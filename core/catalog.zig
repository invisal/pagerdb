const std = @import("std");
const t = @import("types.zig");
const ast = @import("sql/ast.zig");
const Pager = @import("pager/pager.zig").Pager;
const PageWriter = @import("page_writer.zig").PageWriter;
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
    // flags bitmask: bit 0 = nullable, bit 1 = is_primary_key
    // Old rows stored 0 or 1 here; bit 1 was always 0, so backward-compatible.
    .{ .col_type = .int, .nullable = false }, // flags
    .{ .col_type = .text, .nullable = true }, // default value expression
};

const INDEXES_SCHEMA = [_]row.ColumnSchema{
    .{ .col_type = .text, .nullable = false }, // name
    .{ .col_type = .int, .nullable = false }, // table_id
    .{ .col_type = .int, .nullable = false }, // is_unique
    .{ .col_type = .int, .nullable = false }, // btree_root
};

const INDEX_COLS_SCHEMA = [_]row.ColumnSchema{
    .{ .col_type = .int, .nullable = false }, // index_id
    .{ .col_type = .int, .nullable = false }, // position
    .{ .col_type = .int, .nullable = false }, // col_index (attnum)
};

const COL = struct {
    const table_id: usize = 0;
    const attnum: usize = 1;
    const name: usize = 2;
    const col_type: usize = 3;
    const flags: usize = 4; // bit 0=nullable, bit 1=is_primary_key
    const default_expr: usize = 5;
};

const IDX = struct {
    const name: usize = 0;
    const table_id: usize = 1;
    const is_unique: usize = 2;
    const btree_root: usize = 3;
};

const IDXCOL = struct {
    const index_id: usize = 0;
    const position: usize = 1;
    const col_index: usize = 2;
};

// ── Public types ──────────────────────────────────────────────────────────────

pub const IndexMeta = struct {
    id: u64,
    name: []const u8,
    table_name: []const u8,
    is_unique: bool,
    btree_root: u32,
    col_indices: []u32, // attnums of indexed columns in index order
};

pub const ColumnMeta = struct {
    /// 0-based physical storage slot number; stable across renames, never reused
    attnum: u32 = 0,
    name: []const u8,
    col_type: t.ColType,
    nullable: bool,
    is_primary_key: bool = false,
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
    indexes: []IndexMeta,

    pub fn findColumn(self: *TableMeta, name: []const u8) ?*const ColumnMeta {
        for (self.columns) |*column| {
            if (std.ascii.eqlIgnoreCase(column.name, name)) return column;
        }
        return null;
    }

    /// Returns the attnum of the INTEGER PRIMARY KEY column, or null if none.
    pub fn findPkColumn(self: *const TableMeta) ?usize {
        for (self.columns) |col| {
            if (col.is_primary_key) return col.attnum;
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
    next_idx_id: u64,
    next_idx_col_rowid: u64,

    pub fn init(allocator: std.mem.Allocator, pager: *Pager) Catalog {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .pager = pager,
            .tables = std.StringHashMap(TableMeta).init(allocator),
            .next_table_id = 1,
            .next_col_rowid = 1,
            .next_idx_id = 1,
            .next_idx_col_rowid = 1,
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
                .indexes = &.{},
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
                (try Parser.parseStandaloneExpr(tmp, src)).expr
            else
                null;

            const flags = vals[COL.flags].int;
            const col = ColumnMeta{
                .attnum = @intCast(vals[COL.attnum].int),
                .name = try alloc.dupe(u8, vals[COL.name].text),
                .col_type = @enumFromInt(vals[COL.col_type].int),
                .nullable = (flags & 1) != 0,
                .is_primary_key = (flags & 2) != 0,
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

        // Pass 3+4: load index metadata and column mappings.
        // Skipped when no indexes have been created yet (sys_indexes_root == 0).
        if (self.pager.sys_indexes_root != 0) {
            // Temporary struct for raw index rows before col_indices are assembled.
            const RawIndex = struct {
                name: []const u8,
                table_id: u64,
                is_unique: bool,
                btree_root: u32,
            };
            var idx_map = std.AutoHashMap(u64, RawIndex).init(tmp);

            var max_idx_id: u64 = 0;
            var idx_scan = try btree.ScanIterator.init(self.pager, self.pager.sys_indexes_root);
            while (try idx_scan.next()) |cell| {
                if (cell.rowid > max_idx_id) max_idx_id = cell.rowid;
                const vals = try row.decodeRow(&INDEXES_SCHEMA, cell.row_data, tmp);
                try idx_map.put(cell.rowid, .{
                    .name = try tmp.dupe(u8, vals[IDX.name].text),
                    .table_id = @intCast(vals[IDX.table_id].int),
                    .is_unique = vals[IDX.is_unique].int != 0,
                    .btree_root = @intCast(vals[IDX.btree_root].int),
                });
            }
            self.next_idx_id = max_idx_id + 1;

            // Collect (position, col_index) pairs per index_id.
            // ArrayListUnmanaged avoids the local-struct type restriction on ArrayList.
            const ColEntry = struct { position: u32, col_index: u32 };
            var col_lists = std.AutoHashMap(u64, std.ArrayListUnmanaged(ColEntry)).init(tmp);

            var max_idx_col_rowid: u64 = 0;
            var icol_scan = try btree.ScanIterator.init(self.pager, self.pager.sys_index_cols_root);
            while (try icol_scan.next()) |cell| {
                if (cell.rowid > max_idx_col_rowid) max_idx_col_rowid = cell.rowid;
                const vals = try row.decodeRow(&INDEX_COLS_SCHEMA, cell.row_data, tmp);
                const idx_id: u64 = @intCast(vals[IDXCOL.index_id].int);
                const gop = try col_lists.getOrPut(idx_id);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(tmp, .{
                    .position = @intCast(vals[IDXCOL.position].int),
                    .col_index = @intCast(vals[IDXCOL.col_index].int),
                });
            }
            self.next_idx_col_rowid = max_idx_col_rowid + 1;

            // Assemble IndexMeta and attach to the owning table.
            var idx_it = idx_map.iterator();
            while (idx_it.next()) |entry| {
                const idx_id = entry.key_ptr.*;
                const raw = entry.value_ptr.*;

                // Sort columns by their position in the index key.
                const col_items: []ColEntry = if (col_lists.getPtr(idx_id)) |l| l.items else &.{};
                std.mem.sort(ColEntry, col_items, {}, struct {
                    fn lt(_: void, a: ColEntry, b: ColEntry) bool {
                        return a.position < b.position;
                    }
                }.lt);

                const col_indices = try alloc.alloc(u32, col_items.len);
                for (col_items, 0..) |ce, i| col_indices[i] = ce.col_index;

                var tbl_it = self.tables.valueIterator();
                while (tbl_it.next()) |tbl| {
                    if (tbl.id == raw.table_id) {
                        const idx_meta = IndexMeta{
                            .id = idx_id,
                            .name = try alloc.dupe(u8, raw.name),
                            .table_name = tbl.name,
                            .is_unique = raw.is_unique,
                            .btree_root = raw.btree_root,
                            .col_indices = col_indices,
                        };
                        tbl.indexes = try appendIndex(alloc, tbl.indexes, idx_meta);
                        break;
                    }
                }
            }
        }
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
            var tables_pw = PageWriter.init(self.pager, tables_root);
            btree.initLeafPage(&tables_pw, true);
            try tables_pw.commit();
            var columns_pw = PageWriter.init(self.pager, columns_root);
            btree.initLeafPage(&columns_pw, true);
            try columns_pw.commit();
            try page0.writeHeader(self.pager);
        }

        const new_table_id = self.next_table_id;
        const col_rowid_start = self.next_col_rowid;

        // Allocate and initialise the new table's root page.
        const root_page = try self.pager.allocPage();
        var root_pw = PageWriter.init(self.pager, root_page);
        btree.initLeafPage(&root_pw, true);
        try root_pw.commit();

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
                col.is_primary_key,
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
                .is_primary_key = col.is_primary_key,
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
            .indexes = &.{},
        };
        try self.tables.put(meta.name, meta);
        return meta;
    }

    pub fn createIndex(
        self: *Catalog,
        name: []const u8,
        table_name: []const u8,
        col_indices: []const u32,
        is_unique: bool,
        btree_root_val: u32,
    ) !IndexMeta {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;

        // Lazy-allocate index catalog roots on the very first createIndex call,
        // mirroring the lazy allocation of table roots in createTable.
        if (self.pager.sys_indexes_root == 0) {
            const indexes_root = try self.pager.allocPage();
            const idx_cols_root = try self.pager.allocPage();
            self.pager.sys_indexes_root = indexes_root;
            self.pager.sys_index_cols_root = idx_cols_root;
            var idx_pw = PageWriter.init(self.pager, indexes_root);
            btree.initLeafPage(&idx_pw, true);
            try idx_pw.commit();
            var icol_pw = PageWriter.init(self.pager, idx_cols_root);
            btree.initLeafPage(&icol_pw, true);
            try icol_pw.commit();
            try page0.writeHeader(self.pager);
        }

        const idx_id = self.next_idx_id;

        // Persist catalog rows for the new index.
        try self.insertIndexesRow(idx_id, name, table.id, is_unique, btree_root_val);
        for (col_indices, 0..) |col_idx, pos| {
            try self.insertIndexColsRow(
                self.next_idx_col_rowid + pos,
                idx_id,
                @intCast(pos),
                col_idx,
            );
        }

        // Advance in-memory counters.
        self.next_idx_id = idx_id + 1;
        self.next_idx_col_rowid += @as(u64, col_indices.len);

        // Build the in-memory IndexMeta and attach it to the table.
        const alloc = self.arena.allocator();
        const meta = IndexMeta{
            .id = idx_id,
            .name = try alloc.dupe(u8, name),
            .table_name = table.name,
            .is_unique = is_unique,
            .btree_root = btree_root_val,
            .col_indices = try alloc.dupe(u32, col_indices),
        };
        table.indexes = try appendIndex(alloc, table.indexes, meta);

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
        is_primary_key: bool,
        default_src: ?[]const u8,
    ) !void {
        const default_value = if (default_src) |src|
            row.Value{ .text = src }
        else
            row.Value{ .null = {} };

        // flags bitmask: bit 0 = nullable, bit 1 = is_primary_key
        const flags: i64 = @as(i64, if (nullable) 1 else 0) | (@as(i64, if (is_primary_key) 1 else 0) << 1);

        const values = [_]row.Value{
            .{ .int = table_id },
            .{ .int = col_index },
            .{ .text = name },
            .{ .int = @intFromEnum(col_type) },
            .{ .int = flags },
            default_value,
        };

        var buf: [256]u8 = undefined;
        const len = row.encodeRow(&values, &buf);
        try btree.insert(self.pager, self.pager.sys_columns_root, rowid, buf[0..len], true);
    }

    fn insertIndexesRow(
        self: *Catalog,
        rowid: u64,
        name: []const u8,
        table_id: u64,
        is_unique: bool,
        btree_root_val: u32,
    ) !void {
        const values = [_]row.Value{
            .{ .text = name },
            .{ .int = @intCast(table_id) },
            .{ .int = if (is_unique) 1 else 0 },
            .{ .int = @intCast(btree_root_val) },
        };
        var buf: [256]u8 = undefined;
        const len = row.encodeRow(&values, &buf);
        try btree.insert(self.pager, self.pager.sys_indexes_root, rowid, buf[0..len], true);
    }

    fn insertIndexColsRow(
        self: *Catalog,
        rowid: u64,
        index_id: u64,
        position: u32,
        col_index: u32,
    ) !void {
        const values = [_]row.Value{
            .{ .int = @intCast(index_id) },
            .{ .int = @intCast(position) },
            .{ .int = @intCast(col_index) },
        };
        var buf: [64]u8 = undefined;
        const len = row.encodeRow(&values, &buf);
        try btree.insert(self.pager, self.pager.sys_index_cols_root, rowid, buf[0..len], true);
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

fn appendIndex(allocator: std.mem.Allocator, idxs: []IndexMeta, idx: IndexMeta) ![]IndexMeta {
    const new_idxs = try allocator.alloc(IndexMeta, idxs.len + 1);
    @memcpy(new_idxs[0..idxs.len], idxs);
    new_idxs[idxs.len] = idx;
    if (idxs.len > 0) allocator.free(idxs);
    return new_idxs;
}
