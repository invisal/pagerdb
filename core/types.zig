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
