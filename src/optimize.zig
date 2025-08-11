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
    while (i < srcLen) {
        switch (bf_source[i]) {
            '+', '-' => {
                var addCount: usize = 0;
                var subCount: usize = 0;
                while (i < srcLen) {
                    if (bf_source[i] == '+') {
                        addCount += 1;
                    } else if (bf_source[i] == '-') {
                        subCount += 1;
                    } else {
                        break;
                    }
                    i += 1;
                }
                if (addCount > subCount) {
                    try codes.append(.{ .data = addCount - subCount, .op = .add });
                } else if (addCount < subCount) {
                    try codes.append(.{ .data = subCount - addCount, .op = .sub });
                }
            },
            '>' => {
                try codes.append(.{ .data = 1, .op = .addp });
                i += 1;
            },
            '<' => {
                try codes.append(.{ .data = 1, .op = .subp });
                i += 1;
            },
            ',' => {
                const start = i;
                while (i + 1 < srcLen and bf_source[i + 1] == ',') {
                    i += 1;
                }
                try codes.append(.{ .data = i - start + 1, .op = .in });
                i += 1;
            },
            '.' => {
                const start = i;
                while (i + 1 < srcLen and bf_source[i + 1] == '.') {
                    i += 1;
                }
                try codes.append(.{ .data = i - start + 1, .op = .out });
                i += 1;
            },
            '[' => {
                try codes.append(.{ .data = 0, .op = .jz });
                i += 1;
            },
            ']' => {
                try codes.append(.{ .data = 0, .op = .jnz });
                i += 1;
            },
            else => i += 1,
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
        switch (codes[i].op) {
            .add, .sub => {
                var addCount: usize = 0;
                var subCount: usize = 0;
                while (i < codesLen) {
                    if (codes[i].op == .add) {
                        addCount += codes[i].data;
                    } else if (codes[i].op == .sub) {
                        subCount += codes[i].data;
                    } else {
                        break;
                    }
                    i += 1;
                }
                if (addCount > subCount) {
                    try outCodes.append(.{ .data = addCount - subCount, .op = .add });
                } else if (addCount < subCount) {
                    try outCodes.append(.{ .data = subCount - addCount, .op = .sub });
                }
            },
            .addp, .subp => {
                var addpCount: usize = 0;
                var subpCount: usize = 0;
                while (i < codesLen) {
                    if (codes[i].op == .addp) {
                        addpCount += codes[i].data;
                    } else if (codes[i].op == .subp) {
                        subpCount += codes[i].data;
                    } else {
                        break;
                    }
                    i += 1;
                }
                if (addpCount > subpCount) {
                    try outCodes.append(.{ .data = addpCount - subpCount, .op = .addp });
                } else if (addpCount < subpCount) {
                    try outCodes.append(.{ .data = subpCount - addpCount, .op = .subp });
                }
            },
            .in => {
                var count: usize = 0;
                while (i < codesLen) {
                    if (codes[i].op == .in) {
                        count += codes[i].data;
                    } else {
                        break;
                    }
                    i += 1;
                }
                try outCodes.append(.{ .data = count, .op = .in });
            },
            .out => {
                var count: usize = 0;
                while (i < codesLen) {
                    if (codes[i].op == .out) {
                        count += codes[i].data;
                    } else {
                        break;
                    }
                    i += 1;
                }
                try outCodes.append(.{ .data = count, .op = .out });
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
    opnodes[codesLen] = .{ .data = .{ .data = 0, .op = .nop }, .next = &opnodes[0] };
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
            right.data.op != .jz and
            right.data.op != .jnz and
            !(hasIO and
                !(right.data.op != .in and right.data.op != .out)))
        {
            if (right != left and (right.data.op == .in or right.data.op == .out)) {
                hasIO = true;
            }
            right = right.next;
        }

        if (right != left.next) {
            var current = left;
            while (current != right) {
                if (hasIO and (current.data.op == .in or current.data.op == .out)) {
                    ioNode = current;
                }

                if (current.data.op == .addp or current.data.op == .subp) {
                    var balance: i64 = if (current.data.op == .addp) 1 else -1;
                    var scan = current.next;

                    while (scan != right) {
                        if (scan.data.op == .addp) {
                            balance += 1;
                        } else if (scan.data.op == .subp) {
                            balance -= 1;
                        }

                        if (balance == 0) {
                            const opsBegin = scan.next;
                            var opsEnd = scan;
                            while (opsEnd.next != right and
                                (opsEnd.next.data.op == .add or
                                    opsEnd.next.data.op == .sub or
                                    opsEnd.next.data.op == .in or
                                    opsEnd.next.data.op == .out))
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
        switch (c.op) {
            .add => {
                for (0..c.data) |_| {
                    try src.append('+');
                }
            },
            .sub => {
                for (0..c.data) |_| {
                    try src.append('-');
                }
            },
            .addp => {
                for (0..c.data) |_| {
                    try src.append('>');
                }
            },
            .subp => {
                for (0..c.data) |_| {
                    try src.append('<');
                }
            },
            .jz => {
                try src.append('[');
            },
            .jnz => {
                try src.append(']');
            },
            .in => {
                for (0..c.data) |_| {
                    try src.append(',');
                }
            },
            .out => {
                for (0..c.data) |_| {
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
            else => {},
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
    while (i < codesLen) {
        switch (codes[i].op) {
            .jz => {
                if ((codesLen - i > 2) and (codes[i + 1].op == .add or codes[i + 1].op == .sub) and codes[i + 2].op == .jnz) {
                    try outCodes.append(.{ .data = 0, .op = .set });
                    i += 3;
                } else {
                    try outCodes.append(codes[i]);
                    i += 1;
                }
            },
            .add, .sub, .addp, .subp, .in, .out, .jnz => {
                try outCodes.append(codes[i]);
                i += 1;
            },
            else => i += 1,
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
    while (i < codesLen) {
        switch (codes[i].op) {
            .jz => {
                try outCodes.append(.{ .data = outCodes.items.len, .op = .jz });
                try loopStack.append(outCodes.getLast());
                i += 1;
            },
            .jnz => {
                const pre = loopStack.pop().?;
                const len: usize = outCodes.items.len - pre.data;
                try outCodes.append(.{ .data = len, .op = .jnz });
                outCodes.items[pre.data] = .{ .data = len, .op = .jz };
                i += 1;
            },
            else => {
                try outCodes.append(codes[i]);
                i += 1;
            },
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
