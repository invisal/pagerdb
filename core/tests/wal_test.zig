const std = @import("std");
const WAL = @import("../pager/wal.zig").WAL;
const Record = @import("../pager//wal.zig").Record;
const RECORD_HEADER_SIZE = @import("../pager/wal.zig").RECORD_HEADER_SIZE;
const DiskIo = @import("../io/disk_io.zig").DiskIo;

const Dir = std.Io.Dir;

test "WAL.open on missing file initializes with lsn=0 and no entries" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const path = "/tmp/wal_test_missing.wal";
    Dir.deleteFile(.cwd(), io, path) catch {};

    var disk_io = DiskIo.init(alloc, io);
    var wal = try WAL.open(disk_io.io(), path, alloc);
    defer wal.deinit();

    try std.testing.expectEqual(0, wal.next_lsn);

    var reader = wal.reader();
    try std.testing.expect(try reader.readHeader() == 0);
    try std.testing.expect(try reader.next(alloc) == null);
}

test "WAL.open on empty file initializes with lsn=0 and no entries" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const path = "/tmp/wal_test_empty.wal";
    Dir.deleteFile(.cwd(), io, path) catch {};

    // Create an empty file (no WAL header) to test edge-case handling.
    var disk_io = DiskIo.init(alloc, io);
    const empty = try disk_io.io().createFile(path);
    empty.close();

    var disk_io2 = DiskIo.init(alloc, io);
    var wal = try WAL.open(disk_io2.io(), path, alloc);
    defer wal.deinit();

    try std.testing.expectEqual(0, wal.next_lsn);

    var reader = wal.reader();
    try std.testing.expect(try reader.readHeader() == 0);
    try std.testing.expect(try reader.next(alloc) == null);
}

test "WAL records can be read after flush" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const path = "/tmp/wal_records.wal";
    Dir.deleteFile(.cwd(), io, path) catch {};

    // Write some WAL records and flush
    var lsn_list: [2]u64 = undefined;
    {
        var disk_io = DiskIo.init(alloc, io);
        var wal = try WAL.open(disk_io.io(), path, alloc);
        defer wal.deinit();

        lsn_list[0] = try wal.append(1, 10, "abc");
        lsn_list[1] = try wal.append(2, 18, "cde");
        try wal.flush();
    }

    // Reopen WAL and replay records
    var disk_io2 = DiskIo.init(alloc, io);
    var wal = try WAL.open(disk_io2.io(), path, alloc);
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

    const path = "/tmp/wal_checksum.wal";
    Dir.deleteFile(.cwd(), io, path) catch {};

    {
        var disk_io = DiskIo.init(alloc, io);
        var wal = try WAL.open(disk_io.io(), path, alloc);
        defer wal.deinit();
        _ = try wal.append(1, 0, "abc");
        try wal.flush();
    }

    // Flip the first byte of the payload on disk.
    // Layout: [file header: 8 bytes][record header: RECORD_HEADER_SIZE bytes][payload...]
    const payload_offset = 8 + RECORD_HEADER_SIZE;
    {
        var disk_io = DiskIo.init(alloc, io);
        const file = try disk_io.io().openFile(path);
        defer file.close();
        try file.writeAt(&[_]u8{0xFF}, payload_offset);
    }

    var disk_io2 = DiskIo.init(alloc, io);
    var wal = try WAL.open(disk_io2.io(), path, alloc);
    defer wal.deinit();

    var reader = wal.reader();
    _ = try reader.readHeader();
    try std.testing.expectError(error.InvalidChecksum, reader.next(alloc));
}

test "WAL reader can read LSN from header" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/wal_lsn_continue.wal";

    // Create WAL with LSN 100
    {
        var disk_io = DiskIo.init(alloc, io);
        var wal = try WAL.open(disk_io.io(), path, alloc);
        defer wal.deinit();

        wal.next_lsn = 100;
        try wal.reset();
    }

    var disk_io2 = DiskIo.init(alloc, io);
    var wal = try WAL.open(disk_io2.io(), path, alloc);
    defer wal.deinit();

    var reader = wal.reader();
    try std.testing.expect(try reader.readHeader() == 100);
}
