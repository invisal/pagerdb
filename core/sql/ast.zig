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
