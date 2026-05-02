const std = @import("std");
const Parser = @import("../parser.zig").Parser;
const LogicalPlanner = @import("../logical_plan.zig").LogicalPlanner;
const utils = @import("utils.zig");
const makeDb = utils.makeDb;

const Dir = utils.Dir;

test "plan CREATE TABLE" {
    const io = std.testing.io;
    const path = "/tmp/test_lp_create.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    var planner = LogicalPlanner.init(&db.cat, alloc);
    defer planner.deinit();

    var parsed = try Parser.parse("CREATE TABLE items (id INT NOT NULL, label TEXT)", alloc);
    defer parsed.deinit();

    const lp = try planner.plan(parsed.stmt);
    const ct = lp.create_table;
    try std.testing.expectEqualStrings("items", ct.table);
    try std.testing.expectEqual(@as(usize, 2), ct.columns.len);
    try std.testing.expectEqualStrings("id", ct.columns[0].name);
    try std.testing.expectEqual(false, ct.columns[0].nullable);
    try std.testing.expectEqualStrings("label", ct.columns[1].name);
    try std.testing.expectEqual(true, ct.columns[1].nullable);
}
