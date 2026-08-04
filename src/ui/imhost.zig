//! Shared GtkIMContext plumbing for every keyboard face (terminal
//! pane, editor canvas, forwarded-app host window).
//!
//! Exists because three faces had three copies of the same delicate
//! sequence — create context, set_client_widget, connect commit +
//! preedit-*, hand it to the GtkEventControllerKey, drive focus_in/out
//! from a focus controller, debounce set_cursor_location, and sever the
//! whole thing while the client widget is still alive — and they had
//! drifted apart in exactly the ways that break input.
//!
//! GUI-only: register in `src/tests.zig`, never `tests_core.zig`.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");

/// Which GtkIMContext implementation a face uses.
///
/// There is NO strategy that gives both compose/dead keys and real
/// input methods. Pick per face:
///
/// `.simple` — `GtkIMContextSimple`. Runs GTK's in-process Compose
/// tables (the same data xkbcommon uses), so dead keys (`^`+`e` -> `ê`,
/// AltGr+`=` -> `~`, `` ` ``+`a` -> `à`) and Compose sequences ALWAYS
/// work, on every display and every compositor. It knows nothing about
/// ibus/fcitx/CJK input methods: no candidate window, no per-language
/// engines.
///
/// `.multi` — `GtkIMMulticontext`. Delegates to whatever module GTK
/// resolves for the display, which is how real IMEs (CJK, Vietnamese,
/// handwriting) reach the app. The catch: on any Wayland display that
/// advertises `zwp_text_input_manager_v3`, GTK resolves the multicontext
/// to its `wayland` module (gtkimmodule.c keys on a display-level
/// registry query). That module derives from GtkIMContext, NOT from
/// GtkIMContextSimple; its filter_keypress only commits
/// `gdk_keyval_to_unicode(keyval)`, which is 0 for every dead keysym.
/// It carries no compose engine and no dead-key state, so dead keys
/// are dropped and the next letter commits bare — UNLESS the
/// compositor's own IME composes for us (ibus under GNOME does; a bare
/// KWin/sway session does not, and sketerm's own wlhost only relays
/// what its host GUI composed).
///
/// NOTE for archaeologists: an earlier comment in input.zig blamed
/// GtkGraphicsOffload for the dead-key loss. That was measured wrong —
/// a 2x2 probe (Simple/Multi x offload/no-offload) shows offload has
/// zero effect on IM behaviour. The false reason is what led the editor
/// face to adopt a multicontext "safely". It was not safe.
pub const Strategy = enum { simple, multi };

/// The user-facing `input_method` config value.
pub const Preference = enum { auto, simple, multi };

/// Faces differ in what `auto` should mean — see `strategyFor`.
pub const Face = enum {
    /// Terminal pane. Dead keys here are load-bearing for every
    /// AZERTY/QWERTZ user typing into a shell.
    terminal,
    /// Editor document canvas.
    editor,
    /// Host-side IM for a forwarded Wayland app.
    app_host,
};

/// The two places GTK users declare an input method, read once so the
/// `auto` heuristic below is a pure function over them.
pub const ImEnv = struct {
    /// `$GTK_IM_MODULE` ("" when unset).
    env: []const u8 = "",
    /// The `gtk-im-module` GtkSettings property ("" when unset).
    setting: []const u8 = "",
};

/// Does either value name a REAL input method the user asked for?
///
/// "none" and "gtk-im-context-simple" are the two ways of saying "no
/// IME"; "simple" is the historic short spelling of the latter.
pub fn userConfiguredIme(e: ImEnv) bool {
    return isImeName(e.env) or isImeName(e.setting);
}

fn isImeName(v: []const u8) bool {
    const t = std.mem.trim(u8, v, " \t");
    if (t.len == 0) return false;
    if (std.mem.eql(u8, t, "none")) return false;
    if (std.mem.eql(u8, t, "simple")) return false;
    if (std.mem.eql(u8, t, "gtk-im-context-simple")) return false;
    return true;
}

/// Resolve the strategy for one face.
///
/// An explicit `input_method = simple|multi` wins everywhere. Under
/// `auto` the faces deliberately differ:
///
/// - `.terminal` is ALWAYS `.simple`. Dead keys in a shell are the
///   behaviour sketerm shipped and users rely on; `auto` must not be
///   able to take it away. An IME user who wants candidate windows in
///   the terminal has to say `input_method = multi` and accept that
///   dead keys then depend on their compositor.
/// - `.editor` and `.app_host` follow the heuristic: `.multi` when the
///   user has visibly configured an input method, `.simple` otherwise.
///
/// The heuristic is honest but not perfect: GNOME/ibus sessions
/// frequently set NEITHER `$GTK_IM_MODULE` nor `gtk-im-module` (the
/// wayland module is picked by display probing), so an IME user there
/// can land on `.simple` and must set `input_method = multi` by hand.
/// The failure mode is chosen on purpose — being wrong toward
/// `.simple` costs a CJK user one config line, being wrong toward
/// `.multi` silently eats every dead key for a European user.
pub fn strategyFor(face: Face, pref: Preference, e: ImEnv) Strategy {
    switch (pref) {
        .simple => return .simple,
        .multi => return .multi,
        .auto => {},
    }
    if (face == .terminal) return .simple;
    return if (userConfiguredIme(e)) .multi else .simple;
}

/// Live `input_method` value, pushed from Config (app-level key).
/// Read at face-construction time, so a change applies to panes and
/// editor tabs opened after it.
var preference: Preference = .auto;

pub fn setPreference(p: Preference) void {
    preference = p;
}

pub fn getPreference() Preference {
    return preference;
}

/// Read the session's IM declarations. Impure half of the heuristic,
/// kept apart from `strategyFor` so the logic stays unit-testable.
pub fn readEnv() ImEnv {
    var out: ImEnv = .{};
    if (c.getenv("GTK_IM_MODULE")) |v| out.env = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
    if (c.gtk_settings_get_default()) |s| {
        var val: [*c]u8 = null;
        c.g_object_get(@as(?*anyopaque, @ptrCast(s)), "gtk-im-module", &val, @as(?*anyopaque, null));
        if (val != null) {
            // The string is freed with the settings read; copy into a
            // static buffer so the returned slice outlives it.
            const span = std.mem.span(@as([*:0]const u8, @ptrCast(val)));
            const n = @min(span.len, setting_buf.len);
            @memcpy(setting_buf[0..n], span[0..n]);
            out.setting = setting_buf[0..n];
            c.g_free(val);
        }
    }
    return out;
}

var setting_buf: [64]u8 = undefined;

/// Resolve the strategy for `face` from the live config + session.
pub fn resolve(face: Face) Strategy {
    return strategyFor(face, preference, readEnv());
}

/// Face callbacks. All slices are BORROWED for the duration of the
/// call — copy what you keep.
pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    /// The IM produced final text.
    on_commit: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    /// Composition in progress. `cursor_chars` is a CHARACTER offset
    /// into `text` (GTK's own unit); convert to bytes yourself if the
    /// renderer wants bytes.
    on_preedit: ?*const fn (ctx: ?*anyopaque, text: []const u8, cursor_chars: usize) void = null,
    /// Composition ended or was cancelled — drop any preedit state.
    on_preedit_end: ?*const fn (ctx: ?*anyopaque) void = null,
};

/// Max key controllers one IM can be routed through. The forwarded-app
/// host has two per window (floating + embedded); everyone else has 1.
const MAX_CTRLS = 4;

pub const ImHost = struct {
    allocator: std.mem.Allocator,
    im: ?*c.GtkIMContext = null,
    /// Which face owns this host. Static string; reported by the
    /// `im-probe` debug hook so a measurement names what it measured
    /// (a pane hosting an editor has BOTH a terminal and an editor
    /// host alive, and they can resolve to different strategies).
    face: Face = .terminal,
    strategy: Strategy = .simple,
    cbs: Callbacks = .{},
    /// The widget the IM context reports as its client. Kept so the
    /// probe hook can find the ImHost of the focused face.
    client_widget: ?*c.GtkWidget = null,
    ctrls: [MAX_CTRLS]?*c.GtkEventControllerKey = @splat(null),
    n_ctrls: usize = 0,
    /// Routed to the controllers right now (see `setEnabled`).
    routed: bool = true,
    /// Last rectangle handed to gtk_im_context_set_cursor_location.
    last_rect: ?c.GdkRectangle = null,
    /// Debug probe capture (see `probeFeed`).
    probe_buf: [256]u8 = undefined,
    probe_len: usize = 0,
    probe_active: bool = false,

    /// Create the IM context for `widget`, wire the callbacks, and
    /// route `ctrl`'s key events through it.
    ///
    /// `ctrl` may be null (add controllers later with `addController`).
    /// The caller still owns focus: wire `focusIn`/`focusOut` from its
    /// own GtkEventControllerFocus — GtkEventControllerKey does NOT
    /// drive them, and without focus_in Wayland text-input-v3 never
    /// enables, so no IME ever composes.
    pub fn attach(
        allocator: std.mem.Allocator,
        widget: ?*c.GtkWidget,
        ctrl: ?*c.GtkEventControllerKey,
        face: Face,
        cbs: Callbacks,
    ) !*ImHost {
        const self = try allocator.create(ImHost);
        errdefer allocator.destroy(self);
        const strategy = resolve(face);
        self.* = .{
            .allocator = allocator,
            .face = face,
            .strategy = strategy,
            .cbs = cbs,
            .client_widget = widget,
        };

        const im: *c.GtkIMContext = @ptrCast(switch (strategy) {
            .simple => c.gtk_im_context_simple_new(),
            .multi => c.gtk_im_multicontext_new(),
        });
        self.im = im;
        if (widget) |w| c.gtk_im_context_set_client_widget(im, w);

        // All three preedit signals, deliberately: connecting only
        // `preedit-changed` (as the terminal used to) leaves stale
        // composition text on screen when an IME cancels.
        _ = c.g_signal_connect_data(im, "commit", @ptrCast(&onCommit), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(im, "preedit-start", @ptrCast(&onPreeditStart), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(im, "preedit-changed", @ptrCast(&onPreeditChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(im, "preedit-end", @ptrCast(&onPreeditEnd), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        if (ctrl) |k| self.addController(k);
        register(self);
        return self;
    }

    /// Route another key controller's events through this IM.
    ///
    /// Always via `gtk_event_controller_key_set_im_context`, never a
    /// manual `filter_key` from a key-pressed handler: GTK4 already
    /// feeds the controller's events to the IM before emitting
    /// key-pressed, so re-submitting double-processes every key.
    pub fn addController(self: *ImHost, ctrl: *c.GtkEventControllerKey) void {
        for (self.ctrls[0..self.n_ctrls]) |maybe| {
            if (maybe == ctrl) return;
        }
        if (self.n_ctrls >= MAX_CTRLS) return;
        self.ctrls[self.n_ctrls] = ctrl;
        self.n_ctrls += 1;
        c.gtk_event_controller_key_set_im_context(ctrl, if (self.routed) self.im else null);
    }

    /// Route key events through the IM (`true`) or bypass it
    /// (`false`), keeping the context and its state alive. The
    /// forwarded-app host uses this to follow the app's
    /// zwp_text_input_v3 enable/disable.
    pub fn setEnabled(self: *ImHost, on: bool) void {
        if (self.routed == on) return;
        self.routed = on;
        for (self.ctrls[0..self.n_ctrls]) |maybe| {
            if (maybe) |k| c.gtk_event_controller_key_set_im_context(k, if (on) self.im else null);
        }
    }

    pub fn focusIn(self: *ImHost) void {
        const im = self.im orelse return;
        c.gtk_im_context_focus_in(im);
    }

    pub fn focusOut(self: *ImHost) void {
        const im = self.im orelse return;
        c.gtk_im_context_focus_out(im);
    }

    /// Tell the IME where to put its candidate window, in widget
    /// coordinates.
    ///
    /// Debounced against the last rectangle sent: this call can hop
    /// into ibus/fcitx over D-Bus, which is far too expensive to
    /// repeat on every dirty redraw or caret move.
    pub fn setCursorLocation(self: *ImHost, rect: c.GdkRectangle) void {
        const im = self.im orelse return;
        if (self.last_rect) |old| {
            if (old.x == rect.x and old.y == rect.y and
                old.width == rect.width and old.height == rect.height) return;
        }
        self.last_rect = rect;
        var r = rect;
        c.gtk_im_context_set_cursor_location(im, &r);
    }

    /// Sever the IM context from its client widget and drop our ref.
    /// Idempotent.
    ///
    /// MUST run while the client widget is still a live GObject —
    /// from the face's prepare-destroy / the GL area's ::destroy, and
    /// never as late as `deinit`. A multicontext's
    /// `set_client_widget(NULL)` reaches into the widget's GtkSettings,
    /// which criticals (or worse) against a finalized widget. The IM
    /// context is not owned by the widget tree, so it can also still
    /// emit `commit`/`preedit-changed` (fcitx5/ibus route
    /// asynchronously through D-Bus) after the widget dies — which is
    /// why the signal handlers go first.
    pub fn detach(self: *ImHost) void {
        const im = self.im orelse return;
        self.im = null;
        for (self.ctrls[0..self.n_ctrls]) |maybe| {
            if (maybe) |k| c.gtk_event_controller_key_set_im_context(k, null);
        }
        self.n_ctrls = 0;
        const im_obj: ?*anyopaque = @ptrCast(im);
        // Disconnect every handler carrying THIS ImHost as user_data.
        // (g_signal_handlers_disconnect_by_data is a macro glib's
        // translate-c pass loses, so spell out the call.)
        _ = c.g_signal_handlers_disconnect_matched(
            im_obj,
            c.G_SIGNAL_MATCH_DATA,
            0,
            0,
            null,
            null,
            @ptrCast(self),
        );
        c.gtk_im_context_set_client_widget(im, null);
        c.g_object_unref(im_obj);
        self.client_widget = null;
    }

    /// Detach (if the owner has not already) and free. The owning face
    /// must have severed callbacks first — an ImHost holds a raw ctx
    /// pointer into its face, exactly the deferred-callback holder the
    /// clearSinks discipline exists for.
    pub fn deinit(self: *ImHost) void {
        self.detach();
        unregister(self);
        self.allocator.destroy(self);
    }

    // ---- debug probe -------------------------------------------------

    /// Feed one hardware keycode (GDK code = evdev + 8) through the IM
    /// exactly the way GtkEventControllerKey does, capturing whatever
    /// it commits. Debug hook behind the IPC `im-probe` command — this
    /// is what makes "does this face compose dead keys?" a repeatable
    /// check instead of a human at a keyboard.
    /// @return false when the IM did not consume the press.
    pub fn probeFeed(self: *ImHost, hw: u32) bool {
        const im = self.im orelse return false;
        const widget = self.client_widget orelse return false;
        const native = c.gtk_widget_get_native(widget) orelse return false;
        const surface = c.gtk_native_get_surface(native) orelse return false;
        const display = c.gtk_widget_get_display(widget) orelse return false;
        const seat = c.gdk_display_get_default_seat(display) orelse return false;
        const dev = c.gdk_seat_get_keyboard(seat) orelse return false;
        if (!self.probe_active) {
            self.probe_active = true;
            // A headless display session never activates the toplevel,
            // so the face's focus controller may not have fired —
            // without focus_in the simple IM keeps no dead-key state.
            c.gtk_im_context_focus_in(im);
        }
        const t: u32 = @truncate(@as(u64, @bitCast(c.g_get_monotonic_time())) / 1000);
        const consumed = c.gtk_im_context_filter_key(im, 1, surface, dev, t, hw, 0, 0) != 0;
        _ = c.gtk_im_context_filter_key(im, 0, surface, dev, t, hw, 0, 0);
        return consumed;
    }

    pub fn probeReset(self: *ImHost) void {
        self.probe_len = 0;
        self.probe_active = false;
    }

    pub fn probeText(self: *ImHost) []const u8 {
        return self.probe_buf[0..self.probe_len];
    }

    fn probeRecord(self: *ImHost, text: []const u8) void {
        if (!self.probe_active) return;
        const room = self.probe_buf.len - self.probe_len;
        const n = @min(room, text.len);
        @memcpy(self.probe_buf[self.probe_len..][0..n], text[0..n]);
        self.probe_len += n;
    }

    // ---- GTK signal handlers -----------------------------------------

    fn onCommit(_: *c.GtkIMContext, text: [*:0]const u8, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(ImHost, user);
        const slice = std.mem.span(text);
        self.probeRecord(slice);
        if (self.cbs.on_commit) |f| f(self.cbs.ctx, slice);
    }

    fn onPreeditStart(_: *c.GtkIMContext, user: ?*anyopaque) callconv(.c) void {
        emitPreedit(cast.userData(ImHost, user));
    }

    fn onPreeditChanged(_: *c.GtkIMContext, user: ?*anyopaque) callconv(.c) void {
        emitPreedit(cast.userData(ImHost, user));
    }

    fn onPreeditEnd(_: *c.GtkIMContext, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(ImHost, user);
        if (self.cbs.on_preedit_end) |f| f(self.cbs.ctx);
    }

    /// The one place that does the get_preedit_string / g_free /
    /// pango_attr_list_unref dance. Both old call sites open-coded it;
    /// forgetting the attr-list unref leaks a PangoAttrList per
    /// keystroke of composition.
    fn emitPreedit(self: *ImHost) void {
        const im = self.im orelse return;
        var str: [*c]u8 = null;
        var attrs: ?*c.PangoAttrList = null;
        var cur: c_int = 0;
        c.gtk_im_context_get_preedit_string(im, &str, @ptrCast(&attrs), &cur);
        defer {
            if (str != null) c.g_free(str);
            if (attrs) |a| c.pango_attr_list_unref(a);
        }
        const slice: []const u8 = if (str != null)
            std.mem.span(@as([*:0]const u8, @ptrCast(str)))
        else
            "";
        const cursor: usize = if (cur < 0) 0 else @intCast(cur);
        if (self.cbs.on_preedit) |f| f(self.cbs.ctx, slice, cursor);
    }
};

// ---- live-host registry (debug probe only) ---------------------------

var hosts: [64]?*ImHost = @splat(null);

fn register(self: *ImHost) void {
    for (&hosts) |*slot| {
        if (slot.* == null) {
            slot.* = self;
            return;
        }
    }
}

fn unregister(self: *ImHost) void {
    for (&hosts) |*slot| {
        if (slot.* == self) slot.* = null;
    }
}

/// The ImHost whose client widget currently holds keyboard focus in
/// `win` (or in any window, when `win` is null). Used by the IPC
/// `im-probe` command to reach "whatever face the user is typing into".
///
/// `gtk_widget_is_focus`, not `has_focus`: the latter also demands an
/// ACTIVE toplevel, and a headless/unviewed display session never
/// activates one — the face is still the window's focus widget and
/// still the one a keystroke would reach.
pub fn focusedHost(win: ?*c.GtkWindow) ?*ImHost {
    for (hosts) |slot| {
        const h = slot orelse continue;
        const w = h.client_widget orelse continue;
        if (c.gtk_widget_is_focus(w) == 0 and c.gtk_widget_has_focus(w) == 0) continue;
        if (win) |target| {
            const root = c.gtk_widget_get_root(w) orelse continue;
            if (@intFromPtr(root) != @intFromPtr(target)) continue;
        }
        return h;
    }
    return null;
}

// ---- tests ------------------------------------------------------------

test "userConfiguredIme: only real module names count" {
    try std.testing.expect(!userConfiguredIme(.{}));
    try std.testing.expect(!userConfiguredIme(.{ .env = "none" }));
    try std.testing.expect(!userConfiguredIme(.{ .env = "simple" }));
    try std.testing.expect(!userConfiguredIme(.{ .setting = "gtk-im-context-simple" }));
    try std.testing.expect(!userConfiguredIme(.{ .env = "  ", .setting = "" }));
    try std.testing.expect(userConfiguredIme(.{ .env = "ibus" }));
    try std.testing.expect(userConfiguredIme(.{ .setting = "fcitx5" }));
    try std.testing.expect(userConfiguredIme(.{ .env = "none", .setting = "ibus" }));
}

test "strategyFor: explicit preference wins on every face" {
    const ime: ImEnv = .{ .env = "fcitx5" };
    for ([_]Face{ .terminal, .editor, .app_host }) |f| {
        try std.testing.expectEqual(Strategy.simple, strategyFor(f, .simple, ime));
        try std.testing.expectEqual(Strategy.multi, strategyFor(f, .multi, .{}));
    }
}

test "strategyFor: auto keeps the terminal on simple, forever" {
    try std.testing.expectEqual(Strategy.simple, strategyFor(.terminal, .auto, .{}));
    try std.testing.expectEqual(Strategy.simple, strategyFor(.terminal, .auto, .{ .env = "ibus" }));
    try std.testing.expectEqual(Strategy.simple, strategyFor(.terminal, .auto, .{ .setting = "fcitx5" }));
}

test "strategyFor: auto follows the session for editor and app host" {
    for ([_]Face{ .editor, .app_host }) |f| {
        try std.testing.expectEqual(Strategy.simple, strategyFor(f, .auto, .{}));
        try std.testing.expectEqual(Strategy.simple, strategyFor(f, .auto, .{ .env = "none" }));
        try std.testing.expectEqual(Strategy.multi, strategyFor(f, .auto, .{ .env = "ibus" }));
        try std.testing.expectEqual(Strategy.multi, strategyFor(f, .auto, .{ .setting = "ibus" }));
    }
}
