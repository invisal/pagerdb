const std = @import("std");
const t = @import("../../types.zig");
const ast = @import("../ast.zig");
const catalog = @import("../../catalog.zig");
const vtab_mod = @import("../../vtable/root.zig");

// Reserved column index that maps to the internal rowid (not a real column).
// We use maxInt(usize) because:
//   1) It's impossible to confuse with any valid column index
//   2) It can be detected at compile time when used in switch expressions
//   3) The physical planner can turn Filter(SeqScan, col_idx = ROWID_SENTINEL = N)
//      into a PointLookup node that uses the B-tree directly instead of scanning.
pub const ROWID_SENTINEL: usize = std.math.maxInt(usize);

// ── Schema ─────────────────────────────────────────────────────────────────────

pub const SchemaCol = struct {
    name: []const u8, // arena-owned
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
    col_idx: usize, // source column index; ROWID_SENTINEL = _rowid_
    binary: *Binary,
    unary: *Unary,

    pub const Binary = struct { op: ast.BinaryOp, left: Expr, right: Expr };
    pub const Unary = struct { op: ast.UnaryOp, operand: Expr };
};

// ── Plan nodes ─────────────────────────────────────────────────────────────────

pub const SeqScan = struct {
    table: []const u8, // arena-owned
    schema: Schema,
};

pub const VTabScan = struct {
    name: []const u8, // arena-owned
    args: []const i64, // resolved integer args, arena-owned
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
    col_indices: []usize, // source column indices in output order
    schema: Schema, // output columns; schema.columns[i].index = col_indices[i]
};

pub const LogicalInsert = struct {
    table: []const u8,
    values: []Expr, // one resolved Expr per column, positional
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

pub const LogicalPlan = union(enum) {
    seq_scan: SeqScan,
    vtab_scan: VTabScan,
    filter: *Filter,
    project: *Project,
    insert: LogicalInsert,
    update: LogicalUpdate,
    delete: LogicalDelete,
    create_table: LogicalCreateTable,

    pub fn schema(self: LogicalPlan) Schema {
        return switch (self) {
            .seq_scan => |n| n.schema,
            .vtab_scan => |n| n.schema,
            .filter => |n| n.schema,
            .project => |n| n.schema,
            .insert => |n| n.schema,
            .update => |n| n.schema,
            .delete => |n| n.schema,
            .create_table => Schema{ .table = "", .columns = &.{} },
        };
    }
};

// ── Planner ────────────────────────────────────────────────────────────────────

pub const PlanError = error{
    TableNotFound,
    ColumnNotFound,
    TypeMismatch,
    ColumnCountMismatch,
    ArgCountMismatch,
    OutOfMemory,
    NoDefaultValue,
};

pub const LogicalPlanner = struct {
    cat: *catalog.Catalog,
    arena: std.heap.ArenaAllocator,

    pub fn init(cat: *catalog.Catalog, allocator: std.mem.Allocator) LogicalPlanner {
        return .{ .cat = cat, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *LogicalPlanner) void {
        self.arena.deinit();
    }

    fn alloc(self: *LogicalPlanner) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn plan(self: *LogicalPlanner, stmt: ast.Stmt) PlanError!LogicalPlan {
        return switch (stmt) {
            .select => |s| try self.planSelect(s),
            .insert => |s| try self.planInsert(s),
            .update => |s| try self.planUpdate(s),
            .delete => |s| try self.planDelete(s),
            .create_table => |s| try self.planCreateTable(s),
        };
    }

    // ── SELECT ─────────────────────────────────────────────────────────────────

    fn planSelect(self: *LogicalPlanner, stmt: ast.SelectStmt) PlanError!LogicalPlan {
        // Build the leaf scan node and its schema from the table reference.
        var scan_schema: Schema = undefined;
        var current: LogicalPlan = switch (stmt.table_ref) {
            .name => |qualified| blk: {
                const table_name = qualified.name;

                if (std.ascii.eqlIgnoreCase(qualified.schema orelse "main", "main")) {
                    if (self.cat.getTable(table_name)) |meta| {
                        scan_schema = try self.buildSchema(meta);
                        break :blk LogicalPlan{ .seq_scan = .{ .table = scan_schema.table, .schema = scan_schema } };
                    }
                }

                // Not a user table — try the vtab registry (zero-arg access).
                const vt = vtab_mod.find(qualified.schema orelse "main", table_name) orelse return PlanError.TableNotFound;
                if (vt.min_args > 0) return PlanError.ArgCountMismatch;

                scan_schema = try self.buildVTabSchema(table_name, vt);
                break :blk LogicalPlan{ .vtab_scan = .{
                    .name = scan_schema.table,
                    .args = &.{},
                    .schema = scan_schema,
                    .vtab = vt,
                } };
            },
            .func => |f| blk: {
                // For now, only support "main" schema (or default/null) for TVFs
                if (f.schema) |schema| {
                    if (!std.ascii.eqlIgnoreCase(schema, "main")) {
                        return PlanError.TableNotFound;
                    }
                }
                const vt = vtab_mod.find(f.schema orelse "main", f.name) orelse return PlanError.TableNotFound;
                if (f.args.len < vt.min_args or f.args.len > vt.max_args)
                    return PlanError.ArgCountMismatch;
                const resolved_args = try self.resolveVTabArgs(f.args);
                scan_schema = try self.buildVTabSchema(f.name, vt);
                break :blk LogicalPlan{ .vtab_scan = .{
                    .name = scan_schema.table,
                    .args = resolved_args,
                    .schema = scan_schema,
                    .vtab = vt,
                } };
            },
        };

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

        // Wrap in Project if specific columns were requested (not SELECT *).
        if (stmt.columns.len > 0) {
            var col_indices: std.ArrayList(usize) = .empty;
            var proj_cols: std.ArrayList(SchemaCol) = .empty;

            for (stmt.columns) |sel_col| {
                const src_idx = try self.resolveColName(sel_col.name, scan_schema);
                try col_indices.append(self.alloc(), src_idx);
                for (scan_schema.columns) |sc| {
                    if (sc.index == src_idx) {
                        try proj_cols.append(self.alloc(), .{
                            .name = try self.alloc().dupe(u8, sc.name),
                            .col_type = sc.col_type,
                            .nullable = sc.nullable,
                            .index = src_idx,
                        });
                        break;
                    }
                }
            }

            const proj_schema = Schema{
                .table = scan_schema.table,
                .columns = try proj_cols.toOwnedSlice(self.alloc()),
            };
            const project = try self.alloc().create(Project);
            project.* = .{
                .input = try self.box(current),
                .col_indices = try col_indices.toOwnedSlice(self.alloc()),
                .schema = proj_schema,
            };
            current = .{ .project = project };
        }

        return current;
    }

    /// Builds a logical plan for an INSERT statement.
    /// Handles both named and positional inserts, resolves expressions,
    /// and ensures all required columns are provided.
    fn planInsert(self: *LogicalPlanner, stmt: ast.InsertStmt) PlanError!LogicalPlan {
        const meta = self.cat.getTable(stmt.table) orelse
            return PlanError.TableNotFound;

        const schema = try self.buildSchema(meta);
        const col_count = meta.columns.len;

        const row_values = try self.alloc().alloc(Expr, col_count);
        const is_set = try self.alloc().alloc(bool, col_count);

        // Initialize defaults
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
            // INSERT INTO table_name(col1, col2, ...)
            if (stmt.columns.len != stmt.values.len)
                return PlanError.ColumnCountMismatch;

            for (stmt.columns, 0..) |name, i| {
                const col = meta.findColumn(name) orelse
                    return PlanError.ColumnNotFound;

                const idx = col.attnum;

                const current_value = stmt.values[i];

                if (current_value == .default_value) {
                    if (meta.columns[idx].default_expr) |default_expr| {
                        row_values[idx] = try self.resolveExpr(default_expr, schema);
                    } else {
                        return PlanError.NoDefaultValue;
                    }
                } else {
                    row_values[idx] = try self.resolveExpr(current_value, schema);
                }

                is_set[idx] = true;
            }
        } else {
            // Positional insert (values mapped by column order)
            // INSERT INTO table_name VALUES (...)
            if (stmt.values.len > col_count)
                return PlanError.ColumnCountMismatch;

            for (stmt.values, 0..) |expr, i| {
                if (expr == .default_value) {
                    if (meta.columns[i].default_expr) |default_expr| {
                        row_values[i] = try self.resolveExpr(default_expr, schema);
                    } else {
                        return PlanError.NoDefaultValue;
                    }
                } else {
                    row_values[i] = try self.resolveExpr(expr, schema);
                }

                is_set[i] = true;
            }
        }

        // Ensure all required columns are filled
        for (is_set) |set| {
            if (!set) return PlanError.ColumnNotFound;
        }

        return .{
            .insert = .{
                .table = schema.table,
                .values = row_values,
                .schema = schema,
            },
        };
    }

    // ── UPDATE ─────────────────────────────────────────────────────────────────

    fn planUpdate(self: *LogicalPlanner, stmt: ast.UpdateStmt) PlanError!LogicalPlan {
        const meta = self.cat.getTable(stmt.table) orelse return PlanError.TableNotFound;
        const schema = try self.buildSchema(meta);

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
        const meta = self.cat.getTable(stmt.table) orelse return PlanError.TableNotFound;
        const schema = try self.buildSchema(meta);

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

    // ── Expression resolution ──────────────────────────────────────────────────

    fn resolveExpr(self: *LogicalPlanner, expr: ast.Expr, schema: Schema) PlanError!Expr {
        return switch (expr) {
            .int_lit => |v| .{ .int_lit = v },
            .float_lit => |v| .{ .float_lit = v },
            .str_lit => |v| .{ .str_lit = try self.alloc().dupe(u8, v) },
            .bool_lit => |v| .{ .bool_lit = v },
            .null_lit => .{ .null_lit = {} },
            .col_ref => |n| .{ .col_idx = try self.resolveColName(n, schema) },
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
            // DEFAULT should have been rewritten to the column's default expression
            // during INSERT/UPDATE planning. It must not reach this stage.
            .default_value => std.debug.panic("DEFAULT must be resolved during planning", .{}),
        };
    }

    fn resolveColName(_: *LogicalPlanner, name: []const u8, schema: Schema) PlanError!usize {
        if (std.ascii.eqlIgnoreCase(name, "_rowid_")) return ROWID_SENTINEL;
        for (schema.columns) |col| {
            if (std.ascii.eqlIgnoreCase(name, col.name)) return col.index;
        }
        return PlanError.ColumnNotFound;
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    fn buildVTabSchema(self: *LogicalPlanner, name: []const u8, vt: *const vtab_mod.VTab) PlanError!Schema {
        const cols = try self.alloc().alloc(SchemaCol, vt.columns.len);
        for (vt.columns, 0..) |col, i| {
            cols[i] = .{
                .name = try self.alloc().dupe(u8, col.name),
                .col_type = col.col_type,
                .nullable = col.nullable,
                .index = i,
            };
        }
        return Schema{
            .table = try self.alloc().dupe(u8, name),
            .columns = cols,
        };
    }

    fn resolveVTabArgs(self: *LogicalPlanner, args: []const ast.Expr) PlanError![]const i64 {
        const resolved = try self.alloc().alloc(i64, args.len);
        for (args, 0..) |arg, i| {
            resolved[i] = switch (arg) {
                .int_lit => |v| v,
                .unary => |u| if (u.op == .neg and u.operand == .int_lit)
                    -u.operand.int_lit
                else
                    return PlanError.TypeMismatch,
                else => return PlanError.TypeMismatch,
            };
        }
        return resolved;
    }

    fn buildSchema(self: *LogicalPlanner, meta: *catalog.TableMeta) PlanError!Schema {
        const cols = try self.alloc().alloc(SchemaCol, meta.columns.len);
        for (meta.columns, 0..) |c, i| {
            cols[i] = .{
                .name = try self.alloc().dupe(u8, c.name),
                .col_type = c.col_type,
                .nullable = c.nullable,
                .index = i,
            };
        }
        return Schema{
            .table = try self.alloc().dupe(u8, meta.name),
            .columns = cols,
        };
    }

    // Heap-allocate a LogicalPlan node in the planner's arena.
    fn box(self: *LogicalPlanner, p: LogicalPlan) PlanError!*LogicalPlan {
        const ptr = try self.alloc().create(LogicalPlan);
        ptr.* = p;
        return ptr;
    }
};
