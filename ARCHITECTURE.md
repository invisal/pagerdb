# PagerDB Architecture

PagerDB is an embedded relational database written in Zig. It follows a classic layered architecture: raw page I/O → B-tree storage → catalog → SQL pipeline. The design is intentionally similar to SQLite — single-file, rowid-based B-trees, page-level caching — but built from scratch for learning and extension.

---

## Layers at a Glance

```
┌─────────────────────────────────────────┐
│              CLI / REPL                 │  cli/repl.zig
├─────────────────────────────────────────┤
│           SQL Pipeline                  │
│  Lexer → Parser → Logical Plan          │
│       → Physical Plan → Executor        │  sql/
├─────────────────────────────────────────┤
│          Database API  (db.zig)         │  insert/delete/update/scan
│       Transaction / Undo Log (txn.zig)  │  BEGIN/COMMIT/ROLLBACK
├─────────────────────────────────────────┤
│       Catalog  (catalog.zig)            │  __tables, __columns B-trees
├─────────────────────────────────────────┤
│       B-Tree Engine  (btree.zig)        │  rowid-keyed ordered tree
│       Overflow Pages (overflow.zig)     │  rows > 2 KB
│       Row Encoding   (row.zig)          │  binary codec + null bitmap
├─────────────────────────────────────────┤
│       Pager  (pager.zig)                │  8 KB pages, 64-frame LRU
│       Header (page0.zig)               │  database metadata on page 0
└─────────────────────────────────────────┘
             single file on disk
```

---

## Storage Layer

### Pager (`src/pager.zig`)

The pager is the only component that touches the file system. Everything above it works in page-sized buffers.

- **Page size**: 8,192 bytes (fixed).
- **Buffer pool**: 64 frames in an LRU cache. Each frame tracks a monotonically increasing `lru_tick`; eviction picks the lowest tick. Dirty frames are written back to disk before eviction.
- **Free list**: Freed pages are pushed onto a singly-linked list (stored in the freed pages themselves). `allocPage()` pops from the list first; only if empty does it extend the file.

Key operations:

| Operation | Description |
|---|---|
| `create(path)` | Creates a new file, writes the header on page 0 |
| `open(path)` | Reads the header, restores `total_pages` and catalog roots |
| `readPage(id, buf)` | LRU cache read; loads from disk on miss |
| `writePage(id, buf)` | Writes into cache, marks frame dirty |
| `allocPage()` | Returns page ID from free list or new tail |
| `freePage(id)` | Pushes page onto free list |
| `flush()` | Writes all dirty frames to disk, re-writes the header, calls `fsync` |

### Database Header (`src/page0.zig`)

Page 0 is never used for data. It stores a 64-byte header:

```
Offset  Size  Field
──────  ────  ─────────────────────────────────────────
0       4     magic = 0x50474442 ("PGDB")
4       2     version_major
6       2     version_minor
8       4     page_size (= 8192)
12      4     total_pages
16      4     free_list_head  (0 = empty)
20      4     sys_tables_root  (root page of __tables B-tree)
24      4     sys_columns_root (root page of __columns B-tree)
28      36    reserved
```

`flush()` always rewrites this header so catalog roots are always recoverable after a clean shutdown.

---

## B-Tree Engine (`src/btree.zig`)

All user tables and both catalog tables are stored as rowid B-trees. The rowid is a `u64` auto-incremented by the database layer.

### Page Layout

Every B-tree page begins with two fixed headers:

```
Offset  Size  Structure
──────  ────  ─────────────────────────────────────────
0       16    PageHeader  { page_type, flags, checksum, lsn }
16      24    BTreeHeader {
                cell_count (u16),
                flags (u16),       // bit 0: rowid tree
                free_end (u16),    // first free byte (grows down)
                dead_bytes (u16),  // bytes from deleted cells
                parent_page (u32),
                prev_leaf (u32),   // leaf-chain linkage
                next_leaf (u32),
                _pad (u32)
              }
40      …     cell pointer array  (grows upward)
…       …     free space
…       …     cells               (grow downward from end of page)
end-4   4     rightmost child page ID (internal nodes only)
```

### Cell Format

**Leaf cell** (sorted by rowid):
```
[8 bytes]  rowid (u64 little-endian)
[2 bytes]  row_len  (bit 15 = overflow flag; bits 0–14 = byte length)
[N bytes]  inline row data  OR  [4 bytes] overflow page ID
```

**Internal cell** (separator keys):
```
[4 bytes]  left_child page ID
[8 bytes]  separator rowid
```
The rightmost child pointer lives at `page_end - 4`, not in a cell.

### Key Algorithms

**Search**: Binary search on cell pointer array comparing rowid values.

**Leaf insert**: Appends cell at `free_end`, writes pointer. If fragmentation (`dead_bytes`) exceeds a threshold, the page is compacted (cells repacked in place) before insertion.

**Splits**:
- *Right-biased split* — used when the new cell belongs in the rightmost position (common for sequential inserts). The new cell goes into a fresh rightmost page; the separator key is promoted to the parent.
- *Half-split* — 50/50 division for random inserts.
- *Root split* — when the root is a leaf, it becomes an internal node and two new leaf children are created.

**Leaf chain**: All leaf pages form a doubly-linked list via `prev_leaf`/`next_leaf`. Full-table scans follow this chain without touching internal nodes.

**Delete**: Marks cell bytes as `dead_bytes`. If the leaf becomes empty, it is freed and unlinked from both the parent and the leaf chain.

> **Current limitation**: Root internal-node splits are not yet implemented. Trees with very large numbers of internal pages will return `NotImplementedYet`.

---

## Overflow Pages (`src/overflow.zig`)

Rows larger than **2,048 bytes** (OVERFLOW_THRESHOLD = PAGE_SIZE / 4) are stored in an overflow chain. The leaf cell stores a 4-byte overflow page ID instead of inline data.

```
OverflowPage layout (8,192 bytes):
  PageHeader (16 bytes)
  next_page  (u32)   — ID of next page, or 0 if last
  data_len   (u16)   — bytes of payload in this page
  _reserved  (u16)
  data       (8,168 bytes)
```

- `buildChain(row_data)` — splits data into 8,168-byte chunks and allocates pages.
- `readChain(first_page, total_len, out)` — follows the chain to reassemble data.
- `freeChain(first_page)` — returns all pages in the chain to the pager's free list.

---

## Row Encoding (`src/row.zig`)

Rows are encoded into a compact binary format before being handed to the B-tree.

**Layout**:
```
[ceil(ncols/8) bytes]  NULL bitmap  (1 bit per column; bit set = NULL)
[per column]           encoded column data
```

**Per-column encoding**:

| Type | Encoding |
|---|---|
| INT  | 8 bytes, offset-binary (XOR 0x8000_0000_0000_0000) so bytes sort correctly |
| REAL | 8 bytes, raw IEEE 754 bits as u64 |
| TEXT | 2-byte big-endian length + UTF-8 bytes |
| BLOB | 4-byte big-endian length + raw bytes |

Offset-binary encoding ensures integer comparisons are correct even when treating the bytes as unsigned integers.

---

## Catalog (`src/catalog.zig`)

The catalog is two ordinary B-trees stored at the roots recorded in the database header.

### `__tables` (sys_tables_root)
One row per user table:
```
rowid          → table ID (auto-assigned)
name           TEXT
btree_root     INT   — root page ID of the table's B-tree
rowid_counter  INT   — next rowid to assign on INSERT
```

### `__columns` (sys_columns_root)
One row per column:
```
rowid      INT   — auto-assigned
table_id   INT   — foreign key into __tables.rowid
col_index  INT   — 0-based position within the table
name       TEXT
col_type   INT   — ColType enum value
nullable   INT   — 1 if nullable
```

The catalog is loaded entirely into an in-memory hash map (`table_name → TableMeta`) when the database is opened. `createTable()` inserts rows into both B-trees, updates the in-memory map, and flushes immediately. There are no deferred catalog writes.

---

## Database API (`src/db.zig`)

`Db` is the entry point for all database operations. It owns the `Pager` and `Catalog`.

| Method | Description |
|---|---|
| `Db.create(io, path, alloc)` | Creates file, bootstraps catalog |
| `Db.open(io, path, alloc)` | Opens file, loads catalog into memory |
| `Db.close()` | Rolls back any open transaction, flushes, syncs, frees memory |
| `createTable(name, columns)` | Allocates B-tree root, writes catalog rows |
| `insert(table, values)` | Encodes row, inserts into B-tree, increments rowid counter |
| `delete(table, rowid)` | Frees overflow chain if any, removes from B-tree |
| `update(table, rowid, values)` | Delete + re-insert with same rowid |
| `getByRowid(table, rowid, alloc)` | Point lookup in B-tree |
| `scan(table, callback, ctx)` | Full scan via leaf chain; stops when callback returns false |
| `begin()` | Opens an explicit transaction; defers `flush()` until commit |
| `commit()` | Flushes dirty pages to disk and discards the undo log |
| `rollback()` | Replays the undo log in reverse to restore prior state, then flushes |

When no explicit transaction is open (`txn == null`), every DML call flushes the pager immediately — this is *auto-commit* mode and preserves the original behaviour.

---

## Transaction System (`core/txn.zig`)

PagerDB uses a **logical undo log** to provide atomicity. Before each mutation, the inverse operation is recorded in memory. If the transaction is rolled back, the log is replayed in reverse to restore the previous state.

### Undo Log Entries

```
UndoEntry (union):
  insert  → { table, rowid }               undo = delete that rowid
  delete  → { table, rowid, row_bytes }     undo = re-insert original bytes
  update  → { table, rowid, old_row_bytes } undo = delete + re-insert old bytes
```

All strings and byte slices captured for undo live in a per-transaction `ArenaAllocator`. On commit or rollback the entire arena is freed in one call — no per-entry cleanup.

### Transaction Lifecycle

```
begin()   — error if already active; initialise Transaction{arena, log}
  │
  ├─ insert() → btree.insert; log UndoEntry.insert
  ├─ delete() → lookup old bytes; btree.delete; log UndoEntry.delete
  └─ update() → lookup old bytes; btree.delete + btree.insert; log UndoEntry.update
  │
  ├─ commit()   — pager.flush(); arena.deinit(); txn = null
  └─ rollback() — iterate log in reverse; apply inverse btree ops;
                  pager.flush(); arena.deinit(); txn = null
```

### Design Choices

- **Logical undo, not physical**: entries record row-level inverses (re-insert old bytes) rather than byte-level page diffs. This keeps the log small and implementation simple, at the cost of requiring the B-tree to be in a consistent state during replay.
- **In-memory only**: the undo log is not written to disk. A crash during an uncommitted transaction leaves the database in an inconsistent state — pages flushed mid-transaction may not be rolled back on next open. Durability requires WAL (redo log), which is the planned next step.
- **rowid counter is not rolled back**: after a rolled-back INSERT the rowid counter stays advanced. Gaps in rowid sequences are acceptable.
- **Auto-commit**: when `txn == null`, each DML op calls `pager.flush()` immediately, preserving the original one-op-per-fsync behaviour.

---

## SQL Pipeline (`src/sql/`)

SQL text goes through five stages before producing a result set.

### 1. Lexer (`sql/lexer.zig`)

Tokenises the input string into a flat token stream: keywords, identifiers, literals, operators, punctuation.

### 2. Parser (`sql/parser.zig`)

Recursive-descent parser that builds an AST. Supported statements:

```sql
CREATE TABLE t (col TYPE [NOT NULL], ...)
INSERT INTO t VALUES (v1, v2, ...)
SELECT [* | col, ...] FROM t [WHERE expr]
UPDATE t SET col = expr [WHERE expr]
DELETE FROM t [WHERE expr]
BEGIN
COMMIT
ROLLBACK
```

Expression grammar supports: integer/float/string literals, column references (including `_rowid_`), binary operators (`=`, `!=`, `<`, `<=`, `>`, `>=`, `AND`, `OR`, `+`, `-`, `*`, `/`), and unary `NOT`.

### 3. Logical Planner (`sql/logical_plan.zig`)

Transforms the AST into a logical plan with semantic analysis:
- Resolves column names to 0-based indices within the table schema.
- Validates expression types.
- Recognises virtual table names and validates argument counts.

**Plan nodes**: `SeqScan`, `VTabScan`, `Filter`, `Project`, `Insert`, `Update`, `Delete`.

Example — `SELECT name FROM users WHERE score > 60`:
```
Project([col_idx=0])
  └─ Filter(Binary(GT, col_idx=1, int_lit=60))
       └─ SeqScan("users")
```

### 4. Physical Planner (`sql/physical_plan.zig`)

Applies rule-based optimisations:

- **Point lookup**: If a `Filter` over `SeqScan` has an equality condition on `_rowid_`, it is replaced by `PointLookup(rowid=N)` — a direct B-tree lookup instead of a full scan.
- **Virtual table dispatch**: `VTabScan` is passed through unchanged; the executor calls the vtab's scan function.

Physical plan node set mirrors the logical set plus `PointLookup`.

### 5. Executor (`sql/executor.zig`)

Walks the physical plan tree and produces a `ResultSet`:

```zig
ResultSet {
  columns: [][]const u8,   // column names
  rows:    []Row,          // arena-owned row values
  arena:   ArenaAllocator, // freed by ResultSet.deinit()
}
```

Row collection per node type:

| Node | Action |
|---|---|
| `SeqScan` | Calls `Db.scan()` with a callback |
| `VTabScan` | Calls the virtual table's `scan` function |
| `PointLookup` | Calls `Db.getByRowid()` |
| `Filter` | Evaluates predicate via `eval.evalExpr()`, drops non-matching rows |
| `Project` | Selects output columns by index |
| `Insert` | Evaluates value expressions, calls `Db.insert()` |
| `Update` | Collects matching rows, calls `Db.update()` for each |
| `Delete` | Collects matching rows, calls `Db.delete()` for each |

### Expression Evaluator (`sql/eval.zig`)

`evalExpr()` recursively evaluates a logical plan expression against a row's `Value` slice.

- **Three-valued logic**: Any operand that is NULL propagates NULL through arithmetic and comparison.
- **Type coercion**: INT and REAL interoperate in comparisons and arithmetic; TEXT and BLOB do not mix with numeric types.
- **Short-circuit**: `AND` and `OR` short-circuit evaluation.
- **Division by zero**: Returns an error (not a NULL or infinity).

---

## Virtual Tables (`src/sql/vtab.zig`)

Virtual tables are read-only tables that generate rows at query time. They do not have an on-disk B-tree.

**VTab descriptor**:
```zig
VTab {
  name:     []const u8,
  columns:  []const VTabColumn,
  min_args: usize,
  max_args: usize,
  scan:     fn(pager, args, out, alloc) anyerror!void,
}
```

Virtual tables are registered in a static `REGISTRY` array. The logical planner looks them up by name; the executor calls `scan` and feeds the rows through any `Filter`/`Project` nodes above the `VTabScan` as normal.

**Built-in virtual tables**:

| Table | Args | Columns | Purpose |
|---|---|---|---|
| `__pages` | none | `page_id INT, page_type TEXT` | Lists every page in the file with its type |
| `__page_slots(page_id)` | 1 INT | `slot_idx INT, rowid INT, data_len INT, is_overflow INT` | Lists every cell in a specific B-tree page |

To add a new virtual table: implement a `scan` function, add a `VTab` descriptor to `REGISTRY`.

---

## Memory Management

| Component | Strategy |
|---|---|
| Pager buffer pool | Fixed 64-frame array, stack allocated inside `Pager` |
| Catalog strings | Heap-allocated via `allocator.dupe()`, freed on `close()` |
| Transaction undo log | `ArenaAllocator` per transaction; freed atomically on commit or rollback |
| Parse / plan pass | `ArenaAllocator`, freed immediately after query execution |
| Result set | `ArenaAllocator` inside `ResultSet`, freed by `deinit()` |

No garbage collection. Every allocation is paired with a deterministic free.

---

## Type Definitions (`src/types.zig`)

```zig
PAGE_SIZE          = 8_192
OVERFLOW_THRESHOLD = 2_048   // PAGE_SIZE / 4

PageType: enum(u8) { btree_internal=1, btree_leaf=2, overflow=3, free=4 }
ColType:  enum(u8) { int=0, real=1, text=2, blob=3 }
```

All on-disk structures use `extern struct` for a fixed, predictable layout.

---

## Known Limitations

1. **No WAL / crash recovery** — the undo log is in-memory only. A crash mid-transaction can leave dirty pages on disk with no way to roll them back on reopen. Durability requires a redo log (WAL), which is the planned next step.
2. **No nested transactions** — `BEGIN` inside an active transaction returns `error.TransactionAlreadyActive`. Savepoints are not supported.
3. **DDL is not transactional** — `CREATE TABLE` calls `pager.flush()` immediately regardless of whether a transaction is open.
4. **No root internal-node split** — B-trees cannot grow past a single level of internal nodes (`NotImplementedYet` error).
5. **No secondary indexes** — all searches are by rowid; range and equality scans on non-rowid columns require a full table scan.
6. **No aggregates** — `COUNT`, `SUM`, `AVG`, etc. are not implemented.
7. **No `ORDER BY`, `GROUP BY`, or `JOIN`** — single-table queries only.
8. **No function calls in SQL** — only `_rowid_` pseudo-column is special-cased.
