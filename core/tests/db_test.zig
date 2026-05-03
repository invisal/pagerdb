const std = @import("std");
const row = @import("../row.zig");
const th = @import("../test_helpers.zig");
const makeMemoryDb = th.makeMemoryDb;
const makeDiskDb = th.makeDiskDb;
const loadDiskDb = th.loadDiskDb;

test "create db, insert rows, scan back" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    {
        const h = try makeDiskDb(alloc, io, "/tmp/test_db_insert_scan.db", .{});
        defer h.db.close();
        try h.db.createTable("users", &.{
            .{ .name = "name", .col_type = .text, .nullable = false },
            .{ .name = "age", .col_type = .int, .nullable = true },
        });
        _ = try h.db.insert("users", &.{ .{ .text = "alice" }, .{ .int = 30 } });
        _ = try h.db.insert("users", &.{ .{ .text = "bob" }, .null });
    }

    const h2 = try loadDiskDb(alloc, io, "/tmp/test_db_insert_scan.db");
    defer h2.deinit();

    var count: usize = 0;
    try h2.db.scan("users", struct {
        fn cb(_: u64, _: []const row.Value, ctx: anytype) bool {
            ctx.* += 1;
            return true;
        }
    }.cb, &count);
    try std.testing.expectEqual(count, 2);
}

test "rowid_counter increments across reopens" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const r1 = blk: {
        const h = try makeDiskDb(alloc, io, "/tmp/test_db_rowid.db", .{});
        defer h.db.close();
        try h.db.createTable("t", &.{.{ .name = "v", .col_type = .int, .nullable = false }});
        break :blk try h.db.insert("t", &.{.{ .int = 1 }});
    };

    const h2 = try loadDiskDb(alloc, io, "/tmp/test_db_rowid.db");
    defer h2.deinit();
    const r2 = try h2.db.insert("t", &.{.{ .int = 2 }});

    try std.testing.expect(r2 > r1);
}

test "insert and scan verify row contents" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    try h.db.createTable("things", &.{
        .{ .name = "label", .col_type = .text, .nullable = false },
        .{ .name = "score", .col_type = .int, .nullable = false },
    });
    _ = try h.db.insert("things", &.{ .{ .text = "alpha" }, .{ .int = 100 } });
    _ = try h.db.insert("things", &.{ .{ .text = "beta" }, .{ .int = 200 } });

    const Ctx = struct { count: usize, sum: i64 };
    var ctx = Ctx{ .count = 0, .sum = 0 };
    try h.db.scan("things", struct {
        fn cb(_: u64, values: []const row.Value, c: anytype) bool {
            c.count += 1;
            c.sum += values[1].int;
            return true;
        }
    }.cb, &ctx);

    try std.testing.expectEqual(ctx.count, 2);
    try std.testing.expectEqual(ctx.sum, 300);
}

test "TableNotFound returned for missing table" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();
    try std.testing.expectError(error.TableNotFound, h.db.insert("nonexistent", &.{}));
}

test "delete removes row and scan skips it" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    try h.db.createTable("t", &.{.{ .name = "v", .col_type = .int, .nullable = false }});
    const r1 = try h.db.insert("t", &.{.{ .int = 1 }});
    const r2 = try h.db.insert("t", &.{.{ .int = 2 }});
    const r3 = try h.db.insert("t", &.{.{ .int = 3 }});
    try std.testing.expect(try h.db.delete("t", r2));

    const ScanCtx = struct { ids: [3]u64 = undefined, count: usize = 0 };
    var scan_ctx = ScanCtx{};
    try h.db.scan("t", struct {
        fn cb(rowid: u64, _: []const row.Value, ctx: anytype) bool {
            ctx.ids[ctx.count] = rowid;
            ctx.count += 1;
            return true;
        }
    }.cb, &scan_ctx);

    try std.testing.expectEqual(scan_ctx.count, 2);
    try std.testing.expectEqual(scan_ctx.ids[0], r1);
    try std.testing.expectEqual(scan_ctx.ids[1], r3);
}

test "delete non-existent rowid returns false" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();
    try h.db.createTable("t", &.{.{ .name = "v", .col_type = .int, .nullable = false }});
    try std.testing.expect(!try h.db.delete("t", 99));
}

test "update changes row value" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    try h.db.createTable("t", &.{.{ .name = "v", .col_type = .int, .nullable = false }});
    const rowid = try h.db.insert("t", &.{.{ .int = 100 }});
    try std.testing.expect(try h.db.update("t", rowid, &.{.{ .int = 999 }}));

    const vals = try h.db.getByRowid("t", rowid, alloc);
    try std.testing.expect(vals != null);
    defer alloc.free(vals.?);
    try std.testing.expectEqual(vals.?[0].int, 999);
}

test "update inline to overflow builds new chain" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    try h.db.createTable("t", &.{.{ .name = "v", .col_type = .blob, .nullable = false }});
    const small = [_]u8{0xAA} ** 16;
    const rowid = try h.db.insert("t", &.{.{ .blob = &small }});

    const big = try alloc.alloc(u8, 5000);
    defer alloc.free(big);
    @memset(big, 0xBB);
    try std.testing.expect(try h.db.update("t", rowid, &.{.{ .blob = big }}));

    const vals = try h.db.getByRowid("t", rowid, alloc);
    try std.testing.expect(vals != null);
    defer {
        alloc.free(vals.?[0].blob);
        alloc.free(vals.?);
    }
    try std.testing.expectEqual(vals.?[0].blob.len, 5000);
    try std.testing.expect(vals.?[0].blob[0] == 0xBB);
}

test "update overflow to inline frees old chain" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    try h.db.createTable("t", &.{.{ .name = "v", .col_type = .blob, .nullable = false }});
    const big = try alloc.alloc(u8, 5000);
    defer alloc.free(big);
    @memset(big, 0xCC);
    const rowid = try h.db.insert("t", &.{.{ .blob = big }});
    const pages_before = h.db.pager.total_pages;

    const small = [_]u8{0xDD} ** 16;
    try std.testing.expect(try h.db.update("t", rowid, &.{.{ .blob = &small }}));
    try std.testing.expect(h.db.pager.free_list_head != 0 or h.db.pager.total_pages < pages_before);

    const vals = try h.db.getByRowid("t", rowid, alloc);
    try std.testing.expect(vals != null);
    defer {
        alloc.free(vals.?[0].blob);
        alloc.free(vals.?);
    }
    try std.testing.expectEqual(vals.?[0].blob.len, 16);
    try std.testing.expect(vals.?[0].blob[0] == 0xDD);
}

test "begin + commit persists rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    try h.db.createTable("t", &.{.{ .name = "v", .col_type = .int, .nullable = false }});
    try h.db.begin();
    _ = try h.db.insert("t", &.{.{ .int = 1 }});
    _ = try h.db.insert("t", &.{.{ .int = 2 }});
    _ = try h.db.insert("t", &.{.{ .int = 3 }});
    try h.db.commit();

    var count: usize = 0;
    try h.db.scan("t", struct {
        fn cb(_: u64, _: []const row.Value, ctx: anytype) bool {
            ctx.* += 1;
            return true;
        }
    }.cb, &count);
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "begin + rollback erases inserted rows" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    try h.db.createTable("t", &.{.{ .name = "v", .col_type = .int, .nullable = false }});
    try h.db.begin();
    _ = try h.db.insert("t", &.{.{ .int = 1 }});
    _ = try h.db.insert("t", &.{.{ .int = 2 }});
    try h.db.rollback();

    var count: usize = 0;
    try h.db.scan("t", struct {
        fn cb(_: u64, _: []const row.Value, ctx: anytype) bool {
            ctx.* += 1;
            return true;
        }
    }.cb, &count);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "rollback of DELETE restores the row" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    try h.db.createTable("t", &.{.{ .name = "v", .col_type = .int, .nullable = false }});
    const rowid = try h.db.insert("t", &.{.{ .int = 42 }});
    try h.db.begin();
    try std.testing.expect(try h.db.delete("t", rowid));
    try h.db.rollback();

    const vals = try h.db.getByRowid("t", rowid, alloc);
    try std.testing.expect(vals != null);
    defer alloc.free(vals.?);
    try std.testing.expectEqual(@as(i64, 42), vals.?[0].int);
}

test "rollback of UPDATE restores original value" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    try h.db.createTable("t", &.{.{ .name = "v", .col_type = .int, .nullable = false }});
    const rowid = try h.db.insert("t", &.{.{ .int = 10 }});
    try h.db.begin();
    try std.testing.expect(try h.db.update("t", rowid, &.{.{ .int = 999 }}));
    try h.db.rollback();

    const vals = try h.db.getByRowid("t", rowid, alloc);
    try std.testing.expect(vals != null);
    defer alloc.free(vals.?);
    try std.testing.expectEqual(@as(i64, 10), vals.?[0].int);
}

test "auto-commit works without explicit BEGIN" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();

    try h.db.createTable("t", &.{.{ .name = "v", .col_type = .int, .nullable = false }});
    const rowid = try h.db.insert("t", &.{.{ .int = 7 }});

    const vals = try h.db.getByRowid("t", rowid, alloc);
    try std.testing.expect(vals != null);
    defer alloc.free(vals.?);
    try std.testing.expectEqual(@as(i64, 7), vals.?[0].int);
}

test "double BEGIN returns error" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();
    try h.db.begin();
    try std.testing.expectError(error.TransactionAlreadyActive, h.db.begin());
    try h.db.rollback();
}

test "COMMIT with no active transaction returns error" {
    const alloc = std.testing.allocator;
    const h = try makeMemoryDb(alloc, .{});
    defer h.deinit();
    try std.testing.expectError(error.NoActiveTransaction, h.db.commit());
}
