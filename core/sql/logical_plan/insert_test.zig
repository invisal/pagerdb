const std = @import("std");
const Parser = @import("../parser.zig").Parser;
const LogicalPlanner = @import("../logical_plan.zig").LogicalPlanner;
const PlanError = @import("../logical_plan.zig").PlanError;
const utils = @import("utils.zig");
const makeDb = utils.makeDb;

const Dir = utils.Dir;

test "plan INSERT resolves values" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_insert.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "name", .col_type = .text, .nullable = false },
        .{ .name = "score", .col_type = .int, .nullable = false },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("INSERT INTO t VALUES ('alice', 100)", alloc);
    defer parsed.deinit();

    const lp = try planner.plan(parsed.stmt);
    const ins = lp.insert;
    try std.testing.expectEqualStrings("t", ins.table);
    try std.testing.expectEqual(@as(usize, 2), ins.values.len);
    try std.testing.expectEqualStrings("alice", ins.values[0].str_lit);
    try std.testing.expectEqual(@as(i64, 100), ins.values[1].int_lit);
}

test "plan INSERT with specified columns" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_insert.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "name", .col_type = .text, .nullable = false },
        .{ .name = "score", .col_type = .int, .nullable = false },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("INSERT INTO t(score, name) VALUES (100, 'alice')", alloc);
    defer parsed.deinit();

    const lp = try planner.plan(parsed.stmt);
    const ins = lp.insert;
    try std.testing.expectEqualStrings("t", ins.table);
    try std.testing.expectEqual(@as(usize, 2), ins.values.len);
    try std.testing.expectEqualStrings("alice", ins.values[0].str_lit);
    try std.testing.expectEqual(@as(i64, 100), ins.values[1].int_lit);
}

test "plan INSERT wrong column count returns ColumnNotFound" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_insert_cc.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "x", .col_type = .int, .nullable = false },
        .{ .name = "y", .col_type = .int, .nullable = false },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("INSERT INTO t VALUES (1)", alloc);
    defer parsed.deinit();

    try std.testing.expectError(PlanError.ColumnNotFound, planner.plan(parsed.stmt));
}

test "plan INSERT specified columns count mismatch values count returns ColumnCountMismatch" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_insert_colval.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "x", .col_type = .int, .nullable = false },
        .{ .name = "y", .col_type = .int, .nullable = false },
        .{ .name = "z", .col_type = .int, .nullable = false },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    // Specifying 2 columns but providing 3 values
    var parsed = try Parser.parse("INSERT INTO t(x, y) VALUES (1, 2, 3)", alloc);
    defer parsed.deinit();

    try std.testing.expectError(PlanError.ColumnCountMismatch, planner.plan(parsed.stmt));
}

test "plan INSERT with partial columns fills missing with NULL" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_insert_partial.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    // Table with 3 columns, where the third is nullable
    _ = try db.cat.createTable("t", &.{
        .{ .name = "x", .col_type = .int, .nullable = false },
        .{ .name = "y", .col_type = .int, .nullable = false },
        .{ .name = "z", .col_type = .int, .nullable = true },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    // Specifying only 2 columns - the third should be filled with NULL
    var parsed = try Parser.parse("INSERT INTO t(x, y) VALUES (1, 2)", alloc);
    defer parsed.deinit();

    const lp = try planner.plan(parsed.stmt);
    const ins = lp.insert;
    try std.testing.expectEqualStrings("t", ins.table);
    // Should have 3 values (2 specified + 1 NULL for missing column)
    try std.testing.expectEqual(@as(usize, 3), ins.values.len);
    try std.testing.expectEqual(@as(i64, 1), ins.values[0].int_lit);
    try std.testing.expectEqual(@as(i64, 2), ins.values[1].int_lit);
    // The missing column should be NULL
    try std.testing.expectEqual(@as(usize, 2), ins.schema.columns[2].index);
    try std.testing.expect(ins.values[2] == .null_lit);
}

test "plan INSERT with nonexistent column returns ColumnNotFound" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_insert_badcol.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "x", .col_type = .int, .nullable = false },
        .{ .name = "y", .col_type = .int, .nullable = false },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    // Specifying a column that doesn't exist in the table
    var parsed = try Parser.parse("INSERT INTO t(x, nonexistent) VALUES (1, 2)", alloc);
    defer parsed.deinit();

    try std.testing.expectError(PlanError.ColumnNotFound, planner.plan(parsed.stmt));
}
