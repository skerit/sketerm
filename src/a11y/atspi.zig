//! Linux/GTK accessibility bridge.
//!
//! Exposes a terminal pane to AT-SPI (Orca, braille via BRLTTY) by giving
//! the pane's `GtkGLArea` a subclass that implements `GtkAccessibleText`.
//! A bare GtkGLArea is an opaque box to a screen reader; this makes its
//! text + caret + selection readable. All the actual text model lives in
//! the platform-neutral `view.zig` so the macOS NSAccessibility bridge
//! reuses it unchanged.
//!
//! Notification policy: `notifyChanged` is called for every applied event
//! batch (and selection mutation), but emission is coalesced to at most
//! one per `INTERVAL_MS` with a trailing-edge timer, because a busy TUI
//! rewrites the screen far faster than any reader can speak. Until an AT
//! actually queries this pane (any vfunc firing flips `at_active`), an
//! emission is a bare caret nudge — no snapshot is built, so a session
//! without a screen reader pays nothing per batch.

const std = @import("std");
const c = @import("../c.zig").c;
const Terminal = @import("../terminal.zig").Terminal;
const view = @import("view.zig");

/// qdata key carrying the owning `*Terminal` (stable; `terminal.screen`
/// itself is swapped wholesale on a remote snapshot, so we deref it live).
const TERM_KEY = "sketerm-a11y-term";
/// qdata key carrying the per-area `*State` (owned; freed on finalize).
const STATE_KEY = "sketerm-a11y-state";

/// Emission floor: at most one AT-SPI notification burst per this many
/// ms. 75ms ≈ 13/s worst case — far below a full-rate TUI redraw, still
/// instant to a human listener.
const INTERVAL_MS: i64 = 75;

var area_gtype: c.GType = 0;

/// Per-area notify state: the AT-activity gate, the coalescing timer,
/// and the previously announced text/caret/selection for diffing.
const State = struct {
    allocator: std.mem.Allocator,
    /// An AT has queried this pane at least once (vfunc fired). Gates
    /// the snapshot+diff work in `emitNow`.
    at_active: bool = false,
    timer: c.guint = 0,
    last_emit_ms: i64 = 0,
    prev_text: ?[]u8 = null,
    prev_caret: u32 = 0,
    prev_sel: ?[2]u32 = null,
};

/// The `SketermTermArea` GType: a GtkGLArea that implements
/// GtkAccessibleText and reports the TERMINAL role. Registered once.
pub fn ensureType() c.GType {
    if (area_gtype != 0) return area_gtype;
    area_gtype = c.g_type_register_static_simple(
        c.gtk_gl_area_get_type(),
        "SketermTermArea",
        @sizeOf(c.GtkGLAreaClass),
        classInit,
        @sizeOf(c.GtkGLArea),
        null,
        c.G_TYPE_FLAG_NONE,
    );
    var info = c.GInterfaceInfo{
        .interface_init = ifaceInit,
        .interface_finalize = null,
        .interface_data = null,
    };
    c.g_type_add_interface_static(area_gtype, c.gtk_accessible_text_get_type(), &info);
    return area_gtype;
}

/// Create the pane's GL area as a SketermTermArea bound to `term`.
pub fn newArea(term: *Terminal) *c.GtkWidget {
    const w: *c.GtkWidget = @ptrCast(@alignCast(c.g_object_new(ensureType(), @as([*c]const u8, null))));
    c.g_object_set_data(@ptrCast(@alignCast(w)), TERM_KEY, @ptrCast(term));
    const st = term.allocator.create(State) catch null;
    if (st) |s| {
        s.* = .{ .allocator = term.allocator };
        c.g_object_set_data_full(@ptrCast(@alignCast(w)), STATE_KEY, @ptrCast(s), destroyState);
    }
    c.gtk_accessible_update_property(
        @ptrCast(@alignCast(w)),
        c.GTK_ACCESSIBLE_PROPERTY_LABEL,
        @as([*c]const u8, "Terminal"),
        @as(c_int, -1),
    );
    // Widget destruction severs unconditionally: no pending timer (with
    // its widget ref) and no Terminal back-pointer may outlive the
    // widget tree, whichever teardown path got here.
    _ = c.g_signal_connect_data(w, "destroy", @ptrCast(&onAreaDestroy), null, null, c.G_CONNECT_DEFAULT);
    return w;
}

/// Screen-reader label. The pane calls this when its title changes, so
/// "Terminal" becomes e.g. "vim src/main.zig" in a reader's focus
/// announcement.
pub fn setLabel(widget: *c.GtkWidget, title_z: [*:0]const u8) void {
    c.gtk_accessible_update_property(
        @ptrCast(@alignCast(widget)),
        c.GTK_ACCESSIBLE_PROPERTY_LABEL,
        title_z,
        @as(c_int, -1),
    );
}

/// Pre-teardown sever: drop the Terminal back-pointer, cancel the
/// coalescing timer, forget the diff cache. Idempotent; called from
/// `Pane.severFaces` (widgets alive) and from the area's own destroy.
pub fn sever(widget: *c.GtkWidget) void {
    c.g_object_set_data(@ptrCast(@alignCast(widget)), TERM_KEY, null);
    const st = stateOf(widget) orelse return;
    if (st.timer != 0) {
        _ = c.g_source_remove(st.timer); // its destroy-notify drops the widget ref
        st.timer = 0;
    }
    if (st.prev_text) |t| {
        st.allocator.free(t);
        st.prev_text = null;
    }
}

/// Tell AT clients the caret/contents/selection may have changed.
/// Coalesced (see file header); cheap when no screen reader is attached.
pub fn notifyChanged(widget: *c.GtkWidget) void {
    const st = stateOf(widget) orelse {
        c.gtk_accessible_text_update_caret_position(@ptrCast(@alignCast(widget)));
        return;
    };
    if (st.timer != 0) return; // trailing emit already scheduled
    const now = nowMs();
    if (now - st.last_emit_ms >= INTERVAL_MS) {
        emitNow(widget, st);
        return;
    }
    const delay: c.guint = @intCast(INTERVAL_MS - (now - st.last_emit_ms));
    st.timer = c.g_timeout_add_full(
        c.G_PRIORITY_DEFAULT,
        delay,
        onCoalesceTimer,
        c.g_object_ref(@as(c.gpointer, @ptrCast(widget))),
        unrefWidget,
    );
}

fn onCoalesceTimer(user: c.gpointer) callconv(.c) c.gboolean {
    const widget: *c.GtkWidget = @ptrCast(@alignCast(user.?));
    if (stateOf(widget)) |st| {
        st.timer = 0;
        emitNow(widget, st);
    }
    return 0; // one-shot; destroy-notify unrefs the widget
}

fn unrefWidget(user: c.gpointer) callconv(.c) void {
    c.g_object_unref(user);
}

/// Emit the actual AT-SPI notifications for the current screen state.
fn emitNow(widget: *c.GtkWidget, st: *State) void {
    st.last_emit_ms = nowMs();
    const at: ?*c.GtkAccessibleText = @ptrCast(@alignCast(widget));
    if (!st.at_active) {
        // Nobody listening yet: a caret nudge is free (GTK no-ops it
        // while the ATContext is unrealized) and enough to bootstrap.
        c.gtk_accessible_text_update_caret_position(at);
        return;
    }
    const term = termOf(at) orelse return; // severed
    var s = view.build(term.screen, term.allocator) catch return;
    defer s.deinit();

    if (st.prev_text) |old| {
        if (view.diffChars(old, s.text)) |chg| {
            // GTK re-queries get_contents for the announced string, so
            // the REMOVE range's text reads from the NEW screen (the
            // grid already changed) — same after-the-fact semantics as
            // GTK's own text widgets; readers key on the range + the
            // INSERT, which are exact.
            if (chg.del_end > chg.del_start)
                c.gtk_accessible_text_update_contents(at, c.GTK_ACCESSIBLE_TEXT_CONTENT_CHANGE_REMOVE, chg.del_start, chg.del_end);
            if (chg.ins_end > chg.ins_start)
                c.gtk_accessible_text_update_contents(at, c.GTK_ACCESSIBLE_TEXT_CONTENT_CHANGE_INSERT, chg.ins_start, chg.ins_end);
        }
    }
    const first = st.prev_text == null;
    if (first or !std.mem.eql(u8, st.prev_text.?, s.text)) {
        const copy = st.allocator.dupe(u8, s.text) catch null;
        if (copy) |cp| {
            if (st.prev_text) |old| st.allocator.free(old);
            st.prev_text = cp;
        }
    }
    if (first or st.prev_caret != s.caret) {
        st.prev_caret = s.caret;
        c.gtk_accessible_text_update_caret_position(at);
    }
    const cur_sel: ?[2]u32 = if (s.sel_start) |a| .{ a, s.sel_end.? } else null;
    const sel_changed = if (st.prev_sel) |p|
        (if (cur_sel) |n| p[0] != n[0] or p[1] != n[1] else true)
    else
        cur_sel != null;
    if (sel_changed) {
        st.prev_sel = cur_sel;
        c.gtk_accessible_text_update_selection_bound(at);
    }
}

fn nowMs() i64 {
    return @divTrunc(c.g_get_monotonic_time(), 1000);
}

fn classInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const wc: *c.GtkWidgetClass = @ptrCast(@alignCast(klass));
    c.gtk_widget_class_set_accessible_role(wc, c.GTK_ACCESSIBLE_ROLE_TERMINAL);
}

fn ifaceInit(iface: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const i: *c.GtkAccessibleTextInterface = @ptrCast(@alignCast(iface));
    i.get_contents = getContents;
    i.get_contents_at = getContentsAt;
    i.get_caret_position = getCaretPosition;
    i.get_selection = getSelection;
    i.get_attributes = getAttributes;
    i.get_default_attributes = getDefaultAttributes;
}

fn onAreaDestroy(widget: ?*c.GtkWidget, _: c.gpointer) callconv(.c) void {
    sever(widget.?);
}

fn destroyState(p: ?*anyopaque) callconv(.c) void {
    const st: *State = @ptrCast(@alignCast(p.?));
    if (st.prev_text) |t| st.allocator.free(t);
    st.allocator.destroy(st);
}

// ── helpers ──────────────────────────────────────────────────────────

fn termOf(self: ?*c.GtkAccessibleText) ?*Terminal {
    const d = c.g_object_get_data(@ptrCast(@alignCast(self orelse return null)), TERM_KEY) orelse return null;
    return @ptrCast(@alignCast(d));
}

fn stateOf(widget: anytype) ?*State {
    const d = c.g_object_get_data(@ptrCast(@alignCast(widget)), STATE_KEY) orelse return null;
    return @ptrCast(@alignCast(d));
}

/// A vfunc fired: a real AT is reading this pane. From here on,
/// `emitNow` does the snapshot+diff work.
fn markActive(self: ?*c.GtkAccessibleText) void {
    const st = stateOf(self orelse return) orelse return;
    st.at_active = true;
}

fn snap(self: ?*c.GtkAccessibleText) ?view.Snapshot {
    const term = termOf(self) orelse return null;
    return view.build(term.screen, term.allocator) catch null;
}

fn bytesNew(b: []const u8) ?*c.GBytes {
    if (b.len == 0) return c.g_bytes_new(null, 0);
    return c.g_bytes_new(b.ptr, b.len);
}

// ── GtkAccessibleText vfuncs ─────────────────────────────────────────

fn getContents(self: ?*c.GtkAccessibleText, start: c_uint, end: c_uint) callconv(.c) ?*c.GBytes {
    markActive(self);
    var s = snap(self) orelse return c.g_bytes_new(null, 0);
    defer s.deinit();
    return bytesNew(s.byteRange(@intCast(start), @intCast(end)));
}

fn getContentsAt(
    self: ?*c.GtkAccessibleText,
    offset: c_uint,
    granularity: c.GtkAccessibleTextGranularity,
    start: [*c]c_uint,
    end: [*c]c_uint,
) callconv(.c) ?*c.GBytes {
    markActive(self);
    var s = snap(self) orelse {
        start.* = 0;
        end.* = 0;
        return c.g_bytes_new(null, 0);
    };
    defer s.deinit();
    const off: u32 = @intCast(offset);
    var rs: u32 = undefined;
    var re: u32 = undefined;
    switch (granularity) {
        c.GTK_ACCESSIBLE_TEXT_GRANULARITY_CHARACTER => {
            rs = @min(off, s.n_chars);
            re = @min(off + 1, s.n_chars);
        },
        c.GTK_ACCESSIBLE_TEXT_GRANULARITY_WORD => {
            const w = s.wordRange(off);
            rs = w.start;
            re = w.end;
        },
        // LINE / SENTENCE / PARAGRAPH all map to a grid row for a terminal.
        else => {
            const l = s.lineRange(off);
            rs = l.start;
            re = l.end;
        },
    }
    start.* = rs;
    end.* = re;
    return bytesNew(s.byteRange(rs, re));
}

fn getCaretPosition(self: ?*c.GtkAccessibleText) callconv(.c) c_uint {
    markActive(self);
    var s = snap(self) orelse return 0;
    defer s.deinit();
    return s.caret;
}

fn getSelection(
    self: ?*c.GtkAccessibleText,
    n_ranges: [*c]c.gsize,
    ranges: [*c][*c]c.GtkAccessibleTextRange,
) callconv(.c) c.gboolean {
    markActive(self);
    n_ranges.* = 0;
    var s = snap(self) orelse return 0;
    defer s.deinit();
    const a = s.sel_start orelse return 0;
    const b = s.sel_end orelse return 0;
    // (transfer container): GTK g_free()s the array, not the contents.
    const arr: [*c]c.GtkAccessibleTextRange = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GtkAccessibleTextRange))));
    arr[0] = .{ .start = a, .length = b - a };
    n_ranges.* = 1;
    ranges.* = arr;
    return 1;
}

fn getAttributes(
    _: ?*c.GtkAccessibleText,
    _: c_uint,
    n_ranges: [*c]c.gsize,
    _: [*c][*c]c.GtkAccessibleTextRange,
    _: [*c][*c][*c]u8,
    _: [*c][*c][*c]u8,
) callconv(.c) c.gboolean {
    n_ranges.* = 0;
    return 0;
}

fn getDefaultAttributes(
    _: ?*c.GtkAccessibleText,
    attribute_names: [*c][*c][*c]u8,
    attribute_values: [*c][*c][*c]u8,
) callconv(.c) void {
    // Empty, NULL-terminated arrays (GTK frees them with g_strfreev).
    attribute_names.* = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(?*u8))));
    attribute_values.* = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(?*u8))));
}
