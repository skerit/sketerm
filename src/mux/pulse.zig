//! PulseAudio native-protocol server for remote-audio forwarding:
//! the daemon IS the session's audio server, the same way it is the
//! session's Wayland display. Pure state machine — no sockets, no
//! libpulse — fed app→server bytes, producing server→app reply bytes
//! plus "audio units" toward the attached viewer (GUI), which plays
//! them through ITS local audio stack.
//!
//! Scope: playback only, protocol v15 (every libpulse since 0.9.15
//! negotiates down to it; the version-gated reply layouts below match
//! pulsecore/protocol-native.c exactly — v15 is the floor for the
//! sink STATE field, which `pactl` shows and probes read). SHM/memfd
//! memblocks are REFUSED in the AUTH reply, so all sample data
//! arrives inline on the socket — which is what can ride the mux
//! wire.
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
const CMD_UPDATE_CLIENT_PROPLIST = 82;
const CMD_REMOVE_PLAYBACK_STREAM_PROPLIST = 84;
const CMD_REMOVE_CLIENT_PROPLIST = 85;
const CMD_REQUEST = 61;

/// The application-facing playback window must cover a real remote round
/// trip plus ordinary SSH/graphics jitter.  Low-latency clients commonly ask
/// PulseAudio for only 20-50 ms; honoring that literally turns every REQUEST
/// into a just-in-time network round trip and underruns continuously.  This
/// does not force 500 ms of speaker latency: PCM is forwarded immediately and
/// the GUI's local Pulse stream consumes from the resulting jitter reservoir.
const REMOTE_TLENGTH_US: u64 = 500_000;
const CMD_UNDERFLOW = 63;

const ERR_INVALID = 3;
const ERR_NOENTITY = 5;
const ERR_NOTSUPPORTED = 19;

/// The version we negotiate down to (protocol-native.c reply layouts
/// below are exact for it). 15 = the sink/source STATE field floor.
pub const VERSION: u32 = 15;
const VERSION_MASK: u32 = 0x0000_FFFF;

/// pa_sink_state_t / pa_source_state_t (pulse/def.h).
const STATE_RUNNING: u32 = 0;
const STATE_IDLE: u32 = 1;

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
    /// u32 stream, u8 version, u32 pid, then four u16-length strings:
    /// application, binary, media title, icon name. Daemon → viewer.
    metadata = 5,
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
    /// Daemon → viewer (runtime Opus, negotiated via subscribe flags).
    /// raw_len lets a non-decoding consumer keep the
    /// consumed-bytes clock without touching libopus.
    pcm_opus = 19,
    _,
};

/// Moved to wire.zig (it crosses the wire inside SessionInfo);
/// re-exported so pulse-side callers keep their spelling.
pub const AudioInfo = @import("wire.zig").AudioInfo;

const META_VERSION: u8 = 1;
/// Sizing input for the broker's worker-control buffer — see
/// `WORKER_META_BUF` in daemon_serve.zig before raising this.
pub const META_STRING_MAX: usize = 128;
const PROPLIST_VALUE_MAX: usize = 64 << 10;

fn boundedUtf8(value_in: []const u8) ?[]const u8 {
    const value = std.mem.trimEnd(u8, value_in, "\x00");
    if (!std.unicode.utf8ValidateSlice(value)) return null;
    var end = @min(value.len, META_STRING_MAX);
    while (end > 0 and !std.unicode.utf8ValidateSlice(value[0..end])) end -= 1;
    return value[0..end];
}

pub fn appendMetadataUnit(out: *std.ArrayList(u8), a: std.mem.Allocator, stream: u32, info: AudioInfo) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(a);
    var fixed: [9]u8 = undefined;
    std.mem.writeInt(u32, fixed[0..4], stream, .little);
    fixed[4] = META_VERSION;
    std.mem.writeInt(u32, fixed[5..9], info.pid, .little);
    try payload.appendSlice(a, &fixed);
    inline for (.{ info.application, info.binary, info.media, info.icon }) |value| {
        const clipped = boundedUtf8(value) orelse "";
        var len: [2]u8 = undefined;
        std.mem.writeInt(u16, &len, @intCast(clipped.len), .little);
        try payload.appendSlice(a, &len);
        try payload.appendSlice(a, clipped);
    }
    try appendUnit(out, a, .metadata, payload.items);
}

pub fn decodeMetadata(payload: []const u8) ?struct { stream: u32, info: AudioInfo } {
    if (payload.len < 9 or payload[4] != META_VERSION) return null;
    var pos: usize = 9;
    var values: [4][]const u8 = undefined;
    for (&values) |*value| {
        if (pos + 2 > payload.len) return null;
        const len = std.mem.readInt(u16, payload[pos..][0..2], .little);
        pos += 2;
        if (pos + len > payload.len) return null;
        value.* = payload[pos .. pos + len];
        pos += len;
    }
    if (pos != payload.len) return null;
    return .{
        .stream = std.mem.readInt(u32, payload[0..4], .little),
        .info = .{
            .application = values[0],
            .binary = values[1],
            .media = values[2],
            .icon = values[3],
            .pid = std.mem.readInt(u32, payload[5..9], .little),
        },
    };
}

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
    fn volume(w: *const Tw, v: u32) Error!void {
        try w.buf.append(w.a, 'V');
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        try w.buf.appendSlice(w.a, &b);
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
        try walkProplist(r, null, null);
    }
};

// ── the server ──────────────────────────────────────────────────

const Metadata = struct {
    const application_bit: u8 = 1 << 0;
    const binary_bit: u8 = 1 << 1;
    const media_name_bit: u8 = 1 << 2;
    const media_title_bit: u8 = 1 << 3;
    const application_icon_bit: u8 = 1 << 4;
    const media_icon_bit: u8 = 1 << 5;
    const pid_bit: u8 = 1 << 6;

    application: []u8 = &.{},
    binary: []u8 = &.{},
    media_name: []u8 = &.{},
    media_title: []u8 = &.{},
    application_icon: []u8 = &.{},
    media_icon: []u8 = &.{},
    pid: u32 = 0,
    present: u8 = 0,

    fn deinit(self: *Metadata, a: std.mem.Allocator) void {
        if (self.application.len > 0) a.free(self.application);
        if (self.binary.len > 0) a.free(self.binary);
        if (self.media_name.len > 0) a.free(self.media_name);
        if (self.media_title.len > 0) a.free(self.media_title);
        if (self.application_icon.len > 0) a.free(self.application_icon);
        if (self.media_icon.len > 0) a.free(self.media_icon);
        self.* = .{};
    }

    fn clear(self: *Metadata, a: std.mem.Allocator) void {
        self.deinit(a);
    }

    fn has(self: *const Metadata, bit: u8) bool {
        return self.present & bit != 0;
    }

    fn setString(self: *Metadata, a: std.mem.Allocator, slot: *[]u8, bit: u8, value_in: []const u8, overwrite: bool) Error!void {
        if (!overwrite and self.has(bit)) return;
        const value = boundedUtf8(value_in) orelse return;
        const fresh: []u8 = if (value.len > 0) try a.dupe(u8, value) else &.{};
        if (slot.*.len > 0) a.free(slot.*);
        slot.* = fresh;
        self.present |= bit;
    }

    fn apply(self: *Metadata, a: std.mem.Allocator, key: []const u8, value: []const u8, overwrite: bool) Error!void {
        if (std.mem.eql(u8, key, "application.name")) {
            try self.setString(a, &self.application, application_bit, value, overwrite);
        } else if (std.mem.eql(u8, key, "application.process.binary")) {
            try self.setString(a, &self.binary, binary_bit, value, overwrite);
        } else if (std.mem.eql(u8, key, "media.name")) {
            try self.setString(a, &self.media_name, media_name_bit, value, overwrite);
        } else if (std.mem.eql(u8, key, "media.title")) {
            try self.setString(a, &self.media_title, media_title_bit, value, overwrite);
        } else if (std.mem.eql(u8, key, "application.icon_name")) {
            try self.setString(a, &self.application_icon, application_icon_bit, value, overwrite);
        } else if (std.mem.eql(u8, key, "media.icon_name")) {
            try self.setString(a, &self.media_icon, media_icon_bit, value, overwrite);
        } else if (std.mem.eql(u8, key, "application.process.id")) {
            if (overwrite or !self.has(pid_bit)) {
                const trimmed = std.mem.trimEnd(u8, value, "\x00");
                self.pid = std.fmt.parseInt(u32, trimmed, 10) catch 0;
                self.present |= pid_bit;
            }
        }
    }

    fn remove(self: *Metadata, a: std.mem.Allocator, key: []const u8) void {
        if (std.mem.eql(u8, key, "application.name")) {
            self.removeString(a, &self.application, application_bit);
        } else if (std.mem.eql(u8, key, "application.process.binary")) {
            self.removeString(a, &self.binary, binary_bit);
        } else if (std.mem.eql(u8, key, "media.name")) {
            self.removeString(a, &self.media_name, media_name_bit);
        } else if (std.mem.eql(u8, key, "media.title")) {
            self.removeString(a, &self.media_title, media_title_bit);
        } else if (std.mem.eql(u8, key, "application.icon_name")) {
            self.removeString(a, &self.application_icon, application_icon_bit);
        } else if (std.mem.eql(u8, key, "media.icon_name")) {
            self.removeString(a, &self.media_icon, media_icon_bit);
        } else if (std.mem.eql(u8, key, "application.process.id")) {
            self.pid = 0;
            self.present &= ~pid_bit;
        }
    }

    fn removeString(self: *Metadata, a: std.mem.Allocator, slot: *[]u8, bit: u8) void {
        if (slot.*.len > 0) a.free(slot.*);
        slot.* = &.{};
        self.present &= ~bit;
    }
};

const ProplistVisitor = *const fn (?*anyopaque, []const u8, []const u8) Error!void;

fn validProplistKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '_') return false;
    }
    return true;
}

fn walkProplist(r: *Tr, context: ?*anyopaque, visitor: ?ProplistVisitor) Error!void {
    if (try r.tag() != 'P') return Error.Protocol;
    while (true) {
        const t = try r.tag();
        if (t == 'N') return;
        if (t != 't') return Error.Protocol;
        const end = std.mem.indexOfScalarPos(u8, r.buf, r.pos, 0) orelse return Error.Protocol;
        const key = r.buf[r.pos..end];
        if (!validProplistKey(key)) return Error.Protocol;
        r.pos = end + 1;
        if (try r.tag() != 'L') return Error.Protocol;
        const len = try r.rawU32();
        if (try r.tag() != 'x') return Error.Protocol;
        const xlen = try r.rawU32();
        if (xlen != len or xlen > PROPLIST_VALUE_MAX or r.pos + xlen > r.buf.len) return Error.Protocol;
        if (visitor) |visit| try visit(context, key, r.buf[r.pos .. r.pos + xlen]);
        r.pos += xlen;
    }
}

const ApplyProperties = struct {
    allocator: std.mem.Allocator,
    metadata: *Metadata,
    overwrite: bool,

    fn visit(raw: ?*anyopaque, key: []const u8, value: []const u8) Error!void {
        const self: *ApplyProperties = @ptrCast(@alignCast(raw.?));
        try self.metadata.apply(self.allocator, key, value, self.overwrite);
    }
};

fn readProplist(r: *Tr, a: std.mem.Allocator, meta: *Metadata, mode: u32) Error!void {
    if (mode > 2) return Error.Protocol;
    // PA_UPDATE_SET replaces the complete list; MERGE keeps existing
    // values, while REPLACE overwrites only keys present in the update.
    if (mode == 0) meta.clear(a);
    var apply = ApplyProperties{ .allocator = a, .metadata = meta, .overwrite = mode != 1 };
    try walkProplist(r, @ptrCast(&apply), &ApplyProperties.visit);
}

fn removeProperties(r: *Tr, a: std.mem.Allocator, meta: *Metadata) Error!void {
    while (true) {
        const key = try r.str() orelse return;
        meta.remove(a, key);
    }
}

pub const Stream = struct {
    format: u8 = 3, // s16le
    channels: u8 = 2,
    rate: u32 = 44100,
    tlength: u32 = 0,
    minreq: u32 = 0,
    corked: bool = false,
    /// Bytes received from the app (its write clock).
    write_index: u64 = 0,
    /// Bytes the viewer reported played (the read clock).
    read_index: u64 = 0,
    /// Cumulative bytes REQUESTed from the app on the self-clock path
    /// (seeded with the create reply's `missing`). Pacing keeps it at
    /// read_index + tlength, minreq-granular.
    req_sent: u64 = 0,
    /// Self-clock base: read_index stood at `clock_base_bytes` at
    /// monotonic `clock_base_ms`. null = clock parked (no data in
    /// flight yet, corked, underrun, or viewer-clocked).
    clock_base_ms: ?i64 = null,
    clock_base_bytes: u64 = 0,
    /// A DRAIN awaiting read_index catching write_index; the tag is
    /// replied when playback (either clock) actually finishes.
    drain_tag: ?u32 = null,
    /// Viewer-reported local sink latency.
    gui_latency_us: u64 = 0,
    /// A viewer's `consumed` reports drive this stream's REQUESTs.
    /// Until the FIRST report (or after all viewers detach) the
    /// server self-clocks: read_index advances at the stream's
    /// declared byte rate on the host-injected monotonic clock —
    /// NEVER instantly. Apps that gate logic on playback progress
    /// (drain, latency queries, write requests) see real pacing even
    /// when every sample is discarded.
    viewer_clocked: bool = false,
    /// Opus decision made (latched at first data, sticky).
    opus_latched: bool = false,
    /// Live encoder (libopus available + subscriber wants it + s16 in the
    /// 48 kHz family). null = ship raw pcm units.
    opus_enc: ?opuscodec.Encoder = null,
    /// Partial 20 ms frame awaiting more samples.
    fbuf: std.ArrayList(u8) = .empty,
    metadata: Metadata = .{},

    fn deinitOwned(self: *Stream, a: std.mem.Allocator) void {
        if (self.opus_enc) |*e| e.deinit();
        self.opus_enc = null;
        self.fbuf.deinit(a);
        self.metadata.deinit(a);
    }

    fn bytesPerSec(self: *const Stream) u64 {
        return @as(u64, self.channels) * sampleSize(self.format) * self.rate;
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
    metadata: Metadata = .{},
    next_stream: u32 = 0,
    dead: bool = false,
    /// Any proto>=5 viewer attached (the daemon updates this each
    /// read round). false resets every stream to self-clocking.
    has_viewer: bool = false,
    /// A subscribed viewer advertised Opus decode (daemon-set).
    /// Latched per stream at first data.
    opus_wanted: bool = false,
    /// Host-injected monotonic milliseconds (set before feed/
    /// applyUnit, and by tick). The self-clock pace source — the
    /// state machine never reads the OS clock itself.
    now_ms: i64 = 0,
    /// Daemon-set: some OTHER connection in this session has active
    /// playback. The v15 sink state is session-wide, but a Server
    /// only sees its own connection's streams (pactl's own
    /// connection never has any).
    sink_running: bool = false,

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
        self.metadata.deinit(self.allocator);
    }

    pub fn streamInfo(self: *const Server, stream: *const Stream) AudioInfo {
        const stream_meta = &stream.metadata;
        const client_meta = &self.metadata;
        const media = if (stream_meta.media_title.len > 0)
            stream_meta.media_title
        else
            stream_meta.media_name;
        const stream_icon = if (stream_meta.media_icon.len > 0)
            stream_meta.media_icon
        else
            stream_meta.application_icon;
        const client_icon = if (client_meta.media_icon.len > 0)
            client_meta.media_icon
        else
            client_meta.application_icon;
        return .{
            .application = if (stream_meta.has(Metadata.application_bit)) stream_meta.application else client_meta.application,
            .binary = if (stream_meta.has(Metadata.binary_bit)) stream_meta.binary else client_meta.binary,
            .media = media,
            .icon = if (stream_icon.len > 0) stream_icon else client_icon,
            .pid = if (stream_meta.has(Metadata.pid_bit)) stream_meta.pid else client_meta.pid,
            .running = !stream.corked,
        };
    }

    pub fn appendStreamDescriptor(self: *const Server, out: *std.ArrayList(u8), stream_id: u32, stream: *const Stream) !void {
        var open: [10]u8 = undefined;
        std.mem.writeInt(u32, open[0..4], stream_id, .little);
        open[4] = stream.format;
        open[5] = stream.channels;
        std.mem.writeInt(u32, open[6..10], stream.rate, .little);
        try appendUnit(out, self.allocator, .open, &open);
        try appendMetadataUnit(out, self.allocator, stream_id, self.streamInfo(stream));
        var cork: [5]u8 = undefined;
        std.mem.writeInt(u32, cork[0..4], stream_id, .little);
        cork[4] = @intFromBool(stream.corked);
        try appendUnit(out, self.allocator, .cork, &cork);
    }

    fn emitMetadata(self: *Server, stream_id: u32) Error!void {
        const stream = self.streams.getPtr(stream_id) orelse return;
        try appendMetadataUnit(&self.units, self.allocator, stream_id, self.streamInfo(stream));
    }

    fn emitAllMetadata(self: *Server) Error!void {
        var it = self.streams.iterator();
        while (it.next()) |entry| try self.emitMetadata(entry.key_ptr.*);
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
                        @import("log.zig").warn("pulse protocol error on command {d} (payload {d} bytes)", .{ cmd, payload.len });
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
                s.clock_base_ms = null; // real playback took the clock
                s.read_index +|= n;
                // The viewer played n bytes: ask the app for n more.
                try self.sendRequest(idx, @intCast(@min(n, 0xffff_ffff)));
                try self.maybeFinishDrain(s);
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
        // libopus is available, a subscriber decodes it, and the spec
        // is s16 in the 48 kHz family (44.1 k stays raw — Opus
        // doesn't eat it and we don't resample).
        if (!s.opus_latched) {
            s.opus_latched = true;
            if (opuscodec.available() and self.opus_wanted and s.format == 3)
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
        if (!self.has_viewer and s.viewer_clocked) revertToSelfClock(s);
        if (!s.viewer_clocked) try self.pumpSelfClock(channel, s);
    }

    /// All viewers detached from a viewer-clocked stream: the self
    /// clock takes back over from the viewer's last reported position
    /// (otherwise the app waits forever for REQUESTs nobody sends).
    fn revertToSelfClock(s: *Stream) void {
        s.viewer_clocked = false;
        s.clock_base_ms = null;
        // Everything already received was implicitly requested.
        if (s.req_sent < s.write_index) s.req_sent = s.write_index;
    }

    /// Advance a self-clocked stream's read_index to `now_ms` at the
    /// declared byte rate, clamped to what was actually written. On
    /// underrun the clock parks so later data plays from "now" instead
    /// of instantly replaying the silent gap.
    fn advanceSelfClock(self: *Server, s: *Stream) void {
        if (s.viewer_clocked or s.corked) return;
        const bps = s.bytesPerSec();
        if (bps == 0) return;
        const base_ms = s.clock_base_ms orelse {
            if (s.write_index > s.read_index) {
                s.clock_base_ms = self.now_ms;
                s.clock_base_bytes = s.read_index;
            }
            return;
        };
        const elapsed: u64 = @intCast(@max(self.now_ms - base_ms, 0));
        // Frame-aligned, ALWAYS: an unaligned read_index yields
        // unaligned REQUESTs, and libpulse clients then attempt
        // unaligned writes that fail and kill their stream (SDL3
        // zombifies the whole device on the first one).
        const fb = @as(u64, s.channels) * sampleSize(s.format);
        var pos = s.clock_base_bytes +| elapsed * bps / 1000;
        if (fb > 0) pos -= pos % fb;
        if (pos >= s.write_index) {
            s.read_index = s.write_index;
            s.clock_base_ms = null;
        } else {
            s.read_index = pos;
        }
    }

    /// One self-clock pump: advance the clock, top up the app's write
    /// window (REQUESTs, minreq-granular), complete a pending drain.
    fn pumpSelfClock(self: *Server, idx: u32, s: *Stream) Error!void {
        self.advanceSelfClock(s);
        const want = s.read_index +| s.tlength;
        if (want > s.req_sent) {
            var delta = want - s.req_sent;
            const fb = @as(u64, s.channels) * sampleSize(s.format);
            if (fb > 0) delta -= delta % fb; // frame-aligned (see advance)
            if (delta >= @max(s.minreq, 1)) {
                try self.sendRequest(idx, @intCast(@min(delta, 0xffff_ffff)));
                s.req_sent += delta;
            }
        }
        try self.maybeFinishDrain(s);
    }

    fn maybeFinishDrain(self: *Server, s: *Stream) Error!void {
        const dtag = s.drain_tag orelse return;
        if (s.read_index < s.write_index) return;
        s.drain_tag = null;
        _ = try self.replyHead(dtag);
        try self.finishFrame();
    }

    /// Host-driven pacing: advance every self-clocked stream to
    /// `now_ms` (emitting REQUESTs / drain replies into `out`) and
    /// return the monotonic deadline of the next due event, or null
    /// when no stream needs pacing.
    pub fn tick(self: *Server, now_ms: i64) Error!?i64 {
        self.now_ms = now_ms;
        var next: ?i64 = null;
        var it = self.streams.iterator();
        while (it.next()) |e| {
            const s = e.value_ptr;
            if (!self.has_viewer and s.viewer_clocked) revertToSelfClock(s);
            if (s.viewer_clocked) continue;
            try self.pumpSelfClock(e.key_ptr.*, s);
            if (s.corked) continue;
            const bps = s.bytesPerSec();
            if (bps == 0) continue;
            const in_flight = s.write_index -| s.read_index;
            if (in_flight == 0 and s.drain_tag == null) continue;
            // Wake at whichever comes first: the drain/underrun point
            // or the next minreq-sized REQUEST becoming due.
            var target_bytes: u64 = in_flight;
            const want = s.read_index +| s.tlength;
            if (s.req_sent >= want) {
                const until_req = (s.req_sent - want) +| @max(s.minreq, 1);
                if (until_req < target_bytes) target_bytes = until_req;
            }
            const ms: i64 = @intCast(@max(target_bytes * 1000 / bps, 1));
            const d = now_ms +| ms;
            if (next == null or d < next.?) next = d;
        }
        return next;
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
                    try readProplist(&r, self.allocator, &self.metadata, 2);
                } else {
                    const name = try r.str() orelse "";
                    try self.metadata.setString(self.allocator, &self.metadata.application, Metadata.application_bit, name, true);
                }
                try self.emitAllMetadata();
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
                if (self.version >= 15) try t.channelMap(2); // default map
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
                // Replied only when playback catches the write head —
                // an instant ack here made `paplay` swallow whole
                // files in milliseconds. A superseded pending drain is
                // acked immediately (real PA cancels it likewise).
                const idx = try r.u32be();
                const s = self.streams.getPtr(idx) orelse
                    return self.sendError(tag, ERR_NOENTITY);
                if (s.drain_tag) |old| {
                    _ = try self.replyHead(old);
                    try self.finishFrame();
                }
                s.drain_tag = tag;
                if (!s.viewer_clocked) self.advanceSelfClock(s);
                try self.maybeFinishDrain(s);
            },
            CMD_GET_PLAYBACK_LATENCY => {
                const idx = try r.u32be();
                const tv = try r.timeval();
                const s = self.streams.getPtr(idx) orelse
                    return self.sendError(tag, ERR_NOENTITY);
                if (!s.viewer_clocked) self.advanceSelfClock(s);
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
                    // Bank played-so-far before freezing; uncork parks
                    // the base so playback resumes from "now".
                    if (!s.viewer_clocked) self.advanceSelfClock(s);
                    s.corked = b;
                    s.clock_base_ms = null;
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
                if (self.streams.getPtr(idx)) |s| {
                    if (tlength != 0 and tlength != 0xffff_ffff) s.tlength = tlength;
                    if (minreq != 0 and minreq != 0xffff_ffff) s.minreq = minreq;
                }
                var t = try self.replyHead(tag);
                try t.u32be(4 * 1024 * 1024); // maxlength
                try t.u32be(tlength);
                try t.u32be(0); // prebuf
                try t.u32be(minreq);
                if (self.version >= 13) try t.usec(20_000);
                try self.finishFrame();
            },
            CMD_FLUSH_PLAYBACK_STREAM => {
                // Discard in-flight: playback jumps to the write head
                // and a pending drain completes trivially.
                const idx = try r.u32be();
                if (self.streams.getPtr(idx)) |s| {
                    s.read_index = s.write_index;
                    s.clock_base_ms = null;
                    try self.maybeFinishDrain(s);
                }
                _ = try self.replyHead(tag);
                try self.finishFrame();
            },
            CMD_UPDATE_PLAYBACK_STREAM_SAMPLE_RATE => {
                // The rate drives self-clock pacing — rebase so
                // already-played bytes keep their old rate.
                const idx = try r.u32be();
                const rate = try r.u32be();
                if (self.streams.getPtr(idx)) |s| {
                    if (!s.viewer_clocked) self.advanceSelfClock(s);
                    s.clock_base_ms = null;
                    if (rate > 0) s.rate = rate;
                }
                _ = try self.replyHead(tag);
                try self.finishFrame();
            },
            CMD_SET_PLAYBACK_STREAM_NAME => {
                const idx = try r.u32be();
                const name = try r.str() orelse return self.sendError(tag, ERR_INVALID);
                if (!std.unicode.utf8ValidateSlice(name)) return self.sendError(tag, ERR_INVALID);
                const s = self.streams.getPtr(idx) orelse return self.sendError(tag, ERR_NOENTITY);
                try s.metadata.setString(self.allocator, &s.metadata.media_name, Metadata.media_name_bit, name, true);
                try self.emitMetadata(idx);
                _ = try self.replyHead(tag);
                try self.finishFrame();
            },
            CMD_UPDATE_PLAYBACK_STREAM_PROPLIST => {
                const idx = try r.u32be();
                const mode = try r.u32be();
                if (mode > 2) {
                    try r.skipProplist();
                    return self.sendError(tag, ERR_INVALID);
                }
                const s = self.streams.getPtr(idx) orelse {
                    try r.skipProplist();
                    return self.sendError(tag, ERR_NOENTITY);
                };
                try readProplist(&r, self.allocator, &s.metadata, mode);
                try self.emitMetadata(idx);
                _ = try self.replyHead(tag);
                try self.finishFrame();
            },
            CMD_REMOVE_PLAYBACK_STREAM_PROPLIST => {
                const idx = try r.u32be();
                const s = self.streams.getPtr(idx) orelse {
                    while (try r.str() != null) {}
                    return self.sendError(tag, ERR_NOENTITY);
                };
                try removeProperties(&r, self.allocator, &s.metadata);
                try self.emitMetadata(idx);
                _ = try self.replyHead(tag);
                try self.finishFrame();
            },
            CMD_UPDATE_CLIENT_PROPLIST => {
                const mode = try r.u32be();
                if (mode > 2) {
                    try r.skipProplist();
                    return self.sendError(tag, ERR_INVALID);
                }
                try readProplist(&r, self.allocator, &self.metadata, mode);
                try self.emitAllMetadata();
                _ = try self.replyHead(tag);
                try self.finishFrame();
            },
            CMD_REMOVE_CLIENT_PROPLIST => {
                try removeProperties(&r, self.allocator, &self.metadata);
                try self.emitAllMetadata();
                _ = try self.replyHead(tag);
                try self.finishFrame();
            },
            // Accepted, trivially acknowledged (their real replies
            // ARE empty acks — anything with a payload gets its own
            // handler above; an empty reply where the client expects
            // fields fails its parse, or worse).
            CMD_SUBSCRIBE,
            CMD_EXIT,
            CMD_TRIGGER_PLAYBACK_STREAM,
            CMD_SET_SINK_INPUT_VOLUME,
            CMD_SET_SINK_INPUT_MUTE,
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
        var metadata: Metadata = .{};
        var metadata_transferred = false;
        defer if (!metadata_transferred) metadata.deinit(self.allocator);
        if (self.version < 13) {
            const name = try r.str() orelse "";
            try metadata.setString(self.allocator, &metadata.media_name, Metadata.media_name_bit, name, true);
        }
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
            try readProplist(r, self.allocator, &metadata, 0);
        }
        if (self.version >= 14) {
            _ = try r.boolean(); // volume_set
            _ = try r.boolean(); // early_requests
        }
        if (self.version >= 15) {
            _ = try r.boolean(); // muted_set
            _ = try r.boolean(); // dont_inhibit_auto_suspend
            _ = try r.boolean(); // fail_on_suspend
        }

        const frame_bytes: u32 = @max(@as(u32, ss.channels) * sampleSize(ss.format), 1);
        const bytes_per_sec: u64 = @as(u64, frame_bytes) * ss.rate;
        // A remote sink needs a real jitter window even when the client asks
        // for a tiny low-latency buffer.  Without this floor, replenishing a
        // 20-50 ms tlength takes a complete viewer<->daemon round trip and
        // inevitably underruns on SSH or behind a graphical frame.
        // Frame-aligned: unaligned server sizes lead clients into
        // unaligned writes that fail (see advanceSelfClock).
        const remote_tlength: u32 = @intCast(@max(bytes_per_sec * REMOTE_TLENGTH_US / 1_000_000, 4096));
        if (tlength < remote_tlength or tlength == 0xffff_ffff)
            tlength = remote_tlength;
        tlength -= tlength % frame_bytes;
        if (maxlength == 0 or maxlength == 0xffff_ffff or maxlength < tlength)
            maxlength = @max(4 * 1024 * 1024, tlength);
        if (minreq < frame_bytes or minreq == 0xffff_ffff)
            minreq = @intCast(@max(bytes_per_sec / 50, 1024));
        minreq -= minreq % frame_bytes;

        const idx = self.next_stream;
        self.next_stream += 1;
        if (std.c.getenv("SKETERM_PA_DEBUG") != null)
            std.debug.print("pulse: create stream {d}: fmt {d} ch {d} rate {d} tlength {d} minreq {d} maxlength {d}\n", .{ idx, ss.format, ss.channels, ss.rate, tlength, minreq, maxlength });
        try self.streams.put(self.allocator, idx, .{
            .format = ss.format,
            .channels = ss.channels,
            .rate = ss.rate,
            .tlength = tlength,
            .minreq = minreq,
            .corked = corked,
            .metadata = metadata,
            // The reply's `missing` below grants a full buffer.
            .req_sent = tlength,
        });
        metadata_transferred = true;
        try self.appendStreamDescriptor(&self.units, idx, self.streams.getPtr(idx).?);

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

    /// v15 sink/source state: RUNNING while any stream on this
    /// connection is uncorked, or the daemon flagged playback on a
    /// sibling connection of the same session.
    fn sinkState(self: *const Server) u32 {
        if (self.sink_running) return STATE_RUNNING;
        var it = self.streams.valueIterator();
        while (it.next()) |s| {
            if (!s.corked) return STATE_RUNNING;
        }
        return STATE_IDLE;
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
        if (self.version >= 15) {
            try t.volume(0x10000); // base volume: norm
            try t.u32be(self.sinkState());
            try t.u32be(0x10000 + 1); // n_volume_steps (digital)
            try t.u32be(INVALID_INDEX); // card
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
        if (self.version >= 15) {
            try t.volume(0x10000); // base volume: norm
            try t.u32be(self.sinkState()); // monitor mirrors the sink
            try t.u32be(0x10000 + 1); // n_volume_steps
            try t.u32be(INVALID_INDEX); // card
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
        if (std.c.getenv("SKETERM_PA_DEBUG") != null)
            std.debug.print("pulse: REQUEST stream {d} nbytes {d}\n", .{ idx, nbytes });
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

fn testProplist(a: std.mem.Allocator, out: *std.ArrayList(u8), properties: []const struct { key: []const u8, value: []const u8 }) !void {
    try out.append(a, 'P');
    for (properties) |property| {
        try out.append(a, 't');
        try out.appendSlice(a, property.key);
        try out.append(a, 0);
        try out.append(a, 'L');
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(property.value.len + 1), .big);
        try out.appendSlice(a, &len);
        try out.append(a, 'x');
        try out.appendSlice(a, &len);
        try out.appendSlice(a, property.value);
        try out.append(a, 0);
    }
    try out.append(a, 'N');
}

test "audio metadata proplists are bounded, inherited and encoded" {
    const a = t_.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    try testProplist(a, &raw, &.{
        .{ .key = "application.name", .value = "Firefox" },
        .{ .key = "application.process.binary", .value = "firefox" },
        .{ .key = "application.process.id", .value = "321" },
        .{ .key = "application.icon_name", .value = "firefox" },
    });
    var server_meta: Metadata = .{};
    defer server_meta.deinit(a);
    var reader = Tr{ .buf = raw.items };
    try readProplist(&reader, a, &server_meta, 0);
    try t_.expectEqualStrings("Firefox", server_meta.application);
    try t_.expectEqualStrings("firefox", server_meta.binary);
    try t_.expectEqual(@as(u32, 321), server_meta.pid);

    var srv = Server.init(a);
    defer srv.deinit();
    srv.metadata = server_meta;
    server_meta = .{};
    var stream_meta: Metadata = .{};
    try stream_meta.setString(a, &stream_meta.media_name, Metadata.media_name_bit, "A very important call", true);
    try srv.streams.put(a, 7, .{ .corked = true, .metadata = stream_meta });
    stream_meta = .{};
    try srv.appendStreamDescriptor(&srv.units, 7, srv.streams.getPtr(7).?);

    const opened = peelUnit(srv.units.items).?;
    try t_.expectEqual(UnitTag.open, opened.tag);
    const meta = peelUnit(srv.units.items[opened.consumed..]).?;
    try t_.expectEqual(UnitTag.metadata, meta.tag);
    const decoded = decodeMetadata(meta.payload).?;
    try t_.expectEqual(@as(u32, 7), decoded.stream);
    try t_.expectEqualStrings("Firefox", decoded.info.application);
    try t_.expectEqualStrings("A very important call", decoded.info.media);
    try t_.expectEqual(@as(u32, 321), decoded.info.pid);
    const cork = peelUnit(srv.units.items[opened.consumed + meta.consumed ..]).?;
    try t_.expectEqual(UnitTag.cork, cork.tag);
    try t_.expectEqual(@as(u8, 1), cork.payload[4]);
}

test "audio metadata preserves Pulse property semantics and UTF-8 boundaries" {
    const a = t_.allocator;
    var meta: Metadata = .{};
    defer meta.deinit(a);

    try meta.apply(a, "media.name", "fallback stream name", true);
    try meta.apply(a, "media.title", "Track title", true);
    try meta.apply(a, "application.icon_name", "player", true);
    try meta.apply(a, "media.icon_name", "album-art", true);
    meta.remove(a, "media.name");
    meta.remove(a, "application.icon_name");
    try t_.expectEqualStrings("Track title", meta.media_title);
    try t_.expectEqualStrings("album-art", meta.media_icon);

    var long: [130]u8 = undefined;
    @memset(long[0..127], 'x');
    @memcpy(long[127..130], "€");
    try meta.apply(a, "application.name", &long, true);
    try t_.expectEqual(@as(usize, 127), meta.application.len);
    try t_.expect(std.unicode.utf8ValidateSlice(meta.application));

    const old = try a.dupe(u8, meta.application);
    defer a.free(old);
    try meta.apply(a, "application.name", "\xffinvalid", true);
    try t_.expectEqualStrings(old, meta.application);

    // MERGE keeps even an explicitly empty property; REPLACE changes it.
    try meta.apply(a, "application.process.binary", "", true);
    try meta.apply(a, "application.process.binary", "ignored", false);
    try t_.expectEqualStrings("", meta.binary);
    try meta.apply(a, "application.process.binary", "replacement", true);
    try t_.expectEqualStrings("replacement", meta.binary);
}

test "Pulse proplists reject invalid keys and oversized values" {
    const a = t_.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);

    try testProplist(a, &raw, &.{.{ .key = "invalid key", .value = "value" }});
    var reader = Tr{ .buf = raw.items };
    var meta: Metadata = .{};
    defer meta.deinit(a);
    try t_.expectError(Error.Protocol, readProplist(&reader, a, &meta, 0));

    raw.clearRetainingCapacity();
    const large = try a.alloc(u8, PROPLIST_VALUE_MAX);
    defer a.free(large);
    @memset(large, 'x');
    try testProplist(a, &raw, &.{.{ .key = "application.name", .value = large }});
    reader = .{ .buf = raw.items };
    try t_.expectError(Error.Protocol, readProplist(&reader, a, &meta, 0));
}

test "set playback stream name rejects invalid UTF-8" {
    const a = t_.allocator;
    var srv = Server.init(a);
    defer srv.deinit();
    srv.authorized = true;
    var metadata: Metadata = .{};
    try metadata.setString(a, &metadata.media_name, Metadata.media_name_bit, "original", true);
    try srv.streams.put(a, 0, .{ .metadata = metadata });
    metadata = .{};

    var fields: std.ArrayList(u8) = .empty;
    defer fields.deinit(a);
    const w = Tw{ .buf = &fields, .a = a };
    try w.u32be(CMD_SET_PLAYBACK_STREAM_NAME);
    try w.u32be(17);
    try w.u32be(0);
    try w.str("\xffinvalid");
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(a);
    try clientFrame(a, &frame, fields.items);
    try srv.feed(frame.items);

    var reply = Tr{ .buf = srv.takeOut()[DESC_SIZE..] };
    try t_.expectEqual(@as(u32, CMD_ERROR), try reply.u32be());
    try t_.expectEqual(@as(u32, 17), try reply.u32be());
    try t_.expectEqual(@as(u32, ERR_INVALID), try reply.u32be());
    try t_.expectEqualStrings("original", srv.streams.get(0).?.metadata.media_name);
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
        try w.u32be(960); // tiny 5 ms tlength: remote floor must enlarge it
        try w.u32be(0xffff_ffff); // prebuf
        try w.u32be(0xffff_ffff); // minreq
        try w.u32be(0); // syncid
        try w.cvolume(2, 0x10000);
        var i: u8 = 0; // v12 bools
        while (i < 7) : (i += 1) try w.boolean(false);
        try w.boolean(false); // muted
        try w.boolean(true); // adjust_latency
        try w.emptyProplist();
        try w.boolean(false); // v14: volume_set
        try w.boolean(false); // v14: early_requests
        try w.boolean(false); // v15: muted_set
        try w.boolean(false); // v15: dont_inhibit_auto_suspend
        try w.boolean(false); // v15: fail_on_suspend
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(a);
        try clientFrame(a, &frame, fields.items);
        try srv.feed(frame.items);
        fields.clearRetainingCapacity();
    }
    try t_.expectEqual(@as(u32, 1), srv.streams.count());
    { // reply: channel 0, sink input 0, missing = 500 ms jitter window
        var r = Tr{ .buf = srv.takeOut()[DESC_SIZE..] };
        try t_.expectEqual(@as(u32, CMD_REPLY), try r.u32be());
        try t_.expectEqual(@as(u32, 3), try r.u32be());
        try t_.expectEqual(@as(u32, 0), try r.u32be()); // channel
        try t_.expectEqual(@as(u32, 0), try r.u32be()); // sink input
        const missing = try r.u32be();
        try t_.expectEqual(@as(u32, 96_000), missing);
        try t_.expectEqual(@as(u32, 96_000), srv.streams.get(0).?.tlength);
        srv.clearOut();
    }
    { // open unit went out
        const u = peelUnit(srv.takeUnits()).?;
        try t_.expectEqual(UnitTag.open, u.tag);
        try t_.expectEqual(@as(u32, 48000), std.mem.readInt(u32, u.payload[6..10], .little));
        srv.clearUnits();
    }

    { // PCM frame on channel 0 → pcm unit; no viewer → self-CLOCKED
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
        // NOT consumed instantly anymore: the self-clock paces it.
        try t_.expectEqual(@as(usize, 0), srv.takeOut().len);
        try t_.expectEqual(@as(u64, 0), srv.streams.get(0).?.read_index);
        // A tick well past the 8 bytes' duration plays them out.
        _ = try srv.tick(1000);
        try t_.expectEqual(@as(u64, 8), srv.streams.get(0).?.read_index);
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

/// Read one control frame from `buf`, returning command + a reader
/// positioned after (command, tag) plus the total frame size.
fn peelControl(buf: []const u8) ?struct { command: u32, tag: u32, size: usize } {
    if (buf.len < DESC_SIZE) return null;
    const len = std.mem.readInt(u32, buf[0..4], .big);
    if (buf.len < DESC_SIZE + len) return null;
    var r = Tr{ .buf = buf[DESC_SIZE .. DESC_SIZE + len] };
    const command = r.u32be() catch return null;
    const tag = r.u32be() catch return null;
    return .{ .command = command, .tag = tag, .size = DESC_SIZE + len };
}

test "v15 sink state: IDLE empty, RUNNING with playback (own or sibling)" {
    const a = t_.allocator;
    var srv = Server.init(a);
    defer srv.deinit();
    try t_.expectEqual(STATE_IDLE, srv.sinkState());
    srv.sink_running = true; // another connection in the session plays
    try t_.expectEqual(STATE_RUNNING, srv.sinkState());
    srv.sink_running = false;
    try srv.streams.put(a, 0, .{ .corked = true });
    try t_.expectEqual(STATE_IDLE, srv.sinkState());
    srv.streams.getPtr(0).?.corked = false;
    try t_.expectEqual(STATE_RUNNING, srv.sinkState());
}

test "self-clock paces read_index and REQUESTs on real time" {
    const a = t_.allocator;
    var srv = Server.init(a);
    defer srv.deinit();
    srv.authorized = true;
    // 48 kHz s16 stereo: 192000 B/s; ~200 ms tlength, ~20 ms minreq.
    try srv.streams.put(a, 0, .{ .rate = 48000, .tlength = 38400, .minreq = 3840, .req_sent = 38400 });

    // App writes 50 ms of audio (9600 bytes) at t=0.
    srv.now_ms = 0;
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(a);
    var desc: [DESC_SIZE]u8 = [_]u8{0} ** DESC_SIZE;
    std.mem.writeInt(u32, desc[0..4], 9600, .big);
    std.mem.writeInt(u32, desc[4..8], 0, .big);
    try frame.appendSlice(a, &desc);
    try frame.appendSlice(a, &([_]u8{0} ** 9600));
    try srv.feed(frame.items);
    srv.clearUnits();
    try t_.expectEqual(@as(usize, 0), srv.takeOut().len); // nothing played yet

    // 25 ms in: 4800 bytes played, one REQUEST(4800) due.
    const d1 = try srv.tick(25);
    try t_.expectEqual(@as(u64, 4800), srv.streams.get(0).?.read_index);
    const pc = peelControl(srv.takeOut()).?;
    try t_.expectEqual(@as(u32, CMD_REQUEST), pc.command);
    srv.clearOut();
    try t_.expect(d1 != null); // in-flight remains → wants another tick

    // Way past the end: clamps at write_index (underrun), never beyond.
    _ = try srv.tick(10_000);
    try t_.expectEqual(@as(u64, 9600), srv.streams.get(0).?.read_index);
    srv.clearOut();

    // Fully played, no drain pending → idle, no deadline.
    try t_.expectEqual(@as(?i64, null), try srv.tick(10_001));
}

test "drain completes on the clock, not instantly" {
    const a = t_.allocator;
    var srv = Server.init(a);
    defer srv.deinit();
    srv.authorized = true;
    try srv.streams.put(a, 0, .{ .rate = 48000, .tlength = 38400, .minreq = 3840, .req_sent = 38400 });

    srv.now_ms = 0;
    { // 100 ms of audio
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(a);
        var desc: [DESC_SIZE]u8 = [_]u8{0} ** DESC_SIZE;
        std.mem.writeInt(u32, desc[0..4], 19200, .big);
        std.mem.writeInt(u32, desc[4..8], 0, .big);
        try frame.appendSlice(a, &desc);
        try frame.appendSlice(a, &([_]u8{0} ** 19200));
        try srv.feed(frame.items);
        srv.clearUnits();
    }
    { // DRAIN at t=0: no reply yet
        var fields: std.ArrayList(u8) = .empty;
        defer fields.deinit(a);
        const w = Tw{ .buf = &fields, .a = a };
        try w.u32be(CMD_DRAIN_PLAYBACK_STREAM);
        try w.u32be(42);
        try w.u32be(0);
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(a);
        try clientFrame(a, &frame, fields.items);
        try srv.feed(frame.items);
    }
    try t_.expectEqual(@as(usize, 0), srv.takeOut().len);
    try t_.expectEqual(@as(?u32, 42), srv.streams.get(0).?.drain_tag);

    // Halfway: still draining (REQUESTs may flow, but no REPLY 42).
    _ = try srv.tick(50);
    {
        var buf = srv.takeOut();
        while (peelControl(buf)) |pc2| {
            try t_.expect(pc2.command != CMD_REPLY);
            buf = buf[pc2.size..];
        }
        srv.clearOut();
    }

    // Past the 100 ms mark: the drain reply lands with its tag.
    _ = try srv.tick(101);
    var found = false;
    var buf = srv.takeOut();
    while (peelControl(buf)) |pc2| {
        if (pc2.command == CMD_REPLY and pc2.tag == 42) found = true;
        buf = buf[pc2.size..];
    }
    try t_.expect(found);
    try t_.expectEqual(@as(?u32, null), srv.streams.get(0).?.drain_tag);
}

test "viewer detach mid-stream reverts to the self clock" {
    const a = t_.allocator;
    var srv = Server.init(a);
    defer srv.deinit();
    srv.authorized = true;
    srv.has_viewer = true;
    try srv.streams.put(a, 0, .{ .rate = 48000, .tlength = 38400, .minreq = 3840, .req_sent = 38400 });

    // Viewer clocks the stream, then the app banks unplayed data.
    var pl: [12]u8 = undefined;
    std.mem.writeInt(u32, pl[0..4], 0, .little);
    std.mem.writeInt(u64, pl[4..12], 4800, .little);
    srv.now_ms = 0;
    try srv.applyUnit(.consumed, &pl);
    srv.clearOut();
    try t_.expect(srv.streams.get(0).?.viewer_clocked);
    srv.streams.getPtr(0).?.write_index = 48000; // in-flight backlog

    // Viewer gone: with the old code REQUESTs stopped forever here.
    srv.has_viewer = false;
    const deadline = try srv.tick(1000); // arms the self clock from the backlog
    try t_.expect(deadline != null); // backlog in flight → wants pacing
    _ = try srv.tick(1500);
    const s = srv.streams.get(0).?;
    try t_.expect(!s.viewer_clocked);
    try t_.expect(s.read_index > 4800); // playback resumed on our clock
    var found_req = false;
    var buf = srv.takeOut();
    while (peelControl(buf)) |pc2| {
        if (pc2.command == CMD_REQUEST) found_req = true;
        buf = buf[pc2.size..];
    }
    try t_.expect(found_req);
}

test "flush jumps playback to the write head" {
    const a = t_.allocator;
    var srv = Server.init(a);
    defer srv.deinit();
    srv.authorized = true;
    try srv.streams.put(a, 0, .{ .rate = 48000, .tlength = 38400, .minreq = 3840, .req_sent = 38400, .write_index = 19200, .drain_tag = 7 });

    var fields: std.ArrayList(u8) = .empty;
    defer fields.deinit(a);
    const w = Tw{ .buf = &fields, .a = a };
    try w.u32be(CMD_FLUSH_PLAYBACK_STREAM);
    try w.u32be(8);
    try w.u32be(0);
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(a);
    try clientFrame(a, &frame, fields.items);
    try srv.feed(frame.items);

    const s = srv.streams.get(0).?;
    try t_.expectEqual(@as(u64, 19200), s.read_index);
    try t_.expectEqual(@as(?u32, null), s.drain_tag);
    // Both the pending drain (tag 7) and the flush (tag 8) got replies.
    var seen7 = false;
    var seen8 = false;
    var buf = srv.takeOut();
    while (peelControl(buf)) |pc2| {
        if (pc2.command == CMD_REPLY and pc2.tag == 7) seen7 = true;
        if (pc2.command == CMD_REPLY and pc2.tag == 8) seen8 = true;
        buf = buf[pc2.size..];
    }
    try t_.expect(seen7 and seen8);
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
        _ = try r.channelMap(); // v15: default channel map (pactl info parse)
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
        _ = try r.tag(); // requested latency (usec)
        _ = try r.rawU32();
        _ = try r.rawU32();
        try t_.expectEqual(@as(u8, 'V'), try r.tag()); // v15 base volume
        _ = try r.rawU32();
        try t_.expectEqual(STATE_IDLE, try r.u32be()); // v15 state
        _ = try r.u32be(); // n_volume_steps
        try t_.expectEqual(INVALID_INDEX, try r.u32be()); // card
        try t_.expectEqual(r.buf.len, r.pos); // consumed exactly
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
