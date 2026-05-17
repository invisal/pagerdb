const std = @import("std");
const types = @import("types.zig");

pub const EvalValue = types.EvalValue;
pub const EvalError = types.EvalError;

// ── ScalarFunc ─────────────────────────────────────────────────────────────────

// Function pointer type for scalar function implementations.  Arguments are
// already-evaluated values; the evaluator handles expression evaluation before
// calling the function.
pub const EvalFn = *const fn (args: []const EvalValue) EvalError!EvalValue;

// A registered scalar function — mirrors the min_args/max_args pattern in
// vtable/root.zig so optional arguments (e.g. round(x) vs round(x, n)) work.
//
// short_circuit = true means the evaluator must not pre-evaluate all arguments.
// Instead it evaluates them one at a time and stops as soon as possible, calling
// eval with only the values it has accumulated so far (length 1, then 2, …).
// The function signals "stop here" by returning a non-null result from a prefix;
// "keep going" means returning null_.  COALESCE uses this to avoid evaluating
// unreachable arguments (which could otherwise raise errors like division by zero).
pub const ScalarFunc = struct {
    name: []const u8,
    min_args: usize,
    max_args: usize,
    eval: EvalFn,
    short_circuit: bool = false,
};

// ── Implementations ────────────────────────────────────────────────────────────

fn evalAbs(args: []const EvalValue) EvalError!EvalValue {
    return switch (args[0]) {
        .int => |n| .{ .int = if (n < 0) -n else n },
        .real => |x| .{ .real = @abs(x) },
        .null_ => .{ .null_ = {} },
        else => EvalError.TypeMismatch,
    };
}

// NULLIF(a, b): returns NULL if a equals b, otherwise returns a.
// Follows SQL three-valued logic: NULLIF(NULL, x) = NULL; NULLIF(x, NULL) = x.
fn evalNullIf(args: []const EvalValue) EvalError!EvalValue {
    if (args[0] == .null_) return .{ .null_ = {} };
    if (args[1] == .null_) return args[0];
    const equal = switch (args[0]) {
        .int => |a| switch (args[1]) {
            .int => |b| a == b,
            .real => |b| @as(f64, @floatFromInt(a)) == b,
            else => false,
        },
        .real => |a| switch (args[1]) {
            .real => |b| a == b,
            .int => |b| a == @as(f64, @floatFromInt(b)),
            else => false,
        },
        .text => |a| switch (args[1]) {
            .text => |b| std.mem.eql(u8, a, b),
            else => false,
        },
        .bool_ => |a| switch (args[1]) {
            .bool_ => |b| a == b,
            else => false,
        },
        .null_ => unreachable,
    };
    return if (equal) .{ .null_ = {} } else args[0];
}

// COALESCE(a, b, ...): returns the first non-NULL argument, or NULL if all are NULL.
fn evalCoalesce(args: []const EvalValue) EvalError!EvalValue {
    for (args) |a| {
        if (a != .null_) return a;
    }
    return .{ .null_ = {} };
}

// ── Registry ───────────────────────────────────────────────────────────────────
//
// To add a new built-in scalar function:
//   1. Write an implementation function above (fn evalXxx).
//   2. Add an entry to REGISTRY.
//   No other files need to change.

const REGISTRY = [_]ScalarFunc{
    .{ .name = "abs", .min_args = 1, .max_args = 1, .eval = &evalAbs },
    .{ .name = "nullif", .min_args = 2, .max_args = 2, .eval = &evalNullIf },
    .{ .name = "coalesce", .min_args = 1, .max_args = std.math.maxInt(usize), .eval = &evalCoalesce, .short_circuit = true },
};

pub fn find(name: []const u8) ?*const ScalarFunc {
    for (&REGISTRY) |*f| {
        if (std.ascii.eqlIgnoreCase(name, f.name)) return f;
    }
    return null;
}
