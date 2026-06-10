//! Mux client connection: blocking helpers shared by the smoke
//! test, the TUI picker, and the GUI attach path (which switches
//! the fd to non-blocking and polls it from the GLib loop).

const std = @import("std");
const c = @import("../c.zig").c;
const wire = @import("wire.zig");
const daemon = @import("daemon.zig");

pub const Conn = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    rbuf: std.ArrayList(u8) = .empty,

    pub fn connect(allocator: std.mem.Allocator, sock_path: []const u8) !Conn {
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        var addr: c.struct_sockaddr_un = undefined;
        try daemon.fillSockaddrUn(&addr, sock_path);
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.ConnectFailed;
        return .{ .allocator = allocator, .fd = fd };
    }

    pub fn deinit(self: *Conn) void {
        _ = c.close(self.fd);
        self.rbuf.deinit(self.allocator);
    }

    /// Connect to a REMOTE host's daemon by running
    /// `ssh -T -o BatchMode=yes <host> sketerm-mux --proxy` over a
    /// socketpair (one fd both ways, so everything downstream is
    /// transport-agnostic). The child is double-forked — it reparents
    /// to init, no zombie to reap. Requires key/agent auth
    /// (BatchMode fails instead of prompting on the protocol pipe).
    /// $SKETERM_SSH overrides the ssh binary (tests fake a remote).
    pub fn connectSsh(allocator: std.mem.Allocator, host: []const u8) !Conn {
        var pair: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair) != 0) return error.SocketFailed;
        errdefer {
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
        }

        var host_z_buf: [256:0]u8 = undefined;
        const host_z = std.fmt.bufPrintZ(&host_z_buf, "{s}", .{host}) catch return error.BadPath;

        const ssh_env = c.getenv("SKETERM_SSH");
        const ssh_bin: [*:0]const u8 = if (ssh_env != null) ssh_env else "ssh";

        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            if (c.fork() == 0) {
                _ = c.dup2(pair[1], 0);
                _ = c.dup2(pair[1], 1);
                _ = c.close(pair[0]);
                _ = c.close(pair[1]);
                const argv = [_:null]?[*:0]const u8{
                    ssh_bin, "-T", "-o", "BatchMode=yes", host_z.ptr, "sketerm-mux", "--proxy", null,
                };
                _ = c.execvp(ssh_bin, @ptrCast(@constCast(&argv)));
            }
            c._exit(0);
        }
        var st: c_int = 0;
        _ = c.waitpid(pid, &st, 0);
        _ = c.close(pair[1]);

        var conn = Conn{ .allocator = allocator, .fd = pair[0] };
        // Probe the bridge: hello → welcome proves ssh + remote
        // binary + daemon all came up before we hand the conn out.
        conn.sendJson(.hello, .{ .proto = @import("wire.zig").PROTO_VERSION }) catch {
            conn.deinit();
            return error.SshTransportFailed;
        };
        const w = conn.recvExpect(&.{.welcome}) catch {
            conn.deinit();
            return error.SshTransportFailed;
        };
        w.deinit(allocator);
        return conn;
    }

    pub fn sendFrame(self: *Conn, ftype: wire.FrameType, payload: []const u8) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        try wire.appendFrame(&out, self.allocator, ftype, payload);
        var off: usize = 0;
        while (off < out.items.len) {
            const n = c.write(self.fd, out.items.ptr + off, out.items.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    pub fn sendJson(self: *Conn, ftype: wire.FrameType, value: anytype) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try std.json.Stringify.value(value, .{}, &aw.writer);
        try self.sendFrame(ftype, aw.written());
    }

    /// Blocking read of the next complete frame. The returned
    /// payload is heap-owned by `allocator`; caller frees.
    pub const OwnedFrame = struct {
        ftype: wire.FrameType,
        payload: []u8,

        pub fn deinit(self: OwnedFrame, allocator: std.mem.Allocator) void {
            allocator.free(self.payload);
        }
    };

    pub fn recvFrame(self: *Conn) !OwnedFrame {
        while (true) {
            if (try wire.peelFrame(self.rbuf.items)) |peeled| {
                const owned = try self.allocator.dupe(u8, peeled.frame.payload);
                const remaining = self.rbuf.items.len - peeled.consumed;
                std.mem.copyForwards(u8, self.rbuf.items[0..remaining], self.rbuf.items[peeled.consumed..]);
                self.rbuf.shrinkRetainingCapacity(remaining);
                return .{ .ftype = peeled.frame.ftype, .payload = owned };
            }
            var tmp: [16384]u8 = undefined;
            const n = c.read(self.fd, &tmp, tmp.len);
            if (n <= 0) return error.Disconnected;
            try self.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]);
        }
    }

    /// Receive frames until one of `want` arrives; frames of other
    /// types are discarded (e.g. EVENTS noise while waiting for an
    /// OK). Errors out on an `err` frame unless err is in `want`.
    pub fn recvExpect(self: *Conn, want: []const wire.FrameType) !OwnedFrame {
        while (true) {
            const f = try self.recvFrame();
            for (want) |w| {
                if (f.ftype == w) return f;
            }
            const was_err = f.ftype == .err;
            f.deinit(self.allocator);
            if (was_err) return error.DaemonError;
        }
    }
};
