const std = @import("std");
const DiskPager = @import("../../pager/disk.zig").DiskPager;
const Db = @import("../../db.zig").Db;
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const Dir = std.Io.Dir;

// Simulate a crash by closing the pager file directly without flushing or
// rolling back.  The undo log pages and the undo_head in the header are
// already on disk (force-flushed by begin()), so Db.load() will detect the
// orphaned chain and recover.
fn abandonDb(db: *Db, alloc: std.mem.Allocator) void {
    if (db.txn) |*txn| txn.deinit();
    db.txn = null;
    db.pager.close(); // closes file, no flush
    db.cat.deinit();
    alloc.destroy(db);
}

test "crash after INSERT: row absent after recovery" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/test_crash_insert.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    defer Dir.deleteFile(.cwd(), io, path ++ ".wal") catch {};

    // Session 1: create schema cleanly.
    {
        const h = try th.makeDiskDb(alloc, io, path, .{ .schema = &.{"CREATE TABLE t (v INT)"} });
        h.db.close();
    }

    // Session 2: begin a transaction, insert a row, then crash.
    {
        const db = try Db.load(try DiskPager.open(alloc, io, path, .{}), alloc);
        try db.begin();
        _ = try db.insert("t", &.{.{ .int = 99 }});
        abandonDb(db, alloc); // crash here; undo_head != 0 on disk
    }

    // Session 3: reopen — recovery must run and the row must not exist.
    {
        const db = try Db.load(try DiskPager.open(alloc, io, path, .{}), alloc);
        defer db.close();
        try std.testing.expectEqual(@as(u32, 0), db.pager.undo_head);
        var it = try db.scanOpen("t");
        const first = try it.next(alloc);
        try std.testing.expect(first == null);
    }
}

test "crash after DELETE: row present after recovery" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/test_crash_delete.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    defer Dir.deleteFile(.cwd(), io, path ++ ".wal") catch {};

    // Session 1: create schema and commit one row; capture the assigned rowid.
    var inserted_rowid: u64 = undefined;
    {
        const h = try th.makeDiskDb(alloc, io, path, .{ .schema = &.{"CREATE TABLE t (v INT)"} });
        inserted_rowid = try h.db.insert("t", &.{.{ .int = 42 }});
        try h.db.pager.flush();
        h.db.close();
    }

    // Session 2: delete the row inside a transaction, then crash.
    {
        const db = try Db.load(try DiskPager.open(alloc, io, path, .{}), alloc);
        try db.begin();
        _ = try db.delete("t", inserted_rowid);
        abandonDb(db, alloc);
    }

    // Session 3: the row must be present after crash recovery.
    {
        const db = try Db.load(try DiskPager.open(alloc, io, path, .{}), alloc);
        defer db.close();
        try std.testing.expectEqual(@as(u32, 0), db.pager.undo_head);
        var it = try db.scanOpen("t");
        const entry = try it.next(alloc);
        try std.testing.expect(entry != null);
        alloc.free(entry.?.values);
    }
}

test "crash after UPDATE: old value present after recovery" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/test_crash_update.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    defer Dir.deleteFile(.cwd(), io, path ++ ".wal") catch {};

    // Session 1: create schema and commit one row with v=1; capture the assigned rowid.
    var inserted_rowid: u64 = undefined;
    {
        const h = try th.makeDiskDb(alloc, io, path, .{ .schema = &.{"CREATE TABLE t (v INT)"} });
        inserted_rowid = try h.db.insert("t", &.{.{ .int = 1 }});
        try h.db.pager.flush();
        h.db.close();
    }

    // Session 2: update to v=999 inside a transaction, then crash.
    {
        const db = try Db.load(try DiskPager.open(alloc, io, path, .{}), alloc);
        try db.begin();
        _ = try db.update("t", inserted_rowid, &.{.{ .int = 999 }});
        abandonDb(db, alloc);
    }

    // Session 3: the original value v=1 must be visible after recovery.
    {
        const db = try Db.load(try DiskPager.open(alloc, io, path, .{}), alloc);
        defer db.close();
        try std.testing.expectEqual(@as(u32, 0), db.pager.undo_head);
        const values = try db.getByRowid("t", inserted_rowid, alloc);
        try std.testing.expect(values != null);
        defer alloc.free(values.?);
        try std.testing.expectEqual(@as(i64, 1), values.?[0].int);
        for (values.?) |v| switch (v) {
            .text => |s| alloc.free(s),
            .blob => |b| alloc.free(b),
            else => {},
        };
    }
}

test "clean commit leaves undo_head at zero" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/test_clean_commit.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    defer Dir.deleteFile(.cwd(), io, path ++ ".wal") catch {};

    {
        const h = try th.makeDiskDb(alloc, io, path, .{ .schema = &.{"CREATE TABLE t (v INT)"} });
        try h.db.begin();
        _ = try h.db.insert("t", &.{.{ .int = 7 }});
        try h.db.commit();
        h.db.close();
    }

    {
        const db = try Db.load(try DiskPager.open(alloc, io, path, .{}), alloc);
        defer db.close();
        try std.testing.expectEqual(@as(u32, 0), db.pager.undo_head);
    }
}

test "clean rollback leaves undo_head at zero" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/test_clean_rollback.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    defer Dir.deleteFile(.cwd(), io, path ++ ".wal") catch {};

    {
        const h = try th.makeDiskDb(alloc, io, path, .{ .schema = &.{"CREATE TABLE t (v INT)"} });
        try h.db.begin();
        _ = try h.db.insert("t", &.{.{ .int = 7 }});
        try h.db.rollback();
        h.db.close();
    }

    {
        const db = try Db.load(try DiskPager.open(alloc, io, path, .{}), alloc);
        defer db.close();
        try std.testing.expectEqual(@as(u32, 0), db.pager.undo_head);
    }
}

test "checkpoint: committed data survives reopen after WAL-only commit" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/test_checkpoint.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    defer Dir.deleteFile(.cwd(), io, path ++ ".wal") catch {};

    // Session 1: commit a row (NO-FORCE: data pages stay in buffer pool),
    // then checkpoint (flushes dirty pages to data file, rotates WAL).
    {
        const h = try th.makeDiskDb(alloc, io, path, .{ .schema = &.{"CREATE TABLE t (v INT)"} });
        try h.db.begin();
        _ = try h.db.insert("t", &.{.{ .int = 42 }});
        try h.db.commit();
        // At this point the row is committed in the WAL but may not be in the data file.
        // Checkpoint flushes everything and rotates the WAL.
        try h.db.checkpoint();
        h.db.close();
    }

    // Session 2: reopen without recovery needed; the row must be present.
    {
        const db = try Db.load(try DiskPager.open(alloc, io, path, .{}), alloc);
        defer db.close();
        try std.testing.expectEqual(@as(u32, 0), db.pager.undo_head);
        var it = try db.scanOpen("t");
        const entry = try it.next(alloc);
        try std.testing.expect(entry != null);
        try std.testing.expectEqual(@as(i64, 42), entry.?.values[0].int);
        alloc.free(entry.?.values);
    }
}
