//! Plan 9 a.out header parsing (sys/include/a.out.h).

const std = @import("std");

pub const HDR_MAGIC: u32 = 0x00008000;

fn magic(f: u32, b: u32) u32 {
    return f | ((((4 * b) + 0) * b) + 7);
}

pub const S_MAGIC = magic(HDR_MAGIC, 26); // amd64
pub const R_MAGIC = magic(HDR_MAGIC, 28); // arm64

pub const Arch = enum { arm64, amd64 };

pub const Layout = struct {
    utzero: u64,
    ustktop: u64,
    stack_size: u64,
    data_align: u64,
};

pub fn layout(arch: Arch) Layout {
    return switch (arch) {
        .arm64 => .{ .utzero = 0x10000, .ustktop = 0x7FFFF0000, .stack_size = 16 << 20, .data_align = 64 << 10 },
        .amd64 => .{ .utzero = 0x200000, .ustktop = 0x7FFFFFFFF000, .stack_size = 16 << 20, .data_align = 2 << 20 },
    };
}

/// Size of the header for 64-bit magics: eight words plus a 64-bit entry.
pub const header_size = 40;

pub const Header = struct {
    arch: Arch,
    text: u32,
    data: u32,
    bss: u32,
    syms: u32,
    spsz: u32,
    pcsz: u32,
    entry: u64,
};

pub const ParseError = error{ Truncated, BadMagic };

pub fn parse(bytes: []const u8) ParseError!Header {
    if (bytes.len < 32) return error.Truncated;
    const w = struct {
        fn at(b: []const u8, i: usize) u32 {
            return std.mem.readInt(u32, b[i * 4 ..][0..4], .big);
        }
    }.at;
    const arch: Arch = switch (w(bytes, 0)) {
        R_MAGIC => .arm64,
        S_MAGIC => .amd64,
        else => return error.BadMagic,
    };
    if (bytes.len < header_size) return error.Truncated;
    return .{
        .arch = arch,
        .text = w(bytes, 1),
        .data = w(bytes, 2),
        .bss = w(bytes, 3),
        .syms = w(bytes, 4),
        .spsz = w(bytes, 6),
        .pcsz = w(bytes, 7),
        .entry = std.mem.readInt(u64, bytes[32..40], .big),
    };
}

/// Writes a 64-bit a.out header. Used by tests and fixture generators.
pub fn writeHeader(out: *[header_size]u8, h: Header) void {
    const m: u32 = switch (h.arch) {
        .arm64 => R_MAGIC,
        .amd64 => S_MAGIC,
    };
    const words = [8]u32{ m, h.text, h.data, h.bss, h.syms, @truncate(h.entry), h.spsz, h.pcsz };
    for (words, 0..) |v, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], v, .big);
    std.mem.writeInt(u64, out[32..40], h.entry, .big);
}

test "magic values" {
    try std.testing.expectEqual(@as(u32, 0x8C47), R_MAGIC);
    try std.testing.expectEqual(@as(u32, 0x8A97), S_MAGIC);
}

test "header round trip" {
    const h: Header = .{ .arch = .arm64, .text = 0x40, .data = 8, .bss = 16, .syms = 0, .spsz = 0, .pcsz = 0, .entry = 0x10028 };
    var buf: [header_size]u8 = undefined;
    writeHeader(&buf, h);
    try std.testing.expectEqualDeep(h, try parse(&buf));
}

test "rejects bad input" {
    var buf = [_]u8{0} ** header_size;
    try std.testing.expectError(error.BadMagic, parse(&buf));
    try std.testing.expectError(error.Truncated, parse(buf[0..10]));
}
