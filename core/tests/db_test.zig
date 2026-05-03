const std = @import("std");
const Db = @import("../db.zig").Db;
const DiskPager = @import("../pager/disk.zig").DiskPager;
const row = @import("../row.zig");
const exec = @import("../sql/executor.zig").execute;

const Dir = std.Io.Dir;

test "create db, insert rows, scan back" {
    const io = std.testing.io;
    const path = "/tmp/test_db_insert_scan.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    {
        const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);

        try db.createTable("users", &.{
            .{ .name = "name", .col_type = .text, .nullable = false },
            .{ .name = "age", .col_type = .int, .nullable = true },
        });

        _ = try db.insert("users", &.{
            .{ .text = "alice" },
            .{ .int = 30 },
        });
        _ = try db.insert("users", &.{
            .{ .text = "bob" },
            .null,
        });

        db.close();
    }

    const db2 = try Db.load(try DiskPager.open(alloc, io, path), alloc);
    defer db2.close();

    var count: usize = 0;
    try db2.scan("users", struct {
        fn cb(rowid: u64, values: []const row.Value, ctx: anytype) bool {
            _ = rowid;
            _ = values;
            ctx.* += 1;
            return true;
        }
    }.cb, &count);

    try std.testing.expectEqual(count, 2);
}

test "insert with default value" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const path = "/tmp/test_db_insert_default_value.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};

    {
        const db1 = try Db.init(try DiskPager.create(alloc, io, path), alloc);
        defer db1.close();

        var r1 = try exec(db1, "CREATE TABLE users(name TEXT, age INT DEFAULT 18);", alloc);
        defer r1.deinit();
    }

    const db = try Db.load(try DiskPager.open(alloc, io, path), alloc);
    defer db.close();

    var r2 = try exec(db, "INSERT INTO users(name) VALUES('alice');", alloc);
    defer r2.deinit();

    var r3 = try exec(db, "SELECT age FROM users WHERE name = 'alice';", alloc);
    defer r3.deinit();

    switch (r3) {
        .result_set => |rs| {
            try std.testing.expectEqual(@as(usize, 1), rs.rows.len);
            try std.testing.expectEqual(@as(i64, 18), rs.rows[0].values[0].int);
        },
        else => unreachable, // test assumes SELECT returns result_set
    }
}

test "rowid_counter increments across reopens" {
    const io = std.testing.io;
    const path = "/tmp/test_db_rowid.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const r1 = blk: {
        const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
        try db.createTable("t", &.{
            .{ .name = "v", .col_type = .int, .nullable = false },
        });
        const r = try db.insert("t", &.{.{ .int = 1 }});
        db.close();
        break :blk r;
    };

    const db2 = try Db.load(try DiskPager.open(alloc, io, path), alloc);
    defer db2.close();
    const r2 = try db2.insert("t", &.{.{ .int = 2 }});

    try std.testing.expect(r2 > r1);
}

test "insert and scan verify row contents" {
    const io = std.testing.io;
    const path = "/tmp/test_db_contents.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    try db.createTable("things", &.{
        .{ .name = "label", .col_type = .text, .nullable = false },
        .{ .name = "score", .col_type = .int, .nullable = false },
    });

    _ = try db.insert("things", &.{ .{ .text = "alpha" }, .{ .int = 100 } });
    _ = try db.insert("things", &.{ .{ .text = "beta" }, .{ .int = 200 } });

    const Ctx = struct { count: usize, sum: i64 };
    var ctx = Ctx{ .count = 0, .sum = 0 };
    try db.scan("things", struct {
        fn cb(rowid: u64, values: []const row.Value, c: anytype) bool {
            _ = rowid;
            c.count += 1;
            c.sum += values[1].int;
            return true;
        }
    }.cb, &ctx);

    try std.testing.expectEqual(ctx.count, 2);
    try std.testing.expectEqual(ctx.sum, 300);
}

test "TableNotFound returned for missing table" {
    const io = std.testing.io;
    const path = "/tmp/test_db_notfound.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    try std.testing.expectError(error.TableNotFound, db.insert("nonexistent", &.{}));
}

test "delete removes row and scan skips it" {
    const io = std.testing.io;
    const path = "/tmp/test_db_delete.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    try db.createTable("t", &.{.{ .name = "v", .col_type = .int, .nullable = false }});

    const r1 = try db.insert("t", &.{.{ .int = 1 }});
    const r2 = try db.insert("t", &.{.{ .int = 2 }});
    const r3 = try db.insert("t", &.{.{ .int = 3 }});

    try std.testing.expect(try db.delete("t", r2));

    const ScanCtx = struct { ids: [3]u64 = undefined, count: usize = 0 };
    var scan_ctx = ScanCtx{};
    try db.scan("t", struct {
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
    const io = std.testing.io;
    const path = "/tmp/test_db_delete_missing.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    try db.createTable("t", &.{.{ .name = "v", .col_type = .int, .nullable = false }});

    try std.testing.expect(!try db.delete("t", 99));
}

test "update changes row value" {
    const io = std.testing.io;
    const path = "/tmp/test_db_update.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    try db.createTable("t", &.{.{ .name = "v", .col_type = .int, .nullable = false }});
    const rowid = try db.insert("t", &.{.{ .int = 100 }});

    try std.testing.expect(try db.update("t", rowid, &.{.{ .int = 999 }}));

    const vals = try db.getByRowid("t", rowid, alloc);
    try std.testing.expect(vals != null);
    defer alloc.free(vals.?);
    try std.testing.expectEqual(vals.?[0].int, 999);
}

test "update inline to overflow builds new chain" {
    const io = std.testing.io;
    const path = "/tmp/test_db_update_overflow.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    try db.createTable("t", &.{.{ .name = "v", .col_type = .blob, .nullable = false }});

    const small = [_]u8{0xAA} ** 16;
    const rowid = try db.insert("t", &.{.{ .blob = &small }});

    const big = try alloc.alloc(u8, 5000);
    defer alloc.free(big);
    @memset(big, 0xBB);
    try std.testing.expect(try db.update("t", rowid, &.{.{ .blob = big }}));

    const vals = try db.getByRowid("t", rowid, alloc);
    try std.testing.expect(vals != null);
    defer {
        alloc.free(vals.?[0].blob);
        alloc.free(vals.?);
    }
    try std.testing.expectEqual(vals.?[0].blob.len, 5000);
    try std.testing.expect(vals.?[0].blob[0] == 0xBB);
}

test "update overflow to inline frees old chain" {
    const io = std.testing.io;
    const path = "/tmp/test_db_update_shrink.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    try db.createTable("t", &.{.{ .name = "v", .col_type = .blob, .nullable = false }});

    const big = try alloc.alloc(u8, 5000);
    defer alloc.free(big);
    @memset(big, 0xCC);
    const rowid = try db.insert("t", &.{.{ .blob = big }});

    const pages_before = db.pager.total_pages;

    const small = [_]u8{0xDD} ** 16;
    try std.testing.expect(try db.update("t", rowid, &.{.{ .blob = &small }}));

    try std.testing.expect(db.pager.free_list_head != 0 or db.pager.total_pages < pages_before);

    const vals = try db.getByRowid("t", rowid, alloc);
    try std.testing.expect(vals != null);
    defer {
        alloc.free(vals.?[0].blob);
        alloc.free(vals.?);
    }
    try std.testing.expectEqual(vals.?[0].blob.len, 16);
    try std.testing.expect(vals.?[0].blob[0] == 0xDD);
}

test "exec with schema-qualified table name" {
    const io = std.testing.io;
    const path = "/tmp/test_db_schema.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const execute = @import("../sql/executor.zig").execute;
    const PlanError = @import("../sql/logical_plan.zig").PlanError;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    // Create table and insert data
    var r = try execute(db, "CREATE TABLE users (id INT, name TEXT)", alloc);
    r.deinit();
    r = try execute(db, "INSERT INTO users VALUES (1, 'alice')", alloc);
    r.deinit();
    r = try execute(db, "INSERT INTO users VALUES (2, 'bob')", alloc);
    r.deinit();

    // Query without schema (default)
    var result = try execute(db, "SELECT * FROM users", alloc);
    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows.len);
    result.deinit();

    // Query with main schema
    result = try execute(db, "SELECT * FROM main.users", alloc);
    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows.len);
    result.deinit();

    // Query with non-existent schema should fail
    try std.testing.expectError(PlanError.TableNotFound, execute(db, "SELECT * FROM other.users", alloc));
}
