# PagerDB — Agent Rules

## After Every Fix

Run these commands after every code change, in order:

```
zig fmt .
zig build
zig build slt
```

Do not report a fix as complete until all three succeed without errors.

## Code Guidelines

**Parameter ordering** — Free functions and constructors (`init`, `create`, `open`, etc.) take infrastructure parameters first: `alloc: std.mem.Allocator`, then `io` (either `std.Io` or the custom `Io` abstraction), then domain-specific parameters. Does not apply to struct methods (`self` or `ptr: *anyopaque` first parameter).

**Comments** — This is a learning project. Explain non-obvious design decisions, how algorithms or data structures work, and why an approach was chosen over alternatives. Skip comments that just restate what the code already says.

## Testing Guidelines

SQL behaviour tests go in `testing/sqllogictest/tests/` as `.test` files. Use Zig tests only for assertions `.test` files cannot make: `affected` row counts, specific error codes, column name checks, internal API calls, or disk-reopen tests.
