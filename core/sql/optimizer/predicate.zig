// Rule 1: Predicate pushdown.
//
// Moves Filter nodes as far down the plan tree as possible so fewer rows
// flow through expensive operators like Join.
//
// Key decisions:
//   - Filter(Join): delegate to tryPushIntoJoin which splits conjuncts by side.
//   - Filter(Filter): merge into one AND so later passes see a flat conjunct list.
//   - Filter above Project/Aggregate/Sort/Distinct: do not push across — their
//     output schemas differ from their inputs, so col_idx values would be wrong.
//   - Right-side predicates are only pushed for INNER/CROSS joins; pushing into
//     a LEFT JOIN right child would silently convert it to an inner join.

const std = @import("std");
const lp = @import("../logical_plan.zig");
const utils = @import("utils.zig");

pub fn pushdownPredicates(a: std.mem.Allocator, plan: lp.LogicalPlan) anyerror!lp.LogicalPlan {
    return switch (plan) {
        .filter => |f| {
            const optimized_input = try pushdownPredicates(a, f.input.*);

            // Child is a join: distribute predicates into its children.
            if (optimized_input == .join)
                return tryPushIntoJoin(a, f, optimized_input.join);

            // Child is another filter: merge both predicates into one AND so
            // the next pass sees a flat conjunct list instead of nested filters.
            if (optimized_input == .filter) {
                const inner = optimized_input.filter;
                const merged = try a.create(lp.Expr.Binary);
                merged.* = .{ .op = .and_, .left = f.predicate, .right = inner.predicate };
                const merged_filter = try a.create(lp.Filter);
                merged_filter.* = .{ .input = inner.input, .predicate = .{ .binary = merged }, .schema = f.schema };
                return pushdownPredicates(a, .{ .filter = merged_filter });
            }

            const new_filter = try a.create(lp.Filter);
            new_filter.* = .{
                .input = try box(a, optimized_input),
                .predicate = f.predicate,
                .schema = f.schema,
            };
            return .{ .filter = new_filter };
        },

        .join => |j| {
            const optimized_left = try pushdownPredicates(a, j.left.*);
            const optimized_right = try pushdownPredicates(a, j.right.*);
            const new_join = try a.create(lp.Join);
            new_join.* = .{
                .left = try box(a, optimized_left),
                .right = try box(a, optimized_right),
                .condition = j.condition,
                .join_type = j.join_type,
                .schema = j.schema,
            };
            return .{ .join = new_join };
        },

        // For Project, Sort, Distinct, Aggregate: recurse into child but do
        // not push predicates past these nodes.  Their schemas differ from
        // their input schemas, so col_idx values in a filter above them would
        // be wrong if the filter were moved below.
        //
        // Exception: a Filter above a Project *can* be pushed past the Project
        // if the filter only references columns that the Project passes through
        // unchanged — but that's a more advanced optimization; skip it for now.
        .project => |p| {
            const optimized_input = try pushdownPredicates(a, p.input.*);
            const new_proj = try a.create(lp.Project);
            new_proj.* = .{
                .input = try box(a, optimized_input),
                .exprs = p.exprs,
                .schema = p.schema,
            };
            return .{ .project = new_proj };
        },

        .aggregate => |ag| {
            const optimized_input = try pushdownPredicates(a, ag.input.*);
            const new_agg = try a.create(lp.Aggregate);
            new_agg.* = .{
                .input = try box(a, optimized_input),
                .group_by = ag.group_by,
                .agg_specs = ag.agg_specs,
                .schema = ag.schema,
            };
            return .{ .aggregate = new_agg };
        },

        .sort => |s| {
            const optimized_input = try pushdownPredicates(a, s.input.*);
            const new_sort = try a.create(lp.Sort);
            new_sort.* = .{
                .input = try box(a, optimized_input),
                .keys = s.keys,
                .schema = s.schema,
            };
            return .{ .sort = new_sort };
        },

        .distinct => |d| {
            const optimized_input = try pushdownPredicates(a, d.input.*);
            const new_distinct = try a.create(lp.Distinct);
            new_distinct.* = .{
                .input = try box(a, optimized_input),
                .schema = d.schema,
            };
            return .{ .distinct = new_distinct };
        },

        // DML nodes: recurse into their scan/filter input if present.
        .update => |u| {
            const optimized_input = try pushdownPredicates(a, u.input.*);
            var new_u = u;
            new_u.input = try box(a, optimized_input);
            return .{ .update = new_u };
        },

        .delete => |d| {
            const optimized_input = try pushdownPredicates(a, d.input.*);
            var new_d = d;
            new_d.input = try box(a, optimized_input);
            return .{ .delete = new_d };
        },

        .insert_select => |is_| {
            const optimized_input = try pushdownPredicates(a, is_.input.*);
            var new_is = is_;
            new_is.input = try box(a, optimized_input);
            return .{ .insert_select = new_is };
        },

        // Leaf nodes and DDL: nothing to recurse into, return unchanged.
        .seq_scan, .vtab_scan, .const_scan, .insert, .create_table, .create_index, .create_view, .drop_view, .drop_table, .begin, .commit, .rollback => plan,
    };
}

// Distributes Filter(Join) predicates: left-only → left child, right-only →
// right child (INNER/CROSS only), both_sides → join condition, neither → above.
// Merges with the existing join condition and recurses on the result.
fn tryPushIntoJoin(a: std.mem.Allocator, f: *lp.Filter, j: *lp.Join) anyerror!lp.LogicalPlan {
    var preds: std.ArrayListUnmanaged(lp.Expr) = .empty;
    const left_count = j.left.schema().columns.len;
    try utils.splitConjuncts(a, f.predicate, &preds);

    var left_preds: std.ArrayListUnmanaged(lp.Expr) = .empty;
    var right_preds: std.ArrayListUnmanaged(lp.Expr) = .empty;
    var both_preds: std.ArrayListUnmanaged(lp.Expr) = .empty;
    var above_preds: std.ArrayListUnmanaged(lp.Expr) = .empty;

    for (preds.items) |p| {
        switch (exprSide(p, left_count)) {
            .left_only => try left_preds.append(a, p),
            .right_only => if (j.join_type != .left) {
                try right_preds.append(a, try shiftRightColIdx(p, left_count, a));
            } else {
                // LEFT JOIN: pushing into the right child would eliminate
                // null-extended rows and silently convert it to an inner join.
                // Keep the predicate above with its original merged-schema indices.
                try above_preds.append(a, p);
            },
            .both_sides => try both_preds.append(a, p),
            .neither => try above_preds.append(a, p),
        }
    }

    if (left_preds.items.len > 0) {
        const new_left = try a.create(lp.Filter);
        new_left.* = lp.Filter{
            .input = j.left,
            .schema = j.left.schema(),
            .predicate = (try utils.joinConjuncts(a, left_preds.items)).?,
        };
        j.left = try box(a, .{ .filter = new_left });
    }

    if (right_preds.items.len > 0) {
        const new_right = try a.create(lp.Filter);
        new_right.* = lp.Filter{
            .input = j.right,
            .schema = j.right.schema(),
            .predicate = (try utils.joinConjuncts(a, right_preds.items)).?,
        };
        j.right = try box(a, .{ .filter = new_right });
    }

    var join_conds: std.ArrayListUnmanaged(lp.Expr) = .empty;
    if (j.condition) |cond| try utils.splitConjuncts(a, cond, &join_conds);
    try join_conds.appendSlice(a, both_preds.items);
    j.condition = try utils.joinConjuncts(a, join_conds.items);

    // Recurse into join children now, before potentially wrapping a filter above.
    // We must NOT call pushdownPredicates(.filter) when above_preds is non-empty:
    // those predicates (e.g. literals with no column refs, or right-only predicates
    // on a LEFT JOIN) would re-enter tryPushIntoJoin and loop forever.
    const optimized_join = try pushdownPredicates(a, .{ .join = j });

    if (above_preds.items.len > 0) {
        const new_filter = try a.create(lp.Filter);
        new_filter.input = try box(a, optimized_join);
        new_filter.schema = j.schema;
        new_filter.predicate = (try utils.joinConjuncts(a, above_preds.items)).?;
        return .{ .filter = new_filter };
    }

    return optimized_join;
}

// Classifies which join side an expression references, by walking all col_idx
// leaves.  Left columns occupy [0, left_count), right columns [left_count, total).
// outer_col_idx and subqueries block pushdown because they don't belong to either child.
const ExprSide = enum { left_only, right_only, both_sides, neither };

fn exprSide(expr: lp.Expr, left_count: usize) ExprSide {
    return switch (expr) {
        .col_idx => |idx| if (idx < left_count) .left_only else .right_only,
        .outer_col_idx, .in_subquery, .subquery => .both_sides,

        .binary => |b| mergeSide(exprSide(b.left, left_count), exprSide(b.right, left_count)),
        .unary => |u| exprSide(u.operand, left_count),
        .cast => |c| exprSide(c.operand, left_count),
        .is_null => |n| exprSide(n.operand, left_count),

        .func_call => |f| blk: {
            var side: ExprSide = .neither;
            for (f.args) |arg| side = mergeSide(side, exprSide(arg, left_count));
            break :blk side;
        },
        .in_list => |il| blk: {
            var side: ExprSide = exprSide(il.operand, left_count);
            for (il.list) |item| side = mergeSide(side, exprSide(item, left_count));
            break :blk side;
        },
        .case_ => |c| blk: {
            var side: ExprSide = .neither;
            for (c.when_clauses) |w| side = mergeSide(side, mergeSide(exprSide(w.cond, left_count), exprSide(w.then, left_count)));
            if (c.else_) |else_expr| side = mergeSide(side, exprSide(else_expr, left_count));
            break :blk side;
        },

        .int_lit, .float_lit, .str_lit, .bool_lit, .null_lit => .neither,
    };
}

fn mergeSide(a: ExprSide, b: ExprSide) ExprSide {
    if (a == .neither) return b;
    if (b == .neither) return a;
    if (a == b) return a;
    return .both_sides;
}

// Rebuilds expr subtracting left_count from every col_idx, so a right-side
// predicate from the merged join schema becomes valid in the right child's schema.
fn shiftRightColIdx(expr: lp.Expr, left_count: usize, a: std.mem.Allocator) !lp.Expr {
    return switch (expr) {
        .col_idx => |idx| blk: {
            std.debug.assert(idx >= left_count);
            break :blk lp.Expr{ .col_idx = idx - left_count };
        },
        .binary => |b| blk: {
            var tmp = try a.create(lp.Expr.Binary);
            tmp.op = b.op;
            tmp.left = try shiftRightColIdx(b.left, left_count, a);
            tmp.right = try shiftRightColIdx(b.right, left_count, a);
            break :blk lp.Expr{ .binary = tmp };
        },
        .unary => |u| blk: {
            var tmp = try a.create(lp.Expr.Unary);
            tmp.op = u.op;
            tmp.operand = try shiftRightColIdx(u.operand, left_count, a);
            break :blk lp.Expr{ .unary = tmp };
        },
        .cast => |c| blk: {
            const tmp = try a.create(lp.Expr.Cast);
            tmp.* = .{ .target_type = c.target_type, .operand = try shiftRightColIdx(c.operand, left_count, a) };
            break :blk lp.Expr{ .cast = tmp };
        },
        .is_null => |n| blk: {
            const tmp = try a.create(lp.Expr.IsNull);
            tmp.* = .{ .negated = n.negated, .operand = try shiftRightColIdx(n.operand, left_count, a) };
            break :blk lp.Expr{ .is_null = tmp };
        },
        .func_call => |f| blk: {
            const args = try a.alloc(lp.Expr, f.args.len);
            for (f.args, 0..) |arg, i| args[i] = try shiftRightColIdx(arg, left_count, a);
            const tmp = try a.create(lp.Expr.FuncCall);
            tmp.* = .{ .func = f.func, .args = args };
            break :blk lp.Expr{ .func_call = tmp };
        },
        .in_list => |il| blk: {
            const list = try a.alloc(lp.Expr, il.list.len);
            for (il.list, 0..) |item, i| list[i] = try shiftRightColIdx(item, left_count, a);
            const tmp = try a.create(lp.Expr.InList);
            tmp.* = .{ .operand = try shiftRightColIdx(il.operand, left_count, a), .list = list, .negated = il.negated };
            break :blk lp.Expr{ .in_list = tmp };
        },
        .case_ => |c| blk: {
            const whens = try a.alloc(lp.Expr.Case.WhenClause, c.when_clauses.len);
            for (c.when_clauses, 0..) |w, i| whens[i] = .{
                .cond = try shiftRightColIdx(w.cond, left_count, a),
                .then = try shiftRightColIdx(w.then, left_count, a),
            };
            const else_ = if (c.else_) |e| try shiftRightColIdx(e, left_count, a) else null;
            const tmp = try a.create(lp.Expr.Case);
            tmp.* = .{ .when_clauses = whens, .else_ = else_ };
            break :blk lp.Expr{ .case_ = tmp };
        },
        // Subqueries are opaque — their internal col_idx values refer to their
        // own schema, not the join's merged schema, so they must not be shifted.
        .subquery,
        .in_subquery,
        // Literals and outer refs have no join-side col_idx to shift.
        .outer_col_idx,
        .int_lit,
        .float_lit,
        .str_lit,
        .bool_lit,
        .null_lit,
        => expr,
    };
}

fn box(a: std.mem.Allocator, p: lp.LogicalPlan) !*lp.LogicalPlan {
    const ptr = try a.create(lp.LogicalPlan);
    ptr.* = p;
    return ptr;
}
