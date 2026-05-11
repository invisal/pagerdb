// WASM-safe public API subset for pagerdb.
//
// Excludes disk I/O components (DiskPager, WAL, ManagedDatabase) that cannot
// compile for wasm32-freestanding. Imported by the wasm/ binding via a named
// module so that wasm/ does not need to know about core's internal layout.
pub const Database = @import("db.zig").Db;
pub const Pager = @import("pager/pager.zig").Pager;
pub const InMemoryPager = @import("pager/memory.zig").InMemoryPager;
pub const execute = @import("sql/executor.zig").execute;
pub const ExecResult = @import("sql/executor.zig").ExecResult;
pub const FormattedError = @import("sql/executor.zig").FormattedError;
pub const ResultSet = @import("sql/executor.zig").ResultSet;
pub const Row = @import("sql/executor.zig").Row;
pub const Value = @import("row.zig").Value;
