//! Command-line parsing: argv to a Config, with no I/O. See DESIGN.md, "CLI".

const std = @import("std");
const builtin = @import("builtin");
const vmm = @import("hp9").vmm;
const policy = @import("hp9").policy;

pub const usage =
    \\usage: hp9 [--backend auto|hvf|kvm|whp|emu] [--root DIR] [--cwd DIR]
    \\           [--env name=value]... [--profile default|tight] [--sandbox DIR]
    \\           [--readable PATH]... [--writable PATH]... [--read-deny PATH]...
    \\           [--write none|scope|ephemeral|overlay] [--net disable|outbound|enable]
    \\           [--memory SIZE] [--timeout DURATION] [--pids N] [--cpus N]
    \\           [--ns FILE] [--host-fs] [--host-cmd]
    \\           [--strict] [--print] [--trace[=FILE]] [--dump-on-fault]
    \\           [--] program [args...]
    \\       hp9 [flags] --rc 'command' [args...]
    \\       hp9 [--backend B] [--root DIR] [--memory SIZE] --check
    \\       hp9 --version
    \\       hp9 --help
    \\
;

/// What hp9 does: run a program, or one of the tool functions.
pub const Mode = enum {
    run,
    /// --check: probe the backends and the root tree, and run a program.
    check,
    /// --version: print the version, the pins and the backends.
    version,
    /// --help, or -h as the only argument: print the usage to stdout.
    help,
};

pub const Config = struct {
    mode: Mode = .run,
    backend: vmm.BackendKind = .auto,
    /// --trace: null for none, "" for stderr, else a file.
    trace: ?[]const u8 = null,
    dump_on_fault: bool = false,
    /// --root; null means $HP9ROOT, then the default.
    root: ?[]const u8 = null,
    /// --cwd: the host directory bound at /mnt/term/cwd; null means the
    /// host cwd.
    cwd: ?[]const u8 = null,
    /// --env values, as name=value.
    env: []const []const u8 = &.{},
    profile: policy.Profile = .default,
    /// --sandbox DIR: the tight profile with DIR as the writable cwd.
    sandbox: ?[]const u8 = null,
    readable: []const []const u8 = &.{},
    writable: []const []const u8 = &.{},
    read_deny: []const []const u8 = &.{},
    write: ?policy.WriteMode = null,
    net: ?policy.NetMode = null,
    memory: ?u64 = null,
    timeout_ns: ?u64 = null,
    pids: ?u32 = null,
    cpus: ?u32 = null,
    /// --ns: a namespace file, in newns syntax, replayed before the program.
    ns: ?[]const u8 = null,
    host_fs: bool = false,
    host_cmd: bool = false,
    strict: bool = false,
    print: bool = false,
    /// --rc: the command line for /bin/rc -c.
    rc: ?[]const u8 = null,
    /// The program followed by its arguments; with --rc, the arguments
    /// that become $*.
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
    // Windows spells them .\ and ..\ too.
    if (builtin.os.tag == .windows and (std.mem.startsWith(u8, arg, ".\\") or std.mem.startsWith(u8, arg, "..\\"))) return .host;
    return .guest;
}

pub fn parse(gpa: std.mem.Allocator, args: []const []const u8) Error!Config {
    var c: Config = .{ .argv = &.{} };
    var env: std.ArrayList([]const u8) = .empty;
    var readable: std.ArrayList([]const u8) = .empty;
    var writable: std.ArrayList([]const u8) = .empty;
    var read_deny: std.ArrayList([]const u8) = .empty;
    // Long flags only (DESIGN.md, "Parsing rules"); -h is accepted alone,
    // where it can't be a program's flag.
    if (args.len == 2 and std.mem.eql(u8, args[1], "-h")) return .{ .mode = .help, .argv = &.{} };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!std.mem.startsWith(u8, a, "--")) break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else if (std.mem.eql(u8, a, "--trace")) {
            c.trace = "";
        } else if (std.mem.startsWith(u8, a, "--trace=")) {
            c.trace = a["--trace=".len..];
            if (c.trace.?.len == 0) return error.Usage;
        } else if (flag(a, "--dump-on-fault")) {
            c.dump_on_fault = true;
        } else if (flag(a, "--host-fs")) {
            c.host_fs = true;
        } else if (flag(a, "--host-cmd")) {
            c.host_cmd = true;
        } else if (flag(a, "--strict")) {
            c.strict = true;
        } else if (flag(a, "--print")) {
            c.print = true;
        } else if (flag(a, "--check")) {
            if (c.mode != .run) return error.Usage;
            c.mode = .check;
        } else if (flag(a, "--version")) {
            if (c.mode != .run) return error.Usage;
            c.mode = .version;
        } else if (flag(a, "--help")) {
            if (c.mode != .run) return error.Usage;
            c.mode = .help;
        } else if (value(args, &i, "--backend")) |v| {
            c.backend = try enumValue(vmm.BackendKind, v);
        } else if (value(args, &i, "--root")) |v| {
            c.root = v orelse return error.Usage;
        } else if (value(args, &i, "--cwd")) |v| {
            c.cwd = v orelse return error.Usage;
        } else if (value(args, &i, "--env")) |v| {
            const e = v orelse return error.Usage;
            const eq = std.mem.indexOfScalar(u8, e, '=') orelse return error.Usage;
            if (eq == 0 or std.mem.indexOfScalar(u8, e[0..eq], '/') != null) return error.Usage;
            try env.append(gpa, e);
        } else if (value(args, &i, "--profile")) |v| {
            c.profile = try enumValue(policy.Profile, v);
        } else if (value(args, &i, "--sandbox")) |v| {
            c.sandbox = v orelse return error.Usage;
        } else if (value(args, &i, "--readable")) |v| {
            try readable.append(gpa, v orelse return error.Usage);
        } else if (value(args, &i, "--writable")) |v| {
            try writable.append(gpa, v orelse return error.Usage);
        } else if (value(args, &i, "--read-deny")) |v| {
            try read_deny.append(gpa, v orelse return error.Usage);
        } else if (value(args, &i, "--write")) |v| {
            c.write = try enumValue(policy.WriteMode, v);
        } else if (value(args, &i, "--net")) |v| {
            c.net = try enumValue(policy.NetMode, v);
        } else if (value(args, &i, "--memory")) |v| {
            c.memory = policy.parseSize(v orelse return error.Usage) orelse return error.Usage;
        } else if (value(args, &i, "--timeout")) |v| {
            c.timeout_ns = policy.parseDuration(v orelse return error.Usage) orelse return error.Usage;
            if (c.timeout_ns == 0) return error.Usage;
        } else if (value(args, &i, "--pids")) |v| {
            c.pids = try count(v);
        } else if (value(args, &i, "--cpus")) |v| {
            c.cpus = try count(v);
        } else if (value(args, &i, "--ns")) |v| {
            c.ns = v orelse return error.Usage;
        } else if (value(args, &i, "--rc")) |v| {
            c.rc = v orelse return error.Usage;
        } else {
            return error.Usage;
        }
    }
    if (c.sandbox != null) {
        if (c.host_fs or c.host_cmd or c.cwd != null) return error.Usage;
        c.profile = .tight;
    }
    // The tool functions take no program, so `hp9 --check ls` is a mistake.
    if (c.mode != .run) {
        if (c.rc != null or i < args.len) return error.Usage;
    } else if (c.rc == null and i >= args.len) return error.Usage;
    c.env = try env.toOwnedSlice(gpa);
    c.readable = try readable.toOwnedSlice(gpa);
    c.writable = try writable.toOwnedSlice(gpa);
    c.read_deny = try read_deny.toOwnedSlice(gpa);
    c.argv = args[i..];
    return c;
}

fn flag(a: []const u8, comptime name: []const u8) bool {
    return std.mem.eql(u8, a, name);
}

/// A positive count, for --pids and --cpus.
fn count(v: ?[]const u8) Error!u32 {
    const n = std.fmt.parseInt(u32, v orelse return error.Usage, 10) catch return error.Usage;
    return if (n == 0) error.Usage else n;
}

fn enumValue(comptime E: type, v: ?[]const u8) Error!E {
    return std.meta.stringToEnum(E, v orelse return error.Usage) orelse error.Usage;
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
    try t.expectEqualStrings("", c.trace.?);
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

test "policy flags" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(), &.{
        "hp9",      "--profile=tight", "--writable",    "./out",           "--readable=/src", "--read-deny", "/src/.env",
        "--memory", "512m",            "--timeout",     "1m",              "--net=disable",   "--write",     "scope",
        "--strict", "--print",         "--trace=t.log", "--dump-on-fault", "mk",
    });
    try t.expectEqual(policy.Profile.tight, c.profile);
    try t.expectEqualStrings("./out", c.writable[0]);
    try t.expectEqualStrings("/src", c.readable[0]);
    try t.expectEqualStrings("/src/.env", c.read_deny[0]);
    try t.expectEqual(@as(?u64, 512 << 20), c.memory);
    try t.expectEqual(@as(?u64, std.time.ns_per_min), c.timeout_ns);
    try t.expectEqual(@as(?policy.NetMode, .disable), c.net);
    try t.expectEqual(@as(?policy.WriteMode, .scope), c.write);
    try t.expect(c.strict and c.print and c.dump_on_fault);
    try t.expectEqualStrings("t.log", c.trace.?);
    try t.expectEqualStrings("mk", c.argv[0]);
}

test "--sandbox and --rc" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try parse(a, &.{ "hp9", "--sandbox", "/w", "--rc", "echo x > f" });
    try t.expectEqual(policy.Profile.tight, c.profile);
    try t.expectEqualStrings("/w", c.sandbox.?);
    try t.expectEqualStrings("echo x > f", c.rc.?);
    try t.expectEqual(@as(usize, 0), c.argv.len);
    try t.expectError(error.Usage, parse(a, &.{ "hp9", "--sandbox", "/w", "--host-fs", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "hp9", "--sandbox", "/w", "--host-cmd", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "hp9", "--memory", "lots", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "hp9", "--timeout", "0", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "hp9", "--write", "maybe", "ls" }));
}

test "--pids, --cpus and --ns" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try parse(a, &.{ "hp9", "--pids", "32", "--cpus=2", "--ns", "ns", "rc" });
    try t.expectEqual(@as(?u32, 32), c.pids);
    try t.expectEqual(@as(?u32, 2), c.cpus);
    try t.expectEqualStrings("ns", c.ns.?);
    try t.expectError(error.Usage, parse(a, &.{ "hp9", "--pids", "0", "rc" }));
    try t.expectError(error.Usage, parse(a, &.{ "hp9", "--cpus", "x", "rc" }));
    try t.expectError(error.Usage, parse(a, &.{ "hp9", "--ns" }));
}

test "--check and --version" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(Mode.version, (try parse(a, &.{ "hp9", "--version" })).mode);
    const c = try parse(a, &.{ "hp9", "--backend", "emu", "--root=/r", "--check" });
    try t.expectEqual(Mode.check, c.mode);
    try t.expectEqual(vmm.BackendKind.emu, c.backend);
    try t.expectEqualStrings("/r", c.root.?);
    try t.expectEqual(Mode.run, (try parse(a, &.{ "hp9", "ls" })).mode);
    // A flag after the program is the program's.
    try t.expectEqual(Mode.run, (try parse(a, &.{ "hp9", "ls", "--version" })).mode);
    try t.expectError(error.Usage, parse(a, &.{ "hp9", "--check", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "hp9", "--version", "--rc", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "hp9", "--check", "--version" }));
}

test "--help and -h" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(Mode.help, (try parse(a, &.{ "hp9", "--help" })).mode);
    try t.expectEqual(Mode.help, (try parse(a, &.{ "hp9", "-h" })).mode);
    // -h counts only alone; anywhere else it's a program name or argument.
    try t.expectEqualStrings("-h", (try parse(a, &.{ "hp9", "--backend", "emu", "-h" })).argv[0]);
    const c = try parse(a, &.{ "hp9", "ls", "-h" });
    try t.expectEqual(Mode.run, c.mode);
    try t.expectEqualStrings("-h", c.argv[1]);
    try t.expectError(error.Usage, parse(a, &.{ "hp9", "--help", "ls" }));
}

test "program kinds" {
    try t.expectEqual(ProgramKind.host, programKind("./hello"));
    try t.expectEqual(ProgramKind.host, programKind("../out/x"));
    try t.expectEqual(ProgramKind.guest, programKind("/bin/cat"));
    try t.expectEqual(ProgramKind.guest, programKind("cat"));
    try t.expectEqual(ProgramKind.guest, programKind("aux/vga"));
}
