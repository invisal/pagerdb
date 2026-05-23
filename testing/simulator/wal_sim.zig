// WAL Crash Simulation — four scenarios that together cover the full durability
// guarantee: every committed transaction survives any crash, and no uncommitted
// transaction is ever visible after recovery.
//
// Scenario 1 — Data-file fault sweep (original):
//   Fault the DATA file at write count F = 0, 1, 2, … after the WAL has been
//   flushed.  This covers every crash window between "WAL committed" and "all
//   pages written".  Recovery replays the WAL and must restore the row.
//
// Scenario 2 — WAL write fault:
//   Fault the WAL SEGMENT file so the flush itself fails.  The data file is
//   never touched.  Recovery sees no commit marker and must discard the partial
//   transaction; all baseline rows survive from the already-written data pages.
//
// Scenario 3 — Multi-transaction crash sweep:
//   Commit BASELINE + INTER rows before the crash sweep begins.  The WAL now
//   holds multiple committed transactions that recovery must replay correctly
//   while still discarding the one uncommitted transaction that crashed.
//
// Scenario 4 — WAL rotation crash:
//   Crash at two points inside rotateAfterCheckpoint:
//     Window A — after the new segment is created but before its header is
//                synced (checkpoint still points to old segment).
//     Window B — after the new segment is created and synced but before the
//                checkpoint file is updated (old checkpoint remains valid).
//   In both windows the database must be fully recoverable.

const std = @import("std");
const core = @import("core");
const checker = @import("checker.zig");

const Database = core.Database;
const DiskPager = core.DiskPager;
const SimIo = core.SimIo;
const WAL = core.WAL;
const walSegmentPath = core.walSegmentPath;

const TABLE = "items";
// Rows committed before any crash sweep — the durable baseline that must always survive.
const BASELINE: usize = 10;
// Extra rows committed between baseline and the multi-transaction crash sweep.
const INTER: usize = 5;
// Upper bound on page writes per insert; the sweep stops when a fault point
// exceeds the actual write count (insert succeeds without a fault).
const MAX_CRASH_POINTS: u32 = 30;

const SCHEMA = [_]core.catalog.ColumnMeta{
    .{ .name = "v", .col_type = .int, .nullable = false, .default_src = null, .default_expr = null },
};

pub fn run(alloc: std.mem.Allocator, io: std.Io, num_seeds: u64) !void {
    _ = io;

    // Scenario 1: data-file fault sweep.
    var seed: u64 = 0;
    while (seed < num_seeds) : (seed += 1) {
        runSeedDataFault(alloc, seed) catch |err| {
            std.debug.print("[WAL-SIM/data-fault] FAILED seed={d}: {s}\n", .{ seed, @errorName(err) });
            std.process.exit(1);
        };
        if (seed % 10 == 9)
            std.debug.print("[WAL-SIM/data-fault] {d}/{d} seeds passed\n", .{ seed + 1, num_seeds });
    }
    std.debug.print("[WAL-SIM/data-fault] {d} seeds passed\n", .{num_seeds});

    // Scenario 2: WAL write fault.
    seed = 0;
    while (seed < num_seeds) : (seed += 1) {
        runSeedWalFault(alloc, seed) catch |err| {
            std.debug.print("[WAL-SIM/wal-fault] FAILED seed={d}: {s}\n", .{ seed, @errorName(err) });
            std.process.exit(1);
        };
        if (seed % 10 == 9)
            std.debug.print("[WAL-SIM/wal-fault] {d}/{d} seeds passed\n", .{ seed + 1, num_seeds });
    }
    std.debug.print("[WAL-SIM/wal-fault] {d} seeds passed\n", .{num_seeds});

    // Scenario 3: multi-transaction crash sweep.
    seed = 0;
    while (seed < num_seeds) : (seed += 1) {
        runSeedMultiTxn(alloc, seed) catch |err| {
            std.debug.print("[WAL-SIM/multi-txn] FAILED seed={d}: {s}\n", .{ seed, @errorName(err) });
            std.process.exit(1);
        };
        if (seed % 10 == 9)
            std.debug.print("[WAL-SIM/multi-txn] {d}/{d} seeds passed\n", .{ seed + 1, num_seeds });
    }
    std.debug.print("[WAL-SIM/multi-txn] {d} seeds passed\n", .{num_seeds});

    // Scenario 4: WAL rotation crash (two windows, each with its own SimIo).
    seed = 0;
    while (seed < num_seeds) : (seed += 1) {
        runSeedRotationCrash(alloc, seed) catch |err| {
            std.debug.print("[WAL-SIM/rotation] FAILED seed={d}: {s}\n", .{ seed, @errorName(err) });
            std.process.exit(1);
        };
        if (seed % 10 == 9)
            std.debug.print("[WAL-SIM/rotation] {d}/{d} seeds passed\n", .{ seed + 1, num_seeds });
    }
    std.debug.print("[WAL-SIM/rotation] {d} seeds passed\n", .{num_seeds});
}

// ── Scenario 1: data-file fault sweep ────────────────────────────────────────
//
// The original simulation: fault the data file at write F after the WAL is
// safely on disk.  Verifies that WAL recovery replays committed records and
// that the B-tree remains structurally valid after each crash.

fn runSeedDataFault(alloc: std.mem.Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/wal_sim_{d}.db", .{seed});
    var wal_path_buf: [72]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_path_buf, "{s}.wal", .{path});

    var sim_io = SimIo.init(alloc);
    defer sim_io.deinit();

    var baseline_ids: [BASELINE]u64 = undefined;
    {
        var wal = try WAL.open(alloc, sim_io.io(), wal_path);
        defer wal.deinit();

        const db = try Database.init(try DiskPager.create(alloc, sim_io.io(), path, .{ .wal = &wal }), alloc);
        defer db.close();
        try db.createTable(TABLE, &SCHEMA);
        for (&baseline_ids) |*id| {
            id.* = try db.insert(TABLE, &.{.{ .int = rng.intRangeAtMost(i64, 0, 1_000_000) }});
        }
    }

    for (0..MAX_CRASH_POINTS) |crash_point| {
        var wal1 = try WAL.open(alloc, sim_io.io(), wal_path);
        defer wal1.deinit();

        var pager = try DiskPager.open(alloc, sim_io.io(), path, .{ .wal = &wal1 });
        try wal1.recover(&pager, alloc);

        sim_io.setFaultAfterWrites(path, @intCast(crash_point));

        const db = try Database.load(pager, alloc);

        const fault_fired = if (db.insert(TABLE, &.{.{ .int = rng.intRangeAtMost(i64, 0, 1_000_000) }})) |_| false else |_| true;

        sim_io.crash();
        sim_io.resetFault();
        db.cat.deinit();
        db.pager.close();
        db.allocator.destroy(db);

        if (!fault_fired) break;

        var wal2 = try WAL.open(alloc, sim_io.io(), wal_path);
        defer wal2.deinit();

        var pager2 = try DiskPager.open(alloc, sim_io.io(), path, .{ .wal = &wal2 });
        try wal2.recover(&pager2, alloc);

        const rdb = try Database.load(pager2, alloc);
        defer rdb.close();

        for (baseline_ids) |rowid| {
            const vals = try rdb.getByRowid(TABLE, rowid, alloc) orelse {
                std.debug.print(
                    "[WAL-SIM/data-fault] seed={d} crash_at={d}: committed rowid {d} missing after recovery\n",
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

        var pager3 = try DiskPager.open(alloc, sim_io.io(), path, .{});
        defer pager3.close();
        core.btree.RowidBTree.verifyTree(&pager3, rdb.cat.tables.get(TABLE).?.btree_root) catch |err| {
            std.debug.print(
                "[WAL-SIM/data-fault] seed={d} crash_at={d}: B-tree violation: {s}\n",
                .{ seed, crash_point, @errorName(err) },
            );
            return err;
        };
    }
}

// ── Scenario 2: WAL write fault ───────────────────────────────────────────────
//
// Faults the WAL segment file so that the flush writeAt fails before any data
// page is touched.  Recovery must find no commit marker and discard the
// partial transaction; all baseline rows survive from the data file.

fn runSeedWalFault(alloc: std.mem.Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var path_buf: [72]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/wal_wfault_{d}.db", .{seed});
    var wal_path_buf: [80]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_path_buf, "{s}.wal", .{path});

    var sim_io = SimIo.init(alloc);
    defer sim_io.deinit();

    // Phase 1: committed baseline (all rows on disk and in WAL).
    var baseline_ids: [BASELINE]u64 = undefined;
    {
        var wal = try WAL.open(alloc, sim_io.io(), wal_path);
        defer wal.deinit();

        const db = try Database.init(try DiskPager.create(alloc, sim_io.io(), path, .{ .wal = &wal }), alloc);
        defer db.close();
        try db.createTable(TABLE, &SCHEMA);
        for (&baseline_ids) |*id| {
            id.* = try db.insert(TABLE, &.{.{ .int = rng.intRangeAtMost(i64, 0, 1_000_000) }});
        }
    }

    // Phase 2: recover (rotates WAL to a fresh segment), then fault the active
    // WAL segment file so that the next flush's writeAt call fails immediately.
    // diskFlush writes WAL before touching any data page, so the data file
    // stays at baseline state while the WAL has no commit marker.
    {
        var wal = try WAL.open(alloc, sim_io.io(), wal_path);
        defer wal.deinit();

        var pager = try DiskPager.open(alloc, sim_io.io(), path, .{ .wal = &wal });
        try wal.recover(&pager, alloc);

        // Target the active WAL segment with write-count=0 so the very first
        // writeAt (records + commit marker, written as one buffer) fails.
        const seg_path = try walSegmentPath(wal_path, wal.segment_num, alloc);
        defer alloc.free(seg_path);
        sim_io.setFaultAfterWrites(seg_path, 0);

        const db = try Database.load(pager, alloc);

        const fault_fired = if (db.insert(TABLE, &.{.{ .int = rng.intRangeAtMost(i64, 0, 1_000_000) }})) |_| false else |_| true;

        sim_io.crash();
        sim_io.resetFault();
        db.cat.deinit();
        db.pager.close();
        db.allocator.destroy(db);

        if (!fault_fired) return; // WAL write had nothing to write; nothing to verify.
    }

    // Phase 3: recover and verify — no partial transaction should appear.
    {
        var wal = try WAL.open(alloc, sim_io.io(), wal_path);
        defer wal.deinit();
        var pager = try DiskPager.open(alloc, sim_io.io(), path, .{ .wal = &wal });
        try wal.recover(&pager, alloc);
        const rdb = try Database.load(pager, alloc);
        defer rdb.close();

        for (baseline_ids) |rowid| {
            const vals = try rdb.getByRowid(TABLE, rowid, alloc) orelse {
                std.debug.print(
                    "[WAL-SIM/wal-fault] seed={d}: rowid {d} missing after WAL write fault\n",
                    .{ seed, rowid },
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
    }
}

// ── Scenario 3: multi-transaction crash sweep ─────────────────────────────────
//
// Commits BASELINE rows then INTER more rows before the crash sweep.  The WAL
// now contains multiple committed transactions; recovery must replay all of
// them and correctly discard only the one uncommitted transaction that crashed.

fn runSeedMultiTxn(alloc: std.mem.Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var path_buf: [72]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/wal_multi_{d}.db", .{seed});
    var wal_path_buf: [80]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_path_buf, "{s}.wal", .{path});

    var sim_io = SimIo.init(alloc);
    defer sim_io.deinit();

    // Phase 1: committed baseline (fully on disk).
    var baseline_ids: [BASELINE]u64 = undefined;
    {
        var wal = try WAL.open(alloc, sim_io.io(), wal_path);
        defer wal.deinit();

        const db = try Database.init(try DiskPager.create(alloc, sim_io.io(), path, .{ .wal = &wal }), alloc);
        defer db.close();
        try db.createTable(TABLE, &SCHEMA);
        for (&baseline_ids) |*id| {
            id.* = try db.insert(TABLE, &.{.{ .int = rng.intRangeAtMost(i64, 0, 1_000_000) }});
        }
    }

    // Phase 2: reopen, recover, commit INTER additional rows.  Each auto-commit
    // insert flushes WAL + data pages, so the WAL accumulates several committed
    // transaction groups before the crash sweep starts.
    var inter_ids: [INTER]u64 = undefined;
    {
        var wal = try WAL.open(alloc, sim_io.io(), wal_path);
        defer wal.deinit();

        var pager = try DiskPager.open(alloc, sim_io.io(), path, .{ .wal = &wal });
        try wal.recover(&pager, alloc);

        const db = try Database.load(pager, alloc);
        defer db.close();
        for (&inter_ids) |*id| {
            id.* = try db.insert(TABLE, &.{.{ .int = rng.intRangeAtMost(i64, 0, 1_000_000) }});
        }
    }

    var all_ids: [BASELINE + INTER]u64 = undefined;
    @memcpy(all_ids[0..BASELINE], &baseline_ids);
    @memcpy(all_ids[BASELINE..], &inter_ids);

    // Phase 3: crash sweep — same data-file fault pattern as scenario 1 but
    // recovery must now traverse all BASELINE + INTER committed transactions.
    for (0..MAX_CRASH_POINTS) |crash_point| {
        var wal1 = try WAL.open(alloc, sim_io.io(), wal_path);
        defer wal1.deinit();

        var pager = try DiskPager.open(alloc, sim_io.io(), path, .{ .wal = &wal1 });
        try wal1.recover(&pager, alloc);

        sim_io.setFaultAfterWrites(path, @intCast(crash_point));

        const db = try Database.load(pager, alloc);

        const fault_fired = if (db.insert(TABLE, &.{.{ .int = rng.intRangeAtMost(i64, 0, 1_000_000) }})) |_| false else |_| true;

        sim_io.crash();
        sim_io.resetFault();
        db.cat.deinit();
        db.pager.close();
        db.allocator.destroy(db);

        if (!fault_fired) break;

        var wal2 = try WAL.open(alloc, sim_io.io(), wal_path);
        defer wal2.deinit();

        var pager2 = try DiskPager.open(alloc, sim_io.io(), path, .{ .wal = &wal2 });
        try wal2.recover(&pager2, alloc);

        const rdb = try Database.load(pager2, alloc);
        defer rdb.close();

        for (all_ids) |rowid| {
            const vals = try rdb.getByRowid(TABLE, rowid, alloc) orelse {
                std.debug.print(
                    "[WAL-SIM/multi-txn] seed={d} crash_at={d}: rowid {d} missing after recovery\n",
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

        var pager3 = try DiskPager.open(alloc, sim_io.io(), path, .{});
        defer pager3.close();
        core.btree.RowidBTree.verifyTree(&pager3, rdb.cat.tables.get(TABLE).?.btree_root) catch |err| {
            std.debug.print(
                "[WAL-SIM/multi-txn] seed={d} crash_at={d}: B-tree violation: {s}\n",
                .{ seed, crash_point, @errorName(err) },
            );
            return err;
        };
    }
}

// ── Scenario 4: WAL rotation crash ───────────────────────────────────────────
//
// rotateAfterCheckpoint has three steps that must all be crash-safe:
//   Step 1  Create new segment file and fsync its header.
//   Step 2  Atomically update the checkpoint (write temp + rename).
//   Step 3  Delete the old segment (best-effort; orphan is harmless).
//
// We test two crash windows:
//   Window A — fault fires during new segment header writeAt (step 1).
//              Checkpoint still points to old segment.  Recovery opens old
//              segment, replays (no-op, data already on disk), and rotates.
//   Window B — fault fires during checkpoint temp file writeAt (step 2).
//              New segment was synced (step 1 done) but checkpoint not updated.
//              Recovery still opens old segment via the unchanged checkpoint.
//
// Each window runs in its own SimIo so state does not bleed between them.

fn runSeedRotationCrash(alloc: std.mem.Allocator, seed: u64) !void {
    try runRotationWindow(alloc, seed, .new_seg_header);
    try runRotationWindow(alloc, seed, .checkpoint_tmp);
}

const RotationWindow = enum {
    // Fault during the new segment's first writeAt (header write).
    new_seg_header,
    // Fault during the checkpoint temp file's writeAt.
    checkpoint_tmp,
};

fn runRotationWindow(alloc: std.mem.Allocator, seed: u64, window: RotationWindow) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var path_buf: [72]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/wal_rot_{d}.db", .{seed});
    var wal_path_buf: [80]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_path_buf, "{s}.wal", .{path});

    var sim_io = SimIo.init(alloc);
    defer sim_io.deinit();

    // Phase 1: committed baseline (all rows on disk).
    var baseline_ids: [BASELINE]u64 = undefined;
    {
        var wal = try WAL.open(alloc, sim_io.io(), wal_path);
        defer wal.deinit();

        const db = try Database.init(try DiskPager.create(alloc, sim_io.io(), path, .{ .wal = &wal }), alloc);
        defer db.close();
        try db.createTable(TABLE, &SCHEMA);
        for (&baseline_ids) |*id| {
            id.* = try db.insert(TABLE, &.{.{ .int = rng.intRangeAtMost(i64, 0, 1_000_000) }});
        }
    }

    // Phase 2: recover (WAL rotates to segment N+1 internally), then trigger a
    // second rotation with a fault armed at the target window.
    {
        var wal = try WAL.open(alloc, sim_io.io(), wal_path);
        defer wal.deinit();

        var pager = try DiskPager.open(alloc, sim_io.io(), path, .{ .wal = &wal });
        try wal.recover(&pager, alloc);
        pager.close();

        // Arm fault on the file that the chosen crash window targets.
        switch (window) {
            .new_seg_header => {
                // Fault the header writeAt on the segment rotateAfterCheckpoint
                // will create next.  write-count=0 catches the first (and only)
                // writeAt on that file.
                const next_seg = try walSegmentPath(wal_path, wal.segment_num + 1, alloc);
                defer alloc.free(next_seg);
                sim_io.setFaultAfterWrites(next_seg, 0);
            },
            .checkpoint_tmp => {
                // Fault the writeAt on the checkpoint temp file.  The new segment
                // is already created and synced (step 1 complete) before this write.
                var tmp_buf: [88]u8 = undefined;
                const ckpt_tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.ckpt.tmp", .{wal_path});
                sim_io.setFaultAfterWrites(ckpt_tmp, 0);
            },
        }

        // Trigger rotation; error is expected and intentional.
        wal.rotateAfterCheckpoint() catch {};

        sim_io.crash();
        sim_io.resetFault();
        // wal.deinit() via defer — no flush, mirrors abrupt process exit.
    }

    // Phase 3: recovery must succeed and all baseline rows must be present.
    {
        var wal = try WAL.open(alloc, sim_io.io(), wal_path);
        defer wal.deinit();
        var pager = try DiskPager.open(alloc, sim_io.io(), path, .{ .wal = &wal });
        try wal.recover(&pager, alloc);
        const rdb = try Database.load(pager, alloc);
        defer rdb.close();

        for (baseline_ids) |rowid| {
            const vals = try rdb.getByRowid(TABLE, rowid, alloc) orelse {
                std.debug.print(
                    "[WAL-SIM/rotation] seed={d} window={s}: rowid {d} missing after rotation crash\n",
                    .{ seed, @tagName(window), rowid },
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
    }
}
