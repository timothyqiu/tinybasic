const std = @import("std");
const Allocator = std.mem.Allocator;
const tok = @import("tokenizer.zig");
const psr = @import("parser.zig");
const exc = @import("executor.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("Memory leaked!");
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    if (argv.len == 1) {
        try stdout.print("Usage: {s} <file>\n", .{std.fs.path.basename(argv[0])});
        return;
    }
    const source = try std.fs.cwd().readFileAllocOptions(
        allocator,
        argv[1],
        std.math.maxInt(u32),
        null,
        @alignOf(u8),
        0,
    );
    defer allocator.free(source);

    var token_list = tok.TokenList{};
    defer token_list.deinit(allocator);

    var tokenizer = tok.Tokenizer{
        .source = source,
        .index = 0,
    };
    while (true) {
        const token = tokenizer.next();
        try token_list.append(allocator, token);
        if (token.tag == .eof) break;
    }

    // try dumpInvalidTokens(source, token_list.slice(), stdout.any());

    var parser = psr.Parser.init(allocator, token_list.items(.tag));
    defer parser.deinit();
    parser.parse() catch |err| {
        // try dumpParserResult(&parser, source, token_list.slice(), stdout.any());
        switch (err) {
            error.OutOfMemory => try stdout.print("Out of memory :(\n", .{}),
            error.ParseFailed => try dumpParserError(&parser, source, token_list.slice(), stdout.any()),
        }
        return;
    };

    // try dumpParserResult(&parser, source, token_list.slice(), stdout.any());

    const ast = exc.Ast{
        .source = source,
        .tokens = token_list.slice(),
        .nodes = parser.nodes.slice(),
        .extra_data = parser.extra_data.items,
    };
    var exe = try exc.Executor.init(
        allocator,
        &ast,
        stdout.any(),
        std.io.getStdIn().reader().any(),
    );
    defer exe.deinit();

    var running: bool = true;
    while (running) {
        running = exe.step() catch |err| {
            switch (err) {
                error.OutOfMemory => try stdout.print("Out of memory :(\n", .{}),
                error.EvaluationFailed => try dumpEvaluationError(&exe, stdout.any()),
            }
            return;
        };
    }
}

fn dumpTokenList(source: []const u8, tokens: tok.TokenList.Slice, writer: std.io.AnyWriter) !void {
    for (0..tokens.len) |i| {
        const token = tokens.get(i);

        const text = source[token.loc.start..token.loc.end];
        const all_printable = blk: for (text) |c| {
            if (!std.ascii.isPrint(c)) {
                break :blk false;
            }
        } else break :blk true;

        if (all_printable) {
            try writer.print("Token #{d:<3} {s} {s}\n", .{ i, @tagName(token.tag), text });
        } else {
            try writer.print("Token #{d:<3} {s} {x:0>2}\n", .{ i, @tagName(token.tag), text });
        }
    }
}

fn dumpInvalidTokens(source: []const u8, tokens: tok.TokenList.Slice, writer: std.io.AnyWriter) !void {
    var count: usize = 0;
    for (0..tokens.len) |i| {
        const token = tokens.get(i);
        if (token.tag == .invalid) {
            try writer.print("Token #{d:<3} is invalid\n", .{i});
            try tok.markToken(source, token, writer);
            count += 1;
        }
    }
}

fn dumpParserResult(
    p: *psr.Parser,
    source: []const u8,
    tokens: tok.TokenList.Slice,
    writer: std.io.AnyWriter,
) !void {
    const nodes = p.nodes.slice();
    for (0..nodes.len) |i| {
        const node = nodes.get(i);
        try writer.print("Node #{d:<3} {s:<12}", .{ i, @tagName(node.tag) });
        switch (node.tag) {
            .root,
            .expression,
            .term_plus,
            .term_minus,
            .stmt_print,
            .stmt_input,
            => {
                for (p.extra_data.items[node.data.lhs..node.data.rhs]) |node_index| {
                    try writer.print("#{d} ", .{node_index});
                }
                try writer.writeByte('\n');
            },

            .stmt_goto,
            .stmt_gosub,
            .line_naked,
            .factor_mul,
            .factor_div,
            => try writer.print("#{}\n", .{node.data.lhs}),

            .line_marked => {
                const token = tokens.get(node.token);
                try writer.print(".line_number = {s}, #{}\n", .{
                    source[token.loc.start..token.loc.end],
                    node.data.lhs,
                });
            },

            .variable, .number, .string => {
                const token = tokens.get(node.token);
                try writer.print("{s}\n", .{source[token.loc.start..token.loc.end]});
            },

            .stmt_if => try writer.print("IF #{} THEN #{}\n", .{ node.data.lhs, node.data.rhs }),

            .predicate => {
                const token = tokens.get(node.token);
                try writer.print("#{} {s} #{}\n", .{
                    node.data.lhs,
                    @tagName(token.tag),
                    node.data.rhs,
                });
            },

            .stmt_let => {
                const token = tokens.get(node.token);
                try writer.print("LET {s} = #{}\n", .{
                    source[token.loc.start..token.loc.end],
                    node.data.rhs,
                });
            },

            .stmt_end => try writer.writeByte('\n'),

            .call => {
                const token = tokens.get(node.token);
                try writer.print("{s}(#{})\n", .{
                    source[token.loc.start..token.loc.end],
                    node.data.lhs,
                });
            },

            else => try writer.print(".token = {d}, {{ .lhs = {d}, .rhs = {d} }}\n", .{
                node.token,
                node.data.lhs,
                node.data.rhs,
            }),
        }
    }
}

fn dumpParserError(
    p: *psr.Parser,
    source: []const u8,
    tokens: tok.TokenList.Slice,
    writer: std.io.AnyWriter,
) !void {
    for (p.errors.items) |err| {
        const token = tokens.get(err.token);
        const line = std.mem.count(u8, source[0..token.loc.start], "\n") + 1;

        try writer.print("line {d}: error: ", .{line});
        if (token.tag == .invalid) {
            try writer.print("invalid token\n", .{});
        } else {
            switch (err.tag) {
                .expect_token => try writer.print("expect `{s}` got `{s}`\n", .{
                    @tagName(err.data.token_tag),
                    @tagName(token.tag),
                }),

                else => try writer.print("{s}\n", .{@tagName(err.tag)}),
            }
        }
        try tok.markToken(source, token, writer);
    }
}

fn dumpEvaluationError(
    exe: *const exc.Executor,
    writer: std.io.AnyWriter,
) !void {
    for (exe.errors.items) |err| {
        try writer.writeAll("error: ");
        switch (err.tag) {
            .missing_line => try writer.print("missing line {d}\n", .{err.data.number}),
            else => try writer.print("{s}\n", .{@tagName(err.tag)}),
        }
    }
}
