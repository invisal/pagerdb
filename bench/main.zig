// Benchmark runner for .sql benchmark files.
//
// Usage:
//   zig build bench -Doptimize=ReleaseFast
//   zig build bench -Doptimize=ReleaseFast -- --group scan
//   zig build bench -Doptimize=ReleaseFast -- --runs 5
//   zig build bench -Doptimize=ReleaseFast -- bench/benchmarks/scan.sql
//
// Each .sql benchmark file has a `load` section (setup, untimed) and a `run`
// section (timed).  Four engines are compared:
//
//   PDB/mem  — PagerDB with InMemoryPager (no I/O)
//   PDB/disk — PagerDB with DiskPager + WAL writing to real files
//   SQ/mem   — SQLite opened as :memory:
//   SQ/disk  — SQLite opened on a real file
//
// The minimum time across --runs iterations is reported for each engine.

const std = @import("std");
const core = @import("core");
const parser = @import("parser.zig");
const c = @cImport(@cInclude("sqlite3.h"));

const Allocator = std.mem.Allocator;
const Database = core.Database;
const InMemoryPager = core.InMemoryPager;
const DiskPager = core.DiskPager;
const DiskIo = core.DiskIo;
const WAL = core.WAL;
const execute = core.execute;
const Dir = std.Io.Dir;

const DEFAULT_BENCH_DIR = "bench/benchmarks";
const DEFAULT_RUNS: usize = 3;

// Temp paths for disk benchmarks.  Chosen to be unlikely to collide with user
// files; cleaned up before each run and after all runs complete.
const PDB_DISK_PATH = "/tmp/pdb_bench.db";
const PDB_WAL_BASE = "/tmp/pdb_bench.wal";
const SQLITE_DISK_PATH = "/tmp/sqlite_bench.db";

// ── Timing ────────────────────────────────────────────────────────────────────

fn monoNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

inline fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

// ── Cleanup helpers ───────────────────────────────────────────────────────────

// Deletes all files the PagerDB disk backend may have created.
// Ignores errors so callers can use it as a best-effort pre-run and post-run sweep.
fn cleanupPagerdbDisk(io: std.Io) void {
    Dir.deleteFile(.cwd(), io, PDB_DISK_PATH) catch {};
    // WAL segments are named {base}-{num:06}.wal; clean up several in case
    // a benchmark triggered multiple rotations.
    var seg_buf: [128]u8 = undefined;
    var seg: u32 = 1;
    while (seg <= 8) : (seg += 1) {
        const p = std.fmt.bufPrint(&seg_buf, "{s}-{d:0>6}.wal", .{ PDB_WAL_BASE, seg }) catch break;
        Dir.deleteFile(.cwd(), io, p) catch {};
    }
    Dir.deleteFile(.cwd(), io, PDB_WAL_BASE ++ ".ckpt") catch {};
    Dir.deleteFile(.cwd(), io, PDB_WAL_BASE ++ ".ckpt.tmp") catch {};
}

// Deletes the SQLite disk file and any side-car files SQLite may have created.
fn cleanupSqliteDisk(io: std.Io) void {
    Dir.deleteFile(.cwd(), io, SQLITE_DISK_PATH) catch {};
    Dir.deleteFile(.cwd(), io, SQLITE_DISK_PATH ++ "-journal") catch {};
    Dir.deleteFile(.cwd(), io, SQLITE_DISK_PATH ++ "-wal") catch {};
    Dir.deleteFile(.cwd(), io, SQLITE_DISK_PATH ++ "-shm") catch {};
}

// ── PagerDB backend ───────────────────────────────────────────────────────────

fn pagerdbExec(alloc: Allocator, db: *Database, sql: []const u8) !bool {
    var r = try execute(alloc, db, sql);
    defer r.deinit();
    if (r == .err) {
        std.debug.print("  [pagerdb] error: {s}\n    sql: {s}\n", .{ r.err.message, sql });
        return false;
    }
    return true;
}

fn timePagerdbMem(alloc: Allocator, bench: parser.Benchmark) !?u64 {
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

fn timePagerdbDisk(alloc: Allocator, io: std.Io, bench: parser.Benchmark) !?u64 {
    cleanupPagerdbDisk(io);

    var disk_io = DiskIo.init(alloc, io);
    var wal = try WAL.open(alloc, disk_io.io(), PDB_WAL_BASE);
    defer wal.deinit();

    const db = try Database.init(
        try DiskPager.create(alloc, disk_io.io(), PDB_DISK_PATH, .{ .wal = &wal }),
        alloc,
    );
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

fn sqliteExec(db: *c.sqlite3, sql: []const u8) bool {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
        std.debug.print("  [sqlite] error: {s}\n    sql: {s}\n", .{
            std.mem.sliceTo(c.sqlite3_errmsg(db), 0), sql,
        });
        return false;
    }
    defer _ = c.sqlite3_finalize(stmt);
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

fn timeSqliteMem(bench: parser.Benchmark) ?u64 {
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

fn timeSqliteDisk(io: std.Io, bench: parser.Benchmark) ?u64 {
    cleanupSqliteDisk(io);

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(SQLITE_DISK_PATH, &db) != c.SQLITE_OK) return null;
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
    pdb_mem_ns: ?u64,
    pdb_disk_ns: ?u64,
    sq_mem_ns: ?u64,
    sq_disk_ns: ?u64,
};

fn runBenchmark(alloc: Allocator, io: std.Io, bench: parser.Benchmark, runs: usize) !BenchResult {
    var pdb_mem: ?u64 = null;
    var pdb_disk: ?u64 = null;
    var sq_mem: ?u64 = null;
    var sq_disk: ?u64 = null;

    for (0..runs) |_| {
        if (try timePagerdbMem(alloc, bench)) |ns| {
            if (pdb_mem == null or ns < pdb_mem.?) pdb_mem = ns;
        }
        if (try timePagerdbDisk(alloc, io, bench)) |ns| {
            if (pdb_disk == null or ns < pdb_disk.?) pdb_disk = ns;
        }
        if (timeSqliteMem(bench)) |ns| {
            if (sq_mem == null or ns < sq_mem.?) sq_mem = ns;
        }
        if (timeSqliteDisk(io, bench)) |ns| {
            if (sq_disk == null or ns < sq_disk.?) sq_disk = ns;
        }
    }

    cleanupPagerdbDisk(io);
    cleanupSqliteDisk(io);

    return .{
        .pdb_mem_ns = pdb_mem,
        .pdb_disk_ns = pdb_disk,
        .sq_mem_ns = sq_mem,
        .sq_disk_ns = sq_disk,
    };
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
    std.sort.block([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

// ── Output ────────────────────────────────────────────────────────────────────

// Formats a nullable nanosecond value as a right-aligned "1234.56 ms" string
// in a 13-character field, or "FAIL" if null.
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
        std.debug.print("no .sql benchmark files found\n", .{});
        return;
    }

    var out_buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;

    try w.print("Benchmarks: PagerDB vs SQLite3  (min of {d} runs each)\n\n", .{runs});
    // Column layout: name(28) group(12) PDB/mem(13) PDB/disk(13) SQ/mem(13) SQ/disk(13) disk-cmp(10)
    try w.print("{s:<28} {s:<12} {s:>13} {s:>13} {s:>13} {s:>13} {s:>10}\n", .{
        "name", "group", "PDB/mem", "PDB/disk", "SQ/mem", "SQ/disk", "disk-cmp",
    });
    try w.print("{s}\n", .{"─" ** 96});

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

        const result = try runBenchmark(alloc, io, bench, runs);

        try w.print("{s:<28} {s:<12}", .{ bench.name, bench.group });
        try fmtMs(w, result.pdb_mem_ns);
        try fmtMs(w, result.pdb_disk_ns);
        try fmtMs(w, result.sq_mem_ns);
        try fmtMs(w, result.sq_disk_ns);

        if (result.pdb_disk_ns != null and result.sq_disk_ns != null) {
            const ratio = nsToMs(result.pdb_disk_ns.?) / nsToMs(result.sq_disk_ns.?);
            try w.print(" {d:>8.2}x\n", .{ratio});
        } else {
            try w.print("\n", .{});
        }
    }

    try w.print(
        "\n  PDB/mem vs SQ/mem: in-memory only (no I/O cost)\n" ++
            "  PDB/disk vs SQ/disk: real files with WAL/journal\n" ++
            "  disk-cmp: PDB/disk ÷ SQ/disk  (<1 faster, >1 slower)\n",
        .{},
    );
    try out.flush();
}
