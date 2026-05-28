const std = @import("std");
const t = @import("../types.zig");
const Pager = @import("pager.zig").Pager;
const Delta = @import("../page_writer.zig").Delta;

const Allocator = std.mem.Allocator;

pub const Config = struct {
    // Number of buffer-pool frames to layer on top of the backing map.
    // 0 (default) keeps the original behaviour: every page is always in the
    // map, no eviction.  A non-zero value adds an LRU read-cache so that
    // eviction code paths are exercised even without a disk backend.
    //
    // The pool is write-through: every write commits to the backing map
    // immediately, so eviction never needs to write back.  Memory usage is
    // map (all pages) + pool (pool_size × PAGE_SIZE); the pool does not
    // reduce total footprint, but it bounds the working-set kept hot and
    // exercises the eviction machinery.
    pool_size: usize = 0,
};

const Frame = struct {
    page_id: u32 = std.math.maxInt(u32), // sentinel: empty frame
    lru_tick: u64 = 0,
    data: [t.PAGE_SIZE]u8 = undefined,
};

// InMemoryPager is a pager implementation backed by an ArrayList.
// Used for testing and in-memory databases.  Page IDs are dense integers
// starting at 0, so an ArrayList gives O(1) access with no hashing and
// better cache locality than the previous HashMap approach.
//
// When created via createWithConfig with pool_size > 0, an LRU buffer pool is
// layered on top.  The ArrayList remains the source of truth; the pool is a
// write-through cache that exercises eviction without needing a real disk.
pub const InMemoryPager = struct {
    allocator: Allocator,
    pages: std.ArrayListUnmanaged([t.PAGE_SIZE]u8),
    pool: []Frame, // empty slice when pool_size = 0
    tick: u64 = 0,

    const vtable = Pager.VTable{
        .readPage = memReadPage,
        .writePage = memWritePage,
        .flush = memFlush,
        .close = memClose,
        .beginTxn = memBeginTxn,
        .endTxn = memEndTxn,
    };

    pub fn create(allocator: Allocator) !Pager {
        return createWithConfig(allocator, .{});
    }

    pub fn createWithConfig(allocator: Allocator, config: Config) !Pager {
        const self = try allocator.create(InMemoryPager);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.tick = 0;
        self.pages = .empty;

        if (config.pool_size > 0) {
            self.pool = try allocator.alloc(Frame, config.pool_size);
            for (self.pool) |*f| f.* = .{};
        } else {
            self.pool = &.{};
        }

        try self.pages.append(allocator, std.mem.zeroes([t.PAGE_SIZE]u8));
        return Pager{
            .ptr = self,
            .vtable = &vtable,
            .total_pages = 1,
            .free_list_head = 0,
            .sys_tables_root = 0,
            .sys_columns_root = 0,
            .sys_indexes_root = 0,
            .sys_index_cols_root = 0,
            .sys_views_root = 0,
        };
    }

    fn poolFind(self: *InMemoryPager, page_id: u32) ?*Frame {
        for (self.pool) |*f| {
            if (f.page_id == page_id) return f;
        }
        return null;
    }

    // Returns the LRU frame for replacement. Since the pool is write-through,
    // dirty eviction is never needed — the backing map always has the latest copy.
    fn poolEvict(self: *InMemoryPager) *Frame {
        var victim = &self.pool[0];
        for (self.pool[1..]) |*f| {
            if (f.lru_tick < victim.lru_tick) victim = f;
        }
        return victim;
    }

    fn memReadPage(ptr: *anyopaque, page_id: u32, buf: *[t.PAGE_SIZE]u8) anyerror!void {
        const self: *InMemoryPager = @ptrCast(@alignCast(ptr));

        if (self.pool.len > 0) {
            // Pool hit: serve from cache and refresh LRU timestamp.
            if (self.poolFind(page_id)) |frame| {
                self.tick += 1;
                frame.lru_tick = self.tick;
                buf.* = frame.data;
                return;
            }

            // Pool miss: load from backing array, bring into pool.
            if (page_id >= self.pages.items.len) return error.PageNotFound;
            const page = self.pages.items[page_id];
            buf.* = page;
            const frame = self.poolEvict();
            self.tick += 1;
            frame.* = .{ .page_id = page_id, .lru_tick = self.tick, .data = page };
            return;
        }

        // No pool: direct array index.
        if (page_id >= self.pages.items.len) return error.PageNotFound;
        buf.* = self.pages.items[page_id];
    }

    fn memWritePage(ptr: *anyopaque, page_id: u32, buf: *const [t.PAGE_SIZE]u8, _: []Delta) anyerror!void {
        const self: *InMemoryPager = @ptrCast(@alignCast(ptr));

        // Grow the array if this is a new page being appended.
        if (page_id >= self.pages.items.len) {
            try self.pages.resize(self.allocator, page_id + 1);
        }
        self.pages.items[page_id] = buf.*;

        // Keep the pool consistent if this page is already cached.
        if (self.pool.len > 0) {
            if (self.poolFind(page_id)) |frame| {
                self.tick += 1;
                frame.lru_tick = self.tick;
                frame.data = buf.*;
            }
        }
    }

    fn memFlush(_: *anyopaque, _: *Pager) anyerror!void {}
    fn memBeginTxn(_: *anyopaque) void {}
    fn memEndTxn(_: *anyopaque) void {}

    fn memClose(ptr: *anyopaque) void {
        const self: *InMemoryPager = @ptrCast(@alignCast(ptr));
        if (self.pool.len > 0) self.allocator.free(self.pool);
        self.pages.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};
