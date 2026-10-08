//! Pushed binary web stream V1 (capability "web-stream"): the framing,
//! validation and flow state behind one per-view stream socket.
//!
//! A frame is `u32 LE length` (INCLUDING the one tag byte) + tag + body,
//! at most `MAX_FRAME`. The helper pushes the surface, damage bands of
//! raw premultiplied BGRA, frame ends, cursor and Opus audio; the client
//! answers with input and an ACK per frame end. Never more than
//! `MAX_UNACKED` frames are in flight and no frame is ever queued:
//! damage is merged and the LIVE buffer is read when a frame is sent,
//! so a slow reader sees fewer, newer frames. The window and the damage
//! list themselves are the shared `frameflow.zig`; a frame carries one
//! band run per pending damage rect.
//!
//! Pure code: std plus the repo spinlock, no CEF, no sockets. The
//! socket half is `streamsrv.zig`; the engine glue `cefhost/stream.zig`.

const std = @import("std");
const SpinLock = @import("../util/spinlock.zig").SpinLock;
const keymap = @import("keymap.zig");
const frameflow = @import("frameflow.zig");
const Rect = frameflow.Rect;

/// Largest frame on the stream, length field included in neither
/// direction's count (the length covers tag + body).
pub const MAX_FRAME: u32 = 4 * 1024 * 1024;
/// Damage pixel payload per band.
pub const MAX_BAND_BYTES: usize = 1024 * 1024;
/// Frame ends the helper may have outstanding without an ACK.
pub const MAX_UNACKED = 2;
/// Hex characters in a stream token (16 random bytes).
pub const TOKEN_LEN = 32;
/// The only surface format V1 defines.
pub const FORMAT_BGRA_PREMUL: u8 = 1;
/// Longest key name accepted in a Key frame.
pub const MAX_KEY_NAME = 64;
/// Longest Text frame body. Every byte can become an engine char event,
/// so this bounds what one frame costs the poll loop.
pub const MAX_TEXT = 4096;
/// Largest frame a CLIENT may send (tag + the longest body, a Text).
/// The helper refuses a longer length at once instead of buffering it.
pub const MAX_CLIENT_FRAME: u32 = 1 + MAX_TEXT;
/// Cursor images larger than this are sent as the named default.
pub const MAX_CURSOR_DIM: u32 = 256;
/// Stream mods are CEF event-flag bits (the engine's own vocabulary,
/// what a client mirroring Chromium input already holds), NOT the
/// control protocol's `mod_*` bits; `modsToProto` translates at the
/// engine seam. Accepted: caps lock, shift, control, alt, the three
/// mouse buttons, command (meta) and num lock. Anything else is refused.
pub const CEF_CAPS_LOCK: u32 = 1 << 0;
pub const CEF_SHIFT: u32 = 1 << 1;
pub const CEF_CONTROL: u32 = 1 << 2;
pub const CEF_ALT: u32 = 1 << 3;
pub const CEF_COMMAND: u32 = 1 << 7;
pub const CEF_NUM_LOCK: u32 = 1 << 8;
pub const MODS_MASK: u32 = 0x1FF;
/// Pointer/wheel coordinates beyond this are refused as hostile.
pub const MAX_COORD: i32 = 1 << 20;

pub const RESIZE_MIN_W: u32 = 320;
pub const RESIZE_MAX_W: u32 = 3840;
pub const RESIZE_MIN_H: u32 = 240;
pub const RESIZE_MAX_H: u32 = 2160;

pub const Tag = enum(u8) {
    auth = 1,
    surface = 2,
    damage = 3,
    frame_end = 4,
    cursor = 5,
    audio = 6,
    pointer = 16,
    wheel = 17,
    key = 18,
    text = 19,
    focus = 20,
    resize = 21,
    ack = 22,
    _,
};

pub const HEADER = 5;
pub const SURFACE_BODY = 17;
pub const DAMAGE_HEAD = 16;
pub const FRAME_END_BODY = 8;
pub const AUDIO_HEAD = 15;
pub const CURSOR_IMAGE_HEAD = 2 + 16;

pub const PointerAction = enum(u8) { move = 0, down = 1, up = 2, leave = 3 };
pub const KeyAction = enum(u8) { down = 0, up = 1 };

pub const Pointer = struct { action: PointerAction, x: i32, y: i32, button: u8, clicks: u8, mods: u32 };
pub const Wheel = struct { x: i32, y: i32, dx: i32, dy: i32, mods: u32 };
pub const Key = struct { action: KeyAction, mods: u32, name: []const u8 };
pub const Size = struct { w: u32, h: u32 };

/// One validated client frame. Slices borrow the inbound buffer.
pub const Input = union(enum) {
    auth: [TOKEN_LEN]u8,
    pointer: Pointer,
    wheel: Wheel,
    key: Key,
    text: []const u8,
    focus: bool,
    resize: Size,
    ack: u64,
};

pub const DecodeError = error{ UnknownTag, BadLength, BadValue, BadUtf8 };

/// A complete frame split off an inbound byte stream.
pub const Raw = struct { tag: u8, body: []const u8, len: usize };

/// The next complete frame at the start of `buf`, or null when more
/// bytes are needed. A length of zero or past `MAX_FRAME` is fatal:
/// the peer is desynchronised, not slow.
pub fn split(buf: []const u8) error{BadLength}!?Raw {
    return splitMax(buf, MAX_FRAME);
}

/// `split` with a tighter length cap (the client direction uses
/// `MAX_CLIENT_FRAME`).
pub fn splitMax(buf: []const u8, max: u32) error{BadLength}!?Raw {
    if (buf.len < 4) return null;
    const n = std.mem.readInt(u32, buf[0..4], .little);
    if (n == 0 or n > max) return error.BadLength;
    if (buf.len - 4 < n) return null;
    return .{ .tag = buf[4], .body = buf[5 .. 4 + n], .len = 4 + n };
}

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn rdI32(b: []const u8, off: usize) i32 {
    return @bitCast(rd32(b, off));
}

fn coordOk(v: i32) bool {
    return v >= -MAX_COORD and v <= MAX_COORD;
}

/// Whether `s` is a well-formed stream token: exactly `TOKEN_LEN`
/// lowercase hex characters.
pub fn isToken(s: []const u8) bool {
    if (s.len != TOKEN_LEN) return false;
    for (s) |ch| switch (ch) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Hex-encode 16 random bytes into a token.
pub fn mintToken(random: [16]u8) [TOKEN_LEN]u8 {
    const hex = "0123456789abcdef";
    var out: [TOKEN_LEN]u8 = undefined;
    for (random, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 15];
    }
    return out;
}

/// Constant-time token comparison, so a wrong guess learns nothing
/// about how much of it matched.
pub fn tokenEql(a: *const [TOKEN_LEN]u8, b: *const [TOKEN_LEN]u8) bool {
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Validate one client frame. Helper-to-client tags arriving from the
/// client are as unknown as a future tag: V1 is strict both ways.
pub fn decode(tag: u8, body: []const u8) DecodeError!Input {
    switch (@as(Tag, @enumFromInt(tag))) {
        .auth => {
            if (!isToken(body)) return error.BadValue;
            return .{ .auth = body[0..TOKEN_LEN].* };
        },
        .pointer => {
            if (body.len != 15) return error.BadLength;
            if (body[0] > 3) return error.BadValue;
            const action: PointerAction = @enumFromInt(body[0]);
            const x = rdI32(body, 1);
            const y = rdI32(body, 5);
            const button = body[9];
            const clicks = body[10];
            const mods = rd32(body, 11);
            if (!coordOk(x) or !coordOk(y) or button > 2 or mods & ~MODS_MASK != 0) return error.BadValue;
            if (clicks < 1 or clicks > 3) return error.BadValue;
            return .{ .pointer = .{ .action = action, .x = x, .y = y, .button = button, .clicks = clicks, .mods = mods } };
        },
        .wheel => {
            if (body.len != 20) return error.BadLength;
            const w = Wheel{ .x = rdI32(body, 0), .y = rdI32(body, 4), .dx = rdI32(body, 8), .dy = rdI32(body, 12), .mods = rd32(body, 16) };
            if (!coordOk(w.x) or !coordOk(w.y) or !coordOk(w.dx) or !coordOk(w.dy) or w.mods & ~MODS_MASK != 0) return error.BadValue;
            return .{ .wheel = w };
        },
        .key => {
            if (body.len < 7) return error.BadLength;
            if (body[0] > 1) return error.BadValue;
            const mods = rd32(body, 1);
            const n = std.mem.readInt(u16, body[5..7], .little);
            if (body.len != 7 + @as(usize, n)) return error.BadLength;
            if (n == 0 or n > MAX_KEY_NAME or mods & ~MODS_MASK != 0) return error.BadValue;
            const name = body[7..];
            if (!std.unicode.utf8ValidateSlice(name)) return error.BadUtf8;
            return .{ .key = .{ .action = @enumFromInt(body[0]), .mods = mods, .name = name } };
        },
        .text => {
            if (body.len > MAX_TEXT) return error.BadLength;
            if (!std.unicode.utf8ValidateSlice(body)) return error.BadUtf8;
            return .{ .text = body };
        },
        .focus => {
            if (body.len != 1) return error.BadLength;
            if (body[0] > 1) return error.BadValue;
            return .{ .focus = body[0] == 1 };
        },
        .resize => {
            if (body.len != 8) return error.BadLength;
            const s = Size{ .w = rd32(body, 0), .h = rd32(body, 4) };
            if (s.w < RESIZE_MIN_W or s.w > RESIZE_MAX_W or s.h < RESIZE_MIN_H or s.h > RESIZE_MAX_H) return error.BadValue;
            return .{ .resize = s };
        },
        .ack => {
            if (body.len != 8) return error.BadLength;
            return .{ .ack = std.mem.readInt(u64, body[0..8], .little) };
        },
        else => return error.UnknownTag,
    }
}

// -- encoders ---------------------------------------------------------
//
// Each writes one whole frame into `dst`, which must be exactly the
// size its `*Len` companion names; the socket half reserves that room
// in its bounded transmit buffer first.

fn putHeader(dst: []u8, tag: Tag, body_len: usize) void {
    std.mem.writeInt(u32, dst[0..4], @intCast(body_len + 1), .little);
    dst[4] = @intFromEnum(tag);
}

fn put32(dst: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, dst[off..][0..4], v, .little);
}

pub const Surface = struct { pixel_w: u32, pixel_h: u32, logical_w: u32, logical_h: u32 };

pub const SURFACE_LEN = HEADER + SURFACE_BODY;

pub fn encodeSurface(dst: *[SURFACE_LEN]u8, s: Surface) void {
    putHeader(dst, .surface, SURFACE_BODY);
    put32(dst, 5, s.pixel_w);
    put32(dst, 9, s.pixel_h);
    put32(dst, 13, s.logical_w);
    put32(dst, 17, s.logical_h);
    dst[21] = FORMAT_BGRA_PREMUL;
}

pub fn damageLen(r: Rect) usize {
    return HEADER + DAMAGE_HEAD + @as(usize, r.w) * r.h * 4;
}

/// The header of a Damage frame; the caller fills the `w*h*4` pixel
/// bytes that follow it.
pub fn encodeDamageHead(dst: []u8, r: Rect) []u8 {
    putHeader(dst, .damage, DAMAGE_HEAD + @as(usize, r.w) * r.h * 4);
    put32(dst, 5, r.x);
    put32(dst, 9, r.y);
    put32(dst, 13, r.w);
    put32(dst, 17, r.h);
    return dst[HEADER + DAMAGE_HEAD ..][0 .. @as(usize, r.w) * r.h * 4];
}

pub const FRAME_END_LEN = HEADER + FRAME_END_BODY;

pub fn encodeFrameEnd(dst: *[FRAME_END_LEN]u8, serial: u64) void {
    putHeader(dst, .frame_end, FRAME_END_BODY);
    std.mem.writeInt(u64, dst[5..13], serial, .little);
}

/// What the page's pointer looks like: hidden, a CSS cursor name, or
/// a premultiplied BGRA image (CEF's own buffer, like damage) with its
/// hotspot.
pub const Cursor = union(enum) {
    hidden,
    named: []const u8,
    image: struct { w: u32, h: u32, hot_x: i32, hot_y: i32, bgra: []const u8 },
};

pub fn cursorLen(cur: Cursor) usize {
    return HEADER + switch (cur) {
        .hidden => 2 + 2,
        .named => |n| 2 + 2 + n.len,
        .image => |im| CURSOR_IMAGE_HEAD + im.bgra.len,
    };
}

/// A hidden cursor is the named form with `visible = 0` and no name.
pub fn encodeCursor(dst: []u8, cur: Cursor) void {
    switch (cur) {
        .hidden => {
            putHeader(dst, .cursor, 4);
            dst[5] = 0;
            dst[6] = 0;
            std.mem.writeInt(u16, dst[7..9], 0, .little);
        },
        .named => |n| {
            putHeader(dst, .cursor, 4 + n.len);
            dst[5] = 1;
            dst[6] = 0;
            std.mem.writeInt(u16, dst[7..9], @intCast(n.len), .little);
            @memcpy(dst[9..][0..n.len], n);
        },
        .image => |im| {
            putHeader(dst, .cursor, CURSOR_IMAGE_HEAD + im.bgra.len);
            dst[5] = 1;
            dst[6] = 1;
            put32(dst, 7, im.w);
            put32(dst, 11, im.h);
            put32(dst, 15, @bitCast(im.hot_x));
            put32(dst, 19, @bitCast(im.hot_y));
            @memcpy(dst[23..][0..im.bgra.len], im.bgra);
        },
    }
}

pub fn audioLen(opus_len: usize) usize {
    return HEADER + AUDIO_HEAD + opus_len;
}

pub fn encodeAudio(dst: []u8, pts_us: u64, rate: u32, channels: u8, samples: u16, opus: []const u8) void {
    putHeader(dst, .audio, AUDIO_HEAD + opus.len);
    std.mem.writeInt(u64, dst[5..13], pts_us, .little);
    put32(dst, 13, rate);
    dst[17] = channels;
    std.mem.writeInt(u16, dst[18..20], samples, .little);
    @memcpy(dst[20..][0..opus.len], opus);
}

// -- damage bands and frame flow ------------------------------------------

/// Splits one damage rect into bands whose pixel payload stays within
/// `MAX_BAND_BYTES`: full-width row bands normally, column-split only
/// for a surface whose single row is already larger than that.
pub const Bands = struct {
    rect: Rect,
    bw: u32,
    bh: u32,
    x: u32 = 0,
    y: u32 = 0,

    pub fn init(r: Rect) Bands {
        const max_px: u32 = @intCast(MAX_BAND_BYTES / 4);
        const bw = @max(1, @min(r.w, max_px));
        const bh = @max(1, @min(r.h, max_px / bw));
        return .{ .rect = r, .bw = bw, .bh = bh };
    }

    /// The next band, without advancing (the sender commits it with
    /// `advance` only once it fitted in the transmit buffer).
    pub fn peek(self: *const Bands) ?Rect {
        if (self.rect.empty() or self.y >= self.rect.h) return null;
        return .{
            .x = self.rect.x + self.x,
            .y = self.rect.y + self.y,
            .w = @min(self.bw, self.rect.w - self.x),
            .h = @min(self.bh, self.rect.h - self.y),
        };
    }

    pub fn advance(self: *Bands) void {
        self.x += self.bw;
        if (self.x >= self.rect.w) {
            self.x = 0;
            self.y += self.bh;
        }
    }
};

/// V1's ack window: at most `MAX_UNACKED` frame ends in flight.
pub const Flow = frameflow.Flow(MAX_UNACKED);

// -- held input ---------------------------------------------------------

/// What the stream client is still holding down, so a disconnect or a
/// blur can let go of it: a key left down on the page auto-repeats or
/// keeps a modifier stuck, a button left down turns every later move
/// into a drag.
pub const Held = struct {
    pub const MAX_KEYS = 16;

    /// Held keys by IDENTITY (what the engine considers the same key:
    /// the caller's choice, the CEF virtual key in practice, so `A` down
    /// and `a` up are one key), each with the keysym its down carried,
    /// which is what the release is sent as.
    keys: [MAX_KEYS]HeldKey = @splat(.{}),
    nkeys: usize = 0,
    /// Bit per protocol button (0 left, 1 middle, 2 right).
    buttons: u8 = 0,
    x: i32 = 0,
    y: i32 = 0,

    pub const HeldKey = struct { id: u32 = 0, keysym: u32 = 0 };

    pub const Release = union(enum) {
        key: u32,
        button: struct { button: u8, x: i32, y: i32 },
    };

    /// Track a key down. False when the table is full: the caller must
    /// drop that edge, since a down it could not release must not land.
    /// A repeat of a held key (same identity) takes no new slot.
    pub fn keyDown(self: *Held, id: u32, keysym: u32) bool {
        for (self.keys[0..self.nkeys]) |k| if (k.id == id) return true;
        if (self.nkeys == MAX_KEYS) return false;
        self.keys[self.nkeys] = .{ .id = id, .keysym = keysym };
        self.nkeys += 1;
        return true;
    }

    /// Forget the key with identity `id`; whether it was held.
    pub fn keyUp(self: *Held, id: u32) bool {
        for (self.keys[0..self.nkeys], 0..) |k, i| {
            if (k.id != id) continue;
            self.keys[i] = self.keys[self.nkeys - 1];
            self.nkeys -= 1;
            return true;
        }
        return false;
    }

    pub fn pointer(self: *Held, p: Pointer) void {
        self.x = p.x;
        self.y = p.y;
        const bit = @as(u8, 1) << @intCast(p.button);
        switch (p.action) {
            .down => self.buttons |= bit,
            .up => self.buttons &= ~bit,
            .move, .leave => {},
        }
    }

    /// The held buttons as CEF event flags (left 1<<4, middle 1<<5,
    /// right 1<<6): what the engine needs on every pointer and wheel
    /// event during a drag, whatever the client put in its mods.
    pub fn cefButtons(self: *const Held) u32 {
        return @as(u32, self.buttons) << 4;
    }

    /// Forget everything without releasing it (the browser is gone).
    pub fn clear(self: *Held) void {
        self.buttons = 0;
        self.nkeys = 0;
    }

    /// Every release owed, buttons first (at the last pointer
    /// position), and forget them all.
    pub fn drain(self: *Held, out: *[MAX_KEYS + 3]Release) []Release {
        var n: usize = 0;
        var b: u8 = 0;
        while (b < 3) : (b += 1) {
            if (self.buttons & (@as(u8, 1) << @intCast(b)) == 0) continue;
            out[n] = .{ .button = .{ .button = b, .x = self.x, .y = self.y } };
            n += 1;
        }
        for (self.keys[0..self.nkeys]) |k| {
            out[n] = .{ .key = k.keysym };
            n += 1;
        }
        self.buttons = 0;
        self.nkeys = 0;
        return out[0..n];
    }
};

// -- audio ----------------------------------------------------------------

/// Bounded, thread-safe PCM handoff from the engine's audio capture
/// thread to the server loop, one slot per stream. The capture thread
/// converts planar float to interleaved s16 stereo OUTSIDE the lock and
/// copies under it; a packet that does not fit is dropped whole (and
/// counted), never blocking the engine. Everything is static storage,
/// so a capture callback racing a stream's close can never touch freed
/// memory: a slot is only ever re-bound, not freed.
///
/// Captures and slots are separate tables because their lifetimes are:
/// the engine keeps a page's capture running until the page has been
/// quiet for a while, across stream closes, and a stream that opens
/// while its page is still captured must attach to that capture, since
/// the engine will not ask again.
pub fn AudioTable(comptime slots: usize, comptime cap_frames: usize) type {
    return struct {
        const Self = @This();
        pub const RATE: u32 = 48_000;
        pub const CHANNELS: u8 = 2;
        /// A packet whose pts lands further than this from where the
        /// queue ends is a discontinuity: the queue is dropped rather
        /// than labelled contiguous.
        pub const GAP_US: u64 = 25_000;

        /// A browser the engine is capturing right now, and its format.
        const Capture = struct { browser: i32 = 0, rate: u32 = 0, channels: u32 = 0 };

        const Slot = struct {
            used: bool = false,
            /// Engine browser id the slot receives for; 0 = unbound.
            browser: i32 = 0,
            ring: [cap_frames * 2]i16 = undefined,
            head: usize = 0,
            frames: usize = 0,
            head_pts_us: u64 = 0,
            dropped: u64 = 0,
            /// A packet was dropped for lack of room: whatever arrives
            /// next is NOT contiguous with the queue, however close its
            /// pts looks.
            broken: bool = false,

            fn reset(self: *Slot) void {
                self.head = 0;
                self.frames = 0;
                self.broken = false;
            }
        };

        lock: SpinLock = .{},
        captures: [slots * 2]Capture = @splat(.{}),
        slot: [slots]Slot = @splat(.{}),

        /// Claim a free slot for a new stream; null when all are taken.
        pub fn claim(self: *Self) ?usize {
            self.lock.lock();
            defer self.lock.unlock();
            for (&self.slot, 0..) |*s, i| {
                if (s.used) continue;
                s.used = true;
                s.browser = 0;
                s.reset();
                s.dropped = 0;
                return i;
            }
            return null;
        }

        /// Release a slot; later packets for its browser are dropped.
        pub fn unclaim(self: *Self, i: usize) void {
            self.lock.lock();
            defer self.lock.unlock();
            self.slot[i].used = false;
            self.slot[i].browser = 0;
            self.slot[i].reset();
        }

        /// Point slot `i` at `browser`, with an empty queue.
        pub fn bind(self: *Self, i: usize, browser: i32) void {
            self.lock.lock();
            defer self.lock.unlock();
            const s = &self.slot[i];
            if (!s.used) return;
            s.browser = browser;
            s.reset();
        }

        /// Drop whatever slot `i` has queued (a stream that just
        /// authenticated wants live audio, not the backlog).
        pub fn flush(self: *Self, i: usize) void {
            self.lock.lock();
            defer self.lock.unlock();
            self.slot[i].reset();
        }

        fn captureOf(self: *Self, browser: i32) ?*Capture {
            for (&self.captures) |*cp| {
                if (cp.browser == browser and browser != 0) return cp;
            }
            return null;
        }

        fn resetBound(self: *Self, browser: i32) void {
            for (&self.slot) |*s| {
                if (s.used and s.browser == browser) s.reset();
            }
        }

        /// The engine started capturing `browser`. A table full of live
        /// captures records nothing, so its packets are dropped.
        pub fn start(self: *Self, browser: i32, rate: u32, channels: u32) void {
            if (browser == 0) return;
            self.lock.lock();
            defer self.lock.unlock();
            const cp = self.captureOf(browser) orelse self.captureOf0() orelse return;
            cp.* = .{ .browser = browser, .rate = rate, .channels = channels };
            self.resetBound(browser);
        }

        fn captureOf0(self: *Self) ?*Capture {
            for (&self.captures) |*cp| {
                if (cp.browser == 0) return cp;
            }
            return null;
        }

        pub fn stop(self: *Self, browser: i32) void {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.captureOf(browser)) |cp| cp.* = .{};
            self.resetBound(browser);
        }

        /// Whether the engine is capturing `browser` at all.
        pub fn capturing(self: *Self, browser: i32) bool {
            self.lock.lock();
            defer self.lock.unlock();
            return self.captureOf(browser) != null;
        }

        /// The live capture's channel count for `browser`; 0 when it is
        /// not captured at `RATE` (its packets are then not read).
        pub fn channelsOf(self: *Self, browser: i32) u32 {
            self.lock.lock();
            defer self.lock.unlock();
            const cp = self.captureOf(browser) orelse return 0;
            return if (cp.rate == RATE) cp.channels else 0;
        }

        /// Capture-thread entry: `data[c][f]` planar float. Mono is
        /// duplicated to both sides, channels past two are dropped.
        /// `pts_ms` is the engine's capture clock (increasing; measured
        /// as epoch ms on Linux, but never relied on as a wall time).
        pub fn push(self: *Self, browser: i32, data: []const [*]const f32, frames: usize, pts_ms: i64) void {
            if (data.len == 0 or browser == 0) return;
            var scratch: [1024 * 2]i16 = undefined;
            var done: usize = 0;
            const base_us: u64 = if (pts_ms > 0) @as(u64, @intCast(pts_ms)) * 1000 else 0;
            while (done < frames) {
                // Keep stereo sample-count multiplication in usize.
                const n: usize = @min(frames - done, scratch.len / 2);
                for (0..n) |f| {
                    const l = data[0][done + f];
                    const r = if (data.len > 1) data[1][done + f] else l;
                    scratch[f * 2] = toS16(l);
                    scratch[f * 2 + 1] = toS16(r);
                }
                self.pushS16(browser, scratch[0 .. n * 2], base_us + @as(u64, done) * 1_000_000 / RATE);
                done += n;
            }
        }

        fn pushS16(self: *Self, browser: i32, pcm: []const i16, pts_us: u64) void {
            self.lock.lock();
            defer self.lock.unlock();
            const cp = self.captureOf(browser) orelse return;
            if (cp.rate != RATE) return;
            const n = pcm.len / 2;
            for (&self.slot) |*s| {
                if (!s.used or s.browser != browser) continue;
                if (s.broken) {
                    s.dropped += s.frames;
                    s.reset();
                }
                if (s.frames != 0 and pts_us != 0) {
                    // Where this packet should start if nothing was lost;
                    // a gap (an earlier drop, an engine stall) must not be
                    // stitched into one contiguous run of timestamps.
                    const tail = s.head_pts_us + @as(u64, s.frames) * 1_000_000 / RATE;
                    const diff = if (pts_us > tail) pts_us - tail else tail - pts_us;
                    if (diff > GAP_US) {
                        s.dropped += s.frames;
                        s.reset();
                    }
                }
                if (s.frames + n > cap_frames) {
                    s.dropped += n;
                    s.broken = true;
                    continue;
                }
                if (s.frames == 0) s.head_pts_us = pts_us;
                var w = (s.head + s.frames) % cap_frames;
                for (0..n) |f| {
                    s.ring[w * 2] = pcm[f * 2];
                    s.ring[w * 2 + 1] = pcm[f * 2 + 1];
                    w = (w + 1) % cap_frames;
                }
                s.frames += n;
            }
        }

        /// Pop exactly `out.len / 2` frames when that many are queued;
        /// returns the pts (us) of the first one.
        pub fn pop(self: *Self, i: usize, out: []i16) ?u64 {
            self.lock.lock();
            defer self.lock.unlock();
            const s = &self.slot[i];
            const n = out.len / 2;
            if (!s.used or s.frames < n) return null;
            const pts = s.head_pts_us;
            for (0..n) |f| {
                out[f * 2] = s.ring[s.head * 2];
                out[f * 2 + 1] = s.ring[s.head * 2 + 1];
                s.head = (s.head + 1) % cap_frames;
            }
            s.frames -= n;
            s.head_pts_us += @as(u64, n) * 1_000_000 / RATE;
            return pts;
        }

        pub fn queued(self: *Self, i: usize) usize {
            self.lock.lock();
            defer self.lock.unlock();
            return self.slot[i].frames;
        }

        pub fn dropped(self: *Self, i: usize) u64 {
            self.lock.lock();
            defer self.lock.unlock();
            return self.slot[i].dropped;
        }
    };
}

/// Whether this input may revive a discarded page. Ups, leaves and blurs
/// only let go of something the dead browser held; waking a page to
/// deliver them would cost a page load for nothing.
pub fn mayWake(in: Input) bool {
    return switch (in) {
        .pointer => |p| p.action == .down or p.action == .move,
        .key => |k| k.action == .down,
        .focus => |on| on,
        .wheel, .text, .resize => true,
        .auth, .ack => false,
    };
}

/// What the engine considers the same physical key: its Windows
/// virtual key (`A` and `a`, `1` and `!` share one), so a down and an up
/// that name different case still pair. A key with no virtual key keeps
/// its keysym, in a range no virtual key reaches.
pub fn keyIdentity(keysym: u32) u32 {
    const vk = keymap.map(keysym).windows_key_code;
    return if (vk > 0) @intCast(vk) else keysym | 0x8000_0000;
}

/// CEF event flags -> the control protocol's `mod_*` bits (values
/// mirrored from `protocol.zig`, which this pure module does not import;
/// the test pins them). Mouse-button bits carry no modifier and drop.
pub fn modsToProto(cef: u32) u32 {
    var m: u32 = 0;
    if (cef & CEF_SHIFT != 0) m |= 1;
    if (cef & CEF_CONTROL != 0) m |= 2;
    if (cef & CEF_ALT != 0) m |= 4;
    if (cef & CEF_COMMAND != 0) m |= 8;
    if (cef & CEF_CAPS_LOCK != 0) m |= 16;
    if (cef & CEF_NUM_LOCK != 0) m |= 32;
    return m;
}

fn toS16(v: f32) i16 {
    const clamped = std.math.clamp(v, -1.0, 1.0);
    return @intFromFloat(clamped * 32767.0);
}

// -- tests ----------------------------------------------------------------

const t = std.testing;

fn frame(buf: []u8, tag: Tag, body: []const u8) []u8 {
    std.mem.writeInt(u32, buf[0..4], @intCast(body.len + 1), .little);
    buf[4] = @intFromEnum(tag);
    @memcpy(buf[5..][0..body.len], body);
    return buf[0 .. 5 + body.len];
}

test "split waits for whole frames and refuses zero or oversized lengths" {
    var buf: [64]u8 = undefined;
    const f = frame(&buf, .ack, &[_]u8{ 7, 0, 0, 0, 0, 0, 0, 0 });
    try t.expect((try split(f[0..3])) == null);
    try t.expect((try split(f[0 .. f.len - 1])) == null);
    const got = (try split(f)).?;
    try t.expectEqual(@as(u8, 22), got.tag);
    try t.expectEqual(@as(usize, 13), got.len);
    try t.expectError(error.BadLength, split(&.{ 0, 0, 0, 0, 1 }));
    var big: [5]u8 = undefined;
    std.mem.writeInt(u32, big[0..4], MAX_FRAME + 1, .little);
    try t.expectError(error.BadLength, split(&big));
}

test "decode accepts the V1 client frames and refuses hostile values" {
    var b: [32]u8 = undefined;
    // Pointer: down, (10,-5), right, 2 clicks, shift.
    std.mem.writeInt(i32, b[1..5], 10, .little);
    std.mem.writeInt(i32, b[5..9], -5, .little);
    b[0] = 1;
    b[9] = 2;
    b[10] = 2;
    std.mem.writeInt(u32, b[11..15], 1, .little);
    const p = (try decode(16, b[0..15])).pointer;
    try t.expectEqual(PointerAction.down, p.action);
    try t.expectEqual(@as(i32, -5), p.y);
    b[10] = 0;
    try t.expectError(error.BadValue, decode(16, b[0..15]));
    b[0] = 0; // even a move carries 1..3
    try t.expectError(error.BadValue, decode(16, b[0..15]));
    b[10] = 1;
    _ = try decode(16, b[0..15]);
    b[9] = 3;
    try t.expectError(error.BadValue, decode(16, b[0..15]));
    b[9] = 0;
    std.mem.writeInt(u32, b[11..15], 1 << 9, .little); // EVENTFLAG_IS_KEY_PAD
    try t.expectError(error.BadValue, decode(16, b[0..15]));
    std.mem.writeInt(u32, b[11..15], CEF_SHIFT | (1 << 4), .little);
    _ = try decode(16, b[0..15]);
    try t.expectError(error.BadLength, decode(16, b[0..14]));
    std.mem.writeInt(u32, b[11..15], 0, .little);
    std.mem.writeInt(i32, b[1..5], MAX_COORD + 1, .little);
    try t.expectError(error.BadValue, decode(16, b[0..15]));

    // Key: down, ctrl, "Tab".
    b[0] = 0;
    std.mem.writeInt(u32, b[1..5], 2, .little);
    std.mem.writeInt(u16, b[5..7], 3, .little);
    @memcpy(b[7..10], "Tab");
    const k = (try decode(18, b[0..10])).key;
    try t.expectEqualStrings("Tab", k.name);
    try t.expectError(error.BadLength, decode(18, b[0..9]));
    std.mem.writeInt(u16, b[5..7], 0, .little);
    try t.expectError(error.BadValue, decode(18, b[0..7]));
    std.mem.writeInt(u16, b[5..7], 2, .little);
    b[7] = 0xc3;
    b[8] = 0x28;
    try t.expectError(error.BadUtf8, decode(18, b[0..9]));

    try t.expectError(error.BadUtf8, decode(19, &.{ 0xff, 0xfe }));
    const long = [_]u8{'a'} ** (MAX_TEXT + 1);
    try t.expectError(error.BadLength, decode(19, &long));
    _ = try decode(19, long[0..MAX_TEXT]);
    var hdr: [5]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], MAX_CLIENT_FRAME + 1, .little);
    try t.expectError(error.BadLength, splitMax(&hdr, MAX_CLIENT_FRAME));
    try t.expectEqualStrings("hi", (try decode(19, "hi")).text);
    try t.expect((try decode(20, &.{1})).focus);
    try t.expectError(error.BadValue, decode(20, &.{2}));

    std.mem.writeInt(u32, b[0..4], 1280, .little);
    std.mem.writeInt(u32, b[4..8], 720, .little);
    try t.expectEqual(@as(u32, 720), (try decode(21, b[0..8])).resize.h);
    std.mem.writeInt(u32, b[0..4], 3841, .little);
    try t.expectError(error.BadValue, decode(21, b[0..8]));
    std.mem.writeInt(u32, b[0..4], 320, .little);
    std.mem.writeInt(u32, b[4..8], 239, .little);
    try t.expectError(error.BadValue, decode(21, b[0..8]));

    // Helper-to-client tags and future tags are refused alike.
    try t.expectError(error.UnknownTag, decode(2, b[0..17]));
    try t.expectError(error.UnknownTag, decode(99, ""));
}

test "CEF event flags translate to protocol mods" {
    try t.expectEqual(@as(u32, 0), modsToProto(0));
    try t.expectEqual(@as(u32, 1 | 2 | 4 | 8), modsToProto(CEF_SHIFT | CEF_CONTROL | CEF_ALT | CEF_COMMAND));
    try t.expectEqual(@as(u32, 16 | 32), modsToProto(CEF_CAPS_LOCK | CEF_NUM_LOCK | (1 << 4)));
    const proto = @import("protocol.zig");
    try t.expectEqual(proto.mod_shift, modsToProto(CEF_SHIFT));
    try t.expectEqual(proto.mod_ctrl, modsToProto(CEF_CONTROL));
    try t.expectEqual(proto.mod_alt, modsToProto(CEF_ALT));
    try t.expectEqual(proto.mod_super, modsToProto(CEF_COMMAND));
    try t.expectEqual(proto.mod_capslock, modsToProto(CEF_CAPS_LOCK));
    try t.expectEqual(proto.mod_numlock, modsToProto(CEF_NUM_LOCK));
}

test "only engaging input may revive a discarded page" {
    const ptr = Pointer{ .action = .up, .x = 0, .y = 0, .button = 0, .clicks = 1, .mods = 0 };
    try t.expect(!mayWake(.{ .pointer = ptr }));
    var lv = ptr;
    lv.action = .leave;
    try t.expect(!mayWake(.{ .pointer = lv }));
    var dn = ptr;
    dn.action = .down;
    try t.expect(mayWake(.{ .pointer = dn }));
    try t.expect(!mayWake(.{ .key = .{ .action = .up, .mods = 0, .name = "a" } }));
    try t.expect(mayWake(.{ .key = .{ .action = .down, .mods = 0, .name = "a" } }));
    try t.expect(!mayWake(.{ .focus = false }));
    try t.expect(mayWake(.{ .focus = true }));
    try t.expect(mayWake(.{ .text = "x" }));
}

test "key identity pairs case variants of one key and keeps others apart" {
    try t.expectEqual(keyIdentity('a'), keyIdentity('A'));
    try t.expectEqual(keyIdentity('1'), keyIdentity('1'));
    try t.expect(keyIdentity('a') != keyIdentity('b'));
    try t.expect(keyIdentity(0xff0d) != keyIdentity(0xff09));
    // A codepoint with no virtual key still has a stable identity.
    try t.expectEqual(keyIdentity(0x010003b1), keyIdentity(0x010003b1));
    try t.expect(keyIdentity(0x010003b1) != keyIdentity(0x010003b2));
}

test "auth takes exactly 32 lowercase hex characters" {
    const tok = mintToken([_]u8{ 0xde, 0xad, 0xbe, 0xef } ++ [_]u8{0} ** 12);
    try t.expect(isToken(&tok));
    try t.expectEqualStrings("deadbeef", tok[0..8]);
    const a = (try decode(1, &tok)).auth;
    try t.expect(tokenEql(&a, &tok));
    var upper = tok;
    upper[0] = 'D';
    try t.expectError(error.BadValue, decode(1, &upper));
    try t.expectError(error.BadValue, decode(1, tok[0..31]));
    var other = tok;
    other[31] = if (tok[31] == '0') '1' else '0';
    try t.expect(!tokenEql(&other, &tok));
}

test "encoders lay frames out as V1 says" {
    var s: [SURFACE_LEN]u8 = undefined;
    encodeSurface(&s, .{ .pixel_w = 1920, .pixel_h = 1080, .logical_w = 1280, .logical_h = 720 });
    const sf = (try split(&s)).?;
    try t.expectEqual(@as(u8, 2), sf.tag);
    try t.expectEqual(@as(usize, 17), sf.body.len);
    try t.expectEqual(@as(u32, 1080), rd32(sf.body, 4));
    try t.expectEqual(FORMAT_BGRA_PREMUL, sf.body[16]);

    var d: [HEADER + DAMAGE_HEAD + 2 * 3 * 4]u8 = undefined;
    const r = Rect{ .x = 4, .y = 5, .w = 2, .h = 3 };
    try t.expectEqual(d.len, damageLen(r));
    const px = encodeDamageHead(&d, r);
    try t.expectEqual(@as(usize, 24), px.len);
    @memset(px, 0xab);
    const df = (try split(&d)).?;
    try t.expectEqual(@as(u32, 3), rd32(df.body, 12));
    try t.expectEqual(@as(usize, 16 + 24), df.body.len);

    var fe: [FRAME_END_LEN]u8 = undefined;
    encodeFrameEnd(&fe, 42);
    try t.expectEqual(@as(u64, 42), std.mem.readInt(u64, (try split(&fe)).?.body[0..8], .little));

    var cb: [64]u8 = undefined;
    const named = Cursor{ .named = "pointer" };
    encodeCursor(cb[0..cursorLen(named)], named);
    const cf = (try split(cb[0..cursorLen(named)])).?;
    try t.expectEqual(@as(u8, 1), cf.body[0]);
    try t.expectEqual(@as(u8, 0), cf.body[1]);
    try t.expectEqualStrings("pointer", cf.body[4..]);
    const img = Cursor{ .image = .{ .w = 1, .h = 1, .hot_x = -1, .hot_y = 0, .bgra = &.{ 1, 2, 3, 4 } } };
    encodeCursor(cb[0..cursorLen(img)], img);
    const imf = (try split(cb[0..cursorLen(img)])).?;
    try t.expectEqual(@as(u8, 1), imf.body[1]);
    try t.expectEqual(@as(i32, -1), rdI32(imf.body, 10));
    try t.expectEqual(@as(u8, 4), imf.body[imf.body.len - 1]);
    encodeCursor(cb[0..cursorLen(.hidden)], .hidden);
    try t.expectEqual(@as(u8, 0), (try split(cb[0..cursorLen(.hidden)])).?.body[0]);

    var ab: [64]u8 = undefined;
    encodeAudio(ab[0..audioLen(3)], 1_000_000, 48_000, 2, 960, &.{ 9, 8, 7 });
    const af = (try split(ab[0..audioLen(3)])).?;
    try t.expectEqual(@as(u16, 960), std.mem.readInt(u16, af.body[13..15], .little));
    try t.expectEqualSlices(u8, &.{ 9, 8, 7 }, af.body[15..]);
}

test "damage splits into bands under the band cap" {

    // A 4K full frame: every band within the cap, rows tiling the rect.
    var bands = Bands.init(.{ .x = 0, .y = 0, .w = 3840, .h = 2160 });
    var rows: u64 = 0;
    var n: usize = 0;
    while (bands.peek()) |b| : (bands.advance()) {
        try t.expect(@as(usize, b.w) * b.h * 4 <= MAX_BAND_BYTES);
        try t.expectEqual(@as(u32, 3840), b.w);
        rows += b.h;
        n += 1;
    }
    try t.expectEqual(@as(u64, 2160), rows);
    try t.expect(n > 1);

    // A row wider than a band splits columns too.
    var wide = Bands.init(.{ .x = 0, .y = 0, .w = 300_000, .h = 2 });
    var area: u64 = 0;
    while (wide.peek()) |b| : (wide.advance()) {
        try t.expect(@as(usize, b.w) * b.h * 4 <= MAX_BAND_BYTES);
        area += @as(u64, b.w) * b.h;
    }
    try t.expectEqual(@as(u64, 600_000), area);
}

test "held input is released on drain, buttons first at the last position" {
    var h: Held = .{};
    try t.expect(h.keyDown(0x10, 0xffe1));
    try t.expect(h.keyDown('A', 'A'));
    // The same key under another keysym (lowercase) is the same slot,
    // and its up clears it.
    try t.expect(h.keyDown('A', 'a'));
    try t.expectEqual(@as(usize, 2), h.nkeys);
    try t.expect(h.keyUp('A'));
    try t.expect(!h.keyUp('A'));
    h.pointer(.{ .action = .down, .x = 5, .y = 6, .button = 2, .clicks = 1, .mods = 0 });
    h.pointer(.{ .action = .move, .x = 7, .y = 8, .button = 0, .clicks = 0, .mods = 0 });
    try t.expectEqual(@as(u32, 1 << 6), h.cefButtons());
    var out: [Held.MAX_KEYS + 3]Held.Release = undefined;
    const rel = h.drain(&out);
    try t.expectEqual(@as(usize, 2), rel.len);
    try t.expectEqual(@as(u32, 0), h.cefButtons());
    try t.expectEqual(@as(u8, 2), rel[0].button.button);
    try t.expectEqual(@as(i32, 8), rel[0].button.y);
    try t.expectEqual(@as(u32, 0xffe1), rel[1].key);
    try t.expectEqual(@as(usize, 0), h.drain(&out).len);

    var full: Held = .{};
    for (0..Held.MAX_KEYS) |i| try t.expect(full.keyDown(@intCast(i + 1), @intCast(i + 1)));
    try t.expect(!full.keyDown(999, 999));
    // Ups by identity free slots again: no leak however keys alternate case.
    var cycle: Held = .{};
    for (0..100) |_| {
        try t.expect(cycle.keyDown('A', 'A'));
        try t.expect(cycle.keyUp('A'));
    }
    try t.expectEqual(@as(usize, 0), cycle.nkeys);
}

/// One table for the tests: a whole `AudioTable` is too large to build on
/// a test's stack.
var test_audio: AudioTable(2, 4096) = .{};

test "audio table takes CEF's real 1024-frame packets and longer ones" {
    const tab = &test_audio;
    const i = tab.claim().?;
    defer tab.unclaim(i);
    tab.bind(i, 3);
    tab.start(3, 48_000, 2);
    defer tab.stop(3);
    var l: [2500]f32 = @splat(0.25);
    var r: [2500]f32 = @splat(-0.25);
    const planes = [_][*]const f32{ &l, &r };
    tab.push(3, &planes, 1024, 1_791_382_245_089);
    try t.expectEqual(@as(usize, 1024), tab.queued(i));
    // Longer than the conversion scratch: split, and still contiguous.
    tab.push(3, &planes, 2500, 1_791_382_245_110);
    try t.expectEqual(@as(usize, 3524), tab.queued(i));
    var out: [1920]i16 = undefined;
    try t.expectEqual(@as(u64, 1_791_382_245_089_000), tab.pop(i, &out).?);
    try t.expectEqual(@as(i16, 8191), out[0]);
    try t.expectEqual(@as(i16, -8191), out[1]);
}

test "audio table hands whole 20ms frames over and drops what does not fit" {
    const Table = AudioTable(2, 1920);
    var tab: Table = .{};
    const i = tab.claim().?;
    tab.bind(i, 7);
    var l: [960]f32 = undefined;
    var r: [960]f32 = undefined;
    for (&l, &r, 0..) |*a, *b, k| {
        a.* = if (k % 2 == 0) 0.5 else -2.0;
        b.* = 0.0;
    }
    const planes = [_][*]const f32{ &l, &r };
    // Not started at 48k yet: nothing is kept.
    tab.push(7, &planes, 960, 1000);
    var out: [1920]i16 = undefined;
    try t.expect(tab.pop(i, &out) == null);

    try t.expectEqual(@as(u32, 0), tab.channelsOf(7));
    tab.start(7, 48_000, 2);
    try t.expectEqual(@as(u32, 2), tab.channelsOf(7));
    tab.push(7, &planes, 960, 1000);
    tab.push(8, &planes, 960, 1000); // another browser: not ours
    const pts = tab.pop(i, &out).?;
    try t.expectEqual(@as(u64, 1_000_000), pts);
    try t.expectEqual(@as(i16, 16383), out[0]);
    try t.expectEqual(@as(i16, -32767), out[2]);
    try t.expectEqual(@as(i16, 0), out[1]);
    try t.expect(tab.pop(i, &out) == null);

    // Capacity is 1920 frames: the third packet is dropped whole.
    tab.push(7, &planes, 960, 2000);
    tab.push(7, &planes, 960, 2020);
    tab.push(7, &planes, 960, 2040);
    try t.expectEqual(@as(u64, 960), tab.dropped(i));
    try t.expectEqual(@as(u64, 2_000_000), tab.pop(i, &out).?);
    // The next packet follows a drop: the queued one is discarded rather
    // than stitched to it under a contiguous timestamp.
    tab.push(7, &planes, 960, 2060);
    try t.expectEqual(@as(u64, 2_060_000), tab.pop(i, &out).?);
    try t.expect(tab.pop(i, &out) == null);
    // A timestamp jump (an engine stall) resets the queue the same way;
    // a contiguous follow-on does not.
    tab.push(7, &planes, 960, 5000);
    tab.push(7, &planes, 960, 5020);
    tab.push(7, &planes, 960, 5200);
    try t.expectEqual(@as(u64, 5_200_000), tab.pop(i, &out).?);
    try t.expect(tab.pop(i, &out) == null);

    // A capture outlives a stream: a slot bound later sees it at once.
    tab.unclaim(i);
    try t.expect(tab.capturing(7));
    const j = tab.claim().?;
    tab.bind(j, 7);
    tab.push(7, &planes, 960, 6000);
    try t.expectEqual(@as(u64, 6_000_000), tab.pop(j, &out).?);
    tab.push(7, &planes, 960, 6020);
    tab.flush(j);
    try t.expect(tab.pop(j, &out) == null);
    tab.stop(7);
    try t.expect(!tab.capturing(7));
    tab.push(7, &planes, 960, 7000);
    try t.expect(tab.pop(j, &out) == null);
    tab.unclaim(j);

    tab.unclaim(i);
    tab.push(7, &planes, 960, 3000);
    try t.expect(tab.pop(i, &out) == null);
    try t.expect(tab.claim() != null);
}
