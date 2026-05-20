// Benchmark runner for .benchmark files.
//
// Usage:
//   zig build bench -Doptimize=ReleaseFast
//   zig build bench -Doptimize=ReleaseFast -- --group scan
//   zig build bench -Doptimize=ReleaseFast -- --runs 5
//   zig build bench -Doptimize=ReleaseFast -- bench/benchmarks/scan.benchmark
//
// Each .benchmark file has a `load` section (setup, untimed) and a `run`
// section (timed). Both PagerDB and SQLite run the same SQL; the minimum
// time across --runs iterations is reported.

const std = @import("std");
const core = @import("core");
const parser = @import("parser.zig");
const c = @cImport(@cInclude("sqlite3.h"));

const Allocator = std.mem.Allocator;
const Database = core.Database;
const InMemoryPager = core.InMemoryPager;
const execute = core.execute;
const Dir = std.Io.Dir;

const DEFAULT_BENCH_DIR = "bench/benchmarks";
const DEFAULT_RUNS: usize = 3;

// ── Timing ────────────────────────────────────────────────────────────────────

fn monoNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

inline fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

// ── PagerDB backend ───────────────────────────────────────────────────────────

// Executes one SQL statement against PagerDB, draining any result rows.
// Returns false and prints a message on SQL error.
fn pagerdbExec(alloc: Allocator, db: *Database, sql: []const u8) !bool {
    var r = try execute(alloc, db, sql);
    defer r.deinit();
    if (r == .err) {
        std.debug.print("  [pagerdb] error: {s}\n    sql: {s}\n", .{ r.err.message, sql });
        return false;
    }
    return true;
}

// Runs the load section then times the run section for PagerDB.
// Returns null if any SQL statement fails.
fn timePagerdb(alloc: Allocator, bench: parser.Benchmark) !?u64 {
    const db = try Database.init(try InMemoryPager.create(alloc), alloc);
    defer db.close();

    for (bench.load_stmts) |sql| {
        if (!try pagerdbExec(alloc, db, sql)) return null;
    }

    const t0 = monoNs();
    for (bench.run_stmts) |sql| {
        if (!try pagerdbExec(alloc, db, sql)) return null;
    }
    return monoNs() - t0;
}

// ── SQLite backend ────────────────────────────────────────────────────────────

// Executes one SQL statement against SQLite, draining all result rows.
// Returns false and prints a message on SQL error.
fn sqliteExec(db: *c.sqlite3, sql: []const u8) bool {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
        std.debug.print("  [sqlite] error: {s}\n    sql: {s}\n", .{
            std.mem.sliceTo(c.sqlite3_errmsg(db), 0), sql,
        });
        return false;
    }
    defer _ = c.sqlite3_finalize(stmt);
    // Drain all rows so SELECT execution is fully measured.
    var rc = c.sqlite3_step(stmt.?);
    while (rc == c.SQLITE_ROW) rc = c.sqlite3_step(stmt.?);
    if (rc != c.SQLITE_DONE) {
        std.debug.print("  [sqlite] error: {s}\n    sql: {s}\n", .{
            std.mem.sliceTo(c.sqlite3_errmsg(db), 0), sql,
        });
        return false;
    }
    return true;
}

// Runs the load section then times the run section for SQLite.
// Returns null if any SQL statement fails.
fn timeSqlite(bench: parser.Benchmark) ?u64 {
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return null;
    defer _ = c.sqlite3_close(db);

    for (bench.load_stmts) |sql| {
        if (!sqliteExec(db.?, sql)) return null;
    }

    const t0 = monoNs();
    for (bench.run_stmts) |sql| {
        if (!sqliteExec(db.?, sql)) return null;
    }
    return monoNs() - t0;
}

// ── Runner ────────────────────────────────────────────────────────────────────

const BenchResult = struct {
    pagerdb_ns: ?u64, // null if benchmark failed on this engine
    sqlite_ns: ?u64,
};

// Runs each benchmark `runs` times and returns the minimum elapsed time per engine.
fn runBenchmark(alloc: Allocator, bench: parser.Benchmark, runs: usize) !BenchResult {
    var min_pagerdb: ?u64 = null;
    var min_sqlite: ?u64 = null;

    for (0..runs) |_| {
        if (try timePagerdb(alloc, bench)) |ns| {
            if (min_pagerdb == null or ns < min_pagerdb.?) min_pagerdb = ns;
        }
        if (timeSqlite(bench)) |ns| {
            if (min_sqlite == null or ns < min_sqlite.?) min_sqlite = ns;
        }
    }

    return .{ .pagerdb_ns = min_pagerdb, .sqlite_ns = min_sqlite };
}

// ── File discovery ────────────────────────────────────────────────────────────

fn collectFiles(alloc: Allocator, io: std.Io, dir_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("error opening '{s}': {s}\n", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, entry.name });
        try out.append(alloc, full);
    }
    // Sort for deterministic output order.
    std.sort.block([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

// ── Output ────────────────────────────────────────────────────────────────────

fn fmtMs(w: *std.Io.Writer, ns: ?u64) !void {
    if (ns) |n| {
        try w.print("{d:>10.2} ms", .{nsToMs(n)});
    } else {
        try w.print("{s:>13}", .{"FAIL"});
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);

    var runs: usize = DEFAULT_RUNS;
    var filter_group: ?[]const u8 = null;
    var explicit_files: std.ArrayList([]const u8) = .empty;
    defer explicit_files.deinit(alloc);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--runs") and i + 1 < args.len) {
            i += 1;
            runs = std.fmt.parseInt(usize, args[i], 10) catch DEFAULT_RUNS;
        } else if (std.mem.eql(u8, args[i], "--group") and i + 1 < args.len) {
            i += 1;
            filter_group = args[i];
        } else {
            try explicit_files.append(alloc, args[i]);
        }
    }

    var all_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (all_files.items) |f| alloc.free(f);
        all_files.deinit(alloc);
    }

    if (explicit_files.items.len > 0) {
        for (explicit_files.items) |path| {
            try all_files.append(alloc, try alloc.dupe(u8, path));
        }
    } else {
        try collectFiles(alloc, io, DEFAULT_BENCH_DIR, &all_files);
    }

    if (all_files.items.len == 0) {
        std.debug.print("no .benchmark files found\n", .{});
        return;
    }

    var out_buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;

    try w.print("Benchmarks: PagerDB vs SQLite3  (min of {d} runs each)\n\n", .{runs});
    try w.print("{s:<28} {s:<12} {s:>13} {s:>13} {s:>10}\n", .{ "name", "group", "PagerDB", "SQLite", "PagerDB/SQLite" });
    try w.print("{s}\n", .{"─" ** 78});

    for (all_files.items) |path| {
        const file = Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| {
            std.debug.print("cannot open '{s}': {s}\n", .{ path, @errorName(err) });
            continue;
        };
        defer file.close(io);

        const file_len = file.length(io) catch continue;
        const content = try alloc.alloc(u8, file_len);
        defer alloc.free(content);
        _ = file.readPositionalAll(io, content, 0) catch continue;

        var bench = parser.parse(alloc, content) catch |err| {
            std.debug.print("parse error in '{s}': {s}\n", .{ path, @errorName(err) });
            continue;
        };
        defer bench.deinit();

        if (filter_group) |g| {
            if (!std.mem.eql(u8, bench.group, g)) continue;
        }

        const result = try runBenchmark(alloc, bench, runs);

        try w.print("{s:<28} {s:<12}", .{ bench.name, bench.group });
        try fmtMs(w, result.pagerdb_ns);
        try fmtMs(w, result.sqlite_ns);

        if (result.pagerdb_ns != null and result.sqlite_ns != null) {
            const ratio = nsToMs(result.pagerdb_ns.?) / nsToMs(result.sqlite_ns.?);
            try w.print(" {d:>8.2}x\n", .{ratio});
        } else {
            try w.print("\n", .{});
        }
    }

    try w.print("\n  PagerDB/SQLite: <1 = PagerDB faster, >1 = PagerDB slower\n", .{});
    try out.flush();
}
