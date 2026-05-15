const std = @import("std");
const db_mod = @import("../db.zig");
const row_mod = @import("../row.zig");
const lp = @import("../sql/logical_plan.zig");
const pp = @import("../sql/physical_plan.zig");
const eval = @import("../sql/eval.zig");
const vtab_mod = @import("../vtable/root.zig");
const agg_mod = @import("agg_func.zig");

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
            // Append __rowid, __pageid, __slotid as the last three values so
            // they align with the synthetic SchemaCol entries injected by buildSchema.
            const vals = try a.alloc(row_mod.Value, hit.values.len + 3);
            @memcpy(vals[0..hit.values.len], hit.values);
            vals[hit.values.len] = .{ .int = @intCast(hit.rowid) };
            vals[hit.values.len + 1] = .{ .int = @intCast(hit.page_id) };
            vals[hit.values.len + 2] = .{ .int = @intCast(hit.slot_id) };
            buf[n] = .{ .rowid = hit.rowid, .values = vals };
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

// Produces exactly one empty row for SELECT without FROM.
// The projection layer above evaluates expressions against this row.
pub const ConstantScanCursor = struct {
    first: bool = true,

    pub fn next(self: *ConstantScanCursor, a: Allocator) !?[]Row {
        if (!self.first) return null;
        self.first = false;
        const t = try a.alloc(Row, 1);
        t[0] = .{ .rowid = 0, .values = try a.alloc(row_mod.Value, 0) };
        return t;
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
    exprs: []lp.Expr,

    pub fn next(self: *ProjectCursor, a: Allocator) !?[]Row {
        const batch = try self.input.next(a) orelse return null;
        const out = try a.alloc(Row, batch.len);
        for (batch, 0..) |r, i| {
            const projected = try a.alloc(row_mod.Value, self.exprs.len);
            for (self.exprs, 0..) |expr, j| {
                const v = try eval.evalExpr(expr, r.values, a);
                projected[j] = evalValueToRowValue(v);
            }
            out[i] = .{ .rowid = r.rowid, .values = projected };
        }
        return out;
    }

    pub fn deinit(self: *ProjectCursor, a: Allocator) void {
        self.input.deinit(a);
        a.destroy(self.input);
    }
};

// AggSpec pairs a resolved aggregate function (pointer into agg_mod.REGISTRY)
// with the column it operates on.  col_idx == null means COUNT(*).
// This is an alias for the type defined in the logical plan so the same
// struct flows unchanged from planning through physical execution.
pub const AggSpec = lp.AggCallSpec;

const GroupState = struct {
    key_values: []row_mod.Value,
    acc_states: []*anyopaque,
};

fn hashGroupRow(values: []const row_mod.Value, group_by: []const usize) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, group_by.len);
    for (group_by) |col_idx| {
        values[col_idx].hashInto(&hasher);
    }
    return hasher.final();
}

fn groupKeyMatches(key_values: []const row_mod.Value, row_values: []const row_mod.Value, group_by: []const usize) bool {
    if (key_values.len != group_by.len) return false;
    for (group_by, 0..) |col_idx, i| {
        if (!row_mod.Value.eql(key_values[i], row_values[col_idx])) return false;
    }
    return true;
}

// Aggregate cursor: blocking — consumes all input before emitting any output.
// For each group (defined by group_by column indices) it maintains one state
// per AggSpec, allocated from the arena passed to next().
pub const AggregateCursor = struct {
    input: *Cursor,
    agg_specs: []const AggSpec,
    group_by: []const usize, // column indices; empty = single global group
    result: ?[]Row, // materialized output, null until first next() call
    pos: usize, // next unread position within result

    pub fn next(self: *AggregateCursor, a: Allocator) !?[]Row {
        if (self.result == null) self.result = try self.compute(a);
        const rows = self.result.?;
        if (self.pos >= rows.len) return null;
        const end = @min(self.pos + BATCH_SIZE, rows.len);
        defer self.pos = end;
        return rows[self.pos..end];
    }

    pub fn deinit(self: *AggregateCursor, a: Allocator) void {
        self.input.deinit(a);
        a.destroy(self.input);
    }

    // Pulls all rows from input, groups them, and returns the result slice.
    // Hashing finds candidate groups quickly; value equality confirms matches
    // to handle collisions and content-based text/blob comparison.
    fn compute(self: *AggregateCursor, a: Allocator) ![]Row {
        var groups: std.ArrayList(GroupState) = .empty;
        var buckets = std.AutoHashMap(u64, std.ArrayListUnmanaged(usize)).init(a);
        defer {
            var it = buckets.valueIterator();
            while (it.next()) |bucket| bucket.deinit(a);
            buckets.deinit();
        }

        while (try self.input.next(a)) |batch| {
            for (batch) |r| {
                const h = hashGroupRow(r.values, self.group_by);
                var group_idx: ?usize = null;

                if (buckets.getPtr(h)) |bucket| {
                    for (bucket.items) |idx| {
                        if (groupKeyMatches(groups.items[idx].key_values, r.values, self.group_by)) {
                            group_idx = idx;
                            break;
                        }
                    }
                }

                if (group_idx == null) {
                    const key_values = try a.alloc(row_mod.Value, self.group_by.len);
                    for (self.group_by, 0..) |col_idx, i| {
                        key_values[i] = try r.values[col_idx].clone(a);
                    }

                    const acc_states = try a.alloc(*anyopaque, self.agg_specs.len);
                    for (self.agg_specs, 0..) |spec, i| {
                        acc_states[i] = try spec.func.init(a);
                    }

                    try groups.append(a, .{ .key_values = key_values, .acc_states = acc_states });
                    const new_idx = groups.items.len - 1;

                    const gop = try buckets.getOrPut(h);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(a, new_idx);

                    group_idx = new_idx;
                }

                const g = &groups.items[group_idx.?];
                for (self.agg_specs, 0..) |spec, i| {
                    const v: ?row_mod.Value = if (spec.col_idx) |col_idx| r.values[col_idx] else null;
                    try spec.func.step(g.acc_states[i], v, a);
                }
            }
        }

        // SQL aggregate semantics without GROUP BY produce a single output row
        // even when the input has no rows (e.g. SELECT COUNT(*) FROM t WHERE 0).
        if (groups.items.len == 0 and self.group_by.len == 0) {
            const acc_states = try a.alloc(*anyopaque, self.agg_specs.len);
            for (self.agg_specs, 0..) |spec, i| {
                acc_states[i] = try spec.func.init(a);
            }
            try groups.append(a, .{ .key_values = &.{}, .acc_states = acc_states });
        }

        const out = try a.alloc(Row, groups.items.len);
        for (groups.items, 0..) |g, row_idx| {
            const values = try a.alloc(row_mod.Value, self.group_by.len + self.agg_specs.len);

            for (g.key_values, 0..) |k, i| values[i] = k;
            for (self.agg_specs, 0..) |spec, i| {
                values[self.group_by.len + i] = try spec.func.finalize(g.acc_states[i], a);
            }

            out[row_idx] = .{
                .rowid = @intCast(row_idx + 1),
                .values = values,
            };
        }

        return out;
    }
};

fn evalValueToRowValue(v: eval.EvalValue) row_mod.Value {
    return switch (v) {
        .int => |n| .{ .int = n },
        .real => |f| .{ .real = f },
        .text => |s| .{ .text = s },
        .bool_ => |b| .{ .int = if (b) 1 else 0 },
        .null_ => .null,
    };
}

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
    const_scan: ConstantScanCursor,
    seq_scan: SeqScanCursor,
    vtab_scan: VTabScanCursor,
    point_lookup: PointLookupCursor,
    filter: *FilterCursor,
    project: *ProjectCursor,
    aggregate: *AggregateCursor,
    join: *JoinCursor,

    pub fn open(plan: pp.PhysicalPlan, db: *Db, a: Allocator) !Cursor {
        return switch (plan) {
            .const_scan => .{ .const_scan = .{} },
            .seq_scan => |n| .{ .seq_scan = .{ .it = try db.scanOpen(n.table) } },
            .vtab_scan => |n| blk: {
                const vtab_cursor = try n.vtab.open(a, &db.cat, n.args);
                break :blk .{ .vtab_scan = .{ .cursor = vtab_cursor, .rowid = 1 } };
            },
            .point_lookup => |n| blk: {
                const vals = try db.getByRowid(n.table, n.rowid, a);
                const r: ?Row = if (vals) |v| blk2: {
                    const full = try a.alloc(row_mod.Value, v.len + 3);
                    @memcpy(full[0..v.len], v);
                    full[v.len] = .{ .int = @intCast(n.rowid) };
                    full[v.len + 1] = .null;
                    full[v.len + 2] = .null;
                    break :blk2 Row{ .rowid = n.rowid, .values = full };
                } else null;
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
                pc.exprs = n.exprs;
                break :blk .{ .project = pc };
            },
            .aggregate => |n| blk: {
                const ac = try a.create(AggregateCursor);
                const input_ptr = try a.create(Cursor);
                input_ptr.* = try open(n.input.*, db, a);
                ac.* = .{
                    .input = input_ptr,
                    .agg_specs = n.agg_specs,
                    .group_by = n.group_by,
                    .result = null,
                    .pos = 0,
                };
                break :blk .{ .aggregate = ac };
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
            .const_scan => |*s| s.next(a),
            .vtab_scan => |*s| s.next(a),
            .point_lookup => |*s| s.next(a),
            .filter => |f| f.next(a),
            .project => |p| p.next(a),
            .aggregate => |ag| ag.next(a),
            .join => |j| j.next(a),
        };
    }

    pub fn deinit(self: *Cursor, a: Allocator) void {
        switch (self.*) {
            .filter => |f| f.deinit(a),
            .project => |p| p.deinit(a),
            .aggregate => |ag| ag.deinit(a),
            .join => |j| j.deinit(a),
            else => {},
        }
    }
};
