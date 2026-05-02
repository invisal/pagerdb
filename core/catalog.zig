const std = @import("std");
const t = @import("types.zig");
const ast = @import("sql/ast.zig");
const Pager = @import("pager/pager.zig").Pager;
const btree = @import("btree.zig");
const row = @import("row.zig");
const page0 = @import("page0.zig");
const Parser = @import("sql/parser.zig").Parser;

// ── Hardcoded catalog schemas ─────────────────────────────────────────────────

const TABLES_SCHEMA = [_]row.ColumnSchema{
    .{ .col_type = .text, .nullable = false }, // name
    .{ .col_type = .int, .nullable = false }, // btree_root
};

const COLUMNS_SCHEMA = [_]row.ColumnSchema{
    .{ .col_type = .int, .nullable = false }, // table_id
    .{ .col_type = .int, .nullable = false }, // col_index
    .{ .col_type = .text, .nullable = false }, // name
    .{ .col_type = .int, .nullable = false }, // col_type (as i64)
    .{ .col_type = .int, .nullable = false }, // nullable (0 or 1)
    .{ .col_type = .text, .nullable = true }, // default value expression
};

const COL = struct {
    const table_id: usize = 0;
    const attnum: usize = 1;
    const name: usize = 2;
    const col_type: usize = 3;
    const nullable: usize = 4;
    const default_expr: usize = 5;
};

// ── Public types ──────────────────────────────────────────────────────────────

pub const ColumnMeta = struct {
    /// 0-based physical storage slot number; stable across renames, never reused
    attnum: u32 = 0,
    name: []const u8,
    col_type: t.ColType,
    nullable: bool,
    /// Default expression in its original string form (e.g., "CURRENT_TIMESTAMP").
    /// Preserved for displaying in DESCRIBE and INFORMATION_SCHEMA.
    default_src: ?[]const u8 = null,
    /// Parsed AST of the default expression, ready for evaluation at runtime.
    /// NULL for columns without a default
    default_expr: ?ast.Expr = null,
};

pub const TableMeta = struct {
    id: u64,
    name: []const u8,
    btree_root: u32,
    rowid_counter: u64,
    columns: []ColumnMeta,

    pub fn findColumn(self: *TableMeta, name: []const u8) ?*const ColumnMeta {
        for (self.columns) |*column| {
            if (std.ascii.eqlIgnoreCase(column.name, name)) return column;
        }
        return null;
    }
};

// ── Catalog ───────────────────────────────────────────────────────────────────

pub const Catalog = struct {
    /// Owns all catalog strings and metadata; freed in one shot on deinit.
    arena: std.heap.ArenaAllocator,
    pager: *Pager,
    /// Uses the backing allocator so tables.deinit() reclaims its internal
    /// array independently from the arena.
    tables: std.StringHashMap(TableMeta),
    next_table_id: u64,
    next_col_rowid: u64,

    pub fn init(allocator: std.mem.Allocator, pager: *Pager) Catalog {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .pager = pager,
            .tables = std.StringHashMap(TableMeta).init(allocator),
            .next_table_id = 1,
            .next_col_rowid = 1,
        };
    }

    // Called on db.create(). Catalog roots are allocated lazily on first
    // createTable() call, so a fresh database is exactly one page (8 KB).
    // This allows opening an empty database without pre-allocating unused
    // catalog pages, keeping the file minimal until actual data is inserted.
    pub fn bootstrap(self: *Catalog) !void {
        try self.load();
    }

    // Called on db.open(): root page IDs already restored by page0.readHeader.
    // Derives next_table_id / next_col_rowid from the max rowids in each tree.
    pub fn load(self: *Catalog) !void {
        if (self.pager.sys_tables_root == 0) return;

        const alloc = self.arena.allocator();

        // Temporary arena for decoded row bytes that are never kept in the catalog.
        // All per-row values are allocated here and freed together when load() returns,
        // replacing the manual defer-free pattern that appeared on every iteration.
        var tmp_arena = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        defer tmp_arena.deinit();
        const tmp = tmp_arena.allocator();

        // Pass 1: load table entries with empty columns slice.
        // We defer column loading to a second pass because columns are stored
        // in a separate B-tree (sys_columns).  This two-pass approach lets us
        // first build the table map, then attach columns by table_id without
        // needing to re-lookup tables during the column scan.
        var max_table_id: u64 = 0;
        var table_scan = try btree.ScanIterator.init(self.pager, self.pager.sys_tables_root);
        while (try table_scan.next()) |cell| {
            const vals = try row.decodeRow(&TABLES_SCHEMA, cell.row_data, tmp);
            const btree_root: u32 = @intCast(vals[1].int);
            const rowid_counter = if (try btree.maxRowid(self.pager, btree_root)) |max| max + 1 else 1;
            const meta = TableMeta{
                .id = cell.rowid,
                .name = try alloc.dupe(u8, vals[0].text),
                .btree_root = btree_root,
                .rowid_counter = rowid_counter,
                .columns = &.{},
            };
            if (cell.rowid > max_table_id) max_table_id = cell.rowid;
            try self.tables.put(meta.name, meta);
        }
        self.next_table_id = max_table_id + 1;

        // Pass 2: attach column metadata to each table.
        var max_col_rowid: u64 = 0;
        var col_scan = try btree.ScanIterator.init(self.pager, self.pager.sys_columns_root);

        while (try col_scan.next()) |cell| {
            if (cell.rowid > max_col_rowid) max_col_rowid = cell.rowid;

            const vals = try row.decodeRow(&COLUMNS_SCHEMA, cell.row_data, tmp);
            const table_id = @as(u64, @intCast(vals[COL.table_id].int));

            // Extract once, use twice - avoids redundant check and keeps logic together.
            // default_src is borrowed from tmp arena; we dup it into the catalog arena below.
            const default_src: ?[]const u8 = if (vals[COL.default_expr] == .text) vals[COL.default_expr].text else null;
            const default_expr: ?ast.Expr = if (default_src) |src|
                try Parser.parseStandaloneExpr(src, tmp)
            else
                null;

            const col = ColumnMeta{
                .attnum = @intCast(vals[COL.attnum].int),
                .name = try alloc.dupe(u8, vals[COL.name].text),
                .col_type = @enumFromInt(vals[COL.col_type].int),
                .nullable = vals[COL.nullable].int != 0,
                .default_expr = if (default_expr) |expr| try expr.clone(alloc) else null,
                .default_src = if (default_src) |src| try alloc.dupe(u8, src) else null,
            };

            var it = self.tables.valueIterator();
            while (it.next()) |meta| {
                if (meta.id == table_id) {
                    meta.columns = try appendColumn(alloc, meta.columns, col);
                    break;
                }
            }
        }
        self.next_col_rowid = max_col_rowid + 1;
    }

    pub fn createTable(
        self: *Catalog,
        name: []const u8,
        cols: []const ColumnMeta,
    ) !TableMeta {
        if (self.tables.contains(name)) return error.TableAlreadyExists;

        // Lazy-allocate catalog roots on the very first createTable call.
        // This keeps empty databases at exactly one page until user data exists.
        // The roots are written to page 0 header so they survive restarts.
        if (self.pager.sys_tables_root == 0) {
            const tables_root = try self.pager.allocPage();
            const columns_root = try self.pager.allocPage();
            self.pager.sys_tables_root = tables_root;
            self.pager.sys_columns_root = columns_root;
            var buf: [t.PAGE_SIZE]u8 = undefined;
            btree.initLeafPage(&buf, true);
            try self.pager.writePage(tables_root, &buf);
            btree.initLeafPage(&buf, true);
            try self.pager.writePage(columns_root, &buf);
            try page0.writeHeader(self.pager);
        }

        const new_table_id = self.next_table_id;
        const col_rowid_start = self.next_col_rowid;

        // Allocate and initialise the new table's root page.
        const root_page = try self.pager.allocPage();
        var pg_buf: [t.PAGE_SIZE]u8 = undefined;
        btree.initLeafPage(&pg_buf, true);
        try self.pager.writePage(root_page, &pg_buf);

        // Insert catalog rows.
        try self.insertTablesRow(new_table_id, name, @intCast(root_page));
        for (cols, 0..) |col, i| {
            try self.insertColumnsRow(
                col_rowid_start + i,
                @intCast(new_table_id),
                @intCast(i),
                col.name,
                col.col_type,
                col.nullable,
                col.default_src,
            );
        }

        // Advance in-memory counters.
        self.next_table_id = new_table_id + 1;
        self.next_col_rowid = col_rowid_start + @as(u64, cols.len);

        // Build the in-memory entry with deep-copied strings into the catalog arena.
        const alloc = self.arena.allocator();
        const duped_name = try alloc.dupe(u8, name);
        const duped_cols = try alloc.alloc(ColumnMeta, cols.len);

        for (cols, 0..) |col, i| {
            const duped_default_src = if (col.default_src) |src|
                try alloc.dupe(u8, src)
            else
                null;

            // Deep-clone the default expression to the catalog arena.
            const duped_default_expr: ?ast.Expr = if (col.default_expr) |expr|
                try expr.clone(alloc)
            else
                null;

            duped_cols[i] = .{
                .attnum = @intCast(i),
                .name = try alloc.dupe(u8, col.name),
                .col_type = col.col_type,
                .nullable = col.nullable,
                .default_src = duped_default_src,
                .default_expr = duped_default_expr,
            };
        }
        const meta = TableMeta{
            .id = new_table_id,
            .name = duped_name,
            .btree_root = root_page,
            .rowid_counter = 1,
            .columns = duped_cols,
        };
        try self.tables.put(meta.name, meta);
        return meta;
    }

    pub fn getTable(self: *Catalog, name: []const u8) ?*TableMeta {
        return self.tables.getPtr(name);
    }

    pub fn deinit(self: *Catalog) void {
        // tables uses the backing allocator, so its internal array must be
        // freed before the arena; the arena owns all the string/column data.
        self.tables.deinit();
        self.arena.deinit();
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    fn insertTablesRow(
        self: *Catalog,
        rowid: u64,
        name: []const u8,
        btree_root: i64,
    ) !void {
        const values = [_]row.Value{
            .{ .text = name },
            .{ .int = btree_root },
        };
        var buf: [256]u8 = undefined;
        const len = row.encodeRow(&values, &buf);
        try btree.insert(self.pager, self.pager.sys_tables_root, rowid, buf[0..len], true);
    }

    fn insertColumnsRow(
        self: *Catalog,
        rowid: u64,
        table_id: i64,
        col_index: i64,
        name: []const u8,
        col_type: t.ColType,
        nullable: bool,
        default_src: ?[]const u8,
    ) !void {
        const default_value = if (default_src) |src|
            row.Value{ .text = src }
        else
            row.Value{ .null = {} };

        const values = [_]row.Value{
            .{ .int = table_id },
            .{ .int = col_index },
            .{ .text = name },
            .{ .int = @intFromEnum(col_type) },
            .{ .int = if (nullable) 1 else 0 },
            default_value,
        };

        var buf: [256]u8 = undefined;
        const len = row.encodeRow(&values, &buf);
        try btree.insert(self.pager, self.pager.sys_columns_root, rowid, buf[0..len], true);
    }
};

// ── Helper ────────────────────────────────────────────────────────────────────

fn appendColumn(allocator: std.mem.Allocator, cols: []ColumnMeta, col: ColumnMeta) ![]ColumnMeta {
    const new_cols = try allocator.alloc(ColumnMeta, cols.len + 1);
    @memcpy(new_cols[0..cols.len], cols);
    new_cols[cols.len] = col;
    if (cols.len > 0) allocator.free(cols);
    return new_cols;
}
