const std = @import("std");
const lib = @import("core");
const Db = lib.Database;
const execute = lib.execute;
const Console = @import("console.zig").Console;

const PROMPT = "visaldb> ";
const CONT_PROMPT = "   ...> ";

pub fn run(db: *Db, io: std.Io, alloc: std.mem.Allocator) !void {
    var out_buf: [4096]u8 = undefined;
    var err_buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var err = std.Io.File.stderr().writerStreaming(io, &err_buf);

    const C = Console(@TypeOf(io));
    var console = try C.setup(io);
    defer console.restore();

    var history: std.ArrayList([]u8) = .empty;
    defer {
        for (history.items) |e| alloc.free(e);
        history.deinit(alloc);
    }
    var hist_cursor: ?usize = null;
    var prefill: []const u8 = "";

    var sql_buf: std.ArrayList(u8) = .empty;
    defer sql_buf.deinit(alloc);
    var in_continuation = false;

    var line_buf: [4096]u8 = undefined;

    while (true) {
        const prompt = if (in_continuation) CONT_PROMPT else PROMPT;
        const result = try console.readLine(prompt, &line_buf, prefill) orelse break;

        switch (result) {
            .line => |line| {
                hist_cursor = null;
                prefill = "";

                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;

                if (!in_continuation and trimmed[0] == '.') {
                    handleMeta(db, trimmed, io, alloc, &out.interface, &err.interface) catch |e| switch (e) {
                        error.Exit => return,
                        else => {
                            try err.interface.print("Error: {s}\n", .{@errorName(e)});
                            try err.interface.flush();
                        },
                    };
                    try out.interface.flush();
                    continue;
                }

                if (sql_buf.items.len > 0) try sql_buf.append(alloc, ' ');
                try sql_buf.appendSlice(alloc, trimmed);

                if (std.mem.indexOfScalar(u8, sql_buf.items, ';') != null) {
                    in_continuation = false;
                    const sql = std.mem.trimEnd(u8, sql_buf.items, " \t\r\n;");
                    if (sql.len > 0) {
                        const is_dup = history.items.len > 0 and
                            std.mem.eql(u8, history.items[history.items.len - 1], sql_buf.items);
                        if (!is_dup) try history.append(alloc, try alloc.dupe(u8, sql_buf.items));

                        execAndPrint(db, sql, alloc, &out.interface, &err.interface) catch |e| {
                            try err.interface.print("Error: {s}\n", .{@errorName(e)});
                            try err.interface.flush();
                        };
                        try out.interface.flush();
                    }
                    sql_buf.clearRetainingCapacity();
                } else {
                    in_continuation = true;
                }
            },

            .history_up => {
                if (in_continuation) continue;
                if (history.items.len == 0) continue;
                if (hist_cursor == null) {
                    hist_cursor = history.items.len - 1;
                } else if (hist_cursor.? > 0) {
                    hist_cursor = hist_cursor.? - 1;
                } else continue;
                prefill = history.items[hist_cursor.?];
            },

            .history_down => {
                if (in_continuation) continue;
                if (hist_cursor == null) continue;
                if (hist_cursor.? + 1 < history.items.len) {
                    hist_cursor = hist_cursor.? + 1;
                    prefill = history.items[hist_cursor.?];
                } else {
                    hist_cursor = null;
                    prefill = "";
                }
            },
        }
    }
}

// Handle dot-commands (meta-commands) like .help, .quit, .tables.
// These are not SQL statements; they're client-side directives.
// We return error.Exit for .quit/.exit so the caller can break the REPL loop.
fn handleMeta(
    db: *Db,
    line: []const u8,
    io: std.Io,
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !void {
    _ = err;
    if (std.ascii.eqlIgnoreCase(line, ".quit") or
        std.ascii.eqlIgnoreCase(line, ".exit"))
    {
        return error.Exit;
    } else if (std.ascii.eqlIgnoreCase(line, ".help")) {
        try printHelp(out);
    } else if (std.ascii.eqlIgnoreCase(line, ".tables")) {
        try printTables(db, alloc, io, out);
    } else {
        try out.print("Unknown command: {s}  (try .help)\n", .{line});
    }
}

// Execute SQL and format results for display.
// Uses the core debug module for consistent output formatting.
fn execAndPrint(
    db: *Db,
    sql: []const u8,
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !void {
    _ = err;
    var result = try execute(db, sql, alloc);
    defer result.deinit();
    try lib.debug.printTo(result, out);
}

fn printTables(db: *Db, alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer) !void {
    _ = alloc;
    _ = io;
    var it = db.cat.tables.keyIterator();
    var count: usize = 0;
    while (it.next()) |key| {
        if (std.mem.startsWith(u8, key.*, "__")) continue;
        try out.print("{s}\n", .{key.*});
        count += 1;
    }
    if (count == 0) try out.print("(no tables)\n", .{});
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print(
        \\Meta-commands:
        \\  .help     Show this help
        \\  .tables   List all user tables
        \\  .quit     Exit  (Ctrl-D also works)
        \\
        \\Enter SQL terminated by ';'. Statements can span multiple lines.
        \\
        \\Supported SQL:
        \\  CREATE TABLE t (col TYPE [NOT NULL], ...)
        \\  INSERT INTO t VALUES (v1, v2, ...)
        \\  SELECT [* | col, ...] FROM t [WHERE expr]
        \\  UPDATE t SET col = expr [WHERE expr]
        \\  DELETE FROM t [WHERE expr]
        \\
        \\Types: INT  REAL  TEXT  BLOB
        \\
    , .{});
}
