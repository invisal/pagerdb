const std = @import("std");

const RECORD_HEADER_SIZE: u64 = @sizeOf(u32) +
    @sizeOf(u64) +
    @sizeOf(u32) +
    @sizeOf(u16);

pub const WAL = struct {
    file: std.Io.File,
    io: std.Io,
    current_lsn: u64,
    buffer: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn flush(self: *WAL) !void {
        try self.file.writeStreamingAll(self.io, self.buffer.items);
        try self.file.sync(self.io);
        self.buffer.clearRetainingCapacity();
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

    // Returns the LSN immediately after this record.
    // Stored in the page header for WAL recovery.
    pub fn append(self: *WAL, page_id: u32, offset: u16, payload: []const u8) !u64 {
        try self.appendInt(u32, @intCast(payload.len));
        try self.appendInt(u64, self.current_lsn);
        try self.appendInt(u32, page_id);
        try self.appendInt(u16, offset);
        try self.buffer.appendSlice(self.alloc, payload);
        self.current_lsn += RECORD_HEADER_SIZE + @as(u64, @intCast(payload.len));
        return self.current_lsn;
    }
};
