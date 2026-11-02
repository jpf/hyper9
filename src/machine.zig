//! One machine: a VM running a 9front process.
//!
//! M0 serves just enough syscalls (pwrite on stdout/stderr, exits) to run a
//! static binary. From M2 syscalls go through drawterm's kern instead.

const std = @import("std");
const vmm = @import("vmm.zig");
const loader = @import("loader.zig");
const aout = @import("aout.zig");

pub const Sys = enum(u64) {
    exits = 8,
    pwrite = 51,
    _,
};

pub const Status = union(enum) {
    /// The `exits` string; empty means success.
    exited: []const u8,
    /// The process died; the message is in Plan 9 note form.
    killed: []const u8,
};

pub const Machine = struct {
    pub const Options = struct {
        backend: vmm.BackendKind = .auto,
        /// Architecture of the binaries this machine runs; null means the host's.
        arch: ?vmm.Arch = null,
        trace: bool = false,
    };

    gpa: std.mem.Allocator,
    io: std.Io,
    backend: vmm.Backend,
    arch: vmm.Arch,
    opts: Options,
    msg_buf: [128]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) vmm.CreateError!Machine {
        const arch = opts.arch orelse vmm.host_arch orelse return error.WrongArch;
        const backend = try vmm.create(gpa, io, opts.backend, .{ .arch = arch });
        return .{ .gpa = gpa, .io = io, .opts = opts, .arch = arch, .backend = backend };
    }

    pub fn deinit(m: *Machine) void {
        m.backend.destroy();
    }

    /// Runs a binary to completion on the calling thread.
    pub fn run(m: *Machine, bytes: []const u8, argv: []const []const u8) !Status {
        if ((try aout.parse(bytes)).arch != m.arch) return error.WrongArch;
        const as = try m.backend.newAddressSpace();
        defer as.destroy();
        const img = try loader.load(m.backend, as, bytes, argv, 1);

        var vcpu = try m.backend.createVcpu();
        defer vcpu.destroy();
        try vcpu.setAddressSpace(as);

        var u: vmm.Ureg = .initExec(img.arch, img.entry, img.sp, img.tos);
        vcpu.setUreg(&u);
        while (true) {
            const exit = try vcpu.run();
            vcpu.getUreg(&u);
            switch (exit) {
                .syscall => {
                    if (try m.syscall(as, &u)) |status| return status;
                    vcpu.setUreg(&u);
                },
                .fault => |f| return .{ .killed = try std.fmt.bufPrint(&m.msg_buf, "sys: trap: fault {t} addr=0x{x} pc=0x{x}", .{ f.access, f.addr, u.pc() }) },
                .interrupted => {},
                .halted => return .{ .killed = "halted" },
                .other => |code| return .{ .killed = try std.fmt.bufPrint(&m.msg_buf, "sys: trap: unexpected exit 0x{x} pc=0x{x}", .{ code, u.pc() }) },
            }
        }
    }

    fn arg(as: vmm.AddressSpace, u: *const vmm.Ureg, i: u64) ?u64 {
        const p = as.translate(u.syscallArgs() + 8 * i, 8) orelse return null;
        return std.mem.readInt(u64, p[0..8], .little);
    }

    /// Copies a NUL-terminated guest string, truncated to buf.len (ERRMAX).
    fn readString(as: vmm.AddressSpace, va: u64, buf: []u8) ?[]const u8 {
        for (buf, 0..) |*c, i| {
            const p = as.translate(va + i, 1) orelse return null;
            if (p[0] == 0) return buf[0..i];
            c.* = p[0];
        }
        return buf;
    }

    fn syscall(m: *Machine, as: vmm.AddressSpace, u: *vmm.Ureg) !?Status {
        const nr: Sys = @enumFromInt(u.syscallNumber());
        const bad: Status = .{ .killed = "sys: bad address in syscall" };
        switch (nr) {
            .exits => {
                const p = arg(as, u, 0) orelse return bad;
                if (p == 0) return .{ .exited = "" };
                const str = readString(as, p, &m.msg_buf) orelse return bad;
                return .{ .exited = str };
            },
            .pwrite => {
                const fd = arg(as, u, 0) orelse return bad;
                const buf = arg(as, u, 1) orelse return bad;
                const n = arg(as, u, 2) orelse return bad;
                const data = as.translate(buf, n) orelse return bad;
                const file: std.Io.File = switch (fd) {
                    1 => .stdout(),
                    2 => .stderr(),
                    else => {
                        u.setReturn(@bitCast(@as(i64, -1)));
                        return null;
                    },
                };
                if (m.opts.trace) std.debug.print("1 pwrite {d} {d} = {d}\n", .{ fd, n, n });
                file.writeStreamingAll(m.io, data) catch {
                    u.setReturn(@bitCast(@as(i64, -1)));
                    return null;
                };
                u.setReturn(n);
                return null;
            },
            _ => return .{ .killed = "sys: bad sys call" },
        }
    }
};
