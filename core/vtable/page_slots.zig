// ── __page_slots(page_id) ─────────────────────────────────────────────────────
// Lists every cell slot in a BTree page.
// Leaf pages:     rowid = row's rowid,      data_len = inline or overflow length.
// Internal pages: rowid = separator key,    data_len = 0.

const std = @import("std");
const t = @import("../types.zig");
const Catalog = @import("../catalog.zig").Catalog;
const btree = @import("../btree.zig");
const root = @import("root.zig");

pub const columns = [_]root.VTabColumn{
    .{ .name = "slot_idx", .col_type = .int, .nullable = false },
    .{ .name = "rowid", .col_type = .int, .nullable = false },
    .{ .name = "data_len", .col_type = .int, .nullable = false },
    .{ .name = "is_overflow", .col_type = .int, .nullable = false },
};

pub fn scan(
    cat: *Catalog,
    args: []const i64,
    out: *std.ArrayList([]root.Value),
    alloc: std.mem.Allocator,
) anyerror!void {
    const pager = cat.pager;
    const page_id: u32 = @intCast(args[0]);
    if (page_id >= pager.total_pages) return;

    var buf: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(page_id, &buf);

    const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
    const bh = btree.readBTreeHeader(&buf);

    switch (ph.page_type) {
        .btree_leaf => {
            for (0..bh.cell_count) |i| {
                const off = btree.getCellPtr(&buf, @intCast(i));
                const cell = btree.readLeafCell(&buf, off);
                const dlen = if (cell.is_overflow) cell.overflow_len else cell.row_data.len;
                const vals = try alloc.alloc(root.Value, 4);
                vals[0] = .{ .int = @intCast(i) };
                vals[1] = .{ .int = @intCast(cell.rowid) };
                vals[2] = .{ .int = @intCast(dlen) };
                vals[3] = .{ .int = if (cell.is_overflow) 1 else 0 };
                try out.append(alloc, vals);
            }
        },
        .btree_internal => {
            for (0..bh.cell_count) |i| {
                const off = btree.getCellPtr(&buf, @intCast(i));
                const sep_rowid = std.mem.readInt(u64, buf[off + 4 ..][0..8], .little);
                const vals = try alloc.alloc(root.Value, 4);
                vals[0] = .{ .int = @intCast(i) };
                vals[1] = .{ .int = @intCast(sep_rowid) };
                vals[2] = .{ .int = 0 };
                vals[3] = .{ .int = 0 };
                try out.append(alloc, vals);
            }
        },
        else => {},
    }
}
