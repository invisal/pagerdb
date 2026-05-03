const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const t = @import("../types.zig");

const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidType,
    OutOfMemory,
} || lexer.LexError;

pub const ParseResult = struct {
    arena: std.heap.ArenaAllocator,
    stmt: ast.Stmt,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

pub const ParseExprResult = struct {
    arena: std.heap.ArenaAllocator,
    expr: ast.Expr,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

pub const Parser = struct {
    tokens: []const Token,
    src: []const u8,
    pos: usize,
    arena: std.heap.ArenaAllocator,

    pub fn parse(src: []const u8, allocator: std.mem.Allocator) ParseError!ParseResult {
        const tokens = try lexer.Lexer.tokenize(src, allocator);
        defer allocator.free(tokens);

        var p = Parser{
            .tokens = tokens,
            .src = src,
            .pos = 0,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer p.arena.deinit();

        const stmt = try p.parseStmt();
        return ParseResult{ .arena = p.arena, .stmt = stmt };
    }

    pub fn parseStandaloneExpr(src: []const u8, allocator: std.mem.Allocator) ParseError!ParseExprResult {
        const tokens = try lexer.Lexer.tokenize(src, allocator);
        defer allocator.free(tokens);

        var p = Parser{
            .tokens = tokens,
            .src = src,
            .pos = 0,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer p.arena.deinit();

        const expr = try p.parseExpr();
        if (p.peek().kind == .semicolon) {
            _ = p.advance();
        }

        if (p.peek().kind != .eof) {
            return error.UnexpectedToken;
        }

        return ParseExprResult{ .arena = p.arena, .expr = expr };
    }

    fn alloc(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn peek(self: *Parser) Token {
        if (self.pos < self.tokens.len) return self.tokens[self.pos];
        return Token{ .kind = .eof, .start = 0, .len = 0 };
    }

    fn advance(self: *Parser) Token {
        const tok = self.peek();
        if (self.pos < self.tokens.len) self.pos += 1;
        return tok;
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!Token {
        const tok = self.peek();
        if (tok.kind != kind) return ParseError.UnexpectedToken;
        return self.advance();
    }

    fn tokenText(self: *Parser, tok: Token) []const u8 {
        return self.src[tok.start .. tok.start + tok.len];
    }

    fn parseStmt(self: *Parser) ParseError!ast.Stmt {
        return switch (self.peek().kind) {
            .kw_select => .{ .select = try self.parseSelect() },
            .kw_insert => .{ .insert = try self.parseInsert() },
            .kw_update => .{ .update = try self.parseUpdate() },
            .kw_delete => .{ .delete = try self.parseDelete() },
            .kw_create => .{ .create_table = try self.parseCreateTable() },
            else => ParseError.UnexpectedToken,
        };
    }

    // ── SELECT ────────────────────────────────────────────────────────────────

    fn parseSelect(self: *Parser) ParseError!ast.SelectStmt {
        _ = try self.expect(.kw_select);

        var columns: std.ArrayList(ast.SelectCol) = .empty;

        if (self.peek().kind == .op_star) {
            _ = self.advance();
            // empty list signals SELECT *
        } else {
            while (true) {
                const tok = try self.expect(.identifier);
                const name = try self.alloc().dupe(u8, self.tokenText(tok));
                try columns.append(self.alloc(), .{ .name = name });
                if (self.peek().kind != .comma) break;
                _ = self.advance();
            }
        }

        _ = try self.expect(.kw_from);
        const qualified_name = try self.parseQualifiedName();

        // Parse optional TVF args: FROM name(arg, ...) or schema.name(arg, ...)
        const table_ref: ast.TableRef = if (self.peek().kind == .lparen) blk: {
            _ = self.advance();
            var args: std.ArrayList(ast.Expr) = .empty;
            if (self.peek().kind != .rparen) {
                while (true) {
                    try args.append(self.alloc(), try self.parseExpr());
                    if (self.peek().kind != .comma) break;
                    _ = self.advance();
                }
            }
            _ = try self.expect(.rparen);
            break :blk .{ .func = .{
                .schema = qualified_name.schema,
                .name = qualified_name.name,
                .args = try args.toOwnedSlice(self.alloc()),
            } };
        } else .{ .name = qualified_name };

        var where: ?ast.Expr = null;
        if (self.peek().kind == .kw_where) {
            _ = self.advance();
            where = try self.parseExpr();
        }

        return ast.SelectStmt{
            .table_ref = table_ref,
            .columns = try columns.toOwnedSlice(self.alloc()),
            .where = where,
        };
    }

    // Parse a qualified name: identifier or identifier.identifier
    // Returns the qualified name with optional schema (null if not specified)
    fn parseQualifiedName(self: *Parser) ParseError!ast.QualifiedName {
        const first_tok = try self.expect(.identifier);
        const first_name = try self.alloc().dupe(u8, self.tokenText(first_tok));

        // Check for schema.table pattern
        if (self.peek().kind == .dot) {
            _ = self.advance(); // consume '.'
            const second_tok = try self.expect(.identifier);
            const second_name = try self.alloc().dupe(u8, self.tokenText(second_tok));
            return ast.QualifiedName{
                .schema = first_name, // first identifier is schema
                .name = second_name, // second identifier is table
            };
        }

        // No schema specified, default to null (will be treated as "main")
        return ast.QualifiedName{
            .schema = null,
            .name = first_name,
        };
    }

    // ── INSERT ────────────────────────────────────────────────────────────────

    fn parseInsert(self: *Parser) ParseError!ast.InsertStmt {
        _ = try self.expect(.kw_insert);
        _ = try self.expect(.kw_into);

        const table_tok = try self.expect(.identifier);
        const table = try self.alloc().dupe(u8, self.tokenText(table_tok));

        var columns: std.ArrayList([]const u8) = .empty;

        // Parsing the column list
        // Support INSERT table(columns)
        if (self.peek().kind == .lparen) {
            _ = self.advance();

            while (true) {
                const column = try self.expect(.identifier);
                try columns.append(self.alloc(), try self.alloc().dupe(u8, self.tokenText(column)));

                switch (self.advance().kind) {
                    .rparen => break,
                    .comma => continue,
                    else => {
                        return ParseError.UnexpectedToken;
                    },
                }
            }
        }

        _ = try self.expect(.kw_values);
        _ = try self.expect(.lparen);

        var values: std.ArrayList(ast.Expr) = .empty;

        while (true) {
            if (self.peek().kind == .kw_default) {
                _ = self.advance();
                try values.append(self.alloc(), .default_value);
            } else {
                try values.append(self.alloc(), try self.parseExpr());
            }

            if (self.peek().kind != .comma) break;
            _ = self.advance();
        }

        _ = try self.expect(.rparen);

        return ast.InsertStmt{
            .table = table,
            .values = try values.toOwnedSlice(self.alloc()),
            .columns = try columns.toOwnedSlice(self.alloc()),
        };
    }

    // ── UPDATE ────────────────────────────────────────────────────────────────

    fn parseUpdate(self: *Parser) ParseError!ast.UpdateStmt {
        _ = try self.expect(.kw_update);

        const table_tok = try self.expect(.identifier);
        const table = try self.alloc().dupe(u8, self.tokenText(table_tok));

        _ = try self.expect(.kw_set);

        var assignments: std.ArrayList(ast.Assignment) = .empty;
        while (true) {
            const col_tok = try self.expect(.identifier);
            const col = try self.alloc().dupe(u8, self.tokenText(col_tok));
            _ = try self.expect(.op_eq);
            const val = try self.parseExpr();
            try assignments.append(self.alloc(), .{ .column = col, .value = val });
            if (self.peek().kind != .comma) break;
            _ = self.advance();
        }

        var where: ?ast.Expr = null;
        if (self.peek().kind == .kw_where) {
            _ = self.advance();
            where = try self.parseExpr();
        }

        return ast.UpdateStmt{
            .table = table,
            .assignments = try assignments.toOwnedSlice(self.alloc()),
            .where = where,
        };
    }

    // ── DELETE ────────────────────────────────────────────────────────────────

    fn parseDelete(self: *Parser) ParseError!ast.DeleteStmt {
        _ = try self.expect(.kw_delete);
        _ = try self.expect(.kw_from);

        const table_tok = try self.expect(.identifier);
        const table = try self.alloc().dupe(u8, self.tokenText(table_tok));

        var where: ?ast.Expr = null;
        if (self.peek().kind == .kw_where) {
            _ = self.advance();
            where = try self.parseExpr();
        }

        return ast.DeleteStmt{ .table = table, .where = where };
    }

    // ── CREATE TABLE ──────────────────────────────────────────────────────────

    fn parseCreateTable(self: *Parser) ParseError!ast.CreateTableStmt {
        _ = try self.expect(.kw_create);
        _ = try self.expect(.kw_table);

        const table_tok = try self.expect(.identifier);
        const table = try self.alloc().dupe(u8, self.tokenText(table_tok));

        _ = try self.expect(.lparen);

        var columns: std.ArrayList(ast.ColumnDef) = .empty;
        while (true) {
            const col_name_tok = try self.expect(.identifier);
            const col_name = try self.alloc().dupe(u8, self.tokenText(col_name_tok));

            const type_tok = self.advance();
            const col_type: t.ColType = switch (type_tok.kind) {
                .kw_int => .int,
                .kw_real => .real,
                .kw_text => .text,
                .kw_blob => .blob,
                else => return ParseError.InvalidType,
            };

            var nullable = true;
            var default_src: ?[]const u8 = null;
            var default_expr: ?ast.Expr = null;

            // Parsing constraint
            while (true) {
                switch (self.peek().kind) {
                    .kw_not => {
                        _ = self.advance();
                        _ = try self.expect(.kw_null);
                        nullable = false;
                    },
                    .kw_default => {
                        _ = self.advance();
                        const src_start = self.peek().start;
                        default_expr = try self.parseExpr();
                        const src_end = self.peek().start;
                        default_src = std.mem.trim(u8, self.src[src_start..src_end], " \t\r\n");
                    },
                    else => break,
                }
            }

            try columns.append(self.alloc(), .{
                .name = col_name,
                .col_type = col_type,
                .nullable = nullable,
                .default_src = default_src,
                .default_expr = default_expr,
            });

            if (self.peek().kind != .comma) break;
            _ = self.advance();
        }

        _ = try self.expect(.rparen);

        return ast.CreateTableStmt{
            .table = table,
            .columns = try columns.toOwnedSlice(self.alloc()),
        };
    }

    // ── Expressions (recursive descent by precedence) ─────────────────────────
    //
    // We use classic recursive descent with one function per precedence level.
    // This is simpler than Pratt parsing for our operator set and produces
    // left-associative trees naturally (e.g. 1-2-3 becomes (1-2)-3).
    //
    // Precedence hierarchy (lowest to highest):
    //   parseExpr → parseOr → parseAnd → parseNot
    //  → parseComparison → parseAddSub → parseMulDiv
    //  → parseUnary → parsePrimary

    fn parseExpr(self: *Parser) ParseError!ast.Expr {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!ast.Expr {
        var left = try self.parseAnd();
        while (self.peek().kind == .kw_or) {
            _ = self.advance();
            const right = try self.parseAnd();
            const node = try self.alloc().create(ast.Expr.Binary);
            node.* = .{ .op = .or_, .left = left, .right = right };
            left = .{ .binary = node };
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParseError!ast.Expr {
        var left = try self.parseNot();
        while (self.peek().kind == .kw_and) {
            _ = self.advance();
            const right = try self.parseNot();
            const node = try self.alloc().create(ast.Expr.Binary);
            node.* = .{ .op = .and_, .left = left, .right = right };
            left = .{ .binary = node };
        }
        return left;
    }

    fn parseNot(self: *Parser) ParseError!ast.Expr {
        if (self.peek().kind == .kw_not) {
            _ = self.advance();
            const operand = try self.parseNot();
            const node = try self.alloc().create(ast.Expr.Unary);
            node.* = .{ .op = .not, .operand = operand };
            return .{ .unary = node };
        }
        return self.parseComparison();
    }

    fn parseComparison(self: *Parser) ParseError!ast.Expr {
        const left = try self.parseAddSub();
        const op: ast.BinaryOp = switch (self.peek().kind) {
            .op_eq => .eq,
            .op_neq => .neq,
            .op_lt => .lt,
            .op_lte => .lte,
            .op_gt => .gt,
            .op_gte => .gte,
            else => return left,
        };
        _ = self.advance();
        const right = try self.parseAddSub();
        const node = try self.alloc().create(ast.Expr.Binary);
        node.* = .{ .op = op, .left = left, .right = right };
        return .{ .binary = node };
    }

    fn parseAddSub(self: *Parser) ParseError!ast.Expr {
        var left = try self.parseMulDiv();
        while (true) {
            const op: ast.BinaryOp = switch (self.peek().kind) {
                .op_plus => .add,
                .op_minus => .sub,
                else => break,
            };
            _ = self.advance();
            const right = try self.parseMulDiv();
            const node = try self.alloc().create(ast.Expr.Binary);
            node.* = .{ .op = op, .left = left, .right = right };
            left = .{ .binary = node };
        }
        return left;
    }

    fn parseMulDiv(self: *Parser) ParseError!ast.Expr {
        var left = try self.parseUnary();
        while (true) {
            const op: ast.BinaryOp = switch (self.peek().kind) {
                .op_star => .mul,
                .op_slash => .div,
                else => break,
            };
            _ = self.advance();
            const right = try self.parseUnary();
            const node = try self.alloc().create(ast.Expr.Binary);
            node.* = .{ .op = op, .left = left, .right = right };
            left = .{ .binary = node };
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!ast.Expr {
        if (self.peek().kind == .op_minus) {
            _ = self.advance();
            const operand = try self.parseUnary();
            const node = try self.alloc().create(ast.Expr.Unary);
            node.* = .{ .op = .neg, .operand = operand };
            return .{ .unary = node };
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) ParseError!ast.Expr {
        const tok = self.peek();
        switch (tok.kind) {
            .lit_int => {
                _ = self.advance();
                return .{ .int_lit = tok.int_val };
            },
            .lit_float => {
                _ = self.advance();
                return .{ .float_lit = tok.float_val };
            },
            .lit_string => {
                _ = self.advance();
                const raw = self.src[tok.str_start..tok.str_end];
                const s = try unescapeString(raw, self.alloc());
                return .{ .str_lit = s };
            },
            .kw_null => {
                _ = self.advance();
                return .{ .null_lit = {} };
            },
            .kw_true => {
                _ = self.advance();
                return .{ .bool_lit = true };
            },
            .kw_false => {
                _ = self.advance();
                return .{ .bool_lit = false };
            },
            .identifier => {
                _ = self.advance();
                const name = try self.alloc().dupe(u8, self.tokenText(tok));
                return .{ .col_ref = name };
            },
            .lparen => {
                _ = self.advance();
                const inner = try self.parseExpr();
                _ = try self.expect(.rparen);
                return inner;
            },
            else => return ParseError.UnexpectedToken,
        }
    }
};

// Unescape '' → ' in a raw string-literal body.
fn unescapeString(raw: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    // Fast path: no embedded quotes at all.
    var has_escape = false;
    for (raw) |c| if (c == '\'') {
        has_escape = true;
        break;
    };
    if (!has_escape) return allocator.dupe(u8, raw);

    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (i + 1 < raw.len and raw[i] == '\'' and raw[i + 1] == '\'') {
            try buf.append(allocator, '\'');
            i += 2;
        } else {
            try buf.append(allocator, raw[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}
