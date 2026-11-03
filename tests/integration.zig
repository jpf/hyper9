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

/// A scratch host directory, resolved, for cwd and policy tests.
const Scratch = struct {
    tmp: std.testing.TmpDir,
    path: []const u8,
    buf: [std.Io.Dir.max_path_bytes]u8 = undefined,

    fn init(s: *Scratch) !void {
        s.tmp = std.testing.tmpDir(.{});
        const n = try s.tmp.dir.realPath(std.testing.io, &s.buf);
        s.path = s.buf[0..n];
    }
    fn deinit(s: *Scratch) void {
        s.tmp.cleanup();
    }
    fn exists(s: *Scratch, name: []const u8) bool {
        s.tmp.dir.access(std.testing.io, name, .{}) catch return false;
        return true;
    }
};

test "tight profile: writing to the cwd fails (M2 demo)" {
    const e = try env();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try run(e, &.{ "--cwd", s.path, "--profile=tight", "--rc", "echo x > /mnt/term/cwd/f" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(!s.exists("f"));
}

test "default profile: the cwd is writable and the root isn't" {
    const e = try env();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // rc can't fork until M3, so files are made with touch.
    const r = try run(e, &.{ "--cwd", s.path, "touch", "f" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(s.exists("f"));
    const ro = try run(e, &.{ "--cwd", s.path, "touch", "/lib/hp9-test" });
    defer ro.deinit();
    try std.testing.expectEqual(1, ro.code);
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(e.root, "lib/hp9-test"), .{}) catch return;
    return error.RootWasWritten;
}

test "--sandbox DIR is writable" {
    const e = try env();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try run(e, &.{ "--sandbox", s.path, "touch", "f" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(s.exists("f"));
}

test "--writable under a read-only cwd" {
    const e = try env();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "out");
    var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out = try std.fmt.bufPrint(&p, "{s}/out", .{s.path});
    const r = try run(e, &.{ "--cwd", s.path, "--profile=tight", "--writable", out, "touch", "out/f" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(s.exists("out/f"));
    const g = try run(e, &.{ "--cwd", s.path, "--profile=tight", "--writable", out, "touch", "g" });
    defer g.deinit();
    try std.testing.expectEqual(1, g.code);
    try std.testing.expect(!s.exists("g"));
}

test "--read-deny hides a path, and symlinks can't escape" {
    const e = try env();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env", .data = "secret\n" });
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ok", .data = "ok\n" });
    var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deny = try std.fmt.bufPrint(&p, "{s}/.env", .{s.path});
    const r = try run(e, &.{ "--cwd", s.path, "--read-deny", deny, "ls" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, ".env") == null);

    // A symlink out of the cwd, to a file in no bound tree.
    var other: Scratch = undefined;
    try other.init();
    defer other.deinit();
    try other.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret", .data = "secret\n" });
    var lp: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try s.tmp.dir.symLink(std.testing.io, try std.fmt.bufPrint(&lp, "{s}/secret", .{other.path}), "link", .{});
    const l = try run(e, &.{ "--cwd", s.path, "cat", "link" });
    defer l.deinit();
    try std.testing.expectEqual(1, l.code);
    try std.testing.expectEqualStrings("", l.out);
}

test "masked devices can't be attached" {
    const e = try env();
    const r = try run(e, &.{ "ls", "#U/" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "mount/attach disallowed") != null);
    const n = try run(e, &.{ "--profile=tight", "ls", "#I" });
    defer n.deinit();
    try std.testing.expect(std.mem.indexOf(u8, n.err, "mount/attach disallowed") != null);
}

test "--print shows the plan and doesn't run" {
    const e = try env();
    const r = try run(e, &.{ "--print", "--profile=tight", "--memory", "512m", "--timeout", "1m", "no-such-program" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "profile:  tight\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "net.disable") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "memory=512M timeout=1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "devmask:  #C #I #U\n") != null);
}

test "--strict refuses what this build can't enforce" {
    const e = try env();
    const r = try run(e, &.{ "--strict", "--write=overlay", "echo" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    const ok = try run(e, &.{ "--strict", "--profile=tight", "echo", "ok" });
    defer ok.deinit();
    try std.testing.expectEqual(0, ok.code);
}

test "--memory caps guest memory" {
    const e = try env();
    const r = try run(e, &.{ "--memory", "8m", "echo", "x" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    const ok = try run(e, &.{ "--memory", "64m", "echo", "x" });
    defer ok.deinit();
    try std.testing.expectEqual(0, ok.code);
}

test "--timeout stops the program" {
    const e = try env();
    const r = try run(e, &.{ "--timeout", "200ms", "sleep", "10" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "hp9: timeout") != null);
}

test "renames and case can't get around the rules" {
    const e = try env();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "sub");
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/secret", .data = "secret\n" });
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env", .data = "secret\n" });
    var p1: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var p2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deny1 = try std.fmt.bufPrint(&p1, "{s}/sub/secret", .{s.path});
    const deny2 = try std.fmt.bufPrint(&p2, "{s}/.env", .{s.path});
    const mv = try run(e, &.{ "--cwd", s.path, "--read-deny", deny1, "mv", "sub", "sub2" });
    defer mv.deinit();
    try std.testing.expectEqual(1, mv.code);
    try std.testing.expect(s.exists("sub/secret"));
    // On case-insensitive hosts .ENV is .env; creating it mustn't truncate it.
    const tc = try run(e, &.{ "--cwd", s.path, "--read-deny", deny2, "touch", ".ENV" });
    defer tc.deinit();
    const data = try s.tmp.dir.readFileAlloc(std.testing.io, ".env", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("secret\n", data);
}
