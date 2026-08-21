//! External display sessions + the controller lease, end to end.
//!
//! Shared stage: `smoke-mux` runs it against a MONOLITH daemon and
//! `smoke-broker` against a real broker (whose per-session workers make
//! the 'Y'/'A' control datagrams load-bearing). Broker-only regressions
//! in exactly that hop have shipped before while monolith smokes stayed
//! green, so both is not redundancy — it is the point.
//!
//! Covered: `display create` returns a usable environment and output mode;
//! `display run` owns command status + cleanup; the
//! returned Wayland socket accepts an EXTERNAL client (a stock
//! weston-terminal sketerm never spawned); duplicate names are refused;
//! `inspect`/`list` report the session; TTL pauses for a live external
//! client then kills an abandoned session; `destroy` closes the listener;
//! display-only destruction cannot kill a shell session; and the controller
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
    err: []u8,

    fn deinit(self: CliResult, allocator: std.mem.Allocator) void {
        allocator.free(self.out);
        allocator.free(self.err);
    }
};

fn runCli(allocator: std.mem.Allocator, argv: []const []const u8) CliResult {
    var out_fds: [2]c_int = undefined;
    var err_fds: [2]c_int = undefined;
    if (c.pipe(&out_fds) != 0 or c.pipe(&err_fds) != 0) fail("pipe");
    const saved_out = c.dup(1);
    const saved_err = c.dup(2);
    if (saved_out < 0 or saved_err < 0) fail("dup output");
    _ = c.dup2(out_fds[1], 1);
    _ = c.dup2(err_fds[1], 2);
    _ = c.close(out_fds[1]);
    _ = c.close(err_fds[1]);
    const code = display_cli.run(allocator, argv);
    _ = c.dup2(saved_out, 1);
    _ = c.dup2(saved_err, 2);
    _ = c.close(saved_out);
    _ = c.close(saved_err);

    var out: std.ArrayList(u8) = .empty;
    while (true) {
        var buf: [4096]u8 = undefined;
        const n = c.read(out_fds[0], &buf, buf.len);
        if (n <= 0) break;
        out.appendSlice(allocator, buf[0..@intCast(n)]) catch fail("oom");
    }
    _ = c.close(out_fds[0]);
    var err: std.ArrayList(u8) = .empty;
    while (true) {
        var buf: [4096]u8 = undefined;
        const n = c.read(err_fds[0], &buf, buf.len);
        if (n <= 0) break;
        err.appendSlice(allocator, buf[0..@intCast(n)]) catch fail("oom");
    }
    _ = c.close(err_fds[0]);
    return .{
        .code = code,
        .out = out.toOwnedSlice(allocator) catch fail("oom"),
        .err = err.toOwnedSlice(allocator) catch fail("oom"),
    };
}

const CreateReply = struct {
    session: []const u8 = "",
    origin_id: []const u8 = "",
    pid: i32 = 0,
    output: struct {
        width: u32 = 0,
        height: u32 = 0,
    } = .{},
    gpu: bool = false,
    xwayland: bool = false,
    environment: struct {
        WAYLAND_DISPLAY: []const u8 = "",
        XDG_RUNTIME_DIR: []const u8 = "",
        PULSE_SERVER: []const u8 = "",
        LIBGL_ALWAYS_SOFTWARE: []const u8 = "",
        DISPLAY: []const u8 = "",
        XAUTHORITY: []const u8 = "",
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

fn connectSocket(path: []const u8) c_int {
    const fd = @import("util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return -1;
    var addr: c.struct_sockaddr_un = undefined;
    @import("mux/daemon.zig").fillSockaddrUn(&addr, path) catch {
        _ = c.close(fd);
        return -1;
    };
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
        _ = c.close(fd);
        return -1;
    }
    return fd;
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
    const opened = (pulse.peelUnit(descriptors.payload[4..]) catch fail("audio: missing open descriptor")) orelse fail("audio: missing open descriptor");
    if (opened.tag != .open) fail("audio: first replayed unit was not open");
    const metadata = (pulse.peelUnit(descriptors.payload[4 + opened.consumed ..]) catch fail("audio: missing metadata descriptor")) orelse fail("audio: missing metadata descriptor");
    if (metadata.tag != .metadata) fail("audio: metadata did not follow open");
    const cork = (pulse.peelUnit(descriptors.payload[4 + opened.consumed + metadata.consumed ..]) catch fail("audio: missing cork descriptor")) orelse fail("audio: missing cork descriptor");
    if (cork.tag != .cork or cork.payload.len < 5 or cork.payload[4] != 0) fail("audio: initial cork state was not replayed");

    paDataSend(fd, a, 0, "\x01\x02\x03\x04");
    const pcm = viewer.recvExpectFor(&.{.chan_data}, 15_000) catch fail("audio: subscribed viewer did not receive PCM");
    defer pcm.deinit(a);
    if (pcm.payload.len < 4) fail("audio: malformed PCM channel data");
    const pcm_unit = (pulse.peelUnit(pcm.payload[4..]) catch fail("audio: malformed PCM unit")) orelse fail("audio: malformed PCM unit");
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
    const replayed_unit = if (replayed.payload.len >= 4) pulse.peelUnit(replayed.payload[4..]) catch null else null;
    if (replayed_unit == null or replayed_unit.?.tag != .open) fail("audio: subscribed reattach did not replay descriptors first");
    replayed.deinit(a);
    const replayed_pcm = viewer.recvExpectFor(&.{.chan_data}, 15_000) catch fail("audio: PCM missing after subscribed reattach descriptors");
    const replayed_pcm_unit = if (replayed_pcm.payload.len >= 4) pulse.peelUnit(replayed_pcm.payload[4..]) catch null else null;
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

fn spawnExternalX11(display: []const u8, authority: []const u8) c.pid_t {
    var display_buf: [64:0]u8 = undefined;
    const display_z = std.fmt.bufPrintZ(&display_buf, "{s}", .{display}) catch fail("X11 display too long");
    var auth_buf: [4096:0]u8 = undefined;
    const auth_z = std.fmt.bufPrintZ(&auth_buf, "{s}", .{authority}) catch fail("Xauthority path too long");
    const pid = c.fork();
    if (pid < 0) fail("fork X11 app");
    if (pid == 0) {
        const null_fd = c.open("/dev/null", c.O_RDWR | c.O_CLOEXEC);
        if (null_fd >= 0) {
            _ = c.dup2(null_fd, 0);
            _ = c.dup2(null_fd, 1);
            _ = c.dup2(null_fd, 2);
            if (null_fd > 2) _ = c.close(null_fd);
        }
        _ = c.setenv("DISPLAY", display_z.ptr, 1);
        _ = c.setenv("XAUTHORITY", auth_z.ptr, 1);
        _ = c.unsetenv("WAYLAND_DISPLAY");
        _ = c.unsetenv("WAYLAND_SOCKET");
        const argv = [_:null]?[*:0]const u8{
            "/usr/bin/xterm", "-geometry", "40x10", "-title", "sketerm-x11-smoke", null,
        };
        _ = c.execv("/usr/bin/xterm", @ptrCast(@constCast(&argv)));
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
    var dsp1_pid: i32 = 0;
    var dsp1_origin_id: @import("mux/wire.zig").SessionOriginId = undefined;
    {
        const r = runCli(allocator, &.{ "create", "--name", "dsp1", "--size", "1024x768", "--no-xwayland", "--json", "--socket", sock_path });
        defer r.deinit(allocator);
        if (r.code != 0) failf("create failed (exit {d}): {s}", .{ r.code, r.out });
        var parsed = std.json.parseFromSlice(CreateReply, allocator, r.out, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch failf("create output is not the documented JSON: {s}", .{r.out});
        defer parsed.deinit();
        const env = parsed.value.environment;
        if (!std.mem.eql(u8, parsed.value.session, "dsp1")) fail("create: wrong session name in reply");
        if (!@import("mux/wire.zig").validSessionOriginId(parsed.value.origin_id))
            fail("create: no valid session origin id in reply");
        @memcpy(&dsp1_origin_id, parsed.value.origin_id);
        dsp1_pid = parsed.value.pid;
        if (dsp1_pid <= 0) fail("create: no keeper pid in reply");
        if (parsed.value.output.width != 1024 or parsed.value.output.height != 768)
            fail("create: requested output size missing from reply");
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
        const r = runCli(allocator, &.{ "create", "--name", "dsp1", "--no-xwayland", "--json", "--socket", sock_path });
        defer r.deinit(allocator);
        if (r.code == 0) fail("create: duplicate name was accepted");
        if (std.mem.indexOf(u8, r.err, "session 'dsp1' already exists") == null)
            failf("create: duplicate diagnostic omitted the session name: {s}", .{r.err});
    }

    // Help is command-local and must not contact the daemon.
    {
        const r = runCli(allocator, &.{ "create", "--help", "--socket", "/definitely/not/a/socket" });
        defer r.deinit(allocator);
        if (r.code != 0 or std.mem.indexOf(u8, r.out, "--size WxH") == null)
            fail("create --help was not available without a daemon");
    }

    // ── --gpu drops the software-GL force ─────────────────────────
    {
        const r = runCli(allocator, &.{ "create", "--name", "dspgpu", "--gpu", "--no-xwayland", "--json", "--socket", sock_path });
        defer r.deinit(allocator);
        if (r.code != 0) failf("create --gpu failed: {s}", .{r.out});
        if (std.mem.indexOf(u8, r.out, "\"LIBGL_ALWAYS_SOFTWARE\":\"1\"") != null)
            fail("create --gpu must not export LIBGL_ALWAYS_SOFTWARE");
        const inspect_gpu = runCli(allocator, &.{ "inspect", "dspgpu", "--json", "--socket", sock_path });
        defer inspect_gpu.deinit(allocator);
        if (inspect_gpu.code != 0 or std.mem.indexOf(u8, inspect_gpu.out, "\"gpu\":true") == null or
            std.mem.indexOf(u8, inspect_gpu.out, "\"LIBGL_ALWAYS_SOFTWARE\":\"1\"") != null)
            fail("inspect did not preserve the display's GPU policy");
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
                std.mem.indexOf(u8, r.out, "\"width\":1024") != null and
                std.mem.indexOf(u8, r.out, "\"height\":768") != null and
                std.mem.indexOf(u8, r.out, "\"controller\":null") != null;
            if (ok) break;
            if (tries == 99) failf("inspect fields never became right: {s}", .{r.out});
            _ = c.usleep(50_000);
        }
    }
    if (!hasDisplay(allocator, sock_path, "dsp1")) fail("list: dsp1 missing");
    {
        var conn = client_mod.Conn.connectProbed(allocator, sock_path) catch fail("identity guard: connect");
        defer conn.deinit();
        conn.sendKill(.{
            .name = "dsp1",
            .origin_id = &dsp1_origin_id,
            .require_display = true,
            .expected_pid = dsp1_pid + 1,
            .expected_wl_display = wl_path,
        }) catch fail("identity guard: send");
        if (conn.recvExpectFor(&.{.ok}, 15_000)) |frame| {
            frame.deinit(allocator);
            fail("identity guard: stale identity was accepted");
        } else |err| if (err != error.DaemonError) {
            fail("identity guard: unexpected reply error");
        }
        if (!hasDisplay(allocator, sock_path, "dsp1")) fail("identity guard killed the wrong display incarnation");
    }
    std.debug.print("smoke-display: inspect + list ok\n", .{});

    // `run` is the xvfb-run-shaped path: environment is applied without
    // eval/jq, command status is preserved, and both success/failure clean up.
    {
        const r = runCli(allocator, &.{
            "run",     "--name", "dsprun",                                                                                                                                              "--size", "320x200", "--no-xwayland", "--socket", sock_path, "--",
            "/bin/sh", "-c",     "test \"$XDG_SESSION_TYPE\" = wayland && test -z \"$DISPLAY\" && test -z \"$WAYLAND_SOCKET\" && test \"$LIBGL_ALWAYS_SOFTWARE\" = 1 && printf run-ok",
        });
        defer r.deinit(allocator);
        if (r.code != 0 or !std.mem.eql(u8, r.out, "run-ok"))
            failf("display run environment/status failed ({d}): out={s} err={s}", .{ r.code, r.out, r.err });
        if (hasDisplay(allocator, sock_path, "dsprun")) fail("display run leaked its successful session");
    }
    {
        const r = runCli(allocator, &.{ "run", "--name", "dsprun-fail", "--no-xwayland", "--socket", sock_path, "--", "/bin/sh", "-c", "exit 23" });
        defer r.deinit(allocator);
        if (r.code != 23) failf("display run returned {d}, want command status 23", .{r.code});
        if (hasDisplay(allocator, sock_path, "dsprun-fail")) fail("display run leaked its failed session");
    }
    { // The runner lease, not an app connection, keeps a short TTL paused.
        const r = runCli(allocator, &.{ "run", "--name", "dsprun-ttl", "--ttl", "1", "--no-xwayland", "--socket", sock_path, "--", "/bin/sh", "-c", "sleep 2" });
        defer r.deinit(allocator);
        if (r.code != 0) failf("display run was reaped by its own TTL: {s}", .{r.err});
        if (hasDisplay(allocator, sock_path, "dsprun-ttl")) fail("TTL runner lease test leaked its display");
    }
    { // --gpu must remove, not merely decline to add, a software override.
        const prior = if (c.getenv("LIBGL_ALWAYS_SOFTWARE")) |p| allocator.dupe(u8, std.mem.span(p)) catch fail("oom") else null;
        defer {
            if (prior) |p| allocator.free(p);
        }
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        defer {
            if (prior) |p| {
                var zbuf: [128:0]u8 = undefined;
                const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{p}) catch fail("prior LIBGL value too long");
                _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", z.ptr, 1);
            } else _ = c.unsetenv("LIBGL_ALWAYS_SOFTWARE");
        }
        const r = runCli(allocator, &.{ "run", "--name", "dsprun-gpu", "--gpu", "--no-xwayland", "--socket", sock_path, "--", "/bin/sh", "-c", "test -z \"$LIBGL_ALWAYS_SOFTWARE\" && printf gpu-ok" });
        defer r.deinit(allocator);
        if (r.code != 0 or !std.mem.eql(u8, r.out, "gpu-ok"))
            failf("display run --gpu inherited software GL: out={s} err={s}", .{ r.out, r.err });
    }
    { // Signals reach the command group, its status wins, then cleanup runs.
        const runner_pid = c.fork();
        if (runner_pid < 0) fail("signal run: fork");
        if (runner_pid == 0) {
            const code = display_cli.run(allocator, &.{ "run", "--name", "dsprun-signal", "--no-xwayland", "--socket", sock_path, "--", "/bin/sh", "-c", "trap 'exit 42' TERM; while :; do sleep 1; done" });
            c._exit(code);
        }
        var appeared = false;
        var tries: usize = 0;
        while (tries < 100) : (tries += 1) {
            if (hasDisplay(allocator, sock_path, "dsprun-signal")) {
                appeared = true;
                break;
            }
            _ = c.usleep(50_000);
        }
        if (!appeared) fail("signal run: display never appeared");
        _ = c.usleep(250_000);
        _ = c.kill(runner_pid, c.SIGTERM);
        var status: c_int = 0;
        _ = c.waitpid(runner_pid, &status, 0);
        if (!c.WIFEXITED(status) or c.WEXITSTATUS(status) != 42)
            failf("signal run: wrapper status was {d}, want 42", .{status});
        if (hasDisplay(allocator, sock_path, "dsprun-signal")) fail("signal run leaked its display");
    }
    { // A SIGKILLed runner drops its lease; TTL then cleans the orphaned hub.
        const runner_pid = c.fork();
        if (runner_pid < 0) fail("killed run: fork");
        if (runner_pid == 0) {
            const code = display_cli.run(allocator, &.{ "run", "--name", "dsprun-killed", "--ttl", "1", "--no-xwayland", "--socket", sock_path, "--", "/bin/sh", "-c", "sleep 3" });
            c._exit(code);
        }
        var appeared = false;
        var tries: usize = 0;
        while (tries < 100) : (tries += 1) {
            if (hasDisplay(allocator, sock_path, "dsprun-killed")) {
                appeared = true;
                break;
            }
            _ = c.usleep(50_000);
        }
        if (!appeared) fail("killed run: display never appeared");
        _ = c.usleep(250_000);
        _ = c.kill(runner_pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(runner_pid, &status, 0);
        tries = 0;
        while (tries < 100 and hasDisplay(allocator, sock_path, "dsprun-killed")) : (tries += 1)
            _ = c.usleep(50_000);
        if (hasDisplay(allocator, sock_path, "dsprun-killed")) fail("killed run: lease stayed alive after runner death");
    }
    std.debug.print("smoke-display: scoped run environment + status + cleanup ok\n", .{});

    // The display namespace shares ordinary mux session names. Guarded kill
    // must reject a shell rather than turning a typo into data loss.
    {
        var conn = client_mod.Conn.connectProbed(allocator, sock_path) catch fail("guard: connect");
        defer conn.deinit();
        conn.sendJson(.spawn, .{ .name = "ordinary", .argv = &.{ "/bin/sh", "-c", "sleep 30" } }) catch fail("guard: spawn send");
        (conn.recvExpectFor(&.{.ok}, 15_000) catch fail("guard: spawn reply")).deinit(allocator);
        const d = runCli(allocator, &.{ "destroy", "ordinary", "--socket", sock_path });
        defer d.deinit(allocator);
        if (d.code == 0 or std.mem.indexOf(u8, d.err, "not a display session") == null)
            fail("display destroy did not reject an ordinary mux session");
        conn.sendJson(.kill, .{ .name = "ordinary" }) catch fail("guard: cleanup send");
        (conn.recvExpectFor(&.{.ok}, 15_000) catch fail("guard: cleanup reply")).deinit(allocator);
    }
    std.debug.print("smoke-display: display-only destroy guard ok\n", .{});

    // ── an uncorked stream flips list's audio flag (and back) ─────
    audioStage(allocator, sock_path, "dsp1", pulse_server);

    // ── the controller lease, against a real external app ─────────
    if (c.access("/usr/bin/weston-terminal", c.X_OK) == 0)
        leaseStage(allocator, sock_path, wl_path)
    else
        std.debug.print("smoke-display: lease stage SKIPPED (no weston-terminal)\n", .{});

    // ── rootless X11 windows traverse satellite -> xdg-shell ──────
    if (c.access("/usr/bin/Xwayland", c.X_OK) == 0 and
        c.access("/usr/bin/xwayland-satellite", c.X_OK) == 0 and
        c.access("/usr/bin/xterm", c.X_OK) == 0)
        xwaylandStage(allocator, sock_path)
    else
        std.debug.print("smoke-display: rootless Xwayland stage SKIPPED (runtime tools missing)\n", .{});

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

    // ── TTL: a live renderer pauses it; disconnect starts it ──────
    var ttl_path_buf: [4096]u8 = undefined;
    var ttl_path_len: usize = 0;
    {
        const r = runCli(allocator, &.{ "create", "--name", "dspttl", "--ttl", "1", "--no-xwayland", "--json", "--socket", sock_path });
        defer r.deinit(allocator);
        if (r.code != 0) failf("create --ttl failed: {s}", .{r.out});
        var parsed = std.json.parseFromSlice(CreateReply, allocator, r.out, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch fail("ttl: create reply parse");
        defer parsed.deinit();
        ttl_path_len = parsed.value.environment.WAYLAND_DISPLAY.len;
        @memcpy(ttl_path_buf[0..ttl_path_len], parsed.value.environment.WAYLAND_DISPLAY);
    }
    if (!hasDisplay(allocator, sock_path, "dspttl")) fail("ttl: session missing right after create");
    const held_client = connectSocket(ttl_path_buf[0..ttl_path_len]);
    if (held_client < 0) fail("ttl: could not connect external Wayland client");
    {
        var tries: usize = 0;
        while (tries < 25) : (tries += 1) {
            _ = c.usleep(100_000);
            if (!hasDisplay(allocator, sock_path, "dspttl"))
                fail("ttl: reaped a display while an external Wayland client was connected");
        }
    }
    _ = c.close(held_client);
    {
        // The complete TTL starts at disconnect; a worker additionally has
        // to exit and be reaped by the broker.
        var tries: usize = 0;
        while (tries < 120) : (tries += 1) {
            if (!hasDisplay(allocator, sock_path, "dspttl")) break;
            _ = c.usleep(100_000);
        }
        if (hasDisplay(allocator, sock_path, "dspttl")) fail("ttl: never-attached session outlived its ttl");
    }
    std.debug.print("smoke-display: ttl active-client pause + expiry ok\n", .{});
}

/// A real X11-only xterm must authenticate, become a normal forwarded
/// toplevel, obey the controller close, and not let satellite defeat TTL.
fn xwaylandStage(allocator: std.mem.Allocator, sock_path: []const u8) void {
    if (c.access("/usr/bin/xprop", c.X_OK) == 0) {
        const run_result = runCli(allocator, &.{
            "run",     "--name", "dspx11-run",                                                                                              "--xwayland", "--socket", sock_path, "--",
            "/bin/sh", "-c",     "test -n \"$DISPLAY\" && test -r \"$XAUTHORITY\" && /usr/bin/xprop -root >/dev/null && printf x11-run-ok",
        });
        defer run_result.deinit(allocator);
        if (run_result.code != 0 or !std.mem.eql(u8, run_result.out, "x11-run-ok"))
            failf("Xwayland run environment/auth failed: out={s} err={s}", .{ run_result.out, run_result.err });
        if (hasDisplay(allocator, sock_path, "dspx11-run")) fail("Xwayland run leaked its display");
    }
    var display_buf: [64]u8 = undefined;
    var display_len: usize = 0;
    var auth_buf: [4096]u8 = undefined;
    var auth_len: usize = 0;
    {
        const r = runCli(allocator, &.{ "create", "--name", "dspx11", "--xwayland", "--ttl", "1", "--json", "--socket", sock_path });
        defer r.deinit(allocator);
        if (r.code != 0) failf("Xwayland create failed: out={s} err={s}", .{ r.out, r.err });
        var parsed = std.json.parseFromSlice(CreateReply, allocator, r.out, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch failf("Xwayland create output is not isolated JSON: {s}", .{r.out});
        defer parsed.deinit();
        if (!parsed.value.xwayland) fail("required Xwayland was not reported active");
        const env = parsed.value.environment;
        if (env.DISPLAY.len < 2 or env.DISPLAY[0] != ':') fail("Xwayland create omitted DISPLAY");
        if (env.XAUTHORITY.len == 0) fail("Xwayland create omitted XAUTHORITY");
        var zbuf: [4096:0]u8 = undefined;
        const auth_z = std.fmt.bufPrintZ(&zbuf, "{s}", .{env.XAUTHORITY}) catch fail("Xauthority path too long");
        var st: c.struct_stat = undefined;
        if (c.stat(auth_z.ptr, &st) != 0 or st.st_mode & 0o777 != 0o600)
            fail("Xauthority is missing or not mode 0600");
        display_len = env.DISPLAY.len;
        auth_len = env.XAUTHORITY.len;
        @memcpy(display_buf[0..display_len], env.DISPLAY);
        @memcpy(auth_buf[0..auth_len], env.XAUTHORITY);
    }
    const display = display_buf[0..display_len];
    const authority = auth_buf[0..auth_len];
    if (!listContains(allocator, sock_path, "\"xwayland\":true"))
        fail("Xwayland state did not cross the worker/broker metadata path");

    g_frames = 0;
    g_sid = 0;
    g_gone = 0;
    const app_pid = spawnExternalX11(display, authority);
    var app_reaped = false;
    defer if (!app_reaped) {
        _ = c.kill(app_pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(app_pid, &status, 0);
    };
    {
        var viewer = Viewer.attach(allocator, sock_path, "dspx11", .{ .replica = true });
        defer viewer.deinit();
        const deadline = nowMs() + 30_000;
        while (g_frames == 0 and nowMs() < deadline) {
            _ = viewer.pump();
            if (!childAlive(app_pid)) fail("xterm died before committing a rootless window");
            _ = c.usleep(20_000);
        }
        if (g_frames == 0 or g_sid == 0) fail("xterm never became a forwarded rootless toplevel");
    }

    // No viewer is attached now. The X11 toplevel itself must pause TTL even
    // though every X window is multiplexed through satellite's auxiliary
    // host-Wayland connection.
    var live_tries: usize = 0;
    while (live_tries < 25) : (live_tries += 1) {
        _ = c.usleep(100_000);
        if (!hasDisplay(allocator, sock_path, "dspx11"))
            fail("TTL reaped a display while an X11 toplevel was active");
        if (!childAlive(app_pid)) fail("xterm died during the no-viewer TTL check");
    }

    {
        var viewer = Viewer.attach(allocator, sock_path, "dspx11", .{});
        defer viewer.deinit();
        const replay_deadline = nowMs() + 10_000;
        while (viewer.chan == 0 and nowMs() < replay_deadline) {
            _ = viewer.pump();
            _ = c.usleep(20_000);
        }
        if (viewer.chan == 0) fail("X11 channel did not replay after a viewerless interval");
        viewer.requestClose(g_sid);
        const close_deadline = nowMs() + 10_000;
        while (nowMs() < close_deadline) {
            _ = viewer.pump();
            if (!childAlive(app_pid)) {
                app_reaped = true;
                break;
            }
            _ = c.usleep(20_000);
        }
        if (!app_reaped) fail("controller close did not reach the X11 client");
    }

    // With the last X11 toplevel gone, satellite itself is not occupancy.
    var tries: usize = 0;
    while (tries < 150 and hasDisplay(allocator, sock_path, "dspx11")) : (tries += 1)
        _ = c.usleep(100_000);
    if (hasDisplay(allocator, sock_path, "dspx11"))
        fail("xwayland-satellite kept an otherwise abandoned display alive past TTL");
    var auth_zbuf: [4096:0]u8 = undefined;
    const auth_z = std.fmt.bufPrintZ(&auth_zbuf, "{s}", .{authority}) catch fail("Xauthority path too long");
    if (c.access(auth_z.ptr, c.F_OK) == 0) fail("Xauthority survived display teardown");
    var x_socket_buf: [128:0]u8 = undefined;
    const x_socket = std.fmt.bufPrintZ(&x_socket_buf, "/tmp/.X11-unix/X{s}", .{display[1..]}) catch fail("X socket path too long");
    if (c.access(x_socket.ptr, c.F_OK) == 0) fail("X11 listener survived display teardown");
    var x_lock_buf: [128:0]u8 = undefined;
    const x_lock = std.fmt.bufPrintZ(&x_lock_buf, "/tmp/.X{s}-lock", .{display[1..]}) catch fail("X lock path too long");
    if (c.access(x_lock.ptr, c.F_OK) == 0) fail("X11 lock survived display teardown");
    std.debug.print("smoke-display: authenticated rootless X11 frame + close + auxiliary TTL ok\n", .{});
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
        const r = runCli(allocator, &.{ "create", "--name", "dsphand", "--no-xwayland", "--json", "--socket", sock_path });
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
