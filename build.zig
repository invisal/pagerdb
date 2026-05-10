const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Core library module ───────────────────────────────────────────────────
    const core_mod = b.createModule(.{
        .root_source_file = b.path("core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "pagerdb",
        .root_module = core_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // ── CLI executable ────────────────────────────────────────────────────────
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("core", core_mod);

    const exe = b.addExecutable(.{
        .name = "pagerdb",
        .root_module = cli_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the CLI");
    if (b.args) |run_args| run_exe.addArgs(run_args);
    run_step.dependOn(&run_exe.step);

    // ── Benchmark executable ──────────────────────────────────────────────────
    // Benchmarks always use ReleaseFast — debug GPA overhead skews results by 100-2000x
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    bench_mod.addImport("core", core_mod);
    bench_mod.linkSystemLibrary("sqlite3", .{});

    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run INSERT / SELECT * benchmarks vs SQLite3");
    bench_step.dependOn(&run_bench.step);

    // ── DST executable ───────────────────────────────────────────────────────
    const dst_mod = b.createModule(.{
        .root_source_file = b.path("testing/simulator/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    dst_mod.addImport("core", core_mod);

    const dst_exe = b.addExecutable(.{
        .name = "dst",
        .root_module = dst_mod,
    });
    b.installArtifact(dst_exe);

    const run_dst = b.addRunArtifact(dst_exe);
    const dst_step = b.step("dst", "Run deterministic simulation tests");
    if (b.args) |dst_args| run_dst.addArgs(dst_args);
    dst_step.dependOn(&run_dst.step);

    // ── Examples (auto-discovered: any examples/<name>/root.zig) ─────────────
    // Build one example:  zig build example-<name>
    // Run one example:    zig build run-example-<name>
    // Build all examples: zig build examples
    const examples_step = b.step("examples", "Build all examples");
    {
        var examples_dir = b.build_root.handle.openDir(b.graph.io, "examples", .{ .iterate = true }) catch null;
        if (examples_dir) |*dir| {
            defer dir.close(b.graph.io);
            var it = dir.iterate();
            while (it.next(b.graph.io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                const root_path = b.fmt("examples/{s}/root.zig", .{entry.name});
                if (b.build_root.handle.access(b.graph.io, root_path, .{}) != error.FileNotFound) {
                    const ex_mod = b.createModule(.{
                        .root_source_file = b.path(root_path),
                        .target = target,
                        .optimize = optimize,
                    });
                    ex_mod.addImport("core", core_mod);

                    const ex_exe = b.addExecutable(.{
                        .name = entry.name,
                        .root_module = ex_mod,
                    });

                    const build_step_name = b.fmt("example-{s}", .{entry.name});
                    const build_step_desc = b.fmt("Build example: {s}", .{entry.name});
                    const ex_build_step = b.step(build_step_name, build_step_desc);
                    ex_build_step.dependOn(&b.addInstallArtifact(ex_exe, .{}).step);
                    examples_step.dependOn(&b.addInstallArtifact(ex_exe, .{}).step);

                    const run_ex = b.addRunArtifact(ex_exe);
                    const run_step_name = b.fmt("run-example-{s}", .{entry.name});
                    const run_step_desc = b.fmt("Run example: {s}", .{entry.name});
                    const ex_run_step = b.step(run_step_name, run_step_desc);
                    if (b.args) |run_args| run_ex.addArgs(run_args);
                    ex_run_step.dependOn(&run_ex.step);
                }
            }
        }
    }

    // ── WASM binding ─────────────────────────────────────────────────────────
    // Build: zig build wasm  →  zig-out/bin/pagerdb.wasm
    // core/wasm_root.zig exposes only the in-memory subset of the API (no
    // DiskPager, no WAL) so the module compiles cleanly for wasm32-freestanding.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_core_mod = b.createModule(.{
        .root_source_file = b.path("core/wasm_root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("wasm/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_mod.addImport("core", wasm_core_mod);
    const wasm_exe = b.addExecutable(.{
        .name = "pagerdb",
        .root_module = wasm_mod,
    });
    wasm_exe.entry = .disabled; // no main() — only exported functions
    wasm_exe.rdynamic = true; // keep export fn symbols visible in the .wasm output
    const wasm_step = b.step("wasm", "Build WASM binding for browser/Node.js use");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);

    // ── Tests (rooted at the core library) ───────────────────────────────────
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "Filter tests",
    );

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = if (test_filter) |f| &[_][]const u8{f} else &.{},
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    if (b.args) |args| run_unit_tests.addArgs(args);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
