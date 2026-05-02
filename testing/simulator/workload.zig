const std = @import("std");
const core = @import("core");

const Database = core.Database;
const catalog = core.catalog;

pub const TABLE_NAME = "dst_test";

pub const SCHEMA = [_]catalog.ColumnMeta{
    .{ .name = "a", .col_type = .int, .nullable = false },
    .{ .name = "b", .col_type = .int, .nullable = false },
};

pub const ShadowState = struct {
    alloc: std.mem.Allocator,
    rowids: std.ArrayList(u64),

    pub fn init(alloc: std.mem.Allocator) ShadowState {
        return .{ .alloc = alloc, .rowids = std.ArrayList(u64).empty };
    }

    pub fn deinit(self: *ShadowState) void {
        self.rowids.deinit(self.alloc);
    }

    pub fn count(self: *const ShadowState) usize {
        return self.rowids.items.len;
    }
};

pub fn setupTable(db: *Database) !void {
    try db.createTable(TABLE_NAME, &SCHEMA);
}

// Pick and run one operation weighted 60% insert / 20% update / 20% delete.
// Falls back to insert when the table is empty.
pub fn runOp(db: *Database, rng: std.Random, shadow: *ShadowState) !void {
    if (shadow.rowids.items.len == 0) {
        return runInsert(db, rng, shadow);
    }
    const r = rng.uintLessThan(u8, 100);
    if (r < 60) {
        try runInsert(db, rng, shadow);
    } else if (r < 80) {
        try runUpdate(db, rng, shadow);
    } else {
        try runDelete(db, rng, shadow);
    }
}

fn runInsert(db: *Database, rng: std.Random, shadow: *ShadowState) !void {
    const a = rng.intRangeAtMost(i64, 0, 100_000);
    const b = rng.intRangeAtMost(i64, 0, 100_000);
    const rowid = try db.insert(TABLE_NAME, &.{
        .{ .int = a },
        .{ .int = b },
    });
    try shadow.rowids.append(shadow.alloc, rowid);
}

fn runUpdate(db: *Database, rng: std.Random, shadow: *ShadowState) !void {
    const idx = rng.uintLessThan(usize, shadow.rowids.items.len);
    const rowid = shadow.rowids.items[idx];
    const a = rng.intRangeAtMost(i64, 0, 100_000);
    const b = rng.intRangeAtMost(i64, 0, 100_000);
    _ = try db.update(TABLE_NAME, rowid, &.{
        .{ .int = a },
        .{ .int = b },
    });
    // rowid stays live; only the values change
}

fn runDelete(db: *Database, rng: std.Random, shadow: *ShadowState) !void {
    const idx = rng.uintLessThan(usize, shadow.rowids.items.len);
    const rowid = shadow.rowids.items[idx];
    _ = try db.delete(TABLE_NAME, rowid);
    _ = shadow.rowids.swapRemove(idx);
}
