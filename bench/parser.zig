// Parser for .sql benchmark files.
//
// Format:
//   -- name: <label>      — benchmark name shown in output
//   -- group: <label>     — group name for --group filtering
//   (blank lines and other -- comments are ignored)
//
//   -- load               — section header: SQL run before timing
//   <sql statements>
//
//   -- run                — section header: SQL that is timed
//   <sql statements>
//
// SQL statements within a section are separated by semicolons.
// Statements may span multiple lines; the semicolon may appear mid-line
// or at the end of a line.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Benchmark = struct {
    name: []const u8,
    group: []const u8,
    // Each entry is one complete SQL statement (no trailing semicolon).
    load_stmts: []const []const u8,
    run_stmts: []const []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Benchmark) void {
        self.arena.deinit();
    }
};

pub fn parse(alloc: Allocator, content: []const u8) !Benchmark {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var name: []const u8 = "(unnamed)";
    var group: []const u8 = "";

    const Section = enum { none, load, run };
    var section = Section.none;

    // Accumulate raw SQL text per section, then split by semicolons at the end.
    var load_text: std.ArrayList(u8) = .empty;
    var run_text: std.ArrayList(u8) = .empty;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r ");

        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "-- name:")) {
            name = try aa.dupe(u8, std.mem.trim(u8, line["-- name:".len..], " \t"));
            continue;
        }
        if (std.mem.startsWith(u8, line, "-- group:")) {
            group = try aa.dupe(u8, std.mem.trim(u8, line["-- group:".len..], " \t"));
            continue;
        }
        if (std.mem.eql(u8, line, "-- load")) {
            section = .load;
            continue;
        }
        if (std.mem.eql(u8, line, "-- run")) {
            section = .run;
            continue;
        }
        if (std.mem.startsWith(u8, line, "--")) continue;

        const buf = switch (section) {
            .none => continue,
            .load => &load_text,
            .run => &run_text,
        };
        try buf.appendSlice(aa, line);
        try buf.append(aa, '\n');
    }

    return .{
        .name = name,
        .group = group,
        .load_stmts = try splitStatements(aa, load_text.items),
        .run_stmts = try splitStatements(aa, run_text.items),
        .arena = arena,
    };
}

// Splits a block of SQL text on semicolons, returning trimmed non-empty statements.
fn splitStatements(alloc: Allocator, sql: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, sql, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len > 0) {
            try out.append(alloc, try alloc.dupe(u8, trimmed));
        }
    }
    return out.toOwnedSlice(alloc);
}
