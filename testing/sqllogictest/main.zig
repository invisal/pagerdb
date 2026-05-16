// sqllogictest runner entry point.
//
// Usage:
//   zig build slt                                        — scan tests/ (default)
//   zig build slt -- --dir testing/sqllogictest/upstream — scan a directory recursively
//   zig build slt -- path/to/test.slt                    — run specific file(s)
//   zig build slt -- --show-errors 5                     — show up to 5 failure details per file
//   zig build slt -- --fail-fast                         — stop at first failure, dump full diff and DB state
//   zig build slt -- --jobs 4                            — limit to 4 parallel workers
//   zig build slt -- --json out.json                     — write per-file results as JSON
//   zig build slt -- --commit abc123                     — embed git SHA in JSON output

const std = @import("std");
const runner = @import("runner.zig");

const DEFAULT_TEST_DIR = "testing/sqllogictest/tests";
const Dir = std.Io.Dir;

// Per-file result written by the owning worker thread.
// Indexed by file position in all_files, so no two threads touch the same slot.
const FileResult = struct {
    passed: usize = 0,
    failed: usize = 0,
};

const WorkerCtx = struct {
    io: std.Io,
    paths: []const []const u8,
    show_errors: usize,
    fail_fast: bool,
    thread_id: usize,
    thread_count: usize,
    file_results: []FileResult,
};

const JsonSummary = struct { passed: usize, failed: usize, files: usize };
const JsonFile = struct { path: []const u8, passed: usize, failed: usize };
const JsonOutput = struct {
    generated_at: i64,
    commit: []const u8,
    summary: JsonSummary,
    files: []const JsonFile,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);

    var scan_dir: []const u8 = DEFAULT_TEST_DIR;
    var show_errors: usize = 0;
    var fail_fast: bool = false;
    var n_jobs: ?usize = null;
    var json_path: ?[]const u8 = null;
    var commit: []const u8 = "";
    var explicit_files: std.ArrayList([]const u8) = .empty;
    defer explicit_files.deinit(alloc);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dir") and i + 1 < args.len) {
            i += 1;
            scan_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--show-errors") and i + 1 < args.len) {
            i += 1;
            show_errors = std.fmt.parseInt(usize, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, args[i], "--fail-fast")) {
            fail_fast = true;
        } else if (std.mem.eql(u8, args[i], "--jobs") and i + 1 < args.len) {
            i += 1;
            n_jobs = std.fmt.parseInt(usize, args[i], 10) catch null;
        } else if (std.mem.eql(u8, args[i], "--json") and i + 1 < args.len) {
            i += 1;
            json_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--commit") and i + 1 < args.len) {
            i += 1;
            commit = args[i];
        } else {
            try explicit_files.append(alloc, args[i]);
        }
    }

    // fail_fast requires sequential execution so we can stop after the first failed file.
    if (fail_fast) n_jobs = 1;

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
        try collectFiles(alloc, io, scan_dir, &all_files);
        std.sort.block([]const u8, all_files.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
    }

    if (all_files.items.len == 0) {
        std.debug.print("no test files found\n", .{});
        return;
    }

    // One result slot per file; each slot is written by exactly one thread (via hash
    // partitioning), so no synchronization is needed.
    const file_results = try alloc.alloc(FileResult, all_files.items.len);
    defer alloc.free(file_results);
    @memset(file_results, .{});

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const thread_count = @min(n_jobs orelse cpu_count, all_files.items.len);

    const threads = try alloc.alloc(std.Thread, thread_count);
    defer alloc.free(threads);

    for (threads, 0..) |*t, id| {
        t.* = try std.Thread.spawn(.{}, workerFn, .{WorkerCtx{
            .io = io,
            .paths = all_files.items,
            .show_errors = show_errors,
            .fail_fast = fail_fast,
            .thread_id = id,
            .thread_count = thread_count,
            .file_results = file_results,
        }});
    }
    for (threads) |t| t.join();

    var total_passed: usize = 0;
    var total_failed: usize = 0;
    for (file_results) |r| {
        total_passed += r.passed;
        total_failed += r.failed;
    }

    if (json_path) |path| {
        try writeJson(alloc, io, path, commit, all_files.items, file_results);
    }

    const total = total_passed + total_failed;
    const pct: f64 = if (total == 0) 100.0 else @as(f64, @floatFromInt(total_passed)) / @as(f64, @floatFromInt(total)) * 100.0;
    std.debug.print("\n{d} passed, {d} failed across {d} file(s) ({d:.1}%)\n", .{
        total_passed, total_failed, all_files.items.len, pct,
    });

    if (total_failed > 0) std.process.exit(1);
}

fn workerFn(ctx: WorkerCtx) void {
    for (ctx.paths, 0..) |path, file_idx| {
        if (std.hash.Wyhash.hash(0, path) % ctx.thread_count != ctx.thread_id) continue;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const result = runner.runFile(arena.allocator(), ctx.io, path, ctx.show_errors, ctx.fail_fast) catch |err| {
            std.debug.print("error in {s}: {s}\n", .{ path, @errorName(err) });
            ctx.file_results[file_idx].failed += 1;
            if (ctx.fail_fast) break;
            continue;
        };

        ctx.file_results[file_idx] = .{ .passed = result.passed, .failed = result.failed };

        const status = if (result.failed == 0) "ok" else "FAILED";
        std.debug.print("{s}: {d} passed, {d} failed [{s}]\n", .{
            path, result.passed, result.failed, status,
        });

        if (ctx.fail_fast and result.failed > 0) break;
    }
}

fn writeJson(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    commit: []const u8,
    paths: []const []const u8,
    results: []const FileResult,
) !void {
    const json_files = try alloc.alloc(JsonFile, paths.len);
    defer alloc.free(json_files);

    var total_passed: usize = 0;
    var total_failed: usize = 0;
    for (paths, results, json_files) |p, r, *jf| {
        jf.* = .{ .path = p, .passed = r.passed, .failed = r.failed };
        total_passed += r.passed;
        total_failed += r.failed;
    }

    const generated_at = std.Io.Clock.real.now(io).toSeconds();

    const output = JsonOutput{
        .generated_at = generated_at,
        .commit = commit,
        .summary = .{ .passed = total_passed, .failed = total_failed, .files = paths.len },
        .files = json_files,
    };

    const json_bytes = try std.json.Stringify.valueAlloc(alloc, output, .{ .whitespace = .indent_2 });
    defer alloc.free(json_bytes);

    const json_file = try Dir.cwd().createFile(io, path, .{});
    defer json_file.close(io);
    try json_file.writeStreamingAll(io, json_bytes);
}

// Recursively collects all .slt / .test files under dir_path into out.
fn collectFiles(alloc: std.mem.Allocator, io: std.Io, dir_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("error opening dir '{s}': {s}\n", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => {
                try collectFiles(alloc, io, full, out);
                alloc.free(full);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".slt") or
                    std.mem.endsWith(u8, entry.name, ".test"))
                {
                    try out.append(alloc, full);
                } else {
                    alloc.free(full);
                }
            },
            else => alloc.free(full),
        }
    }
}
