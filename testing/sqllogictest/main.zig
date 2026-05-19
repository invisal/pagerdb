// sqllogictest runner entry point.
//
// Usage:
//   zig build slt                                        — scan tests/ (default)
//   zig build slt -- --dir testing/sqllogictest/upstream — scan a directory recursively
//   zig build slt -- path/to/test.slt                    — run specific file(s)
//   zig build slt -- --show-errors 5                     — show up to 5 failure details per file
//   zig build slt -- --agent                             — stop at first failure, write full diff and DB state to last_error.md
//   zig build slt -- --sqlite                            — run against SQLite3 instead of PagerDB
//   zig build slt -- --jobs 4                            — limit to 4 parallel workers
//   zig build slt -- --json out.json                     — write per-file results as JSON
//   zig build slt -- --commit abc123                     — embed git SHA in JSON output
//
// Each file runs with a 256 MB memory cap (hard limit, not configurable).

const std = @import("std");
const runner = @import("runner.zig");

const DEFAULT_TEST_DIR = "testing/sqllogictest/tests";
const MEM_LIMIT_BYTES: usize = 256 * 1024 * 1024;
const Dir = std.Io.Dir;

// Per-file result written by the owning worker thread.
// Indexed by file position in all_files, so no two threads touch the same slot.
const FileResult = struct {
    passed: usize = 0,
    failed: usize = 0,
    peak_mem_bytes: usize = 0,
    db_size_bytes: usize = 0,
};

const WorkerCtx = struct {
    io: std.Io,
    paths: []const []const u8,
    show_errors: usize,
    agent: bool,
    sqlite: bool,
    thread_id: usize,
    thread_count: usize,
    file_results: []FileResult,
};

// Wraps a backing allocator to track current and peak bytes in use.
// Alloc/resize/remap return failure once MEM_LIMIT_BYTES would be exceeded.
// Thread-safety: one CountingAllocator per file/thread, no sharing.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    current_bytes: usize = 0,
    peak_bytes: usize = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (self.current_bytes + len > MEM_LIMIT_BYTES) return null;
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.current_bytes += len;
        if (self.current_bytes > self.peak_bytes) self.peak_bytes = self.current_bytes;
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) {
            const delta = new_len - memory.len;
            if (self.current_bytes + delta > MEM_LIMIT_BYTES) return false;
        }
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) {
            self.current_bytes += new_len - memory.len;
            if (self.current_bytes > self.peak_bytes) self.peak_bytes = self.current_bytes;
        } else {
            self.current_bytes -= memory.len - new_len;
        }
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) {
            const delta = new_len - memory.len;
            if (self.current_bytes + delta > MEM_LIMIT_BYTES) return null;
        }
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) {
            self.current_bytes += new_len - memory.len;
            if (self.current_bytes > self.peak_bytes) self.peak_bytes = self.current_bytes;
        } else {
            self.current_bytes -= memory.len - new_len;
        }
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.current_bytes -= memory.len;
    }
};

fn fmtMem(bytes: usize) struct { value: usize, unit: []const u8 } {
    if (bytes >= 1024 * 1024) return .{ .value = bytes / (1024 * 1024), .unit = "MB" };
    if (bytes >= 1024) return .{ .value = bytes / 1024, .unit = "KB" };
    return .{ .value = bytes, .unit = "B" };
}

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
    var agent: bool = false;
    var sqlite: bool = false;
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
        } else if (std.mem.eql(u8, args[i], "--agent")) {
            agent = true;
        } else if (std.mem.eql(u8, args[i], "--sqlite")) {
            sqlite = true;
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

    // --agent requires sequential execution so we can stop after the first failed file.
    if (agent) n_jobs = 1;

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
            .agent = agent,
            .sqlite = sqlite,
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

        // CountingAllocator wraps page_allocator and serves as the backing
        // store for both the file-level arena and per-statement arenas (via
        // page_alloc in runner). This lets us measure peak bytes in use at
        // any point during the file run, and enforce the 256 MB hard cap.
        var counter = CountingAllocator{ .backing = std.heap.page_allocator };
        var arena = std.heap.ArenaAllocator.init(counter.allocator());
        defer arena.deinit();

        var db_bytes: usize = 0;
        const result = runner.runFile(arena.allocator(), counter.allocator(), ctx.io, path, ctx.show_errors, ctx.agent, ctx.sqlite, &db_bytes) catch |err| {
            const db = fmtMem(db_bytes);
            if (err == error.OutOfMemory) {
                std.debug.print("{s}: exceeded 256 MB memory limit [db:{d}{s}]\n", .{ path, db.value, db.unit });
            } else {
                std.debug.print("error in {s}: {s} [db:{d}{s}]\n", .{ path, @errorName(err), db.value, db.unit });
            }
            ctx.file_results[file_idx].failed += 1;
            if (ctx.agent) break;
            continue;
        };

        const peak = fmtMem(counter.peak_bytes);
        const db = fmtMem(db_bytes);
        ctx.file_results[file_idx] = .{
            .passed = result.passed,
            .failed = result.failed,
            .peak_mem_bytes = counter.peak_bytes,
            .db_size_bytes = db_bytes,
        };

        const status = if (result.failed == 0) "ok" else "FAILED";
        std.debug.print("{s}: {d} passed, {d} failed [{s}] db:{d}{s} peak:{d}{s}\n", .{
            path, result.passed, result.failed, status, db.value, db.unit, peak.value, peak.unit,
        });

        if (ctx.agent and result.failed > 0) break;
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
