//! Standalone asciicast playback window (`sketerm play <file.cast>`).
//!
//! A CastView is a window shell around the shared CastPlayerBox
//! (`castbox.zig`), which owns the Terminal, the fixed_grid
//! TerminalSurface, the transport bar and the ephemeral-session
//! lifecycle. This file adds only the window, its title, and the
//! standalone key bindings (Space, Left/Right seek, R, Q/Escape).

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const castbox = @import("castbox.zig");

const CAST_QDATA = "sketerm-cast-view";

pub const CastView = struct {
    allocator: std.mem.Allocator,
    window: *c.GtkWidget,
    box: *castbox.CastPlayerBox,
    /// True once severLive ran (window destroyed); makes it idempotent.
    severed: bool = false,

    /// Spawn a cast-playback session for `spec` (local path or
    /// host:/path) and open a playback window on it. Prints a readable
    /// reason to stderr on every failure path.
    pub fn open(allocator: std.mem.Allocator, app: ?*c.GtkApplication, spec: []const u8) !*CastView {
        const self = try allocator.create(CastView);
        errdefer allocator.destroy(self);

        const window = c.adw_application_window_new(app) orelse return error.OutOfMemory;
        errdefer c.gtk_window_destroy(@ptrCast(window));
        c.gtk_window_set_default_size(@ptrCast(window), 960, 640);
        self.* = .{
            .allocator = allocator,
            .window = window,
            .box = undefined,
        };

        // The title callback fires during create (initial title), so
        // self.window must already be set — it is, just above.
        const box = try castbox.CastPlayerBox.create(allocator, spec, "sketerm play", .{
            .ctx = @ptrCast(self),
            .on_title = &onBoxTitle,
        });
        self.box = box;
        c.gtk_widget_set_tooltip_text(box.playbar.scale, "Seek (Left/Right: 5s, Shift: 30s)");

        const toolbar = c.adw_toolbar_view_new().?;
        const header = c.adw_header_bar_new().?;
        c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar), header);
        c.adw_toolbar_view_add_bottom_bar(@ptrCast(toolbar), box.barWidget());
        c.adw_toolbar_view_set_content(@ptrCast(toolbar), box.surfaceWidget());
        c.adw_application_window_set_content(@ptrCast(window), toolbar);

        c.g_object_set_data_full(@ptrCast(window), CAST_QDATA, @ptrCast(self), @ptrCast(&destroyView));
        // Surface timers and terminal sinks reach into widgets; fence
        // them the moment the window starts dying, not at finalize.
        _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onWindowDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        const keys = c.gtk_event_controller_key_new();
        c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(window, @ptrCast(keys));

        c.gtk_window_present(@ptrCast(window));
        return self;
    }

    fn severLive(self: *CastView) void {
        if (self.severed) return;
        self.severed = true;
        self.box.severLive();
    }

    /// GDestroyNotify at window finalize: free the view and kill the
    /// ephemeral session (the box's Terminal.deinit sends the kill).
    fn destroyView(user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(CastView, user);
        self.severLive();
        self.box.destroy();
        self.allocator.destroy(self);
    }

    fn onWindowDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(CastView, user);
        self.severLive();
    }

    fn onBoxTitle(user: ?*anyopaque, name: []const u8) void {
        const self = cast.userData(CastView, user);
        var buf: [512:0]u8 = undefined;
        const t = std.fmt.bufPrintZ(&buf, "{s} - Sketerm Play", .{name}) catch "Sketerm Play";
        c.gtk_window_set_title(@ptrCast(self.window), t.ptr);
    }

    fn onKey(
        _: *c.GtkEventControllerKey,
        keyval: c.guint,
        _: c.guint,
        state: c.GdkModifierType,
        user: ?*anyopaque,
    ) callconv(.c) c.gboolean {
        const self = cast.userData(CastView, user);
        const shift = (state & c.GDK_SHIFT_MASK) != 0;
        const step: i64 = if (shift) 30_000 else 5_000;
        switch (keyval) {
            c.GDK_KEY_space => self.box.togglePlay(),
            c.GDK_KEY_Left => self.box.seekRelative(-step),
            c.GDK_KEY_Right => self.box.seekRelative(step),
            c.GDK_KEY_r, c.GDK_KEY_R => self.box.restart(),
            c.GDK_KEY_q, c.GDK_KEY_Escape => c.gtk_window_close(@ptrCast(self.window)),
            else => return 0,
        }
        return 1;
    }
};
