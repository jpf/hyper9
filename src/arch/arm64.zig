//! arm64 Plan 9 user ABI (9front arm64/include/ureg.h, 9/arm64/trap.c).

/// Plan 9 Ureg. `type` holds ESR_EL1 for synchronous exceptions.
pub const Ureg = extern struct {
    r: [31]u64 = @splat(0), // r28 is SB, r30 is the link register
    sp: u64 = 0,
    pc: u64 = 0,
    psr: u64 = 0,
    type: u64 = 0,

    pub fn syscallNumber(u: *const Ureg) u64 {
        return u.r[0];
    }
    pub fn syscallArgs(u: *const Ureg) u64 {
        return u.sp + 8;
    }
    pub fn setReturn(u: *Ureg, v: u64) void {
        u.r[0] = v;
    }
    /// Registers at process entry: R0 holds the Tos pointer.
    pub fn initExec(entry: u64, sp: u64, tos: u64) Ureg {
        var u: Ureg = .{ .sp = sp, .pc = entry };
        u.r[0] = tos;
        return u;
    }
};

comptime {
    const std = @import("std");
    std.debug.assert(@offsetOf(Ureg, "sp") == 248);
    std.debug.assert(@offsetOf(Ureg, "type") == 272);
}

pub const EC_SVC64 = 0x15;
pub const EC_IABT_LOWER = 0x20;
pub const EC_DABT_LOWER = 0x24;
