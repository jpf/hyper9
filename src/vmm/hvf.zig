//! Hypervisor.framework backend (macOS, arm64).
//!
//! Guest-physical layout: one RAM region at ram_ipa, handed out in 4K pages
//! for user pages, page tables and shared pages alike, first-fit from a list
//! of freed ranges and otherwise from the end.
//! User code runs at EL0 under TTBR0. The shim, the doorbell page and the
//! per-vCPU shared pages live at fixed kernel addresses under TTBR1, which
//! every vCPU shares.

const std = @import("std");
const vmm = @import("../vmm.zig");
const arm64 = @import("../arch/arm64.zig");

const Ureg = arm64.Ureg;

const shim_code = @embedFile("shim_arm64");

const ram_ipa: u64 = 0x8000_0000;
const doorbell_ipa: u64 = 0x1000_0000; // never mapped, so stores exit to the host

// shim.S finds the doorbell at the page after the vectors.
const kva_shim: u64 = 0xFFFF_FFFF_F000_0000;
const kva_doorbell: u64 = kva_shim + 0x1000;
const kva_shared: u64 = kva_shim + 0x10000;

/// The per-vCPU page the shim saves into; layout is fixed by shim.S.
const Shared = extern struct {
    ureg: Ureg,
    far: u64,
    why: u64,
    /// Set by the host to make the shim flush the TLB and I-cache before
    /// it returns to EL0.
    flush: u64,
};
comptime {
    std.debug.assert(@offsetOf(Ureg, "sp") == 248);
    std.debug.assert(@offsetOf(Ureg, "type") == 272);
    std.debug.assert(@offsetOf(Shared, "far") == 280);
    std.debug.assert(@offsetOf(Shared, "why") == 288);
    std.debug.assert(@offsetOf(Shared, "flush") == 296);
}
/// shim.S's entry point after the vectors, which restores the Ureg from the
/// shared page and ERETs, flushing first if asked.
const shim_enter = 0x800;
/// EL1h with DAIF masked, for entering the shim.
const psr_el1h: u64 = 0x3c5;
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
    /// Pages past `next` have never been handed out.
    next: usize = 0,
    /// Freed ranges below `next`, sorted and coalesced.
    free: std.ArrayList(Range) = .empty,
    lock: std.Io.Mutex = .init,
    io: std.Io,
    kernel_root: u64 = 0,
    /// Serializes changes to the kernel tables (allocPages takes `lock`).
    ktables: std.atomic.Mutex = .unlocked,
    /// Shared-page slots in use, one bit per vCPU.
    slots: u64 = 0,
    next_as_id: u64 = 1,

    const Range = struct { off: usize, len: usize };

    pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: vmm.Options) vmm.CreateError!*Backend {
        if (opts.arch != .arm64) return error.WrongArch;
        try check(hv_vm_create(null));
        errdefer _ = hv_vm_destroy();

        const want = opts.memory orelse vmm.default_memory;
        if (want > vmm.max_memory) return error.OutOfGuestMemory;
        const ram_size = std.mem.alignForward(usize, @intCast(want), vmm.page_size);
        if (ram_size < 16 * vmm.page_size) return error.OutOfGuestMemory;
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
        b.free.deinit(b.gpa);
        b.gpa.destroy(b);
    }

    pub fn maxVcpus(_: *Backend) vmm.Error!u32 {
        var n: u32 = 0;
        try check(hv_vm_get_max_vcpu_count(&n));
        return n;
    }

    /// Returns zeroed pages backed by guest-physical memory.
    pub fn allocPages(b: *Backend, n: usize) vmm.Error![]align(vmm.page_size) u8 {
        const len = n * vmm.page_size;
        if (len == 0) return error.BadAddress;
        const off = blk: {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            for (b.free.items, 0..) |*r, i| if (r.len >= len) {
                const off = r.off;
                r.off += len;
                r.len -= len;
                if (r.len == 0) _ = b.free.orderedRemove(i);
                break :blk off;
            };
            if (b.next + len > b.ram.len) return error.OutOfGuestMemory;
            b.next += len;
            break :blk b.next - len;
        };
        const mem: []align(vmm.page_size) u8 = @alignCast(b.ram[off..][0..len]);
        // Freed pages are dirty; never-used ones are already zero.
        @memset(mem, 0);
        return mem;
    }

    /// Returns pages from `allocPages` (all of them, or any page-aligned
    /// part). They must no longer be mapped anywhere.
    pub fn freePages(b: *Backend, mem: []align(vmm.page_size) u8) void {
        if (mem.len == 0) return;
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        b.freeLocked(@intFromPtr(mem.ptr) - @intFromPtr(b.ram.ptr), mem.len);
    }

    fn freeLocked(b: *Backend, off: usize, len: usize) void {
        var i: usize = 0;
        while (i < b.free.items.len and b.free.items[i].off < off) i += 1;
        var r: Range = .{ .off = off, .len = len };
        if (i < b.free.items.len and r.off + r.len == b.free.items[i].off) {
            r.len += b.free.items[i].len;
            _ = b.free.orderedRemove(i);
        }
        if (i > 0 and b.free.items[i - 1].off + b.free.items[i - 1].len == r.off) {
            i -= 1;
            r.off = b.free.items[i].off;
            r.len += b.free.items[i].len;
            _ = b.free.orderedRemove(i);
        }
        if (r.off + r.len == b.next) {
            b.next = r.off;
            return;
        }
        // On allocation failure the range is lost, which is only a leak.
        b.free.insert(b.gpa, i, r) catch {};
    }

    pub fn newAddressSpace(b: *Backend) vmm.CreateError!*AddressSpace {
        const as = try b.gpa.create(AddressSpace);
        errdefer b.gpa.destroy(as);
        const id = blk: {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            b.next_as_id += 1;
            break :blk b.next_as_id;
        };
        as.* = .{ .backend = b, .root = try b.allocTable(), .id = id };
        return as;
    }

    /// Must be called on the thread that will run the vCPU.
    pub fn createVcpu(b: *Backend) vmm.CreateError!Vcpu {
        const index: u6 = blk: {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            if (b.slots == std.math.maxInt(u64)) return error.HypervisorFailed;
            const i: u6 = @intCast(@ctz(~b.slots));
            b.slots |= @as(u64, 1) << i;
            break :blk i;
        };
        errdefer b.releaseSlot(index);

        const shared_kva = kva_shared + @as(u64, index) * vmm.page_size;
        const shared_page = try b.allocPages(1);
        errdefer b.freePages(shared_page);
        {
            while (!b.ktables.tryLock()) std.atomic.spinLoopHint();
            defer b.ktables.unlock();
            try b.mapPage(b.kernel_root, shared_kva, b.ipaOf(shared_page), pteAttrs(false, .{ .write = true }));
        }

        var v: Vcpu = .{ .id = 0, .exit = undefined, .shared = @ptrCast(shared_page.ptr), .backend = b, .slot = index };
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

    fn releaseSlot(b: *Backend, i: u6) void {
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        b.slots &= ~(@as(u64, 1) << i);
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

    fn freeTable(b: *Backend, ipa: u64) void {
        b.freePages(@alignCast(b.ram[ipa - ram_ipa ..][0..vmm.page_size]));
    }

    /// The caller serializes changes to the tables under `root`.
    fn mapPage(b: *Backend, root: u64, va: u64, ipa: u64, attrs: u64) vmm.Error!void {
        var t = root;
        var shift: u6 = 39;
        while (shift > 12) : (shift -= 9) {
            const e = &b.table(t)[(va >> shift) & 511];
            if (e.* & PTE_VALID == 0) @atomicStore(u64, e, (try b.allocTable()) | PTE_VALID, .release);
            t = e.* & PTE_ADDR;
        }
        @atomicStore(u64, &b.table(t)[(va >> 12) & 511], (ipa & PTE_ADDR) | attrs, .release);
    }

    fn unmapPage(b: *Backend, root: u64, va: u64) void {
        var t = root;
        var shift: u6 = 39;
        while (shift > 12) : (shift -= 9) {
            const e = b.table(t)[(va >> shift) & 511];
            if (e & PTE_VALID == 0) return;
            t = e & PTE_ADDR;
        }
        @atomicStore(u64, &b.table(t)[(va >> 12) & 511], 0, .release);
    }

    /// Frees the table at `ipa` and the tables below it, not the pages
    /// they map.
    fn freeTables(b: *Backend, ipa: u64, level: u2) void {
        if (level < 3) for (b.table(ipa)) |e| {
            if (e & PTE_VALID != 0) b.freeTables(e & PTE_ADDR, level + 1);
        };
        b.freeTable(ipa);
    }
};

pub const AddressSpace = struct {
    backend: *Backend,
    root: u64,
    /// Unique for the backend's life, so a vCPU can tell a new space at a
    /// reused address from the one it last ran.
    id: u64,
    /// Bumped by `unmap`, so vCPUs that ran this space flush their TLBs.
    epoch: std.atomic.Value(u64) = .init(0),
    lock: std.atomic.Mutex = .unlocked,
    regions: std.ArrayList(Region) = .empty,

    const Region = struct { va: u64, mem: []u8 };

    fn lockSpin(as: *AddressSpace) void {
        while (!as.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Maps backend-allocated memory at a page-aligned user address.
    pub fn map(as: *AddressSpace, va: u64, mem: []align(vmm.page_size) u8, perms: vmm.Perms) vmm.CreateError!void {
        if (va % vmm.page_size != 0 or mem.len % vmm.page_size != 0 or mem.len == 0) return error.BadAddress;
        const b = as.backend;
        as.lockSpin();
        defer as.lock.unlock();
        for (as.regions.items) |r| {
            if (va < r.va + r.mem.len and r.va < va + mem.len) return error.BadAddress;
        }
        try as.regions.ensureUnusedCapacity(b.gpa, 1);
        const ipa = b.ipaOf(mem);
        var off: u64 = 0;
        while (off < mem.len) : (off += vmm.page_size) {
            b.mapPage(as.root, va + off, ipa + off, pteAttrs(true, perms)) catch |e| {
                var u: u64 = 0;
                while (u < off) : (u += vmm.page_size) b.unmapPage(as.root, va + u);
                return e;
            };
        }
        as.regions.appendAssumeCapacity(.{ .va = va, .mem = mem });
    }

    /// Removes the mapping made by `map` at `va`. The pages stay allocated.
    pub fn unmap(as: *AddressSpace, va: u64) void {
        as.lockSpin();
        defer as.lock.unlock();
        for (as.regions.items, 0..) |r, i| if (r.va == va) {
            var off: u64 = 0;
            while (off < r.mem.len) : (off += vmm.page_size) as.backend.unmapPage(as.root, va + off);
            _ = as.regions.swapRemove(i);
            _ = as.epoch.fetchAdd(1, .release);
            return;
        };
    }

    /// Host view of [va, va+len) if it lies within one mapping.
    pub fn translate(as: *AddressSpace, va: u64, len: u64) ?[]u8 {
        as.lockSpin();
        defer as.lock.unlock();
        for (as.regions.items) |r| {
            if (va >= r.va and va - r.va <= r.mem.len and len <= r.mem.len - (va - r.va)) {
                return r.mem[va - r.va ..][0..len];
            }
        }
        return null;
    }

    /// Frees the page tables; the mapped pages belong to the caller.
    pub fn destroy(as: *AddressSpace) void {
        as.backend.freeTables(as.root, 0);
        as.regions.deinit(as.backend.gpa);
        as.backend.gpa.destroy(as);
    }
};

pub const Vcpu = struct {
    id: u64,
    exit: *HvExit,
    shared: *Shared,
    backend: *Backend,
    slot: u6,
    fresh: bool = true,
    /// The address space last run, and its epoch then; a change means a
    /// TLB flush before the next run.
    as: ?*AddressSpace = null,
    as_id: u64 = 0,
    epoch: u64 = 0,

    pub fn destroy(v: *Vcpu) void {
        _ = hv_vcpu_destroy(v.id);
        const b = v.backend;
        {
            while (!b.ktables.tryLock()) std.atomic.spinLoopHint();
            defer b.ktables.unlock();
            b.unmapPage(b.kernel_root, kva_shared + @as(u64, v.slot) * vmm.page_size);
        }
        b.freePages(@as([*]align(vmm.page_size) u8, @ptrCast(@alignCast(v.shared)))[0..vmm.page_size]);
        b.releaseSlot(v.slot);
    }

    pub fn setAddressSpace(v: *Vcpu, as: *AddressSpace) vmm.Error!void {
        if (v.as == as and v.as_id == as.id) return;
        try check(hv_vcpu_set_sys_reg(v.id, SYS_TTBR0_EL1, as.root));
        v.as = as;
        v.as_id = as.id;
        v.epoch = as.epoch.load(.acquire);
        v.shared.flush = 1;
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
        const as = v.as orelse return error.BadAddress;
        const epoch = as.epoch.load(.acquire);
        if (epoch != v.epoch) {
            v.epoch = epoch;
            v.shared.flush = 1;
        }
        if (v.fresh) {
            // Enter through the shim, which loads the Ureg (and flushes).
            try check(hv_vcpu_set_reg(v.id, REG_PC, kva_shim + shim_enter));
            try check(hv_vcpu_set_reg(v.id, REG_CPSR, psr_el1h));
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
