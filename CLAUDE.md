# PagerDB — Agent Rules

## After Every Fix

Run these two commands after every code change, in order:

```
zig fmt .
zig build
```

Do not report a fix as complete until both commands succeed without errors.

## Parameter Ordering

For free functions and constructors (`init`, `create`, `open`, etc.), infrastructure parameters always come first in this order:

1. `alloc: std.mem.Allocator` (if present)
2. `io: std.Io` (if present)
3. Domain-specific parameters

Do not apply this to struct methods (functions with a `self` or `ptr: *anyopaque` first parameter).

## Comments

This is a learning project. Add comments to explain:
- Non-obvious design decisions or trade-offs
- How algorithms or data structures work at a high level
- Why a particular approach was chosen over alternatives

Skip comments that just restate what the code already says.
