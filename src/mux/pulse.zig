//! PulseAudio native-protocol server for remote-audio forwarding:
//! the daemon IS the session's audio server, the same way it is the
//! session's Wayland display. Pure state machine — no sockets, no
//! libpulse — fed app→server bytes, producing server→app reply bytes
//! plus "audio units" toward the attached viewer (GUI), which plays
//! them through ITS local audio stack.
//!
//! Scope: playback only, protocol v13 (every libpulse since 0.9.11
//! negotiates down to it; the version-gated reply layouts below match
//! pulsecore/protocol-native.c exactly). SHM/memfd memblocks are
//! REFUSED in the AUTH reply, so all sample data arrives inline on
//! the socket — which is what can ride the mux wire.
//!
//! Wire format notes (all BIG-endian, unlike everything else here):
//! frames are a 20-byte descriptor (length, channel, offset hi/lo,
//! flags) + payload. channel 0xffffffff = control (a tagstruct:
//! type-tagged values); anything else = PCM for that stream.

const std = @import("std");
const opuscodec = @import("opuscodec.zig");

pub const Error = error{ Protocol, OutOfMemory };

// ── protocol constants (pulsecore/native-common.h) ──────────────

const CMD_ERROR = 0;
const CMD_REPLY = 2;
const CMD_CREATE_PLAYBACK_STREAM = 3;
const CMD_DELETE_PLAYBACK_STREAM = 4;
const CMD_CREATE_RECORD_STREAM = 5;
const CMD_EXIT = 7;
const CMD_AUTH = 8;
const CMD_SET_CLIENT_NAME = 9;
const CMD_LOOKUP_SINK = 10;
const CMD_LOOKUP_SOURCE = 11;
const CMD_DRAIN_PLAYBACK_STREAM = 12;
const CMD_STAT = 13;
const CMD_GET_PLAYBACK_LATENCY = 14;
const CMD_GET_SERVER_INFO = 20;
const CMD_GET_SINK_INFO = 21;
const CMD_GET_SINK_INFO_LIST = 22;
const CMD_GET_SOURCE_INFO = 23;
const CMD_GET_SOURCE_INFO_LIST = 24;
const CMD_SUBSCRIBE = 35;
const CMD_SET_SINK_INPUT_VOLUME = 37;
const CMD_CORK_PLAYBACK_STREAM = 41;
const CMD_FLUSH_PLAYBACK_STREAM = 42;
const CMD_TRIGGER_PLAYBACK_STREAM = 43;
const CMD_SET_PLAYBACK_STREAM_NAME = 46;
const CMD_SET_SINK_INPUT_MUTE = 69;
const CMD_SET_PLAYBACK_STREAM_BUFFER_ATTR = 72;
const CMD_UPDATE_PLAYBACK_STREAM_SAMPLE_RATE = 74;
const CMD_UPDATE_PLAYBACK_STREAM_PROPLIST = 81;
const CMD_REMOVE_PLAYBACK_STREAM_PROPLIST = 84;
const CMD_REQUEST = 61;
const CMD_UNDERFLOW = 63;

const ERR_INVALID = 3;
const ERR_NOENTITY = 5;
const ERR_NOTSUPPORTED = 19;

/// The version we negotiate down to (protocol-native.c reply layouts
/// below are exact for it).
pub const VERSION: u32 = 13;
const VERSION_MASK: u32 = 0x0000_FFFF;

const CONTROL_CHANNEL: u32 = 0xffff_ffff;
const INVALID_INDEX: u32 = 0xffff_ffff;
const COOKIE_LEN = 256;
const DESC_SIZE = 20;
/// Sanity bound on one frame (pstream's own limit is 16 MB).
const MAX_FRAME = 16 << 20;

// ── audio units (daemon ↔ viewer, inside an `audio` channel) ────
// Same length-prefixed shape as wlhost/pipe units (u32 len LE, u8
// tag, payload) so receivers peel identically. Payloads are LE.

pub const UnitTag = enum(u8) {
    /// u32 stream, u8 sample format (PA codes: 3 s16le, 5 f32le, …),
    /// u8 channels, u32 rate. Daemon → viewer.
    open = 1,
    /// u32 stream, PCM bytes. Daemon → viewer.
    pcm = 2,
    /// u32 stream. Daemon → viewer.
    close = 3,
    /// u32 stream, u8 corked. Daemon → viewer.
    cork = 4,
    /// u32 stream, u64 bytes played locally. Viewer → daemon — this
    /// is the CLOCK: the daemon requests exactly this much more from
    /// the app, so the app paces itself to real playback.
    consumed = 16,
    /// u32 stream, u64 usec of local sink latency. Viewer → daemon;
    /// folded into GET_PLAYBACK_LATENCY answers (lip-sync).
    latency = 17,
    /// Viewer → daemon: "I drain audio units". PCM only flows to
    /// subscribed viewers — a terminal-only client that ignores
    /// audio must never be flooded into its output cap. Optional
    /// flags byte: bit0 = "I decode Opus" (pcm_opus units OK).
    subscribe = 18,
    /// u32 stream, u32 raw byte count, one 20 ms Opus packet.
    /// Daemon → viewer (-Daudio-opus, negotiated via subscribe
    /// flags). raw_len lets a non-decoding consumer keep the
    /// consumed-bytes clock without touching libopus.
    pcm_opus = 19,
    _,
};

pub fn appendUnit(out: *std.ArrayList(u8), a: std.mem.Allocator, tag: UnitTag, payload: []const u8) !void {
    var hdr: [5]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload.len + 1), .little);
    hdr[4] = @intFromEnum(tag);
    try out.appendSlice(a, &hdr);
    try out.appendSlice(a, payload);
}

pub fn peelUnit(bytes: []const u8) ?struct { tag: UnitTag, payload: []const u8, consumed: usize } {
    if (bytes.len < 5) return null;
    const len = std.mem.readInt(u32, bytes[0..4], .little);
    if (len == 0 or len > MAX_FRAME) return null;
    if (bytes.len < 4 + len) return null;
    return .{
        .tag = @enumFromInt(bytes[4]),
        .payload = bytes[5 .. 4 + len],
        .consumed = 4 + len,
    };
}

// ── tagstruct writer (big-endian) ───────────────────────────────

const Tw = struct {
    buf: *std.ArrayList(u8),
    a: std.mem.Allocator,

    fn u32be(w: *const Tw, v: u32) Error!void {
        try w.buf.append(w.a, 'L');
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        try w.buf.appendSlice(w.a, &b);
    }
    fn u8v(w: *const Tw, v: u8) Error!void {
        try w.buf.append(w.a, 'B');
        try w.buf.append(w.a, v);
    }
    fn usec(w: *const Tw, v: u64) Error!void {
        try w.buf.append(w.a, 'U');
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .big);
        try w.buf.appendSlice(w.a, &b);
    }
    fn u64v(w: *const Tw, v: u64) Error!void {
        try w.buf.append(w.a, 'R');
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .big);
        try w.buf.appendSlice(w.a, &b);
    }
    fn s64v(w: *const Tw, v: i64) Error!void {
        try w.buf.append(w.a, 'r');
        var b: [8]u8 = undefined;
        std.mem.writeInt(i64, &b, v, .big);
        try w.buf.appendSlice(w.a, &b);
    }
    fn str(w: *const Tw, s: ?[]const u8) Error!void {
        const v = s orelse {
            try w.buf.append(w.a, 'N');
            return;
        };
        try w.buf.append(w.a, 't');
        try w.buf.appendSlice(w.a, v);
        try w.buf.append(w.a, 0);
    }
    fn boolean(w: *const Tw, v: bool) Error!void {
        try w.buf.append(w.a, if (v) @as(u8, '1') else '0');
    }
    fn sampleSpec(w: *const Tw, format: u8, channels: u8, rate: u32) Error!void {
        try w.buf.append(w.a, 'a');
        try w.buf.append(w.a, format);
        try w.buf.append(w.a, channels);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, rate, .big);
        try w.buf.appendSlice(w.a, &b);
    }
    fn channelMap(w: *const Tw, channels: u8) Error!void {
        try w.buf.append(w.a, 'm');
        try w.buf.append(w.a, channels);
        // Front-left, front-right (mono: mono).
        if (channels == 1) {
            try w.buf.append(w.a, 0); // PA_CHANNEL_POSITION_MONO
        } else {
            var i: u8 = 0;
            while (i < channels) : (i += 1) try w.buf.append(w.a, 1 + i); // FL, FR, ...
        }
    }
    fn cvolume(w: *const Tw, channels: u8, vol: u32) Error!void {
        try w.buf.append(w.a, 'v');
        try w.buf.append(w.a, channels);
        var i: u8 = 0;
        while (i < channels) : (i += 1) {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, vol, .big);
            try w.buf.appendSlice(w.a, &b);
        }
    }
    fn timeval(w: *const Tw, sec: u32, us: u32) Error!void {
        try w.buf.append(w.a, 'T');
        var b: [8]u8 = undefined;
        std.mem.writeInt(u32, b[0..4], sec, .big);
        std.mem.writeInt(u32, b[4..8], us, .big);
        try w.buf.appendSlice(w.a, &b);
    }
    fn emptyProplist(w: *const Tw) Error!void {
        try w.buf.append(w.a, 'P');
        try w.buf.append(w.a, 'N'); // terminator
    }
};

// ── tagstruct reader ────────────────────────────────────────────

const Tr = struct {
    buf: []const u8,
    pos: usize = 0,

    fn tag(r: *Tr) Error!u8 {
        if (r.pos >= r.buf.len) return Error.Protocol;
        defer r.pos += 1;
        return r.buf[r.pos];
    }
    fn rawU32(r: *Tr) Error!u32 {
        if (r.pos + 4 > r.buf.len) return Error.Protocol;
        defer r.pos += 4;
        return std.mem.readInt(u32, r.buf[r.pos..][0..4], .big);
    }
    fn rawU8(r: *Tr) Error!u8 {
        if (r.pos >= r.buf.len) return Error.Protocol;
        defer r.pos += 1;
        return r.buf[r.pos];
    }
    fn u32be(r: *Tr) Error!u32 {
        if (try r.tag() != 'L') return Error.Protocol;
        return r.rawU32();
    }
    fn boolean(r: *Tr) Error!bool {
        return switch (try r.tag()) {
            '1' => true,
            '0' => false,
            else => Error.Protocol,
        };
    }
    /// Returns null for STRING_NULL.
    fn str(r: *Tr) Error!?[]const u8 {
        switch (try r.tag()) {
            'N' => return null,
            't' => {
                const start = r.pos;
                const end = std.mem.indexOfScalarPos(u8, r.buf, start, 0) orelse return Error.Protocol;
                r.pos = end + 1;
                return r.buf[start..end];
            },
            else => return Error.Protocol,
        }
    }
    fn arbitrary(r: *Tr, expected_len: usize) Error![]const u8 {
        if (try r.tag() != 'x') return Error.Protocol;
        const len = try r.rawU32();
        if (len != expected_len or r.pos + len > r.buf.len) return Error.Protocol;
        defer r.pos += len;
        return r.buf[r.pos .. r.pos + len];
    }
    fn sampleSpec(r: *Tr) Error!struct { format: u8, channels: u8, rate: u32 } {
        if (try r.tag() != 'a') return Error.Protocol;
        const f = try r.rawU8();
        const ch = try r.rawU8();
        const rate = try r.rawU32();
        return .{ .format = f, .channels = ch, .rate = rate };
    }
    fn channelMap(r: *Tr) Error!u8 {
        if (try r.tag() != 'm') return Error.Protocol;
        const n = try r.rawU8();
        if (r.pos + n > r.buf.len) return Error.Protocol;
        r.pos += n;
        return n;
    }
    fn cvolume(r: *Tr) Error!void {
        if (try r.tag() != 'v') return Error.Protocol;
        const n = try r.rawU8();
        if (r.pos + @as(usize, n) * 4 > r.buf.len) return Error.Protocol;
        r.pos += @as(usize, n) * 4;
    }
    fn timeval(r: *Tr) Error!struct { sec: u32, us: u32 } {
        if (try r.tag() != 'T') return Error.Protocol;
        const sec = try r.rawU32();
        const us = try r.rawU32();
        return .{ .sec = sec, .us = us };
    }
    /// Skip a whole proplist.
    fn skipProplist(r: *Tr) Error!void {
        if (try r.tag() != 'P') return Error.Protocol;
        while (true) {
            const t = try r.tag();
            if (t == 'N') return; // terminator
            if (t != 't') return Error.Protocol;
            const end = std.mem.indexOfScalarPos(u8, r.buf, r.pos, 0) orelse return Error.Protocol;
            r.pos = end + 1;
            if (try r.tag() != 'L') return Error.Protocol;
            const len = try r.rawU32();
            if (try r.tag() != 'x') return Error.Protocol;
            const xlen = try r.rawU32();
            if (xlen != len or r.pos + xlen > r.buf.len) return Error.Protocol;
            r.pos += xlen;
        }
    }
};

// ── the server ──────────────────────────────────────────────────

pub const Stream = struct {
    format: u8 = 3, // s16le
    channels: u8 = 2,
    rate: u32 = 44100,
    tlength: u32 = 0,
    corked: bool = false,
    /// Bytes received from the app (its write clock).
    write_index: u64 = 0,
    /// Bytes the viewer reported played (the read clock).
    read_index: u64 = 0,
    /// Viewer-reported local sink latency.
    gui_latency_us: u64 = 0,
    /// A viewer's `consumed` reports drive this stream's REQUESTs.
    /// Until the FIRST report (or after all viewers detach) the
    /// server self-clocks — a viewer that ignores audio units
    /// (terminal-only MCP clients) must never stall the app.
    viewer_clocked: bool = false,
    /// Opus decision made (latched at first data, sticky).
    opus_latched: bool = false,
    /// Live encoder (-Daudio-opus + subscriber wants it + s16 in
    /// the 48 kHz family). null = ship raw pcm units.
    opus_enc: ?opuscodec.Encoder = null,
    /// Partial 20 ms frame awaiting more samples.
    fbuf: std.ArrayList(u8) = .empty,

    fn deinitOwned(self: *Stream, a: std.mem.Allocator) void {
        if (self.opus_enc) |*e| e.deinit();
        self.opus_enc = null;
        self.fbuf.deinit(a);
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    inbuf: std.ArrayList(u8) = .empty,
    /// Reply bytes toward the app socket. Caller drains.
    out: std.ArrayList(u8) = .empty,
    /// Audio units toward the viewer channel. Caller drains.
    units: std.ArrayList(u8) = .empty,
    version: u32 = VERSION,
    authorized: bool = false,
    streams: std.AutoHashMapUnmanaged(u32, Stream) = .empty,
    next_stream: u32 = 0,
    dead: bool = false,
    /// Any proto>=5 viewer attached (the daemon updates this each
    /// read round). false resets every stream to self-clocking.
    has_viewer: bool = false,
    /// A subscribed viewer advertised Opus decode (daemon-set).
    /// Latched per stream at first data.
    opus_wanted: bool = false,

    pub fn init(allocator: std.mem.Allocator) Server {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Server) void {
        self.inbuf.deinit(self.allocator);
        self.out.deinit(self.allocator);
        self.units.deinit(self.allocator);
        var it = self.streams.valueIterator();
        while (it.next()) |st| st.deinitOwned(self.allocator);
        self.streams.deinit(self.allocator);
    }

    /// Feed app→server socket bytes; complete frames dispatch,
    /// tails buffer. Fatal protocol violations set `dead`.
    pub fn feed(self: *Server, bytes: []const u8) Error!void {
        try self.inbuf.appendSlice(self.allocator, bytes);
        var pos: usize = 0;
        while (!self.dead) {
            const avail = self.inbuf.items[pos..];
            if (avail.len < DESC_SIZE) break;
            const len = std.mem.readInt(u32, avail[0..4], .big);
            const channel = std.mem.readInt(u32, avail[4..8], .big);
            if (len > MAX_FRAME) {
                self.dead = true;
                break;
            }
            if (avail.len < DESC_SIZE + len) break;
            const payload = avail[DESC_SIZE .. DESC_SIZE + len];
            if (channel == CONTROL_CHANNEL) {
                self.control(payload) catch |err| switch (err) {
                    Error.OutOfMemory => return err,
                    else => {
                        // Name the killer (the wayland-side pattern):
                        // the next unusual client failure self-reports.
                        const cmd: u32 = if (payload.len >= 5)
                            std.mem.readInt(u32, payload[1..5], .big)
                        else
                            0xffff_ffff;
                        std.debug.print("sketerm-mux: pulse protocol error on command {d} (payload {d} bytes)\n", .{ cmd, payload.len });
                        self.dead = true;
                    },
                };
            } else {
                try self.pcm(channel, payload);
            }
            pos += DESC_SIZE + len;
        }
        if (pos > 0) {
            const rem = self.inbuf.items.len - pos;
            std.mem.copyForwards(u8, self.inbuf.items[0..rem], self.inbuf.items[pos..]);
            self.inbuf.shrinkRetainingCapacity(rem);
        }
    }

    /// Apply one viewer unit (consumed / latency reports).
    pub fn applyUnit(self: *Server, tag: UnitTag, payload: []const u8) Error!void {
        switch (tag) {
            .consumed => {
                if (payload.len < 12) return;
                const idx = std.mem.readInt(u32, payload[0..4], .little);
                const n = std.mem.readInt(u64, payload[4..12], .little);
                const s = self.streams.getPtr(idx) orelse return;
                s.viewer_clocked = true;
                s.read_index +|= n;
                // The viewer played n bytes: ask the app for n more.
                try self.sendRequest(idx, @intCast(@min(n, 0xffff_ffff)));
            },
            .latency => {
                if (payload.len < 12) return;
                const idx = std.mem.readInt(u32, payload[0..4], .little);
                const s = self.streams.getPtr(idx) orelse return;
                s.gui_latency_us = std.mem.readInt(u64, payload[4..12], .little);
            },
            else => {},
        }
    }

    // ── frame handling ───────────────────────────────────────────

    fn rawPcmUnit(self: *Server, channel: u32, payload: []const u8) Error!void {
        if (payload.len == 0) return;
        var pl: std.ArrayList(u8) = .empty;
        defer pl.deinit(self.allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, channel, .little);
        try pl.appendSlice(self.allocator, &idb);
        try pl.appendSlice(self.allocator, payload);
        try appendUnit(&self.units, self.allocator, .pcm, pl.items);
    }

    fn pcm(self: *Server, channel: u32, payload: []const u8) Error!void {
        const s = self.streams.getPtr(channel) orelse return; // stale stream: drop
        s.write_index +|= payload.len;
        // Opus decision is sticky per stream, made at first data:
        // -Daudio-opus built, a subscriber decodes it, and the spec
        // is s16 in the 48 kHz family (44.1 k stays raw — Opus
        // doesn't eat it and we don't resample).
        if (!s.opus_latched) {
            s.opus_latched = true;
            if (opuscodec.enabled and self.opus_wanted and s.format == 3)
                s.opus_enc = opuscodec.Encoder.init(s.rate, s.channels);
            if (std.c.getenv("SKETERM_PA_DEBUG") != null)
                std.debug.print("pulse: stream {d} latched {s} ({d} Hz, {d} ch)\n", .{ channel, if (s.opus_enc != null) "OPUS" else "raw", s.rate, s.channels });
        }
        if (s.opus_enc) |*enc| {
            try s.fbuf.appendSlice(self.allocator, payload);
            const fb = enc.frameBytes();
            var off: usize = 0;
            var packet_buf: [opuscodec.MAX_PACKET]u8 = undefined;
            while (s.fbuf.items.len - off >= fb) : (off += fb) {
                const frame = s.fbuf.items[off .. off + fb];
                const packet = enc.encode(frame, &packet_buf) orelse {
                    // Encoder wedged: fall back to raw from here on.
                    var e2 = s.opus_enc.?;
                    e2.deinit();
                    s.opus_enc = null;
                    try self.rawPcmUnit(channel, s.fbuf.items[off..]);
                    off = s.fbuf.items.len;
                    break;
                };
                var pl: std.ArrayList(u8) = .empty;
                defer pl.deinit(self.allocator);
                var hdr: [8]u8 = undefined;
                std.mem.writeInt(u32, hdr[0..4], channel, .little);
                std.mem.writeInt(u32, hdr[4..8], @intCast(fb), .little);
                try pl.appendSlice(self.allocator, &hdr);
                try pl.appendSlice(self.allocator, packet);
                try appendUnit(&self.units, self.allocator, .pcm_opus, pl.items);
            }
            if (off > 0) {
                const rem = s.fbuf.items.len - off;
                std.mem.copyForwards(u8, s.fbuf.items[0..rem], s.fbuf.items[off..]);
                s.fbuf.shrinkRetainingCapacity(rem);
            }
        } else {
            try self.rawPcmUnit(channel, payload);
        }
        if (!self.has_viewer) s.viewer_clocked = false;
        if (!s.viewer_clocked) {
            // Self-clock: pretend instant playback so the app never
            // stalls while nobody consumes (headless / terminal-only
            // viewers). A viewer's first consumed report takes over.
            s.read_index = s.write_index;
            try self.sendRequest(channel, @intCast(payload.len));
        }
    }

    fn control(self: *Server, payload: []const u8) Error!void {
        var r = Tr{ .buf = payload };
        const command = try r.u32be();
        const tag = try r.u32be();
        if (std.c.getenv("SKETERM_PA_DEBUG") != null)
            std.debug.print("pulse: cmd {d} tag {d}\n", .{ command, tag });
        if (!self.authorized and command != CMD_AUTH) return Error.Protocol;
        switch (command) {
            CMD_AUTH => {
                const ver = try r.u32be();
                _ = try r.arbitrary(COOKIE_LEN);
                if ((ver & VERSION_MASK) < 8) return Error.Protocol;
                self.version = @min(ver & VERSION_MASK, VERSION);
                self.authorized = true;
                var t = try self.replyHead(tag);
                // No SHM, no memfd: flag bits stay clear.
                try t.u32be(VERSION);
                try self.finishFrame();
            },
            CMD_SET_CLIENT_NAME => {
                if (self.version >= 13) {
                    try r.skipProplist();
                } else {
                    _ = try r.str();
                }
                var t = try self.replyHead(tag);
                if (self.version >= 13) try t.u32be(1); // client index
                try self.finishFrame();
            },
            CMD_GET_SERVER_INFO => {
                var t = try self.replyHead(tag);
                try t.str("sketerm");
                try t.str("1.0");
                try t.str("user");
                try t.str("sketerm");
                try t.sampleSpec(3, 2, 44100); // s16le stereo
                try t.str("sketerm"); // default sink
                // The default SOURCE must be a real, non-null name: no
                // genuine server ever reports none (a sink always has
                // a monitor), so clients dereference it unchecked —
                // SDL3's ServerInfoCallback SIGSEGVd on our old NULL.
                try t.str("sketerm.monitor");
                try t.u32be(0x5EE7); // instance cookie
                try self.finishFrame();
            },
            CMD_GET_SINK_INFO, CMD_GET_SINK_INFO_LIST => {
                if (command == CMD_GET_SINK_INFO) {
                    _ = try r.u32be(); // index
                    _ = try r.str(); // name
                }
                var t = try self.replyHead(tag);
                try self.putSink(&t);
                try self.finishFrame();
            },
            CMD_GET_SOURCE_INFO, CMD_GET_SOURCE_INFO_LIST => {
                // One source: the sink's monitor (backs the non-null
                // default source above; capture-side clients skip
                // monitors, so nothing tries to record from it).
                if (command == CMD_GET_SOURCE_INFO) {
                    _ = try r.u32be(); // index
                    _ = try r.str(); // name
                }
                var t = try self.replyHead(tag);
                try self.putSource(&t);
                try self.finishFrame();
            },
            CMD_LOOKUP_SINK => {
                _ = try r.str();
                var t = try self.replyHead(tag);
                try t.u32be(0);
                try self.finishFrame();
            },
            CMD_LOOKUP_SOURCE => {
                _ = try r.str();
                var t = try self.replyHead(tag);
                try t.u32be(0);
                try self.finishFrame();
            },
            CMD_STAT => {
                // pa_stat_info: five u32s (memblock counts/sizes and
                // the sample-cache size). An empty reply here made
                // pa_context_stat callbacks fail their parse.
                var t = try self.replyHead(tag);
                try t.u32be(0); // memblock_total
                try t.u32be(0); // memblock_total_size
                try t.u32be(0); // memblock_allocated
                try t.u32be(0); // memblock_allocated_size
                try t.u32be(0); // scache_size
                try self.finishFrame();
            },
            CMD_CREATE_PLAYBACK_STREAM => try self.createPlayback(&r, tag),
            CMD_DELETE_PLAYBACK_STREAM => {
                const idx = try r.u32be();
                if (self.streams.fetchRemove(idx)) |kv| {
                    var st = kv.value;
                    st.deinitOwned(self.allocator);
                    var idb: [4]u8 = undefined;
                    std.mem.writeInt(u32, &idb, idx, .little);
                    try appendUnit(&self.units, self.allocator, .close, &idb);
                }
                _ = try self.replyHead(tag);
                try self.finishFrame();
            },
            CMD_DRAIN_PLAYBACK_STREAM => {
                // Approximation: everything received is already
                // shipped toward the viewer — report drained.
                _ = try r.u32be();
                _ = try self.replyHead(tag);
                try self.finishFrame();
            },
            CMD_GET_PLAYBACK_LATENCY => {
                const idx = try r.u32be();
                const tv = try r.timeval();
                const s = self.streams.getPtr(idx) orelse
                    return self.sendError(tag, ERR_NOENTITY);
                var t = try self.replyHead(tag);
                try t.usec(streamLatencyUsec(s));
                try t.usec(0); // source latency
                try t.boolean(!s.corked); // playing
                try t.timeval(tv.sec, tv.us); // echo client stamp
                try t.timeval(tv.sec, tv.us); // "our" stamp (no clock here)
                try t.s64v(@intCast(@min(s.write_index, std.math.maxInt(i64))));
                try t.s64v(@intCast(@min(s.read_index, std.math.maxInt(i64))));
                if (self.version >= 13) {
                    try t.u64v(0); // underrun_for
                    try t.u64v(s.write_index); // playing_for
                }
                try self.finishFrame();
            },
            CMD_CORK_PLAYBACK_STREAM => {
                const idx = try r.u32be();
                const b = try r.boolean();
                if (self.streams.getPtr(idx)) |s| {
                    s.corked = b;
                    var pl: [5]u8 = undefined;
                    std.mem.writeInt(u32, pl[0..4], idx, .little);
                    pl[4] = @intFromBool(b);
                    try appendUnit(&self.units, self.allocator, .cork, &pl);
                }
                _ = try self.replyHead(tag);
                try self.finishFrame();
            },
            CMD_SET_PLAYBACK_STREAM_BUFFER_ATTR => {
                const idx = try r.u32be();
                const maxlength = try r.u32be();
                const tlength = try r.u32be();
                const prebuf = try r.u32be();
                const minreq = try r.u32be();
                _ = maxlength;
                _ = prebuf;
                if (self.streams.getPtr(idx)) |s| s.tlength = tlength;
                var t = try self.replyHead(tag);
                try t.u32be(4 * 1024 * 1024); // maxlength
                try t.u32be(tlength);
                try t.u32be(0); // prebuf
                try t.u32be(minreq);
                if (self.version >= 13) try t.usec(20_000);
                try self.finishFrame();
            },
            // Accepted, trivially acknowledged (their real replies
            // ARE empty acks — anything with a payload gets its own
            // handler above; an empty reply where the client expects
            // fields fails its parse, or worse).
            CMD_SUBSCRIBE,
            CMD_EXIT,
            CMD_FLUSH_PLAYBACK_STREAM,
            CMD_TRIGGER_PLAYBACK_STREAM,
            CMD_SET_PLAYBACK_STREAM_NAME,
            CMD_SET_SINK_INPUT_VOLUME,
            CMD_SET_SINK_INPUT_MUTE,
            CMD_UPDATE_PLAYBACK_STREAM_SAMPLE_RATE,
            CMD_UPDATE_PLAYBACK_STREAM_PROPLIST,
            CMD_REMOVE_PLAYBACK_STREAM_PROPLIST,
            => {
                _ = try self.replyHead(tag);
                try self.finishFrame();
            },
            CMD_CREATE_RECORD_STREAM => try self.sendError(tag, ERR_NOTSUPPORTED),
            else => try self.sendError(tag, ERR_NOTSUPPORTED),
        }
    }

    /// v13 request/reply layout, matching protocol-native.c.
    fn createPlayback(self: *Server, r: *Tr, tag: u32) Error!void {
        if (self.version < 13) _ = try r.str(); // legacy stream name
        const ss = try r.sampleSpec();
        _ = try r.channelMap();
        _ = try r.u32be(); // sink index
        _ = try r.str(); // sink name
        var maxlength = try r.u32be();
        const corked = try r.boolean();
        var tlength = try r.u32be();
        _ = try r.u32be(); // prebuf
        var minreq = try r.u32be();
        _ = try r.u32be(); // syncid
        try r.cvolume();
        if (self.version >= 12) {
            var i: u8 = 0;
            while (i < 7) : (i += 1) _ = try r.boolean();
        }
        if (self.version >= 13) {
            _ = try r.boolean(); // muted
            _ = try r.boolean(); // adjust_latency
            try r.skipProplist();
        }

        const frame_bytes: u32 = @as(u32, ss.channels) * sampleSize(ss.format);
        const bytes_per_sec: u64 = @as(u64, frame_bytes) * ss.rate;
        // Fill in "whatever" (0xffffffff) requests with ~200 ms.
        if (tlength == 0 or tlength == 0xffff_ffff)
            tlength = @intCast(@max(bytes_per_sec / 5, 4096));
        if (maxlength == 0 or maxlength == 0xffff_ffff)
            maxlength = 4 * 1024 * 1024;
        if (minreq == 0 or minreq == 0xffff_ffff)
            minreq = @intCast(@max(bytes_per_sec / 50, 1024));

        const idx = self.next_stream;
        self.next_stream += 1;
        try self.streams.put(self.allocator, idx, .{
            .format = ss.format,
            .channels = ss.channels,
            .rate = ss.rate,
            .tlength = tlength,
            .corked = corked,
        });
        {
            var pl: [10]u8 = undefined;
            std.mem.writeInt(u32, pl[0..4], idx, .little);
            pl[4] = ss.format;
            pl[5] = ss.channels;
            std.mem.writeInt(u32, pl[6..10], ss.rate, .little);
            try appendUnit(&self.units, self.allocator, .open, &pl);
        }

        var t = try self.replyHead(tag);
        try t.u32be(idx); // channel (data frames use this)
        try t.u32be(idx); // sink input index
        try t.u32be(tlength); // missing: request a full buffer
        if (self.version >= 9) {
            try t.u32be(maxlength);
            try t.u32be(tlength);
            try t.u32be(0); // prebuf: start immediately
            try t.u32be(minreq);
        }
        if (self.version >= 12) {
            try t.sampleSpec(ss.format, ss.channels, ss.rate);
            try t.channelMap(ss.channels);
            try t.u32be(0); // sink index
            try t.str("sketerm");
            try t.boolean(false); // not suspended
        }
        if (self.version >= 13) try t.usec(20_000); // configured sink latency
        try self.finishFrame();
    }

    fn streamLatencyUsec(s: *const Stream) u64 {
        const frame_bytes: u64 = @as(u64, s.channels) * sampleSize(s.format);
        const bytes_per_sec: u64 = frame_bytes * s.rate;
        if (bytes_per_sec == 0) return s.gui_latency_us;
        const in_flight = s.write_index -| s.read_index;
        return s.gui_latency_us + (in_flight * 1_000_000) / bytes_per_sec;
    }

    fn putSink(self: *Server, t: *const Tw) Error!void {
        try t.u32be(0); // index
        try t.str("sketerm");
        try t.str("sketerm remote audio");
        try t.sampleSpec(3, 2, 44100);
        try t.channelMap(2);
        try t.u32be(INVALID_INDEX); // owner module
        try t.cvolume(2, 0x10000); // norm
        try t.boolean(false); // mute
        try t.u32be(0); // monitor source (see putSource)
        try t.str("sketerm.monitor");
        try t.usec(20_000); // latency
        try t.str("sketerm"); // driver
        try t.u32be(0x0002); // PA_SINK_LATENCY
        if (self.version >= 13) {
            try t.emptyProplist();
            try t.usec(20_000); // requested latency
        }
    }

    /// The sink's monitor source (source_fill_tagstruct, v13). Exists
    /// so the server-info default source is a real object — clients
    /// dereference that name unchecked; capture-side enumeration
    /// skips monitors, so nothing records from it.
    fn putSource(self: *Server, t: *const Tw) Error!void {
        try t.u32be(0); // index
        try t.str("sketerm.monitor");
        try t.str("Monitor of sketerm remote audio");
        try t.sampleSpec(3, 2, 44100);
        try t.channelMap(2);
        try t.u32be(INVALID_INDEX); // owner module
        try t.cvolume(2, 0x10000); // norm
        try t.boolean(false); // mute
        try t.u32be(0); // monitor OF sink 0
        try t.str("sketerm"); // monitored sink name
        try t.usec(20_000); // latency
        try t.str("sketerm"); // driver
        try t.u32be(0x0002); // PA_SOURCE_LATENCY
        if (self.version >= 13) {
            try t.emptyProplist();
            try t.usec(20_000); // requested latency
        }
    }

    // ── server → client frames ───────────────────────────────────

    /// Begin a control frame with REPLY + tag; returns the writer.
    /// Every begun frame MUST end with finishFrame (length patch).
    fn replyHead(self: *Server, tag: u32) Error!Tw {
        try self.beginFrame();
        const t = Tw{ .buf = &self.out, .a = self.allocator };
        try t.u32be(CMD_REPLY);
        try t.u32be(tag);
        return t;
    }

    fn sendError(self: *Server, tag: u32, code: u32) Error!void {
        try self.beginFrame();
        const t = Tw{ .buf = &self.out, .a = self.allocator };
        try t.u32be(CMD_ERROR);
        try t.u32be(tag);
        try t.u32be(code);
        try self.finishFrame();
    }

    /// Server-initiated: ask the app for `nbytes` more of stream.
    fn sendRequest(self: *Server, idx: u32, nbytes: u32) Error!void {
        try self.beginFrame();
        const t = Tw{ .buf = &self.out, .a = self.allocator };
        try t.u32be(CMD_REQUEST);
        try t.u32be(CONTROL_CHANNEL); // tag -1: unsolicited
        try t.u32be(idx);
        try t.u32be(nbytes);
        try self.finishFrame();
    }

    var frame_start: usize = 0; // patched by begin/finish (single-threaded)

    fn beginFrame(self: *Server) Error!void {
        frame_start = self.out.items.len;
        var desc: [DESC_SIZE]u8 = [_]u8{0} ** DESC_SIZE;
        std.mem.writeInt(u32, desc[4..8], CONTROL_CHANNEL, .big);
        try self.out.appendSlice(self.allocator, &desc);
    }

    fn finishFrame(self: *Server) Error!void {
        const len: u32 = @intCast(self.out.items.len - frame_start - DESC_SIZE);
        std.mem.writeInt(u32, self.out.items[frame_start..][0..4], len, .big);
    }

    pub fn takeOut(self: *Server) []const u8 {
        return self.out.items;
    }
    pub fn clearOut(self: *Server) void {
        self.out.clearRetainingCapacity();
    }
    pub fn takeUnits(self: *Server) []const u8 {
        return self.units.items;
    }
    pub fn clearUnits(self: *Server) void {
        self.units.clearRetainingCapacity();
    }
};

/// Bytes per sample for the PA sample formats we pass through.
fn sampleSize(format: u8) u32 {
    return switch (format) {
        0, 1, 2 => 1, // u8 / alaw / ulaw
        3, 4 => 2, // s16le/be
        5, 6, 7, 8 => 4, // f32, s32
        9, 10 => 3, // s24 packed
        11, 12 => 4, // s24 in 32
        else => 2,
    };
}

// ─── tests ──────────────────────────────────────────────────────

const t_ = std.testing;

/// Build a client control frame from a callback that writes fields.
fn clientFrame(a: std.mem.Allocator, out: *std.ArrayList(u8), fields: []const u8) !void {
    var desc: [DESC_SIZE]u8 = [_]u8{0} ** DESC_SIZE;
    std.mem.writeInt(u32, desc[0..4], @intCast(fields.len), .big);
    std.mem.writeInt(u32, desc[4..8], CONTROL_CHANNEL, .big);
    try out.appendSlice(a, &desc);
    try out.appendSlice(a, fields);
}

test "auth + client name + create stream + pcm flows to units" {
    const a = t_.allocator;
    var srv = Server.init(a);
    defer srv.deinit();

    var fields: std.ArrayList(u8) = .empty;
    defer fields.deinit(a);
    const w = Tw{ .buf = &fields, .a = a };

    { // AUTH(version 35 | SHM flags, cookie)
        try w.u32be(CMD_AUTH);
        try w.u32be(1); // tag
        try w.u32be(35 | 0x8000_0000);
        try fields.append(a, 'x');
        var lb: [4]u8 = undefined;
        std.mem.writeInt(u32, &lb, COOKIE_LEN, .big);
        try fields.appendSlice(a, &lb);
        try fields.appendSlice(a, &([_]u8{0} ** COOKIE_LEN));
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(a);
        try clientFrame(a, &frame, fields.items);
        try srv.feed(frame.items);
        fields.clearRetainingCapacity();
    }
    try t_.expect(srv.authorized);
    try t_.expectEqual(VERSION, srv.version);
    { // reply must carry REPLY, tag 1, version 13 (no SHM bit)
        var r = Tr{ .buf = srv.takeOut()[DESC_SIZE..] };
        try t_.expectEqual(@as(u32, CMD_REPLY), try r.u32be());
        try t_.expectEqual(@as(u32, 1), try r.u32be());
        try t_.expectEqual(VERSION, try r.u32be());
        srv.clearOut();
    }

    { // SET_CLIENT_NAME with empty proplist
        try w.u32be(CMD_SET_CLIENT_NAME);
        try w.u32be(2);
        try w.emptyProplist();
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(a);
        try clientFrame(a, &frame, fields.items);
        try srv.feed(frame.items);
        fields.clearRetainingCapacity();
        srv.clearOut();
    }

    { // CREATE_PLAYBACK_STREAM, v13 shape: s16le stereo 48k
        try w.u32be(CMD_CREATE_PLAYBACK_STREAM);
        try w.u32be(3);
        try w.sampleSpec(3, 2, 48000);
        try w.channelMap(2);
        try w.u32be(INVALID_INDEX); // sink index
        try w.str(null); // sink name
        try w.u32be(0xffff_ffff); // maxlength
        try w.boolean(false); // corked
        try w.u32be(0xffff_ffff); // tlength
        try w.u32be(0xffff_ffff); // prebuf
        try w.u32be(0xffff_ffff); // minreq
        try w.u32be(0); // syncid
        try w.cvolume(2, 0x10000);
        var i: u8 = 0; // v12 bools
        while (i < 7) : (i += 1) try w.boolean(false);
        try w.boolean(false); // muted
        try w.boolean(true); // adjust_latency
        try w.emptyProplist();
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(a);
        try clientFrame(a, &frame, fields.items);
        try srv.feed(frame.items);
        fields.clearRetainingCapacity();
    }
    try t_.expectEqual(@as(u32, 1), srv.streams.count());
    { // reply: channel 0, sink input 0, missing > 0
        var r = Tr{ .buf = srv.takeOut()[DESC_SIZE..] };
        try t_.expectEqual(@as(u32, CMD_REPLY), try r.u32be());
        try t_.expectEqual(@as(u32, 3), try r.u32be());
        try t_.expectEqual(@as(u32, 0), try r.u32be()); // channel
        try t_.expectEqual(@as(u32, 0), try r.u32be()); // sink input
        const missing = try r.u32be();
        try t_.expect(missing > 0);
        srv.clearOut();
    }
    { // open unit went out
        const u = peelUnit(srv.takeUnits()).?;
        try t_.expectEqual(UnitTag.open, u.tag);
        try t_.expectEqual(@as(u32, 48000), std.mem.readInt(u32, u.payload[6..10], .little));
        srv.clearUnits();
    }

    { // PCM frame on channel 0 → pcm unit; no viewer → self-request
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(a);
        var desc: [DESC_SIZE]u8 = [_]u8{0} ** DESC_SIZE;
        std.mem.writeInt(u32, desc[0..4], 8, .big);
        std.mem.writeInt(u32, desc[4..8], 0, .big); // stream channel
        try frame.appendSlice(a, &desc);
        try frame.appendSlice(a, "\x01\x02\x03\x04\x05\x06\x07\x08");
        try srv.feed(frame.items);
    }
    {
        const u = peelUnit(srv.takeUnits()).?;
        try t_.expectEqual(UnitTag.pcm, u.tag);
        try t_.expectEqual(@as(u32, 0), std.mem.readInt(u32, u.payload[0..4], .little));
        try t_.expectEqualStrings("\x01\x02\x03\x04\x05\x06\x07\x08", u.payload[4..]);
        srv.clearUnits();
        // Self-clock REQUEST went to the app.
        var r = Tr{ .buf = srv.takeOut()[DESC_SIZE..] };
        try t_.expectEqual(@as(u32, CMD_REQUEST), try r.u32be());
        srv.clearOut();
    }

    { // GET_PLAYBACK_LATENCY answers with indices
        try w.u32be(CMD_GET_PLAYBACK_LATENCY);
        try w.u32be(4);
        try w.u32be(0);
        try w.timeval(100, 200);
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(a);
        try clientFrame(a, &frame, fields.items);
        try srv.feed(frame.items);
        fields.clearRetainingCapacity();
        var r = Tr{ .buf = srv.takeOut()[DESC_SIZE..] };
        try t_.expectEqual(@as(u32, CMD_REPLY), try r.u32be());
        try t_.expectEqual(@as(u32, 4), try r.u32be());
        srv.clearOut();
    }
    try t_.expect(!srv.dead);
}

test "viewer consumed reports drive REQUESTs" {
    const a = t_.allocator;
    var srv = Server.init(a);
    defer srv.deinit();
    srv.has_viewer = true;
    srv.authorized = true;
    try srv.streams.put(a, 0, .{ .rate = 48000 });

    var pl: [12]u8 = undefined;
    std.mem.writeInt(u32, pl[0..4], 0, .little);
    std.mem.writeInt(u64, pl[4..12], 9600, .little);
    try srv.applyUnit(.consumed, &pl);
    var r = Tr{ .buf = srv.takeOut()[DESC_SIZE..] };
    try t_.expectEqual(@as(u32, CMD_REQUEST), try r.u32be());
    _ = try r.u32be(); // tag -1
    try t_.expectEqual(@as(u32, 0), try r.u32be());
    try t_.expectEqual(@as(u32, 9600), try r.u32be());
    try t_.expectEqual(@as(u64, 9600), srv.streams.get(0).?.read_index);
}

test "server/sink/source/stat replies parse fully (SDL crash regression)" {
    const a = t_.allocator;
    var srv = Server.init(a);
    defer srv.deinit();
    srv.authorized = true;

    var fields: std.ArrayList(u8) = .empty;
    defer fields.deinit(a);
    const w = Tw{ .buf = &fields, .a = a };

    { // GET_SERVER_INFO: the default SOURCE must be a real name —
        // SDL3's ServerInfoCallback dereferences it unchecked and
        // SIGSEGVd on the NULL we used to send.
        try w.u32be(CMD_GET_SERVER_INFO);
        try w.u32be(7);
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(a);
        try clientFrame(a, &frame, fields.items);
        try srv.feed(frame.items);
        fields.clearRetainingCapacity();
        var r = Tr{ .buf = srv.takeOut()[DESC_SIZE..] };
        try t_.expectEqual(@as(u32, CMD_REPLY), try r.u32be());
        try t_.expectEqual(@as(u32, 7), try r.u32be());
        _ = try r.str(); // package
        _ = try r.str(); // version
        _ = try r.str(); // user
        _ = try r.str(); // host
        _ = try r.sampleSpec();
        try t_.expectEqualStrings("sketerm", (try r.str()).?); // default sink
        try t_.expectEqualStrings("sketerm.monitor", (try r.str()).?); // default source: NON-NULL
        _ = try r.u32be(); // cookie
        try t_.expectEqual(r.buf.len, r.pos); // consumed exactly
        srv.clearOut();
    }
    { // GET_SOURCE_INFO_LIST: one monitor source, v13 layout exact.
        try w.u32be(CMD_GET_SOURCE_INFO_LIST);
        try w.u32be(8);
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(a);
        try clientFrame(a, &frame, fields.items);
        try srv.feed(frame.items);
        fields.clearRetainingCapacity();
        var r = Tr{ .buf = srv.takeOut()[DESC_SIZE..] };
        try t_.expectEqual(@as(u32, CMD_REPLY), try r.u32be());
        try t_.expectEqual(@as(u32, 8), try r.u32be());
        try t_.expectEqual(@as(u32, 0), try r.u32be()); // index
        try t_.expectEqualStrings("sketerm.monitor", (try r.str()).?);
        _ = try r.str(); // description
        _ = try r.sampleSpec();
        _ = try r.channelMap();
        try t_.expectEqual(INVALID_INDEX, try r.u32be()); // owner module
        try r.cvolume();
        try t_.expectEqual(false, try r.boolean()); // mute
        try t_.expectEqual(@as(u32, 0), try r.u32be()); // monitor of sink 0
        try t_.expectEqualStrings("sketerm", (try r.str()).?);
        _ = try r.tag(); // usec latency
        _ = try r.rawU32();
        _ = try r.rawU32();
        _ = try r.str(); // driver
        try t_.expectEqual(@as(u32, 0x0002), try r.u32be()); // flags
        try r.skipProplist();
        srv.clearOut();
    }
    { // STAT: five u32s (an empty reply broke pa_context_stat).
        try w.u32be(CMD_STAT);
        try w.u32be(9);
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(a);
        try clientFrame(a, &frame, fields.items);
        try srv.feed(frame.items);
        fields.clearRetainingCapacity();
        var r = Tr{ .buf = srv.takeOut()[DESC_SIZE..] };
        try t_.expectEqual(@as(u32, CMD_REPLY), try r.u32be());
        try t_.expectEqual(@as(u32, 9), try r.u32be());
        var i: u32 = 0;
        while (i < 5) : (i += 1) _ = try r.u32be();
        try t_.expectEqual(r.buf.len, r.pos);
        srv.clearOut();
    }
    try t_.expect(!srv.dead);
}
