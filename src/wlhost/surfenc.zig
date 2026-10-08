//! Per-surface encoder: the ONE home of the video-vs-lossless route for
//! a remote pixel surface (a forwarded Wayland surface in the daemon's
//! `Native.videoCommit`, a captured macOS window in winstream/sck.zig).
//!
//! A `Surface` holds a churn tracker (util/churn.zig), a lazily opened
//! vcodec encoder, the codec it was opened for, a latch for a codec whose
//! open failed, the pending-keyframe flag and the tile seq. A frame goes
//! out as ONE whole-surface video tile only when the surface is hot AND
//! photographic (util/content.zig) AND a codec is available AND both
//! dims are even; everything else is the caller's lossless route, for
//! which `Lossless` encodes damaged rects through pixcodec.
//!
//! How an encoder is opened is the caller's `Opener` (the negotiated
//! codec through `vcodec.Encoder.init`, or VideoToolbox on macOS), so
//! the state machine never forks per backend. Daemon-safe: libc only,
//! every codec library stays behind vcodec's dlopen.

const std = @import("std");
const vcodec = @import("vcodec.zig");
const pixcodec = @import("pixcodec.zig");
const churn = @import("../util/churn.zig");
const content = @import("../util/content.zig");

/// Frame rate every surface encoder is opened with.
pub const fps: i32 = 30;

/// Opens a fixed-size encoder for `codec`; an error latches `codec` as
/// failed for this surface until its size changes.
pub const Opener = *const fn (allocator: std.mem.Allocator, codec: vcodec.Codec, w: i32, h: i32, fps: i32) anyerror!vcodec.Encoder;

/// The negotiated codec's backend (`vcodec.Encoder.init`).
pub fn openNegotiated(allocator: std.mem.Allocator, codec: vcodec.Codec, w: i32, h: i32, fps_: i32) anyerror!vcodec.Encoder {
    return vcodec.Encoder.init(allocator, codec, w, h, fps_);
}

/// VideoToolbox H.264 regardless of `codec` (native macOS capture only
/// ever streams H.264).
pub fn openVtoolbox(allocator: std.mem.Allocator, codec: vcodec.Codec, w: i32, h: i32, fps_: i32) anyerror!vcodec.Encoder {
    _ = codec;
    return vcodec.Encoder.initVtoolbox(allocator, w, h, fps_);
}

/// Whether a `w`x`h` surface can be video-coded at all (both codecs need
/// even, non-empty dims).
pub fn sizeOk(w: i32, h: i32) bool {
    return w > 0 and h > 0 and @rem(w, 2) == 0 and @rem(h, 2) == 0;
}

pub const Verdict = union(enum) {
    /// Not video this frame: the caller sends it lossless.
    lossless,
    /// Exactly one tile was appended to the caller's buffer.
    video: struct {
        keyframe: bool,
        /// The encoder was (re)opened for this frame.
        opened: bool,
    },
    /// Opening the encoder for `codec` failed (now latched); lossless.
    open_failed: struct { codec: vcodec.Codec, err: anyerror },
};

pub const Surface = struct {
    allocator: std.mem.Allocator,
    open: Opener,
    churn: churn.Tracker,
    enc: ?vcodec.Encoder = null,
    /// The codec `enc` was opened FOR, which is what a codec switch is
    /// judged against (the stub encoder reports `.stub` for any request).
    enc_codec: vcodec.Codec = .stub,
    /// The codec an open FAILED for at this size (e.g. below an encoder's
    /// minimum), so an expensive open is not retried on every frame.
    failed: ?vcodec.Codec = null,
    w: i32,
    h: i32,
    seq: u32 = 0,
    needs_kf: bool = true,

    pub fn init(allocator: std.mem.Allocator, open: Opener, w: i32, h: i32) !Surface {
        const tracker = try churn.Tracker.init(allocator, @intCast(@max(w, 0)), @intCast(@max(h, 0)), .{});
        return .{ .allocator = allocator, .open = open, .churn = tracker, .w = w, .h = h };
    }

    pub fn deinit(self: *Surface) void {
        self.churn.deinit();
        if (self.enc) |*e| e.deinit();
        self.* = undefined;
    }

    pub fn noteDamage(self: *Surface, x: i32, y: i32, w: i32, h: i32) void {
        self.churn.noteDamage(x, y, w, h);
    }

    pub fn endFrame(self: *Surface) void {
        self.churn.endFrame();
    }

    /// The next tile must be self-contained (a viewer reattached, or a
    /// previous tile never reached the viewers).
    pub fn forceKeyframe(self: *Surface) void {
        self.needs_kf = true;
    }

    /// Cheap pre-check before the caller gathers whole-surface pixels:
    /// a codec is available, the dims are codable and the surface is hot.
    pub fn wantsPixels(self: *const Surface, codec: ?vcodec.Codec) bool {
        if (codec == null or !sizeOk(self.w, self.h)) return false;
        return self.churn.hot(0, 0, self.w, self.h);
    }

    /// Route this frame: append ONE whole-surface tile of `codec` to `out`
    /// when `pixels` (tight BGRA, `w*h*4`) look photographic and an
    /// encoder is available, else leave `out` untouched.
    pub fn encode(self: *Surface, out: *std.ArrayList(u8), codec: vcodec.Codec, pixels: []const u8) Verdict {
        if (!content.looksPhotographic(pixels, .{})) return .lossless;

        // The codec moved (a viewer joined or left): reopen, and the new
        // stream starts with a keyframe.
        if (self.enc) |*e| {
            if (self.enc_codec != codec) {
                e.deinit();
                self.enc = null;
            }
        }
        var opened = false;
        if (self.enc == null) {
            if (self.failed == codec) return .lossless;
            self.enc = self.open(self.allocator, codec, self.w, self.h, fps) catch |err| {
                self.failed = codec;
                return .{ .open_failed = .{ .codec = codec, .err = err } };
            };
            self.enc_codec = codec;
            self.needs_kf = true;
            opened = true;
        }
        const enc = &self.enc.?;

        const res = enc.encodeTile(self.w, self.h, pixels, self.needs_kf) catch return .lossless;
        self.needs_kf = false;

        const mark = out.items.len;
        vcodec.appendTile(out, self.allocator, .{
            .codec = enc.codec(),
            .keyframe = res.keyframe,
            .x = 0,
            .y = 0,
            .w = self.w,
            .h = self.h,
            .seq = self.seq,
            .payload = res.bytes,
        }) catch {
            out.shrinkRetainingCapacity(mark);
            return .lossless;
        };
        self.seq +%= 1;
        return .{ .video = .{ .keyframe = res.keyframe, .opened = opened } };
    }
};

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Lossless route for damaged rects: each rect is packed tight (`w*4`
/// stride) and run through pixcodec, reusing one scratch.
pub const Lossless = struct {
    sc: pixcodec.Scratch = .{},
    tight: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Lossless, a: std.mem.Allocator) void {
        self.sc.deinit(a);
        self.tight.deinit(a);
    }

    /// Encode `rect` of a BGRA surface whose rows are `stride` bytes apart;
    /// the body decodes to `rect.w*4` stride. The result aliases this
    /// scratch until the next call.
    /// @throws error.OutOfBounds when `rect` is empty or leaves `pixels`.
    pub fn encodeRect(self: *Lossless, a: std.mem.Allocator, pixels: []const u8, stride: usize, rect: Rect) !pixcodec.Encoded {
        if (rect.x < 0 or rect.y < 0 or rect.w <= 0 or rect.h <= 0) return error.OutOfBounds;
        const x: usize = @intCast(rect.x);
        const y: usize = @intCast(rect.y);
        const row: usize = @as(usize, @intCast(rect.w)) * 4;
        const rows: usize = @intCast(rect.h);
        if (x * 4 + row > stride or (y + rows - 1) * stride + x * 4 + row > pixels.len) return error.OutOfBounds;
        try self.tight.resize(a, row * rows);
        for (0..rows) |r| {
            @memcpy(self.tight.items[r * row ..][0..row], pixels[(y + r) * stride + x * 4 ..][0..row]);
        }
        return pixcodec.encodeOrRaw(&self.sc, a, self.tight.items, row);
    }
};

// --- tests ---------------------------------------------------------

const t = std.testing;

fn openStub(allocator: std.mem.Allocator, codec: vcodec.Codec, w: i32, h: i32, fps_: i32) anyerror!vcodec.Encoder {
    _ = .{ codec, w, h, fps_ };
    return vcodec.Encoder.initStub(allocator);
}

var av1_opens: u32 = 0;

/// Stub for every codec except AV1, whose open always fails.
fn openNoAv1(allocator: std.mem.Allocator, codec: vcodec.Codec, w: i32, h: i32, fps_: i32) anyerror!vcodec.Encoder {
    if (codec == .av1) {
        av1_opens += 1;
        return error.Unsupported;
    }
    return openStub(allocator, codec, w, h, fps_);
}

const W = 64;
const H = 64;

fn photo(px: *[W * H * 4]u8) void {
    var st: u32 = 0x1234567;
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        st = st *% 1664525 +% 1013904223;
        px[i + 0] = @truncate(st >> 24);
        px[i + 1] = @truncate(st >> 16);
        px[i + 2] = @truncate(st >> 8);
        px[i + 3] = 0xff;
    }
}

fn heat(s: *Surface, frames: usize) void {
    for (0..frames) |_| {
        s.noteDamage(0, 0, s.w, s.h);
        s.endFrame();
    }
}

fn onlyTile(out: []const u8) !vcodec.Tile {
    const p = (try vcodec.peelTile(out)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(out.len, p.consumed);
    return p.tile;
}

test "a cold surface stays lossless" {
    var s = try Surface.init(t.allocator, openStub, W, H);
    defer s.deinit();
    heat(&s, 3); // one frame short of hot
    try t.expect(!s.wantsPixels(.h264));
    try t.expect(s.enc == null);
}

test "a hot photographic surface sends a keyframe tile, then deltas" {
    var s = try Surface.init(t.allocator, openStub, W, H);
    defer s.deinit();
    var px: [W * H * 4]u8 = undefined;
    photo(&px);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);

    heat(&s, 4);
    try t.expect(s.wantsPixels(.h264));
    try t.expect(!s.wantsPixels(null));
    const v1 = s.encode(&out, .h264, &px);
    try t.expect(v1.video.opened);
    var tile = try onlyTile(out.items);
    try t.expectEqual(@as(u32, 0), tile.seq);
    try t.expectEqual(@as(i32, W), tile.w);
    try t.expect(!s.needs_kf);

    out.clearRetainingCapacity();
    const v2 = s.encode(&out, .h264, &px);
    try t.expect(!v2.video.opened);
    tile = try onlyTile(out.items);
    try t.expectEqual(@as(u32, 1), tile.seq);
    try t.expect(!s.needs_kf);
}

test "a flat hot surface stays lossless and opens no encoder" {
    var s = try Surface.init(t.allocator, openStub, W, H);
    defer s.deinit();
    var px: [W * H * 4]u8 = undefined;
    @memset(&px, 0x20);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    heat(&s, 8);
    try t.expect(s.wantsPixels(.h264));
    try t.expectEqual(Verdict.lossless, s.encode(&out, .h264, &px));
    try t.expectEqual(@as(usize, 0), out.items.len);
    try t.expect(s.enc == null);
}

test "odd dims never want pixels" {
    var s = try Surface.init(t.allocator, openStub, W + 1, H);
    defer s.deinit();
    heat(&s, 8);
    try t.expect(!s.wantsPixels(.h264));
    try t.expect(!sizeOk(0, 2));
    try t.expect(sizeOk(2, 2));
}

test "a codec switch reopens the encoder and forces a keyframe" {
    var s = try Surface.init(t.allocator, openStub, W, H);
    defer s.deinit();
    var px: [W * H * 4]u8 = undefined;
    photo(&px);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    heat(&s, 4);
    _ = s.encode(&out, .h264, &px);
    _ = s.encode(&out, .h264, &px);
    try t.expect(!s.needs_kf);
    out.clearRetainingCapacity();
    const v = s.encode(&out, .av1, &px);
    try t.expect(v.video.opened);
    try t.expectEqual(vcodec.Codec.av1, s.enc_codec);
    // The seq keeps counting across the reopen.
    try t.expectEqual(@as(u32, 2), (try onlyTile(out.items)).seq);
}

test "a failed codec is latched and not reopened every frame" {
    av1_opens = 0;
    var s = try Surface.init(t.allocator, openNoAv1, W, H);
    defer s.deinit();
    var px: [W * H * 4]u8 = undefined;
    photo(&px);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    heat(&s, 4);
    const v = s.encode(&out, .av1, &px);
    try t.expectEqual(vcodec.Codec.av1, v.open_failed.codec);
    try t.expectEqual(Verdict.lossless, s.encode(&out, .av1, &px));
    try t.expectEqual(@as(u32, 1), av1_opens);
    try t.expectEqual(@as(usize, 0), out.items.len);
    // Another codec still opens.
    try t.expect(s.encode(&out, .h264, &px).video.opened);
}

test "forceKeyframe requests a keyframe on the next tile" {
    var s = try Surface.init(t.allocator, openStub, W, H);
    defer s.deinit();
    var px: [W * H * 4]u8 = undefined;
    photo(&px);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    heat(&s, 4);
    _ = s.encode(&out, .h264, &px);
    try t.expect(!s.needs_kf);
    s.forceKeyframe();
    try t.expect(s.needs_kf);
    _ = s.encode(&out, .h264, &px);
    try t.expect(!s.needs_kf);
}

test "Lossless.encodeRect packs a sub-rect tight and round-trips" {
    var px: [W * H * 4]u8 = undefined;
    photo(&px);
    var l: Lossless = .{};
    defer l.deinit(t.allocator);
    const r: Rect = .{ .x = 3, .y = 5, .w = 10, .h = 7 };
    const enc = try l.encodeRect(t.allocator, &px, W * 4, r);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(t.allocator);
    try pixcodec.appendBody(&body, t.allocator, enc, 10 * 7 * 4, 10 * 4);
    var dst: [10 * 7 * 4]u8 = undefined;
    try pixcodec.decodeBody(pixcodec.peelBody(body.items).?, &dst);
    for (0..7) |row| {
        try t.expectEqualSlices(u8, px[(5 + row) * W * 4 + 3 * 4 ..][0 .. 10 * 4], dst[row * 40 ..][0..40]);
    }
    try t.expectError(error.OutOfBounds, l.encodeRect(t.allocator, &px, W * 4, .{ .x = 60, .y = 0, .w = 8, .h = 1 }));
    try t.expectError(error.OutOfBounds, l.encodeRect(t.allocator, &px, W * 4, .{ .x = 0, .y = 60, .w = 1, .h = 8 }));
}
