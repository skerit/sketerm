//! Mux daemon end-to-end smoke (headless, no display needed):
//! daemon thread + real client over a temp socket. Exercises spawn,
//! attach (snapshot), live event stream applied to a client-side
//! Screen, detach/reattach with content intact, resize, list, kill,
//! shutdown. `zig build smoke-mux`.

const std = @import("std");
const c = @import("c.zig").c;
const daemon_mod = @import("mux/daemon.zig");
const client_mod = @import("mux/client.zig");
const wire = @import("mux/wire.zig");
const snapshot = @import("mux/snapshot.zig");
const Screen = @import("grid/screen.zig").Screen;
const Pool = @import("grid/style_pool.zig").Pool;

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("smoke-mux: FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

const MARKER = "mux-smoke-7311";

/// Client-side mirror: snapshot restore + event application.
const Mirror = struct {
    allocator: std.mem.Allocator,
    pool: *Pool,
    screen: ?*Screen = null,

    fn applySnapshot(self: *Mirror, payload: []const u8) !void {
        if (payload.len < 8) return error.Truncated;
        if (self.screen) |s| s.deinit();
        self.screen = null;
        self.pool.deinit();
        self.pool.* = try Pool.init(self.allocator);
        self.screen = try snapshot.restore(self.allocator, self.pool, payload[8..]);
    }

    fn applyEvents(self: *Mirror, payload: []const u8) !void {
        const screen = self.screen orelse return error.NoScreen;
        if (payload.len < 12) return error.Truncated;
        var r = wire.Reader.init(payload[12..]);
        while (!r.atEnd()) {
            var ev = try r.getEvent(self.allocator);
            screen.apply(ev);
            ev.deinit(self.allocator);
        }
    }

    fn screenText(self: *Mirror) ![]u8 {
        return (self.screen orelse return error.NoScreen).extractScreen(self.allocator);
    }
};

fn daemonMain(d: *daemon_mod.Daemon) void {
    d.run() catch |err| {
        std.debug.print("smoke-mux: daemon error: {s}\n", .{@errorName(err)});
    };
}

pub fn main() u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var path_buf: [128]u8 = undefined;
    const sock_path = std.fmt.bufPrint(&path_buf, "/tmp/sketerm-mux-smoke-{d}/mux.sock", .{c.getpid()}) catch unreachable;

    const d = daemon_mod.Daemon.init(allocator, sock_path) catch fail("daemon init");
    // d.deinit() runs after the thread joins, below.

    const th = std.Thread.spawn(.{}, daemonMain, .{d}) catch fail("thread spawn");

    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("connect");

    // hello / welcome.
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("hello send");
    const w = conn.recvExpect(&.{.welcome}) catch fail("welcome");
    w.deinit(allocator);

    // Spawn a session running a shell.
    conn.sendJson(.spawn, .{
        .name = "smoke",
        .argv = [_][]const u8{"/bin/sh"},
        .rows = @as(u16, 10),
        .cols = @as(u16, 60),
    }) catch fail("spawn send");
    (conn.recvExpect(&.{.ok}) catch fail("spawn ok")).deinit(allocator);

    // Attach → snapshot.
    var mirror = Mirror{ .allocator = allocator, .pool = allocator.create(Pool) catch fail("pool") };
    mirror.pool.* = Pool.init(allocator) catch fail("pool init");
    defer {
        if (mirror.screen) |s| s.deinit();
        mirror.pool.deinit();
        allocator.destroy(mirror.pool);
    }

    conn.sendJson(.attach, .{ .name = "smoke" }) catch fail("attach send");
    const snap = conn.recvExpect(&.{.snapshot}) catch fail("attach snapshot");
    mirror.applySnapshot(snap.payload) catch fail("snapshot apply");
    snap.deinit(allocator);

    // Type a marker; watch the event stream until it appears.
    conn.sendFrame(.input, "echo " ++ MARKER ++ "\n") catch fail("input send");
    var deadline: usize = 0;
    var seen = false;
    while (deadline < 200) : (deadline += 1) {
        const f = conn.recvFrame() catch fail("stream read");
        defer f.deinit(allocator);
        if (f.ftype == .events) mirror.applyEvents(f.payload) catch fail("events apply");
        const txt = mirror.screenText() catch fail("extract");
        defer allocator.free(txt);
        // Output line + echoed command = 2 occurrences.
        if (std.mem.count(u8, txt, MARKER) >= 2) {
            seen = true;
            break;
        }
    }
    if (!seen) fail("marker never appeared via event stream");

    // Detach, reattach: snapshot alone must already contain the marker.
    conn.sendFrame(.detach, "") catch fail("detach send");
    (conn.recvExpect(&.{.ok}) catch fail("detach ok")).deinit(allocator);
    conn.sendJson(.attach, .{ .name = "smoke" }) catch fail("reattach send");
    const snap2 = conn.recvExpect(&.{.snapshot}) catch fail("reattach snapshot");
    mirror.applySnapshot(snap2.payload) catch fail("snapshot2 apply");
    snap2.deinit(allocator);
    {
        const txt = mirror.screenText() catch fail("extract2");
        defer allocator.free(txt);
        if (std.mem.count(u8, txt, MARKER) < 2) fail("marker lost across reattach");
    }

    // Resize → fresh snapshot broadcast with new geometry.
    var rsz: [4]u8 = undefined;
    std.mem.writeInt(u16, rsz[0..2], 20, .little);
    std.mem.writeInt(u16, rsz[2..4], 80, .little);
    conn.sendFrame(.resize, &rsz) catch fail("resize send");
    const snap3 = conn.recvExpect(&.{.snapshot}) catch fail("resize snapshot");
    mirror.applySnapshot(snap3.payload) catch fail("snapshot3 apply");
    snap3.deinit(allocator);
    if (mirror.screen.?.rows != 20 or mirror.screen.?.cols != 80) fail("resize geometry");

    // A second client sees the session in LIST.
    var conn2 = client_mod.Conn.connect(allocator, sock_path) catch fail("connect2");
    conn2.sendFrame(.list, "") catch fail("list send");
    const lst = conn2.recvExpect(&.{.welcome}) catch fail("list");
    if (std.mem.indexOf(u8, lst.payload, "\"smoke\"") == null) fail("list missing session");
    lst.deinit(allocator);

    // Kill: attached client gets GONE.
    conn2.sendJson(.kill, .{ .name = "smoke" }) catch fail("kill send");
    (conn2.recvExpect(&.{.ok}) catch fail("kill ok")).deinit(allocator);
    (conn.recvExpect(&.{.gone}) catch fail("gone")).deinit(allocator);

    // Shutdown; daemon thread exits; socket unlinked by deinit.
    conn2.sendFrame(.shutdown, "") catch fail("shutdown send");
    th.join();
    conn.deinit();
    conn2.deinit();
    d.deinit();

    std.debug.print("smoke-mux: PASS\n", .{});
    return 0;
}
