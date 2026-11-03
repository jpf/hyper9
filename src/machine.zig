//! One machine: a VM running 9front processes whose syscalls are served by
//! drawterm's kern. See DESIGN.md, "Process model" and "Filesystem, boot
//! and I/O".
//!
//! Each guest process runs on its own kernel thread with its own vCPU. The
//! first is made with kern.spawn: it builds the machine's namespace, loads
//! the program and runs the exit loop. rfork makes the others with
//! kern.fork, and they run the same loop. Machine.run waits for the first
//! to exit, then stops the rest.

const std = @import("std");
const vmm = @import("vmm.zig");
const loader = @import("loader.zig");
const aout = @import("aout.zig");
const kern = @import("kern.zig");
const syscall = @import("syscall.zig");
const policy = @import("policy.zig");
const segment = @import("segment.zig");
const newns = @import("newns.zig");
const cpupool = @import("cpupool.zig");

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
        /// A namespace file (newns syntax, src/newns.zig) to replay in the
        /// first process after the policy's namespace is built and before
        /// the program is looked up. It's a guest path, read as newns
        /// would, so a relative one is in the guest's cwd.
        ns: ?[]const u8 = null,
        /// How many processes may own a vCPU before the rest share the
        /// pool (src/cpupool.zig); null means the backend's limit less the
        /// pool. For tests of the pool.
        owned_vcpus: ?u32 = null,
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
    err_buf: [256]u8 = undefined,
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
        const pool = cpupool.Pool.init(m.gpa, m.io, m.backend, m.plan.cpus, m.opts.owned_vcpus) catch |e| {
            m.gpa.destroy(job);
            return e;
        };
        job.* = .{ .m = undefined, .mc = m.*, .prog = prog, .argv = argv, .con = .{ .in = m.opts.stdio.in, .out = m.opts.stdio.out, .err = m.opts.stdio.err }, .pool = pool };
        job.pool.gpa = m.gpa;
        job.m = &job.mc;
        job.mc.err_msg = "";
        job.con_id = kern.addConsole(&job.con) catch |e| {
            m.gpa.destroy(job);
            return e;
        };
        const first = job.newProc() catch |e| {
            kern.removeConsole(job.con_id);
            job.pool.deinit();
            m.gpa.destroy(job);
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.TooManyProcs => unreachable, // the cap is at least 1
            };
        };
        kern.spawn("hp9", Proc, firstMain, first) catch |e| {
            job.dropProc(first);
            kern.removeConsole(job.con_id);
            job.procs.deinit(m.gpa);
            job.pool.deinit();
            m.gpa.destroy(job);
            return e;
        };

        var timed_out = false;
        if (m.plan.timeout_ns) |ns| {
            const d: std.Io.Clock.Duration = .{ .raw = .fromNanoseconds(ns), .clock = .awake };
            job.first_done.waitTimeout(m.io, .{ .duration = d }) catch {
                job.timed_out.store(true, .release);
                timed_out = true;
            };
        }
        if (!timed_out) job.first_done.waitUncancelable(m.io);
        // The machine ends with its first process: any others are stopped,
        // as at a timeout.
        job.stopAll();
        if (!job.waitAll()) {
            m.stuck = true;
            kern.removeConsole(job.con_id);
            return .{ .killed = timeout_note };
        }
        kern.removeConsole(job.con_id);
        defer {
            job.procs.deinit(m.gpa);
            job.pool.deinit();
            m.gpa.destroy(job);
        }
        if (timed_out) return .{ .killed = timeout_note };
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
    const stopped_note = "hp9: machine stopped";
    const grace_ms = 500;

    /// One run of the machine: its process tree and console.
    const Job = struct {
        /// Points at `mc`.
        m: *Machine,
        mc: Machine,
        prog: Program,
        argv: []const []const u8,
        con: kern.Console,
        con_id: u32 = 0,
        /// The first process's outcome, set before `first_done`.
        result: RunError!Status = error.Kern,
        first_done: std.Io.Event = .unset,
        /// Set when the last process has exited.
        all_done: std.Io.Event = .unset,
        timed_out: std.atomic.Value(bool) = .init(false),
        /// Set to end every process; exit loops check it after every exit.
        stopping: std.atomic.Value(bool) = .init(false),
        /// Guards `procs`, `next_pid` and each Proc's `kproc` and `lease`.
        lock: std.atomic.Mutex = .unlocked,
        /// Live processes. A process is only made by a live one, so once
        /// this is empty it stays empty.
        procs: std.ArrayList(*Proc) = .empty,
        next_pid: u32 = 1,
        trace_lock: std.atomic.Mutex = .unlocked,
        /// vCPUs for the processes.
        pool: cpupool.Pool,

        fn lockSpin(j: *Job) void {
            while (!j.lock.tryLock()) std.atomic.spinLoopHint();
        }

        /// Allocates and registers a process with the next pid. Fails with
        /// TooManyProcs at the policy's `--pids` cap.
        fn newProc(j: *Job) error{ OutOfMemory, TooManyProcs }!*Proc {
            const gpa = j.m.gpa;
            const p = try gpa.create(Proc);
            errdefer gpa.destroy(p);
            j.lockSpin();
            defer j.lock.unlock();
            if (j.m.plan.pids) |cap| if (j.procs.items.len >= cap) return error.TooManyProcs;
            try j.procs.append(gpa, p);
            p.* = .{ .job = j, .pid = j.next_pid };
            j.next_pid += 1;
            return p;
        }

        /// Unregisters and frees a process that never ran.
        fn dropProc(j: *Job, p: *Proc) void {
            j.lockSpin();
            for (j.procs.items, 0..) |q, i| if (q == p) {
                _ = j.procs.swapRemove(i);
                break;
            };
            j.lock.unlock();
            j.m.gpa.destroy(p);
        }

        /// Stops every process: kicks vCPUs and interrupts blocking
        /// kernel calls. Safe from any thread.
        fn stopAll(j: *Job) void {
            j.stopping.store(true, .release);
            j.lockSpin();
            defer j.lock.unlock();
            for (j.procs.items) |p| {
                if (p.lease) |l| l.kick();
                if (p.kproc) |k| kern.interrupt(k);
            }
        }

        /// Waits for every process to exit after `stopAll`, kicking again
        /// for a grace period. Returns false if some are stuck.
        fn waitAll(j: *Job) bool {
            var waited: u32 = 0;
            while (waited < grace_ms) : (waited += 10) {
                const tick: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(10), .clock = .awake };
                if (j.all_done.waitTimeout(j.m.io, .{ .duration = tick })) |_| return true else |_| j.stopAll();
            }
            return j.all_done.isSet();
        }
    };

    /// One guest process: a kernel process with its own host thread, an
    /// address space and segments, and a vCPU while it runs.
    const Proc = struct {
        job: *Job,
        /// Machine-local pid.
        pid: u32,
        /// Set on the process's own thread; guarded by `job.lock`.
        kproc: ?*kern.Proc = null,
        /// How it runs guest code, while it does.
        lease: ?*cpupool.Lease = null,
        lease_store: cpupool.Lease = undefined,
        as: ?vmm.AddressSpace = null,
        segs: segment.Segs = .{},
        sys: syscall.Process = undefined,
        /// Registers to start from.
        ureg: vmm.Ureg = undefined,
        extra: vmm.Extra = .{},
        /// The Tos address, for the pid at fork.
        tos: u64 = 0,
        /// The a.out, for symbolizing faults with dump_on_fault.
        image: ?[]u8 = null,
        msg_buf: [256]u8 = undefined,

        fn setKproc(p: *Proc) void {
            p.job.lockSpin();
            defer p.job.lock.unlock();
            p.kproc = kern.self();
        }

        fn setLease(p: *Proc, l: ?*cpupool.Lease) void {
            p.job.lockSpin();
            defer p.job.lock.unlock();
            p.lease = l;
        }

        fn initSys(p: *Proc) void {
            const m = p.job.m;
            p.sys = .{
                .pid = p.pid,
                .gpa = m.gpa,
                .backend = m.backend,
                .as = p.as.?,
                .segs = &p.segs,
                .trace = m.opts.trace,
                .trace_lock = &p.job.trace_lock,
            };
        }

        fn keepImage(p: *Proc, bytes: []const u8) void {
            if (p.image) |old| p.job.m.gpa.free(old);
            p.image = if (p.job.m.opts.dump_on_fault) p.job.m.gpa.dupe(u8, bytes) catch null else null;
        }

        /// Frees the process and unregisters it. Called last on its thread;
        /// the job may be gone once it returns.
        fn exit(p: *Proc) void {
            const j = p.job;
            const gpa = j.m.gpa;
            const io = j.m.io;
            if (p.lease) |l| {
                p.setLease(null);
                l.release();
            }
            if (p.as) |as| {
                p.segs.release(as);
                as.destroy();
            }
            if (p.image) |b| gpa.free(b);
            j.lockSpin();
            for (j.procs.items, 0..) |q, i| if (q == p) {
                _ = j.procs.swapRemove(i);
                break;
            };
            const empty = j.procs.items.len == 0;
            j.lock.unlock();
            gpa.destroy(p);
            if (empty) j.all_done.set(io);
        }
    };

    /// The first process's thread: builds the namespace, loads the program
    /// and runs it.
    fn firstMain(p: *Proc) void {
        const j = p.job;
        const m = j.m;
        // devfs checks this thread's accesses against the plan.
        kern.setPlan(&m.plan);
        kern.setGuestPid(p.pid);
        p.setKproc();
        const r = m.startFirst(p);
        // The status and err_msg can point into the Proc or its errstr,
        // which go when it exits.
        j.result = if (r) |st| switch (st) {
            .exited => |t| .{ .exited = m.keep(t) },
            .killed => |t| .{ .killed = m.keep(t) },
        } else |e| e;
        const e = m.err_msg;
        if (e.len > 0 and !(@intFromPtr(e.ptr) >= @intFromPtr(&m.msg_buf) and @intFromPtr(e.ptr) < @intFromPtr(&m.msg_buf) + m.msg_buf.len)) {
            m.err_msg = m.keep2(e);
        }
        j.first_done.set(m.io);
        p.exit();
    }

    fn startFirst(m: *Machine, p: *Proc) RunError!Status {
        const j = p.job;
        if (j.stopping.load(.acquire)) return .{ .killed = timeout_note };
        try m.buildNamespace(j.con_id);
        if (m.opts.ns) |path| {
            var buf: [1024]u8 = undefined;
            const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return m.fail("--ns: name too long", .{});
            const text = readFile(m.gpa, z) catch return m.fail("--ns {s}: {s}", .{ path, kern.errstr() });
            defer m.gpa.free(text);
            try m.replayNamespace(text, j.con_id);
        }

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
        var name_buf: [kern.ERRMAX]u8 = undefined;
        const name = switch (j.prog) {
            .guest => |n| n,
            .bytes => if (j.argv.len > 0) j.argv[0] else "a.out",
        };
        kern.setText(std.fmt.bufPrintZ(&name_buf, "{s}", .{basename(name)}) catch "a.out");

        p.as = try m.backend.newAddressSpace();
        const img = try loader.load(m.gpa, m.backend, p.as.?, bytes, j.argv, p.pid);
        p.segs = img.segs;
        p.tos = img.tos;
        p.ureg = .initExec(img.arch, img.entry, img.sp, img.tos);
        p.extra = .initExec(img.arch);
        p.keepImage(bytes);
        p.initSys();
        return m.loop(p);
    }

    /// A forked process's thread.
    fn childMain(p: *Proc) void {
        const m = p.job.m;
        kern.setPlan(&m.plan);
        p.setKproc();
        const st = m.loop(p) catch |e| Status{ .killed = std.fmt.bufPrint(&p.msg_buf, "hp9: {t}", .{e}) catch "hp9: error" };
        setExits(switch (st) {
            .exited => |t| t,
            .killed => |t| t,
        });
        p.exit();
    }

    fn setExits(msg: []const u8) void {
        var buf: [kern.ERRMAX]u8 = undefined;
        const n = @min(msg.len, buf.len - 1);
        @memcpy(buf[0..n], msg[0..n]);
        buf[n] = 0;
        kern.setExits(buf[0..n :0]);
    }

    /// The exit loop: runs the process on its vCPU and serves its exits
    /// until it exits or dies. Runs on the process's thread.
    fn loop(m: *Machine, p: *Proc) RunError!Status {
        const j = p.job;
        try j.pool.acquire(&p.lease_store);
        p.setLease(&p.lease_store);
        const vcpu = &p.lease_store;
        try vcpu.setAddressSpace(p.as.?);
        vcpu.setExtra(&p.extra);
        var u = p.ureg;
        vcpu.setUreg(&u);
        while (true) {
            if (j.stopping.load(.acquire)) return .{ .killed = if (j.timed_out.load(.acquire)) timeout_note else stopped_note };
            const exit = try vcpu.run();
            vcpu.getUreg(&u);
            switch (exit) {
                .syscall => switch (syscall.dispatch(&p.sys, &u)) {
                    .ret => |r| {
                        u.setReturn(r);
                        vcpu.setUreg(&u);
                    },
                    .exits => |s| {
                        setExits(s);
                        return .{ .exited = s };
                    },
                    .killed => |s| return .{ .killed = s },
                    .rfork => |flags| {
                        try vcpu.getExtra(&p.extra);
                        const r: i64 = if (m.fork(p, flags, &u)) |pid| pid else |_| -1;
                        p.sys.traceRet("rfork", r);
                        u.setReturn(@bitCast(r));
                        vcpu.setUreg(&u);
                    },
                    .exec => |e| {
                        defer e.deinit(m.gpa);
                        if (m.exec(p, vcpu, e)) |_| {
                            p.sys.traceRet("exec", 0);
                            u = p.ureg;
                            vcpu.setExtra(&p.extra);
                        } else |_| {
                            p.sys.traceRet("exec", -1);
                            u.setReturn(@bitCast(@as(i64, -1)));
                        }
                        vcpu.setUreg(&u);
                    },
                },
                .fault => |f| {
                    // The stack grows down on demand, as 9front's does.
                    if (f.access != .exec and p.segs.growStack(f.addr)) continue;
                    if (m.opts.dump_on_fault) dumpFault(m.opts.stdio.err, &u, f, p.image orelse "");
                    return .{ .killed = try std.fmt.bufPrint(&p.msg_buf, "sys: trap: fault {t} addr=0x{x} pc=0x{x}", .{ f.access, f.addr, u.pc() }) };
                },
                .interrupted => {},
                .halted => return .{ .killed = "halted" },
                .other => |code| return .{ .killed = try std.fmt.bufPrint(&p.msg_buf, "sys: trap: unexpected exit 0x{x} pc=0x{x}", .{ code, u.pc() }) },
            }
        }
    }

    /// rfork. With RF.PROC, starts a child that resumes from `u` with 0
    /// returned, and returns its pid; without, changes the caller's groups.
    /// On error the error string is set.
    fn fork(m: *Machine, p: *Proc, flags: u32, u: *const vmm.Ureg) error{Failed}!u32 {
        const flag: c_int = @bitCast(flags);
        if (flags & kern.RF.PROC == 0) {
            kern.rfork(flag) catch return error.Failed;
            return 0;
        }
        const j = p.job;
        // 9front's error when it runs out of procs.
        const c = j.newProc() catch return failWith("no procs");
        const cas = m.backend.newAddressSpace() catch {
            j.dropProc(c);
            return failWith("no procs");
        };
        c.as = cas;
        c.segs = p.segs.fork(cas, flags & kern.RF.MEM != 0) catch {
            cas.destroy();
            j.dropProc(c);
            return failWith("virtual memory allocation failed");
        };
        loader.setTosPid(cas, p.tos, c.pid);
        c.tos = p.tos;
        c.ureg = u.*;
        c.ureg.setReturn(0);
        c.extra = p.extra;
        if (p.image) |b| c.image = m.gpa.dupe(u8, b) catch null;
        c.initSys();
        c.sys.notify = p.sys.notify;
        // The child may run, exit and free itself before kern.fork returns.
        const pid = c.pid;
        kern.fork(flag, pid, Proc, childMain, c) catch {
            if (c.image) |b| m.gpa.free(b);
            c.segs.release(cas);
            cas.destroy();
            j.dropProc(c);
            return error.Failed;
        };
        return pid;
    }

    fn failWith(msg: []const u8) error{Failed} {
        kern.setErrstr(msg);
        return error.Failed;
    }

    const max_indir = 8;
    const ebadexec = "exec header invalid";

    /// exec, as 9front's sysexec: loads the program (following up to 8
    /// levels of #! interpreters) into a new address space, and only then
    /// replaces the process's memory, closes its close-on-exec fds and
    /// resets its registers. On error the process is unchanged and the
    /// error string is set.
    fn exec(m: *Machine, p: *Proc, vcpu: *cpupool.Lease, e: syscall.Exec) error{Failed}!void {
        var arena_state: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // The last path element names the process, and is argv[0] for a script.
        const elem = basename(e.path);

        var pre: std.ArrayList([]const u8) = .empty;
        var bytes = readFile(arena, e.path) catch |err| return execError(err);
        var indir: usize = 0;
        while (std.mem.startsWith(u8, bytes, "#!")) : (indir += 1) {
            if (indir >= max_indir) return failWith(ebadexec);
            const head = bytes[0..@min(bytes.len, 256)];
            const nl = std.mem.indexOfScalar(u8, head, '\n') orelse return failWith(ebadexec);
            var toks: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, head[2..nl], " \t\r");
            while (it.next()) |t| toks.append(arena, t) catch return failWith("no memory");
            if (toks.items.len < 1 or toks.items.len >= 32) return failWith(ebadexec);
            if (indir == 0) pre.append(arena, e.path) catch return failWith("no memory");
            pre.insertSlice(arena, 0, toks.items) catch return failWith("no memory");
            const interp = std.fmt.allocPrintSentinel(arena, "{s}", .{toks.items[0]}, 0) catch return failWith("no memory");
            bytes = readFile(arena, interp) catch |err| return execError(err);
        }
        const hdr = aout.parse(bytes) catch return failWith(ebadexec);
        if (hdr.arch != m.arch) return failWith(ebadexec);

        // For a script, as 9front builds it: the interpreters' arguments
        // (the outermost's first) and the script's full name, with the
        // first interpreter's name swapped for `elem`, then the caller's
        // arguments after argv[0]. So `#!/bin/rc` running /bin/x with argv
        // `x a` gets `x /bin/x a`.
        var argv: std.ArrayList([]const u8) = .empty;
        if (indir > 0) {
            argv.append(arena, elem) catch return failWith("no memory");
            argv.appendSlice(arena, pre.items[1..]) catch return failWith("no memory");
            argv.appendSlice(arena, @ptrCast(e.argv[1..])) catch return failWith("no memory");
        } else argv.appendSlice(arena, @ptrCast(e.argv)) catch return failWith("no memory");

        const nas = m.backend.newAddressSpace() catch return failWith("virtual memory allocation failed");
        const img = loader.load(m.gpa, m.backend, nas, bytes, argv.items, p.pid) catch |err| {
            nas.destroy();
            return failWith(switch (err) {
                error.BadExec, error.Truncated, error.BadMagic => ebadexec,
                else => "virtual memory allocation failed",
            });
        };
        vcpu.setAddressSpace(nas) catch {
            var segs = img.segs;
            segs.release(nas);
            nas.destroy();
            return failWith("virtual memory allocation failed");
        };

        // Committed.
        const old = p.as.?;
        p.segs.release(old);
        old.destroy();
        p.as = nas;
        p.segs = img.segs;
        p.tos = img.tos;
        p.sys.as = nas;
        p.sys.notify = 0;
        p.ureg = .initExec(img.arch, img.entry, img.sp, img.tos);
        p.extra = .initExec(img.arch);
        p.keepImage(bytes);
        kern.closeExec();
        var name_buf: [kern.ERRMAX]u8 = undefined;
        kern.setText(std.fmt.bufPrintZ(&name_buf, "{s}", .{elem}) catch "a.out");
    }

    fn execError(err: RunError) error{Failed} {
        // A failed stat or open has set the error string already.
        return switch (err) {
            error.NotFound => error.Failed,
            error.OutOfMemory => failWith("no memory"),
            else => failWith(ebadexec),
        };
    }

    fn basename(path: []const u8) []const u8 {
        const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
        return path[i + 1 ..];
    }

    fn keep(m: *Machine, s: []const u8) []const u8 {
        const n = @min(s.len, m.msg_buf.len);
        @memmove(m.msg_buf[0..n], s[0..n]);
        return m.msg_buf[0..n];
    }

    /// Like `keep`, into a separate buffer, for `err_msg`.
    fn keep2(m: *Machine, s: []const u8) []const u8 {
        const n = @min(s.len, m.err_buf.len);
        @memmove(m.err_buf[0..n], s[0..n]);
        return m.err_buf[0..n];
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

    /// Runs a namespace file's operations, as newns does: a failed bind or
    /// mount is skipped, and only a syntax error fails the run. The device
    /// mask is already set, so it can't reach masked devices.
    fn replayNamespace(m: *Machine, text: []const u8, con_id: u32) RunError!void {
        var arena_state: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var line: usize = 0;
        const ops = newns.parse(arena, text, &line) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => return m.fail("--ns: line {d}: syntax error", .{line}),
        };
        for (ops) |op| switch (op) {
            .bind => |b| kern.bind(try m.nsPath(arena, b.from, con_id), try m.nsPath(arena, b.to, con_id), mountFlag(b.flag)) catch {},
            .mount => |mt| {
                const fd = kern.open(try m.nsPath(arena, mt.file, con_id), kern.ORDWR) catch continue;
                defer kern.close(fd) catch {};
                kern.mount(fd, try m.nsPath(arena, mt.to, con_id), mountFlag(mt.flag), try arena.dupeZ(u8, mt.spec)) catch {};
            },
            .unmount => |u| kern.unmount(if (u.from) |f| try m.nsPath(arena, f, con_id) else null, try m.nsPath(arena, u.to, con_id)) catch {},
            .cd => |d| kern.chdir(try m.nsPath(arena, d, con_id)) catch {},
            // newns's rfork(RFCNAMEG): an empty namespace, keeping the mask.
            .clear => kern.rfork(kern.RF.CNAMEG) catch {},
        };
    }

    /// A namespace-file path, with --print's `<id>` console placeholder
    /// filled in.
    fn nsPath(_: *Machine, arena: std.mem.Allocator, p: []const u8, con_id: u32) RunError![:0]const u8 {
        if (std.mem.indexOf(u8, p, "<id>")) |i| return std.fmt.allocPrintSentinel(arena, "{s}{d}{s}", .{ p[0..i], con_id, p[i + 4 ..] }, 0);
        return arena.dupeZ(u8, p);
    }

    fn mountFlag(f: newns.Flag) c_int {
        var flag: c_int = switch (f.order) {
            .repl => kern.MREPL,
            .before => kern.MBEFORE,
            .after => kern.MAFTER,
        };
        if (f.create) flag |= kern.MCREATE;
        if (f.cache) flag |= kern.MCACHE;
        return flag;
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
