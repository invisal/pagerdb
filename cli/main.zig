const std = @import("std");

const Engine = @import("core");

const Db = Engine.Database;
const DiskPager = Engine.DiskPager;
const InMemoryPager = Engine.InMemoryPager;

const repl = @import("repl.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);

    var out_buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);

    // Handle help flag
    if (args.len > 1 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        printUsage(args[0]);
        return;
    }

    const db: *Db = if (args.len < 2)
        try initInMemoryDb(alloc, &out.interface)
    else
        try initDiskDb(alloc, io, args[1], &out.interface);
    defer db.close();

    try repl.run(db, io, alloc);
}

fn initInMemoryDb(alloc: std.mem.Allocator, out: *std.Io.Writer) !*Db {
    try out.print("PagerDB — in-memory mode (data will be lost on exit)\n", .{});
    try out.print("Type SQL followed by ';', or .help for commands.\n\n", .{});
    try out.flush();

    const pager = try InMemoryPager.create(alloc);
    return try Db.init(pager, alloc);
}

fn initDiskDb(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *std.Io.Writer,
) !*Db {
    const pager = DiskPager.open(alloc, io, path) catch |err| switch (err) {
        error.FileNotFound => {
            try out.print("Creating new database: {s}\n", .{path});
            try out.flush();
            const new_pager = try DiskPager.create(alloc, io, path);
            const db = try Db.init(new_pager, alloc);
            try printWelcome(out, path);
            return db;
        },
        error.AccessDenied => {
            try out.print("Error: Cannot access '{s}' - permission denied\n", .{path});
            return error.AccessDenied;
        },
        error.IsDir => {
            try out.print("Error: '{s}' is a directory, not a database file\n", .{path});
            return error.IsDir;
        },
        else => {
            try out.print("Error: Cannot open '{s}': {s}\n", .{ path, @errorName(err) });
            return err;
        },
    };

    const db = try Db.load(pager, alloc);
    try printWelcome(out, path);
    return db;
}

fn printWelcome(out: *std.Io.Writer, path: []const u8) !void {
    try out.print("PagerDB — {s}\n", .{path});
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
