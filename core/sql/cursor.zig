const std = @import("std");
const db_mod = @import("../db.zig");
const row_mod = @import("../row.zig");
const lp = @import("logical_plan.zig");
const pp = @import("physical_plan.zig");
const eval = @import("eval.zig");
const vtab_mod = @import("../vtable/root.zig");

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

// Virtual table cursor: pulls one row at a time from the vtable's own cursor
// and accumulates up to BATCH_SIZE rows per call so the outer loop is uniform.
pub const VTabScanCursor = struct {
    cursor: vtab_mod.VTabCursor,
    // 1-indexed rowid, incremented for every row returned across all batches
    rowid: u64,

    pub fn next(self: *VTabScanCursor, a: Allocator) !?[]Row {
        var buf: std.ArrayListUnmanaged(Row) = .empty;
        while (buf.items.len < BATCH_SIZE) {
            const vals = try self.cursor.next(a) orelse break;
            try buf.append(a, .{ .rowid = self.rowid, .values = vals });
            self.rowid += 1;
        }
        if (buf.items.len == 0) return null;
        return buf.items;
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

// ── Join cursor ────────────────────────────────────────────────────────────────

// Nested-loop inner join with a materialized right side.
// On open(), all right-side rows are collected into a slice so that for each
// left row we can iterate the right side without re-opening the right cursor.
// This is simple and correct; hash join can be added later as an optimisation.
pub const JoinCursor = struct {
    left: *Cursor,
    right_rows: []Row, // all right rows, materialized at open time
    right_pos: usize, // current position within right_rows for this left row
    left_batch: []Row, // current batch pulled from left cursor
    left_pos: usize, // position within left_batch
    condition: lp.Expr,

    // Pull combined (left ++ right) rows that satisfy the join condition.
    // Returns up to BATCH_SIZE rows per call, or null when exhausted.
    pub fn next(self: *JoinCursor, a: Allocator) !?[]Row {
        var out: std.ArrayList(Row) = .empty;

        while (true) {
            // Advance to the next left row when the current one is exhausted.
            while (self.left_pos >= self.left_batch.len) {
                self.left_batch = try self.left.next(a) orelse {
                    if (out.items.len > 0) return out.items;
                    return null;
                };
                self.left_pos = 0;
                self.right_pos = 0;
            }

            const left_row = self.left_batch[self.left_pos];

            // Walk the right side for the current left row.
            while (self.right_pos < self.right_rows.len) {
                const right_row = self.right_rows[self.right_pos];
                self.right_pos += 1;

                // Build a combined values slice: left_vals ++ right_vals.
                // col_idx values in the condition already reference merged positions.
                const combined = try a.alloc(row_mod.Value, left_row.values.len + right_row.values.len);
                @memcpy(combined[0..left_row.values.len], left_row.values);
                @memcpy(combined[left_row.values.len..], right_row.values);

                const ev = try eval.evalExpr(self.condition, combined, a);
                if (eval.isTruthy(ev)) {
                    try out.append(a, .{ .rowid = left_row.rowid, .values = combined });
                }

                if (out.items.len >= BATCH_SIZE) return out.items;
            }

            // Finished right side for this left row; move to the next left row.
            self.left_pos += 1;
            self.right_pos = 0;

            // Return any accumulated rows rather than looping back to the left,
            // to avoid unbounded iteration when most left rows have no matches.
            if (out.items.len > 0) return out.items;
        }
    }

    pub fn deinit(self: *JoinCursor, a: Allocator) void {
        self.left.deinit(a);
        a.destroy(self.left);
    }
};

// ── Cursor union ───────────────────────────────────────────────────────────────

pub const Cursor = union(enum) {
    seq_scan: SeqScanCursor,
    vtab_scan: VTabScanCursor,
    point_lookup: PointLookupCursor,
    filter: *FilterCursor,
    project: *ProjectCursor,
    join: *JoinCursor,

    pub fn open(plan: pp.PhysicalPlan, db: *Db, a: Allocator) !Cursor {
        return switch (plan) {
            .seq_scan => |n| .{ .seq_scan = .{ .it = try db.scanOpen(n.table) } },
            .vtab_scan => |n| blk: {
                const vtab_cursor = try n.vtab.open(&db.cat, n.args, a);
                break :blk .{ .vtab_scan = .{ .cursor = vtab_cursor, .rowid = 1 } };
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
            .join => |n| blk: {
                // Materialize the right side once so each left row can scan it
                // without re-opening a cursor.
                var right_rows: std.ArrayList(Row) = .empty;
                var right_cur = try open(n.right, db, a);
                defer right_cur.deinit(a);
                while (try right_cur.next(a)) |batch| {
                    try right_rows.appendSlice(a, batch);
                }
                const jc = try a.create(JoinCursor);
                jc.left = try a.create(Cursor);
                jc.left.* = try open(n.left, db, a);
                jc.right_rows = try right_rows.toOwnedSlice(a);
                jc.right_pos = 0;
                jc.left_batch = &.{};
                jc.left_pos = 0;
                jc.condition = n.condition;
                break :blk .{ .join = jc };
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
            .join => |j| j.next(a),
        };
    }

    pub fn deinit(self: *Cursor, a: Allocator) void {
        switch (self.*) {
            .filter => |f| f.deinit(a),
            .project => |p| p.deinit(a),
            .join => |j| j.deinit(a),
            else => {},
        }
    }
};
