// Physical (executable) expression type.
//
// Sits between logical planning and execution: column references have been
// resolved to positional indices, scalar functions to registry pointers, and
// scalar subqueries to executable inner plans with a function-pointer executor.
//
// Kept in its own file so eval.zig, physical_plan.zig, and cursor/root.zig can
// all import it without creating circular dependencies.

const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");
const t = @import("../types.zig"); // ColType lives in core/types.zig, not core/sql/types.zig
const sf = @import("scalar_func.zig");
const agg_mod = @import("cursor/agg_func.zig");
const row = @import("../row.zig");

pub const EvalValue = types.EvalValue;

// Callback that executes a scalar subquery and returns the first column of the
// first result row.  Both inner (*PhysicalPlan) and db (*Db) are passed as
// *anyopaque to keep this file free of imports from physical_plan.zig/db.zig,
// which would create circular dependencies.
pub const SubqueryExecFn = *const fn (
    inner: *anyopaque,
    db: *anyopaque,
    outer: []const row.Value,
    alloc: std.mem.Allocator,
) anyerror!?EvalValue;

pub const ExecExpr = union(enum) {
    int_lit: i64,
    float_lit: f64,
    str_lit: []const u8, // arena-owned
    bool_lit: bool,
    null_lit: void,
    col_idx: usize, // index into the current inner row
    outer_col_idx: usize, // index into the outer row (correlated subquery ref)
    binary: *Binary,
    unary: *Unary,
    func_call: *FuncCall,
    cast: *Cast,
    in_list: *InList,
    case_: *Case,
    is_null: *IsNull,
    subquery: *Subquery,

    pub const Binary = struct { op: ast.BinaryOp, left: ExecExpr, right: ExecExpr };
    pub const Unary = struct { op: ast.UnaryOp, operand: ExecExpr };
    pub const FuncCall = struct { func: *const sf.ScalarFunc, args: []ExecExpr };
    pub const Cast = struct { target_type: t.ColType, operand: ExecExpr };
    pub const InList = struct { operand: ExecExpr, list: []ExecExpr, negated: bool };
    pub const Case = struct {
        pub const WhenClause = struct { cond: ExecExpr, then: ExecExpr };
        when_clauses: []WhenClause,
        else_: ?ExecExpr,
    };
    pub const IsNull = struct { operand: ExecExpr, negated: bool };
    // Scalar subquery: executes an inner plan and returns the first column of
    // the first result row.  inner and db are opaque pointers; exec_fn knows
    // their concrete types and casts them internally.
    pub const Subquery = struct {
        inner: *anyopaque, // *PhysicalPlan, heap-allocated by physical planner
        db: *anyopaque, // *Db
        exec_fn: SubqueryExecFn,
    };
};

// Physical aggregate call spec: mirrors lp.AggCallSpec but uses ExecExpr.
pub const ExecAggCallSpec = struct {
    func: *const agg_mod.AggFunc,
    input_expr: ?ExecExpr, // null = COUNT(*) / no-arg agg
    distinct: bool = false,
};

// Physical sort key: mirrors lp.SortKey but uses ExecExpr.
pub const ExecSortKey = struct {
    expr: ExecExpr,
    descending: bool,
};

// Physical UPDATE assignment: mirrors lp.LogicalUpdate.Assignment but uses ExecExpr.
pub const ExecAssignment = struct {
    col_idx: usize,
    value: ExecExpr,
};
