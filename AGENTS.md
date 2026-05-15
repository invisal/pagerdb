# PagerDB — Agent Rules

## After Every Fix

Run these two commands after every code change, in order:

```
zig fmt .
zig build
```

Do not report a fix as complete until both commands succeed without errors.

## Code Guidelines

**Parameter ordering** — Free functions and constructors (`init`, `create`, `open`, etc.) take infrastructure parameters first: `alloc: std.mem.Allocator`, then `io` (either `std.Io` or the custom `Io` abstraction), then domain-specific parameters. Does not apply to struct methods (`self` or `ptr: *anyopaque` first parameter).

**Comments** — This is a learning project. Explain non-obvious design decisions, how algorithms or data structures work, and why an approach was chosen over alternatives. Skip comments that just restate what the code already says.
