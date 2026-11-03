//! Command-line parsing: argv to a Config, with no I/O. See DESIGN.md, "CLI".

const std = @import("std");
const vmm = @import("hp9").vmm;

pub const usage =
    \\usage: hp9 [--backend auto|hvf|kvm|whp|emu] [--root DIR] [--cwd DIR]
    \\           [--env name=value]... [--trace] [--] program [args...]
    \\
;

pub const Config = struct {
    backend: vmm.BackendKind = .auto,
    trace: bool = false,
    /// --root; null means $HP9ROOT, then the default.
    root: ?[]const u8 = null,
    /// --cwd: the host directory bound at /mnt/term/cwd; null means the
    /// host cwd.
    cwd: ?[]const u8 = null,
    /// --env values, as name=value.
    env: []const []const u8 = &.{},
    /// The program followed by its arguments.
    argv: []const []const u8,
};

pub const Error = error{ Usage, OutOfMemory };

/// How a program argument is found (DESIGN.md, "Program resolution").
pub const ProgramKind = enum {
    /// `./x` or `../x`: read on the host, relative to the host cwd.
    host,
    /// Anything else: resolved in the guest namespace.
    guest,
};

pub fn programKind(arg: []const u8) ProgramKind {
    if (std.mem.startsWith(u8, arg, "./") or std.mem.startsWith(u8, arg, "../")) return .host;
    return .guest;
}

pub fn parse(gpa: std.mem.Allocator, args: []const []const u8) Error!Config {
    var c: Config = .{ .argv = &.{} };
    var env: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!std.mem.startsWith(u8, a, "--")) break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else if (std.mem.eql(u8, a, "--trace")) {
            c.trace = true;
        } else if (value(args, &i, "--backend")) |v| {
            c.backend = std.meta.stringToEnum(vmm.BackendKind, v orelse return error.Usage) orelse return error.Usage;
        } else if (value(args, &i, "--root")) |v| {
            c.root = v orelse return error.Usage;
        } else if (value(args, &i, "--cwd")) |v| {
            c.cwd = v orelse return error.Usage;
        } else if (value(args, &i, "--env")) |v| {
            const e = v orelse return error.Usage;
            const eq = std.mem.indexOfScalar(u8, e, '=') orelse return error.Usage;
            if (eq == 0 or std.mem.indexOfScalar(u8, e[0..eq], '/') != null) return error.Usage;
            try env.append(gpa, e);
        } else {
            return error.Usage;
        }
    }
    if (i >= args.len) return error.Usage;
    c.env = try env.toOwnedSlice(gpa);
    c.argv = args[i..];
    return c;
}

/// Matches `--name=value` or `--name value`. Returns null if args[i.*] is a
/// different flag, and a null value if the value is missing.
fn value(args: []const []const u8, i: *usize, comptime name: []const u8) ??[]const u8 {
    const a = args[i.*];
    if (std.mem.startsWith(u8, a, name ++ "=")) return a[name.len + 1 ..];
    if (!std.mem.eql(u8, a, name)) return null;
    if (i.* + 1 >= args.len) return @as(?[]const u8, null);
    i.* += 1;
    return args[i.*];
}

const t = std.testing;

test "flags stop at the first non-flag" {
    const c = try parse(t.allocator, &.{ "hp9", "--backend", "emu", "--trace", "./ls", "--trace" });
    defer t.allocator.free(c.env);
    try t.expectEqual(vmm.BackendKind.emu, c.backend);
    try t.expect(c.trace);
    try t.expectEqual(@as(usize, 2), c.argv.len);
    try t.expectEqualStrings("--trace", c.argv[1]);
}

test "--backend=value and --" {
    const c = try parse(t.allocator, &.{ "hp9", "--backend=hvf", "--", "--weird" });
    defer t.allocator.free(c.env);
    try t.expectEqual(vmm.BackendKind.hvf, c.backend);
    try t.expectEqualStrings("--weird", c.argv[0]);
}

test "--root, --cwd and repeated --env" {
    const c = try parse(t.allocator, &.{ "hp9", "--root", "/r", "--cwd=/w", "--env", "a=1", "--env=b=x=y", "cat" });
    defer t.allocator.free(c.env);
    try t.expectEqualStrings("/r", c.root.?);
    try t.expectEqualStrings("/w", c.cwd.?);
    try t.expectEqual(@as(usize, 2), c.env.len);
    try t.expectEqualStrings("b=x=y", c.env[1]);
}

test "usage errors" {
    try t.expectError(error.Usage, parse(t.allocator, &.{"hp9"}));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "hp9", "--backend" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "hp9", "--backend", "qemu", "x" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "hp9", "--nope", "x" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "hp9", "--env", "noequals", "x" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "hp9", "--env", "=v", "x" }));
}

test "program kinds" {
    try t.expectEqual(ProgramKind.host, programKind("./hello"));
    try t.expectEqual(ProgramKind.host, programKind("../out/x"));
    try t.expectEqual(ProgramKind.guest, programKind("/bin/cat"));
    try t.expectEqual(ProgramKind.guest, programKind("cat"));
    try t.expectEqual(ProgramKind.guest, programKind("aux/vga"));
}
