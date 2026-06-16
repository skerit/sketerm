//! Linux/GTK accessibility bridge.
//!
//! Exposes a terminal pane to AT-SPI (Orca, braille via BRLTTY) by giving
//! the pane's `GtkGLArea` a subclass that implements `GtkAccessibleText`.
//! A bare GtkGLArea is an opaque box to a screen reader; this makes its
//! text + caret readable. All the actual text model lives in the
//! platform-neutral `view.zig` so a future macOS NSAccessibility bridge
//! reuses it unchanged.

const std = @import("std");
const c = @import("../c.zig").c;
const Terminal = @import("../terminal.zig").Terminal;
const view = @import("view.zig");

/// qdata key carrying the owning `*Terminal` (stable; `terminal.screen`
/// itself is swapped wholesale on a remote snapshot, so we deref it live).
const TERM_KEY = "sketerm-a11y-term";

var area_gtype: c.GType = 0;

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
    return w;
}

/// Tell AT clients the caret moved / contents changed. Cheap; AT clients
/// re-query `get_contents` on demand. Call when the screen has changed.
pub fn notifyChanged(widget: *c.GtkWidget) void {
    c.gtk_accessible_text_update_caret_position(@ptrCast(@alignCast(widget)));
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

// ── helpers ──────────────────────────────────────────────────────────

fn termOf(self: ?*c.GtkAccessibleText) ?*Terminal {
    const d = c.g_object_get_data(@ptrCast(@alignCast(self orelse return null)), TERM_KEY) orelse return null;
    return @ptrCast(@alignCast(d));
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
    var s = snap(self) orelse return 0;
    defer s.deinit();
    return s.caret;
}

fn getSelection(
    _: ?*c.GtkAccessibleText,
    n_ranges: [*c]c.gsize,
    _: [*c][*c]c.GtkAccessibleTextRange,
) callconv(.c) c.gboolean {
    // No selection exposed yet (the terminal's own selection model is a
    // follow-up). Report none.
    n_ranges.* = 0;
    return 0;
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
