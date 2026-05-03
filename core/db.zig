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

    // Load the catalog from a pager that already contains database pages.
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

    // Begin an explicit transaction.  DML operations will be buffered in the
    // undo log and the pager will not be flushed until commit() is called.
    pub fn begin(self: *Db) !void {
        if (self.txn != null) return error.TransactionAlreadyActive;
        self.txn = txn_mod.Transaction.init(self.allocator);
    }

    // Commit the active transaction: flush all dirty pages to disk and discard
    // the undo log.
    pub fn commit(self: *Db) !void {
        if (self.txn == null) return error.NoActiveTransaction;
        try self.pager.flush();
        self.txn.?.deinit();
        self.txn = null;
    }

    // Roll back the active transaction by replaying the undo log in reverse,
    // then flush the reverted state to disk.
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

        const rowid = meta.rowid_counter;
        meta.rowid_counter += 1;

        const row_size = row.encodedSize(values);
        const row_buf = try self.allocator.alloc(u8, row_size);
        defer self.allocator.free(row_buf);
        _ = row.encodeRow(values, row_buf);

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
