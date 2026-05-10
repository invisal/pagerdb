const std = @import("std");
const row_mod = @import("../row.zig");

pub const Value = row_mod.Value;

// ── AggFunc ────────────────────────────────────────────────────────────────────

// A stateless vtable describing an aggregate function.
// State is a bare *anyopaque allocated by init() and owned by the caller
// (AggregateCursor keeps one per group), so AggFunc itself is a
// compile-time constant shared across all groups and all queries.
pub const AggFunc = struct {
    name: []const u8,
    // Allocates and zeroes a fresh state for one group.
    init: *const fn (alloc: std.mem.Allocator) anyerror!*anyopaque,
    // Folds one input value into the group state.  val == null means COUNT(*).
    // alloc must be the same arena used for init() and finalize().
    step: *const fn (state: *anyopaque, val: ?Value, alloc: std.mem.Allocator) anyerror!void,
    // Produces the final result from the group state.
    finalize: *const fn (state: *anyopaque, alloc: std.mem.Allocator) anyerror!Value,
};

// ── COUNT ──────────────────────────────────────────────────────────────────────

const Count = struct {
    n: i64,

    fn init(alloc: std.mem.Allocator) !*anyopaque {
        const s = try alloc.create(Count);
        s.* = .{ .n = 0 };
        return s;
    }

    // val == null means COUNT(*) — count every row regardless of value.
    // val == .null means COUNT(col) with a SQL NULL — skip it (SQL standard).
    fn step(state: *anyopaque, val: ?Value, _: std.mem.Allocator) !void {
        const s: *Count = @ptrCast(@alignCast(state));
        if (val == null) {
            s.n += 1;
        } else switch (val.?) {
            .null => {},
            else => s.n += 1,
        }
    }

    fn finalize(state: *anyopaque, _: std.mem.Allocator) !Value {
        const s: *Count = @ptrCast(@alignCast(state));
        return .{ .int = s.n };
    }
};

pub const CountFunc = AggFunc{ .name = "count", .init = Count.init, .step = Count.step, .finalize = Count.finalize };

// ── SUM ───────────────────────────────────────────────────────────────────────

const Sum = struct {
    saw_any: bool,
    saw_real: bool,
    int_sum: i64,
    real_sum: f64,

    fn init(alloc: std.mem.Allocator) !*anyopaque {
        const s = try alloc.create(Sum);
        s.* = .{ .saw_any = false, .saw_real = false, .int_sum = 0, .real_sum = 0 };
        return s;
    }

    fn step(state: *anyopaque, val: ?Value, _: std.mem.Allocator) !void {
        const s: *Sum = @ptrCast(@alignCast(state));
        if (val == null) return error.TypeMismatch;

        switch (val.?) {
            .null => {},
            .int => |n| {
                s.saw_any = true;
                if (s.saw_real) {
                    s.real_sum += @floatFromInt(n);
                } else {
                    s.int_sum += n;
                }
            },
            .real => |f| {
                if (!s.saw_real) {
                    s.real_sum = @floatFromInt(s.int_sum);
                    s.saw_real = true;
                }
                s.saw_any = true;
                s.real_sum += f;
            },
            else => return error.TypeMismatch,
        }
    }

    fn finalize(state: *anyopaque, _: std.mem.Allocator) !Value {
        const s: *Sum = @ptrCast(@alignCast(state));
        if (!s.saw_any) return .null;
        if (s.saw_real) return .{ .real = s.real_sum };
        return .{ .int = s.int_sum };
    }
};

pub const SumFunc = AggFunc{ .name = "sum", .init = Sum.init, .step = Sum.step, .finalize = Sum.finalize };

// ── AVG ───────────────────────────────────────────────────────────────────────

const Avg = struct {
    count: u64,
    sum: f64,

    fn init(alloc: std.mem.Allocator) !*anyopaque {
        const s = try alloc.create(Avg);
        s.* = .{ .count = 0, .sum = 0 };
        return s;
    }

    fn step(state: *anyopaque, val: ?Value, _: std.mem.Allocator) !void {
        const s: *Avg = @ptrCast(@alignCast(state));
        if (val == null) return error.TypeMismatch;

        switch (val.?) {
            .null => {},
            .int => |n| {
                s.sum += @floatFromInt(n);
                s.count += 1;
            },
            .real => |f| {
                s.sum += f;
                s.count += 1;
            },
            else => return error.TypeMismatch,
        }
    }

    fn finalize(state: *anyopaque, _: std.mem.Allocator) !Value {
        const s: *Avg = @ptrCast(@alignCast(state));
        if (s.count == 0) return .null;
        return .{ .real = s.sum / @as(f64, @floatFromInt(s.count)) };
    }
};

pub const AvgFunc = AggFunc{ .name = "avg", .init = Avg.init, .step = Avg.step, .finalize = Avg.finalize };

// ── MIN / MAX ────────────────────────────────────────────────────────────────

const Min = struct {
    saw_any: bool,
    saw_real: bool,
    int_val: i64,
    real_val: f64,

    fn init(alloc: std.mem.Allocator) !*anyopaque {
        const s = try alloc.create(Min);
        s.* = .{ .saw_any = false, .saw_real = false, .int_val = 0, .real_val = 0 };
        return s;
    }

    fn step(state: *anyopaque, val: ?Value, _: std.mem.Allocator) !void {
        const s: *Min = @ptrCast(@alignCast(state));
        if (val == null) return error.TypeMismatch;

        switch (val.?) {
            .null => {},
            .int => |n| {
                if (!s.saw_any) {
                    s.saw_any = true;
                    s.int_val = n;
                    return;
                }
                if (s.saw_real) {
                    const nf: f64 = @floatFromInt(n);
                    if (nf < s.real_val) s.real_val = nf;
                } else if (n < s.int_val) {
                    s.int_val = n;
                }
            },
            .real => |f| {
                if (!s.saw_any) {
                    s.saw_any = true;
                    s.saw_real = true;
                    s.real_val = f;
                    return;
                }
                if (!s.saw_real) {
                    s.real_val = @floatFromInt(s.int_val);
                    s.saw_real = true;
                }
                if (f < s.real_val) s.real_val = f;
            },
            else => return error.TypeMismatch,
        }
    }

    fn finalize(state: *anyopaque, _: std.mem.Allocator) !Value {
        const s: *Min = @ptrCast(@alignCast(state));
        if (!s.saw_any) return .null;
        if (s.saw_real) return .{ .real = s.real_val };
        return .{ .int = s.int_val };
    }
};

pub const MinFunc = AggFunc{ .name = "min", .init = Min.init, .step = Min.step, .finalize = Min.finalize };

const Max = struct {
    saw_any: bool,
    saw_real: bool,
    int_val: i64,
    real_val: f64,

    fn init(alloc: std.mem.Allocator) !*anyopaque {
        const s = try alloc.create(Max);
        s.* = .{ .saw_any = false, .saw_real = false, .int_val = 0, .real_val = 0 };
        return s;
    }

    fn step(state: *anyopaque, val: ?Value, _: std.mem.Allocator) !void {
        const s: *Max = @ptrCast(@alignCast(state));
        if (val == null) return error.TypeMismatch;

        switch (val.?) {
            .null => {},
            .int => |n| {
                if (!s.saw_any) {
                    s.saw_any = true;
                    s.int_val = n;
                    return;
                }
                if (s.saw_real) {
                    const nf: f64 = @floatFromInt(n);
                    if (nf > s.real_val) s.real_val = nf;
                } else if (n > s.int_val) {
                    s.int_val = n;
                }
            },
            .real => |f| {
                if (!s.saw_any) {
                    s.saw_any = true;
                    s.saw_real = true;
                    s.real_val = f;
                    return;
                }
                if (!s.saw_real) {
                    s.real_val = @floatFromInt(s.int_val);
                    s.saw_real = true;
                }
                if (f > s.real_val) s.real_val = f;
            },
            else => return error.TypeMismatch,
        }
    }

    fn finalize(state: *anyopaque, _: std.mem.Allocator) !Value {
        const s: *Max = @ptrCast(@alignCast(state));
        if (!s.saw_any) return .null;
        if (s.saw_real) return .{ .real = s.real_val };
        return .{ .int = s.int_val };
    }
};

pub const MaxFunc = AggFunc{ .name = "max", .init = Max.init, .step = Max.step, .finalize = Max.finalize };

// ── Registry ───────────────────────────────────────────────────────────────────

pub const REGISTRY = [_]AggFunc{ CountFunc, SumFunc, AvgFunc, MinFunc, MaxFunc };

pub fn find(name: []const u8) ?*const AggFunc {
    for (&REGISTRY) |*f| {
        if (std.ascii.eqlIgnoreCase(f.name, name)) return f;
    }
    return null;
}
