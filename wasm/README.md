# PagerDB WASM Binding

Compiles PagerDB's in-memory SQL engine to WebAssembly so it can run inside a browser or Node.js. No files are read or written — everything lives in WASM linear memory.

## Build

```sh
zig build wasm
```

Output: **`zig-out/bin/pagerdb.wasm`** (~160 KB, `ReleaseSmall`)

## Files

| File | Purpose |
|------|---------|
| `wasm/root.zig` | Exported WASM functions (`db_init`, `db_exec`, …) |
| `wasm/pagerdb.js` | JavaScript wrapper — use this, not the raw exports |
| `core/wasm_root.zig` | WASM-safe API subset of `core/` (no disk I/O) |

## JavaScript usage

The wrapper exports a single `ManagedDatabase` class with three methods: `open`, `execute`, `close`.

### Browser

```js
import { ManagedDatabase } from './pagerdb.js';

const db = await ManagedDatabase.open('/pagerdb.wasm');

db.execute("CREATE TABLE users (id int, name text)");
db.execute("INSERT INTO users VALUES (1, 'Alice')");
db.execute("INSERT INTO users VALUES (2, 'Bob')");

const result = db.execute("SELECT * FROM users WHERE id = 1");
console.log(result);
// { type: "select", columns: ["id", "name"], rows: [[1, "Alice"]] }

db.close();
```

### Node.js

```js
import { ManagedDatabase } from './pagerdb.js';
import { readFileSync } from 'fs';

const db = await ManagedDatabase.open(readFileSync('./zig-out/bin/pagerdb.wasm'));
const result = db.execute("SELECT 1 + 1");
console.log(result);
db.close();
```

## Result shapes

Every `execute` call returns a plain object:

| Statement | Shape |
|-----------|-------|
| `SELECT` | `{ type: "select", columns: string[], rows: any[][] }` |
| `INSERT / UPDATE / DELETE` | `{ type: "affected", count: number }` |
| `CREATE TABLE` | `{ type: "created" }` |
| Error | `{ type: "error", message: string }` |

## SQL notes

Column types use the short lowercase keywords the parser recognises: `int`, `real`, `text`, `blob`.

```sql
CREATE TABLE products (id int, price real, name text, data blob)
```

## Raw WASM exports

If you need to call the WASM module directly (without `pagerdb.js`), the exported functions are:

| Export | Signature | Description |
|--------|-----------|-------------|
| `db_init` | `() → i32` | Initialise DB. Returns 0 on success, -1 on failure. |
| `db_alloc` | `(len: i32) → i32` | Allocate a buffer in WASM memory. Returns pointer (0 = OOM). |
| `db_free` | `(ptr: i32, len: i32) → void` | Free a buffer allocated by `db_alloc`. |
| `db_exec` | `(ptr: i32, len: i32) → i32` | Execute SQL. Returns byte-length of JSON result, -1 on error. |
| `db_result_ptr` | `() → i32` | Pointer to the JSON result from the last `db_exec`. |
| `db_close` | `() → void` | Close the database and release all resources. |
