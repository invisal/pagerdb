const std = @import("std");
const th = @import("../test_helpers.zig");
const cursor_mod = @import("root.zig");
const agg_mod = @import("agg_func.zig");

fn openSeqScanInput(db: anytype, a: std.mem.Allocator, table: []const u8) !*cursor_mod.Cursor {
    const input = try a.create(cursor_mod.Cursor);
    input.* = .{ .seq_scan = .{ .it = try db.scanOpen(table) } };
    return input;
}

test "aggregate cursor: COUNT(*) and COUNT(col) without GROUP BY" {
    const h = try th.makeMemoryDb(std.testing.allocator, .{});
    defer h.deinit();

    try h.db.createTable("t", &.{
        .{ .name = "grp", .col_type = .int, .nullable = false },
        .{ .name = "v", .col_type = .int, .nullable = true },
    });

    _ = try h.db.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });
    _ = try h.db.insert("t", &.{ .{ .int = 1 }, .null });
    _ = try h.db.insert("t", &.{ .{ .int = 2 }, .{ .int = 7 } });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const input = try openSeqScanInput(h.db, a, "t");

    const specs = [_]cursor_mod.AggSpec{
        .{ .func = &agg_mod.CountFunc, .col_idx = null },
        .{ .func = &agg_mod.CountFunc, .col_idx = 1 },
    };

    var ac = cursor_mod.AggregateCursor{
        .input = input,
        .agg_specs = &specs,
        .group_by = &.{},
        .result = null,
        .pos = 0,
    };
    defer ac.deinit(a);

    const batch = (try ac.next(a)).?;
    try std.testing.expectEqual(@as(usize, 1), batch.len);
    try std.testing.expectEqual(@as(i64, 3), batch[0].values[0].int); // COUNT(*)
    try std.testing.expectEqual(@as(i64, 2), batch[0].values[1].int); // COUNT(v)
    try std.testing.expect((try ac.next(a)) == null);
}

test "aggregate cursor: COUNT(*) with GROUP BY preserves first-seen group order" {
    const h = try th.makeMemoryDb(std.testing.allocator, .{});
    defer h.deinit();

    try h.db.createTable("t", &.{
        .{ .name = "grp", .col_type = .int, .nullable = false },
        .{ .name = "v", .col_type = .int, .nullable = true },
    });

    _ = try h.db.insert("t", &.{ .{ .int = 2 }, .{ .int = 10 } });
    _ = try h.db.insert("t", &.{ .{ .int = 1 }, .{ .int = 20 } });
    _ = try h.db.insert("t", &.{ .{ .int = 2 }, .null });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const input = try openSeqScanInput(h.db, a, "t");

    const specs = [_]cursor_mod.AggSpec{
        .{ .func = &agg_mod.CountFunc, .col_idx = null },
    };
    const groups = [_]usize{0};

    var ac = cursor_mod.AggregateCursor{
        .input = input,
        .agg_specs = &specs,
        .group_by = &groups,
        .result = null,
        .pos = 0,
    };
    defer ac.deinit(a);

    const batch = (try ac.next(a)).?;
    try std.testing.expectEqual(@as(usize, 2), batch.len);

    // Output shape is [group_key..., agg_values...].
    try std.testing.expectEqual(@as(i64, 2), batch[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 2), batch[0].values[1].int);

    try std.testing.expectEqual(@as(i64, 1), batch[1].values[0].int);
    try std.testing.expectEqual(@as(i64, 1), batch[1].values[1].int);
    try std.testing.expect((try ac.next(a)) == null);
}

test "aggregate cursor: SUM/AVG/MIN/MAX without GROUP BY" {
    const h = try th.makeMemoryDb(std.testing.allocator, .{});
    defer h.deinit();

    try h.db.createTable("t", &.{
        .{ .name = "grp", .col_type = .int, .nullable = false },
        .{ .name = "v", .col_type = .int, .nullable = true },
    });

    _ = try h.db.insert("t", &.{ .{ .int = 1 }, .{ .int = 10 } });
    _ = try h.db.insert("t", &.{ .{ .int = 1 }, .null });
    _ = try h.db.insert("t", &.{ .{ .int = 2 }, .{ .int = 7 } });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const input = try openSeqScanInput(h.db, a, "t");

    const specs = [_]cursor_mod.AggSpec{
        .{ .func = &agg_mod.SumFunc, .col_idx = 1 },
        .{ .func = &agg_mod.AvgFunc, .col_idx = 1 },
        .{ .func = &agg_mod.MinFunc, .col_idx = 1 },
        .{ .func = &agg_mod.MaxFunc, .col_idx = 1 },
    };

    var ac = cursor_mod.AggregateCursor{
        .input = input,
        .agg_specs = &specs,
        .group_by = &.{},
        .result = null,
        .pos = 0,
    };
    defer ac.deinit(a);

    const batch = (try ac.next(a)).?;
    try std.testing.expectEqual(@as(usize, 1), batch.len);
    try std.testing.expectEqual(@as(i64, 17), batch[0].values[0].int);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), batch[0].values[1].real, 1e-9);
    try std.testing.expectEqual(@as(i64, 7), batch[0].values[2].int);
    try std.testing.expectEqual(@as(i64, 10), batch[0].values[3].int);
    try std.testing.expect((try ac.next(a)) == null);
}

test "aggregate cursor: SUM/AVG/MIN/MAX with GROUP BY" {
    const h = try th.makeMemoryDb(std.testing.allocator, .{});
    defer h.deinit();

    try h.db.createTable("t", &.{
        .{ .name = "grp", .col_type = .int, .nullable = false },
        .{ .name = "v", .col_type = .real, .nullable = true },
    });

    _ = try h.db.insert("t", &.{ .{ .int = 2 }, .{ .real = 10.0 } });
    _ = try h.db.insert("t", &.{ .{ .int = 1 }, .{ .real = 1.5 } });
    _ = try h.db.insert("t", &.{ .{ .int = 2 }, .null });
    _ = try h.db.insert("t", &.{ .{ .int = 2 }, .{ .real = 7.5 } });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const input = try openSeqScanInput(h.db, a, "t");

    const specs = [_]cursor_mod.AggSpec{
        .{ .func = &agg_mod.SumFunc, .col_idx = 1 },
        .{ .func = &agg_mod.AvgFunc, .col_idx = 1 },
        .{ .func = &agg_mod.MinFunc, .col_idx = 1 },
        .{ .func = &agg_mod.MaxFunc, .col_idx = 1 },
    };
    const groups = [_]usize{0};

    var ac = cursor_mod.AggregateCursor{
        .input = input,
        .agg_specs = &specs,
        .group_by = &groups,
        .result = null,
        .pos = 0,
    };
    defer ac.deinit(a);

    const batch = (try ac.next(a)).?;
    try std.testing.expectEqual(@as(usize, 2), batch.len);

    // First seen group key is 2.
    try std.testing.expectEqual(@as(i64, 2), batch[0].values[0].int);
    try std.testing.expectApproxEqAbs(@as(f64, 17.5), batch[0].values[1].real, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.75), batch[0].values[2].real, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 7.5), batch[0].values[3].real, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), batch[0].values[4].real, 1e-9);

    try std.testing.expectEqual(@as(i64, 1), batch[1].values[0].int);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), batch[1].values[1].real, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), batch[1].values[2].real, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), batch[1].values[3].real, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), batch[1].values[4].real, 1e-9);
    try std.testing.expect((try ac.next(a)) == null);
}
