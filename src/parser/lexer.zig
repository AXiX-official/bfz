const std = @import("std");

pub const SrcLocation = struct {
    line: usize,
    col: usize,
};

pub const Token = struct {
    char: u8,
    loc: SrcLocation,
};

pub fn lex(src: []const u8, alloc: std.mem.Allocator) ![]const Token {
    var tokens = std.ArrayList(Token).init(alloc);
    errdefer tokens.deinit();

    var line: usize = 1;
    var col: usize = 1;
    for (src) |c| {
        switch (c) {
            '+', '-', '>', '<', '[', ']', ',', '.' => {
                try tokens.append(.{ .char = c, .loc = .{ .line = line, .col = col } });
                col += 1;
            },
            '\n' => {
                line += 1;
                col = 1;
            },
            else => col += 1,
        }
    }

    return tokens.toOwnedSlice();
}
