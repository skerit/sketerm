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
    Timeout,
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

    /// Spawn an app session on the local (autostart) daemon, or on
    /// `host` over SSH, and attach as a proto-v5 viewer.
    pub fn launch(
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        cols: u16,
        rows: u16,
        host: ?[]const u8,
    ) Error!*App {
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
        }) catch return Error.SpawnFailed;
        (conn.recvExpect(&.{.ok}) catch return Error.SpawnFailed).deinit(allocator);
        conn.sendJson(.attach, .{ .name = name }) catch return Error.SpawnFailed;
        (conn.recvExpect(&.{.snapshot}) catch return Error.SpawnFailed).deinit(allocator);

        const self = allocator.create(App) catch return Error.OutOfMemory;
        self.* = .{ .allocator = allocator, .conn = conn, .name = name };
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

    pub fn typeText(self: *App, win_id: ?u32, text: []const u8) Error!void {
        const win = try self.resolveKbd(win_id);
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        var shift_held = false;
        for (text) |chr| {
            const key = evkeys.charKey(chr) orelse return Error.BadKey;
            if (key.shift != shift_held) {
                shift_held = key.shift;
                wlpipe.appendSeatMods(&units, a, if (shift_held) 1 else 0, 0, 0, 0) catch return Error.OutOfMemory;
            }
            wlpipe.appendSeatKey(&units, a, key.code, true) catch return Error.OutOfMemory;
            wlpipe.appendSeatKey(&units, a, key.code, false) catch return Error.OutOfMemory;
        }
        if (shift_held) wlpipe.appendSeatMods(&units, a, 0, 0, 0, 0) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    pub fn pressKey(self: *App, win_id: ?u32, spec: []const u8) Error!void {
        const chord = evkeys.parseChord(spec) orelse return Error.BadKey;
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

    /// Latest committed pixels of one window as a PNG. Caller owns.
    pub fn screenshotPng(self: *App, win_id: u32) Error![]u8 {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        if (win.w <= 0 or win.h <= 0 or win.pixels.items.len == 0) return Error.NoSuchWindow;
        const uw: u32 = @intCast(win.w);
        const uh: u32 = @intCast(win.h);
        return png.encodeShm(self.allocator, win.pixels.items, uw, uh, uw * 4, win.format) catch
            return Error.OutOfMemory;
    }
};
