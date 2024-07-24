const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Location,

    pub const Tag = enum(u8) {
        invalid,
        eof,
        eol,
        comma,
        number,
        string,
        lparen,
        rparen,
        op_plus,
        op_minus,
        op_mul,
        op_div,
        op_eq,
        op_ne,
        op_lt,
        op_lte,
        op_gt,
        op_gte,
        variable,
        keyword_print,
        keyword_if,
        keyword_then,
        keyword_goto,
        keyword_input,
        keyword_let,
        keyword_gosub,
        keyword_return,
        keyword_clear,
        keyword_list,
        keyword_run,
        keyword_end,
        func_abs,
        func_rnd,
    };

    pub const Location = struct {
        start: u32,
        end: u32,
    };
};

pub const TokenList = std.MultiArrayList(Token);

pub const Tokenizer = struct {
    source: [:0]const u8,
    index: u32,

    pub fn next(self: *Tokenizer) Token {
        var result = Token{
            .tag = undefined,
            .loc = .{ .start = self.index, .end = undefined },
        };
        var state: State = .start;

        while (true) : (self.index += 1) {
            const c = self.source[self.index];

            switch (state) {
                .start => switch (c) {
                    0 => {
                        result.tag = .eof;
                        break;
                    },

                    ' ', '\r', '\t' => result.loc.start += 1,

                    '\n' => {
                        self.index += 1;
                        result.tag = .eol;
                        break;
                    },

                    '0'...'9' => state = .number,
                    '"' => state = .string,
                    'A'...'Z' => state = .identifier,
                    '<' => state = .less_than,
                    '>' => state = .greater_than,

                    ',' => {
                        self.index += 1;
                        result.tag = .comma;
                        break;
                    },
                    '(' => {
                        self.index += 1;
                        result.tag = .lparen;
                        break;
                    },
                    ')' => {
                        self.index += 1;
                        result.tag = .rparen;
                        break;
                    },
                    '=' => {
                        self.index += 1;
                        result.tag = .op_eq;
                        break;
                    },
                    '+' => {
                        self.index += 1;
                        result.tag = .op_plus;
                        break;
                    },
                    '-' => {
                        self.index += 1;
                        result.tag = .op_minus;
                        break;
                    },
                    '*' => {
                        self.index += 1;
                        result.tag = .op_mul;
                        break;
                    },
                    '/' => {
                        self.index += 1;
                        result.tag = .op_div;
                        break;
                    },

                    else => {
                        self.index += 1;
                        result.tag = .invalid;
                        break;
                    },
                },

                .number => switch (c) {
                    '0'...'9' => {},
                    else => {
                        const text = self.source[result.loc.start..self.index];
                        if (std.fmt.parseInt(i16, text, 10)) |_| {
                            result.tag = .number;
                        } else |_| {
                            result.tag = .invalid;
                        }
                        break;
                    },
                },

                .string => switch (c) {
                    // Original TINY BASIC only allows UPPER CASE.
                    // ' ', '!', '#'...'Z' => {},
                    ' ', '!', '#'...'z' => {},
                    '"' => {
                        self.index += 1;
                        result.tag = .string;
                        break;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .identifier => switch (c) {
                    'A'...'Z' => {},
                    else => {
                        const text = self.source[result.loc.start..self.index];
                        if (indentifiers.get(text)) |tag| {
                            result.tag = tag;
                            break;
                        }
                        if (text.len == 1) {
                            result.tag = .variable;
                            break;
                        }
                        if (std.mem.eql(u8, text, "REM")) {
                            // Original TINY BASIC doesn't have comments.
                            state = .comment;
                        } else {
                            result.tag = .invalid;
                            break;
                        }
                    },
                },

                .comment => switch (c) {
                    '\n' => {
                        result.loc.start = self.index + 1;
                        state = .start;
                    },
                    else => {},
                },

                .less_than => switch (c) {
                    '=' => {
                        self.index += 1;
                        result.tag = .op_lte;
                        break;
                    },
                    '>' => {
                        self.index += 1;
                        result.tag = .op_ne;
                        break;
                    },
                    else => {
                        result.tag = .op_lt;
                        break;
                    },
                },

                .greater_than => switch (c) {
                    '=' => {
                        self.index += 1;
                        result.tag = .op_gte;
                        break;
                    },
                    '<' => {
                        self.index += 1;
                        result.tag = .op_ne;
                        break;
                    },
                    else => {
                        result.tag = .op_gt;
                        break;
                    },
                },
            }
        }

        result.loc.end = self.index;
        return result;
    }

    const State = enum {
        start,
        number,
        string,
        identifier,
        less_than,
        greater_than,
        comment,
    };

    const indentifiers = std.StaticStringMap(Token.Tag).initComptime(.{
        .{ "PRINT", .keyword_print },
        .{ "IF", .keyword_if },
        .{ "THEN", .keyword_then },
        .{ "GOTO", .keyword_goto },
        .{ "INPUT", .keyword_input },
        .{ "LET", .keyword_let },
        .{ "GOSUB", .keyword_gosub },
        .{ "RETURN", .keyword_return },
        .{ "CLEAR", .keyword_clear },
        .{ "LIST", .keyword_list },
        .{ "RUN", .keyword_run },
        .{ "END", .keyword_end },
        .{ "ABS", .func_abs },
        .{ "RND", .func_rnd },
    });
};

pub fn markToken(source: []const u8, token: Token, writer: std.io.AnyWriter) !void {
    const begin = if (std.mem.lastIndexOfScalar(u8, source[0..token.loc.start], '\n')) |v| v + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, source, token.loc.start, '\n') orelse source.len;
    const text = source[begin..end];

    try writer.print("{s}\n", .{text});
    if (token.loc.end - token.loc.start > 1) {
        try writer.writeByteNTimes(' ', token.loc.start - begin);
        try writer.writeByteNTimes('~', token.loc.end - token.loc.start);
        try writer.writeByte('\n');
    } else {
        try writer.writeByteNTimes(' ', token.loc.start - begin);
        try writer.print("^\n", .{});
    }
}
