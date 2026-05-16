const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

test "DISTINCT single column removes duplicates" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (2)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (3)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (2)");

    var r = try execute(alloc, h.db, "SELECT DISTINCT n FROM t ORDER BY n");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 3), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[1].values[0].int);
    try std.testing.expectEqual(@as(i64, 3), r.result_set.rows[2].values[0].int);
}

test "DISTINCT multi-column deduplicates on all columns" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (a INT NOT NULL, b INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (1, 1)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (1, 2)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (1, 1)"); // duplicate of first
    try exec(alloc, h.db, "INSERT INTO t VALUES (2, 1)");

    var r = try execute(alloc, h.db, "SELECT DISTINCT a, b FROM t ORDER BY a, b");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 3), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[0].values[1].int);
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[1].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[1].values[1].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[2].values[0].int);
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[2].values[1].int);
}

test "DISTINCT with WHERE" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (2)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (2)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (3)");

    var r = try execute(alloc, h.db, "SELECT DISTINCT n FROM t WHERE n > 1 ORDER BY n");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 2), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 3), r.result_set.rows[1].values[0].int);
}

test "DISTINCT on already-unique rows is a no-op" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (10)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (20)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (30)");

    var r = try execute(alloc, h.db, "SELECT DISTINCT n FROM t ORDER BY n");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 3), r.result_set.rows.len);
}

test "DISTINCT on empty table returns no rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    var r = try execute(alloc, h.db, "SELECT DISTINCT n FROM t");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 0), r.result_set.rows.len);
}
