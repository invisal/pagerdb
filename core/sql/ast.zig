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

    // Binary, unary, and func_call nodes are heap-allocated so the Expr union
    // stays small (two pointers).  This keeps stack frames shallow during deep
    // recursion in the parser, and makes moving Expr values cheap (no deep copy).
    binary: *Binary,
    unary: *Unary,
    func_call: *FuncCall,

    pub const Binary = struct { op: BinaryOp, left: Expr, right: Expr };
    pub const Unary = struct { op: UnaryOp, operand: Expr };
    pub const FuncCall = struct { name: []const u8, args: []Expr };

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
                };
                break :blk .{ .func_call = node };
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

// One INNER JOIN clause: the right-hand table and its ON condition.
pub const JoinClause = struct {
    table_ref: TableRef, // right-hand table
    condition: Expr, // ON predicate
};

pub const SelectStmt = struct {
    table_ref: ?TableRef, // null means SELECT without FROM (e.g. SELECT 1)
    joins: []JoinClause, // INNER JOIN clauses in order (empty = no joins)
    columns: []SelectCol, // len = 0 means SELECT *
    where: ?Expr,
    group_by: []Expr = &.{}, // GROUP BY expressions; empty = no grouping
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
