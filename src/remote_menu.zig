//! The host-side chrome a forwarded remote-application window carries:
//! the Ctrl+right-click menu (screenshot, record, embedding, close),
//! the PNG/GIF/WebM capture behind its rows, and the save-location
//! pick that follows.
//!
//! Its own module rather than a corner of either renderer because BOTH
//! remote-app backends put this menu on their windows -- the Wayland
//! app pipe (`wlapp.zig` AppHost) and the macOS window stream
//! (`winapp.zig` WsHost) -- and it lived in `wlapp.zig` until now, so
//! the pixels-only backend had to import the whole 2800-line Wayland
//! compositor brain to pop a three-row menu. `remote_window.zig` is
//! the window itself (creation, geometry, textures, no allocator and
//! no dialogs); this is what the host overlays on top of it.
//!
//! Moved verbatim out of wlapp.zig, so behaviour is unchanged.
//!
//! Lifetime: a row's `ctx` is the backend's window struct, which
//! outlives the popover; nothing here owns it. The popover unparents
//! itself from its own "closed" emission (ref-held across the idle),
//! which is the only allocation this module manages for the caller.

const std = @import("std");
const c = @import("c.zig").c;
const cast = @import("util/cast.zig");
const picker = @import("ui/picker.zig");
const fpicker = @import("filebrowser/picker.zig");
const pathZ = @import("util/pathz.zig").pathZ;

/// Pending "where do I put this blob?" pick. The encoded bytes are
/// captured before the picker opens, so they outlive the app window.
const SaveBytesCtx = struct {
    allocator: std.mem.Allocator,
    bytes: *c.GBytes,
    parent: ?*c.GtkWindow,
};

/// Ask for a destination and write `bytes` there. Takes ownership of
/// the GBytes reference on every path, including failure to open.
fn askSaveBytes(
    allocator: std.mem.Allocator,
    parent: ?*c.GtkWindow,
    bytes: *c.GBytes,
    title: []const u8,
    suggested: []const u8,
    filters: []const fpicker.Filter,
) void {
    const ctx = allocator.create(SaveBytesCtx) catch {
        c.g_bytes_unref(bytes);
        return;
    };
    ctx.* = .{ .allocator = allocator, .bytes = bytes, .parent = parent };
    _ = picker.PickerWindow.open(allocator, parent, .{
        .mode = .save_file,
        .title = title,
        .suggested_name = suggested,
        .filters = filters,
    }, &onShotPicked, @ptrCast(ctx)) catch {
        c.g_bytes_unref(bytes);
        allocator.destroy(ctx);
        return;
    };
}

/// Fires exactly once (cancel included), so the blob and the ctx are
/// released here on every path.
fn onShotPicked(user: ?*anyopaque, result: ?fpicker.Result) void {
    const ctx = cast.userData(SaveBytesCtx, user);
    defer {
        c.g_bytes_unref(ctx.bytes);
        ctx.allocator.destroy(ctx);
    }
    const res = result orelse return;
    if (res.specs.len == 0) return;
    // This process holds the encoded bytes and writes them itself —
    // there is no path on another host it could write to.
    const path = picker.localPathOrRefuse(
        ctx.parent,
        res.specs[0],
        "Sketerm writes the file itself — pick a location on this machine.",
    ) orelse return;
    var pz: [4096]u8 = undefined;
    const path_z = pathZ(&pz, path) catch return;
    const file = c.g_file_new_for_path(path_z) orelse return;
    defer c.g_object_unref(file);
    var sz: usize = 0;
    const data = c.g_bytes_get_data(ctx.bytes, &sz) orelse return;
    _ = c.g_file_replace_contents(
        file,
        @ptrCast(data),
        sz,
        null,
        0,
        c.G_FILE_CREATE_REPLACE_DESTINATION,
        null,
        null,
        null,
    );
}

const PNG_FILTERS = [_]fpicker.Filter{.{ .label = "PNG images", .patterns = &.{"*.png"} }};
const GIF_FILTERS = [_]fpicker.Filter{.{ .label = "GIF animations", .patterns = &.{"*.gif"} }};
const WEBM_FILTERS = [_]fpicker.Filter{.{ .label = "WebM videos", .patterns = &.{"*.webm"} }};

// ---- forwarded-window host menu ----------------------------------
//
// Both app-forwarding backends put the same host-side chrome on a
// remote window: screenshot, record, close. The rows below are the
// mechanism (popover, row buttons, teardown); each backend passes its
// own row list, because only the Wayland side has embedding
// (pop-out / show-in-tab) to offer.

/// One host-menu row: a label and the handler the button drives.
pub const HostMenuRow = struct {
    label: [*:0]const u8,
    cb: *const fn (?*c.GtkButton, ?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
};

/// A row of the host menu as a DECISION rather than a widget.
///
/// Which rows a forwarded window offers, in what order, and with what
/// wording is the same question for both backends and depends only on
/// the window's state — so it is decided here, once, by a pure
/// function `hostMenuPlan`, and each backend only maps items onto its
/// own handlers. Two things fall out of that:
///
///   * the two backends cannot drift apart in row order or labelling
///     (winapp's half raises a real window only against a remote macOS
///     agent, so drift there would go unnoticed indefinitely);
///   * a backend's `switch` over this enum is EXHAUSTIVE, so adding a
///     row here is a compile error in any backend that has not decided
///     what to do about it. That is the same class of guard as the
///     comptime action-name table in `ui/menu.zig`, for the same
///     reason: nothing at runtime complains about a row that looks
///     live and does nothing.
pub const HostMenuItem = enum {
    screenshot,
    /// Start a WebM recording — nothing is recording yet.
    record_webm,
    /// Stop whatever is recording. Occupies the WebM row's slot,
    /// because `WindowRec.toggle` stops whichever kind is running.
    stop_recording,
    /// Start a GIF recording. Offered only when nothing is recording:
    /// with a recording live there is one stop row, not two.
    record_gif,
    /// Wayland only: leave the embedding pane for a floating toplevel.
    pop_out,
    /// Wayland only: move this floating toplevel into a pane.
    show_in_tab,
    close,
};

/// The one spelling of each row. Shared so the backends cannot word
/// the same verb two ways.
pub fn hostMenuLabel(item: HostMenuItem) [*:0]const u8 {
    return switch (item) {
        .screenshot => "Screenshot Window\u{2026}",
        .record_webm => "Record Window (WebM)",
        .stop_recording => "Stop Recording\u{2026}",
        .record_gif => "Record Window (GIF)",
        .pop_out => "Pop Out Window",
        .show_in_tab => "Show in Tab",
        .close => "Close Window",
    };
}

/// What a forwarded window's host menu offers right now.
pub const HostMenuState = struct {
    /// A GIF or WebM recording of this window is running.
    recording: bool = false,
    /// This window is currently embedded in a pane (Wayland only).
    embedded: bool = false,
    /// This host CAN embed a window and none is embedded (Wayland
    /// only). Ignored when `embedded` is set.
    can_embed: bool = false,
};

/// Upper bound on the rows a plan can hold.
pub const MAX_HOST_MENU_ROWS: usize = 5;

/// The rows this window's host menu shows, in order. Pure: unit-tested
/// without a window, a GTK context or a remote agent.
pub fn hostMenuPlan(st: HostMenuState, out: *[MAX_HOST_MENU_ROWS]HostMenuItem) []const HostMenuItem {
    var n: usize = 0;
    out[n] = .screenshot;
    n += 1;
    out[n] = if (st.recording) .stop_recording else .record_webm;
    n += 1;
    if (!st.recording) {
        out[n] = .record_gif;
        n += 1;
    }
    if (st.embedded) {
        out[n] = .pop_out;
        n += 1;
    } else if (st.can_embed) {
        out[n] = .show_in_tab;
        n += 1;
    }
    out[n] = .close;
    n += 1;
    return out[0..n];
}

/// Pop a host menu of `rows`, parented to `parent` at (x, y) in its
/// coordinates. Handlers call `popdownHostMenu` on their button.
pub fn popupHostMenu(parent: *c.GtkWidget, x: f64, y: f64, rows: []const HostMenuRow) void {
    const pop = c.gtk_popover_new();
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    for (rows) |row| {
        const btn = c.gtk_button_new_with_label(row.label);
        c.gtk_button_set_has_frame(@ptrCast(btn), 0);
        _ = c.g_signal_connect_data(@ptrCast(btn), "clicked", @ptrCast(row.cb), row.ctx, null, 0);
        c.gtk_box_append(@ptrCast(box), btn);
    }
    c.gtk_popover_set_child(@ptrCast(pop), box);
    c.gtk_widget_set_parent(pop, parent);
    var rect = c.GdkRectangle{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = 1, .height = 1 };
    c.gtk_popover_set_pointing_to(@ptrCast(pop), &rect);
    _ = c.g_signal_connect_data(@ptrCast(pop), "closed", @ptrCast(&onHostMenuClosed), null, null, 0);
    c.gtk_popover_popup(@ptrCast(pop));
}

/// Dismiss the host menu a row button belongs to.
pub fn popdownHostMenu(btn: ?*c.GtkButton) void {
    const pop = c.gtk_widget_get_ancestor(@ptrCast(btn), c.gtk_popover_get_type()) orelse return;
    c.gtk_popover_popdown(@ptrCast(pop));
}

fn onHostMenuClosed(pop: ?*c.GtkPopover, _: ?*anyopaque) callconv(.c) void {
    // Unparent OUTSIDE the closed emission; ref-held so a window
    // teardown racing the idle can't leave a dangler.
    _ = c.g_object_ref(@ptrCast(pop));
    _ = c.g_idle_add(@ptrCast(&idleUnparentPopover), pop);
}

fn idleUnparentPopover(user: ?*anyopaque) callconv(.c) c_int {
    const w: *c.GtkWidget = @ptrCast(@alignCast(user.?));
    if (c.gtk_widget_get_parent(w) != null) c.gtk_widget_unparent(w);
    c.g_object_unref(@ptrCast(w));
    return 0; // G_SOURCE_REMOVE
}

/// Save a GtkPicture's CURRENT frame as a PNG. The texture's bytes are
/// taken immediately (they outlive the window), then a save location
/// is asked for.
pub fn screenshotPicture(allocator: std.mem.Allocator, parent: ?*c.GtkWindow, picture: *c.GtkWidget) void {
    const paintable = c.gtk_picture_get_paintable(@ptrCast(picture)) orelse return;
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(paintable)), c.gdk_texture_get_type()) == 0) return;
    const bytes = c.gdk_texture_save_to_png_bytes(@ptrCast(paintable)) orelse return;
    askSaveBytes(allocator, parent, bytes, "Save App Screenshot", "sketerm-app.png", &PNG_FILTERS);
}

/// GIF/WebM recording of one forwarded window's frames — the state
/// behind the host menu's Record rows, shared by both backends so the
/// start/stop/save rules cannot drift apart.
pub const WindowRec = struct {
    pub const Kind = enum { gif, webm };

    gif: ?@import("util/gifrec.zig").Rec = null,
    webm: ?@import("util/videorec.zig").Rec = null,

    pub fn active(self: *const WindowRec) bool {
        return self.gif != null or self.webm != null;
    }

    pub fn nowMs() i64 {
        return @divTrunc(c.g_get_monotonic_time(), 1000);
    }

    /// Feed one presented frame (wl_shm-style format code: 0 =
    /// premultiplied BGRA, 1 = BGRX). No-op when not recording.
    pub fn addFrame(self: *WindowRec, pixels: []const u8, w: u32, h: u32, format: u32) void {
        if (self.gif) |*r| r.addShmFrame(pixels, w, h, format, nowMs()) catch {};
        if (self.webm) |*r| r.addShmFrame(pixels, w, h, format, nowMs()) catch {};
    }

    /// Toggle: a running recording of EITHER kind stops and offers to
    /// save; otherwise `kind` starts.
    pub fn toggle(self: *WindowRec, allocator: std.mem.Allocator, parent: ?*c.GtkWindow, kind: Kind) void {
        if (self.gif) |*r| {
            const blob = r.finish(nowMs()) catch {
                self.gif = null;
                return;
            };
            self.gif = null;
            const bytes = c.g_bytes_new(blob.ptr, blob.len);
            allocator.free(blob);
            askSaveBytes(allocator, parent, bytes.?, "Save Recording", "sketerm-recording.gif", &GIF_FILTERS);
            return;
        }
        if (self.webm) |*r| {
            const blob = r.finish(nowMs()) catch {
                self.webm = null;
                return;
            };
            self.webm = null;
            const bytes = c.g_bytes_new(blob.ptr, blob.len);
            allocator.free(blob);
            askSaveBytes(allocator, parent, bytes.?, "Save Recording", "sketerm-recording.webm", &WEBM_FILTERS);
            return;
        }
        switch (kind) {
            .gif => self.gif = @import("util/gifrec.zig").Rec.init(allocator, 0),
            .webm => self.webm = @import("util/videorec.zig").Rec.init(allocator, 0),
        }
    }

    /// Drop a recording without saving (the window died under it).
    pub fn abort(self: *WindowRec) void {
        if (self.gif) |*r| r.abort();
        if (self.webm) |*r| r.abort();
        self.gif = null;
        self.webm = null;
    }
};

// ---- host-menu plan tests -----------------------------------------
//
// This is the part of the forwarded-window host menu that CAN be
// covered on a Linux box: the row decision is pure, so both backends'
// menus are asserted here without a window, a GTK context, a
// compositor or (for winapp) a remote macOS agent.

const testing = std.testing;

fn planLabels(st: HostMenuState, buf: *[MAX_HOST_MENU_ROWS]HostMenuItem) []const HostMenuItem {
    return hostMenuPlan(st, buf);
}

test "host menu: an idle floating window offers screenshot, both recorders and close" {
    var buf: [MAX_HOST_MENU_ROWS]HostMenuItem = undefined;
    const plan = planLabels(.{}, &buf);
    try testing.expectEqualSlices(HostMenuItem, &.{ .screenshot, .record_webm, .record_gif, .close }, plan);
}

test "host menu: recording collapses the two record rows into one stop row" {
    var buf: [MAX_HOST_MENU_ROWS]HostMenuItem = undefined;
    const plan = planLabels(.{ .recording = true }, &buf);
    try testing.expectEqualSlices(HostMenuItem, &.{ .screenshot, .stop_recording, .close }, plan);
    // The stop row sits where the WebM row was, because the toggle
    // stops whichever kind is running.
    try testing.expect(plan[1] == .stop_recording);
    for (plan) |it| try testing.expect(it != .record_gif and it != .record_webm);
}

test "host menu: an embedded window offers Pop Out and never Show in Tab" {
    var buf: [MAX_HOST_MENU_ROWS]HostMenuItem = undefined;
    const plan = planLabels(.{ .embedded = true, .can_embed = true }, &buf);
    try testing.expectEqualSlices(
        HostMenuItem,
        &.{ .screenshot, .record_webm, .record_gif, .pop_out, .close },
        plan,
    );
}

test "host menu: a floating window on an embedding host offers Show in Tab" {
    var buf: [MAX_HOST_MENU_ROWS]HostMenuItem = undefined;
    const plan = planLabels(.{ .can_embed = true }, &buf);
    try testing.expectEqualSlices(
        HostMenuItem,
        &.{ .screenshot, .record_webm, .record_gif, .show_in_tab, .close },
        plan,
    );
}

test "host menu: no plan ever exceeds the row buffer, and Close is always last" {
    var buf: [MAX_HOST_MENU_ROWS]HostMenuItem = undefined;
    for ([_]bool{ false, true }) |rec| {
        for ([_]bool{ false, true }) |emb| {
            for ([_]bool{ false, true }) |can| {
                const plan = planLabels(.{ .recording = rec, .embedded = emb, .can_embed = can }, &buf);
                try testing.expect(plan.len <= MAX_HOST_MENU_ROWS);
                try testing.expect(plan.len >= 3);
                try testing.expect(plan[0] == .screenshot);
                try testing.expect(plan[plan.len - 1] == .close);
                // Never two rows for the same verb.
                for (plan, 0..) |a, i| for (plan[i + 1 ..]) |b| try testing.expect(a != b);
            }
        }
    }
}

test "host menu: winapp's state can never produce a row it has no handler for" {
    // winapp.zig maps the plan onto its handlers with an exhaustive
    // switch whose only skip is `.pop_out, .show_in_tab => continue`.
    // That skip is safe exactly because a winstream window is always
    // floating: `embedded` and `can_embed` are both false there, and
    // this pins that such a state never yields either row. Without it,
    // a future change to hostMenuPlan could drop a row from the
    // winstream menu with nothing anywhere complaining.
    var buf: [MAX_HOST_MENU_ROWS]HostMenuItem = undefined;
    for ([_]bool{ false, true }) |rec| {
        const plan = planLabels(.{ .recording = rec }, &buf);
        for (plan) |it| try testing.expect(it != .pop_out and it != .show_in_tab);
    }
}

test "host menu: every row has a non-empty label and no two share one" {
    inline for (@typeInfo(HostMenuItem).@"enum".fields) |fa| {
        const a: HostMenuItem = @enumFromInt(fa.value);
        try testing.expect(std.mem.span(hostMenuLabel(a)).len > 0);
        inline for (@typeInfo(HostMenuItem).@"enum".fields) |fb| {
            const b: HostMenuItem = @enumFromInt(fb.value);
            if (fa.value == fb.value) continue;
            try testing.expect(!std.mem.eql(u8, std.mem.span(hostMenuLabel(a)), std.mem.span(hostMenuLabel(b))));
        }
    }
}
