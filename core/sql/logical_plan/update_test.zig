const std = @import("std");
const Parser = @import("../parser.zig").Parser;
const LogicalPlanner = @import("../logical_plan.zig").LogicalPlanner;
const LogicalPlan = @import("../logical_plan.zig").LogicalPlan;
const utils = @import("utils.zig");
const makeDb = utils.makeDb;

const Dir = utils.Dir;

test "plan UPDATE resolves assignments and filter" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_update.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "name", .col_type = .text, .nullable = false },
        .{ .name = "score", .col_type = .int, .nullable = true },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("UPDATE t SET score = 99 WHERE name = 'alice'", alloc);
    defer parsed.deinit();

    const lp = try planner.plan(parsed.stmt);
    const upd = lp.update;
    try std.testing.expectEqualStrings("t", upd.table);
    try std.testing.expectEqual(@as(usize, 1), upd.assignments.len);
    try std.testing.expectEqual(@as(usize, 1), upd.assignments[0].col_idx);
    try std.testing.expectEqual(@as(i64, 99), upd.assignments[0].value.int_lit);
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).filter, std.meta.activeTag(upd.input.*));
}
