// Shared test helpers for all core test suites.
//
// Usage (most tests — no disk):
//   const h = try makeMemoryDb(alloc, .{ .schema = &.{"CREATE TABLE t (x INT)"} });
//   defer h.deinit();
//
// Usage (persistence tests — disk, auto-deleted on deinit):
//   const h = try makeDiskDb(alloc, io, "/tmp/test.db", .{});
//   defer h.deinit(); // closes db and deletes the file
//
// Usage (reopen tests — two sessions, one file):
//   const h1 = try makeDiskDb(alloc, io, path, .{});
//   h1.db.close();         // end session 1; file survives
//   const h2 = try loadDiskDb(alloc, io, path);
//   defer h2.deinit();     // end session 2; file deleted

const std = @import("std");
const DiskPager = @import("pager/disk.zig").DiskPager;
const DiskIo = @import("io/disk_io.zig").DiskIo;
const InMemoryPager = @import("pager/memory.zig").InMemoryPager;
const Db = @import("db.zig").Db;
const execute = @import("sql/executor.zig").execute;

/// Execute SQL and discard the result. Use for setup statements
/// (CREATE TABLE, INSERT, BEGIN/COMMIT) where the return value is irrelevant.
pub fn exec(db: *Db, sql: []const u8, alloc: std.mem.Allocator) !void {
    var r = try execute(db, sql, alloc);
    r.deinit();
}

pub const DbOptions = struct {
    /// SQL statements to execute immediately after the database is created.
    schema: []const []const u8 = &.{},
};

// ── In-memory handle ──────────────────────────────────────────────────────────

pub const DbHandle = struct {
    db: *Db,

    /// Close the database and free all memory.
    pub fn deinit(self: DbHandle) void {
        self.db.close();
    }
};

/// Create a Db backed by InMemoryPager. No disk I/O, no path, no file to clean up.
/// Use for the vast majority of tests.
pub fn makeMemoryDb(alloc: std.mem.Allocator, opts: DbOptions) !DbHandle {
    const db = try Db.init(try InMemoryPager.create(alloc), alloc);
    errdefer db.close();
    for (opts.schema) |sql| try exec(db, sql, alloc);
    return .{ .db = db };
}

// ── Disk handle ───────────────────────────────────────────────────────────────

pub const DiskDbHandle = struct {
    db: *Db,
    io: std.Io,
    path: []const u8,

    /// Close the database and delete the file.
    pub fn deinit(self: DiskDbHandle) void {
        self.db.close();
        std.Io.Dir.deleteFile(.cwd(), self.io, self.path) catch {};
    }
};

/// Create a fresh Db backed by a DiskPager. deinit() closes the db and deletes
/// the file, so no separate defer Dir.deleteFile(...) is needed.
///
/// For reopen tests where the file must survive between sessions, close just the
/// database with h.db.close() and let the final loadDiskDb handle delete the file.
pub fn makeDiskDb(alloc: std.mem.Allocator, io: std.Io, path: []const u8, opts: DbOptions) !DiskDbHandle {
    var disk_io = DiskIo.init(alloc, io);
    const db = try Db.init(try DiskPager.create(alloc, disk_io.io(), path, .{}), alloc);
    errdefer db.close();
    for (opts.schema) |sql| try exec(db, sql, alloc);
    return .{ .db = db, .io = io, .path = path };
}

/// Open an existing database file. Pairs with makeDiskDb for reopen tests.
/// deinit() closes the db and deletes the file.
pub fn loadDiskDb(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !DiskDbHandle {
    var disk_io = DiskIo.init(alloc, io);
    return .{
        .db = try Db.load(try DiskPager.open(alloc, disk_io.io(), path, .{}), alloc),
        .io = io,
        .path = path,
    };
}
