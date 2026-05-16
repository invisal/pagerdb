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
    exprs: []lp.Expr,
    schema: lp.Schema,
};

pub const PhysicalInsert = struct {
    table: []const u8,
    values: [][]lp.Expr, // multiple rows; each inner slice is one row (one Expr per column)
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
    args: []const vtab_mod.Value,
    schema: lp.Schema,
};

pub const PhysicalCreateTable = struct {
    table: []const u8,
    columns: []catalog.ColumnMeta,
};

pub const PhysicalJoin = struct {
    left: PhysicalPlan,
    right: PhysicalPlan,
    condition: lp.Expr,
    schema: lp.Schema,
};

pub const PhysicalAggregate = struct {
    input: *PhysicalPlan,
    group_by: []const usize,
    agg_specs: []const lp.AggCallSpec,
    schema: lp.Schema,
};

pub const PhysicalSort = struct {
    input: *PhysicalPlan,
    keys: []lp.SortKey,
    schema: lp.Schema,
};

pub const PhysicalDistinct = struct {
    input: *PhysicalPlan,
    schema: lp.Schema,
};

pub const PhysicalPlan = union(enum) {
    seq_scan: PhysicalSeqScan,
    vtab_scan: PhysicalVTabScan,
    const_scan: void,
    point_lookup: PhysicalPointLookup,
    filter: *PhysicalFilter,
    project: *PhysicalProject,
    aggregate: *PhysicalAggregate,
    sort: *PhysicalSort,
    distinct: *PhysicalDistinct,
    join: *PhysicalJoin,
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
            .const_scan => lp.Schema{ .table = "", .columns = &.{} },
            .vtab_scan => |n| n.schema,
            .point_lookup => |n| n.schema,
            .filter => |n| n.schema,
            .project => |n| n.schema,
            .aggregate => |n| n.schema,
            .sort => |n| n.schema,
            .distinct => |n| n.schema,
            .join => |n| n.schema,
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
            .const_scan => .{ .const_scan = {} },
            .filter => |n| try self.planFilter(n),
            .project => |n| try self.planProject(n),
            .aggregate => |n| try self.planAggregate(n),
            .sort => |n| try self.planSort(n),
            .distinct => |n| try self.planDistinct(n),
            .join => |n| try self.planJoin(n),
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
            // Find the __rowid column index in this scan's schema, then check
            // if the predicate is a simple equality on it.  If so, replace the
            // SeqScan+Filter with a direct B-tree point lookup.
            const scan_schema = node.input.seq_scan.schema;
            var rowid_col_idx: ?usize = null;
            for (scan_schema.columns) |col| {
                if (std.mem.eql(u8, col.name, "__rowid")) {
                    rowid_col_idx = col.index;
                    break;
                }
            }
            if (rowid_col_idx) |ridx| {
                if (extractRowidEq(node.predicate, ridx)) |rowid_val| {
                    return .{ .point_lookup = .{
                        .table = node.input.seq_scan.table,
                        .rowid = rowid_val,
                        .schema = node.schema,
                    } };
                }
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
            .exprs = node.exprs,
            .schema = node.schema,
        };
        return .{ .project = proj };
    }

    fn planAggregate(self: *PhysicalPlanner, node: *lp.Aggregate) !PhysicalPlan {
        const phys_input = try self.alloc().create(PhysicalPlan);
        phys_input.* = try self.plan(node.input.*);
        const agg = try self.alloc().create(PhysicalAggregate);
        agg.* = .{
            .input = phys_input,
            .group_by = node.group_by,
            .agg_specs = node.agg_specs,
            .schema = node.schema,
        };
        return .{ .aggregate = agg };
    }

    fn planSort(self: *PhysicalPlanner, node: *lp.Sort) !PhysicalPlan {
        const phys_input = try self.alloc().create(PhysicalPlan);
        phys_input.* = try self.plan(node.input.*);
        const sort = try self.alloc().create(PhysicalSort);
        sort.* = .{ .input = phys_input, .keys = node.keys, .schema = node.schema };
        return .{ .sort = sort };
    }

    fn planDistinct(self: *PhysicalPlanner, node: *lp.Distinct) !PhysicalPlan {
        const phys_input = try self.alloc().create(PhysicalPlan);
        phys_input.* = try self.plan(node.input.*);
        const d = try self.alloc().create(PhysicalDistinct);
        d.* = .{ .input = phys_input, .schema = node.schema };
        return .{ .distinct = d };
    }

    fn planJoin(self: *PhysicalPlanner, node: *lp.Join) !PhysicalPlan {
        const join_node = try self.alloc().create(PhysicalJoin);
        join_node.* = .{
            .left = try self.plan(node.left.*),
            .right = try self.plan(node.right.*),
            .condition = node.condition,
            .schema = node.schema,
        };
        return .{ .join = join_node };
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

// Optimization: detect "__rowid = N" or "N = __rowid" patterns in the WHERE
// clause.  When found, the physical planner replaces SeqScan+Filter with
// PointLookup, which uses btree.lookup() directly — O(log n) vs O(n).
fn extractRowidEq(expr: lp.Expr, rowid_col_idx: usize) ?u64 {
    if (expr != .binary) return null;
    const b = expr.binary;
    if (b.op != .eq) return null;
    if (b.left == .col_idx and b.left.col_idx == rowid_col_idx and b.right == .int_lit)
        return @intCast(b.right.int_lit);
    if (b.right == .col_idx and b.right.col_idx == rowid_col_idx and b.left == .int_lit)
        return @intCast(b.left.int_lit);
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const Pager = @import("../pager/pager.zig").Pager;
const DiskPager = @import("../pager/disk.zig").DiskPager;
const DiskIo = @import("../io/disk_io.zig").DiskIo;
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
    var disk_io = DiskIo.init(alloc, io);
    pager.* = try DiskPager.create(alloc, disk_io.io(), path, .{});
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
    var parser = Parser.init(src, alloc);
    defer parser.deinit();
    const stmt = try parser.parse();
    const logical = try lp_out.plan(stmt);
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
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).project, std.meta.activeTag(pp));
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).seq_scan, std.meta.activeTag(pp.project.input));
    try std.testing.expectEqualStrings("t", pp.project.input.seq_scan.table);
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
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).project, std.meta.activeTag(pp));
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).filter, std.meta.activeTag(pp.project.input));
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).seq_scan, std.meta.activeTag(pp.project.input.filter.input));
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

    const pp = try makePlan("SELECT * FROM t WHERE __rowid = 42", alloc, &lplanner, &pplanner);
    // __rowid = N is optimized to PointLookup, then wrapped in Project for column filtering.
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).project, std.meta.activeTag(pp));
    try std.testing.expectEqual(std.meta.Tag(PhysicalPlan).point_lookup, std.meta.activeTag(pp.project.input));
    try std.testing.expectEqual(@as(u64, 42), pp.project.input.point_lookup.rowid);
    try std.testing.expectEqualStrings("t", pp.project.input.point_lookup.table);
}

test "Project carries through exprs" {
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
    try std.testing.expectEqual(@as(usize, 2), pp.project.exprs.len);
    try std.testing.expectEqual(@as(usize, 0), pp.project.exprs[0].col_idx);
    try std.testing.expectEqual(@as(usize, 2), pp.project.exprs[1].col_idx);
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
    try std.testing.expectEqual(@as(i64, 7), pp.insert.values[0][0].int_lit);
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
