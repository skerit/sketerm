//! Host-clipboard paste into a forwarded app, shared by smoke-mux and
//! smoke-broker.
//!
//! The daemon brain cannot read the host clipboard; a viewer can. This
//! stage runs REAL wl-clipboard clients on a display session and proves:
//!   1. with no viewer attached, `wl-paste` completes (empty) instead of
//!      hanging on a receive fd nobody will ever write;
//!   2. a viewer whose hello says `paste_request:true` is asked
//!      (paste_request unit) and its answer is what `wl-paste` prints;
//!   3. when the host clipboard changes (the viewer's offer_selection),
//!      an app's OWN selection source is cancelled: `wl-copy
//!      --foreground` exits, and the next paste is the host's text.
//! Skipped when wl-clipboard is not installed.

const std = @import("std");
const c = @import("c.zig").c;
const client_mod = @import("mux/client.zig");
const wire = @import("mux/wire.zig");
const wlpipe = @import("wlhost/pipe.zig");
const displaycli = @import("smoke/displaycli.zig");
const nowMs = @import("util/clock.zig").nowMs;

const TAG = "smoke-paste";
const HOST_TEXT = "HOST-PASTE-7731";

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print(TAG ++ ": FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

const CreateReply = struct {
    session: []const u8 = "",
    environment: struct { WAYLAND_DISPLAY: []const u8 = "" } = .{},
};

/// A raw viewer that answers paste requests with `HOST_TEXT` and can
/// announce a host clipboard change on every app channel it sees.
const PasteViewer = struct {
    allocator: std.mem.Allocator,
    conn: client_mod.Conn,
    chans: std.ArrayList(u32) = .empty,
    unitbuf: std.ArrayList(u8) = .empty,
    requests: usize = 0,

    fn attach(allocator: std.mem.Allocator, sock_path: []const u8, name: []const u8) PasteViewer {
        var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("viewer connect");
        conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION, .paste_request = true }) catch fail("viewer hello");
        const w = conn.recvExpectFor(&.{.welcome}, 15_000) catch fail("viewer welcome");
        const flags = @import("mux/capabilities.zig").parse(allocator, w.payload);
        w.deinit(allocator);
        if (!flags.app_paste_request) fail("daemon does not advertise app_paste_request");
        conn.sendJson(.attach, .{ .name = name, .kind = "gui" }) catch fail("viewer attach");
        (conn.recvExpectFor(&.{.snapshot}, 15_000) catch fail("viewer snapshot")).deinit(allocator);
        conn.setNonBlocking();
        return .{ .allocator = allocator, .conn = conn };
    }

    fn deinit(self: *PasteViewer) void {
        self.conn.deinit();
        self.chans.deinit(self.allocator);
        self.unitbuf.deinit(self.allocator);
    }

    fn send(self: *PasteViewer, chan: u32, tag: wlpipe.Tag, payload: []const u8) void {
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(self.allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, chan, .little);
        units.appendSlice(self.allocator, &idb) catch fail("oom");
        wlpipe.appendUnit(&units, self.allocator, tag, payload) catch fail("oom");
        self.conn.sendFrame(.chan_data, units.items) catch fail("chan_data send");
    }

    fn pump(self: *PasteViewer) void {
        if (!self.conn.fillAvailable()) fail("viewer connection lost");
        while (self.conn.takeFrame() catch fail("viewer frame")) |f| {
            defer f.deinit(self.allocator);
            switch (f.ftype) {
                .chan_open => {
                    const open = wire.decodeChanOpen(f.payload) orelse continue;
                    if (open.kind == .wayland_native) self.chans.append(self.allocator, open.id) catch fail("oom");
                },
                .chan_data => {
                    const id = wire.decodeChanId(f.payload) orelse continue;
                    // Units may split across frames; they are small here,
                    // but reassemble per frame stream anyway.
                    self.unitbuf.appendSlice(self.allocator, f.payload[4..]) catch fail("oom");
                    var pos: usize = 0;
                    while (wlpipe.peelUnit(self.unitbuf.items[pos..]) catch fail("unit")) |p| {
                        pos += p.consumed;
                        if (p.unit.tag != .paste_request or p.unit.payload.len < 1) continue;
                        self.requests += 1;
                        self.send(id, if (p.unit.payload[0] == 1) .primary_data else .clip_data, HOST_TEXT);
                    }
                    const rem = self.unitbuf.items.len - pos;
                    std.mem.copyForwards(u8, self.unitbuf.items[0..rem], self.unitbuf.items[pos..]);
                    self.unitbuf.shrinkRetainingCapacity(rem);
                },
                else => {},
            }
        }
    }

    /// The host clipboard changed: announce it on every app channel.
    fn offerHost(self: *PasteViewer) void {
        for (self.chans.items) |id| self.send(id, .offer_selection, "text/plain;charset=utf-8");
    }
};

const Child = struct { pid: c.pid_t, out_fd: c_int };

fn spawn(wl: []const u8, argv: []const [*:0]const u8) Child {
    var wl_z: [4096:0]u8 = undefined;
    const wz = std.fmt.bufPrintZ(&wl_z, "{s}", .{wl}) catch fail("wl path too long");
    var pfds: [2]c_int = undefined;
    if (c.pipe(&pfds) != 0) fail("pipe");
    var args: [8:null]?[*:0]const u8 = @splat(null);
    for (argv, 0..) |a, i| args[i] = a;
    const pid = c.fork();
    if (pid < 0) fail("fork");
    if (pid == 0) {
        _ = c.dup2(pfds[1], 1);
        _ = c.close(pfds[0]);
        _ = c.close(pfds[1]);
        _ = c.setenv("WAYLAND_DISPLAY", wz.ptr, 1);
        _ = c.unsetenv("DISPLAY");
        _ = c.execv(args[0].?, @ptrCast(&args));
        c._exit(127);
    }
    _ = c.close(pfds[1]);
    const fl = c.fcntl(pfds[0], c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(pfds[0], c.F_SETFL, fl | c.O_NONBLOCK);
    return .{ .pid = pid, .out_fd = pfds[0] };
}

/// Wait for `ch` to exit (pumping `viewer` meanwhile), collecting its
/// stdout. Null = still running at the deadline (it is then killed).
fn finish(allocator: std.mem.Allocator, ch: Child, viewer: ?*PasteViewer, timeout_ms: i64) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    const deadline = nowMs() + timeout_ms;
    var exited = false;
    while (nowMs() < deadline) {
        if (viewer) |v| v.pump();
        var buf: [512]u8 = undefined;
        const n = c.read(ch.out_fd, &buf, buf.len);
        if (n > 0) out.appendSlice(allocator, buf[0..@intCast(n)]) catch fail("oom");
        var st: c_int = 0;
        if (c.waitpid(ch.pid, &st, c.WNOHANG) == ch.pid) {
            exited = true;
            break;
        }
        _ = c.usleep(10_000);
    }
    while (exited) {
        var buf: [512]u8 = undefined;
        const n = c.read(ch.out_fd, &buf, buf.len);
        if (n <= 0) break;
        out.appendSlice(allocator, buf[0..@intCast(n)]) catch fail("oom");
    }
    _ = c.close(ch.out_fd);
    if (!exited) {
        _ = c.kill(ch.pid, c.SIGKILL);
        var st: c_int = 0;
        _ = c.waitpid(ch.pid, &st, 0);
        out.deinit(allocator);
        return null;
    }
    return out.toOwnedSlice(allocator) catch fail("oom");
}

pub fn run(allocator: std.mem.Allocator, sock_path: []const u8) void {
    if (c.access("/usr/bin/wl-paste", c.X_OK) != 0 or c.access("/usr/bin/wl-copy", c.X_OK) != 0) {
        std.debug.print(TAG ++ ": SKIPPED (wl-clipboard not installed)\n", .{});
        return;
    }
    var wl_buf: [4096]u8 = undefined;
    const wl = blk: {
        const r = displaycli.runDisplayCli(allocator, &.{ "create", "--name", "paste1", "--no-xwayland", "--json", "--socket", sock_path });
        defer allocator.free(r.out);
        if (r.code != 0) fail("display create");
        const parsed = std.json.parseFromSlice(CreateReply, allocator, r.out, .{ .ignore_unknown_fields = true }) catch fail("create reply");
        defer parsed.deinit();
        const p = parsed.value.environment.WAYLAND_DISPLAY;
        if (p.len == 0 or p.len > wl_buf.len) fail("no WAYLAND_DISPLAY");
        @memcpy(wl_buf[0..p.len], p);
        break :blk wl_buf[0..p.len];
    };
    defer {
        const d = displaycli.runDisplayCli(allocator, &.{ "destroy", "paste1", "--socket", sock_path });
        allocator.free(d.out);
    }

    // 1. Nobody to ask: the paste completes empty rather than hanging.
    {
        const out = finish(allocator, spawn(wl, &.{ "/usr/bin/wl-paste", "-n" }), null, 10_000) orelse
            fail("wl-paste hung with no viewer attached (the receive fd was never answered)");
        defer allocator.free(out);
        if (out.len != 0) fail("wl-paste printed data nobody provided");
    }
    std.debug.print(TAG ++ ": paste with no viewer completes empty ok\n", .{});

    // 2. A paste-capable viewer is asked, and its answer is the paste.
    var viewer = PasteViewer.attach(allocator, sock_path, "paste1");
    defer viewer.deinit();
    {
        const out = finish(allocator, spawn(wl, &.{ "/usr/bin/wl-paste", "-n" }), &viewer, 10_000) orelse
            fail("wl-paste hung with a paste-capable viewer attached");
        defer allocator.free(out);
        if (viewer.requests == 0) fail("the daemon never sent the viewer a paste_request");
        if (!std.mem.eql(u8, out, HOST_TEXT)) {
            std.debug.print(TAG ++ ": wl-paste printed '{s}'\n", .{out});
            fail("wl-paste did not print the viewer's host clipboard");
        }
    }
    std.debug.print(TAG ++ ": host clipboard pasted into a real wl-paste ok\n", .{});

    // 3. An app's own selection is cancelled when the host clipboard
    // changes: wl-copy --foreground serves until cancelled, then exits.
    {
        const copier = spawn(wl, &.{ "/usr/bin/wl-copy", "--foreground", "APP-OWN-55" });
        const settle = nowMs() + 1_500;
        while (nowMs() < settle) {
            viewer.pump();
            _ = c.usleep(10_000);
        }
        var st: c_int = 0;
        if (c.waitpid(copier.pid, &st, c.WNOHANG) == copier.pid) fail("wl-copy exited before the host clipboard changed");
        viewer.offerHost();
        const out = finish(allocator, copier, &viewer, 10_000) orelse
            fail("wl-copy kept its selection after the host clipboard changed (source never cancelled)");
        allocator.free(out);
        const pasted = finish(allocator, spawn(wl, &.{ "/usr/bin/wl-paste", "-n" }), &viewer, 10_000) orelse
            fail("wl-paste hung after the selection change");
        defer allocator.free(pasted);
        if (!std.mem.eql(u8, pasted, HOST_TEXT)) fail("paste after the host change is not the host's text");
    }
    std.debug.print(TAG ++ ": app selection cancelled on a host clipboard change ok\n", .{});
}
