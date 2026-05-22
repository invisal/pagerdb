const std = @import("std");
const utils = @import("utils.zig");
const pp = @import("./../physical_plan.zig");
const lp = @import("./../logical_plan.zig");
const catalog = @import("./../../catalog.zig");
const ast = @import("./../ast.zig");
const index_key = @import("./../../index_key.zig");
const row = @import("./../../row.zig");

const KeyRange = pp.KeyRange;
const Expr = lp.Expr;
const IndexMeta = catalog.IndexMeta;

const splitConjuncts = utils.splitConjuncts;
const joinConjuncts = utils.joinConjuncts;

pub const RangeResult = struct {
    range: KeyRange,
    residual: ?Expr,
};

// Extract the range from predicate for the given index.
// Returns null if no conjunct in the predicate matches the index's leading column.
pub fn extractRange(alloc: std.mem.Allocator, predicate: Expr, index: IndexMeta) !?RangeResult {
    // Only single-column indexes are supported for now.
    if (index.col_indices.len != 1) return null;

    var conjuncts: std.ArrayListUnmanaged(Expr) = .empty;
    try splitConjuncts(alloc, predicate, &conjuncts);

    var residual: std.ArrayListUnmanaged(Expr) = .empty;

    var final_range: KeyRange = .{};
    for (conjuncts.items) |conjunct| {
        if (try tryExtractBound(alloc, conjunct, index)) |current_range| {
            if (current_range.lower) |new_lb| {
                if (final_range.lower) |existing_lb| {
                    const ord = index_key.compareKeys(new_lb.encoded, existing_lb.encoded);
                    // Keep the tighter lower bound. e.g. a > 10 AND a > 15 → keep a > 15.
                    // If equal value, exclusive is tighter: a >= 10 AND a > 10 → keep a > 10.
                    if (ord == .gt or (ord == .eq and !new_lb.inclusive)) {
                        final_range.lower = new_lb;
                    }
                } else {
                    final_range.lower = new_lb;
                }
            }

            if (current_range.upper) |new_up| {
                if (final_range.upper) |existing_up| {
                    // Keep the tighter upper bound. e.g. a < 15 AND a < 10 → keep a < 10.
                    // If equal value, exclusive is tighter: a <= 10 AND a < 10 → keep a < 10.
                    const ord = index_key.compareKeys(new_up.encoded, existing_up.encoded);
                    if (ord == .lt or (ord == .eq and !new_up.inclusive)) {
                        final_range.upper = new_up;
                    }
                } else {
                    final_range.upper = new_up;
                }
            }
        } else {
            try residual.append(alloc, conjunct);
        }
    }

    if (final_range.lower == null and final_range.upper == null) return null;

    return RangeResult{
        .residual = try joinConjuncts(alloc, residual.items),
        .range = final_range,
    };
}

pub fn tryExtractBound(alloc: std.mem.Allocator, expr: Expr, index: IndexMeta) !?KeyRange {
    return switch (expr) {
        .binary => |binary_expr| tryExtractBinaryExprBound(alloc, binary_expr.*, index),
        else => null,
    };
}

fn tryExtractBinaryExprBound(alloc: std.mem.Allocator, expr: Expr.Binary, index: IndexMeta) !?KeyRange {
    const lit, const op = if (expr.left == .col_idx and expr.left.col_idx == index.col_indices[0])
        .{ expr.right, expr.op }
    else if (expr.right == .col_idx and expr.right.col_idx == index.col_indices[0])
        .{ expr.left, flipOp(expr.op) }
    else
        return null;

    const val: row.Value = switch (lit) {
        .int_lit => |v| row.Value{ .int = v },
        .float_lit => |v| row.Value{ .real = v },
        .str_lit => |v| row.Value{ .text = v },
        else => return null,
    };

    var buf: [index_key.MAX_KEY_LEN]u8 = undefined;
    const encoded_size = index_key.encodeKeyWithDirections(&.{val}, index.col_desc, &buf);
    const encoded = try alloc.dupe(u8, buf[0..encoded_size]);

    return switch (op) {
        .eq => KeyRange{
            .lower = .{ .encoded = encoded, .inclusive = true },
            .upper = .{ .encoded = encoded, .inclusive = true },
        },
        .gt => KeyRange{
            .lower = .{ .encoded = encoded, .inclusive = false },
        },
        .gte => KeyRange{
            .lower = .{ .encoded = encoded, .inclusive = true },
        },
        .lt => KeyRange{
            .upper = .{ .encoded = encoded, .inclusive = false },
        },
        .lte => KeyRange{ .upper = .{ .encoded = encoded, .inclusive = true } },
        else => null,
    };
}

// ------------------------------------------
// Helper Functions
// ------------------------------------------
fn flipOp(op: ast.BinaryOp) ast.BinaryOp {
    return switch (op) {
        .lt => .gt,
        .lte => .gte,
        .gt => .lt,
        .gte => .lte,
        .eq => .eq,
        else => op,
    };
}
