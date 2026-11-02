//! Hypervisor.framework backend (macOS, arm64).
//!
//! Guest-physical layout: one RAM region at ram_ipa, handed out 4K at a time
//! by a bump allocator for user pages, page tables and shared pages alike.
//! User code runs at EL0 under TTBR0. The shim, the doorbell page and the
//! per-vCPU shared pages live at fixed kernel addresses under TTBR1, which
//! every vCPU shares.

const std = @import("std");
const vmm = @import("../vmm.zig");
const arm64 = @import("../arch/arm64.zig");

const Ureg = arm64.Ureg;

const shim_code = @embedFile("shim_arm64");

const ram_ipa: u64 = 0x8000_0000;
const ram_size: usize = 1 << 30;
const doorbell_ipa: u64 = 0x1000_0000; // never mapped, so stores exit to the host

// shim.S finds the doorbell at the page after the vectors.
const kva_shim: u64 = 0xFFFF_FFFF_F000_0000;
const kva_doorbell: u64 = kva_shim + 0x1000;
const kva_shared: u64 = kva_shim + 0x10000;
const max_vcpus = 64;

/// The per-vCPU page the shim saves into; layout is fixed by shim.S.
const Shared = extern struct {
    ureg: Ureg,
    far: u64,
    why: u64,
};
comptime {
    std.debug.assert(@offsetOf(Ureg, "sp") == 248);
    std.debug.assert(@offsetOf(Ureg, "type") == 272);
    std.debug.assert(@offsetOf(Shared, "far") == 280);
    std.debug.assert(@offsetOf(Shared, "why") == 288);
}
const why_el0 = 1;
const why_irq = 3;

// ---- Hypervisor.framework ----

const hv_return_t = i32;
const HV_SUCCESS: hv_return_t = 0;
const HV_DENIED: hv_return_t = @bitCast(@as(u32, 0xfae94007));
const HV_UNSUPPORTED: hv_return_t = @bitCast(@as(u32, 0xfae9400f));

const HvExit = extern struct {
    reason: u32,
    syndrome: u64,
    virtual_address: u64,
    physical_address: u64,
};
const EXIT_CANCELED = 0;
const EXIT_EXCEPTION = 1;
const EXIT_VTIMER = 2;

const REG_X0 = 0;
const REG_PC = 31;
const REG_CPSR = 34;

const SYS_SCTLR_EL1: u16 = 0xc080;
const SYS_CPACR_EL1: u16 = 0xc082;
const SYS_TTBR0_EL1: u16 = 0xc100;
const SYS_TTBR1_EL1: u16 = 0xc101;
const SYS_TCR_EL1: u16 = 0xc102;
const SYS_SP_EL0: u16 = 0xc208;
const SYS_MAIR_EL1: u16 = 0xc510;
const SYS_VBAR_EL1: u16 = 0xc600;
const SYS_SP_EL1: u16 = 0xe208;

extern "c" fn hv_vm_create(config: ?*anyopaque) hv_return_t;
extern "c" fn hv_vm_destroy() hv_return_t;
extern "c" fn hv_vm_map(addr: *anyopaque, ipa: u64, size: usize, flags: u64) hv_return_t;
extern "c" fn hv_vm_get_max_vcpu_count(max: *u32) hv_return_t;
extern "c" fn hv_vcpu_create(vcpu: *u64, exit: **HvExit, config: ?*anyopaque) hv_return_t;
extern "c" fn hv_vcpu_destroy(vcpu: u64) hv_return_t;
extern "c" fn hv_vcpu_run(vcpu: u64) hv_return_t;
extern "c" fn hv_vcpu_get_reg(vcpu: u64, reg: u32, value: *u64) hv_return_t;
extern "c" fn hv_vcpu_set_reg(vcpu: u64, reg: u32, value: u64) hv_return_t;
extern "c" fn hv_vcpu_set_sys_reg(vcpu: u64, reg: u16, value: u64) hv_return_t;
extern "c" fn hv_vcpus_exit(vcpus: [*]const u64, count: u32) hv_return_t;

fn check(r: hv_return_t) vmm.Error!void {
    return switch (r) {
        HV_SUCCESS => {},
        HV_UNSUPPORTED, HV_DENIED => error.HypervisorUnavailable,
        else => error.HypervisorFailed,
    };
}

// ---- Stage-1 translation: 4K granule, 48-bit VAs in both halves ----

const TCR: u64 = 16 | // T0SZ
    (1 << 8) | (1 << 10) | (3 << 12) | // TTBR0 walks: write-back, inner shareable
    (16 << 16) | // T1SZ
    (1 << 24) | (1 << 26) | (3 << 28) | // TTBR1 walks: write-back, inner shareable
    (2 << 30) | // TG1 = 4K (TG0 = 0 is 4K)
    (1 << 32); // IPS = 36 bits, HVF's default IPA size

const MAIR: u64 = 0xff; // attr 0: normal memory, write-back

const SCTLR: u64 = (1 << 29) | (1 << 28) | (1 << 23) | (1 << 22) | (1 << 20) | (1 << 11) | (1 << 8) | (1 << 7) | // RES1
    (1 << 0) | (1 << 2) | (1 << 12); // M, C, I

const PTE_VALID: u64 = 0b11; // page (L3) or table (L0-L2)
const PTE_AF: u64 = 1 << 10;
const PTE_ISH: u64 = 3 << 8;
const PTE_USER: u64 = 1 << 6;
const PTE_RDONLY: u64 = 1 << 7;
const PTE_PXN: u64 = 1 << 53;
const PTE_UXN: u64 = 1 << 54;
const PTE_ADDR: u64 = 0x0000_FFFF_FFFF_F000;

fn pteAttrs(user: bool, perms: vmm.Perms) u64 {
    var d = PTE_VALID | PTE_AF | PTE_ISH;
    if (!perms.write) d |= PTE_RDONLY;
    if (user) {
        d |= PTE_USER | PTE_PXN;
        if (!perms.exec) d |= PTE_UXN;
    } else {
        d |= PTE_UXN;
        if (!perms.exec) d |= PTE_PXN;
    }
    return d;
}

pub const Backend = struct {
    gpa: std.mem.Allocator,
    ram: []align(std.heap.page_size_min) u8,
    next: usize = 0,
    lock: std.Io.Mutex = .init,
    io: std.Io,
    kernel_root: u64 = 0,
    nvcpus: u32 = 0,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: vmm.Options) vmm.CreateError!*Backend {
        if (opts.arch != .arm64) return error.WrongArch;
        try check(hv_vm_create(null));
        errdefer _ = hv_vm_destroy();

        const ram = std.posix.mmap(null, ram_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch
            return error.OutOfGuestMemory;
        errdefer std.posix.munmap(ram);
        try check(hv_vm_map(ram.ptr, ram_ipa, ram.len, 0b111));

        const b = try gpa.create(Backend);
        errdefer gpa.destroy(b);
        b.* = .{ .gpa = gpa, .io = io, .ram = ram };

        b.kernel_root = try b.allocTable();
        const shim = try b.allocPages(1);
        @memcpy(shim[0..shim_code.len], shim_code);
        try b.mapPage(b.kernel_root, kva_shim, b.ipaOf(shim), pteAttrs(false, .{ .exec = true }));
        try b.mapPage(b.kernel_root, kva_doorbell, doorbell_ipa, pteAttrs(false, .{ .write = true }));
        return b;
    }

    pub fn destroy(b: *Backend) void {
        _ = hv_vm_destroy();
        std.posix.munmap(b.ram);
        b.gpa.destroy(b);
    }

    pub fn maxVcpus(_: *Backend) vmm.Error!u32 {
        var n: u32 = 0;
        try check(hv_vm_get_max_vcpu_count(&n));
        return n;
    }

    /// Returns zeroed pages backed by guest-physical memory.
    pub fn allocPages(b: *Backend, n: usize) vmm.Error![]align(vmm.page_size) u8 {
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        const len = n * vmm.page_size;
        if (b.next + len > b.ram.len) return error.OutOfGuestMemory;
        const mem: []align(vmm.page_size) u8 = @alignCast(b.ram[b.next..][0..len]);
        b.next += len;
        return mem;
    }

    pub fn newAddressSpace(b: *Backend) vmm.CreateError!*AddressSpace {
        const as = try b.gpa.create(AddressSpace);
        as.* = .{ .backend = b, .root = try b.allocTable() };
        return as;
    }

    /// Must be called on the thread that will run the vCPU.
    pub fn createVcpu(b: *Backend) vmm.CreateError!Vcpu {
        const index = blk: {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            if (b.nvcpus >= max_vcpus) return error.HypervisorFailed;
            b.nvcpus += 1;
            break :blk b.nvcpus - 1;
        };

        const shared_page = try b.allocPages(1);
        const shared_kva = kva_shared + @as(u64, index) * vmm.page_size;
        try b.mapPage(b.kernel_root, shared_kva, b.ipaOf(shared_page), pteAttrs(false, .{ .write = true }));

        var v: Vcpu = .{ .id = 0, .exit = undefined, .shared = @ptrCast(shared_page.ptr) };
        try check(hv_vcpu_create(&v.id, &v.exit, null));
        errdefer _ = hv_vcpu_destroy(v.id);
        try check(hv_vcpu_set_sys_reg(v.id, SYS_VBAR_EL1, kva_shim));
        try check(hv_vcpu_set_sys_reg(v.id, SYS_MAIR_EL1, MAIR));
        try check(hv_vcpu_set_sys_reg(v.id, SYS_TCR_EL1, TCR));
        try check(hv_vcpu_set_sys_reg(v.id, SYS_TTBR1_EL1, b.kernel_root));
        try check(hv_vcpu_set_sys_reg(v.id, SYS_CPACR_EL1, 3 << 20)); // no FP/SIMD traps
        try check(hv_vcpu_set_sys_reg(v.id, SYS_SP_EL1, shared_kva));
        try check(hv_vcpu_set_sys_reg(v.id, SYS_SCTLR_EL1, SCTLR));
        return v;
    }

    fn ipaOf(b: *Backend, mem: []const u8) u64 {
        return ram_ipa + (@intFromPtr(mem.ptr) - @intFromPtr(b.ram.ptr));
    }

    fn table(b: *Backend, ipa: u64) *[512]u64 {
        return @ptrCast(@alignCast(b.ram[ipa - ram_ipa ..][0..vmm.page_size]));
    }

    fn allocTable(b: *Backend) vmm.Error!u64 {
        return b.ipaOf(try b.allocPages(1));
    }

    fn mapPage(b: *Backend, root: u64, va: u64, ipa: u64, attrs: u64) vmm.Error!void {
        var t = root;
        var shift: u6 = 39;
        while (shift > 12) : (shift -= 9) {
            const e = &b.table(t)[(va >> shift) & 511];
            if (e.* & PTE_VALID == 0) e.* = (try b.allocTable()) | PTE_VALID;
            t = e.* & PTE_ADDR;
        }
        b.table(t)[(va >> 12) & 511] = (ipa & PTE_ADDR) | attrs;
    }
};

pub const AddressSpace = struct {
    backend: *Backend,
    root: u64,
    regions: std.ArrayList(Region) = .empty,

    const Region = struct { va: u64, mem: []u8 };

    /// Maps backend-allocated memory at a page-aligned user address.
    pub fn map(as: *AddressSpace, va: u64, mem: []align(vmm.page_size) u8, perms: vmm.Perms) vmm.CreateError!void {
        if (va % vmm.page_size != 0 or mem.len % vmm.page_size != 0) return error.BadAddress;
        const b = as.backend;
        const ipa = b.ipaOf(mem);
        var off: u64 = 0;
        while (off < mem.len) : (off += vmm.page_size) {
            try b.mapPage(as.root, va + off, ipa + off, pteAttrs(true, perms));
        }
        try as.regions.append(b.gpa, .{ .va = va, .mem = mem });
    }

    /// Host view of [va, va+len) if it lies within one mapping.
    pub fn translate(as: *AddressSpace, va: u64, len: u64) ?[]u8 {
        for (as.regions.items) |r| {
            if (va >= r.va and va - r.va <= r.mem.len and len <= r.mem.len - (va - r.va)) {
                return r.mem[va - r.va ..][0..len];
            }
        }
        return null;
    }

    pub fn destroy(as: *AddressSpace) void {
        as.regions.deinit(as.backend.gpa);
        as.backend.gpa.destroy(as);
    }
};

pub const Vcpu = struct {
    id: u64,
    exit: *HvExit,
    shared: *Shared,
    fresh: bool = true,

    pub fn destroy(v: *Vcpu) void {
        _ = hv_vcpu_destroy(v.id);
    }

    pub fn setAddressSpace(v: *Vcpu, as: *AddressSpace) vmm.Error!void {
        // TODO(M3): ASIDs or a TLB flush once a vCPU switches between spaces.
        try check(hv_vcpu_set_sys_reg(v.id, SYS_TTBR0_EL1, as.root));
    }

    pub fn getUreg(v: *Vcpu, u: *vmm.Ureg) void {
        u.* = .{ .arm64 = v.shared.ureg };
    }

    pub fn setUreg(v: *Vcpu, u: *const vmm.Ureg) void {
        v.shared.ureg = u.arm64;
    }

    /// Safe to call from any thread.
    pub fn kick(v: *Vcpu) void {
        _ = hv_vcpus_exit(@ptrCast(&v.id), 1);
    }

    pub fn run(v: *Vcpu) vmm.Error!vmm.Exit {
        if (v.fresh) {
            // The first entry goes straight to EL0; after that the shim reloads the Ureg.
            const u = &v.shared.ureg;
            for (u.r, 0..) |val, i| try check(hv_vcpu_set_reg(v.id, REG_X0 + @as(u32, @intCast(i)), val));
            try check(hv_vcpu_set_reg(v.id, REG_PC, u.pc));
            try check(hv_vcpu_set_reg(v.id, REG_CPSR, u.psr));
            try check(hv_vcpu_set_sys_reg(v.id, SYS_SP_EL0, u.sp));
            v.fresh = false;
        }
        while (true) {
            try check(hv_vcpu_run(v.id));
            switch (v.exit.reason) {
                EXIT_CANCELED => return .interrupted,
                EXIT_VTIMER => continue,
                EXIT_EXCEPTION => {
                    const ec = v.exit.syndrome >> 26;
                    if (ec == arm64.EC_DABT_LOWER and v.exit.physical_address & ~@as(u64, 0xfff) == doorbell_ipa) {
                        var pc: u64 = 0;
                        try check(hv_vcpu_get_reg(v.id, REG_PC, &pc));
                        try check(hv_vcpu_set_reg(v.id, REG_PC, pc + 4));
                        return v.decode();
                    }
                    return .{ .other = v.exit.syndrome };
                },
                else => return .{ .other = v.exit.reason },
            }
        }
    }

    fn decode(v: *Vcpu) vmm.Exit {
        const s = v.shared;
        switch (s.why) {
            why_el0 => {},
            why_irq => return .interrupted,
            else => return .{ .other = s.ureg.type },
        }
        const esr = s.ureg.type;
        return switch (esr >> 26) {
            arm64.EC_SVC64 => .syscall,
            arm64.EC_IABT_LOWER => .{ .fault = .{ .addr = s.far, .access = .exec, .syndrome = esr } },
            arm64.EC_DABT_LOWER => .{ .fault = .{ .addr = s.far, .access = if (esr & (1 << 6) != 0) .write else .read, .syndrome = esr } },
            else => .{ .fault = .{ .addr = s.ureg.pc, .access = .exec, .syndrome = esr } },
        };
    }
};
