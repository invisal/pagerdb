const std = @import("std");
const db_mod = @import("../db.zig");
const row_mod = @import("../row.zig");
const lp = @import("logical_plan.zig");
const pp = @import("physical_plan.zig");
const eval = @import("eval.zig");

const Db = db_mod.Db;
const Allocator = std.mem.Allocator;

pub const BATCH_SIZE: usize = 64;

pub const Row = struct {
    rowid: u64,
    values: []row_mod.Value,
};

// ── Leaf cursors ───────────────────────────────────────────────────────────────

// Walks a real table via DbRowIterator, returning up to BATCH_SIZE rows per
// call.  The btree page buffer lives inside DbRowIterator so there is no
// additional heap allocation per batch beyond the Row slice itself.
pub const SeqScanCursor = struct {
    it: Db.DbRowIterator,

    pub fn next(self: *SeqScanCursor, a: Allocator) !?[]Row {
        var buf = try a.alloc(Row, BATCH_SIZE);
        var n: usize = 0;
        while (n < BATCH_SIZE) {
            const hit = try self.it.next(a) orelse break;
            buf[n] = .{ .rowid = hit.rowid, .values = hit.values };
            n += 1;
        }
        if (n == 0) return null;
        return buf[0..n];
    }
};

// Virtual tables materialise all rows at once on open.  We buffer the full
// result and return it in BATCH_SIZE chunks so the calling loop is uniform.
pub const VTabScanCursor = struct {
    rows: [][]row_mod.Value,
    index: usize,

    pub fn next(self: *VTabScanCursor, a: Allocator) !?[]Row {
        if (self.index >= self.rows.len) return null;
        const start = self.index;
        const end = @min(self.index + BATCH_SIZE, self.rows.len);
        const buf = try a.alloc(Row, end - start);
        for (self.rows[start..end], 0..) |vals, i| {
            // rowids are 1-indexed to match the executor convention
            buf[i] = .{ .rowid = @intCast(start + i + 1), .values = vals };
        }
        self.index = end;
        return buf;
    }
};

// Point lookups fetch exactly one row (or nothing) from the btree.
// We return it as a 1-element batch so the calling loop stays uniform.
pub const PointLookupCursor = struct {
    row: ?Row,

    pub fn next(self: *PointLookupCursor, a: Allocator) !?[]Row {
        const r = self.row orelse return null;
        self.row = null;
        const buf = try a.alloc(Row, 1);
        buf[0] = r;
        return buf;
    }
};

// ── Intermediate cursors ───────────────────────────────────────────────────────

pub const FilterCursor = struct {
    input: *Cursor,
    predicate: lp.Expr,

    // Pull batches from the input and return only the rows that pass the
    // predicate.  We keep pulling until we have at least one match or the
    // input is exhausted, so callers never receive an empty non-null slice.
    pub fn next(self: *FilterCursor, a: Allocator) !?[]Row {
        var out: std.ArrayList(Row) = .empty;
        while (out.items.len == 0) {
            const batch = try self.input.next(a) orelse return null;
            for (batch) |r| {
                const ev = try eval.evalExpr(self.predicate, r.values, a);
                if (eval.isTruthy(ev)) try out.append(a, r);
            }
        }
        return out.items;
    }

    pub fn deinit(self: *FilterCursor, a: Allocator) void {
        self.input.deinit(a);
        a.destroy(self.input);
    }
};

pub const ProjectCursor = struct {
    input: *Cursor,
    col_indices: []usize,

    pub fn next(self: *ProjectCursor, a: Allocator) !?[]Row {
        const batch = try self.input.next(a) orelse return null;
        const out = try a.alloc(Row, batch.len);
        for (batch, 0..) |r, i| {
            const projected = try a.alloc(row_mod.Value, self.col_indices.len);
            for (self.col_indices, 0..) |idx, j| projected[j] = r.values[idx];
            out[i] = .{ .rowid = r.rowid, .values = projected };
        }
        return out;
    }

    pub fn deinit(self: *ProjectCursor, a: Allocator) void {
        self.input.deinit(a);
        a.destroy(self.input);
    }
};

// ── Cursor union ───────────────────────────────────────────────────────────────

pub const Cursor = union(enum) {
    seq_scan: SeqScanCursor,
    vtab_scan: VTabScanCursor,
    point_lookup: PointLookupCursor,
    filter: *FilterCursor,
    project: *ProjectCursor,

    pub fn open(plan: pp.PhysicalPlan, db: *Db, a: Allocator) !Cursor {
        return switch (plan) {
            .seq_scan => |n| .{ .seq_scan = .{ .it = try db.scanOpen(n.table) } },
            .vtab_scan => |n| blk: {
                var raw: std.ArrayList([]row_mod.Value) = .empty;
                try n.vtab.scan(&db.cat, n.args, &raw, a);
                break :blk .{ .vtab_scan = .{
                    .rows = try raw.toOwnedSlice(a),
                    .index = 0,
                } };
            },
            .point_lookup => |n| blk: {
                const vals = try db.getByRowid(n.table, n.rowid, a);
                const r: ?Row = if (vals) |v| .{ .rowid = n.rowid, .values = v } else null;
                break :blk .{ .point_lookup = .{ .row = r } };
            },
            .filter => |n| blk: {
                const fc = try a.create(FilterCursor);
                fc.input = try a.create(Cursor);
                fc.input.* = try open(n.input, db, a);
                fc.predicate = n.predicate;
                break :blk .{ .filter = fc };
            },
            .project => |n| blk: {
                const pc = try a.create(ProjectCursor);
                pc.input = try a.create(Cursor);
                pc.input.* = try open(n.input, db, a);
                pc.col_indices = n.col_indices;
                break :blk .{ .project = pc };
            },
            else => error.UnsupportedPlan,
        };
    }

    pub fn next(self: *Cursor, a: Allocator) !?[]Row {
        return switch (self.*) {
            .seq_scan => |*s| s.next(a),
            .vtab_scan => |*s| s.next(a),
            .point_lookup => |*s| s.next(a),
            .filter => |f| f.next(a),
            .project => |p| p.next(a),
        };
    }

    pub fn deinit(self: *Cursor, a: Allocator) void {
        switch (self.*) {
            .filter => |f| f.deinit(a),
            .project => |p| p.deinit(a),
            else => {},
        }
    }
};
