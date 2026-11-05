//! Writes the hello test binary (see hello.zig).
//!
//! usage: mkhello arm64|amd64|386 out

const std = @import("std");
const aout = @import("aout");
const hello = @import("hello");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    const arch = aout.Arch.fromName(args[1]) orelse return error.Usage;
    const text: []const u8 = switch (arch) {
        .arm64 => &hello.arm64_text,
        .amd64 => &hello.amd64_text,
        .i386 => &hello.i386_text,
    };
    var buf: [aout.header_size]u8 = undefined;
    const hdr = buf[0..arch.headerSize()];
    aout.writeTextHeader(hdr, arch, text.len);
    const file = try std.Io.Dir.cwd().createFile(init.io, args[2], .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, hdr);
    try file.writeStreamingAll(init.io, text);
}
