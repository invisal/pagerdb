# PagerDB

A toy database written in Zig for learning purposes. This project explores database internals while learning Zig, with a focus on simplicity and modularity.

> **Status:** Work in progress — many features are incomplete.  
> The page layout and file format are still highly experimental and will change frequently. Database files may not be compatible across versions.

## Overview

PagerDB implements core database concepts from scratch:

- **Pluggable Pager** — Manages fixed-size pages on disk with read/write caching; swappable backend (disk, memory, etc.)
- **B-Tree** — Used for table storage (clustered index)
- **Storage format** — Custom binary format for rows and metadata
- **SQL-like interface** — Simple REPL for interactive queries

Major features not yet implemented:

- **WAL** — Write-ahead logging for durability
- **Transactions** — ACID transactions with rollback
- **Secondary Indexes** — Non-clustered B-Tree indexes
- **Query Optimizer** — Cost-based plan selection

## Quick Start

### Build

```bash
zig build
```

### Run

```bash
./zig-out/bin/pagerdb <database-file>
```

Create or open a database file:

```bash
# Create a new database
./zig-out/bin/pagerdb mydb.db

# Reopen an existing database
./zig-out/bin/pagerdb mydb.db
```

Or run directly through the build system:

```bash
zig build run -- mydb.db
```

### Run Tests

```bash
zig build test
```

## Benchmarks

See [bench/README.md](bench/README.md) for instructions on running performance comparisons against SQLite3.

## AI Usage

This project uses AI assistance for:
- Initial code generation and scaffolding
- Documentation and comments (English is not the author's first language)

## Contributing

Contributions are not accepted. This is a personal learning project, and external contributions would defeat that purpose.

## License

MIT License — see [LICENSE](LICENSE) for details.
