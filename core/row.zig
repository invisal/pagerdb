const std = @import("std");
const t = @import("types.zig");

pub const ValueTag = enum { null, int, real, text, blob };

pub const Value = union(ValueTag) {
    null,
    int: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,

    pub fn clone(self: Value, alloc: std.mem.Allocator) !Value {
        return switch (self) {
            .null => .null,
            .int => |n| .{ .int = n },
            .real => |f| .{ .real = f },
            .text => |s| .{ .text = try alloc.dupe(u8, s) },
            .blob => |b| .{ .blob = try alloc.dupe(u8, b) },
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .null => switch (b) {
                .null => true,
                else => false,
            },
            .int => |ai| switch (b) {
                .int => |bi| ai == bi,
                else => false,
            },
            .real => |af| switch (b) {
                .real => |bf| @as(u64, @bitCast(af)) == @as(u64, @bitCast(bf)),
                else => false,
            },
            .text => |as| switch (b) {
                .text => |bs| std.mem.eql(u8, as, bs),
                else => false,
            },
            .blob => |ab| switch (b) {
                .blob => |bb| std.mem.eql(u8, ab, bb),
                else => false,
            },
        };
    }

    pub fn hashInto(self: Value, hasher: *std.hash.Wyhash) void {
        std.hash.autoHash(hasher, @intFromEnum(std.meta.activeTag(self)));
        switch (self) {
            .null => {},
            .int => |n| std.hash.autoHash(hasher, n),
            .real => |f| std.hash.autoHash(hasher, @as(u64, @bitCast(f))),
            .text => |s| hasher.update(s),
            .blob => |b| hasher.update(b),
        }
    }

    pub fn hash(self: Value) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hashInto(&hasher);
        return hasher.final();
    }
};

pub const ColumnSchema = struct {
    col_type: t.ColType,
    nullable: bool,
};

fn nullBitmapSize(col_count: usize) usize {
    return (col_count + 7) / 8;
}

fn isNull(bitmap: []const u8, col_index: usize) bool {
    return (bitmap[col_index / 8] >> @intCast(col_index % 8)) & 1 == 1;
}

fn setNull(bitmap: []u8, col_index: usize) void {
    bitmap[col_index / 8] |= @as(u8, 1) << @intCast(col_index % 8);
}

// Offset-binary (also called bias) encoding: flip the sign bit so that
// the lexicographic order of the encoded u64 matches the numeric order of
// the original i64.  This lets us use memcmp-style comparisons on integers
// (e.g. in B-tree keys) without decoding first.
//   -1 → 0x7FFF...FF  (largest positive)
//    0 → 0x8000...00  (middle)
//   +1 → 0x8000...01  (smallest positive)
pub fn encodeInt(v: i64) u64 {
    return @as(u64, @bitCast(v)) ^ 0x8000000000000000;
}

pub fn decodeInt(v: u64) i64 {
    return @bitCast(v ^ 0x8000000000000000);
}

pub fn encodedSize(values: []const Value) usize {
    var size = nullBitmapSize(values.len);
    for (values) |val| {
        size += switch (val) {
            .null => 0,
            .int => 8,
            .real => 8,
            .text => |s| 2 + s.len,
            .blob => |b| 4 + b.len,
        };
    }
    return size;
}

pub fn encodeRow(values: []const Value, buf: []u8) usize {
    const bitmap_size = nullBitmapSize(values.len);
    const bitmap = buf[0..bitmap_size];
    @memset(bitmap, 0);

    var pos: usize = bitmap_size;

    for (values, 0..) |val, i| {
        switch (val) {
            .null => setNull(bitmap, i),
            .int => |v| {
                const encoded = encodeInt(v);
                std.mem.writeInt(u64, buf[pos..][0..8], encoded, .big);
                pos += 8;
            },
            .real => |v| {
                const bits: u64 = @bitCast(v);
                std.mem.writeInt(u64, buf[pos..][0..8], bits, .little);
                pos += 8;
            },
            .text => |s| {
                const len: u16 = @intCast(s.len);
                std.mem.writeInt(u16, buf[pos..][0..2], len, .big);
                pos += 2;
                @memcpy(buf[pos..][0..len], s);
                pos += len;
            },
            .blob => |b| {
                const len: u32 = @intCast(b.len);
                std.mem.writeInt(u32, buf[pos..][0..4], len, .big);
                pos += 4;
                @memcpy(buf[pos..][0..len], b);
                pos += len;
            },
        }
    }
    return pos;
}

pub fn decodeRow(
    cols: []const ColumnSchema,
    buf: []const u8,
    allocator: std.mem.Allocator,
) ![]Value {
    const bitmap_size = nullBitmapSize(cols.len);
    const bitmap = buf[0..bitmap_size];
    var pos: usize = bitmap_size;

    const values = try allocator.alloc(Value, cols.len);

    for (cols, 0..) |col, i| {
        if (isNull(bitmap, i)) {
            values[i] = .null;
            continue;
        }
        switch (col.col_type) {
            .int => {
                const raw = std.mem.readInt(u64, buf[pos..][0..8], .big);
                values[i] = .{ .int = decodeInt(raw) };
                pos += 8;
            },
            .real => {
                const bits = std.mem.readInt(u64, buf[pos..][0..8], .little);
                values[i] = .{ .real = @bitCast(bits) };
                pos += 8;
            },
            .text => {
                const len = std.mem.readInt(u16, buf[pos..][0..2], .big);
                pos += 2;
                values[i] = .{ .text = try allocator.dupe(u8, buf[pos..][0..len]) };
                pos += len;
            },
            .blob => {
                const len = std.mem.readInt(u32, buf[pos..][0..4], .big);
                pos += 4;
                values[i] = .{ .blob = try allocator.dupe(u8, buf[pos..][0..len]) };
                pos += len;
            },
        }
    }
    return values;
}

test "encode and decode round-trip" {
    const allocator = std.testing.allocator;

    const cols = [_]ColumnSchema{
        .{ .col_type = .int, .nullable = false },
        .{ .col_type = .text, .nullable = true },
        .{ .col_type = .real, .nullable = false },
        .{ .col_type = .blob, .nullable = true },
    };

    const values = [_]Value{
        .{ .int = -42 },
        .{ .text = "hello" },
        .{ .real = 3.14 },
        .null,
    };

    var buf: [256]u8 = undefined;
    const written = encodeRow(&values, &buf);

    const decoded = try decodeRow(&cols, buf[0..written], allocator);
    defer {
        for (decoded) |v| switch (v) {
            .text => |s| allocator.free(s),
            .blob => |b| allocator.free(b),
            else => {},
        };
        allocator.free(decoded);
    }

    try std.testing.expectEqual(decoded[0].int, -42);
    try std.testing.expectEqualStrings(decoded[1].text, "hello");
    try std.testing.expectEqual(decoded[2].real, 3.14);
    try std.testing.expect(decoded[3] == .null);
}

test "INT offset-binary ordering" {
    const neg = encodeInt(-1);
    const zero = encodeInt(0);
    const pos = encodeInt(1);
    try std.testing.expect(neg < zero);
    try std.testing.expect(zero < pos);
}
