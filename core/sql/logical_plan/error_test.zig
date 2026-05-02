const std = @import("std");
const Parser = @import("../parser.zig").Parser;
const LogicalPlanner = @import("../logical_plan.zig").LogicalPlanner;
const PlanError = @import("../logical_plan.zig").PlanError;
const ROWID_SENTINEL = @import("../logical_plan.zig").ROWID_SENTINEL;
const ast = @import("../ast.zig");
const utils = @import("utils.zig");
const makeDb = utils.makeDb;

const Dir = utils.Dir;

test "unknown table returns TableNotFound" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_notfound.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM ghost", alloc);
    defer parsed.deinit();

    try std.testing.expectError(PlanError.TableNotFound, planner.plan(parsed.stmt));
}

test "non-main schema returns TableNotFound" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_badschema.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("users", &.{
        .{ .name = "name", .col_type = .text, .nullable = false },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    // Only "main" schema is supported; "other" schema should fail
    var parsed = try Parser.parse("SELECT * FROM other.users", alloc);
    defer parsed.deinit();

    try std.testing.expectError(PlanError.TableNotFound, planner.plan(parsed.stmt));
}

test "unknown column in WHERE returns ColumnNotFound" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_badcol.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "x", .col_type = .int, .nullable = false },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM t WHERE y = 1", alloc);
    defer parsed.deinit();

    try std.testing.expectError(PlanError.ColumnNotFound, planner.plan(parsed.stmt));
}

test "_rowid_ resolves to ROWID_SENTINEL" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_rowid.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "x", .col_type = .int, .nullable = false },
    });

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("SELECT * FROM t WHERE _rowid_ = 42", alloc);
    defer parsed.deinit();

    const lp = try planner.plan(parsed.stmt);
    const pred = lp.filter.predicate.binary;
    try std.testing.expectEqual(ast.BinaryOp.eq, pred.op);
    try std.testing.expectEqual(ROWID_SENTINEL, pred.left.col_idx);
    try std.testing.expectEqual(@as(i64, 42), pred.right.int_lit);
}
