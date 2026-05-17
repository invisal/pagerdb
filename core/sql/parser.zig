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
            .kw_create => try self.parseCreate(),
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
            // Only allow clause keywords, semicolon, or EOF after the column list when there is no FROM.
            const nk = self.peek().kind;
            if (nk != .eof and nk != .semicolon and nk != .kw_order and nk != .kw_group and nk != .kw_where and nk != .kw_having) {
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

            var having: ?ast.Expr = null;
            if (self.peek().kind == .kw_having) {
                _ = self.advance();
                having = try self.parseExpr();
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
                .having = having,
                .order_by = try order_by.toOwnedSlice(self.alloc()),
            };
        }

        // A parenthesised join group — FROM (t1 CROSS JOIN t2) — is semantically
        // identical to the unparenthesised form.  Consume the opening paren and
        // flatten the contents into the same table_ref + joins list; the closing
        // paren is consumed inside the loop below.
        const paren_group = self.peek().kind == .lparen;
        if (paren_group) _ = self.advance();
        opt_table_ref = try self.parseTableRef();

        // Parse optional JOIN clauses: INNER JOIN … ON …, CROSS JOIN …, or
        // comma-separated tables (implicit CROSS JOIN: FROM a, b).
        while (true) {
            if (paren_group and self.peek().kind == .rparen) {
                _ = self.advance(); // close the parenthesised group; outer JOINs may follow
            } else if (self.peek().kind == .comma) {
                _ = self.advance(); // consume ','
                const tref = try self.parseTableRef();
                try joins.append(self.alloc(), .{ .join_type = .cross, .table_ref = tref, .condition = null });
            } else if (self.peek().kind == .kw_inner) {
                _ = self.advance(); // consume INNER
                _ = try self.expect(.kw_join);
                const tref = try self.parseTableRef();
                _ = try self.expect(.kw_on);
                const condition = try self.parseExpr();
                try joins.append(self.alloc(), .{ .join_type = .inner, .table_ref = tref, .condition = condition });
            } else if (self.peek().kind == .kw_cross) {
                _ = self.advance(); // consume CROSS
                _ = try self.expect(.kw_join);
                const tref = try self.parseTableRef();
                try joins.append(self.alloc(), .{ .join_type = .cross, .table_ref = tref, .condition = null });
            } else if (self.peek().kind == .kw_join) {
                // Bare JOIN is INNER JOIN in SQL.
                _ = self.advance(); // consume JOIN
                const tref = try self.parseTableRef();
                _ = try self.expect(.kw_on);
                const condition = try self.parseExpr();
                try joins.append(self.alloc(), .{ .join_type = .inner, .table_ref = tref, .condition = condition });
            } else if (self.peek().kind == .kw_left) {
                _ = self.advance(); // consume LEFT
                if (self.peek().kind == .kw_outer) _ = self.advance(); // consume optional OUTER
                _ = try self.expect(.kw_join);
                const tref = try self.parseTableRef();
                _ = try self.expect(.kw_on);
                const condition = try self.parseExpr();
                try joins.append(self.alloc(), .{ .join_type = .left, .table_ref = tref, .condition = condition });
            } else break;
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

        var having: ?ast.Expr = null;
        if (self.peek().kind == .kw_having) {
            _ = self.advance();
            having = try self.parseExpr();
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
            .having = having,
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

    // Parse a table reference: a qualified name optionally followed by TVF args
    // and an optional AS alias.  Used for both the FROM table and JOIN tables.
    fn parseTableRef(self: *Parser) ParseError!ast.TableRef {
        const qname = try self.parseQualifiedName();
        if (self.peek().kind == .lparen) {
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
            return .{ .func = .{
                .schema = qname.schema,
                .name = qname.name,
                .args = try args.toOwnedSlice(self.alloc()),
                .alias = try self.parseOptionalAlias(),
            } };
        }
        return .{ .name = .{
            .schema = qname.schema,
            .name = qname.name,
            .alias = try self.parseOptionalAlias(),
        } };
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

    fn parseCreate(self: *Parser) ParseError!ast.Stmt {
        _ = try self.expect(.kw_create);
        return switch (self.peek().kind) {
            .kw_table => .{ .create_table = try self.parseCreateTable() },
            .kw_index => blk: {
                _ = self.advance(); // consume INDEX
                break :blk .{ .create_index = try self.parseCreateIndex(false) };
            },
            .kw_unique => blk: {
                _ = self.advance(); // consume UNIQUE
                _ = try self.expect(.kw_index);
                break :blk .{ .create_index = try self.parseCreateIndex(true) };
            },
            else => {
                const tok = self.peek();
                self.error_message = std.fmt.allocPrint(
                    self.arena.allocator(),
                    "[{d}] Expected TABLE or INDEX after CREATE, got '{s}'",
                    .{ tok.start, self.tokenText(tok) },
                ) catch "";
                return ParseError.UnexpectedToken;
            },
        };
    }

    fn parseCreateIndex(self: *Parser, is_unique: bool) ParseError!ast.CreateIndexStmt {
        // Caller has already consumed CREATE [UNIQUE] INDEX.
        // Syntax: [IF NOT EXISTS] name ON table (col, ...)
        var if_not_exists = false;
        if (self.peek().kind == .kw_if) {
            _ = self.advance(); // consume IF
            _ = try self.expect(.kw_not);
            _ = try self.expect(.kw_exists);
            if_not_exists = true;
        }

        const name_tok = try self.expect(.identifier);
        const name = try self.alloc().dupe(u8, self.tokenText(name_tok));

        _ = try self.expect(.kw_on);

        const table_tok = try self.expect(.identifier);
        const table = try self.alloc().dupe(u8, self.tokenText(table_tok));

        _ = try self.expect(.lparen);
        var cols: std.ArrayList([]const u8) = .empty;
        while (true) {
            const col_tok = try self.expect(.identifier);
            try cols.append(self.alloc(), try self.alloc().dupe(u8, self.tokenText(col_tok)));
            if (self.peek().kind != .comma) break;
            _ = self.advance();
        }
        _ = try self.expect(.rparen);

        return ast.CreateIndexStmt{
            .name = name,
            .table = table,
            .columns = try cols.toOwnedSlice(self.alloc()),
            .is_unique = is_unique,
            .if_not_exists = if_not_exists,
        };
    }

    fn parseCreateTable(self: *Parser) ParseError!ast.CreateTableStmt {
        _ = try self.expect(.kw_table);

        const table_tok = try self.expect(.identifier);
        const table = try self.alloc().dupe(u8, self.tokenText(table_tok));

        _ = try self.expect(.lparen);

        var columns: std.ArrayList(ast.ColumnDef) = .empty;
        // Table-level PRIMARY KEY (col, ...) constraint — stores the first column name.
        // Composite PKs are not supported yet; only the first name is used.
        var table_pk_name: ?[]const u8 = null;

        while (true) {
            // Table-level PRIMARY KEY (...) constraint — not a column definition.
            if (self.peek().kind == .kw_primary) {
                _ = self.advance(); // consume PRIMARY
                _ = try self.expect(.kw_key);
                _ = try self.expect(.lparen);
                while (true) {
                    const pk_tok = try self.expect(.identifier);
                    if (table_pk_name == null) {
                        table_pk_name = try self.alloc().dupe(u8, self.tokenText(pk_tok));
                    }
                    if (self.peek().kind != .comma) break;
                    _ = self.advance();
                }
                _ = try self.expect(.rparen);
            } else {
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
                            "[{d}] Invalid column type '{s}', expected INT, INTEGER, REAL, FLOAT, TEXT, or BLOB",
                            .{ type_tok.start, self.tokenText(type_tok) },
                        ) catch "";
                        return ParseError.InvalidType;
                    },
                };

                var nullable = true;
                var is_primary_key = false;
                var default_src: ?[]const u8 = null;
                var default_expr: ?ast.Expr = null;

                // Parse column-level constraints: NOT NULL, DEFAULT, PRIMARY KEY.
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
                        .kw_primary => {
                            _ = self.advance();
                            _ = try self.expect(.kw_key);
                            is_primary_key = true;
                        },
                        else => break,
                    }
                }

                try columns.append(self.alloc(), .{
                    .name = col_name,
                    .col_type = col_type,
                    .nullable = nullable,
                    .is_primary_key = is_primary_key,
                    .default_src = default_src,
                    .default_expr = default_expr,
                });
            }

            if (self.peek().kind != .comma) break;
            _ = self.advance();
        }

        _ = try self.expect(.rparen);

        // Apply table-level PRIMARY KEY to the named column.
        if (table_pk_name) |pk_name| {
            for (columns.items) |*col| {
                if (std.ascii.eqlIgnoreCase(col.name, pk_name)) {
                    col.is_primary_key = true;
                    break;
                }
            }
        }

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

        // Detect NOT IN / NOT BETWEEN before the standard comparison operators
        // so that the NOT is consumed here rather than by the outer parseNot().
        if (self.peek().kind == .kw_not and self.pos + 1 < self.tokens.len) {
            switch (self.tokens[self.pos + 1].kind) {
                .kw_in => {
                    _ = self.advance(); // NOT
                    _ = self.advance(); // IN
                    return self.parseInList(left, true);
                },
                .kw_between => {
                    _ = self.advance(); // NOT
                    _ = self.advance(); // BETWEEN
                    return self.parseBetween(left, true);
                },
                else => {},
            }
        }
        if (self.peek().kind == .kw_in) {
            _ = self.advance();
            return self.parseInList(left, false);
        }
        if (self.peek().kind == .kw_between) {
            _ = self.advance();
            return self.parseBetween(left, false);
        }

        // IS [NOT] NULL — SQL null check, parsed before the regular comparison operators.
        if (self.peek().kind == .kw_is) {
            _ = self.advance(); // consume IS
            const negated = self.peek().kind == .kw_not;
            if (negated) _ = self.advance(); // consume NOT
            _ = try self.expect(.kw_null);
            const node = try self.alloc().create(ast.Expr.IsNull);
            node.* = .{ .operand = left, .negated = negated };
            return .{ .is_null = node };
        }

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

    fn parseBetween(self: *Parser, operand: ast.Expr, negated: bool) ParseError!ast.Expr {
        const low = try self.parseAddSub();
        _ = try self.expect(.kw_and);
        const high = try self.parseAddSub();
        const node = try self.alloc().create(ast.Expr.Between);
        node.* = .{ .operand = operand, .low = low, .high = high, .negated = negated };
        return .{ .between = node };
    }

    fn parseInList(self: *Parser, operand: ast.Expr, negated: bool) ParseError!ast.Expr {
        _ = try self.expect(.lparen);
        var list: std.ArrayList(ast.Expr) = .empty;
        if (self.peek().kind != .rparen) {
            try list.append(self.alloc(), try self.parseExpr());
            while (self.peek().kind == .comma) {
                _ = self.advance();
                try list.append(self.alloc(), try self.parseExpr());
            }
        }
        _ = try self.expect(.rparen);
        const node = try self.alloc().create(ast.Expr.InList);
        node.* = .{
            .operand = operand,
            .list = try list.toOwnedSlice(self.alloc()),
            .negated = negated,
        };
        return .{ .in_list = node };
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
        // Unary + is a no-op; consume it and parse the operand normally.
        if (self.peek().kind == .op_plus) {
            _ = self.advance();
            return self.parseUnary();
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
                    // Optional DISTINCT / ALL quantifier before the argument.
                    var distinct = false;
                    if (self.peek().kind == .kw_distinct) {
                        _ = self.advance();
                        distinct = true;
                    } else if (self.peek().kind == .kw_all) {
                        _ = self.advance(); // ALL is the default; distinct stays false
                    }
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
                    node.* = .{ .name = name, .args = try args.toOwnedSlice(self.alloc()), .distinct = distinct };
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
            .kw_cast => {
                _ = self.advance();
                _ = try self.expect(.lparen);
                const operand = try self.parseExpr();
                _ = try self.expect(.kw_as);
                const type_tok = self.peek();
                const target_type: t.ColType = switch (type_tok.kind) {
                    .kw_int => .int,
                    .kw_real => .real,
                    .kw_text => .text,
                    .kw_blob => .blob,
                    else => return ParseError.UnexpectedToken,
                };
                _ = self.advance();
                _ = try self.expect(.rparen);
                const node = try self.alloc().create(ast.Expr.Cast);
                node.* = .{ .target_type = target_type, .operand = operand };
                return .{ .cast = node };
            },
            .kw_case => {
                _ = self.advance();
                // Simple CASE (CASE input WHEN val ...) vs searched CASE (CASE WHEN cond ...).
                // Both are normalised to searched CASE here: simple WHEN clauses become
                // WHEN input = val, so the rest of the pipeline only handles one form.
                const input: ?ast.Expr = if (self.peek().kind != .kw_when)
                    try self.parseExpr()
                else
                    null;
                var when_clauses: std.ArrayList(ast.Expr.Case.WhenClause) = .empty;
                while (self.peek().kind == .kw_when) {
                    _ = self.advance(); // consume WHEN
                    var cond = try self.parseExpr();
                    if (input) |inp| {
                        const eq_node = try self.alloc().create(ast.Expr.Binary);
                        eq_node.* = .{ .op = .eq, .left = inp, .right = cond };
                        cond = .{ .binary = eq_node };
                    }
                    _ = try self.expect(.kw_then);
                    const then_ = try self.parseExpr();
                    try when_clauses.append(self.alloc(), .{ .cond = cond, .then = then_ });
                }
                const else_: ?ast.Expr = if (self.peek().kind == .kw_else) blk: {
                    _ = self.advance();
                    break :blk try self.parseExpr();
                } else null;
                _ = try self.expect(.kw_end);
                const node = try self.alloc().create(ast.Expr.Case);
                node.* = .{
                    .when_clauses = try when_clauses.toOwnedSlice(self.alloc()),
                    .else_ = else_,
                };
                return .{ .case_ = node };
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
