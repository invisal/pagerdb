const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

test "INNER JOIN returns matching rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{
            "CREATE TABLE orders (id INT NOT NULL, user_id INT NOT NULL)",
            "CREATE TABLE users (id INT NOT NULL, name TEXT NOT NULL)",
        },
    });
    defer h.deinit();

    try exec(h.db, "INSERT INTO users VALUES (1, 'alice')", alloc);
    try exec(h.db, "INSERT INTO users VALUES (2, 'bob')", alloc);
    try exec(h.db, "INSERT INTO orders VALUES (10, 1)", alloc);
    try exec(h.db, "INSERT INTO orders VALUES (11, 2)", alloc);
    try exec(h.db, "INSERT INTO orders VALUES (12, 1)", alloc);

    var result = try execute(
        h.db,
        "SELECT * FROM orders INNER JOIN users ON orders.user_id = users.id",
        alloc,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.result_set.rows.len);
    // Each row should have 4 values: orders.id, orders.user_id, users.id, users.name
    try std.testing.expectEqual(@as(usize, 4), result.result_set.rows[0].values.len);
}

test "INNER JOIN with no matching rows returns empty" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{
            "CREATE TABLE a (x INT NOT NULL)",
            "CREATE TABLE b (y INT NOT NULL)",
        },
    });
    defer h.deinit();

    try exec(h.db, "INSERT INTO a VALUES (1)", alloc);
    try exec(h.db, "INSERT INTO b VALUES (99)", alloc);

    var result = try execute(h.db, "SELECT * FROM a INNER JOIN b ON a.x = b.y", alloc);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.result_set.rows.len);
}

test "INNER JOIN with SELECT * exposes all columns" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{
            "CREATE TABLE dept (dept_id INT NOT NULL, dept_name TEXT NOT NULL)",
            "CREATE TABLE emp (emp_id INT NOT NULL, dept_id INT NOT NULL, emp_name TEXT NOT NULL)",
        },
    });
    defer h.deinit();

    try exec(h.db, "INSERT INTO dept VALUES (1, 'engineering')", alloc);
    try exec(h.db, "INSERT INTO dept VALUES (2, 'sales')", alloc);
    try exec(h.db, "INSERT INTO emp VALUES (100, 1, 'alice')", alloc);
    try exec(h.db, "INSERT INTO emp VALUES (101, 1, 'bob')", alloc);
    try exec(h.db, "INSERT INTO emp VALUES (102, 2, 'carol')", alloc);

    var result = try execute(
        h.db,
        "SELECT * FROM dept INNER JOIN emp ON dept.dept_id = emp.dept_id",
        alloc,
    );
    defer result.deinit();

    // 2 engineering employees + 1 sales employee
    try std.testing.expectEqual(@as(usize, 3), result.result_set.rows.len);
    // 5 columns: dept_id, dept_name, emp_id, emp_dept_id, emp_name
    try std.testing.expectEqual(@as(usize, 5), result.result_set.rows[0].values.len);
}

test "INNER JOIN column names are correct" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{
            "CREATE TABLE t1 (a INT NOT NULL)",
            "CREATE TABLE t2 (b INT NOT NULL)",
        },
    });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t1 VALUES (1)", alloc);
    try exec(h.db, "INSERT INTO t2 VALUES (1)", alloc);

    var result = try execute(h.db, "SELECT * FROM t1 INNER JOIN t2 ON t1.a = t2.b", alloc);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.result_set.columns.len);
    try std.testing.expectEqualStrings("a", result.result_set.columns[0]);
    try std.testing.expectEqualStrings("b", result.result_set.columns[1]);
}

test "INNER JOIN with WHERE filters after join" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{
            "CREATE TABLE orders (id INT NOT NULL, user_id INT NOT NULL)",
            "CREATE TABLE users (id INT NOT NULL, name TEXT NOT NULL)",
        },
    });
    defer h.deinit();

    try exec(h.db, "INSERT INTO users VALUES (1, 'alice')", alloc);
    try exec(h.db, "INSERT INTO users VALUES (2, 'bob')", alloc);
    try exec(h.db, "INSERT INTO orders VALUES (10, 1)", alloc);
    try exec(h.db, "INSERT INTO orders VALUES (11, 2)", alloc);
    try exec(h.db, "INSERT INTO orders VALUES (12, 1)", alloc);

    // WHERE filters on a left-side column after the join
    var result = try execute(
        h.db,
        "SELECT * FROM orders INNER JOIN users ON orders.user_id = users.id WHERE orders.id > 10",
        alloc,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows.len);
}

test "INNER JOIN with qualified SELECT columns" {
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
        "SELECT orders.id, users.name FROM orders INNER JOIN users ON orders.user_id = users.id",
        alloc,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows[0].values.len);
    try std.testing.expectEqual(@as(i64, 10), result.result_set.rows[0].values[0].int);
    try std.testing.expectEqualStrings("alice", result.result_set.rows[0].values[1].text);
}
