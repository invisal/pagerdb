const std = @import("std");
const t = @import("../types.zig");
const WAL = @import("../pager/wal.zig").WAL;
const RECORD_HEADER_SIZE = @import("../pager/wal.zig").RECORD_HEADER_SIZE;
const InMemoryPager = @import("../pager/memory.zig").InMemoryPager;
const DiskIo = @import("../io/disk_io.zig").DiskIo;

const Dir = std.Io.Dir;

// Creates a temp-file-backed WAL initialized to initial_lsn and ready to
// receive records.
fn makeWAL(alloc: std.mem.Allocator, std_io: std.Io, path: []const u8, initial_lsn: u64) !WAL {
    var disk_io = DiskIo.init(alloc, std_io);
    var wal = try WAL.create(alloc, disk_io.io(), path);
    wal.next_lsn = initial_lsn;
    try wal.reset(); // writes the 8-byte next_lsn header
    return wal;
}

// Returns a zeroed page with the given LSN stamped in the PageHeader.
fn pageWithLSN(lsn: u64) [t.PAGE_SIZE]u8 {
    var page = std.mem.zeroes([t.PAGE_SIZE]u8);
    std.mem.writeInt(u64, page[@offsetOf(t.PageHeader, "lsn")..][0..8], lsn, .little);
    return page;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "empty WAL file returns immediately without touching the pager" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const wal_path = "/tmp/test_recovery_empty_wal.wal";
    defer Dir.deleteFile(.cwd(), io, wal_path) catch {};

    // Create a 0-byte WAL file — never initialized with reset().
    // reader.open() will hit EndOfStream and recovery returns early.
    var disk_io = DiskIo.init(alloc, io);
    const file = try disk_io.io().createFile(wal_path);
    var wal = WAL{ .file = file, .next_lsn = 0, .buffer = .empty, .alloc = alloc, .offset = 0 };
    defer {
        wal.file.close();
        wal.buffer.deinit(alloc);
    }

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();

    try wal.recover(&pager, alloc);

    // Pager is untouched — only the initial page 0 created by InMemoryPager exists.
    try std.testing.expectEqual(@as(u32, 1), pager.total_pages);
}

test "recovery with no WAL records leaves next_lsn unchanged" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const wal_path = "/tmp/test_recovery_no_records.wal";
    defer Dir.deleteFile(.cwd(), io, wal_path) catch {};

    var wal = try makeWAL(alloc, io, wal_path, 42);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();

    try wal.recover(&pager, alloc);

    // next_lsn is restored from the WAL header (42) and stays there.
    try std.testing.expectEqual(@as(u64, 42), wal.next_lsn);
}

test "recovery applies WAL record to a stale page" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const wal_path = "/tmp/test_recovery_stale_page.wal";
    defer Dir.deleteFile(.cwd(), io, wal_path) catch {};

    // WAL starts at LSN=10; the first appended record has LSN=10.
    var wal = try makeWAL(alloc, io, wal_path, 10);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();

    // Page 1 LSN=0 is behind record LSN=10, so the record must be applied.
    try pager.writePage(1, &pageWithLSN(0), &.{});

    _ = try wal.append(1, 16, "hello");
    try wal.appendCommit();
    try wal.flush();

    try wal.recover(&pager, alloc);

    var result: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(1, &result);
    try std.testing.expectEqualSlices(u8, "hello", result[16..21]);
    try std.testing.expectEqual(@as(u64, 10), std.mem.readInt(u64, result[@offsetOf(t.PageHeader, "lsn")..][0..8], .little));
}

test "recovery skips a page whose LSN is already ahead of the WAL record" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const wal_path = "/tmp/test_recovery_skip_fresh.wal";
    defer Dir.deleteFile(.cwd(), io, wal_path) catch {};

    // Record will have LSN=5; page has LSN=20 — already ahead.
    var wal = try makeWAL(alloc, io, wal_path, 5);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();

    var page = pageWithLSN(20);
    page[16] = 0xAA; // sentinel: must not be overwritten
    try pager.writePage(1, &page, &.{});

    _ = try wal.append(1, 16, "hello");
    try wal.flush();

    try wal.recover(&pager, alloc);

    var result: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(1, &result);
    try std.testing.expectEqual(@as(u8, 0xAA), result[16]);
    try std.testing.expectEqual(@as(u64, 20), std.mem.readInt(u64, result[@offsetOf(t.PageHeader, "lsn")..][0..8], .little));
}

test "recovery patches stale pages and skips fresh ones in the same run" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const wal_path = "/tmp/test_recovery_mixed.wal";
    defer Dir.deleteFile(.cwd(), io, wal_path) catch {};

    // Records: LSN=10 for page 1, LSN=32 for page 2 (10+18+4).
    var wal = try makeWAL(alloc, io, wal_path, 10);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();

    try pager.writePage(1, &pageWithLSN(0), &.{}); // stale  → should be patched
    var page2 = pageWithLSN(50);
    page2[16] = 0xBB; // sentinel
    try pager.writePage(2, &page2, &.{}); // LSN=50 > 32 → should be skipped

    _ = try wal.append(1, 16, "aaaa"); // LSN=10
    _ = try wal.append(2, 16, "bbbb"); // LSN=32
    try wal.appendCommit();
    try wal.flush();

    try wal.recover(&pager, alloc);

    var r1: [t.PAGE_SIZE]u8 = undefined;
    var r2: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(1, &r1);
    try pager.readPage(2, &r2);

    try std.testing.expectEqualSlices(u8, "aaaa", r1[16..20]);
    try std.testing.expectEqual(@as(u8, 0xBB), r2[16]); // sentinel unchanged
}

test "recovery advances next_lsn past the last WAL record" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const wal_path = "/tmp/test_recovery_next_lsn.wal";
    defer Dir.deleteFile(.cwd(), io, wal_path) catch {};

    var wal = try makeWAL(alloc, io, wal_path, 0);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();
    try pager.writePage(1, &pageWithLSN(0), &.{});

    const payload = "abcd"; // 4 bytes; record LSN=0
    _ = try wal.append(1, 16, payload);
    try wal.appendCommit();
    try wal.flush();

    try wal.recover(&pager, alloc);

    // next_lsn = RECORD_HEADER_SIZE(23) + payload.len(4) + commit byte(1) = 28
    const expected: u64 = RECORD_HEADER_SIZE + payload.len + 1;
    try std.testing.expectEqual(expected, wal.next_lsn);
}

test "recovery truncates WAL to a header-only file after completing" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const wal_path = "/tmp/test_recovery_wal_reset.wal";
    defer Dir.deleteFile(.cwd(), io, wal_path) catch {};

    var wal = try makeWAL(alloc, io, wal_path, 10);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();
    try pager.writePage(1, &pageWithLSN(0), &.{});

    _ = try wal.append(1, 16, "test");
    try wal.flush();

    try wal.recover(&pager, alloc);

    // WAL file must contain exactly the 8-byte next_lsn header.
    const file_len = try wal.file.length();
    try std.testing.expectEqual(@as(u64, @sizeOf(u64)), file_len);

    // The stored value must match the in-memory next_lsn.
    var lsn_buf: [8]u8 = undefined;
    _ = try wal.file.readAt(&lsn_buf, 0);
    const stored = std.mem.readInt(u64, &lsn_buf, .little);
    try std.testing.expectEqual(wal.next_lsn, stored);
}

test "recovery returns CorruptWAL when record write range overflows the page" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const wal_path = "/tmp/test_recovery_corrupt_overflow.wal";
    defer Dir.deleteFile(.cwd(), io, wal_path) catch {};

    var wal = try makeWAL(alloc, io, wal_path, 10);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();
    try pager.writePage(1, &pageWithLSN(0), &.{});

    // offset=8100 + payload_len=200 = 8300 > PAGE_SIZE(8192)
    const payload = [_]u8{0} ** 200;
    _ = try wal.append(1, 8100, &payload);
    try wal.appendCommit();
    try wal.flush();

    try std.testing.expectError(error.CorruptWAL, wal.recover(&pager, alloc));
}

test "recovery returns CorruptWAL when the WAL file is truncated mid-record" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const wal_path = "/tmp/test_recovery_corrupt_truncated.wal";
    defer Dir.deleteFile(.cwd(), io, wal_path) catch {};

    var wal = try makeWAL(alloc, io, wal_path, 0);
    defer wal.deinit();

    // Write only the length and lsn fields of a record, then stop.
    // This simulates a crash that occurred mid-write.
    // When recovery reads this, it will hit EndOfStream trying to read page_id.
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, 4, .little);
    try wal.buffer.appendSlice(alloc, &len_buf);

    var lsn_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &lsn_buf, 0, .little);
    try wal.buffer.appendSlice(alloc, &lsn_buf);

    try wal.flush(); // file: [8-byte header][4-byte length][8-byte lsn] — no page_id/offset/payload

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();

    try std.testing.expectError(error.CorruptWAL, wal.recover(&pager, alloc));
}
