//! Shared GTK image canvas and texture-publishing session.

const std = @import("std");
const c = @import("../c.zig").c;
const Viewport = @import("../viewer.zig").Viewport;

pub const Canvas = struct {
    root: *c.GtkWidget,
    picture: *c.GtkWidget,
    scroller: *c.GtkScrolledWindow,
    viewport: Viewport = .{},
    image_width: u32 = 0,
    image_height: u32 = 0,
    drag_x: f64 = 0,
    drag_y: f64 = 0,
    on_zoom: ?*const fn (?*anyopaque, f64, bool) void = null,
    zoom_ctx: ?*anyopaque = null,

    pub fn init() Canvas {
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_scrolled_window_set_policy(@ptrCast(scroll), c.GTK_POLICY_AUTOMATIC, c.GTK_POLICY_AUTOMATIC);
        c.gtk_widget_set_hexpand(scroll, 1);
        c.gtk_widget_set_vexpand(scroll, 1);
        c.gtk_widget_add_css_class(scroll, "sketerm-image-canvas");
        const picture = c.gtk_picture_new().?;
        c.gtk_picture_set_content_fit(@ptrCast(picture), c.GTK_CONTENT_FIT_CONTAIN);
        c.gtk_picture_set_can_shrink(@ptrCast(picture), 1);
        c.gtk_widget_add_css_class(picture, "sketerm-image-picture");
        c.gtk_widget_set_hexpand(picture, 1);
        c.gtk_widget_set_vexpand(picture, 1);
        c.gtk_scrolled_window_set_child(@ptrCast(scroll), picture);
        installCss(scroll);
        return .{ .root = scroll, .picture = picture, .scroller = @ptrCast(@alignCast(scroll)) };
    }

    /// Install controllers after the Canvas has reached its stable address.
    pub fn enableInput(self: *Canvas) void {
        const zoom = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
        c.gtk_event_controller_set_propagation_phase(@ptrCast(zoom), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(zoom, "scroll", @ptrCast(&onScroll), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(self.root, @ptrCast(zoom));

        const drag = c.gtk_gesture_drag_new();
        c.gtk_gesture_single_set_button(@ptrCast(drag), 1);
        _ = c.g_signal_connect_data(drag, "drag-begin", @ptrCast(&onDragBegin), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(drag, "drag-update", @ptrCast(&onDragUpdate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(self.picture, @ptrCast(drag));
    }

    pub fn widget(self: *Canvas) *c.GtkWidget {
        return self.root;
    }

    pub fn setTexture(self: *Canvas, texture: ?*c.GdkTexture) void {
        c.gtk_picture_set_paintable(@ptrCast(self.picture), @ptrCast(texture));
        if (texture) |tex| {
            self.image_width = @intCast(c.gdk_texture_get_width(tex));
            self.image_height = @intCast(c.gdk_texture_get_height(tex));
        } else {
            self.image_width = 0;
            self.image_height = 0;
        }
        self.applyViewport();
    }

    pub fn fit(self: *Canvas) void {
        self.viewport.useFit();
        self.applyViewport();
        self.notifyZoom();
    }

    pub fn actual(self: *Canvas) void {
        self.viewport.actual();
        self.applyViewport();
        self.notifyZoom();
    }

    pub fn zoomBy(self: *Canvas, factor: f64) void {
        const old = self.viewport.zoom;
        const hadj = c.gtk_scrolled_window_get_hadjustment(self.scroller);
        const vadj = c.gtk_scrolled_window_get_vadjustment(self.scroller);
        const hx = c.gtk_adjustment_get_page_size(hadj) / 2;
        const vy = c.gtk_adjustment_get_page_size(vadj) / 2;
        const old_h = c.gtk_adjustment_get_value(hadj);
        const old_v = c.gtk_adjustment_get_value(vadj);
        self.viewport.scaleBy(factor);
        self.applyViewport();
        c.gtk_adjustment_set_value(hadj, Viewport.anchoredScroll(old_h, hx, old, self.viewport.zoom));
        c.gtk_adjustment_set_value(vadj, Viewport.anchoredScroll(old_v, vy, old, self.viewport.zoom));
        self.notifyZoom();
    }

    fn applyViewport(self: *Canvas) void {
        if (self.viewport.fit or self.image_width == 0 or self.image_height == 0) {
            c.gtk_widget_set_size_request(self.picture, -1, -1);
            c.gtk_widget_set_hexpand(self.picture, 1);
            c.gtk_widget_set_vexpand(self.picture, 1);
            c.gtk_widget_set_halign(self.picture, c.GTK_ALIGN_FILL);
            c.gtk_widget_set_valign(self.picture, c.GTK_ALIGN_FILL);
            c.gtk_picture_set_can_shrink(@ptrCast(self.picture), 1);
            return;
        }
        const width: c_int = @intFromFloat(@max(1, @as(f64, @floatFromInt(self.image_width)) * self.viewport.zoom));
        const height: c_int = @intFromFloat(@max(1, @as(f64, @floatFromInt(self.image_height)) * self.viewport.zoom));
        c.gtk_widget_set_hexpand(self.picture, 0);
        c.gtk_widget_set_vexpand(self.picture, 0);
        c.gtk_widget_set_halign(self.picture, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_valign(self.picture, c.GTK_ALIGN_CENTER);
        c.gtk_picture_set_can_shrink(@ptrCast(self.picture), 0);
        c.gtk_widget_set_size_request(self.picture, width, height);
    }

    fn notifyZoom(self: *Canvas) void {
        if (self.on_zoom) |callback| callback(self.zoom_ctx, self.viewport.zoom, self.viewport.fit);
    }

    fn onScroll(controller: *c.GtkEventControllerScroll, _: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Canvas = @ptrCast(@alignCast(user.?));
        const state = c.gtk_event_controller_get_current_event_state(@ptrCast(controller));
        if (state & c.GDK_CONTROL_MASK == 0) return 0;
        if (dy != 0) self.zoomBy(if (dy < 0) 1.2 else 1.0 / 1.2);
        return 1;
    }

    fn onDragBegin(_: *c.GtkGestureDrag, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const self: *Canvas = @ptrCast(@alignCast(user.?));
        self.drag_x = c.gtk_adjustment_get_value(c.gtk_scrolled_window_get_hadjustment(self.scroller));
        self.drag_y = c.gtk_adjustment_get_value(c.gtk_scrolled_window_get_vadjustment(self.scroller));
    }

    fn onDragUpdate(_: *c.GtkGestureDrag, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) void {
        const self: *Canvas = @ptrCast(@alignCast(user.?));
        if (self.viewport.fit) return;
        c.gtk_adjustment_set_value(c.gtk_scrolled_window_get_hadjustment(self.scroller), self.drag_x - dx);
        c.gtk_adjustment_set_value(c.gtk_scrolled_window_get_vadjustment(self.scroller), self.drag_y - dy);
    }
};

var css_installed = false;

fn installCss(widget: *c.GtkWidget) void {
    if (css_installed) return;
    css_installed = true;
    const provider = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(provider,
        \\scrolledwindow.sketerm-image-canvas,
        \\scrolledwindow.sketerm-image-canvas > viewport {
        \\  background: #17151b;
        \\}
        \\picture.sketerm-image-picture {
        \\  background: #17151b;
        \\}
    );
    const display = c.gtk_widget_get_display(widget);
    c.gtk_style_context_add_provider_for_display(display, @ptrCast(@alignCast(provider)), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    c.g_object_unref(@ptrCast(provider));
}

pub const Session = struct {
    canvases: std.ArrayList(*Canvas) = .empty,
    texture: ?*c.GdkTexture = null,

    pub fn attach(self: *Session, allocator: std.mem.Allocator, canvas: *Canvas) !void {
        for (self.canvases.items) |existing| if (existing == canvas) return;
        try self.canvases.append(allocator, canvas);
        canvas.setTexture(self.texture);
    }

    pub fn detach(self: *Session, canvas: *Canvas) void {
        for (self.canvases.items, 0..) |existing, index| {
            if (existing == canvas) {
                _ = self.canvases.swapRemove(index);
                return;
            }
        }
    }

    pub fn setTexture(self: *Session, texture: ?*c.GdkTexture) void {
        if (texture) |tex| _ = c.g_object_ref(@ptrCast(tex));
        const old = self.texture;
        self.texture = texture;
        for (self.canvases.items) |canvas| canvas.setTexture(texture);
        if (old) |tex| c.g_object_unref(@ptrCast(tex));
    }

    pub fn clear(self: *Session) void {
        self.setTexture(null);
    }

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        if (self.texture) |texture| c.g_object_unref(@ptrCast(texture));
        self.texture = null;
        self.canvases.deinit(allocator);
    }
};
