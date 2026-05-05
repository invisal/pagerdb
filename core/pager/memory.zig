const std = @import("std");
const t = @import("../types.zig");
const Pager = @import("pager.zig").Pager;

const Allocator = std.mem.Allocator;

// InMemoryPager is a pager implementation backed by a hash map.
// Used for testing and in-memory databases.  Unlike DiskPager there is no
// buffer pool — every page is always in memory.  This trades memory for
// simplicity and removes I/O error paths from test code.
pub const InMemoryPager = struct {
    allocator: Allocator,
    pages: std.AutoHashMap(u32, [t.PAGE_SIZE]u8),

    const vtable = Pager.VTable{
        .readPage = memReadPage,
        .writePage = memWritePage,
        .flush = memFlush,
        .close = memClose,
        .flushPage = memFlushPage,
        .beginTxn = memBeginTxn,
        .endTxn = memEndTxn,
    };

    pub fn create(allocator: Allocator) !Pager {
        const self = try allocator.create(InMemoryPager);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.pages = std.AutoHashMap(u32, [t.PAGE_SIZE]u8).init(allocator);
        try self.pages.put(0, std.mem.zeroes([t.PAGE_SIZE]u8));
        return Pager{
            .ptr = self,
            .vtable = &vtable,
            .total_pages = 1,
            .free_list_head = 0,
            .sys_tables_root = 0,
            .sys_columns_root = 0,
            .undo_head = 0,
        };
    }

    fn memReadPage(ptr: *anyopaque, page_id: u32, buf: *[t.PAGE_SIZE]u8) anyerror!void {
        const self: *InMemoryPager = @ptrCast(@alignCast(ptr));
        const page = self.pages.get(page_id) orelse return error.PageNotFound;
        buf.* = page;
    }

    fn memWritePage(ptr: *anyopaque, page_id: u32, buf: *const [t.PAGE_SIZE]u8) anyerror!void {
        const self: *InMemoryPager = @ptrCast(@alignCast(ptr));
        try self.pages.put(page_id, buf.*);
    }

    fn memFlush(ptr: *anyopaque, p: *Pager) anyerror!void {
        _ = ptr;
        _ = p;
    }

    fn memFlushPage(ptr: *anyopaque, page_id: u32) anyerror!void {
        _ = ptr;
        _ = page_id;
    }

    fn memBeginTxn(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn memEndTxn(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn memClose(ptr: *anyopaque) void {
        const self: *InMemoryPager = @ptrCast(@alignCast(ptr));
        self.pages.deinit();
        self.allocator.destroy(self);
    }
};
