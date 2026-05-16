const std = @import("std");
const t = @import("../../types.zig");
const ast = @import("../ast.zig");
const catalog = @import("../../catalog.zig");
const vtab_mod = @import("../../vtable/root.zig");
const sf = @import("../scalar_func.zig");
const agg_mod = @import("../cursor/agg_func.zig");

// ── Schema ─────────────────────────────────────────────────────────────────────

pub const SchemaCol = struct {
    name: []const u8, // arena-owned
    table: []const u8, // arena-owned; source table name (used for qualified col resolution)
    col_type: t.ColType,
    nullable: bool,
    index: usize, // position in the source row
};

pub const Schema = struct {
    table: []const u8, // arena-owned; empty for anonymous nodes
    columns: []SchemaCol,
};

// ── Resolved expression ────────────────────────────────────────────────────────
//
// Resolved expression: all column references have been replaced by their
// positional indices in the source schema.  This decouples the execution
// layer from column names, allowing the planner to reorder or project
// columns without tracking name mappings at runtime.
pub const Expr = union(enum) {
    int_lit: i64,
    float_lit: f64,
    str_lit: []const u8, // arena-owned
    bool_lit: bool,
    null_lit: void,
    col_idx: usize, // source column index into the row's values slice
    binary: *Binary,
    unary: *Unary,
    func_call: *FuncCall,
    cast: *Cast,
    in_list: *InList,
    case_: *Case,
    is_null: *IsNull,

    pub const Binary = struct { op: ast.BinaryOp, left: Expr, right: Expr };
    pub const Unary = struct { op: ast.UnaryOp, operand: Expr };
    // func points directly into scalar_func.REGISTRY, resolved at plan time —
    // the same pattern as VTabScan storing *const VTab.
    pub const FuncCall = struct { func: *const sf.ScalarFunc, args: []Expr };
    pub const Cast = struct { target_type: t.ColType, operand: Expr };
    pub const InList = struct { operand: Expr, list: []Expr, negated: bool };
    pub const Case = struct {
        pub const WhenClause = struct { cond: Expr, then: Expr };
        when_clauses: []WhenClause,
        else_: ?Expr,
    };
    pub const IsNull = struct { operand: Expr, negated: bool };
};

// ── Aggregate spec ────────────────────────────────────────────────────────────
//
// Pairs a resolved aggregate function with its per-row input expression.
// input_expr == null means COUNT(*) — count every row regardless of value.
// distinct == true means only unique non-null values are fed to step().
pub const AggCallSpec = struct {
    func: *const agg_mod.AggFunc,
    input_expr: ?Expr, // null = COUNT(*); otherwise evaluated per row
    distinct: bool = false,
};

// ── Plan nodes ─────────────────────────────────────────────────────────────────

pub const SeqScan = struct {
    table: []const u8, // arena-owned
    schema: Schema,
};

pub const VTabScan = struct {
    name: []const u8, // arena-owned
    args: []const vtab_mod.Value, // resolved args, arena-owned
    schema: Schema,
    vtab: *const vtab_mod.VTab,
};

pub const Filter = struct {
    input: *LogicalPlan,
    predicate: Expr,
    schema: Schema, // same as input's schema
};

pub const Project = struct {
    input: *LogicalPlan,
    // One resolved expression per output column; simple column references are
    // represented as col_idx, while computed columns (e.g. abs(n)) use the
    // full expression.
    exprs: []Expr,
    schema: Schema,
};

pub const LogicalInsert = struct {
    table: []const u8,
    // Multiple rows; each inner slice has one resolved Expr per column.
    values: [][]Expr,
    schema: Schema, // target table schema (for the executor to build the row)
};

pub const LogicalUpdate = struct {
    table: []const u8,
    input: *LogicalPlan, // scan + optional filter to find matching rows
    assignments: []Assignment,
    schema: Schema,

    pub const Assignment = struct {
        col_idx: usize,
        value: Expr,
    };
};

pub const LogicalDelete = struct {
    table: []const u8,
    input: *LogicalPlan, // scan + optional filter to find matching rows
    schema: Schema,
};

pub const LogicalCreateTable = struct {
    table: []const u8,
    columns: []catalog.ColumnMeta, // arena-owned
};

// Aggregate node: consumes all input rows, groups by group_by column indices,
// and computes one aggregate result per group.  Output schema is:
//   [group_key_cols..., agg_result_cols...]
// with sequential indices 0, 1, 2, ... matching the values slice produced by
// AggregateCursor.  A Project node above this maps SELECT column order.
pub const Aggregate = struct {
    input: *LogicalPlan,
    group_by: []const usize, // column indices into input schema
    agg_specs: []const AggCallSpec,
    schema: Schema, // [group_key cols, agg result cols]
};

// One key in an ORDER BY clause, resolved against the Project's output schema.
// col_idx values in expr refer to 0-based positions in the projected values
// slice (not scan-level indices), so the SortCursor can index into them directly.
pub const SortKey = struct {
    expr: Expr,
    descending: bool,
};

// Blocking sort node: consumes all input rows then emits them sorted.
// Sits above Project so ORDER BY positions refer to SELECT output columns.
pub const Sort = struct {
    input: *LogicalPlan,
    keys: []SortKey,
    schema: Schema, // same shape as input; Sort doesn't add or remove columns
};

// Blocking deduplication node: consumes all input rows and emits only unique
// rows (equality across all projected columns).  Sits above Project so column
// indices refer to SELECT output positions, and below Sort so duplicates are
// removed before ordering.
pub const Distinct = struct {
    input: *LogicalPlan,
    schema: Schema, // same shape as input
};

// Nested-loop join.  The schema merges both tables' columns with right-side
// indices offset by the number of left-side columns.  condition is null for
// CROSS JOIN (every left/right pair is emitted).
pub const Join = struct {
    left: *LogicalPlan,
    right: *LogicalPlan,
    condition: ?Expr, // null for CROSS JOIN; ON predicate for INNER JOIN
    schema: Schema, // combined schema (left cols then right cols)
};

pub const LogicalPlan = union(enum) {
    seq_scan: SeqScan,
    const_scan: void,
    vtab_scan: VTabScan,
    filter: *Filter,
    project: *Project,
    aggregate: *Aggregate,
    sort: *Sort,
    distinct: *Distinct,
    join: *Join,
    insert: LogicalInsert,
    update: LogicalUpdate,
    delete: LogicalDelete,
    create_table: LogicalCreateTable,
    begin: void,
    commit: void,
    rollback: void,

    pub fn schema(self: LogicalPlan) Schema {
        return switch (self) {
            .seq_scan => |n| n.schema,
            .vtab_scan => |n| n.schema,
            .filter => |n| n.schema,
            .project => |n| n.schema,
            .aggregate => |n| n.schema,
            .sort => |n| n.schema,
            .distinct => |n| n.schema,
            .join => |n| n.schema,
            .insert => |n| n.schema,
            .update => |n| n.schema,
            .delete => |n| n.schema,
            .const_scan, .create_table, .begin, .commit, .rollback => Schema{ .table = "", .columns = &.{} },
        };
    }
};

// ── Planner ────────────────────────────────────────────────────────────────────

pub const PlanError = error{
    TableNotFound,
    ColumnNotFound,
    // table.* used where a scalar expression is required (e.g. WHERE clause)
    WildcardInExpression,
    TypeMismatch,
    ColumnCountMismatch,
    ArgCountMismatch,
    OutOfMemory,
    NoDefaultValue,
    UnknownFunction,
    WrongArgCount,
};

pub const LogicalPlanner = struct {
    cat: *catalog.Catalog,
    arena: std.heap.ArenaAllocator,
    error_message: []const u8 = "",

    pub fn init(cat: *catalog.Catalog, allocator: std.mem.Allocator) LogicalPlanner {
        return .{ .cat = cat, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *LogicalPlanner) void {
        self.arena.deinit();
    }

    fn alloc(self: *LogicalPlanner) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn setError(self: *LogicalPlanner, comptime fmt_str: []const u8, args: anytype) void {
        self.error_message = std.fmt.allocPrint(self.arena.allocator(), fmt_str, args) catch "";
    }

    pub fn plan(self: *LogicalPlanner, stmt: ast.Stmt) PlanError!LogicalPlan {
        return switch (stmt) {
            .select => |s| try self.planSelect(s),
            .insert => |s| try self.planInsert(s),
            .update => |s| try self.planUpdate(s),
            .delete => |s| try self.planDelete(s),
            .create_table => |s| try self.planCreateTable(s),
            .begin => .{ .begin = {} },
            .commit => .{ .commit = {} },
            .rollback => .{ .rollback = {} },
        };
    }

    // ── SELECT ─────────────────────────────────────────────────────────────────

    fn planSelect(self: *LogicalPlanner, stmt: ast.SelectStmt) PlanError!LogicalPlan {
        const first = try self.buildScan(stmt.table_ref);
        var scan_schema = first.schema;
        var current = first.plan;

        // Build Join nodes for each JOIN clause.  Each join merges the accumulated
        // schema on the left with the new table schema on the right, offsetting
        // right-side column indices so they don't collide with left-side indices
        // in the combined values array produced by JoinCursor.
        for (stmt.joins) |join_clause| {
            const right = try self.buildScan(join_clause.table_ref);

            const left_count = scan_schema.columns.len;
            const merged_schema = try self.mergeSchemas(scan_schema, right.schema, left_count);
            const condition = if (join_clause.condition) |cond|
                try self.resolveExpr(cond, merged_schema)
            else
                null;
            const join_node = try self.alloc().create(Join);
            join_node.* = .{
                .left = try self.box(current),
                .right = try self.box(right.plan),
                .condition = condition,
                .schema = merged_schema,
            };
            current = .{ .join = join_node };
            scan_schema = merged_schema;
        }

        // Wrap in Filter if WHERE is present.
        if (stmt.where) |where_expr| {
            const pred = try self.resolveExpr(where_expr, scan_schema);
            const filter = try self.alloc().create(Filter);
            filter.* = .{
                .input = try self.box(current),
                .predicate = pred,
                .schema = scan_schema,
            };
            current = .{ .filter = filter };
        }

        // If the query has GROUP BY or aggregate function calls in the SELECT list,
        // route to the aggregate planning path which inserts an Aggregate node.
        if (needsAggregate(stmt)) {
            var result = try self.planSelectAgg(stmt, current, scan_schema);
            if (stmt.order_by.len > 0) {
                const proj_schema = result.schema();
                const keys = try self.resolveOrderByKeys(stmt.order_by, proj_schema.columns, proj_schema.table);
                const sort_node = try self.alloc().create(Sort);
                sort_node.* = .{ .input = try self.box(result), .keys = keys, .schema = proj_schema };
                result = .{ .sort = sort_node };
            }
            return result;
        }

        // Always wrap in Project so hidden metadata cols (__rowid etc.) are
        // excluded from SELECT * and column order is always explicit.
        {
            var exprs: std.ArrayList(Expr) = .empty;
            var proj_cols: std.ArrayList(SchemaCol) = .empty;

            for (stmt.columns) |sel_col| {
                switch (sel_col.col) {
                    .star => {
                        for (scan_schema.columns) |sc| {
                            // Skip hidden metadata cols; users must request them explicitly.
                            if (std.mem.startsWith(u8, sc.name, "__")) continue;
                            try exprs.append(self.alloc(), .{ .col_idx = sc.index });
                            try proj_cols.append(self.alloc(), .{
                                .name = try self.alloc().dupe(u8, sc.name),
                                .table = try self.alloc().dupe(u8, sc.table),
                                .col_type = sc.col_type,
                                .nullable = sc.nullable,
                                .index = sc.index,
                            });
                        }
                    },
                    .name => |n| {
                        const src_idx = try self.resolveColName(n, scan_schema);
                        try exprs.append(self.alloc(), .{ .col_idx = src_idx });
                        for (scan_schema.columns) |sc| {
                            if (sc.index == src_idx) {
                                const out_name = sel_col.alias orelse sc.name;
                                try proj_cols.append(self.alloc(), .{
                                    .name = try self.alloc().dupe(u8, out_name),
                                    .table = try self.alloc().dupe(u8, sc.table),
                                    .col_type = sc.col_type,
                                    .nullable = sc.nullable,
                                    .index = src_idx,
                                });
                                break;
                            }
                        }
                    },
                    .qual_name => |q| {
                        if (q.col == null) {
                            // Handle SELECT table_name.*
                            var matched = false;
                            for (scan_schema.columns) |sc| {
                                if (std.ascii.eqlIgnoreCase(sc.table, q.table)) {
                                    matched = true;
                                    if (std.mem.startsWith(u8, sc.name, "__")) continue;
                                    try exprs.append(self.alloc(), .{ .col_idx = sc.index });
                                    try proj_cols.append(self.alloc(), .{
                                        .name = try self.alloc().dupe(u8, sc.name),
                                        .table = try self.alloc().dupe(u8, sc.table),
                                        .col_type = sc.col_type,
                                        .nullable = sc.nullable,
                                        .index = sc.index,
                                    });
                                }
                            }
                            if (!matched) {
                                self.setError("Table '{s}' does not exist", .{q.table});
                                return PlanError.TableNotFound;
                            }
                        } else {
                            // Handle SELECT table_name.column_name
                            const src_idx = try self.resolveQualColName(q.table, q.col.?, scan_schema);
                            try exprs.append(self.alloc(), .{ .col_idx = src_idx });
                            for (scan_schema.columns) |sc| {
                                if (sc.index == src_idx) {
                                    const out_name = sel_col.alias orelse sc.name;
                                    try proj_cols.append(self.alloc(), .{
                                        .name = try self.alloc().dupe(u8, out_name),
                                        .table = try self.alloc().dupe(u8, sc.table),
                                        .col_type = sc.col_type,
                                        .nullable = sc.nullable,
                                        .index = src_idx,
                                    });
                                    break;
                                }
                            }
                        }
                    },
                    .expr => |e| {
                        const resolved = try self.resolveExpr(e, scan_schema);
                        try exprs.append(self.alloc(), resolved);
                        // Use alias, function name, or a generic label as the output column name.
                        const col_name = if (sel_col.alias) |a| a else switch (e) {
                            .func_call => |f| f.name,
                            else => "?",
                        };
                        try proj_cols.append(self.alloc(), .{
                            .name = try self.alloc().dupe(u8, col_name),
                            .table = "",
                            .col_type = .int,
                            .nullable = true,
                            .index = std.math.maxInt(usize),
                        });
                    },
                }
            }

            const proj_schema = Schema{
                .table = scan_schema.table,
                .columns = try proj_cols.toOwnedSlice(self.alloc()),
            };
            const project = try self.alloc().create(Project);
            project.* = .{
                .input = try self.box(current),
                .exprs = try exprs.toOwnedSlice(self.alloc()),
                .schema = proj_schema,
            };
            current = .{ .project = project };
        }

        if (stmt.distinct) {
            const d = try self.alloc().create(Distinct);
            d.* = .{ .input = try self.box(current), .schema = current.schema() };
            current = .{ .distinct = d };
        }

        if (stmt.order_by.len > 0) {
            const proj_schema = current.schema();
            const keys = try self.resolveOrderByKeys(stmt.order_by, proj_schema.columns, proj_schema.table);
            const sort_node = try self.alloc().create(Sort);
            sort_node.* = .{ .input = try self.box(current), .keys = keys, .schema = proj_schema };
            current = .{ .sort = sort_node };
        }

        return current;
    }

    /// Builds a logical plan for an INSERT statement.
    /// Handles both named and positional inserts, resolves expressions,
    /// and ensures all required columns are provided for every row.
    fn planInsert(self: *LogicalPlanner, stmt: ast.InsertStmt) PlanError!LogicalPlan {
        const meta = self.cat.getTable(stmt.table) orelse {
            self.setError("Table '{s}' does not exist", .{stmt.table});
            return PlanError.TableNotFound;
        };

        const schema = try self.buildSchema(meta, null);
        const col_count = meta.columns.len;

        const all_rows = try self.alloc().alloc([]Expr, stmt.values.len);

        for (stmt.values, 0..) |raw_row, row_idx| {
            const row_values = try self.alloc().alloc(Expr, col_count);
            const is_set = try self.alloc().alloc(bool, col_count);
            defer self.alloc().free(is_set);

            // Initialize each column to its default / NULL.
            for (meta.columns) |col| {
                const idx = col.attnum;
                if (col.default_expr) |default_expr| {
                    row_values[idx] = try self.resolveExpr(default_expr, schema);
                    is_set[idx] = true;
                } else if (col.nullable) {
                    row_values[idx] = .null_lit;
                    is_set[idx] = true;
                } else {
                    is_set[idx] = false;
                }
            }

            if (stmt.columns.len > 0) {
                // Named column insert (user specifies target columns)
                // INSERT INTO table_name(col1, col2, ...) VALUES (...)
                if (stmt.columns.len != raw_row.len) {
                    self.setError("Column count ({d}) does not match value count ({d})", .{ stmt.columns.len, raw_row.len });
                    return PlanError.ColumnCountMismatch;
                }

                for (stmt.columns, 0..) |name, i| {
                    const col = meta.findColumn(name) orelse {
                        self.setError("Column '{s}' does not exist in table '{s}'", .{ name, stmt.table });
                        return PlanError.ColumnNotFound;
                    };
                    const idx = col.attnum;
                    const current_value = raw_row[i];
                    if (current_value != .default_value) {
                        row_values[idx] = try self.resolveExpr(current_value, schema);
                        is_set[idx] = true;
                    }
                }
            } else {
                // Positional insert (values mapped by column order)
                // INSERT INTO table_name VALUES (...)
                if (raw_row.len > col_count)
                    return PlanError.ColumnCountMismatch;

                for (raw_row, 0..) |expr, i| {
                    if (expr != .default_value) {
                        row_values[i] = try self.resolveExpr(expr, schema);
                        is_set[i] = true;
                    }
                }
            }

            // Ensure all required columns are filled.
            for (is_set, 0..) |set, i| {
                if (!set) {
                    self.setError("Column '{s}' has no default value and was not provided", .{meta.columns[i].name});
                    return PlanError.NoDefaultValue;
                }
            }

            all_rows[row_idx] = row_values;
        }

        return .{
            .insert = .{
                .table = schema.table,
                .values = all_rows,
                .schema = schema,
            },
        };
    }

    // ── UPDATE ─────────────────────────────────────────────────────────────────

    fn planUpdate(self: *LogicalPlanner, stmt: ast.UpdateStmt) PlanError!LogicalPlan {
        const meta = self.cat.getTable(stmt.table) orelse {
            self.setError("Table '{s}' does not exist", .{stmt.table});
            return PlanError.TableNotFound;
        };
        const schema = try self.buildSchema(meta, null);

        var input: LogicalPlan = .{ .seq_scan = .{ .table = schema.table, .schema = schema } };

        if (stmt.where) |where_expr| {
            const pred = try self.resolveExpr(where_expr, schema);
            const filter = try self.alloc().create(Filter);
            filter.* = .{
                .input = try self.box(input),
                .predicate = pred,
                .schema = schema,
            };
            input = .{ .filter = filter };
        }

        const assignments = try self.alloc().alloc(LogicalUpdate.Assignment, stmt.assignments.len);
        for (stmt.assignments, 0..) |asgn, i| {
            assignments[i] = .{
                .col_idx = try self.resolveColName(asgn.column, schema),
                .value = try self.resolveExpr(asgn.value, schema),
            };
        }

        return .{ .update = .{
            .table = schema.table,
            .input = try self.box(input),
            .assignments = assignments,
            .schema = schema,
        } };
    }

    // ── DELETE ─────────────────────────────────────────────────────────────────

    fn planDelete(self: *LogicalPlanner, stmt: ast.DeleteStmt) PlanError!LogicalPlan {
        const meta = self.cat.getTable(stmt.table) orelse {
            self.setError("Table '{s}' does not exist", .{stmt.table});
            return PlanError.TableNotFound;
        };
        const schema = try self.buildSchema(meta, null);

        var input: LogicalPlan = .{ .seq_scan = .{ .table = schema.table, .schema = schema } };

        if (stmt.where) |where_expr| {
            const pred = try self.resolveExpr(where_expr, schema);
            const filter = try self.alloc().create(Filter);
            filter.* = .{
                .input = try self.box(input),
                .predicate = pred,
                .schema = schema,
            };
            input = .{ .filter = filter };
        }

        return .{ .delete = .{
            .table = schema.table,
            .input = try self.box(input),
            .schema = schema,
        } };
    }

    // ── CREATE TABLE ───────────────────────────────────────────────────────────

    fn planCreateTable(self: *LogicalPlanner, stmt: ast.CreateTableStmt) PlanError!LogicalPlan {
        const table = try self.alloc().dupe(u8, stmt.table);
        const cols = try self.alloc().alloc(catalog.ColumnMeta, stmt.columns.len);
        for (stmt.columns, 0..) |col_def, i| {
            // Clone the AST expression to the planner's allocator.
            // The expression will be resolved at runtime when needed.
            const default_expr: ?ast.Expr = if (col_def.default_expr) |ast_expr|
                try ast_expr.clone(self.alloc())
            else
                null;

            cols[i] = .{
                .name = try self.alloc().dupe(u8, col_def.name),
                .col_type = col_def.col_type,
                .nullable = col_def.nullable,
                .default_expr = default_expr,
                .default_src = if (col_def.default_src) |src| try self.alloc().dupe(u8, src) else null,
            };
        }
        return .{ .create_table = .{ .table = table, .columns = cols } };
    }

    // ── Aggregate planning ─────────────────────────────────────────────────────

    // Returns true if the SELECT statement requires an Aggregate node: either
    // GROUP BY is present, or at least one SELECT column expression contains an
    // aggregate function call.
    fn needsAggregate(stmt: ast.SelectStmt) bool {
        if (stmt.group_by.len > 0) return true;
        for (stmt.columns) |col| {
            switch (col.col) {
                .expr => |e| if (containsAggCall(e)) return true,
                else => {},
            }
        }
        return false;
    }

    // Returns true if expr contains an aggregate function call anywhere in its
    // subtree (e.g. COUNT, SUM, AVG).  Used by needsAggregate to decide whether
    // to insert an Aggregate plan node — the planner must recurse into every
    // expression variant that has child expressions so no nested aggregate is missed.
    fn containsAggCall(expr: ast.Expr) bool {
        return switch (expr) {
            // A function call is an aggregate if it's in the agg registry.
            // For scalar functions, recurse into the arguments in case an
            // aggregate is nested inside, e.g. abs(COUNT(*)).
            .func_call => |f| agg_mod.find(f.name) != null or blk: {
                for (f.args) |arg| if (containsAggCall(arg)) break :blk true;
                break :blk false;
            },
            .binary => |b| containsAggCall(b.left) or containsAggCall(b.right),
            .unary => |u| containsAggCall(u.operand),
            .in_list => |il| blk: {
                if (containsAggCall(il.operand)) break :blk true;
                for (il.list) |item| if (containsAggCall(item)) break :blk true;
                break :blk false;
            },
            .between => |b| containsAggCall(b.operand) or containsAggCall(b.low) or containsAggCall(b.high),
            .case_ => |c| blk: {
                for (c.when_clauses) |w| {
                    if (containsAggCall(w.cond) or containsAggCall(w.then)) break :blk true;
                }
                if (c.else_) |e| if (containsAggCall(e)) break :blk true;
                break :blk false;
            },
            .is_null => |n| containsAggCall(n.operand),
            .cast => |c| containsAggCall(c.operand),
            // Literals, column references, and other leaves can never be aggregates.
            else => false,
        };
    }

    // Plan a SELECT that requires aggregation.
    //
    // Output plan shape:
    //   Project → Aggregate → (scan / filter / join chain)
    //
    // The Aggregate node emits rows in the form:
    //   [group_key_0, ..., group_key_G-1, agg_result_0, ..., agg_result_N-1]
    //
    // The Project re-orders / renames the columns to match the SELECT list.
    fn planSelectAgg(
        self: *LogicalPlanner,
        stmt: ast.SelectStmt,
        input: LogicalPlan,
        scan_schema: Schema,
    ) PlanError!LogicalPlan {
        // Step 1: resolve GROUP BY expressions to source column indices.
        const group_by = try self.alloc().alloc(usize, stmt.group_by.len);
        for (stmt.group_by, 0..) |gb_expr, i| {
            group_by[i] = switch (gb_expr) {
                .col_ref => |n| try self.resolveColName(n, scan_schema),
                .qual_col_ref => |q| if (q.col) |c| try self.resolveQualColName(q.table, c, scan_schema) else return PlanError.WildcardInExpression,
                else => return PlanError.TypeMismatch,
            };
        }

        // Step 2: collect aggregate function calls from SELECT column expressions.
        var agg_specs: std.ArrayListUnmanaged(AggCallSpec) = .empty;
        for (stmt.columns) |sel_col| {
            switch (sel_col.col) {
                .expr => |e| try self.collectAggSpecs(e, scan_schema, &agg_specs),
                else => {},
            }
        }
        const agg_specs_slice = try agg_specs.toOwnedSlice(self.alloc());

        // Step 3: build the aggregate output schema:
        //   [group_key_cols (index=0..G-1), agg_result_cols (index=G..G+N-1)]
        const total = group_by.len + agg_specs_slice.len;
        const agg_out_cols = try self.alloc().alloc(SchemaCol, total);

        for (group_by, 0..) |col_idx, i| {
            for (scan_schema.columns) |sc| {
                if (sc.index == col_idx) {
                    agg_out_cols[i] = .{
                        .name = sc.name,
                        .table = sc.table,
                        .col_type = sc.col_type,
                        .nullable = sc.nullable,
                        .index = i,
                    };
                    break;
                }
            }
        }
        for (agg_specs_slice, 0..) |spec, j| {
            agg_out_cols[group_by.len + j] = .{
                .name = try self.alloc().dupe(u8, spec.func.name),
                .table = "",
                .col_type = .int,
                .nullable = true,
                .index = group_by.len + j,
            };
        }
        const agg_out_schema = Schema{ .table = scan_schema.table, .columns = agg_out_cols };

        // Step 4: build the Aggregate logical plan node.
        const agg_node = try self.alloc().create(Aggregate);
        agg_node.* = .{
            .input = try self.box(input),
            .group_by = group_by,
            .agg_specs = agg_specs_slice,
            .schema = agg_out_schema,
        };

        // Step 5: build a Project on top to map SELECT column order and naming.
        var proj_exprs: std.ArrayListUnmanaged(Expr) = .empty;
        var proj_cols: std.ArrayListUnmanaged(SchemaCol) = .empty;

        for (stmt.columns) |sel_col| {
            switch (sel_col.col) {
                .star => {
                    for (agg_out_cols) |sc| {
                        try proj_exprs.append(self.alloc(), .{ .col_idx = sc.index });
                        try proj_cols.append(self.alloc(), sc);
                    }
                },
                .name => |n| {
                    const col_idx = try self.resolveColName(n, agg_out_schema);
                    const out_name = sel_col.alias orelse agg_out_cols[col_idx].name;
                    try proj_exprs.append(self.alloc(), .{ .col_idx = col_idx });
                    try proj_cols.append(self.alloc(), .{
                        .name = try self.alloc().dupe(u8, out_name),
                        .table = try self.alloc().dupe(u8, agg_out_cols[col_idx].table),
                        .col_type = agg_out_cols[col_idx].col_type,
                        .nullable = agg_out_cols[col_idx].nullable,
                        .index = col_idx,
                    });
                },
                .qual_name => |q| {
                    if (q.col == null) {
                        var matched = false;
                        for (agg_out_cols) |sc| {
                            if (std.ascii.eqlIgnoreCase(sc.table, q.table)) {
                                matched = true;
                                try proj_exprs.append(self.alloc(), .{ .col_idx = sc.index });
                                try proj_cols.append(self.alloc(), sc);
                            }
                        }
                        if (!matched) {
                            self.setError("Table '{s}' does not exist", .{q.table});
                            return PlanError.TableNotFound;
                        }
                    } else {
                        const col_idx = try self.resolveQualColName(q.table, q.col.?, agg_out_schema);
                        const out_name = sel_col.alias orelse agg_out_cols[col_idx].name;
                        try proj_exprs.append(self.alloc(), .{ .col_idx = col_idx });
                        try proj_cols.append(self.alloc(), .{
                            .name = try self.alloc().dupe(u8, out_name),
                            .table = try self.alloc().dupe(u8, agg_out_cols[col_idx].table),
                            .col_type = agg_out_cols[col_idx].col_type,
                            .nullable = agg_out_cols[col_idx].nullable,
                            .index = col_idx,
                        });
                    }
                },
                .expr => |e| {
                    const lp_expr = try self.resolveExprOverAgg(e, scan_schema, agg_specs_slice, group_by.len, agg_out_schema);
                    try proj_exprs.append(self.alloc(), lp_expr);
                    // Use alias, or derive name from the expression for direct references.
                    const col_name: []const u8 = if (sel_col.alias) |a| a else switch (lp_expr) {
                        .col_idx => |idx| if (idx < agg_out_cols.len) agg_out_cols[idx].name else "?",
                        else => switch (e) {
                            .func_call => |f| f.name,
                            .col_ref => |n| n,
                            else => "?",
                        },
                    };
                    try proj_cols.append(self.alloc(), .{
                        .name = try self.alloc().dupe(u8, col_name),
                        .table = "",
                        .col_type = .int,
                        .nullable = true,
                        .index = std.math.maxInt(usize),
                    });
                },
            }
        }

        const proj_schema = Schema{
            .table = agg_out_schema.table,
            .columns = try proj_cols.toOwnedSlice(self.alloc()),
        };
        const project = try self.alloc().create(Project);
        project.* = .{
            .input = try self.box(.{ .aggregate = agg_node }),
            .exprs = try proj_exprs.toOwnedSlice(self.alloc()),
            .schema = proj_schema,
        };
        return .{ .project = project };
    }

    // Walk expr and append one AggCallSpec for every aggregate function call found.
    // Recurse into scalar function args and binary/unary nodes; do not recurse into
    // aggregate function args (nested aggregates are not valid SQL).
    fn collectAggSpecs(
        self: *LogicalPlanner,
        expr: ast.Expr,
        scan_schema: Schema,
        out: *std.ArrayListUnmanaged(AggCallSpec),
    ) PlanError!void {
        switch (expr) {
            .func_call => |f| {
                if (agg_mod.find(f.name)) |agg_func| {
                    const input_expr = try self.resolveAggArg(f.args, scan_schema);
                    // DISTINCT requires a real argument, not a wildcard/no-arg.
                    if (f.distinct and input_expr == null) return PlanError.WrongArgCount;
                    try out.append(self.alloc(), .{ .func = agg_func, .input_expr = input_expr, .distinct = f.distinct });
                } else {
                    for (f.args) |arg| try self.collectAggSpecs(arg, scan_schema, out);
                }
            },
            .binary => |b| {
                try self.collectAggSpecs(b.left, scan_schema, out);
                try self.collectAggSpecs(b.right, scan_schema, out);
            },
            .unary => |u| try self.collectAggSpecs(u.operand, scan_schema, out),
            .in_list => |il| {
                try self.collectAggSpecs(il.operand, scan_schema, out);
                for (il.list) |item| try self.collectAggSpecs(item, scan_schema, out);
            },
            .between => |b| {
                try self.collectAggSpecs(b.operand, scan_schema, out);
                try self.collectAggSpecs(b.low, scan_schema, out);
                try self.collectAggSpecs(b.high, scan_schema, out);
            },
            .case_ => |c| {
                for (c.when_clauses) |w| {
                    try self.collectAggSpecs(w.cond, scan_schema, out);
                    try self.collectAggSpecs(w.then, scan_schema, out);
                }
                if (c.else_) |e| try self.collectAggSpecs(e, scan_schema, out);
            },
            .is_null => |n| try self.collectAggSpecs(n.operand, scan_schema, out),
            .cast => |c| try self.collectAggSpecs(c.operand, scan_schema, out),
            else => {},
        }
    }

    // Resolve the argument list of an aggregate call to a nullable resolved Expr.
    // Zero args → null (behaves like COUNT(*)).
    // One star arg → null (COUNT(*)).
    // Any other scalar expression → resolved Expr evaluated per row.
    fn resolveAggArg(self: *LogicalPlanner, args: []const ast.Expr, scan_schema: Schema) PlanError!?Expr {
        if (args.len == 0) return null;
        if (args.len > 1) return PlanError.WrongArgCount;
        return switch (args[0]) {
            .star => null,
            else => try self.resolveExpr(args[0], scan_schema),
        };
    }

    // Resolve a SELECT expression that sits above an Aggregate node.
    // Aggregate function calls are translated to col_idx references into the
    // aggregate output; all other sub-expressions are resolved recursively.
    fn resolveExprOverAgg(
        self: *LogicalPlanner,
        expr: ast.Expr,
        scan_schema: Schema,
        agg_specs: []const AggCallSpec,
        group_by_count: usize,
        agg_out_schema: Schema,
    ) PlanError!Expr {
        return switch (expr) {
            .int_lit => |v| .{ .int_lit = v },
            .float_lit => |v| .{ .float_lit = v },
            .str_lit => |v| .{ .str_lit = try self.alloc().dupe(u8, v) },
            .bool_lit => |v| .{ .bool_lit = v },
            .null_lit => .{ .null_lit = {} },
            .col_ref => |n| .{ .col_idx = try self.resolveColName(n, agg_out_schema) },
            .qual_col_ref => |q| if (q.col) |c|
                .{ .col_idx = try self.resolveQualColName(q.table, c, agg_out_schema) }
            else
                return PlanError.WildcardInExpression,
            .binary => |b| blk: {
                const node = try self.alloc().create(Expr.Binary);
                node.* = .{
                    .op = b.op,
                    .left = try self.resolveExprOverAgg(b.left, scan_schema, agg_specs, group_by_count, agg_out_schema),
                    .right = try self.resolveExprOverAgg(b.right, scan_schema, agg_specs, group_by_count, agg_out_schema),
                };
                break :blk .{ .binary = node };
            },
            .unary => |u| blk: {
                const node = try self.alloc().create(Expr.Unary);
                node.* = .{
                    .op = u.op,
                    .operand = try self.resolveExprOverAgg(u.operand, scan_schema, agg_specs, group_by_count, agg_out_schema),
                };
                break :blk .{ .unary = node };
            },
            .func_call => |f| blk: {
                if (agg_mod.find(f.name)) |_| {
                    // Aggregate call: find the matching AggCallSpec and return a
                    // col_idx into the aggregate output values slice.
                    const arg_expr = try self.resolveAggArg(f.args, scan_schema);
                    for (agg_specs, 0..) |spec, i| {
                        if (std.ascii.eqlIgnoreCase(spec.func.name, f.name) and
                            exprEql(spec.input_expr, arg_expr) and
                            spec.distinct == f.distinct)
                        {
                            break :blk Expr{ .col_idx = group_by_count + i };
                        }
                    }
                    return PlanError.ColumnNotFound;
                } else {
                    // Scalar function applied to aggregate outputs.
                    const func = sf.find(f.name) orelse return PlanError.UnknownFunction;
                    if (f.args.len < func.min_args or f.args.len > func.max_args) return PlanError.WrongArgCount;
                    const resolved_args = try self.alloc().alloc(Expr, f.args.len);
                    for (f.args, 0..) |arg, i| {
                        resolved_args[i] = try self.resolveExprOverAgg(arg, scan_schema, agg_specs, group_by_count, agg_out_schema);
                    }
                    const node = try self.alloc().create(Expr.FuncCall);
                    node.* = .{ .func = func, .args = resolved_args };
                    break :blk Expr{ .func_call = node };
                }
            },
            .cast => |c| blk: {
                const node = try self.alloc().create(Expr.Cast);
                node.* = .{
                    .target_type = c.target_type,
                    .operand = try self.resolveExprOverAgg(c.operand, scan_schema, agg_specs, group_by_count, agg_out_schema),
                };
                break :blk .{ .cast = node };
            },
            .in_list => |il| blk: {
                const node = try self.alloc().create(Expr.InList);
                const resolved_list = try self.alloc().alloc(Expr, il.list.len);
                for (il.list, 0..) |item, i| {
                    resolved_list[i] = try self.resolveExprOverAgg(item, scan_schema, agg_specs, group_by_count, agg_out_schema);
                }
                node.* = .{
                    .operand = try self.resolveExprOverAgg(il.operand, scan_schema, agg_specs, group_by_count, agg_out_schema),
                    .list = resolved_list,
                    .negated = il.negated,
                };
                break :blk .{ .in_list = node };
            },
            .between => |b| blk: {
                const operand_lo = try self.resolveExprOverAgg(b.operand, scan_schema, agg_specs, group_by_count, agg_out_schema);
                const operand_hi = try self.resolveExprOverAgg(b.operand, scan_schema, agg_specs, group_by_count, agg_out_schema);
                const lo = try self.resolveExprOverAgg(b.low, scan_schema, agg_specs, group_by_count, agg_out_schema);
                const hi = try self.resolveExprOverAgg(b.high, scan_schema, agg_specs, group_by_count, agg_out_schema);
                const cmp_lo = try self.alloc().create(Expr.Binary);
                const cmp_hi = try self.alloc().create(Expr.Binary);
                const combined = try self.alloc().create(Expr.Binary);
                if (!b.negated) {
                    cmp_lo.* = .{ .op = .gte, .left = operand_lo, .right = lo };
                    cmp_hi.* = .{ .op = .lte, .left = operand_hi, .right = hi };
                    combined.* = .{ .op = .and_, .left = .{ .binary = cmp_lo }, .right = .{ .binary = cmp_hi } };
                } else {
                    cmp_lo.* = .{ .op = .lt, .left = operand_lo, .right = lo };
                    cmp_hi.* = .{ .op = .gt, .left = operand_hi, .right = hi };
                    combined.* = .{ .op = .or_, .left = .{ .binary = cmp_lo }, .right = .{ .binary = cmp_hi } };
                }
                break :blk Expr{ .binary = combined };
            },
            .case_ => |c| blk: {
                const node = try self.alloc().create(Expr.Case);
                const resolved_whens = try self.alloc().alloc(Expr.Case.WhenClause, c.when_clauses.len);
                for (c.when_clauses, 0..) |w, i| {
                    resolved_whens[i] = .{
                        .cond = try self.resolveExprOverAgg(w.cond, scan_schema, agg_specs, group_by_count, agg_out_schema),
                        .then = try self.resolveExprOverAgg(w.then, scan_schema, agg_specs, group_by_count, agg_out_schema),
                    };
                }
                node.* = .{
                    .when_clauses = resolved_whens,
                    .else_ = if (c.else_) |e| try self.resolveExprOverAgg(e, scan_schema, agg_specs, group_by_count, agg_out_schema) else null,
                };
                break :blk .{ .case_ = node };
            },
            .is_null => |n| blk: {
                const node = try self.alloc().create(Expr.IsNull);
                node.* = .{
                    .operand = try self.resolveExprOverAgg(n.operand, scan_schema, agg_specs, group_by_count, agg_out_schema),
                    .negated = n.negated,
                };
                break :blk .{ .is_null = node };
            },
            .star => return PlanError.WildcardInExpression,
            .default_value => std.debug.panic("DEFAULT must be resolved during planning", .{}),
        };
    }

    // ── Expression resolution ──────────────────────────────────────────────────

    fn resolveExpr(self: *LogicalPlanner, expr: ast.Expr, schema: Schema) PlanError!Expr {
        return switch (expr) {
            .int_lit => |v| .{ .int_lit = v },
            .float_lit => |v| .{ .float_lit = v },
            .str_lit => |v| .{ .str_lit = try self.alloc().dupe(u8, v) },
            .bool_lit => |v| .{ .bool_lit = v },
            .null_lit => .{ .null_lit = {} },
            // star is only valid inside COUNT(*); it must not reach regular expr resolution.
            .star => return PlanError.WildcardInExpression,
            .col_ref => |n| .{ .col_idx = try self.resolveColName(n, schema) },
            .qual_col_ref => |q| if (q.col) |col| .{ .col_idx = try self.resolveQualColName(q.table, col, schema) } else return PlanError.WildcardInExpression,
            .binary => |b| blk: {
                const node = try self.alloc().create(Expr.Binary);
                node.* = .{
                    .op = b.op,
                    .left = try self.resolveExpr(b.left, schema),
                    .right = try self.resolveExpr(b.right, schema),
                };
                break :blk .{ .binary = node };
            },
            .unary => |u| blk: {
                const node = try self.alloc().create(Expr.Unary);
                node.* = .{
                    .op = u.op,
                    .operand = try self.resolveExpr(u.operand, schema),
                };
                break :blk .{ .unary = node };
            },
            .func_call => |f| blk: {
                // Look up the function in the registry at plan time — same pattern
                // as vtable resolution.  The pointer into REGISTRY is stored in the
                // plan and used directly by the evaluator, with no string comparison
                // at execution time.
                const func = sf.find(f.name) orelse {
                    self.setError("Unknown function '{s}'", .{f.name});
                    return PlanError.UnknownFunction;
                };
                if (f.args.len < func.min_args or f.args.len > func.max_args) {
                    self.setError("Function '{s}' expects {d}-{d} arguments but got {d}", .{ f.name, func.min_args, func.max_args, f.args.len });
                    return PlanError.WrongArgCount;
                }
                const resolved_args = try self.alloc().alloc(Expr, f.args.len);
                for (f.args, 0..) |arg, i| resolved_args[i] = try self.resolveExpr(arg, schema);
                const node = try self.alloc().create(Expr.FuncCall);
                node.* = .{ .func = func, .args = resolved_args };
                break :blk .{ .func_call = node };
            },
            .cast => |c| blk: {
                const node = try self.alloc().create(Expr.Cast);
                node.* = .{
                    .target_type = c.target_type,
                    .operand = try self.resolveExpr(c.operand, schema),
                };
                break :blk .{ .cast = node };
            },
            .in_list => |il| blk: {
                const node = try self.alloc().create(Expr.InList);
                const resolved_list = try self.alloc().alloc(Expr, il.list.len);
                for (il.list, 0..) |item, i| resolved_list[i] = try self.resolveExpr(item, schema);
                node.* = .{
                    .operand = try self.resolveExpr(il.operand, schema),
                    .list = resolved_list,
                    .negated = il.negated,
                };
                break :blk .{ .in_list = node };
            },
            // BETWEEN desugars to (operand >= low AND operand <= high).
            // NOT BETWEEN desugars to (operand < low OR operand > high).
            // The operand is resolved twice (two col_idx nodes pointing at the same
            // column), which is safe because evaluation is pure — no side effects.
            .between => |b| try self.resolveBetween(b.operand, b.low, b.high, b.negated, schema),
            .case_ => |c| blk: {
                const node = try self.alloc().create(Expr.Case);
                const resolved_whens = try self.alloc().alloc(Expr.Case.WhenClause, c.when_clauses.len);
                for (c.when_clauses, 0..) |w, i| {
                    resolved_whens[i] = .{
                        .cond = try self.resolveExpr(w.cond, schema),
                        .then = try self.resolveExpr(w.then, schema),
                    };
                }
                node.* = .{
                    .when_clauses = resolved_whens,
                    .else_ = if (c.else_) |e| try self.resolveExpr(e, schema) else null,
                };
                break :blk .{ .case_ = node };
            },
            .is_null => |n| blk: {
                const node = try self.alloc().create(Expr.IsNull);
                node.* = .{ .operand = try self.resolveExpr(n.operand, schema), .negated = n.negated };
                break :blk .{ .is_null = node };
            },
            // DEFAULT should have been rewritten to the column's default expression
            // during INSERT/UPDATE planning. It must not reach this stage.
            .default_value => std.debug.panic("DEFAULT must be resolved during planning", .{}),
        };
    }

    fn resolveBetween(
        self: *LogicalPlanner,
        operand: ast.Expr,
        low: ast.Expr,
        high: ast.Expr,
        negated: bool,
        schema: Schema,
    ) PlanError!Expr {
        const op_lo = try self.resolveExpr(operand, schema);
        const op_hi = try self.resolveExpr(operand, schema);
        const lo = try self.resolveExpr(low, schema);
        const hi = try self.resolveExpr(high, schema);

        const cmp_lo = try self.alloc().create(Expr.Binary);
        const cmp_hi = try self.alloc().create(Expr.Binary);
        const combined = try self.alloc().create(Expr.Binary);

        if (!negated) {
            // operand >= low AND operand <= high
            cmp_lo.* = .{ .op = .gte, .left = op_lo, .right = lo };
            cmp_hi.* = .{ .op = .lte, .left = op_hi, .right = hi };
            combined.* = .{ .op = .and_, .left = .{ .binary = cmp_lo }, .right = .{ .binary = cmp_hi } };
        } else {
            // operand < low OR operand > high
            cmp_lo.* = .{ .op = .lt, .left = op_lo, .right = lo };
            cmp_hi.* = .{ .op = .gt, .left = op_hi, .right = hi };
            combined.* = .{ .op = .or_, .left = .{ .binary = cmp_lo }, .right = .{ .binary = cmp_hi } };
        }
        return .{ .binary = combined };
    }

    fn resolveColName(self: *LogicalPlanner, name: []const u8, schema: Schema) PlanError!usize {
        for (schema.columns) |col| {
            if (std.ascii.eqlIgnoreCase(name, col.name)) return col.index;
        }
        self.setError("Column '{s}' does not exist", .{name});
        return PlanError.ColumnNotFound;
    }

    // Build SortKey slice from ORDER BY AST items, resolved against the Project's
    // output columns.  A "projected resolution schema" is synthesised where each
    // column's index equals its 0-based position in the projected values slice so
    // that col_idx values in the resulting Expr nodes index correctly into the row
    // values produced by ProjectCursor.
    fn resolveOrderByKeys(
        self: *LogicalPlanner,
        order_by: []const ast.OrderByItem,
        proj_cols: []const SchemaCol,
        proj_table: []const u8,
    ) PlanError![]SortKey {
        // Build a resolution schema where index = position in projected output.
        const res_cols = try self.alloc().alloc(SchemaCol, proj_cols.len);
        for (proj_cols, 0..) |col, i| {
            res_cols[i] = .{
                .name = col.name,
                .table = col.table,
                .col_type = col.col_type,
                .nullable = col.nullable,
                .index = i,
            };
        }
        const res_schema = Schema{ .table = proj_table, .columns = res_cols };

        const keys = try self.alloc().alloc(SortKey, order_by.len);
        for (order_by, 0..) |item, i| {
            const expr: Expr = switch (item.expr) {
                // Positional reference: ORDER BY 1 → col at position 0.
                .int_lit => |pos| blk: {
                    if (pos < 1 or @as(usize, @intCast(pos)) > proj_cols.len) {
                        self.setError("ORDER BY position {d} is out of range (query has {d} output columns)", .{ pos, proj_cols.len });
                        return PlanError.ColumnNotFound;
                    }
                    break :blk .{ .col_idx = @intCast(pos - 1) };
                },
                else => try self.resolveExpr(item.expr, res_schema),
            };
            keys[i] = .{ .expr = expr, .descending = item.direction == .desc };
        }
        return keys;
    }

    // Resolve a table-qualified column reference (tbl.col) to its merged index.
    fn resolveQualColName(self: *LogicalPlanner, table: []const u8, col_name: []const u8, schema: Schema) PlanError!usize {
        for (schema.columns) |col| {
            if (std.ascii.eqlIgnoreCase(table, col.table) and
                std.ascii.eqlIgnoreCase(col_name, col.name))
            {
                return col.index;
            }
        }
        self.setError("Column '{s}.{s}' does not exist", .{ table, col_name });
        return PlanError.ColumnNotFound;
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    fn buildVTabSchema(self: *LogicalPlanner, name: []const u8, vt: *const vtab_mod.VTab) PlanError!Schema {
        const duped_name = try self.alloc().dupe(u8, name);
        const cols = try self.alloc().alloc(SchemaCol, vt.columns.len);
        for (vt.columns, 0..) |col, i| {
            cols[i] = .{
                .name = try self.alloc().dupe(u8, col.name),
                .table = duped_name,
                .col_type = col.col_type,
                .nullable = col.nullable,
                .index = i,
            };
        }
        return Schema{ .table = duped_name, .columns = cols };
    }

    fn resolveVTabArgs(self: *LogicalPlanner, args: []const ast.Expr) PlanError![]const vtab_mod.Value {
        const resolved = try self.alloc().alloc(vtab_mod.Value, args.len);
        for (args, 0..) |arg, i| {
            resolved[i] = switch (arg) {
                .int_lit => |v| .{ .int = v },
                .float_lit => |v| .{ .real = v },
                .str_lit => |v| .{ .text = v },
                .bool_lit => |v| .{ .int = if (v) 1 else 0 },
                .unary => |u| if (u.op == .neg and u.operand == .int_lit)
                    .{ .int = -u.operand.int_lit }
                else
                    return PlanError.TypeMismatch,
                else => return PlanError.TypeMismatch,
            };
        }
        return resolved;
    }

    // Turn a TableRef into a leaf scan node and its schema.  Used for both the
    // FROM clause and each INNER JOIN right-hand side.
    // SchemaCol.table is set to the alias (when present) so qualified column
    // references resolve against the alias rather than the real table name.
    // SeqScan.table always holds the real catalog name for execution.
    const ScanResult = struct { plan: LogicalPlan, schema: Schema };
    fn buildScan(self: *LogicalPlanner, ref: ?ast.TableRef) PlanError!ScanResult {
        if (ref == null) {
            return ScanResult{ .plan = .{ .const_scan = {} }, .schema = .{
                .table = "",
                .columns = &.{},
            } };
        }

        return switch (ref.?) {
            .name => |q| blk: {
                const effective = q.alias orelse q.name;
                if (std.ascii.eqlIgnoreCase(q.schema orelse "main", "main")) {
                    if (self.cat.getTable(q.name)) |meta| {
                        const s = try self.buildSchema(meta, q.alias);
                        break :blk ScanResult{
                            .plan = .{ .seq_scan = .{
                                .table = try self.alloc().dupe(u8, meta.name),
                                .schema = s,
                            } },
                            .schema = s,
                        };
                    }
                }
                // Not a user table — try the vtab registry (zero-arg access).
                const vt = vtab_mod.find(q.schema orelse "main", q.name) orelse {
                    self.setError("Table '{s}' does not exist", .{q.name});
                    return PlanError.TableNotFound;
                };
                if (vt.min_args > 0) return PlanError.ArgCountMismatch;
                const s = try self.buildVTabSchema(effective, vt);
                break :blk ScanResult{
                    .plan = .{ .vtab_scan = .{ .name = s.table, .args = &.{}, .schema = s, .vtab = vt } },
                    .schema = s,
                };
            },
            .func => |f| blk: {
                if (f.schema) |schema_name| {
                    if (!std.ascii.eqlIgnoreCase(schema_name, "main")) return PlanError.TableNotFound;
                }
                const vt = vtab_mod.find(f.schema orelse "main", f.name) orelse {
                    self.setError("Table function '{s}' does not exist", .{f.name});
                    return PlanError.TableNotFound;
                };
                if (f.args.len < vt.min_args or f.args.len > vt.max_args) return PlanError.ArgCountMismatch;
                const resolved_args = try self.resolveVTabArgs(f.args);
                const effective = f.alias orelse f.name;
                const s = try self.buildVTabSchema(effective, vt);
                break :blk ScanResult{
                    .plan = .{ .vtab_scan = .{ .name = s.table, .args = resolved_args, .schema = s, .vtab = vt } },
                    .schema = s,
                };
            },
        };
    }

    // alias overrides the table name used in SchemaCol.table for qualified column
    // resolution (e.g. SELECT u.id FROM users AS u).  Pass null for no alias.
    // Note: SeqScan.table must still hold the real catalog name for execution;
    // callers are responsible for setting that field from meta.name directly.
    fn buildSchema(self: *LogicalPlanner, meta: *catalog.TableMeta, alias: ?[]const u8) PlanError!Schema {
        const effective_name = alias orelse meta.name;
        const duped_name = try self.alloc().dupe(u8, effective_name);
        // Real columns followed by three hidden metadata cols (__rowid, __pageid, __slotid).
        // Hidden cols are excluded from SELECT * but addressable by name.
        const n = meta.columns.len;
        const cols = try self.alloc().alloc(SchemaCol, n + 3);
        for (meta.columns, 0..) |c, i| {
            cols[i] = .{
                .name = try self.alloc().dupe(u8, c.name),
                .table = duped_name,
                .col_type = c.col_type,
                .nullable = c.nullable,
                .index = i,
            };
        }
        cols[n] = .{ .name = "__rowid", .table = duped_name, .col_type = .int, .nullable = false, .index = n };
        cols[n + 1] = .{ .name = "__pageid", .table = duped_name, .col_type = .int, .nullable = true, .index = n + 1 };
        cols[n + 2] = .{ .name = "__slotid", .table = duped_name, .col_type = .int, .nullable = true, .index = n + 2 };
        return Schema{ .table = duped_name, .columns = cols };
    }

    // Build a merged schema for a join: left columns keep their indices, right
    // column indices are offset by left_count so they address distinct positions
    // in the combined values slice produced by JoinCursor.
    fn mergeSchemas(self: *LogicalPlanner, left: Schema, right: Schema, left_count: usize) PlanError!Schema {
        const total = left_count + right.columns.len;
        const cols = try self.alloc().alloc(SchemaCol, total);
        for (left.columns, 0..) |col, i| {
            cols[i] = col;
        }
        for (right.columns, 0..) |col, i| {
            cols[left_count + i] = .{
                .name = col.name,
                .table = col.table,
                .col_type = col.col_type,
                .nullable = col.nullable,
                .index = left_count + i,
            };
        }
        return Schema{ .table = "", .columns = cols };
    }

    // Heap-allocate a LogicalPlan node in the planner's arena.
    fn box(self: *LogicalPlanner, p: LogicalPlan) PlanError!*LogicalPlan {
        const ptr = try self.alloc().create(LogicalPlan);
        ptr.* = p;
        return ptr;
    }
};

// Structural equality for nullable aggregate input expressions.
// Used to deduplicate identical aggregate calls within the same SELECT list
// (e.g. COUNT(*) + COUNT(*) shares a single Aggregate output column).
fn exprEql(a: ?Expr, b: ?Expr) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return exprEqlInner(a.?, b.?);
}

fn exprEqlInner(a: Expr, b: Expr) bool {
    return switch (a) {
        .int_lit => |av| b == .int_lit and b.int_lit == av,
        .float_lit => |av| b == .float_lit and b.float_lit == av,
        .str_lit => |av| b == .str_lit and std.mem.eql(u8, av, b.str_lit),
        .bool_lit => |av| b == .bool_lit and b.bool_lit == av,
        .null_lit => b == .null_lit,
        .col_idx => |av| b == .col_idx and b.col_idx == av,
        .binary => |av| b == .binary and
            av.op == b.binary.op and
            exprEqlInner(av.left, b.binary.left) and
            exprEqlInner(av.right, b.binary.right),
        .unary => |av| b == .unary and
            av.op == b.unary.op and
            exprEqlInner(av.operand, b.unary.operand),
        .func_call => |av| b == .func_call and
            av.func == b.func_call.func and
            av.args.len == b.func_call.args.len and blk: {
            for (av.args, b.func_call.args) |aa, ba| {
                if (!exprEqlInner(aa, ba)) break :blk false;
            }
            break :blk true;
        },
        .cast => |av| b == .cast and
            av.target_type == b.cast.target_type and
            exprEqlInner(av.operand, b.cast.operand),
        .in_list => |av| b == .in_list and
            av.negated == b.in_list.negated and
            av.list.len == b.in_list.list.len and
            exprEqlInner(av.operand, b.in_list.operand) and blk: {
            for (av.list, b.in_list.list) |ai, bi| {
                if (!exprEqlInner(ai, bi)) break :blk false;
            }
            break :blk true;
        },
        .is_null => |av| b == .is_null and av.negated == b.is_null.negated and exprEqlInner(av.operand, b.is_null.operand),
        .case_ => |av| b == .case_ and
            av.when_clauses.len == b.case_.when_clauses.len and blk: {
            for (av.when_clauses, b.case_.when_clauses) |aw, bw| {
                if (!exprEqlInner(aw.cond, bw.cond) or !exprEqlInner(aw.then, bw.then)) break :blk false;
            }
            const else_eql = (av.else_ == null and b.case_.else_ == null) or
                (av.else_ != null and b.case_.else_ != null and exprEqlInner(av.else_.?, b.case_.else_.?));
            break :blk else_eql;
        },
    };
}
