//! The host's stdin as a `std.Io.Reader`, for the guest's console.
//!
//! On POSIX this is std's streaming file reader. On Windows, std reads with
//! NtReadFile and treats STATUS_PENDING as unreachable, which a console
//! handle under a pseudoconsole (Windows Terminal, OpenSSH, ConPTY) can
//! return, so there the reader calls ReadFile, which waits for the read.
//! A console in line mode ends each line with \r\n; the reader turns that
//! into \n, as a POSIX terminal does, so rc doesn't see a stray \r.

const std = @import("std");
const builtin = @import("builtin");

pub const Stdin = if (builtin.os.tag == .windows) WindowsStdin else PosixStdin;

const PosixStdin = struct {
    r: std.Io.File.Reader,

    pub fn init(s: *PosixStdin, io: std.Io, buf: []u8) void {
        s.r = std.Io.File.stdin().readerStreaming(io, buf);
    }

    pub fn reader(s: *PosixStdin) *std.Io.Reader {
        return &s.r.interface;
    }
};

const WindowsStdin = struct {
    const w = std.os.windows;
    extern "kernel32" fn ReadFile(h: w.HANDLE, buf: [*]u8, n: w.DWORD, read: ?*w.DWORD, ov: ?*anyopaque) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetConsoleMode(h: w.HANDLE, mode: *w.DWORD) callconv(.winapi) w.BOOL;
    const ERROR_BROKEN_PIPE: w.DWORD = 109;
    const ERROR_HANDLE_EOF: w.DWORD = 38;
    const ERROR_OPERATION_ABORTED: w.DWORD = 995;

    handle: ?w.HANDLE,
    console: bool,
    interface: std.Io.Reader,

    pub fn init(s: *WindowsStdin, _: std.Io, buf: []u8) void {
        s.handle = w.peb().ProcessParameters.hStdInput;
        var mode: w.DWORD = 0;
        s.console = if (s.handle) |h| GetConsoleMode(h, &mode).toBool() else false;
        s.interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = buf,
            .seek = 0,
            .end = 0,
        };
    }

    pub fn reader(s: *WindowsStdin) *std.Io.Reader {
        return &s.interface;
    }

    fn stream(r: *std.Io.Reader, wr: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const s: *WindowsStdin = @alignCast(@fieldParentPtr("interface", r));
        const h = s.handle orelse return error.EndOfStream;
        const dest = limit.slice(try wr.writableSliceGreedy(1));
        var n: w.DWORD = 0;
        while (true) {
            if (!ReadFile(h, dest.ptr, std.math.lossyCast(w.DWORD, dest.len), &n, null).toBool()) {
                return switch (@intFromEnum(w.GetLastError())) {
                    ERROR_BROKEN_PIPE, ERROR_HANDLE_EOF => error.EndOfStream,
                    else => error.ReadFailed,
                };
            }
            // Ctrl-C in a console with processed input ends a pending read
            // with no bytes and ERROR_OPERATION_ABORTED; that isn't EOF.
            if (n == 0 and s.console and @intFromEnum(w.GetLastError()) == ERROR_OPERATION_ABORTED) continue;
            break;
        }
        if (n == 0) return error.EndOfStream;
        var got: usize = n;
        if (s.console) got = crlfToLf(dest[0..n]);
        wr.advance(got);
        return got;
    }

    /// Replaces each \r\n in `b` with \n, in place; returns the new length.
    fn crlfToLf(b: []u8) usize {
        var o: usize = 0;
        for (b, 0..) |c, i| {
            if (c == '\r' and i + 1 < b.len and b[i + 1] == '\n') continue;
            b[o] = c;
            o += 1;
        }
        return o;
    }
};
