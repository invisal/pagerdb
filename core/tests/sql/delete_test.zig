const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

test "DELETE removes matching rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES ('a')");
    try exec(alloc, h.db, "INSERT INTO t VALUES ('b')");
    try exec(alloc, h.db, "INSERT INTO t VALUES ('c')");

    var del = try execute(alloc, h.db, "DELETE FROM t WHERE name = 'b'");
    defer del.deinit();
    try std.testing.expectEqual(@as(u64, 1), del.affected);

    var sel = try execute(alloc, h.db, "SELECT * FROM t");
    defer sel.deinit();
    try std.testing.expectEqual(@as(usize, 2), sel.result_set.rows.len);
}

test "DELETE with no matching rows returns affected=0" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");

    var del = try execute(alloc, h.db, "DELETE FROM t WHERE x = 999");
    defer del.deinit();
    try std.testing.expectEqual(@as(u64, 0), del.affected);
}
