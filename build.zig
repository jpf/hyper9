const std = @import("std");

const drawterm = "third_party/drawterm";

// kern/Makefile OFILES for OS=posix, AUDIO=none.
const kern_sources = [_][]const u8{
    "alloc.c",        "allocb.c",        "chan.c",     "data.c",        "dev.c",
    "devaudio.c",     "devaudio-none.c", "devcmd.c",   "devcons.c",     "devdraw.c",
    "devenv.c",       "devfs-posix.c",   "devip.c",    "devip-posix.c", "devkbd.c",
    "devlfd-posix.c", "devmnt.c",        "devmouse.c", "devpipe.c",     "devroot.c",
    "devssl.c",       "devtls.c",        "devtab.c",   "error.c",       "parse.c",
    "pgrp.c",         "procinit.c",      "rwlock.c",   "sleep.c",       "stub.c",
    "sysfile.c",      "qio.c",           "qlock.c",    "term.c",        "waserror.c",
    "posix.c",
};

const kern_flags = [_][]const u8{
    "-Wall",
    "-Wno-missing-braces",
    "-D_THREAD_SAFE",
    "-fno-sanitize=undefined",
};

/// Zig's own macOS SDK detection runs xcodebuild, which fails in some
/// environments; SDKROOT (set by scripts/env.sh) is used when present.
fn addSdkPaths(b: *std.Build, m: *std.Build.Module) void {
    const sdk = b.graph.environ_map.get("SDKROOT") orelse return;
    m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
}

pub const Emu = enum { none, unicorn };

/// Directory under .local/unicorn (see UNICORN_WHEELS in scripts/pins.sh)
/// with the prebuilt libunicorn.a for this target, if one exists.
fn unicornDir(t: std.Target) ?[]const u8 {
    return switch (t.os.tag) {
        .macos => if (t.cpu.arch == .aarch64) "aarch64-macos" else null,
        .linux => if (t.abi.isMusl()) switch (t.cpu.arch) {
            .aarch64 => "aarch64-linux-musl",
            .x86_64 => "x86_64-linux-musl",
            else => null,
        } else null,
        else => null,
    };
}

/// Adds the prebuilt Unicorn: returns its translated header as a module and
/// records the static library for `linkUnicorn`.
fn addUnicorn(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Module {
    const name = unicornDir(target.result) orelse {
        b.getInstallStep().dependOn(&b.addFail("-Demu=unicorn: no prebuilt Unicorn for this target (macOS arm64 and linux-musl arm64/x86_64 only)").step);
        return null;
    };
    const dir = b.pathJoin(&.{ ".local/unicorn", name });
    const lib = b.pathJoin(&.{ dir, "lib/libunicorn.a" });
    if (b.build_root.handle.access(b.graph.io, lib, .{})) {} else |_| {
        b.getInstallStep().dependOn(&b.addFail(b.fmt("{s} is missing; run scripts/fetch.sh", .{lib})).step);
        return null;
    }
    const wf = b.addWriteFiles();
    const h = wf.add("unicorn.h", "#include <unicorn/unicorn.h>\n");
    const tc = b.addTranslateC(.{ .root_source_file = h, .target = target, .optimize = optimize });
    tc.addIncludePath(b.path(b.pathJoin(&.{ dir, "include" })));
    unicorn_lib = b.path(lib);
    if (target.result.os.tag == .linux and target.result.cpu.arch == .aarch64) {
        // An archive, not a source file: the root module's objects can reach
        // the linker twice, and archive members don't clash.
        const compat = b.addLibrary(.{
            .name = "unicorn_compat",
            .linkage = .static,
            .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
        });
        compat.root_module.addAssemblyFile(b.path("src/vmm/unicorn_compat_aarch64.S"));
        unicorn_compat = compat;
    }
    return tc.createModule();
}

var unicorn_lib: ?std.Build.LazyPath = null;
var unicorn_compat: ?*std.Build.Step.Compile = null;

/// Links the prebuilt Unicorn into the compile step's root module.
fn linkUnicorn(c: *std.Build.Step.Compile) void {
    const lib = unicorn_lib orelse return;
    const m = c.root_module;
    m.link_libc = true;
    m.addObjectFile(lib);
    if (unicorn_compat) |compat| m.linkLibrary(compat);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    var emu = b.option(Emu, "emu", "Emulator backend to build in (GPLv2 Unicorn: dev and CI builds only)") orelse .none;

    const mod = b.addModule("hp9", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    if (emu == .unicorn) {
        // On failure addUnicorn has already made the install step fail.
        if (addUnicorn(b, target, optimize)) |uc| mod.addImport("unicorn", uc) else emu = .none;
    }
    const options = b.addOptions();
    options.addOption(Emu, "emu", emu);
    mod.addOptions("build_options", options);

    // The arm64 guest shim, assembled freestanding and embedded as raw bytes.
    const shim_obj = b.addObject(.{
        .name = "shim_arm64",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });
    shim_obj.root_module.addAssemblyFile(b.path("src/arch/arm64/shim.S"));
    const shim_bin = b.addObjCopy(shim_obj.getEmittedBin(), .{ .format = .bin, .only_section = ".text" });
    mod.addAnonymousImport("shim_arm64", .{ .root_source_file = shim_bin.getOutput() });

    const kern = b.addLibrary(.{
        .name = "kern",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    kern.root_module.addIncludePath(b.path(drawterm));
    kern.root_module.addIncludePath(b.path(drawterm ++ "/include"));
    kern.root_module.addIncludePath(b.path(drawterm ++ "/kern"));
    kern.root_module.addCSourceFiles(.{
        .root = b.path(drawterm ++ "/kern"),
        .files = &kern_sources,
        .flags = &kern_flags,
    });
    const kern_step = b.step("kern", "Compile drawterm's kern");
    const have_drawterm = if (b.build_root.handle.access(b.graph.io, drawterm ++ "/kern/sysfile.c", .{})) true else |_| false;
    if (!have_drawterm) {
        const fail = b.addFail(drawterm ++ " is missing; run scripts/vendor-drawterm.sh");
        kern.step.dependOn(&fail.step);
    }
    // TODO(M2): build kern for Windows (drawterm's Make.win64 configuration).
    const build_kern = have_drawterm and os != .windows;
    if (os == .windows) {
        kern_step.dependOn(&b.addFail("kern doesn't build for Windows yet (M2)").step);
    } else {
        kern_step.dependOn(&kern.step);
    }

    const exe = b.addExecutable(.{
        .name = "hp9",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "hp9", .module = mod }},
        }),
    });
    if (os == .macos) {
        addSdkPaths(b, exe.root_module);
        addSdkPaths(b, kern.root_module);
        exe.root_module.linkFramework("Hypervisor", .{});
    }
    linkUnicorn(exe);
    // TODO(M2): link kern into hp9 once the syscall seam exists.
    if (build_kern) exe.step.dependOn(&kern.step);

    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    // HVF refuses hv_vm_create without the hypervisor entitlement.
    var signed_step = &install_exe.step;
    if (os == .macos and b.graph.host.result.os.tag == .macos) {
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
        sign.addFileArg(b.path("hp9.entitlements"));
        sign.addArg(b.getInstallPath(.bin, exe.out_filename));
        sign.step.dependOn(&install_exe.step);
        b.getInstallStep().dependOn(&sign.step);
        signed_step = &sign.step;
    }

    const run_cmd = b.addSystemCommand(&.{b.getInstallPath(.bin, exe.out_filename)});
    run_cmd.step.dependOn(signed_step);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run hp9").dependOn(&run_cmd.step);

    // M0/M1 fixtures: hand-assembled hello a.outs for arm64 and amd64.
    const mkhello = b.addExecutable(.{
        .name = "mkhello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/mkhello.zig"),
            .target = b.graph.host,
            .imports = &.{
                .{ .name = "aout", .module = b.createModule(.{ .root_source_file = b.path("src/aout.zig"), .target = b.graph.host }) },
                .{ .name = "hello", .module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/hello.zig"), .target = b.graph.host }) },
            },
        }),
    });
    var hellos: [2]std.Build.LazyPath = undefined;
    for (&hellos, [_][]const u8{ "arm64", "amd64" }, [_][]const u8{ "hello", "hello-amd64" }) |*out, arch, name| {
        const gen = b.addRunArtifact(mkhello);
        gen.addArg(arch);
        out.* = gen.addOutputFileArg(name);
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(out.*, .{ .custom = "fixtures" }, name).step);
    }

    const m0 = b.addSystemCommand(&.{b.getInstallPath(.bin, exe.out_filename)});
    m0.addFileArg(hellos[0]);
    m0.expectStdOutEqual("hello\n");
    m0.step.dependOn(signed_step);
    b.step("m0", "Run the M0 demo: hp9 ./hello").dependOn(&m0.step);

    // The M1 demo runs the host architecture's hello on the emulator.
    const m1_step = b.step("m1", "Run the M1 demo: hp9 --backend emu ./hello (needs -Demu=unicorn)");
    if (emu != .unicorn) {
        m1_step.dependOn(&b.addFail("the M1 demo needs -Demu=unicorn").step);
    } else {
        const m1 = b.addSystemCommand(&.{ b.getInstallPath(.bin, exe.out_filename), "--backend", "emu" });
        m1.addFileArg(if (target.result.cpu.arch == .x86_64) hellos[1] else hellos[0]);
        m1.expectStdOutEqual("hello\n");
        m1.step.dependOn(signed_step);
        m1_step.dependOn(&m1.step);
    }

    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    linkUnicorn(mod_tests); // exe_tests shares exe's root module, already linked
    // Runs the same programs on every backend built in and compares them.
    const backend_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/backends.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hp9", .module = mod },
            .{ .name = "hello", .module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/hello.zig"), .target = target }) },
        },
    }) });
    if (os == .macos) {
        addSdkPaths(b, backend_tests.root_module);
        backend_tests.root_module.linkFramework("Hypervisor", .{});
    }
    linkUnicorn(backend_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    // HVF needs the entitlement, so the test binary is signed like hp9.
    const run_backend_tests = b.addRunArtifact(backend_tests);
    if (os == .macos and b.graph.host.result.os.tag == .macos) {
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
        sign.addFileArg(b.path("hp9.entitlements"));
        sign.addFileArg(backend_tests.getEmittedBin());
        run_backend_tests.step.dependOn(&sign.step);
    }
    test_step.dependOn(&run_backend_tests.step);

    // For running the backend tests in a VM: zig-out/bin/backend-tests.
    const install_tests = b.addInstallArtifact(backend_tests, .{ .dest_sub_path = "backend-tests" });
    b.step("install-tests", "Install the backend tests as zig-out/bin/backend-tests").dependOn(&install_tests.step);
}
