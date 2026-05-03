const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const makeDiskDb = th.makeDiskDb;
const loadDiskDb = th.loadDiskDb;
const exec = th.exec;

test "omitted column uses DEFAULT value" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT, age INT DEFAULT 18)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t(name) VALUES ('alice')", alloc);

    var r = try execute(h.db, "SELECT age FROM t WHERE name = 'alice'", alloc);
    defer r.deinit();
    try std.testing.expectEqual(@as(i64, 18), r.result_set.rows[0].values[0].int);
}

test "DEFAULT keyword explicitly uses default value" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT, age INT DEFAULT 18)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t(name, age) VALUES ('alice', DEFAULT)", alloc);

    var r = try execute(h.db, "SELECT age FROM t WHERE name = 'alice'", alloc);
    defer r.deinit();
    try std.testing.expectEqual(@as(i64, 18), r.result_set.rows[0].values[0].int);
}

test "DEFAULT value survives database reopen" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    {
        const h = try makeDiskDb(alloc, io, "/tmp/test_sql_default_reopen.db", .{});
        defer h.db.close();
        try exec(h.db, "CREATE TABLE t (name TEXT, age INT DEFAULT 18)", alloc);
    }

    const h = try loadDiskDb(alloc, io, "/tmp/test_sql_default_reopen.db");
    defer h.deinit();

    try exec(h.db, "INSERT INTO t(name) VALUES ('alice')", alloc);

    var r = try execute(h.db, "SELECT age FROM t WHERE name = 'alice'", alloc);
    defer r.deinit();
    try std.testing.expectEqual(@as(i64, 18), r.result_set.rows[0].values[0].int);
}

test "nullable column defaults to NULL when omitted" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL, score INT)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t(name) VALUES ('alice')", alloc);

    var r = try execute(h.db, "SELECT score FROM t WHERE name = 'alice'", alloc);
    defer r.deinit();
    try std.testing.expect(r.result_set.rows[0].values[0] == .null);
}
