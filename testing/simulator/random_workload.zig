const std = @import("std");
const core = @import("core");
const runner = @import("runner.zig");
const Database = core.ManagedDatabase;

pub const RandomWorkload = struct {
    alloc: std.mem.Allocator,
    next_id: u64 = 1,
    // Tracks IDs of rows currently in the table so update/delete can target them.
    // Resynced from the DB in verify(), which also handles post-crash staleness.
    live_ids: std.ArrayListUnmanaged(u64) = .empty,

    const vtable = runner.Workload.VTable{
        .name = "RANDOM",
        .setup = vtableSetup,
        .next = vtableNext,
        .verify = vtableVerify,
    };

    fn vtableSetup(ptr: *anyopaque, db: *Database, rng: std.Random) anyerror!void {
        const self: *RandomWorkload = @ptrCast(@alignCast(ptr));
        return self.setup(db, rng);
    }

    fn vtableNext(ptr: *anyopaque, db: *Database, rng: std.Random) anyerror!void {
        const self: *RandomWorkload = @ptrCast(@alignCast(ptr));
        return self.next(db, rng);
    }

    fn vtableVerify(ptr: *anyopaque, db: *Database, rng: std.Random) anyerror!void {
        const self: *RandomWorkload = @ptrCast(@alignCast(ptr));
        return self.verify(db, rng);
    }

    pub fn init(alloc: std.mem.Allocator) RandomWorkload {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *RandomWorkload) void {
        self.live_ids.deinit(self.alloc);
    }

    pub fn workload(self: *RandomWorkload) runner.Workload {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn setup(self: *RandomWorkload, db: *Database, _: std.Random) !void {
        self.next_id = 1;
        self.live_ids.clearRetainingCapacity();
        var result = try db.execute("CREATE TABLE random_test(id INTEGER PRIMARY KEY, a INT, b INT)", self.alloc);
        result.deinit();
    }

    // Pick and execute one operation: 60% insert, 20% update, 20% delete.
    pub fn next(self: *RandomWorkload, db: *Database, rng: std.Random) !void {
        if (self.live_ids.items.len == 0) return self.doInsert(db, rng);
        const roll = rng.uintLessThan(u8, 100);
        if (roll < 60) return self.doInsert(db, rng);
        if (roll < 80) return self.doUpdate(db, rng);
        return self.doDelete(db, rng);
    }

    // Resync live_ids from the database. After a crash the shadow may be ahead
    // of the committed state; a full scan also acts as a readability check —
    // corrupted pages surface as errors or panics here.
    pub fn verify(self: *RandomWorkload, db: *Database, _: std.Random) !void {
        var result = try db.execute("SELECT id FROM random_test", self.alloc);
        defer result.deinit();
        self.live_ids.clearRetainingCapacity();
        for (result.result_set.rows) |row| {
            const id: u64 = @intCast(row.values[0].int);
            try self.live_ids.append(self.alloc, id);
            if (id >= self.next_id) self.next_id = id + 1;
        }
    }

    fn doInsert(self: *RandomWorkload, db: *Database, rng: std.Random) !void {
        const id = self.next_id;
        self.next_id += 1;
        const a = rng.intRangeAtMost(i64, 0, 100_000);
        const b = rng.intRangeAtMost(i64, 0, 100_000);
        var buf: [96]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO random_test VALUES ({d}, {d}, {d})", .{ id, a, b });
        var result = try db.execute(sql, self.alloc);
        defer result.deinit();
        try self.live_ids.append(self.alloc, id);
    }

    fn doUpdate(self: *RandomWorkload, db: *Database, rng: std.Random) !void {
        const idx = rng.uintLessThan(usize, self.live_ids.items.len);
        const id = self.live_ids.items[idx];
        const a = rng.intRangeAtMost(i64, 0, 100_000);
        const b = rng.intRangeAtMost(i64, 0, 100_000);
        var buf: [96]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "UPDATE random_test SET a = {d}, b = {d} WHERE id = {d}", .{ a, b, id });
        var result = try db.execute(sql, self.alloc);
        defer result.deinit();
    }

    fn doDelete(self: *RandomWorkload, db: *Database, rng: std.Random) !void {
        const idx = rng.uintLessThan(usize, self.live_ids.items.len);
        const id = self.live_ids.items[idx];
        var buf: [64]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "DELETE FROM random_test WHERE id = {d}", .{id});
        var result = try db.execute(sql, self.alloc);
        defer result.deinit();
        _ = self.live_ids.swapRemove(idx);
    }
};

test "random workload: 10_000 operations complete without error" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    var io = core.SimIo.init(alloc);
    defer io.deinit();

    var db = try Database.open(alloc, io.io(), "/random_workload_test.db");
    defer db.deinit();

    var w = RandomWorkload.init(alloc);
    defer w.deinit();
    try w.setup(&db, rng);
    for (0..10_000) |_| try w.next(&db, rng);
}
