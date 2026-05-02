const std = @import("std");
const t = @import("../types.zig");
const ast = @import("../sql/ast.zig");
const Parser = @import("../sql/parser.zig").Parser;

test "parse SELECT *" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("SELECT * FROM users", alloc);
    defer res.deinit();

    const s = res.stmt.select;
    try std.testing.expectEqualStrings("users", s.table_ref.name.name);
    try std.testing.expect(s.table_ref.name.schema == null);
    try std.testing.expectEqual(@as(usize, 0), s.columns.len);
    try std.testing.expect(s.where == null);
}

test "parse SELECT * with schema" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("SELECT * FROM main.users", alloc);
    defer res.deinit();

    const s = res.stmt.select;
    try std.testing.expectEqualStrings("users", s.table_ref.name.name);
    try std.testing.expectEqualStrings("main", s.table_ref.name.schema.?);
}

test "parse SELECT * with information_schema schema" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("SELECT * FROM information_schema.tables", alloc);
    defer res.deinit();

    const s = res.stmt.select;
    try std.testing.expectEqualStrings("tables", s.table_ref.name.name);
    try std.testing.expectEqualStrings("information_schema", s.table_ref.name.schema.?);
}

test "parse SELECT columns with WHERE" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("SELECT name, score FROM users WHERE score > 100", alloc);
    defer res.deinit();

    const s = res.stmt.select;
    try std.testing.expectEqual(@as(usize, 2), s.columns.len);
    try std.testing.expectEqualStrings("name", s.columns[0].name);
    try std.testing.expectEqualStrings("score", s.columns[1].name);
    const w = s.where.?.binary;
    try std.testing.expectEqual(ast.BinaryOp.gt, w.op);
}

test "parse SELECT * FROM tvf with no args" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("SELECT * FROM __pages()", alloc);
    defer res.deinit();

    const s = res.stmt.select;
    try std.testing.expect(s.table_ref.func.schema == null);
    try std.testing.expectEqualStrings("__pages", s.table_ref.func.name);
    try std.testing.expectEqual(@as(usize, 0), s.table_ref.func.args.len);
}

test "parse SELECT * FROM schema.tvf with no args" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("SELECT * FROM main.__pages()", alloc);
    defer res.deinit();

    const s = res.stmt.select;
    try std.testing.expectEqualStrings("main", s.table_ref.func.schema.?);
    try std.testing.expectEqualStrings("__pages", s.table_ref.func.name);
    try std.testing.expectEqual(@as(usize, 0), s.table_ref.func.args.len);
}

test "parse SELECT * FROM tvf with int arg" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("SELECT * FROM __page_slots(3)", alloc);
    defer res.deinit();

    const s = res.stmt.select;
    try std.testing.expect(s.table_ref.func.schema == null);
    try std.testing.expectEqualStrings("__page_slots", s.table_ref.func.name);
    try std.testing.expectEqual(@as(usize, 1), s.table_ref.func.args.len);
    try std.testing.expectEqual(@as(i64, 3), s.table_ref.func.args[0].int_lit);
}

test "parse INSERT" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("INSERT INTO t VALUES ('alice', 42, NULL)", alloc);
    defer res.deinit();

    const ins = res.stmt.insert;
    try std.testing.expectEqualStrings("t", ins.table);
    try std.testing.expectEqual(@as(usize, 3), ins.values.len);
    try std.testing.expectEqualStrings("alice", ins.values[0].str_lit);
    try std.testing.expectEqual(@as(i64, 42), ins.values[1].int_lit);
    _ = ins.values[2].null_lit;
}

test "parse INSERT with columns" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("INSERT INTO t(id, name) VALUES(5, 'visal')", alloc);
    defer res.deinit();

    const ins = res.stmt.insert;
    try std.testing.expectEqualStrings("t", ins.table);
    try std.testing.expectEqual(@as(usize, 2), ins.values.len);
    try std.testing.expectEqual(@as(usize, 2), ins.columns.len);
    try std.testing.expectEqualStrings("id", ins.columns[0]);
    try std.testing.expectEqualStrings("name", ins.columns[1]);
}

test "parse UPDATE" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("UPDATE t SET score = 999 WHERE name = 'bob'", alloc);
    defer res.deinit();

    const u = res.stmt.update;
    try std.testing.expectEqualStrings("t", u.table);
    try std.testing.expectEqualStrings("score", u.assignments[0].column);
    try std.testing.expectEqual(@as(i64, 999), u.assignments[0].value.int_lit);
    try std.testing.expect(u.where != null);
}

test "parse DELETE" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("DELETE FROM t WHERE id = 1", alloc);
    defer res.deinit();

    const d = res.stmt.delete;
    try std.testing.expectEqualStrings("t", d.table);
    try std.testing.expect(d.where != null);
}

test "parse CREATE TABLE" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse(
        "CREATE TABLE products (name TEXT NOT NULL, price REAL, qty INT)",
        alloc,
    );
    defer res.deinit();

    const ct = res.stmt.create_table;
    try std.testing.expectEqualStrings("products", ct.table);
    try std.testing.expectEqual(@as(usize, 3), ct.columns.len);
    try std.testing.expectEqualStrings("name", ct.columns[0].name);
    try std.testing.expectEqual(false, ct.columns[0].nullable);
    try std.testing.expectEqual(true, ct.columns[1].nullable);
    try std.testing.expectEqual(t.ColType.real, ct.columns[1].col_type);
}

test "parse CREATE TABLE with default value" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE products (
        \\  a TEXT DEFAULT 'PagerDB', 
        \\  b REAL DEFAULT 1 + (2 - 5),
        \\  c INT DEFAULT 1 + 2 NOT NULL
        \\);
    ;

    var res = try Parser.parse(sql, alloc);
    defer res.deinit();

    const ct = res.stmt.create_table;
    try std.testing.expectEqualStrings("products", ct.table);
    try std.testing.expectEqual(@as(usize, 3), ct.columns.len);

    try std.testing.expectEqualStrings("'PagerDB'", ct.columns[0].default_src.?);

    try std.testing.expectEqualStrings(
        "1 + (2 - 5)",
        ct.columns[1].default_src.?,
    );
    try std.testing.expectEqualStrings(
        "1 + 2",
        ct.columns[2].default_src.?,
    );
    try std.testing.expectEqual(false, ct.columns[2].nullable);
}

test "parse AND / OR precedence" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("SELECT * FROM t WHERE a = 1 OR b = 2 AND c = 3", alloc);
    defer res.deinit();

    const w = res.stmt.select.where.?;
    try std.testing.expectEqual(ast.BinaryOp.or_, w.binary.op);
    try std.testing.expectEqual(ast.BinaryOp.and_, w.binary.right.binary.op);
}

test "parse nested parens" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("SELECT * FROM t WHERE (a = 1 OR b = 2) AND c = 3", alloc);
    defer res.deinit();

    const w = res.stmt.select.where.?;
    try std.testing.expectEqual(ast.BinaryOp.and_, w.binary.op);
    try std.testing.expectEqual(ast.BinaryOp.or_, w.binary.left.binary.op);
}

test "parse string with escaped quote" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("INSERT INTO t VALUES ('alice''s')", alloc);
    defer res.deinit();

    try std.testing.expectEqualStrings("alice's", res.stmt.insert.values[0].str_lit);
}

test "parse unary negation" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("INSERT INTO t VALUES (-42)", alloc);
    defer res.deinit();

    const expr = res.stmt.insert.values[0];
    try std.testing.expectEqual(ast.UnaryOp.neg, expr.unary.op);
    try std.testing.expectEqual(@as(i64, 42), expr.unary.operand.int_lit);
}

test "parse NOT expression" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("SELECT * FROM t WHERE NOT done = 1", alloc);
    defer res.deinit();

    const w = res.stmt.select.where.?;
    try std.testing.expectEqual(ast.UnaryOp.not, w.unary.op);
}

test "parse arithmetic in expression" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("SELECT * FROM t WHERE score + 10 > 100", alloc);
    defer res.deinit();

    const w = res.stmt.select.where.?.binary;
    try std.testing.expectEqual(ast.BinaryOp.gt, w.op);
    try std.testing.expectEqual(ast.BinaryOp.add, w.left.binary.op);
}

test "parse DELETE without WHERE" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("DELETE FROM t", alloc);
    defer res.deinit();

    try std.testing.expect(res.stmt.delete.where == null);
}

test "parse UPDATE multiple assignments" {
    const alloc = std.testing.allocator;
    var res = try Parser.parse("UPDATE t SET a = 1, b = 2", alloc);
    defer res.deinit();

    try std.testing.expectEqual(@as(usize, 2), res.stmt.update.assignments.len);
    try std.testing.expectEqualStrings("a", res.stmt.update.assignments[0].column);
    try std.testing.expectEqualStrings("b", res.stmt.update.assignments[1].column);
}
