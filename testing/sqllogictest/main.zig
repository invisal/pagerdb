// sqllogictest runner — single-file, sequential, PagerDB only.
//
// Usage:
//   zig build slt -- <file.test>
//
// Each run gets a fresh in-memory database so tests are isolated.

const std = @import("std");
const pdb = @import("core");
const parser = @import("parser.zig");
const matcher = @import("matcher.zig");

const Database = pdb.Database;
const InMemoryPager = pdb.InMemoryPager;
const execute = pdb.execute;
const check_btree = pdb.debug.check_btree;

// Tracks the record currently under execution so the panic handler can print it.
var panic_ctx: struct {
    counter: usize = 0,
    file: []const u8 = "",
    line: usize = 0,
    sql: []const u8 = "",
} = .{};

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    if (panic_ctx.counter > 0) {
        std.debug.print(
            "\n\nPANIC at {s}:{d} {s}\nStatement:\n{s}\n\n\n",
            .{ panic_ctx.file, panic_ctx.line, msg, panic_ctx.sql },
        );
    }
    std.debug.defaultPanic(msg, ret_addr);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);

    var file_path: ?[]const u8 = null;
    var btree_check_table: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--btree-check=")) {
            btree_check_table = arg["--btree-check=".len..];
        } else {
            file_path = arg;
        }
    }

    const path = file_path orelse {
        std.debug.print("Usage: slt <file.test>\n", .{});
        return;
    };

    const content = try readFile(alloc, io, path);
    defer alloc.free(content);

    var parsed = try parser.parse(alloc, content);
    defer parsed.deinit();

    // Fresh in-memory database per run — no leftover state between test files.
    var db = try Database.init(try InMemoryPager.create(alloc), alloc);
    defer db.close();

    var passed: usize = 0;
    var failed: usize = 0;
    var skip_next = false;

    for (parsed.records, 1..) |record, counter| {
        switch (record) {
            // skipif / onlyif do not execute SQL — they set a flag that causes
            // the immediately following record to be skipped.
            .skipif => |engine| {
                if (engineMatches(engine)) skip_next = true;
                continue;
            },
            .onlyif => |engine| {
                if (!engineMatches(engine)) skip_next = true;
                continue;
            },

            // statement: run SQL, check only whether it succeeded or errored.
            // No rows are inspected.
            .statement => |stmt| {
                if (skip_next) {
                    skip_next = false;
                    continue;
                }

                panic_ctx = .{ .counter = counter, .file = path, .line = stmt.line, .sql = stmt.sql };
                var arena = std.heap.ArenaAllocator.init(alloc);
                defer arena.deinit();

                const exec_result = try execute(arena.allocator(), db, stmt.sql);

                switch (matcher.matchStatement(exec_result, stmt.expected)) {
                    .match => passed += 1,
                    .mismatch => {
                        failed += 1;
                        // std.debug.print("[n:{d}] FAIL\n", .{counter});
                        // printStatementMismatch(path, stmt, m);
                    },
                }

                if (btree_check_table) |tname| {
                    checkTableBtrees(alloc, db, tname) catch |err| {
                        std.debug.print("[n:{d}] BTREE INVARIANT FAIL after statement: {}\n  sql: {s}\n", .{ counter, err, stmt.sql });
                        std.process.exit(1);
                    };
                }
            },

            // query: run SQL, format every cell to a string using the type_string
            // hint, then compare the flat value list against the expected values.
            //
            // The type_string maps column index → format hint: I=integer, R=real,
            // T=text. It affects how real numbers are displayed (e.g. type I causes
            // truncation to match SQLite reference output).
            .query => |qry| {
                if (skip_next) {
                    skip_next = false;
                    continue;
                }

                panic_ctx = .{ .counter = counter, .file = path, .line = qry.line, .sql = qry.sql };
                var arena = std.heap.ArenaAllocator.init(alloc);
                defer arena.deinit();

                const exec_result = try execute(arena.allocator(), db, qry.sql);

                if (exec_result == .err) {
                    // The query returned a SQL error — always a mismatch for a
                    // query record (queries are expected to return rows, not errors).
                    failed += 1;
                    // std.debug.print("[n:{d}] FAIL\n", .{counter});
                    // std.debug.print("FAIL {s}:{d}: sql error: {s}\n  sql: {s}\n", .{
                    //     path, qry.line, exec_result.err.message, qry.sql,
                    // });
                    continue;
                }

                if (exec_result != .result_set) {
                    failed += 1;
                    // std.debug.print("[n:{d}] FAIL\n", .{counter});
                    // std.debug.print("FAIL {s}:{d}: query returned no result set\n  sql: {s}\n", .{
                    //     path, qry.line, qry.sql,
                    // });
                    continue;
                }

                const rs = &exec_result.result_set;
                const col_count = rs.columns.len;

                // Format every cell to a string before handing off to matcher.
                // matcher.matchQuery needs [][]const u8, not raw DB values.
                var values = try arena.allocator().alloc([]const u8, rs.rows.len * col_count);
                for (rs.rows, 0..) |row, ri| {
                    for (row.values, 0..) |val, ci| {
                        const col_type: u8 = if (ci < qry.type_string.len) qry.type_string[ci] else 0;
                        values[ri * col_count + ci] = try formatValue(arena.allocator(), val, col_type);
                    }
                }

                // matchQuery sorts values in-place (for rowsort / valuesort) then compares.
                switch (matcher.matchQuery(values, col_count, qry.expected, qry.sort_mode)) {
                    .match => passed += 1,
                    .mismatch => {
                        failed += 1;
                        // std.debug.print("[n:{d}] FAIL\n", .{counter});
                        // printQueryMismatch(path, qry, m, values, col_count);
                    },
                }

                if (btree_check_table) |tname| {
                    checkTableBtrees(alloc, db, tname) catch |err| {
                        std.debug.print("[n:{d}] BTREE INVARIANT FAIL after query: {}\n  sql: {s}\n", .{ counter, err, qry.sql });
                        std.process.exit(1);
                    };
                }
            },
        }
    }

    const total = passed + failed;
    const pct: f64 = if (total == 0) 100.0 else @as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(total)) * 100.0;
    std.debug.print("{s}: {d} passed, {d} failed ({d:.1}%)\n", .{ path, passed, failed, pct });

    if (failed > 0) std.process.exit(1);
}

// --------------------------
// B-tree invariant checking
// --------------------------

// Check all B-trees owned by a named table: the rowid tree and every index tree.
// Called after each SLT operation when --btree-check=<name> is active.
fn checkTableBtrees(alloc: std.mem.Allocator, db: *Database, table_name: []const u8) !void {
    const meta = db.cat.tables.get(table_name) orelse return; // table not yet created — skip
    check_btree.checkBtreeInvariant(pdb.btree.RowidFormat, alloc, &db.pager, meta.btree_root) catch |err| {
        std.debug.print("  rowid tree (root={d})\n", .{meta.btree_root});
        return err;
    };
    for (meta.indexes) |idx| {
        check_btree.checkBtreeInvariant(pdb.btree.IndexFormat, alloc, &db.pager, idx.btree_root) catch |err| {
            std.debug.print("  index '{s}' tree (root={d})\n", .{ idx.name, idx.btree_root });
            return err;
        };
    }
}

// --------------------------
// Engine matching
// --------------------------

// We target ANSI SQL / PostgreSQL compatibility, so both "pagerdb" and
// "postgresql" directives apply to us.
fn engineMatches(engine: []const u8) bool {
    return std.mem.eql(u8, engine, "pagerdb") or std.mem.eql(u8, engine, "postgresql");
}

// --------------------------
// Value formatting
// --------------------------

// Formats a single DB value to an owned string for SLT comparison.
// col_type is the SLT type character from the query type_string:
//   'I' = integer, 'R' = real, 'T' = text, 0 = unknown (treat as text).
// When col_type is 'I' and the stored value is real, we truncate toward zero
// to match the SQLite reference tool's behaviour.
fn formatValue(alloc: std.mem.Allocator, val: anytype, col_type: u8) ![]u8 {
    return switch (val) {
        .null => alloc.dupe(u8, "NULL"),
        .int => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
        .real => |f| if (col_type == 'I')
            std.fmt.allocPrint(alloc, "{d}", .{@as(i64, @intFromFloat(@trunc(f)))})
        else
            // Normalize -0.0 → 0.0 to match reference output.
            std.fmt.allocPrint(alloc, "{d}", .{if (f == 0.0) @as(f64, 0.0) else f}),
        .text => |s| alloc.dupe(u8, s),
        .blob => |b| std.fmt.allocPrint(alloc, "<blob {d}B>", .{b.len}),
    };
}

// --------------------------
// Error printing
// --------------------------

fn printStatementMismatch(path: []const u8, stmt: parser.StatementRecord, m: matcher.Mismatch) void {
    switch (m) {
        .statement => |s| {
            if (s.want_err) {
                std.debug.print("FAIL {s}:{d}: expected error but statement succeeded\n  sql: {s}\n", .{
                    path, stmt.line, stmt.sql,
                });
            } else {
                std.debug.print("FAIL {s}:{d}: expected ok but got error: {s}\n  sql: {s}\n", .{
                    path, stmt.line, s.got_msg orelse "(unknown)", stmt.sql,
                });
            }
        },
        else => {},
    }
}

fn printQueryMismatch(
    path: []const u8,
    qry: parser.QueryRecord,
    m: matcher.Mismatch,
    values: []const []const u8,
    col_count: usize,
) void {
    switch (m) {
        .count => |c| std.debug.print(
            "FAIL {s}:{d}: expected {d} values, got {d}\n  sql: {s}\n",
            .{ path, qry.line, c.expected, c.got, qry.sql },
        ),
        .value => |v| std.debug.print(
            "FAIL {s}:{d}: value[{d}] expected '{s}', got '{s}'\n  sql: {s}\n",
            .{ path, qry.line, v.index, v.expected, v.got, qry.sql },
        ),
        .hash => |h| std.debug.print(
            "FAIL {s}:{d}: hash mismatch (expected {s}, got {s})\n  sql: {s}\n",
            .{ path, qry.line, h.expected_md5, h.got_md5, qry.sql },
        ),
        .sql_error => |msg| std.debug.print(
            "FAIL {s}:{d}: sql error: {s}\n  sql: {s}\n",
            .{ path, qry.line, msg, qry.sql },
        ),
        .statement => {},
    }
    _ = values;
    _ = col_count;
}

// --------------------------
// File I/O
// --------------------------

fn readFile(alloc: std.mem.Allocator, io: std.Io, filename: []const u8) ![]u8 {
    const f = try std.Io.Dir.cwd().openFile(io, filename, .{ .mode = .read_only });
    defer f.close(io);
    const len = @as(usize, try f.length(io));
    const buf = try alloc.alloc(u8, len);
    _ = try f.readPositionalAll(io, buf, 0);
    return buf;
}
