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
const policy = @import("policy.zig");

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
    /// The machine's last run timed out and its process is still stuck in
    /// a host call, so the machine can't run another.
    Stuck,
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
        /// The sandbox policy (DESIGN.md, "Sandbox policy"). Host paths in
        /// it, like `root` and `cwd`, must be absolute and resolved.
        policy: policy.Policy = .{},
        /// Receives a ratrace-style line per syscall.
        trace: ?*std.Io.Writer = null,
        /// On a fault, print the Ureg and a symbolized PC to `stdio.err`.
        dump_on_fault: bool = false,
        stdio: Stdio,
    };

    pub const InitError = vmm.CreateError || error{PolicyConflict};

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
    /// The compiled policy; allocated in `arena`.
    plan: policy.Plan,
    arena: *std.heap.ArenaAllocator,
    msg_buf: [256]u8 = undefined,
    /// Why the last run failed with NamespaceFailed, NotFound or NotExecutable,
    /// or why init failed with PolicyConflict.
    err_msg: []const u8 = "",
    /// Set when a timed-out process couldn't be torn down; see `run`.
    stuck: bool = false,
    /// Holds a returned status message or `err_msg`.
    out_buf: [256]u8 = undefined,

    /// Compiles a policy for a machine with these options, as `init` does,
    /// without creating one (for `--print`).
    pub fn compilePlan(arena: std.mem.Allocator, opts: Options, err_msg: *[]const u8) policy.CompileError!policy.Plan {
        const arch = opts.arch orelse vmm.host_arch orelse .arm64;
        return policy.compile(arena, .{ .root = opts.root, .cwd = opts.cwd, .arch = arch }, opts.policy, err_msg);
    }

    /// On PolicyConflict, `conflict` (if given) explains it.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) InitError!Machine {
        return initExplained(gpa, io, opts, null);
    }

    pub fn initExplained(gpa: std.mem.Allocator, io: std.Io, opts: Options, conflict: ?*[]const u8) InitError!Machine {
        const arch = opts.arch orelse vmm.host_arch orelse return error.WrongArch;
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        errdefer {
            arena.deinit();
            gpa.destroy(arena);
        }
        var msg: []const u8 = "";
        const plan = compilePlan(arena.allocator(), opts, &msg) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Conflict => {
                if (conflict) |c| c.* = msg;
                return error.PolicyConflict;
            },
        };
        const backend = try vmm.create(gpa, io, opts.backend, .{ .arch = arch, .memory = plan.memory });
        return .{ .gpa = gpa, .io = io, .opts = opts, .arch = arch, .backend = backend, .plan = plan, .arena = arena };
    }

    pub fn deinit(m: *Machine) void {
        // A stuck process still uses the backend and the plan, so they're
        // leaked rather than freed under it.
        if (m.stuck) return;
        m.backend.destroy();
        m.arena.deinit();
        m.gpa.destroy(m.arena);
    }

    /// Runs a program to completion. `argv[0]` is the program's name as it
    /// sees it.
    ///
    /// With a timeout in the policy, the process is stopped at the deadline:
    /// its vCPU is kicked and any blocking kernel call is interrupted, and
    /// it's killed with "hp9: timeout". If it's stuck in a host call that
    /// can't be interrupted (a console read, say), `run` returns after a
    /// short grace period anyway and the machine is left `stuck`: the
    /// backend, plan and run state are leaked rather than freed under the
    /// process, and the Machine itself may be dropped. The process can
    /// still touch `argv`, the program bytes, `Stdio` and the trace writer
    /// when its host call returns, so an embedder must keep those alive or
    /// exit, as the CLI does.
    pub fn run(m: *Machine, prog: Program, argv: []const []const u8) RunError!Status {
        if (m.stuck) return error.Stuck;
        // Heap-allocated, with its own copy of the machine, so a stuck
        // process never refers to the caller's Machine.
        const job = try m.gpa.create(Job);
        job.* = .{ .m = undefined, .mc = m.*, .prog = prog, .argv = argv, .con = .{ .in = m.opts.stdio.in, .out = m.opts.stdio.out, .err = m.opts.stdio.err } };
        job.m = &job.mc;
        job.mc.err_msg = "";
        job.con_id = kern.addConsole(&job.con) catch |e| {
            m.gpa.destroy(job);
            return e;
        };
        kern.spawn("hp9", Job, Job.main, job) catch |e| {
            kern.removeConsole(job.con_id);
            m.gpa.destroy(job);
            return e;
        };

        if (m.plan.timeout_ns) |ns| {
            const d: std.Io.Clock.Duration = .{ .raw = .fromNanoseconds(ns), .clock = .awake };
            job.done.waitTimeout(m.io, .{ .duration = d }) catch {
                job.stop();
                // Keep kicking until it notices, for a grace period.
                var waited: u32 = 0;
                while (waited < grace_ms) : (waited += 10) {
                    const tick: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(10), .clock = .awake };
                    if (job.done.waitTimeout(m.io, .{ .duration = tick })) |_| break else |_| job.stop();
                }
                if (!job.done.isSet()) {
                    m.stuck = true;
                    kern.removeConsole(job.con_id);
                    return .{ .killed = timeout_note };
                }
            };
        }
        job.done.waitUncancelable(m.io);
        kern.removeConsole(job.con_id);
        defer m.gpa.destroy(job);
        m.err_msg = m.copyOut(job.mc.err_msg);
        const st = job.result catch |e| return e;
        return switch (st) {
            .exited => |t| .{ .exited = m.copyOut(t) },
            .killed => |t| .{ .killed = m.copyOut(t) },
        };
    }

    fn copyOut(m: *Machine, t: []const u8) []const u8 {
        const n = @min(t.len, m.out_buf.len);
        @memmove(m.out_buf[0..n], t[0..n]);
        return m.out_buf[0..n];
    }

    const timeout_note = "hp9: timeout";
    const grace_ms = 500;

    const Job = struct {
        /// Points at `mc`.
        m: *Machine,
        mc: Machine,
        prog: Program,
        argv: []const []const u8,
        con: kern.Console,
        con_id: u32 = 0,
        result: RunError!Status = error.Kern,
        done: std.Io.Event = .unset,
        /// Set at the deadline; the exit loop checks it after every exit.
        timed_out: std.atomic.Value(bool) = .init(false),
        /// The running process's Proc and vCPU, for `stop`. Guarded by `lock`.
        lock: std.atomic.Mutex = .unlocked,
        proc: ?*kern.Proc = null,
        vcpu: ?*vmm.Vcpu = null,

        fn main(j: *Job) void {
            j.result = j.m.process(j);
            // err_msg can be the Proc's errstr, which goes when it exits.
            const e = j.m.err_msg;
            if (e.len > 0 and !(@intFromPtr(e.ptr) >= @intFromPtr(&j.m.msg_buf) and @intFromPtr(e.ptr) < @intFromPtr(&j.m.msg_buf) + j.m.msg_buf.len)) {
                j.m.err_msg = j.m.keep(e);
            }
            j.lockSpin();
            j.proc = null;
            j.vcpu = null;
            j.lock.unlock();
            j.done.set(j.m.io);
        }

        fn lockSpin(j: *Job) void {
            while (!j.lock.tryLock()) std.atomic.spinLoopHint();
        }

        /// Stops the process at the deadline. Safe from any thread.
        fn stop(j: *Job) void {
            j.timed_out.store(true, .release);
            j.lockSpin();
            defer j.lock.unlock();
            if (j.vcpu) |v| v.kick();
            if (j.proc) |p| kern.interrupt(p);
        }

        fn attach(j: *Job, v: ?*vmm.Vcpu) void {
            j.lockSpin();
            defer j.lock.unlock();
            j.proc = kern.self();
            j.vcpu = v;
        }
    };

    /// Runs on the process's kernel thread.
    fn process(m: *Machine, j: *Job) RunError!Status {
        // devfs checks this thread's accesses against the plan.
        kern.setPlan(&m.plan);
        defer kern.setPlan(null);
        j.attach(null);
        if (j.timed_out.load(.acquire)) return .{ .killed = timeout_note };
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
        j.attach(&vcpu);
        defer j.attach(null);

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
            if (j.timed_out.load(.acquire)) return .{ .killed = timeout_note };
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
                .fault => |f| {
                    if (m.opts.dump_on_fault) dumpFault(m.opts.stdio.err, &u, f, bytes);
                    return .{ .killed = try std.fmt.bufPrint(&m.msg_buf, "sys: trap: fault {t} addr=0x{x} pc=0x{x}", .{ f.access, f.addr, u.pc() }) };
                },
                .interrupted => {},
                .halted => return .{ .killed = "halted" },
                .other => |code| return .{ .killed = try std.fmt.bufPrint(&m.msg_buf, "sys: trap: unexpected exit 0x{x} pc=0x{x}", .{ code, u.pc() }) },
            }
        }
    }

    fn keep(m: *Machine, s: []const u8) []const u8 {
        const n = @min(s.len, m.msg_buf.len);
        @memmove(m.msg_buf[0..n], s[0..n]);
        return m.msg_buf[0..n];
    }

    fn fail(m: *Machine, comptime fmt: []const u8, args: anytype) error{NamespaceFailed} {
        m.err_msg = std.fmt.bufPrint(&m.msg_buf, fmt, args) catch fmt;
        return error.NamespaceFailed;
    }

    /// Builds the first Proc's namespace from the plan (DESIGN.md, "Boot
    /// sequence"), then sets the device mask.
    fn buildNamespace(m: *Machine, con_id: u32) RunError!void {
        var buf: [std.fs.max_path_bytes + 8]u8 = undefined;
        var buf2: [std.fs.max_path_bytes + 8]u8 = undefined;
        var cwd_at: ?[:0]const u8 = null;
        for (m.plan.binds) |b| {
            const from = if (b.console)
                try std.fmt.bufPrintZ(&buf, "{s}{d}", .{ b.from, con_id })
            else
                try std.fmt.bufPrintZ(&buf, "{s}", .{b.from});
            var flag: c_int = switch (b.flag) {
                .repl => kern.MREPL,
                .before => kern.MBEFORE,
                .after => kern.MAFTER,
            };
            if (b.create) flag |= kern.MCREATE;
            const to = try std.fmt.bufPrintZ(&buf2, "{s}", .{b.to});
            if (kern.bind(from, to, flag)) |_| {
                if (std.mem.eql(u8, b.to, "/mnt/term/cwd")) cwd_at = "/mnt/term/cwd";
                continue;
            } else |_| {}
            if (b.fallback) |fb| {
                if (kern.bind(from, try std.fmt.bufPrintZ(&buf2, "{s}", .{fb}), flag)) |_| {
                    if (std.mem.eql(u8, b.to, "/mnt/term/cwd")) cwd_at = "/mnt/term";
                    continue;
                } else |_| {}
            }
            if (!b.optional) return m.fail("bind {s} {s}: {s}", .{ b.from, b.to, kern.errstr() });
        }
        if (cwd_at) |at| kern.chdir(at) catch return m.fail("cwd: {s}", .{kern.errstr()});

        // fds 0-2 on the console.
        const in = kern.open("/dev/cons", kern.OREAD) catch return m.fail("open /dev/cons: {s}", .{kern.errstr()});
        const out = kern.open("/dev/cons", kern.OWRITE) catch return m.fail("open /dev/cons: {s}", .{kern.errstr()});
        const err = kern.open("/dev/stderr", kern.OWRITE) catch return m.fail("open /dev/stderr: {s}", .{kern.errstr()});
        if (in != 0 or out != 1 or err != 2) return m.fail("console fds are {d} {d} {d}", .{ in, out, err });

        try m.setEnv();

        // Existing binds keep working, but masked devices can't be attached
        // again to reach more of the host.
        if (m.plan.devmask.len > 0) kern.devmask(try std.fmt.bufPrintZ(&buf, "{s}", .{m.plan.devmask}));
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

/// Prints a fault for `--dump-on-fault`: the Ureg, the faulting address and
/// the PC symbolized from the a.out symbol table.
fn dumpFault(w: *std.Io.Writer, u: *const vmm.Ureg, f: vmm.Fault, bytes: []const u8) void {
    dumpFaultTo(w, u, f, bytes) catch {};
    w.flush() catch {};
}

fn dumpFaultTo(w: *std.Io.Writer, u: *const vmm.Ureg, f: vmm.Fault, bytes: []const u8) std.Io.Writer.Error!void {
    try w.print("hp9: fault: {t} addr=0x{x} syndrome=0x{x}\n", .{ f.access, f.addr, f.syndrome });
    try w.writeAll("hp9: pc ");
    try writeSym(w, bytes, u.pc());
    try w.writeAll("\n");
    switch (u.*) {
        .arm64 => |r| {
            for (r.r, 0..) |v, i| {
                try w.print("R{d}\t0x{x:0>16}", .{ i, v });
                try w.writeAll(if (i % 4 == 3) "\n" else "  ");
            }
            try w.print("\nSP\t0x{x:0>16}  PC\t0x{x:0>16}  PSR\t0x{x:0>16}  TYPE\t0x{x:0>16}\n", .{ r.sp, r.pc, r.psr, r.type });
            try w.writeAll("hp9: lr ");
            try writeSym(w, bytes, r.r[30]);
            try w.writeAll("\n");
        },
        .amd64 => |r| {
            inline for (.{ "ax", "bx", "cx", "dx", "si", "di", "bp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "pc", "sp", "flags" }, 0..) |name, i| {
                try w.print("{s}\t0x{x:0>16}", .{ name, @field(r, name) });
                try w.writeAll(if (i % 4 == 3) "\n" else "  ");
            }
            try w.writeAll("\n");
        },
    }
}

fn writeSym(w: *std.Io.Writer, bytes: []const u8, addr: u64) std.Io.Writer.Error!void {
    if (aout.symbolize(bytes, addr)) |s| {
        try w.print("0x{x} {s}+0x{x}", .{ addr, s.name, addr - s.value });
    } else try w.print("0x{x}", .{addr});
}
