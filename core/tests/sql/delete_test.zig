const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

test "DELETE removes matching rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES ('a')", alloc);
    try exec(h.db, "INSERT INTO t VALUES ('b')", alloc);
    try exec(h.db, "INSERT INTO t VALUES ('c')", alloc);

    var del = try execute(h.db, "DELETE FROM t WHERE name = 'b'", alloc);
    defer del.deinit();
    try std.testing.expectEqual(@as(u64, 1), del.affected);

    var sel = try execute(h.db, "SELECT * FROM t", alloc);
    defer sel.deinit();
    try std.testing.expectEqual(@as(usize, 2), sel.result_set.rows.len);
}

test "DELETE with no matching rows returns affected=0" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES (1)", alloc);

    var del = try execute(h.db, "DELETE FROM t WHERE x = 999", alloc);
    defer del.deinit();
    try std.testing.expectEqual(@as(u64, 0), del.affected);
}
