const std = @import("std");
const Optimize = @import("optimize.zig");
const Op = @import("opcode.zig").Op;
const Opcode = @import("opcode.zig").Opcode;

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
            try self.stdout.print("compile time usage: {d:.6}s\n", .{compile_elapsed_s});
            try self.stdout.print("execute time usage: {d:.6}s\n", .{execute_elapsed_s});
            try self.stdout.print("bf memory allocated: {}\n", .{self.memory.len});
            try self.stdout.print("bf memory used: {}\n", .{self.size});
        }

        pub fn executeOpCodes(self: *Self, codes: []const Opcode) !void {
            var codePtr: usize = 0;
            var ptr = self.ptr;
            @setRuntimeSafety(false);
            while (codePtr < codes.len) : (codePtr += 1) {
                const code = codes[codePtr];
                switch (code.op) {
                    inline .add, .sub => {
                        const delta = if (code.op == .add) code.data else -%code.data;
                        self.memory[ptr] +%= @as(u8, @truncate(delta));
                    },
                    .addp => {
                        ptr += code.data;
                        if (ptr >= self.limit) return error.MemoryOutOfLimit;
                        if (ptr >= self.memory.len) {
                            const new_size = if (ptr + 1 > self.memory.len * 2) ptr + 1 else self.memory.len * 2;
                            const new_mem = try self.alloc.alloc(u8, new_size);
                            @memset(new_mem, 0);
                            @memcpy(new_mem[0..self.memory.len], self.memory);
                            self.alloc.free(self.memory);
                            self.memory = new_mem;
                        }
                        self.size = @max(self.size, ptr);
                    },
                    .subp => ptr = try std.math.sub(usize, ptr, code.data),
                    .jz => {
                        codePtr += if (self.memory[ptr] == 0) code.data else 0;
                    },
                    .jnz => {
                        codePtr = if (self.memory[ptr] != 0) try std.math.sub(usize, codePtr, code.data) else codePtr;
                    },
                    .in => {
                        try self.stdin.skipBytes(code.data - 1, .{ .buf_size = 512 });
                        self.memory[ptr] = try self.stdin.readByte();
                    },
                    .out => {
                        try self.stdout.writeByteNTimes(self.memory[ptr], code.data);
                    },
                    .nop => {},
                    .set => {
                        self.memory[ptr] = @as(u8, @truncate(code.data));
                    },
                    else => unreachable,
                }
            }
            self.ptr = ptr;
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
