const std = @import("std");
const t = @import("types.zig");
const Pager = @import("pager/pager.zig").Pager;
const page0 = @import("page0.zig");
const btree = @import("btree.zig");
const row = @import("row.zig");
const catalog = @import("catalog.zig");
const overflow = @import("overflow.zig");
const txn_mod = @import("txn.zig");

// Database handle.  Must be heap-allocated (via init() or load()) because
// catalog.pager is a pointer that must remain valid for the lifetime of the
// catalog.  Using a stack-allocated Db would create a dangling pointer if the
// caller moves the struct (e.g. returning it from a function).
pub const Db = struct {
    allocator: std.mem.Allocator,
    pager: Pager,
    cat: catalog.Catalog,
    // null = auto-commit mode; non-null = inside an explicit transaction
    txn: ?txn_mod.Transaction,

    // Bootstrap the system catalog on a freshly-created pager.
    // Caller owns the returned pointer; release with db.close().
    pub fn init(pager: Pager, allocator: std.mem.Allocator) !*Db {
        const db = try allocator.create(Db);
        errdefer allocator.destroy(db);
        db.allocator = allocator;
        db.pager = pager;
        db.cat = catalog.Catalog.init(allocator, &db.pager);
        db.txn = null;
        try db.cat.bootstrap();
        try db.pager.flush();
        return db;
    }

    pub fn load(pager: Pager, allocator: std.mem.Allocator) !*Db {
        const db = try allocator.create(Db);
        errdefer allocator.destroy(db);
        db.allocator = allocator;
        db.pager = pager;
        db.cat = catalog.Catalog.init(allocator, &db.pager);
        db.txn = null;
        try db.cat.load();
        return db;
    }

    // Flush dirty pages, close the file, free catalog memory, and destroy self.
    // If a transaction is still open it is rolled back before closing.
    pub fn close(self: *Db) void {
        if (self.txn != null) self.rollback() catch {};
        self.pager.flush() catch {};
        self.pager.close();
        self.cat.deinit();
        self.allocator.destroy(self);
    }

    pub fn begin(self: *Db) !void {
        if (self.txn != null) return error.TransactionAlreadyActive;
        self.txn = txn_mod.Transaction.init(self.allocator);
        // Pin dirty frames so data pages cannot reach disk before commit.
        self.pager.beginTxn();
    }

    pub fn commit(self: *Db) !void {
        if (self.txn == null) return error.NoActiveTransaction;
        self.pager.endTxn();
        try self.pager.flush();
        self.txn.?.deinit();
        self.txn = null;
    }

    pub fn rollback(self: *Db) !void {
        if (self.txn == null) return error.NoActiveTransaction;

        const log = self.txn.?.log.items;
        var i: usize = log.len;
        while (i > 0) {
            i -= 1;
            switch (log[i]) {
                .insert => |e| {
                    // Undo the insert by deleting the row that was added.
                    const meta = self.cat.getTable(e.table) orelse continue;
                    _ = try btree.delete(&self.pager, meta.btree_root, e.rowid);
                },
                .delete => |e| {
                    // Undo the delete by re-inserting the original row bytes.
                    const meta = self.cat.getTable(e.table) orelse continue;
                    try btree.insert(&self.pager, meta.btree_root, e.rowid, e.row_bytes, true);
                },
                .update => |e| {
                    // Undo the update: remove new row, restore original bytes.
                    const meta = self.cat.getTable(e.table) orelse continue;
                    _ = try btree.delete(&self.pager, meta.btree_root, e.rowid);
                    try btree.insert(&self.pager, meta.btree_root, e.rowid, e.old_row_bytes, true);
                },
            }
        }

        self.pager.endTxn();
        try self.pager.flush();
        self.txn.?.deinit();
        self.txn = null;
    }

    // Define a new table and persist the catalog immediately.
    pub fn createTable(
        self: *Db,
        name: []const u8,
        cols: []const catalog.ColumnMeta,
    ) !void {
        _ = try self.cat.createTable(name, cols);
        try self.pager.flush();
    }

    // Encode and insert a row, returning the assigned rowid.
    pub fn insert(
        self: *Db,
        table: []const u8,
        values: []const row.Value,
    ) !u64 {
        const meta = self.cat.getTable(table) orelse return error.TableNotFound;

        // If the table has an INTEGER PRIMARY KEY column, use its value as the
        // rowid.  A null value means the user omitted it → auto-assign.
        // We also need to ensure the PK column value in the stored row bytes
        // matches the actual rowid (important for the auto-assign case where
        // the caller passes null for the PK slot).
        var mutable_values: ?[]row.Value = null;
        defer if (mutable_values) |mv| self.allocator.free(mv);

        const rowid: u64 = if (meta.findPkColumn()) |pk_idx| blk: {
            if (pk_idx < values.len and values[pk_idx] == .int) {
                const pk_val = values[pk_idx].int;
                const rid: u64 = @intCast(pk_val);
                // Reject duplicates: the B-tree does not check this on its own.
                var leaf_buf: [t.PAGE_SIZE]u8 = undefined;
                const existing = try btree.lookup(&self.pager, meta.btree_root, rid, &leaf_buf);
                if (existing != null) return error.PrimaryKeyConflict;
                // Keep rowid_counter ahead of any explicit PK values.
                if (rid >= meta.rowid_counter) meta.rowid_counter = rid + 1;
                break :blk rid;
            }
            // PK was null (omitted) → auto-assign rowid and write it back into
            // the values so the stored row bytes reflect the actual PK value.
            const rid = meta.rowid_counter;
            meta.rowid_counter += 1;
            const mv = try self.allocator.dupe(row.Value, values);
            mv[pk_idx] = .{ .int = @intCast(rid) };
            mutable_values = mv;
            break :blk rid;
        } else blk: {
            const rid = meta.rowid_counter;
            meta.rowid_counter += 1;
            break :blk rid;
        };

        const actual_values: []const row.Value = if (mutable_values) |mv| mv else values;

        const row_size = row.encodedSize(actual_values);
        const row_buf = try self.allocator.alloc(u8, row_size);
        defer self.allocator.free(row_buf);
        _ = row.encodeRow(actual_values, row_buf);

        try btree.insert(&self.pager, meta.btree_root, rowid, row_buf, true);

        if (self.txn) |*active_txn| {
            try active_txn.logInsert(table, rowid);
        } else {
            try self.pager.flush();
        }
        return rowid;
    }

    // Remove a row by rowid. Returns false if the rowid does not exist.
    pub fn delete(self: *Db, table: []const u8, rowid: u64) !bool {
        const meta = self.cat.getTable(table) orelse return error.TableNotFound;

        if (self.txn) |*active_txn| {
            // Capture old row bytes before deletion so we can restore them on rollback.
            var leaf_buf: [t.PAGE_SIZE]u8 = undefined;
            const cell = try btree.lookup(&self.pager, meta.btree_root, rowid, &leaf_buf) orelse return false;

            if (cell.is_overflow) {
                const tmp = try self.allocator.alloc(u8, cell.overflow_len);
                defer self.allocator.free(tmp);
                try overflow.readChain(&self.pager, cell.overflow_page, cell.overflow_len, tmp);
                try active_txn.logDelete(table, rowid, tmp);
            } else {
                try active_txn.logDelete(table, rowid, cell.row_data);
            }

            _ = try btree.delete(&self.pager, meta.btree_root, rowid);
            return true;
        }

        const deleted = try btree.delete(&self.pager, meta.btree_root, rowid);
        if (deleted) try self.pager.flush();
        return deleted;
    }

    // Replace the row at rowid with new values. Returns false if not found.
    pub fn update(
        self: *Db,
        table: []const u8,
        rowid: u64,
        values: []const row.Value,
    ) !bool {
        const meta = self.cat.getTable(table) orelse return error.TableNotFound;

        if (self.txn) |*active_txn| {
            // Capture old row bytes before mutation so we can restore them on rollback.
            var leaf_buf: [t.PAGE_SIZE]u8 = undefined;
            const cell = try btree.lookup(&self.pager, meta.btree_root, rowid, &leaf_buf) orelse return false;

            if (cell.is_overflow) {
                const tmp = try self.allocator.alloc(u8, cell.overflow_len);
                defer self.allocator.free(tmp);
                try overflow.readChain(&self.pager, cell.overflow_page, cell.overflow_len, tmp);
                try active_txn.logUpdate(table, rowid, tmp);
            } else {
                try active_txn.logUpdate(table, rowid, cell.row_data);
            }

            _ = try btree.delete(&self.pager, meta.btree_root, rowid);
            const row_size = row.encodedSize(values);
            const row_buf = try self.allocator.alloc(u8, row_size);
            defer self.allocator.free(row_buf);
            _ = row.encodeRow(values, row_buf);
            try btree.insert(&self.pager, meta.btree_root, rowid, row_buf, true);
            return true;
        }

        const deleted = try btree.delete(&self.pager, meta.btree_root, rowid);
        if (!deleted) return false;

        const row_size = row.encodedSize(values);
        const row_buf = try self.allocator.alloc(u8, row_size);
        defer self.allocator.free(row_buf);
        _ = row.encodeRow(values, row_buf);

        try btree.insert(&self.pager, meta.btree_root, rowid, row_buf, true);
        try self.pager.flush();
        return true;
    }

    // Fetch a single row by rowid. Caller owns the returned slice and its values.
    // Returns null if the rowid does not exist.
    pub fn getByRowid(
        self: *Db,
        table: []const u8,
        rowid: u64,
        allocator: std.mem.Allocator,
    ) !?[]row.Value {
        const meta = self.cat.getTable(table) orelse return error.TableNotFound;

        var schema_buf: [64]row.ColumnSchema = undefined;
        const cols = buildColSchema(meta.columns, &schema_buf);

        var leaf_buf: [t.PAGE_SIZE]u8 = undefined;
        const cell = try btree.lookup(&self.pager, meta.btree_root, rowid, &leaf_buf) orelse return null;

        const row_bytes: []u8 = if (cell.is_overflow) blk: {
            const out = try allocator.alloc(u8, cell.overflow_len);
            try overflow.readChain(&self.pager, cell.overflow_page, cell.overflow_len, out);
            break :blk out;
        } else try allocator.dupe(u8, cell.row_data);
        defer allocator.free(row_bytes);

        return try row.decodeRow(cols, row_bytes, allocator);
    }

    // Iterator that decodes rows from a btree scan one at a time.
    // The struct is self-contained (schema_buf is inline) so it can be returned
    // by value without the cols slice dangling after a move.
    pub const DbRowIterator = struct {
        it: btree.ScanIterator,
        schema_buf: [64]row.ColumnSchema,
        schema_len: usize,

        // Returns the next decoded row, arena-allocated, or null at EOF.
        pub fn next(self: *DbRowIterator, allocator: std.mem.Allocator) !?struct { rowid: u64, page_id: u32, slot_id: u16, values: []row.Value } {
            const cell = try self.it.next() orelse return null;
            const cols = self.schema_buf[0..self.schema_len];

            // Overflow rows span multiple pages; copy into a temp buffer,
            // decode, then free the raw bytes.
            const row_bytes: []u8 = if (cell.is_overflow) blk: {
                const out = try allocator.alloc(u8, cell.overflow_len);
                errdefer allocator.free(out);
                try overflow.readChain(self.it.pager, cell.overflow_page, cell.overflow_len, out);
                break :blk out;
            } else try allocator.dupe(u8, cell.row_data);
            defer allocator.free(row_bytes);

            return .{ .rowid = cell.rowid, .page_id = cell.page_id, .slot_id = cell.slot_idx, .values = try row.decodeRow(cols, row_bytes, allocator) };
        }
    };

    // Open a forward scan over every row in table, in rowid order.
    // The returned iterator borrows &self.pager, so it must not outlive db.
    pub fn scanOpen(self: *Db, table: []const u8) !DbRowIterator {
        const meta = self.cat.getTable(table) orelse return error.TableNotFound;
        var it = DbRowIterator{
            .it = try btree.ScanIterator.init(&self.pager, meta.btree_root),
            .schema_buf = undefined,
            .schema_len = meta.columns.len,
        };
        for (meta.columns, 0..) |c, i| {
            it.schema_buf[i] = .{ .col_type = c.col_type, .nullable = c.nullable };
        }
        return it;
    }

    // Walk every row in a table in rowid order, calling cb(rowid, values, ctx).
    // Return false from the callback to stop early.
    pub fn scan(
        self: *Db,
        table: []const u8,
        cb: anytype,
        ctx: anytype,
    ) !void {
        const meta = self.cat.getTable(table) orelse return error.TableNotFound;

        var schema_buf: [64]row.ColumnSchema = undefined;
        const cols = buildColSchema(meta.columns, &schema_buf);

        var it = try btree.ScanIterator.init(&self.pager, meta.btree_root);
        while (try it.next()) |cell| {
            const row_bytes: []u8 = if (cell.is_overflow) blk: {
                const out = try self.allocator.alloc(u8, cell.overflow_len);
                try overflow.readChain(&self.pager, cell.overflow_page, cell.overflow_len, out);
                break :blk out;
            } else try self.allocator.dupe(u8, cell.row_data);
            defer self.allocator.free(row_bytes);

            const values = try row.decodeRow(cols, row_bytes, self.allocator);
            defer {
                for (values) |v| switch (v) {
                    .text => |s| self.allocator.free(s),
                    .blob => |b| self.allocator.free(b),
                    else => {},
                };
                self.allocator.free(values);
            }

            if (!cb(cell.rowid, values, ctx)) break;
        }
    }
};

// Fill a caller-supplied buffer with ColumnSchema derived from ColumnMeta.
// Avoids returning a pointer to a local stack array.
fn buildColSchema(cols: []const catalog.ColumnMeta, buf: []row.ColumnSchema) []const row.ColumnSchema {
    for (cols, 0..) |c, i| {
        buf[i] = .{ .col_type = c.col_type, .nullable = c.nullable };
    }
    return buf[0..cols.len];
}
