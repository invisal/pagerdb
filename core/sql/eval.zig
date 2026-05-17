const std = @import("std");
const row = @import("../row.zig");
const ee = @import("exec_expr.zig");
const sf = @import("scalar_func.zig");
const types = @import("types.zig");

pub const EvalValue = types.EvalValue;
pub const EvalError = types.EvalError;
pub const ExecExpr = ee.ExecExpr;

// Execution context passed through evalExpr and cursor next() calls.
// outer: the current outer query row, used to evaluate outer_col_idx nodes
//        in correlated subqueries.  Empty slice for top-level queries.
// alloc: arena allocator for any allocations evalExpr needs to make
//        (CAST to text, etc.).
pub const EvalContext = struct {
    outer: []const row.Value,
    alloc: std.mem.Allocator,
};

pub fn evalExpr(
    expr: ExecExpr,
    row_values: []const row.Value,
    ctx: EvalContext,
) anyerror!EvalValue {
    return switch (expr) {
        .int_lit => |v| .{ .int = v },
        .float_lit => |v| .{ .real = v },
        .str_lit => |v| .{ .text = v },
        .bool_lit => |v| .{ .bool_ = v },
        .null_lit => .{ .null_ = {} },
        .col_idx => |i| rowValToEval(row_values[i]),
        .outer_col_idx => |i| rowValToEval(ctx.outer[i]),
        .binary => |b| try evalBinary(b, row_values, ctx),
        .unary => |u| try evalUnary(u, row_values, ctx),
        .func_call => |f| try evalFunc(f, row_values, ctx),
        .cast => |c| try evalCast(c, row_values, ctx),
        .in_list => |il| try evalInList(il, row_values, ctx),
        .case_ => |c| try evalCase(c, row_values, ctx),
        .is_null => |n| blk: {
            const v = try evalExpr(n.operand, row_values, ctx);
            const is_null_val = v == .null_;
            break :blk .{ .bool_ = if (n.negated) !is_null_val else is_null_val };
        },
        .subquery => |s| blk: {
            // Execute the inner plan.  outer_col_idx nodes inside it will resolve
            // against row_values (the current outer row at this call site).
            const result = try s.exec_fn(s.inner, s.db, row_values, ctx.alloc);
            break :blk result orelse .{ .null_ = {} };
        },
    };
}

// SQL truthiness rules:
//   - Boolean: use the value directly
//   - Integer: non-zero is true, zero is false
//   - NULL: always false (this is for WHERE clause filtering; NULL in a
//     SELECT result is still displayed as NULL)
//   - Everything else (text, real): true
pub fn isTruthy(v: EvalValue) bool {
    return switch (v) {
        .bool_ => |b| b,
        .int => |n| n != 0,
        .null_ => false,
        else => true,
    };
}

pub fn rowValToEval(v: row.Value) EvalValue {
    return switch (v) {
        .null => .{ .null_ = {} },
        .int => |n| .{ .int = n },
        .real => |f| .{ .real = f },
        .text => |s| .{ .text = s },
        .blob => |b| .{ .text = b },
    };
}

fn evalBinary(
    b: *ExecExpr.Binary,
    row_values: []const row.Value,
    ctx: EvalContext,
) anyerror!EvalValue {
    // SQL uses three-valued logic (TRUE/FALSE/NULL).  For AND/OR we must
    // short-circuit correctly: a definite FALSE dominates AND, a definite TRUE
    // dominates OR, even when the other operand is NULL.
    //
    //   NULL AND FALSE = FALSE   (not NULL — FALSE dominates)
    //   NULL AND TRUE  = NULL
    //   NULL OR  TRUE  = TRUE    (not NULL — TRUE dominates)
    //   NULL OR  FALSE = NULL
    if (b.op == .and_) {
        const left = try evalExpr(b.left, row_values, ctx);
        // Definite false on the left: short-circuit without evaluating right.
        if (left != .null_ and !isTruthy(left)) return .{ .bool_ = false };
        const right = try evalExpr(b.right, row_values, ctx);
        // Definite false on the right (covers NULL AND FALSE = FALSE).
        if (right != .null_ and !isTruthy(right)) return .{ .bool_ = false };
        if (left == .null_ or right == .null_) return .{ .null_ = {} };
        return .{ .bool_ = true };
    }
    if (b.op == .or_) {
        const left = try evalExpr(b.left, row_values, ctx);
        // Definite true on the left: short-circuit without evaluating right.
        if (left != .null_ and isTruthy(left)) return .{ .bool_ = true };
        const right = try evalExpr(b.right, row_values, ctx);
        // Definite true on the right (covers NULL OR TRUE = TRUE).
        if (right != .null_ and isTruthy(right)) return .{ .bool_ = true };
        if (left == .null_ or right == .null_) return .{ .null_ = {} };
        return .{ .bool_ = false };
    }

    const left = try evalExpr(b.left, row_values, ctx);
    const right = try evalExpr(b.right, row_values, ctx);

    if (left == .null_ or right == .null_) return .{ .null_ = {} };

    return switch (b.op) {
        .eq => .{ .bool_ = compareValues(left, right) == .eq },
        .neq => .{ .bool_ = compareValues(left, right) != .eq },
        .lt => .{ .bool_ = compareValues(left, right) == .lt },
        .lte => .{ .bool_ = compareValues(left, right) != .gt },
        .gt => .{ .bool_ = compareValues(left, right) == .gt },
        .gte => .{ .bool_ = compareValues(left, right) != .lt },
        .add => try evalArith(.add, left, right),
        .sub => try evalArith(.sub, left, right),
        .mul => try evalArith(.mul, left, right),
        .div => try evalArith(.div, left, right),
        .and_, .or_ => unreachable,
    };
}

// SQL IN semantics (three-valued logic):
//   - If operand is NULL → NULL
//   - If any list element equals operand → TRUE (or FALSE if negated)
//   - If any list element is NULL (and none matched) → NULL
//   - Otherwise → FALSE (or TRUE if negated)
fn evalInList(
    il: *ExecExpr.InList,
    row_values: []const row.Value,
    ctx: EvalContext,
) anyerror!EvalValue {
    const operand = try evalExpr(il.operand, row_values, ctx);
    if (operand == .null_) return .{ .null_ = {} };

    var saw_null = false;
    for (il.list) |item| {
        const val = try evalExpr(item, row_values, ctx);
        if (val == .null_) {
            saw_null = true;
            continue;
        }
        if (compareValues(operand, val) == .eq) {
            return .{ .bool_ = !il.negated };
        }
    }
    if (saw_null) return .{ .null_ = {} };
    return .{ .bool_ = il.negated };
}

fn evalUnary(
    u: *ExecExpr.Unary,
    row_values: []const row.Value,
    ctx: EvalContext,
) anyerror!EvalValue {
    const operand = try evalExpr(u.operand, row_values, ctx);
    return switch (u.op) {
        .not => switch (operand) {
            .bool_ => |b| .{ .bool_ = !b },
            .null_ => .{ .null_ = {} },
            else => EvalError.TypeMismatch,
        },
        .neg => switch (operand) {
            .int => |n| .{ .int = -n },
            .real => |f| .{ .real = -f },
            .null_ => .{ .null_ = {} },
            else => EvalError.TypeMismatch,
        },
    };
}

fn evalCast(
    c: *ExecExpr.Cast,
    row_values: []const row.Value,
    ctx: EvalContext,
) anyerror!EvalValue {
    const val = try evalExpr(c.operand, row_values, ctx);
    if (val == .null_) return .{ .null_ = {} };
    return switch (c.target_type) {
        .int => switch (val) {
            .int => val,
            .real => |f| .{ .int = @intFromFloat(f) },
            .bool_ => |b| .{ .int = if (b) 1 else 0 },
            .text => |s| .{ .int = std.fmt.parseInt(i64, s, 10) catch return EvalError.TypeMismatch },
            .null_ => unreachable,
        },
        .real => switch (val) {
            .real => val,
            .int => |n| .{ .real = @floatFromInt(n) },
            .bool_ => |b| .{ .real = if (b) 1.0 else 0.0 },
            .text => |s| .{ .real = std.fmt.parseFloat(f64, s) catch return EvalError.TypeMismatch },
            .null_ => unreachable,
        },
        .text, .blob => switch (val) {
            .text => val,
            .int => |n| .{ .text = try std.fmt.allocPrint(ctx.alloc, "{d}", .{n}) },
            .real => |f| .{ .text = try std.fmt.allocPrint(ctx.alloc, "{d}", .{f}) },
            .bool_ => |b| .{ .text = if (b) "1" else "0" },
            .null_ => unreachable,
        },
    };
}

// Searched CASE: evaluate each WHEN condition in order; return the THEN value
// for the first true condition.  If none match, return the ELSE value (or NULL).
fn evalCase(
    c: *ExecExpr.Case,
    row_values: []const row.Value,
    ctx: EvalContext,
) anyerror!EvalValue {
    for (c.when_clauses) |w| {
        const cond = try evalExpr(w.cond, row_values, ctx);
        if (isTruthy(cond)) return evalExpr(w.then, row_values, ctx);
    }
    return if (c.else_) |e| evalExpr(e, row_values, ctx) else .{ .null_ = {} };
}

fn evalFunc(
    f: *ExecExpr.FuncCall,
    row_values: []const row.Value,
    ctx: EvalContext,
) anyerror!EvalValue {
    // short_circuit functions (e.g. COALESCE) must not have all arguments
    // pre-evaluated: evaluate one at a time and stop as soon as the function
    // returns a non-null result.  The mechanism lives here because evalExpr is
    // only visible in this file; the *policy* (which functions opt in) is on
    // ScalarFunc.short_circuit in scalar_func.zig.
    if (f.func.short_circuit) {
        for (f.args) |arg| {
            const v = try evalExpr(arg, row_values, ctx);
            const result = try f.func.eval(&.{v});
            if (result != .null_) return result;
        }
        return .{ .null_ = {} };
    }

    // Evaluate each argument expression, then hand the values to the function
    // implementation.  A small stack buffer covers the common case of low-arity
    // functions without heap allocation.
    var buf: [8]EvalValue = undefined;
    const evaled = buf[0..f.args.len];
    for (f.args, 0..) |arg, i| evaled[i] = try evalExpr(arg, row_values, ctx);
    return f.func.eval(evaled);
}

fn compareValues(a: EvalValue, b: EvalValue) std.math.Order {
    return switch (a) {
        .int => |av| switch (b) {
            .int => |bv| std.math.order(av, bv),
            .real => |bv| std.math.order(@as(f64, @floatFromInt(av)), bv),
            else => .lt,
        },
        .real => |av| switch (b) {
            .real => |bv| std.math.order(av, bv),
            .int => |bv| std.math.order(av, @as(f64, @floatFromInt(bv))),
            else => .lt,
        },
        .text => |av| switch (b) {
            .text => |bv| std.mem.order(u8, av, bv),
            else => .lt,
        },
        .bool_ => |av| switch (b) {
            .bool_ => |bv| if (av == bv) .eq else if (!av) .lt else .gt,
            else => .lt,
        },
        .null_ => .lt,
    };
}

fn evalArith(op: @import("ast.zig").BinaryOp, a: EvalValue, b: EvalValue) anyerror!EvalValue {
    switch (a) {
        .int => |av| switch (b) {
            .int => |bv| return switch (op) {
                .add => .{ .int = av + bv },
                .sub => .{ .int = av - bv },
                .mul => .{ .int = av * bv },
                // SQLite returns NULL for division by zero rather than raising an error.
                .div => if (bv == 0) .{ .null_ = {} } else .{ .int = @divTrunc(av, bv) },
                else => EvalError.TypeMismatch,
            },
            .real => |bv| return evalArith(op, .{ .real = @as(f64, @floatFromInt(av)) }, .{ .real = bv }),
            else => return EvalError.TypeMismatch,
        },
        .real => |av| switch (b) {
            .real => |bv| return switch (op) {
                .add => .{ .real = av + bv },
                .sub => .{ .real = av - bv },
                .mul => .{ .real = av * bv },
                .div => if (bv == 0.0) .{ .null_ = {} } else .{ .real = av / bv },
                else => EvalError.TypeMismatch,
            },
            .int => |bv| return evalArith(op, .{ .real = av }, .{ .real = @as(f64, @floatFromInt(bv)) }),
            else => return EvalError.TypeMismatch,
        },
        else => return EvalError.TypeMismatch,
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────────

test "evalExpr literals" {
    const alloc = std.testing.allocator;
    const vals: []const row.Value = &.{};
    const ctx = EvalContext{ .outer = &.{}, .alloc = alloc };

    const v_int = try evalExpr(.{ .int_lit = 42 }, vals, ctx);
    const v_float = try evalExpr(.{ .float_lit = 3.14 }, vals, ctx);
    const v_str = try evalExpr(.{ .str_lit = "hi" }, vals, ctx);
    const v_bool = try evalExpr(.{ .bool_lit = true }, vals, ctx);
    const v_null = try evalExpr(.{ .null_lit = {} }, vals, ctx);

    try std.testing.expectEqual(@as(i64, 42), v_int.int);
    try std.testing.expectApproxEqAbs(3.14, v_float.real, 1e-9);
    try std.testing.expectEqualStrings("hi", v_str.text);
    try std.testing.expect(v_bool.bool_);
    try std.testing.expect(v_null == .null_);
}

test "evalExpr col_idx reads from row" {
    const alloc = std.testing.allocator;
    const ctx = EvalContext{ .outer = &.{}, .alloc = alloc };
    const vals = [_]row.Value{
        .{ .int = 99 },
        .null,
    };
    const v0 = try evalExpr(.{ .col_idx = 0 }, &vals, ctx);
    const v1 = try evalExpr(.{ .col_idx = 1 }, &vals, ctx);
    try std.testing.expectEqual(@as(i64, 99), v0.int);
    try std.testing.expect(v1 == .null_);
}

test "evalExpr outer_col_idx reads from outer row" {
    const alloc = std.testing.allocator;
    const outer = [_]row.Value{.{ .int = 77 }};
    const ctx = EvalContext{ .outer = &outer, .alloc = alloc };
    const vals: []const row.Value = &.{};
    const v = try evalExpr(.{ .outer_col_idx = 0 }, vals, ctx);
    try std.testing.expectEqual(@as(i64, 77), v.int);
}

test "evalExpr comparison operators" {
    const alloc = std.testing.allocator;
    const vals: []const row.Value = &.{};
    const ctx = EvalContext{ .outer = &.{}, .alloc = alloc };

    var b_eq = ExecExpr.Binary{ .op = .eq, .left = .{ .int_lit = 5 }, .right = .{ .int_lit = 5 } };
    var b_neq = ExecExpr.Binary{ .op = .neq, .left = .{ .int_lit = 5 }, .right = .{ .int_lit = 6 } };
    var b_lt = ExecExpr.Binary{ .op = .lt, .left = .{ .int_lit = 3 }, .right = .{ .int_lit = 5 } };

    try std.testing.expect((try evalExpr(.{ .binary = &b_eq }, vals, ctx)).bool_);
    try std.testing.expect((try evalExpr(.{ .binary = &b_neq }, vals, ctx)).bool_);
    try std.testing.expect((try evalExpr(.{ .binary = &b_lt }, vals, ctx)).bool_);
}

test "evalExpr arithmetic" {
    const alloc = std.testing.allocator;
    const vals: []const row.Value = &.{};
    const ctx = EvalContext{ .outer = &.{}, .alloc = alloc };

    var b_add = ExecExpr.Binary{ .op = .add, .left = .{ .int_lit = 3 }, .right = .{ .int_lit = 4 } };
    var b_div = ExecExpr.Binary{ .op = .div, .left = .{ .int_lit = 10 }, .right = .{ .int_lit = 0 } };

    try std.testing.expectEqual(@as(i64, 7), (try evalExpr(.{ .binary = &b_add }, vals, ctx)).int);
    try std.testing.expect((try evalExpr(.{ .binary = &b_div }, vals, ctx)) == .null_);
}

test "evalExpr NULL propagation" {
    const alloc = std.testing.allocator;
    const vals = [_]row.Value{.null};
    const ctx = EvalContext{ .outer = &.{}, .alloc = alloc };
    var b = ExecExpr.Binary{ .op = .eq, .left = .{ .col_idx = 0 }, .right = .{ .int_lit = 5 } };
    const result = try evalExpr(.{ .binary = &b }, &vals, ctx);
    try std.testing.expect(result == .null_);
}

test "abs() on integers" {
    const alloc = std.testing.allocator;
    const vals: []const row.Value = &.{};
    const ctx = EvalContext{ .outer = &.{}, .alloc = alloc };
    var args_neg = [_]ExecExpr{.{ .int_lit = -42 }};
    var args_pos = [_]ExecExpr{.{ .int_lit = 7 }};
    var f_neg = ExecExpr.FuncCall{ .func = sf.find("abs").?, .args = &args_neg };
    var f_pos = ExecExpr.FuncCall{ .func = sf.find("abs").?, .args = &args_pos };
    try std.testing.expectEqual(@as(i64, 42), (try evalExpr(.{ .func_call = &f_neg }, vals, ctx)).int);
    try std.testing.expectEqual(@as(i64, 7), (try evalExpr(.{ .func_call = &f_pos }, vals, ctx)).int);
}

test "abs() on reals" {
    const alloc = std.testing.allocator;
    const vals: []const row.Value = &.{};
    const ctx = EvalContext{ .outer = &.{}, .alloc = alloc };
    var args = [_]ExecExpr{.{ .float_lit = -3.14 }};
    var f = ExecExpr.FuncCall{ .func = sf.find("abs").?, .args = &args };
    const result = try evalExpr(.{ .func_call = &f }, vals, ctx);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), result.real, 1e-9);
}

test "abs() on NULL" {
    const alloc = std.testing.allocator;
    const vals: []const row.Value = &.{};
    const ctx = EvalContext{ .outer = &.{}, .alloc = alloc };
    var args = [_]ExecExpr{.{ .null_lit = {} }};
    var f = ExecExpr.FuncCall{ .func = sf.find("abs").?, .args = &args };
    const result = try evalExpr(.{ .func_call = &f }, vals, ctx);
    try std.testing.expect(result == .null_);
}
