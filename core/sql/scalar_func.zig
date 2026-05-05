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
pub const ScalarFunc = struct {
    name: []const u8,
    min_args: usize,
    max_args: usize,
    eval: EvalFn,
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

// ── Registry ───────────────────────────────────────────────────────────────────
//
// To add a new built-in scalar function:
//   1. Write an implementation function above (fn evalXxx).
//   2. Add an entry to REGISTRY.
//   No other files need to change.

const REGISTRY = [_]ScalarFunc{
    .{ .name = "abs", .min_args = 1, .max_args = 1, .eval = &evalAbs },
};

pub fn find(name: []const u8) ?*const ScalarFunc {
    for (&REGISTRY) |*f| {
        if (std.ascii.eqlIgnoreCase(name, f.name)) return f;
    }
    return null;
}
