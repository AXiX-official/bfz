const std = @import("std");
const Memory = @import("memory.zig").Memory;
const Optimize = @import("optimize.zig");
const Op = @import("opcode.zig").Op;
const Opcode = @import("opcode.zig").Opcode;

pub fn BFVM(comptime writer: type, comptime reader: type) type {
    return struct {
        const Self = @This();

        memory: Memory(u8, 512),
        ptr: i64,
        alloc: std.mem.Allocator,
        stdout: writer,
        stdin: reader,

        pub fn init(alloc: std.mem.Allocator, limit: usize, in: reader, out: writer) !Self {
            return Self{ .memory = try Memory(u8, 512).init(alloc, 0, limit), .ptr = 0, .alloc = alloc, .stdin = in, .stdout = out };
        }

        pub fn deinit(self: Self) void {
            self.memory.deinit();
        }

        pub fn executeString(self: *Self, bf_source: []const u8) !void {
            const compileBegin = std.time.microTimestamp();

            const opcodes = try Optimize.optimize(bf_source, self.alloc);
            defer self.alloc.free(opcodes);

            const compileEnd = std.time.microTimestamp();
            const compile_elapsed_us = compileEnd - compileBegin;
            const compile_elapsed_s = @as(f64, @floatFromInt(compile_elapsed_us)) / 1_000_000.0;

            const executeBegin = std.time.microTimestamp();

            try self.executeOpCodes(opcodes);

            const executeEnd = std.time.microTimestamp();
            const execute_elapsed_us = executeEnd - executeBegin;
            const execute_elapsed_s = @as(f64, @floatFromInt(execute_elapsed_us)) / 1_000_000.0;
            try self.stdout.print("compile time usage: {d:.6}s", .{compile_elapsed_s});
            try self.stdout.print("execute time usage: {d:.6}s", .{execute_elapsed_s});
        }

        fn getMemory(self: *Self) !*u8 {
            return self.memory.getItem(self.ptr);
        }

        pub fn executeOpCodes(self: *Self, codes: []const Opcode) !void {
            var codePtr: usize = 0;
            while (codePtr < codes.len) {
                const code = codes[codePtr];
                switch (code.op) {
                    .add => {
                        const mem = try self.getMemory();
                        mem.* +%= @as(u8, @intCast(code.data));
                    },
                    .sub => {
                        const mem = try self.getMemory();
                        mem.* -%= @as(u8, @intCast(code.data));
                    },
                    .addp => self.ptr += @as(i64, @intCast(code.data)),
                    .subp => self.ptr -= @as(i64, @intCast(code.data)),
                    .jz => {
                        const mem = try self.getMemory();
                        codePtr += if (mem.* == 0) code.data else 0;
                    },
                    .jnz => {
                        const mem = try self.getMemory();
                        codePtr -= if (mem.* != 0) code.data else 0;
                    },
                    .in => for (0..code.data) |_| {
                        const mem = try self.getMemory();
                        mem.* = try self.stdin.readByte();
                    },
                    .out => for (0..code.data) |_| {
                        const mem = try self.getMemory();
                        try self.stdout.writeByte(mem.*);
                    },
                    .nop => {},
                    .set => {
                        const mem = try self.getMemory();
                        mem.* = @as(u8, @intCast(code.data));
                    },
                    else => unreachable,
                }
                codePtr += 1;
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
