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

const PageSlotsCursor = struct {
    // The page buffer is loaded once at open() and read lazily by next().
    buf: [t.PAGE_SIZE]u8,
    slot_idx: usize,
    cell_count: usize,
    is_leaf: bool,
};

fn cursorNext(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]root.Value {
    const self: *PageSlotsCursor = @ptrCast(@alignCast(ptr));
    if (self.slot_idx >= self.cell_count) return null;

    const i = self.slot_idx;
    self.slot_idx += 1;

    const vals = try alloc.alloc(root.Value, 4);
    if (self.is_leaf) {
        const off = btree.getCellPtr(&self.buf, @intCast(i));
        const cell = btree.readLeafCell(&self.buf, off);
        const dlen = if (cell.is_overflow) cell.overflow_len else cell.row_data.len;
        vals[0] = .{ .int = @intCast(i) };
        vals[1] = .{ .int = @intCast(cell.rowid) };
        vals[2] = .{ .int = @intCast(dlen) };
        vals[3] = .{ .int = if (cell.is_overflow) 1 else 0 };
    } else {
        const off = btree.getCellPtr(&self.buf, @intCast(i));
        const sep_rowid = std.mem.readInt(u64, self.buf[off + 4 ..][0..8], .little);
        vals[0] = .{ .int = @intCast(i) };
        vals[1] = .{ .int = @intCast(sep_rowid) };
        vals[2] = .{ .int = 0 };
        vals[3] = .{ .int = 0 };
    }
    return vals;
}

pub fn open(alloc: std.mem.Allocator, cat: *Catalog, args: []const root.Value) anyerror!root.VTabCursor {
    const page_id: u32 = switch (args[0]) {
        .int => |n| @intCast(n),
        else => return error.InvalidArgumentType,
    };

    const cur = try alloc.create(PageSlotsCursor);
    cur.* = .{ .buf = undefined, .slot_idx = 0, .cell_count = 0, .is_leaf = false };

    const pager = cat.pager;
    if (page_id < pager.total_pages) {
        try pager.readPage(page_id, &cur.buf);
        const ph = std.mem.bytesToValue(t.PageHeader, cur.buf[0..@sizeOf(t.PageHeader)]);
        const bh = btree.readBTreeHeader(&cur.buf);
        switch (ph.page_type) {
            .btree_leaf => {
                cur.cell_count = bh.cell_count;
                cur.is_leaf = true;
            },
            .btree_internal => {
                cur.cell_count = bh.cell_count;
                cur.is_leaf = false;
            },
            else => {},
        }
    }

    return .{ .ptr = cur, .next_fn = cursorNext };
}
