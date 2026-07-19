//! Opus codec layer for the remote-audio path. Normal builds probe
//! libopus at runtime, so compression works automatically wherever
//! the library is installed without adding it to sketerm-mux's ELF
//! dependency graph. `-Daudio-opus=false` compiles the probe out for
//! static portable builds; missing libopus degrades to raw PCM.
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

const EncoderCreate = *const fn (i32, c_int, c_int, ?*c_int) callconv(.c) ?*anyopaque;
const EncoderDestroy = *const fn (?*anyopaque) callconv(.c) void;
const EncoderCtl = *const fn (?*anyopaque, c_int, ...) callconv(.c) c_int;
const Encode = *const fn (?*anyopaque, [*]const i16, c_int, [*]u8, i32) callconv(.c) i32;
const DecoderCreate = *const fn (i32, c_int, ?*c_int) callconv(.c) ?*anyopaque;
const DecoderDestroy = *const fn (?*anyopaque) callconv(.c) void;
const Decode = *const fn (?*anyopaque, ?[*]const u8, i32, [*]i16, c_int, c_int) callconv(.c) i32;

const Api = struct {
    handle: *anyopaque,
    encoder_create: EncoderCreate,
    encoder_destroy: EncoderDestroy,
    encoder_ctl: EncoderCtl,
    encode: Encode,
    decoder_create: DecoderCreate,
    decoder_destroy: DecoderDestroy,
    decode: Decode,
};

extern fn dlopen(filename: [*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern fn dlclose(handle: ?*anyopaque) c_int;

const RTLD_LAZY: c_int = 0x1;
var load_attempted = false;
var loaded_api: ?Api = null;

fn sym(comptime T: type, handle: *anyopaque, name: [*:0]const u8) ?T {
    return @ptrCast(dlsym(handle, name) orelse return null);
}

fn loadApi() ?Api {
    const names = [_][*:0]const u8{
        "libopus.so.0",
        "libopus.so",
        "libopus.0.dylib",
        "libopus.dylib",
    };
    var handle: ?*anyopaque = null;
    for (names) |name| {
        handle = dlopen(name, RTLD_LAZY);
        if (handle != null) break;
    }
    const h = handle orelse return null;
    const encoder_create = sym(EncoderCreate, h, "opus_encoder_create") orelse {
        _ = dlclose(h);
        return null;
    };
    const encoder_destroy = sym(EncoderDestroy, h, "opus_encoder_destroy") orelse {
        _ = dlclose(h);
        return null;
    };
    const encoder_ctl = sym(EncoderCtl, h, "opus_encoder_ctl") orelse {
        _ = dlclose(h);
        return null;
    };
    const encode = sym(Encode, h, "opus_encode") orelse {
        _ = dlclose(h);
        return null;
    };
    const decoder_create = sym(DecoderCreate, h, "opus_decoder_create") orelse {
        _ = dlclose(h);
        return null;
    };
    const decoder_destroy = sym(DecoderDestroy, h, "opus_decoder_destroy") orelse {
        _ = dlclose(h);
        return null;
    };
    const decode = sym(Decode, h, "opus_decode") orelse {
        _ = dlclose(h);
        return null;
    };
    return .{
        .handle = h,
        .encoder_create = encoder_create,
        .encoder_destroy = encoder_destroy,
        .encoder_ctl = encoder_ctl,
        .encode = encode,
        .decoder_create = decoder_create,
        .decoder_destroy = decoder_destroy,
        .decode = decode,
    };
}

fn getApi() ?*const Api {
    if (comptime !enabled) return null;
    if (!load_attempted) {
        load_attempted = true;
        loaded_api = loadApi();
    }
    return if (loaded_api) |*api| api else null;
}

/// Runtime capability advertised over the mux handshake. A build may support
/// probing while the current machine has no libopus installed.
pub fn available() bool {
    return getApi() != null;
}

pub const Encoder = if (enabled) struct {
    api: *const Api,
    st: *anyopaque,
    channels: u8,
    rate: u32,

    pub fn init(rate: u32, channels: u8) ?Encoder {
        if (!rateSupported(rate) or channels == 0 or channels > 2) return null;
        const api = getApi() orelse return null;
        var err: c_int = 0;
        const st = api.encoder_create(@intCast(rate), channels, APPLICATION_AUDIO, &err) orelse return null;
        if (err != 0) {
            api.encoder_destroy(st);
            return null;
        }
        _ = api.encoder_ctl(st, SET_BITRATE_REQUEST, BITRATE);
        return .{ .api = api, .st = st, .channels = channels, .rate = rate };
    }

    pub fn deinit(self: *Encoder) void {
        self.api.encoder_destroy(self.st);
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
        const n = self.api.encode(
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
    api: *const Api,
    st: *anyopaque,
    channels: u8,
    rate: u32,

    pub fn init(rate: u32, channels: u8) ?Decoder {
        if (!rateSupported(rate) or channels == 0 or channels > 2) return null;
        const api = getApi() orelse return null;
        var err: c_int = 0;
        const st = api.decoder_create(@intCast(rate), channels, &err) orelse return null;
        if (err != 0) {
            api.decoder_destroy(st);
            return null;
        }
        return .{ .api = api, .st = st, .channels = channels, .rate = rate };
    }

    pub fn deinit(self: *Decoder) void {
        self.api.decoder_destroy(self.st);
    }

    /// Decode one packet into interleaved s16; returns the byte
    /// slice into `out` (null on decode error).
    pub fn decode(self: *Decoder, packet: []const u8, out: *[MAX_DECODE_SAMPLES]i16) ?[]const u8 {
        const n = self.api.decode(
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
    if (!available()) return error.SkipZigTest;
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
