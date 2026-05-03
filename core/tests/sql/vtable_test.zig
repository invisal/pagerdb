const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const exec = th.exec;

test "SELECT * FROM __pages returns at least the header page" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    var result = try execute(h.db, "SELECT * FROM __pages", alloc);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 0), result.result_set.rows[0].values[0].int);
    try std.testing.expectEqualStrings("header", result.result_set.rows[0].values[1].text);
}

test "SELECT * FROM __pages after creating table has more pages" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    var result = try execute(h.db, "SELECT * FROM __pages", alloc);
    defer result.deinit();
    try std.testing.expect(result.result_set.rows.len >= 4);
}

test "SELECT * FROM __page_slots(1) shows btree_leaf cells" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (n INT NOT NULL)"} });
    defer h.deinit();

    try exec(h.db, "INSERT INTO t VALUES (10)", alloc);
    try exec(h.db, "INSERT INTO t VALUES (20)", alloc);

    var pages_res = try execute(h.db, "SELECT * FROM __pages", alloc);
    defer pages_res.deinit();

    var leaf_page_id: i64 = -1;
    for (pages_res.result_set.rows) |r| {
        if (std.mem.eql(u8, r.values[1].text, "btree_leaf"))
            leaf_page_id = r.values[0].int;
    }
    try std.testing.expect(leaf_page_id >= 0);

    var buf: [64]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf, "SELECT * FROM __page_slots({d})", .{leaf_page_id});
    var slots = try execute(h.db, sql, alloc);
    defer slots.deinit();

    try std.testing.expectEqual(@as(usize, 2), slots.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 0), slots.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 1), slots.result_set.rows[1].values[0].int);
}
