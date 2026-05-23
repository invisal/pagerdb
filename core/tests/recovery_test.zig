const std = @import("std");
const t = @import("../types.zig");
const WAL = @import("../pager/wal.zig").WAL;
const Checkpoint = @import("../pager/wal.zig").Checkpoint;
const segmentPath = @import("../pager/wal.zig").segmentPath;
const RECORD_HEADER_SIZE = @import("../pager/wal.zig").RECORD_HEADER_SIZE;
const COMMIT_SIZE = @import("../pager/wal.zig").COMMIT_SIZE;
const FPW_SIZE = @import("../pager/wal.zig").FPW_SIZE;
const InMemoryPager = @import("../pager/memory.zig").InMemoryPager;
const DiskIo = @import("../io/disk_io.zig").DiskIo;
const Io = @import("../io/io.zig").Io;

const Dir = std.Io.Dir;

// Creates a WAL at segment 1 of base_path, initialized to initial_lsn.
// Caller must keep disk_io alive for the lifetime of the returned WAL since
// the WAL stores an Io that holds a pointer into disk_io.
fn makeWAL(alloc: std.mem.Allocator, io: Io, base_path: []const u8, initial_lsn: u64) !WAL {
    var wal = try WAL.create(alloc, io, base_path);
    wal.next_lsn = initial_lsn;
    // Rewrite the segment header with the new initial_lsn.
    try wal.writeSegmentHeader();
    return wal;
}

// Delete all WAL-related files for a base path: segments 1..max_seg and the
// checkpoint file.  Used in defer blocks to clean up after each test.
fn cleanupWAL(alloc: std.mem.Allocator, std_io: std.Io, base_path: []const u8, max_seg: u32) void {
    var seg: u32 = 1;
    while (seg <= max_seg) : (seg += 1) {
        const p = segmentPath(base_path, seg, alloc) catch continue;
        defer alloc.free(p);
        Dir.deleteFile(.cwd(), std_io, p) catch {};
    }
    const ckpt = std.fmt.allocPrint(alloc, "{s}.ckpt", .{base_path}) catch return;
    defer alloc.free(ckpt);
    Dir.deleteFile(.cwd(), std_io, ckpt) catch {};
}

// Returns a zeroed page with the given LSN stamped in the PageHeader.
fn pageWithLSN(lsn: u64) [t.PAGE_SIZE]u8 {
    var page = std.mem.zeroes([t.PAGE_SIZE]u8);
    std.mem.writeInt(u64, page[@offsetOf(t.PageHeader, "lsn")..][0..8], lsn, .little);
    return page;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "empty WAL segment returns immediately without touching the pager" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const base = "/tmp/test_recovery_empty_wal";
    defer cleanupWAL(alloc, io, base, 3);

    var disk_io = DiskIo.init(alloc, io);
    // Create a valid-but-empty WAL (just the 8-byte header, no records).
    var wal = try WAL.create(alloc, disk_io.io(), base);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();

    try wal.recover(&pager, alloc);

    // Pager is untouched — only the initial page 0 created by InMemoryPager exists.
    try std.testing.expectEqual(@as(u32, 1), pager.total_pages);
}

test "recovery with no WAL records leaves next_lsn unchanged" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const base = "/tmp/test_recovery_no_records";
    defer cleanupWAL(alloc, io, base, 3);

    var disk_io = DiskIo.init(alloc, io);
    var wal = try makeWAL(alloc, disk_io.io(), base, 42);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();

    try wal.recover(&pager, alloc);

    // next_lsn is restored from the segment header (42) and stays there.
    try std.testing.expectEqual(@as(u64, 42), wal.next_lsn);
}

test "recovery applies WAL record to a stale page" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const base = "/tmp/test_recovery_stale_page";
    defer cleanupWAL(alloc, io, base, 3);

    // WAL starts at LSN=10; the first appended record has LSN=10.
    var disk_io = DiskIo.init(alloc, io);
    var wal = try makeWAL(alloc, disk_io.io(), base, 10);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();

    // Page 1 LSN=0 is behind record LSN=10, so the record must be applied.
    try pager.writePage(1, &pageWithLSN(0), &.{});

    _ = try wal.append(1, 16, "hello");
    try wal.appendCommit(0);
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
    const base = "/tmp/test_recovery_skip_fresh";
    defer cleanupWAL(alloc, io, base, 3);

    // Record will have LSN=5; page has LSN=20 — already ahead.
    var disk_io = DiskIo.init(alloc, io);
    var wal = try makeWAL(alloc, disk_io.io(), base, 5);
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
    const base = "/tmp/test_recovery_mixed";
    defer cleanupWAL(alloc, io, base, 3);

    // Records: LSN=10 for page 1, LSN=32 for page 2 (10+18+4).
    var disk_io = DiskIo.init(alloc, io);
    var wal = try makeWAL(alloc, disk_io.io(), base, 10);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();

    try pager.writePage(1, &pageWithLSN(0), &.{}); // stale  → should be patched
    var page2 = pageWithLSN(50);
    page2[16] = 0xBB; // sentinel
    try pager.writePage(2, &page2, &.{}); // LSN=50 > 32 → should be skipped

    _ = try wal.append(1, 16, "aaaa"); // LSN=10
    _ = try wal.append(2, 16, "bbbb"); // LSN=32
    try wal.appendCommit(0);
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
    const base = "/tmp/test_recovery_next_lsn";
    defer cleanupWAL(alloc, io, base, 3);

    var disk_io = DiskIo.init(alloc, io);
    var wal = try makeWAL(alloc, disk_io.io(), base, 0);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();
    try pager.writePage(1, &pageWithLSN(0), &.{});

    const payload = "abcd"; // 4 bytes; record LSN=0
    _ = try wal.append(1, 16, payload);
    try wal.appendCommit(0);
    try wal.flush();

    try wal.recover(&pager, alloc);

    // next_lsn = RECORD_HEADER_SIZE(23) + payload.len(4) + COMMIT_SIZE(9) = 36
    const expected: u64 = RECORD_HEADER_SIZE + payload.len + COMMIT_SIZE;
    try std.testing.expectEqual(expected, wal.next_lsn);
}

test "after recovery the new segment has only an 8-byte header" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const base = "/tmp/test_recovery_wal_rotate";
    defer cleanupWAL(alloc, io, base, 3);

    var disk_io = DiskIo.init(alloc, io);
    var wal = try makeWAL(alloc, disk_io.io(), base, 10);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();
    try pager.writePage(1, &pageWithLSN(0), &.{});

    _ = try wal.append(1, 16, "test");
    try wal.flush();

    try wal.recover(&pager, alloc);

    // After recovery, WAL rotated to segment 2.  That segment has only the
    // 8-byte next_lsn header; no records yet.
    const file_len = try wal.file.length();
    try std.testing.expectEqual(@as(u64, @sizeOf(u64)), file_len);

    // The stored value must match the in-memory next_lsn.
    var lsn_buf: [8]u8 = undefined;
    _ = try wal.file.readAt(&lsn_buf, 0);
    const stored = std.mem.readInt(u64, &lsn_buf, .little);
    try std.testing.expectEqual(wal.next_lsn, stored);

    // A checkpoint file must exist recording the new segment.
    const ckpt = try Checkpoint.read(wal.io, wal.base_path, alloc);
    try std.testing.expectEqual(@as(u32, 2), ckpt.segment_num);
    try std.testing.expectEqual(wal.next_lsn, ckpt.lsn);
}

test "recovery returns CorruptWAL when record write range overflows the page" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const base = "/tmp/test_recovery_corrupt_overflow";
    defer cleanupWAL(alloc, io, base, 3);

    var disk_io = DiskIo.init(alloc, io);
    var wal = try makeWAL(alloc, disk_io.io(), base, 10);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();
    try pager.writePage(1, &pageWithLSN(0), &.{});

    // offset=8100 + payload_len=200 = 8300 > PAGE_SIZE(8192)
    const payload = [_]u8{0} ** 200;
    _ = try wal.append(1, 8100, &payload);
    try wal.appendCommit(0);
    try wal.flush();

    try std.testing.expectError(error.CorruptWAL, wal.recover(&pager, alloc));
}

test "recovery returns CorruptWAL when the WAL segment is truncated mid-record" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const base = "/tmp/test_recovery_corrupt_truncated";
    defer cleanupWAL(alloc, io, base, 3);

    var disk_io = DiskIo.init(alloc, io);
    var wal = try makeWAL(alloc, disk_io.io(), base, 0);
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

test "FPW record is applied when page LSN is behind the FPW LSN" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const base = "/tmp/test_fpw_stale";
    defer cleanupWAL(alloc, io, base, 3);

    // WAL starts at LSN=10; the FPW record will get LSN=10.
    var disk_io = DiskIo.init(alloc, io);
    var wal = try makeWAL(alloc, disk_io.io(), base, 10);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();

    // Page 1 is stale: lsn=0 < fpw_lsn=10 → FPW must be applied.
    try pager.writePage(1, &pageWithLSN(0), &.{});

    // Build the FPW payload: a known page image with a sentinel byte.
    var fpw_image = pageWithLSN(0);
    fpw_image[200] = 0xAB;
    _ = try wal.appendFullPage(1, &fpw_image);
    try wal.appendCommit(0);
    try wal.flush();

    try wal.recover(&pager, alloc);

    var result: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(1, &result);
    try std.testing.expectEqual(@as(u8, 0xAB), result[200]);
}

test "FPW record is skipped when page LSN is already ahead of FPW LSN" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const base = "/tmp/test_fpw_fresh";
    defer cleanupWAL(alloc, io, base, 3);

    var disk_io = DiskIo.init(alloc, io);
    var wal = try makeWAL(alloc, disk_io.io(), base, 5);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();

    // Page 1 has lsn=999 — well ahead of fpw_lsn=5.  Sentinel must survive.
    var page = pageWithLSN(999);
    page[200] = 0xCC;
    try pager.writePage(1, &page, &.{});

    var fpw_image = pageWithLSN(0);
    fpw_image[200] = 0xDD; // would overwrite sentinel if wrongly applied
    _ = try wal.appendFullPage(1, &fpw_image);
    try wal.appendCommit(0);
    try wal.flush();

    try wal.recover(&pager, alloc);

    var result: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(1, &result);
    try std.testing.expectEqual(@as(u8, 0xCC), result[200]); // sentinel unchanged
}

test "FPW followed by a delta: delta is applied on top of FPW base" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const base = "/tmp/test_fpw_with_delta";
    defer cleanupWAL(alloc, io, base, 3);

    // FPW gets LSN=10, delta gets LSN=10+FPW_SIZE.
    var disk_io = DiskIo.init(alloc, io);
    var wal = try makeWAL(alloc, disk_io.io(), base, 10);
    defer wal.deinit();

    var pager = try InMemoryPager.create(alloc);
    defer pager.close();
    try pager.writePage(1, &pageWithLSN(0), &.{});

    // FPW contains the pre-delta image.
    const fpw_image = pageWithLSN(0);
    _ = try wal.appendFullPage(1, &fpw_image);
    // Delta written on top of the FPW base.
    _ = try wal.append(1, 100, "hello");
    try wal.appendCommit(0);
    try wal.flush();

    try wal.recover(&pager, alloc);

    var result: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(1, &result);

    // Delta bytes must be present.
    try std.testing.expectEqualSlices(u8, "hello", result[100..105]);

    // next_lsn must account for FPW + data record + commit.
    const expected_lsn: u64 = FPW_SIZE + RECORD_HEADER_SIZE + "hello".len + COMMIT_SIZE;
    try std.testing.expectEqual(expected_lsn, wal.next_lsn);
}
