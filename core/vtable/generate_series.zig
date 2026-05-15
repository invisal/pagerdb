// ── __tables ──────────────────────────────────────────────────────────────────
// Lists all user-defined tables in the database with their metadata.

const std = @import("std");
const catalog = @import("../catalog.zig");
const Catalog = catalog.Catalog;
const root = @import("root.zig");

pub const columns = [_]root.VTabColumn{
    .{ .name = "generate_series", .col_type = .int, .nullable = false },
};

const GenerateSeries = struct {
    cursor: i64,
    to: i64,
};

fn cursorNext(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]root.Value {
    const self: *GenerateSeries = @ptrCast(@alignCast(ptr));

    if (self.cursor >= self.to) return null;

    const vals = try alloc.alloc(root.Value, 1);
    vals[0] = .{ .int = self.cursor };
    self.cursor += 1;

    return vals;
}

pub fn open(alloc: std.mem.Allocator, _: *Catalog, args: []const root.Value) anyerror!root.VTabCursor {
    if (args.len < 1) return error.ArgumentMismatch;

    switch (args[0]) {
        .int => |n| {
            const cur = try alloc.create(GenerateSeries);
            cur.* = .{ .cursor = 0, .to = n };
            return .{ .ptr = cur, .next_fn = cursorNext };
        },
        else => return error.InvalidArgumentType,
    }
}
