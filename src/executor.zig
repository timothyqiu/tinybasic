const std = @import("std");
const Allocator = std.mem.Allocator;
const TokenList = @import("tokenizer.zig").TokenList;
const Node = @import("parser.zig").Node;
const NodeList = @import("parser.zig").NodeList;
const NodeIndex = @import("parser.zig").NodeIndex;
const TokenIndex = @import("parser.zig").TokenIndex;

pub const Ast = struct {
    source: []const u8,
    tokens: TokenList.Slice,
    nodes: NodeList.Slice,
    extra_data: []NodeIndex,

    fn getNumber(self: *const Ast, token_index: TokenIndex) i16 {
        const token = self.tokens.get(token_index);
        std.debug.assert(token.tag == .number);
        const text = self.source[token.loc.start..token.loc.end];
        return std.fmt.parseInt(i16, text, 10) catch unreachable;
    }

    fn getString(self: *const Ast, token_index: TokenIndex) []const u8 {
        const token = self.tokens.get(token_index);
        std.debug.assert(token.tag == .string);
        return self.source[token.loc.start + 1 .. token.loc.end - 1];
    }
};

pub const Executor = struct {
    gpa: Allocator,
    ast: *const Ast,
    stdout: std.io.AnyWriter,
    stdin: std.io.AnyReader,
    rng: std.Random.DefaultPrng,

    variables: [26]i16,
    lines: []const NodeIndex,
    line_map: std.AutoHashMapUnmanaged(i16, usize),
    errors: std.ArrayListUnmanaged(ErrorMessage),

    stack: [16]usize,
    sp: usize,
    pc: usize,

    const EvaluationError = error{
        EvaluationFailed,
        OutOfMemory,
    };

    pub fn init(
        allocator: Allocator,
        ast: *const Ast,
        stdout: std.io.AnyWriter,
        stdin: std.io.AnyReader,
    ) !Executor {
        const root = ast.nodes.get(0);
        const lines = ast.extra_data[root.data.lhs..root.data.rhs];

        var line_map = std.AutoHashMapUnmanaged(i16, usize){};
        errdefer line_map.deinit(allocator);
        for (lines, 0..) |line_index, i| {
            const node = ast.nodes.get(line_index);
            if (node.tag == .line_naked) continue;
            const number = ast.getNumber(node.token);
            try line_map.put(allocator, number, i);
        }

        return .{
            .gpa = allocator,
            .ast = ast,
            .stdout = stdout,
            .stdin = stdin,
            .rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp())),
            .variables = undefined,
            .lines = lines,
            .line_map = line_map,
            .errors = .{},
            .stack = undefined,
            .pc = 0,
            .sp = 0,
        };
    }

    pub fn deinit(self: *Executor) void {
        self.line_map.deinit(self.gpa);
        self.errors.deinit(self.gpa);
    }

    pub fn step(self: *Executor) !bool {
        if (self.pc >= self.lines.len) {
            return false;
        }
        const pc = self.pc;
        self.pc += 1;
        _ = try self.evaluate(self.lines[pc]);
        return true;
    }

    fn evaluate(self: *Executor, index: NodeIndex) EvaluationError!?i16 {
        const node = self.ast.nodes.get(index);
        switch (node.tag) {
            .line_naked, .line_marked => return self.evaluate(node.data.lhs),

            .number => return self.ast.getNumber(node.token),

            .variable => return self.getVariable(node.token),

            .factor_mul, .factor_div => return self.evaluate(node.data.lhs),

            .term_plus, .term_minus => {
                const factors = self.ast.extra_data[node.data.lhs..node.data.rhs];
                var product: i16 = 1;
                for (factors) |factor_index| {
                    const value = try self.evaluate(factor_index) orelse unreachable;
                    product = switch (self.ast.nodes.get(factor_index).tag) {
                        .factor_mul => std.math.mul(i16, product, value),
                        .factor_div => std.math.divTrunc(i16, product, value),
                        else => unreachable,
                    } catch |err| return self.addError(.{
                        .tag = switch (err) {
                            error.DivisionByZero => .division_by_zero,
                            error.Overflow => .math_overflow,
                        },
                    });
                }
                return product;
            },

            .expression => {
                const terms = self.ast.extra_data[node.data.lhs..node.data.rhs];
                var sum: i16 = 0;
                for (terms) |term_index| {
                    const value = try self.evaluate(term_index) orelse unreachable;
                    sum = switch (self.ast.nodes.get(term_index).tag) {
                        .term_plus => std.math.add(i16, sum, value),
                        .term_minus => std.math.sub(i16, sum, value),
                        else => unreachable,
                    } catch return self.addError(.{
                        .tag = .math_overflow,
                    });
                }
                return sum;
            },

            .stmt_print => {
                self.evaluatePrintStatement(&node) catch |err| return switch (err) {
                    error.OutOfMemory, error.EvaluationFailed => |e| e,
                    else => self.addError(.{
                        .tag = .io_failed,
                        .data = .{ .err = err },
                    }),
                };
                return null;
            },

            .stmt_input => {
                self.evaluateInputStatement(&node) catch |err| return switch (err) {
                    error.OutOfMemory, error.EvaluationFailed => |e| e,
                    else => self.addError(.{
                        .tag = .io_failed,
                        .data = .{ .err = err },
                    }),
                };
                return null;
            },

            .stmt_let => {
                self.setVariable(node.token, try self.evaluate(node.data.rhs) orelse unreachable);
                return null;
            },

            .stmt_if => {
                const predicate = try self.evaluate(node.data.lhs) orelse unreachable;
                if (predicate != 0) {
                    _ = try self.evaluate(node.data.rhs);
                }
                return null;
            },

            .stmt_gosub, .stmt_goto => {
                if (node.tag == .stmt_gosub) {
                    if (self.sp + 1 == self.stack.len) {
                        return self.addError(.{ .tag = .too_many_gosubs });
                    }
                    self.sp += 1;
                    self.stack[self.sp] = self.pc;
                }

                const number = try self.evaluate(node.data.lhs) orelse unreachable;
                if (self.line_map.get(number)) |pc| {
                    self.pc = pc;
                    return null;
                }
                return self.addError(.{
                    .tag = .missing_line,
                    .data = .{ .number = number },
                });
            },

            .stmt_return => {
                if (self.sp == 0) {
                    return self.addError(.{ .tag = .return_without_gosub });
                }
                defer self.sp -= 1;
                self.pc = self.stack[self.sp];
                return null;
            },

            .stmt_end => {
                self.pc = std.math.maxInt(usize);
                return null;
            },

            .predicate => {
                const lhs = try self.evaluate(node.data.lhs) orelse unreachable;
                const rhs = try self.evaluate(node.data.rhs) orelse unreachable;
                return @intFromBool(switch (self.ast.tokens.get(node.token).tag) {
                    .op_eq => lhs == rhs,
                    .op_ne => lhs != rhs,
                    .op_lt => lhs < rhs,
                    .op_lte => lhs <= rhs,
                    .op_gt => lhs > rhs,
                    .op_gte => lhs >= rhs,
                    else => unreachable,
                });
            },

            .call_1 => {
                const arg = try self.evaluate(node.data.lhs) orelse unreachable;
                return switch (self.ast.tokens.get(node.token).tag) {
                    .func_abs => @intCast(@abs(arg)),
                    .func_rnd => self.rng.random().intRangeAtMost(i16, 1, @max(1, arg)),
                    else => unreachable,
                };
            },

            .call_2 => {
                const arg1 = try self.evaluate(node.data.lhs) orelse unreachable;
                const arg2 = try self.evaluate(node.data.rhs) orelse unreachable;
                switch (self.ast.tokens.get(node.token).tag) {
                    .func_mod => {
                        if (arg2 == 0) {
                            return self.addError(.{ .tag = .division_by_zero });
                        }
                        return @mod(arg1, arg2);
                    },

                    else => unreachable,
                }
            },

            else => return self.addError(.{
                .tag = .not_implemented,
            }),
        }
    }

    fn evaluatePrintStatement(self: *Executor, node: *const Node) !void {
        const exprs = self.ast.extra_data[node.data.lhs..node.data.rhs];
        for (exprs, 0..) |expr_index, i| {
            if (i > 0) {
                try self.stdout.writeByte(' ');
            }

            const expr_node = self.ast.nodes.get(expr_index);
            switch (expr_node.tag) {
                .string => {
                    try self.stdout.writeAll(self.ast.getString(expr_node.token));
                },

                .expression => {
                    try self.stdout.print("{d}", .{try self.evaluate(expr_index) orelse unreachable});
                },

                else => unreachable,
            }
        }
        try self.stdout.writeByte('\n');
    }

    fn evaluateInputStatement(self: *Executor, node: *const Node) !void {
        const vars = self.ast.extra_data[node.data.lhs..node.data.rhs];

        var buffer: [128]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);

        for (vars) |var_index| {
            while (true) {
                try self.stdout.writeAll("? ");

                stream.reset();
                try self.stdin.streamUntilDelimiter(stream.writer(), '\n', buffer.len);

                const value = std.fmt.parseInt(i16, stream.getWritten(), 10) catch |err| {
                    std.debug.print("Invalid integer: {s}\n", .{@errorName(err)});
                    continue;
                };

                self.setVariable(self.ast.nodes.get(var_index).token, value);
                break;
            }
        }
    }

    fn getVariable(self: *const Executor, token_index: TokenIndex) i16 {
        const token = self.ast.tokens.get(token_index);
        std.debug.assert(token.tag == .variable);
        const v = self.ast.source[token.loc.start] - 'A';
        return self.variables[v];
    }

    fn setVariable(self: *Executor, token_index: TokenIndex, value: i16) void {
        const token = self.ast.tokens.get(token_index);
        std.debug.assert(token.tag == .variable);
        const v = self.ast.source[token.loc.start] - 'A';
        self.variables[v] = value;
    }

    fn addError(self: *Executor, err: ErrorMessage) EvaluationError {
        @setCold(true);
        try self.errors.append(self.gpa, err);
        return error.EvaluationFailed;
    }
};

pub const ErrorMessage = struct {
    tag: Tag,
    data: union {
        none: void,
        number: i16,
        err: anyerror,
    } = .{ .none = {} },

    const Tag = enum {
        not_implemented,
        math_overflow,
        division_by_zero,
        return_without_gosub,
        too_many_gosubs,
        /// data.number = expected
        missing_line,
        /// data.err = actual err
        io_failed,
    };
};
