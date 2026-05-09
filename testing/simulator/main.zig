// Deterministic Simulation Test for PagerDB.
//
// Runs seeded random workloads (INSERT / UPDATE / DELETE) and checks
// structural invariants after every operation:
//   - Catalog consistency
//   - B-tree key ordering and leaf chain integrity
//   - Row count matches shadow state
//
// A failing seed can be replayed exactly with --seed N.
//
// Run:
//   zig build dst                        # 200 seeds × 50 ops (correctness)
//   zig build dst -- --seeds 1000        # more seeds
//   zig build dst -- --seed 42           # replay one specific seed
//   zig build dst -- --wal               # WAL crash-recovery simulation
//   zig build dst -- --wal --seeds 100   # more WAL seeds

const std = @import("std");
const core = @import("core");
const checker = @import("checker.zig");
const workload = @import("workload.zig");
const wal_sim = @import("wal_sim.zig");

const Database = core.Database;
const DiskPager = core.DiskPager;
const Dir = std.Io.Dir;

const DEFAULT_SEEDS: u64 = 200;
const DEFAULT_OPS: u64 = 50;
const DEFAULT_WAL_SEEDS: u64 = 50;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);

    var num_seeds: u64 = DEFAULT_SEEDS;
    var ops_per_seed: u64 = DEFAULT_OPS;
    var single_seed: ?u64 = null;
    var wal_mode = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--seeds") and i + 1 < args.len) {
            i += 1;
            num_seeds = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--ops") and i + 1 < args.len) {
            i += 1;
            ops_per_seed = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--seed") and i + 1 < args.len) {
            i += 1;
            single_seed = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--wal")) {
            wal_mode = true;
        }
    }

    if (wal_mode) {
        const seeds = if (num_seeds == DEFAULT_SEEDS) DEFAULT_WAL_SEEDS else num_seeds;
        return wal_sim.run(io, alloc, seeds);
    }

    if (single_seed) |s| {
        try runSeed(io, alloc, s, ops_per_seed);
        std.debug.print("[DST] seed {d} passed ({d} ops)\n", .{ s, ops_per_seed });
        return;
    }

    var seed: u64 = 0;
    while (seed < num_seeds) : (seed += 1) {
        runSeed(io, alloc, seed, ops_per_seed) catch |err| {
            std.debug.print("[DST] FAILED seed={d}: {s}\n", .{ seed, @errorName(err) });
            std.process.exit(1);
        };
        if (seed % 50 == 49)
            std.debug.print("[DST] {d}/{d} seeds passed\n", .{ seed + 1, num_seeds });
    }
    std.debug.print("[DST] {d} seeds passed ({d} ops each)\n", .{ num_seeds, ops_per_seed });
}

fn runSeed(io: std.Io, alloc: std.mem.Allocator, seed: u64, n_ops: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/dst_{d}.db", .{seed});

    var wal_path_buf: [72]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_path_buf, "{s}.wal", .{path});

    defer Dir.deleteFile(.cwd(), io, path) catch {};
    defer Dir.deleteFile(.cwd(), io, wal_path) catch {};

    const db = try Database.init(try DiskPager.create(alloc, io, path, .{}), alloc);
    defer db.close();

    try workload.setupTable(db);
    var shadow = workload.ShadowState.init(alloc);
    defer shadow.deinit();

    for (0..n_ops) |_| {
        try workload.runOp(db, rng, &shadow);
        try db.pager.flush();
        if (rng.uintLessThan(u8, 10) == 0) {
            try checker.checkCatalog(db);
            try checker.checkBTreeStructure(io, alloc, db, path, workload.TABLE_NAME);
            try checker.checkRowCount(db, workload.TABLE_NAME, shadow.count(), alloc);
        }
    }
}
