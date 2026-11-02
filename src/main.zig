const std = @import("std");
const hp9 = @import("hp9");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    const cfg = cli.parse(args) catch {
        std.debug.print(cli.usage, .{});
        return 2;
    };
    const path = cfg.argv[0];

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30)) catch |err| {
        std.debug.print("hp9: {s}: {t}\n", .{ path, err });
        return 1;
    };
    const hdr = hp9.aout.parse(bytes) catch |err| {
        std.debug.print("hp9: {s}: not a 9front executable: {t}\n", .{ path, err });
        return 1;
    };

    var out = std.Io.File.stdout().writerStreaming(io, &.{});
    var err_w = std.Io.File.stderr().writerStreaming(io, &.{});
    var machine = hp9.Machine.init(init.gpa, io, .{
        .backend = cfg.backend,
        .arch = hdr.arch,
        .trace = if (cfg.trace) &err_w.interface else null,
        .stdio = .{ .out = &out.interface, .err = &err_w.interface },
    }) catch |err| {
        std.debug.print("hp9: cannot create {t} machine for {t}: {s}\n", .{ cfg.backend, hdr.arch, explain(cfg.backend, err) });
        return 1;
    };
    defer machine.deinit();
    if (cfg.backend == .auto and machine.backend.kind() == .emu) {
        std.debug.print("hp9: warning: no usable hypervisor; using the emulator\n", .{});
    }

    const status = machine.run(bytes, cfg.argv) catch |err| {
        std.debug.print("hp9: {s}: {t}\n", .{ path, err });
        return 1;
    };
    switch (status) {
        .exited => |msg| {
            if (msg.len == 0) return 0;
            std.debug.print("{s}\n", .{msg});
            return 1;
        },
        .killed => |msg| {
            std.debug.print("hp9: {s}: {s}\n", .{ path, msg });
            return 1;
        },
    }
}

fn explain(want: hp9.vmm.BackendKind, err: hp9.vmm.CreateError) []const u8 {
    return switch (err) {
        error.HypervisorUnavailable => "no usable hypervisor (on macOS, is hp9 signed with hp9.entitlements?)",
        error.BackendNotBuilt => switch (want) {
            .emu, .auto => "the emulator isn't built into this hp9 (build with -Demu=unicorn)",
            else => "backend not built into this hp9",
        },
        error.WrongArch => "backend can't run this architecture",
        error.NotImplemented => "backend not implemented yet",
        else => @errorName(err),
    };
}

test {
    _ = cli;
}
