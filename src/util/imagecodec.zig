//! Runtime-loaded JPEG XL/WebP transport for bounded RGBA previews.
//! Neither codec becomes an ELF dependency of the mux daemon.

const std = @import("std");

pub const Codec = enum { jxl, webp };
pub const Encoded = struct { codec: Codec, bytes: []u8 };
pub const Decoded = struct { rgba: []u8, width: u32, height: u32 };
pub const Error = error{ NoCodec, EncodeFailed, DecodeFailed, TooLarge, OutOfMemory };

const MAX_JXL_VERSION: u32 = 13_999;
const JXL_ENC_SUCCESS = 0;
const JXL_ENC_NEED_MORE_OUTPUT = 2;
const JXL_DEC_SUCCESS = 0;
const JXL_DEC_NEED_MORE_INPUT = 2;
const JXL_DEC_NEED_IMAGE_OUT_BUFFER = 5;
const JXL_DEC_BASIC_INFO = 0x40;
const JXL_DEC_FULL_IMAGE = 0x1000;
const JXL_TYPE_UINT8 = 2;
const JXL_NATIVE_ENDIAN = 0;
const JXL_ENC_FRAME_SETTING_EFFORT = 0;

const JxlPreviewHeader = extern struct { xsize: u32, ysize: u32 };
const JxlAnimationHeader = extern struct {
    tps_numerator: u32,
    tps_denominator: u32,
    num_loops: u32,
    have_timecodes: c_int,
};
const JxlBasicInfo = extern struct {
    have_container: c_int,
    xsize: u32,
    ysize: u32,
    bits_per_sample: u32,
    exponent_bits_per_sample: u32,
    intensity_target: f32,
    min_nits: f32,
    relative_to_max_display: c_int,
    linear_below: f32,
    uses_original_profile: c_int,
    have_preview: c_int,
    have_animation: c_int,
    orientation: c_int,
    num_color_channels: u32,
    num_extra_channels: u32,
    alpha_bits: u32,
    alpha_exponent_bits: u32,
    alpha_premultiplied: c_int,
    preview: JxlPreviewHeader,
    animation: JxlAnimationHeader,
    intrinsic_xsize: u32,
    intrinsic_ysize: u32,
    padding: [100]u8,
};
const JxlColorEncoding = extern struct {
    color_space: c_int,
    white_point: c_int,
    white_point_xy: [2]f64,
    primaries: c_int,
    primaries_red_xy: [2]f64,
    primaries_green_xy: [2]f64,
    primaries_blue_xy: [2]f64,
    transfer_function: c_int,
    gamma: f64,
    rendering_intent: c_int,
};
const JxlPixelFormat = extern struct {
    num_channels: u32,
    data_type: c_int,
    endianness: c_int,
    @"align": usize,
};

comptime {
    if (@sizeOf(JxlBasicInfo) != 204 or @offsetOf(JxlBasicInfo, "xsize") != 4 or
        @offsetOf(JxlBasicInfo, "alpha_bits") != 60 or @offsetOf(JxlBasicInfo, "padding") != 104)
        @compileError("unexpected JxlBasicInfo ABI");
    if (@sizeOf(JxlColorEncoding) != 104 or @sizeOf(JxlPixelFormat) != 24)
        @compileError("unexpected libjxl color/pixel ABI");
}

const JxlApi = struct {
    handle: *anyopaque,
    encoder_version: *const fn () callconv(.c) u32,
    encoder_create: *const fn (?*const anyopaque) callconv(.c) ?*anyopaque,
    encoder_destroy: *const fn (?*anyopaque) callconv(.c) void,
    encoder_init_basic: *const fn (*JxlBasicInfo) callconv(.c) void,
    encoder_set_basic: *const fn (?*anyopaque, *const JxlBasicInfo) callconv(.c) c_int,
    color_srgb: *const fn (*JxlColorEncoding, c_int) callconv(.c) void,
    encoder_set_color: *const fn (?*anyopaque, *const JxlColorEncoding) callconv(.c) c_int,
    settings_create: *const fn (?*anyopaque, ?*const anyopaque) callconv(.c) ?*anyopaque,
    set_option: *const fn (?*anyopaque, c_int, i64) callconv(.c) c_int,
    set_distance: *const fn (?*anyopaque, f32) callconv(.c) c_int,
    set_extra_distance: *const fn (?*anyopaque, usize, f32) callconv(.c) c_int,
    add_frame: *const fn (?*const anyopaque, *const JxlPixelFormat, *const anyopaque, usize) callconv(.c) c_int,
    close_input: *const fn (?*anyopaque) callconv(.c) void,
    process_output: *const fn (?*anyopaque, *[*]u8, *usize) callconv(.c) c_int,
    decoder_version: *const fn () callconv(.c) u32,
    decoder_create: *const fn (?*const anyopaque) callconv(.c) ?*anyopaque,
    decoder_destroy: *const fn (?*anyopaque) callconv(.c) void,
    decoder_subscribe: *const fn (?*anyopaque, c_int) callconv(.c) c_int,
    decoder_set_input: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) c_int,
    decoder_close_input: *const fn (?*anyopaque) callconv(.c) void,
    decoder_process: *const fn (?*anyopaque) callconv(.c) c_int,
    decoder_get_basic: *const fn (?*const anyopaque, *JxlBasicInfo) callconv(.c) c_int,
    decoder_buffer_size: *const fn (?*const anyopaque, *const JxlPixelFormat, *usize) callconv(.c) c_int,
    decoder_set_buffer: *const fn (?*anyopaque, *const JxlPixelFormat, *anyopaque, usize) callconv(.c) c_int,
};

const WebpApi = struct {
    handle: *anyopaque,
    encode: *const fn ([*]const u8, c_int, c_int, c_int, f32, *?[*]u8) callconv(.c) usize,
    free: *const fn (?*anyopaque) callconv(.c) void,
    get_info: *const fn ([*]const u8, usize, ?*c_int, ?*c_int) callconv(.c) c_int,
    decode_into: *const fn ([*]const u8, usize, [*]u8, usize, c_int) callconv(.c) ?[*]u8,
};

extern fn dlopen(filename: [*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern fn dlclose(handle: ?*anyopaque) c_int;
const RTLD_LAZY: c_int = 1;

var load_attempted = false;
var jxl_api: ?JxlApi = null;
var webp_api: ?WebpApi = null;
/// Spinlock (Zig 0.16 std.Thread has no Mutex; this module keeps no
/// libc module dependency). Contention is a first-probe race only.
var load_lock = std.atomic.Value(u8).init(0);

fn sym(comptime T: type, handle: *anyopaque, name: [*:0]const u8) ?T {
    // dlsym returns *anyopaque (align 1); function pointers have a
    // real alignment on aarch64, so the cast needs @alignCast.
    return @ptrCast(@alignCast(dlsym(handle, name) orelse return null));
}

fn loadOne(names: []const [*:0]const u8) ?*anyopaque {
    for (names) |name| if (dlopen(name, RTLD_LAZY)) |handle| return handle;
    return null;
}

fn loadJxl() ?JxlApi {
    const h = loadOne(&.{
        "libjxl.so.0.12",    "libjxl.so.0.11", "libjxl.so.0.10", "libjxl.so.0.9",
        "libjxl.so.0.8",     "libjxl.so.0.7",  "libjxl.so",      "libjxl.0.12.dylib",
        "libjxl.0.11.dylib", "libjxl.dylib",
    }) orelse return null;
    var keep = false;
    defer {
        if (!keep) _ = dlclose(h);
    }
    const api = JxlApi{
        .handle = h,
        .encoder_version = sym(@FieldType(JxlApi, "encoder_version"), h, "JxlEncoderVersion") orelse return null,
        .encoder_create = sym(@FieldType(JxlApi, "encoder_create"), h, "JxlEncoderCreate") orelse return null,
        .encoder_destroy = sym(@FieldType(JxlApi, "encoder_destroy"), h, "JxlEncoderDestroy") orelse return null,
        .encoder_init_basic = sym(@FieldType(JxlApi, "encoder_init_basic"), h, "JxlEncoderInitBasicInfo") orelse return null,
        .encoder_set_basic = sym(@FieldType(JxlApi, "encoder_set_basic"), h, "JxlEncoderSetBasicInfo") orelse return null,
        .color_srgb = sym(@FieldType(JxlApi, "color_srgb"), h, "JxlColorEncodingSetToSRGB") orelse return null,
        .encoder_set_color = sym(@FieldType(JxlApi, "encoder_set_color"), h, "JxlEncoderSetColorEncoding") orelse return null,
        .settings_create = sym(@FieldType(JxlApi, "settings_create"), h, "JxlEncoderFrameSettingsCreate") orelse return null,
        .set_option = sym(@FieldType(JxlApi, "set_option"), h, "JxlEncoderFrameSettingsSetOption") orelse return null,
        .set_distance = sym(@FieldType(JxlApi, "set_distance"), h, "JxlEncoderSetFrameDistance") orelse return null,
        .set_extra_distance = sym(@FieldType(JxlApi, "set_extra_distance"), h, "JxlEncoderSetExtraChannelDistance") orelse return null,
        .add_frame = sym(@FieldType(JxlApi, "add_frame"), h, "JxlEncoderAddImageFrame") orelse return null,
        .close_input = sym(@FieldType(JxlApi, "close_input"), h, "JxlEncoderCloseInput") orelse return null,
        .process_output = sym(@FieldType(JxlApi, "process_output"), h, "JxlEncoderProcessOutput") orelse return null,
        .decoder_version = sym(@FieldType(JxlApi, "decoder_version"), h, "JxlDecoderVersion") orelse return null,
        .decoder_create = sym(@FieldType(JxlApi, "decoder_create"), h, "JxlDecoderCreate") orelse return null,
        .decoder_destroy = sym(@FieldType(JxlApi, "decoder_destroy"), h, "JxlDecoderDestroy") orelse return null,
        .decoder_subscribe = sym(@FieldType(JxlApi, "decoder_subscribe"), h, "JxlDecoderSubscribeEvents") orelse return null,
        .decoder_set_input = sym(@FieldType(JxlApi, "decoder_set_input"), h, "JxlDecoderSetInput") orelse return null,
        .decoder_close_input = sym(@FieldType(JxlApi, "decoder_close_input"), h, "JxlDecoderCloseInput") orelse return null,
        .decoder_process = sym(@FieldType(JxlApi, "decoder_process"), h, "JxlDecoderProcessInput") orelse return null,
        .decoder_get_basic = sym(@FieldType(JxlApi, "decoder_get_basic"), h, "JxlDecoderGetBasicInfo") orelse return null,
        .decoder_buffer_size = sym(@FieldType(JxlApi, "decoder_buffer_size"), h, "JxlDecoderImageOutBufferSize") orelse return null,
        .decoder_set_buffer = sym(@FieldType(JxlApi, "decoder_set_buffer"), h, "JxlDecoderSetImageOutBuffer") orelse return null,
    };
    const ev = api.encoder_version();
    const dv = api.decoder_version();
    if (ev < 7000 or ev > MAX_JXL_VERSION or dv != ev) return null;
    keep = true;
    return api;
}

fn loadWebp() ?WebpApi {
    const h = loadOne(&.{ "libwebp.so.7", "libwebp.so", "libwebp.7.dylib", "libwebp.dylib" }) orelse return null;
    var keep = false;
    defer {
        if (!keep) _ = dlclose(h);
    }
    const api = WebpApi{
        .handle = h,
        .encode = sym(@FieldType(WebpApi, "encode"), h, "WebPEncodeRGBA") orelse return null,
        .free = sym(@FieldType(WebpApi, "free"), h, "WebPFree") orelse return null,
        .get_info = sym(@FieldType(WebpApi, "get_info"), h, "WebPGetInfo") orelse return null,
        .decode_into = sym(@FieldType(WebpApi, "decode_into"), h, "WebPDecodeRGBAInto") orelse return null,
    };
    keep = true;
    return api;
}

const Apis = struct { jxl: ?JxlApi, webp: ?WebpApi };

/// Re-probes while NOTHING loaded: installing libjxl/libwebp and
/// retrying then works without restarting the process. Once a
/// library is in, the result is final (a lib in use is never
/// reloaded). Returns COPIES taken under the mutex so concurrent
/// callers (GUI main thread + thumb worker) never read a mid-store
/// global. A failed dlopen re-probe costs microseconds per call.
fn ensureLoaded() Apis {
    while (load_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {}
    defer load_lock.store(0, .release);
    if (!load_attempted or (jxl_api == null and webp_api == null)) {
        jxl_api = loadJxl();
        webp_api = loadWebp();
        load_attempted = true;
    }
    return .{ .jxl = jxl_api, .webp = webp_api };
}

pub fn capabilities() []const u8 {
    const apis = ensureLoaded();
    if (apis.jxl != null and apis.webp != null) return "jxl,webp";
    if (apis.jxl != null) return "jxl";
    if (apis.webp != null) return "webp";
    return "";
}

pub fn wanted(spec: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |part| if (std.mem.eql(u8, part, name)) return true;
    return false;
}

pub fn encodePreferred(allocator: std.mem.Allocator, rgba: []const u8, width: u32, height: u32, receiver: []const u8, max_bytes: usize) Error!Encoded {
    const expected = try checkedEncodeSize(width, height);
    if (rgba.len < expected) return Error.EncodeFailed;
    if (max_bytes == 0) return Error.TooLarge;
    const apis = ensureLoaded();
    if (wanted(receiver, "jxl")) if (apis.jxl) |*api|
        if (encodeJxl(allocator, api, rgba, width, height, max_bytes)) |bytes|
            return .{ .codec = .jxl, .bytes = bytes }
        else |_| {};
    if (wanted(receiver, "webp")) if (apis.webp) |*api|
        if (encodeWebp(allocator, api, rgba, width, height, max_bytes)) |bytes|
            return .{ .codec = .webp, .bytes = bytes }
        else |_| {};
    return Error.NoCodec;
}

fn pixelFormat() JxlPixelFormat {
    return .{ .num_channels = 4, .data_type = JXL_TYPE_UINT8, .endianness = JXL_NATIVE_ENDIAN, .@"align" = 0 };
}

fn checkedEncodeSize(width: u32, height: u32) Error!usize {
    if (width == 0 or height == 0 or width > std.math.maxInt(c_int) or height > std.math.maxInt(c_int))
        return Error.EncodeFailed;
    if (width > @as(u32, @intCast(std.math.maxInt(c_int))) / 4) return Error.EncodeFailed;
    const pixels = std.math.mul(usize, width, height) catch return Error.TooLarge;
    return std.math.mul(usize, pixels, 4) catch Error.TooLarge;
}

fn encodeJxl(allocator: std.mem.Allocator, api: *const JxlApi, rgba: []const u8, width: u32, height: u32, max_bytes: usize) Error![]u8 {
    const input_len = try checkedEncodeSize(width, height);
    if (rgba.len < input_len) return Error.EncodeFailed;
    const enc = api.encoder_create(null) orelse return Error.EncodeFailed;
    defer api.encoder_destroy(enc);
    var info: JxlBasicInfo = undefined;
    api.encoder_init_basic(&info);
    info.xsize = width;
    info.ysize = height;
    info.bits_per_sample = 8;
    info.num_color_channels = 3;
    info.num_extra_channels = 1;
    info.alpha_bits = 8;
    info.alpha_premultiplied = 0;
    if (api.encoder_set_basic(enc, &info) != JXL_ENC_SUCCESS) return Error.EncodeFailed;
    var color: JxlColorEncoding = undefined;
    api.color_srgb(&color, 0);
    if (api.encoder_set_color(enc, &color) != JXL_ENC_SUCCESS) return Error.EncodeFailed;
    const settings = api.settings_create(enc, null) orelse return Error.EncodeFailed;
    // Effort 4: interactive previews; the default (7) costs several
    // times the encode time for a marginal size win at distance 1.0.
    _ = api.set_option(settings, JXL_ENC_FRAME_SETTING_EFFORT, 4);
    if (api.set_distance(settings, 1.0) != JXL_ENC_SUCCESS or
        api.set_extra_distance(settings, 0, 0.0) != JXL_ENC_SUCCESS) return Error.EncodeFailed;
    const fmt = pixelFormat();
    if (api.add_frame(settings, &fmt, rgba.ptr, input_len) != JXL_ENC_SUCCESS)
        return Error.EncodeFailed;
    api.close_input(enc);
    const scratch = allocator.alloc(u8, max_bytes) catch return Error.OutOfMemory;
    defer allocator.free(scratch);
    var next: [*]u8 = scratch.ptr;
    var avail = scratch.len;
    while (true) {
        const status = api.process_output(enc, &next, &avail);
        if (status == JXL_ENC_SUCCESS) break;
        if (status != JXL_ENC_NEED_MORE_OUTPUT) return Error.EncodeFailed;
        if (avail == 0) return Error.TooLarge;
    }
    const used = scratch.len - avail;
    return allocator.dupe(u8, scratch[0..used]) catch Error.OutOfMemory;
}

fn encodeWebp(allocator: std.mem.Allocator, api: *const WebpApi, rgba: []const u8, width: u32, height: u32, max_bytes: usize) Error![]u8 {
    const input_len = try checkedEncodeSize(width, height);
    if (rgba.len < input_len) return Error.EncodeFailed;
    var output: ?[*]u8 = null;
    const n = api.encode(rgba.ptr, @intCast(width), @intCast(height), @intCast(width * 4), 92.0, &output);
    const bytes = output orelse return Error.EncodeFailed;
    defer api.free(bytes);
    if (n == 0) return Error.EncodeFailed;
    if (n > max_bytes) return Error.TooLarge;
    return allocator.dupe(u8, bytes[0..n]) catch Error.OutOfMemory;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, max_pixels: usize) Error!Decoded {
    const apis = ensureLoaded();
    if (isJxl(bytes)) {
        const api = if (apis.jxl) |*a| a else return Error.NoCodec;
        return decodeJxl(allocator, api, bytes, max_pixels);
    }
    if (isWebp(bytes)) {
        const api = if (apis.webp) |*a| a else return Error.NoCodec;
        return decodeWebp(allocator, api, bytes, max_pixels);
    }
    return Error.DecodeFailed;
}

fn isJxl(bytes: []const u8) bool {
    return (bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0x0a) or
        (bytes.len >= 12 and std.mem.eql(u8, bytes[0..12], "\x00\x00\x00\x0cJXL \r\n\x87\n"));
}

fn isWebp(bytes: []const u8) bool {
    return bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP");
}

fn checkedImageSize(width: c_int, height: c_int, max_pixels: usize) Error!usize {
    if (width <= 0 or height <= 0) return Error.DecodeFailed;
    if (width > std.math.maxInt(c_int) / 4) return Error.TooLarge;
    const pixels = std.math.mul(usize, @intCast(width), @intCast(height)) catch return Error.TooLarge;
    if (pixels > max_pixels) return Error.TooLarge;
    return std.math.mul(usize, pixels, 4) catch Error.TooLarge;
}

fn decodeJxl(allocator: std.mem.Allocator, api: *const JxlApi, bytes: []const u8, max_pixels: usize) Error!Decoded {
    const dec = api.decoder_create(null) orelse return Error.DecodeFailed;
    defer api.decoder_destroy(dec);
    if (api.decoder_subscribe(dec, JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS or
        api.decoder_set_input(dec, bytes.ptr, bytes.len) != JXL_DEC_SUCCESS) return Error.DecodeFailed;
    api.decoder_close_input(dec);
    var info: JxlBasicInfo = undefined;
    var rgba: ?[]u8 = null;
    errdefer if (rgba) |p| allocator.free(p);
    var complete = false;
    const fmt = pixelFormat();
    while (true) {
        switch (api.decoder_process(dec)) {
            JXL_DEC_BASIC_INFO => {
                if (api.decoder_get_basic(dec, &info) != JXL_DEC_SUCCESS) return Error.DecodeFailed;
                if (info.xsize > std.math.maxInt(c_int) or info.ysize > std.math.maxInt(c_int))
                    return Error.TooLarge;
                const size = try checkedImageSize(@intCast(info.xsize), @intCast(info.ysize), max_pixels);
                var reported: usize = 0;
                if (api.decoder_buffer_size(dec, &fmt, &reported) != JXL_DEC_SUCCESS or reported != size)
                    return Error.DecodeFailed;
                rgba = allocator.alloc(u8, size) catch return Error.OutOfMemory;
            },
            JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
                const out = rgba orelse return Error.DecodeFailed;
                if (api.decoder_set_buffer(dec, &fmt, out.ptr, out.len) != JXL_DEC_SUCCESS) return Error.DecodeFailed;
            },
            JXL_DEC_FULL_IMAGE => complete = true,
            JXL_DEC_SUCCESS => break,
            JXL_DEC_NEED_MORE_INPUT => return Error.DecodeFailed,
            else => return Error.DecodeFailed,
        }
    }
    if (!complete) return Error.DecodeFailed;
    return .{ .rgba = rgba orelse return Error.DecodeFailed, .width = info.xsize, .height = info.ysize };
}

fn decodeWebp(allocator: std.mem.Allocator, api: *const WebpApi, bytes: []const u8, max_pixels: usize) Error!Decoded {
    var width: c_int = 0;
    var height: c_int = 0;
    if (api.get_info(bytes.ptr, bytes.len, &width, &height) == 0) return Error.DecodeFailed;
    const size = try checkedImageSize(width, height, max_pixels);
    const rgba = allocator.alloc(u8, size) catch return Error.OutOfMemory;
    errdefer allocator.free(rgba);
    if (api.decode_into(bytes.ptr, bytes.len, rgba.ptr, rgba.len, width * 4) == null) return Error.DecodeFailed;
    return .{ .rgba = rgba, .width = @intCast(width), .height = @intCast(height) };
}

test "JPEG XL is preferred over WebP" {
    try std.testing.expect(wanted("jxl,webp", "jxl"));
    try std.testing.expect(wanted("jxl,webp", "webp"));
    try std.testing.expect(!wanted("webp", "jxl"));
}

test "encoder rejects invalid dimensions and output caps before codec dispatch" {
    const t = std.testing;
    try t.expectError(Error.EncodeFailed, encodePreferred(t.allocator, &.{}, 0, 1, "", 1));
    try t.expectError(Error.EncodeFailed, encodePreferred(t.allocator, &.{}, std.math.maxInt(u32), 2, "", 1));
    try t.expectError(Error.TooLarge, encodePreferred(t.allocator, &.{ 0, 0, 0, 0 }, 1, 1, "", 0));
}

test "available preview codecs round-trip RGBA with exact alpha" {
    if (capabilities().len == 0) return error.SkipZigTest;
    const a = std.testing.allocator;
    var rgba: [32 * 24 * 4]u8 = undefined;
    for (0..32 * 24) |i| {
        rgba[i * 4] = @truncate(i * 7);
        rgba[i * 4 + 1] = @truncate(i * 13);
        rgba[i * 4 + 2] = @truncate(i * 29);
        rgba[i * 4 + 3] = @truncate(i * 5);
    }
    const encoded = try encodePreferred(a, &rgba, 32, 24, capabilities(), 1 << 20);
    defer a.free(encoded.bytes);
    if (std.mem.startsWith(u8, capabilities(), "jxl"))
        try std.testing.expectEqual(Codec.jxl, encoded.codec);
    const decoded = try decode(a, encoded.bytes, 32 * 24);
    defer a.free(decoded.rgba);
    try std.testing.expectEqual(@as(u32, 32), decoded.width);
    try std.testing.expectEqual(@as(u32, 24), decoded.height);
    for (0..32 * 24) |i| try std.testing.expectEqual(rgba[i * 4 + 3], decoded.rgba[i * 4 + 3]);
}

test "WebP fallback round-trips dimensions and alpha" {
    const apis = ensureLoaded();
    const api = if (apis.webp) |*loaded| loaded else return error.SkipZigTest;
    const a = std.testing.allocator;
    var rgba: [12 * 9 * 4]u8 = undefined;
    for (0..12 * 9) |i| {
        rgba[i * 4] = @truncate(i * 3);
        rgba[i * 4 + 1] = @truncate(i * 11);
        rgba[i * 4 + 2] = @truncate(i * 19);
        rgba[i * 4 + 3] = @truncate(i * 7);
    }
    const bytes = try encodeWebp(a, api, &rgba, 12, 9, 1 << 20);
    defer a.free(bytes);
    const decoded = try decodeWebp(a, api, bytes, 12 * 9);
    defer a.free(decoded.rgba);
    try std.testing.expectEqual(@as(u32, 12), decoded.width);
    try std.testing.expectEqual(@as(u32, 9), decoded.height);
    for (0..12 * 9) |i| try std.testing.expectEqual(rgba[i * 4 + 3], decoded.rgba[i * 4 + 3]);
}
