const std = @import("std");
const t = @import("../types.zig");

pub const BinaryOp = enum {
    eq,
    neq,
    lt,
    lte,
    gt,
    gte,
    and_,
    or_,
    add,
    sub,
    mul,
    div,
};

pub const UnaryOp = enum { not, neg };

// A column reference qualified by table name: tbl.col
pub const QualifiedColRef = struct {
    table: []const u8, // arena-owned
    col: ?[]const u8, // arena-owned. NULL means table.*
};

pub const Expr = union(enum) {
    int_lit: i64,
    float_lit: f64,
    str_lit: []const u8, // arena-owned copy, '' already unescaped
    bool_lit: bool,
    null_lit: void,
    col_ref: []const u8, // unqualified column name, arena-owned
    qual_col_ref: QualifiedColRef, // table.col reference, arena-owned
    default_value: void, // using column default value
    // Wildcard argument in aggregate calls: COUNT(*).  Only valid as the sole
    // argument to an aggregate function; the planner rejects it elsewhere.
    star: void,

    // Binary, unary, func_call, and cast nodes are heap-allocated so the Expr
    // union stays small (two pointers).  This keeps stack frames shallow during
    // deep recursion in the parser, and makes moving Expr values cheap (no deep copy).
    binary: *Binary,
    unary: *Unary,
    func_call: *FuncCall,
    cast: *Cast,
    in_list: *InList,
    between: *Between,
    case_: *Case,
    is_null: *IsNull,

    pub const Binary = struct { op: BinaryOp, left: Expr, right: Expr };
    pub const Unary = struct { op: UnaryOp, operand: Expr };
    pub const FuncCall = struct { name: []const u8, args: []Expr, distinct: bool = false };
    pub const Cast = struct { target_type: t.ColType, operand: Expr };
    // expr [NOT] IN (val1, val2, ...) — scalar value list, not a subquery.
    pub const InList = struct { operand: Expr, list: []Expr, negated: bool };
    // expr [NOT] BETWEEN low AND high — desugars to (>= low AND <= high) in the planner.
    pub const Between = struct { operand: Expr, low: Expr, high: Expr, negated: bool };
    // expr IS [NOT] NULL — SQL null check (distinct from = NULL which returns NULL).
    pub const IsNull = struct { operand: Expr, negated: bool };
    // CASE WHEN cond THEN result ... [ELSE result] END (searched form).
    // Simple CASE (CASE input WHEN val THEN result END) is converted to
    // the searched form during parsing by rewriting each WHEN val as WHEN input = val.
    pub const Case = struct {
        pub const WhenClause = struct { cond: Expr, then: Expr };
        when_clauses: []WhenClause,
        else_: ?Expr, // null means no ELSE (result is NULL when no clause matches)
    };

    /// Deep-clone the expression to a different allocator.
    /// Used when transferring expressions from the parser's arena to the catalog.
    pub fn clone(self: Expr, allocator: std.mem.Allocator) std.mem.Allocator.Error!Expr {
        return switch (self) {
            .int_lit => |v| .{ .int_lit = v },
            .float_lit => |v| .{ .float_lit = v },
            .str_lit => |v| .{ .str_lit = try allocator.dupe(u8, v) },
            .bool_lit => |v| .{ .bool_lit = v },
            .null_lit => .{ .null_lit = {} },
            .col_ref => |n| .{ .col_ref = try allocator.dupe(u8, n) },
            .qual_col_ref => |q| .{ .qual_col_ref = .{
                .table = try allocator.dupe(u8, q.table),
                .col = if (q.col) |col| try allocator.dupe(u8, col) else null,
            } },
            .binary => |b| blk: {
                const node = try allocator.create(Binary);
                node.* = .{
                    .op = b.op,
                    .left = try b.left.clone(allocator),
                    .right = try b.right.clone(allocator),
                };
                break :blk .{ .binary = node };
            },
            .unary => |u| blk: {
                const node = try allocator.create(Unary);
                node.* = .{
                    .op = u.op,
                    .operand = try u.operand.clone(allocator),
                };
                break :blk .{ .unary = node };
            },
            .default_value => .{ .default_value = {} },
            .star => .{ .star = {} },
            .func_call => |f| blk: {
                const node = try allocator.create(FuncCall);
                const cloned_args = try allocator.alloc(Expr, f.args.len);
                for (f.args, 0..) |arg, i| cloned_args[i] = try arg.clone(allocator);
                node.* = .{
                    .name = try allocator.dupe(u8, f.name),
                    .args = cloned_args,
                    .distinct = f.distinct,
                };
                break :blk .{ .func_call = node };
            },
            .cast => |c| blk: {
                const node = try allocator.create(Cast);
                node.* = .{ .target_type = c.target_type, .operand = try c.operand.clone(allocator) };
                break :blk .{ .cast = node };
            },
            .in_list => |il| blk: {
                const node = try allocator.create(InList);
                const cloned_list = try allocator.alloc(Expr, il.list.len);
                for (il.list, 0..) |item, i| cloned_list[i] = try item.clone(allocator);
                node.* = .{
                    .operand = try il.operand.clone(allocator),
                    .list = cloned_list,
                    .negated = il.negated,
                };
                break :blk .{ .in_list = node };
            },
            .between => |b| blk: {
                const node = try allocator.create(Between);
                node.* = .{
                    .operand = try b.operand.clone(allocator),
                    .low = try b.low.clone(allocator),
                    .high = try b.high.clone(allocator),
                    .negated = b.negated,
                };
                break :blk .{ .between = node };
            },
            .is_null => |n| blk: {
                const node = try allocator.create(IsNull);
                node.* = .{ .operand = try n.operand.clone(allocator), .negated = n.negated };
                break :blk .{ .is_null = node };
            },
            .case_ => |c| blk: {
                const node = try allocator.create(Case);
                const cloned_whens = try allocator.alloc(Case.WhenClause, c.when_clauses.len);
                for (c.when_clauses, 0..) |w, i| {
                    cloned_whens[i] = .{
                        .cond = try w.cond.clone(allocator),
                        .then = try w.then.clone(allocator),
                    };
                }
                node.* = .{
                    .when_clauses = cloned_whens,
                    .else_ = if (c.else_) |e| try e.clone(allocator) else null,
                };
                break :blk .{ .case_ = node };
            },
        };
    }

    /// Recursively free the expression and all its children.
    pub fn deinit(self: Expr, allocator: std.mem.Allocator) void {
        switch (self) {
            .str_lit => |s| allocator.free(s),
            .col_ref => |n| allocator.free(n),
            .qual_col_ref => |q| {
                allocator.free(q.table);
                allocator.free(q.col);
            },
            .binary => |b| {
                b.left.deinit(allocator);
                b.right.deinit(allocator);
                allocator.destroy(b);
            },
            .unary => |u| {
                u.operand.deinit(allocator);
                allocator.destroy(u);
            },
            .func_call => |f| {
                allocator.free(f.name);
                for (f.args) |arg| arg.deinit(allocator);
                allocator.free(f.args);
                allocator.destroy(f);
            },
            .cast => |c| {
                c.operand.deinit(allocator);
                allocator.destroy(c);
            },
            .in_list => |il| {
                il.operand.deinit(allocator);
                for (il.list) |item| item.deinit(allocator);
                allocator.free(il.list);
                allocator.destroy(il);
            },
            .between => |b| {
                b.operand.deinit(allocator);
                b.low.deinit(allocator);
                b.high.deinit(allocator);
                allocator.destroy(b);
            },
            .is_null => |n| {
                n.operand.deinit(allocator);
                allocator.destroy(n);
            },
            .case_ => |c| {
                for (c.when_clauses) |w| {
                    w.cond.deinit(allocator);
                    w.then.deinit(allocator);
                }
                allocator.free(c.when_clauses);
                if (c.else_) |e| e.deinit(allocator);
                allocator.destroy(c);
            },
            else => {},
        }
    }
};

pub const SelectCol = struct {
    col: Kind,
    alias: ?[]const u8, // arena-owned; AS alias, or null if none

    pub const Kind = union(enum) {
        star,
        name: []const u8, // arena-owned: bare column name
        qual_name: QualifiedColRef, // arena-owned: table.col
        expr: Expr, // computed expression, e.g. abs(n) or n + 1
    };
};

pub const TableFunc = struct {
    schema: ?[]const u8, // arena-owned; null means default schema (main)
    name: []const u8, // arena-owned
    args: []Expr, // positional integer/string args
    alias: ?[]const u8, // arena-owned; AS alias, or null if none
};

pub const QualifiedName = struct {
    schema: ?[]const u8, // arena-owned; null means default schema (main)
    name: []const u8, // arena-owned
    alias: ?[]const u8, // arena-owned; AS alias, or null if none
};

pub const TableRef = union(enum) {
    name: QualifiedName, // plain table:  FROM users or FROM main.users
    func: TableFunc, // TVF:          FROM __page_slots(1)
};

pub const JoinType = enum { inner, cross };

// One JOIN clause: join type, right-hand table, and optional ON condition.
// CROSS JOIN (explicit or via comma syntax) has no condition; INNER JOIN always does.
pub const JoinClause = struct {
    join_type: JoinType,
    table_ref: TableRef,
    condition: ?Expr, // null for CROSS JOIN
};

pub const OrderDirection = enum { asc, desc };

pub const OrderByItem = struct {
    expr: Expr,
    direction: OrderDirection,
};

pub const SelectStmt = struct {
    distinct: bool = false, // SELECT DISTINCT removes duplicate output rows
    table_ref: ?TableRef, // null means SELECT without FROM (e.g. SELECT 1)
    joins: []JoinClause, // JOIN clauses in order (empty = no joins)
    columns: []SelectCol, // len = 0 means SELECT *
    where: ?Expr,
    group_by: []Expr = &.{}, // GROUP BY expressions; empty = no grouping
    order_by: []OrderByItem = &.{}, // ORDER BY items; empty = no ordering
};

pub const InsertStmt = struct {
    table: []const u8, // arena-owned
    columns: [][]const u8, //arena-owned
    // Each element is one row; within a row, values are positional per column.
    values: [][]Expr,
};

pub const Assignment = struct {
    column: []const u8, // arena-owned
    value: Expr,
};

pub const UpdateStmt = struct {
    table: []const u8,
    assignments: []Assignment,
    where: ?Expr,
};

pub const DeleteStmt = struct {
    table: []const u8,
    where: ?Expr,
};

pub const ColumnDef = struct {
    name: []const u8, // arena-owned
    col_type: t.ColType,
    nullable: bool, // true unless NOT NULL present

    default_expr: ?Expr,
    default_src: ?[]const u8,
};

pub const CreateTableStmt = struct {
    table: []const u8,
    columns: []ColumnDef,
};

pub const Stmt = union(enum) {
    select: SelectStmt,
    insert: InsertStmt,
    update: UpdateStmt,
    delete: DeleteStmt,
    create_table: CreateTableStmt,
    begin: void,
    commit: void,
    rollback: void,
};
