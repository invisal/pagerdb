const std = @import("std");
const t = @import("../types.zig");
const Catalog = @import("../catalog.zig").Catalog;
const row_m = @import("../row.zig");

pub const Value = row_m.Value;

pub const ScanFn = *const fn (
    cat: *Catalog,
    args: []const i64,
    out: *std.ArrayList([]Value),
    alloc: std.mem.Allocator,
) anyerror!void;

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
    scan: ScanFn,
};

// Import individual vtable implementations
const pages = @import("pages.zig");
const page_slots = @import("page_slots.zig");
const tables = @import("tables.zig");

// ── Registry ──────────────────────────────────────────────────────────────────

const REGISTRY = [_]VTab{
    .{
        .schema = "main",
        .name = "__pages",
        .columns = &pages.columns,
        .min_args = 0,
        .max_args = 0,
        .scan = pages.scan,
    },
    .{
        .schema = "main",
        .name = "__page_slots",
        .columns = &page_slots.columns,
        .min_args = 1,
        .max_args = 1,
        .scan = page_slots.scan,
    },
    .{
        .schema = "information_schema",
        .name = "tables",
        .columns = &tables.columns,
        .min_args = 0,
        .max_args = 0,
        .scan = tables.scan,
    },
};

pub fn find(schema: []const u8, name: []const u8) ?*const VTab {
    for (&REGISTRY) |*vt| {
        if (std.mem.eql(u8, vt.name, name) and std.mem.eql(u8, vt.schema, schema)) return vt;
    }

    return null;
}
