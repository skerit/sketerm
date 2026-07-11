//! Opus codec layer for the remote-audio path (-Daudio-opus).
//! Mirrors vcodec.zig's shape: with the flag off every impl
//! collapses to `void` and nothing links — the daemon stays
//! dependency-free and PCM ships raw. libopus is declared via
//! extern fn (like zstd), no headers needed.
//!
//! Scope: s16 interleaved, 20 ms frames, the 48 kHz family only
//! (Opus can't eat 44.1 k — those streams stay raw).

const std = @import("std");
const build_options = @import("build_options");

pub const enabled = build_options.audio_opus;

/// 20 ms — the interactive sweet spot; one frame of added latency.
pub const FRAME_MS = 20;
/// Bitrate for transparent-ish stereo music.
const BITRATE: i32 = 128_000;
/// OPUS_APPLICATION_AUDIO (music-tuned).
const APPLICATION_AUDIO: c_int = 2049;
const SET_BITRATE_REQUEST: c_int = 4002;
/// Upper bound on one encoded 20 ms packet.
pub const MAX_PACKET = 4000;
/// Decoder scratch: 120 ms of stereo (libopus' documented max).
pub const MAX_DECODE_SAMPLES = 5760 * 2;

pub fn rateSupported(rate: u32) bool {
    return switch (rate) {
        8000, 12000, 16000, 24000, 48000 => true,
        else => false,
    };
}

const c_opus = if (enabled) struct {
    extern fn opus_encoder_create(fs: i32, channels: c_int, application: c_int, err: ?*c_int) ?*anyopaque;
    extern fn opus_encoder_destroy(st: ?*anyopaque) void;
    extern fn opus_encoder_ctl(st: ?*anyopaque, request: c_int, ...) c_int;
    extern fn opus_encode(st: ?*anyopaque, pcm: [*]const i16, frame_size: c_int, data: [*]u8, max_bytes: i32) i32;
    extern fn opus_decoder_create(fs: i32, channels: c_int, err: ?*c_int) ?*anyopaque;
    extern fn opus_decoder_destroy(st: ?*anyopaque) void;
    extern fn opus_decode(st: ?*anyopaque, data: ?[*]const u8, len: i32, pcm: [*]i16, frame_size: c_int, decode_fec: c_int) c_int;
} else struct {};

pub const Encoder = if (enabled) struct {
    st: *anyopaque,
    channels: u8,
    rate: u32,

    pub fn init(rate: u32, channels: u8) ?Encoder {
        if (!rateSupported(rate) or channels == 0 or channels > 2) return null;
        var err: c_int = 0;
        const st = c_opus.opus_encoder_create(@intCast(rate), channels, APPLICATION_AUDIO, &err) orelse return null;
        if (err != 0) {
            c_opus.opus_encoder_destroy(st);
            return null;
        }
        _ = c_opus.opus_encoder_ctl(st, SET_BITRATE_REQUEST, BITRATE);
        return .{ .st = st, .channels = channels, .rate = rate };
    }

    pub fn deinit(self: *Encoder) void {
        c_opus.opus_encoder_destroy(self.st);
    }

    /// Samples per channel in one 20 ms frame.
    pub fn frameSamples(self: *const Encoder) usize {
        return self.rate / (1000 / FRAME_MS);
    }

    /// Bytes of interleaved s16 in one 20 ms frame.
    pub fn frameBytes(self: *const Encoder) usize {
        return self.frameSamples() * self.channels * 2;
    }

    /// Encode exactly one frame of interleaved s16; returns the
    /// packet slice into `out` (null on encoder error).
    pub fn encode(self: *Encoder, pcm: []const u8, out: *[MAX_PACKET]u8) ?[]const u8 {
        std.debug.assert(pcm.len == self.frameBytes());
        const n = c_opus.opus_encode(
            self.st,
            @ptrCast(@alignCast(pcm.ptr)),
            @intCast(self.frameSamples()),
            out,
            MAX_PACKET,
        );
        if (n <= 0) return null;
        return out[0..@intCast(n)];
    }
} else struct {
    pub fn init(rate: u32, channels: u8) ?@This() {
        _ = rate;
        _ = channels;
        return null;
    }
    pub fn deinit(self: *@This()) void {
        _ = self;
    }
    pub fn frameSamples(self: *const @This()) usize {
        _ = self;
        unreachable; // init always returns null when disabled
    }
    pub fn frameBytes(self: *const @This()) usize {
        _ = self;
        unreachable;
    }
    pub fn encode(self: *@This(), pcm: []const u8, out: *[MAX_PACKET]u8) ?[]const u8 {
        _ = self;
        _ = pcm;
        _ = out;
        unreachable;
    }
};

pub const Decoder = if (enabled) struct {
    st: *anyopaque,
    channels: u8,
    rate: u32,

    pub fn init(rate: u32, channels: u8) ?Decoder {
        if (!rateSupported(rate) or channels == 0 or channels > 2) return null;
        var err: c_int = 0;
        const st = c_opus.opus_decoder_create(@intCast(rate), channels, &err) orelse return null;
        if (err != 0) {
            c_opus.opus_decoder_destroy(st);
            return null;
        }
        return .{ .st = st, .channels = channels, .rate = rate };
    }

    pub fn deinit(self: *Decoder) void {
        c_opus.opus_decoder_destroy(self.st);
    }

    /// Decode one packet into interleaved s16; returns the byte
    /// slice into `out` (null on decode error).
    pub fn decode(self: *Decoder, packet: []const u8, out: *[MAX_DECODE_SAMPLES]i16) ?[]const u8 {
        const n = c_opus.opus_decode(
            self.st,
            packet.ptr,
            @intCast(packet.len),
            out,
            @intCast(MAX_DECODE_SAMPLES / @as(usize, self.channels)),
            0,
        );
        if (n <= 0) return null;
        const bytes = @as(usize, @intCast(n)) * self.channels * 2;
        return @as([*]const u8, @ptrCast(out))[0..bytes];
    }
} else struct {
    pub fn init(rate: u32, channels: u8) ?@This() {
        _ = rate;
        _ = channels;
        return null;
    }
    pub fn deinit(self: *@This()) void {
        _ = self;
    }
    pub fn decode(self: *@This(), packet: []const u8, out: *[MAX_DECODE_SAMPLES]i16) ?[]const u8 {
        _ = self;
        _ = packet;
        _ = out;
        unreachable; // init always returns null when disabled
    }
};

// ─── tests (skip without -Daudio-opus) ──────────────────────────

test "opus round-trip: a 20 ms stereo sine survives" {
    if (!enabled) return error.SkipZigTest;
    var enc = Encoder.init(48000, 2) orelse return error.TestUnexpectedResult;
    defer enc.deinit();
    var dec = Decoder.init(48000, 2) orelse return error.TestUnexpectedResult;
    defer dec.deinit();

    var pcm: [960 * 2 * 2]u8 = undefined;
    var i: usize = 0;
    while (i < 960) : (i += 1) {
        const v: i16 = @intFromFloat(@sin(@as(f64, @floatFromInt(i)) * 0.05) * 8000.0);
        std.mem.writeInt(i16, pcm[i * 4 ..][0..2], v, .little);
        std.mem.writeInt(i16, pcm[i * 4 + 2 ..][0..2], v, .little);
    }
    var packet_buf: [MAX_PACKET]u8 = undefined;
    const packet = enc.encode(&pcm, &packet_buf) orelse return error.TestUnexpectedResult;
    // Compression actually happened.
    try std.testing.expect(packet.len < pcm.len / 4);

    var out: [MAX_DECODE_SAMPLES]i16 = undefined;
    const decoded = dec.decode(packet, &out) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(pcm.len, decoded.len);
}
