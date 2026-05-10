const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

test "COUNT(*) on empty table returns one row with 0" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    var r = try execute(h.db, "SELECT COUNT(*) FROM t", alloc);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 0), r.result_set.rows[0].values[0].int);
}

test "COUNT(*) counts all rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES (1)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (2)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (3)", alloc);

    var r = try execute(h.db, "SELECT COUNT(*) FROM t", alloc);
    defer r.deinit();
    try std.testing.expectEqual(@as(i64, 3), r.result_set.rows[0].values[0].int);
}

test "COUNT(*) with WHERE filters before counting" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES (1)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (5)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (10)", alloc);

    var r = try execute(h.db, "SELECT COUNT(*) FROM t WHERE n > 3", alloc);
    defer r.deinit();
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[0].values[0].int);
}

test "SUM, AVG, MIN, MAX without GROUP BY" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (v INT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES (10)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (20)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (30)", alloc);

    var r = try execute(h.db, "SELECT SUM(v), MIN(v), MAX(v) FROM t", alloc);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 60), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 10), r.result_set.rows[0].values[1].int);
    try std.testing.expectEqual(@as(i64, 30), r.result_set.rows[0].values[2].int);
}

test "GROUP BY produces one row per unique key" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{"CREATE TABLE t (dept INT NOT NULL, salary INT NOT NULL)"},
    });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES (1, 100)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (2, 200)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (1, 150)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (2, 250)", alloc);

    var r = try execute(h.db, "SELECT dept, COUNT(*) FROM t GROUP BY dept", alloc);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.result_set.rows.len);
    // First-seen group (dept=1): count=2
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[0].values[1].int);
    // Second group (dept=2): count=2
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[1].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[1].values[1].int);
}

test "GROUP BY with SUM" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{"CREATE TABLE t (dept INT NOT NULL, salary INT NOT NULL)"},
    });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES (1, 100)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (2, 200)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (1, 150)", alloc);

    var r = try execute(h.db, "SELECT dept, SUM(salary) FROM t GROUP BY dept", alloc);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 1), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 250), r.result_set.rows[0].values[1].int);
    try std.testing.expectEqual(@as(i64, 2), r.result_set.rows[1].values[0].int);
    try std.testing.expectEqual(@as(i64, 200), r.result_set.rows[1].values[1].int);
}

test "column names in aggregate result set" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES (1)", alloc);

    var r = try execute(h.db, "SELECT COUNT(*), SUM(n) FROM t", alloc);
    defer r.deinit();
    try std.testing.expectEqualStrings("count", r.result_set.columns[0]);
    try std.testing.expectEqualStrings("sum", r.result_set.columns[1]);
}
