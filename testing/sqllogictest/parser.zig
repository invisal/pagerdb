// Parses sqllogictest (.slt) files into a sequence of records.
//
// Format overview:
//   statement ok          — execute SQL; expect success
//   statement error       — execute SQL; expect an error
//   query <types> [sort]  — execute SQL; compare result rows to expected values
//   skipif <engine>       — skip the next record if engine matches
//   onlyif <engine>       — skip the next record if engine does NOT match
//   # comment             — ignored
//   <blank line>          — separates records
//
// Type string letters: I (integer), R (real), T (text)
// Sort modes: rowsort, valuesort (default = exact order)

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SortMode = enum { none, row_sort, value_sort };
pub const StatementExpected = enum { ok, err };

pub const StatementRecord = struct {
    line: usize,
    sql: []const u8,
    expected: StatementExpected,
};

pub const QueryExpected = union(enum) {
    // Explicit values: one string per result cell, flattened across all rows/columns.
    values: []const []const u8,
    // Hash mode: "N values hashing to <md5>" — used for large result sets.
    hash: struct { count: usize, md5: []const u8 },
};

pub const QueryRecord = struct {
    line: usize,
    sql: []const u8,
    type_string: []const u8,
    sort_mode: SortMode,
    expected: QueryExpected,
};

pub const Record = union(enum) {
    statement: StatementRecord,
    query: QueryRecord,
    skipif: []const u8,
    onlyif: []const u8,
};

pub const ParseResult = struct {
    records: []const Record,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

pub fn parse(alloc: Allocator, content: []const u8) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(alloc);
    const aa = arena.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    var line_nums: std.ArrayList(usize) = .empty;

    var raw_it = std.mem.splitScalar(u8, content, '\n');
    var n: usize = 1;
    while (raw_it.next()) |raw| : (n += 1) {
        try lines.append(aa, std.mem.trimEnd(u8, raw, "\r"));
        try line_nums.append(aa, n);
    }

    var records: std.ArrayList(Record) = .empty;
    var i: usize = 0;

    while (i < lines.items.len) {
        const line = lines.items[i];
        const lnum = line_nums.items[i];

        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) {
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "statement ")) {
            const tail = line["statement ".len..];
            const expected: StatementExpected = if (std.mem.eql(u8, tail, "ok"))
                .ok
            else if (std.mem.eql(u8, tail, "error"))
                .err
            else {
                i += 1;
                continue;
            };

            i += 1;
            var sql_lines: std.ArrayList([]const u8) = .empty;
            while (i < lines.items.len and lines.items[i].len > 0 and
                !std.mem.startsWith(u8, lines.items[i], "#"))
            {
                try sql_lines.append(aa, lines.items[i]);
                i += 1;
            }

            try records.append(aa, .{ .statement = .{
                .line = lnum,
                .sql = try std.mem.join(aa, "\n", sql_lines.items),
                .expected = expected,
            } });
        } else if (std.mem.startsWith(u8, line, "query ")) {
            const tail = line["query ".len..];
            var parts = std.mem.splitScalar(u8, tail, ' ');
            const type_string = parts.next() orelse "";
            const sort_str = parts.next() orelse "";
            const sort_mode: SortMode = if (std.mem.eql(u8, sort_str, "rowsort"))
                .row_sort
            else if (std.mem.eql(u8, sort_str, "valuesort"))
                .value_sort
            else
                .none;

            i += 1;
            var sql_lines: std.ArrayList([]const u8) = .empty;
            while (i < lines.items.len and !std.mem.eql(u8, lines.items[i], "----")) {
                const l = lines.items[i];
                if (l.len > 0 and !std.mem.startsWith(u8, l, "#")) {
                    try sql_lines.append(aa, l);
                }
                i += 1;
            }
            i += 1; // skip "----"

            var raw_expected: std.ArrayList([]const u8) = .empty;
            while (i < lines.items.len and lines.items[i].len > 0) {
                try raw_expected.append(aa, lines.items[i]);
                i += 1;
            }

            const expected: QueryExpected = if (raw_expected.items.len == 1)
                parseHashLine(raw_expected.items[0]) orelse
                    .{ .values = try raw_expected.toOwnedSlice(aa) }
            else
                .{ .values = try raw_expected.toOwnedSlice(aa) };

            try records.append(aa, .{ .query = .{
                .line = lnum,
                .sql = try std.mem.join(aa, "\n", sql_lines.items),
                .type_string = type_string,
                .sort_mode = sort_mode,
                .expected = expected,
            } });
        } else if (std.mem.startsWith(u8, line, "skipif ")) {
            try records.append(aa, .{ .skipif = line["skipif ".len..] });
            i += 1;
        } else if (std.mem.startsWith(u8, line, "onlyif ")) {
            try records.append(aa, .{ .onlyif = line["onlyif ".len..] });
            i += 1;
        } else {
            i += 1;
        }
    }

    return .{
        .records = try records.toOwnedSlice(aa),
        .arena = arena,
    };
}

// Parses "N values hashing to <md5>" into a QueryExpected.hash, or returns
// null if the line does not match the hash format.
fn parseHashLine(line: []const u8) ?QueryExpected {
    const marker = " values hashing to ";
    const marker_pos = std.mem.indexOf(u8, line, marker) orelse return null;
    const count = std.fmt.parseInt(usize, line[0..marker_pos], 10) catch return null;
    const md5 = line[marker_pos + marker.len ..];
    if (md5.len != 32) return null;
    return .{ .hash = .{ .count = count, .md5 = md5 } };
}
