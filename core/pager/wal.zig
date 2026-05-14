// Write-Ahead Log (WAL) — guarantees crash safety by writing changes here
// before touching data pages, so recovery can replay any missing writes.
//
// File layout:
//
//   [ next_lsn: u64 ]  ← file header; restored on open so LSNs never repeat
//   [ record ... ]     ← data records, one per page delta
//   [ record ... ]
//   [ commit ]         ← commit marker; ends one transaction group
//   [ record ... ]     ← next transaction begins here
//   ...
//
// Record formats:
//
//   Data   (type=0):  [type:u8 | checksum:u32 | payload_len:u32 | lsn:u64 | page_id:u32 | offset:u16 | payload...]
//   Commit (type=1):  [type:u8]
//
//   The data record checksum (CRC32) covers every field except itself.
//   A bad checksum or truncated read means the record was partially written
//   during a crash and is treated as end-of-log.
//   The commit record has no checksum — truncation detection is sufficient
//   since it carries no variable data.
//
// Write protocol:  append data records → appendCommit → flush (fsync) → write data pages → fsync
//   Crash before flush: no commit marker, recovery discards the records.
//   Crash after flush:  commit marker present, recovery replays the records.
//
// Recovery: buffer data records until commit marker, then apply them all.
//   Trailing records with no commit marker are discarded. WAL is reset after.

const std = @import("std");
const t = @import("../types.zig");
const Pager = @import("pager.zig").Pager;

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
    commit: void,
};

pub const WAL = struct {
    file: std.Io.File,
    io: std.Io,
    next_lsn: u64,
    buffer: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    offset: usize,

    // Create a new WAL file and write the initial LSN header.
    pub fn create(io: std.Io, path: []const u8, alloc: std.mem.Allocator) !WAL {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true });
        var wal = WAL{ .file = file, .io = io, .next_lsn = 0, .buffer = .empty, .alloc = alloc, .offset = 0 };
        try wal.reset();
        return wal;
    }

    // Open an existing WAL file, or create it if it doesn't exist.
    // Caller must run wal.recover() before use if the file already existed.
    pub fn open(io: std.Io, path: []const u8, alloc: std.mem.Allocator) !WAL {
        const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => return create(io, path, alloc),
            else => return err,
        };
        return WAL{ .file = file, .io = io, .next_lsn = 0, .buffer = .empty, .alloc = alloc, .offset = 0 };
    }

    pub fn deinit(self: *WAL) void {
        self.file.close(self.io);
        self.buffer.deinit(self.alloc);
    }

    pub fn reader(self: *WAL) WALReader {
        return .{
            .wal = self,
            .offset = 0,
        };
    }

    pub fn flush(self: *WAL) !void {
        try self.file.writePositionalAll(self.io, self.buffer.items, self.offset);
        self.offset += self.buffer.items.len;

        try self.file.sync(self.io);
        self.buffer.clearRetainingCapacity();
    }

    pub fn reset(self: *WAL) !void {
        self.offset = 0;
        try self.file.setLength(self.io, 0);

        try self.appendInt(u64, self.next_lsn);
        try self.flush();
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
    pub fn appendCommit(self: *WAL) !void {
        try self.appendInt(u8, @intFromEnum(RecordType.commit));
        self.next_lsn += 1;
    }

    // Replay WAL records to bring pages up to date after a crash.
    // Only records from transactions that ended with a commit marker are applied;
    // trailing records without a commit marker are discarded (the transaction
    // that wrote them never completed, so their changes must not be visible).
    pub fn recover(self: *WAL, pager: *Pager, alloc: std.mem.Allocator) !void {
        var wal_reader = self.reader();

        // An empty WAL file means no records were ever written; nothing to recover.
        self.next_lsn = try wal_reader.readHeader();

        // Accumulate data records until we see a commit marker, then apply them.
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
                    // Apply first, free after. If an error is returned mid-loop
                    // the outer defer owns all payloads in pending and frees them,
                    // so no defer inside the loop to avoid a double-free.
                    for (pending.items) |record| {
                        try pager.readPage(record.page_id, &buffer);
                        const offset: usize = @intCast(record.offset);
                        if (offset + record.payload.len > t.PAGE_SIZE) return error.CorruptWAL;
                        if (t.PageHeader.readLSN(&buffer) < record.lsn) {
                            @memcpy(buffer[offset .. offset + record.payload.len], record.payload);
                            t.PageHeader.writeLSN(&buffer, record.lsn);
                            try pager.writePage(record.page_id, &buffer, &.{});
                        }
                    }
                    for (pending.items) |record| alloc.free(record.payload);
                    pending.clearRetainingCapacity();
                    // Advance next_lsn to just past this commit marker so that
                    // new LSNs never collide with any record already on disk.
                    self.next_lsn = wal_reader.offset - @sizeOf(u64);
                },
            }
        }
        // Records still in `pending` have no commit marker — discard them.

        // page0 may have been restored into the buffer pool by the WAL records
        // above with values that differ from what DiskPager.open() loaded at
        // startup (because the crash happened before page0 reached disk).
        // Re-read page0 now so the diskFlush inside pager.flush() writes the
        // correct metadata rather than the stale values from open time.
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

        try pager.flush();
        try self.reset();
    }
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
            .commit => return .{ .commit = {} },
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
                const n = try self.wal.file.readPositionalAll(self.wal.io, payload, self.offset);
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
        const n = try self.wal.file.readPositionalAll(self.wal.io, &buffer, self.offset);
        if (n != @sizeOf(T)) return error.EndOfStream;
        self.offset += @sizeOf(T);
        return std.mem.readInt(T, &buffer, .little);
    }
};
