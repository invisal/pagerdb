const std = @import("std");

// Each entry records what is needed to reverse one DML operation.
// Strings and byte slices point into the transaction's own arena
// and are freed atomically when the transaction ends.
pub const UndoEntry = union(enum) {
    // Undo an INSERT: delete the row that was inserted.
    insert: struct { table: []const u8, rowid: u64 },
    // Undo a DELETE: re-insert the original row bytes at the same rowid.
    delete: struct { table: []const u8, rowid: u64, row_bytes: []const u8 },
    // Undo an UPDATE: discard the new row, restore the original bytes.
    update: struct { table: []const u8, rowid: u64, old_row_bytes: []const u8 },
};

// In-memory transaction context.  All allocations (log entries, strings,
// captured row bytes) live in `arena` and are freed together on commit
// or rollback.  Swapping to a disk-backed log later only requires
// changing these methods, not any caller code in db.zig.
pub const Transaction = struct {
    arena: std.heap.ArenaAllocator,
    log: std.ArrayListUnmanaged(UndoEntry),

    pub fn init(backing: std.mem.Allocator) Transaction {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .log = .empty,
        };
    }

    // Free the arena and every allocation it owns (log array, strings, row bytes).
    pub fn deinit(self: *Transaction) void {
        self.arena.deinit();
    }

    // Record that a row was inserted (undo = delete it).
    pub fn logInsert(self: *Transaction, table: []const u8, rowid: u64) !void {
        const a = self.arena.allocator();
        try self.log.append(a, .{
            .insert = .{ .table = try a.dupe(u8, table), .rowid = rowid },
        });
    }

    // Record that a row was deleted (undo = re-insert original bytes).
    // row_bytes is copied into the transaction arena.
    pub fn logDelete(self: *Transaction, table: []const u8, rowid: u64, row_bytes: []const u8) !void {
        const a = self.arena.allocator();
        try self.log.append(a, .{
            .delete = .{
                .table = try a.dupe(u8, table),
                .rowid = rowid,
                .row_bytes = try a.dupe(u8, row_bytes),
            },
        });
    }

    // Record that a row was updated (undo = replace current row with old bytes).
    // old_row_bytes is copied into the transaction arena.
    pub fn logUpdate(self: *Transaction, table: []const u8, rowid: u64, old_row_bytes: []const u8) !void {
        const a = self.arena.allocator();
        try self.log.append(a, .{
            .update = .{
                .table = try a.dupe(u8, table),
                .rowid = rowid,
                .old_row_bytes = try a.dupe(u8, old_row_bytes),
            },
        });
    }
};
