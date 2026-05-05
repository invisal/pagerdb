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

pub const EvalError = error{ TypeMismatch, DivisionByZero };
