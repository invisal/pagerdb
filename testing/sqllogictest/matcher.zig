// Pure comparison helpers for sqllogictest results.
//
// This module is intentionally free of I/O and printing — it only decides
// whether a backend result matches the expectation from a parsed SLT record.
// Error-reporting and agent-report generation stay in runner.zig.

const std = @import("std");
const parser = @import("parser.zig");
const core = @import("core");

const Allocator = std.mem.Allocator;
const ExecResult = core.ExecResult;

// ── Public result types ───────────────────────────────────────────────────────

pub const MatchResult = union(enum) {
    match,
    mismatch: Mismatch,
};

pub const Mismatch = union(enum) {
    // Statement: expected ok but got an error, or vice-versa.
    statement: struct { want_err: bool, got_msg: ?[]const u8 },
    // Query: wrong number of result values.
    count: struct { expected: usize, got: usize },
    // Query: specific cell value differed.
    value: struct { index: usize, expected: []const u8, got: []const u8 },
    // Query: hash count or digest mismatched.
    hash: struct { expected_md5: []const u8, got_md5: [32]u8, count_ok: bool },
    // Query: the backend returned a SQL error instead of rows.
    sql_error: []const u8,
};

// ── Public API ────────────────────────────────────────────────────────────────

pub fn matchStatement(exec_result: ExecResult, expected: parser.StatementExpected) MatchResult {
    const got_err = exec_result == .err;
    const want_err = expected == .err;
    if (got_err == want_err) return .match;
    const got_msg: ?[]const u8 = if (got_err) exec_result.err.message else null;
    return .{ .mismatch = .{ .statement = .{ .want_err = want_err, .got_msg = got_msg } } };
}

// Compares a flat row-major slice of formatted string values against the
// expected result for a query record.
//
// values is mutable because sorting (rowsort / valuesort) is applied in-place
// before comparison — the same approach used by the original SQLite SLT tool.
// The caller retains ownership of all memory; this function does not allocate
// except for the MD5 computation scratch space (stack-allocated internally).
pub fn matchQuery(
    values: [][]const u8,
    col_count: usize,
    expected: parser.QueryExpected,
    sort_mode: parser.SortMode,
) MatchResult {
    switch (sort_mode) {
        .none => {},
        .row_sort => sortRows(values, col_count),
        .value_sort => sortValues(values),
    }

    switch (expected) {
        .values => |exp_values| {
            if (values.len != exp_values.len) {
                return .{ .mismatch = .{ .count = .{ .expected = exp_values.len, .got = values.len } } };
            }
            for (values, exp_values, 0..) |got, exp, idx| {
                if (!std.mem.eql(u8, got, exp)) {
                    return .{ .mismatch = .{ .value = .{ .index = idx, .expected = exp, .got = got } } };
                }
            }
            return .match;
        },
        .hash => |h| {
            if (values.len != h.count) {
                return .{ .mismatch = .{ .hash = .{
                    .expected_md5 = h.md5,
                    .got_md5 = md5OfValues(values),
                    .count_ok = false,
                } } };
            }
            const digest = md5OfValues(values);
            if (!std.mem.eql(u8, &digest, h.md5)) {
                return .{ .mismatch = .{ .hash = .{
                    .expected_md5 = h.md5,
                    .got_md5 = digest,
                    .count_ok = true,
                } } };
            }
            return .match;
        },
    }
}

// ── Sorting ───────────────────────────────────────────────────────────────────

// Groups values into rows of col_count and sorts them lexicographically.
pub fn sortRows(values: [][]const u8, col_count: usize) void {
    if (col_count == 0 or values.len < col_count * 2) return;
    const row_count = values.len / col_count;
    var i: usize = 1;
    while (i < row_count) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            const prev = values[(j - 1) * col_count .. j * col_count];
            const curr = values[j * col_count .. (j + 1) * col_count];
            if (compareRows(prev, curr) != .gt) break;
            for (0..col_count) |k| {
                const tmp = values[(j - 1) * col_count + k];
                values[(j - 1) * col_count + k] = values[j * col_count + k];
                values[j * col_count + k] = tmp;
            }
        }
    }
}

fn compareRows(a: []const []const u8, b: []const []const u8) std.math.Order {
    for (a, b) |av, bv| {
        const ord = std.mem.order(u8, av, bv);
        if (ord != .eq) return ord;
    }
    return .eq;
}

pub fn sortValues(values: [][]const u8) void {
    std.sort.block([]const u8, values, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

// ── Hashing ───────────────────────────────────────────────────────────────────

// Computes MD5 of all values joined by newlines, returned as a 32-char lowercase
// hex string matching the format used by the original SQLite sqllogictest tool.
pub fn md5OfValues(values: []const []const u8) [32]u8 {
    const Md5 = std.crypto.hash.Md5;
    var hasher = Md5.init(.{});
    for (values) |v| {
        hasher.update(v);
        hasher.update("\n");
    }
    var digest: [Md5.digest_length]u8 = undefined;
    hasher.final(&digest);

    var hex: [32]u8 = undefined;
    for (digest, 0..) |byte, idx| {
        _ = std.fmt.bufPrint(hex[idx * 2 .. idx * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
    }
    return hex;
}
