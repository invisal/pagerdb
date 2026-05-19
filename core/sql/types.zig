const std = @import("std");

// Runtime value type used throughout expression evaluation.  Kept separate from
// row.Value (the storage type) because evaluation produces booleans — transient
// results from comparisons and logical operators — which have no disk encoding.
pub const EvalValue = union(enum) {
    int: i64,
    real: f64,
    text: []const u8, // not owned — points into row data or a literal
    bool_: bool,
    null_: void,
};

pub const EvalError = error{ TypeMismatch, OutOfMemory };

// Caches non-correlated IN-subquery result sets for the lifetime of one query
// execution.  Key = plan pointer (stable within a query); value = all
// first-column values from that subquery, allocated on the per-query arena.
pub const SubqueryCache = std.AutoHashMapUnmanaged(*anyopaque, []EvalValue);
