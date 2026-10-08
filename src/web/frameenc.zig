//! One receiver's encoded, acknowledged frame stream for one view
//! (capability "frames-encoded"): the helper keeps a `Stream` per
//! opted-in owner-inline view and per opted-in observer subscription.
//!
//! Paints only accumulate (`paint`: churn for the video route, a
//! `frameflow.Damage` rect list for the lossless one); a logical frame is
//! cut from the LIVE surface only when the `frameflow.Flow` window has
//! room (`cut`), so a slow link never builds a queue of stale frames. The
//! route is `surfenc.Surface`'s: hot AND photographic AND a codec both
//! sides speak AND even dims is ONE whole-surface video tile, anything
//! else is pixcodec regions for the damage, banded and split across
//! messages under the stream's `Limits`.
//!
//! Pure: no CEF, no sockets; posts into a `proto.Outbox`.

const std = @import("std");
const proto = @import("protocol.zig");
const frameflow = @import("frameflow.zig");
const surfenc = @import("../wlhost/surfenc.zig");
const vcodec = @import("../wlhost/vcodec.zig");
const pixcodec = @import("../wlhost/pixcodec.zig");

/// Raw bytes one lossless band covers at most: bounds pixcodec's working
/// set and keeps a single band far under the message budget.
const BAND_RAW_MAX: usize = 1 << 20;

/// Wire overhead of one message plus one part, beyond the part bodies.
const MSG_OVERHEAD: usize = 64;
const PART_OVERHEAD: usize = 16;

/// How large one message of a stream may get: the control socket takes
/// `proto.MAX_FRAME`, a V1 stream socket only its own smaller frame cap.
pub const Limits = struct {
    /// Bytes of one lossless message, length prefix and tag included.
    msg: usize = proto.ENCODED_MSG_BUDGET,
    /// Bytes of one video tile; past this the frame goes lossless.
    tile: usize = proto.MAX_FRAME - 4096,

    /// Limits for a carrier whose frame (tag + body) is at most `max_frame`.
    pub fn within(max_frame: usize) Limits {
        return .{ .msg = max_frame - 4096, .tile = max_frame - 4096 };
    }
};

pub const Stream = struct {
    gpa: std.mem.Allocator,
    open: surfenc.Opener,
    limits: Limits = .{},
    flow: frameflow.Flow(proto.ENCODED_WINDOW) = .{},
    damage: frameflow.Damage = .{},
    /// Churn + encoder state, sized to the surface; only while a codec is
    /// agreed (lossless-only streams need no churn).
    surf: ?surfenc.Surface = null,
    lossless: surfenc.Lossless = .{},
    /// The first codec of the client's list this process encodes; null =
    /// lossless only.
    codec: ?vcodec.Codec = null,
    /// The previous logical frame was video: the next lossless one is the
    /// whole surface, so lossy pixels never outlive the animation.
    was_video: bool = false,
    tile: std.ArrayList(u8) = .empty,
    bodies: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, open: surfenc.Opener) Stream {
        return .{ .gpa = gpa, .open = open };
    }

    pub fn deinit(self: *Stream) void {
        if (self.surf) |*s| s.deinit();
        self.lossless.deinit(self.gpa);
        self.tile.deinit(self.gpa);
        self.bodies.deinit(self.gpa);
        self.* = undefined;
    }

    /// Apply a client's `frame_encode` codec list (vcodec ids in its
    /// preference order) against what this process encodes, and restart
    /// at a keyframe of the whole `w`x`h` surface.
    pub fn configure(self: *Stream, offered: []const u8, encodable: vcodec.CodecList, w: u16, h: u16) void {
        var list: vcodec.CodecList = .{};
        for (offered) |b| list.add(@enumFromInt(b));
        self.codec = vcodec.negotiate(&.{list}, encodable);
        if (self.codec == null) self.dropSurface();
        self.restart(w, h);
    }

    /// The receiver needs everything again (a new subscription, a resume,
    /// a re-opt): the whole surface, video starting at a keyframe.
    pub fn restart(self: *Stream, w: u16, h: u16) void {
        self.damage.full(w, h);
        if (self.surf) |*s| s.forceKeyframe();
        self.was_video = false;
    }

    /// New pixels landed in `rects` of the `w`x`h` surface.
    pub fn paint(self: *Stream, w: u16, h: u16, rects: anytype) void {
        self.damage.addAll(rects);
        if (self.codec == null) return;
        if (self.surf) |s| {
            if (s.w != w or s.h != h) self.dropSurface();
        }
        if (self.surf == null) {
            // A fresh surface opens its encoder at a keyframe; failing to
            // allocate one only costs the video route.
            self.surf = surfenc.Surface.init(self.gpa, self.open, w, h) catch null;
            self.was_video = false;
        }
        const s = &(self.surf orelse return);
        for (rects) |r| s.noteDamage(@intCast(r.x), @intCast(r.y), @intCast(r.w), @intCast(r.h));
        s.endFrame();
    }

    fn dropSurface(self: *Stream) void {
        if (self.surf) |*s| s.deinit();
        self.surf = null;
    }

    /// `frame_ack`: cumulative; a serial no longer outstanding is ignored
    /// (a re-opt or an abandoned frame can leave one in flight).
    pub fn ack(self: *Stream, serial: u64) void {
        self.flow.ack(serial) catch {};
    }

    /// Damage is pending and the window has room for another frame.
    pub fn ready(self: *const Stream) bool {
        return self.damage.pending() and self.flow.canSend();
    }

    /// Cut one logical frame from `pixels` (tight BGRA of the `w`x`h`
    /// surface) onto `out`, addressed to `view` in the receiver's ids.
    /// No-op unless `ready`.
    pub fn cut(self: *Stream, out: *proto.Outbox, view: u32, gen: u32, pixels: []const u8, w: u16, h: u16) void {
        if (!self.ready() or w == 0 or h == 0) return;
        const tight = @as(usize, w) * @as(usize, h) * 4;
        if (pixels.len < tight) {
            self.damage.clear();
            return;
        }
        if (self.cutVideo(out, view, gen, pixels[0..tight], w, h)) return;
        self.cutLossless(out, view, gen, pixels[0..tight], w, h);
    }

    fn cutVideo(self: *Stream, out: *proto.Outbox, view: u32, gen: u32, pixels: []const u8, w: u16, h: u16) bool {
        const cd = self.codec orelse return false;
        const s = &(self.surf orelse return false);
        if (s.w != w or s.h != h or !s.wantsPixels(cd)) return false;
        self.tile.clearRetainingCapacity();
        switch (s.encode(&self.tile, cd, pixels)) {
            .lossless => return false,
            .open_failed => |f| {
                std.debug.print("sketerm-web: {s} encoder for a {d}x{d} view failed ({s}); frames stay lossless\n", .{ vcodec.codecName(f.codec), w, h, @errorName(f.err) });
                return false;
            },
            .video => {},
        }
        if (self.tile.items.len > self.limits.tile) {
            // The encoder advanced past a frame nobody will see.
            s.forceKeyframe();
            return false;
        }
        const serial = self.flow.sent();
        const part = [_]proto.EncodedPart{.{ .kind = proto.encoded_video, .x = 0, .y = 0, .w = w, .h = h, .data = self.tile.items }};
        out.post(proto.FrameEncoded{ .view = view, .serial = serial, .gen = gen, .w = w, .h = h, .last = 1, .parts = &part }, null) catch {
            self.abandon(w, h);
            return true;
        };
        self.damage.clear();
        self.was_video = true;
        return true;
    }

    const Span = struct { kind: u8, x: u16, y: u16, w: u16, h: u16, start: usize, end: usize };

    fn cutLossless(self: *Stream, out: *proto.Outbox, view: u32, gen: u32, pixels: []const u8, w: u16, h: u16) void {
        if (self.was_video) {
            self.damage.full(w, h);
            self.was_video = false;
        }
        var rects: [frameflow.Damage.MAX_RECTS]frameflow.Rect = undefined;
        const list = self.damage.take(w, h, &rects);
        if (list.len == 0) return;
        const serial = self.flow.sent();
        const stride = @as(usize, w) * 4;

        var spans: std.ArrayList(Span) = .empty;
        defer spans.deinit(self.gpa);
        self.bodies.clearRetainingCapacity();
        const msg = Msg{ .stream = self, .out = out, .view = view, .serial = serial, .gen = gen, .w = w, .h = h };
        for (list) |r| {
            const band_rows: u32 = @intCast(@max(@as(usize, 1), BAND_RAW_MAX / (@as(usize, r.w) * 4)));
            var y = r.y;
            const y_end = r.y + r.h;
            while (y < y_end) : (y += band_rows) {
                const rows = @min(band_rows, y_end - y);
                const band: surfenc.Rect = .{ .x = @intCast(r.x), .y = @intCast(y), .w = @intCast(r.w), .h = @intCast(rows) };
                const enc = self.lossless.encodeRect(self.gpa, pixels, stride, band) catch continue;
                const need = enc.bytes.len + pixcodec.body_header + PART_OVERHEAD;
                const queued = self.bodies.items.len + spans.items.len * PART_OVERHEAD;
                if (spans.items.len != 0 and queued + need + MSG_OVERHEAD > self.limits.msg) {
                    if (!msg.post(spans.items, 0)) return;
                    spans.clearRetainingCapacity();
                    self.bodies.clearRetainingCapacity();
                }
                const start = self.bodies.items.len;
                pixcodec.appendBody(&self.bodies, self.gpa, enc, r.w * rows * 4, r.w * 4) catch {
                    self.bodies.shrinkRetainingCapacity(start);
                    continue;
                };
                spans.append(self.gpa, .{
                    .kind = proto.encoded_lossless,
                    .x = @intCast(r.x),
                    .y = @intCast(y),
                    .w = @intCast(r.w),
                    .h = @intCast(rows),
                    .start = start,
                    .end = self.bodies.items.len,
                }) catch {
                    self.bodies.shrinkRetainingCapacity(start);
                    continue;
                };
            }
        }
        // Even an empty final message closes the serial, or the window
        // would wait for an ack nobody can send.
        _ = msg.post(spans.items, 1);
    }

    /// One message of a lossless logical frame.
    const Msg = struct {
        stream: *Stream,
        out: *proto.Outbox,
        view: u32,
        serial: u64,
        gen: u32,
        w: u16,
        h: u16,

        fn post(m: Msg, spans: []const Span, last: u8) bool {
            const self = m.stream;
            const parts = self.gpa.alloc(proto.EncodedPart, spans.len) catch {
                self.abandon(m.w, m.h);
                return false;
            };
            defer self.gpa.free(parts);
            for (spans, parts) |s, *p| p.* = .{ .kind = s.kind, .x = s.x, .y = s.y, .w = s.w, .h = s.h, .data = self.bodies.items[s.start..s.end] };
            m.out.post(proto.FrameEncoded{ .view = m.view, .serial = m.serial, .gen = m.gen, .w = m.w, .h = m.h, .last = last, .parts = parts }, null) catch {
                self.abandon(m.w, m.h);
                return false;
            };
            return true;
        }
    };

    /// A frame could not be queued whole: forget its serial (the window
    /// must not wait for an ack that cannot come) and resend everything.
    fn abandon(self: *Stream, w: u16, h: u16) void {
        self.flow = .{ .next = self.flow.next };
        self.restart(w, h);
    }
};

/// The receive side of a `Stream`: applies `frame_encoded` parts to a
/// tight BGRA surface (the GUI's face buffer, a rig's mirror), so every
/// client decodes exactly one way.
pub const Receiver = struct {
    dec: vcodec.StreamDecoder = .{},
    scratch: std.ArrayList(u8) = .empty,

    pub const Applied = union(enum) {
        /// These pixels of the surface changed.
        rect: frameflow.Rect,
        /// A video tile was dropped; the decoder said why.
        dropped: vcodec.StreamDecoder.Outcome,
        /// The part does not describe pixels of this surface.
        malformed,
    };

    pub fn deinit(self: *Receiver, a: std.mem.Allocator) void {
        self.dec.deinit();
        self.scratch.deinit(a);
    }

    /// Apply `p` to `dst`, the `w`x`h` surface (stride `w*4`).
    /// @throws error.OutOfMemory when the decode scratch cannot grow.
    pub fn apply(self: *Receiver, a: std.mem.Allocator, dst: []u8, w: u16, h: u16, p: proto.EncodedPart) !Applied {
        if (p.w == 0 or p.h == 0 or @as(u32, p.x) + p.w > w or @as(u32, p.y) + p.h > h) return .malformed;
        if (dst.len < @as(usize, w) * h * 4) return .malformed;
        const rect: frameflow.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = p.h };
        switch (p.kind) {
            proto.encoded_lossless => {
                const body = pixcodec.peelBody(p.data) orelse return .malformed;
                if (body.raw_len != @as(u32, p.w) * p.h * 4) return .malformed;
                try self.scratch.resize(a, body.raw_len);
                pixcodec.decodeBody(body, self.scratch.items) catch return .malformed;
            },
            proto.encoded_video => {
                const peeled = (vcodec.peelTile(p.data) catch return .malformed) orelse return .malformed;
                const tile = peeled.tile;
                if (tile.x != p.x or tile.y != p.y or tile.w != p.w or tile.h != p.h) return .malformed;
                const got = try self.dec.decode(a, tile, &self.scratch);
                if (got != .decoded) return .{ .dropped = got };
            },
            else => return .malformed,
        }
        surfenc.blitRect(dst, w, h, self.scratch.items, p.x, p.y, p.w, p.h);
        return .{ .rect = rect };
    }
};

// -- tests ----------------------------------------------------------------

const t = std.testing;

fn openStub(allocator: std.mem.Allocator, codec: vcodec.Codec, w: i32, h: i32, fps: i32) anyerror!vcodec.Encoder {
    _ = .{ codec, w, h, fps };
    return vcodec.Encoder.initStub(allocator);
}

fn noise(px: []u8, seed: u32) void {
    var st: u32 = seed;
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        st = st *% 1664525 +% 1013904223;
        px[i + 0] = @truncate(st >> 24);
        px[i + 1] = @truncate(st >> 16);
        px[i + 2] = @truncate(st >> 8);
        px[i + 3] = 0xff;
    }
}

/// What a receiver reassembled from an outbox: pixels plus per logical
/// frame facts.
const Rx = struct {
    w: u16,
    h: u16,
    pix: []u8,
    frames: u32 = 0,
    messages: u32 = 0,
    video_parts: u32 = 0,
    lossless_parts: u32 = 0,
    last_serial: u64 = 0,
    recv: Receiver = .{},

    fn init(w: u16, h: u16) !Rx {
        const pix = try t.allocator.alloc(u8, @as(usize, w) * h * 4);
        @memset(pix, 0);
        return .{ .w = w, .h = h, .pix = pix };
    }

    fn deinit(self: *Rx) void {
        t.allocator.free(self.pix);
        self.recv.deinit(t.allocator);
    }

    /// Apply every queued message, checking the framing invariants.
    fn drain(self: *Rx, out: *proto.Outbox) !void {
        var open_serial: ?u64 = null;
        while (out.front()) |m| {
            var r = proto.Reader.init(m.bytes);
            const f = (try r.next()).?;
            try t.expectEqual(proto.Tag.frame_encoded, f.tag);
            const fe = try proto.FrameEncoded.decodeAlloc(f.payload, t.allocator);
            defer t.allocator.free(fe.parts);
            try t.expect(m.bytes.len <= proto.ENCODED_MSG_BUDGET);
            if (open_serial) |s| try t.expectEqual(s, fe.serial) else try t.expect(fe.serial > self.last_serial);
            for (fe.parts) |p| try self.apply(p);
            self.messages += 1;
            if (fe.last != 0) {
                self.frames += 1;
                self.last_serial = fe.serial;
                open_serial = null;
            } else open_serial = fe.serial;
            out.advance(m.bytes.len);
        }
        try t.expect(open_serial == null);
    }

    fn apply(self: *Rx, p: proto.EncodedPart) !void {
        switch (p.kind) {
            proto.encoded_lossless => self.lossless_parts += 1,
            proto.encoded_video => self.video_parts += 1,
            else => {},
        }
        const got = try self.recv.apply(t.allocator, self.pix, self.w, self.h, p);
        try t.expectEqual(frameflow.Rect{ .x = p.x, .y = p.y, .w = p.w, .h = p.h }, got.rect);
    }
};

const full_rect = struct {
    fn of(w: u16, h: u16) [1]frameflow.Rect {
        return .{.{ .x = 0, .y = 0, .w = w, .h = h }};
    }
};

test "a lossless stream reproduces the surface exactly, one serial per logical frame" {
    const W = 64;
    const H = 48;
    var px: [W * H * 4]u8 = undefined;
    noise(&px, 1);
    var s = Stream.init(t.allocator, openStub);
    defer s.deinit();
    s.configure("", .{}, W, H);
    try t.expect(s.codec == null);
    var out = proto.Outbox.init(t.allocator);
    defer out.deinit();
    var rx = try Rx.init(W, H);
    defer rx.deinit();

    s.cut(&out, 5, 1, &px, W, H);
    try rx.drain(&out);
    try t.expectEqualSlices(u8, &px, rx.pix);
    try t.expectEqual(@as(u32, 1), rx.frames);
    try t.expect(!s.ready());

    // A small change ships only its rect.
    px[(10 * W + 10) * 4] ^= 0xff;
    s.paint(W, H, &[_]frameflow.Rect{.{ .x = 10, .y = 10, .w = 1, .h = 1 }});
    s.cut(&out, 5, 2, &px, W, H);
    const before = rx.lossless_parts;
    try rx.drain(&out);
    try t.expectEqual(before + 1, rx.lossless_parts);
    try t.expectEqualSlices(u8, &px, rx.pix);
    try t.expectEqual(@as(u64, 2), rx.last_serial);
}

test "a large logical frame splits across messages under the budget, only the final one last" {
    const W: u16 = 1024;
    const H: u16 = 1300; // ~5.3 MB of incompressible pixels
    const px = try t.allocator.alloc(u8, @as(usize, W) * H * 4);
    defer t.allocator.free(px);
    noise(px, 7);
    var s = Stream.init(t.allocator, openStub);
    defer s.deinit();
    s.configure("", .{}, W, H);
    var out = proto.Outbox.init(t.allocator);
    defer out.deinit();
    var rx = try Rx.init(W, H);
    defer rx.deinit();
    s.cut(&out, 1, 1, px, W, H);
    try t.expect(out.pending() >= 2);
    try rx.drain(&out);
    try t.expectEqual(@as(u32, 1), rx.frames);
    try t.expect(rx.messages >= 2);
    try t.expectEqualSlices(u8, px, rx.pix);
}

test "the ack window holds frames back while damage merges, and an ack releases the newest pixels" {
    const W = 32;
    const H = 32;
    var px: [W * H * 4]u8 = undefined;
    @memset(&px, 0x40);
    var s = Stream.init(t.allocator, openStub);
    defer s.deinit();
    s.configure("", .{}, W, H);
    var out = proto.Outbox.init(t.allocator);
    defer out.deinit();
    var rx = try Rx.init(W, H);
    defer rx.deinit();

    s.cut(&out, 1, 1, &px, W, H); // serial 1
    s.paint(W, H, &[_]frameflow.Rect{.{ .x = 0, .y = 0, .w = 4, .h = 4 }});
    s.cut(&out, 1, 2, &px, W, H); // serial 2: the window is now full
    try rx.drain(&out);
    try t.expectEqual(@as(u32, 2), rx.frames);

    // Two more paints while nothing is acked: nothing is cut, both merge.
    px[0] = 1;
    s.paint(W, H, &[_]frameflow.Rect{.{ .x = 0, .y = 0, .w = 1, .h = 1 }});
    px[(31 * W + 31) * 4] = 2;
    s.paint(W, H, &[_]frameflow.Rect{.{ .x = 31, .y = 31, .w = 1, .h = 1 }});
    try t.expect(!s.ready());
    s.cut(&out, 1, 3, &px, W, H);
    try t.expect(out.empty());

    // A stale or unknown ack changes nothing; acking serial 1 frees one slot.
    s.ack(9);
    try t.expect(!s.ready());
    s.ack(1);
    try t.expect(s.ready());
    s.cut(&out, 1, 4, &px, W, H);
    try rx.drain(&out);
    try t.expectEqual(@as(u32, 3), rx.frames);
    try t.expectEqualSlices(u8, &px, rx.pix);
    // Cumulative: acking 3 retires 2 as well.
    s.ack(3);
    try t.expect(s.flow.canSend() and s.flow.n == 0);
}

test "a hot photographic surface goes out as one video tile, and settles lossless when it cools" {
    const W = 64;
    const H = 64;
    var px: [W * H * 4]u8 = undefined;
    var s = Stream.init(t.allocator, openStub);
    defer s.deinit();
    s.configure("", .{}, W, H);
    // The stub codec is a test backend `negotiate` never picks.
    s.codec = .stub;
    var out = proto.Outbox.init(t.allocator);
    defer out.deinit();
    var rx = try Rx.init(W, H);
    defer rx.deinit();

    var gen: u32 = 0;
    var serial_seen: u64 = 0;
    while (gen < 8) : (gen += 1) {
        noise(&px, gen + 3);
        s.paint(W, H, &full_rect.of(W, H));
        s.cut(&out, 1, gen, &px, W, H);
        try rx.drain(&out);
        s.ack(rx.last_serial);
        serial_seen = rx.last_serial;
    }
    try t.expect(rx.video_parts >= 1);
    try t.expectEqualSlices(u8, &px, rx.pix);

    // The animation stops on a flat colour: the next frame is lossless and
    // covers the WHOLE surface even though only a corner was damaged.
    @memset(&px, 0x22);
    const lossless_before = rx.lossless_parts;
    s.paint(W, H, &[_]frameflow.Rect{.{ .x = 0, .y = 0, .w = 2, .h = 2 }});
    s.cut(&out, 1, 99, &px, W, H);
    try rx.drain(&out);
    try t.expect(rx.lossless_parts > lossless_before);
    try t.expectEqualSlices(u8, &px, rx.pix);
    try t.expect(serial_seen < rx.last_serial);
}

test "configure picks the client's first codec this process encodes" {
    var s = Stream.init(t.allocator, openStub);
    defer s.deinit();
    var enc: vcodec.CodecList = .{};
    enc.add(.h264);
    s.configure(&.{ @intFromEnum(vcodec.Codec.av1), @intFromEnum(vcodec.Codec.h264) }, enc, 8, 8);
    try t.expectEqual(@as(?vcodec.Codec, .h264), s.codec);
    s.configure(&.{@intFromEnum(vcodec.Codec.av1)}, enc, 8, 8);
    try t.expect(s.codec == null);
    // Unknown ids (a newer client's codecs) and the stub are skipped.
    s.configure(&.{ 0, 9 }, enc, 8, 8);
    try t.expect(s.codec == null);
    // A restart owes the receiver the whole surface.
    try t.expect(s.ready());
}

test "a receiver refuses parts outside the surface and reports a tile it cannot start on" {
    var r: Receiver = .{};
    defer r.deinit(t.allocator);
    var dst: [8 * 8 * 4]u8 = undefined;
    const bad = proto.EncodedPart{ .kind = proto.encoded_lossless, .x = 6, .y = 0, .w = 4, .h = 1, .data = "" };
    try t.expectEqual(Receiver.Applied.malformed, try r.apply(t.allocator, &dst, 8, 8, bad));
    const junk = proto.EncodedPart{ .kind = proto.encoded_lossless, .x = 0, .y = 0, .w = 1, .h = 1, .data = "xx" };
    try t.expectEqual(Receiver.Applied.malformed, try r.apply(t.allocator, &dst, 8, 8, junk));
    // A delta tile with no decoder yet: dropped until a keyframe.
    var tile: std.ArrayList(u8) = .empty;
    defer tile.deinit(t.allocator);
    const px: [8 * 8 * 4]u8 = @splat(7);
    try vcodec.appendTile(&tile, t.allocator, .{ .codec = .stub, .keyframe = false, .x = 0, .y = 0, .w = 8, .h = 8, .seq = 1, .payload = &px });
    const delta = proto.EncodedPart{ .kind = proto.encoded_video, .x = 0, .y = 0, .w = 8, .h = 8, .data = tile.items };
    try t.expectEqual(Receiver.Applied{ .dropped = .need_keyframe }, try r.apply(t.allocator, &dst, 8, 8, delta));
}
