//! Builds Unicorn (GPLv2) from source for the emu backend: the patched
//! source that scripts/fetch.sh unpacks into .local/src/unicorn, with the
//! per-host QEMU config headers in third_party/unicorn/config. Only the
//! x86_64 and aarch64 guest targets are built. See third_party/unicorn.

const std = @import("std");

/// The source tree that scripts/fetch.sh unpacks and patches.
pub const src_dir = ".local/src/unicorn";
const config_dir = "third_party/unicorn/config";

/// Directory under third_party/unicorn/config for a host, if there is one.
pub fn configName(t: std.Target) ?[]const u8 {
    return switch (t.os.tag) {
        .macos => if (t.cpu.arch == .aarch64) "aarch64-macos" else null,
        .linux => if (t.abi.isMusl()) switch (t.cpu.arch) {
            .aarch64 => "aarch64-linux-musl",
            .x86_64 => "x86_64-linux-musl",
            else => null,
        } else null,
        .windows => if (t.cpu.arch == .aarch64 and t.abi == .gnu) "aarch64-windows-gnu" else null,
        else => null,
    };
}

pub const Unicorn = struct {
    /// Static libraries to link.
    libs: [3]*std.Build.Step.Compile,
    /// For translate-c of <unicorn/unicorn.h>.
    include: std.Build.LazyPath,
};

/// Returns null if there's no config for this target.
pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?Unicorn {
    const t = target.result;
    const cfg = b.path(b.pathJoin(&.{ config_dir, configName(t) orelse return null }));
    const src = b.path(src_dir);
    const tcg_host: []const u8 = if (t.cpu.arch == .x86_64) "i386" else "aarch64";

    const core = lib(b, "unicorn", target, optimize, src, cfg, tcg_host);
    core.root_module.addCSourceFiles(.{ .root = src, .files = &core_sources, .flags = &flags });
    core.root_module.addCSourceFiles(.{
        .root = src,
        .files = if (t.os.tag == .windows) &.{ "qemu/util/oslib-win32.c", "qemu/util/qemu-thread-posix.c" } else &.{ "qemu/util/oslib-posix.c", "qemu/util/qemu-thread-posix.c" },
        .flags = &flags,
    });

    // QEMU builds each guest target from the same files with a forced
    // include that renames its symbols. Zig keys C objects by path within a
    // module, so each target is its own library.
    var libs: [3]*std.Build.Step.Compile = undefined;
    libs[2] = core;
    for (guest_targets, 0..) |g, i| {
        const l = lib(b, b.fmt("{s}-softmmu", .{g.name}), target, optimize, src, cfg, tcg_host);
        const m = l.root_module;
        m.addIncludePath(cfg.path(b, b.fmt("{s}-softmmu", .{g.name})));
        m.addIncludePath(src.path(b, b.fmt("qemu/target/{s}", .{g.dir})));
        // The forced include must be an absolute path, or Zig doesn't track
        // it as a dependency and its cache check fails.
        const gflags = std.mem.concat(b.allocator, []const u8, &.{
            &flags,
            &.{ "-DNEED_CPU_H", "-include", b.pathFromRoot(b.fmt("{s}/qemu/{s}.h", .{ src_dir, g.name })) },
        }) catch @panic("OOM");
        m.addCSourceFiles(.{ .root = src, .files = &arch_common_sources, .flags = gflags });
        m.addCSourceFiles(.{ .root = src, .files = g.files, .flags = gflags });
        libs[i] = l;
    }
    return .{ .libs = libs, .include = src.path(b, "include") };
}

fn lib(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    src: std.Build.LazyPath,
    cfg: std.Build.LazyPath,
    tcg_host: []const u8,
) *std.Build.Step.Compile {
    const l = b.addLibrary(.{
        .name = name,
        .linkage = .static,
        // A Debug Unicorn is much slower and only helps when debugging
        // Unicorn itself, so it's optimized even in Debug builds of h9.
        .root_module = b.createModule(.{
            .target = target,
            .optimize = if (optimize == .Debug) .ReleaseFast else optimize,
            .link_libc = true,
        }),
    });
    const m = l.root_module;
    m.addIncludePath(cfg);
    for ([_][]const u8{ "glib_compat", "qemu", "qemu/include", "include", "qemu/tcg" }) |d| m.addIncludePath(src.path(b, d));
    m.addIncludePath(src.path(b, b.fmt("qemu/tcg/{s}", .{tcg_host})));
    return l;
}

// From Unicorn 2.1.4's CMakeLists.txt (non-MSVC), for the two targets.
const flags = [_][]const u8{
    "-std=gnu99",
    "-D_GNU_SOURCE",
    "-D_FILE_OFFSET_BITS=64",
    "-D_LARGEFILE_SOURCE",
    "-fno-strict-aliasing",
    "-fwrapv",
    "-fno-common",
    "-fno-sanitize=undefined",
    "-Wno-everything",
    "-DUNICORN_HAS_X86",
    "-DUNICORN_HAS_ARM64",
};

const GuestTarget = struct { name: []const u8, dir: []const u8, files: []const []const u8 };
const guest_targets = [_]GuestTarget{
    .{ .name = "x86_64", .dir = "i386", .files = &x86_64_sources },
    .{ .name = "aarch64", .dir = "arm", .files = &aarch64_sources },
};

// UNICORN_COMMON_SRCS and UNICORN_SRCS, without the oslib and thread files.
const core_sources = [_][]const u8{
    "list.c",
    "glib_compat/glib_compat.c",
    "glib_compat/gtestutils.c",
    "glib_compat/garray.c",
    "glib_compat/gtree.c",
    "glib_compat/grand.c",
    "glib_compat/glist.c",
    "glib_compat/gmem.c",
    "glib_compat/gpattern.c",
    "glib_compat/gslice.c",
    "qemu/util/bitmap.c",
    "qemu/util/bitops.c",
    "qemu/util/crc32c.c",
    "qemu/util/cutils.c",
    "qemu/util/getauxval.c",
    "qemu/util/guest-random.c",
    "qemu/util/host-utils.c",
    "qemu/util/osdep.c",
    "qemu/util/qdist.c",
    "qemu/util/qemu-timer.c",
    "qemu/util/qemu-timer-common.c",
    "qemu/util/range.c",
    "qemu/util/qht.c",
    "qemu/util/pagesize.c",
    "qemu/util/cacheinfo.c",
    "qemu/crypto/aes.c",
    "uc.c",
    "qemu/softmmu/vl.c",
    "qemu/hw/core/cpu.c",
};

// UNICORN_ARCH_COMMON: compiled once per guest target.
const arch_common_sources = [_][]const u8{
    "qemu/exec.c",
    "qemu/exec-vary.c",
    "qemu/softmmu/cpus.c",
    "qemu/softmmu/ioport.c",
    "qemu/softmmu/memory.c",
    "qemu/softmmu/memory_mapping.c",
    "qemu/fpu/softfloat.c",
    "qemu/tcg/optimize.c",
    "qemu/tcg/tcg.c",
    "qemu/tcg/tcg-op.c",
    "qemu/tcg/tcg-op-gvec.c",
    "qemu/tcg/tcg-op-vec.c",
    "qemu/accel/tcg/cpu-exec.c",
    "qemu/accel/tcg/cpu-exec-common.c",
    "qemu/accel/tcg/cputlb.c",
    "qemu/accel/tcg/tcg-all.c",
    "qemu/accel/tcg/tcg-runtime.c",
    "qemu/accel/tcg/tcg-runtime-gvec.c",
    "qemu/accel/tcg/translate-all.c",
    "qemu/accel/tcg/translator.c",
    "qemu/softmmu/unicorn_vtlb.c",
};

const x86_64_sources = [_][]const u8{
    "qemu/hw/i386/x86.c",
    "qemu/target/i386/arch_memory_mapping.c",
    "qemu/target/i386/bpt_helper.c",
    "qemu/target/i386/cc_helper.c",
    "qemu/target/i386/cpu.c",
    "qemu/target/i386/excp_helper.c",
    "qemu/target/i386/fpu_helper.c",
    "qemu/target/i386/helper.c",
    "qemu/target/i386/int_helper.c",
    "qemu/target/i386/machine.c",
    "qemu/target/i386/mem_helper.c",
    "qemu/target/i386/misc_helper.c",
    "qemu/target/i386/mpx_helper.c",
    "qemu/target/i386/seg_helper.c",
    "qemu/target/i386/smm_helper.c",
    "qemu/target/i386/svm_helper.c",
    "qemu/target/i386/translate.c",
    "qemu/target/i386/xsave_helper.c",
    "qemu/target/i386/unicorn.c",
};

const aarch64_sources = [_][]const u8{
    "qemu/target/arm/cpu64.c",
    "qemu/target/arm/cpu.c",
    "qemu/target/arm/crypto_helper.c",
    "qemu/target/arm/debug_helper.c",
    "qemu/target/arm/helper-a64.c",
    "qemu/target/arm/helper.c",
    "qemu/target/arm/iwmmxt_helper.c",
    "qemu/target/arm/m_helper.c",
    "qemu/target/arm/neon_helper.c",
    "qemu/target/arm/op_helper.c",
    "qemu/target/arm/pauth_helper.c",
    "qemu/target/arm/psci.c",
    "qemu/target/arm/sve_helper.c",
    "qemu/target/arm/tlb_helper.c",
    "qemu/target/arm/translate-a64.c",
    "qemu/target/arm/translate.c",
    "qemu/target/arm/translate-sve.c",
    "qemu/target/arm/vec_helper.c",
    "qemu/target/arm/vfp_helper.c",
    "qemu/target/arm/unicorn_aarch64.c",
};
