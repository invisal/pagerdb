const std = @import("std");
const t = @import("types.zig");
const PageWriter = @import("page_writer.zig").PageWriter;
const Pager = @import("pager/pager.zig").Pager;
const overflow = @import("overflow.zig");

// Generic B-tree parametrized by a cell-format module.
//
// Both the rowid table B-tree and the secondary index B-tree share identical
// structure: slotted pages, sorted cell arrays, rightmost-child pointer at
// PAGE_SIZE-4, path-recording descent, right-biased / half splits, and root
// promotion.  The only differences are how cells are laid out on the page and
// how keys are compared.  This file captures the shared skeleton once and lets
// callers choose a format at comptime.
//
// Usage:
//   const BT = BTree(MyFormat);
//   try BT.insert(&pager, root_id, payload);
//   const found = try BT.delete(&pager, root_id, key);
//   var it = try BT.ScanIterator.init(&pager, root_id);
//   while (try it.next()) |item| { ... }
//
// Format interface — the comptime Fmt argument must be a namespace exporting:
//
//   Types:
//     Key       — key type used for navigation and binary search
//     Payload   — value passed to insert (may differ from Key for rowid trees)
//     Separator — separator stored in internal cells; copyable/stack-allocatable
//     ScanItem  — item returned by ScanIterator.next
//
//   Comptime constants:
//     is_rowid: bool — passed to initLeafPage/initInternalPage for the flags field
//
//   Leaf operations:
//     fn leafCellSize(buf, offset) u16
//     fn leafGetKey(buf, offset) Key
//     fn leafPayloadSize(payload) u16
//     fn writeLeafCell(pw, offset, payload) void
//     fn readCellPayload(buf, offset) Payload   — used in splitLeafHalf to re-insert cells
//     fn readScanItem(buf, offset, page_id, slot_idx) ScanItem
//     fn payloadKey(payload) Key
//     fn payloadSeparator(payload) Separator    — separator for right-biased split
//     fn separatorKey(sep) Key                  — extract Key from Separator for comparisons
//     fn pageFirstSeparator(buf) Separator      — first cell's key; pushed up after half-split
//     fn compareKeys(a, b: Key) std.math.Order
//     fn isRightmostInsert(buf, h, key) bool
//     fn beforeDeleteCell(pager, buf, offset) anyerror!void  — e.g. frees overflow chains
//
//   Internal operations:
//     fn internalGetKey(buf, offset) Key
//     fn internalGetLeftChild(buf, offset) u32
//     fn internalCellSize(buf, offset) u16
//     fn internalSeparatorSize(sep) u16
//     fn writeInternalCell(pw, offset, left_child, sep) void

// ── Shared page-level helpers ─────────────────────────────────────────────────
// These are the same for every B-tree regardless of cell format.

pub const CELL_PTR_OFFSET: u16 = @sizeOf(t.PageHeader) + @sizeOf(t.BTreeHeader);
pub const BTREE_FLAG_ROWID_TREE: u16 = 1;

pub fn readBTreeHeader(buf: *const [t.PAGE_SIZE]u8) t.BTreeHeader {
    return std.mem.bytesToValue(t.BTreeHeader, buf[@sizeOf(t.PageHeader)..][0..@sizeOf(t.BTreeHeader)]);
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

pub fn getCellPtr(buf: *const [t.PAGE_SIZE]u8, i: u16) u16 {
    return std.mem.readInt(u16, buf[CELL_PTR_OFFSET + i * 2 ..][0..2], .little);
}

pub fn setCellPtr(pw: *PageWriter, i: u16, cell_offset: u16) void {
    pw.writeInt(u16, CELL_PTR_OFFSET + i * 2, cell_offset, .little);
}

pub fn insertCellPtr(pw: *PageWriter, h: *t.BTreeHeader, i: u16, cell_offset: u16) void {
    var j: u16 = h.cell_count;
    while (j > i) : (j -= 1) setCellPtr(pw, j, getCellPtr(&pw.buf, j - 1));
    setCellPtr(pw, i, cell_offset);
    h.cell_count += 1;
}

pub fn removeCellPtr(pw: *PageWriter, h: *t.BTreeHeader, i: u16) void {
    var j: u16 = i;
    while (j < h.cell_count - 1) : (j += 1) setCellPtr(pw, j, getCellPtr(&pw.buf, j + 1));
    h.cell_count -= 1;
}

pub fn initLeafPage(pw: *PageWriter, is_rowid: bool) void {
    pw.writeAt(0, std.mem.asBytes(&t.PageHeader{ .page_type = .btree_leaf, .flags = 0, .checksum = 0, .lsn = 0 }));
    writeBTreeHeader(pw, t.BTreeHeader{
        .cell_count = 0,
        .flags = if (is_rowid) BTREE_FLAG_ROWID_TREE else 0,
        .free_end = t.PAGE_SIZE,
        .dead_bytes = 0,
        .parent_page = 0,
        .prev_leaf = 0,
        .next_leaf = 0,
        ._pad = 0,
    });
}

pub fn initInternalPage(pw: *PageWriter, is_rowid: bool) void {
    pw.writeAt(0, std.mem.asBytes(&t.PageHeader{ .page_type = .btree_internal, .flags = 0, .checksum = 0, .lsn = 0 }));
    writeBTreeHeader(pw, t.BTreeHeader{
        .cell_count = 0,
        .flags = if (is_rowid) BTREE_FLAG_ROWID_TREE else 0,
        .free_end = t.PAGE_SIZE,
        .dead_bytes = 0,
        .parent_page = 0,
        .prev_leaf = 0,
        .next_leaf = 0,
        ._pad = 0,
    });
}

pub fn getRightmostChild(buf: *const [t.PAGE_SIZE]u8) u32 {
    return std.mem.readInt(u32, buf[t.PAGE_SIZE - 4 ..][0..4], .little);
}

pub fn setRightmostChild(pw: *PageWriter, page_id: u32) void {
    pw.writeInt(u32, t.PAGE_SIZE - 4, page_id, .little);
}

// Traverse to the leftmost leaf.  Used to initialise ScanIterator.
pub fn scanFirst(pager: *Pager, root_id: u32) !u32 {
    var page_id = root_id;
    var buf: [t.PAGE_SIZE]u8 = undefined;
    while (true) {
        try pager.readPage(page_id, &buf);
        const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
        if (ph.page_type == .btree_leaf) return page_id;
        const h = readBTreeHeader(&buf);
        // When all separator cells have been removed by unlinkFromParent but a
        // rightmost child still exists, follow that child to reach the remaining
        // subtree.  Without this, scanFirst would wrongly return the internal
        // node itself (cell_count == 0 was previously used as an "empty tree"
        // sentinel, but that only applies to root leaves, not internal nodes).
        if (h.cell_count == 0) {
            page_id = getRightmostChild(&buf);
        } else {
            page_id = std.mem.readInt(u32, buf[getCellPtr(&buf, 0)..][0..4], .little);
        }
    }
}

// ── Generic B-tree ────────────────────────────────────────────────────────────

pub fn BTree(comptime Fmt: type) type {
    return struct {
        const SplitResult = struct { right_page: u32, separator: Fmt.Separator };

        pub const LeafSearchResult = struct { found: bool, cell_index: u16, cell_offset: u16 };

        // ── Compaction ───────────────────────────────────────────────────────

        // Defragment a leaf page: pack all live cells contiguously from the top,
        // then reset free_end and dead_bytes.  Works for any format because it
        // uses Fmt.leafCellSize to determine each cell's byte footprint.
        fn compactLeaf(pw: *PageWriter, h: *t.BTreeHeader) void {
            var tmp: [t.PAGE_SIZE]u8 = undefined;
            @memcpy(&tmp, &pw.buf);
            var write_pos: u16 = t.PAGE_SIZE;
            for (0..h.cell_count) |i| {
                const old_off = getCellPtr(&tmp, @intCast(i));
                const size = Fmt.leafCellSize(&tmp, old_off);
                write_pos -= size;
                @memcpy(pw.buf[write_pos..][0..size], tmp[old_off..][0..size]);
                std.mem.writeInt(u16, pw.buf[CELL_PTR_OFFSET + @as(u16, @intCast(i)) * 2 ..][0..2], write_pos, .little);
            }
            h.free_end = write_pos;
            h.dead_bytes = 0;
            @memcpy(pw.buf[@sizeOf(t.PageHeader)..][0..@sizeOf(t.BTreeHeader)], std.mem.asBytes(h));
            pw.delta_count = 1;
            pw.deltas[0] = .{ .offset = 0, .len = t.PAGE_SIZE };
        }

        // ── Leaf binary search ───────────────────────────────────────────────

        // Returns the first slot index i such that cell[i].key >= key.
        // This is both the correct insertion position and the candidate for an exact match.
        pub fn findKeyPos(buf: *const [t.PAGE_SIZE]u8, h: t.BTreeHeader, key: Fmt.Key) u16 {
            var lo: u16 = 0;
            var hi: u16 = h.cell_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const off = getCellPtr(buf, mid);
                const cell_key = Fmt.leafGetKey(buf, off);
                if (Fmt.compareKeys(key, cell_key) != .gt) hi = mid else lo = mid + 1;
            }
            return lo;
        }

        pub fn leafSearch(buf: *const [t.PAGE_SIZE]u8, key: Fmt.Key) LeafSearchResult {
            const h = readBTreeHeader(buf);
            const pos = findKeyPos(buf, h, key);
            if (pos < h.cell_count) {
                const off = getCellPtr(buf, pos);
                if (Fmt.compareKeys(key, Fmt.leafGetKey(buf, off)) == .eq)
                    return .{ .found = true, .cell_index = pos, .cell_offset = off };
            }
            return .{ .found = false, .cell_index = pos, .cell_offset = 0 };
        }

        // ── Leaf insert (page-level) ─────────────────────────────────────────

        fn leafInsert(pw: *PageWriter, payload: Fmt.Payload) error{PageFull}!void {
            var h = readBTreeHeader(&pw.buf);
            const sz = Fmt.leafPayloadSize(payload);

            if (freeBytes(h) < sz + 2) {
                if (freeBytes(h) + h.dead_bytes < sz + 2) return error.PageFull;
                compactLeaf(pw, &h);
            }

            const key = Fmt.payloadKey(payload);
            const pos = findKeyPos(&pw.buf, h, key);
            const new_free_end = h.free_end - sz;
            Fmt.writeLeafCell(pw, new_free_end, payload);
            insertCellPtr(pw, &h, pos, new_free_end);
            h.free_end = new_free_end;
            writeBTreeHeader(pw, h);
        }

        // ── Internal node navigation ─────────────────────────────────────────

        // Descend from root to the leaf page that should contain key.
        pub fn findLeaf(pager: *Pager, root_id: u32, key: Fmt.Key) !u32 {
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
                    if (Fmt.compareKeys(key, Fmt.internalGetKey(&buf, off)) == .lt) {
                        page_id = Fmt.internalGetLeftChild(&buf, off);
                        break;
                    }
                }
            }
        }

        // ── Splits ───────────────────────────────────────────────────────────

        // Right-biased split: the new payload goes to a fresh right page, and the
        // left page keeps all existing cells.  Preferred when inserts are sequential
        // (append-only) because it maximises left-page utilisation.
        fn splitLeafRight(pager: *Pager, lw: *PageWriter, payload: Fmt.Payload) !SplitResult {
            const right_id = try pager.allocPage();
            var rw = PageWriter.init(pager, right_id);
            initLeafPage(&rw, Fmt.is_rowid);

            var lh = readBTreeHeader(&lw.buf);
            var rh = readBTreeHeader(&rw.buf);
            rh.prev_leaf = lw.page_id;
            rh.next_leaf = lh.next_leaf;
            lh.next_leaf = right_id;
            writeBTreeHeader(lw, lh);
            writeBTreeHeader(&rw, rh);

            try leafInsert(&rw, payload);
            try lw.commit();
            try rw.commit();

            return .{ .right_page = right_id, .separator = Fmt.payloadSeparator(payload) };
        }

        // 50/50 split: move the right half of left-page cells to a new right page,
        // insert the new payload in the correct half, then push the first key of the
        // right page up to the parent.  Used for non-sequential (random) inserts.
        fn splitLeafHalf(pager: *Pager, lw: *PageWriter, payload: Fmt.Payload) !SplitResult {
            var h = readBTreeHeader(&lw.buf);
            const mid = h.cell_count / 2;

            const right_id = try pager.allocPage();
            var rw = PageWriter.init(pager, right_id);
            initLeafPage(&rw, Fmt.is_rowid);

            // Move the upper half to rw; mark their space in lw as dead.
            for (mid..h.cell_count) |i| {
                const off = getCellPtr(&lw.buf, @intCast(i));
                try leafInsert(&rw, Fmt.readCellPayload(&lw.buf, off));
                h.dead_bytes += Fmt.leafCellSize(&lw.buf, off);
            }

            var rh = readBTreeHeader(&rw.buf);
            rh.prev_leaf = lw.page_id;
            rh.next_leaf = h.next_leaf;
            h.next_leaf = right_id;
            h.cell_count = mid;
            writeBTreeHeader(lw, h);
            writeBTreeHeader(&rw, rh);

            if (findKeyPos(&lw.buf, h, Fmt.payloadKey(payload)) < mid) {
                try leafInsert(lw, payload);
            } else {
                try leafInsert(&rw, payload);
            }

            // Capture separator before committing (it lives in rw.buf).
            const sep = Fmt.pageFirstSeparator(&rw.buf);
            try lw.commit();
            try rw.commit();

            return .{ .right_page = right_id, .separator = sep };
        }

        // Root split promotion: when the root leaf is full we keep the same root page
        // ID but convert it into an internal node, moving its old content to a new
        // left child.  This keeps all callers' root_id references stable.
        fn splitRoot(pager: *Pager, root_id: u32, root_buf: *[t.PAGE_SIZE]u8, payload: Fmt.Payload) !void {
            const left_id = try pager.allocPage();
            var left_pw = PageWriter.init(pager, left_id);
            left_pw.buf = root_buf.*;
            var lh = readBTreeHeader(&left_pw.buf);
            lh.parent_page = root_id;
            writeBTreeHeader(&left_pw, lh);

            const key = Fmt.payloadKey(payload);
            const split = if (Fmt.isRightmostInsert(root_buf, readBTreeHeader(root_buf), key))
                try splitLeafRight(pager, &left_pw, payload)
            else
                try splitLeafHalf(pager, &left_pw, payload);

            var root_pw = PageWriter.init(pager, root_id);
            initInternalPage(&root_pw, Fmt.is_rowid);
            setRightmostChild(&root_pw, split.right_page);

            var rh = readBTreeHeader(&root_pw.buf);
            rh.free_end = t.PAGE_SIZE - 4;
            const sz = Fmt.internalSeparatorSize(split.separator);
            const new_end = rh.free_end - sz;
            Fmt.writeInternalCell(&root_pw, new_end, left_id, split.separator);
            insertCellPtr(&root_pw, &rh, 0, new_end);
            rh.free_end = new_end;
            writeBTreeHeader(&root_pw, rh);
            try root_pw.commit();
        }

        // Insert a separator into an internal page, returning null on success or a
        // new SplitResult if the internal page itself overflowed.
        fn internalInsert(pager: *Pager, pw: *PageWriter, separator: Fmt.Separator, right_child: u32) !?SplitResult {
            var h = readBTreeHeader(&pw.buf);
            const cell_size = Fmt.internalSeparatorSize(separator);
            const sep_key = Fmt.separatorKey(separator);

            var insert_pos: u16 = h.cell_count;
            for (0..h.cell_count) |i| {
                const off = getCellPtr(&pw.buf, @intCast(i));
                if (Fmt.compareKeys(sep_key, Fmt.internalGetKey(&pw.buf, off)) == .lt) {
                    insert_pos = @intCast(i);
                    break;
                }
            }

            if (freeBytes(h) >= cell_size + 2) {
                const new_end = h.free_end - cell_size;

                if (insert_pos == h.cell_count) {
                    // New separator is rightmost: the old rightmost child becomes the
                    // left child of the new cell, and right_child becomes the new rightmost.
                    const old_rightmost = getRightmostChild(&pw.buf);
                    Fmt.writeInternalCell(pw, new_end, old_rightmost, separator);
                    insertCellPtr(pw, &h, insert_pos, new_end);
                    setRightmostChild(pw, right_child);
                } else {
                    // New separator splits an existing range: inherit the existing cell's
                    // left child, then redirect the existing cell's left child to right_child.
                    const existing_off = getCellPtr(&pw.buf, insert_pos);
                    const old_lc = Fmt.internalGetLeftChild(&pw.buf, existing_off);
                    Fmt.writeInternalCell(pw, new_end, old_lc, separator);
                    insertCellPtr(pw, &h, insert_pos, new_end);
                    pw.writeInt(u32, getCellPtr(&pw.buf, insert_pos + 1), right_child, .little);
                }

                h.free_end = new_end;
                writeBTreeHeader(pw, h);
                return null;
            }

            _ = pager;
            return error.NotImplementedYet;
        }

        // Remove a child pointer from a parent internal page when the child leaf becomes empty.
        // Remove child_id from parent_id's internal cell list or rightmost pointer.
        // Returns true when the parent ends up with no children at all (cell_count == 0
        // and it was the rightmost child) — the caller must then free the parent too.
        fn unlinkFromParent(pager: *Pager, parent_id: u32, child_id: u32) !bool {
            var pw = try PageWriter.open(pager, parent_id);
            var h = readBTreeHeader(&pw.buf);

            for (0..h.cell_count) |i| {
                const off = getCellPtr(&pw.buf, @intCast(i));
                if (Fmt.internalGetLeftChild(&pw.buf, off) == child_id) {
                    h.dead_bytes += Fmt.internalCellSize(&pw.buf, off);
                    removeCellPtr(&pw, &h, @intCast(i));
                    writeBTreeHeader(&pw, h);
                    try pw.commit();
                    return false;
                }
            }

            if (getRightmostChild(&pw.buf) == child_id) {
                if (h.cell_count > 0) {
                    const last_off = getCellPtr(&pw.buf, h.cell_count - 1);
                    setRightmostChild(&pw, Fmt.internalGetLeftChild(&pw.buf, last_off));
                    h.dead_bytes += Fmt.internalCellSize(&pw.buf, last_off);
                    removeCellPtr(&pw, &h, h.cell_count - 1);
                    writeBTreeHeader(&pw, h);
                    try pw.commit();
                    return false;
                }
                // cell_count == 0: parent had exactly one child (this one).
                // It is now completely empty — caller must free it.
                try pw.commit();
                return true;
            }

            return false;
        }

        // ── Public API ───────────────────────────────────────────────────────

        pub fn insert(pager: *Pager, root_id: u32, payload: Fmt.Payload) !void {
            const key = Fmt.payloadKey(payload);

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
                    if (Fmt.compareKeys(key, Fmt.internalGetKey(&buf, off)) == .lt) {
                        page_id = Fmt.internalGetLeftChild(&buf, off);
                        break;
                    }
                }
            }

            var lw = try PageWriter.open(pager, path[depth - 1]);
            leafInsert(&lw, payload) catch |err| {
                if (err != error.PageFull) return err;

                if (depth == 1) {
                    try splitRoot(pager, root_id, &lw.buf, payload);
                    return;
                }

                var split = if (Fmt.isRightmostInsert(&lw.buf, readBTreeHeader(&lw.buf), key))
                    try splitLeafRight(pager, &lw, payload)
                else
                    try splitLeafHalf(pager, &lw, payload);

                var level = depth - 2;
                while (true) {
                    var parent_pw = try PageWriter.open(pager, path[level]);
                    const result = try internalInsert(pager, &parent_pw, split.separator, split.right_page);
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

        pub fn delete(pager: *Pager, root_id: u32, key: Fmt.Key) !bool {
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
                    if (Fmt.compareKeys(key, Fmt.internalGetKey(&buf, off)) == .lt) {
                        page_id = Fmt.internalGetLeftChild(&buf, off);
                        break;
                    }
                }
            }

            const leaf_id = path[depth - 1];
            var pw = try PageWriter.open(pager, leaf_id);
            const sr = leafSearch(&pw.buf, key);
            if (!sr.found) return false;

            try Fmt.beforeDeleteCell(pager, &pw.buf, sr.cell_offset);
            var h = readBTreeHeader(&pw.buf);
            h.dead_bytes += Fmt.leafCellSize(&pw.buf, sr.cell_offset);
            removeCellPtr(&pw, &h, sr.cell_index);
            writeBTreeHeader(&pw, h);

            if (h.cell_count == 0 and leaf_id != root_id) {
                // Splice this leaf out of the doubly-linked leaf chain before
                // freeing it.  freePage() zeros the page, which would corrupt
                // next_leaf to 0; any predecessor whose next_leaf still pointed
                // here would then cause the scan iterator to miss all subsequent
                // leaves and/or read garbage cells.
                if (h.prev_leaf != 0) {
                    var prev_pw = try PageWriter.open(pager, h.prev_leaf);
                    var prev_h = readBTreeHeader(&prev_pw.buf);
                    prev_h.next_leaf = h.next_leaf;
                    writeBTreeHeader(&prev_pw, prev_h);
                    try prev_pw.commit();
                }
                if (h.next_leaf != 0) {
                    var next_pw = try PageWriter.open(pager, h.next_leaf);
                    var next_h = readBTreeHeader(&next_pw.buf);
                    next_h.prev_leaf = h.prev_leaf;
                    writeBTreeHeader(&next_pw, next_h);
                    try next_pw.commit();
                }
                try pager.freePage(leaf_id);

                // Walk up the path, freeing any internal node that has become
                // completely childless after its only child was freed.
                var freed_child = leaf_id;
                var level: usize = depth - 1; // path[level-1] is the parent to unlink from
                while (level >= 1) {
                    const parent_id = path[level - 1];
                    const childless = try unlinkFromParent(pager, parent_id, freed_child);
                    if (!childless) break;
                    if (parent_id == root_id) {
                        // The root lost its last child.  Convert it back to an
                        // empty leaf so the tree is in a valid empty state.
                        // Leaving it as an internal node with a dangling
                        // rightmost_child pointer would crash the next traversal.
                        var root_pw = try PageWriter.open(pager, root_id);
                        initLeafPage(&root_pw, Fmt.is_rowid);
                        try root_pw.commit();
                        break;
                    }
                    try pager.freePage(parent_id);
                    freed_child = parent_id;
                    level -= 1;
                }
            } else {
                try pw.commit();
            }
            return true;
        }

        pub fn lookup(pager: *Pager, root_id: u32, key: Fmt.Key) !?Fmt.ScanItem {
            const leaf_id = try findLeaf(pager, root_id, key);
            var buf: [t.PAGE_SIZE]u8 = undefined;
            try pager.readPage(leaf_id, &buf);
            const sr = leafSearch(&buf, key);
            if (!sr.found) return null;
            return Fmt.readScanItem(&buf, sr.cell_offset, leaf_id, sr.cell_index);
        }

        // Recursively free every page in the tree, including overflow chains on
        // leaf cells (via Fmt.beforeDeleteCell).  Call this before removing the
        // tree's root from the catalog so the pages are returned to the free list.
        pub fn freeTree(pager: *Pager, page_id: u32) !void {
            var buf: [t.PAGE_SIZE]u8 = undefined;
            try pager.readPage(page_id, &buf);
            const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
            const h = readBTreeHeader(&buf);

            if (ph.page_type == .btree_internal) {
                // Recurse into every child before freeing this internal page.
                for (0..h.cell_count) |i| {
                    const offset = getCellPtr(&buf, @intCast(i));
                    const child = Fmt.internalGetLeftChild(&buf, offset);
                    try freeTree(pager, child);
                }
                try freeTree(pager, getRightmostChild(&buf));
            } else {
                // Leaf: give the format a chance to clean up each cell (e.g. overflow chains).
                for (0..h.cell_count) |i| {
                    const offset = getCellPtr(&buf, @intCast(i));
                    try Fmt.beforeDeleteCell(pager, &buf, offset);
                }
            }

            try pager.freePage(page_id);
        }

        pub const ScanIterator = struct {
            pager: *Pager,
            current_page: u32,
            cell_index: u16,
            buf: [t.PAGE_SIZE]u8,

            pub fn init(pager: *Pager, root_id: u32) !ScanIterator {
                const first = try scanFirst(pager, root_id);
                var it = ScanIterator{ .pager = pager, .current_page = first, .cell_index = 0, .buf = undefined };
                try pager.readPage(first, &it.buf);
                return it;
            }

            pub fn next(self: *ScanIterator) !?Fmt.ScanItem {
                while (true) {
                    const h = readBTreeHeader(&self.buf);
                    if (self.cell_index < h.cell_count) {
                        const slot = self.cell_index;
                        const off = getCellPtr(&self.buf, self.cell_index);
                        self.cell_index += 1;
                        return Fmt.readScanItem(&self.buf, off, self.current_page, slot);
                    }
                    const next_page = h.next_leaf;
                    if (next_page == 0) return null;
                    self.current_page = next_page;
                    self.cell_index = 0;
                    try self.pager.readPage(next_page, &self.buf);
                }
            }
        };

        // ── Structural verification ──────────────────────────────────────────
        // Walk the entire tree and assert invariants.  Used by tests and the
        // deterministic simulator to catch corruption early.
        //
        // Invariants checked:
        //   1. Every leaf page has strictly ascending keys (no duplicates, sorted).
        //   2. Every internal page has strictly ascending separator keys.
        //   3. The leaf doubly-linked chain has consistent prev/next pointers.
        //   4. No cycles in the internal node graph (depth_limit check).

        pub const VerifyError = error{
            LeafKeysNotAscending,
            InternalKeysNotAscending,
            LeafChainLinkBroken,
            LeafChainCycle,
            TreeDepthExceeded,
        };

        pub fn verifyTree(pager: *Pager, root_id: u32) !void {
            try verifyNode(pager, root_id, pager.total_pages);
            try verifyLeafChain(pager, root_id);
        }

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
            var prev_key: ?Fmt.Key = null;
            for (0..h.cell_count) |i| {
                const off = getCellPtr(buf, @intCast(i));
                const key = Fmt.leafGetKey(buf, off);
                if (prev_key) |pk| {
                    if (Fmt.compareKeys(key, pk) != .gt) return VerifyError.LeafKeysNotAscending;
                }
                prev_key = key;
            }
        }

        fn verifyInternalPage(pager: *Pager, buf: *const [t.PAGE_SIZE]u8, depth_limit: u32) anyerror!void {
            const h = readBTreeHeader(buf);
            var prev_key: ?Fmt.Key = null;
            for (0..h.cell_count) |i| {
                const off = getCellPtr(buf, @intCast(i));
                const left_child = Fmt.internalGetLeftChild(buf, off);
                const key = Fmt.internalGetKey(buf, off);
                if (prev_key) |pk| {
                    if (Fmt.compareKeys(key, pk) != .gt) return VerifyError.InternalKeysNotAscending;
                }
                try verifyNode(pager, left_child, depth_limit);
                prev_key = key;
            }
            const rightmost = getRightmostChild(buf);
            try verifyNode(pager, rightmost, depth_limit);
        }

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
    };
}

// ── Rowid B-tree format ───────────────────────────────────────────────────────
// Leaf cell:     [rowid:u64 LE][row_len:u16 LE (high bit = overflow)][row_data OR overflow_page:u32]
// Internal cell: [left_child:u32 LE][separator_rowid:u64 LE]  — fixed 12 bytes

pub const CellData = struct {
    rowid: u64,
    row_data: []const u8,
    is_overflow: bool,
    overflow_page: u32,
    overflow_len: usize = 0,
    page_id: u32 = 0,
    slot_idx: u16 = 0,
};

pub const RowidFormat = struct {
    pub const Key = u64;
    pub const Payload = CellData;
    pub const Separator = u64;
    pub const ScanItem = CellData;
    pub const is_rowid = true;

    pub fn leafCellSize(buf: *const [t.PAGE_SIZE]u8, offset: u16) u16 {
        const row_len = std.mem.readInt(u16, buf[offset + 8 ..][0..2], .little);
        if (row_len & 0x8000 != 0) return 8 + 2 + 4;
        return 8 + 2 + (row_len & 0x7FFF);
    }

    pub fn leafGetKey(buf: *const [t.PAGE_SIZE]u8, offset: u16) u64 {
        return std.mem.readInt(u64, buf[offset..][0..8], .little);
    }

    pub fn leafPayloadSize(cell: CellData) u16 {
        if (cell.is_overflow) return 8 + 2 + 4;
        return @intCast(8 + 2 + cell.row_data.len);
    }

    pub fn writeLeafCell(pw: *PageWriter, offset: u16, cell: CellData) void {
        pw.writeInt(u64, offset, cell.rowid, .little);
        if (cell.is_overflow) {
            pw.writeInt(u16, offset + 8, 0x8000 | @as(u16, @intCast(cell.row_data.len)), .little);
            pw.writeInt(u32, offset + 10, cell.overflow_page, .little);
        } else {
            pw.writeInt(u16, offset + 8, @intCast(cell.row_data.len), .little);
            pw.writeAt(offset + 10, cell.row_data);
        }
    }

    pub fn readCellPayload(buf: *const [t.PAGE_SIZE]u8, offset: u16) CellData {
        const rowid = std.mem.readInt(u64, buf[offset..][0..8], .little);
        const raw_len = std.mem.readInt(u16, buf[offset + 8 ..][0..2], .little);
        const is_ov = (raw_len & 0x8000) != 0;
        const data_len: u16 = raw_len & 0x7FFF;
        if (is_ov) {
            return .{
                .rowid = rowid,
                .row_data = &.{},
                .is_overflow = true,
                .overflow_page = std.mem.readInt(u32, buf[offset + 10 ..][0..4], .little),
                .overflow_len = data_len,
            };
        }
        return .{ .rowid = rowid, .row_data = buf[offset + 10 ..][0..data_len], .is_overflow = false, .overflow_page = 0 };
    }

    pub fn readScanItem(buf: *const [t.PAGE_SIZE]u8, offset: u16, page_id: u32, slot_idx: u16) CellData {
        var cell = readCellPayload(buf, offset);
        cell.page_id = page_id;
        cell.slot_idx = slot_idx;
        return cell;
    }

    pub fn payloadKey(cell: CellData) u64 {
        return cell.rowid;
    }
    pub fn payloadSeparator(cell: CellData) u64 {
        return cell.rowid;
    }
    pub fn separatorKey(sep: u64) u64 {
        return sep;
    }

    pub fn pageFirstSeparator(buf: *const [t.PAGE_SIZE]u8) u64 {
        return std.mem.readInt(u64, buf[getCellPtr(buf, 0)..][0..8], .little);
    }

    pub fn compareKeys(a: u64, b: u64) std.math.Order {
        return std.math.order(a, b);
    }

    pub fn isRightmostInsert(buf: *const [t.PAGE_SIZE]u8, h: t.BTreeHeader, key: u64) bool {
        if (h.cell_count == 0) return true;
        return key > std.mem.readInt(u64, buf[getCellPtr(buf, h.cell_count - 1)..][0..8], .little);
    }

    pub fn internalGetKey(buf: *const [t.PAGE_SIZE]u8, offset: u16) u64 {
        return std.mem.readInt(u64, buf[offset + 4 ..][0..8], .little);
    }

    pub fn internalGetLeftChild(buf: *const [t.PAGE_SIZE]u8, offset: u16) u32 {
        return std.mem.readInt(u32, buf[offset..][0..4], .little);
    }

    pub fn internalCellSize(_: *const [t.PAGE_SIZE]u8, _: u16) u16 {
        return 12;
    }
    pub fn internalSeparatorSize(_: u64) u16 {
        return 12;
    }

    pub fn writeInternalCell(pw: *PageWriter, offset: u16, left_child: u32, sep: u64) void {
        pw.writeInt(u32, offset, left_child, .little);
        pw.writeInt(u64, offset + 4, sep, .little);
    }

    pub fn beforeDeleteCell(pager: *Pager, buf: *const [t.PAGE_SIZE]u8, offset: u16) anyerror!void {
        const cell = readCellPayload(buf, offset);
        if (cell.is_overflow) try overflow.freeChain(pager, cell.overflow_page);
    }
};

// ── Index B-tree format ───────────────────────────────────────────────────────
// Leaf cell:     [key_len:u16 LE][key_bytes:key_len]
// Internal cell: [left_child:u32 LE][key_len:u16 LE][key_bytes:key_len]

pub const MAX_KEY_LEN: usize = 512;

// Separator is a copy of the key bytes so it lives on the stack during splits.
pub const IndexSeparator = struct { bytes: [MAX_KEY_LEN]u8, len: u16 };

pub const IndexFormat = struct {
    pub const Key = []const u8;
    pub const Payload = []const u8;
    pub const Separator = IndexSeparator;
    pub const ScanItem = []const u8;
    pub const is_rowid = false;

    pub fn leafCellSize(buf: *const [t.PAGE_SIZE]u8, offset: u16) u16 {
        return 2 + std.mem.readInt(u16, buf[offset..][0..2], .little);
    }

    pub fn leafGetKey(buf: *const [t.PAGE_SIZE]u8, offset: u16) []const u8 {
        const key_len = std.mem.readInt(u16, buf[offset..][0..2], .little);
        return buf[offset + 2 ..][0..key_len];
    }

    pub fn leafPayloadSize(key: []const u8) u16 {
        return 2 + @as(u16, @intCast(key.len));
    }

    pub fn writeLeafCell(pw: *PageWriter, offset: u16, key: []const u8) void {
        pw.writeInt(u16, offset, @intCast(key.len), .little);
        pw.writeAt(offset + 2, key);
    }

    pub fn readCellPayload(buf: *const [t.PAGE_SIZE]u8, offset: u16) []const u8 {
        return leafGetKey(buf, offset);
    }

    pub fn readScanItem(buf: *const [t.PAGE_SIZE]u8, offset: u16, _: u32, _: u16) []const u8 {
        return leafGetKey(buf, offset);
    }

    pub fn payloadKey(key: []const u8) []const u8 {
        return key;
    }

    pub fn payloadSeparator(key: []const u8) IndexSeparator {
        var sep = IndexSeparator{ .bytes = undefined, .len = @intCast(key.len) };
        @memcpy(sep.bytes[0..key.len], key);
        return sep;
    }

    pub fn separatorKey(sep: IndexSeparator) []const u8 {
        return sep.bytes[0..sep.len];
    }

    pub fn pageFirstSeparator(buf: *const [t.PAGE_SIZE]u8) IndexSeparator {
        const off = getCellPtr(buf, 0);
        const key_len = std.mem.readInt(u16, buf[off..][0..2], .little);
        var sep = IndexSeparator{ .bytes = undefined, .len = key_len };
        @memcpy(sep.bytes[0..key_len], buf[off + 2 ..][0..key_len]);
        return sep;
    }

    pub fn compareKeys(a: []const u8, b: []const u8) std.math.Order {
        return std.mem.order(u8, a, b);
    }

    pub fn isRightmostInsert(buf: *const [t.PAGE_SIZE]u8, h: t.BTreeHeader, key: []const u8) bool {
        if (h.cell_count == 0) return true;
        const last_off = getCellPtr(buf, h.cell_count - 1);
        const last_len = std.mem.readInt(u16, buf[last_off..][0..2], .little);
        return std.mem.order(u8, key, buf[last_off + 2 ..][0..last_len]) == .gt;
    }

    pub fn internalGetKey(buf: *const [t.PAGE_SIZE]u8, offset: u16) []const u8 {
        const key_len = std.mem.readInt(u16, buf[offset + 4 ..][0..2], .little);
        return buf[offset + 6 ..][0..key_len];
    }

    pub fn internalGetLeftChild(buf: *const [t.PAGE_SIZE]u8, offset: u16) u32 {
        return std.mem.readInt(u32, buf[offset..][0..4], .little);
    }

    pub fn internalCellSize(buf: *const [t.PAGE_SIZE]u8, offset: u16) u16 {
        return 4 + 2 + std.mem.readInt(u16, buf[offset + 4 ..][0..2], .little);
    }

    pub fn internalSeparatorSize(sep: IndexSeparator) u16 {
        return 4 + 2 + sep.len;
    }

    pub fn writeInternalCell(pw: *PageWriter, offset: u16, left_child: u32, sep: IndexSeparator) void {
        pw.writeInt(u32, offset, left_child, .little);
        pw.writeInt(u16, offset + 4, sep.len, .little);
        pw.writeAt(offset + 6, sep.bytes[0..sep.len]);
    }

    pub fn beforeDeleteCell(_: *Pager, _: *const [t.PAGE_SIZE]u8, _: u16) anyerror!void {}
};

// ── Concrete tree types ───────────────────────────────────────────────────────

pub const RowidBTree = BTree(RowidFormat);
pub const IndexBTree = BTree(IndexFormat);

// ── Rowid-tree helpers not in the generic ─────────────────────────────────────

// Walk rightmost children to find the largest rowid in the tree.
pub fn maxRowid(pager: *Pager, root_id: u32) !?u64 {
    var page_id = root_id;
    var buf: [t.PAGE_SIZE]u8 = undefined;
    while (true) {
        try pager.readPage(page_id, &buf);
        const ph = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
        if (ph.page_type == .btree_leaf) {
            const h = readBTreeHeader(&buf);
            if (h.cell_count == 0) return null;
            return std.mem.readInt(u64, buf[getCellPtr(&buf, h.cell_count - 1)..][0..8], .little);
        }
        page_id = getRightmostChild(&buf);
    }
}

// Insert a row into a rowid tree, building an overflow chain when the row
// exceeds OVERFLOW_THRESHOLD.  This is the primary entry point for callers
// that have raw row bytes; RowidBTree.insert takes a pre-built CellData.
pub fn insertRow(pager: *Pager, root_id: u32, rowid: u64, row_data: []const u8) !void {
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
    return RowidBTree.insert(pager, root_id, cell);
}

// Lookup a cell by rowid, reading the leaf page into a caller-provided buffer.
// row_data in the returned CellData is a slice into buf, so buf must remain
// alive for as long as row_data is used.
pub fn lookupCell(pager: *Pager, root_id: u32, rowid: u64, buf: *[t.PAGE_SIZE]u8) !?CellData {
    const leaf_id = try RowidBTree.findLeaf(pager, root_id, rowid);
    try pager.readPage(leaf_id, buf);
    const sr = RowidBTree.leafSearch(buf, rowid);
    if (!sr.found) return null;
    return RowidFormat.readCellPayload(buf, sr.cell_offset);
}

// Read a rowid-tree leaf cell from a page buffer at the given byte offset.
pub fn readLeafCell(buf: *const [t.PAGE_SIZE]u8, offset: u16) CellData {
    return RowidFormat.readCellPayload(buf, offset);
}

// Retrieve a row by rowid, decoding overflow chains if needed.
pub fn lookupRow(pager: *Pager, root_id: u32, rowid: u64, allocator: std.mem.Allocator) !?[]u8 {
    var buf: [t.PAGE_SIZE]u8 = undefined;
    const cell = try lookupCell(pager, root_id, rowid, &buf) orelse return null;
    if (cell.is_overflow) {
        const out = try allocator.alloc(u8, cell.overflow_len);
        errdefer allocator.free(out);
        try overflow.readChain(pager, cell.overflow_page, cell.overflow_len, out);
        return out;
    }
    return try allocator.dupe(u8, cell.row_data);
}

// ── Index-tree helpers not in the generic ────────────────────────────────────

// Search for any key that starts with prefix (the column-values portion without
// the rowid suffix appended for non-unique entries).  Used to detect unique
// index violations.  Returns the rowid embedded in the matching key, or null.
pub fn searchPrefix(pager: *Pager, root_id: u32, prefix: []const u8) !?u64 {
    if (root_id == 0) return null;
    // Navigate with the minimum full key for this prefix: prefix + 8 zero bytes.
    // Because rowid 0 is the smallest possible rowid, this finds the first entry
    // whose column values are >= prefix.
    var min_key: [MAX_KEY_LEN + 8]u8 = undefined;
    @memcpy(min_key[0..prefix.len], prefix);
    @memset(min_key[prefix.len..][0..8], 0);
    const min_key_slice = min_key[0 .. prefix.len + 8];

    const leaf_id = try IndexBTree.findLeaf(pager, root_id, min_key_slice);
    var buf: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(leaf_id, &buf);
    const h = readBTreeHeader(&buf);
    const pos = IndexBTree.findKeyPos(&buf, h, min_key_slice);
    if (pos < h.cell_count) {
        const off = getCellPtr(&buf, pos);
        const key_len = std.mem.readInt(u16, buf[off..][0..2], .little);
        const cell_key = buf[off + 2 ..][0..key_len];
        if (cell_key.len > prefix.len and std.mem.eql(u8, cell_key[0..prefix.len], prefix)) {
            return std.mem.readInt(u64, cell_key[cell_key.len - 8 ..][0..8], .big);
        }
    }
    return null;
}
