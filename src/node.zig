const std = @import("std");

pub fn Node(comptime T: type) type {
    return struct {
        data: T,
        next: *Node(T),
    };
}
