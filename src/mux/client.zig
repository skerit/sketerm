//! Mux client connection: blocking helpers shared by the smoke
//! test, the TUI picker, and the GUI attach path (which switches
//! the fd to non-blocking and polls it from the GLib loop).

const std = @import("std");
const c = @import("../c.zig").c;
const wire = @import("wire.zig");
const daemon = @import("daemon.zig");

/// Resolve the sketerm-mux binary: sibling of our own executable
/// first (works for `zig build run` trees), then bare name ($PATH).
pub fn findMuxBinary(buf: *[4096:0]u8) [*:0]const u8 {
    const n = c.readlink("/proc/self/exe", buf, buf.len - 1);
    if (n > 0) {
        const exe_path = buf[0..@intCast(n)];
        if (std.mem.lastIndexOfScalar(u8, exe_path, '/')) |slash| {
            const dir_len = slash + 1;
            const want = "sketerm-mux";
            if (dir_len + want.len < buf.len) {
                @memcpy(buf[dir_len .. dir_len + want.len], want);
                buf[dir_len + want.len] = 0;
                if (c.access(buf, c.X_OK) == 0) return @ptrCast(buf);
            }
        }
    }
    return "sketerm-mux";
}

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

    /// Connect to the local daemon, spawning it (sibling binary,
    /// $PATH fallback) and retrying for ~2s when it isn't running.
    pub fn connectLocalAutostart(allocator: std.mem.Allocator) !Conn {
        const path = try daemon.defaultSocketPath(allocator);
        defer allocator.free(path);
        if (Conn.connect(allocator, path)) |conn| return conn else |_| {}

        const pid = c.fork();
        if (pid == 0) {
            _ = c.setsid();
            var bin_buf: [4096:0]u8 = undefined;
            const bin = findMuxBinary(&bin_buf);
            const argv = [_:null]?[*:0]const u8{ bin, null };
            _ = c.execvp(bin, @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        var tries: u32 = 0;
        while (tries < 40) : (tries += 1) {
            _ = c.usleep(50_000);
            if (Conn.connect(allocator, path)) |conn| return conn else |_| {}
        }
        return error.MuxDaemonUnreachable;
    }

    pub fn deinit(self: *Conn) void {
        _ = c.close(self.fd);
        self.rbuf.deinit(self.allocator);
    }

    /// Mosh-style UDP transport: bootstrap over SSH (run
    /// `sketerm-mux --udp-listen` remotely, read its one-line
    /// "SKETERM-UDP <port> <key>" announcement, ssh exits), then
    /// spawn a local `sketerm-mux --udp-connect` bridge over a
    /// socketpair. Everything downstream is fd-agnostic, same as
    /// the plain SSH transport — but the live connection is
    /// encrypted UDP with roaming + retransmission (rudp.zig).
    pub fn connectUdp(allocator: std.mem.Allocator, host: []const u8, port_range: ?[]const u8) !Conn {
        // 1. Bootstrap: ssh prints the announcement on a pipe.
        var pipe_fds: [2]c_int = undefined;
        if (c.pipe(&pipe_fds) != 0) return error.SocketFailed;

        var host_z_buf: [256:0]u8 = undefined;
        const host_z = std.fmt.bufPrintZ(&host_z_buf, "{s}", .{host}) catch return error.BadPath;
        const ssh_env = c.getenv("SKETERM_SSH");
        const ssh_bin: [*:0]const u8 = if (ssh_env != null) ssh_env else "ssh";

        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(pipe_fds[0]);
            _ = c.close(pipe_fds[1]);
            return error.ForkFailed;
        }
        if (pid == 0) {
            _ = c.dup2(pipe_fds[1], 1);
            _ = c.close(pipe_fds[0]);
            _ = c.close(pipe_fds[1]);
            var range_z_buf: [32:0]u8 = undefined;
            var argv = [_:null]?[*:0]const u8{
                ssh_bin, "-T", "-o", "BatchMode=yes", host_z.ptr, "sketerm-mux", "--udp-listen", null, null, null,
            };
            if (port_range) |r| {
                if (std.fmt.bufPrintZ(&range_z_buf, "{s}", .{r})) |rz| {
                    argv[7] = "--udp-port";
                    argv[8] = rz.ptr;
                } else |_| {}
            }
            _ = c.execvp(ssh_bin, @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        _ = c.close(pipe_fds[1]);

        // Read the announcement line (bounded; ssh chatter before it
        // is skipped line by line).
        var line_buf: [512]u8 = undefined;
        var line_len: usize = 0;
        var announce: ?[]const u8 = null;
        outer: while (line_len < line_buf.len) {
            const n = c.read(pipe_fds[0], line_buf[line_len..].ptr, line_buf.len - line_len);
            if (n <= 0) break;
            line_len += @intCast(n);
            var start: usize = 0;
            while (std.mem.indexOfScalarPos(u8, line_buf[0..line_len], start, '\n')) |nl| {
                const line = line_buf[start..nl];
                if (std.mem.startsWith(u8, line, "SKETERM-UDP ")) {
                    announce = line;
                    break :outer;
                }
                start = nl + 1;
            }
            if (start > 0) {
                std.mem.copyForwards(u8, line_buf[0 .. line_len - start], line_buf[start..line_len]);
                line_len -= start;
            }
        }
        _ = c.close(pipe_fds[0]);
        var st: c_int = 0;
        _ = c.waitpid(pid, &st, 0);
        const ann = announce orelse return error.SshTransportFailed;

        // "SKETERM-UDP <port> <keyhex>"
        var it = std.mem.tokenizeScalar(u8, ann, ' ');
        _ = it.next(); // tag
        const port = it.next() orelse return error.SshTransportFailed;
        const keyhex = it.next() orelse return error.SshTransportFailed;

        // 2. Local UDP bridge child over a socketpair. UDP goes to
        // the bare hostname (strip any user@ ssh prefix).
        const bare_host = if (std.mem.indexOfScalar(u8, host, '@')) |at| host[at + 1 ..] else host;
        var mux_bin_buf: [4096:0]u8 = undefined;
        const mux_bin = findMuxBinary(&mux_bin_buf);
        var port_z_buf: [16:0]u8 = undefined;
        const port_z = std.fmt.bufPrintZ(&port_z_buf, "{s}", .{port}) catch return error.SshTransportFailed;
        var key_z_buf: [128:0]u8 = undefined;
        const key_z = std.fmt.bufPrintZ(&key_z_buf, "{s}", .{keyhex}) catch return error.SshTransportFailed;
        var bh_z_buf: [256:0]u8 = undefined;
        const bh_z = std.fmt.bufPrintZ(&bh_z_buf, "{s}", .{bare_host}) catch return error.BadPath;

        const argv2 = [_:null]?[*:0]const u8{
            mux_bin, "--udp-connect", bh_z.ptr, port_z.ptr, key_z.ptr, null,
        };
        var conn = try spawnOverSocketpair(allocator, mux_bin, &argv2);
        errdefer conn.deinit();

        conn.sendJson(.hello, .{ .proto = @import("wire.zig").PROTO_VERSION }) catch return error.SshTransportFailed;
        const w = conn.recvExpect(&.{.welcome}) catch return error.SshTransportFailed;
        w.deinit(allocator);
        return conn;
    }

    /// Connect to a REMOTE host's daemon by running
    /// `ssh -T -o BatchMode=yes <host> sketerm-mux --proxy` over a
    /// socketpair (one fd both ways, so everything downstream is
    /// transport-agnostic). The child is double-forked — it reparents
    /// to init, no zombie to reap. Requires key/agent auth
    /// (BatchMode fails instead of prompting on the protocol pipe).
    /// $SKETERM_SSH overrides the ssh binary (tests fake a remote).
    pub fn connectSsh(allocator: std.mem.Allocator, host: []const u8) !Conn {
        var host_z_buf: [256:0]u8 = undefined;
        const host_z = std.fmt.bufPrintZ(&host_z_buf, "{s}", .{host}) catch return error.BadPath;
        const ssh_env = c.getenv("SKETERM_SSH");
        const ssh_bin: [*:0]const u8 = if (ssh_env != null) ssh_env else "ssh";

        const argv = [_:null]?[*:0]const u8{
            ssh_bin, "-T", "-o", "BatchMode=yes", host_z.ptr, "sketerm-mux", "--proxy", null,
        };
        var conn = try spawnOverSocketpair(allocator, ssh_bin, &argv);
        errdefer conn.deinit();

        // Probe the bridge: hello → welcome proves ssh + remote
        // binary + daemon all came up before we hand the conn out.
        conn.sendJson(.hello, .{ .proto = @import("wire.zig").PROTO_VERSION }) catch return error.SshTransportFailed;
        const w = conn.recvExpect(&.{.welcome}) catch return error.SshTransportFailed;
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

    /// Spawn `argv` with both stdio ends on one socketpair fd,
    /// double-forked so init reaps it (no zombies, child outlives
    /// nothing it shouldn't). Returns a Conn over our end.
    fn spawnOverSocketpair(allocator: std.mem.Allocator, bin: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) !Conn {
        var pair: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair) != 0) return error.SocketFailed;
        errdefer {
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
        }
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            if (c.fork() == 0) {
                _ = c.dup2(pair[1], 0);
                _ = c.dup2(pair[1], 1);
                _ = c.close(pair[0]);
                _ = c.close(pair[1]);
                _ = c.execvp(bin, @ptrCast(@constCast(argv)));
            }
            c._exit(0);
        }
        var st: c_int = 0;
        _ = c.waitpid(pid, &st, 0);
        _ = c.close(pair[1]);
        return .{ .allocator = allocator, .fd = pair[0] };
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
