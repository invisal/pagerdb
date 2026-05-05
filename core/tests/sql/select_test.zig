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

test "SELECT with _rowid_ point-lookup returns single row" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (v INT NOT NULL)"} });
    defer h.deinit();

    _ = try h.db.insert("t", &.{.{ .int = 11 }});
    const rowid = try h.db.insert("t", &.{.{ .int = 22 }});
    _ = try h.db.insert("t", &.{.{ .int = 33 }});

    var buf: [64]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf, "SELECT * FROM t WHERE _rowid_ = {d}", .{rowid});
    var result = try execute(h.db, sql, alloc);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 22), result.result_set.rows[0].values[0].int);
}

test "SELECT with main. schema prefix resolves table" {
    const alloc = std.testing.allocator;
    const PlanError = @import("../../sql/logical_plan.zig").PlanError;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE users (id INT, name TEXT)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO users VALUES (1, 'alice')", alloc);

    var r1 = try execute(h.db, "SELECT * FROM users", alloc);
    defer r1.deinit();
    try std.testing.expectEqual(@as(usize, 1), r1.result_set.rows.len);

    var r2 = try execute(h.db, "SELECT * FROM main.users", alloc);
    defer r2.deinit();
    try std.testing.expectEqual(@as(usize, 1), r2.result_set.rows.len);

    try std.testing.expectError(PlanError.TableNotFound, execute(h.db, "SELECT * FROM other.users", alloc));
}

test "SELECT abs() evaluates correctly end-to-end" {
    const alloc = std.testing.allocator;
    const PlanError = @import("../../sql/logical_plan.zig").PlanError;
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
    try std.testing.expectError(PlanError.UnknownFunction, execute(h.db, "SELECT upper(n) FROM t", alloc));
}
