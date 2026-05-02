const std = @import("std");
const ast = @import("../ast.zig");
const Parser = @import("../parser.zig").Parser;
const LogicalPlanner = @import("../logical_plan.zig").LogicalPlanner;
const LogicalPlan = @import("../logical_plan.zig").LogicalPlan;
const utils = @import("utils.zig");
const makeDb = utils.makeDb;

const Dir = utils.Dir;

test "plan SELECT * resolves to SeqScan with correct schema" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_seqscan.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("users", &.{
        .{ .name = "name", .col_type = .text, .nullable = false },
        .{ .name = "score", .col_type = .int, .nullable = true },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM users", alloc);
    defer parsed.deinit();

    const lp = try planner.plan(parsed.stmt);
    const scan = lp.seq_scan;
    try std.testing.expectEqualStrings("users", scan.table);
    try std.testing.expectEqual(@as(usize, 2), scan.schema.columns.len);
    try std.testing.expectEqualStrings("name", scan.schema.columns[0].name);
    try std.testing.expectEqualStrings("score", scan.schema.columns[1].name);
    try std.testing.expectEqual(@as(usize, 0), scan.schema.columns[0].index);
    try std.testing.expectEqual(@as(usize, 1), scan.schema.columns[1].index);
}

test "plan SELECT * with main.schema prefix resolves to SeqScan" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_schema.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("users", &.{
        .{ .name = "name", .col_type = .text, .nullable = false },
        .{ .name = "score", .col_type = .int, .nullable = true },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM main.users", alloc);
    defer parsed.deinit();

    const lp = try planner.plan(parsed.stmt);
    const scan = lp.seq_scan;
    try std.testing.expectEqualStrings("users", scan.table);
    try std.testing.expectEqual(@as(usize, 2), scan.schema.columns.len);
}

test "plan SELECT with WHERE wraps in Filter" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_filter.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "score", .col_type = .int, .nullable = true },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM t WHERE score > 50", alloc);
    defer parsed.deinit();

    const lp = try planner.plan(parsed.stmt);
    const filter = lp.filter;
    try std.testing.expectEqual(ast.BinaryOp.gt, filter.predicate.binary.op);
    try std.testing.expectEqual(@as(usize, 0), filter.predicate.binary.left.col_idx);
    try std.testing.expectEqual(@as(i64, 50), filter.predicate.binary.right.int_lit);
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).seq_scan, std.meta.activeTag(filter.input.*));
}

test "plan SELECT columns produces Project" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_project.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "a", .col_type = .int, .nullable = false },
        .{ .name = "b", .col_type = .text, .nullable = true },
        .{ .name = "c", .col_type = .int, .nullable = true },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT a, c FROM t", alloc);
    defer parsed.deinit();

    const lp = try planner.plan(parsed.stmt);
    const project = lp.project;
    try std.testing.expectEqual(@as(usize, 2), project.col_indices.len);
    try std.testing.expectEqual(@as(usize, 0), project.col_indices[0]);
    try std.testing.expectEqual(@as(usize, 2), project.col_indices[1]);
    try std.testing.expectEqualStrings("a", project.schema.columns[0].name);
    try std.testing.expectEqualStrings("c", project.schema.columns[1].name);
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).seq_scan, std.meta.activeTag(project.input.*));
}

test "plan SELECT columns + WHERE: Project wraps Filter wraps SeqScan" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_proj_filter.db";
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

    var parsed = try Parser.parse("SELECT name FROM t WHERE score > 10", alloc);
    defer parsed.deinit();

    const lp = try planner.plan(parsed.stmt);
    const project = lp.project;
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).filter, std.meta.activeTag(project.input.*));
    const filter = project.input.*.filter;
    try std.testing.expectEqual(std.meta.Tag(LogicalPlan).seq_scan, std.meta.activeTag(filter.input.*));
}
