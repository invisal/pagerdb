# Deterministic Simulation Testing (DST)

DST finds bugs that unit tests miss by running many randomly-generated workloads and checking structural invariants after every operation. Every run is reproducible: a failing seed can be replayed exactly.

## What it tests

Each seed runs a sequence of random operations weighted 60% INSERT / 20% UPDATE / 20% DELETE (always INSERT when the table is empty). After every operation the following invariants are checked:

- **Catalog consistency** — every table in the catalog has at least one column defined.
- **B-tree structure** — rowids within each leaf page are strictly ascending; separator rowids in internal pages are strictly ascending; the leaf doubly-linked chain has consistent `prev_leaf`/`next_leaf` pointers. Both tree traversal and chain walk are bounded by `total_pages` to catch pointer cycles (`LeafChainCycle`, `TreeDepthExceeded`).
- **Row count** — `SELECT *` returns exactly as many rows as the shadow state tracks.

## How to run

```sh
# Default: 200 seeds, 50 ops each
zig build dst

# More thorough
zig build dst -- --seeds 1000 --ops 100

# Replay one specific seed (useful after a failure)
zig build dst -- --seed 42

# Adjust ops only
zig build dst -- --ops 200
```

## Reading the output

A passing run prints progress every 50 seeds:

```
[DST] 50/200 seeds passed
[DST] 100/200 seeds passed
...
[DST] 200 seeds passed (50 ops each)
```

A failure prints the failing seed and exits with code 1:

```
[DST] FAILED seed=137: RowCountMismatch
```

Replay it with `--seed 137` to reproduce deterministically.

## File layout

| File | Purpose |
|------|---------|
| `main.zig` | Runner: arg parsing, seed loop, per-seed orchestration |
| `workload.zig` | Seeded random INSERT/UPDATE/DELETE generator and shadow state |
| `checker.zig` | Invariant checks: catalog consistency, B-tree structure, row count |
