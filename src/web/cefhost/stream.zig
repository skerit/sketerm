//! Pushed per-view stream (capability "web-stream", 0xF8 block), the
//! engine half: which views may stream, what a stream shows (the live
//! frame buffer with the `<select>` popup composed over it), where its
//! input goes, the cursor, and page audio captured through CEF's audio
//! handler. The socket half is `streamsrv.zig`, the format `stream.zig`.
//! The `Host` methods are free functions taking `*Host`, re-exported
//! from `Host` under the same names.

const std = @import("std");
const cef = @import("cef");
const proto = @import("../protocol.zig");
const st = @import("../stream.zig");
const srv = @import("../streamsrv.zig");
const webkeys = @import("../webkeys.zig");
const clock = @import("../../util/clock.zig");
const host_mod = @import("../cefhost.zig");
const Host = host_mod.Host;
const View = host_mod.View;
const releaseArg = host_mod.releaseArg;
const viewOf = host_mod.viewOf;

pub const OpenResult = union(enum) {
    ok: *srv.Stream,
    err: []const u8,
};

fn streamOf(self: *Host, view: u32) ?*srv.Stream {
    for (self.streams.items) |s| {
        if (s.view == view and s.closed == null) return s;
    }
    return null;
}

/// Open `view`'s stream for the dispatching connection. The view id is
/// already engine-global; ownership was checked by `find`.
pub fn streamOpen(self: *Host, view: u32, want_audio: bool) OpenResult {
    const v = self.find(view) orelse return .{ .err = "no such view" };
    if (v.webext_bg or v.webext_popup or v.windowed) return .{ .err = "this view has no page to stream" };
    // GPU frames never enter this process's memory, so there is nothing
    // to cut damage bands from.
    if (host_mod.isAccelerated()) return .{ .err = "this helper renders on the GPU; streams need CPU frames" };
    if (streamOf(self, v.id) != null) return .{ .err = "this view already has a stream" };
    var live: usize = 0;
    for (self.streams.items) |s| {
        if (s.closed == null) live += 1;
    }
    if (live >= srv.MAX_STREAMS) return .{ .err = "too many open streams" };
    const s = srv.Stream.open(self.gpa, self.stream_dir, v.id, self.dispatch_conn, want_audio, clock.nowMs()) catch |err|
        return .{ .err = switch (err) {
            error.NoDirectory => "this helper has no socket directory to put a stream in",
            error.PathTooLong => "the stream socket path is too long",
            error.NoEntropy => "no randomness for the stream token",
            error.SocketFailed => "could not create the stream socket",
            error.OutOfMemory => "out of memory",
        } };
    self.streams.append(self.gpa, s) catch {
        s.deinit();
        return .{ .err = "out of memory" };
    };
    // A page the engine is still capturing (an earlier stream asked for
    // it) will not be asked about again: attach to that capture now.
    if (s.audio_slot) |slot| {
        if (v.cef_id != 0 and srv.audio.capturing(v.cef_id)) srv.audio.bind(slot, v.cef_id);
    }
    return .{ .ok = s };
}

/// `stream_close` from the client.
pub fn streamClose(self: *Host, view: u32) void {
    const v = self.find(view) orelse return;
    if (streamOf(self, v.id)) |s| {
        s.shut("closed by the client");
        streamReap(self);
    }
}

/// The view is going away (destroy or owner disconnect): end its stream
/// while the record still exists, so held input is released into it.
pub fn streamDropView(self: *Host, view: u32) void {
    if (streamOf(self, view)) |s| {
        s.shut("the view was destroyed");
        streamReap(self);
    }
}

/// End every stream (the helper is shutting down).
pub fn streamCloseAll(self: *Host) void {
    for (self.streams.items) |s| s.shut("the browser helper is shutting down");
    streamReap(self);
    self.streams.deinit(self.gpa);
    self.streams = .empty;
}

/// The stream descriptors for the server's poll set; returns how many
/// were written into `out`.
pub fn streamPollFds(self: *const Host, out: []@import("cbindings").struct_pollfd) usize {
    var n: usize = 0;
    for (self.streams.items) |s| {
        if (n == out.len) break;
        out[n] = s.pollFd() orelse continue;
        n += 1;
    }
    return n;
}

/// One poll turn of every stream, then reap the ended ones.
pub fn streamPump(self: *Host) void {
    if (self.streams.items.len == 0) return;
    const now = clock.nowMs();
    // Input dispatched from a service can tear a view down (a failed
    // revival destroys the record), which ends that view's stream: the
    // reap is deferred to after the loop so no stream is freed while it
    // is being serviced.
    self.stream_busy = true;
    for (self.streams.items) |s| s.service(source(self), now);
    self.stream_busy = false;
    streamReap(self);
}

/// Free ended streams: release what their client still held, announce
/// the end to the owner, free the record.
fn streamReap(self: *Host) void {
    if (self.stream_busy) return;
    var i: usize = 0;
    while (i < self.streams.items.len) {
        const s = self.streams.items[i];
        if (s.closed == null) {
            i += 1;
            continue;
        }
        _ = self.streams.swapRemove(i);
        releaseHeld(self, s);
        // Routed by the view id's window, so it reaches the owner even
        // when the view itself is already gone.
        self.post(proto.EvStreamClosed{ .view = s.view, .reason = s.closed.? });
        s.deinit();
    }
}

/// Let go of every key and button the stream client still holds, into
/// the browser that holds them. Never a revival: a discarded view has no
/// browser holding anything (`streamBrowserGone` already forgot it), and
/// waking one to deliver key-ups would cost a whole page load.
fn releaseHeld(self: *Host, s: *srv.Stream) void {
    var buf: [st.Held.MAX_KEYS + 3]st.Held.Release = undefined;
    const rel = s.held.drain(&buf);
    if (rel.len == 0) return;
    const v = self.findAny(s.view) orelse return;
    if (v.discarded or v.browser == null) return;
    const prev = self.dispatch_conn;
    self.dispatch_conn = s.owner;
    defer self.dispatch_conn = prev;
    for (rel) |r| switch (r) {
        .button => |b| self.pointerFlags(
            .{ .view = s.view, .kind = @intFromEnum(proto.PointerKind.up), .x = b.x, .y = b.y, .button = b.button, .clicks = 1, .mods = 0 },
            @as(u32, 1) << @intCast(4 + @as(u32, b.button)),
        ),
        .key => |k| self.key(.{ .view = s.view, .kind = @intFromEnum(proto.KeyKind.up), .keyval = k, .keycode = 0, .mods = 0, .text = "" }),
    };
}

/// `dropBrowser`: whatever the stream client held was held in the
/// browser that just went away.
pub fn streamBrowserGone(self: *Host, view: u32) void {
    const s = streamOf(self, view) orelse return;
    s.held.clear();
}

// -- paint hooks ---------------------------------------------------------

/// View damage in physical pixels, from `onPaint`.
pub fn streamDamage(self: *Host, v: *const View, rects: []const proto.Rect) void {
    const s = streamOf(self, v.id) orelse return;
    for (rects) |r| s.damage(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
}

fn damageRect(self: *Host, v: *const View, r: st.Rect) void {
    const s = streamOf(self, v.id) orelse return;
    s.damage(r);
}

/// The popup rect in physical pixels, origin SIGNED: position from
/// `on_popup_size` (view-rect coordinates, already physical), size from
/// the popup paint itself. A popup can hang off the top or left of the
/// view, and its visible part then starts inside its own pixels.
const PopupRect = struct { x: i64, y: i64, w: u32, h: u32 };

fn popupPhys(v: *const View) PopupRect {
    return .{
        .x = v.widget_x,
        .y = v.widget_y,
        .w = v.widget_w,
        .h = v.widget_h,
    };
}

/// The part of the popup on the surface, as damage (empty when none).
fn popupDamage(v: *const View) st.Rect {
    const p = popupPhys(v);
    const x0 = @max(p.x, 0);
    const y0 = @max(p.y, 0);
    const x1 = p.x + p.w;
    const y1 = p.y + p.h;
    if (x1 <= x0 or y1 <= y0) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    return (st.Rect{ .x = @intCast(x0), .y = @intCast(y0), .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) }).clip(v.pw, v.ph);
}

fn dropPopup(self: *Host, v: *View) void {
    if (v.widget_map.len != 0) {
        damageRect(self, v, popupDamage(v));
        self.gpa.free(v.widget_map);
        v.widget_map = &.{};
    }
    v.widget_w = 0;
    v.widget_h = 0;
}

pub fn onPopupShow(_: [*c]cef.cef_render_handler_t, browser: [*c]cef.cef_browser_t, show: c_int) callconv(.c) void {
    defer releaseArg(browser);
    const host = host_mod.g_host orelse return;
    const v = viewOf(browser) orelse return;
    v.widget_shown = show != 0;
    if (!v.widget_shown) dropPopup(host, v);
}

pub fn onPopupSize(_: [*c]cef.cef_render_handler_t, browser: [*c]cef.cef_browser_t, rect: [*c]const cef.cef_rect_t) callconv(.c) void {
    defer releaseArg(browser);
    const host = host_mod.g_host orelse return;
    const v = viewOf(browser) orelse return;
    const r: *const cef.cef_rect_t = @ptrCast(rect orelse return);
    // The old position is damage too: the page shows through it again.
    if (v.widget_map.len != 0) damageRect(host, v, popupDamage(v));
    v.widget_x = r.x;
    v.widget_y = r.y;
    if (v.widget_map.len != 0) damageRect(host, v, popupDamage(v));
}

/// A `PET_POPUP` paint: keep the popup's pixels (they are composed over
/// the view at send time) and damage where it sits.
pub fn popupPaint(self: *Host, v: *View, buffer: ?*const anyopaque, width: c_int, height: c_int) void {
    if (!v.widget_shown or width <= 0 or height <= 0) return;
    const src: [*]const u8 = @ptrCast(buffer orelse return);
    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);
    const size = @as(usize, w) * h * 4;
    if (v.widget_map.len != size) {
        if (v.widget_map.len != 0) {
            damageRect(self, v, popupDamage(v));
            self.gpa.free(v.widget_map);
            v.widget_map = &.{};
        }
        v.widget_map = self.gpa.alloc(u8, size) catch return;
    }
    @memcpy(v.widget_map, src[0..size]);
    v.widget_w = w;
    v.widget_h = h;
    damageRect(self, v, popupDamage(v));
}

/// Free the popup copy with the browser (`dropBrowser`).
pub fn popupForget(self: *Host, v: *View) void {
    if (v.widget_map.len != 0) self.gpa.free(v.widget_map);
    v.widget_map = &.{};
    v.widget_w = 0;
    v.widget_h = 0;
    v.widget_shown = false;
}

// -- cursor --------------------------------------------------------------

/// CEF's cursor type as a CSS cursor name.
pub fn cursorName(ctype: cef.cef_cursor_type_t) []const u8 {
    return switch (ctype) {
        cef.CT_CROSS => "crosshair",
        cef.CT_HAND => "pointer",
        cef.CT_IBEAM => "text",
        cef.CT_WAIT => "wait",
        cef.CT_HELP => "help",
        cef.CT_EASTRESIZE => "e-resize",
        cef.CT_NORTHRESIZE => "n-resize",
        cef.CT_NORTHEASTRESIZE => "ne-resize",
        cef.CT_NORTHWESTRESIZE => "nw-resize",
        cef.CT_SOUTHRESIZE => "s-resize",
        cef.CT_SOUTHEASTRESIZE => "se-resize",
        cef.CT_SOUTHWESTRESIZE => "sw-resize",
        cef.CT_WESTRESIZE => "w-resize",
        cef.CT_NORTHSOUTHRESIZE => "ns-resize",
        cef.CT_EASTWESTRESIZE => "ew-resize",
        cef.CT_NORTHEASTSOUTHWESTRESIZE => "nesw-resize",
        cef.CT_NORTHWESTSOUTHEASTRESIZE => "nwse-resize",
        cef.CT_COLUMNRESIZE => "col-resize",
        cef.CT_ROWRESIZE => "row-resize",
        cef.CT_MIDDLEPANNING, cef.CT_EASTPANNING, cef.CT_NORTHPANNING, cef.CT_NORTHEASTPANNING, cef.CT_NORTHWESTPANNING, cef.CT_SOUTHPANNING, cef.CT_SOUTHEASTPANNING, cef.CT_SOUTHWESTPANNING, cef.CT_WESTPANNING, cef.CT_MIDDLE_PANNING_VERTICAL, cef.CT_MIDDLE_PANNING_HORIZONTAL => "all-scroll",
        cef.CT_MOVE => "move",
        cef.CT_VERTICALTEXT => "vertical-text",
        cef.CT_CELL => "cell",
        cef.CT_CONTEXTMENU => "context-menu",
        cef.CT_ALIAS, cef.CT_DND_LINK => "alias",
        cef.CT_PROGRESS => "progress",
        cef.CT_NODROP, cef.CT_NOTALLOWED, cef.CT_DND_NONE => "not-allowed",
        cef.CT_COPY, cef.CT_DND_COPY => "copy",
        cef.CT_ZOOMIN => "zoom-in",
        cef.CT_ZOOMOUT => "zoom-out",
        cef.CT_GRAB => "grab",
        cef.CT_GRABBING => "grabbing",
        cef.CT_DND_MOVE => "move",
        else => "default",
    };
}

/// From `onCursorChange`: hidden for `CT_NONE`, the image for a custom
/// cursor that fits `MAX_CURSOR_DIM`, otherwise its CSS name. Cached on
/// the VIEW whether or not a stream exists, so a stream opened later
/// starts from the page's real cursor; a stream is told only when it
/// actually changed.
pub fn streamCursor(self: *Host, v: *View, ctype: cef.cef_cursor_type_t, info: [*c]const cef.cef_cursor_info_t) void {
    if (setViewCursor(self, v, cursorOf(ctype, info))) {
        if (streamOf(self, v.id)) |s| s.markCursor();
    }
}

fn setViewCursor(self: *Host, v: *View, cur: st.Cursor) bool {
    return v.cursor.set(self.gpa, cur);
}

/// The engine's cursor as the stream's vocabulary; an `.image` borrows
/// the engine's buffer for this call only.
fn cursorOf(ctype: cef.cef_cursor_type_t, info: [*c]const cef.cef_cursor_info_t) st.Cursor {
    if (ctype == cef.CT_NONE) return .hidden;
    if (ctype == cef.CT_CUSTOM) custom: {
        const inf: *const cef.cef_cursor_info_t = @ptrCast(info orelse break :custom);
        const buf: [*]const u8 = @ptrCast(inf.buffer orelse break :custom);
        if (inf.size.width <= 0 or inf.size.height <= 0) break :custom;
        const w: u32 = @intCast(inf.size.width);
        const h: u32 = @intCast(inf.size.height);
        if (w > st.MAX_CURSOR_DIM or h > st.MAX_CURSOR_DIM) break :custom;
        return .{ .image = .{
            .w = w,
            .h = h,
            .hot_x = std.math.clamp(inf.hotspot.x, 0, @as(i32, @intCast(w)) - 1),
            .hot_y = std.math.clamp(inf.hotspot.y, 0, @as(i32, @intCast(h)) - 1),
            .bgra = buf[0 .. @as(usize, w) * h * 4],
        } };
    }
    return .{ .named = cursorName(ctype) };
}

// -- what the stream reads and drives -------------------------------------

fn source(self: *Host) srv.Source {
    return .{ .ctx = self, .surface = surface, .compose = compose, .input = input, .cursor = cursor };
}

fn cursor(ctx: *anyopaque, view: u32) st.Cursor {
    const self: *Host = @ptrCast(@alignCast(ctx));
    const v = self.findAny(view) orelse return .{ .named = "default" };
    return v.cursor.view();
}

fn surface(ctx: *anyopaque, view: u32) ?st.Surface {
    const self: *Host = @ptrCast(@alignCast(ctx));
    const v = self.findAny(view) orelse return null;
    // A freshly (re)allocated buffer is zeroes until the engine paints
    // into it; streaming that would flash black.
    if (v.discarded or v.hidden or v.buf_unpainted) return null;
    if (v.map.len < @as(usize, v.pw) * v.ph * 4 or v.pw == 0 or v.ph == 0) return null;
    return .{ .pixel_w = v.pw, .pixel_h = v.ph, .logical_w = v.w, .logical_h = v.h };
}

fn compose(ctx: *anyopaque, view: u32, r: st.Rect, dst: []u8) void {
    const self: *Host = @ptrCast(@alignCast(ctx));
    const v = self.findAny(view) orelse return @memset(dst, 0);
    const stride = @as(usize, v.pw) * 4;
    const row = @as(usize, r.w) * 4;
    for (0..r.h) |i| {
        const off = (@as(usize, r.y) + i) * stride + @as(usize, r.x) * 4;
        @memcpy(dst[i * row ..][0..row], v.map[off..][0..row]);
    }
    if (v.widget_map.len == 0) return;
    const pr = popupPhys(v);
    // Overlap of the band and the popup, in signed surface pixels.
    const x0 = @max(pr.x, @as(i64, r.x));
    const y0 = @max(pr.y, @as(i64, r.y));
    const x1 = @min(pr.x + pr.w, @as(i64, r.x) + r.w);
    const y1 = @min(pr.y + pr.h, @as(i64, r.y) + r.h);
    if (x1 <= x0 or y1 <= y0) return;
    const prow = @as(usize, pr.w) * 4;
    const n: usize = @intCast((x1 - x0) * 4);
    var y = y0;
    while (y < y1) : (y += 1) {
        // Source offsets are relative to the popup's own origin, which
        // may lie off the surface; the overlap keeps both non-negative.
        const src_off = @as(usize, @intCast(y - pr.y)) * prow + @as(usize, @intCast(x0 - pr.x)) * 4;
        const dst_off = @as(usize, @intCast(y - r.y)) * row + @as(usize, @intCast(x0 - r.x)) * 4;
        @memcpy(dst[dst_off..][0..n], v.widget_map[src_off..][0..n]);
    }
}

/// Whether the view has a running browser to deliver to WITHOUT a
/// revival. Ups, leaves and blurs only ever let go of something; to a
/// discarded view there is nothing to let go of, and waking it for that
/// would cost a page load (`streamBrowserGone` already forgot its holds).
fn awake(self: *Host, view: u32) bool {
    const v = self.findAny(view) orelse return false;
    return !v.discarded and v.browser != null;
}

fn input(ctx: *anyopaque, s: *srv.Stream, in: st.Input) void {
    const self: *Host = @ptrCast(@alignCast(ctx));
    if (self.findAny(s.view) == null) return s.shut("the view was destroyed");
    // The stream acts for the connection that opened it.
    const prev = self.dispatch_conn;
    self.dispatch_conn = s.owner;
    defer self.dispatch_conn = prev;
    switch (in) {
        .pointer => |p| {
            // The engine's button flags come from what the stream holds,
            // never from the client's mods: before the event, so a down
            // does not yet carry its own button and an up still does.
            const flags = s.held.cefButtons();
            s.held.pointer(p);
            if (!st.mayWake(in) and !awake(self, s.view)) return;
            self.pointerFlags(.{
                .view = s.view,
                .kind = @intFromEnum(p.action),
                .x = p.x,
                .y = p.y,
                .button = p.button,
                .clicks = p.clicks,
                .mods = st.modsToProto(p.mods),
            }, flags);
        },
        .wheel => |w| self.scrollFlags(
            .{ .view = s.view, .x = w.x, .y = w.y, .dx = w.dx, .dy = w.dy, .mods = st.modsToProto(w.mods) },
            s.held.cefButtons(),
        ),
        .key => |k| {
            const chord = webkeys.parseChord(k.name) catch return s.shut("unknown key name on the stream");
            const kind: proto.KeyKind = if (k.action == .down) .down else .up;
            const id = st.keyIdentity(chord.keysym);
            var keysym = chord.keysym;
            if (kind == .down) {
                // A down the release table cannot hold is dropped, never
                // left stuck on the page.
                if (!s.held.keyDown(id, chord.keysym)) return;
            } else {
                // The up names the key as its down did, whatever case the
                // client spelt it in this time.
                for (s.held.keys[0..s.held.nkeys]) |hk| {
                    if (hk.id == id) keysym = hk.keysym;
                }
                _ = s.held.keyUp(id);
                if (!st.mayWake(in) and !awake(self, s.view)) return;
            }
            const mods = st.modsToProto(k.mods) | chord.mods;
            // The chord's text was decided from the NAME's own mods only;
            // ctrl or alt from the frame's mods makes it a shortcut that
            // types nothing (Host.key then sends no char event either).
            const chorded = mods & (proto.mod_ctrl | proto.mod_alt) != 0;
            self.key(.{
                .view = s.view,
                .kind = @intFromEnum(kind),
                .keyval = keysym,
                .keycode = 0,
                .mods = mods,
                .text = if (kind == .down and !chorded) chord.textSlice() else "",
            });
        },
        .text => |txt| if (txt.len != 0) self.paste(.{ .view = s.view, .text = .{ .s = txt } }),
        .focus => |on| {
            if (!on) {
                releaseHeld(self, s);
                // A blur is let-go too: never a revival.
                if (!st.mayWake(in) and !awake(self, s.view)) return;
            }
            self.focus(.{ .view = s.view, .focused = @intFromBool(on) });
        },
        .resize => |sz| {
            const v = self.findAny(s.view) orelse return;
            self.resizeView(.{ .view = s.view, .w = @intCast(sz.w), .h = @intCast(sz.h), .scale_x1000 = v.scale_x1000 }) catch {};
        },
        .auth, .ack => {},
    }
}

// -- audio -----------------------------------------------------------------
//
// `get_audio_parameters` and `on_audio_stream_stopped` run on the UI
// thread, which here is the poll loop's own; started/packet/error run on
// the engine's audio threads and touch nothing but `srv.audio`.

pub var audio_handler: cef.cef_audio_handler_t = undefined;

pub fn installAudio() void {
    audio_handler = std.mem.zeroes(cef.cef_audio_handler_t);
    audio_handler.base = host_mod.staticBase(cef.cef_audio_handler_t);
    audio_handler.get_audio_parameters = onGetAudioParameters;
    audio_handler.on_audio_stream_started = onAudioStarted;
    audio_handler.on_audio_stream_packet = onAudioPacket;
    audio_handler.on_audio_stream_stopped = onAudioStopped;
    audio_handler.on_audio_stream_error = onAudioError;
}

pub fn getAudioHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_audio_handler_t {
    return &audio_handler;
}

fn browserId(browser: [*c]cef.cef_browser_t) i32 {
    const b: *cef.cef_browser_t = @ptrCast(browser orelse return 0);
    const gi = b.get_identifier orelse return 0;
    return gi(b);
}

/// Capture only for a view whose authenticated stream asked for audio:
/// a captured page is NOT heard through the helper's own output, so
/// every other page must stay uncaptured.
fn onGetAudioParameters(_: [*c]cef.cef_audio_handler_t, browser: [*c]cef.cef_browser_t, params: [*c]cef.cef_audio_parameters_t) callconv(.c) c_int {
    defer releaseArg(browser);
    const host = host_mod.g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    const s = streamOf(host, v.id) orelse return 0;
    const slot = s.audio_slot orelse return 0;
    const p: *cef.cef_audio_parameters_t = @ptrCast(params orelse return 0);
    p.sample_rate = srv.Audio.RATE;
    p.channel_layout = cef.CEF_CHANNEL_LAYOUT_STEREO;
    srv.audio.bind(slot, browserId(browser));
    return 1;
}

fn onAudioStarted(_: [*c]cef.cef_audio_handler_t, browser: [*c]cef.cef_browser_t, params: [*c]const cef.cef_audio_parameters_t, channels: c_int) callconv(.c) void {
    defer releaseArg(browser);
    const p: *const cef.cef_audio_parameters_t = @ptrCast(params orelse return);
    if (p.sample_rate <= 0 or channels <= 0) return;
    srv.audio.start(browserId(browser), @intCast(p.sample_rate), @intCast(channels));
}

fn onAudioPacket(_: [*c]cef.cef_audio_handler_t, browser: [*c]cef.cef_browser_t, data: [*c][*c]const f32, frames: c_int, pts: i64) callconv(.c) void {
    defer releaseArg(browser);
    if (data == null or frames <= 0) return;
    const id = browserId(browser);
    // `data` holds exactly as many planes as the stream has channels;
    // two at most are read and mono duplicates its one plane.
    const n = @min(srv.audio.channelsOf(id), 2);
    if (n == 0) return;
    var planes: [2][*]const f32 = undefined;
    for (0..n) |i| planes[i] = @ptrCast(data[i] orelse return);
    srv.audio.push(id, planes[0..n], @intCast(frames), pts);
}

fn onAudioStopped(_: [*c]cef.cef_audio_handler_t, browser: [*c]cef.cef_browser_t) callconv(.c) void {
    defer releaseArg(browser);
    srv.audio.stop(browserId(browser));
}

fn onAudioError(_: [*c]cef.cef_audio_handler_t, browser: [*c]cef.cef_browser_t, _: [*c]const cef.cef_string_t) callconv(.c) void {
    defer releaseArg(browser);
    srv.audio.stop(browserId(browser));
}
