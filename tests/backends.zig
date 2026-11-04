//! Runs the same programs on every backend built into this h9 and checks
//! that each one produces the expected output and syscall trace. Backends
//! that can't run here (no hypervisor, not built, wrong architecture) are
//! skipped; the test fails if none can.

const std = @import("std");
const h9 = @import("h9");
const hello = @import("hello");
const vmm = h9.vmm;
const aout = h9.aout;

const Result = struct {
    status: []const u8,
    out: []const u8,
    trace: []const u8,
};

/// Runs `bytes` on backend `kind`, or returns null if that backend can't run
/// `arch` binaries on this host.
fn runOn(gpa: std.mem.Allocator, kind: vmm.BackendKind, arch: aout.Arch, bytes: []const u8) !?Result {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var trace: std.Io.Writer.Allocating = .init(gpa);
    defer trace.deinit();

    var m = h9.Machine.init(gpa, std.testing.io, .{
        .backend = kind,
        .arch = arch,
        .trace = &trace.writer,
        .stdio = .{ .out = &out.writer, .err = &err.writer },
    }) catch |e| switch (e) {
        error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => return null,
        else => return e,
    };
    defer m.deinit();

    const status = try m.run(.{ .bytes = bytes }, &.{"hello"});
    const s = switch (status) {
        .exited => |msg| try std.fmt.allocPrint(gpa, "exited \"{s}\"", .{msg}),
        .killed => |msg| try std.fmt.allocPrint(gpa, "killed \"{s}\"", .{msg}),
    };
    return .{ .status = s, .out = try out.toOwnedSlice(), .trace = try trace.toOwnedSlice() };
}

fn image(gpa: std.mem.Allocator, arch: aout.Arch, text: []const u8) ![]u8 {
    const buf = try gpa.alloc(u8, aout.header_size + text.len);
    aout.writeTextHeader(buf[0..aout.header_size], arch, text.len);
    @memcpy(buf[aout.header_size..], text);
    return buf;
}

/// Little-endian bytes of arm64 instruction words.
fn words(comptime code: []const u32) [code.len * 4]u8 {
    var out: [code.len * 4]u8 = undefined;
    for (code, 0..) |w, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], w, .little);
    return out;
}

fn expectAll(arch: aout.Arch, bytes: []const u8, want: Result) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .emu }) |kind| {
        const got = try runOn(gpa, kind, arch, bytes) orelse continue;
        ran += 1;
        errdefer std.debug.print("backend {t}, {t} binary\n", .{ kind, arch });
        try std.testing.expectEqualStrings(want.status, got.status);
        try std.testing.expectEqualStrings(want.out, got.out);
        try std.testing.expectEqualStrings(want.trace, got.trace);
    }
    if (ran == 0) return error.SkipZigTest;
}

const hello_result: Result = .{
    .status = "exited \"\"",
    .out = hello.msg,
    .trace = "1 pwrite 1 6 = 6\n1 exits \"\"\n",
};

test "hello arm64" {
    const bytes = try image(std.testing.allocator, .arm64, &hello.arm64_text);
    defer std.testing.allocator.free(bytes);
    try expectAll(.arm64, bytes, hello_result);
}

test "hello amd64" {
    const bytes = try image(std.testing.allocator, .amd64, &hello.amd64_text);
    defer std.testing.allocator.free(bytes);
    try expectAll(.amd64, bytes, hello_result);
}

const exits_msg = "failed\x00";
const exits_result: Result = .{ .status = "exited \"failed\"", .out = "", .trace = "1 exits \"failed\"\n" };

test "exits with a message arm64" {
    // exits(msg). The message follows the code.
    const code = [_]u32{
        0xd10083ff, // sub  sp, sp, #32
        0x10000081, // adr  x1, msg (16 bytes ahead)
        0xf90007e1, // str  x1, [sp, #8]
        0xd2800100, // mov  x0, #8   EXITS
        0xd4000001, // svc  #0
    };
    const bytes = try image(std.testing.allocator, .arm64, &(words(&code) ++ exits_msg.*));
    defer std.testing.allocator.free(bytes);
    try expectAll(.arm64, bytes, exits_result);
}

test "exits with a message amd64" {
    const code = [_]u8{
        0x48, 0x83, 0xec, 0x20, // subq  $0x20, %rsp
        0x48, 0x8d, 0x05, 0x0e, 0x00, 0x00, 0x00, // leaq  msg(%rip), %rax
        0x48, 0x89, 0x44, 0x24, 0x08, // movq  %rax, 8(%rsp)
        0xbd, 0x08, 0x00, 0x00, 0x00, // movl  $8, %ebp   EXITS
        0x0f, 0x05, // syscall
        0xeb, 0xfe, // jmp   .
    };
    const bytes = try image(std.testing.allocator, .amd64, &(code ++ exits_msg.*));
    defer std.testing.allocator.free(bytes);
    try expectAll(.amd64, bytes, exits_result);
}

fn expectFault(arch: aout.Arch, text: []const u8, pc_off: u64) !void {
    const bytes = try image(std.testing.allocator, arch, text);
    defer std.testing.allocator.free(bytes);
    var buf: [128]u8 = undefined;
    const pc = aout.layout(arch).utzero + aout.header_size + pc_off;
    try expectAll(arch, bytes, .{
        .status = try std.fmt.bufPrint(&buf, "killed \"sys: trap: fault read addr=0x0 pc=0x{x}\"", .{pc}),
        .out = "",
        .trace = "",
    });
}

test "fault on unmapped memory arm64" {
    try expectFault(.arm64, &words(&.{
        0xd2800001, // mov  x1, #0
        0xf9400022, // ldr  x2, [x1]
    }), 4);
}

test "fault on unmapped memory amd64" {
    try expectFault(.amd64, &[_]u8{
        0x31, 0xc9, // xorl  %ecx, %ecx
        0x48, 0x8b, 0x01, // movq  (%rcx), %rax
    }, 2);
}

/// Loops until kicked from another thread; `run` must return `.interrupted`.
fn expectKick(arch: aout.Arch, text: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const bytes = try image(gpa, arch, text);
    defer gpa.free(bytes);
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .emu }) |kind| {
        var b = vmm.create(gpa, io, kind, .{ .arch = arch }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer b.destroy();
        const as = try b.newAddressSpace();
        defer as.destroy();
        var img = try h9.loader.load(gpa, b, as, bytes, &.{"spin"}, 1);
        defer img.segs.release(as);
        var v = try b.createVcpu();
        defer v.destroy();
        try v.setAddressSpace(as);
        var u: vmm.Ureg = .initExec(arch, img.entry, img.sp, img.tos);
        v.setUreg(&u);

        const Kicker = struct {
            fn run(vc: *vmm.Vcpu, i: std.Io) void {
                std.Io.sleep(i, .fromMilliseconds(50), .awake) catch {};
                vc.kick();
            }
        };
        const t = try std.Thread.spawn(.{}, Kicker.run, .{ &v, io });
        const exit = v.run();
        t.join();
        errdefer std.debug.print("backend {t}, {t} binary\n", .{ kind, arch });
        try std.testing.expectEqual(vmm.Exit.interrupted, try exit);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "kick interrupts a running vcpu arm64" {
    try expectKick(.arm64, &words(&.{0x14000000})); // b .
}

test "kick interrupts a running vcpu amd64" {
    try expectKick(.amd64, &[_]u8{ 0xeb, 0xfe }); // jmp .
}

/// Kicks with no delay, many times over, so some kicks land while `run` is
/// starting. Every run must still return `.interrupted`; a lost kick hangs.
fn expectKickRace(arch: aout.Arch, text: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const bytes = try image(gpa, arch, text);
    defer gpa.free(bytes);
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .emu }) |kind| {
        var b = vmm.create(gpa, io, kind, .{ .arch = arch }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer b.destroy();
        const as = try b.newAddressSpace();
        defer as.destroy();
        var img = try h9.loader.load(gpa, b, as, bytes, &.{"spin"}, 1);
        defer img.segs.release(as);
        var v = try b.createVcpu();
        defer v.destroy();
        try v.setAddressSpace(as);
        const u: vmm.Ureg = .initExec(arch, img.entry, img.sp, img.tos);

        const Kicker = struct {
            fn run(vc: *vmm.Vcpu, go: *std.atomic.Value(u32), n: u32) void {
                for (0..n) |i| {
                    while (go.load(.acquire) <= i) std.atomic.spinLoopHint();
                    vc.kick();
                }
            }
        };
        const rounds = 200;
        var go: std.atomic.Value(u32) = .init(0);
        const t = try std.Thread.spawn(.{}, Kicker.run, .{ &v, &go, rounds });
        defer t.join();
        errdefer std.debug.print("backend {t}, {t} binary\n", .{ kind, arch });
        for (0..rounds) |_| {
            v.setUreg(&u);
            _ = go.fetchAdd(1, .release);
            try std.testing.expectEqual(vmm.Exit.interrupted, try v.run());
        }
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "a kick racing the start of a run isn't lost arm64" {
    try expectKickRace(.arm64, &words(&.{0x14000000})); // b .
}

test "a kick racing the start of a run isn't lost amd64" {
    try expectKickRace(.amd64, &[_]u8{ 0xeb, 0xfe }); // jmp .
}

/// Runs `bytes` as a machine with `pol` on every backend that can, and
/// returns the statuses.
fn runPolicy(arch: aout.Arch, bytes: []const u8, pol: h9.Policy, want: []const u8) !void {
    const gpa = std.testing.allocator;
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .emu }) |kind| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = arch,
            .policy = pol,
            .stdio = .{ .out = &out.writer, .err = &out.writer },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer m.deinit();
        const status = try m.run(.{ .bytes = bytes }, &.{"t"});
        errdefer std.debug.print("backend {t}, {t} binary\n", .{ kind, arch });
        try std.testing.expectEqualStrings(want, switch (status) {
            .exited => |s| s,
            .killed => |s| s,
        });
        try std.testing.expect(!m.stuck);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "a timeout stops a spinning process arm64" {
    const bytes = try image(std.testing.allocator, .arm64, &words(&.{0x14000000})); // b .
    defer std.testing.allocator.free(bytes);
    try runPolicy(.arm64, bytes, .{ .timeout_ns = 100 * std.time.ns_per_ms }, "h9: timeout");
}

test "a timeout stops a spinning process amd64" {
    const bytes = try image(std.testing.allocator, .amd64, &[_]u8{ 0xeb, 0xfe }); // jmp .
    defer std.testing.allocator.free(bytes);
    try runPolicy(.amd64, bytes, .{ .timeout_ns = 100 * std.time.ns_per_ms }, "h9: timeout");
}

test "a timeout interrupts sleep arm64" {
    // sleep(100000), then spin.
    const code = words(&.{
        0xd10083ff, // sub  sp, sp, #32
        0xd290d401, // mov  x1, #0x86a0
        0xf2a00021, // movk x1, #1, lsl #16
        0xf90007e1, // str  x1, [sp, #8]
        0xd2800220, // mov  x0, #17   SLEEP
        0xd4000001, // svc  #0
        0x14000000, // b    .
    });
    const img = try image(std.testing.allocator, .arm64, &code);
    defer std.testing.allocator.free(img);
    try runPolicy(.arm64, img, .{ .timeout_ns = 100 * std.time.ns_per_ms }, "h9: timeout");
}

/// Runs `bytes` on every backend that can, with an owned and a pooled
/// vCPU, and checks the status (prefix) and output.
fn expectNotes(arch: aout.Arch, bytes: []const u8, want_status: []const u8, want_out: []const u8) !void {
    const gpa = std.testing.allocator;
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .emu }) |kind| for ([_]?u32{ null, 0 }) |own| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var err: std.Io.Writer.Allocating = .init(gpa);
        defer err.deinit();
        var m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = arch,
            .policy = .{ .timeout_ns = 10 * std.time.ns_per_s },
            .owned_vcpus = own,
            .stdio = .{ .out = &out.writer, .err = &err.writer },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer m.deinit();
        const status = try m.run(.{ .bytes = bytes }, &.{"t"});
        errdefer std.debug.print("backend {t}, {t} binary, owned_vcpus {?d}\n", .{ kind, arch, own });
        var sb: [300]u8 = undefined;
        const got = switch (status) {
            .exited => |t| try std.fmt.bufPrint(&sb, "exited {s}", .{t}),
            .killed => |t| try std.fmt.bufPrint(&sb, "killed {s}", .{t}),
        };
        if (!std.mem.startsWith(u8, got, want_status)) {
            std.debug.print("status: want prefix \"{s}\", got \"{s}\"\n", .{ want_status, got });
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqualStrings(want_out, out.written());
        ran += 1;
    };
    if (ran == 0) return error.SkipZigTest;
}

/// notify(handler); a bad syscall, whose note the handler catches: it
/// writes the note's first 17 bytes to fd 1 and calls noted(NCONT), and
/// the program carries on after the syscall to exits(nil). With
/// `with_handler` false, the notify is skipped (its svc becomes a nop).
fn noteProgramArm64(comptime with_handler: bool) [26 * 4]u8 {
    return words(&.{
        0xd100c3ff, // sub  sp, sp, #48
        0x10000141, // adr  x1, handler
        0xf90007e1, // str  x1, [sp, #8]
        0xd2800380, // mov  x0, #28           NOTIFY
        if (with_handler) 0xd4000001 else 0xd503201f, // svc #0 (or nop)
        0xd2800c60, // mov  x0, #99           no such call
        0xd4000001, // svc  #0
        0xf90007ff, // str  xzr, [sp, #8]     exits(nil)
        0xd2800100, // mov  x0, #8            EXITS
        0xd4000001, // svc  #0
        0x14000000, // b    .
        // handler(ureg, msg): msg is at sp+16.
        0xf9400be2, // ldr  x2, [sp, #16]
        0xd100c3ff, // sub  sp, sp, #48
        0xd2800021, // mov  x1, #1
        0xf90007e1, // str  x1, [sp, #8]      fd 1
        0xf9000be2, // str  x2, [sp, #16]     buf = msg
        0xd2800223, // mov  x3, #17
        0xf9000fe3, // str  x3, [sp, #24]     len
        0x92800004, // mov  x4, #-1
        0xf90013e4, // str  x4, [sp, #32]     offset
        0xd2800660, // mov  x0, #51           PWRITE
        0xd4000001, // svc  #0
        0xf90007ff, // str  xzr, [sp, #8]     NCONT
        0xd28003a0, // mov  x0, #29           NOTED
        0xd4000001, // svc  #0
        0x14000000, // b    .
    });
}

test "a note handler catches a note and noted(NCONT) resumes arm64" {
    const img = try image(std.testing.allocator, .arm64, &noteProgramArm64(true));
    defer std.testing.allocator.free(img);
    try expectNotes(.arm64, img, "exited ", "sys: bad sys call");
}

test "an unhandled note kills the process with the note and pc arm64" {
    const img = try image(std.testing.allocator, .arm64, &noteProgramArm64(false));
    defer std.testing.allocator.free(img);
    try expectNotes(.arm64, img, "killed sys: bad sys call pc=0x", "");
}

test "a note handler catches a note and noted(NCONT) resumes amd64" {
    // As noteProgramArm64; the handler's msg is at sp+16, its Ureg in BP.
    const code = [_]u8{
        0x48, 0x83, 0xec, 0x30, // subq  $0x30, %rsp
        0x48, 0x8d, 0x05, 0x25, 0x00, 0x00, 0x00, // leaq  handler(%rip), %rax
        0x48, 0x89, 0x44, 0x24, 0x08, // movq  %rax, 8(%rsp)
        0xbd, 0x1c, 0x00, 0x00, 0x00, // movl  $28, %ebp          NOTIFY
        0x0f, 0x05, // syscall
        0xbd, 0x63, 0x00, 0x00, 0x00, // movl  $99, %ebp          no such call
        0x0f, 0x05, // syscall
        0x48, 0xc7, 0x44, 0x24, 0x08, 0x00, 0x00, 0x00, 0x00, // movq  $0, 8(%rsp)
        0xbd, 0x08, 0x00, 0x00, 0x00, // movl  $8, %ebp           EXITS
        0x0f, 0x05, // syscall
        0xeb, 0xfe, // jmp   .
        // handler:
        0x48, 0x8b, 0x54, 0x24, 0x10, // movq  16(%rsp), %rdx     msg
        0x48, 0x83, 0xec, 0x30, // subq  $0x30, %rsp
        0x48, 0xc7, 0x44, 0x24, 0x08, 0x01, 0x00, 0x00, 0x00, // movq  $1, 8(%rsp)
        0x48, 0x89, 0x54, 0x24, 0x10, // movq  %rdx, 16(%rsp)
        0x48, 0xc7, 0x44, 0x24, 0x18, 0x11, 0x00, 0x00, 0x00, // movq  $17, 24(%rsp)
        0x48, 0xc7, 0x44, 0x24, 0x20, 0xff, 0xff, 0xff, 0xff, // movq  $-1, 32(%rsp)
        0xbd, 0x33, 0x00, 0x00, 0x00, // movl  $51, %ebp          PWRITE
        0x0f, 0x05, // syscall
        0x48, 0xc7, 0x44, 0x24, 0x08, 0x00, 0x00, 0x00, 0x00, // movq  $0, 8(%rsp)  NCONT
        0xbd, 0x1d, 0x00, 0x00, 0x00, // movl  $29, %ebp          NOTED
        0x0f, 0x05, // syscall
        0xeb, 0xfe, // jmp   .
    };
    comptime std.debug.assert(code[48] == 0x48 and code[49] == 0x8b); // handler at 0x30
    const img = try image(std.testing.allocator, .amd64, &code);
    defer std.testing.allocator.free(img);
    try expectNotes(.amd64, img, "exited ", "sys: bad sys call");
}

test "noted outside a handler fails, and a fault's note reaches the handler arm64" {
    // noted(NCONT) with no note fails and returns -1; then a fault on
    // address 0, which the handler from notify ends with noted(NDFLT).
    const code = words(&.{
        0xd100c3ff, // sub  sp, sp, #48
        0xf90007ff, // str  xzr, [sp, #8]     NCONT
        0xd28003a0, // mov  x0, #29           NOTED
        0xd4000001, // svc  #0
        0xb100041f, // cmn  x0, #1
        0x54000040, // b.eq +8
        0x14000000, // b    .                 (noted didn't fail)
        0x100000c1, // adr  x1, handler (+24)
        0xf90007e1, // str  x1, [sp, #8]
        0xd2800380, // mov  x0, #28           NOTIFY
        0xd4000001, // svc  #0
        0xf940001f, // ldr  xzr, [x0]         fault (x0 = 0)
        0x14000000, // b    .
        // handler: noted(NDFLT)
        0xd100c3ff, // sub  sp, sp, #48
        0xd2800021, // mov  x1, #1
        0xf90007e1, // str  x1, [sp, #8]      NDFLT
        0xd28003a0, // mov  x0, #29           NOTED
        0xd4000001, // svc  #0
        0x14000000, // b    .
    });
    const img = try image(std.testing.allocator, .arm64, &code);
    defer std.testing.allocator.free(img);
    try expectNotes(.arm64, img, "killed sys: trap: fault read addr=0x0 pc=0x", "");
}

/// A console input that blocks until cancelled, then gives `after` once.
const BlockingInput = struct {
    io: std.Io,
    after: []const u8,
    cancelled: std.atomic.Value(u32) = .init(0),
    served: bool = false,
    reads: std.atomic.Value(u32) = .init(0),
    interface: std.Io.Reader,

    fn init(b: *BlockingInput, io: std.Io, after: []const u8, buf: []u8) void {
        b.* = .{ .io = io, .after = after, .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buf, .seek = 0, .end = 0 } };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const b: *BlockingInput = @alignCast(@fieldParentPtr("interface", r));
        _ = b.reads.fetchAdd(1, .release);
        if (b.cancelled.load(.acquire) != 0) {
            if (b.served) return error.EndOfStream;
            b.served = true;
            return w.write(limit.sliceConst(b.after)) catch error.WriteFailed;
        }
        b.io.futexWaitUncancelable(u32, &b.cancelled.raw, 0);
        return error.ReadFailed;
    }

    fn cancel(ctx: *anyopaque, _: std.Thread) void {
        const b: *BlockingInput = @ptrCast(@alignCast(ctx));
        b.cancelled.store(1, .release);
        b.io.futexWake(u32, &b.cancelled.raw, 1);
    }

    fn reset(_: *anyopaque) void {}
};

/// pread(0, buf, 16, -1), then write what it read to fd 1 and exit.
const read_echo_arm64 = words(&.{
    0xd10103ff, // sub  sp, sp, #64
    0xf90007ff, // str  xzr, [sp, #8]     fd 0
    0x9100c3e1, // add  x1, sp, #48
    0xf9000be1, // str  x1, [sp, #16]     buf
    0xd2800202, // mov  x2, #16
    0xf9000fe2, // str  x2, [sp, #24]     len
    0x92800003, // mov  x3, #-1
    0xf90013e3, // str  x3, [sp, #32]     offset
    0xd2800640, // mov  x0, #50           PREAD
    0xd4000001, // svc  #0
    0xf9000fe0, // str  x0, [sp, #24]     len = bytes read
    0xd2800021, // mov  x1, #1
    0xf90007e1, // str  x1, [sp, #8]      fd 1
    0xd2800660, // mov  x0, #51           PWRITE
    0xd4000001, // svc  #0
    0xf90007ff, // str  xzr, [sp, #8]     exits(nil)
    0xd2800100, // mov  x0, #8            EXITS
    0xd4000001, // svc  #0
    0x14000000, // b    .
});

test "a timeout interrupts a console read, and its reader thread is cancelled" {
    const gpa = std.testing.allocator;
    const img = try image(gpa, .arm64, &read_echo_arm64);
    defer gpa.free(img);
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .emu }) |kind| {
        var in_buf: [64]u8 = undefined;
        var in: BlockingInput = undefined;
        in.init(std.testing.io, "", &in_buf);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = .arm64,
            .policy = .{ .timeout_ns = 100 * std.time.ns_per_ms },
            .stdio = .{
                .in = &in.interface,
                .in_cancel = .{ .ctx = &in, .func = BlockingInput.cancel, .reset = BlockingInput.reset },
                .out = &out.writer,
                .err = &out.writer,
            },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer m.deinit();
        errdefer std.debug.print("backend {t}\n", .{kind});
        const status = try m.run(.{ .bytes = img }, &.{"t"});
        try std.testing.expectEqualStrings("h9: timeout", status.killed);
        try std.testing.expect(!m.stuck);
        try std.testing.expect(in.reads.load(.acquire) >= 1);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "a console read returns input from the reader thread, and a later run sees EOF" {
    const gpa = std.testing.allocator;
    const img = try image(gpa, .arm64, &read_echo_arm64);
    defer gpa.free(img);
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .emu }) |kind| {
        var src: std.Io.Reader = .fixed("one\ntwo\n");
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = .arm64,
            .stdio = .{ .in = &src, .out = &out.writer, .err = &out.writer },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer m.deinit();
        errdefer std.debug.print("backend {t}\n", .{kind});
        // A fixed reader gives everything in one read; the guest reads 16
        // bytes, so a second run gets EOF and writes nothing.
        _ = try m.run(.{ .bytes = img }, &.{"t"});
        try std.testing.expectEqualStrings("one\ntwo\n", out.written());
        _ = try m.run(.{ .bytes = img }, &.{"t"});
        try std.testing.expectEqualStrings("one\ntwo\n", out.written());
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "the memory cap is exact" {
    const bytes = try image(std.testing.allocator, .arm64, &hello.arm64_text);
    defer std.testing.allocator.free(bytes);
    // The text page and the stack's first 68 KiB don't fit in 64 KiB (on
    // HVF, the kernel's page tables count too).
    const gpa = std.testing.allocator;
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .emu }) |kind| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = .arm64,
            .policy = .{ .memory = 64 << 10 },
            .stdio = .{ .out = &out.writer, .err = &out.writer },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer m.deinit();
        try std.testing.expectError(error.OutOfGuestMemory, m.run(.{ .bytes = bytes }, &.{"hello"}));
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

/// Runs `f(backend)` on each backend that can run arm64 here.
fn eachBackend(comptime f: fn (vmm.Backend) anyerror!void) !void {
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .emu }) |kind| {
        var b = vmm.create(std.testing.allocator, std.testing.io, kind, .{ .arch = .arm64, .memory = 64 << 20 }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer b.destroy();
        errdefer std.debug.print("backend {t}\n", .{kind});
        try f(b);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

fn byteAt(as: vmm.AddressSpace, va: u64) ?u8 {
    const s = as.translate(va, 1) orelse return null;
    return s[0];
}

fn setByte(as: vmm.AddressSpace, va: u64, v: u8) void {
    as.translate(va, 1).?[0] = v;
}

test "segments: fork shares text, copies the stack, and shares data only with RFMEM" {
    try eachBackend(struct {
        fn f(b: vmm.Backend) !void {
            const gpa = std.testing.allocator;
            const bytes = try image(gpa, .arm64, &hello.arm64_text);
            defer gpa.free(bytes);
            const as = try b.newAddressSpace();
            defer as.destroy();
            var img = try h9.loader.load(gpa, b, as, bytes, &.{"hello"}, 1);
            defer img.segs.release(as);
            // hello has no data or bss, so give it some.
            const data = img.segs.data.?.base;
            try img.segs.brk(data + vmm.page_size);
            const sp = img.sp;
            setByte(as, data, 1);
            setByte(as, sp, 1);

            for ([_]bool{ false, true }) |share| {
                const cas = try b.newAddressSpace();
                defer cas.destroy();
                var c = try img.segs.fork(cas, share);
                defer c.release(cas);
                try std.testing.expectEqual(img.segs.text.?, c.text.?);
                try std.testing.expectEqual(share, img.segs.data.? == c.data.?);
                try std.testing.expect(img.segs.stack.? != c.stack.?);
                // The child sees the parent's memory at fork time...
                try std.testing.expectEqual(@as(?u8, 1), byteAt(cas, data));
                try std.testing.expectEqual(@as(?u8, 1), byteAt(cas, sp));
                // ...and then only shared segments follow each other.
                setByte(cas, data, 2);
                setByte(cas, sp, 2);
                try std.testing.expectEqual(@as(?u8, if (share) 2 else 1), byteAt(as, data));
                try std.testing.expectEqual(@as(?u8, 1), byteAt(as, sp));
                setByte(as, data, 1);
                // Growing a shared break maps the pages into both spaces
                // (past the headroom the parent's mapping already has).
                const top = img.segs.brkTop();
                const far = top + (1 << 20);
                try c.brk(far + 1);
                try std.testing.expectEqual(share, byteAt(as, far) != null);
                try std.testing.expectEqual(@as(?u8, 0), byteAt(cas, far));
                // 9front won't shrink a segment others share.
                if (share) try std.testing.expectError(error.InUse, c.brk(top)) else try c.brk(top);
            }
        }
    }.f);
}

test "segments: brk grows and shrinks, and memory above the break is zeroed" {
    try eachBackend(struct {
        fn f(b: vmm.Backend) !void {
            const gpa = std.testing.allocator;
            const bytes = try image(gpa, .arm64, &hello.arm64_text);
            defer gpa.free(bytes);
            const as = try b.newAddressSpace();
            defer as.destroy();
            var img = try h9.loader.load(gpa, b, as, bytes, &.{"hello"}, 1);
            defer img.segs.release(as);
            const s = &img.segs;
            const base = s.brkTop();
            try std.testing.expectEqual(@as(?u8, null), byteAt(as, base));

            // Small steps don't each add a mapping (hello's data starts empty).
            for (1..9) |i| try s.brk(base + i * 100);
            try std.testing.expectEqual(base + vmm.page_size, s.brkTop());
            for (1..9) |i| try s.brk(base + i * vmm.page_size);
            try std.testing.expectEqual(@as(usize, 1), s.data.?.chunks.items.len);

            try s.brk(base + (1 << 20) + 1);
            try std.testing.expectEqual(base + (1 << 20) + vmm.page_size, s.brkTop());
            setByte(as, base + 10, 7);
            setByte(as, base + (1 << 20), 7);

            try s.brk(base);
            try std.testing.expectEqual(base, s.brkTop());
            try s.brk(base + (1 << 20) + 1);
            try std.testing.expectEqual(@as(?u8, 0), byteAt(as, base + 10));
            try std.testing.expectEqual(@as(?u8, 0), byteAt(as, base + (1 << 20)));

            try std.testing.expectError(error.NoVmem, s.brk(s.data.?.base - 1));
            try std.testing.expectError(error.NoVmem, s.brk(s.stack_floor + 1));
            try std.testing.expectError(error.NoVmem, s.brk(std.math.maxInt(u64)));
            // More than --memory.
            try std.testing.expectError(error.NoVmem, s.brk(base + (128 << 20)));
        }
    }.f);
}

test "segments: the stack grows down to its 16 MiB limit" {
    try eachBackend(struct {
        fn f(b: vmm.Backend) !void {
            const gpa = std.testing.allocator;
            const bytes = try image(gpa, .arm64, &hello.arm64_text);
            defer gpa.free(bytes);
            const as = try b.newAddressSpace();
            defer as.destroy();
            var img = try h9.loader.load(gpa, b, as, bytes, &.{"hello"}, 1);
            defer img.segs.release(as);
            const s = &img.segs;
            const l = aout.layout(.arm64);
            try std.testing.expect(s.stack.?.base > s.stack_floor);
            const deep = l.ustktop - (8 << 20);
            try std.testing.expectEqual(@as(?u8, null), byteAt(as, deep));
            try std.testing.expect(s.growStack(deep));
            try std.testing.expectEqual(@as(?u8, 0), byteAt(as, deep));
            try std.testing.expect(s.growStack(s.stack_floor));
            try std.testing.expectEqual(s.stack_floor, s.stack.?.base);
            try std.testing.expect(!s.growStack(s.stack_floor - 1));
            try std.testing.expect(!s.growStack(l.ustktop));
        }
    }.f);
}

test "segments: releasing a process's segments frees its memory" {
    try eachBackend(struct {
        fn f(b: vmm.Backend) !void {
            const gpa = std.testing.allocator;
            const bytes = try image(gpa, .arm64, &hello.arm64_text);
            defer gpa.free(bytes);
            // 64 MiB of guest memory, so 200 processes' worth only fits if
            // each one's pages come back.
            for (0..200) |_| {
                const as = try b.newAddressSpace();
                defer as.destroy();
                var img = try h9.loader.load(gpa, b, as, bytes, &.{"hello"}, 1);
                defer img.segs.release(as);
                try img.segs.brk(img.segs.brkTop() + (1 << 20));
                _ = img.segs.growStack(img.sp - (1 << 20));
                const cas = try b.newAddressSpace();
                defer cas.destroy();
                var c = try img.segs.fork(cas, false);
                c.release(cas);
            }
        }
    }.f);
}

test "pooled vCPUs carry FP state, the thread pointer and fork across processes arm64" {
    // Forks four times (16 processes), then each sets d8 and TPIDR_EL0 from
    // its Tos pid and makes 2000 syscalls, each one a fresh trip through
    // the shared pool when no vCPUs can be owned, so processes keep landing
    // on vCPUs others last used. Each checks both registers at the end, and
    // faults if either is wrong.
    const code = words(&.{
        0xaa0003f7, // mov  x23, x0            Tos
        0xd10083ff, // sub  sp, sp, #32
        0xd2800098, // mov  x24, #4
        // fork:
        0xd2800281, // mov  x1, #0x14          RFPROC|RFFDG
        0xf90007e1, // str  x1, [sp, #8]
        0xd2800260, // mov  x0, #19            RFORK
        0xd4000001, // svc  #0
        0xf1000718, // subs x24, x24, #1
        0x54ffff61, // b.ne fork
        0xb94042f4, // ldr  w20, [x23, #64]    Tos.pid
        0x91019294, // add  x20, x20, #100
        0x9e670288, // fmov d8, x20
        0xd51bd054, // msr  tpidr_el0, x20
        0xd280fa15, // mov  x21, #2000
        // loop:
        0xf90007ff, // str  xzr, [sp, #8]
        0xd2800220, // mov  x0, #17            SLEEP(0)
        0xd4000001, // svc  #0
        0xf10006b5, // subs x21, x21, #1
        0x54ffff81, // b.ne loop
        0x9e660116, // fmov x22, d8
        0xeb1402df, // cmp  x22, x20
        0x540000c1, // b.ne bad
        0xd53bd056, // mrs  x22, tpidr_el0
        0xeb1402df, // cmp  x22, x20
        0x54000061, // b.ne bad
        0xf90007ff, // str  xzr, [sp, #8]      exits(nil)
        0x14000002, // b    exit
        // bad:
        0xf9400000, // ldr  x0, [x0]           x0 is 0: a fault kills it
        // exit:
        0xd2800100, // mov  x0, #8             EXITS
        0xd4000001, // svc  #0
    });
    try expectPooled(.arm64, &code);
}

test "pooled vCPUs carry FP state and fork across processes amd64" {
    // As the arm64 test, with xmm8 and MXCSR (FS base isn't used by 9front
    // binaries, and Unicorn's user mode can't write it without a GDT).
    const code = [_]u8{
        0x49, 0x89, 0xc4, // movq  %rax, %r12          Tos
        0x48, 0x83, 0xec, 0x20, // subq  $0x20, %rsp
        0x49, 0xc7, 0xc5, 0x04, 0x00, 0x00, 0x00, // movq  $4, %r13
        // fork:
        0x48, 0xc7, 0x44, 0x24, 0x08, 0x14, 0x00, 0x00, 0x00, // movq $0x14, 8(%rsp)  RFPROC|RFFDG
        0xbd, 0x13, 0x00, 0x00, 0x00, // movl  $19, %ebp          RFORK
        0x0f, 0x05, // syscall
        0x49, 0xff, 0xcd, // decq  %r13
        0x75, 0xeb, // jne   fork
        0x41, 0x8b, 0x5c, 0x24, 0x40, // movl  64(%r12), %ebx     Tos.pid
        0x48, 0x83, 0xc3, 0x64, // addq  $100, %rbx
        0x66, 0x4c, 0x0f, 0x6e, 0xc3, // movq  %rbx, %xmm8
        0xc7, 0x44, 0x24, 0x10, 0x80, 0x7f, 0x00, 0x00, // movl $0x7f80, 16(%rsp)
        0x0f, 0xae, 0x54, 0x24, 0x10, // ldmxcsr 16(%rsp)          round down
        0x49, 0xc7, 0xc6, 0xd0, 0x07, 0x00, 0x00, // movq  $2000, %r14
        // loop:
        0x48, 0xc7, 0x44, 0x24, 0x08, 0x00, 0x00, 0x00, 0x00, // movq $0, 8(%rsp)
        0xbd, 0x11, 0x00, 0x00, 0x00, // movl  $17, %ebp          SLEEP(0)
        0x0f, 0x05, // syscall
        0x49, 0xff, 0xce, // decq  %r14
        0x75, 0xeb, // jne   loop
        0x66, 0x4c, 0x0f, 0x7e, 0xc1, // movq  %xmm8, %rcx
        0x48, 0x39, 0xd9, // cmpq  %rbx, %rcx
        0x75, 0x1a, // jne   bad
        0x0f, 0xae, 0x5c, 0x24, 0x10, // stmxcsr 16(%rsp)
        0x81, 0x7c, 0x24, 0x10, 0x80, 0x7f, 0x00, 0x00, // cmpl $0x7f80, 16(%rsp)
        0x75, 0x0b, // jne   bad
        0x48, 0xc7, 0x44, 0x24, 0x08, 0x00, 0x00, 0x00, 0x00, // movq $0, 8(%rsp)  exits(nil)
        0xeb, 0x05, // jmp   exit
        // bad:
        0x31, 0xc0, // xorl  %eax, %eax
        0x48, 0x8b, 0x00, // movq  (%rax), %rax       a fault kills it
        // exit:
        0xbd, 0x08, 0x00, 0x00, 0x00, // movl  $8, %ebp           EXITS
        0x0f, 0x05, // syscall
    };
    try expectPooled(.amd64, &code);
}

/// Runs `code` with the pool forced on (no owned vCPUs) and off, on every
/// backend that can, and expects a clean exit.
fn expectPooled(arch: aout.Arch, code: []const u8) !void {
    const gpa = std.testing.allocator;
    const bytes = try image(gpa, arch, code);
    defer gpa.free(bytes);
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .emu }) |kind| for ([_]u32{ 0, 1 }) |own| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = arch,
            .owned_vcpus = own,
            .stdio = .{ .out = &out.writer, .err = &out.writer },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer m.deinit();
        const status = try m.run(.{ .bytes = bytes }, &.{"t"});
        errdefer std.debug.print("backend {t}, {t}, owned_vcpus {d}\n", .{ kind, arch, own });
        var sb: [300]u8 = undefined;
        try std.testing.expectEqualStrings("exited ", switch (status) {
            .exited => |t| try std.fmt.bufPrint(&sb, "exited {s}", .{t}),
            .killed => |t| try std.fmt.bufPrint(&sb, "killed {s}", .{t}),
        });
        ran += 1;
    };
    if (ran == 0) return error.SkipZigTest;
}
