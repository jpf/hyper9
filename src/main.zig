const std = @import("std");
const hp9 = @import("hp9");

const usage = "usage: hp9 [--trace] binary [args...]\n";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var opts: hp9.Machine.Options = .{};
    var i: usize = 1;
    while (i < args.len and std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--trace")) {
            opts.trace = true;
        } else {
            std.debug.print(usage, .{});
            return 2;
        }
    }
    if (i >= args.len) {
        std.debug.print(usage, .{});
        return 2;
    }
    const path = args[i];
    const argv = args[i..];

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30)) catch |err| {
        std.debug.print("hp9: {s}: {t}\n", .{ path, err });
        return 1;
    };

    var machine = hp9.Machine.init(init.gpa, io, opts) catch |err| {
        std.debug.print("hp9: cannot create VM: {t} (is hp9 signed with hp9.entitlements?)\n", .{err});
        return 1;
    };
    defer machine.deinit();

    const status = machine.run(bytes, argv) catch |err| {
        std.debug.print("hp9: {s}: {t}\n", .{ path, err });
        return 1;
    };
    switch (status) {
        .exited => |msg| {
            if (msg.len == 0) return 0;
            std.debug.print("{s}\n", .{msg});
            return 1;
        },
        .killed => |msg| {
            std.debug.print("hp9: {s}: {s}\n", .{ path, msg });
            return 1;
        },
    }
}
