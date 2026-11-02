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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;

    const mod = b.addModule("hp9", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

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
    kern_step.dependOn(&kern.step);

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
    // TODO(M1): link kern into hp9 once the syscall seam exists.
    if (have_drawterm) exe.step.dependOn(&kern.step);

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

    // M0 fixture: a hand-assembled arm64 hello a.out.
    const mkhello = b.addExecutable(.{
        .name = "mkhello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/mkhello.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "aout", .module = b.createModule(.{
                .root_source_file = b.path("src/aout.zig"),
                .target = b.graph.host,
            }) }},
        }),
    });
    const gen_hello = b.addRunArtifact(mkhello);
    const hello = gen_hello.addOutputFileArg("hello");
    const install_hello = b.addInstallFileWithDir(hello, .{ .custom = "fixtures" }, "hello");
    b.getInstallStep().dependOn(&install_hello.step);

    const m0 = b.addSystemCommand(&.{b.getInstallPath(.bin, exe.out_filename)});
    m0.addFileArg(hello);
    m0.expectStdOutEqual("hello\n");
    m0.step.dependOn(signed_step);
    b.step("m0", "Run the M0 demo: hp9 ./hello").dependOn(&m0.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
