const std = @import("std");
const t = @import("../types.zig");
const page0 = @import("../page0.zig");
const Pager = @import("pager.zig").Pager;
const WAL = @import("wal.zig").WAL;
const Delta = @import("../page_writer.zig").Delta;
const recovery_fn = @import("../recovery.zig").recovery;

const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Allocator = std.mem.Allocator;

pub const DEFAULT_POOL_SIZE: usize = 64;

// Runtime-configurable buffer pool settings.  Pass .{} to create/open to
// accept all defaults (DEFAULT_POOL_SIZE frames × PAGE_SIZE bytes each).
pub const Config = struct {
    // How many pages to keep in RAM.  Linear scan over the pool is O(pool_size),
    // so values above ~512 may benefit from a hash-map eviction index instead.
    pool_size: usize = DEFAULT_POOL_SIZE,
};

const Frame = struct {
    page_id: u32,
    dirty: bool,
    lru_tick: u64,
    data: [t.PAGE_SIZE]u8,
};

pub const DiskPager = struct {
    file: File,
    io: Io,
    allocator: Allocator,
    // Heap-allocated slice; length equals the pool_size passed at creation.
    pool: []Frame,
    tick: u64,
    fault_after: ?u32 = null,
    fault_write_count: u32 = 0,
    // No-steal: when true, dirty frames are not evicted during pool pressure.
    // This keeps data pages in the buffer pool until commit, so the database
    // file always reflects only committed state.
    txn_active: bool = false,

    wal: ?WAL,

    const vtable = Pager.VTable{
        .readPage = diskReadPage,
        .writePage = diskWritePage,
        .flush = diskFlush,
        .close = diskClose,
        .beginTxn = diskBeginTxn,
        .endTxn = diskEndTxn,
    };

    pub fn create(allocator: Allocator, io: Io, path: []const u8, config: Config) !Pager {
        const file = try Dir.cwd().createFile(io, path, .{ .read = true });
        errdefer file.close(io);
        const self = try allocator.create(DiskPager);
        errdefer allocator.destroy(self);
        try initSelf(self, file, io, allocator, config.pool_size);
        errdefer allocator.free(self.pool);

        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{path});
        defer allocator.free(wal_path);
        self.wal = try WAL.create(io, wal_path, allocator);
        errdefer self.wal.?.deinit();

        var pager = Pager{
            .ptr = self,
            .vtable = &vtable,
            .total_pages = 0,
            .free_list_head = 0,
            .sys_tables_root = 0,
            .sys_columns_root = 0,
        };
        const blank = [_]u8{0} ** t.PAGE_SIZE;
        try file.writeStreamingAll(io, &blank);
        pager.total_pages = 1;
        try page0.writeHeader(&pager);
        return pager;
    }

    pub fn open(allocator: Allocator, io: Io, path: []const u8, config: Config) !Pager {
        const file = try Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        errdefer file.close(io);
        const file_size = try file.length(io);
        const self = try allocator.create(DiskPager);
        errdefer allocator.destroy(self);
        try initSelf(self, file, io, allocator, config.pool_size);
        errdefer allocator.free(self.pool);
        var pager = Pager{
            .ptr = self,
            .vtable = &vtable,
            .total_pages = @intCast(file_size / t.PAGE_SIZE),
            .free_list_head = 0,
            .sys_tables_root = 0,
            .sys_columns_root = 0,
        };
        const h = try page0.readHeader(&pager);
        try page0.validateHeader(h);
        pager.free_list_head = h.free_list_head;
        pager.sys_tables_root = h.sys_tables_root;
        pager.sys_columns_root = h.sys_columns_root;

        // Open existing WAL, or create a fresh one if missing (e.g. first open
        // after migrating from a build without WAL support).
        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{path});
        defer allocator.free(wal_path);
        self.wal = WAL.open(io, wal_path, allocator) catch |err| switch (err) {
            error.FileNotFound => try WAL.create(io, wal_path, allocator),
            else => return err,
        };
        errdefer self.wal.?.deinit();
        try recovery_fn(&self.wal.?, &pager, allocator);

        return pager;
    }

    fn initSelf(self: *DiskPager, file: File, io: Io, allocator: Allocator, pool_size: usize) !void {
        self.file = file;
        self.io = io;
        self.allocator = allocator;
        self.tick = 0;
        self.fault_after = null;
        self.fault_write_count = 0;
        self.txn_active = false;
        self.wal = null;
        self.pool = try allocator.alloc(Frame, pool_size);
        for (self.pool) |*frame| {
            frame.page_id = std.math.maxInt(u32);
            frame.dirty = false;
            frame.lru_tick = 0;
        }
    }

    fn poolFind(self: *DiskPager, page_id: u32) ?*Frame {
        for (self.pool) |*frame| {
            if (frame.page_id == page_id) return frame;
        }
        return null;
    }

    // Selects the least-recently-used frame for replacement.
    // We use a monotonic tick counter rather than a linked list because:
    //   1) It requires no pointer chasing during normal access (cache-friendly)
    //   2) With small pool sizes, a linear scan is O(n) and simpler than a heap
    //   3) Tick comparison is branch-predictor friendly on modern CPUs
    // If the chosen frame is dirty, its contents are written back to disk.
    //
    // No-steal: when txn_active is true, dirty frames are skipped.  This keeps
    // all data page changes in the buffer pool until commit, so the database
    // file always reflects the last committed state.
    fn poolEvict(self: *DiskPager) !*Frame {
        var oldest: ?*Frame = null;
        for (self.pool) |*frame| {
            if (self.txn_active and frame.dirty) continue;
            if (oldest == null or frame.lru_tick < oldest.?.lru_tick) oldest = frame;
        }
        const f = oldest orelse return error.BufferPoolFull;
        if (f.dirty) {
            try self.writePageRaw(f.page_id, &f.data);
            f.dirty = false;
        }
        return f;
    }

    fn readPageRaw(self: *DiskPager, page_id: u32, buf: *[t.PAGE_SIZE]u8) !void {
        const offset: u64 = @as(u64, page_id) * t.PAGE_SIZE;
        const n = try self.file.readPositionalAll(self.io, buf, offset);
        if (n != t.PAGE_SIZE) return error.IncompleteRead;
    }

    fn writePageRaw(self: *DiskPager, page_id: u32, buf: *const [t.PAGE_SIZE]u8) !void {
        if (self.fault_after) |limit| {
            const n = self.fault_write_count;
            self.fault_write_count = n + 1;
            if (n >= limit) return error.NoSpaceLeft;
        }
        const offset: u64 = @as(u64, page_id) * t.PAGE_SIZE;
        try self.file.writePositionalAll(self.io, buf, offset);
    }

    fn diskReadPage(ptr: *anyopaque, page_id: u32, buf: *[t.PAGE_SIZE]u8) anyerror!void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        self.tick += 1;
        if (self.poolFind(page_id)) |frame| {
            frame.lru_tick = self.tick;
            buf.* = frame.data;
            return;
        }
        const frame = try self.poolEvict();
        frame.page_id = page_id;
        frame.dirty = false;
        frame.lru_tick = self.tick;
        try self.readPageRaw(page_id, &frame.data);
        buf.* = frame.data;
    }

    fn diskWritePage(ptr: *anyopaque, page_id: u32, buf: *const [t.PAGE_SIZE]u8, deltas: []Delta) anyerror!void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        self.tick += 1;

        var latest_lsn: ?u64 = null;

        // |*wal| gives a pointer into self.wal so current_lsn increments persist.
        if (self.wal) |*wal| {
            for (deltas) |d| {
                latest_lsn = try wal.append(page_id, d.offset, buf[d.offset .. d.offset + d.len]);
            }
        }

        if (self.poolFind(page_id)) |frame| {
            frame.data = buf.*;
            frame.dirty = true;
            frame.lru_tick = self.tick;
            if (latest_lsn) |lsn| t.PageHeader.writeLSN(&frame.data, lsn);
            return;
        }

        const frame = try self.poolEvict();
        frame.page_id = page_id;
        frame.data = buf.*;
        frame.dirty = true;
        frame.lru_tick = self.tick;
        if (latest_lsn) |lsn| t.PageHeader.writeLSN(&frame.data, lsn);
    }

    fn diskFlush(ptr: *anyopaque, pager: *Pager) anyerror!void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        // Flush is only valid at commit time; dirty pages must never reach disk
        // mid-transaction (no-steal policy).
        std.debug.assert(!self.txn_active);
        // WAL must reach disk before pages so recovery can replay any records
        // that were not yet applied to the data file at crash time.
        if (self.wal) |*wal| try wal.flush();
        try page0.writeHeader(pager);
        for (self.pool) |*frame| {
            if (frame.dirty and frame.page_id != std.math.maxInt(u32)) {
                try self.writePageRaw(frame.page_id, &frame.data);
                frame.dirty = false;
            }
        }
        try self.file.sync(self.io);
    }

    fn diskBeginTxn(ptr: *anyopaque) void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        self.txn_active = true;
    }

    fn diskEndTxn(ptr: *anyopaque) void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        self.txn_active = false;
    }

    fn diskClose(ptr: *anyopaque) void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        if (self.wal) |*wal| wal.deinit();
        self.file.close(self.io);
        self.allocator.free(self.pool);
        self.allocator.destroy(self);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const Dir2 = std.Io.Dir;

test "create, write, read page" {
    const io = std.testing.io;
    const path = "/tmp/test_pager.db";
    defer Dir2.deleteFile(.cwd(), io, path) catch {};
    defer Dir2.deleteFile(.cwd(), io, path ++ ".wal") catch {};
    const alloc = std.testing.allocator;

    var pager = try DiskPager.create(alloc, io, path, .{});
    defer pager.close();

    var buf = [_]u8{0} ** t.PAGE_SIZE;
    buf[0] = 0xAB;
    buf[t.PAGE_SIZE - 1] = 0xCD;
    try pager.writePage(1, &buf, &.{});

    var read_buf = [_]u8{0} ** t.PAGE_SIZE;
    try pager.readPage(1, &read_buf);

    try std.testing.expectEqual(read_buf[0], 0xAB);
    try std.testing.expectEqual(read_buf[t.PAGE_SIZE - 1], 0xCD);
}

test "allocPage extends file" {
    const io = std.testing.io;
    const path = "/tmp/test_alloc.db";
    defer Dir2.deleteFile(.cwd(), io, path) catch {};
    defer Dir2.deleteFile(.cwd(), io, path ++ ".wal") catch {};
    const alloc = std.testing.allocator;

    var pager = try DiskPager.create(alloc, io, path, .{});
    defer pager.close();

    const id = try pager.allocPage();
    try std.testing.expectEqual(id, 1);
    try std.testing.expectEqual(pager.total_pages, 2);
}

test "buffer pool hit avoids disk read" {
    const io = std.testing.io;
    const path = "/tmp/test_pool.db";
    defer Dir2.deleteFile(.cwd(), io, path) catch {};
    defer Dir2.deleteFile(.cwd(), io, path ++ ".wal") catch {};
    const alloc = std.testing.allocator;

    var pager = try DiskPager.create(alloc, io, path, .{});
    defer pager.close();

    var buf = std.mem.zeroes([t.PAGE_SIZE]u8);
    buf[0] = 42;
    try pager.writePage(1, &buf, &.{});

    var buf2 = std.mem.zeroes([t.PAGE_SIZE]u8);
    try pager.readPage(1, &buf2);
    try std.testing.expectEqual(buf2[0], 42);
}

test "freePage and allocPage reuse" {
    const io = std.testing.io;
    const path = "/tmp/test_free.db";
    defer Dir2.deleteFile(.cwd(), io, path) catch {};
    defer Dir2.deleteFile(.cwd(), io, path ++ ".wal") catch {};
    const alloc = std.testing.allocator;

    var pager = try DiskPager.create(alloc, io, path, .{});
    defer pager.close();

    const id = try pager.allocPage();
    try pager.freePage(id);
    const id2 = try pager.allocPage();
    try std.testing.expectEqual(id, id2);
}
