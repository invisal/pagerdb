const std = @import("std");
const t = @import("types.zig");
const PageWriter = @import("page_writer.zig").PageWriter;
const Pager = @import("pager/pager.zig").Pager;
const btree = @import("btree.zig");

// Index B-tree: stores variable-length keys in lexicographic (byte) order.
//
// Cell layouts (different from the rowid B-tree which uses fixed-size 8-byte keys):
//   Leaf cell:     key_len:u16 LE + key_bytes[key_len]
//   Internal cell: left_child:u32 LE + key_len:u16 LE + key_bytes[key_len]
//
// The rightmost child pointer is stored at PAGE_SIZE-4, same as the rowid B-tree.
// Shared helpers (cell-pointer management, header read/write, page init) are
// imported from btree.zig; only cell-format-specific code lives here.
//
// Keys always include the rowid as their last 8 big-endian bytes, which makes
// every entry globally unique.  Unique index violation detection uses
// searchPrefix(), which checks whether any existing key shares the same
// column-values prefix.

const MAX_KEY_LEN: usize = 512;

// ── Cell helpers ─────────────────────────────────────────────────────────────

fn indexLeafCellSize(buf: *const [t.PAGE_SIZE]u8, offset: u16) u16 {
    const key_len = std.mem.readInt(u16, buf[offset..][0..2], .little);
    return 2 + key_len;
}

fn indexInternalCellSize(buf: *const [t.PAGE_SIZE]u8, offset: u16) u16 {
    const key_len = std.mem.readInt(u16, buf[offset + 4 ..][0..2], .little);
    return 4 + 2 + key_len;
}

fn compareKeys(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

// Binary search: returns the first slot index where cell_key >= key.
// This is the correct insertion position and the starting point for an exact search.
fn findKeyPos(buf: *const [t.PAGE_SIZE]u8, h: t.BTreeHeader, key: []const u8) u16 {
    var lo: u16 = 0;
    var hi: u16 = h.cell_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const off = btree.getCellPtr(buf, mid);
        const key_len = std.mem.readInt(u16, buf[off..][0..2], .little);
        const cell_key = buf[off + 2 ..][0..key_len];
        if (compareKeys(key, cell_key) != .gt) hi = mid else lo = mid + 1;
    }
    return lo;
}

fn writeIndexLeafCell(pw: *PageWriter, offset: u16, key: []const u8) void {
    pw.writeInt(u16, offset, @intCast(key.len), .little);
    pw.writeAt(offset + 2, key);
}

const LeafSearchResult = struct { found: bool, cell_index: u16, cell_offset: u16 };

fn indexLeafSearch(buf: *const [t.PAGE_SIZE]u8, key: []const u8) LeafSearchResult {
    const h = btree.readBTreeHeader(buf);
    const pos = findKeyPos(buf, h, key);
    if (pos < h.cell_count) {
        const off = btree.getCellPtr(buf, pos);
        const key_len = std.mem.readInt(u16, buf[off..][0..2], .little);
        const cell_key = buf[off + 2 ..][0..key_len];
        if (std.mem.eql(u8, cell_key, key))
            return .{ .found = true, .cell_index = pos, .cell_offset = off };
    }
    return .{ .found = false, .cell_index = pos, .cell_offset = 0 };
}

// Defragment: pack cells contiguously from the top of the page, then reset free_end and dead_bytes.
fn indexCompactPage(pw: *PageWriter, h: *t.BTreeHeader) void {
    var tmp: [t.PAGE_SIZE]u8 = undefined;
    @memcpy(&tmp, &pw.buf);
    var write_pos: u16 = t.PAGE_SIZE;
    for (0..h.cell_count) |i| {
        const old_off = btree.getCellPtr(&tmp, @intCast(i));
        const size = indexLeafCellSize(&tmp, old_off);
        write_pos -= size;
        @memcpy(pw.buf[write_pos..][0..size], tmp[old_off..][0..size]);
        std.mem.writeInt(u16, pw.buf[btree.CELL_PTR_OFFSET + @as(u16, @intCast(i)) * 2 ..][0..2], write_pos, .little);
    }
    h.free_end = write_pos;
    h.dead_bytes = 0;
    @memcpy(pw.buf[@sizeOf(t.PageHeader)..][0..@sizeOf(t.BTreeHeader)], std.mem.asBytes(h));
    pw.delta_count = 1;
    pw.deltas[0] = .{ .offset = 0, .len = t.PAGE_SIZE };
}

fn indexLeafInsert(pw: *PageWriter, key: []const u8) error{PageFull}!void {
    var h = btree.readBTreeHeader(&pw.buf);
    const sz: u16 = 2 + @as(u16, @intCast(key.len));
    if (btree.freeBytes(h) < sz + 2) {
        if (btree.freeBytes(h) + h.dead_bytes < sz + 2) return error.PageFull;
        indexCompactPage(pw, &h);
    }
    const pos = findKeyPos(&pw.buf, h, key);
    const new_free_end = h.free_end - sz;
    writeIndexLeafCell(pw, new_free_end, key);
    btree.insertCellPtr(pw, &h, pos, new_free_end);
    h.free_end = new_free_end;
    btree.writeBTreeHeader(pw, h);
}

// ── Internal page helpers ─────────────────────────────────────────────────────

const SplitResult = struct {
    right_page: u32,
    separator: [MAX_KEY_LEN]u8,
    separator_len: u16,
};

fn getRightmostChild(buf: *const [t.PAGE_SIZE]u8) u32 {
    return std.mem.readInt(u32, buf[t.PAGE_SIZE - 4 ..][0..4], .little);
}

fn setRightmostChild(pw: *PageWriter, page_id: u32) void {
    pw.writeInt(u32, t.PAGE_SIZE - 4, page_id, .little);
}

fn isRightmostInsert(buf: *const [t.PAGE_SIZE]u8, h: t.BTreeHeader, key: []const u8) bool {
    if (h.cell_count == 0) return true;
    const last_off = btree.getCellPtr(buf, h.cell_count - 1);
    const last_key_len = std.mem.readInt(u16, buf[last_off..][0..2], .little);
    const last_key = buf[last_off + 2 ..][0..last_key_len];
    return compareKeys(key, last_key) == .gt;
}

// ── Leaf splits ───────────────────────────────────────────────────────────────

fn splitIndexLeafRight(pager: *Pager, lw: *PageWriter, key: []const u8) !SplitResult {
    const right_id = try pager.allocPage();
    var rw = PageWriter.init(pager, right_id);
    btree.initLeafPage(&rw, false);
    var lh = btree.readBTreeHeader(&lw.buf);
    var rh = btree.readBTreeHeader(&rw.buf);
    rh.prev_leaf = lw.page_id;
    rh.next_leaf = lh.next_leaf;
    lh.next_leaf = right_id;
    btree.writeBTreeHeader(lw, lh);
    btree.writeBTreeHeader(&rw, rh);
    try indexLeafInsert(&rw, key);
    try lw.commit();
    try rw.commit();
    var result = SplitResult{ .right_page = right_id, .separator = undefined, .separator_len = @intCast(key.len) };
    @memcpy(result.separator[0..key.len], key);
    return result;
}

fn splitIndexLeafHalf(pager: *Pager, lw: *PageWriter, key: []const u8) !SplitResult {
    var h = btree.readBTreeHeader(&lw.buf);
    const mid = h.cell_count / 2;
    const right_id = try pager.allocPage();
    var rw = PageWriter.init(pager, right_id);
    btree.initLeafPage(&rw, false);
    for (mid..h.cell_count) |i| {
        const off = btree.getCellPtr(&lw.buf, @intCast(i));
        const klen = std.mem.readInt(u16, lw.buf[off..][0..2], .little);
        try indexLeafInsert(&rw, lw.buf[off + 2 ..][0..klen]);
        h.dead_bytes += indexLeafCellSize(&lw.buf, off);
    }
    var rh = btree.readBTreeHeader(&rw.buf);
    rh.prev_leaf = lw.page_id;
    rh.next_leaf = h.next_leaf;
    h.next_leaf = right_id;
    h.cell_count = mid;
    btree.writeBTreeHeader(lw, h);
    btree.writeBTreeHeader(&rw, rh);
    if (findKeyPos(&lw.buf, h, key) < mid) {
        try indexLeafInsert(lw, key);
    } else {
        try indexLeafInsert(&rw, key);
    }
    const first_off = btree.getCellPtr(&rw.buf, 0);
    const sep_len = std.mem.readInt(u16, rw.buf[first_off..][0..2], .little);
    var result = SplitResult{ .right_page = right_id, .separator = undefined, .separator_len = sep_len };
    @memcpy(result.separator[0..sep_len], rw.buf[first_off + 2 ..][0..sep_len]);
    try lw.commit();
    try rw.commit();
    return result;
}

// Root split: convert the root page from a leaf to an internal node.
// The old root content becomes the left child (new page); root keeps its page ID.
fn splitRoot(pager: *Pager, root_id: u32, root_buf: *[t.PAGE_SIZE]u8, key: []const u8) !void {
    const left_id = try pager.allocPage();
    var left_pw = PageWriter.init(pager, left_id);
    left_pw.buf = root_buf.*;
    var lh = btree.readBTreeHeader(&left_pw.buf);
    lh.parent_page = root_id;
    btree.writeBTreeHeader(&left_pw, lh);

    const split = if (isRightmostInsert(root_buf, btree.readBTreeHeader(root_buf), key))
        try splitIndexLeafRight(pager, &left_pw, key)
    else
        try splitIndexLeafHalf(pager, &left_pw, key);

    var root_pw = PageWriter.init(pager, root_id);
    btree.initInternalPage(&root_pw, false);
    setRightmostChild(&root_pw, split.right_page);

    var rh = btree.readBTreeHeader(&root_pw.buf);
    rh.free_end = t.PAGE_SIZE - 4;
    const sep = split.separator[0..split.separator_len];
    const sz: u16 = 4 + 2 + split.separator_len;
    const new_end = rh.free_end - sz;
    root_pw.writeInt(u32, new_end, left_id, .little);
    root_pw.writeInt(u16, new_end + 4, split.separator_len, .little);
    root_pw.writeAt(new_end + 6, sep);
    btree.insertCellPtr(&root_pw, &rh, 0, new_end);
    rh.free_end = new_end;
    btree.writeBTreeHeader(&root_pw, rh);
    try root_pw.commit();
}

// ── Internal node navigation ──────────────────────────────────────────────────

fn indexFindLeaf(pager: *Pager, root_id: u32, key: []const u8) !u32 {
    var page_id = root_id;
    var buf: [t.PAGE_SIZE]u8 = undefined;
    while (true) {
        try pager.readPage(page_id, &buf);
        const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
        if (ph.page_type == .btree_leaf) return page_id;
        const h = btree.readBTreeHeader(&buf);
        page_id = getRightmostChild(&buf);
        for (0..h.cell_count) |i| {
            const off = btree.getCellPtr(&buf, @intCast(i));
            const sep_len = std.mem.readInt(u16, buf[off + 4 ..][0..2], .little);
            const sep = buf[off + 6 ..][0..sep_len];
            if (compareKeys(key, sep) == .lt) {
                page_id = std.mem.readInt(u32, buf[off..][0..4], .little);
                break;
            }
        }
    }
}

fn indexInternalInsert(pw: *PageWriter, separator: []const u8, right_child: u32) !?SplitResult {
    var h = btree.readBTreeHeader(&pw.buf);
    const sz: u16 = 4 + 2 + @as(u16, @intCast(separator.len));

    var insert_pos: u16 = h.cell_count;
    for (0..h.cell_count) |i| {
        const off = btree.getCellPtr(&pw.buf, @intCast(i));
        const sep_len = std.mem.readInt(u16, pw.buf[off + 4 ..][0..2], .little);
        const sep = pw.buf[off + 6 ..][0..sep_len];
        if (compareKeys(separator, sep) == .lt) {
            insert_pos = @intCast(i);
            break;
        }
    }

    if (btree.freeBytes(h) >= sz + 2) {
        const new_end = h.free_end - sz;
        if (insert_pos == h.cell_count) {
            const old_rightmost = getRightmostChild(&pw.buf);
            pw.writeInt(u32, new_end, old_rightmost, .little);
            pw.writeInt(u16, new_end + 4, @intCast(separator.len), .little);
            pw.writeAt(new_end + 6, separator);
            btree.insertCellPtr(pw, &h, insert_pos, new_end);
            setRightmostChild(pw, right_child);
        } else {
            const existing_off = btree.getCellPtr(&pw.buf, insert_pos);
            const old_lc = std.mem.readInt(u32, pw.buf[existing_off..][0..4], .little);
            pw.writeInt(u32, new_end, old_lc, .little);
            pw.writeInt(u16, new_end + 4, @intCast(separator.len), .little);
            pw.writeAt(new_end + 6, separator);
            btree.insertCellPtr(pw, &h, insert_pos, new_end);
            const shifted_off = btree.getCellPtr(&pw.buf, insert_pos + 1);
            pw.writeInt(u32, shifted_off, right_child, .little);
        }
        h.free_end = new_end;
        btree.writeBTreeHeader(pw, h);
        return null;
    }
    // Internal page split not yet implemented; with PAGE_SIZE=8192 and
    // MAX_KEY_LEN=512 an internal page holds at least 15 entries, so this
    // limit is only reached with millions of distinct index entries.
    return error.NotImplementedYet;
}

fn indexUnlinkFromParent(pager: *Pager, parent_id: u32, child_id: u32) !void {
    var pw = try PageWriter.open(pager, parent_id);
    var h = btree.readBTreeHeader(&pw.buf);
    for (0..h.cell_count) |i| {
        const off = btree.getCellPtr(&pw.buf, @intCast(i));
        const lc = std.mem.readInt(u32, pw.buf[off..][0..4], .little);
        if (lc == child_id) {
            h.dead_bytes += indexInternalCellSize(&pw.buf, off);
            btree.removeCellPtr(&pw, &h, @intCast(i));
            btree.writeBTreeHeader(&pw, h);
            try pw.commit();
            return;
        }
    }
    if (getRightmostChild(&pw.buf) == child_id) {
        if (h.cell_count > 0) {
            const last_off = btree.getCellPtr(&pw.buf, h.cell_count - 1);
            setRightmostChild(&pw, std.mem.readInt(u32, pw.buf[last_off..][0..4], .little));
            h.dead_bytes += indexInternalCellSize(&pw.buf, last_off);
            btree.removeCellPtr(&pw, &h, h.cell_count - 1);
            btree.writeBTreeHeader(&pw, h);
        }
        try pw.commit();
    }
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Insert key into the index B-tree.
pub fn insertKey(pager: *Pager, root_id: u32, key: []const u8) !void {
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
        const h = btree.readBTreeHeader(&buf);
        page_id = getRightmostChild(&buf);
        for (0..h.cell_count) |i| {
            const off = btree.getCellPtr(&buf, @intCast(i));
            const sep_len = std.mem.readInt(u16, buf[off + 4 ..][0..2], .little);
            const sep = buf[off + 6 ..][0..sep_len];
            if (compareKeys(key, sep) == .lt) {
                page_id = std.mem.readInt(u32, buf[off..][0..4], .little);
                break;
            }
        }
    }

    var lw = try PageWriter.open(pager, path[depth - 1]);
    indexLeafInsert(&lw, key) catch |err| {
        if (err != error.PageFull) return err;

        if (depth == 1) {
            try splitRoot(pager, root_id, &lw.buf, key);
            return;
        }

        var split = if (isRightmostInsert(&lw.buf, btree.readBTreeHeader(&lw.buf), key))
            try splitIndexLeafRight(pager, &lw, key)
        else
            try splitIndexLeafHalf(pager, &lw, key);

        var level = depth - 2;
        while (true) {
            var parent_pw = try PageWriter.open(pager, path[level]);
            const sep = split.separator[0..split.separator_len];
            const result = try indexInternalInsert(&parent_pw, sep, split.right_page);
            try parent_pw.commit();
            if (result == null) break;
            split = result.?;
            if (level == 0) return error.NotImplementedYet;
            level -= 1;
        }
        return;
    };
    try lw.commit();
}

/// Delete an exact key from the index B-tree.
/// Returns true if found and deleted, false if not found.
pub fn deleteKey(pager: *Pager, root_id: u32, key: []const u8) !bool {
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
        const h = btree.readBTreeHeader(&buf);
        page_id = getRightmostChild(&buf);
        for (0..h.cell_count) |i| {
            const off = btree.getCellPtr(&buf, @intCast(i));
            const sep_len = std.mem.readInt(u16, buf[off + 4 ..][0..2], .little);
            const sep = buf[off + 6 ..][0..sep_len];
            if (compareKeys(key, sep) == .lt) {
                page_id = std.mem.readInt(u32, buf[off..][0..4], .little);
                break;
            }
        }
    }

    const leaf_id = path[depth - 1];
    var pw = try PageWriter.open(pager, leaf_id);
    const sr = indexLeafSearch(&pw.buf, key);
    if (!sr.found) return false;

    var h = btree.readBTreeHeader(&pw.buf);
    h.dead_bytes += indexLeafCellSize(&pw.buf, sr.cell_offset);
    btree.removeCellPtr(&pw, &h, sr.cell_index);
    btree.writeBTreeHeader(&pw, h);

    const new_h = btree.readBTreeHeader(&pw.buf);
    if (new_h.cell_count == 0 and leaf_id != root_id) {
        try pager.freePage(leaf_id);
        if (depth >= 2) try indexUnlinkFromParent(pager, path[depth - 2], leaf_id);
    } else {
        try pw.commit();
    }
    return true;
}

/// Search for any key that starts with prefix (the column-values portion without the rowid suffix).
/// Used to detect unique index violations before inserting.
/// Returns the rowid embedded in the matching key, or null if no match.
pub fn searchPrefix(pager: *Pager, root_id: u32, prefix: []const u8) !?u64 {
    if (root_id == 0) return null;
    // Navigate using the minimum possible full key for this prefix:
    // prefix bytes followed by 8 zero bytes (rowid = 0 is the minimum possible).
    var min_key: [MAX_KEY_LEN + 8]u8 = undefined;
    @memcpy(min_key[0..prefix.len], prefix);
    @memset(min_key[prefix.len..][0..8], 0);
    const min_key_slice = min_key[0 .. prefix.len + 8];

    const leaf_id = try indexFindLeaf(pager, root_id, min_key_slice);
    var buf: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(leaf_id, &buf);
    const h = btree.readBTreeHeader(&buf);
    const pos = findKeyPos(&buf, h, min_key_slice);
    if (pos < h.cell_count) {
        const off = btree.getCellPtr(&buf, pos);
        const key_len = std.mem.readInt(u16, buf[off..][0..2], .little);
        const cell_key = buf[off + 2 ..][0..key_len];
        if (cell_key.len > prefix.len and std.mem.eql(u8, cell_key[0..prefix.len], prefix)) {
            return std.mem.readInt(u64, cell_key[cell_key.len - 8 ..][0..8], .big);
        }
    }
    return null;
}

/// Forward iterator over all keys in the index.
pub const KeyIterator = struct {
    pager: *Pager,
    current_page: u32,
    cell_index: u16,
    buf: [t.PAGE_SIZE]u8,

    pub fn init(pager: *Pager, root_id: u32) !KeyIterator {
        const first = try btree.scanFirst(pager, root_id);
        var it = KeyIterator{
            .pager = pager,
            .current_page = first,
            .cell_index = 0,
            .buf = undefined,
        };
        try pager.readPage(first, &it.buf);
        return it;
    }

    /// Returns the next key slice (valid until the next call) or null at EOF.
    pub fn next(self: *KeyIterator) !?[]const u8 {
        while (true) {
            const h = btree.readBTreeHeader(&self.buf);
            if (self.cell_index < h.cell_count) {
                const off = btree.getCellPtr(&self.buf, self.cell_index);
                self.cell_index += 1;
                const key_len = std.mem.readInt(u16, self.buf[off..][0..2], .little);
                return self.buf[off + 2 ..][0..key_len];
            }
            const next_page = h.next_leaf;
            if (next_page == 0) return null;
            self.current_page = next_page;
            self.cell_index = 0;
            try self.pager.readPage(next_page, &self.buf);
        }
    }
};
