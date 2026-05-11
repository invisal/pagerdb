const std = @import("std");
const Parser = @import("../parser.zig").Parser;
const LogicalPlanner = @import("../logical_plan.zig").LogicalPlanner;
const LogicalPlan = @import("../logical_plan.zig").LogicalPlan;
const makeMemoryDb = @import("../../test_helpers.zig").makeMemoryDb;

test "plan DELETE without WHERE: input is SeqScan" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT NOT NULL)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed_parser = Parser.init("DELETE FROM t", alloc);

    defer parsed_parser.deinit();

    const parsed = try parsed_parser.parse();

    const del = (try planner.plan(parsed)).delete;
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).seq_scan, std.meta.activeTag(del.input.*));
}

test "plan DELETE with WHERE: input is Filter" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT NOT NULL)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed_parser = Parser.init("DELETE FROM t WHERE x = 1", alloc);

    defer parsed_parser.deinit();

    const parsed = try parsed_parser.parse();

    const lp = try planner.plan(parsed);
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).filter, std.meta.activeTag(lp.delete.input.*));
}
