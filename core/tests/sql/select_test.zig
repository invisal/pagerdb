const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

test "SELECT * returns all rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES (1)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (2)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (3)", alloc);

    var result = try execute(h.db, "SELECT * FROM t", alloc);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.result_set.rows.len);
}

test "SELECT with WHERE filters rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (score INT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES (10)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (50)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (100)", alloc);

    var result = try execute(h.db, "SELECT * FROM t WHERE score > 40", alloc);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows.len);
}

test "SELECT specific columns projects correctly" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL, score INT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES ('alice', 42)", alloc);

    var result = try execute(h.db, "SELECT name FROM t", alloc);
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
    var result = try execute(h.db, sql, alloc);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 22), result.result_set.rows[0].values[0].int);
}

test "SELECT with main. schema prefix resolves table" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE users (id INT, name TEXT)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO users VALUES (1, 'alice')", alloc);

    var r1 = try execute(h.db, "SELECT * FROM users", alloc);
    defer r1.deinit();
    try std.testing.expectEqual(@as(usize, 1), r1.result_set.rows.len);

    var r2 = try execute(h.db, "SELECT * FROM main.users", alloc);
    defer r2.deinit();
    try std.testing.expectEqual(@as(usize, 1), r2.result_set.rows.len);

    var r3 = try execute(h.db, "SELECT * FROM other.users", alloc);
    defer r3.deinit();
    try std.testing.expect(r3 == .err);
    try std.testing.expectEqualStrings("TableNotFound", r3.err.code);
}

test "SELECT table.* expands all columns from that table" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (a INT NOT NULL, b TEXT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES (1, 'x')", alloc);

    var result = try execute(h.db, "SELECT t.* FROM t", alloc);
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

    try exec(h.db, "INSERT INTO users VALUES (1, 'alice')", alloc);
    try exec(h.db, "INSERT INTO orders VALUES (10, 1)", alloc);

    var result = try execute(
        h.db,
        "SELECT orders.* FROM orders INNER JOIN users ON orders.user_id = users.id",
        alloc,
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

    try exec(h.db, "INSERT INTO users VALUES (1, 'alice')", alloc);
    try exec(h.db, "INSERT INTO orders VALUES (10, 1)", alloc);

    var result = try execute(
        h.db,
        "SELECT orders.*, users.name FROM orders INNER JOIN users ON orders.user_id = users.id",
        alloc,
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

    var r = try execute(h.db, "SELECT nope.* FROM t", alloc);
    defer r.deinit();
    try std.testing.expect(r == .err);
    try std.testing.expectEqualStrings("TableNotFound", r.err.code);
}

test "table.* in WHERE clause returns WildcardInExpression" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (a INT NOT NULL)"} });
    defer h.deinit();

    var r = try execute(h.db, "SELECT a FROM t WHERE t.*", alloc);
    defer r.deinit();
    try std.testing.expect(r == .err);
    try std.testing.expectEqualStrings("WildcardInExpression", r.err.code);
}

test "SELECT without FROM returns one row" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    var result = try execute(h.db, "SELECT 1", alloc);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 1), result.result_set.rows[0].values[0].int);
}

test "SELECT constant expression without FROM evaluates correctly" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    var result = try execute(h.db, "SELECT 1 + 2", alloc);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 3), result.result_set.rows[0].values[0].int);
}

test "SELECT ABS() without FROM evaluates correctly" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    var result = try execute(h.db, "SELECT abs(-42)", alloc);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 42), result.result_set.rows[0].values[0].int);
}

test "SELECT multiple constants without FROM returns one row with multiple values" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    var result = try execute(h.db, "SELECT 1, 2, 3", alloc);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(usize, 3), result.result_set.rows[0].values.len);
    try std.testing.expectEqual(@as(i64, 1), result.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), result.result_set.rows[0].values[1].int);
    try std.testing.expectEqual(@as(i64, 3), result.result_set.rows[0].values[2].int);
}

test "SELECT abs() evaluates correctly end-to-end" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES (-10)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (5)", alloc);

    var r = try execute(h.db, "SELECT abs(n) FROM t", alloc);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 10), r.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 5), r.result_set.rows[1].values[0].int);

    // Unknown function should be rejected at plan time.
    var bad = try execute(h.db, "SELECT upper(n) FROM t", alloc);
    defer bad.deinit();
    try std.testing.expect(bad == .err);
    try std.testing.expectEqualStrings("UnknownFunction", bad.err.code);
}
