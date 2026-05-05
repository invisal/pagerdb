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

const PagesCursor = struct {
    cat: *Catalog,
    page_id: u32,
};

fn cursorNext(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]root.Value {
    const self: *PagesCursor = @ptrCast(@alignCast(ptr));
    const pager = self.cat.pager;
    if (self.page_id >= pager.total_pages) return null;

    var buf: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(self.page_id, &buf);
    const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
    const type_str: []const u8 = if (self.page_id == 0) "header" else switch (ph.page_type) {
        .btree_leaf => "btree_leaf",
        .btree_internal => "btree_internal",
        .overflow => "overflow",
        .free => "free",
        .undo => "undo",
    };

    const vals = try alloc.alloc(root.Value, 2);
    vals[0] = .{ .int = @intCast(self.page_id) };
    vals[1] = .{ .text = type_str };
    self.page_id += 1;
    return vals;
}

pub fn open(cat: *Catalog, args: []const root.Value, alloc: std.mem.Allocator) anyerror!root.VTabCursor {
    _ = args;
    const cur = try alloc.create(PagesCursor);
    cur.* = .{ .cat = cat, .page_id = 0 };
    return .{ .ptr = cur, .next_fn = cursorNext };
}
