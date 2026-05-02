const std = @import("std");
const DiskPager = @import("../pager/disk.zig").DiskPager;
const catalog = @import("../catalog.zig");

const Catalog = catalog.Catalog;
const ColumnMeta = catalog.ColumnMeta;
const Dir = std.Io.Dir;

test "fresh database has no pages beyond header" {
    const io = std.testing.io;
    const path = "/tmp/test_catalog_fresh.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var pager = try DiskPager.create(alloc, io, path);
    var cat = Catalog.init(alloc, &pager);
    try cat.bootstrap();
    try pager.flush();
    pager.close();
    cat.deinit();

    var pager2 = try DiskPager.open(alloc, io, path);
    defer pager2.close();
    try std.testing.expectEqual(pager2.total_pages, 1);
    try std.testing.expectEqual(pager2.sys_tables_root, 0);
    try std.testing.expectEqual(pager2.sys_columns_root, 0);
}

test "createTable allocates catalog roots lazily" {
    const io = std.testing.io;
    const path = "/tmp/test_catalog_lazy.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var tables_root: u32 = 0;
    var columns_root: u32 = 0;

    {
        var pager = try DiskPager.create(alloc, io, path);
        var cat = Catalog.init(alloc, &pager);
        try cat.bootstrap();

        _ = try cat.createTable("users", &.{
            .{ .name = "id", .col_type = .int, .nullable = false, .default_src = null, .default_expr = null },
        });

        tables_root = pager.sys_tables_root;
        columns_root = pager.sys_columns_root;
        try std.testing.expect(tables_root != 0);
        try std.testing.expect(columns_root != 0);

        try pager.flush();
        pager.close();
        cat.deinit();
    }
    {
        var pager = try DiskPager.open(alloc, io, path);
        var cat = Catalog.init(alloc, &pager);
        try cat.load();
        defer {
            pager.close();
            cat.deinit();
        }

        try std.testing.expectEqual(pager.sys_tables_root, tables_root);
        try std.testing.expectEqual(pager.sys_columns_root, columns_root);
        try std.testing.expect(cat.getTable("users") != null);
    }
}

test "createTable persists across reopen" {
    const io = std.testing.io;
    const path = "/tmp/test_catalog_create.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const cols = [_]ColumnMeta{
        .{ .name = "id", .col_type = .int, .nullable = false, .default_src = null, .default_expr = null },
        .{ .name = "name", .col_type = .text, .nullable = true, .default_src = null, .default_expr = null },
    };

    {
        var pager = try DiskPager.create(alloc, io, path);
        var cat = Catalog.init(alloc, &pager);
        try cat.bootstrap();
        _ = try cat.createTable("users", &cols);
        try pager.flush();
        pager.close();
        cat.deinit();
    }
    {
        var pager = try DiskPager.open(alloc, io, path);
        var cat = Catalog.init(alloc, &pager);
        try cat.load();
        defer {
            pager.close();
            cat.deinit();
        }

        const t_meta = cat.getTable("users");
        try std.testing.expect(t_meta != null);
        try std.testing.expectEqual(t_meta.?.columns.len, 2);
        try std.testing.expectEqualStrings(t_meta.?.columns[0].name, "id");
        try std.testing.expectEqualStrings(t_meta.?.columns[1].name, "name");
    }
}

test "next_table_id increments correctly across multiple tables" {
    const io = std.testing.io;
    const path = "/tmp/test_catalog_ids.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    const col = [_]ColumnMeta{.{ .name = "x", .col_type = .int, .nullable = false, .default_src = null, .default_expr = null }};

    {
        var pager = try DiskPager.create(alloc, io, path);
        var cat = Catalog.init(alloc, &pager);
        try cat.bootstrap();
        const a = try cat.createTable("a", &col);
        const b = try cat.createTable("b", &col);
        try std.testing.expectEqual(a.id, 1);
        try std.testing.expectEqual(b.id, 2);
        try pager.flush();
        pager.close();
        cat.deinit();
    }
    {
        var pager = try DiskPager.open(alloc, io, path);
        var cat = Catalog.init(alloc, &pager);
        try cat.load();
        defer {
            pager.close();
            cat.deinit();
        }

        try std.testing.expectEqual(cat.next_table_id, 3);
        const c_table = try cat.createTable("c", &col);
        try std.testing.expectEqual(c_table.id, 3);
    }
}

test "duplicate table name returns error" {
    const io = std.testing.io;
    const path = "/tmp/test_catalog_dup.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var pager = try DiskPager.create(alloc, io, path);
    var cat = Catalog.init(alloc, &pager);
    defer {
        pager.close();
        cat.deinit();
    }
    try cat.bootstrap();

    const cols = [_]ColumnMeta{
        .{ .name = "x", .col_type = .int, .nullable = false, .default_src = null, .default_expr = null },
    };
    _ = try cat.createTable("foo", &cols);
    try std.testing.expectError(error.TableAlreadyExists, cat.createTable("foo", &cols));
}
