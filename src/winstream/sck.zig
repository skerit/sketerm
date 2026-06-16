//! ScreenCaptureKit window-stream source (Darwin only) — the real
//! backend behind winstream/source.zig's `Source.sck` arm, built
//! when build_options.winstream_sck is set (native macOS builds).
//!
//! All Darwin API work lives in sck_shim.m behind a C ABI; this
//! file translates shim events into proto units (deflating frames
//! like the stub does) and wire input into shim injection calls
//! (evdev → CGKeyCode via keymap.zig). The shim's wakeup pipe is
//! exposed as pollFd() so the daemon's poll loop reacts to frames
//! that arrive between ticks.

const std = @import("std");
const build_options = @import("build_options");
const proto = @import("proto.zig");
const keymap = @import("keymap.zig");
const pixcodec = @import("../wlhost/pixcodec.zig");
const vcodec = @import("../wlhost/vcodec.zig");
const churn = @import("../util/churn.zig");
const content = @import("../util/content.zig");

/// VideoToolbox H.264 encode is available (native macOS). The video
/// route (hot + photographic windows → win_vtile) collapses out when
/// false. sck.zig only ever compiles on native macOS, so this is true
/// in practice; the gate keeps the dead path honest.
const have_vtenc = build_options.vtenc;

const CEvent = extern struct {
    kind: u32, // 0 open, 1 frame, 2 title, 3 close, 4 drag-rects, 5 patch
    win: u32,
    w: i32, // kind 4: rect count. kind 5: patch rect size.
    h: i32,
    x: i32, // kind 5 only: dirty-rect origin in window pixels.
    y: i32,
    data: ?[*]const u8,
    len: usize,
};

extern fn sketerm_sck_create(root_pid: i32) ?*anyopaque;
extern fn sketerm_sck_destroy(ctx: *anyopaque) void;
extern fn sketerm_sck_wakeup_fd(ctx: *anyopaque) c_int;
extern fn sketerm_sck_status(ctx: *anyopaque) u32;
extern fn sketerm_sck_last_error(ctx: *anyopaque, buf: [*]u8, cap: usize) usize;
extern fn sketerm_sck_drain(ctx: *anyopaque, out_n: *usize) ?[*]const CEvent;
extern fn sketerm_sck_key(ctx: *anyopaque, win: u32, keycode: u16, down: bool, flags: u64) void;
extern fn sketerm_sck_ptr(ctx: *anyopaque, win: u32, kind: u8, x: f64, y: f64, detail: u32) void;
extern fn sketerm_sck_scroll(ctx: *anyopaque, win: u32, dx: f64, dy: f64) void;
extern fn sketerm_sck_close_win(ctx: *anyopaque, win: u32) void;
extern fn sketerm_sck_reannounce(ctx: *anyopaque) void;
/// Whole-frame snapshot for the video encoder (the lossless stream may
/// carry only patches). Returns null if the window has no frame yet.
extern fn sketerm_sck_snapshot(ctx: *anyopaque, win: u32, out_w: *i32, out_h: *i32, out_len: *usize) ?[*]const u8;

const status_screen: u32 = 1;

/// Synthetic window that tells the user WHY nothing is streaming
/// when the Screen Recording grant is missing — a silent hang is
/// the one failure mode this backend must not have.
const notice_win: u32 = 0xfffffffe;
const notice_w: i32 = 520;
const notice_h: i32 = 80;
const notice_title = "sketerm: grant Screen Recording to sketerm-mux on the Mac, then restart the daemon";

/// Per-window lossy-video state: a churn tracker + a fixed-resolution
/// H.264 encoder (VideoToolbox), mirroring daemon.zig's Wayland
/// VideoSurface. Hot, photographic windows route through here to
/// win_vtile instead of the lossless win_frame_c/win_patch_c.
const WinVid = struct {
    churn: churn.Tracker,
    enc: vcodec.Encoder,
    w: i32,
    h: i32,
    seq: u32 = 0,
    needs_kf: bool = true,
    /// A full lossless frame (win_frame_c) has established this window's
    /// backing buffer on the CURRENT client. The receiver DROPS a
    /// win_vtile until then (it blits into the backing, like a patch), so
    /// video can't start before a base frame. Reset on (re)attach + resize.
    base_sent: bool = false,
    /// Got a pixel update (frame/patch) this poll → reconsider its route.
    touched: bool = false,
    /// Decided this poll: its frame/patch was sent as a video tile, so the
    /// lossless path must skip it.
    route_video: bool = false,

    fn deinit(self: *WinVid) void {
        self.churn.deinit();
        self.enc.deinit();
    }
};

pub const Source = struct {
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    /// Reused across every frame/patch encode in a poll cycle — each
    /// `Encoded` aliases it but is appended into `out` before the next
    /// encode reuses it (same discipline as the stub).
    sc: pixcodec.Scratch = .{},
    notice_open: bool = false,
    /// Dedupe for shim error reporting — refresh retries reproduce
    /// the same failure string every few seconds.
    last_err: [512]u8 = undefined,
    last_err_len: usize = 0,
    /// The attached client advertised it can decode H.264 (hello
    /// `video`). Until then the video route stays dormant — never send a
    /// tile no client can decode.
    wants_video: bool = false,
    /// Per-window video state (only populated when wants_video).
    vstate: std.AutoHashMapUnmanaged(u32, WinVid) = .empty,
    /// Reused vcodec tile blob for the win_vtile body.
    vblob: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, app_pid: i32) !Source {
        const ctx = sketerm_sck_create(app_pid) orelse return error.SckInitFailed;
        return .{ .allocator = allocator, .ctx = ctx };
    }

    pub fn deinit(self: *Source) void {
        sketerm_sck_destroy(self.ctx);
        self.sc.deinit(self.allocator);
        var it = self.vstate.valueIterator();
        while (it.next()) |v| v.deinit();
        self.vstate.deinit(self.allocator);
        self.vblob.deinit(self.allocator);
    }

    pub fn pollFd(self: *const Source) c_int {
        return sketerm_sck_wakeup_fd(self.ctx);
    }

    /// The attached client's H.264 decode capability — gates the video
    /// route. Set when a winstream channel (re)attaches to a client.
    pub fn setWantsVideo(self: *Source, wants: bool) void {
        self.wants_video = wants;
    }

    /// A client (re)attached: replay win_open + current frame for
    /// every live window — it missed the originals. A fresh client has no
    /// prior reference frames, so force the next video tile per window to
    /// be a keyframe.
    pub fn reannounce(self: *Source) void {
        sketerm_sck_reannounce(self.ctx);
        // The new client's backing is empty: it needs a fresh base frame
        // (win_frame_c) before any video tile, and the first tile after
        // that must be a keyframe.
        var it = self.vstate.valueIterator();
        while (it.next()) |v| {
            v.needs_kf = true;
            v.base_sent = false;
        }
    }

    pub fn poll(self: *Source, out: *std.ArrayList(u8), out_allocator: std.mem.Allocator, now_ms: u64) !void {
        _ = now_ms; // SCK paces frames itself (minimumFrameInterval)

        // Drain FIRST, unconditionally: it reads the wakeup pipe dry
        // (a stale readable byte would spin the daemon poll loop hot)
        // and kicks the throttled window refresh.
        var n: usize = 0;
        const evs = sketerm_sck_drain(self.ctx, &n);

        // Shim-side problems (TCC, fetch failures, stream errors)
        // land in the daemon log — once per distinct message.
        var err_buf: [512]u8 = undefined;
        const elen = sketerm_sck_last_error(self.ctx, &err_buf, err_buf.len);
        if (elen > 0 and !std.mem.eql(u8, err_buf[0..elen], self.last_err[0..self.last_err_len])) {
            std.debug.print("sketerm-mux winstream: {s}\n", .{err_buf[0..elen]});
            @memcpy(self.last_err[0..elen], err_buf[0..elen]);
            self.last_err_len = elen;
        }

        if (sketerm_sck_status(self.ctx) & status_screen == 0) {
            if (!self.notice_open) {
                self.notice_open = true;
                try proto.appendWinOpen(out, out_allocator, .{
                    .win = notice_win,
                    .w = notice_w,
                    .h = notice_h,
                    .title = notice_title,
                });
                const px = try self.allocator.alloc(u8, @intCast(notice_w * 4 * notice_h));
                defer self.allocator.free(px);
                for (0..@intCast(notice_h)) |y| {
                    for (0..@intCast(notice_w)) |x| {
                        const i = (y * @as(usize, @intCast(notice_w)) + x) * 4;
                        // Warning-yellow band on dark gray.
                        const band = y < 8 or y >= @as(usize, @intCast(notice_h)) - 8;
                        px[i + 0] = if (band) 0x00 else 0x30; // B
                        px[i + 1] = if (band) 0xc8 else 0x30; // G
                        px[i + 2] = if (band) 0xe8 else 0x30; // R
                        px[i + 3] = 0xff;
                    }
                }
                try proto.appendFrame(out, out_allocator, .{
                    .win = notice_win,
                    .w = notice_w,
                    .h = notice_h,
                    .pixels = px,
                });
            }
            return;
        }

        const list = evs orelse return;
        const events = list[0..n];

        // No video route (capability off, or this build has no encoder):
        // emit every event on the lossless path, exactly as before.
        if (comptime !have_vtenc) {
            for (events) |ev| try self.emitOne(ev, out, out_allocator);
            return;
        }
        if (!self.wants_video) {
            for (events) |ev| try self.emitOne(ev, out, out_allocator);
            return;
        }

        // ── video route (client can decode H.264) ──────────────────
        // Pass 1: emit lifecycle (open/title/close/drag) immediately and
        // feed each window's churn tracker with this poll's pixel damage.
        for (events) |ev| {
            switch (ev.kind) {
                0, 2, 4 => try self.emitOne(ev, out, out_allocator),
                3 => {
                    try self.emitOne(ev, out, out_allocator);
                    if (self.vstate.fetchRemove(ev.win)) |kv| {
                        var v = kv.value;
                        v.deinit();
                    }
                },
                1 => if (self.videoState(ev.win, ev.w, ev.h)) |vs| {
                    vs.churn.noteDamage(0, 0, ev.w, ev.h); // whole-frame change
                    vs.touched = true;
                },
                5 => if (self.vstate.getPtr(ev.win)) |vs| {
                    vs.churn.noteDamage(ev.x, ev.y, ev.w, ev.h);
                    vs.touched = true;
                },
                else => {},
            }
        }

        // Pass 2: per touched window, decide the route. Hot + photographic
        // → encode the whole frame as one H.264 tile and emit a win_vtile.
        var it = self.vstate.iterator();
        while (it.next()) |e| {
            const vs = e.value_ptr;
            vs.route_video = false;
            if (!vs.touched) continue;
            vs.touched = false;
            vs.churn.endFrame();
            if (!vs.base_sent) continue; // no backing on the client yet → lossless
            if (!vs.churn.hot(0, 0, vs.w, vs.h)) continue;
            var sw: i32 = 0;
            var sh: i32 = 0;
            var slen: usize = 0;
            const snap = sketerm_sck_snapshot(self.ctx, e.key_ptr.*, &sw, &sh, &slen) orelse continue;
            if (sw != vs.w or sh != vs.h) continue; // resized mid-poll → lossless
            const pixels = snap[0..slen];
            if (!content.looksPhotographic(pixels, .{})) continue;
            const res = vs.enc.encodeTile(vs.w, vs.h, pixels, vs.needs_kf) catch continue;
            vs.needs_kf = false;
            self.vblob.clearRetainingCapacity();
            vcodec.appendTile(&self.vblob, self.allocator, .{
                .codec = vs.enc.codec(),
                .keyframe = res.keyframe,
                .x = 0,
                .y = 0,
                .w = vs.w,
                .h = vs.h,
                .seq = vs.seq,
                .payload = res.bytes,
            }) catch continue;
            vs.seq +%= 1;
            try proto.appendWinVtile(out, out_allocator, e.key_ptr.*, self.vblob.items);
            vs.route_video = true;
        }

        // Pass 3: emit the lossless frame/patch ONLY for windows not sent
        // as video this poll. A full frame (kind 1) here establishes the
        // client's backing → video may start next poll.
        for (events) |ev| {
            if (ev.kind != 1 and ev.kind != 5) continue;
            const vs = self.vstate.getPtr(ev.win);
            if (vs) |v| {
                if (v.route_video) continue;
            }
            try self.emitOne(ev, out, out_allocator);
            if (ev.kind == 1) {
                if (vs) |v| v.base_sent = true;
            }
        }
    }

    /// Lossless emission of one shim event (open / frame / title / close /
    /// drag / patch). The video route calls this for lifecycle events and
    /// for the pixel events of windows it did NOT send as video.
    fn emitOne(self: *Source, ev: CEvent, out: *std.ArrayList(u8), out_allocator: std.mem.Allocator) !void {
        switch (ev.kind) {
            0 => try proto.appendWinOpen(out, out_allocator, .{
                .win = ev.win,
                .w = ev.w,
                .h = ev.h,
                .title = if (ev.data) |d| d[0..ev.len] else "remote app",
            }),
            1 => {
                // Whole window frame (open / resize / reattach, or a
                // patch-fallback). Tight w*4 stride → codec frame.
                const d = ev.data orelse return;
                if (ev.w <= 0 or ev.h <= 0) return;
                const enc = pixcodec.encodeRegion(&self.sc, self.allocator, d[0..ev.len], @intCast(ev.w * 4)) catch
                    pixcodec.Encoded{ .coder = .raw, .filter = .none, .bytes = d[0..ev.len] };
                try proto.appendWinFrameC(out, out_allocator, ev.win, ev.w, ev.h, enc);
            },
            5 => {
                // Damaged sub-rect at (x,y), tight w*4 stride. The receiver
                // blits it into the window's backing — which a prior full
                // frame (kind 1) must have established.
                const d = ev.data orelse return;
                if (ev.w <= 0 or ev.h <= 0) return;
                const enc = pixcodec.encodeRegion(&self.sc, self.allocator, d[0..ev.len], @intCast(ev.w * 4)) catch
                    pixcodec.Encoded{ .coder = .raw, .filter = .none, .bytes = d[0..ev.len] };
                try proto.appendWinPatchC(out, out_allocator, ev.win, ev.x, ev.y, ev.w, ev.h, enc);
            },
            2 => {
                var pbuf: [4 + 512]u8 = undefined;
                std.mem.writeInt(u32, pbuf[0..4], ev.win, .little);
                const tlen = @min(ev.len, 512);
                if (ev.data) |d| @memcpy(pbuf[4 .. 4 + tlen], d[0..tlen]);
                try proto.appendUnit(out, out_allocator, .win_title, pbuf[0 .. 4 + tlen]);
            },
            3 => {
                var pbuf: [4]u8 = undefined;
                std.mem.writeInt(u32, &pbuf, ev.win, .little);
                try proto.appendUnit(out, out_allocator, .win_close, &pbuf);
            },
            4 => {
                // Drag-rect blob: i16[0]=ref_w, i16[1]=ref_h, then ev.w
                // rects of i16{x,y,w,h}. The shim keeps it alive until the
                // next drain (its drain_hold), so copy out here.
                const d = ev.data orelse return;
                const vals: [*]align(1) const i16 = @ptrCast(d);
                const cnt = @min(@as(usize, @intCast(@max(ev.w, 0))), proto.max_drag_rects);
                var rects: [proto.max_drag_rects]proto.DragRect = undefined;
                for (0..cnt) |i| rects[i] = .{
                    .x = vals[2 + i * 4],
                    .y = vals[2 + i * 4 + 1],
                    .w = vals[2 + i * 4 + 2],
                    .h = vals[2 + i * 4 + 3],
                };
                try proto.appendWinDrag(out, out_allocator, ev.win, vals[0], vals[1], rects[0..cnt]);
            },
            else => {},
        }
    }

    /// Get-or-create the per-window video state, sized to w×h. Null for odd
    /// dims (the H.264 encoder needs even) or on encoder-open failure — the
    /// window then stays on the lossless path.
    fn videoState(self: *Source, win: u32, w: i32, h: i32) ?*WinVid {
        if (comptime !have_vtenc) return null;
        if (w <= 0 or h <= 0 or @rem(w, 2) != 0 or @rem(h, 2) != 0) return null;
        const gop = self.vstate.getOrPut(self.allocator, win) catch return null;
        if (!gop.found_existing or gop.value_ptr.w != w or gop.value_ptr.h != h) {
            if (gop.found_existing) gop.value_ptr.deinit();
            var tracker = churn.Tracker.init(self.allocator, @intCast(w), @intCast(h), .{}) catch {
                _ = self.vstate.remove(win);
                return null;
            };
            const enc = vcodec.Encoder.initVtoolbox(self.allocator, w, h, 30) catch {
                tracker.deinit();
                _ = self.vstate.remove(win);
                return null;
            };
            gop.value_ptr.* = .{ .churn = tracker, .enc = enc, .w = w, .h = h };
        }
        return gop.value_ptr;
    }

    pub fn handleInput(self: *Source, unit: proto.Unit) void {
        switch (unit.tag) {
            .input_key => {
                const k = proto.decodeInputKey(unit.payload) orelse return;
                const vk = keymap.evdevToCgKeycode(k.key) orelse return;
                sketerm_sck_key(self.ctx, k.win, vk, k.pressed, keymap.modsToCgFlags(k.mods));
            },
            .input_ptr => {
                const p = proto.decodeInputPtr(unit.payload) orelse return;
                if (p.win == notice_win) return;
                if (p.kind == 3) {
                    // Scroll: x/y carry the wheel deltas (lines).
                    sketerm_sck_scroll(self.ctx, p.win, p.x, p.y);
                } else {
                    sketerm_sck_ptr(self.ctx, p.win, p.kind, p.x, p.y, p.detail);
                }
            },
            .close_req => {
                if (unit.payload.len < 4) return;
                const win = std.mem.readInt(u32, unit.payload[0..4], .little);
                if (win == notice_win) return; // nothing to close on this side
                sketerm_sck_close_win(self.ctx, win);
            },
            else => {},
        }
    }
};
