//! Headless driver for forwarded Wayland apps: a proto-v5 mux client
//! that spawns app sessions, keeps passive replica compositors per
//! channel (windows render into memory, nothing on any display),
//! captures PNG screenshots, and injects seat input as intent units.
//! GTK-free — usable from `sketerm mcp` without a GUI anywhere.

const std = @import("std");
const c = @import("../c.zig").c;
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const wlpipe = @import("../wlhost/pipe.zig");
const wlcomp = @import("../wlhost/compositor.zig");
const png = @import("../util/png.zig");
const evkeys = @import("evkeys.zig");
const xkblayout = @import("xkblayout.zig");
const keymaps = @import("../wlhost/keymaps.zig");

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

pub const Error = error{
    SpawnFailed,
    NotConnected,
    NoSuchWindow,
    BadKey,
    BadLayout,
    Timeout,
    NoClipboard,
    OutOfMemory,
};

/// Query the daemon host's installed GUI apps (name + exec) without
/// spawning anything. `host` null = local autostart daemon. Returns a
/// JSON array string (arena-owned via the passed allocator's arena
/// semantics: caller frees with allocator.free).
pub fn listInstalledApps(allocator: std.mem.Allocator, host: ?[]const u8) Error![]u8 {
    var conn = blk: {
        if (host) |h| break :blk muxclient.Conn.connectSsh(allocator, h) catch return Error.SpawnFailed;
        break :blk muxclient.Conn.connectLocalAutostart(allocator) catch return Error.SpawnFailed;
    };
    defer conn.deinit();
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch return Error.NotConnected;
    (conn.recvExpect(&.{.welcome}) catch return Error.NotConnected).deinit(allocator);
    // app_list needs no session attach — the daemon scans its own host.
    conn.sendFrame(.app_list, "") catch return Error.NotConnected;
    const f = conn.recvExpect(&.{.app_listing}) catch return Error.Timeout;
    defer f.deinit(allocator);
    return allocator.dupe(u8, f.payload) catch return Error.OutOfMemory;
}

/// One rendered toplevel (or popup) surface of one app channel.
pub const Window = struct {
    /// Stable public id (MCP-facing), unique within the App.
    id: u32,
    chan: u32,
    sid: u32,
    w: i32 = 0,
    h: i32 = 0,
    scale: i32 = 1,
    format: u32 = 0,
    /// Latest committed pixels, tightly packed w*4 (wl_shm layout).
    pixels: std.ArrayList(u8) = .empty,
    title: ?[]u8 = null,
    app_id: ?[]u8 = null,
    popup: bool = false,
    frames: u64 = 0,

    fn deinit(self: *Window, a: std.mem.Allocator) void {
        self.pixels.deinit(a);
        if (self.title) |s| a.free(s);
        if (self.app_id) |s| a.free(s);
    }
};

/// One wayland_native channel = one app display connection, with its
/// own replica compositor.
const Chan = struct {
    app: *App,
    id: u32,
    comp: wlcomp.Compositor,
};

var name_counter: u32 = 0;

pub const App = struct {
    allocator: std.mem.Allocator,
    conn: muxclient.Conn,
    name: []u8,
    chans: std.AutoArrayHashMapUnmanaged(u32, *Chan) = .empty,
    windows: std.ArrayList(*Window) = .empty,
    next_win_id: u32 = 1,
    /// Bumped on every committed frame — the quiescence signal.
    frame_seq: u64 = 0,
    exited: bool = false,
    exit_status: i32 = 0,
    /// Toplevel the keyboard was last aimed at (0 = none yet).
    kbd_focus: u32 = 0, // public window id
    /// Latest clipboard selection the app announced (copy source).
    clip_offer: ?ClipOffer = null,
    /// Fetched app-clipboard bytes (answer to a clip_send).
    clip_buf: std.ArrayList(u8) = .empty,
    clip_got: bool = false,
    /// Text we offered as the host clipboard; served on app paste.
    paste_data: ?[]u8 = null,
    /// Parsed session keymap for layout-aware typing (null = the
    /// builtin us tables in evkeys.zig).
    layout: ?xkblayout.Layout = null,

    const ClipOffer = struct { chan: u32, source: u32, mime: []u8 };

    /// Spawn an app session on the local (autostart) daemon, or on
    /// `host` over SSH, and attach as a proto-v5 viewer. `kb_layout`
    /// picks the session keymap (wlhost/keymaps.zig; null/"" = us) —
    /// typing is encoded against the same blob.
    pub fn launch(
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        cols: u16,
        rows: u16,
        host: ?[]const u8,
        kb_layout: ?[]const u8,
    ) Error!*App {
        const layout_name = kb_layout orelse "";
        const blob = keymaps.get(layout_name) orelse return Error.BadLayout;
        var layout: ?xkblayout.Layout = xkblayout.parse(allocator, blob) catch null;
        errdefer if (layout) |*l| l.deinit(allocator);
        var conn = blk: {
            if (host) |h| break :blk muxclient.Conn.connectSsh(allocator, h) catch return Error.SpawnFailed;
            break :blk muxclient.Conn.connectLocalAutostart(allocator) catch return Error.SpawnFailed;
        };
        errdefer conn.deinit();

        conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch return Error.SpawnFailed;
        (conn.recvExpect(&.{.welcome}) catch return Error.SpawnFailed).deinit(allocator);

        name_counter += 1;
        const name = std.fmt.allocPrint(allocator, "mcpapp-{d}-{d}", .{ c.getpid(), name_counter }) catch
            return Error.OutOfMemory;
        errdefer allocator.free(name);

        conn.sendJson(.spawn, .{
            .name = name,
            .argv = argv,
            .rows = rows,
            .cols = cols,
            .app = true,
            .kb_layout = layout_name,
        }) catch return Error.SpawnFailed;
        (conn.recvExpect(&.{.ok}) catch return Error.SpawnFailed).deinit(allocator);
        conn.sendJson(.attach, .{ .name = name }) catch return Error.SpawnFailed;
        (conn.recvExpect(&.{.snapshot}) catch return Error.SpawnFailed).deinit(allocator);

        const self = allocator.create(App) catch return Error.OutOfMemory;
        self.* = .{ .allocator = allocator, .conn = conn, .name = name, .layout = layout };
        layout = null; // ownership moved
        return self;
    }

    /// Kill the session (the app dies with it) and free everything.
    pub fn deinit(self: *App) void {
        const a = self.allocator;
        if (!self.exited) {
            self.conn.sendJson(.kill, .{ .name = self.name }) catch {};
        }
        self.conn.deinit();
        for (self.chans.values()) |ch| {
            ch.comp.deinit();
            a.destroy(ch);
        }
        self.chans.deinit(a);
        for (self.windows.items) |w| {
            w.deinit(a);
            a.destroy(w);
        }
        self.windows.deinit(a);
        if (self.clip_offer) |o| a.free(o.mime);
        self.clip_buf.deinit(a);
        if (self.paste_data) |p| a.free(p);
        if (self.layout) |*l| l.deinit(a);
        a.free(self.name);
        a.destroy(self);
    }

    // ── stream pumping ──────────────────────────────────────────

    fn pollIn(fd: c_int, ms: i32) bool {
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const r = c.poll(&pfd, 1, ms);
        return r > 0 and (pfd.revents & (c.POLLIN | c.POLLHUP)) != 0;
    }

    /// Process at most one incoming frame, waiting up to `wait_ms`.
    /// Returns false when nothing arrived in time (or after exit).
    pub fn pumpOnce(self: *App, wait_ms: i32) bool {
        if (self.exited) return false;
        if (!pollIn(self.conn.fd, wait_ms)) return false;
        const f = self.conn.recvFrame() catch {
            self.exited = true;
            return false;
        };
        defer f.deinit(self.allocator);
        self.handleFrame(f.ftype, f.payload);
        return true;
    }

    /// Drain whatever is queued without blocking.
    pub fn drain(self: *App) void {
        while (self.pumpOnce(0)) {}
    }

    fn handleFrame(self: *App, ftype: wire.FrameType, payload: []const u8) void {
        switch (ftype) {
            .chan_open => {
                const open = wire.decodeChanOpen(payload) orelse return;
                if (open.kind != .wayland_native) return;
                const ch = self.allocator.create(Chan) catch return;
                ch.* = .{ .app = self, .id = open.id, .comp = undefined };
                ch.comp = wlcomp.Compositor.init(self.allocator, .{
                    .ctx = ch,
                    .toplevel_new = onNew,
                    .toplevel_frame = onFrame,
                    .toplevel_title = onTitle,
                    .toplevel_app_id = onAppId,
                    .toplevel_gone = onGone,
                    .popup_new = onPopupNew,
                    .popup_gone = onGone,
                    .clipboard_offer = onClipOffer,
                    .clipboard_data = onClipData,
                    .clipboard_read = onClipRead,
                }) catch {
                    self.allocator.destroy(ch);
                    return;
                };
                ch.comp.lenient = true;
                self.chans.put(self.allocator, open.id, ch) catch {
                    ch.comp.deinit();
                    self.allocator.destroy(ch);
                };
            },
            .chan_close => {
                const id = wire.decodeChanId(payload) orelse return;
                if (self.chans.fetchSwapRemove(id)) |kv| {
                    self.dropChanWindows(id);
                    kv.value.comp.deinit();
                    self.allocator.destroy(kv.value);
                }
            },
            .chan_data => {
                const id = wire.decodeChanId(payload) orelse return;
                const ch = self.chans.get(id) orelse return;
                ch.comp.feed(payload[4..]) catch {};
                ch.comp.clearOut(); // replica output is discarded
            },
            .exit => {
                self.exited = true;
                if (payload.len >= 4) self.exit_status = std.mem.readInt(i32, payload[0..4], .little);
            },
            else => {},
        }
    }

    fn dropChanWindows(self: *App, chan: u32) void {
        var i: usize = 0;
        while (i < self.windows.items.len) {
            if (self.windows.items[i].chan == chan) {
                const w = self.windows.swapRemove(i);
                w.deinit(self.allocator);
                self.allocator.destroy(w);
            } else i += 1;
        }
    }

    fn winBySurface(self: *App, chan: u32, sid: u32) ?*Window {
        for (self.windows.items) |w| {
            if (w.chan == chan and w.sid == sid) return w;
        }
        return null;
    }

    pub fn winById(self: *App, id: u32) ?*Window {
        for (self.windows.items) |w| {
            if (w.id == id) return w;
        }
        return null;
    }

    fn ensureWindow(self: *App, chan: u32, sid: u32, popup: bool) ?*Window {
        if (self.winBySurface(chan, sid)) |w| return w;
        const w = self.allocator.create(Window) catch return null;
        w.* = .{ .id = self.next_win_id, .chan = chan, .sid = sid, .popup = popup };
        self.next_win_id += 1;
        self.windows.append(self.allocator, w) catch {
            self.allocator.destroy(w);
            return null;
        };
        return w;
    }

    // ── replica view callbacks ──────────────────────────────────

    fn chanOf(ctx: ?*anyopaque) *Chan {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onNew(ctx: ?*anyopaque, sid: u32) void {
        const ch = chanOf(ctx);
        _ = ch.app.ensureWindow(ch.id, sid, false);
    }

    fn onPopupNew(ctx: ?*anyopaque, sid: u32, parent: u32, x: i32, y: i32) void {
        _ = parent;
        _ = x;
        _ = y;
        const ch = chanOf(ctx);
        _ = ch.app.ensureWindow(ch.id, sid, true);
    }

    fn onFrame(ctx: ?*anyopaque, sid: u32, w: i32, h: i32, scale: i32, format: u32, pixels: []const u8) void {
        const ch = chanOf(ctx);
        const win = ch.app.ensureWindow(ch.id, sid, false) orelse return;
        win.w = w;
        win.h = h;
        win.scale = scale;
        win.format = format;
        win.pixels.clearRetainingCapacity();
        win.pixels.appendSlice(ch.app.allocator, pixels) catch {};
        win.frames += 1;
        ch.app.frame_seq += 1;
    }

    fn onTitle(ctx: ?*anyopaque, sid: u32, title: []const u8) void {
        const ch = chanOf(ctx);
        const win = ch.app.ensureWindow(ch.id, sid, false) orelse return;
        const copy = ch.app.allocator.dupe(u8, title) catch return;
        if (win.title) |old| ch.app.allocator.free(old);
        win.title = copy;
    }

    fn onAppId(ctx: ?*anyopaque, sid: u32, app_id: []const u8) void {
        const ch = chanOf(ctx);
        const win = ch.app.ensureWindow(ch.id, sid, false) orelse return;
        const copy = ch.app.allocator.dupe(u8, app_id) catch return;
        if (win.app_id) |old| ch.app.allocator.free(old);
        win.app_id = copy;
    }

    fn onClipOffer(ctx: ?*anyopaque, source: u32, mime: []const u8) void {
        const ch = chanOf(ctx);
        const a = ch.app.allocator;
        const copy = a.dupe(u8, mime) catch return;
        if (ch.app.clip_offer) |old| a.free(old.mime);
        ch.app.clip_offer = .{ .chan = ch.id, .source = source, .mime = copy };
    }

    fn onClipData(ctx: ?*anyopaque, bytes: []const u8) void {
        const ch = chanOf(ctx);
        ch.app.clip_buf.clearRetainingCapacity();
        ch.app.clip_buf.appendSlice(ch.app.allocator, bytes) catch return;
        ch.app.clip_got = true;
    }

    fn onClipRead(ctx: ?*anyopaque, mime: []const u8) void {
        _ = mime;
        const ch = chanOf(ctx);
        const data = ch.app.paste_data orelse "";
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(ch.app.allocator);
        wlpipe.appendUnit(&units, ch.app.allocator, .clip_data, data) catch return;
        ch.app.sendIntents(ch.id, units.items) catch {};
    }

    fn onGone(ctx: ?*anyopaque, sid: u32) void {
        const ch = chanOf(ctx);
        var i: usize = 0;
        while (i < ch.app.windows.items.len) {
            const w = ch.app.windows.items[i];
            if (w.chan == ch.id and w.sid == sid) {
                _ = ch.app.windows.swapRemove(i);
                w.deinit(ch.app.allocator);
                ch.app.allocator.destroy(w);
                continue;
            }
            i += 1;
        }
    }

    // ── waiting ─────────────────────────────────────────────────

    /// Pump until at least one toplevel has pixels (or timeout).
    pub fn waitFirstWindow(self: *App, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (nowMs() < deadline) {
            for (self.windows.items) |w| {
                if (!w.popup and w.frames > 0) return true;
            }
            if (self.exited) return false;
            _ = self.pumpOnce(50);
        }
        for (self.windows.items) |w| {
            if (!w.popup and w.frames > 0) return true;
        }
        return false;
    }

    /// Pump until no frame arrived for `quiet_ms` (bounded by
    /// `timeout_ms`). Returns true when quiescence was reached.
    pub fn waitIdle(self: *App, quiet_ms: i64, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        var last_seq = self.frame_seq;
        var quiet_since = nowMs();
        while (nowMs() < deadline) {
            _ = self.pumpOnce(25);
            if (self.frame_seq != last_seq) {
                last_seq = self.frame_seq;
                quiet_since = nowMs();
            } else if (nowMs() - quiet_since >= quiet_ms) {
                return true;
            }
            if (self.exited) return true;
        }
        return false;
    }

    // ── input intents ───────────────────────────────────────────

    fn sendIntents(self: *App, chan: u32, units: []const u8) Error!void {
        if (self.exited) return Error.NotConnected;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, chan, .little);
        payload.appendSlice(self.allocator, &idb) catch return Error.OutOfMemory;
        payload.appendSlice(self.allocator, units) catch return Error.OutOfMemory;
        self.conn.sendFrame(.chan_data, payload.items) catch return Error.NotConnected;
    }

    /// Left=1 Middle=2 Right=3 (GDK numbering) → evdev BTN_*.
    fn evdevButton(button: u32) u32 {
        return switch (button) {
            2 => 0x112,
            3 => 0x111,
            else => 0x110,
        };
    }

    pub fn click(self: *App, win_id: u32, x: f64, y: f64, button: u32) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatEnter(&units, a, win.sid, x, y) catch return Error.OutOfMemory;
        wlpipe.appendSeatMotion(&units, a, x, y) catch return Error.OutOfMemory;
        wlpipe.appendSeatButton(&units, a, evdevButton(button), true) catch return Error.OutOfMemory;
        wlpipe.appendSeatButton(&units, a, evdevButton(button), false) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    pub fn scroll(self: *App, win_id: u32, x: f64, y: f64, dx: f64, dy: f64) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatEnter(&units, a, win.sid, x, y) catch return Error.OutOfMemory;
        if (dy != 0) wlpipe.appendSeatAxis(&units, a, 0, dy * 10.0) catch return Error.OutOfMemory;
        if (dx != 0) wlpipe.appendSeatAxis(&units, a, 1, dx * 10.0) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    /// Press-move-release drag. Motions go out in small bursts with
    /// pumps between so the app sees a gesture, not one event blob.
    pub fn drag(self: *App, win_id: u32, x1: f64, y1: f64, x2: f64, y2: f64, button: u32) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatEnter(&units, a, win.sid, x1, y1) catch return Error.OutOfMemory;
        wlpipe.appendSeatMotion(&units, a, x1, y1) catch return Error.OutOfMemory;
        wlpipe.appendSeatButton(&units, a, evdevButton(button), true) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
        const dist = @max(@abs(x2 - x1), @abs(y2 - y1));
        const steps: u32 = @intFromFloat(std.math.clamp(dist / 16.0, 4.0, 40.0));
        var i: u32 = 1;
        while (i <= steps) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            units.clearRetainingCapacity();
            wlpipe.appendSeatMotion(&units, a, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t) catch return Error.OutOfMemory;
            try self.sendIntents(win.chan, units.items);
            if (i % 4 == 0) _ = self.pumpOnce(5);
        }
        units.clearRetainingCapacity();
        wlpipe.appendSeatButton(&units, a, evdevButton(button), false) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    // ── clipboard ───────────────────────────────────────────────

    /// Fetch what the app last copied. Requires the app to have
    /// announced a selection (clip_offer); pumps until the daemon
    /// pipes the bytes back. Caller owns the result.
    pub fn getClipboard(self: *App, timeout_ms: i64) Error![]u8 {
        self.drain();
        const offer = self.clip_offer orelse return Error.NoClipboard;
        const a = self.allocator;
        self.clip_got = false;
        var pl: std.ArrayList(u8) = .empty;
        defer pl.deinit(a);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, offer.source, .little);
        pl.appendSlice(a, &idb) catch return Error.OutOfMemory;
        pl.appendSlice(a, offer.mime) catch return Error.OutOfMemory;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendUnit(&units, a, .clip_send, pl.items) catch return Error.OutOfMemory;
        try self.sendIntents(offer.chan, units.items);
        const deadline = nowMs() + timeout_ms;
        while (!self.clip_got and nowMs() < deadline) {
            if (self.exited) return Error.NotConnected;
            _ = self.pumpOnce(25);
        }
        if (!self.clip_got) return Error.Timeout;
        return a.dupe(u8, self.clip_buf.items) catch Error.OutOfMemory;
    }

    /// Announce `text` as the host clipboard toward every app
    /// connection; served when the app pastes (onClipRead).
    pub fn setClipboard(self: *App, text: []const u8) Error!void {
        const a = self.allocator;
        const copy = a.dupe(u8, text) catch return Error.OutOfMemory;
        if (self.paste_data) |old| a.free(old);
        self.paste_data = copy;
        for (self.chans.values()) |ch| {
            var units: std.ArrayList(u8) = .empty;
            defer units.deinit(a);
            wlpipe.appendUnit(&units, a, .offer_selection, "text/plain;charset=utf-8") catch
                return Error.OutOfMemory;
            self.sendIntents(ch.id, units.items) catch {};
        }
    }

    /// Clipboard-paste text into a window: offer + Ctrl+V. The paste
    /// itself completes during subsequent pumps (waitIdle/drain).
    pub fn pasteText(self: *App, win_id: ?u32, text: []const u8) Error!void {
        try self.setClipboard(text);
        _ = try self.resolveKbd(win_id);
        try self.pressKey(win_id, "ctrl+v");
    }

    /// Aim the keyboard at a window (idempotent).
    fn kbdTarget(self: *App, win_id: u32) Error!*Window {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatKbdEnter(&units, a, win.sid) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
        self.kbd_focus = win_id;
        return win;
    }

    /// Default keyboard target: the explicit id, or the first toplevel.
    fn resolveKbd(self: *App, win_id: ?u32) Error!*Window {
        if (win_id) |id| return self.kbdTarget(id);
        if (self.kbd_focus != 0) {
            if (self.winById(self.kbd_focus)) |w| return w;
        }
        for (self.windows.items) |w| {
            if (!w.popup) return self.kbdTarget(w.id);
        }
        return Error.NoSuchWindow;
    }

    /// Codepoint -> keycode+mods against the session's keymap (or
    /// the builtin us tables when no layout was parsed).
    fn charEntry(self: *App, cp: u21) ?xkblayout.Entry {
        if (cp == '\n') return .{ .code = evkeys.KEY_ENTER };
        if (cp == '\t') return .{ .code = 15 };
        if (self.layout) |*l| return l.lookup(cp);
        if (cp > 127) return null;
        const k = evkeys.charKey(@intCast(cp)) orelse return null;
        return .{ .code = k.code, .shift = k.shift };
    }

    pub fn typeText(self: *App, win_id: ?u32, text: []const u8) Error!void {
        // Anything the keymap can't express goes through the
        // clipboard-paste path instead.
        const view = std.unicode.Utf8View.init(text) catch
            return self.pasteText(win_id, text);
        var probe = view.iterator();
        while (probe.nextCodepoint()) |cp| {
            if (self.charEntry(cp) == null) return self.pasteText(win_id, text);
        }
        const win = try self.resolveKbd(win_id);
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        var held: u32 = 0;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const e = self.charEntry(cp) orelse return Error.BadKey;
            const want: u32 = (@as(u32, @intFromBool(e.shift))) | (@as(u32, @intFromBool(e.altgr)) * 128);
            if (want != held) {
                held = want;
                wlpipe.appendSeatMods(&units, a, held, 0, 0, 0) catch return Error.OutOfMemory;
            }
            wlpipe.appendSeatKey(&units, a, e.code, true) catch return Error.OutOfMemory;
            wlpipe.appendSeatKey(&units, a, e.code, false) catch return Error.OutOfMemory;
        }
        if (held != 0) wlpipe.appendSeatMods(&units, a, 0, 0, 0, 0) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    pub fn pressKey(self: *App, win_id: ?u32, spec: []const u8) Error!void {
        var chord = evkeys.parseChord(spec) orelse return Error.BadKey;
        if (chord.ch) |ch| {
            // Chord letters name CHARACTERS ("ctrl+c" means the key
            // that types 'c'), so they follow the session layout.
            if (self.layout != null) {
                const e = self.charEntry(ch) orelse return Error.BadKey;
                chord.key.code = e.code;
                chord.mods.shift = chord.mods.shift or e.shift;
                chord.mods.altgr = e.altgr;
            }
        }
        const win = try self.resolveKbd(win_id);
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        if (chord.mods.any())
            wlpipe.appendSeatMods(&units, a, chord.mods.bits(), 0, 0, 0) catch return Error.OutOfMemory;
        wlpipe.appendSeatKey(&units, a, chord.key.code, true) catch return Error.OutOfMemory;
        wlpipe.appendSeatKey(&units, a, chord.key.code, false) catch return Error.OutOfMemory;
        if (chord.mods.any())
            wlpipe.appendSeatMods(&units, a, 0, 0, 0, 0) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    pub fn resizeWindow(self: *App, win_id: u32, w: i32, h: i32) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendConfigure(&units, a, win.sid, w, h, 1) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    pub fn closeWindow(self: *App, win_id: u32) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendRequestClose(&units, a, win.sid) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    // ── capture ─────────────────────────────────────────────────

    pub const Shot = struct {
        png: []u8,
        /// Emitted image dimensions (after any downscale).
        img_w: u32,
        img_h: u32,
        /// Surface pixels per image pixel; multiply image coords by
        /// this to get click coordinates. 1.0 = no downscale.
        scale: f64,
    };

    /// Latest committed pixels of one window as a PNG, downscaled so
    /// neither dimension exceeds `max_dim` (0 = no bound). Caller
    /// owns `.png`.
    pub fn screenshotPng(self: *App, win_id: u32, max_dim: u32) Error!Shot {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        if (win.w <= 0 or win.h <= 0 or win.pixels.items.len == 0) return Error.NoSuchWindow;
        const uw: u32 = @intCast(win.w);
        const uh: u32 = @intCast(win.h);
        const a = self.allocator;
        const longest = @max(uw, uh);
        if (max_dim == 0 or longest <= max_dim) {
            const bytes = png.encodeShm(a, win.pixels.items, uw, uh, uw * 4, win.format) catch
                return Error.OutOfMemory;
            return .{ .png = bytes, .img_w = uw, .img_h = uh, .scale = 1.0 };
        }
        const rgba = png.shmToRgba(a, win.pixels.items, uw, uh, uw * 4, win.format) catch
            return Error.OutOfMemory;
        defer a.free(rgba);
        const dw: u32 = @max(1, uw * max_dim / longest);
        const dh: u32 = @max(1, uh * max_dim / longest);
        const small = png.downscaleRgba(a, rgba, uw, uh, dw, dh) catch return Error.OutOfMemory;
        defer a.free(small);
        const bytes = png.encodeRgba(a, small, dw, dh) catch return Error.OutOfMemory;
        return .{
            .png = bytes,
            .img_w = dw,
            .img_h = dh,
            .scale = @as(f64, @floatFromInt(uw)) / @as(f64, @floatFromInt(dw)),
        };
    }
};
