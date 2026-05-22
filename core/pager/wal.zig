// Write-Ahead Log (WAL) — guarantees crash safety by writing changes here
// before touching data pages, so recovery can replay any missing writes.
//
// File layout (per segment):
//
//   [ next_lsn: u64 ]  ← segment header; next_lsn is the first LSN this segment
//                          will assign.  Restored on open so LSNs never repeat.
//   [ record ... ]     ← data records, one per page delta
//   [ record ... ]
//   [ commit ]         ← commit marker; ends one transaction group
//   [ record ... ]     ← next transaction begins here
//   ...
//
// Record formats:
//
//   Data   (type=0):  [type:u8 | checksum:u32 | payload_len:u32 | lsn:u64 | page_id:u32 | offset:u16 | payload...]
//   Commit (type=1):  [type:u8 | timestamp_us:u64]
//
//   The data record checksum (CRC32) covers every field except itself.
//   A bad checksum or truncated read means the record was partially written
//   during a crash and is treated as end-of-log.
//   The commit record has no checksum — truncation detection is sufficient.
//   timestamp_us is microseconds since Unix epoch, stored for future
//   point-in-time recovery: given a target time, scan commit records to find
//   the WAL position to replay up to.
//
// Write protocol:  append data records → appendCommit → flush (fsync) → write data pages → fsync
//   Crash before flush: no commit marker, recovery discards the records.
//   Crash after flush:  commit marker present, recovery replays the records.
//
// Recovery: buffer data records until commit marker, then apply them all.
//   Trailing records with no commit marker are discarded.
//
// Segment rotation:
//
//   WAL files are named  {base}-000001.wal, {base}-000002.wal, …
//   A checkpoint file    {base}.ckpt  records which segment is active and the
//   LSN at which all data pages are guaranteed on disk.  On recovery, only the
//   active segment (and later ones, if any) need to be replayed.
//
//   Rotation happens when the current segment exceeds WAL_CHECKPOINT_SIZE:
//     1. Create new segment file (seg N+1) and write its header.
//     2. Atomically write checkpoint file (via temp+rename): lsn=current, seg=N+1.
//     3. Delete old segment (seg N).
//   After a crash at any point, recovery reads the checkpoint to find the active
//   segment and replays only it.  Old segments are cleaned up on the next rotation.

const std = @import("std");
const t = @import("../types.zig");
const Pager = @import("pager.zig").Pager;
const io_mod = @import("../io/io.zig");
const Io = io_mod.Io;
const File = io_mod.File;

const WALError = error{
    CorruptWAL,
    ReaderNotInitialized,
    InvalidHeader,
    InvalidChecksum,
    WALClosed,
};

// Each WAL record begins with a type byte so recovery can distinguish data
// records from commit markers without parsing the full record header.
const RecordType = enum(u8) { data = 0, commit = 1 };

pub const RECORD_HEADER_SIZE: u64 = @sizeOf(u8) + // type
    @sizeOf(u32) + // checksum
    @sizeOf(u32) + // payload_len
    @sizeOf(u64) + // lsn
    @sizeOf(u32) + // page_id
    @sizeOf(u16); // offset

pub const COMMIT_SIZE: u64 = @sizeOf(u8) + @sizeOf(u64); // type + timestamp_us

// ── Checkpoint file ───────────────────────────────────────────────────────────

// Format: [magic:u32 | ckpt_lsn:u64 | segment_num:u32 | crc32:u32] = 20 bytes.
// crc32 covers the preceding 16 bytes so a torn write is detectable.
// Written atomically via write-to-temp + rename so recovery always sees either
// the old valid checkpoint or the new one, never a partial write.

const CKPT_MAGIC: u32 = 0x43504B54; // "CPKT"
const CKPT_SIZE: usize = @sizeOf(u32) + @sizeOf(u64) + @sizeOf(u32) + @sizeOf(u32); // 20

pub const Checkpoint = struct {
    lsn: u64,
    // The WAL segment number that is active after this checkpoint.  New writes
    // go here; older segments have already been applied to the data file.
    segment_num: u32,

    fn ckptPath(base: []const u8, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}.ckpt", .{base});
    }

    fn tmpPath(base: []const u8, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}.ckpt.tmp", .{base});
    }

    // Write the checkpoint atomically: write to a temp file, fsync, rename.
    // If the process crashes mid-write the old checkpoint remains intact.
    pub fn write(io: Io, base_path: []const u8, lsn: u64, segment_num: u32, alloc: std.mem.Allocator) !void {
        var buf: [CKPT_SIZE]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], CKPT_MAGIC, .little);
        std.mem.writeInt(u64, buf[4..12], lsn, .little);
        std.mem.writeInt(u32, buf[12..16], segment_num, .little);
        var h = std.hash.Crc32.init();
        h.update(buf[0..16]);
        std.mem.writeInt(u32, buf[16..20], h.final(), .little);

        const tmp = try tmpPath(base_path, alloc);
        defer alloc.free(tmp);
        const dst = try ckptPath(base_path, alloc);
        defer alloc.free(dst);

        const f = try io.createFile(tmp);
        try f.writeAt(&buf, 0);
        try f.sync();
        f.close();
        try io.renameFile(tmp, dst);
    }

    // Read and verify the checkpoint file.  Returns error.FileNotFound if no
    // checkpoint exists yet (fresh database) or error.InvalidCheckpoint if the
    // file is corrupt, so callers can fall back to replaying from segment 1.
    pub fn read(io: Io, base_path: []const u8, alloc: std.mem.Allocator) !Checkpoint {
        const path = try ckptPath(base_path, alloc);
        defer alloc.free(path);

        const f = try io.openFile(path);
        defer f.close();

        var buf: [CKPT_SIZE]u8 = undefined;
        const n = try f.readAt(&buf, 0);
        if (n != CKPT_SIZE) return error.InvalidCheckpoint;

        if (std.mem.readInt(u32, buf[0..4], .little) != CKPT_MAGIC) return error.InvalidCheckpoint;

        var h = std.hash.Crc32.init();
        h.update(buf[0..16]);
        if (h.final() != std.mem.readInt(u32, buf[16..20], .little)) return error.InvalidCheckpoint;

        return .{
            .lsn = std.mem.readInt(u64, buf[4..12], .little),
            .segment_num = std.mem.readInt(u32, buf[12..16], .little),
        };
    }
};

// ── WAL segment path helpers ──────────────────────────────────────────────────

// Segment files are named {base}-{num:06}.wal.  Six digits supports 999 999
// rotations; at 8 MB per segment that is ~8 TB of WAL, more than enough.
pub fn segmentPath(base: []const u8, seg_num: u32, alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}-{d:0>6}.wal", .{ base, seg_num });
}

// ── WAL ───────────────────────────────────────────────────────────────────────

pub const WAL = struct {
    file: File,
    io: Io,
    alloc: std.mem.Allocator,
    base_path: []const u8, // owned; base name used to construct segment/ckpt paths
    segment_num: u32, // current active segment number
    next_lsn: u64,
    buffer: std.ArrayListUnmanaged(u8),
    offset: usize, // write position in current segment file

    // Create a brand-new WAL starting at segment 1.  Used when the database
    // file itself is being created for the first time.
    pub fn create(alloc: std.mem.Allocator, io: Io, base_path: []const u8) !WAL {
        const owned_base = try alloc.dupe(u8, base_path);
        errdefer alloc.free(owned_base);
        const seg_path = try segmentPath(owned_base, 1, alloc);
        defer alloc.free(seg_path);

        const file = try io.createFile(seg_path);
        var wal = WAL{
            .file = file,
            .io = io,
            .alloc = alloc,
            .base_path = owned_base,
            .segment_num = 1,
            .next_lsn = 0,
            .buffer = .empty,
            .offset = 0,
        };
        try wal.writeSegmentHeader();
        return wal;
    }

    // Open an existing WAL for recovery+use, or create one if none exists.
    // Reads the checkpoint file to find which segment is active.  Caller must
    // run wal.recover() before writing new records.
    pub fn open(alloc: std.mem.Allocator, io: Io, base_path: []const u8) !WAL {
        const owned_base = try alloc.dupe(u8, base_path);
        errdefer alloc.free(owned_base);

        // Which segment should we open?  The checkpoint file tells us.
        // If there is no checkpoint (fresh database or all rotated away), start
        // at segment 1.
        const ckpt = Checkpoint.read(io, owned_base, alloc) catch |err| switch (err) {
            error.FileNotFound, error.InvalidCheckpoint => Checkpoint{ .lsn = 0, .segment_num = 1 },
            else => return err,
        };

        const seg_path = try segmentPath(owned_base, ckpt.segment_num, alloc);
        defer alloc.free(seg_path);

        const file = io.openFile(seg_path) catch |err| switch (err) {
            // No segment file: post-checkpoint state with no new writes yet.
            // Create a fresh segment at the checkpoint LSN position.
            error.FileNotFound => {
                const f = try io.createFile(seg_path);
                var wal = WAL{
                    .file = f,
                    .io = io,
                    .alloc = alloc,
                    .base_path = owned_base,
                    .segment_num = ckpt.segment_num,
                    .next_lsn = ckpt.lsn,
                    .buffer = .empty,
                    .offset = 0,
                };
                try wal.writeSegmentHeader();
                return wal;
            },
            else => return err,
        };

        return WAL{
            .file = file,
            .io = io,
            .alloc = alloc,
            .base_path = owned_base,
            .segment_num = ckpt.segment_num,
            .next_lsn = 0, // overwritten by recover() reading the segment header
            .buffer = .empty,
            .offset = 0,
        };
    }

    pub fn deinit(self: *WAL) void {
        self.file.close();
        self.buffer.deinit(self.alloc);
        self.alloc.free(self.base_path);
    }

    pub fn reader(self: *WAL) WALReader {
        return .{ .wal = self, .offset = 0 };
    }

    pub fn flush(self: *WAL) !void {
        try self.file.writeAt(self.buffer.items, self.offset);
        self.offset += self.buffer.items.len;
        try self.file.sync();
        self.buffer.clearRetainingCapacity();
    }

    // Write the 8-byte next_lsn header that starts every segment.
    pub fn writeSegmentHeader(self: *WAL) !void {
        self.offset = 0;
        try self.appendInt(u64, self.next_lsn);
        try self.flushBuffer();
    }

    // Write the buffer to disk without fsync (used during header init).
    fn flushBuffer(self: *WAL) !void {
        try self.file.writeAt(self.buffer.items, self.offset);
        self.offset += self.buffer.items.len;
        self.buffer.clearRetainingCapacity();
    }

    // Rotate to a new WAL segment after a checkpoint.
    //   1. Create new segment file and write its header.
    //   2. Write checkpoint file atomically (temp + rename).
    //   3. Delete old segment (best-effort; stale segments are harmless).
    //   4. Switch self to point at the new segment.
    pub fn rotateAfterCheckpoint(self: *WAL) !void {
        const new_seg = self.segment_num + 1;
        const new_path = try segmentPath(self.base_path, new_seg, self.alloc);
        defer self.alloc.free(new_path);

        // Step 1: create new segment and write header.
        const new_file = try self.io.createFile(new_path);
        var next_lsn_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &next_lsn_buf, self.next_lsn, .little);
        try new_file.writeAt(&next_lsn_buf, 0);
        try new_file.sync();

        // Step 2: atomic checkpoint.
        try Checkpoint.write(self.io, self.base_path, self.next_lsn, new_seg, self.alloc);

        // Step 3: delete old segment (crash here leaves a stale file, cleaned next rotation).
        const old_path = try segmentPath(self.base_path, self.segment_num, self.alloc);
        defer self.alloc.free(old_path);
        self.io.deleteFile(old_path) catch {};

        // Step 4: switch to new segment.
        self.file.close();
        self.file = new_file;
        self.segment_num = new_seg;
        self.offset = 8; // past the header we just wrote
        self.buffer.clearRetainingCapacity();
    }

    fn appendInt(self: *WAL, comptime T: type, value: T) !void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, value, .little);
        try self.buffer.appendSlice(self.alloc, &buf);
    }

    // Encode an integer as little-endian bytes for checksum input.
    fn intBytes(comptime T: type, value: T) [@sizeOf(T)]u8 {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, value, .little);
        return buf;
    }

    // Returns the LSN of this record, written into the page header so recovery
    // can tell whether a WAL record has already been applied to a page on disk.
    pub fn append(self: *WAL, page_id: u32, offset: u16, payload: []const u8) !u64 {
        const type_byte: u8 = @intFromEnum(RecordType.data);
        const payload_len: u32 = @intCast(payload.len);
        const lsn = self.next_lsn;

        // CRC32 covers every field in the record except the checksum itself.
        var hasher = std.hash.Crc32.init();
        hasher.update(&.{type_byte});
        hasher.update(&intBytes(u32, payload_len));
        hasher.update(&intBytes(u64, lsn));
        hasher.update(&intBytes(u32, page_id));
        hasher.update(&intBytes(u16, offset));
        hasher.update(payload);

        try self.appendInt(u8, type_byte);
        try self.appendInt(u32, hasher.final());
        try self.appendInt(u32, payload_len);
        try self.appendInt(u64, lsn);
        try self.appendInt(u32, page_id);
        try self.appendInt(u16, offset);
        try self.buffer.appendSlice(self.alloc, payload);

        self.next_lsn += RECORD_HEADER_SIZE + @as(u64, payload_len);
        return lsn;
    }

    // Write a commit marker as the final WAL entry for a transaction.
    // Must be called before flush() so the marker reaches disk atomically
    // with the preceding data records.
    // timestamp_us is microseconds since Unix epoch, provided by the caller
    // so WAL stays clock-agnostic and tests can inject deterministic values.
    pub fn appendCommit(self: *WAL, timestamp_us: u64) !void {
        try self.appendInt(u8, @intFromEnum(RecordType.commit));
        try self.appendInt(u64, timestamp_us);
        self.next_lsn += COMMIT_SIZE;
    }

    // Replay WAL records to bring pages up to date after a crash.
    // Only records from transactions that ended with a commit marker are applied;
    // trailing records without a commit marker are discarded (the transaction
    // that wrote them never completed, so their changes must not be visible).
    // After recovery, rotates to a fresh segment and writes a checkpoint so the
    // next open does not need to replay the recovered records again.
    pub fn recover(self: *WAL, pager: *Pager, alloc: std.mem.Allocator) !void {
        var wal_reader = self.reader();
        self.next_lsn = try wal_reader.readHeader();

        var pending: std.ArrayList(Record) = .empty;
        defer {
            for (pending.items) |r| alloc.free(r.payload);
            pending.deinit(alloc);
        }

        var buffer: [t.PAGE_SIZE]u8 = undefined;

        while (try wal_reader.next(alloc)) |entry| {
            switch (entry) {
                .data => |record| try pending.append(alloc, record),
                .commit => {
                    for (pending.items) |record| {
                        try pager.readPage(record.page_id, &buffer);
                        const offset: usize = @intCast(record.offset);
                        if (offset + record.payload.len > t.PAGE_SIZE) return error.CorruptWAL;
                        const page_lsn = std.mem.readInt(u64, buffer[@offsetOf(t.PageHeader, "lsn")..][0..8], .little);
                        if (page_lsn < record.lsn) {
                            @memcpy(buffer[offset .. offset + record.payload.len], record.payload);
                            std.mem.writeInt(u64, buffer[@offsetOf(t.PageHeader, "lsn")..][0..8], record.lsn, .little);
                            try pager.writePage(record.page_id, &buffer, &.{});
                        }
                    }
                    for (pending.items) |record| alloc.free(record.payload);
                    pending.clearRetainingCapacity();
                    self.next_lsn = wal_reader.offset - @sizeOf(u64);
                },
            }
        }

        // Restore page0 metadata that may have been updated by the records above.
        var p0: [t.PAGE_SIZE]u8 = undefined;
        if (pager.readPage(0, &p0)) |_| {
            const off = @sizeOf(t.PageHeader);
            const h = std.mem.bytesToValue(t.DbHeader, p0[off..][0..@sizeOf(t.DbHeader)]);
            if (h.magic == t.DB_MAGIC) {
                pager.total_pages = h.total_pages;
                pager.free_list_head = h.free_list_head;
                pager.sys_tables_root = h.sys_tables_root;
                pager.sys_columns_root = h.sys_columns_root;
            }
        } else |_| {}

        // Flush recovered pages to disk, then rotate to a fresh segment so
        // the next open does not replay these records again.
        try pager.flush();
        try self.rotateAfterCheckpoint();
    }
};

// ── WAL records ───────────────────────────────────────────────────────────────

pub const Record = struct {
    lsn: u64,
    page_id: u32,
    offset: u16,
    payload: []const u8,
};

// WALReader.next() returns this so callers can distinguish data records from
// commit markers without a separate call.
pub const WALEntry = union(enum) {
    data: Record,
    commit: u64, // microseconds since Unix epoch when the transaction committed
};

pub const WALReader = struct {
    wal: *WAL,
    offset: usize,
    initialized: bool = false,

    pub fn readHeader(self: *WALReader) !u64 {
        self.initialized = true;
        return self.readInt(u64) catch |err| switch (err) {
            error.EndOfStream => return 0,
            else => return err,
        };
    }

    pub fn next(self: *WALReader, alloc: std.mem.Allocator) !?WALEntry {
        if (!self.initialized) return WALError.ReaderNotInitialized;

        const type_byte = self.readInt(u8) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        const record_type: RecordType = switch (type_byte) {
            @intFromEnum(RecordType.data) => .data,
            @intFromEnum(RecordType.commit) => .commit,
            else => return WALError.CorruptWAL,
        };

        switch (record_type) {
            .commit => {
                // A truncated timestamp means the commit marker itself was torn;
                // treat as end-of-log (transaction never completed).
                const timestamp_us = self.readInt(u64) catch return null;
                return .{ .commit = timestamp_us };
            },
            .data => {
                // If the file is truncated mid-record (crash during write), treat it as
                // end of valid records rather than a hard error.
                const stored = self.readInt(u32) catch return null;
                const length = self.readInt(u32) catch return null;
                const lsn = self.readInt(u64) catch return WALError.CorruptWAL;
                const page_id = self.readInt(u32) catch return WALError.CorruptWAL;
                const offset = self.readInt(u16) catch return WALError.CorruptWAL;

                const payload = try alloc.alloc(u8, length);
                errdefer alloc.free(payload);
                const n = try self.wal.file.readAt(payload, self.offset);
                if (n != length) return WALError.CorruptWAL;
                self.offset += @intCast(length);

                var hasher = std.hash.Crc32.init();
                hasher.update(&.{type_byte});
                hasher.update(&WAL.intBytes(u32, length));
                hasher.update(&WAL.intBytes(u64, lsn));
                hasher.update(&WAL.intBytes(u32, page_id));
                hasher.update(&WAL.intBytes(u16, offset));
                hasher.update(payload);
                if (hasher.final() != stored) return WALError.InvalidChecksum;

                return .{ .data = Record{
                    .lsn = lsn,
                    .offset = offset,
                    .page_id = page_id,
                    .payload = payload,
                } };
            },
        }
    }

    fn readInt(self: *WALReader, comptime T: type) !T {
        var buffer: [@sizeOf(T)]u8 = undefined;
        const n = try self.wal.file.readAt(&buffer, self.offset);
        if (n != @sizeOf(T)) return error.EndOfStream;
        self.offset += @sizeOf(T);
        return std.mem.readInt(T, &buffer, .little);
    }
};
