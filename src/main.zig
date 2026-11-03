const std = @import("std");
const hp9 = @import("hp9");
const cli = @import("cli.zig");

/// Exit codes for hp9's own failures (DESIGN.md, "Exit codes").
const exit_failed = 125;
const exit_not_executable = 126;
const exit_not_found = 127;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    const cfg = cli.parse(arena, args) catch {
        std.debug.print(cli.usage, .{});
        return 2;
    };
    const prog_arg = cfg.argv[0];

    // A host program is read here; a guest one is resolved in the machine.
    var arch: ?hp9.vmm.Arch = null;
    const prog: hp9.Program = switch (cli.programKind(prog_arg)) {
        .host => blk: {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, prog_arg, arena, .limited(1 << 30)) catch |err| {
                std.debug.print("hp9: {s}: {t}\n", .{ prog_arg, err });
                return if (err == error.FileNotFound) exit_not_found else exit_failed;
            };
            const hdr = hp9.aout.parse(bytes) catch |err| {
                std.debug.print("hp9: {s}: not a 9front executable: {t}\n", .{ prog_arg, err });
                return exit_not_executable;
            };
            arch = hdr.arch;
            break :blk .{ .bytes = bytes };
        },
        .guest => .{ .guest = prog_arg },
    };

    // #U takes absolute host paths, with symlinks resolved.
    const root_arg = cfg.root orelse init.environ_map.get("HP9ROOT") orelse defaultRoot(arena, io);
    const root = if (root_arg) |r| std.Io.Dir.cwd().realPathFileAlloc(io, r, arena) catch {
        std.debug.print("hp9: root {s}: not found\n", .{r});
        return exit_failed;
    } else null;
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, cfg.cwd orelse ".", arena) catch {
        std.debug.print("hp9: cwd {s}: not found\n", .{cfg.cwd orelse "."});
        return exit_failed;
    };
    var env: std.ArrayList(hp9.EnvVar) = .empty;
    for (cfg.env) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=').?;
        try env.append(arena, .{ .name = e[0..eq], .value = e[eq + 1 ..] });
    }

    var in_buf: [4096]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out = std.Io.File.stdout().writerStreaming(io, &.{});
    var err_w = std.Io.File.stderr().writerStreaming(io, &.{});
    var machine = hp9.Machine.init(init.gpa, io, .{
        .backend = cfg.backend,
        .arch = arch,
        .root = root,
        .cwd = cwd,
        .env = env.items,
        .trace = if (cfg.trace) &err_w.interface else null,
        .stdio = .{ .in = &in.interface, .out = &out.interface, .err = &err_w.interface },
    }) catch |err| {
        const a: hp9.vmm.Arch = arch orelse hp9.vmm.host_arch orelse .arm64;
        std.debug.print("hp9: cannot create {t} machine for {t}: {s}\n", .{ cfg.backend, a, explain(cfg.backend, err) });
        return exit_failed;
    };
    defer machine.deinit();
    if (cfg.backend == .auto and machine.backend.kind() == .emu) {
        std.debug.print("hp9: warning: no usable hypervisor; using the emulator\n", .{});
    }

    const status = machine.run(prog, cfg.argv) catch |err| {
        const why = if (machine.err_msg.len > 0) machine.err_msg else @errorName(err);
        std.debug.print("hp9: {s}: {s}\n", .{ prog_arg, why });
        return switch (err) {
            error.NotFound => exit_not_found,
            error.NotExecutable => exit_not_executable,
            else => exit_failed,
        };
    };
    switch (status) {
        .exited => |msg| {
            if (msg.len == 0) return 0;
            std.debug.print("{s}\n", .{msg});
            return 1;
        },
        .killed => |msg| {
            std.debug.print("hp9: {s}: {s}\n", .{ prog_arg, msg });
            return 1;
        },
    }
}

/// The default root: .local/9front/root beside the hp9 binary's source tree
/// in development builds (zig-out/bin/hp9 -> ../../.local/9front/root).
fn defaultRoot(arena: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const exe = std.process.executablePathAlloc(io, arena) catch return null;
    const dir = std.fs.path.dirname(exe) orelse return null;
    const root = std.fs.path.join(arena, &.{ dir, "..", "..", ".local", "9front", "root" }) catch return null;
    std.Io.Dir.cwd().access(io, root, .{}) catch return null;
    return root;
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
