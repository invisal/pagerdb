const std = @import("std");
const t = @import("types.zig");
const Pager = @import("pager/pager.zig").Pager;
const page0 = @import("page0.zig");
const btree = @import("btree.zig");
const row = @import("row.zig");
const catalog = @import("catalog.zig");
const overflow = @import("overflow.zig");

// Database handle.  Must be heap-allocated (via init() or load()) because
// catalog.pager is a pointer that must remain valid for the lifetime of the
// catalog.  Using a stack-allocated Db would create a dangling pointer if the
// caller moves the struct (e.g. returning it from a function).
pub const Db = struct {
    allocator: std.mem.Allocator,
    pager: Pager,
    cat: catalog.Catalog,

    // Bootstrap the system catalog on a freshly-created pager.
    // Caller owns the returned pointer; release with db.close().
    pub fn init(pager: Pager, allocator: std.mem.Allocator) !*Db {
        const db = try allocator.create(Db);
        errdefer allocator.destroy(db);
        db.allocator = allocator;
        db.pager = pager;
        db.cat = catalog.Catalog.init(allocator, &db.pager);
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
        try db.cat.load();
        return db;
    }

    // Flush dirty pages, close the file, free catalog memory, and destroy self.
    pub fn close(self: *Db) void {
        self.pager.flush() catch {};
        self.pager.close();
        self.cat.deinit();
        self.allocator.destroy(self);
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
        try self.pager.flush();
        return rowid;
    }

    // Remove a row by rowid. Returns false if the rowid does not exist.
    pub fn delete(self: *Db, table: []const u8, rowid: u64) !bool {
        const meta = self.cat.getTable(table) orelse return error.TableNotFound;
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
