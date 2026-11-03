//! Emulator backend (Unicorn). Built with -Demu=unicorn. See DESIGN.md,
//! "Emulator backend (emu)".
//!
//! User mode only: each vCPU is a Unicorn engine running at EL0 (arm64) or
//! in flat 64-bit mode (amd64), with no MMU and no guest kernel. Hooks turn
//! syscall instructions, invalid memory accesses and CPU exceptions into
//! vmm exits, doing the shim's job. Address-space pages are host memory
//! mapped straight into the engine with uc_mem_map_ptr, so the host and the
//! guest share them.

const std = @import("std");
const vmm = @import("../vmm.zig");
const arm64 = @import("../arch/arm64.zig");
const amd64 = @import("../arch/amd64.zig");
const uc = @import("unicorn");

/// Unicorn's runtime version, e.g. "2.1".
pub fn version(buf: []u8) []const u8 {
    var major: c_uint = 0;
    var minor: c_uint = 0;
    _ = uc.uc_version(&major, &minor);
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ major, minor }) catch buf[0..0];
}

fn open(arch: vmm.Arch) vmm.Error!*uc.uc_engine {
    const a: uc.uc_arch, const mode: uc.uc_mode = switch (arch) {
        .arm64 => .{ uc.UC_ARCH_ARM64, uc.UC_MODE_ARM },
        .amd64 => .{ uc.UC_ARCH_X86, uc.UC_MODE_64 },
    };
    var engine: ?*uc.uc_engine = null;
    if (uc.uc_open(a, mode, &engine) != uc.UC_ERR_OK) return error.HypervisorFailed;
    return engine.?;
}

fn check(err: uc.uc_err) vmm.Error!void {
    if (err != uc.UC_ERR_OK) return error.HypervisorFailed;
}

fn prot(p: vmm.Perms) u32 {
    var r: u32 = 0;
    if (p.read) r |= uc.UC_PROT_READ;
    if (p.write) r |= uc.UC_PROT_WRITE;
    if (p.exec) r |= uc.UC_PROT_EXEC;
    return r;
}

pub const Backend = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arch: vmm.Arch,
    lock: std.Io.Mutex = .init,
    /// Live allocations: address to length.
    allocs: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    /// Bytes handed out, against the cap in `limit`.
    used: u64 = 0,
    limit: u64,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: vmm.Options) vmm.CreateError!*Backend {
        // Fail here, not at the first vCPU, if Unicorn lacks the architecture.
        _ = uc.uc_close(try open(opts.arch));
        const b = try gpa.create(Backend);
        const limit = opts.memory orelse vmm.default_memory;
        if (limit > vmm.max_memory) return error.OutOfGuestMemory;
        b.* = .{ .gpa = gpa, .io = io, .arch = opts.arch, .limit = limit };
        return b;
    }

    pub fn destroy(b: *Backend) void {
        var it = b.allocs.iterator();
        while (it.next()) |e| std.heap.page_allocator.free(@as([*]align(vmm.page_size) u8, @ptrFromInt(e.key_ptr.*))[0..e.value_ptr.*]);
        b.allocs.deinit(b.gpa);
        b.gpa.destroy(b);
    }

    /// No hardware limit; this keeps the number in line with HVF's.
    pub fn maxVcpus(_: *Backend) vmm.Error!u32 {
        return 64;
    }

    /// Returns zeroed pages.
    pub fn allocPages(b: *Backend, n: usize) vmm.Error![]align(vmm.page_size) u8 {
        {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            const len = n * vmm.page_size;
            if (b.used + len > b.limit) return error.OutOfGuestMemory;
            b.used += len;
        }
        errdefer {
            b.lock.lockUncancelable(b.io);
            b.used -= n * vmm.page_size;
            b.lock.unlock(b.io);
        }
        const mem = std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(vmm.page_size), n * vmm.page_size) catch
            return error.OutOfGuestMemory;
        // Fresh pages from the OS are zero, but Zig's allocators fill new
        // memory with 0xaa in safe builds, so zero them explicitly.
        @memset(mem, 0);
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        b.allocs.put(b.gpa, @intFromPtr(mem.ptr), mem.len) catch {
            std.heap.page_allocator.free(mem);
            return error.OutOfGuestMemory;
        };
        return mem;
    }

    /// Returns a whole allocation from `allocPages`.
    pub fn freePages(b: *Backend, mem: []align(vmm.page_size) u8) void {
        {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            const len = (b.allocs.fetchRemove(@intFromPtr(mem.ptr)) orelse return).value;
            std.debug.assert(len == mem.len);
            b.used -= len;
        }
        std.heap.page_allocator.free(mem);
    }

    pub fn newAddressSpace(b: *Backend) vmm.CreateError!*AddressSpace {
        const as = try b.gpa.create(AddressSpace);
        as.* = .{ .backend = b };
        return as;
    }

    pub fn createVcpu(b: *Backend) vmm.CreateError!Vcpu {
        const s = try b.gpa.create(State);
        errdefer b.gpa.destroy(s);
        s.* = .{ .backend = b, .arch = b.arch, .engine = try open(b.arch), .ureg = switch (b.arch) {
            .arm64 => .{ .arm64 = .{} },
            .amd64 => .{ .amd64 = .{} },
        } };
        errdefer _ = uc.uc_close(s.engine);
        try s.addHooks();
        return .{ .s = s };
    }
};

/// The emulator keeps the mappings itself; vCPUs copy them into their
/// engines when they switch to the address space or it changes.
pub const AddressSpace = struct {
    backend: *Backend,
    regions: std.ArrayList(Region) = .empty,
    /// Bumped on every change, so vCPUs know to remap.
    generation: u64 = 1,

    const Region = struct { va: u64, mem: []align(vmm.page_size) u8, perms: vmm.Perms };

    pub fn map(as: *AddressSpace, va: u64, mem: []align(vmm.page_size) u8, perms: vmm.Perms) vmm.CreateError!void {
        if (va % vmm.page_size != 0 or mem.len % vmm.page_size != 0 or mem.len == 0) return error.BadAddress;
        for (as.regions.items) |r| {
            if (va < r.va + r.mem.len and r.va < va + mem.len) return error.BadAddress;
        }
        try as.regions.append(as.backend.gpa, .{ .va = va, .mem = mem, .perms = perms });
        as.generation += 1;
    }

    pub fn unmap(as: *AddressSpace, va: u64) void {
        for (as.regions.items, 0..) |r, i| if (r.va == va) {
            _ = as.regions.swapRemove(i);
            as.generation += 1;
            return;
        };
    }

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

/// Why the engine last stopped, as seen by the hooks.
const Stop = union(enum) {
    none,
    syscall,
    fault: vmm.Fault,
    /// A CPU exception other than a syscall (arm64 EXCP_* or x86 vector).
    exception: u32,
};

/// Heap state behind a Vcpu, so the hooks have a stable pointer.
const State = struct {
    backend: *Backend,
    arch: vmm.Arch,
    engine: *uc.uc_engine,
    ureg: vmm.Ureg,
    as: ?*AddressSpace = null,
    mapped: std.ArrayList(AddressSpace.Region) = .empty,
    generation: u64 = 0,
    stop: Stop = .none,
    kicked: std.atomic.Value(bool) = .init(false),

    fn addHooks(s: *State) vmm.Error!void {
        var h: uc.uc_hook = 0;
        try check(uc.uc_hook_add(s.engine, &h, uc.UC_HOOK_MEM_INVALID, @ptrCast(@constCast(&onMemInvalid)), s, 1, 0));
        try check(uc.uc_hook_add(s.engine, &h, uc.UC_HOOK_INTR, @ptrCast(@constCast(&onIntr)), s, 1, 0));
        if (s.arch == .amd64) {
            try check(uc.uc_hook_add(s.engine, &h, uc.UC_HOOK_INSN, @ptrCast(@constCast(&onSyscall)), s, 1, 0, @as(c_int, uc.UC_X86_INS_SYSCALL)));
        }
    }

    fn halt(s: *State, why: Stop) void {
        s.stop = why;
        _ = uc.uc_emu_stop(s.engine);
    }

    fn onIntr(_: ?*uc.uc_engine, intno: u32, data: ?*anyopaque) callconv(.c) void {
        const s: *State = @ptrCast(@alignCast(data));
        if (s.arch == .arm64 and intno == arm64_excp_swi) return s.halt(.syscall);
        s.halt(.{ .exception = intno });
    }

    fn onSyscall(_: ?*uc.uc_engine, data: ?*anyopaque) callconv(.c) void {
        const s: *State = @ptrCast(@alignCast(data));
        s.halt(.syscall);
    }

    fn onMemInvalid(_: ?*uc.uc_engine, kind: uc.uc_mem_type, addr: u64, _: c_int, _: i64, data: ?*anyopaque) callconv(.c) bool {
        const s: *State = @ptrCast(@alignCast(data));
        const access: @FieldType(vmm.Fault, "access") = switch (kind) {
            uc.UC_MEM_WRITE_UNMAPPED, uc.UC_MEM_WRITE_PROT => .write,
            uc.UC_MEM_FETCH_UNMAPPED, uc.UC_MEM_FETCH_PROT => .exec,
            else => .read,
        };
        s.stop = .{ .fault = .{ .addr = addr, .access = access, .syndrome = @intCast(kind) } };
        return false; // Unicorn stops with an error, leaving the PC at the access
    }

    /// Makes the engine's mappings match the address space.
    fn sync(s: *State) vmm.Error!void {
        const as = s.as orelse return;
        if (s.generation == as.generation) return;
        for (s.mapped.items) |r| try check(uc.uc_mem_unmap(s.engine, r.va, r.mem.len));
        s.mapped.clearRetainingCapacity();
        for (as.regions.items) |r| {
            try check(uc.uc_mem_map_ptr(s.engine, r.va, r.mem.len, prot(r.perms), r.mem.ptr));
            s.mapped.append(s.backend.gpa, r) catch return error.OutOfGuestMemory;
        }
        // Translated blocks may hold code from the old mappings.
        try check(uc.uc_ctl(s.engine, uc_ctl_tb_flush));
        s.generation = as.generation;
    }

    fn writeRegs(s: *State) vmm.Error!void {
        switch (s.ureg) {
            .arm64 => |*u| {
                var vals: [arm64_regs.len]u64 = undefined;
                @memcpy(vals[0..31], &u.r);
                vals[31] = u.sp;
                vals[32] = u.pc;
                vals[33] = u.psr & arm64_nzcv; // EL0t, interrupts unmasked
                try writeBatch(s.engine, &arm64_regs, &vals);
            },
            .amd64 => |*u| {
                var vals: [amd64_regs.len]u64 = undefined;
                inline for (amd64_fields, 0..) |f, i| vals[i] = @field(u, f);
                vals[amd64_fields.len] = u.flags | amd64_flags_res1;
                try writeBatch(s.engine, &amd64_regs, &vals);
            },
        }
    }

    fn readRegs(s: *State) vmm.Error!void {
        switch (s.ureg) {
            .arm64 => |*u| {
                var vals: [arm64_regs.len]u64 = undefined;
                try readBatch(s.engine, &arm64_regs, &vals);
                @memcpy(&u.r, vals[0..31]);
                u.sp = vals[31];
                u.pc = vals[32];
                u.psr = vals[33];
            },
            .amd64 => |*u| {
                var vals: [amd64_regs.len]u64 = undefined;
                try readBatch(s.engine, &amd64_regs, &vals);
                inline for (amd64_fields, 0..) |f, i| @field(u, f) = vals[i];
                u.flags = vals[amd64_fields.len];
            },
        }
    }

    fn run(s: *State) vmm.Error!vmm.Exit {
        if (s.as == null) return error.BadAddress;
        // TODO(M4): a kick landing between this check and uc_emu_start is
        // lost, because uc_emu_start clears Unicorn's stop request.
        if (s.kicked.swap(false, .acquire)) return .interrupted;
        try s.sync();
        try s.writeRegs();
        s.stop = .none;
        const err = uc.uc_emu_start(s.engine, s.ureg.pc(), std.math.maxInt(u64), 0, 0);
        try s.readRegs();
        const stop = s.stop;
        s.stop = .none;
        switch (stop) {
            .syscall => {
                s.setSyscallType();
                return .syscall;
            },
            .fault => |f| return .{ .fault = f },
            .exception => |n| return s.exception(n),
            .none => {},
        }
        if (err != uc.UC_ERR_OK) {
            // Errors no hook saw, such as an invalid instruction on amd64.
            const pc = s.ureg.pc();
            return switch (err) {
                uc.UC_ERR_INSN_INVALID => .{ .fault = .{ .addr = pc, .access = .exec, .syndrome = @intCast(err) } },
                else => .{ .other = @intCast(err) },
            };
        }
        if (s.kicked.swap(false, .acquire)) return .interrupted;
        return .halted;
    }

    /// Fills Ureg.type the way the real kernel does for a syscall.
    fn setSyscallType(s: *State) void {
        switch (s.ureg) {
            .arm64 => |*u| u.type = @as(u64, arm64.EC_SVC64) << 26,
            .amd64 => |*u| u.type = amd64_vector_syscall,
        }
    }

    fn exception(s: *State, n: u32) vmm.Exit {
        const pc = s.ureg.pc();
        switch (s.ureg) {
            .arm64 => |*u| u.type = n,
            .amd64 => |*u| u.type = n,
        }
        return .{ .fault = .{ .addr = pc, .access = .exec, .syndrome = n } };
    }
};

// uc_ctl_flush_tb is a macro: UC_CTL_WRITE(UC_CTL_TB_FLUSH, 0).
const uc_ctl_tb_flush: c_uint = uc.UC_CTL_TB_FLUSH | (1 << 30);

// QEMU's arm64 exception numbers, as passed to UC_HOOK_INTR.
const arm64_excp_swi = 2;
const arm64_nzcv: u64 = 0xf000_0000;
// pc/io.h VectorSYSCALL, which 9front puts in Ureg.type for syscalls.
const amd64_vector_syscall = 64;
const amd64_flags_res1: u64 = 1 << 1;

const arm64_regs = blk: {
    var r: [34]c_int = undefined;
    for (0..29) |i| r[i] = uc.UC_ARM64_REG_X0 + @as(c_int, @intCast(i));
    r[29] = uc.UC_ARM64_REG_X29;
    r[30] = uc.UC_ARM64_REG_X30;
    r[31] = uc.UC_ARM64_REG_SP;
    r[32] = uc.UC_ARM64_REG_PC;
    r[33] = uc.UC_ARM64_REG_PSTATE;
    break :blk r;
};

const amd64_fields = [_][]const u8{ "ax", "bx", "cx", "dx", "si", "di", "bp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "pc", "sp" };
const amd64_regs = [_]c_int{
    uc.UC_X86_REG_RAX, uc.UC_X86_REG_RBX,    uc.UC_X86_REG_RCX, uc.UC_X86_REG_RDX,
    uc.UC_X86_REG_RSI, uc.UC_X86_REG_RDI,    uc.UC_X86_REG_RBP, uc.UC_X86_REG_R8,
    uc.UC_X86_REG_R9,  uc.UC_X86_REG_R10,    uc.UC_X86_REG_R11, uc.UC_X86_REG_R12,
    uc.UC_X86_REG_R13, uc.UC_X86_REG_R14,    uc.UC_X86_REG_R15, uc.UC_X86_REG_RIP,
    uc.UC_X86_REG_RSP, uc.UC_X86_REG_EFLAGS,
};

comptime {
    std.debug.assert(amd64_regs.len == amd64_fields.len + 1);
}

fn writeBatch(e: *uc.uc_engine, comptime regs: []const c_int, vals: []u64) vmm.Error!void {
    var ptrs: [regs.len]?*anyopaque = undefined;
    for (&ptrs, vals) |*p, *v| p.* = v;
    try check(uc.uc_reg_write_batch(e, regs.ptr, @ptrCast(&ptrs), regs.len));
}

fn readBatch(e: *uc.uc_engine, comptime regs: []const c_int, vals: []u64) vmm.Error!void {
    var ptrs: [regs.len]?*anyopaque = undefined;
    for (&ptrs, vals) |*p, *v| p.* = v;
    try check(uc.uc_reg_read_batch(e, regs.ptr, @ptrCast(&ptrs), regs.len));
}

pub const Vcpu = struct {
    s: *State,

    pub fn destroy(v: *Vcpu) void {
        const s = v.s;
        _ = uc.uc_close(s.engine);
        s.mapped.deinit(s.backend.gpa);
        s.backend.gpa.destroy(s);
    }

    pub fn setAddressSpace(v: *Vcpu, as: *AddressSpace) vmm.Error!void {
        if (v.s.as == as) return;
        v.s.as = as;
        v.s.generation = 0;
    }

    pub fn getUreg(v: *Vcpu, u: *vmm.Ureg) void {
        u.* = v.s.ureg;
    }

    pub fn setUreg(v: *Vcpu, u: *const vmm.Ureg) void {
        std.debug.assert(std.meta.activeTag(u.*) == v.s.arch);
        v.s.ureg = u.*;
    }

    pub fn getExtra(v: *Vcpu, x: *vmm.Extra) vmm.Error!void {
        const e = v.s.engine;
        switch (v.s.arch) {
            .arm64 => {
                for (&x.v, 0..) |*q, i| try check(uc.uc_reg_read(e, uc.UC_ARM64_REG_Q0 + @as(c_int, @intCast(i)), q));
                try check(uc.uc_reg_read(e, uc.UC_ARM64_REG_FPCR, &x.fpcr));
                try check(uc.uc_reg_read(e, uc.UC_ARM64_REG_FPSR, &x.fpsr));
                try check(uc.uc_reg_read(e, uc.UC_ARM64_REG_TPIDR_EL0, &x.tls));
            },
            .amd64 => {
                for (x.v[0..16], 0..) |*q, i| try check(uc.uc_reg_read(e, uc.UC_X86_REG_XMM0 + @as(c_int, @intCast(i)), q));
                var mxcsr: u32 = 0;
                try check(uc.uc_reg_read(e, uc.UC_X86_REG_MXCSR, &mxcsr));
                x.fpcr = mxcsr;
                try check(uc.uc_reg_read(e, uc.UC_X86_REG_FS_BASE, &x.tls));
            },
        }
    }

    pub fn setExtra(v: *Vcpu, x: *const vmm.Extra) vmm.Error!void {
        const e = v.s.engine;
        switch (v.s.arch) {
            .arm64 => {
                for (&x.v, 0..) |*q, i| try check(uc.uc_reg_write(e, uc.UC_ARM64_REG_Q0 + @as(c_int, @intCast(i)), q));
                try check(uc.uc_reg_write(e, uc.UC_ARM64_REG_FPCR, &x.fpcr));
                try check(uc.uc_reg_write(e, uc.UC_ARM64_REG_FPSR, &x.fpsr));
                try check(uc.uc_reg_write(e, uc.UC_ARM64_REG_TPIDR_EL0, &x.tls));
            },
            .amd64 => {
                for (x.v[0..16], 0..) |*q, i| try check(uc.uc_reg_write(e, uc.UC_X86_REG_XMM0 + @as(c_int, @intCast(i)), q));
                const mxcsr: u32 = @truncate(x.fpcr);
                try check(uc.uc_reg_write(e, uc.UC_X86_REG_MXCSR, &mxcsr));
                try check(uc.uc_reg_write(e, uc.UC_X86_REG_FS_BASE, &x.tls));
            },
        }
    }

    /// Safe from any thread. A kick before `run` makes the next run return
    /// `.interrupted` at once.
    pub fn kick(v: *Vcpu) void {
        v.s.kicked.store(true, .release);
        _ = uc.uc_emu_stop(v.s.engine);
    }

    pub fn run(v: *Vcpu) vmm.Error!vmm.Exit {
        return v.s.run();
    }
};
