const std = @import("std");
const Db = @import("../db.zig").Db;
const row_mod = @import("../row.zig");
const lp = @import("logical_plan.zig");
const pp = @import("physical_plan.zig");
const eval = @import("eval.zig");
const Parser = @import("parser.zig").Parser;
const lp_mod = @import("logical_plan.zig");
const pp_mod = @import("physical_plan.zig");
const cursor_mod = @import("cursor/root.zig");

// ── Result types ───────────────────────────────────────────────────────────────

// Row is defined alongside the cursor layer so that both share the same type.
pub const Row = cursor_mod.Row;

pub const ResultSet = struct {
    columns: [][]const u8, // column names, arena-owned
    rows: []Row,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ResultSet) void {
        self.arena.deinit();
    }
};

/// A SQL-level error with a human-readable message.  Returned as a result
/// variant rather than a Zig error so callers can inspect the message string.
pub const FormattedError = struct {
    /// Machine-readable error name, e.g. "TableNotFound"
    code: []const u8,
    /// Human-readable message, e.g. "Table 'users' does not exist"
    message: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *FormattedError) void {
        self.arena.deinit();
    }
};

pub const ExecResult = union(enum) {
    result_set: ResultSet,
    affected: u64,
    created: void,
    /// SQL-level error (bad syntax, unknown table, type mismatch, …).
    /// Unexpected system failures (OOM, I/O) still propagate as Zig errors.
    err: FormattedError,

    pub fn deinit(self: *ExecResult) void {
        switch (self.*) {
            .result_set => |*rs| rs.deinit(),
            .err => |*e| e.deinit(),
            else => {},
        }
    }
};

// ── Executor ───────────────────────────────────────────────────────────────────

pub const Executor = struct {
    db: *Db,
    alloc: std.mem.Allocator,

    pub fn init(db: *Db, allocator: std.mem.Allocator) Executor {
        return .{ .db = db, .alloc = allocator };
    }

    pub fn exec(self: *Executor, plan: pp.PhysicalPlan) !ExecResult {
        return switch (plan) {
            .seq_scan, .vtab_scan, .const_scan, .point_lookup, .filter, .project, .aggregate, .sort, .join => .{ .result_set = try self.execQuery(plan) },
            .insert => |n| .{ .affected = try self.execInsert(n) },
            .update => |n| .{ .affected = try self.execUpdate(n) },
            .delete => |n| .{ .affected = try self.execDelete(n) },
            .create_table => |n| blk: {
                try self.db.createTable(n.table, n.columns);
                break :blk .{ .created = {} };
            },
            .begin => blk: {
                try self.db.begin();
                break :blk .{ .affected = 0 };
            },
            .commit => blk: {
                try self.db.commit();
                break :blk .{ .affected = 0 };
            },
            .rollback => blk: {
                try self.db.rollback();
                break :blk .{ .affected = 0 };
            },
        };
    }

    // ── SELECT ─────────────────────────────────────────────────────────────────

    // Execute a SELECT and return all rows in memory.  We use an arena allocator
    // so that the caller can free the entire result set with one call to deinit().
    fn execQuery(self: *Executor, plan: pp.PhysicalPlan) !ResultSet {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        var result_rows: std.ArrayList(Row) = .empty;
        try collectRows(plan, self.db, &result_rows, a);

        const schema = plan.schema();
        const col_names = try a.alloc([]const u8, schema.columns.len);
        for (schema.columns, 0..) |col, i| {
            col_names[i] = try a.dupe(u8, col.name);
        }

        return ResultSet{
            .columns = col_names,
            .rows = try result_rows.toOwnedSlice(a),
            .arena = arena,
        };
    }

    // ── DML ────────────────────────────────────────────────────────────────────

    fn execInsert(self: *Executor, n: pp.PhysicalInsert) !u64 {
        for (n.values) |row| {
            const vals = try self.alloc.alloc(row_mod.Value, row.len);
            defer self.alloc.free(vals);
            for (row, 0..) |expr, i| {
                vals[i] = try evalToValue(expr, &.{}, self.alloc);
            }
            _ = try self.db.insert(n.table, vals);
        }
        return n.values.len;
    }

    fn execUpdate(self: *Executor, n: pp.PhysicalUpdate) !u64 {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var matches: std.ArrayList(Row) = .empty;
        try collectRows(n.input.*, self.db, &matches, a);

        var count: u64 = 0;
        const meta = self.db.cat.getTable(n.table) orelse return error.TableNotFound;
        for (matches.items) |r| {
            const real_vals = r.values[0..meta.columns.len];
            const new_vals = try self.alloc.dupe(row_mod.Value, real_vals);
            defer self.alloc.free(new_vals);
            for (n.assignments) |asgn| {
                new_vals[asgn.col_idx] = try evalToValue(asgn.value, real_vals, self.alloc);
            }
            if (try self.db.update(n.table, r.rowid, new_vals)) count += 1;
        }
        return count;
    }

    fn execDelete(self: *Executor, n: pp.PhysicalDelete) !u64 {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var matches: std.ArrayList(Row) = .empty;
        try collectRows(n.input.*, self.db, &matches, a);

        var count: u64 = 0;
        for (matches.items) |r| {
            if (try self.db.delete(n.table, r.rowid)) count += 1;
        }
        return count;
    }
};

// ── Helpers ────────────────────────────────────────────────────────────────────

fn collectRows(
    plan: pp.PhysicalPlan,
    db: *Db,
    out: *std.ArrayList(Row),
    a: std.mem.Allocator,
) anyerror!void {
    var cur = try cursor_mod.Cursor.open(plan, db, a);
    defer cur.deinit(a);
    while (try cur.next(a)) |batch| {
        try out.appendSlice(a, batch);
    }
}

fn evalToValue(
    expr: lp.Expr,
    row_values: []const row_mod.Value,
    alloc: std.mem.Allocator,
) !row_mod.Value {
    const ev = try eval.evalExpr(expr, row_values, alloc);
    return switch (ev) {
        .null_ => .null,
        .int => |n| .{ .int = n },
        .real => |f| .{ .real = f },
        .text => |s| .{ .text = s },
        .bool_ => |b| .{ .int = if (b) 1 else 0 },
    };
}

// ── Public convenience function ────────────────────────────────────────────────

// Full query pipeline: parse → logical plan → physical plan → execute.
// Each stage owns its memory via arena allocators that are freed before
// returning, so the only memory retained is the result set itself.
//
// SQL-level errors (bad syntax, unknown table, type mismatch, …) are returned
// as ExecResult.err so callers receive a human-readable message string.
// Genuine system failures (OOM, I/O errors) still propagate as Zig errors.
pub fn execute(allocator: std.mem.Allocator, db: *Db, sql: []const u8) !ExecResult {
    var parser = Parser.init(sql, allocator);
    defer parser.deinit();

    const stmt = parser.parse() catch |e| {
        return toSqlError(allocator, e, parser.error_message);
    };

    var logical_planner = lp_mod.LogicalPlanner.init(&db.cat, allocator);
    defer logical_planner.deinit();
    const logical = logical_planner.plan(stmt) catch |e| {
        return toSqlError(allocator, e, logical_planner.error_message);
    };

    var phys_planner = pp_mod.PhysicalPlanner.init(allocator);
    defer phys_planner.deinit();
    const physical = try phys_planner.plan(logical);

    var ex = Executor.init(db, allocator);
    return ex.exec(physical) catch |e| {
        if (isSqlUserError(e)) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const msg = try std.fmt.allocPrint(arena.allocator(), "{s}", .{@errorName(e)});
            return ExecResult{ .err = .{ .code = @errorName(e), .message = msg, .arena = arena } };
        }
        return e;
    };
}

/// Convert a caught error into ExecResult.err (SQL-level user error) or
/// re-propagate it as a Zig error (unexpected system failure).
fn toSqlError(allocator: std.mem.Allocator, e: anyerror, message: []const u8) !ExecResult {
    if (!isSqlUserError(e)) return e;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const msg = if (message.len > 0)
        try arena.allocator().dupe(u8, message)
    else
        try std.fmt.allocPrint(arena.allocator(), "{s}", .{@errorName(e)});

    return ExecResult{ .err = .{ .code = @errorName(e), .message = msg, .arena = arena } };
}

/// Returns true for errors that are the user's fault (bad SQL, wrong schema).
/// Returns false for system failures that should surface as Zig errors.
fn isSqlUserError(e: anyerror) bool {
    return switch (e) {
        // Lex / parse errors
        error.UnexpectedChar,
        error.UnterminatedString,
        error.InvalidNumber,
        error.UnexpectedToken,
        error.UnexpectedEof,
        error.InvalidType,
        // Logical plan errors
        error.TableNotFound,
        error.ColumnNotFound,
        error.WildcardInExpression,
        error.TypeMismatch,
        error.ColumnCountMismatch,
        error.ArgCountMismatch,
        error.NoDefaultValue,
        error.UnknownFunction,
        error.WrongArgCount,
        // Execution errors
        error.DivisionByZero,
        // Schema / catalog errors
        error.TableAlreadyExists,
        // Transaction errors
        error.TransactionAlreadyActive,
        error.NoActiveTransaction,
        // Virtual table argument errors
        error.ArgumentMismatch,
        error.InvalidArgumentType,
        => true,
        else => false,
    };
}
