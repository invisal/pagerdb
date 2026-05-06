const std = @import("std");
const t = @import("../types.zig");
const page0 = @import("../page0.zig");
const Pager = @import("pager.zig").Pager;
const Wal = @import("../wal.zig").Wal;

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
    // WAL LSN assigned when this frame was last written.  The WAL must be
    // fsynced up to at least this LSN before the frame may reach the data file.
    lsn: u64,
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
    wal: Wal,
    // Monotonically increasing transaction ID counter.
    next_txn_id: u32,
    // ID of the currently active transaction; 0 in auto-commit mode.
    current_txn_id: u32,
    // When true, diskWritePage skips WAL recording.  Set during rollback undo
    // replay so that compensation writes don't pollute the redo log.
    wal_bypass: bool,
    // Kept for bookkeeping; no longer used to block eviction (STEAL policy).
    txn_active: bool,

    const vtable = Pager.VTable{
        .readPage = diskReadPage,
        .writePage = diskWritePage,
        .flush = diskFlush,
        .close = diskClose,
        .flushPage = diskFlushPage,
        .beginTxn = diskBeginTxn,
        .endTxn = diskEndTxn,
        .commitTxn = diskCommitTxn,
        .setWalBypass = diskSetWalBypass,
        .checkpoint = diskCheckpoint,
    };

    pub fn create(allocator: Allocator, io: Io, path: []const u8, config: Config) !Pager {
        const file = try Dir.cwd().createFile(io, path, .{ .read = true });
        errdefer file.close(io);

        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{path});
        defer allocator.free(wal_path);
        var wal = try Wal.create(allocator, io, wal_path);
        errdefer wal.close();

        const self = try allocator.create(DiskPager);
        errdefer allocator.destroy(self);
        try initSelf(self, file, wal, io, allocator, config.pool_size);
        errdefer allocator.free(self.pool);

        var pager = Pager{
            .ptr = self,
            .vtable = &vtable,
            .total_pages = 0,
            .free_list_head = 0,
            .sys_tables_root = 0,
            .sys_columns_root = 0,
            .undo_head = 0,
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

        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{path});
        defer allocator.free(wal_path);
        var wal = try Wal.open(allocator, io, wal_path);
        errdefer wal.close();

        const self = try allocator.create(DiskPager);
        errdefer allocator.destroy(self);
        try initSelf(self, file, wal, io, allocator, config.pool_size);
        errdefer allocator.free(self.pool);

        var pager = Pager{
            .ptr = self,
            .vtable = &vtable,
            .total_pages = @intCast(file_size / t.PAGE_SIZE),
            .free_list_head = 0,
            .sys_tables_root = 0,
            .sys_columns_root = 0,
            .undo_head = 0,
        };
        const h = try page0.readHeader(&pager);
        try page0.validateHeader(h);
        pager.free_list_head = h.free_list_head;
        pager.sys_tables_root = h.sys_tables_root;
        pager.sys_columns_root = h.sys_columns_root;
        pager.undo_head = h.undo_head;
        return pager;
    }

    fn initSelf(self: *DiskPager, file: File, wal: Wal, io: Io, allocator: Allocator, pool_size: usize) !void {
        self.file = file;
        self.wal = wal;
        self.io = io;
        self.allocator = allocator;
        self.tick = 0;
        self.fault_after = null;
        self.fault_write_count = 0;
        self.next_txn_id = 1;
        self.current_txn_id = 0;
        self.wal_bypass = false;
        self.txn_active = false;
        self.pool = try allocator.alloc(Frame, pool_size);
        for (self.pool) |*frame| {
            frame.page_id = std.math.maxInt(u32);
            frame.dirty = false;
            frame.lru_tick = 0;
            frame.lsn = 0;
        }
    }

    fn poolFind(self: *DiskPager, page_id: u32) ?*Frame {
        for (self.pool) |*frame| {
            if (frame.page_id == page_id) return frame;
        }
        return null;
    }

    // STEAL policy: dirty frames may be evicted at any time, even during an
    // active transaction.  Before writing a dirty frame to the data file we
    // enforce the WAL rule: the frame's WAL record must already be on stable
    // storage (last_fsynced_lsn >= frame.lsn).  If not, we flush the WAL first.
    fn poolEvict(self: *DiskPager) !*Frame {
        var oldest: ?*Frame = null;
        for (self.pool) |*frame| {
            if (oldest == null or frame.lru_tick < oldest.?.lru_tick) oldest = frame;
        }
        const f = oldest orelse return error.BufferPoolFull;
        if (f.dirty) {
            // WAL rule: ensure the WAL is durable before the page reaches disk.
            if (f.lsn > self.wal.last_fsynced_lsn) {
                try self.wal.flush();
            }
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
        frame.lsn = 0;
        try self.readPageRaw(page_id, &frame.data);
        buf.* = frame.data;
    }

    // Write a page: record the after-image in the WAL (unless wal_bypass is
    // set), then update the buffer pool frame.  The WAL record is written to
    // the OS page cache here; callers must call wal.flush() before relying on
    // durability.
    fn diskWritePage(ptr: *anyopaque, page_id: u32, buf: *const [t.PAGE_SIZE]u8) anyerror!void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        self.tick += 1;

        // Write WAL record before touching the buffer pool (WAL rule).
        const lsn: u64 = if (!self.wal_bypass)
            try self.wal.appendPageImage(self.current_txn_id, page_id, buf)
        else
            0;

        if (self.poolFind(page_id)) |frame| {
            frame.data = buf.*;
            frame.dirty = true;
            frame.lru_tick = self.tick;
            frame.lsn = lsn;
            return;
        }
        const frame = try self.poolEvict();
        frame.page_id = page_id;
        frame.data = buf.*;
        frame.dirty = true;
        frame.lru_tick = self.tick;
        frame.lsn = lsn;
    }

    // FORCE flush: write page 0, flush all dirty frames to the data file, and
    // fsync.  Used for auto-commit DML, rollback, createTable, and close.
    // Enforces the WAL rule by fsyncing the WAL first.
    fn diskFlush(ptr: *anyopaque, pager: *Pager) anyerror!void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        // WAL rule: fsync WAL before writing any dirty data pages.
        if (self.wal.last_fsynced_lsn < self.wal.next_lsn - 1) {
            try self.wal.flush();
        }
        try page0.writeHeader(pager);
        // After writeHeader, page 0 has a new WAL record; flush WAL again.
        try self.wal.flush();
        for (self.pool) |*frame| {
            if (frame.dirty and frame.page_id != std.math.maxInt(u32)) {
                try self.writePageRaw(frame.page_id, &frame.data);
                frame.dirty = false;
            }
        }
        try self.file.sync(self.io);
    }

    // Flush a single page directly to the data file, enforcing the WAL rule.
    // Used by the undo log and by commit() to persist page 0.
    fn diskFlushPage(ptr: *anyopaque, page_id: u32) anyerror!void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        if (self.poolFind(page_id)) |frame| {
            if (frame.dirty) {
                // WAL rule: WAL must be durable before data page reaches disk.
                if (frame.lsn > self.wal.last_fsynced_lsn) {
                    try self.wal.flush();
                }
                try self.writePageRaw(frame.page_id, &frame.data);
                frame.dirty = false;
            }
        }
        // If not in pool the page is already on disk; nothing to do.
    }

    fn diskBeginTxn(ptr: *anyopaque) void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        self.txn_active = true;
        self.current_txn_id = self.next_txn_id;
        self.next_txn_id += 1;
    }

    fn diskEndTxn(ptr: *anyopaque) void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        self.txn_active = false;
        self.current_txn_id = 0;
    }

    // NO-FORCE commit: write a COMMIT record and fsync the WAL.
    // Data pages are NOT flushed to the data file here — they stay in the
    // buffer pool and will reach disk lazily via checkpoint.
    fn diskCommitTxn(ptr: *anyopaque) anyerror!void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        try self.wal.appendCommit(self.current_txn_id);
        try self.wal.flush();
    }

    fn diskSetWalBypass(ptr: *anyopaque, bypass: bool) void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        self.wal_bypass = bypass;
    }

    // Checkpoint: flush all dirty data pages to the data file, then rotate the
    // WAL so it starts fresh.  After this, recovery only needs to replay records
    // written after the checkpoint.
    fn diskCheckpoint(ptr: *anyopaque, pager: *Pager) anyerror!void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        // Flush WAL first (WAL rule) then write all dirty frames.
        try self.wal.flush();
        try page0.writeHeader(pager);
        try self.wal.flush(); // include page0 WAL record
        for (self.pool) |*frame| {
            if (frame.dirty and frame.page_id != std.math.maxInt(u32)) {
                try self.writePageRaw(frame.page_id, &frame.data);
                frame.dirty = false;
            }
        }
        try self.file.sync(self.io);
        // Rotate WAL: start fresh, recording the LSN we've checkpointed up to.
        const checkpoint_lsn = self.wal.next_lsn - 1;
        try self.wal.rotate(checkpoint_lsn);
    }

    fn diskClose(ptr: *anyopaque) void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        self.file.close(self.io);
        self.wal.close();
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
    try pager.writePage(1, &buf);

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
    try pager.writePage(1, &buf);

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
