//! Page-view tools: the find bar, reader mode and zoom. Split out of `webface.zig`; the `WebFace` methods are free functions
//! taking `*WebFace`, re-exported from `WebFace` by name.

const std = @import("std");
const c = @import("../../c.zig").c;
const cast = @import("../../util/cast.zig");
const input = @import("../input.zig");
const proto = @import("../../web/protocol.zig");
const reader_model = @import("../../web/reader.zig");
const webreader = @import("../webreader.zig");
const webstore = @import("../webstore.zig");
const wf_menus = @import("../webface/menus.zig");
const host_mod = @import("../webface.zig");
const WebFace = host_mod.WebFace;

// ---- find-in-page ----------------------------------------------

pub fn openFind(self: *WebFace) void {
    if (self.widgets_dead) return;
    c.gtk_widget_set_visible(self.find_bar, 1);
    _ = c.gtk_widget_grab_focus(self.find_entry);
}

pub fn closeFind(self: *WebFace) void {
    if (self.widgets_dead) return;
    c.gtk_widget_set_visible(self.find_bar, 0);
    c.gtk_label_set_text(@ptrCast(self.find_count), "");
    if (self.view_live)
        self.cl.post(proto.FindStop{ .view = self.view, .clear_selection = 1 });
    _ = c.gtk_widget_grab_focus(self.view_area);
}

/// The find entry's current text (borrowed from the widget).
pub fn findQuery(self: *WebFace) []const u8 {
    const t = c.gtk_editable_get_text(@ptrCast(self.find_entry)) orelse return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(t)));
}

/// A NEW search for the entry's text; an emptied entry ends the
/// search instead (matching every browser's find bar).
pub fn findStart(self: *WebFace) void {
    if (self.widgets_dead or !self.view_live) return;
    const q = self.findQuery();
    if (q.len == 0) {
        c.gtk_label_set_text(@ptrCast(self.find_count), "");
        self.cl.post(proto.FindStop{ .view = self.view, .clear_selection = 1 });
        return;
    }
    self.cl.post(proto.Find{
        .view = self.view,
        .forward = 1,
        .match_case = 0,
        .find_next = 0,
        .text = q,
    });
}

/// Step through the current search's matches.
pub fn findStep(self: *WebFace, forward: bool) void {
    if (self.widgets_dead or !self.view_live) return;
    const q = self.findQuery();
    if (q.len == 0) return;
    self.cl.post(proto.Find{
        .view = self.view,
        .forward = if (forward) 1 else 0,
        .match_case = 0,
        .find_next = 1,
        .text = q,
    });
}

pub fn onFindResult(self: *WebFace, ev: proto.EvFindResult) void {
    if (self.widgets_dead) return;
    if (c.gtk_widget_get_visible(self.find_bar) == 0) return;
    var buf: [64]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{d}/{d}", .{ ev.active, ev.count }) catch return;
    c.gtk_label_set_text(@ptrCast(self.find_count), z.ptr);
}

// ---- reader mode -------------------------------------------------

/// The `web_reader` action, the toolbar toggle and the context-menu
/// row all land here.
pub fn toggleReader(self: *WebFace) void {
    if (self.reader_active) self.exitReader() else self.requestReader();
}

/// Ask the page for its article. The answer arrives on the socket,
/// so this only starts the round trip; `onReadReply` finishes it.
pub fn requestReader(self: *WebFace) void {
    if (self.widgets_dead) return;
    self.syncReaderButton(true);
    if (!self.view_live) {
        self.toast("The page is not ready yet.");
        self.syncReaderButton(false);
        return;
    }
    // `autoRead` refuses a second read while one is in flight — an
    // MCP `web_read` on the same view, or an earlier press.
    self.reader_token = self.autoRead() orelse {
        self.toast("Still reading this page. Try again in a moment.");
        self.syncReaderButton(false);
        return;
    };
}

/// A `sem_read_result` landed. It is only OURS when its token is
/// the one this face is waiting on: an MCP `web_read` against the
/// same view produces the same frame and must not be stolen.
pub fn onReadReply(self: *WebFace) void {
    const token = self.reader_token orelse return;
    const res = self.autoTake(token) orelse return;
    defer self.allocator.free(res.text);
    self.reader_token = null;
    if (!res.ok) {
        self.toast("Could not read this page.");
        self.syncReaderButton(false);
        return;
    }
    if (self.cl.has(.reader_ids)) {
        const parsed = reader_model.parse(self.allocator, res.text) catch {
            self.toast("Could not read this page.");
            self.syncReaderButton(false);
            return;
        };
        defer parsed.deinit();
        self.enterReader(parsed.value.markdown);
    } else {
        self.enterReader(res.text);
    }
}

pub fn enterReader(self: *WebFace, md: []const u8) void {
    if (self.widgets_dead) return;
    if (self.reader == null) {
        const r = webreader.Reader.create(
            self.allocator,
            @ptrCast(self),
            &readerLinkCb,
            &readerKeyCb,
        ) orelse {
            self.toast("Could not open the reader view.");
            self.syncReaderButton(false);
            return;
        };
        c.gtk_widget_set_visible(r.widget(), 0);
        // Last overlay child = on top of the frame, the sensor and
        // the status box, and the only one of them that takes
        // input, so the page underneath sees nothing while it shows.
        c.gtk_overlay_add_overlay(@ptrCast(self.overlay), r.widget());
        self.reader = r;
    }
    const r = self.reader.?;
    if (!r.setMarkdown(md, self.url orelse "")) {
        self.toast("No article found on this page.");
        self.syncReaderButton(false);
        return;
    }
    c.gtk_widget_set_visible(r.widget(), 1);
    c.gtk_widget_set_visible(self.picture, 0);
    self.reader_active = true;
    self.syncReaderButton(true);
    r.focus();
}

/// Back to the page. Cheap by design — the view never stopped
/// living, so nothing is reloaded and no history entry was made.
/// Also the exit path for a navigation, which is why it must be a
/// no-op (and must NOT steal focus) when no reader is up.
pub fn exitReader(self: *WebFace) void {
    const was_pending = self.reader_token != null;
    if (self.reader_token) |token| {
        for (self.auto_ops.items, 0..) |op, i| {
            if (op.token != token) continue;
            const abandoned = self.auto_ops.orderedRemove(i);
            if (abandoned.request == 0)
                self.auto_legacy_quarantine.mark(@intFromEnum(abandoned.kind));
            break;
        }
    }
    self.reader_token = null;
    if (!self.reader_active) {
        if (was_pending) self.syncReaderButton(false);
        return;
    }
    self.reader_active = false;
    if (self.widgets_dead) return;
    if (self.reader) |r| c.gtk_widget_set_visible(r.widget(), 0);
    c.gtk_widget_set_visible(self.picture, 1);
    self.syncReaderButton(false);
    _ = c.gtk_widget_grab_focus(self.view_area);
}

pub fn syncReaderButton(self: *WebFace, on: bool) void {
    if (self.widgets_dead) return;
    self.reader_syncing = true;
    defer self.reader_syncing = false;
    c.gtk_toggle_button_set_active(@ptrCast(self.reader_btn), if (on) @as(c_int, 1) else 0);
}

pub fn toast(self: *WebFace, msg: []const u8) void {
    const win = self.ownerWindow() orelse return;
    @import("../window.zig").showToast(win, msg);
}

/// A link in the article: navigate the page underneath and leave
/// reader mode, which is what a reader's link click means
/// everywhere else too.
pub fn readerLinkCb(ctx: ?*anyopaque, url: []const u8) void {
    const self = cast.userData(WebFace, ctx);
    self.exitReader();
    self.navigate(url);
}

/// Keys the reader did not want. Escape leaves; everything else
/// gets the pane/window bindings, so a focused reader is no more of
/// a keyboard trap than a focused page.
pub fn readerKeyCb(ctx: ?*anyopaque, keyval: c.guint, state: c.GdkModifierType) bool {
    const self = cast.userData(WebFace, ctx);
    if (keyval == c.GDK_KEY_Escape) {
        self.exitReader();
        return true;
    }
    if (self.pane) |pane| {
        if (pane.input_ctx) |ictx| {
            if (input.fallbackToPaneBindings(ictx, keyval, state)) |handled| return handled != 0;
        }
    }
    return false;
}

pub fn onReaderToggled(btn: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(WebFace, user);
    if (self.reader_syncing) return;
    if (c.gtk_toggle_button_get_active(@ptrCast(btn)) != 0)
        self.requestReader()
    else
        self.exitReader();
}

pub fn onMenuReader(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(MenuCtx, user).face.toggleReader();
}

// ---- zoom -------------------------------------------------------

/// Zoom bounds in level x100: 1.2^-7 (~28%) to 1.2^8 (~430%),
/// Chromium's own preset range.
pub const zoom_min_x100: i32 = -700;
pub const zoom_max_x100: i32 = 800;

pub fn zoomStep(self: *WebFace, dir: i32) void {
    self.setZoomLevel(std.math.clamp(self.zoom_x100 + dir * 100, zoom_min_x100, zoom_max_x100));
}

pub fn zoomReset(self: *WebFace) void {
    self.setZoomLevel(0);
}

/// Chromium zoom levels are logarithmic: factor = 1.2^(level/100).
pub fn userZoomFactor(self: *const WebFace) f64 {
    if (self.zoom_x100 == 0) return 1.0;
    return std.math.pow(f64, 1.2, @as(f64, @floatFromInt(self.zoom_x100)) / 100.0);
}

pub fn setZoomLevel(self: *WebFace, level_x100: i32) void {
    if (level_x100 == self.zoom_x100) return;
    // A zoom rescales every hint rect; stale labels would lie.
    if (self.hints_active) self.cancelHints();
    self.zoom_x100 = level_x100;
    // A user-chosen zoom is a per-site setting: persist it on the
    // daemon so the origin comes back at this zoom (0 clears).
    if (self.storeOrigin()) |o| webstore.siteSetZoom(self.allocator, o, level_x100);
    if (!self.view_live) return;
    self.cl.post(proto.SetZoom{ .view = self.view, .level_x100 = level_x100 });
}

/// Face-local chords, tried after the window bindings and before
/// the page: Ctrl+F (find), Ctrl+=/-/0 (zoom), Ctrl+V/C/X.
///
/// A page never sees these — the same trade every browser makes.
/// The clipboard three MUST be claimed rather than forwarded: the
/// engine's own clipboard is empty here, so letting Ctrl+V reach
/// the page runs a real Paste of nothing, which REPLACES the
/// selection — select-all then paste would wipe the field. They
/// fall through when the helper is too old to answer, so an
/// unsupported helper degrades to the old behaviour instead of
/// silently eating the chord.
pub fn faceChord(self: *WebFace, keyval: c.guint, state: c.GdkModifierType) bool {
    const s: c_int = @intCast(state);
    if (s & c.GDK_CONTROL_MASK == 0 or s & c.GDK_ALT_MASK != 0) return false;
    switch (c.gdk_keyval_to_lower(keyval)) {
        c.GDK_KEY_f => self.openFind(),
        c.GDK_KEY_equal, c.GDK_KEY_plus, c.GDK_KEY_KP_Add => self.zoomStep(1),
        c.GDK_KEY_minus, c.GDK_KEY_KP_Subtract => self.zoomStep(-1),
        c.GDK_KEY_0, c.GDK_KEY_KP_0 => self.zoomReset(),
        c.GDK_KEY_v => return self.pasteFromClipboard(),
        c.GDK_KEY_c => return self.copyToClipboard(false),
        c.GDK_KEY_x => return self.copyToClipboard(true),
        else => return false,
    }
    return true;
}

pub const MenuCtx = wf_menus.MenuCtx;
pub const freeMenuCtx = wf_menus.freeMenuCtx;
pub const onContextMenu = wf_menus.onContextMenu;
pub const appendToolRows = wf_menus.appendToolRows;
pub const appendContainerRows = wf_menus.appendContainerRows;
pub const copyText = wf_menus.copyText;
pub const pasteFromClipboard = wf_menus.pasteFromClipboard;
pub const copyToClipboard = wf_menus.copyToClipboard;
pub const buildNavStrip = wf_menus.buildNavStrip;
pub const onBurger = wf_menus.onBurger;
pub const showBurgerMenu = wf_menus.showBurgerMenu;
pub const shellRowLabel = wf_menus.shellRowLabel;
