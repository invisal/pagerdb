const std = @import("std");
const core = @import("core");

const Database = core.Database;
const DiskPager = core.DiskPager;
const DiskIo = core.DiskIo;
const execute = core.execute;
const btree = core.btree;

pub const Error = error{
    TableMissingColumns,
    RowCountMismatch,
    TableNotFound,
};

// Verify that every table in the catalog has at least one column defined.
pub fn checkCatalog(db: *Database) !void {
    var it = db.cat.tables.valueIterator();
    while (it.next()) |meta| {
        if (meta.columns.len == 0) {
            std.debug.print("  [checker] table '{s}' has no columns in catalog\n", .{meta.name});
            return Error.TableMissingColumns;
        }
    }
}

// Walk the B-tree for table_name and verify structural invariants using a
// fresh Pager that has an empty buffer pool, so every page is read from disk.
// This avoids false negatives that could occur if the cached pager hides an
// inconsistency between in-memory and on-disk state.
pub fn checkBTreeStructure(alloc: std.mem.Allocator, io: std.Io, db: *Database, path: []const u8, table_name: []const u8) !void {
    const meta = db.cat.tables.get(table_name) orelse return Error.TableNotFound;
    var disk_io = DiskIo.init(alloc, io);
    var disk_pager = try DiskPager.open(alloc, disk_io.io(), path, .{});
    defer disk_pager.close();
    btree.RowidBTree.verifyTree(&disk_pager, meta.btree_root) catch |err| {
        std.debug.print(
            "  [checker] B-tree structure violation in '{s}': {s}\n",
            .{ table_name, @errorName(err) },
        );
        return err;
    };
}

// Run SELECT * on table_name and verify the row count matches expected.
pub fn checkRowCount(
    db: *Database,
    table_name: []const u8,
    expected: usize,
    alloc: std.mem.Allocator,
) !void {
    var sql_buf: [256]u8 = undefined;
    const sql = try std.fmt.bufPrint(&sql_buf, "SELECT * FROM {s}", .{table_name});

    var er = try execute(alloc, db, sql);
    defer er.result_set.deinit();

    const got = er.result_set.rows.len;
    if (got != expected) {
        std.debug.print(
            "  [checker] row count mismatch: expected {d}, got {d}\n",
            .{ expected, got },
        );
        return Error.RowCountMismatch;
    }
}
