// WASM binding for PagerDB — exposes an in-memory SQL database to JavaScript.
//
// Memory bridge pattern:
//   1. JS calls db_alloc(len) to get a pointer into WASM linear memory
//   2. JS writes SQL bytes at that pointer
//   3. JS calls db_exec(ptr, len); result JSON is written to an internal buffer
//   4. JS reads len bytes from db_result_ptr() to get the JSON
//   5. JS calls db_free(ptr, len) to release the SQL buffer
//
// All results (including errors) are returned as JSON:
//   SELECT  → {"type":"select","columns":[...],"rows":[[...],...]}
//   DML     → {"type":"affected","count":N}
//   DDL     → {"type":"created"}
//   Error   → {"type":"error","message":"..."}

const std = @import("std");
// "core" is a named module added in build.zig, rooted at core/wasm_root.zig.
// It exposes only the WASM-safe subset (no DiskPager, no WAL).
const core = @import("core");

// Minimal panic handler — traps instead of printing stack traces.
// Required for wasm32-freestanding where OS panic infrastructure is absent.
pub const panic = std.debug.no_panic;

// wasm_allocator is backed by @wasmMemoryGrow — no OS calls.
const allocator = std.heap.wasm_allocator;

var g_db: ?*core.Database = null;
var g_result: std.Io.Writer.Allocating = undefined;
var g_initialized: bool = false;

/// Create an in-memory database. Must be called before any other function.
/// Returns 0 on success, -1 on allocation failure.
export fn db_init() i32 {
    if (g_initialized) return 0;
    const pager = core.InMemoryPager.create(allocator) catch return -1;
    g_db = core.Database.init(pager, allocator) catch return -1;
    g_result = .init(allocator);
    g_initialized = true;
    return 0;
}

/// Allocate a buffer in WASM linear memory for the caller to write SQL into.
/// Returns null (0) on allocation failure.
export fn db_alloc(len: usize) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Free a buffer previously returned by db_alloc.
export fn db_free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

/// Execute a SQL statement. Writes the JSON result to an internal buffer.
/// Returns the byte length of the result JSON, or -1 on catastrophic failure.
/// Call db_result_ptr() to get a pointer to the result bytes.
export fn db_exec(sql_ptr: [*]const u8, sql_len: usize) i32 {
    if (!g_initialized) return -1;
    const sql = sql_ptr[0..sql_len];
    g_result.clearRetainingCapacity();
    execInner(sql) catch |err| {
        writeError(err) catch return -1;
        return @intCast(g_result.written().len);
    };
    return @intCast(g_result.written().len);
}

/// Returns a pointer to the result JSON from the most recent db_exec call.
/// The data is valid until the next db_exec or db_close call.
export fn db_result_ptr() [*]const u8 {
    return g_result.written().ptr;
}

/// Close the database and free all resources.
export fn db_close() void {
    if (g_db) |db| {
        db.close(); // also closes pager and frees db allocation
        g_db = null;
    }
    if (g_initialized) {
        g_result.deinit();
    }
    g_initialized = false;
}

fn execInner(sql: []const u8) !void {
    var result = try core.execute(allocator, g_db.?, sql);
    defer result.deinit();
    try writeResult(result);
}

fn writeResult(result: core.ExecResult) !void {
    var jw: std.json.Stringify = .{ .writer = &g_result.writer };
    switch (result) {
        .result_set => |rs| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("select");
            try jw.objectField("columns");
            try jw.beginArray();
            for (rs.columns) |col| try jw.write(col);
            try jw.endArray();
            try jw.objectField("rows");
            try jw.beginArray();
            for (rs.rows) |row| {
                try jw.beginArray();
                for (row.values) |val| {
                    switch (val) {
                        .null => try jw.write(@as(?u8, null)),
                        .int => |n| try jw.write(n),
                        .real => |f| try jw.write(f),
                        .text => |s| try jw.write(s),
                        .blob => |b| try jw.write(b),
                    }
                }
                try jw.endArray();
            }
            try jw.endArray();
            try jw.endObject();
        },
        .affected => |n| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("affected");
            try jw.objectField("count");
            try jw.write(n);
            try jw.endObject();
        },
        .created => {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("created");
            try jw.endObject();
        },
        .err => |e| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("error");
            try jw.objectField("code");
            try jw.write(e.code);
            try jw.objectField("message");
            try jw.write(e.message);
            try jw.endObject();
        },
    }
}

// writeError handles unexpected system failures (OOM, I/O) that were not
// caught as SQL-level errors and converted to ExecResult.err.
fn writeError(err: anyerror) !void {
    var jw: std.json.Stringify = .{ .writer = &g_result.writer };
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("error");
    try jw.objectField("code");
    try jw.write(@errorName(err));
    try jw.objectField("message");
    try jw.write(@errorName(err));
    try jw.endObject();
}
