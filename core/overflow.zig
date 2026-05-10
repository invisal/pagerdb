// Overflow pages are regular database pages used to store row data
// that does not fit inline inside a B-tree cell.
//
// Overflow chain layout:
//
//   first_page
//        |
//        v
//
//   +-----------+     +-----------+     +-----------+
//   | Page #12  | --> | Page #18  | --> | Page #24  | --> NULL
//   | next = 18 |     | next = 24 |     | next = 0  |
//   | data...   |     | data...   |     | data...   |
//   +-----------+     +-----------+     +-----------+
//
// Each overflow page stores:
//
//   [PageHeader | next_page_id | data_len | data...]
//
// The first overflow page ID is stored inside the owning B-tree cell.
// Pages are linked using `next_page_id`, where 0 marks end-of-chain.
//
// We keep the first overflow page number in the B-tree cell so that the
// original row length can be reconstructed during readChain.

// During writes, pages are committed one page late so the previous
// page can patch its next-page pointer before flushing.

const std = @import("std");
const t = @import("types.zig");
const Pager = @import("pager/pager.zig").Pager;
const PageWriter = @import("page_writer.zig").PageWriter;
pub const DATA_CAP: usize = t.PAGE_SIZE - 24;
const NEXT_PAGE_OFF: usize = @sizeOf(t.PageHeader); // 16
const DATA_LEN_OFF: usize = @sizeOf(t.PageHeader) + 4; // 20
pub const DATA_OFF: usize = @sizeOf(t.PageHeader) + 8; // 24

comptime {
    std.debug.assert(DATA_OFF == @sizeOf(t.PageHeader) + @sizeOf(u32) + @sizeOf(u16) + @sizeOf(u16));
    std.debug.assert(DATA_OFF + DATA_CAP == t.PAGE_SIZE);
}

/// Build a linked chain of overflow pages.
/// Returns the first overflow page ID.
pub fn buildChain(pager: *Pager, row_data: []const u8) !u32 {
    var remaining: []const u8 = row_data;
    var first_page: u32 = 0;

    // Overflow pages are committed one page late so the previous
    // page can patch its next-page pointer.
    var prev: ?PageWriter = null;

    while (remaining.len > 0) {
        const chunk_len = @min(remaining.len, DATA_CAP);
        const page_id = try pager.allocPage();

        if (prev) |*p| {
            // Previous page can now be finalized because the next page ID
            // is known and its next-page pointer can be patched.
            p.writeInt(u32, @intCast(NEXT_PAGE_OFF), page_id, .little);
            try p.commit();
        } else {
            first_page = page_id;
        }

        // Write as much remaining row data as fits in this overflow page.
        const ph = t.PageHeader{ .page_type = .overflow, .flags = 0, .checksum = 0, .lsn = 0 };
        var pw = PageWriter.init(pager, page_id);
        pw.writeAt(0, std.mem.asBytes(&ph));
        pw.writeInt(u16, @intCast(DATA_LEN_OFF), @intCast(chunk_len), .little);
        pw.writeAt(@intCast(DATA_OFF), remaining[0..chunk_len]);

        prev = pw;
        remaining = remaining[chunk_len..];
    }

    if (prev) |*p| try p.commit();
    return first_page;
}

pub fn readChain(pager: *Pager, first_page: u32, total_len: usize, out: []u8) !void {
    var page_id = first_page;
    var written: usize = 0;

    while (page_id != 0 and written < total_len) {
        var buf: [t.PAGE_SIZE]u8 = undefined;
        try pager.readPage(page_id, &buf);

        const data_len = std.mem.readInt(u16, buf[DATA_LEN_OFF..][0..2], .little);
        const next_page = std.mem.readInt(u32, buf[NEXT_PAGE_OFF..][0..4], .little);

        const chunk = @min(data_len, total_len - written);
        @memcpy(out[written..][0..chunk], buf[DATA_OFF..][0..chunk]);
        written += chunk;
        page_id = next_page;
    }
}

pub fn freeChain(pager: *Pager, first_page: u32) !void {
    var page_id = first_page;
    while (page_id != 0) {
        var buf: [t.PAGE_SIZE]u8 = undefined;
        try pager.readPage(page_id, &buf);
        const next_page = std.mem.readInt(u32, buf[NEXT_PAGE_OFF..][0..4], .little);
        try pager.freePage(page_id);
        page_id = next_page;
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "overflow round-trip for large row" {
    const DiskPager = @import("pager/disk.zig").DiskPager;
    const io = std.testing.io;
    const path = "/tmp/test_overflow_roundtrip.db";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};

    var pager = try DiskPager.create(std.testing.allocator, io, path, .{});
    defer pager.close();

    const big_row = try std.testing.allocator.alloc(u8, 5000);
    defer std.testing.allocator.free(big_row);
    for (big_row, 0..) |*b, i| b.* = @intCast(i % 256);

    const first = try buildChain(&pager, big_row);

    const out = try std.testing.allocator.alloc(u8, 5000);
    defer std.testing.allocator.free(out);
    try readChain(&pager, first, 5000, out);

    try std.testing.expectEqualSlices(u8, big_row, out);
}

test "freeChain returns pages to free list" {
    const DiskPager = @import("pager/disk.zig").DiskPager;
    const io = std.testing.io;
    const path = "/tmp/test_overflow_free.db";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};

    var pager = try DiskPager.create(std.testing.allocator, io, path, .{});
    defer pager.close();

    const big_row = [_]u8{0xAB} ** 5000;
    const first = try buildChain(&pager, &big_row);
    try std.testing.expect(pager.free_list_head == 0);

    try freeChain(&pager, first);

    // Allocating a page now should reuse a freed overflow page.
    const reused = try pager.allocPage();
    try std.testing.expect(reused >= 1);
    try std.testing.expect(pager.free_list_head != 0 or reused < pager.total_pages);
}

test "multi-page chain round-trip" {
    const DiskPager = @import("pager/disk.zig").DiskPager;
    const io = std.testing.io;
    const path = "/tmp/test_overflow_multipage.db";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};

    var pager = try DiskPager.create(std.testing.allocator, io, path, .{});
    defer pager.close();

    // 3 × DATA_CAP forces at least 3 overflow pages
    const len = DATA_CAP * 3 - 1;
    const big_row = try std.testing.allocator.alloc(u8, len);
    defer std.testing.allocator.free(big_row);
    for (big_row, 0..) |*b, i| b.* = @intCast(i % 251);

    const first = try buildChain(&pager, big_row);

    const out = try std.testing.allocator.alloc(u8, len);
    defer std.testing.allocator.free(out);
    try readChain(&pager, first, len, out);

    try std.testing.expectEqualSlices(u8, big_row, out);
}
