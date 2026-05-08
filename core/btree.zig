const std = @import("std");
const t = @import("types.zig");
const PageWriter = @import("page_writer.zig").PageWriter;
const Pager = @import("pager/pager.zig").Pager;
const DiskPager = @import("pager/disk.zig").DiskPager;
const InMemoryPager = @import("pager/memory.zig").InMemoryPager;
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

pub fn writeBTreeHeader(pw: *PageWriter, h: t.BTreeHeader) void {
    pw.writeAt(@sizeOf(t.PageHeader), std.mem.asBytes(&h));
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

pub fn initLeafPage(pw: *PageWriter, is_rowid: bool) void {
    const ph = t.PageHeader{
        .page_type = .btree_leaf,
        .flags = 0,
        .checksum = 0,
        .lsn = 0,
    };
    pw.writeAt(0, std.mem.asBytes(&ph));

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
    writeBTreeHeader(pw, bh);
}

pub fn initInternalPage(pw: *PageWriter, is_rowid: bool) void {
    const ph = t.PageHeader{
        .page_type = .btree_internal,
        .flags = 0,
        .checksum = 0,
        .lsn = 0,
    };
    pw.writeAt(0, std.mem.asBytes(&ph));

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
    writeBTreeHeader(pw, bh);
}

pub fn getCellPtr(buf: *const [t.PAGE_SIZE]u8, i: u16) u16 {
    const ptr_offset = CELL_PTR_OFFSET + i * 2;
    return std.mem.readInt(u16, buf[ptr_offset..][0..2], .little);
}

pub fn setCellPtr(pw: *PageWriter, i: u16, cell_offset: u16) void {
    const ptr_offset = CELL_PTR_OFFSET + i * 2;
    pw.writeInt(u16, ptr_offset, cell_offset, .little);
}

pub fn insertCellPtr(pw: *PageWriter, h: *t.BTreeHeader, i: u16, cell_offset: u16) void {
    var j: u16 = h.cell_count;
    while (j > i) : (j -= 1) {
        setCellPtr(pw, j, getCellPtr(&pw.buf, j - 1));
    }
    setCellPtr(pw, i, cell_offset);
    h.cell_count += 1;
}

pub fn removeCellPtr(pw: *PageWriter, h: *t.BTreeHeader, i: u16) void {
    var j: u16 = i;
    while (j < h.cell_count - 1) : (j += 1) {
        setCellPtr(pw, j, getCellPtr(&pw.buf, j + 1));
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

fn writeLeafCell(pw: *PageWriter, offset: u16, cell: CellData) void {
    var pos = offset;
    pw.writeInt(u64, pos, cell.rowid, .little);
    pos += 8;

    if (cell.is_overflow) {
        const flag: u16 = 0x8000 | @as(u16, @intCast(cell.row_data.len));
        pw.writeInt(u16, pos, flag, .little);
        pos += 2;
        pw.writeInt(u32, pos, cell.overflow_page, .little);
    } else {
        pw.writeInt(u16, pos, @intCast(cell.row_data.len), .little);
        pos += 2;
        pw.writeAt(pos, cell.row_data);
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
pub fn compactPage(pw: *PageWriter, h: *t.BTreeHeader) void {
    // Copy to a temporary buffer so we can pack cells contiguously from the
    // end of the page without worrying about overlapping moves.
    var tmp: [t.PAGE_SIZE]u8 = undefined;
    @memcpy(&tmp, &pw.buf);

    var write_pos: u16 = t.PAGE_SIZE;
    for (0..h.cell_count) |i| {
        const old_off = getCellPtr(&tmp, @intCast(i));
        const size = leafCellSize(&tmp, old_off);
        write_pos -= size;
        // Write directly into pw.buf to avoid one delta per cell (compaction
        // may move 30+ cells; recording individual deltas would overflow MAX_DELTAS).
        @memcpy(pw.buf[write_pos..][0..size], tmp[old_off..][0..size]);
        std.mem.writeInt(u16, pw.buf[CELL_PTR_OFFSET + @as(u16, @intCast(i)) * 2 ..][0..2], write_pos, .little);
    }

    h.free_end = write_pos;
    h.dead_bytes = 0;
    // Write header directly too (same reason: avoid extra deltas mid-compact).
    @memcpy(pw.buf[@sizeOf(t.PageHeader)..][0..@sizeOf(t.BTreeHeader)], std.mem.asBytes(h));

    // Collapse all prior deltas into one full-page record: compaction rewrites
    // the entire live area, so a single delta is the most accurate WAL record.
    pw.delta_count = 1;
    pw.deltas[0] = .{ .offset = 0, .len = t.PAGE_SIZE };
}

// ── Insert ───────────────────────────────────────────────────────────────────

pub const InsertError = error{PageFull};

pub fn leafInsert(pw: *PageWriter, cell: CellData) InsertError!void {
    var h = readBTreeHeader(&pw.buf);
    const sz = cellSize(cell);

    if (freeBytes(h) < sz + 2) {
        if (freeBytes(h) + h.dead_bytes < sz + 2) return InsertError.PageFull;
        compactPage(pw, &h);
    }

    const pos = findRowidPos(&pw.buf, h, cell.rowid);
    const new_free_end = h.free_end - sz;
    writeLeafCell(pw, new_free_end, cell);
    insertCellPtr(pw, &h, pos, new_free_end);
    h.free_end = new_free_end;
    writeBTreeHeader(pw, h);
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

fn writeInternalCell(pw: *PageWriter, h: *t.BTreeHeader, ic: InternalCell) void {
    const size: u16 = 12;
    const new_end = h.free_end - size;
    pw.writeInt(u32, new_end, ic.left_child, .little);
    pw.writeInt(u64, new_end + 4, ic.rowid, .little);
    insertCellPtr(pw, h, h.cell_count, new_end);
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
    lw: *PageWriter,
    cell: CellData,
    is_rowid: bool,
) !SplitResult {
    const right_id = try pager.allocPage();
    var rw = PageWriter.init(pager, right_id);
    initLeafPage(&rw, is_rowid);

    var lh = readBTreeHeader(&lw.buf);
    var rh = readBTreeHeader(&rw.buf);
    rh.prev_leaf = lw.page_id;
    rh.next_leaf = lh.next_leaf;
    lh.next_leaf = right_id;
    writeBTreeHeader(lw, lh);
    writeBTreeHeader(&rw, rh);

    try leafInsert(&rw, cell);

    try lw.commit();
    try rw.commit();

    return .{ .right_page = right_id, .separator = cell.rowid };
}

// 50/50 split: used when the new rowid lands somewhere in the middle of the
// existing key range.  We move the right half of the cells to a new page so
// that both pages have roughly equal free space.  This keeps the tree balanced
// under random insert patterns (e.g. B-tree used as an index on non-sequential data).
fn splitLeafHalf(
    pager: *Pager,
    lw: *PageWriter,
    cell: CellData,
    is_rowid: bool,
) !SplitResult {
    var h = readBTreeHeader(&lw.buf);
    const mid = h.cell_count / 2;

    const right_id = try pager.allocPage();
    var rw = PageWriter.init(pager, right_id);
    initLeafPage(&rw, is_rowid);

    for (mid..h.cell_count) |i| {
        const off = getCellPtr(&lw.buf, @intCast(i));
        const c = readLeafCell(&lw.buf, off);
        try leafInsert(&rw, c);
        h.dead_bytes += leafCellSize(&lw.buf, off);
    }

    var rh = readBTreeHeader(&rw.buf);
    rh.prev_leaf = lw.page_id;
    rh.next_leaf = h.next_leaf;
    h.next_leaf = right_id;
    h.cell_count = mid;
    writeBTreeHeader(lw, h);
    writeBTreeHeader(&rw, rh);

    const insert_pos = findRowidPos(&lw.buf, h, cell.rowid);
    if (insert_pos < mid) {
        try leafInsert(lw, cell);
    } else {
        try leafInsert(&rw, cell);
    }

    const first_off = getCellPtr(&rw.buf, 0);
    const separator = std.mem.readInt(u64, rw.buf[first_off..][0..8], .little);

    try lw.commit();
    try rw.commit();

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
    // Seed the left-child writer with the current root content, then fix parent_page.
    var left_pw = PageWriter.init(pager, left_id);
    left_pw.buf = root_buf.*;
    var lh = readBTreeHeader(&left_pw.buf);
    lh.parent_page = root_id;
    writeBTreeHeader(&left_pw, lh);

    const split_result = if (isRightmostInsert(root_buf, readBTreeHeader(root_buf), cell.rowid))
        try splitLeafRight(pager, &left_pw, cell, is_rowid)
    else
        try splitLeafHalf(pager, &left_pw, cell, is_rowid);
    // left_pw was committed inside splitLeaf*.

    var root_pw = PageWriter.init(pager, root_id);
    initInternalPage(&root_pw, is_rowid);
    setRightmostChild(&root_pw, split_result.right_page);

    var rh = readBTreeHeader(&root_pw.buf);
    rh.free_end = t.PAGE_SIZE - 4;
    writeBTreeHeader(&root_pw, rh);

    const ic = InternalCell{ .left_child = left_id, .rowid = split_result.separator };
    writeInternalCell(&root_pw, &rh, ic);
    writeBTreeHeader(&root_pw, rh);

    try root_pw.commit();
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

fn setRightmostChild(pw: *PageWriter, page_id: u32) void {
    pw.writeInt(u32, t.PAGE_SIZE - 4, page_id, .little);
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
    pw: *PageWriter,
    separator: u64,
    right_child: u32,
) !?SplitResult {
    var h = readBTreeHeader(&pw.buf);
    const cell_size: u16 = 12;

    var insert_pos: u16 = h.cell_count;
    for (0..h.cell_count) |i| {
        const off = getCellPtr(&pw.buf, @intCast(i));
        const sep = std.mem.readInt(u64, pw.buf[off + 4 ..][0..8], .little);
        if (separator < sep) {
            insert_pos = @intCast(i);
            break;
        }
    }

    if (freeBytes(h) >= cell_size + 2) {
        const new_end = h.free_end - cell_size;

        if (insert_pos == h.cell_count) {
            // New separator is rightmost: old rightmost becomes left_child of new cell.
            const old_rightmost = getRightmostChild(&pw.buf);
            pw.writeInt(u32, new_end, old_rightmost, .little);
            pw.writeInt(u64, new_end + 4, separator, .little);
            insertCellPtr(pw, &h, insert_pos, new_end);
            setRightmostChild(pw, right_child);
        } else {
            // New separator splits the range owned by cell[insert_pos].
            // Preserve old left_child in the new cell; update the shifted cell to point at right_child.
            const existing_off = getCellPtr(&pw.buf, insert_pos);
            const old_lc = std.mem.readInt(u32, pw.buf[existing_off..][0..4], .little);
            pw.writeInt(u32, new_end, old_lc, .little);
            pw.writeInt(u64, new_end + 4, separator, .little);
            insertCellPtr(pw, &h, insert_pos, new_end);
            const shifted_off = getCellPtr(&pw.buf, insert_pos + 1);
            pw.writeInt(u32, shifted_off, right_child, .little);
        }

        h.free_end = new_end;
        writeBTreeHeader(pw, h);
        return null;
    }

    return try splitInternalPage(pager, pw, separator, right_child);
}

fn splitInternalPage(
    pager: *Pager,
    pw: *PageWriter,
    separator: u64,
    right_child: u32,
) !SplitResult {
    _ = pager;
    _ = pw;
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

    var lw = try PageWriter.open(pager, path[depth - 1]);
    leafInsert(&lw, cell) catch |err| {
        if (err != InsertError.PageFull) return err;

        // Leaf is full.
        if (depth == 1) {
            // Root is a leaf — promote root in place.
            try splitRoot(pager, root_id, &lw.buf, cell, is_rowid);
            return;
        }

        var split = if (isRightmostInsert(&lw.buf, readBTreeHeader(&lw.buf), cell.rowid))
            try splitLeafRight(pager, &lw, cell, is_rowid)
        else
            try splitLeafHalf(pager, &lw, cell, is_rowid);

        // Propagate separator upward through internal nodes.
        var level = depth - 2;
        while (true) {
            var parent_pw = try PageWriter.open(pager, path[level]);
            const result = try internalInsert(pager, &parent_pw, split.separator, split.right_page);
            try parent_pw.commit();

            if (result == null) break;

            split = result.?;
            if (level == 0) return error.NotImplementedYet; // root internal split not yet implemented
            level -= 1;
        }
        return;
    };
    try lw.commit();
}

// ── Delete ────────────────────────────────────────────────────────────────────

pub fn deleteFromLeaf(pw: *PageWriter, rowid: u64) bool {
    var h = readBTreeHeader(&pw.buf);
    const result = leafSearch(&pw.buf, rowid);
    if (!result.found) return false;

    const cell_sz = leafCellSize(&pw.buf, result.cell_offset);
    h.dead_bytes += cell_sz;
    removeCellPtr(pw, &h, result.cell_index);
    writeBTreeHeader(pw, h);
    return true;
}

fn unlinkFromParent(pager: *Pager, parent_id: u32, child_id: u32) !void {
    var pw = try PageWriter.open(pager, parent_id);
    var h = readBTreeHeader(&pw.buf);

    for (0..h.cell_count) |i| {
        const off = getCellPtr(&pw.buf, @intCast(i));
        const lc = std.mem.readInt(u32, pw.buf[off..][0..4], .little);
        if (lc == child_id) {
            h.dead_bytes += 12;
            removeCellPtr(&pw, &h, @intCast(i));
            writeBTreeHeader(&pw, h);
            try pw.commit();
            return;
        }
    }

    if (getRightmostChild(&pw.buf) == child_id) {
        if (h.cell_count > 0) {
            const last_off = getCellPtr(&pw.buf, h.cell_count - 1);
            const new_rightmost = std.mem.readInt(u32, pw.buf[last_off..][0..4], .little);
            setRightmostChild(&pw, new_rightmost);
            h.dead_bytes += 12;
            removeCellPtr(&pw, &h, h.cell_count - 1);
            writeBTreeHeader(&pw, h);
        }
        try pw.commit();
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
    var pw = try PageWriter.open(pager, leaf_id);
    const sr = leafSearch(&pw.buf, rowid);
    if (sr.found) {
        const cell = readLeafCell(&pw.buf, sr.cell_offset);
        if (cell.is_overflow) try overflow.freeChain(pager, cell.overflow_page);
    }
    const deleted = deleteFromLeaf(&pw, rowid);
    if (!deleted) return false;

    const h = readBTreeHeader(&pw.buf);
    if (h.cell_count == 0 and leaf_id != root_id) {
        try pager.freePage(leaf_id);
        if (depth >= 2) {
            try unlinkFromParent(pager, path[depth - 2], leaf_id);
        }
    } else {
        try pw.commit();
    }

    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn getCellRowid(buf: *const [t.PAGE_SIZE]u8, i: u16) u64 {
    return std.mem.readInt(u64, buf[getCellPtr(buf, i)..][0..8], .little);
}

test "insert and search in single leaf" {
    var pager = try InMemoryPager.create(std.testing.allocator);
    defer pager.close();
    const page_id = try pager.allocPage();
    var pw = PageWriter.init(&pager, page_id);
    initLeafPage(&pw, true);

    const row = [_]u8{ 0x01, 0x02, 0x03 };
    try leafInsert(&pw, .{ .rowid = 10, .row_data = &row, .is_overflow = false, .overflow_page = 0 });
    try leafInsert(&pw, .{ .rowid = 5, .row_data = &row, .is_overflow = false, .overflow_page = 0 });
    try leafInsert(&pw, .{ .rowid = 20, .row_data = &row, .is_overflow = false, .overflow_page = 0 });

    const h = readBTreeHeader(&pw.buf);
    try std.testing.expectEqual(h.cell_count, 3);

    try std.testing.expectEqual(getCellRowid(&pw.buf, 0), 5);
    try std.testing.expectEqual(getCellRowid(&pw.buf, 1), 10);
    try std.testing.expectEqual(getCellRowid(&pw.buf, 2), 20);

    const r = leafSearch(&pw.buf, 10);
    try std.testing.expect(r.found);
    try std.testing.expectEqual(r.cell_index, 1);

    const r2 = leafSearch(&pw.buf, 99);
    try std.testing.expect(!r2.found);
}

test "PageFull returned when no space remains" {
    var pager = try InMemoryPager.create(std.testing.allocator);
    defer pager.close();
    const page_id = try pager.allocPage();
    var pw = PageWriter.init(&pager, page_id);
    initLeafPage(&pw, true);

    // Each cell: 8 + 2 + 250 = 260 bytes + 2 ptr = 262 bytes.
    // Usable area: PAGE_SIZE(8192) - CELL_PTR_OFFSET(40) = 8152 bytes → ~31 cells fit.
    var row: [250]u8 = undefined;
    @memset(&row, 0xAB);
    var rowid: u64 = 1;
    while (true) : (rowid += 1) {
        leafInsert(&pw, .{ .rowid = rowid, .row_data = &row, .is_overflow = false, .overflow_page = 0 }) catch |err| {
            try std.testing.expectEqual(err, InsertError.PageFull);
            break;
        };
    }
}

test "compactPage reclaims dead bytes" {
    var pager = try InMemoryPager.create(std.testing.allocator);
    defer pager.close();
    const page_id = try pager.allocPage();
    var pw = PageWriter.init(&pager, page_id);
    initLeafPage(&pw, true);

    const row = [_]u8{0xAA} ** 10;
    try leafInsert(&pw, .{ .rowid = 1, .row_data = &row, .is_overflow = false, .overflow_page = 0 });
    try leafInsert(&pw, .{ .rowid = 2, .row_data = &row, .is_overflow = false, .overflow_page = 0 });
    try leafInsert(&pw, .{ .rowid = 3, .row_data = &row, .is_overflow = false, .overflow_page = 0 });

    // Simulate dead bytes by directly bumping the header field
    var h = readBTreeHeader(&pw.buf);
    h.dead_bytes = 100;
    writeBTreeHeader(&pw, h);

    compactPage(&pw, &h);

    try std.testing.expectEqual(h.dead_bytes, 0);
    // All 3 cells still readable in order
    try std.testing.expectEqual(getCellRowid(&pw.buf, 0), 1);
    try std.testing.expectEqual(getCellRowid(&pw.buf, 1), 2);
    try std.testing.expectEqual(getCellRowid(&pw.buf, 2), 3);
}

test "initLeafPage sets correct header" {
    var pager = try InMemoryPager.create(std.testing.allocator);
    defer pager.close();
    const page_id = try pager.allocPage();
    var pw = PageWriter.init(&pager, page_id);
    initLeafPage(&pw, true);

    const ph = std.mem.bytesToValue(t.PageHeader, pw.buf[0..@sizeOf(t.PageHeader)]);
    try std.testing.expectEqual(ph.page_type, .btree_leaf);

    const bh = readBTreeHeader(&pw.buf);
    try std.testing.expectEqual(bh.cell_count, 0);
    try std.testing.expectEqual(bh.free_end, t.PAGE_SIZE);
    try std.testing.expectEqual(bh.flags & BTREE_FLAG_ROWID_TREE, BTREE_FLAG_ROWID_TREE);
}

test "cell pointer insert and remove" {
    var pager = try InMemoryPager.create(std.testing.allocator);
    defer pager.close();
    const page_id = try pager.allocPage();
    var pw = PageWriter.init(&pager, page_id);
    initLeafPage(&pw, true);
    var h = readBTreeHeader(&pw.buf);

    insertCellPtr(&pw, &h, 0, 8000);
    insertCellPtr(&pw, &h, 1, 7900);
    insertCellPtr(&pw, &h, 0, 8100);

    try std.testing.expectEqual(getCellPtr(&pw.buf, 0), 8100);
    try std.testing.expectEqual(getCellPtr(&pw.buf, 1), 8000);
    try std.testing.expectEqual(getCellPtr(&pw.buf, 2), 7900);
    try std.testing.expectEqual(h.cell_count, 3);

    removeCellPtr(&pw, &h, 1);
    try std.testing.expectEqual(h.cell_count, 2);
    try std.testing.expectEqual(getCellPtr(&pw.buf, 1), 7900);
}

test "right-biased split keeps left page full" {
    const io = std.testing.io;
    const path = "/tmp/test_split_right.db";
    defer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};

    var pager = try DiskPager.create(std.testing.allocator, io, path, .{});
    defer pager.close();

    const page_id = try pager.allocPage();
    var pw = PageWriter.init(&pager, page_id);
    initLeafPage(&pw, true);

    var row: [100]u8 = undefined;
    @memset(&row, 0xAB);
    var rowid: u64 = 1;
    while (true) : (rowid += 1) {
        leafInsert(&pw, .{ .rowid = rowid, .row_data = &row, .is_overflow = false, .overflow_page = 0 }) catch break;
    }
    const left_count_before = readBTreeHeader(&pw.buf).cell_count;

    const new_cell = CellData{ .rowid = rowid, .row_data = &row, .is_overflow = false, .overflow_page = 0 };
    const result = try splitLeafRight(&pager, &pw, new_cell, true);

    try std.testing.expectEqual(readBTreeHeader(&pw.buf).cell_count, left_count_before);

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
    var pw = PageWriter.init(&pager, page_id);
    initLeafPage(&pw, true);

    var row: [100]u8 = undefined;
    @memset(&row, 0xAB);
    var rowid: u64 = 100;
    while (true) : (rowid += 100) {
        leafInsert(&pw, .{ .rowid = rowid, .row_data = &row, .is_overflow = false, .overflow_page = 0 }) catch break;
    }
    const total = readBTreeHeader(&pw.buf).cell_count;

    const new_cell = CellData{ .rowid = 150, .row_data = &row, .is_overflow = false, .overflow_page = 0 };
    const result = try splitLeafHalf(&pager, &pw, new_cell, true);

    var right_buf: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(result.right_page, &right_buf);

    const left_count = readBTreeHeader(&pw.buf).cell_count;
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
    var pw = PageWriter.init(&pager, root_id);
    initLeafPage(&pw, true);

    var row: [100]u8 = undefined;
    @memset(&row, 0xAB);
    var rowid: u64 = 1;
    while (true) : (rowid += 1) {
        leafInsert(&pw, .{ .rowid = rowid, .row_data = &row, .is_overflow = false, .overflow_page = 0 }) catch break;
    }

    const new_cell = CellData{ .rowid = rowid, .row_data = &row, .is_overflow = false, .overflow_page = 0 };
    try splitRoot(&pager, root_id, &pw.buf, new_cell, true);

    // splitRoot writes the new internal root to pager; read it back to verify.
    var root_check: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(root_id, &root_check);

    const ph = std.mem.bytesToValue(t.PageHeader, root_check[0..@sizeOf(t.PageHeader)]);
    try std.testing.expectEqual(ph.page_type, .btree_internal);

    const rh = readBTreeHeader(&root_check);
    try std.testing.expectEqual(rh.cell_count, 1);

    const left_child_id = std.mem.readInt(u32, root_check[getCellPtr(&root_check, 0)..][0..4], .little);
    const right_child_id = std.mem.readInt(u32, root_check[t.PAGE_SIZE - 4 ..][0..4], .little);

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
    var pw = PageWriter.init(&pager, root_id);
    initLeafPage(&pw, true);
    try pw.commit();

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
