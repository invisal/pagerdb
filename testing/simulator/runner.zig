// runner.zig — crash simulation loop for deterministic simulation testing.
//
// Each call to run() executes two phases for the given workload:
//   Phase 1 — normal (no faults): validates correctness with clean runs.
//   Phase 2 — fault injection: validates crash recovery under random write faults.
//
// Two separate PRNGs are seeded from the same seed value:
//   prng       — drives the workload's operation sequence (stable across runs)
//   fault_prng — drives fault injection timing (separate so fault injection
//                does not perturb the workload sequence)

const std = @import("std");
const core = @import("core");
const Database = core.ManagedDatabase;

pub const RunConfig = struct {
    ops_per_seed: u64 = 10_000,
    // Fraction of operations that arm a write fault: N out of 100.
    fault_percent: u8 = 2,
    // Fault fires after 0..max_writes_before_fault successful writes.
    max_writes_before_fault: u32 = 8,
};

// Workload is a vtable interface driven by the runner.  Implementations supply
// setup (schema creation, run once per seed) and next (one random operation).
// The runner owns SimIo and the Database; the workload owns only its own state
// (e.g. ID counters) and an allocator for temporary SQL result sets.
pub const Workload = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: []const u8,
        setup: *const fn (*anyopaque, *Database, std.Random) anyerror!void,
        next: *const fn (*anyopaque, *Database, std.Random) anyerror!void,
        // Called after every successful next() and after every crash recovery.
        // Implement as a no-op if the workload has no invariants to check.
        verify: *const fn (*anyopaque, *Database, std.Random) anyerror!void,
    };

    pub fn setup(self: Workload, db: *Database, rng: std.Random) !void {
        return self.vtable.setup(self.ptr, db, rng);
    }

    pub fn next(self: Workload, db: *Database, rng: std.Random) !void {
        return self.vtable.next(self.ptr, db, rng);
    }

    pub fn verify(self: Workload, db: *Database, rng: std.Random) !void {
        return self.vtable.verify(self.ptr, db, rng);
    }
};

pub fn run(alloc: std.mem.Allocator, io: std.Io, workload: Workload, num_seeds: u64, config: RunConfig) !void {
    // Phase 1: no faults — pure correctness baseline.
    const normal = RunConfig{ .ops_per_seed = config.ops_per_seed, .fault_percent = 0, .max_writes_before_fault = 0 };
    try runPhase(alloc, io, workload, num_seeds, normal);

    // Phase 2: fault injection — crash recovery.
    try runPhase(alloc, io, workload, num_seeds, config);
}

fn runPhase(alloc: std.mem.Allocator, io: std.Io, workload: Workload, num_seeds: u64, config: RunConfig) !void {
    const name = workload.vtable.name;

    var label_buf: [16]u8 = undefined;
    const label = if (config.fault_percent == 0)
        "normal"
    else
        try std.fmt.bufPrint(&label_buf, "fault({d}%)", .{config.fault_percent});

    std.debug.print("[{s}] === {s}: {d} seeds x {d} ops ===\n", .{ name, label, num_seeds, config.ops_per_seed });

    // Seed from wall-clock time so each phase explores a different region of
    // the seed space.  Seeds are printed on failure for exact replay with --seed N.
    var seed_prng = std.Random.DefaultPrng.init(@bitCast(std.Io.Clock.real.now(io).toMicroseconds()));
    const seed_rng = seed_prng.random();

    for (0..num_seeds) |i| {
        const seed = seed_rng.int(u64);
        runSeed(alloc, workload, config, seed) catch |err| {
            std.debug.print("[{s}] FAILED seed={d} ({s}): {s}\n", .{ name, seed, label, @errorName(err) });
            std.process.exit(1);
        };
        if ((i + 1) % 10 == 0)
            std.debug.print("[{s}] {d}/{d} seeds passed\n", .{ name, i + 1, num_seeds });
    }
    std.debug.print("[{s}] {s} done: {d} seeds x {d} ops\n", .{ name, label, num_seeds, config.ops_per_seed });
}

pub fn runSeed(alloc: std.mem.Allocator, workload: Workload, config: RunConfig, seed: u64) !void {
    const name = workload.vtable.name;
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/{s}_{d}.db", .{ name, seed });

    var io = core.SimIo.init(alloc);
    defer io.deinit();

    std.debug.print("[{s}] seed={d} open\n", .{ name, seed });
    var db = try Database.open(alloc, io.io(), path);

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    try workload.setup(&db, rng);
    std.debug.print("[{s}] seed={d} setup\n", .{ name, seed });

    var fault_prng = std.Random.DefaultPrng.init(seed ^ 0xfa17_deed);
    const fault_rng = fault_prng.random();

    // Print progress ~10 times per seed regardless of ops_per_seed.
    const log_interval = @max(1, config.ops_per_seed / 10);

    for (0..config.ops_per_seed) |op| {
        if (op > 0 and op % log_interval == 0)
            std.debug.print("[{s}] seed={d} op={d}\n", .{ name, seed, op });

        // ~fault_percent% of operations: arm a write fault on the db file.
        if (fault_rng.uintLessThan(u8, 100) < config.fault_percent) {
            io.setFaultAfterWrites(path, fault_rng.uintLessThan(u32, config.max_writes_before_fault));
        }

        workload.next(&db, rng) catch |fault_err| {
            io.resetFault();
            std.debug.print("[{s}] seed={d} op={d} fault={s} — closing\n", .{ name, seed, op, @errorName(fault_err) });
            db.deinit();
            io.crash();
            db = Database.open(alloc, io.io(), path) catch |open_err| {
                std.debug.print("[{s}] seed={d} recovery failed (fault={s}): {s}\n", .{
                    name, seed, @errorName(fault_err), @errorName(open_err),
                });
                return open_err;
            };
            std.debug.print("[{s}] seed={d} op={d} reopened\n", .{ name, seed, op });
            try workload.verify(&db, rng);
            continue;
        };

        io.resetFault();
        try workload.verify(&db, rng);
    }

    std.debug.print("[{s}] seed={d} close\n", .{ name, seed });
    db.deinit();
}
