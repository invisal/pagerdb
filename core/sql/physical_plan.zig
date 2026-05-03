const std = @import("std");
const lp = @import("logical_plan.zig");
const catalog = @import("../catalog.zig");
const vtab_mod = @import("../vtable/root.zig");

// ── Physical plan types ────────────────────────────────────────────────────────

pub const PhysicalSeqScan = struct {
    table: []const u8,
    schema: lp.Schema,
};

pub const PhysicalPointLookup = struct {
    table: []const u8,
    rowid: u64,
    schema: lp.Schema,
};

pub const PhysicalFilter = struct {
    input: PhysicalPlan,
    predicate: lp.Expr,
    schema: lp.Schema,
};

pub const PhysicalProject = struct {
    input: PhysicalPlan,
    col_indices: []usize,
    schema: lp.Schema,
};

pub const PhysicalInsert = struct {
    table: []const u8,
    values: []lp.Expr,
    schema: lp.Schema,
};

pub const PhysicalUpdate = struct {
    table: []const u8,
    input: *PhysicalPlan,
    assignments: []lp.LogicalUpdate.Assignment,
    schema: lp.Schema,
};

pub const PhysicalDelete = struct {
    table: []const u8,
    input: *PhysicalPlan,
    schema: lp.Schema,
};

pub const PhysicalVTabScan = struct {
    vtab: *const vtab_mod.VTab,
    args: []const i64,
    schema: lp.Schema,
};

pub const PhysicalCreateTable = struct {
    table: []const u8,
    columns: []catalog.ColumnMeta,
};

pub const PhysicalPlan = union(enum) {
    seq_scan: PhysicalSeqScan,
    vtab_scan: PhysicalVTabScan,
    point_lookup: PhysicalPointLookup,
    filter: *PhysicalFilter,
    project: *PhysicalProject,
    insert: PhysicalInsert,
    update: PhysicalUpdate,
    delete: PhysicalDelete,
    create_table: PhysicalCreateTable,
    begin: void,
    commit: void,
    rollback: void,

    pub fn schema(self: PhysicalPlan) lp.Schema {
        return switch (self) {
            .seq_scan => |n| n.schema,
            .vtab_scan => |n| n.schema,
            .point_lookup => |n| n.schema,
            .filter => |n| n.schema,
            .project => |n| n.schema,
            .insert => |n| n.schema,
            .update => |n| n.schema,
            .delete => |n| n.schema,
            .create_table, .begin, .commit, .rollback => lp.Schema{ .table = "", .columns = &.{} },
        };
    }
};

// ── Planner ────────────────────────────────────────────────────────────────────

pub const PhysicalPlanner = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) PhysicalPlanner {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *PhysicalPlanner) void {
        self.arena.deinit();
    }

    fn alloc(self: *PhysicalPlanner) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn plan(self: *PhysicalPlanner, logical: lp.LogicalPlan) error{OutOfMemory}!PhysicalPlan {
        return switch (logical) {
            .seq_scan => |n| .{ .seq_scan = .{ .table = n.table, .schema = n.schema } },
            .vtab_scan => |n| .{ .vtab_scan = .{ .vtab = n.vtab, .args = n.args, .schema = n.schema } },
            .filter => |n| try self.planFilter(n),
            .project => |n| try self.planProject(n),
            .insert => |n| .{ .insert = .{ .table = n.table, .values = n.values, .schema = n.schema } },
            .update => |n| try self.planUpdate(n),
            .delete => |n| try self.planDelete(n),
            .create_table => |n| .{ .create_table = .{ .table = n.table, .columns = n.columns } },
            .begin => .{ .begin = {} },
            .commit => .{ .commit = {} },
            .rollback => .{ .rollback = {} },
        };
    }

    fn planFilter(self: *PhysicalPlanner, node: *lp.Filter) !PhysicalPlan {
        if (node.input.* == .seq_scan) {
            if (extractRowidEq(node.predicate)) |rowid_val| {
                return .{ .point_lookup = .{
                    .table = node.input.seq_scan.table,
                    .rowid = rowid_val,
                    .schema = node.schema,
                } };
            }
        }
        const phys_input = try self.alloc().create(PhysicalPlan);
        phys_input.* = try self.plan(node.input.*);
        const filter_node = try self.alloc().create(PhysicalFilter);
        filter_node.* = .{
            .input = phys_input.*,
            .predicate = node.predicate,
            .schema = node.schema,
        };
        return .{ .filter = filter_node };
    }

    fn planProject(self: *PhysicalPlanner, node: *lp.Project) !PhysicalPlan {
        const phys_input = try self.alloc().create(PhysicalPlan);
        phys_input.* = try self.plan(node.input.*);
        const proj = try self.alloc().create(PhysicalProject);
        proj.* = .{
            .input = phys_input.*,
            .col_indices = node.col_indices,
            .schema = node.schema,
        };
        return .{ .project = proj };
    }

    fn planUpdate(self: *PhysicalPlanner, node: lp.LogicalUpdate) !PhysicalPlan {
        const phys_input = try self.alloc().create(PhysicalPlan);
        phys_input.* = try self.plan(node.input.*);
        return .{ .update = .{
            .table = node.table,
            .input = phys_input,
            .assignments = node.assignments,
            .schema = node.schema,
        } };
    }

    fn planDelete(self: *PhysicalPlanner, node: lp.LogicalDelete) !PhysicalPlan {
        const phys_input = try self.alloc().create(PhysicalPlan);
        phys_input.* = try self.plan(node.input.*);
        return .{ .delete = .{
            .table = node.table,
            .input = phys_input,
            .schema = node.schema,
        } };
    }
};

// Optimization: detect "rowid = N" or "N = rowid" patterns in the WHERE clause.
// When found, the physical planner replaces SeqScan+Filter with PointLookup,
// which uses btree.lookup() directly.  This is O(log n) vs O(n) and avoids
// allocating a row buffer for every row in the table.
fn extractRowidEq(expr: lp.Expr) ?u64 {
    if (expr != .binary) return null;
    const b = expr.binary;
    if (b.op != .eq) return null;
    if (b.left == .col_idx and b.left.col_idx == lp.ROWID_SENTINEL and b.right == .int_lit)
        return @intCast(b.right.int_lit);
    if (b.right == .col_idx and b.right.col_idx == lp.ROWID_SENTINEL and b.left == .int_lit)
        return @intCast(b.left.int_lit);
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const Pager = @import("../pager/pager.zig").Pager;
const DiskPager = @import("../pager/disk.zig").DiskPager;
const Parser = @import("parser.zig").Parser;
const Dir = std.Io.Dir;

const DbHandle = struct {
    pager: *Pager,
    cat: catalog.Catalog,
    alloc: std.mem.Allocator,

    fn deinit(self: *DbHandle) void {
        self.pager.flush() catch {};
        self.pager.close();
        self.alloc.destroy(self.pager);
        self.cat.deinit();
    }
};

fn makeDb(
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

fn makePlan(
    src: []const u8,
    alloc: std.mem.Allocator,
    lp_out: *lp.LogicalPlanner,
    pp_out: *PhysicalPlanner,
) !PhysicalPlan {
    var parsed = try Parser.parse(src, alloc);
    defer parsed.deinit();
    const logical = try lp_out.plan(parsed.stmt);
    return pp_out.plan(logical);
}

test "SeqScan stays as SeqScan" {
    const io = std.testing.io;
    const path = "/tmp/test_pp_seqscan.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "x", .col_type = .int, .nullable = false },
    });

    var lplanner = lp.LogicalPlanner.init(&db.cat, alloc);
    defer lplanner.deinit();
    var pplanner = PhysicalPlanner.init(alloc);
    defer pplanner.deinit();

    const pp = try makePlan("SELECT * FROM t", alloc, &lplanner, &pplanner);
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).seq_scan, std.meta.activeTag(pp));
    try std.testing.expectEqualStrings("t", pp.seq_scan.table);
}

test "Filter over SeqScan becomes PhysicalFilter" {
    const io = std.testing.io;
    const path = "/tmp/test_pp_filter.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "score", .col_type = .int, .nullable = false },
    });

    var lplanner = lp.LogicalPlanner.init(&db.cat, alloc);
    defer lplanner.deinit();
    var pplanner = PhysicalPlanner.init(alloc);
    defer pplanner.deinit();

    const pp = try makePlan("SELECT * FROM t WHERE score > 5", alloc, &lplanner, &pplanner);
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).filter, std.meta.activeTag(pp));
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).seq_scan, std.meta.activeTag(pp.filter.input));
}

test "rowid equality filter becomes PointLookup" {
    const io = std.testing.io;
    const path = "/tmp/test_pp_rowid.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "x", .col_type = .int, .nullable = false },
    });

    var lplanner = lp.LogicalPlanner.init(&db.cat, alloc);
    defer lplanner.deinit();
    var pplanner = PhysicalPlanner.init(alloc);
    defer pplanner.deinit();

    const pp = try makePlan("SELECT * FROM t WHERE _rowid_ = 42", alloc, &lplanner, &pplanner);
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).point_lookup, std.meta.activeTag(pp));
    try std.testing.expectEqual(@as(u64, 42), pp.point_lookup.rowid);
    try std.testing.expectEqualStrings("t", pp.point_lookup.table);
}

test "Project carries through col_indices" {
    const io = std.testing.io;
    const path = "/tmp/test_pp_project.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "a", .col_type = .int, .nullable = false },
        .{ .name = "b", .col_type = .text, .nullable = true },
        .{ .name = "c", .col_type = .int, .nullable = true },
    });

    var lplanner = lp.LogicalPlanner.init(&db.cat, alloc);
    defer lplanner.deinit();
    var pplanner = PhysicalPlanner.init(alloc);
    defer pplanner.deinit();

    const pp = try makePlan("SELECT a, c FROM t", alloc, &lplanner, &pplanner);
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).project, std.meta.activeTag(pp));
    try std.testing.expectEqual(@as(usize, 2), pp.project.col_indices.len);
    try std.testing.expectEqual(@as(usize, 0), pp.project.col_indices[0]);
    try std.testing.expectEqual(@as(usize, 2), pp.project.col_indices[1]);
}

test "INSERT physical plan preserves values" {
    const io = std.testing.io;
    const path = "/tmp/test_pp_insert.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "n", .col_type = .int, .nullable = false },
    });

    var lplanner = lp.LogicalPlanner.init(&db.cat, alloc);
    defer lplanner.deinit();
    var pplanner = PhysicalPlanner.init(alloc);
    defer pplanner.deinit();

    const pp = try makePlan("INSERT INTO t VALUES (7)", alloc, &lplanner, &pplanner);
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).insert, std.meta.activeTag(pp));
    try std.testing.expectEqual(@as(i64, 7), pp.insert.values[0].int_lit);
}

test "UPDATE physical plan wraps input" {
    const io = std.testing.io;
    const path = "/tmp/test_pp_update.db";
    defer Dir.deleteFile(.cwd(), io, path) catch {};
    const alloc = std.testing.allocator;

    var db = try makeDb(io, path, alloc);
    defer db.deinit();

    _ = try db.cat.createTable("t", &.{
        .{ .name = "x", .col_type = .int, .nullable = false },
    });

    var lplanner = lp.LogicalPlanner.init(&db.cat, alloc);
    defer lplanner.deinit();
    var pplanner = PhysicalPlanner.init(alloc);
    defer pplanner.deinit();

    const pp = try makePlan("UPDATE t SET x = 1 WHERE x = 0", alloc, &lplanner, &pplanner);
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).update, std.meta.activeTag(pp));
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).filter, std.meta.activeTag(pp.update.input.*));
}
