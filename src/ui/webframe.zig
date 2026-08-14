//! Frame-presentation primitives shared by the browser face
//! (`webface.zig`) and the extension-popup toolbar (`webaction.zig`):
//! refcounted frame mappings, BGRA `GdkMemoryTexture` building, inline
//! damage-rect decode, and the GDK-to-protocol input translations.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const proto = @import("../web/protocol.zig");
const zpool = @import("../wlhost/zpool.zig");

/// Refcounted mmap of a frame buffer (memfd or anonymous). `GBytes`
/// built over it hold a reference each; the pages stay mapped until the
/// last texture using them is released.
pub const Map = struct {
    ptr: [*]align(std.heap.page_size_min) u8,
    len: usize,
    refs: u32,
    allocator: std.mem.Allocator,

    pub fn ref(self: *Map) *Map {
        self.refs += 1;
        return self;
    }

    pub fn unref(self: *Map) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        _ = c.munmap(self.ptr, self.len);
        self.allocator.destroy(self);
    }

    pub fn gbytesDestroy(user: ?*anyopaque) callconv(.c) void {
        cast.userData(Map, user).unref();
    }
};

/// Byte length of a frame buffer, or null when the descriptor cannot be
/// trusted. Lives in `protocol.zig` beside `FrameBuffer` so the GTK-free
/// clients can validate geometry without importing this GTK module.
pub const frameSize = proto.frameSize;

/// Map a frame memfd read-only, refusing a descriptor `frameSize`
/// rejects. The caller keeps ownership of `fd`.
pub fn mapFrameFd(allocator: std.mem.Allocator, fd: c_int, w: u16, h: u16, stride: u32) ?*Map {
    const size = frameSize(w, h, stride) orelse return null;
    return mapFd(allocator, size, fd);
}

/// Map a frame memfd read-only. The caller keeps ownership of `fd`.
fn mapFd(allocator: std.mem.Allocator, size: usize, fd: c_int) ?*Map {
    const addr = c.mmap(null, size, c.PROT_READ, c.MAP_SHARED, fd, 0);
    if (addr == c.MAP_FAILED) return null;
    return wrap(allocator, addr, size);
}

/// Anonymous writable mapping for inline frames (pixels arrive in-band).
pub fn mapAnon(allocator: std.mem.Allocator, size: usize) ?*Map {
    const addr = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_PRIVATE | c.MAP_ANONYMOUS, -1, 0);
    if (addr == c.MAP_FAILED) return null;
    return wrap(allocator, addr, size);
}

fn wrap(allocator: std.mem.Allocator, addr: ?*anyopaque, size: usize) ?*Map {
    const bytes: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(addr));
    const m = allocator.create(Map) catch {
        _ = c.munmap(bytes, size);
        return null;
    };
    m.* = .{ .ptr = bytes, .len = size, .refs = 1, .allocator = allocator };
    return m;
}

/// Build a premultiplied-BGRA `GdkMemoryTexture` over `m`.
///
/// The `GBytes` refs the mapping, so a buffer replacement can never
/// pull pages out from under a texture GSK still reads. Passing
/// `update_tex` (with `region`) opts into GSK's damage-rect upload
/// economy; the caller owns the returned reference.
pub fn buildBgraTexture(
    m: *Map,
    w: u16,
    h: u16,
    stride: u32,
    update_tex: ?*c.GdkTexture,
    region: ?*c.cairo_region_t,
) ?*c.GdkTexture {
    // Second gate on the same rule as `frameSize`: a texture is the one
    // thing that reads every row, so it never trusts geometry it was
    // handed without re-checking it against the mapping.
    const need = frameSize(w, h, stride) orelse return null;
    if (need > m.len) return null;
    const builder = c.gdk_memory_texture_builder_new() orelse return null;
    defer c.g_object_unref(@ptrCast(builder));
    const bytes = c.g_bytes_new_with_free_func(m.ptr, m.len, Map.gbytesDestroy, m.ref()) orelse {
        m.unref();
        return null;
    };
    defer c.g_bytes_unref(bytes);
    c.gdk_memory_texture_builder_set_bytes(builder, bytes);
    c.gdk_memory_texture_builder_set_width(builder, w);
    c.gdk_memory_texture_builder_set_height(builder, h);
    c.gdk_memory_texture_builder_set_stride(builder, stride);
    c.gdk_memory_texture_builder_set_format(builder, c.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED);
    if (update_tex) |t| {
        c.gdk_memory_texture_builder_set_update_texture(builder, t);
        c.gdk_memory_texture_builder_set_update_region(builder, region);
    }
    return c.gdk_memory_texture_builder_build(builder);
}

/// Decode one inline rect (raw or raw-deflate BGRA) into the mapping.
///
/// @return false for an empty, out-of-bounds or malformed rect (a
/// desynchronised stream is dropped, never written) and on OOM.
pub fn decodeInlineRect(
    allocator: std.mem.Allocator,
    m: *Map,
    stride: u32,
    surface_w: u16,
    surface_h: u16,
    r: proto.InlineRect,
) bool {
    if (r.w == 0 or r.h == 0) return false;
    if (@as(u32, r.x) + r.w > surface_w or @as(u32, r.y) + r.h > surface_h) return false;
    const raw_len: usize = @as(usize, r.w) * @as(usize, r.h) * 4;
    var scratch: ?[]u8 = null;
    defer if (scratch) |s| allocator.free(s);
    const decoded: []const u8 = switch (r.enc) {
        proto.inline_enc_raw => blk: {
            if (r.data.len != raw_len) return false;
            break :blk r.data;
        },
        proto.inline_enc_deflate => blk: {
            const s = allocator.alloc(u8, raw_len) catch return false;
            scratch = s;
            break :blk zpool.decompress(r.data, s) catch return false;
        },
        else => return false,
    };
    const row_bytes: usize = @as(usize, r.w) * 4;
    var row: usize = 0;
    while (row < r.h) : (row += 1) {
        const dst = (@as(usize, r.y) + row) * stride + @as(usize, r.x) * 4;
        @memcpy(m.ptr[dst..][0..row_bytes], decoded[row * row_bytes ..][0..row_bytes]);
    }
    return true;
}

/// GDK button number (1 left, 2 middle, 3 right) to the protocol's
/// CEF-shaped byte.
pub fn cefButton(btn: c.guint) u8 {
    return switch (btn) {
        2 => 1,
        3 => 2,
        else => 0,
    };
}

pub fn modsOf(ctrl: *c.GtkEventController) u32 {
    return modsFromState(c.gtk_event_controller_get_current_event_state(ctrl));
}

/// GTK reports wheel notches (1.0 per click); Chromium's unit is 120
/// per notch.
pub fn wheelDelta(d: f64) i32 {
    return @intFromFloat(@round(d * 120.0));
}

/// The text an `input_key` carries, encoded into `buf`.
///
/// Empty for a key-up, for a Ctrl/Alt chord and for anything below
/// U+0020 or DEL: the helper maps the keyval itself, and a chord that
/// also arrived as text would be typed into the page.
pub fn keyText(buf: *[8]u8, kind: proto.KeyKind, keyval: c.guint, mods: u32) []const u8 {
    if (kind != .down) return &.{};
    if (mods & (proto.mod_ctrl | proto.mod_alt) != 0) return &.{};
    const cp = c.gdk_keyval_to_unicode(keyval);
    if (cp < 0x20 or cp == 0x7f) return &.{};
    const n = std.unicode.utf8Encode(@intCast(cp), buf) catch 0;
    return buf[0..n];
}

/// The five controllers `wireInput` added, so the caller can keep them
/// alive and tear them down the way it already does (webface tracks
/// them for a bulk disconnect, the extension popup disconnects them by
/// hand).
pub const Controllers = struct {
    motion: *c.GtkEventController,
    click: *c.GtkGesture,
    scroll: *c.GtkEventController,
    key: *c.GtkEventController,
    focus: *c.GtkEventController,
};

/// Wire pointer, scroll, key and focus events on `area` into `S`, the
/// caller's protocol-shaped sink; `user` is handed back to every call
/// untouched.
///
/// `S` is a namespace, not a value, so the nine GTK trampolines are
/// generated per sink and the widget's user-data stays the caller's own
/// pointer. It must declare, all taking `?*anyopaque` first:
/// `pointer(kind, x, y, button, clicks, mods)`,
/// `scroll(dx, dy, mods) c.gboolean`,
/// `key(kind, keyval, keycode, state) c.gboolean` and
/// `focus(focused: bool)`. Policy above the translation — hint modes,
/// zoom chords, window chords, pacing promotion — belongs in the sink.
pub fn wireInput(comptime S: type, area: *c.GtkWidget, user: *anyopaque) ?Controllers {
    const T = Trampolines(S);
    const motion = c.gtk_event_controller_motion_new() orelse return null;
    const click = c.gtk_gesture_click_new() orelse return null;
    const scroll = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES) orelse return null;
    const key = c.gtk_event_controller_key_new() orelse return null;
    const focus = c.gtk_event_controller_focus_new() orelse return null;

    _ = c.g_signal_connect_data(motion, "motion", @ptrCast(&T.onMotion), user, null, 0);
    _ = c.g_signal_connect_data(motion, "leave", @ptrCast(&T.onPointerLeave), user, null, 0);
    c.gtk_widget_add_controller(area, motion);

    c.gtk_gesture_single_set_button(@ptrCast(click), 0);
    _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&T.onPressed), user, null, 0);
    _ = c.g_signal_connect_data(click, "released", @ptrCast(&T.onReleased), user, null, 0);
    c.gtk_widget_add_controller(area, @ptrCast(click));

    _ = c.g_signal_connect_data(scroll, "scroll", @ptrCast(&T.onScroll), user, null, 0);
    c.gtk_widget_add_controller(area, scroll);

    _ = c.g_signal_connect_data(key, "key-pressed", @ptrCast(&T.onKeyPressed), user, null, 0);
    _ = c.g_signal_connect_data(key, "key-released", @ptrCast(&T.onKeyReleased), user, null, 0);
    c.gtk_widget_add_controller(area, key);

    _ = c.g_signal_connect_data(focus, "enter", @ptrCast(&T.onFocusEnter), user, null, 0);
    _ = c.g_signal_connect_data(focus, "leave", @ptrCast(&T.onFocusLeave), user, null, 0);
    c.gtk_widget_add_controller(area, focus);

    return .{ .motion = motion, .click = @ptrCast(click), .scroll = scroll, .key = key, .focus = focus };
}

fn Trampolines(comptime S: type) type {
    return struct {
        fn onMotion(ctrl: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
            S.pointer(user, .move, x, y, 0, 0, modsOf(@ptrCast(ctrl)));
        }

        fn onPointerLeave(ctrl: *c.GtkEventControllerMotion, user: ?*anyopaque) callconv(.c) void {
            // A leave carries no position; a sink that wants the last
            // one it saw substitutes it.
            S.pointer(user, .leave, 0, 0, 0, 0, modsOf(@ptrCast(ctrl)));
        }

        fn onPressed(g: *c.GtkGestureClick, n: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
            const button = cefButton(c.gtk_gesture_single_get_current_button(@ptrCast(g)));
            S.pointer(user, .down, x, y, button, @intCast(@max(n, 1)), modsOf(@ptrCast(g)));
        }

        fn onReleased(g: *c.GtkGestureClick, n: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
            const button = cefButton(c.gtk_gesture_single_get_current_button(@ptrCast(g)));
            S.pointer(user, .up, x, y, button, @intCast(@max(n, 1)), modsOf(@ptrCast(g)));
        }

        fn onScroll(ctrl: *c.GtkEventControllerScroll, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
            return S.scroll(user, dx, dy, modsOf(@ptrCast(ctrl)));
        }

        fn onKeyPressed(
            _: *c.GtkEventControllerKey,
            keyval: c.guint,
            keycode: c.guint,
            state: c.GdkModifierType,
            user: ?*anyopaque,
        ) callconv(.c) c.gboolean {
            return S.key(user, .down, keyval, keycode, state);
        }

        fn onKeyReleased(
            _: *c.GtkEventControllerKey,
            keyval: c.guint,
            keycode: c.guint,
            state: c.GdkModifierType,
            user: ?*anyopaque,
        ) callconv(.c) void {
            _ = S.key(user, .up, keyval, keycode, state);
        }

        fn onFocusEnter(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
            S.focus(user, true);
        }

        fn onFocusLeave(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
            S.focus(user, false);
        }
    };
}

pub fn modsFromState(state: c.GdkModifierType) u32 {
    var mods: u32 = 0;
    const s: c_int = @intCast(state);
    if (s & c.GDK_SHIFT_MASK != 0) mods |= proto.mod_shift;
    if (s & c.GDK_CONTROL_MASK != 0) mods |= proto.mod_ctrl;
    if (s & c.GDK_ALT_MASK != 0) mods |= proto.mod_alt;
    if (s & c.GDK_SUPER_MASK != 0) mods |= proto.mod_super;
    if (s & c.GDK_LOCK_MASK != 0) mods |= proto.mod_capslock;
    return mods;
}
