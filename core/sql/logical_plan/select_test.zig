const std = @import("std");
const ast = @import("../ast.zig");
const Parser = @import("../parser.zig").Parser;
const LogicalPlanner = @import("../logical_plan.zig").LogicalPlanner;
const LogicalPlan = @import("../logical_plan.zig").LogicalPlan;
const makeMemoryDb = @import("../../test_helpers.zig").makeMemoryDb;

test "plan SELECT * resolves to SeqScan with correct schema" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE users (name TEXT NOT NULL, score INT)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM users", alloc);
    defer parsed.deinit();

    const scan = (try planner.plan(parsed.stmt)).seq_scan;
    try std.testing.expectEqualStrings("users", scan.table);
    try std.testing.expectEqual(@as(usize, 2), scan.schema.columns.len);
    try std.testing.expectEqualStrings("name", scan.schema.columns[0].name);
    try std.testing.expectEqualStrings("score", scan.schema.columns[1].name);
    try std.testing.expectEqual(@as(usize, 0), scan.schema.columns[0].index);
    try std.testing.expectEqual(@as(usize, 1), scan.schema.columns[1].index);
}

test "plan SELECT * with main.schema prefix resolves to SeqScan" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE users (name TEXT NOT NULL, score INT)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM main.users", alloc);
    defer parsed.deinit();

    const scan = (try planner.plan(parsed.stmt)).seq_scan;
    try std.testing.expectEqualStrings("users", scan.table);
    try std.testing.expectEqual(@as(usize, 2), scan.schema.columns.len);
}

test "plan SELECT with WHERE wraps in Filter" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (score INT)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM t WHERE score > 50", alloc);
    defer parsed.deinit();

    const filter = (try planner.plan(parsed.stmt)).filter;
    try std.testing.expectEqual(ast.BinaryOp.gt, filter.predicate.binary.op);
    try std.testing.expectEqual(@as(usize, 0), filter.predicate.binary.left.col_idx);
    try std.testing.expectEqual(@as(i64, 50), filter.predicate.binary.right.int_lit);
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).seq_scan, std.meta.activeTag(filter.input.*));
}

test "plan SELECT columns produces Project" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (a INT NOT NULL, b TEXT, c INT)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT a, c FROM t", alloc);
    defer parsed.deinit();

    const project = (try planner.plan(parsed.stmt)).project;
    try std.testing.expectEqual(@as(usize, 2), project.exprs.len);
    try std.testing.expectEqual(@as(usize, 0), project.exprs[0].col_idx);
    try std.testing.expectEqual(@as(usize, 2), project.exprs[1].col_idx);
    try std.testing.expectEqualStrings("a", project.schema.columns[0].name);
    try std.testing.expectEqualStrings("c", project.schema.columns[1].name);
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).seq_scan, std.meta.activeTag(project.input.*));
}

test "plan SELECT columns + WHERE: Project wraps Filter wraps SeqScan" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL, score INT)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT name FROM t WHERE score > 10", alloc);
    defer parsed.deinit();

    const project = (try planner.plan(parsed.stmt)).project;
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).filter, std.meta.activeTag(project.input.*));
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).seq_scan, std.meta.activeTag(project.input.*.filter.input.*));
}
