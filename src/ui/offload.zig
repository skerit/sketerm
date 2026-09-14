//! Bound GTK offload callback retention without changing the GL renderer.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");

// GTK can request one callback per toplevel paint on a rejected subsurface
// without receiving its completion. Retire that surface well before the
// accumulated delete_id replies could fill a compositor's outgoing queue.
pub const FRAME_BUDGET: i64 = 128;

const Age = struct {
    born: i64 = 0,

    fn due(self: Age, frame: i64) bool {
        return frame >= self.born and frame - self.born >= FRAME_BUDGET;
    }
};

fn clockKey() c.GQuark {
    return c.g_quark_from_static_string("sketerm-offload-guards");
}

pub const Guard = struct {
    widget: ?*c.GtkWidget = null, // owned until deinit
    clock: ?*c.GdkFrameClock = null, // owned while connected
    clock_signal: c_ulong = 0,
    next: ?*Guard = null,
    age: Age = .{},
    renewing: bool = false,

    pub fn init(self: *Guard, widget: *c.GtkWidget) void {
        _ = c.g_object_ref(widget);
        self.widget = widget;
        _ = c.g_signal_connect_data(widget, "map", @ptrCast(&onMap), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(widget, "unmap", @ptrCast(&onUnmap), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(widget, "notify::enabled", @ptrCast(&onEnabled), self, null, c.G_CONNECT_DEFAULT);
        self.syncClock();
    }

    pub fn deinit(self: *Guard) void {
        const widget = self.widget orelse return;
        self.widget = null;
        self.disconnectClock();
        _ = c.g_signal_handlers_disconnect_matched(widget, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_graphics_offload_set_enabled(@ptrCast(widget), c.GTK_GRAPHICS_OFFLOAD_DISABLED);
        c.g_object_unref(widget);
    }

    fn disconnectClock(self: *Guard) void {
        const clock = self.clock orelse return;
        const obj: *c.GObject = @ptrCast(@alignCast(clock));
        var head: ?*Guard = @ptrCast(@alignCast(c.g_object_get_qdata(obj, clockKey())));
        if (head == self) {
            head = self.next;
        } else {
            var previous = head;
            while (previous) |guard| : (previous = guard.next) {
                if (guard.next == self) {
                    guard.next = self.next;
                    break;
                }
            }
        }
        c.g_object_set_qdata(obj, clockKey(), head);
        if (head == null) c.g_signal_handler_disconnect(clock, self.clock_signal);
        self.next = null;
        self.clock_signal = 0;
        self.clock = null;
        c.g_object_unref(clock);
    }

    fn syncClock(self: *Guard) void {
        if (self.renewing) return;
        const widget = self.widget orelse return;
        const clock: ?*c.GdkFrameClock = blk: {
            if (c.gtk_widget_get_mapped(widget) == 0 or
                c.gtk_graphics_offload_get_enabled(@ptrCast(widget)) != c.GTK_GRAPHICS_OFFLOAD_ENABLED) break :blk null;
            const display = c.gtk_widget_get_display(widget) orelse break :blk null;
            const name = c.g_type_name_from_instance(@ptrCast(@alignCast(display))) orelse break :blk null;
            if (!std.mem.eql(u8, std.mem.span(name), "GdkWaylandDisplay")) break :blk null;
            break :blk c.gtk_widget_get_frame_clock(widget);
        };
        if (clock == self.clock) return;
        self.disconnectClock();
        if (clock) |value| {
            _ = c.g_object_ref(value);
            self.clock = value;
            self.age.born = c.gdk_frame_clock_get_frame_counter(value);
            const obj: *c.GObject = @ptrCast(@alignCast(value));
            self.next = @ptrCast(@alignCast(c.g_object_get_qdata(obj, clockKey())));
            // One observer per clock; never start a tick or wake an idle pane.
            self.clock_signal = if (self.next) |head|
                head.clock_signal
            else
                c.g_signal_connect_data(value, "after-paint", @ptrCast(&onPaint), null, null, c.G_CONNECT_AFTER);
            c.g_object_set_qdata(obj, clockKey(), self);
        }
    }

    fn onMap(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(Guard, user).syncClock();
    }

    fn onUnmap(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(Guard, user).disconnectClock();
    }

    fn onEnabled(_: *c.GObject, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        cast.userData(Guard, user).syncClock();
    }

    fn onPaint(clock: *c.GdkFrameClock, _: ?*anyopaque) callconv(.c) void {
        const obj: *c.GObject = @ptrCast(@alignCast(clock));
        const frame = c.gdk_frame_clock_get_frame_counter(clock);
        var candidate: ?*Guard = null;
        var next: ?*Guard = @ptrCast(@alignCast(c.g_object_get_qdata(obj, clockKey())));
        while (next) |guard| : (next = guard.next) {
            if (!guard.age.due(frame)) continue;
            if (candidate == null or guard.age.born < candidate.?.age.born) candidate = guard;
        }
        // Retire one oldest surface per paint, even with more siblings than
        // the frame budget; fixed callback order would starve the last ones.
        const self = candidate orelse return;
        const widget = self.widget orelse return;

        self.renewing = true;
        defer self.renewing = false;
        // Both changes precede the next snapshot. GTK replaces only the
        // subsurface; the GLArea, its context and its rendered texture stay.
        c.gtk_graphics_offload_set_enabled(@ptrCast(widget), c.GTK_GRAPHICS_OFFLOAD_DISABLED);
        c.gtk_graphics_offload_set_enabled(@ptrCast(widget), c.GTK_GRAPHICS_OFFLOAD_ENABLED);
        self.age.born = frame;
    }
};

test "offload age counts toplevel paints, not elapsed time or pane renders" {
    const age: Age = .{ .born = 20 };
    try std.testing.expect(!age.due(20));
    try std.testing.expect(!age.due(20 + FRAME_BUDGET - 1));
    try std.testing.expect(age.due(20 + FRAME_BUDGET));
    try std.testing.expect(!age.due(0));
}

test "staggered renewal does not starve siblings" {
    var ages = [_]Age{.{}} ** 129;
    var renewals = [_]usize{0} ** ages.len;
    for (0..1024) |value| {
        const frame: i64 = @intCast(value);
        var oldest: ?usize = null;
        for (&ages, 0..) |*age, i| {
            if (!age.due(frame)) continue;
            if (oldest == null or age.born < ages[oldest.?].born) oldest = i;
        }
        if (oldest) |i| {
            const age = &ages[i];
            try std.testing.expect(frame - age.born < FRAME_BUDGET + ages.len);
            age.born = frame;
            renewals[i] += 1;
        }
    }
    for (renewals) |count| try std.testing.expect(count >= 6);
}
