//! Verification-only drop receiver for the `dnd-probe` command
//! (`smoke-dragout`): a second toplevel of the GUI with two drop zones.
//!
//! The left zone reads the drop exactly as a foreign application such
//! as Chromium does: raw `text/uri-list` bytes through
//! `gdk_drop_read_async`, so the browser drag's own provider, fetch and
//! GTK serializer all run. The right zone lists the gtypes sketerm's
//! own file-list targets list (pane, editor, viewer) and records which
//! one GTK picked, proving an in-sketerm drop still gets specs.

const std = @import("std");
const c = @import("../c.zig").c;
const dragspecs = @import("dragspecs.zig");

pub const TITLE = "sketerm-dnd-probe";

const Result = struct {
    state: []const u8 = "idle",
    /// The MIME type read (external) or the GType GTK picked (internal).
    mime: []const u8 = "",
    data: []const u8 = "",
    err: []const u8 = "",
};

var window: ?*c.GtkWidget = null;
var external: Result = .{};
var internal: Result = .{};
var drops: u32 = 0;

fn setText(slot: *[]const u8, text: []const u8) void {
    if (slot.len > 0) std.heap.c_allocator.free(slot.*);
    slot.* = std.heap.c_allocator.dupe(u8, text) catch "";
}

fn resetResult(r: *Result) void {
    for ([_]*[]const u8{ &r.mime, &r.data, &r.err }) |slot| {
        if (slot.len > 0) std.heap.c_allocator.free(slot.*);
        slot.* = "";
    }
    r.state = "idle";
}

/// What the probe saw, for the command's JSON reply.
pub const Report = struct {
    drops: u32,
    external: Result,
    internal: Result,
};

/// Open the probe window once; `reset` clears what earlier drops recorded.
pub fn ensure(reset: bool) Report {
    if (reset) {
        resetResult(&external);
        resetResult(&internal);
        drops = 0;
    }
    if (window == null) build();
    return .{ .drops = drops, .external = external, .internal = internal };
}

fn build() void {
    const win = c.gtk_window_new() orelse return;
    c.gtk_window_set_title(@ptrCast(win), TITLE);
    c.gtk_window_set_default_size(@ptrCast(win), 640, 320);
    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    const left = c.gtk_label_new("external: text/uri-list");
    const right = c.gtk_label_new("internal: sketerm targets");
    for ([_]?*c.GtkWidget{ left, right }) |zone| {
        c.gtk_widget_set_hexpand(zone, 1);
        c.gtk_widget_set_vexpand(zone, 1);
        c.gtk_widget_set_size_request(zone, 300, 300);
        c.gtk_box_append(@ptrCast(box), zone);
    }
    c.gtk_window_set_child(@ptrCast(win), box);

    const mimes = [_][*c]const u8{ "text/uri-list", null };
    const formats = c.gdk_content_formats_new(@ptrCast(@constCast(&mimes)), 1);
    const ext = c.gtk_drop_target_async_new(formats, c.GDK_ACTION_COPY | c.GDK_ACTION_MOVE);
    _ = c.g_signal_connect_data(ext, "drop", @ptrCast(&onExternalDrop), null, null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(left, @ptrCast(ext));

    const int = c.gtk_drop_target_new(c.G_TYPE_INVALID, c.GDK_ACTION_COPY);
    var types = [_]c.GType{ dragspecs.gtype(), c.gdk_file_list_get_type(), c.G_TYPE_STRING };
    c.gtk_drop_target_set_gtypes(int, &types, types.len);
    _ = c.g_signal_connect_data(int, "drop", @ptrCast(&onInternalDrop), null, null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(right, @ptrCast(int));

    window = win;
    c.gtk_window_present(@ptrCast(win));
}

fn onExternalDrop(_: *c.GtkDropTargetAsync, drop: *c.GdkDrop, _: f64, _: f64, _: ?*anyopaque) callconv(.c) c.gboolean {
    drops += 1;
    resetResult(&external);
    external.state = "reading";
    const mimes = [_][*c]const u8{ "text/uri-list", null };
    _ = c.g_object_ref(drop);
    c.gdk_drop_read_async(drop, @ptrCast(@constCast(&mimes)), c.G_PRIORITY_DEFAULT, null, @ptrCast(&onRead), drop);
    return 1;
}

fn onRead(_: ?*c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const drop: *c.GdkDrop = @ptrCast(@alignCast(user.?));
    var err: ?*c.GError = null;
    var mime: [*c]const u8 = null;
    const stream = c.gdk_drop_read_finish(drop, result, &mime, &err);
    if (stream == null) return finishExternal(drop, err, null);
    if (mime != null) setText(&external.mime, std.mem.span(@as([*:0]const u8, @ptrCast(mime))));
    const sink = c.g_memory_output_stream_new_resizable();
    c.g_output_stream_splice_async(sink, stream, c.G_OUTPUT_STREAM_SPLICE_CLOSE_SOURCE | c.G_OUTPUT_STREAM_SPLICE_CLOSE_TARGET, c.G_PRIORITY_DEFAULT, null, @ptrCast(&onSpliced), drop);
    c.g_object_unref(stream);
    c.g_object_unref(sink);
}

fn onSpliced(source: ?*c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const drop: *c.GdkDrop = @ptrCast(@alignCast(user.?));
    const sink: [*c]c.GOutputStream = @ptrCast(@alignCast(source));
    var err: ?*c.GError = null;
    if (c.g_output_stream_splice_finish(sink, result, &err) < 0) return finishExternal(drop, err, null);
    const mem: [*c]c.GMemoryOutputStream = @ptrCast(@alignCast(sink));
    const size = c.g_memory_output_stream_get_data_size(mem);
    const data: ?[*]const u8 = @ptrCast(c.g_memory_output_stream_get_data(mem));
    finishExternal(drop, null, if (data) |d| d[0..size] else "");
}

fn finishExternal(drop: *c.GdkDrop, err: ?*c.GError, data: ?[]const u8) void {
    defer c.g_object_unref(drop);
    if (err) |e| {
        external.state = "failed";
        setText(&external.err, std.mem.span(@as([*:0]const u8, @ptrCast(e.message))));
        c.g_error_free(e);
        c.gdk_drop_finish(drop, 0);
        return;
    }
    external.state = "done";
    setText(&external.data, data orelse "");
    c.gdk_drop_finish(drop, c.GDK_ACTION_COPY);
}

fn onInternalDrop(_: *c.GtkDropTarget, value: [*c]const c.GValue, _: f64, _: f64, _: ?*anyopaque) callconv(.c) c.gboolean {
    drops += 1;
    resetResult(&internal);
    internal.state = "done";
    setText(&internal.mime, std.mem.span(@as([*:0]const u8, @ptrCast(c.g_type_name(value.*.g_type)))));
    if (dragspecs.holds(value)) {
        const txt = dragspecs.quotedText(std.heap.c_allocator, value) catch return 0;
        defer std.heap.c_allocator.free(txt);
        setText(&internal.data, txt);
    }
    return 1;
}
