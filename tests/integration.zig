//! Runs real 9front binaries from the root tree through the hp9 CLI and
//! checks their output and exit status. Each case is a separate hp9 process,
//! so it covers the CLI, root resolution and exit codes end to end.
//!
//! The build passes the hp9 binary, the root tree (-Droot, default
//! .local/9front/root) and the backends to test (HP9_TEST_BACKENDS, the
//! ones built in) through the environment. Every case runs on each backend
//! that can run arm64 here. Without a root tree, the tests are skipped.

const std = @import("std");
const builtin = @import("builtin");

const gpa = std.testing.allocator;

const Env = struct {
    hp9: []const u8,
    root: []const u8,
    backends: []const u8,
};

fn env() !Env {
    const hp9 = std.testing.environ.getPosix("HP9_TEST_BIN") orelse return error.SkipZigTest;
    const root = std.testing.environ.getPosix("HP9_TEST_ROOT") orelse return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(root, "arm64/bin/cat"), .{}) catch return error.SkipZigTest;
    const backends = std.testing.environ.getPosix("HP9_TEST_BACKENDS") orelse "auto";
    return .{ .hp9 = hp9, .root = root, .backends = backends };
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

/// Runs `hp9 --root <root> args...` on each backend and returns the first
/// result, after checking that every backend gave the same one.
fn run(e: Env, args: []const []const u8) !Result {
    return runIn(e, args, null);
}

/// Like `run`, with `stdin` (if not null) on the guest's console.
fn runIn(e: Env, args: []const []const u8, stdin: ?[]const u8) !Result {
    var first: ?Result = null;
    errdefer if (first) |f| f.deinit();
    var it = std.mem.tokenizeScalar(u8, e.backends, ',');
    while (it.next()) |backend| {
        const r = try runOn(e, backend, args, stdin);
        if (first) |f| {
            defer r.deinit();
            errdefer std.debug.print("backend {s} differs from {s} for hp9 {s}\n", .{ backend, firstBackend(e), args[0] });
            try std.testing.expectEqualStrings(f.out, r.out);
            try std.testing.expectEqual(f.code, r.code);
        } else first = r;
    }
    return first orelse error.SkipZigTest;
}

fn firstBackend(e: Env) []const u8 {
    var it = std.mem.tokenizeScalar(u8, e.backends, ',');
    return it.next() orelse "auto";
}

fn runOn(e: Env, backend: []const u8, args: []const []const u8, stdin: ?[]const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ e.hp9, "--backend", backend, "--root", e.root });
    try argv.appendSlice(gpa, args);
    const r = if (stdin) |data| blk: {
        // std.process.run has no stdin; feed it through a file.
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in", .data = data });
        var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPathFile(std.testing.io, "in", &p);
        var sh: std.ArrayList(u8) = .empty;
        defer sh.deinit(gpa);
        for (argv.items) |a| try sh.print(gpa, "'{s}' ", .{a});
        try sh.print(gpa, "< '{s}'", .{p[0..n]});
        break :blk try std.process.run(gpa, std.testing.io, .{
            .argv = &.{ "/bin/sh", "-c", sh.items },
            .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
        });
    } else try std.process.run(gpa, std.testing.io, .{
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

test "stdin reaches the guest's console" {
    const e = try env();
    const r = try runIn(e, &.{"wc"}, "a b\nc\n");
    defer r.deinit();
    try std.testing.expectEqualStrings("      2       3       6\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "the host environment isn't imported" {
    const e = try env();
    const r = try run(e, &.{ "--env", "hp9test=yes", "ls", "/env" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/env/hp9test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/env/user\n") != null);
    // HOME is set in every host environment that runs these tests.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/env/HOME") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/env/PATH") == null);
}

test "the host cwd is the guest's cwd" {
    const e = try env();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "note", .data = "from the host cwd\n" });
    var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &p);
    const r = try run(e, &.{ "--cwd", p[0..n], "cat", "note" });
    defer r.deinit();
    try std.testing.expectEqualStrings("from the host cwd\n", r.out);
    const pwd = try run(e, &.{ "--cwd", p[0..n], "pwd" });
    defer pwd.deinit();
    try std.testing.expectEqualStrings("/mnt/term/cwd\n", pwd.out);
}
