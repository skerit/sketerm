//! `sketerm-mux --proxy` targets beyond the per-user daemon: `--instance`
//! (a live MCP server's private daemon on this host) and `--via` (the next
//! hop of a route, dialed with THIS host's ssh). Both halves of the hop
//! protocol live here: what a hop prints and what a client reads back.
//!
//! A routed proxy prints ONE status line on stdout before any mux byte:
//! `hop` (the next hop is routed too and prints its own), `ok` (the mux
//! stream follows) or `err <code> <message>`. The route flags precede
//! `--proxy` on every command line this module builds, because an older
//! sketerm-mux dispatches `--proxy` the moment it sees it and would bridge
//! the per-user daemon while ignoring the rest; in front, it refuses the
//! first one with `unknown argument: --via` and exits, which the client
//! names as "too old". libc only: compiled into `sketerm-mux`.

const std = @import("std");
const c = @import("../c.zig").c;
const sshroute = @import("sshroute.zig");
const sockpath = @import("sockpath.zig");
const selfexec = @import("selfexec.zig");
const deploy = @import("deploy.zig");
const socks5_client = @import("socks5_client.zig");
const shellquote = @import("../util/shellquote.zig");
const fdio = @import("../util/fdio.zig");
const platform = @import("../util/platform.zig");
const webpresence = @import("../web/webpresence.zig");
const mcp_registry = @import("../ipc/mcp_registry.zig");

pub const VIA_FLAG = "--via";
pub const INSTANCE_FLAG = "--instance";
pub const STATUS_PREFIX = "SKETERM-ROUTE ";
/// Longest status line either side handles, newline included.
pub const MAX_LINE = 512;

/// Why a hop refused. The tag is the wire word.
pub const Code = enum {
    /// A hop or instance value no route may carry.
    bad_route,
    /// No live MCP server and no instance directory by that key.
    unknown_instance,
    /// The instance directory exists, but no live server holds it.
    dead_instance,
    /// A live server, whose private daemon is not running.
    instance_down,
    /// The next hop's ssh could not be started.
    exec_failed,
};

pub const Status = union(enum) {
    hop,
    ok,
    err: struct { code: Code, msg: []const u8 },
};

/// The line for `status`, newline included; the message is cut to fit and
/// stripped of control bytes so it stays one line.
pub fn formatStatus(buf: *[MAX_LINE]u8, status: Status) []const u8 {
    var w: std.Io.Writer = .fixed(buf[0 .. MAX_LINE - 1]);
    w.writeAll(STATUS_PREFIX) catch unreachable;
    switch (status) {
        .hop => w.writeAll("hop") catch unreachable,
        .ok => w.writeAll("ok") catch unreachable,
        .err => |e| {
            w.print("err {s} ", .{@tagName(e.code)}) catch unreachable;
            for (e.msg) |b| w.writeByte(if (b < 0x20 or b == 0x7f) ' ' else b) catch break;
        },
    }
    const n = w.buffered().len;
    buf[n] = '\n';
    return buf[0 .. n + 1];
}

/// One status line without its newline; null for anything else.
pub fn parseStatus(line: []const u8) ?Status {
    if (!std.mem.startsWith(u8, line, STATUS_PREFIX)) return null;
    const rest = line[STATUS_PREFIX.len..];
    if (std.mem.eql(u8, rest, "hop")) return .hop;
    if (std.mem.eql(u8, rest, "ok")) return .ok;
    if (!std.mem.startsWith(u8, rest, "err ")) return null;
    const tail = rest["err ".len..];
    const sp = std.mem.indexOfScalar(u8, tail, ' ') orelse tail.len;
    const code = std.meta.stringToEnum(Code, tail[0..sp]) orelse return null;
    return .{ .err = .{ .code = code, .msg = if (sp < tail.len) tail[sp + 1 ..] else "" } };
}

/// An older sketerm-mux's refusal of a route flag, as it prints it.
pub fn refusedByOldBinary(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "unknown argument: " ++ VIA_FLAG) != null or
        std.mem.indexOf(u8, stderr, "unknown argument: " ++ INSTANCE_FLAG) != null;
}

/// The route flags of one `sketerm-mux` invocation, unvalidated until `check`.
pub const Args = struct {
    via: [sshroute.RouteSpec.MAX_HOPS][]const u8 = undefined,
    n_via: usize = 0,
    instance: ?[]const u8 = null,

    pub fn isFlag(arg: []const u8) bool {
        return std.mem.eql(u8, arg, VIA_FLAG) or std.mem.eql(u8, arg, INSTANCE_FLAG);
    }

    /// Record one `flag value` pair; `flag` must satisfy `isFlag`.
    pub fn take(self: *Args, flag: []const u8, value: []const u8) error{ TooManyHops, DuplicateInstance }!void {
        if (std.mem.eql(u8, flag, VIA_FLAG)) {
            if (self.n_via >= self.via.len) return error.TooManyHops;
            self.via[self.n_via] = value;
            self.n_via += 1;
        } else {
            if (self.instance != null) return error.DuplicateInstance;
            self.instance = value;
        }
    }

    pub fn routed(self: *const Args) bool {
        return self.n_via > 0 or self.instance != null;
    }

    pub fn hops(self: *const Args) []const []const u8 {
        return self.via[0..self.n_via];
    }

    /// Why these flags cannot be served, or null.
    pub fn check(self: *const Args) ?[]const u8 {
        for (self.hops()) |hop| if (!sshroute.validHop(hop)) return "a --via hop is not a plain ssh destination";
        if (self.instance) |inst| if (!webpresence.validInstance(inst)) return "--instance is not an MCP instance key";
        return null;
    }
};

/// `exec <bin> [--via H]... [--instance K] --proxy`, shell-quoted where a
/// word needs it (`[::1]`): the one remote command a route's ssh leg runs.
pub fn remoteCommand(allocator: std.mem.Allocator, bin: []const u8, rest_hops: []const []const u8, instance: ?[]const u8) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "exec ");
    try shellquote.appendQuoted(&out, allocator, bin);
    for (rest_hops) |hop| {
        try out.appendSlice(allocator, " " ++ VIA_FLAG ++ " ");
        try shellquote.appendQuoted(&out, allocator, hop);
    }
    if (instance) |inst| {
        try out.appendSlice(allocator, " " ++ INSTANCE_FLAG ++ " ");
        try shellquote.appendQuoted(&out, allocator, inst);
    }
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, selfexec.Mode.proxy.flag().?);
    return out.toOwnedSliceSentinel(allocator, 0);
}

/// What a routed `--proxy` left for its caller to do.
pub const Outcome = union(enum) {
    exit: u8,
    /// Pump stdin/stdout against this connected daemon socket.
    bridge: c_int,
};

fn say(status: Status) void {
    var buf: [MAX_LINE]u8 = undefined;
    _ = fdio.writeAll(1, formatStatus(&buf, status));
}

fn refuse(code: Code, msg: []const u8) Outcome {
    say(.{ .err = .{ .code = code, .msg = msg } });
    std.debug.print("sketerm-mux --proxy: {s}\n", .{msg});
    return .{ .exit = 2 };
}

/// Serve a routed `--proxy`: execs the next hop's ssh (`--via`) or
/// connects an instance daemon (`--instance`) without ever starting one.
pub fn run(allocator: std.mem.Allocator, args: Args) Outcome {
    if (args.check()) |why| return refuse(.bad_route, why);
    if (args.n_via > 0) return execNext(allocator, args);
    const key = args.instance.?;
    const found = mcp_registry.lookupInstance(allocator, key) catch return refuse(.unknown_instance, "cannot read this host's MCP registry");
    var msg_buf: [256]u8 = undefined;
    switch (found) {
        .invalid => return refuse(.bad_route, "--instance is not an MCP instance key"),
        .unknown => return refuse(.unknown_instance, std.fmt.bufPrint(&msg_buf, "no MCP instance '{s}' on this host", .{key}) catch "no such MCP instance"),
        .dead => return refuse(.dead_instance, std.fmt.bufPrint(&msg_buf, "MCP instance '{s}' is not running (no live server holds it)", .{key}) catch "MCP instance not running"),
        .live => |path| {
            defer allocator.free(path);
            const fd = connectUnix(path) orelse return refuse(.instance_down, std.fmt.bufPrint(&msg_buf, "MCP instance '{s}' is live but its daemon is not running", .{key}) catch "instance daemon not running");
            say(.ok);
            return .{ .bridge = fd };
        },
    }
}

fn connectUnix(path: []const u8) ?c_int {
    var addr: c.struct_sockaddr_un = undefined;
    sockpath.fillSockaddrUn(&addr, path) catch return null;
    const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return null;
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
        _ = c.close(fd);
        return null;
    }
    return fd;
}

/// Become `ssh <next> sketerm-mux <rest of the route> --proxy`. The status
/// goes out first: `ok` when the next hop is a plain `--proxy` (it prints
/// nothing, so this is the last word the route protocol gets), else `hop`.
fn execNext(allocator: std.mem.Allocator, args: Args) Outcome {
    const next = args.via[0];
    const rest = args.via[1..args.n_via];
    const command = remoteCommand(allocator, selfexec.BINARY, rest, args.instance) catch return refuse(.exec_failed, "out of memory");
    defer allocator.free(command);
    const plan = sshroute.Plan.init(next, .direct, socks5_client.DEFAULT_ENDPOINT) catch return refuse(.bad_route, "a --via hop is not a plain ssh destination");
    const ssh_env = c.getenv("SKETERM_SSH");
    const ssh_bin: [*:0]const u8 = if (ssh_env != null) ssh_env else "ssh";
    var route_args = plan.args(ssh_env == null and deploy.canMultiplex()) catch return refuse(.exec_failed, "cannot build the ssh options");
    var argv: [40:null]?[*:0]const u8 = .{null} ** 40;
    var n: usize = 0;
    argv[n] = ssh_bin;
    n += 1;
    route_args.append(&argv, &n) catch return refuse(.exec_failed, "cannot build the ssh options");
    var host_z: [256:0]u8 = undefined;
    const hz = std.fmt.bufPrintZ(&host_z, "{s}", .{next}) catch return refuse(.bad_route, "hop too long");
    if (n + 3 > argv.len) return refuse(.exec_failed, "too many ssh options");
    argv[n] = hz.ptr;
    argv[n + 1] = command.ptr;
    argv[n + 2] = null;
    say(if (rest.len == 0 and args.instance == null) .ok else .hop);
    _ = c.execvp(ssh_bin, @ptrCast(&argv));
    std.debug.print("sketerm-mux --proxy: cannot run ssh for the next hop ({s})\n", .{next});
    return .{ .exit = 127 };
}

const t = std.testing;

test "status lines round-trip and stay one line" {
    var buf: [MAX_LINE]u8 = undefined;
    try t.expectEqualStrings("SKETERM-ROUTE ok\n", formatStatus(&buf, .ok));
    try t.expectEqualStrings("SKETERM-ROUTE hop\n", formatStatus(&buf, .hop));
    const line = formatStatus(&buf, .{ .err = .{ .code = .dead_instance, .msg = "gone\nnow" } });
    try t.expectEqualStrings("SKETERM-ROUTE err dead_instance gone now\n", line);
    const back = parseStatus(line[0 .. line.len - 1]).?;
    try t.expectEqual(Code.dead_instance, back.err.code);
    try t.expectEqualStrings("gone now", back.err.msg);
    try t.expectEqual(Status.ok, parseStatus("SKETERM-ROUTE ok").?);
    try t.expect(parseStatus("SKETERM-ROUTE err nonsense x") == null);
    try t.expect(parseStatus("\x00\x00\x00") == null);
    // An overlong message is cut, never spilled onto a second line.
    const long = formatStatus(&buf, .{ .err = .{ .code = .bad_route, .msg = "x" ** 900 } });
    try t.expectEqual(@as(usize, MAX_LINE), long.len);
    try t.expectEqual(@as(?usize, long.len - 1), std.mem.indexOfScalar(u8, long, '\n'));
}

test "proxy route flags: collected, bounded and validated" {
    var a: Args = .{};
    try t.expect(!a.routed());
    try t.expect(Args.isFlag("--via") and Args.isFlag("--instance") and !Args.isFlag("--proxy"));
    try a.take("--via", "hostb");
    try a.take("--instance", "tmp-12");
    try t.expect(a.routed());
    try t.expect(a.check() == null);
    try t.expectError(error.DuplicateInstance, a.take("--instance", "x"));
    var bad: Args = .{};
    try bad.take("--via", "b;touch /tmp/x");
    try t.expect(bad.check() != null);
    var bad_inst: Args = .{};
    try bad_inst.take("--instance", "../etc");
    try t.expect(bad_inst.check() != null);
    var many: Args = .{};
    for (0..sshroute.RouteSpec.MAX_HOPS) |_| try many.take("--via", "h");
    try t.expectError(error.TooManyHops, many.take("--via", "h"));
}

test "the remote command puts the route flags before --proxy, every word quoted" {
    const cmd = try remoteCommand(t.allocator, "sketerm-mux", &.{"hostc"}, "tmp-7");
    defer t.allocator.free(cmd);
    try t.expectEqualStrings("exec sketerm-mux --via hostc --instance tmp-7 --proxy", cmd);
    const deployed = try remoteCommand(t.allocator, "/home/u/.cache/sketerm/sketerm-mux-ab cd", &.{}, null);
    defer t.allocator.free(deployed);
    try t.expectEqualStrings("exec '/home/u/.cache/sketerm/sketerm-mux-ab cd' --proxy", deployed);
}

test "an older binary's refusal is recognised by what it prints" {
    try t.expect(refusedByOldBinary("sketerm-mux: unknown argument: --via\n"));
    try t.expect(refusedByOldBinary("noise\nsketerm-mux: unknown argument: --instance\n"));
    try t.expect(!refusedByOldBinary("ssh: Could not resolve hostname b\n"));
}
