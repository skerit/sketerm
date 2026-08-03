//! External display sessions + the controller lease, end to end.
//!
//! Shared stage: `smoke-mux` runs it against a MONOLITH daemon and
//! `smoke-broker` against a real broker (whose per-session workers make
//! the 'Y'/'A' control datagrams load-bearing). Broker-only regressions
//! in exactly that hop have shipped before while monolith smokes stayed
//! green, so both is not redundancy — it is the point.
//!
//! Covered: `display create` returns a usable environment as JSON; the
//! returned Wayland socket accepts an EXTERNAL client (a stock
//! weston-terminal sketerm never spawned); duplicate names are refused;
//! `inspect`/`list` report the session; the no-viewer TTL kills an
//! abandoned session; `destroy` closes the listener; and the controller
//! lease actually gates input — a non-controller's `request_close` does
//! nothing, the controller's closes the app.

const std = @import("std");
const c = @import("c.zig").c;
const client_mod = @import("mux/client.zig");
const wire = @import("mux/wire.zig");
const display_cli = @import("mux/display.zig");
const pulse = @import("mux/pulse.zig");
const pipe_mod = @import("wlhost/pipe.zig");
const compositor_mod = @import("wlhost/compositor.zig");

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("smoke-display: FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

fn failf(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("smoke-display: FAIL: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Run the display CLI with stdout captured, so the stage asserts on
/// the REAL bytes a caller would parse (not a re-implementation of the
/// formatting). Output is small; the pipe buffer is never a concern.
const CliResult = struct {
    code: u8,
    out: []u8,

    fn deinit(self: CliResult, allocator: std.mem.Allocator) void {
        allocator.free(self.out);
    }
};

fn runCli(allocator: std.mem.Allocator, argv: []const []const u8) CliResult {
    var pfds: [2]c_int = undefined;
    if (c.pipe(&pfds) != 0) fail("pipe");
    const saved = c.dup(1);
    if (saved < 0) fail("dup stdout");
    _ = c.dup2(pfds[1], 1);
    _ = c.close(pfds[1]);
    const code = display_cli.run(allocator, argv);
    _ = c.dup2(saved, 1);
    _ = c.close(saved);

    var out: std.ArrayList(u8) = .empty;
    while (true) {
        var buf: [4096]u8 = undefined;
        const n = c.read(pfds[0], &buf, buf.len);
        if (n <= 0) break;
        out.appendSlice(allocator, buf[0..@intCast(n)]) catch fail("oom");
    }
    _ = c.close(pfds[0]);
    return .{ .code = code, .out = out.toOwnedSlice(allocator) catch fail("oom") };
}

const CreateReply = struct {
    session: []const u8 = "",
    environment: struct {
        WAYLAND_DISPLAY: []const u8 = "",
        XDG_RUNTIME_DIR: []const u8 = "",
        PULSE_SERVER: []const u8 = "",
        LIBGL_ALWAYS_SOFTWARE: []const u8 = "",
    } = .{},
};

fn socketAccepts(path: []const u8) bool {
    const fd = @import("util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var addr: c.struct_sockaddr_un = undefined;
    @import("mux/daemon.zig").fillSockaddrUn(&addr, path) catch return false;
    return c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0;
}

// ── audio-flag stage ─────────────────────────────────────────────
//
// A hand-rolled PulseAudio-native client (same frames the pulse.zig
// unit tests feed the Server directly, here over the REAL session
// socket): AUTH, SET_CLIENT_NAME, CREATE_PLAYBACK_STREAM uncorked.
// The daemon must then report `"audio":true` for the session in
// `list` — in broker mode that means the worker's 'M' metadata push
// carries it, exactly the hop that has silently regressed before.

const PA_DESC_SIZE = 20;

fn paU32(out: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) void {
    out.append(a, 'L') catch fail("oom");
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    out.appendSlice(a, &b) catch fail("oom");
}

fn paBool(out: *std.ArrayList(u8), a: std.mem.Allocator, v: bool) void {
    out.append(a, if (v) @as(u8, '1') else '0') catch fail("oom");
}

fn paString(out: *std.ArrayList(u8), a: std.mem.Allocator, value: []const u8) void {
    out.append(a, 't') catch fail("oom");
    out.appendSlice(a, value) catch fail("oom");
    out.append(a, 0) catch fail("oom");
}

const PaProperty = struct { key: []const u8, value: []const u8 };

fn paProplist(out: *std.ArrayList(u8), a: std.mem.Allocator, properties: []const PaProperty) void {
    out.append(a, 'P') catch fail("oom");
    for (properties) |property| {
        paString(out, a, property.key);
        paU32(out, a, @intCast(property.value.len + 1));
        out.append(a, 'x') catch fail("oom");
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(property.value.len + 1), .big);
        out.appendSlice(a, &len) catch fail("oom");
        out.appendSlice(a, property.value) catch fail("oom");
        out.append(a, 0) catch fail("oom");
    }
    out.append(a, 'N') catch fail("oom");
}

fn paFrameSend(fd: c_int, a: std.mem.Allocator, fields: []const u8) void {
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(a);
    var desc: [PA_DESC_SIZE]u8 = [_]u8{0} ** PA_DESC_SIZE;
    std.mem.writeInt(u32, desc[0..4], @intCast(fields.len), .big);
    std.mem.writeInt(u32, desc[4..8], 0xffff_ffff, .big); // control channel
    frame.appendSlice(a, &desc) catch fail("oom");
    frame.appendSlice(a, fields) catch fail("oom");
    var off: usize = 0;
    while (off < frame.items.len) {
        const n = c.write(fd, frame.items.ptr + off, frame.items.len - off);
        if (n <= 0) fail("audio: short write to the pulse socket");
        off += @intCast(n);
    }
}

fn paDataSend(fd: c_int, a: std.mem.Allocator, channel: u32, bytes: []const u8) void {
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(a);
    var desc: [PA_DESC_SIZE]u8 = [_]u8{0} ** PA_DESC_SIZE;
    std.mem.writeInt(u32, desc[0..4], @intCast(bytes.len), .big);
    std.mem.writeInt(u32, desc[4..8], channel, .big);
    frame.appendSlice(a, &desc) catch fail("oom");
    frame.appendSlice(a, bytes) catch fail("oom");
    var off: usize = 0;
    while (off < frame.items.len) {
        const n = c.write(fd, frame.items.ptr + off, frame.items.len - off);
        if (n <= 0) fail("audio: short PCM write to the pulse socket");
        off += @intCast(n);
    }
}

/// Does the daemon's raw `list` reply currently say `"audio":true`?
fn listSaysAudio(allocator: std.mem.Allocator, sock_path: []const u8) bool {
    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("audio: list connect");
    defer conn.deinit();
    conn.sendFrame(.list, "") catch fail("audio: list send");
    const f = conn.recvExpect(&.{.welcome}) catch fail("audio: list recv");
    defer f.deinit(allocator);
    return std.mem.indexOf(u8, f.payload, "\"audio\":true") != null;
}

fn listContains(allocator: std.mem.Allocator, sock_path: []const u8, needle: []const u8) bool {
    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("audio: list connect");
    defer conn.deinit();
    conn.sendFrame(.list, "") catch fail("audio: list send");
    const f = conn.recvExpect(&.{.welcome}) catch fail("audio: list recv");
    defer f.deinit(allocator);
    return std.mem.indexOf(u8, f.payload, needle) != null;
}

fn audioStage(allocator: std.mem.Allocator, sock_path: []const u8, session_name: []const u8, pulse_server: []const u8) void {
    const a = allocator;
    // "unix:<path>" — the scheme was asserted at create.
    const pa_path = pulse_server["unix:".len..];
    if (listSaysAudio(a, sock_path)) fail("audio: flag already true with no stream");

    // Attach a deaf viewer before the stream exists. The stream's initial
    // descriptors are withheld until this viewer subscribes, which is the
    // startup ordering that used to produce audible but unidentified audio.
    var viewer = client_mod.Conn.connect(a, sock_path) catch fail("audio: viewer connect");
    defer viewer.deinit();
    viewer.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("audio: viewer hello");
    (viewer.recvExpectFor(&.{.welcome}, 15_000) catch fail("audio: viewer welcome")).deinit(a);
    viewer.sendJson(.attach, .{ .name = session_name, .kind = "gui", .read_only = true }) catch fail("audio: viewer attach");
    (viewer.recvExpectFor(&.{.snapshot}, 15_000) catch fail("audio: viewer snapshot")).deinit(a);

    const fd = @import("util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) fail("audio: socket");
    var addr: c.struct_sockaddr_un = undefined;
    @import("mux/daemon.zig").fillSockaddrUn(&addr, pa_path) catch fail("audio: pulse path too long");
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0)
        fail("audio: cannot connect to the session's PULSE_SERVER");

    var fields: std.ArrayList(u8) = .empty;
    defer fields.deinit(a);
    { // AUTH(version 35, zero cookie)
        paU32(&fields, a, 8); // CMD_AUTH
        paU32(&fields, a, 1); // tag
        paU32(&fields, a, 35 | 0x8000_0000);
        fields.append(a, 'x') catch fail("oom"); // arbitrary blob
        var lb: [4]u8 = undefined;
        std.mem.writeInt(u32, &lb, 256, .big);
        fields.appendSlice(a, &lb) catch fail("oom");
        fields.appendSlice(a, &([_]u8{0} ** 256)) catch fail("oom");
        paFrameSend(fd, a, fields.items);
        fields.clearRetainingCapacity();
    }
    { // SET_CLIENT_NAME with the application identity used by the overview
        paU32(&fields, a, 9); // CMD_SET_CLIENT_NAME
        paU32(&fields, a, 2);
        paProplist(&fields, a, &.{
            .{ .key = "application.name", .value = "Smoke Player" },
            .{ .key = "application.process.binary", .value = "smoke-player" },
            .{ .key = "application.process.id", .value = "4242" },
            .{ .key = "application.icon_name", .value = "multimedia-player" },
        });
        paFrameSend(fd, a, fields.items);
        fields.clearRetainingCapacity();
    }
    { // CREATE_PLAYBACK_STREAM: s16le stereo 48k, NOT corked
        paU32(&fields, a, 3); // CMD_CREATE_PLAYBACK_STREAM
        paU32(&fields, a, 3); // tag
        fields.appendSlice(a, &[_]u8{ 'a', 3, 2 }) catch fail("oom"); // sample spec s16le stereo...
        var rb: [4]u8 = undefined;
        std.mem.writeInt(u32, &rb, 48000, .big);
        fields.appendSlice(a, &rb) catch fail("oom"); // ...48 kHz
        fields.appendSlice(a, &[_]u8{ 'm', 2, 1, 2 }) catch fail("oom"); // channel map FL,FR
        paU32(&fields, a, 0xffff_ffff); // sink index: invalid
        fields.append(a, 'N') catch fail("oom"); // sink name: null
        paU32(&fields, a, 0xffff_ffff); // maxlength
        paBool(&fields, a, false); // corked — the whole point
        paU32(&fields, a, 48000); // tlength
        paU32(&fields, a, 0xffff_ffff); // prebuf
        paU32(&fields, a, 0xffff_ffff); // minreq
        paU32(&fields, a, 0); // syncid
        fields.append(a, 'v') catch fail("oom"); // cvolume, 2 channels
        fields.append(a, 2) catch fail("oom");
        var vb: [4]u8 = undefined;
        std.mem.writeInt(u32, &vb, 0x10000, .big);
        fields.appendSlice(a, &vb) catch fail("oom");
        fields.appendSlice(a, &vb) catch fail("oom");
        var i: u8 = 0; // v12 bools
        while (i < 7) : (i += 1) paBool(&fields, a, false);
        paBool(&fields, a, false); // muted
        paBool(&fields, a, true); // adjust_latency
        paProplist(&fields, a, &.{.{ .key = "media.name", .value = "Smoke Song" }});
        paBool(&fields, a, false); // v14: volume_set
        paBool(&fields, a, false); // v14: early_requests
        paBool(&fields, a, false); // v15: muted_set
        paBool(&fields, a, false); // v15: dont_inhibit_auto_suspend
        paBool(&fields, a, false); // v15: fail_on_suspend
        paFrameSend(fd, a, fields.items);
        fields.clearRetainingCapacity();
    }

    const chan_open = viewer.recvExpectFor(&.{.chan_open}, 15_000) catch fail("audio: viewer never received channel open");
    const channel = (wire.decodeChanOpen(chan_open.payload) orelse fail("audio: malformed channel open"));
    if (channel.kind != .audio) fail("audio: viewer received a non-audio channel");
    chan_open.deinit(a);
    var subscribe_units: std.ArrayList(u8) = .empty;
    defer subscribe_units.deinit(a);
    pulse.appendUnit(&subscribe_units, a, .subscribe, "") catch fail("oom");
    var subscribe_payload: std.ArrayList(u8) = .empty;
    defer subscribe_payload.deinit(a);
    var channel_id: [4]u8 = undefined;
    std.mem.writeInt(u32, &channel_id, channel.id, .little);
    subscribe_payload.appendSlice(a, &channel_id) catch fail("oom");
    subscribe_payload.appendSlice(a, subscribe_units.items) catch fail("oom");
    viewer.sendFrame(.chan_data, subscribe_payload.items) catch fail("audio: subscribe send");

    const descriptors = viewer.recvExpectFor(&.{.chan_data}, 15_000) catch fail("audio: descriptors not replayed on subscribe");
    defer descriptors.deinit(a);
    if (descriptors.payload.len < 4 or std.mem.readInt(u32, descriptors.payload[0..4], .little) != channel.id)
        fail("audio: descriptors arrived on the wrong channel");
    const opened = pulse.peelUnit(descriptors.payload[4..]) orelse fail("audio: missing open descriptor");
    if (opened.tag != .open) fail("audio: first replayed unit was not open");
    const metadata = pulse.peelUnit(descriptors.payload[4 + opened.consumed ..]) orelse fail("audio: missing metadata descriptor");
    if (metadata.tag != .metadata) fail("audio: metadata did not follow open");
    const cork = pulse.peelUnit(descriptors.payload[4 + opened.consumed + metadata.consumed ..]) orelse fail("audio: missing cork descriptor");
    if (cork.tag != .cork or cork.payload.len < 5 or cork.payload[4] != 0) fail("audio: initial cork state was not replayed");

    paDataSend(fd, a, 0, "\x01\x02\x03\x04");
    const pcm = viewer.recvExpectFor(&.{.chan_data}, 15_000) catch fail("audio: subscribed viewer did not receive PCM");
    defer pcm.deinit(a);
    if (pcm.payload.len < 4) fail("audio: malformed PCM channel data");
    const pcm_unit = pulse.peelUnit(pcm.payload[4..]) orelse fail("audio: malformed PCM unit");
    if (pcm_unit.tag != .pcm) fail("audio: PCM overtook stream descriptors");

    // Reattaching on the same subscribed connection keeps audio_ok set.
    // Descriptor replay must therefore share PCM's priority lane: putting
    // descriptors on the normal lane lets fresh PCM overtake them behind
    // the snapshot backlog.
    viewer.sendJson(.attach, .{ .name = session_name, .kind = "gui", .read_only = true }) catch fail("audio: subscribed reattach");
    _ = c.usleep(100_000);
    paDataSend(fd, a, 0, "\x05\x06\x07\x08");
    const reopened = viewer.recvExpectFor(&.{.chan_open}, 15_000) catch fail("audio: subscribed reattach omitted channel open");
    const reopened_channel = wire.decodeChanOpen(reopened.payload) orelse fail("audio: malformed reattached channel open");
    if (reopened_channel.id != channel.id or reopened_channel.kind != .audio) fail("audio: wrong reattached audio channel");
    reopened.deinit(a);
    const replayed = viewer.recvExpectFor(&.{.chan_data}, 15_000) catch fail("audio: subscribed reattach descriptors were overtaken");
    const replayed_unit = if (replayed.payload.len >= 4) pulse.peelUnit(replayed.payload[4..]) else null;
    if (replayed_unit == null or replayed_unit.?.tag != .open) fail("audio: subscribed reattach did not replay descriptors first");
    replayed.deinit(a);
    const replayed_pcm = viewer.recvExpectFor(&.{.chan_data}, 15_000) catch fail("audio: PCM missing after subscribed reattach descriptors");
    const replayed_pcm_unit = if (replayed_pcm.payload.len >= 4) pulse.peelUnit(replayed_pcm.payload[4..]) else null;
    if (replayed_pcm_unit == null or replayed_pcm_unit.?.tag != .pcm) fail("audio: subscribed reattach descriptor order was malformed");
    replayed_pcm.deinit(a);

    // The daemon's poll loop must notice the uncorked stream, and in
    // broker mode the worker's 'M' push must carry it to the broker.
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        if (listSaysAudio(allocator, sock_path)) break;
        if (tries == 99) fail("audio: list never reported the uncorked stream as \"audio\":true");
        _ = c.usleep(50_000);
    }
    if (!listContains(a, sock_path, "\"application\":\"Smoke Player\"")) fail("audio: list omitted application metadata");
    if (!listContains(a, sock_path, "\"binary\":\"smoke-player\"")) fail("audio: list omitted binary metadata");
    if (!listContains(a, sock_path, "\"media\":\"Smoke Song\"")) fail("audio: list omitted media metadata");
    if (!listContains(a, sock_path, "\"icon\":\"multimedia-player\"")) fail("audio: list omitted icon metadata");
    if (!listContains(a, sock_path, "\"pid\":4242")) fail("audio: list omitted pid metadata");

    { // Dynamic title updates must propagate while the audio flag stays true.
        paU32(&fields, a, 46); // CMD_SET_PLAYBACK_STREAM_NAME
        paU32(&fields, a, 4);
        paU32(&fields, a, 0);
        paString(&fields, a, "Smoke Song Two");
        paFrameSend(fd, a, fields.items);
        fields.clearRetainingCapacity();
    }
    tries = 0;
    while (tries < 100) : (tries += 1) {
        if (listContains(a, sock_path, "\"media\":\"Smoke Song Two\"")) break;
        if (tries == 99) fail("audio: changed media title never reached list metadata");
        _ = c.usleep(50_000);
    }

    { // Corking keeps identity but clears the running/audio state.
        paU32(&fields, a, 41); // CMD_CORK_PLAYBACK_STREAM
        paU32(&fields, a, 5);
        paU32(&fields, a, 0);
        paBool(&fields, a, true);
        paFrameSend(fd, a, fields.items);
        fields.clearRetainingCapacity();
    }
    tries = 0;
    while (tries < 100) : (tries += 1) {
        if (!listSaysAudio(a, sock_path)) break;
        if (tries == 99) fail("audio: corked stream remained active");
        _ = c.usleep(50_000);
    }
    if (!listContains(a, sock_path, "\"running\":false")) fail("audio: cork state missing from stream metadata");
    { // Uncork again so close exercises the active-stream teardown.
        paU32(&fields, a, 41);
        paU32(&fields, a, 6);
        paU32(&fields, a, 0);
        paBool(&fields, a, false);
        paFrameSend(fd, a, fields.items);
        fields.clearRetainingCapacity();
    }
    tries = 0;
    while (tries < 100) : (tries += 1) {
        if (listSaysAudio(a, sock_path)) break;
        if (tries == 99) fail("audio: uncorked stream did not become active again");
        _ = c.usleep(50_000);
    }

    // Closing the client tears the stream down; the flag must clear.
    _ = c.close(fd);
    tries = 0;
    while (tries < 100) : (tries += 1) {
        if (!listSaysAudio(allocator, sock_path)) break;
        if (tries == 99) fail("audio: flag stuck true after the stream's client vanished");
        _ = c.usleep(50_000);
    }
    std.debug.print("smoke-display: session audio metadata + subscribe replay ok\n", .{});
}

/// One attached viewer. `has_control` mirrors the daemon's
/// control_state pushes — the lease is only observable through them.
const Viewer = struct {
    allocator: std.mem.Allocator,
    conn: client_mod.Conn,
    comp: ?*compositor_mod.Compositor = null,
    chan: u32 = 0,
    has_control: bool = false,
    holder: [32]u8 = undefined,
    holder_len: usize = 0,
    control_pushes: u32 = 0,
    viewers: u32 = 0,
    alive: bool = true,

    fn attach(allocator: std.mem.Allocator, sock_path: []const u8, name: []const u8, opts: struct {
        read_only: bool = false,
        control: bool = false,
        replica: bool = false,
    }) Viewer {
        var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("viewer connect");
        conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("viewer hello");
        (conn.recvExpectFor(&.{.welcome}, 15_000) catch fail("viewer welcome")).deinit(allocator);
        conn.sendJson(.attach, .{
            .name = name,
            .kind = "gui",
            .read_only = opts.read_only,
            .control = opts.control,
        }) catch fail("viewer attach");
        (conn.recvExpectFor(&.{.snapshot}, 15_000) catch fail("viewer snapshot")).deinit(allocator);
        // Non-blocking from here: the stage pumps several connections
        // and must never park in a read on one of them.
        conn.setNonBlocking();
        var v = Viewer{ .allocator = allocator, .conn = conn };
        if (opts.replica) {
            const comp = allocator.create(compositor_mod.Compositor) catch fail("oom");
            comp.* = compositor_mod.Compositor.init(allocator, .{
                .toplevel_frame = onFrame,
                .toplevel_gone = onGone,
            }) catch fail("replica init");
            comp.lenient = true;
            v.comp = comp;
        }
        return v;
    }

    fn deinit(self: *Viewer) void {
        if (self.comp) |comp| {
            comp.deinit();
            self.allocator.destroy(comp);
            self.comp = null;
        }
        if (self.alive) {
            self.conn.deinit();
            self.alive = false;
        }
    }

    /// Drop the socket WITHOUT detaching — a viewer process dying.
    fn kill(self: *Viewer) void {
        if (!self.alive) return;
        self.conn.deinit();
        self.alive = false;
    }

    fn label(self: *const Viewer) []const u8 {
        return self.holder[0..self.holder_len];
    }

    /// Drain whatever has arrived. Returns false once the peer hung up.
    fn pump(self: *Viewer) bool {
        if (!self.alive) return false;
        if (!self.conn.fillAvailable()) return false;
        while (self.conn.takeFrame() catch return false) |f| {
            defer f.deinit(self.allocator);
            switch (f.ftype) {
                .control_state => {
                    const Msg = struct {
                        controller: bool = false,
                        read_only: bool = false,
                        controller_label: []const u8 = "",
                        viewers: u32 = 0,
                    };
                    var parsed = std.json.parseFromSlice(Msg, self.allocator, f.payload, .{
                        .ignore_unknown_fields = true,
                        .allocate = .alloc_always,
                    }) catch fail("control_state parse");
                    defer parsed.deinit();
                    self.has_control = parsed.value.controller;
                    self.viewers = parsed.value.viewers;
                    self.holder_len = @min(parsed.value.controller_label.len, self.holder.len);
                    @memcpy(self.holder[0..self.holder_len], parsed.value.controller_label[0..self.holder_len]);
                    self.control_pushes += 1;
                },
                .chan_open => {
                    const open = wire.decodeChanOpen(f.payload) orelse continue;
                    if (open.kind == .wayland_native) self.chan = open.id;
                },
                .chan_data => {
                    const comp = self.comp orelse continue;
                    if ((wire.decodeChanId(f.payload) orelse 0) != self.chan) continue;
                    comp.feed(f.payload[4..]) catch fail("replica feed");
                    comp.clearOut(); // passive replica: output is discarded
                    if (comp.dead) fail("replica flagged a protocol error");
                },
                else => {},
            }
        }
        return true;
    }

    fn sendUnits(self: *Viewer, units: []const u8) void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, self.chan, .little);
        payload.appendSlice(self.allocator, &idb) catch fail("oom");
        payload.appendSlice(self.allocator, units) catch fail("oom");
        self.conn.sendFrame(.chan_data, payload.items) catch fail("chan_data send");
    }

    fn requestClose(self: *Viewer, sid: u32) void {
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(self.allocator);
        pipe_mod.appendRequestClose(&units, self.allocator, sid) catch fail("oom");
        self.sendUnits(units.items);
    }

    fn requestControl(self: *Viewer, op: []const u8) void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(.{ .op = op }, .{}, &aw.writer) catch fail("oom");
        self.conn.sendFrame(.control_req, aw.written()) catch fail("control_req send");
    }
};

/// Frames land on a file-global because the compositor callback carries
/// only an opaque ctx and every viewer here shares one accounting.
var g_frames: usize = 0;
var g_sid: u32 = 0;
var g_gone: usize = 0;

fn onFrame(ctx: ?*anyopaque, surface: u32, fw: i32, fh: i32, scale: i32, lw: i32, lh: i32, format: u32, pixels: []const u8) void {
    _ = .{ ctx, fw, fh, scale, lw, lh, format, pixels };
    g_frames += 1;
    g_sid = surface;
}

fn onGone(ctx: ?*anyopaque, surface: u32) void {
    _ = .{ ctx, surface };
    g_gone += 1;
}

fn pumpFor(vs: []*Viewer, ms: i64) void {
    const deadline = nowMs() + ms;
    while (nowMs() < deadline) {
        for (vs) |v| _ = v.pump();
        _ = c.usleep(20_000);
    }
}

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

fn childAlive(pid: c.pid_t) bool {
    var st: c_int = 0;
    // WNOHANG reap first: a zombie answers kill(0) just fine.
    if (c.waitpid(pid, &st, c.WNOHANG) == pid) return false;
    return c.kill(pid, 0) == 0;
}

/// Spawn an EXTERNAL Wayland client against `wl_path` — the whole point
/// of a display session. Nothing about it goes through sketerm.
fn spawnExternalApp(wl_path: []const u8) c.pid_t {
    var wl_z: [4096:0]u8 = undefined;
    const wz = std.fmt.bufPrintZ(&wl_z, "{s}", .{wl_path}) catch fail("wl path too long");
    const pid = c.fork();
    if (pid < 0) fail("fork external app");
    if (pid == 0) {
        _ = c.setenv("WAYLAND_DISPLAY", wz.ptr, 1);
        // The daemon's own hub is the display; a stray X11 display or
        // GDK backend hint must not divert the client.
        _ = c.unsetenv("DISPLAY");
        const argv = [_:null]?[*:0]const u8{ "/usr/bin/weston-terminal", null };
        _ = c.execv("/usr/bin/weston-terminal", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    return pid;
}

fn listJson(allocator: std.mem.Allocator, sock_path: []const u8) CliResult {
    return runCli(allocator, &.{ "list", "--json", "--socket", sock_path });
}

fn hasDisplay(allocator: std.mem.Allocator, sock_path: []const u8, name: []const u8) bool {
    const r = listJson(allocator, sock_path);
    defer r.deinit(allocator);
    if (r.code != 0) fail("list failed");
    var needle_buf: [96]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"session\":\"{s}\"", .{name}) catch fail("oom");
    return std.mem.indexOf(u8, r.out, needle) != null;
}

pub fn run(allocator: std.mem.Allocator, sock_path: []const u8) void {
    // ── create: the JSON environment is the contract ──────────────
    var wl_path_buf: [4096]u8 = undefined;
    var wl_path_len: usize = 0;
    var pa_buf: [4096]u8 = undefined;
    var pa_len: usize = 0;
    {
        const r = runCli(allocator, &.{ "create", "--name", "dsp1", "--json", "--socket", sock_path });
        defer r.deinit(allocator);
        if (r.code != 0) failf("create failed (exit {d}): {s}", .{ r.code, r.out });
        var parsed = std.json.parseFromSlice(CreateReply, allocator, r.out, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch failf("create output is not the documented JSON: {s}", .{r.out});
        defer parsed.deinit();
        const env = parsed.value.environment;
        if (!std.mem.eql(u8, parsed.value.session, "dsp1")) fail("create: wrong session name in reply");
        if (env.WAYLAND_DISPLAY.len == 0 or env.WAYLAND_DISPLAY[0] != '/')
            failf("create: WAYLAND_DISPLAY must be an absolute path, got '{s}'", .{env.WAYLAND_DISPLAY});
        if (env.XDG_RUNTIME_DIR.len == 0) fail("create: no XDG_RUNTIME_DIR");
        if (!std.mem.eql(u8, env.LIBGL_ALWAYS_SOFTWARE, "1"))
            fail("create: software GL must be forced without --gpu");
        // libpulse needs the scheme, exactly as the daemon hands it to
        // its own children — a bare path is not a usable PULSE_SERVER.
        if (env.PULSE_SERVER.len == 0)
            fail("create: no PULSE_SERVER (the session has an audio hub)");
        if (!std.mem.startsWith(u8, env.PULSE_SERVER, "unix:/"))
            failf("create: PULSE_SERVER must be 'unix:<path>', got '{s}'", .{env.PULSE_SERVER});
        if (!socketAccepts(env.WAYLAND_DISPLAY))
            failf("create: nothing listening on {s}", .{env.WAYLAND_DISPLAY});
        wl_path_len = env.WAYLAND_DISPLAY.len;
        @memcpy(wl_path_buf[0..wl_path_len], env.WAYLAND_DISPLAY);
        pa_len = env.PULSE_SERVER.len;
        @memcpy(pa_buf[0..pa_len], env.PULSE_SERVER);
    }
    const wl_path = wl_path_buf[0..wl_path_len];
    const pulse_server = pa_buf[0..pa_len];
    std.debug.print("smoke-display: create + live wayland socket ok ({s})\n", .{wl_path});

    // ── duplicate names are refused, not silently reused ──────────
    {
        const r = runCli(allocator, &.{ "create", "--name", "dsp1", "--json", "--socket", sock_path });
        defer r.deinit(allocator);
        if (r.code == 0) fail("create: duplicate name was accepted");
    }

    // ── --gpu drops the software-GL force ─────────────────────────
    {
        const r = runCli(allocator, &.{ "create", "--name", "dspgpu", "--gpu", "--json", "--socket", sock_path });
        defer r.deinit(allocator);
        if (r.code != 0) failf("create --gpu failed: {s}", .{r.out});
        if (std.mem.indexOf(u8, r.out, "LIBGL_ALWAYS_SOFTWARE") != null)
            fail("create --gpu must not export LIBGL_ALWAYS_SOFTWARE");
        const d = runCli(allocator, &.{ "destroy", "dspgpu", "--socket", sock_path });
        defer d.deinit(allocator);
        if (d.code != 0) fail("destroy dspgpu failed");
    }
    std.debug.print("smoke-display: duplicate refusal + --gpu env ok\n", .{});

    // ── inspect / list ────────────────────────────────────────────
    {
        // In broker mode the viewer/controller fields ride the worker's
        // 'M' push, so allow it a moment to land.
        var tries: usize = 0;
        while (tries < 100) : (tries += 1) {
            const r = runCli(allocator, &.{ "inspect", "dsp1", "--json", "--socket", sock_path });
            defer r.deinit(allocator);
            if (r.code != 0) failf("inspect failed: {s}", .{r.out});
            const ok = std.mem.indexOf(u8, r.out, "\"display\":true") != null and
                std.mem.indexOf(u8, r.out, wl_path) != null and
                std.mem.indexOf(u8, r.out, "\"controller\":null") != null;
            if (ok) break;
            if (tries == 99) failf("inspect fields never became right: {s}", .{r.out});
            _ = c.usleep(50_000);
        }
    }
    if (!hasDisplay(allocator, sock_path, "dsp1")) fail("list: dsp1 missing");
    std.debug.print("smoke-display: inspect + list ok\n", .{});

    // ── an uncorked stream flips list's audio flag (and back) ─────
    audioStage(allocator, sock_path, "dsp1", pulse_server);

    // ── the controller lease, against a real external app ─────────
    if (c.access("/usr/bin/weston-terminal", c.X_OK) == 0)
        leaseStage(allocator, sock_path, wl_path)
    else
        std.debug.print("smoke-display: lease stage SKIPPED (no weston-terminal)\n", .{});

    // ── controller death hands the lease to the oldest viewer ─────
    handoverStage(allocator, sock_path);

    // ── destroy closes the listener ───────────────────────────────
    {
        const r = runCli(allocator, &.{ "destroy", "dsp1", "--socket", sock_path });
        defer r.deinit(allocator);
        if (r.code != 0) failf("destroy failed: {s}", .{r.out});
    }
    {
        var tries: usize = 0;
        while (tries < 100 and socketAccepts(wl_path)) : (tries += 1) _ = c.usleep(50_000);
        if (socketAccepts(wl_path)) fail("destroy: the wayland socket still accepts connections");
    }
    if (hasDisplay(allocator, sock_path, "dsp1")) fail("destroy: dsp1 still listed");
    std.debug.print("smoke-display: destroy closes the listener ok\n", .{});

    // ── TTL: an abandoned session must not leak a hub forever ─────
    {
        const r = runCli(allocator, &.{ "create", "--name", "dspttl", "--ttl", "1", "--json", "--socket", sock_path });
        defer r.deinit(allocator);
        if (r.code != 0) failf("create --ttl failed: {s}", .{r.out});
    }
    if (!hasDisplay(allocator, sock_path, "dspttl")) fail("ttl: session missing right after create");
    {
        // 1s TTL, checked on the daemon's reap; a worker additionally
        // has to exit and be reaped by the broker.
        var tries: usize = 0;
        while (tries < 120) : (tries += 1) {
            if (!hasDisplay(allocator, sock_path, "dspttl")) break;
            _ = c.usleep(100_000);
        }
        if (hasDisplay(allocator, sock_path, "dspttl")) fail("ttl: never-attached session outlived its ttl");
    }
    std.debug.print("smoke-display: ttl expiry ok\n", .{});
}

/// Two viewers on one display session with a real external app: only
/// the controller's input reaches it. `request_close` is the observable
/// — binary, and immune to the app's own idle repaints (a cursor blink
/// would defeat any "no new frames" assertion).
fn leaseStage(allocator: std.mem.Allocator, sock_path: []const u8, wl_path: []const u8) void {
    g_frames = 0;
    g_sid = 0;
    g_gone = 0;

    const app_pid = spawnExternalApp(wl_path);
    var app_reaped = false;
    defer if (!app_reaped) {
        // Our own child, by exact pid — never a name-based kill.
        _ = c.kill(app_pid, c.SIGKILL);
        var st: c_int = 0;
        _ = c.waitpid(app_pid, &st, 0);
    };

    var a = Viewer.attach(allocator, sock_path, "dsp1", .{ .replica = true });
    defer a.deinit();
    var b = Viewer.attach(allocator, sock_path, "dsp1", .{ .replica = false });
    defer b.deinit();
    var vs = [_]*Viewer{ &a, &b };

    // Wait for the external app's first committed toplevel frame.
    {
        const deadline = nowMs() + 30_000;
        while (g_frames == 0 and nowMs() < deadline) {
            for (&vs) |v| _ = v.pump();
            if (!childAlive(app_pid)) fail("lease: the external app died before committing a frame");
            _ = c.usleep(20_000);
        }
        if (g_frames == 0) fail("lease: the external app never committed a frame into the display session");
    }
    std.debug.print("smoke-display: external app rendered into the display session ({d} frames)\n", .{g_frames});

    // First non-read-only attach holds the lease; the second is a viewer.
    pumpFor(&vs, 500);
    if (!a.has_control) fail("lease: the first viewer did not auto-acquire control");
    if (b.has_control) fail("lease: the second viewer must not hold control");
    if (b.holder_len == 0) fail("lease: a read-only viewer was not told who controls");
    if (!std.mem.eql(u8, a.label(), b.label())) fail("lease: viewers disagree about the controller");
    if (b.viewers != 2) failf("lease: viewer count is {d}, want 2", .{b.viewers});
    std.debug.print("smoke-display: auto-acquire + read-only notice ok (controller {s})\n", .{b.label()});

    // A non-controller's input must be DROPPED daemon-side.
    b.requestClose(g_sid);
    pumpFor(&vs, 1_500);
    if (!childAlive(app_pid)) fail("lease: a NON-CONTROLLER's request_close reached the app");
    std.debug.print("smoke-display: non-controller input dropped ok\n", .{});

    // Forced takeover moves the lease both ways.
    b.requestControl("takeover");
    {
        const deadline = nowMs() + 5_000;
        while ((!b.has_control or a.has_control) and nowMs() < deadline) {
            for (&vs) |v| _ = v.pump();
            _ = c.usleep(20_000);
        }
    }
    if (!b.has_control) fail("lease: takeover did not grant control");
    if (a.has_control) fail("lease: the evicted controller still believes it controls");

    // The previous controller is now gated too.
    a.requestClose(g_sid);
    pumpFor(&vs, 1_500);
    if (!childAlive(app_pid)) fail("lease: the EVICTED controller's request_close reached the app");
    std.debug.print("smoke-display: takeover ok (controller {s})\n", .{a.label()});

    // And the new controller's input does reach it.
    b.requestClose(g_sid);
    {
        const deadline = nowMs() + 10_000;
        while (childAlive(app_pid) and nowMs() < deadline) {
            for (&vs) |v| _ = v.pump();
            _ = c.usleep(20_000);
        }
    }
    if (childAlive(app_pid)) fail("lease: the controller's request_close did NOT reach the app");
    app_reaped = true;
    std.debug.print("smoke-display: controller input forwarded ok\n", .{});
}

/// A controller that vanishes must hand the lease to the oldest
/// remaining eligible viewer — otherwise a session survives that nobody
/// can drive. Read-only viewers are skipped by that handover.
fn handoverStage(allocator: std.mem.Allocator, sock_path: []const u8) void {
    {
        const r = runCli(allocator, &.{ "create", "--name", "dsphand", "--json", "--socket", sock_path });
        defer r.deinit(allocator);
        if (r.code != 0) failf("handover: create failed: {s}", .{r.out});
    }
    var a = Viewer.attach(allocator, sock_path, "dsphand", .{});
    defer a.deinit();
    var ro = Viewer.attach(allocator, sock_path, "dsphand", .{ .read_only = true });
    defer ro.deinit();
    var b = Viewer.attach(allocator, sock_path, "dsphand", .{});
    defer b.deinit();
    var vs = [_]*Viewer{ &a, &ro, &b };
    pumpFor(&vs, 500);
    if (!a.has_control) fail("handover: first viewer should hold the lease");
    if (ro.has_control or b.has_control) fail("handover: later viewers must be read-only");

    // The controller's process dies (socket drop, no detach).
    a.kill();
    {
        const deadline = nowMs() + 5_000;
        while (!b.has_control and nowMs() < deadline) {
            _ = ro.pump();
            _ = b.pump();
            _ = c.usleep(20_000);
        }
    }
    if (!b.has_control) fail("handover: no viewer picked up the lease after the controller died");
    if (ro.has_control) fail("handover: a read-only viewer must never be handed the lease");
    if (!std.mem.eql(u8, ro.label(), b.label())) fail("handover: viewers disagree about the new controller");
    std.debug.print("smoke-display: controller-death handover ok (now {s})\n", .{b.label()});

    // Explicit release with no eligible viewer left leaves nobody in
    // charge — and says so.
    b.requestControl("release");
    {
        const deadline = nowMs() + 5_000;
        while (b.has_control and nowMs() < deadline) {
            _ = ro.pump();
            _ = b.pump();
            _ = c.usleep(20_000);
        }
    }
    if (b.has_control) fail("handover: release did not drop the lease");
    if (ro.holder_len != 0) fail("handover: a released lease should report no controller");

    const d = runCli(allocator, &.{ "destroy", "dsphand", "--socket", sock_path });
    defer d.deinit(allocator);
    if (d.code != 0) fail("handover: destroy failed");
}
