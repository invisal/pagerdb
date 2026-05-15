const std = @import("std");

const Engine = @import("core");

const ManagedDatabase = Engine.ManagedDatabase;
const DiskPager = Engine.DiskPager;
const InMemoryPager = Engine.InMemoryPager;

const repl = @import("repl.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);

    // Handle help flag
    if (args.len > 1 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        printUsage(args[0]);
        return;
    }

    const path: ?[]const u8 = if (args.len < 2) null else args[1];
    var db = ManagedDatabase.open(alloc, io, path) catch |err| switch (err) {
        error.AccessDenied => {
            return error.AccessDenied;
        },
        error.IsDir => {
            return error.IsDir;
        },
        else => {
            return err;
        },
    };

    defer db.deinit();

    var out_buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    try printWelcome(&out.interface);

    try repl.run(alloc, io, &db);
}

fn printWelcome(out: *std.Io.Writer) !void {
    try out.print("Type SQL followed by ';', or .help for commands.\n\n", .{});
    try out.flush();
}

fn printUsage(exe: []const u8) void {
    std.debug.print(
        \\Usage: {s} [database-file]
        \\
        \\Options:
        \\  -h, --help    Show this help message
        \\
        \\Arguments:
        \\  database-file  Path to the database file (optional)
        \\                 If omitted, uses in-memory mode (data is lost on exit)
        \\                 If file doesn't exist, it will be created
        \\
        \\Examples:
        \\  {s}           # Start in-memory database
        \\  {s} mydb.db   # Open or create mydb.db
        \\
    , .{ exe, exe, exe });
}
