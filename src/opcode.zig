const std = @import("std");

pub const Op = enum(u8) {
    /// `+`
    add,
    /// `-`
    sub,
    /// `>`
    addp,
    /// `<`
    subp,
    /// `[`
    jz,
    /// `]`
    jnz,
    /// `,`
    in,
    /// `.`
    out,
    // extend
    /// nop
    nop,
    /// buff[ptr] = value
    set,
    _,
};

pub const Opcode = struct {
    data: usize,
    op: Op,
};
