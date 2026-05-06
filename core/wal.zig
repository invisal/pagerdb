// Write-ahead log (WAL) for STEAL/NO-FORCE durability.
//
// Every page mutation is recorded in the WAL before the modified page may
// reach the data file (the WAL rule). At commit time, only the WAL is fsynced;
// data pages are flushed lazily via checkpoint.  On crash, the redo pass
// replays WAL records forward from the last checkpoint to recover committed
// state.
//
// File layout:
//   [0..63]  WalHeader  — magic, LSN counter, checkpoint position
//   [64+]    records    — fixed-size RedoHeader, followed by PAGE_SIZE bytes
//                         of page data for page_image records
const std = @import("std");
const t = @import("types.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Allocator = std.mem.Allocator;

pub const WAL_MAGIC: u32 = 0x57414C47; // "WALG"
pub const WAL_VERSION: u16 = 1;

pub const RecordType = enum(u8) {
    page_image = 1,
    commit = 2,
    checkpoint = 3,
};

// 4+2+2+8+8+8+32 = 64 bytes, stored at file offset 0.
pub const WalHeader = extern struct {
    magic: u32,
    version: u16,
    _pad: u16,
    next_lsn: u64,
    checkpoint_lsn: u64,
    write_offset: u64,
    _reserved: [32]u8,
};

// 8+4+4+1+7 = 24 bytes, followed by PAGE_SIZE bytes for page_image records.
pub const RedoHeader = extern struct {
    lsn: u64,
    txn_id: u32,
    page_id: u32,
    record_type: u8,
    _pad: [7]u8,
};

comptime {
    std.debug.assert(@sizeOf(WalHeader) == 64);
    std.debug.assert(@sizeOf(RedoHeader) == 24);
}

// A redo record deserialized during recovery.
pub const RedoRecord = struct {
    header: RedoHeader,
    // Non-null only for page_image records.
    page_data: ?[t.PAGE_SIZE]u8,
};

pub const Wal = struct {
    file: File,
    io: Io,
    allocator: Allocator,
    // Heap-owned copy of the WAL file path, used for rotation on checkpoint.
    path: []u8,
    next_lsn: u64,
    checkpoint_lsn: u64,
    // Current append position in the WAL file (bytes from start).
    write_offset: u64,
    // Highest LSN that has been fsynced to the WAL file.
    // The WAL rule: a dirty page may only reach the data file when
    // frame.lsn <= last_fsynced_lsn.
    last_fsynced_lsn: u64,

    // Create a brand-new WAL file, overwriting any existing one.
    pub fn create(allocator: Allocator, io: Io, path: []const u8) !Wal {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        const file = try Dir.cwd().createFile(io, path, .{ .read = true });
        errdefer file.close(io);

        var self = Wal{
            .file = file,
            .io = io,
            .allocator = allocator,
            .path = owned_path,
            .next_lsn = 1,
            .checkpoint_lsn = 0,
            .write_offset = @sizeOf(WalHeader),
            .last_fsynced_lsn = 0,
        };
        try self.writeFileHeader();
        return self;
    }

    // Open an existing WAL file, or create a fresh one if it doesn't exist.
    pub fn open(allocator: Allocator, io: Io, path: []const u8) !Wal {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        const file = Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| {
            if (err == error.FileNotFound) {
                // No WAL file means the database is at a clean checkpoint state.
                allocator.free(owned_path);
                return create(allocator, io, path);
            }
            return err;
        };
        errdefer file.close(io);

        var hdr_buf: [@sizeOf(WalHeader)]u8 align(@alignOf(WalHeader)) = undefined;
        const n = try file.readPositionalAll(io, &hdr_buf, 0);
        if (n != @sizeOf(WalHeader)) return error.InvalidWalHeader;

        const hdr: *const WalHeader = @ptrCast(&hdr_buf);
        if (hdr.magic != WAL_MAGIC) return error.InvalidWalHeader;
        if (hdr.version != WAL_VERSION) return error.UnsupportedWalVersion;

        return Wal{
            .file = file,
            .io = io,
            .allocator = allocator,
            .path = owned_path,
            .next_lsn = hdr.next_lsn,
            .checkpoint_lsn = hdr.checkpoint_lsn,
            .write_offset = hdr.write_offset,
            // Conservative: assume nothing is fsynced yet (we don't persist this).
            .last_fsynced_lsn = 0,
        };
    }

    // Append a page image record and return the assigned LSN.
    // Must be called before the corresponding buffer pool frame is modified
    // (WAL rule: log before data).
    pub fn appendPageImage(self: *Wal, txn_id: u32, page_id: u32, data: *const [t.PAGE_SIZE]u8) !u64 {
        const lsn = self.next_lsn;
        self.next_lsn += 1;

        const hdr = RedoHeader{
            .lsn = lsn,
            .txn_id = txn_id,
            .page_id = page_id,
            .record_type = @intFromEnum(RecordType.page_image),
            ._pad = std.mem.zeroes([7]u8),
        };
        try self.file.writePositionalAll(self.io, std.mem.asBytes(&hdr), self.write_offset);
        self.write_offset += @sizeOf(RedoHeader);
        try self.file.writePositionalAll(self.io, data, self.write_offset);
        self.write_offset += t.PAGE_SIZE;
        return lsn;
    }

    // Append a COMMIT marker for the given transaction.
    // Called just before wal.flush() at commit time.
    pub fn appendCommit(self: *Wal, txn_id: u32) !void {
        const lsn = self.next_lsn;
        self.next_lsn += 1;
        const hdr = RedoHeader{
            .lsn = lsn,
            .txn_id = txn_id,
            .page_id = 0,
            .record_type = @intFromEnum(RecordType.commit),
            ._pad = std.mem.zeroes([7]u8),
        };
        try self.file.writePositionalAll(self.io, std.mem.asBytes(&hdr), self.write_offset);
        self.write_offset += @sizeOf(RedoHeader);
    }

    // Fsync the WAL file and update last_fsynced_lsn.
    // After this returns, all previously appended records are durable.
    pub fn flush(self: *Wal) !void {
        try self.writeFileHeader();
        try self.file.sync(self.io);
        self.last_fsynced_lsn = self.next_lsn - 1;
    }

    // Rotate the WAL after a checkpoint: delete the old file and start fresh.
    // The caller must have already flushed all dirty data pages to the data
    // file and fsynced it before calling this.  The new WAL starts with an
    // updated checkpoint_lsn so recovery knows where to begin.
    pub fn rotate(self: *Wal, checkpoint_lsn: u64) !void {
        self.file.close(self.io);
        // Delete old WAL; ignore error if it was already gone.
        Dir.deleteFile(.cwd(), self.io, self.path) catch {};

        self.file = try Dir.cwd().createFile(self.io, self.path, .{ .read = true });
        self.checkpoint_lsn = checkpoint_lsn;
        self.write_offset = @sizeOf(WalHeader);
        self.last_fsynced_lsn = self.next_lsn - 1;
        try self.writeFileHeader();
        try self.file.sync(self.io);
    }

    // Read all redo records at or after start_lsn.  Used during crash recovery.
    // Caller owns the returned slice.
    pub fn readFrom(self: *Wal, start_lsn: u64, allocator: Allocator) ![]RedoRecord {
        var records = std.ArrayList(RedoRecord).init(allocator);
        errdefer records.deinit();

        const file_size = try self.file.length(self.io);
        var offset: u64 = @sizeOf(WalHeader);

        while (offset + @sizeOf(RedoHeader) <= file_size) {
            var hdr_buf: [@sizeOf(RedoHeader)]u8 align(@alignOf(RedoHeader)) = undefined;
            const n = try self.file.readPositionalAll(self.io, &hdr_buf, offset);
            if (n != @sizeOf(RedoHeader)) break;

            const hdr: *const RedoHeader = @ptrCast(&hdr_buf);
            offset += @sizeOf(RedoHeader);

            const rec_type: RecordType = @enumFromInt(hdr.record_type);
            if (rec_type == .page_image) {
                if (hdr.lsn >= start_lsn) {
                    var page_data: [t.PAGE_SIZE]u8 = undefined;
                    const m = try self.file.readPositionalAll(self.io, &page_data, offset);
                    if (m != t.PAGE_SIZE) break;
                    try records.append(.{ .header = hdr.*, .page_data = page_data });
                }
                offset += t.PAGE_SIZE;
            } else {
                if (hdr.lsn >= start_lsn) {
                    try records.append(.{ .header = hdr.*, .page_data = null });
                }
            }
        }

        return records.toOwnedSlice();
    }

    pub fn close(self: *Wal) void {
        self.writeFileHeader() catch {};
        self.file.close(self.io);
        self.allocator.free(self.path);
    }

    fn writeFileHeader(self: *Wal) !void {
        const hdr = WalHeader{
            .magic = WAL_MAGIC,
            .version = WAL_VERSION,
            ._pad = 0,
            .next_lsn = self.next_lsn,
            .checkpoint_lsn = self.checkpoint_lsn,
            .write_offset = self.write_offset,
            ._reserved = std.mem.zeroes([32]u8),
        };
        try self.file.writePositionalAll(self.io, std.mem.asBytes(&hdr), 0);
    }
};
