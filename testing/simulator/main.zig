// Deterministic Simulation Test for PagerDB.
//
// Every mode runs seeded random workloads through the crash simulation runner:
// faults are injected mid-operation, the simulated filesystem is crashed, and
// the database is reopened to verify crash recovery.
//
// Run:
//   zig build dst                        # DST workload — 200 seeds × 50 ops
//   zig build dst -- --seeds 1000        # more seeds
//   zig build dst -- --ops 200           # more ops per seed
//   zig build dst -- --seed 42           # replay one specific seed
//   zig build dst -- --wal               # WAL crash scenarios (50 seeds)
//   zig build dst -- --wal --seeds 100   # more WAL seeds
//   zig build dst -- --order             # order workload (200 seeds × 10 000 ops)
//   zig build dst -- --order --seeds 50  # fewer order seeds

const std = @import("std");
const wal_sim = @import("wal_sim.zig");
const order_workload = @import("order_workload.zig");
const random_workload = @import("random_workload.zig");
const runner = @import("runner.zig");

const DEFAULT_SEEDS: u64 = 200;
const DEFAULT_OPS: u64 = 10_000;
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
    var order_mode = false;

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
        } else if (std.mem.eql(u8, args[i], "--order")) {
            order_mode = true;
        }
    }

    if (wal_mode) {
        const seeds = if (num_seeds == DEFAULT_SEEDS) DEFAULT_WAL_SEEDS else num_seeds;
        return wal_sim.run(alloc, io, seeds);
    }

    if (order_mode) {
        var order = order_workload.OrderWorkload.init(alloc);
        return runner.run(alloc, io, order.workload(), num_seeds, .{});
    }

    var rw = random_workload.RandomWorkload.init(alloc);
    defer rw.deinit();
    const config = runner.RunConfig{ .ops_per_seed = ops_per_seed };

    if (single_seed) |s| {
        runner.runSeed(alloc, rw.workload(), config, s) catch |err| {
            std.debug.print("[RANDOM] FAILED seed={d}: {s}\n", .{ s, @errorName(err) });
            std.process.exit(1);
        };
        std.debug.print("[RANDOM] seed {d} passed ({d} ops)\n", .{ s, ops_per_seed });
        return;
    }

    return runner.run(alloc, io, rw.workload(), num_seeds, config);
}
