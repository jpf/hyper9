//! The M0/M1 test program: pwrite(1, "hello\n", 6, -1) then exits(nil), as
//! arm64 and amd64 text segments. Zig no longer links Plan 9 a.out, so the
//! instructions are encoded by hand; aout.image wraps them in a header.

const std = @import("std");

const arm64_code = [_]u32{
    0xd100c3ff, // sub  sp, sp, #48
    0xd2800021, // mov  x1, #1
    0xf90007e1, // str  x1, [sp, #8]       fd
    0x10000182, // adr  x2, msg
    0xf9000be2, // str  x2, [sp, #16]      buf
    0xd28000c3, // mov  x3, #6
    0xf9000fe3, // str  x3, [sp, #24]      n
    0x92800004, // mov  x4, #-1
    0xf90013e4, // str  x4, [sp, #32]      offset
    0xd2800660, // mov  x0, #51            PWRITE
    0xd4000001, // svc  #0
    0xf90007ff, // str  xzr, [sp, #8]      nil
    0xd2800100, // mov  x0, #8             EXITS
    0xd4000001, // svc  #0
    0x14000000, // b    .
};

// The syscall number goes in BP (RARG); arguments are on the stack from SP+8.
const amd64_code = [_]u8{
    0x48, 0x83, 0xec, 0x30, // subq  $0x30, %rsp
    0x48, 0xc7, 0x44, 0x24, 0x08, 0x01, 0x00, 0x00, 0x00, // movq  $1, 8(%rsp)       fd
    0x48, 0x8d, 0x05, 0x30, 0x00, 0x00, 0x00, // leaq  msg(%rip), %rax
    0x48, 0x89, 0x44, 0x24, 0x10, // movq  %rax, 16(%rsp)     buf
    0x48, 0xc7, 0x44, 0x24, 0x18, 0x06, 0x00, 0x00, 0x00, // movq  $6, 24(%rsp)      n
    0x48, 0xc7, 0x44, 0x24, 0x20, 0xff, 0xff, 0xff, 0xff, // movq  $-1, 32(%rsp)     offset
    0xbd, 0x33, 0x00, 0x00, 0x00, // movl  $51, %ebp          PWRITE
    0x0f, 0x05, // syscall
    0x48, 0xc7, 0x44, 0x24, 0x08, 0x00, 0x00, 0x00, 0x00, // movq  $0, 8(%rsp)       nil
    0xbd, 0x08, 0x00, 0x00, 0x00, // movl  $8, %ebp           EXITS
    0x0f, 0x05, // syscall
    0xeb, 0xfe, // jmp   .
};

pub const msg = "hello\n";

comptime {
    // leaq's displacement (0x30) is relative to the end of the leaq.
    std.debug.assert(amd64_code.len == 20 + 0x30);
}

/// Text segments (code then the message) for arm64 and amd64. The entry
/// point is the start of text, just after the header.
pub const arm64_text = blk: {
    var text: [arm64_code.len * 4 + msg.len]u8 = undefined;
    for (arm64_code, 0..) |insn, i| std.mem.writeInt(u32, text[i * 4 ..][0..4], insn, .little);
    @memcpy(text[arm64_code.len * 4 ..], msg);
    break :blk text;
};
pub const amd64_text = amd64_code ++ msg.*;
