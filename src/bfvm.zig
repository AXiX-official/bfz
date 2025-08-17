const std = @import("std");
const lex = @import("parser/lexer.zig").lex;
const SrcLocation = @import("parser/lexer.zig").SrcLocation;
const SimpleAstType = @import("parser/parser.zig").SimpleAstType;
const SimpleAst = @import("parser/parser.zig").SimpleAst;
const Parse = @import("parser/parser.zig").Parse;
const SemanticAstType = @import("parser/analyzer.zig").SemanticAstType;
const SemanticAST = @import("parser/analyzer.zig").SemanticAST;
const analyze = @import("parser/analyzer.zig").analyze;

pub fn BFVM(comptime writer: type, comptime reader: type) type {
    return struct {
        const Self = @This();

        memory: []u8,
        ptr: usize = 0,
        alloc: std.mem.Allocator,
        stdout: writer,
        stdin: reader,
        limit: usize,
        size: usize = 0,

        pub fn init(alloc: std.mem.Allocator, size: usize, limit: usize, out: writer, in: reader) !Self {
            const mem = try alloc.alloc(u8, size);
            @memset(mem, 0);
            return Self{ .memory = mem, .alloc = alloc, .stdout = out, .stdin = in, .limit = limit };
        }

        pub fn deinit(self: *Self) void {
            self.alloc.free(self.memory);
        }

        pub fn executeString(self: *Self, bf_source: []const u8) !void {
            const compileBegin = std.time.microTimestamp();

            const tokens = try lex(bf_source, self.alloc);
            errdefer self.alloc.free(tokens);

            var errorLoc: ?SrcLocation = null;
            const simple_ast = try Parse(tokens, self.alloc, &errorLoc);
            errdefer simple_ast.deinit();

            const semantic_ast = try analyze(simple_ast, self.alloc);
            errdefer semantic_ast.deinit();

            const compileEnd = std.time.microTimestamp();
            const compile_elapsed_us = compileEnd - compileBegin;
            const compile_elapsed_s = @as(f64, @floatFromInt(compile_elapsed_us)) / 1_000_000.0;

            const executeBegin = std.time.microTimestamp();

            try self.executeSemanticAST(semantic_ast);

            const executeEnd = std.time.microTimestamp();
            const execute_elapsed_us = executeEnd - executeBegin;
            const execute_elapsed_s = @as(f64, @floatFromInt(execute_elapsed_us)) / 1_000_000.0;
            try self.stdout.print("compile time usage: {d:.6}s\n", .{compile_elapsed_s});
            try self.stdout.print("execute time usage: {d:.6}s\n", .{execute_elapsed_s});
            try self.stdout.print("bf memory allocated: {}\n", .{self.memory.len});
            try self.stdout.print("bf memory used: {}\n", .{self.size});

            self.alloc.free(tokens);
            simple_ast.deinit();
            semantic_ast.deinit();
        }

        fn executeSemanticASTEmptyLoop(self: *Self) !void {
            if (self.memory[self.ptr] == 0)
                return;
            return error.DeadLoop;
        }

        fn executeSemanticASTCountedLoop(self: *Self, ast: SemanticAST) !void {
            const body = ast.CountedLoop.body;
            @setRuntimeSafety(false);
            const flag_val = self.memory[self.ptr];
            if (flag_val == 0) return;
            const gcd = std.math.gcd(ast.CountedLoop.flag_step, @as(u16, 256));
            const c: u16 = (256 - @as(u16, @intCast(flag_val))) % 256;
            var loopCount: u8 = 0;
            if (c % gcd != 0) {
                return error.DeadLoop;
            } else {
                while (loopCount <= 255) : (loopCount += 1) {
                    if (flag_val +% (loopCount *% ast.CountedLoop.flag_step) == 0)
                        break;
                }
            }
            if (ast.CountedLoop.init.?) |init_op| {
                switch (init_op.*) {
                    .AddPtr => |offset| self.ptr = @intCast(@as(isize, @intCast(self.ptr)) + offset),
                    else => unreachable,
                }
            }
            for (0..loopCount) |_| {
                for (body.items) |child| {
                    switch (child) {
                        .AddPtr => |offset| self.ptr = @intCast(@as(isize, @intCast(self.ptr)) + offset),
                        .VecAdd =>
                        else => unreachable,
                    }
                }
            }
        }

        fn executeSemanticASTLoop(self: *Self, ast: SemanticAST) !void {
            const body = ast.Loop.body;
            @setRuntimeSafety(false);
            while (self.memory[self.ptr] != 0) {
                for (body.items) |child| {
                    switch (child) {
                        .Add => |data| self.memory[self.ptr] +%= data,
                        .AddPtr => |offset| self.ptr = @intCast(@as(isize, @intCast(self.ptr)) + offset),
                        .Read => |count| {
                            try self.stdin.skipBytes(count - 1, .{ .buf_size = 512 });
                            self.memory[self.ptr] = try self.stdin.readByte();
                        },
                        .Write => |count| try self.stdout.writeByteNTimes(self.memory[self.ptr], count),
                        .Loop => try self.executeSemanticASTLoop(child),
                        .CountedLoop => try self.executeSemanticASTCountedLoop(child),
                        .EmptyLoop => try self.executeSemanticASTEmptyLoop(),
                        .SetZero => self.memory[self.ptr] = 0,
                        .JumpToNextZero => |step| {
                            while (self.memory[self.ptr] != 0) {
                                self.ptr = @intCast(@as(isize, @intCast(self.ptr)) + step);
                            }
                        },
                        else => unreachable,
                    }
                }
            }
        }

        pub fn executeSemanticAST(self: *Self, ast: SemanticAST) !void {
            const body = ast.MainEntry.body;
            @setRuntimeSafety(false);
            for (body.items) |child| {
                switch (child) {
                    .Add => |data| self.memory[self.ptr] +%= data,
                    .AddPtr => |offset| self.ptr = @intCast(@as(isize, @intCast(self.ptr)) + offset),
                    .Read => |count| {
                        try self.stdin.skipBytes(count - 1, .{ .buf_size = 512 });
                        self.memory[self.ptr] = try self.stdin.readByte();
                    },
                    .Write => |count| try self.stdout.writeByteNTimes(self.memory[self.ptr], count),
                    .Loop => try self.executeSemanticASTLoop(child),
                    .CountedLoop => try self.executeSemanticASTCountedLoop(child),
                    .EmptyLoop => try self.executeSemanticASTEmptyLoop(),
                    .SetZero => self.memory[self.ptr] = 0,
                    .JumpToNextZero => |step| {
                        while (self.memory[self.ptr] != 0) {
                            self.ptr = @intCast(@as(isize, @intCast(self.ptr)) + step);
                        }
                    },
                    else => unreachable,
                }
            }
        }

        fn readAllFromFile(
            alloc: std.mem.Allocator,
            filepath: []const u8,
        ) ![]const u8 {
            const file = try std.fs.cwd().openFile(
                filepath,
                .{ .mode = .read_only },
            );
            defer file.close();
            return try file.reader().readAllAlloc(alloc, @import("std").math.maxInt(usize));
        }

        pub fn executeFile(self: *Self, bf_srcPath: []const u8) !void {
            const bf_source = try readAllFromFile(self.alloc, bf_srcPath);
            try self.executeString(bf_source);
            defer self.alloc.free(bf_source);
        }
    };
}
