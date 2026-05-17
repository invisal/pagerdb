const std = @import("std");
const row_mod = @import("row.zig");

// Sort-preserving encoding of row values into a fixed-format byte key.
//
// Encoding rules (applied per value, in order):
//   NULL          → 0x00
//   INT (i64)     → 0x01 + 8 bytes offset-binary big-endian
//                   (XOR sign bit so negatives sort before positives)
//   REAL (f64)    → 0x01 + 8 bytes IEEE-754, sign-corrected for sort order
//   TEXT / BLOB   → 0x01 + raw bytes + 0x00 NUL terminator
//
// Rowid suffix: callers append 8 big-endian bytes via appendRowid() so every
// index entry is globally unique, enabling exact-match deletion and preventing
// unique-index duplicates with different rowids from colliding.

/// Maximum total key length (column encoding only, without the 8-byte rowid suffix).
/// Bounds the stack buffer used during B-tree page splits.
pub const MAX_KEY_LEN: usize = 512;

pub fn encodeKey(values: []const row_mod.Value, buf: []u8) usize {
    var pos: usize = 0;
    for (values) |val| {
        switch (val) {
            .null => {
                buf[pos] = 0x00;
                pos += 1;
            },
            .int => |n| {
                buf[pos] = 0x01;
                pos += 1;
                // Offset-binary: XOR the sign bit so i64 sort order matches u64 sort order.
                const u: u64 = @bitCast(n);
                std.mem.writeInt(u64, buf[pos..][0..8], u ^ 0x8000_0000_0000_0000, .big);
                pos += 8;
            },
            .real => |f| {
                buf[pos] = 0x01;
                pos += 1;
                var bits: u64 = @bitCast(f);
                // Negative: flip all bits (negatives go from large u64 to small).
                // Positive/zero: flip only the sign bit (positives go from small to large).
                if (bits >> 63 != 0) bits = ~bits else bits ^= 0x8000_0000_0000_0000;
                std.mem.writeInt(u64, buf[pos..][0..8], bits, .big);
                pos += 8;
            },
            .text => |s| {
                buf[pos] = 0x01;
                pos += 1;
                @memcpy(buf[pos..][0..s.len], s);
                pos += s.len;
                buf[pos] = 0x00; // NUL terminator separates fields in composite keys
                pos += 1;
            },
            .blob => |b| {
                buf[pos] = 0x01;
                pos += 1;
                @memcpy(buf[pos..][0..b.len], b);
                pos += b.len;
                buf[pos] = 0x00;
                pos += 1;
            },
        }
    }
    return pos;
}

/// Append the rowid as 8 big-endian bytes at buf[pos..pos+8].
/// Returns the new position.
pub fn appendRowid(buf: []u8, pos: usize, rowid: u64) usize {
    std.mem.writeInt(u64, buf[pos..][0..8], rowid, .big);
    return pos + 8;
}

/// Extract the rowid from the last 8 bytes of a full index key.
pub fn extractRowid(key: []const u8) u64 {
    return std.mem.readInt(u64, key[key.len - 8 ..][0..8], .big);
}

pub fn compareKeys(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}
