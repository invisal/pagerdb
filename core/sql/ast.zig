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

pub const Expr = union(enum) {
    int_lit: i64,
    float_lit: f64,
    str_lit: []const u8, // arena-owned copy, '' already unescaped
    bool_lit: bool,
    null_lit: void,
    col_ref: []const u8, // column name, arena-owned

    // Binary and unary nodes are heap-allocated so the Expr union stays small
    // (two pointers).  This keeps stack frames shallow during deep recursion
    // in the parser, and makes moving Expr values cheap (no deep copy).
    binary: *Binary,
    unary: *Unary,

    pub const Binary = struct { op: BinaryOp, left: Expr, right: Expr };
    pub const Unary = struct { op: UnaryOp, operand: Expr };

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
        };
    }

    /// Recursively free the expression and all its children.
    pub fn deinit(self: Expr, allocator: std.mem.Allocator) void {
        switch (self) {
            .str_lit => |s| allocator.free(s),
            .col_ref => |n| allocator.free(n),
            .binary => |b| {
                b.left.deinit(allocator);
                b.right.deinit(allocator);
                allocator.destroy(b);
            },
            .unary => |u| {
                u.operand.deinit(allocator);
                allocator.destroy(u);
            },
            else => {},
        }
    }
};

pub const SelectCol = union(enum) {
    star,
    name: []const u8, // arena-owned
};

pub const TableFunc = struct {
    schema: ?[]const u8, // arena-owned; null means default schema (main)
    name: []const u8, // arena-owned
    args: []Expr, // positional integer/string args
};

pub const QualifiedName = struct {
    schema: ?[]const u8, // arena-owned; null means default schema (main)
    name: []const u8, // arena-owned
};

pub const TableRef = union(enum) {
    name: QualifiedName, // plain table:  FROM users or FROM main.users
    func: TableFunc, // TVF:          FROM __page_slots(1)
};

pub const SelectStmt = struct {
    table_ref: TableRef, // arena-owned
    columns: []SelectCol, // len = 0 means SELECT *
    where: ?Expr,
};

pub const InsertStmt = struct {
    table: []const u8, // arena-owned
    columns: [][]const u8, //arena-owned
    values: []Expr, // positional, one per column
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
};
