const std = @import("std");
const t = @import("types.zig");
const Pager = @import("pager/pager.zig").Pager;
const btree = @import("btree.zig");
const row = @import("row.zig");
const page0 = @import("page0.zig");

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
};

// ── Public types ──────────────────────────────────────────────────────────────

pub const ColumnMeta = struct {
    /// 0-based physical storage slot number; stable across renames, never reused
    attnum: u32 = 0,
    name: []const u8,
    col_type: t.ColType,
    nullable: bool,
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
    allocator: std.mem.Allocator,
    pager: *Pager,
    tables: std.StringHashMap(TableMeta),
    next_table_id: u64,
    next_col_rowid: u64,

    pub fn init(allocator: std.mem.Allocator, pager: *Pager) Catalog {
        return .{
            .allocator = allocator,
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

        // Pass 1: load table entries with empty columns slice.
        // We defer column loading to a second pass because columns are stored
        // in a separate B-tree (sys_columns).  This two-pass approach lets us
        // first build the table map, then attach columns by table_id without
        // needing to re-lookup tables during the column scan.
        var max_table_id: u64 = 0;
        var table_scan = try btree.ScanIterator.init(self.pager, self.pager.sys_tables_root);
        while (try table_scan.next()) |cell| {
            const vals = try row.decodeRow(&TABLES_SCHEMA, cell.row_data, self.allocator);
            defer {
                self.allocator.free(vals[0].text);
                self.allocator.free(vals);
            }
            const btree_root: u32 = @intCast(vals[1].int);
            const rowid_counter = if (try btree.maxRowid(self.pager, btree_root)) |max| max + 1 else 1;
            const meta = TableMeta{
                .id = cell.rowid,
                .name = try self.allocator.dupe(u8, vals[0].text),
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
            const vals = try row.decodeRow(&COLUMNS_SCHEMA, cell.row_data, self.allocator);
            defer {
                self.allocator.free(vals[2].text);
                self.allocator.free(vals);
            }
            const table_id = @as(u64, @intCast(vals[0].int));
            const col = ColumnMeta{
                .attnum = @intCast(vals[1].int),
                .name = try self.allocator.dupe(u8, vals[2].text),
                .col_type = @enumFromInt(vals[3].int),
                .nullable = vals[4].int != 0,
            };
            var it = self.tables.valueIterator();
            while (it.next()) |meta| {
                if (meta.id == table_id) {
                    meta.columns = try appendColumn(self.allocator, meta.columns, col);
                    break;
                }
            } else {
                self.allocator.free(col.name);
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
            );
        }

        // Advance in-memory counters.
        self.next_table_id = new_table_id + 1;
        self.next_col_rowid = col_rowid_start + @as(u64, cols.len);

        // Build the in-memory entry with deep-copied strings.
        const duped_name = try self.allocator.dupe(u8, name);
        const duped_cols = try self.allocator.alloc(ColumnMeta, cols.len);
        for (cols, 0..) |col, i| {
            duped_cols[i] = .{
                .attnum = @intCast(i),
                .name = try self.allocator.dupe(u8, col.name),
                .col_type = col.col_type,
                .nullable = col.nullable,
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
        var it = self.tables.valueIterator();
        while (it.next()) |meta| {
            for (meta.columns) |col| self.allocator.free(col.name);
            if (meta.columns.len > 0) self.allocator.free(meta.columns);
            self.allocator.free(meta.name);
        }
        self.tables.deinit();
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
    ) !void {
        const values = [_]row.Value{
            .{ .int = table_id },
            .{ .int = col_index },
            .{ .text = name },
            .{ .int = @intFromEnum(col_type) },
            .{ .int = if (nullable) 1 else 0 },
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
