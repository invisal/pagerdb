const std = @import("std");
const t = @import("types.zig");
const WAL = @import("./pager/wal.zig").WAL;
const RECORD_HEADER_SIZE = @import("./pager/wal.zig").RECORD_HEADER_SIZE;
const Pager = @import("./pager/pager.zig").Pager;
const PageHeader = t.PageHeader;

pub fn recovery(wal: *WAL, pager: *Pager, alloc: std.mem.Allocator) !void {
    var reader = wal.reader();
    var buffer: [t.PAGE_SIZE]u8 = undefined;

    // An empty WAL file means no records were ever written; nothing to recover.
    reader.open() catch |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    };

    while (try reader.next(alloc)) |record| {
        defer alloc.free(record.payload);

        try pager.readPage(record.page_id, &buffer);
        const offset: usize = @intCast(record.offset);

        if (offset + record.payload.len > t.PAGE_SIZE) return error.CorruptWAL;

        const page_lsn = PageHeader.readLSN(&buffer);

        if (page_lsn < record.lsn) {
            @memcpy(buffer[offset .. offset + record.payload.len], record.payload);
            PageHeader.writeLSN(&buffer, record.lsn);
            try pager.writePage(record.page_id, &buffer, &.{});
        }

        wal.next_lsn = record.lsn + @as(u64, @intCast(record.payload.len)) + RECORD_HEADER_SIZE;
    }

    try pager.flush();
    try wal.reset();
}
