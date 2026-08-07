//! Reusable media transport bar: play/pause, seekable position scale,
//! position/duration label, optional restart button, speed dropdown and
//! scale markers.
//!
//! The bar is presentation-only. It talks to its media through a small
//! `Source` vtable (toggle / restart / seek / speed); the media pushes
//! its state back via `setState` (and `setMarkers` when its marker set
//! changes). The seek throttle + guard machinery lives HERE because it
//! is chrome policy, but the numbers are construction options: cast
//! playback needs 250ms/1s (every daemon seek is a full replay), image
//! animation seeks are cheap and pass 0/0 for instant scrubbing.
//!
//! Signal-lifetime contract (mechanism 2 of the CLAUDE.md rules, same
//! shape as CastPlayerBox): every handler carries a raw *Playbar with
//! no destroy-notify. The host must call `sever()` (fences the seek
//! timer), let the bar widget die, and only then call `destroy()`.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");

/// Playback speeds offered by the optional dropdown; index 2 = 1x.
const SPEEDS = [_]f64{ 0.25, 0.5, 1.0, 1.5, 2.0, 4.0 };
const SPEED_LABELS = [_:null]?[*:0]const u8{ "0.25x", "0.5x", "1x", "1.5x", "2x", "4x", null };

pub const Playbar = struct {
    /// Mirrors cast play-state semantics; image sources map their
    /// simpler playing/paused/done states onto it.
    pub const Kind = enum { playing, paused, seeking, finished };

    /// A push-update from the media. `duration_ms == null` means still
    /// unknown (the scale stays insensitive until it arrives).
    pub const State = struct {
        kind: Kind,
        position_ms: u64 = 0,
        duration_ms: ?u64 = null,
    };

    /// Transport commands, all optional: an omitted `restart`/`set_speed`
    /// simply pairs with the matching Options flag being false.
    pub const Source = struct {
        ctx: ?*anyopaque = null,
        toggle: ?*const fn (?*anyopaque) void = null,
        restart: ?*const fn (?*anyopaque) void = null,
        seek_to_ms: ?*const fn (?*anyopaque, u64) void = null,
        set_speed: ?*const fn (?*anyopaque, f64) void = null,
    };

    pub const Options = struct {
        restart_button: bool = true,
        speed_dropdown: bool = false,
        /// Minimum gap between seek sends while the slider is dragged;
        /// 0 sends every change immediately.
        seek_throttle_ms: c_uint = 0,
        /// After a user seek, ignore `.playing` position pushes this
        /// long (µs) so a stale throttled push can't snap the thumb
        /// back; 0 disables the guard.
        seek_guard_us: i64 = 0,
    };

    allocator: std.mem.Allocator,
    source: Source,
    options: Options,

    bar: *c.GtkWidget,
    play_button: *c.GtkWidget,
    scale: *c.GtkWidget,
    position_label: *c.GtkLabel,
    speed_drop: ?*c.GtkWidget,

    /// Latest known duration (0 = unknown, seek disabled).
    duration_ms: u64 = 0,
    /// Latest pushed position; baseline for `seekRelative`.
    position_ms: u64 = 0,
    /// Owned copy of the marker positions, kept so a duration that
    /// arrives after the markers can still draw them.
    markers: std.ArrayList(u64) = .empty,
    /// Monotonic µs of the last user slider/seek interaction.
    user_seek_us: i64 = 0,
    /// Slider seek throttle: latest target, sent by `seek_timer`.
    pending_seek: ?u64 = null,
    seek_timer: c_uint = 0,
    /// True once sever ran; makes it idempotent.
    severed: bool = false,

    pub fn create(allocator: std.mem.Allocator, source: Source, options: Options) !*Playbar {
        const self = try allocator.create(Playbar);
        errdefer allocator.destroy(self);

        const bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8).?;
        c.gtk_widget_set_margin_start(bar, 10);
        c.gtk_widget_set_margin_end(bar, 10);
        c.gtk_widget_set_margin_top(bar, 6);
        c.gtk_widget_set_margin_bottom(bar, 8);
        const play_button = c.gtk_button_new_from_icon_name("media-playback-pause-symbolic").?;
        c.gtk_widget_set_tooltip_text(play_button, "Play / Pause (Space)");
        c.gtk_box_append(@ptrCast(bar), play_button);
        if (options.restart_button) {
            const restart_button = c.gtk_button_new_from_icon_name("media-skip-backward-symbolic").?;
            c.gtk_widget_set_tooltip_text(restart_button, "Restart (R)");
            c.gtk_box_append(@ptrCast(bar), restart_button);
            _ = c.g_signal_connect_data(restart_button, "clicked", @ptrCast(&onRestartClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        }
        const position_label = c.gtk_label_new("0:00 / --:--").?;
        c.gtk_widget_add_css_class(position_label, "numeric");
        const scale = c.gtk_scale_new_with_range(c.GTK_ORIENTATION_HORIZONTAL, 0, 1, 100).?;
        c.gtk_scale_set_draw_value(@ptrCast(scale), 0);
        c.gtk_widget_set_hexpand(scale, 1);
        c.gtk_widget_set_sensitive(scale, 0); // until duration_ms is known
        c.gtk_widget_set_tooltip_text(scale, "Seek");
        c.gtk_box_append(@ptrCast(bar), scale);
        c.gtk_box_append(@ptrCast(bar), @ptrCast(@alignCast(position_label)));
        var speed_drop: ?*c.GtkWidget = null;
        if (options.speed_dropdown) {
            const drop = c.gtk_drop_down_new_from_strings(@ptrCast(@constCast(&SPEED_LABELS))).?;
            c.gtk_drop_down_set_selected(@ptrCast(drop), 2); // 1x
            c.gtk_widget_set_tooltip_text(drop, "Playback speed");
            c.gtk_box_append(@ptrCast(bar), drop);
            _ = c.g_signal_connect_data(drop, "notify::selected", @ptrCast(&onSpeedChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
            speed_drop = drop;
        }

        self.* = .{
            .allocator = allocator,
            .source = source,
            .options = options,
            .bar = bar,
            .play_button = play_button,
            .scale = scale,
            .position_label = @ptrCast(@alignCast(position_label)),
            .speed_drop = speed_drop,
        };
        _ = c.g_signal_connect_data(play_button, "clicked", @ptrCast(&onPlayClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        // change-value fires on USER interaction only (set_value does
        // not emit it), so no feedback-loop guard is needed here.
        _ = c.g_signal_connect_data(scale, "change-value", @ptrCast(&onScaleChangeValue), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        return self;
    }

    /// The bar widget the host parents wherever it wants.
    pub fn widget(self: *Playbar) *c.GtkWidget {
        return self.bar;
    }

    /// Fence the seek timer before the widgets die. Idempotent.
    pub fn sever(self: *Playbar) void {
        if (self.severed) return;
        self.severed = true;
        if (self.seek_timer != 0) {
            _ = c.g_source_remove(self.seek_timer);
            self.seek_timer = 0;
        }
    }

    /// Free the struct. The bar widget must already be dead (or about
    /// to die with its container) — see the contract in the file docs.
    pub fn destroy(self: *Playbar) void {
        self.sever();
        self.markers.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Apply a state push: play icon, duration/range, thumb position
    /// (guard-filtered) and the position label.
    pub fn setState(self: *Playbar, st: State) void {
        const playing = st.kind == .playing or st.kind == .seeking;
        c.gtk_button_set_icon_name(
            @ptrCast(self.play_button),
            if (playing) "media-playback-pause-symbolic" else "media-playback-start-symbolic",
        );

        if (st.duration_ms) |d| {
            const dur = @max(d, 1);
            if (self.duration_ms != dur) {
                self.duration_ms = dur;
                c.gtk_range_set_range(@ptrCast(self.scale), 0, @floatFromInt(dur));
                c.gtk_widget_set_sensitive(self.scale, 1);
                self.redrawMarkers();
            }
        }

        // Keep the thumb off the user's fingers: right after a user
        // seek, a THROTTLED position push (kind .playing) may still
        // carry the pre-seek position — skip only those. Event-driven
        // pushes (seeking/paused/finished — seek completions included)
        // always carry the fresh position and must land, or the thumb
        // sticks wherever the user left it.
        const now = c.g_get_monotonic_time();
        const guard = st.kind == .playing and self.options.seek_guard_us > 0 and
            now - self.user_seek_us < self.options.seek_guard_us;
        self.position_ms = st.position_ms;
        if (self.duration_ms > 0 and !guard) {
            c.gtk_range_set_value(@ptrCast(self.scale), @floatFromInt(st.position_ms));
        }

        var buf: [64:0]u8 = undefined;
        const text = formatPosition(&buf, st.kind, st.position_ms, self.duration_ms);
        c.gtk_label_set_text(self.position_label, text.ptr);
    }

    /// Number of markers currently held (the caller's cheap "did the
    /// set change" probe, matching the old count-based redraw policy).
    pub fn markerCount(self: *const Playbar) usize {
        return self.markers.items.len;
    }

    /// Replace the marker set. A same-length set is treated as
    /// unchanged (count-based change detection, as the cast player
    /// always did). Draws immediately when the duration is known,
    /// otherwise on the state push that brings it.
    pub fn setMarkers(self: *Playbar, ms_list: []const u64) void {
        if (ms_list.len == self.markers.items.len) return;
        self.markers.clearRetainingCapacity();
        self.markers.appendSlice(self.allocator, ms_list) catch return;
        self.redrawMarkers();
    }

    /// Keyboard seeking: relative to the last pushed position, sent
    /// immediately (key repeat is far below drag rates) but still
    /// arming the guard against stale position pushes.
    pub fn seekRelative(self: *Playbar, delta_ms: i64) void {
        const pos: i64 = @intCast(self.position_ms);
        var target = pos + delta_ms;
        if (target < 0) target = 0;
        self.user_seek_us = c.g_get_monotonic_time();
        self.sendSeek(@intCast(target));
    }

    fn redrawMarkers(self: *Playbar) void {
        c.gtk_scale_clear_marks(@ptrCast(self.scale));
        if (self.duration_ms == 0) return;
        for (self.markers.items) |ms| {
            c.gtk_scale_add_mark(@ptrCast(self.scale), @floatFromInt(ms), c.GTK_POS_BOTTOM, null);
        }
    }

    fn sendSeek(self: *Playbar, target_ms: u64) void {
        const f = self.source.seek_to_ms orelse return;
        f(self.source.ctx, target_ms);
    }

    fn onPlayClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Playbar, user);
        if (self.source.toggle) |f| f(self.source.ctx);
    }

    fn onRestartClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Playbar, user);
        if (self.source.restart) |f| f(self.source.ctx);
    }

    fn onSpeedChanged(_: *c.GObject, _: ?*c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Playbar, user);
        const drop = self.speed_drop orelse return;
        const idx = c.gtk_drop_down_get_selected(@ptrCast(drop));
        if (idx >= SPEEDS.len) return;
        if (self.source.set_speed) |f| f(self.source.ctx, SPEEDS[idx]);
    }

    /// Slider interaction. With a throttle, at most one seek per
    /// `seek_throttle_ms` goes out while the drag continues; without
    /// one, every change is sent as it happens.
    fn onScaleChangeValue(_: *c.GtkRange, _: c.GtkScrollType, value: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Playbar, user);
        if (self.duration_ms == 0) return 0;
        const clamped = std.math.clamp(value, 0, @as(f64, @floatFromInt(self.duration_ms)));
        self.user_seek_us = c.g_get_monotonic_time();
        const target: u64 = @intFromFloat(clamped);
        if (self.options.seek_throttle_ms == 0) {
            self.sendSeek(target);
            return 0;
        }
        self.pending_seek = target;
        if (self.seek_timer == 0) {
            self.flushSeek();
            self.seek_timer = c.g_timeout_add(self.options.seek_throttle_ms, @ptrCast(&onSeekTimer), @ptrCast(self));
        }
        return 0; // let the range update visually
    }

    fn flushSeek(self: *Playbar) void {
        const target = self.pending_seek orelse return;
        self.pending_seek = null;
        self.sendSeek(target);
    }

    fn onSeekTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Playbar, user);
        if (self.pending_seek == null) {
            self.seek_timer = 0;
            return 0; // G_SOURCE_REMOVE
        }
        self.flushSeek();
        return 1; // keep throttling while the drag continues
    }
};

/// Position label text: "seeking...", "m:ss / m:ss", "m:ss / --:--"
/// while the duration (0 = unknown) has not arrived — and tenths
/// ("0.4s / 0.6s") for sub-10s media, where whole-second m:ss would
/// freeze at 0:00 for a typical short GIF.
pub fn formatPosition(buf: *[64:0]u8, kind: Playbar.Kind, position_ms: u64, duration_ms: u64) [:0]const u8 {
    if (kind == .seeking)
        return std.fmt.bufPrintZ(buf, "seeking...", .{}) catch unreachable;
    if (duration_ms > 0 and duration_ms < 10_000)
        return std.fmt.bufPrintZ(buf, "{d}.{d}s / {d}.{d}s", .{
            position_ms / 1000, (position_ms % 1000) / 100,
            duration_ms / 1000, (duration_ms % 1000) / 100,
        }) catch "0.0s";
    if (duration_ms > 0)
        return std.fmt.bufPrintZ(buf, "{d}:{d:0>2} / {d}:{d:0>2}", .{
            position_ms / 60_000, (position_ms / 1000) % 60,
            duration_ms / 60_000, (duration_ms / 1000) % 60,
        }) catch "0:00";
    return std.fmt.bufPrintZ(buf, "{d}:{d:0>2} / --:--", .{
        position_ms / 60_000, (position_ms / 1000) % 60,
    }) catch "0:00";
}

test "formatPosition covers unknown duration, known duration and seeking" {
    var buf: [64:0]u8 = undefined;
    try std.testing.expectEqualStrings("0:00 / --:--", formatPosition(&buf, .playing, 0, 0));
    try std.testing.expectEqualStrings("1:05 / 2:30", formatPosition(&buf, .paused, 65_000, 150_000));
    try std.testing.expectEqualStrings("seeking...", formatPosition(&buf, .seeking, 65_000, 150_000));
    // Sub-second positions round down to the elapsed whole second.
    try std.testing.expectEqualStrings("0:59 / 1:00", formatPosition(&buf, .playing, 59_999, 60_000));
    // Short media (a typical GIF) gets tenths instead of a frozen 0:00.
    try std.testing.expectEqualStrings("0.4s / 0.6s", formatPosition(&buf, .playing, 400, 600));
    try std.testing.expectEqualStrings("9.9s / 9.9s", formatPosition(&buf, .finished, 9_999, 9_999));
    try std.testing.expectEqualStrings("0:10 / 0:10", formatPosition(&buf, .finished, 10_000, 10_000));
}
