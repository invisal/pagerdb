const std = @import("std");
const WAL = @import("../pager/wal.zig").WAL;
const segmentPath = @import("../pager/wal.zig").segmentPath;
const Record = @import("../pager//wal.zig").Record;
const RECORD_HEADER_SIZE = @import("../pager/wal.zig").RECORD_HEADER_SIZE;
const DiskIo = @import("../io/disk_io.zig").DiskIo;

const Dir = std.Io.Dir;

// Delete WAL segments 1..max_seg and the checkpoint file for base_path.
fn cleanup(alloc: std.mem.Allocator, std_io: std.Io, base: []const u8, max_seg: u32) void {
    var seg: u32 = 1;
    while (seg <= max_seg) : (seg += 1) {
        const p = segmentPath(base, seg, alloc) catch continue;
        defer alloc.free(p);
        Dir.deleteFile(.cwd(), std_io, p) catch {};
    }
    const ckpt = std.fmt.allocPrint(alloc, "{s}.ckpt", .{base}) catch return;
    defer alloc.free(ckpt);
    Dir.deleteFile(.cwd(), std_io, ckpt) catch {};
}

test "WAL.open on missing base creates segment 1 with lsn=0" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const base = "/tmp/wal_test_missing";
    defer cleanup(alloc, io, base, 3);

    var disk_io = DiskIo.init(alloc, io);
    var wal = try WAL.open(alloc, disk_io.io(), base);
    defer wal.deinit();

    try std.testing.expectEqual(@as(u64, 0), wal.next_lsn);

    var reader = wal.reader();
    try std.testing.expect(try reader.readHeader() == 0);
    try std.testing.expect(try reader.next(alloc) == null);
}

test "WAL.open on empty segment file initializes with lsn=0" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const base = "/tmp/wal_test_empty";
    defer cleanup(alloc, io, base, 3);

    // Create an empty segment 1 file (no header) to test the edge case.
    const seg = try segmentPath(base, 1, alloc);
    defer alloc.free(seg);
    var disk_io = DiskIo.init(alloc, io);
    const empty = try disk_io.io().createFile(seg);
    empty.close();

    var disk_io2 = DiskIo.init(alloc, io);
    var wal = try WAL.open(alloc, disk_io2.io(), base);
    defer wal.deinit();

    try std.testing.expectEqual(@as(u64, 0), wal.next_lsn);

    var reader = wal.reader();
    try std.testing.expect(try reader.readHeader() == 0);
    try std.testing.expect(try reader.next(alloc) == null);
}

test "WAL records can be read after flush" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const base = "/tmp/wal_records";
    defer cleanup(alloc, io, base, 3);

    var lsn_list: [2]u64 = undefined;
    {
        var disk_io = DiskIo.init(alloc, io);
        var wal = try WAL.open(alloc, disk_io.io(), base);
        defer wal.deinit();

        lsn_list[0] = try wal.append(1, 10, "abc");
        lsn_list[1] = try wal.append(2, 18, "cde");
        try wal.flush();
    }

    // Reopen WAL (segment 1 still active, no checkpoint yet) and read records.
    var disk_io2 = DiskIo.init(alloc, io);
    var wal = try WAL.open(alloc, disk_io2.io(), base);
    defer wal.deinit();

    var reader = wal.reader();
    try std.testing.expect(try reader.readHeader() == 0);

    var arena = std.heap.ArenaAllocator.init(alloc);
    const record_alloc = arena.allocator();
    defer arena.deinit();

    try std.testing.expectEqualDeep(Record{ .lsn = lsn_list[0], .offset = 10, .page_id = 1, .payload = "abc" }, (try reader.next(record_alloc)).?.data);
    try std.testing.expectEqualDeep(Record{ .lsn = lsn_list[1], .offset = 18, .page_id = 2, .payload = "cde" }, (try reader.next(record_alloc)).?.data);
    try std.testing.expect(try reader.next(record_alloc) == null);
}

test "WAL reader returns InvalidChecksum on corrupted payload" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const base = "/tmp/wal_checksum";
    defer cleanup(alloc, io, base, 3);

    {
        var disk_io = DiskIo.init(alloc, io);
        var wal = try WAL.open(alloc, disk_io.io(), base);
        defer wal.deinit();
        _ = try wal.append(1, 0, "abc");
        try wal.flush();
    }

    // Flip the first byte of the payload on disk.
    // Layout: [segment header: 8 bytes][record header: RECORD_HEADER_SIZE bytes][payload...]
    const payload_offset = 8 + RECORD_HEADER_SIZE;
    const seg = try segmentPath(base, 1, alloc);
    defer alloc.free(seg);
    {
        var disk_io = DiskIo.init(alloc, io);
        const file = try disk_io.io().openFile(seg);
        defer file.close();
        try file.writeAt(&[_]u8{0xFF}, payload_offset);
    }

    var disk_io2 = DiskIo.init(alloc, io);
    var wal = try WAL.open(alloc, disk_io2.io(), base);
    defer wal.deinit();

    var reader = wal.reader();
    _ = try reader.readHeader();
    try std.testing.expectError(error.InvalidChecksum, reader.next(alloc));
}

test "WAL segment header persists next_lsn across reopens" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const base = "/tmp/wal_lsn_continue";
    defer cleanup(alloc, io, base, 3);

    // Open WAL, set LSN 100, rewrite segment header to persist it.
    {
        var disk_io = DiskIo.init(alloc, io);
        var wal = try WAL.open(alloc, disk_io.io(), base);
        defer wal.deinit();
        wal.next_lsn = 100;
        try wal.writeSegmentHeader();
    }

    // Reopen and verify the header reads back LSN 100.
    var disk_io2 = DiskIo.init(alloc, io);
    var wal = try WAL.open(alloc, disk_io2.io(), base);
    defer wal.deinit();

    var reader = wal.reader();
    try std.testing.expect(try reader.readHeader() == 100);
}
