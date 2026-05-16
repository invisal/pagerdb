// sqllogictest runner entry point.
//
// Usage:
//   zig build slt                                        — scan tests/ (default)
//   zig build slt -- --dir testing/sqllogictest/upstream — scan a directory recursively
//   zig build slt -- path/to/test.slt                    — run specific file(s)
//   zig build slt -- --show-errors 5                     — show up to 5 failure details per file

const std = @import("std");
const runner = @import("runner.zig");

const DEFAULT_TEST_DIR = "testing/sqllogictest/tests";
const Dir = std.Io.Dir;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);

    var scan_dir: []const u8 = DEFAULT_TEST_DIR;
    var show_errors: usize = 0;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(alloc);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dir") and i + 1 < args.len) {
            i += 1;
            scan_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--show-errors") and i + 1 < args.len) {
            i += 1;
            show_errors = std.fmt.parseInt(usize, args[i], 10) catch 0;
        } else {
            try files.append(alloc, args[i]);
        }
    }

    var total_passed: usize = 0;
    var total_failed: usize = 0;
    var file_count: usize = 0;

    if (files.items.len > 0) {
        for (files.items) |path| {
            try runOneFile(alloc, io, path, show_errors, &total_passed, &total_failed, &file_count);
        }
    } else {
        try runDir(alloc, io, scan_dir, show_errors, &total_passed, &total_failed, &file_count);
    }

    std.debug.print("\n{d} passed, {d} failed across {d} file(s)\n", .{ total_passed, total_failed, file_count });

    if (total_failed > 0) std.process.exit(1);
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

fn runDir(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    show_errors: usize,
    total_passed: *usize,
    total_failed: *usize,
    file_count: *usize,
) !void {
    var all_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (all_files.items) |f| alloc.free(f);
        all_files.deinit(alloc);
    }

    try collectFiles(alloc, io, dir_path, &all_files);

    std.sort.block([]const u8, all_files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    for (all_files.items) |path| {
        try runOneFile(alloc, io, path, show_errors, total_passed, total_failed, file_count);
    }
}

fn runOneFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    show_errors: usize,
    total_passed: *usize,
    total_failed: *usize,
    file_count: *usize,
) !void {
    const result = try runner.runFile(alloc, io, path, show_errors);
    total_passed.* += result.passed;
    total_failed.* += result.failed;
    file_count.* += 1;

    const status = if (result.failed == 0) "ok" else "FAILED";
    std.debug.print("{s}: {d} passed, {d} failed [{s}]\n", .{ path, result.passed, result.failed, status });
}
