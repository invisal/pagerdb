const std = @import("std");

pub const UndoEntry = union(enum) {
    insert: struct { table: []const u8, rowid: u64 },
    delete: struct { table: []const u8, rowid: u64, row_bytes: []const u8 },
    update: struct { table: []const u8, rowid: u64, old_row_bytes: []const u8 },
};

// In-memory transaction context.  All allocations (log entries, strings,
// captured row bytes) live in `arena` and are freed together on commit
// or rollback.  With the no-steal policy, dirty pages never reach disk
// before commit, so in-process rollback via the in-memory log is sufficient
// for correctness — no disk undo log is needed.
pub const Transaction = struct {
    arena: std.heap.ArenaAllocator,
    log: std.ArrayListUnmanaged(UndoEntry),

    pub fn init(backing: std.mem.Allocator) Transaction {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .log = .empty,
        };
    }

    pub fn deinit(self: *Transaction) void {
        self.arena.deinit();
    }

    pub fn logInsert(self: *Transaction, table: []const u8, rowid: u64) !void {
        const a = self.arena.allocator();
        try self.log.append(a, .{ .insert = .{ .table = try a.dupe(u8, table), .rowid = rowid } });
    }

    pub fn logDelete(self: *Transaction, table: []const u8, rowid: u64, row_bytes: []const u8) !void {
        const a = self.arena.allocator();
        try self.log.append(a, .{ .delete = .{
            .table = try a.dupe(u8, table),
            .rowid = rowid,
            .row_bytes = try a.dupe(u8, row_bytes),
        } });
    }

    pub fn logUpdate(self: *Transaction, table: []const u8, rowid: u64, old_row_bytes: []const u8) !void {
        const a = self.arena.allocator();
        try self.log.append(a, .{ .update = .{
            .table = try a.dupe(u8, table),
            .rowid = rowid,
            .old_row_bytes = try a.dupe(u8, old_row_bytes),
        } });
    }
};
