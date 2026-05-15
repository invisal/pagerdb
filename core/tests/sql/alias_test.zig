const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

test "AS alias on plain table allows qualified column reference" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{"CREATE TABLE users (id INT NOT NULL, name TEXT NOT NULL)"},
    });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO users VALUES (1, 'alice')");
    try exec(alloc, h.db, "INSERT INTO users VALUES (2, 'bob')");

    var result = try execute(alloc, h.db, "SELECT u.id, u.name FROM users AS u");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 1), result.result_set.rows[0].values[0].int);
    try std.testing.expectEqualStrings("alice", result.result_set.rows[0].values[1].text);
}

test "AS alias on TVF allows qualified column reference" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    // generate_series(5) yields 0..4
    var result = try execute(alloc, h.db, "SELECT gs.generate_series FROM generate_series(5) AS gs");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 5), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 0), result.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 4), result.result_set.rows[4].values[0].int);
}

test "AS alias on JOIN right-hand plain table" {
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
        "SELECT o.id, u.name FROM orders AS o INNER JOIN users AS u ON o.user_id = u.id",
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 10), result.result_set.rows[0].values[0].int);
    try std.testing.expectEqualStrings("alice", result.result_set.rows[0].values[1].text);
}

test "INNER JOIN two aliased TVFs" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    // gs yields 0..9, gs2 yields 0..4; inner join keeps values in 0..4 (5 rows)
    var result = try execute(
        alloc,
        h.db,
        "SELECT gs.generate_series FROM generate_series(10) AS gs INNER JOIN generate_series(5) AS gs2 ON gs.generate_series = gs2.generate_series",
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 5), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 0), result.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 4), result.result_set.rows[4].values[0].int);
}

test "INNER JOIN plain table alias and TVF alias" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{"CREATE TABLE items (id INT NOT NULL, label TEXT NOT NULL)"},
    });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO items VALUES (1, 'one')");
    try exec(alloc, h.db, "INSERT INTO items VALUES (2, 'two')");
    try exec(alloc, h.db, "INSERT INTO items VALUES (3, 'three')");

    // generate_series(4) yields 0,1,2,3; items has ids 1,2,3 — three matches
    var result = try execute(
        alloc,
        h.db,
        "SELECT i.label FROM items AS i INNER JOIN generate_series(4) AS gs ON i.id = gs.generate_series",
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.result_set.rows.len);
}
