const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

test "INSERT adds a row" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    var r = try execute(h.db, "INSERT INTO t VALUES (42)", alloc);
    defer r.deinit();
    try std.testing.expectEqual(@as(u64, 1), r.affected);

    var sel = try execute(h.db, "SELECT * FROM t", alloc);
    defer sel.deinit();
    try std.testing.expectEqual(@as(usize, 1), sel.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 42), sel.result_set.rows[0].values[0].int);
}

test "INSERT with named columns reorders values correctly" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL, score INT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t(score, name) VALUES (99, 'alice')", alloc);

    var sel = try execute(h.db, "SELECT * FROM t", alloc);
    defer sel.deinit();
    try std.testing.expectEqualStrings("alice", sel.result_set.rows[0].values[0].text);
    try std.testing.expectEqual(@as(i64, 99), sel.result_set.rows[0].values[1].int);
}

test "INSERT with multiple value rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (id INT NOT NULL, name TEXT NOT NULL)"} });
    defer h.deinit();

    var r = try execute(h.db, "INSERT INTO t VALUES (1, 'alice'), (2, 'bob'), (3, 'carol')", alloc);
    defer r.deinit();
    try std.testing.expectEqual(@as(u64, 3), r.affected);

    var sel = try execute(h.db, "SELECT * FROM t", alloc);
    defer sel.deinit();
    try std.testing.expectEqual(@as(usize, 3), sel.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 1), sel.result_set.rows[0].values[0].int);
    try std.testing.expectEqualStrings("alice", sel.result_set.rows[0].values[1].text);
    try std.testing.expectEqual(@as(i64, 2), sel.result_set.rows[1].values[0].int);
    try std.testing.expectEqualStrings("bob", sel.result_set.rows[1].values[1].text);
    try std.testing.expectEqual(@as(i64, 3), sel.result_set.rows[2].values[0].int);
    try std.testing.expectEqualStrings("carol", sel.result_set.rows[2].values[1].text);
}

test "CREATE TABLE then INSERT via SQL" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    try exec(h.db, "CREATE TABLE items (id INT NOT NULL, label TEXT)", alloc);
    try exec(h.db, "INSERT INTO items VALUES (1, 'thing')", alloc);

    var sel = try execute(h.db, "SELECT * FROM items", alloc);
    defer sel.deinit();
    try std.testing.expectEqual(@as(usize, 1), sel.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 1), sel.result_set.rows[0].values[0].int);
}
