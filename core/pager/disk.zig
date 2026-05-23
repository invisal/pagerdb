const std = @import("std");
const t = @import("../types.zig");
const page0 = @import("../page0.zig");
const Pager = @import("pager.zig").Pager;
const WAL = @import("wal.zig").WAL;
const Delta = @import("../page_writer.zig").Delta;
const io_mod = @import("../io/io.zig");
const Io = io_mod.Io;
const File = io_mod.File;
const Allocator = std.mem.Allocator;

// 256 frames × 4 KB = 1 MB buffer pool.  Large enough to hold the dirty pages
// for typical single-statement transactions (e.g. INSERT…SELECT of ~10 k rows
// needs ~150–200 B-tree pages).  64 was too small: under the no-steal policy a
// large implicit transaction would exhaust the pool before committing.
pub const DEFAULT_POOL_SIZE: usize = 256;
// Rotate to a new WAL segment once the current one exceeds this size.
// Smaller = more frequent checkpoints (faster recovery), larger = fewer I/Os.
pub const WAL_SEGMENT_SIZE: usize = 8 * 1024 * 1024; // 8 MB

// Runtime-configurable buffer pool settings.  Pass .{} to create/open to
// accept all defaults (DEFAULT_POOL_SIZE frames × PAGE_SIZE bytes each).
pub const Config = struct {
    // How many pages to keep in RAM.  Linear scan over the pool is O(pool_size),
    // so values above ~512 may benefit from a hash-map eviction index instead.
    pool_size: usize = DEFAULT_POOL_SIZE,
    wal: ?*WAL = null,
};

const Frame = struct {
    page_id: u32,
    dirty: bool,
    // Set after WAL rotation; cleared on first write so that write emits a
    // full-page WAL record (FPW) capturing the pre-delta page image.  Recovery
    // uses FPW to reconstruct a page whose disk write was torn mid-sector.
    needs_fpw: bool,
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
    // No-steal: when true, dirty frames are not evicted during pool pressure.
    // This keeps data pages in the buffer pool until commit, so the database
    // file always reflects only committed state.
    txn_active: bool = false,

    wal: ?*WAL,

    const vtable = Pager.VTable{
        .readPage = diskReadPage,
        .writePage = diskWritePage,
        .flush = diskFlush,
        .close = diskClose,
        .beginTxn = diskBeginTxn,
        .endTxn = diskEndTxn,
        .abortTxn = diskAbortTxn,
    };

    pub fn create(allocator: Allocator, io: Io, path: []const u8, config: Config) !Pager {
        const file = try io.createFile(path);
        errdefer file.close();
        const self = try allocator.create(DiskPager);
        errdefer allocator.destroy(self);
        try initSelf(self, file, io, allocator, config.pool_size);
        errdefer allocator.free(self.pool);

        self.wal = config.wal;

        var pager = Pager{
            .ptr = self,
            .vtable = &vtable,
            .total_pages = 0,
            .free_list_head = 0,
            .sys_tables_root = 0,
            .sys_columns_root = 0,
            .sys_indexes_root = 0,
            .sys_index_cols_root = 0,
            .sys_views_root = 0,
        };
        // Write a zero-filled page 0 to initialise the file.
        const blank = [_]u8{0} ** t.PAGE_SIZE;
        try file.writeAt(&blank, 0);
        pager.total_pages = 1;
        try page0.writeHeader(&pager);
        return pager;
    }

    pub fn open(allocator: Allocator, io: Io, path: []const u8, config: Config) !Pager {
        const file = try io.openFile(path);
        errdefer file.close();
        const file_size = try file.length();
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
            .sys_indexes_root = 0,
            .sys_index_cols_root = 0,
            .sys_views_root = 0,
        };
        const h = try page0.readHeader(&pager);
        try page0.validateHeader(h);
        pager.free_list_head = h.free_list_head;
        pager.sys_tables_root = h.sys_tables_root;
        pager.sys_columns_root = h.sys_columns_root;
        pager.sys_indexes_root = h.sys_indexes_root;
        pager.sys_index_cols_root = h.sys_index_cols_root;
        pager.sys_views_root = h.sys_views_root;

        self.wal = config.wal;
        return pager;
    }

    fn initSelf(self: *DiskPager, file: File, io: Io, allocator: Allocator, pool_size: usize) !void {
        self.file = file;
        self.io = io;
        self.allocator = allocator;
        self.tick = 0;
        self.txn_active = false;
        self.wal = null;
        self.pool = try allocator.alloc(Frame, pool_size);
        for (self.pool) |*frame| {
            frame.page_id = std.math.maxInt(u32);
            frame.dirty = false;
            frame.needs_fpw = false;
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
        const n = try self.file.readAt(buf, offset);
        if (n != t.PAGE_SIZE) return error.IncompleteRead;
        try t.verifyPageChecksum(page_id, buf);
    }

    fn writePageRaw(self: *DiskPager, page_id: u32, buf: *const [t.PAGE_SIZE]u8) !void {
        // Copy so we can stamp the checksum without mutating the caller's buffer.
        var stamped = buf.*;
        t.writePageChecksum(page_id, &stamped);
        const offset: u64 = @as(u64, page_id) * t.PAGE_SIZE;
        try self.file.writeAt(&stamped, offset);
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

        if (self.poolFind(page_id)) |frame| {
            if (self.wal) |wal| {
                // First write after a WAL rotation: emit a full-page record containing
                // the pre-delta page image so recovery can reconstruct this page even
                // if its later disk write is torn (partial 512-byte sector write on an
                // 8 KB page).  Only needed for pool hits; cold misses load from disk
                // which is already at last-checkpoint state.
                if (frame.needs_fpw and deltas.len > 0) {
                    _ = try wal.appendFullPage(page_id, &frame.data);
                    frame.needs_fpw = false;
                }
                for (deltas) |d| {
                    latest_lsn = try wal.append(page_id, d.offset, buf[d.offset .. d.offset + d.len]);
                }
            }
            frame.data = buf.*;
            frame.dirty = true;
            frame.lru_tick = self.tick;
            if (latest_lsn) |lsn| std.mem.writeInt(u64, frame.data[@offsetOf(t.PageHeader, "lsn")..][0..8], lsn, .little);
            return;
        }

        const frame = try self.poolEvict();
        frame.page_id = page_id;
        frame.needs_fpw = false;
        frame.lru_tick = self.tick;

        if (self.wal) |wal| {
            for (deltas) |d| {
                latest_lsn = try wal.append(page_id, d.offset, buf[d.offset .. d.offset + d.len]);
            }
        }
        frame.data = buf.*;
        frame.dirty = true;
        if (latest_lsn) |lsn| std.mem.writeInt(u64, frame.data[@offsetOf(t.PageHeader, "lsn")..][0..8], lsn, .little);
    }

    fn diskFlush(ptr: *anyopaque, pager: *Pager) anyerror!void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        // Flush is only valid at commit time; dirty pages must never reach disk
        // mid-transaction (no-steal policy).
        std.debug.assert(!self.txn_active);

        try page0.writeHeader(pager);

        // WAL must reach disk before pages so recovery can replay any records
        // that were not yet applied to the data file at crash time.
        if (self.wal) |wal| {
            try wal.appendCommit(self.io.nowMicros());
            try wal.flush();
        }
        for (self.pool) |*frame| {
            if (frame.dirty and frame.page_id != std.math.maxInt(u32)) {
                try self.writePageRaw(frame.page_id, &frame.data);
                frame.dirty = false;
            }
        }
        try self.file.sync();

        // All dirty pages are now on disk.  If the WAL segment has grown past
        // the threshold, rotate to a new segment and write a checkpoint so
        // recovery only needs to replay the new (mostly-empty) segment.
        // After rotation, mark every pool frame so the next write to each will
        // emit a full-page WAL record (FPW) before its deltas.
        if (self.wal) |wal| {
            if (wal.offset >= WAL_SEGMENT_SIZE) {
                try wal.rotateAfterCheckpoint();
                for (self.pool) |*frame| {
                    if (frame.page_id != std.math.maxInt(u32)) {
                        frame.needs_fpw = true;
                    }
                }
            }
        }
    }

    fn diskBeginTxn(ptr: *anyopaque) void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        self.txn_active = true;
    }

    fn diskEndTxn(ptr: *anyopaque) void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        self.txn_active = false;
    }

    // Discard every dirty frame without writing to disk.  Under no-steal, dirty
    // frames were never flushed to the data file, so dropping them restores the
    // pool to a clean state that matches the last committed data-file snapshot.
    // Called by db.rollback() so that even a failed logical undo (e.g. because
    // the pool itself was full) cannot leave corrupted data on disk.
    fn diskAbortTxn(ptr: *anyopaque) void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        for (self.pool) |*frame| {
            if (frame.dirty) {
                frame.page_id = std.math.maxInt(u32);
                frame.dirty = false;
                frame.needs_fpw = false;
            }
        }
        self.txn_active = false;
    }

    // Cast a generic Pager handle back to the underlying DiskPager.
    // Only valid when the Pager was created by DiskPager.create() or DiskPager.open().
    pub fn asDiskPager(pager: *Pager) *DiskPager {
        return @ptrCast(@alignCast(pager.ptr));
    }

    fn diskClose(ptr: *anyopaque) void {
        const self: *DiskPager = @ptrCast(@alignCast(ptr));
        self.file.close();
        self.allocator.free(self.pool);
        self.allocator.destroy(self);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const DiskIo = @import("../io/disk_io.zig").DiskIo;
const Dir = std.Io.Dir;

test "create, write, read page" {
    const alloc = std.testing.allocator;
    const path = "/tmp/test_pager.db";
    var disk_io = DiskIo.init(alloc, std.testing.io);
    defer disk_io.io().deleteFile(path) catch {};
    defer disk_io.io().deleteFile(path ++ ".wal") catch {};

    var pager = try DiskPager.create(alloc, disk_io.io(), path, .{});
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
    const alloc = std.testing.allocator;
    const path = "/tmp/test_alloc.db";
    var disk_io = DiskIo.init(alloc, std.testing.io);
    defer disk_io.io().deleteFile(path) catch {};
    defer disk_io.io().deleteFile(path ++ ".wal") catch {};

    var pager = try DiskPager.create(alloc, disk_io.io(), path, .{});
    defer pager.close();

    const id = try pager.allocPage();
    try std.testing.expectEqual(id, 1);
    try std.testing.expectEqual(pager.total_pages, 2);
}

test "buffer pool hit avoids disk read" {
    const alloc = std.testing.allocator;
    const path = "/tmp/test_pool.db";
    var disk_io = DiskIo.init(alloc, std.testing.io);
    defer disk_io.io().deleteFile(path) catch {};
    defer disk_io.io().deleteFile(path ++ ".wal") catch {};

    var pager = try DiskPager.create(alloc, disk_io.io(), path, .{});
    defer pager.close();

    var buf = std.mem.zeroes([t.PAGE_SIZE]u8);
    buf[0] = 42;
    try pager.writePage(1, &buf, &.{});

    var buf2 = std.mem.zeroes([t.PAGE_SIZE]u8);
    try pager.readPage(1, &buf2);
    try std.testing.expectEqual(buf2[0], 42);
}

test "freePage and allocPage reuse" {
    const alloc = std.testing.allocator;
    const path = "/tmp/test_free.db";
    var disk_io = DiskIo.init(alloc, std.testing.io);
    defer disk_io.io().deleteFile(path) catch {};
    defer disk_io.io().deleteFile(path ++ ".wal") catch {};

    var pager = try DiskPager.create(alloc, disk_io.io(), path, .{});
    defer pager.close();

    const id = try pager.allocPage();
    try pager.freePage(id);
    const id2 = try pager.allocPage();
    try std.testing.expectEqual(id, id2);
}
