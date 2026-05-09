// Public API surface for the pagerdb library.
pub const Database = @import("db.zig").Db;
pub const Pager = @import("pager/pager.zig").Pager;
pub const DiskPager = @import("pager/disk.zig").DiskPager;
pub const InMemoryPager = @import("pager/memory.zig").InMemoryPager;
pub const execute = @import("sql/executor.zig").execute;
pub const ExecResult = @import("sql/executor.zig").ExecResult;
pub const ResultSet = @import("sql/executor.zig").ResultSet;
pub const Row = @import("sql/executor.zig").Row;
pub const row = @import("row.zig");
pub const catalog = @import("catalog.zig");
pub const btree = @import("btree.zig");

// Debug utilities for printing query results.
// Usage: PagerDB.debug.print(result);
pub const debug = @import("debug.zig");

test {
    _ = @import("pager/disk.zig");
    _ = @import("pager/memory.zig");
    _ = @import("page0.zig");
    _ = @import("row.zig");
    _ = @import("btree.zig");
    _ = @import("overflow.zig");
    _ = @import("sql/lexer.zig");
    _ = @import("sql/eval.zig");
    _ = @import("sql/physical_plan.zig");
    _ = @import("sql/logical_plan.zig"); // includes all logical_plan tests
    _ = @import("sql/cursor.zig");
    _ = @import("recovery.zig");
    _ = @import("tests/recovery_test.zig");
    _ = @import("tests/btree_test.zig");
    _ = @import("tests/catalog_test.zig");
    _ = @import("tests/db_test.zig");
    _ = @import("tests/sql/root.zig");
    _ = @import("tests/parser_test.zig");
}
