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
const wlwire = @import("wlhost/wire.zig");
const wlpipe = @import("wlhost/pipe.zig");
const snapshot = @import("mux/snapshot.zig");
const Screen = @import("grid/screen.zig").Screen;
const Pool = @import("grid/style_pool.zig").Pool;

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("smoke-mux: FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

const MARKER = "mux-smoke-7311";

/// 2x2 solid-red RGBA file for the t=f image stage.
fn writeRedRgba(path: []const u8) !void {
    var z_buf: [4096]u8 = undefined;
    const p = try @import("util/pathz.zig").pathZ(&z_buf, path);
    const fp = c.fopen(p, "wb") orelse return error.OpenFailed;
    defer _ = c.fclose(fp);
    const px = [_]u8{ 0xff, 0, 0, 0xff } ** 4;
    if (c.fwrite(&px, 1, px.len, fp) != px.len) return error.WriteFailed;
}

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

/// Native app pipe: a fake Wayland app drives the daemon's display
/// socket directly (registry binds, shm pool over SCM_RIGHTS,
/// buffer, attach+commit) and the attached client must receive the
/// pipe-unit stream: every message relayed, pool mirror announced,
/// committed pixels replicated. Then one event flows back down.
fn nativePipeStage(allocator: std.mem.Allocator, conn: *client_mod.Conn, sock_path: []const u8) void {
    // Hang guard: any stall in the pipe machinery fails the stage.
    const tv = c.struct_timeval{ .tv_sec = 15, .tv_usec = 0 };
    _ = c.setsockopt(conn.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
    const dir_end = std.mem.lastIndexOfScalar(u8, sock_path, '/').?;
    var disp_buf: [128]u8 = undefined;
    // First session spawned ever → wl-1.
    const disp_path = std.fmt.bufPrint(&disp_buf, "{s}/wl-1", .{sock_path[0..dir_end]}) catch unreachable;

    // The shm "pool": a regular temp file works like a memfd here.
    var pool_bytes: [64]u8 = undefined;
    for (&pool_bytes, 0..) |*b, i| b.* = @intCast(i);
    var tmp_buf: [128]u8 = undefined;
    const tmp_path = std.fmt.bufPrintZ(&tmp_buf, "/tmp/sketerm-mux-smoke-{d}-pool", .{c.getpid()}) catch unreachable;
    const pool_fd = c.open(tmp_path.ptr, c.O_RDWR | c.O_CREAT | c.O_TRUNC, @as(c.mode_t, 0o600));
    if (pool_fd < 0) fail("pool file open");
    _ = c.unlink(tmp_path.ptr);
    if (c.write(pool_fd, &pool_bytes, pool_bytes.len) != pool_bytes.len) fail("pool file write");

    // Connect to the session's display socket like a Wayland app.
    const app_fd = @import("util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (app_fd < 0) fail("app socket");
    var addr: c.struct_sockaddr_un = undefined;
    daemon_mod.fillSockaddrUn(&addr, disp_path) catch fail("app sockaddr");
    if (c.connect(app_fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) fail("app connect (native display socket missing?)");
    defer _ = c.close(app_fd);

    // The client request stream. create_pool's fd rides SCM_RIGHTS
    // attached to its own bytes.
    var mbuf: [256]u8 = undefined;
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    const msgs = [_][]const u8{
        blk: { // wl_display.get_registry(id=2)
            var b = wlwire.Builder.init(&mbuf, 1, 1);
            b.putNewId(2);
            break :blk b.finish() catch unreachable;
        },
        blk: { // wl_registry.bind(1, "wl_shm", 1, id=3)
            var b = wlwire.Builder.init(mbuf[32..], 2, 0);
            b.putUint(1);
            b.putString("wl_shm");
            b.putUint(1);
            b.putNewId(3);
            break :blk b.finish() catch unreachable;
        },
        blk: { // wl_registry.bind(2, "wl_compositor", 6, id=6)
            var b = wlwire.Builder.init(mbuf[96..], 2, 0);
            b.putUint(2);
            b.putString("wl_compositor");
            b.putUint(6);
            b.putNewId(6);
            break :blk b.finish() catch unreachable;
        },
    };
    for (msgs) |m| stream.appendSlice(allocator, m) catch fail("oom");
    if (c.write(app_fd, stream.items.ptr, stream.items.len) != @as(isize, @intCast(stream.items.len))) fail("app write 1");
    var expected_msgs: usize = msgs.len;

    { // wl_shm.create_pool(id=4, fd, 64) — fd via cmsg
        var b = wlwire.Builder.init(&mbuf, 3, 0);
        b.putNewId(4);
        b.putInt(64);
        const m = b.finish() catch unreachable;
        sendWithFd(app_fd, m, pool_fd) catch fail("create_pool sendmsg");
        _ = c.close(pool_fd);
        expected_msgs += 1;
    }

    stream.clearRetainingCapacity();
    const msgs2 = [_][]const u8{
        blk: { // wl_shm_pool.create_buffer(id=5, 0, 4x4, stride 16, fmt 1)
            var b = wlwire.Builder.init(&mbuf, 4, 0);
            b.putNewId(5);
            b.putInt(0);
            b.putInt(4);
            b.putInt(4);
            b.putInt(16);
            b.putUint(1);
            break :blk b.finish() catch unreachable;
        },
        blk: { // wl_compositor.create_surface(id=7)
            var b = wlwire.Builder.init(mbuf[64..], 6, 0);
            b.putNewId(7);
            break :blk b.finish() catch unreachable;
        },
        blk: { // wl_surface.attach(buffer 5, 0, 0)
            var b = wlwire.Builder.init(mbuf[96..], 7, 1);
            b.putObject(5);
            b.putInt(0);
            b.putInt(0);
            break :blk b.finish() catch unreachable;
        },
        blk: { // wl_surface.commit()
            var b = wlwire.Builder.init(mbuf[160..], 7, 6);
            break :blk b.finish() catch unreachable;
        },
    };
    for (msgs2) |m| stream.appendSlice(allocator, m) catch fail("oom");
    if (c.write(app_fd, stream.items.ptr, stream.items.len) != @as(isize, @intCast(stream.items.len))) fail("app write 2");
    expected_msgs += msgs2.len;

    // Collect the unit stream from chan_open/chan_data frames.
    var chan_id: u32 = 0;
    var units_raw: std.ArrayList(u8) = .empty;
    defer units_raw.deinit(allocator);
    var got_commit = false;
    var rounds: usize = 0;
    while (!got_commit and rounds < 400) : (rounds += 1) {
        const f = conn.recvFrame() catch fail("native stream read");
        defer f.deinit(allocator);
        switch (f.ftype) {
            .chan_open => {
                const open = wire.decodeChanOpen(f.payload) orelse fail("bad chan_open");
                if (open.kind != .wayland_native) fail("channel kind not wayland_native");
                chan_id = open.id;
            },
            .chan_data => {
                if (chan_id == 0) fail("chan_data before chan_open");
                if ((wire.decodeChanId(f.payload) orelse 0) != chan_id) fail("chan_data id");
                units_raw.appendSlice(allocator, f.payload[4..]) catch fail("oom");
                // A commit message at the tail of the unit stream =
                // everything we sent has been processed.
                got_commit = std.mem.indexOf(u8, units_raw.items, &commitNeedle()) != null;
            },
            else => {},
        }
    }
    if (!got_commit) fail("native pipe: commit never relayed");

    // Walk the units: count relayed messages, find pool side-band.
    var n_msgs: usize = 0;
    var pool_meta_ok = false;
    var update_bytes: std.ArrayList(u8) = .empty;
    defer update_bytes.deinit(allocator);
    var pos: usize = 0;
    while (true) {
        const p = (wlpipe.peelUnit(units_raw.items[pos..]) catch fail("bad unit")) orelse break;
        switch (p.unit.tag) {
            .wl_msg => n_msgs += 1,
            .pool_create => {
                const meta = wlpipe.decodePoolMeta(p.unit.payload) orelse fail("pool meta");
                if (meta.pool == 4 and meta.size == 64) pool_meta_ok = true;
            },
            .pool_update => {
                const upd = wlpipe.decodePoolUpdate(p.unit.payload) orelse fail("pool update");
                if (upd.pool != 4) fail("pool update id");
                if (upd.offset != update_bytes.items.len) fail("pool update offset");
                update_bytes.appendSlice(allocator, upd.bytes) catch fail("oom");
            },
            else => {},
        }
        pos += p.consumed;
    }
    if (n_msgs != expected_msgs) fail("native pipe: relayed message count wrong");
    if (!pool_meta_ok) fail("native pipe: pool_create side-band missing");
    if (!std.mem.eql(u8, update_bytes.items, &pool_bytes)) fail("native pipe: committed pixels wrong");

    // Clipboard, daemon-level. PASTE: the GUI announces an offer,
    // the app receive()s with a pipe fd the daemon must hold until
    // the GUI's clip_data arrives. COPY: the GUI sends clip_send,
    // the daemon pipes a wl_data_source.send to the app, and the
    // app's bytes come back up as a clip_data unit.
    {
        // App binds the data-device manager + a device.
        var b = wlwire.Builder.init(&mbuf, 2, 0); // registry.bind
        b.putUint(9);
        b.putString("wl_data_device_manager");
        b.putUint(1);
        b.putNewId(20);
        var m = b.finish() catch unreachable;
        if (c.write(app_fd, m.ptr, m.len) != @as(isize, @intCast(m.len))) fail("clip bind write");
        b = wlwire.Builder.init(&mbuf, 20, 1); // get_data_device(21, seat 0)
        b.putNewId(21);
        b.putObject(0);
        m = b.finish() catch unreachable;
        if (c.write(app_fd, m.ptr, m.len) != @as(isize, @intCast(m.len))) fail("clip dev write");

        // Wait until the daemon relayed get_data_device — only then
        // does its tracker know object 21 (mirrors the real flow,
        // where the GUI learns ids from relayed messages).
        {
            var seen_dev = false;
            var dl: usize = 0;
            while (!seen_dev and dl < 200) : (dl += 1) {
                const f = conn.recvFrame() catch fail("dev relay read");
                defer f.deinit(allocator);
                if (f.ftype != .chan_data) continue;
                var raw: std.ArrayList(u8) = .empty;
                defer raw.deinit(allocator);
                raw.appendSlice(allocator, f.payload[4..]) catch fail("oom");
                var upos: usize = 0;
                while ((wlpipe.peelUnit(raw.items[upos..]) catch fail("dev unit")) != null) {
                    const p = (wlpipe.peelUnit(raw.items[upos..]) catch unreachable).?;
                    if (p.unit.tag == .wl_msg) {
                        const h = (wlwire.parseHeader(p.unit.payload) catch fail("dev hdr")) orelse fail("dev hdr");
                        if (h.object == 20 and h.opcode == 1) seen_dev = true;
                    }
                    upos += p.consumed;
                }
            }
            if (!seen_dev) fail("get_data_device never relayed");
        }

        // GUI announces an offer (server-created id) + selection.
        var ub: std.ArrayList(u8) = .empty;
        defer ub.deinit(allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, chan_id, .little);
        ub.appendSlice(allocator, &idb) catch fail("oom");
        b = wlwire.Builder.init(&mbuf, 21, 0); // data_offer(new_id)
        b.putNewId(0xff000001);
        wlpipe.appendUnit(&ub, allocator, .wl_msg, b.finish() catch unreachable) catch fail("oom");
        conn.sendFrame(.chan_data, ub.items) catch fail("clip offer send");

        // App consumes the event, then pastes: receive(mime, fd).
        var evb: [64]u8 = undefined;
        const evn = c.read(app_fd, &evb, 12); // data_offer event = 8 hdr + 4
        if (evn != 12) fail("data_offer event not delivered");
        var pfds: [2]c_int = undefined;
        if (c.pipe(&pfds) != 0) fail("paste pipe");
        b = wlwire.Builder.init(&mbuf, 0xff000001, 1); // receive
        b.putString("text/plain;charset=utf-8");
        sendWithFd(app_fd, b.finish() catch unreachable, pfds[1]) catch fail("receive sendmsg");
        _ = c.close(pfds[1]);

        // GUI answers with paste bytes; the app must read them.
        var deadline2: usize = 0;
        var got_receive = false;
        while (!got_receive and deadline2 < 200) : (deadline2 += 1) {
            const f = conn.recvFrame() catch fail("clip stream read");
            defer f.deinit(allocator);
            if (f.ftype != .chan_data) continue;
            units_raw.clearRetainingCapacity();
            units_raw.appendSlice(allocator, f.payload[4..]) catch fail("oom");
            var upos: usize = 0;
            while ((wlpipe.peelUnit(units_raw.items[upos..]) catch fail("clip unit")) != null) {
                const p = (wlpipe.peelUnit(units_raw.items[upos..]) catch unreachable).?;
                if (p.unit.tag == .wl_msg) {
                    const h = (wlwire.parseHeader(p.unit.payload) catch fail("clip hdr")) orelse fail("clip hdr");
                    if (h.object == 0xff000001 and h.opcode == 1) got_receive = true;
                }
                upos += p.consumed;
            }
        }
        if (!got_receive) fail("receive never relayed to the GUI");
        var ub2: std.ArrayList(u8) = .empty;
        defer ub2.deinit(allocator);
        ub2.appendSlice(allocator, &idb) catch fail("oom");
        wlpipe.appendUnit(&ub2, allocator, .clip_data, "PASTE-42") catch fail("oom");
        conn.sendFrame(.chan_data, ub2.items) catch fail("clip_data send");
        var paste: [32]u8 = undefined;
        const pn = c.read(pfds[0], &paste, paste.len);
        if (pn != 8 or !std.mem.eql(u8, paste[0..8], "PASTE-42")) fail("paste bytes wrong");
        if (c.read(pfds[0], &paste, paste.len) != 0) fail("paste fd not closed");
        _ = c.close(pfds[0]);

        // COPY: app creates a source; GUI fetches it.
        b = wlwire.Builder.init(&mbuf, 20, 0); // create_data_source(22)
        b.putNewId(22);
        m = b.finish() catch unreachable;
        if (c.write(app_fd, m.ptr, m.len) != @as(isize, @intCast(m.len))) fail("clip src write");
        var ub3: std.ArrayList(u8) = .empty;
        defer ub3.deinit(allocator);
        ub3.appendSlice(allocator, &idb) catch fail("oom");
        var sendp: std.ArrayList(u8) = .empty;
        defer sendp.deinit(allocator);
        var srcb: [4]u8 = undefined;
        std.mem.writeInt(u32, &srcb, 22, .little);
        sendp.appendSlice(allocator, &srcb) catch fail("oom");
        sendp.appendSlice(allocator, "text/plain;charset=utf-8") catch fail("oom");
        wlpipe.appendUnit(&ub3, allocator, .clip_send, sendp.items) catch fail("oom");
        conn.sendFrame(.chan_data, ub3.items) catch fail("clip_send send");

        // App receives wl_data_source.send(mime, fd), writes, closes.
        const got = recvWithFd(app_fd) orelse fail("send event missing fd");
        if (got.fd < 0) fail("send event missing fd");
        if (c.write(got.fd, "COPY-7", 6) != 6) fail("copy write");
        _ = c.close(got.fd);

        // The copy content must come back as a clip_data unit.
        var copy_ok = false;
        deadline2 = 0;
        while (!copy_ok and deadline2 < 200) : (deadline2 += 1) {
            const f = conn.recvFrame() catch fail("copy stream read");
            defer f.deinit(allocator);
            if (f.ftype != .chan_data) continue;
            units_raw.clearRetainingCapacity();
            units_raw.appendSlice(allocator, f.payload[4..]) catch fail("oom");
            var upos: usize = 0;
            while ((wlpipe.peelUnit(units_raw.items[upos..]) catch fail("copy unit")) != null) {
                const p = (wlpipe.peelUnit(units_raw.items[upos..]) catch unreachable).?;
                if (p.unit.tag == .clip_data and std.mem.eql(u8, p.unit.payload, "COPY-7")) copy_ok = true;
                upos += p.consumed;
            }
        }
        if (!copy_ok) fail("copied bytes never came back up");
        std.debug.print("smoke-mux: clipboard paste+copy round-trip ok\n", .{});
    }

    // GUI→app: an event unit must come out of the app socket verbatim.
    {
        var b = wlwire.Builder.init(&mbuf, 3, 0); // wl_shm.format(1)
        b.putUint(1);
        const ev = b.finish() catch unreachable;
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, chan_id, .little);
        unit.appendSlice(allocator, &idb) catch fail("oom");
        wlpipe.appendUnit(&unit, allocator, .wl_msg, ev) catch fail("oom");
        conn.sendFrame(.chan_data, unit.items) catch fail("chan_data send");

        var got: [64]u8 = undefined;
        const r = c.read(app_fd, &got, got.len);
        if (r != @as(isize, @intCast(ev.len)) or !std.mem.eql(u8, got[0..ev.len], ev)) fail("event did not reach the app");
    }
}

/// The real-client milestone: a stock Wayland app (weston-terminal)
/// spawned in a native-pipe session, with the wlhost Compositor on
/// this end answering the protocol. Pass = a committed toplevel
/// frame with plausible dimensions reaches the view. Skipped when
/// weston-terminal isn't installed.
fn realAppStage(allocator: std.mem.Allocator, sock_path: []const u8) void {
    if (c.access("/usr/bin/weston-terminal", c.X_OK) != 0) {
        std.debug.print("smoke-mux: real-app stage SKIPPED (no weston-terminal)\n", .{});
        return;
    }
    const compositor_mod = @import("wlhost/compositor.zig");

    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("app-stage connect");
    defer conn.deinit();
    // Hang guard: a silent stall fails the stage instead of wedging
    // the smoke. Generous because weston-terminal loads fonts.
    const tv = c.struct_timeval{ .tv_sec = 20, .tv_usec = 0 };
    _ = c.setsockopt(conn.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));

    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("app-stage hello");
    (conn.recvExpect(&.{.welcome}) catch fail("app-stage welcome")).deinit(allocator);
    conn.sendJson(.spawn, .{
        .name = "wlapp",
        .argv = [_][]const u8{"/usr/bin/weston-terminal"},
        .rows = @as(u16, 10),
        .cols = @as(u16, 60),
        .app = true,
    }) catch fail("app-stage spawn");
    (conn.recvExpect(&.{.ok}) catch fail("app-stage spawn ok")).deinit(allocator);
    conn.sendJson(.attach, .{ .name = "wlapp" }) catch fail("app-stage attach");
    (conn.recvExpect(&.{.snapshot}) catch fail("app-stage snapshot")).deinit(allocator);

    const ViewState = struct {
        var frames: usize = 0;
        var w: i32 = 0;
        var h: i32 = 0;
        var sid: u32 = 0;
        var nonzero_px: bool = false;
        fn onFrame(ctx: ?*anyopaque, surface: u32, fw: i32, fh: i32, format: u32, pixels: []const u8) void {
            _ = ctx;
            _ = format;
            frames += 1;
            sid = surface;
            w = fw;
            h = fh;
            for (pixels) |p| {
                if (p != 0) {
                    nonzero_px = true;
                    break;
                }
            }
        }
    };
    ViewState.frames = 0;
    ViewState.sid = 0;
    ViewState.nonzero_px = false;

    var comp = compositor_mod.Compositor.init(allocator, .{
        .toplevel_frame = ViewState.onFrame,
    }) catch fail("compositor init");
    defer comp.deinit();

    var chan_id: u32 = 0;
    var rounds: usize = 0;
    while (ViewState.frames == 0 and rounds < 2000) : (rounds += 1) {
        const f = conn.recvFrame() catch fail("app-stage stream read (timeout = app never committed)");
        defer f.deinit(allocator);
        switch (f.ftype) {
            .chan_open => {
                const open = wire.decodeChanOpen(f.payload) orelse fail("app-stage chan_open");
                if (open.kind != .wayland_native) fail("app-stage channel kind");
                chan_id = open.id;
            },
            .chan_data => {
                if ((wire.decodeChanId(f.payload) orelse 0) != chan_id) continue;
                comp.feed(f.payload[4..]) catch fail("compositor feed");
                const out = comp.takeOut();
                if (out.len > 0) {
                    var payload: std.ArrayList(u8) = .empty;
                    defer payload.deinit(allocator);
                    var idb: [4]u8 = undefined;
                    std.mem.writeInt(u32, &idb, chan_id, .little);
                    payload.appendSlice(allocator, &idb) catch fail("oom");
                    payload.appendSlice(allocator, out) catch fail("oom");
                    comp.clearOut();
                    conn.sendFrame(.chan_data, payload.items) catch fail("app-stage chan send");
                }
                if (comp.dead) fail("compositor flagged protocol error from a stock client");
            },
            .exit => fail("weston-terminal exited before committing a frame"),
            else => {},
        }
    }
    if (ViewState.frames == 0) fail("no toplevel frame from weston-terminal");
    if (ViewState.w < 100 or ViewState.h < 100) fail("implausible toplevel size");
    if (!ViewState.nonzero_px) fail("toplevel frame is all zeros");
    std.debug.print("smoke-mux: real app frame {d}x{d} after {d} rounds\n", .{ ViewState.w, ViewState.h, rounds });

    // Keyboard input through the full pipe: the keymap fd was
    // materialized by the daemon when weston-terminal bound the
    // keyboard; now type "ls" and expect echo redraws (new frames).
    const frames_before_input = ViewState.frames;
    comp.now_ms = 1000;
    comp.keyboardEnter(ViewState.sid) catch fail("kbd enter");
    comp.keyboardModifiers(0, 0, 0, 0) catch fail("kbd mods");
    for ([_]u32{ 38, 31 }) |key| { // evdev l, s
        comp.keyboardKey(key, true) catch fail("kbd key");
        comp.keyboardKey(key, false) catch fail("kbd key");
    }
    {
        const out = comp.takeOut();
        if (out.len == 0) fail("no input events queued (keyboard never bound?)");
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, chan_id, .little);
        payload.appendSlice(allocator, &idb) catch fail("oom");
        payload.appendSlice(allocator, out) catch fail("oom");
        comp.clearOut();
        conn.sendFrame(.chan_data, payload.items) catch fail("input chan send");
    }
    rounds = 0;
    while (ViewState.frames == frames_before_input and rounds < 2000) : (rounds += 1) {
        const f = conn.recvFrame() catch fail("input echo read (timeout = keys never echoed)");
        defer f.deinit(allocator);
        if (f.ftype != .chan_data) continue;
        if ((wire.decodeChanId(f.payload) orelse 0) != chan_id) continue;
        comp.feed(f.payload[4..]) catch fail("compositor feed (input)");
        const out = comp.takeOut();
        if (out.len > 0) {
            var payload: std.ArrayList(u8) = .empty;
            defer payload.deinit(allocator);
            var idb: [4]u8 = undefined;
            std.mem.writeInt(u32, &idb, chan_id, .little);
            payload.appendSlice(allocator, &idb) catch fail("oom");
            payload.appendSlice(allocator, out) catch fail("oom");
            comp.clearOut();
            conn.sendFrame(.chan_data, payload.items) catch fail("chan send");
        }
        if (comp.dead) fail("protocol error after input injection");
    }
    if (ViewState.frames == frames_before_input) fail("typed keys never produced a redraw");
    std.debug.print("smoke-mux: input echo ok ({d} frames after typing)\n", .{ViewState.frames});

    // Tear the session down; the daemon must survive the app dying.
    conn.sendJson(.kill, .{ .name = "wlapp" }) catch fail("app-stage kill");
}

/// wl_surface.commit on surface 7 — 8 header bytes, no args.
fn commitNeedle() [8]u8 {
    var buf: [8]u8 = undefined;
    var b = wlwire.Builder.init(&buf, 7, 6);
    _ = b.finish() catch unreachable;
    return buf;
}

/// recvmsg expecting one SCM_RIGHTS fd (the wl_data_source.send
/// event from the daemon). fd = -1 when none was attached.
fn recvWithFd(sock: c_int) ?struct { fd: c_int } {
    var data: [256]u8 = undefined;
    var cbuf: [64]u8 align(@alignOf(c.struct_cmsghdr)) = undefined;
    var iov = c.struct_iovec{ .iov_base = &data, .iov_len = data.len };
    var mh = std.mem.zeroes(c.struct_msghdr);
    mh.msg_iov = @ptrCast(&iov);
    mh.msg_iovlen = 1;
    mh.msg_control = &cbuf;
    mh.msg_controllen = cbuf.len;
    const r = c.recvmsg(sock, &mh, 0);
    if (r <= 0) return null;
    const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
    var off: usize = 0;
    const clen: usize = @intCast(mh.msg_controllen);
    while (off + hdr_size <= clen) {
        const hdr: *const c.struct_cmsghdr = @alignCast(@ptrCast(cbuf[off..].ptr));
        const cl: usize = @intCast(hdr.cmsg_len);
        if (cl < hdr_size or off + cl > clen) break;
        if (hdr.cmsg_level == c.SOL_SOCKET and hdr.cmsg_type == c.SCM_RIGHTS) {
            var fd: c_int = undefined;
            @memcpy(std.mem.asBytes(&fd), cbuf[off + hdr_size ..][0..@sizeOf(c_int)]);
            return .{ .fd = fd };
        }
        off += (cl + @sizeOf(usize) - 1) & ~@as(usize, @sizeOf(usize) - 1);
    }
    return .{ .fd = -1 };
}

/// sendmsg with one SCM_RIGHTS fd attached (CMSG_* macros don't
/// translate; layout per 64-bit glibc/musl: 16-byte header, data
/// follows, space padded to 8).
fn sendWithFd(sock: c_int, bytes: []const u8, fd: c_int) !void {
    var iov = c.struct_iovec{ .iov_base = @constCast(bytes.ptr), .iov_len = bytes.len };
    var cbuf: [32]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([32]u8);
    const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
    const cmsg: *c.struct_cmsghdr = @ptrCast(&cbuf);
    cmsg.cmsg_len = @intCast(hdr_size + @sizeOf(c_int));
    cmsg.cmsg_level = c.SOL_SOCKET;
    cmsg.cmsg_type = c.SCM_RIGHTS;
    @memcpy(cbuf[hdr_size..][0..@sizeOf(c_int)], std.mem.asBytes(&fd));
    var mh = std.mem.zeroes(c.struct_msghdr);
    mh.msg_iov = @ptrCast(&iov);
    mh.msg_iovlen = 1;
    mh.msg_control = &cbuf;
    mh.msg_controllen = @intCast(hdr_size + 8); // CMSG_SPACE(4)
    if (c.sendmsg(sock, &mh, 0) != @as(isize, @intCast(bytes.len))) return error.SendFailed;
}

fn daemonMain(d: *daemon_mod.Daemon) void {
    d.run() catch |err| {
        std.debug.print("smoke-mux: daemon error: {s}\n", .{@errorName(err)});
    };
}

pub fn main() u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // Sessions in this smoke use the sketerm-native app pipe (no
    // waypipe dependency on the test host).
    _ = c.setenv("SKETERM_MUX_NATIVE_WAYLAND", "1", 1);

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

    // Kitty t=f image: the file lives on the DAEMON's host. The
    // daemon must fetch + inline it (t=d rewrite) so the client can
    // decode it without filesystem access, and the snapshot must
    // carry the placement across reattach.
    var img_path_buf: [128]u8 = undefined;
    const img_path = std.fmt.bufPrint(&img_path_buf, "/tmp/sketerm-mux-smoke-{d}-img.rgba", .{c.getpid()}) catch unreachable;
    writeRedRgba(img_path) catch fail("image file write");
    var b64_buf: [256]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    const path_b64 = enc.encode(b64_buf[0..enc.calcSize(img_path.len)], img_path);
    var cmd_buf: [512]u8 = undefined;
    const img_cmd = std.fmt.bufPrint(
        &cmd_buf,
        "printf '\\033_Gf=32,s=2,v=2,t=f,a=T,i=77;{s}\\033\\\\'\n",
        .{path_b64},
    ) catch unreachable;
    conn.sendFrame(.input, img_cmd) catch fail("img input send");
    deadline = 0;
    var img_seen = false;
    while (deadline < 200) : (deadline += 1) {
        const f = conn.recvFrame() catch fail("img stream read");
        defer f.deinit(allocator);
        if (f.ftype == .events) mirror.applyEvents(f.payload) catch fail("img events apply");
        if (mirror.screen.?.kitty_images.get(77) != null) {
            img_seen = true;
            break;
        }
    }
    if (!img_seen) fail("t=f image never reached the client inline");
    {
        // t=f must leave the file in place (only t=t deletes); clean
        // it up ourselves now that the assertion ran.
        var z_buf: [4096]u8 = undefined;
        if (@import("util/pathz.zig").pathZ(&z_buf, img_path)) |p| {
            if (c.access(p, c.F_OK) != 0) fail("t=f deleted the source file");
            _ = c.unlink(p);
        } else |_| {}
    }

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
        // Image placement restored from the snapshot.
        if (mirror.screen.?.retained_images.items.len < 1) fail("image placement missing from snapshot");
        const ri = mirror.screen.?.retained_images.items[0];
        if (ri.ev.image_id != 77 or ri.owned.len != 16) fail("retained image data wrong");
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

    // Native Wayland app pipe end-to-end (scripted client).
    nativePipeStage(allocator, &conn, sock_path);

    // Native pipe with a REAL Wayland app + the compositor brain.
    realAppStage(allocator, sock_path);

    // A second client sees the session in LIST.
    var conn2 = client_mod.Conn.connect(allocator, sock_path) catch fail("connect2");
    conn2.sendFrame(.list, "") catch fail("list send");
    const lst = conn2.recvExpect(&.{.welcome}) catch fail("list");
    if (std.mem.indexOf(u8, lst.payload, "\"smoke\"") == null) fail("list missing session");
    lst.deinit(allocator);

    // Rename: duplicate name rejected, fresh name confirmed and
    // visible in LIST (under the new name only).
    conn2.sendJson(.rename, .{ .name = "smoke", .new_name = "" }) catch fail("rename send");
    (conn2.recvExpect(&.{.err}) catch fail("rename empty not rejected")).deinit(allocator);
    conn2.sendJson(.rename, .{ .name = "smoke", .new_name = "smoke2" }) catch fail("rename send");
    (conn2.recvExpect(&.{.ok}) catch fail("rename ok")).deinit(allocator);
    conn2.sendFrame(.list, "") catch fail("list send");
    const lst2 = conn2.recvExpect(&.{.welcome}) catch fail("list after rename");
    if (std.mem.indexOf(u8, lst2.payload, "\"smoke2\"") == null) fail("rename missing in list");
    if (std.mem.indexOf(u8, lst2.payload, "\"smoke\",") != null) fail("old name still listed");
    lst2.deinit(allocator);
    conn2.sendJson(.rename, .{ .name = "nosuch", .new_name = "other" }) catch fail("rename send");
    (conn2.recvExpect(&.{.err}) catch fail("rename ghost not rejected")).deinit(allocator);

    // Kill: attached client gets GONE.
    conn2.sendJson(.kill, .{ .name = "smoke2" }) catch fail("kill send");
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
