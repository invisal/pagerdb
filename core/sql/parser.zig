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

pub const ParseExprResult = struct {
    arena: std.heap.ArenaAllocator,
    expr: ast.Expr,

    pub fn deinit(self: *ParseExprResult) void {
        self.arena.deinit();
    }
};

pub const Parser = struct {
    tokens: []const Token = &.{},
    src: []const u8,
    pos: usize = 0,
    arena: std.heap.ArenaAllocator,
    /// Human-readable message set at the error site; valid until deinit().
    error_message: []const u8 = "",

    pub fn init(src: []const u8, allocator: std.mem.Allocator) Parser {
        return .{ .src = src, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    /// Tokenise src then parse it into a statement.
    /// On failure, error_message holds a human-readable description.
    /// The returned ast.Stmt is arena-owned; keep the Parser alive until done.
    pub fn parse(self: *Parser) ParseError!ast.Stmt {
        self.tokens = lexer.Lexer.tokenize(self.src, self.arena.allocator()) catch |e| {
            self.error_message = switch (e) {
                error.UnexpectedChar => "Unexpected character in SQL",
                error.UnterminatedString => "Unterminated string literal",
                error.InvalidNumber => "Invalid number literal",
                else => "",
            };
            return e;
        };
        return self.parseStmt();
    }

    pub fn parseStandaloneExpr(allocator: std.mem.Allocator, src: []const u8) ParseError!ParseExprResult {
        const tokens = try lexer.Lexer.tokenize(src, allocator);
        defer allocator.free(tokens);

        var p = Parser{
            .tokens = tokens,
            .src = src,
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
        if (tok.kind != kind) {
            const got = if (tok.kind == .eof) "end of input" else self.tokenText(tok);
            self.error_message = std.fmt.allocPrint(
                self.arena.allocator(),
                "[{d}] Expected {s} but got '{s}'",
                .{ tok.start, kind.label(), got },
            ) catch "";
            return ParseError.UnexpectedToken;
        }
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
            .kw_begin => blk: {
                _ = self.advance();
                break :blk .{ .begin = {} };
            },
            .kw_commit => blk: {
                _ = self.advance();
                break :blk .{ .commit = {} };
            },
            .kw_rollback => blk: {
                _ = self.advance();
                break :blk .{ .rollback = {} };
            },
            else => {
                const tok = self.peek();
                const text = if (tok.kind == .eof) "end of input" else self.tokenText(tok);
                self.error_message = std.fmt.allocPrint(
                    self.arena.allocator(),
                    "[{d}] Unexpected '{s}': expected SELECT, INSERT, UPDATE, DELETE, CREATE, BEGIN, COMMIT, or ROLLBACK",
                    .{ tok.start, text },
                ) catch "";
                return ParseError.UnexpectedToken;
            },
        };
    }

    // ── SELECT ────────────────────────────────────────────────────────────────

    fn parseSelect(self: *Parser) ParseError!ast.SelectStmt {
        _ = try self.expect(.kw_select);

        // DISTINCT keeps only unique rows; ALL (the default) keeps all rows.
        const distinct = self.peek().kind == .kw_distinct;
        if (distinct or self.peek().kind == .kw_all) _ = self.advance();

        var columns: std.ArrayList(ast.SelectCol) = .empty;

        // Parse column list
        while (true) {
            switch (self.peek().kind) {
                .op_star => {
                    // Handle SELECT *
                    _ = self.advance();
                    try columns.append(self.alloc(), .{ .col = .star, .alias = null });
                },
                else => {
                    const e = try self.parseExpr();
                    const alias = try self.parseOptionalAlias();
                    const col_kind: ast.SelectCol.Kind = switch (e) {
                        .col_ref => |n| .{ .name = n },
                        .qual_col_ref => |q| .{ .qual_name = q },
                        else => .{ .expr = e },
                    };
                    try columns.append(self.alloc(), .{ .col = col_kind, .alias = alias });
                },
            }

            if (self.peek().kind != .comma) break;
            _ = self.advance();
        }

        // A SELECT can omit FROM entirely (e.g. SELECT 1 + 2, SELECT 1 ORDER BY 1).
        // Peek at the next token instead of consuming it so that ORDER BY / GROUP BY
        // / WHERE that immediately follow columns are handled by the shared parsing
        // below rather than triggering an error here.
        const has_from = self.peek().kind == .kw_from;
        if (!has_from) {
            // Only allow clause keywords or EOF after the column list when there is no FROM.
            const nk = self.peek().kind;
            if (nk != .eof and nk != .kw_order and nk != .kw_group and nk != .kw_where) {
                const tok = self.advance();
                self.error_message = try std.fmt.allocPrint(self.alloc(), "[{d}] Unexpected token FROM but found {s}", .{ tok.start, self.tokenText(tok) });
                return ParseError.UnexpectedToken;
            }
        }

        // If there is no FROM clause we skip the table-ref / join parsing
        // and go straight to the optional WHERE / GROUP BY / ORDER BY below.
        var opt_table_ref: ?ast.TableRef = null;
        var joins: std.ArrayList(ast.JoinClause) = .empty;
        if (has_from) {
            _ = self.advance(); // consume FROM
        }

        if (!has_from) {
            // Jump to optional clause parsing (WHERE / GROUP BY / ORDER BY).
            // Declare the variables that the shared block below expects.
            var where: ?ast.Expr = null;
            var group_by: std.ArrayList(ast.Expr) = .empty;

            if (self.peek().kind == .kw_where) {
                _ = self.advance();
                where = try self.parseExpr();
            }

            if (self.peek().kind == .kw_group) {
                _ = self.advance();
                _ = try self.expect(.kw_by);
                while (true) {
                    try group_by.append(self.alloc(), try self.parseExpr());
                    if (self.peek().kind != .comma) break;
                    _ = self.advance();
                }
            }

            var order_by: std.ArrayList(ast.OrderByItem) = .empty;
            if (self.peek().kind == .kw_order) {
                _ = self.advance();
                _ = try self.expect(.kw_by);
                while (true) {
                    const expr = try self.parseExpr();
                    const direction: ast.OrderDirection = switch (self.peek().kind) {
                        .kw_desc => blk: {
                            _ = self.advance();
                            break :blk .desc;
                        },
                        .kw_asc => blk: {
                            _ = self.advance();
                            break :blk .asc;
                        },
                        else => .asc,
                    };
                    try order_by.append(self.alloc(), .{ .expr = expr, .direction = direction });
                    if (self.peek().kind != .comma) break;
                    _ = self.advance();
                }
            }

            return ast.SelectStmt{
                .distinct = distinct,
                .table_ref = null,
                .joins = &.{},
                .columns = try columns.toOwnedSlice(self.alloc()),
                .where = where,
                .group_by = try group_by.toOwnedSlice(self.alloc()),
                .order_by = try order_by.toOwnedSlice(self.alloc()),
            };
        }

        const qualified_name = try self.parseQualifiedName();

        // Parse optional TVF args and optional AS alias for the FROM table.
        opt_table_ref = if (self.peek().kind == .lparen) blk: {
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
                .alias = try self.parseOptionalAlias(),
            } };
        } else .{ .name = .{
            .schema = qualified_name.schema,
            .name = qualified_name.name,
            .alias = try self.parseOptionalAlias(),
        } };

        // Parse optional INNER JOIN clauses. Each right-hand side can be a plain
        // table or a TVF, both with an optional AS alias.
        while (self.peek().kind == .kw_inner) {
            _ = self.advance(); // consume INNER
            _ = try self.expect(.kw_join);
            const join_qname = try self.parseQualifiedName();
            const join_table_ref: ast.TableRef = if (self.peek().kind == .lparen) blk: {
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
                    .schema = join_qname.schema,
                    .name = join_qname.name,
                    .args = try args.toOwnedSlice(self.alloc()),
                    .alias = try self.parseOptionalAlias(),
                } };
            } else .{ .name = .{
                .schema = join_qname.schema,
                .name = join_qname.name,
                .alias = try self.parseOptionalAlias(),
            } };
            _ = try self.expect(.kw_on);
            const condition = try self.parseExpr();
            try joins.append(self.alloc(), .{ .table_ref = join_table_ref, .condition = condition });
        }

        var where: ?ast.Expr = null;
        if (self.peek().kind == .kw_where) {
            _ = self.advance();
            where = try self.parseExpr();
        }

        var group_by: std.ArrayList(ast.Expr) = .empty;
        if (self.peek().kind == .kw_group) {
            _ = self.advance();
            _ = try self.expect(.kw_by);
            while (true) {
                try group_by.append(self.alloc(), try self.parseExpr());
                if (self.peek().kind != .comma) break;
                _ = self.advance();
            }
        }

        var order_by: std.ArrayList(ast.OrderByItem) = .empty;
        if (self.peek().kind == .kw_order) {
            _ = self.advance();
            _ = try self.expect(.kw_by);
            while (true) {
                const expr = try self.parseExpr();
                const direction: ast.OrderDirection = switch (self.peek().kind) {
                    .kw_desc => blk: {
                        _ = self.advance();
                        break :blk .desc;
                    },
                    .kw_asc => blk: {
                        _ = self.advance();
                        break :blk .asc;
                    },
                    else => .asc,
                };
                try order_by.append(self.alloc(), .{ .expr = expr, .direction = direction });
                if (self.peek().kind != .comma) break;
                _ = self.advance();
            }
        }

        return ast.SelectStmt{
            .distinct = distinct,
            .table_ref = opt_table_ref,
            .joins = try joins.toOwnedSlice(self.alloc()),
            .columns = try columns.toOwnedSlice(self.alloc()),
            .where = where,
            .group_by = try group_by.toOwnedSlice(self.alloc()),
            .order_by = try order_by.toOwnedSlice(self.alloc()),
        };
    }

    // Parse a qualified name: identifier or identifier.identifier
    // Returns the qualified name with optional schema (null if not specified).
    // Alias is always null here; callers parse AS separately.
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
                .alias = null,
            };
        }

        // No schema specified, default to null (will be treated as "main")
        return ast.QualifiedName{
            .schema = null,
            .name = first_name,
            .alias = null,
        };
    }

    // Consume an optional AS alias: [ AS ] identifier.
    // Returns the alias string, or null if no alias follows.
    fn parseOptionalAlias(self: *Parser) ParseError!?[]const u8 {
        if (self.peek().kind == .kw_as) _ = self.advance();
        if (self.peek().kind == .identifier) {
            const tok = self.advance();
            return try self.alloc().dupe(u8, self.tokenText(tok));
        }
        return null;
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

        var rows: std.ArrayList([]ast.Expr) = .empty;

        while (true) {
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
            try rows.append(self.alloc(), try values.toOwnedSlice(self.alloc()));

            if (self.peek().kind != .comma) break;
            _ = self.advance();
        }

        return ast.InsertStmt{
            .table = table,
            .values = try rows.toOwnedSlice(self.alloc()),
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
                else => {
                    self.error_message = std.fmt.allocPrint(
                        self.arena.allocator(),
                        "[{d}] Invalid column type '{s}', expected INT, INTEGER, REAL, TEXT, or BLOB",
                        .{ type_tok.start, self.tokenText(type_tok) },
                    ) catch "";
                    return ParseError.InvalidType;
                },
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
                const s = try unescapeString(self.alloc(), raw);
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
                // Function call: name(arg, ...)
                if (self.peek().kind == .lparen) {
                    _ = self.advance();
                    var args: std.ArrayList(ast.Expr) = .empty;
                    if (self.peek().kind != .rparen) {
                        // COUNT(*): the lone * inside a function call is a special
                        // aggregate wildcard, not multiplication.
                        if (self.peek().kind == .op_star) {
                            _ = self.advance();
                            try args.append(self.alloc(), .{ .star = {} });
                        } else {
                            try args.append(self.alloc(), try self.parseExpr());
                            while (self.peek().kind == .comma) {
                                _ = self.advance();
                                try args.append(self.alloc(), try self.parseExpr());
                            }
                        }
                    }
                    _ = try self.expect(.rparen);
                    const node = try self.alloc().create(ast.Expr.FuncCall);
                    node.* = .{ .name = name, .args = try args.toOwnedSlice(self.alloc()) };
                    return .{ .func_call = node };
                }
                // Handle table.col qualified references in expressions
                if (self.peek().kind == .dot) {
                    _ = self.advance();

                    if (self.peek().kind == .op_star) {
                        _ = self.advance();
                        return .{ .qual_col_ref = .{ .table = name, .col = null } };
                    } else {
                        const col_tok = try self.expect(.identifier);
                        const col_name = try self.alloc().dupe(u8, self.tokenText(col_tok));
                        return .{ .qual_col_ref = .{ .table = name, .col = col_name } };
                    }
                }
                return .{ .col_ref = name };
            },
            .lparen => {
                _ = self.advance();
                const inner = try self.parseExpr();
                _ = try self.expect(.rparen);
                return inner;
            },
            else => {
                const bad = self.peek();
                const text = if (bad.kind == .eof) "end of input" else self.tokenText(bad);
                self.error_message = std.fmt.allocPrint(
                    self.arena.allocator(),
                    "[{d}] Unexpected '{s}' in expression",
                    .{ bad.start, text },
                ) catch "";
                return ParseError.UnexpectedToken;
            },
        }
    }
};

// Unescape '' → ' in a raw string-literal body.
fn unescapeString(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
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
