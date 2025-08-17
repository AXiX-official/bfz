const std = @import("std");
const SimpleAst = @import("parser.zig").SimpleAst;
const SimpleAstType = @import("parser.zig").SimpleAstType;
const builtin = @import("builtin");
pub const VectorLen = std.simd.suggestVectorLength(u8) orelse {
    @compileError("Cannot determine optimal SIMD vector length for this CPU");
};
pub const HalfVectorLen = VectorLen / 2;
pub const DataVec = @Vector(VectorLen, u8);

pub const SemanticAstType = enum {
    MainEntry,
    Add,
    VecAdd,
    AddPtr,
    Read,
    Write,
    Loop,
    CountedLoop,
    /// []
    EmptyLoop,
    /// [+] or [-]
    SetZero,
    /// [<] or [>]
    JumpToNextZero,
};

/// strip debug info
pub const SemanticAST = union(SemanticAstType) {
    MainEntry: struct {
        body: std.ArrayList(SemanticAST),
    },
    Add: u8,
    VecAdd: DataVec,
    AddPtr: isize,
    Read: usize,
    Write: usize,
    Loop: struct {
        body: std.ArrayList(SemanticAST),
    },
    /// e.g. [+>-<]
    /// - `flag_step` = 1
    /// - mem[0] + `flag_step` * loop_count = 0
    CountedLoop: struct {
        body: std.ArrayList(SemanticAST),
        tail: std.ArrayList(SemanticAST),

        flag_step: u8 = 0,

        vecBegin: isize = 0,
        vecEnd: isize = 0,
    },
    EmptyLoop: void,
    SetZero: void,
    JumpToNextZero: isize,

    pub fn deinit(self: SemanticAST) void {
        switch (self) {
            .MainEntry => |entry| {
                for (entry.body.items) |node| {
                    node.deinit();
                }
                entry.body.deinit();
            },
            .Loop => |loop| {
                for (loop.body.items) |node| {
                    node.deinit();
                }
                loop.body.deinit();
            },
            .CountedLoop => |counted_loop| {
                for (counted_loop.body.items) |node| {
                    node.deinit();
                }
                counted_loop.body.deinit();
            },
            else => {},
        }
    }
};

// TODO: inculde `analyze_single_loop`
fn LoopAnalyzerGenic(comptime is_balanced: bool) type {
    return struct {
        pub fn Analyze(simple_ast: SimpleAst, alloc: std.mem.Allocator) !SemanticAST {
            const simple_node = &simple_ast.Loop;

            if (!is_balanced and simple_node.ptr_move_per_iteration.? == 0) {
                return analyze_single_pure_balanced_loop(simple_ast, alloc);
            }

            // No cell modifications or pointer movements - dead loop or empty loop
            if (!simple_node.has_add and !simple_node.has_addptr) {
                return .{ .EmptyLoop = {} };
            }

            // Only cell modifications (no pointer moves) - e.g. [+] or [-]
            if (simple_node.has_add and !simple_node.has_addptr) {
                var count: u8 = 0;
                // Calculate net cell modification
                for (simple_node.body.items) |child| {
                    switch (child.BasicOp.type) {
                        .Add => count +%= 1,
                        .Sub => count -%= 1,
                        else => {},
                    }
                }
                // If net modification ≠ 0, equivalent to setting cell to zero
                if (count != 0) return .{ .SetZero = {} };
                // Net modification = 0 → empty loop
                return .{ .EmptyLoop = {} };
            }

            // Only pointer movements (no cell modifications) - e.g. [>] or [<<]
            if (!simple_node.has_add and simple_node.has_addptr) {
                if (is_balanced) {
                    return .{ .EmptyLoop = {} };
                } else {
                    // If pointer moves each iteration, jump to next zero cell
                    return .{ .JumpToNextZero = @intCast(simple_node.ptr_move_per_iteration.?) };
                }
            }

            // Mixed operations (both cell mods and pointer moves) - requires complex analysis

            var root =
                if (is_balanced)
                    SemanticAST{ .CountedLoop = .{ .body = std.ArrayList(SemanticAST).init(alloc), .tail = std.ArrayList(SemanticAST).init(alloc) } }
                else
                    SemanticAST{ .Loop = .{ .body = std.ArrayList(SemanticAST).init(alloc) } };
            errdefer root.deinit();
            var node =
                if (is_balanced)
                    &root.CountedLoop
                else
                    &root.Loop;
            var body = &node.body;
            // Simulate loop execution to track memory changes
            const memory_range: usize = @intCast(simple_node.max_ptr - simple_node.min_ptr + 1);
            const loop_memory = try alloc.alloc(u8, memory_range);
            errdefer alloc.free(loop_memory);
            @memset(loop_memory, 0);
            var ptr: usize = @intCast(-simple_node.min_ptr);
            for (simple_node.body.items) |child| {
                switch (child.BasicOp.type) {
                    .Add => loop_memory[ptr] +%= 1,
                    .Sub => loop_memory[ptr] -%= 1,
                    .AddPtr => ptr += 1,
                    .SubPtr => ptr -= 1,
                    // By function contract, no I/O ops
                    .Write, .Read => unreachable,
                }
            }
            if (is_balanced) node.flag_step = loop_memory[ptr];
            // Count leading zero cells (unchanged memory)
            const leading_zero_count = lzc_blk: {
                for (loop_memory, 0..) |mem, i| {
                    if (mem != 0) {
                        break :lzc_blk i;
                    }
                }
                break :lzc_blk memory_range;
            };
            // All cells unchanged → empty loop
            if (leading_zero_count == memory_range) {
                root.deinit();
                alloc.free(loop_memory);
                return .{ .EmptyLoop = {} };
            }
            // Count trailing zero cells (unchanged memory)
            const trailing_zero_count = tzc_blk: {
                for (0..memory_range) |i| {
                    if (loop_memory[memory_range - i - 1] != 0) {
                        break :tzc_blk i;
                    }
                }
                break :tzc_blk loop_memory.len;
            };
            // Calculate actual affected memory range
            const min_ptr: isize = simple_node.min_ptr + @as(isize, @intCast(leading_zero_count));
            const max_ptr: isize = simple_node.max_ptr - @as(isize, @intCast(trailing_zero_count));
            // Handle small memory ranges (< HalfVectorLen)
            if (!is_balanced or max_ptr - min_ptr < HalfVectorLen) {
                ptr = 0;
                for (loop_memory[leading_zero_count..(memory_range - trailing_zero_count)], 0..) |mem, i| {
                    if (mem != 0) {
                        const offset: isize = @as(isize, @intCast(i - ptr)) + min_ptr;
                        ptr = @intCast(@as(isize, @intCast(i)) + min_ptr);
                        if (offset != 0) {
                            try body.append(.{ .AddPtr = offset });
                        }
                        try body.append(.{ .Add = mem });
                    }
                }
                const offset = simple_node.ptr_move_per_iteration.? - @as(isize, @intCast(ptr));
                if (offset != 0) {
                    try body.append(.{ .AddPtr = offset });
                }
            } else {
                // Handle large memory ranges (using vectorization)
                ptr = 0;
                var temp_memory = try alloc.alloc(u8, VectorLen);
                defer alloc.free(temp_memory);
                var start_index = leading_zero_count;

                node.vecBegin = @as(isize, @intCast(start_index)) + simple_node.min_ptr;

                while (memory_range - trailing_zero_count - start_index > VectorLen) : (start_index += VectorLen) {
                    const offset: isize = @as(isize, @intCast(start_index - ptr)) + min_ptr;
                    ptr = @intCast(@as(isize, @intCast(start_index)) + min_ptr);
                    if (offset != 0) {
                        try body.append(.{ .AddPtr = offset });
                    }
                    @memset(temp_memory, 0);
                    @memcpy(temp_memory, loop_memory[start_index..(start_index + VectorLen)]);
                    try body.append(.{ .VecAdd = temp_memory[0..VectorLen].* });
                }

                node.vecEnd = @as(isize, @intCast(start_index)) + simple_node.min_ptr;

                ptr = @intCast(-simple_node.min_ptr);
                if (node.vecEnd != 0) {
                    try body.append(.{ .AddPtr = node.vecEnd });
                }
                for (loop_memory[start_index..(memory_range - trailing_zero_count)], 0..) |mem, i| {
                    if (mem != 0) {
                        const offset: isize = @intCast(i + start_index - ptr);
                        ptr = i + start_index;
                        if (offset != 0) {
                            try body.append(.{ .AddPtr = offset });
                        }
                        try body.append(.{ .Add = mem });
                    }
                }

                const offset: isize = -simple_node.min_ptr - @as(isize, @intCast(ptr));
                if (offset != 0) {
                    try body.append(.{ .AddPtr = offset });
                }
            }

            alloc.free(loop_memory);

            return root;
        }
    };
}

const analyze_single_pure_balanced_loop = LoopAnalyzerGenic(true).Analyze;
const analyze_single_pure_loop = LoopAnalyzerGenic(false).Analyze;

/// Analyzes a single loop structure without sub-loops
fn analyze_single_loop(simple_ast: SimpleAst, alloc: std.mem.Allocator) !SemanticAST {
    const simple_node = &simple_ast.Loop;

    if (!simple_node.has_io) return analyze_single_pure_loop(simple_ast, alloc);

    if (!simple_node.has_addptr) {
        var root = SemanticAST{ .Loop = .{ .body = std.ArrayList(SemanticAST).init(alloc) } };
        errdefer root.deinit();

        var node = &root.Loop;
        var body = &node.body;

        var index: usize = 0;
        const simple_body = simple_node.body.items;
        while (index < simple_body.len) : (index += 1) {
            const op = simple_body[index].BasicOp;
            switch (op.type) {
                .Add, .Sub => {
                    var addCount: usize = 0;
                    var subCount: usize = 0;
                    while (index + 1 < simple_body.len) : (index += 1) {
                        switch (simple_body[index].BasicOp.type) {
                            .Add => addCount += 1,
                            .Sub => subCount += 1,
                            else => break,
                        }
                    }
                    index -= 1;
                    const diff = @mod(addCount -% subCount, 256);
                    if (diff != 0) {
                        try body.append(.{ .Add = @truncate(diff) });
                    }
                },
                inline .Read, .Write => {
                    const start = index;
                    while (index + 1 < simple_body.len and simple_body[index + 1].BasicOp.type == op.type) : (index += 1) {}
                    switch (op.type) {
                        .Read => try body.append(.{ .Read = index - start + 1 }),
                        .Write => try body.append(.{ .Write = index - start + 1 }),
                        else => unreachable,
                    }
                },
                else => unreachable,
            }
        }
        return root;
    }

    const memory_range: usize = @intCast(simple_node.max_ptr - simple_node.min_ptr + 1);
    const loop_memory = try alloc.alloc(u8, memory_range);
    errdefer alloc.free(loop_memory);
    @memset(loop_memory, 0);

    const dirty_flag = try alloc.alloc(bool, memory_range);
    errdefer alloc.free(dirty_flag);
    @memset(dirty_flag, false);

    // reserved iter, lazy io
    var ptr: usize = @intCast(simple_node.ptr_move_per_iteration.? - simple_node.min_ptr);

    var temp_reserved_body = std.ArrayList(SemanticAST).init(alloc);
    var temp_reserved_ptr = std.ArrayList(usize).init(alloc);

    const children = simple_node.body.items;
    var index: usize = children.len - 1;
    var can_be_counted_loop = (simple_node.ptr_move_per_iteration.? == 0);
    while (index >= 0) : (index -= 1) {
        const op = children[index].BasicOp;
        switch (op.type) {
            .Add => {
                loop_memory[ptr] +%= 1;
                dirty_flag[ptr] = true;
            },
            .Sub => {
                loop_memory[ptr] -%= 1;
                dirty_flag[ptr] = true;
            },
            // reserved iter
            .AddPtr => ptr -= 1,
            // reserved iter
            .SubPtr => ptr += 1,
            inline .Read, .Write => {
                if (ptr == @as(usize, @intCast(simple_node.ptr_move_per_iteration.? - simple_node.min_ptr))) {
                    can_be_counted_loop = false;
                }
                if (dirty_flag[ptr]) {
                    try temp_reserved_body.append(.{ .Add = loop_memory[ptr] });
                    try temp_reserved_ptr.append(ptr);
                    loop_memory[ptr] = 0;
                    dirty_flag[ptr] = false;
                }
                const start = index;
                while (index > 0 and children[index - 1].BasicOp.type == op.type) : (index -= 1) {}
                switch (op.type) {
                    .Read => {
                        try temp_reserved_body.append(.{ .Read = start - index + 1 });
                        try temp_reserved_ptr.append(ptr);
                    },
                    .Write => {
                        try temp_reserved_body.append(.{ .Write = start - index + 1 });
                        try temp_reserved_ptr.append(ptr);
                    },
                    else => unreachable,
                }
            },
        }
    }

    // Count leading zero cells (unchanged memory)
    const leading_zero_count = lzc_blk: {
        for (loop_memory, 0..) |mem, i| {
            if (mem != 0) {
                break :lzc_blk i;
            }
        }
        break :lzc_blk memory_range;
    };
    // All cells unchanged → empty loop
    if (leading_zero_count == memory_range) {
        return .{ .EmptyLoop = {} };
    }
    // Count trailing zero cells (unchanged memory)
    const trailing_zero_count = tzc_blk: {
        for (0..memory_range) |i| {
            if (loop_memory[memory_range - i - 1] != 0) {
                break :tzc_blk i;
            }
        }
        break :tzc_blk loop_memory.len;
    };
    // Calculate actual affected memory range
    const min_ptr: isize = simple_node.min_ptr + @as(isize, @intCast(leading_zero_count));
    const max_ptr: isize = simple_node.max_ptr - @as(isize, @intCast(trailing_zero_count));

    if (can_be_counted_loop) {
        var root = SemanticAST{ .CountedLoop = .{ .body = std.ArrayList(SemanticAST).init(alloc) } };
        errdefer root.deinit();
        var node = &root.CountedLoop;
        var body = &node.body;

        node.flag_step = loop_memory[@intCast(simple_node.ptr_move_per_iteration.? - simple_node.min_ptr)];

        // Handle small memory ranges (< HalfVectorLen)
        if (max_ptr - min_ptr < HalfVectorLen) {
            ptr = 0;
            for (loop_memory[leading_zero_count..(memory_range - trailing_zero_count)], 0..) |mem, i| {
                if (mem != 0) {
                    const offset: isize = @as(isize, @intCast(i - ptr)) + min_ptr;
                    ptr = @intCast(@as(isize, @intCast(i)) + min_ptr);
                    if (offset != 0) {
                        var offset_op = SemanticAST{ .AddPtr = offset };
                        if (node.init == null) {
                            node.init = &offset_op;
                        } else {
                            try body.append(offset_op);
                        }
                    }
                    try body.append(.{ .Add = mem });
                }
            }
            const offset = simple_node.ptr_move_per_iteration.? - @as(isize, @intCast(ptr));
            if (offset != 0) {
                var post_op = SemanticAST{ .AddPtr = offset };
                node.post = &post_op;
            }
        } else {
            // Handle large memory ranges (using vectorization)
            ptr = 0;
            var temp_memory = try alloc.alloc(u8, VectorLen);
            defer alloc.free(temp_memory);
            var start_index = leading_zero_count;

            while (memory_range - trailing_zero_count - start_index > VectorLen) : (start_index += VectorLen) {
                const offset: isize = @as(isize, @intCast(start_index - ptr)) + min_ptr;
                ptr = @intCast(@as(isize, @intCast(start_index)) + min_ptr);
                if (offset != 0) {
                    var offset_op = SemanticAST{ .AddPtr = offset };
                    if (node.init == null) {
                        node.init = &offset_op;
                    } else {
                        try body.append(offset_op);
                    }
                }
                @memset(temp_memory, 0);
                @memcpy(temp_memory, loop_memory[start_index..(start_index + VectorLen)]);
                try body.append(.{ .VecAdd = temp_memory[0..VectorLen].* });
            }

            var offset: isize = @as(isize, @intCast(start_index - ptr)) + min_ptr;
            ptr = @intCast(@as(isize, @intCast(start_index)) + min_ptr);
            if (offset != 0) {
                try body.append(.{ .AddPtr = offset });
            }
            @memset(temp_memory, 0);
            for (loop_memory[start_index..(memory_range - trailing_zero_count)], temp_memory[0..(memory_range - trailing_zero_count - start_index)]) |mem, *tmp_mem| {
                tmp_mem.* = mem;
            }
            try body.append(.{ .VecAdd = temp_memory[0..VectorLen].* });

            offset = simple_node.ptr_move_per_iteration.? - @as(isize, @intCast(ptr));
            if (offset != 0) {
                var post_op = SemanticAST{ .AddPtr = offset };
                node.post = &post_op;
            }
        }

        if (temp_reserved_body.items.len > 0) {
            var reserved_index = temp_reserved_body.items.len - 1;
            while (reserved_index >= 0) : (reserved_index -= 1) {
                const offset: isize = @intCast(temp_reserved_ptr.items[reserved_index] - ptr);
                ptr = temp_reserved_ptr.items[reserved_index];
                if (offset != 0) {
                    try body.append(.{ .AddPtr = offset });
                }
                try body.append(temp_reserved_body.items[reserved_index]);
            }
        }

        return root;
    }

    var root = SemanticAST{ .Loop = .{ .body = std.ArrayList(SemanticAST).init(alloc) } };
    errdefer root.deinit();

    var node = &root.Loop;
    var body = &node.body;

    ptr = 0;
    for (loop_memory[leading_zero_count..(memory_range - trailing_zero_count)], 0..) |mem, i| {
        if (mem != 0) {
            const offset: isize = @as(isize, @intCast(i - ptr)) + min_ptr;
            ptr = @intCast(@as(isize, @intCast(i)) + min_ptr);
            if (offset != 0) {
                try body.append(.{ .AddPtr = offset });
            }
            try body.append(.{ .Add = mem });
        }
    }

    if (temp_reserved_body.items.len > 0) {
        var reserved_index = temp_reserved_body.items.len - 1;
        while (reserved_index >= 0) : (reserved_index -= 1) {
            const offset: isize = @intCast(temp_reserved_ptr.items[reserved_index] - ptr);
            ptr = temp_reserved_ptr.items[reserved_index];
            if (offset != 0) {
                try body.append(.{ .AddPtr = offset });
            }
            try body.append(temp_reserved_body.items[reserved_index]);
        }
    }

    const offset = simple_node.ptr_move_per_iteration.? - @as(isize, @intCast(ptr));
    if (offset != 0) {
        try body.append(.{ .AddPtr = offset });
    }

    alloc.free(loop_memory);
    alloc.free(dirty_flag);

    return root;
}

fn analyze_basiceop(comptime T: type, simple_node: *const T, children: []SimpleAst, alloc: std.mem.Allocator) ![]SemanticAST {
    const memory_range: usize = @intCast(simple_node.max_ptr - simple_node.min_ptr + 1);
    const loop_memory = try alloc.alloc(u8, memory_range);
    errdefer alloc.free(loop_memory);
    @memset(loop_memory, 0);

    const dirty_flag = try alloc.alloc(bool, memory_range);
    errdefer alloc.free(dirty_flag);
    @memset(dirty_flag, false);

    var ptr: usize = 0;
    var ptr_move_per_iteration: isize = 0;

    if (simple_node.ptr_move_per_iteration) |ptr_move_per_iteration_val| {
        ptr = @intCast(ptr_move_per_iteration_val - simple_node.min_ptr);
        ptr_move_per_iteration = ptr_move_per_iteration_val;
    } else {
        ptr = @intCast(-simple_node.min_ptr);
        for (children) |child_op| {
            switch (child_op.BasicOp.type) {
                .AddPtr => ptr += 1,
                .SubPtr => ptr -= 1,
                else => {},
            }
        }
        ptr_move_per_iteration = @as(isize, @intCast(ptr)) + simple_node.min_ptr;
    }

    var temp_reserved_body = std.ArrayList(SemanticAST).init(alloc);
    var temp_reserved_ptr = std.ArrayList(usize).init(alloc);

    var index = children.len;
    while (index > 0) : (index -= 1) {
        const op = children[index - 1].BasicOp;
        switch (op.type) {
            .Add => {
                loop_memory[ptr] +%= 1;
                dirty_flag[ptr] = true;
            },
            .Sub => {
                loop_memory[ptr] -%= 1;
                dirty_flag[ptr] = true;
            },
            // reserved iter
            .AddPtr => ptr -= 1,
            // reserved iter
            .SubPtr => ptr += 1,
            inline .Read, .Write => {
                if (dirty_flag[ptr]) {
                    try temp_reserved_body.append(.{ .Add = loop_memory[ptr] });
                    try temp_reserved_ptr.append(ptr);
                    loop_memory[ptr] = 0;
                    dirty_flag[ptr] = false;
                }
                const start = index;
                while (index > 0 and children[index - 1].BasicOp.type == op.type) : (index -= 1) {}
                switch (op.type) {
                    .Read => {
                        try temp_reserved_body.append(.{ .Read = start - index });
                        try temp_reserved_ptr.append(ptr);
                    },
                    .Write => {
                        try temp_reserved_body.append(.{ .Write = start - index });
                        try temp_reserved_ptr.append(ptr);
                    },
                    else => unreachable,
                }
            },
        }
    }

    var body = std.ArrayList(SemanticAST).init(alloc);
    errdefer body.deinit();

    // Count leading zero cells (unchanged memory)
    const leading_zero_count = lzc_blk: {
        for (loop_memory, 0..) |mem, i| {
            if (mem != 0) {
                break :lzc_blk i;
            }
        }
        break :lzc_blk memory_range;
    };
    if (leading_zero_count == memory_range) {
        alloc.free(loop_memory);
        alloc.free(dirty_flag);
        return body.toOwnedSlice();
    }
    // Count trailing zero cells (unchanged memory)
    const trailing_zero_count = tzc_blk: {
        for (0..memory_range) |i| {
            if (loop_memory[memory_range - i - 1] != 0) {
                break :tzc_blk i;
            }
        }
        break :tzc_blk loop_memory.len;
    };
    // Calculate actual affected memory range
    const min_ptr: isize = simple_node.min_ptr + @as(isize, @intCast(leading_zero_count));

    ptr = 0;

    for (loop_memory[leading_zero_count..(memory_range - trailing_zero_count)], 0..) |mem, i| {
        if (mem != 0) {
            const offset: isize = @as(isize, @intCast(i - ptr)) + min_ptr;
            ptr = @intCast(@as(isize, @intCast(i)) + min_ptr);
            if (offset != 0) {
                try body.append(.{ .AddPtr = offset });
            }
            try body.append(.{ .Add = mem });
        }
    }

    if (temp_reserved_body.items.len > 0) {
        var reserved_index = temp_reserved_body.items.len - 1;
        while (reserved_index >= 0) : (reserved_index -= 1) {
            const offset: isize = @intCast(temp_reserved_ptr.items[reserved_index] - ptr);
            ptr = temp_reserved_ptr.items[reserved_index];
            if (offset != 0) {
                try body.append(.{ .AddPtr = offset });
            }
            try body.append(temp_reserved_body.items[reserved_index]);
        }
    }

    const offset = ptr_move_per_iteration - @as(isize, @intCast(ptr));
    if (offset != 0) {
        try body.append(.{ .AddPtr = offset });
    }

    alloc.free(loop_memory);
    alloc.free(dirty_flag);

    return body.toOwnedSlice();
}

fn analyze_loop(simple_ast: SimpleAst, alloc: std.mem.Allocator) !SemanticAST {
    const simple_node = &simple_ast.Loop;

    var root = SemanticAST{ .Loop = .{ .body = std.ArrayList(SemanticAST).init(alloc) } };
    errdefer root.deinit();

    var node = &root.Loop;
    var body = &node.body;

    var index: usize = 0;
    var start: usize = 0;
    const children = simple_node.body.items;
    while (index < children.len) : (index += 1) {
        const child = children[index];
        switch (child) {
            .Loop => |loop_node| {
                const basicops = try analyze_basiceop(@TypeOf(simple_ast.Loop), simple_node, children[start..index], alloc);
                errdefer alloc.free(basicops);
                try body.appendSlice(basicops);
                alloc.free(basicops);

                if (loop_node.has_nested_loops) {
                    try body.append(try analyze_loop(child, alloc));
                } else {
                    try body.append(try analyze_single_loop(child, alloc));
                }

                start = index + 1;
            },
            else => {},
        }
    }
    const basicops = try analyze_basiceop(@TypeOf(simple_ast.Loop), simple_node, children[start..index], alloc);
    errdefer alloc.free(basicops);
    try body.appendSlice(basicops);
    alloc.free(basicops);

    return root;
}

fn analyze(simple_ast: SimpleAst, alloc: std.mem.Allocator) !SemanticAST {
    const simple_node = &simple_ast.MainEntry;

    var root = SemanticAST{ .MainEntry = .{ .body = std.ArrayList(SemanticAST).init(alloc) } };
    errdefer root.deinit();

    var node = &root.MainEntry;
    var body = &node.body;

    var index: usize = 0;
    var start: usize = 0;
    const children = simple_node.body.items;
    while (index < children.len) : (index += 1) {
        const child = children[index];
        switch (child) {
            .Loop => |loop_node| {
                const basicops = try analyze_basiceop(@TypeOf(simple_ast.MainEntry), simple_node, children[start..index], alloc);
                errdefer alloc.free(basicops);
                try body.appendSlice(basicops);
                alloc.free(basicops);

                if (loop_node.has_nested_loops) {
                    try body.append(try analyze_loop(child, alloc));
                } else {
                    try body.append(try analyze_single_loop(child, alloc));
                }

                start = index + 1;
            },
            else => {},
        }
    }
    const basicops = try analyze_basiceop(@TypeOf(simple_ast.MainEntry), simple_node, children[start..index], alloc);
    errdefer alloc.free(basicops);
    try body.appendSlice(basicops);
    alloc.free(basicops);

    return root;
}

test "analyze single loop" {
    const lex = @import("lexer.zig").lex;
    const SrcLocation = @import("lexer.zig").SrcLocation;
    const Parse = @import("parser.zig").Parse;
    const alloc = std.testing.allocator;

    const test_program = "[-][+-+][<][+>+<->-<][+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+>+]";
    const test_tokens = try lex(test_program, alloc);
    defer alloc.free(test_tokens);
    var errorLoc: ?SrcLocation = null;
    const ret = try Parse(test_tokens, alloc, &errorLoc);
    defer ret.deinit();

    const main = try analyze(ret, alloc);

    const loop1 = main.MainEntry.body.items[0];
    const loop2 = main.MainEntry.body.items[1];
    const loop3 = main.MainEntry.body.items[2];
    const loop4 = main.MainEntry.body.items[3];
    const loop5 = main.MainEntry.body.items[4];

    try std.testing.expectEqual(SemanticAST{ .SetZero = {} }, loop1);
    try std.testing.expectEqual(SemanticAST{ .SetZero = {} }, loop2);
    try std.testing.expectEqual(SemanticAST{ .JumpToNextZero = -1 }, loop3);
    try std.testing.expectEqual(SemanticAST{ .EmptyLoop = {} }, loop4);
    std.debug.print("{}\n", .{loop5.Loop.body});
    //try std.testing.expect(loop5.Loop.body.items[0] == .VecAdd);
    //try std.testing.expect(loop5.Loop.body.items[1] == .AddPtr);

    defer main.deinit();
}
