const std = @import("std");
const t = @import("../types.zig");
const btree = @import("../btree.zig");
const DiskPager = @import("../pager/disk.zig").DiskPager;
const PageWriter = @import("../page_writer.zig").PageWriter;

const Dir = std.Io.Dir;

test "scan returns rows in rowid order" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/test_btree_scan_order.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};

    var pager = try DiskPager.create(alloc, io, path, .{});
    defer pager.close();

    const root_id = try pager.allocPage();
    var root_pw = PageWriter.init(&pager, root_id);
    btree.initLeafPage(&root_pw, true);
    try root_pw.commit();

    const row = [_]u8{0x01};
    for ([_]u64{ 10, 5, 20, 1 }) |rowid| {
        try btree.insert(&pager, root_id, rowid, &row, true);
    }

    var it = try btree.ScanIterator.init(&pager, root_id);
    const expected = [_]u64{ 1, 5, 10, 20 };
    for (expected) |exp| {
        const cell = try it.next();
        try std.testing.expect(cell != null);
        try std.testing.expectEqual(cell.?.rowid, exp);
    }
    try std.testing.expect(try it.next() == null);
}

test "delete existing row" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/test_btree_delete_row.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};

    var pager = try DiskPager.create(alloc, io, path, .{});
    defer pager.close();

    const root_id = try pager.allocPage();
    var root_pw = PageWriter.init(&pager, root_id);
    btree.initLeafPage(&root_pw, true);
    try root_pw.commit();

    const row = [_]u8{0x01};
    for (1..11) |i| {
        try btree.insert(&pager, root_id, @intCast(i), &row, true);
    }

    try std.testing.expect(try btree.delete(&pager, root_id, 5));

    var buf: [t.PAGE_SIZE]u8 = undefined;
    try std.testing.expect(try btree.lookup(&pager, root_id, 5, &buf) == null);

    var count: usize = 0;
    var it = try btree.ScanIterator.init(&pager, root_id);
    while (try it.next()) |_| count += 1;
    try std.testing.expectEqual(count, 9);
}

test "delete non-existent row returns false" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/test_btree_delete_nonexist.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};

    var pager = try DiskPager.create(alloc, io, path, .{});
    defer pager.close();

    const root_id = try pager.allocPage();
    var root_pw = PageWriter.init(&pager, root_id);
    btree.initLeafPage(&root_pw, true);
    try root_pw.commit();

    const row = [_]u8{0x01};
    try btree.insert(&pager, root_id, 1, &row, true);

    try std.testing.expect(!try btree.delete(&pager, root_id, 99));
}

test "delete all rows in a page frees the page" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/test_btree_delete_freepage.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};

    var pager = try DiskPager.create(alloc, io, path, .{});
    defer pager.close();

    const root_id = try pager.allocPage();
    var root_pw = PageWriter.init(&pager, root_id);
    btree.initLeafPage(&root_pw, true);
    try root_pw.commit();

    var row: [200]u8 = undefined;
    @memset(&row, 0);
    for (1..51) |i| {
        try btree.insert(&pager, root_id, @intCast(i), &row, true);
    }

    const free_before = pager.free_list_head;

    for (1..51) |i| {
        _ = try btree.delete(&pager, root_id, @intCast(i));
    }

    try std.testing.expect(pager.free_list_head != free_before);

    var count: usize = 0;
    var it = try btree.ScanIterator.init(&pager, root_id);
    while (try it.next()) |_| count += 1;
    try std.testing.expectEqual(count, 0);
}

test "insert and lookup large row via btree" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/test_btree_overflow.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};

    var pager = try DiskPager.create(alloc, io, path, .{});
    defer pager.close();

    const root_id = try pager.allocPage();
    var root_pw = PageWriter.init(&pager, root_id);
    btree.initLeafPage(&root_pw, true);
    try root_pw.commit();

    const big_row = try alloc.alloc(u8, 5000);
    defer alloc.free(big_row);
    for (big_row, 0..) |*b, i| b.* = @intCast(i % 256);

    try btree.insert(&pager, root_id, 42, big_row, true);

    const result = try btree.lookupRow(&pager, root_id, 42, alloc);
    defer if (result) |r| alloc.free(r);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, big_row, result.?);
}

test "delete overflowed row frees overflow chain" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/test_btree_overflow_delete.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};

    var pager = try DiskPager.create(alloc, io, path, .{});
    defer pager.close();

    const root_id = try pager.allocPage();
    var root_pw = PageWriter.init(&pager, root_id);
    btree.initLeafPage(&root_pw, true);
    try root_pw.commit();

    const big_row = try alloc.alloc(u8, 5000);
    defer alloc.free(big_row);
    @memset(big_row, 0xCC);

    try btree.insert(&pager, root_id, 7, big_row, true);
    const free_before = pager.free_list_head;

    try std.testing.expect(try btree.delete(&pager, root_id, 7));
    try std.testing.expect(pager.free_list_head != free_before);

    var buf: [t.PAGE_SIZE]u8 = undefined;
    try std.testing.expect(try btree.lookup(&pager, root_id, 7, &buf) == null);
}
