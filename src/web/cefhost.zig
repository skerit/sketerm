//! CEF containment: the ONLY file in sketerm-web that sees a CEF type.
//!
//! It owns the browser fleet (one windowless browser per protocol view),
//! turns OnPaint into memfd + `frame_damage`, turns CEF notifications
//! into protocol events, and turns protocol input frames into trusted
//! CEF input. Everything crosses the boundary as `protocol.zig` values,
//! so swapping engines means replacing this file and nothing else.
//!
//! THREADING: `multi_threaded_message_loop = 0` and
//! `external_message_pump = 0`, so every callback below arrives on the
//! thread that calls `pump()` — the single process thread. There is
//! therefore no lock, no atomic and no queue-to-main-thread anywhere in
//! sketerm-web, and adding a thread would invalidate all of it.
//!
//! REFCOUNTS: the static handler structs use no-op add_ref/release.
//! That is sound ONLY because they are process-lifetime statics that CEF
//! may never free; it is NOT a general pattern. Objects CEF hands US
//! (browser, host, frame) are returned with a reference held, and every
//! one of them is released here after use.

const std = @import("std");
const cef = @import("cef");
const c = @import("cbindings");
const proto = @import("protocol.zig");
const keymap = @import("keymap.zig");

// The event-flag values keymap.zig hardcodes to stay CEF-free.
comptime {
    std.debug.assert(keymap.flag_shift == cef.EVENTFLAG_SHIFT_DOWN);
    std.debug.assert(keymap.flag_control == cef.EVENTFLAG_CONTROL_DOWN);
    std.debug.assert(keymap.flag_alt == cef.EVENTFLAG_ALT_DOWN);
    std.debug.assert(keymap.flag_command == cef.EVENTFLAG_COMMAND_DOWN);
    std.debug.assert(keymap.flag_caps_lock == cef.EVENTFLAG_CAPS_LOCK_ON);
    std.debug.assert(keymap.flag_num_lock == cef.EVENTFLAG_NUM_LOCK_ON);
    std.debug.assert(keymap.flag_is_key_pad == cef.EVENTFLAG_IS_KEY_PAD);
    std.debug.assert(keymap.flag_left_mouse == cef.EVENTFLAG_LEFT_MOUSE_BUTTON);
}

/// memfd_create hides behind _GNU_SOURCE, which translate-c does not
/// define — declared here, resolved at link (Linux-only helper).
extern fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
const MFD_CLOEXEC: c_uint = 1;

/// Cap on damage rects forwarded per paint; beyond it a single
/// full-view rect is cheaper than the bookkeeping.
const max_rects = 32;

// ---------------------------------------------------------------------
// Per-view state
// ---------------------------------------------------------------------

/// One protocol view: a windowless browser plus its shared frame buffer.
pub const View = struct {
    id: u32,
    /// CEF's own browser id, the key callbacks are resolved through.
    cef_id: c_int = 0,
    /// Owned reference from create_browser_sync; released on destroy.
    browser: ?*cef.cef_browser_t = null,
    w: u16,
    h: u16,
    scale_x1000: u16,
    buf_id: u32 = 0,
    /// Writable mapping of the memfd announced by `frame_buffer`. The
    /// fd itself is handed to the client and closed by the sender: a
    /// mapping outlives its descriptor.
    map: []align(std.heap.page_size_min) u8 = &.{},
    gen: u32 = 0,
    hidden: bool = false,
    /// Last address CEF reported, owned; the `ev_nav_state` payload.
    url: []u8 = &.{},

    fn stride(self: *const View) u32 {
        return @as(u32, self.w) * 4;
    }
};

// ---------------------------------------------------------------------
// Host
// ---------------------------------------------------------------------

/// The browser fleet plus its outbound protocol queue.
///
/// A single instance per process, reachable from the C callbacks
/// through `g_host` — CEF handlers take no user-data pointer, and the
/// single-threaded loop makes a global sound here.
pub const Host = struct {
    gpa: std.mem.Allocator,
    out: *proto.Outbox,
    views: std.ArrayList(*View) = .empty,
    /// The view a create_browser_sync call is currently building, for
    /// the callbacks CEF fires BEFORE it returns the browser pointer.
    pending: ?*View = null,

    pub fn init(gpa: std.mem.Allocator, out: *proto.Outbox) Host {
        return .{ .gpa = gpa, .out = out };
    }

    pub fn deinit(self: *Host) void {
        self.destroyAll();
        self.views.deinit(self.gpa);
        if (g_host == self) g_host = null;
    }

    /// Publish this host to the CEF callbacks and build the handler set.
    pub fn install(self: *Host) void {
        g_host = self;
        installHandlers();
    }

    pub fn find(self: *Host, id: u32) ?*View {
        for (self.views.items) |v| {
            if (v.id == id) return v;
        }
        return null;
    }

    fn findCef(self: *Host, cef_id: c_int) ?*View {
        for (self.views.items) |v| {
            if (v.cef_id == cef_id) return v;
        }
        return null;
    }

    pub fn viewCount(self: *const Host) usize {
        return self.views.items.len;
    }

    /// Create a windowless browser for `id`. A duplicate id is ignored
    /// (view ids are client-allocated and never reused).
    pub fn createView(self: *Host, req: proto.ViewCreate) !void {
        if (req.view == 0 or self.find(req.view) != null) return;
        const v = try self.gpa.create(View);
        errdefer self.gpa.destroy(v);
        v.* = .{
            .id = req.view,
            .w = @max(req.w, 1),
            .h = @max(req.h, 1),
            .scale_x1000 = if (req.scale_x1000 == 0) 1000 else req.scale_x1000,
        };
        try self.views.append(self.gpa, v);
        errdefer _ = self.views.pop();

        var winfo = std.mem.zeroes(cef.cef_window_info_t);
        winfo.size = @sizeOf(cef.cef_window_info_t);
        winfo.windowless_rendering_enabled = 1;
        winfo.runtime_style = cef.CEF_RUNTIME_STYLE_ALLOY;

        var bsettings = std.mem.zeroes(cef.cef_browser_settings_t);
        bsettings.size = @sizeOf(cef.cef_browser_settings_t);
        bsettings.windowless_frame_rate = 30;

        var url = std.mem.zeroes(cef.cef_string_t);
        setStr("about:blank", &url);
        defer cef.cef_string_utf16_clear(&url);

        self.pending = v;
        defer self.pending = null;
        const browser = cef.cef_browser_host_create_browser_sync(
            &winfo,
            &client,
            &url,
            &bsettings,
            null,
            null,
        );
        if (browser == null) return error.BrowserCreateFailed;
        v.browser = browser;
        v.cef_id = browserInt(browser, "get_identifier");
        // A view without a frame buffer is invisible and unfixable, so
        // the whole view goes rather than leaving a stranded browser.
        self.allocBuffer(v) catch |e| {
            self.destroyView(v.id);
            return e;
        };
    }

    pub fn destroyView(self: *Host, id: u32) void {
        for (self.views.items, 0..) |v, i| {
            if (v.id != id) continue;
            _ = self.views.swapRemove(i);
            self.freeView(v);
            return;
        }
    }

    pub fn destroyAll(self: *Host) void {
        while (self.views.pop()) |v| self.freeView(v);
    }

    fn freeView(self: *Host, v: *View) void {
        if (browserHost(v)) |host| {
            if (host.close_browser) |cb| cb(host, 1);
            release(&host.base);
        }
        if (v.browser) |b| release(&b.base);
        if (v.map.len != 0) _ = c.munmap(v.map.ptr, v.map.len);
        if (v.url.len != 0) self.gpa.free(v.url);
        self.gpa.destroy(v);
    }

    /// (Re)allocate the view's shared frame buffer and announce it.
    ///
    /// The memfd is handed to the client through the outbox and closed
    /// by the sender; the write mapping made here survives that close.
    /// v1 stride is exactly w*4 — no padding, per the spec.
    fn allocBuffer(self: *Host, v: *View) !void {
        if (v.map.len != 0) {
            _ = c.munmap(v.map.ptr, v.map.len);
            v.map = &.{};
        }
        const size: usize = v.stride() * @as(usize, v.h);
        const fd = memfd_create("sketerm-web-view", MFD_CLOEXEC);
        if (fd < 0) return error.MemfdFailed;
        var keep_fd = false;
        defer if (!keep_fd) {
            _ = c.close(fd);
        };
        if (c.ftruncate(fd, @intCast(size)) != 0) return error.FtruncateFailed;
        const addr = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (addr == c.MAP_FAILED) return error.MmapFailed;
        const bytes: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(addr));
        v.map = bytes[0..size];
        @memset(v.map, 0);
        v.buf_id +%= 1;
        if (v.buf_id == 0) v.buf_id = 1;
        try self.out.post(proto.FrameBuffer{
            .view = v.id,
            .buf_id = v.buf_id,
            .w = v.w,
            .h = v.h,
            .stride = v.stride(),
        }, fd);
        keep_fd = true;
    }

    pub fn resizeView(self: *Host, req: proto.ViewResize) !void {
        const v = self.find(req.view) orelse return;
        const w = @max(req.w, 1);
        const h = @max(req.h, 1);
        v.scale_x1000 = if (req.scale_x1000 == 0) 1000 else req.scale_x1000;
        if (v.w == w and v.h == h) return;
        v.w = w;
        v.h = h;
        try self.allocBuffer(v);
        withHost(v, struct {
            fn f(host: *cef.cef_browser_host_t) void {
                if (host.was_resized) |wr| wr(host);
            }
        }.f);
    }

    pub fn showView(self: *Host, id: u32, show: bool) void {
        const v = self.find(id) orelse return;
        v.hidden = !show;
        withHost(v, if (show) struct {
            fn f(host: *cef.cef_browser_host_t) void {
                if (host.was_hidden) |wh| wh(host, 0);
                if (host.invalidate) |inv| inv(host, cef.PET_VIEW);
            }
        }.f else struct {
            fn f(host: *cef.cef_browser_host_t) void {
                if (host.was_hidden) |wh| wh(host, 1);
            }
        }.f);
    }

    pub fn navigate(self: *Host, req: proto.Navigate) void {
        const v = self.find(req.view) orelse return;
        const b = v.browser orelse return;
        const get_frame = b.get_main_frame orelse return;
        const frame: *cef.cef_frame_t = get_frame(b) orelse return;
        defer release(&frame.base);
        var url = std.mem.zeroes(cef.cef_string_t);
        setStr(req.url, &url);
        defer cef.cef_string_utf16_clear(&url);
        if (frame.load_url) |lu| lu(frame, &url);
    }

    pub fn navAction(self: *Host, req: proto.NavAction) void {
        const v = self.find(req.view) orelse return;
        const b = v.browser orelse return;
        switch (@as(proto.NavAct, @enumFromInt(req.action))) {
            .back => if (b.go_back) |f| f(b),
            .forward => if (b.go_forward) |f| f(b),
            .reload => if (b.reload) |f| f(b),
            .stop => if (b.stop_load) |f| f(b),
            .reload_no_cache => if (b.reload_ignore_cache) |f| f(b),
            _ => {},
        }
    }

    // -- input ---------------------------------------------------------

    pub fn pointer(self: *Host, req: proto.InputPointer) void {
        const v = self.find(req.view) orelse return;
        var ev = cef.cef_mouse_event_t{
            .x = req.x,
            .y = req.y,
            .modifiers = keymap.eventFlags(req.mods),
        };
        const button: cef.cef_mouse_button_type_t = switch (req.button) {
            1 => cef.MBT_MIDDLE,
            2 => cef.MBT_RIGHT,
            else => cef.MBT_LEFT,
        };
        const clicks: c_int = @max(1, @as(c_int, req.clicks));
        switch (@as(proto.PointerKind, @enumFromInt(req.kind))) {
            .move => withHostArgs(v, sendMove, .{ &ev, @as(c_int, 0) }),
            .leave => withHostArgs(v, sendMove, .{ &ev, @as(c_int, 1) }),
            .down => withHostArgs(v, sendClick, .{ &ev, button, @as(c_int, 0), clicks }),
            .up => withHostArgs(v, sendClick, .{ &ev, button, @as(c_int, 1), clicks }),
            _ => {},
        }
    }

    pub fn scroll(self: *Host, req: proto.InputScroll) void {
        const v = self.find(req.view) orelse return;
        var ev = cef.cef_mouse_event_t{
            .x = req.x,
            .y = req.y,
            .modifiers = keymap.eventFlags(req.mods),
        };
        // Protocol dy is positive DOWN; CEF's wheel delta is positive UP.
        withHostArgs(v, sendWheel, .{ &ev, req.dx, -req.dy });
    }

    pub fn key(self: *Host, req: proto.InputKey) void {
        const v = self.find(req.view) orelse return;
        const mapped = keymap.map(req.keyval);
        var ev = std.mem.zeroes(cef.cef_key_event_t);
        ev.size = @sizeOf(cef.cef_key_event_t);
        ev.modifiers = keymap.eventFlags(req.mods);
        if (mapped.keypad) ev.modifiers |= keymap.flag_is_key_pad;
        ev.windows_key_code = mapped.windows_key_code;
        ev.native_key_code = @bitCast(req.keycode);
        ev.character = mapped.character;
        ev.unmodified_character = mapped.character;

        if (@as(proto.KeyKind, @enumFromInt(req.kind)) == .up) {
            ev.type = cef.KEYEVENT_KEYUP;
            withHostArgs(v, sendKey, .{&ev});
            return;
        }
        ev.type = cef.KEYEVENT_RAWKEYDOWN;
        withHostArgs(v, sendKey, .{&ev});

        // Text delivery: the committed text wins when the client sent
        // it (dead keys, IME-less compose), otherwise the keysym's own
        // character. Ctrl/Alt chords produce no text.
        const chorded = req.mods & (proto.mod_ctrl | proto.mod_alt) != 0;
        if (req.text.len != 0) {
            var it = std.unicode.Utf8Iterator{ .bytes = req.text, .i = 0 };
            while (it.nextCodepoint()) |cp| charEvent(v, ev, cp);
        } else if (mapped.character != 0 and !chorded) {
            charEvent(v, ev, mapped.character);
        }
    }

    /// One CHAR event for `cp`; codepoints outside the BMP need a
    /// surrogate pair because CEF's character field is UTF-16.
    fn charEvent(v: *View, base_ev: cef.cef_key_event_t, cp: u21) void {
        var ev = base_ev;
        ev.type = cef.KEYEVENT_CHAR;
        if (cp <= 0xffff) {
            ev.character = @intCast(cp);
            ev.unmodified_character = ev.character;
            withHostArgs(v, sendKey, .{&ev});
            return;
        }
        const off = cp - 0x10000;
        const units = [2]u16{
            @intCast(0xd800 + (off >> 10)),
            @intCast(0xdc00 + (off & 0x3ff)),
        };
        for (units) |u| {
            ev.character = u;
            ev.unmodified_character = u;
            withHostArgs(v, sendKey, .{&ev});
        }
    }

    pub fn ime(self: *Host, req: proto.InputIme) void {
        const v = self.find(req.view) orelse return;
        var text = std.mem.zeroes(cef.cef_string_t);
        setStr(req.text, &text);
        defer cef.cef_string_utf16_clear(&text);
        switch (@as(proto.ImeKind, @enumFromInt(req.kind))) {
            .compose => {
                const pos: u32 = @bitCast(req.cursor);
                const sel = cef.cef_range_t{ .from = pos, .to = pos };
                withHostArgs(v, imeCompose, .{ &text, &sel });
            },
            .commit => withHostArgs(v, imeCommit, .{ &text, req.cursor }),
            .cancel => withHostArgs(v, imeCancel, .{}),
            _ => {},
        }
    }

    pub fn focus(self: *Host, req: proto.InputFocus) void {
        const v = self.find(req.view) orelse return;
        withHostArgs(v, setFocus, .{@as(c_int, if (req.focused != 0) 1 else 0)});
    }

    // -- outbound ------------------------------------------------------

    /// Post an event, dropping it if the outbox is out of memory: a
    /// missed event must never take the helper down.
    fn post(self: *Host, value: anytype) void {
        self.out.post(value, null) catch {};
    }

    fn setUrl(self: *Host, v: *View, url: []const u8) void {
        const dup = self.gpa.dupe(u8, url) catch return;
        if (v.url.len != 0) self.gpa.free(v.url);
        v.url = dup;
    }

    fn postNavState(self: *Host, v: *View) void {
        const b = v.browser;
        const can_back: u8 = if (b != null and browserInt(b, "can_go_back") != 0) 1 else 0;
        const can_fwd: u8 = if (b != null and browserInt(b, "can_go_forward") != 0) 1 else 0;
        const loading: u8 = if (b != null and browserInt(b, "is_loading") != 0) 1 else 0;
        self.post(proto.EvNavState{
            .view = v.id,
            .can_back = can_back,
            .can_fwd = can_fwd,
            .loading = loading,
            .url = v.url,
        });
    }
};

var g_host: ?*Host = null;

// ---------------------------------------------------------------------
// Small CEF call helpers
// ---------------------------------------------------------------------

/// Invoke a nullary int-returning `cef_browser_t` accessor by name,
/// tolerating both a null browser and a null vtable slot.
fn browserInt(b: ?*cef.cef_browser_t, comptime name: []const u8) c_int {
    const br = b orelse return 0;
    const f = @field(br, name) orelse return 0;
    return f(br);
}

fn release(base: *cef.cef_base_ref_counted_t) void {
    if (base.release) |r| _ = r(base);
}

fn setStr(utf8: []const u8, out: *cef.cef_string_t) void {
    _ = cef.cef_string_utf8_to_utf16(utf8.ptr, utf8.len, out);
}

/// Borrowed UTF-8 view of a CEF string; `free` releases it.
const Utf8 = struct {
    s: cef.cef_string_utf8_t,

    fn init(str: [*c]const cef.cef_string_t) Utf8 {
        var out = std.mem.zeroes(cef.cef_string_utf8_t);
        if (str != null and str.*.str != null) {
            _ = cef.cef_string_utf16_to_utf8(str.*.str, str.*.length, &out);
        }
        return .{ .s = out };
    }

    fn slice(self: *const Utf8) []const u8 {
        if (self.s.str == null) return "";
        return self.s.str[0..self.s.length];
    }

    fn free(self: *Utf8) void {
        cef.cef_string_utf8_clear(&self.s);
    }
};

/// The view's browser host, WITH a reference held: every caller must
/// release it (CEF's capi returns referenced pointers).
fn browserHost(v: *View) ?*cef.cef_browser_host_t {
    const b = v.browser orelse return null;
    const gh = b.get_host orelse return null;
    const host: ?*cef.cef_browser_host_t = gh(b);
    return host;
}

/// Run `f` against the view's browser host, releasing the reference.
fn withHost(v: *View, f: *const fn (*cef.cef_browser_host_t) void) void {
    const host = browserHost(v) orelse return;
    defer release(&host.base);
    f(host);
}

/// `withHost` for the arg-taking senders below (Zig has no closures).
fn withHostArgs(v: *View, comptime f: anytype, args: anytype) void {
    const host = browserHost(v) orelse return;
    defer release(&host.base);
    @call(.auto, f, .{host} ++ args);
}

fn sendMove(host: *cef.cef_browser_host_t, ev: *const cef.cef_mouse_event_t, leave: c_int) void {
    if (host.send_mouse_move_event) |f| f(host, ev, leave);
}

fn sendClick(
    host: *cef.cef_browser_host_t,
    ev: *const cef.cef_mouse_event_t,
    button: cef.cef_mouse_button_type_t,
    up: c_int,
    clicks: c_int,
) void {
    if (host.send_mouse_click_event) |f| f(host, ev, button, up, clicks);
}

fn sendWheel(host: *cef.cef_browser_host_t, ev: *const cef.cef_mouse_event_t, dx: c_int, dy: c_int) void {
    if (host.send_mouse_wheel_event) |f| f(host, ev, dx, dy);
}

fn sendKey(host: *cef.cef_browser_host_t, ev: *const cef.cef_key_event_t) void {
    if (host.send_key_event) |f| f(host, ev);
}

fn setFocus(host: *cef.cef_browser_host_t, on: c_int) void {
    if (host.set_focus) |f| f(host, on);
}

fn imeCompose(
    host: *cef.cef_browser_host_t,
    text: *const cef.cef_string_t,
    sel: *const cef.cef_range_t,
) void {
    if (host.ime_set_composition) |f| f(host, text, 0, null, null, sel);
}

fn imeCommit(host: *cef.cef_browser_host_t, text: *const cef.cef_string_t, cursor: c_int) void {
    if (host.ime_commit_text) |f| f(host, text, null, cursor);
}

fn imeCancel(host: *cef.cef_browser_host_t) void {
    if (host.ime_cancel_composition) |f| f(host);
}

// ---------------------------------------------------------------------
// Static handler set
// ---------------------------------------------------------------------
//
// One shared instance of each handler serves every browser; callbacks
// resolve their view through the browser's CEF id. These structs are
// statics that live as long as the process, which is the ONLY reason
// their no-op add_ref/release is correct: CEF can never own or free
// them, so a refcount would have nothing to protect.

fn baseAddRef(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) void {}
fn baseRelease(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
    return 0;
}
fn baseHasOne(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
    return 1;
}

fn staticBase(comptime T: type) cef.cef_base_ref_counted_t {
    return .{
        .size = @sizeOf(T),
        .add_ref = baseAddRef,
        .release = baseRelease,
        .has_one_ref = baseHasOne,
        .has_at_least_one_ref = baseHasOne,
    };
}

var app: cef.cef_app_t = undefined;
var client: cef.cef_client_t = undefined;
var render_handler: cef.cef_render_handler_t = undefined;
var display_handler: cef.cef_display_handler_t = undefined;
var life_span_handler: cef.cef_life_span_handler_t = undefined;
var load_handler: cef.cef_load_handler_t = undefined;
var request_handler: cef.cef_request_handler_t = undefined;
var bp_handler: cef.cef_browser_process_handler_t = undefined;

/// Milliseconds until CEF next wants `pump()`; -1 = nothing scheduled.
var pump_delay_ms: i64 = -1;

fn onScheduleMessagePumpWork(_: [*c]cef.cef_browser_process_handler_t, delay: i64) callconv(.c) void {
    pump_delay_ms = delay;
}

fn getBrowserProcessHandler(_: [*c]cef.cef_app_t) callconv(.c) [*c]cef.cef_browser_process_handler_t {
    return &bp_handler;
}

/// Poll timeout CEF asked for, clamped to `cap` ms.
pub fn pumpTimeoutMs(cap: i64) i64 {
    if (pump_delay_ms < 0) return cap;
    return @min(@max(pump_delay_ms, 0), cap);
}

fn getRenderHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_render_handler_t {
    return &render_handler;
}
fn getDisplayHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_display_handler_t {
    return &display_handler;
}
fn getLifeSpanHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_life_span_handler_t {
    return &life_span_handler;
}
fn getLoadHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_load_handler_t {
    return &load_handler;
}
fn getRequestHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_request_handler_t {
    return &request_handler;
}

fn installHandlers() void {
    render_handler = std.mem.zeroes(cef.cef_render_handler_t);
    render_handler.base = staticBase(cef.cef_render_handler_t);
    render_handler.get_view_rect = onGetViewRect;
    render_handler.get_screen_info = onGetScreenInfo;
    render_handler.on_paint = onPaint;

    display_handler = std.mem.zeroes(cef.cef_display_handler_t);
    display_handler.base = staticBase(cef.cef_display_handler_t);
    display_handler.on_address_change = onAddressChange;
    display_handler.on_title_change = onTitleChange;
    display_handler.on_favicon_urlchange = onFaviconChange;
    display_handler.on_console_message = onConsoleMessage;
    display_handler.on_cursor_change = onCursorChange;

    life_span_handler = std.mem.zeroes(cef.cef_life_span_handler_t);
    life_span_handler.base = staticBase(cef.cef_life_span_handler_t);
    life_span_handler.on_before_popup = onBeforePopup;
    life_span_handler.on_after_created = onAfterCreated;

    load_handler = std.mem.zeroes(cef.cef_load_handler_t);
    load_handler.base = staticBase(cef.cef_load_handler_t);
    load_handler.on_loading_state_change = onLoadingStateChange;
    load_handler.on_load_start = onLoadStart;
    load_handler.on_load_end = onLoadEnd;
    load_handler.on_load_error = onLoadError;

    request_handler = std.mem.zeroes(cef.cef_request_handler_t);
    request_handler.base = staticBase(cef.cef_request_handler_t);
    request_handler.on_render_process_terminated = onRenderProcessTerminated;

    client = std.mem.zeroes(cef.cef_client_t);
    client.base = staticBase(cef.cef_client_t);
    client.get_render_handler = getRenderHandler;
    client.get_display_handler = getDisplayHandler;
    client.get_life_span_handler = getLifeSpanHandler;
    client.get_load_handler = getLoadHandler;
    client.get_request_handler = getRequestHandler;
}

/// Resolve the view a callback's browser belongs to. During
/// create_browser_sync the browser is not registered yet, so the
/// in-flight view answers instead.
fn viewOf(browser: [*c]cef.cef_browser_t) ?*View {
    const host = g_host orelse return null;
    if (browser != null) {
        if (browser.*.get_identifier) |gi| {
            if (host.findCef(gi(browser))) |v| return v;
        }
    }
    return host.pending;
}

fn onGetViewRect(
    _: [*c]cef.cef_render_handler_t,
    browser: [*c]cef.cef_browser_t,
    rect: [*c]cef.cef_rect_t,
) callconv(.c) void {
    const v = viewOf(browser) orelse {
        rect.* = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
        return;
    };
    rect.* = .{ .x = 0, .y = 0, .width = v.w, .height = v.h };
}

fn onGetScreenInfo(
    _: [*c]cef.cef_render_handler_t,
    browser: [*c]cef.cef_browser_t,
    info: [*c]cef.cef_screen_info_t,
) callconv(.c) c_int {
    const v = viewOf(browser) orelse return 0;
    info.* = std.mem.zeroes(cef.cef_screen_info_t);
    info.*.size = @sizeOf(cef.cef_screen_info_t);
    info.*.device_scale_factor = @as(f32, @floatFromInt(v.scale_x1000)) / 1000.0;
    info.*.depth = 32;
    info.*.depth_per_component = 8;
    info.*.rect = .{ .x = 0, .y = 0, .width = v.w, .height = v.h };
    info.*.available_rect = info.*.rect;
    return 1;
}

fn onPaint(
    _: [*c]cef.cef_render_handler_t,
    browser: [*c]cef.cef_browser_t,
    ptype: cef.cef_paint_element_type_t,
    count: usize,
    rects: [*c]const cef.cef_rect_t,
    buffer: ?*const anyopaque,
    width: c_int,
    height: c_int,
) callconv(.c) void {
    if (ptype != cef.PET_VIEW) return;
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    if (v.map.len == 0) return;
    // A paint for the pre-resize geometry: the resize triggers its own
    // full repaint, so dropping this one loses nothing.
    if (width != @as(c_int, v.w) or height != @as(c_int, v.h)) return;
    const src: [*]const u8 = @ptrCast(buffer orelse return);
    const stride: usize = v.stride();

    var list: [max_rects]proto.Rect = undefined;
    var n: usize = 0;
    const collapse = count == 0 or count > max_rects;
    const src_rects = if (rects == null) &[_]cef.cef_rect_t{} else rects[0..count];
    if (collapse) {
        copyRect(v, src, stride, 0, 0, v.w, v.h);
        list[0] = .{ .x = 0, .y = 0, .w = v.w, .h = v.h };
        n = 1;
    } else {
        for (src_rects) |r| {
            const x: u16 = @intCast(std.math.clamp(r.x, 0, @as(c_int, v.w)));
            const y: u16 = @intCast(std.math.clamp(r.y, 0, @as(c_int, v.h)));
            const w: u16 = @intCast(std.math.clamp(r.width, 0, @as(c_int, v.w) - @as(c_int, x)));
            const h: u16 = @intCast(std.math.clamp(r.height, 0, @as(c_int, v.h) - @as(c_int, y)));
            if (w == 0 or h == 0) continue;
            copyRect(v, src, stride, x, y, w, h);
            list[n] = .{ .x = x, .y = y, .w = w, .h = h };
            n += 1;
        }
    }
    if (n == 0) return;
    v.gen +%= 1;
    host.post(proto.FrameDamage{
        .view = v.id,
        .buf_id = v.buf_id,
        .gen = v.gen,
        .rects = list[0..n],
    });
}

/// Copy one BGRA rect out of CEF's full-view buffer into the memfd.
fn copyRect(v: *View, src: [*]const u8, stride: usize, x: u16, y: u16, w: u16, h: u16) void {
    var row: usize = y;
    while (row < @as(usize, y) + h) : (row += 1) {
        const off = row * stride + @as(usize, x) * 4;
        const len = @as(usize, w) * 4;
        @memcpy(v.map[off..][0..len], src[off..][0..len]);
    }
}

fn onAddressChange(
    _: [*c]cef.cef_display_handler_t,
    browser: [*c]cef.cef_browser_t,
    _: [*c]cef.cef_frame_t,
    url: [*c]const cef.cef_string_t,
) callconv(.c) void {
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    var s = Utf8.init(url);
    defer s.free();
    host.setUrl(v, s.slice());
    host.postNavState(v);
}

fn onTitleChange(
    _: [*c]cef.cef_display_handler_t,
    browser: [*c]cef.cef_browser_t,
    title: [*c]const cef.cef_string_t,
) callconv(.c) void {
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    var s = Utf8.init(title);
    defer s.free();
    host.post(proto.EvTitle{ .view = v.id, .title = s.slice() });
}

fn onFaviconChange(
    _: [*c]cef.cef_display_handler_t,
    browser: [*c]cef.cef_browser_t,
    icon_urls: cef.cef_string_list_t,
) callconv(.c) void {
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    if (cef.cef_string_list_size(icon_urls) == 0) return;
    var first = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&first);
    if (cef.cef_string_list_value(icon_urls, 0, &first) != 1) return;
    var s = Utf8.init(&first);
    defer s.free();
    host.post(proto.EvFavicon{ .view = v.id, .url = s.slice() });
}

fn onConsoleMessage(
    _: [*c]cef.cef_display_handler_t,
    browser: [*c]cef.cef_browser_t,
    level: cef.cef_log_severity_t,
    message: [*c]const cef.cef_string_t,
    _: [*c]const cef.cef_string_t,
    _: c_int,
) callconv(.c) c_int {
    const host = g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    var s = Utf8.init(message);
    defer s.free();
    host.post(proto.EvConsole{
        .view = v.id,
        .level = @intCast(@min(level, 5)),
        .msg = s.slice(),
    });
    return 0;
}

fn onCursorChange(
    _: [*c]cef.cef_display_handler_t,
    browser: [*c]cef.cef_browser_t,
    _: cef.cef_cursor_handle_t,
    ctype: cef.cef_cursor_type_t,
    _: [*c]const cef.cef_cursor_info_t,
) callconv(.c) c_int {
    const host = g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    const mapped: proto.Cursor = switch (ctype) {
        cef.CT_HAND => .pointer,
        cef.CT_IBEAM => .text,
        cef.CT_WAIT => .wait,
        cef.CT_CROSS => .crosshair,
        cef.CT_NOTALLOWED => .not_allowed,
        cef.CT_GRAB => .grab,
        cef.CT_GRABBING => .grabbing,
        cef.CT_EASTWESTRESIZE, cef.CT_COLUMNRESIZE => .ew_resize,
        cef.CT_NORTHSOUTHRESIZE, cef.CT_ROWRESIZE => .ns_resize,
        else => .default,
    };
    host.post(proto.EvCursor{ .view = v.id, .cursor = @intFromEnum(mapped) });
    return 0;
}

/// Popups are NEVER opened by the helper: it cancels them and reports
/// the request, leaving the tab/window decision to the client.
fn onBeforePopup(
    _: [*c]cef.cef_life_span_handler_t,
    browser: [*c]cef.cef_browser_t,
    _: [*c]cef.cef_frame_t,
    _: c_int,
    target_url: [*c]const cef.cef_string_t,
    _: [*c]const cef.cef_string_t,
    disposition: cef.cef_window_open_disposition_t,
    _: c_int,
    _: [*c]const cef.cef_popup_features_t,
    _: [*c]cef.cef_window_info_t,
    _: [*c][*c]cef.cef_client_t,
    _: [*c]cef.cef_browser_settings_t,
    _: [*c][*c]cef.cef_dictionary_value_t,
    _: [*c]c_int,
) callconv(.c) c_int {
    const host = g_host orelse return 1;
    const v = viewOf(browser) orelse return 1;
    var s = Utf8.init(target_url);
    defer s.free();
    const d: proto.Disposition = switch (disposition) {
        cef.CEF_WOD_NEW_WINDOW => .new_window,
        cef.CEF_WOD_NEW_POPUP, cef.CEF_WOD_NEW_PICTURE_IN_PICTURE => .popup,
        else => .new_tab,
    };
    host.post(proto.EvPopupRequest{
        .view = v.id,
        .url = s.slice(),
        .disposition = @intFromEnum(d),
    });
    return 1;
}

fn onAfterCreated(
    _: [*c]cef.cef_life_span_handler_t,
    browser: [*c]cef.cef_browser_t,
) callconv(.c) void {
    const host = g_host orelse return;
    const v = host.pending orelse return;
    if (v.cef_id != 0 or browser == null) return;
    if (browser.*.get_identifier) |gi| v.cef_id = gi(browser);
}

fn onLoadingStateChange(
    _: [*c]cef.cef_load_handler_t,
    browser: [*c]cef.cef_browser_t,
    is_loading: c_int,
    can_back: c_int,
    can_fwd: c_int,
) callconv(.c) void {
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    host.post(proto.EvNavState{
        .view = v.id,
        .can_back = if (can_back != 0) 1 else 0,
        .can_fwd = if (can_fwd != 0) 1 else 0,
        .loading = if (is_loading != 0) 1 else 0,
        .url = v.url,
    });
}

fn onLoadStart(
    _: [*c]cef.cef_load_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    _: cef.cef_transition_type_t,
) callconv(.c) void {
    if (!isMainFrame(frame)) return;
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    host.post(proto.EvLoad{
        .view = v.id,
        .state = @intFromEnum(proto.LoadState.started),
        .url = v.url,
    });
}

fn onLoadEnd(
    _: [*c]cef.cef_load_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    _: c_int,
) callconv(.c) void {
    if (!isMainFrame(frame)) return;
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    host.post(proto.EvLoad{
        .view = v.id,
        .state = @intFromEnum(proto.LoadState.finished),
        .url = v.url,
    });
}

fn onLoadError(
    _: [*c]cef.cef_load_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    code: cef.cef_errorcode_t,
    text: [*c]const cef.cef_string_t,
    failed_url: [*c]const cef.cef_string_t,
) callconv(.c) void {
    if (!isMainFrame(frame)) return;
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    var url = Utf8.init(failed_url);
    defer url.free();
    var msg = Utf8.init(text);
    defer msg.free();
    host.post(proto.EvLoadError{
        .view = v.id,
        .code = @intCast(code),
        .url = url.slice(),
        .msg = msg.slice(),
    });
    host.post(proto.EvLoad{
        .view = v.id,
        .state = @intFromEnum(proto.LoadState.failed),
        .url = url.slice(),
    });
}

fn onRenderProcessTerminated(
    _: [*c]cef.cef_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    _: cef.cef_termination_status_t,
    _: c_int,
    _: [*c]const cef.cef_string_t,
) callconv(.c) void {
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    host.post(proto.EvCrashed{ .view = v.id });
}

fn isMainFrame(frame: [*c]cef.cef_frame_t) bool {
    if (frame == null) return false;
    const f = frame.*.is_main orelse return false;
    return f(frame) != 0;
}

// ---------------------------------------------------------------------
// Process bootstrap (the only CEF entry points main.zig needs)
// ---------------------------------------------------------------------

/// Configure the libcef API version. MUST be the first libcef call of
/// any process — without it `cef_execute_process` spins forever.
pub fn apiHash() bool {
    return cef.cef_api_hash(cef.CEF_API_VERSION_LAST, 0) != null;
}

/// CEF subprocess passthrough: returns the exit code for a helper
/// process, or null in the browser process.
pub fn executeProcess(argc: c_int, argv: [*c][*c]u8) ?u8 {
    bp_handler = std.mem.zeroes(cef.cef_browser_process_handler_t);
    bp_handler.base = staticBase(cef.cef_browser_process_handler_t);
    bp_handler.on_schedule_message_pump_work = onScheduleMessagePumpWork;
    app = std.mem.zeroes(cef.cef_app_t);
    app.base = staticBase(cef.cef_app_t);
    app.get_browser_process_handler = getBrowserProcessHandler;
    const args = cef.cef_main_args_t{ .argc = argc, .argv = argv };
    const code = cef.cef_execute_process(&args, &app, null);
    if (code < 0) return null;
    return @intCast(@as(u32, @bitCast(code)) & 0xff);
}

/// Bring CEF up in windowless mode with a private cache directory.
pub fn initialize(argc: c_int, argv: [*c][*c]u8, cache_dir: []const u8, log_file: []const u8) bool {
    const args = cef.cef_main_args_t{ .argc = argc, .argv = argv };
    var settings = std.mem.zeroes(cef.cef_settings_t);
    settings.size = @sizeOf(cef.cef_settings_t);
    settings.no_sandbox = 1;
    settings.windowless_rendering_enabled = 1;
    settings.log_severity = cef.LOGSEVERITY_WARNING;
    setStr(cache_dir, &settings.root_cache_path);
    setStr(log_file, &settings.log_file);
    defer cef.cef_string_utf16_clear(&settings.root_cache_path);
    defer cef.cef_string_utf16_clear(&settings.log_file);
    return cef.cef_initialize(&args, &settings, &app, null) == 1;
}

/// One iteration of CEF's message loop. Every handler above runs
/// inside this call, on this thread.
pub fn pump() void {
    pump_delay_ms = -1;
    cef.cef_do_message_loop_work();
}

pub fn shutdown() void {
    cef.cef_shutdown();
}

/// Engine identity for the handshake.
pub fn engineName() []const u8 {
    return "cef";
}

pub fn engineVersion() []const u8 {
    return std.mem.span(@as([*:0]const u8, cef.CEF_VERSION));
}
