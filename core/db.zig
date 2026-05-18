const std = @import("std");
const t = @import("types.zig");
const Pager = @import("pager/pager.zig").Pager;
const PageWriter = @import("page_writer.zig").PageWriter;
const page0 = @import("page0.zig");
const btree = @import("btree_shared.zig");
const row = @import("row.zig");
const index_key_mod = @import("index_key.zig");
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
                    // Undo the insert: delete the row and its index entries.
                    const meta = self.cat.getTable(e.table) orelse continue;
                    if (meta.indexes.len > 0) {
                        if (try readAndDecodeRow(self, meta, e.rowid)) |vals| {
                            defer freeValues(self.allocator, vals);
                            try deleteFromIndexes(self, meta, e.rowid, vals);
                        }
                    }
                    _ = try btree.RowidBTree.delete(&self.pager, meta.btree_root, e.rowid);
                },
                .delete => |e| {
                    // Undo the delete: re-insert the original row and its index entries.
                    const meta = self.cat.getTable(e.table) orelse continue;
                    if (meta.indexes.len > 0) {
                        var schema_buf: [64]row.ColumnSchema = undefined;
                        const cols = buildColSchema(meta.columns, &schema_buf);
                        const vals = try row.decodeRow(cols, e.row_bytes, self.allocator);
                        defer freeValues(self.allocator, vals);
                        try insertToIndexes(self, meta, e.rowid, vals);
                    }
                    try btree.insertRow(&self.pager, meta.btree_root, e.rowid, e.row_bytes);
                },
                .update => |e| {
                    // Undo the update: restore old row bytes and fix index entries.
                    const meta = self.cat.getTable(e.table) orelse continue;
                    if (meta.indexes.len > 0) {
                        // Delete the current (new) index entries before overwriting.
                        if (try readAndDecodeRow(self, meta, e.rowid)) |new_vals| {
                            defer freeValues(self.allocator, new_vals);
                            try deleteFromIndexes(self, meta, e.rowid, new_vals);
                        }
                        // Insert index entries for the original row.
                        var schema_buf: [64]row.ColumnSchema = undefined;
                        const cols = buildColSchema(meta.columns, &schema_buf);
                        const old_vals = try row.decodeRow(cols, e.old_row_bytes, self.allocator);
                        defer freeValues(self.allocator, old_vals);
                        try insertToIndexes(self, meta, e.rowid, old_vals);
                    }
                    _ = try btree.RowidBTree.delete(&self.pager, meta.btree_root, e.rowid);
                    try btree.insertRow(&self.pager, meta.btree_root, e.rowid, e.old_row_bytes);
                },
            }
        }

        self.pager.endTxn();
        try self.pager.flush();
        self.txn.?.deinit();
        self.txn = null;
    }

    // Build a secondary index over an existing table, then register it in the catalog.
    // Full table scan encodes a key for every existing row and inserts it into
    // the new index B-tree.  For unique indexes, duplicate keys are rejected with
    // error.UniqueViolation.
    pub fn createIndex(
        self: *Db,
        name: []const u8,
        table_name: []const u8,
        col_indices: []const u32,
        is_unique: bool,
        if_not_exists: bool,
    ) !void {
        const table = self.cat.getTable(table_name) orelse return error.TableNotFound;

        // Duplicate check before allocating any pages.
        for (table.indexes) |idx| {
            if (std.ascii.eqlIgnoreCase(idx.name, name)) {
                if (if_not_exists) return;
                return error.IndexAlreadyExists;
            }
        }

        // Allocate a fresh leaf page for the index B-tree.
        const index_root = try self.pager.allocPage();
        var idx_pw = PageWriter.init(&self.pager, index_root);
        btree.initLeafPage(&idx_pw, false);
        try idx_pw.commit();

        // Populate the index from existing rows.
        var schema_buf: [64]row.ColumnSchema = undefined;
        const cols = buildColSchema(table.columns, &schema_buf);
        var it = try btree.RowidBTree.ScanIterator.init(&self.pager, table.btree_root);
        while (try it.next()) |cell| {
            const row_bytes: []u8 = if (cell.is_overflow) blk: {
                const out = try self.allocator.alloc(u8, cell.overflow_len);
                try overflow.readChain(&self.pager, cell.overflow_page, cell.overflow_len, out);
                break :blk out;
            } else try self.allocator.dupe(u8, cell.row_data);
            defer self.allocator.free(row_bytes);

            const values = try row.decodeRow(cols, row_bytes, self.allocator);
            defer freeValues(self.allocator, values);

            var key_buf: [index_key_mod.MAX_KEY_LEN + 8]u8 = undefined;
            const prefix_len = buildIndexKeyPrefix(values, col_indices, &key_buf);
            if (is_unique) {
                if (try btree.searchPrefix(&self.pager, index_root, key_buf[0..prefix_len]) != null)
                    return error.UniqueViolation;
            }
            const full_len = index_key_mod.appendRowid(&key_buf, prefix_len, cell.rowid);
            try btree.IndexBTree.insert(&self.pager, index_root, key_buf[0..full_len]);
        }

        _ = try self.cat.createIndex(name, table_name, col_indices, is_unique, index_root);
        try self.pager.flush();
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

    pub fn createView(self: *Db, name: []const u8, sql: []const u8) !void {
        _ = try self.cat.createView(name, sql);
        try self.pager.flush();
    }

    pub fn dropView(self: *Db, name: []const u8, if_exists: bool) !void {
        self.cat.dropView(name) catch |e| {
            if (e == error.ViewNotFound and if_exists) return;
            return e;
        };
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
                const existing = try btree.lookupCell(&self.pager, meta.btree_root, rid, &leaf_buf);
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

        // Enforce unique index constraints before touching the main B-tree so that
        // a violation leaves the database in a clean state.
        if (meta.indexes.len > 0) try checkUniqueConstraints(self, meta, actual_values);

        try btree.insertRow(&self.pager, meta.btree_root, rowid, row_buf);

        if (meta.indexes.len > 0) try insertToIndexes(self, meta, rowid, actual_values);

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

        // Read the row before deleting whenever we need it for the transaction
        // log or for index key deletion.
        const need_row = self.txn != null or meta.indexes.len > 0;
        if (need_row) {
            var leaf_buf: [t.PAGE_SIZE]u8 = undefined;
            const cell = try btree.lookupCell(&self.pager, meta.btree_root, rowid, &leaf_buf) orelse return false;

            const row_bytes: []u8 = if (cell.is_overflow) blk: {
                const out = try self.allocator.alloc(u8, cell.overflow_len);
                try overflow.readChain(&self.pager, cell.overflow_page, cell.overflow_len, out);
                break :blk out;
            } else try self.allocator.dupe(u8, cell.row_data);
            defer self.allocator.free(row_bytes);

            if (self.txn) |*active_txn| try active_txn.logDelete(table, rowid, row_bytes);

            if (meta.indexes.len > 0) {
                var schema_buf: [64]row.ColumnSchema = undefined;
                const cols = buildColSchema(meta.columns, &schema_buf);
                const values = try row.decodeRow(cols, row_bytes, self.allocator);
                defer freeValues(self.allocator, values);
                try deleteFromIndexes(self, meta, rowid, values);
            }

            _ = try btree.RowidBTree.delete(&self.pager, meta.btree_root, rowid);
            if (self.txn == null) try self.pager.flush();
            return true;
        }

        const deleted = try btree.RowidBTree.delete(&self.pager, meta.btree_root, rowid);
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

        // Read old row whenever needed for the transaction log or index maintenance.
        const need_old_row = self.txn != null or meta.indexes.len > 0;
        if (need_old_row) {
            var leaf_buf: [t.PAGE_SIZE]u8 = undefined;
            const cell = try btree.lookupCell(&self.pager, meta.btree_root, rowid, &leaf_buf) orelse return false;

            const old_row_bytes: []u8 = if (cell.is_overflow) blk: {
                const out = try self.allocator.alloc(u8, cell.overflow_len);
                try overflow.readChain(&self.pager, cell.overflow_page, cell.overflow_len, out);
                break :blk out;
            } else try self.allocator.dupe(u8, cell.row_data);
            defer self.allocator.free(old_row_bytes);

            if (self.txn) |*active_txn| try active_txn.logUpdate(table, rowid, old_row_bytes);

            if (meta.indexes.len > 0) {
                var schema_buf: [64]row.ColumnSchema = undefined;
                const cols = buildColSchema(meta.columns, &schema_buf);
                const old_values = try row.decodeRow(cols, old_row_bytes, self.allocator);
                defer freeValues(self.allocator, old_values);
                // Pre-check unique constraints before making any writes.
                // Allow the current row's own entry to "conflict" (self-update).
                try checkUniqueConstraintsExcept(self, meta, values, rowid);
                try deleteFromIndexes(self, meta, rowid, old_values);
                try insertToIndexes(self, meta, rowid, values);
            }

            _ = try btree.RowidBTree.delete(&self.pager, meta.btree_root, rowid);
            const row_size = row.encodedSize(values);
            const row_buf = try self.allocator.alloc(u8, row_size);
            defer self.allocator.free(row_buf);
            _ = row.encodeRow(values, row_buf);
            try btree.insertRow(&self.pager, meta.btree_root, rowid, row_buf);
            if (self.txn == null) try self.pager.flush();
            return true;
        }

        const deleted = try btree.RowidBTree.delete(&self.pager, meta.btree_root, rowid);
        if (!deleted) return false;

        const row_size = row.encodedSize(values);
        const row_buf = try self.allocator.alloc(u8, row_size);
        defer self.allocator.free(row_buf);
        _ = row.encodeRow(values, row_buf);

        try btree.insertRow(&self.pager, meta.btree_root, rowid, row_buf);
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
        const cell = try btree.lookupCell(&self.pager, meta.btree_root, rowid, &leaf_buf) orelse return null;

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
        it: btree.RowidBTree.ScanIterator,
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
            .it = try btree.RowidBTree.ScanIterator.init(&self.pager, meta.btree_root),
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

        var it = try btree.RowidBTree.ScanIterator.init(&self.pager, meta.btree_root);
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

// Free heap-allocated text/blob inside a decoded row, then free the slice itself.
fn freeValues(alloc: std.mem.Allocator, values: []const row.Value) void {
    for (values) |v| switch (v) {
        .text => |s| alloc.free(s),
        .blob => |b| alloc.free(b),
        else => {},
    };
    alloc.free(values);
}

// Encode the values at the given column positions into the first N bytes of buf.
// Returns the number of bytes written (the prefix length before the rowid suffix).
fn buildIndexKeyPrefix(values: []const row.Value, col_indices: []const u32, buf: []u8) usize {
    var key_vals: [16]row.Value = undefined;
    const n = @min(col_indices.len, key_vals.len);
    for (col_indices[0..n], 0..) |attnum, k| {
        key_vals[k] = if (attnum < values.len) values[attnum] else .null;
    }
    return index_key_mod.encodeKey(key_vals[0..n], buf);
}

// Read a row from the B-tree and decode it.  Caller must call freeValues on the result.
fn readAndDecodeRow(self: *Db, meta: *const catalog.TableMeta, rowid: u64) !?[]row.Value {
    var leaf_buf: [t.PAGE_SIZE]u8 = undefined;
    const cell = try btree.lookupCell(&self.pager, meta.btree_root, rowid, &leaf_buf) orelse return null;
    const row_bytes: []u8 = if (cell.is_overflow) blk: {
        const out = try self.allocator.alloc(u8, cell.overflow_len);
        try overflow.readChain(&self.pager, cell.overflow_page, cell.overflow_len, out);
        break :blk out;
    } else try self.allocator.dupe(u8, cell.row_data);
    defer self.allocator.free(row_bytes);
    var schema_buf: [64]row.ColumnSchema = undefined;
    const cols = buildColSchema(meta.columns, &schema_buf);
    return try row.decodeRow(cols, row_bytes, self.allocator);
}

// Pre-check: returns error.UniqueViolation if any unique index already contains
// a matching column-value prefix.  Must be called BEFORE the main B-tree insert
// so that a failure leaves the database in a clean state.
fn checkUniqueConstraints(self: *Db, meta: *const catalog.TableMeta, values: []const row.Value) !void {
    for (meta.indexes) |idx| {
        if (!idx.is_unique) continue;
        var key_buf: [index_key_mod.MAX_KEY_LEN + 8]u8 = undefined;
        const prefix_len = buildIndexKeyPrefix(values, idx.col_indices, &key_buf);
        if (try btree.searchPrefix(&self.pager, idx.btree_root, key_buf[0..prefix_len]) != null)
            return error.UniqueViolation;
    }
}

// Like checkUniqueConstraints but allows one rowid to be the conflicting entry.
// Used during UPDATE so that a row can be updated to its own current unique value
// without triggering a false violation.
fn checkUniqueConstraintsExcept(
    self: *Db,
    meta: *const catalog.TableMeta,
    values: []const row.Value,
    except_rowid: u64,
) !void {
    for (meta.indexes) |idx| {
        if (!idx.is_unique) continue;
        var key_buf: [index_key_mod.MAX_KEY_LEN + 8]u8 = undefined;
        const prefix_len = buildIndexKeyPrefix(values, idx.col_indices, &key_buf);
        if (try btree.searchPrefix(&self.pager, idx.btree_root, key_buf[0..prefix_len])) |found_rowid| {
            if (found_rowid != except_rowid) return error.UniqueViolation;
        }
    }
}

// Insert a key into every secondary index for this row (no unique check — caller
// must call checkUniqueConstraints first).
fn insertToIndexes(self: *Db, meta: *const catalog.TableMeta, rowid: u64, values: []const row.Value) !void {
    for (meta.indexes) |idx| {
        var key_buf: [index_key_mod.MAX_KEY_LEN + 8]u8 = undefined;
        const prefix_len = buildIndexKeyPrefix(values, idx.col_indices, &key_buf);
        const full_len = index_key_mod.appendRowid(&key_buf, prefix_len, rowid);
        try btree.IndexBTree.insert(&self.pager, idx.btree_root, key_buf[0..full_len]);
    }
}

// Delete index entries for every secondary index on the table.
fn deleteFromIndexes(self: *Db, meta: *const catalog.TableMeta, rowid: u64, values: []const row.Value) !void {
    for (meta.indexes) |idx| {
        var key_buf: [index_key_mod.MAX_KEY_LEN + 8]u8 = undefined;
        const prefix_len = buildIndexKeyPrefix(values, idx.col_indices, &key_buf);
        const full_len = index_key_mod.appendRowid(&key_buf, prefix_len, rowid);
        _ = try btree.IndexBTree.delete(&self.pager, idx.btree_root, key_buf[0..full_len]);
    }
}
