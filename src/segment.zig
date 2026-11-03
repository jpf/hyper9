//! A process's memory segments: text, data (data and bss together) and
//! stack, each a set of pages from the backend's allocator that it can free
//! again. See DESIGN.md, "Process model".
//!
//! A segment can be attached to several address spaces (rfork with RFMEM
//! shares text, data and bss), and a change to it, such as brk growing the
//! data, is mapped into all of them. It's freed when the last one detaches.
//!
//! Pages come in chunks, one backend allocation and one mapping each, so a
//! segment grows without copying. The stack grows down on demand, as
//! 9front's does: it starts with what the arguments need plus some
//! headroom, and `Segs.growStack` extends it on faults and at syscalls.

const std = @import("std");
const vmm = @import("vmm.zig");

const page = vmm.page_size;

pub const Kind = enum { text, data, stack };

/// Headroom kept below a stack address when the stack grows to cover it.
pub const stack_slack: u64 = 64 << 10;
/// Smallest step the data segment's mapping grows by.
pub const min_grow: u64 = 64 << 10;

pub const Error = vmm.CreateError;

pub const Segment = struct {
    gpa: std.mem.Allocator,
    backend: vmm.Backend,
    kind: Kind,
    perms: vmm.Perms,
    /// [base, top) is mapped: data grows `top` up, the stack grows `base` down.
    base: u64,
    top: u64,
    /// The break, for data: brk moves it, and `top` follows it up in steps
    /// of at least `min_grow`, so a run of small sbrks maps few chunks.
    brk: u64,
    /// Sorted by address and contiguous, covering [base, top).
    chunks: std.ArrayList(Chunk) = .empty,
    attached: std.ArrayList(vmm.AddressSpace) = .empty,
    lock: std.atomic.Mutex = .unlocked,

    const Chunk = struct { va: u64, mem: []align(page) u8 };

    /// A segment of `len` zeroed bytes at `base`, attached to nothing yet;
    /// `len` may be 0.
    pub fn create(gpa: std.mem.Allocator, backend: vmm.Backend, kind: Kind, perms: vmm.Perms, base: u64, len: u64) Error!*Segment {
        std.debug.assert(base % page == 0 and len % page == 0);
        const s = try gpa.create(Segment);
        s.* = .{ .gpa = gpa, .backend = backend, .kind = kind, .perms = perms, .base = base, .top = base + len, .brk = base + len };
        errdefer s.free();
        if (len > 0) {
            try s.chunks.ensureUnusedCapacity(gpa, 1);
            s.chunks.appendAssumeCapacity(.{ .va = base, .mem = try backend.allocPages(len / page) });
        }
        return s;
    }

    /// Frees a segment that's attached to nothing.
    fn free(s: *Segment) void {
        std.debug.assert(s.attached.items.len == 0);
        for (s.chunks.items) |c| s.backend.freePages(c.mem);
        s.chunks.deinit(s.gpa);
        s.attached.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    fn lockSpin(s: *Segment) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Maps the segment into `as`. A segment attached to nothing is freed
    /// if this fails, so callers can hand over a fresh one.
    pub fn attach(s: *Segment, as: vmm.AddressSpace) Error!void {
        s.lockSpin();
        attachLocked(s, as) catch |e| {
            const orphan = s.attached.items.len == 0;
            s.lock.unlock();
            if (orphan) s.free();
            return e;
        };
        s.lock.unlock();
    }

    fn attachLocked(s: *Segment, as: vmm.AddressSpace) Error!void {
        try s.attached.ensureUnusedCapacity(s.gpa, 1);
        for (s.chunks.items, 0..) |c, i| {
            as.map(c.va, c.mem, s.perms) catch |e| {
                for (s.chunks.items[0..i]) |m| as.unmap(m.va);
                return e;
            };
        }
        s.attached.appendAssumeCapacity(as);
    }

    /// Unmaps the segment from `as`, and frees it if that was the last.
    pub fn detach(s: *Segment, as: vmm.AddressSpace) void {
        s.lockSpin();
        for (s.attached.items, 0..) |a, i| if (std.meta.eql(a, as)) {
            for (s.chunks.items) |c| as.unmap(c.va);
            _ = s.attached.swapRemove(i);
            break;
        };
        const last = s.attached.items.len == 0;
        s.lock.unlock();
        if (last) s.free();
    }

    /// A private copy of the segment's pages, attached to nothing (rfork's
    /// eager copy).
    pub fn copy(s: *Segment) Error!*Segment {
        s.lockSpin();
        defer s.lock.unlock();
        const n = try create(s.gpa, s.backend, s.kind, s.perms, s.base, s.top - s.base);
        n.brk = s.brk;
        for (s.chunks.items) |c| @memcpy(n.chunks.items[0].mem[c.va - s.base ..][0..c.mem.len], c.mem);
        return n;
    }

    /// Adds zeroed pages at [va, va+len) and maps them everywhere the
    /// segment is attached. The caller holds the lock and keeps the chunks
    /// contiguous.
    fn addChunkLocked(s: *Segment, va: u64, len: u64, at: usize) Error!void {
        try s.chunks.ensureUnusedCapacity(s.gpa, 1);
        const mem = try s.backend.allocPages(len / page);
        for (s.attached.items, 0..) |as, i| {
            as.map(va, mem, s.perms) catch |e| {
                for (s.attached.items[0..i]) |m| m.unmap(va);
                s.backend.freePages(mem);
                return e;
            };
        }
        s.chunks.insertAssumeCapacity(at, .{ .va = va, .mem = mem });
    }

    fn growUpLocked(s: *Segment, top: u64) Error!void {
        if (top <= s.top) return;
        try s.addChunkLocked(s.top, top - s.top, s.chunks.items.len);
        s.top = top;
    }

    fn growDownLocked(s: *Segment, base: u64) Error!void {
        if (base >= s.base) return;
        try s.addChunkLocked(base, s.base - base, 0);
        s.base = base;
    }

    /// Zeroes [from, to) within the mapped part of the segment.
    fn zeroLocked(s: *Segment, from: u64, to: u64) void {
        for (s.chunks.items) |c| {
            const lo = @max(from, c.va);
            const hi = @min(to, c.va + c.mem.len);
            if (lo < hi) @memset(c.mem[lo - c.va .. hi - c.va], 0);
        }
    }

    /// Frees the chunks that lie wholly at or above `top`. A chunk that
    /// straddles it stays, so the segment may end above `top`.
    fn shrinkLocked(s: *Segment, top: u64) void {
        while (s.chunks.items.len > 0) {
            const c = s.chunks.items[s.chunks.items.len - 1];
            if (c.va < top) break;
            for (s.attached.items) |as| as.unmap(c.va);
            s.backend.freePages(c.mem);
            _ = s.chunks.pop();
            s.top = c.va;
        }
    }
};

pub const BrkError = error{
    /// Out of range, or out of memory ("virtual memory allocation failed").
    NoVmem,
    /// Shrinking a segment shared with other processes.
    InUse,
};

/// One process's segments.
pub const Segs = struct {
    text: ?*Segment = null,
    data: ?*Segment = null,
    stack: ?*Segment = null,
    /// Lowest address the stack may grow down to; brk stops below it.
    stack_floor: u64 = 0,

    /// Detaches every segment from `as`.
    pub fn release(s: *Segs, as: vmm.AddressSpace) void {
        inline for (.{ "text", "data", "stack" }) |f| if (@field(s, f)) |seg| {
            seg.detach(as);
            @field(s, f) = null;
        };
    }

    /// The segments for an rfork child running in `as`: text is shared,
    /// the stack is copied, and data is shared with RFMEM (`share`) and
    /// copied without it.
    pub fn fork(s: *const Segs, as: vmm.AddressSpace, share: bool) Error!Segs {
        var c: Segs = .{ .stack_floor = s.stack_floor };
        errdefer c.release(as);
        if (s.text) |t| {
            try t.attach(as);
            c.text = t;
        }
        if (s.data) |d| {
            const n = if (share) d else try d.copy();
            try n.attach(as);
            c.data = n;
        }
        if (s.stack) |st| {
            const n = try st.copy();
            try n.attach(as);
            c.stack = n;
        }
        return c;
    }

    /// The current break.
    pub fn brkTop(s: *const Segs) u64 {
        const d = s.data orelse return 0;
        d.lockSpin();
        defer d.lock.unlock();
        return d.brk;
    }

    /// Moves the break to `addr` (9front's ibrk), rounded up to a page. The
    /// data segment's mapping grows to cover it, and gives back whole chunks
    /// above it. With RFMEM the break is shared, since the segment is.
    pub fn brk(s: *Segs, addr: u64) BrkError!void {
        const d = s.data orelse return error.NoVmem;
        if (addr < d.base or addr > s.stack_floor) return error.NoVmem;
        const want = std.mem.alignForward(u64, addr, page);
        if (want > s.stack_floor) return error.NoVmem;
        d.lockSpin();
        defer d.lock.unlock();
        if (want >= d.brk) {
            if (want > d.top) {
                const step = std.mem.alignForward(u64, std.math.clamp((d.top - d.base) / 2, min_grow, 4 << 20), page);
                const top = @min(@max(want, d.top + step), s.stack_floor);
                d.growUpLocked(top) catch {
                    // Without the headroom, if that's what didn't fit.
                    if (top == want) return error.NoVmem;
                    d.growUpLocked(want) catch return error.NoVmem;
                };
            }
            d.brk = want;
            return;
        }
        // A shared segment's pages may already be in another process's
        // syscall, so 9front refuses to shrink it.
        if (d.attached.items.len > 1) return error.InUse;
        d.shrinkLocked(want);
        // Memory above the break reads as zero when it grows back.
        d.zeroLocked(want, d.brk);
        d.brk = want;
    }

    /// Grows the stack down so that `addr` and `stack_slack` below it are
    /// mapped. Returns whether `addr` is now mapped stack. Called on faults,
    /// and at each syscall with the SP, so that buffers on the stack that
    /// the guest hasn't touched yet are mapped before the kernel uses them.
    pub fn growStack(s: *Segs, addr: u64) bool {
        const st = s.stack orelse return false;
        st.lockSpin();
        defer st.lock.unlock();
        if (addr >= st.top or addr < s.stack_floor) return false;
        if (addr >= st.base + stack_slack or (addr >= st.base and st.base == s.stack_floor)) return true;
        // At least double, so a deep stack takes few chunks.
        const want = @min(std.mem.alignBackward(u64, addr, page) -| stack_slack, st.base -| (st.top - st.base));
        st.growDownLocked(@max(want, s.stack_floor)) catch return addr >= st.base;
        return true;
    }
};
