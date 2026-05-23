// Minimal IO interface exposing only what this database actually uses.
//
// Having our own thin interface rather than std.Io directly lets us swap in
// SimIo for deterministic simulation tests without changing any production
// code paths.  The two concrete implementations are:
//
//   DiskIo  — wraps std.Io for real filesystem access
//   SimIo   — in-memory filesystem with crash simulation and fault injection
//
// File is self-contained (its vtable handles everything), so callers no
// longer need to carry a separate Io handle once a file is open.

// A handle to an open file.  The vtable is implementation-specific;
// DiskFile delegates to std.Io.File, SimFile operates on an ArrayList.
pub const File = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Reads up to buf.len bytes from the file at byte offset, returns
        // the number of bytes actually read (may be less at EOF).
        readAt: *const fn (*anyopaque, []u8, u64) anyerror!usize,
        // Writes all of buf to the file at byte offset.  Extends the file
        // with zeros if offset is past the current end.
        writeAt: *const fn (*anyopaque, []const u8, u64) anyerror!void,
        // Flush and persist all previous writes (equivalent to fsync).
        sync: *const fn (*anyopaque) anyerror!void,
        // Return the current size of the file in bytes.
        length: *const fn (*anyopaque) anyerror!u64,
        // Truncate or extend the file to exactly len bytes.
        setLength: *const fn (*anyopaque, u64) anyerror!void,
        // Release the file handle.  For DiskIo this closes the OS fd and
        // frees the DiskFile allocation; for SimIo this is a no-op because
        // SimFiles are owned by SimIo and survive individual close calls.
        close: *const fn (*anyopaque) void,
    };

    pub fn readAt(self: File, buf: []u8, offset: u64) !usize {
        return self.vtable.readAt(self.ptr, buf, offset);
    }

    pub fn writeAt(self: File, buf: []const u8, offset: u64) !void {
        return self.vtable.writeAt(self.ptr, buf, offset);
    }

    pub fn sync(self: File) !void {
        return self.vtable.sync(self.ptr);
    }

    pub fn length(self: File) !u64 {
        return self.vtable.length(self.ptr);
    }

    pub fn setLength(self: File, len: u64) !void {
        return self.vtable.setLength(self.ptr, len);
    }

    pub fn close(self: File) void {
        self.vtable.close(self.ptr);
    }
};

// IO manages the filesystem namespace: creating, opening, and deleting files.
// File-level operations (read, write, sync, …) go through the File handle
// returned by createFile / openFile, not through Io itself.
pub const Io = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Create a new file at path, truncating if it already exists.
        // The returned file is open for both reading and writing.
        createFile: *const fn (*anyopaque, []const u8) anyerror!File,
        // Open an existing file for reading and writing.
        // Returns error.FileNotFound if the file does not exist.
        openFile: *const fn (*anyopaque, []const u8) anyerror!File,
        // Delete the file at path.  Silently succeeds if the file does not exist.
        deleteFile: *const fn (*anyopaque, []const u8) anyerror!void,
        // Atomically rename old_path to new_path.  On POSIX this is rename(2),
        // which replaces new_path if it already exists.
        renameFile: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
        // Return the current wall-clock time as microseconds since Unix epoch.
        // SimIo may return a monotonically advancing counter instead of real
        // wall time so that tests remain deterministic.
        nowMicros: *const fn (*anyopaque) u64,
    };

    pub fn createFile(self: Io, path: []const u8) !File {
        return self.vtable.createFile(self.ptr, path);
    }

    pub fn openFile(self: Io, path: []const u8) !File {
        return self.vtable.openFile(self.ptr, path);
    }

    pub fn deleteFile(self: Io, path: []const u8) !void {
        return self.vtable.deleteFile(self.ptr, path);
    }

    pub fn renameFile(self: Io, old_path: []const u8, new_path: []const u8) !void {
        return self.vtable.renameFile(self.ptr, old_path, new_path);
    }

    pub fn nowMicros(self: Io) u64 {
        return self.vtable.nowMicros(self.ptr);
    }
};
