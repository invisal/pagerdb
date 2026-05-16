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

    try exec(alloc, h.db, "INSERT INTO users VALUES (1, 'alice')");
    try exec(alloc, h.db, "INSERT INTO users VALUES (2, 'bob')");
    try exec(alloc, h.db, "INSERT INTO orders VALUES (10, 1)");
    try exec(alloc, h.db, "INSERT INTO orders VALUES (11, 2)");
    try exec(alloc, h.db, "INSERT INTO orders VALUES (12, 1)");

    var result = try execute(
        alloc,
        h.db,
        "SELECT * FROM orders INNER JOIN users ON orders.user_id = users.id",
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

    try exec(alloc, h.db, "INSERT INTO a VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO b VALUES (99)");

    var result = try execute(alloc, h.db, "SELECT * FROM a INNER JOIN b ON a.x = b.y");
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

    try exec(alloc, h.db, "INSERT INTO dept VALUES (1, 'engineering')");
    try exec(alloc, h.db, "INSERT INTO dept VALUES (2, 'sales')");
    try exec(alloc, h.db, "INSERT INTO emp VALUES (100, 1, 'alice')");
    try exec(alloc, h.db, "INSERT INTO emp VALUES (101, 1, 'bob')");
    try exec(alloc, h.db, "INSERT INTO emp VALUES (102, 2, 'carol')");

    var result = try execute(
        alloc,
        h.db,
        "SELECT * FROM dept INNER JOIN emp ON dept.dept_id = emp.dept_id",
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

    try exec(alloc, h.db, "INSERT INTO t1 VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO t2 VALUES (1)");

    var result = try execute(alloc, h.db, "SELECT * FROM t1 INNER JOIN t2 ON t1.a = t2.b");
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

    try exec(alloc, h.db, "INSERT INTO users VALUES (1, 'alice')");
    try exec(alloc, h.db, "INSERT INTO users VALUES (2, 'bob')");
    try exec(alloc, h.db, "INSERT INTO orders VALUES (10, 1)");
    try exec(alloc, h.db, "INSERT INTO orders VALUES (11, 2)");
    try exec(alloc, h.db, "INSERT INTO orders VALUES (12, 1)");

    // WHERE filters on a left-side column after the join
    var result = try execute(
        alloc,
        h.db,
        "SELECT * FROM orders INNER JOIN users ON orders.user_id = users.id WHERE orders.id > 10",
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows.len);
}

test "CROSS JOIN explicit syntax produces cartesian product" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{
            "CREATE TABLE colors (name TEXT NOT NULL)",
            "CREATE TABLE sizes (label TEXT NOT NULL)",
        },
    });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO colors VALUES ('red')");
    try exec(alloc, h.db, "INSERT INTO colors VALUES ('blue')");
    try exec(alloc, h.db, "INSERT INTO sizes VALUES ('S')");
    try exec(alloc, h.db, "INSERT INTO sizes VALUES ('M')");
    try exec(alloc, h.db, "INSERT INTO sizes VALUES ('L')");

    var result = try execute(alloc, h.db, "SELECT * FROM colors CROSS JOIN sizes");
    defer result.deinit();

    // 2 colors × 3 sizes = 6 rows
    try std.testing.expectEqual(@as(usize, 6), result.result_set.rows.len);
    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows[0].values.len);
}

test "CROSS JOIN comma syntax produces cartesian product" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{
            "CREATE TABLE a (x INT NOT NULL)",
            "CREATE TABLE b (y INT NOT NULL)",
        },
    });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO a VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO a VALUES (2)");
    try exec(alloc, h.db, "INSERT INTO b VALUES (10)");
    try exec(alloc, h.db, "INSERT INTO b VALUES (20)");
    try exec(alloc, h.db, "INSERT INTO b VALUES (30)");

    var result = try execute(alloc, h.db, "SELECT * FROM a, b");
    defer result.deinit();

    // 2 rows × 3 rows = 6 rows
    try std.testing.expectEqual(@as(usize, 6), result.result_set.rows.len);
    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows[0].values.len);
}

test "CROSS JOIN with WHERE filters after cartesian product" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{
        .schema = &.{
            "CREATE TABLE a (x INT NOT NULL)",
            "CREATE TABLE b (y INT NOT NULL)",
        },
    });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO a VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO a VALUES (2)");
    try exec(alloc, h.db, "INSERT INTO b VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO b VALUES (2)");

    // Cartesian product is 4 rows; WHERE a.x = b.y keeps only matching pairs
    var result = try execute(alloc, h.db, "SELECT * FROM a, b WHERE a.x = b.y");
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

    try exec(alloc, h.db, "INSERT INTO users VALUES (1, 'alice')");
    try exec(alloc, h.db, "INSERT INTO orders VALUES (10, 1)");

    var result = try execute(
        alloc,
        h.db,
        "SELECT orders.id, users.name FROM orders INNER JOIN users ON orders.user_id = users.id",
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows[0].values.len);
    try std.testing.expectEqual(@as(i64, 10), result.result_set.rows[0].values[0].int);
    try std.testing.expectEqualStrings("alice", result.result_set.rows[0].values[1].text);
}
