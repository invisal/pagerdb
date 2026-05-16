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

// Path where the agent report is written on first failure in --agent mode.
const AGENT_REPORT_PATH = "testing/sqllogictest/last_error.md";

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
// agent: stop at first failure, write a markdown report (diff + DB state) to
// testing/sqllogictest/last_error.md, then print a one-line instruction to stdout.
pub fn runFile(alloc: Allocator, io: std.Io, path: []const u8, show_errors: usize, agent: bool) !RunResult {
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

    // Scratch buffer for the agent failure report; populated on first failure.
    var report_buf: std.ArrayList(u8) = .empty;
    defer report_buf.deinit(alloc);

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
                const print_err = agent or (show_errors > 0 and failures_shown < show_errors);
                const report: ?*std.ArrayList(u8) = if (agent) &report_buf else null;
                const ok = try runStatement(alloc, db, path, stmt, print_err, report);
                if (ok) {
                    result.passed += 1;
                } else {
                    if (print_err and !agent) failures_shown += 1;
                    result.failed += 1;
                    if (agent) {
                        try writeAgentReport(alloc, io, path, report_buf.items, db);
                        return result;
                    }
                }
            },
            .query => |qry| {
                if (skip_next) {
                    skip_next = false;
                    continue;
                }
                const print_err = agent or (show_errors > 0 and failures_shown < show_errors);
                const report: ?*std.ArrayList(u8) = if (agent) &report_buf else null;
                const ok = try runQuery(alloc, db, path, qry, print_err, report);
                if (ok) {
                    result.passed += 1;
                } else {
                    if (print_err and !agent) failures_shown += 1;
                    result.failed += 1;
                    if (agent) {
                        try writeAgentReport(alloc, io, path, report_buf.items, db);
                        return result;
                    }
                }
            },
        }
    }

    if (show_errors > 0 and result.failed > failures_shown) {
        std.debug.print("  ... and {d} more failure(s) not shown\n", .{result.failed - failures_shown});
    }

    return result;
}

fn runStatement(alloc: Allocator, db: *Database, path: []const u8, stmt: parser.StatementRecord, print_error: bool, report: ?*std.ArrayList(u8)) !bool {
    var exec_result = try execute(alloc, db, stmt.sql);
    defer exec_result.deinit();

    const got_err = exec_result == .err;
    const want_err = stmt.expected == .err;

    if (got_err != want_err) {
        if (print_error) {
            if (report) |buf| {
                const exp_str: []const u8 = if (stmt.expected == .ok) "ok" else "error";
                try bufPrint(alloc, buf, "## Failed Statement\n\n**Location:** `{s}:{d}`\n\n**SLT:**\n```\nstatement {s}\n{s}\n```\n\n", .{ path, stmt.line, exp_str, stmt.sql });
                if (want_err) {
                    try buf.appendSlice(alloc, "**Error:** expected error but statement succeeded\n");
                } else {
                    try bufPrint(alloc, buf, "**Error:** expected ok but got: `{s}`\n", .{exec_result.err.message});
                }
            } else {
                if (want_err) {
                    std.debug.print("FAIL {s}:{d}: expected error but statement succeeded\n  sql: {s}\n", .{ path, stmt.line, stmt.sql });
                } else {
                    std.debug.print("FAIL {s}:{d}: expected ok but got error: {s}\n  sql: {s}\n", .{ path, stmt.line, exec_result.err.message, stmt.sql });
                }
            }
        }
        return false;
    }
    return true;
}

fn runQuery(alloc: Allocator, db: *Database, path: []const u8, qry: parser.QueryRecord, print_error: bool, report: ?*std.ArrayList(u8)) !bool {
    const sort_str: []const u8 = switch (qry.sort_mode) {
        .none => "",
        .row_sort => " rowsort",
        .value_sort => " valuesort",
    };

    var exec_result = try execute(alloc, db, qry.sql);
    defer exec_result.deinit();

    if (exec_result == .err) {
        if (print_error) {
            if (report) |buf| {
                try bufPrint(alloc, buf, "## Failed Query\n\n**Location:** `{s}:{d}`\n\n**SLT:**\n```\nquery {s}{s}\n{s}\n```\n\n**Error:** query returned error: `{s}`\n", .{ path, qry.line, qry.type_string, sort_str, qry.sql, exec_result.err.message });
            } else {
                std.debug.print("FAIL {s}:{d}: query returned error: {s}\n  sql: {s}\n", .{ path, qry.line, exec_result.err.message, qry.sql });
            }
        }
        return false;
    }
    if (exec_result != .result_set) {
        if (print_error) {
            if (report) |buf| {
                try bufPrint(alloc, buf, "## Failed Query\n\n**Location:** `{s}:{d}`\n\n**SLT:**\n```\nquery {s}{s}\n{s}\n```\n\n**Error:** query did not return a result set\n", .{ path, qry.line, qry.type_string, sort_str, qry.sql });
            } else {
                std.debug.print("FAIL {s}:{d}: query did not return a result set\n  sql: {s}\n", .{ path, qry.line, qry.sql });
            }
        }
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
                if (print_error) {
                    if (report) |buf| {
                        try bufPrint(alloc, buf, "## Failed Query\n\n**Location:** `{s}:{d}`\n\n**SLT:**\n```\nquery {s}{s}\n{s}\n```\n\n**Error:** expected {d} values, got {d}\n\n### Expected\n\n", .{ path, qry.line, qry.type_string, sort_str, qry.sql, expected.len, actual.items.len });
                        try appendValuesCodeBlock(alloc, buf, col_count, expected);
                        try buf.appendSlice(alloc, "\n### Got\n\n");
                        try appendValuesCodeBlock(alloc, buf, col_count, actual.items);
                    } else {
                        std.debug.print("FAIL {s}:{d}: expected {d} values, got {d}\n  sql: {s}\n", .{
                            path, qry.line, expected.len, actual.items.len, qry.sql,
                        });
                    }
                }
                return false;
            }
            for (actual.items, expected, 0..) |act, exp, idx| {
                if (!std.mem.eql(u8, act, exp)) {
                    if (print_error) {
                        if (report) |buf| {
                            try bufPrint(alloc, buf, "## Failed Query\n\n**Location:** `{s}:{d}`\n\n**SLT:**\n```\nquery {s}{s}\n{s}\n```\n\n**Error:** value[{d}] expected `{s}`, got `{s}`\n\n### Expected\n\n", .{ path, qry.line, qry.type_string, sort_str, qry.sql, idx, exp, act });
                            try appendValuesCodeBlock(alloc, buf, col_count, expected);
                            try buf.appendSlice(alloc, "\n### Got\n\n");
                            try appendValuesCodeBlock(alloc, buf, col_count, actual.items);
                        } else {
                            std.debug.print("FAIL {s}:{d}: value[{d}] expected '{s}', got '{s}'\n  sql: {s}\n", .{
                                path, qry.line, idx, exp, act, qry.sql,
                            });
                        }
                    }
                    return false;
                }
            }
        },
        .hash => |h| {
            if (actual.items.len != h.count) {
                if (print_error) {
                    if (report) |buf| {
                        try bufPrint(alloc, buf, "## Failed Query\n\n**Location:** `{s}:{d}`\n\n**SLT:**\n```\nquery {s}{s}\n{s}\n```\n\n**Error:** expected {d} values, got {d}\n\n### Got\n\n", .{ path, qry.line, qry.type_string, sort_str, qry.sql, h.count, actual.items.len });
                        try appendValuesCodeBlock(alloc, buf, col_count, actual.items);
                    } else {
                        std.debug.print("FAIL {s}:{d}: expected {d} values, got {d}\n  sql: {s}\n", .{
                            path, qry.line, h.count, actual.items.len, qry.sql,
                        });
                    }
                }
                return false;
            }
            const digest = md5OfValues(actual.items);
            if (!std.mem.eql(u8, &digest, h.md5)) {
                if (print_error) {
                    if (report) |buf| {
                        try bufPrint(alloc, buf, "## Failed Query\n\n**Location:** `{s}:{d}`\n\n**SLT:**\n```\nquery {s}{s}\n{s}\n```\n\n**Error:** hash mismatch (expected `{s}`, got `{s}`)\n\n### Got\n\n", .{ path, qry.line, qry.type_string, sort_str, qry.sql, h.md5, digest });
                        try appendValuesCodeBlock(alloc, buf, col_count, actual.items);
                    } else {
                        std.debug.print("FAIL {s}:{d}: hash mismatch (expected {s}, got {s})\n  sql: {s}\n", .{
                            path, qry.line, h.md5, digest, qry.sql,
                        });
                    }
                }
                return false;
            }
        },
    }

    return true;
}

// Appends a GitHub-flavoured markdown table to buf.
// col_names provides header labels; falls back to (0), (1), ... for out-of-range indices.
// values is a flat row-major slice; col_count is the number of columns per row.
fn appendMarkdownTable(alloc: Allocator, buf: *std.ArrayList(u8), col_names: []const []const u8, col_count: usize, values: []const []const u8) !void {
    if (col_count == 0) {
        try buf.appendSlice(alloc, "*(empty)*\n");
        return;
    }

    // Header row
    try buf.appendSlice(alloc, "|");
    for (0..col_count) |i| {
        if (i < col_names.len) {
            try bufPrint(alloc, buf, " {s} |", .{col_names[i]});
        } else {
            try bufPrint(alloc, buf, " ({d}) |", .{i});
        }
    }
    try buf.appendSlice(alloc, "\n|");
    for (0..col_count) |_| try buf.appendSlice(alloc, " --- |");
    try buf.appendSlice(alloc, "\n");

    if (values.len == 0) {
        try buf.appendSlice(alloc, "\n*(no rows)*\n");
        return;
    }

    var i: usize = 0;
    while (i < values.len) : (i += col_count) {
        try buf.appendSlice(alloc, "|");
        const end = @min(i + col_count, values.len);
        for (values[i..end]) |v| try bufPrint(alloc, buf, " {s} |", .{v});
        try buf.appendSlice(alloc, "\n");
    }
}

// Renders values as raw text inside a fenced code block.
// Each row of col_count values appears on one line, space-separated.
fn appendValuesCodeBlock(alloc: Allocator, buf: *std.ArrayList(u8), col_count: usize, values: []const []const u8) !void {
    try buf.appendSlice(alloc, "```\n");

    if (values.len == 0) {
        try buf.appendSlice(alloc, "(empty)\n```\n");
        return;
    }

    const step = if (col_count > 0) col_count else 1;
    var i: usize = 0;
    while (i < values.len) : (i += step) {
        const end = @min(i + step, values.len);
        for (values[i..end], 0..) |v, j| {
            if (j > 0) try buf.appendSlice(alloc, "  ");
            try buf.appendSlice(alloc, v);
        }
        try buf.appendSlice(alloc, "\n");
    }

    try buf.appendSlice(alloc, "```\n");
}

// Appends markdown tables for every user table in the database.
fn appendTablesMarkdown(alloc: Allocator, buf: *std.ArrayList(u8), db: *Database) !void {
    var tables_result = execute(alloc, db, "SELECT table_name FROM information_schema.tables") catch |err| {
        try bufPrint(alloc, buf, "*(could not list tables: {s})*\n", .{@errorName(err)});
        return;
    };
    defer tables_result.deinit();

    if (tables_result != .result_set or tables_result.result_set.rows.len == 0) {
        try buf.appendSlice(alloc, "*(no tables)*\n");
        return;
    }

    for (tables_result.result_set.rows) |row| {
        const name = switch (row.values[0]) {
            .text => |s| s,
            else => continue,
        };

        try bufPrint(alloc, buf, "### {s}\n\n", .{name});

        var sql_buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "SELECT * FROM {s}", .{name}) catch {
            try buf.appendSlice(alloc, "*(table name too long)*\n\n");
            continue;
        };

        var data = execute(alloc, db, sql) catch |err| {
            try bufPrint(alloc, buf, "*(error: {s})*\n\n", .{@errorName(err)});
            continue;
        };
        defer data.deinit();

        if (data != .result_set) {
            try buf.appendSlice(alloc, "*(no result)*\n\n");
            continue;
        }

        const rs = &data.result_set;

        var values: std.ArrayList([]const u8) = .empty;
        defer {
            for (values.items) |s| alloc.free(s);
            values.deinit(alloc);
        }

        for (rs.rows) |data_row| {
            for (data_row.values) |val| {
                try values.append(alloc, try formatValue(alloc, val));
            }
        }

        try appendMarkdownTable(alloc, buf, rs.columns, rs.columns.len, values.items);
        try buf.appendSlice(alloc, "\n");
    }
}

// Writes a markdown failure report to AGENT_REPORT_PATH, then prints a one-line
// instruction to stdout directing the agent to read it.
fn writeAgentReport(alloc: Allocator, io: std.Io, _: []const u8, error_content: []const u8, db: *Database) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "# SLT Failure Report\n\n");
    try buf.appendSlice(alloc, error_content);
    try buf.appendSlice(alloc, "\n## Database State\n\n");
    try appendTablesMarkdown(alloc, &buf, db);

    const file = try Dir.cwd().createFile(io, AGENT_REPORT_PATH, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, buf.items);

    std.debug.print(
        "\nFound unmatched result. Read the file below to diagnose the issue..\n└─ {s}\n\n",
        .{AGENT_REPORT_PATH},
    );
}

// Formats a value to an owned string for display or comparison.
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

// Helper: allocates a formatted string and appends it to buf.
fn bufPrint(alloc: Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try buf.appendSlice(alloc, s);
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
