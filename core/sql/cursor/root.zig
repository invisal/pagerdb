const std = @import("std");
const db_mod = @import("../../db.zig");
const row_mod = @import("../../row.zig");
const pp = @import("../physical_plan.zig");
const eval = @import("../eval.zig");
const ee = @import("../exec_expr.zig");
const vtab_mod = @import("../../vtable/root.zig");
const agg_mod = @import("agg_func.zig");

const Db = db_mod.Db;
const Allocator = std.mem.Allocator;
const EvalContext = eval.EvalContext;

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

    pub fn next(self: *SeqScanCursor, ctx: EvalContext) !?[]Row {
        var buf = try ctx.alloc.alloc(Row, BATCH_SIZE);
        var n: usize = 0;
        while (n < BATCH_SIZE) {
            const hit = try self.it.next(ctx.alloc) orelse break;
            // Append __rowid, __pageid, __slotid as the last three values so
            // they align with the synthetic SchemaCol entries injected by buildSchema.
            const vals = try ctx.alloc.alloc(row_mod.Value, hit.values.len + 3);
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

    pub fn next(self: *VTabScanCursor, ctx: EvalContext) !?[]Row {
        var buf: std.ArrayListUnmanaged(Row) = .empty;
        while (buf.items.len < BATCH_SIZE) {
            const vals = try self.cursor.next(ctx.alloc) orelse break;
            try buf.append(ctx.alloc, .{ .rowid = self.rowid, .values = vals });
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

    pub fn next(self: *ConstantScanCursor, ctx: EvalContext) !?[]Row {
        if (!self.first) return null;
        self.first = false;
        const t = try ctx.alloc.alloc(Row, 1);
        t[0] = .{ .rowid = 0, .values = try ctx.alloc.alloc(row_mod.Value, 0) };
        return t;
    }
};

// Point lookups fetch exactly one row (or nothing) from the btree.
// We return it as a 1-element batch so the calling loop stays uniform.
pub const PointLookupCursor = struct {
    row: ?Row,

    pub fn next(self: *PointLookupCursor, ctx: EvalContext) !?[]Row {
        const r = self.row orelse return null;
        self.row = null;
        const buf = try ctx.alloc.alloc(Row, 1);
        buf[0] = r;
        return buf;
    }
};

// ── Intermediate cursors ───────────────────────────────────────────────────────

pub const FilterCursor = struct {
    input: *Cursor,
    predicate: ee.ExecExpr,

    // Pull batches from the input and return only the rows that pass the
    // predicate.  We keep pulling until we have at least one match or the
    // input is exhausted, so callers never receive an empty non-null slice.
    pub fn next(self: *FilterCursor, ctx: EvalContext) !?[]Row {
        var out: std.ArrayList(Row) = .empty;
        while (out.items.len == 0) {
            const batch = try self.input.next(ctx) orelse return null;
            for (batch) |r| {
                const ev = try eval.evalExpr(self.predicate, r.values, ctx);
                if (eval.isTruthy(ev)) try out.append(ctx.alloc, r);
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
    exprs: []ee.ExecExpr,

    pub fn next(self: *ProjectCursor, ctx: EvalContext) !?[]Row {
        const batch = try self.input.next(ctx) orelse return null;
        const out = try ctx.alloc.alloc(Row, batch.len);
        for (batch, 0..) |r, i| {
            const projected = try ctx.alloc.alloc(row_mod.Value, self.exprs.len);
            for (self.exprs, 0..) |expr, j| {
                const v = try eval.evalExpr(expr, r.values, ctx);
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

// ExecAggCallSpec alias so callers don't need to import exec_expr.zig directly.
pub const AggSpec = ee.ExecAggCallSpec;

// Hash context for Value keys, used by the per-spec distinct sets.
const ValueHashContext = struct {
    pub fn hash(_: @This(), v: row_mod.Value) u64 {
        var h = std.hash.Wyhash.init(0);
        v.hashInto(&h);
        return h.final();
    }
    pub fn eql(_: @This(), a: row_mod.Value, b: row_mod.Value) bool {
        return row_mod.Value.eql(a, b);
    }
};

// Set of Values seen so far within a group for one DISTINCT aggregate.
const ValueSet = std.HashMapUnmanaged(row_mod.Value, void, ValueHashContext, 80);

const GroupState = struct {
    key_values: []row_mod.Value,
    acc_states: []*anyopaque,
    // One entry per agg_spec; only used when spec.distinct == true.
    distinct_sets: []ValueSet,
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

    pub fn next(self: *AggregateCursor, ctx: EvalContext) !?[]Row {
        if (self.result == null) self.result = try self.compute(ctx);
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
    fn compute(self: *AggregateCursor, ctx: EvalContext) ![]Row {
        const a = ctx.alloc;
        var groups: std.ArrayList(GroupState) = .empty;
        var buckets = std.AutoHashMap(u64, std.ArrayListUnmanaged(usize)).init(a);
        defer {
            var it = buckets.valueIterator();
            while (it.next()) |bucket| bucket.deinit(a);
            buckets.deinit();
        }

        while (try self.input.next(ctx)) |batch| {
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

                    const distinct_sets = try a.alloc(ValueSet, self.agg_specs.len);
                    for (distinct_sets) |*ds| ds.* = .empty;

                    try groups.append(a, .{ .key_values = key_values, .acc_states = acc_states, .distinct_sets = distinct_sets });
                    const new_idx = groups.items.len - 1;

                    const gop = try buckets.getOrPut(h);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(a, new_idx);

                    group_idx = new_idx;
                }

                const g = &groups.items[group_idx.?];
                for (self.agg_specs, 0..) |spec, i| {
                    // null input_expr = COUNT(*): pass null to signal "count this row".
                    // Otherwise evaluate the expression to get the per-row value.
                    const v: ?row_mod.Value = if (spec.input_expr) |expr|
                        evalValueToRowValue(try eval.evalExpr(expr, r.values, ctx))
                    else
                        null;
                    if (spec.distinct) {
                        // input_expr is guaranteed non-null for DISTINCT specs (validated by planner).
                        const val = v.?;
                        // Skip SQL NULLs — same behaviour as the non-distinct path.
                        if (val == .null) continue;
                        const gop = try g.distinct_sets[i].getOrPut(a, val);
                        if (gop.found_existing) continue;
                    }
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
            const distinct_sets = try a.alloc(ValueSet, self.agg_specs.len);
            for (distinct_sets) |*ds| ds.* = .empty;
            try groups.append(a, .{ .key_values = &.{}, .acc_states = acc_states, .distinct_sets = distinct_sets });
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

// ── Sort cursor ────────────────────────────────────────────────────────────────

// Compare two Values for ORDER BY.  Nulls sort before all non-null values
// (NULLS FIRST semantics).  int and real are compared numerically with cross-
// type promotion.  text and blob are compared lexicographically.
fn compareValues(a: row_mod.Value, b: row_mod.Value) std.math.Order {
    const a_null = a == .null;
    const b_null = b == .null;
    if (a_null and b_null) return .eq;
    if (a_null) return .lt;
    if (b_null) return .gt;
    return switch (a) {
        .int => |ai| switch (b) {
            .int => |bi| std.math.order(ai, bi),
            .real => |bf| std.math.order(@as(f64, @floatFromInt(ai)), bf),
            else => .lt, // int < text < blob
        },
        .real => |af| switch (b) {
            .real => |bf| std.math.order(af, bf),
            .int => |bi| std.math.order(af, @as(f64, @floatFromInt(bi))),
            else => .lt,
        },
        .text => |as| switch (b) {
            .text => |bs| std.mem.order(u8, as, bs),
            .int, .real => .gt, // text > int/real
            else => .lt, // text < blob
        },
        .blob => |ab| switch (b) {
            .blob => |bb| std.mem.order(u8, ab, bb),
            else => .gt, // blob > everything else
        },
        .null => unreachable, // handled above
    };
}

// Blocking sort: consumes all input rows, pre-evaluates sort key expressions,
// sorts in-place, then streams the result out in BATCH_SIZE chunks.
// Sits above Project so col_idx values in sort keys index into the projected
// values array (0-based position in SELECT output), not the raw scan columns.
pub const SortCursor = struct {
    input: *Cursor,
    keys: []ee.ExecSortKey,
    result: ?[]Row, // null until first next() triggers compute()
    pos: usize,

    pub fn next(self: *SortCursor, ctx: EvalContext) !?[]Row {
        if (self.result == null) self.result = try self.compute(ctx);
        const rows = self.result.?;
        if (self.pos >= rows.len) return null;
        const end = @min(self.pos + BATCH_SIZE, rows.len);
        defer self.pos = end;
        return rows[self.pos..end];
    }

    pub fn deinit(self: *SortCursor, a: Allocator) void {
        self.input.deinit(a);
        a.destroy(self.input);
    }

    // Pairs a row with its pre-evaluated sort key values so the comparison
    // function can run without error propagation.
    const SortRow = struct {
        row: Row,
        key_values: []row_mod.Value,
    };

    fn compute(self: *SortCursor, ctx: EvalContext) ![]Row {
        const a = ctx.alloc;
        var sort_rows: std.ArrayList(SortRow) = .empty;

        // Materialise all rows and eagerly evaluate the sort key expressions.
        while (try self.input.next(ctx)) |batch| {
            for (batch) |r| {
                const key_vals = try a.alloc(row_mod.Value, self.keys.len);
                for (self.keys, 0..) |key, i| {
                    const ev = try eval.evalExpr(key.expr, r.values, ctx);
                    key_vals[i] = evalValueToRowValue(ev);
                }
                try sort_rows.append(a, .{ .row = r, .key_values = key_vals });
            }
        }

        std.sort.block(SortRow, sort_rows.items, self.keys, struct {
            fn lessThan(keys: []ee.ExecSortKey, l: SortRow, r: SortRow) bool {
                for (keys, 0..) |key, i| {
                    const ord = compareValues(l.key_values[i], r.key_values[i]);
                    if (ord != .eq) return if (key.descending) ord == .gt else ord == .lt;
                }
                return false; // all keys equal: preserve original order
            }
        }.lessThan);

        const out = try a.alloc(Row, sort_rows.items.len);
        for (sort_rows.items, 0..) |sr, i| out[i] = sr.row;
        return out;
    }
};

// ── Distinct cursor ────────────────────────────────────────────────────────────

// Blocking deduplication: materializes all input rows into a hash-based seen
// set, then streams out the first occurrence of each unique row.  Uses the
// same hash+collision-chain strategy as AggregateCursor so NULL, text, and
// blob values are compared correctly (not just by pointer).
pub const DistinctCursor = struct {
    input: *Cursor,
    col_count: usize,
    result: ?[]Row,
    pos: usize,

    pub fn next(self: *DistinctCursor, ctx: EvalContext) !?[]Row {
        if (self.result == null) self.result = try self.compute(ctx);
        const rows = self.result.?;
        if (self.pos >= rows.len) return null;
        const end = @min(self.pos + BATCH_SIZE, rows.len);
        defer self.pos = end;
        return rows[self.pos..end];
    }

    pub fn deinit(self: *DistinctCursor, a: Allocator) void {
        self.input.deinit(a);
        a.destroy(self.input);
    }

    fn compute(self: *DistinctCursor, ctx: EvalContext) ![]Row {
        const a = ctx.alloc;
        // Build a full-column index array so we can reuse hashGroupRow/groupKeyMatches.
        const all_cols = try a.alloc(usize, self.col_count);
        defer a.free(all_cols);
        for (all_cols, 0..) |*c, i| c.* = i;

        // seen_keys: one entry per unique row, holds a copy of that row's values.
        // buckets: maps hash → list of indices into seen_keys (collision chain).
        var seen_keys: std.ArrayList([]row_mod.Value) = .empty;
        var buckets = std.AutoHashMap(u64, std.ArrayListUnmanaged(usize)).init(a);
        defer {
            var it = buckets.valueIterator();
            while (it.next()) |b| b.deinit(a);
            buckets.deinit();
        }

        var output: std.ArrayList(Row) = .empty;

        while (try self.input.next(ctx)) |batch| {
            for (batch) |r| {
                const h = hashGroupRow(r.values, all_cols);
                var found = false;
                if (buckets.getPtr(h)) |bucket| {
                    for (bucket.items) |idx| {
                        if (groupKeyMatches(seen_keys.items[idx], r.values, all_cols)) {
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) {
                    const key_copy = try a.alloc(row_mod.Value, r.values.len);
                    for (r.values, 0..) |v, i| key_copy[i] = try v.clone(a);
                    try seen_keys.append(a, key_copy);
                    const new_idx = seen_keys.items.len - 1;
                    const gop = try buckets.getOrPut(h);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(a, new_idx);
                    try output.append(a, r);
                }
            }
        }

        return try output.toOwnedSlice(a);
    }
};

// ── Join cursor ────────────────────────────────────────────────────────────────

// Nested-loop join with a materialized right side.
// On open(), all right-side rows are collected into a slice so that for each
// left row we can iterate the right side without re-opening the right cursor.
// Supports CROSS JOIN (no condition), INNER JOIN, and LEFT [OUTER] JOIN.
// For LEFT JOIN, any left row with no matching right row is emitted with NULLs
// padding the right-side columns.
pub const JoinCursor = struct {
    left: *Cursor,
    right_rows: []Row, // all right rows, materialized at open time
    right_pos: usize, // current position within right_rows for this left row
    left_batch: []Row, // current batch pulled from left cursor
    left_pos: usize, // position within left_batch
    condition: ?ee.ExecExpr, // null for CROSS JOIN (every left/right pair emitted)
    is_left_join: bool, // true = LEFT JOIN: unmatched left rows emitted with NULLs
    right_col_count: usize, // number of right-side columns (needed for NULL padding)
    had_right_match: bool, // tracks whether the current left row matched any right row

    // Pull combined (left ++ right) rows that satisfy the join condition.
    // Returns up to BATCH_SIZE rows per call, or null when exhausted.
    pub fn next(self: *JoinCursor, ctx: EvalContext) !?[]Row {
        const a = ctx.alloc;
        var out: std.ArrayList(Row) = .empty;

        while (true) {
            // Advance to the next left row when the current one is exhausted.
            while (self.left_pos >= self.left_batch.len) {
                self.left_batch = try self.left.next(ctx) orelse {
                    if (out.items.len > 0) return out.items;
                    return null;
                };
                self.left_pos = 0;
                self.right_pos = 0;
                self.had_right_match = false;
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

                const should_emit = if (self.condition) |cond| blk: {
                    const ev = try eval.evalExpr(cond, combined, ctx);
                    break :blk eval.isTruthy(ev);
                } else true;
                if (should_emit) {
                    self.had_right_match = true;
                    try out.append(a, .{ .rowid = left_row.rowid, .values = combined });
                }

                if (out.items.len >= BATCH_SIZE) return out.items;
            }

            // Finished right side for this left row; move to the next left row.
            self.left_pos += 1;
            self.right_pos = 0;

            // LEFT JOIN: if no right row matched, emit the left row with NULLs for
            // all right-side columns so the left row still appears in the result.
            if (self.is_left_join and !self.had_right_match) {
                const combined = try a.alloc(row_mod.Value, left_row.values.len + self.right_col_count);
                @memcpy(combined[0..left_row.values.len], left_row.values);
                @memset(combined[left_row.values.len..], .null);
                try out.append(a, .{ .rowid = left_row.rowid, .values = combined });
            }
            self.had_right_match = false;

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

// ── Scalar subquery executor ───────────────────────────────────────────────────

// Executes an IN subquery check for needle against the subquery's first column.
//
// Non-correlated (cache != null): the result set is the same for every outer
// row, so we materialise it once into the per-query arena and cache it by
// plan pointer.  Subsequent calls are a cheap linear scan of the cached slice.
// The cache is propagated into nested subquery contexts so inner non-correlated
// subqueries also get cached on their first evaluation.
//
// Correlated (cache == null): the result varies per outer row, so we open a
// fresh cursor each call and stream rows through a private arena that is freed
// on return.  Memory stays O(batch_size) regardless of table size or nesting.
pub fn execInSubquery(
    needle: eval.EvalValue,
    inner: *anyopaque,
    db_ptr: *anyopaque,
    outer: []const row_mod.Value,
    alloc: Allocator,
    cache: ?*eval.SubqueryCache,
) anyerror!bool {
    const plan: *pp.PhysicalPlan = @ptrCast(@alignCast(inner));
    const db: *Db = @ptrCast(@alignCast(db_ptr));

    if (cache) |c| {
        // Cache hit: scan the previously materialised result set.
        if (c.get(inner)) |cached| {
            for (cached) |v| {
                if (eval.compareValues(needle, v) == .eq) return true;
            }
            return false;
        }

        // Cache miss: execute once, store in per-query arena, then check.
        // Propagate the cache so nested non-correlated subqueries are also cached.
        const ctx = EvalContext{ .outer = outer, .alloc = alloc, .subquery_cache = cache };
        var cur = try Cursor.open(plan.*, db, alloc);
        defer cur.deinit(alloc);
        var results: std.ArrayListUnmanaged(eval.EvalValue) = .empty;
        while (try cur.next(ctx)) |batch| {
            for (batch) |result_row| {
                if (result_row.values.len > 0)
                    try results.append(alloc, eval.rowValToEval(result_row.values[0]));
            }
        }
        const cached = try results.toOwnedSlice(alloc);
        try c.put(alloc, inner, cached);
        for (cached) |v| {
            if (eval.compareValues(needle, v) == .eq) return true;
        }
        return false;
    }

    // Correlated: stream with a private arena freed on return.
    // Pass null cache so nested allocations do not escape into a dead arena.
    var tmp = std.heap.ArenaAllocator.init(alloc);
    defer tmp.deinit();
    const a = tmp.allocator();
    const ctx = EvalContext{ .outer = outer, .alloc = a, .subquery_cache = null };
    var cur = try Cursor.open(plan.*, db, a);
    defer cur.deinit(a);
    while (try cur.next(ctx)) |batch| {
        for (batch) |result_row| {
            if (result_row.values.len > 0) {
                if (eval.compareValues(needle, eval.rowValToEval(result_row.values[0])) == .eq)
                    return true;
            }
        }
    }
    return false;
}

// row.  Registered as the SubqueryExecFn in executor.zig so PhysicalPlan can
// hold a function pointer without importing cursor/root.zig (which would create
// a circular dependency).
//
// inner: *PhysicalPlan (opaque), db: *Db (opaque).
// outer: the current outer row's values, threaded through for correlated refs.
pub fn execScalarSubquery(
    inner: *anyopaque,
    db_ptr: *anyopaque,
    outer: []const row_mod.Value,
    alloc: Allocator,
) anyerror!?eval.EvalValue {
    const plan: *pp.PhysicalPlan = @ptrCast(@alignCast(inner));
    const db: *Db = @ptrCast(@alignCast(db_ptr));
    const ctx = EvalContext{ .outer = outer, .alloc = alloc };
    var cur = try Cursor.open(plan.*, db, alloc);
    defer cur.deinit(alloc);
    const batch = try cur.next(ctx) orelse return null;
    if (batch.len == 0 or batch[0].values.len == 0) return null;
    return eval.rowValToEval(batch[0].values[0]);
}

// ── Cursor union ───────────────────────────────────────────────────────────────

pub const Cursor = union(enum) {
    const_scan: ConstantScanCursor,
    seq_scan: SeqScanCursor,
    vtab_scan: VTabScanCursor,
    point_lookup: PointLookupCursor,
    filter: *FilterCursor,
    project: *ProjectCursor,
    aggregate: *AggregateCursor,
    sort: *SortCursor,
    distinct: *DistinctCursor,
    join: *JoinCursor,

    pub fn open(plan: pp.PhysicalPlan, db: *Db, a: Allocator) !Cursor {
        // Default context for open(): no outer row (top-level plan), alloc = a.
        // Used only for the join's right-side materialisation at open time.
        const init_ctx = EvalContext{ .outer = &.{}, .alloc = a };
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
            .sort => |n| blk: {
                const sc = try a.create(SortCursor);
                const input_ptr = try a.create(Cursor);
                input_ptr.* = try open(n.input.*, db, a);
                sc.* = .{ .input = input_ptr, .keys = n.keys, .result = null, .pos = 0 };
                break :blk .{ .sort = sc };
            },
            .distinct => |n| blk: {
                const dc = try a.create(DistinctCursor);
                const input_ptr = try a.create(Cursor);
                input_ptr.* = try open(n.input.*, db, a);
                dc.* = .{ .input = input_ptr, .col_count = n.schema.columns.len, .result = null, .pos = 0 };
                break :blk .{ .distinct = dc };
            },
            .join => |n| blk: {
                // Materialize the right side once so each left row can scan it
                // without re-opening a cursor.
                var right_rows: std.ArrayList(Row) = .empty;
                var right_cur = try open(n.right, db, a);
                defer right_cur.deinit(a);
                while (try right_cur.next(init_ctx)) |batch| {
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
                jc.is_left_join = n.join_type == .left;
                jc.right_col_count = n.right.schema().columns.len;
                jc.had_right_match = false;
                break :blk .{ .join = jc };
            },
            else => error.UnsupportedPlan,
        };
    }

    pub fn next(self: *Cursor, ctx: EvalContext) !?[]Row {
        return switch (self.*) {
            .seq_scan => |*s| s.next(ctx),
            .const_scan => |*s| s.next(ctx),
            .vtab_scan => |*s| s.next(ctx),
            .point_lookup => |*s| s.next(ctx),
            .filter => |f| f.next(ctx),
            .project => |p| p.next(ctx),
            .aggregate => |ag| ag.next(ctx),
            .sort => |s| s.next(ctx),
            .distinct => |d| d.next(ctx),
            .join => |j| j.next(ctx),
        };
    }

    pub fn deinit(self: *Cursor, a: Allocator) void {
        switch (self.*) {
            .filter => |f| f.deinit(a),
            .project => |p| p.deinit(a),
            .aggregate => |ag| ag.deinit(a),
            .sort => |s| s.deinit(a),
            .distinct => |d| d.deinit(a),
            .join => |j| j.deinit(a),
            else => {},
        }
    }
};
