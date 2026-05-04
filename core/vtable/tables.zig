// ── __tables ──────────────────────────────────────────────────────────────────
// Lists all user-defined tables in the database with their metadata.

const std = @import("std");
const catalog = @import("../catalog.zig");
const Catalog = catalog.Catalog;
const root = @import("root.zig");

pub const columns = [_]root.VTabColumn{
    .{ .name = "table_schema", .col_type = .text, .nullable = false },
    .{ .name = "table_name", .col_type = .text, .nullable = false },
    .{ .name = "btree_root", .col_type = .int, .nullable = false },
    .{ .name = "column_count", .col_type = .int, .nullable = false },
};

const TablesCursor = struct {
    it: std.StringHashMap(catalog.TableMeta).ValueIterator,
};

fn cursorNext(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]root.Value {
    const self: *TablesCursor = @ptrCast(@alignCast(ptr));
    const meta = self.it.next() orelse return null;

    const vals = try alloc.alloc(root.Value, 4);
    vals[0] = .{ .text = try alloc.dupe(u8, "main") };
    vals[1] = .{ .text = try alloc.dupe(u8, meta.name) };
    vals[2] = .{ .int = @intCast(meta.btree_root) };
    vals[3] = .{ .int = @intCast(meta.columns.len) };
    return vals;
}

fn cursorClose(ptr: *anyopaque, alloc: std.mem.Allocator) void {
    alloc.destroy(@as(*TablesCursor, @ptrCast(@alignCast(ptr))));
}

pub fn open(cat: *Catalog, args: []const i64, alloc: std.mem.Allocator) anyerror!root.VTabCursor {
    _ = args;
    const cur = try alloc.create(TablesCursor);
    cur.* = .{ .it = cat.tables.valueIterator() };
    return .{ .ptr = cur, .next_fn = cursorNext, .close_fn = cursorClose };
}
