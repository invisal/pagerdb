const std = @import("std");
const t = @import("types.zig");
const Pager = @import("pager/pager.zig").Pager;
const page0 = @import("page0.zig");

// UndoEntry describes one DML operation in reverse, enough to undo it.
// Moved here (out of txn.zig) because txn.zig needs to import UndoLog,
// which would create a circular dependency if UndoEntry lived in txn.zig.
pub const UndoEntry = union(enum) {
    // Undo an INSERT: delete the row that was inserted.
    insert: struct { table: []const u8, rowid: u64 },
    // Undo a DELETE: re-insert the original row bytes at the same rowid.
    delete: struct { table: []const u8, rowid: u64, row_bytes: []const u8 },
    // Undo an UPDATE: discard the new row, restore the original bytes.
    update: struct { table: []const u8, rowid: u64, old_row_bytes: []const u8 },
};

// Append-only undo log stored as a chain of UndoPage pages inside the
// database file.  The head page ID is kept in pager.undo_head; zero means
// no active log and the database is in a consistent committed state.
//
// Each record is force-flushed to disk immediately after being written so it
// survives a crash even though data pages are pinned in the buffer pool
// (no-steal policy) and will not reach disk until commit.
//
// Write order per DML:
//   1. append() → write undo record → flushPage (durable)
//   2. btree operation → writePage (stays in buffer pool, pinned)
//
// If the process crashes after step 1 but before commit's flush:
//   - Data pages are in pre-transaction state on disk (no-steal guarantee)
//   - undo_head != 0 on disk signals recovery needed
//   - recoverIfNeeded() in Db.load() frees the orphaned undo pages and
//     resets undo_head to 0; no data replay is required
pub const UndoLog = struct {
    pager: *Pager,
    head_page: u32,
    cur_page: u32,
    write_offset: u16, // next free byte offset within cur_page.data
    // The WAL transaction ID that owns this undo log.  Stored in the first
    // undo page's header.lsn field so crash recovery can check whether the
    // transaction committed without reading the full WAL.
    txn_id: u32,

    // Allocate the first undo page, force it to disk, and persist undo_head
    // in the database header so a crash after begin() is detectable on reopen.
    // txn_id is the WAL transaction ID assigned by the pager at beginTxn().
    pub fn begin(pager: *Pager, txn_id: u32) !UndoLog {
        const page_id = try pager.allocPage();
        var buf: [t.PAGE_SIZE]u8 align(@alignOf(t.UndoPage)) = std.mem.zeroes([t.PAGE_SIZE]u8);
        const up: *t.UndoPage = @ptrCast(&buf);
        // Store txn_id in header.lsn so recovery can identify which WAL
        // transaction owns this undo chain without scanning the full WAL.
        up.header = .{ .page_type = .undo, .flags = 0, .checksum = 0, .lsn = txn_id };
        up.next_page = 0;
        up.data_len = 0;
        try pager.writePage(page_id, &buf);
        try pager.flushPage(page_id);

        pager.undo_head = page_id;
        try page0.writeHeader(pager);
        try pager.flushPage(0);

        return .{
            .pager = pager,
            .head_page = page_id,
            .cur_page = page_id,
            .write_offset = 0,
            .txn_id = txn_id,
        };
    }

    // Open an UndoLog from an existing page chain (used during crash recovery).
    // Reads the head page to extract the txn_id stored in header.lsn.
    pub fn fromHead(pager: *Pager, head_page: u32) !UndoLog {
        var buf: [t.PAGE_SIZE]u8 align(@alignOf(t.UndoPage)) = undefined;
        try pager.readPage(head_page, &buf);
        const up: *const t.UndoPage = @ptrCast(&buf);
        const txn_id: u32 = @truncate(up.header.lsn);
        return .{
            .pager = pager,
            .head_page = head_page,
            .cur_page = head_page,
            .write_offset = 0,
            .txn_id = txn_id,
        };
    }

    // Serialize entry and append to the current undo page, allocating a new
    // page when the current one is full.  Flushes the page to disk before
    // returning so the record is durable.
    pub fn append(self: *UndoLog, entry: UndoEntry) !void {
        const size = serializedSize(entry);
        const capacity: usize = t.PAGE_SIZE - 24;
        if (size > capacity) return error.UndoRecordTooLarge;

        var buf: [t.PAGE_SIZE]u8 align(@alignOf(t.UndoPage)) = undefined;
        try self.pager.readPage(self.cur_page, &buf);
        var up: *t.UndoPage = @ptrCast(&buf);

        if (@as(usize, self.write_offset) + size > capacity) {
            // Current page is full; link in a fresh one.
            const new_page_id = try self.pager.allocPage();
            up.next_page = new_page_id;
            try self.pager.writePage(self.cur_page, &buf);
            try self.pager.flushPage(self.cur_page);

            var new_buf: [t.PAGE_SIZE]u8 align(@alignOf(t.UndoPage)) = std.mem.zeroes([t.PAGE_SIZE]u8);
            const new_up: *t.UndoPage = @ptrCast(&new_buf);
            new_up.header = .{ .page_type = .undo, .flags = 0, .checksum = 0, .lsn = 0 };
            new_up.next_page = 0;
            new_up.data_len = 0;
            try self.pager.writePage(new_page_id, &new_buf);
            try self.pager.flushPage(new_page_id);

            self.cur_page = new_page_id;
            self.write_offset = 0;

            try self.pager.readPage(self.cur_page, &buf);
            up = @ptrCast(&buf);
        }

        serializeEntryInto(entry, up.data[self.write_offset..]);
        self.write_offset += @intCast(size);
        up.data_len = self.write_offset;
        try self.pager.writePage(self.cur_page, &buf);
        try self.pager.flushPage(self.cur_page);
    }

    // Walk the page chain and deserialize all undo entries into a heap slice.
    // Used during crash recovery when steal is implemented.  Caller owns the
    // returned slice and must free each entry's string/byte fields.
    pub fn readAll(self: *UndoLog, allocator: std.mem.Allocator) ![]UndoEntry {
        var entries: std.ArrayListUnmanaged(UndoEntry) = .empty;
        errdefer entries.deinit(allocator);

        var page_id = self.head_page;
        while (page_id != 0) {
            var buf: [t.PAGE_SIZE]u8 align(@alignOf(t.UndoPage)) = undefined;
            try self.pager.readPage(page_id, &buf);
            const up: *const t.UndoPage = @ptrCast(&buf);
            const valid = up.data[0..up.data_len];

            var offset: usize = 0;
            while (offset < valid.len) {
                try entries.append(allocator, try deserializeEntry(valid, &offset, allocator));
            }
            page_id = up.next_page;
        }

        return entries.toOwnedSlice(allocator);
    }

    // Free all pages in the chain and clear pager.undo_head.
    // Does NOT flush — the caller must flush afterwards so the freed pages
    // and the undo_head=0 header update land in the same fsync as the data pages.
    pub fn discard(self: *UndoLog) !void {
        var page_id = self.head_page;
        while (page_id != 0) {
            var buf: [t.PAGE_SIZE]u8 align(@alignOf(t.UndoPage)) = undefined;
            try self.pager.readPage(page_id, &buf);
            const up: *const t.UndoPage = @ptrCast(&buf);
            const next = up.next_page;
            try self.pager.freePage(page_id);
            page_id = next;
        }
        self.pager.undo_head = 0;
    }
};

// ── Serialization ─────────────────────────────────────────────────────────────
//
// Record wire format (all integers little-endian):
//   type:          u8   (1 = insert, 2 = delete, 3 = update)
//   table_len:     u16
//   table:         [table_len]u8
//   rowid:         u64
//   row_bytes_len: u32  (0 for insert)
//   row_bytes:     [row_bytes_len]u8

fn serializedSize(entry: UndoEntry) usize {
    const fixed = 1 + 2 + 8 + 4; // type + table_len + rowid + row_bytes_len
    return switch (entry) {
        .insert => |e| fixed + e.table.len,
        .delete => |e| fixed + e.table.len + e.row_bytes.len,
        .update => |e| fixed + e.table.len + e.old_row_bytes.len,
    };
}

fn serializeEntryInto(entry: UndoEntry, buf: []u8) void {
    var pos: usize = 0;
    switch (entry) {
        .insert => |e| {
            buf[pos] = 1;
            pos += 1;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(e.table.len), .little);
            pos += 2;
            @memcpy(buf[pos..][0..e.table.len], e.table);
            pos += e.table.len;
            std.mem.writeInt(u64, buf[pos..][0..8], e.rowid, .little);
            pos += 8;
            std.mem.writeInt(u32, buf[pos..][0..4], 0, .little);
        },
        .delete => |e| {
            buf[pos] = 2;
            pos += 1;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(e.table.len), .little);
            pos += 2;
            @memcpy(buf[pos..][0..e.table.len], e.table);
            pos += e.table.len;
            std.mem.writeInt(u64, buf[pos..][0..8], e.rowid, .little);
            pos += 8;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(e.row_bytes.len), .little);
            pos += 4;
            @memcpy(buf[pos..][0..e.row_bytes.len], e.row_bytes);
        },
        .update => |e| {
            buf[pos] = 3;
            pos += 1;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(e.table.len), .little);
            pos += 2;
            @memcpy(buf[pos..][0..e.table.len], e.table);
            pos += e.table.len;
            std.mem.writeInt(u64, buf[pos..][0..8], e.rowid, .little);
            pos += 8;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(e.old_row_bytes.len), .little);
            pos += 4;
            @memcpy(buf[pos..][0..e.old_row_bytes.len], e.old_row_bytes);
        },
    }
}

fn deserializeEntry(data: []const u8, offset: *usize, allocator: std.mem.Allocator) !UndoEntry {
    const entry_type = data[offset.*];
    offset.* += 1;

    const table_len = std.mem.readInt(u16, data[offset.*..][0..2], .little);
    offset.* += 2;
    const table = try allocator.dupe(u8, data[offset.*..][0..table_len]);
    errdefer allocator.free(table);
    offset.* += table_len;

    const rowid = std.mem.readInt(u64, data[offset.*..][0..8], .little);
    offset.* += 8;

    const row_bytes_len = std.mem.readInt(u32, data[offset.*..][0..4], .little);
    offset.* += 4;

    switch (entry_type) {
        1 => return .{ .insert = .{ .table = table, .rowid = rowid } },
        2 => {
            const row_bytes = try allocator.dupe(u8, data[offset.*..][0..row_bytes_len]);
            offset.* += row_bytes_len;
            return .{ .delete = .{ .table = table, .rowid = rowid, .row_bytes = row_bytes } };
        },
        3 => {
            const old_row_bytes = try allocator.dupe(u8, data[offset.*..][0..row_bytes_len]);
            offset.* += row_bytes_len;
            return .{ .update = .{ .table = table, .rowid = rowid, .old_row_bytes = old_row_bytes } };
        },
        else => return error.InvalidUndoRecord,
    }
}
