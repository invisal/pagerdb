// WAL Crash Simulation
//
// For each seed:
//   Phase 1 — Baseline: insert BASELINE rows using auto-commit.  Every flush
//             succeeds, so all rows are durably committed before any crash.
//
//   Phase 2 — Crash sweep: reopen the DB and arm fault injection at write
//             count F (0, 1, 2, …) targeting the data file only (WAL writes
//             are not counted).  Insert one more row; the fault fires inside
//             diskFlush after the WAL has been flushed to disk but before all
//             dirty pages have been written.  We then simulate a crash by
//             calling sim_io.crash(), which reverts every file to its last
//             sync'd state, then reopen the DB (triggering WAL recovery) and
//             assert:
//               • every baseline rowid is still readable
//               • the B-tree structure is valid
//
//             The sweep stops when a fault point exceeds the actual write
//             count for one insert (i.e. the insert succeeds without a
//             fault), confirming all crash windows have been covered.

const std = @import("std");
const core = @import("core");
const checker = @import("checker.zig");

const Database = core.Database;
const DiskPager = core.DiskPager;
const SimIo = core.SimIo;
const WAL = core.WAL;

const TABLE = "items";
// Number of rows committed before the crash sweep begins.
const BASELINE: usize = 10;
// Maximum write count to probe.  One auto-commit insert touches at most a
// handful of pages; 30 is a safe upper bound even after btree splits.
const MAX_CRASH_POINTS: u32 = 30;

const SCHEMA = [_]core.catalog.ColumnMeta{
    .{ .name = "v", .col_type = .int, .nullable = false, .default_src = null, .default_expr = null },
};

pub fn run(io: std.Io, alloc: std.mem.Allocator, num_seeds: u64) !void {
    _ = io; // SimIo replaces real disk IO for the crash simulation

    var seed: u64 = 0;
    while (seed < num_seeds) : (seed += 1) {
        runSeed(alloc, seed) catch |err| {
            std.debug.print("[WAL-SIM] FAILED seed={d}: {s}\n", .{ seed, @errorName(err) });
            std.process.exit(1);
        };
        if (seed % 10 == 9)
            std.debug.print("[WAL-SIM] {d}/{d} seeds passed\n", .{ seed + 1, num_seeds });
    }
    std.debug.print("[WAL-SIM] {d} seeds passed\n", .{num_seeds});
}

fn runSeed(alloc: std.mem.Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/wal_sim_{d}.db", .{seed});
    var wal_path_buf: [72]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_path_buf, "{s}.wal", .{path});

    // SimIo provides an in-memory filesystem shared across all phases.
    // sim_io.crash() reverts all files to their last sync()'d state,
    // and files persist across open/close cycles (like real files on disk).
    var sim_io = SimIo.init(alloc);
    defer sim_io.deinit();

    // ── Phase 1: committed baseline ─────────────────────────────────────────
    var baseline_ids: [BASELINE]u64 = undefined;
    {
        var wal = try WAL.open(sim_io.io(), wal_path, alloc);
        defer wal.deinit();

        const db = try Database.init(try DiskPager.create(alloc, sim_io.io(), path, .{ .wal = &wal }), alloc);
        defer db.close();
        try db.createTable(TABLE, &SCHEMA);
        for (&baseline_ids) |*id| {
            id.* = try db.insert(TABLE, &.{.{ .int = rng.intRangeAtMost(i64, 0, 1_000_000) }});
        }
    }

    // ── Phase 2: crash sweep ─────────────────────────────────────────────────
    for (0..MAX_CRASH_POINTS) |crash_point| {
        var wal1 = try WAL.open(sim_io.io(), wal_path, alloc);
        defer wal1.deinit();

        var pager = try DiskPager.open(alloc, sim_io.io(), path, .{ .wal = &wal1 });
        try wal1.recover(&pager, alloc);

        // Arm fault injection AFTER recovery so that recovery's own page writes
        // are not counted.  Only writeAt calls to the data file are counted;
        // WAL writes go to a different file and do not affect the counter.
        sim_io.setFaultAfterWrites(path, @intCast(crash_point));

        const db = try Database.load(pager, alloc);

        // Attempt one insert.  If the fault fires inside diskFlush (after the
        // WAL is safely on disk but before all pages are written), the insert
        // returns an error.
        const fault_fired = if (db.insert(TABLE, &.{.{ .int = rng.intRangeAtMost(i64, 0, 1_000_000) }})) |_| false else |_| true;

        // Simulate crash: revert all files to last sync()'d state and
        // tear down without flushing — mirrors an abrupt process exit.
        sim_io.crash();
        sim_io.resetFault();
        db.cat.deinit();
        db.pager.close();
        db.allocator.destroy(db);

        // If the fault never fired, crash_point is past the last write for
        // this insert, so all crash windows have been covered.
        if (!fault_fired) break;

        // ── Recovery check ──────────────────────────────────────────────────
        // Reopen triggers WAL recovery; then verify every committed row survived.
        var wal2 = try WAL.open(sim_io.io(), wal_path, alloc);
        defer wal2.deinit();

        var pager2 = try DiskPager.open(alloc, sim_io.io(), path, .{ .wal = &wal2 });
        try wal2.recover(&pager2, alloc);

        const rdb = try Database.load(pager2, alloc);
        defer rdb.close();

        for (baseline_ids) |rowid| {
            const vals = try rdb.getByRowid(TABLE, rowid, alloc) orelse {
                std.debug.print(
                    "[WAL-SIM] seed={d} crash_at={d}: committed rowid {d} missing after recovery\n",
                    .{ seed, crash_point, rowid },
                );
                return error.LostCommittedRow;
            };
            for (vals) |v| switch (v) {
                .text => |s| alloc.free(s),
                .blob => |b| alloc.free(b),
                else => {},
            };
            alloc.free(vals);
        }

        // B-tree structural check using a second fresh pager (no WAL needed
        // since recovery has already been applied and flushed above).
        var pager3 = try DiskPager.open(alloc, sim_io.io(), path, .{});
        defer pager3.close();
        core.btree.verifyTree(&pager3, rdb.cat.tables.get(TABLE).?.btree_root) catch |err| {
            std.debug.print(
                "[WAL-SIM] seed={d} crash_at={d}: B-tree structure violation: {s}\n",
                .{ seed, crash_point, @errorName(err) },
            );
            return err;
        };
    }
}
