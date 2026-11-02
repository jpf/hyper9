//! Hypervisor abstraction. See DESIGN.md, "Hypervisor layer (vmm)".

const builtin = @import("builtin");

pub const backend = switch (builtin.os.tag) {
    .macos => @import("vmm/hvf.zig"),
    else => @compileError("hp9: no hypervisor backend for this host yet"),
};

pub const Error = error{ HypervisorUnavailable, HypervisorFailed, OutOfGuestMemory, BadAddress };

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

pub const Backend = backend.Backend;
pub const AddressSpace = backend.AddressSpace;
pub const Vcpu = backend.Vcpu;
pub const Ureg = backend.Ureg;
