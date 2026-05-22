//! PagerDB aims to be lego-like which exposes a lot of internals.
//! However, sometimes users want quick and easy usage. ManagedDatabase
//! is opinionated and already wired up with disk pager and WAL, ready to use.

const std = @import("std");
const Db = @import("db.zig").Db;
const DiskPager = @import("pager/disk.zig").DiskPager;
const DiskIo = @import("io/disk_io.zig").DiskIo;
const InMemoryPager = @import("pager/memory.zig").InMemoryPager;
const Pager = @import("pager/pager.zig").Pager;
const WAL = @import("pager/wal.zig").WAL;
const e = @import("sql/executor.zig");

// Strip the last extension from path: "mydb.db" → "mydb", "mydb" → "mydb".
// Used to derive the WAL base path from the database file path so that all
// WAL files (segments + checkpoint) share a common prefix next to the db file.
fn stripExtension(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '.') {
            // Only strip if the dot is not the first char and not after a separator.
            if (i > 0 and path[i - 1] != '/' and path[i - 1] != '\\') {
                return alloc.dupe(u8, path[0..i]);
            }
            break;
        }
        if (path[i] == '/' or path[i] == '\\') break;
    }
    return alloc.dupe(u8, path);
}

/// A high-level database handle that manages the full lifecycle of a database.
/// This includes the pager (disk or memory), write-ahead log (WAL), and the core database engine.
/// Use `open()` to create or open a database, and `deinit()` to clean up resources.
pub const ManagedDatabase = struct {
    alloc: std.mem.Allocator,

    db: *Db,
    pager: Pager,
    disk_pager: ?*DiskPager,
    wal: ?*WAL,

    // DiskIo is heap-allocated so that Io handles (which hold a pointer into
    // it) remain valid for the lifetime of ManagedDatabase, not just for the
    // stack frame of open().
    disk_io: ?*DiskIo,

    wal_base_path: ?[]const u8 = null,
    path: ?[]const u8 = null,

    /// Open or create a database at the given path.
    /// If `path` is null, creates an in-memory database (no persistence).
    /// If `path` points to an existing database file, it will be loaded.
    /// If `path` points to a non-existing location, a new database will be created.
    ///
    /// For disk-based databases, WAL segments are created at `{base}-NNNNNN.wal`
    /// where base is the database path with its extension stripped.
    ///
    /// **Resource management:** The returned `ManagedDatabase` owns all resources.
    /// Call `deinit()` to properly release memory and close file handles.
    ///
    /// **Example:**
    /// ```zig
    /// var db = try ManagedDatabase.open(allocator, io, "mydb.db");
    /// defer db.deinit();
    /// ```
    pub fn open(alloc: std.mem.Allocator, std_io: std.Io, path: ?[]const u8) !ManagedDatabase {
        if (path) |db_path| {
            // Heap-allocate DiskIo so that Io handles derived from it stay valid
            // for the full lifetime of this ManagedDatabase, not just this frame.
            const disk_io = try alloc.create(DiskIo);
            errdefer alloc.destroy(disk_io);
            disk_io.* = DiskIo.init(alloc, std_io);
            const io = disk_io.io();

            // WAL files share the database path prefix, minus the file extension.
            // e.g. "mydb.db" → "mydb-000001.wal", "mydb.ckpt"
            const wal_base = try stripExtension(alloc, db_path);
            errdefer alloc.free(wal_base);

            const wal = try alloc.create(WAL);
            errdefer alloc.destroy(wal);

            // Try to open existing database file, or create new if not found.
            const OpenResult = struct { pager: Pager, is_new: bool };
            const result: OpenResult = blk: {
                const p = DiskPager.open(alloc, io, db_path, .{ .wal = wal }) catch |err| {
                    if (err == error.FileNotFound) {
                        // New database: create the WAL at segment 1.
                        wal.* = try WAL.create(alloc, io, wal_base);
                        break :blk .{
                            .pager = try DiskPager.create(alloc, io, db_path, .{ .wal = wal }),
                            .is_new = true,
                        };
                    }
                    return err;
                };
                // Existing database: open WAL (finds active segment via checkpoint)
                // then run recovery to replay any uncommitted records.
                wal.* = try WAL.open(alloc, io, wal_base);
                break :blk .{ .pager = p, .is_new = false };
            };

            var pager = result.pager;

            // Run WAL recovery for existing databases.  This replays any records
            // written after the last checkpoint and then rotates to a fresh segment.
            if (!result.is_new) {
                try wal.recover(&pager, alloc);
            }

            const db = if (result.is_new)
                try Db.init(result.pager, alloc)
            else
                try Db.load(result.pager, alloc);

            return ManagedDatabase{
                .db = db,
                .wal = wal,
                .pager = pager,
                .disk_pager = DiskPager.asDiskPager(&pager),
                .disk_io = disk_io,
                .path = try alloc.dupe(u8, db_path),
                .wal_base_path = wal_base,
                .alloc = alloc,
            };
        }

        // Create an in-memory database (no persistence, no WAL)
        const pager = try InMemoryPager.create(alloc);
        const db = try Db.init(pager, alloc);

        return ManagedDatabase{
            .db = db,
            .wal = null,
            .pager = pager,
            .disk_pager = null,
            .disk_io = null,
            .path = null,
            .wal_base_path = null,
            .alloc = alloc,
        };
    }

    /// Clean up all resources associated with this database.
    /// This closes the database, flushes any pending writes, deinitializes the WAL,
    /// and frees all allocated memory including path strings.
    ///
    /// **Important:** After calling `deinit()`, the `ManagedDatabase` instance
    /// should not be used again.
    pub fn deinit(self: *ManagedDatabase) void {
        self.db.close();

        if (self.wal) |wal| {
            wal.deinit();
            self.alloc.destroy(wal);
        }

        if (self.path) |p| self.alloc.free(p);
        if (self.wal_base_path) |p| self.alloc.free(p);
        if (self.disk_io) |di| self.alloc.destroy(di);
    }

    /// Execute a SQL statement against this database.
    /// Supports CREATE TABLE, INSERT, SELECT, and other SQL operations.
    ///
    /// **Note:** The returned `ExecResult` may contain allocated data (e.g., query results).
    /// The caller is responsible for freeing any result data using the provided allocator.
    ///
    /// **Example:**
    /// ```zig
    /// const result = try db.execute("SELECT * FROM users", allocator);
    /// defer e.freeExecResult(result, allocator); // Clean up result data
    /// ```
    pub fn execute(self: *ManagedDatabase, sql: []const u8, exec_alloc: std.mem.Allocator) !e.ExecResult {
        return e.execute(exec_alloc, self.db, sql);
    }
};
