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
const consin = @import("consin.zig");

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

/// The C side, or stubs where kern isn't built so h9 still links.
const c = if (available) c_real else c_stub;

const c_stub = struct {
    fn h9_kern_boot() c_int {
        return -1;
    }
    fn h9_kern_park() noreturn {
        unreachable;
    }
    fn h9_kern_spawn(_: [*:0]const u8, _: *const fn (?*anyopaque) callconv(.c) void, _: ?*anyopaque) c_int {
        return -1;
    }
    fn h9_kern_pid() c_ulong {
        return 0;
    }
    fn h9_kern_fork(_: c_int, _: c_ulong, _: *const fn (?*anyopaque) callconv(.c) void, _: ?*anyopaque) c_int {
        return -1;
    }
    fn h9_kern_rfork(_: c_int) c_int {
        return -1;
    }
    fn h9_kern_await(_: [*]u8, _: c_int) c_int {
        return -1;
    }
    fn h9_kern_setexits(_: [*:0]const u8) void {}
    fn h9_kern_gpid() c_ulong {
        return 0;
    }
    fn h9_kern_setgpid(_: c_ulong) void {}
    fn h9_kern_settext(_: [*:0]const u8) void {}
    fn h9_kern_aux() ?*anyopaque {
        return null;
    }
    fn h9_kern_setaux(_: ?*anyopaque) void {}
    fn h9_kern_closeexec() void {}
    fn h9_kern_postnote(_: c_ulong, _: [*:0]const u8, _: c_int) c_int {
        return -1;
    }
    fn h9_kern_postnotepg(_: c_ulong, _: [*:0]const u8, _: c_int) void {}
    fn h9_kern_noteid() c_ulong {
        return 0;
    }
    fn h9_kern_setnotify(_: c_int) void {}
    fn h9_kern_notepending() c_int {
        return 0;
    }
    fn h9_kern_popnote(_: [*]u8, _: u64) c_int {
        return 0;
    }
    fn h9_kern_noted(_: c_int, _: [*]u8) c_int {
        return -1;
    }
    fn h9_kern_execnotes() void {}
    fn h9_kern_mach() ?*anyopaque {
        return null;
    }
    fn h9_kern_putmach(_: ?*anyopaque) void {}
    fn h9_kern_postmach(_: ?*anyopaque, _: c_int, _: [*:0]const u8, _: c_int) c_int {
        return 0;
    }
    fn syspipe(_: *[2]c_int) c_int {
        return -1;
    }
    fn h9_kern_user() [*:0]const u8 {
        return "none";
    }
    fn h9_kern_devmask(_: [*:0]const u8) void {}
    fn h9_kern_self() ?*anyopaque {
        return null;
    }
    fn h9_kern_interrupt(_: ?*anyopaque) void {}
    fn h9_kern_sleep(_: c_long) c_int {
        return -1;
    }
    fn h9_cons_wake(_: c_ulong) void {}
    var no_err: [ERRMAX:0]u8 = @splat(0);
    fn h9_kern_errstr() [*:0]u8 {
        return &no_err;
    }
    fn h9_fd2path(_: c_int, _: [*]u8, _: c_uint) c_int {
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
    fn h9_kern_chdir(_: [*:0]const u8) c_int {
        return -1;
    }
    fn h9_kern_setargs(_: [*]const u8, _: c_int) void {}
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
    extern fn h9_kern_boot() c_int;
    extern fn h9_kern_park() noreturn;
    extern fn h9_kern_spawn(name: [*:0]const u8, func: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) c_int;
    extern fn h9_kern_pid() c_ulong;
    extern fn h9_kern_fork(flag: c_int, pid: c_ulong, func: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) c_int;
    extern fn h9_kern_rfork(flag: c_int) c_int;
    extern fn h9_kern_await(buf: [*]u8, n: c_int) c_int;
    extern fn h9_kern_setexits(msg: [*:0]const u8) void;
    extern fn h9_kern_gpid() c_ulong;
    extern fn h9_kern_setgpid(pid: c_ulong) void;
    extern fn h9_kern_settext(text: [*:0]const u8) void;
    extern fn h9_kern_aux() ?*anyopaque;
    extern fn h9_kern_setaux(aux: ?*anyopaque) void;
    extern fn h9_kern_closeexec() void;
    extern var h9_notekick: ?*const fn (?*anyopaque) callconv(.c) void;
    extern fn h9_kern_postnote(pid: c_ulong, msg: [*:0]const u8, flag: c_int) c_int;
    extern fn h9_kern_postnotepg(noteid: c_ulong, msg: [*:0]const u8, flag: c_int) void;
    extern fn h9_kern_noteid() c_ulong;
    extern fn h9_kern_setnotify(on: c_int) void;
    extern fn h9_kern_notepending() c_int;
    extern fn h9_kern_popnote(msg: [*]u8, pc: u64) c_int;
    extern fn h9_kern_noted(arg: c_int, msg: [*]u8) c_int;
    extern fn h9_kern_execnotes() void;
    extern fn h9_kern_mach() ?*anyopaque;
    extern fn h9_kern_putmach(m: ?*anyopaque) void;
    extern fn h9_kern_postmach(m: ?*anyopaque, all: c_int, msg: [*:0]const u8, flag: c_int) c_int;
    extern fn syspipe(fd: *[2]c_int) c_int;
    extern fn h9_kern_user() [*:0]const u8;
    extern fn h9_kern_devmask(devs: [*:0]const u8) void;
    extern fn h9_kern_self() ?*anyopaque;
    extern fn h9_kern_interrupt(p: ?*anyopaque) void;
    extern fn h9_kern_sleep(ms: c_long) c_int;
    extern fn h9_cons_wake(id: c_ulong) void;
    extern fn h9_kern_errstr() [*:0]u8;
    extern fn h9_fd2path(fd: c_int, buf: [*]u8, n: c_uint) c_int;
    extern fn sysopen(name: [*:0]const u8, mode: c_int) c_int;
    extern fn syscreate(name: [*:0]const u8, mode: c_int, perm: c_uint) c_int;
    extern fn sysclose(fd: c_int) c_int;
    extern fn syspread(fd: c_int, buf: [*]u8, n: c_int, off: i64) c_int;
    extern fn syspwrite(fd: c_int, buf: [*]const u8, n: c_int, off: i64) c_int;
    extern fn sysseek(fd: c_int, off: i64, whence: c_int) i64;
    extern fn sysbind(old: [*:0]const u8, new: [*:0]const u8, flag: c_int) c_int;
    extern fn sysmount(fd: c_int, afd: c_int, new: [*:0]const u8, flag: c_int, spec: [*:0]const u8) c_int;
    extern fn sysunmount(old: ?[*:0]const u8, new: [*:0]const u8) c_int;
    extern fn h9_kern_chdir(name: [*:0]const u8) c_int;
    extern fn h9_kern_setargs(args: [*]const u8, n: c_int) void;
    extern var h9_procstatus: ?*const fn (?*anyopaque, [*]u8, c_int, *c_ulong) callconv(.c) void;
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
    const ok = c.h9_kern_boot() >= 0;
    boot_state.store(if (ok) .up else .failed, .release);
    // The thread is the boot Proc now, which h9_kern_spawn clones from.
    if (ok) c.h9_kern_park();
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
    if (c.h9_kern_spawn(name, Tramp.run, arg) < 0) return error.OutOfMemory;
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
    _ = try check(c.h9_kern_fork(flag, child_pid, Tramp.run, arg));
}

/// rfork without RF.PROC: changes the caller's own groups.
pub fn rfork(flag: c_int) Error!void {
    _ = try check(c.h9_kern_rfork(flag));
}

/// Waits for a child to exit and writes its wait message to `buf`, as the
/// await syscall returns it: "pid utime stime real 'msg'". Fails with "no
/// living children" when there are none.
pub fn await(buf: []u8) Error!usize {
    return try check(c.h9_kern_await(buf.ptr, clampLen(buf.len)));
}

/// Sets the exit string the parent's wait record carries; "" is success.
pub fn setExits(msg: [*:0]const u8) void {
    c.h9_kern_setexits(msg);
}

/// The calling process's machine-local pid (0 if never set).
pub fn guestPid() u32 {
    return @intCast(c.h9_kern_gpid());
}

pub fn setGuestPid(p: u32) void {
    c.h9_kern_setgpid(p);
}

/// Sets the process's name, as wait messages show it.
pub fn setText(text: [*:0]const u8) void {
    c.h9_kern_settext(text);
}

/// The Zig process attached to the calling kernel process.
pub fn aux() ?*anyopaque {
    return c.h9_kern_aux();
}

pub fn setAux(p: ?*anyopaque) void {
    c.h9_kern_setaux(p);
}

/// Closes the calling process's close-on-exec fds.
pub fn closeExec() void {
    c.h9_kern_closeexec();
}

/// Sets the hook a note posted to a process calls, with the process's
/// `aux`, so a process running guest code takes an exit and sees it. It
/// runs on the posting thread with the target's note lock held, and only
/// while `aux` is set; it must not post notes or block.
pub fn setNoteKick(f: *const fn (?*anyopaque) callconv(.c) void) void {
    if (available) c.h9_notekick = f;
}

/// Sets the hook /proc/n/status calls, with the process's `aux`, for its
/// state (into a buffer of the given size) and its memory in KiB. It runs
/// on the reading thread with the target's note lock held, and only while
/// `aux` is set; it must not block or make kernel calls.
pub fn setProcStatus(f: *const fn (?*anyopaque, [*]u8, c_int, *c_ulong) callconv(.c) void) void {
    if (available) c.h9_procstatus = f;
}

/// The most of exec's argv /proc/n/args keeps, as 9front's exec.
pub const args_max = 128;

/// Records exec's argv for /proc/n/args: the strings NUL-terminated and
/// run together, cut to `args_max` bytes at a character boundary.
pub fn setArgs(argv: []const []const u8) void {
    var buf: [args_max]u8 = undefined;
    const n = packArgs(&buf, argv);
    c.h9_kern_setargs(&buf, @intCast(n));
}

fn packArgs(buf: *[args_max]u8, argv: []const []const u8) usize {
    var n: usize = 0;
    for (argv) |a| {
        if (n == buf.len) break;
        if (n + a.len + 1 > buf.len) {
            // As 9front: keep what fits, ending at a UTF-8 boundary.
            var k = buf.len - 1 - n;
            if (k > a.len) k = a.len;
            while (k > 0 and k < a.len and (a[k] & 0xc0) == 0x80) k -= 1;
            @memcpy(buf[n..][0..k], a[0..k]);
            n += k;
            buf[n] = 0;
            n += 1;
            break;
        }
        @memcpy(buf[n..][0..a.len], a);
        n += a.len;
        buf[n] = 0;
        n += 1;
    }
    return n;
}

test "packArgs cuts argv to args_max at a character boundary" {
    var buf: [args_max]u8 = undefined;
    try std.testing.expectEqualStrings("ar\x00vu\x00", buf[0..packArgs(&buf, &.{ "ar", "vu" })]);

    // Exactly full, then more arguments: ar's argv in libc's mkfile.
    const full = "x" ** (args_max - 1);
    try std.testing.expectEqual(args_max, packArgs(&buf, &.{ full, "a.7", "b.7" }));
    try std.testing.expectEqual(0, buf[args_max - 1]);

    // The cut would fall inside é, so it backs up to before it.
    const long = "y" ** (args_max - 5) ++ "\u{e9}z";
    const n = packArgs(&buf, &.{ "ab", long });
    try std.testing.expectEqual(args_max - 1, n);
    try std.testing.expectEqualStrings("y" ** (args_max - 5), buf[3 .. n - 1]);
}

/// Who posted a note (9front's NUser, NExit, NDebug). A note that isn't
/// NUser drops the notes queued before it when the process can't handle
/// it; NDebug makes a death from it print "suicide: note".
pub const NoteFlag = enum(c_int) { user = 0, exit = 1, debug = 2 };

/// Posts a note to the process with machine-local `pid` in the caller's
/// machine. Returns false if its queue was full. Fails, with "process
/// exited" as the error string, if there's no such process.
pub fn postNote(to: u32, msg: [*:0]const u8, flag: NoteFlag) Error!bool {
    return try check(c.h9_kern_postnote(to, msg, @intFromEnum(flag))) != 0;
}

/// Posts a note to every process but the caller in note group `noteid` of
/// the caller's machine.
pub fn postNoteGroup(noteid: u32, msg: [*:0]const u8, flag: NoteFlag) void {
    c.h9_kern_postnotepg(noteid, msg, @intFromEnum(flag));
}

/// The calling process's note group: machine-local, inherited by children
/// and replaced by RF.NOTEG.
pub fn noteId() u32 {
    return @intCast(c.h9_kern_noteid());
}

/// Records whether the calling process has a note handler (`notify`).
pub fn setNotify(on: bool) void {
    c.h9_kern_setnotify(@intFromBool(on));
}

/// Whether the calling process has a note queued.
pub fn notePending() bool {
    return c.h9_kern_notepending() != 0;
}

/// What to do with a popped note.
pub const NoteAction = enum(c_int) {
    /// Nothing to deliver now.
    none = 0,
    /// Enter the handler; the process is in it until `noted`.
    handle = 1,
    /// The process dies with the note as its status.
    kill = 2,
    /// The same, after printing "suicide: note".
    kill_debug = 3,
};

/// Takes the calling process's next note into `msg`, as 9front's popnote
/// does: a "sys:" note posted to this process alone gets " pc=0x..." with
/// `pc` appended. User notes wait while the process is in its handler.
/// Also clears the "interrupt this call" flag.
pub fn popNote(msg: *[ERRMAX]u8, pc: u64) NoteAction {
    msg[0] = 0;
    return @enumFromInt(c.h9_kern_popnote(msg, pc));
}

/// noted's arguments (9front's libc.h).
pub const Noted = enum(c_int) { cont = 0, dflt = 1, save = 2, rstr = 3, _ };

/// The note bookkeeping of noted: `cont`, `save` and `rstr` leave the
/// handler, and `dflt` (or an unknown argument) kills the
/// process with the last note, which is put in `msg`. Fails, with the
/// error string set, for noted outside a handler with anything but `rstr`.
pub fn noted(arg: Noted, msg: *[ERRMAX]u8) Error!NoteAction {
    msg[0] = 0;
    const r = c.h9_kern_noted(@intFromEnum(arg), msg);
    if (r < 0) return error.Kern;
    return @enumFromInt(r);
}

/// A machine as the kernel sees it: the process tree from one `spawn`.
/// Holding one keeps it valid after its processes have exited.
pub const Mach = opaque {
    /// Releases the reference from `mach`.
    pub fn put(m: *Mach) void {
        c.h9_kern_putmach(m);
    }

    /// Who a host-side note goes to.
    pub const To = enum(c_int) {
        /// The foreground note group: the first process's.
        foreground = 0,
        /// Every process.
        all = 1,
    };

    /// Posts a note from the host side (Ctrl-C, hangup, a timeout). Safe
    /// from any thread, including ones that aren't kernel processes.
    /// Returns how many processes it reached.
    pub fn post(m: *Mach, to: To, msg: [*:0]const u8) u32 {
        return @intCast(c.h9_kern_postmach(m, @intFromEnum(to), msg, @intFromEnum(NoteFlag.user)));
    }
};

/// The calling process's machine, with a reference to release with `put`.
pub fn mach() ?*Mach {
    return @ptrCast(c.h9_kern_mach());
}

/// exec's reset of the calling process's notes: no handler, none queued.
pub fn execNotes() void {
    c.h9_kern_execnotes();
}

/// Makes a pipe and returns its two fds.
pub fn pipe() Error![2]u31 {
    var fd: [2]c_int = .{ -1, -1 };
    _ = try check(c.syspipe(&fd));
    return .{ @intCast(fd[0]), @intCast(fd[1]) };
}

/// The host user, which is the kernel's hostowner (eve).
pub fn user() []const u8 {
    return std.mem.span(c.h9_kern_user());
}

/// The calling Proc's kernel pid.
pub fn pid() u32 {
    return @intCast(c.h9_kern_pid());
}

/// Blocks future attaches of the devices named by `devs` (letters, as in
/// `#U`) in the calling Proc's namespace. Existing binds keep working.
pub fn devmask(devs: [*:0]const u8) void {
    c.h9_kern_devmask(devs);
}

/// The calling kernel process, for `interrupt`.
pub const Proc = opaque {};

pub fn self() *Proc {
    return @ptrCast(c.h9_kern_self().?);
}

/// Makes the process's current or next blocking kernel call fail with
/// "interrupted". The caller must know the process hasn't exited.
pub fn interrupt(p: *Proc) void {
    c.h9_kern_interrupt(p);
}

/// Sleeps for `ms` milliseconds, or until the process is interrupted.
pub fn sleep(ms: i64) Error!void {
    _ = try check(c.h9_kern_sleep(@intCast(std.math.clamp(ms, std.math.minInt(c_long), std.math.maxInt(c_long)))));
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
    return std.mem.span(c.h9_kern_errstr());
}

/// Swaps `buf` (NUL-terminated, at most ERRMAX) with the error string, as
/// the errstr syscall does.
pub fn swapErrstr(buf: *[ERRMAX]u8) void {
    const k = c.h9_kern_errstr();
    var tmp: [ERRMAX]u8 = undefined;
    const kl = std.mem.len(k);
    @memcpy(tmp[0..kl], k[0..kl]);
    tmp[kl] = 0;
    const bl = std.mem.indexOfScalar(u8, buf, 0) orelse ERRMAX - 1;
    @memcpy(k[0..bl], buf[0..bl]);
    k[bl] = 0;
    @memcpy(buf[0 .. kl + 1], tmp[0 .. kl + 1]);
}

/// Sets the error string, for errors h9 raises itself.
pub fn setErrstr(msg: []const u8) void {
    const k = c.h9_kern_errstr();
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

/// chdir, swapping dot so /proc/n readers never see it freed.
pub fn chdir(name: [*:0]const u8) Error!void {
    _ = try check(c.h9_kern_chdir(name));
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
    _ = try check(c.h9_fd2path(fd, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_uint)))));
}

/// One machine's console, behind `#y<id>` (src/kern/devhcons.c).
pub const Console = struct {
    /// Input from the run's reader thread; none means EOF.
    in: ?*consin.ConsoleInput,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    /// Puts the host terminal in or out of raw mode (Machine.Stdio.raw).
    raw: ?Raw = null,
    mutex: std.atomic.Mutex = .unlocked,
    raw_on: bool = false,

    pub const Raw = struct {
        ctx: *anyopaque,
        set: *const fn (ctx: *anyopaque, on: bool) void,
    };

    /// Turns raw mode on or off, if it isn't already.
    pub fn setRaw(con: *Console, on: bool) void {
        while (!con.mutex.tryLock()) std.atomic.spinLoopHint();
        defer con.mutex.unlock();
        if (con.raw_on == on) return;
        con.raw_on = on;
        if (con.raw) |r| r.set(r.ctx, on);
    }
};

/// Wakes a guest read on console `id` sleeping for input. Called from the
/// console's reader thread, which isn't a kernel process: drawterm's
/// wakeup only takes locks and signals the sleeper's thread.
pub fn wakeConsole(id: u32) void {
    c.h9_cons_wake(id);
}

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
        @export(&h9_cons_read, .{ .name = "h9_cons_read" });
        @export(&h9_cons_ready, .{ .name = "h9_cons_ready" });
        @export(&h9_cons_write, .{ .name = "h9_cons_write" });
        @export(&h9_cons_raw, .{ .name = "h9_cons_raw" });
        @export(&h9_policy_active, .{ .name = "h9_policy_active" });
        @export(&h9_policy_check, .{ .name = "h9_policy_check" });
    }
}

fn h9_policy_active() callconv(.c) c_int {
    return @intFromBool(fs_plan != null);
}

fn h9_policy_check(path: [*]const u8, len: c_long, op: c_int) callconv(.c) c_int {
    const p = fs_plan orelse return 0;
    const o = std.enums.fromInt(policy.Op, op) orelse return @intFromEnum(policy.Verdict.hidden);
    return @intFromEnum(p.check(path[0..@intCast(len)], o));
}

/// Returns the bytes read, 0 at EOF, -1 on error, or -2 when the caller
/// has to sleep until `h9_cons_ready` and try again.
fn h9_cons_read(id: c_ulong, buf: [*]u8, n: c_long) callconv(.c) c_long {
    const con = console(id) orelse return -1;
    const in = con.in orelse return 0;
    return @intCast(in.read(buf[0..@intCast(n)]));
}

fn h9_cons_ready(id: c_ulong) callconv(.c) c_int {
    const con = console(id) orelse return 1;
    const in = con.in orelse return 1;
    return @intFromBool(in.ready());
}

fn h9_cons_raw(id: c_ulong, on: c_int) callconv(.c) void {
    const con = console(id) orelse return;
    con.setRaw(on != 0);
}

fn h9_cons_write(id: c_ulong, fd: c_int, buf: [*]const u8, n: c_long) callconv(.c) c_long {
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
    try std.testing.expectEqualStrings("h9", t.sysname[0..t.sysname_len]);
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

test "notes queue per process, reach note groups and stay in their machine" {
    if (!available) return error.SkipZigTest;

    const T = struct {
        err: ?anyerror = null,
        where: []const u8 = "",
        done: std.atomic.Value(bool) = .init(false),
        /// Set by the first machine once its children are waiting; the
        /// second machine posts then, and sets `other_done`.
        ready: std.atomic.Value(bool) = .init(false),
        other_done: std.atomic.Value(bool) = .init(false),
        other_err: ?anyerror = null,
        other_noteid: u32 = 0,
        ids: [2]u32 = @splat(0),
        got: [2][ERRMAX]u8 = undefined,
        acts: [2]NoteAction = @splat(.none),

        const Self = @This();
        const Child = struct {
            t: *Self,
            i: usize,
            fn run(ch: *Child) void {
                ch.t.ids[ch.i] = noteId();
                // A note interrupts the sleep.
                while (!notePending()) sleep(5000) catch {};
                ch.t.acts[ch.i] = popNote(&ch.t.got[ch.i], 0);
            }
        };

        fn run(t: *Self) void {
            defer t.done.store(true, .release);
            t.body() catch |e| {
                if (t.err == null) t.err = e;
            };
        }
        fn body(t: *Self) !void {
            setGuestPid(1);
            var msg: [ERRMAX]u8 = undefined;

            // With a handler: user notes wait while in it, sys: notes get a pc.
            t.where = "handler";
            setNotify(true);
            if (!try postNote(1, "one", .user)) return error.NotQueued;
            _ = try postNote(1, "two", .user);
            if (popNote(&msg, 0) != .handle) return error.NotHandled;
            try std.testing.expectEqualStrings("one", std.mem.sliceTo(&msg, 0));
            if (popNote(&msg, 0) != .none) return error.NestedUserNote;
            if (try noted(.cont, &msg) != .none) return error.NotedKilled;
            if (popNote(&msg, 0) != .handle) return error.NotHandled;
            try std.testing.expectEqualStrings("two", std.mem.sliceTo(&msg, 0));
            _ = try noted(.cont, &msg);
            if (noted(.cont, &msg)) |_| return error.NotedOutsideHandler else |_| {}
            _ = try postNote(1, "sys: trap", .user);
            _ = popNote(&msg, 0x1234);
            try std.testing.expectEqualStrings("sys: trap pc=0x1234", std.mem.sliceTo(&msg, 0));
            if (try noted(.dflt, &msg) != .kill) return error.NotedDfltLived;
            try std.testing.expectEqualStrings("sys: trap pc=0x1234", std.mem.sliceTo(&msg, 0));
            execNotes();
            if (postNote(99, "x", .user)) |_| return error.NoSuchProcess else |_| {}

            // Children: 2 shares the note group, 3 has its own.
            t.where = "groups";
            var c0: Child = .{ .t = t, .i = 0 };
            var c1: Child = .{ .t = t, .i = 1 };
            try fork(RF.PROC, 2, Child, Child.run, &c0);
            try fork(RF.PROC | RF.NOTEG, 3, Child, Child.run, &c1);
            while (t.ids[0] == 0 or t.ids[1] == 0) std.Thread.yield() catch {};
            try std.testing.expectEqual(noteId(), t.ids[0]);
            if (t.ids[1] == t.ids[0]) return error.SameNoteGroup;

            // Another machine's group and pids don't reach these.
            t.ready.store(true, .release);
            while (!t.other_done.load(.acquire)) std.Thread.yield() catch {};
            if (t.other_err) |e| return e;
            try std.testing.expectEqual(noteId(), t.other_noteid);
            if (notePending()) return error.NoteToPoster;

            postNoteGroup(noteId(), "hangup", .user);
            var buf: [64]u8 = undefined;
            _ = try await(&buf);
            _ = try postNote(3, "die", .user);
            _ = try await(&buf);
            if (notePending()) return error.NoteToPoster;
        }

        fn other(t: *Self) void {
            defer t.other_done.store(true, .release);
            setGuestPid(1);
            while (!t.ready.load(.acquire)) std.Thread.yield() catch {};
            t.other_noteid = noteId();
            postNoteGroup(noteId(), "wrong machine", .user);
            if (postNote(2, "wrong machine", .user)) |_| {
                t.other_err = error.ReachedOtherMachine;
            } else |_| {}
        }
    };
    var t: T = .{};
    try spawn("test", T, T.run, &t);
    try spawn("other", T, T.other, &t);
    while (!t.done.load(.acquire)) std.Thread.yield() catch {};
    while (!t.other_done.load(.acquire)) std.Thread.yield() catch {};
    if (t.err) |e| {
        std.debug.print("failed in {s}\n", .{t.where});
        return e;
    }
    try std.testing.expectEqualStrings("hangup", std.mem.sliceTo(&t.got[0], 0));
    try std.testing.expectEqual(NoteAction.kill, t.acts[0]);
    try std.testing.expectEqualStrings("die", std.mem.sliceTo(&t.got[1], 0));
    try std.testing.expectEqual(NoteAction.kill, t.acts[1]);
}

test "#p lists and serves only the caller's machine, by machine-local pid" {
    if (!available) return error.SkipZigTest;
    const T = struct {
        const Self = @This();
        err: ?anyerror = null,
        where: []const u8 = "",
        ready: std.atomic.Value(u32) = .init(0),
        go: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(u32) = .init(0),
        lists: [2][64]u8 = undefined,
        list_lens: [2]usize = .{ 0, 0 },
        args: [64]u8 = undefined,
        args_len: usize = 0,
        killed: [64]u8 = undefined,
        killed_len: usize = 0,

        const Child = struct {
            fn run(t: *Self) void {
                // Waits to be killed through ctl.
                while (true) {
                    var msg: [ERRMAX]u8 = undefined;
                    if (popNote(&msg, 0) == .kill) {
                        const s = std.mem.sliceTo(&msg, 0);
                        @memcpy(t.killed[0..s.len], s);
                        t.killed_len = s.len;
                        setExits("killed");
                        return;
                    }
                    sleep(5) catch {};
                }
            }
        };

        fn machine(t: *Self, i: usize) void {
            defer _ = t.done.fetchAdd(1, .release);
            t.body(i) catch |e| {
                t.err = e;
            };
        }

        fn readAll(path: [*:0]const u8, buf: []u8) !usize {
            const fd = try open(path, OREAD);
            defer close(fd) catch {};
            var n: usize = 0;
            while (n < buf.len) {
                const k = try pread(fd, buf[n..], @intCast(n));
                if (k == 0) break;
                n += k;
            }
            return n;
        }

        fn body(t: *Self, i: usize) !void {
            setGuestPid(1);
            try bind("#p", "/", MREPL);
            setArgs(&.{ "prog", "a b", "c" });
            if (i == 0) {
                t.where = "fork";
                try fork(RF.PROC, 2, Self, Child.run, t);
            }
            _ = t.ready.fetchAdd(1, .release);
            while (!t.go.load(.acquire)) std.Thread.yield() catch {};

            // The directory: machine 0 has 1 and 2, machine 1 only 1.
            t.where = "list";
            const d = try open("/", OREAD);
            defer close(d) catch {};
            var buf: [4096]u8 = undefined;
            var off: usize = 0;
            while (true) {
                const n = try pread(d, &buf, 0);
                if (n == 0) break;
                var j: usize = 0;
                while (j + 2 <= n) {
                    const sz = std.mem.readInt(u16, buf[j..][0..2], .little) + 2;
                    // The name: after size[2] type[2] dev[4] qid[13] mode[4] atime[4] mtime[4] length[8].
                    const nl = std.mem.readInt(u16, buf[j + 41 ..][0..2], .little);
                    const name = buf[j + 43 ..][0..nl];
                    @memcpy(t.lists[i][off..][0..name.len], name);
                    off += name.len;
                    t.lists[i][off] = ' ';
                    off += 1;
                    j += sz;
                }
            }
            t.list_lens[i] = off;

            if (i == 1) {
                // Machine 0's pid 2 isn't visible here.
                t.where = "other machine";
                if (open("/2/status", OREAD)) |_| return error.SawOtherMachine else |_| {}
                return;
            }
            t.where = "args";
            t.args_len = try readAll("/1/args", &t.args);
            t.where = "kill";
            const ctl = try open("/2/ctl", OWRITE);
            defer close(ctl) catch {};
            _ = try pwrite(ctl, "kill", 0);
            var w: [128]u8 = undefined;
            _ = try await(&w);
        }
    };
    var t: T = .{};
    var m0: struct { t: *T } = .{ .t = &t };
    var m1: struct { t: *T } = .{ .t = &t };
    const M0 = struct {
        fn run(a: *@TypeOf(m0)) void {
            a.t.machine(0);
        }
    };
    const M1 = struct {
        fn run(a: *@TypeOf(m1)) void {
            a.t.machine(1);
        }
    };
    try spawn("m0", @TypeOf(m0), M0.run, &m0);
    try spawn("m1", @TypeOf(m1), M1.run, &m1);
    while (t.ready.load(.acquire) < 2) std.Thread.yield() catch {};
    t.go.store(true, .release);
    while (t.done.load(.acquire) < 2) std.Thread.yield() catch {};
    if (t.err) |e| {
        std.debug.print("failed in {s}\n", .{t.where});
        return e;
    }
    try std.testing.expectEqualStrings("1 2 ", t.lists[0][0..t.list_lens[0]]);
    try std.testing.expectEqualStrings("1 ", t.lists[1][0..t.list_lens[1]]);
    try std.testing.expectEqualStrings("prog 'a b' c", t.args[0..t.args_len]);
    try std.testing.expectEqualStrings("Killed", t.killed[0..t.killed_len]);
}
