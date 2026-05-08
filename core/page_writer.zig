const std = @import("std");
const Pager = @import("pager/pager.zig").Pager;
const t = @import("types.zig");

pub const Delta = struct {
    offset: u16,
    len: u16,
};

// Fixed-size delta log. 32 slots is more
// than enough for btree operation needs in a single page
const MAX_DELTAS = 32;

pub const PageWriter = struct {
    pager: *Pager,
    page_id: u32,
    buf: [t.PAGE_SIZE]u8,
    deltas: [MAX_DELTAS]Delta,
    delta_count: usize,

    pub fn open(pager: *Pager, page_id: u32) !PageWriter {
        var pw = PageWriter{
            .pager = pager,
            .page_id = page_id,
            .buf = undefined,
            .deltas = undefined,
            .delta_count = 0,
        };

        try pager.readPage(page_id, &pw.buf);
        return pw;
    }

    pub fn init(pager: *Pager, page_id: u32) PageWriter {
        return PageWriter{
            .pager = pager,
            .page_id = page_id,
            .buf = [_]u8{0} ** t.PAGE_SIZE,
            .deltas = undefined,
            .delta_count = 0,
        };
    }

    pub fn writeAt(self: *PageWriter, offset: u16, data: []const u8) void {
        @memcpy(self.buf[offset .. offset + data.len], data);
        self.recordDelta(offset, @intCast(data.len));
    }

    pub fn writeInt(self: *PageWriter, comptime T: type, offset: u16, value: T, endian: std.builtin.Endian) void {
        std.mem.writeInt(T, self.buf[offset..][0..@sizeOf(T)], value, endian);
        self.recordDelta(offset, @sizeOf(T));
    }

    // Fill a range with a byte value. Records a single delta covering the range.
    pub fn fill(self: *PageWriter, offset: u16, byte: u8, len: u16) void {
        @memset(self.buf[offset .. offset + len], byte);
        self.recordDelta(offset, len);
    }

    // Once the delta log fills up, collapse to a single full-page delta
    // (delta_count = MAX_DELTAS + 1) and stop recording. Subsequent writes
    // still update buf correctly; commit() flushes the whole page either way.
    fn recordDelta(self: *PageWriter, offset: u16, len: u16) void {
        if (self.delta_count < MAX_DELTAS) {
            self.deltas[self.delta_count] = .{ .offset = offset, .len = len };
            self.delta_count += 1;
        } else if (self.delta_count == MAX_DELTAS) {
            self.deltas[0] = .{ .offset = 0, .len = t.PAGE_SIZE };
            self.delta_count = MAX_DELTAS + 1;
        }
        // delta_count > MAX_DELTAS: full-page mode, nothing left to record.
    }

    pub fn commit(self: *PageWriter) !void {
        try self.pager.writePage(self.page_id, &self.buf);
    }
};
