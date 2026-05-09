const std = @import("std");

pub const RECORD_HEADER_SIZE: u64 = @sizeOf(u32) +
    @sizeOf(u64) +
    @sizeOf(u32) +
    @sizeOf(u16);

pub const Record = struct {
    lsn: u64,
    page_id: u32,
    offset: u16,
    payload: []const u8,
};

pub const WAL = struct {
    file: std.Io.File,
    io: std.Io,
    next_lsn: u64,
    buffer: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    offset: usize,

    // Create a new WAL file and write the initial LSN header.
    pub fn create(io: std.Io, path: []const u8, alloc: std.mem.Allocator) !WAL {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true });
        var wal = WAL{ .file = file, .io = io, .next_lsn = 0, .buffer = .empty, .alloc = alloc, .offset = 0 };
        try wal.reset();
        return wal;
    }

    // Open an existing WAL file. Caller must run recovery() before use.
    pub fn open(io: std.Io, path: []const u8, alloc: std.mem.Allocator) !WAL {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        return WAL{ .file = file, .io = io, .next_lsn = 0, .buffer = .empty, .alloc = alloc, .offset = 0 };
    }

    pub fn deinit(self: *WAL) void {
        self.file.close(self.io);
        self.buffer.deinit(self.alloc);
    }

    pub fn reader(self: *WAL) WALReader {
        return .{
            .wal = self,
            .offset = 0,
        };
    }

    pub fn flush(self: *WAL) !void {
        try self.file.writePositionalAll(self.io, self.buffer.items, self.offset);
        self.offset += self.buffer.items.len;

        try self.file.sync(self.io);
        self.buffer.clearRetainingCapacity();
    }

    pub fn reset(self: *WAL) !void {
        self.offset = 0;
        try self.file.setLength(self.io, 0);

        try self.appendInt(u64, self.next_lsn);
        try self.flush();
    }

    fn appendInt(
        self: *WAL,
        comptime T: type,
        value: T,
    ) !void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, value, .little);
        try self.buffer.appendSlice(self.alloc, &buf);
    }

    // Returns the LSN of this record, written into the page header so recovery
    // can tell whether a WAL record has already been applied to a page on disk.
    pub fn append(self: *WAL, page_id: u32, offset: u16, payload: []const u8) !u64 {
        try self.appendInt(u32, @intCast(payload.len));
        try self.appendInt(u64, self.next_lsn);
        try self.appendInt(u32, page_id);
        try self.appendInt(u16, offset);
        try self.buffer.appendSlice(self.alloc, payload);

        const current = self.next_lsn;
        self.next_lsn += RECORD_HEADER_SIZE + @as(u64, @intCast(payload.len));

        return current;
    }
};

pub const WALReader = struct {
    wal: *WAL,
    offset: usize,

    pub fn open(self: *WALReader) !void {
        self.wal.next_lsn = try self.readInt(u64);
    }

    pub fn next(self: *WALReader, alloc: std.mem.Allocator) !?Record {
        const length = self.readInt(u32) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };

        // If the file is truncated mid-record (crash during write), treat it as
        // end of valid records rather than a hard error.
        const lsn = self.readInt(u64) catch return error.CorruptWAL;
        const page_id = self.readInt(u32) catch return error.CorruptWAL;
        const offset = self.readInt(u16) catch return error.CorruptWAL;

        const buffer = try alloc.alloc(u8, length);
        errdefer alloc.free(buffer);
        const n = try self.wal.file.readPositionalAll(self.wal.io, buffer, self.offset);
        if (n != length) return error.CorruptWAL;
        self.offset += @intCast(length);

        return Record{
            .lsn = lsn,
            .offset = offset,
            .page_id = page_id,
            .payload = buffer,
        };
    }

    fn readInt(self: *WALReader, comptime T: type) !T {
        var buffer: [@sizeOf(T)]u8 = undefined;
        const n = try self.wal.file.readPositionalAll(self.wal.io, &buffer, self.offset);
        if (n != @sizeOf(T)) return error.EndOfStream;
        self.offset += @sizeOf(T);
        return std.mem.readInt(T, &buffer, .little);
    }
};
