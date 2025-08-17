const std = @import("std");
const SrcLocation = @import("lexer.zig").SrcLocation;
const Token = @import("lexer.zig").Token;
const SemanticASTType = @import("analyzer.zig").SemanticASTType;

pub const SimpleAstType = enum {
    MainEntry,
    BasicOp,
    Loop,
};

pub const SimpleAst = union(SimpleAstType) {
    /// Root node of a Brainfuck program.
    MainEntry: struct {
        body: std.ArrayList(SimpleAst),

        /// Whether any nested loops exist in the body.
        has_nested_loops: bool = false,
        /// Net pointer movement after execution (null if dynamic).
        ptr_move_per_iteration: ?isize = null,
        /// Minimum pointer position reached (relative to start).
        min_ptr: isize = 0,
        /// Maximum pointer position reached (relative to start).
        max_ptr: isize = 0,

        /// Whether this loop contains IO operation (`,` and `.`).
        has_io: bool = true,
        /// Whether this loop contains add/sub operation (`+` and `-`).
        has_add: bool = false,
        /// Whether this loop contains addptr/subptr operation (`>` and `<`).
        has_addptr: bool = false,
    },
    /// Basic Brainfuck operation (non-loop).
    BasicOp: struct {
        type: enum { Add, Sub, AddPtr, SubPtr, Read, Write },
        loc: SrcLocation,
    },
    /// Loop structure (`[ ... ]`).
    Loop: struct {
        loc: SrcLocation,
        body: std.ArrayList(SimpleAst),

        /// Whether this loop contains nested loops.
        /// - If `false`: The pointer movement range (`min_ptr`/`max_ptr`) can be statically determined.
        /// - If `true`: The pointer range depends on runtime behavior of nested loops.
        has_nested_loops: bool = false,
        /// Net pointer movement after per loop iteration:
        /// - If `null`: Pointer position depends on runtime input or pre-loop memory state.
        /// - If non-null: Statically determined (e.g., `[>]` has `ptrOffset = 1`).
        ptr_move_per_iteration: ?isize = null,
        /// Minimum pointer position reached during loop execution (relative to start).
        max_ptr: isize = 0,
        /// Maximum pointer position reached during loop execution (relative to start).
        min_ptr: isize = 0,

        /// Whether this loop contains IO operation (`,` and `.`).
        has_io: bool = false,
        /// Whether this loop contains add/sub operation (`+` and `-`).
        has_add: bool = false,
        /// Whether this loop contains addptr/subptr operation (`>` and `<`).
        has_addptr: bool = false,
    },

    pub fn deinit(self: SimpleAst) void {
        switch (self) {
            .MainEntry => |entry| {
                for (entry.body.items) |node| {
                    node.deinit();
                }
                entry.body.deinit();
            },
            .BasicOp => {},
            .Loop => |loop| {
                for (loop.body.items) |node| {
                    node.deinit();
                }
                loop.body.deinit();
            },
        }
    }
};

pub const ParseError = error{
    UnmatchLeftBracket,
    UnmatchRightBracket,
};

fn ParserGenic(comptime is_loop: bool) type {
    return struct {
        fn parse(tokens: []const Token, index: *usize, alloc: std.mem.Allocator, errorLoc: *?SrcLocation) !SimpleAst {
            var root =
                if (is_loop)
                    SimpleAst{ .Loop = .{ .body = std.ArrayList(SimpleAst).init(alloc), .loc = tokens[index.* - 1].loc } }
                else
                    SimpleAst{ .MainEntry = .{ .body = std.ArrayList(SimpleAst).init(alloc) } };
            errdefer root.deinit();

            var node =
                if (is_loop)
                    &root.Loop
                else
                    &root.MainEntry;

            var ptr: isize = 0;
            var sub_loop_balanced = true;
            while (index.* < tokens.len) : ({
                index.* += 1;
                node.max_ptr = @max(node.max_ptr, ptr);
                node.min_ptr = @min(node.min_ptr, ptr);
            }) {
                const token = tokens[index.*];
                var body = &node.body;
                switch (token.char) {
                    '+' => {
                        node.has_add = true;
                        try body.append(.{ .BasicOp = .{ .type = .Add, .loc = token.loc } });
                    },
                    '-' => {
                        node.has_add = true;
                        try body.append(.{ .BasicOp = .{ .type = .Sub, .loc = token.loc } });
                    },
                    ',' => {
                        node.has_io = true;
                        try body.append(.{ .BasicOp = .{ .type = .Read, .loc = token.loc } });
                    },
                    '.' => {
                        node.has_io = true;
                        try body.append(.{ .BasicOp = .{ .type = .Write, .loc = token.loc } });
                    },
                    '>' => {
                        node.has_addptr = true;
                        ptr += 1;
                        try body.append(.{ .BasicOp = .{ .type = .AddPtr, .loc = token.loc } });
                    },
                    '<' => {
                        node.has_addptr = true;
                        ptr -= 1;
                        try body.append(.{ .BasicOp = .{ .type = .SubPtr, .loc = token.loc } });
                    },
                    ']' => {
                        if (is_loop) {
                            if (sub_loop_balanced) {
                                node.ptr_move_per_iteration = ptr;
                            }
                            return root;
                        } else {
                            errorLoc.* = token.loc;
                            return ParseError.UnmatchRightBracket;
                        }
                    },
                    '[' => {
                        if (index.* == tokens.len - 1) {
                            errorLoc.* = token.loc;
                            return ParseError.UnmatchLeftBracket;
                        }
                        node.has_nested_loops = true;
                        index.* += 1;
                        const loop_child = try ParserGenic(true).parse(tokens, index, alloc, errorLoc);
                        sub_loop_balanced = sub_loop_balanced and if (loop_child.Loop.ptr_move_per_iteration) |ptr_move| ptr_move == 0 else false;
                        node.has_io = node.has_io or loop_child.Loop.has_io;
                        node.has_add = node.has_add or loop_child.Loop.has_add;
                        node.has_addptr = node.has_addptr or loop_child.Loop.has_addptr;
                        try body.append(loop_child);
                        ptr = 0;
                    },
                    else => unreachable,
                }
            }

            if (is_loop) {
                errorLoc.* = node.loc;
                return ParseError.UnmatchLeftBracket;
            } else {
                if (sub_loop_balanced) {
                    node.ptr_move_per_iteration = ptr;
                }
                return root;
            }
        }
    };
}

pub fn Parse(tokens: []const Token, alloc: std.mem.Allocator, errorLoc: *?SrcLocation) !SimpleAst {
    var index: usize = 0;
    return ParserGenic(false).parse(tokens, &index, alloc, errorLoc);
}

test "bracket match" {
    const lex = @import("lexer.zig").lex;
    const alloc = std.testing.allocator;

    const test_program1 = "[+-[],";
    const test_tokens1 = try lex(test_program1, alloc);
    defer alloc.free(test_tokens1);
    var errorLoc: ?SrcLocation = null;
    const ret1 = Parse(test_tokens1, alloc, &errorLoc);
    try std.testing.expectError(ParseError.UnmatchLeftBracket, ret1);
    try std.testing.expectEqual(SrcLocation{ .line = 1, .col = 1 }, errorLoc);

    const test_program2 = "++>[\n-+>]]";
    const test_tokens2 = try lex(test_program2, alloc);
    defer alloc.free(test_tokens2);
    errorLoc = null;
    const ret2 = Parse(test_tokens2, alloc, &errorLoc);
    try std.testing.expectError(ParseError.UnmatchRightBracket, ret2);
    try std.testing.expectEqual(SrcLocation{ .line = 2, .col = 5 }, errorLoc);
}
