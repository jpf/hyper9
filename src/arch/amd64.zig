//! amd64 Plan 9 user ABI (9front amd64/include/ureg.h, 9/pc64/trap.c).

pub const Ureg = extern struct {
    ax: u64 = 0,
    bx: u64 = 0,
    cx: u64 = 0,
    dx: u64 = 0,
    si: u64 = 0,
    di: u64 = 0,
    bp: u64 = 0, // RARG: the syscall number, and the first argument of calls
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    ds: u16 = 0,
    es: u16 = 0,
    fs: u16 = 0,
    gs: u16 = 0,
    type: u64 = 0,
    @"error": u64 = 0,
    pc: u64 = 0,
    cs: u64 = 0,
    flags: u64 = 0,
    sp: u64 = 0,
    ss: u64 = 0,

    pub fn syscallNumber(u: *const Ureg) u64 {
        return u.bp;
    }
    pub fn syscallArgs(u: *const Ureg) u64 {
        return u.sp + 8;
    }
    pub fn setReturn(u: *Ureg, v: u64) void {
        u.ax = v;
    }
    /// Registers at process entry (execregs): AX holds the Tos pointer and
    /// R14/R15 (extern register variables) start at zero.
    pub fn initExec(entry: u64, sp: u64, tos: u64) Ureg {
        return .{ .ax = tos, .sp = sp, .pc = entry, .cs = UESEL, .ss = UDSEL };
    }
};

// pc64/mem.h: SELECTOR(UESEG, SELGDT, 3) and SELECTOR(UDSEG, SELGDT, 3).
pub const UESEL = (5 << 3) | 3;
pub const UDSEL = (4 << 3) | 3;

comptime {
    const std = @import("std");
    std.debug.assert(@offsetOf(Ureg, "type") == 128);
    std.debug.assert(@offsetOf(Ureg, "pc") == 144);
    std.debug.assert(@sizeOf(Ureg) == 184);
}
