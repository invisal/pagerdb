// This is vtable for information_schema.columns
const std = @import("std");
const catalog = @import("../catalog.zig");
const Catalog = catalog.Catalog;
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

// Iterates table-by-table, column-by-column.  current_meta tracks which table
// we are currently emitting columns for; col_idx advances within that table.
const ColumnsCursor = struct {
    it: std.StringHashMap(catalog.TableMeta).ValueIterator,
    current_meta: ?*catalog.TableMeta,
    col_idx: usize,
};

fn cursorNext(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]root.Value {
    const self: *ColumnsCursor = @ptrCast(@alignCast(ptr));

    // Advance to the next (table, column) pair.
    while (true) {
        if (self.current_meta) |meta| {
            if (self.col_idx < meta.columns.len) {
                const column = meta.columns[self.col_idx];
                self.col_idx += 1;

                const vals = try alloc.alloc(root.Value, columns.len);
                vals[C.TABLE_CATALOG] = .{ .text = try alloc.dupe(u8, "def") };
                vals[C.TABLE_SCHEMA] = .{ .text = try alloc.dupe(u8, "main") };
                vals[C.TABLE_NAME] = .{ .text = try alloc.dupe(u8, meta.name) };
                vals[C.COLUMN_NAME] = .{ .text = try alloc.dupe(u8, column.name) };
                vals[C.ORDINAL_POSITION] = .{ .int = column.attnum };
                vals[C.COLUMN_DEFAULT] = if (column.default_src) |src|
                    .{ .text = try alloc.dupe(u8, src) }
                else
                    .{ .null = {} };
                vals[C.IS_NULLABLE] = .{ .text = if (column.nullable) try alloc.dupe(u8, "YES") else try alloc.dupe(u8, "NO") };
                vals[C.DATA_TYPE] = .{ .text = column.col_type.name() };
                return vals;
            }
        }
        // Move to the next table.
        self.current_meta = self.it.next();
        if (self.current_meta == null) return null;
        self.col_idx = 0;
    }
}

pub fn open(cat: *Catalog, args: []const i64, alloc: std.mem.Allocator) anyerror!root.VTabCursor {
    _ = args;
    const cur = try alloc.create(ColumnsCursor);
    cur.* = .{ .it = cat.tables.valueIterator(), .current_meta = null, .col_idx = 0 };
    return .{ .ptr = cur, .next_fn = cursorNext };
}
