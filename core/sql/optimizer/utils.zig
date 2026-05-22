// Shared utilities used by multiple optimizer passes.

const std = @import("std");
const lp = @import("../logical_plan.zig");

/// Flattens an AND-tree into a list of independent conjuncts.
/// A "conjunct" is one independent clause of an AND expression.
/// Only splits on AND; everything else is treated as a single opaque conjunct.
pub fn splitConjuncts(a: std.mem.Allocator, expr: lp.Expr, out: *std.ArrayListUnmanaged(lp.Expr)) !void {
    if (expr == .binary and expr.binary.op == .and_) {
        try splitConjuncts(a, expr.binary.left, out);
        try splitConjuncts(a, expr.binary.right, out);
    } else {
        try out.append(a, expr);
    }
}

// Inverse of splitConjuncts: folds [a, b, c] back into a AND (b AND c).
// Returns null for an empty list, used for optional join conditions.
pub fn joinConjuncts(a: std.mem.Allocator, list: []const lp.Expr) !?lp.Expr {
    if (list.len == 0) return null;
    if (list.len == 1) return list[0];
    var result = list[0];
    for (list[1..]) |e| {
        const node = try a.create(lp.Expr.Binary);
        node.* = .{ .op = .and_, .left = result, .right = e };
        result = .{ .binary = node };
    }
    return result;
}
