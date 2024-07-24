const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("tokenizer.zig").Token;

pub const TokenIndex = u32;
pub const NodeIndex = u32;

pub const Node = struct {
    tag: Tag,
    token: TokenIndex,
    data: Data,

    pub const Tag = enum(u8) {
        /// extra_data[[lhs..rhs]] = [[line_*]]
        root,
        /// lhs = stmt_*
        line_naked,
        /// token = line_number
        /// lhs = stmt_*
        line_marked,
        /// token = PRINT
        /// extra_data[[lhs..rhs]] = [[string|expression]]
        stmt_print,
        /// LET token = rhs
        stmt_let,
        /// IF lhs THEN rhs
        /// lhs = predicate
        /// rhs = statement
        stmt_if,
        /// GOTO lhs
        /// token = GOTO
        /// lhs = expression
        stmt_goto,
        /// GOSUB lhs
        /// token = GOSUB
        /// lhs = expression
        stmt_gosub,
        /// token = INPUT
        /// extra_data[[lhs..rhs]] = [[varable]]
        stmt_input,
        stmt_return,
        stmt_clear,
        stmt_list,
        stmt_run,
        stmt_end,
        /// token = "XXX"
        string,
        /// extra_data[[lhs..rhs]] = [[term_*]]
        expression,
        /// extra_data[[lhs..rhs]] = [[factor_*]]
        term_plus,
        /// extra_data[[lhs..rhs]] = [[factor_*]]
        term_minus,
        /// lhs = variable | number | expression
        factor_mul,
        /// lhs = variable | number | expression
        factor_div,
        /// lhs token rhs
        predicate,
        /// token = X
        variable,
        /// token = X
        number,
        /// token = function
        /// lhs = arg1
        call,
    };

    pub const Data = struct {
        lhs: NodeIndex,
        rhs: NodeIndex,
    };
};

pub const NodeList = std.MultiArrayList(Node);

pub const Parser = struct {
    gpa: Allocator,
    token_tags: []const Token.Tag,
    tok_i: TokenIndex,
    nodes: NodeList,
    errors: std.ArrayListUnmanaged(ErrorMessage),
    extra_data: std.ArrayListUnmanaged(NodeIndex),
    scratch: std.ArrayListUnmanaged(NodeIndex),

    const ParserError = error{
        ParseFailed,
        OutOfMemory,
    };

    pub fn init(allocator: Allocator, token_tags: []const Token.Tag) Parser {
        return .{
            .gpa = allocator,
            .token_tags = token_tags,
            .tok_i = 0,
            .nodes = .{},
            .errors = .{},
            .extra_data = .{},
            .scratch = .{},
        };
    }

    pub fn deinit(self: *Parser) void {
        self.nodes.deinit(self.gpa);
        self.errors.deinit(self.gpa);
        self.extra_data.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
    }

    pub fn parse(self: *Parser) !void {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        try self.nodes.append(self.gpa, .{
            .tag = .root,
            .token = undefined,
            .data = undefined,
        });

        while (self.token_tags[self.tok_i] != .eof) {
            if (try self.parseLine()) |line| {
                try self.scratch.append(self.gpa, line);
            }
        }

        const items = self.scratch.items[scratch_top..];
        try self.extra_data.appendSlice(self.gpa, items);
        self.nodes.items(.data)[0] = .{
            .lhs = @intCast(self.extra_data.items.len - items.len),
            .rhs = @intCast(self.extra_data.items.len),
        };
    }

    fn parseLine(self: *Parser) !?NodeIndex {
        const maybe_line_number = self.eatToken(.number);
        const maybe_statement = try self.parseStatement();

        if (self.eatToken(.eol) == null and self.token_tags[self.tok_i] != .eof) {
            return self.addError(.{
                .tag = .expect_token,
                .token = self.tok_i,
                .data = .{ .token_tag = .eol },
            });
        }

        if (maybe_statement) |stmt| {
            if (maybe_line_number) |line_number| {
                return try self.addNode(.{
                    .tag = .line_marked,
                    .token = line_number,
                    .data = .{ .lhs = stmt, .rhs = undefined },
                });
            } else {
                return try self.addNode(.{
                    .tag = .line_naked,
                    .token = undefined,
                    .data = .{ .lhs = stmt, .rhs = undefined },
                });
            }
        }
        return null;
    }

    fn parseStatement(self: *Parser) ParserError!?NodeIndex {
        return switch (self.token_tags[self.tok_i]) {
            .eol => null,

            .keyword_print => try self.expectPrintStatement(),
            .keyword_input => try self.expectInputStatement(),
            .keyword_let => try self.expectLetStatement(),
            .keyword_if => try self.expectIfStatement(),

            .keyword_goto => try self.expectGoStatement(.stmt_goto),
            .keyword_gosub => try self.expectGoStatement(.stmt_gosub),

            .keyword_return => try self.addNode(.{
                .tag = .stmt_return,
                .token = self.nextToken(),
                .data = undefined,
            }),
            .keyword_clear => try self.addNode(.{
                .tag = .stmt_clear,
                .token = self.nextToken(),
                .data = undefined,
            }),
            .keyword_list => try self.addNode(.{
                .tag = .stmt_list,
                .token = self.nextToken(),
                .data = undefined,
            }),
            .keyword_run => try self.addNode(.{
                .tag = .stmt_run,
                .token = self.nextToken(),
                .data = undefined,
            }),
            .keyword_end => try self.addNode(.{
                .tag = .stmt_end,
                .token = self.nextToken(),
                .data = undefined,
            }),

            else => self.addError(.{
                .tag = .expect_token,
                .token = self.tok_i,
                .data = .{ .token_tag = .eol },
            }),
        };
    }

    fn expectStatement(self: *Parser) !NodeIndex {
        if (try self.parseStatement()) |index| {
            return index;
        }
        return self.addError(.{
            .tag = .expect_statement,
            .token = self.tok_i,
        });
    }

    fn expectPrintStatement(self: *Parser) !NodeIndex {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        const print = try self.expectToken(.keyword_print);

        while (true) {
            if (self.eatToken(.string)) |token| {
                try self.scratch.append(self.gpa, try self.addNode(.{
                    .tag = .string,
                    .token = token,
                    .data = undefined,
                }));
            } else {
                try self.scratch.append(self.gpa, try self.expectExpression());
            }

            if (self.eatToken(.comma) == null) break;
        }

        const items = self.scratch.items[scratch_top..];
        try self.extra_data.appendSlice(self.gpa, items);
        return try self.addNode(.{
            .tag = .stmt_print,
            .token = print,
            .data = .{
                .lhs = @intCast(self.extra_data.items.len - items.len),
                .rhs = @intCast(self.extra_data.items.len),
            },
        });
    }

    fn expectInputStatement(self: *Parser) !NodeIndex {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        const input = try self.expectToken(.keyword_input);

        try self.scratch.append(self.gpa, try self.expectVariable());
        while (self.eatToken(.comma)) |_| {
            try self.scratch.append(self.gpa, try self.expectVariable());
        }

        const items = self.scratch.items[scratch_top..];
        try self.extra_data.appendSlice(self.gpa, items);
        return try self.addNode(.{
            .tag = .stmt_input,
            .token = input,
            .data = .{
                .lhs = @intCast(self.extra_data.items.len - items.len),
                .rhs = @intCast(self.extra_data.items.len),
            },
        });
    }

    fn expectLetStatement(self: *Parser) !NodeIndex {
        _ = try self.expectToken(.keyword_let);
        const variable = try self.expectToken(.variable);
        _ = try self.expectToken(.op_eq);
        const expression = try self.expectExpression();
        return self.addNode(.{
            .tag = .stmt_let,
            .token = variable,
            .data = .{ .lhs = undefined, .rhs = expression },
        });
    }

    fn expectIfStatement(self: *Parser) !NodeIndex {
        _ = try self.expectToken(.keyword_if);
        const predicate = try self.expectPredicate();
        _ = try self.expectToken(.keyword_then);
        const statement = try self.expectStatement();
        return self.addNode(.{
            .tag = .stmt_if,
            .token = undefined,
            .data = .{ .lhs = predicate, .rhs = statement },
        });
    }

    fn expectGoStatement(self: *Parser, tag: Node.Tag) !NodeIndex {
        const token = self.nextToken();
        const expression = try self.expectExpression();
        return try self.addNode(.{
            .tag = tag,
            .token = token,
            .data = .{ .lhs = expression, .rhs = undefined },
        });
    }

    fn expectExpression(self: *Parser) ParserError!NodeIndex {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        if (self.eatToken(.op_minus)) |_| {
            try self.scratch.append(self.gpa, try self.expectTerm(.term_minus));
        } else {
            _ = self.eatToken(.op_plus);
            try self.scratch.append(self.gpa, try self.expectTerm(.term_plus));
        }

        while (true) {
            switch (self.token_tags[self.tok_i]) {
                .op_plus => {
                    _ = self.nextToken();
                    try self.scratch.append(self.gpa, try self.expectTerm(.term_plus));
                },
                .op_minus => {
                    _ = self.nextToken();
                    try self.scratch.append(self.gpa, try self.expectTerm(.term_minus));
                },

                else => break,
            }
        }

        const items = self.scratch.items[scratch_top..];
        try self.extra_data.appendSlice(self.gpa, items);
        return try self.addNode(.{
            .tag = .expression,
            .token = undefined,
            .data = .{
                .lhs = @intCast(self.extra_data.items.len - items.len),
                .rhs = @intCast(self.extra_data.items.len),
            },
        });
    }

    fn expectTerm(self: *Parser, tag: Node.Tag) !NodeIndex {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        try self.scratch.append(self.gpa, try self.expectFactor(.factor_mul));

        while (true) {
            switch (self.token_tags[self.tok_i]) {
                .op_mul => {
                    _ = self.nextToken();
                    try self.scratch.append(
                        self.gpa,
                        try self.expectFactor(.factor_mul),
                    );
                },
                .op_div => {
                    _ = self.nextToken();
                    try self.scratch.append(
                        self.gpa,
                        try self.expectFactor(.factor_div),
                    );
                },
                else => break,
            }
        }

        const items = self.scratch.items[scratch_top..];
        try self.extra_data.appendSlice(self.gpa, items);
        return try self.addNode(.{
            .tag = tag,
            .token = undefined,
            .data = .{
                .lhs = @intCast(self.extra_data.items.len - items.len),
                .rhs = @intCast(self.extra_data.items.len),
            },
        });
    }

    fn expectFactor(self: *Parser, tag: Node.Tag) !NodeIndex {
        if (self.eatToken(.variable)) |token| {
            const variable = try self.addNode(.{
                .tag = .variable,
                .token = token,
                .data = undefined,
            });
            return self.addNode(.{
                .tag = tag,
                .token = undefined,
                .data = .{ .lhs = variable, .rhs = undefined },
            });
        }

        if (self.eatToken(.number)) |token| {
            const number = try self.addNode(.{
                .tag = .number,
                .token = token,
                .data = undefined,
            });
            return self.addNode(.{
                .tag = tag,
                .token = undefined,
                .data = .{ .lhs = number, .rhs = undefined },
            });
        }

        if (self.eatToken(.lparen) != null) {
            const expression = try self.expectExpression();
            _ = try self.expectToken(.rparen);
            return self.addNode(.{
                .tag = tag,
                .token = undefined,
                .data = .{ .lhs = expression, .rhs = undefined },
            });
        }

        if (try self.parseCall()) |index| {
            return self.addNode(.{
                .tag = tag,
                .token = undefined,
                .data = .{ .lhs = index, .rhs = undefined },
            });
        }

        return self.addError(.{
            .tag = .expect_expression,
            .token = self.tok_i,
        });
    }

    fn parseCall(self: *Parser) !?NodeIndex {
        const token = switch (self.token_tags[self.tok_i]) {
            .func_abs,
            .func_rnd,
            => self.nextToken(),

            else => return null,
        };
        _ = try self.expectToken(.lparen);
        const expression = try self.expectExpression();
        _ = try self.expectToken(.rparen);
        return try self.addNode(.{
            .tag = .call,
            .token = token,
            .data = .{ .lhs = expression, .rhs = undefined },
        });
    }

    fn expectPredicate(self: *Parser) !NodeIndex {
        const lhs = try self.expectExpression();
        const relop = switch (self.token_tags[self.tok_i]) {
            .op_eq,
            .op_ne,
            .op_lt,
            .op_lte,
            .op_gt,
            .op_gte,
            => self.nextToken(),

            else => return self.addError(.{
                .tag = .expect_relop,
                .token = self.tok_i,
            }),
        };
        const rhs = try self.expectExpression();
        return self.addNode(.{
            .tag = .predicate,
            .token = relop,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }

    fn expectVariable(self: *Parser) !NodeIndex {
        const variable = try self.expectToken(.variable);
        return try self.addNode(.{
            .tag = .variable,
            .token = variable,
            .data = undefined,
        });
    }

    fn eatToken(self: *Parser, tag: Token.Tag) ?TokenIndex {
        return if (self.token_tags[self.tok_i] == tag) self.nextToken() else null;
    }

    fn expectToken(self: *Parser, tag: Token.Tag) !TokenIndex {
        const index = self.nextToken();
        if (self.token_tags[index] != tag) {
            return self.addError(.{
                .tag = .expect_token,
                .token = index,
                .data = .{ .token_tag = tag },
            });
        }
        return index;
    }

    fn nextToken(self: *Parser) TokenIndex {
        const result = self.tok_i;
        self.tok_i += 1;
        return result;
    }

    fn addError(self: *Parser, err: ErrorMessage) ParserError {
        @setCold(true);
        try self.errors.append(self.gpa, err);
        return error.ParseFailed;
    }

    fn addNode(self: *Parser, node: Node) !NodeIndex {
        const result: NodeIndex = @intCast(self.nodes.len);
        try self.nodes.append(self.gpa, node);
        return result;
    }
};

pub const ErrorMessage = struct {
    tag: Tag,
    token: TokenIndex,
    data: union {
        none: void,
        token_tag: Token.Tag,
    } = .{ .none = {} },

    const Tag = enum {
        /// data.token_tag = what the parser needs
        expect_token,
        ///
        expect_statement,
        ///
        expect_relop,
        ///
        expect_expression,
    };
};
