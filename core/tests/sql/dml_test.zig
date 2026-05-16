const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

// --- INSERT affected count ---

test "INSERT returns correct affected count" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    var r = try execute(alloc, h.db, "INSERT INTO t VALUES (42)");
    defer r.deinit();
    try std.testing.expectEqual(@as(u64, 1), r.affected);
}

test "Multi-row INSERT returns affected count equal to row count" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (id INT NOT NULL, name TEXT NOT NULL)"} });
    defer h.deinit();

    var r = try execute(alloc, h.db, "INSERT INTO t VALUES (1, 'alice'), (2, 'bob'), (3, 'carol')");
    defer r.deinit();
    try std.testing.expectEqual(@as(u64, 3), r.affected);
}

// --- UPDATE affected count ---

test "UPDATE returns correct affected count" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL, score INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES ('alice', 10)");

    var upd = try execute(alloc, h.db, "UPDATE t SET score = 999 WHERE name = 'alice'");
    defer upd.deinit();
    try std.testing.expectEqual(@as(u64, 1), upd.affected);
}

test "UPDATE with no matching rows returns affected=0" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");

    var upd = try execute(alloc, h.db, "UPDATE t SET x = 99 WHERE x = 999");
    defer upd.deinit();
    try std.testing.expectEqual(@as(u64, 0), upd.affected);
}

// --- DELETE affected count ---

test "DELETE returns correct affected count" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES ('a'), ('b'), ('c')");

    var del = try execute(alloc, h.db, "DELETE FROM t WHERE name = 'b'");
    defer del.deinit();
    try std.testing.expectEqual(@as(u64, 1), del.affected);
}

test "DELETE with no matching rows returns affected=0" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT NOT NULL)"} });
    defer h.deinit();

    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");

    var del = try execute(alloc, h.db, "DELETE FROM t WHERE x = 999");
    defer del.deinit();
    try std.testing.expectEqual(@as(u64, 0), del.affected);
}
