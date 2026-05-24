const std = @import("std");
const t = @import("../types.zig");
const bs = @import("../btree_shared.zig");
const Pager = @import("../pager/pager.zig").Pager;

// Print only the page banner and header fields — no cell dump.
// Use for structural violations (wrong parent pointer, bad page type, broken
// leaf chain link) where the header fields are what matters and printing
// hundreds of cell slots would just be noise.
pub fn printPageHeader(pager: *Pager, page_id: u32) void {
    var buf: [t.PAGE_SIZE]u8 = undefined;
    pager.readPage(page_id, &buf) catch |err| {
        std.debug.print("  ── page {d}: read error: {}\n", .{ page_id, err });
        return;
    };
    printBufHeader(&buf, page_id);
}

// Print the banner, header fields, and every cell slot.
// Use for cell-level violations (bad offsets, overlaps, wrong key order,
// subtree bounds) where you need to see the actual cell contents.
pub fn printPage(pager: *Pager, page_id: u32) void {
    var buf: [t.PAGE_SIZE]u8 = undefined;
    pager.readPage(page_id, &buf) catch |err| {
        std.debug.print("  ── page {d}: read error: {}\n", .{ page_id, err });
        return;
    };
    printBufHeader(&buf, page_id);
    printBufCells(&buf);
}

// ── Shared internals ──────────────────────────────────────────────────────────

fn printBufHeader(buf: *const [t.PAGE_SIZE]u8, page_id: u32) void {
    const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
    const h = bs.readBTreeHeader(buf);
    const is_rowid = (h.flags & bs.BTREE_FLAG_ROWID_TREE) != 0;

    const type_label: []const u8 = switch (ph.page_type) {
        .btree_leaf => "btree_leaf",
        .btree_internal => "btree_internal",
        .overflow => "overflow",
        .free => "free",
    };
    const fmt_label: []const u8 = if (is_rowid) "rowid" else "index";

    std.debug.print("  ── page {d} ({s}, {s}) ", .{ page_id, type_label, fmt_label });
    for (0..44) |_| std.debug.print("─", .{});
    std.debug.print("\n", .{});

    if (ph.page_type != .btree_leaf and ph.page_type != .btree_internal) {
        std.debug.print("  (not a btree page)\n", .{});
        return;
    }

    const free_bytes = if (h.free_end >= bs.freeStart(h)) h.free_end - bs.freeStart(h) else 0;
    std.debug.print("  header : cell_count={d}  free_end={d}  dead={d}\n", .{
        h.cell_count, h.free_end, h.dead_bytes,
    });
    std.debug.print("           parent={d}  prev={d}  next={d}\n", .{
        h.parent_page, h.prev_leaf, h.next_leaf,
    });
    std.debug.print("  space  : free={d} bytes  dead={d} bytes\n", .{ free_bytes, h.dead_bytes });
}

fn printBufCells(buf: *const [t.PAGE_SIZE]u8) void {
    const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
    const h = bs.readBTreeHeader(buf);
    const is_rowid = (h.flags & bs.BTREE_FLAG_ROWID_TREE) != 0;
    const cell_area_end: u16 = if (ph.page_type == .btree_internal) t.PAGE_SIZE - 4 else t.PAGE_SIZE;

    for (0..h.cell_count) |i| {
        const offset = bs.getCellPtr(buf, @intCast(i));
        if (ph.page_type == .btree_leaf) {
            if (is_rowid) printRowidLeafCell(buf, @intCast(i), offset, cell_area_end) else printIndexLeafCell(buf, @intCast(i), offset, cell_area_end);
        } else {
            if (is_rowid) printRowidInternalCell(buf, @intCast(i), offset, cell_area_end) else printIndexInternalCell(buf, @intCast(i), offset, cell_area_end);
        }
    }

    if (ph.page_type == .btree_internal) {
        std.debug.print("  rightmost_child={d}\n", .{bs.getRightmostChild(buf)});
    }
}

// ── Cell printers ─────────────────────────────────────────────────────────────

fn printRowidLeafCell(buf: *const [t.PAGE_SIZE]u8, slot: u16, offset: u16, cell_area_end: u16) void {
    if (@as(u32, offset) + 10 > @as(u32, cell_area_end)) {
        std.debug.print("  slot {d:2}  off={d}  !! offset out of bounds\n", .{ slot, offset });
        return;
    }
    const rowid = std.mem.readInt(u64, buf[offset..][0..8], .little);
    const raw_len = std.mem.readInt(u16, buf[offset + 8 ..][0..2], .little);
    const is_overflow = (raw_len & 0x8000) != 0;
    const data_len: u16 = raw_len & 0x7FFF;
    const size: u16 = if (is_overflow) 14 else 10 + data_len;
    if (is_overflow) {
        const ov_page = std.mem.readInt(u32, buf[offset + 10 ..][0..4], .little);
        std.debug.print("  slot {d:2}  off={d}  size={d}  key={d}  [overflow page={d} len={d}]\n", .{ slot, offset, size, rowid, ov_page, data_len });
    } else {
        std.debug.print("  slot {d:2}  off={d}  size={d}  key={d}  inline_len={d}\n", .{ slot, offset, size, rowid, data_len });
    }
}

fn printRowidInternalCell(buf: *const [t.PAGE_SIZE]u8, slot: u16, offset: u16, cell_area_end: u16) void {
    if (@as(u32, offset) + 12 > @as(u32, cell_area_end)) {
        std.debug.print("  slot {d:2}  off={d}  !! offset out of bounds\n", .{ slot, offset });
        return;
    }
    const left_child = std.mem.readInt(u32, buf[offset..][0..4], .little);
    const sep = std.mem.readInt(u64, buf[offset + 4 ..][0..8], .little);
    std.debug.print("  slot {d:2}  off={d}  size=12  left_child={d}  key={d}\n", .{ slot, offset, left_child, sep });
}

fn printIndexLeafCell(buf: *const [t.PAGE_SIZE]u8, slot: u16, offset: u16, cell_area_end: u16) void {
    if (@as(u32, offset) + 2 > @as(u32, cell_area_end)) {
        std.debug.print("  slot {d:2}  off={d}  !! offset out of bounds\n", .{ slot, offset });
        return;
    }
    const key_len = std.mem.readInt(u16, buf[offset..][0..2], .little);
    const size: u16 = 2 + key_len;
    if (@as(u32, offset) + @as(u32, size) > @as(u32, cell_area_end)) {
        std.debug.print("  slot {d:2}  off={d}  size={d}  !! cell exceeds page bounds\n", .{ slot, offset, size });
        return;
    }
    std.debug.print("  slot {d:2}  off={d}  size={d}  key=", .{ slot, offset, size });
    printHex(buf[offset + 2 ..][0..key_len]);
    std.debug.print("\n", .{});
}

fn printIndexInternalCell(buf: *const [t.PAGE_SIZE]u8, slot: u16, offset: u16, cell_area_end: u16) void {
    if (@as(u32, offset) + 6 > @as(u32, cell_area_end)) {
        std.debug.print("  slot {d:2}  off={d}  !! offset out of bounds\n", .{ slot, offset });
        return;
    }
    const left_child = std.mem.readInt(u32, buf[offset..][0..4], .little);
    const key_len = std.mem.readInt(u16, buf[offset + 4 ..][0..2], .little);
    const size: u16 = 6 + key_len;
    if (@as(u32, offset) + @as(u32, size) > @as(u32, cell_area_end)) {
        std.debug.print("  slot {d:2}  off={d}  size={d}  !! cell exceeds page bounds\n", .{ slot, offset, size });
        return;
    }
    std.debug.print("  slot {d:2}  off={d}  size={d}  left_child={d}  key=", .{ slot, offset, size, left_child });
    printHex(buf[offset + 6 ..][0..key_len]);
    std.debug.print("\n", .{});
}

fn printHex(bytes: []const u8) void {
    for (bytes) |b| std.debug.print("{x:0>2}", .{b});
}
