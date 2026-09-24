//! Video-tile codec layer — the LOSSY / temporal path for HOT regions
//! of forwarded app windows (src/util/churn.zig + util/content.zig decide
//! which). Sibling of pixcodec (lossless): where pixcodec encodes a
//! self-contained region, vcodec encodes a surface as an opaque, possibly
//! inter-frame-predicted bitstream plus the framing a receiver needs to
//! decode it and place it in the window backing buffer.
//!
//! Who runs what: the session daemon ENCODES (daemon.zig `videoCommit`,
//! winstream/sck.zig on macOS) and the viewer DECODES (wlhost/compositor.zig
//! `pool_vtile`, winapp.zig `win_vtile`). Backends:
//!   - `.h264` encode: libx264 (vendor/x264_shim.c); VideoToolbox on a
//!     native macOS toolchain (vendor/vtenc_shim.c), same wire codec.
//!   - `.av1` encode: SVT-AV1 (vendor/svtav1_shim.c), low-delay.
//!   - decode, both codecs: libavcodec (vendor/avdec_shim.c; AV1 through
//!     libdav1d wherever ffmpeg has it).
//!   - `.stub`: raw BGRA passthrough, always available, for tests.
//!
//! Every third-party codec library is RUNTIME-LOADED (`dlopen`, the
//! opuscodec.zig pattern): `-Dvideo` compiles the shims against the
//! headers only, so sketerm-mux keeps its libc-only ELF graph, and what a
//! process can actually encode/decode is a runtime fact (`canEncode`,
//! `canDecode`) that the mux handshake negotiates: the viewer lists the
//! codecs it can decode (hello `video_codecs`, in its preference order),
//! the daemon picks the first one it can encode that every viewer of the
//! session shares (`negotiate`), and without a common codec the surface
//! simply stays lossless. See docs/app-video.md.

const std = @import("std");
const build_options = @import("build_options");
const yuv = @import("../util/yuv.zig");
const platform = @import("../util/platform.zig");

/// The x264 + libavcodec shims are compiled in (build_options.video: the
/// headers were found at build time). Says nothing about the RUNTIME:
/// the libraries are dlopen'd on first use, see `canEncode`/`canDecode`.
const have_video = build_options.video;
/// The SVT-AV1 shim is compiled in (its headers were found too).
const have_svt = build_options.video_av1enc;
const X264Impl = if (have_video) X264 else void;
const SvtImpl = if (have_svt) Svt else void;
const AvDecImpl = if (have_video) AvDec else void;

/// VideoToolbox H.264 encoder (build_options.vtenc — native macOS only).
/// The Mac-native encode path: hardware H.264 with NO libx264/libavcodec
/// dependency, a system framework. Independent of `have_video`: a Mac
/// daemon can have vtenc without video.
const have_vtenc = build_options.vtenc;
const VtImpl = if (have_vtenc) Vt else void;

// ─── runtime library loading ────────────────────────────────────

extern fn sk_x264_build() c_int;
extern fn sk_x264_bind(h: ?*anyopaque) c_int;
extern fn sk_av_codec_major() c_int;
extern fn sk_av_util_major() c_int;
extern fn sk_av_bind(hcodec: ?*anyopaque, hutil: ?*anyopaque) c_int;
extern fn sk_avdec_has(which: c_int) c_int;
extern fn sk_svt_major() c_int;
extern fn sk_svt_bind(h: ?*anyopaque) c_int;

const Probe = enum { unknown, ok, missing };
var x264_probe: Probe = .unknown;
var av_probe: Probe = .unknown;
var svt_probe: Probe = .unknown;

/// dlopen the Linux soname or Darwin dylib spelling of a versioned
/// library through platform.dlopenAny (which also knows the
/// Homebrew/MacPorts prefixes). The major comes from the header the shim
/// was compiled against, so a runtime of another ABI fails the open
/// instead of being called with mismatched struct layouts.
fn openVersioned(comptime linux_fmt: []const u8, comptime mac_fmt: []const u8, major: c_int) ?*anyopaque {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const n1 = std.fmt.bufPrintZ(&a, linux_fmt, .{major}) catch return null;
    const n2 = std.fmt.bufPrintZ(&b, mac_fmt, .{major}) catch return null;
    return platform.dlopenAny(&.{ n1.ptr, n2.ptr });
}

/// Test/diagnostic override: `SKETERM_VIDEO_DISABLE=h264,av1` (or `all`)
/// makes this process behave as if those codecs were absent, so the
/// negotiation and degrade-to-lossless paths are reachable on a host
/// that has every library.
fn disabledByEnv(codec: Codec) bool {
    const raw = std.c.getenv("SKETERM_VIDEO_DISABLE") orelse return false;
    var it = std.mem.tokenizeAny(u8, std.mem.span(raw), ", ");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "all")) return true;
        if (codecFromName(tok)) |named| {
            if (named == codec) return true;
        }
    }
    return false;
}

fn x264Loaded() bool {
    if (comptime !have_video) return false;
    if (x264_probe == .unknown) {
        const h = openVersioned("libx264.so.{d}", "libx264.{d}.dylib", sk_x264_build());
        x264_probe = if (h != null and sk_x264_bind(h) == 1) .ok else .missing;
    }
    return x264_probe == .ok;
}

fn avLoaded() bool {
    if (comptime !have_video) return false;
    if (av_probe == .unknown) {
        const util = openVersioned("libavutil.so.{d}", "libavutil.{d}.dylib", sk_av_util_major());
        const codec = openVersioned("libavcodec.so.{d}", "libavcodec.{d}.dylib", sk_av_codec_major());
        av_probe = if (util != null and codec != null and sk_av_bind(codec, util) == 1) .ok else .missing;
    }
    return av_probe == .ok;
}

fn svtLoaded() bool {
    if (comptime !have_svt) return false;
    if (svt_probe == .unknown) {
        const h = openVersioned("libSvtAv1Enc.so.{d}", "libSvtAv1Enc.{d}.dylib", sk_svt_major());
        svt_probe = if (h != null and sk_svt_bind(h) == 1) .ok else .missing;
    }
    return svt_probe == .ok;
}

/// This process can ENCODE `codec` right now (library present + bound).
/// The stub is deliberately not negotiable: it is a test backend.
pub fn canEncode(codec: Codec) bool {
    if (disabledByEnv(codec)) return false;
    return switch (codec) {
        .h264 => have_vtenc or x264Loaded(),
        .av1 => svtLoaded(),
        else => false,
    };
}

/// This process can DECODE `codec` right now.
pub fn canDecode(codec: Codec) bool {
    if (comptime !have_video) return false;
    if (disabledByEnv(codec)) return false;
    return switch (codec) {
        .h264, .av1 => avLoaded() and sk_avdec_has(shimCodec(codec)) == 1,
        else => false,
    };
}

// ─── negotiation ────────────────────────────────────────────────

/// Every codec a peer may negotiate, in the DAEMON's default preference
/// order: H.264 first (x264 ultrafast/zerolatency is the cheapest
/// real-time encoder by far), AV1 second (royalty-free, smaller on the
/// wire, several times the CPU). A viewer reorders it with its own list.
pub const negotiable = [_]Codec{ .h264, .av1 };

pub fn codecName(codec: Codec) []const u8 {
    return switch (codec) {
        .stub => "stub",
        .h264 => "h264",
        .av1 => "av1",
        _ => "unknown",
    };
}

pub fn codecFromName(name: []const u8) ?Codec {
    inline for (negotiable) |cd| {
        if (std.mem.eql(u8, name, codecName(cd))) return cd;
    }
    return null;
}

/// A small ordered set of codecs (preference order, no duplicates, no
/// stub). What a hello carries, what a Client keeps, what the broker's
/// handoff datagram ships.
pub const CodecList = struct {
    pub const cap = negotiable.len;
    buf: [cap]Codec = undefined,
    len: u8 = 0,

    pub fn items(self: *const CodecList) []const Codec {
        return self.buf[0..self.len];
    }

    pub fn contains(self: *const CodecList, codec: Codec) bool {
        return std.mem.indexOfScalar(Codec, self.items(), codec) != null;
    }

    /// Append unless already present, not negotiable, or full.
    pub fn add(self: *CodecList, codec: Codec) void {
        if (self.contains(codec) or self.len >= cap) return;
        if (std.mem.indexOfScalar(Codec, &negotiable, codec) == null) return;
        self.buf[self.len] = codec;
        self.len += 1;
    }

    /// A pre-negotiation peer's `video: bool`: every client that ever
    /// sent `true` decoded H.264 (the only codec such a daemon encoded),
    /// so the bool maps to exactly {h264} and never to AV1.
    pub fn fromLegacy(video: bool) CodecList {
        var l: CodecList = .{};
        if (video) l.add(.h264);
        return l;
    }

    /// Parse a hello's `video_codecs` names; unknown names (codecs a
    /// newer peer knows) are skipped, never an error.
    pub fn fromNames(names_in: []const []const u8) CodecList {
        var l: CodecList = .{};
        for (names_in) |n| {
            if (codecFromName(n)) |cd| l.add(cd);
        }
        return l;
    }

    /// Names for a JSON array; `out` must hold `cap` entries.
    pub fn names(self: *const CodecList, out: *[cap][]const u8) []const []const u8 {
        for (self.items(), 0..) |cd, i| out[i] = codecName(cd);
        return out[0..self.len];
    }

    /// Byte form for the broker->worker handoff: count, then codec ids.
    pub const wire_size = 1 + cap;
    pub fn encode(self: *const CodecList) [wire_size]u8 {
        var out: [wire_size]u8 = @splat(0);
        out[0] = self.len;
        for (self.items(), 0..) |cd, i| out[1 + i] = @intFromEnum(cd);
        return out;
    }
    pub fn decode(bytes: []const u8) CodecList {
        var l: CodecList = .{};
        if (bytes.len == 0) return l;
        const n = @min(bytes[0], bytes.len - 1);
        for (bytes[1 .. 1 + n]) |b| l.add(@enumFromInt(b));
        return l;
    }
};

/// What a user may ask for (config `app_video_codec`). `auto` offers
/// every decodable codec in the daemon's default order; a named codec
/// is offered FIRST with the others as fallbacks, so a daemon lacking
/// it still streams video; `lossless` offers nothing.
pub const Preference = enum { auto, h264, av1, lossless };

/// The list a viewer puts in its hello: `decodable` filtered and
/// ordered by the user's preference.
pub fn offer(pref: Preference, decodable: CodecList) CodecList {
    var l: CodecList = .{};
    switch (pref) {
        .lossless => return l,
        .h264 => if (decodable.contains(.h264)) l.add(.h264),
        .av1 => if (decodable.contains(.av1)) l.add(.av1),
        .auto => {},
    }
    for (negotiable) |cd| {
        if (decodable.contains(cd)) l.add(cd);
    }
    return l;
}

/// What this process can decode, in the default order.
pub fn decodableHere() CodecList {
    var l: CodecList = .{};
    for (negotiable) |cd| {
        if (canDecode(cd)) l.add(cd);
    }
    return l;
}

/// What this process can encode, in the default order.
pub fn encodableHere() CodecList {
    var l: CodecList = .{};
    for (negotiable) |cd| {
        if (canEncode(cd)) l.add(cd);
    }
    return l;
}

/// Daemon-side pick for one session: the first codec of the FIRST
/// viewer's list that every viewer can decode and this daemon can
/// encode. Null = stay lossless (no viewer, or no common codec): a
/// tile one viewer cannot decode is a black window there.
pub fn negotiate(viewers: []const CodecList, encodable: CodecList) ?Codec {
    if (viewers.len == 0) return null;
    outer: for (viewers[0].items()) |cd| {
        if (!encodable.contains(cd)) continue;
        for (viewers[1..]) |v| {
            if (!v.contains(cd)) continue :outer;
        }
        return cd;
    }
    return null;
}

/// Codec → the int the avdec shim uses: 0 = H.264, 1 = AV1.
fn shimCodec(codec: Codec) c_int {
    return switch (codec) {
        .av1 => 1,
        else => 0,
    };
}

pub const Error = error{ UnknownCodec, SizeMismatch, Malformed, TooLong, Decode, Unsupported, X264 };

/// Which codec produced a tile's bitstream — tells the receiver which
/// decoder to run, chosen by capability negotiation. Append-only;
/// `stub` is always decodable so it's the universal fallback.
pub const Codec = enum(u8) {
    stub = 0,
    h264 = 1,
    av1 = 2,
    _,
};

// ─── wire framing ───────────────────────────────────────────────
//
// One encoded tile: codec, flags (bit0 = keyframe — self-contained, no
// dependency on a prior frame), the tile's window-space rect, a
// monotonic seq for loss/order detection over UDP, then the opaque
// bitstream. Length-prefixed like the other unit streams so it rides any
// carrier (winstream channel / wayland pipe) and split-resilient peeling
// works the same way.

/// codec(1) + flags(1) + x(4) + y(4) + w(4) + h(4) + seq(4)
pub const header_size = 22;
pub const max_payload = 64 << 20; // a 4K BGRA keyframe worst-case bound

const flag_keyframe: u8 = 1 << 0;

pub const Tile = struct {
    codec: Codec,
    keyframe: bool,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    seq: u32,
    payload: []const u8,
};

/// Append one tile, length-prefixed (u32 total-after-len, then header +
/// payload) so receivers reassemble across carrier-frame splits.
pub fn appendTile(out: *std.ArrayList(u8), a: std.mem.Allocator, tile: Tile) !void {
    const body = header_size + tile.payload.len;
    var hdr: [4 + header_size]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(body), .little);
    hdr[4] = @intFromEnum(tile.codec);
    hdr[5] = if (tile.keyframe) flag_keyframe else 0;
    std.mem.writeInt(i32, hdr[6..10], tile.x, .little);
    std.mem.writeInt(i32, hdr[10..14], tile.y, .little);
    std.mem.writeInt(i32, hdr[14..18], tile.w, .little);
    std.mem.writeInt(i32, hdr[18..22], tile.h, .little);
    std.mem.writeInt(u32, hdr[22..26], tile.seq, .little);
    try out.appendSlice(a, &hdr);
    try out.appendSlice(a, tile.payload);
}

/// Split one tile off the front of `bytes`; null when incomplete.
pub fn peelTile(bytes: []const u8) error{ Malformed, TooLong }!?struct { tile: Tile, consumed: usize } {
    if (bytes.len < 4) return null;
    const body = std.mem.readInt(u32, bytes[0..4], .little);
    if (body < header_size) return error.Malformed;
    if (body - header_size > max_payload) return error.TooLong;
    if (bytes.len < 4 + body) return null;
    const h = bytes[4 .. 4 + header_size];
    return .{
        .tile = .{
            .codec = @enumFromInt(h[0]),
            .keyframe = (h[1] & flag_keyframe) != 0,
            .x = std.mem.readInt(i32, h[2..6], .little),
            .y = std.mem.readInt(i32, h[6..10], .little),
            .w = std.mem.readInt(i32, h[10..14], .little),
            .h = std.mem.readInt(i32, h[14..18], .little),
            .seq = std.mem.readInt(u32, h[18..22], .little),
            .payload = bytes[4 + header_size .. 4 + body],
        },
        .consumed = 4 + body,
    };
}

// ─── encoder ────────────────────────────────────────────────────

pub const EncodeResult = struct { keyframe: bool, bytes: []const u8 };

/// Tagged dispatch the daemon holds; real backends become new variants
/// (collapsing to nothing on builds that don't link them). The interface
/// supports stateful inter-frame coding (`force_keyframe`, per-tile
/// reference state) even though the stub is stateless.
pub const Encoder = union(enum) {
    stub: Stub,
    x264: X264Impl,
    av1: SvtImpl,
    vtoolbox: VtImpl,

    pub fn initStub(allocator: std.mem.Allocator) Encoder {
        return .{ .stub = .{ .allocator = allocator } };
    }

    /// Open a fixed-size encoder for the NEGOTIATED `codec` — the one
    /// entry point the daemon uses, so the codec is a runtime choice.
    /// H.264 prefers libx264 and falls back to VideoToolbox (macOS).
    /// Unsupported when no backend for `codec` is loadable here.
    pub fn init(allocator: std.mem.Allocator, codec_: Codec, w: i32, h: i32, fps: i32) !Encoder {
        if (!canEncode(codec_)) return Error.Unsupported;
        return switch (codec_) {
            .h264 => if (x264Loaded()) initX264(allocator, w, h, fps) else initVtoolbox(allocator, w, h, fps),
            .av1 => initAv1(allocator, w, h, fps),
            else => Error.Unsupported,
        };
    }

    /// Open a fixed-size H.264 encoder for `w`×`h` tiles. Errors with
    /// Unsupported when libx264 is not compiled in or not loadable.
    pub fn initX264(allocator: std.mem.Allocator, w: i32, h: i32, fps: i32) !Encoder {
        if (comptime have_video) {
            if (x264Loaded()) return .{ .x264 = try X264.init(allocator, w, h, fps) };
        }
        return Error.Unsupported;
    }

    /// Open a fixed-size AV1 encoder (SVT-AV1, low delay).
    pub fn initAv1(allocator: std.mem.Allocator, w: i32, h: i32, fps: i32) !Encoder {
        if (comptime have_svt) {
            if (svtLoaded()) return .{ .av1 = try Svt.init(allocator, w, h, fps) };
        }
        return Error.Unsupported;
    }

    /// Open a fixed-size VideoToolbox H.264 encoder (native macOS). Emits
    /// the SAME `.h264` Annex-B wire codec as x264, so any avdec client
    /// decodes it. Unsupported when vtenc isn't linked.
    pub fn initVtoolbox(allocator: std.mem.Allocator, w: i32, h: i32, fps: i32) !Encoder {
        if (comptime have_vtenc) return .{ .vtoolbox = try Vt.init(allocator, w, h, fps) };
        return Error.Unsupported;
    }

    pub fn deinit(self: *Encoder) void {
        switch (self.*) {
            .stub => |*s| s.deinit(),
            .x264 => |*s| if (comptime have_video) s.deinit(),
            .av1 => |*s| if (comptime have_svt) s.deinit(),
            .vtoolbox => |*s| if (comptime have_vtenc) s.deinit(),
        }
    }

    pub fn codec(self: *const Encoder) Codec {
        return switch (self.*) {
            .stub => .stub,
            .x264 => .h264,
            .av1 => .av1,
            .vtoolbox => .h264, // VideoToolbox emits H.264 — same wire codec
        };
    }

    /// Encode one tile of tight BGRA (`w*4` stride, len `w*h*4`).
    /// `force_keyframe` requests a self-contained frame (first encode,
    /// scene change, or loss recovery). The returned bytes ALIAS internal
    /// scratch (or `pixels` for the stub) — valid until the next call.
    pub fn encodeTile(self: *Encoder, w: i32, h: i32, pixels: []const u8, force_keyframe: bool) !EncodeResult {
        return switch (self.*) {
            .stub => |*s| s.encodeTile(w, h, pixels, force_keyframe),
            .x264 => |*s| if (comptime have_video) s.encodeTile(w, h, pixels, force_keyframe) else Error.Unsupported,
            .av1 => |*s| if (comptime have_svt) s.encodeTile(w, h, pixels, force_keyframe) else Error.Unsupported,
            .vtoolbox => |*s| if (comptime have_vtenc) s.encodeTile(w, h, pixels, force_keyframe) else Error.Unsupported,
        };
    }
};

/// libx264 backend via vendor/x264_shim.c. Fixed tile geometry (one
/// encoder per tile size); BGRA→I420 through yuv.zig, then low-latency
/// H.264. Compiled only when build_options.video is set.
const X264 = struct {
    allocator: std.mem.Allocator,
    handle: ?*anyopaque,
    w: i32,
    h: i32,
    yp: []u8,
    up: []u8,
    vp: []u8,
    out: std.ArrayList(u8) = .empty,

    extern fn sk_x264_open(width: c_int, height: c_int, fps: c_int) ?*anyopaque;
    extern fn sk_x264_encode(enc: ?*anyopaque, y: [*]const u8, u: [*]const u8, v: [*]const u8, force_kf: c_int, out: *[*]const u8, is_kf: *c_int) c_int;
    extern fn sk_x264_close(enc: ?*anyopaque) void;

    fn init(allocator: std.mem.Allocator, w: i32, h: i32, fps: i32) !X264 {
        if (w <= 0 or h <= 0 or @rem(w, 2) != 0 or @rem(h, 2) != 0) return Error.SizeMismatch;
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        const handle = sk_x264_open(w, h, fps) orelse return Error.X264;
        errdefer sk_x264_close(handle);
        const yp = try allocator.alloc(u8, yuv.ySize(uw, uh));
        errdefer allocator.free(yp);
        const up = try allocator.alloc(u8, yuv.chromaSize(uw, uh));
        errdefer allocator.free(up);
        const vp = try allocator.alloc(u8, yuv.chromaSize(uw, uh));
        return .{ .allocator = allocator, .handle = handle, .w = w, .h = h, .yp = yp, .up = up, .vp = vp };
    }

    fn deinit(self: *X264) void {
        sk_x264_close(self.handle);
        self.allocator.free(self.yp);
        self.allocator.free(self.up);
        self.allocator.free(self.vp);
        self.out.deinit(self.allocator);
    }

    fn encodeTile(self: *X264, w: i32, h: i32, pixels: []const u8, force_keyframe: bool) !EncodeResult {
        if (w != self.w or h != self.h) return Error.SizeMismatch;
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        if (pixels.len != @as(usize, uw) * uh * 4) return Error.SizeMismatch;
        yuv.bgraToI420(pixels, uw, uh, self.yp, self.up, self.vp);

        var out_ptr: [*]const u8 = undefined;
        var is_kf: c_int = 0;
        const n = sk_x264_encode(self.handle, self.yp.ptr, self.up.ptr, self.vp.ptr, if (force_keyframe) 1 else 0, &out_ptr, &is_kf);
        if (n <= 0) return Error.X264; // zerolatency should never buffer
        self.out.clearRetainingCapacity();
        try self.out.appendSlice(self.allocator, out_ptr[0..@intCast(n)]);
        return .{ .keyframe = is_kf != 0, .bytes = self.out.items };
    }
};

/// VideoToolbox H.264 backend (vendor/vtenc_shim.c) — the macOS-native
/// hardware encoder. Same shape as X264 (BGRA→I420 via yuv.zig, then
/// encode), and emits the SAME Annex-B `.h264` stream the avdec decoder
/// reads. Needs no libx264/libavcodec. Compiled only when
/// build_options.vtenc is set (native macOS).
const Vt = struct {
    allocator: std.mem.Allocator,
    handle: ?*anyopaque,
    w: i32,
    h: i32,
    yp: []u8,
    up: []u8,
    vp: []u8,
    out: std.ArrayList(u8) = .empty,

    extern fn sk_vtenc_open(width: c_int, height: c_int, fps: c_int) ?*anyopaque;
    extern fn sk_vtenc_encode(enc: ?*anyopaque, y: [*]const u8, u: [*]const u8, v: [*]const u8, force_kf: c_int, out: *[*]const u8, is_kf: *c_int) c_int;
    extern fn sk_vtenc_close(enc: ?*anyopaque) void;

    fn init(allocator: std.mem.Allocator, w: i32, h: i32, fps: i32) !Vt {
        if (w <= 0 or h <= 0 or @rem(w, 2) != 0 or @rem(h, 2) != 0) return Error.SizeMismatch;
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        const handle = sk_vtenc_open(w, h, fps) orelse return Error.X264;
        errdefer sk_vtenc_close(handle);
        const yp = try allocator.alloc(u8, yuv.ySize(uw, uh));
        errdefer allocator.free(yp);
        const up = try allocator.alloc(u8, yuv.chromaSize(uw, uh));
        errdefer allocator.free(up);
        const vp = try allocator.alloc(u8, yuv.chromaSize(uw, uh));
        return .{ .allocator = allocator, .handle = handle, .w = w, .h = h, .yp = yp, .up = up, .vp = vp };
    }

    fn deinit(self: *Vt) void {
        sk_vtenc_close(self.handle);
        self.allocator.free(self.yp);
        self.allocator.free(self.up);
        self.allocator.free(self.vp);
        self.out.deinit(self.allocator);
    }

    fn encodeTile(self: *Vt, w: i32, h: i32, pixels: []const u8, force_keyframe: bool) !EncodeResult {
        if (w != self.w or h != self.h) return Error.SizeMismatch;
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        if (pixels.len != @as(usize, uw) * uh * 4) return Error.SizeMismatch;
        yuv.bgraToI420(pixels, uw, uh, self.yp, self.up, self.vp);

        var out_ptr: [*]const u8 = undefined;
        var is_kf: c_int = 0;
        const n = sk_vtenc_encode(self.handle, self.yp.ptr, self.up.ptr, self.vp.ptr, if (force_keyframe) 1 else 0, &out_ptr, &is_kf);
        if (n <= 0) return Error.X264; // RealTime+CompleteFrames never buffers
        self.out.clearRetainingCapacity();
        try self.out.appendSlice(self.allocator, out_ptr[0..@intCast(n)]);
        return .{ .keyframe = is_kf != 0, .bytes = self.out.items };
    }
};

/// SVT-AV1 encoder backend (vendor/svtav1_shim.c), low-delay so a frame
/// in is a packet out. Same shape as X264; BGRA→I420 then encode.
/// Compiled only when build_options.video_av1enc is set.
const Svt = struct {
    allocator: std.mem.Allocator,
    handle: ?*anyopaque,
    w: i32,
    h: i32,
    yp: []u8,
    up: []u8,
    vp: []u8,
    out: std.ArrayList(u8) = .empty,

    extern fn sk_svt_open(width: c_int, height: c_int, fps: c_int) ?*anyopaque;
    extern fn sk_svt_encode(enc: ?*anyopaque, y: [*]const u8, u: [*]const u8, v: [*]const u8, force_kf: c_int, out: *[*]const u8, is_kf: *c_int) c_int;
    extern fn sk_svt_close(enc: ?*anyopaque) void;

    fn init(allocator: std.mem.Allocator, w: i32, h: i32, fps: i32) !Svt {
        if (w <= 0 or h <= 0 or @rem(w, 2) != 0 or @rem(h, 2) != 0) return Error.SizeMismatch;
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        const handle = sk_svt_open(w, h, fps) orelse return Error.X264;
        errdefer sk_svt_close(handle);
        const yp = try allocator.alloc(u8, yuv.ySize(uw, uh));
        errdefer allocator.free(yp);
        const up = try allocator.alloc(u8, yuv.chromaSize(uw, uh));
        errdefer allocator.free(up);
        const vp = try allocator.alloc(u8, yuv.chromaSize(uw, uh));
        return .{ .allocator = allocator, .handle = handle, .w = w, .h = h, .yp = yp, .up = up, .vp = vp };
    }

    fn deinit(self: *Svt) void {
        sk_svt_close(self.handle);
        self.allocator.free(self.yp);
        self.allocator.free(self.up);
        self.allocator.free(self.vp);
        self.out.deinit(self.allocator);
    }

    fn encodeTile(self: *Svt, w: i32, h: i32, pixels: []const u8, force_keyframe: bool) !EncodeResult {
        if (w != self.w or h != self.h) return Error.SizeMismatch;
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        if (pixels.len != @as(usize, uw) * uh * 4) return Error.SizeMismatch;
        yuv.bgraToI420(pixels, uw, uh, self.yp, self.up, self.vp);

        var out_ptr: [*]const u8 = undefined;
        var is_kf: c_int = 0;
        const n = sk_svt_encode(self.handle, self.yp.ptr, self.up.ptr, self.vp.ptr, if (force_keyframe) 1 else 0, &out_ptr, &is_kf);
        if (n <= 0) return Error.X264; // 0 = no packet (low-delay get_packet blocks, so shouldn't happen)
        self.out.clearRetainingCapacity();
        try self.out.appendSlice(self.allocator, out_ptr[0..@intCast(n)]);
        return .{ .keyframe = is_kf != 0, .bytes = self.out.items };
    }
};

/// Raw passthrough: payload IS the BGRA, every tile a keyframe. Exists
/// so the transport/decode/composite pipeline is exercised end-to-end
/// without a codec — exactly the role winstream's Stub source plays.
pub const Stub = struct {
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Stub) void {
        _ = self;
    }

    pub fn encodeTile(self: *Stub, w: i32, h: i32, pixels: []const u8, force_keyframe: bool) !EncodeResult {
        _ = self;
        _ = force_keyframe; // raw is always self-contained
        if (w <= 0 or h <= 0) return Error.SizeMismatch;
        const need = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
        if (pixels.len != need) return Error.SizeMismatch;
        return .{ .keyframe = true, .bytes = pixels };
    }
};

// ─── decoder ────────────────────────────────────────────────────

pub const Decoder = union(enum) {
    stub: Stub_,
    avcodec: AvDecImpl,

    pub fn initStub(allocator: std.mem.Allocator) Decoder {
        return .{ .stub = .{ .allocator = allocator } };
    }

    /// Open a fixed-size software decoder (libavcodec) for `w`×`h` tiles
    /// of `codec` (.h264 or .av1). Errors Unsupported without -Dvideo or
    /// when libavcodec (or its decoder for `codec`) is not loadable here.
    pub fn initAvcodec(allocator: std.mem.Allocator, w: i32, h: i32, codec: Codec) !Decoder {
        if (comptime have_video) {
            if (canDecode(codec)) return .{ .avcodec = try AvDec.init(allocator, w, h, codec) };
        }
        return Error.Unsupported;
    }

    pub fn deinit(self: *Decoder) void {
        switch (self.*) {
            .stub => |*s| s.deinit(),
            .avcodec => |*s| if (comptime have_video) s.deinit(),
        }
    }

    /// Decode `tile`'s bitstream into `dst`, which MUST be `w*h*4`.
    pub fn decodeTile(self: *Decoder, tile: Tile, dst: []u8) Error!void {
        return switch (self.*) {
            .stub => |*s| s.decodeTile(tile, dst),
            .avcodec => |*s| if (comptime have_video) s.decodeTile(tile, dst) else Error.Unsupported,
        };
    }

    /// The Stub decoder accepts only `stub`-coded tiles; real decoders
    /// are added as variants and chosen to match the negotiated codec.
    pub const Stub_ = struct {
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Stub_) void {
            _ = self;
        }

        pub fn decodeTile(self: *Stub_, tile: Tile, dst: []u8) Error!void {
            _ = self;
            if (tile.codec != .stub) return Error.UnknownCodec;
            if (tile.w <= 0 or tile.h <= 0) return Error.SizeMismatch;
            const need = @as(usize, @intCast(tile.w)) * @as(usize, @intCast(tile.h)) * 4;
            if (dst.len != need or tile.payload.len != need) return Error.SizeMismatch;
            @memcpy(dst, tile.payload);
        }
    };
};

/// libavcodec software decoder (H.264 or AV1) via vendor/avdec_shim.c.
/// Fixed tile geometry; decodes a tile to I420 then yuv.zig → BGRA. The
/// daemon never instantiates this (it encodes); it's the GUI/compositor
/// receive path. Compiled only when build_options.video is set.
const AvDec = struct {
    allocator: std.mem.Allocator,
    handle: ?*anyopaque,
    codec: Codec,
    w: i32,
    h: i32,
    yp: []u8,
    up: []u8,
    vp: []u8,

    extern fn sk_avdec_open(which: c_int) ?*anyopaque;
    extern fn sk_avdec_decode(dec: ?*anyopaque, data: [*]const u8, len: c_int, exp_w: c_int, exp_h: c_int, y: [*]u8, u: [*]u8, v: [*]u8) c_int;
    extern fn sk_avdec_close(dec: ?*anyopaque) void;

    fn init(allocator: std.mem.Allocator, w: i32, h: i32, codec: Codec) !AvDec {
        if (w <= 0 or h <= 0 or @rem(w, 2) != 0 or @rem(h, 2) != 0) return Error.SizeMismatch;
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        const handle = sk_avdec_open(shimCodec(codec)) orelse return Error.Decode;
        errdefer sk_avdec_close(handle);
        const yp = try allocator.alloc(u8, yuv.ySize(uw, uh));
        errdefer allocator.free(yp);
        const up = try allocator.alloc(u8, yuv.chromaSize(uw, uh));
        errdefer allocator.free(up);
        const vp = try allocator.alloc(u8, yuv.chromaSize(uw, uh));
        return .{ .allocator = allocator, .handle = handle, .codec = codec, .w = w, .h = h, .yp = yp, .up = up, .vp = vp };
    }

    fn deinit(self: *AvDec) void {
        sk_avdec_close(self.handle);
        self.allocator.free(self.yp);
        self.allocator.free(self.up);
        self.allocator.free(self.vp);
    }

    fn decodeTile(self: *AvDec, tile: Tile, dst: []u8) Error!void {
        if (tile.codec != self.codec) return Error.UnknownCodec;
        if (tile.w != self.w or tile.h != self.h) return Error.SizeMismatch;
        const uw: u32 = @intCast(self.w);
        const uh: u32 = @intCast(self.h);
        if (dst.len != @as(usize, uw) * uh * 4) return Error.SizeMismatch;
        const n = sk_avdec_decode(self.handle, tile.payload.ptr, @intCast(tile.payload.len), self.w, self.h, self.yp.ptr, self.up.ptr, self.vp.ptr);
        if (n != 1) return Error.Decode; // 0 = no frame yet, <0 = error
        yuv.i420ToBgra(self.yp, self.up, self.vp, uw, uh, dst);
    }
};

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

/// Side of the square tile every backend test encodes.
const TILE = 64;
const TilePixels = [TILE * TILE * 4]u8;

/// A smooth grayscale gradient: neutral chroma and low frequency, so a
/// lossy 4:2:0 round-trip stays close and a range/matrix mismatch (full
/// vs video) blows the MAE bound instead of hiding in the noise.
fn grayGradient(px: *TilePixels) void {
    for (0..TILE) |yy| for (0..TILE) |xx| {
        const o = (yy * TILE + xx) * 4;
        const v: u8 = @truncate(40 + xx + yy);
        px[o] = v;
        px[o + 1] = v;
        px[o + 2] = v;
        px[o + 3] = 0xff;
    };
}

/// A per-channel ramp, for the encode-only tests that never compare pixels.
fn colorRamp(px: *TilePixels) void {
    for (0..TILE) |yy| for (0..TILE) |xx| {
        const o = (yy * TILE + xx) * 4;
        px[o + 0] = @truncate(xx * 3);
        px[o + 1] = @truncate(yy * 3);
        px[o + 2] = @truncate((xx + yy) * 2);
        px[o + 3] = 0xff;
    };
}

/// Mean absolute error over RGB between a source tile and a decoded one,
/// asserting on the way that the decode forced alpha opaque when
/// `require_opaque` (the AV1 case deliberately does not check it).
fn rgbMae(src: *const TilePixels, dst: *const TilePixels, comptime require_opaque: bool) !f64 {
    var sum: u64 = 0;
    for (0..TILE * TILE) |i| {
        inline for (.{ 0, 1, 2 }) |ch| {
            const dv: i32 = @as(i32, src[i * 4 + ch]) - @as(i32, dst[i * 4 + ch]);
            sum += @abs(dv);
        }
        if (require_opaque) try t.expectEqual(@as(u8, 0xff), dst[i * 4 + 3]);
    }
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(TILE * TILE * 3));
}

/// The wire tile a whole-frame encode of `TILE` x `TILE` produces.
fn wholeTile(codec: Codec, r: EncodeResult) Tile {
    return .{
        .codec = codec,
        .keyframe = r.keyframe,
        .x = 0,
        .y = 0,
        .w = TILE,
        .h = TILE,
        .seq = 0,
        .payload = r.bytes,
    };
}

test "tile wire round-trips and peels across split points" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    var px: [4 * 2 * 4]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = @intCast(i);
    try appendTile(&out, a, .{ .codec = .stub, .keyframe = true, .x = 10, .y = 20, .w = 4, .h = 2, .seq = 7, .payload = &px });

    // Partial buffers peel to null, never error, up to the full unit.
    var cut: usize = 0;
    while (cut < out.items.len) : (cut += 1) {
        try t.expect((try peelTile(out.items[0..cut])) == null);
    }
    const p = (try peelTile(out.items)).?;
    try t.expectEqual(out.items.len, p.consumed);
    try t.expectEqual(Codec.stub, p.tile.codec);
    try t.expect(p.tile.keyframe);
    try t.expectEqual(@as(i32, 10), p.tile.x);
    try t.expectEqual(@as(i32, 2), p.tile.h);
    try t.expectEqual(@as(u32, 7), p.tile.seq);
    try t.expectEqualSlices(u8, &px, p.tile.payload);
}

test "malformed and over-long headers are rejected" {
    // body < header_size.
    const bad = [_]u8{ 5, 0, 0, 0, 0 };
    try t.expectError(error.Malformed, peelTile(&bad));
    // body claims an absurd payload.
    var big: [4]u8 = undefined;
    std.mem.writeInt(u32, &big, header_size + max_payload + 1, .little);
    try t.expectError(error.TooLong, peelTile(&big));
}

test "stub encode → wire → stub decode reproduces the tile" {
    const a = t.allocator;
    var enc = Encoder.initStub(a);
    defer enc.deinit();
    var dec = Decoder.initStub(a);
    defer dec.deinit();

    const w = 8;
    const h = 5;
    var px: [w * h * 4]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = @truncate(i * 7 + 3);

    const r = try enc.encodeTile(w, h, &px, false);
    try t.expect(r.keyframe); // stub is always self-contained

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendTile(&out, a, .{ .codec = enc.codec(), .keyframe = r.keyframe, .x = 0, .y = 0, .w = w, .h = h, .seq = 1, .payload = r.bytes });

    const p = (try peelTile(out.items)).?;
    var dst: [w * h * 4]u8 = undefined;
    try dec.decodeTile(p.tile, &dst);
    try t.expectEqualSlices(u8, &px, &dst);
}

test "decoder rejects wrong codec and mismatched sizes" {
    const a = t.allocator;
    var dec = Decoder.initStub(a);
    defer dec.deinit();
    var dst: [16]u8 = undefined;

    var px: [16]u8 = undefined;
    try dec.decodeTile(.{ .codec = .stub, .keyframe = true, .x = 0, .y = 0, .w = 2, .h = 2, .seq = 0, .payload = &px }, &dst); // ok

    try t.expectError(Error.UnknownCodec, dec.decodeTile(.{ .codec = .h264, .keyframe = true, .x = 0, .y = 0, .w = 2, .h = 2, .seq = 0, .payload = &px }, &dst));
    var small: [4]u8 = undefined;
    try t.expectError(Error.SizeMismatch, dec.decodeTile(.{ .codec = .stub, .keyframe = true, .x = 0, .y = 0, .w = 2, .h = 2, .seq = 0, .payload = &px }, &small));
}

test "stub encoder rejects a pixel buffer that isn't w*h*4" {
    const a = t.allocator;
    var enc = Encoder.initStub(a);
    defer enc.deinit();
    var px: [10]u8 = undefined;
    try t.expectError(Error.SizeMismatch, enc.encodeTile(2, 2, &px, true)); // needs 16
}

test "x264 backend encodes a keyframe Annex-B stream (when libx264 loads)" {
    if (!x264Loaded()) return error.SkipZigTest;
    var enc = try Encoder.initX264(t.allocator, TILE, TILE, 30);
    defer enc.deinit();
    try t.expectEqual(Codec.h264, enc.codec());

    var px: TilePixels = undefined;
    colorRamp(&px);
    const r = try enc.encodeTile(TILE, TILE, &px, true);
    try t.expect(r.keyframe);
    // Real Annex-B H.264 begins with a start code (00 00 00 01 / 00 00 01).
    try t.expect(r.bytes.len >= 4);
    try t.expectEqual(@as(u8, 0), r.bytes[0]);
    try t.expectEqual(@as(u8, 0), r.bytes[1]);
    // A second frame (non-forced) still encodes without error.
    const r2 = try enc.encodeTile(TILE, TILE, &px, false);
    try t.expect(r2.bytes.len > 0);

    // Wrong tile size is rejected.
    try t.expectError(Error.SizeMismatch, enc.encodeTile(32, 32, &px, false));
}

test "x264 encode → avcodec decode round-trips a frame (when both load)" {
    if (!x264Loaded() or !canDecode(.h264)) return error.SkipZigTest;
    var enc = try Encoder.initX264(t.allocator, TILE, TILE, 30);
    defer enc.deinit();
    var dec = try Decoder.initAvcodec(t.allocator, TILE, TILE, .h264);
    defer dec.deinit();
    try t.expectEqual(Codec.h264, enc.codec());

    var px: TilePixels = undefined;
    grayGradient(&px);
    const r = try enc.encodeTile(TILE, TILE, &px, true);
    try t.expect(r.keyframe);

    var dst: TilePixels = undefined;
    try dec.decodeTile(wholeTile(enc.codec(), r), &dst);

    // Lossy → compare by mean absolute error over RGB; alpha forced opaque.
    try t.expect(try rgbMae(&px, &dst, true) < 15.0);
}

test "VideoToolbox backend encodes an Annex-B H.264 keyframe (when vtenc linked)" {
    if (!have_vtenc) return error.SkipZigTest;
    var enc = try Encoder.initVtoolbox(t.allocator, TILE, TILE, 30);
    defer enc.deinit();
    try t.expectEqual(Codec.h264, enc.codec());

    var px: TilePixels = undefined;
    colorRamp(&px);
    const r = try enc.encodeTile(TILE, TILE, &px, true);
    try t.expect(r.keyframe);
    // Annex-B: a start code (00 00 00 01) leads the stream.
    try t.expect(r.bytes.len >= 4);
    try t.expectEqual(@as(u8, 0), r.bytes[0]);
    try t.expectEqual(@as(u8, 0), r.bytes[1]);
    try t.expectEqual(@as(u8, 0), r.bytes[2]);
    try t.expectEqual(@as(u8, 1), r.bytes[3]);
    // A follow-up frame still encodes without error.
    const r2 = try enc.encodeTile(TILE, TILE, &px, false);
    try t.expect(r2.bytes.len > 0);
    // Wrong tile size is rejected.
    try t.expectError(Error.SizeMismatch, enc.encodeTile(32, 32, &px, false));
}

test "VideoToolbox encode → avcodec decode round-trips a frame (vtenc + -Dvideo)" {
    if (!have_vtenc or !have_video) return error.SkipZigTest;
    var enc = try Encoder.initVtoolbox(t.allocator, TILE, TILE, 30);
    defer enc.deinit();
    var dec = try Decoder.initAvcodec(t.allocator, TILE, TILE, .h264);
    defer dec.deinit();
    try t.expectEqual(Codec.h264, enc.codec());

    var px: TilePixels = undefined;
    grayGradient(&px);
    const r = try enc.encodeTile(TILE, TILE, &px, true);
    try t.expect(r.keyframe);

    var dst: TilePixels = undefined;
    try dec.decodeTile(wholeTile(enc.codec(), r), &dst);
    try t.expect(try rgbMae(&px, &dst, true) < 15.0);
}

test "AV1 (SVT-AV1) encode → avcodec decode round-trips frames (when both load)" {
    if (!canEncode(.av1) or !canDecode(.av1)) return error.SkipZigTest;
    var enc = try Encoder.initAv1(t.allocator, TILE, TILE, 30);
    defer enc.deinit();
    var dec = try Decoder.initAvcodec(t.allocator, TILE, TILE, .av1);
    defer dec.deinit();
    try t.expectEqual(Codec.av1, enc.codec());

    var px: TilePixels = undefined;
    grayGradient(&px);
    const r = try enc.encodeTile(TILE, TILE, &px, true);
    try t.expect(r.keyframe);

    var dst: TilePixels = undefined;
    try dec.decodeTile(wholeTile(enc.codec(), r), &dst);
    // AV1 4:2:0 lossy; grayscale stays close.
    try t.expect(try rgbMae(&px, &dst, false) < 20.0);

    // Inter frames: low delay means every frame in is a packet out, and
    // each decodes immediately (the tile stream has no reorder buffer).
    for (0..4) |i| {
        for (&px) |*b| b.* +%= @intCast(i + 1);
        const ri = try enc.encodeTile(TILE, TILE, &px, false);
        try t.expect(ri.bytes.len > 0);
        try dec.decodeTile(wholeTile(enc.codec(), ri), &dst);
    }
}

test "Encoder.init picks the backend of the negotiated codec" {
    try t.expectError(Error.Unsupported, Encoder.init(t.allocator, .stub, TILE, TILE, 30));
    inline for (negotiable) |cd| {
        if (canEncode(cd)) {
            var enc = try Encoder.init(t.allocator, cd, TILE, TILE, 30);
            defer enc.deinit();
            try t.expectEqual(cd, enc.codec());
        } else {
            try t.expectError(Error.Unsupported, Encoder.init(t.allocator, cd, TILE, TILE, 30));
        }
    }
}

fn listOf(codecs: []const Codec) CodecList {
    var l: CodecList = .{};
    for (codecs) |cd| l.add(cd);
    return l;
}

test "an old viewer's video bool negotiates H.264 and never AV1" {
    const both = listOf(&.{ .av1, .h264 });
    // A pre-negotiation GUI that sent `video: true` gets x264 even from
    // a daemon that could (and a new viewer would) prefer AV1.
    try t.expectEqual(@as(?Codec, .h264), negotiate(&.{CodecList.fromLegacy(true)}, both));
    try t.expectEqual(@as(?Codec, null), negotiate(&.{CodecList.fromLegacy(false)}, both));
    // A daemon without x264 has nothing an old viewer can decode.
    try t.expectEqual(@as(?Codec, null), negotiate(&.{CodecList.fromLegacy(true)}, listOf(&.{.av1})));
}

test "negotiate honours the first viewer's order within the common set" {
    const enc = listOf(&.{ .h264, .av1 });
    try t.expectEqual(@as(?Codec, .av1), negotiate(&.{listOf(&.{ .av1, .h264 })}, enc));
    try t.expectEqual(@as(?Codec, .h264), negotiate(&.{listOf(&.{ .h264, .av1 })}, enc));
    // Every viewer must decode the pick: an old (h264-only) viewer
    // joining an AV1-preferring one moves the session to H.264.
    try t.expectEqual(@as(?Codec, .h264), negotiate(&.{ listOf(&.{ .av1, .h264 }), CodecList.fromLegacy(true) }, enc));
    // No common codec → lossless.
    try t.expectEqual(@as(?Codec, null), negotiate(&.{ listOf(&.{.av1}), listOf(&.{.h264}) }, enc));
    // Daemon cannot encode the viewer's only codec → lossless.
    try t.expectEqual(@as(?Codec, null), negotiate(&.{listOf(&.{.av1})}, listOf(&.{.h264})));
    try t.expectEqual(@as(?Codec, null), negotiate(&.{}, enc));
}

test "codec lists parse names, skip unknowns and round-trip the handoff bytes" {
    const names_in = [_][]const u8{ "vp9", "av1", "stub", "h264", "av1" };
    const l = CodecList.fromNames(&names_in);
    try t.expectEqualSlices(Codec, &.{ .av1, .h264 }, l.items());
    var nb: [CodecList.cap][]const u8 = undefined;
    const out = l.names(&nb);
    try t.expectEqual(@as(usize, 2), out.len);
    try t.expectEqualStrings("av1", out[0]);
    const bytes = l.encode();
    try t.expectEqualSlices(Codec, l.items(), CodecList.decode(&bytes).items());
    // Truncated / garbage-tolerant.
    try t.expectEqual(@as(u8, 0), CodecList.decode(&.{}).len);
    try t.expectEqual(@as(u8, 1), CodecList.decode(&.{ 5, 2 }).len);
    try t.expectEqual(@as(u8, 0), CodecList.decode(&.{ 1, 0 }).len); // stub is never negotiable
}

test "offer applies the user's preference to what this viewer decodes" {
    const both = listOf(&.{ .h264, .av1 });
    try t.expectEqualSlices(Codec, &.{ .h264, .av1 }, offer(.auto, both).items());
    try t.expectEqualSlices(Codec, &.{ .av1, .h264 }, offer(.av1, both).items());
    try t.expectEqualSlices(Codec, &.{ .h264, .av1 }, offer(.h264, both).items());
    try t.expectEqual(@as(u8, 0), offer(.lossless, both).len);
    // Preferring a codec this viewer cannot decode never offers it.
    try t.expectEqualSlices(Codec, &.{.h264}, offer(.av1, listOf(&.{.h264})).items());
}
