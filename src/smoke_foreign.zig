//! xdg-foreign / xdg-dialog daemon end-to-end smoke (headless):
//! daemon thread + scripted raw-Wayland clients on the session display
//! sockets + a mux viewer running a REAL replica Compositor. Covers
//! what the compositor.zig unit tests cannot: the session-shared
//! handle registry across real connections, the `foreign_parent` pipe
//! unit toward viewers, the idle-brain flush sweep
//! (`Daemon.foreign_flush_pending`), reattach replay of resolved
//! relations, and session scoping of handles. `zig build smoke-foreign`.

const std = @import("std");
const c = @import("c.zig").c;
const daemon_mod = @import("mux/daemon.zig");
const client_mod = @import("mux/client.zig");
const wire = @import("mux/wire.zig");
const wlwire = @import("wlhost/wire.zig");
const wlpipe = @import("wlhost/pipe.zig");
const wlcomp = @import("wlhost/compositor.zig");
const platform = @import("util/platform.zig");

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("smoke-foreign: FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

fn daemonMain(d: *daemon_mod.Daemon) void {
    d.run() catch |err| {
        std.debug.print("smoke-foreign: daemon error: {s}\n", .{@errorName(err)});
    };
}

/// Every socket gets this receive timeout, so any stall in the foreign
/// machinery (most importantly a REGRESSED idle-brain sweep, which
/// turns "importer is told `destroyed`" into "importer waits forever")
/// fails the run instead of hanging it.
const RECV_TIMEOUT = c.struct_timeval{ .tv_sec = 15, .tv_usec = 0 };

/// One scripted Wayland app connection to a session's display socket.
const App = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    buf: std.ArrayList(u8) = .empty,

    /// `ordinal` is the daemon's sequential display counter ("wl-N",
    /// monolith mode) — 1 for the first session spawned, 2 for the
    /// second.
    fn connect(allocator: std.mem.Allocator, sock_path: []const u8, ordinal: usize) App {
        const dir_end = std.mem.lastIndexOfScalar(u8, sock_path, '/').?;
        var disp_buf: [128]u8 = undefined;
        const disp_path = std.fmt.bufPrint(&disp_buf, "{s}/wl-{d}", .{ sock_path[0..dir_end], ordinal }) catch unreachable;
        const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) fail("app socket");
        var addr: c.struct_sockaddr_un = undefined;
        daemon_mod.fillSockaddrUn(&addr, disp_path) catch fail("app sockaddr");
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0)
            fail("app connect (session display socket missing?)");
        _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &RECV_TIMEOUT, @sizeOf(c.struct_timeval));
        return .{ .allocator = allocator, .fd = fd };
    }

    fn deinit(self: *App) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        self.buf.deinit(self.allocator);
    }

    /// Close the socket WITHOUT any destructor requests — the
    /// crashed/vanished exporting client.
    fn vanish(self: *App) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }

    fn send(self: *App, m: []const u8) void {
        if (c.write(self.fd, m.ptr, m.len) != @as(isize, @intCast(m.len))) fail("app write");
    }

    /// Block until (object, opcode) arrives, dropping every event
    /// before it; the event body (up to out.len bytes) is copied out.
    fn awaitEvent(self: *App, object: u32, opcode: u16, out: []u8) []u8 {
        while (true) {
            var pos: usize = 0;
            while (true) {
                const h = (wlwire.parseHeader(self.buf.items[pos..]) catch fail("app event header")) orelse break;
                if (self.buf.items[pos..].len < h.size) break;
                if (h.object == object and h.opcode == opcode) {
                    const body = self.buf.items[pos + wlwire.header_size .. pos + h.size];
                    const n = @min(body.len, out.len);
                    @memcpy(out[0..n], body[0..n]);
                    const rem = self.buf.items.len - (pos + h.size);
                    std.mem.copyForwards(u8, self.buf.items[0..rem], self.buf.items[pos + h.size ..]);
                    self.buf.shrinkRetainingCapacity(rem);
                    return out[0..n];
                }
                pos += h.size;
            }
            if (pos > 0) {
                const rem = self.buf.items.len - pos;
                std.mem.copyForwards(u8, self.buf.items[0..rem], self.buf.items[pos..]);
                self.buf.shrinkRetainingCapacity(rem);
            }
            var chunk: [4096]u8 = undefined;
            const r = c.read(self.fd, &chunk, chunk.len);
            if (r <= 0) fail("app socket read timed out awaiting an event");
            self.buf.appendSlice(self.allocator, chunk[0..@intCast(r)]) catch fail("oom");
        }
    }

    /// Send wl_display.sync(cb) and report whether `destroyed` (event
    /// 0) on `watch` arrived BEFORE the callback's done — the
    /// deterministic "did the import get revoked or not" probe.
    fn destroyedBeforeSync(self: *App, watch: u32, cb: u32) bool {
        var mbuf: [16]u8 = undefined;
        var b = wlwire.Builder.init(&mbuf, 1, 0); // wl_display.sync
        b.putNewId(cb);
        self.send(b.finish() catch unreachable);
        while (true) {
            var pos: usize = 0;
            while (true) {
                const h = (wlwire.parseHeader(self.buf.items[pos..]) catch fail("app sync header")) orelse break;
                if (self.buf.items[pos..].len < h.size) break;
                if (h.object == watch and h.opcode == 0) return true;
                if (h.object == cb and h.opcode == 0) return false; // wl_callback.done
                pos += h.size;
            }
            if (pos > 0) {
                const rem = self.buf.items.len - pos;
                std.mem.copyForwards(u8, self.buf.items[0..rem], self.buf.items[pos..]);
                self.buf.shrinkRetainingCapacity(rem);
            }
            var chunk: [4096]u8 = undefined;
            const r = c.read(self.fd, &chunk, chunk.len);
            if (r <= 0) fail("app socket read timed out awaiting sync");
            self.buf.appendSlice(self.allocator, chunk[0..@intCast(r)]) catch fail("oom");
        }
    }
};

fn bindGlobal(app: *App, name: u32, iface: []const u8, ver: u32, id: u32) void {
    var mbuf: [128]u8 = undefined;
    var b = wlwire.Builder.init(&mbuf, 2, 0); // wl_registry.bind
    b.putUint(name);
    b.putString(iface);
    b.putUint(ver);
    b.putNewId(id);
    app.send(b.finish() catch unreachable);
}

/// get_registry + wl_compositor(3) + xdg_wm_base(4) binds, then one
/// mapped-role toplevel: wl_surface `sid`, xdg_surface `xid`,
/// xdg_toplevel `tid`.
fn setupBase(app: *App, sid: u32, xid: u32, tid: u32) void {
    var mbuf: [64]u8 = undefined;
    var b = wlwire.Builder.init(&mbuf, 1, 1); // wl_display.get_registry(2)
    b.putNewId(2);
    app.send(b.finish() catch unreachable);
    bindGlobal(app, 1, "wl_compositor", 4, 3);
    bindGlobal(app, 5, "xdg_wm_base", 1, 4);
    addToplevel(app, sid, xid, tid);
}

fn addToplevel(app: *App, sid: u32, xid: u32, tid: u32) void {
    var mbuf: [64]u8 = undefined;
    var b = wlwire.Builder.init(&mbuf, 3, 0); // wl_compositor.create_surface
    b.putNewId(sid);
    app.send(b.finish() catch unreachable);
    b = wlwire.Builder.init(&mbuf, 4, 2); // xdg_wm_base.get_xdg_surface
    b.putNewId(xid);
    b.putObject(sid);
    app.send(b.finish() catch unreachable);
    b = wlwire.Builder.init(&mbuf, xid, 1); // xdg_surface.get_toplevel
    b.putNewId(tid);
    app.send(b.finish() catch unreachable);
}

/// zxdg_exporter_v2.export_toplevel + wait for the handle event.
/// Returns the handle and proves it is the documented capability
/// format: 16 bytes of entropy as 32 lowercase hex chars.
fn exportToplevel(app: *App, exporter: u32, exported: u32, sid: u32, out: *[wlcomp.foreign_handle_len]u8) []u8 {
    var mbuf: [32]u8 = undefined;
    var b = wlwire.Builder.init(&mbuf, exporter, 1); // export_toplevel
    b.putNewId(exported);
    b.putObject(sid);
    app.send(b.finish() catch unreachable);
    var body: [64]u8 = undefined;
    const got = app.awaitEvent(exported, 0, &body); // handle(string)
    if (got.len < 4) fail("handle event body truncated");
    const slen = std.mem.readInt(u32, got[0..4], .little);
    if (slen != wlcomp.foreign_handle_len + 1) fail("foreign handle is not 32 chars");
    const handle = got[4 .. 4 + wlcomp.foreign_handle_len];
    for (handle) |ch| {
        const hex = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
        if (!hex) fail("foreign handle is not lowercase hex — not an entropy capability");
    }
    @memcpy(out, handle);
    return out;
}

fn importToplevel(app: *App, importer: u32, imported: u32, handle: []const u8) void {
    var mbuf: [64]u8 = undefined;
    var b = wlwire.Builder.init(&mbuf, importer, 1); // import_toplevel
    b.putNewId(imported);
    b.putString(handle);
    app.send(b.finish() catch unreachable);
}

fn setParentOf(app: *App, imported: u32, child_sid: u32) void {
    var mbuf: [16]u8 = undefined;
    var b = wlwire.Builder.init(&mbuf, imported, 1); // set_parent_of
    b.putObject(child_sid);
    app.send(b.finish() catch unreachable);
}

fn simpleReq(app: *App, object: u32, opcode: u16) void {
    var mbuf: [8]u8 = undefined;
    var b = wlwire.Builder.init(&mbuf, object, opcode);
    app.send(b.finish() catch unreachable);
}

/// Viewer-side observer for ONE app channel: a REAL replica Compositor
/// fed the exact stream the GUI would feed wlapp, with the same view
/// callbacks wlapp registers — so assertions run against what the GUI
/// parents windows from, not against a re-reading of the wire.
///
/// Latching (`cb_*`) mirrors wlapp's `foreign_parents` map: within one
/// daemon read batch the `foreign_parent` unit is emitted DURING the
/// brain feed while that batch's wl_msg relays are queued after it, so
/// a live replica can legitimately hear the relation before it has
/// re-parsed the child's create_surface. wlapp therefore latches the
/// callback and applies it in winFor; asserting on the latch is
/// asserting the real consumer contract. The replica SURFACE fields
/// are ordering-safe only on the reattach path (state_sync restores
/// surfaces before the replayed units) and are asserted there.
const Watch = struct {
    allocator: std.mem.Allocator,
    chan: u32,
    replica: wlcomp.Compositor,
    /// Latched from view.toplevel_foreign_parent (wlapp's contract).
    cb_sid: u32 = 0,
    cb_conn: u32 = 0,
    cb_parent: u32 = 0,
    cb_count: usize = 0,
    /// Raw foreign_parent pipe unit (the daemon's own statement).
    fp_sid: u32 = 0,
    fp_conn: u32 = 0,
    fp_parent: u32 = 0,
    fp_count: usize = 0,

    fn init(allocator: std.mem.Allocator, chan: u32) Watch {
        var replica = wlcomp.Compositor.init(allocator, .{}) catch fail("replica init");
        replica.lenient = true;
        replica.conn_id = chan;
        return .{ .allocator = allocator, .chan = chan, .replica = replica };
    }

    /// Register the view callbacks. Separate from init because the
    /// ctx pointer must be the struct's FINAL address.
    fn bind(self: *Watch) void {
        self.replica.view = .{ .ctx = self, .toplevel_foreign_parent = onForeignParent };
    }

    fn onForeignParent(ctx: ?*anyopaque, surface: u32, conn: u32, parent: u32) void {
        const self: *Watch = @ptrCast(@alignCast(ctx.?));
        self.cb_sid = surface;
        self.cb_conn = conn;
        self.cb_parent = parent;
        self.cb_count += 1;
    }

    fn deinit(self: *Watch) void {
        self.replica.deinit();
    }

    /// One chan_data frame payload ([chan_id u32][units...]).
    fn feedFrame(self: *Watch, payload: []const u8) void {
        if (payload.len < 4) return;
        if ((wire.decodeChanId(payload) orelse return) != self.chan) return;
        const units = payload[4..];
        var pos: usize = 0;
        while ((wlpipe.peelUnit(units[pos..]) catch fail("bad unit")) != null) {
            const p = (wlpipe.peelUnit(units[pos..]) catch unreachable).?;
            if (p.unit.tag == .foreign_parent and p.unit.payload.len >= 12) {
                self.fp_sid = std.mem.readInt(u32, p.unit.payload[0..4], .little);
                self.fp_conn = std.mem.readInt(u32, p.unit.payload[4..8], .little);
                self.fp_parent = std.mem.readInt(u32, p.unit.payload[8..12], .little);
                self.fp_count += 1;
            }
            pos += p.consumed;
        }
        // Replicas swallow their own queued output (nobody drains it
        // here); clear it so a long run cannot look like a leak.
        self.replica.feed(units) catch fail("replica feed");
        self.replica.clearOut();
    }

    fn surf(self: *Watch, sid: u32) ?wlcomp.Surface {
        return self.replica.surfaces.get(sid);
    }
};

/// pumpUntil context for "the latched relation reached (conn, parent)
/// via at least `min_count` callbacks".
const FpWant = struct { min_count: usize, conn: u32, parent: u32 };

fn condFp(want: FpWant, w: *Watch) bool {
    return w.cb_count >= want.min_count and w.cb_sid == 16 and
        w.cb_conn == want.conn and w.cb_parent == want.parent;
}

/// Drain viewer frames (feeding `watch`) until chan_open, whose id is
/// returned.
fn awaitChanOpen(allocator: std.mem.Allocator, conn: *client_mod.Conn, watch: ?*Watch) u32 {
    var rounds: usize = 0;
    while (rounds < 400) : (rounds += 1) {
        const f = conn.recvFrame() catch fail("viewer read awaiting chan_open");
        defer f.deinit(allocator);
        switch (f.ftype) {
            .chan_open => {
                const open = wire.decodeChanOpen(f.payload) orelse fail("bad chan_open");
                if (open.kind != .wayland_native) continue;
                return open.id;
            },
            .chan_data => if (watch) |w| w.feedFrame(f.payload),
            else => {},
        }
    }
    fail("chan_open never arrived");
}

/// Drain viewer frames into `watch` until `cond` holds.
fn pumpUntil(
    allocator: std.mem.Allocator,
    conn: *client_mod.Conn,
    watch: *Watch,
    ctx: anytype,
    comptime cond: fn (@TypeOf(ctx), *Watch) bool,
    comptime what: []const u8,
) void {
    var rounds: usize = 0;
    while (rounds < 600) : (rounds += 1) {
        if (cond(ctx, watch)) return;
        const f = conn.recvFrame() catch |err| {
            var avail: c_int = -1;
            _ = c.ioctl(conn.fd, c.FIONREAD, &avail);
            std.debug.print("smoke-foreign: viewer recv error: {s} rounds={d} rbuf={d} fionread={d} errno={d}\n", .{
                @errorName(err), rounds, conn.rbuf.items.len, avail, @intFromEnum(std.posix.errno(@as(isize, -1))),
            });
            fail("viewer read: " ++ what);
        };
        defer f.deinit(allocator);
        if (f.ftype == .chan_data) watch.feedFrame(f.payload);
    }
    fail(what);
}

fn spawnSession(allocator: std.mem.Allocator, conn: *client_mod.Conn, name: []const u8) void {
    conn.sendJson(.spawn, .{
        .name = name,
        .argv = [_][]const u8{ "/bin/sleep", "300" },
        .rows = @as(u16, 10),
        .cols = @as(u16, 40),
    }) catch fail("spawn send");
    (conn.recvExpect(&.{.ok}) catch fail("spawn ok")).deinit(allocator);
}

pub fn main() u8 {
    // safety=true forces allocation tracking even in ReleaseFast so
    // the leak check below actually runs (same rationale as smoke-mux:
    // the daemon and both replicas are fully deinit'd, so a clean run
    // leaves ZERO outstanding allocations).
    var gpa_state: std.heap.DebugAllocator(.{ .safety = true }) = .{};
    defer if (gpa_state.deinit() == .leak) {
        std.debug.print("smoke-foreign: FAIL — leaked memory (see GPA report above)\n", .{});
        std.process.exit(1);
    };
    const allocator = gpa_state.allocator();

    // On a capture-capable macOS build the daemon would auto-enable
    // winstream for app-hosting sessions, diverting the Wayland pipe.
    _ = c.setenv("SKETERM_WINSTREAM", "off", 1);

    var path_buf: [128]u8 = undefined;
    const sock_path = std.fmt.bufPrint(&path_buf, "/tmp/sketerm-foreign-smoke-{d}/mux.sock", .{c.getpid()}) catch unreachable;

    const d = daemon_mod.Daemon.init(allocator, sock_path) catch fail("daemon init");
    const th = std.Thread.spawn(.{}, daemonMain, .{d}) catch fail("thread spawn");

    // Viewer V1: attached BEFORE any app connects, so chan_open frames
    // arrive live. A plain current-proto hello negotiates the full
    // native-state ceiling (xdg-foreign needs >= 10, xdg-dialog 11).
    var v1 = client_mod.Conn.connect(allocator, sock_path) catch fail("v1 connect");
    _ = c.setsockopt(v1.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &RECV_TIMEOUT, @sizeOf(c.struct_timeval));
    v1.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("v1 hello");
    (v1.recvExpect(&.{.welcome}) catch fail("v1 welcome")).deinit(allocator);
    spawnSession(allocator, &v1, "one");
    v1.sendJson(.attach, .{ .name = "one" }) catch fail("v1 attach");
    (v1.recvExpect(&.{.snapshot}) catch fail("v1 snapshot")).deinit(allocator);

    // ── Exporter A: one toplevel, exported ──────────────────────
    var a = App.connect(allocator, sock_path, 1);
    defer a.deinit();
    const chan_a = awaitChanOpen(allocator, &v1, null);
    setupBase(&a, 6, 7, 8);
    bindGlobal(&a, 25, "zxdg_exporter_v2", 1, 5);
    var h1_buf: [wlcomp.foreign_handle_len]u8 = undefined;
    const h1 = exportToplevel(&a, 5, 9, 6, &h1_buf);

    // ── Importer B: a DIFFERENT connection parents onto A ───────
    var b = App.connect(allocator, sock_path, 1);
    defer b.deinit();
    var watch = Watch.init(allocator, 0);
    defer watch.deinit();
    watch.bind();
    const chan_b = awaitChanOpen(allocator, &v1, null);
    if (chan_b == chan_a) fail("second app connection reused a channel id");
    watch.chan = chan_b;
    watch.replica.conn_id = chan_b;
    setupBase(&b, 16, 17, 18);
    bindGlobal(&b, 26, "zxdg_importer_v2", 1, 5);
    bindGlobal(&b, 27, "xdg_wm_dialog_v1", 1, 10);
    importToplevel(&b, 5, 19, h1);
    setParentOf(&b, 19, 16);
    { // xdg_wm_dialog_v1.get_xdg_dialog(11, toplevel 18) + set_modal
        var mbuf: [16]u8 = undefined;
        var bb = wlwire.Builder.init(&mbuf, 10, 1);
        bb.putNewId(11);
        bb.putObject(18);
        b.send(bb.finish() catch unreachable);
        simpleReq(&b, 11, 1); // set_modal
    }

    // The daemon must resolve the import cross-connection and ship the
    // SESSION-WIDE identity — (exporting channel id, exporting surface
    // id) — as a foreign_parent unit, which the replica hands its view
    // exactly as wlapp latches it. tl_parent staying 0 is the proof
    // this relation came from the foreign path, not from an
    // xdg_toplevel.set_parent the compositor happened to honor (the
    // historical apparently-wired case).
    pumpUntil(allocator, &v1, &watch, FpWant{ .min_count = 1, .conn = chan_a, .parent = 6 }, condFp, "cross-connection foreign_parent never reached the viewer");
    if (watch.fp_sid != 16) fail("foreign_parent unit names the wrong child surface");
    if (watch.fp_conn != chan_a) fail("foreign_parent unit names the wrong exporting channel");
    if (watch.fp_parent != 6) fail("foreign_parent unit names the wrong parent surface");
    const CondModal = struct {
        fn f(_: void, w: *Watch) bool {
            const s = w.surf(16) orelse return false;
            return s.modal;
        }
    };
    pumpUntil(allocator, &v1, &watch, {}, CondModal.f, "set_modal never reached the replica");
    if (watch.surf(16).?.tl_parent != 0) fail("relation leaked into tl_parent — set_parent path, not foreign");
    std.debug.print("smoke-foreign: cross-connection import resolved, unit + latched view agree, modal set\n", .{});

    // ── Reattach replay: daemon state, not a transient relay ────
    // A FRESH viewer's replica must rebuild the relation and the
    // modality from the attach replay alone (state_sync v11 + the
    // daemon's retained Native.foreign_parents), proving the daemon
    // holds this durably rather than having merely passed bytes along.
    {
        var v2 = client_mod.Conn.connect(allocator, sock_path) catch fail("v2 connect");
        defer v2.deinit();
        _ = c.setsockopt(v2.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &RECV_TIMEOUT, @sizeOf(c.struct_timeval));
        v2.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("v2 hello");
        (v2.recvExpect(&.{.welcome}) catch fail("v2 welcome")).deinit(allocator);
        v2.sendJson(.attach, .{ .name = "one" }) catch fail("v2 attach");
        (v2.recvExpect(&.{.snapshot}) catch fail("v2 snapshot")).deinit(allocator);
        var watch2 = Watch.init(allocator, chan_b);
        defer watch2.deinit();
        watch2.bind();
        const Cond = struct {
            fn f(_: void, w: *Watch) bool {
                const s = w.surf(16) orelse return false;
                return s.foreign_parent != 0 and s.modal;
            }
        };
        pumpUntil(allocator, &v2, &watch2, {}, Cond.f, "reattach replay never rebuilt the foreign relation");
        const s = watch2.surf(16).?;
        if (s.foreign_parent != 6 or s.foreign_parent_conn != chan_a or !s.foreign_parent_remote)
            fail("replayed foreign relation wrong");
        if (!s.modal) fail("replayed modality wrong");
        v2.sendFrame(.detach, "") catch fail("v2 detach");
        (v2.recvExpect(&.{.ok}) catch fail("v2 detach ok")).deinit(allocator);
    }
    std.debug.print("smoke-foreign: reattach replay rebuilt relation + modality in a fresh replica\n", .{});

    // ── Revocation 1: the exported surface dies ─────────────────
    // B is IDLE (sends nothing): its `destroyed` sits queued on a
    // brain nobody feeds unless the daemon's per-tick sweep
    // (foreign_flush_pending → flushPendingBrains) flushes it. The
    // 15s receive timeout turns a regressed sweep into a failure.
    const clear1_count = watch.cb_count + 1;
    simpleReq(&a, 8, 0); // xdg_toplevel.destroy
    simpleReq(&a, 7, 0); // xdg_surface.destroy
    simpleReq(&a, 6, 0); // wl_surface.destroy
    {
        var body: [8]u8 = undefined;
        _ = b.awaitEvent(19, 0, &body); // zxdg_imported_v2.destroyed
    }
    pumpUntil(allocator, &v1, &watch, FpWant{ .min_count = clear1_count, .conn = 0, .parent = 0 }, condFp, "surface death never cleared the importer's relation");
    if (watch.fp_sid != 16 or watch.fp_conn != 0 or watch.fp_parent != 0)
        fail("clearing foreign_parent unit wrong");
    std.debug.print("smoke-foreign: exported surface death revoked the idle importer (sweep flushed)\n", .{});

    // ── Revocation 2: the exporting CLIENT vanishes ─────────────
    // A second exporter connection, a fresh handle, a fresh import —
    // then the exporter's socket just closes, no destructors. The
    // idle importer must still be told, again via the sweep.
    {
        var a2 = App.connect(allocator, sock_path, 1);
        const chan_a2 = awaitChanOpen(allocator, &v1, &watch);
        setupBase(&a2, 6, 7, 8);
        bindGlobal(&a2, 25, "zxdg_exporter_v2", 1, 5);
        var h2_buf: [wlcomp.foreign_handle_len]u8 = undefined;
        const h2 = exportToplevel(&a2, 5, 9, 6, &h2_buf);
        const set2_count = watch.cb_count + 1;
        importToplevel(&b, 5, 20, h2);
        setParentOf(&b, 20, 16);
        pumpUntil(allocator, &v1, &watch, FpWant{ .min_count = set2_count, .conn = chan_a2, .parent = 6 }, condFp, "second cross-connection relation never resolved");
        const clear2_count = watch.cb_count + 1;
        a2.vanish();
        a2.deinit();
        var body: [8]u8 = undefined;
        _ = b.awaitEvent(20, 0, &body); // destroyed, no destructor ran
        pumpUntil(allocator, &v1, &watch, FpWant{ .min_count = clear2_count, .conn = 0, .parent = 0 }, condFp, "vanished exporter never cleared the relation");
    }
    std.debug.print("smoke-foreign: exporter vanishing (no destructors) revoked the idle importer\n", .{});

    // ── Modality can be unset ───────────────────────────────────
    simpleReq(&b, 11, 2); // xdg_dialog_v1.unset_modal
    const CondUnmodal = struct {
        fn f(_: void, w: *Watch) bool {
            const s = w.surf(16) orelse return false;
            return !s.modal;
        }
    };
    pumpUntil(allocator, &v1, &watch, {}, CondUnmodal.f, "unset_modal never reached the replica");

    // ── Handles are SESSION-scoped capabilities ─────────────────
    // B (session "one") exports a live toplevel; a client of session
    // "two" importing that handle must be answered `destroyed`
    // immediately, while its OWN session's handle resolves fine (the
    // control that proves "two" isn't just refusing everything).
    {
        var ctl = client_mod.Conn.connect(allocator, sock_path) catch fail("ctl connect");
        defer ctl.deinit();
        _ = c.setsockopt(ctl.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &RECV_TIMEOUT, @sizeOf(c.struct_timeval));
        ctl.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("ctl hello");
        (ctl.recvExpect(&.{.welcome}) catch fail("ctl welcome")).deinit(allocator);
        spawnSession(allocator, &ctl, "two");

        bindGlobal(&b, 25, "zxdg_exporter_v2", 1, 12);
        var h3_buf: [wlcomp.foreign_handle_len]u8 = undefined;
        const h3 = exportToplevel(&b, 12, 13, 16, &h3_buf);

        var cc = App.connect(allocator, sock_path, 2);
        defer cc.deinit();
        setupBase(&cc, 6, 7, 8);
        addToplevel(&cc, 30, 31, 32);
        bindGlobal(&cc, 26, "zxdg_importer_v2", 1, 5);
        bindGlobal(&cc, 25, "zxdg_exporter_v2", 1, 12);
        importToplevel(&cc, 5, 21, h3);
        if (!cc.destroyedBeforeSync(21, 40))
            fail("a session-one handle resolved in session two — handles leak across sessions");
        var h4_buf: [wlcomp.foreign_handle_len]u8 = undefined;
        const h4 = exportToplevel(&cc, 12, 13, 6, &h4_buf);
        importToplevel(&cc, 5, 22, h4);
        setParentOf(&cc, 22, 30);
        if (cc.destroyedBeforeSync(22, 41))
            fail("session two revoked its own live handle — the scope test proves nothing");

        ctl.sendJson(.kill, .{ .name = "two" }) catch fail("kill two");
        (ctl.recvExpect(&.{.ok}) catch fail("kill two ok")).deinit(allocator);
    }
    std.debug.print("smoke-foreign: handles are session-scoped (foreign import refused, own import live)\n", .{});

    // ── Teardown + leak check ───────────────────────────────────
    b.vanish();
    {
        var ctl = client_mod.Conn.connect(allocator, sock_path) catch fail("ctl2 connect");
        _ = c.setsockopt(ctl.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &RECV_TIMEOUT, @sizeOf(c.struct_timeval));
        ctl.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("ctl2 hello");
        (ctl.recvExpect(&.{.welcome}) catch fail("ctl2 welcome")).deinit(allocator);
        ctl.sendJson(.kill, .{ .name = "one" }) catch fail("kill one");
        (ctl.recvExpect(&.{.ok}) catch fail("kill one ok")).deinit(allocator);
        // V1 was attached: the kill must surface as GONE there.
        var rounds: usize = 0;
        var gone = false;
        while (!gone and rounds < 400) : (rounds += 1) {
            const f = v1.recvFrame() catch fail("v1 read awaiting gone");
            gone = f.ftype == .gone;
            f.deinit(allocator);
        }
        if (!gone) fail("kill never surfaced as GONE on the attached viewer");
        ctl.sendFrame(.shutdown, "") catch fail("shutdown send");
        th.join();
        ctl.deinit();
    }
    v1.deinit();
    d.deinit();

    std.debug.print("smoke-foreign: PASS\n", .{});
    return 0;
}
