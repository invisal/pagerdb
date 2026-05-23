const std = @import("std");
const t = @import("../types.zig");
const Delta = @import("../page_writer.zig").Delta;

// Pager is a vtable-based interface to different storage backends (disk,
// memory, test mocks).  This indirection allows the same btree/catalog code
// to run against both real files and in-memory buffers, which is essential
// for deterministic testing and fuzzing without file system side effects.
pub const Pager = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    total_pages: u32,
    free_list_head: u32,
    sys_tables_root: u32,
    sys_columns_root: u32,
    sys_indexes_root: u32,
    sys_index_cols_root: u32,
    sys_views_root: u32,

    pub const VTable = struct {
        readPage: *const fn (*anyopaque, u32, *[t.PAGE_SIZE]u8) anyerror!void,
        writePage: *const fn (*anyopaque, u32, *const [t.PAGE_SIZE]u8, deltas: []Delta) anyerror!void,
        flush: *const fn (*anyopaque, *Pager) anyerror!void,
        close: *const fn (*anyopaque) void,
        // No-steal support: prevent dirty data frames from being evicted mid-transaction.
        beginTxn: *const fn (*anyopaque) void,
        endTxn: *const fn (*anyopaque) void,
        // Discard all dirty frames without writing to disk.  Called on rollback so
        // that partial or failed undo does not leave corrupted pages in the pool.
        // Safe under no-steal: dirty frames were never written to the data file, so
        // dropping them always restores the database file to the last committed state.
        abortTxn: *const fn (*anyopaque) void,
    };

    pub fn readPage(self: *Pager, page_id: u32, buf: *[t.PAGE_SIZE]u8) !void {
        return self.vtable.readPage(self.ptr, page_id, buf);
    }

    pub fn writePage(self: *Pager, page_id: u32, buf: *const [t.PAGE_SIZE]u8, deltas: []Delta) !void {
        return self.vtable.writePage(self.ptr, page_id, buf, deltas);
    }

    pub fn flush(self: *Pager) !void {
        return self.vtable.flush(self.ptr, self);
    }

    pub fn close(self: *Pager) void {
        self.vtable.close(self.ptr);
    }

    pub fn beginTxn(self: *Pager) void {
        self.vtable.beginTxn(self.ptr);
    }

    pub fn endTxn(self: *Pager) void {
        self.vtable.endTxn(self.ptr);
    }

    pub fn abortTxn(self: *Pager) void {
        self.vtable.abortTxn(self.ptr);
    }

    pub fn freePage(self: *Pager, page_id: u32) !void {
        var buf = std.mem.zeroes([t.PAGE_SIZE]u8);
        const fp = t.FreePage{
            .header = .{
                .lsn = 0,
                .checksum = 0,
                .page_type = .free,
                .flags = 0,
                ._pad = 0,
            },
            .next_free_page = self.free_list_head,
            ._reserved = 0,
        };
        @memcpy(buf[0..@sizeOf(t.FreePage)], std.mem.asBytes(&fp));
        // Log the free-page header so recovery can restore the free-list chain
        // pointer (next_free_page).  Without this, recovery might restore
        // free_list_head in page0 but find stale btree content in the freed page.
        var delta = [_]Delta{.{ .offset = 0, .len = @sizeOf(t.FreePage) }};
        try self.writePage(page_id, &buf, &delta);
        self.free_list_head = page_id;
    }

    pub fn allocPage(self: *Pager) !u32 {
        if (self.free_list_head != 0) {
            const page_id = self.free_list_head;
            var buf: [t.PAGE_SIZE]u8 align(@alignOf(t.FreePage)) = undefined;
            try self.readPage(page_id, &buf);
            const fp: *const t.FreePage = @ptrCast(&buf);
            self.free_list_head = fp.next_free_page;
            @memset(&buf, 0);
            try self.writePage(page_id, &buf, &.{});
            return page_id;
        }
        const page_id = self.total_pages;
        self.total_pages += 1;
        var blank = std.mem.zeroes([t.PAGE_SIZE]u8);
        try self.writePage(page_id, &blank, &.{});
        return page_id;
    }
};
