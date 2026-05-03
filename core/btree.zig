const std = @import("std");
const t = @import("types.zig");
const Pager = @import("pager/pager.zig").Pager;
const DiskPager = @import("pager/disk.zig").DiskPager;
const overflow = @import("overflow.zig");

// Cell pointers grow downward from the start of the B-tree header area.
// Actual cell content grows upward from the end of the page.
// This "slotted page" layout allows variable-length cells and handles
// fragmentation by compacting cells without updating the cell pointer array.
pub const CELL_PTR_OFFSET: u16 = @sizeOf(t.PageHeader) + @sizeOf(t.BTreeHeader); // 40
pub const BTREE_FLAG_ROWID_TREE: u16 = 1;

pub fn readBTreeHeader(buf: *const [t.PAGE_SIZE]u8) t.BTreeHeader {
    return std.mem.bytesToValue(
        t.BTreeHeader,
        buf[@sizeOf(t.PageHeader)..][0..@sizeOf(t.BTreeHeader)],
    );
}

pub fn writeBTreeHeader(buf: *[t.PAGE_SIZE]u8, h: t.BTreeHeader) void {
    const dest = buf[@sizeOf(t.PageHeader)..][0..@sizeOf(t.BTreeHeader)];
    @memcpy(dest, std.mem.asBytes(&h));
}

pub fn freeStart(h: t.BTreeHeader) u16 {
    return CELL_PTR_OFFSET + h.cell_count * 2;
}

pub fn freeBytes(h: t.BTreeHeader) u16 {
    return h.free_end - freeStart(h);
}

pub fn usableBytes(h: t.BTreeHeader) u16 {
    return h.free_end - CELL_PTR_OFFSET;
}

pub fn initLeafPage(buf: *[t.PAGE_SIZE]u8, is_rowid: bool) void {
    @memset(buf, 0);

    const ph = t.PageHeader{
        .page_type = .btree_leaf,
        .flags = 0,
        .checksum = 0,
        .lsn = 0,
    };
    @memcpy(buf[0..@sizeOf(t.PageHeader)], std.mem.asBytes(&ph));

    const bh = t.BTreeHeader{
        .cell_count = 0,
        .flags = if (is_rowid) BTREE_FLAG_ROWID_TREE else 0,
        .free_end = t.PAGE_SIZE,
        .dead_bytes = 0,
        .parent_page = 0,
        .prev_leaf = 0,
        .next_leaf = 0,
        ._pad = 0,
    };
    writeBTreeHeader(buf, bh);
}

pub fn initInternalPage(buf: *[t.PAGE_SIZE]u8, is_rowid: bool) void {
    @memset(buf, 0);

    const ph = t.PageHeader{
        .page_type = .btree_internal,
        .flags = 0,
        .checksum = 0,
        .lsn = 0,
    };
    @memcpy(buf[0..@sizeOf(t.PageHeader)], std.mem.asBytes(&ph));

    const bh = t.BTreeHeader{
        .cell_count = 0,
        .flags = if (is_rowid) BTREE_FLAG_ROWID_TREE else 0,
        .free_end = t.PAGE_SIZE,
        .dead_bytes = 0,
        .parent_page = 0,
        .prev_leaf = 0,
        .next_leaf = 0,
        ._pad = 0,
    };
    writeBTreeHeader(buf, bh);
}

pub fn getCellPtr(buf: *const [t.PAGE_SIZE]u8, i: u16) u16 {
    const ptr_offset = CELL_PTR_OFFSET + i * 2;
    return std.mem.readInt(u16, buf[ptr_offset..][0..2], .little);
}

pub fn setCellPtr(buf: *[t.PAGE_SIZE]u8, i: u16, cell_offset: u16) void {
    const ptr_offset = CELL_PTR_OFFSET + i * 2;
    std.mem.writeInt(u16, buf[ptr_offset..][0..2], cell_offset, .little);
}

pub fn insertCellPtr(buf: *[t.PAGE_SIZE]u8, h: *t.BTreeHeader, i: u16, cell_offset: u16) void {
    var j: u16 = h.cell_count;
    while (j > i) : (j -= 1) {
        setCellPtr(buf, j, getCellPtr(buf, j - 1));
    }
    setCellPtr(buf, i, cell_offset);
    h.cell_count += 1;
}

pub fn removeCellPtr(buf: *[t.PAGE_SIZE]u8, h: *t.BTreeHeader, i: u16) void {
    var j: u16 = i;
    while (j < h.cell_count - 1) : (j += 1) {
        setCellPtr(buf, j, getCellPtr(buf, j + 1));
    }
    h.cell_count -= 1;
}

pub fn findRowidPos(buf: *const [t.PAGE_SIZE]u8, h: t.BTreeHeader, rowid: u64) u16 {
    var lo: u16 = 0;
    var hi: u16 = h.cell_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cell_off = getCellPtr(buf, mid);
        const cell_rowid = std.mem.readInt(u64, buf[cell_off..][0..8], .little);
        if (rowid <= cell_rowid) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    return lo;
}

// ── Cell types & helpers ─────────────────────────────────────────────────────

pub const CellData = struct {
    rowid: u64,
    row_data: []const u8,
    is_overflow: bool,
    overflow_page: u32,
    overflow_len: usize = 0, // original row length; valid when is_overflow == true
};

fn cellSize(cell: CellData) u16 {
    if (cell.is_overflow) return 8 + 2 + 4;
    return @intCast(8 + 2 + cell.row_data.len);
}

pub fn leafCellSize(buf: *const [t.PAGE_SIZE]u8, offset: u16) u16 {
    const row_len = std.mem.readInt(u16, buf[offset + 8 ..][0..2], .little);
    if (row_len & 0x8000 != 0) return 8 + 2 + 4;
    return 8 + 2 + (row_len & 0x7FFF);
}

fn writeLeafCell(buf: *[t.PAGE_SIZE]u8, offset: u16, cell: CellData) void {
    var pos = offset;
    std.mem.writeInt(u64, buf[pos..][0..8], cell.rowid, .little);
    pos += 8;
    if (cell.is_overflow) {
        const flag: u16 = 0x8000 | @as(u16, @intCast(cell.row_data.len));
        std.mem.writeInt(u16, buf[pos..][0..2], flag, .little);
        pos += 2;
        std.mem.writeInt(u32, buf[pos..][0..4], cell.overflow_page, .little);
    } else {
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(cell.row_data.len), .little);
        pos += 2;
        @memcpy(buf[pos..][0..cell.row_data.len], cell.row_data);
    }
}

pub fn readLeafCell(buf: *const [t.PAGE_SIZE]u8, cell_offset: u16) CellData {
    const rowid = std.mem.readInt(u64, buf[cell_offset..][0..8], .little);
    const raw_len = std.mem.readInt(u16, buf[cell_offset + 8 ..][0..2], .little);
    const is_overflow = (raw_len & 0x8000) != 0;
    const data_len: u16 = raw_len & 0x7FFF;

    if (is_overflow) {
        const ov_page = std.mem.readInt(u32, buf[cell_offset + 10 ..][0..4], .little);
        return .{ .rowid = rowid, .row_data = &.{}, .is_overflow = true, .overflow_page = ov_page, .overflow_len = data_len };
    }
    return .{
        .rowid = rowid,
        .row_data = buf[cell_offset + 10 ..][0..data_len],
        .is_overflow = false,
        .overflow_page = 0,
    };
}

// ── Compaction ───────────────────────────────────────────────────────────────

// Defragmentation: cells are not moved on every delete (that would be O(n²)).
// Instead we accumulate dead_bytes and compact only when free space is needed.
// This trades temporary fragmentation for predictable write amplification.
pub fn compactPage(buf: *[t.PAGE_SIZE]u8, h: *t.BTreeHeader) void {
    // Copy to a temporary buffer so we can pack cells contiguously from the
    // end of the page without worrying about overlapping moves.
    var tmp: [t.PAGE_SIZE]u8 = undefined;
    @memcpy(&tmp, buf);

    var write_pos: u16 = t.PAGE_SIZE;
    for (0..h.cell_count) |i| {
        const old_off = getCellPtr(&tmp, @intCast(i));
        const size = leafCellSize(&tmp, old_off);
        write_pos -= size;
        @memcpy(buf[write_pos..][0..size], tmp[old_off..][0..size]);
        setCellPtr(buf, @intCast(i), write_pos);
    }

    h.free_end = write_pos;
    h.dead_bytes = 0;
    writeBTreeHeader(buf, h.*);
}

// ── Insert ───────────────────────────────────────────────────────────────────

pub const InsertError = error{PageFull};

pub fn leafInsert(buf: *[t.PAGE_SIZE]u8, cell: CellData) InsertError!void {
    var h = readBTreeHeader(buf);
    const sz = cellSize(cell);

    if (freeBytes(h) < sz + 2) {
        if (freeBytes(h) + h.dead_bytes < sz + 2) return InsertError.PageFull;
        compactPage(buf, &h);
    }

    const pos = findRowidPos(buf, h, cell.rowid);
    const new_free_end = h.free_end - sz;
    writeLeafCell(buf, new_free_end, cell);
    insertCellPtr(buf, &h, pos, new_free_end);
    h.free_end = new_free_end;
    writeBTreeHeader(buf, h);
}

// ── Search ───────────────────────────────────────────────────────────────────

pub const SearchResult = struct {
    found: bool,
    cell_index: u16,
    cell_offset: u16,
};

pub fn leafSearch(buf: *const [t.PAGE_SIZE]u8, rowid: u64) SearchResult {
    const h = readBTreeHeader(buf);
    const pos = findRowidPos(buf, h, rowid);

    if (pos < h.cell_count) {
        const off = getCellPtr(buf, pos);
        const cell_rowid = std.mem.readInt(u64, buf[off..][0..8], .little);
        if (cell_rowid == rowid)
            return .{ .found = true, .cell_index = pos, .cell_offset = off };
    }
    return .{ .found = false, .cell_index = pos, .cell_offset = 0 };
}

// ── Scan ─────────────────────────────────────────────────────────────────────

pub fn leafScan(
    buf: *const [t.PAGE_SIZE]u8,
    ctx: anytype,
    comptime callbackFn: anytype,
) void {
    const h = readBTreeHeader(buf);
    for (0..h.cell_count) |i| {
        const off = getCellPtr(buf, @intCast(i));
        const cell = readLeafCell(buf, off);
        if (!callbackFn(cell, ctx)) break;
    }
}

pub fn lookup(
    pager: *Pager,
    root_id: u32,
    rowid: u64,
    buf: *[t.PAGE_SIZE]u8,
) !?CellData {
    const leaf_id = try findLeaf(pager, root_id, rowid);
    try pager.readPage(leaf_id, buf);
    const result = leafSearch(buf, rowid);
    if (!result.found) return null;
    return readLeafCell(buf, result.cell_offset);
}

pub fn lookupRow(
    pager: *Pager,
    root_id: u32,
    rowid: u64,
    allocator: std.mem.Allocator,
) !?[]u8 {
    var buf: [t.PAGE_SIZE]u8 = undefined;
    const cell = try lookup(pager, root_id, rowid, &buf) orelse return null;

    if (cell.is_overflow) {
        const out = try allocator.alloc(u8, cell.overflow_len);
        errdefer allocator.free(out);
        try overflow.readChain(pager, cell.overflow_page, cell.overflow_len, out);
        return out;
    }
    return try allocator.dupe(u8, cell.row_data);
}

pub fn maxRowid(pager: *Pager, root_id: u32) !?u64 {
    var page_id = root_id;
    var buf: [t.PAGE_SIZE]u8 = undefined;
    while (true) {
        try pager.readPage(page_id, &buf);
        const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
        if (ph.page_type == .btree_leaf) {
            const h = readBTreeHeader(&buf);
            if (h.cell_count == 0) return null;
            const last_off = getCellPtr(&buf, h.cell_count - 1);
            return std.mem.readInt(u64, buf[last_off..][0..8], .little);
        }
        page_id = getRightmostChild(&buf);
    }
}

pub fn scanFirst(pager: *Pager, root_id: u32) !u32 {
    var page_id = root_id;
    var buf: [t.PAGE_SIZE]u8 = undefined;
    while (true) {
        try pager.readPage(page_id, &buf);
        const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
        if (ph.page_type == .btree_leaf) return page_id;
        const h = readBTreeHeader(&buf);
        if (h.cell_count == 0) return page_id;
        const off = getCellPtr(&buf, 0);
        page_id = std.mem.readInt(u32, buf[off..][0..4], .little);
    }
}

pub const ScanIterator = struct {
    pager: *Pager,
    current_page: u32,
    cell_index: u16,
    buf: [t.PAGE_SIZE]u8,

    pub fn init(pager: *Pager, root_id: u32) !ScanIterator {
        const first = try scanFirst(pager, root_id);
        var it = ScanIterator{
            .pager = pager,
            .current_page = first,
            .cell_index = 0,
            .buf = undefined,
        };
        try pager.readPage(first, &it.buf);
        return it;
    }

    pub fn next(self: *ScanIterator) !?CellData {
        while (true) {
            const h = readBTreeHeader(&self.buf);
            if (self.cell_index < h.cell_count) {
                const off = getCellPtr(&self.buf, self.cell_index);
                self.cell_index += 1;
                return readLeafCell(&self.buf, off);
            }
            const next_page = h.next_leaf;
            if (next_page == 0) return null;
            self.current_page = next_page;
            self.cell_index = 0;
            try self.pager.readPage(next_page, &self.buf);
        }
    }
};

// ── Internal cell helpers ─────────────────────────────────────────────────────

const InternalCell = struct { left_child: u32, rowid: u64 };
const SplitResult = struct { right_page: u32, separator: u64 };

fn writeInternalCell(buf: *[t.PAGE_SIZE]u8, h: *t.BTreeHeader, ic: InternalCell) void {
    const size: u16 = 12;
    const new_end = h.free_end - size;
    std.mem.writeInt(u32, buf[new_end..][0..4], ic.left_child, .little);
    std.mem.writeInt(u64, buf[new_end + 4 ..][0..8], ic.rowid, .little);
    insertCellPtr(buf, h, h.cell_count, new_end);
    h.free_end = new_end;
}

// ── Splits ────────────────────────────────────────────────────────────────────

// Detect whether an insert would land at the rightmost edge of the page.
// Right-biased splits (keeping the left page full) are preferred for
// append-only workloads because they maximize page utilization and delay
// the next split.  This heuristic is used by the splitLeaf* functions.
fn isRightmostInsert(buf: *const [t.PAGE_SIZE]u8, h: t.BTreeHeader, rowid: u64) bool {
    if (h.cell_count == 0) return true;
    const last_off = getCellPtr(buf, h.cell_count - 1);
    const last_rowid = std.mem.readInt(u64, buf[last_off..][0..8], .little);
    return rowid > last_rowid;
}

fn splitLeafRight(
    pager: *Pager,
    page_id: u32,
    buf: *[t.PAGE_SIZE]u8,
    cell: CellData,
    is_rowid: bool,
) !SplitResult {
    const right_id = try pager.allocPage();
    var right_buf: [t.PAGE_SIZE]u8 = undefined;
    initLeafPage(&right_buf, is_rowid);

    var lh = readBTreeHeader(buf);
    var rh = readBTreeHeader(&right_buf);
    rh.prev_leaf = page_id;
    rh.next_leaf = lh.next_leaf;
    lh.next_leaf = right_id;
    writeBTreeHeader(buf, lh);

    rh.free_end = t.PAGE_SIZE;
    writeBTreeHeader(&right_buf, rh);
    try leafInsert(&right_buf, cell);

    try pager.writePage(page_id, buf);
    try pager.writePage(right_id, &right_buf);

    return .{ .right_page = right_id, .separator = cell.rowid };
}

// 50/50 split: used when the new rowid lands somewhere in the middle of the
// existing key range.  We move the right half of the cells to a new page so
// that both pages have roughly equal free space.  This keeps the tree balanced
// under random insert patterns (e.g. B-tree used as an index on non-sequential data).
fn splitLeafHalf(
    pager: *Pager,
    page_id: u32,
    buf: *[t.PAGE_SIZE]u8,
    cell: CellData,
    is_rowid: bool,
) !SplitResult {
    var h = readBTreeHeader(buf);
    const mid = h.cell_count / 2;

    const right_id = try pager.allocPage();
    var right_buf: [t.PAGE_SIZE]u8 = undefined;
    initLeafPage(&right_buf, is_rowid);

    for (mid..h.cell_count) |i| {
        const off = getCellPtr(buf, @intCast(i));
        const c = readLeafCell(buf, off);
        try leafInsert(&right_buf, c);
        h.dead_bytes += leafCellSize(buf, off);
    }

    var rh = readBTreeHeader(&right_buf);
    rh.prev_leaf = page_id;
    rh.next_leaf = h.next_leaf;
    h.next_leaf = right_id;
    h.cell_count = mid;
    writeBTreeHeader(buf, h);
    writeBTreeHeader(&right_buf, rh);

    const insert_pos = findRowidPos(buf, h, cell.rowid);
    if (insert_pos < mid) {
        try leafInsert(buf, cell);
    } else {
        try leafInsert(&right_buf, cell);
    }

    const first_off = getCellPtr(&right_buf, 0);
    const separator = std.mem.readInt(u64, right_buf[first_off..][0..8], .little);

    try pager.writePage(page_id, buf);
    try pager.writePage(right_id, &right_buf);

    return .{ .right_page = right_id, .separator = separator };
}

// Root split promotion: when the root page overflows we keep the same root_id
// but convert it from a leaf to an internal node.  The old leaf content is
// moved to a newly-allocated left child.  This guarantees that the root page
// never moves, which simplifies pager state management (pager.sys_tables_root
// and sys_columns_root remain valid pointers).
pub fn splitRoot(
    pager: *Pager,
    root_id: u32,
    root_buf: *[t.PAGE_SIZE]u8,
    cell: CellData,
    is_rowid: bool,
) !void {
    const left_id = try pager.allocPage();
    var left_buf: [t.PAGE_SIZE]u8 = undefined;
    @memcpy(&left_buf, root_buf);
    var lh = readBTreeHeader(&left_buf);
    lh.parent_page = root_id;
    writeBTreeHeader(&left_buf, lh);

    const split_result = if (isRightmostInsert(root_buf, readBTreeHeader(root_buf), cell.rowid))
        try splitLeafRight(pager, left_id, &left_buf, cell, is_rowid)
    else
        try splitLeafHalf(pager, left_id, &left_buf, cell, is_rowid);

    initInternalPage(root_buf, is_rowid);
    std.mem.writeInt(u32, root_buf[t.PAGE_SIZE - 4 ..][0..4], split_result.right_page, .little);

    var rh = readBTreeHeader(root_buf);
    rh.free_end = t.PAGE_SIZE - 4;
    writeBTreeHeader(root_buf, rh);

    const ic = InternalCell{ .left_child = left_id, .rowid = split_result.separator };
    writeInternalCell(root_buf, &rh, ic);
    writeBTreeHeader(root_buf, rh);

    try pager.writePage(root_id, root_buf);
    try pager.writePage(left_id, &left_buf);
}

// ── Internal node navigation ──────────────────────────────────────────────────
// Internal pages store cells as (left_child: u32, separator: u64) pairs.
// The rightmost child (all keys >= last separator) is stored separately at
// the end of the page so that every cell has the same fixed size (12 bytes).
// This simplifies insertion and deletion because we never have to shift
// variable-length data.

fn getRightmostChild(buf: *const [t.PAGE_SIZE]u8) u32 {
    return std.mem.readInt(u32, buf[t.PAGE_SIZE - 4 ..][0..4], .little);
}

fn setRightmostChild(buf: *[t.PAGE_SIZE]u8, page_id: u32) void {
    std.mem.writeInt(u32, buf[t.PAGE_SIZE - 4 ..][0..4], page_id, .little);
}

pub fn findLeaf(pager: *Pager, root_id: u32, rowid: u64) !u32 {
    var page_id = root_id;
    var buf: [t.PAGE_SIZE]u8 = undefined;

    while (true) {
        try pager.readPage(page_id, &buf);
        const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
        if (ph.page_type == .btree_leaf) return page_id;

        const h = readBTreeHeader(&buf);
        page_id = getRightmostChild(&buf);
        for (0..h.cell_count) |i| {
            const off = getCellPtr(&buf, @intCast(i));
            const sep = std.mem.readInt(u64, buf[off + 4 ..][0..8], .little);
            if (rowid < sep) {
                page_id = std.mem.readInt(u32, buf[off..][0..4], .little);
                break;
            }
        }
    }
}

fn internalInsert(
    pager: *Pager,
    buf: *[t.PAGE_SIZE]u8,
    page_id: u32,
    separator: u64,
    right_child: u32,
) !?SplitResult {
    var h = readBTreeHeader(buf);
    const cell_size: u16 = 12;

    var insert_pos: u16 = h.cell_count;
    for (0..h.cell_count) |i| {
        const off = getCellPtr(buf, @intCast(i));
        const sep = std.mem.readInt(u64, buf[off + 4 ..][0..8], .little);
        if (separator < sep) {
            insert_pos = @intCast(i);
            break;
        }
    }

    if (freeBytes(h) >= cell_size + 2) {
        const new_end = h.free_end - cell_size;

        if (insert_pos == h.cell_count) {
            // New separator is rightmost: old rightmost becomes left_child of new cell.
            const old_rightmost = getRightmostChild(buf);
            std.mem.writeInt(u32, buf[new_end..][0..4], old_rightmost, .little);
            std.mem.writeInt(u64, buf[new_end + 4 ..][0..8], separator, .little);
            insertCellPtr(buf, &h, insert_pos, new_end);
            setRightmostChild(buf, right_child);
        } else {
            // New separator splits the range owned by cell[insert_pos].
            // Preserve old left_child in the new cell; update the shifted cell to point at right_child.
            const existing_off = getCellPtr(buf, insert_pos);
            const old_lc = std.mem.readInt(u32, buf[existing_off..][0..4], .little);
            std.mem.writeInt(u32, buf[new_end..][0..4], old_lc, .little);
            std.mem.writeInt(u64, buf[new_end + 4 ..][0..8], separator, .little);
            insertCellPtr(buf, &h, insert_pos, new_end);
            const shifted_off = getCellPtr(buf, insert_pos + 1);
            std.mem.writeInt(u32, buf[shifted_off..][0..4], right_child, .little);
        }

        h.free_end = new_end;
        writeBTreeHeader(buf, h);
        return null;
    }

    return try splitInternalPage(pager, buf, page_id, separator, right_child);
}

fn splitInternalPage(
    pager: *Pager,
    buf: *[t.PAGE_SIZE]u8,
    page_id: u32,
    separator: u64,
    right_child: u32,
) !SplitResult {
    _ = pager;
    _ = buf;
    _ = page_id;
    _ = separator;
    _ = right_child;
    return error.NotImplementedYet;
}

pub fn insert(
    pager: *Pager,
    root_id: u32,
    rowid: u64,
    row_data: []const u8,
    is_rowid: bool,
) !void {
    const cell: CellData = if (row_data.len > t.OVERFLOW_THRESHOLD) blk: {
        const first_page = try overflow.buildChain(pager, row_data);
        break :blk .{
            .rowid = rowid,
            .row_data = row_data,
            .is_overflow = true,
            .overflow_page = first_page,
            .overflow_len = row_data.len,
        };
    } else .{
        .rowid = rowid,
        .row_data = row_data,
        .is_overflow = false,
        .overflow_page = 0,
    };

    var path: [32]u32 = undefined;
    var depth: usize = 0;
    var page_id = root_id;
    var buf: [t.PAGE_SIZE]u8 = undefined;

    // Descend to leaf, recording path.
    while (true) {
        try pager.readPage(page_id, &buf);
        path[depth] = page_id;
        depth += 1;

        const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
        if (ph.page_type == .btree_leaf) break;

        const h = readBTreeHeader(&buf);
        page_id = getRightmostChild(&buf);
        for (0..h.cell_count) |i| {
            const off = getCellPtr(&buf, @intCast(i));
            const sep = std.mem.readInt(u64, buf[off + 4 ..][0..8], .little);
            if (cell.rowid < sep) {
                page_id = std.mem.readInt(u32, buf[off..][0..4], .little);
                break;
            }
        }
    }

    try pager.readPage(path[depth - 1], &buf);
    leafInsert(&buf, cell) catch |err| {
        if (err != InsertError.PageFull) return err;

        // Leaf is full.
        if (depth == 1) {
            // Root is a leaf — promote root in place.
            try splitRoot(pager, root_id, &buf, cell, is_rowid);
            return;
        }

        var split = if (isRightmostInsert(&buf, readBTreeHeader(&buf), cell.rowid))
            try splitLeafRight(pager, path[depth - 1], &buf, cell, is_rowid)
        else
            try splitLeafHalf(pager, path[depth - 1], &buf, cell, is_rowid);

        // Propagate separator upward through internal nodes.
        var level = depth - 2;
        while (true) {
            var parent_buf: [t.PAGE_SIZE]u8 = undefined;
            try pager.readPage(path[level], &parent_buf);

            const result = try internalInsert(pager, &parent_buf, path[level], split.separator, split.right_page);
            try pager.writePage(path[level], &parent_buf);

            if (result == null) break;

            split = result.?;
            if (level == 0) return error.NotImplementedYet; // root internal split not yet implemented
            level -= 1;
        }
        return;
    };
    try pager.writePage(path[depth - 1], &buf);
}

// ── Delete ────────────────────────────────────────────────────────────────────

pub fn deleteFromLeaf(buf: *[t.PAGE_SIZE]u8, rowid: u64) bool {
    var h = readBTreeHeader(buf);
    const result = leafSearch(buf, rowid);
    if (!result.found) return false;

    const cell_sz = leafCellSize(buf, result.cell_offset);
    h.dead_bytes += cell_sz;
    removeCellPtr(buf, &h, result.cell_index);
    writeBTreeHeader(buf, h);
    return true;
}

fn unlinkFromParent(pager: *Pager, parent_id: u32, child_id: u32) !void {
    var buf: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(parent_id, &buf);
    var h = readBTreeHeader(&buf);

    for (0..h.cell_count) |i| {
        const off = getCellPtr(&buf, @intCast(i));
        const lc = std.mem.readInt(u32, buf[off..][0..4], .little);
        if (lc == child_id) {
            h.dead_bytes += 12;
            removeCellPtr(&buf, &h, @intCast(i));
            writeBTreeHeader(&buf, h);
            try pager.writePage(parent_id, &buf);
            return;
        }
    }

    if (getRightmostChild(&buf) == child_id) {
        if (h.cell_count > 0) {
            const last_off = getCellPtr(&buf, h.cell_count - 1);
            const new_rightmost = std.mem.readInt(u32, buf[last_off..][0..4], .little);
            setRightmostChild(&buf, new_rightmost);
            h.dead_bytes += 12;
            removeCellPtr(&buf, &h, h.cell_count - 1);
            writeBTreeHeader(&buf, h);
        }
        try pager.writePage(parent_id, &buf);
    }
}

pub fn delete(
    pager: *Pager,
    root_id: u32,
    rowid: u64,
) !bool {
    var path: [32]u32 = undefined;
    var depth: usize = 0;
    var page_id = root_id;
    var buf: [t.PAGE_SIZE]u8 = undefined;

    while (true) {
        try pager.readPage(page_id, &buf);
        path[depth] = page_id;
        depth += 1;
        const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
        if (ph.page_type == .btree_leaf) break;

        const h = readBTreeHeader(&buf);
        page_id = getRightmostChild(&buf);
        for (0..h.cell_count) |i| {
            const off = getCellPtr(&buf, @intCast(i));
            const sep = std.mem.readInt(u64, buf[off + 4 ..][0..8], .little);
            if (rowid < sep) {
                page_id = std.mem.readInt(u32, buf[off..][0..4], .little);
                break;
            }
        }
    }

    const leaf_id = path[depth - 1];
    try pager.readPage(leaf_id, &buf);
    const sr = leafSearch(&buf, rowid);
    if (sr.found) {
        const cell = readLeafCell(&buf, sr.cell_offset);
        if (cell.is_overflow) try overflow.freeChain(pager, cell.overflow_page);
    }
    const deleted = deleteFromLeaf(&buf, rowid);
    if (!deleted) return false;

    const h = readBTreeHeader(&buf);
    if (h.cell_count == 0 and leaf_id != root_id) {
        try pager.freePage(leaf_id);
        if (depth >= 2) {
            try unlinkFromParent(pager, path[depth - 2], leaf_id);
        }
    } else {
        try pager.writePage(leaf_id, &buf);
    }

    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn getCellRowid(buf: *const [t.PAGE_SIZE]u8, i: u16) u64 {
    return std.mem.readInt(u64, buf[getCellPtr(buf, i)..][0..8], .little);
}

test "insert and search in single leaf" {
    var buf: [t.PAGE_SIZE]u8 = undefined;
    initLeafPage(&buf, true);

    const row = [_]u8{ 0x01, 0x02, 0x03 };
    try leafInsert(&buf, .{ .rowid = 10, .row_data = &row, .is_overflow = false, .overflow_page = 0 });
    try leafInsert(&buf, .{ .rowid = 5, .row_data = &row, .is_overflow = false, .overflow_page = 0 });
    try leafInsert(&buf, .{ .rowid = 20, .row_data = &row, .is_overflow = false, .overflow_page = 0 });

    const h = readBTreeHeader(&buf);
    try std.testing.expectEqual(h.cell_count, 3);

    try std.testing.expectEqual(getCellRowid(&buf, 0), 5);
    try std.testing.expectEqual(getCellRowid(&buf, 1), 10);
    try std.testing.expectEqual(getCellRowid(&buf, 2), 20);

    const r = leafSearch(&buf, 10);
    try std.testing.expect(r.found);
    try std.testing.expectEqual(r.cell_index, 1);

    const r2 = leafSearch(&buf, 99);
    try std.testing.expect(!r2.found);
}

test "PageFull returned when no space remains" {
    var buf: [t.PAGE_SIZE]u8 = undefined;
    initLeafPage(&buf, true);

    // Each cell: 8 + 2 + 250 = 260 bytes + 2 ptr = 262 bytes.
    // Usable area: PAGE_SIZE(8192) - CELL_PTR_OFFSET(40) = 8152 bytes → ~31 cells fit.
    var row: [250]u8 = undefined;
    @memset(&row, 0xAB);
    var rowid: u64 = 1;
    while (true) : (rowid += 1) {
        leafInsert(&buf, .{ .rowid = rowid, .row_data = &row, .is_overflow = false, .overflow_page = 0 }) catch |err| {
            try std.testing.expectEqual(err, InsertError.PageFull);
            break;
        };
    }
}

test "compactPage reclaims dead bytes" {
    var buf: [t.PAGE_SIZE]u8 = undefined;
    initLeafPage(&buf, true);

    const row = [_]u8{0xAA} ** 10;
    try leafInsert(&buf, .{ .rowid = 1, .row_data = &row, .is_overflow = false, .overflow_page = 0 });
    try leafInsert(&buf, .{ .rowid = 2, .row_data = &row, .is_overflow = false, .overflow_page = 0 });
    try leafInsert(&buf, .{ .rowid = 3, .row_data = &row, .is_overflow = false, .overflow_page = 0 });

    // Simulate dead bytes by directly bumping the header field
    var h = readBTreeHeader(&buf);
    h.dead_bytes = 100;
    writeBTreeHeader(&buf, h);

    compactPage(&buf, &h);

    try std.testing.expectEqual(h.dead_bytes, 0);
    // All 3 cells still readable in order
    try std.testing.expectEqual(getCellRowid(&buf, 0), 1);
    try std.testing.expectEqual(getCellRowid(&buf, 1), 2);
    try std.testing.expectEqual(getCellRowid(&buf, 2), 3);
}

test "initLeafPage sets correct header" {
    var buf: [t.PAGE_SIZE]u8 = undefined;
    initLeafPage(&buf, true);

    const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
    try std.testing.expectEqual(ph.page_type, .btree_leaf);

    const bh = readBTreeHeader(&buf);
    try std.testing.expectEqual(bh.cell_count, 0);
    try std.testing.expectEqual(bh.free_end, t.PAGE_SIZE);
    try std.testing.expectEqual(bh.flags & BTREE_FLAG_ROWID_TREE, BTREE_FLAG_ROWID_TREE);
}

test "cell pointer insert and remove" {
    var buf: [t.PAGE_SIZE]u8 = undefined;
    initLeafPage(&buf, true);
    var h = readBTreeHeader(&buf);

    insertCellPtr(&buf, &h, 0, 8000);
    insertCellPtr(&buf, &h, 1, 7900);
    insertCellPtr(&buf, &h, 0, 8100);

    try std.testing.expectEqual(getCellPtr(&buf, 0), 8100);
    try std.testing.expectEqual(getCellPtr(&buf, 1), 8000);
    try std.testing.expectEqual(getCellPtr(&buf, 2), 7900);
    try std.testing.expectEqual(h.cell_count, 3);

    removeCellPtr(&buf, &h, 1);
    try std.testing.expectEqual(h.cell_count, 2);
    try std.testing.expectEqual(getCellPtr(&buf, 1), 7900);
}

test "right-biased split keeps left page full" {
    const io = std.testing.io;
    const path = "/tmp/test_split_right.db";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};

    var pager = try DiskPager.create(std.testing.allocator, io, path, .{});
    defer pager.close();

    const page_id = try pager.allocPage();
    var buf: [t.PAGE_SIZE]u8 = undefined;
    initLeafPage(&buf, true);

    var row: [100]u8 = undefined;
    @memset(&row, 0xAB);
    var rowid: u64 = 1;
    while (true) : (rowid += 1) {
        leafInsert(&buf, .{ .rowid = rowid, .row_data = &row, .is_overflow = false, .overflow_page = 0 }) catch break;
    }
    const left_count_before = readBTreeHeader(&buf).cell_count;

    const new_cell = CellData{ .rowid = rowid, .row_data = &row, .is_overflow = false, .overflow_page = 0 };
    const result = try splitLeafRight(&pager, page_id, &buf, new_cell, true);

    try std.testing.expectEqual(readBTreeHeader(&buf).cell_count, left_count_before);

    var right_buf: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(result.right_page, &right_buf);
    try std.testing.expectEqual(readBTreeHeader(&right_buf).cell_count, 1);
    try std.testing.expectEqual(getCellRowid(&right_buf, 0), rowid);
}

test "50/50 split distributes cells evenly" {
    const io = std.testing.io;
    const path = "/tmp/test_split_half.db";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};

    var pager = try DiskPager.create(std.testing.allocator, io, path, .{});
    defer pager.close();

    const page_id = try pager.allocPage();
    var buf: [t.PAGE_SIZE]u8 = undefined;
    initLeafPage(&buf, true);

    var row: [100]u8 = undefined;
    @memset(&row, 0xAB);
    var rowid: u64 = 100;
    while (true) : (rowid += 100) {
        leafInsert(&buf, .{ .rowid = rowid, .row_data = &row, .is_overflow = false, .overflow_page = 0 }) catch break;
    }
    const total = readBTreeHeader(&buf).cell_count;

    const new_cell = CellData{ .rowid = 150, .row_data = &row, .is_overflow = false, .overflow_page = 0 };
    const result = try splitLeafHalf(&pager, page_id, &buf, new_cell, true);

    var right_buf: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(result.right_page, &right_buf);

    const left_count = readBTreeHeader(&buf).cell_count;
    const right_count = readBTreeHeader(&right_buf).cell_count;
    try std.testing.expectEqual(left_count + right_count, total + 1);
    try std.testing.expect(left_count >= total / 2 - 1 and left_count <= total / 2 + 2);
}

test "root split keeps root_id stable" {
    const io = std.testing.io;
    const path = "/tmp/test_split_root.db";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};

    var pager = try DiskPager.create(std.testing.allocator, io, path, .{});
    defer pager.close();

    const root_id = try pager.allocPage();
    var root_buf: [t.PAGE_SIZE]u8 = undefined;
    initLeafPage(&root_buf, true);

    var row: [100]u8 = undefined;
    @memset(&row, 0xAB);
    var rowid: u64 = 1;
    while (true) : (rowid += 1) {
        leafInsert(&root_buf, .{ .rowid = rowid, .row_data = &row, .is_overflow = false, .overflow_page = 0 }) catch break;
    }

    const new_cell = CellData{ .rowid = rowid, .row_data = &row, .is_overflow = false, .overflow_page = 0 };
    try splitRoot(&pager, root_id, &root_buf, new_cell, true);

    const ph = std.mem.bytesToValue(t.PageHeader, root_buf[0..@sizeOf(t.PageHeader)]);
    try std.testing.expectEqual(ph.page_type, .btree_internal);

    const rh = readBTreeHeader(&root_buf);
    try std.testing.expectEqual(rh.cell_count, 1);

    const left_child_id = std.mem.readInt(u32, root_buf[getCellPtr(&root_buf, 0)..][0..4], .little);
    const right_child_id = std.mem.readInt(u32, root_buf[t.PAGE_SIZE - 4 ..][0..4], .little);

    var left_buf: [t.PAGE_SIZE]u8 = undefined;
    var right_buf: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(left_child_id, &left_buf);
    try pager.readPage(right_child_id, &right_buf);

    const lph = std.mem.bytesToValue(t.PageHeader, left_buf[0..@sizeOf(t.PageHeader)]);
    const rph = std.mem.bytesToValue(t.PageHeader, right_buf[0..@sizeOf(t.PageHeader)]);
    try std.testing.expectEqual(lph.page_type, .btree_leaf);
    try std.testing.expectEqual(rph.page_type, .btree_leaf);
}

test "multi-level insert: force root to become internal" {
    const io = std.testing.io;
    const path = "/tmp/test_btree_multi.db";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};

    var pager = try DiskPager.create(std.testing.allocator, io, path, .{});
    defer pager.close();

    const root_id = try pager.allocPage();
    var root_buf: [t.PAGE_SIZE]u8 = undefined;
    initLeafPage(&root_buf, true);
    try pager.writePage(root_id, &root_buf);

    var row: [200]u8 = undefined;
    @memset(&row, 0);
    for (1..200) |i| {
        try insert(&pager, root_id, @intCast(i), &row, true);
    }

    // Root should now be an internal node.
    var buf: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(root_id, &buf);
    const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
    try std.testing.expectEqual(ph.page_type, .btree_internal);

    // All 199 rows must be findable.
    for (1..200) |i| {
        const leaf_id = try findLeaf(&pager, root_id, @intCast(i));
        try pager.readPage(leaf_id, &buf);
        const r = leafSearch(&buf, @intCast(i));
        try std.testing.expect(r.found);
    }
}

// ── Structural verification ────────────────────────────────────────────────────

pub const VerifyError = error{
    LeafRowidsNotAscending,
    InternalSeparatorsNotAscending,
    LeafChainLinkBroken,
    LeafChainCycle,
    TreeDepthExceeded,
};

// Walk the entire B-tree and assert structural invariants.  Used by tests
// and the deterministic simulator to catch corruption early.  Invariants:
//   1. Every leaf page has strictly ascending rowids (no duplicates, sorted).
//   2. Every internal page has strictly ascending separator rowids.
//   3. The leaf doubly-linked chain has consistent prev/next pointers.
//   4. No cycles in the internal node graph (depth_limit check).
// We bound walks by pager.total_pages; any traversal exceeding this must
// have cycled, indicating a corrupted child pointer.
pub fn verifyTree(pager: *Pager, root_id: u32) !void {
    try verifyNode(pager, root_id, pager.total_pages);
    try verifyLeafChain(pager, root_id);
}

// depth_limit decrements on every page visit; hitting zero means a pointer
// cycle is present in the internal-page graph.
fn verifyNode(pager: *Pager, page_id: u32, depth_limit: u32) anyerror!void {
    if (depth_limit == 0) return VerifyError.TreeDepthExceeded;
    var buf: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(page_id, &buf);
    const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);

    if (ph.page_type == .btree_leaf) {
        try verifyLeafPage(&buf);
    } else {
        try verifyInternalPage(pager, &buf, depth_limit - 1);
    }
}

fn verifyLeafPage(buf: *const [t.PAGE_SIZE]u8) !void {
    const h = readBTreeHeader(buf);
    var prev: ?u64 = null;
    for (0..h.cell_count) |i| {
        const off = getCellPtr(buf, @intCast(i));
        const cell = readLeafCell(buf, off);
        if (prev) |p| {
            if (cell.rowid <= p) return VerifyError.LeafRowidsNotAscending;
        }
        prev = cell.rowid;
    }
}

fn verifyInternalPage(pager: *Pager, buf: *const [t.PAGE_SIZE]u8, depth_limit: u32) anyerror!void {
    const h = readBTreeHeader(buf);
    var prev_sep: ?u64 = null;
    for (0..h.cell_count) |i| {
        const off = getCellPtr(buf, @intCast(i));
        const left_child = std.mem.readInt(u32, buf[off..][0..4], .little);
        const sep = std.mem.readInt(u64, buf[off + 4 ..][0..8], .little);
        if (prev_sep) |p| {
            if (sep <= p) return VerifyError.InternalSeparatorsNotAscending;
        }
        try verifyNode(pager, left_child, depth_limit);
        prev_sep = sep;
    }
    const rightmost = std.mem.readInt(u32, buf[t.PAGE_SIZE - 4 ..][0..4], .little);
    try verifyNode(pager, rightmost, depth_limit);
}

// Walk the leaf doubly-linked list and verify that every next_leaf->prev_leaf
// points back to the current page, and vice-versa.  The loop is bounded by
// total_pages: a valid chain cannot visit more pages than exist in the file.
fn verifyLeafChain(pager: *Pager, root_id: u32) !void {
    var page_id = try scanFirst(pager, root_id);
    var prev_id: u32 = 0;
    var steps: u32 = 0;

    while (true) {
        if (steps >= pager.total_pages) return VerifyError.LeafChainCycle;
        steps += 1;

        var buf: [t.PAGE_SIZE]u8 = undefined;
        try pager.readPage(page_id, &buf);
        const h = readBTreeHeader(&buf);

        if (h.prev_leaf != prev_id) return VerifyError.LeafChainLinkBroken;

        const next = h.next_leaf;
        if (next == 0) break;

        var next_buf: [t.PAGE_SIZE]u8 = undefined;
        try pager.readPage(next, &next_buf);
        const next_h = readBTreeHeader(&next_buf);
        if (next_h.prev_leaf != page_id) return VerifyError.LeafChainLinkBroken;

        prev_id = page_id;
        page_id = next;
    }
}
