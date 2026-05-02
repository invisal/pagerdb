const std = @import("std");
const catalog = @import("../../catalog.zig");
const Pager = @import("../../pager/pager.zig").Pager;
const DiskPager = @import("../../pager/disk.zig").DiskPager;

pub const Dir = std.Io.Dir;

pub const DbHandle = struct {
    pager: *Pager,
    cat: catalog.Catalog,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *DbHandle) void {
        self.pager.flush() catch {};
        self.pager.close();
        self.alloc.destroy(self.pager);
        self.cat.deinit();
    }
};

pub fn makeDb(
    io: std.Io,
    path: []const u8,
    alloc: std.mem.Allocator,
) !DbHandle {
    const pager = try alloc.create(Pager);
    errdefer alloc.destroy(pager);
    pager.* = try DiskPager.create(alloc, io, path);
    var cat = catalog.Catalog.init(alloc, pager);
    try cat.bootstrap();
    return .{ .pager = pager, .cat = cat, .alloc = alloc };
}
