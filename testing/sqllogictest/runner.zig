// Executes sqllogictest records against an in-memory VisalDB instance.
//
// Each .slt file gets a fresh database so tests are fully isolated.
// Statements check for expected success/failure; queries collect result
// values as strings, optionally sort them, and compare against expected.

const std = @import("std");
const core = @import("core");
const parser = @import("parser.zig");

const Allocator = std.mem.Allocator;
const Database = core.Database;
const InMemoryPager = core.InMemoryPager;
const execute = core.execute;
const Dir = std.Io.Dir;

// Engines we identify as. "postgresql" is included so that onlyif/skipif
// directives written for Postgres apply to us too — we target SQL compatibility
// with general ANSI SQL and PostgreSQL, not MySQL or SQLite dialects.
const ENGINES = [_][]const u8{ "pagerdb", "postgresql" };

fn engineMatches(engine: []const u8) bool {
    for (ENGINES) |e| {
        if (std.mem.eql(u8, engine, e)) return true;
    }
    return false;
}

pub const RunResult = struct {
    passed: usize,
    failed: usize,
};

// show_errors: print up to this many individual failure messages per file.
// 0 = suppress all individual failure output (summary-only mode).
pub fn runFile(alloc: Allocator, io: std.Io, path: []const u8, show_errors: usize) !RunResult {
    const std_file = try Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer std_file.close(io);

    const file_len = try std_file.length(io);
    const content = try alloc.alloc(u8, file_len);
    defer alloc.free(content);
    _ = try std_file.readPositionalAll(io, content, 0);

    var parsed = try parser.parse(alloc, content);
    defer parsed.deinit();

    const db = try Database.init(try InMemoryPager.create(alloc), alloc);
    defer db.close();

    var result = RunResult{ .passed = 0, .failed = 0 };
    var failures_shown: usize = 0;
    var skip_next = false;

    for (parsed.records) |record| {
        switch (record) {
            .skipif => |engine| {
                if (engineMatches(engine)) skip_next = true;
                continue;
            },
            .onlyif => |engine| {
                if (!engineMatches(engine)) skip_next = true;
                continue;
            },
            .statement => |stmt| {
                if (skip_next) {
                    skip_next = false;
                    continue;
                }
                const print_err = show_errors > 0 and failures_shown < show_errors;
                const ok = try runStatement(alloc, db, path, stmt, print_err);
                if (ok) {
                    result.passed += 1;
                } else {
                    if (print_err) failures_shown += 1;
                    result.failed += 1;
                }
            },
            .query => |qry| {
                if (skip_next) {
                    skip_next = false;
                    continue;
                }
                const print_err = show_errors > 0 and failures_shown < show_errors;
                const ok = try runQuery(alloc, db, path, qry, print_err);
                if (ok) {
                    result.passed += 1;
                } else {
                    if (print_err) failures_shown += 1;
                    result.failed += 1;
                }
            },
        }
    }

    if (show_errors > 0 and result.failed > failures_shown) {
        std.debug.print("  ... and {d} more failure(s) not shown\n", .{result.failed - failures_shown});
    }

    return result;
}

fn runStatement(alloc: Allocator, db: *Database, path: []const u8, stmt: parser.StatementRecord, print_error: bool) !bool {
    var exec_result = try execute(alloc, db, stmt.sql);
    defer exec_result.deinit();

    const got_err = exec_result == .err;
    const want_err = stmt.expected == .err;

    if (got_err != want_err) {
        if (print_error) {
            if (want_err) {
                std.debug.print("FAIL {s}:{d}: expected error but statement succeeded\n  sql: {s}\n", .{ path, stmt.line, stmt.sql });
            } else {
                std.debug.print("FAIL {s}:{d}: expected ok but got error: {s}\n  sql: {s}\n", .{ path, stmt.line, exec_result.err.message, stmt.sql });
            }
        }
        return false;
    }
    return true;
}

fn runQuery(alloc: Allocator, db: *Database, path: []const u8, qry: parser.QueryRecord, print_error: bool) !bool {
    var exec_result = try execute(alloc, db, qry.sql);
    defer exec_result.deinit();

    if (exec_result == .err) {
        if (print_error)
            std.debug.print("FAIL {s}:{d}: query returned error: {s}\n  sql: {s}\n", .{ path, qry.line, exec_result.err.message, qry.sql });
        return false;
    }
    if (exec_result != .result_set) {
        if (print_error)
            std.debug.print("FAIL {s}:{d}: query did not return a result set\n  sql: {s}\n", .{ path, qry.line, qry.sql });
        return false;
    }

    const rs = &exec_result.result_set;
    const col_count = rs.columns.len;

    // Collect all result values as formatted strings (flat list).
    var actual: std.ArrayList([]const u8) = .empty;
    defer {
        for (actual.items) |s| alloc.free(s);
        actual.deinit(alloc);
    }

    for (rs.rows) |row| {
        for (row.values) |val| {
            try actual.append(alloc, try formatValue(alloc, val));
        }
    }

    switch (qry.sort_mode) {
        .none => {},
        .row_sort => sortRows(actual.items, col_count),
        .value_sort => sortValues(actual.items),
    }

    switch (qry.expected) {
        .values => |expected| {
            if (actual.items.len != expected.len) {
                if (print_error)
                    std.debug.print("FAIL {s}:{d}: expected {d} values, got {d}\n  sql: {s}\n", .{
                        path, qry.line, expected.len, actual.items.len, qry.sql,
                    });
                return false;
            }
            for (actual.items, expected, 0..) |act, exp, idx| {
                if (!std.mem.eql(u8, act, exp)) {
                    if (print_error)
                        std.debug.print("FAIL {s}:{d}: value[{d}] expected '{s}', got '{s}'\n  sql: {s}\n", .{
                            path, qry.line, idx, exp, act, qry.sql,
                        });
                    return false;
                }
            }
        },
        .hash => |h| {
            if (actual.items.len != h.count) {
                if (print_error)
                    std.debug.print("FAIL {s}:{d}: expected {d} values, got {d}\n  sql: {s}\n", .{
                        path, qry.line, h.count, actual.items.len, qry.sql,
                    });
                return false;
            }
            const digest = md5OfValues(actual.items);
            if (!std.mem.eql(u8, &digest, h.md5)) {
                if (print_error)
                    std.debug.print("FAIL {s}:{d}: hash mismatch (expected {s}, got {s})\n  sql: {s}\n", .{
                        path, qry.line, h.md5, digest, qry.sql,
                    });
                return false;
            }
        },
    }

    return true;
}

fn formatValue(alloc: Allocator, val: anytype) ![]const u8 {
    return switch (val) {
        .null => alloc.dupe(u8, "NULL"),
        .int => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
        // Normalize -0.0 → 0.0 so output matches the reference tool (SQLite
        // treats negative zero as zero for display purposes).
        .real => |f| std.fmt.allocPrint(alloc, "{d}", .{if (f == 0.0) @as(f64, 0.0) else f}),
        .text => |s| alloc.dupe(u8, s),
        .blob => |b| std.fmt.allocPrint(alloc, "<blob {d}B>", .{b.len}),
    };
}

// Insertion sort: groups values into rows of col_count, sorts rows lexicographically.
fn sortRows(values: [][]const u8, col_count: usize) void {
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

fn sortValues(values: [][]const u8) void {
    std.sort.block([]const u8, values, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

// Computes the MD5 of all values joined by newlines (each value followed by '\n'),
// then returns the result as a 32-character lowercase hex string — matching the
// format used by the original SQLite sqllogictest tool.
fn md5OfValues(values: []const []const u8) [32]u8 {
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
