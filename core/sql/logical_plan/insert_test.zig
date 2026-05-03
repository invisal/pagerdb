const std = @import("std");
const Parser = @import("../parser.zig").Parser;
const LogicalPlanner = @import("../logical_plan.zig").LogicalPlanner;
const PlanError = @import("../logical_plan.zig").PlanError;
const utils = @import("utils.zig");
const makeCatalog = utils.makeCatalog;

test "plan INSERT resolves values" {
    const alloc = std.testing.allocator;

    var cat_handle = try makeCatalog(alloc, &.{
        "CREATE TABLE t (name TEXT NOT NULL, score INT NOT NULL)",
    });
    defer cat_handle.deinit();

    var planner = LogicalPlanner.init(&cat_handle.cat, alloc);
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
    const alloc = std.testing.allocator;

    var cat_handle = try makeCatalog(alloc, &.{
        "CREATE TABLE t (name TEXT NOT NULL, score INT NOT NULL)",
    });
    defer cat_handle.deinit();

    var planner = LogicalPlanner.init(&cat_handle.cat, alloc);
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
    const alloc = std.testing.allocator;

    // Both columns are NOT NULL, so missing values should cause an error
    var cat_handle = try makeCatalog(alloc, &.{
        "CREATE TABLE t (x INT NOT NULL, y INT NOT NULL)",
    });
    defer cat_handle.deinit();

    var planner = LogicalPlanner.init(&cat_handle.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("INSERT INTO t VALUES (1)", alloc);
    defer parsed.deinit();

    try std.testing.expectError(PlanError.ColumnNotFound, planner.plan(parsed.stmt));
}

test "plan INSERT specified columns count mismatch values count returns ColumnCountMismatch" {
    const alloc = std.testing.allocator;

    var cat_handle = try makeCatalog(alloc, &.{
        "CREATE TABLE t (x INT NOT NULL, y INT NOT NULL, z INT NOT NULL)",
    });
    defer cat_handle.deinit();

    var planner = LogicalPlanner.init(&cat_handle.cat, alloc);
    defer planner.deinit();

    // Specifying 2 columns but providing 3 values
    var parsed = try Parser.parse("INSERT INTO t(x, y) VALUES (1, 2, 3)", alloc);
    defer parsed.deinit();

    try std.testing.expectError(PlanError.ColumnCountMismatch, planner.plan(parsed.stmt));
}

test "plan INSERT specified columns with DEFAULT on column with no default" {
    const alloc = std.testing.allocator;
    var cat_handle = try makeCatalog(alloc, &.{
        "CREATE TABLE t(x INT, y INT)",
    });
    defer cat_handle.deinit();

    var planner = LogicalPlanner.init(&cat_handle.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("INSERT INTO t(x, y) VALUES(1, DEFAULT);", alloc);
    defer parsed.deinit();

    try std.testing.expectError(PlanError.NoDefaultValue, planner.plan(parsed.stmt));
}

test "plan INSERT with partial columns fills missing with NULL" {
    const alloc = std.testing.allocator;

    // Table with 3 columns, where the third is nullable (by default)
    var cat_handle = try makeCatalog(alloc, &.{
        "CREATE TABLE t (x INT NOT NULL, y INT NOT NULL, z INT)",
    });
    defer cat_handle.deinit();

    var planner = LogicalPlanner.init(&cat_handle.cat, alloc);
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
    const alloc = std.testing.allocator;

    var cat_handle = try makeCatalog(alloc, &.{
        "CREATE TABLE t (x INT NOT NULL, y INT NOT NULL)",
    });
    defer cat_handle.deinit();

    var planner = LogicalPlanner.init(&cat_handle.cat, alloc);
    defer planner.deinit();

    // Specifying a column that doesn't exist in the table
    var parsed = try Parser.parse("INSERT INTO t(x, nonexistent) VALUES (1, 2)", alloc);
    defer parsed.deinit();

    try std.testing.expectError(PlanError.ColumnNotFound, planner.plan(parsed.stmt));
}
