//! Shared GTK image canvas and texture-publishing session.

const std = @import("std");
const c = @import("../c.zig").c;
const Viewport = @import("../viewer.zig").Viewport;
const decoder = @import("image_decoder.zig");

pub const Canvas = struct {
    root: *c.GtkWidget,
    picture: *c.GtkWidget,
    scroller: *c.GtkScrolledWindow,
    viewport: Viewport = .{},
    image_width: u32 = 0,
    image_height: u32 = 0,
    drag_x: f64 = 0,
    drag_y: f64 = 0,
    pinch_scale: f64 = 1,
    rotate_angle: f64 = 0,
    accessible_detail: [512]u8 = @splat(0),
    accessible_detail_len: usize = 0,
    on_zoom: ?*const fn (?*anyopaque, f64, Viewport.Mode) void = null,
    zoom_ctx: ?*anyopaque = null,
    on_navigate: ?*const fn (?*anyopaque, isize) void = null,
    navigate_ctx: ?*anyopaque = null,
    on_rotate: ?*const fn (?*anyopaque, i8) void = null,
    rotate_ctx: ?*anyopaque = null,

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

        const pinch = c.gtk_gesture_zoom_new();
        c.gtk_event_controller_set_propagation_phase(@ptrCast(pinch), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(pinch, "begin", @ptrCast(&onPinchBegin), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(pinch, "scale-changed", @ptrCast(&onPinchScale), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(self.root, @ptrCast(pinch));

        const rotate = c.gtk_gesture_rotate_new();
        c.gtk_event_controller_set_propagation_phase(@ptrCast(rotate), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(rotate, "begin", @ptrCast(&onRotateBegin), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(rotate, "angle-changed", @ptrCast(&onRotateAngle), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(rotate, "end", @ptrCast(&onRotateEnd), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(self.root, @ptrCast(rotate));

        const swipe = c.gtk_gesture_swipe_new();
        c.gtk_event_controller_set_propagation_phase(@ptrCast(swipe), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(swipe, "swipe", @ptrCast(&onSwipe), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(self.root, @ptrCast(swipe));
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

    pub fn fill(self: *Canvas) void {
        self.viewport.useFill();
        self.applyViewport();
        self.notifyZoom();
    }

    pub fn actual(self: *Canvas) void {
        self.viewport.actual();
        self.applyViewport();
        self.notifyZoom();
    }

    pub fn zoomBy(self: *Canvas, factor: f64) void {
        const hadj = c.gtk_scrolled_window_get_hadjustment(self.scroller);
        const vadj = c.gtk_scrolled_window_get_vadjustment(self.scroller);
        const hx = c.gtk_adjustment_get_page_size(hadj) / 2;
        const vy = c.gtk_adjustment_get_page_size(vadj) / 2;
        self.zoomAt(factor, hx, vy);
    }

    pub fn zoomAt(self: *Canvas, factor: f64, anchor_x: f64, anchor_y: f64) void {
        const hadj = c.gtk_scrolled_window_get_hadjustment(self.scroller);
        const vadj = c.gtk_scrolled_window_get_vadjustment(self.scroller);
        const page_w = c.gtk_adjustment_get_page_size(hadj);
        const page_h = c.gtk_adjustment_get_page_size(vadj);
        const hx = std.math.clamp(anchor_x, 0, @max(page_w, 0));
        const vy = std.math.clamp(anchor_y, 0, @max(page_h, 0));
        const old = self.viewport.effectiveScale(
            page_w,
            page_h,
            @floatFromInt(self.image_width),
            @floatFromInt(self.image_height),
        );
        const old_h = c.gtk_adjustment_get_value(hadj);
        const old_v = c.gtk_adjustment_get_value(vadj);
        self.viewport.setManual(old * factor);
        self.applyViewport();
        c.gtk_adjustment_set_value(hadj, Viewport.anchoredScroll(old_h, hx, old, self.viewport.zoom));
        c.gtk_adjustment_set_value(vadj, Viewport.anchoredScroll(old_v, vy, old, self.viewport.zoom));
        self.notifyZoom();
    }

    fn applyViewport(self: *Canvas) void {
        if (self.viewport.mode == .fit or self.viewport.mode == .fill or self.image_width == 0 or self.image_height == 0) {
            c.gtk_picture_set_content_fit(@ptrCast(self.picture), if (self.viewport.mode == .fill) c.GTK_CONTENT_FIT_COVER else c.GTK_CONTENT_FIT_CONTAIN);
            c.gtk_widget_set_size_request(self.picture, -1, -1);
            c.gtk_widget_set_hexpand(self.picture, 1);
            c.gtk_widget_set_vexpand(self.picture, 1);
            c.gtk_widget_set_halign(self.picture, c.GTK_ALIGN_FILL);
            c.gtk_widget_set_valign(self.picture, c.GTK_ALIGN_FILL);
            c.gtk_picture_set_can_shrink(@ptrCast(self.picture), 1);
            return;
        }
        c.gtk_picture_set_content_fit(@ptrCast(self.picture), c.GTK_CONTENT_FIT_CONTAIN);
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
        if (self.on_zoom) |callback| callback(self.zoom_ctx, self.viewport.zoom, self.viewport.mode);
        self.updateAccessibleDescription(null);
    }

    pub fn setAccessible(self: *Canvas, label: []const u8, detail: ?[]const u8, busy: bool) void {
        var label_buf: [512:0]u8 = undefined;
        const label_z = std.fmt.bufPrintZ(&label_buf, "{s}", .{label}) catch "Image";
        c.gtk_accessible_update_property(@ptrCast(self.picture), c.GTK_ACCESSIBLE_PROPERTY_LABEL, label_z.ptr, @as(c_int, -1));
        self.updateAccessibleDescription(detail);
        c.gtk_accessible_update_state(@ptrCast(self.picture), c.GTK_ACCESSIBLE_STATE_BUSY, @as(c.gboolean, @intFromBool(busy)), @as(c_int, -1));
    }

    fn updateAccessibleDescription(self: *Canvas, detail: ?[]const u8) void {
        if (detail) |value| {
            self.accessible_detail_len = @min(value.len, self.accessible_detail.len);
            @memcpy(self.accessible_detail[0..self.accessible_detail_len], value[0..self.accessible_detail_len]);
        }
        const semantic = self.accessible_detail[0..self.accessible_detail_len];
        var buf: [768:0]u8 = undefined;
        const mode = switch (self.viewport.mode) {
            .fit => "fit to window",
            .fill => "fill window",
            .actual => "actual size",
            .manual => "manual zoom",
        };
        const hadj = c.gtk_scrolled_window_get_hadjustment(self.scroller);
        const vadj = c.gtk_scrolled_window_get_vadjustment(self.scroller);
        const effective = self.viewport.effectiveScale(
            c.gtk_adjustment_get_page_size(hadj),
            c.gtk_adjustment_get_page_size(vadj),
            @floatFromInt(self.image_width),
            @floatFromInt(self.image_height),
        );
        const text = if (semantic.len > 0)
            std.fmt.bufPrintZ(&buf, "{s}; {d} by {d} pixels; {s}; {d}%", .{
                semantic,
                self.image_width,
                self.image_height,
                mode,
                @as(u32, @intFromFloat(@round(effective * 100))),
            }) catch mode
        else
            std.fmt.bufPrintZ(&buf, "{d} by {d} pixels; {s}; {d}%", .{
                self.image_width,
                self.image_height,
                mode,
                @as(u32, @intFromFloat(@round(effective * 100))),
            }) catch mode;
        c.gtk_accessible_update_property(@ptrCast(self.picture), c.GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, text.ptr, @as(c_int, -1));
    }

    fn onScroll(controller: *c.GtkEventControllerScroll, _: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Canvas = @ptrCast(@alignCast(user.?));
        const state = c.gtk_event_controller_get_current_event_state(@ptrCast(controller));
        if (state & c.GDK_CONTROL_MASK == 0) return 0;
        if (dy != 0) {
            var x = c.gtk_adjustment_get_page_size(c.gtk_scrolled_window_get_hadjustment(self.scroller)) / 2;
            var y = c.gtk_adjustment_get_page_size(c.gtk_scrolled_window_get_vadjustment(self.scroller)) / 2;
            if (c.gtk_event_controller_get_current_event(@ptrCast(controller))) |event| {
                var root_x: f64 = 0;
                var root_y: f64 = 0;
                if (c.gdk_event_get_position(event, &root_x, &root_y) != 0) {
                    if (c.gtk_widget_get_root(self.root)) |root| {
                        const input = c.graphene_point_t{ .x = @floatCast(root_x), .y = @floatCast(root_y) };
                        var output: c.graphene_point_t = undefined;
                        if (c.gtk_widget_compute_point(@ptrCast(@alignCast(root)), self.root, &input, &output) != 0) {
                            x = output.x;
                            y = output.y;
                        }
                    }
                }
            }
            self.zoomAt(if (dy < 0) 1.2 else 1.0 / 1.2, x, y);
        }
        return 1;
    }

    fn onDragBegin(_: *c.GtkGestureDrag, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const self: *Canvas = @ptrCast(@alignCast(user.?));
        self.drag_x = c.gtk_adjustment_get_value(c.gtk_scrolled_window_get_hadjustment(self.scroller));
        self.drag_y = c.gtk_adjustment_get_value(c.gtk_scrolled_window_get_vadjustment(self.scroller));
    }

    fn onDragUpdate(_: *c.GtkGestureDrag, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) void {
        const self: *Canvas = @ptrCast(@alignCast(user.?));
        if (self.viewport.mode == .fit or self.viewport.mode == .fill) return;
        c.gtk_adjustment_set_value(c.gtk_scrolled_window_get_hadjustment(self.scroller), self.drag_x - dx);
        c.gtk_adjustment_set_value(c.gtk_scrolled_window_get_vadjustment(self.scroller), self.drag_y - dy);
    }

    fn onPinchBegin(_: *c.GtkGesture, _: ?*c.GdkEventSequence, user: ?*anyopaque) callconv(.c) void {
        const self: *Canvas = @ptrCast(@alignCast(user.?));
        self.pinch_scale = 1;
    }

    fn onPinchScale(gesture: *c.GtkGestureZoom, scale: f64, user: ?*anyopaque) callconv(.c) void {
        const self: *Canvas = @ptrCast(@alignCast(user.?));
        if (scale <= 0 or self.pinch_scale <= 0) return;
        var x: f64 = 0;
        var y: f64 = 0;
        if (c.gtk_gesture_get_bounding_box_center(@ptrCast(gesture), &x, &y) == 0) return;
        self.zoomAt(scale / self.pinch_scale, x, y);
        self.pinch_scale = scale;
    }

    fn onRotateBegin(_: *c.GtkGesture, _: ?*c.GdkEventSequence, user: ?*anyopaque) callconv(.c) void {
        const self: *Canvas = @ptrCast(@alignCast(user.?));
        self.rotate_angle = 0;
    }

    fn onRotateAngle(_: *c.GtkGestureRotate, _: f64, angle_delta: f64, user: ?*anyopaque) callconv(.c) void {
        const self: *Canvas = @ptrCast(@alignCast(user.?));
        self.rotate_angle = angle_delta;
    }

    fn onRotateEnd(_: *c.GtkGesture, _: ?*c.GdkEventSequence, user: ?*anyopaque) callconv(.c) void {
        const self: *Canvas = @ptrCast(@alignCast(user.?));
        if (@abs(self.rotate_angle) < @as(f64, std.math.pi) / 4.0) return;
        if (self.on_rotate) |callback| callback(self.rotate_ctx, if (self.rotate_angle > 0) 1 else -1);
    }

    fn onSwipe(_: *c.GtkGestureSwipe, velocity_x: f64, velocity_y: f64, user: ?*anyopaque) callconv(.c) void {
        const self: *Canvas = @ptrCast(@alignCast(user.?));
        if (@abs(velocity_x) < 300 or @abs(velocity_x) <= @abs(velocity_y)) return;
        if (self.on_navigate) |callback| callback(self.navigate_ctx, if (velocity_x < 0) 1 else -1);
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
    const AnimationFrame = struct {
        texture: *c.GdkTexture,
        rotated: ?*c.GdkTexture = null,
        delay_ms: u32,
    };

    canvases: std.ArrayList(*Canvas) = .empty,
    frames: std.ArrayList(AnimationFrame) = .empty,
    allocator: ?std.mem.Allocator = null,
    frame_index: usize = 0,
    timer: c.guint = 0,
    next_deadline_us: i64 = 0,
    playing: bool = true,
    plays: u32 = 1,
    completed_plays: u32 = 0,
    quarter_turns: u2 = 0,
    on_playback: ?*const fn (?*anyopaque) void = null,
    playback_ctx: ?*anyopaque = null,

    pub fn attach(self: *Session, allocator: std.mem.Allocator, canvas: *Canvas) !void {
        self.allocator = allocator;
        for (self.canvases.items) |existing| if (existing == canvas) return;
        try self.canvases.append(allocator, canvas);
        canvas.setTexture(self.currentTexture());
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
        self.clearFrames();
        const tex = texture orelse return;
        _ = c.g_object_ref(@ptrCast(tex));
        self.frames.append(self.allocator orelse std.heap.c_allocator, .{ .texture = tex, .delay_ms = 0 }) catch {
            c.g_object_unref(@ptrCast(tex));
            return;
        };
        self.publishCurrent();
    }

    pub fn setDecoded(self: *Session, allocator: std.mem.Allocator, image: *const decoder.Decoded) !void {
        self.allocator = allocator;
        self.clearFrames();
        errdefer self.clearFrames();
        try self.frames.ensureTotalCapacity(allocator, image.frames.len);
        for (image.frames) |frame| {
            const texture = textureFromFrame(frame) orelse return error.TextureFailed;
            self.frames.appendAssumeCapacity(.{ .texture = texture, .delay_ms = frame.delay_ms });
        }
        self.playing = true;
        self.plays = image.plays;
        self.completed_plays = 0;
        if (self.frames.items.len > 1) {
            for (self.frames.items) |*frame|
                frame.delay_ms = std.math.clamp(frame.delay_ms, 10, 10_000);
        }
        self.publishCurrent();
        self.scheduleNext();
    }

    pub fn animated(self: *const Session) bool {
        return self.frames.items.len > 1;
    }

    pub fn isPlaying(self: *const Session) bool {
        return self.animated() and self.playing;
    }

    pub fn togglePlayback(self: *Session) void {
        if (!self.animated()) return;
        if (self.playing) {
            self.playing = false;
        } else {
            if (self.plays != 0 and self.completed_plays >= self.plays) {
                self.frame_index = 0;
                self.completed_plays = 0;
                self.publishCurrent();
            }
            self.playing = true;
        }
        self.next_deadline_us = 0;
        if (self.playing) self.scheduleNext() else self.stopTimer();
        self.notifyPlayback();
    }

    pub fn setPlaybackCallback(self: *Session, context: ?*anyopaque, callback: ?*const fn (?*anyopaque) void) void {
        self.playback_ctx = context;
        self.on_playback = callback;
    }

    pub fn rotate(self: *Session, delta: i8) void {
        const next = @as(i8, @intCast(self.quarter_turns)) + delta;
        self.quarter_turns = @intCast(@mod(next, 4));
        for (self.frames.items) |*frame| {
            if (frame.rotated) |texture| c.g_object_unref(@ptrCast(texture));
            frame.rotated = null;
        }
        self.publishCurrent();
    }

    pub fn rotationDegrees(self: *const Session) u16 {
        return @as(u16, self.quarter_turns) * 90;
    }

    pub fn currentTexture(self: *const Session) ?*c.GdkTexture {
        if (self.frame_index < self.frames.items.len) {
            const frame = self.frames.items[self.frame_index];
            if (self.quarter_turns != 0) return frame.rotated orelse frame.texture;
            return frame.texture;
        }
        return null;
    }

    pub fn clear(self: *Session) void {
        self.clearFrames();
    }

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        self.releaseFrames(false);
        self.canvases.deinit(allocator);
    }

    fn stopTimer(self: *Session) void {
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.timer = 0;
    }

    fn clearFrames(self: *Session) void {
        self.releaseFrames(true);
    }

    fn releaseFrames(self: *Session, publish: bool) void {
        self.stopTimer();
        if (publish) for (self.canvases.items) |canvas| canvas.setTexture(null);
        for (self.frames.items) |frame| {
            c.g_object_unref(@ptrCast(frame.texture));
            if (frame.rotated) |texture| c.g_object_unref(@ptrCast(texture));
        }
        self.frames.clearRetainingCapacity();
        self.frame_index = 0;
        self.playing = true;
        self.quarter_turns = 0;
        self.next_deadline_us = 0;
        self.plays = 1;
        self.completed_plays = 0;
    }

    fn publishCurrent(self: *Session) void {
        const frame = if (self.frame_index < self.frames.items.len) &self.frames.items[self.frame_index] else null;
        const shown = if (frame) |current| blk: {
            if (self.quarter_turns == 0) break :blk current.texture;
            if (current.rotated == null) current.rotated = rotateTexture(current.texture, self.quarter_turns);
            break :blk current.rotated orelse current.texture;
        } else null;
        for (self.canvases.items) |canvas| canvas.setTexture(shown);
    }

    fn scheduleNext(self: *Session) void {
        self.stopTimer();
        if (!self.playing or !self.animated()) return;
        const now = c.g_get_monotonic_time();
        if (self.next_deadline_us == 0)
            self.next_deadline_us = now + @as(i64, self.frames.items[self.frame_index].delay_ms) * 1000;
        const delay: c.guint = @intCast(@max(1, @divTrunc(self.next_deadline_us - now + 999, 1000)));
        self.timer = c.g_timeout_add(delay, @ptrCast(&onAnimationTick), @ptrCast(self));
    }

    fn onAnimationTick(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Session = @ptrCast(@alignCast(user.?));
        self.timer = 0;
        if (!self.playing or !self.animated()) return 0;
        const now = c.g_get_monotonic_time();
        if (self.plays == 0) {
            var cycle_us: i64 = 0;
            for (self.frames.items) |frame| cycle_us += @as(i64, frame.delay_ms) * 1000;
            if (cycle_us > 0 and now - self.next_deadline_us >= cycle_us)
                self.next_deadline_us += @divTrunc(now - self.next_deadline_us, cycle_us) * cycle_us;
        }
        var advanced: usize = 0;
        while (self.next_deadline_us <= now) {
            const next = (self.frame_index + 1) % self.frames.items.len;
            if (next == 0) {
                self.completed_plays +|= 1;
                if (self.plays != 0 and self.completed_plays >= self.plays) {
                    self.frame_index = self.frames.items.len - 1;
                    self.playing = false;
                    self.next_deadline_us = 0;
                    self.publishCurrent();
                    self.notifyPlayback();
                    return 0;
                }
            }
            self.frame_index = next;
            self.next_deadline_us += @as(i64, self.frames.items[self.frame_index].delay_ms) * 1000;
            advanced += 1;
            if (advanced > self.frames.items.len + 1) {
                self.next_deadline_us = now + @as(i64, self.frames.items[self.frame_index].delay_ms) * 1000;
                break;
            }
        }
        self.publishCurrent();
        self.scheduleNext();
        return 0;
    }

    fn notifyPlayback(self: *Session) void {
        if (self.on_playback) |callback| callback(self.playback_ctx);
    }
};

fn textureFromFrame(frame: decoder.Frame) ?*c.GdkTexture {
    const bytes = c.g_bytes_new(frame.rgba.ptr, frame.rgba.len) orelse return null;
    defer c.g_bytes_unref(bytes);
    return @ptrCast(@alignCast(c.gdk_memory_texture_new(
        @intCast(frame.width),
        @intCast(frame.height),
        c.GDK_MEMORY_R8G8B8A8,
        bytes,
        @intCast(frame.width * 4),
    )));
}

fn rotateTexture(source: *c.GdkTexture, turns: u2) ?*c.GdkTexture {
    if (turns == 0) return null;
    const width: usize = @intCast(c.gdk_texture_get_width(source));
    const height: usize = @intCast(c.gdk_texture_get_height(source));
    const byte_len = std.math.mul(usize, std.math.mul(usize, width, height) catch return null, 4) catch return null;
    const allocator = std.heap.c_allocator;
    const input = allocator.alloc(u8, byte_len) catch return null;
    defer allocator.free(input);
    const output = allocator.alloc(u8, byte_len) catch return null;
    defer allocator.free(output);
    c.gdk_texture_download(source, input.ptr, width * 4);
    rotateRgba(input, output, width, height, turns);
    const out_width = if (turns == 1 or turns == 3) height else width;
    const out_height = if (turns == 1 or turns == 3) width else height;
    const bytes = c.g_bytes_new(output.ptr, output.len) orelse return null;
    defer c.g_bytes_unref(bytes);
    return @ptrCast(@alignCast(c.gdk_memory_texture_new(
        @intCast(out_width),
        @intCast(out_height),
        c.GDK_MEMORY_R8G8B8A8,
        bytes,
        out_width * 4,
    )));
}

fn rotateRgba(input: []const u8, output: []u8, width: usize, height: usize, turns: u2) void {
    for (0..height) |y| for (0..width) |x| {
        const src = (y * width + x) * 4;
        const dst_pixel = switch (turns) {
            1 => x * height + (height - 1 - y),
            2 => (height - 1 - y) * width + (width - 1 - x),
            3 => (width - 1 - x) * height + y,
            else => y * width + x,
        };
        @memcpy(output[dst_pixel * 4 ..][0..4], input[src..][0..4]);
    };
}

test "temporary rotation maps pixels clockwise without changing source" {
    const red = [_]u8{ 255, 0, 0, 255 };
    const blue = [_]u8{ 0, 0, 255, 255 };
    const source = red ++ blue;
    var clockwise: [8]u8 = undefined;
    rotateRgba(&source, &clockwise, 2, 1, 1);
    try std.testing.expectEqualSlices(u8, &source, &clockwise);
    var around: [8]u8 = undefined;
    rotateRgba(&source, &around, 2, 1, 2);
    try std.testing.expectEqualSlices(u8, &(blue ++ red), &around);
    try std.testing.expectEqualSlices(u8, &(red ++ blue), &source);
}
