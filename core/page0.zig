const std = @import("std");
const t = @import("types.zig");
const Pager = @import("pager/pager.zig").Pager;
const DiskPager = @import("pager/disk.zig").DiskPager;

pub fn writeHeader(pager: *Pager) !void {
    var buf = std.mem.zeroes([t.PAGE_SIZE]u8);

    const header = t.DbHeader{
        .magic = t.DB_MAGIC,
        .version_major = 1,
        .version_minor = 0,
        .page_size = t.PAGE_SIZE,
        .total_pages = pager.total_pages,
        .free_list_head = pager.free_list_head,
        .sys_tables_root = pager.sys_tables_root,
        .sys_columns_root = pager.sys_columns_root,
        ._reserved = std.mem.zeroes([36]u8),
    };

    @memcpy(buf[0..@sizeOf(t.DbHeader)], std.mem.asBytes(&header));
    try pager.writePage(0, &buf, &.{});
}

pub fn readHeader(pager: *Pager) !t.DbHeader {
    var buf: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(0, &buf);
    return std.mem.bytesToValue(t.DbHeader, buf[0..@sizeOf(t.DbHeader)]);
}

pub fn validateHeader(h: t.DbHeader) !void {
    if (h.magic != t.DB_MAGIC) return error.BadMagic;
    if (h.page_size != t.PAGE_SIZE) return error.BadPageSize;
    if (h.version_major != 1) return error.UnsupportedVersion;
}

const Dir = std.Io.Dir;

test "create and reopen preserves header" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/test_page0.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};

    {
        var pager = try DiskPager.create(alloc, io, path, .{});
        defer pager.close();
        try pager.flush();
    }
    {
        var pager = try DiskPager.open(alloc, io, path, .{});
        defer pager.close();
        const h = try readHeader(&pager);
        try validateHeader(h);
        try std.testing.expectEqual(h.magic, t.DB_MAGIC);
        try std.testing.expectEqual(h.sys_tables_root, 0);
        try std.testing.expectEqual(h.sys_columns_root, 0);
    }
}

test "catalog roots round-trip through header" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const path = "/tmp/test_page0_roots.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};

    {
        var pager = try DiskPager.create(alloc, io, path, .{});
        defer pager.close();
        pager.sys_tables_root = 1;
        pager.sys_columns_root = 2;
        try writeHeader(&pager);
        try pager.flush();
    }
    {
        var pager = try DiskPager.open(alloc, io, path, .{});
        defer pager.close();
        try std.testing.expectEqual(pager.sys_tables_root, 1);
        try std.testing.expectEqual(pager.sys_columns_root, 2);
    }
}

test "bad magic returns error" {
    const bad = t.DbHeader{
        .magic = 0xDEADBEEF,
        .version_major = 1,
        .version_minor = 0,
        .page_size = t.PAGE_SIZE,
        .total_pages = 1,
        .free_list_head = 0,
        .sys_tables_root = 0,
        .sys_columns_root = 0,
        ._reserved = std.mem.zeroes([36]u8),
    };
    try std.testing.expectError(error.BadMagic, validateHeader(bad));
}
