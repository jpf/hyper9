//! Zig side of the drawterm kern seam (DESIGN.md, "Kernel: drawterm kern/
//! and the Zig seam"). Each call goes through one of kern's `sys*` wrappers,
//! which catch kernel errors with waserror and return -1; `errstr` then
//! holds the message. No Zig frame sits between a waserror and an error.
//!
//! The kernel boots once per host process, on a private thread. Each guest
//! process runs on a thread made by `spawn`, and only that thread may make
//! kernel calls for it.

const std = @import("std");
const build_options = @import("build_options");
const policy = @import("policy.zig");

/// False where kern isn't built (a checkout without drawterm).
pub const available = build_options.kern;

pub const Error = error{ KernUnavailable, Kern, OutOfMemory };

pub const OREAD = 0;
pub const OWRITE = 1;
pub const ORDWR = 2;
pub const OEXEC = 3;
pub const MREPL = 0;
pub const MBEFORE = 1;
pub const MAFTER = 2;
pub const MCREATE = 4;
pub const MCACHE = 0x10;
pub const ERRMAX = 128;

/// The C side, or stubs where kern isn't built so hp9 still links.
const c = if (available) c_real else c_stub;

const c_stub = struct {
    fn hp9_kern_boot() c_int {
        return -1;
    }
    fn hp9_kern_park() noreturn {
        unreachable;
    }
    fn hp9_kern_spawn(_: [*:0]const u8, _: *const fn (?*anyopaque) callconv(.c) void, _: ?*anyopaque) c_int {
        return -1;
    }
    fn hp9_kern_pid() c_ulong {
        return 0;
    }
    fn hp9_kern_fork(_: c_int, _: c_ulong, _: *const fn (?*anyopaque) callconv(.c) void, _: ?*anyopaque) c_int {
        return -1;
    }
    fn hp9_kern_rfork(_: c_int) c_int {
        return -1;
    }
    fn hp9_kern_await(_: [*]u8, _: c_int) c_int {
        return -1;
    }
    fn hp9_kern_setexits(_: [*:0]const u8) void {}
    fn hp9_kern_gpid() c_ulong {
        return 0;
    }
    fn hp9_kern_setgpid(_: c_ulong) void {}
    fn hp9_kern_settext(_: [*:0]const u8) void {}
    fn hp9_kern_aux() ?*anyopaque {
        return null;
    }
    fn hp9_kern_setaux(_: ?*anyopaque) void {}
    fn hp9_kern_closeexec() void {}
    fn hp9_kern_takenote() c_int {
        return 0;
    }
    fn syspipe(_: *[2]c_int) c_int {
        return -1;
    }
    fn hp9_kern_user() [*:0]const u8 {
        return "none";
    }
    fn hp9_kern_devmask(_: [*:0]const u8) void {}
    fn hp9_kern_self() ?*anyopaque {
        return null;
    }
    fn hp9_kern_interrupt(_: ?*anyopaque) void {}
    fn hp9_kern_sleep(_: c_long) c_int {
        return -1;
    }
    var no_err: [ERRMAX:0]u8 = @splat(0);
    fn hp9_kern_errstr() [*:0]u8 {
        return &no_err;
    }
    fn hp9_fd2path(_: c_int, _: [*]u8, _: c_uint) c_int {
        return -1;
    }
    fn sysopen(_: [*:0]const u8, _: c_int) c_int {
        return -1;
    }
    fn syscreate(_: [*:0]const u8, _: c_int, _: c_uint) c_int {
        return -1;
    }
    fn sysclose(_: c_int) c_int {
        return -1;
    }
    fn syspread(_: c_int, _: [*]u8, _: c_int, _: i64) c_int {
        return -1;
    }
    fn syspwrite(_: c_int, _: [*]const u8, _: c_int, _: i64) c_int {
        return -1;
    }
    fn sysseek(_: c_int, _: i64, _: c_int) i64 {
        return -1;
    }
    fn sysbind(_: [*:0]const u8, _: [*:0]const u8, _: c_int) c_int {
        return -1;
    }
    fn sysmount(_: c_int, _: c_int, _: [*:0]const u8, _: c_int, _: [*:0]const u8) c_int {
        return -1;
    }
    fn sysunmount(_: ?[*:0]const u8, _: [*:0]const u8) c_int {
        return -1;
    }
    fn syschdir(_: [*:0]const u8) c_int {
        return -1;
    }
    fn sysdup(_: c_int, _: c_int) c_int {
        return -1;
    }
    fn sysstat(_: [*:0]const u8, _: [*]u8, _: c_int) c_int {
        return -1;
    }
    fn sysfstat(_: c_int, _: [*]u8, _: c_int) c_int {
        return -1;
    }
    fn sysremove(_: [*:0]const u8) c_int {
        return -1;
    }
    fn syswstat(_: [*:0]const u8, _: [*]u8, _: c_int) c_int {
        return -1;
    }
    fn sysfwstat(_: c_int, _: [*]u8, _: c_int) c_int {
        return -1;
    }
};

const c_real = struct {
    extern fn hp9_kern_boot() c_int;
    extern fn hp9_kern_park() noreturn;
    extern fn hp9_kern_spawn(name: [*:0]const u8, func: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) c_int;
    extern fn hp9_kern_pid() c_ulong;
    extern fn hp9_kern_fork(flag: c_int, pid: c_ulong, func: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) c_int;
    extern fn hp9_kern_rfork(flag: c_int) c_int;
    extern fn hp9_kern_await(buf: [*]u8, n: c_int) c_int;
    extern fn hp9_kern_setexits(msg: [*:0]const u8) void;
    extern fn hp9_kern_gpid() c_ulong;
    extern fn hp9_kern_setgpid(pid: c_ulong) void;
    extern fn hp9_kern_settext(text: [*:0]const u8) void;
    extern fn hp9_kern_aux() ?*anyopaque;
    extern fn hp9_kern_setaux(aux: ?*anyopaque) void;
    extern fn hp9_kern_closeexec() void;
    extern fn hp9_kern_takenote() c_int;
    extern fn syspipe(fd: *[2]c_int) c_int;
    extern fn hp9_kern_user() [*:0]const u8;
    extern fn hp9_kern_devmask(devs: [*:0]const u8) void;
    extern fn hp9_kern_self() ?*anyopaque;
    extern fn hp9_kern_interrupt(p: ?*anyopaque) void;
    extern fn hp9_kern_sleep(ms: c_long) c_int;
    extern fn hp9_kern_errstr() [*:0]u8;
    extern fn hp9_fd2path(fd: c_int, buf: [*]u8, n: c_uint) c_int;
    extern fn sysopen(name: [*:0]const u8, mode: c_int) c_int;
    extern fn syscreate(name: [*:0]const u8, mode: c_int, perm: c_uint) c_int;
    extern fn sysclose(fd: c_int) c_int;
    extern fn syspread(fd: c_int, buf: [*]u8, n: c_int, off: i64) c_int;
    extern fn syspwrite(fd: c_int, buf: [*]const u8, n: c_int, off: i64) c_int;
    extern fn sysseek(fd: c_int, off: i64, whence: c_int) i64;
    extern fn sysbind(old: [*:0]const u8, new: [*:0]const u8, flag: c_int) c_int;
    extern fn sysmount(fd: c_int, afd: c_int, new: [*:0]const u8, flag: c_int, spec: [*:0]const u8) c_int;
    extern fn sysunmount(old: ?[*:0]const u8, new: [*:0]const u8) c_int;
    extern fn syschdir(name: [*:0]const u8) c_int;
    extern fn sysdup(fd0: c_int, fd1: c_int) c_int;
    extern fn sysstat(name: [*:0]const u8, buf: [*]u8, n: c_int) c_int;
    extern fn sysfstat(fd: c_int, buf: [*]u8, n: c_int) c_int;
    extern fn sysremove(name: [*:0]const u8) c_int;
    extern fn syswstat(name: [*:0]const u8, buf: [*]u8, n: c_int) c_int;
    extern fn sysfwstat(fd: c_int, buf: [*]u8, n: c_int) c_int;
};

const BootState = enum(u8) { idle, booting, up, failed };
var boot_state: std.atomic.Value(BootState) = .init(.idle);

/// Boots the kernel if it isn't already. Safe to call from any thread.
/// The boot runs on a private thread, which becomes the kernel's first
/// Proc for good and then parks.
pub fn boot() Error!void {
    if (!available) return error.KernUnavailable;
    while (true) switch (boot_state.load(.acquire)) {
        .up => return,
        .failed => return error.Kern,
        .booting => std.atomic.spinLoopHint(),
        .idle => if (boot_state.cmpxchgStrong(.idle, .booting, .acq_rel, .acquire) == null) {
            const t = std.Thread.spawn(.{}, bootThread, .{}) catch {
                boot_state.store(.idle, .release);
                return error.OutOfMemory;
            };
            t.detach();
        },
    };
}

fn bootThread() void {
    const ok = c.hp9_kern_boot() >= 0;
    boot_state.store(if (ok) .up else .failed, .release);
    // The thread is the boot Proc now, which hp9_kern_spawn clones from.
    if (ok) c.hp9_kern_park();
}

/// Runs `func(arg)` on a new kernel process with its own host thread, a
/// fresh namespace containing only #/, no fds, an empty environment and no
/// parent. The process ends when `func` returns.
pub fn spawn(name: [*:0]const u8, comptime T: type, comptime func: fn (*T) void, arg: *T) Error!void {
    try boot();
    const Tramp = struct {
        fn run(p: ?*anyopaque) callconv(.c) void {
            func(@ptrCast(@alignCast(p.?)));
        }
    };
    if (c.hp9_kern_spawn(name, Tramp.run, arg) < 0) return error.OutOfMemory;
}

/// rfork flags (9front's libc.h).
pub const RF = struct {
    pub const NAMEG = 1 << 0;
    pub const ENVG = 1 << 1;
    pub const FDG = 1 << 2;
    pub const NOTEG = 1 << 3;
    pub const PROC = 1 << 4;
    pub const MEM = 1 << 5;
    pub const NOWAIT = 1 << 6;
    pub const CNAMEG = 1 << 10;
    pub const CENVG = 1 << 11;
    pub const CFDG = 1 << 12;
    pub const REND = 1 << 13;
    pub const NOMNT = 1 << 14;
};

/// rfork with RF.PROC from a process made by `spawn` or `fork`: runs
/// `func(arg)` on a new kernel process that is the caller's child, with its
/// namespace, fds, environment and rendezvous group shared or copied as
/// `flag` says. `pid` is its machine-local pid. Without RF.NOWAIT, its exit
/// leaves a wait record for the caller's `await`. On error `func` never
/// runs, and `errstr` says why.
pub fn fork(flag: c_int, child_pid: u32, comptime T: type, comptime func: fn (*T) void, arg: *T) Error!void {
    const Tramp = struct {
        fn run(p: ?*anyopaque) callconv(.c) void {
            func(@ptrCast(@alignCast(p.?)));
        }
    };
    _ = try check(c.hp9_kern_fork(flag, child_pid, Tramp.run, arg));
}

/// rfork without RF.PROC: changes the caller's own groups.
pub fn rfork(flag: c_int) Error!void {
    _ = try check(c.hp9_kern_rfork(flag));
}

/// Waits for a child to exit and writes its wait message to `buf`, as the
/// await syscall returns it: "pid utime stime real 'msg'". Fails with "no
/// living children" when there are none.
pub fn await(buf: []u8) Error!usize {
    return try check(c.hp9_kern_await(buf.ptr, clampLen(buf.len)));
}

/// Sets the exit string the parent's wait record carries; "" is success.
pub fn setExits(msg: [*:0]const u8) void {
    c.hp9_kern_setexits(msg);
}

/// The calling process's machine-local pid (0 if never set).
pub fn guestPid() u32 {
    return @intCast(c.hp9_kern_gpid());
}

pub fn setGuestPid(p: u32) void {
    c.hp9_kern_setgpid(p);
}

/// Sets the process's name, as wait messages show it.
pub fn setText(text: [*:0]const u8) void {
    c.hp9_kern_settext(text);
}

/// The Zig process attached to the calling kernel process.
pub fn aux() ?*anyopaque {
    return c.hp9_kern_aux();
}

pub fn setAux(p: ?*anyopaque) void {
    c.hp9_kern_setaux(p);
}

/// Closes the calling process's close-on-exec fds.
pub fn closeExec() void {
    c.hp9_kern_closeexec();
}

/// Returns and clears the process's pending-note flag, which devpipe sets
/// on a write to a closed pipe.
pub fn takeNote() bool {
    return c.hp9_kern_takenote() != 0;
}

/// Makes a pipe and returns its two fds.
pub fn pipe() Error![2]u31 {
    var fd: [2]c_int = .{ -1, -1 };
    _ = try check(c.syspipe(&fd));
    return .{ @intCast(fd[0]), @intCast(fd[1]) };
}

/// The host user, which is the kernel's hostowner (eve).
pub fn user() []const u8 {
    return std.mem.span(c.hp9_kern_user());
}

/// The calling Proc's kernel pid.
pub fn pid() u32 {
    return @intCast(c.hp9_kern_pid());
}

/// Blocks future attaches of the devices named by `devs` (letters, as in
/// `#U`) in the calling Proc's namespace. Existing binds keep working.
pub fn devmask(devs: [*:0]const u8) void {
    c.hp9_kern_devmask(devs);
}

/// The calling kernel process, for `interrupt`.
pub const Proc = opaque {};

pub fn self() *Proc {
    return @ptrCast(c.hp9_kern_self().?);
}

/// Makes the process's current or next blocking kernel call fail with
/// "interrupted". The caller must know the process hasn't exited.
pub fn interrupt(p: *Proc) void {
    c.hp9_kern_interrupt(p);
}

/// Sleeps for `ms` milliseconds, or until the process is interrupted.
pub fn sleep(ms: i64) Error!void {
    _ = try check(c.hp9_kern_sleep(@intCast(std.math.clamp(ms, std.math.minInt(c_long), std.math.maxInt(c_long)))));
}

/// The sandbox plan devfs checks for the calling thread's process (see
/// src/kern/fscheck.c). Each guest process runs on its own thread, so the
/// plan is per thread; kernel threads without one aren't restricted.
threadlocal var fs_plan: ?*const policy.Plan = null;

pub fn setPlan(p: ?*const policy.Plan) void {
    fs_plan = p;
}

/// The calling Proc's error string after a failed call.
pub fn errstr() []const u8 {
    return std.mem.span(c.hp9_kern_errstr());
}

/// Swaps `buf` (NUL-terminated, at most ERRMAX) with the error string, as
/// the errstr syscall does.
pub fn swapErrstr(buf: *[ERRMAX]u8) void {
    const k = c.hp9_kern_errstr();
    var tmp: [ERRMAX]u8 = undefined;
    const kl = std.mem.len(k);
    @memcpy(tmp[0..kl], k[0..kl]);
    tmp[kl] = 0;
    const bl = std.mem.indexOfScalar(u8, buf, 0) orelse ERRMAX - 1;
    @memcpy(k[0..bl], buf[0..bl]);
    k[bl] = 0;
    @memcpy(buf[0 .. kl + 1], tmp[0 .. kl + 1]);
}

/// Sets the error string, for errors hp9 raises itself.
pub fn setErrstr(msg: []const u8) void {
    const k = c.hp9_kern_errstr();
    const n = @min(msg.len, ERRMAX - 1);
    @memcpy(k[0..n], msg[0..n]);
    k[n] = 0;
}

fn check(r: c_int) Error!u31 {
    if (r < 0) return error.Kern;
    return @intCast(r);
}

fn clampLen(n: usize) c_int {
    return @intCast(@min(n, std.math.maxInt(c_int)));
}

pub fn open(name: [*:0]const u8, mode: c_int) Error!u31 {
    return check(c.sysopen(name, mode));
}

pub fn create(name: [*:0]const u8, mode: c_int, perm: u32) Error!u31 {
    return check(c.syscreate(name, mode, perm));
}

pub fn close(fd: u31) Error!void {
    _ = try check(c.sysclose(fd));
}

/// One read of at most 2 GiB - 1; `off` -1 uses and advances the fd offset.
pub fn pread(fd: u31, buf: []u8, off: i64) Error!usize {
    return try check(c.syspread(fd, buf.ptr, clampLen(buf.len), off));
}

/// One write of at most 2 GiB - 1; `off` -1 uses and advances the fd offset.
pub fn pwrite(fd: u31, buf: []const u8, off: i64) Error!usize {
    return try check(c.syspwrite(fd, buf.ptr, clampLen(buf.len), off));
}

pub fn seek(fd: u31, off: i64, whence: c_int) Error!i64 {
    const r = c.sysseek(fd, off, whence);
    if (r < 0) return error.Kern;
    return r;
}

pub fn bind(old: [*:0]const u8, new: [*:0]const u8, flag: c_int) Error!void {
    _ = try check(c.sysbind(old, new, flag));
}

/// Mounts the 9P server on `fd` at `new`.
pub fn mount(fd: u31, new: [*:0]const u8, flag: c_int, spec: [*:0]const u8) Error!void {
    _ = try check(c.sysmount(fd, -1, new, flag, spec));
}

/// Undoes binds and mounts on `new`: only `old`'s, or all with null.
pub fn unmount(old: ?[*:0]const u8, new: [*:0]const u8) Error!void {
    _ = try check(c.sysunmount(old, new));
}

pub fn chdir(name: [*:0]const u8) Error!void {
    _ = try check(c.syschdir(name));
}

pub fn dup(fd0: u31, fd1: i32) Error!u31 {
    return check(c.sysdup(fd0, fd1));
}

/// Returns the length of the stat message written to `buf`, or, if `buf`
/// is too small, the BIT16SZ size prefix that tells the caller how big.
pub fn stat(name: [*:0]const u8, buf: []u8) Error!usize {
    return try check(c.sysstat(name, buf.ptr, clampLen(buf.len)));
}

pub fn fstat(fd: u31, buf: []u8) Error!usize {
    return try check(c.sysfstat(fd, buf.ptr, clampLen(buf.len)));
}

pub fn wstat(name: [*:0]const u8, buf: []u8) Error!usize {
    return try check(c.syswstat(name, buf.ptr, clampLen(buf.len)));
}

pub fn fwstat(fd: u31, buf: []u8) Error!usize {
    return try check(c.sysfwstat(fd, buf.ptr, clampLen(buf.len)));
}

pub fn remove(name: [*:0]const u8) Error!void {
    _ = try check(c.sysremove(name));
}

pub fn fd2path(fd: u31, buf: []u8) Error!void {
    _ = try check(c.hp9_fd2path(fd, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_uint)))));
}

/// One machine's console, behind `#y<id>` (src/kern/devhcons.c).
pub const Console = struct {
    in: ?*std.Io.Reader,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    mutex: std.atomic.Mutex = .unlocked,
    /// Serializes reads, since processes in a tree share the console. A
    /// reader blocked on the host waits with the lock held, so others yield.
    rmutex: std.atomic.Mutex = .unlocked,
};

const max_consoles = 64;
var consoles: [max_consoles]std.atomic.Value(?*Console) = @splat(.init(null));

/// Registers a console and returns its id for `#y<id>`.
pub fn addConsole(con: *Console) error{TooManyMachines}!u32 {
    for (&consoles, 0..) |*slot, i| {
        if (slot.cmpxchgStrong(null, con, .acq_rel, .acquire) == null) return @intCast(i);
    }
    return error.TooManyMachines;
}

pub fn removeConsole(id: u32) void {
    consoles[id].store(null, .release);
}

fn console(id: c_ulong) ?*Console {
    if (id >= max_consoles) return null;
    return consoles[id].load(.acquire);
}

// Leaves called from devhcons.c. They never raise kernel errors.

comptime {
    if (available) {
        @export(&hp9_cons_read, .{ .name = "hp9_cons_read" });
        @export(&hp9_cons_write, .{ .name = "hp9_cons_write" });
        @export(&hp9_policy_active, .{ .name = "hp9_policy_active" });
        @export(&hp9_policy_check, .{ .name = "hp9_policy_check" });
    }
}

fn hp9_policy_active() callconv(.c) c_int {
    return @intFromBool(fs_plan != null);
}

fn hp9_policy_check(path: [*]const u8, len: c_long, op: c_int) callconv(.c) c_int {
    const p = fs_plan orelse return 0;
    const o = std.enums.fromInt(policy.Op, op) orelse return @intFromEnum(policy.Verdict.hidden);
    return @intFromEnum(p.check(path[0..@intCast(len)], o));
}

fn hp9_cons_read(id: c_ulong, buf: [*]u8, n: c_long) callconv(.c) c_long {
    const con = console(id) orelse return -1;
    const r = con.in orelse return 0;
    while (!con.rmutex.tryLock()) std.Thread.yield() catch {};
    defer con.rmutex.unlock();
    const got = r.readSliceShort(buf[0..@intCast(n)]) catch return -1;
    return @intCast(got);
}

fn hp9_cons_write(id: c_ulong, fd: c_int, buf: [*]const u8, n: c_long) callconv(.c) c_long {
    const con = console(id) orelse return -1;
    const w = if (fd == 2) con.err else con.out;
    while (!con.mutex.tryLock()) std.atomic.spinLoopHint();
    defer con.mutex.unlock();
    w.writeAll(buf[0..@intCast(n)]) catch return -1;
    w.flush() catch return -1;
    return n;
}

test "spawn a process and read a host file through kern" {
    if (!available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/namespace", .data = "mount -a #s/boot /\n" });
    try tmp.dir.createDirPath(io, "dev");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);

    const T = struct {
        root: [:0]u8,
        err: ?anyerror = null,
        data: [64]u8 = undefined,
        len: usize = 0,
        sysname: [16]u8 = undefined,
        sysname_len: usize = 0,
        missing: []const u8 = "",
        missing_buf: [ERRMAX]u8 = undefined,
        done: std.atomic.Value(bool) = .init(false),

        fn run(t: *@This()) void {
            defer t.done.store(true, .release);
            t.body() catch |e| {
                t.err = e;
            };
        }
        fn body(t: *@This()) !void {
            var spec: [std.fs.max_path_bytes + 3]u8 = undefined;
            try bind(try std.fmt.bufPrintZ(&spec, "#U{s}", .{t.root}), "/", MREPL);
            try bind("#c", "/dev", MREPL);
            const fd = try open("/lib/namespace", OREAD);
            defer close(fd) catch {};
            t.len = try pread(fd, &t.data, 0);
            if (open("/lib/nonexistent", OREAD)) |_| return error.Unexpected else |_| {}
            const e = errstr();
            @memcpy(t.missing_buf[0..e.len], e);
            t.missing = t.missing_buf[0..e.len];
            const s = try open("/dev/sysname", OREAD);
            defer close(s) catch {};
            t.sysname_len = try pread(s, &t.sysname, 0);
        }
    };
    buf[n] = 0;
    var t: T = .{ .root = buf[0..n :0] };
    try spawn("test", T, T.run, &t);
    while (!t.done.load(.acquire)) std.Thread.yield() catch {};
    if (t.err) |e| return e;
    try std.testing.expectEqualStrings("mount -a #s/boot /\n", t.data[0..t.len]);
    try std.testing.expect(std.mem.indexOf(u8, t.missing, "does not exist") != null);
    try std.testing.expectEqualStrings("hp9", t.sysname[0..t.sysname_len]);
}

test "fork shares or copies groups, and await returns wait records" {
    if (!available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/namespace", .data = "ns\n" });
    try tmp.dir.createDirPath(io, "dev");
    try tmp.dir.createDirPath(io, "env");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    buf[n] = 0;

    const T = struct {
        root: [:0]u8,
        err: ?anyerror = null,
        where: []const u8 = "",
        done: std.atomic.Value(bool) = .init(false),
        waits: [4][64]u8 = undefined,
        wait_lens: [4]usize = @splat(0),
        no_child: [ERRMAX]u8 = undefined,
        no_child_len: usize = 0,
        child_saw: [16]u8 = undefined,
        child_saw_len: usize = 0,

        const Self = @This();
        const Child = struct {
            t: *Self,
            kind: enum { copy_env, share_env, new_ns, nowait },
            fn run(ch: *Child) void {
                ch.body() catch |e| {
                    ch.t.err = e;
                    ch.t.where = @tagName(ch.kind);
                };
            }
            fn body(ch: *Child) !void {
                switch (ch.kind) {
                    .copy_env => {
                        ch.t.child_saw_len = try readAll("/env/x", &ch.t.child_saw);
                        try writeAll("/env/x", "child");
                        if (guestPid() != 2) return error.WrongPid;
                        setExits("boom");
                    },
                    .share_env => try writeAll("/env/x", "shared"),
                    .new_ns => {
                        // The copied namespace still has the root; the new bind stays here.
                        var scratch: [16]u8 = undefined;
                        _ = try readAll("/lib/namespace", &scratch);
                        try bind("#c", "/dev", MREPL);
                        _ = try readAll("/dev/sysname", &scratch);
                    },
                    .nowait => {},
                }
            }
        };

        fn run(t: *@This()) void {
            defer t.done.store(true, .release);
            t.body() catch |e| {
                if (t.err == null) t.err = e;
                if (t.where.len == 0) t.where = "parent";
            };
        }
        fn body(t: *@This()) !void {
            var spec: [std.fs.max_path_bytes + 3]u8 = undefined;
            try bind(try std.fmt.bufPrintZ(&spec, "#U{s}", .{t.root}), "/", MREPL);
            try bind("#e", "/env", MREPL | MCREATE);
            setGuestPid(1);
            try writeAll("/env/x", "parent");
            var tmpb: [16]u8 = undefined;

            if (fork(0, 9, Child, Child.run, undefined)) |_| return error.ForkWithoutProc else |_| {}

            var c1: Child = .{ .t = t, .kind = .copy_env };
            try fork(RF.PROC | RF.FDG | RF.ENVG, 2, Child, Child.run, &c1);
            t.wait_lens[0] = try await(&t.waits[0]);
            try std.testing.expectEqualStrings("parent", tmpb[0..try readAll("/env/x", &tmpb)]);

            var c2: Child = .{ .t = t, .kind = .share_env };
            try fork(RF.PROC, 3, Child, Child.run, &c2);
            t.wait_lens[1] = try await(&t.waits[1]);
            try std.testing.expectEqualStrings("shared", tmpb[0..try readAll("/env/x", &tmpb)]);

            var c3: Child = .{ .t = t, .kind = .new_ns };
            try fork(RF.PROC | RF.NAMEG, 4, Child, Child.run, &c3);
            t.wait_lens[2] = try await(&t.waits[2]);
            if (open("/dev/sysname", OREAD)) |_| return error.ChildBindLeaked else |_| {}

            var c4: Child = .{ .t = t, .kind = .nowait };
            try fork(RF.PROC | RF.NOWAIT, 5, Child, Child.run, &c4);
            if (await(&t.waits[3])) |_| return error.AwaitedNowaitChild else |_| {}
            const e = errstr();
            @memcpy(t.no_child[0..e.len], e);
            t.no_child_len = e.len;
            // Let the RFNOWAIT child finish before c4 goes out of scope.
            try sleep(50);
        }

        fn readAll(path: [*:0]const u8, out: []u8) !usize {
            const fd = try open(path, OREAD);
            defer close(fd) catch {};
            return pread(fd, out, 0);
        }
        fn writeAll(path: [*:0]const u8, data: []const u8) !void {
            const fd = try create(path, OWRITE, 0o664);
            defer close(fd) catch {};
            _ = try pwrite(fd, data, 0);
        }
    };
    var t: T = .{ .root = buf[0..n :0] };
    try spawn("test", T, T.run, &t);
    while (!t.done.load(.acquire)) std.Thread.yield() catch {};
    if (t.err) |e| {
        std.debug.print("failed in {s}\n", .{t.where});
        return e;
    }
    try std.testing.expectEqualStrings("parent", t.child_saw[0..t.child_saw_len]);
    // "pid utime stime real 'msg'", with the message as 9front's pexit makes it.
    var f = std.mem.tokenizeScalar(u8, t.waits[0][0..t.wait_lens[0]], ' ');
    try std.testing.expectEqualStrings("2", f.next().?);
    _ = f.next();
    _ = f.next();
    _ = f.next();
    try std.testing.expectEqualStrings("'test 2: boom'", f.rest());
    try std.testing.expect(std.mem.startsWith(u8, t.waits[1][0..t.wait_lens[1]], "3 "));
    try std.testing.expect(std.mem.endsWith(u8, t.waits[1][0..t.wait_lens[1]], " ''"));
    try std.testing.expect(std.mem.startsWith(u8, t.waits[2][0..t.wait_lens[2]], "4 "));
    try std.testing.expectEqualStrings("no living children", t.no_child[0..t.no_child_len]);
}
