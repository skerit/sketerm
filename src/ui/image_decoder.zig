//! GUI-only image decoder boundary with sandboxed Glycin on Linux.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");

pub const Backend = enum { glycin, gdk_pixbuf };

pub const Frame = struct {
    rgba: []u8,
    width: u32,
    height: u32,
    delay_ms: u32 = 0,

    fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.rgba);
    }
};

pub const Decoded = struct {
    frames: []Frame,
    backend: Backend,
    /// Total plays; zero means repeat forever.
    plays: u32 = 1,

    pub fn first(self: *const Decoded) *const Frame {
        return &self.frames[0];
    }

    pub fn animated(self: *const Decoded) bool {
        return self.frames.len > 1;
    }

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        for (self.frames) |*frame| frame.deinit(allocator);
        allocator.free(self.frames);
        self.* = undefined;
    }
};

pub const Options = struct {
    max_pixels: usize,
    max_animation_bytes: usize,
    max_frames: usize = 240,
    cancel_context: ?*anyopaque = null,
    should_cancel: ?*const fn (?*anyopaque) bool = null,

    fn canceled(self: Options) bool {
        return if (self.should_cancel) |callback| callback(self.cancel_context) else false;
    }
};

pub const Error = error{
    DecodeFailed,
    UnsupportedPixelFormat,
    TooLarge,
    Canceled,
    OutOfMemory,
};

const GlyLoader = opaque {};
const GlyImage = opaque {};
const GlyFrame = opaque {};
const GlyFrameRequest = opaque {};
const GLY_RGBA_SELECTION: c_int = 1 << 5;
const GLY_RGBA_FORMAT: c_int = 5;

const Api = struct {
    handle: *anyopaque,
    loader_new_bytes: *const fn (*c.GBytes) callconv(.c) ?*GlyLoader,
    loader_set_formats: *const fn (*GlyLoader, c_int) callconv(.c) void,
    loader_load: *const fn (*GlyLoader, *?*c.GError) callconv(.c) ?*GlyImage,
    image_width: *const fn (*GlyImage) callconv(.c) u32,
    image_height: *const fn (*GlyImage) callconv(.c) u32,
    frame_request_new: *const fn () callconv(.c) ?*GlyFrameRequest,
    frame_request_set_loop: *const fn (*GlyFrameRequest, c.gboolean) callconv(.c) void,
    image_get_frame: *const fn (*GlyImage, *GlyFrameRequest, *?*c.GError) callconv(.c) ?*GlyFrame,
    frame_width: *const fn (*GlyFrame) callconv(.c) u32,
    frame_height: *const fn (*GlyFrame) callconv(.c) u32,
    frame_stride: *const fn (*GlyFrame) callconv(.c) u32,
    frame_bytes: *const fn (*GlyFrame) callconv(.c) ?*c.GBytes,
    frame_format: *const fn (*GlyFrame) callconv(.c) c_int,
    frame_delay: *const fn (*GlyFrame) callconv(.c) i64,
    loader_error_quark: *const fn () callconv(.c) c.GQuark,
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
        .frame_request_new = symbol(@FieldType(Api, "frame_request_new"), handle, "gly_frame_request_new") orelse return null,
        .frame_request_set_loop = symbol(@FieldType(Api, "frame_request_set_loop"), handle, "gly_frame_request_set_loop_animation") orelse return null,
        .image_get_frame = symbol(@FieldType(Api, "image_get_frame"), handle, "gly_image_get_specific_frame") orelse return null,
        .frame_width = symbol(@FieldType(Api, "frame_width"), handle, "gly_frame_get_width") orelse return null,
        .frame_height = symbol(@FieldType(Api, "frame_height"), handle, "gly_frame_get_height") orelse return null,
        .frame_stride = symbol(@FieldType(Api, "frame_stride"), handle, "gly_frame_get_stride") orelse return null,
        .frame_bytes = symbol(@FieldType(Api, "frame_bytes"), handle, "gly_frame_get_buf_bytes") orelse return null,
        .frame_format = symbol(@FieldType(Api, "frame_format"), handle, "gly_frame_get_memory_format") orelse return null,
        .frame_delay = symbol(@FieldType(Api, "frame_delay"), handle, "gly_frame_get_delay") orelse return null,
        .loader_error_quark = symbol(@FieldType(Api, "loader_error_quark"), handle, "gly_loader_error_quark") orelse return null,
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

pub fn decodeBytes(allocator: std.mem.Allocator, bytes: []const u8, options: Options) Error!Decoded {
    if (api()) |gly| return decodeGlycin(allocator, bytes, options, gly);
    return decodePixbuf(allocator, bytes, options);
}

fn checkedPixels(width: u32, height: u32, max_pixels: usize) Error!usize {
    if (width == 0 or height == 0) return Error.DecodeFailed;
    const pixels = std.math.mul(usize, width, height) catch return Error.TooLarge;
    if (pixels > max_pixels) return Error.TooLarge;
    return pixels;
}

fn delayMs(microseconds: i64) u32 {
    if (microseconds <= 0) return 0;
    return @intCast(std.math.clamp(@divTrunc(microseconds + 999, 1000), 10, 10_000));
}

const AnimationMeta = struct {
    frame_count: usize = 0,
    plays: u32 = 0,
};

fn skipGifSubBlocks(bytes: []const u8, start: usize) ?usize {
    var at = start;
    while (at < bytes.len) {
        const len: usize = bytes[at];
        at += 1;
        if (len == 0) return at;
        if (at + len > bytes.len) return null;
        at += len;
    }
    return null;
}

fn gifAnimationMeta(bytes: []const u8) AnimationMeta {
    if (bytes.len < 13 or (!std.mem.eql(u8, bytes[0..6], "GIF87a") and !std.mem.eql(u8, bytes[0..6], "GIF89a"))) return .{};
    var at: usize = 13;
    if (bytes[10] & 0x80 != 0) at += @as(usize, 3) << @intCast((bytes[10] & 0x07) + 1);
    if (at > bytes.len) return .{};
    var frames: usize = 0;
    var plays: u32 = 1;
    while (at < bytes.len) {
        const marker = bytes[at];
        at += 1;
        switch (marker) {
            0x2c => {
                if (at + 9 > bytes.len) break;
                const flags = bytes[at + 8];
                at += 9;
                if (flags & 0x80 != 0) at += @as(usize, 3) << @intCast((flags & 0x07) + 1);
                if (at >= bytes.len) break;
                at += 1; // LZW minimum code size
                at = skipGifSubBlocks(bytes, at) orelse break;
                frames += 1;
            },
            0x21 => {
                if (at >= bytes.len) break;
                const label = bytes[at];
                at += 1;
                if (label == 0xff and at + 12 <= bytes.len and bytes[at] == 11 and
                    (std.mem.eql(u8, bytes[at + 1 .. at + 12], "NETSCAPE2.0") or
                        std.mem.eql(u8, bytes[at + 1 .. at + 12], "ANIMEXTS1.0")))
                {
                    at += 12;
                    if (at + 5 <= bytes.len and bytes[at] == 3 and bytes[at + 1] == 1) {
                        const loops = std.mem.readInt(u16, bytes[at + 2 ..][0..2], .little);
                        plays = if (loops == 0) 0 else @as(u32, loops) + 1;
                    }
                }
                at = skipGifSubBlocks(bytes, at) orelse break;
            },
            0x3b => break,
            else => break,
        }
    }
    return .{ .frame_count = frames, .plays = plays };
}

fn animationMeta(bytes: []const u8) AnimationMeta {
    const gif = gifAnimationMeta(bytes);
    if (gif.frame_count > 0) return gif;
    const png_sig = "\x89PNG\r\n\x1a\n";
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], png_sig)) {
        var at: usize = 8;
        while (at + 12 <= bytes.len) {
            const len: usize = std.mem.readInt(u32, bytes[at..][0..4], .big);
            if (at + 12 + len > bytes.len) break;
            if (std.mem.eql(u8, bytes[at + 4 .. at + 8], "acTL") and len >= 8) return .{
                .frame_count = std.mem.readInt(u32, bytes[at + 8 ..][0..4], .big),
                .plays = std.mem.readInt(u32, bytes[at + 12 ..][0..4], .big),
            };
            at += 12 + len;
        }
    }
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        var at: usize = 12;
        var frames: usize = 0;
        var plays: u32 = 0;
        while (at + 8 <= bytes.len) {
            const len: usize = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
            const padded = len + (len & 1);
            if (at + 8 + padded > bytes.len) break;
            if (std.mem.eql(u8, bytes[at .. at + 4], "ANMF")) frames += 1;
            if (std.mem.eql(u8, bytes[at .. at + 4], "ANIM") and len >= 6)
                plays = std.mem.readInt(u16, bytes[at + 12 ..][0..2], .little);
            at += 8 + padded;
        }
        if (frames > 0) return .{ .frame_count = frames, .plays = plays };
    }
    return .{};
}

fn decodeGlycin(allocator: std.mem.Allocator, bytes: []const u8, options: Options, gly: Api) Error!Decoded {
    const animation = animationMeta(bytes);
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
        _ = try checkedPixels(early_width, early_height, options.max_pixels);
    const request = gly.frame_request_new() orelse return Error.OutOfMemory;
    defer c.g_object_unref(@ptrCast(request));
    gly.frame_request_set_loop(request, 0);

    var frames: std.ArrayList(Frame) = .empty;
    errdefer {
        for (frames.items) |*decoded| decoded.deinit(allocator);
        frames.deinit(allocator);
    }
    var total_bytes: usize = 0;
    while (true) {
        if (options.canceled()) return Error.Canceled;
        gerr = null;
        const raw_frame = gly.image_get_frame(image, request, &gerr) orelse {
            const no_more = if (gerr) |err|
                err.domain == gly.loader_error_quark() and err.code == 2
            else
                false;
            if (gerr) |err| c.g_error_free(err);
            if (frames.items.len > 0 and no_more) break;
            return Error.DecodeFailed;
        };
        defer c.g_object_unref(@ptrCast(raw_frame));
        if (frames.items.len >= options.max_frames) return Error.TooLarge;
        if (gly.frame_format(raw_frame) != GLY_RGBA_FORMAT) return Error.UnsupportedPixelFormat;
        const width = gly.frame_width(raw_frame);
        const height = gly.frame_height(raw_frame);
        const pixels = try checkedPixels(width, height, options.max_pixels);
        const byte_len = std.math.mul(usize, pixels, 4) catch return Error.TooLarge;
        if ((std.math.add(usize, total_bytes, byte_len) catch return Error.TooLarge) > options.max_animation_bytes)
            return Error.TooLarge;
        const row_bytes = std.math.mul(usize, width, 4) catch return Error.TooLarge;
        const stride: usize = gly.frame_stride(raw_frame);
        if (stride < row_bytes) return Error.DecodeFailed;
        const payload = gly.frame_bytes(raw_frame) orelse return Error.DecodeFailed;
        var payload_len: usize = 0;
        const raw = c.g_bytes_get_data(payload, &payload_len) orelse return Error.DecodeFailed;
        const required = std.math.mul(usize, stride, height) catch return Error.TooLarge;
        if (payload_len < required) return Error.DecodeFailed;
        const out = allocator.alloc(u8, byte_len) catch return Error.OutOfMemory;
        const src: [*]const u8 = @ptrCast(raw);
        for (0..height) |row| {
            if (options.canceled()) {
                allocator.free(out);
                return Error.Canceled;
            }
            @memcpy(out[row * row_bytes ..][0..row_bytes], src[row * stride ..][0..row_bytes]);
        }
        const decoded = Frame{
            .rgba = out,
            .width = width,
            .height = height,
            .delay_ms = delayMs(gly.frame_delay(raw_frame)),
        };
        frames.append(allocator, decoded) catch {
            allocator.free(out);
            return Error.OutOfMemory;
        };
        total_bytes += byte_len;
    }
    const animated = frames.items.len > 1;
    return .{
        .frames = frames.toOwnedSlice(allocator) catch return Error.OutOfMemory,
        .backend = .glycin,
        .plays = if (animated) animation.plays else 1,
    };
}

const PixbufLimit = struct {
    max_pixels: usize,
    max_animation_bytes: usize,
    frame_count: usize,
    too_large: bool = false,
};

fn onPixbufSizePrepared(loader: *c.GdkPixbufLoader, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) void {
    const limit: *PixbufLimit = @ptrCast(@alignCast(user.?));
    if (width <= 0 or height <= 0) return;
    const pixels = std.math.mul(usize, @intCast(width), @intCast(height)) catch limit.max_pixels +| 1;
    const frame_bytes = std.math.mul(usize, pixels, 4) catch limit.max_animation_bytes +| 1;
    const animation_bytes = std.math.mul(usize, frame_bytes, @max(limit.frame_count, 1)) catch limit.max_animation_bytes +| 1;
    if (pixels <= limit.max_pixels and animation_bytes <= limit.max_animation_bytes) return;
    limit.too_large = true;
    // The signal fires after the header is parsed but before the full
    // pixbuf is allocated. Keep the decoder's provisional allocation tiny;
    // its output is discarded after close.
    c.gdk_pixbuf_loader_set_size(loader, 1, 1);
}

fn copyPixbuf(allocator: std.mem.Allocator, raw: *c.GdkPixbuf, options: Options, delay_ms: u32) Error!Frame {
    const oriented = c.gdk_pixbuf_apply_embedded_orientation(raw) orelse return Error.DecodeFailed;
    defer c.g_object_unref(@ptrCast(oriented));
    const width: u32 = @intCast(c.gdk_pixbuf_get_width(oriented));
    const height: u32 = @intCast(c.gdk_pixbuf_get_height(oriented));
    const pixels = try checkedPixels(width, height, options.max_pixels);
    if (c.gdk_pixbuf_get_bits_per_sample(oriented) != 8 or c.gdk_pixbuf_get_colorspace(oriented) != c.GDK_COLORSPACE_RGB)
        return Error.UnsupportedPixelFormat;
    const channels: usize = @intCast(c.gdk_pixbuf_get_n_channels(oriented));
    if (channels != 3 and channels != 4) return Error.UnsupportedPixelFormat;
    const stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(oriented));
    const source = c.gdk_pixbuf_get_pixels(oriented) orelse return Error.DecodeFailed;
    const out = allocator.alloc(u8, pixels * 4) catch return Error.OutOfMemory;
    for (0..height) |y| {
        if (options.canceled()) {
            allocator.free(out);
            return Error.Canceled;
        }
        for (0..width) |x| {
            const si = y * stride + x * channels;
            const di = (y * @as(usize, width) + x) * 4;
            out[di] = source[si];
            out[di + 1] = source[si + 1];
            out[di + 2] = source[si + 2];
            out[di + 3] = if (channels == 4) source[si + 3] else 255;
        }
    }
    return .{ .rgba = out, .width = width, .height = height, .delay_ms = delay_ms };
}

fn decodePixbuf(allocator: std.mem.Allocator, bytes: []const u8, options: Options) Error!Decoded {
    const animation_meta = animationMeta(bytes);
    if (animation_meta.frame_count > options.max_frames) return Error.TooLarge;
    const loader = c.gdk_pixbuf_loader_new() orelse return Error.OutOfMemory;
    defer c.g_object_unref(@ptrCast(loader));
    var limit = PixbufLimit{
        .max_pixels = options.max_pixels,
        .max_animation_bytes = options.max_animation_bytes,
        .frame_count = animation_meta.frame_count,
    };
    _ = c.g_signal_connect_data(loader, "size-prepared", @ptrCast(&onPixbufSizePrepared), @ptrCast(&limit), null, c.G_CONNECT_DEFAULT);
    const wrote = c.gdk_pixbuf_loader_write(loader, bytes.ptr, bytes.len, null);
    const closed = c.gdk_pixbuf_loader_close(loader, null);
    if (limit.too_large) return Error.TooLarge;
    if (wrote == 0 or closed == 0) return Error.DecodeFailed;
    const animation = c.gdk_pixbuf_loader_get_animation(loader) orelse return Error.DecodeFailed;
    var frames: std.ArrayList(Frame) = .empty;
    errdefer {
        for (frames.items) |*frame| frame.deinit(allocator);
        frames.deinit(allocator);
    }
    if (c.gdk_pixbuf_animation_is_static_image(animation) != 0) {
        const raw = c.gdk_pixbuf_animation_get_static_image(animation) orelse return Error.DecodeFailed;
        const frame = try copyPixbuf(allocator, raw, options, 0);
        try frames.append(allocator, frame);
    } else {
        var now = c.GTimeVal{ .tv_sec = 0, .tv_usec = 0 };
        const iter = c.gdk_pixbuf_animation_get_iter(animation, &now) orelse return Error.DecodeFailed;
        defer c.g_object_unref(@ptrCast(iter));
        var total_bytes: usize = 0;
        const expected_frames = animation_meta.frame_count;
        if (expected_frames < 2 or expected_frames > options.max_frames) return Error.TooLarge;
        for (0..expected_frames) |frame_index| {
            if (options.canceled()) return Error.Canceled;
            const raw = c.gdk_pixbuf_animation_iter_get_pixbuf(iter) orelse return Error.DecodeFailed;
            const raw_delay = c.gdk_pixbuf_animation_iter_get_delay_time(iter);
            const delay: u32 = @intCast(std.math.clamp(if (raw_delay < 0) 0 else raw_delay, 10, 10_000));
            var frame = try copyPixbuf(allocator, raw, options, delay);
            const byte_len = frame.rgba.len;
            if ((std.math.add(usize, total_bytes, byte_len) catch return Error.TooLarge) > options.max_animation_bytes) {
                frame.deinit(allocator);
                return Error.TooLarge;
            }
            frames.append(allocator, frame) catch {
                frame.deinit(allocator);
                return Error.OutOfMemory;
            };
            total_bytes += byte_len;
            if (frame_index + 1 == expected_frames) break;
            if (raw_delay < 0) return Error.DecodeFailed;
            const advance_ms = @max(raw_delay, 1);
            c.g_time_val_add(&now, @as(c.glong, @intCast(advance_ms)) * 1000 + 1);
            _ = c.gdk_pixbuf_animation_iter_advance(iter, &now);
        }
    }
    const animated = frames.items.len > 1;
    return .{
        .frames = frames.toOwnedSlice(allocator) catch return Error.OutOfMemory,
        .backend = .gdk_pixbuf,
        .plays = if (animated) animation_meta.plays else 1,
    };
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
    try std.testing.expectError(Error.TooLarge, decodeBytes(allocator, encoded, .{ .max_pixels = 1, .max_animation_bytes = 8 }));
    var decoded = try decodeBytes(allocator, encoded, .{ .max_pixels = 2, .max_animation_bytes = 8 });
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.frames.len);
    try std.testing.expectEqual(@as(u32, 2), decoded.first().width);
    try std.testing.expectEqual(@as(u32, 1), decoded.first().height);
    try std.testing.expectEqualSlices(u8, &pixels, decoded.first().rgba);
}

test "image decoder preserves common animated image frames" {
    const allocator = std.testing.allocator;
    const fixtures = [_][]const u8{
        "R0lGODlhAgABAPAAAP8AAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQAAAAAACwAAAAAAgABAAACAgQKACH5BAAKAAAALAAAAAACAAEAgAAA/wAAAAICBAoAOw==",
        "UklGRsAAAABXRUJQVlA4WAoAAAACAAAAAQAAAAAAQU5JTQYAAAD/////AABBTk1GSAAAAAAAAAAAAAEAAAAAAGQAAAJWUDggMAAAANABAJ0BKgIAAQACADQloAJ0ugH4AAOwAP7wxAv/ILlhdcjX/yA/5Af8gP/48gAAAEFOTUZEAAAAAAAAAAAAAQAAAAAAZAAAAFZQOCAsAAAAlAEAnQEqAgABAAAANCWgAnS6AAOYAP75k2//kB//kB//kB//ID/iF3sgMAA=",
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAACXBIWXMAAAAAAAAAAQCEeRdzAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAACAAAAAQAAAAAAAAAAAAEAGQAA50mrUAAAAA9JREFUeJxj/MvAyMDAAAAGAAEAuVLGwQAAABpmY1RMAAAAAQAAAAIAAAABAAAAAAAAAAAAAQAZAAB8OkGEAAAAE2ZkQVQAAAACeJxjZGT4y8DAAAAECAEAmCREywAAAABJRU5ErkJggg==",
    };
    for (fixtures, 0..) |encoded, fixture_index| {
        const decoder64 = std.base64.standard.Decoder;
        const bytes = try allocator.alloc(u8, try decoder64.calcSizeForSlice(encoded));
        defer allocator.free(bytes);
        try decoder64.decode(bytes, encoded);
        var image = try decodeBytes(allocator, bytes, .{
            .max_pixels = 16,
            .max_animation_bytes = 4096,
            .max_frames = 8,
        });
        defer image.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), image.frames.len);
        try std.testing.expectEqual(@as(u32, 0), image.plays);
        try std.testing.expect(image.frames[0].delay_ms > 0);
        try std.testing.expect(image.frames[1].delay_ms > 0);
        if (fixture_index == 0) {
            var fallback = try decodePixbuf(allocator, bytes, .{
                .max_pixels = 16,
                .max_animation_bytes = 4096,
                .max_frames = 8,
            });
            defer fallback.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 2), fallback.frames.len);
        }
    }
}

test "animation metadata distinguishes finite and repeating GIFs" {
    const allocator = std.testing.allocator;
    const once_b64 = "R0lGODlhAgABAPAAAP8AAAAAACH5BAAAAAAALAAAAAACAAEAAAICBAoAIfkEAAoAAAAsAAAAAAIAAQCAAAD/AAAAAgIECgA7";
    const decoder64 = std.base64.standard.Decoder;
    const bytes = try allocator.alloc(u8, try decoder64.calcSizeForSlice(once_b64));
    defer allocator.free(bytes);
    try decoder64.decode(bytes, once_b64);
    const meta = animationMeta(bytes);
    try std.testing.expectEqual(@as(usize, 2), meta.frame_count);
    try std.testing.expectEqual(@as(u32, 1), meta.plays);
}
