//! Wayland presenter: every OSR view becomes a real toplevel on the
//! session hub, so a human can watch (and take over) what an assistant
//! browses through the ordinary app-session machinery.
//!
//! A hand-rolled Wayland CLIENT over `wlhost/wire.zig` framing: the
//! helper links libc and CEF only, so libwayland is not available and
//! not wanted. It binds wl_compositor, wl_shm, wl_seat and xdg_wm_base
//! on the display named by `WAYLAND_DISPLAY`, creates one xdg_toplevel
//! per presentable view on that view's FIRST paint, and blits the
//! helper's own frame buffer (the memfd/anonymous mapping `onPaint`
//! already fills) into a double-buffered wl_shm pool. Seat events on a
//! presenter surface are handed back to the host through `Sink`, which
//! turns them into the same engine input the wire protocol uses.
//!
//! It is armed ONLY by `SKETERM_WEB_PRESENTER=1`, which `webdrive.zig`
//! sets for a helper it started as a mux app session's client. A
//! `WAYLAND_DISPLAY` alone must never arm it: a helper the GUI spawned
//! inherits the user's real compositor, and a browser toplevel popping
//! up on the desktop for every hidden pane would be a bug.
//!
//! Single-threaded by construction, like everything in the helper: the
//! display fd joins `server.zig`'s one poll loop and `pump` runs there.
//! Any protocol error or a dead display DISARMS the presenter (one
//! log line); the helper keeps serving its clients exactly as before,
//! because presentation is an observer of the engine, never a party to
//! it.
//!
//! Frame pacing follows wl_surface.frame: while a frame callback is
//! outstanding, or no buffer is free (the hub releases a buffer right
//! after copying it), paints only widen the pending damage rect; the
//! next flush copies the union from the LIVE source buffer, so the
//! newest pixels always win and a slow viewer never queues frames.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const wire = @import("../wlhost/wire.zig");
const xkblayout = @import("../ipc/xkblayout.zig");
const clock = @import("../util/clock.zig");
const platform = @import("../util/platform.zig");

/// The environment flag that arms the presenter. Set by webdrive for a
/// session-mode helper; nothing else may set it.
pub const ENV_FLAG = @import("protocol.zig").CAP_PRESENTER_ENV;
/// app_id of every presenter toplevel: the browser identity, so a
/// viewer that adopts the window groups and icons it as sketerm-web.
pub const APP_ID = "dev.sker.sketerm.web";

/// The last keycode the seat may name plus one; evdev keys are small.
const KEY_TABLE = 256;
/// Two presses of one button this close (ms, px) are a double click.
const MULTI_CLICK_MS: i64 = 400;
const MULTI_CLICK_PX: u32 = 4;
/// How long `start` waits for the hub's registry and bind roundtrips.
const HANDSHAKE_MS: i64 = 3000;
/// How long an fd-carrying request may wait for the outbox to drain.
const FLUSH_MS: i64 = 500;

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

pub const PointerKind = enum(u8) { move, down, up, leave };

/// Where seat input on a presented surface goes. Coordinates are in
/// the view's LOGICAL space (what the wire protocol's input frames
/// carry), `button` follows the protocol (0 left, 1 middle, 2 right),
/// `mods` the protocol's modifier bits, `keysym` an XKB keysym and
/// `keycode` the X keycode (evdev + 8).
pub const Sink = struct {
    ctx: ?*anyopaque,
    pointer: *const fn (ctx: ?*anyopaque, view: u32, kind: PointerKind, x: i32, y: i32, button: u8, clicks: u8, mods: u32) void,
    scroll: *const fn (ctx: ?*anyopaque, view: u32, x: i32, y: i32, dx: i32, dy: i32, mods: u32) void,
    key: *const fn (ctx: ?*anyopaque, view: u32, keysym: u32, keycode: u32, mods: u32, pressed: bool) void,
};

/// Protocol modifier bits (the wire protocol's `mod_*` vocabulary,
/// mirrored here so this file stays protocol-free; cefhost asserts the
/// two agree).
pub const mod_shift: u32 = 1;
pub const mod_ctrl: u32 = 2;
pub const mod_alt: u32 = 4;
pub const mod_super: u32 = 8;
pub const mod_capslock: u32 = 16;
pub const mod_numlock: u32 = 32;

/// xkb modifier masks in the pc105 order every embedded keymap uses.
const xkb_shift: u32 = 1 << 0;
const xkb_lock: u32 = 1 << 1;
const xkb_control: u32 = 1 << 2;
const xkb_mod1: u32 = 1 << 3;
const xkb_mod2: u32 = 1 << 4;
const xkb_mod4: u32 = 1 << 6;
/// Mod5 is AltGr on every embedded layout.
const xkb_mod5: u32 = 1 << 7;

/// xkb depressed/latched/locked masks -> protocol modifier bits. All
/// three states count as active: a latched or locked (sticky-keys)
/// Control is a held Control as far as the page is concerned, and Caps
/// and Num Lock only ever arrive locked.
pub fn modsFromXkb(depressed: u32, latched: u32, locked: u32) u32 {
    const eff = depressed | latched | locked;
    var out: u32 = 0;
    if (eff & xkb_shift != 0) out |= mod_shift;
    if (eff & xkb_control != 0) out |= mod_ctrl;
    if (eff & xkb_mod1 != 0) out |= mod_alt;
    if (eff & xkb_mod4 != 0) out |= mod_super;
    if (eff & xkb_lock != 0) out |= mod_capslock;
    if (eff & xkb_mod2 != 0) out |= mod_numlock;
    return out;
}

/// Bounding box of `a` and `b`.
pub fn unionRect(a: ?Rect, b: Rect) Rect {
    const d = a orelse return b;
    const x0 = @min(d.x, b.x);
    const y0 = @min(d.y, b.y);
    const x1 = @max(@as(u32, d.x) + d.w, @as(u32, b.x) + b.w);
    const y1 = @max(@as(u32, d.y) + d.h, @as(u32, b.y) + b.h);
    return .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
}

/// Physical surface coordinate -> the view's logical coordinate.
pub fn logical(v: f64, scale_x1000: u16) i32 {
    const s: f64 = @floatFromInt(if (scale_x1000 == 0) 1000 else scale_x1000);
    return @intFromFloat(@round(v * 1000.0 / s));
}

/// evdev button code -> protocol button (0 left, 1 middle, 2 right).
pub fn protoButton(evdev: u32) ?u8 {
    return switch (evdev) {
        0x110 => 0,
        0x112 => 1,
        0x111 => 2,
        else => null,
    };
}

/// Keysyms for the keys no character keymap names: editing, navigation,
/// function and modifier keys, by evdev code.
pub fn specialKeysym(code: u32) ?u32 {
    return switch (code) {
        1 => 0xff1b, // Escape
        14 => 0xff08, // BackSpace
        15 => 0xff09, // Tab
        28 => 0xff0d, // Return
        29 => 0xffe3, // Control_L
        42 => 0xffe1, // Shift_L
        54 => 0xffe2, // Shift_R
        56 => 0xffe9, // Alt_L
        58 => 0xffe5, // Caps_Lock
        59...68 => 0xffbe + (code - 59), // F1..F10
        69 => 0xff7f, // Num_Lock
        70 => 0xff14, // Scroll_Lock
        87 => 0xffc8, // F11
        88 => 0xffc9, // F12
        96 => 0xff8d, // KP_Enter
        97 => 0xffe4, // Control_R
        100 => 0xffea, // Alt_R
        102 => 0xff50, // Home
        103 => 0xff52, // Up
        104 => 0xff55, // Prior
        105 => 0xff51, // Left
        106 => 0xff53, // Right
        107 => 0xff57, // End
        108 => 0xff54, // Down
        109 => 0xff56, // Next
        110 => 0xff63, // Insert
        111 => 0xffff, // Delete
        119 => 0xff13, // Pause
        125 => 0xffeb, // Super_L
        126 => 0xffec, // Super_R
        else => null,
    };
}

/// Codepoint -> keysym, the encoding `keymap.zig` decodes on the far
/// side (Latin-1 is its own keysym, the rest is the Unicode keysym).
pub fn keysymFromCodepoint(cp: u21) u32 {
    if (cp >= 0x20 and cp <= 0xff) return cp;
    return 0x01000000 | @as(u32, cp);
}

/// One key of the session keymap, by level.
const KeyChars = struct { plain: u21 = 0, shift: u21 = 0, altgr: u21 = 0, shift_altgr: u21 = 0 };

/// The paint decision, kept pure so it is testable without a socket:
/// a surface may take new pixels only once the hub has configured it,
/// with no frame callback outstanding, when a buffer is free and there
/// is damage to show. Returns the buffer to draw into.
pub const FrameGate = struct {
    configured: bool = false,
    frame_pending: bool = false,
    busy: [2]bool = .{ false, false },
    dirty: ?Rect = null,

    pub fn ready(self: *const FrameGate) ?usize {
        if (!self.configured or self.frame_pending or self.dirty == null) return null;
        for (self.busy, 0..) |b, i| {
            if (!b) return i;
        }
        return null;
    }
};

const ObjKind = enum {
    display,
    registry,
    sync_cb,
    frame_cb,
    compositor,
    shm,
    seat,
    pointer,
    keyboard,
    wm_base,
    surface,
    xdg_surface,
    toplevel,
    pool,
    buffer,
};

const Global = struct { name: u32 = 0, version: u32 = 0 };

const Surface = struct {
    view: u32,
    wl_surface: u32 = 0,
    xdg_surface: u32 = 0,
    toplevel: u32 = 0,
    pw: u16 = 0,
    ph: u16 = 0,
    scale_x1000: u16 = 1000,
    pool_id: u32 = 0,
    pool_fd: c_int = -1,
    pool_map: []align(std.heap.page_size_min) u8 = &.{},
    bufs: [2]u32 = .{ 0, 0 },
    gate: FrameGate = .{},
    /// The helper's own frame buffer for this view (BGRA, stride pw*4),
    /// valid between paints; re-pointed on every paint.
    src: []const u8 = &.{},
};

pub const Presenter = struct {
    gpa: std.mem.Allocator,
    sink: Sink,
    fd: c_int = -1,
    active: bool = false,
    inbuf: std.ArrayList(u8) = .empty,
    in_fds: std.ArrayList(c_int) = .empty,
    out: std.ArrayList(u8) = .empty,
    objects: std.AutoHashMapUnmanaged(u32, ObjKind) = .empty,
    /// Frame callback id -> the wl_surface it paces.
    frame_cbs: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Buffer id -> the wl_surface owning it.
    buffer_owner: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    next_id: u32 = 2,
    g_compositor: Global = .{},
    g_shm: Global = .{},
    g_seat: Global = .{},
    g_wm_base: Global = .{},
    compositor: u32 = 0,
    shm: u32 = 0,
    seat: u32 = 0,
    wm_base: u32 = 0,
    pointer: u32 = 0,
    keyboard: u32 = 0,
    sync_pending: u32 = 0,
    surfaces: std.ArrayList(Surface) = .empty,
    /// Titles by view, kept for surfaces that do not exist yet.
    titles: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    ptr_focus: u32 = 0,
    ptr_x: f64 = 0,
    ptr_y: f64 = 0,
    kbd_focus: u32 = 0,
    mods: u32 = 0,
    /// AltGr (Mod5) is not a protocol modifier; it only selects the
    /// keymap level, so it is tracked beside `mods`.
    altgr: bool = false,
    last_press_ms: i64 = 0,
    last_press_button: u8 = 0,
    last_press_x: i32 = 0,
    last_press_y: i32 = 0,
    clicks: u8 = 1,
    keys: [KEY_TABLE]KeyChars = @splat(.{}),
    have_keymap: bool = false,
    disarm_reason: []const u8 = "",

    /// Arm the presenter when the environment says so and the display
    /// answers; null otherwise, and the helper runs unpresented.
    pub fn start(gpa: std.mem.Allocator, sink: Sink) ?*Presenter {
        if (builtin.target.os.tag != .linux) return null;
        const flag = c.getenv(ENV_FLAG) orelse return null;
        if (!std.mem.eql(u8, std.mem.span(flag), "1")) return null;
        const self = gpa.create(Presenter) catch return null;
        self.* = .{ .gpa = gpa, .sink = sink };
        if (!self.connect()) {
            self.destroy();
            return null;
        }
        if (!self.handshake()) {
            std.debug.print("sketerm-web: presenter disarmed during handshake: {s}\n", .{self.disarm_reason});
            self.destroy();
            return null;
        }
        self.active = true;
        return self;
    }

    pub fn deinit(self: *Presenter) void {
        self.destroy();
    }

    fn destroy(self: *Presenter) void {
        const gpa = self.gpa;
        for (self.surfaces.items) |*s| self.releasePool(s);
        self.surfaces.deinit(gpa);
        var it = self.titles.valueIterator();
        while (it.next()) |title| gpa.free(title.*);
        self.titles.deinit(gpa);
        for (self.in_fds.items) |fd| _ = c.close(fd);
        self.in_fds.deinit(gpa);
        self.inbuf.deinit(gpa);
        self.out.deinit(gpa);
        self.objects.deinit(gpa);
        self.frame_cbs.deinit(gpa);
        self.buffer_owner.deinit(gpa);
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        gpa.destroy(self);
    }

    /// The display fd, for the server's poll set; -1 once disarmed.
    pub fn pollFd(self: *const Presenter) c_int {
        return if (self.active) self.fd else -1;
    }

    pub fn wantsWrite(self: *const Presenter) bool {
        return self.active and self.out.items.len != 0;
    }

    // -- connection ------------------------------------------------------

    fn connect(self: *Presenter) bool {
        const disp = c.getenv("WAYLAND_DISPLAY") orelse return self.disarm("no WAYLAND_DISPLAY");
        var path_buf: [108]u8 = undefined;
        const disp_s = std.mem.span(disp);
        const path = if (disp_s.len != 0 and disp_s[0] == '/')
            disp_s
        else blk: {
            const rt = c.getenv("XDG_RUNTIME_DIR") orelse return self.disarm("relative WAYLAND_DISPLAY without XDG_RUNTIME_DIR");
            break :blk std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ std.mem.span(rt), disp_s }) catch return self.disarm("display path too long");
        };
        var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        addr.sun_family = c.AF_UNIX;
        if (path.len >= addr.sun_path.len) return self.disarm("display path too long");
        @memcpy(addr.sun_path[0..path.len], path);
        const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return self.disarm("socket() failed");
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
            _ = c.close(fd);
            return self.disarm("connect to the display failed");
        }
        _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
        self.fd = fd;
        self.objects.put(self.gpa, 1, .display) catch return self.disarm("oom");
        return true;
    }

    /// get_registry + sync, bind the four globals, get the seat
    /// devices, sync again: after this the hub has either accepted
    /// every bind or reported an error.
    fn handshake(self: *Presenter) bool {
        const registry = self.allocId(.registry);
        var buf: [64]u8 = undefined;
        {
            var b = wire.Builder.init(&buf, 1, 1); // wl_display.get_registry
            b.putNewId(registry);
            self.emit(b.finish() catch return self.disarm("encode"));
        }
        if (!self.roundtrip()) return false;
        if (self.g_compositor.name == 0 or self.g_shm.name == 0 or self.g_seat.name == 0 or self.g_wm_base.name == 0)
            return self.disarm("the display lacks wl_compositor, wl_shm, wl_seat or xdg_wm_base");
        self.compositor = self.bind(registry, self.g_compositor, "wl_compositor", 4, .compositor) orelse return false;
        self.shm = self.bind(registry, self.g_shm, "wl_shm", 1, .shm) orelse return false;
        self.seat = self.bind(registry, self.g_seat, "wl_seat", 5, .seat) orelse return false;
        self.wm_base = self.bind(registry, self.g_wm_base, "xdg_wm_base", 2, .wm_base) orelse return false;
        self.pointer = self.allocId(.pointer);
        {
            var b = wire.Builder.init(&buf, self.seat, 0); // get_pointer
            b.putNewId(self.pointer);
            self.emit(b.finish() catch return self.disarm("encode"));
        }
        self.keyboard = self.allocId(.keyboard);
        {
            var b = wire.Builder.init(&buf, self.seat, 1); // get_keyboard
            b.putNewId(self.keyboard);
            self.emit(b.finish() catch return self.disarm("encode"));
        }
        return self.roundtrip();
    }

    fn bind(self: *Presenter, registry: u32, g: Global, iface: []const u8, want: u32, kind: ObjKind) ?u32 {
        const id = self.allocId(kind);
        var buf: [96]u8 = undefined;
        var b = wire.Builder.init(&buf, registry, 0); // wl_registry.bind
        b.putUint(g.name);
        b.putString(iface);
        b.putUint(@min(g.version, want));
        b.putNewId(id);
        self.emit(b.finish() catch {
            _ = self.disarm("encode");
            return null;
        });
        return id;
    }

    /// wl_display.sync and block (bounded) until its done arrives.
    fn roundtrip(self: *Presenter) bool {
        const cb = self.allocId(.sync_cb);
        var buf: [16]u8 = undefined;
        var b = wire.Builder.init(&buf, 1, 0); // wl_display.sync
        b.putNewId(cb);
        self.emit(b.finish() catch return self.disarm("encode"));
        self.sync_pending = cb;
        const deadline = clock.nowMs() + HANDSHAKE_MS;
        while (self.sync_pending != 0) {
            if (clock.nowMs() >= deadline) return self.disarm("the display did not answer a sync");
            if (!self.flushOut()) return false;
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            const n = c.poll(@ptrCast(&pfd), 1, 50);
            if (n < 0 and std.posix.errno(n) != .INTR) return self.disarm("poll failed");
            if (n > 0 and !self.readIn()) return false;
            if (!self.process()) return false;
        }
        return true;
    }

    fn allocId(self: *Presenter, kind: ObjKind) u32 {
        const id = self.next_id;
        self.next_id += 1;
        self.objects.put(self.gpa, id, kind) catch {};
        return id;
    }

    fn disarm(self: *Presenter, reason: []const u8) bool {
        if (self.disarm_reason.len == 0) self.disarm_reason = reason;
        if (self.active) {
            std.debug.print("sketerm-web: presenter disarmed: {s}\n", .{reason});
            self.active = false;
        }
        return false;
    }

    // -- output ----------------------------------------------------------

    fn emit(self: *Presenter, msg: []const u8) void {
        self.out.appendSlice(self.gpa, msg) catch {
            _ = self.disarm("oom");
        };
    }

    /// Write what the socket takes; the rest waits for POLLOUT.
    fn flushOut(self: *Presenter) bool {
        // No display (the unit tests build request streams without
        // one): the outbox simply accumulates.
        if (self.fd < 0) return true;
        while (self.out.items.len != 0) {
            const n = c.write(self.fd, self.out.items.ptr, self.out.items.len);
            if (n < 0) {
                const e = std.posix.errno(n);
                if (e == .AGAIN) return true;
                if (e == .INTR) continue;
                return self.disarm("display write failed");
            }
            if (n == 0) return self.disarm("display closed");
            const done: usize = @intCast(n);
            const rest = self.out.items.len - done;
            std.mem.copyForwards(u8, self.out.items[0..rest], self.out.items[done..]);
            self.out.shrinkRetainingCapacity(rest);
        }
        return true;
    }

    /// Drain the outbox, waiting up to FLUSH_MS, so an fd-carrying
    /// message can go out in order.
    fn flushOutBlocking(self: *Presenter) bool {
        const deadline = clock.nowMs() + FLUSH_MS;
        while (self.out.items.len != 0) {
            if (!self.flushOut()) return false;
            if (self.out.items.len == 0) break;
            if (clock.nowMs() >= deadline) return self.disarm("display outbox stalled");
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLOUT, .revents = 0 };
            _ = c.poll(@ptrCast(&pfd), 1, 20);
        }
        return true;
    }

    /// One message with a descriptor riding SCM_RIGHTS (create_pool).
    fn emitWithFd(self: *Presenter, msg: []const u8, fd: c_int) bool {
        if (!self.flushOutBlocking()) return false;
        var iov = c.struct_iovec{ .iov_base = @constCast(msg.ptr), .iov_len = msg.len };
        var cbuf: [32]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([32]u8);
        const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
        const cmsg: *c.struct_cmsghdr = @ptrCast(&cbuf);
        cmsg.cmsg_len = @intCast(hdr_size + @sizeOf(c_int));
        cmsg.cmsg_level = c.SOL_SOCKET;
        cmsg.cmsg_type = c.SCM_RIGHTS;
        @memcpy(cbuf[hdr_size..][0..@sizeOf(c_int)], std.mem.asBytes(&fd));
        var mh = std.mem.zeroes(c.struct_msghdr);
        mh.msg_iov = @ptrCast(&iov);
        mh.msg_iovlen = 1;
        mh.msg_control = &cbuf;
        mh.msg_controllen = @intCast(std.mem.alignForward(usize, hdr_size + @sizeOf(c_int), @sizeOf(usize)));
        const deadline = clock.nowMs() + FLUSH_MS;
        while (true) {
            const n = c.sendmsg(self.fd, &mh, if (@hasDecl(c, "MSG_NOSIGNAL")) c.MSG_NOSIGNAL else 0);
            if (n == @as(isize, @intCast(msg.len))) return true;
            if (n < 0 and std.posix.errno(n) == .AGAIN and clock.nowMs() < deadline) {
                var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLOUT, .revents = 0 };
                _ = c.poll(@ptrCast(&pfd), 1, 20);
                continue;
            }
            return self.disarm("could not hand the pool descriptor to the display");
        }
    }

    // -- input -----------------------------------------------------------

    /// Serve the display: read everything available, parse, act,
    /// flush. Called once per poll iteration; cheap when idle.
    pub fn pump(self: *Presenter) void {
        if (!self.active) return;
        if (!self.readIn()) return;
        if (!self.process()) return;
        _ = self.flushOut();
    }

    fn readIn(self: *Presenter) bool {
        var rounds: u8 = 0;
        while (rounds < 8) : (rounds += 1) {
            var data: [16384]u8 = undefined;
            var cbuf: [256]u8 align(@alignOf(c.struct_cmsghdr)) = undefined;
            var iov = c.struct_iovec{ .iov_base = &data, .iov_len = data.len };
            var mh = std.mem.zeroes(c.struct_msghdr);
            mh.msg_iov = @ptrCast(&iov);
            mh.msg_iovlen = 1;
            mh.msg_control = &cbuf;
            mh.msg_controllen = cbuf.len;
            const r = c.recvmsg(self.fd, &mh, 0);
            if (r < 0) {
                const e = std.posix.errno(r);
                if (e == .AGAIN) return true;
                if (e == .INTR) continue;
                return self.disarm("display read failed");
            }
            if (r == 0) return self.disarm("the display went away");
            self.collectFds(&mh);
            self.inbuf.appendSlice(self.gpa, data[0..@intCast(r)]) catch return self.disarm("oom");
            if (@as(usize, @intCast(r)) < data.len) return true;
        }
        return true;
    }

    /// Hand-rolled CMSG walk (the CMSG_* macros do not survive
    /// translate-c): on 64-bit glibc and musl the header is 16 bytes and
    /// data follows it directly.
    fn collectFds(self: *Presenter, mh: *const c.struct_msghdr) void {
        const ctl: [*]const u8 = @ptrCast(mh.msg_control orelse return);
        const clen: usize = @intCast(mh.msg_controllen);
        const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
        const alignment: usize = @sizeOf(usize);
        var off: usize = 0;
        while (off + hdr_size <= clen) {
            const hdr: *const c.struct_cmsghdr = @ptrCast(@alignCast(ctl + off));
            const cl: usize = @intCast(hdr.cmsg_len);
            if (cl < hdr_size or off + cl > clen) break;
            if (hdr.cmsg_level == c.SOL_SOCKET and hdr.cmsg_type == c.SCM_RIGHTS) {
                const n_fds = (cl - hdr_size) / @sizeOf(c_int);
                var i: usize = 0;
                while (i < n_fds) : (i += 1) {
                    var fd: c_int = undefined;
                    @memcpy(std.mem.asBytes(&fd), ctl[off + hdr_size + i * @sizeOf(c_int) ..][0..@sizeOf(c_int)]);
                    _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
                    self.in_fds.append(self.gpa, fd) catch {
                        _ = c.close(fd);
                    };
                }
            }
            off += (cl + alignment - 1) & ~(alignment - 1);
        }
    }

    fn takeFd(self: *Presenter) ?c_int {
        if (self.in_fds.items.len == 0) return null;
        return self.in_fds.orderedRemove(0);
    }

    /// Peel and act on every complete message in the inbox.
    fn process(self: *Presenter) bool {
        var pos: usize = 0;
        while (true) {
            const hdr = (wire.parseHeader(self.inbuf.items[pos..]) catch return self.disarm("malformed display message")) orelse break;
            if (self.inbuf.items[pos..].len < hdr.size) break;
            const body = self.inbuf.items[pos + wire.header_size .. pos + hdr.size];
            if (!self.event(hdr, body)) return false;
            pos += hdr.size;
        }
        if (pos != 0) {
            const rest = self.inbuf.items.len - pos;
            std.mem.copyForwards(u8, self.inbuf.items[0..rest], self.inbuf.items[pos..]);
            self.inbuf.shrinkRetainingCapacity(rest);
        }
        return true;
    }

    fn event(self: *Presenter, hdr: wire.Header, body: []const u8) bool {
        const kind = self.objects.get(hdr.object) orelse return true;
        switch (kind) {
            .display => switch (hdr.opcode) {
                0 => return self.disarm("the display reported a protocol error"),
                else => {},
            },
            .registry => if (hdr.opcode == 0) {
                var it = wire.ArgIter.init(body, "usu");
                const name = ((it.next() catch return self.disarm("bad global")) orelse return true).uint;
                const iface = ((it.next() catch return self.disarm("bad global")) orelse return true).string orelse return true;
                const version = ((it.next() catch return self.disarm("bad global")) orelse return true).uint;
                const g = Global{ .name = name, .version = version };
                if (std.mem.eql(u8, iface, "wl_compositor")) self.g_compositor = g;
                if (std.mem.eql(u8, iface, "wl_shm")) self.g_shm = g;
                if (std.mem.eql(u8, iface, "wl_seat")) self.g_seat = g;
                if (std.mem.eql(u8, iface, "xdg_wm_base")) self.g_wm_base = g;
            },
            .sync_cb => if (hdr.opcode == 0) {
                if (self.sync_pending == hdr.object) self.sync_pending = 0;
                _ = self.objects.remove(hdr.object);
            },
            .frame_cb => if (hdr.opcode == 0) {
                _ = self.objects.remove(hdr.object);
                if (self.frame_cbs.fetchRemove(hdr.object)) |kv| {
                    if (self.surfaceByWl(kv.value)) |s| {
                        s.gate.frame_pending = false;
                        if (!self.flushSurface(s)) return false;
                    }
                }
            },
            .buffer => if (hdr.opcode == 0) { // release
                const owner = self.buffer_owner.get(hdr.object) orelse return true;
                if (self.surfaceByWl(owner)) |s| {
                    for (s.bufs, 0..) |id, i| {
                        if (id == hdr.object) s.gate.busy[i] = false;
                    }
                    if (!self.flushSurface(s)) return false;
                }
            },
            .wm_base => if (hdr.opcode == 0) { // ping
                var it = wire.ArgIter.init(body, "u");
                const serial = ((it.next() catch return self.disarm("bad ping")) orelse return true).uint;
                var buf: [16]u8 = undefined;
                var b = wire.Builder.init(&buf, self.wm_base, 3); // pong
                b.putUint(serial);
                self.emit(b.finish() catch return self.disarm("encode"));
            },
            .xdg_surface => if (hdr.opcode == 0) { // configure
                var it = wire.ArgIter.init(body, "u");
                const serial = ((it.next() catch return self.disarm("bad configure")) orelse return true).uint;
                var buf: [16]u8 = undefined;
                var b = wire.Builder.init(&buf, hdr.object, 4); // ack_configure
                b.putUint(serial);
                self.emit(b.finish() catch return self.disarm("encode"));
                if (self.surfaceByXdg(hdr.object)) |s| {
                    s.gate.configured = true;
                    if (!self.flushSurface(s)) return false;
                }
            },
            .pointer => return self.pointerEvent(hdr.opcode, body),
            .keyboard => return self.keyboardEvent(hdr.opcode, body),
            else => {},
        }
        return true;
    }

    fn pointerEvent(self: *Presenter, opcode: u16, body: []const u8) bool {
        switch (opcode) {
            0 => { // enter(serial, surface, x, y)
                var it = wire.ArgIter.init(body, "uoff");
                _ = it.next() catch return self.disarm("bad pointer event");
                const sid = ((it.next() catch return self.disarm("bad pointer event")) orelse return true).object;
                const x = wire.fixedToF64(((it.next() catch return self.disarm("bad pointer event")) orelse return true).fixed);
                const y = wire.fixedToF64(((it.next() catch return self.disarm("bad pointer event")) orelse return true).fixed);
                self.ptr_focus = sid;
                self.pointerMove(x, y);
            },
            1 => { // leave
                if (self.surfaceByWl(self.ptr_focus)) |s| {
                    self.sink.pointer(self.sink.ctx, s.view, .leave, logical(self.ptr_x, s.scale_x1000), logical(self.ptr_y, s.scale_x1000), 0, 0, self.mods);
                }
                self.ptr_focus = 0;
            },
            2 => { // motion(time, x, y)
                var it = wire.ArgIter.init(body, "uff");
                _ = it.next() catch return self.disarm("bad pointer event");
                const x = wire.fixedToF64(((it.next() catch return self.disarm("bad pointer event")) orelse return true).fixed);
                const y = wire.fixedToF64(((it.next() catch return self.disarm("bad pointer event")) orelse return true).fixed);
                self.pointerMove(x, y);
            },
            3 => { // button(serial, time, button, state)
                var it = wire.ArgIter.init(body, "uuuu");
                _ = it.next() catch return self.disarm("bad pointer event");
                _ = it.next() catch return self.disarm("bad pointer event");
                const code = ((it.next() catch return self.disarm("bad pointer event")) orelse return true).uint;
                const state = ((it.next() catch return self.disarm("bad pointer event")) orelse return true).uint;
                self.pointerButton(code, state != 0);
            },
            4 => { // axis(time, axis, value)
                var it = wire.ArgIter.init(body, "uuf");
                _ = it.next() catch return self.disarm("bad pointer event");
                const axis = ((it.next() catch return self.disarm("bad pointer event")) orelse return true).uint;
                const value = wire.fixedToF64(((it.next() catch return self.disarm("bad pointer event")) orelse return true).fixed);
                const s = self.surfaceByWl(self.ptr_focus) orelse return true;
                const dv = logical(value, s.scale_x1000);
                const dx: i32 = if (axis == 1) dv else 0;
                const dy: i32 = if (axis == 0) dv else 0;
                if (dx == 0 and dy == 0) return true;
                self.sink.scroll(self.sink.ctx, s.view, logical(self.ptr_x, s.scale_x1000), logical(self.ptr_y, s.scale_x1000), dx, dy, self.mods);
            },
            else => {},
        }
        return true;
    }

    fn pointerMove(self: *Presenter, x: f64, y: f64) void {
        self.ptr_x = x;
        self.ptr_y = y;
        const s = self.surfaceByWl(self.ptr_focus) orelse return;
        self.sink.pointer(self.sink.ctx, s.view, .move, logical(x, s.scale_x1000), logical(y, s.scale_x1000), 0, 0, self.mods);
    }

    fn pointerButton(self: *Presenter, code: u32, pressed: bool) void {
        const s = self.surfaceByWl(self.ptr_focus) orelse return;
        const button = protoButton(code) orelse return;
        const lx = logical(self.ptr_x, s.scale_x1000);
        const ly = logical(self.ptr_y, s.scale_x1000);
        if (pressed) {
            const now = clock.nowMs();
            const near = @abs(lx - self.last_press_x) <= MULTI_CLICK_PX and @abs(ly - self.last_press_y) <= MULTI_CLICK_PX;
            if (button == self.last_press_button and now - self.last_press_ms <= MULTI_CLICK_MS and near) {
                self.clicks = @min(self.clicks + 1, 3);
            } else {
                self.clicks = 1;
            }
            self.last_press_ms = now;
            self.last_press_button = button;
            self.last_press_x = lx;
            self.last_press_y = ly;
        }
        self.sink.pointer(self.sink.ctx, s.view, if (pressed) .down else .up, lx, ly, button, self.clicks, self.mods);
    }

    fn keyboardEvent(self: *Presenter, opcode: u16, body: []const u8) bool {
        switch (opcode) {
            0 => { // keymap(format, fd, size)
                var it = wire.ArgIter.init(body, "uhu");
                const format = ((it.next() catch return self.disarm("bad keymap")) orelse return true).uint;
                _ = it.next() catch return self.disarm("bad keymap");
                const size = ((it.next() catch return self.disarm("bad keymap")) orelse return true).uint;
                const fd = self.takeFd() orelse return true;
                defer _ = c.close(fd);
                if (format == 1) self.loadKeymap(fd, size);
            },
            1 => { // enter(serial, surface, keys)
                var it = wire.ArgIter.init(body, "uoa");
                _ = it.next() catch return self.disarm("bad keyboard event");
                const sid = ((it.next() catch return self.disarm("bad keyboard event")) orelse return true).object;
                self.kbd_focus = sid;
            },
            2 => self.kbd_focus = 0,
            3 => { // key(serial, time, key, state)
                var it = wire.ArgIter.init(body, "uuuu");
                _ = it.next() catch return self.disarm("bad keyboard event");
                _ = it.next() catch return self.disarm("bad keyboard event");
                const code = ((it.next() catch return self.disarm("bad keyboard event")) orelse return true).uint;
                const state = ((it.next() catch return self.disarm("bad keyboard event")) orelse return true).uint;
                const s = self.surfaceByWl(self.kbd_focus) orelse return true;
                const keysym = self.keysymFor(code) orelse return true;
                self.sink.key(self.sink.ctx, s.view, keysym, code + 8, self.mods, state != 0);
            },
            4 => { // modifiers(serial, depressed, latched, locked, group)
                var it = wire.ArgIter.init(body, "uuuuu");
                _ = it.next() catch return self.disarm("bad keyboard event");
                const dep = ((it.next() catch return self.disarm("bad keyboard event")) orelse return true).uint;
                const lat = ((it.next() catch return self.disarm("bad keyboard event")) orelse return true).uint;
                const lock = ((it.next() catch return self.disarm("bad keyboard event")) orelse return true).uint;
                self.mods = modsFromXkb(dep, lat, lock);
                self.altgr = (dep | lat | lock) & xkb_mod5 != 0;
            },
            else => {},
        }
        return true;
    }

    /// Read the hub's compiled xkb keymap and invert it into a
    /// keycode -> characters table.
    fn loadKeymap(self: *Presenter, fd: c_int, size: u32) void {
        if (size == 0 or size > (4 << 20)) return;
        const blob = self.gpa.alloc(u8, size) catch return;
        defer self.gpa.free(blob);
        var got: usize = 0;
        while (got < size) {
            const n = c.pread(fd, blob.ptr + got, size - got, @intCast(got));
            if (n <= 0) break;
            got += @intCast(n);
        }
        const text = std.mem.sliceTo(blob[0..got], 0);
        var layout = xkblayout.parse(self.gpa, text) catch return;
        defer layout.deinit(self.gpa);
        self.keys = @splat(.{});
        var it = layout.map.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            if (e.code >= KEY_TABLE) continue;
            const slot = &self.keys[e.code];
            if (e.shift and e.altgr) {
                slot.shift_altgr = kv.key_ptr.*;
            } else if (e.shift) {
                slot.shift = kv.key_ptr.*;
            } else if (e.altgr) {
                slot.altgr = kv.key_ptr.*;
            } else {
                slot.plain = kv.key_ptr.*;
            }
        }
        self.have_keymap = true;
    }

    /// The keysym a key produces under the current modifiers.
    pub fn keysymFor(self: *const Presenter, code: u32) ?u32 {
        if (specialKeysym(code)) |sym| return sym;
        if (code >= KEY_TABLE) return null;
        const k = self.keys[code];
        const shift = self.mods & mod_shift != 0;
        const altgr = self.altgr;
        var cp: u21 = if (shift and altgr) k.shift_altgr else if (altgr) k.altgr else if (shift) k.shift else k.plain;
        if (cp == 0) cp = k.plain;
        if (cp == 0) return null;
        if (self.mods & mod_capslock != 0 and cp < 0x80 and std.ascii.isAlphabetic(@intCast(cp))) {
            cp = if (shift) std.ascii.toLower(@intCast(cp)) else std.ascii.toUpper(@intCast(cp));
        }
        return keysymFromCodepoint(cp);
    }

    // -- surfaces ---------------------------------------------------------

    fn surfaceByWl(self: *Presenter, wl_surface: u32) ?*Surface {
        if (wl_surface == 0) return null;
        for (self.surfaces.items) |*s| {
            if (s.wl_surface == wl_surface) return s;
        }
        return null;
    }

    fn surfaceByXdg(self: *Presenter, xdg: u32) ?*Surface {
        for (self.surfaces.items) |*s| {
            if (s.xdg_surface == xdg) return s;
        }
        return null;
    }

    fn surfaceByView(self: *Presenter, view: u32) ?*Surface {
        for (self.surfaces.items) |*s| {
            if (s.view == view) return s;
        }
        return null;
    }

    /// New pixels for `view`. `src` is the helper's frame buffer (BGRA,
    /// stride pw*4) and stays valid until the next paint, resize or
    /// drop; `rects` is anything with x/y/w/h fields.
    pub fn paint(self: *Presenter, view: u32, pw: u16, ph: u16, scale_x1000: u16, src: []const u8, rects: anytype) void {
        if (!self.active or pw == 0 or ph == 0) return;
        if (src.len < @as(usize, pw) * ph * 4) return;
        const s = self.surfaceByView(view) orelse self.createSurface(view, pw, ph, scale_x1000) orelse return;
        if (s.pw != pw or s.ph != ph) {
            self.releasePool(s);
            s.pw = pw;
            s.ph = ph;
            s.gate.dirty = null;
            self.sendSizeHints(s);
            s.gate.dirty = .{ .x = 0, .y = 0, .w = pw, .h = ph };
        }
        s.scale_x1000 = scale_x1000;
        s.src = src;
        for (rects) |r| {
            s.gate.dirty = unionRect(s.gate.dirty, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
        }
        _ = self.flushSurface(s);
        _ = self.flushOut();
    }

    /// The page title, shown as the toplevel's; remembered for a view
    /// whose toplevel does not exist yet.
    pub fn setTitle(self: *Presenter, view: u32, title: []const u8) void {
        if (!self.active) return;
        const owned = self.gpa.dupe(u8, title) catch return;
        if (self.titles.fetchPut(self.gpa, view, owned) catch {
            self.gpa.free(owned);
            return;
        }) |old| self.gpa.free(old.value);
        if (self.surfaceByView(view)) |s| {
            self.sendTitle(s, title);
            _ = self.flushOut();
        }
    }

    /// The view is gone (destroyed or discarded): take its toplevel down.
    pub fn dropView(self: *Presenter, view: u32) void {
        if (self.titles.fetchRemove(view)) |kv| self.gpa.free(kv.value);
        if (!self.active) return;
        for (self.surfaces.items, 0..) |*s, i| {
            if (s.view != view) continue;
            if (self.ptr_focus == s.wl_surface) self.ptr_focus = 0;
            if (self.kbd_focus == s.wl_surface) self.kbd_focus = 0;
            self.releasePool(s);
            var buf: [16]u8 = undefined;
            var b1 = wire.Builder.init(&buf, s.toplevel, 0); // destroy
            self.emit(b1.finish() catch return);
            var b2 = wire.Builder.init(&buf, s.xdg_surface, 0);
            self.emit(b2.finish() catch return);
            var b3 = wire.Builder.init(&buf, s.wl_surface, 0);
            self.emit(b3.finish() catch return);
            _ = self.objects.remove(s.toplevel);
            _ = self.objects.remove(s.xdg_surface);
            _ = self.objects.remove(s.wl_surface);
            _ = self.surfaces.swapRemove(i);
            _ = self.flushOut();
            return;
        }
    }

    pub fn surfaceCount(self: *const Presenter) usize {
        return self.surfaces.items.len;
    }

    fn createSurface(self: *Presenter, view: u32, pw: u16, ph: u16, scale_x1000: u16) ?*Surface {
        var s = Surface{ .view = view, .pw = pw, .ph = ph, .scale_x1000 = scale_x1000 };
        s.wl_surface = self.allocId(.surface);
        s.xdg_surface = self.allocId(.xdg_surface);
        s.toplevel = self.allocId(.toplevel);
        var buf: [32]u8 = undefined;
        {
            var b = wire.Builder.init(&buf, self.compositor, 0); // create_surface
            b.putNewId(s.wl_surface);
            self.emit(b.finish() catch return null);
        }
        {
            var b = wire.Builder.init(&buf, self.wm_base, 2); // get_xdg_surface
            b.putNewId(s.xdg_surface);
            b.putObject(s.wl_surface);
            self.emit(b.finish() catch return null);
        }
        {
            var b = wire.Builder.init(&buf, s.xdg_surface, 1); // get_toplevel
            b.putNewId(s.toplevel);
            self.emit(b.finish() catch return null);
        }
        {
            var abuf: [64]u8 = undefined;
            var b = wire.Builder.init(&abuf, s.toplevel, 3); // set_app_id
            b.putString(APP_ID);
            self.emit(b.finish() catch return null);
        }
        self.surfaces.append(self.gpa, s) catch return null;
        const ptr = &self.surfaces.items[self.surfaces.items.len - 1];
        self.sendTitle(ptr, self.titles.get(view) orelse "");
        self.sendSizeHints(ptr);
        {
            // The first commit carries no buffer: that is what asks the
            // hub for the initial configure.
            var b = wire.Builder.init(&buf, ptr.wl_surface, 6); // commit
            self.emit(b.finish() catch return null);
        }
        ptr.gate.dirty = .{ .x = 0, .y = 0, .w = pw, .h = ph };
        return ptr;
    }

    fn sendTitle(self: *Presenter, s: *Surface, title: []const u8) void {
        var tbuf: [1100]u8 = undefined;
        var b = wire.Builder.init(&tbuf, s.toplevel, 2); // set_title
        b.putString(title[0..@min(title.len, 1024)]);
        self.emit(b.finish() catch return);
    }

    /// The toplevel is exactly the view: min and max size pin it.
    fn sendSizeHints(self: *Presenter, s: *Surface) void {
        var buf: [24]u8 = undefined;
        var b1 = wire.Builder.init(&buf, s.toplevel, 7); // set_max_size
        b1.putInt(s.pw);
        b1.putInt(s.ph);
        self.emit(b1.finish() catch return);
        var b2 = wire.Builder.init(&buf, s.toplevel, 8); // set_min_size
        b2.putInt(s.pw);
        b2.putInt(s.ph);
        self.emit(b2.finish() catch return);
    }

    /// Copy the pending damage into a free buffer and commit it, when
    /// the gate allows.
    fn flushSurface(self: *Presenter, s: *Surface) bool {
        if (!self.active) return false;
        if (s.pool_id == 0 and s.gate.configured and s.gate.dirty != null) {
            if (!self.createPool(s)) return false;
        }
        const slot = s.gate.ready() orelse return true;
        const rect = s.gate.dirty.?;
        if (s.src.len < @as(usize, s.pw) * s.ph * 4) return true;
        const stride: usize = @as(usize, s.pw) * 4;
        const base = slot * stride * s.ph;
        const dst = s.pool_map[base .. base + stride * s.ph];
        var row: usize = rect.y;
        const y_end = @min(@as(usize, rect.y) + rect.h, s.ph);
        const x_end = @min(@as(usize, rect.x) + rect.w, s.pw);
        while (row < y_end) : (row += 1) {
            const off = row * stride + @as(usize, rect.x) * 4;
            const len = (x_end - rect.x) * 4;
            @memcpy(dst[off..][0..len], s.src[off..][0..len]);
        }
        var buf: [32]u8 = undefined;
        {
            var b = wire.Builder.init(&buf, s.wl_surface, 1); // attach
            b.putObject(s.bufs[slot]);
            b.putInt(0);
            b.putInt(0);
            self.emit(b.finish() catch return self.disarm("encode"));
        }
        {
            var b = wire.Builder.init(&buf, s.wl_surface, 2); // damage
            b.putInt(rect.x);
            b.putInt(rect.y);
            b.putInt(@intCast(x_end - rect.x));
            b.putInt(@intCast(y_end - rect.y));
            self.emit(b.finish() catch return self.disarm("encode"));
        }
        const cb = self.allocId(.frame_cb);
        self.frame_cbs.put(self.gpa, cb, s.wl_surface) catch return self.disarm("oom");
        {
            var b = wire.Builder.init(&buf, s.wl_surface, 3); // frame
            b.putNewId(cb);
            self.emit(b.finish() catch return self.disarm("encode"));
        }
        {
            var b = wire.Builder.init(&buf, s.wl_surface, 6); // commit
            self.emit(b.finish() catch return self.disarm("encode"));
        }
        s.gate.busy[slot] = true;
        s.gate.frame_pending = true;
        s.gate.dirty = null;
        return true;
    }

    /// One pool holding both buffers, sized for the surface.
    fn createPool(self: *Presenter, s: *Surface) bool {
        const stride: usize = @as(usize, s.pw) * 4;
        const size = stride * s.ph * 2;
        // The one anonymous-file home (memfd on Linux); sized here, so
        // the mapping below covers both buffers.
        const fd = platform.anonFileFd(size);
        if (fd < 0) return self.disarm("could not create the pool's anonymous file");
        const p = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0) orelse {
            _ = c.close(fd);
            return self.disarm("mmap failed");
        };
        if (@intFromPtr(p) == std.math.maxInt(usize)) {
            _ = c.close(fd);
            return self.disarm("mmap failed");
        }
        s.pool_map = @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(p)))[0..size];
        @memset(s.pool_map, 0);
        s.pool_fd = fd;
        s.pool_id = self.allocId(.pool);
        var buf: [40]u8 = undefined;
        {
            var b = wire.Builder.init(&buf, self.shm, 0); // create_pool(id, fd, size)
            b.putNewId(s.pool_id);
            b.putInt(@intCast(size));
            const msg = b.finish() catch return self.disarm("encode");
            if (!self.emitWithFd(msg, fd)) return false;
        }
        for (&s.bufs, 0..) |*id, i| {
            id.* = self.allocId(.buffer);
            self.buffer_owner.put(self.gpa, id.*, s.wl_surface) catch return self.disarm("oom");
            var b = wire.Builder.init(&buf, s.pool_id, 0); // create_buffer
            b.putNewId(id.*);
            b.putInt(@intCast(i * stride * s.ph));
            b.putInt(s.pw);
            b.putInt(s.ph);
            b.putInt(@intCast(stride));
            b.putUint(1); // WL_SHM_FORMAT_XRGB8888: the page is opaque
            self.emit(b.finish() catch return self.disarm("encode"));
        }
        s.gate.busy = .{ false, false };
        return true;
    }

    fn releasePool(self: *Presenter, s: *Surface) void {
        var buf: [16]u8 = undefined;
        for (&s.bufs) |*id| {
            if (id.* == 0) continue;
            if (self.active) {
                var b = wire.Builder.init(&buf, id.*, 0); // wl_buffer.destroy
                self.emit(b.finish() catch return);
            }
            _ = self.buffer_owner.remove(id.*);
            _ = self.objects.remove(id.*);
            id.* = 0;
        }
        if (s.pool_id != 0) {
            if (self.active) {
                var b = wire.Builder.init(&buf, s.pool_id, 1); // wl_shm_pool.destroy
                self.emit(b.finish() catch return);
            }
            _ = self.objects.remove(s.pool_id);
            s.pool_id = 0;
        }
        if (s.pool_map.len != 0) {
            _ = c.munmap(s.pool_map.ptr, s.pool_map.len);
            s.pool_map = &.{};
        }
        if (s.pool_fd >= 0) {
            _ = c.close(s.pool_fd);
            s.pool_fd = -1;
        }
        s.gate.busy = .{ false, false };
        s.gate.frame_pending = false;
    }
};

// --- tests ------------------------------------------------------

const t = std.testing;

fn noPointer(_: ?*anyopaque, _: u32, _: PointerKind, _: i32, _: i32, _: u8, _: u8, _: u32) void {}
fn noScroll(_: ?*anyopaque, _: u32, _: i32, _: i32, _: i32, _: i32, _: u32) void {}
fn noKey(_: ?*anyopaque, _: u32, _: u32, _: u32, _: u32, _: bool) void {}

const silent_sink = Sink{ .ctx = null, .pointer = noPointer, .scroll = noScroll, .key = noKey };

test "the frame gate admits a paint only when configured, unpaced, free and dirty" {
    var g = FrameGate{};
    try t.expectEqual(@as(?usize, null), g.ready());
    g.dirty = .{ .x = 0, .y = 0, .w = 4, .h = 4 };
    try t.expectEqual(@as(?usize, null), g.ready()); // not configured
    g.configured = true;
    try t.expectEqual(@as(?usize, 0), g.ready());
    g.frame_pending = true;
    try t.expectEqual(@as(?usize, null), g.ready()); // callback outstanding
    g.frame_pending = false;
    g.busy[0] = true;
    try t.expectEqual(@as(?usize, 1), g.ready()); // the other buffer
    g.busy[1] = true;
    try t.expectEqual(@as(?usize, null), g.ready()); // nothing free
    g.busy = .{ false, false };
    g.dirty = null;
    try t.expectEqual(@as(?usize, null), g.ready()); // nothing to show
}

test "damage rects union into one bounding box" {
    const a = unionRect(null, .{ .x = 10, .y = 10, .w = 5, .h = 5 });
    try t.expectEqual(Rect{ .x = 10, .y = 10, .w = 5, .h = 5 }, a);
    const b = unionRect(a, .{ .x = 2, .y = 20, .w = 3, .h = 3 });
    try t.expectEqual(Rect{ .x = 2, .y = 10, .w = 13, .h = 13 }, b);
    const inner = unionRect(b, .{ .x = 4, .y = 12, .w = 1, .h = 1 });
    try t.expectEqual(b, inner);
}

test "seat modifiers and buttons translate to the protocol vocabulary" {
    try t.expectEqual(mod_shift | mod_ctrl, modsFromXkb(xkb_shift | xkb_control, 0, 0));
    try t.expectEqual(mod_alt | mod_super, modsFromXkb(0, xkb_mod1, xkb_mod4) & (mod_alt | mod_super));
    try t.expectEqual(mod_capslock, modsFromXkb(0, 0, xkb_lock));
    try t.expectEqual(mod_numlock, modsFromXkb(0, 0, xkb_mod2));
    try t.expectEqual(@as(?u8, 0), protoButton(0x110));
    try t.expectEqual(@as(?u8, 1), protoButton(0x112));
    try t.expectEqual(@as(?u8, 2), protoButton(0x111));
    try t.expectEqual(@as(?u8, null), protoButton(0x113));
    try t.expectEqual(@as(i32, 100), logical(150.0, 1500));
    try t.expectEqual(@as(i32, 7), logical(7.4, 0));
}

test "keysyms: specials by keycode, characters by keymap level, caps lock flips letters" {
    try t.expectEqual(@as(?u32, 0xff0d), specialKeysym(28));
    try t.expectEqual(@as(?u32, 0xffc9), specialKeysym(88));
    try t.expectEqual(@as(?u32, 0xffbe + 4), specialKeysym(63));
    try t.expectEqual(@as(?u32, null), specialKeysym(30));
    try t.expectEqual(@as(u32, 'a'), keysymFromCodepoint('a'));
    try t.expectEqual(@as(u32, 0x01000000 | 0x20ac), keysymFromCodepoint(0x20ac));

    var p = Presenter{ .gpa = t.allocator, .sink = silent_sink };
    defer {
        p.objects.deinit(t.allocator);
        p.out.deinit(t.allocator);
    }
    p.keys[30] = .{ .plain = 'a', .shift = 'A', .altgr = 0xe6 };
    try t.expectEqual(@as(?u32, 'a'), p.keysymFor(30));
    p.mods = mod_shift;
    try t.expectEqual(@as(?u32, 'A'), p.keysymFor(30));
    p.mods = 0;
    p.altgr = true;
    try t.expectEqual(@as(?u32, 0xe6), p.keysymFor(30));
    p.altgr = false;
    p.mods = mod_capslock;
    try t.expectEqual(@as(?u32, 'A'), p.keysymFor(30));
    p.mods = mod_capslock | mod_shift;
    try t.expectEqual(@as(?u32, 'a'), p.keysymFor(30));
    p.mods = 0;
    try t.expectEqual(@as(?u32, null), p.keysymFor(31));
}

test "a registry bind marshals as name, interface, version, new id" {
    var p = Presenter{ .gpa = t.allocator, .sink = silent_sink };
    defer {
        p.objects.deinit(t.allocator);
        p.out.deinit(t.allocator);
    }
    const id = p.bind(2, .{ .name = 7, .version = 9 }, "wl_seat", 5, .seat).?;
    try t.expectEqual(@as(u32, 2), id);
    const hdr = (try wire.parseHeader(p.out.items)).?;
    try t.expectEqual(@as(u32, 2), hdr.object);
    try t.expectEqual(@as(u16, 0), hdr.opcode);
    var it = wire.ArgIter.init(p.out.items[wire.header_size..hdr.size], "usun");
    try t.expectEqual(@as(u32, 7), (try it.next()).?.uint);
    try t.expectEqualStrings("wl_seat", (try it.next()).?.string.?);
    // The bound version never exceeds what the registry advertised OR
    // what this client implements.
    try t.expectEqual(@as(u32, 5), (try it.next()).?.uint);
    try t.expectEqual(@as(u32, 2), (try it.next()).?.new_id);
    try t.expectEqual(ObjKind.seat, p.objects.get(2).?);
}

test "a new view's toplevel is created, identified and committed without a buffer" {
    var p = Presenter{ .gpa = t.allocator, .sink = silent_sink, .active = true, .compositor = 3, .wm_base = 6 };
    defer {
        p.objects.deinit(t.allocator);
        p.out.deinit(t.allocator);
        p.surfaces.deinit(t.allocator);
        p.titles.deinit(t.allocator);
    }
    p.next_id = 10;
    const s = p.createSurface(41, 300, 200, 1000).?;
    try t.expectEqual(@as(u32, 10), s.wl_surface);
    try t.expectEqual(@as(u32, 11), s.xdg_surface);
    try t.expectEqual(@as(u32, 12), s.toplevel);
    // Walk the request stream: create_surface, get_xdg_surface,
    // get_toplevel, set_app_id, set_title, set_max_size, set_min_size,
    // commit -- and the commit carries no attach before it.
    var pos: usize = 0;
    var seen: [8]struct { object: u32, opcode: u16 } = undefined;
    var n: usize = 0;
    while ((try wire.parseHeader(p.out.items[pos..]))) |h| {
        seen[n] = .{ .object = h.object, .opcode = h.opcode };
        n += 1;
        pos += h.size;
    }
    try t.expectEqual(@as(usize, 8), n);
    try t.expectEqual(@as(u32, 3), seen[0].object); // wl_compositor.create_surface
    try t.expectEqual(@as(u16, 0), seen[0].opcode);
    try t.expectEqual(@as(u32, 6), seen[1].object); // xdg_wm_base.get_xdg_surface
    try t.expectEqual(@as(u16, 2), seen[1].opcode);
    try t.expectEqual(@as(u32, 11), seen[2].object); // xdg_surface.get_toplevel
    try t.expectEqual(@as(u32, 12), seen[3].object); // set_app_id
    try t.expectEqual(@as(u16, 3), seen[3].opcode);
    try t.expectEqual(@as(u16, 2), seen[4].opcode); // set_title
    try t.expectEqual(@as(u16, 7), seen[5].opcode); // set_max_size
    try t.expectEqual(@as(u16, 8), seen[6].opcode); // set_min_size
    try t.expectEqual(@as(u32, 10), seen[7].object); // wl_surface.commit
    try t.expectEqual(@as(u16, 6), seen[7].opcode);
    // Not configured yet: a paint only widens the damage.
    try t.expect(!s.gate.configured);
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 300, .h = 200 }, s.gate.dirty.?);
}

test "a paint before the initial configure is held, never attached" {
    var p = Presenter{ .gpa = t.allocator, .sink = silent_sink, .active = true, .compositor = 3, .wm_base = 6 };
    defer {
        p.objects.deinit(t.allocator);
        p.out.deinit(t.allocator);
        p.surfaces.deinit(t.allocator);
        p.titles.deinit(t.allocator);
    }
    p.fd = -1;
    const px = try t.allocator.alloc(u8, 4 * 4 * 4);
    defer t.allocator.free(px);
    @memset(px, 0x7f);
    p.paint(5, 4, 4, 1000, px, &[_]Rect{.{ .x = 1, .y = 1, .w = 2, .h = 2 }});
    const s = p.surfaceByView(5).?;
    try t.expectEqual(@as(u32, 0), s.pool_id);
    try t.expect(!s.gate.busy[0] and !s.gate.busy[1]);
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 4, .h = 4 }, s.gate.dirty.?);
    // A title set for an existing surface goes straight out.
    const before = p.out.items.len;
    p.setTitle(5, "Hello");
    try t.expect(p.out.items.len > before);
    try t.expectEqualStrings("Hello", p.titles.get(5).?);
    p.dropView(5);
    try t.expectEqual(@as(usize, 0), p.surfaces.items.len);
    try t.expect(p.titles.get(5) == null);
}
