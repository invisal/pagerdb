const std = @import("std");
const Db = @import("../db.zig").Db;
const DiskPager = @import("../pager/disk.zig").DiskPager;
const row = @import("../row.zig");
const execute = @import("../sql/executor.zig").execute;

const Dir = std.Io.Dir;

test "execute SELECT * returns all rows" {
    const io = std.testing.io;
    const path = "/tmp/test_exec_select_all.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    try db.createTable("t", &.{
        .{ .name = "n", .col_type = .int, .nullable = false },
    });
    _ = try db.insert("t", &.{.{ .int = 1 }});
    _ = try db.insert("t", &.{.{ .int = 2 }});
    _ = try db.insert("t", &.{.{ .int = 3 }});

    var result = try execute(db, "SELECT * FROM t", alloc);
    defer result.result_set.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.result_set.rows.len);
}

test "execute SELECT with WHERE filters rows" {
    const io = std.testing.io;
    const path = "/tmp/test_exec_select_where.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    try db.createTable("t", &.{
        .{ .name = "score", .col_type = .int, .nullable = false },
    });
    _ = try db.insert("t", &.{.{ .int = 10 }});
    _ = try db.insert("t", &.{.{ .int = 50 }});
    _ = try db.insert("t", &.{.{ .int = 100 }});

    var result = try execute(db, "SELECT * FROM t WHERE score > 40", alloc);
    defer result.result_set.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.result_set.rows.len);
}

test "execute INSERT adds a row" {
    const io = std.testing.io;
    const path = "/tmp/test_exec_insert.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    _ = try execute(db, "CREATE TABLE t (n INT NOT NULL)", alloc);
    const r1 = try execute(db, "INSERT INTO t VALUES (42)", alloc);
    try std.testing.expectEqual(@as(u64, 1), r1.affected);

    var sel = try execute(db, "SELECT * FROM t", alloc);
    defer sel.result_set.deinit();
    try std.testing.expectEqual(@as(usize, 1), sel.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 42), sel.result_set.rows[0].values[0].int);
}

test "execute UPDATE changes value" {
    const io = std.testing.io;
    const path = "/tmp/test_exec_update.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    try db.createTable("t", &.{
        .{ .name = "name", .col_type = .text, .nullable = false },
        .{ .name = "score", .col_type = .int, .nullable = false },
    });
    _ = try db.insert("t", &.{
        .{ .text = "alice" },
        .{ .int = 10 },
    });

    const upd = try execute(db, "UPDATE t SET score = 999 WHERE name = 'alice'", alloc);
    try std.testing.expectEqual(@as(u64, 1), upd.affected);

    var sel = try execute(db, "SELECT * FROM t", alloc);
    defer sel.result_set.deinit();
    try std.testing.expectEqual(@as(i64, 999), sel.result_set.rows[0].values[1].int);
}

test "execute DELETE removes row" {
    const io = std.testing.io;
    const path = "/tmp/test_exec_delete.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    try db.createTable("t", &.{
        .{ .name = "name", .col_type = .text, .nullable = false },
    });
    _ = try db.insert("t", &.{.{ .text = "a" }});
    _ = try db.insert("t", &.{.{ .text = "b" }});
    _ = try db.insert("t", &.{.{ .text = "c" }});

    const del = try execute(db, "DELETE FROM t WHERE name = 'b'", alloc);
    try std.testing.expectEqual(@as(u64, 1), del.affected);

    var sel = try execute(db, "SELECT * FROM t", alloc);
    defer sel.result_set.deinit();
    try std.testing.expectEqual(@as(usize, 2), sel.result_set.rows.len);
}

test "execute CREATE TABLE then INSERT works" {
    const io = std.testing.io;
    const path = "/tmp/test_exec_create.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    _ = try execute(db, "CREATE TABLE items (id INT NOT NULL, label TEXT)", alloc);
    _ = try execute(db, "INSERT INTO items VALUES (1, 'thing')", alloc);

    var sel = try execute(db, "SELECT * FROM items", alloc);
    defer sel.result_set.deinit();
    try std.testing.expectEqual(@as(usize, 1), sel.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 1), sel.result_set.rows[0].values[0].int);
}

test "execute point-lookup via _rowid_" {
    const io = std.testing.io;
    const path = "/tmp/test_exec_rowid.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    try db.createTable("t", &.{
        .{ .name = "v", .col_type = .int, .nullable = false },
    });
    _ = try db.insert("t", &.{.{ .int = 11 }});
    const rowid = try db.insert("t", &.{.{ .int = 22 }});
    _ = try db.insert("t", &.{.{ .int = 33 }});

    var buf: [64]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf, "SELECT * FROM t WHERE _rowid_ = {d}", .{rowid});

    var result = try execute(db, sql, alloc);
    defer result.result_set.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 22), result.result_set.rows[0].values[0].int);
}

test "UPDATE with no matching rows returns affected=0" {
    const io = std.testing.io;
    const path = "/tmp/test_exec_upd_nomatch.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    try db.createTable("t", &.{.{ .name = "x", .col_type = .int, .nullable = false }});
    _ = try db.insert("t", &.{.{ .int = 1 }});

    const upd = try execute(db, "UPDATE t SET x = 99 WHERE x = 999", alloc);
    try std.testing.expectEqual(@as(u64, 0), upd.affected);
}

test "SELECT * FROM __pages returns at least the header page" {
    const io = std.testing.io;
    const path = "/tmp/test_exec_vtab_pages.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    var result = try execute(db, "SELECT * FROM __pages", alloc);
    defer result.result_set.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 0), result.result_set.rows[0].values[0].int);
    try std.testing.expectEqualStrings("header", result.result_set.rows[0].values[1].text);
}

test "SELECT * FROM __pages after creating table has more pages" {
    const io = std.testing.io;
    const path = "/tmp/test_exec_vtab_pages2.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    _ = try execute(db, "CREATE TABLE t (n INT NOT NULL)", alloc);

    var result = try execute(db, "SELECT * FROM __pages", alloc);
    defer result.result_set.deinit();

    try std.testing.expect(result.result_set.rows.len >= 4);
}

test "SELECT * FROM __page_slots(1) shows btree_leaf cells" {
    const io = std.testing.io;
    const path = "/tmp/test_exec_vtab_slots.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    _ = try execute(db, "CREATE TABLE t (n INT NOT NULL)", alloc);
    _ = try execute(db, "INSERT INTO t VALUES (10)", alloc);
    _ = try execute(db, "INSERT INTO t VALUES (20)", alloc);

    var pages_res = try execute(db, "SELECT * FROM __pages", alloc);
    defer pages_res.result_set.deinit();

    var leaf_page_id: i64 = -1;
    for (pages_res.result_set.rows) |r| {
        if (std.mem.eql(u8, r.values[1].text, "btree_leaf"))
            leaf_page_id = r.values[0].int;
    }
    try std.testing.expect(leaf_page_id >= 0);

    var buf: [64]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf, "SELECT * FROM __page_slots({d})", .{leaf_page_id});
    var slots = try execute(db, sql, alloc);
    defer slots.result_set.deinit();

    try std.testing.expectEqual(@as(usize, 2), slots.result_set.rows.len);
    try std.testing.expectEqual(@as(i64, 0), slots.result_set.rows[0].values[0].int);
    try std.testing.expectEqual(@as(i64, 1), slots.result_set.rows[1].values[0].int);
}

test "DELETE with no matching rows returns affected=0" {
    const io = std.testing.io;
    const path = "/tmp/test_exec_del_nomatch.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();

    try db.createTable("t", &.{.{ .name = "x", .col_type = .int, .nullable = false }});
    _ = try db.insert("t", &.{.{ .int = 1 }});

    const del = try execute(db, "DELETE FROM t WHERE x = 999", alloc);
    try std.testing.expectEqual(@as(u64, 0), del.affected);
}
