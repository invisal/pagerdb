// Benchmark: PagerDB vs SQLite3
//
// Both engines commit every statement individually (no batching) for a fair
// apples-to-apples comparison of per-statement durability cost.
//
// Run:  zig build bench -Doptimize=ReleaseFast

const std = @import("std");
const Db = @import("core").Database;
const DiskPager = @import("core").DiskPager;
const row = @import("core").row;
const catalog = @import("core").catalog;
const c = @cImport(@cInclude("sqlite3.h"));

const Dir = std.Io.Dir;

const COUNTS = [_]usize{ 500, 2_000 };

const SCHEMA = [_]catalog.ColumnMeta{
    .{ .name = "id", .col_type = .int, .nullable = false, .default_src = null, .default_expr = null },
    .{ .name = "name", .col_type = .text, .nullable = false, .default_src = null, .default_expr = null },
    .{ .name = "score", .col_type = .real, .nullable = false, .default_src = null, .default_expr = null },
};

const InsertResult = struct { ns: u64, bytes: u64 };

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var out_buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;

    try w.print(
        \\Benchmark: PagerDB vs SQLite3 — both commit every statement
        \\Schema: id INT, name TEXT, score REAL — fixed values per row
        \\
        \\
    , .{});

    for (COUNTS) |n| {
        const insert_pagerdb = try benchPagerdbInsert(n, io, alloc);
        const insert_sqlite = try benchSqliteInsert(n, io);
        const insert_pagerdb_txn = try benchPagerdbInsertTxn(n, io, alloc);
        const insert_sqlite_txn = try benchSqliteInsertTxn(n, io);
        const scan_pagerdb = try benchPagerdbScan(n, io, alloc);
        const scan_sqlite = try benchSqliteScan(n);
        const where_pagerdb = try benchPagerdbWhere(n, io, alloc);
        const where_sqlite = try benchSqliteWhere(n);

        try printTable(w, n, insert_pagerdb.ns, insert_sqlite.ns, insert_pagerdb_txn.ns, insert_sqlite_txn.ns, scan_pagerdb, scan_sqlite, where_pagerdb, where_sqlite, insert_pagerdb.bytes, insert_sqlite.bytes);
    }
    try out.flush();
}

// ── PagerDB ───────────────────────────────────────────────────────────────────

fn benchPagerdbInsert(n: usize, io: std.Io, alloc: std.mem.Allocator) !InsertResult {
    const path = "bench/data/bench_pagerdb_insert.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};

    var ns: u64 = 0;
    {
        const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
        defer db.close();
        try db.createTable("bench", &SCHEMA);

        var name_buf: [32]u8 = undefined;
        const t0 = monoNs();
        for (0..n) |i| {
            const name = std.fmt.bufPrint(&name_buf, "user{d}", .{i}) catch "user";
            _ = try db.insert("bench", &.{
                .{ .int = @intCast(i) },
                .{ .text = name },
                .{ .real = @as(f64, @floatFromInt(i)) * 0.1 },
            });
        }
        ns = monoNs() - t0;
    }
    const stat = try Dir.statFile(.cwd(), io, path, .{});
    return .{ .ns = ns, .bytes = stat.size };
}

fn benchPagerdbInsertTxn(n: usize, io: std.Io, alloc: std.mem.Allocator) !InsertResult {
    const path = "bench/data/bench_pagerdb_insert_txn.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};

    var ns: u64 = 0;
    {
        const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
        defer db.close();
        try db.createTable("bench", &SCHEMA);

        var name_buf: [32]u8 = undefined;
        const t0 = monoNs();
        try db.begin();
        for (0..n) |i| {
            const name = std.fmt.bufPrint(&name_buf, "user{d}", .{i}) catch "user";
            _ = try db.insert("bench", &.{
                .{ .int = @intCast(i) },
                .{ .text = name },
                .{ .real = @as(f64, @floatFromInt(i)) * 0.1 },
            });
        }
        try db.commit();
        ns = monoNs() - t0;
    }
    const stat = try Dir.statFile(.cwd(), io, path, .{});
    return .{ .ns = ns, .bytes = stat.size };
}

fn benchPagerdbScan(n: usize, io: std.Io, alloc: std.mem.Allocator) !u64 {
    const path = "bench/data/bench_pagerdb_scan.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();
    try db.createTable("bench", &SCHEMA);

    var name_buf: [32]u8 = undefined;
    for (0..n) |i| {
        const name = std.fmt.bufPrint(&name_buf, "user{d}", .{i}) catch "user";
        _ = try db.insert("bench", &.{
            .{ .int = @intCast(i) },
            .{ .text = name },
            .{ .real = @as(f64, @floatFromInt(i)) * 0.1 },
        });
    }

    var count: usize = 0;
    const t0 = monoNs();
    try db.scan("bench", struct {
        fn cb(_: u64, _: []const row.Value, ctx: *usize) bool {
            ctx.* += 1;
            return true;
        }
    }.cb, &count);
    const elapsed = monoNs() - t0;

    std.debug.assert(count == n);
    return elapsed;
}

fn benchPagerdbWhere(n: usize, io: std.Io, alloc: std.mem.Allocator) !u64 {
    const path = "bench/data/bench_pagerdb_where.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};

    const db = try Db.init(try DiskPager.create(alloc, io, path), alloc);
    defer db.close();
    try db.createTable("bench", &SCHEMA);

    var name_buf: [32]u8 = undefined;
    for (0..n) |i| {
        const name = std.fmt.bufPrint(&name_buf, "user{d}", .{i}) catch "user";
        _ = try db.insert("bench", &.{
            .{ .int = @intCast(i) },
            .{ .text = name },
            .{ .real = @as(f64, @floatFromInt(i)) * 0.1 },
        });
    }

    const Ctx = struct { count: usize, threshold: f64 };
    var ctx = Ctx{ .count = 0, .threshold = @as(f64, @floatFromInt(n)) * 0.05 };
    const t0 = monoNs();
    try db.scan("bench", struct {
        fn cb(_: u64, values: []const row.Value, cx: *Ctx) bool {
            if (values[2].real >= cx.threshold) cx.count += 1;
            return true;
        }
    }.cb, &ctx);
    const elapsed = monoNs() - t0;

    std.debug.assert(ctx.count == n / 2);
    return elapsed;
}

// ── SQLite3 ───────────────────────────────────────────────────────────────────

fn benchSqliteInsert(n: usize, io: std.Io) !InsertResult {
    const path = "bench/data/bench_sqlite_insert.db";
    defer _ = std.c.unlink(path);

    var ns: u64 = 0;
    {
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path, &db) != c.SQLITE_OK) return error.SqliteOpen;
        defer _ = c.sqlite3_close(db);

        _ = c.sqlite3_exec(db, "CREATE TABLE bench (id INTEGER, name TEXT, score REAL)", null, null, null);

        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "INSERT INTO bench VALUES (?,?,?)", -1, &stmt, null);
        defer _ = c.sqlite3_finalize(stmt);

        var name_buf: [32]u8 = undefined;
        const t0 = monoNs();
        for (0..n) |i| {
            const name = std.fmt.bufPrintZ(&name_buf, "user{d}", .{i}) catch "user";
            _ = c.sqlite3_bind_int64(stmt, 1, @intCast(i));
            _ = c.sqlite3_bind_text(stmt, 2, name.ptr, @intCast(name.len), c.SQLITE_STATIC);
            _ = c.sqlite3_bind_double(stmt, 3, @as(f64, @floatFromInt(i)) * 0.1);
            _ = c.sqlite3_step(stmt);
            _ = c.sqlite3_reset(stmt);
        }
        ns = monoNs() - t0;
    }
    const stat = try Dir.statFile(.cwd(), io, path, .{});
    return .{ .ns = ns, .bytes = stat.size };
}

fn benchSqliteInsertTxn(n: usize, io: std.Io) !InsertResult {
    const path = "bench/data/bench_sqlite_insert_txn.db";
    defer _ = std.c.unlink(path);

    var ns: u64 = 0;
    {
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path, &db) != c.SQLITE_OK) return error.SqliteOpen;
        defer _ = c.sqlite3_close(db);

        _ = c.sqlite3_exec(db, "CREATE TABLE bench (id INTEGER, name TEXT, score REAL)", null, null, null);

        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "INSERT INTO bench VALUES (?,?,?)", -1, &stmt, null);
        defer _ = c.sqlite3_finalize(stmt);

        var name_buf: [32]u8 = undefined;
        const t0 = monoNs();
        _ = c.sqlite3_exec(db, "BEGIN", null, null, null);
        for (0..n) |i| {
            const name = std.fmt.bufPrintZ(&name_buf, "user{d}", .{i}) catch "user";
            _ = c.sqlite3_bind_int64(stmt, 1, @intCast(i));
            _ = c.sqlite3_bind_text(stmt, 2, name.ptr, @intCast(name.len), c.SQLITE_STATIC);
            _ = c.sqlite3_bind_double(stmt, 3, @as(f64, @floatFromInt(i)) * 0.1);
            _ = c.sqlite3_step(stmt);
            _ = c.sqlite3_reset(stmt);
        }
        _ = c.sqlite3_exec(db, "COMMIT", null, null, null);
        ns = monoNs() - t0;
    }
    const stat = try Dir.statFile(.cwd(), io, path, .{});
    return .{ .ns = ns, .bytes = stat.size };
}

fn benchSqliteScan(n: usize) !u64 {
    const path = "bench/data/bench_sqlite_scan.db";
    defer _ = std.c.unlink(path);

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path, &db) != c.SQLITE_OK) return error.SqliteOpen;
    defer _ = c.sqlite3_close(db);

    _ = c.sqlite3_exec(db, "CREATE TABLE bench (id INTEGER, name TEXT, score REAL)", null, null, null);

    var stmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "INSERT INTO bench VALUES (?,?,?)", -1, &stmt, null);

    var name_buf: [32]u8 = undefined;
    for (0..n) |i| {
        const name = std.fmt.bufPrintZ(&name_buf, "user{d}", .{i}) catch "user";
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(i));
        _ = c.sqlite3_bind_text(stmt, 2, name.ptr, @intCast(name.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_double(stmt, 3, @as(f64, @floatFromInt(i)) * 0.1);
        _ = c.sqlite3_step(stmt);
        _ = c.sqlite3_reset(stmt);
    }
    _ = c.sqlite3_finalize(stmt);

    var scan_stmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "SELECT * FROM bench", -1, &scan_stmt, null);
    defer _ = c.sqlite3_finalize(scan_stmt);

    var count: usize = 0;
    const t0 = monoNs();
    while (c.sqlite3_step(scan_stmt) == c.SQLITE_ROW) count += 1;
    const elapsed = monoNs() - t0;

    std.debug.assert(count == n);
    return elapsed;
}

fn benchSqliteWhere(n: usize) !u64 {
    const path = "bench/data/bench_sqlite_where.db";
    defer _ = std.c.unlink(path);

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path, &db) != c.SQLITE_OK) return error.SqliteOpen;
    defer _ = c.sqlite3_close(db);

    _ = c.sqlite3_exec(db, "CREATE TABLE bench (id INTEGER, name TEXT, score REAL)", null, null, null);

    var ins: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "INSERT INTO bench VALUES (?,?,?)", -1, &ins, null);

    var name_buf: [32]u8 = undefined;
    for (0..n) |i| {
        const name = std.fmt.bufPrintZ(&name_buf, "user{d}", .{i}) catch "user";
        _ = c.sqlite3_bind_int64(ins, 1, @intCast(i));
        _ = c.sqlite3_bind_text(ins, 2, name.ptr, @intCast(name.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_double(ins, 3, @as(f64, @floatFromInt(i)) * 0.1);
        _ = c.sqlite3_step(ins);
        _ = c.sqlite3_reset(ins);
    }
    _ = c.sqlite3_finalize(ins);

    const threshold: f64 = @as(f64, @floatFromInt(n)) * 0.05;
    var sel: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "SELECT * FROM bench WHERE score >= ?", -1, &sel, null);
    defer _ = c.sqlite3_finalize(sel);
    _ = c.sqlite3_bind_double(sel, 1, threshold);

    var count: usize = 0;
    const t0 = monoNs();
    while (c.sqlite3_step(sel) == c.SQLITE_ROW) count += 1;
    const elapsed = monoNs() - t0;

    std.debug.assert(count == n / 2);
    return elapsed;
}

// ── Output ────────────────────────────────────────────────────────────────────

fn printTable(
    w: *std.Io.Writer,
    n: usize,
    insert_pagerdb: u64,
    insert_sqlite: u64,
    insert_pagerdb_txn: u64,
    insert_sqlite_txn: u64,
    scan_pagerdb: u64,
    scan_sqlite: u64,
    where_pagerdb: u64,
    where_sqlite: u64,
    vdb_bytes: u64,
    sql_bytes: u64,
) !void {
    const iv = nsToMs(insert_pagerdb);
    const is = nsToMs(insert_sqlite);
    const ivt = nsToMs(insert_pagerdb_txn);
    const ist = nsToMs(insert_sqlite_txn);
    const sv = nsToMs(scan_pagerdb);
    const ss = nsToMs(scan_sqlite);
    const wv = nsToMs(where_pagerdb);
    const ws = nsToMs(where_sqlite);

    // ratio = PagerDB / SQLite: >1 means PagerDB is slower, <1 means faster
    const insert_ratio = if (is > 0) iv / is else 0;
    const insert_txn_ratio = if (ist > 0) ivt / ist else 0;
    const scan_ratio = if (ss > 0) sv / ss else 0;
    const where_ratio = if (ws > 0) wv / ws else 0;
    const vdb_kb = @as(f64, @floatFromInt(vdb_bytes)) / 1024.0;
    const sql_kb = @as(f64, @floatFromInt(sql_bytes)) / 1024.0;
    const size_ratio = if (sql_kb > 0) vdb_kb / sql_kb else 0;

    try w.print("=== N = {d} rows ===\n", .{n});
    try w.print("{s:<26} {s:>14} {s:>14} {s:>12}\n", .{ "Operation", "PagerDB", "SQLite", "VDB/SQL" });
    try w.print("{s}\n", .{"─" ** 68});
    try w.print("{s:<26} {d:>11.2} ms {d:>11.2} ms    {d:>6.2}x\n", .{ "INSERT (per-stmt fsync)", iv, is, insert_ratio });
    try w.print("{s:<26} {d:>11.2} ms {d:>11.2} ms    {d:>6.2}x\n", .{ "INSERT (single txn)", ivt, ist, insert_txn_ratio });
    try w.print("{s:<26} {d:>11.2} ms {d:>11.2} ms    {d:>6.2}x\n", .{ "SELECT * (full scan)", sv, ss, scan_ratio });
    try w.print("{s:<26} {d:>11.2} ms {d:>11.2} ms    {d:>6.2}x\n", .{ "SELECT WHERE (no index)", wv, ws, where_ratio });
    try w.print("{s:<26} {d:>10.1} KB  {d:>10.1} KB    {d:>6.2}x\n", .{ "File size (post-insert)", vdb_kb, sql_kb, size_ratio });
    try w.print("  VDB/SQL ratio: <1 = PagerDB faster/smaller, >1 = PagerDB slower/larger\n\n", .{});
}

// ── Timing ────────────────────────────────────────────────────────────────────

fn monoNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 +
        @as(u64, @intCast(ts.nsec));
}

inline fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}
