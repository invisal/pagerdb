const std = @import("std");
const ExecResult = @import("sql/executor.zig").ExecResult;
const ResultSet = @import("sql/executor.zig").ResultSet;
const Row = @import("sql/executor.zig").Row;
const row_mod = @import("row.zig");

// Debug printing utilities for PagerDB.
// These are convenience functions for printing query results during development.
// They format output as ASCII tables similar to the CLI REPL.
//
// The print() functions output to stderr (idiomatic for debug output).
// The printTo() functions allow writing to any writer.

/// Print an ExecResult to stderr.
/// Handles all variants: result_set, affected, created, and err.
/// The caller retains ownership and must call deinit() when done.
pub fn print(result: ExecResult) void {
    switch (result) {
        .result_set => |rs| {
            printResultSet(rs);
        },
        .affected => |n| std.debug.print("{d} row{s} affected\n", .{ n, if (n == 1) "" else "s" }),
        .created => std.debug.print("Table created.\n", .{}),
        .err => |e| std.debug.print("Error ({s}): {s}\n", .{ e.code, e.message }),
    }
}

/// Print an ExecResult to the given writer.
/// For result_set, the caller is responsible for calling deinit on the result set.
pub fn printTo(result: ExecResult, writer: anytype) !void {
    switch (result) {
        .result_set => |rs| {
            try printResultSetTo(rs, writer);
        },
        .affected => |n| try writer.print("{d} row{s} affected\n", .{ n, if (n == 1) "" else "s" }),
        .created => try writer.print("Table created.\n", .{}),
        .err => |e| try writer.print("Error ({s}): {s}\n", .{ e.code, e.message }),
    }
}

/// Print a ResultSet as a formatted ASCII table to stderr.
pub fn printResultSet(rs: ResultSet) void {
    if (rs.columns.len == 0) {
        std.debug.print("(0 rows)\n", .{});
        return;
    }

    // Calculate column widths based on headers and data
    const alloc = std.heap.page_allocator;

    const widths = alloc.alloc(usize, rs.columns.len) catch {
        std.debug.print("Error: out of memory\n", .{});
        return;
    };
    defer alloc.free(widths);

    // Initialize widths with column name lengths
    for (rs.columns, 0..) |col, i| {
        widths[i] = col.len;
    }

    // Expand widths to fit data
    for (rs.rows) |row| {
        for (row.values, 0..) |v, i| {
            const w = valueLen(v);
            if (w > widths[i]) widths[i] = w;
        }
    }

    // Print header row
    printHeaderRow(rs.columns, widths);

    // Print separator line
    printSeparator(widths);

    // Print data rows
    for (rs.rows) |row| {
        printDataRow(row.values, widths);
    }

    std.debug.print("({d} row{s})\n", .{
        rs.rows.len,
        if (rs.rows.len == 1) "" else "s",
    });
}

/// Print a ResultSet as a formatted ASCII table to the given writer.
pub fn printResultSetTo(rs: ResultSet, writer: anytype) !void {
    if (rs.columns.len == 0) {
        try writer.print("(0 rows)\n", .{});
        return;
    }

    // Calculate column widths based on headers and data
    const alloc = std.heap.page_allocator;

    const widths = try alloc.alloc(usize, rs.columns.len);
    defer alloc.free(widths);

    // Initialize widths with column name lengths
    for (rs.columns, 0..) |col, i| {
        widths[i] = col.len;
    }

    // Expand widths to fit data
    for (rs.rows) |row| {
        for (row.values, 0..) |v, i| {
            const w = valueLen(v);
            if (w > widths[i]) widths[i] = w;
        }
    }

    // Print header row
    try writeHeaderRow(writer, rs.columns, widths);

    // Print separator line
    try writeSeparator(writer, widths);

    // Print data rows
    for (rs.rows) |row| {
        try writeDataRow(writer, row.values, widths);
    }

    try writer.print("({d} row{s})\n", .{
        rs.rows.len,
        if (rs.rows.len == 1) "" else "s",
    });
}

// ========== stderr output functions (for debug.print) ==========

/// Print the header row with column names to stderr.
fn printHeaderRow(columns: [][]const u8, widths: []const usize) void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    for (columns, 0..) |col, i| {
        if (i > 0) {
            const sep = " | ";
            @memcpy(buf[pos .. pos + sep.len], sep);
            pos += sep.len;
        }
        @memcpy(buf[pos .. pos + col.len], col);
        pos += col.len;
        pos = padSpacesBuf(&buf, pos, widths[i] - col.len);
    }
    buf[pos] = '\n';
    pos += 1;

    std.debug.print("{s}", .{buf[0..pos]});
}

/// Print a separator line between header and data to stderr.
fn printSeparator(widths: []const usize) void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    for (widths, 0..) |w, i| {
        if (i > 0) {
            const sep = "-+";
            @memcpy(buf[pos .. pos + sep.len], sep);
            pos += sep.len;
        }
        pos = padDashesBuf(&buf, pos, w);
    }
    buf[pos] = '\n';
    pos += 1;

    std.debug.print("{s}", .{buf[0..pos]});
}

/// Print a data row with formatted values to stderr.
fn printDataRow(values: []row_mod.Value, widths: []const usize) void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    for (values, 0..) |v, i| {
        if (i > 0) {
            const sep = " | ";
            @memcpy(buf[pos .. pos + sep.len], sep);
            pos += sep.len;
        }
        pos = formatValueBuf(&buf, pos, v, widths[i]);
    }
    buf[pos] = '\n';
    pos += 1;

    std.debug.print("{s}", .{buf[0..pos]});
}

// ========== writer output functions (for printTo) ==========

/// Write the header row with column names to a writer.
fn writeHeaderRow(writer: anytype, columns: [][]const u8, widths: []const usize) !void {
    for (columns, 0..) |col, i| {
        if (i > 0) try writer.print(" | ", .{});
        try writer.print("{s}", .{col});
        try padSpaces(writer, widths[i] - col.len);
    }
    try writer.print("\n", .{});
}

/// Write a separator line between header and data to a writer.
fn writeSeparator(writer: anytype, widths: []const usize) !void {
    for (widths, 0..) |w, i| {
        if (i > 0) try writer.print("-+-", .{});
        try padDashes(writer, w);
    }
    try writer.print("\n", .{});
}

/// Write a data row with formatted values to a writer.
fn writeDataRow(writer: anytype, values: []row_mod.Value, widths: []const usize) !void {
    for (values, 0..) |v, i| {
        if (i > 0) try writer.print(" | ", .{});
        try writeValue(writer, v, widths[i]);
    }
    try writer.print("\n", .{});
}

/// Write a single value with padding to align columns.
fn writeValue(writer: anytype, v: row_mod.Value, width: usize) !void {
    const printed: usize = switch (v) {
        .null => blk: {
            try writer.print("NULL", .{});
            break :blk 4;
        },
        .int => |n| blk: {
            const s = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{n});
            defer std.heap.page_allocator.free(s);
            try writer.print("{s}", .{s});
            break :blk s.len;
        },
        .real => |f| blk: {
            const s = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{f});
            defer std.heap.page_allocator.free(s);
            try writer.print("{s}", .{s});
            break :blk s.len;
        },
        .text => |s| blk: {
            try writer.print("{s}", .{s});
            break :blk s.len;
        },
        .blob => |b| blk: {
            try writer.print("<blob {d}B>", .{b.len});
            break :blk std.fmt.count("<blob {d}B>", .{b.len});
        },
    };
    try padSpaces(writer, width - @min(width, printed));
}

fn padSpaces(writer: anytype, n: usize) !void {
    for (0..n) |_| try writer.print(" ", .{});
}

fn padDashes(writer: anytype, n: usize) !void {
    for (0..n) |_| try writer.print("-", .{});
}

// ========== shared utility functions ==========

/// Calculate the display length of a value.
fn valueLen(v: row_mod.Value) usize {
    return switch (v) {
        .null => 4,
        .int => |n| std.fmt.count("{d}", .{n}),
        .real => |f| std.fmt.count("{d}", .{f}),
        .text => |s| s.len,
        .blob => |b| std.fmt.count("<blob {d}B>", .{b.len}),
    };
}

/// Format a value into a buffer with padding (for stderr output).
fn formatValueBuf(buf: []u8, pos: usize, v: row_mod.Value, width: usize) usize {
    var new_pos = pos;
    var printed: usize = 0;

    switch (v) {
        .null => {
            const s = "NULL";
            @memcpy(buf[new_pos .. new_pos + s.len], s);
            new_pos += s.len;
            printed = s.len;
        },
        .int => |n| {
            const s = std.fmt.bufPrint(buf[new_pos..], "{d}", .{n}) catch return new_pos;
            new_pos += s.len;
            printed = s.len;
        },
        .real => |f| {
            const s = std.fmt.bufPrint(buf[new_pos..], "{d}", .{f}) catch return new_pos;
            new_pos += s.len;
            printed = s.len;
        },
        .text => |s| {
            @memcpy(buf[new_pos .. new_pos + s.len], s);
            new_pos += s.len;
            printed = s.len;
        },
        .blob => |b| {
            const s = std.fmt.bufPrint(buf[new_pos..], "<blob {d}B>", .{b.len}) catch return new_pos;
            new_pos += s.len;
            printed = s.len;
        },
    }

    new_pos = padSpacesBuf(buf, new_pos, width - @min(width, printed));
    return new_pos;
}

fn padSpacesBuf(buf: []u8, pos: usize, n: usize) usize {
    var new_pos = pos;
    for (0..n) |_| {
        buf[new_pos] = ' ';
        new_pos += 1;
    }
    return new_pos;
}

fn padDashesBuf(buf: []u8, pos: usize, n: usize) usize {
    var new_pos = pos;
    for (0..n) |_| {
        buf[new_pos] = '-';
        new_pos += 1;
    }
    return new_pos;
}
