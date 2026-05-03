const std = @import("std");
const Parser = @import("../parser.zig").Parser;
const LogicalPlanner = @import("../logical_plan.zig").LogicalPlanner;
const LogicalPlan = @import("../logical_plan.zig").LogicalPlan;
const makeMemoryDb = @import("../../test_helpers.zig").makeMemoryDb;

test "plan UPDATE resolves assignments and filter" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL, score INT)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("UPDATE t SET score = 99 WHERE name = 'alice'", alloc);
    defer parsed.deinit();

    const upd = (try planner.plan(parsed.stmt)).update;
    try std.testing.expectEqualStrings("t", upd.table);
    try std.testing.expectEqual(@as(usize, 1), upd.assignments.len);
    try std.testing.expectEqual(@as(usize, 1), upd.assignments[0].col_idx);
    try std.testing.expectEqual(@as(i64, 99), upd.assignments[0].value.int_lit);
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).filter, std.meta.activeTag(upd.input.*));
}
