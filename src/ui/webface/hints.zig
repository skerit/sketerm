//! Link hints (the human skin over the semantic layer). Split out of `webface.zig`; the `WebFace` methods are free functions
//! taking `*WebFace`, re-exported from `WebFace` by name.

const std = @import("std");
const c = @import("../../c.zig").c;
const proto = @import("../../web/protocol.zig");
const webhints = @import("../../web/hints.zig");
const host_mod = @import("../webface.zig");
const WebFace = host_mod.WebFace;
const webhintCss = host_mod.webhintCss;

/// Cap on painted hint labels; a page listing more is a page nobody
/// hint-navigates past the first few hundred anyway.
pub const MAX_HINTS = 300;

/// One painted link hint: the semantic id it activates, the link
/// target (for the new-tab modifier), its label and its label widget.
/// `url`/`label` are owned by the face's allocator; the widget belongs
/// to the hints layer and dies with it.
pub const HintItem = struct {
    sid: u32,
    url: []u8,
    label: []u8,
    widget: *c.GtkWidget,
};

// ---- link hints (the human skin over the semantic layer) --------

/// Kick off link hints: ask the helper for the visible interactive
/// elements (a `visible` semantic query — the same ids `web_act`
/// clicks), then paint labels when the reply lands. Returns true
/// when the chord is consumed; false only when this face cannot
/// hint at all, so `hints_open` falls through to the terminal.
pub fn startHints(self: *WebFace) bool {
    if (self.widgets_dead or !self.view_live) return false;
    if (self.hints_active) {
        // The chord toggles: hints-while-hinting means "never mind".
        self.cancelHints();
        return true;
    }
    if (self.hints_token != 0) return true; // request already out
    const token = self.autoBegin(.query, false) orelse return true;
    self.hints_token = token;
    // The viewport travels in the page's CSS px space: user zoom
    // shrinks the CSS viewport by its factor while the widget's
    // logical size stays put.
    const f = self.userZoomFactor();
    const vw: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(self.sent_w)) / f));
    const vh: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(self.sent_h)) / f));
    var buf: [32]u8 = undefined;
    const arg = std.fmt.bufPrint(&buf, "{d} {d}", .{ vw, vh }) catch return true;
    self.postSemantic(token, proto.SemQueryReq{
        .view = self.view,
        .kind = @intFromEnum(proto.SemQuery.visible),
        .arg = arg,
    });
    // The matcher lives on the view area's key controller.
    _ = c.gtk_widget_grab_focus(self.view_area);
    return true;
}

/// True when this query reply was a hints reply and is consumed
/// here; false hands it to the automation bookkeeping untouched.
pub fn onHintsResult(self: *WebFace, request: u32, text: []const u8) bool {
    if (self.hints_token == 0) return false;
    if (!self.acceptsOp(.query, request)) return false;
    for (self.auto_ops.items, 0..) |op, i| {
        if (op.token == self.hints_token) {
            _ = self.auto_ops.orderedRemove(i);
            break;
        }
    }
    self.hints_token = 0;
    self.buildHints(text);
    return true;
}

/// Parse the reply and paint one label per hint on a fresh overlay
/// layer. Rects are page-logical px, which IS the widget's logical
/// coordinate space — the inverse of the input mapping is just the
/// `snap_dx/dy` pixel-grid nudge the picture is drawn under.
pub fn buildHints(self: *WebFace, text: []const u8) void {
    self.cancelHints();
    if (self.widgets_dead or !self.on_screen) return;
    const parsed = (webhints.parse(self.allocator, text) catch return) orelse return;
    defer self.allocator.free(parsed);
    if (parsed.len == 0) return;
    const n = @min(parsed.len, MAX_HINTS);
    const labels = webhints.generateLabels(self.allocator, n, webhints.ALPHABET) catch return;
    var labels_moved: usize = 0;
    defer {
        for (labels[labels_moved..]) |l| self.allocator.free(l);
        self.allocator.free(labels);
    }

    webhintCss(self.view_area);
    const layer = c.gtk_fixed_new();
    c.gtk_widget_set_can_target(layer, 0);
    c.gtk_overlay_add_overlay(@ptrCast(self.overlay), layer);
    self.hints_layer = layer;

    const max_x: i32 = @max(0, @as(i32, self.sent_w) - 24);
    const max_y: i32 = @max(0, @as(i32, self.sent_h) - 16);
    // CSS px -> widget logical px: multiply the user-zoom factor
    // back in (DPR never appears — the wire is logical throughout).
    const f = self.userZoomFactor();
    for (parsed[0..n], 0..) |h, i| {
        const url = self.allocator.dupe(u8, h.url) catch break;
        var z: [16:0]u8 = @splat(0);
        const m = @min(labels[i].len, 15);
        @memcpy(z[0..m], labels[i][0..m]);
        const wgt = c.gtk_label_new(&z);
        c.gtk_widget_add_css_class(wgt, "sketerm-webhint");
        const zx: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(h.x)) * f));
        const zy: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(h.y)) * f));
        const x = std.math.clamp(zx + @as(i32, self.snap_dx), 0, max_x);
        const y = std.math.clamp(zy + @as(i32, self.snap_dy), 0, max_y);
        c.gtk_fixed_put(@ptrCast(layer), wgt, @floatFromInt(x), @floatFromInt(y));
        self.hints_items.append(self.allocator, .{
            .sid = h.sid,
            .url = url,
            .label = labels[i],
            .widget = wgt,
        }) catch {
            self.allocator.free(url);
            break;
        };
        labels_moved = i + 1;
    }
    if (self.hints_items.items.len == 0) {
        self.cancelHints();
        return;
    }
    self.hints_typed_len = 0;
    self.hints_active = true;
}

/// Take down the overlay and every owned hint string. Idempotent,
/// safe with dead widgets, and it also orphans any reply still in
/// flight (the automation bookkeeping absorbs it).
pub fn cancelHints(self: *WebFace) void {
    if (self.hints_token != 0) {
        for (self.auto_ops.items, 0..) |op, i| {
            if (op.token != self.hints_token) continue;
            const abandoned = self.auto_ops.orderedRemove(i);
            if (abandoned.request == 0)
                self.auto_legacy_quarantine.mark(@intFromEnum(abandoned.kind));
            break;
        }
    }
    if (self.hints_layer) |layer| {
        if (!self.widgets_dead) c.gtk_overlay_remove_overlay(@ptrCast(self.overlay), layer);
        self.hints_layer = null;
    }
    for (self.hints_items.items) |it| {
        self.allocator.free(it.url);
        self.allocator.free(it.label);
    }
    self.hints_items.clearRetainingCapacity();
    self.hints_typed_len = 0;
    self.hints_token = 0;
    self.hints_active = false;
}

/// The hints-mode key matcher. Consumes EVERY press — nothing may
/// leak to the page or to the chord table while labels are up —
/// and only Escape (or a dead-end prefix) leaves the mode.
pub fn hintsKey(self: *WebFace, keyval: c.guint, state: c.GdkModifierType) c.gboolean {
    if (keyval == c.GDK_KEY_Escape) {
        self.cancelHints();
        return 1;
    }
    if (keyval == c.GDK_KEY_BackSpace) {
        if (self.hints_typed_len > 0) {
            self.hints_typed_len -= 1;
            self.refilterHints(false, false);
        }
        return 1;
    }
    const new_tab = (@as(c_uint, @intCast(state)) &
        (c.GDK_SHIFT_MASK | c.GDK_CONTROL_MASK)) != 0;
    if (keyval == c.GDK_KEY_Return or keyval == c.GDK_KEY_KP_Enter) {
        if (self.soleVisibleHint()) |i| self.activateHint(i, new_tab);
        return 1;
    }
    const lower = c.gdk_keyval_to_lower(keyval);
    if (lower >= 'a' and lower <= 'z' and
        std.mem.indexOfScalar(u8, webhints.ALPHABET, @intCast(lower)) != null)
    {
        if (self.hints_typed_len < self.hints_typed.len) {
            self.hints_typed[self.hints_typed_len] = @intCast(lower);
            self.hints_typed_len += 1;
        }
        self.refilterHints(true, new_tab);
        return 1;
    }
    // Everything else (bare modifiers included) is swallowed.
    return 1;
}

/// Show only the labels matching the typed prefix. A fully typed
/// label activates (prefix-freedom makes that unambiguous); a
/// prefix nothing matches ends the mode, like Vimium.
pub fn refilterHints(self: *WebFace, allow_activate: bool, new_tab: bool) void {
    const typed = self.hints_typed[0..self.hints_typed_len];
    var visible: usize = 0;
    var exact: ?usize = null;
    for (self.hints_items.items, 0..) |it, i| {
        const match = std.mem.startsWith(u8, it.label, typed);
        if (!self.widgets_dead)
            c.gtk_widget_set_visible(it.widget, if (match) @as(c_int, 1) else 0);
        if (match) visible += 1;
        if (std.mem.eql(u8, it.label, typed)) exact = i;
    }
    if (!allow_activate) return;
    if (exact) |i| {
        self.activateHint(i, new_tab);
        return;
    }
    if (visible == 0) self.cancelHints();
}

pub fn soleVisibleHint(self: *WebFace) ?usize {
    const typed = self.hints_typed[0..self.hints_typed_len];
    var found: ?usize = null;
    for (self.hints_items.items, 0..) |it, i| {
        if (!std.mem.startsWith(u8, it.label, typed)) continue;
        if (found != null) return null;
        found = i;
    }
    return found;
}

/// Activate one hint: a link with the new-tab modifier opens its
/// url in a fresh web tab (`newWebTabAt`, the popup path); anything
/// else is a trusted click on the semantic id — byte-for-byte what
/// MCP's `web_act` does.
pub fn activateHint(self: *WebFace, idx: usize, new_tab: bool) void {
    const it = self.hints_items.items[idx];
    const sid = it.sid;
    var url_buf: [512]u8 = undefined;
    var url: []const u8 = "";
    if (it.url.len > 0 and it.url.len <= url_buf.len) {
        @memcpy(url_buf[0..it.url.len], it.url);
        url = url_buf[0..it.url.len];
    }
    self.cancelHints();
    if (new_tab and url.len > 0) {
        if (self.ownerWindow() != null) {
            self.openInNewTab(url);
            return;
        }
    }
    _ = self.autoAct(sid, @intFromEnum(proto.SemAct.click), "");
}
