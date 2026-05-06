const std = @import("std");
const t = @import("types.zig");
const Pager = @import("pager/pager.zig").Pager;
const DiskPager = @import("pager/disk.zig").DiskPager;
const wal_mod = @import("wal.zig");
const Wal = wal_mod.Wal;
const page0 = @import("page0.zig");
const btree = @import("btree.zig");
const row = @import("row.zig");
const catalog = @import("catalog.zig");
const overflow = @import("overflow.zig");
const txn_mod = @import("txn.zig");
const undo_log_mod = @import("undo_log.zig");

// Database handle.  Must be heap-allocated (via init() or load()) because
// catalog.pager is a pointer that must remain valid for the lifetime of the
// catalog.  Using a stack-allocated Db would create a dangling pointer if the
// caller moves the struct (e.g. returning it from a function).
pub const Db = struct {
    allocator: std.mem.Allocator,
    pager: Pager,
    cat: catalog.Catalog,
    // null = auto-commit mode; non-null = inside an explicit transaction
    txn: ?txn_mod.Transaction,

    // Bootstrap the system catalog on a freshly-created pager.
    // Caller owns the returned pointer; release with db.close().
    pub fn init(pager: Pager, allocator: std.mem.Allocator) !*Db {
        const db = try allocator.create(Db);
        errdefer allocator.destroy(db);
        db.allocator = allocator;
        db.pager = pager;
        db.cat = catalog.Catalog.init(allocator, &db.pager);
        db.txn = null;
        try db.cat.bootstrap();
        try db.pager.flush();
        return db;
    }

    // Load the catalog from a pager that already contains database pages.
    // For WAL-backed pagers, runs three-pass ARIES-style recovery:
    //   1. Analysis — collect committed txn_ids from WAL
    //   2. Redo     — replay all WAL page images into buffer pool
    //   3. Undo     — revert any uncommitted changes found on disk
    pub fn load(pager: Pager, allocator: std.mem.Allocator) !*Db {
        const db = try allocator.create(Db);
        errdefer allocator.destroy(db);
        db.allocator = allocator;
        db.pager = pager;
        db.cat = catalog.Catalog.init(allocator, &db.pager);
        db.txn = null;

        if (db.pager.has_wal) {
            const disk_pager: *DiskPager = @ptrCast(@alignCast(db.pager.ptr));

            // Pass 1: find all txn_ids that have a durable COMMIT record in the WAL.
            var committed_txns = try analysisPass(&disk_pager.wal, allocator);
            defer committed_txns.deinit();

            // Pass 2: replay every WAL page image into the buffer pool.  After this
            // the buffer pool reflects the last consistent committed state.
            try redoPass(db, &disk_pager.wal, allocator);

            // Sync pager fields (total_pages, undo_head, etc.) from the redo'd page 0.
            try updatePagerFromPage0(db);

            // Load catalog from the redo'd btree pages so undo replay has correct roots.
            try db.cat.load();

            // Pass 3: undo uncommitted changes; skip committed transactions.
            try db.recoverIfNeeded(&committed_txns);
        } else {
            // InMemoryPager: no WAL, no crash recovery needed.
            // Call recoverIfNeeded with an empty committed set (undo_head is always 0).
            try db.cat.load();
            var empty = std.AutoHashMap(u32, void).init(allocator);
            defer empty.deinit();
            try db.recoverIfNeeded(&empty);
        }

        return db;
    }

    // Undo any in-flight transaction left by a crash.
    //
    // committed_txns: set of txn_ids that have a durable COMMIT record in the WAL.
    // If undo_head points to a committed transaction, skip undo and just clean up
    // the undo chain (the redo pass already restored the committed data).
    //
    // With STEAL, dirty pages from an uncommitted transaction may have reached
    // the data file before the crash.  For those we replay the undo log in reverse
    // to restore the pre-transaction state, then FORCE-flush.
    //
    // WAL bypass is set so recovery writes do not produce new redo log records.
    fn recoverIfNeeded(self: *Db, committed_txns: *const std.AutoHashMap(u32, void)) !void {
        if (self.pager.undo_head == 0) return;

        var ul = try undo_log_mod.UndoLog.fromHead(&self.pager, self.pager.undo_head);

        // Bypass WAL during all recovery writes (undo replay + discard cleanup).
        self.pager.setWalBypass(true);
        defer self.pager.setWalBypass(false);

        if (committed_txns.contains(ul.txn_id)) {
            // The transaction committed but the undo chain wasn't cleaned up before
            // the crash (e.g. crash between COMMIT fsync and page-0 flush).
            // Discard the chain without replaying it; redo already applied the data.
            try ul.discard();
            try self.pager.flush();
            return;
        }

        // Uncommitted transaction: replay undo entries in reverse to revert changes.
        const entries = try ul.readAll(self.allocator);
        defer {
            for (entries) |entry| switch (entry) {
                .insert => |e| self.allocator.free(e.table),
                .delete => |e| {
                    self.allocator.free(e.table);
                    self.allocator.free(e.row_bytes);
                },
                .update => |e| {
                    self.allocator.free(e.table);
                    self.allocator.free(e.old_row_bytes);
                },
            };
            self.allocator.free(entries);
        }

        var i: usize = entries.len;
        while (i > 0) {
            i -= 1;
            switch (entries[i]) {
                .insert => |e| {
                    const meta = self.cat.getTable(e.table) orelse continue;
                    _ = try btree.delete(&self.pager, meta.btree_root, e.rowid);
                },
                .delete => |e| {
                    const meta = self.cat.getTable(e.table) orelse continue;
                    try btree.insert(&self.pager, meta.btree_root, e.rowid, e.row_bytes, true);
                },
                .update => |e| {
                    const meta = self.cat.getTable(e.table) orelse continue;
                    _ = try btree.delete(&self.pager, meta.btree_root, e.rowid);
                    try btree.insert(&self.pager, meta.btree_root, e.rowid, e.old_row_bytes, true);
                },
            }
        }

        try ul.discard();
        try self.pager.flush();
    }

    // Flush dirty pages, close the file, free catalog memory, and destroy self.
    // If a transaction is still open it is rolled back before closing.
    pub fn close(self: *Db) void {
        if (self.txn != null) self.rollback() catch {};
        self.pager.flush() catch {};
        self.pager.close();
        self.cat.deinit();
        self.allocator.destroy(self);
    }

    // Flush all dirty buffer pool pages to the data file and rotate the WAL.
    // After a checkpoint, crash recovery only needs to replay WAL records
    // written after this point, keeping recovery time bounded.
    // Must not be called while a transaction is active.
    pub fn checkpoint(self: *Db) !void {
        if (self.txn != null) return error.TransactionAlreadyActive;
        try self.pager.checkpoint();
    }

    // Begin an explicit transaction.  DML operations will be buffered in the
    // undo log and the pager will not be flushed until commit() is called.
    // An undo log page chain is started and force-flushed to disk so that a
    // crash before commit() is detectable on next open (pager.undo_head != 0).
    pub fn begin(self: *Db) !void {
        if (self.txn != null) return error.TransactionAlreadyActive;
        // beginTxn must come first so getTxnId() returns the assigned ID.
        self.pager.beginTxn();
        const txn_id = self.pager.getTxnId();
        self.txn = txn_mod.Transaction.init(self.allocator);
        self.txn.?.log_file = try undo_log_mod.UndoLog.begin(&self.pager, txn_id);
    }

    // Commit the active transaction using NO-FORCE: fsync the WAL COMMIT record
    // first (making the transaction durable), then flush page 0 with undo_head=0
    // to disk, then clean up undo log pages.
    //
    // Ordering is critical for crash safety:
    //   1. commitTxn()       — COMMIT record fsynced; transaction is now durable
    //   2. pager.undo_head=0 + page0.writeHeader + flushPage(0) — undo_head=0 on disk
    //   3. lf.discard()      — free undo pages (bypass WAL; undo_head already safe)
    //
    // If crash between steps 1 and 2, recovery sees undo_head != 0 in the WAL but
    // finds the txn_id in committed_txns → discards undo chain without replaying.
    // If crash after step 2, recovery sees undo_head=0 → no recovery needed.
    pub fn commit(self: *Db) !void {
        if (self.txn == null) return error.NoActiveTransaction;
        // Step 1: make the commit durable.
        try self.pager.commitTxn();
        // Step 2: write undo_head=0 to page 0 and flush to disk.
        self.pager.undo_head = 0;
        try page0.writeHeader(&self.pager);
        try self.pager.flushPage(0);
        // Step 3: free undo pages (cleanup; bypass WAL since undo_head=0 is already durable).
        if (self.txn.?.log_file) |*lf| {
            self.pager.setWalBypass(true);
            defer self.pager.setWalBypass(false);
            try lf.discard();
        }
        self.pager.endTxn();
        self.txn.?.deinit();
        self.txn = null;
    }

    // Roll back the active transaction by replaying the in-memory undo log in
    // reverse, then free the disk undo pages and FORCE-flush the reverted state.
    // Undo replay uses wal_bypass so compensation writes don't pollute the WAL.
    pub fn rollback(self: *Db) !void {
        if (self.txn == null) return error.NoActiveTransaction;

        // Bypass WAL for undo operations: we are reverting changes, not making
        // new committed mutations.  FORCE flush at the end makes the reverted
        // state durable without needing WAL records for the compensation writes.
        self.pager.setWalBypass(true);
        defer self.pager.setWalBypass(false);

        const log = self.txn.?.log.items;
        var i: usize = log.len;
        while (i > 0) {
            i -= 1;
            switch (log[i]) {
                .insert => |e| {
                    // Undo the insert by deleting the row that was added.
                    const meta = self.cat.getTable(e.table) orelse continue;
                    _ = try btree.delete(&self.pager, meta.btree_root, e.rowid);
                },
                .delete => |e| {
                    // Undo the delete by re-inserting the original row bytes.
                    const meta = self.cat.getTable(e.table) orelse continue;
                    try btree.insert(&self.pager, meta.btree_root, e.rowid, e.row_bytes, true);
                },
                .update => |e| {
                    // Undo the update: remove new row, restore original bytes.
                    const meta = self.cat.getTable(e.table) orelse continue;
                    _ = try btree.delete(&self.pager, meta.btree_root, e.rowid);
                    try btree.insert(&self.pager, meta.btree_root, e.rowid, e.old_row_bytes, true);
                },
            }
        }

        if (self.txn.?.log_file) |*lf| try lf.discard();
        self.pager.endTxn();
        // FORCE flush: write all reverted pages to disk so any previously-stolen
        // dirty pages are overwritten with the pre-transaction state.
        try self.pager.flush();
        self.txn.?.deinit();
        self.txn = null;
    }

    // Define a new table and persist the catalog immediately.
    pub fn createTable(
        self: *Db,
        name: []const u8,
        cols: []const catalog.ColumnMeta,
    ) !void {
        _ = try self.cat.createTable(name, cols);
        try self.pager.flush();
    }

    // Encode and insert a row, returning the assigned rowid.
    pub fn insert(
        self: *Db,
        table: []const u8,
        values: []const row.Value,
    ) !u64 {
        const meta = self.cat.getTable(table) orelse return error.TableNotFound;

        const rowid = meta.rowid_counter;
        meta.rowid_counter += 1;

        const row_size = row.encodedSize(values);
        const row_buf = try self.allocator.alloc(u8, row_size);
        defer self.allocator.free(row_buf);
        _ = row.encodeRow(values, row_buf);

        try btree.insert(&self.pager, meta.btree_root, rowid, row_buf, true);

        if (self.txn) |*active_txn| {
            try active_txn.logInsert(table, rowid);
        } else {
            try self.pager.flush();
        }
        return rowid;
    }

    // Remove a row by rowid. Returns false if the rowid does not exist.
    pub fn delete(self: *Db, table: []const u8, rowid: u64) !bool {
        const meta = self.cat.getTable(table) orelse return error.TableNotFound;

        if (self.txn) |*active_txn| {
            // Capture old row bytes before deletion so we can restore them on rollback.
            var leaf_buf: [t.PAGE_SIZE]u8 = undefined;
            const cell = try btree.lookup(&self.pager, meta.btree_root, rowid, &leaf_buf) orelse return false;

            if (cell.is_overflow) {
                const tmp = try self.allocator.alloc(u8, cell.overflow_len);
                defer self.allocator.free(tmp);
                try overflow.readChain(&self.pager, cell.overflow_page, cell.overflow_len, tmp);
                try active_txn.logDelete(table, rowid, tmp);
            } else {
                try active_txn.logDelete(table, rowid, cell.row_data);
            }

            _ = try btree.delete(&self.pager, meta.btree_root, rowid);
            return true;
        }

        const deleted = try btree.delete(&self.pager, meta.btree_root, rowid);
        if (deleted) try self.pager.flush();
        return deleted;
    }

    // Replace the row at rowid with new values. Returns false if not found.
    pub fn update(
        self: *Db,
        table: []const u8,
        rowid: u64,
        values: []const row.Value,
    ) !bool {
        const meta = self.cat.getTable(table) orelse return error.TableNotFound;

        if (self.txn) |*active_txn| {
            // Capture old row bytes before mutation so we can restore them on rollback.
            var leaf_buf: [t.PAGE_SIZE]u8 = undefined;
            const cell = try btree.lookup(&self.pager, meta.btree_root, rowid, &leaf_buf) orelse return false;

            if (cell.is_overflow) {
                const tmp = try self.allocator.alloc(u8, cell.overflow_len);
                defer self.allocator.free(tmp);
                try overflow.readChain(&self.pager, cell.overflow_page, cell.overflow_len, tmp);
                try active_txn.logUpdate(table, rowid, tmp);
            } else {
                try active_txn.logUpdate(table, rowid, cell.row_data);
            }

            _ = try btree.delete(&self.pager, meta.btree_root, rowid);
            const row_size = row.encodedSize(values);
            const row_buf = try self.allocator.alloc(u8, row_size);
            defer self.allocator.free(row_buf);
            _ = row.encodeRow(values, row_buf);
            try btree.insert(&self.pager, meta.btree_root, rowid, row_buf, true);
            return true;
        }

        const deleted = try btree.delete(&self.pager, meta.btree_root, rowid);
        if (!deleted) return false;

        const row_size = row.encodedSize(values);
        const row_buf = try self.allocator.alloc(u8, row_size);
        defer self.allocator.free(row_buf);
        _ = row.encodeRow(values, row_buf);

        try btree.insert(&self.pager, meta.btree_root, rowid, row_buf, true);
        try self.pager.flush();
        return true;
    }

    // Fetch a single row by rowid. Caller owns the returned slice and its values.
    // Returns null if the rowid does not exist.
    pub fn getByRowid(
        self: *Db,
        table: []const u8,
        rowid: u64,
        allocator: std.mem.Allocator,
    ) !?[]row.Value {
        const meta = self.cat.getTable(table) orelse return error.TableNotFound;

        var schema_buf: [64]row.ColumnSchema = undefined;
        const cols = buildColSchema(meta.columns, &schema_buf);

        var leaf_buf: [t.PAGE_SIZE]u8 = undefined;
        const cell = try btree.lookup(&self.pager, meta.btree_root, rowid, &leaf_buf) orelse return null;

        const row_bytes: []u8 = if (cell.is_overflow) blk: {
            const out = try allocator.alloc(u8, cell.overflow_len);
            try overflow.readChain(&self.pager, cell.overflow_page, cell.overflow_len, out);
            break :blk out;
        } else try allocator.dupe(u8, cell.row_data);
        defer allocator.free(row_bytes);

        return try row.decodeRow(cols, row_bytes, allocator);
    }

    // Iterator that decodes rows from a btree scan one at a time.
    // The struct is self-contained (schema_buf is inline) so it can be returned
    // by value without the cols slice dangling after a move.
    pub const DbRowIterator = struct {
        it: btree.ScanIterator,
        schema_buf: [64]row.ColumnSchema,
        schema_len: usize,

        // Returns the next decoded row, arena-allocated, or null at EOF.
        pub fn next(self: *DbRowIterator, allocator: std.mem.Allocator) !?struct { rowid: u64, values: []row.Value } {
            const cell = try self.it.next() orelse return null;
            const cols = self.schema_buf[0..self.schema_len];

            // Overflow rows span multiple pages; copy into a temp buffer,
            // decode, then free the raw bytes.
            const row_bytes: []u8 = if (cell.is_overflow) blk: {
                const out = try allocator.alloc(u8, cell.overflow_len);
                errdefer allocator.free(out);
                try overflow.readChain(self.it.pager, cell.overflow_page, cell.overflow_len, out);
                break :blk out;
            } else try allocator.dupe(u8, cell.row_data);
            defer allocator.free(row_bytes);

            return .{ .rowid = cell.rowid, .values = try row.decodeRow(cols, row_bytes, allocator) };
        }
    };

    // Open a forward scan over every row in table, in rowid order.
    // The returned iterator borrows &self.pager, so it must not outlive db.
    pub fn scanOpen(self: *Db, table: []const u8) !DbRowIterator {
        const meta = self.cat.getTable(table) orelse return error.TableNotFound;
        var it = DbRowIterator{
            .it = try btree.ScanIterator.init(&self.pager, meta.btree_root),
            .schema_buf = undefined,
            .schema_len = meta.columns.len,
        };
        for (meta.columns, 0..) |c, i| {
            it.schema_buf[i] = .{ .col_type = c.col_type, .nullable = c.nullable };
        }
        return it;
    }

    // Walk every row in a table in rowid order, calling cb(rowid, values, ctx).
    // Return false from the callback to stop early.
    pub fn scan(
        self: *Db,
        table: []const u8,
        cb: anytype,
        ctx: anytype,
    ) !void {
        const meta = self.cat.getTable(table) orelse return error.TableNotFound;

        var schema_buf: [64]row.ColumnSchema = undefined;
        const cols = buildColSchema(meta.columns, &schema_buf);

        var it = try btree.ScanIterator.init(&self.pager, meta.btree_root);
        while (try it.next()) |cell| {
            const row_bytes: []u8 = if (cell.is_overflow) blk: {
                const out = try self.allocator.alloc(u8, cell.overflow_len);
                try overflow.readChain(&self.pager, cell.overflow_page, cell.overflow_len, out);
                break :blk out;
            } else try self.allocator.dupe(u8, cell.row_data);
            defer self.allocator.free(row_bytes);

            const values = try row.decodeRow(cols, row_bytes, self.allocator);
            defer {
                for (values) |v| switch (v) {
                    .text => |s| self.allocator.free(s),
                    .blob => |b| self.allocator.free(b),
                    else => {},
                };
                self.allocator.free(values);
            }

            if (!cb(cell.rowid, values, ctx)) break;
        }
    }
};

// ── Recovery passes ───────────────────────────────────────────────────────────

// Pass 1: scan the WAL from checkpoint_lsn and collect every txn_id that has
// a durable COMMIT record.  Used by recoverIfNeeded to skip undo for committed txns.
fn analysisPass(wal: *Wal, allocator: std.mem.Allocator) !std.AutoHashMap(u32, void) {
    var committed = std.AutoHashMap(u32, void).init(allocator);
    errdefer committed.deinit();

    const records = try wal.readFrom(wal.checkpoint_lsn, allocator);
    defer allocator.free(records);

    for (records) |rec| {
        const rec_type: wal_mod.RecordType = @enumFromInt(rec.header.record_type);
        if (rec_type == .commit) {
            try committed.put(rec.header.txn_id, {});
        }
    }

    return committed;
}

// Pass 2: replay all WAL page images from checkpoint_lsn into the buffer pool.
// WAL bypass is on so the writes don't produce new WAL records.
// After this, the buffer pool reflects the latest committed on-disk state.
fn redoPass(db: *Db, wal: *Wal, allocator: std.mem.Allocator) !void {
    db.pager.setWalBypass(true);
    defer db.pager.setWalBypass(false);

    const records = try wal.readFrom(wal.checkpoint_lsn, allocator);
    defer allocator.free(records);

    for (records) |rec| {
        const rec_type: wal_mod.RecordType = @enumFromInt(rec.header.record_type);
        if (rec_type != .page_image) continue;
        const data = rec.page_data orelse continue;
        try db.pager.writePage(rec.header.page_id, &data);
    }
}

// After redoPass, the buffer pool's page 0 holds the recovered header.  Sync
// the in-memory Pager fields from it so subsequent operations see the right
// total_pages, free_list_head, undo_head, etc.
fn updatePagerFromPage0(db: *Db) !void {
    const h = try page0.readHeader(&db.pager);
    db.pager.total_pages = h.total_pages;
    db.pager.free_list_head = h.free_list_head;
    db.pager.sys_tables_root = h.sys_tables_root;
    db.pager.sys_columns_root = h.sys_columns_root;
    db.pager.undo_head = h.undo_head;
}

// Fill a caller-supplied buffer with ColumnSchema derived from ColumnMeta.
// Avoids returning a pointer to a local stack array.
fn buildColSchema(cols: []const catalog.ColumnMeta, buf: []row.ColumnSchema) []const row.ColumnSchema {
    for (cols, 0..) |c, i| {
        buf[i] = .{ .col_type = c.col_type, .nullable = c.nullable };
    }
    return buf[0..cols.len];
}
