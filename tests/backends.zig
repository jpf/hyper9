//! Runs the same programs on every backend built into this hp9 and checks
//! that each one produces the expected output and syscall trace. Backends
//! that can't run here (no hypervisor, not built, wrong architecture) are
//! skipped; the test fails if none can.

const std = @import("std");
const hp9 = @import("hp9");
const hello = @import("hello");
const vmm = hp9.vmm;
const aout = hp9.aout;

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

    var m = hp9.Machine.init(gpa, std.testing.io, .{
        .backend = kind,
        .arch = arch,
        .trace = &trace.writer,
        .stdio = .{ .out = &out.writer, .err = &err.writer },
    }) catch |e| switch (e) {
        error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => return null,
        else => return e,
    };
    defer m.deinit();

    const status = try m.run(bytes, &.{"hello"});
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
        const img = try hp9.loader.load(b, as, bytes, &.{"spin"}, 1);
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
