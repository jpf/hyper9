//! Runs real 9front binaries from the root tree through the hp9 CLI and
//! checks their output and exit status. Each case is a separate hp9 process,
//! so it covers the CLI, root resolution and exit codes end to end.
//!
//! The build passes the hp9 binary and the root tree (-Droot, default
//! .local/9front/root) through the environment. Without a root tree, or on
//! hosts where hp9 can't run arm64 binaries, the tests are skipped.

const std = @import("std");
const builtin = @import("builtin");

const gpa = std.testing.allocator;

const Env = struct {
    hp9: []const u8,
    root: []const u8,
};

fn env() !Env {
    const hp9 = std.testing.environ.getPosix("HP9_TEST_BIN") orelse return error.SkipZigTest;
    const root = std.testing.environ.getPosix("HP9_TEST_ROOT") orelse return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(root, "arm64/bin/cat"), .{}) catch return error.SkipZigTest;
    return .{ .hp9 = hp9, .root = root };
}

var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

fn hostPath(root: []const u8, rel: []const u8) ![]const u8 {
    return std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, rel });
}

const Result = struct {
    code: u8,
    out: []u8,
    err: []u8,

    fn deinit(r: Result) void {
        gpa.free(r.out);
        gpa.free(r.err);
    }
};

/// Runs `hp9 --root <root> args...`.
fn run(e: Env, args: []const []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ e.hp9, "--root", e.root });
    try argv.appendSlice(gpa, args);
    const r = try std.process.run(gpa, std.testing.io, .{
        .argv = argv.items,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    });
    const code = switch (r.term) {
        .exited => |c| c,
        else => {
            std.debug.print("hp9 {s}: {any}\n{s}", .{ args[0], r.term, r.stderr });
            return error.Crashed;
        },
    };
    return .{ .code = code, .out = r.stdout, .err = r.stderr };
}

test "cat /lib/namespace (M2 demo)" {
    const e = try env();
    const want = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try hostPath(e.root, "lib/namespace"), gpa, .unlimited);
    defer gpa.free(want);
    const r = try run(e, &.{ "/bin/cat", "/lib/namespace" });
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.err);
    try std.testing.expectEqualStrings(want, r.out);
    try std.testing.expectEqual(0, r.code);
}

test "echo" {
    const e = try env();
    const r = try run(e, &.{ "echo", "hello,", "world" });
    defer r.deinit();
    try std.testing.expectEqualStrings("hello, world\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "exits string gives status 1 and is printed" {
    const e = try env();
    const r = try run(e, &.{ "/bin/cat", "/does/not/exist" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "/does/not/exist") != null);
}

test "missing program gives 127" {
    const e = try env();
    const r = try run(e, &.{"no-such-program"});
    defer r.deinit();
    try std.testing.expectEqual(127, r.code);
}

test "non-a.out program gives 126" {
    const e = try env();
    const r = try run(e, &.{"/lib/namespace"});
    defer r.deinit();
    try std.testing.expectEqual(126, r.code);
}
