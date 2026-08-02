//! GUI-only image decoder boundary with sandboxed Glycin on Linux.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");

pub const Backend = enum { glycin, gdk_pixbuf };

pub const Decoded = struct {
    rgba: []u8,
    width: u32,
    height: u32,
    backend: Backend,

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.rgba);
        self.* = undefined;
    }
};

pub const Error = error{
    DecodeFailed,
    UnsupportedPixelFormat,
    TooLarge,
    OutOfMemory,
};

const GlyLoader = opaque {};
const GlyImage = opaque {};
const GlyFrame = opaque {};
const GLY_RGBA_SELECTION: c_int = 1 << 5;
const GLY_RGBA_FORMAT: c_int = 5;

const Api = struct {
    handle: *anyopaque,
    loader_new_bytes: *const fn (*c.GBytes) callconv(.c) ?*GlyLoader,
    loader_set_formats: *const fn (*GlyLoader, c_int) callconv(.c) void,
    loader_load: *const fn (*GlyLoader, *?*c.GError) callconv(.c) ?*GlyImage,
    image_width: *const fn (*GlyImage) callconv(.c) u32,
    image_height: *const fn (*GlyImage) callconv(.c) u32,
    image_next_frame: *const fn (*GlyImage, *?*c.GError) callconv(.c) ?*GlyFrame,
    frame_width: *const fn (*GlyFrame) callconv(.c) u32,
    frame_height: *const fn (*GlyFrame) callconv(.c) u32,
    frame_stride: *const fn (*GlyFrame) callconv(.c) u32,
    frame_bytes: *const fn (*GlyFrame) callconv(.c) ?*c.GBytes,
    frame_format: *const fn (*GlyFrame) callconv(.c) c_int,
};

extern fn dlopen(filename: [*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern fn dlclose(handle: ?*anyopaque) c_int;
const RTLD_LAZY: c_int = 1;

var load_lock = std.atomic.Value(u8).init(0);
var load_attempted = false;
var loaded_api: ?Api = null;

fn symbol(comptime T: type, handle: *anyopaque, name: [*:0]const u8) ?T {
    return @ptrCast(@alignCast(dlsym(handle, name) orelse return null));
}

fn loadApi() ?Api {
    if (!platform.is_linux) return null;
    const handle = dlopen("libglycin-2.so.0", RTLD_LAZY) orelse dlopen("libglycin-2.so", RTLD_LAZY) orelse return null;
    var keep = false;
    defer {
        if (!keep) _ = dlclose(handle);
    }
    const loaded = Api{
        .handle = handle,
        .loader_new_bytes = symbol(@FieldType(Api, "loader_new_bytes"), handle, "gly_loader_new_for_bytes") orelse return null,
        .loader_set_formats = symbol(@FieldType(Api, "loader_set_formats"), handle, "gly_loader_set_accepted_memory_formats") orelse return null,
        .loader_load = symbol(@FieldType(Api, "loader_load"), handle, "gly_loader_load") orelse return null,
        .image_width = symbol(@FieldType(Api, "image_width"), handle, "gly_image_get_width") orelse return null,
        .image_height = symbol(@FieldType(Api, "image_height"), handle, "gly_image_get_height") orelse return null,
        .image_next_frame = symbol(@FieldType(Api, "image_next_frame"), handle, "gly_image_next_frame") orelse return null,
        .frame_width = symbol(@FieldType(Api, "frame_width"), handle, "gly_frame_get_width") orelse return null,
        .frame_height = symbol(@FieldType(Api, "frame_height"), handle, "gly_frame_get_height") orelse return null,
        .frame_stride = symbol(@FieldType(Api, "frame_stride"), handle, "gly_frame_get_stride") orelse return null,
        .frame_bytes = symbol(@FieldType(Api, "frame_bytes"), handle, "gly_frame_get_buf_bytes") orelse return null,
        .frame_format = symbol(@FieldType(Api, "frame_format"), handle, "gly_frame_get_memory_format") orelse return null,
    };
    keep = true;
    return loaded;
}

fn api() ?Api {
    while (load_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {}
    defer load_lock.store(0, .release);
    if (!load_attempted) {
        loaded_api = loadApi();
        load_attempted = true;
    }
    return loaded_api;
}

pub fn glycinAvailable() bool {
    return api() != null;
}

pub fn decodeBytes(allocator: std.mem.Allocator, bytes: []const u8, max_pixels: usize) Error!Decoded {
    if (api()) |gly| return decodeGlycin(allocator, bytes, max_pixels, gly);
    return decodePixbuf(allocator, bytes, max_pixels);
}

fn checkedPixels(width: u32, height: u32, max_pixels: usize) Error!usize {
    if (width == 0 or height == 0) return Error.DecodeFailed;
    const pixels = std.math.mul(usize, width, height) catch return Error.TooLarge;
    if (pixels > max_pixels) return Error.TooLarge;
    return pixels;
}

fn decodeGlycin(allocator: std.mem.Allocator, bytes: []const u8, max_pixels: usize, gly: Api) Error!Decoded {
    const source = c.g_bytes_new(bytes.ptr, bytes.len) orelse return Error.OutOfMemory;
    defer c.g_bytes_unref(source);
    const loader = gly.loader_new_bytes(source) orelse return Error.DecodeFailed;
    defer c.g_object_unref(@ptrCast(loader));
    gly.loader_set_formats(loader, GLY_RGBA_SELECTION);
    var gerr: ?*c.GError = null;
    const image = gly.loader_load(loader, &gerr) orelse {
        if (gerr) |err| c.g_error_free(err);
        return Error.DecodeFailed;
    };
    defer c.g_object_unref(@ptrCast(image));
    const early_width = gly.image_width(image);
    const early_height = gly.image_height(image);
    if (early_width != 0 and early_height != 0)
        _ = try checkedPixels(early_width, early_height, max_pixels);
    const frame = gly.image_next_frame(image, &gerr) orelse {
        if (gerr) |err| c.g_error_free(err);
        return Error.DecodeFailed;
    };
    defer c.g_object_unref(@ptrCast(frame));
    if (gly.frame_format(frame) != GLY_RGBA_FORMAT) return Error.UnsupportedPixelFormat;
    const width = gly.frame_width(frame);
    const height = gly.frame_height(frame);
    const pixels = try checkedPixels(width, height, max_pixels);
    const row_bytes = std.math.mul(usize, width, 4) catch return Error.TooLarge;
    const stride: usize = gly.frame_stride(frame);
    if (stride < row_bytes) return Error.DecodeFailed;
    const payload = gly.frame_bytes(frame) orelse return Error.DecodeFailed;
    var payload_len: usize = 0;
    const raw = c.g_bytes_get_data(payload, &payload_len) orelse return Error.DecodeFailed;
    const required = std.math.mul(usize, stride, height) catch return Error.TooLarge;
    if (payload_len < required) return Error.DecodeFailed;
    const out = allocator.alloc(u8, pixels * 4) catch return Error.OutOfMemory;
    const src: [*]const u8 = @ptrCast(raw);
    for (0..height) |row| {
        @memcpy(out[row * row_bytes ..][0..row_bytes], src[row * stride ..][0..row_bytes]);
    }
    return .{ .rgba = out, .width = width, .height = height, .backend = .glycin };
}

const PixbufLimit = struct {
    max_pixels: usize,
    too_large: bool = false,
};

fn onPixbufSizePrepared(loader: *c.GdkPixbufLoader, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) void {
    const limit: *PixbufLimit = @ptrCast(@alignCast(user.?));
    if (width <= 0 or height <= 0) return;
    const pixels = std.math.mul(usize, @intCast(width), @intCast(height)) catch limit.max_pixels +| 1;
    if (pixels <= limit.max_pixels) return;
    limit.too_large = true;
    // The signal fires after the header is parsed but before the full
    // pixbuf is allocated. Keep the decoder's provisional allocation tiny;
    // its output is discarded after close.
    c.gdk_pixbuf_loader_set_size(loader, 1, 1);
}

fn decodePixbuf(allocator: std.mem.Allocator, bytes: []const u8, max_pixels: usize) Error!Decoded {
    const loader = c.gdk_pixbuf_loader_new() orelse return Error.OutOfMemory;
    defer c.g_object_unref(@ptrCast(loader));
    var limit = PixbufLimit{ .max_pixels = max_pixels };
    _ = c.g_signal_connect_data(loader, "size-prepared", @ptrCast(&onPixbufSizePrepared), @ptrCast(&limit), null, c.G_CONNECT_DEFAULT);
    const wrote = c.gdk_pixbuf_loader_write(loader, bytes.ptr, bytes.len, null);
    const closed = c.gdk_pixbuf_loader_close(loader, null);
    if (limit.too_large) return Error.TooLarge;
    if (wrote == 0 or closed == 0) return Error.DecodeFailed;
    const raw = c.gdk_pixbuf_loader_get_pixbuf(loader) orelse return Error.DecodeFailed;
    _ = try checkedPixels(@intCast(c.gdk_pixbuf_get_width(raw)), @intCast(c.gdk_pixbuf_get_height(raw)), max_pixels);
    const oriented = c.gdk_pixbuf_apply_embedded_orientation(raw) orelse return Error.DecodeFailed;
    defer c.g_object_unref(@ptrCast(oriented));
    const width: u32 = @intCast(c.gdk_pixbuf_get_width(oriented));
    const height: u32 = @intCast(c.gdk_pixbuf_get_height(oriented));
    const pixels = try checkedPixels(width, height, max_pixels);
    if (c.gdk_pixbuf_get_bits_per_sample(oriented) != 8 or c.gdk_pixbuf_get_colorspace(oriented) != c.GDK_COLORSPACE_RGB)
        return Error.UnsupportedPixelFormat;
    const channels: usize = @intCast(c.gdk_pixbuf_get_n_channels(oriented));
    if (channels != 3 and channels != 4) return Error.UnsupportedPixelFormat;
    const stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(oriented));
    const source = c.gdk_pixbuf_get_pixels(oriented) orelse return Error.DecodeFailed;
    const out = allocator.alloc(u8, pixels * 4) catch return Error.OutOfMemory;
    for (0..height) |y| {
        for (0..width) |x| {
            const si = y * stride + x * channels;
            const di = (y * @as(usize, width) + x) * 4;
            out[di] = source[si];
            out[di + 1] = source[si + 1];
            out[di + 2] = source[si + 2];
            out[di + 3] = if (channels == 4) source[si + 3] else 255;
        }
    }
    return .{ .rgba = out, .width = width, .height = height, .backend = .gdk_pixbuf };
}

test "image decoder rejects impossible pixel budgets before allocation" {
    try std.testing.expectError(Error.TooLarge, checkedPixels(4096, 4096, 1024));
    try std.testing.expectError(Error.DecodeFailed, checkedPixels(0, 12, 1024));
}

test "image decoder produces normalized RGBA through the available backend" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 128, 255, 64 };
    const encoded = try @import("../util/png.zig").encodeRgba(allocator, &pixels, 2, 1);
    defer allocator.free(encoded);
    try std.testing.expectError(Error.TooLarge, decodeBytes(allocator, encoded, 1));
    var decoded = try decodeBytes(allocator, encoded, 2);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 1), decoded.height);
    try std.testing.expectEqualSlices(u8, &pixels, decoded.rgba);
}
