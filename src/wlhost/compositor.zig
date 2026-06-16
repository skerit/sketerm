//! The compositor brain of the sketerm-native app pipe: the server
//! side of the Wayland protocol, as a pure state machine (no
//! sockets, no GTK, no GL — the view layer renders).
//!
//! Input: the daemon's pipe-unit stream (wlhost/pipe.zig) — verbatim
//! client requests plus shm-pool side-band keeping local mirrors in
//! sync (pool bytes arrive BEFORE the commit that references them).
//! Output: pipe units of compositor→client events, drained by the
//! caller toward the daemon. The View callbacks surface toplevel
//! lifecycle + committed pixels to whatever renders windows.
//!
//! v1 scope (docs/proposal-macos-remote-apps.md): shm only,
//! toplevels only (popups refused), single output, integer scale 1.
//! Frame callbacks fire at commit time.
//!
//! Input: wl_seat v1 with pointer+keyboard. The view injects via
//! pointer*/keyboard* methods; key codes are evdev (GTK hardware
//! keycode - 8). The keymap is a fixed pc105/us blob shipped as a
//! pipe `keymap` unit — the DAEMON materializes the fd and emits
//! the wl_keyboard.keymap event (we can't carry fds).

const std = @import("std");
const wire = @import("wire.zig");
const protocol = @import("protocol.zig");
const pipe = @import("pipe.zig");
const pixcodec = @import("pixcodec.zig");
const vcodec = @import("vcodec.zig");
const build_options = @import("build_options");

/// Fixed pc105/us xkb keymap (scope pin: layouts come later).
/// Generated: `xkbcli compile-keymap --layout us --model pc105`.
pub const us_keymap = @embedFile("us_keymap.txt");

fn removeId(list: *std.ArrayList(u32), id: u32) void {
    for (list.items, 0..) |v, i| {
        if (v == id) {
            _ = list.swapRemove(i);
            return;
        }
    }
}

pub const Error = error{
    Protocol,
    OutOfMemory,
} || wire.Error;

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Renderer-facing callbacks. Slices are valid only for the call.
pub const View = struct {
    ctx: ?*anyopaque = null,
    /// A surface gained the toplevel role.
    toplevel_new: ?*const fn (ctx: ?*anyopaque, surface: u32) void = null,
    /// New committed content for a MAPPED surface (toplevel or
    /// popup). `pixels` is tightly packed w*4 rows (stride already
    /// applied), wl_shm format (0 argb, 1 xrgb).
    toplevel_frame: ?*const fn (ctx: ?*anyopaque, surface: u32, w: i32, h: i32, scale: i32, format: u32, pixels: []const u8) void = null,
    toplevel_title: ?*const fn (ctx: ?*anyopaque, surface: u32, title: []const u8) void = null,
    /// xdg_toplevel.set_app_id — desktop identity (icon, grouping).
    toplevel_app_id: ?*const fn (ctx: ?*anyopaque, surface: u32, app_id: []const u8) void = null,
    /// Toplevel destroyed (or its surface) — drop the window.
    toplevel_gone: ?*const fn (ctx: ?*anyopaque, surface: u32) void = null,
    /// A surface gained the popup role: render it at (x, y) in the
    /// PARENT surface's coordinate space.
    popup_new: ?*const fn (ctx: ?*anyopaque, surface: u32, parent: u32, x: i32, y: i32) void = null,
    popup_gone: ?*const fn (ctx: ?*anyopaque, surface: u32) void = null,
    /// A surface gained the subsurface role: render it as a child of
    /// `parent` at (x, y) in the parent's coordinate space (GTK3
    /// tooltips / tree-view type-ahead). `subsurface_pos` updates the
    /// offset; frames arrive via toplevel_frame like any surface.
    subsurface_new: ?*const fn (ctx: ?*anyopaque, surface: u32, parent: u32, x: i32, y: i32) void = null,
    subsurface_pos: ?*const fn (ctx: ?*anyopaque, surface: u32, x: i32, y: i32) void = null,
    subsurface_gone: ?*const fn (ctx: ?*anyopaque, surface: u32) void = null,
    /// The app announced a clipboard selection with a usable text
    /// mime. Call fetchClipboard to pull the content.
    clipboard_offer: ?*const fn (ctx: ?*anyopaque, source: u32, mime: []const u8) void = null,
    /// Content fetched from the app (answer to fetchClipboard) —
    /// hand it to the host clipboard.
    clipboard_data: ?*const fn (ctx: ?*anyopaque, bytes: []const u8) void = null,
    /// The app wants to paste: read the host clipboard and answer
    /// with sendClipData (ALWAYS answer, even empty — the daemon
    /// holds a pipe fd FIFO-paired with the answers).
    clipboard_read: ?*const fn (ctx: ?*anyopaque, mime: []const u8) void = null,
    /// wp_cursor_shape set_shape — apply to the pointer-focused
    /// window (enum per cursor-shape-v1; names match CSS cursors).
    cursor_shape: ?*const fn (ctx: ?*anyopaque, shape: u32) void = null,
    /// xdg-decoration: the app wants server-side (host) decorations
    /// (true) or draws its own (false).
    toplevel_decoration: ?*const fn (ctx: ?*anyopaque, surface: u32, ssd: bool) void = null,
    /// xdg_toplevel.move — the app's own titlebar drag: start an
    /// interactive move of the host window.
    toplevel_move: ?*const fn (ctx: ?*anyopaque, surface: u32) void = null,
    /// xdg_toplevel.resize with wayland edge flags (1 top, 2 bottom,
    /// 4 left, 8 right, combinable).
    toplevel_resize: ?*const fn (ctx: ?*anyopaque, surface: u32, edges: u32) void = null,
    /// xdg_toplevel.set_parent — dialogs become transient for
    /// their parent's host window (0 clears).
    toplevel_parent: ?*const fn (ctx: ?*anyopaque, surface: u32, parent: u32) void = null,
    /// xdg_toplevel.set_min_size (0 = unset).
    toplevel_min_size: ?*const fn (ctx: ?*anyopaque, surface: u32, w: i32, h: i32) void = null,
    /// App-initiated window ops: 1 maximize, 2 unmaximize,
    /// 3 fullscreen, 4 unfullscreen, 5 minimize.
    toplevel_state_request: ?*const fn (ctx: ?*anyopaque, surface: u32, req: u8) void = null,
    /// Committed window geometry: the app's visible rect within
    /// its buffer. Frames are CROPPED to it — the view needs the
    /// offset to translate widget coords back to surface coords.
    toplevel_geometry: ?*const fn (ctx: ?*anyopaque, surface: u32, x: i32, y: i32, w: i32, h: i32) void = null,
    /// Committed input region (surface coords). Null slice = the
    /// whole surface accepts input (the default); empty/partial =
    /// only those rects do — CSD shadows become click-through.
    input_region: ?*const fn (ctx: ?*anyopaque, surface: u32, rects: ?[]const Rect) void = null,
};

const Global = struct {
    name: u32,
    iface: *const protocol.Interface,
    version: u32,
};

/// What we advertise — deliberately low versions: nothing here
/// obliges events we don't implement.
const globals = [_]Global{
    .{ .name = 1, .iface = &protocol.wl_compositor, .version = 4 },
    // GTK3 maps tooltips / tree-view type-ahead popups as subsurfaces;
    // without this its GdkDisplay->subcompositor is NULL and it crashes
    // (wl_proxy_get_version(NULL)) the first time it shows one.
    .{ .name = 11, .iface = &protocol.wl_subcompositor, .version = 1 },
    .{ .name = 2, .iface = &protocol.wl_shm, .version = 1 },
    // v4: keyboards get repeat_info — held keys repeat client-side.
    .{ .name = 3, .iface = &protocol.wl_seat, .version = 4 },
    .{ .name = 4, .iface = &protocol.wl_output, .version = 2 },
    .{ .name = 5, .iface = &protocol.xdg_wm_base, .version = 2 },
    // v1 = selection only, no dnd action machinery.
    .{ .name = 6, .iface = &protocol.wl_data_device_manager, .version = 1 },
    // Modern niceties many clients probe for. Viewporter is
    // accept-and-ignore at scale 1; cursor shapes reach the view.
    // No fractional-scale: clients use the integer wl_output.scale +
    // set_buffer_scale path; the host renders the HiDPI buffer crisply
    // and the local compositor does any final fractional downscale.
    .{ .name = 7, .iface = &protocol.wp_cursor_shape_manager_v1, .version = 1 },
    .{ .name = 8, .iface = &protocol.wp_viewporter, .version = 1 },
    // Decoration negotiation: SSD-wanting apps (Qt, traditional
    // GTK) get the host window's decorations; CSD apps draw their
    // own into an undecorated host window.
    .{ .name = 10, .iface = &protocol.zxdg_decoration_manager_v1, .version = 1 },
};

const Pool = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// Lazily-created H.264 decoder for pool_vtile updates to this pool,
    /// recreated when the tile dimensions change (build_options.video).
    vdec: ?vcodec.Decoder = null,
    vdec_w: i32 = 0,
    vdec_h: i32 = 0,

    fn deinit(self: *Pool, a: std.mem.Allocator) void {
        self.bytes.deinit(a);
        if (self.vdec) |*d| d.deinit();
    }
};

const Buffer = struct {
    pool: u32,
    offset: i32,
    width: i32,
    height: i32,
    stride: i32,
    format: u32,
};

const Surface = struct {
    /// Pending (attach happened since last commit). 0 with
    /// has_pending = attach(null) → unmap.
    pending_buffer: u32 = 0,
    has_pending: bool = false,
    /// set_buffer_scale: physical pixels per surface-local (logical)
    /// unit in the committed buffer. 1 unless HiDPI.
    buffer_scale: i32 = 1,
    /// Latched buffer id (content source after commit).
    committed_buffer: u32 = 0,
    xdg_surface: u32 = 0,
    toplevel: u32 = 0,
    /// xdg_popup id when this surface is a popup.
    popup: u32 = 0,
    /// Parent surface id when this surface is a subsurface (0 = not).
    /// Position is in the parent's coordinate space.
    subparent: u32 = 0,
    sub_x: i32 = 0,
    sub_y: i32 = 0,
    /// Popup placement (parent surface coords) from the positioner.
    parent: u32 = 0,
    px: i32 = 0,
    py: i32 = 0,
    pw: i32 = 0,
    ph: i32 = 0,
    /// wl_callback ids awaiting frame done.
    frame_cbs: std.ArrayList(u32) = .empty,
    /// Initial configure sent (xdg dance).
    configured: bool = false,
    /// Double-buffered input region: set_input_region stages, the
    /// next commit applies. whole = null region (everything).
    input_pending: bool = false,
    input_whole: bool = true,
    input_rects: std.ArrayList(Rect) = .empty,
    /// xdg_surface.set_window_geometry: the visible window rect
    /// inside the buffer (everything else is CSD shadow). w=0 →
    /// never set → the full buffer is the window.
    geo_pending: bool = false,
    geo_next: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    geo: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

/// xdg_positioner state — just enough geometry to place menus.
const Positioner = struct {
    w: i32 = 0,
    h: i32 = 0,
    ax: i32 = 0,
    ay: i32 = 0,
    aw: i32 = 0,
    ah: i32 = 0,
    anchor: u32 = 0,
    gravity: u32 = 0,
    ox: i32 = 0,
    oy: i32 = 0,

    /// Popup top-left in parent coords: anchor point on the anchor
    /// rect, extended along the gravity. Constraint adjustment is
    /// ignored in v1 (popups clip at the host window edge anyway).
    fn place(p: *const Positioner) [2]i32 {
        // anchor enum: 1 top, 2 bottom, 3 left, 4 right, 5 tl,
        // 6 bl, 7 tr, 8 br (0 = center)
        var x: i32 = p.ax + @divTrunc(p.aw, 2);
        var y: i32 = p.ay + @divTrunc(p.ah, 2);
        switch (p.anchor) {
            3, 5, 6 => x = p.ax,
            4, 7, 8 => x = p.ax + p.aw,
            else => {},
        }
        switch (p.anchor) {
            1, 5, 7 => y = p.ay,
            2, 6, 8 => y = p.ay + p.ah,
            else => {},
        }
        switch (p.gravity) {
            3, 5, 6 => x -= p.w, // gravity left: extends leftwards
            4, 7, 8 => {},
            else => x -= @divTrunc(p.w, 2),
        }
        switch (p.gravity) {
            1, 5, 7 => y -= p.h,
            2, 6, 8 => {},
            else => y -= @divTrunc(p.h, 2),
        }
        return .{ x + p.ox, y + p.oy };
    }
};

pub const Compositor = struct {
    allocator: std.mem.Allocator,
    view: View,
    /// Integer output scale advertised to clients (HiDPI). The view
    /// sets this from the local display before the first feed; apps
    /// render buffers at this scale and tag them with set_buffer_scale.
    output_scale: i32 = 1,
    /// wl_output object id the client bound (0 = not yet). Surfaces are
    /// told they entered this output (wl_surface.enter) so GTK3 picks up
    /// the output scale — without it GTK3 mis-scales (half-height).
    output_id: u32 = 0,
    /// Outgoing pipe units (events). Caller drains via takeOut.
    out: std.ArrayList(u8) = .empty,
    /// Incoming unit reassembly (chan_data may split units).
    inbuf: std.ArrayList(u8) = .empty,
    objects: std.AutoHashMapUnmanaged(u32, *const protocol.Interface) = .empty,
    pools: std.AutoHashMapUnmanaged(u32, Pool) = .empty,
    /// Scratch for a decoded video tile's BGRA before it's blitted into
    /// the pool mirror (build_options.video).
    vscratch: std.ArrayList(u8) = .empty,
    buffers: std.AutoHashMapUnmanaged(u32, Buffer) = .empty,
    surfaces: std.AutoHashMapUnmanaged(u32, Surface) = .empty,
    /// xdg_surface id → wl_surface id; xdg_toplevel id → wl_surface id.
    xdg_map: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// wl_subsurface id → wl_surface id (the surface it gave the role to).
    sub_map: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    positioners: std.AutoHashMapUnmanaged(u32, Positioner) = .empty,
    /// Surface id of the popup holding an explicit grab (0 = none).
    grabbed_popup: u32 = 0,
    /// wl_region contents (add rects only; subtract is rare and
    /// ignored in v1 — the union over-approximates input areas,
    /// which fails safe).
    regions: std.AutoHashMapUnmanaged(u32, std.ArrayList(Rect)) = .empty,
    /// Clipboard: app-side data sources and their offered mimes
    /// (owned strings), bound data devices, server-created offers.
    data_sources: std.AutoHashMapUnmanaged(u32, std.ArrayList([]u8)) = .empty,
    data_devices: std.ArrayList(u32) = .empty,
    /// Next server-allocated object id (data offers).
    next_server_id: u32 = 0xff000000,
    /// Bound input devices (a client may bind several of each).
    pointers: std.ArrayList(u32) = .empty,
    keyboards: std.ArrayList(u32) = .empty,
    /// Surface currently holding pointer / keyboard focus (0 = none).
    pointer_focus: u32 = 0,
    keyboard_focus: u32 = 0,
    /// Version the client bound wl_seat at (gates repeat_info).
    seat_version: u32 = 1,
    /// Tight-packed copy handed to toplevel_frame.
    frame_scratch: std.ArrayList(u8) = .empty,
    serial: u32 = 1,
    /// Caller-provided clock for frame-callback timestamps (ms).
    now_ms: u32 = 0,
    /// Set on fatal protocol error after wl_display.error went out;
    /// the caller should close the channel once out is drained.
    dead: bool = false,

    pub fn init(allocator: std.mem.Allocator, view: View) Error!Compositor {
        var self = Compositor{ .allocator = allocator, .view = view };
        try self.objects.put(allocator, 1, &protocol.wl_display);
        return self;
    }

    pub fn deinit(self: *Compositor) void {
        const a = self.allocator;
        self.out.deinit(a);
        self.inbuf.deinit(a);
        self.objects.deinit(a);
        var pit = self.pools.valueIterator();
        while (pit.next()) |p| p.deinit(a);
        self.pools.deinit(a);
        self.vscratch.deinit(a);
        self.buffers.deinit(a);
        var sit = self.surfaces.valueIterator();
        while (sit.next()) |s| {
            s.frame_cbs.deinit(a);
            s.input_rects.deinit(a);
        }
        self.surfaces.deinit(a);
        self.xdg_map.deinit(a);
        self.sub_map.deinit(a);
        self.positioners.deinit(a);
        var rit = self.regions.valueIterator();
        while (rit.next()) |r| r.deinit(a);
        self.regions.deinit(a);
        var dit = self.data_sources.valueIterator();
        while (dit.next()) |mimes| {
            for (mimes.items) |m| a.free(m);
            mimes.deinit(a);
        }
        self.data_sources.deinit(a);
        self.data_devices.deinit(a);
        self.pointers.deinit(a);
        self.keyboards.deinit(a);
        self.frame_scratch.deinit(a);
    }

    /// Feed raw bytes of the pipe-unit stream (e.g. one chan_data
    /// payload). Processes every complete unit; buffers the tail.
    pub fn feed(self: *Compositor, bytes: []const u8) Error!void {
        try self.inbuf.appendSlice(self.allocator, bytes);
        var pos: usize = 0;
        while (!self.dead) {
            const peeled = pipe.peelUnit(self.inbuf.items[pos..]) catch return Error.Protocol;
            const p = peeled orelse break;
            try self.feedUnit(p.unit.tag, p.unit.payload);
            pos += p.consumed;
        }
        if (pos > 0) {
            const rem = self.inbuf.items.len - pos;
            std.mem.copyForwards(u8, self.inbuf.items[0..rem], self.inbuf.items[pos..]);
            self.inbuf.shrinkRetainingCapacity(rem);
        }
    }

    // ── input injection (view → client) ─────────────────────────
    // Coordinates are surface-local pixels; key codes are evdev.
    // All no-ops until the client binds the device.

    pub fn pointerEnter(self: *Compositor, sid: u32, x: f64, y: f64) Error!void {
        if (!self.surfaces.contains(sid)) return;
        if (self.pointer_focus == sid) return;
        try self.pointerLeave();
        self.pointer_focus = sid;
        const serial = self.nextSerial();
        for (self.pointers.items) |p| {
            var buf: [32]u8 = undefined;
            var b = wire.Builder.init(&buf, p, 0); // enter
            b.putUint(serial);
            b.putObject(sid);
            b.putFixed(wire.fixedFromF64(x));
            b.putFixed(wire.fixedFromF64(y));
            try self.send(try b.finish());
        }
    }

    pub fn pointerLeave(self: *Compositor) Error!void {
        if (self.pointer_focus == 0) return;
        const serial = self.nextSerial();
        for (self.pointers.items) |p| {
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, p, 1); // leave
            b.putUint(serial);
            b.putObject(self.pointer_focus);
            try self.send(try b.finish());
        }
        self.pointer_focus = 0;
    }

    pub fn pointerMotion(self: *Compositor, x: f64, y: f64) Error!void {
        if (self.pointer_focus == 0) return;
        for (self.pointers.items) |p| {
            var buf: [24]u8 = undefined;
            var b = wire.Builder.init(&buf, p, 2); // motion
            b.putUint(self.now_ms);
            b.putFixed(wire.fixedFromF64(x));
            b.putFixed(wire.fixedFromF64(y));
            try self.send(try b.finish());
        }
    }

    /// `button` is an evdev code (BTN_LEFT 0x110 …).
    pub fn pointerButton(self: *Compositor, button: u32, pressed: bool) Error!void {
        if (self.pointer_focus == 0) return;
        const serial = self.nextSerial();
        for (self.pointers.items) |p| {
            var buf: [32]u8 = undefined;
            var b = wire.Builder.init(&buf, p, 3); // button
            b.putUint(serial);
            b.putUint(self.now_ms);
            b.putUint(button);
            b.putUint(if (pressed) 1 else 0);
            try self.send(try b.finish());
        }
    }

    /// `axis`: 0 vertical, 1 horizontal. `value` in surface px.
    pub fn pointerAxis(self: *Compositor, axis: u32, value: f64) Error!void {
        if (self.pointer_focus == 0) return;
        for (self.pointers.items) |p| {
            var buf: [24]u8 = undefined;
            var b = wire.Builder.init(&buf, p, 4); // axis
            b.putUint(self.now_ms);
            b.putUint(axis);
            b.putFixed(wire.fixedFromF64(value));
            try self.send(try b.finish());
        }
    }

    pub fn keyboardEnter(self: *Compositor, sid: u32) Error!void {
        if (!self.surfaces.contains(sid)) return;
        if (self.keyboard_focus == sid) return;
        try self.keyboardLeave();
        self.keyboard_focus = sid;
        const serial = self.nextSerial();
        for (self.keyboards.items) |k| {
            var buf: [24]u8 = undefined;
            var b = wire.Builder.init(&buf, k, 1); // enter
            b.putUint(serial);
            b.putObject(sid);
            b.putArray(&.{}); // no keys held
            try self.send(try b.finish());
        }
    }

    pub fn keyboardLeave(self: *Compositor) Error!void {
        if (self.keyboard_focus == 0) return;
        const serial = self.nextSerial();
        for (self.keyboards.items) |k| {
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, k, 2); // leave
            b.putUint(serial);
            b.putObject(self.keyboard_focus);
            try self.send(try b.finish());
        }
        self.keyboard_focus = 0;
    }

    /// `key` is an evdev code (GTK hardware keycode - 8).
    pub fn keyboardKey(self: *Compositor, key: u32, pressed: bool) Error!void {
        if (self.keyboard_focus == 0) return;
        const serial = self.nextSerial();
        for (self.keyboards.items) |k| {
            var buf: [32]u8 = undefined;
            var b = wire.Builder.init(&buf, k, 3); // key
            b.putUint(serial);
            b.putUint(self.now_ms);
            b.putUint(key);
            b.putUint(if (pressed) 1 else 0);
            try self.send(try b.finish());
        }
    }

    /// X11-order modifier masks (shift 1, lock 2, ctrl 4, mod1 8 …)
    /// — GDK's low bits match the pc105/us keymap's mod order.
    pub fn keyboardModifiers(self: *Compositor, depressed: u32, latched: u32, locked: u32, group: u32) Error!void {
        const serial = self.nextSerial();
        for (self.keyboards.items) |k| {
            var buf: [32]u8 = undefined;
            var b = wire.Builder.init(&buf, k, 4); // modifiers
            b.putUint(serial);
            b.putUint(depressed);
            b.putUint(latched);
            b.putUint(locked);
            b.putUint(group);
            try self.send(try b.finish());
        }
    }

    /// Best text-ish mime an app-side source offers (preference
    /// order matches what GTK itself advertises).
    fn bestTextMime(self: *Compositor, source: u32) ?[]const u8 {
        const mimes = self.data_sources.get(source) orelse return null;
        for ([_][]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain" }) |want| {
            for (mimes.items) |m| {
                if (std.mem.eql(u8, m, want)) return m;
            }
        }
        return null;
    }

    /// View → client: pull the app's announced clipboard content.
    /// The daemon pipes it; the answer arrives as clipboard_data.
    pub fn fetchClipboard(self: *Compositor, source: u32, mime: []const u8) Error!void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, source, .little);
        try payload.appendSlice(self.allocator, &idb);
        try payload.appendSlice(self.allocator, mime);
        try pipe.appendUnit(&self.out, self.allocator, .clip_send, payload.items);
    }

    /// View → client: paste bytes answering the oldest outstanding
    /// clipboard_read (the daemon writes them into the held fd).
    pub fn sendClipData(self: *Compositor, bytes: []const u8) Error!void {
        try pipe.appendUnit(&self.out, self.allocator, .clip_data, bytes);
    }

    /// View → client: announce the HOST clipboard to the app so it
    /// can paste: a fresh server-created data offer per call, sent
    /// to every bound data device.
    pub fn offerSelection(self: *Compositor, mime: []const u8) Error!void {
        for (self.data_devices.items) |dev| {
            const id = self.next_server_id;
            self.next_server_id += 1;
            try self.objects.put(self.allocator, id, &protocol.wl_data_offer);
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, dev, 0); // data_offer(new_id)
            b.putNewId(id);
            try self.send(try b.finish());
            var mbuf: [128]u8 = undefined;
            var bm = wire.Builder.init(&mbuf, id, 0); // offer(mime)
            bm.putString(mime);
            try self.send(try bm.finish());
            var sbuf: [16]u8 = undefined;
            var bs = wire.Builder.init(&sbuf, dev, 5); // selection(offer)
            bs.putObject(id);
            try self.send(try bs.finish());
        }
    }

    /// View → client: a click landed outside a grabbed popup —
    /// tell the app to dismiss it (xdg_popup.popup_done). No-op
    /// when nothing is grabbed.
    pub fn dismissPopups(self: *Compositor) Error!void {
        if (self.grabbed_popup == 0) return;
        const surf = self.surfaces.getPtr(self.grabbed_popup) orelse {
            self.grabbed_popup = 0;
            return;
        };
        if (surf.popup != 0) {
            var buf: [8]u8 = undefined;
            var b = wire.Builder.init(&buf, surf.popup, 1); // popup_done
            try self.send(try b.finish());
        }
        self.grabbed_popup = 0;
    }

    /// View → client: the host window was resized — tell the app to
    /// redraw at the new size (it acks and commits a new buffer).
    pub const ToplevelState = struct {
        activated: bool = true,
        maximized: bool = false,
        fullscreen: bool = false,
        resizing: bool = false,
    };

    pub fn configureToplevel(self: *Compositor, sid: u32, w: i32, h: i32, st: ToplevelState) Error!void {
        const surf = self.surfaces.getPtr(sid) orelse return;
        if (surf.toplevel == 0 or !surf.configured) return;
        if (w <= 0 or h <= 0) return;
        var buf: [80]u8 = undefined;
        var b = wire.Builder.init(&buf, surf.toplevel, 0); // configure
        b.putInt(w);
        b.putInt(h);
        var states: [16]u8 = undefined;
        var n: usize = 0;
        if (st.maximized) {
            std.mem.writeInt(u32, states[n..][0..4], 1, .little);
            n += 4;
        }
        if (st.fullscreen) {
            std.mem.writeInt(u32, states[n..][0..4], 2, .little);
            n += 4;
        }
        if (st.resizing and !st.maximized and !st.fullscreen) {
            std.mem.writeInt(u32, states[n..][0..4], 3, .little);
            n += 4;
        }
        if (st.activated) {
            std.mem.writeInt(u32, states[n..][0..4], 4, .little);
            n += 4;
        }
        b.putArray(states[0..n]);
        try self.send(try b.finish());
        var buf2: [16]u8 = undefined;
        var b2 = wire.Builder.init(&buf2, surf.xdg_surface, 0); // configure
        b2.putUint(self.nextSerial());
        try self.send(try b2.finish());
    }

    /// View → client: ask the app to close this toplevel (window
    /// close button). The app decides; nothing is destroyed here.
    pub fn requestClose(self: *Compositor, sid: u32) Error!void {
        const surf = self.surfaces.getPtr(sid) orelse return;
        if (surf.toplevel == 0) return;
        var buf: [8]u8 = undefined;
        var b = wire.Builder.init(&buf, surf.toplevel, 1); // close
        try self.send(try b.finish());
    }

    /// The accumulated outgoing unit stream; caller ships it (as
    /// chan_data, or decoded onto a test socket) and then clears.
    pub fn takeOut(self: *Compositor) []const u8 {
        return self.out.items;
    }

    pub fn clearOut(self: *Compositor) void {
        self.out.clearRetainingCapacity();
    }

    fn feedUnit(self: *Compositor, tag: pipe.Tag, payload: []const u8) Error!void {
        switch (tag) {
            .wl_msg => {
                const hdr = (wire.parseHeader(payload) catch return Error.Protocol) orelse return Error.Protocol;
                if (payload.len < hdr.size) return Error.Protocol;
                self.request(hdr, payload[wire.header_size..hdr.size]) catch |err| switch (err) {
                    Error.OutOfMemory => return err,
                    else => try self.fatal(hdr.object, "protocol error"),
                };
            },
            .pool_create, .pool_resize => {
                const meta = pipe.decodePoolMeta(payload) orelse return Error.Protocol;
                const slot = try self.pools.getOrPut(self.allocator, meta.pool);
                if (!slot.found_existing) slot.value_ptr.* = .{};
                try slot.value_ptr.bytes.resize(self.allocator, meta.size);
            },
            .pool_update => {
                const upd = pipe.decodePoolUpdate(payload) orelse return Error.Protocol;
                const pool = self.pools.getPtr(upd.pool) orelse return Error.Protocol;
                const end = @as(usize, upd.offset) + upd.bytes.len;
                if (end > pool.bytes.items.len) return Error.Protocol;
                @memcpy(pool.bytes.items[upd.offset..end], upd.bytes);
            },
            .pool_update_z => {
                const upd = pipe.decodePoolUpdateZ(payload) orelse return Error.Protocol;
                const pool = self.pools.getPtr(upd.pool) orelse return Error.Protocol;
                const end = @as(usize, upd.offset) + upd.raw_len;
                if (end > pool.bytes.items.len) return Error.Protocol;
                _ = @import("zpool.zig").decompress(upd.z, pool.bytes.items[upd.offset..end]) catch
                    return Error.Protocol;
            },
            .pool_update_c => {
                const upd = pipe.decodePoolUpdateC(payload) orelse return Error.Protocol;
                const pool = self.pools.getPtr(upd.pool) orelse return Error.Protocol;
                const end = @as(usize, upd.offset) + upd.body.raw_len;
                if (end > pool.bytes.items.len) return Error.Protocol;
                pixcodec.decodeBody(upd.body, pool.bytes.items[upd.offset..end]) catch
                    return Error.Protocol;
            },
            .pool_vtile => if (comptime build_options.video) {
                const vt = pipe.decodePoolVtile(payload) orelse return Error.Protocol;
                const peeled = (vcodec.peelTile(vt.blob) catch return Error.Protocol) orelse return Error.Protocol;
                const tile = peeled.tile;
                if (tile.w <= 0 or tile.h <= 0) return Error.Protocol;
                const pool = self.pools.getPtr(vt.pool) orelse return Error.Protocol;
                const uw: usize = @intCast(tile.w);
                const uh: usize = @intCast(tile.h);
                // Per-pool decoder, recreated on a dimension change.
                if (pool.vdec == null or pool.vdec_w != tile.w or pool.vdec_h != tile.h) {
                    if (pool.vdec) |*d| d.deinit();
                    pool.vdec = vcodec.Decoder.initAvcodec(self.allocator, tile.w, tile.h) catch return Error.Protocol;
                    pool.vdec_w = tile.w;
                    pool.vdec_h = tile.h;
                }
                try self.vscratch.resize(self.allocator, uw * uh * 4);
                pool.vdec.?.decodeTile(tile, self.vscratch.items) catch return Error.Protocol;
                // Blit the decoded BGRA into the pool mirror at offset,
                // uw*4 bytes per row stepping by row_stride.
                const stride: usize = vt.row_stride;
                const base: usize = vt.offset;
                if (stride < uw * 4 or base + (uh - 1) * stride + uw * 4 > pool.bytes.items.len) return Error.Protocol;
                for (0..uh) |r| {
                    @memcpy(pool.bytes.items[base + r * stride ..][0 .. uw * 4], self.vscratch.items[r * uw * 4 ..][0 .. uw * 4]);
                }
            },
            .pool_destroy => {
                if (payload.len >= 4) {
                    const id = std.mem.readInt(u32, payload[0..4], .little);
                    if (self.pools.getPtr(id)) |p| {
                        p.bytes.deinit(self.allocator);
                        _ = self.pools.remove(id);
                    }
                }
            },
            .clip_data => {
                // Fetched app clipboard content (answer to clip_send).
                if (self.view.clipboard_data) |cb| cb(self.view.ctx, payload);
            },
            else => {}, // forward compat
        }
    }

    // ── request dispatch ────────────────────────────────────────

    fn request(self: *Compositor, hdr: wire.Header, body: []const u8) Error!void {
        const iface = self.objects.get(hdr.object) orelse return Error.Protocol;
        if (hdr.opcode >= iface.requests.len) return Error.Protocol;
        const msg = &iface.requests[hdr.opcode];
        var it = wire.ArgIter.init(body, msg.sig);

        if (iface == &protocol.wl_display) switch (hdr.opcode) {
            0 => { // sync(callback)
                const cb = (try it.next()).?.new_id;
                var buf: [32]u8 = undefined;
                var b = wire.Builder.init(&buf, cb, 0); // done
                b.putUint(self.nextSerial());
                try self.send(try b.finish());
                try self.deleteId(cb);
            },
            1 => { // get_registry
                const reg = (try it.next()).?.new_id;
                try self.register(reg, &protocol.wl_registry);
                for (globals) |g| {
                    var buf: [64]u8 = undefined;
                    var b = wire.Builder.init(&buf, reg, 0); // global
                    b.putUint(g.name);
                    b.putString(g.iface.name);
                    b.putUint(g.version);
                    try self.send(try b.finish());
                }
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_registry) {
            // bind(name, iface_str, version, id)
            const name = (try it.next()).?.uint;
            const iname = (try it.next()).?.string orelse return Error.Protocol;
            const ver = (try it.next()).?.uint;
            const id = (try it.next()).?.new_id;
            const g = for (globals) |g| {
                if (g.name == name) break g;
            } else return Error.Protocol;
            if (!std.mem.eql(u8, g.iface.name, iname) or ver == 0 or ver > g.version)
                return Error.Protocol;
            try self.register(id, g.iface);
            if (g.iface == &protocol.wl_seat) self.seat_version = ver;
            if (g.iface == &protocol.wl_output) self.output_id = id;
            try self.boundGlobal(id, g.iface);
        } else if (iface == &protocol.wl_compositor) switch (hdr.opcode) {
            0 => { // create_surface
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.wl_surface);
                try self.surfaces.put(self.allocator, id, .{});
            },
            1 => { // create_region — tracked, contents ignored
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.wl_region);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_subcompositor) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object), // destroy
            1 => { // get_subsurface(id, surface, parent)
                const id = (try it.next()).?.new_id;
                const sid = (try it.next()).?.object;
                const parent = (try it.next()).?.object;
                try self.register(id, &protocol.wl_subsurface);
                try self.sub_map.put(self.allocator, id, sid);
                if (self.surfaces.getPtr(sid)) |surf| {
                    surf.subparent = parent;
                    if (self.view.subsurface_new) |cb| cb(self.view.ctx, sid, parent, 0, 0);
                }
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_subsurface) switch (hdr.opcode) {
            0 => { // destroy
                if (self.sub_map.fetchRemove(hdr.object)) |kv| {
                    if (self.surfaces.getPtr(kv.value)) |surf| surf.subparent = 0;
                    if (self.view.subsurface_gone) |cb| cb(self.view.ctx, kv.value);
                }
                try self.destroyObject(hdr.object);
            },
            1 => { // set_position(x, y) — parent-relative, applied live
                const x = (try it.next()).?.int;
                const y = (try it.next()).?.int;
                const sid = self.sub_map.get(hdr.object) orelse return;
                if (self.surfaces.getPtr(sid)) |surf| {
                    surf.sub_x = x;
                    surf.sub_y = y;
                }
                if (self.view.subsurface_pos) |cb| cb(self.view.ctx, sid, x, y);
            },
            // place_above / place_below / set_sync / set_desync: the
            // full-copy view stacks subsurfaces above the parent and
            // commits them immediately, so these are no-ops.
            2, 3, 4, 5 => {},
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_region) switch (hdr.opcode) {
            0 => { // destroy
                if (self.regions.getPtr(hdr.object)) |r| {
                    r.deinit(self.allocator);
                    _ = self.regions.remove(hdr.object);
                }
                try self.destroyObject(hdr.object);
            },
            1 => { // add(x, y, w, h)
                const slot = try self.regions.getOrPut(self.allocator, hdr.object);
                if (!slot.found_existing) slot.value_ptr.* = .empty;
                const x = (try it.next()).?.int;
                const y = (try it.next()).?.int;
                const rw = (try it.next()).?.int;
                const rh = (try it.next()).?.int;
                try slot.value_ptr.append(self.allocator, .{ .x = x, .y = y, .w = rw, .h = rh });
            },
            2 => {}, // subtract — v1 over-approximates (fails safe)
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_shm) switch (hdr.opcode) {
            0 => { // create_pool(id, fd, size) — bytes via side-band
                const id = (try it.next()).?.new_id;
                _ = (try it.next()).?; // fd placeholder
                const size = (try it.next()).?.int;
                if (size <= 0) return Error.Protocol;
                try self.register(id, &protocol.wl_shm_pool);
                const slot = try self.pools.getOrPut(self.allocator, id);
                if (!slot.found_existing) slot.value_ptr.* = .{};
                try slot.value_ptr.bytes.resize(self.allocator, @intCast(size));
            },
            else => return Error.Protocol, // release is since-2; we advertise 1
        } else if (iface == &protocol.wl_shm_pool) switch (hdr.opcode) {
            0 => { // create_buffer
                const id = (try it.next()).?.new_id;
                const offset = (try it.next()).?.int;
                const width = (try it.next()).?.int;
                const height = (try it.next()).?.int;
                const stride = (try it.next()).?.int;
                const format = (try it.next()).?.uint;
                // width*4 is widened to i64 first: width is client-controlled
                // i32, so the i32 multiply would overflow (UB/wrap in
                // ReleaseFast) for width > ~536M and let the guard pass.
                if (width <= 0 or height <= 0 or @as(i64, stride) < @as(i64, width) * 4 or offset < 0)
                    return Error.Protocol;
                try self.register(id, &protocol.wl_buffer);
                try self.buffers.put(self.allocator, id, .{
                    .pool = hdr.object,
                    .offset = offset,
                    .width = width,
                    .height = height,
                    .stride = stride,
                    .format = format,
                });
            },
            1 => { // destroy — mirror stays while buffers reference it
                try self.destroyObject(hdr.object);
            },
            2 => {}, // resize — side-band already grew the mirror
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_buffer) {
            // destroy
            _ = self.buffers.remove(hdr.object);
            try self.destroyObject(hdr.object);
        } else if (iface == &protocol.wl_surface) {
            try self.surfaceRequest(hdr, &it);
        } else if (iface == &protocol.wl_seat) switch (hdr.opcode) {
            0 => { // get_pointer
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.wl_pointer);
                try self.pointers.append(self.allocator, id);
            },
            1 => { // get_keyboard
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.wl_keyboard);
                try self.keyboards.append(self.allocator, id);
                // The daemon materializes the keymap fd and emits
                // wl_keyboard.keymap(id, format, fd, size) itself.
                var payload: std.ArrayList(u8) = .empty;
                defer payload.deinit(self.allocator);
                var meta: [8]u8 = undefined;
                std.mem.writeInt(u32, meta[0..4], id, .little);
                std.mem.writeInt(u32, meta[4..8], 1, .little); // xkb_v1
                try payload.appendSlice(self.allocator, &meta);
                try payload.appendSlice(self.allocator, us_keymap);
                try pipe.appendUnit(&self.out, self.allocator, .keymap, payload.items);
                if (self.seat_version >= 4) {
                    var rbuf: [16]u8 = undefined;
                    var rb = wire.Builder.init(&rbuf, id, 5); // repeat_info
                    rb.putInt(30); // keys/sec
                    rb.putInt(400); // delay ms
                    try self.send(try rb.finish());
                }
            },
            2 => { // get_touch — registered, never speaks
                try self.register((try it.next()).?.new_id, &protocol.wl_touch);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_pointer) switch (hdr.opcode) {
            // set_cursor: accepted, ignored — the local pointer
            // keeps its native cursor in v1. The cursor surface
            // (no xdg role) renders nowhere by design.
            0 => {},
            1 => { // release
                removeId(&self.pointers, hdr.object);
                try self.destroyObject(hdr.object);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_keyboard or iface == &protocol.wl_touch) {
            // release — the only request on both.
            removeId(&self.keyboards, hdr.object);
            try self.destroyObject(hdr.object);
        } else if (iface == &protocol.wl_output) {
            // release — lenient even though we advertise v2.
            try self.destroyObject(hdr.object);
        } else if (iface == &protocol.wp_cursor_shape_manager_v1) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object),
            1, 2 => { // get_pointer / get_tablet_tool_v2
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.wp_cursor_shape_device_v1);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wp_cursor_shape_device_v1) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object),
            1 => { // set_shape(serial, shape)
                _ = (try it.next()).?; // serial
                const shape = (try it.next()).?.uint;
                if (self.view.cursor_shape) |cb| cb(self.view.ctx, shape);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wp_viewporter) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object),
            1 => { // get_viewport
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.wp_viewport);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wp_viewport) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object),
            // set_source / set_destination: scale-1 scope — the
            // destination always equals the buffer size in practice.
            1, 2 => {},
            else => return Error.Protocol,
        } else if (iface == &protocol.zxdg_decoration_manager_v1) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object),
            1 => { // get_toplevel_decoration(id, xdg_toplevel)
                const id = (try it.next()).?.new_id;
                const tl = (try it.next()).?.object;
                const sid = self.xdg_map.get(tl) orelse return Error.Protocol;
                try self.register(id, &protocol.zxdg_toplevel_decoration_v1);
                try self.xdg_map.put(self.allocator, id, sid);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.zxdg_toplevel_decoration_v1) switch (hdr.opcode) {
            0 => { // destroy
                _ = self.xdg_map.remove(hdr.object);
                try self.destroyObject(hdr.object);
            },
            1, 2 => { // set_mode(u) / unset_mode
                var mode: u32 = 2; // unset → we prefer server-side
                if (hdr.opcode == 1) mode = (try it.next()).?.uint;
                if (mode != 1) mode = 2;
                var buf: [16]u8 = undefined;
                var b = wire.Builder.init(&buf, hdr.object, 0); // configure
                b.putUint(mode);
                try self.send(try b.finish());
                if (self.xdg_map.get(hdr.object)) |sid| {
                    if (self.view.toplevel_decoration) |cb| cb(self.view.ctx, sid, mode == 2);
                }
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_data_device_manager) switch (hdr.opcode) {
            0 => { // create_data_source
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.wl_data_source);
                try self.data_sources.put(self.allocator, id, .empty);
            },
            1 => { // get_data_device(id, seat)
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.wl_data_device);
                try self.data_devices.append(self.allocator, id);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_data_source) switch (hdr.opcode) {
            0 => { // offer(mime)
                const mime = (try it.next()).?.string orelse return Error.Protocol;
                const mimes = self.data_sources.getPtr(hdr.object) orelse return Error.Protocol;
                const owned = try self.allocator.dupe(u8, mime);
                errdefer self.allocator.free(owned);
                try mimes.append(self.allocator, owned);
            },
            1 => { // destroy
                if (self.data_sources.getPtr(hdr.object)) |mimes| {
                    for (mimes.items) |m| self.allocator.free(m);
                    mimes.deinit(self.allocator);
                    _ = self.data_sources.remove(hdr.object);
                }
                try self.destroyObject(hdr.object);
            },
            else => {}, // set_actions — dnd, ignored at v1
        } else if (iface == &protocol.wl_data_device) switch (hdr.opcode) {
            0 => {}, // start_drag — dnd unsupported in v1
            1 => { // set_selection(?source, serial)
                const source = (try it.next()).?.object;
                if (source != 0) {
                    if (self.bestTextMime(source)) |mime| {
                        if (self.view.clipboard_offer) |cb| cb(self.view.ctx, source, mime);
                    }
                }
            },
            2 => { // release
                removeId(&self.data_devices, hdr.object);
                try self.destroyObject(hdr.object);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_data_offer) switch (hdr.opcode) {
            0 => {}, // accept — dnd negotiation, ignored
            1 => { // receive(mime, fd) — the paste; fd is held by
                // the daemon, FIFO-paired with sendClipData answers.
                const mime = (try it.next()).?.string orelse return Error.Protocol;
                if (self.view.clipboard_read) |cb| cb(self.view.ctx, mime);
            },
            2 => try self.destroyObject(hdr.object), // destroy
            else => {}, // finish/set_actions — dnd, ignored
        } else if (iface == &protocol.xdg_wm_base) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object), // destroy
            1 => { // create_positioner
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.xdg_positioner);
            },
            2 => { // get_xdg_surface(id, surface)
                const id = (try it.next()).?.new_id;
                const sid = (try it.next()).?.object;
                const surf = self.surfaces.getPtr(sid) orelse return Error.Protocol;
                if (surf.xdg_surface != 0) return Error.Protocol;
                try self.register(id, &protocol.xdg_surface);
                try self.xdg_map.put(self.allocator, id, sid);
                surf.xdg_surface = id;
            },
            3 => {}, // pong
            else => return Error.Protocol,
        } else if (iface == &protocol.xdg_positioner) {
            const pos = blk: {
                const slot = try self.positioners.getOrPut(self.allocator, hdr.object);
                if (!slot.found_existing) slot.value_ptr.* = .{};
                break :blk slot.value_ptr;
            };
            switch (hdr.opcode) {
                0 => { // destroy
                    _ = self.positioners.remove(hdr.object);
                    try self.destroyObject(hdr.object);
                },
                1 => { // set_size
                    pos.w = (try it.next()).?.int;
                    pos.h = (try it.next()).?.int;
                },
                2 => { // set_anchor_rect
                    pos.ax = (try it.next()).?.int;
                    pos.ay = (try it.next()).?.int;
                    pos.aw = (try it.next()).?.int;
                    pos.ah = (try it.next()).?.int;
                },
                3 => pos.anchor = (try it.next()).?.uint,
                4 => pos.gravity = (try it.next()).?.uint,
                6 => { // set_offset
                    pos.ox = (try it.next()).?.int;
                    pos.oy = (try it.next()).?.int;
                },
                // constraint_adjustment / reactive / parent_size /
                // parent_configure: accepted, unused in v1.
                5, 7, 8, 9 => {},
                else => return Error.Protocol,
            }
        } else if (iface == &protocol.xdg_popup) {
            const sid = self.xdg_map.get(hdr.object) orelse return Error.Protocol;
            switch (hdr.opcode) {
                0 => { // destroy
                    if (self.grabbed_popup == sid) self.grabbed_popup = 0;
                    if (self.surfaces.getPtr(sid)) |surf| {
                        surf.popup = 0;
                        surf.configured = false;
                    }
                    if (self.view.popup_gone) |cb| cb(self.view.ctx, sid);
                    _ = self.xdg_map.remove(hdr.object);
                    try self.destroyObject(hdr.object);
                },
                1 => { // grab(seat, serial)
                    self.grabbed_popup = sid;
                },
                2 => {}, // reposition — v1 keeps the original spot
                else => return Error.Protocol,
            }
        } else if (iface == &protocol.xdg_surface) {
            try self.xdgSurfaceRequest(hdr, &it);
        } else if (iface == &protocol.xdg_toplevel) {
            try self.toplevelRequest(hdr, body, &it);
        } else {
            return Error.Protocol;
        }
    }

    fn surfaceRequest(self: *Compositor, hdr: wire.Header, it: *wire.ArgIter) Error!void {
        const surf = self.surfaces.getPtr(hdr.object) orelse return Error.Protocol;
        switch (hdr.opcode) {
            0 => { // destroy
                if (surf.toplevel != 0) self.notifyGone(hdr.object);
                if (surf.popup != 0) {
                    if (self.grabbed_popup == hdr.object) self.grabbed_popup = 0;
                    if (self.view.popup_gone) |cb| cb(self.view.ctx, hdr.object);
                }
                if (surf.subparent != 0) {
                    if (self.view.subsurface_gone) |cb| cb(self.view.ctx, hdr.object);
                }
                if (self.pointer_focus == hdr.object) self.pointer_focus = 0;
                if (self.keyboard_focus == hdr.object) self.keyboard_focus = 0;
                surf.frame_cbs.deinit(self.allocator);
                surf.input_rects.deinit(self.allocator);
                _ = self.surfaces.remove(hdr.object);
                try self.destroyObject(hdr.object);
            },
            1 => { // attach(buffer, x, y)
                surf.pending_buffer = (try it.next()).?.object;
                surf.has_pending = true;
            },
            3 => { // frame(callback)
                const cb = (try it.next()).?.new_id;
                try surf.frame_cbs.append(self.allocator, cb);
            },
            5 => { // set_input_region(?region) — staged until commit
                const region = (try it.next()).?.object;
                surf.input_pending = true;
                surf.input_rects.clearRetainingCapacity();
                if (region == 0) {
                    surf.input_whole = true;
                } else {
                    surf.input_whole = false;
                    if (self.regions.get(region)) |rects| {
                        try surf.input_rects.appendSlice(self.allocator, rects.items);
                    }
                }
            },
            6 => try self.commit(hdr.object, surf),
            8 => { // set_buffer_scale(scale) — HiDPI buffers
                const sc = (try it.next()).?.int;
                surf.buffer_scale = if (sc > 0) sc else 1;
            },
            // damage/damage_buffer/opaque-region/transform/offset:
            // accepted, ignored (full-copy pipeline).
            2, 4, 7, 9, 10 => {},
            else => return Error.Protocol,
        }
    }

    fn xdgSurfaceRequest(self: *Compositor, hdr: wire.Header, it: *wire.ArgIter) Error!void {
        const sid = self.xdg_map.get(hdr.object) orelse return Error.Protocol;
        switch (hdr.opcode) {
            0 => { // destroy
                if (self.surfaces.getPtr(sid)) |surf| {
                    surf.xdg_surface = 0;
                    surf.configured = false;
                }
                _ = self.xdg_map.remove(hdr.object);
                try self.destroyObject(hdr.object);
            },
            1 => { // get_toplevel(id)
                const id = (try it.next()).?.new_id;
                const surf = self.surfaces.getPtr(sid) orelse return Error.Protocol;
                if (surf.toplevel != 0) return Error.Protocol;
                try self.register(id, &protocol.xdg_toplevel);
                try self.xdg_map.put(self.allocator, id, sid);
                surf.toplevel = id;
                // Tell the surface it's on our output so GTK3 reads the
                // scale (without it GTK3 renders mis-scaled / half-height).
                if (self.output_id != 0) {
                    var ebuf: [16]u8 = undefined;
                    var eb = wire.Builder.init(&ebuf, sid, 0); // wl_surface.enter
                    eb.putObject(self.output_id);
                    try self.send(try eb.finish());
                }
                if (self.view.toplevel_new) |cb| cb(self.view.ctx, sid);
            },
            2 => { // get_popup(id, parent, positioner)
                const id = (try it.next()).?.new_id;
                const parent_xdg = (try it.next()).?.object;
                const pos_id = (try it.next()).?.object;
                if (parent_xdg == 0) return Error.Protocol; // v1: explicit parent only
                const parent_sid = self.xdg_map.get(parent_xdg) orelse return Error.Protocol;
                const pos = self.positioners.get(pos_id) orelse return Error.Protocol;
                const surf = self.surfaces.getPtr(sid) orelse return Error.Protocol;
                if (surf.toplevel != 0 or surf.popup != 0) return Error.Protocol;
                try self.register(id, &protocol.xdg_popup);
                try self.xdg_map.put(self.allocator, id, sid);
                const at = pos.place();
                surf.popup = id;
                surf.parent = parent_sid;
                surf.px = at[0];
                surf.py = at[1];
                surf.pw = pos.w;
                surf.ph = pos.h;
                if (self.view.popup_new) |cb| cb(self.view.ctx, sid, parent_sid, at[0], at[1]);
            },
            3 => { // set_window_geometry(x, y, w, h) — staged
                const surf = self.surfaces.getPtr(sid) orelse return Error.Protocol;
                surf.geo_pending = true;
                surf.geo_next = .{
                    .x = (try it.next()).?.int,
                    .y = (try it.next()).?.int,
                    .w = (try it.next()).?.int,
                    .h = (try it.next()).?.int,
                };
            },
            4 => {}, // ack_configure
            else => return Error.Protocol,
        }
    }

    fn toplevelRequest(self: *Compositor, hdr: wire.Header, body: []const u8, it: *wire.ArgIter) Error!void {
        _ = body;
        const sid = self.xdg_map.get(hdr.object) orelse return Error.Protocol;
        switch (hdr.opcode) {
            0 => { // destroy
                if (self.surfaces.getPtr(sid)) |surf| surf.toplevel = 0;
                self.notifyGone(sid);
                _ = self.xdg_map.remove(hdr.object);
                try self.destroyObject(hdr.object);
            },
            2 => { // set_title(s)
                const title = (try it.next()).?.string orelse return;
                if (self.view.toplevel_title) |cb| cb(self.view.ctx, sid, title);
            },
            3 => { // set_app_id(s)
                const app_id = (try it.next()).?.string orelse return;
                if (self.view.toplevel_app_id) |cb| cb(self.view.ctx, sid, app_id);
            },
            1 => { // set_parent(?toplevel)
                const ptl = (try it.next()).?.object;
                const psid = if (ptl != 0) (self.xdg_map.get(ptl) orelse 0) else 0;
                if (self.view.toplevel_parent) |cb| cb(self.view.ctx, sid, psid);
            },
            8 => { // set_min_size(w, h)
                const mw = (try it.next()).?.int;
                const mh = (try it.next()).?.int;
                if (self.view.toplevel_min_size) |cb| cb(self.view.ctx, sid, mw, mh);
            },
            9, 10, 12, 13 => { // maximize / unmaximize / unfullscreen / minimize
                const op: u8 = switch (hdr.opcode) {
                    9 => 1,
                    10 => 2,
                    12 => 4,
                    else => 5,
                };
                if (self.view.toplevel_state_request) |cb| cb(self.view.ctx, sid, op);
            },
            11 => { // set_fullscreen(?output)
                if (self.view.toplevel_state_request) |cb| cb(self.view.ctx, sid, 3);
            },
            5 => { // move(seat, serial) — app-initiated window drag
                if (self.view.toplevel_move) |cb| cb(self.view.ctx, sid);
            },
            6 => { // resize(seat, serial, edges)
                _ = (try it.next()).?; // seat
                _ = (try it.next()).?; // serial
                const edges = (try it.next()).?.uint;
                if (self.view.toplevel_resize) |cb| cb(self.view.ctx, sid, edges);
            },
            // show_window_menu needs a real GdkEvent to forward —
            // there is none for synthetic input; set_max_size has
            // no GTK4 window API. Both accepted and dropped.
            4, 7 => {},
            else => return Error.Protocol,
        }
    }

    /// Latch pending state, push pixels to the view, fire frame
    /// callbacks, release the buffer. The xdg dance: the first
    /// commit WITHOUT a buffer triggers the initial configure.
    fn commit(self: *Compositor, sid: u32, surf: *Surface) Error!void {
        // A buffer is copied + released exactly once: on the commit
        // that attaches it. A commit WITHOUT a fresh attach (frame
        // callback / damage-only repaint — common in GTK on cursor
        // and hover redraws) keeps the same content and must NOT
        // re-release. Releasing the same wl_buffer twice underflows
        // the client's cairo surface refcount and aborts the app
        // (cairo_surface_reference assertion).
        const took_buffer = surf.has_pending;
        if (surf.has_pending) {
            surf.committed_buffer = surf.pending_buffer;
            surf.has_pending = false;
        }
        if (surf.geo_pending) {
            surf.geo_pending = false;
            surf.geo = surf.geo_next;
            if (self.view.toplevel_geometry) |cb|
                cb(self.view.ctx, sid, surf.geo.x, surf.geo.y, surf.geo.w, surf.geo.h);
        }
        if (surf.input_pending) {
            surf.input_pending = false;
            if (self.view.input_region) |cb| {
                cb(self.view.ctx, sid, if (surf.input_whole) null else surf.input_rects.items);
            }
        }

        if (surf.xdg_surface != 0 and !surf.configured) {
            surf.configured = true;
            if (surf.toplevel != 0) {
                var buf: [64]u8 = undefined;
                var b = wire.Builder.init(&buf, surf.toplevel, 0); // configure
                b.putInt(0); // width: client decides
                b.putInt(0);
                var states: [4]u8 = undefined;
                std.mem.writeInt(u32, &states, 4, .little); // activated
                b.putArray(&states);
                try self.send(try b.finish());
            } else if (surf.popup != 0) {
                var buf: [32]u8 = undefined;
                var b = wire.Builder.init(&buf, surf.popup, 0); // configure
                b.putInt(surf.px);
                b.putInt(surf.py);
                b.putInt(surf.pw);
                b.putInt(surf.ph);
                try self.send(try b.finish());
            }
            var buf2: [16]u8 = undefined;
            var b2 = wire.Builder.init(&buf2, surf.xdg_surface, 0); // configure
            b2.putUint(self.nextSerial());
            try self.send(try b2.finish());
        }

        if (took_buffer and surf.committed_buffer != 0) {
            if (self.buffers.get(surf.committed_buffer)) |info| {
                // Only mapped surfaces (toplevel/popup/subsurface role)
                // reach the view — cursor surfaces (set_cursor, no role)
                // commit buffers too and must NOT become windows.
                if (surf.toplevel != 0 or surf.popup != 0 or surf.subparent != 0)
                    try self.pushFrame(sid, info);
                // Released immediately: pixels were copied out (or
                // ignored — either way we won't read them later).
                var buf: [8]u8 = undefined;
                var b = wire.Builder.init(&buf, surf.committed_buffer, 0); // release
                try self.send(try b.finish());
            }
        }

        // Frame callbacks: done + delete_id, in request order.
        for (surf.frame_cbs.items) |cb| {
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, cb, 0); // done
            b.putUint(self.now_ms);
            try self.send(try b.finish());
            try self.deleteId(cb);
        }
        surf.frame_cbs.clearRetainingCapacity();
    }

    /// Copy the committed pixels tightly packed and hand them to the
    /// view. Bounds are clamped against the mirror, not trusted.
    ///
    /// The FULL buffer is sent — CSD shadow included — so the host
    /// shows the app's real drop shadow. The shadow is kept out of the
    /// WM's window geometry (snapping/maximize hit the real edge) by
    /// the view reporting it as the host toplevel's shadow width; the
    /// committed window-geometry rect rides along via toplevel_geometry.
    fn pushFrame(self: *Compositor, sid: u32, info: Buffer) Error!void {
        const cb = self.view.toplevel_frame orelse return;
        const pool = self.pools.getPtr(info.pool) orelse return;
        const scale: i32 = if (self.surfaces.getPtr(sid)) |s| s.buffer_scale else 1;
        const w: usize = @intCast(info.width);
        const h: usize = @intCast(info.height);
        const stride: usize = @intCast(info.stride);
        const offset: usize = @intCast(info.offset);
        const row_bytes = w * 4;
        try self.frame_scratch.resize(self.allocator, row_bytes * h);
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const src_start = offset + y * stride;
            if (src_start + row_bytes > pool.bytes.items.len) return; // stale mirror
            @memcpy(
                self.frame_scratch.items[y * row_bytes ..][0..row_bytes],
                pool.bytes.items[src_start..][0..row_bytes],
            );
        }
        cb(self.view.ctx, sid, @intCast(w), @intCast(h), scale, info.format, self.frame_scratch.items);
    }

    // ── server plumbing ─────────────────────────────────────────

    fn boundGlobal(self: *Compositor, id: u32, iface: *const protocol.Interface) Error!void {
        if (iface == &protocol.wl_shm) {
            for ([_]u32{ 0, 1 }) |fmt| { // argb8888, xrgb8888
                var buf: [16]u8 = undefined;
                var b = wire.Builder.init(&buf, id, 0); // format
                b.putUint(fmt);
                try self.send(try b.finish());
            }
        } else if (iface == &protocol.wl_seat) {
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, id, 0); // capabilities
            b.putUint(3); // pointer | keyboard
            try self.send(try b.finish());
        } else if (iface == &protocol.wl_output) {
            var gbuf: [96]u8 = undefined;
            var g = wire.Builder.init(&gbuf, id, 0); // geometry
            g.putInt(0); // x
            g.putInt(0);
            g.putInt(0); // physical size unknown
            g.putInt(0);
            g.putInt(0); // subpixel unknown
            g.putString("sketerm");
            g.putString("remote");
            g.putInt(0); // transform normal
            try self.send(try g.finish());
            var mbuf: [32]u8 = undefined;
            var m = wire.Builder.init(&mbuf, id, 1); // mode
            m.putUint(0x3); // current | preferred
            m.putInt(1920);
            m.putInt(1080);
            m.putInt(60000);
            try self.send(try m.finish());
            var sbuf: [16]u8 = undefined;
            var s = wire.Builder.init(&sbuf, id, 3); // scale
            s.putInt(self.output_scale);
            try self.send(try s.finish());
            var dbuf: [8]u8 = undefined;
            var d = wire.Builder.init(&dbuf, id, 2); // done
            try self.send(try d.finish());
        }
    }

    fn register(self: *Compositor, id: u32, iface: *const protocol.Interface) Error!void {
        if (id == 0) return Error.Protocol;
        const slot = try self.objects.getOrPut(self.allocator, id);
        if (slot.found_existing) return Error.Protocol;
        slot.value_ptr.* = iface;
    }

    /// Remove a destroyed object and confirm to the client so it
    /// can reuse the id.
    fn destroyObject(self: *Compositor, id: u32) Error!void {
        _ = self.objects.remove(id);
        try self.deleteId(id);
    }

    fn deleteId(self: *Compositor, id: u32) Error!void {
        _ = self.objects.remove(id);
        var buf: [16]u8 = undefined;
        var b = wire.Builder.init(&buf, 1, 1); // wl_display.delete_id
        b.putUint(id);
        try self.send(try b.finish());
    }

    fn notifyGone(self: *Compositor, sid: u32) void {
        if (self.view.toplevel_gone) |cb| cb(self.view.ctx, sid);
    }

    fn nextSerial(self: *Compositor) u32 {
        self.serial +%= 1;
        return self.serial;
    }

    fn send(self: *Compositor, msg: []const u8) Error!void {
        try pipe.appendUnit(&self.out, self.allocator, .wl_msg, msg);
    }

    /// wl_display.error + dead-mark. The object may be anything the
    /// client recognizes; code 1 = invalid_method is close enough
    /// for every v1 refusal.
    fn fatal(self: *Compositor, object: u32, text: []const u8) Error!void {
        var buf: [128]u8 = undefined;
        var b = wire.Builder.init(&buf, 1, 0); // wl_display.error
        b.putObject(object);
        b.putUint(1);
        b.putString(text);
        try self.send(try b.finish());
        self.dead = true;
    }
};

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

const TestView = struct {
    new_count: usize = 0,
    frames: usize = 0,
    last_w: i32 = 0,
    last_scale: i32 = 0,
    last_h: i32 = 0,
    last_pixels: [64]u8 = undefined,
    last_len: usize = 0,
    title_buf: [64]u8 = undefined,
    title_len: usize = 0,
    gone: usize = 0,
    popups: usize = 0,
    popups_gone: usize = 0,
    popup_x: i32 = 0,
    popup_y: i32 = 0,
    popup_parent: u32 = 0,
    subs: usize = 0,
    subs_gone: usize = 0,
    sub_x: i32 = 0,
    sub_y: i32 = 0,
    sub_parent: u32 = 0,
    clip_source: u32 = 0,
    clip_mime: [64]u8 = undefined,
    clip_mime_len: usize = 0,
    clip_data: [64]u8 = undefined,
    clip_data_len: usize = 0,
    clip_reads: usize = 0,
    cursor: u32 = 0,
    ssd: ?bool = null,
    input_rects: usize = 999,

    fn onNew(ctx: ?*anyopaque, surface: u32) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.new_count += 1;
    }
    fn onFrame(ctx: ?*anyopaque, surface: u32, w: i32, h: i32, scale: i32, format: u32, pixels: []const u8) void {
        _ = surface;
        _ = format;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.frames += 1;
        self.last_scale = scale;
        self.last_w = w;
        self.last_h = h;
        self.last_len = @min(pixels.len, self.last_pixels.len);
        @memcpy(self.last_pixels[0..self.last_len], pixels[0..self.last_len]);
    }
    fn onTitle(ctx: ?*anyopaque, surface: u32, title: []const u8) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.title_len = @min(title.len, self.title_buf.len);
        @memcpy(self.title_buf[0..self.title_len], title[0..self.title_len]);
    }
    fn onGone(ctx: ?*anyopaque, surface: u32) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.gone += 1;
    }

    fn onPopupNew(ctx: ?*anyopaque, surface: u32, parent: u32, x: i32, y: i32) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.popups += 1;
        self.popup_x = x;
        self.popup_y = y;
        self.popup_parent = parent;
    }
    fn onPopupGone(ctx: ?*anyopaque, surface: u32) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.popups_gone += 1;
    }

    fn onSubNew(ctx: ?*anyopaque, surface: u32, parent: u32, x: i32, y: i32) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.subs += 1;
        self.sub_parent = parent;
        self.sub_x = x;
        self.sub_y = y;
    }
    fn onSubPos(ctx: ?*anyopaque, surface: u32, x: i32, y: i32) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.sub_x = x;
        self.sub_y = y;
    }
    fn onSubGone(ctx: ?*anyopaque, surface: u32) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.subs_gone += 1;
    }

    fn onClipOffer(ctx: ?*anyopaque, source: u32, mime: []const u8) void {
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.clip_source = source;
        self.clip_mime_len = @min(mime.len, self.clip_mime.len);
        @memcpy(self.clip_mime[0..self.clip_mime_len], mime[0..self.clip_mime_len]);
    }
    fn onClipData(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.clip_data_len = @min(bytes.len, self.clip_data.len);
        @memcpy(self.clip_data[0..self.clip_data_len], bytes[0..self.clip_data_len]);
    }
    fn onClipRead(ctx: ?*anyopaque, mime: []const u8) void {
        _ = mime;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.clip_reads += 1;
    }
    fn onCursor(ctx: ?*anyopaque, shape: u32) void {
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.cursor = shape;
    }
    fn onInputRegion(ctx: ?*anyopaque, surface: u32, rects: ?[]const Rect) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.input_rects = if (rects) |r| r.len else 999;
    }
    fn onDeco(ctx: ?*anyopaque, surface: u32, ssd: bool) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.ssd = ssd;
    }

    fn view(self: *TestView) View {
        return .{
            .ctx = self,
            .toplevel_new = onNew,
            .toplevel_frame = onFrame,
            .toplevel_title = onTitle,
            .toplevel_gone = onGone,
            .popup_new = onPopupNew,
            .popup_gone = onPopupGone,
            .subsurface_new = onSubNew,
            .subsurface_pos = onSubPos,
            .subsurface_gone = onSubGone,
            .clipboard_offer = onClipOffer,
            .clipboard_data = onClipData,
            .clipboard_read = onClipRead,
            .cursor_shape = onCursor,
            .toplevel_decoration = onDeco,
            .input_region = onInputRegion,
        };
    }
};

/// Feed one client request as a wl_msg unit.
fn req(comp: *Compositor, msg: []const u8) !void {
    var unit: std.ArrayList(u8) = .empty;
    defer unit.deinit(t.allocator);
    try pipe.appendUnit(&unit, t.allocator, .wl_msg, msg);
    try comp.feed(unit.items);
}

/// Collect every event (object, opcode) pair currently queued.
fn drainEvents(comp: *Compositor, list: *std.ArrayList([2]u32)) !void {
    var pos: usize = 0;
    const bytes = comp.takeOut();
    while (try pipe.peelUnit(bytes[pos..])) |p| {
        if (p.unit.tag == .wl_msg) {
            const hdr = (try wire.parseHeader(p.unit.payload)).?;
            try list.append(t.allocator, .{ hdr.object, hdr.opcode });
        }
        pos += p.consumed;
    }
    comp.clearOut();
}

test "registry dance announces our globals" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();

    var buf: [64]u8 = undefined;
    var b = wire.Builder.init(&buf, 1, 1); // get_registry(2)
    b.putNewId(2);
    try req(&comp, try b.finish());

    var seen: usize = 0;
    var pos: usize = 0;
    const bytes = comp.takeOut();
    while (try pipe.peelUnit(bytes[pos..])) |p| {
        const hdr = (try wire.parseHeader(p.unit.payload)).?;
        try t.expectEqual(@as(u32, 2), hdr.object); // registry
        try t.expectEqual(@as(u16, 0), hdr.opcode); // global
        seen += 1;
        pos += p.consumed;
    }
    try t.expectEqual(globals.len, seen);
}

test "subsurface: get_subsurface, set_position, destroy" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [128]u8 = undefined;

    { // get_registry(2)
        var b = wire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try req(&comp, try b.finish());
    }
    { // bind wl_compositor(name 1) → id 3
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(1);
        b.putString("wl_compositor");
        b.putUint(4);
        b.putNewId(3);
        try req(&comp, try b.finish());
    }
    { // bind wl_subcompositor(name 11) → id 4
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(11);
        b.putString("wl_subcompositor");
        b.putUint(1);
        b.putNewId(4);
        try req(&comp, try b.finish());
    }
    { // create_surface → parent 5
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(5);
        try req(&comp, try b.finish());
    }
    { // create_surface → child 6
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(6);
        try req(&comp, try b.finish());
    }
    { // get_subsurface(id 7, surface 6, parent 5)
        var b = wire.Builder.init(&buf, 4, 1);
        b.putNewId(7);
        b.putObject(6);
        b.putObject(5);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.subs);
    try t.expectEqual(@as(u32, 5), tv.sub_parent);

    { // wl_subsurface.set_position(40, 60)
        var b = wire.Builder.init(&buf, 7, 1);
        b.putInt(40);
        b.putInt(60);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(i32, 40), tv.sub_x);
    try t.expectEqual(@as(i32, 60), tv.sub_y);

    { // wl_subsurface.destroy
        var b = wire.Builder.init(&buf, 7, 0);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.subs_gone);
}

test "full client lifecycle: bind, surface, xdg dance, commit, pixels" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [128]u8 = undefined;

    { // get_registry(2)
        var b = wire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try req(&comp, try b.finish());
    }
    comp.clearOut();
    { // bind compositor(name 1) → id 3
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(1);
        b.putString("wl_compositor");
        b.putUint(4);
        b.putNewId(3);
        try req(&comp, try b.finish());
    }
    { // bind shm(name 2) → id 4
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(2);
        b.putString("wl_shm");
        b.putUint(1);
        b.putNewId(4);
        try req(&comp, try b.finish());
    }
    { // bind xdg_wm_base(name 5) → id 5
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(5);
        b.putString("xdg_wm_base");
        b.putUint(2);
        b.putNewId(5);
        try req(&comp, try b.finish());
    }
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    // shm formats announced on bind
    try t.expect(evs.items.len >= 2);
    try t.expectEqual([2]u32{ 4, 0 }, evs.items[0]);

    { // create_surface → 6
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(6);
        try req(&comp, try b.finish());
    }
    { // get_xdg_surface(7, surface 6)
        var b = wire.Builder.init(&buf, 5, 2);
        b.putNewId(7);
        b.putObject(6);
        try req(&comp, try b.finish());
    }
    { // get_toplevel(8)
        var b = wire.Builder.init(&buf, 7, 1);
        b.putNewId(8);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.new_count);
    { // set_title
        var b = wire.Builder.init(&buf, 8, 2);
        b.putString("hello");
        try req(&comp, try b.finish());
    }
    try t.expectEqualStrings("hello", tv.title_buf[0..tv.title_len]);

    // First commit (no buffer) → toplevel.configure + xdg.configure
    comp.clearOut();
    { // commit
        var b = wire.Builder.init(&buf, 6, 6);
        try req(&comp, try b.finish());
    }
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    try t.expectEqual(@as(usize, 2), evs.items.len);
    try t.expectEqual([2]u32{ 8, 0 }, evs.items[0]); // toplevel configure
    try t.expectEqual([2]u32{ 7, 0 }, evs.items[1]); // xdg configure

    // Pool (side-band sized), buffer 2x2, attach, frame cb, commit.
    { // create_pool(9, fd, 16)
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(9);
        b.putInt(16);
        try req(&comp, try b.finish());
    }
    { // pool bytes via side-band update
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(t.allocator);
        var px: [16]u8 = undefined;
        for (&px, 0..) |*p, i| p.* = @intCast(i + 100);
        try pipe.appendPoolUpdate(&unit, t.allocator, 9, 0, &px);
        try comp.feed(unit.items);
    }
    { // create_buffer(10, 0, 2x2, stride 8, xrgb)
        var b = wire.Builder.init(&buf, 9, 0);
        b.putNewId(10);
        b.putInt(0);
        b.putInt(2);
        b.putInt(2);
        b.putInt(8);
        b.putUint(1);
        try req(&comp, try b.finish());
    }
    { // attach(10, 0, 0)
        var b = wire.Builder.init(&buf, 6, 1);
        b.putObject(10);
        b.putInt(0);
        b.putInt(0);
        try req(&comp, try b.finish());
    }
    { // frame(11)
        var b = wire.Builder.init(&buf, 6, 3);
        b.putNewId(11);
        try req(&comp, try b.finish());
    }
    comp.clearOut();
    { // commit
        var b = wire.Builder.init(&buf, 6, 6);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.frames);
    try t.expectEqual(@as(i32, 2), tv.last_w);
    try t.expectEqual(@as(i32, 2), tv.last_h);
    try t.expectEqual(@as(u8, 100), tv.last_pixels[0]);
    try t.expectEqual(@as(u8, 115), tv.last_pixels[15]);

    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    // buffer release + frame done + delete_id(11)
    try t.expectEqual(@as(usize, 3), evs.items.len);
    try t.expectEqual([2]u32{ 10, 0 }, evs.items[0]); // release
    try t.expectEqual([2]u32{ 11, 0 }, evs.items[1]); // done
    try t.expectEqual([2]u32{ 1, 1 }, evs.items[2]); // delete_id

    // Re-commit WITHOUT a fresh attach (frame-callback-only repaint,
    // as GTK does on cursor/hover redraws). The buffer must NOT be
    // released a second time — a double release underflows the
    // client's cairo refcount and aborts the app. Only done +
    // delete_id for the new frame callback should come back.
    { // frame(12)
        var b = wire.Builder.init(&buf, 6, 3);
        b.putNewId(12);
        try req(&comp, try b.finish());
    }
    { // commit (no attach)
        var b = wire.Builder.init(&buf, 6, 6);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.frames); // no new frame pushed
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    try t.expectEqual(@as(usize, 2), evs.items.len); // NO release
    try t.expectEqual([2]u32{ 12, 0 }, evs.items[0]); // done
    try t.expectEqual([2]u32{ 1, 1 }, evs.items[1]); // delete_id(12)

    // Toplevel destroy → gone callback.
    { // xdg_toplevel.destroy
        var b = wire.Builder.init(&buf, 8, 0);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.gone);
}

test "seat: devices bind, keymap unit emitted, input events flow" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    { // get_registry(2)
        var b = wire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try req(&comp, try b.finish());
    }
    { // bind seat(name 3) → id 3
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(3);
        b.putString("wl_seat");
        b.putUint(1);
        b.putNewId(3);
        try req(&comp, try b.finish());
    }
    { // bind compositor → 4, create surface 5
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(1);
        b.putString("wl_compositor");
        b.putUint(1);
        b.putNewId(4);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 4, 0);
        b2.putNewId(5);
        try req(&comp, try b2.finish());
    }
    comp.clearOut();
    { // get_pointer(6), get_keyboard(7)
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(6);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 3, 1);
        b2.putNewId(7);
        try req(&comp, try b2.finish());
    }
    // keymap unit with keyboard id 7, format 1, the embedded blob.
    {
        var found = false;
        var pos: usize = 0;
        const bytes = comp.takeOut();
        while (try pipe.peelUnit(bytes[pos..])) |p| {
            if (p.unit.tag == .keymap) {
                try t.expectEqual(@as(u32, 7), std.mem.readInt(u32, p.unit.payload[0..4], .little));
                try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, p.unit.payload[4..8], .little));
                try t.expectEqual(us_keymap.len, p.unit.payload.len - 8);
                found = true;
            }
            pos += p.consumed;
        }
        try t.expect(found);
    }
    comp.clearOut();

    // enter + motion + button + key reach the device objects.
    try comp.pointerEnter(5, 10.5, 20.0);
    try comp.pointerMotion(11.0, 21.0);
    try comp.pointerButton(0x110, true);
    try comp.keyboardEnter(5);
    try comp.keyboardKey(38, true); // evdev 'a'
    try comp.keyboardModifiers(1, 0, 0, 0);

    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    const expect = [_][2]u32{
        .{ 6, 0 }, // pointer enter
        .{ 6, 2 }, // motion
        .{ 6, 3 }, // button
        .{ 7, 1 }, // keyboard enter
        .{ 7, 3 }, // key
        .{ 7, 4 }, // modifiers
    };
    try t.expectEqualSlices([2]u32, &expect, evs.items);

    // No focus → no events.
    try comp.pointerLeave();
    try comp.keyboardLeave();
    comp.clearOut();
    try comp.pointerMotion(1, 1);
    try comp.keyboardKey(38, false);
    try t.expectEqual(@as(usize, 0), comp.takeOut().len);
}

test "clipboard: copy offer, fetch, paste offer, receive answer" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [80]u8 = undefined;

    { // registry(2) + bind manager(name 6) → 3
        var b = wire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try req(&comp, try b.finish());
        var b1 = wire.Builder.init(&buf, 2, 0);
        b1.putUint(6);
        b1.putString("wl_data_device_manager");
        b1.putUint(1);
        b1.putNewId(3);
        try req(&comp, try b1.finish());
    }
    { // create_data_source(4) + offers + get_data_device(5, seat 0)
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(4);
        try req(&comp, try b.finish());
        var b1 = wire.Builder.init(&buf, 4, 0);
        b1.putString("image/png");
        try req(&comp, try b1.finish());
        var b2 = wire.Builder.init(&buf, 4, 0);
        b2.putString("text/plain;charset=utf-8");
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 3, 1);
        b3.putNewId(5);
        b3.putObject(0);
        try req(&comp, try b3.finish());
    }
    { // set_selection(source 4) → clipboard_offer with the text mime
        var b = wire.Builder.init(&buf, 5, 1);
        b.putObject(4);
        b.putUint(1);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(u32, 4), tv.clip_source);
    try t.expectEqualStrings("text/plain;charset=utf-8", tv.clip_mime[0..tv.clip_mime_len]);

    // fetchClipboard → clip_send unit; clip_data unit → callback.
    comp.clearOut();
    try comp.fetchClipboard(4, "text/plain;charset=utf-8");
    {
        const p = (try pipe.peelUnit(comp.takeOut())).?;
        try t.expectEqual(pipe.Tag.clip_send, p.unit.tag);
        try t.expectEqual(@as(u32, 4), std.mem.readInt(u32, p.unit.payload[0..4], .little));
    }
    comp.clearOut();
    {
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(t.allocator);
        try pipe.appendUnit(&unit, t.allocator, .clip_data, "COPIED");
        try comp.feed(unit.items);
    }
    try t.expectEqualStrings("COPIED", tv.clip_data[0..tv.clip_data_len]);

    // offerSelection → data_offer/offer/selection toward device 5,
    // then receive on the server-created offer → clipboard_read.
    comp.clearOut();
    try comp.offerSelection("text/plain;charset=utf-8");
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    try t.expectEqual(@as(usize, 3), evs.items.len);
    try t.expectEqual([2]u32{ 5, 0 }, evs.items[0]); // data_offer
    try t.expectEqual([2]u32{ 0xff000000, 0 }, .{ evs.items[1][0], evs.items[1][1] }); // offer(mime)
    try t.expectEqual([2]u32{ 5, 5 }, evs.items[2]); // selection
    {
        var b = wire.Builder.init(&buf, 0xff000000, 1); // receive
        b.putString("text/plain;charset=utf-8");
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.clip_reads);
    comp.clearOut();
    try comp.sendClipData("PASTED");
    {
        const p = (try pipe.peelUnit(comp.takeOut())).?;
        try t.expectEqual(pipe.Tag.clip_data, p.unit.tag);
        try t.expectEqualStrings("PASTED", p.unit.payload);
    }
}

test "popup lifecycle: positioner place, configure, frame, grab dismiss" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    // registry(2), compositor(3), shm(4), wm_base(5); toplevel
    // surface 6 with xdg 7 + toplevel 8, committed once.
    {
        var b = wire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try req(&comp, try b.finish());
        var b1 = wire.Builder.init(&buf, 2, 0);
        b1.putUint(1);
        b1.putString("wl_compositor");
        b1.putUint(4);
        b1.putNewId(3);
        try req(&comp, try b1.finish());
        var b2 = wire.Builder.init(&buf, 2, 0);
        b2.putUint(2);
        b2.putString("wl_shm");
        b2.putUint(1);
        b2.putNewId(4);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 2, 0);
        b3.putUint(5);
        b3.putString("xdg_wm_base");
        b3.putUint(2);
        b3.putNewId(5);
        try req(&comp, try b3.finish());
        var b4 = wire.Builder.init(&buf, 3, 0);
        b4.putNewId(6);
        try req(&comp, try b4.finish());
        var b5 = wire.Builder.init(&buf, 5, 2);
        b5.putNewId(7);
        b5.putObject(6);
        try req(&comp, try b5.finish());
        var b6 = wire.Builder.init(&buf, 7, 1);
        b6.putNewId(8);
        try req(&comp, try b6.finish());
        var b7 = wire.Builder.init(&buf, 6, 6); // commit
        try req(&comp, try b7.finish());
    }

    // Positioner 9: 100x200 menu anchored bottom-left of a rect at
    // (10, 20, 30, 40), gravity bottom-right → lands at (10, 60).
    {
        var b = wire.Builder.init(&buf, 5, 1); // create_positioner
        b.putNewId(9);
        try req(&comp, try b.finish());
        var b1 = wire.Builder.init(&buf, 9, 1); // set_size
        b1.putInt(100);
        b1.putInt(200);
        try req(&comp, try b1.finish());
        var b2 = wire.Builder.init(&buf, 9, 2); // set_anchor_rect
        b2.putInt(10);
        b2.putInt(20);
        b2.putInt(30);
        b2.putInt(40);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 9, 3); // anchor bottom_left
        b3.putUint(6);
        try req(&comp, try b3.finish());
        var b4 = wire.Builder.init(&buf, 9, 4); // gravity bottom_right
        b4.putUint(8);
        try req(&comp, try b4.finish());
    }

    // Popup: surface 10, xdg 11, popup 12, grab, commit.
    var popup_seen_at: [2]i32 = .{ -1, -1 };
    _ = &popup_seen_at;
    {
        var b = wire.Builder.init(&buf, 3, 0); // create_surface(10)
        b.putNewId(10);
        try req(&comp, try b.finish());
        var b1 = wire.Builder.init(&buf, 5, 2); // get_xdg_surface(11, 10)
        b1.putNewId(11);
        b1.putObject(10);
        try req(&comp, try b1.finish());
        var b2 = wire.Builder.init(&buf, 11, 2); // get_popup(12, 7, 9)
        b2.putNewId(12);
        b2.putObject(7);
        b2.putObject(9);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 12, 1); // grab(seat=0, serial)
        b3.putObject(0);
        b3.putUint(1);
        try req(&comp, try b3.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.popups);
    try t.expectEqual(@as(i32, 10), tv.popup_x);
    try t.expectEqual(@as(i32, 60), tv.popup_y);
    try t.expectEqual(@as(u32, 6), tv.popup_parent);

    // First popup commit → xdg_popup.configure(10,60,100,200).
    comp.clearOut();
    {
        var b = wire.Builder.init(&buf, 10, 6);
        try req(&comp, try b.finish());
    }
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    try t.expectEqual([2]u32{ 12, 0 }, evs.items[0]); // popup configure
    try t.expectEqual([2]u32{ 11, 0 }, evs.items[1]); // xdg configure

    // Click-outside dismiss → popup_done on the grabbed popup.
    comp.clearOut();
    try comp.dismissPopups();
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    try t.expectEqual([2]u32{ 12, 1 }, evs.items[0]); // popup_done
    try t.expectEqual(@as(u32, 0), comp.grabbed_popup);

    // Destroy → popup_gone.
    {
        var b = wire.Builder.init(&buf, 12, 0);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.popups_gone);
}

test "set_cursor is not a destructor; cursor surfaces never reach the view" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    { // registry(2), seat bind(3), compositor bind(4)
        var b = wire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 2, 0);
        b2.putUint(3);
        b2.putString("wl_seat");
        b2.putUint(1);
        b2.putNewId(3);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 2, 0);
        b3.putUint(1);
        b3.putString("wl_compositor");
        b3.putUint(1);
        b3.putNewId(4);
        try req(&comp, try b3.finish());
    }
    { // get_pointer(9)
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(9);
        try req(&comp, try b.finish());
    }
    { // cursor surface (15) + set_cursor — the weston-terminal dance
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(15);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 9, 0); // set_cursor
        b2.putUint(1);
        b2.putObject(15);
        b2.putInt(13);
        b2.putInt(15);
        try req(&comp, try b2.finish());
        // pointer must survive — a second set_cursor still works
        var b3 = wire.Builder.init(&buf, 9, 0);
        b3.putUint(2);
        b3.putObject(0);
        b3.putInt(0);
        b3.putInt(0);
        try req(&comp, try b3.finish());
    }
    try t.expect(!comp.dead);
    try t.expect(comp.objects.get(9) != null);

    { // commit the cursor surface with a buffer → no view callback
        var b = wire.Builder.init(&buf, 2, 0); // bind shm(5)
        b.putUint(2);
        b.putString("wl_shm");
        b.putUint(1);
        b.putNewId(5);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 5, 0); // pool(6, 16)
        b2.putNewId(6);
        b2.putInt(16);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 6, 0); // buffer(7) 2x2
        b3.putNewId(7);
        b3.putInt(0);
        b3.putInt(2);
        b3.putInt(2);
        b3.putInt(8);
        b3.putUint(0);
        try req(&comp, try b3.finish());
        var b4 = wire.Builder.init(&buf, 15, 1); // attach
        b4.putObject(7);
        b4.putInt(0);
        b4.putInt(0);
        try req(&comp, try b4.finish());
        var b5 = wire.Builder.init(&buf, 15, 6); // commit
        try req(&comp, try b5.finish());
    }
    try t.expectEqual(@as(usize, 0), tv.frames);
    try t.expect(!comp.dead);

    { // release destroys the pointer for real
        var b = wire.Builder.init(&buf, 9, 1);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(?*const protocol.Interface, null), comp.objects.get(9));
}

test "extensions: cursor shape, viewporter, buffer scale" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    comp.output_scale = 2;
    defer comp.deinit();
    var buf: [80]u8 = undefined;

    { // registry(2); bind cursor(7)->3, viewporter(8)->4, compositor(1)->7
        var b = wire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try req(&comp, try b.finish());
        var b1 = wire.Builder.init(&buf, 2, 0);
        b1.putUint(7);
        b1.putString("wp_cursor_shape_manager_v1");
        b1.putUint(1);
        b1.putNewId(3);
        try req(&comp, try b1.finish());
        var b2 = wire.Builder.init(&buf, 2, 0);
        b2.putUint(8);
        b2.putString("wp_viewporter");
        b2.putUint(1);
        b2.putNewId(4);
        try req(&comp, try b2.finish());
        var bc = wire.Builder.init(&buf, 2, 0);
        bc.putUint(1);
        bc.putString("wl_compositor");
        bc.putUint(1);
        bc.putNewId(7);
        try req(&comp, try bc.finish());
    }
    { // cursor device(6) + set_shape(text=9) -> callback
        var b = wire.Builder.init(&buf, 3, 1);
        b.putNewId(6);
        b.putObject(0);
        try req(&comp, try b.finish());
        var b1 = wire.Builder.init(&buf, 6, 1);
        b1.putUint(1);
        b1.putUint(9);
        try req(&comp, try b1.finish());
    }
    try t.expectEqual(@as(u32, 9), tv.cursor);

    { // surface(8): viewport inert, set_buffer_scale(2) tracked
        var bs = wire.Builder.init(&buf, 7, 0); // create_surface(8)
        bs.putNewId(8);
        try req(&comp, try bs.finish());
        var b = wire.Builder.init(&buf, 4, 1); // get_viewport(9, surf 8)
        b.putNewId(9);
        b.putObject(8);
        try req(&comp, try b.finish());
        var b1 = wire.Builder.init(&buf, 9, 2); // set_destination
        b1.putInt(800);
        b1.putInt(600);
        try req(&comp, try b1.finish());
        var b2 = wire.Builder.init(&buf, 8, 8); // wl_surface.set_buffer_scale(2)
        b2.putInt(2);
        try req(&comp, try b2.finish());
    }
    try t.expect(!comp.dead);
    try t.expectEqual(@as(i32, 2), comp.surfaces.get(8).?.buffer_scale);
}

test "input region: staged on set, applied at commit" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;
    var b = wire.Builder.init(&buf, 1, 1); // registry(2)
    b.putNewId(2);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 2, 0); // compositor(3)
    b.putUint(1);
    b.putString("wl_compositor");
    b.putUint(1);
    b.putNewId(3);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 3, 0); // surface(4)
    b.putNewId(4);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 3, 1); // region(5)
    b.putNewId(5);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 5, 1); // add(10,10,100,100)
    b.putInt(10);
    b.putInt(10);
    b.putInt(100);
    b.putInt(100);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 4, 5); // set_input_region(5)
    b.putObject(5);
    try req(&comp, try b.finish());
    try t.expectEqual(@as(usize, 999), tv.input_rects); // staged, not applied
    b = wire.Builder.init(&buf, 4, 6); // commit
    try req(&comp, try b.finish());
    try t.expectEqual(@as(usize, 1), tv.input_rects);
    // null region restores whole-surface input
    b = wire.Builder.init(&buf, 4, 5);
    b.putObject(0);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 4, 6);
    try req(&comp, try b.finish());
    try t.expectEqual(@as(usize, 999), tv.input_rects);
}

test "xdg-decoration: SSD negotiation reaches the view" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [80]u8 = undefined;
    // registry(2), compositor(3)→surface(4), wm_base(5)→xdg(6)→toplevel(7)
    var b = wire.Builder.init(&buf, 1, 1);
    b.putNewId(2);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 2, 0);
    b.putUint(1);
    b.putString("wl_compositor");
    b.putUint(1);
    b.putNewId(3);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 2, 0);
    b.putUint(5);
    b.putString("xdg_wm_base");
    b.putUint(1);
    b.putNewId(5);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 3, 0);
    b.putNewId(4);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 5, 2);
    b.putNewId(6);
    b.putObject(4);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 6, 1);
    b.putNewId(7);
    try req(&comp, try b.finish());
    // bind decoration manager(name 10) → 8; decoration 9 on toplevel 7
    b = wire.Builder.init(&buf, 2, 0);
    b.putUint(10);
    b.putString("zxdg_decoration_manager_v1");
    b.putUint(1);
    b.putNewId(8);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 8, 1);
    b.putNewId(9);
    b.putObject(7);
    try req(&comp, try b.finish());
    comp.clearOut();
    b = wire.Builder.init(&buf, 9, 1); // set_mode(server_side)
    b.putUint(2);
    try req(&comp, try b.finish());
    try t.expectEqual(@as(?bool, true), tv.ssd);
    const p = (try pipe.peelUnit(comp.takeOut())).?;
    const hdr = (try wire.parseHeader(p.unit.payload)).?;
    try t.expectEqual(@as(u32, 9), hdr.object); // configure(mode)
    try t.expectEqual(@as(u32, 2), std.mem.readInt(u32, p.unit.payload[wire.header_size..][0..4], .little));
    // client_side flips it back
    b = wire.Builder.init(&buf, 9, 1);
    b.putUint(1);
    try req(&comp, try b.finish());
    try t.expectEqual(@as(?bool, false), tv.ssd);
}

test "protocol violation produces wl_display.error and dead" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;
    // bind on a nonexistent registry object
    var b = wire.Builder.init(&buf, 99, 0);
    b.putUint(1);
    try req(&comp, try b.finish());
    try t.expect(comp.dead);
    const bytes = comp.takeOut();
    const p = (try pipe.peelUnit(bytes)).?;
    const hdr = (try wire.parseHeader(p.unit.payload)).?;
    try t.expectEqual(@as(u32, 1), hdr.object); // wl_display
    try t.expectEqual(@as(u16, 0), hdr.opcode); // error
}

test "stale mirror bounds are never trusted" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [128]u8 = undefined;

    // Minimal dance up to a buffer whose extent exceeds the pool.
    var b = wire.Builder.init(&buf, 1, 1);
    b.putNewId(2);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 2, 0);
    b.putUint(1);
    b.putString("wl_compositor");
    b.putUint(1);
    b.putNewId(3);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 2, 0);
    b.putUint(2);
    b.putString("wl_shm");
    b.putUint(1);
    b.putNewId(4);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 3, 0);
    b.putNewId(6);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 4, 0); // pool 16 bytes
    b.putNewId(9);
    b.putInt(16);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 9, 0); // buffer claims 4x4 stride 16
    b.putNewId(10);
    b.putInt(0);
    b.putInt(4);
    b.putInt(4);
    b.putInt(16);
    b.putUint(1);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 6, 1);
    b.putObject(10);
    b.putInt(0);
    b.putInt(0);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 6, 6); // commit
    try req(&comp, try b.finish());

    // No crash, no frame callback with garbage.
    try t.expectEqual(@as(usize, 0), tv.frames);
    try t.expect(!comp.dead);
}
