const std = @import("std");
const Parser = @import("../parser.zig").Parser;
const LogicalPlanner = @import("../logical_plan.zig").LogicalPlanner;
const makeMemoryDb = @import("../../test_helpers.zig").makeMemoryDb;

test "plan CREATE TABLE" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{});
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("CREATE TABLE items (id INT NOT NULL, label TEXT)", alloc);
    defer parsed.deinit();

    const ct = (try planner.plan(parsed.stmt)).create_table;
    try std.testing.expectEqualStrings("items", ct.table);
    try std.testing.expectEqual(@as(usize, 2), ct.columns.len);
    try std.testing.expectEqualStrings("id", ct.columns[0].name);
    try std.testing.expectEqual(false, ct.columns[0].nullable);
    try std.testing.expectEqualStrings("label", ct.columns[1].name);
    try std.testing.expectEqual(true, ct.columns[1].nullable);
}
