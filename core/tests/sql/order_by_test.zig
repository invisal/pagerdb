const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

test "ORDER BY single column ASC (default)" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (3)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (2)");

    var r = try execute(alloc, h.db, "SELECT n FROM t ORDER BY n");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 3), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[1].values[0].int);
    try std.testing.expectEqual(@as(i64, 3), r.result_set.rows[2].values[0].int);
}

test "ORDER BY single column ASC explicit" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (30)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (10)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (20)");

    var r = try execute(alloc, h.db, "SELECT n FROM t ORDER BY n ASC");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 3), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 10), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 20), r.result_set.rows[1].values[0].int);
    try std.testing.expectEqual(@as(i64, 30), r.result_set.rows[2].values[0].int);
}

test "ORDER BY single column DESC" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (3)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (2)");

    var r = try execute(alloc, h.db, "SELECT n FROM t ORDER BY n DESC");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 3), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 3), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[1].values[0].int);
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[2].values[0].int);
}

test "ORDER BY positional (ORDER BY 1)" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (5)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (2)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (8)");

    var r = try execute(alloc, h.db, "SELECT n FROM t ORDER BY 1 DESC");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 3), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 8), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 5), r.result_set.rows[1].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[2].values[0].int);
}

test "ORDER BY multi-key (ORDER BY 2, 1)" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (a INT NOT NULL, b INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (2, 1)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (1, 2)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (1, 1)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (2, 2)");

    // Sort by b ASC, then a ASC
    var r = try execute(alloc, h.db, "SELECT a, b FROM t ORDER BY 2 ASC, 1 ASC");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 4), r.result_set.rows.len);
    // b=1 first: (1,1) then (2,1)
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[0].values[1].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[1].values[0].int);
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[1].values[1].int);
    // b=2 next: (1,2) then (2,2)
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[2].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[2].values[1].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[3].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[3].values[1].int);
}

test "ORDER BY expression" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (3)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (2)");

    // ORDER BY n + 0 tests expression evaluation in sort keys
    var r = try execute(alloc, h.db, "SELECT n FROM t ORDER BY n + 0 ASC");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 3), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[1].values[0].int);
    try std.testing.expectEqual(@as(i64, 3), r.result_set.rows[2].values[0].int);
}

test "ORDER BY with WHERE" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (5)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (3)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (2)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (4)");

    var r = try execute(alloc, h.db, "SELECT n FROM t WHERE n > 2 ORDER BY n DESC");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 3), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 5), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 4), r.result_set.rows[1].values[0].int);
    try std.testing.expectEqual(@as(i64, 3), r.result_set.rows[2].values[0].int);
}

test "ORDER BY with text column" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES ('charlie')");
    try exec(alloc, h.db, "INSERT INTO t VALUES ('alice')");
    try exec(alloc, h.db, "INSERT INTO t VALUES ('bob')");

    var r = try execute(alloc, h.db, "SELECT name FROM t ORDER BY name ASC");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 3), r.result_set.rows.len);
    try std.testing.expectEqualStrings("alice", r.result_set.rows[0].values[0].text);
    try std.testing.expectEqualStrings("bob", r.result_set.rows[1].values[0].text);
    try std.testing.expectEqualStrings("charlie", r.result_set.rows[2].values[0].text);
}

test "ORDER BY with GROUP BY" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (dept TEXT NOT NULL, n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES ('b', 1)");
    try exec(alloc, h.db, "INSERT INTO t VALUES ('a', 2)");
    try exec(alloc, h.db, "INSERT INTO t VALUES ('b', 3)");
    try exec(alloc, h.db, "INSERT INTO t VALUES ('a', 4)");

    // GROUP BY dept, ORDER BY dept ASC
    var r = try execute(alloc, h.db, "SELECT dept FROM t GROUP BY dept ORDER BY 1 ASC");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 2), r.result_set.rows.len);
    try std.testing.expectEqualStrings("a", r.result_set.rows[0].values[0].text);
    try std.testing.expectEqualStrings("b", r.result_set.rows[1].values[0].text);
}

test "ORDER BY NULL values sort first (NULLS FIRST)" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (2)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (null)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");

    var r = try execute(alloc, h.db, "SELECT n FROM t ORDER BY n ASC");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 3), r.result_set.rows.len);
    try std.testing.expect(r.result_set.rows[0].values[0] == .null);
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[1].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[2].values[0].int);
}

test "ORDER BY column alias" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (3)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (2)");

    var r = try execute(alloc, h.db, "SELECT n AS val FROM t ORDER BY val DESC");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 3), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 3), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[1].values[0].int);
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[2].values[0].int);
}
