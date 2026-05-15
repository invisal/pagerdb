const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

test "SELECT * returns all rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (2)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (3)");

    var result = try execute(alloc, h.db, "SELECT * FROM t");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.result_set.rows.len);
}

test "SELECT with WHERE filters rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (score INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (10)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (50)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (100)");

    var result = try execute(alloc, h.db, "SELECT * FROM t WHERE score > 40");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows.len);
}

test "SELECT specific columns projects correctly" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL, score INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES ('alice', 42)");

    var result = try execute(alloc, h.db, "SELECT name FROM t");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows[0].values.len);
    try std.testing.expectEqualStrings("alice", result.result_set.rows[0].values[0].text);
}

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

test "SELECT with main. schema prefix resolves table" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE users (id INT, name TEXT)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO users VALUES (1, 'alice')");

    var r1 = try execute(alloc, h.db, "SELECT * FROM users");
    defer r1.deinit();
    try std.testing.expectEqual(@as(usize, 1), r1.result_set.rows.len);

    var r2 = try execute(alloc, h.db, "SELECT * FROM main.users");
    defer r2.deinit();
    try std.testing.expectEqual(@as(usize, 1), r2.result_set.rows.len);

    var r3 = try execute(alloc, h.db, "SELECT * FROM other.users");
    defer r3.deinit();
    try std.testing.expect(r3 == .err);
    try std.testing.expectEqualStrings("TableNotFound", r3.err.code);
}

test "SELECT table.* expands all columns from that table" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (a INT NOT NULL, b TEXT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (1, 'x')");

    var result = try execute(alloc, h.db, "SELECT t.* FROM t");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    // t.* expands to both columns
    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows[0].values.len);
    try std.testing.expectEqual(@as(i64, 1), result.result_set.rows[0].values[0].int);
    try std.testing.expectEqualStrings("x", result.result_set.rows[0].values[1].text);
}

test "SELECT table.* in JOIN returns only that table's columns" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{
            "CREATE TABLE orders (id INT NOT NULL, user_id INT NOT NULL)",
            "CREATE TABLE users (id INT NOT NULL, name TEXT NOT NULL)",
        },
    });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO users VALUES (1, 'alice')");
    try exec(alloc, h.db, "INSERT INTO orders VALUES (10, 1)");

    var result = try execute(
        alloc,
        h.db,
        "SELECT orders.* FROM orders INNER JOIN users ON orders.user_id = users.id",
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    // orders.* = id, user_id — not users columns
    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows[0].values.len);
    try std.testing.expectEqual(@as(i64, 10), result.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 1), result.result_set.rows[0].values[1].int);
}

test "SELECT mixed table.* and column in JOIN" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{
            "CREATE TABLE orders (id INT NOT NULL, user_id INT NOT NULL)",
            "CREATE TABLE users (id INT NOT NULL, name TEXT NOT NULL)",
        },
    });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO users VALUES (1, 'alice')");
    try exec(alloc, h.db, "INSERT INTO orders VALUES (10, 1)");

    var result = try execute(
        alloc,
        h.db,
        "SELECT orders.*, users.name FROM orders INNER JOIN users ON orders.user_id = users.id",
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    // orders.* = id, user_id; users.name = "alice"
    try std.testing.expectEqual(@as(usize, 3), result.result_set.rows[0].values.len);
    try std.testing.expectEqual(@as(i64, 10), result.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 1), result.result_set.rows[0].values[1].int);
    try std.testing.expectEqualStrings("alice", result.result_set.rows[0].values[2].text);
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

test "SELECT without FROM returns one row" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    var result = try execute(alloc, h.db, "SELECT 1");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 1), result.result_set.rows[0].values[0].int);
}

test "SELECT constant expression without FROM evaluates correctly" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    var result = try execute(alloc, h.db, "SELECT 1 + 2");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 3), result.result_set.rows[0].values[0].int);
}

test "SELECT ABS() without FROM evaluates correctly" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    var result = try execute(alloc, h.db, "SELECT abs(-42)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 42), result.result_set.rows[0].values[0].int);
}

test "SELECT multiple constants without FROM returns one row with multiple values" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    var result = try execute(alloc, h.db, "SELECT 1, 2, 3");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(usize, 3), result.result_set.rows[0].values.len);
    try std.testing.expectEqual(@as(i64, 1), result.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), result.result_set.rows[0].values[1].int);
    try std.testing.expectEqual(@as(i64, 3), result.result_set.rows[0].values[2].int);
}

test "SELECT column AS alias renames output column" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL, score INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES ('alice', 42)");

    var result = try execute(alloc, h.db, "SELECT name AS full_name, score AS points FROM t");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.result_set.columns.len);
    try std.testing.expectEqualStrings("full_name", result.result_set.columns[0]);
    try std.testing.expectEqualStrings("points", result.result_set.columns[1]);
    try std.testing.expectEqualStrings("alice", result.result_set.rows[0].values[0].text);
    try std.testing.expectEqual(@as(i64, 42), result.result_set.rows[0].values[1].int);
}

test "SELECT expression AS alias labels computed column" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    var result = try execute(alloc, h.db, "SELECT 6 + 7 AS tt");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.result_set.columns.len);
    try std.testing.expectEqualStrings("tt", result.result_set.columns[0]);
    try std.testing.expectEqual(@as(i64, 13), result.result_set.rows[0].values[0].int);
}

test "SELECT table.col AS alias renames qualified column" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE users (id INT NOT NULL, name TEXT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO users VALUES (1, 'bob')");

    var result = try execute(alloc, h.db, "SELECT users.name AS username FROM users");
    defer result.deinit();

    try std.testing.expectEqualStrings("username", result.result_set.columns[0]);
    try std.testing.expectEqualStrings("bob", result.result_set.rows[0].values[0].text);
}

test "SELECT abs() evaluates correctly end-to-end" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (-10)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (5)");

    var r = try execute(alloc, h.db, "SELECT abs(n) FROM t");
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 10), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 5), r.result_set.rows[1].values[0].int);

    // Unknown function should be rejected at plan time.
    var bad = try execute(alloc, h.db, "SELECT upper(n) FROM t");
    defer bad.deinit();
    try std.testing.expect(bad == .err);
    try std.testing.expectEqualStrings("UnknownFunction", bad.err.code);
}
