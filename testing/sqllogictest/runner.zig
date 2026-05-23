// Executes sqllogictest records against a database backend.
//
// Each .slt file gets a fresh database so tests are fully isolated.
// Statements check for expected success/failure; queries collect result
// values as strings, optionally sort them, and compare against expected.
//
// Two backends are supported:
//   .pagerdb — an in-memory VisalDB instance (default)
//   .sqlite  — an in-memory SQLite3 instance (via --sqlite flag)

const std = @import("std");
const core = @import("core");
const parser = @import("parser.zig");
const c = @cImport(@cInclude("sqlite3.h"));

const Allocator = std.mem.Allocator;
const Database = core.Database;
const InMemoryPager = core.InMemoryPager;
const execute = core.execute;
const Dir = std.Io.Dir;
const PAGE_SIZE = core.PAGE_SIZE;

// Path where the agent report is written on first failure in --agent mode.
const AGENT_REPORT_PATH = "testing/sqllogictest/last_error.md";

// ── Backend abstraction ───────────────────────────────────────────────────────

const Backend = union(enum) {
    pagerdb: *Database,
    sqlite: *c.sqlite3,
};

// Returns the engine names that match this backend for onlyif/skipif directives.
// "postgresql" is included for pagerdb so that directives written for Postgres
// apply to us too — we target ANSI SQL / PostgreSQL compatibility, not SQLite.
fn engineMatches(backend: Backend, engine: []const u8) bool {
    const engines: []const []const u8 = switch (backend) {
        .pagerdb => &.{ "pagerdb", "postgresql" },
        .sqlite => &.{"sqlite"},
    };
    for (engines) |e| {
        if (std.mem.eql(u8, engine, e)) return true;
    }
    return false;
}

// ── Backend execution helpers ─────────────────────────────────────────────────

// Executes a statement. Returns null on success, or an owned error message
// string (caller must free with exec_alloc) on SQL failure.
fn backendExecStmt(exec_alloc: Allocator, backend: Backend, sql: []const u8) !?[]const u8 {
    switch (backend) {
        .pagerdb => |db| {
            var r = try execute(exec_alloc, db, sql);
            defer r.deinit();
            if (r == .err) return try exec_alloc.dupe(u8, r.err.message);
            return null;
        },
        .sqlite => |db| {
            var stmt: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
            if (rc != c.SQLITE_OK) {
                return try exec_alloc.dupe(u8, std.mem.sliceTo(c.sqlite3_errmsg(db), 0));
            }
            defer _ = c.sqlite3_finalize(stmt);
            const step_rc = c.sqlite3_step(stmt.?);
            if (step_rc != c.SQLITE_DONE and step_rc != c.SQLITE_ROW) {
                return try exec_alloc.dupe(u8, std.mem.sliceTo(c.sqlite3_errmsg(db), 0));
            }
            return null;
        },
    }
}

// Result of a backend query: either a SQL error message or a flat row-major
// table of formatted string values. All memory is owned by the allocator
// passed to backendExecQuery and must be freed via deinit.
const BackendRows = struct {
    col_count: usize,
    col_names: [][]const u8,
    values: [][]const u8,

    fn deinit(self: BackendRows, alloc: Allocator) void {
        for (self.col_names) |s| alloc.free(s);
        alloc.free(self.col_names);
        for (self.values) |s| alloc.free(s);
        alloc.free(self.values);
    }
};

const BackendQueryResult = union(enum) {
    sql_err: []const u8,
    rows: BackendRows,

    fn deinit(self: BackendQueryResult, alloc: Allocator) void {
        switch (self) {
            .sql_err => |s| alloc.free(s),
            .rows => |r| r.deinit(alloc),
        }
    }
};

// Executes a query and returns all results as formatted strings.
// col_type_str maps column index → SLT type character ('I', 'R', 'T').
// Pass "" to format all columns with default (text-like) rules.
fn backendExecQuery(exec_alloc: Allocator, backend: Backend, sql: []const u8, col_type_str: []const u8) !BackendQueryResult {
    switch (backend) {
        .pagerdb => |db| {
            var exec_result = try execute(exec_alloc, db, sql);
            defer exec_result.deinit();

            if (exec_result == .err) {
                return .{ .sql_err = try exec_alloc.dupe(u8, exec_result.err.message) };
            }
            if (exec_result != .result_set) {
                return .{ .sql_err = try exec_alloc.dupe(u8, "query did not return a result set") };
            }

            const rs = &exec_result.result_set;
            const col_count = rs.columns.len;

            var col_names: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (col_names.items) |s| exec_alloc.free(s);
                col_names.deinit(exec_alloc);
            }
            for (rs.columns) |name| {
                try col_names.append(exec_alloc, try exec_alloc.dupe(u8, name));
            }

            var values: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (values.items) |s| exec_alloc.free(s);
                values.deinit(exec_alloc);
            }
            for (rs.rows) |row| {
                for (row.values, 0..) |val, col_idx| {
                    const col_type: u8 = if (col_idx < col_type_str.len) col_type_str[col_idx] else 0;
                    try values.append(exec_alloc, try formatValue(exec_alloc, val, col_type));
                }
            }

            return .{ .rows = .{
                .col_count = col_count,
                .col_names = try col_names.toOwnedSlice(exec_alloc),
                .values = try values.toOwnedSlice(exec_alloc),
            } };
        },

        .sqlite => |db| {
            var stmt: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
            if (rc != c.SQLITE_OK) {
                return .{ .sql_err = try exec_alloc.dupe(u8, std.mem.sliceTo(c.sqlite3_errmsg(db), 0)) };
            }
            defer _ = c.sqlite3_finalize(stmt);

            const col_count: usize = @intCast(c.sqlite3_column_count(stmt.?));

            var col_names: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (col_names.items) |s| exec_alloc.free(s);
                col_names.deinit(exec_alloc);
            }
            for (0..col_count) |i| {
                const name_ptr = c.sqlite3_column_name(stmt.?, @intCast(i));
                const name: []const u8 = if (name_ptr != null) std.mem.sliceTo(name_ptr, 0) else "(col)";
                try col_names.append(exec_alloc, try exec_alloc.dupe(u8, name));
            }

            var values: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (values.items) |s| exec_alloc.free(s);
                values.deinit(exec_alloc);
            }
            while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
                for (0..col_count) |i| {
                    const col_type: u8 = if (i < col_type_str.len) col_type_str[i] else 0;
                    try values.append(exec_alloc, try formatSqliteCol(exec_alloc, stmt.?, @intCast(i), col_type));
                }
            }

            return .{ .rows = .{
                .col_count = col_count,
                .col_names = try col_names.toOwnedSlice(exec_alloc),
                .values = try values.toOwnedSlice(exec_alloc),
            } };
        },
    }
}

// Formats a single SQLite column value to an owned string, applying the same
// type-coercion rules as formatValue so PagerDB and SQLite produce comparable output.
fn formatSqliteCol(alloc: Allocator, stmt: *c.sqlite3_stmt, col: c_int, col_type: u8) ![]const u8 {
    return switch (c.sqlite3_column_type(stmt, col)) {
        c.SQLITE_NULL => alloc.dupe(u8, "NULL"),
        c.SQLITE_INTEGER => std.fmt.allocPrint(alloc, "{d}", .{c.sqlite3_column_int64(stmt, col)}),
        c.SQLITE_FLOAT => {
            const f = c.sqlite3_column_double(stmt, col);
            if (col_type == 'I')
                return std.fmt.allocPrint(alloc, "{d}", .{@as(i64, @intFromFloat(@trunc(f)))});
            return std.fmt.allocPrint(alloc, "{d}", .{if (f == 0.0) @as(f64, 0.0) else f});
        },
        c.SQLITE_TEXT => {
            const ptr = c.sqlite3_column_text(stmt, col);
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
            if (ptr == null) return alloc.dupe(u8, "NULL");
            return alloc.dupe(u8, ptr[0..len]);
        },
        c.SQLITE_BLOB => {
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
            return std.fmt.allocPrint(alloc, "<blob {d}B>", .{len});
        },
        else => alloc.dupe(u8, "NULL"),
    };
}

// ── Public runner API ─────────────────────────────────────────────────────────

pub const RunResult = struct {
    passed: usize,
    failed: usize,
};

// Returns the total bytes consumed by all allocated pages in the backend.
// For SQLite (opaque handle) we cannot query this, so we return 0.
fn backendSizeBytes(backend: Backend) usize {
    return switch (backend) {
        .pagerdb => |db| @as(usize, db.pager.total_pages) * PAGE_SIZE,
        .sqlite => 0,
    };
}

// show_errors: print up to this many individual failure messages per file.
// 0 = suppress all individual failure output (summary-only mode).
// agent: stop at first failure, write a markdown report (diff + DB state) to
// testing/sqllogictest/last_error.md, then print a one-line instruction to stdout.
// sqlite: run against an in-memory SQLite3 instance instead of PagerDB.
// page_alloc: backing allocator used for per-statement arenas; passing the
// same CountingAllocator that backs the file-level arena lets the caller track
// total peak memory (file state + peak transient execution memory) in one place.
pub fn runFile(alloc: Allocator, page_alloc: Allocator, io: std.Io, path: []const u8, show_errors: usize, agent: bool, sqlite: bool, db_bytes_out: ?*usize) !RunResult {
    const std_file = try Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer std_file.close(io);

    const file_len = try std_file.length(io);
    const content = try alloc.alloc(u8, file_len);
    defer alloc.free(content);
    _ = try std_file.readPositionalAll(io, content, 0);

    var parsed = try parser.parse(alloc, content);
    defer parsed.deinit();

    const backend: Backend = if (sqlite) blk: {
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return error.SqliteOpenFailed;
        break :blk .{ .sqlite = db.? };
    } else .{ .pagerdb = try Database.init(try InMemoryPager.create(alloc), alloc) };
    defer switch (backend) {
        .pagerdb => |db| db.close(),
        .sqlite => |db| _ = c.sqlite3_close(db),
    };
    // Runs before the close defer (LIFO), so the pager is still live when we read total_pages.
    defer if (db_bytes_out) |p| {
        p.* = backendSizeBytes(backend);
    };

    var result = RunResult{ .passed = 0, .failed = 0 };
    var failures_shown: usize = 0;
    var skip_next = false;

    // Scratch buffer for the agent failure report; populated on first failure.
    var report_buf: std.ArrayList(u8) = .empty;
    defer report_buf.deinit(alloc);

    for (parsed.records) |record| {
        switch (record) {
            .skipif => |engine| {
                if (engineMatches(backend, engine)) skip_next = true;
                continue;
            },
            .onlyif => |engine| {
                if (!engineMatches(backend, engine)) skip_next = true;
                continue;
            },
            .statement => |stmt| {
                if (skip_next) {
                    skip_next = false;
                    continue;
                }
                writeCrashBreadcrumb(io, path, stmt.line, stmt.sql);
                // Per-statement arena backed by page_alloc (the same CountingAllocator
                // that backs the file-level arena) so that transient execution memory
                // is included in peak tracking and the limit applies globally.
                var stmt_arena = std.heap.ArenaAllocator.init(page_alloc);
                defer stmt_arena.deinit();
                const print_err = agent or (show_errors > 0 and failures_shown < show_errors);
                const report: ?*std.ArrayList(u8) = if (agent) &report_buf else null;
                const ok = try runStatement(stmt_arena.allocator(), alloc, backend, path, stmt, print_err, report);
                if (ok) {
                    result.passed += 1;
                } else {
                    if (print_err and !agent) failures_shown += 1;
                    result.failed += 1;
                    if (agent) {
                        try writeAgentReport(alloc, io, path, report_buf.items, backend);
                        return result;
                    }
                }
            },
            .query => |qry| {
                if (skip_next) {
                    skip_next = false;
                    continue;
                }
                writeCrashBreadcrumb(io, path, qry.line, qry.sql);
                var stmt_arena = std.heap.ArenaAllocator.init(page_alloc);
                defer stmt_arena.deinit();
                const print_err = agent or (show_errors > 0 and failures_shown < show_errors);
                const report: ?*std.ArrayList(u8) = if (agent) &report_buf else null;
                const ok = try runQuery(stmt_arena.allocator(), alloc, backend, path, qry, print_err, report);
                if (ok) {
                    result.passed += 1;
                } else {
                    if (print_err and !agent) failures_shown += 1;
                    result.failed += 1;
                    if (agent) {
                        try writeAgentReport(alloc, io, path, report_buf.items, backend);
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

// Overwrite testing/sqllogictest/last_crash.md before every statement/query so
// that a hard crash (SIGABRT/panic) leaves a readable record of the exact SQL
// that was executing.  Failures are silently ignored — this is best-effort.
fn writeCrashBreadcrumb(io: std.Io, slt_path: []const u8, line: usize, sql: []const u8) void {
    const f = Dir.cwd().createFile(io, "testing/sqllogictest/last_crash.md", .{ .truncate = true }) catch return;
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf,
        \\# Crash Breadcrumb
        \\
        \\**File:** `{s}`
        \\**Line:** {d}
        \\
        \\```sql
        \\{s}
        \\```
        \\
    , .{ slt_path, line, sql }) catch return;
    f.writeStreamingAll(io, msg) catch return;
}

fn runStatement(exec_alloc: Allocator, buf_alloc: Allocator, backend: Backend, path: []const u8, stmt: parser.StatementRecord, print_error: bool, report: ?*std.ArrayList(u8)) !bool {
    const err_msg = try backendExecStmt(exec_alloc, backend, stmt.sql);
    defer if (err_msg) |m| exec_alloc.free(m);

    const got_err = err_msg != null;
    const want_err = stmt.expected == .err;

    if (got_err != want_err) {
        if (print_error) {
            if (report) |buf| {
                const exp_str: []const u8 = if (stmt.expected == .ok) "ok" else "error";
                try bufPrint(buf_alloc, buf, "## Failed Statement\n\n**Location:** `{s}:{d}`\n\n**SLT:**\n```\nstatement {s}\n{s}\n```\n\n", .{ path, stmt.line, exp_str, stmt.sql });
                if (want_err) {
                    try buf.appendSlice(buf_alloc, "**Error:** expected error but statement succeeded\n");
                } else {
                    try bufPrint(buf_alloc, buf, "**Error:** expected ok but got: `{s}`\n", .{err_msg.?});
                }
            } else {
                if (want_err) {
                    std.debug.print("FAIL {s}:{d}: expected error but statement succeeded\n  sql: {s}\n", .{ path, stmt.line, stmt.sql });
                } else {
                    std.debug.print("FAIL {s}:{d}: expected ok but got error: {s}\n  sql: {s}\n", .{ path, stmt.line, err_msg.?, stmt.sql });
                }
            }
        }
        return false;
    }
    return true;
}

fn runQuery(exec_alloc: Allocator, buf_alloc: Allocator, backend: Backend, path: []const u8, qry: parser.QueryRecord, print_error: bool, report: ?*std.ArrayList(u8)) !bool {
    const sort_str: []const u8 = switch (qry.sort_mode) {
        .none => "",
        .row_sort => " rowsort",
        .value_sort => " valuesort",
    };

    var qr = try backendExecQuery(exec_alloc, backend, qry.sql, qry.type_string);
    defer qr.deinit(exec_alloc);

    switch (qr) {
        .sql_err => |msg| {
            if (print_error) {
                if (report) |buf| {
                    try bufPrint(buf_alloc, buf, "## Failed Query\n\n**Location:** `{s}:{d}`\n\n**SLT:**\n```\nquery {s}{s}\n{s}\n```\n\n**Error:** {s}\n\n### Expected\n\n", .{ path, qry.line, qry.type_string, sort_str, qry.sql, msg });
                    switch (qry.expected) {
                        .values => |expected| try appendValuesCodeBlock(buf_alloc, buf, qry.type_string.len, expected),
                        .hash => |h| try bufPrint(buf_alloc, buf, "{d} values hashing to `{s}`\n", .{ h.count, h.md5 }),
                    }
                } else {
                    std.debug.print("FAIL {s}:{d}: {s}\n  sql: {s}\n", .{ path, qry.line, msg, qry.sql });
                }
            }
            return false;
        },
        .rows => |rows| {
            const col_count = rows.col_count;
            const actual = rows.values;

            switch (qry.sort_mode) {
                .none => {},
                .row_sort => sortRows(actual, col_count),
                .value_sort => sortValues(actual),
            }

            switch (qry.expected) {
                .values => |expected| {
                    if (actual.len != expected.len) {
                        if (print_error) {
                            if (report) |buf| {
                                try bufPrint(buf_alloc, buf, "## Failed Query\n\n**Location:** `{s}:{d}`\n\n**SLT:**\n```\nquery {s}{s}\n{s}\n```\n\n**Error:** expected {d} values, got {d}\n\n### Expected\n\n", .{ path, qry.line, qry.type_string, sort_str, qry.sql, expected.len, actual.len });
                                try appendValuesCodeBlock(buf_alloc, buf, col_count, expected);
                                try buf.appendSlice(buf_alloc, "\n### Got\n\n");
                                try appendValuesCodeBlock(buf_alloc, buf, col_count, actual);
                            } else {
                                std.debug.print("FAIL {s}:{d}: expected {d} values, got {d}\n  sql: {s}\n", .{
                                    path, qry.line, expected.len, actual.len, qry.sql,
                                });
                            }
                        }
                        return false;
                    }
                    for (actual, expected, 0..) |act, exp, idx| {
                        if (!std.mem.eql(u8, act, exp)) {
                            if (print_error) {
                                if (report) |buf| {
                                    try bufPrint(buf_alloc, buf, "## Failed Query\n\n**Location:** `{s}:{d}`\n\n**SLT:**\n```\nquery {s}{s}\n{s}\n```\n\n**Error:** value[{d}] expected `{s}`, got `{s}`\n\n### Expected\n\n", .{ path, qry.line, qry.type_string, sort_str, qry.sql, idx, exp, act });
                                    try appendValuesCodeBlock(buf_alloc, buf, col_count, expected);
                                    try buf.appendSlice(buf_alloc, "\n### Got\n\n");
                                    try appendValuesCodeBlock(buf_alloc, buf, col_count, actual);
                                } else {
                                    std.debug.print("FAIL {s}:{d}: value[{d}] expected '{s}', got '{s}'\n  sql: {s}\n", .{
                                        path, qry.line, idx, exp, act, qry.sql,
                                    });
                                }
                            }
                            return false;
                        }
                    }
                    return true;
                },
                .hash => |h| {
                    if (actual.len != h.count) {
                        if (print_error) {
                            if (report) |buf| {
                                try bufPrint(buf_alloc, buf, "## Failed Query\n\n**Location:** `{s}:{d}`\n\n**SLT:**\n```\nquery {s}{s}\n{s}\n```\n\n**Error:** expected {d} values, got {d}\n\n### Got\n\n", .{ path, qry.line, qry.type_string, sort_str, qry.sql, h.count, actual.len });
                                try appendValuesCodeBlock(buf_alloc, buf, col_count, actual);
                            } else {
                                std.debug.print("FAIL {s}:{d}: expected {d} values, got {d}\n  sql: {s}\n", .{
                                    path, qry.line, h.count, actual.len, qry.sql,
                                });
                            }
                        }
                        return false;
                    }
                    const digest = md5OfValues(actual);
                    if (!std.mem.eql(u8, &digest, h.md5)) {
                        if (print_error) {
                            if (report) |buf| {
                                try bufPrint(buf_alloc, buf, "## Failed Query\n\n**Location:** `{s}:{d}`\n\n**SLT:**\n```\nquery {s}{s}\n{s}\n```\n\n**Error:** hash mismatch (expected `{s}`, got `{s}`)\n\n### Got\n\n", .{ path, qry.line, qry.type_string, sort_str, qry.sql, h.md5, digest });
                                try appendValuesCodeBlock(buf_alloc, buf, col_count, actual);
                            } else {
                                std.debug.print("FAIL {s}:{d}: hash mismatch (expected {s}, got {s})\n  sql: {s}\n", .{
                                    path, qry.line, h.md5, digest, qry.sql,
                                });
                            }
                        }
                        return false;
                    }
                    return true;
                },
            }
        },
    }
}

// ── Agent report helpers ──────────────────────────────────────────────────────

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
fn appendTablesMarkdown(alloc: Allocator, buf: *std.ArrayList(u8), backend: Backend) !void {
    // The SQL to list user tables differs between backends.
    const tables_sql: []const u8 = switch (backend) {
        .pagerdb => "SELECT table_name FROM information_schema.tables",
        .sqlite => "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    };

    var tables_qr = backendExecQuery(alloc, backend, tables_sql, "") catch |err| {
        try bufPrint(alloc, buf, "*(could not list tables: {s})*\n", .{@errorName(err)});
        return;
    };
    defer tables_qr.deinit(alloc);

    switch (tables_qr) {
        .sql_err => |msg| {
            try bufPrint(alloc, buf, "*(could not list tables: {s})*\n", .{msg});
            return;
        },
        .rows => |rows| {
            if (rows.values.len == 0) {
                try buf.appendSlice(alloc, "*(no tables)*\n");
                return;
            }

            // Each row has col_count columns; the first column is the table name.
            const col_count = if (rows.col_count > 0) rows.col_count else 1;
            var i: usize = 0;
            while (i < rows.values.len) : (i += col_count) {
                const name = rows.values[i];
                try bufPrint(alloc, buf, "### {s}\n\n", .{name});

                var sql_buf: [256]u8 = undefined;
                const sql = std.fmt.bufPrint(&sql_buf, "SELECT * FROM {s}", .{name}) catch {
                    try buf.appendSlice(alloc, "*(table name too long)*\n\n");
                    continue;
                };

                var data_qr = backendExecQuery(alloc, backend, sql, "") catch |err| {
                    try bufPrint(alloc, buf, "*(error: {s})*\n\n", .{@errorName(err)});
                    continue;
                };
                defer data_qr.deinit(alloc);

                switch (data_qr) {
                    .sql_err => |msg| try bufPrint(alloc, buf, "*(error: {s})*\n\n", .{msg}),
                    .rows => |data_rows| {
                        try appendMarkdownTable(alloc, buf, data_rows.col_names, data_rows.col_count, data_rows.values);
                        try buf.appendSlice(alloc, "\n");
                    },
                }
            }
        },
    }
}

// Writes a markdown failure report to AGENT_REPORT_PATH, then prints a one-line
// instruction to stdout directing the agent to read it.
fn writeAgentReport(alloc: Allocator, io: std.Io, _: []const u8, error_content: []const u8, backend: Backend) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "# SLT Failure Report\n\n");
    try buf.appendSlice(alloc, error_content);
    try buf.appendSlice(alloc, "\n## Database State\n\n");
    try appendTablesMarkdown(alloc, &buf, backend);

    const file = try Dir.cwd().createFile(io, AGENT_REPORT_PATH, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, buf.items);

    std.debug.print(
        "\nFound unmatched result. Read the file below to diagnose the issue..\n└─ {s}\n\n",
        .{AGENT_REPORT_PATH},
    );
}

// ── Value formatting ──────────────────────────────────────────────────────────

// Formats a PagerDB value to an owned string for display or comparison.
// col_type is the SLT column type character: 'I' = integer, 'R' = real, 'T' = text, 0 = unknown.
// When col_type is 'I' and the value is real, SQLite truncates toward zero before comparing,
// so we do the same to match the reference tool's behaviour.
fn formatValue(alloc: Allocator, val: anytype, col_type: u8) ![]const u8 {
    return switch (val) {
        .null => alloc.dupe(u8, "NULL"),
        .int => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
        // Normalize -0.0 → 0.0 so output matches the reference tool (SQLite
        // treats negative zero as zero for display purposes).
        .real => |f| if (col_type == 'I')
            std.fmt.allocPrint(alloc, "{d}", .{@as(i64, @intFromFloat(@trunc(f)))})
        else
            std.fmt.allocPrint(alloc, "{d}", .{if (f == 0.0) @as(f64, 0.0) else f}),
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

// ── Sorting ───────────────────────────────────────────────────────────────────

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

// ── Hashing ───────────────────────────────────────────────────────────────────

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
