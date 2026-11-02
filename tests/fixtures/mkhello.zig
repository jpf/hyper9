//! Writes the M0 test binary: a static arm64 9front a.out that does
//! pwrite(1, "hello\n", 6, -1) then exits(nil). Zig no longer links Plan 9
//! a.out, so the instructions are encoded by hand.

const std = @import("std");
const aout = @import("aout");

const code = [_]u32{
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
const msg = "hello\n";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;

    var text: [code.len * 4 + msg.len]u8 = undefined;
    for (code, 0..) |insn, i| std.mem.writeInt(u32, text[i * 4 ..][0..4], insn, .little);
    @memcpy(text[code.len * 4 ..], msg);

    var hdr: [aout.header_size]u8 = undefined;
    aout.writeHeader(&hdr, .{
        .arch = .arm64,
        .text = text.len,
        .data = 0,
        .bss = 0,
        .syms = 0,
        .spsz = 0,
        .pcsz = 0,
        .entry = aout.layout(.arm64).utzero + aout.header_size,
    });

    const file = try std.Io.Dir.cwd().createFile(init.io, args[1], .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, &hdr);
    try file.writeStreamingAll(init.io, &text);
}
