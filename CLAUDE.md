# PagerDB — Agent Rules

## After Every Fix

Run these two commands after every code change, in order:

```
zig fmt .
zig build
```

Do not report a fix as complete until both commands succeed without errors.

## Comments

This is a learning project. Add comments to explain:
- Non-obvious design decisions or trade-offs
- How algorithms or data structures work at a high level
- Why a particular approach was chosen over alternatives

Skip comments that just restate what the code already says.
