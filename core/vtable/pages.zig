// ── __pages ───────────────────────────────────────────────────────────────────
// Lists every page in the database file with its type.

const std = @import("std");
const t = @import("../types.zig");
const Catalog = @import("../catalog.zig").Catalog;
const root = @import("root.zig");

pub const columns = [_]root.VTabColumn{
    .{ .name = "page_id", .col_type = .int, .nullable = false },
    .{ .name = "page_type", .col_type = .text, .nullable = false },
};

pub fn scan(
    cat: *Catalog,
    args: []const i64,
    out: *std.ArrayList([]root.Value),
    alloc: std.mem.Allocator,
) anyerror!void {
    _ = args;
    const pager = cat.pager;
    var page_id: u32 = 0;
    while (page_id < pager.total_pages) : (page_id += 1) {
        var buf: [t.PAGE_SIZE]u8 = undefined;
        try pager.readPage(page_id, &buf);
        const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
        const type_str: []const u8 = if (page_id == 0) "header" else switch (ph.page_type) {
            .btree_leaf => "btree_leaf",
            .btree_internal => "btree_internal",
            .overflow => "overflow",
            .free => "free",
        };
        const vals = try alloc.alloc(root.Value, 2);
        vals[0] = .{ .int = @intCast(page_id) };
        vals[1] = .{ .text = type_str };
        try out.append(alloc, vals);
    }
}
