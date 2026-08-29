//! Libc-only SOCKS5 CONNECT client used by the internal SSH ProxyCommand.

const std = @import("std");
const c = @import("../c.zig").c;
const clock = @import("../util/clock.zig");
const platform = @import("../util/platform.zig");

pub const DEFAULT_ENDPOINT = "127.0.0.1:9050";
const HANDSHAKE_TIMEOUT_MS: i64 = 20_000;

/// Widest bound address a CONNECT reply can name, plus its 2-byte port.
///
/// Derived from the ATYP=domain length byte's own type rather than from any
/// address family's width: that byte is remote input, and ReleaseFast strips
/// the slice bounds check that would otherwise catch a short scratch buffer.
const MAX_BOUND_ADDRESS = std.math.maxInt(u8) + 2;

pub const Endpoint = union(enum) {
    ipv4: struct { addr: [4]u8, port: u16 },
    ipv6: struct { addr: [16]u8, port: u16 },

    /// Parse a numeric IPv4 endpoint or a bracketed numeric IPv6 endpoint.
    pub fn parse(text: []const u8) !Endpoint {
        if (text.len == 0) return error.InvalidEndpoint;
        if (text[0] == '[') {
            const close = std.mem.indexOfScalar(u8, text, ']') orelse return error.InvalidEndpoint;
            if (close <= 1 or close + 2 > text.len or text[close + 1] != ':') return error.InvalidEndpoint;
            const port = parsePort(text[close + 2 ..]) catch return error.InvalidEndpoint;
            var host_z: [c.INET6_ADDRSTRLEN:0]u8 = undefined;
            const host = std.fmt.bufPrintZ(&host_z, "{s}", .{text[1..close]}) catch return error.InvalidEndpoint;
            var addr: [16]u8 = undefined;
            if (c.inet_pton(c.AF_INET6, host.ptr, &addr) != 1) return error.InvalidEndpoint;
            return .{ .ipv6 = .{ .addr = addr, .port = port } };
        }

        const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidEndpoint;
        if (colon == 0 or colon + 1 >= text.len or std.mem.indexOfScalar(u8, text[0..colon], ':') != null)
            return error.InvalidEndpoint;
        const port = parsePort(text[colon + 1 ..]) catch return error.InvalidEndpoint;
        var host_z: [c.INET_ADDRSTRLEN:0]u8 = undefined;
        const host = std.fmt.bufPrintZ(&host_z, "{s}", .{text[0..colon]}) catch return error.InvalidEndpoint;
        var addr: [4]u8 = undefined;
        if (c.inet_pton(c.AF_INET, host.ptr, &addr) != 1) return error.InvalidEndpoint;
        return .{ .ipv4 = .{ .addr = addr, .port = port } };
    }

    fn connect(self: Endpoint, deadline: i64) !c_int {
        const family: c_int = switch (self) {
            .ipv4 => c.AF_INET,
            .ipv6 => c.AF_INET6,
        };
        const fd = platform.socketCloexec(family, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        try setNonBlocking(fd);

        const result = switch (self) {
            .ipv4 => |ep| blk: {
                var sa = std.mem.zeroes(c.struct_sockaddr_in);
                sa.sin_family = c.AF_INET;
                sa.sin_port = std.mem.nativeToBig(u16, ep.port);
                @memcpy(std.mem.asBytes(&sa.sin_addr)[0..4], &ep.addr);
                break :blk c.connect(fd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in));
            },
            .ipv6 => |ep| blk: {
                var sa = std.mem.zeroes(c.struct_sockaddr_in6);
                sa.sin6_family = c.AF_INET6;
                sa.sin6_port = std.mem.nativeToBig(u16, ep.port);
                @memcpy(std.mem.asBytes(&sa.sin6_addr)[0..16], &ep.addr);
                break :blk c.connect(fd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in6));
            },
        };
        if (result == 0) return fd;
        const connect_errno = std.posix.errno(result);
        if (connect_errno != .INPROGRESS and connect_errno != .AGAIN) return error.ConnectFailed;
        try waitFd(fd, c.POLLOUT, deadline);
        var socket_error: c_int = 0;
        var len: c.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &socket_error, &len) != 0 or socket_error != 0)
            return error.ConnectFailed;
        return fd;
    }
};

fn parsePort(text: []const u8) !u16 {
    const port = try std.fmt.parseInt(u16, text, 10);
    if (port == 0) return error.InvalidPort;
    return port;
}

fn setNonBlocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) != 0)
        return error.NonBlockingFailed;
}

fn waitFd(fd: c_int, events: c_short, deadline: i64) !void {
    while (true) {
        const remain = deadline - clock.nowMs();
        if (remain <= 0) return error.Timeout;
        var pfd = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
        const result = c.poll(&pfd, 1, @intCast(@min(remain, 1000)));
        if (result < 0 and std.posix.errno(result) == .INTR) continue;
        if (result < 0 or pfd.revents & (c.POLLERR | c.POLLNVAL) != 0) return error.IoFailed;
        if (result > 0 and pfd.revents & (events | c.POLLHUP) != 0) return;
    }
}

fn writeAllFor(fd: c_int, bytes: []const u8, deadline: i64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
            c.send(fd, bytes.ptr + offset, bytes.len - offset, c.MSG_NOSIGNAL)
        else
            c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (count > 0) {
            offset += @intCast(count);
            continue;
        }
        const err = std.posix.errno(count);
        if (err == .INTR) continue;
        if (err != .AGAIN) return error.IoFailed;
        try waitFd(fd, c.POLLOUT, deadline);
    }
}

fn readExactFor(fd: c_int, bytes: []u8, deadline: i64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (count > 0) {
            offset += @intCast(count);
            continue;
        }
        if (count == 0) return error.UnexpectedEof;
        const err = std.posix.errno(count);
        if (err == .INTR) continue;
        if (err != .AGAIN) return error.IoFailed;
        try waitFd(fd, c.POLLIN, deadline);
    }
}

fn handshake(fd: c_int, destination: []const u8, port: u16, deadline: i64) !void {
    if (destination.len == 0 or destination.len > 255 or std.mem.indexOfScalar(u8, destination, 0) != null)
        return error.InvalidDestination;

    try writeAllFor(fd, &.{ 0x05, 0x01, 0x00 }, deadline);
    var method: [2]u8 = undefined;
    try readExactFor(fd, &method, deadline);
    if (!std.mem.eql(u8, &method, &.{ 0x05, 0x00 })) return error.AuthenticationUnsupported;

    var request: [4 + 1 + 255 + 2]u8 = undefined;
    request[0..5].* = .{ 0x05, 0x01, 0x00, 0x03, @intCast(destination.len) };
    @memcpy(request[5 .. 5 + destination.len], destination);
    std.mem.writeInt(u16, request[5 + destination.len ..][0..2], port, .big);
    try writeAllFor(fd, request[0 .. 7 + destination.len], deadline);

    var reply: [4]u8 = undefined;
    try readExactFor(fd, &reply, deadline);
    if (reply[0] != 0x05 or reply[2] != 0x00) return error.MalformedReply;
    if (reply[1] != 0x00) return error.ConnectRefused;
    const address_len: usize = switch (reply[3]) {
        0x01 => 4,
        0x04 => 16,
        // RFC 1928 lets the reply name the bound address, and the proxy
        // picks its length: up to 255 bytes, not the 16 an IPv6 address
        // takes.
        0x03 => blk: {
            var domain_len: [1]u8 = undefined;
            try readExactFor(fd, &domain_len, deadline);
            break :blk domain_len[0];
        },
        else => return error.MalformedReply,
    };
    var discard: [MAX_BOUND_ADDRESS]u8 = undefined;
    try readExactFor(fd, discard[0 .. address_len + 2], deadline);
}

fn writeSomeSocket(fd: c_int, bytes: []const u8) !usize {
    const count = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
        c.send(fd, bytes.ptr, bytes.len, c.MSG_NOSIGNAL)
    else
        c.write(fd, bytes.ptr, bytes.len);
    if (count > 0) return @intCast(count);
    if (count == 0) return error.IoFailed;
    const err = std.posix.errno(count);
    if (err == .INTR or err == .AGAIN) return 0;
    return error.IoFailed;
}

fn writeSomeFd(fd: c_int, bytes: []const u8) !usize {
    const count = c.write(fd, bytes.ptr, bytes.len);
    if (count > 0) return @intCast(count);
    if (count == 0) return error.IoFailed;
    const err = std.posix.errno(count);
    if (err == .INTR or err == .AGAIN) return 0;
    return error.IoFailed;
}

fn readSome(fd: c_int, bytes: []u8) !?usize {
    const count = c.read(fd, bytes.ptr, bytes.len);
    if (count > 0) return @intCast(count);
    if (count == 0) return null;
    const err = std.posix.errno(count);
    if (err == .INTR or err == .AGAIN) return 0;
    return error.IoFailed;
}

/// Pump ProxyCommand stdin/stdout over an established SOCKS stream.
fn pump(fd: c_int, stdin_fd: c_int, stdout_fd: c_int) !void {
    try setNonBlocking(stdin_fd);
    try setNonBlocking(stdout_fd);
    var to_remote: [64 * 1024]u8 = undefined;
    var to_remote_off: usize = 0;
    var to_remote_len: usize = 0;
    var to_ssh: [64 * 1024]u8 = undefined;
    var to_ssh_off: usize = 0;
    var to_ssh_len: usize = 0;
    var stdin_open = true;
    var remote_open = true;
    var write_shutdown = false;

    while (remote_open or to_ssh_len != 0) {
        if (!stdin_open and to_remote_len == 0 and !write_shutdown) {
            _ = c.shutdown(fd, c.SHUT_WR);
            write_shutdown = true;
        }

        const pollin: c_short = @intCast(c.POLLIN);
        const pollout: c_short = @intCast(c.POLLOUT);
        const stdin_events: c_short = if (stdin_open and to_remote_len == 0) pollin else 0;
        const socket_events: c_short = (if (remote_open and to_ssh_len == 0) pollin else 0) |
            (if (to_remote_len != 0) pollout else 0);
        const stdout_events: c_short = if (to_ssh_len != 0) pollout else 0;
        var fds = [_]c.struct_pollfd{
            .{ .fd = stdin_fd, .events = stdin_events, .revents = 0 },
            .{ .fd = fd, .events = socket_events, .revents = 0 },
            .{ .fd = stdout_fd, .events = stdout_events, .revents = 0 },
        };
        const polled = c.poll(&fds, fds.len, -1);
        if (polled < 0 and std.posix.errno(polled) == .INTR) continue;
        if (polled < 0) return error.IoFailed;

        if (to_remote_len != 0 and fds[1].revents & c.POLLOUT != 0) {
            const count = try writeSomeSocket(fd, to_remote[to_remote_off .. to_remote_off + to_remote_len]);
            to_remote_off += count;
            to_remote_len -= count;
            if (to_remote_len == 0) to_remote_off = 0;
        }
        if (to_ssh_len != 0 and fds[2].revents & c.POLLOUT != 0) {
            const count = try writeSomeFd(stdout_fd, to_ssh[to_ssh_off .. to_ssh_off + to_ssh_len]);
            to_ssh_off += count;
            to_ssh_len -= count;
            if (to_ssh_len == 0) to_ssh_off = 0;
        }
        if (stdin_open and to_remote_len == 0 and fds[0].revents & (c.POLLIN | c.POLLHUP) != 0) {
            const count = try readSome(stdin_fd, &to_remote);
            if (count) |n| {
                to_remote_len = n;
            } else {
                stdin_open = false;
            }
        }
        if (remote_open and to_ssh_len == 0 and fds[1].revents & (c.POLLIN | c.POLLHUP) != 0) {
            const count = try readSome(fd, &to_ssh);
            if (count) |n| {
                to_ssh_len = n;
            } else {
                remote_open = false;
            }
        }
        if (fds[0].revents & (c.POLLERR | c.POLLNVAL) != 0 or
            fds[1].revents & (c.POLLERR | c.POLLNVAL) != 0 or
            fds[2].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0)
            return error.IoFailed;
    }
}

/// Connect through SOCKS5 and bridge the supplied ProxyCommand descriptors.
pub fn connectAndPump(endpoint_text: []const u8, destination: []const u8, port_text: []const u8, stdin_fd: c_int, stdout_fd: c_int) !void {
    const endpoint = try Endpoint.parse(endpoint_text);
    const port = try parsePort(port_text);
    const deadline = clock.nowMs() + HANDSHAKE_TIMEOUT_MS;
    const fd = try endpoint.connect(deadline);
    defer _ = c.close(fd);
    try handshake(fd, destination, port, deadline);
    try pump(fd, stdin_fd, stdout_fd);
}

fn sigNoop(_: c_int) callconv(.c) void {}

/// Hidden command entry point; its route is argv-only and its environment is discarded.
pub fn serve(endpoint: []const u8, destination: []const u8, port: []const u8) u8 {
    _ = c.signal(c.SIGPIPE, &sigNoop);
    platform.clearEnvironment();
    connectAndPump(endpoint, destination, port, 0, 1) catch |err| {
        _ = c.fprintf(platform.stderr(), "sketerm SOCKS5 proxy: %s\n", @as([*:0]const u8, @errorName(err)));
        return 1;
    };
    return 0;
}

test "SOCKS endpoint accepts numeric IPv4 and bracketed IPv6 only" {
    const t = std.testing;
    const v4 = try Endpoint.parse(DEFAULT_ENDPOINT);
    try t.expectEqual(@as(u16, 9050), v4.ipv4.port);
    try t.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &v4.ipv4.addr);
    const v6 = try Endpoint.parse("[::1]:9150");
    try t.expectEqual(@as(u16, 9150), v6.ipv6.port);
    try t.expectEqual(@as(u8, 1), v6.ipv6.addr[15]);
    try t.expectError(error.InvalidEndpoint, Endpoint.parse("localhost:9050"));
    try t.expectError(error.InvalidEndpoint, Endpoint.parse("127.0.0.1:0"));
    try t.expectError(error.InvalidEndpoint, Endpoint.parse("::1:9050"));
}

const TestServer = struct {
    listen_fd: c_int,
    /// Length of the ATYP=domain bound address to answer with; null answers
    /// with the 4-byte ATYP=IPv4 form instead.
    bound_domain_len: ?u8 = null,
    ok: bool = false,

    fn run(self: *TestServer) void {
        const fd = c.accept(self.listen_fd, null, null);
        if (fd < 0) return;
        defer _ = c.close(fd);
        const deadline = clock.nowMs() + 5_000;
        var greeting: [3]u8 = undefined;
        readExactFor(fd, &greeting, deadline) catch return;
        if (!std.mem.eql(u8, &greeting, &.{ 5, 1, 0 })) return;
        writeAllFor(fd, &.{ 5, 0 }, deadline) catch return;
        const destination = "hidden-service.invalid";
        var request: [5 + destination.len + 2]u8 = undefined;
        readExactFor(fd, &request, deadline) catch return;
        if (!std.mem.eql(u8, request[0..5], &.{ 5, 1, 0, 3, destination.len })) return;
        if (!std.mem.eql(u8, request[5 .. 5 + destination.len], destination)) return;
        if (std.mem.readInt(u16, request[5 + destination.len ..][0..2], .big) != 22) return;
        if (self.bound_domain_len) |domain_len| {
            const n: usize = domain_len;
            // The bound name is filled with a marker byte so a drain of the
            // wrong length leaves it in the stream and corrupts the pump.
            var bound: [4 + 1 + MAX_BOUND_ADDRESS]u8 = undefined;
            bound[0..4].* = .{ 5, 0, 0, 3 };
            bound[4] = domain_len;
            @memset(bound[5 .. 5 + n], 'b');
            std.mem.writeInt(u16, bound[5 + n ..][0..2], 22, .big);
            writeAllFor(fd, bound[0 .. 7 + n], deadline) catch return;
        } else {
            writeAllFor(fd, &.{ 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 }, deadline) catch return;
        }
        var ping: [4]u8 = undefined;
        readExactFor(fd, &ping, deadline) catch return;
        if (!std.mem.eql(u8, &ping, "ping")) return;
        writeAllFor(fd, "pong", deadline) catch return;
        _ = c.shutdown(fd, c.SHUT_WR);
        self.ok = true;
    }
};

const TestClient = struct {
    endpoint: []const u8,
    fd: c_int,
    ok: bool = false,

    fn run(self: *TestClient) void {
        connectAndPump(self.endpoint, "hidden-service.invalid", "22", self.fd, self.fd) catch return;
        self.ok = true;
    }
};

/// Run one helper round trip against the in-process SOCKS server, whose reply
/// names its bound address per `bound_domain_len` (null = ATYP IPv4).
fn expectRoundTrip(bound_domain_len: ?u8) !void {
    const t = std.testing;
    const listen_fd = platform.socketCloexec(c.AF_INET, c.SOCK_STREAM, 0);
    if (listen_fd < 0) return error.SkipZigTest;
    defer _ = c.close(listen_fd);
    var sa = std.mem.zeroes(c.struct_sockaddr_in);
    sa.sin_family = c.AF_INET;
    sa.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
    if (c.bind(listen_fd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in)) != 0 or c.listen(listen_fd, 1) != 0)
        return error.SkipZigTest;
    var bound = std.mem.zeroes(c.struct_sockaddr_in);
    var bound_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
    try t.expectEqual(@as(c_int, 0), c.getsockname(listen_fd, @ptrCast(&bound), &bound_len));
    const port = std.mem.bigToNative(u16, bound.sin_port);
    var endpoint_buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "127.0.0.1:{d}", .{port});

    var server = TestServer{ .listen_fd = listen_fd, .bound_domain_len = bound_domain_len };
    const server_thread = try std.Thread.spawn(.{}, TestServer.run, .{&server});
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&pair));
    defer _ = c.close(pair[1]);
    var client = TestClient{ .endpoint = endpoint, .fd = pair[0] };
    const client_thread = try std.Thread.spawn(.{}, TestClient.run, .{&client});

    const deadline = clock.nowMs() + 5_000;
    try writeAllFor(pair[1], "ping", deadline);
    _ = c.shutdown(pair[1], c.SHUT_WR);
    var pong: [4]u8 = undefined;
    try readExactFor(pair[1], &pong, deadline);
    try t.expectEqualStrings("pong", &pong);
    client_thread.join();
    server_thread.join();
    try t.expect(client.ok);
    try t.expect(server.ok);
}

test "SOCKS helper sends domain ATYP and pumps both directions" {
    try expectRoundTrip(null);
}

test "SOCKS helper drains a 255-byte ATYP=domain bound address" {
    try expectRoundTrip(255);
}

test "SOCKS reply scratch covers every address type a reply may name" {
    // The round trip above cannot fail on a short scratch buffer: the drain
    // reads the right NUMBER of bytes either way, so the stream stays in sync
    // and only the stack past the buffer is smashed. This is the assertion
    // that catches an under-sized one.
    const widest: usize = @max(4, @max(16, std.math.maxInt(u8)));
    try std.testing.expect(MAX_BOUND_ADDRESS >= widest + 2);
}
