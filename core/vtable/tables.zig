// ── __tables ──────────────────────────────────────────────────────────────────
// Lists all user-defined tables in the database with their metadata.

const std = @import("std");
const Catalog = @import("../catalog.zig").Catalog;
const root = @import("root.zig");

pub const columns = [_]root.VTabColumn{
    .{ .name = "table_schema", .col_type = .text, .nullable = false },
    .{ .name = "table_name", .col_type = .text, .nullable = false },
    .{ .name = "btree_root", .col_type = .int, .nullable = false },
    .{ .name = "column_count", .col_type = .int, .nullable = false },
};

pub fn scan(
    cat: *Catalog,
    args: []const i64,
    out: *std.ArrayList([]root.Value),
    alloc: std.mem.Allocator,
) anyerror!void {
    _ = args;
    var it = cat.tables.valueIterator();
    while (it.next()) |meta| {
        const vals = try alloc.alloc(root.Value, 4);
        vals[0] = .{ .text = try alloc.dupe(u8, "main") };
        vals[1] = .{ .text = try alloc.dupe(u8, meta.name) };
        vals[2] = .{ .int = @intCast(meta.btree_root) };
        vals[3] = .{ .int = @intCast(meta.columns.len) };
        try out.append(alloc, vals);
    }
}
