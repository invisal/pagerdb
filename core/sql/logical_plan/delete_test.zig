const std = @import("std");
const Parser = @import("../parser.zig").Parser;
const LogicalPlanner = @import("../logical_plan.zig").LogicalPlanner;
const LogicalPlan = @import("../logical_plan.zig").LogicalPlan;
const utils = @import("utils.zig");
const makeDb = utils.makeDb;

const Dir = utils.Dir;

test "plan DELETE without WHERE: input is SeqScan" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_delete.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "x", .col_type = .int, .nullable = false },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("DELETE FROM t", alloc);
    defer parsed.deinit();

    const lp = try planner.plan(parsed.stmt);
    const del = lp.delete;
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).seq_scan, std.meta.activeTag(del.input.*));
}

test "plan DELETE with WHERE: input is Filter" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_delete_where.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "x", .col_type = .int, .nullable = false },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("DELETE FROM t WHERE x = 1", alloc);
    defer parsed.deinit();

    const lp = try planner.plan(parsed.stmt);
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).filter, std.meta.activeTag(lp.delete.input.*));
}
