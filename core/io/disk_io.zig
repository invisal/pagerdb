// DiskIo — real filesystem implementation of the Io interface.
//
// Each file opened or created through DiskIo is represented by a heap-
// allocated DiskFile that wraps std.Io.File.  Heap allocation keeps the
// pointer address stable for the File.ptr vtable field even when the caller
// moves the returned File value.
//
// The DiskIo itself only needs to exist long enough to open or create files.
// Once a File handle is returned, all subsequent operations go through the
// File vtable and do not touch DiskIo.

const std = @import("std");
const Io = @import("io.zig").Io;
const File = @import("io.zig").File;

// DiskFile is heap-allocated by DiskIo.createFile / DiskIo.openFile.
// close() closes the underlying OS file descriptor and frees this allocation.
const DiskFile = struct {
    file: std.Io.File,
    std_io: std.Io,
    alloc: std.mem.Allocator,

    const vtable = File.VTable{
        .readAt = readAt,
        .writeAt = writeAt,
        .sync = sync,
        .length = length,
        .setLength = setLength,
        .close = close,
    };

    fn readAt(ptr: *anyopaque, buf: []u8, offset: u64) anyerror!usize {
        const self: *DiskFile = @ptrCast(@alignCast(ptr));
        return self.file.readPositionalAll(self.std_io, buf, offset);
    }

    fn writeAt(ptr: *anyopaque, buf: []const u8, offset: u64) anyerror!void {
        const self: *DiskFile = @ptrCast(@alignCast(ptr));
        try self.file.writePositionalAll(self.std_io, buf, offset);
    }

    fn sync(ptr: *anyopaque) anyerror!void {
        const self: *DiskFile = @ptrCast(@alignCast(ptr));
        try self.file.sync(self.std_io);
    }

    fn length(ptr: *anyopaque) anyerror!u64 {
        const self: *DiskFile = @ptrCast(@alignCast(ptr));
        return self.file.length(self.std_io);
    }

    fn setLength(ptr: *anyopaque, len: u64) anyerror!void {
        const self: *DiskFile = @ptrCast(@alignCast(ptr));
        try self.file.setLength(self.std_io, len);
    }

    fn close(ptr: *anyopaque) void {
        const self: *DiskFile = @ptrCast(@alignCast(ptr));
        const alloc = self.alloc;
        self.file.close(self.std_io);
        alloc.destroy(self);
    }
};

pub const DiskIo = struct {
    std_io: std.Io,
    alloc: std.mem.Allocator,

    const vtable = Io.VTable{
        .createFile = createFile,
        .openFile = openFile,
        .deleteFile = deleteFile,
    };

    pub fn init(alloc: std.mem.Allocator, std_io: std.Io) DiskIo {
        return .{ .std_io = std_io, .alloc = alloc };
    }

    // Returns an Io handle backed by this DiskIo.  The returned Io.ptr points
    // into self, so this must only be used while self is still in scope.
    // After files are opened, the resulting File handles are independent.
    pub fn io(self: *DiskIo) Io {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn createFile(ptr: *anyopaque, path: []const u8) anyerror!File {
        const self: *DiskIo = @ptrCast(@alignCast(ptr));
        const std_file = try std.Io.Dir.cwd().createFile(self.std_io, path, .{ .read = true });
        errdefer std_file.close(self.std_io);
        const disk_file = try self.alloc.create(DiskFile);
        disk_file.* = .{ .file = std_file, .std_io = self.std_io, .alloc = self.alloc };
        return File{ .ptr = disk_file, .vtable = &DiskFile.vtable };
    }

    fn openFile(ptr: *anyopaque, path: []const u8) anyerror!File {
        const self: *DiskIo = @ptrCast(@alignCast(ptr));
        const std_file = try std.Io.Dir.cwd().openFile(self.std_io, path, .{ .mode = .read_write });
        errdefer std_file.close(self.std_io);
        const disk_file = try self.alloc.create(DiskFile);
        disk_file.* = .{ .file = std_file, .std_io = self.std_io, .alloc = self.alloc };
        return File{ .ptr = disk_file, .vtable = &DiskFile.vtable };
    }

    fn deleteFile(ptr: *anyopaque, path: []const u8) anyerror!void {
        const self: *DiskIo = @ptrCast(@alignCast(ptr));
        try std.Io.Dir.deleteFile(.cwd(), self.std_io, path);
    }
};
