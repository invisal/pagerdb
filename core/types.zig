const std = @import("std");

pub const PAGE_SIZE: u32 = 8192;
// Rows larger than this are stored in overflow pages instead of inline.
// 25% of page size is chosen to balance:
//   - Keeping B-tree pages dense (more rows per page = fewer disk reads)
//   - Avoiding excessive fragmentation from small overflow pages
//   - Leaving room for the B-tree header + cell pointers + other cells
pub const OVERFLOW_THRESHOLD: u16 = PAGE_SIZE / 4; // 2048

pub const PageType = enum(u8) {
    btree_internal = 1,
    btree_leaf = 2,
    overflow = 3,
    free = 4,
};

// Page headers use extern layout to guarantee byte offsets for on-disk format.
// Fields are ordered so durability-critical fields come first and no implicit
// padding is inserted: u64 u32 u8 u8 u16 = 8+4+1+1+2 = 16 bytes.
//
// lsn leads the header so recovery code can read it with a single cast at
// offset 0 — no arithmetic needed.  checksum follows immediately so both
// durability fields are in the first 12 bytes.
pub const PageHeader = extern struct {
    lsn: u64,
    checksum: u32,
    page_type: PageType,
    flags: u8,
    _pad: u16,
};

const CHECKSUM_OFF = @offsetOf(PageHeader, "checksum"); // 8
const CHECKSUM_END = CHECKSUM_OFF + @sizeOf(u32); // 12

// Compute the page checksum.  Covers every byte except the checksum field
// itself, so corruption in lsn, page_type, flags, or the data region is
// detected.  XORing with page_id catches the case where the OS reads the
// wrong physical block into a buffer (wrong-block detection, same as
// PostgreSQL's block-number XOR trick).
pub fn pageChecksum(page_id: u32, buf: *const [PAGE_SIZE]u8) u32 {
    var h = std.hash.Crc32.init();
    h.update(buf[0..CHECKSUM_OFF]); // lsn
    h.update(buf[CHECKSUM_END..]); // page_type, flags, _pad, data
    return h.final() ^ page_id;
}

// Stamp the checksum into a page buffer before writing to disk.
pub fn writePageChecksum(page_id: u32, buf: *[PAGE_SIZE]u8) void {
    const cs = pageChecksum(page_id, buf);
    std.mem.writeInt(u32, buf[CHECKSUM_OFF..][0..4], cs, .little);
}

// Verify the checksum of a page read from disk.  Returns error.BadChecksum
// on mismatch so callers can distinguish corruption from other I/O errors.
pub fn verifyPageChecksum(page_id: u32, buf: *const [PAGE_SIZE]u8) error{BadChecksum}!void {
    const stored = std.mem.readInt(u32, buf[CHECKSUM_OFF..][0..4], .little);
    // A zero checksum means the page was written before checksum support was
    // added (or is a freshly zeroed page).  Accept it to stay compatible with
    // existing databases.
    if (stored == 0) return;
    if (pageChecksum(page_id, buf) != stored) return error.BadChecksum;
}

pub const ColType = enum(u8) {
    int = 0,
    real = 1,
    text = 2,
    blob = 3,

    pub fn name(self: ColType) []const u8 {
        return switch (self) {
            .int => "INT",
            .real => "REAL",
            .text => "TEXT",
            .blob => "BLOB",
        };
    }
};

pub const DB_MAGIC: u32 = 0x50474442; // "PGDB"

// 4+2+2+4+4+4+4+4+4+4+4+24 = 64 bytes
pub const DbHeader = extern struct {
    magic: u32,
    version_major: u16,
    version_minor: u16,
    page_size: u32,
    total_pages: u32,
    free_list_head: u32,
    sys_tables_root: u32,
    sys_columns_root: u32,
    sys_indexes_root: u32,
    sys_index_cols_root: u32,
    sys_views_root: u32,
    _reserved: [24]u8,
};

// 2+2+2+2+4+4+4+4 = 24 bytes
pub const BTreeHeader = extern struct {
    cell_count: u16,
    flags: u16, // bit 0: 1 = rowid tree, 0 = index tree
    free_end: u16,
    dead_bytes: u16,
    parent_page: u32,
    prev_leaf: u32,
    next_leaf: u32,
    _pad: u32,
};

// overhead: PageHeader(16) + next_page(4) + data_len(2) + _reserved(2) = 24
pub const OverflowPage = extern struct {
    header: PageHeader,
    next_page: u32,
    data_len: u16,
    _reserved: u16,
    data: [PAGE_SIZE - 24]u8,
};

pub const FreePage = extern struct {
    header: PageHeader,
    next_free_page: u32,
    _reserved: u32,
};

// Compile-time size assertions
comptime {
    std.debug.assert(@sizeOf(PageHeader) == 16);
    std.debug.assert(@sizeOf(DbHeader) == 64); // 4+2+2+4+4+4+4+4+4+4+4+24
    std.debug.assert(@sizeOf(BTreeHeader) == 24);
    std.debug.assert(@sizeOf(OverflowPage) == PAGE_SIZE);
}
