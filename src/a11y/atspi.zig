//! Linux/GTK accessibility bridge for a GPU canvas.
//!
//! A bare `GtkGLArea` is an opaque box to a screen reader. This module
//! gives one a subclass that implements `GtkAccessibleText`, so its
//! text + caret + selection become readable by Orca (and braille via
//! BRLTTY). It is deliberately content-agnostic: what the canvas is
//! showing arrives through a `Source` vtable, so the terminal grid
//! (`termsource.zig`, over the platform-neutral `view.zig`) and the
//! editor's rope (`docsource.zig`, over `docview.zig`) share one
//! GType-and-notification implementation rather than forking it.
//!
//! Notification policy: `notifyChanged` is called for every applied
//! event batch, edit and selection mutation, but emission is coalesced
//! to at most one per `INTERVAL_MS` with a trailing-edge timer, because
//! a busy TUI rewrites the screen — and a held key rewrites a document
//! line — far faster than any reader can speak. Until an AT actually
//! queries this canvas (any vfunc firing flips `at_active`), an
//! emission is a bare caret nudge: no source query, no rope walk, no
//! snapshot, so a session without a screen reader pays nothing.
//!
//! Content-change notifications diff a REGION the source nominates —
//! the whole screen for a terminal, a caret-anchored line block for a
//! document. The region carries an identity `key` and its own starting
//! character offset; a burst whose region key or origin moved since the
//! last one emits NO text-changed event (only caret/selection), because
//! a diff across two different regions would be a fabricated range.
//! Emitting nothing is correct: readers re-read on the caret move.

const std = @import("std");
const c = @import("../c.zig").c;
const view = @import("view.zig");

/// qdata key carrying the per-area `*State` (owned; freed on finalize).
const STATE_KEY = "sketerm-a11y-state";

/// Emission floor: at most one AT-SPI notification burst per this many
/// ms. 75ms ≈ 13/s worst case — far below a full-rate TUI redraw, still
/// instant to a human listener.
const INTERVAL_MS: i64 = 75;

/// Preedit announcement debounce: a composing keystroke burst speaks
/// only its final state, this many ms after the last change.
const PREEDIT_MS: c.guint = 150;

/// Text granularity an AT asked for, collapsed to the three units both
/// backends can answer. SENTENCE/PARAGRAPH map onto LINE.
pub const Gran = enum { character, word, line };

/// A character range [start, end) of the accessible text.
pub const Range = struct { start: u32, end: u32 };

/// Text for a granularity unit, plus the range it occupies.
pub const Chunk = struct { text: []u8, start: u32, end: u32 };

/// The slice of accessible text a source is willing to diff for
/// change notifications, its character offset, and an identity key.
/// Bursts only diff two regions with the same key AND the same
/// `char0`; see the file header.
pub const Region = struct { text: []u8, char0: u32, key: u64 };

/// Everything the bridge needs to know about the canvas's content.
/// All calls happen on the main thread, only while an AT is attached,
/// and every returned allocation is freed by the bridge.
pub const VTable = struct {
    /// UTF-8 bytes of character range [c0, c1), clamped by the source.
    contents: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, c0: u32, c1: u32) ?[]u8,
    /// The granularity unit containing character offset `off`.
    contentsAt: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, off: u32, gran: Gran) ?Chunk,
    /// Character offset of the (primary) caret.
    caret: *const fn (ctx: *anyopaque) u32,
    /// Every non-empty selection, most significant first. Empty slice
    /// = no selection (a bare caret is a position, not a selection).
    selections: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator) []Range,
    /// The diff region for change notifications; null = this burst
    /// cannot be localized, so no text-changed event is emitted.
    region: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator) ?Region,
};

pub const Source = struct { ctx: *anyopaque, vtable: *const VTable };

/// Which accessible role (and therefore which GType) an area gets.
pub const Role = enum {
    /// A terminal emulator's screen: read-only, grid-shaped.
    terminal,
    /// An editable multi-line document canvas.
    text_box,
};

var term_gtype: c.GType = 0;
var edit_gtype: c.GType = 0;

/// Per-area notify state: the source, the AT-activity gate, the
/// coalescing timer, and the previously announced region/caret/
/// selection for diffing.
const State = struct {
    allocator: std.mem.Allocator,
    /// Null once severed; every query and emission short-circuits.
    source: ?Source = null,
    /// An AT has queried this canvas at least once (vfunc fired).
    /// Gates all the snapshot/diff work in `emitNow`.
    at_active: bool = false,
    timer: c.guint = 0,
    last_emit_ms: i64 = 0,
    /// At least one burst has been emitted, so the prev_* fields are
    /// meaningful (offset 0 / no selection are legitimate values).
    have_prev: bool = false,
    prev_text: ?[]u8 = null,
    prev_key: u64 = 0,
    prev_char0: u32 = 0,
    prev_caret: u32 = 0,
    prev_sel: []Range = &.{},
    /// IME preedit debounce (see `announcePreedit`): the latest
    /// composition string, NUL-terminated for gtk_accessible_announce,
    /// and its trailing-edge timer.
    preedit: ?[:0]u8 = null,
    preedit_timer: c.guint = 0,

    fn dropPrev(self: *State) void {
        if (self.prev_text) |t| self.allocator.free(t);
        self.prev_text = null;
        if (self.prev_sel.len > 0) self.allocator.free(self.prev_sel);
        self.prev_sel = &.{};
        self.have_prev = false;
    }

    fn dropPreedit(self: *State) void {
        if (self.preedit) |p| self.allocator.free(p);
        self.preedit = null;
        if (self.preedit_timer != 0) {
            _ = c.g_source_remove(self.preedit_timer); // destroy-notify unrefs the widget
            self.preedit_timer = 0;
        }
    }
};

/// The GType for `role`: a GtkGLArea subclass implementing
/// GtkAccessibleText. Registered once per role.
pub fn ensureType(role: Role) c.GType {
    const slot = switch (role) {
        .terminal => &term_gtype,
        .text_box => &edit_gtype,
    };
    if (slot.* != 0) return slot.*;
    slot.* = c.g_type_register_static_simple(
        c.gtk_gl_area_get_type(),
        switch (role) {
            .terminal => "SketermTermArea",
            .text_box => "SketermEditArea",
        },
        @sizeOf(c.GtkGLAreaClass),
        switch (role) {
            .terminal => classInitTerm,
            .text_box => classInitEdit,
        },
        @sizeOf(c.GtkGLArea),
        null,
        c.G_TYPE_FLAG_NONE,
    );
    var info = c.GInterfaceInfo{
        .interface_init = ifaceInit,
        .interface_finalize = null,
        .interface_data = null,
    };
    c.g_type_add_interface_static(slot.*, c.gtk_accessible_text_get_type(), &info);
    return slot.*;
}

/// Create a GL area of `role` bound to `source`, labelled `label`.
pub fn newArea(
    role: Role,
    source: Source,
    label: [*:0]const u8,
    allocator: std.mem.Allocator,
) *c.GtkWidget {
    const w: *c.GtkWidget = @ptrCast(@alignCast(c.g_object_new(ensureType(role), @as([*c]const u8, null))));
    const st = allocator.create(State) catch null;
    if (st) |s| {
        s.* = .{ .allocator = allocator, .source = source };
        c.g_object_set_data_full(@ptrCast(@alignCast(w)), STATE_KEY, @ptrCast(s), destroyState);
    }
    c.gtk_accessible_update_property(
        @ptrCast(@alignCast(w)),
        c.GTK_ACCESSIBLE_PROPERTY_LABEL,
        label,
        @as(c_int, -1),
    );
    if (role == .text_box) {
        // An editable, multi-line text box: without these an AT-SPI
        // ENTRY reads as a single-line read-only field and Orca refuses
        // to run its caret-review commands over it.
        c.gtk_accessible_update_property(
            @ptrCast(@alignCast(w)),
            c.GTK_ACCESSIBLE_PROPERTY_READ_ONLY,
            @as(c_int, 0),
            @as(c_int, -1),
        );
        c.gtk_accessible_update_property(
            @ptrCast(@alignCast(w)),
            c.GTK_ACCESSIBLE_PROPERTY_MULTI_LINE,
            @as(c_int, 1),
            @as(c_int, -1),
        );
    }
    // Widget destruction severs unconditionally: no pending timer (with
    // its widget ref) and no source back-pointer may outlive the widget
    // tree, whichever teardown path got here.
    _ = c.g_signal_connect_data(w, "destroy", @ptrCast(&onAreaDestroy), null, null, c.G_CONNECT_DEFAULT);
    return w;
}

/// Screen-reader label. Callers update it when their title changes, so
/// "Terminal" becomes e.g. "vim src/main.zig", and an editor canvas
/// names the document it is showing.
pub fn setLabel(widget: *c.GtkWidget, title_z: [*:0]const u8) void {
    c.gtk_accessible_update_property(
        @ptrCast(@alignCast(widget)),
        c.GTK_ACCESSIBLE_PROPERTY_LABEL,
        title_z,
        @as(c_int, -1),
    );
}

/// Pre-teardown sever: drop the source back-pointer, cancel the
/// coalescing timer, forget the diff cache. Idempotent; called from
/// `Pane.severFaces` (widgets alive) and from the area's own destroy.
pub fn sever(widget: *c.GtkWidget) void {
    const st = stateOf(widget) orelse return;
    st.source = null;
    if (st.timer != 0) {
        _ = c.g_source_remove(st.timer); // its destroy-notify drops the widget ref
        st.timer = 0;
    }
    st.dropPrev();
    st.dropPreedit();
}

/// Tell an attached AT what the IME is composing over this canvas.
///
/// AT-SPI has no composition event on the text widget itself and GTK's
/// own editables expose nothing during preedit (the composed text is
/// only announced when it commits, through the normal text-changed
/// path). The vocabulary that DOES reach a reader today is the AT-SPI
/// Announcement (`object:announcement`, live-region semantics), which
/// Orca speaks at POLITE priority — so the uncommitted string is
/// announced as transient speech and the accessible TEXT stays equal to
/// the document, keeping every offset honest.
///
/// Debounced trailing-edge (`PREEDIT_MS`): composing rewrites the
/// string per keystroke, and only the latest state is worth speaking.
/// An empty `text` cancels (preedit ended: the commit announces itself
/// via the document's own change events). No-op until an AT has
/// actually queried the canvas, so sessions without a reader pay one
/// branch.
pub fn announcePreedit(widget: *c.GtkWidget, text: []const u8) void {
    const st = stateOf(widget) orelse return;
    if (!st.at_active or st.source == null) return;
    if (st.preedit) |p| st.allocator.free(p);
    st.preedit = null;
    if (text.len == 0) {
        if (st.preedit_timer != 0) {
            _ = c.g_source_remove(st.preedit_timer);
            st.preedit_timer = 0;
        }
        return;
    }
    st.preedit = st.allocator.dupeZ(u8, text) catch return;
    if (st.preedit_timer != 0) return; // trailing emit already scheduled
    st.preedit_timer = c.g_timeout_add_full(
        c.G_PRIORITY_DEFAULT,
        PREEDIT_MS,
        onPreeditTimer,
        c.g_object_ref(@as(c.gpointer, @ptrCast(widget))),
        unrefWidget,
    );
}

fn onPreeditTimer(user: c.gpointer) callconv(.c) c.gboolean {
    const widget: *c.GtkWidget = @ptrCast(@alignCast(user.?));
    if (stateOf(widget)) |st| {
        st.preedit_timer = 0;
        if (st.preedit) |p| {
            c.gtk_accessible_announce(
                @ptrCast(@alignCast(widget)),
                p.ptr,
                c.GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM,
            );
            st.allocator.free(p);
            st.preedit = null;
        }
    }
    return 0; // one-shot; destroy-notify unrefs the widget
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

/// Emit the actual AT-SPI notifications for the current content.
fn emitNow(widget: *c.GtkWidget, st: *State) void {
    st.last_emit_ms = nowMs();
    const at: ?*c.GtkAccessibleText = @ptrCast(@alignCast(widget));
    if (!st.at_active) {
        // Nobody listening yet: a caret nudge is free (GTK no-ops it
        // while the ATContext is unrealized) and enough to bootstrap.
        c.gtk_accessible_text_update_caret_position(at);
        return;
    }
    const src = st.source orelse return; // severed

    if (src.vtable.region(src.ctx, st.allocator)) |reg| {
        if (st.prev_text) |old| {
            if (st.prev_key == reg.key and st.prev_char0 == reg.char0) {
                // GTK re-queries get_contents for the announced string,
                // so the REMOVE range's text reads from the NEW content
                // (it already changed) — same after-the-fact semantics
                // as GTK's own text widgets; readers key on the range +
                // the INSERT, which are exact.
                if (view.diffChars(old, reg.text)) |chg| {
                    if (chg.del_end > chg.del_start)
                        c.gtk_accessible_text_update_contents(at, c.GTK_ACCESSIBLE_TEXT_CONTENT_CHANGE_REMOVE, reg.char0 + chg.del_start, reg.char0 + chg.del_end);
                    if (chg.ins_end > chg.ins_start)
                        c.gtk_accessible_text_update_contents(at, c.GTK_ACCESSIBLE_TEXT_CONTENT_CHANGE_INSERT, reg.char0 + chg.ins_start, reg.char0 + chg.ins_end);
                }
            }
            st.allocator.free(old);
        }
        st.prev_text = reg.text;
        st.prev_key = reg.key;
        st.prev_char0 = reg.char0;
    } else if (st.prev_text) |old| {
        st.allocator.free(old);
        st.prev_text = null;
    }

    const caret = src.vtable.caret(src.ctx);
    if (!st.have_prev or st.prev_caret != caret) {
        st.prev_caret = caret;
        c.gtk_accessible_text_update_caret_position(at);
    }

    // No `have_prev` guard here: an empty `prev_sel` already IS "no
    // selection", so a first burst without one must not announce a
    // selection change.
    const sels = src.vtable.selections(src.ctx, st.allocator);
    if (!rangesEql(st.prev_sel, sels)) {
        if (st.prev_sel.len > 0) st.allocator.free(st.prev_sel);
        st.prev_sel = sels;
        c.gtk_accessible_text_update_selection_bound(at);
    } else if (sels.len > 0) {
        st.allocator.free(sels);
    }
    st.have_prev = true;
}

fn rangesEql(a: []const Range, b: []const Range) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.start != y.start or x.end != y.end) return false;
    return true;
}

fn nowMs() i64 {
    return @divTrunc(c.g_get_monotonic_time(), 1000);
}

fn classInitTerm(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const wc: *c.GtkWidgetClass = @ptrCast(@alignCast(klass));
    c.gtk_widget_class_set_accessible_role(wc, c.GTK_ACCESSIBLE_ROLE_TERMINAL);
}

fn classInitEdit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const wc: *c.GtkWidgetClass = @ptrCast(@alignCast(klass));
    c.gtk_widget_class_set_accessible_role(wc, c.GTK_ACCESSIBLE_ROLE_TEXT_BOX);
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
    st.dropPrev();
    st.dropPreedit();
    st.allocator.destroy(st);
}

// ── helpers ──────────────────────────────────────────────────────────

fn stateOf(widget: anytype) ?*State {
    const d = c.g_object_get_data(@ptrCast(@alignCast(widget)), STATE_KEY) orelse return null;
    return @ptrCast(@alignCast(d));
}

/// A vfunc fired: a real AT is reading this canvas. From here on,
/// `emitNow` does the query+diff work.
fn active(self: ?*c.GtkAccessibleText) ?*State {
    const st = stateOf(self orelse return null) orelse return null;
    st.at_active = true;
    if (st.source == null) return null;
    return st;
}

fn bytesNew(b: []const u8) ?*c.GBytes {
    if (b.len == 0) return c.g_bytes_new(null, 0);
    return c.g_bytes_new(b.ptr, b.len);
}

// ── GtkAccessibleText vfuncs ─────────────────────────────────────────

fn getContents(self: ?*c.GtkAccessibleText, start: c_uint, end: c_uint) callconv(.c) ?*c.GBytes {
    const st = active(self) orelse return c.g_bytes_new(null, 0);
    const src = st.source.?;
    const text = src.vtable.contents(src.ctx, st.allocator, @intCast(start), @intCast(end)) orelse
        return c.g_bytes_new(null, 0);
    defer st.allocator.free(text);
    return bytesNew(text);
}

fn getContentsAt(
    self: ?*c.GtkAccessibleText,
    offset: c_uint,
    granularity: c.GtkAccessibleTextGranularity,
    start: [*c]c_uint,
    end: [*c]c_uint,
) callconv(.c) ?*c.GBytes {
    start.* = 0;
    end.* = 0;
    const st = active(self) orelse return c.g_bytes_new(null, 0);
    const src = st.source.?;
    const gran: Gran = switch (granularity) {
        c.GTK_ACCESSIBLE_TEXT_GRANULARITY_CHARACTER => .character,
        c.GTK_ACCESSIBLE_TEXT_GRANULARITY_WORD => .word,
        // LINE / SENTENCE / PARAGRAPH all map to one line.
        else => .line,
    };
    const chunk = src.vtable.contentsAt(src.ctx, st.allocator, @intCast(offset), gran) orelse
        return c.g_bytes_new(null, 0);
    defer st.allocator.free(chunk.text);
    start.* = chunk.start;
    end.* = chunk.end;
    return bytesNew(chunk.text);
}

fn getCaretPosition(self: ?*c.GtkAccessibleText) callconv(.c) c_uint {
    const st = active(self) orelse return 0;
    const src = st.source.?;
    return src.vtable.caret(src.ctx);
}

fn getSelection(
    self: ?*c.GtkAccessibleText,
    n_ranges: [*c]c.gsize,
    ranges: [*c][*c]c.GtkAccessibleTextRange,
) callconv(.c) c.gboolean {
    n_ranges.* = 0;
    const st = active(self) orelse return 0;
    const src = st.source.?;
    const sels = src.vtable.selections(src.ctx, st.allocator);
    defer if (sels.len > 0) st.allocator.free(sels);
    if (sels.len == 0) return 0;
    // (transfer container): GTK g_free()s the array, not the contents.
    const arr: [*c]c.GtkAccessibleTextRange = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GtkAccessibleTextRange) * sels.len)));
    for (sels, 0..) |r, i| arr[i] = .{ .start = r.start, .length = r.end - r.start };
    n_ranges.* = sels.len;
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
