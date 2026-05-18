const std = @import("std");
const t = @import("types.zig");
const Pager = @import("pager/pager.zig").Pager;
const PageWriter = @import("page_writer.zig").PageWriter;
const DiskPager = @import("pager/disk.zig").DiskPager;
const DiskIo = @import("io/disk_io.zig").DiskIo;

// DbHeader is stored after the PageHeader so page0 participates in the normal
// WAL delta path: PageWriter stamps an LSN into PageHeader, and recovery uses
// the same LSN check as every other page.  Offset is a compile-time constant
// so both read and write always agree on the layout.
const DB_HEADER_OFFSET: u16 = @sizeOf(t.PageHeader);

pub fn writeHeader(pager: *Pager) !void {
    const header = t.DbHeader{
        .magic = t.DB_MAGIC,
        .version_major = 1,
        .version_minor = 0,
        .page_size = t.PAGE_SIZE,
        .total_pages = pager.total_pages,
        .free_list_head = pager.free_list_head,
        .sys_tables_root = pager.sys_tables_root,
        .sys_columns_root = pager.sys_columns_root,
        .sys_indexes_root = pager.sys_indexes_root,
        .sys_index_cols_root = pager.sys_index_cols_root,
        .sys_views_root = pager.sys_views_root,
        ._reserved = std.mem.zeroes([24]u8),
    };

    var pw = try PageWriter.open(pager, 0);
    pw.writeAt(DB_HEADER_OFFSET, std.mem.asBytes(&header));
    try pw.commit();
}

pub fn readHeader(pager: *Pager) !t.DbHeader {
    var buf: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(0, &buf);
    return std.mem.bytesToValue(t.DbHeader, buf[DB_HEADER_OFFSET..][0..@sizeOf(t.DbHeader)]);
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
    defer Dir.deleteFile(.cwd(), io, path ++ ".wal") catch {};

    {
        var disk_io = DiskIo.init(alloc, io);
        var pager = try DiskPager.create(alloc, disk_io.io(), path, .{});
        defer pager.close();
        try pager.flush();
    }
    {
        var disk_io = DiskIo.init(alloc, io);
        var pager = try DiskPager.open(alloc, disk_io.io(), path, .{});
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
    defer Dir.deleteFile(.cwd(), io, path ++ ".wal") catch {};

    {
        var disk_io = DiskIo.init(alloc, io);
        var pager = try DiskPager.create(alloc, disk_io.io(), path, .{});
        defer pager.close();
        pager.sys_tables_root = 1;
        pager.sys_columns_root = 2;
        try writeHeader(&pager);
        try pager.flush();
    }
    {
        var disk_io = DiskIo.init(alloc, io);
        var pager = try DiskPager.open(alloc, disk_io.io(), path, .{});
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
        .sys_indexes_root = 0,
        .sys_index_cols_root = 0,
        .sys_views_root = 0,
        ._reserved = std.mem.zeroes([24]u8),
    };
    try std.testing.expectError(error.BadMagic, validateHeader(bad));
}
