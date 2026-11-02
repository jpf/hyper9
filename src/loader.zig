//! Loads a 9front a.out into an address space, following sysexec in
//! 9front's port/sysproc.c.

const std = @import("std");
const aout = @import("aout.zig");
const vmm = @import("vmm.zig");

const page = vmm.page_size;

/// sys/include/tos.h
pub const Tos = extern struct {
    prof: extern struct { pp: u64, next: u64, last: u64, first: u64, pid: u32, what: u32 },
    cyclefreq: u64,
    kcycles: i64,
    pcycles: i64,
    pid: u32,
    clock: u32,
};

pub const Image = struct {
    arch: aout.Arch,
    entry: u64,
    sp: u64,
    tos: u64,
};

pub const Error = error{BadExec} || aout.ParseError;

fn pageRound(x: u64) u64 {
    return std.mem.alignForward(u64, x, page);
}

pub fn load(b: vmm.Backend, as: vmm.AddressSpace, bytes: []const u8, argv: []const []const u8, pid: u32) !Image {
    const h = try aout.parse(bytes);
    const l = aout.layout(h.arch);

    const text_end = l.utzero + aout.header_size + h.text;
    if (h.entry < l.utzero + aout.header_size or h.entry >= text_end) return error.BadExec;
    const file_text = aout.header_size + h.text;
    if (bytes.len < file_text + h.data) return error.BadExec;

    const adata = std.mem.alignForward(u64, text_end, l.data_align);
    const abss = pageRound(adata + h.data);
    const ebss = pageRound(adata + h.data + h.bss);
    const stack_base = l.ustktop - l.stack_size;
    if (ebss >= stack_base) return error.BadExec;

    const text = try b.allocPages(pageRound(file_text) / page);
    @memcpy(text[0..file_text], bytes[0..file_text]);
    try as.map(l.utzero, text, .{ .exec = true });

    if (ebss > adata) {
        const data = try b.allocPages((ebss - adata) / page);
        @memcpy(data[0..h.data], bytes[file_text..][0..h.data]);
        try as.map(adata, data, .{ .write = true });
    }
    _ = abss;

    const stack = try b.allocPages(l.stack_size / page);
    try as.map(stack_base, stack, .{ .write = true });

    // Top of stack: Tos, then argument strings, then argv[], then argc at SP.
    const top = stack.len;
    const tos_off = top - @sizeOf(Tos);
    const tos: *Tos = @ptrCast(@alignCast(stack[tos_off..][0..@sizeOf(Tos)]));
    tos.* = std.mem.zeroes(Tos);
    tos.pid = pid;

    var strs = tos_off;
    for (argv) |a| strs -= a.len + 1;
    const strs_start = strs;
    const nbytes = tos_off - strs_start;

    const ssize = 8 * (argv.len + 1) + std.mem.alignForward(usize, nbytes, 8);
    const argv_off = tos_off - ssize;
    var p = strs_start;
    for (argv, 0..) |a, i| {
        @memcpy(stack[p..][0..a.len], a);
        stack[p + a.len] = 0;
        std.mem.writeInt(u64, stack[argv_off + 8 * i ..][0..8], stack_base + p, .little);
        p += a.len + 1;
    }
    std.mem.writeInt(u64, stack[argv_off + 8 * argv.len ..][0..8], 0, .little);
    const argc_off = argv_off - 8;
    std.mem.writeInt(u64, stack[argc_off..][0..8], argv.len, .little);

    return .{ .arch = h.arch, .entry = h.entry, .sp = stack_base + argc_off, .tos = stack_base + tos_off };
}

test "Tos layout matches tos.h" {
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(Tos));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Tos, "cyclefreq"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(Tos, "pid"));
}
