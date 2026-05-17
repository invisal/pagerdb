// Logical query planner: transforms SQL AST into a logical plan.
// The logical plan is a tree of operations independent of physical execution.

const root = @import("logical_plan/root.zig");

const ast = @import("ast.zig");

// Re-export all public items from root.zig
pub const JoinType = ast.JoinType;
pub const SchemaCol = root.SchemaCol;
pub const Schema = root.Schema;
pub const Expr = root.Expr;
pub const SeqScan = root.SeqScan;
pub const VTabScan = root.VTabScan;
pub const Filter = root.Filter;
pub const Project = root.Project;
pub const Aggregate = root.Aggregate;
pub const AggCallSpec = root.AggCallSpec;
pub const SortKey = root.SortKey;
pub const Sort = root.Sort;
pub const Distinct = root.Distinct;
pub const Join = root.Join;
pub const LogicalInsert = root.LogicalInsert;
pub const LogicalInsertSelect = root.LogicalInsertSelect;
pub const LogicalUpdate = root.LogicalUpdate;
pub const LogicalDelete = root.LogicalDelete;
pub const LogicalCreateTable = root.LogicalCreateTable;
pub const LogicalPlan = root.LogicalPlan;
pub const LogicalPlanner = root.LogicalPlanner;
pub const PlanError = root.PlanError;

test {
    _ = @import("logical_plan/select_test.zig");
    _ = @import("logical_plan/insert_test.zig");
    _ = @import("logical_plan/update_test.zig");
    _ = @import("logical_plan/delete_test.zig");
    _ = @import("logical_plan/create_table_test.zig");
    _ = @import("logical_plan/error_test.zig");
}
