const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

// --- rowid ---

test "SELECT with __rowid point-lookup returns single row" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (v INT NOT NULL)"} });
    defer h.deinit();

    _ = try h.db.insert("t", &.{.{ .int = 11 }});
    const rowid = try h.db.insert("t", &.{.{ .int = 22 }});
    _ = try h.db.insert("t", &.{.{ .int = 33 }});

    var buf: [64]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf, "SELECT * FROM t WHERE __rowid = {d}", .{rowid});
    var result = try execute(alloc, h.db, sql);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 22), result.result_set.rows[0].values[0].int);
}

// --- error codes ---

test "SELECT from unknown schema returns TableNotFound" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE users (id INT, name TEXT)"} });
    defer h.deinit();

    var r = try execute(alloc, h.db, "SELECT * FROM other.users");
    defer r.deinit();
    try std.testing.expect(r == .err);
    try std.testing.expectEqualStrings("TableNotFound", r.err.code);
}

test "SELECT unknown_table.* returns TableNotFound" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (a INT NOT NULL)"} });
    defer h.deinit();

    var r = try execute(alloc, h.db, "SELECT nope.* FROM t");
    defer r.deinit();
    try std.testing.expect(r == .err);
    try std.testing.expectEqualStrings("TableNotFound", r.err.code);
}

test "table.* in WHERE clause returns WildcardInExpression" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (a INT NOT NULL)"} });
    defer h.deinit();

    var r = try execute(alloc, h.db, "SELECT a FROM t WHERE t.*");
    defer r.deinit();
    try std.testing.expect(r == .err);
    try std.testing.expectEqualStrings("WildcardInExpression", r.err.code);
}

test "unknown function returns UnknownFunction" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");

    var bad = try execute(alloc, h.db, "SELECT upper(n) FROM t");
    defer bad.deinit();
    try std.testing.expect(bad == .err);
    try std.testing.expectEqualStrings("UnknownFunction", bad.err.code);
}

// --- column names (not checkable in .test files) ---

test "SELECT column AS alias produces correct column name" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL, score INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES ('alice', 42)");

    var result = try execute(alloc, h.db, "SELECT name AS full_name, score AS points FROM t");
    defer result.deinit();
    try std.testing.expectEqualStrings("full_name", result.result_set.columns[0]);
    try std.testing.expectEqualStrings("points", result.result_set.columns[1]);
}

test "INNER JOIN column names match source column names" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{
            "CREATE TABLE t1 (a INT NOT NULL)",
            "CREATE TABLE t2 (b INT NOT NULL)",
        },
    });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t1 VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO t2 VALUES (1)");

    var result = try execute(alloc, h.db, "SELECT * FROM t1 INNER JOIN t2 ON t1.a = t2.b");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.result_set.columns.len);
    try std.testing.expectEqualStrings("a", result.result_set.columns[0]);
    try std.testing.expectEqualStrings("b", result.result_set.columns[1]);
}

test "aggregate result set uses lowercase function name as column name" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");

    var r = try execute(alloc, h.db, "SELECT COUNT(*), SUM(n) FROM t");
    defer r.deinit();
    try std.testing.expectEqualStrings("count", r.result_set.columns[0]);
    try std.testing.expectEqualStrings("sum", r.result_set.columns[1]);
}
