const std = @import("std");
const undo_log_mod = @import("undo_log.zig");

// Re-export so callers that already import txn.zig keep working.
pub const UndoEntry = undo_log_mod.UndoEntry;
pub const UndoLog = undo_log_mod.UndoLog;

// In-memory transaction context.  All allocations (log entries, strings,
// captured row bytes) live in `arena` and are freed together on commit
// or rollback.
//
// `log_file` shadows the in-memory log on disk: every entry is appended to the
// undo log page chain before it is pushed to the in-memory array.  In-process
// rollback replays the in-memory array (fast, no disk reads).  If the process
// crashes, Db.load() detects pager.undo_head != 0 and runs crash recovery.
pub const Transaction = struct {
    arena: std.heap.ArenaAllocator,
    log: std.ArrayListUnmanaged(UndoEntry),
    log_file: ?UndoLog,

    pub fn init(backing: std.mem.Allocator) Transaction {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .log = .empty,
            .log_file = null,
        };
    }

    pub fn deinit(self: *Transaction) void {
        self.arena.deinit();
    }

    // Record that a row was inserted (undo = delete it).
    pub fn logInsert(self: *Transaction, table: []const u8, rowid: u64) !void {
        const a = self.arena.allocator();
        const entry = UndoEntry{ .insert = .{ .table = try a.dupe(u8, table), .rowid = rowid } };
        if (self.log_file) |*lf| try lf.append(entry);
        try self.log.append(a, entry);
    }

    // Record that a row was deleted (undo = re-insert original bytes).
    // row_bytes is copied into the transaction arena.
    pub fn logDelete(self: *Transaction, table: []const u8, rowid: u64, row_bytes: []const u8) !void {
        const a = self.arena.allocator();
        const entry = UndoEntry{ .delete = .{
            .table = try a.dupe(u8, table),
            .rowid = rowid,
            .row_bytes = try a.dupe(u8, row_bytes),
        } };
        if (self.log_file) |*lf| try lf.append(entry);
        try self.log.append(a, entry);
    }

    // Record that a row was updated (undo = replace current row with old bytes).
    // old_row_bytes is copied into the transaction arena.
    pub fn logUpdate(self: *Transaction, table: []const u8, rowid: u64, old_row_bytes: []const u8) !void {
        const a = self.arena.allocator();
        const entry = UndoEntry{ .update = .{
            .table = try a.dupe(u8, table),
            .rowid = rowid,
            .old_row_bytes = try a.dupe(u8, old_row_bytes),
        } };
        if (self.log_file) |*lf| try lf.append(entry);
        try self.log.append(a, entry);
    }
};
