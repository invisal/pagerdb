const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

test "UPDATE changes matching rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL, score INT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES ('alice', 10)", alloc);

    var upd = try execute(h.db, "UPDATE t SET score = 999 WHERE name = 'alice'", alloc);
    defer upd.deinit();
    try std.testing.expectEqual(@as(u64, 1), upd.affected);

    var sel = try execute(h.db, "SELECT * FROM t", alloc);
    defer sel.deinit();
    try std.testing.expectEqual(@as(i64, 999), sel.result_set.rows[0].values[1].int);
}

test "UPDATE with no matching rows returns affected=0" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES (1)", alloc);

    var upd = try execute(h.db, "UPDATE t SET x = 99 WHERE x = 999", alloc);
    defer upd.deinit();
    try std.testing.expectEqual(@as(u64, 0), upd.affected);
}
