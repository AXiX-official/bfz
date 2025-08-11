const std = @import("std");
const BFVM = @import("bfvm.zig").BFVM;

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 2) {
        std.debug.print("Usage:{s} <.bf filepath>", .{args[0]});
        return;
    }

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    const bfvm = BFVM(@TypeOf(stdout), @TypeOf(stdin));
    var vm = try bfvm.init(alloc, 2048, stdout, stdin);

    try vm.executeFile(args[1]);
    defer vm.deinit();
}

test "mainTest" {
    const alloc = std.testing.allocator;
    const program = "[+]>>>";

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    const bfvm = BFVM(@TypeOf(stdout), @TypeOf(stdin));
    var vm = try bfvm.init(alloc, 2048, stdin, stdout);
    try vm.executeString(program);
    defer vm.deinit();
}
