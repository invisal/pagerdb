const std = @import("std");
const t = @import("../types.zig");
const Catalog = @import("../catalog.zig").Catalog;
const row_m = @import("../row.zig");

pub const Value = row_m.Value;

// ── VTabCursor ─────────────────────────────────────────────────────────────────

// An open cursor over a virtual table's rows.  The vtable allocates its cursor
// state through the arena allocator passed by the executor; that arena owns all
// cursor state and frees it in one shot, so no explicit close is needed.
pub const VTabCursor = struct {
    ptr: *anyopaque,
    next_fn: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]Value,

    pub fn next(self: *VTabCursor, alloc: std.mem.Allocator) anyerror!?[]Value {
        return self.next_fn(self.ptr, alloc);
    }
};

// Opens a cursor over the virtual table.  The returned VTabCursor owns its
// internal state and must be closed by the caller.
pub const OpenFn = *const fn (
    cat: *Catalog,
    args: []const Value,
    alloc: std.mem.Allocator,
) anyerror!VTabCursor;

pub const VTabColumn = struct {
    name: []const u8,
    col_type: t.ColType,
    nullable: bool,
};

pub const VTab = struct {
    schema: []const u8,
    name: []const u8,
    columns: []const VTabColumn,
    min_args: usize,
    max_args: usize,
    open: OpenFn,
};

// Import individual vtable implementations
const pages = @import("pages.zig");
const page_slots = @import("page_slots.zig");
const tables = @import("tables.zig");
const columns = @import("columns.zig");
const generate_series = @import("generate_series.zig");

// ── Registry ──────────────────────────────────────────────────────────────────

const REGISTRY = [_]VTab{
    .{
        .schema = "main",
        .name = "__pages",
        .columns = &pages.columns,
        .min_args = 0,
        .max_args = 0,
        .open = pages.open,
    },
    .{
        .schema = "main",
        .name = "__page_slots",
        .columns = &page_slots.columns,
        .min_args = 1,
        .max_args = 1,
        .open = page_slots.open,
    },
    .{
        .schema = "main",
        .name = "generate_series",
        .columns = &generate_series.columns,
        .min_args = 1,
        .max_args = 1,
        .open = generate_series.open,
    },
    .{
        .schema = "information_schema",
        .name = "tables",
        .columns = &tables.columns,
        .min_args = 0,
        .max_args = 0,
        .open = tables.open,
    },
    .{
        .schema = "information_schema",
        .name = "columns",
        .columns = &columns.columns,
        .min_args = 0,
        .max_args = 0,
        .open = columns.open,
    },
};

pub fn find(schema: []const u8, name: []const u8) ?*const VTab {
    for (&REGISTRY) |*vt| {
        if (std.mem.eql(u8, vt.name, name) and std.mem.eql(u8, vt.schema, schema)) return vt;
    }

    return null;
}
