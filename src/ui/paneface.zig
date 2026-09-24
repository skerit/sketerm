//! The non-terminal faces a Pane can wear — file browser, editor,
//! panel, web — as data. Each face is a widget in the pane's wrapper
//! box plus the same five-pointer ownership contract; they used to be
//! twenty flat `<face>_widget` / `_ctx` / `_prepare_destroy` /
//! `_deinit` / `_focus` fields on Pane, with the attach, detach and
//! hide-the-others code copied four times.
//!
//! Teardown order is the contract (see CLAUDE.md, `severFaces`): the
//! pane forgets the face FIRST (`Slot.take`) so widget-destruction
//! signals cannot re-enter and detach it again, then `prepare_destroy`
//! runs, then the widget leaves the wrapper box (only while the widget
//! tree is alive), and only then `deinit` frees the face's state —
//! unparenting synchronously emits signals the face still answers.

const c = @import("../c.zig").c;

pub const Kind = enum {
    /// File browser (src/ui/browser.zig); its fd watch must never
    /// outlive the pane.
    browser,
    /// Text editor (src/ui/editorview.zig).
    editor,
    /// A declarative document an assistant authored, rendered as real
    /// widgets (src/ui/panel/view.zig, hosted by ui/panelhost.zig).
    panel,
    /// A browser view rendered from the `sketerm-webengine` helper
    /// (src/ui/webface.zig). Its ctx is the web GROUP, not a face.
    web,
};

/// One face riding a pane. `prepare_destroy` is told whether the
/// pane's widgets are already finalized (`Pane.widgets_dead`): the
/// ordinary path (severFaces) calls it with the widgets up, the
/// last-resort call from `Pane.deinit` after GTK finalized them.
/// Passing it is not optional -- the editor face restores window-level
/// shortcuts through its root widget, a use-after-free on the late path.
pub const Slot = struct {
    widget: ?*c.GtkWidget = null,
    ctx: ?*anyopaque = null,
    prepare_destroy: ?*const fn (*anyopaque, widgets_dead: bool) void = null,
    deinit: ?*const fn (*anyopaque) void = null,
    /// Put GTK focus inside the face. Called whenever it becomes the
    /// visible one.
    focus: ?*const fn (*anyopaque) void = null,

    pub fn present(self: *const Slot) bool {
        return self.widget != null;
    }

    pub fn visible(self: *const Slot) bool {
        const w = self.widget orelse return false;
        return c.gtk_widget_get_visible(w) != 0;
    }

    pub fn hide(self: *const Slot) void {
        if (self.widget) |w| c.gtk_widget_set_visible(w, 0);
    }

    pub fn grabFocus(self: *const Slot) void {
        if (self.focus) |f| {
            if (self.ctx) |ctx| f(ctx);
        }
    }

    /// Adopt `face` into the pane's wrapper box. The caller has
    /// detached any previous occupant of this slot.
    pub fn install(
        self: *Slot,
        wrap: *c.GtkWidget,
        face: *c.GtkWidget,
        ctx: *anyopaque,
        prepare_destroy_cb: *const fn (*anyopaque, widgets_dead: bool) void,
        deinit_cb: *const fn (*anyopaque) void,
        focus_cb: *const fn (*anyopaque) void,
    ) void {
        self.* = .{
            .widget = face,
            .ctx = ctx,
            .prepare_destroy = prepare_destroy_cb,
            .deinit = deinit_cb,
            .focus = focus_cb,
        };
        c.gtk_widget_set_vexpand(face, 1);
        c.gtk_widget_set_hexpand(face, 1);
        c.gtk_box_append(@ptrCast(wrap), face);
    }

    /// Clear pane ownership and hand back what was there, so the
    /// destruction chain `teardown` starts cannot re-enter through the
    /// pane and detach the same face again.
    pub fn take(self: *Slot) Slot {
        const old = self.*;
        self.* = .{};
        return old;
    }

    /// Two-phase teardown of a slot `take` returned: prepare, unparent
    /// (only while the widgets live; after the widget tree's destroy
    /// GTK already removed everything itself), then free.
    pub fn teardown(old: Slot, widgets_dead: bool, wrap: ?*c.GtkWidget, offload: ?*c.GtkWidget) void {
        if (old.ctx) |ctx| {
            if (old.prepare_destroy) |cb| cb(ctx, widgets_dead);
        }
        if (old.widget) |w| {
            if (!widgets_dead) {
                if (wrap) |box| c.gtk_box_remove(@ptrCast(box), w);
                if (offload) |ow| c.gtk_widget_set_visible(ow, 1);
            }
        }
        if (old.ctx) |ctx| {
            if (old.deinit) |cb| cb(ctx);
        }
    }
};

/// Every face slot of one pane. Faces are exclusive: raising one hides
/// the others (`hideAllBut`).
pub const Faces = struct {
    browser: Slot = .{},
    editor: Slot = .{},
    panel: Slot = .{},
    web: Slot = .{},

    pub fn slot(self: *Faces, kind: Kind) *Slot {
        return switch (kind) {
            .browser => &self.browser,
            .editor => &self.editor,
            .panel => &self.panel,
            .web => &self.web,
        };
    }

    pub fn hideAllBut(self: *const Faces, keep: Kind) void {
        if (keep != .browser) self.browser.hide();
        if (keep != .editor) self.editor.hide();
        if (keep != .panel) self.panel.hide();
        if (keep != .web) self.web.hide();
    }
};
