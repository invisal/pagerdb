const std = @import("std");
const Parser = @import("../parser.zig").Parser;
const LogicalPlanner = @import("../logical_plan.zig").LogicalPlanner;
const PlanError = @import("../logical_plan.zig").PlanError;
const makeMemoryDb = @import("../../test_helpers.zig").makeMemoryDb;

test "plan INSERT resolves values" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL, score INT NOT NULL)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed_parser = Parser.init("INSERT INTO t VALUES ('alice', 100)", alloc);

    defer parsed_parser.deinit();

    const parsed = try parsed_parser.parse();

    const lp = try planner.plan(parsed);
    const ins = lp.insert;
    try std.testing.expectEqualStrings("t", ins.table);
    try std.testing.expectEqual(@as(usize, 1), ins.values.len);
    try std.testing.expectEqual(@as(usize, 2), ins.values[0].len);
    try std.testing.expectEqualStrings("alice", ins.values[0][0].str_lit);
    try std.testing.expectEqual(@as(i64, 100), ins.values[0][1].int_lit);
}

test "plan INSERT with specified columns" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (name TEXT NOT NULL, score INT NOT NULL)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed_parser = Parser.init("INSERT INTO t(score, name) VALUES (100, 'alice')", alloc);

    defer parsed_parser.deinit();

    const parsed = try parsed_parser.parse();

    const lp = try planner.plan(parsed);
    const ins = lp.insert;
    try std.testing.expectEqualStrings("t", ins.table);
    try std.testing.expectEqual(@as(usize, 1), ins.values.len);
    try std.testing.expectEqual(@as(usize, 2), ins.values[0].len);
    try std.testing.expectEqualStrings("alice", ins.values[0][0].str_lit);
    try std.testing.expectEqual(@as(i64, 100), ins.values[0][1].int_lit);
}

test "plan INSERT wrong column count returns NoDefaultValue" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT NOT NULL, y INT NOT NULL)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed_parser = Parser.init("INSERT INTO t VALUES (1)", alloc);

    defer parsed_parser.deinit();

    const parsed = try parsed_parser.parse();

    try std.testing.expectError(PlanError.NoDefaultValue, planner.plan(parsed));
}

test "plan INSERT specified columns count mismatch values count returns ColumnCountMismatch" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT NOT NULL, y INT NOT NULL, z INT NOT NULL)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed_parser = Parser.init("INSERT INTO t(x, y) VALUES (1, 2, 3)", alloc);

    defer parsed_parser.deinit();

    const parsed = try parsed_parser.parse();

    try std.testing.expectError(PlanError.ColumnCountMismatch, planner.plan(parsed));
}

test "plan INSERT specified columns with DEFAULT on column with no default" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT, y INT NOT NULL)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed_parser = Parser.init("INSERT INTO t(x, y) VALUES(1, DEFAULT);", alloc);

    defer parsed_parser.deinit();

    const parsed = try parsed_parser.parse();
    try std.testing.expectError(PlanError.NoDefaultValue, planner.plan(parsed));

    var parsed2_parser = Parser.init("INSERT INTO t VALUES(DEFAULT, DEFAULT);", alloc);

    defer parsed2_parser.deinit();

    const parsed2 = try parsed2_parser.parse();
    try std.testing.expectError(PlanError.NoDefaultValue, planner.plan(parsed2));
}

test "plan INSERT with DEFAULT keyword should use default value" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT, y INT DEFAULT 10)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var p_parser = Parser.init("INSERT INTO t(x, y) VALUES(1, DEFAULT);", alloc);

    defer p_parser.deinit();

    const p = try p_parser.parse();
    try std.testing.expectEqual(10, (try planner.plan(p)).insert.values[0][1].int_lit);

    var p2_parser = Parser.init("INSERT INTO t VALUES(DEFAULT, DEFAULT);", alloc);

    defer p2_parser.deinit();

    const p2 = try p2_parser.parse();
    try std.testing.expectEqual(10, (try planner.plan(p2)).insert.values[0][1].int_lit);
}

test "plan INSERT with partial columns fills missing with NULL" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT NOT NULL, y INT NOT NULL, z INT)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed_parser = Parser.init("INSERT INTO t(x, y) VALUES (1, 2)", alloc);

    defer parsed_parser.deinit();

    const parsed = try parsed_parser.parse();

    const lp = try planner.plan(parsed);
    const ins = lp.insert;
    try std.testing.expectEqualStrings("t", ins.table);
    try std.testing.expectEqual(@as(usize, 1), ins.values.len);
    try std.testing.expectEqual(@as(usize, 3), ins.values[0].len);
    try std.testing.expectEqual(@as(i64, 1), ins.values[0][0].int_lit);
    try std.testing.expectEqual(@as(i64, 2), ins.values[0][1].int_lit);
    try std.testing.expectEqual(@as(usize, 2), ins.schema.columns[2].index);
    try std.testing.expect(ins.values[0][2] == .null_lit);
}

test "plan INSERT with nonexistent column returns ColumnNotFound" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT NOT NULL, y INT NOT NULL)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed_parser = Parser.init("INSERT INTO t(x, nonexistent) VALUES (1, 2)", alloc);

    defer parsed_parser.deinit();

    const parsed = try parsed_parser.parse();

    try std.testing.expectError(PlanError.ColumnNotFound, planner.plan(parsed));
}
