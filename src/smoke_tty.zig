//! Shared smoke stage: in-terminal attach (`sketerm mux` on a
//! non-sketerm terminal) end to end.
//!
//! Runs the real `mux_tty.attach` loop against the daemon over a
//! socketpair standing in for the tty, parses what it writes to the
//! "host" through the VT parser into a Screen, and checks that host
//! grid against the daemon's own view of the session. Then the detach
//! chord, scroll mode, survival of the session across the detach, and
//! the exit path.

const std = @import("std");
const c = @import("c.zig").c;
const platform = @import("util/platform.zig");
const clock = @import("util/clock.zig");
const client_mod = @import("mux/client.zig");
const wire = @import("mux/wire.zig");
const snapshot = @import("mux/snapshot.zig");
const mux_tty = @import("ipc/mux_tty.zig");
const Parser = @import("parser/vt.zig").Parser;
const Event = @import("parser/event.zig").Event;
const Screen = @import("grid/screen.zig").Screen;
const Pool = @import("grid/style_pool.zig").Pool;

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("smoke tty stage: FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

const SESSION = "ttyview";
const COLS: u16 = 80;
const ROWS: u16 = 24;

/// The "host terminal": bytes from the viewer's out_fd parsed into a grid.
const Host = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    pool: Pool,
    screen: *Screen,
    parser: Parser,
    /// Everything received, for sequence-level checks.
    raw: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator, fd: c_int) !*Host {
        const self = try allocator.create(Host);
        self.* = .{ .allocator = allocator, .fd = fd, .pool = undefined, .screen = undefined, .parser = Parser.init(allocator) };
        self.pool = try Pool.init(allocator);
        self.screen = try Screen.init(allocator, &self.pool, COLS, ROWS);
        self.screen.mute_responses = true;
        return self;
    }

    fn deinit(self: *Host) void {
        self.raw.deinit(self.allocator);
        self.parser.deinit();
        self.screen.deinit();
        self.pool.deinit();
        self.allocator.destroy(self);
    }

    fn emit(user: ?*anyopaque, ev: Event) void {
        const self: *Host = @ptrCast(@alignCast(user.?));
        var mut = ev;
        self.screen.apply(ev);
        mut.deinit(self.allocator);
    }

    /// Read whatever arrives within `ms`, feeding the parser.
    fn pump(self: *Host, ms: i32) bool {
        var got_any = false;
        const deadline = clock.nowMs() + ms;
        while (true) {
            const remain = deadline - clock.nowMs();
            if (remain <= 0) return got_any;
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            const r = c.poll(&pfd, 1, @intCast(remain));
            if (r <= 0) return got_any;
            var buf: [8192]u8 = undefined;
            const n = c.read(self.fd, &buf, buf.len);
            if (n <= 0) return got_any;
            got_any = true;
            self.raw.appendSlice(self.allocator, buf[0..@intCast(n)]) catch fail("host buffer");
            self.parser.advance(buf[0..@intCast(n)], emit, @ptrCast(self));
        }
    }

    /// Pump until the host grid contains `needle` (bounded).
    fn waitText(self: *Host, needle: []const u8, timeout_ms: i64) bool {
        const deadline = clock.nowMs() + timeout_ms;
        while (clock.nowMs() < deadline) {
            _ = self.pump(100);
            const text = self.screen.extractScreen(self.allocator) catch fail("host extract");
            defer self.allocator.free(text);
            if (std.mem.indexOf(u8, text, needle) != null) return true;
        }
        return false;
    }

    fn waitGone(self: *Host, needle: []const u8, timeout_ms: i64) bool {
        const deadline = clock.nowMs() + timeout_ms;
        while (clock.nowMs() < deadline) {
            _ = self.pump(100);
            const text = self.screen.extractScreen(self.allocator) catch fail("host extract");
            defer self.allocator.free(text);
            if (std.mem.indexOf(u8, text, needle) == null) return true;
        }
        return false;
    }

    fn send(self: *Host, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(self.fd, bytes.ptr + off, bytes.len - off);
            if (n <= 0) fail("host write");
            off += @intCast(n);
        }
    }
};

const ViewerJob = struct {
    allocator: std.mem.Allocator,
    conn: client_mod.Conn,
    fd: c_int,
    outcome: mux_tty.Outcome = .failed,

    fn run(self: *ViewerJob) void {
        self.outcome = mux_tty.attach(self.allocator, &self.conn, SESSION, .{
            .in_fd = self.fd,
            .out_fd = self.fd,
            .fixed_size = .{ .cols = COLS, .rows = ROWS },
            .quiet = true,
            .signals = false,
        });
    }
};

fn connect(allocator: std.mem.Allocator, sock_path: []const u8) client_mod.Conn {
    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("connect");
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("hello");
    (conn.recvExpect(&.{.welcome}) catch fail("welcome")).deinit(allocator);
    return conn;
}

/// The daemon's own text for the session, via a read-only attach.
fn daemonText(allocator: std.mem.Allocator, sock_path: []const u8) []u8 {
    var conn = connect(allocator, sock_path);
    defer conn.deinit();
    conn.sendJson(.attach, .{ .name = SESSION, .kind = "cli", .read_only = true }) catch fail("peek attach");
    const snap = conn.recvExpectFor(&.{.snapshot}, 10_000) catch fail("peek snapshot");
    defer snap.deinit(allocator);
    const restored = snapshot.restoreOwned(allocator, snap.payload) catch fail("peek restore");
    defer restored.deinit(allocator);
    return restored.screen.extractScreen(allocator) catch fail("peek extract");
}

fn sessionListed(allocator: std.mem.Allocator, sock_path: []const u8) bool {
    var conn = connect(allocator, sock_path);
    defer conn.deinit();
    conn.sendFrame(.list, "") catch fail("list");
    const lst = conn.recvExpectFor(&.{.welcome}, 10_000) catch fail("list reply");
    defer lst.deinit(allocator);
    return std.mem.indexOf(u8, lst.payload, "\"" ++ SESSION ++ "\"") != null;
}

/// Start the viewer loop on its own thread over a fresh socketpair.
fn startViewer(allocator: std.mem.Allocator, sock_path: []const u8, job: *ViewerJob) struct { thread: std.Thread, host_fd: c_int } {
    var pair: [2]c_int = undefined;
    if (platform.socketpairCloexec(&pair) != 0) fail("socketpair");
    job.* = .{ .allocator = allocator, .conn = connect(allocator, sock_path), .fd = pair[1] };
    const th = std.Thread.spawn(.{}, ViewerJob.run, .{job}) catch fail("viewer thread");
    return .{ .thread = th, .host_fd = pair[0] };
}

pub fn run(allocator: std.mem.Allocator, sock_path: []const u8) void {
    var ctl = connect(allocator, sock_path);
    defer ctl.deinit();
    ctl.sendJson(.spawn, .{
        .name = SESSION,
        .argv = [_][]const u8{"/bin/sh"},
        .env = [_][]const u8{ "PS1=$ ", "TERM=xterm" },
        .rows = ROWS,
        .cols = COLS,
    }) catch fail("spawn");
    (ctl.recvExpectFor(&.{.ok}, 10_000) catch fail("spawn ok")).deinit(allocator);

    // ── attach, type, compare grids ──
    var job: ViewerJob = undefined;
    const v = startViewer(allocator, sock_path, &job);
    const host = Host.init(allocator, v.host_fd) catch fail("host init");
    defer host.deinit();
    defer _ = c.close(v.host_fd);

    host.send("echo tty-smoke-marker\r");
    if (!host.waitText("tty-smoke-marker", 10_000)) fail("marker never rendered on the host");
    // Let the shell finish its prompt, then compare with the daemon's grid.
    _ = host.pump(300);
    _ = host.pump(200);
    const theirs = daemonText(allocator, sock_path);
    defer allocator.free(theirs);
    const ours = host.screen.extractScreen(allocator) catch fail("host extract");
    defer allocator.free(ours);
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, theirs, "\n"), std.mem.trimEnd(u8, ours, "\n"))) {
        std.debug.print("daemon grid:\n{s}\n--- host grid:\n{s}\n", .{ theirs, ours });
        fail("host grid differs from the daemon's");
    }
    if (std.mem.indexOf(u8, host.raw.items, "\x1b[?1049h") == null) fail("viewer never entered the alternate screen");
    if (std.mem.indexOf(u8, host.raw.items, "\x1b[?2026h") == null) fail("viewer does not bracket frames with synchronized output");

    // ── scroll mode: indicator on, keys eaten, indicator off ──
    host.send("\x1c[");
    if (!host.waitText("scrollback 0/", 5_000)) fail("scroll indicator never appeared");
    host.send("q");
    if (!host.waitGone("scrollback", 5_000)) fail("scroll indicator never left");

    // ── a literal Ctrl-\ after the prefix reaches the shell ──
    // (sh prints nothing for it; the point is that it is not a detach)
    host.send("\x1c\\");
    _ = host.pump(200);
    if (job.outcome != .failed) fail("prefix+backslash must not detach");

    // ── detach: session survives, host handed back ──
    host.send("\x1c\x1c");
    v.thread.join();
    job.conn.deinit();
    if (job.outcome != .detached) fail("double prefix did not detach");
    _ = host.pump(100);
    if (std.mem.indexOf(u8, host.raw.items, "\x1b[?1049l") == null) fail("viewer never left the alternate screen");
    if (!sessionListed(allocator, sock_path)) fail("session died on detach");

    // ── reattach on a fresh viewer; the shell exiting ends the view ──
    var job2: ViewerJob = undefined;
    const v2 = startViewer(allocator, sock_path, &job2);
    const host2 = Host.init(allocator, v2.host_fd) catch fail("host2 init");
    defer host2.deinit();
    defer _ = c.close(v2.host_fd);
    if (!host2.waitText("tty-smoke-marker", 10_000)) fail("reattach snapshot lost the earlier output");
    host2.send("exit\r");
    v2.thread.join();
    job2.conn.deinit();
    if (job2.outcome != .exited) fail("shell exit was not reported as the session ending");

    std.debug.print("smoke-mux: in-terminal attach (mux_tty) ok\n", .{});
}
