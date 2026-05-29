const std = @import("std");
const db_mod = @import("../../db.zig");
const row_mod = @import("../../row.zig");
const pp = @import("../physical_plan.zig");
const eval = @import("../eval.zig");
const ee = @import("../exec_expr.zig");
const vtab_mod = @import("../../vtable/root.zig");
const agg_mod = @import("agg_func.zig");
const index_key = @import("./../../index_key.zig");

const Db = db_mod.Db;
const Allocator = std.mem.Allocator;
const EvalContext = eval.EvalContext;

pub const BATCH_SIZE: usize = 64;

// BorrowedRow: values are allocated on the batch arena and are valid only until
// the next cursor.next() call.  Call .clone(alloc) to copy into a longer-lived
// allocator when a row must survive past the current batch.
pub const BorrowedRow = struct {
    rowid: u64,
    values: []row_mod.Value,

    pub fn clone(self: BorrowedRow, alloc: Allocator) !BorrowedRow {
        const vals = try alloc.alloc(row_mod.Value, self.values.len);
        for (self.values, 0..) |v, i| vals[i] = try v.clone(alloc);
        return .{ .rowid = self.rowid, .values = vals };
    }
};

// Resets an arena between batch allocations.
// Debug: free_all returns pages to the OS — any stale pointer access faults immediately.
// Release: retain_capacity keeps pages mapped for reuse, making the next alloc fast.
fn resetArena(arena: *std.heap.ArenaAllocator) void {
    if (@import("builtin").mode == .Debug) {
        _ = arena.reset(.free_all);
    } else {
        _ = arena.reset(.retain_capacity);
    }
}

// ── Leaf cursors ───────────────────────────────────────────────────────────────

// Walks a real table via DbRowIterator, returning up to BATCH_SIZE rows per
// call.  The btree page buffer lives inside DbRowIterator so there is no
// additional heap allocation per batch beyond the Row slice itself.
pub const SeqScanCursor = struct {
    it: Db.DbRowIterator,
    batch_arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *SeqScanCursor) void {
        self.batch_arena.deinit();
    }

    pub fn next(self: *SeqScanCursor, _: EvalContext) !?[]BorrowedRow {
        resetArena(&self.batch_arena);
        const ba = self.batch_arena.allocator();
        var buf = try ba.alloc(BorrowedRow, BATCH_SIZE);
        // Decode directly into a pre-sized slice that already has room for
        // __rowid/__pageid/__slotid, avoiding an intermediate alloc+memcpy.
        const schema_len = self.it.schema_len;
        var n: usize = 0;
        while (n < BATCH_SIZE) {
            const vals = try ba.alloc(row_mod.Value, schema_len + 3);
            const meta = try self.it.nextInto(vals, ba) orelse break;
            vals[schema_len] = .{ .int = @intCast(meta.rowid) };
            vals[schema_len + 1] = .{ .int = @intCast(meta.page_id) };
            vals[schema_len + 2] = .{ .int = @intCast(meta.slot_id) };
            buf[n] = .{ .rowid = meta.rowid, .values = vals };
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
    batch_arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *VTabScanCursor) void {
        self.batch_arena.deinit();
    }

    pub fn next(self: *VTabScanCursor, _: EvalContext) !?[]BorrowedRow {
        resetArena(&self.batch_arena);
        const ba = self.batch_arena.allocator();
        var buf: std.ArrayListUnmanaged(BorrowedRow) = .empty;
        while (buf.items.len < BATCH_SIZE) {
            const vals = try self.cursor.next(ba) orelse break;
            try buf.append(ba, .{ .rowid = self.rowid, .values = vals });
            self.rowid += 1;
        }
        if (buf.items.len == 0) return null;
        return buf.items;
    }
};

// Produces exactly one empty row for SELECT without FROM.
// The projection layer above evaluates expressions against this row.
// Single allocation in the query arena — called at most once per query.
pub const ConstantScanCursor = struct {
    first: bool = true,

    pub fn next(self: *ConstantScanCursor, ctx: EvalContext) !?[]BorrowedRow {
        if (!self.first) return null;
        self.first = false;
        const t = try ctx.alloc.alloc(BorrowedRow, 1);
        t[0] = .{ .rowid = 0, .values = try ctx.alloc.alloc(row_mod.Value, 0) };
        return t;
    }
};

// Point lookups fetch exactly one row (or nothing) from the btree.
// We return it as a 1-element batch so the calling loop stays uniform.
// The row is pre-built into the query arena at open() time; next() wraps it
// in a slice allocated from the query arena (called at most once).
pub const PointLookupCursor = struct {
    row: ?BorrowedRow,

    pub fn next(self: *PointLookupCursor, ctx: EvalContext) !?[]BorrowedRow {
        const r = self.row orelse return null;
        self.row = null;
        const buf = try ctx.alloc.alloc(BorrowedRow, 1);
        buf[0] = r;
        return buf;
    }
};

pub const IndexRangeScanCursor = struct {
    it: Db.IndexRangeScanIterator,
    range: pp.KeyRange,
    residual: ?ee.ExecExpr,
    batch_arena: std.heap.ArenaAllocator,
    schema_col_count: usize,

    pub fn deinit(self: *IndexRangeScanCursor) void {
        self.batch_arena.deinit();
    }

    pub fn next(self: *IndexRangeScanCursor, ctx: EvalContext) !?[]BorrowedRow {
        resetArena(&self.batch_arena);
        const ba = self.batch_arena.allocator();
        var buf = try ba.alloc(BorrowedRow, BATCH_SIZE);
        var n: usize = 0;

        while (n < BATCH_SIZE) {
            const hit = try self.it.next(ba) orelse break;

            // Lower bound: initFromLower lands on the right leaf page but
            // starts at cell_index 0, so the first few entries on that page
            // may still be below the bound.  Skip them here.
            if (self.range.lower) |lb| {
                const prefix_len = @min(hit.key.len, lb.encoded.len);
                const ord = index_key.compareKeys(hit.key[0..prefix_len], lb.encoded[0..prefix_len]);
                const before = if (lb.inclusive) ord == .lt else ord != .gt;
                if (before) continue;
            }

            // Upper bound: compare the key prefix (same length as the encoded bound)
            // so the rowid suffix doesn't affect the comparison.
            if (self.range.upper) |ub| {
                const prefix_len = @min(hit.key.len, ub.encoded.len);
                const ord = index_key.compareKeys(hit.key[0..prefix_len], ub.encoded[0..prefix_len]);
                const past = if (ub.inclusive) ord == .gt else ord != .lt;
                if (past) break;
            }

            const vals = try ba.alloc(row_mod.Value, hit.values.len + 3);
            @memcpy(vals[0..hit.values.len], hit.values);
            vals[hit.values.len] = .{ .int = @intCast(hit.rowid) };
            vals[hit.values.len + 1] = .{ .int = 0 };
            vals[hit.values.len + 2] = .{ .int = 0 };

            if (self.residual) |pred| {
                const ev = try eval.evalExpr(pred, vals, ctx);
                if (!eval.isTruthy(ev)) continue;
            }

            buf[n] = .{ .rowid = hit.rowid, .values = vals };
            n += 1;
        }
        if (n == 0) return null;
        return buf[0..n];
    }
};

// ── Intermediate cursors ───────────────────────────────────────────────────────

pub const FilterCursor = struct {
    input: *Cursor,
    predicate: ee.ExecExpr,
    // Owns memory for the filtered row-pointer array and predicate eval strings.
    // Reset at the start of each next() call; never reset between inner loops
    // so predicate strings from failed batches accumulate (bounded, freed next call).
    batch_arena: std.heap.ArenaAllocator,

    // Pull batches from the input and return only the rows that pass the
    // predicate.  We keep pulling until we have at least one match or the
    // input is exhausted, so callers never receive an empty non-null slice.
    pub fn next(self: *FilterCursor, ctx: EvalContext) !?[]BorrowedRow {
        resetArena(&self.batch_arena);
        const ba = self.batch_arena.allocator();
        // Route evalExpr string allocations (e.g. CAST) into our own batch arena.
        const eval_ctx = EvalContext{ .outer = ctx.outer, .alloc = ctx.alloc, .batch_alloc = ba, .subquery_cache = ctx.subquery_cache };
        var out: std.ArrayListUnmanaged(BorrowedRow) = .empty;
        while (out.items.len == 0) {
            // input.next() resets the input cursor's own batch arena, invalidating
            // its previous batch.  Re-init out so appends start fresh.
            const batch = try self.input.next(ctx) orelse return null;
            out = .empty;
            for (batch) |r| {
                const ev = try eval.evalExpr(self.predicate, r.values, eval_ctx);
                // r is a struct copy; values pointer still lives in input's arena.
                if (eval.isTruthy(ev)) try out.append(ba, r);
            }
        }
        return out.items;
    }

    pub fn deinit(self: *FilterCursor, a: Allocator) void {
        self.input.deinit(a);
        a.destroy(self.input);
        self.batch_arena.deinit();
    }
};

pub const ProjectCursor = struct {
    input: *Cursor,
    exprs: []ee.ExecExpr,
    // Owns computed value slices and any strings produced by expression evaluation.
    // Passthrough column values are shallow-copied from the input's batch arena
    // and remain valid as long as the input cursor has not been advanced.
    batch_arena: std.heap.ArenaAllocator,

    pub fn next(self: *ProjectCursor, ctx: EvalContext) !?[]BorrowedRow {
        resetArena(&self.batch_arena);
        const ba = self.batch_arena.allocator();
        const eval_ctx = EvalContext{ .outer = ctx.outer, .alloc = ctx.alloc, .batch_alloc = ba, .subquery_cache = ctx.subquery_cache };
        const batch = try self.input.next(ctx) orelse return null;
        const out = try ba.alloc(BorrowedRow, batch.len);
        for (batch, 0..) |r, i| {
            const projected = try ba.alloc(row_mod.Value, self.exprs.len);
            for (self.exprs, 0..) |expr, j| {
                const v = try eval.evalExpr(expr, r.values, eval_ctx);
                projected[j] = evalValueToRowValue(v);
            }
            out[i] = .{ .rowid = r.rowid, .values = projected };
        }
        return out;
    }

    pub fn deinit(self: *ProjectCursor, a: Allocator) void {
        self.input.deinit(a);
        a.destroy(self.input);
        self.batch_arena.deinit();
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
    result: ?[]BorrowedRow, // materialized output, null until first next() call
    pos: usize, // next unread position within result

    pub fn next(self: *AggregateCursor, ctx: EvalContext) !?[]BorrowedRow {
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
    fn compute(self: *AggregateCursor, ctx: EvalContext) ![]BorrowedRow {
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
                        // Clone into the query arena before storing: val may contain a string
                        // pointer into the batch arena that will be reset on the next batch.
                        const val_owned = try val.clone(a);
                        const gop = try g.distinct_sets[i].getOrPut(a, val_owned);
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

        const out = try a.alloc(BorrowedRow, groups.items.len);
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
    result: ?[]BorrowedRow, // null until first next() triggers compute()
    pos: usize,

    pub fn next(self: *SortCursor, ctx: EvalContext) !?[]BorrowedRow {
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
        row: BorrowedRow,
        key_values: []row_mod.Value,
    };

    fn compute(self: *SortCursor, ctx: EvalContext) ![]BorrowedRow {
        const a = ctx.alloc;
        var sort_rows: std.ArrayList(SortRow) = .empty;

        // Materialise all rows into the query arena before the batch resets.
        // Each input.next() call resets the batch arena (via the leaf cursor),
        // so rows must be cloned into ctx.alloc to survive across batches.
        while (try self.input.next(ctx)) |batch| {
            for (batch) |r| {
                const key_vals = try a.alloc(row_mod.Value, self.keys.len);
                for (self.keys, 0..) |key, i| {
                    const ev = try eval.evalExpr(key.expr, r.values, ctx);
                    key_vals[i] = evalValueToRowValue(ev);
                }
                try sort_rows.append(a, .{ .row = try r.clone(a), .key_values = key_vals });
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

        const out = try a.alloc(BorrowedRow, sort_rows.items.len);
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
    result: ?[]BorrowedRow,
    pos: usize,

    pub fn next(self: *DistinctCursor, ctx: EvalContext) !?[]BorrowedRow {
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

    fn compute(self: *DistinctCursor, ctx: EvalContext) ![]BorrowedRow {
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

        var output: std.ArrayList(BorrowedRow) = .empty;

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
                    // Clone into query arena: r.values points into the batch arena
                    // which will be reset on the next input.next() call.
                    try output.append(a, try r.clone(a));
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
    right_rows: []BorrowedRow, // all right rows, materialized at open time into query arena
    right_pos: usize, // current position within right_rows for this left row
    left_batch: []BorrowedRow, // current batch from left cursor; lives in left's batch arena
    left_pos: usize, // position within left_batch
    condition: ?ee.ExecExpr, // null for CROSS JOIN (every left/right pair emitted)
    is_left_join: bool, // true = LEFT JOIN: unmatched left rows emitted with NULLs
    right_col_count: usize, // number of right-side columns (needed for NULL padding)
    had_right_match: bool, // tracks whether the current left row matched any right row
    // Owns combined value slices for the current output batch.
    // Reset each time we fetch a new left batch (left_batch exhausted).
    batch_arena: std.heap.ArenaAllocator,

    // Pull combined (left ++ right) rows that satisfy the join condition.
    // Returns up to BATCH_SIZE rows per call, or null when exhausted.
    //
    // left_batch lives in the left cursor's own batch arena and stays valid
    // across multiple JoinCursor.next() calls for the same left batch because
    // we only call left.next() (which resets the left cursor's arena) once
    // left_batch is fully consumed.
    pub fn next(self: *JoinCursor, ctx: EvalContext) !?[]BorrowedRow {
        const ba = self.batch_arena.allocator();
        const eval_ctx = EvalContext{ .outer = ctx.outer, .alloc = ctx.alloc, .batch_alloc = ba, .subquery_cache = ctx.subquery_cache };
        var out: std.ArrayListUnmanaged(BorrowedRow) = .empty;

        while (true) {
            // Fetch the next left batch when the current one is exhausted.
            // Reset our arena here: all combined rows from the previous left batch
            // are no longer needed, and left.next() may reorder left's arena.
            while (self.left_pos >= self.left_batch.len) {
                resetArena(&self.batch_arena);
                out = .empty;
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
                const combined = try ba.alloc(row_mod.Value, left_row.values.len + right_row.values.len);
                @memcpy(combined[0..left_row.values.len], left_row.values);
                @memcpy(combined[left_row.values.len..], right_row.values);

                const should_emit = if (self.condition) |cond| blk: {
                    const ev = try eval.evalExpr(cond, combined, eval_ctx);
                    break :blk eval.isTruthy(ev);
                } else true;
                if (should_emit) {
                    self.had_right_match = true;
                    try out.append(ba, .{ .rowid = left_row.rowid, .values = combined });
                }

                if (out.items.len >= BATCH_SIZE) return out.items;
            }

            // Finished right side for this left row; move to the next left row.
            self.left_pos += 1;
            self.right_pos = 0;

            // LEFT JOIN: if no right row matched, emit the left row with NULLs for
            // all right-side columns so the left row still appears in the result.
            if (self.is_left_join and !self.had_right_match) {
                const combined = try ba.alloc(row_mod.Value, left_row.values.len + self.right_col_count);
                @memcpy(combined[0..left_row.values.len], left_row.values);
                @memset(combined[left_row.values.len..], .null);
                try out.append(ba, .{ .rowid = left_row.rowid, .values = combined });
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
        self.batch_arena.deinit();
    }
};

// ── Hash join cursor ───────────────────────────────────────────────────────────

// Build-probe hash join.
//
// Build phase (open): iterate the right child, hash each row by its equi-join
// key columns into a hash table mapping hash → list of right-row indices.
//
// Probe phase (next): for each left row hash its key columns, look up the
// bucket, verify actual key equality for each candidate (guarding against hash
// collisions), evaluate any residual non-equi condition, then emit matches.
//
// This cuts inner-loop work from O(R) per left row (nested-loop) to O(1)
// average, giving O(L + R) total instead of O(L × R).
pub const HashJoinCursor = struct {
    left: *Cursor,
    right_rows: []BorrowedRow, // all right rows, materialized in query arena at open time
    // Maps hash(key columns) → indices into right_rows.  Multiple indices per
    // hash bucket handle genuine duplicates and hash collisions.
    hash_table: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(u32)),
    keys: []pp.EquiKey,
    residual: ?ee.ExecExpr, // non-equi part of the original ON condition, if any
    is_left_join: bool,
    right_col_count: usize,
    left_batch: []BorrowedRow,
    left_pos: usize,
    bucket: []const u32, // right-row index candidates for the current left row
    bucket_pos: usize,
    had_match: bool,
    batch_arena: std.heap.ArenaAllocator,

    fn hashRightKeys(row: []const row_mod.Value, keys: []const pp.EquiKey) u64 {
        var h = std.hash.Wyhash.init(0);
        for (keys) |k| row[k.right_idx].hashInto(&h);
        return h.final();
    }

    fn hashLeftKeys(row: []const row_mod.Value, keys: []const pp.EquiKey) u64 {
        var h = std.hash.Wyhash.init(0);
        for (keys) |k| row[k.left_idx].hashInto(&h);
        return h.final();
    }

    fn keysMatch(left_row: []const row_mod.Value, right_row: []const row_mod.Value, keys: []const pp.EquiKey) bool {
        for (keys) |k| {
            if (!left_row[k.left_idx].eql(right_row[k.right_idx])) return false;
        }
        return true;
    }

    pub fn next(self: *HashJoinCursor, ctx: EvalContext) !?[]BorrowedRow {
        const ba = self.batch_arena.allocator();
        const eval_ctx = EvalContext{ .outer = ctx.outer, .alloc = ctx.alloc, .batch_alloc = ba, .subquery_cache = ctx.subquery_cache };
        var out: std.ArrayListUnmanaged(BorrowedRow) = .empty;

        while (true) {
            // Fetch a new left batch when the current one is exhausted.
            while (self.left_pos >= self.left_batch.len) {
                resetArena(&self.batch_arena);
                out = .empty;
                self.left_batch = try self.left.next(ctx) orelse {
                    if (out.items.len > 0) return out.items;
                    return null;
                };
                self.left_pos = 0;
                self.had_match = false;
                // Pre-look up the hash bucket for the first row in the batch.
                if (self.left_batch.len > 0) {
                    const h = hashLeftKeys(self.left_batch[0].values, self.keys);
                    self.bucket = if (self.hash_table.get(h)) |list| list.items else &.{};
                    self.bucket_pos = 0;
                }
            }

            const left_row = self.left_batch[self.left_pos];

            // Walk hash bucket candidates for this left row.
            while (self.bucket_pos < self.bucket.len) {
                const right_idx = self.bucket[self.bucket_pos];
                self.bucket_pos += 1;
                const right_row = self.right_rows[right_idx];

                // Guard against hash collisions: verify actual key equality.
                if (!keysMatch(left_row.values, right_row.values, self.keys)) continue;

                const combined = try ba.alloc(row_mod.Value, left_row.values.len + right_row.values.len);
                @memcpy(combined[0..left_row.values.len], left_row.values);
                @memcpy(combined[left_row.values.len..], right_row.values);

                const should_emit = if (self.residual) |res| blk: {
                    const ev = try eval.evalExpr(res, combined, eval_ctx);
                    break :blk eval.isTruthy(ev);
                } else true;

                if (should_emit) {
                    self.had_match = true;
                    try out.append(ba, .{ .rowid = left_row.rowid, .values = combined });
                }

                if (out.items.len >= BATCH_SIZE) return out.items;
            }

            // Finished bucket for this left row; advance to next left row.
            self.left_pos += 1;

            // LEFT JOIN: emit left row with NULLs if no right row matched.
            if (self.is_left_join and !self.had_match) {
                const combined = try ba.alloc(row_mod.Value, left_row.values.len + self.right_col_count);
                @memcpy(combined[0..left_row.values.len], left_row.values);
                @memset(combined[left_row.values.len..], .null);
                try out.append(ba, .{ .rowid = left_row.rowid, .values = combined });
            }
            self.had_match = false;

            // Pre-look up the bucket for the next left row while still in this batch.
            if (self.left_pos < self.left_batch.len) {
                const h = hashLeftKeys(self.left_batch[self.left_pos].values, self.keys);
                self.bucket = if (self.hash_table.get(h)) |list| list.items else &.{};
                self.bucket_pos = 0;
            }

            if (out.items.len > 0) return out.items;
        }
    }

    pub fn deinit(self: *HashJoinCursor, a: Allocator) void {
        self.left.deinit(a);
        a.destroy(self.left);
        self.hash_table.deinit(a);
        self.batch_arena.deinit();
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
                if (result_row.values.len > 0) {
                    const raw = eval.rowValToEval(result_row.values[0]);
                    // result_row.values live in the cursor's batch arena which resets
                    // on the next cur.next() call.  Clone text into alloc so cached
                    // results remain valid for the lifetime of the query.
                    const owned: eval.EvalValue = switch (raw) {
                        .text => |s| .{ .text = try alloc.dupe(u8, s) },
                        else => raw,
                    };
                    try results.append(alloc, owned);
                }
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
    const raw = eval.rowValToEval(batch[0].values[0]);
    // Clone text into alloc before defer fires cur.deinit(), which frees the
    // leaf cursor's batch arena where the string data lives.
    return switch (raw) {
        .text => |s| eval.EvalValue{ .text = try alloc.dupe(u8, s) },
        else => raw,
    };
}

// ── Cursor union ───────────────────────────────────────────────────────────────

pub const Cursor = union(enum) {
    const_scan: ConstantScanCursor,
    seq_scan: SeqScanCursor,
    vtab_scan: VTabScanCursor,
    point_lookup: PointLookupCursor,
    index_range_scan: *IndexRangeScanCursor,
    filter: *FilterCursor,
    project: *ProjectCursor,
    aggregate: *AggregateCursor,
    sort: *SortCursor,
    distinct: *DistinctCursor,
    join: *JoinCursor,
    hash_join: *HashJoinCursor,

    pub fn open(plan: pp.PhysicalPlan, db: *Db, a: Allocator) !Cursor {
        return switch (plan) {
            .const_scan => .{ .const_scan = .{} },
            .seq_scan => |n| .{ .seq_scan = .{
                .it = try db.scanOpen(n.table),
                .batch_arena = std.heap.ArenaAllocator.init(a),
            } },
            .vtab_scan => |n| blk: {
                const vtab_cursor = try n.vtab.open(a, &db.cat, n.args);
                break :blk .{ .vtab_scan = .{
                    .cursor = vtab_cursor,
                    .rowid = 1,
                    .batch_arena = std.heap.ArenaAllocator.init(a),
                } };
            },
            .point_lookup => |n| blk: {
                const vals = try db.getByRowid(n.table, n.rowid, a);
                const r: ?BorrowedRow = if (vals) |v| blk2: {
                    const full = try a.alloc(row_mod.Value, v.len + 3);
                    @memcpy(full[0..v.len], v);
                    full[v.len] = .{ .int = @intCast(n.rowid) };
                    full[v.len + 1] = .null;
                    full[v.len + 2] = .null;
                    break :blk2 BorrowedRow{ .rowid = n.rowid, .values = full };
                } else null;
                break :blk .{ .point_lookup = .{ .row = r } };
            },
            .index_range_scan => |n| blk: {
                const c = try a.create(IndexRangeScanCursor);
                c.* = IndexRangeScanCursor{
                    .it = try db.indexRangeScanOpen(n.table, n.index, n.range),
                    .batch_arena = std.heap.ArenaAllocator.init(a),
                    .residual = n.residual,
                    .range = n.range,
                    .schema_col_count = n.schema.columns.len - 3,
                };
                break :blk Cursor{ .index_range_scan = c };
            },
            .filter => |n| blk: {
                const fc = try a.create(FilterCursor);
                fc.input = try a.create(Cursor);
                fc.input.* = try open(n.input, db, a);
                fc.predicate = n.predicate;
                fc.batch_arena = std.heap.ArenaAllocator.init(a);
                break :blk .{ .filter = fc };
            },
            .project => |n| blk: {
                const pc = try a.create(ProjectCursor);
                pc.input = try a.create(Cursor);
                pc.input.* = try open(n.input, db, a);
                pc.exprs = n.exprs;
                pc.batch_arena = std.heap.ArenaAllocator.init(a);
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
                // Materialize the right side once into the query arena so each left row
                // can scan it without re-opening a cursor.  The right cursor owns its own
                // batch arena (per the per-cursor design), so rows are cloned into `a`.
                const right_init_ctx = EvalContext{ .outer = &.{}, .alloc = a };
                var right_rows: std.ArrayList(BorrowedRow) = .empty;
                var right_cur = try open(n.right, db, a);
                defer right_cur.deinit(a);
                while (try right_cur.next(right_init_ctx)) |batch| {
                    for (batch) |r| try right_rows.append(a, try r.clone(a));
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
                jc.batch_arena = std.heap.ArenaAllocator.init(a);
                break :blk .{ .join = jc };
            },
            .hash_join => |n| blk: {
                // Build phase: materialize the right side and index it by key hash.
                const right_init_ctx = EvalContext{ .outer = &.{}, .alloc = a };
                var right_list: std.ArrayListUnmanaged(BorrowedRow) = .empty;
                var right_cur = try open(n.right, db, a);
                defer right_cur.deinit(a);
                while (try right_cur.next(right_init_ctx)) |batch| {
                    for (batch) |r| try right_list.append(a, try r.clone(a));
                }
                const right_rows = try right_list.toOwnedSlice(a);

                var hash_table: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(u32)) = .empty;
                for (right_rows, 0..) |row, i| {
                    var hasher = std.hash.Wyhash.init(0);
                    for (n.keys) |k| row.values[k.right_idx].hashInto(&hasher);
                    const h = hasher.final();
                    const gop = try hash_table.getOrPut(a, h);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(a, @intCast(i));
                }

                const hjc = try a.create(HashJoinCursor);
                hjc.* = .{
                    .left = try a.create(Cursor),
                    .right_rows = right_rows,
                    .hash_table = hash_table,
                    .keys = n.keys,
                    .residual = n.residual,
                    .is_left_join = n.join_type == .left,
                    .right_col_count = n.right.schema().columns.len,
                    .left_batch = &.{},
                    .left_pos = 0,
                    .bucket = &.{},
                    .bucket_pos = 0,
                    .had_match = false,
                    .batch_arena = std.heap.ArenaAllocator.init(a),
                };
                hjc.left.* = try open(n.left, db, a);
                break :blk .{ .hash_join = hjc };
            },
            else => error.UnsupportedPlan,
        };
    }

    pub fn next(self: *Cursor, ctx: EvalContext) !?[]BorrowedRow {
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
            .hash_join => |j| j.next(ctx),
            .index_range_scan => |i| i.next(ctx),
        };
    }

    pub fn deinit(self: *Cursor, a: Allocator) void {
        switch (self.*) {
            .seq_scan => |*s| s.deinit(),
            .vtab_scan => |*s| s.deinit(),
            .filter => |f| f.deinit(a),
            .project => |p| p.deinit(a),
            .aggregate => |ag| ag.deinit(a),
            .sort => |s| s.deinit(a),
            .distinct => |d| d.deinit(a),
            .join => |j| j.deinit(a),
            .hash_join => |j| j.deinit(a),
            .index_range_scan => |i| i.deinit(),
            else => {},
        }
    }
};
