//! Loads a 9front a.out into an address space, following sysexec in
//! 9front's port/sysproc.c.

const std = @import("std");
const aout = @import("aout.zig");
const vmm = @import("vmm.zig");
const segment = @import("segment.zig");

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
    /// Text, data (data and bss) and stack, attached to the address space.
    segs: segment.Segs,
};

pub const Error = error{BadExec} || aout.ParseError;

fn pageRound(x: u64) u64 {
    return std.mem.alignForward(u64, x, page);
}

/// Loads `bytes` into `as`, which must have no segments in the way, and
/// sets up the stack with `argv` and a Tos for `pid`. On error nothing is
/// left attached to `as`.
pub fn load(gpa: std.mem.Allocator, b: vmm.Backend, as: vmm.AddressSpace, bytes: []const u8, argv: []const []const u8, pid: u32) !Image {
    const h = try aout.parse(bytes);
    const l = aout.layout(h.arch);

    const text_end = l.utzero + aout.header_size + h.text;
    if (h.entry < l.utzero + aout.header_size or h.entry >= text_end) return error.BadExec;
    const file_text = aout.header_size + h.text;
    if (bytes.len < file_text + h.data) return error.BadExec;

    const adata = std.mem.alignForward(u64, text_end, l.data_align);
    const ebss = pageRound(adata + h.data + h.bss);
    const stack_base = l.ustktop - l.stack_size;
    if (ebss >= stack_base) return error.BadExec;

    // The stack's first pages: Tos, then argument strings, then argv[],
    // then argc at SP, with room below for the program to start.
    var nbytes: usize = 0;
    for (argv) |a| nbytes += a.len + 1;
    const ssize = @sizeOf(Tos) + std.mem.alignForward(usize, nbytes, 8) + 8 * (argv.len + 2);
    if (ssize > l.stack_size / 2) return error.BadExec;
    const stack_len = pageRound(ssize + segment.stack_slack);

    var segs: segment.Segs = .{ .stack_floor = stack_base };
    errdefer segs.release(as);

    const text = try segment.Segment.create(gpa, b, .text, .{ .exec = true }, l.utzero, pageRound(file_text));
    @memcpy(text.chunks.items[0].mem[0..file_text], bytes[0..file_text]);
    try text.attach(as);
    segs.text = text;

    const data = try segment.Segment.create(gpa, b, .data, .{ .write = true }, adata, ebss - adata);
    if (h.data > 0) @memcpy(data.chunks.items[0].mem[0..h.data], bytes[file_text..][0..h.data]);
    try data.attach(as);
    segs.data = data;

    const stack = try segment.Segment.create(gpa, b, .stack, .{ .write = true }, l.ustktop - stack_len, stack_len);
    const top = buildStack(stack.chunks.items[0].mem, stack.base, argv, pid);
    try stack.attach(as);
    segs.stack = stack;

    return .{ .arch = h.arch, .entry = h.entry, .sp = top.sp, .tos = top.tos, .segs = segs };
}

/// Lays out Tos, the argument strings, argv[] and argc at the top of
/// `stack`, which is mapped at `base`. Returns the SP and the Tos address.
fn buildStack(stack: []u8, base: u64, argv: []const []const u8, pid: u32) struct { sp: u64, tos: u64 } {
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
        std.mem.writeInt(u64, stack[argv_off + 8 * i ..][0..8], base + p, .little);
        p += a.len + 1;
    }
    std.mem.writeInt(u64, stack[argv_off + 8 * argv.len ..][0..8], 0, .little);
    const argc_off = argv_off - 8;
    std.mem.writeInt(u64, stack[argc_off..][0..8], argv.len, .little);
    return .{ .sp = base + argc_off, .tos = base + tos_off };
}

/// Sets the pid in a process's Tos, as fork and exec must (libc's getpid
/// reads it from there).
pub fn setTosPid(as: vmm.AddressSpace, tos: u64, pid: u32) void {
    const b = as.translate(tos + @offsetOf(Tos, "pid"), 4) orelse return;
    std.mem.writeInt(u32, b[0..4], pid, .little);
}

test "Tos layout matches tos.h" {
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(Tos));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Tos, "cyclefreq"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(Tos, "pid"));
}
