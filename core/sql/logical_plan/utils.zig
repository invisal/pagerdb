const std = @import("std");
const catalog = @import("../../catalog.zig");
const Pager = @import("../../pager/pager.zig").Pager;
const DiskPager = @import("../../pager/disk.zig").DiskPager;
const InMemoryPager = @import("../../pager/memory.zig").InMemoryPager;
const Parser = @import("../parser.zig").Parser;

pub const Dir = std.Io.Dir;

pub const DbHandle = struct {
    pager: *Pager,
    cat: catalog.Catalog,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *DbHandle) void {
        self.pager.flush() catch {};
        self.pager.close();
        self.alloc.destroy(self.pager);
        self.cat.deinit();
    }
};

pub fn makeDb(
    io: std.Io,
    path: []const u8,
    alloc: std.mem.Allocator,
) !DbHandle {
    const pager = try alloc.create(Pager);
    errdefer alloc.destroy(pager);
    pager.* = try DiskPager.create(alloc, io, path);
    var cat = catalog.Catalog.init(alloc, pager);
    try cat.bootstrap();
    return .{ .pager = pager, .cat = cat, .alloc = alloc };
}

/// Creates an in-memory catalog from SQL CREATE TABLE statements.
/// Each SQL statement should be a CREATE TABLE statement.
///
/// Example:
///   var cat = try makeCatalog(alloc, &.{
///       "CREATE TABLE t (name TEXT, score INT)",
///       "CREATE TABLE users (id INT, email TEXT)",
///   });
///   defer cat.deinit();
pub fn makeCatalog(
    alloc: std.mem.Allocator,
    sql_statements: []const []const u8,
) !CatalogHandle {
    const pager = try alloc.create(Pager);
    errdefer alloc.destroy(pager);
    pager.* = try InMemoryPager.create(alloc);

    var cat = catalog.Catalog.init(alloc, pager);
    try cat.bootstrap();

    // Use a temporary arena for parsing SQL and building column metadata.
    // This keeps the parsing temporary data separate from the catalog's arena.
    var tmp_arena = std.heap.ArenaAllocator.init(alloc);
    defer tmp_arena.deinit();
    const tmp = tmp_arena.allocator();

    for (sql_statements) |sql| {
        var parsed = try Parser.parse(sql, tmp);
        defer parsed.deinit();

        switch (parsed.stmt) {
            .create_table => |stmt| {
                const cols = try tmp.alloc(catalog.ColumnMeta, stmt.columns.len);
                for (stmt.columns, 0..) |col_def, i| {
                    cols[i] = .{
                        .name = col_def.name,
                        .col_type = col_def.col_type,
                        .nullable = col_def.nullable,
                        .default_expr = col_def.default_expr,
                        .default_src = col_def.default_src,
                    };
                }
                _ = try cat.createTable(stmt.table, cols);
            },
            else => return error.NotCreateTableStatement,
        }
    }

    return CatalogHandle{
        .pager = pager,
        .cat = cat,
        .alloc = alloc,
    };
}

/// Handle for an in-memory catalog created by makeCatalog.
/// Call deinit() to clean up resources.
pub const CatalogHandle = struct {
    pager: *Pager,
    cat: catalog.Catalog,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *CatalogHandle) void {
        self.pager.close();
        self.alloc.destroy(self.pager);
        self.cat.deinit();
    }
};
