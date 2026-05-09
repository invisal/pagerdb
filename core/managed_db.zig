//! PagerDB aims to be lego-like which exposes a lot of internals.
//! However, sometimes users want quick and easy usage. ManagedDatabase
//! is opinionated and already wired up with disk pager and WAL, ready to use.

const std = @import("std");
const Db = @import("db.zig").Db;
const DiskPager = @import("pager/disk.zig").DiskPager;
const InMemoryPager = @import("pager/memory.zig").InMemoryPager;
const Pager = @import("pager/pager.zig").Pager;
const WAL = @import("pager/wal.zig").WAL;
const e = @import("sql/executor.zig");

/// A high-level database handle that manages the full lifecycle of a database.
/// This includes the pager (disk or memory), write-ahead log (WAL), and the core database engine.
/// Use `open()` to create or open a database, and `deinit()` to clean up resources.
pub const ManagedDatabase = struct {
    alloc: std.mem.Allocator,

    db: *Db,
    pager: Pager,
    disk_pager: ?*DiskPager,
    wal: ?*WAL,

    wal_path: ?[]const u8 = undefined,
    path: ?[]const u8 = undefined,

    /// Open or create a database at the given path.
    /// If `path` is null, creates an in-memory database (no persistence).
    /// If `path` points to an existing database file, it will be loaded.
    /// If `path` points to a non-existing location, a new database will be created.
    ///
    /// For disk-based databases, a WAL file is created at `{path}.wal` for durability.
    ///
    /// **Resource management:** The returned `ManagedDatabase` owns all resources.
    /// Call `deinit()` to properly release memory and close file handles.
    ///
    /// **Example:**
    /// ```zig
    /// var db = try ManagedDatabase.open(io, allocator, "mydb.db");
    /// defer db.deinit();
    /// ```
    pub fn open(io: std.Io, alloc: std.mem.Allocator, path: ?[]const u8) !ManagedDatabase {
        if (path) |db_path| {
            // Construct WAL path by appending ".wal" to the database path
            const wal_path = try std.mem.concat(alloc, u8, &.{ db_path, ".wal" });

            // Initialize the WAL for durability
            const wal = try alloc.create(WAL);
            wal.* = try WAL.open(io, wal_path, alloc);
            errdefer alloc.destroy(wal);

            // Try to open existing database file, or create new if not found.
            // Returns both the pager and a flag indicating if it's newly created.
            const OpenResult = struct { pager: Pager, is_new: bool };
            const result: OpenResult = blk: {
                const p = DiskPager.open(alloc, io, db_path, .{ .wal = wal }) catch |err| {
                    if (err == error.FileNotFound) {
                        break :blk .{
                            .pager = try DiskPager.create(alloc, io, db_path, .{}),
                            .is_new = true,
                        };
                    }
                    return err;
                };
                break :blk .{ .pager = p, .is_new = false };
            };

            // Initialize or load the database depending on whether it's new
            const db = if (result.is_new)
                try Db.init(result.pager, alloc)
            else
                try Db.load(result.pager, alloc);
            var pager = result.pager;

            return ManagedDatabase{
                .db = db,
                .wal = wal,
                .pager = pager,
                .disk_pager = DiskPager.asDiskPager(&pager),
                .path = try alloc.dupe(u8, db_path),
                .wal_path = wal_path,
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
            .path = null,
            .wal_path = null,
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
        // Close the core database engine (flushes metadata, etc.)
        self.db.close();

        // Clean up WAL resources (if disk-based database)
        if (self.wal) |wal| {
            wal.deinit();
            self.alloc.destroy(wal);
        }

        // Free path strings
        if (self.wal_path) |wal_path| self.alloc.free(wal_path);
        if (self.path) |path| self.alloc.free(path);
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
    pub fn execute(self: *ManagedDatabase, sql: []const u8, alloc: std.mem.Allocator) !e.ExecResult {
        return e.execute(self.db, sql, alloc);
    }
};
