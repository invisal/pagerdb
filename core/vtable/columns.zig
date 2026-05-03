// This is vtable for information_schema.columns
const std = @import("std");
const Catalog = @import("../catalog.zig").Catalog;
const root = @import("root.zig");

pub const columns = [_]root.VTabColumn{
    .{ .name = "TABLE_CATALOG", .col_type = .text, .nullable = false },
    .{ .name = "TABLE_SCHEMA", .col_type = .text, .nullable = false },
    .{ .name = "TABLE_NAME", .col_type = .text, .nullable = false },
    .{ .name = "COLUMN_NAME", .col_type = .text, .nullable = false },
    .{ .name = "ORDINAL_POSITION", .col_type = .int, .nullable = false },
    .{ .name = "COLUMN_DEFAULT", .col_type = .text, .nullable = true },
    .{ .name = "IS_NULLABLE", .col_type = .text, .nullable = false },
    .{ .name = "DATA_TYPE", .col_type = .text, .nullable = false },
};

const C = struct {
    const TABLE_CATALOG: usize = 0;
    const TABLE_SCHEMA: usize = 1;
    const TABLE_NAME: usize = 2;
    const COLUMN_NAME: usize = 3;
    const ORDINAL_POSITION: usize = 4;
    const COLUMN_DEFAULT: usize = 5;
    const IS_NULLABLE: usize = 6;
    const DATA_TYPE: usize = 7;
};

pub fn scan(
    cat: *Catalog,
    args: []const i64,
    out: *std.ArrayList([]root.Value),
    alloc: std.mem.Allocator,
) anyerror!void {
    _ = args;
    var it = cat.tables.valueIterator();
    while (it.next()) |meta| {
        for (meta.columns) |column| {
            const vals = try alloc.alloc(root.Value, columns.len);
            vals[C.TABLE_CATALOG] = .{ .text = try alloc.dupe(u8, "def") };
            vals[C.TABLE_SCHEMA] = .{ .text = try alloc.dupe(u8, "main") };
            vals[C.TABLE_NAME] = .{ .text = try alloc.dupe(u8, meta.name) };
            vals[C.COLUMN_NAME] = .{ .text = try alloc.dupe(u8, column.name) };
            vals[C.COLUMN_DEFAULT] = if (column.default_src) |src| .{ .text = try alloc.dupe(u8, src) } else .{ .null = {} };
            vals[C.ORDINAL_POSITION] = .{ .int = column.attnum };
            vals[C.IS_NULLABLE] = .{ .text = if (column.nullable) try alloc.dupe(u8, "YES") else try alloc.dupe(u8, "NO") };
            vals[C.DATA_TYPE] = .{ .text = column.col_type.name() };
            try out.append(alloc, vals);
        }
    }
}
