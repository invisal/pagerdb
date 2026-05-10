const std = @import("std");
const ast = @import("../ast.zig");
const Parser = @import("../parser.zig").Parser;
const LogicalPlanner = @import("../logical_plan.zig").LogicalPlanner;
const LogicalPlan = @import("../logical_plan.zig").LogicalPlan;
const makeMemoryDb = @import("../../test_helpers.zig").makeMemoryDb;

test "plan SELECT * produces Project over SeqScan with only real columns" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE users (name TEXT NOT NULL, score INT)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM users", alloc);
    defer parsed.deinit();

    const project = (try planner.plan(parsed.stmt)).project;
    // Only real columns in the output — hidden __rowid etc. are excluded.
    try std.testing.expectEqual(@as(usize, 2), project.schema.columns.len);
    try std.testing.expectEqualStrings("name", project.schema.columns[0].name);
    try std.testing.expectEqualStrings("score", project.schema.columns[1].name);
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).seq_scan, std.meta.activeTag(project.input.*));
    try std.testing.expectEqualStrings("users", project.input.seq_scan.table);
}

test "plan SELECT * with main.schema prefix produces Project over SeqScan" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE users (name TEXT NOT NULL, score INT)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM main.users", alloc);
    defer parsed.deinit();

    const project = (try planner.plan(parsed.stmt)).project;
    try std.testing.expectEqual(@as(usize, 2), project.schema.columns.len);
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).seq_scan, std.meta.activeTag(project.input.*));
}

test "plan SELECT * with WHERE wraps in Project over Filter over SeqScan" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (score INT)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM t WHERE score > 50", alloc);
    defer parsed.deinit();

    const project = (try planner.plan(parsed.stmt)).project;
    const filter = project.input.*.filter;
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

test "plan SELECT __rowid produces Project with correct schema and indices" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT NOT NULL)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT __rowid, __pageid, __slotid, x FROM t", alloc);
    defer parsed.deinit();

    const project = (try planner.plan(parsed.stmt)).project;
    // Schema must have 4 columns — one per selected item.
    try std.testing.expectEqual(@as(usize, 4), project.schema.columns.len);
    try std.testing.expectEqualStrings("__rowid", project.schema.columns[0].name);
    try std.testing.expectEqualStrings("__pageid", project.schema.columns[1].name);
    try std.testing.expectEqualStrings("__slotid", project.schema.columns[2].name);
    try std.testing.expectEqualStrings("x", project.schema.columns[3].name);
    // t has 1 real column, so synthetic cols land at indices 1, 2, 3.
    try std.testing.expectEqual(@as(usize, 1), project.exprs[0].col_idx); // __rowid
    try std.testing.expectEqual(@as(usize, 2), project.exprs[1].col_idx); // __pageid
    try std.testing.expectEqual(@as(usize, 3), project.exprs[2].col_idx); // __slotid
    try std.testing.expectEqual(@as(usize, 0), project.exprs[3].col_idx); // x
}
