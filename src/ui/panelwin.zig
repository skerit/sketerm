//! The standalone panel window: an AdwApplicationWindow hosting a
//! `PanelView`, exactly the way ui/editorwin.zig hosts a paneless
//! EditorView. Composition, not a second renderer — every component,
//! every gesture and the event queue are the pane face's code.
//!
//! What the window adds: a header bar, a title driven by the
//! document's own title (through `view.on_changed`), and the teardown
//! ordering a toplevel needs. GtkWindow dispose destroys children
//! before emitting "destroy", so the view's STRUCT teardown is deferred
//! to the window's finalize (the qdata destroy-notify), after the
//! destroy storm has unwound — PickerWindow's shape, not ViewerWindow's.
//!
//! Ownership: the window owns the view and frees it at finalize. The
//! host (ui/panelhost.zig) is told at ::destroy via `on_closed`, which
//! is where it drops its registry entry — a panel whose window the user
//! closed must stop being addressable immediately, not at finalize.

const std = @import("std");
const c = @import("../c.zig").c;
const PanelView = @import("panel/view.zig").PanelView;
const canary = @import("panel/canary.zig");

const PANEL_QDATA = "sketerm-panel-window";

pub const APP_NAME = "Sketerm Panel";

pub const PanelWindow = struct {
    pub const MAGIC: u32 = 0x504E4C57; // "PNLW"
    /// Use-after-free DETECTOR, not a lifetime mechanism — see
    /// canary.zig. The window OWNS this struct through the qdata
    /// destroy-notify, which is what makes the raw `self` on the
    /// ::destroy connection sound; the canary only makes a future
    /// regression in that arrangement fail loudly and at once.
    magic: u32 = MAGIC,
    allocator: std.mem.Allocator,
    window: *c.GtkWidget,
    view: *PanelView,
    /// Fired once from ::destroy so the host can forget this panel.
    on_closed: ?*const fn (ctx: *anyopaque) void = null,
    closed_ctx: ?*anyopaque = null,
    destroyed: bool = false,
    title_buf: [512:0]u8 = undefined,

    /// Wrap `view` (already carrying its document) in a toplevel and
    /// present it. The window takes ownership of the view.
    pub fn open(
        allocator: std.mem.Allocator,
        app: ?*c.GtkApplication,
        view: *PanelView,
    ) !*PanelWindow {
        const self = try allocator.create(PanelWindow);
        errdefer allocator.destroy(self);
        const window = c.adw_application_window_new(app) orelse return error.OutOfMemory;
        errdefer c.gtk_window_destroy(@ptrCast(window));

        self.* = .{ .allocator = allocator, .window = window, .view = view };

        c.gtk_window_set_default_size(@ptrCast(window), 900, 680);
        const toolbar = c.adw_toolbar_view_new().?;
        const header = c.adw_header_bar_new().?;
        c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar), header);
        c.gtk_widget_set_vexpand(view.root_box, 1);
        c.adw_toolbar_view_set_content(@ptrCast(toolbar), view.root_box);
        c.adw_application_window_set_content(@ptrCast(window), toolbar);

        view.on_changed = &onViewChanged;
        view.changed_ctx = @ptrCast(self);
        self.syncTitle();

        // Self-ownership, the EditorWindow way: the notify runs at
        // window FINALIZE, i.e. once the destroy has fully unwound and
        // still inside the main loop.
        c.g_object_set_data_full(@ptrCast(window), PANEL_QDATA, @ptrCast(self), @ptrCast(&finalizePanelWindow));
        _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onWindowDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        c.gtk_window_present(@ptrCast(window));
        view.focusFace();
        return self;
    }

    /// Raise an existing panel window (a repeated panel-show on the
    /// same name).
    pub fn present(self: *PanelWindow) void {
        if (self.destroyed) return;
        c.gtk_window_present(@ptrCast(self.window));
        self.view.focusFace();
    }

    /// Close from the host side (panel-close). The rest of teardown
    /// runs through ::destroy / finalize as if the user had closed it.
    pub fn close(self: *PanelWindow) void {
        if (self.destroyed) return;
        c.gtk_window_destroy(@ptrCast(self.window));
    }

    /// The document's title, else the app name. Called from the view
    /// whenever setDocument or a title patch lands.
    fn onViewChanged(ctx: *anyopaque) void {
        const self = canary.live(PanelWindow, ctx) orelse return;
        self.syncTitle();
    }

    fn syncTitle(self: *PanelWindow) void {
        if (self.destroyed) return;
        const doc_title = self.view.title();
        const text = if (doc_title.len > 0)
            std.fmt.bufPrintZ(&self.title_buf, "{s} - {s}", .{ doc_title, APP_NAME }) catch APP_NAME
        else
            APP_NAME;
        c.gtk_window_set_title(@ptrCast(self.window), text.ptr);
    }

    fn onWindowDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = canary.live(PanelWindow, user) orelse return;
        if (self.destroyed) return;
        self.destroyed = true;
        // Phase 1 of the face's two-phase teardown: fences every
        // further widget access and unblocks anyone waiting on the
        // event queue. The widget subtree is going away with the
        // window, so it is dead as far as the view is concerned.
        self.view.prepareDestroy(true);
        if (self.on_closed) |cb| {
            if (self.closed_ctx) |ctx| cb(ctx);
        }
        self.on_closed = null;
        self.closed_ctx = null;
    }

    fn finalizePanelWindow(user: ?*anyopaque) callconv(.c) void {
        const self = canary.live(PanelWindow, user) orelse return;
        self.view.deinit();
        canary.poison(self);
        self.allocator.destroy(self);
    }
};

test "a poisoned PanelWindow makes finalize bail instead of double-freeing" {
    const a = std.testing.allocator;
    const self = try a.create(PanelWindow);
    // `view` and `window` are never reached: the guard is the first
    // statement, so this stands in for "the window finalized twice".
    self.* = .{ .allocator = a, .window = undefined, .view = undefined };
    canary.poison(self);

    const before = canary.trips;
    PanelWindow.finalizePanelWindow(@ptrCast(self));
    try std.testing.expectEqual(before + 1, canary.trips);
    // A double free here would be reported by the testing allocator.
    a.destroy(self);
}

test "a poisoned PanelWindow does not run the ::destroy handler" {
    var self = PanelWindow{ .allocator = std.testing.allocator, .window = undefined, .view = undefined };
    canary.poison(&self);
    const before = canary.trips;
    PanelWindow.onWindowDestroy(undefined, @ptrCast(&self));
    try std.testing.expectEqual(before + 1, canary.trips);
    try std.testing.expect(!self.destroyed);
}

test "panel window decls type-check" {
    // Lazy analysis: without this, a signature error in a callback no
    // test calls would slip through the build.
    std.testing.refAllDecls(PanelWindow);
}
