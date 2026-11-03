//! Zig side of the drawterm kern seam (DESIGN.md, "Kernel: drawterm kern/
//! and the Zig seam"). Each call goes through one of kern's `sys*` wrappers,
//! which catch kernel errors with waserror and return -1; `errstr` then
//! holds the message. No Zig frame sits between a waserror and an error.
//!
//! kern is a process-wide singleton: one booted kernel per host process.

const std = @import("std");
const build_options = @import("build_options");

/// False where kern isn't built (Windows until M2).
pub const available = build_options.kern;

pub const Error = error{ KernUnavailable, AlreadyBooted, Kern };

pub const OREAD = 0;
pub const OWRITE = 1;
pub const ORDWR = 2;

const c = struct {
    extern fn hp9_kern_boot(root: [*:0]const u8, cwd: ?[*:0]const u8) c_int;
    extern fn hp9_kern_errstr() [*:0]const u8;
    extern fn sysopen(name: [*:0]const u8, mode: c_int) c_int;
    extern fn sysclose(fd: c_int) c_int;
    extern fn syspread(fd: c_int, buf: [*]u8, n: c_int, off: i64) c_int;
    extern fn syspwrite(fd: c_int, buf: [*]const u8, n: c_int, off: i64) c_int;
};

var booted: std.atomic.Value(bool) = .init(false);

/// Boots the kernel on the calling thread, which becomes its first Proc,
/// with the host directory `root` as / and `cwd` (if given) at /mnt/term.
/// The kernel can be booted only once per host process.
pub fn boot(root: [*:0]const u8, cwd: ?[*:0]const u8) Error!void {
    if (!available) return error.KernUnavailable;
    if (booted.swap(true, .acq_rel)) return error.AlreadyBooted;
    if (c.hp9_kern_boot(root, cwd) < 0) return error.Kern;
}

/// The calling Proc's error string after a failed call.
pub fn errstr() []const u8 {
    return std.mem.span(c.hp9_kern_errstr());
}

fn check(r: c_int) Error!u31 {
    if (r < 0) return error.Kern;
    return @intCast(r);
}

pub fn open(name: [*:0]const u8, mode: c_int) Error!u31 {
    return check(c.sysopen(name, mode));
}

pub fn close(fd: u31) Error!void {
    _ = try check(c.sysclose(fd));
}

pub fn pread(fd: u31, buf: []u8, off: i64) Error!usize {
    return try check(c.syspread(fd, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_int))), off));
}

pub fn pwrite(fd: u31, buf: []const u8, off: i64) Error!usize {
    return try check(c.syspwrite(fd, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_int))), off));
}

test "boot a host tree and read a file through kern" {
    if (!available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/namespace", .data = "mount -a #s/boot /\n" });
    for ([_][]const u8{ "dev", "env", "net", "mnt/term" }) |d| try tmp.dir.createDirPath(io, d);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    buf[n] = 0;
    const root: [*:0]const u8 = buf[0..n :0];

    try boot(root, root);

    const fd = try open("/lib/namespace", OREAD);
    defer close(fd) catch {};
    var data: [64]u8 = undefined;
    try std.testing.expectEqualStrings("mount -a #s/boot /\n", data[0..try pread(fd, &data, 0)]);

    try std.testing.expectError(error.Kern, open("namespace", OREAD));
    try std.testing.expect(std.mem.indexOf(u8, errstr(), "does not exist") != null);

    const sys = try open("/dev/sysname", OREAD);
    defer close(sys) catch {};
    try std.testing.expectEqualStrings("hp9", data[0..try pread(sys, &data, 0)]);
}
