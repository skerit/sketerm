//! Optional Linux dma-buf readback through runtime-loaded EGL and GLES.
//!
//! The importer owns a headless ES3 context. Imported file descriptors are
//! borrowed by EGL and remain owned by the caller. Buffers must be destroyed
//! before their importer, and all methods must run on one thread.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const dmabuf = @import("../wlhost/dmabuf.zig");

const option_enabled = if (@hasDecl(build_options, "dmabuf_import"))
    @field(build_options, "dmabuf_import")
else
    false;

pub const enabled = builtin.os.tag == .linux and option_enabled;

pub const DRM_FORMAT_ARGB8888 = dmabuf.DRM_FORMAT_ARGB8888;
pub const DRM_FORMAT_XRGB8888 = dmabuf.DRM_FORMAT_XRGB8888;
pub const FLAG_Y_INVERT = dmabuf.FLAG_Y_INVERT;
pub const Capability = dmabuf.Capability;

pub const Plane = struct {
    fd: c_int,
    offset: u32,
    stride: u32,
    modifier: u64,
};

pub const Import = struct {
    width: u32,
    height: u32,
    format: u32,
    flags: u32 = 0,
    planes: []const Plane,
};

const MAX_DIMENSION = dmabuf.MAX_DIMENSION;
const MAX_STAGING_BYTES: usize = @intCast(dmabuf.MAX_BUFFER_BYTES);
const MAX_QUERY_ITEMS: usize = 4096;

fn validLayout(desc: Import) bool {
    if (desc.width == 0 or desc.height == 0 or
        desc.width > MAX_DIMENSION or desc.height > MAX_DIMENSION or
        desc.planes.len == 0 or desc.planes.len > dmabuf.MAX_PLANES or
        desc.flags & ~FLAG_Y_INVERT != 0)
        return false;
    if (desc.format != DRM_FORMAT_ARGB8888 and desc.format != DRM_FORMAT_XRGB8888)
        return false;
    const modifier = desc.planes[0].modifier;
    if (modifier == dmabuf.DRM_FORMAT_MOD_LINEAR and desc.planes.len != 1)
        return false;
    for (desc.planes, 0..) |plane, index| {
        if (plane.fd < 0 or plane.stride == 0 or
            plane.offset > std.math.maxInt(EglInt) or
            plane.stride > std.math.maxInt(EglInt) or
            plane.modifier != modifier)
            return false;
        if (index == 0 and plane.stride < desc.width * 4) return false;
    }
    const pixels = std.math.mul(usize, desc.width, desc.height) catch return false;
    const bytes = std.math.mul(usize, pixels, 4) catch return false;
    return bytes <= MAX_STAGING_BYTES;
}

fn hasExtension(list: []const u8, wanted: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |extension| {
        if (std.mem.eql(u8, extension, wanted)) return true;
    }
    return false;
}

/// Reverses storage rows when Y_INVERT says row zero is the buffer's bottom row.
fn normalizeTopDownRows(bytes: []u8, row_bytes: usize, height: usize, y_invert: bool) bool {
    const expected = std.math.mul(usize, row_bytes, height) catch return false;
    if (row_bytes == 0 or bytes.len != expected) return false;
    if (!y_invert or height < 2) return true;

    var top: usize = 0;
    var bottom: usize = height - 1;
    while (top < bottom) : ({
        top += 1;
        bottom -= 1;
    }) {
        const top_start = top * row_bytes;
        const bottom_start = bottom * row_bytes;
        for (0..row_bytes) |column| {
            std.mem.swap(u8, &bytes[top_start + column], &bytes[bottom_start + column]);
        }
    }
    return true;
}

fn rgbaToBgra(bytes: []u8) bool {
    if (bytes.len % 4 != 0) return false;
    var index: usize = 0;
    while (index < bytes.len) : (index += 4)
        std.mem.swap(u8, &bytes[index], &bytes[index + 2]);
    return true;
}

fn appendCapabilities(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Capability),
    format: u32,
    modifiers: []const u64,
    external_only: []const EglBoolean,
) !void {
    if (modifiers.len != external_only.len) return;
    for (modifiers, external_only) |modifier, external| {
        if (external != EGL_FALSE) continue;
        const candidate = Capability{ .format = format, .modifier = modifier, .external_only = false };
        var duplicate = false;
        for (out.items) |existing| {
            if (existing.format == candidate.format and existing.modifier == candidate.modifier) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try out.append(allocator, candidate);
    }
}

const EglBoolean = c_uint;
const EglInt = i32;
const EglAttrib = isize;
const EglEnum = c_uint;
const EglDisplay = ?*anyopaque;
const EglConfig = ?*anyopaque;
const EglContext = ?*anyopaque;
const EglSurface = ?*anyopaque;
const EglImage = ?*anyopaque;
const EglClientBuffer = ?*anyopaque;
const GlEnum = c_uint;
const GlUint = c_uint;
const GlInt = c_int;
const GlSizei = c_int;
const GlChar = u8;

const EGL_FALSE: EglBoolean = 0;
const EGL_TRUE: EglBoolean = 1;
const EGL_NONE: EglInt = 0x3038;
const EGL_EXTENSIONS: EglInt = 0x3055;
const EGL_SURFACE_TYPE: EglInt = 0x3033;
const EGL_PBUFFER_BIT: EglInt = 0x0001;
const EGL_RENDERABLE_TYPE: EglInt = 0x3040;
const EGL_OPENGL_ES3_BIT: EglInt = 0x0040;
const EGL_CONTEXT_CLIENT_VERSION: EglInt = 0x3098;
const EGL_OPENGL_ES_API: EglEnum = 0x30A0;
const EGL_PLATFORM_SURFACELESS_MESA: EglEnum = 0x31DD;
const EGL_LINUX_DMA_BUF_EXT: EglEnum = 0x3270;
const EGL_WIDTH: EglInt = 0x3057;
const EGL_HEIGHT: EglInt = 0x3056;
const EGL_LINUX_DRM_FOURCC_EXT: EglInt = 0x3271;
const DRM_FORMAT_MOD_INVALID = dmabuf.DRM_FORMAT_MOD_INVALID;

const EGL_DMA_BUF_PLANE_FD = [_]EglInt{ 0x3272, 0x3275, 0x3278, 0x3440 };
const EGL_DMA_BUF_PLANE_OFFSET = [_]EglInt{ 0x3273, 0x3276, 0x3279, 0x3441 };
const EGL_DMA_BUF_PLANE_PITCH = [_]EglInt{ 0x3274, 0x3277, 0x327A, 0x3442 };
const EGL_DMA_BUF_PLANE_MOD_LO = [_]EglInt{ 0x3443, 0x3445, 0x3447, 0x3449 };
const EGL_DMA_BUF_PLANE_MOD_HI = [_]EglInt{ 0x3444, 0x3446, 0x3448, 0x344A };

const GL_NO_ERROR: GlEnum = 0;
const GL_EXTENSIONS: GlEnum = 0x1F03;
const GL_MAX_TEXTURE_SIZE: GlEnum = 0x0D33;
const GL_MAX_VIEWPORT_DIMS: GlEnum = 0x0D3A;
const GL_MAX_RENDERBUFFER_SIZE: GlEnum = 0x84E8;
const GL_TEXTURE_2D: GlEnum = 0x0DE1;
const GL_TEXTURE_MIN_FILTER: GlEnum = 0x2801;
const GL_TEXTURE_MAG_FILTER: GlEnum = 0x2800;
const GL_TEXTURE_WRAP_S: GlEnum = 0x2802;
const GL_TEXTURE_WRAP_T: GlEnum = 0x2803;
const GL_NEAREST: GlInt = 0x2600;
const GL_CLAMP_TO_EDGE: GlInt = 0x812F;
const GL_VERTEX_SHADER: GlEnum = 0x8B31;
const GL_FRAGMENT_SHADER: GlEnum = 0x8B30;
const GL_COMPILE_STATUS: GlEnum = 0x8B81;
const GL_LINK_STATUS: GlEnum = 0x8B82;
const GL_FRAMEBUFFER: GlEnum = 0x8D40;
const GL_RENDERBUFFER: GlEnum = 0x8D41;
const GL_RGBA8: GlEnum = 0x8058;
const GL_COLOR_ATTACHMENT0: GlEnum = 0x8CE0;
const GL_FRAMEBUFFER_COMPLETE: GlEnum = 0x8CD5;
const GL_COLOR_BUFFER_BIT: GlEnum = 0x00004000;
const GL_DITHER: GlEnum = 0x0BD0;
const GL_TRIANGLES: GlEnum = 0x0004;
const GL_TEXTURE0: GlEnum = 0x84C0;
const GL_RGBA: GlEnum = 0x1908;
const GL_UNSIGNED_BYTE: GlEnum = 0x1401;
const GL_PACK_ALIGNMENT: GlEnum = 0x0D05;

const GetDisplay = *const fn (?*anyopaque) callconv(.c) EglDisplay;
const GetPlatformDisplay = *const fn (EglEnum, ?*anyopaque, ?[*]const EglAttrib) callconv(.c) EglDisplay;
const GetPlatformDisplayExt = *const fn (EglEnum, ?*anyopaque, ?[*]const EglInt) callconv(.c) EglDisplay;
const Initialize = *const fn (EglDisplay, *EglInt, *EglInt) callconv(.c) EglBoolean;
const Terminate = *const fn (EglDisplay) callconv(.c) EglBoolean;
const BindApi = *const fn (EglEnum) callconv(.c) EglBoolean;
const ChooseConfig = *const fn (EglDisplay, [*]const EglInt, *EglConfig, EglInt, *EglInt) callconv(.c) EglBoolean;
const CreateContext = *const fn (EglDisplay, EglConfig, EglContext, [*]const EglInt) callconv(.c) EglContext;
const DestroyContext = *const fn (EglDisplay, EglContext) callconv(.c) EglBoolean;
const CreatePbufferSurface = *const fn (EglDisplay, EglConfig, [*]const EglInt) callconv(.c) EglSurface;
const DestroySurface = *const fn (EglDisplay, EglSurface) callconv(.c) EglBoolean;
const MakeCurrent = *const fn (EglDisplay, EglSurface, EglSurface, EglContext) callconv(.c) EglBoolean;
const QueryString = *const fn (EglDisplay, EglInt) callconv(.c) ?[*:0]const u8;
const GetProcAddress = *const fn ([*:0]const u8) callconv(.c) ?*anyopaque;
const CreateImage = *const fn (EglDisplay, EglContext, EglEnum, EglClientBuffer, [*]const EglInt) callconv(.c) EglImage;
const DestroyImage = *const fn (EglDisplay, EglImage) callconv(.c) EglBoolean;
const QueryFormats = *const fn (EglDisplay, EglInt, ?[*]EglInt, *EglInt) callconv(.c) EglBoolean;
const QueryModifiers = *const fn (EglDisplay, EglInt, EglInt, ?[*]u64, ?[*]EglBoolean, *EglInt) callconv(.c) EglBoolean;

const GlGetString = *const fn (GlEnum) callconv(.c) ?[*:0]const u8;
const GlGetIntegerv = *const fn (GlEnum, *GlInt) callconv(.c) void;
const GlGetError = *const fn () callconv(.c) GlEnum;
const GlGenTextures = *const fn (GlSizei, *GlUint) callconv(.c) void;
const GlDeleteTextures = *const fn (GlSizei, *const GlUint) callconv(.c) void;
const GlBindTexture = *const fn (GlEnum, GlUint) callconv(.c) void;
const GlTexParameteri = *const fn (GlEnum, GlEnum, GlInt) callconv(.c) void;
const GlImageTargetTexture = *const fn (GlEnum, EglImage) callconv(.c) void;
const GlCreateShader = *const fn (GlEnum) callconv(.c) GlUint;
const GlShaderSource = *const fn (GlUint, GlSizei, [*]const [*:0]const GlChar, ?[*]const GlInt) callconv(.c) void;
const GlCompileShader = *const fn (GlUint) callconv(.c) void;
const GlGetShaderiv = *const fn (GlUint, GlEnum, *GlInt) callconv(.c) void;
const GlDeleteShader = *const fn (GlUint) callconv(.c) void;
const GlCreateProgram = *const fn () callconv(.c) GlUint;
const GlAttachShader = *const fn (GlUint, GlUint) callconv(.c) void;
const GlLinkProgram = *const fn (GlUint) callconv(.c) void;
const GlGetProgramiv = *const fn (GlUint, GlEnum, *GlInt) callconv(.c) void;
const GlDeleteProgram = *const fn (GlUint) callconv(.c) void;
const GlUseProgram = *const fn (GlUint) callconv(.c) void;
const GlGetUniformLocation = *const fn (GlUint, [*:0]const GlChar) callconv(.c) GlInt;
const GlUniform1i = *const fn (GlInt, GlInt) callconv(.c) void;
const GlGenFramebuffers = *const fn (GlSizei, *GlUint) callconv(.c) void;
const GlDeleteFramebuffers = *const fn (GlSizei, *const GlUint) callconv(.c) void;
const GlBindFramebuffer = *const fn (GlEnum, GlUint) callconv(.c) void;
const GlCheckFramebufferStatus = *const fn (GlEnum) callconv(.c) GlEnum;
const GlFramebufferRenderbuffer = *const fn (GlEnum, GlEnum, GlEnum, GlUint) callconv(.c) void;
const GlGenRenderbuffers = *const fn (GlSizei, *GlUint) callconv(.c) void;
const GlDeleteRenderbuffers = *const fn (GlSizei, *const GlUint) callconv(.c) void;
const GlBindRenderbuffer = *const fn (GlEnum, GlUint) callconv(.c) void;
const GlRenderbufferStorage = *const fn (GlEnum, GlEnum, GlSizei, GlSizei) callconv(.c) void;
const GlViewport = *const fn (GlInt, GlInt, GlSizei, GlSizei) callconv(.c) void;
const GlClearColor = *const fn (f32, f32, f32, f32) callconv(.c) void;
const GlClear = *const fn (GlEnum) callconv(.c) void;
const GlDisable = *const fn (GlEnum) callconv(.c) void;
const GlActiveTexture = *const fn (GlEnum) callconv(.c) void;
const GlDrawArrays = *const fn (GlEnum, GlInt, GlSizei) callconv(.c) void;
const GlPixelStorei = *const fn (GlEnum, GlInt) callconv(.c) void;
const GlReadPixels = *const fn (GlInt, GlInt, GlSizei, GlSizei, GlEnum, GlEnum, *anyopaque) callconv(.c) void;

const EglApi = struct {
    handle: *anyopaque,
    get_display: GetDisplay,
    get_platform_display: ?GetPlatformDisplay,
    get_platform_display_ext: ?GetPlatformDisplayExt,
    initialize: Initialize,
    terminate: Terminate,
    bind_api: BindApi,
    choose_config: ChooseConfig,
    create_context: CreateContext,
    destroy_context: DestroyContext,
    create_pbuffer_surface: CreatePbufferSurface,
    destroy_surface: DestroySurface,
    make_current: MakeCurrent,
    query_string: QueryString,
    get_proc_address: GetProcAddress,
    create_image: CreateImage,
    destroy_image: DestroyImage,
    query_formats: QueryFormats,
    query_modifiers: QueryModifiers,
};

const GlApi = struct {
    handle: *anyopaque,
    get_string: GlGetString,
    get_integerv: GlGetIntegerv,
    get_error: GlGetError,
    gen_textures: GlGenTextures,
    delete_textures: GlDeleteTextures,
    bind_texture: GlBindTexture,
    tex_parameteri: GlTexParameteri,
    image_target_texture: GlImageTargetTexture,
    create_shader: GlCreateShader,
    shader_source: GlShaderSource,
    compile_shader: GlCompileShader,
    get_shader_iv: GlGetShaderiv,
    delete_shader: GlDeleteShader,
    create_program: GlCreateProgram,
    attach_shader: GlAttachShader,
    link_program: GlLinkProgram,
    get_program_iv: GlGetProgramiv,
    delete_program: GlDeleteProgram,
    use_program: GlUseProgram,
    get_uniform_location: GlGetUniformLocation,
    uniform_1i: GlUniform1i,
    gen_framebuffers: GlGenFramebuffers,
    delete_framebuffers: GlDeleteFramebuffers,
    bind_framebuffer: GlBindFramebuffer,
    check_framebuffer_status: GlCheckFramebufferStatus,
    framebuffer_renderbuffer: GlFramebufferRenderbuffer,
    gen_renderbuffers: GlGenRenderbuffers,
    delete_renderbuffers: GlDeleteRenderbuffers,
    bind_renderbuffer: GlBindRenderbuffer,
    renderbuffer_storage: GlRenderbufferStorage,
    viewport: GlViewport,
    clear_color: GlClearColor,
    clear: GlClear,
    disable: GlDisable,
    active_texture: GlActiveTexture,
    draw_arrays: GlDrawArrays,
    pixel_storei: GlPixelStorei,
    read_pixels: GlReadPixels,
};

extern fn dlopen(filename: [*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern fn dlclose(handle: ?*anyopaque) c_int;

const RTLD_LAZY: c_int = 0x1;
const RTLD_LOCAL: c_int = 0;

fn openLibrary(names: []const [*:0]const u8) ?*anyopaque {
    for (names) |name| {
        if (dlopen(name, RTLD_LAZY | RTLD_LOCAL)) |handle| return handle;
    }
    return null;
}

fn symbol(comptime T: type, handle: *anyopaque, name: [*:0]const u8) ?T {
    return @ptrCast(dlsym(handle, name) orelse return null);
}

fn eglProc(comptime T: type, handle: *anyopaque, get_proc: GetProcAddress, name: [*:0]const u8) ?T {
    const address = dlsym(handle, name) orelse get_proc(name) orelse return null;
    return @ptrCast(address);
}

fn glProc(comptime T: type, handle: *anyopaque, get_proc: GetProcAddress, name: [*:0]const u8) ?T {
    const address = dlsym(handle, name) orelse get_proc(name) orelse return null;
    return @ptrCast(address);
}

fn loadEgl() ?EglApi {
    const handle = openLibrary(&.{ "libEGL.so.1", "libEGL.so" }) orelse return null;
    var success = false;
    defer if (!success) {
        _ = dlclose(handle);
    };
    const get_proc = symbol(GetProcAddress, handle, "eglGetProcAddress") orelse return null;
    const api = EglApi{
        .handle = handle,
        .get_display = symbol(GetDisplay, handle, "eglGetDisplay") orelse return null,
        .get_platform_display = eglProc(GetPlatformDisplay, handle, get_proc, "eglGetPlatformDisplay"),
        .get_platform_display_ext = eglProc(GetPlatformDisplayExt, handle, get_proc, "eglGetPlatformDisplayEXT"),
        .initialize = symbol(Initialize, handle, "eglInitialize") orelse return null,
        .terminate = symbol(Terminate, handle, "eglTerminate") orelse return null,
        .bind_api = symbol(BindApi, handle, "eglBindAPI") orelse return null,
        .choose_config = symbol(ChooseConfig, handle, "eglChooseConfig") orelse return null,
        .create_context = symbol(CreateContext, handle, "eglCreateContext") orelse return null,
        .destroy_context = symbol(DestroyContext, handle, "eglDestroyContext") orelse return null,
        .create_pbuffer_surface = symbol(CreatePbufferSurface, handle, "eglCreatePbufferSurface") orelse return null,
        .destroy_surface = symbol(DestroySurface, handle, "eglDestroySurface") orelse return null,
        .make_current = symbol(MakeCurrent, handle, "eglMakeCurrent") orelse return null,
        .query_string = symbol(QueryString, handle, "eglQueryString") orelse return null,
        .get_proc_address = get_proc,
        .create_image = eglProc(CreateImage, handle, get_proc, "eglCreateImageKHR") orelse return null,
        .destroy_image = eglProc(DestroyImage, handle, get_proc, "eglDestroyImageKHR") orelse return null,
        .query_formats = eglProc(QueryFormats, handle, get_proc, "eglQueryDmaBufFormatsEXT") orelse return null,
        .query_modifiers = eglProc(QueryModifiers, handle, get_proc, "eglQueryDmaBufModifiersEXT") orelse return null,
    };
    success = true;
    return api;
}

fn loadGl(get_proc: GetProcAddress) ?GlApi {
    const handle = openLibrary(&.{ "libGLESv2.so.2", "libGLESv2.so" }) orelse return null;
    var success = false;
    defer if (!success) {
        _ = dlclose(handle);
    };
    const api = GlApi{
        .handle = handle,
        .get_string = glProc(GlGetString, handle, get_proc, "glGetString") orelse return null,
        .get_integerv = glProc(GlGetIntegerv, handle, get_proc, "glGetIntegerv") orelse return null,
        .get_error = glProc(GlGetError, handle, get_proc, "glGetError") orelse return null,
        .gen_textures = glProc(GlGenTextures, handle, get_proc, "glGenTextures") orelse return null,
        .delete_textures = glProc(GlDeleteTextures, handle, get_proc, "glDeleteTextures") orelse return null,
        .bind_texture = glProc(GlBindTexture, handle, get_proc, "glBindTexture") orelse return null,
        .tex_parameteri = glProc(GlTexParameteri, handle, get_proc, "glTexParameteri") orelse return null,
        .image_target_texture = glProc(GlImageTargetTexture, handle, get_proc, "glEGLImageTargetTexture2DOES") orelse return null,
        .create_shader = glProc(GlCreateShader, handle, get_proc, "glCreateShader") orelse return null,
        .shader_source = glProc(GlShaderSource, handle, get_proc, "glShaderSource") orelse return null,
        .compile_shader = glProc(GlCompileShader, handle, get_proc, "glCompileShader") orelse return null,
        .get_shader_iv = glProc(GlGetShaderiv, handle, get_proc, "glGetShaderiv") orelse return null,
        .delete_shader = glProc(GlDeleteShader, handle, get_proc, "glDeleteShader") orelse return null,
        .create_program = glProc(GlCreateProgram, handle, get_proc, "glCreateProgram") orelse return null,
        .attach_shader = glProc(GlAttachShader, handle, get_proc, "glAttachShader") orelse return null,
        .link_program = glProc(GlLinkProgram, handle, get_proc, "glLinkProgram") orelse return null,
        .get_program_iv = glProc(GlGetProgramiv, handle, get_proc, "glGetProgramiv") orelse return null,
        .delete_program = glProc(GlDeleteProgram, handle, get_proc, "glDeleteProgram") orelse return null,
        .use_program = glProc(GlUseProgram, handle, get_proc, "glUseProgram") orelse return null,
        .get_uniform_location = glProc(GlGetUniformLocation, handle, get_proc, "glGetUniformLocation") orelse return null,
        .uniform_1i = glProc(GlUniform1i, handle, get_proc, "glUniform1i") orelse return null,
        .gen_framebuffers = glProc(GlGenFramebuffers, handle, get_proc, "glGenFramebuffers") orelse return null,
        .delete_framebuffers = glProc(GlDeleteFramebuffers, handle, get_proc, "glDeleteFramebuffers") orelse return null,
        .bind_framebuffer = glProc(GlBindFramebuffer, handle, get_proc, "glBindFramebuffer") orelse return null,
        .check_framebuffer_status = glProc(GlCheckFramebufferStatus, handle, get_proc, "glCheckFramebufferStatus") orelse return null,
        .framebuffer_renderbuffer = glProc(GlFramebufferRenderbuffer, handle, get_proc, "glFramebufferRenderbuffer") orelse return null,
        .gen_renderbuffers = glProc(GlGenRenderbuffers, handle, get_proc, "glGenRenderbuffers") orelse return null,
        .delete_renderbuffers = glProc(GlDeleteRenderbuffers, handle, get_proc, "glDeleteRenderbuffers") orelse return null,
        .bind_renderbuffer = glProc(GlBindRenderbuffer, handle, get_proc, "glBindRenderbuffer") orelse return null,
        .renderbuffer_storage = glProc(GlRenderbufferStorage, handle, get_proc, "glRenderbufferStorage") orelse return null,
        .viewport = glProc(GlViewport, handle, get_proc, "glViewport") orelse return null,
        .clear_color = glProc(GlClearColor, handle, get_proc, "glClearColor") orelse return null,
        .clear = glProc(GlClear, handle, get_proc, "glClear") orelse return null,
        .disable = glProc(GlDisable, handle, get_proc, "glDisable") orelse return null,
        .active_texture = glProc(GlActiveTexture, handle, get_proc, "glActiveTexture") orelse return null,
        .draw_arrays = glProc(GlDrawArrays, handle, get_proc, "glDrawArrays") orelse return null,
        .pixel_storei = glProc(GlPixelStorei, handle, get_proc, "glPixelStorei") orelse return null,
        .read_pixels = glProc(GlReadPixels, handle, get_proc, "glReadPixels") orelse return null,
    };
    success = true;
    return api;
}

const DisplayState = struct {
    display: EglDisplay,
    major: EglInt,
    minor: EglInt,
};

fn initializeDisplay(egl: *const EglApi, display: EglDisplay) ?DisplayState {
    if (display == null) return null;
    var major: EglInt = 0;
    var minor: EglInt = 0;
    if (egl.initialize(display, &major, &minor) == EGL_FALSE) return null;
    return .{ .display = display, .major = major, .minor = minor };
}

fn initializeHeadlessDisplay(egl: *const EglApi) ?DisplayState {
    if (egl.query_string(null, EGL_EXTENSIONS)) |client_extensions_z| {
        const client_extensions = std.mem.span(client_extensions_z);
        if (hasExtension(client_extensions, "EGL_MESA_platform_surfaceless")) {
            if (egl.get_platform_display) |get_platform_display| {
                if (initializeDisplay(egl, get_platform_display(
                    EGL_PLATFORM_SURFACELESS_MESA,
                    null,
                    null,
                ))) |state| return state;
            } else if (egl.get_platform_display_ext) |get_platform_display| {
                if (initializeDisplay(egl, get_platform_display(
                    EGL_PLATFORM_SURFACELESS_MESA,
                    null,
                    null,
                ))) |state| return state;
            }
        }
    }

    // EGL_DEFAULT_DISPLAY lets implementations without the Mesa platform path
    // select their normal headless or device-backed display.
    return initializeDisplay(egl, egl.get_display(null));
}

const vertex_source: [*:0]const u8 =
    \\#version 300 es
    \\out vec2 v_uv;
    \\void main() {
    \\    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    \\    v_uv = p;
    \\    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

const fragment_source: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D source_texture;
    \\uniform bool force_opaque;
    \\in vec2 v_uv;
    \\out vec4 out_color;
    \\void main() {
    \\    vec4 pixel = texture(source_texture, v_uv);
    \\    out_color = vec4(pixel.rgb, force_opaque ? 1.0 : pixel.a);
    \\}
;

fn compileShader(gl: *const GlApi, kind: GlEnum, source: [*:0]const u8) ?GlUint {
    clearErrors(gl);
    const shader = gl.create_shader(kind);
    if (shader == 0) return null;
    const sources = [_][*:0]const u8{source};
    gl.shader_source(shader, 1, &sources, null);
    gl.compile_shader(shader);
    var ok: GlInt = 0;
    gl.get_shader_iv(shader, GL_COMPILE_STATUS, &ok);
    if (ok == 0 or takeErrors(gl)) {
        gl.delete_shader(shader);
        return null;
    }
    return shader;
}

fn createProgram(gl: *const GlApi) ?GlUint {
    const vertex = compileShader(gl, GL_VERTEX_SHADER, vertex_source) orelse return null;
    defer gl.delete_shader(vertex);
    const fragment = compileShader(gl, GL_FRAGMENT_SHADER, fragment_source) orelse return null;
    defer gl.delete_shader(fragment);
    const program = gl.create_program();
    if (program == 0) return null;
    gl.attach_shader(program, vertex);
    gl.attach_shader(program, fragment);
    gl.link_program(program);
    var ok: GlInt = 0;
    gl.get_program_iv(program, GL_LINK_STATUS, &ok);
    if (ok == 0 or takeErrors(gl)) {
        gl.delete_program(program);
        return null;
    }
    return program;
}

fn clearErrors(gl: *const GlApi) void {
    var remaining: u8 = 32;
    while (remaining > 0 and gl.get_error() != GL_NO_ERROR) : (remaining -= 1) {}
}

fn takeErrors(gl: *const GlApi) bool {
    var found = false;
    var remaining: u8 = 32;
    while (remaining > 0) : (remaining -= 1) {
        if (gl.get_error() == GL_NO_ERROR) break;
        found = true;
    }
    return found;
}

fn buildAttributes(desc: Import, attrs: *[48]EglInt) []const EglInt {
    var n: usize = 0;
    const add = struct {
        fn pair(storage: *[48]EglInt, index: *usize, key: EglInt, value: EglInt) void {
            storage[index.*] = key;
            storage[index.* + 1] = value;
            index.* += 2;
        }
    }.pair;
    add(attrs, &n, EGL_WIDTH, @intCast(desc.width));
    add(attrs, &n, EGL_HEIGHT, @intCast(desc.height));
    add(attrs, &n, EGL_LINUX_DRM_FOURCC_EXT, @bitCast(desc.format));
    for (desc.planes, 0..) |plane, index| {
        add(attrs, &n, EGL_DMA_BUF_PLANE_FD[index], plane.fd);
        add(attrs, &n, EGL_DMA_BUF_PLANE_OFFSET[index], @bitCast(plane.offset));
        add(attrs, &n, EGL_DMA_BUF_PLANE_PITCH[index], @bitCast(plane.stride));
        if (plane.modifier != DRM_FORMAT_MOD_INVALID) {
            add(attrs, &n, EGL_DMA_BUF_PLANE_MOD_LO[index], @bitCast(@as(u32, @truncate(plane.modifier))));
            add(attrs, &n, EGL_DMA_BUF_PLANE_MOD_HI[index], @bitCast(@as(u32, @truncate(plane.modifier >> 32))));
        }
    }
    attrs[n] = EGL_NONE;
    return attrs[0 .. n + 1];
}

pub const Importer = if (enabled) struct {
    allocator: std.mem.Allocator,
    egl: EglApi,
    gl: GlApi,
    display: EglDisplay,
    context: EglContext,
    surface: EglSurface,
    program: GlUint,
    source_uniform: GlInt,
    opaque_uniform: GlInt,
    max_readback_width: u32,
    max_readback_height: u32,
    caps: std.ArrayList(Capability) = .empty,
    readback: std.ArrayList(u8) = .empty,
    readback_framebuffer: GlUint = 0,
    readback_renderbuffer: GlUint = 0,
    readback_width: u32 = 0,
    readback_height: u32 = 0,
    active_buffers: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ?@This() {
        const egl = loadEgl() orelse return null;
        var display: EglDisplay = null;
        var context: EglContext = null;
        var surface: EglSurface = null;
        var gl: ?GlApi = null;
        var program: GlUint = 0;
        var success = false;
        defer if (!success) {
            if (display != null and context != null) {
                if (gl) |loaded_gl| {
                    if (program != 0 and
                        egl.make_current(display, surface, surface, context) != EGL_FALSE)
                        loaded_gl.delete_program(program);
                }
                _ = egl.make_current(display, null, null, null);
                _ = egl.destroy_context(display, context);
            }
            if (display != null and surface != null) _ = egl.destroy_surface(display, surface);
            if (display != null) _ = egl.terminate(display);
            if (gl) |loaded_gl| _ = dlclose(loaded_gl.handle);
            _ = dlclose(egl.handle);
        };

        const display_state = initializeHeadlessDisplay(&egl) orelse return null;
        display = display_state.display;

        const extensions_z = egl.query_string(display, EGL_EXTENSIONS) orelse return null;
        const extensions = std.mem.span(extensions_z);
        if (!hasExtension(extensions, "EGL_EXT_image_dma_buf_import") or
            !hasExtension(extensions, "EGL_EXT_image_dma_buf_import_modifiers"))
            return null;
        const egl_15 = display_state.major > 1 or
            (display_state.major == 1 and display_state.minor >= 5);
        if (!egl_15 and !hasExtension(extensions, "EGL_KHR_create_context")) return null;
        if (egl.bind_api(EGL_OPENGL_ES_API) == EGL_FALSE) return null;

        const config_attrs = [_]EglInt{
            EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL_NONE,
        };
        var config: EglConfig = null;
        var config_count: EglInt = 0;
        if (egl.choose_config(display, &config_attrs, &config, 1, &config_count) == EGL_FALSE or
            config_count < 1 or config == null)
            return null;
        const context_attrs = [_]EglInt{ EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
        context = egl.create_context(display, config, null, &context_attrs);
        if (context == null) return null;

        var current = false;
        if (hasExtension(extensions, "EGL_KHR_surfaceless_context"))
            current = egl.make_current(display, null, null, context) != EGL_FALSE;
        if (!current) {
            const surface_attrs = [_]EglInt{ EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
            surface = egl.create_pbuffer_surface(display, config, &surface_attrs);
            if (surface == null or
                egl.make_current(display, surface, surface, context) == EGL_FALSE)
                return null;
        }

        gl = loadGl(egl.get_proc_address) orelse return null;
        clearErrors(&gl.?);
        const gl_extensions_z = gl.?.get_string(GL_EXTENSIONS) orelse return null;
        if (takeErrors(&gl.?)) return null;
        if (!hasExtension(std.mem.span(gl_extensions_z), "GL_OES_EGL_image")) return null;
        var max_texture: GlInt = 0;
        gl.?.get_integerv(GL_MAX_TEXTURE_SIZE, &max_texture);
        var max_renderbuffer: GlInt = 0;
        gl.?.get_integerv(GL_MAX_RENDERBUFFER_SIZE, &max_renderbuffer);
        var max_viewport = [_]GlInt{ 0, 0 };
        gl.?.get_integerv(GL_MAX_VIEWPORT_DIMS, &max_viewport[0]);
        if (max_texture <= 0 or max_renderbuffer <= 0 or
            max_viewport[0] <= 0 or max_viewport[1] <= 0 or takeErrors(&gl.?))
            return null;
        program = createProgram(&gl.?) orelse return null;
        clearErrors(&gl.?);
        const source_uniform = gl.?.get_uniform_location(program, "source_texture");
        const opaque_uniform = gl.?.get_uniform_location(program, "force_opaque");
        if (source_uniform < 0 or opaque_uniform < 0 or takeErrors(&gl.?)) return null;

        var self = @This(){
            .allocator = allocator,
            .egl = egl,
            .gl = gl.?,
            .display = display,
            .context = context,
            .surface = surface,
            .program = program,
            .source_uniform = source_uniform,
            .opaque_uniform = opaque_uniform,
            .max_readback_width = @intCast(@min(max_texture, max_renderbuffer, max_viewport[0])),
            .max_readback_height = @intCast(@min(max_texture, max_renderbuffer, max_viewport[1])),
        };
        var keep_caps = false;
        defer if (!keep_caps) self.caps.deinit(allocator);
        self.queryCapabilities() catch return null;
        if (self.caps.items.len == 0) return null;
        keep_caps = true;
        success = true;
        return self;
    }

    pub fn deinit(self: *@This()) void {
        if (self.active_buffers != 0) @panic("dma-buf buffers outlive importer");
        self.caps.deinit(self.allocator);
        self.readback.deinit(self.allocator);
        if (self.makeCurrent()) {
            if (self.readback_framebuffer != 0)
                self.gl.delete_framebuffers(1, &self.readback_framebuffer);
            if (self.readback_renderbuffer != 0)
                self.gl.delete_renderbuffers(1, &self.readback_renderbuffer);
            self.gl.delete_program(self.program);
        }
        _ = self.egl.make_current(self.display, null, null, null);
        _ = self.egl.destroy_context(self.display, self.context);
        if (self.surface != null) _ = self.egl.destroy_surface(self.display, self.surface);
        _ = self.egl.terminate(self.display);
        _ = dlclose(self.gl.handle);
        _ = dlclose(self.egl.handle);
    }

    pub fn capabilities(self: *const @This()) []const Capability {
        return self.caps.items;
    }

    fn makeCurrent(self: *const @This()) bool {
        return self.egl.make_current(
            self.display,
            self.surface,
            self.surface,
            self.context,
        ) != EGL_FALSE;
    }

    fn supports(self: *const @This(), desc: Import) bool {
        const modifier = desc.planes[0].modifier;
        for (self.caps.items) |capability| {
            if (capability.format == desc.format and
                capability.modifier == modifier and
                !capability.external_only)
                return true;
        }
        return false;
    }

    fn ensureReadback(self: *@This(), width: u32, height: u32) bool {
        clearErrors(&self.gl);
        if (self.readback_renderbuffer == 0)
            self.gl.gen_renderbuffers(1, &self.readback_renderbuffer);
        if (self.readback_framebuffer == 0)
            self.gl.gen_framebuffers(1, &self.readback_framebuffer);
        if (self.readback_renderbuffer == 0 or self.readback_framebuffer == 0)
            return false;

        self.gl.bind_renderbuffer(GL_RENDERBUFFER, self.readback_renderbuffer);
        if (width != self.readback_width or height != self.readback_height) {
            self.gl.renderbuffer_storage(GL_RENDERBUFFER, GL_RGBA8, @intCast(width), @intCast(height));
            if (takeErrors(&self.gl)) return false;
            self.readback_width = width;
            self.readback_height = height;
        }
        self.gl.bind_framebuffer(GL_FRAMEBUFFER, self.readback_framebuffer);
        self.gl.framebuffer_renderbuffer(
            GL_FRAMEBUFFER,
            GL_COLOR_ATTACHMENT0,
            GL_RENDERBUFFER,
            self.readback_renderbuffer,
        );
        return self.gl.check_framebuffer_status(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE and
            !takeErrors(&self.gl);
    }

    pub fn importBuffer(self: *@This(), desc: Import) ?Buffer {
        if (!validLayout(desc) or
            desc.width > self.max_readback_width or
            desc.height > self.max_readback_height)
            return null;
        if (!self.supports(desc) or !self.makeCurrent()) return null;

        var attrs_storage: [48]EglInt = undefined;
        const attrs = buildAttributes(desc, &attrs_storage);
        const image = self.egl.create_image(self.display, null, EGL_LINUX_DMA_BUF_EXT, null, attrs.ptr);
        if (image == null) return null;
        var texture: GlUint = 0;
        var success = false;
        defer if (!success) {
            if (texture != 0) self.gl.delete_textures(1, &texture);
            _ = self.egl.destroy_image(self.display, image);
        };

        clearErrors(&self.gl);
        self.gl.gen_textures(1, &texture);
        if (texture == 0) return null;
        self.gl.bind_texture(GL_TEXTURE_2D, texture);
        self.gl.tex_parameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        self.gl.tex_parameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        self.gl.tex_parameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        self.gl.tex_parameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        self.gl.image_target_texture(GL_TEXTURE_2D, image);
        if (takeErrors(&self.gl)) return null;

        self.active_buffers += 1;
        success = true;
        return .{
            .importer = self,
            .image = image,
            .texture = texture,
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
            .y_invert = desc.flags & FLAG_Y_INVERT != 0,
        };
    }

    fn queryCapabilities(self: *@This()) !void {
        var format_count: EglInt = 0;
        if (self.egl.query_formats(self.display, 0, null, &format_count) == EGL_FALSE or
            format_count <= 0 or format_count > MAX_QUERY_ITEMS)
            return;
        const formats = try self.allocator.alloc(EglInt, @intCast(format_count));
        defer self.allocator.free(formats);
        var returned_formats: EglInt = 0;
        if (self.egl.query_formats(self.display, format_count, formats.ptr, &returned_formats) == EGL_FALSE or
            returned_formats < 0 or returned_formats > format_count)
            return;

        for ([_]u32{ DRM_FORMAT_ARGB8888, DRM_FORMAT_XRGB8888 }) |wanted| {
            var supported = false;
            for (formats[0..@intCast(returned_formats)]) |format| {
                if (@as(u32, @bitCast(format)) == wanted) {
                    supported = true;
                    break;
                }
            }
            if (!supported) continue;
            var modifier_count: EglInt = 0;
            if (self.egl.query_modifiers(self.display, @bitCast(wanted), 0, null, null, &modifier_count) == EGL_FALSE or
                modifier_count <= 0 or modifier_count > MAX_QUERY_ITEMS)
                continue;
            const modifiers = try self.allocator.alloc(u64, @intCast(modifier_count));
            defer self.allocator.free(modifiers);
            const external = try self.allocator.alloc(EglBoolean, @intCast(modifier_count));
            defer self.allocator.free(external);
            var returned_modifiers: EglInt = 0;
            if (self.egl.query_modifiers(
                self.display,
                @bitCast(wanted),
                modifier_count,
                modifiers.ptr,
                external.ptr,
                &returned_modifiers,
            ) == EGL_FALSE or returned_modifiers < 0 or returned_modifiers > modifier_count)
                continue;
            try appendCapabilities(
                self.allocator,
                &self.caps,
                wanted,
                modifiers[0..@intCast(returned_modifiers)],
                external[0..@intCast(returned_modifiers)],
            );
        }
    }
} else struct {
    pub fn init(allocator: std.mem.Allocator) ?@This() {
        _ = allocator;
        return null;
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }

    pub fn capabilities(self: *const @This()) []const Capability {
        _ = self;
        return &.{};
    }

    pub fn importBuffer(self: *@This(), desc: Import) ?Buffer {
        _ = self;
        _ = desc;
        return null;
    }
};

pub const Buffer = if (enabled) struct {
    importer: *Importer,
    image: EglImage,
    texture: GlUint,
    width: u32,
    height: u32,
    format: u32,
    y_invert: bool,

    pub fn deinit(self: *@This()) void {
        const importer = self.importer;
        if (importer.makeCurrent()) {
            importer.gl.delete_textures(1, &self.texture);
        }
        _ = importer.egl.destroy_image(importer.display, self.image);
        std.debug.assert(importer.active_buffers > 0);
        importer.active_buffers -= 1;
    }

    /// Writes tightly packed, top-down BGRA pixels after complete readback.
    pub fn readPixels(self: *@This(), out: []u8) bool {
        const importer = self.importer;
        const expected = std.math.mul(
            usize,
            std.math.mul(usize, self.width, self.height) catch return false,
            4,
        ) catch return false;
        if (out.len != expected or !importer.makeCurrent()) return false;
        importer.readback.resize(importer.allocator, expected) catch return false;
        if (!importer.ensureReadback(self.width, self.height)) return false;
        clearErrors(&importer.gl);
        importer.gl.bind_framebuffer(GL_FRAMEBUFFER, importer.readback_framebuffer);
        if (importer.gl.check_framebuffer_status(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return false;
        importer.gl.viewport(0, 0, @intCast(self.width), @intCast(self.height));
        importer.gl.disable(GL_DITHER);
        importer.gl.clear_color(0, 0, 0, 0);
        importer.gl.clear(GL_COLOR_BUFFER_BIT);
        importer.gl.use_program(importer.program);
        importer.gl.active_texture(GL_TEXTURE0);
        importer.gl.bind_texture(GL_TEXTURE_2D, self.texture);
        importer.gl.uniform_1i(importer.source_uniform, 0);
        importer.gl.uniform_1i(importer.opaque_uniform, @intFromBool(self.format == DRM_FORMAT_XRGB8888));
        importer.gl.draw_arrays(GL_TRIANGLES, 0, 3);
        importer.gl.pixel_storei(GL_PACK_ALIGNMENT, 1);
        importer.gl.read_pixels(
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
            GL_RGBA,
            GL_UNSIGNED_BYTE,
            importer.readback.items.ptr,
        );
        if (takeErrors(&importer.gl)) return false;

        // EGL dma-buf texture row zero maps to the plane offset. The shader
        // maps it to framebuffer row zero, which glReadPixels emits first, so
        // the staging rows remain in buffer storage order before Y_INVERT.
        const row_bytes = @as(usize, self.width) * 4;
        if (!normalizeTopDownRows(importer.readback.items, row_bytes, @intCast(self.height), self.y_invert))
            return false;
        // Sampling and readback are RGBA; callers require BGRA bytes.
        if (!rgbaToBgra(importer.readback.items)) return false;
        @memcpy(out, importer.readback.items);
        return true;
    }
} else struct {
    pub fn deinit(self: *@This()) void {
        _ = self;
    }

    pub fn readPixels(self: *@This(), out: []u8) bool {
        _ = self;
        _ = out;
        return false;
    }
};

test "extension matching requires complete tokens" {
    try std.testing.expect(hasExtension("one EGL_EXT_image_dma_buf_import two", "EGL_EXT_image_dma_buf_import"));
    try std.testing.expect(!hasExtension("EGL_EXT_image_dma_buf_import_modifiers", "EGL_EXT_image_dma_buf_import"));
    try std.testing.expect(!hasExtension("prefixEGL_EXT_image_dma_buf_import", "EGL_EXT_image_dma_buf_import"));
}

test "capability filtering excludes external-only and duplicates" {
    var capabilities: std.ArrayList(Capability) = .empty;
    defer capabilities.deinit(std.testing.allocator);
    const modifiers = [_]u64{ 0, 7, 0, 9 };
    const external = [_]EglBoolean{ EGL_FALSE, EGL_TRUE, EGL_FALSE, EGL_FALSE };
    try appendCapabilities(std.testing.allocator, &capabilities, DRM_FORMAT_ARGB8888, &modifiers, &external);
    try std.testing.expectEqual(@as(usize, 2), capabilities.items.len);
    try std.testing.expectEqual(@as(u64, 0), capabilities.items[0].modifier);
    try std.testing.expectEqual(@as(u64, 9), capabilities.items[1].modifier);
}

test "layout validation bounds dimensions planes formats and flags" {
    const plane = Plane{ .fd = 3, .offset = 0, .stride = 64, .modifier = 0 };
    try std.testing.expect(validLayout(.{
        .width = 16,
        .height = 16,
        .format = DRM_FORMAT_XRGB8888,
        .flags = FLAG_Y_INVERT,
        .planes = &.{plane},
    }));
    try std.testing.expect(!validLayout(.{
        .width = MAX_DIMENSION + 1,
        .height = 1,
        .format = DRM_FORMAT_XRGB8888,
        .planes = &.{plane},
    }));
    try std.testing.expect(!validLayout(.{
        .width = 16,
        .height = 16,
        .format = DRM_FORMAT_XRGB8888,
        .flags = 2,
        .planes = &.{plane},
    }));
    try std.testing.expect(!validLayout(.{
        .width = 16,
        .height = 16,
        .format = DRM_FORMAT_XRGB8888,
        .planes = &.{ plane, plane },
    }));
    const auxiliary = Plane{ .fd = 4, .offset = 4096, .stride = 64, .modifier = 7 };
    const modified = Plane{ .fd = 3, .offset = 0, .stride = 64, .modifier = 7 };
    try std.testing.expect(validLayout(.{
        .width = 16,
        .height = 16,
        .format = DRM_FORMAT_XRGB8888,
        .planes = &.{ modified, auxiliary },
    }));
}

test "row normalization makes Y_INVERT top-down explicitly" {
    var normal = [_]u8{ 1, 2, 3, 4, 5, 6 };
    try std.testing.expect(normalizeTopDownRows(&normal, 2, 3, false));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, &normal);

    var inverted = [_]u8{ 1, 2, 3, 4, 5, 6 };
    try std.testing.expect(normalizeTopDownRows(&inverted, 2, 3, true));
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 3, 4, 1, 2 }, &inverted);
    try std.testing.expect(!normalizeTopDownRows(&inverted, 4, 2, true));
}

test "implicit modifier omits modifier image attributes" {
    const plane = Plane{
        .fd = 3,
        .offset = 8,
        .stride = 64,
        .modifier = DRM_FORMAT_MOD_INVALID,
    };
    const desc = Import{
        .width = 16,
        .height = 2,
        .format = DRM_FORMAT_ARGB8888,
        .planes = &.{plane},
    };
    var storage: [48]EglInt = undefined;
    const attrs = buildAttributes(desc, &storage);
    try std.testing.expectEqual(@as(usize, 13), attrs.len);
    try std.testing.expectEqual(EGL_NONE, attrs[attrs.len - 1]);
}

test "explicit modifier attributes retain both 32-bit halves" {
    const modifier: u64 = 0x0123_4567_89ab_cdef;
    const desc = Import{
        .width = 16,
        .height = 2,
        .format = DRM_FORMAT_ARGB8888,
        .planes = &.{.{
            .fd = 3,
            .offset = 8,
            .stride = 64,
            .modifier = modifier,
        }},
    };
    var storage: [48]EglInt = undefined;
    const attrs = buildAttributes(desc, &storage);
    try std.testing.expectEqual(@as(usize, 17), attrs.len);
    try std.testing.expectEqual(EGL_DMA_BUF_PLANE_MOD_LO[0], attrs[12]);
    try std.testing.expectEqual(@as(EglInt, @bitCast(@as(u32, 0x89ab_cdef))), attrs[13]);
    try std.testing.expectEqual(EGL_DMA_BUF_PLANE_MOD_HI[0], attrs[14]);
    try std.testing.expectEqual(@as(EglInt, 0x0123_4567), attrs[15]);
    try std.testing.expectEqual(EGL_NONE, attrs[16]);
}

test "auxiliary modifier planes are included in EGL image attributes" {
    const modifier: u64 = 0x1234;
    const desc = Import{
        .width = 16,
        .height = 16,
        .format = DRM_FORMAT_XRGB8888,
        .planes = &.{
            .{ .fd = 3, .offset = 0, .stride = 64, .modifier = modifier },
            .{ .fd = 4, .offset = 4096, .stride = 32, .modifier = modifier },
        },
    };
    var storage: [48]EglInt = undefined;
    const attrs = buildAttributes(desc, &storage);
    try std.testing.expectEqual(@as(usize, 27), attrs.len);
    try std.testing.expectEqual(EGL_DMA_BUF_PLANE_FD[1], attrs[16]);
    try std.testing.expectEqual(@as(EglInt, 4), attrs[17]);
    try std.testing.expectEqual(EGL_DMA_BUF_PLANE_OFFSET[1], attrs[18]);
    try std.testing.expectEqual(@as(EglInt, 4096), attrs[19]);
    try std.testing.expectEqual(EGL_NONE, attrs[26]);
}

test "RGBA readback conversion produces BGRA without changing alpha" {
    var pixels = [_]u8{ 1, 2, 3, 4, 10, 20, 30, 40 };
    try std.testing.expect(rgbaToBgra(&pixels));
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 4, 30, 20, 10, 40 }, &pixels);
    try std.testing.expect(!rgbaToBgra(pixels[0..7]));
}

test "runtime importer initializes when EGL dma-buf support is available" {
    if (!enabled) return error.SkipZigTest;
    var importer = Importer.init(std.testing.allocator) orelse return error.SkipZigTest;
    defer importer.deinit();
    for (importer.capabilities()) |capability| {
        try std.testing.expect(capability.format == DRM_FORMAT_ARGB8888 or
            capability.format == DRM_FORMAT_XRGB8888);
    }
}

test {
    std.testing.refAllDecls(@This());
}
