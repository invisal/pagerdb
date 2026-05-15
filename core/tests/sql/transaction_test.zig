const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

test "BEGIN / COMMIT persists rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (v INT)"} });
    defer h.deinit();

    try exec(alloc, h.db, "BEGIN");
    try exec(alloc, h.db, "INSERT INTO t VALUES (1)");
    try exec(alloc, h.db, "INSERT INTO t VALUES (2)");
    try exec(alloc, h.db, "COMMIT");

    var result = try execute(alloc, h.db, "SELECT * FROM t");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows.len);
}

test "BEGIN / ROLLBACK discards rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (v INT)"} });
    defer h.deinit();

    try exec(alloc, h.db, "BEGIN");
    try exec(alloc, h.db, "INSERT INTO t VALUES (99)");
    try exec(alloc, h.db, "ROLLBACK");

    var result = try execute(alloc, h.db, "SELECT * FROM t");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.result_set.rows.len);
}
