//! Hypervisor abstraction. See DESIGN.md, "Hypervisor layer (vmm)".
//!
//! Each backend module provides Backend, AddressSpace and Vcpu types with the
//! same methods; the unions below pick one at run time. Backends that aren't
//! built into this hp9 are replaced by vmm/none.zig.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const aout = @import("aout.zig");
pub const arm64 = @import("arch/arm64.zig");
pub const amd64 = @import("arch/amd64.zig");

const hvf = if (have_hvf) @import("vmm/hvf.zig") else @import("vmm/none.zig");
const emu = if (have_emu) @import("vmm/emu.zig") else @import("vmm/none.zig");

const have_hvf = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;
const have_emu = build_options.emu != .none;

pub const Arch = aout.Arch;

/// The architecture of 9front binaries that run natively on this host.
pub const host_arch: ?Arch = switch (builtin.cpu.arch) {
    .aarch64 => .arm64,
    .x86_64 => .amd64,
    else => null,
};

/// What `--backend` asks for.
pub const BackendKind = enum { auto, hvf, kvm, whp, emu };

/// A concrete backend. kvm and whp join at M8 and M9.
pub const Kind = enum {
    hvf,
    emu,

    pub fn built(k: Kind) bool {
        return switch (k) {
            .hvf => have_hvf,
            .emu => have_emu,
        };
    }
};

pub const Error = error{
    /// The host has no usable hypervisor, or hp9 lacks the access it needs.
    HypervisorUnavailable,
    HypervisorFailed,
    OutOfGuestMemory,
    BadAddress,
    /// The backend isn't compiled into this hp9.
    BackendNotBuilt,
    /// The backend can't run binaries for this architecture.
    WrongArch,
    NotImplemented,
};

pub const CreateError = Error || std.mem.Allocator.Error;

pub const Options = struct {
    arch: Arch,
};

pub const page_size = 4096;

pub const Perms = packed struct { read: bool = true, write: bool = false, exec: bool = false };

pub const Fault = struct {
    addr: u64,
    access: enum { read, write, exec },
    syndrome: u64,
};

pub const Exit = union(enum) {
    syscall,
    fault: Fault,
    interrupted,
    halted,
    other: u64,
};

/// A Plan 9 Ureg in the layout of the process's architecture.
pub const Ureg = union(Arch) {
    arm64: arm64.Ureg,
    amd64: amd64.Ureg,

    pub fn initExec(arch: Arch, entry: u64, sp: u64, tos: u64) Ureg {
        return switch (arch) {
            .arm64 => .{ .arm64 = .initExec(entry, sp, tos) },
            .amd64 => .{ .amd64 = .initExec(entry, sp, tos) },
        };
    }
    pub fn pc(u: *const Ureg) u64 {
        return switch (u.*) {
            inline else => |r| r.pc,
        };
    }
    pub fn syscallNumber(u: *const Ureg) u64 {
        return switch (u.*) {
            inline else => |*r| r.syscallNumber(),
        };
    }
    pub fn syscallArgs(u: *const Ureg) u64 {
        return switch (u.*) {
            inline else => |*r| r.syscallArgs(),
        };
    }
    pub fn setReturn(u: *Ureg, v: u64) void {
        switch (u.*) {
            inline else => |*r| r.setReturn(v),
        }
    }
};

/// The native hypervisor backend for this host, if there is one.
fn native() ?Kind {
    return if (have_hvf) .hvf else null;
}

/// Creates a backend. `.auto` uses the host hypervisor when it can run
/// `opts.arch` binaries, and otherwise the emulator; check `kind()` to see
/// which one was picked.
pub fn create(gpa: std.mem.Allocator, io: std.Io, want: BackendKind, opts: Options) CreateError!Backend {
    return switch (want) {
        .hvf => createKind(gpa, io, .hvf, opts),
        .emu => createKind(gpa, io, .emu, opts),
        .kvm, .whp => error.BackendNotBuilt,
        .auto => {
            if (native()) |k| {
                if (createKind(gpa, io, k, opts)) |b| return b else |err| switch (err) {
                    error.HypervisorUnavailable, error.WrongArch => if (!have_emu) return err,
                    else => return err,
                }
            }
            return createKind(gpa, io, .emu, opts);
        },
    };
}

fn createKind(gpa: std.mem.Allocator, io: std.Io, k: Kind, opts: Options) CreateError!Backend {
    return switch (k) {
        .hvf => .{ .hvf = try hvf.Backend.create(gpa, io, opts) },
        .emu => .{ .emu = try emu.Backend.create(gpa, io, opts) },
    };
}

pub const Backend = union(Kind) {
    hvf: *hvf.Backend,
    emu: *emu.Backend,

    pub fn kind(b: Backend) Kind {
        return b;
    }
    pub fn destroy(b: Backend) void {
        switch (b) {
            inline else => |p| p.destroy(),
        }
    }
    pub fn maxVcpus(b: Backend) Error!u32 {
        return switch (b) {
            inline else => |p| p.maxVcpus(),
        };
    }
    /// Returns zeroed, page-aligned memory that address spaces can map.
    pub fn allocPages(b: Backend, n: usize) Error![]align(page_size) u8 {
        return switch (b) {
            inline else => |p| p.allocPages(n),
        };
    }
    pub fn newAddressSpace(b: Backend) CreateError!AddressSpace {
        return switch (b) {
            inline else => |p, k| @unionInit(AddressSpace, @tagName(k), try p.newAddressSpace()),
        };
    }
    /// Must be called on the thread that will run the vCPU.
    pub fn createVcpu(b: Backend) CreateError!Vcpu {
        return switch (b) {
            inline else => |p, k| @unionInit(Vcpu, @tagName(k), try p.createVcpu()),
        };
    }
};

/// One address space per Plan 9 process.
pub const AddressSpace = union(Kind) {
    hvf: *hvf.AddressSpace,
    emu: *emu.AddressSpace,

    pub fn destroy(as: AddressSpace) void {
        switch (as) {
            inline else => |p| p.destroy(),
        }
    }
    /// Maps memory from `Backend.allocPages` at a page-aligned user address.
    pub fn map(as: AddressSpace, va: u64, mem: []align(page_size) u8, perms: Perms) CreateError!void {
        return switch (as) {
            inline else => |p| p.map(va, mem, perms),
        };
    }
    /// Host view of [va, va+len) if it lies within one mapping.
    pub fn translate(as: AddressSpace, va: u64, len: u64) ?[]u8 {
        return switch (as) {
            inline else => |p| p.translate(va, len),
        };
    }
};

pub const Vcpu = union(Kind) {
    hvf: hvf.Vcpu,
    emu: emu.Vcpu,

    pub fn destroy(v: *Vcpu) void {
        switch (v.*) {
            inline else => |*p| p.destroy(),
        }
    }
    pub fn setAddressSpace(v: *Vcpu, as: AddressSpace) Error!void {
        return switch (v.*) {
            inline else => |*p, k| p.setAddressSpace(@field(as, @tagName(k))),
        };
    }
    /// Blocks until the next exit.
    pub fn run(v: *Vcpu) Error!Exit {
        return switch (v.*) {
            inline else => |*p| p.run(),
        };
    }
    pub fn getUreg(v: *Vcpu, u: *Ureg) void {
        switch (v.*) {
            inline else => |*p| p.getUreg(u),
        }
    }
    pub fn setUreg(v: *Vcpu, u: *const Ureg) void {
        switch (v.*) {
            inline else => |*p| p.setUreg(u),
        }
    }
    /// Makes `run` return `.interrupted` soon. Safe to call from any thread.
    pub fn kick(v: *Vcpu) void {
        switch (v.*) {
            inline else => |*p| p.kick(),
        }
    }
};
