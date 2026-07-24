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
const wlpixcodec = @import("wlhost/pixcodec.zig");
const wlprotocol = @import("wlhost/protocol.zig");
const snapshot = @import("mux/snapshot.zig");
const Screen = @import("grid/screen.zig").Screen;
const Pool = @import("grid/style_pool.zig").Pool;

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("smoke-mux: FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

const MARKER = "mux-smoke-7311";

fn negotiationStage(allocator: std.mem.Allocator, sock_path: []const u8) void {
    // A future client with no shared core can still list sessions; attach is
    // refused without mutating the daemon or its sessions.
    var future = client_mod.Conn.connect(allocator, sock_path) catch fail("neg future connect");
    defer future.deinit();
    future.sendJson(.hello, .{
        .proto = @as(u32, wire.PROTO_VERSION + 3),
        .min_proto = @as(u32, wire.PROTO_VERSION + 1),
        .negotiation = @as(u8, 1),
        .snapshot_max = snapshot.SNAPSHOT_VERSION,
    }) catch fail("neg future hello");
    const fw = future.recvExpect(&.{.welcome}) catch fail("neg future welcome");
    if (std.mem.indexOf(u8, fw.payload, "\"proto\":0") == null) fail("neg future overlap");
    fw.deinit(allocator);
    future.sendFrame(.list, "") catch fail("neg future list");
    const fl = future.recvExpect(&.{.welcome}) catch fail("neg future list reply");
    if (std.mem.indexOf(u8, fl.payload, "\"smoke\"") == null) fail("neg future list lost sessions");
    fl.deinit(allocator);
    future.sendJson(.attach, .{ .name = "smoke" }) catch fail("neg future attach");
    (future.recvExpect(&.{.err}) catch fail("neg future attach not refused")).deinit(allocator);

    var legacy_future = client_mod.Conn.connect(allocator, sock_path) catch fail("neg legacy future connect");
    defer legacy_future.deinit();
    legacy_future.sendJson(.hello, .{ .proto = wire.PROTO_VERSION + 3 }) catch fail("neg legacy future hello");
    const lfw = legacy_future.recvExpect(&.{.welcome}) catch fail("neg legacy future welcome");
    if (std.mem.indexOf(u8, lfw.payload, "\"proto\":0") == null) fail("neg legacy future clamped");
    lfw.deinit(allocator);
    legacy_future.sendFrame(.shutdown, "") catch fail("neg legacy future shutdown send");
    (legacy_future.recvExpect(&.{.err}) catch fail("neg legacy future shutdown not refused")).deinit(allocator);

    // Protocol 1 cannot identify which historical snapshot revision it reads.
    // Keep discovery available, but do not guess and corrupt its stream.
    var v1 = client_mod.Conn.connect(allocator, sock_path) catch fail("neg v1 connect");
    defer v1.deinit();
    v1.sendJson(.hello, .{ .proto = @as(u32, 1) }) catch fail("neg v1 hello");
    const v1w = v1.recvExpect(&.{.welcome}) catch fail("neg v1 welcome");
    if (std.mem.indexOf(u8, v1w.payload, "\"proto\":0") == null) fail("neg v1 ambiguity");
    v1w.deinit(allocator);
    v1.sendJson(.attach, .{ .name = "smoke" }) catch fail("neg v1 attach");
    (v1.recvExpect(&.{.err}) catch fail("neg v1 attach not refused")).deinit(allocator);

    // Optional-format negotiation can select an older snapshot body while
    // keeping the current core protocol.
    var legacy = client_mod.Conn.connect(allocator, sock_path) catch fail("neg legacy connect");
    defer legacy.deinit();
    legacy.sendJson(.hello, .{
        .proto = wire.PROTO_VERSION,
        .min_proto = @as(u32, 1),
        .negotiation = @as(u8, 1),
        .snapshot_max = @as(u8, 3),
        .native_state_max = @as(u8, 0),
        .audio = false,
        .winstream = false,
    }) catch fail("neg legacy hello");
    const lw = legacy.recvExpect(&.{.welcome}) catch fail("neg legacy welcome");
    if (std.mem.indexOf(u8, lw.payload, "\"snapshot\":3") == null) fail("neg snapshot max ignored");
    lw.deinit(allocator);
    legacy.sendJson(.attach, .{ .name = "smoke" }) catch fail("neg legacy attach");
    const snap = legacy.recvExpect(&.{.snapshot}) catch fail("neg legacy snapshot");
    const envelope = snapshot.peelEnvelope(snap.payload) catch fail("neg legacy envelope");
    if (std.mem.readInt(u32, envelope.body[0..4], .little) != 3) fail("neg legacy snapshot body");
    snap.deinit(allocator);
}

/// A client that never sends a hello (the quick CLI send/get-text/kill
/// connections of every released build) is served with the documented
/// legacy defaults — spawn, kill, and attach must all work, and the
/// snapshot body must be the legacy revision its decoders accept.
/// Runs late: its extra session must not shift the Wayland display
/// ordinals earlier stages hard-code.
fn noHelloStage(allocator: std.mem.Allocator, sock_path: []const u8) void {
    var nohello = client_mod.Conn.connect(allocator, sock_path) catch fail("nohello connect");
    defer nohello.deinit();
    nohello.sendJson(.spawn, .{
        .name = "nohello",
        .argv = [_][]const u8{ "/bin/sleep", "30" },
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
    }) catch fail("nohello spawn send");
    (nohello.recvExpect(&.{.ok}) catch fail("nohello spawn refused")).deinit(allocator);
    nohello.sendJson(.attach, .{ .name = "nohello" }) catch fail("nohello attach");
    const nh_snap = nohello.recvExpect(&.{.snapshot}) catch fail("nohello attach refused");
    const nh_env = snapshot.peelEnvelope(nh_snap.payload) catch fail("nohello envelope");
    if (std.mem.readInt(u32, nh_env.body[0..4], .little) != 3) fail("nohello snapshot body");
    nh_snap.deinit(allocator);
    nohello.sendJson(.detach, .{}) catch fail("nohello detach");
    nohello.sendJson(.kill, .{ .name = "nohello" }) catch fail("nohello kill send");
    (nohello.recvExpect(&.{.ok}) catch fail("nohello kill refused")).deinit(allocator);
    std.debug.print("smoke-mux: no-hello legacy client served ok\n", .{});
}

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
        if (payload.len < 9) return error.Truncated; // [seq:u64][app:u8] header
        if (self.screen) |s| s.deinit();
        self.screen = null;
        self.pool.deinit();
        self.pool.* = try Pool.init(self.allocator);
        self.screen = try snapshot.restore(self.allocator, self.pool, (try snapshot.peelEnvelope(payload)).body);
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
/// Drain the app-side socket until `dev` receives its selection
/// event (opcode `sel_op`), returning the offer id announced by the
/// preceding data_offer event on that device. Skips every other
/// event (registry globals, shm formats, other devices' offers).
fn awaitSelection(allocator: std.mem.Allocator, app_fd: c_int, dev: u32, sel_op: u16) u32 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var offer: u32 = 0;
    var rounds: usize = 0;
    while (rounds < 400) : (rounds += 1) {
        var pos: usize = 0;
        while (true) {
            const h = (wlwire.parseHeader(buf.items[pos..]) catch fail("app event header")) orelse break;
            if (buf.items[pos..].len < h.size) break;
            const body = buf.items[pos + wlwire.header_size .. pos + h.size];
            if (h.object == dev and h.opcode == 0 and body.len >= 4)
                offer = std.mem.readInt(u32, body[0..4], .little);
            if (h.object == dev and h.opcode == sel_op) return offer;
            pos += h.size;
        }
        if (pos > 0) {
            const rem = buf.items.len - pos;
            std.mem.copyForwards(u8, buf.items[0..rem], buf.items[pos..]);
            buf.shrinkRetainingCapacity(rem);
        }
        var chunk: [4096]u8 = undefined;
        const r = c.read(app_fd, &chunk, chunk.len);
        if (r <= 0) fail("app socket read while awaiting selection");
        buf.appendSlice(allocator, chunk[0..@intCast(r)]) catch fail("oom");
    }
    fail("selection event never arrived");
}

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
    _ = c.setsockopt(app_fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));

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
        blk: { // wl_registry.bind(2, "wl_shm", 1, id=3) — real global names:
            // the daemon brain (proto v5) resolves binds strictly
            // against its advertised globals (wl_shm = name 2).
            var b = wlwire.Builder.init(mbuf[32..], 2, 0);
            b.putUint(2);
            b.putString("wl_shm");
            b.putUint(1);
            b.putNewId(3);
            break :blk b.finish() catch unreachable;
        },
        blk: { // wl_registry.bind(1, "wl_compositor", 4, id=6)
            var b = wlwire.Builder.init(mbuf[96..], 2, 0);
            b.putUint(1);
            b.putString("wl_compositor");
            b.putUint(4);
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
            .pool_update_c => {
                const upd = wlpipe.decodePoolUpdateC(p.unit.payload) orelse fail("pool update c");
                if (upd.pool != 4) fail("pool update c id");
                if (upd.offset != update_bytes.items.len) fail("pool update c offset");
                const dst = allocator.alloc(u8, upd.body.raw_len) catch fail("oom");
                defer allocator.free(dst);
                wlpixcodec.decodeBody(upd.body, dst) catch fail("pool update c decode");
                update_bytes.appendSlice(allocator, dst) catch fail("oom");
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
        b.putUint(6); // real global name — the v5 brain resolves strictly
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

        // Viewer announces a host selection via the v5 intent; the
        // daemon BRAIN creates the server-side offer and emits
        // data_offer/offer/selection toward the app.
        var ub: std.ArrayList(u8) = .empty;
        defer ub.deinit(allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, chan_id, .little);
        ub.appendSlice(allocator, &idb) catch fail("oom");
        wlpipe.appendUnit(&ub, allocator, .offer_selection, "text/plain;charset=utf-8") catch fail("oom");
        conn.sendFrame(.chan_data, ub.items) catch fail("clip offer send");

        // App parses the brain's events, then pastes: receive(mime, fd).
        const offer_id = awaitSelection(allocator, app_fd, 21, 5);
        if (offer_id == 0) fail("brain never announced a data offer");
        var pfds: [2]c_int = undefined;
        if (c.pipe(&pfds) != 0) fail("paste pipe");
        b = wlwire.Builder.init(&mbuf, offer_id, 1); // receive
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
                    if (h.object == offer_id and h.opcode == 1) got_receive = true;
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

    // Surface-less clipboard (wlr-data-control): same daemon plumbing,
    // but the `send`/`receive` opcodes differ from wl_data_device and
    // the daemon must pick them by the source's tracked interface.
    {
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, chan_id, .little);

        // App binds zwlr_data_control_manager_v1 (obj 30) + device 31.
        var b = wlwire.Builder.init(&mbuf, 2, 0); // registry.bind
        b.putUint(12);
        b.putString("zwlr_data_control_manager_v1");
        b.putUint(1);
        b.putNewId(30);
        var m = b.finish() catch unreachable;
        if (c.write(app_fd, m.ptr, m.len) != @as(isize, @intCast(m.len))) fail("dc bind write");
        b = wlwire.Builder.init(&mbuf, 30, 1); // get_data_device(31, seat 0)
        b.putNewId(31);
        b.putObject(0);
        m = b.finish() catch unreachable;
        if (c.write(app_fd, m.ptr, m.len) != @as(isize, @intCast(m.len))) fail("dc dev write");

        // Wait for the daemon to relay get_data_device (tracker learns 31).
        {
            var seen = false;
            var dl: usize = 0;
            while (!seen and dl < 200) : (dl += 1) {
                const f = conn.recvFrame() catch fail("dc dev relay read");
                defer f.deinit(allocator);
                if (f.ftype != .chan_data) continue;
                units_raw.clearRetainingCapacity();
                units_raw.appendSlice(allocator, f.payload[4..]) catch fail("oom");
                var upos: usize = 0;
                while ((wlpipe.peelUnit(units_raw.items[upos..]) catch fail("dc unit")) != null) {
                    const p = (wlpipe.peelUnit(units_raw.items[upos..]) catch unreachable).?;
                    if (p.unit.tag == .wl_msg) {
                        const h = (wlwire.parseHeader(p.unit.payload) catch fail("dc hdr")) orelse fail("dc hdr");
                        if (h.object == 30 and h.opcode == 1) seen = true;
                    }
                    upos += p.consumed;
                }
            }
            if (!seen) fail("dc get_data_device never relayed");
        }

        // No intent needed: the data-control protocol requires the
        // compositor to announce the current selection right after
        // get_data_device, and the brain does — the app just waits
        // for the zwlr selection (op 1) and pastes at OP 0.
        const dc_offer = awaitSelection(allocator, app_fd, 31, 1);
        if (dc_offer == 0) fail("brain never announced a dc offer");
        var pfds: [2]c_int = undefined;
        if (c.pipe(&pfds) != 0) fail("dc paste pipe");
        b = wlwire.Builder.init(&mbuf, dc_offer, 0); // receive (op 0)
        b.putString("text/plain;charset=utf-8");
        sendWithFd(app_fd, b.finish() catch unreachable, pfds[1]) catch fail("dc receive sendmsg");
        _ = c.close(pfds[1]);

        // Daemon must relay the receive up + hold the fd; GUI answers.
        var got_receive = false;
        var dl2: usize = 0;
        while (!got_receive and dl2 < 200) : (dl2 += 1) {
            const f = conn.recvFrame() catch fail("dc clip stream read");
            defer f.deinit(allocator);
            if (f.ftype != .chan_data) continue;
            units_raw.clearRetainingCapacity();
            units_raw.appendSlice(allocator, f.payload[4..]) catch fail("oom");
            var upos: usize = 0;
            while ((wlpipe.peelUnit(units_raw.items[upos..]) catch fail("dc unit")) != null) {
                const p = (wlpipe.peelUnit(units_raw.items[upos..]) catch unreachable).?;
                if (p.unit.tag == .wl_msg) {
                    const h = (wlwire.parseHeader(p.unit.payload) catch fail("dc hdr")) orelse fail("dc hdr");
                    if (h.object == dc_offer and h.opcode == 0) got_receive = true;
                }
                upos += p.consumed;
            }
        }
        if (!got_receive) fail("dc receive never relayed to the GUI");
        var ub2: std.ArrayList(u8) = .empty;
        defer ub2.deinit(allocator);
        ub2.appendSlice(allocator, &idb) catch fail("oom");
        wlpipe.appendUnit(&ub2, allocator, .clip_data, "DC-PASTE") catch fail("oom");
        conn.sendFrame(.chan_data, ub2.items) catch fail("dc clip_data send");
        var paste: [32]u8 = undefined;
        const pn = c.read(pfds[0], &paste, paste.len);
        if (pn != 8 or !std.mem.eql(u8, paste[0..8], "DC-PASTE")) fail("dc paste bytes wrong");
        _ = c.close(pfds[0]);

        // COPY: app creates a data-control source (obj 32); GUI fetches.
        b = wlwire.Builder.init(&mbuf, 30, 0); // create_data_source(32)
        b.putNewId(32);
        m = b.finish() catch unreachable;
        if (c.write(app_fd, m.ptr, m.len) != @as(isize, @intCast(m.len))) fail("dc src write");
        // Wait for the daemon to relay create_data_source so its tracker
        // knows obj 32 is a data-control source BEFORE clip_send arrives —
        // otherwise it can't pick the op-0 `send` opcode (the whole point).
        {
            var seen = false;
            var dl: usize = 0;
            while (!seen and dl < 200) : (dl += 1) {
                const f = conn.recvFrame() catch fail("dc src relay read");
                defer f.deinit(allocator);
                if (f.ftype != .chan_data) continue;
                units_raw.clearRetainingCapacity();
                units_raw.appendSlice(allocator, f.payload[4..]) catch fail("oom");
                var upos: usize = 0;
                while ((wlpipe.peelUnit(units_raw.items[upos..]) catch fail("dc unit")) != null) {
                    const p = (wlpipe.peelUnit(units_raw.items[upos..]) catch unreachable).?;
                    if (p.unit.tag == .wl_msg) {
                        const h = (wlwire.parseHeader(p.unit.payload) catch fail("dc hdr")) orelse fail("dc hdr");
                        if (h.object == 30 and h.opcode == 0) seen = true;
                    }
                    upos += p.consumed;
                }
            }
            if (!seen) fail("dc create_data_source never relayed");
        }
        var ub3: std.ArrayList(u8) = .empty;
        defer ub3.deinit(allocator);
        ub3.appendSlice(allocator, &idb) catch fail("oom");
        var sendp: std.ArrayList(u8) = .empty;
        defer sendp.deinit(allocator);
        var srcb: [4]u8 = undefined;
        std.mem.writeInt(u32, &srcb, 32, .little);
        sendp.appendSlice(allocator, &srcb) catch fail("oom");
        sendp.appendSlice(allocator, "text/plain;charset=utf-8") catch fail("oom");
        wlpipe.appendUnit(&ub3, allocator, .clip_send, sendp.items) catch fail("oom");
        conn.sendFrame(.chan_data, ub3.items) catch fail("dc clip_send send");

        // The daemon must emit zwlr_data_control_source_v1.send at OP 0
        // (wl_data_source.send is op 1) — the crux of the opcode fix.
        const got = recvWithFd(app_fd) orelse fail("dc send event missing fd");
        if (got.fd < 0) fail("dc send event missing fd");
        if (got.obj != 32 or got.opcode != 0) fail("dc send wrong object/opcode (expected source 32 op 0)");
        if (c.write(got.fd, "DC-COPY", 7) != 7) fail("dc copy write");
        _ = c.close(got.fd);

        var copy_ok = false;
        dl2 = 0;
        while (!copy_ok and dl2 < 200) : (dl2 += 1) {
            const f = conn.recvFrame() catch fail("dc copy stream read");
            defer f.deinit(allocator);
            if (f.ftype != .chan_data) continue;
            units_raw.clearRetainingCapacity();
            units_raw.appendSlice(allocator, f.payload[4..]) catch fail("oom");
            var upos: usize = 0;
            while ((wlpipe.peelUnit(units_raw.items[upos..]) catch fail("dc unit")) != null) {
                const p = (wlpipe.peelUnit(units_raw.items[upos..]) catch unreachable).?;
                if (p.unit.tag == .clip_data and std.mem.eql(u8, p.unit.payload, "DC-COPY")) copy_ok = true;
                upos += p.consumed;
            }
        }
        if (!copy_ok) fail("dc copied bytes never came back up");
        std.debug.print("smoke-mux: wlr-data-control surfaceless clipboard round-trip ok\n", .{});
    }

    // Viewer→app, v5: raw wl_msg from a viewer must be DROPPED (the
    // daemon brain is the only protocol driver — a replica answering
    // too would double-drive the app). An intent through the brain
    // must still reach the app: request_close emits
    // xdg_toplevel.close... but this scripted app has no toplevel, so
    // use dismiss_popups (inert, proves intent parsing is harmless)
    // plus a seat intent path exercised by the real-app stage below.
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

        // The forged event must NOT reach the app. Give the daemon a
        // moment, then confirm the app socket stays silent.
        const short = c.struct_timeval{ .tv_sec = 0, .tv_usec = 300_000 };
        _ = c.setsockopt(app_fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &short, @sizeOf(c.struct_timeval));
        var got: [64]u8 = undefined;
        const r = c.read(app_fd, &got, got.len);
        if (r > 0) fail("forged viewer wl_msg reached the app (v5 must drop it)");
        std.debug.print("smoke-mux: forged viewer event dropped ok\n", .{});
    }

    // An actual non-negotiating protocol-5 viewer must receive the historical
    // v6 state blob, not be silently excluded by the current v7 capability.
    {
        var legacy = client_mod.Conn.connect(allocator, sock_path) catch fail("v5 native connect");
        defer legacy.deinit();
        _ = c.setsockopt(legacy.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
        legacy.sendJson(.hello, .{ .proto = @as(u32, 5) }) catch fail("v5 native hello");
        const welcome = legacy.recvExpect(&.{.welcome}) catch fail("v5 native welcome");
        if (std.mem.indexOf(u8, welcome.payload, "\"native_state\":6") == null) fail("v5 native capability");
        welcome.deinit(allocator);
        legacy.sendJson(.attach, .{ .name = "smoke" }) catch fail("v5 native attach");
        (legacy.recvExpect(&.{.snapshot}) catch fail("v5 native snapshot")).deinit(allocator);

        var replay: std.ArrayList(u8) = .empty;
        defer replay.deinit(allocator);
        var saw_v6 = false;
        var tries: usize = 0;
        while (!saw_v6 and tries < 200) : (tries += 1) {
            const frame = legacy.recvFrame() catch fail("v5 native replay");
            defer frame.deinit(allocator);
            if (frame.ftype != .chan_data or frame.payload.len < 4) continue;
            replay.appendSlice(allocator, frame.payload[4..]) catch fail("v5 native replay oom");
            var replay_pos: usize = 0;
            while (true) {
                const unit = (wlpipe.peelUnit(replay.items[replay_pos..]) catch fail("v5 native replay unit")) orelse break;
                if (unit.unit.tag == .state_sync) {
                    if (unit.unit.payload.len == 0 or unit.unit.payload[0] != 6) fail("v5 native state version");
                    saw_v6 = true;
                }
                replay_pos += unit.consumed;
            }
            if (replay_pos > 0) {
                const remain = replay.items.len - replay_pos;
                std.mem.copyForwards(u8, replay.items[0..remain], replay.items[replay_pos..]);
                replay.shrinkRetainingCapacity(remain);
            }
        }
        if (!saw_v6) fail("v5 native state replay missing");
        std.debug.print("smoke-mux: protocol-5 native state downgrade ok\n", .{});
    }
}

/// Waits for the advertised linux-dmabuf global on a scripted app socket.
fn awaitDmabufGlobal(allocator: std.mem.Allocator, app_fd: c_int) void {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    while (true) {
        var pos: usize = 0;
        while (true) {
            const h = (wlwire.parseHeader(raw.items[pos..]) catch fail("dmabuf registry header")) orelse break;
            if (raw.items[pos..].len < h.size) break;
            const body = raw.items[pos + wlwire.header_size .. pos + h.size];
            if (h.object == 2 and h.opcode == 0 and body.len >= 12) {
                const name = std.mem.readInt(u32, body[0..4], .little);
                const iface_len: usize = std.mem.readInt(u32, body[4..8], .little);
                const padded = (iface_len + 3) & ~@as(usize, 3);
                if (iface_len > 0 and 8 + padded + 4 <= body.len) {
                    const iface = body[8 .. 8 + iface_len - 1];
                    const version = std.mem.readInt(u32, body[8 + padded ..][0..4], .little);
                    if (name == 22 and version == 3 and std.mem.eql(u8, iface, "zwp_linux_dmabuf_v1")) return;
                }
            }
            pos += h.size;
        }
        if (pos > 0) {
            const rem = raw.items.len - pos;
            std.mem.copyForwards(u8, raw.items[0..rem], raw.items[pos..]);
            raw.shrinkRetainingCapacity(rem);
        }
        var chunk: [4096]u8 = undefined;
        const n = c.read(app_fd, &chunk, chunk.len);
        if (n <= 0) fail("linux-dmabuf global was not advertised");
        raw.appendSlice(allocator, chunk[0..@intCast(n)]) catch fail("oom");
    }
}

/// Waits for one Wayland event while safely skipping unrelated events.
fn awaitWaylandEvent(allocator: std.mem.Allocator, app_fd: c_int, object: u32, opcode: u16) void {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    while (true) {
        var pos: usize = 0;
        while (true) {
            const h = (wlwire.parseHeader(raw.items[pos..]) catch fail("dmabuf app event header")) orelse break;
            if (raw.items[pos..].len < h.size) break;
            if (h.object == object and h.opcode == opcode) return;
            pos += h.size;
        }
        if (pos > 0) {
            const rem = raw.items.len - pos;
            std.mem.copyForwards(u8, raw.items[0..rem], raw.items[pos..]);
            raw.shrinkRetainingCapacity(rem);
        }
        var chunk: [4096]u8 = undefined;
        const n = c.read(app_fd, &chunk, chunk.len);
        if (n <= 0) fail("dmabuf app event timed out");
        raw.appendSlice(allocator, chunk[0..@intCast(n)]) catch fail("oom");
    }
}

/// Scripted linux-dmabuf import through the daemon, including durable replay.
fn dmabufStage(allocator: std.mem.Allocator, conn: *client_mod.Conn, sock_path: []const u8) void {
    const tv = c.struct_timeval{ .tv_sec = 15, .tv_usec = 0 };
    _ = c.setsockopt(conn.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));

    const dir_end = std.mem.lastIndexOfScalar(u8, sock_path, '/').?;
    var disp_buf: [128]u8 = undefined;
    const disp_path = std.fmt.bufPrint(&disp_buf, "{s}/wl-1", .{sock_path[0..dir_end]}) catch unreachable;
    const app_fd = @import("util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (app_fd < 0) fail("dmabuf app socket");
    defer _ = c.close(app_fd);
    var addr: c.struct_sockaddr_un = undefined;
    daemon_mod.fillSockaddrUn(&addr, disp_path) catch fail("dmabuf app sockaddr");
    if (c.connect(app_fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) fail("dmabuf app connect");
    _ = c.setsockopt(app_fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));

    var mbuf: [256]u8 = undefined;
    { // get_registry(2), then prove gpu=true really exposed global 22.
        var b = wlwire.Builder.init(&mbuf, 1, 1);
        b.putNewId(2);
        const m = b.finish() catch unreachable;
        if (c.write(app_fd, m.ptr, m.len) != @as(isize, @intCast(m.len))) fail("dmabuf registry write");
        awaitDmabufGlobal(allocator, app_fd);
    }

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    inline for (.{
        .{ 1, "wl_compositor", 4, 3 },
        .{ 22, "zwp_linux_dmabuf_v1", 3, 4 },
        .{ 2, "wl_shm", 1, 8 },
    }) |bind| {
        var b = wlwire.Builder.init(&mbuf, 2, 0);
        b.putUint(bind[0]);
        b.putString(bind[1]);
        b.putUint(bind[2]);
        b.putNewId(bind[3]);
        stream.appendSlice(allocator, b.finish() catch unreachable) catch fail("oom");
    }
    {
        var b = wlwire.Builder.init(&mbuf, 4, 1); // create_params(5)
        b.putNewId(5);
        stream.appendSlice(allocator, b.finish() catch unreachable) catch fail("oom");
    }
    if (c.write(app_fd, stream.items.ptr, stream.items.len) != @as(isize, @intCast(stream.items.len))) fail("dmabuf bind write");

    const expected = [_]u8{
        0x11, 0x12, 0x13, 0xff, 0x21, 0x22, 0x23, 0xff,
        0x31, 0x32, 0x33, 0xff, 0x41, 0x42, 0x43, 0xff,
    };
    // Offset 4, 8 bytes of pixels per row, and 4 bytes of padding.
    const source = [_]u8{
        0xa0, 0xa1, 0xa2, 0xa3,
        0x11, 0x12, 0x13, 0xff,
        0x21, 0x22, 0x23, 0xff,
        0xb0, 0xb1, 0xb2, 0xb3,
        0x31, 0x32, 0x33, 0xff,
        0x41, 0x42, 0x43, 0xff,
        0xc0, 0xc1, 0xc2, 0xc3,
    };
    var tmp_buf: [128]u8 = undefined;
    const tmp_path = std.fmt.bufPrintZ(&tmp_buf, "/tmp/sketerm-mux-smoke-{d}-dmabuf", .{c.getpid()}) catch unreachable;
    const pool_fd = c.open(tmp_path.ptr, c.O_RDWR | c.O_CREAT | c.O_TRUNC, @as(c.mode_t, 0o600));
    if (pool_fd < 0) fail("dmabuf source open");
    defer _ = c.close(pool_fd);
    _ = c.unlink(tmp_path.ptr);
    if (c.write(pool_fd, &source, source.len) != source.len) fail("dmabuf source write");

    // Keep a buffer from destroyed shm pool id 6 alive, receive delete_id,
    // then legally reuse 6 for the dmabuf wl_buffer. The daemon must orphan
    // the old pool incarnation rather than rejecting the synthetic pool id.
    {
        var b = wlwire.Builder.init(&mbuf, 8, 0); // wl_shm.create_pool(6)
        b.putNewId(6);
        b.putInt(16);
        sendWithFd(app_fd, b.finish() catch unreachable, pool_fd) catch fail("dmabuf reuse pool sendmsg");
        stream.clearRetainingCapacity();
        var b2 = wlwire.Builder.init(&mbuf, 6, 0); // create_buffer(9)
        b2.putNewId(9);
        b2.putInt(0);
        b2.putInt(1);
        b2.putInt(1);
        b2.putInt(4);
        b2.putUint(1);
        stream.appendSlice(allocator, b2.finish() catch unreachable) catch fail("oom");
        var b3 = wlwire.Builder.init(&mbuf, 6, 1); // destroy pool 6
        stream.appendSlice(allocator, b3.finish() catch unreachable) catch fail("oom");
        if (c.write(app_fd, stream.items.ptr, stream.items.len) != @as(isize, @intCast(stream.items.len)))
            fail("dmabuf reuse setup");
        awaitWaylandEvent(allocator, app_fd, 1, 1); // wl_display.delete_id(6)
    }
    {
        var b = wlwire.Builder.init(&mbuf, 5, 1); // add(fd, plane 0, offset 4, stride 12, LINEAR)
        b.putUint(0);
        b.putUint(4);
        b.putUint(12);
        b.putUint(0);
        b.putUint(0);
        sendWithFd(app_fd, b.finish() catch unreachable, pool_fd) catch fail("dmabuf add sendmsg");
    }

    stream.clearRetainingCapacity();
    {
        var b = wlwire.Builder.init(&mbuf, 5, 3); // create_immed(buffer 6, 2x2 XR24)
        b.putNewId(6);
        b.putInt(2);
        b.putInt(2);
        b.putUint(wlprotocol.DRM_FORMAT_XRGB8888);
        b.putUint(0);
        stream.appendSlice(allocator, b.finish() catch unreachable) catch fail("oom");
        var b2 = wlwire.Builder.init(&mbuf, 3, 0); // create_surface(7)
        b2.putNewId(7);
        stream.appendSlice(allocator, b2.finish() catch unreachable) catch fail("oom");
        var b3 = wlwire.Builder.init(&mbuf, 7, 1); // attach(buffer 6)
        b3.putObject(6);
        b3.putInt(0);
        b3.putInt(0);
        stream.appendSlice(allocator, b3.finish() catch unreachable) catch fail("oom");
        var b4 = wlwire.Builder.init(&mbuf, 7, 2); // damage
        b4.putInt(0);
        b4.putInt(0);
        b4.putInt(2);
        b4.putInt(2);
        stream.appendSlice(allocator, b4.finish() catch unreachable) catch fail("oom");
        var b5 = wlwire.Builder.init(&mbuf, 7, 6); // commit
        stream.appendSlice(allocator, b5.finish() catch unreachable) catch fail("oom");
    }
    if (c.write(app_fd, stream.items.ptr, stream.items.len) != @as(isize, @intCast(stream.items.len))) fail("dmabuf requests write");

    // Live stream: tight pixel units must precede the relayed commit.
    var chan_id: u32 = 0;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    var saw_create = false;
    var saw_update = false;
    var saw_commit = false;
    var rounds: usize = 0;
    while (!saw_commit and rounds < 400) : (rounds += 1) {
        const f = conn.recvFrame() catch fail("dmabuf live stream read");
        defer f.deinit(allocator);
        switch (f.ftype) {
            .chan_open => {
                const open = wire.decodeChanOpen(f.payload) orelse fail("dmabuf chan_open");
                if (open.kind == .wayland_native) chan_id = open.id;
            },
            .chan_data => {
                if (chan_id == 0 or (wire.decodeChanId(f.payload) orelse 0) != chan_id) continue;
                raw.appendSlice(allocator, f.payload[4..]) catch fail("oom");
                var pos: usize = 0;
                while ((wlpipe.peelUnit(raw.items[pos..]) catch fail("dmabuf live unit")) != null) {
                    const p = (wlpipe.peelUnit(raw.items[pos..]) catch unreachable).?;
                    switch (p.unit.tag) {
                        .wl_msg => {
                            const h = (wlwire.parseHeader(p.unit.payload) catch fail("dmabuf live wl header")) orelse fail("dmabuf live wl header");
                            if (h.object == 5 and h.opcode == 3) {
                                const body = p.unit.payload[wlwire.header_size..];
                                if (body.len != 20 or std.mem.readInt(u32, body[0..4], .little) != 6 or
                                    std.mem.readInt(i32, body[4..8], .little) != 2 or
                                    std.mem.readInt(i32, body[8..12], .little) != 2 or
                                    std.mem.readInt(u32, body[12..16], .little) != wlprotocol.DRM_FORMAT_XRGB8888)
                                    fail("dmabuf create_immed metadata wrong");
                                saw_create = true;
                            }
                            if (h.object == 7 and h.opcode == 6) {
                                if (!saw_update) fail("dmabuf commit preceded pixel units");
                                saw_commit = true;
                            }
                        },
                        .pool_create => {
                            const meta = wlpipe.decodePoolMeta(p.unit.payload) orelse fail("dmabuf live pool meta");
                            if (meta.pool == 6 and meta.size != 16) fail("dmabuf live synthetic pool size");
                        },
                        .pool_update_c => {
                            const upd = wlpipe.decodePoolUpdateC(p.unit.payload) orelse fail("dmabuf live update");
                            if (upd.pool == 6) {
                                if (upd.offset != 0 or upd.body.raw_len != 16 or upd.body.row_stride != 8) fail("dmabuf live pool is not tight");
                                var pixels: [16]u8 = undefined;
                                wlpixcodec.decodeBody(upd.body, &pixels) catch fail("dmabuf live pixel decode");
                                if (!std.mem.eql(u8, &pixels, &expected)) fail("dmabuf live pixels include offset/padding");
                                saw_update = true;
                            }
                        },
                        else => {},
                    }
                    pos += p.consumed;
                }
                if (pos > 0) {
                    const rem = raw.items.len - pos;
                    std.mem.copyForwards(u8, raw.items[0..rem], raw.items[pos..]);
                    raw.shrinkRetainingCapacity(rem);
                }
            },
            else => {},
        }
    }
    if (chan_id == 0) fail("dmabuf channel never opened");
    if (!saw_create) fail("dmabuf create_immed was not relayed");
    if (!saw_update) fail("dmabuf tight pixel update missing");
    if (!saw_commit) fail("dmabuf commit was not relayed");
    awaitWaylandEvent(allocator, app_fd, 6, 0); // wl_buffer.release

    // A damage-only commit after release must not reread producer storage.
    // Poison the source and require the relayed commit to carry no pixels.
    const early_poison = [_]u8{0xdd} ** source.len;
    if (c.lseek(pool_fd, 0, c.SEEK_SET) != 0 or
        c.write(pool_fd, &early_poison, early_poison.len) != early_poison.len)
        fail("dmabuf no-attach poison");
    stream.clearRetainingCapacity();
    {
        var b = wlwire.Builder.init(&mbuf, 7, 2); // damage without attach
        b.putInt(0);
        b.putInt(0);
        b.putInt(2);
        b.putInt(2);
        stream.appendSlice(allocator, b.finish() catch unreachable) catch fail("oom");
        var b2 = wlwire.Builder.init(&mbuf, 7, 6); // commit
        stream.appendSlice(allocator, b2.finish() catch unreachable) catch fail("oom");
    }
    if (c.write(app_fd, stream.items.ptr, stream.items.len) != @as(isize, @intCast(stream.items.len)))
        fail("dmabuf no-attach commit");
    var no_attach_raw: std.ArrayList(u8) = .empty;
    defer no_attach_raw.deinit(allocator);
    var saw_no_attach_commit = false;
    rounds = 0;
    while (!saw_no_attach_commit and rounds < 400) : (rounds += 1) {
        const f = conn.recvFrame() catch fail("dmabuf no-attach stream read");
        defer f.deinit(allocator);
        if (f.ftype != .chan_data or (wire.decodeChanId(f.payload) orelse 0) != chan_id) continue;
        no_attach_raw.appendSlice(allocator, f.payload[4..]) catch fail("oom");
        var pos: usize = 0;
        while ((wlpipe.peelUnit(no_attach_raw.items[pos..]) catch fail("dmabuf no-attach unit")) != null) {
            const p = (wlpipe.peelUnit(no_attach_raw.items[pos..]) catch unreachable).?;
            if (p.unit.tag == .pool_update_c) {
                const upd = wlpipe.decodePoolUpdateC(p.unit.payload) orelse fail("dmabuf no-attach update");
                if (upd.pool == 6) fail("dmabuf reread a released buffer without attach");
            } else if (p.unit.tag == .wl_msg) {
                const h = (wlwire.parseHeader(p.unit.payload) catch fail("dmabuf no-attach header")) orelse
                    fail("dmabuf no-attach header");
                if (h.object == 7 and h.opcode == 6) saw_no_attach_commit = true;
            }
            pos += p.consumed;
        }
        if (pos > 0) {
            const rem = no_attach_raw.items.len - pos;
            std.mem.copyForwards(u8, no_attach_raw.items[0..rem], no_attach_raw.items[pos..]);
            no_attach_raw.shrinkRetainingCapacity(rem);
        }
    }
    if (!saw_no_attach_commit) fail("dmabuf no-attach commit missing");

    // Prove headless commits are captured before release and replay never
    // rereads producer storage. Detach the only viewer, commit a second image,
    // wait for release, then overwrite the source before attaching a viewer.
    conn.sendFrame(.detach, "") catch fail("dmabuf headless detach");
    (conn.recvExpect(&.{.ok}) catch fail("dmabuf headless detach ok")).deinit(allocator);
    const replay_expected = [_]u8{
        0x51, 0x52, 0x53, 0xff, 0x61, 0x62, 0x63, 0xff,
        0x71, 0x72, 0x73, 0xff, 0x81, 0x82, 0x83, 0xff,
    };
    const replay_source = [_]u8{
        0xd0, 0xd1, 0xd2, 0xd3,
        0x51, 0x52, 0x53, 0xff,
        0x61, 0x62, 0x63, 0xff,
        0xe0, 0xe1, 0xe2, 0xe3,
        0x71, 0x72, 0x73, 0xff,
        0x81, 0x82, 0x83, 0xff,
        0xf0, 0xf1, 0xf2, 0xf3,
    };
    if (c.lseek(pool_fd, 0, c.SEEK_SET) != 0 or
        c.write(pool_fd, &replay_source, replay_source.len) != replay_source.len)
        fail("dmabuf headless source update");
    stream.clearRetainingCapacity();
    {
        var b = wlwire.Builder.init(&mbuf, 7, 1); // re-attach released buffer
        b.putObject(6);
        b.putInt(0);
        b.putInt(0);
        stream.appendSlice(allocator, b.finish() catch unreachable) catch fail("oom");
        var b2 = wlwire.Builder.init(&mbuf, 7, 2); // damage
        b2.putInt(0);
        b2.putInt(0);
        b2.putInt(2);
        b2.putInt(2);
        stream.appendSlice(allocator, b2.finish() catch unreachable) catch fail("oom");
        var b3 = wlwire.Builder.init(&mbuf, 7, 6); // commit
        stream.appendSlice(allocator, b3.finish() catch unreachable) catch fail("oom");
    }
    if (c.write(app_fd, stream.items.ptr, stream.items.len) != @as(isize, @intCast(stream.items.len)))
        fail("dmabuf headless commit");
    awaitWaylandEvent(allocator, app_fd, 6, 0);
    const poison = [_]u8{0xee} ** replay_source.len;
    if (c.lseek(pool_fd, 0, c.SEEK_SET) != 0 or
        c.write(pool_fd, &poison, poison.len) != poison.len)
        fail("dmabuf post-release overwrite");

    // A fresh viewer must rebuild the tight synthetic pool before state_sync.
    var replay = client_mod.Conn.connect(allocator, sock_path) catch fail("dmabuf replay connect");
    defer replay.deinit();
    _ = c.setsockopt(replay.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
    replay.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("dmabuf replay hello");
    (replay.recvExpect(&.{.welcome}) catch fail("dmabuf replay welcome")).deinit(allocator);
    replay.sendJson(.attach, .{ .name = "smoke" }) catch fail("dmabuf replay attach");
    (replay.recvExpect(&.{.snapshot}) catch fail("dmabuf replay snapshot")).deinit(allocator);

    var replay_raw: std.ArrayList(u8) = .empty;
    defer replay_raw.deinit(allocator);
    var replay_pixels: [16]u8 = @splat(0);
    var replay_open = false;
    var replay_pool = false;
    var replay_filled: usize = 0;
    var saw_state_sync = false;
    rounds = 0;
    while (!saw_state_sync and rounds < 400) : (rounds += 1) {
        const f = replay.recvFrame() catch fail("dmabuf replay stream read");
        defer f.deinit(allocator);
        switch (f.ftype) {
            .chan_open => {
                const open = wire.decodeChanOpen(f.payload) orelse fail("dmabuf replay chan_open");
                if (open.kind == .wayland_native and open.id == chan_id) replay_open = true;
            },
            .chan_data => {
                if ((wire.decodeChanId(f.payload) orelse 0) != chan_id) continue;
                replay_raw.appendSlice(allocator, f.payload[4..]) catch fail("oom");
                var pos: usize = 0;
                while ((wlpipe.peelUnit(replay_raw.items[pos..]) catch fail("dmabuf replay unit")) != null) {
                    const p = (wlpipe.peelUnit(replay_raw.items[pos..]) catch unreachable).?;
                    switch (p.unit.tag) {
                        .pool_create => {
                            const meta = wlpipe.decodePoolMeta(p.unit.payload) orelse fail("dmabuf replay pool meta");
                            if (meta.pool == 6) {
                                if (meta.size != 16) fail("dmabuf replay synthetic pool is not tight");
                                replay_pool = true;
                            }
                        },
                        .pool_update_c => {
                            const upd = wlpipe.decodePoolUpdateC(p.unit.payload) orelse fail("dmabuf replay update");
                            if (upd.pool == 6) {
                                const offset: usize = @intCast(upd.offset);
                                const len: usize = @intCast(upd.body.raw_len);
                                if (!replay_pool or offset + len > replay_pixels.len) fail("dmabuf replay update bounds/order");
                                wlpixcodec.decodeBody(upd.body, replay_pixels[offset..][0..len]) catch fail("dmabuf replay pixel decode");
                                replay_filled += len;
                            }
                        },
                        .state_sync => {
                            if (!replay_pool or replay_filled != 16 or !std.mem.eql(u8, &replay_pixels, &replay_expected))
                                fail("dmabuf replay pixels were not rebuilt before state_sync");
                            saw_state_sync = true;
                        },
                        else => {},
                    }
                    pos += p.consumed;
                }
                if (pos > 0) {
                    const rem = replay_raw.items.len - pos;
                    std.mem.copyForwards(u8, replay_raw.items[0..rem], replay_raw.items[pos..]);
                    replay_raw.shrinkRetainingCapacity(rem);
                }
            },
            else => {},
        }
    }
    if (!replay_open) fail("dmabuf replay channel missing");
    if (!saw_state_sync) fail("dmabuf replay state_sync missing");
    replay.sendFrame(.detach, "") catch fail("dmabuf replay detach");
    (replay.recvExpect(&.{.ok}) catch fail("dmabuf replay detach ok")).deinit(allocator);
    conn.sendJson(.attach, .{ .name = "smoke" }) catch fail("dmabuf restore original viewer");
    (conn.recvExpect(&.{.snapshot}) catch fail("dmabuf restore original snapshot")).deinit(allocator);

    std.debug.print("smoke-mux: linux-dmabuf id reuse + tight pre-release headless replay ok\n", .{});
}

/// The real-client milestone: a stock Wayland app (weston-terminal)
/// spawned in a native-pipe session, with the wlhost Compositor on
/// this end answering the protocol. Pass = a committed toplevel
/// frame with plausible dimensions reaches the view. Skipped when
/// weston-terminal isn't installed.
fn realAppStage(allocator: std.mem.Allocator, sock_path: []const u8) bool {
    if (c.access("/usr/bin/weston-terminal", c.X_OK) != 0) {
        std.debug.print("smoke-mux: real-app stage SKIPPED (no weston-terminal)\n", .{});
        return false;
    }
    const compositor_mod = @import("wlhost/compositor.zig");

    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("app-stage connect");
    // The durability step below deinits this conn EXPLICITLY (drop
    // without detach); the deferred call must not run a second time.
    var conn_alive = true;
    defer if (conn_alive) conn.deinit();
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
        fn onFrame(ctx: ?*anyopaque, surface: u32, fw: i32, fh: i32, scale: i32, lw: i32, lh: i32, format: u32, pixels: []const u8) void {
            _ = lw;
            _ = lh;
            _ = ctx;
            _ = scale;
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

    // Proto v5: this compositor is a passive REPLICA — the daemon
    // brain answers the app; replica output is discarded and input
    // travels as seat-intent units.
    var comp = compositor_mod.Compositor.init(allocator, .{
        .toplevel_frame = ViewState.onFrame,
    }) catch fail("compositor init");
    comp.lenient = true;
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
                comp.clearOut(); // replica output is DISCARDED (v5)
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

    // Keyboard input through the full pipe, v5 style: seat-intent
    // units toward the daemon brain; expect echo redraws (frames).
    const frames_before_input = ViewState.frames;
    {
        const pipe_mod = @import("wlhost/pipe.zig");
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(allocator);
        pipe_mod.appendSeatKbdEnter(&units, allocator, ViewState.sid) catch fail("oom");
        pipe_mod.appendSeatMods(&units, allocator, 0, 0, 0, 0) catch fail("oom");
        for ([_]u32{ 38, 31 }) |key| { // evdev l, s
            pipe_mod.appendSeatKey(&units, allocator, key, true) catch fail("oom");
            pipe_mod.appendSeatKey(&units, allocator, key, false) catch fail("oom");
        }
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, chan_id, .little);
        payload.appendSlice(allocator, &idb) catch fail("oom");
        payload.appendSlice(allocator, units.items) catch fail("oom");
        conn.sendFrame(.chan_data, payload.items) catch fail("input chan send");
    }
    rounds = 0;
    while (ViewState.frames == frames_before_input and rounds < 2000) : (rounds += 1) {
        const f = conn.recvFrame() catch fail("input echo read (timeout = keys never echoed)");
        defer f.deinit(allocator);
        if (f.ftype != .chan_data) continue;
        if ((wire.decodeChanId(f.payload) orelse 0) != chan_id) continue;
        comp.feed(f.payload[4..]) catch fail("compositor feed (input)");
        comp.clearOut();
        if (comp.dead) fail("protocol error after input injection");
    }
    if (ViewState.frames == frames_before_input) fail("typed keys never produced a redraw");
    std.debug.print("smoke-mux: input echo ok ({d} frames after typing)\n", .{ViewState.frames});

    // ── durability: the app must survive this client dying ──────
    // Drop the connection WITHOUT detaching (a GUI crash), then
    // reattach fresh: the daemon replays chan_open + pool bytes +
    // state_sync, and the replica's windows come back with pixels.
    conn.deinit();
    conn_alive = false;
    var conn2 = client_mod.Conn.connect(allocator, sock_path) catch fail("reattach connect");
    defer conn2.deinit();
    const tv2 = c.struct_timeval{ .tv_sec = 20, .tv_usec = 0 };
    _ = c.setsockopt(conn2.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv2, @sizeOf(c.struct_timeval));
    conn2.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("reattach hello");
    (conn2.recvExpect(&.{.welcome}) catch fail("reattach welcome")).deinit(allocator);
    conn2.sendJson(.attach, .{ .name = "wlapp" }) catch fail("reattach attach");

    var comp2 = compositor_mod.Compositor.init(allocator, .{
        .toplevel_frame = ViewState.onFrame,
    }) catch fail("replica2 init");
    comp2.lenient = true;
    defer comp2.deinit();
    ViewState.frames = 0;
    ViewState.nonzero_px = false;
    var chan2: u32 = 0;
    rounds = 0;
    while (ViewState.frames == 0 and rounds < 2000) : (rounds += 1) {
        const f = conn2.recvFrame() catch fail("reattach stream read (timeout = no replay)");
        defer f.deinit(allocator);
        switch (f.ftype) {
            .chan_open => {
                const open = wire.decodeChanOpen(f.payload) orelse fail("reattach chan_open");
                if (open.kind == .wayland_native) chan2 = open.id;
            },
            .chan_data => {
                if ((wire.decodeChanId(f.payload) orelse 0) != chan2) continue;
                comp2.feed(f.payload[4..]) catch fail("replica2 feed");
                comp2.clearOut();
                if (comp2.dead) fail("replica2 protocol error during replay");
            },
            .exit => fail("app died when its client went away (durability regression)"),
            else => {},
        }
    }
    if (ViewState.frames == 0) fail("reattach never replayed a frame (state_sync missing?)");
    if (!ViewState.nonzero_px) fail("replayed frame is all zeros");
    if (ViewState.w < 100 or ViewState.h < 100) fail("replayed frame has implausible size");
    std.debug.print("smoke-mux: durable reattach ok ({d}x{d} replayed)\n", .{ ViewState.w, ViewState.h });

    // Tear the session down; the daemon must survive the app dying.
    conn2.sendJson(.kill, .{ .name = "wlapp" }) catch fail("app-stage kill");
    return true;
}

/// Window-stream pipeline (the macOS-apps-on-Linux transport) with
/// the stub capture source: spawn an app session, expect win_open +
/// frames on a winstream channel, send a key, expect the tint to
/// change (input round-trip).
fn winstreamStage(allocator: std.mem.Allocator, sock_path: []const u8) void {
    const wsproto = @import("winstream/proto.zig");

    // This stage asserts the STUB test pattern; on macOS builds
    // with the ScreenCaptureKit backend, the winstream session
    // would otherwise capture for real. Scoped to this stage —
    // a process-wide value would steal the Wayland hub from the
    // earlier app sessions (winstream excludes wayland).
    _ = c.setenv("SKETERM_WINSTREAM", "stub", 1);
    defer _ = c.setenv("SKETERM_WINSTREAM", "off", 1); // restore the suite default

    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("ws connect");
    defer conn.deinit();
    const tv = c.struct_timeval{ .tv_sec = 15, .tv_usec = 0 };
    _ = c.setsockopt(conn.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("ws hello");
    (conn.recvExpect(&.{.welcome}) catch fail("ws welcome")).deinit(allocator);
    conn.sendJson(.spawn, .{
        .name = "wsapp",
        .argv = [_][]const u8{ "/bin/sleep", "60" },
        .rows = @as(u16, 10),
        .cols = @as(u16, 40),
        .app = true,
        .winstream = true,
    }) catch fail("ws spawn");
    (conn.recvExpect(&.{.ok}) catch fail("ws spawn ok")).deinit(allocator);
    conn.sendJson(.attach, .{ .name = "wsapp" }) catch fail("ws attach");

    var chan_id: u32 = 0;
    var saw_open = false;
    var tint_before: ?u8 = null;
    var tint_after: ?u8 = null;
    var sent_key = false;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    var rounds: usize = 0;
    while (tint_after == null and rounds < 600) : (rounds += 1) {
        const f = conn.recvFrame() catch fail("ws stream read");
        defer f.deinit(allocator);
        switch (f.ftype) {
            .chan_open => {
                const open = wire.decodeChanOpen(f.payload) orelse fail("ws chan_open");
                if (open.kind != .winstream) fail("ws channel kind");
                chan_id = open.id;
            },
            .chan_data => {
                if ((wire.decodeChanId(f.payload) orelse 0) != chan_id) continue;
                raw.appendSlice(allocator, f.payload[4..]) catch fail("oom");
                var pos: usize = 0;
                while ((wsproto.peelUnit(raw.items[pos..]) catch fail("ws unit")) != null) {
                    const p = (wsproto.peelUnit(raw.items[pos..]) catch unreachable).?;
                    switch (p.unit.tag) {
                        .win_open => {
                            const wo = wsproto.decodeWinOpen(p.unit.payload) orelse fail("ws open dec");
                            if (wo.w != 320 or wo.h != 240) fail("ws open size");
                            saw_open = true;
                        },
                        .win_frame_c => {
                            const fc = wsproto.decodeWinFrameC(p.unit.payload) orelse fail("ws frame_c dec");
                            const scratch = allocator.alloc(u8, fc.body.raw_len) catch fail("oom");
                            defer allocator.free(scratch);
                            wlpixcodec.decodeBody(fc.body, scratch) catch fail("ws frame_c decode");
                            const red = scratch[2];
                            if (!sent_key) {
                                tint_before = red;
                            } else if (red != tint_before.?) {
                                tint_after = red;
                            }
                        },
                        else => {},
                    }
                    pos += p.consumed;
                }
                const rem = raw.items.len - pos;
                std.mem.copyForwards(u8, raw.items[0..rem], raw.items[pos..]);
                raw.shrinkRetainingCapacity(rem);
                if (saw_open and tint_before != null and !sent_key) {
                    sent_key = true;
                    var ub: std.ArrayList(u8) = .empty;
                    defer ub.deinit(allocator);
                    var idb: [4]u8 = undefined;
                    std.mem.writeInt(u32, &idb, chan_id, .little);
                    ub.appendSlice(allocator, &idb) catch fail("oom");
                    wsproto.appendInputKey(&ub, allocator, .{ .win = 1, .key = 30, .pressed = true, .mods = 0 }) catch fail("oom");
                    conn.sendFrame(.chan_data, ub.items) catch fail("ws key send");
                }
            },
            else => {},
        }
    }
    if (!saw_open) fail("winstream window never opened");
    if (tint_after == null) fail("winstream input never changed the frame");
    conn.sendJson(.kill, .{ .name = "wsapp" }) catch fail("ws kill");
    std.debug.print("smoke-mux: winstream stub round-trip ok\n", .{});
}

/// The snapshot header's app byte: an attaching client must be able to
/// tell a forwarded GUI app (`sketerm app`, spawn app=true) from a plain
/// shell session, so it can hold the pane open on app exit. Proto v4
/// widened the header to [seq:u64][app:u8].
fn appFlagStage(allocator: std.mem.Allocator, sock_path: []const u8) void {
    const cases = [_]struct { name: []const u8, app: bool }{
        .{ .name = "flag-app", .app = true },
        .{ .name = "flag-shell", .app = false },
    };
    for (cases) |cse| {
        var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("flag connect");
        defer conn.deinit();
        conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("flag hello");
        (conn.recvExpect(&.{.welcome}) catch fail("flag welcome")).deinit(allocator);
        conn.sendJson(.spawn, .{
            .name = cse.name,
            .argv = [_][]const u8{ "/bin/sleep", "60" },
            .rows = @as(u16, 10),
            .cols = @as(u16, 40),
            .app = cse.app,
        }) catch fail("flag spawn");
        (conn.recvExpect(&.{.ok}) catch fail("flag spawn ok")).deinit(allocator);
        conn.sendJson(.attach, .{ .name = cse.name }) catch fail("flag attach");
        const snap = conn.recvExpect(&.{.snapshot}) catch fail("flag snapshot");
        defer snap.deinit(allocator);
        if (snap.payload.len < 9) fail("flag snapshot header too short");
        const want: u8 = if (cse.app) 1 else 0;
        if (snap.payload[8] != want) fail("flag snapshot app byte wrong");
        conn.sendJson(.kill, .{ .name = cse.name }) catch fail("flag kill");
    }
    std.debug.print("smoke-mux: snapshot app-flag header ok\n", .{});
}

/// Headless + durable apps (proto v5): the daemon brain must answer
/// an app with ZERO clients attached; a later attach must replay
/// chan_open + pool bytes + state_sync so a replica rebuilds the
/// window with pixels; and the app must survive its client dying.
fn pendingAppStage(allocator: std.mem.Allocator, sock_path: []const u8, wl_id: usize) void {
    const compositor_mod = @import("wlhost/compositor.zig");
    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("pend connect");
    defer conn.deinit();
    const tv = c.struct_timeval{ .tv_sec = 15, .tv_usec = 0 };
    _ = c.setsockopt(conn.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("pend hello");
    (conn.recvExpect(&.{.welcome}) catch fail("pend welcome")).deinit(allocator);
    conn.sendJson(.spawn, .{
        .name = "pend",
        .argv = [_][]const u8{ "/bin/sleep", "60" },
        .rows = @as(u16, 10),
        .cols = @as(u16, 40),
    }) catch fail("pend spawn");
    (conn.recvExpect(&.{.ok}) catch fail("pend spawn ok")).deinit(allocator);

    // The scripted app connects BEFORE anyone attached and runs the
    // full xdg dance. The daemon brain must answer immediately.
    const dir_end = std.mem.lastIndexOfScalar(u8, sock_path, '/').?;
    var disp_buf: [128]u8 = undefined;
    const disp = std.fmt.bufPrint(&disp_buf, "{s}/wl-{d}", .{ sock_path[0..dir_end], wl_id }) catch unreachable;
    const app_fd = @import("util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    var addr: c.struct_sockaddr_un = undefined;
    daemon_mod.fillSockaddrUn(&addr, disp) catch fail("pend sockaddr");
    if (c.connect(app_fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) fail("pend app connect");
    defer _ = c.close(app_fd);
    _ = c.setsockopt(app_fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));

    var mbuf: [256]u8 = undefined;
    { // get_registry(2) — globals must come back with NO client attached
        var b = wlwire.Builder.init(&mbuf, 1, 1);
        b.putNewId(2);
        const m = b.finish() catch unreachable;
        if (c.write(app_fd, m.ptr, m.len) != @as(isize, @intCast(m.len))) fail("pend app write");
        var got: [512]u8 = undefined;
        const r = c.read(app_fd, &got, got.len);
        if (r <= 0) fail("brain never answered a client-less app (headless regression)");
        const h = (wlwire.parseHeader(got[0..@intCast(r)]) catch fail("pend global hdr")) orelse fail("pend global hdr");
        if (h.object != 2 or h.opcode != 0) fail("expected wl_registry.global from the brain");
    }
    std.debug.print("smoke-mux: headless brain answered pre-attach ok\n", .{});

    // Bind + surface + toplevel + title + pixels (2x2, values 100..115).
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    inline for (.{
        .{ 1, "wl_compositor", 4, 3 },
        .{ 2, "wl_shm", 1, 4 },
        .{ 5, "xdg_wm_base", 2, 5 },
    }) |bind| {
        var b = wlwire.Builder.init(&mbuf, 2, 0);
        b.putUint(bind[0]);
        b.putString(bind[1]);
        b.putUint(bind[2]);
        b.putNewId(bind[3]);
        stream.appendSlice(allocator, b.finish() catch unreachable) catch fail("oom");
    }
    {
        var b = wlwire.Builder.init(&mbuf, 3, 0); // create_surface(6)
        b.putNewId(6);
        stream.appendSlice(allocator, b.finish() catch unreachable) catch fail("oom");
        var b2 = wlwire.Builder.init(&mbuf, 5, 2); // get_xdg_surface(7, 6)
        b2.putNewId(7);
        b2.putObject(6);
        stream.appendSlice(allocator, b2.finish() catch unreachable) catch fail("oom");
        var b3 = wlwire.Builder.init(&mbuf, 7, 1); // get_toplevel(8)
        b3.putNewId(8);
        stream.appendSlice(allocator, b3.finish() catch unreachable) catch fail("oom");
        var b4 = wlwire.Builder.init(&mbuf, 8, 2); // set_title("DUR")
        b4.putString("DUR");
        stream.appendSlice(allocator, b4.finish() catch unreachable) catch fail("oom");
        var b5 = wlwire.Builder.init(&mbuf, 6, 6); // commit (xdg dance)
        stream.appendSlice(allocator, b5.finish() catch unreachable) catch fail("oom");
    }
    if (c.write(app_fd, stream.items.ptr, stream.items.len) != @as(isize, @intCast(stream.items.len))) fail("pend dance write");

    // Pool + buffer + attach + commit (pool fd via SCM_RIGHTS).
    var pool_bytes: [16]u8 = undefined;
    for (&pool_bytes, 0..) |*bt, i| bt.* = @intCast(i + 100);
    var tmp_buf: [128]u8 = undefined;
    const tmp_path = std.fmt.bufPrintZ(&tmp_buf, "/tmp/sketerm-mux-smoke-{d}-pend", .{c.getpid()}) catch unreachable;
    const pool_fd = c.open(tmp_path.ptr, c.O_RDWR | c.O_CREAT | c.O_TRUNC, @as(c.mode_t, 0o600));
    if (pool_fd < 0) fail("pend pool open");
    _ = c.unlink(tmp_path.ptr);
    if (c.write(pool_fd, &pool_bytes, pool_bytes.len) != pool_bytes.len) fail("pend pool write");
    {
        var b = wlwire.Builder.init(&mbuf, 4, 0); // create_pool(9, fd, 16)
        b.putNewId(9);
        b.putInt(16);
        sendWithFd(app_fd, b.finish() catch unreachable, pool_fd) catch fail("pend pool sendmsg");
        _ = c.close(pool_fd);
    }
    stream.clearRetainingCapacity();
    {
        var b = wlwire.Builder.init(&mbuf, 9, 0); // create_buffer(10, 0, 2x2, 8, xrgb)
        b.putNewId(10);
        b.putInt(0);
        b.putInt(2);
        b.putInt(2);
        b.putInt(8);
        b.putUint(1);
        stream.appendSlice(allocator, b.finish() catch unreachable) catch fail("oom");
        var b2 = wlwire.Builder.init(&mbuf, 6, 1); // attach(10)
        b2.putObject(10);
        b2.putInt(0);
        b2.putInt(0);
        stream.appendSlice(allocator, b2.finish() catch unreachable) catch fail("oom");
        var b3 = wlwire.Builder.init(&mbuf, 6, 6); // commit
        stream.appendSlice(allocator, b3.finish() catch unreachable) catch fail("oom");
    }
    if (c.write(app_fd, stream.items.ptr, stream.items.len) != @as(isize, @intCast(stream.items.len))) fail("pend pixels write");
    _ = c.usleep(150_000); // let the daemon drain the app socket

    // Shared replica view: records what replay reconstructs.
    const RView = struct {
        var toplevels: usize = 0;
        var frames: usize = 0;
        var w: i32 = 0;
        var h: i32 = 0;
        var px0: u8 = 0;
        var title_buf: [64]u8 = undefined;
        var title_len: usize = 0;
        fn onNew(ctx: ?*anyopaque, surface: u32) void {
            _ = ctx;
            _ = surface;
            toplevels += 1;
        }
        fn onTitle(ctx: ?*anyopaque, surface: u32, title: []const u8) void {
            _ = ctx;
            _ = surface;
            title_len = @min(title.len, title_buf.len);
            @memcpy(title_buf[0..title_len], title[0..title_len]);
        }
        fn onFrame(ctx: ?*anyopaque, surface: u32, fw: i32, fh: i32, scale: i32, lw: i32, lh: i32, format: u32, pixels: []const u8) void {
            _ = lw;
            _ = lh;
            _ = ctx;
            _ = surface;
            _ = scale;
            _ = format;
            frames += 1;
            w = fw;
            h = fh;
            if (pixels.len > 0) px0 = pixels[0];
        }
        fn reset() void {
            toplevels = 0;
            frames = 0;
            w = 0;
            h = 0;
            px0 = 0;
            title_len = 0;
        }
    };

    // Attach viewer #1: replay must rebuild the window + pixels.
    RView.reset();
    conn.sendJson(.attach, .{ .name = "pend" }) catch fail("pend attach");
    {
        var replica = compositor_mod.Compositor.init(allocator, .{
            .toplevel_new = RView.onNew,
            .toplevel_title = RView.onTitle,
            .toplevel_frame = RView.onFrame,
        }) catch fail("pend replica init");
        replica.lenient = true;
        defer replica.deinit();
        var chan_id: u32 = 0;
        var rounds: usize = 0;
        while (RView.frames == 0 and rounds < 400) : (rounds += 1) {
            const f = conn.recvFrame() catch fail("pend replay read (state_sync missing?)");
            defer f.deinit(allocator);
            switch (f.ftype) {
                .chan_open => {
                    const open = wire.decodeChanOpen(f.payload) orelse fail("pend chan_open");
                    if (open.kind == .wayland_native) chan_id = open.id;
                },
                .chan_data => {
                    if ((wire.decodeChanId(f.payload) orelse 0) != chan_id) continue;
                    replica.feed(f.payload[4..]) catch fail("pend replica feed");
                    replica.clearOut();
                    if (replica.dead) fail("pend replica protocol error");
                },
                else => {},
            }
        }
        if (RView.toplevels != 1) fail("replay did not rebuild the toplevel");
        if (!std.mem.eql(u8, RView.title_buf[0..RView.title_len], "DUR")) fail("replay lost the title");
        if (RView.w != 2 or RView.h != 2) fail("replayed frame size wrong");
        if (RView.px0 != 100) fail("replayed pixels wrong");
    }
    std.debug.print("smoke-mux: attach replay rebuilt window + pixels ok\n", .{});

    // Viewer dies WITHOUT detaching (GUI crash). The app must stay
    // alive: a title change afterwards must be accepted and visible
    // to the NEXT viewer's state_sync.
    _ = c.close(conn.fd);
    conn.fd = -1;
    _ = c.usleep(150_000); // let the daemon reap the client
    {
        var b = wlwire.Builder.init(&mbuf, 8, 2); // set_title("AGAIN")
        b.putString("AGAIN");
        const m = b.finish() catch unreachable;
        if (c.write(app_fd, m.ptr, m.len) != @as(isize, @intCast(m.len))) fail("app died with its viewer (durability regression)");
    }
    _ = c.usleep(150_000);

    var conn2 = client_mod.Conn.connect(allocator, sock_path) catch fail("pend reconnect");
    defer conn2.deinit();
    _ = c.setsockopt(conn2.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
    conn2.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("pend hello2");
    (conn2.recvExpect(&.{.welcome}) catch fail("pend welcome2")).deinit(allocator);
    RView.reset();
    conn2.sendJson(.attach, .{ .name = "pend" }) catch fail("pend attach2");
    {
        var replica = compositor_mod.Compositor.init(allocator, .{
            .toplevel_new = RView.onNew,
            .toplevel_title = RView.onTitle,
            .toplevel_frame = RView.onFrame,
        }) catch fail("pend replica2 init");
        replica.lenient = true;
        defer replica.deinit();
        var chan_id: u32 = 0;
        var rounds: usize = 0;
        while (RView.frames == 0 and rounds < 400) : (rounds += 1) {
            const f = conn2.recvFrame() catch fail("pend replay2 read");
            defer f.deinit(allocator);
            switch (f.ftype) {
                .chan_open => {
                    const open = wire.decodeChanOpen(f.payload) orelse fail("pend chan_open2");
                    if (open.kind == .wayland_native) chan_id = open.id;
                },
                .chan_data => {
                    if ((wire.decodeChanId(f.payload) orelse 0) != chan_id) continue;
                    replica.feed(f.payload[4..]) catch fail("pend replica2 feed");
                    replica.clearOut();
                    if (replica.dead) fail("pend replica2 protocol error");
                },
                else => {},
            }
        }
        if (RView.toplevels != 1) fail("post-crash replay did not rebuild the toplevel");
        if (!std.mem.eql(u8, RView.title_buf[0..RView.title_len], "AGAIN")) fail("post-crash title change lost (app not durable)");
        if (RView.w != 2 or RView.h != 2 or RView.px0 != 100) fail("post-crash pixels wrong");
    }
    std.debug.print("smoke-mux: durable headless app survived viewer crash ok\n", .{});

    // Multi-viewer fan-out: with a SECOND live viewer attached, a
    // fresh app request must reach BOTH viewers' unit streams.
    var conn3 = client_mod.Conn.connect(allocator, sock_path) catch fail("pend third connect");
    defer conn3.deinit();
    _ = c.setsockopt(conn3.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
    conn3.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("pend hello3");
    (conn3.recvExpect(&.{.welcome}) catch fail("pend welcome3")).deinit(allocator);
    conn3.sendJson(.attach, .{ .name = "pend" }) catch fail("pend attach3");
    var needle_buf: [32]u8 = undefined;
    const needle = blk: {
        var b = wlwire.Builder.init(&needle_buf, 8, 2); // set_title("BOTH")
        b.putString("BOTH");
        break :blk b.finish() catch unreachable;
    };
    if (c.write(app_fd, needle.ptr, needle.len) != @as(isize, @intCast(needle.len))) fail("pend title3 write");
    inline for (.{ &conn2, &conn3 }, 0..) |cn, viewer| {
        var seen = false;
        var acc: std.ArrayList(u8) = .empty;
        defer acc.deinit(allocator);
        var rounds: usize = 0;
        while (!seen and rounds < 400) : (rounds += 1) {
            const f = cn.recvFrame() catch fail("fan-out read (viewer starved)");
            defer f.deinit(allocator);
            if (f.ftype != .chan_data) continue;
            acc.appendSlice(allocator, f.payload[4..]) catch fail("oom");
            seen = std.mem.indexOf(u8, acc.items, needle) != null;
        }
        if (!seen) {
            std.debug.print("smoke-mux: viewer {d} never saw the fan-out unit\n", .{viewer});
            fail("fan-out: a live viewer missed a broadcast unit");
        }
    }
    conn2.sendJson(.kill, .{ .name = "pend" }) catch fail("pend kill");
    std.debug.print("smoke-mux: two-viewer fan-out ok\n", .{});
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
fn recvWithFd(sock: c_int) ?struct { fd: c_int, obj: u32 = 0, opcode: u16 = 0 } {
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
    // Parse the message header so callers can assert object/opcode.
    var obj: u32 = 0;
    var opcode: u16 = 0;
    if (r >= wlwire.header_size) {
        if (wlwire.parseHeader(data[0..@intCast(r)]) catch null) |h| {
            obj = h.object;
            opcode = h.opcode;
        }
    }
    const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
    var off: usize = 0;
    const clen: usize = @intCast(mh.msg_controllen);
    while (off + hdr_size <= clen) {
        const hdr: *const c.struct_cmsghdr = @ptrCast(@alignCast(cbuf[off..].ptr));
        const cl: usize = @intCast(hdr.cmsg_len);
        if (cl < hdr_size or off + cl > clen) break;
        if (hdr.cmsg_level == c.SOL_SOCKET and hdr.cmsg_type == c.SCM_RIGHTS) {
            var fd: c_int = undefined;
            @memcpy(std.mem.asBytes(&fd), cbuf[off + hdr_size ..][0..@sizeOf(c_int)]);
            return .{ .fd = fd, .obj = obj, .opcode = opcode };
        }
        off += (cl + @sizeOf(usize) - 1) & ~@as(usize, @sizeOf(usize) - 1);
    }
    return .{ .fd = -1, .obj = obj, .opcode = opcode };
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
    // CMSG_SPACE(sizeof(int)): cmsg alignment is 8 on Linux (16-byte
    // header), 4 on Darwin (12-byte header, and XNU rejects a
    // controllen that overshoots the aligned length).
    const cmsg_align: usize = if (@import("builtin").os.tag == .macos) 4 else 8;
    mh.msg_controllen = @intCast(std.mem.alignForward(usize, hdr_size + @sizeOf(c_int), cmsg_align));
    if (c.sendmsg(sock, &mh, 0) != @as(isize, @intCast(bytes.len))) return error.SendFailed;
}

fn daemonMain(d: *daemon_mod.Daemon) void {
    d.run() catch |err| {
        std.debug.print("smoke-mux: daemon error: {s}\n", .{@errorName(err)});
    };
}

/// Isolated app session (`sketerm app -i`): the child must run under a
/// private XDG_RUNTIME_DIR with the inherited D-Bus session bus dropped,
/// and that dir — contents and all — must be recursively removed when
/// the session dies. Exercises spawnSession's isolation path and the
/// removeTreeBestEffort recursion.
fn isolatedStage(allocator: std.mem.Allocator, sock_path: []const u8) void {
    const pathZ = @import("util/pathz.zig").pathZ;
    // Seed a bogus session bus so "dropped" is observable, not merely
    // "was already unset". The forked child unsets it; this process
    // keeps it (nothing here reads DBUS).
    _ = c.setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/tmp/iso-fake-bus", 1);

    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("iso connect");
    defer conn.deinit();
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("iso hello");
    (conn.recvExpect(&.{.welcome}) catch fail("iso welcome")).deinit(allocator);

    conn.sendJson(.spawn, .{
        .name = "iso",
        .argv = [_][]const u8{"/bin/sh"},
        .rows = @as(u16, 10),
        .cols = @as(u16, 80),
        .app = true,
        .isolated = true,
    }) catch fail("iso spawn send");
    (conn.recvExpect(&.{.ok}) catch fail("iso spawn ok")).deinit(allocator);

    var mirror = Mirror{ .allocator = allocator, .pool = allocator.create(Pool) catch fail("iso pool") };
    mirror.pool.* = Pool.init(allocator) catch fail("iso pool init");
    defer {
        if (mirror.screen) |s| s.deinit();
        mirror.pool.deinit();
        allocator.destroy(mirror.pool);
    }
    conn.sendJson(.attach, .{ .name = "iso" }) catch fail("iso attach");
    const snap = conn.recvExpect(&.{.snapshot}) catch fail("iso snapshot");
    mirror.applySnapshot(snap.payload) catch fail("iso snapshot apply");
    snap.deinit(allocator);

    // Drop a file + subdir under the private runtime dir so teardown
    // has a tree to recurse through, then echo the env we ended up with.
    conn.sendFrame(.input, "mkdir -p \"$XDG_RUNTIME_DIR/sub\" && : > \"$XDG_RUNTIME_DIR/sub/f\" && : > \"$XDG_RUNTIME_DIR/g\"; " ++
        "echo \"RT=$XDG_RUNTIME_DIR DB=${DBUS_SESSION_BUS_ADDRESS:-none}\"\n") catch fail("iso input");

    var rt_path: ?[]u8 = null;
    defer if (rt_path) |p| allocator.free(p);
    var deadline: usize = 0;
    while (deadline < 200) : (deadline += 1) {
        const f = conn.recvFrame() catch fail("iso stream read");
        defer f.deinit(allocator);
        if (f.ftype == .events) mirror.applyEvents(f.payload) catch fail("iso events apply");
        const txt = mirror.screenText() catch fail("iso extract");
        defer allocator.free(txt);
        // Match "RT=/" so we catch the OUTPUT line (expanded path), not
        // the echoed command (which carries the literal "$XDG_...").
        const at = std.mem.indexOf(u8, txt, "RT=/") orelse continue;
        const rest = txt[at + 3 ..];
        const end = std.mem.indexOfAny(u8, rest, " \n") orelse continue;
        // The parent's shared bus must never leak into the child.
        // App sessions get a PRIVATE a11y bus (DB=.../dbus-...) when
        // dbus-daemon exists, else the bus is dropped (DB=none) — both
        // isolate; only the inherited /tmp/iso-fake-bus is a failure.
        if (std.mem.indexOf(u8, txt, "iso-fake-bus") != null) fail("iso: shared D-Bus bus leaked into child");
        rt_path = allocator.dupe(u8, rest[0..end]) catch fail("iso oom");
        break;
    }
    const rtp = rt_path orelse fail("iso: env line never appeared");
    if (std.mem.indexOf(u8, rtp, "/rt-") == null) fail("iso: runtime dir not a private rt- path");

    // Private dir + contents exist on disk while the session lives.
    var z_buf: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    if (c.stat(pathZ(&z_buf, rtp) catch fail("iso pathz"), &st) != 0)
        fail("iso: private runtime dir missing while session alive");
    if (st.st_mode & c.S_IFDIR == 0) fail("iso: runtime dir is not a directory");

    // Kill → the daemon recursively removes the dir (g + sub/f + sub).
    conn.sendJson(.kill, .{ .name = "iso" }) catch fail("iso kill");
    (conn.recvExpect(&.{.ok}) catch fail("iso kill ok")).deinit(allocator);
    var gone = false;
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        if (c.stat(pathZ(&z_buf, rtp) catch break, &st) != 0) {
            gone = true;
            break;
        }
        _ = c.usleep(20_000);
    }
    if (!gone) fail("iso: private runtime dir not removed on teardown");

    std.debug.print("smoke-mux: isolated session env + recursive dir cleanup ok\n", .{});
}

/// Stream a file to the attached "smoke" session over the file_*
/// frames and verify it lands on disk in the shell's cwd — plus the
/// daemon's non-clobber rename on a repeated name.
fn uploadStage(allocator: std.mem.Allocator, conn: *client_mod.Conn, mirror: *Mirror) void {
    const pathZ = @import("util/pathz.zig").pathZ;
    var z_buf: [4096]u8 = undefined;
    var dir_buf: [128]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "/tmp/sketerm-mux-smoke-{d}-up", .{c.getpid()}) catch unreachable;
    _ = c.mkdir(pathZ(&z_buf, dir) catch fail("up mkdir pathz"), 0o700);

    // Move the shell into the temp dir; wait for the echo to confirm
    // chdir ran (so /proc/<pid>/cwd is updated before we upload).
    var cmd_buf: [256]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "cd {s} && echo UPCWDOK\n", .{dir}) catch unreachable;
    conn.sendFrame(.input, cmd) catch fail("up cd send");
    var deadline: usize = 0;
    var cd_ok = false;
    while (deadline < 200) : (deadline += 1) {
        const f = conn.recvFrame() catch fail("up cd stream");
        defer f.deinit(allocator);
        if (f.ftype == .events) mirror.applyEvents(f.payload) catch fail("up events apply");
        const txt = mirror.screenText() catch fail("up extract");
        defer allocator.free(txt);
        if (std.mem.count(u8, txt, "UPCWDOK") >= 2) {
            cd_ok = true;
            break;
        }
    }
    if (!cd_ok) fail("up: cd confirmation never appeared");

    const contents = "hello sketerm upload\n";

    // file_open → "ready".
    conn.sendJson(.file_open, .{ .xfer = @as(u32, 1), .name = "up.txt", .size = @as(u32, contents.len) }) catch fail("up file_open");
    {
        const r = conn.recvExpect(&.{.file_reply}) catch fail("up open reply");
        defer r.deinit(allocator);
        if (std.mem.indexOf(u8, r.payload, "\"status\":\"ready\"") == null) fail("up: open not ready");
    }

    // file_data [u32 xfer | bytes] → "progress".
    var data_buf: [4 + contents.len]u8 = undefined;
    std.mem.writeInt(u32, data_buf[0..4], 1, .little);
    @memcpy(data_buf[4..], contents);
    conn.sendFrame(.file_data, &data_buf) catch fail("up file_data");
    {
        const r = conn.recvExpect(&.{.file_reply}) catch fail("up data reply");
        defer r.deinit(allocator);
        if (std.mem.indexOf(u8, r.payload, "\"status\":\"progress\"") == null) fail("up: data not progress");
    }

    // file_close [u32 xfer] → "done".
    var close_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, close_buf[0..4], 1, .little);
    conn.sendFrame(.file_close, &close_buf) catch fail("up file_close");
    {
        const r = conn.recvExpect(&.{.file_reply}) catch fail("up close reply");
        defer r.deinit(allocator);
        if (std.mem.indexOf(u8, r.payload, "\"status\":\"done\"") == null) fail("up: close not done");
    }

    // The file must exist in the shell cwd with the exact contents.
    var fpath_buf: [256]u8 = undefined;
    const fpath = std.fmt.bufPrint(&fpath_buf, "{s}/up.txt", .{dir}) catch unreachable;
    {
        const fd = c.open(pathZ(&z_buf, fpath) catch fail("up open pathz"), c.O_RDONLY, @as(c_uint, 0));
        if (fd < 0) fail("up: uploaded file missing");
        defer _ = c.close(fd);
        var rd: [64]u8 = undefined;
        const n = c.read(fd, &rd, rd.len);
        if (n != contents.len or !std.mem.eql(u8, rd[0..@intCast(n)], contents)) fail("up: contents mismatch");
    }

    // A second upload of the same name must NOT clobber: the daemon
    // renames it to "up (1).txt" and reports that path.
    conn.sendJson(.file_open, .{ .xfer = @as(u32, 2), .name = "up.txt", .size = @as(u32, 0) }) catch fail("up2 open");
    {
        const r = conn.recvExpect(&.{.file_reply}) catch fail("up2 open reply");
        defer r.deinit(allocator);
        if (std.mem.indexOf(u8, r.payload, "up (1).txt") == null) fail("up: clobber not avoided");
    }
    var close2: [4]u8 = undefined;
    std.mem.writeInt(u32, close2[0..4], 2, .little);
    conn.sendFrame(.file_close, &close2) catch fail("up2 close");
    (conn.recvExpect(&.{.file_reply}) catch fail("up2 close reply")).deinit(allocator);

    // Download the file back (relative to cwd): daemon streams it as
    // reverse file_data; verify we reassemble the exact contents.
    conn.sendJson(.file_get, .{ .xfer = @as(u32, 3), .path = "up.txt" }) catch fail("dl file_get");
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(allocator);
    var dl_ready = false;
    var dl_done = false;
    var dline: usize = 0;
    while (dline < 500 and !dl_done) : (dline += 1) {
        const f = conn.recvFrame() catch fail("dl stream");
        defer f.deinit(allocator);
        switch (f.ftype) {
            .file_reply => {
                if (std.mem.indexOf(u8, f.payload, "\"status\":\"ready\"") != null) dl_ready = true;
                if (std.mem.indexOf(u8, f.payload, "\"status\":\"error\"") != null) fail("dl: daemon error");
                if (std.mem.indexOf(u8, f.payload, "\"status\":\"done\"") != null) dl_done = true;
            },
            .file_data => {
                if (wire.decodeChanId(f.payload)) |id| {
                    if (id == 3) got.appendSlice(allocator, f.payload[4..]) catch fail("dl oom");
                }
            },
            else => {},
        }
    }
    if (!dl_ready) fail("dl: never got ready");
    if (!dl_done) fail("dl: never completed");
    if (!std.mem.eql(u8, got.items, contents)) fail("dl: contents mismatch");

    // A missing file must fail cleanly, not hang.
    conn.sendJson(.file_get, .{ .xfer = @as(u32, 4), .path = "nope-not-here.txt" }) catch fail("dl miss get");
    {
        const r = conn.recvExpect(&.{.file_reply}) catch fail("dl miss reply");
        defer r.deinit(allocator);
        if (std.mem.indexOf(u8, r.payload, "\"status\":\"error\"") == null) fail("dl: missing file not refused");
    }

    // Directory browse: list the cwd (path="") and find the uploaded file.
    conn.sendJson(.file_list, .{ .xfer = @as(u32, 5), .path = "" }) catch fail("ls send");
    {
        const r = conn.recvExpect(&.{.file_listing}) catch fail("ls reply");
        defer r.deinit(allocator);
        if (std.mem.indexOf(u8, r.payload, "\"name\":\"up.txt\"") == null) fail("ls: uploaded file not listed");
        if (std.mem.indexOf(u8, r.payload, "\"dir\":false") == null) fail("ls: file not marked as a file");
    }

    // Cleanup (rmdir works even though it's the shell's cwd on Linux).
    _ = c.unlink(pathZ(&z_buf, fpath) catch unreachable);
    var f2_buf: [256]u8 = undefined;
    const f2 = std.fmt.bufPrint(&f2_buf, "{s}/up (1).txt", .{dir}) catch unreachable;
    _ = c.unlink(pathZ(&z_buf, f2) catch unreachable);
    _ = c.rmdir(pathZ(&z_buf, dir) catch unreachable);

    std.debug.print("smoke-mux: file upload + download round-trip + non-clobber ok\n", .{});
}

/// No-op SIGPIPE handler, same rationale as mux_main.zig: the daemon
/// runs IN-PROCESS here, and its write() to a dropped client (the
/// durability stage does exactly that) must EPIPE, not kill the smoke.
fn sigNoop(_: c_int) callconv(.c) void {}

pub fn main() u8 {
    _ = c.signal(c.SIGPIPE, &sigNoop);
    // safety=true forces allocation tracking even in ReleaseFast (the
    // repo's default optimize mode), where it is off by default — so
    // the leak check below actually runs.
    var gpa_state: std.heap.DebugAllocator(.{ .safety = true }) = .{};
    // The daemon is fully deinit'd before we return (thread joined,
    // d.deinit called), so a clean run must leave ZERO outstanding
    // allocations. Failing on a leak here is the regression guard for
    // the daemon-side memory leaks (unreclaimed pool mirrors, and the
    // per-commit pixel-encode scratch that ballooned an animated
    // forwarded app to 15GB) — both exercised by realAppStage.
    defer if (gpa_state.deinit() == .leak) {
        std.debug.print("smoke-mux: FAIL — daemon leaked memory (see GPA report above)\n", .{});
        std.process.exit(1);
    };
    const allocator = gpa_state.allocator();

    // On a capture-capable macOS build, the daemon would auto-enable
    // winstream for every app-hosting session — which is correct in
    // production but would divert this smoke's Wayland-pipe stages.
    // Pin "off" so the suite runs the Linux-equivalent paths; the
    // winstream stage opts back in explicitly.
    _ = c.setenv("SKETERM_WINSTREAM", "off", 1);

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
        .gpu = true,
    }) catch fail("spawn send");
    (conn.recvExpect(&.{.ok}) catch fail("spawn ok")).deinit(allocator);

    negotiationStage(allocator, sock_path);

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

    // The daemon must export the STABLE session identity into the shell
    // env — this is what `sketerm cli --pane self` / `sketerm mux` resolve
    // "my pane" by (instead of the GUI's stale-prone pane id).
    conn.sendFrame(.input, "printf 'SESCHK=[%s]\\n' \"$SKETERM_SESSION\"\n") catch fail("ses input");
    deadline = 0;
    var ses_ok = false;
    while (deadline < 200) : (deadline += 1) {
        const f = conn.recvFrame() catch fail("ses stream read");
        defer f.deinit(allocator);
        if (f.ftype == .events) mirror.applyEvents(f.payload) catch fail("ses events apply");
        const txt = mirror.screenText() catch fail("ses extract");
        defer allocator.free(txt);
        if (std.mem.indexOf(u8, txt, "SESCHK=[smoke]") != null) {
            ses_ok = true;
            break;
        }
    }
    if (!ses_ok) fail("SKETERM_SESSION not exported as the session name");

    // File upload (file_* frames) → daemon writes into the shell cwd.
    uploadStage(allocator, &conn, &mirror);

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

    // Scripted LINEAR linux-dmabuf import + durable synthetic-pool replay.
    dmabufStage(allocator, &conn, sock_path);

    // Backlogged mcp client: gap + live-mirror resync (shared stage,
    // also run against a real broker by smoke-broker).
    @import("smoke_backlog.zig").run(allocator, sock_path);

    // Native pipe with a REAL Wayland app + the compositor brain.
    const wlapp_ran = realAppStage(allocator, sock_path);

    // Window-stream pipeline (stub capture source).
    winstreamStage(allocator, sock_path);

    // Apps that connect before a renderer attaches are parked.
    pendingAppStage(allocator, sock_path, if (wlapp_ran) 4 else 3);

    // Snapshot header carries the app flag (drives GUI hold-on-exit).
    appFlagStage(allocator, sock_path);

    // Isolated session: private runtime dir + dropped D-Bus + cleanup.
    isolatedStage(allocator, sock_path);

    // Quick CLI connections send no hello and must still be served.
    noHelloStage(allocator, sock_path);

    // A second client sees the session in LIST.
    var conn2 = client_mod.Conn.connect(allocator, sock_path) catch fail("connect2");
    conn2.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("hello2 send");
    (conn2.recvExpect(&.{.welcome}) catch fail("welcome2")).deinit(allocator);
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
