const std = @import("std");

pub const TokenKind = enum {
    // Keywords
    kw_select,
    kw_default,
    kw_from,
    kw_where,
    kw_and,
    kw_or,
    kw_not,
    kw_insert,
    kw_into,
    kw_values,
    kw_update,
    kw_set,
    kw_delete,
    kw_create,
    kw_table,
    kw_null,
    kw_true,
    kw_false,
    kw_int,
    kw_real,
    kw_text,
    kw_blob,
    kw_primary,
    kw_key,
    kw_begin,
    kw_commit,
    kw_rollback,
    kw_cross,
    kw_inner,
    kw_join,
    kw_on,
    kw_as,
    kw_group,
    kw_by,
    kw_order,
    kw_asc,
    kw_desc,
    kw_distinct,
    kw_all,
    kw_cast,
    kw_in,
    kw_between,
    kw_case,
    kw_when,
    kw_then,
    kw_else,
    kw_end,
    kw_is,
    // Literals
    lit_int, // int_val is valid
    lit_float, // float_val is valid
    lit_string, // src[str_start..str_end] is raw content between quotes; '' not yet unescaped
    // Identifier
    identifier,
    // Operators
    op_eq, // =
    op_neq, // != or <>
    op_lt, // <
    op_lte, // <=
    op_gt, // >
    op_gte, // >=
    op_plus, // +
    op_minus, // -
    op_star, // *
    op_slash, // /
    // Punctuation
    lparen,
    rparen,
    comma,
    semicolon,
    dot,
    // Sentinel
    eof,

    pub fn label(self: TokenKind) []const u8 {
        return switch (self) {
            .kw_select => "SELECT",
            .kw_from => "FROM",
            .kw_where => "WHERE",
            .kw_and => "AND",
            .kw_or => "OR",
            .kw_not => "NOT",
            .kw_insert => "INSERT",
            .kw_into => "INTO",
            .kw_values => "VALUES",
            .kw_update => "UPDATE",
            .kw_set => "SET",
            .kw_delete => "DELETE",
            .kw_create => "CREATE",
            .kw_table => "TABLE",
            .kw_null => "NULL",
            .kw_true => "TRUE",
            .kw_false => "FALSE",
            .kw_int => "INT",
            .kw_real => "REAL",
            .kw_text => "TEXT",
            .kw_blob => "BLOB",
            .kw_primary => "PRIMARY",
            .kw_key => "KEY",
            .kw_begin => "BEGIN",
            .kw_commit => "COMMIT",
            .kw_rollback => "ROLLBACK",
            .kw_cross => "CROSS",
            .kw_inner => "INNER",
            .kw_join => "JOIN",
            .kw_on => "ON",
            .kw_as => "AS",
            .kw_group => "GROUP",
            .kw_by => "BY",
            .kw_default => "DEFAULT",
            .kw_order => "ORDER",
            .kw_asc => "ASC",
            .kw_desc => "DESC",
            .kw_distinct => "DISTINCT",
            .kw_all => "ALL",
            .kw_cast => "CAST",
            .kw_in => "IN",
            .kw_between => "BETWEEN",
            .kw_case => "CASE",
            .kw_when => "WHEN",
            .kw_then => "THEN",
            .kw_else => "ELSE",
            .kw_end => "END",
            .kw_is => "IS",
            .identifier => "identifier",
            .lit_int => "integer",
            .lit_float => "float",
            .lit_string => "string",
            .lparen => "'('",
            .rparen => "')'",
            .comma => "','",
            .semicolon => "';'",
            .dot => "'.'",
            .op_star => "'*'",
            .op_plus => "'+'",
            .op_minus => "'-'",
            .op_slash => "'/'",
            .op_eq => "'='",
            .op_neq => "'<>'",
            .op_lt => "'<'",
            .op_lte => "'<='",
            .op_gt => "'>'",
            .op_gte => "'>='",
            .eof => "end of input",
        };
    }
};

// Token holds both syntactic info (kind, position) and semantic values.
// We store string literals as offsets (str_start/str_end) rather than slices
// because the input source string is guaranteed to outlive the lexer.
// This avoids allocations during tokenization and keeps Token at a fixed
// size regardless of literal length.
pub const Token = struct {
    kind: TokenKind,
    start: u32, // byte offset in source
    len: u32, // byte length in source
    int_val: i64 = 0,
    float_val: f64 = 0.0,
    // For lit_string: raw content inside the quotes (not unescaped).
    // src[str_start..str_end] excludes the surrounding quotes.
    str_start: u32 = 0,
    str_end: u32 = 0,
};

pub const LexError = error{ UnexpectedChar, UnterminatedString, InvalidNumber };

const keyword_pairs = [_]struct { text: []const u8, kind: TokenKind }{
    .{ .text = "select", .kind = .kw_select },
    .{ .text = "from", .kind = .kw_from },
    .{ .text = "where", .kind = .kw_where },
    .{ .text = "and", .kind = .kw_and },
    .{ .text = "or", .kind = .kw_or },
    .{ .text = "not", .kind = .kw_not },
    .{ .text = "insert", .kind = .kw_insert },
    .{ .text = "into", .kind = .kw_into },
    .{ .text = "values", .kind = .kw_values },
    .{ .text = "update", .kind = .kw_update },
    .{ .text = "set", .kind = .kw_set },
    .{ .text = "delete", .kind = .kw_delete },
    .{ .text = "create", .kind = .kw_create },
    .{ .text = "table", .kind = .kw_table },
    .{ .text = "null", .kind = .kw_null },
    .{ .text = "true", .kind = .kw_true },
    .{ .text = "false", .kind = .kw_false },
    .{ .text = "int", .kind = .kw_int },
    .{ .text = "integer", .kind = .kw_int },
    .{ .text = "real", .kind = .kw_real },
    .{ .text = "text", .kind = .kw_text },
    .{ .text = "blob", .kind = .kw_blob },
    .{ .text = "primary", .kind = .kw_primary },
    .{ .text = "key", .kind = .kw_key },
    .{ .text = "default", .kind = .kw_default },
    .{ .text = "begin", .kind = .kw_begin },
    .{ .text = "commit", .kind = .kw_commit },
    .{ .text = "rollback", .kind = .kw_rollback },
    .{ .text = "cross", .kind = .kw_cross },
    .{ .text = "inner", .kind = .kw_inner },
    .{ .text = "join", .kind = .kw_join },
    .{ .text = "on", .kind = .kw_on },
    .{ .text = "as", .kind = .kw_as },
    .{ .text = "group", .kind = .kw_group },
    .{ .text = "by", .kind = .kw_by },
    .{ .text = "order", .kind = .kw_order },
    .{ .text = "asc", .kind = .kw_asc },
    .{ .text = "desc", .kind = .kw_desc },
    .{ .text = "distinct", .kind = .kw_distinct },
    .{ .text = "all", .kind = .kw_all },
    .{ .text = "cast", .kind = .kw_cast },
    .{ .text = "in", .kind = .kw_in },
    .{ .text = "between", .kind = .kw_between },
    .{ .text = "case", .kind = .kw_case },
    .{ .text = "when", .kind = .kw_when },
    .{ .text = "then", .kind = .kw_then },
    .{ .text = "else", .kind = .kw_else },
    .{ .text = "end", .kind = .kw_end },
    .{ .text = "is", .kind = .kw_is },
};

fn lookupKeyword(word: []const u8) ?TokenKind {
    for (keyword_pairs) |kp| {
        if (std.ascii.eqlIgnoreCase(word, kp.text)) return kp.kind;
    }
    return null;
}

pub const Lexer = struct {
    src: []const u8,
    pos: u32,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src, .pos = 0 };
    }

    pub fn next(self: *Lexer) LexError!Token {
        // Skip whitespace and -- comments.
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (self.pos + 1 < self.src.len and c == '-' and self.src[self.pos + 1] == '-') {
                self.pos += 2;
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else {
                break;
            }
        }

        const start = self.pos;
        if (self.pos >= self.src.len)
            return Token{ .kind = .eof, .start = start, .len = 0 };

        const ch = self.src[self.pos];
        self.pos += 1;

        switch (ch) {
            'a'...'z', 'A'...'Z', '_' => {
                while (self.pos < self.src.len) {
                    const nc = self.src[self.pos];
                    if (std.ascii.isAlphanumeric(nc) or nc == '_') self.pos += 1 else break;
                }
                const word = self.src[start..self.pos];
                const kind = lookupKeyword(word) orelse .identifier;
                return Token{ .kind = kind, .start = start, .len = @intCast(self.pos - start) };
            },

            '0'...'9' => {
                while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos]))
                    self.pos += 1;
                // Float: digits '.' digits
                if (self.pos + 1 < self.src.len and
                    self.src[self.pos] == '.' and
                    std.ascii.isDigit(self.src[self.pos + 1]))
                {
                    self.pos += 1; // consume '.'
                    while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos]))
                        self.pos += 1;
                    const text = self.src[start..self.pos];
                    const val = std.fmt.parseFloat(f64, text) catch return LexError.InvalidNumber;
                    return Token{
                        .kind = .lit_float,
                        .start = start,
                        .len = @intCast(self.pos - start),
                        .float_val = val,
                    };
                }
                const text = self.src[start..self.pos];
                const val = std.fmt.parseInt(i64, text, 10) catch return LexError.InvalidNumber;
                return Token{
                    .kind = .lit_int,
                    .start = start,
                    .len = @intCast(self.pos - start),
                    .int_val = val,
                };
            },

            '\'' => {
                const str_start = self.pos; // first char after opening quote
                while (true) {
                    if (self.pos >= self.src.len) return LexError.UnterminatedString;
                    if (self.src[self.pos] == '\'') {
                        self.pos += 1; // consume quote
                        // '' is an escaped single quote — keep scanning
                        if (self.pos < self.src.len and self.src[self.pos] == '\'') {
                            self.pos += 1;
                            continue;
                        }
                        break; // closing quote
                    }
                    self.pos += 1;
                }
                // self.pos is now after the closing quote; closing quote was at self.pos-1
                const str_end = self.pos - 1;
                return Token{
                    .kind = .lit_string,
                    .start = start,
                    .len = @intCast(self.pos - start),
                    .str_start = @intCast(str_start),
                    .str_end = @intCast(str_end),
                };
            },

            '=' => return Token{ .kind = .op_eq, .start = start, .len = 1 },
            '!' => {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return Token{ .kind = .op_neq, .start = start, .len = 2 };
                }
                return LexError.UnexpectedChar;
            },
            '<' => {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return Token{ .kind = .op_lte, .start = start, .len = 2 };
                } else if (self.pos < self.src.len and self.src[self.pos] == '>') {
                    self.pos += 1;
                    return Token{ .kind = .op_neq, .start = start, .len = 2 };
                }
                return Token{ .kind = .op_lt, .start = start, .len = 1 };
            },
            '>' => {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return Token{ .kind = .op_gte, .start = start, .len = 2 };
                }
                return Token{ .kind = .op_gt, .start = start, .len = 1 };
            },
            '+' => return Token{ .kind = .op_plus, .start = start, .len = 1 },
            '-' => return Token{ .kind = .op_minus, .start = start, .len = 1 },
            '*' => return Token{ .kind = .op_star, .start = start, .len = 1 },
            '/' => return Token{ .kind = .op_slash, .start = start, .len = 1 },
            '(' => return Token{ .kind = .lparen, .start = start, .len = 1 },
            ')' => return Token{ .kind = .rparen, .start = start, .len = 1 },
            ',' => return Token{ .kind = .comma, .start = start, .len = 1 },
            ';' => return Token{ .kind = .semicolon, .start = start, .len = 1 },
            '.' => return Token{ .kind = .dot, .start = start, .len = 1 },
            else => return LexError.UnexpectedChar,
        }
    }

    pub fn tokenize(
        src: []const u8,
        alloc: std.mem.Allocator,
    ) (LexError || error{OutOfMemory})![]Token {
        var lex = Lexer.init(src);
        var list: std.ArrayList(Token) = .empty;
        while (true) {
            const tok = try lex.next();
            try list.append(alloc, tok);
            if (tok.kind == .eof) break;
        }
        return list.toOwnedSlice(alloc);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "tokenize SELECT" {
    const alloc = std.testing.allocator;
    const toks = try Lexer.tokenize("SELECT * FROM users WHERE id = 1", alloc);
    defer alloc.free(toks);

    try std.testing.expectEqual(TokenKind.kw_select, toks[0].kind);
    try std.testing.expectEqual(TokenKind.op_star, toks[1].kind);
    try std.testing.expectEqual(TokenKind.kw_from, toks[2].kind);
    try std.testing.expectEqual(TokenKind.identifier, toks[3].kind);
    try std.testing.expectEqual(TokenKind.kw_where, toks[4].kind);
    try std.testing.expectEqual(TokenKind.identifier, toks[5].kind);
    try std.testing.expectEqual(TokenKind.op_eq, toks[6].kind);
    try std.testing.expectEqual(TokenKind.lit_int, toks[7].kind);
    try std.testing.expectEqual(@as(i64, 1), toks[7].int_val);
    try std.testing.expectEqual(TokenKind.eof, toks[8].kind);
}

test "keywords are case-insensitive" {
    const alloc = std.testing.allocator;
    const toks = try Lexer.tokenize("SeLeCt SELECT select", alloc);
    defer alloc.free(toks);
    for (toks[0..3]) |tok|
        try std.testing.expectEqual(TokenKind.kw_select, tok.kind);
}

test "integer and float literals" {
    const alloc = std.testing.allocator;
    const toks = try Lexer.tokenize("42 3.14", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(TokenKind.lit_int, toks[0].kind);
    try std.testing.expectEqual(@as(i64, 42), toks[0].int_val);
    try std.testing.expectEqual(TokenKind.lit_float, toks[1].kind);
    try std.testing.expectApproxEqAbs(toks[1].float_val, 3.14, 1e-9);
}

test "string literal str_start/str_end" {
    const src = "SELECT 'hello'";
    const alloc = std.testing.allocator;
    const toks = try Lexer.tokenize(src, alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(TokenKind.lit_string, toks[1].kind);
    try std.testing.expectEqualStrings("hello", src[toks[1].str_start..toks[1].str_end]);
}

test "line comments are skipped" {
    const alloc = std.testing.allocator;
    const toks = try Lexer.tokenize("-- this is a comment\nSELECT", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(TokenKind.kw_select, toks[0].kind);
    try std.testing.expectEqual(TokenKind.eof, toks[1].kind);
}

test "comparison operators" {
    const alloc = std.testing.allocator;
    const toks = try Lexer.tokenize("= != <> < <= > >=", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(TokenKind.op_eq, toks[0].kind);
    try std.testing.expectEqual(TokenKind.op_neq, toks[1].kind);
    try std.testing.expectEqual(TokenKind.op_neq, toks[2].kind);
    try std.testing.expectEqual(TokenKind.op_lt, toks[3].kind);
    try std.testing.expectEqual(TokenKind.op_lte, toks[4].kind);
    try std.testing.expectEqual(TokenKind.op_gt, toks[5].kind);
    try std.testing.expectEqual(TokenKind.op_gte, toks[6].kind);
}

test "unterminated string returns error" {
    var lex = Lexer.init("'unterminated");
    try std.testing.expectError(LexError.UnterminatedString, lex.next());
}

test "unexpected char returns error" {
    var lex = Lexer.init("@");
    try std.testing.expectError(LexError.UnexpectedChar, lex.next());
}
