const std = @import("std");
const Parser = @import("../parser.zig").Parser;
const LogicalPlanner = @import("../logical_plan.zig").LogicalPlanner;
const PlanError = @import("../logical_plan.zig").PlanError;
const ast = @import("../ast.zig");
const makeMemoryDb = @import("../../test_helpers.zig").makeMemoryDb;

test "unknown table returns TableNotFound" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{});
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM ghost", alloc);
    defer parsed.deinit();

    try std.testing.expectError(PlanError.TableNotFound, planner.plan(parsed.stmt));
}

test "non-main schema returns TableNotFound" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE users (name TEXT NOT NULL)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM other.users", alloc);
    defer parsed.deinit();

    try std.testing.expectError(PlanError.TableNotFound, planner.plan(parsed.stmt));
}

test "unknown column in WHERE returns ColumnNotFound" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT NOT NULL)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM t WHERE y = 1", alloc);
    defer parsed.deinit();

    try std.testing.expectError(PlanError.ColumnNotFound, planner.plan(parsed.stmt));
}

test "__rowid resolves to correct column index" {
    const alloc = std.testing.allocator;
    var h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT NOT NULL)"} });
    defer h.deinit();
    var planner = LogicalPlanner.init(&h.db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM t WHERE __rowid = 42", alloc);
    defer parsed.deinit();

    // t has 1 real column, so __rowid is at index 1.
    const pred = (try planner.plan(parsed.stmt)).project.input.filter.predicate.binary;
    try std.testing.expectEqual(ast.BinaryOp.eq, pred.op);
    try std.testing.expectEqual(@as(usize, 1), pred.left.col_idx);
    try std.testing.expectEqual(@as(i64, 42), pred.right.int_lit);
}
