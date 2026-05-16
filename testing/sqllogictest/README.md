# sqllogictest Runner

A [sqllogictest](https://www.sqlite.org/sqllogictest/doc/trunk/about.wiki)-compatible test runner for VisalDB. Test files are plain text (`.slt` or `.test`) describing SQL statements and expected query results.

## Usage

```bash
# Scan the built-in tests/ directory (default)
zig build slt

# Scan any directory recursively for .slt and .test files
zig build slt -- --dir testing/sqllogictest/upstream

# Run a specific file
zig build slt -- testing/sqllogictest/tests/basic.test

# Show up to N individual failure details per file
zig build slt -- --show-errors 5
zig build slt -- --dir testing/sqllogictest/upstream --show-errors 5
```

## Output format

By default the runner prints one summary line per file and a final total — no individual failure lines:

```
testing/sqllogictest/tests/aggregate.test: 19 passed, 0 failed [ok]
testing/sqllogictest/tests/basic.test:    13 passed, 0 failed [ok]
testing/sqllogictest/tests/select.test:   20 passed, 0 failed [ok]

52 passed, 0 failed across 3 file(s)
```

Add `--show-errors N` to reveal the first N failure details per file:

```
FAIL testing/sqllogictest/tests/basic.test:12: expected ok but got error: no such column: x
  ... and 3 more failure(s) not shown
```

## Upstream test suite

The `upstream/` folder holds the original SQLite sqllogictest files. It is gitignored and must be fetched manually.

**Fetch the upstream tests** (clone to a temp location, copy only the test files — no `.git/` included):

```bash
git clone --depth=1 https://github.com/invisal/sqllogictest /tmp/slt-upstream
cp -r /tmp/slt-upstream/test testing/sqllogictest/upstream
rm -rf /tmp/slt-upstream
```

**Then run them:**

```bash
zig build slt -- --dir testing/sqllogictest/upstream
```

Many upstream tests will fail — they cover SQL features not yet implemented in VisalDB. That is expected. Use the per-file summary to track compatibility progress.

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
