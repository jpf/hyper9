//! Emulator backend (Unicorn). Built with -Demu=unicorn. See DESIGN.md,
//! "Emulator backend (emu)".
//!
//! TODO(M1): only the Unicorn link and the engine probe exist so far.

const std = @import("std");
const vmm = @import("../vmm.zig");
const uc = @import("unicorn");

/// Unicorn's runtime version, e.g. "2.1".
pub fn version(buf: []u8) []const u8 {
    var major: c_uint = 0;
    var minor: c_uint = 0;
    _ = uc.uc_version(&major, &minor);
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ major, minor }) catch buf[0..0];
}

/// Checks that Unicorn can create an engine for `arch`.
pub fn probe(arch: vmm.Arch) vmm.Error!void {
    const a: uc.uc_arch, const mode: uc.uc_mode = switch (arch) {
        .arm64 => .{ uc.UC_ARCH_ARM64, uc.UC_MODE_ARM },
        .amd64 => .{ uc.UC_ARCH_X86, uc.UC_MODE_64 },
    };
    var engine: ?*uc.uc_engine = null;
    if (uc.uc_open(a, mode, &engine) != uc.UC_ERR_OK) return error.HypervisorFailed;
    _ = uc.uc_close(engine);
}

pub const Backend = struct {
    pub fn create(_: std.mem.Allocator, _: std.Io, opts: vmm.Options) vmm.CreateError!*Backend {
        try probe(opts.arch);
        return error.NotImplemented;
    }
    pub fn destroy(_: *Backend) void {}
    pub fn maxVcpus(_: *Backend) vmm.Error!u32 {
        return error.NotImplemented;
    }
    pub fn allocPages(_: *Backend, _: usize) vmm.Error![]align(vmm.page_size) u8 {
        return error.NotImplemented;
    }
    pub fn newAddressSpace(_: *Backend) vmm.CreateError!*AddressSpace {
        return error.NotImplemented;
    }
    pub fn createVcpu(_: *Backend) vmm.CreateError!Vcpu {
        return error.NotImplemented;
    }
};

pub const AddressSpace = struct {
    pub fn destroy(_: *AddressSpace) void {}
    pub fn map(_: *AddressSpace, _: u64, _: []align(vmm.page_size) u8, _: vmm.Perms) vmm.CreateError!void {
        return error.NotImplemented;
    }
    pub fn translate(_: *AddressSpace, _: u64, _: u64) ?[]u8 {
        return null;
    }
};

pub const Vcpu = struct {
    pub fn destroy(_: *Vcpu) void {}
    pub fn setAddressSpace(_: *Vcpu, _: *AddressSpace) vmm.Error!void {
        return error.NotImplemented;
    }
    pub fn run(_: *Vcpu) vmm.Error!vmm.Exit {
        return error.NotImplemented;
    }
    pub fn getUreg(_: *Vcpu, _: *vmm.Ureg) void {}
    pub fn setUreg(_: *Vcpu, _: *const vmm.Ureg) void {}
    pub fn kick(_: *Vcpu) void {}
};
