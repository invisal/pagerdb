// SimIo — in-memory filesystem for deterministic simulation testing.
//
// SimFiles model crash safety by separating durable state (what has been
// sync()'d) from pending state (writes since the last sync).  Calling
// SimIo.crash() reverts every file's pending state to its last durable
// snapshot, mimicking an abrupt power loss where the OS page cache is
// discarded.
//
// Fault injection is per-file and path-targeted: setFaultAfterWrites arms a
// counter on a specific file so that the Nth writeAt call to that file
// returns error.SimulatedFault.  Writes to other files proceed normally.
// This matches the existing DiskPager fault model (which only counts page
// writes to the data file, not WAL writes).

const std = @import("std");
const Io = @import("io.zig").Io;
const File = @import("io.zig").File;

const SimFile = struct {
    // The path string is owned by this struct (duped from the caller).
    path: []const u8,
    // Last sync()'d content — this is what survives a crash().
    durable: std.ArrayListUnmanaged(u8),
    // Current content — includes un-sync()'d writes, lost on crash().
    pending: std.ArrayListUnmanaged(u8),
    // Back-reference for fault injection counter and allocator access.
    sim: *SimIo,

    const vtable = File.VTable{
        .readAt = readAt,
        .writeAt = writeAt,
        .sync = sync,
        .length = length,
        .setLength = setLength,
        .close = close,
    };

    fn readAt(ptr: *anyopaque, buf: []u8, offset: u64) anyerror!usize {
        const self: *SimFile = @ptrCast(@alignCast(ptr));
        const data = self.pending.items;
        if (offset >= data.len) return 0;
        const off: usize = @intCast(offset);
        const n = @min(buf.len, data.len - off);
        @memcpy(buf[0..n], data[off..][0..n]);
        return n;
    }

    fn writeAt(ptr: *anyopaque, buf: []const u8, offset: u64) anyerror!void {
        const self: *SimFile = @ptrCast(@alignCast(ptr));

        // Fault injection: only counts writes to the targeted file.
        if (self.sim.fault_path) |fp| {
            if (std.mem.eql(u8, fp, self.path)) {
                if (self.sim.fault_after_writes) |limit| {
                    const n = self.sim.write_count;
                    self.sim.write_count = n + 1;
                    if (n >= limit) return error.SimulatedFault;
                }
            }
        }

        const end: usize = @intCast(offset + buf.len);
        // Extend with zeros if the write reaches past the current end.
        if (end > self.pending.items.len) {
            try self.pending.resize(self.sim.alloc, end);
        }
        const off: usize = @intCast(offset);
        @memcpy(self.pending.items[off..][0..buf.len], buf);
    }

    fn sync(ptr: *anyopaque) anyerror!void {
        const self: *SimFile = @ptrCast(@alignCast(ptr));
        // Promote pending → durable.
        try self.durable.resize(self.sim.alloc, self.pending.items.len);
        @memcpy(self.durable.items, self.pending.items);
    }

    fn length(ptr: *anyopaque) anyerror!u64 {
        const self: *SimFile = @ptrCast(@alignCast(ptr));
        return @intCast(self.pending.items.len);
    }

    fn setLength(ptr: *anyopaque, len: u64) anyerror!void {
        const self: *SimFile = @ptrCast(@alignCast(ptr));
        const sz: usize = @intCast(len);
        try self.pending.resize(self.sim.alloc, sz);
        // Truncation is treated as immediately durable so that crash() does
        // not restore content that was explicitly deleted.
        if (sz < self.durable.items.len) {
            try self.durable.resize(self.sim.alloc, sz);
        }
    }

    // SimFiles are owned by SimIo and live until SimIo.deinit().
    // Calling close() on a SimFile handle is intentionally a no-op so that
    // the in-memory file survives across open/close cycles — just like a real
    // file on disk would survive between process restarts.
    fn close(_: *anyopaque) void {}
};

pub const SimIo = struct {
    alloc: std.mem.Allocator,
    // Maps path → SimFile.  Keys are the path slices owned by each SimFile.
    files: std.StringHashMap(*SimFile),

    // Fault injection target.  Only writeAt calls to fault_path count.
    fault_path: ?[]const u8 = null,
    fault_after_writes: ?u32 = null,
    write_count: u32 = 0,

    // Monotonically advancing counter used as the simulated wall clock.
    // Increments by 1 microsecond per call so tests see distinct timestamps
    // without depending on real wall time.
    sim_time_us: u64 = 0,

    const vtable = Io.VTable{
        .createFile = createFile,
        .openFile = openFile,
        .deleteFile = deleteFile,
        .renameFile = renameFile,
        .nowMicros = nowMicros,
    };

    pub fn init(alloc: std.mem.Allocator) SimIo {
        return .{
            .alloc = alloc,
            .files = std.StringHashMap(*SimFile).init(alloc),
        };
    }

    pub fn deinit(self: *SimIo) void {
        var it = self.files.valueIterator();
        while (it.next()) |sf_ptr| {
            const sf = sf_ptr.*;
            sf.durable.deinit(self.alloc);
            sf.pending.deinit(self.alloc);
            self.alloc.free(sf.path);
            self.alloc.destroy(sf);
        }
        self.files.deinit();
    }

    // Returns an Io handle backed by this SimIo.
    pub fn io(self: *SimIo) Io {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // Revert every file's pending state to its last sync()'d snapshot.
    // This models an abrupt process crash: writes that were not yet sync()'d
    // to durable storage are lost, just as they would be after a power cut.
    pub fn crash(self: *SimIo) void {
        var it = self.files.valueIterator();
        while (it.next()) |sf_ptr| {
            const sf = sf_ptr.*;
            sf.pending.clearRetainingCapacity();
            // appendSlice cannot fail here: we are shrinking (durable ≤ pending).
            sf.pending.appendSlice(self.alloc, sf.durable.items) catch unreachable;
        }
    }

    // Arm fault injection: after n successful writeAt calls to path, the
    // next writeAt returns error.SimulatedFault.
    // Pass n=0 to fail on the very first write.
    pub fn setFaultAfterWrites(self: *SimIo, path: []const u8, n: u32) void {
        self.fault_path = path;
        self.fault_after_writes = n;
        self.write_count = 0;
    }

    pub fn resetFault(self: *SimIo) void {
        self.fault_path = null;
        self.fault_after_writes = null;
        self.write_count = 0;
    }

    fn getOrCreate(self: *SimIo, path: []const u8) !*SimFile {
        if (self.files.get(path)) |sf| return sf;
        const path_copy = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(path_copy);
        const sf = try self.alloc.create(SimFile);
        sf.* = .{
            .path = path_copy,
            .durable = .empty,
            .pending = .empty,
            .sim = self,
        };
        try self.files.put(path_copy, sf);
        return sf;
    }

    fn createFile(ptr: *anyopaque, path: []const u8) anyerror!File {
        const self: *SimIo = @ptrCast(@alignCast(ptr));
        const sf = try self.getOrCreate(path);
        // Truncate to empty, mirroring O_CREAT|O_TRUNC semantics.
        sf.pending.clearRetainingCapacity();
        sf.durable.clearRetainingCapacity();
        return File{ .ptr = sf, .vtable = &SimFile.vtable };
    }

    fn openFile(ptr: *anyopaque, path: []const u8) anyerror!File {
        const self: *SimIo = @ptrCast(@alignCast(ptr));
        const sf = self.files.get(path) orelse return error.FileNotFound;
        return File{ .ptr = sf, .vtable = &SimFile.vtable };
    }

    fn deleteFile(ptr: *anyopaque, path: []const u8) anyerror!void {
        const self: *SimIo = @ptrCast(@alignCast(ptr));
        if (self.files.fetchRemove(path)) |entry| {
            const sf = entry.value;
            sf.durable.deinit(self.alloc);
            sf.pending.deinit(self.alloc);
            self.alloc.free(sf.path);
            self.alloc.destroy(sf);
        }
    }

    fn renameFile(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void {
        const self: *SimIo = @ptrCast(@alignCast(ptr));
        const entry = self.files.fetchRemove(old_path) orelse return error.FileNotFound;
        const sf = entry.value;
        self.alloc.free(sf.path);
        sf.path = try self.alloc.dupe(u8, new_path);
        try self.files.put(sf.path, sf);
    }

    fn nowMicros(ptr: *anyopaque) u64 {
        const self: *SimIo = @ptrCast(@alignCast(ptr));
        self.sim_time_us += 1;
        return self.sim_time_us;
    }
};
