# Benchmarks

This directory contains benchmarks comparing PagerDB against SQLite3.

## What is Measured

- **INSERT** — Bulk insertions with per-statement durability (fsync)
- **SELECT *** — Full table scan reading all rows
- **SELECT WHERE** — Filtered scan without indexes
- **File size** — On-disk footprint after insertions

Both databases commit every statement individually (no batching) for a fair apples-to-apples comparison of per-statement durability cost.

## Prerequisites

SQLite3 development headers must be installed:

```bash
# Debian / Ubuntu / WSL2
sudo apt install libsqlite3-dev

# Fedora / RHEL
sudo dnf install sqlite-devel

# macOS
brew install sqlite
```

## Running Benchmarks

```bash
zig build bench -Doptimize=ReleaseFast
```

The benchmark will run with different row counts and output timing comparisons.

## Benchmark Data

Benchmark databases are created in `bench/data/` and cleaned up automatically after each run.
