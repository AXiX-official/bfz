const std = @import("std");
const Op = @import("opcode.zig").Op;
const Opcode = @import("opcode.zig").Opcode;
const Node = @import("node.zig").Node;

const OpNode = Node(Opcode);

/// Check if the `[` and `]` brackets are properly balanced.
/// Only need check once before any optimize.
fn loopCheck(bf_source: []const u8) bool {
    var count: i64 = 0;
    for (bf_source) |ch| {
        switch (ch) {
            '[' => count += 1,
            ']' => count -= 1,
            else => continue,
        }
        if (count < 0) return false;
    }
    return count == 0;
}

/// Combine instructions Except `[` , `]` , `>` and `<`
/// for later optimization.
/// the `.data` in `jz/jnz` is incorrect.
fn combineInstructionsFromSrcExceptPtr(bf_source: []const u8, alloc: std.mem.Allocator) ![]const Opcode {
    const srcLen = bf_source.len;

    var codes = std.ArrayList(Opcode).init(alloc);
    errdefer codes.deinit();

    var i: usize = 0;
    while (i < srcLen) : (i += 1) {
        switch (bf_source[i]) {
            '+', '-' => {
                var addCount: usize = 0;
                var subCount: usize = 0;
                while (i < srcLen) : (i += 1) {
                    switch (bf_source[i]) {
                        '+' => addCount += 1,
                        '-' => subCount += 1,
                        else => break,
                    }
                }
                i -= 1;
                if (addCount > subCount) {
                    try codes.append(.{ .add = @as(u8, @truncate(addCount - subCount)) });
                } else if (addCount < subCount) {
                    try codes.append(.{ .sub = @as(u8, @truncate(subCount - addCount)) });
                }
            },
            '>' => {
                try codes.append(.{ .addp = 1 });
            },
            '<' => {
                try codes.append(.{ .subp = 1 });
            },
            inline ',', '.' => |c| {
                const start = i;
                while (i + 1 < srcLen and bf_source[i + 1] == c) : (i += 1) {}
                switch (c) {
                    ',' => try codes.append(.{ .in = i - start + 1 }),
                    '.' => try codes.append(.{ .out = i - start + 1 }),
                    else => unreachable,
                }
            },
            '[' => {
                try codes.append(.{ .jz = 0 });
            },
            ']' => {
                try codes.append(.{ .jnz = 0 });
            },
            else => {},
        }
    }

    return codes.toOwnedSlice();
}

/// Combine instructions Except `[` and `]`
/// for later optimization.
/// the `.data` in `jz/jnz` is incorrect.
fn combineInstructionsFromOpCodes(codes: []const Opcode, alloc: std.mem.Allocator) ![]const Opcode {
    const codesLen = codes.len;

    var outCodes = std.ArrayList(Opcode).init(alloc);
    errdefer outCodes.deinit();

    var i: usize = 0;
    while (i < codesLen) {
        switch (codes[i]) {
            .add, .sub => {
                var addCount: usize = 0;
                var subCount: usize = 0;
                while (i < codesLen) : (i += 1) {
                    switch (codes[i]) {
                        .add => |data| addCount += data,
                        .sub => |data| subCount += data,
                        else => break,
                    }
                }
                if (addCount > subCount) {
                    try outCodes.append(.{ .add = @as(u8, @truncate(addCount - subCount)) });
                } else if (addCount < subCount) {
                    try outCodes.append(.{ .sub = @as(u8, @truncate(subCount - addCount)) });
                }
            },
            .addp, .subp => {
                var addpCount: usize = 0;
                var subpCount: usize = 0;
                while (i < codesLen) : (i += 1) {
                    switch (codes[i]) {
                        .addp => |data| addpCount += data,
                        .subp => |data| subpCount += data,
                        else => break,
                    }
                }
                if (addpCount > subpCount) {
                    try outCodes.append(.{ .addp = addpCount - subpCount });
                } else if (addpCount < subpCount) {
                    try outCodes.append(.{ .subp = subpCount - addpCount });
                }
            },
            .in => {
                var count: usize = 0;
                while (i < codesLen) : (i += 1) {
                    switch (codes[i]) {
                        .in => |data| count += data,
                        else => break,
                    }
                }
                try outCodes.append(.{ .in = count });
            },
            .out => {
                var count: usize = 0;
                while (i < codesLen) : (i += 1) {
                    switch (codes[i]) {
                        .out => |data| count += data,
                        else => break,
                    }
                }
                try outCodes.append(.{ .out = count });
            },
            .jz => {
                try outCodes.append(codes[i]);
                i += 1;
            },
            .jnz => {
                try outCodes.append(codes[i]);
                i += 1;
            },
            else => i += 1,
        }
    }

    return outCodes.toOwnedSlice();
}

/// Code reordering
/// Never reorder across `[` or `]` (treat as boundaries)
/// the `.data` in `jz/jnz` is incorrect.
fn opcodeReordering(codes: []const Opcode, alloc: std.mem.Allocator) ![]const Opcode {
    const codesLen = codes.len;

    var opnodes = try alloc.alloc(OpNode, codesLen + 1);
    defer alloc.free(opnodes);
    opnodes[codesLen] = .{ .data = .{ .nop = {} }, .next = &opnodes[0] };
    for (0..codesLen) |i| {
        opnodes[i] = .{ .data = codes[i], .next = &opnodes[i + 1] };
    }

    var prev = &opnodes[codesLen];
    var left = opnodes[codesLen].next;
    var hasIO: bool = false;
    var ioNode = &opnodes[codesLen];
    while (left != &opnodes[codesLen]) {
        var right = left;
        while (right != &opnodes[codesLen] and
            right.data != .jz and right.data != .jnz and
            !(hasIO and !(right.data != .in and right.data != .out)))
        {
            if (right != left and (right.data == .in or right.data == .out)) {
                hasIO = true;
            }
            right = right.next;
        }

        if (right != left.next) {
            var current = left;
            while (current != right) {
                if (hasIO and (current.data == .in or current.data == .out)) {
                    ioNode = current;
                }

                if (current.data == .addp or current.data == .subp) {
                    var balance: i64 = if (current.data == .addp) 1 else -1;
                    var scan = current.next;

                    while (scan != right) {
                        if (scan.data == .addp) {
                            balance += 1;
                        } else if (scan.data == .subp) {
                            balance -= 1;
                        }

                        if (balance == 0) {
                            const opsBegin = scan.next;
                            var opsEnd = scan;
                            while (opsEnd.next != right and
                                (opsEnd.next.data == .add or
                                    opsEnd.next.data == .sub or
                                    opsEnd.next.data == .in or
                                    opsEnd.next.data == .out))
                            {
                                opsEnd = opsEnd.next;
                            }
                            if (opsBegin != opsEnd.next) {
                                const after = opsEnd.next;
                                prev.next = opsBegin;
                                prev = opsEnd;
                                opsEnd.next = current;
                                scan.next = after;
                            }
                        }

                        scan = scan.next;
                    }
                }

                prev = current;
                current = current.next;
            }
        }

        if (hasIO) {
            prev = ioNode;
            left = ioNode.next;
            hasIO = false;
        } else {
            prev = right;
            left = if (right == &opnodes[codesLen]) right else right.next;
        }
    }

    var reordered = try alloc.alloc(Opcode, codesLen);
    var node = opnodes[codesLen].next;
    var index: usize = 0;
    while (node != &opnodes[codesLen]) {
        reordered[index] = node.data;
        node = node.next;
        index += 1;
    }

    return reordered;
}

/// Code reordering
/// Never reorder across `[` or `]` (treat as boundaries)
/// the jz/jnz address in output is not correct
fn codeReordering(bf_source: []const u8, alloc: std.mem.Allocator) ![]const Opcode {
    const combinedCodes = try combineInstructionsFromSrcExceptPtr(bf_source, alloc);
    defer alloc.free(combinedCodes);
    return opcodeReordering(combinedCodes, alloc);
}

pub fn opcodesToSource(codes: []const Opcode, alloc: std.mem.Allocator) ![]const u8 {
    var src = std.ArrayList(u8).init(alloc);
    errdefer src.deinit();

    for (codes) |c| {
        switch (c) {
            .add => |data| {
                for (0..data) |_| {
                    try src.append('+');
                }
            },
            .sub => |data| {
                for (0..data) |_| {
                    try src.append('-');
                }
            },
            .addp => |data| {
                for (0..data) |_| {
                    try src.append('>');
                }
            },
            .subp => |data| {
                for (0..data) |_| {
                    try src.append('<');
                }
            },
            .jz => {
                try src.append('[');
            },
            .jnz => {
                try src.append(']');
            },
            .in => |data| {
                for (0..data) |_| {
                    try src.append(',');
                }
            },
            .out => |data| {
                for (0..data) |_| {
                    try src.append('.');
                }
            },
            .set => {
                if (c.data == 0) {
                    try src.append('[');
                    try src.append('-');
                    try src.append(']');
                }
            },
            .nop => {},
            else => comptime unreachable,
        }
    }

    return src.toOwnedSlice();
}

/// replace `jz add/sub jnz` with `set`
fn setZeroOp(codes: []const Opcode, alloc: std.mem.Allocator) ![]const Opcode {
    const codesLen = codes.len;

    var outCodes = std.ArrayList(Opcode).init(alloc);
    errdefer outCodes.deinit();

    var i: usize = 0;
    while (i < codesLen) : (i += 1) {
        switch (codes[i]) {
            .jz => {
                if ((codesLen - i > 2) and (codes[i + 1] == .add or codes[i + 1] == .sub) and codes[i + 2] == .jnz) {
                    try outCodes.append(.{ .set = 0 });
                    i += 2;
                } else {
                    try outCodes.append(codes[i]);
                }
            },
            .add, .sub, .addp, .subp, .in, .out, .jnz => {
                try outCodes.append(codes[i]);
            },
            .nop, .set => {},
        }
    }

    return outCodes.toOwnedSlice();
}

/// set `.data` for `.jz/.jnz`
fn setJmupAddress(codes: []const Opcode, alloc: std.mem.Allocator) ![]const Opcode {
    const codesLen = codes.len;

    var outCodes = std.ArrayList(Opcode).init(alloc);
    errdefer outCodes.deinit();

    var loopStack = std.ArrayList(Opcode).init(alloc);
    defer loopStack.deinit();

    var i: usize = 0;
    while (i < codesLen) : (i += 1) {
        switch (codes[i]) {
            .jz => {
                try outCodes.append(.{ .jz = outCodes.items.len });
                try loopStack.append(outCodes.getLast());
            },
            .jnz => {
                const pre = loopStack.pop().?;
                const len: usize = outCodes.items.len - pre.jz;
                try outCodes.append(.{ .jnz = len });
                outCodes.items[pre.jz] = .{ .jz = len };
            },
            .add, .sub, .addp, .subp, .in, .out, .set, .nop => try outCodes.append(codes[i]),
        }
    }

    if (loopStack.items.len != 0) {
        return error.UnMatchedLoop;
    }

    return outCodes.toOwnedSlice();
}

pub fn optimize(bf_source: []const u8, alloc: std.mem.Allocator) ![]const Opcode {
    if (!loopCheck(bf_source)) {
        return error.UnMatchedLoop;
    }

    const reordered = try codeReordering(bf_source, alloc);
    defer alloc.free(reordered);

    const combined = try combineInstructionsFromOpCodes(reordered, alloc);
    defer alloc.free(combined);

    const setZero = try setZeroOp(combined, alloc);
    defer alloc.free(setZero);

    return setJmupAddress(setZero, alloc);
}

test "canonicalization optimize" {
    const alloc = std.testing.allocator;
    const program = "-<<<++><>>--<>>++<<+>>-";

    const optimized = try optimize(program, alloc);
    const ordered = try opcodesToSource(optimized, alloc);

    try std.testing.expectEqualStrings(ordered, "<--<+<++>>>");

    defer alloc.free(optimized);
    defer alloc.free(ordered);
}

test "reorder" {
    const alloc = std.testing.allocator;
    const program = "-<<<++><>>--<>>++<<+>>-";

    const orderedProgram = try codeReordering(program, alloc);
    const ordered = try opcodesToSource(orderedProgram, alloc);

    try std.testing.expectEqualStrings(ordered, "-++-<--<+<++><>><>><<>>");

    defer alloc.free(orderedProgram);
    defer alloc.free(ordered);
}

test "unmatched brackets detection" {
    const alloc = std.testing.allocator;

    try std.testing.expectError(error.UnMatchedLoop, combineInstructionsFromSrcExceptPtr("]", alloc));

    try std.testing.expectError(error.UnMatchedLoop, combineInstructionsFromSrcExceptPtr("[++", alloc));

    if (combineInstructionsFromSrcExceptPtr("[[]]", alloc)) |optimized| {
        defer alloc.free(optimized);
    } else |_| {
        try std.testing.expect(false);
    }
}
