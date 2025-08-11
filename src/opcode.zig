const std = @import("std");

pub const Op = enum(u8) {
    /// `+`
    add,
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
};

pub const Opcode = union(Op) {
    add: u8,
    addp: usize,
    subp: usize,
    jz: usize,
    jnz: usize,
    in: usize,
    out: usize,
    // extend
    nop: void,
    set: u8,
};
