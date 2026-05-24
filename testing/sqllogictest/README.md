# sqllogictest Runner

A [sqllogictest](https://www.sqlite.org/sqllogictest/doc/trunk/about.wiki)-compatible test runner for PagerDB. Test files are plain text (`.test`) describing SQL statements and expected query results.

## Running tests

### All local test files

Uses the Bun runner (`runner.ts`), which runs every `.test` file in the directory as a separate process, collects results, and prints a summary. Requires `zig build` to have run first.

```bash
bun runner.ts --no-build
```

Or let the runner build the binary itself:

```bash
bun runner.ts
```

### Single file

```bash
zig build slt -- testing/sqllogictest/tests/basic.test
```

## runner.ts options

| Flag | Default | Description |
|------|---------|-------------|
| `--dir <path>` | `testing/sqllogictest/tests` | Directory of `.test` files to run |
| `--json <path>` | *(none)* | Write a JSON report (see schema below) |
| `--commit <sha>` | `unknown` | Commit SHA to embed in the JSON report |
| `--timeout <sec>` | `180` | Per-file timeout in seconds |
| `--no-build` | *(off)* | Skip `zig build` (binary must already exist) |

### JSON report schema

The `--json` output matches the `CoveragePayload` type consumed by the site:

```json
{
  "generated_at": 1700000000,
  "commit": "abc123",
  "summary": { "passed": 404, "failed": 0, "files": 21 },
  "files": [
    { "path": "basic.test", "passed": 13, "failed": 0 }
  ]
}
```

## Upstream test suite

The `upstream/` folder holds the original SQLite sqllogictest files. It is gitignored and must be fetched manually.

```bash
git clone --depth=1 https://github.com/invisal/sqllogictest /tmp/slt-upstream
cp -r /tmp/slt-upstream/test testing/sqllogictest/upstream
rm -rf /tmp/slt-upstream
```

Then run against the upstream suite:

```bash
bun runner.ts --dir testing/sqllogictest/upstream
```

Many upstream tests will fail — they cover SQL features not yet implemented in PagerDB. That is expected. Use the per-file summary to track compatibility progress.

## Test file format

```
# comment

statement ok
CREATE TABLE t (id INTEGER NOT NULL, name TEXT NOT NULL);

statement error
SELECT bad_col FROM t;

query IT rowsort
SELECT id, name FROM t;
----
1
alice
2
bob
```

| Directive | Meaning |
|-----------|---------|
| `statement ok` | Execute SQL; expect success |
| `statement error` | Execute SQL; expect an error |
| `query <types> [sort]` | Execute SQL; compare result values to expected |
| `skipif <engine>` | Skip the next record if engine is `visaldb` |
| `onlyif <engine>` | Skip the next record if engine is not `visaldb` |

**Type string letters:** `I` integer · `R` real · `T` text

**Sort modes:** *(none)* exact order · `rowsort` sort rows · `valuesort` sort all values flat

Result values are listed one per line after `----`, flattened across all columns.
