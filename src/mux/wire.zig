//! Mux wire format: framing + Event (de)serialization.
//!
//! THE compatibility surface between sketerm-mux daemon and clients
//! (possibly different builds on different hosts). Rules:
//!   - little-endian, length-prefixed frames and payloads
//!   - tag values are append-only — never renumber, never reuse
//!   - a reader skips unknown frame types via the length prefix
//!
//! Pure code, no GTK, no sockets — unit-tested headless.

const std = @import("std");
const Event = @import("../parser/event.zig").Event;

/// Version 2 adds the byte-channel frames (chan_*) used for Wayland
/// app forwarding. The daemon only opens channels toward clients
/// whose hello announced proto >= 2; older clients keep working
/// without them. Version 3 adds the file-transfer frames (file_*):
/// the GUI streams a local file to the daemon, which writes it into
/// the session shell's working directory — so "upload to remote"
/// works over any transport (local/SSH/UDP) with no shell help. The
/// handshake (helloProbe) requires an exact proto match, so an
/// attached daemon is always the same build and understands them.
/// Version 4 widens the snapshot frame header from [seq:u64] to
/// [seq:u64][app:u8], so an attaching client learns whether the
/// session is a forwarded GUI app (`sketerm app`) and can hold the
/// pane open on app exit instead of detaching to a shell.
/// Version 5 moves the Wayland compositor brain into the daemon:
/// wayland_native channels broadcast to every attached client
/// (passive replicas), viewers drive input via seat-intent pipe
/// units, and attach replays pool bytes + a state_sync unit so app
/// windows survive detach/reattach (durable GUI apps).
pub const PROTO_VERSION: u32 = 5;

/// Frame types. Append-only.
pub const FrameType = enum(u8) {
    // client → daemon
    hello = 1,
    attach = 2,
    spawn = 3,
    input = 4,
    resize = 5,
    detach = 6,
    list = 7,
    kill = 8,
    // client → daemon (continued; append-only)
    shutdown = 9,
    rename = 10,
    // File upload (client → daemon). A transfer is a JSON `file_open`
    // (name + size), a run of `file_data` chunks ([u32 xfer | bytes]),
    // then `file_close` ([u32 xfer]). The daemon answers each with a
    // JSON `file_reply` carrying cumulative-written for flow control.
    file_open = 11,
    file_data = 12,
    file_close = 13,
    // File download (client → daemon): JSON `file_get` ({xfer, path}).
    // The daemon answers `file_reply` "ready" (with size + basename),
    // streams `file_data` chunks the OTHER way (daemon → client), then
    // `file_reply` "done". `file_data` is thus bidirectional — the
    // receiver's context (upload vs download xfer) tells the directions
    // apart.
    file_get = 14,
    // Remote directory browse (client → daemon): JSON `file_list`
    // ({xfer, path}). The daemon answers `file_listing` (a JSON
    // directory listing) so the GUI can offer a remote file picker.
    file_list = 15,
    // Installed-app discovery (client → daemon): empty payload. The
    // daemon scans its own $XDG_DATA_DIRS/applications/*.desktop and
    // answers `app_listing`, so a client can offer a launcher for the
    // apps on the session's host (the remote, over SSH/UDP).
    app_list = 16,
    /// AT-SPI request for the attached app session. Empty payload (or
    /// {op:"tree"}) = tree walk; {op:"action"|"set_text"|"set_value",
    /// id, index?/text?/value?} performs the op on one node. Answered
    /// with app_a11y_tree ({tree}, {ok:true}, or {error}).
    app_a11y = 17,
    /// Start recording the ATTACHED session's raw PTY output as an
    /// asciicast v2 file on the daemon's host. JSON { path }.
    /// Answered with ok / err. Recording survives detach; a second
    /// rec_start replaces the previous recording.
    rec_start = 18,
    /// Stop the attached session's recording. Empty payload; ok/err.
    rec_stop = 19,
    /// Search the ATTACHED session's scrollback + live grid. JSON
    /// { pattern, max? } (case-insensitive substring). Answered with
    /// `search_hits`. Attach-scoped so it reaches the worker that
    /// owns the Screen in broker mode.
    search = 20,
    /// Open a TCP forward: JSON { port } — the daemon connects to
    /// 127.0.0.1:port ON ITS HOST and answers with a `chan_open`
    /// (kind tcp_forward) owned by the requesting client; raw bytes
    /// then flow as chan_data both ways. No attach required.
    forward_open = 21,
    /// Fetch lines from the ATTACHED session's indexed log ring
    /// (escape-free PTY output, one monotonically-increasing id per
    /// line). JSON { tail?, from_id?, id?, max_chars? }; answered
    /// with `log_data`. Attach-scoped so it reaches the worker that
    /// owns the Session in broker mode.
    log_get = 22,
    // daemon → client
    welcome = 64,
    snapshot = 65,
    events = 66,
    exit = 67,
    gone = 68,
    ok = 69,
    err = 70,
    /// JSON status for an in-flight upload: { xfer, status, written,
    /// path?, message? }. status ∈ ready|progress|done|error.
    file_reply = 71,
    /// JSON directory listing answering `file_list`: { xfer, path,
    /// entries: [{name, dir, size}], error?, truncated? }.
    file_listing = 72,
    /// JSON app listing answering `app_list`: { apps: [{name, exec,
    /// icon, terminal}], truncated? }.
    app_listing = 73,
    /// JSON attach roster for the client's session, pushed whenever
    /// it changes: { total, guis, drivers } (drivers = headless MCP
    /// clients). Lets viewers show an "assistant is driving" badge.
    peer_info = 74,
    /// JSON AT-SPI tree answering app_a11y: { tree: <node> } or
    /// { error: "..." }. Node = { role, name, states, rect?, children? }.
    app_a11y_tree = 75,
    /// JSON answer to `search`: { hits: [{back, text}], total } —
    /// `back` = display lines up from the bottom of the live grid,
    /// `total` = matches found (hits capped at the request's max).
    search_hits = 76,
    /// JSON answer to `log_get`: { next_id, dropped, lines: [{id, t,
    /// text, truncated?, cut?, marker?}] }. `t` = epoch ms on the
    /// daemon's host; `truncated` = stored line was capped at ingest;
    /// `cut` = shortened to the request's max_chars in this reply.
    log_data = 77,
    /// Pushed to every attached client when the session's child emits
    /// the sketerm marker escape (OSC 5522 ; label): JSON { id, label,
    /// t } where `id` is the marker's log-ring line id. Viewers may
    /// stash a screenshot of the app's current frame against it.
    marker = 78,
    // Byte channels (both directions). Generic multiplexed streams
    // riding the mux connection — used to tunnel a session's app
    // protocol, so forwarded apps inherit whatever transport the
    // terminal uses (incl. roaming UDP). The daemon initiates with
    // chan_open; chan_data/chan_close flow both ways.
    chan_open = 80,
    chan_data = 81,
    chan_close = 82,
    /// Daemon → MCP client: native app-channel streaming toward this
    /// client is PAUSED (its outbound queue crossed the backlog cap).
    /// A replay of every native channel, rebuilt from the daemon's
    /// live mirrors and terminated by `native_sync`, follows once the
    /// client fully drains. Empty payload.
    native_gap = 83,
    /// Daemon → MCP client: the post-drain native replay is complete;
    /// the client's replicas now reflect the live mirrors. Empty.
    native_sync = 84,
    _,
};

/// chan_open payload kinds. Append-only — 1 (legacy waypipe bridge)
/// is retired and never emitted.
pub const ChannelKind = enum(u8) {
    /// Sketerm-native app pipe: chan_data carries wlhost/pipe.zig
    /// units (Wayland messages + shm pool side-band). The GUI
    /// compositor brain consumes it directly.
    wayland_native = 2,
    /// Window pixel stream (winstream/proto.zig units): remotes
    /// with no forwardable display protocol — macOS capture agent;
    /// the stub backend tests the pipeline anywhere.
    winstream = 3,
    /// Remote audio (mux/pulse.zig units): the daemon is the
    /// session's PulseAudio server; PCM streams toward the viewer,
    /// consumed/latency reports flow back as the playback clock.
    audio = 4,
    /// Raw TCP forward (answering `forward_open`): chan_data carries
    /// unframed socket bytes; 1:1 with the requesting client.
    tcp_forward = 5,
    _,
};

/// chan_open: u32 channel id + u8 kind.
pub fn encodeChanOpen(buf: *[5]u8, id: u32, kind: ChannelKind) []const u8 {
    std.mem.writeInt(u32, buf[0..4], id, .little);
    buf[4] = @intFromEnum(kind);
    return buf[0..5];
}

pub fn decodeChanOpen(payload: []const u8) ?struct { id: u32, kind: ChannelKind } {
    if (payload.len < 5) return null;
    return .{
        .id = std.mem.readInt(u32, payload[0..4], .little),
        .kind = @enumFromInt(payload[4]),
    };
}

/// chan_data: u32 channel id + raw bytes. chan_close: u32 id only.
pub fn putChanHeader(buf: *[4]u8, id: u32) []const u8 {
    std.mem.writeInt(u32, buf[0..4], id, .little);
    return buf[0..4];
}

pub fn decodeChanId(payload: []const u8) ?u32 {
    if (payload.len < 4) return null;
    return std.mem.readInt(u32, payload[0..4], .little);
}

pub const MAX_FRAME = 16 << 20; // images can be chunky; bound anyway

/// Event tags on the wire. Independent of the in-memory union order
/// (which may be rearranged freely) — append-only here.
const EventTag = enum(u8) {
    print = 1,
    print_byte = 2,
    print_run = 3,
    execute = 4,
    csi = 5,
    esc_final = 6,
    osc = 7,
    apc = 8,
    dcs = 9,
    child_eof = 10,
    parse_error = 11,
    _,
};

pub const Writer = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.allocator);
    }

    fn putInt(self: *Writer, comptime T: type, v: T) !void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, .little);
        try self.buf.appendSlice(self.allocator, &tmp);
    }

    fn putBytes(self: *Writer, b: []const u8) !void {
        try self.putInt(u32, @intCast(b.len));
        try self.buf.appendSlice(self.allocator, b);
    }

    /// Serialize one Event. Legacy markers (`dcs_start`, `dcs_data`,
    /// `dcs_end`) are never produced by the current parser and are
    /// not representable on the wire.
    pub fn putEvent(self: *Writer, ev: Event) !void {
        switch (ev) {
            .print => |cp| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.print));
                try self.putInt(u32, cp);
            },
            .print_byte => |b| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.print_byte));
                try self.buf.append(self.allocator, b);
            },
            .print_run => |r| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.print_run));
                try self.buf.append(self.allocator, r.len);
                try self.buf.appendSlice(self.allocator, r.bytes[0..r.len]);
            },
            .execute => |b| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.execute));
                try self.buf.append(self.allocator, b);
            },
            .csi => |csi| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.csi));
                try self.buf.append(self.allocator, csi.n_params);
                for (csi.params[0..csi.n_params]) |p| try self.putInt(u16, p);
                try self.putInt(u16, csi.is_sub_bits);
                try self.buf.append(self.allocator, csi.n_intermediates);
                try self.buf.appendSlice(self.allocator, csi.intermediates[0..csi.n_intermediates]);
                try self.buf.append(self.allocator, csi.private);
                try self.buf.append(self.allocator, csi.final);
            },
            .esc_final => |e| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.esc_final));
                try self.buf.append(self.allocator, e.n_intermediates);
                try self.buf.appendSlice(self.allocator, e.intermediates[0..e.n_intermediates]);
                try self.buf.append(self.allocator, e.final);
            },
            .osc => |o| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.osc));
                try self.putBytes(o.bytes);
            },
            .apc => |o| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.apc));
                try self.putBytes(o.bytes);
            },
            .dcs => |d| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.dcs));
                try self.buf.append(self.allocator, d.proto.n_params);
                for (d.proto.params[0..d.proto.n_params]) |p| try self.putInt(u16, p);
                try self.buf.append(self.allocator, d.proto.n_intermediates);
                try self.buf.appendSlice(self.allocator, d.proto.intermediates[0..d.proto.n_intermediates]);
                try self.buf.append(self.allocator, d.proto.final);
                try self.putBytes(d.body);
            },
            .child_eof => |status| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.child_eof));
                try self.putInt(i32, status);
            },
            .parse_error => |pe| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.parse_error));
                try self.buf.append(self.allocator, @intFromEnum(pe.kind));
            },
            .dcs_start, .dcs_data, .dcs_end => return error.LegacyEventNotWireable,
        }
    }
};

pub const ReadError = error{ Truncated, BadTag, TooLong, OutOfMemory };

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn atEnd(self: *const Reader) bool {
        return self.pos >= self.bytes.len;
    }

    fn take(self: *Reader, n: usize) ReadError![]const u8 {
        if (self.pos + n > self.bytes.len) return error.Truncated;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn getInt(self: *Reader, comptime T: type) ReadError!T {
        const s = try self.take(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }

    fn getByte(self: *Reader) ReadError!u8 {
        return (try self.take(1))[0];
    }

    /// Length-prefixed bytes; the returned slice is HEAP-OWNED by
    /// `allocator` (events transfer payload ownership, mirroring the
    /// parser's own allocation contract).
    fn getOwnedBytes(self: *Reader, allocator: std.mem.Allocator) ReadError![]u8 {
        const len = try self.getInt(u32);
        if (len > MAX_FRAME) return error.TooLong;
        const s = try self.take(len);
        return allocator.dupe(u8, s) catch return error.OutOfMemory;
    }

    /// Deserialize one Event. OSC/APC/DCS payloads are allocated from
    /// `allocator`; caller owns the Event (free via Event.deinit).
    pub fn getEvent(self: *Reader, allocator: std.mem.Allocator) ReadError!Event {
        const tag_byte = try self.getByte();
        const tag: EventTag = @enumFromInt(tag_byte); // non-exhaustive; switch `_` rejects
        switch (tag) {
            .print => return .{ .print = try self.getInt(u32) },
            .print_byte => return .{ .print_byte = try self.getByte() },
            .print_run => {
                var r: Event.PrintRun = .{};
                r.len = try self.getByte();
                if (r.len > r.bytes.len) return error.Truncated;
                @memcpy(r.bytes[0..r.len], try self.take(r.len));
                return .{ .print_run = r };
            },
            .execute => return .{ .execute = try self.getByte() },
            .csi => {
                var csi: Event.Csi = .{};
                csi.n_params = try self.getByte();
                if (csi.n_params > csi.params.len) return error.Truncated;
                for (0..csi.n_params) |i| csi.params[i] = try self.getInt(u16);
                csi.is_sub_bits = try self.getInt(u16);
                csi.n_intermediates = try self.getByte();
                if (csi.n_intermediates > csi.intermediates.len) return error.Truncated;
                @memcpy(csi.intermediates[0..csi.n_intermediates], try self.take(csi.n_intermediates));
                csi.private = try self.getByte();
                csi.final = try self.getByte();
                return .{ .csi = csi };
            },
            .esc_final => {
                var e: Event.EscFinal = .{};
                e.n_intermediates = try self.getByte();
                if (e.n_intermediates > e.intermediates.len) return error.Truncated;
                @memcpy(e.intermediates[0..e.n_intermediates], try self.take(e.n_intermediates));
                e.final = try self.getByte();
                return .{ .esc_final = e };
            },
            .osc => return .{ .osc = .{ .bytes = try self.getOwnedBytes(allocator) } },
            .apc => return .{ .apc = .{ .bytes = try self.getOwnedBytes(allocator) } },
            .dcs => {
                var proto: Event.Dcs = .{};
                proto.n_params = try self.getByte();
                if (proto.n_params > proto.params.len) return error.Truncated;
                for (0..proto.n_params) |i| proto.params[i] = try self.getInt(u16);
                proto.n_intermediates = try self.getByte();
                if (proto.n_intermediates > proto.intermediates.len) return error.Truncated;
                @memcpy(proto.intermediates[0..proto.n_intermediates], try self.take(proto.n_intermediates));
                proto.final = try self.getByte();
                const body = try self.getOwnedBytes(allocator);
                return .{ .dcs = .{ .proto = proto, .body = body } };
            },
            .child_eof => return .{ .child_eof = try self.getInt(i32) },
            .parse_error => {
                const kind = std.enums.fromInt(Event.ParseError.Kind, try self.getByte()) orelse return error.BadTag;
                return .{ .parse_error = .{ .kind = kind } };
            },
            _ => return error.BadTag,
        }
    }
};

/// Write one frame (type + payload) to a buffer: u32 len, u8 type,
/// payload. `len` covers type + payload.
pub fn appendFrame(out: *std.ArrayList(u8), allocator: std.mem.Allocator, ftype: FrameType, payload: []const u8) !void {
    var hdr: [5]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload.len + 1), .little);
    hdr[4] = @intFromEnum(ftype);
    try out.appendSlice(allocator, &hdr);
    try out.appendSlice(allocator, payload);
}

/// Parsed frame view into the input buffer (payload not copied).
pub const Frame = struct {
    ftype: FrameType,
    payload: []const u8,
};

/// Try to split one frame off `bytes`. Returns null when incomplete.
/// On success, `consumed` is the total size to drop from the stream.
pub fn peelFrame(bytes: []const u8) error{ TooLong, Malformed }!?struct { frame: Frame, consumed: usize } {
    if (bytes.len < 5) return null;
    const len = std.mem.readInt(u32, bytes[0..4], .little);
    if (len == 0) return error.Malformed;
    if (len > MAX_FRAME) return error.TooLong;
    if (bytes.len < 4 + len) return null;
    return .{
        .frame = .{
            .ftype = @enumFromInt(bytes[4]),
            .payload = bytes[5 .. 4 + len],
        },
        .consumed = 4 + len,
    };
}

/// Progress of a PARTIALLY buffered frame: bytes the frame declares
/// vs bytes arrived. Null when the buffer is empty or holds a
/// complete frame — only useful for "stuck at N of M" diagnostics.
pub fn partialInfo(bytes: []const u8) ?struct { expected: usize, have: usize } {
    if (bytes.len == 0) return null;
    if (bytes.len < 5) return .{ .expected = 5, .have = bytes.len };
    const len = std.mem.readInt(u32, bytes[0..4], .little);
    if (bytes.len >= 4 + @as(usize, len)) return null; // complete
    return .{ .expected = 4 + @as(usize, len), .have = bytes.len };
}

// ── tests ───────────────────────────────────────────────────────

fn roundtrip(allocator: std.mem.Allocator, ev: Event) !Event {
    var w = Writer.init(allocator);
    defer w.deinit();
    try w.putEvent(ev);
    var r = Reader.init(w.buf.items);
    const out = try r.getEvent(allocator);
    try std.testing.expect(r.atEnd());
    return out;
}

test "wire: simple events round-trip" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 0x1F600), (try roundtrip(a, .{ .print = 0x1F600 })).print);
    try std.testing.expectEqual(@as(u8, 'x'), (try roundtrip(a, .{ .print_byte = 'x' })).print_byte);
    try std.testing.expectEqual(@as(u8, 0x07), (try roundtrip(a, .{ .execute = 0x07 })).execute);
    try std.testing.expectEqual(@as(i32, 42), (try roundtrip(a, .{ .child_eof = 42 })).child_eof);

    var run: Event.PrintRun = .{};
    const txt = "hello world";
    @memcpy(run.bytes[0..txt.len], txt);
    run.len = txt.len;
    const out = try roundtrip(a, .{ .print_run = run });
    try std.testing.expectEqualStrings(txt, out.print_run.bytes[0..out.print_run.len]);
}

test "wire: csi round-trips params, sub-bits, intermediates, private" {
    const a = std.testing.allocator;
    var csi: Event.Csi = .{};
    csi.params = .{ 38, 2, 255, 128, 0 } ++ .{0} ** 11;
    csi.n_params = 5;
    csi.setSub(1, true);
    csi.setSub(2, true);
    csi.intermediates[0] = '$';
    csi.n_intermediates = 1;
    csi.private = '?';
    csi.final = 'm';
    const out = (try roundtrip(a, .{ .csi = csi })).csi;
    try std.testing.expectEqual(csi.n_params, out.n_params);
    try std.testing.expectEqualSlices(u16, csi.params[0..5], out.params[0..5]);
    try std.testing.expectEqual(csi.is_sub_bits, out.is_sub_bits);
    try std.testing.expectEqual(@as(u8, '$'), out.intermediates[0]);
    try std.testing.expectEqual(@as(u8, '?'), out.private);
    try std.testing.expectEqual(@as(u8, 'm'), out.final);
}

test "wire: owned payloads round-trip (osc / apc / dcs)" {
    const a = std.testing.allocator;

    const osc_src = try a.dupe(u8, "0;my title");
    defer a.free(osc_src);
    var osc_out = try roundtrip(a, .{ .osc = .{ .bytes = osc_src } });
    defer osc_out.deinit(a);
    try std.testing.expectEqualStrings("0;my title", osc_out.osc.bytes);

    const apc_src = try a.dupe(u8, "Gf=32,s=2,v=2;AAAA");
    defer a.free(apc_src);
    var apc_out = try roundtrip(a, .{ .apc = .{ .bytes = apc_src } });
    defer apc_out.deinit(a);
    try std.testing.expectEqualStrings("Gf=32,s=2,v=2;AAAA", apc_out.apc.bytes);

    var proto: Event.Dcs = .{};
    proto.params[0] = 1;
    proto.n_params = 1;
    proto.final = 'q';
    const body_src = try a.dupe(u8, "#0;2;0;0;0sixels");
    defer a.free(body_src);
    var dcs_out = try roundtrip(a, .{ .dcs = .{ .proto = proto, .body = body_src } });
    defer dcs_out.deinit(a);
    try std.testing.expectEqual(@as(u16, 1), dcs_out.dcs.proto.params[0]);
    try std.testing.expectEqual(@as(u8, 'q'), dcs_out.dcs.proto.final);
    try std.testing.expectEqualStrings("#0;2;0;0;0sixels", dcs_out.dcs.body);
}

test "wire: parse_error round-trips every kind" {
    const a = std.testing.allocator;
    for ([_]Event.ParseError.Kind{ .dcs_truncated, .osc_truncated, .apc_truncated }) |kind| {
        const out = try roundtrip(a, .{ .parse_error = .{ .kind = kind } });
        try std.testing.expectEqual(kind, out.parse_error.kind);
    }
    // Unknown kind byte is rejected, not panicked.
    var r = Reader.init(&[_]u8{ @intFromEnum(EventTag.parse_error), 99 });
    try std.testing.expectError(error.BadTag, r.getEvent(a));
}

test "wire: corrupt input errors, never panics" {
    const a = std.testing.allocator;
    // Unknown tag.
    var r1 = Reader.init(&[_]u8{255});
    try std.testing.expectError(error.BadTag, r1.getEvent(a));
    // Truncated CSI.
    var r2 = Reader.init(&[_]u8{ @intFromEnum(EventTag.csi), 5, 1, 0 });
    try std.testing.expectError(error.Truncated, r2.getEvent(a));
    // print_run with absurd length byte.
    var r3 = Reader.init(&[_]u8{ @intFromEnum(EventTag.print_run), 200 });
    try std.testing.expectError(error.Truncated, r3.getEvent(a));
    // OSC with length larger than buffer.
    var r4 = Reader.init(&[_]u8{ @intFromEnum(EventTag.osc), 0xFF, 0xFF, 0xFF, 0x7F });
    try std.testing.expectError(error.TooLong, r4.getEvent(a));
}

test "wire: frame peel handles partial + complete + unknown type" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendFrame(&out, a, .input, "ls\n");
    try appendFrame(&out, a, @enumFromInt(200), "future");

    // Partial: only half the first frame.
    try std.testing.expectEqual(@as(?@TypeOf((try peelFrame(out.items)).?), null), try peelFrame(out.items[0..3]));

    const p1 = (try peelFrame(out.items)).?;
    try std.testing.expectEqual(FrameType.input, p1.frame.ftype);
    try std.testing.expectEqualStrings("ls\n", p1.frame.payload);

    // Unknown frame type still peels cleanly (skippable by caller).
    const rest = out.items[p1.consumed..];
    const p2 = (try peelFrame(rest)).?;
    try std.testing.expectEqualStrings("future", p2.frame.payload);
    try std.testing.expectEqual(p1.consumed + p2.consumed, out.items.len);

    // Zero-length frame is malformed.
    const zero = [_]u8{ 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.Malformed, peelFrame(&zero));
}

test "partialInfo reports expected-vs-buffered for a half frame" {
    const t2 = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t2.allocator);
    try appendFrame(&out, t2.allocator, .events, "hello world");
    // Complete frame → null.
    try t2.expectEqual(@as(?@TypeOf(partialInfo("").?), null), partialInfo(out.items));
    // Half a frame → declared total vs buffered so far.
    const half = out.items[0 .. out.items.len - 4];
    const p = partialInfo(half).?;
    try t2.expectEqual(out.items.len, p.expected);
    try t2.expectEqual(half.len, p.have);
    // Empty buffer → null.
    try t2.expectEqual(@as(?@TypeOf(p), null), partialInfo(""));
}
