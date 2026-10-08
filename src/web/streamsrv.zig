//! The socket half of the pushed per-view stream (capability
//! "web-stream"): one private listening socket per opened stream, one
//! authenticated client on it, served non-blocking from the helper's
//! own poll loop. CEF-free; what a stream shows and what its input does
//! come from a `Source` the engine glue (`cefhost/stream.zig`) supplies.
//!
//! Nothing here queues frames. Damage is merged in a `frameflow.Damage`
//! list and a frame is cut from the LIVE buffer only when the flow window
//! has room AND the bounded transmit buffer can take the next band, so
//! the newest pixels always win and a stalled reader costs a fixed
//! amount of memory.
//!
//! An encoded stream (capability "stream-encoded") hands pixels to a
//! `frameenc.Stream` instead, the same encoder and ack window as encoded
//! watch-along frames: it cuts one logical frame into `enc_out` only when
//! the previous one has been written whole, so at most one encoded frame
//! is ever buffered.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("cbindings");
const st = @import("stream.zig");
const frameflow = @import("frameflow.zig");
const Rect = frameflow.Rect;
const opus = @import("../mux/opuscodec.zig");
const proto = @import("protocol.zig");
const frameenc = @import("frameenc.zig");
const surfenc = @import("../wlhost/surfenc.zig");
const vcodec = @import("../wlhost/vcodec.zig");

/// Streams one helper serves at once; also the audio slot count.
pub const MAX_STREAMS = 16;
/// Half a second of 48kHz stereo per stream between capture and encode.
const AUDIO_CAP_FRAMES = 24_000;

pub const Audio = st.AudioTable(MAX_STREAMS, AUDIO_CAP_FRAMES);
/// Process-wide: the engine's capture thread pushes into it by browser
/// id, the poll loop pops by slot. Static so no capture callback can
/// outlive the memory it writes.
pub var audio: Audio = .{};

/// Samples per channel in one 20ms frame at `Audio.RATE`.
const OPUS_FRAME = Audio.RATE / 50;

/// Inbound bytes buffered before the helper stops reading (the client
/// then blocks on its own socket), and read per poll turn.
const IN_CAP = 64 * 1024;
/// Client frames dispatched per poll turn, and Text bytes among them:
/// a client flooding input gets a fixed share of the loop, never all of
/// it, and the rest waits in the buffer for the next turn.
const EVENTS_PER_TURN = 64;
const TEXT_BYTES_PER_TURN = 16 * 1024;

/// Largest single message: one damage band.
const MAX_MSG = st.HEADER + st.DAMAGE_HEAD + st.MAX_BAND_BYTES;
/// Bounded transmit buffer: two bands' worth, so the next band is
/// encoded while the previous one drains.
const TX_CAP = 2 * MAX_MSG;

/// Whether the page's audio can be streamed at all in this process.
pub fn audioAvailable() bool {
    return opus.enabled and opus.available();
}

/// What a stream shows and where its input goes; the engine glue.
pub const Source = struct {
    ctx: *anyopaque,
    /// The view's paintable surface right now, or null while it has
    /// none (no buffer, not painted yet, browser discarded).
    surface: *const fn (ctx: *anyopaque, view: u32) ?st.Surface,
    /// Copy `r` (pixels, inside the surface) of the composed live frame
    /// into `dst`, packed `r.w * 4` bytes per row.
    compose: *const fn (ctx: *anyopaque, view: u32, r: Rect, dst: []u8) void,
    /// One validated input frame; never `auth` or `ack`.
    input: *const fn (ctx: *anyopaque, s: *Stream, in: st.Input) void,
    /// The view's current cursor, read when the Cursor frame is cut;
    /// borrowed for that one encode.
    cursor: *const fn (ctx: *anyopaque, view: u32) st.Cursor,
    /// The whole live surface for an encoded cut, or null while it has
    /// none (exactly when `surface` is null).
    live: *const fn (ctx: *anyopaque, view: u32) ?Live,
};

/// The live tight BGRA surface of a view and its paint counter.
pub const Live = struct {
    map: []const u8,
    gen: u32,
    /// Something is composed over `map` (a `<select>` popup): the cut
    /// reads the surface through `compose` instead.
    overlay: bool,
};

/// An encoded stream's choice at open: the client's view id (what its
/// ENCODED frames carry), the codecs it decodes in preference order
/// (`vcodec.Codec` ids, empty = lossless only), what this process encodes
/// and how an encoder is opened.
pub const Encode = struct {
    wire_view: u32,
    codecs: []const u8,
    encodable: vcodec.CodecList,
    open: surfenc.Opener,
};

pub const OpenError = error{ NoDirectory, PathTooLong, NoEntropy, SocketFailed, OutOfMemory };

/// A view's current cursor, owned by the VIEW (not by its stream), so a
/// stream opened later starts from what the page shows now and a custom
/// image exists once, however many times the engine re-reports it.
pub const CursorCache = struct {
    kind: enum { hidden, named, image } = .named,
    name: [32]u8 = undefined,
    /// 0 means the engine has reported nothing yet: "default".
    name_len: usize = 0,
    image: []u8 = &.{},
    w: u32 = 0,
    h: u32 = 0,
    hot_x: i32 = 0,
    hot_y: i32 = 0,

    pub fn view(self: *const CursorCache) st.Cursor {
        return switch (self.kind) {
            .hidden => .hidden,
            .named => .{ .named = if (self.name_len == 0) "default" else self.name[0..self.name_len] },
            .image => .{ .image = .{ .w = self.w, .h = self.h, .hot_x = self.hot_x, .hot_y = self.hot_y, .bgra = self.image } },
        };
    }

    /// Record `cur`; whether it differs from what was cached. The engine
    /// re-reports an unchanged custom cursor on every move, and that
    /// must cost neither a copy nor a frame.
    pub fn set(self: *CursorCache, gpa: std.mem.Allocator, cur: st.Cursor) bool {
        if (std.meta.activeTag(cur) == std.meta.activeTag(self.view())) {
            switch (cur) {
                .hidden => return false,
                .named => |n| if (std.mem.eql(u8, n, self.view().named)) return false,
                .image => |im| if (im.w == self.w and im.h == self.h and im.hot_x == self.hot_x and
                    im.hot_y == self.hot_y and std.mem.eql(u8, im.bgra, self.image)) return false,
            }
        }
        switch (cur) {
            .hidden => {
                self.freeImage(gpa);
                self.kind = .hidden;
            },
            .named => |n| {
                self.freeImage(gpa);
                const len = @min(n.len, self.name.len);
                @memcpy(self.name[0..len], n[0..len]);
                self.name_len = len;
                self.kind = .named;
            },
            .image => |im| {
                // Out of memory degrades to the plain arrow, never to a
                // stale image.
                const copy = gpa.dupe(u8, im.bgra) catch {
                    self.freeImage(gpa);
                    self.kind = .named;
                    self.name_len = 0;
                    return true;
                };
                self.freeImage(gpa);
                self.* = .{ .kind = .image, .image = copy, .w = im.w, .h = im.h, .hot_x = im.hot_x, .hot_y = im.hot_y };
            },
        }
        return true;
    }

    fn freeImage(self: *CursorCache, gpa: std.mem.Allocator) void {
        if (self.image.len != 0) gpa.free(self.image);
        self.image = &.{};
    }

    pub fn deinit(self: *CursorCache, gpa: std.mem.Allocator) void {
        self.freeImage(gpa);
        self.* = .{};
    }
};

pub const Stream = struct {
    gpa: std.mem.Allocator,
    /// Engine-global view id and the connection that opened the stream.
    view: u32,
    owner: u32,
    path_buf: [108]u8 = undefined,
    path_len: usize = 0,
    listen_fd: c_int = -1,
    fd: c_int = -1,
    token: [st.TOKEN_LEN]u8,
    authed: bool = false,
    /// Monotonic ms by which the client must have authenticated.
    deadline_ms: i64,
    /// Why the stream ended; set once, reaped by the glue.
    closed: ?[]const u8 = null,
    in: std.ArrayList(u8) = .empty,
    tx: []u8,
    tx_head: usize = 0,
    tx_len: usize = 0,
    flow: st.Flow = .{},
    dirty: frameflow.Damage = .{},
    /// The frame being cut: its damage rects, and the bands of the one
    /// at `frame_next - 1`; null `bands` means no frame in progress.
    frame: [frameflow.Damage.MAX_RECTS]Rect = undefined,
    frame_n: usize = 0,
    frame_next: usize = 0,
    bands: ?st.Bands = null,
    /// At least one band of the frame in `bands` is already queued, so
    /// that frame must be ENDED before anything resets the surface.
    frame_open: bool = false,
    announced: ?st.Surface = null,
    /// The client still needs the view's current cursor (set at AUTH and
    /// on every change; the pixels live in the view's `CursorCache`).
    cursor_pending: bool = true,
    held: st.Held = .{},
    audio_slot: ?usize = null,
    /// Set only while audio is actually encoded: what the open reports.
    encoder: ?opus.Encoder = null,
    /// Set for an encoded stream: pixels go through it, never `dirty`.
    enc: ?*frameenc.Stream = null,
    /// The client's id for the view, carried by ENCODED frames.
    wire_view: u32 = 0,
    /// ENCODED messages of the logical frame being written, in stream
    /// framing; empty before the next frame is cut.
    enc_out: proto.Outbox,
    /// The surface with its popup composed, for a cut while one shows.
    composed: std.ArrayList(u8) = .empty,

    pub fn path(self: *const Stream) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Bind a fresh 0600 socket under `dir` with a random name and mint
    /// the token that alone may use it; `encode` makes it an encoded stream.
    pub fn open(gpa: std.mem.Allocator, dir: []const u8, view: u32, owner: u32, want_audio: bool, encode: ?Encode, now_ms: i64) OpenError!*Stream {
        if (dir.len == 0) return error.NoDirectory;
        // Token and socket name from DISJOINT random bytes: the name is
        // visible to anyone who can list the directory.
        var rnd: [32]u8 = undefined;
        if (c.getentropy(&rnd, rnd.len) != 0) return error.NoEntropy;
        const tx = try gpa.alloc(u8, TX_CAP);
        errdefer gpa.free(tx);
        const s = try gpa.create(Stream);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .view = view,
            .owner = owner,
            .token = st.mintToken(rnd[0..16].*),
            .deadline_ms = now_ms + proto.STREAM_CONNECT_MS,
            .tx = tx,
            .enc_out = proto.Outbox.init(gpa),
        };
        const name = st.mintToken(rnd[16..32].*);
        const p = std.fmt.bufPrint(s.path_buf[0 .. s.path_buf.len - 1], "{s}/ws-{s}.sock", .{ std.mem.trimEnd(u8, dir, "/"), name[0..16] }) catch
            return error.PathTooLong;
        s.path_len = p.len;
        s.path_buf[p.len] = 0;
        try s.bind();
        errdefer s.closeListener();
        if (encode) |e| {
            const enc = try gpa.create(frameenc.Stream);
            enc.* = frameenc.Stream.init(gpa, e.open);
            // An ENCODED frame must fit the stream's own frame cap.
            enc.limits = frameenc.Limits.within(st.MAX_FRAME);
            // The surface is unknown until the first SURFACE; that
            // announcement restarts the stream at a keyframe.
            enc.configure(e.codecs, e.encodable, 0, 0);
            s.enc = enc;
            s.wire_view = e.wire_view;
        }
        // The audio slot exists from the open on, not from AUTH: the
        // engine asks once, when the page becomes audible, and a page
        // that does so before the client authenticated must still be
        // captured.
        if (want_audio and audioAvailable()) s.startAudio();
        return s;
    }

    fn bind(self: *Stream) OpenError!void {
        var addr = std.mem.zeroes(c.struct_sockaddr_un);
        if (self.path_len + 1 > @sizeOf(@TypeOf(addr.sun_path))) return error.PathTooLong;
        addr.sun_family = c.AF_UNIX;
        @memcpy(addr.sun_path[0..self.path_len], self.path());
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
        // No umask: it is process-wide, and a directory one of CEF's own
        // threads created inside the window would come out unusable. The
        // node is chmod'ed 0600 right after bind; until then it sits in
        // the instance's private directory under a random name, and a
        // connection still needs the token.
        const rc = c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un));
        if (rc != 0 or c.chmod(@ptrCast(&self.path_buf), 0o600) != 0 or c.listen(fd, 1) != 0) {
            _ = c.close(fd);
            _ = c.unlink(@ptrCast(&self.path_buf));
            return error.SocketFailed;
        }
        self.listen_fd = fd;
    }

    /// Close every descriptor and free everything; the glue has already
    /// drained `held` and announced the end.
    pub fn deinit(self: *Stream) void {
        self.shut("the stream was freed");
        self.in.deinit(self.gpa);
        self.gpa.free(self.tx);
        if (self.enc) |e| {
            e.deinit();
            self.gpa.destroy(e);
        }
        self.enc_out.deinit();
        self.composed.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// How this stream carries pixels: what the open reports.
    pub fn encoding(self: *const Stream) proto.StreamEncoding {
        return if (self.enc != null) .encoded else .raw;
    }

    /// The video codec an encoded stream negotiated; null = lossless only.
    pub fn codec(self: *const Stream) ?vcodec.Codec {
        return (self.enc orelse return null).codec;
    }

    /// End the stream with `reason` (the first reason wins). Descriptors
    /// go now; the record stays until the glue reaps it.
    pub fn shut(self: *Stream, reason: []const u8) void {
        if (self.closed == null) self.closed = reason;
        self.closeListener();
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        if (self.audio_slot) |slot| {
            audio.unclaim(slot);
            self.audio_slot = null;
        }
        if (self.encoder) |*e| {
            e.deinit();
            self.encoder = null;
        }
    }

    /// The listener and its socket file: gone the moment the token is
    /// spent, so nobody else can even connect.
    fn closeListener(self: *Stream) void {
        if (self.listen_fd < 0) return;
        _ = c.close(self.listen_fd);
        self.listen_fd = -1;
        _ = c.unlink(@ptrCast(&self.path_buf));
    }

    /// The descriptor the server should poll, and for what.
    pub fn pollFd(self: *const Stream) ?c.struct_pollfd {
        if (self.closed != null) return null;
        if (self.fd >= 0) return .{
            .fd = self.fd,
            .events = @as(c_short, c.POLLIN) | (if (self.tx_len != 0 or !self.enc_out.empty()) @as(c_short, c.POLLOUT) else @as(c_short, 0)),
            .revents = 0,
        };
        if (self.listen_fd >= 0) return .{ .fd = self.listen_fd, .events = c.POLLIN, .revents = 0 };
        return null;
    }

    /// One paint of the `w`x`h` surface damaged `rects` (any x/y/w/h
    /// rects, surface pixels).
    pub fn paint(self: *Stream, w: u32, h: u32, rects: anytype) void {
        if (self.enc) |e| return e.paint(@intCast(w), @intCast(h), rects);
        self.dirty.addAll(rects);
    }

    /// The view's cursor changed; the newest one is what the client gets.
    pub fn markCursor(self: *Stream) void {
        self.cursor_pending = true;
    }

    /// One poll turn: accept, read and dispatch input, cut and write
    /// output. Never blocks; every failure ends the stream with a reason.
    pub fn service(self: *Stream, src: Source, now_ms: i64) void {
        if (self.closed != null) return;
        if (!self.authed and now_ms >= self.deadline_ms) return self.shut("no client authenticated in time");
        if (self.fd < 0) self.accept();
        if (self.fd < 0 or self.closed != null) return;
        self.readIn();
        if (self.closed != null) return;
        // Dispatch even with nothing new read: a previous turn may have
        // left frames over its budget.
        if (!self.consume(src)) return;
        if (self.authed) self.produce(src);
        self.flush();
    }

    fn accept(self: *Stream) void {
        if (self.listen_fd < 0) return;
        const fd = c.accept(self.listen_fd, null, null);
        if (fd < 0) return;
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
        self.fd = fd;
    }

    /// Read at most what fits under `IN_CAP`; one call per turn.
    fn readIn(self: *Stream) void {
        var buf: [IN_CAP]u8 = undefined;
        while (self.in.items.len < IN_CAP) {
            const want = IN_CAP - self.in.items.len;
            const n = c.read(self.fd, &buf, want);
            if (n == 0) return self.shut("the stream client disconnected");
            if (n < 0) {
                const e = std.c._errno().*;
                if (e == c.EAGAIN or e == c.EWOULDBLOCK) break;
                if (e == c.EINTR) continue;
                return self.shut("the stream socket failed");
            }
            self.in.appendSlice(self.gpa, buf[0..@intCast(n)]) catch return self.shut("out of memory reading the stream");
            if (@as(usize, @intCast(n)) < want) break;
        }
    }

    /// Dispatch the complete frames buffered so far, within this turn's
    /// budget; false once the stream ended.
    fn consume(self: *Stream, src: Source) bool {
        var used: usize = 0;
        var events: usize = 0;
        var text_bytes: usize = 0;
        defer if (self.closed == null and used != 0) {
            const rest = self.in.items.len - used;
            std.mem.copyForwards(u8, self.in.items[0..rest], self.in.items[used..]);
            self.in.shrinkRetainingCapacity(rest);
        };
        while (events < EVENTS_PER_TURN and text_bytes < TEXT_BYTES_PER_TURN) {
            const raw = (st.splitMax(self.in.items[used..], st.MAX_CLIENT_FRAME) catch {
                self.shut("malformed stream frame");
                return false;
            }) orelse return true;
            // A Text that would take this turn past its byte budget waits
            // for the next turn, unless it is the turn's first (one frame
            // is at most MAX_TEXT, so progress is always made).
            if (raw.tag == @intFromEnum(st.Tag.text) and text_bytes != 0 and text_bytes + raw.body.len > TEXT_BYTES_PER_TURN) return true;
            used += raw.len;
            events += 1;
            const in = st.decode(raw.tag, raw.body) catch |err| {
                self.shut(switch (err) {
                    error.UnknownTag => "unknown stream frame",
                    error.BadLength => "stream frame has the wrong length",
                    error.BadValue => "stream frame value out of range",
                    error.BadUtf8 => "stream frame text is not UTF-8",
                });
                return false;
            };
            if (!self.authed) {
                // The token is spent by the first frame, right or wrong:
                // one attempt per open.
                const ok = in == .auth and st.tokenEql(&in.auth, &self.token);
                self.token = @splat(0);
                self.closeListener();
                if (!ok) {
                    self.shut("stream authentication failed");
                    return false;
                }
                self.authed = true;
                if (self.audio_slot) |slot| audio.flush(slot);
                self.dirty.clear();
                self.announced = null;
                self.cursor_pending = true;
                continue;
            }
            switch (in) {
                .auth => {
                    self.shut("second authentication on the stream");
                    return false;
                },
                // An encoded stream takes frameenc's cumulative ACK, which
                // ignores a serial it no longer waits for (a frame it could
                // not queue whole is abandoned and resent from a keyframe).
                .ack => |serial| if (self.enc) |e| e.ack(serial) else self.flow.ack(serial) catch {
                    self.shut("stream ACK names no unacknowledged frame");
                    return false;
                },
                else => {
                    if (in == .text) text_bytes += in.text.len;
                    src.input(src.ctx, self, in);
                    if (self.closed != null) return false;
                },
            }
        }
        return true;
    }

    fn startAudio(self: *Stream) void {
        const slot = audio.claim() orelse return;
        self.encoder = opus.Encoder.init(Audio.RATE, Audio.CHANNELS) orelse return audio.unclaim(slot);
        self.audio_slot = slot;
    }

    /// Bytes the transmit buffer can take once its sent head is
    /// compacted away (what `reserve` will actually find).
    fn freeRoom(self: *const Stream) usize {
        return self.tx.len - (self.tx_len - self.tx_head);
    }

    /// Bytes the transmit buffer can still take.
    fn room(self: *const Stream) usize {
        return self.tx.len - self.tx_len;
    }

    /// A contiguous `n`-byte region at the end of the transmit buffer,
    /// or null when it does not fit (the caller then waits a turn).
    fn reserve(self: *Stream, n: usize) ?[]u8 {
        if (self.tx_head != 0) {
            std.mem.copyForwards(u8, self.tx[0 .. self.tx_len - self.tx_head], self.tx[self.tx_head..self.tx_len]);
            self.tx_len -= self.tx_head;
            self.tx_head = 0;
        }
        if (n > self.room()) return null;
        defer self.tx_len += n;
        return self.tx[self.tx_len..][0..n];
    }

    /// Order: surface (it resets the client), cursor, audio, then the
    /// frame in progress or a new one.
    fn produce(self: *Stream, src: Source) void {
        const surf = src.surface(src.ctx, self.view);
        if (surf) |sf| {
            const same = if (self.announced) |a| std.meta.eql(a, sf) else false;
            // An encoded frame is announced only once its messages are all
            // written: a client never sees SURFACE inside a logical frame.
            if (!same and self.enc != null and !self.enc_out.empty()) return;
            if (!same) {
                // A frame whose bands already went out is closed FIRST,
                // with its own serial: a client must never see Surface
                // while damage is pending, and that damage must be
                // acknowledgeable. Its remaining bands are moot (the old
                // surface is gone). FrameEnd and Surface are reserved as
                // ONE block, so the pair can never be split across turns.
                // A frame with nothing sent yet ends silently.
                const end_old = self.bands != null and self.frame_open;
                const need: usize = st.SURFACE_LEN + @as(usize, if (end_old) st.FRAME_END_LEN else 0);
                const dst = self.reserve(need) orelse return;
                var off: usize = 0;
                if (end_old) {
                    st.encodeFrameEnd(dst[0..st.FRAME_END_LEN], self.flow.sent());
                    off = st.FRAME_END_LEN;
                }
                st.encodeSurface(dst[off..][0..st.SURFACE_LEN], sf);
                self.announced = sf;
                self.bands = null;
                self.frame_open = false;
                if (self.enc) |e| e.restart(@intCast(sf.pixel_w), @intCast(sf.pixel_h)) else self.dirty.full(sf.pixel_w, sf.pixel_h);
            }
        }
        if (self.cursor_pending) {
            const cur = src.cursor(src.ctx, self.view);
            if (self.reserve(st.cursorLen(cur))) |dst| {
                st.encodeCursor(dst, cur);
                self.cursor_pending = false;
            }
        }
        self.produceAudio();
        const sf = self.announced orelse return;
        if (surf == null) return;
        if (self.enc) |e| return self.produceEncoded(src, e, sf);
        if (self.bands == null) {
            if (!self.flow.canSend()) return;
            const rects = self.dirty.take(sf.pixel_w, sf.pixel_h, &self.frame);
            if (rects.len == 0) return;
            self.frame_n = rects.len;
            self.frame_next = 1;
            self.bands = st.Bands.init(rects[0]);
        }
        // One band run per damage rect, all in this one frame.
        while (true) {
            const bands = &self.bands.?;
            while (bands.peek()) |b| {
                const dst = self.reserve(st.damageLen(b)) orelse return;
                src.compose(src.ctx, self.view, b, st.encodeDamageHead(dst, b));
                bands.advance();
                self.frame_open = true;
            }
            if (self.frame_next == self.frame_n) break;
            self.bands = st.Bands.init(self.frame[self.frame_next]);
            self.frame_next += 1;
        }
        const dst = self.reserve(st.FRAME_END_LEN) orelse return;
        st.encodeFrameEnd(dst[0..st.FRAME_END_LEN], self.flow.sent());
        self.bands = null;
        self.frame_open = false;
    }

    /// Cut the next logical encoded frame once the previous one is
    /// written whole and the ack window has room.
    fn produceEncoded(self: *Stream, src: Source, e: *frameenc.Stream, sf: st.Surface) void {
        if (!self.enc_out.empty() or !e.ready()) return;
        const live = src.live(src.ctx, self.view) orelse return;
        var pixels = live.map;
        if (live.overlay) {
            const full: Rect = .{ .x = 0, .y = 0, .w = sf.pixel_w, .h = sf.pixel_h };
            self.composed.resize(self.gpa, @as(usize, sf.pixel_w) * sf.pixel_h * 4) catch return;
            src.compose(src.ctx, self.view, full, self.composed.items);
            pixels = self.composed.items;
        }
        e.cut(&self.enc_out, self.wire_view, live.gen, pixels, @intCast(sf.pixel_w), @intCast(sf.pixel_h));
        // Each message is a control-protocol `frame_encoded` frame: the
        // same u32 length (tag included) and payload as the stream's own
        // framing, so only the tag byte differs.
        for (self.enc_out.queue.items[self.enc_out.head..]) |m| m.bytes[4] = @intFromEnum(st.Tag.encoded);
    }

    /// Encode every whole 20ms frame the capture thread handed over. A
    /// packet that does not fit is dropped: audio is never queued here.
    fn produceAudio(self: *Stream) void {
        const slot = self.audio_slot orelse return;
        const enc = if (self.encoder) |*e| e else return;
        var pcm: [OPUS_FRAME * 2]i16 = undefined;
        var packet: [opus.MAX_PACKET]u8 = undefined;
        // Pop only while a packet of ANY size still fits: a popped frame
        // that cannot be sent is lost, while one left queued waits in the
        // bounded ring (whose overflow is honest about the gap).
        while (self.freeRoom() >= st.audioLen(opus.MAX_PACKET)) {
            const pts = audio.pop(slot, &pcm) orelse break;
            const out = enc.encode(std.mem.sliceAsBytes(&pcm), &packet) orelse continue;
            const dst = self.reserve(st.audioLen(out.len)) orelse continue;
            st.encodeAudio(dst, pts, Audio.RATE, Audio.CHANNELS, OPUS_FRAME, out);
        }
    }

    /// Write what is pending without ever splitting a frame: a partly
    /// written ENCODED message finishes first, then the transmit buffer,
    /// then the encoded frame's remaining messages.
    fn flush(self: *Stream) void {
        if (self.enc_out.sent != 0 and !self.flushEncoded(true)) return;
        if (!self.flushTx()) return;
        _ = self.flushEncoded(false);
    }

    /// Whether the transmit buffer drained completely.
    fn flushTx(self: *Stream) bool {
        while (self.tx_head < self.tx_len) {
            const n = self.sendSome(self.tx[self.tx_head..self.tx_len]) orelse return false;
            self.tx_head += n;
        }
        self.tx_head = 0;
        self.tx_len = 0;
        return true;
    }

    /// Whether `enc_out` drained (just its front message when `one`).
    fn flushEncoded(self: *Stream, one: bool) bool {
        while (self.enc_out.front()) |m| {
            const n = self.sendSome(m.bytes) orelse return false;
            self.enc_out.advance(n);
            if (one and self.enc_out.sent == 0) return true;
        }
        return true;
    }

    /// Bytes of `bytes` the socket took; null when it takes no more this
    /// turn (or the stream ended).
    fn sendSome(self: *Stream, bytes: []const u8) ?usize {
        while (true) {
            const n = c.send(self.fd, bytes.ptr, bytes.len, send_flags);
            if (n >= 0) return @intCast(n);
            const e = std.c._errno().*;
            if (e == c.EAGAIN or e == c.EWOULDBLOCK) return null;
            if (e == c.EINTR) continue;
            self.shut("the stream client disconnected");
            return null;
        }
    }
};

/// No SIGPIPE for a reader that vanished mid-write, where the platform
/// can say so per call.
const send_flags: c_int = if (@hasDecl(c, "MSG_NOSIGNAL")) c.MSG_NOSIGNAL else 0;

// -- tests ----------------------------------------------------------------

const t = std.testing;

/// A fake engine: a solid surface whose pixels encode their position,
/// recording every input it is handed.
const Fake = struct {
    surf: ?st.Surface = .{ .pixel_w = 8, .pixel_h = 4, .logical_w = 8, .logical_h = 4 },
    inputs: std.ArrayList(st.Input) = .empty,
    texts: std.ArrayList(u8) = .empty,
    cur: CursorCache = .{},
    /// The live surface `live` hands out, rebuilt from `compose` each call.
    px: std.ArrayList(u8) = .empty,
    gen: u32 = 0,
    /// Blue channel of every pixel, so a test can change the page.
    tint: u8 = 0,
    noise: bool = false,

    fn source(self: *Fake) Source {
        return .{ .ctx = self, .surface = surface, .compose = compose, .input = input, .cursor = cursor, .live = live };
    }

    fn live(ctx: *anyopaque, view: u32) ?Live {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const sf = self.surf orelse return null;
        self.px.resize(t.allocator, @as(usize, sf.pixel_w) * sf.pixel_h * 4) catch return null;
        compose(ctx, view, .{ .x = 0, .y = 0, .w = sf.pixel_w, .h = sf.pixel_h }, self.px.items);
        self.gen += 1;
        return .{ .map = self.px.items, .gen = self.gen, .overlay = false };
    }

    fn cursor(ctx: *anyopaque, _: u32) st.Cursor {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.cur.view();
    }

    fn surface(ctx: *anyopaque, _: u32) ?st.Surface {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.surf;
    }

    fn compose(ctx: *anyopaque, _: u32, r: Rect, dst: []u8) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        var i: usize = 0;
        for (0..r.h) |y| for (0..r.w) |x| {
            const px = r.x + x;
            const py = r.y + y;
            if (self.noise) {
                // Incompressible: a hash of the position.
                const hsh = std.hash.int(@as(u32, @intCast(py * 65536 + px)));
                dst[i] = @truncate(hsh);
                dst[i + 1] = @truncate(hsh >> 8);
                dst[i + 2] = @truncate(hsh >> 16);
            } else {
                dst[i] = @truncate(px);
                dst[i + 1] = @truncate(py);
                dst[i + 2] = self.tint;
            }
            dst[i + 3] = 255;
            i += 4;
        };
    }

    fn input(ctx: *anyopaque, s: *Stream, in: st.Input) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        switch (in) {
            .key => |k| if (k.action == .down) {
                _ = s.held.keyDown(k.name[0], k.name[0]);
            } else {
                _ = s.held.keyUp(k.name[0]);
            },
            .pointer => |p| s.held.pointer(p),
            .text => |txt| self.texts.appendSlice(t.allocator, txt) catch {},
            else => {},
        }
        self.inputs.append(t.allocator, in) catch {};
    }
};

fn tmpDir(buf: []u8) ![]const u8 {
    var rnd: [16]u8 = @splat(0);
    _ = c.getentropy(&rnd, 4);
    const tok = st.mintToken(rnd);
    const d = try std.fmt.bufPrintZ(buf, "/tmp/skst-{s}", .{tok[0..8]});
    if (c.mkdir(d.ptr, 0o700) != 0) return error.MkdirFailed;
    return d;
}

fn connectTo(path: []const u8) !c_int {
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    @memcpy(addr.sun_path[0..path.len], path);
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.Socket;
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
        _ = c.close(fd);
        return error.Connect;
    }
    _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
    return fd;
}

fn sendFrame(fd: c_int, tag: st.Tag, body: []const u8) !void {
    var hdr: [5]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(body.len + 1), .little);
    hdr[4] = @intFromEnum(tag);
    if (c.write(fd, &hdr, 5) != 5) return error.Write;
    if (body.len != 0 and c.write(fd, body.ptr, body.len) != @as(isize, @intCast(body.len))) return error.Write;
}

/// Everything the helper wrote so far, split into frames.
const Reader = struct {
    buf: std.ArrayList(u8) = .empty,
    pos: usize = 0,

    fn pull(self: *Reader, fd: c_int) void {
        var tmp: [64 * 1024]u8 = undefined;
        while (true) {
            const n = c.read(fd, &tmp, tmp.len);
            if (n <= 0) return;
            self.buf.appendSlice(t.allocator, tmp[0..@intCast(n)]) catch return;
        }
    }

    fn next(self: *Reader) ?st.Raw {
        const raw = (st.split(self.buf.items[self.pos..]) catch return null) orelse return null;
        self.pos += raw.len;
        return raw;
    }
};

test "stream: auth, first full frame, two-frame window, held release, bad token" {
    var dbuf: [64]u8 = undefined;
    const dir = try tmpDir(&dbuf);
    defer _ = c.rmdir(@ptrCast(dir.ptr));
    var fake: Fake = .{};
    defer fake.inputs.deinit(t.allocator);
    defer fake.texts.deinit(t.allocator);

    const s = try Stream.open(t.allocator, dir, 5, 1, false, null, 0);
    defer s.deinit();
    // The node exists, is a socket, and is private.
    var stb: c.struct_stat = undefined;
    try t.expectEqual(@as(c_int, 0), c.stat(@ptrCast(&s.path_buf), &stb));
    try t.expectEqual(@as(c_uint, 0o600), @as(c_uint, @intCast(stb.st_mode)) & 0o777);
    try t.expect(st.isToken(&s.token));
    const token = s.token;

    const fd = try connectTo(s.path());
    defer _ = c.close(fd);
    s.service(fake.source(), 1);
    try t.expect(!s.authed);
    try sendFrame(fd, .auth, &token);
    s.service(fake.source(), 2);
    try t.expect(s.authed);
    // The token is spent and the socket file gone.
    try t.expect(s.listen_fd < 0);
    try t.expect(c.stat(@ptrCast(&s.path_buf), &stb) != 0);

    var rd: Reader = .{};
    defer rd.buf.deinit(t.allocator);
    rd.pull(fd);
    const surf = rd.next().?;
    try t.expectEqual(@as(u8, 2), surf.tag);
    try t.expectEqual(@as(u8, 5), rd.next().?.tag); // cursor
    const dmg = rd.next().?;
    try t.expectEqual(@as(u8, 3), dmg.tag);
    try t.expectEqual(@as(u32, 8), std.mem.readInt(u32, dmg.body[8..12], .little));
    try t.expectEqual(@as(usize, 16 + 8 * 4 * 4), dmg.body.len);
    // Pixel (3,2) carries its own coordinates.
    try t.expectEqual(@as(u8, 3), dmg.body[16 + (2 * 8 + 3) * 4]);
    try t.expectEqual(@as(u8, 2), dmg.body[16 + (2 * 8 + 3) * 4 + 1]);
    const fe1 = rd.next().?;
    try t.expectEqual(@as(u8, 4), fe1.tag);
    try t.expectEqual(@as(u64, 1), std.mem.readInt(u64, fe1.body[0..8], .little));

    // Two frames may be in flight, the third waits for an ACK and then
    // carries what was damaged meanwhile, near rects merged.
    s.paint(8, 4, &[_]Rect{.{ .x = 0, .y = 0, .w = 1, .h = 1 }});
    s.service(fake.source(), 3);
    s.paint(8, 4, &[_]Rect{.{ .x = 1, .y = 1, .w = 1, .h = 1 }});
    s.service(fake.source(), 4);
    s.paint(8, 4, &[_]Rect{.{ .x = 6, .y = 3, .w = 1, .h = 1 }});
    s.service(fake.source(), 5);
    rd.pull(fd);
    try t.expectEqual(@as(u8, 3), rd.next().?.tag);
    const fe2 = rd.next().?;
    try t.expectEqual(@as(u64, 2), std.mem.readInt(u64, fe2.body[0..8], .little));
    try t.expect(rd.next() == null);
    var ack: [8]u8 = undefined;
    std.mem.writeInt(u64, &ack, 1, .little);
    try sendFrame(fd, .ack, &ack);
    s.service(fake.source(), 6);
    rd.pull(fd);
    const d3 = rd.next().?;
    try t.expectEqual(@as(u8, 3), d3.tag);
    try t.expectEqual(Rect{ .x = 1, .y = 1, .w = 6, .h = 3 }, Rect{
        .x = std.mem.readInt(u32, d3.body[0..4], .little),
        .y = std.mem.readInt(u32, d3.body[4..8], .little),
        .w = std.mem.readInt(u32, d3.body[8..12], .little),
        .h = std.mem.readInt(u32, d3.body[12..16], .little),
    });
    try t.expectEqual(@as(u8, 4), rd.next().?.tag);

    // Input reaches the source; held state is what the glue drains.
    var key: [8]u8 = undefined;
    key[0] = 0;
    std.mem.writeInt(u32, key[1..5], 0, .little);
    std.mem.writeInt(u16, key[5..7], 1, .little);
    key[7] = 'x';
    try sendFrame(fd, .key, &key);
    try sendFrame(fd, .text, "h\xc3\xa9");
    s.service(fake.source(), 7);
    try t.expectEqualStrings("h\xc3\xa9", fake.texts.items);
    try t.expectEqual(@as(usize, 1), s.held.nkeys);

    // A resize of the surface re-announces it and repaints it whole.
    fake.surf = .{ .pixel_w = 4, .pixel_h = 2, .logical_w = 4, .logical_h = 2 };
    std.mem.writeInt(u64, &ack, 3, .little);
    try sendFrame(fd, .ack, &ack);
    s.service(fake.source(), 8);
    rd.pull(fd);
    try t.expectEqual(@as(u8, 2), rd.next().?.tag);
    const d4 = rd.next().?;
    try t.expectEqual(@as(u32, 4), std.mem.readInt(u32, d4.body[8..12], .little));

    // An ACK naming nothing in flight ends the stream.
    std.mem.writeInt(u64, &ack, 99, .little);
    try sendFrame(fd, .ack, &ack);
    s.service(fake.source(), 9);
    try t.expectEqualStrings("stream ACK names no unacknowledged frame", s.closed.?);

    // A wrong token spends the open: the listener is gone afterwards.
    const s2 = try Stream.open(t.allocator, dir, 6, 1, false, null, 0);
    defer s2.deinit();
    const fd2 = try connectTo(s2.path());
    defer _ = c.close(fd2);
    var wrong = s2.token;
    wrong[0] = if (wrong[0] == 'a') 'b' else 'a';
    try sendFrame(fd2, .auth, &wrong);
    s2.service(fake.source(), 1);
    try t.expectEqualStrings("stream authentication failed", s2.closed.?);
    try t.expect(c.stat(@ptrCast(&s2.path_buf), &stb) != 0);

    // Nobody connecting within the window closes it too.
    const s3 = try Stream.open(t.allocator, dir, 7, 1, false, null, 0);
    defer s3.deinit();
    s3.service(fake.source(), @import("protocol.zig").STREAM_CONNECT_MS);
    try t.expectEqualStrings("no client authenticated in time", s3.closed.?);
}

test "stream: far-apart damage is two band runs in ONE frame, not their bounding box" {
    var dbuf: [64]u8 = undefined;
    const dir = try tmpDir(&dbuf);
    defer _ = c.rmdir(@ptrCast(dir.ptr));
    var fake: Fake = .{ .surf = .{ .pixel_w = 200, .pixel_h = 100, .logical_w = 200, .logical_h = 100 } };
    defer fake.inputs.deinit(t.allocator);
    defer fake.texts.deinit(t.allocator);
    const s = try Stream.open(t.allocator, dir, 5, 1, false, null, 0);
    defer s.deinit();
    const fd = try connectTo(s.path());
    defer _ = c.close(fd);
    try sendFrame(fd, .auth, &s.token);
    s.service(fake.source(), 1);
    var rd: Reader = .{};
    defer rd.buf.deinit(t.allocator);
    rd.pull(fd);
    while (rd.next()) |f| if (f.tag == 4) break;

    s.paint(200, 100, &[_]Rect{.{ .x = 2, .y = 3, .w = 4, .h = 5 }});
    s.paint(200, 100, &[_]Rect{.{ .x = 190, .y = 90, .w = 6, .h = 7 }});
    s.service(fake.source(), 2);
    rd.pull(fd);
    var area: u64 = 0;
    var bands: usize = 0;
    while (rd.next()) |f| {
        if (f.tag == 4) break;
        try t.expectEqual(@as(u8, 3), f.tag);
        const r = Rect{
            .x = std.mem.readInt(u32, f.body[0..4], .little),
            .y = std.mem.readInt(u32, f.body[4..8], .little),
            .w = std.mem.readInt(u32, f.body[8..12], .little),
            .h = std.mem.readInt(u32, f.body[12..16], .little),
        };
        // Each band's pixels are exactly its own rect's.
        try t.expectEqual(@as(usize, 16 + r.area() * 4), f.body.len);
        try t.expectEqual(@as(u8, @truncate(r.x)), f.body[16]);
        area += r.area();
        bands += 1;
    } else return error.NoFrameEnd;
    try t.expectEqual(@as(usize, 2), bands);
    try t.expectEqual(@as(u64, 4 * 5 + 6 * 7), area);
    try t.expect(rd.next() == null);
}

test "cursor cache: a stream starts from the view's cursor, unchanged reports cost nothing" {
    var cc: CursorCache = .{};
    defer cc.deinit(t.allocator);
    try t.expectEqualStrings("default", cc.view().named);
    try t.expect(cc.set(t.allocator, .{ .named = "crosshair" }));
    try t.expect(!cc.set(t.allocator, .{ .named = "crosshair" }));
    const px = [_]u8{ 1, 2, 3, 4 };
    const img = st.Cursor{ .image = .{ .w = 1, .h = 1, .hot_x = 0, .hot_y = 0, .bgra = &px } };
    try t.expect(cc.set(t.allocator, img));
    const kept = cc.image.ptr;
    // The engine re-reports the same custom cursor on every move: no copy.
    try t.expect(!cc.set(t.allocator, img));
    try t.expectEqual(kept, cc.image.ptr);
    try t.expect(cc.set(t.allocator, .hidden));
    try t.expectEqual(@as(usize, 0), cc.image.len);
    try t.expect(!cc.set(t.allocator, .hidden));

    // A stream opened now announces the cached cursor first, not "default".
    var dbuf: [64]u8 = undefined;
    const dir = try tmpDir(&dbuf);
    defer _ = c.rmdir(@ptrCast(dir.ptr));
    var fake: Fake = .{};
    defer fake.inputs.deinit(t.allocator);
    defer fake.texts.deinit(t.allocator);
    defer fake.cur.deinit(t.allocator);
    _ = fake.cur.set(t.allocator, .{ .named = "pointer" });
    const s = try Stream.open(t.allocator, dir, 5, 1, false, null, 0);
    defer s.deinit();
    const fd = try connectTo(s.path());
    defer _ = c.close(fd);
    try sendFrame(fd, .auth, &s.token);
    s.service(fake.source(), 1);
    var rd: Reader = .{};
    defer rd.buf.deinit(t.allocator);
    rd.pull(fd);
    try t.expectEqual(@as(u8, 2), rd.next().?.tag);
    const cf = rd.next().?;
    try t.expectEqual(@as(u8, 5), cf.tag);
    try t.expectEqualStrings("pointer", cf.body[4..]);
    // A later change is pushed once.
    _ = fake.cur.set(t.allocator, .{ .named = "text" });
    s.markCursor();
    s.service(fake.source(), 2);
    rd.pull(fd);
    var named: ?[]const u8 = null;
    while (rd.next()) |f| if (f.tag == 5) {
        named = f.body[4..];
    };
    try t.expectEqualStrings("text", named.?);
}

test "stream: a resize mid-frame ends the started frame before the new surface" {
    var dbuf: [64]u8 = undefined;
    const dir = try tmpDir(&dbuf);
    defer _ = c.rmdir(@ptrCast(dir.ptr));
    // 1024x1024 is 4MiB of pixels: four 1MiB bands, more than the
    // transmit buffer takes in one turn, so the frame stays open across
    // turns while the client is not reading.
    var fake: Fake = .{ .surf = .{ .pixel_w = 1024, .pixel_h = 1024, .logical_w = 1024, .logical_h = 1024 } };
    defer fake.inputs.deinit(t.allocator);
    defer fake.texts.deinit(t.allocator);
    const s = try Stream.open(t.allocator, dir, 5, 1, false, null, 0);
    defer s.deinit();
    const fd = try connectTo(s.path());
    defer _ = c.close(fd);
    try sendFrame(fd, .auth, &s.token);
    s.service(fake.source(), 1);
    // Mid-frame: some bands queued (and partly written), the rest pending.
    try t.expect(s.bands != null and s.frame_open);

    // The view resizes now.
    fake.surf = .{ .pixel_w = 640, .pixel_h = 480, .logical_w = 640, .logical_h = 480 };
    var rd: Reader = .{};
    defer rd.buf.deinit(t.allocator);
    var turn: i64 = 2;
    while (turn < 400) : (turn += 1) {
        s.service(fake.source(), turn);
        rd.pull(fd);
    }
    try t.expect(s.closed == null);

    // Surface, Cursor, Damage+ (old, partial), FrameEnd 1, Surface,
    // Damage+ (new, whole), FrameEnd 2: never a Surface with damage
    // pending, and every damage run closed by a FrameEnd.
    var surfaces: usize = 0;
    var ends: [4]u64 = undefined;
    var nends: usize = 0;
    var pending_damage = false;
    var damage_rows_new: u64 = 0;
    while (rd.next()) |f| switch (f.tag) {
        2 => {
            try t.expect(!pending_damage);
            surfaces += 1;
        },
        3 => {
            pending_damage = true;
            if (surfaces == 2) damage_rows_new += std.mem.readInt(u32, f.body[12..16], .little);
        },
        4 => {
            try t.expect(pending_damage);
            pending_damage = false;
            ends[nends] = std.mem.readInt(u64, f.body[0..8], .little);
            nends += 1;
        },
        else => {},
    };
    try t.expectEqual(@as(usize, 2), surfaces);
    try t.expect(!pending_damage);
    try t.expectEqual(@as(usize, 2), nends);
    try t.expectEqual(@as(u64, 1), ends[0]);
    try t.expectEqual(@as(u64, 2), ends[1]);
    // The new surface was painted whole, within the two-frame window
    // (nothing was ACKed).
    try t.expectEqual(@as(u64, 480), damage_rows_new);
    try t.expect(!s.flow.canSend());
}

test "stream: a flood of input is served a bounded share per turn" {
    var dbuf: [64]u8 = undefined;
    const dir = try tmpDir(&dbuf);
    defer _ = c.rmdir(@ptrCast(dir.ptr));
    var fake: Fake = .{};
    defer fake.inputs.deinit(t.allocator);
    defer fake.texts.deinit(t.allocator);
    const s = try Stream.open(t.allocator, dir, 5, 1, false, null, 0);
    defer s.deinit();
    const fd = try connectTo(s.path());
    defer _ = c.close(fd);
    try sendFrame(fd, .auth, &s.token);
    for (0..EVENTS_PER_TURN * 2 + 5) |_| try sendFrame(fd, .focus, &.{1});
    s.service(fake.source(), 1);
    try t.expectEqual(@as(usize, EVENTS_PER_TURN - 1), fake.inputs.items.len);
    s.service(fake.source(), 2);
    try t.expectEqual(@as(usize, EVENTS_PER_TURN * 2 - 1), fake.inputs.items.len);
    // Nothing new arrives, yet the leftovers are still dispatched.
    s.service(fake.source(), 3);
    try t.expectEqual(@as(usize, EVENTS_PER_TURN * 2 + 5), fake.inputs.items.len);
    try t.expect(s.closed == null);

    // Text is budgeted exactly: four 4096-byte frames fill a turn's 16KiB
    // and a fifth waits, it is not let through 4095 bytes over.
    fake.texts.clearRetainingCapacity();
    const big = [_]u8{'x'} ** st.MAX_TEXT;
    for (0..5) |_| try sendFrame(fd, .text, &big);
    s.service(fake.source(), 5);
    try t.expectEqual(@as(usize, TEXT_BYTES_PER_TURN), fake.texts.items.len);
    s.service(fake.source(), 6);
    try t.expectEqual(@as(usize, 5 * st.MAX_TEXT), fake.texts.items.len);
    // A smaller Text that does not fit beside 4KiB already taken also waits.
    fake.texts.clearRetainingCapacity();
    for (0..3) |_| try sendFrame(fd, .text, &big);
    try sendFrame(fd, .text, big[0..4000]);
    try sendFrame(fd, .text, big[0..200]);
    s.service(fake.source(), 7);
    try t.expectEqual(@as(usize, 3 * st.MAX_TEXT + 4000), fake.texts.items.len);
    s.service(fake.source(), 8);
    try t.expectEqual(@as(usize, 3 * st.MAX_TEXT + 4200), fake.texts.items.len);

    // A Text frame longer than MAX_TEXT is refused by its length alone.
    var hdr: [5]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], st.MAX_CLIENT_FRAME + 1, .little);
    hdr[4] = @intFromEnum(st.Tag.text);
    _ = c.write(fd, &hdr, hdr.len);
    s.service(fake.source(), 4);
    try t.expectEqualStrings("malformed stream frame", s.closed.?);
}

test "stream: input before auth and hostile frames end the stream" {
    var dbuf: [64]u8 = undefined;
    const dir = try tmpDir(&dbuf);
    defer _ = c.rmdir(@ptrCast(dir.ptr));
    var fake: Fake = .{};
    defer fake.inputs.deinit(t.allocator);
    defer fake.texts.deinit(t.allocator);

    const s = try Stream.open(t.allocator, dir, 5, 1, false, null, 0);
    defer s.deinit();
    const fd = try connectTo(s.path());
    defer _ = c.close(fd);
    try sendFrame(fd, .focus, &.{1});
    s.service(fake.source(), 1);
    try t.expectEqualStrings("stream authentication failed", s.closed.?);
    try t.expectEqual(@as(usize, 0), fake.inputs.items.len);

    const s2 = try Stream.open(t.allocator, dir, 6, 1, false, null, 0);
    defer s2.deinit();
    const fd2 = try connectTo(s2.path());
    defer _ = c.close(fd2);
    try sendFrame(fd2, .auth, &s2.token);
    // A length claiming more than the cap: desynchronised peer.
    var bad: [5]u8 = undefined;
    std.mem.writeInt(u32, bad[0..4], st.MAX_FRAME + 1, .little);
    bad[4] = 19;
    _ = c.write(fd2, &bad, bad.len);
    s2.service(fake.source(), 1);
    try t.expectEqualStrings("malformed stream frame", s2.closed.?);

    const s3 = try Stream.open(t.allocator, dir, 7, 1, false, null, 0);
    defer s3.deinit();
    const fd3 = try connectTo(s3.path());
    defer _ = c.close(fd3);
    try sendFrame(fd3, .auth, &s3.token);
    try sendFrame(fd3, .surface, &([_]u8{0} ** 17));
    s3.service(fake.source(), 1);
    try t.expectEqualStrings("unknown stream frame", s3.closed.?);
}

fn openStub(allocator: std.mem.Allocator, codec_: vcodec.Codec, w: i32, h: i32, fps: i32) anyerror!vcodec.Encoder {
    _ = .{ codec_, w, h, fps };
    return vcodec.Encoder.initStub(allocator);
}

/// A client mirror of an encoded stream: applies ENCODED parts through
/// the shared `frameenc.Receiver`, the way a third-party consumer would.
const EncMirror = struct {
    w: u16 = 0,
    h: u16 = 0,
    pix: std.ArrayList(u8) = .empty,
    recv: frameenc.Receiver = .{},
    frames: u32 = 0,
    messages: u32 = 0,
    last_serial: u64 = 0,
    open_serial: ?u64 = null,
    surfaces: u32 = 0,
    area: u64 = 0,

    fn deinit(self: *EncMirror) void {
        self.pix.deinit(t.allocator);
        self.recv.deinit(t.allocator);
    }

    /// Apply every complete frame `rd` holds; a raw DAMAGE or FRAME_END
    /// is a test failure, as is SURFACE inside a logical frame.
    fn drain(self: *EncMirror, rd: *Reader) !void {
        while (true) {
            const raw = (try st.split(rd.buf.items[rd.pos..])) orelse return;
            rd.pos += raw.len;
            switch (@as(st.Tag, @enumFromInt(raw.tag))) {
                .surface => {
                    try t.expect(self.open_serial == null);
                    self.w = @intCast(std.mem.readInt(u32, raw.body[0..4], .little));
                    self.h = @intCast(std.mem.readInt(u32, raw.body[4..8], .little));
                    try self.pix.resize(t.allocator, @as(usize, self.w) * self.h * 4);
                    @memset(self.pix.items, 0);
                    self.surfaces += 1;
                },
                .cursor, .audio => {},
                .encoded => {
                    const fe = try proto.FrameEncoded.decodeAlloc(raw.body, t.allocator);
                    defer t.allocator.free(fe.parts);
                    try t.expectEqual(@as(u32, 42), fe.view);
                    try t.expectEqual(self.w, fe.w);
                    try t.expectEqual(self.h, fe.h);
                    if (self.open_serial) |sr| try t.expectEqual(sr, fe.serial) else try t.expect(fe.serial > self.last_serial);
                    for (fe.parts) |p| {
                        const got = try self.recv.apply(t.allocator, self.pix.items, self.w, self.h, p);
                        try t.expect(got == .rect);
                        self.area += @as(u64, p.w) * p.h;
                    }
                    self.messages += 1;
                    if (fe.last != 0) {
                        self.frames += 1;
                        self.last_serial = fe.serial;
                        self.open_serial = null;
                    } else self.open_serial = fe.serial;
                },
                else => return error.UnexpectedTag,
            }
        }
    }
};

fn sendAck(fd: c_int, serial: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, serial, .little);
    try sendFrame(fd, .ack, &b);
}

test "stream: an encoded stream decodes to the live surface under the two-frame window" {
    var dbuf: [64]u8 = undefined;
    const dir = try tmpDir(&dbuf);
    defer _ = c.rmdir(@ptrCast(dir.ptr));
    var fake: Fake = .{ .surf = .{ .pixel_w = 64, .pixel_h = 32, .logical_w = 64, .logical_h = 32 } };
    defer fake.inputs.deinit(t.allocator);
    defer fake.texts.deinit(t.allocator);
    defer fake.px.deinit(t.allocator);
    const s = try Stream.open(t.allocator, dir, 5, 1, false, .{ .wire_view = 42, .codecs = "", .encodable = .{}, .open = openStub }, 0);
    defer s.deinit();
    try t.expectEqual(proto.StreamEncoding.encoded, s.encoding());
    try t.expect(s.codec() == null);
    const fd = try connectTo(s.path());
    defer _ = c.close(fd);
    try sendFrame(fd, .auth, &s.token);
    s.service(fake.source(), 1);
    var rd: Reader = .{};
    defer rd.buf.deinit(t.allocator);
    var mirror: EncMirror = .{};
    defer mirror.deinit();
    rd.pull(fd);
    try mirror.drain(&rd);
    // SURFACE, then the whole surface as one logical frame.
    try t.expectEqual(@as(u32, 1), mirror.surfaces);
    try t.expectEqual(@as(u32, 1), mirror.frames);
    try t.expectEqualSlices(u8, Fake.live(&fake, 5).?.map, mirror.pix.items);

    // A small paint ships only its rect; a second fills the window.
    fake.tint = 9;
    s.paint(64, 32, &[_]Rect{.{ .x = 3, .y = 4, .w = 2, .h = 2 }});
    s.service(fake.source(), 2);
    rd.pull(fd);
    const area0 = mirror.area;
    try mirror.drain(&rd);
    try t.expectEqual(@as(u32, 2), mirror.frames);
    try t.expectEqual(area0 + 4, mirror.area);
    // While two frames are unacknowledged nothing more is cut; paints merge.
    s.paint(64, 32, &[_]Rect{.{ .x = 0, .y = 0, .w = 64, .h = 32 }});
    s.service(fake.source(), 3);
    rd.pull(fd);
    try mirror.drain(&rd);
    try t.expectEqual(@as(u32, 2), mirror.frames);
    // A stale ACK is ignored on an encoded stream (not a violation).
    try sendAck(fd, 77);
    s.service(fake.source(), 4);
    try t.expect(s.closed == null);
    rd.pull(fd);
    try mirror.drain(&rd);
    try t.expectEqual(@as(u32, 2), mirror.frames);
    // ACKing the newest retires both: the merged frame carries the newest pixels.
    try sendAck(fd, mirror.last_serial);
    s.service(fake.source(), 5);
    rd.pull(fd);
    try mirror.drain(&rd);
    try t.expectEqual(@as(u32, 3), mirror.frames);
    try t.expectEqualSlices(u8, Fake.live(&fake, 5).?.map, mirror.pix.items);

    // A resize: SURFACE again, then the whole new surface.
    fake.surf = .{ .pixel_w = 32, .pixel_h = 16, .logical_w = 32, .logical_h = 16 };
    try sendAck(fd, mirror.last_serial);
    s.service(fake.source(), 6);
    rd.pull(fd);
    try mirror.drain(&rd);
    try t.expectEqual(@as(u32, 2), mirror.surfaces);
    try t.expectEqual(@as(u32, 4), mirror.frames);
    try t.expectEqualSlices(u8, Fake.live(&fake, 5).?.map, mirror.pix.items);
}

test "stream: a large encoded frame splits into messages within the stream's frame cap" {
    var dbuf: [64]u8 = undefined;
    const dir = try tmpDir(&dbuf);
    defer _ = c.rmdir(@ptrCast(dir.ptr));
    // ~5.3 MB of incompressible pixels: more than one stream frame holds.
    var fake: Fake = .{ .surf = .{ .pixel_w = 1024, .pixel_h = 1300, .logical_w = 1024, .logical_h = 1300 }, .noise = true };
    defer fake.inputs.deinit(t.allocator);
    defer fake.texts.deinit(t.allocator);
    defer fake.px.deinit(t.allocator);
    const s = try Stream.open(t.allocator, dir, 5, 1, false, .{ .wire_view = 42, .codecs = "", .encodable = .{}, .open = openStub }, 0);
    defer s.deinit();
    const fd = try connectTo(s.path());
    defer _ = c.close(fd);
    try sendFrame(fd, .auth, &s.token);
    var rd: Reader = .{};
    defer rd.buf.deinit(t.allocator);
    var mirror: EncMirror = .{};
    defer mirror.deinit();
    // The client reads while the helper writes: the frame spans turns.
    var turn: i64 = 1;
    while (turn < 400 and mirror.frames == 0) : (turn += 1) {
        s.service(fake.source(), turn);
        rd.pull(fd);
        try mirror.drain(&rd);
    }
    try t.expect(s.closed == null);
    try t.expectEqual(@as(u32, 1), mirror.frames);
    try t.expect(mirror.messages >= 2);
    try t.expectEqualSlices(u8, Fake.live(&fake, 5).?.map, mirror.pix.items);
}
