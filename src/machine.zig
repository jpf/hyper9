//! One machine: a VM running 9front processes whose syscalls are served by
//! drawterm's kern. See DESIGN.md, "Process model" and "Filesystem, boot
//! and I/O".
//!
//! M2 runs one process. It runs on its own kernel thread (kern.spawn),
//! which builds the machine's namespace, loads the binary, creates the vCPU
//! and runs the exit loop; Machine.run waits for it.

const std = @import("std");
const vmm = @import("vmm.zig");
const loader = @import("loader.zig");
const aout = @import("aout.zig");
const kern = @import("kern.zig");
const syscall = @import("syscall.zig");

pub const Status = union(enum) {
    /// The `exits` string; empty means success.
    exited: []const u8,
    /// The process died; the message is in Plan 9 note form.
    killed: []const u8,
};

/// What to run.
pub const Program = union(enum) {
    /// The bytes of an a.out read on the host (`./prog`).
    bytes: []const u8,
    /// A guest path or name, resolved in the machine's namespace: names
    /// without a leading `/`, `./` or `../` are searched along `$path`.
    guest: []const u8,
};

pub const EnvVar = struct { name: []const u8, value: []const u8 };

pub const RunError = error{
    /// The guest program wasn't found (exit code 127).
    NotFound,
    /// The program isn't a runnable a.out for this machine (exit code 126).
    NotExecutable,
    /// The namespace couldn't be built (bad root or cwd); see `err_msg`.
    NamespaceFailed,
    TooManyMachines,
    NoSpaceLeft,
} || kern.Error || vmm.CreateError || loader.Error;

pub const Machine = struct {
    pub const Options = struct {
        backend: vmm.BackendKind = .auto,
        /// Architecture of the binaries this machine runs; null means the host's.
        arch: ?vmm.Arch = null,
        /// Host directory served as the guest's /. Without one the machine
        /// has only devices, so only host-path programs can run.
        root: ?[]const u8 = null,
        /// Host directory bound at /mnt/term/cwd and made the guest's cwd.
        cwd: ?[]const u8 = null,
        /// Guest environment variables, beyond the defaults.
        env: []const EnvVar = &.{},
        /// Receives a ratrace-style line per syscall.
        trace: ?*std.Io.Writer = null,
        stdio: Stdio,
    };

    /// Host streams behind the guest's console: reads from `in` (none means
    /// EOF), writes to fd 1 go to `out` and to fd 2 to `err`.
    pub const Stdio = struct {
        in: ?*std.Io.Reader = null,
        out: *std.Io.Writer,
        err: *std.Io.Writer,
    };

    gpa: std.mem.Allocator,
    io: std.Io,
    backend: vmm.Backend,
    arch: vmm.Arch,
    opts: Options,
    msg_buf: [256]u8 = undefined,
    /// Why the last run failed with NamespaceFailed, NotFound or NotExecutable.
    err_msg: []const u8 = "",

    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) vmm.CreateError!Machine {
        const arch = opts.arch orelse vmm.host_arch orelse return error.WrongArch;
        const backend = try vmm.create(gpa, io, opts.backend, .{ .arch = arch });
        return .{ .gpa = gpa, .io = io, .opts = opts, .arch = arch, .backend = backend };
    }

    pub fn deinit(m: *Machine) void {
        m.backend.destroy();
    }

    /// Runs a program to completion. `argv[0]` is the program's name as it
    /// sees it.
    pub fn run(m: *Machine, prog: Program, argv: []const []const u8) RunError!Status {
        var con: kern.Console = .{ .in = m.opts.stdio.in, .out = m.opts.stdio.out, .err = m.opts.stdio.err };
        const con_id = try kern.addConsole(&con);
        defer kern.removeConsole(con_id);

        var job: Job = .{ .m = m, .prog = prog, .argv = argv, .con_id = con_id };
        try kern.spawn("hp9", Job, Job.main, &job);
        job.done.wait(m.io) catch {};
        return job.result;
    }

    const Job = struct {
        m: *Machine,
        prog: Program,
        argv: []const []const u8,
        con_id: u32,
        result: RunError!Status = error.Kern,
        done: std.Io.Event = .unset,

        fn main(j: *Job) void {
            j.result = j.m.process(j);
            j.done.set(j.m.io);
        }
    };

    /// Runs on the process's kernel thread.
    fn process(m: *Machine, j: *Job) RunError!Status {
        try m.buildNamespace(j.con_id);

        var arena: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena.deinit();
        const bytes = switch (j.prog) {
            .bytes => |b| b,
            .guest => |name| try m.readGuest(arena.allocator(), name),
        };
        const hdr = aout.parse(bytes) catch {
            m.err_msg = "not a 9front executable";
            return error.NotExecutable;
        };
        if (hdr.arch != m.arch) {
            m.err_msg = "wrong architecture";
            return error.NotExecutable;
        }

        const as = try m.backend.newAddressSpace();
        defer as.destroy();
        // pids are per machine; the first process is 1 (rfork numbers the
        // rest from M3).
        const pid = 1;
        const img = try loader.load(m.backend, as, bytes, j.argv, pid);

        var vcpu = try m.backend.createVcpu();
        defer vcpu.destroy();
        try vcpu.setAddressSpace(as);

        var p: syscall.Process = .{
            .pid = pid,
            .backend = m.backend,
            .as = as,
            .brk = img.ebss,
            .brk_floor = img.data_base,
            .brk_limit = aout.layout(m.arch).ustktop - aout.layout(m.arch).stack_size,
            .trace = m.opts.trace,
        };
        var u: vmm.Ureg = .initExec(img.arch, img.entry, img.sp, img.tos);
        vcpu.setUreg(&u);
        while (true) {
            const exit = try vcpu.run();
            vcpu.getUreg(&u);
            switch (exit) {
                .syscall => switch (syscall.dispatch(&p, &u)) {
                    .ret => |r| {
                        u.setReturn(r);
                        vcpu.setUreg(&u);
                    },
                    .exits => |s| return .{ .exited = m.keep(s) },
                    .killed => |s| return .{ .killed = m.keep(s) },
                },
                .fault => |f| return .{ .killed = try std.fmt.bufPrint(&m.msg_buf, "sys: trap: fault {t} addr=0x{x} pc=0x{x}", .{ f.access, f.addr, u.pc() }) },
                .interrupted => {},
                .halted => return .{ .killed = "halted" },
                .other => |code| return .{ .killed = try std.fmt.bufPrint(&m.msg_buf, "sys: trap: unexpected exit 0x{x} pc=0x{x}", .{ code, u.pc() }) },
            }
        }
    }

    fn keep(m: *Machine, s: []const u8) []const u8 {
        const n = @min(s.len, m.msg_buf.len);
        @memcpy(m.msg_buf[0..n], s[0..n]);
        return m.msg_buf[0..n];
    }

    fn fail(m: *Machine, comptime fmt: []const u8, args: anytype) error{NamespaceFailed} {
        m.err_msg = std.fmt.bufPrint(&m.msg_buf, fmt, args) catch fmt;
        return error.NamespaceFailed;
    }

    /// Builds the first Proc's namespace (DESIGN.md, "Boot sequence"). This
    /// boot namespace is provisional until the policy's namespace builder
    /// and device mask replace it.
    fn buildNamespace(m: *Machine, con_id: u32) RunError!void {
        var buf: [std.fs.max_path_bytes + 8]u8 = undefined;
        if (m.opts.root) |root| {
            kern.bind(try std.fmt.bufPrintZ(&buf, "#U{s}", .{root}), "/", kern.MREPL) catch
                return m.fail("root {s}: {s}", .{ root, kern.errstr() });
        }
        // Devices. The console device goes over #c, so /dev/cons is ours.
        bindDev("#c", "/dev", kern.MREPL);
        kern.bind(try std.fmt.bufPrintZ(&buf, "#y{d}", .{con_id}), "/dev", kern.MBEFORE) catch
            return m.fail("console: {s}", .{kern.errstr()});
        bindDev("#e", "/env", kern.MREPL | kern.MCREATE);
        bindDev("#|", "/fd", kern.MREPL);
        bindDev("#I", "/net", kern.MREPL);
        if (m.opts.root != null) {
            const bin = try std.fmt.bufPrintZ(&buf, "/{s}/bin", .{@tagName(m.arch)});
            bindDev(bin, "/bin", kern.MREPL);
            bindDev("/rc/bin", "/bin", kern.MAFTER);
        }
        // The host cwd goes at /mnt/term/cwd. Trees made before mkroot.py
        // added that mount point lack it, so it falls back to /mnt/term.
        // Without a root tree there's nowhere to bind it.
        if (m.opts.root == null) {} else if (m.opts.cwd) |cwd| {
            const spec = try std.fmt.bufPrintZ(&buf, "#U{s}", .{cwd});
            const at: [:0]const u8 = for ([_][:0]const u8{ "/mnt/term/cwd", "/mnt/term" }) |dir| {
                if (kern.bind(spec, dir, kern.MREPL)) |_| break dir else |_| {}
            } else return m.fail("cwd {s}: {s}", .{ cwd, kern.errstr() });
            kern.chdir(at) catch return m.fail("cwd: {s}", .{kern.errstr()});
        }

        // fds 0-2 on the console.
        const in = kern.open("/dev/cons", kern.OREAD) catch return m.fail("open /dev/cons: {s}", .{kern.errstr()});
        const out = kern.open("/dev/cons", kern.OWRITE) catch return m.fail("open /dev/cons: {s}", .{kern.errstr()});
        const err = kern.open("/dev/stderr", kern.OWRITE) catch return m.fail("open /dev/stderr: {s}", .{kern.errstr()});
        if (in != 0 or out != 1 or err != 2) return m.fail("console fds are {d} {d} {d}", .{ in, out, err });

        try m.setEnv();
    }

    /// Binds that are fine to miss (a root without /net, say).
    fn bindDev(old: [*:0]const u8, new: [*:0]const u8, flag: c_int) void {
        kern.bind(old, new, flag) catch {};
    }

    fn setEnv(m: *Machine) RunError!void {
        const user = kern.user();
        var home_buf: [96]u8 = undefined;
        const defaults = [_]EnvVar{
            .{ .name = "user", .value = user },
            .{ .name = "home", .value = std.fmt.bufPrint(&home_buf, "/usr/{s}", .{user}) catch "/" },
            .{ .name = "cputype", .value = @tagName(m.arch) },
            .{ .name = "objtype", .value = @tagName(m.arch) },
            .{ .name = "sysname", .value = "hp9" },
            .{ .name = "service", .value = "terminal" },
        };
        for (defaults) |e| try putEnv(e.name, e.value);
        // As 9front's boot does: the local timezone, for date and ls -l.
        copyFile("/adm/timezone/local", "/env/timezone");
        // rc lists end each element with a NUL: path=(. /bin).
        try putEnv("path", ".\x00/bin\x00");
        for (m.opts.env) |e| try putEnv(e.name, e.value);
    }

    fn putEnv(name: []const u8, value: []const u8) RunError!void {
        var buf: [kern.ERRMAX + 8]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "/env/{s}", .{name}) catch return error.NamespaceFailed;
        const fd = kern.create(path, kern.OWRITE, 0o664) catch return;
        defer kern.close(fd) catch {};
        _ = kern.pwrite(fd, value, 0) catch {};
    }

    fn copyFile(from: [:0]const u8, to: [:0]const u8) void {
        const in = kern.open(from, kern.OREAD) catch return;
        defer kern.close(in) catch {};
        var buf: [4096]u8 = undefined;
        const n = kern.pread(in, &buf, 0) catch return;
        const out = kern.create(to, kern.OWRITE, 0o664) catch return;
        defer kern.close(out) catch {};
        _ = kern.pwrite(out, buf[0..n], 0) catch {};
    }

    /// Reads a guest program, searching $path for bare names.
    fn readGuest(m: *Machine, gpa: std.mem.Allocator, name: []const u8) RunError![]u8 {
        var buf: [1024]u8 = undefined;
        const direct = name.len > 0 and (name[0] == '/' or std.mem.startsWith(u8, name, "./") or std.mem.startsWith(u8, name, "../"));
        if (direct) {
            return readFile(gpa, std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch return error.NotFound) catch |e| {
                m.err_msg = kern.errstr();
                return e;
            };
        }
        var last: RunError = error.NotFound;
        for ([_][]const u8{ ".", "/bin" }) |dir| {
            const path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch continue;
            if (readFile(gpa, path)) |b| return b else |e| last = e;
        }
        m.err_msg = "file does not exist";
        return last;
    }

    fn readFile(gpa: std.mem.Allocator, path: [:0]const u8) RunError![]u8 {
        var dbuf: [512]u8 = undefined;
        const n = kern.stat(path, &dbuf) catch return error.NotFound;
        // Dir: size[2] type[2] dev[4] qid[13] mode[4] ... length[8] at 2+2+4+13+4+4+4 = 33.
        if (n < 41) return error.NotExecutable;
        const mode = std.mem.readInt(u32, dbuf[21..25], .little);
        if (mode & 0x80000000 != 0) return error.NotExecutable;
        const len = std.mem.readInt(u64, dbuf[33..41], .little);
        if (len > 1 << 30) return error.NotExecutable;
        const fd = kern.open(path, kern.OREAD) catch return error.NotExecutable;
        defer kern.close(fd) catch {};
        const bytes = try gpa.alloc(u8, len);
        var off: usize = 0;
        while (off < len) {
            const got = kern.pread(fd, bytes[off..], @intCast(off)) catch return error.NotExecutable;
            if (got == 0) break;
            off += got;
        }
        return bytes[0..off];
    }
};
