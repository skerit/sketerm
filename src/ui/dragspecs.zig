//! The in-sketerm drag flavor (`dragout.SPECS_MIME`) as a GType.
//!
//! A file-browser drag offers text/uri-list for other applications, and
//! every GTK drop target that lists GdkFileList would then pick that
//! instead of the quoted-spec text it used to get -- and for a remote
//! entry, asking for a file list means fetching the file. Sketerm's own
//! targets therefore list this type FIRST: only a sketerm drag offers
//! it, it carries host-qualified specs plus their kind, and it crosses
//! process boundaries (a `sketerm files` window into a terminal pane)
//! through its registered (de)serializers.

const std = @import("std");
const c = @import("../c.zig").c;
const dragout = @import("../filebrowser/dragout.zig");

var specs_gtype: c.GType = 0;

/// The boxed type (a GStrv of `dragout` records). The first call also
/// registers the flavor's serializer and deserializer, so a drop target
/// must call this before it can be entered.
pub fn gtype() c.GType {
    if (specs_gtype != 0) return specs_gtype;
    specs_gtype = c.g_boxed_type_register_static("SketermDragSpecs", @ptrCast(&c.g_strdupv), @ptrCast(&c.g_strfreev));
    c.gdk_content_register_serializer(specs_gtype, dragout.SPECS_MIME, &serialize, null, null);
    c.gdk_content_register_deserializer(dragout.SPECS_MIME, specs_gtype, &deserialize, null, null);
    return specs_gtype;
}

/// Whether `value` holds the specs flavor.
pub fn holds(value: [*c]const c.GValue) bool {
    return specs_gtype != 0 and c.g_type_check_value_holds(value, specs_gtype) != 0;
}

/// A content provider offering `records` (each from `dragout.encodeRecord`).
pub fn provider(records: []const [:0]u8) ?*c.GdkContentProvider {
    const builder = c.g_strv_builder_new() orelse return null;
    defer c.g_strv_builder_unref(builder);
    for (records) |rec| c.g_strv_builder_add(builder, rec.ptr);
    var value: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&value, gtype());
    defer c.g_value_unset(&value);
    c.g_value_take_boxed(&value, @ptrCast(c.g_strv_builder_end(builder)));
    return c.gdk_content_provider_new_for_value(&value);
}

/// The records a specs value carries, in drag order.
pub const Iter = struct {
    strv: c.GStrv = null,
    index: usize = 0,

    pub fn init(value: [*c]const c.GValue) Iter {
        if (!holds(value)) return .{};
        const boxed = c.g_value_get_boxed(value) orelse return .{};
        return .{ .strv = @ptrCast(@alignCast(boxed)) };
    }

    pub fn next(self: *Iter) ?dragout.Record {
        const strv = self.strv orelse return null;
        while (strv[self.index]) |raw| {
            self.index += 1;
            if (dragout.decodeRecord(std.mem.span(@as([*:0]const u8, @ptrCast(raw))))) |rec| return rec;
        }
        return null;
    }
};

/// The plain-text flavor of the same drag (`dragout.appendQuotedSpecs`),
/// NUL-terminated; what terminal panes and text drops have always got.
pub fn quotedText(allocator: std.mem.Allocator, value: [*c]const c.GValue) ![:0]u8 {
    var specs: std.ArrayList([]const u8) = .empty;
    defer specs.deinit(allocator);
    var it = Iter.init(value);
    while (it.next()) |rec| try specs.append(allocator, rec.spec);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try dragout.appendQuotedSpecs(&out, allocator, specs.items);
    return out.toOwnedSliceSentinel(allocator, 0);
}

fn serialize(serializer: ?*c.GdkContentSerializer) callconv(.c) void {
    const value = c.gdk_content_serializer_get_value(serializer);
    var len: usize = 0;
    var it = Iter.init(value);
    var counting = it;
    while (counting.strv) |strv| : (counting.index += 1) {
        const raw = strv[counting.index] orelse break;
        len += std.mem.len(@as([*:0]const u8, @ptrCast(raw))) + 1;
    }
    const buf: [*]u8 = @ptrCast(c.g_malloc(@max(len, 1)) orelse {
        returnError(serializer, null, "out of memory");
        return;
    });
    var at: usize = 0;
    while (it.strv) |strv| : (it.index += 1) {
        const raw = strv[it.index] orelse break;
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        @memcpy(buf[at..][0..s.len], s);
        buf[at + s.len] = 0;
        at += s.len + 1;
    }
    c.gdk_content_serializer_set_task_data(serializer, buf, &c.g_free);
    c.g_output_stream_write_all_async(
        c.gdk_content_serializer_get_output_stream(serializer),
        buf,
        len,
        c.gdk_content_serializer_get_priority(serializer),
        c.gdk_content_serializer_get_cancellable(serializer),
        @ptrCast(&serializeDone),
        serializer,
    );
}

fn serializeDone(stream: ?*c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const serializer: ?*c.GdkContentSerializer = @ptrCast(@alignCast(user));
    var err: ?*c.GError = null;
    if (c.g_output_stream_write_all_finish(@ptrCast(@alignCast(stream)), result, null, &err) == 0)
        c.gdk_content_serializer_return_error(serializer, err)
    else
        c.gdk_content_serializer_return_success(serializer);
}

fn returnError(serializer: ?*c.GdkContentSerializer, deserializer: ?*c.GdkContentDeserializer, msg: [*:0]const u8) void {
    const err = c.g_error_new_literal(c.g_io_error_quark(), c.G_IO_ERROR_FAILED, msg);
    if (serializer) |s| c.gdk_content_serializer_return_error(s, err);
    if (deserializer) |d| c.gdk_content_deserializer_return_error(d, err);
}

fn deserialize(deserializer: ?*c.GdkContentDeserializer) callconv(.c) void {
    const sink = c.g_memory_output_stream_new_resizable();
    c.g_output_stream_splice_async(
        sink,
        c.gdk_content_deserializer_get_input_stream(deserializer),
        c.G_OUTPUT_STREAM_SPLICE_CLOSE_SOURCE | c.G_OUTPUT_STREAM_SPLICE_CLOSE_TARGET,
        c.gdk_content_deserializer_get_priority(deserializer),
        c.gdk_content_deserializer_get_cancellable(deserializer),
        @ptrCast(&deserializeDone),
        deserializer,
    );
    c.g_object_unref(sink);
}

fn deserializeDone(stream: ?*c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const deserializer: ?*c.GdkContentDeserializer = @ptrCast(@alignCast(user));
    const sink: [*c]c.GOutputStream = @ptrCast(@alignCast(stream));
    var err: ?*c.GError = null;
    if (c.g_output_stream_splice_finish(sink, result, &err) < 0) {
        c.gdk_content_deserializer_return_error(deserializer, err);
        return;
    }
    const mem: [*c]c.GMemoryOutputStream = @ptrCast(@alignCast(sink));
    const size = c.g_memory_output_stream_get_data_size(mem);
    const data: ?[*]const u8 = @ptrCast(c.g_memory_output_stream_get_data(mem));
    const bytes: []const u8 = if (data) |d| d[0..size] else "";
    const builder = c.g_strv_builder_new() orelse return returnError(null, deserializer, "out of memory");
    defer c.g_strv_builder_unref(builder);
    var records: dragout.Records = .{ .bytes = bytes };
    var rec_buf: std.ArrayList(u8) = .empty;
    defer rec_buf.deinit(std.heap.c_allocator);
    while (records.next()) |rec| {
        rec_buf.clearRetainingCapacity();
        rec_buf.append(std.heap.c_allocator, @intFromEnum(rec.kind)) catch return returnError(null, deserializer, "out of memory");
        rec_buf.appendSlice(std.heap.c_allocator, rec.spec) catch return returnError(null, deserializer, "out of memory");
        rec_buf.append(std.heap.c_allocator, 0) catch return returnError(null, deserializer, "out of memory");
        c.g_strv_builder_add(builder, rec_buf.items.ptr);
    }
    c.g_value_take_boxed(c.gdk_content_deserializer_get_value(deserializer), @ptrCast(c.g_strv_builder_end(builder)));
    c.gdk_content_deserializer_return_success(deserializer);
}
