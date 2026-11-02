//! Command-line parsing: argv to a Config, with no I/O. See DESIGN.md, "CLI".

const std = @import("std");
const vmm = @import("hp9").vmm;

pub const usage = "usage: hp9 [--backend auto|hvf|kvm|whp|emu] [--trace] [--] binary [args...]\n";

pub const Config = struct {
    backend: vmm.BackendKind = .auto,
    trace: bool = false,
    /// The program path followed by its arguments.
    argv: []const []const u8,
};

pub const Error = error{Usage};

pub fn parse(args: []const []const u8) Error!Config {
    var c: Config = .{ .argv = &.{} };
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
        } else {
            return error.Usage;
        }
    }
    if (i >= args.len) return error.Usage;
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

test "flags stop at the first non-flag" {
    const c = try parse(&.{ "hp9", "--backend", "emu", "--trace", "./ls", "--trace" });
    try std.testing.expectEqual(vmm.BackendKind.emu, c.backend);
    try std.testing.expect(c.trace);
    try std.testing.expectEqual(@as(usize, 2), c.argv.len);
    try std.testing.expectEqualStrings("--trace", c.argv[1]);
}

test "--backend=value and --" {
    const c = try parse(&.{ "hp9", "--backend=hvf", "--", "--weird" });
    try std.testing.expectEqual(vmm.BackendKind.hvf, c.backend);
    try std.testing.expectEqualStrings("--weird", c.argv[0]);
}

test "usage errors" {
    try std.testing.expectError(error.Usage, parse(&.{"hp9"}));
    try std.testing.expectError(error.Usage, parse(&.{ "hp9", "--backend" }));
    try std.testing.expectError(error.Usage, parse(&.{ "hp9", "--backend", "qemu", "x" }));
    try std.testing.expectError(error.Usage, parse(&.{ "hp9", "--nope", "x" }));
}
