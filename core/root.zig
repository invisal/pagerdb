// Public API surface for the pagerdb library.
pub const PAGE_SIZE = @import("types.zig").PAGE_SIZE;
pub const Database = @import("db.zig").Db;
pub const ManagedDatabase = @import("managed_db.zig").ManagedDatabase;
pub const Pager = @import("pager/pager.zig").Pager;
pub const DiskPager = @import("pager/disk.zig").DiskPager;
pub const InMemoryPager = @import("pager/memory.zig").InMemoryPager;
pub const execute = @import("sql/executor.zig").execute;
pub const ExecResult = @import("sql/executor.zig").ExecResult;
pub const ResultSet = @import("sql/executor.zig").ResultSet;
pub const Row = @import("sql/executor.zig").Row;
pub const row = @import("row.zig");
pub const catalog = @import("catalog.zig");
pub const btree = @import("btree_shared.zig");
pub const WAL = @import("pager/wal.zig").WAL;
pub const walSegmentPath = @import("pager/wal.zig").segmentPath;
pub const Io = @import("io/io.zig").Io;
pub const File = @import("io/io.zig").File;
pub const DiskIo = @import("io/disk_io.zig").DiskIo;
pub const SimIo = @import("io/sim_io.zig").SimIo;

// Debug utilities for printing query results.
// Usage: PagerDB.debug.print(result);
pub const debug = @import("debug.zig");

test {
    _ = @import("pager/disk.zig");
    _ = @import("pager/memory.zig");
    _ = @import("page0.zig");
    _ = @import("row.zig");
    _ = @import("btree_shared.zig");
    _ = @import("overflow.zig");
    _ = @import("sql/lexer.zig");
    _ = @import("sql/eval.zig");
    _ = @import("sql/physical_plan.zig");
    _ = @import("sql/logical_plan.zig"); // includes all logical_plan tests
    _ = @import("sql/cursor/root.zig");
    _ = @import("sql/cursor/agg_test.zig");
    _ = @import("tests/recovery_test.zig");
    _ = @import("tests/btree_test.zig");
    _ = @import("tests/catalog_test.zig");
    _ = @import("tests/db_test.zig");
    _ = @import("tests/sql/root.zig");
    _ = @import("tests/parser_test.zig");
    _ = @import("tests/wal_test.zig");
}
