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

/// Combine instructions Except `[` and `]`
/// for later optimization.
/// the `.data` in `jz/jnz` is incorrect.
fn combineInstructionsFromSrc(bf_source: []const u8, alloc: std.mem.Allocator) ![]const Opcode {
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

/// Conservative code reordering
/// the `.data` in `jz/jnz` is incorrect.
fn opcodeReordering(codes: []const Opcode, alloc: std.mem.Allocator) ![]const Opcode {
    const codesLen = codes.len;

    var opnodes = try alloc.alloc(OpNode, codesLen + 1);
    defer alloc.free(opnodes);
    opnodes[codesLen] = .{ .data = .{ .data = 0, .op = .nop }, .next = &opnodes[0] };
    for (0..codesLen) |i| {
        opnodes[i] = .{ .data = codes[i], .next = &opnodes[i + 1] };
    }

    var left: usize = 0;
    while (left < codesLen) {
        var right = left;
        while (right < codesLen and
            codes[right].op != .jz and
            codes[right].op != .jnz and
            codes[right].op != .in and
            codes[right].op != .out)
        {
            right += 1;
        }

        if (right < codesLen) {
            right += 1;
        }

        if (right - left > 1) {
            var current = &opnodes[left];
            var prev = if (left == 0) &opnodes[codesLen] else &opnodes[left - 1];

            while (current != &opnodes[right]) {
                if (current.data.op == .addp or current.data.op == .subp) {
                    var balance: i64 = if (current.data.op == .addp) 1 else -1;
                    var scan = current.next;

                    while (scan != &opnodes[right]) {
                        if (scan.data.op == .addp) {
                            balance += 1;
                        } else if (scan.data.op == .subp) {
                            balance -= 1;
                        }

                        if (balance == 0) {
                            const opsBegin = scan.next;
                            var opsEnd = scan;
                            while (opsEnd.next != &opnodes[right] and
                                (opsEnd.next.data.op == .add or
                                    opsEnd.next.data.op == .sub))
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

        left = right + 1;
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

/// Conservative code reordering
/// Never reorder across `[` , `]` , `,` or `.` (treat as boundaries)
/// the jz/jnz address in output is not correct
fn codeReordering(bf_source: []const u8, alloc: std.mem.Allocator) ![]const Opcode {
    const combinedCodes = try combineInstructionsFromSrc(bf_source, alloc);
    defer alloc.free(combinedCodes);
    return opcodeReordering(combinedCodes, alloc);
}

fn opcodesToSource(codes: []const Opcode, alloc: std.mem.Allocator) ![]const u8 {
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

    var loopStack = std.ArrayList(*Opcode).init(alloc);
    defer loopStack.deinit();

    var i: usize = 0;
    while (i < codesLen) {
        switch (codes[i].op) {
            .jz => {
                try outCodes.append(.{ .data = outCodes.items.len, .op = .jz });
                try loopStack.append(@constCast(&outCodes.getLast()));
                i += 1;
            },
            .jnz => {
                const pre = loopStack.pop().?;
                const len: usize = outCodes.items.len - pre.*.data;
                try outCodes.append(.{ .data = len, .op = .jnz });
                outCodes.items[pre.*.data] = .{ .data = len, .op = .jz };
                i += 1;
            },
            .add, .sub, .addp, .subp, .in, .out => {
                try outCodes.append(codes[i]);
                i += 1;
            },
            else => i += 1,
        }
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

    try std.testing.expectError(error.UnMatchedLoop, combineInstructionsFromSrc("]", alloc));

    try std.testing.expectError(error.UnMatchedLoop, combineInstructionsFromSrc("[++", alloc));

    if (combineInstructionsFromSrc("[[]]", alloc)) |optimized| {
        defer alloc.free(optimized);
    } else |_| {
        try std.testing.expect(false);
    }
}
