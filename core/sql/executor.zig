const std = @import("std");
const Db = @import("../db.zig").Db;
const row_mod = @import("../row.zig");
const lp = @import("logical_plan.zig");
const pp = @import("physical_plan.zig");
const eval = @import("eval.zig");
const Parser = @import("parser.zig").Parser;
const lp_mod = @import("logical_plan.zig");
const pp_mod = @import("physical_plan.zig");

// ── Result types ───────────────────────────────────────────────────────────────

pub const Row = struct {
    rowid: u64,
    values: []row_mod.Value, // arena-owned
};

pub const ResultSet = struct {
    columns: [][]const u8, // column names, arena-owned
    rows: []Row,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ResultSet) void {
        self.arena.deinit();
    }
};

pub const ExecResult = union(enum) {
    result_set: ResultSet,
    affected: u64,
    created: void,

    pub fn deinit(self: *ExecResult) void {
        switch (self.*) {
            .result_set => |*rs| rs.deinit(),
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
            .seq_scan, .vtab_scan, .point_lookup, .filter, .project => .{ .result_set = try self.execQuery(plan) },
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
    // This is acceptable for a simple embedded database; a production system would
    // use cursor-style iteration for large result sets.
    fn execQuery(self: *Executor, plan: pp.PhysicalPlan) !ResultSet {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        var result_rows: std.ArrayList(Row) = .empty;
        try self.collectRows(plan, &result_rows, a);

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

    fn collectRows(
        self: *Executor,
        plan: pp.PhysicalPlan,
        out: *std.ArrayList(Row),
        a: std.mem.Allocator,
    ) anyerror!void {
        switch (plan) {
            .seq_scan => |n| try self.scanTable(n.table, out, a, null),
            .vtab_scan => |n| try self.scanVTab(n, out, a),
            .point_lookup => |n| try self.lookupRow(n, out, a),
            .filter => |n| try self.collectFiltered(n, out, a),
            .project => |n| try self.collectProjected(n, out, a),
            else => unreachable,
        }
    }

    fn scanTable(
        self: *Executor,
        table: []const u8,
        out: *std.ArrayList(Row),
        a: std.mem.Allocator,
        predicate: ?lp.Expr,
    ) !void {
        const Ctx = struct {
            out: *std.ArrayList(Row),
            a: std.mem.Allocator,
            pred: ?lp.Expr,
            err: ?anyerror = null,
        };
        var ctx = Ctx{ .out = out, .a = a, .pred = predicate };

        try self.db.scan(table, struct {
            fn cb(rowid: u64, values: []const row_mod.Value, c: anytype) bool {
                if (c.pred) |pred| {
                    const ev = eval.evalExpr(pred, values, c.a) catch |err| {
                        c.err = err;
                        return false;
                    };
                    if (!eval.isTruthy(ev)) return true;
                }
                const duped = c.a.alloc(row_mod.Value, values.len) catch |err| {
                    c.err = err;
                    return false;
                };
                @memcpy(duped, values);
                for (duped) |*v| dupeValue(v, c.a) catch |err| {
                    c.err = err;
                    return false;
                };
                c.out.append(c.a, .{ .rowid = rowid, .values = duped }) catch |err| {
                    c.err = err;
                    return false;
                };
                return true;
            }
        }.cb, &ctx);

        if (ctx.err) |err| return err;
    }

    fn scanVTab(
        self: *Executor,
        n: pp.PhysicalVTabScan,
        out: *std.ArrayList(Row),
        a: std.mem.Allocator,
    ) !void {
        var raw_rows: std.ArrayList([]row_mod.Value) = .empty;
        try n.vtab.scan(&self.db.cat, n.args, &raw_rows, a);
        for (raw_rows.items, 0..) |vals, i| {
            try out.append(a, .{ .rowid = @intCast(i + 1), .values = vals });
        }
    }

    fn lookupRow(
        self: *Executor,
        n: pp.PhysicalPointLookup,
        out: *std.ArrayList(Row),
        a: std.mem.Allocator,
    ) !void {
        const vals = try self.db.getByRowid(n.table, n.rowid, a) orelse return;
        try out.append(a, .{ .rowid = n.rowid, .values = vals });
    }

    fn collectFiltered(
        self: *Executor,
        n: *pp.PhysicalFilter,
        out: *std.ArrayList(Row),
        a: std.mem.Allocator,
    ) !void {
        var input_rows: std.ArrayList(Row) = .empty;
        try self.collectRows(n.input, &input_rows, a);
        for (input_rows.items) |r| {
            const ev = try eval.evalExpr(n.predicate, r.values, a);
            if (eval.isTruthy(ev)) try out.append(a, r);
        }
    }

    fn collectProjected(
        self: *Executor,
        n: *pp.PhysicalProject,
        out: *std.ArrayList(Row),
        a: std.mem.Allocator,
    ) !void {
        var input_rows: std.ArrayList(Row) = .empty;
        try self.collectRows(n.input, &input_rows, a);
        for (input_rows.items) |r| {
            const projected = try a.alloc(row_mod.Value, n.col_indices.len);
            for (n.col_indices, 0..) |idx, j| projected[j] = r.values[idx];
            try out.append(a, .{ .rowid = r.rowid, .values = projected });
        }
    }

    // ── DML ────────────────────────────────────────────────────────────────────

    fn execInsert(self: *Executor, n: pp.PhysicalInsert) !u64 {
        const vals = try self.alloc.alloc(row_mod.Value, n.values.len);
        defer self.alloc.free(vals);
        for (n.values, 0..) |expr, i| {
            vals[i] = try evalToValue(expr, &.{}, self.alloc);
        }
        _ = try self.db.insert(n.table, vals);
        return 1;
    }

    fn execUpdate(self: *Executor, n: pp.PhysicalUpdate) !u64 {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var matches: std.ArrayList(Row) = .empty;
        try self.collectRows(n.input.*, &matches, a);

        var count: u64 = 0;
        for (matches.items) |r| {
            const new_vals = try self.alloc.dupe(row_mod.Value, r.values);
            defer self.alloc.free(new_vals);
            for (n.assignments) |asgn| {
                new_vals[asgn.col_idx] = try evalToValue(asgn.value, r.values, self.alloc);
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
        try self.collectRows(n.input.*, &matches, a);

        var count: u64 = 0;
        for (matches.items) |r| {
            if (try self.db.delete(n.table, r.rowid)) count += 1;
        }
        return count;
    }
};

// ── Helpers ────────────────────────────────────────────────────────────────────

fn dupeValue(v: *row_mod.Value, a: std.mem.Allocator) !void {
    switch (v.*) {
        .text => |s| v.* = .{ .text = try a.dupe(u8, s) },
        .blob => |b| v.* = .{ .blob = try a.dupe(u8, b) },
        else => {},
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
pub fn execute(db: *Db, sql: []const u8, allocator: std.mem.Allocator) !ExecResult {
    var parse_result = try Parser.parse(sql, allocator);
    defer parse_result.deinit();

    var logical_planner = lp_mod.LogicalPlanner.init(&db.cat, allocator);
    defer logical_planner.deinit();
    const logical = try logical_planner.plan(parse_result.stmt);

    var phys_planner = pp_mod.PhysicalPlanner.init(allocator);
    defer phys_planner.deinit();
    const physical = try phys_planner.plan(logical);

    var ex = Executor.init(db, allocator);
    return ex.exec(physical);
}
