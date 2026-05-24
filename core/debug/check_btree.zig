const std = @import("std");
const t = @import("../types.zig");
const bs = @import("../btree_shared.zig");
const Pager = @import("../pager/pager.zig").Pager;
const print_page = @import("print_page.zig");

// Single comprehensive invariant checker for the B-tree.
// Call this from tests or the simulator instead of verifyTree.
//
// Invariants checked:
//
//   Per-page (checked on every visited page):
//     1. Page type is .btree_leaf or .btree_internal (never free/overflow).
//     2. freeStart(h) <= h.free_end <= cell_area_end.
//     3. Every cell offset is in [h.free_end, cell_area_end) and within its size.
//     4. No two cells overlap.
//     5. Within-page keys are strictly ascending (leaf and internal).
//
//   Tree structure (checked during the recursive descent):
//     6. Each non-root page's parent_page field matches the page that led to it.
//     7. No page appears more than once (catches shared subtrees and cycles).
//     8. Every key in a subtree falls strictly within the key range implied by
//        the separators on the path from the root (subtree bounds).
//
//   Leaf chain (checked in a separate linear pass):
//     9. prev/next pointers are bidirectionally consistent.
//    10. Last key of leaf N is strictly less than first key of leaf N+1.
//
// On any violation the offending page(s) are printed to stderr before the
// error is returned, so no extra diagnostic plumbing is needed by callers.

pub const CheckError = error{
    // Invariant 1
    UnexpectedPageType,
    // Invariant 2
    FreeEndAccountingWrong,
    // Invariants 3-4
    CellOffsetOutOfBounds,
    CellsOverlap,
    // Invariant 5
    LeafKeysNotAscending,
    InternalKeysNotAscending,
    // Invariant 6
    ParentPointerWrong,
    // Invariant 7
    PageVisitedTwice,
    // Invariant 8
    SubtreeBoundsViolation,
    // Invariant 9
    LeafChainLinkBroken,
    // Invariant 10
    CrossLeafKeyNotAscending,
};

// Key-range bounds threaded through the recursive descent.
// null means unbounded on that side.
// A key k in a subtree must satisfy: lo < k < hi.
fn Bounds(comptime Fmt: type) type {
    return struct {
        lo: ?Fmt.Key = null,
        hi: ?Fmt.Key = null,
    };
}

pub fn checkBtreeInvariant(
    comptime Fmt: type,
    alloc: std.mem.Allocator,
    pager: *Pager,
    root_id: u32,
) !void {
    var visited = std.AutoHashMap(u32, void).init(alloc);
    defer visited.deinit();

    try checkNode(Fmt, pager, root_id, 0, Bounds(Fmt){}, &visited);
    try checkLeafChain(Fmt, pager, root_id);
}

// ── Recursive descent ─────────────────────────────────────────────────────────

fn checkNode(
    comptime Fmt: type,
    pager: *Pager,
    page_id: u32,
    expected_parent: u32, // 0 = this is the root
    bounds: Bounds(Fmt),
    visited: *std.AutoHashMap(u32, void),
) anyerror!void {
    const put_result = try visited.getOrPut(page_id);
    if (put_result.found_existing) return CheckError.PageVisitedTwice;

    var buf: [t.PAGE_SIZE]u8 = undefined;
    try pager.readPage(page_id, &buf);

    const page_header = std.mem.bytesToValue(t.PageHeader, buf[0..@sizeOf(t.PageHeader)]);
    const btree_header = bs.readBTreeHeader(&buf);

    if (page_header.page_type != .btree_internal and page_header.page_type != .btree_leaf) {
        print_page.printPageHeader(pager, page_id);
        return CheckError.UnexpectedPageType;
    }

    if (expected_parent != 0 and btree_header.parent_page != expected_parent) {
        std.debug.print("  parent pointer: got={d}  expected={d}\n", .{ btree_header.parent_page, expected_parent });
        print_page.printPageHeader(pager, page_id);
        std.debug.print("  expected parent:\n", .{});
        print_page.printPageHeader(pager, expected_parent);
        return CheckError.ParentPointerWrong;
    }

    // checkPageLayout and checkLeafBounds don't know their page_id, so we catch
    // their errors here, print the page, and re-return.
    checkPageLayout(Fmt, &buf, btree_header, page_header.page_type) catch |err| {
        print_page.printPage(pager, page_id);
        return err;
    };

    if (page_header.page_type == .btree_leaf) {
        checkLeafBounds(Fmt, &buf, btree_header, bounds) catch |err| {
            print_page.printPage(pager, page_id);
            return err;
        };
    } else {
        try checkInternalNode(Fmt, pager, page_id, &buf, btree_header, bounds, visited);
    }
}

// ── Invariants 2-5: per-page layout and within-page key order ─────────────────

fn checkPageLayout(
    comptime Fmt: type,
    buf: *const [t.PAGE_SIZE]u8,
    btree_header: t.BTreeHeader,
    page_type: t.PageType,
) !void {
    // Internal pages reserve the last 4 bytes for the rightmost-child pointer.
    const cell_area_end: u16 = if (page_type == .btree_internal) t.PAGE_SIZE - 4 else t.PAGE_SIZE;

    // Invariant 2: free-region bounds sanity.
    if (bs.freeStart(btree_header) > btree_header.free_end or btree_header.free_end > cell_area_end) {
        return CheckError.FreeEndAccountingWrong;
    }

    // Invariants 3-4: cell offsets and overlaps.
    // We use a bit-map (1 bit per page byte, 1024 bytes on the stack) to detect
    // overlapping cells without heap allocation.  Marking a bit that is already
    // set means two cells claim the same byte.
    var used: [t.PAGE_SIZE / 8]u8 = @splat(0);

    for (0..btree_header.cell_count) |i| {
        const offset = bs.getCellPtr(buf, @intCast(i));
        const size: u16 = if (page_type == .btree_leaf)
            Fmt.leafCellSize(buf, offset)
        else
            Fmt.internalCellSize(buf, offset);

        // Invariant 3: cell must live entirely within [free_end, cell_area_end).
        if (offset < btree_header.free_end or
            @as(u32, offset) + @as(u32, size) > @as(u32, cell_area_end))
        {
            return CheckError.CellOffsetOutOfBounds;
        }

        // Invariant 4: mark bytes used; any byte already marked is an overlap.
        for (@as(usize, offset)..@as(usize, offset) + @as(usize, size)) |b| {
            const word = b / 8;
            const bit: u8 = @as(u8, 1) << @intCast(b % 8);
            if (used[word] & bit != 0) return CheckError.CellsOverlap;
            used[word] |= bit;
        }
    }

    // Invariant 5: within-page keys must be strictly ascending.
    if (btree_header.cell_count > 0) {
        if (page_type == .btree_leaf) {
            var prev_key = Fmt.leafGetKey(buf, bs.getCellPtr(buf, 0));
            for (1..btree_header.cell_count) |i| {
                const cur_key = Fmt.leafGetKey(buf, bs.getCellPtr(buf, @intCast(i)));
                if (Fmt.compareKeys(prev_key, cur_key) != .lt) return CheckError.LeafKeysNotAscending;
                prev_key = cur_key;
            }
        } else {
            var prev_key = Fmt.internalGetKey(buf, bs.getCellPtr(buf, 0));
            for (1..btree_header.cell_count) |i| {
                const cur_key = Fmt.internalGetKey(buf, bs.getCellPtr(buf, @intCast(i)));
                if (Fmt.compareKeys(prev_key, cur_key) != .lt) return CheckError.InternalKeysNotAscending;
                prev_key = cur_key;
            }
        }
    }
}

// ── Invariant 8 (leaf side): keys fall within inherited bounds ────────────────

fn checkLeafBounds(
    comptime Fmt: type,
    buf: *const [t.PAGE_SIZE]u8,
    h: t.BTreeHeader,
    bounds: Bounds(Fmt),
) !void {
    for (0..h.cell_count) |i| {
        const key = Fmt.leafGetKey(buf, bs.getCellPtr(buf, @intCast(i)));
        if (bounds.lo) |lo| {
            if (Fmt.compareKeys(key, lo) == .lt) return CheckError.SubtreeBoundsViolation;
        }
        if (bounds.hi) |hi| {
            if (Fmt.compareKeys(key, hi) != .lt) return CheckError.SubtreeBoundsViolation;
        }
    }
}

// ── Invariant 8 + recursion (internal side) ───────────────────────────────────

fn checkInternalNode(
    comptime Fmt: type,
    pager: *Pager,
    page_id: u32,
    buf: *const [t.PAGE_SIZE]u8,
    h: t.BTreeHeader,
    bounds: Bounds(Fmt),
    visited: *std.AutoHashMap(u32, void),
) anyerror!void {
    // For a page with N cells, the key ranges are:
    //   left_child[0]  => (bounds.lo,  key[0])
    //   left_child[1]  => (key[0],     key[1])
    //   ...
    //   left_child[N-1]=> (key[N-2],   key[N-1])
    //   rightmost      => (key[N-1],   bounds.hi)
    for (0..h.cell_count) |i| {
        const off = bs.getCellPtr(buf, @intCast(i));
        const child_lo: ?Fmt.Key = if (i == 0)
            bounds.lo
        else
            Fmt.internalGetKey(buf, bs.getCellPtr(buf, @intCast(i - 1)));
        const child_hi: ?Fmt.Key = Fmt.internalGetKey(buf, off);
        const left_child = Fmt.internalGetLeftChild(buf, off);
        try checkNode(Fmt, pager, left_child, page_id, .{ .lo = child_lo, .hi = child_hi }, visited);
    }

    const rm_lo: ?Fmt.Key = if (h.cell_count > 0)
        Fmt.internalGetKey(buf, bs.getCellPtr(buf, h.cell_count - 1))
    else
        bounds.lo;
    try checkNode(Fmt, pager, bs.getRightmostChild(buf), page_id, .{ .lo = rm_lo, .hi = bounds.hi }, visited);
}

// ── Invariants 9-10: leaf chain linear pass ───────────────────────────────────

fn checkLeafChain(comptime Fmt: type, pager: *Pager, root_id: u32) !void {
    var page_id = try bs.scanFirst(pager, root_id);
    var prev_id: u32 = 0;
    var buf: [t.PAGE_SIZE]u8 = undefined;
    var next_buf: [t.PAGE_SIZE]u8 = undefined;

    while (true) {
        try pager.readPage(page_id, &buf);
        const h = bs.readBTreeHeader(&buf);

        // Invariant 9: back-pointer must match the page we came from.
        if (h.prev_leaf != prev_id) {
            std.debug.print("  prev_leaf: got={d}  expected={d}\n", .{ h.prev_leaf, prev_id });
            print_page.printPageHeader(pager, page_id);
            return CheckError.LeafChainLinkBroken;
        }

        const next = h.next_leaf;
        if (next == 0) break;

        // Invariant 9: forward pointer of next must point back here.
        try pager.readPage(next, &next_buf);
        const next_h = bs.readBTreeHeader(&next_buf);
        if (next_h.prev_leaf != page_id) {
            std.debug.print("  next page {d} prev_leaf: got={d}  expected={d}\n", .{ next, next_h.prev_leaf, page_id });
            print_page.printPageHeader(pager, page_id);
            print_page.printPageHeader(pager, next);
            return CheckError.LeafChainLinkBroken;
        }

        // Invariant 10: last key of this page < first key of next page.
        if (h.cell_count > 0 and next_h.cell_count > 0) {
            const last_key = Fmt.leafGetKey(&buf, bs.getCellPtr(&buf, h.cell_count - 1));
            const first_key = Fmt.leafGetKey(&next_buf, bs.getCellPtr(&next_buf, 0));
            if (Fmt.compareKeys(last_key, first_key) != .lt) {
                print_page.printPage(pager, page_id);
                print_page.printPage(pager, next);
                return CheckError.CrossLeafKeyNotAscending;
            }
        }

        prev_id = page_id;
        page_id = next;
    }
}
