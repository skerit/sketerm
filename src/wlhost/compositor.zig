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
//! Input: wl_seat (v5 advertised) with pointer+keyboard. The view
//! injects via
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

/// Default pc105/us xkb keymap; alternatives in keymaps.zig, chosen
/// per session via the spawn `kb_layout` option (Compositor.keymap).
pub const us_keymap = @import("keymaps.zig").us;

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
    /// applied), wl_shm format (0 argb, 1 xrgb). `lw`/`lh` is the
    /// surface's LOGICAL size: the viewport destination when set
    /// (fractional-scale clients), else physical ÷ buffer scale.
    toplevel_frame: ?*const fn (ctx: ?*anyopaque, surface: u32, w: i32, h: i32, scale: i32, lw: i32, lh: i32, format: u32, pixels: []const u8) void = null,
    toplevel_title: ?*const fn (ctx: ?*anyopaque, surface: u32, title: []const u8) void = null,
    /// xdg_toplevel.set_app_id — desktop identity (icon, grouping).
    toplevel_app_id: ?*const fn (ctx: ?*anyopaque, surface: u32, app_id: []const u8) void = null,
    /// The app's window icon as image bytes (daemon-injected via the
    /// toplevel_icon unit; the client sets it on the toplevel).
    /// `kind`: 1 png, 2 svg. Slices valid only for the call.
    toplevel_icon: ?*const fn (ctx: ?*anyopaque, surface: u32, kind: u8, bytes: []const u8) void = null,
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
    /// xdg_popup.reposition: move an existing popup to (x, y) in the
    /// parent's coordinate space (same frame as popup_new).
    popup_moved: ?*const fn (ctx: ?*anyopaque, surface: u32, parent: u32, x: i32, y: i32) void = null,
    /// A pointer lock (zwp_locked_pointer_v1) activated/deactivated
    /// on this surface — the host should hide/restore its cursor.
    pointer_locked: ?*const fn (ctx: ?*anyopaque, surface: u32, locked: bool) void = null,
    /// The app enabled/disabled a zwp_text_input_v3: route the host
    /// IM (IME) at the app while true, raw keys only while false.
    text_input_active: ?*const fn (ctx: ?*anyopaque, active: bool) void = null,
    /// The app announced a PRIMARY selection (middle-click paste)
    /// with a usable text mime. Fetch via fetchClipboard — the
    /// answer routing is the caller's (FIFO with clipboard fetches).
    primary_offer: ?*const fn (ctx: ?*anyopaque, source: u32, mime: []const u8) void = null,
    /// The app wants a primary paste: read the host PRIMARY
    /// selection and ALWAYS answer via sendPrimaryData.
    primary_read: ?*const fn (ctx: ?*anyopaque, mime: []const u8) void = null,
    /// xdg-activation activate: raise/present this surface's window.
    toplevel_raise: ?*const fn (ctx: ?*anyopaque, surface: u32) void = null,
};

const Global = struct {
    name: u32,
    iface: *const protocol.Interface,
    version: u32,
};

const RelPointer = struct { id: u32, pointer: u32 };

const Constraint = struct {
    sid: u32,
    /// 0 = lock (motion suppressed, cursor hidden), 1 = confine.
    kind: u8,
    /// 1 oneshot (defunct after deactivation), 2 persistent.
    lifetime: u32,
    active: bool = false,
};

const TextInput = struct {
    enabled: bool = false,
    pending_enabled: bool = false,
    /// Incremented per commit request; echoed in done events.
    serial: u32 = 0,
};

const HostDrag = struct {
    /// Server-created offer id (0 = no host drop in flight).
    offer: u32 = 0,
    /// Owned payload handed out on receive.
    mime: []u8 = &.{},
    data: []u8 = &.{},

    fn free(self: *HostDrag, a: std.mem.Allocator) void {
        if (self.mime.len > 0) a.free(self.mime);
        if (self.data.len > 0) a.free(self.data);
        self.* = .{};
    }
};

const Drag = struct {
    active: bool = false,
    /// True between drop and dnd_finished/offer-destroy (the data
    /// transfer window — receive() still routes to the source).
    dropped: bool = false,
    source: u32 = 0,
    origin: u32 = 0,
    focus: u32 = 0,
    /// Server-created wl_data_offer mirroring the drag source.
    offer: u32 = 0,
    accepted: bool = false,
    /// Negotiated dnd action (1 copy, 2 move, 4 ask; 0 = none yet).
    action: u32 = 0,
};

/// What we advertise — deliberately low versions: nothing here
/// obliges events we don't implement.
const globals = [_]Global{
    // v6: surfaces get preferred_buffer_scale/transform on creation
    // (GTK4 at v6 sizes buffers from it instead of wl_output scale).
    .{ .name = 1, .iface = &protocol.wl_compositor, .version = 6 },
    // GTK3 maps tooltips / tree-view type-ahead popups as subsurfaces;
    // without this its GdkDisplay->subcompositor is NULL and it crashes
    // (wl_proxy_get_version(NULL)) the first time it shows one.
    .{ .name = 11, .iface = &protocol.wl_subcompositor, .version = 1 },
    .{ .name = 2, .iface = &protocol.wl_shm, .version = 1 },
    // v4: keyboards get repeat_info — held keys repeat client-side.
    // v5: pointer events are frame-grouped (JBR hard-requires >= 5
    // and binds 5 unconditionally; v5-bound clients queue pointer
    // events until the frame, so every injection emits one).
    // v8: wheel scrolls carry axis_value120.
    .{ .name = 3, .iface = &protocol.wl_seat, .version = 8 },
    // v4: name/description events at bind.
    .{ .name = 4, .iface = &protocol.wl_output, .version = 4 },
    // v3 popup reposition; v4 configure_bounds; v5 wm_capabilities
    // (all honored in the configure/reposition paths).
    .{ .name = 5, .iface = &protocol.xdg_wm_base, .version = 6 },
    // v3 wire surface (JBR binds 3 unconditionally). Selection plus
    // WITHIN-APP dnd (start_drag drives a real drag state machine —
    // both ends are the same client, so data flows daemon-locally);
    // cross-app dnd stays out of scope.
    .{ .name = 6, .iface = &protocol.wl_data_device_manager, .version = 3 },
    // Surface-less clipboard: wl-copy/wl-paste set/read the selection
    // without a throwaway focus surface (no taskbar flash). v1 =
    // selection only, no primary selection.
    .{ .name = 12, .iface = &protocol.zwlr_data_control_manager_v1, .version = 1 },
    // Cursor shapes reach the view. Viewport destinations define the
    // surface's LOGICAL size — fractional-scale clients render the
    // buffer at scale120/120 × logical with buffer_scale 1.
    .{ .name = 7, .iface = &protocol.wp_cursor_shape_manager_v1, .version = 1 },
    .{ .name = 8, .iface = &protocol.wp_viewporter, .version = 1 },
    // True fractional scaling: preferred_scale carries the viewer's
    // scale120 (set_scale intent) so apps render for the real pixel
    // grid instead of an integer approximation the host resamples.
    .{ .name = 21, .iface = &protocol.wp_fractional_scale_manager_v1, .version = 1 },
    // Decoration negotiation: SSD-wanting apps (Qt, traditional
    // GTK) get the host window's decorations; CSD apps draw their
    // own into an undecorated host window.
    .{ .name = 10, .iface = &protocol.zxdg_decoration_manager_v1, .version = 1 },
    // Primary selection (middle-click paste), mirroring the
    // wl_data_device selection path with its own daemon fd FIFO.
    .{ .name = 13, .iface = &protocol.zwp_primary_selection_device_manager_v1, .version = 1 },
    // Relative pointer + constraints: mouse-look/pointer-lock apps
    // (games, Blender viewports). Relative motion is derived from
    // absolute injections; locks hide the host cursor via the view.
    .{ .name = 14, .iface = &protocol.zwp_relative_pointer_manager_v1, .version = 1 },
    .{ .name = 15, .iface = &protocol.zwp_pointer_constraints_v1, .version = 1 },
    // text-input v3: host IME commits arrive as text_commit intents.
    .{ .name = 16, .iface = &protocol.zwp_text_input_manager_v3, .version = 1 },
    // xdg-activation: tokens are minted freely; activate = raise.
    .{ .name = 17, .iface = &protocol.xdg_activation_v1, .version = 1 },
    // presentation-time: feedbacks answer at commit time with the
    // brain clock (frame-callback semantics — good enough for A/V).
    .{ .name = 18, .iface = &protocol.wp_presentation, .version = 1 },
    // Accepted-inert: inhibitors are tracked objects with no effect;
    // gesture objects never fire (no gestures detected — legal).
    .{ .name = 19, .iface = &protocol.zwp_idle_inhibit_manager_v1, .version = 1 },
    .{ .name = 20, .iface = &protocol.zwp_pointer_gestures_v1, .version = 3 },
    // linux-dmabuf v3 (v4 needs a main DRM device we don't have):
    // LINEAR-only XRGB/ARGB — the daemon mmaps the plane fd and ships
    // pixels exactly like an shm pool (no GPU libraries anywhere).
    // GPU clients render natively and blit linear; import failure
    // falls back to shm via `failed`.
    .{ .name = 22, .iface = &protocol.zwp_linux_dmabuf_v1, .version = 3 },
    // xdg-output: wl_output's LOGICAL geometry. SDL probes for it and
    // logs a scary "protocol missing: disabling" without it.
    .{ .name = 23, .iface = &protocol.zxdg_output_manager_v1, .version = 3 },
};

const Pool = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// Live wl_buffers created from this pool; the bytes are freed
    /// only when this reaches 0 on a destroyed pool (wl_shm_pool
    /// destructor semantics keep the memory alive for buffers).
    buffers: u32 = 0,
    destroyed: bool = false,
    /// Incarnation serial: pool ids are recycled after delete_id
    /// while old buffers may still reference the displaced storage
    /// (Vulkan WSI probe pools). Buffers match on this, not the id.
    serial: u64 = 0,
    /// Lazily-created video decoder for pool_vtile updates to this pool,
    /// recreated when the tile dimensions or codec change (-Dvideo).
    vdec: ?vcodec.Decoder = null,
    vdec_w: i32 = 0,
    vdec_h: i32 = 0,
    vdec_codec: vcodec.Codec = .stub,

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
    /// Serial of the pool incarnation this buffer was created from
    /// (0 = unresolvable, e.g. restored from a pre-v4 state_sync).
    pool_serial: u64 = 0,
};

/// Plane-0 layout of a zwp_linux_buffer_params_v1 between add and
/// create_immed. ok = single plane with the LINEAR modifier.
const DmabufP = struct { offset: u32 = 0, stride: u32 = 0, ok: bool = false };

const Surface = struct {
    /// Pending (attach happened since last commit). 0 with
    /// has_pending = attach(null) → unmap.
    pending_buffer: u32 = 0,
    has_pending: bool = false,
    /// set_buffer_scale: physical pixels per surface-local (logical)
    /// unit in the committed buffer. 1 unless HiDPI.
    buffer_scale: i32 = 1,
    /// wp_viewport destination — the surface's LOGICAL size when set
    /// (fractional-scale clients); 0 = unset (derive from scale).
    vp_w: i32 = 0,
    vp_h: i32 = 0,
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
    /// wp_presentation_feedback ids answered at the next commit.
    feedbacks: std.ArrayList(u32) = .empty,
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
    /// Retained copies of pass-through toplevel metadata so
    /// state_sync replay can re-fire the View callbacks (the live
    /// path fires them directly without storing). Owned strings.
    title: ?[]u8 = null,
    app_id: ?[]u8 = null,
    /// Decoration mode: 0 never negotiated, 1 CSD, 2 SSD.
    deco: u8 = 0,
    min_w: i32 = 0,
    min_h: i32 = 0,
    /// set_parent target (surface id, 0 = none).
    tl_parent: u32 = 0,

    fn freeOwned(self: *Surface, a: std.mem.Allocator) void {
        self.frame_cbs.deinit(a);
        self.feedbacks.deinit(a);
        self.input_rects.deinit(a);
        if (self.title) |s| a.free(s);
        if (self.app_id) |s| a.free(s);
        self.title = null;
        self.app_id = null;
    }
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
    /// Version the client bound zxdg_output_manager_v1 at (0 = not
    /// bound). Gates name/description (since 2) and the deprecated
    /// per-object done (v1/2 only; v3 relies on wl_output.done). Not
    /// serialized: a post-restore default of 0 just re-gates to v1
    /// behavior, which every client tolerates.
    xdg_output_ver: u32 = 0,
    /// Outgoing pipe units (events). Caller drains via takeOut.
    out: std.ArrayList(u8) = .empty,
    /// Incoming unit reassembly (chan_data may split units).
    inbuf: std.ArrayList(u8) = .empty,
    objects: std.AutoHashMapUnmanaged(u32, *const protocol.Interface) = .empty,
    pools: std.AutoHashMapUnmanaged(u32, Pool) = .empty,
    /// Incarnation serial → pool displaced from `pools` by id reuse
    /// while buffers still referenced it; freed on the last release.
    orphan_pools: std.AutoHashMapUnmanaged(u64, Pool) = .empty,
    pool_serial_ctr: u64 = 0,
    /// Scratch for a decoded video tile's BGRA before it's blitted into
    /// the pool mirror (build_options.video).
    vscratch: std.ArrayList(u8) = .empty,
    buffers: std.AutoHashMapUnmanaged(u32, Buffer) = .empty,
    /// Dmabuf params negotiation state; a completed create_immed
    /// turns into a plain Buffer whose pool is the buffer's own id
    /// (a synthetic pool the pipe units fill like any shm pool).
    dmabuf_params: std.AutoHashMapUnmanaged(u32, DmabufP) = .empty,
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
    /// Bound zwlr_data_control devices (surface-less clipboard). Kept
    /// separate from data_devices because the wlr `selection` event
    /// uses a different opcode and offers go to a different interface.
    data_control_devices: std.ArrayList(u32) = .empty,
    /// Next server-allocated object id (data offers).
    next_server_id: u32 = 0xff000000,
    /// Bound input devices (a client may bind several of each).
    pointers: std.ArrayList(u32) = .empty,
    keyboards: std.ArrayList(u32) = .empty,
    /// Surface currently holding pointer / keyboard focus (0 = none).
    pointer_focus: u32 = 0,
    keyboard_focus: u32 = 0,
    /// Version the client bound wl_seat at (gates repeat_info,
    /// pointer frame grouping, axis_value120).
    seat_version: u32 = 1,
    /// Version the client bound wl_compositor at (gates the
    /// preferred_buffer_scale/transform events on new surfaces).
    compositor_version: u32 = 1,
    /// Version the client bound xdg_wm_base at (gates
    /// configure_bounds and wm_capabilities).
    wm_base_version: u32 = 1,
    /// Version the client bound wl_data_device_manager at (gates the
    /// v3 dnd-action events during within-app drags).
    ddm_version: u32 = 1,
    /// Last injected absolute pointer position — relative_motion
    /// deltas derive from it.
    last_px: f64 = 0,
    last_py: f64 = 0,
    /// Last still-held pointer button (evdev code, 0 = none); its
    /// release ends a within-app drag.
    pressed_button: u32 = 0,
    /// Bound zwp_relative_pointer_v1 objects and the wl_pointer each
    /// one shadows.
    rel_pointers: std.ArrayList(RelPointer) = .empty,
    /// Pointer constraints by locked/confined object id.
    constraints: std.AutoHashMapUnmanaged(u32, Constraint) = .empty,
    /// zwp_text_input_v3 objects (enable/disable is double-buffered:
    /// applied on commit, per spec).
    text_inputs: std.AutoHashMapUnmanaged(u32, TextInput) = .empty,
    /// Bound zwp_primary_selection_device_v1 objects.
    primary_devices: std.ArrayList(u32) = .empty,
    /// wl_data_source.set_actions values (dnd negotiation).
    source_actions: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Within-app drag state (wl_data_device.start_drag).
    drag: Drag = .{},
    /// Host→app drop in flight: a server-sourced dnd offer whose
    /// receive is answered from `host_drag.data` (drop_data unit).
    host_drag: HostDrag = .{},
    /// Viewer display scale × 120 (set_scale intent); 0 = derive
    /// from output_scale. Announced via wp_fractional_scale.
    scale120: u32 = 0,
    /// wp_viewport object id → surface id.
    viewport_map: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// wp_fractional_scale_v1 object id → surface id.
    fs_map: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Tight-packed copy handed to toplevel_frame.
    frame_scratch: std.ArrayList(u8) = .empty,
    serial: u32 = 1,
    /// Caller-provided clock for frame-callback timestamps (ms).
    now_ms: u32 = 0,
    /// Set on fatal protocol error after wl_display.error went out;
    /// the caller should close the channel once out is drained.
    dead: bool = false,
    /// Replica mode (proto v5 viewers): tolerate requests on unknown
    /// objects instead of declaring a protocol error — the daemon
    /// brain is authoritative and its server-created object ids are
    /// invisible to replicas. Never set on the brain itself.
    lenient: bool = false,
    /// Announce zwp_linux_dmabuf_v1 in get_registry. The daemon
    /// brain sets this from SKETERM_MUX_DMABUF; replicas leave it
    /// false (their announcements are discarded, and binds validate
    /// against the static table regardless).
    advertise_dmabuf: bool = false,
    /// Compiled xkb keymap announced to the app's keyboards. Must
    /// match whoever drives the seat (see keymaps.zig).
    keymap: []const u8 = us_keymap,

    pub fn init(allocator: std.mem.Allocator, view: View) Error!Compositor {
        var self = Compositor{ .allocator = allocator, .view = view };
        try self.objects.put(allocator, 1, &protocol.wl_display);
        return self;
    }

    /// Replica pool storage must never expose allocator contents.  Pool
    /// updates may legitimately cover only damaged rows, so bytes outside
    /// those updates remain visible to frame assembly and must start at a
    /// deterministic value.
    fn resizePoolBytes(self: *Compositor, pool: *Pool, size: usize) Error!void {
        const old_len = pool.bytes.items.len;
        try pool.bytes.resize(self.allocator, size);
        if (size > old_len) @memset(pool.bytes.items[old_len..], 0);
    }

    /// Install a fresh pool incarnation under `id`. A displaced
    /// predecessor still referenced by buffers is parked in
    /// orphan_pools under its serial; an unreferenced one is freed.
    fn freshPool(self: *Compositor, id: u32, size: usize) Error!*Pool {
        const slot = try self.pools.getOrPut(self.allocator, id);
        if (slot.found_existing) {
            if (slot.value_ptr.buffers > 0) {
                try self.orphan_pools.put(self.allocator, slot.value_ptr.serial, slot.value_ptr.*);
            } else {
                slot.value_ptr.deinit(self.allocator);
            }
        }
        self.pool_serial_ctr += 1;
        slot.value_ptr.* = .{ .serial = self.pool_serial_ctr };
        try self.resizePoolBytes(slot.value_ptr, size);
        return slot.value_ptr;
    }

    /// The pool a buffer reads from: the current holder of its pool
    /// id when the incarnation matches, else the orphaned one.
    fn poolFor(self: *Compositor, info: Buffer) ?*Pool {
        if (self.pools.getPtr(info.pool)) |p| {
            if (p.serial == info.pool_serial) return p;
        }
        return self.orphan_pools.getPtr(info.pool_serial);
    }

    /// Resolve a pool by incarnation serial (pool_update_s target):
    /// usually an orphan, but a commit raced ahead of the recycling
    /// create_pool still finds the current holder.
    fn poolBySerial(self: *Compositor, serial: u64) ?*Pool {
        if (self.orphan_pools.getPtr(serial)) |p| return p;
        var it = self.pools.valueIterator();
        while (it.next()) |p| {
            if (p.serial == serial) return p;
        }
        return null;
    }

    /// Release one buffer reference against its pool incarnation,
    /// reclaiming bytes when it was the last on a destroyed pool.
    fn releaseBufferRef(self: *Compositor, info: Buffer) void {
        if (self.pools.getPtr(info.pool)) |p| {
            if (p.serial == info.pool_serial) {
                if (p.buffers > 0) p.buffers -= 1;
                if (p.destroyed and p.buffers == 0) {
                    var pool = self.pools.fetchRemove(info.pool).?.value;
                    pool.deinit(self.allocator);
                }
                return;
            }
        }
        if (self.orphan_pools.getPtr(info.pool_serial)) |op| {
            if (op.buffers > 0) op.buffers -= 1;
            if (op.buffers == 0) {
                var pool = self.orphan_pools.fetchRemove(info.pool_serial).?.value;
                pool.deinit(self.allocator);
            }
        }
    }

    pub fn deinit(self: *Compositor) void {
        const a = self.allocator;
        self.out.deinit(a);
        self.inbuf.deinit(a);
        self.objects.deinit(a);
        var pit = self.pools.valueIterator();
        while (pit.next()) |p| p.deinit(a);
        self.pools.deinit(a);
        var opit = self.orphan_pools.valueIterator();
        while (opit.next()) |p| p.deinit(a);
        self.orphan_pools.deinit(a);
        self.vscratch.deinit(a);
        self.buffers.deinit(a);
        self.dmabuf_params.deinit(a);
        var sit = self.surfaces.valueIterator();
        while (sit.next()) |s| s.freeOwned(a);
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
        self.data_control_devices.deinit(a);
        self.pointers.deinit(a);
        self.keyboards.deinit(a);
        self.rel_pointers.deinit(a);
        self.constraints.deinit(a);
        self.text_inputs.deinit(a);
        self.primary_devices.deinit(a);
        self.source_actions.deinit(a);
        self.viewport_map.deinit(a);
        self.fs_map.deinit(a);
        self.host_drag.free(a);
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
        if (self.drag.active) return self.dragEnter(sid, x, y);
        if (self.pointer_focus == sid) return;
        try self.pointerLeave();
        self.pointer_focus = sid;
        self.last_px = x;
        self.last_py = y;
        const serial = self.nextSerial();
        for (self.pointers.items) |p| {
            var buf: [32]u8 = undefined;
            var b = wire.Builder.init(&buf, p, 0); // enter
            b.putUint(serial);
            b.putObject(sid);
            b.putFixed(wire.fixedFromF64(x));
            b.putFixed(wire.fixedFromF64(y));
            try self.send(try b.finish());
            try self.pointerFrame(p);
        }
        try self.activateConstraints(sid);
    }

    pub fn pointerLeave(self: *Compositor) Error!void {
        if (self.drag.active) return self.dragLeave();
        if (self.pointer_focus == 0) return;
        try self.deactivateConstraints(self.pointer_focus);
        const serial = self.nextSerial();
        for (self.pointers.items) |p| {
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, p, 1); // leave
            b.putUint(serial);
            b.putObject(self.pointer_focus);
            try self.send(try b.finish());
            try self.pointerFrame(p);
        }
        self.pointer_focus = 0;
    }

    pub fn pointerMotion(self: *Compositor, x: f64, y: f64) Error!void {
        if (self.drag.active) return self.dragMotion(x, y);
        if (self.pointer_focus == 0) return;
        const dx = x - self.last_px;
        const dy = y - self.last_py;
        self.last_px = x;
        self.last_py = y;
        // An active lock suppresses absolute motion (the pointer is
        // pinned); relative_motion keeps flowing for mouse-look.
        const locked = self.hasActiveLock(self.pointer_focus);
        for (self.pointers.items) |p| {
            if (!locked) {
                var buf: [24]u8 = undefined;
                var b = wire.Builder.init(&buf, p, 2); // motion
                b.putUint(self.now_ms);
                b.putFixed(wire.fixedFromF64(x));
                b.putFixed(wire.fixedFromF64(y));
                try self.send(try b.finish());
            }
            const had_rel = try self.relativeMotion(p, dx, dy);
            if (!locked or had_rel) try self.pointerFrame(p);
        }
    }

    /// `button` is an evdev code (BTN_LEFT 0x110 …).
    pub fn pointerButton(self: *Compositor, button: u32, pressed: bool) Error!void {
        if (pressed) {
            self.pressed_button = button;
        } else if (self.pressed_button == button) {
            self.pressed_button = 0;
        }
        if (self.drag.active) {
            if (!pressed) try self.dragDrop();
            return; // drag swallows all button events
        }
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
            try self.pointerFrame(p);
        }
    }

    /// `axis`: 0 vertical, 1 horizontal. `value` in surface px.
    /// `value120`: high-resolution wheel amount (±120 per detent),
    /// 0 for smooth/finger scroll.
    pub fn pointerAxis(self: *Compositor, axis: u32, value: f64, value120: i32) Error!void {
        if (self.pointer_focus == 0 or self.drag.active) return;
        for (self.pointers.items) |p| {
            if (value120 != 0) {
                if (self.seat_version >= 8) {
                    var vbuf: [16]u8 = undefined;
                    var vb = wire.Builder.init(&vbuf, p, 9); // axis_value120
                    vb.putUint(axis);
                    vb.putInt(value120);
                    try self.send(try vb.finish());
                } else if (self.seat_version >= 5) {
                    var dbuf: [16]u8 = undefined;
                    var db = wire.Builder.init(&dbuf, p, 8); // axis_discrete
                    db.putUint(axis);
                    db.putInt(@divTrunc(value120, 120));
                    try self.send(try db.finish());
                }
            }
            var buf: [24]u8 = undefined;
            var b = wire.Builder.init(&buf, p, 4); // axis
            b.putUint(self.now_ms);
            b.putUint(axis);
            b.putFixed(wire.fixedFromF64(value));
            try self.send(try b.finish());
            try self.pointerFrame(p);
        }
    }

    /// v5-bound clients buffer pointer events until the frame that
    /// closes the group — skipping it means input arrives never.
    fn pointerFrame(self: *Compositor, p: u32) Error!void {
        if (self.seat_version < 5) return;
        var buf: [16]u8 = undefined;
        var b = wire.Builder.init(&buf, p, 5); // frame
        try self.send(try b.finish());
    }

    /// relative_motion toward the rel-pointer objects shadowing `p`.
    /// Returns true if any event went out (the caller frames it).
    fn relativeMotion(self: *Compositor, p: u32, dx: f64, dy: f64) Error!bool {
        var sent = false;
        const utime: u64 = @as(u64, self.now_ms) * 1000;
        for (self.rel_pointers.items) |rp| {
            if (rp.pointer != p) continue;
            var buf: [40]u8 = undefined;
            var b = wire.Builder.init(&buf, rp.id, 0); // relative_motion
            b.putUint(@truncate(utime >> 32));
            b.putUint(@truncate(utime));
            b.putFixed(wire.fixedFromF64(dx));
            b.putFixed(wire.fixedFromF64(dy));
            b.putFixed(wire.fixedFromF64(dx)); // unaccelerated = same
            b.putFixed(wire.fixedFromF64(dy));
            try self.send(try b.finish());
            sent = true;
        }
        return sent;
    }

    fn hasActiveLock(self: *Compositor, sid: u32) bool {
        var it = self.constraints.valueIterator();
        while (it.next()) |con| {
            if (con.sid == sid and con.kind == 0 and con.active) return true;
        }
        return false;
    }

    /// Pointer focus landed on `sid`: activate its constraints.
    fn activateConstraints(self: *Compositor, sid: u32) Error!void {
        var it = self.constraints.iterator();
        while (it.next()) |e| {
            const con = e.value_ptr;
            if (con.sid != sid or con.active) continue;
            con.active = true;
            var buf: [8]u8 = undefined;
            var b = wire.Builder.init(&buf, e.key_ptr.*, 0); // locked / confined
            try self.send(try b.finish());
            if (con.kind == 0) {
                if (self.view.pointer_locked) |cb| cb(self.view.ctx, sid, true);
            }
        }
    }

    /// Pointer focus left `sid`: deactivate; oneshot constraints
    /// become defunct (removed from the map, object id stays alive
    /// until the client destroys it).
    fn deactivateConstraints(self: *Compositor, sid: u32) Error!void {
        var defunct: [8]u32 = undefined;
        var n_defunct: usize = 0;
        var it = self.constraints.iterator();
        while (it.next()) |e| {
            const con = e.value_ptr;
            if (con.sid != sid or !con.active) continue;
            con.active = false;
            var buf: [8]u8 = undefined;
            var b = wire.Builder.init(&buf, e.key_ptr.*, 1); // unlocked / unconfined
            try self.send(try b.finish());
            if (con.kind == 0) {
                if (self.view.pointer_locked) |cb| cb(self.view.ctx, sid, false);
            }
            if (con.lifetime == 1 and n_defunct < defunct.len) {
                defunct[n_defunct] = e.key_ptr.*;
                n_defunct += 1;
            }
        }
        for (defunct[0..n_defunct]) |id| _ = self.constraints.remove(id);
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
        try self.textInputFocus(sid, true);
    }

    pub fn keyboardLeave(self: *Compositor) Error!void {
        if (self.keyboard_focus == 0) return;
        try self.textInputFocus(self.keyboard_focus, false);
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

    /// zwp_text_input_v3 enter/leave rides keyboard focus.
    fn textInputFocus(self: *Compositor, sid: u32, entered: bool) Error!void {
        var it = self.text_inputs.keyIterator();
        while (it.next()) |id| {
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, id.*, if (entered) @as(u16, 0) else 1);
            b.putObject(sid);
            try self.send(try b.finish());
        }
    }

    /// View → client: IME-committed text toward every enabled text
    /// input (there is one seat; focused apps enable exactly one).
    pub fn commitString(self: *Compositor, text: []const u8) Error!void {
        if (self.keyboard_focus == 0) return;
        var it = self.text_inputs.iterator();
        while (it.next()) |e| {
            if (!e.value_ptr.enabled) continue;
            var buf: [4096]u8 = undefined;
            var b = wire.Builder.init(&buf, e.key_ptr.*, 3); // commit_string
            b.putString(text);
            try self.send(try b.finish());
            var dbuf: [16]u8 = undefined;
            var db = wire.Builder.init(&dbuf, e.key_ptr.*, 5); // done
            db.putUint(e.value_ptr.serial);
            try self.send(try db.finish());
        }
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
    /// to every bound data device (both wl_data_device and the
    /// surface-less wlr-data-control devices).
    pub fn offerSelection(self: *Compositor, mime: []const u8) Error!void {
        for (self.data_devices.items) |dev| try self.offerToDevice(dev, mime, false);
        for (self.data_control_devices.items) |dev| try self.offerToDevice(dev, mime, true);
    }

    fn sendStringEvent(self: *Compositor, object: u32, opcode: u16, value: ?[]const u8) Error!void {
        const len = if (value) |v| v.len else 0;
        const cap = wire.header_size + 4 + ((len + 1 + 3) & ~@as(usize, 3));
        if (cap > 0xffff) return Error.Protocol;
        const buf = try self.allocator.alloc(u8, cap);
        defer self.allocator.free(buf);
        var b = wire.Builder.init(buf, object, opcode);
        b.putString(value);
        try self.send(try b.finish());
    }

    /// Emit data_offer → offer(mime) → selection(offer) toward one
    /// device. The data_offer/offer opcodes match across the two
    /// device families; only `selection` differs (wl_data_device op 5
    /// vs zwlr_data_control_device_v1 op 1), as does the offer's
    /// interface type so the client's later receive() dispatches.
    fn offerToDevice(self: *Compositor, dev: u32, mime: []const u8, control: bool) Error!void {
        const id = self.next_server_id;
        self.next_server_id += 1;
        try self.objects.put(self.allocator, id, if (control)
            &protocol.zwlr_data_control_offer_v1
        else
            &protocol.wl_data_offer);
        var buf: [16]u8 = undefined;
        var b = wire.Builder.init(&buf, dev, 0); // data_offer(new_id)
        b.putNewId(id);
        try self.send(try b.finish());
        try self.sendStringEvent(id, 0, mime); // offer(mime)
        var sbuf: [16]u8 = undefined;
        var bs = wire.Builder.init(&sbuf, dev, if (control) 1 else 5); // selection(offer)
        bs.putObject(id);
        try self.send(try bs.finish());
    }

    /// View → client: announce the HOST primary selection so the
    /// app can middle-click paste.
    pub fn offerPrimary(self: *Compositor, mime: []const u8) Error!void {
        for (self.primary_devices.items) |dev| {
            const id = self.next_server_id;
            self.next_server_id += 1;
            try self.objects.put(self.allocator, id, &protocol.zwp_primary_selection_offer_v1);
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, dev, 0); // data_offer(new_id)
            b.putNewId(id);
            try self.send(try b.finish());
            try self.sendStringEvent(id, 0, mime); // offer(mime)
            var sbuf: [16]u8 = undefined;
            var bs = wire.Builder.init(&sbuf, dev, 1); // selection(offer)
            bs.putObject(id);
            try self.send(try bs.finish());
        }
    }

    /// View → client: primary-paste bytes for the oldest outstanding
    /// primary_read (separate daemon fd FIFO from clipboard pastes).
    pub fn sendPrimaryData(self: *Compositor, bytes: []const u8) Error!void {
        try pipe.appendUnit(&self.out, self.allocator, .primary_data, bytes);
    }

    // ── within-app dnd (wl_data_device.start_drag) ──────────────
    // Both drag ends are the same client, so the transfer is local:
    // offer.receive's fd feeds the source's send (dnd_send unit —
    // the daemon pairs the held fd, like the clipboard path).

    fn dragEnter(self: *Compositor, sid: u32, x: f64, y: f64) Error!void {
        if (self.drag.focus == sid) return;
        try self.dragLeave();
        self.drag.focus = sid;
        const serial = self.nextSerial();
        for (self.data_devices.items) |dev| {
            var offer_id: u32 = 0;
            if (self.drag.source != 0) {
                offer_id = self.next_server_id;
                self.next_server_id += 1;
                try self.objects.put(self.allocator, offer_id, &protocol.wl_data_offer);
                var buf: [16]u8 = undefined;
                var b = wire.Builder.init(&buf, dev, 0); // data_offer(new_id)
                b.putNewId(offer_id);
                try self.send(try b.finish());
                if (self.data_sources.get(self.drag.source)) |mimes| {
                    for (mimes.items) |m| {
                        try self.sendStringEvent(offer_id, 0, m); // offer(mime)
                    }
                }
                if (self.ddm_version >= 3) {
                    const acts = self.source_actions.get(self.drag.source) orelse 0;
                    var abuf: [16]u8 = undefined;
                    var ab = wire.Builder.init(&abuf, offer_id, 1); // source_actions
                    ab.putUint(acts);
                    try self.send(try ab.finish());
                }
                self.drag.offer = offer_id;
            }
            var ebuf: [40]u8 = undefined;
            var eb = wire.Builder.init(&ebuf, dev, 1); // enter
            eb.putUint(serial);
            eb.putObject(sid);
            eb.putFixed(wire.fixedFromF64(x));
            eb.putFixed(wire.fixedFromF64(y));
            eb.putObject(offer_id);
            try self.send(try eb.finish());
        }
    }

    fn dragLeave(self: *Compositor) Error!void {
        if (self.drag.focus == 0) return;
        for (self.data_devices.items) |dev| {
            var buf: [8]u8 = undefined;
            var b = wire.Builder.init(&buf, dev, 2); // leave
            try self.send(try b.finish());
        }
        self.drag.focus = 0;
        self.drag.accepted = false;
        self.drag.action = 0;
        // The offer is defunct once left; the client destroys it.
        self.drag.offer = 0;
    }

    fn dragMotion(self: *Compositor, x: f64, y: f64) Error!void {
        self.last_px = x;
        self.last_py = y;
        if (self.drag.focus == 0) return;
        for (self.data_devices.items) |dev| {
            var buf: [24]u8 = undefined;
            var b = wire.Builder.init(&buf, dev, 3); // motion
            b.putUint(self.now_ms);
            b.putFixed(wire.fixedFromF64(x));
            b.putFixed(wire.fixedFromF64(y));
            try self.send(try b.finish());
        }
    }

    /// The drag button was released: drop if the target accepted
    /// (and, at ddm v3, an action was negotiated), else cancel.
    fn dragDrop(self: *Compositor) Error!void {
        const can_drop = self.drag.focus != 0 and self.drag.accepted and
            (self.ddm_version < 3 or self.drag.action != 0);
        if (can_drop) {
            for (self.data_devices.items) |dev| {
                var buf: [8]u8 = undefined;
                var b = wire.Builder.init(&buf, dev, 4); // drop
                try self.send(try b.finish());
            }
            if (self.drag.source != 0 and self.ddm_version >= 3) {
                var buf: [8]u8 = undefined;
                var b = wire.Builder.init(&buf, self.drag.source, 3); // dnd_drop_performed
                try self.send(try b.finish());
            }
            self.drag.active = false;
            self.drag.dropped = true; // receive/finish still route
        } else {
            try self.dragLeave();
            if (self.drag.source != 0) {
                var buf: [8]u8 = undefined;
                var b = wire.Builder.init(&buf, self.drag.source, 2); // cancelled
                try self.send(try b.finish());
            }
            self.drag = .{};
        }
    }

    /// View → client: the user dropped host data onto surface `sid`
    /// at surface-local (x, y). Synthesizes a server-sourced dnd:
    /// offer → enter → action → motion → drop in one burst (the
    /// client accepts during its enter processing and calls receive
    /// after drop — answered from `host_drag.data` via drop_data).
    pub fn hostDrop(self: *Compositor, sid: u32, x: f64, y: f64, mime: []const u8, data: []const u8) Error!void {
        if (self.drag.active or self.host_drag.offer != 0) return;
        if (!self.surfaces.contains(sid)) return;
        if (self.data_devices.items.len == 0) return;
        const mime_copy = try self.allocator.dupe(u8, mime);
        errdefer self.allocator.free(mime_copy);
        const data_copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(data_copy);

        const serial = self.nextSerial();
        var offer_id: u32 = 0;
        for (self.data_devices.items) |dev| {
            offer_id = self.next_server_id;
            self.next_server_id += 1;
            try self.objects.put(self.allocator, offer_id, &protocol.wl_data_offer);
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, dev, 0); // data_offer(new_id)
            b.putNewId(offer_id);
            try self.send(try b.finish());
            try self.sendStringEvent(offer_id, 0, mime); // offer(mime)
            if (self.ddm_version >= 3) {
                var abuf: [16]u8 = undefined;
                var ab = wire.Builder.init(&abuf, offer_id, 1); // source_actions
                ab.putUint(1); // copy
                try self.send(try ab.finish());
            }
            var ebuf: [40]u8 = undefined;
            var eb = wire.Builder.init(&ebuf, dev, 1); // enter
            eb.putUint(serial);
            eb.putObject(sid);
            eb.putFixed(wire.fixedFromF64(x));
            eb.putFixed(wire.fixedFromF64(y));
            eb.putObject(offer_id);
            try self.send(try eb.finish());
            if (self.ddm_version >= 3) {
                var cbuf: [16]u8 = undefined;
                var cb = wire.Builder.init(&cbuf, offer_id, 2); // action(copy)
                cb.putUint(1);
                try self.send(try cb.finish());
            }
            var obuf: [24]u8 = undefined;
            var ob = wire.Builder.init(&obuf, dev, 3); // motion
            ob.putUint(self.now_ms);
            ob.putFixed(wire.fixedFromF64(x));
            ob.putFixed(wire.fixedFromF64(y));
            try self.send(try ob.finish());
            var dbuf: [8]u8 = undefined;
            var db = wire.Builder.init(&dbuf, dev, 4); // drop
            try self.send(try db.finish());
        }
        self.host_drag = .{ .offer = offer_id, .mime = mime_copy, .data = data_copy };
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
                    else => {
                        const iname = if (self.objects.get(hdr.object)) |i| i.name else "?";
                        std.debug.print("wlhost: protocol error on {s}#{d} opcode {d}\n", .{ iname, hdr.object, hdr.opcode });
                        try self.fatal(hdr.object, "protocol error");
                    },
                };
            },
            .pool_create, .pool_resize => {
                // In the live stream the wl_msg handler already
                // installed the incarnation (this unit trails it);
                // only the replay path (fresh replica, no wl_msg)
                // creates pools here — give those a serial too.
                const meta = pipe.decodePoolMeta(payload) orelse return Error.Protocol;
                const slot = try self.pools.getOrPut(self.allocator, meta.pool);
                if (!slot.found_existing) {
                    self.pool_serial_ctr += 1;
                    slot.value_ptr.* = .{ .serial = self.pool_serial_ctr };
                }
                try self.resizePoolBytes(slot.value_ptr, meta.size);
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
            .pool_serial => {
                // Adopt the daemon's incarnation serial (trails every
                // pool_create): serial-addressed units and state_sync
                // buffer serials then resolve on replicas attached
                // mid-session, whose self-counted serials diverge.
                const ps = pipe.decodePoolSerial(payload) orelse return Error.Protocol;
                if (self.pools.getPtr(ps.pool)) |p| p.serial = ps.serial;
                if (ps.serial > self.pool_serial_ctr) self.pool_serial_ctr = ps.serial;
            },
            .pool_orphan => {
                // Replayed displaced incarnation; pool_update_s units
                // fill it. Refcounts are recomputed by restoreState.
                const po = pipe.decodePoolOrphan(payload) orelse return Error.Protocol;
                const slot = try self.orphan_pools.getOrPut(self.allocator, po.serial);
                if (slot.found_existing) slot.value_ptr.deinit(self.allocator);
                slot.value_ptr.* = .{ .serial = po.serial };
                try self.resizePoolBytes(slot.value_ptr, po.size);
                if (po.serial > self.pool_serial_ctr) self.pool_serial_ctr = po.serial;
            },
            .pool_update_s => {
                // Serial-addressed pixels: reach a displaced pool the
                // id can't name anymore (a client still committing
                // buffers from a recycled pool's old incarnation).
                const upd = pipe.decodePoolUpdateS(payload) orelse return Error.Protocol;
                // A serial we no longer retain (freed on the last
                // buffer release) is stale data, not a protocol fault.
                const pool = self.poolBySerial(upd.serial) orelse return;
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
                // Per-pool decoder, recreated on a dimension or codec change.
                if (pool.vdec == null or pool.vdec_w != tile.w or pool.vdec_h != tile.h or pool.vdec_codec != tile.codec) {
                    if (pool.vdec) |*d| d.deinit();
                    pool.vdec = vcodec.Decoder.initAvcodec(self.allocator, tile.w, tile.h, tile.codec) catch return Error.Protocol;
                    pool.vdec_w = tile.w;
                    pool.vdec_h = tile.h;
                    pool.vdec_codec = tile.codec;
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
                // Daemon reclaim notice. Respect the local refcount:
                // if buffers still reference this incarnation (the
                // daemon and replica should agree, but a stale notice
                // must not strand them), defer to the last release.
                if (payload.len >= 4) {
                    const id = std.mem.readInt(u32, payload[0..4], .little);
                    if (self.pools.getPtr(id)) |p| {
                        if (p.buffers == 0) {
                            var pool = self.pools.fetchRemove(id).?.value;
                            pool.deinit(self.allocator);
                        } else {
                            p.destroyed = true;
                        }
                    }
                }
            },
            .clip_data => {
                // Fetched app clipboard content (answer to clip_send).
                if (self.view.clipboard_data) |cb| cb(self.view.ctx, payload);
            },
            .state_sync => try self.restoreState(payload),
            .toplevel_icon => {
                if (payload.len >= 5) {
                    const sid = std.mem.readInt(u32, payload[0..4], .little);
                    const kind = payload[4];
                    if (self.view.toplevel_icon) |cb| cb(self.view.ctx, sid, kind, payload[5..]);
                }
            },
            else => {}, // forward compat
        }
    }

    // ── request dispatch ────────────────────────────────────────

    fn request(self: *Compositor, hdr: wire.Header, body: []const u8) Error!void {
        const iface = self.objects.get(hdr.object) orelse {
            // Replicas never learn the brain's server-created objects
            // (clipboard data offers): requests on them are skipped,
            // not fatal. The authoritative brain stays strict.
            if (self.lenient) return;
            return Error.Protocol;
        };
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
                    // dmabuf is announce-gated (SKETERM_MUX_DMABUF):
                    // drivers that refuse CPU mmap can't degrade
                    // per-buffer under create_immed, so the safe
                    // default keeps clients on shm. Binds stay
                    // table-validated either way (replicas re-parse
                    // them; their announcements are discarded).
                    if (g.iface == &protocol.zwp_linux_dmabuf_v1 and !self.advertise_dmabuf)
                        continue;
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
            if (!std.mem.eql(u8, g.iface.name, iname) or ver == 0 or ver > g.version) {
                std.debug.print("wlhost: bad bind {s} v{d} (advertised {s} v{d})\n", .{ iname, ver, g.iface.name, g.version });
                return Error.Protocol;
            }
            try self.register(id, g.iface);
            if (g.iface == &protocol.wl_seat) self.seat_version = ver;
            if (g.iface == &protocol.wl_compositor) self.compositor_version = ver;
            if (g.iface == &protocol.xdg_wm_base) self.wm_base_version = ver;
            if (g.iface == &protocol.wl_data_device_manager) self.ddm_version = ver;
            if (g.iface == &protocol.wl_output) self.output_id = id;
            if (g.iface == &protocol.zxdg_output_manager_v1) self.xdg_output_ver = ver;
            try self.boundGlobal(id, g.iface, ver);
        } else if (iface == &protocol.wl_compositor) switch (hdr.opcode) {
            0 => { // create_surface
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.wl_surface);
                try self.surfaces.put(self.allocator, id, .{});
                if (self.compositor_version >= 6) {
                    var buf: [16]u8 = undefined;
                    var b = wire.Builder.init(&buf, id, 2); // preferred_buffer_scale
                    b.putInt(self.output_scale);
                    try self.send(try b.finish());
                    var tbuf: [16]u8 = undefined;
                    var tb = wire.Builder.init(&tbuf, id, 3); // preferred_buffer_transform
                    tb.putUint(0); // normal
                    try self.send(try tb.finish());
                }
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
                // Recycled id: old buffers keep resolving to the
                // displaced incarnation via their serial.
                _ = try self.freshPool(id, @intCast(size));
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
                var serial: u64 = 0;
                if (self.pools.getPtr(hdr.object)) |p| {
                    p.buffers += 1;
                    serial = p.serial;
                }
                try self.buffers.put(self.allocator, id, .{
                    .pool = hdr.object,
                    .offset = offset,
                    .width = width,
                    .height = height,
                    .stride = stride,
                    .format = format,
                    .pool_serial = serial,
                });
            },
            1 => { // destroy — bytes reclaim once no buffer references them
                if (self.pools.getPtr(hdr.object)) |p| {
                    if (p.buffers == 0) {
                        var pool = self.pools.fetchRemove(hdr.object).?.value;
                        pool.deinit(self.allocator);
                    } else {
                        p.destroyed = true;
                    }
                }
                try self.destroyObject(hdr.object);
            },
            2 => {}, // resize — side-band already grew the mirror
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_buffer) {
            // destroy — a dmabuf buffer also owns its synthetic pool
            // (pool id == buffer id); an shm buffer releases its pool
            // reference and reclaims a destroyed pool's bytes when it
            // was the last one. Both resolve by incarnation serial so
            // a recycled pool id can't cross refcounts.
            if (self.buffers.fetchRemove(hdr.object)) |kv| {
                if (kv.value.pool == hdr.object) {
                    if (self.pools.getPtr(hdr.object)) |p| {
                        if (p.serial == kv.value.pool_serial) {
                            var pool = self.pools.fetchRemove(hdr.object).?.value;
                            pool.deinit(self.allocator);
                        } else {
                            self.releaseBufferRef(kv.value);
                        }
                    } else {
                        self.releaseBufferRef(kv.value);
                    }
                } else {
                    self.releaseBufferRef(kv.value);
                }
            }
            try self.destroyObject(hdr.object);
        } else if (iface == &protocol.zwp_linux_dmabuf_v1) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object),
            1 => { // create_params
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.zwp_linux_buffer_params_v1);
                try self.dmabuf_params.put(self.allocator, id, .{});
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.zwp_linux_buffer_params_v1) switch (hdr.opcode) {
            0 => { // destroy
                _ = self.dmabuf_params.remove(hdr.object);
                try self.destroyObject(hdr.object);
            },
            1 => { // add(fd, plane_idx, offset, stride, mod_hi, mod_lo)
                _ = (try it.next()).?; // fd placeholder
                const plane = (try it.next()).?.uint;
                const offset = (try it.next()).?.uint;
                const stride = (try it.next()).?.uint;
                const mod_hi = (try it.next()).?.uint;
                const mod_lo = (try it.next()).?.uint;
                const p = self.dmabuf_params.getPtr(hdr.object) orelse return Error.Protocol;
                if (plane == 0) {
                    p.* = .{
                        .offset = offset,
                        .stride = stride,
                        .ok = (@as(u64, mod_hi) << 32 | mod_lo) == protocol.DRM_FORMAT_MOD_LINEAR,
                    };
                } else p.ok = false;
            },
            2 => { // create (non-immed) — declined: failed → shm fallback
                var buf: [8]u8 = undefined;
                var b = wire.Builder.init(&buf, hdr.object, 1); // failed
                try self.send(try b.finish());
            },
            3 => { // create_immed(new_id, w, h, format, flags)
                const id = (try it.next()).?.new_id;
                const width = (try it.next()).?.int;
                const height = (try it.next()).?.int;
                const format = (try it.next()).?.uint;
                const flags = (try it.next()).?.uint;
                const p = self.dmabuf_params.get(hdr.object) orelse return Error.Protocol;
                const shm_format: u32 = switch (format) {
                    protocol.DRM_FORMAT_ARGB8888 => 0,
                    protocol.DRM_FORMAT_XRGB8888 => 1,
                    else => return Error.Protocol,
                };
                if (!p.ok or flags != 0 or width <= 0 or height <= 0 or
                    @as(u64, p.stride) < @as(u64, @intCast(width)) * 4)
                    return Error.Protocol;
                try self.register(id, &protocol.wl_buffer);
                // Synthetic pool, laid out exactly like the mapped
                // dmabuf so the daemon's pool_update offsets line up.
                const pool_size = @as(usize, p.offset) + @as(usize, p.stride) * @as(usize, @intCast(height));
                const pool = try self.freshPool(id, pool_size);
                pool.buffers = 1;
                try self.buffers.put(self.allocator, id, .{
                    .pool = id,
                    .offset = @intCast(p.offset),
                    .width = width,
                    .height = height,
                    .stride = @intCast(p.stride),
                    .format = shm_format,
                    .pool_serial = pool.serial,
                });
            },
            else => return Error.Protocol,
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
                try payload.appendSlice(self.allocator, self.keymap);
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
            3 => try self.destroyObject(hdr.object), // release (v5)
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
        } else if (iface == &protocol.zxdg_output_manager_v1) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object),
            1 => { // get_xdg_output(id, output)
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.zxdg_output_v1);
                try self.sendXdgOutputState(id);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.zxdg_output_v1) {
            // destroy — the only request.
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
            1 => { // get_viewport(id, surface)
                const id = (try it.next()).?.new_id;
                const sid = (try it.next()).?.object;
                try self.register(id, &protocol.wp_viewport);
                try self.viewport_map.put(self.allocator, id, sid);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wp_viewport) switch (hdr.opcode) {
            0 => { // destroy — the surface reverts to buffer-derived size
                if (self.viewport_map.fetchRemove(hdr.object)) |kv| {
                    if (self.surfaces.getPtr(kv.value)) |surf| {
                        surf.vp_w = 0;
                        surf.vp_h = 0;
                    }
                }
                try self.destroyObject(hdr.object);
            },
            1 => {}, // set_source — full-buffer scope, accepted
            2 => { // set_destination(w, h) — the surface's LOGICAL size
                const vw = (try it.next()).?.int;
                const vh = (try it.next()).?.int;
                const sid = self.viewport_map.get(hdr.object) orelse return Error.Protocol;
                if (self.surfaces.getPtr(sid)) |surf| {
                    // -1,-1 unsets per spec.
                    surf.vp_w = if (vw > 0) vw else 0;
                    surf.vp_h = if (vh > 0) vh else 0;
                }
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wp_fractional_scale_manager_v1) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object),
            1 => { // get_fractional_scale(id, surface)
                const id = (try it.next()).?.new_id;
                const sid = (try it.next()).?.object;
                try self.register(id, &protocol.wp_fractional_scale_v1);
                try self.fs_map.put(self.allocator, id, sid);
                var buf: [16]u8 = undefined;
                var b = wire.Builder.init(&buf, id, 0); // preferred_scale
                b.putUint(self.effScale120());
                try self.send(try b.finish());
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wp_fractional_scale_v1) switch (hdr.opcode) {
            0 => { // destroy
                _ = self.fs_map.remove(hdr.object);
                try self.destroyObject(hdr.object);
            },
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
                    if (self.surfaces.getPtr(sid)) |surf| surf.deco = @intCast(mode);
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
                _ = self.source_actions.remove(hdr.object);
                if (self.drag.source == hdr.object) {
                    if (self.drag.active) try self.dragLeave();
                    self.drag = .{};
                }
                try self.destroyObject(hdr.object);
            },
            2 => { // set_actions(actions) — stored for dnd negotiation
                const acts = (try it.next()).?.uint;
                try self.source_actions.put(self.allocator, hdr.object, acts);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_data_device) switch (hdr.opcode) {
            0 => { // start_drag(?source, origin, ?icon, serial)
                const source = (try it.next()).?.object;
                const origin = (try it.next()).?.object;
                if (self.drag.active or !self.surfaces.contains(origin)) return;
                // No held button = nothing to release; refuse inert.
                if (self.pressed_button == 0) {
                    if (source != 0) {
                        var buf: [8]u8 = undefined;
                        var b = wire.Builder.init(&buf, source, 2); // cancelled
                        try self.send(try b.finish());
                    }
                    return;
                }
                // The pointer leaves the origin surface for the drag.
                const px = self.last_px;
                const py = self.last_py;
                try self.pointerLeave();
                self.drag = .{ .active = true, .source = source, .origin = origin };
                try self.dragEnter(origin, px, py);
            },
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
            0 => { // accept(serial, ?mime) — dnd target feedback
                if (hdr.object == self.drag.offer and self.drag.offer != 0) {
                    _ = (try it.next()).?; // serial
                    const mime = (try it.next()).?.string;
                    self.drag.accepted = mime != null;
                    if (self.drag.source != 0) {
                        const mime_len = if (mime) |m| m.len else 0;
                        const cap = wire.header_size + 4 + ((mime_len + 1 + 3) & ~@as(usize, 3));
                        if (cap > 0xffff) return Error.Protocol;
                        const buf = try self.allocator.alloc(u8, cap);
                        defer self.allocator.free(buf);
                        var b = wire.Builder.init(buf, self.drag.source, 0); // target
                        b.putString(mime);
                        try self.send(try b.finish());
                    }
                }
            },
            1 => { // receive(mime, fd) — host-drop offers answer from
                // the stored payload (drop_data); within-app dnd
                // offers pull from the SOURCE (dnd_send); selection
                // offers paste the HOST clipboard.
                const mime = (try it.next()).?.string orelse return Error.Protocol;
                if (hdr.object == self.host_drag.offer and self.host_drag.offer != 0) {
                    var payload: std.ArrayList(u8) = .empty;
                    defer payload.deinit(self.allocator);
                    var idb: [4]u8 = undefined;
                    std.mem.writeInt(u32, &idb, self.host_drag.offer, .little);
                    try payload.appendSlice(self.allocator, &idb);
                    try payload.appendSlice(self.allocator, self.host_drag.data);
                    try pipe.appendUnit(&self.out, self.allocator, .drop_data, payload.items);
                } else if (hdr.object == self.drag.offer and self.drag.source != 0) {
                    var payload: std.ArrayList(u8) = .empty;
                    defer payload.deinit(self.allocator);
                    var idb: [8]u8 = undefined;
                    std.mem.writeInt(u32, idb[0..4], self.drag.source, .little);
                    std.mem.writeInt(u32, idb[4..8], hdr.object, .little);
                    try payload.appendSlice(self.allocator, &idb);
                    try payload.appendSlice(self.allocator, mime);
                    try pipe.appendUnit(&self.out, self.allocator, .dnd_send, payload.items);
                } else if (self.view.clipboard_read) |cb| cb(self.view.ctx, mime);
            },
            2 => { // destroy
                if (hdr.object == self.host_drag.offer) self.host_drag.free(self.allocator);
                if (hdr.object == self.drag.offer) self.drag.offer = 0;
                if (self.drag.dropped and !self.drag.active) self.drag = .{};
                try self.destroyObject(hdr.object);
            },
            3 => { // finish — dnd transfer complete
                if (hdr.object == self.host_drag.offer) self.host_drag.free(self.allocator);
                if (hdr.object == self.drag.offer and self.drag.source != 0) {
                    var buf: [8]u8 = undefined;
                    var b = wire.Builder.init(&buf, self.drag.source, 4); // dnd_finished
                    try self.send(try b.finish());
                    self.drag = .{};
                }
            },
            4 => { // set_actions(actions, preferred) — negotiate
                if (hdr.object == self.drag.offer and self.drag.offer != 0) {
                    const acts = (try it.next()).?.uint;
                    const preferred = (try it.next()).?.uint;
                    const src = self.source_actions.get(self.drag.source) orelse 0;
                    const overlap = acts & src;
                    const chosen: u32 = if (preferred & overlap != 0)
                        preferred
                    else if (overlap & 1 != 0)
                        1 // copy
                    else if (overlap & 2 != 0)
                        2 // move
                    else
                        0;
                    self.drag.action = chosen;
                    var obuf: [16]u8 = undefined;
                    var ob = wire.Builder.init(&obuf, hdr.object, 2); // action
                    ob.putUint(chosen);
                    try self.send(try ob.finish());
                    if (self.drag.source != 0) {
                        var sbuf: [16]u8 = undefined;
                        var sb = wire.Builder.init(&sbuf, self.drag.source, 5); // action
                        sb.putUint(chosen);
                        try self.send(try sb.finish());
                    }
                }
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.zwlr_data_control_manager_v1) switch (hdr.opcode) {
            0 => { // create_data_source
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.zwlr_data_control_source_v1);
                try self.data_sources.put(self.allocator, id, .empty);
            },
            1 => { // get_data_device(id, seat)
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.zwlr_data_control_device_v1);
                try self.data_control_devices.append(self.allocator, id);
                // The protocol requires advertising the current
                // selection right after the device is created — a
                // data-control client (wl-paste) has no focus event to
                // trigger offerSelection, so send it now.
                try self.offerToDevice(id, "text/plain;charset=utf-8", true);
            },
            2 => try self.destroyObject(hdr.object), // destroy
            else => return Error.Protocol,
        } else if (iface == &protocol.zwlr_data_control_source_v1) switch (hdr.opcode) {
            0 => { // offer(mime) — same store as wl_data_source
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
            else => return Error.Protocol,
        } else if (iface == &protocol.zwlr_data_control_device_v1) switch (hdr.opcode) {
            0 => { // set_selection(?source) — no serial, unlike wl
                const source = (try it.next()).?.object;
                if (source != 0) {
                    if (self.bestTextMime(source)) |mime| {
                        if (self.view.clipboard_offer) |cb| cb(self.view.ctx, source, mime);
                    }
                }
            },
            1 => { // destroy
                removeId(&self.data_control_devices, hdr.object);
                try self.destroyObject(hdr.object);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.zwlr_data_control_offer_v1) switch (hdr.opcode) {
            0 => { // receive(mime, fd) — same paste path as wl_data_offer
                const mime = (try it.next()).?.string orelse return Error.Protocol;
                if (self.view.clipboard_read) |cb| cb(self.view.ctx, mime);
            },
            1 => try self.destroyObject(hdr.object), // destroy
            else => return Error.Protocol,
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
                2 => { // reposition(positioner, token)
                    const pos_id = (try it.next()).?.object;
                    const token = (try it.next()).?.uint;
                    const pos = self.positioners.get(pos_id) orelse return Error.Protocol;
                    const surf = self.surfaces.getPtr(sid) orelse return Error.Protocol;
                    const at = pos.place();
                    surf.px = at[0];
                    surf.py = at[1];
                    surf.pw = pos.w;
                    surf.ph = pos.h;
                    var rbuf: [16]u8 = undefined;
                    var rb = wire.Builder.init(&rbuf, hdr.object, 2); // repositioned
                    rb.putUint(token);
                    try self.send(try rb.finish());
                    var cbuf: [32]u8 = undefined;
                    var cb = wire.Builder.init(&cbuf, hdr.object, 0); // configure
                    cb.putInt(surf.px);
                    cb.putInt(surf.py);
                    cb.putInt(surf.pw);
                    cb.putInt(surf.ph);
                    try self.send(try cb.finish());
                    var sbuf: [16]u8 = undefined;
                    var sb = wire.Builder.init(&sbuf, surf.xdg_surface, 0); // configure
                    sb.putUint(self.nextSerial());
                    try self.send(try sb.finish());
                    if (self.view.popup_moved) |vcb|
                        vcb(self.view.ctx, sid, surf.parent, at[0], at[1]);
                },
                else => return Error.Protocol,
            }
        } else if (iface == &protocol.xdg_surface) {
            try self.xdgSurfaceRequest(hdr, &it);
        } else if (iface == &protocol.xdg_toplevel) {
            try self.toplevelRequest(hdr, body, &it);
        } else if (iface == &protocol.zwp_primary_selection_device_manager_v1) switch (hdr.opcode) {
            0 => { // create_source
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.zwp_primary_selection_source_v1);
                try self.data_sources.put(self.allocator, id, .empty);
            },
            1 => { // get_device(id, seat)
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.zwp_primary_selection_device_v1);
                try self.primary_devices.append(self.allocator, id);
            },
            2 => try self.destroyObject(hdr.object), // destroy
            else => return Error.Protocol,
        } else if (iface == &protocol.zwp_primary_selection_source_v1) switch (hdr.opcode) {
            0 => { // offer(mime) — same store as wl_data_source
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
            else => return Error.Protocol,
        } else if (iface == &protocol.zwp_primary_selection_device_v1) switch (hdr.opcode) {
            0 => { // set_selection(?source, serial)
                const source = (try it.next()).?.object;
                if (source != 0) {
                    if (self.bestTextMime(source)) |mime| {
                        if (self.view.primary_offer) |cb| cb(self.view.ctx, source, mime);
                    }
                }
            },
            1 => { // destroy
                removeId(&self.primary_devices, hdr.object);
                try self.destroyObject(hdr.object);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.zwp_primary_selection_offer_v1) switch (hdr.opcode) {
            0 => { // receive(mime, fd) — host PRIMARY selection paste
                const mime = (try it.next()).?.string orelse return Error.Protocol;
                if (self.view.primary_read) |cb| cb(self.view.ctx, mime);
            },
            1 => try self.destroyObject(hdr.object), // destroy
            else => return Error.Protocol,
        } else if (iface == &protocol.zwp_relative_pointer_manager_v1) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object), // destroy
            1 => { // get_relative_pointer(id, pointer)
                const id = (try it.next()).?.new_id;
                const ptr = (try it.next()).?.object;
                try self.register(id, &protocol.zwp_relative_pointer_v1);
                try self.rel_pointers.append(self.allocator, .{ .id = id, .pointer = ptr });
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.zwp_relative_pointer_v1) switch (hdr.opcode) {
            0 => { // destroy
                for (self.rel_pointers.items, 0..) |rp, i| {
                    if (rp.id == hdr.object) {
                        _ = self.rel_pointers.swapRemove(i);
                        break;
                    }
                }
                try self.destroyObject(hdr.object);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.zwp_pointer_constraints_v1) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object), // destroy
            1, 2 => { // lock_pointer / confine_pointer(id, surface, pointer, ?region, lifetime)
                const id = (try it.next()).?.new_id;
                const sid = (try it.next()).?.object;
                _ = (try it.next()).?; // pointer
                _ = (try it.next()).?; // region — whole surface in scope
                const lifetime = (try it.next()).?.uint;
                const kind: u8 = if (hdr.opcode == 1) 0 else 1;
                try self.register(id, if (kind == 0)
                    &protocol.zwp_locked_pointer_v1
                else
                    &protocol.zwp_confined_pointer_v1);
                try self.constraints.put(self.allocator, id, .{
                    .sid = sid,
                    .kind = kind,
                    .lifetime = lifetime,
                });
                // Already hovering the surface: activate immediately.
                if (self.pointer_focus == sid) try self.activateConstraints(sid);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.zwp_locked_pointer_v1 or
            iface == &protocol.zwp_confined_pointer_v1)
        {
            switch (hdr.opcode) {
                0 => { // destroy
                    if (self.constraints.getPtr(hdr.object)) |con| {
                        if (con.active and con.kind == 0) {
                            if (self.view.pointer_locked) |cb| cb(self.view.ctx, con.sid, false);
                        }
                        _ = self.constraints.remove(hdr.object);
                    }
                    try self.destroyObject(hdr.object);
                },
                // set_cursor_position_hint / set_region: accepted,
                // unused (whole-surface constraints, host cursor).
                else => {},
            }
        } else if (iface == &protocol.zwp_text_input_manager_v3) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object), // destroy
            1 => { // get_text_input(id, seat)
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.zwp_text_input_v3);
                try self.text_inputs.put(self.allocator, id, .{});
                if (self.keyboard_focus != 0) {
                    var buf: [16]u8 = undefined;
                    var b = wire.Builder.init(&buf, id, 0); // enter
                    b.putObject(self.keyboard_focus);
                    try self.send(try b.finish());
                }
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.zwp_text_input_v3) {
            const ti = self.text_inputs.getPtr(hdr.object) orelse return Error.Protocol;
            switch (hdr.opcode) {
                0 => { // destroy
                    if (ti.enabled) {
                        if (self.view.text_input_active) |cb| cb(self.view.ctx, false);
                    }
                    _ = self.text_inputs.remove(hdr.object);
                    try self.destroyObject(hdr.object);
                },
                1 => ti.pending_enabled = true, // enable
                2 => ti.pending_enabled = false, // disable
                // surrounding text / change cause / content type /
                // cursor rectangle: accepted (no IM popup to place).
                3, 4, 5, 6 => {},
                7 => { // commit — latch double-buffered state
                    ti.serial +%= 1;
                    if (ti.enabled != ti.pending_enabled) {
                        ti.enabled = ti.pending_enabled;
                        if (self.view.text_input_active) |cb| cb(self.view.ctx, ti.enabled);
                    }
                },
                else => return Error.Protocol,
            }
        } else if (iface == &protocol.xdg_activation_v1) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object), // destroy
            1 => { // get_activation_token
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.xdg_activation_token_v1);
            },
            2 => { // activate(token, surface)
                _ = (try it.next()).?; // token — minted freely, not checked
                const sid = (try it.next()).?.object;
                if (self.surfaces.contains(sid)) {
                    if (self.view.toplevel_raise) |cb| cb(self.view.ctx, sid);
                }
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.xdg_activation_token_v1) switch (hdr.opcode) {
            0, 1, 2 => {}, // set_serial / set_app_id / set_surface
            3 => { // commit → done(token)
                var tok: [48]u8 = undefined;
                const s = std.fmt.bufPrint(&tok, "sketerm-{d}", .{self.nextSerial()}) catch
                    return Error.Protocol;
                var buf: [64]u8 = undefined;
                var b = wire.Builder.init(&buf, hdr.object, 0); // done
                b.putString(s);
                try self.send(try b.finish());
            },
            4 => try self.destroyObject(hdr.object), // destroy
            else => return Error.Protocol,
        } else if (iface == &protocol.wp_presentation) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object), // destroy
            1 => { // feedback(surface, id)
                const sid = (try it.next()).?.object;
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.wp_presentation_feedback);
                if (self.surfaces.getPtr(sid)) |surf| {
                    try surf.feedbacks.append(self.allocator, id);
                } else {
                    // Unknown surface: discard immediately.
                    var buf: [8]u8 = undefined;
                    var b = wire.Builder.init(&buf, id, 2); // discarded
                    try self.send(try b.finish());
                    try self.deleteId(id);
                }
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.zwp_idle_inhibit_manager_v1) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object), // destroy
            1 => { // create_inhibitor(id, surface) — tracked, inert
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.zwp_idle_inhibitor_v1);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.zwp_idle_inhibitor_v1) {
            try self.destroyObject(hdr.object); // destroy (only request)
        } else if (iface == &protocol.zwp_pointer_gestures_v1) switch (hdr.opcode) {
            0, 1, 3 => { // get_{swipe,pinch,hold}_gesture(id, pointer)
                const id = (try it.next()).?.new_id;
                try self.register(id, switch (hdr.opcode) {
                    0 => &protocol.zwp_pointer_gesture_swipe_v1,
                    1 => &protocol.zwp_pointer_gesture_pinch_v1,
                    else => &protocol.zwp_pointer_gesture_hold_v1,
                });
            },
            2 => try self.destroyObject(hdr.object), // release
            else => return Error.Protocol,
        } else if (iface == &protocol.zwp_pointer_gesture_swipe_v1 or
            iface == &protocol.zwp_pointer_gesture_pinch_v1 or
            iface == &protocol.zwp_pointer_gesture_hold_v1)
        {
            try self.destroyObject(hdr.object); // destroy (only request)
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
                // Constraints on a dead surface are defunct (their
                // objects survive until the client destroys them).
                var cit = self.constraints.valueIterator();
                while (cit.next()) |con| {
                    if (con.sid == hdr.object) con.active = false;
                }
                if (self.drag.active and
                    (self.drag.focus == hdr.object or self.drag.origin == hdr.object))
                {
                    self.drag.focus = 0;
                    try self.dragDrop(); // cancels (focus is gone)
                }
                surf.freeOwned(self.allocator);
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
                if (self.surfaces.getPtr(sid)) |surf| {
                    const copy = try self.allocator.dupe(u8, title);
                    if (surf.title) |old| self.allocator.free(old);
                    surf.title = copy;
                }
                if (self.view.toplevel_title) |cb| cb(self.view.ctx, sid, title);
            },
            3 => { // set_app_id(s)
                const app_id = (try it.next()).?.string orelse return;
                if (self.surfaces.getPtr(sid)) |surf| {
                    const copy = try self.allocator.dupe(u8, app_id);
                    if (surf.app_id) |old| self.allocator.free(old);
                    surf.app_id = copy;
                }
                if (self.view.toplevel_app_id) |cb| cb(self.view.ctx, sid, app_id);
            },
            1 => { // set_parent(?toplevel)
                const ptl = (try it.next()).?.object;
                const psid = if (ptl != 0) (self.xdg_map.get(ptl) orelse 0) else 0;
                if (self.surfaces.getPtr(sid)) |surf| surf.tl_parent = psid;
                if (self.view.toplevel_parent) |cb| cb(self.view.ctx, sid, psid);
            },
            8 => { // set_min_size(w, h)
                const mw = (try it.next()).?.int;
                const mh = (try it.next()).?.int;
                if (self.surfaces.getPtr(sid)) |surf| {
                    surf.min_w = mw;
                    surf.min_h = mh;
                }
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
                if (self.wm_base_version >= 4) {
                    var bbuf: [24]u8 = undefined;
                    var bb = wire.Builder.init(&bbuf, surf.toplevel, 2); // configure_bounds
                    bb.putInt(1920);
                    bb.putInt(1080);
                    try self.send(try bb.finish());
                }
                if (self.wm_base_version >= 5) {
                    var cbuf: [32]u8 = undefined;
                    var cb = wire.Builder.init(&cbuf, surf.toplevel, 3); // wm_capabilities
                    var caps: [12]u8 = undefined;
                    std.mem.writeInt(u32, caps[0..4], 2, .little); // maximize
                    std.mem.writeInt(u32, caps[4..8], 3, .little); // fullscreen
                    std.mem.writeInt(u32, caps[8..12], 4, .little); // minimize
                    cb.putArray(&caps);
                    try self.send(try cb.finish());
                }
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

        // Presentation feedbacks: answered at commit time with the
        // brain clock (frame-callback timing, not real vsync — no
        // flags claimed). One-shot: server-destroyed after the event.
        for (surf.feedbacks.items) |fb| {
            var buf: [48]u8 = undefined;
            var b = wire.Builder.init(&buf, fb, 1); // presented
            b.putUint(0); // tv_sec_hi
            b.putUint(self.now_ms / 1000); // tv_sec_lo
            b.putUint((self.now_ms % 1000) * 1_000_000); // tv_nsec
            b.putUint(16_666_666); // refresh (60 Hz)
            b.putUint(0); // seq_hi
            b.putUint(0); // seq_lo
            b.putUint(0); // flags
            try self.send(try b.finish());
            try self.deleteId(fb);
        }
        surf.feedbacks.clearRetainingCapacity();
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
        const pool = self.poolFor(info) orelse return;
        var scale: i32 = 1;
        var lw: i32 = info.width;
        var lh: i32 = info.height;
        if (self.surfaces.getPtr(sid)) |s| {
            scale = s.buffer_scale;
            if (s.vp_w > 0 and s.vp_h > 0) {
                // Viewport destination IS the logical size — the
                // fractional-scale path (buffer_scale stays 1).
                lw = s.vp_w;
                lh = s.vp_h;
            } else {
                lw = @divTrunc(info.width, @max(1, scale));
                lh = @divTrunc(info.height, @max(1, scale));
            }
        }
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
        cb(self.view.ctx, sid, @intCast(w), @intCast(h), scale, lw, lh, info.format, self.frame_scratch.items);
    }

    /// The effective display scale × 120 (fractional-scale wire unit).
    fn effScale120(self: *const Compositor) u32 {
        if (self.scale120 != 0) return self.scale120;
        return @intCast(self.output_scale * 120);
    }

    /// The viewer told us its true display scale (set_scale intent):
    /// re-announce every scale channel so a mid-session change (or
    /// the app having connected before the viewer attached) converges.
    pub fn setScale120(self: *Compositor, v: u32) Error!void {
        if (v == 0 or v == self.scale120) return;
        self.scale120 = v;
        self.output_scale = @intCast(@divTrunc(v + 119, 120)); // ceil
        var it = self.fs_map.keyIterator();
        while (it.next()) |id| {
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, id.*, 0); // preferred_scale
            b.putUint(v);
            try self.send(try b.finish());
        }
        if (self.compositor_version >= 6) {
            var sit = self.surfaces.keyIterator();
            while (sit.next()) |sid| {
                var buf: [16]u8 = undefined;
                var b = wire.Builder.init(&buf, sid.*, 2); // preferred_buffer_scale
                b.putInt(self.output_scale);
                try self.send(try b.finish());
            }
        }
        // Logical geometry scales with the output — re-announce every
        // live xdg_output BEFORE wl_output.done (v3 completion order).
        var oit = self.objects.iterator();
        while (oit.next()) |e| {
            if (e.value_ptr.* == &protocol.zxdg_output_v1)
                try self.sendXdgOutputState(e.key_ptr.*);
        }
        if (self.output_id != 0) {
            var sbuf: [16]u8 = undefined;
            var sb = wire.Builder.init(&sbuf, self.output_id, 3); // scale
            sb.putInt(self.output_scale);
            try self.send(try sb.finish());
            var dbuf: [8]u8 = undefined;
            var db = wire.Builder.init(&dbuf, self.output_id, 2); // done
            try self.send(try db.finish());
        }
    }

    /// Announce an xdg_output's logical geometry. The fixed 1920x1080
    /// mode divided by the effective scale — matches what fractional-
    /// scale clients will render at.
    fn sendXdgOutputState(self: *Compositor, id: u32) Error!void {
        const s120 = self.effScale120();
        const lw: i32 = @intCast(@as(u64, 1920) * 120 / @max(120, s120));
        const lh: i32 = @intCast(@as(u64, 1080) * 120 / @max(120, s120));
        var pbuf: [24]u8 = undefined;
        var pb = wire.Builder.init(&pbuf, id, 0); // logical_position
        pb.putInt(0);
        pb.putInt(0);
        try self.send(try pb.finish());
        var sbuf: [24]u8 = undefined;
        var sb = wire.Builder.init(&sbuf, id, 1); // logical_size
        sb.putInt(lw);
        sb.putInt(lh);
        try self.send(try sb.finish());
        if (self.xdg_output_ver >= 2) {
            var nbuf: [32]u8 = undefined;
            var nb = wire.Builder.init(&nbuf, id, 3); // name
            nb.putString("sketerm-0");
            try self.send(try nb.finish());
            var ebuf: [48]u8 = undefined;
            var eb = wire.Builder.init(&ebuf, id, 4); // description
            eb.putString("sketerm remote output");
            try self.send(try eb.finish());
        }
        if (self.xdg_output_ver < 3) {
            var dbuf: [8]u8 = undefined;
            var db = wire.Builder.init(&dbuf, id, 2); // done (deprecated in v3)
            try self.send(try db.finish());
        } else if (self.output_id != 0) {
            // v3: state completes via wl_output.done instead.
            var dbuf: [8]u8 = undefined;
            var db = wire.Builder.init(&dbuf, self.output_id, 2);
            try self.send(try db.finish());
        }
    }

    // ── server plumbing ─────────────────────────────────────────

    fn boundGlobal(self: *Compositor, id: u32, iface: *const protocol.Interface, ver: u32) Error!void {
        if (iface == &protocol.wp_presentation) {
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, id, 0); // clock_id
            b.putUint(1); // CLOCK_MONOTONIC
            try self.send(try b.finish());
        }
        if (iface == &protocol.wl_shm) {
            for ([_]u32{ 0, 1 }) |fmt| { // argb8888, xrgb8888
                var buf: [16]u8 = undefined;
                var b = wire.Builder.init(&buf, id, 0); // format
                b.putUint(fmt);
                try self.send(try b.finish());
            }
        } else if (iface == &protocol.zwp_linux_dmabuf_v1) {
            for ([_]u32{ protocol.DRM_FORMAT_ARGB8888, protocol.DRM_FORMAT_XRGB8888 }) |fmt| {
                var fbuf: [16]u8 = undefined;
                var fb = wire.Builder.init(&fbuf, id, 0); // format (legacy)
                fb.putUint(fmt);
                try self.send(try fb.finish());
                if (ver >= 3) {
                    var mbuf: [24]u8 = undefined;
                    var mb = wire.Builder.init(&mbuf, id, 1); // modifier
                    mb.putUint(fmt);
                    mb.putUint(0); // LINEAR hi
                    mb.putUint(0); // LINEAR lo
                    try self.send(try mb.finish());
                }
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
            if (ver >= 4) {
                var nbuf: [32]u8 = undefined;
                var nb = wire.Builder.init(&nbuf, id, 4); // name
                nb.putString("sketerm-0");
                try self.send(try nb.finish());
                var ebuf: [48]u8 = undefined;
                var eb = wire.Builder.init(&ebuf, id, 5); // description
                eb.putString("sketerm remote output");
                try self.send(try eb.finish());
            }
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

    // ── state sync (daemon brain → replica) ─────────────────────
    // Everything a freshly attached replica needs to keep consuming
    // the live request stream and render current windows, EXCEPT
    // pool bytes — those precede the state_sync unit as pool_create
    // + pool_update_c units replayed from the daemon's mirrors.

    // v2 appends the modern-protocol state (bind versions, relative
    // pointers, constraints, text inputs, primary devices, drag).
    // v4 appends a per-buffer flag: 1 = the buffer references the
    // CURRENT incarnation of its pool id (restored refcounts bind to
    // it), 0 = it referenced a displaced incarnation whose bytes are
    // not replayed (the buffer restores unresolvable, never frees a
    // stranger's pool).
    const state_sync_version: u8 = 5;

    fn putU8(out: *std.ArrayList(u8), a: std.mem.Allocator, v: u8) Error!void {
        try out.append(a, v);
    }

    fn putU32(out: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try out.appendSlice(a, &b);
    }

    fn putI32(out: *std.ArrayList(u8), a: std.mem.Allocator, v: i32) Error!void {
        try putU32(out, a, @bitCast(v));
    }

    fn putF64(out: *std.ArrayList(u8), a: std.mem.Allocator, v: f64) Error!void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, @bitCast(v), .little);
        try out.appendSlice(a, &b);
    }

    /// Length-prefixed optional string (0xffffffff = null).
    fn putStr(out: *std.ArrayList(u8), a: std.mem.Allocator, s: ?[]const u8) Error!void {
        const v = s orelse {
            try putU32(out, a, 0xffff_ffff);
            return;
        };
        try putU32(out, a, @intCast(v.len));
        try out.appendSlice(a, v);
    }

    const StateReader = struct {
        buf: []const u8,
        pos: usize = 0,

        fn u8v(r: *StateReader) Error!u8 {
            if (r.pos + 1 > r.buf.len) return Error.Protocol;
            defer r.pos += 1;
            return r.buf[r.pos];
        }

        fn u32v(r: *StateReader) Error!u32 {
            if (r.pos + 4 > r.buf.len) return Error.Protocol;
            defer r.pos += 4;
            return std.mem.readInt(u32, r.buf[r.pos..][0..4], .little);
        }

        fn i32v(r: *StateReader) Error!i32 {
            return @bitCast(try r.u32v());
        }

        fn f64v(r: *StateReader) Error!f64 {
            if (r.pos + 8 > r.buf.len) return Error.Protocol;
            defer r.pos += 8;
            return @bitCast(std.mem.readInt(u64, r.buf[r.pos..][0..8], .little));
        }

        fn str(r: *StateReader, a: std.mem.Allocator) Error!?[]u8 {
            const len = try r.u32v();
            if (len == 0xffff_ffff) return null;
            if (len > pipe.max_unit or r.pos + len > r.buf.len) return Error.Protocol;
            defer r.pos += len;
            return try a.dupe(u8, r.buf[r.pos..][0..len]);
        }
    };

    /// Serialize the full protocol-tracking state. Caller owns the
    /// result. Pool bytes are excluded by design (see above).
    pub fn serializeState(self: *const Compositor, a: std.mem.Allocator) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);

        try putU8(&out, a, state_sync_version);
        try putI32(&out, a, self.output_scale);
        try putU32(&out, a, self.output_id);
        try putU32(&out, a, self.grabbed_popup);
        try putU32(&out, a, self.next_server_id);
        try putU32(&out, a, self.seat_version);
        try putU32(&out, a, self.serial);
        try putU32(&out, a, self.pointer_focus);
        try putU32(&out, a, self.keyboard_focus);

        try putU32(&out, a, self.objects.count());
        var oit = self.objects.iterator();
        while (oit.next()) |e| {
            try putU32(&out, a, e.key_ptr.*);
            try putStr(&out, a, e.value_ptr.*.name);
        }

        try putU32(&out, a, self.buffers.count());
        var bit = self.buffers.iterator();
        while (bit.next()) |e| {
            const b = e.value_ptr;
            try putU32(&out, a, e.key_ptr.*);
            try putU32(&out, a, b.pool);
            try putI32(&out, a, b.offset);
            try putI32(&out, a, b.width);
            try putI32(&out, a, b.height);
            try putI32(&out, a, b.stride);
            try putU32(&out, a, b.format);
            const current = if (self.pools.get(b.pool)) |p| p.serial == b.pool_serial else false;
            try putU8(&out, a, @intFromBool(current));
            // v5: the raw incarnation serial — displaced buffers bind
            // to a replayed orphan pool (pool_orphan units) instead of
            // restoring unresolvable (frozen windows on reattach).
            try putU32(&out, a, @intCast(b.pool_serial & 0xffff_ffff));
            try putU32(&out, a, @intCast(b.pool_serial >> 32));
        }

        try putU32(&out, a, self.surfaces.count());
        var sit = self.surfaces.iterator();
        while (sit.next()) |e| {
            const s = e.value_ptr;
            try putU32(&out, a, e.key_ptr.*);
            try putU32(&out, a, s.pending_buffer);
            try putU8(&out, a, @intFromBool(s.has_pending));
            try putI32(&out, a, s.buffer_scale);
            try putU32(&out, a, s.committed_buffer);
            try putU32(&out, a, s.xdg_surface);
            try putU32(&out, a, s.toplevel);
            try putU32(&out, a, s.popup);
            try putU32(&out, a, s.subparent);
            try putI32(&out, a, s.sub_x);
            try putI32(&out, a, s.sub_y);
            try putU32(&out, a, s.parent);
            try putI32(&out, a, s.px);
            try putI32(&out, a, s.py);
            try putI32(&out, a, s.pw);
            try putI32(&out, a, s.ph);
            try putU8(&out, a, @intFromBool(s.configured));
            try putU8(&out, a, @intFromBool(s.input_pending));
            try putU8(&out, a, @intFromBool(s.input_whole));
            try putU8(&out, a, @intFromBool(s.geo_pending));
            inline for (.{ s.geo_next, s.geo }) |r| {
                try putI32(&out, a, r.x);
                try putI32(&out, a, r.y);
                try putI32(&out, a, r.w);
                try putI32(&out, a, r.h);
            }
            try putStr(&out, a, s.title);
            try putStr(&out, a, s.app_id);
            try putU8(&out, a, s.deco);
            try putI32(&out, a, s.min_w);
            try putI32(&out, a, s.min_h);
            try putU32(&out, a, s.tl_parent);
            try putU32(&out, a, @intCast(s.frame_cbs.items.len));
            for (s.frame_cbs.items) |cb| try putU32(&out, a, cb);
            try putU32(&out, a, @intCast(s.input_rects.items.len));
            for (s.input_rects.items) |r| {
                try putI32(&out, a, r.x);
                try putI32(&out, a, r.y);
                try putI32(&out, a, r.w);
                try putI32(&out, a, r.h);
            }
        }

        inline for (.{ self.xdg_map, self.sub_map }) |map| {
            try putU32(&out, a, map.count());
            var mit = map.iterator();
            while (mit.next()) |e| {
                try putU32(&out, a, e.key_ptr.*);
                try putU32(&out, a, e.value_ptr.*);
            }
        }

        try putU32(&out, a, self.positioners.count());
        var pit = self.positioners.iterator();
        while (pit.next()) |e| {
            const p = e.value_ptr;
            try putU32(&out, a, e.key_ptr.*);
            inline for (.{ p.w, p.h, p.ax, p.ay, p.aw, p.ah }) |v| try putI32(&out, a, v);
            try putU32(&out, a, p.anchor);
            try putU32(&out, a, p.gravity);
            try putI32(&out, a, p.ox);
            try putI32(&out, a, p.oy);
        }

        try putU32(&out, a, self.regions.count());
        var rit = self.regions.iterator();
        while (rit.next()) |e| {
            try putU32(&out, a, e.key_ptr.*);
            try putU32(&out, a, @intCast(e.value_ptr.items.len));
            for (e.value_ptr.items) |r| {
                try putI32(&out, a, r.x);
                try putI32(&out, a, r.y);
                try putI32(&out, a, r.w);
                try putI32(&out, a, r.h);
            }
        }

        try putU32(&out, a, self.data_sources.count());
        var dit = self.data_sources.iterator();
        while (dit.next()) |e| {
            try putU32(&out, a, e.key_ptr.*);
            try putU32(&out, a, @intCast(e.value_ptr.items.len));
            for (e.value_ptr.items) |m| try putStr(&out, a, m);
        }

        inline for (.{ self.data_devices, self.data_control_devices, self.pointers, self.keyboards }) |list| {
            try putU32(&out, a, @intCast(list.items.len));
            for (list.items) |v| try putU32(&out, a, v);
        }

        // ── v2 tail ──────────────────────────────────────────────
        try putU32(&out, a, self.compositor_version);
        try putU32(&out, a, self.wm_base_version);
        try putU32(&out, a, self.ddm_version);
        try putF64(&out, a, self.last_px);
        try putF64(&out, a, self.last_py);
        try putU32(&out, a, self.pressed_button);

        try putU8(&out, a, @intFromBool(self.drag.active));
        try putU8(&out, a, @intFromBool(self.drag.dropped));
        try putU32(&out, a, self.drag.source);
        try putU32(&out, a, self.drag.origin);
        try putU32(&out, a, self.drag.focus);
        try putU32(&out, a, self.drag.offer);
        try putU8(&out, a, @intFromBool(self.drag.accepted));
        try putU32(&out, a, self.drag.action);

        try putU32(&out, a, @intCast(self.rel_pointers.items.len));
        for (self.rel_pointers.items) |rp| {
            try putU32(&out, a, rp.id);
            try putU32(&out, a, rp.pointer);
        }

        try putU32(&out, a, self.constraints.count());
        var cit = self.constraints.iterator();
        while (cit.next()) |e| {
            try putU32(&out, a, e.key_ptr.*);
            try putU32(&out, a, e.value_ptr.sid);
            try putU8(&out, a, e.value_ptr.kind);
            try putU32(&out, a, e.value_ptr.lifetime);
            try putU8(&out, a, @intFromBool(e.value_ptr.active));
        }

        try putU32(&out, a, self.text_inputs.count());
        var tit = self.text_inputs.iterator();
        while (tit.next()) |e| {
            try putU32(&out, a, e.key_ptr.*);
            try putU8(&out, a, @intFromBool(e.value_ptr.enabled));
            try putU8(&out, a, @intFromBool(e.value_ptr.pending_enabled));
            try putU32(&out, a, e.value_ptr.serial);
        }

        try putU32(&out, a, @intCast(self.primary_devices.items.len));
        for (self.primary_devices.items) |v| try putU32(&out, a, v);

        try putU32(&out, a, self.source_actions.count());
        var ait = self.source_actions.iterator();
        while (ait.next()) |e| {
            try putU32(&out, a, e.key_ptr.*);
            try putU32(&out, a, e.value_ptr.*);
        }

        try putU32(&out, a, self.scale120);
        inline for (.{ self.viewport_map, self.fs_map }) |map| {
            try putU32(&out, a, map.count());
            var mit = map.iterator();
            while (mit.next()) |e| {
                try putU32(&out, a, e.key_ptr.*);
                try putU32(&out, a, e.value_ptr.*);
            }
        }
        // Viewport destinations ride separately from the fixed
        // per-surface layout (appended later than it was designed).
        var vp_count: u32 = 0;
        var vit = self.surfaces.iterator();
        while (vit.next()) |e| {
            if (e.value_ptr.vp_w > 0 or e.value_ptr.vp_h > 0) vp_count += 1;
        }
        try putU32(&out, a, vp_count);
        vit = self.surfaces.iterator();
        while (vit.next()) |e| {
            if (e.value_ptr.vp_w > 0 or e.value_ptr.vp_h > 0) {
                try putU32(&out, a, e.key_ptr.*);
                try putI32(&out, a, e.value_ptr.vp_w);
                try putI32(&out, a, e.value_ptr.vp_h);
            }
        }

        // v3: in-flight dmabuf params (a replica attaching between
        // add and create_immed must know plane-0 layout).
        try putU32(&out, a, self.dmabuf_params.count());
        var dpit = self.dmabuf_params.iterator();
        while (dpit.next()) |e| {
            try putU32(&out, a, e.key_ptr.*);
            try putU32(&out, a, e.value_ptr.offset);
            try putU32(&out, a, e.value_ptr.stride);
            try putU8(&out, a, @intFromBool(e.value_ptr.ok));
        }

        return out.toOwnedSlice(a);
    }

    /// Restore serialized state into a FRESH compositor (replica on
    /// attach), then re-fire the View callbacks so windows rebuild.
    /// Feed the pool units before this so frames have pixels.
    pub fn restoreState(self: *Compositor, blob: []const u8) Error!void {
        var r = StateReader{ .buf = blob };
        const a = self.allocator;
        const ver = try r.u8v();
        if (ver < 1 or ver > state_sync_version) return Error.Protocol;
        self.output_scale = try r.i32v();
        self.output_id = try r.u32v();
        self.grabbed_popup = try r.u32v();
        self.next_server_id = try r.u32v();
        self.seat_version = try r.u32v();
        self.serial = try r.u32v();
        self.pointer_focus = try r.u32v();
        self.keyboard_focus = try r.u32v();

        self.objects.clearRetainingCapacity();
        const n_obj = try r.u32v();
        for (0..n_obj) |_| {
            const id = try r.u32v();
            const name = (try r.str(a)) orelse return Error.Protocol;
            defer a.free(name);
            const iface = protocol.find(name) orelse return Error.Protocol;
            try self.objects.put(a, id, iface);
        }

        const n_buf = try r.u32v();
        for (0..n_buf) |_| {
            const id = try r.u32v();
            var b = Buffer{
                .pool = try r.u32v(),
                .offset = try r.i32v(),
                .width = try r.i32v(),
                .height = try r.i32v(),
                .stride = try r.i32v(),
                .format = try r.u32v(),
            };
            // v4: bind only current-incarnation buffers to the
            // replayed pool; pre-v4 senders never distinguished —
            // treat all as current, as before. v5 adds the raw
            // serial: displaced buffers bind to a replayed orphan
            // pool (pool_orphan units) instead of restoring
            // unresolvable (frozen windows on reattach).
            const current = if (ver >= 4) (try r.u8v()) != 0 else true;
            var raw_serial: u64 = 0;
            if (ver >= 5) {
                const lo: u64 = try r.u32v();
                const hi: u64 = try r.u32v();
                raw_serial = lo | (hi << 32);
            }
            if (current) {
                if (self.pools.getPtr(b.pool)) |p| b.pool_serial = p.serial;
            } else {
                b.pool_serial = raw_serial;
            }
            try self.buffers.put(a, id, b);
        }
        // Recompute pool refcounts: the pools arrived via replayed
        // pool_create/pool_orphan units with counts at 0, and freeing
        // a pool under a restored live buffer would drop its frames.
        var bit = self.buffers.valueIterator();
        while (bit.next()) |b| {
            if (self.pools.getPtr(b.pool)) |p| {
                if (p.serial == b.pool_serial) {
                    p.buffers += 1;
                    continue;
                }
            }
            if (self.orphan_pools.getPtr(b.pool_serial)) |op| op.buffers += 1;
        }

        const n_surf = try r.u32v();
        for (0..n_surf) |_| {
            const id = try r.u32v();
            var s = Surface{};
            errdefer s.freeOwned(a);
            s.pending_buffer = try r.u32v();
            s.has_pending = try r.u8v() != 0;
            s.buffer_scale = try r.i32v();
            s.committed_buffer = try r.u32v();
            s.xdg_surface = try r.u32v();
            s.toplevel = try r.u32v();
            s.popup = try r.u32v();
            s.subparent = try r.u32v();
            s.sub_x = try r.i32v();
            s.sub_y = try r.i32v();
            s.parent = try r.u32v();
            s.px = try r.i32v();
            s.py = try r.i32v();
            s.pw = try r.i32v();
            s.ph = try r.i32v();
            s.configured = try r.u8v() != 0;
            s.input_pending = try r.u8v() != 0;
            s.input_whole = try r.u8v() != 0;
            s.geo_pending = try r.u8v() != 0;
            s.geo_next = .{ .x = try r.i32v(), .y = try r.i32v(), .w = try r.i32v(), .h = try r.i32v() };
            s.geo = .{ .x = try r.i32v(), .y = try r.i32v(), .w = try r.i32v(), .h = try r.i32v() };
            s.title = try r.str(a);
            s.app_id = try r.str(a);
            s.deco = try r.u8v();
            s.min_w = try r.i32v();
            s.min_h = try r.i32v();
            s.tl_parent = try r.u32v();
            const n_cbs = try r.u32v();
            for (0..n_cbs) |_| try s.frame_cbs.append(a, try r.u32v());
            const n_rects = try r.u32v();
            for (0..n_rects) |_| try s.input_rects.append(a, .{
                .x = try r.i32v(),
                .y = try r.i32v(),
                .w = try r.i32v(),
                .h = try r.i32v(),
            });
            try self.surfaces.put(a, id, s);
        }

        inline for (.{ &self.xdg_map, &self.sub_map }) |map| {
            const n = try r.u32v();
            for (0..n) |_| {
                const k = try r.u32v();
                try map.put(a, k, try r.u32v());
            }
        }

        const n_pos = try r.u32v();
        for (0..n_pos) |_| {
            const id = try r.u32v();
            var p = Positioner{};
            p.w = try r.i32v();
            p.h = try r.i32v();
            p.ax = try r.i32v();
            p.ay = try r.i32v();
            p.aw = try r.i32v();
            p.ah = try r.i32v();
            p.anchor = try r.u32v();
            p.gravity = try r.u32v();
            p.ox = try r.i32v();
            p.oy = try r.i32v();
            try self.positioners.put(a, id, p);
        }

        const n_reg = try r.u32v();
        for (0..n_reg) |_| {
            const id = try r.u32v();
            var rects: std.ArrayList(Rect) = .empty;
            errdefer rects.deinit(a);
            const n = try r.u32v();
            for (0..n) |_| try rects.append(a, .{
                .x = try r.i32v(),
                .y = try r.i32v(),
                .w = try r.i32v(),
                .h = try r.i32v(),
            });
            try self.regions.put(a, id, rects);
        }

        const n_src = try r.u32v();
        for (0..n_src) |_| {
            const id = try r.u32v();
            var mimes: std.ArrayList([]u8) = .empty;
            errdefer {
                for (mimes.items) |m| a.free(m);
                mimes.deinit(a);
            }
            const n = try r.u32v();
            for (0..n) |_| {
                const m = (try r.str(a)) orelse return Error.Protocol;
                try mimes.append(a, m);
            }
            try self.data_sources.put(a, id, mimes);
        }

        inline for (.{ &self.data_devices, &self.data_control_devices, &self.pointers, &self.keyboards }) |list| {
            const n = try r.u32v();
            for (0..n) |_| try list.append(a, try r.u32v());
        }

        if (ver >= 2) {
            self.compositor_version = try r.u32v();
            self.wm_base_version = try r.u32v();
            self.ddm_version = try r.u32v();
            self.last_px = try r.f64v();
            self.last_py = try r.f64v();
            self.pressed_button = try r.u32v();

            self.drag.active = try r.u8v() != 0;
            self.drag.dropped = try r.u8v() != 0;
            self.drag.source = try r.u32v();
            self.drag.origin = try r.u32v();
            self.drag.focus = try r.u32v();
            self.drag.offer = try r.u32v();
            self.drag.accepted = try r.u8v() != 0;
            self.drag.action = try r.u32v();

            const n_rel = try r.u32v();
            for (0..n_rel) |_| {
                const id = try r.u32v();
                try self.rel_pointers.append(a, .{ .id = id, .pointer = try r.u32v() });
            }

            const n_con = try r.u32v();
            for (0..n_con) |_| {
                const id = try r.u32v();
                var con = Constraint{ .sid = try r.u32v(), .kind = try r.u8v(), .lifetime = 0 };
                con.lifetime = try r.u32v();
                con.active = try r.u8v() != 0;
                try self.constraints.put(a, id, con);
            }

            const n_ti = try r.u32v();
            for (0..n_ti) |_| {
                const id = try r.u32v();
                var ti = TextInput{};
                ti.enabled = try r.u8v() != 0;
                ti.pending_enabled = try r.u8v() != 0;
                ti.serial = try r.u32v();
                try self.text_inputs.put(a, id, ti);
            }

            const n_pd = try r.u32v();
            for (0..n_pd) |_| try self.primary_devices.append(a, try r.u32v());

            const n_sa = try r.u32v();
            for (0..n_sa) |_| {
                const id = try r.u32v();
                try self.source_actions.put(a, id, try r.u32v());
            }

            self.scale120 = try r.u32v();
            inline for (.{ &self.viewport_map, &self.fs_map }) |map| {
                const n = try r.u32v();
                for (0..n) |_| {
                    const k = try r.u32v();
                    try map.put(a, k, try r.u32v());
                }
            }
            const n_vp = try r.u32v();
            for (0..n_vp) |_| {
                const sid = try r.u32v();
                const vw = try r.i32v();
                const vh = try r.i32v();
                if (self.surfaces.getPtr(sid)) |surf| {
                    surf.vp_w = vw;
                    surf.vp_h = vh;
                }
            }
        }

        if (ver >= 3) {
            const n_dp = try r.u32v();
            for (0..n_dp) |_| {
                const id = try r.u32v();
                var dp = DmabufP{};
                dp.offset = try r.u32v();
                dp.stride = try r.u32v();
                dp.ok = try r.u8v() != 0;
                try self.dmabuf_params.put(a, id, dp);
            }
        }

        try self.replayToView();
    }

    /// Re-fire View callbacks for restored state: hosts before
    /// children before pixels (children pushed before their host
    /// window exists would be dropped by the view).
    fn replayToView(self: *Compositor) Error!void {
        var it = self.surfaces.iterator();
        while (it.next()) |e| {
            const sid = e.key_ptr.*;
            const s = e.value_ptr;
            if (s.toplevel == 0) continue;
            if (self.view.toplevel_new) |cb| cb(self.view.ctx, sid);
            if (s.title) |title| if (self.view.toplevel_title) |cb| cb(self.view.ctx, sid, title);
            if (s.app_id) |id| if (self.view.toplevel_app_id) |cb| cb(self.view.ctx, sid, id);
            if (s.deco != 0) if (self.view.toplevel_decoration) |cb| cb(self.view.ctx, sid, s.deco == 2);
            if (s.tl_parent != 0) if (self.view.toplevel_parent) |cb| cb(self.view.ctx, sid, s.tl_parent);
            if (s.min_w != 0 or s.min_h != 0) if (self.view.toplevel_min_size) |cb| cb(self.view.ctx, sid, s.min_w, s.min_h);
            if (s.geo.w != 0) if (self.view.toplevel_geometry) |cb| cb(self.view.ctx, sid, s.geo.x, s.geo.y, s.geo.w, s.geo.h);
            if (!s.input_whole) if (self.view.input_region) |cb| cb(self.view.ctx, sid, s.input_rects.items);
        }
        it = self.surfaces.iterator();
        while (it.next()) |e| {
            const sid = e.key_ptr.*;
            const s = e.value_ptr;
            if (s.subparent != 0) {
                if (self.view.subsurface_new) |cb| cb(self.view.ctx, sid, s.subparent, s.sub_x, s.sub_y);
            } else if (s.popup != 0) {
                if (self.view.popup_new) |cb| cb(self.view.ctx, sid, s.parent, s.px, s.py);
            }
        }
        // Restored input-protocol state the view acts on.
        var tvit = self.text_inputs.valueIterator();
        while (tvit.next()) |ti| {
            if (ti.enabled) {
                if (self.view.text_input_active) |cb| cb(self.view.ctx, true);
                break;
            }
        }
        var cvit = self.constraints.valueIterator();
        while (cvit.next()) |con| {
            if (con.active and con.kind == 0) {
                if (self.view.pointer_locked) |cb| cb(self.view.ctx, con.sid, true);
            }
        }
        // Pixels, same host-then-child order.
        it = self.surfaces.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.toplevel == 0) continue;
            try self.replayFrame(e.key_ptr.*, e.value_ptr);
        }
        it = self.surfaces.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.toplevel != 0) continue;
            try self.replayFrame(e.key_ptr.*, e.value_ptr);
        }
    }

    fn replayFrame(self: *Compositor, sid: u32, s: *const Surface) Error!void {
        if (s.committed_buffer == 0) return;
        const info = self.buffers.get(s.committed_buffer) orelse return;
        try self.pushFrame(sid, info);
    }

    /// Apply one viewer intent unit to this (brain) compositor.
    /// Malformed or unknown intents are ignored: a viewer must never
    /// be able to kill the app's session.
    pub fn applyIntent(self: *Compositor, tag: pipe.Tag, pl: []const u8) void {
        const g = struct {
            fn f64At(b: []const u8, off: usize) f64 {
                return @bitCast(std.mem.readInt(u64, b[off..][0..8], .little));
            }
            fn u32At(b: []const u8, off: usize) u32 {
                return std.mem.readInt(u32, b[off..][0..4], .little);
            }
            fn i32At(b: []const u8, off: usize) i32 {
                return @bitCast(u32At(b, off));
            }
        };
        switch (tag) {
            .seat_enter => if (pl.len >= 20) self.pointerEnter(g.u32At(pl, 0), g.f64At(pl, 4), g.f64At(pl, 12)) catch {},
            .seat_leave => self.pointerLeave() catch {},
            .seat_motion => if (pl.len >= 16) self.pointerMotion(g.f64At(pl, 0), g.f64At(pl, 8)) catch {},
            .seat_button => if (pl.len >= 5) self.pointerButton(g.u32At(pl, 0), pl[4] != 0) catch {},
            .seat_axis => if (pl.len >= 12) {
                const v120: i32 = if (pl.len >= 16) g.i32At(pl, 12) else 0;
                self.pointerAxis(g.u32At(pl, 0), g.f64At(pl, 4), v120) catch {};
            },
            .seat_kbd_enter => if (pl.len >= 4) self.keyboardEnter(g.u32At(pl, 0)) catch {},
            .seat_kbd_leave => self.keyboardLeave() catch {},
            .seat_key => if (pl.len >= 5) self.keyboardKey(g.u32At(pl, 0), pl[4] != 0) catch {},
            .seat_mods => if (pl.len >= 16) self.keyboardModifiers(g.u32At(pl, 0), g.u32At(pl, 4), g.u32At(pl, 8), g.u32At(pl, 12)) catch {},
            .configure => if (pl.len >= 16) {
                const bits = g.u32At(pl, 12);
                self.configureToplevel(g.u32At(pl, 0), g.i32At(pl, 4), g.i32At(pl, 8), .{
                    .activated = bits & 1 != 0,
                    .maximized = bits & 2 != 0,
                    .fullscreen = bits & 4 != 0,
                    .resizing = bits & 8 != 0,
                }) catch {};
            },
            .dismiss_popups => self.dismissPopups() catch {},
            .offer_selection => self.offerSelection(pl) catch {},
            .offer_primary => self.offerPrimary(pl) catch {},
            .text_commit => self.commitString(pl) catch {},
            .set_scale => if (pl.len >= 4) self.setScale120(g.u32At(pl, 0)) catch {},
            .host_drop => if (pl.len >= 24) {
                const mime_len: usize = g.u32At(pl, 20);
                if (24 + mime_len <= pl.len) {
                    self.hostDrop(
                        g.u32At(pl, 0),
                        g.f64At(pl, 4),
                        g.f64At(pl, 12),
                        pl[24 .. 24 + mime_len],
                        pl[24 + mime_len ..],
                    ) catch {};
                }
            },
            .request_close => if (pl.len >= 4) self.requestClose(g.u32At(pl, 0)) catch {},
            else => {},
        }
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
    popup_moves: usize = 0,
    locked_sid: u32 = 0,
    locked: bool = false,
    text_active: bool = false,
    text_flips: usize = 0,
    primary_source: u32 = 0,
    primary_reads: usize = 0,
    raised: u32 = 0,
    last_lw: i32 = 0,
    last_lh: i32 = 0,
    // set_parent ordering: the test sets child_sid; onParent/onFrame
    // record whether the parent arrived before the child's first frame.
    child_sid: u32 = 0,
    child_frames: usize = 0,
    child_parent: u32 = 0,
    child_parent_before_frame: ?bool = null,

    fn onNew(ctx: ?*anyopaque, surface: u32) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.new_count += 1;
    }
    fn onParent(ctx: ?*anyopaque, surface: u32, parent: u32) void {
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        if (surface == self.child_sid) {
            self.child_parent = parent;
            self.child_parent_before_frame = (self.child_frames == 0);
        }
    }
    fn onFrame(ctx: ?*anyopaque, surface: u32, w: i32, h: i32, scale: i32, lw: i32, lh: i32, format: u32, pixels: []const u8) void {
        _ = format;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        if (surface == self.child_sid) self.child_frames += 1;
        self.frames += 1;
        self.last_scale = scale;
        self.last_w = w;
        self.last_h = h;
        self.last_lw = lw;
        self.last_lh = lh;
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

    fn onPopupMoved(ctx: ?*anyopaque, surface: u32, parent: u32, x: i32, y: i32) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.popup_moves += 1;
        self.popup_parent = parent;
        self.popup_x = x;
        self.popup_y = y;
    }
    fn onLocked(ctx: ?*anyopaque, surface: u32, locked: bool) void {
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.locked_sid = surface;
        self.locked = locked;
    }
    fn onTextActive(ctx: ?*anyopaque, active: bool) void {
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.text_active = active;
        self.text_flips += 1;
    }
    fn onPrimaryOffer(ctx: ?*anyopaque, source: u32, mime: []const u8) void {
        _ = mime;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.primary_source = source;
    }
    fn onPrimaryRead(ctx: ?*anyopaque, mime: []const u8) void {
        _ = mime;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.primary_reads += 1;
    }
    fn onRaise(ctx: ?*anyopaque, surface: u32) void {
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.raised = surface;
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
            .popup_moved = onPopupMoved,
            .pointer_locked = onLocked,
            .text_input_active = onTextActive,
            .primary_offer = onPrimaryOffer,
            .primary_read = onPrimaryRead,
            .toplevel_raise = onRaise,
            .toplevel_parent = onParent,
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

test "replica pool storage starts zeroed before partial updates" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    const pool = try comp.freshPool(77, 64);
    for (pool.bytes.items) |b| try t.expectEqual(@as(u8, 0), b);
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
    // Opt-in global; announced here so the count covers the full table.
    comp.advertise_dmabuf = true;

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

    // Default (no SKETERM_MUX_DMABUF): dmabuf is NOT announced —
    // clients that would create unmappable GPU buffers stay on shm.
    var tv2 = TestView{};
    var comp2 = try Compositor.init(t.allocator, tv2.view());
    defer comp2.deinit();
    var b2 = wire.Builder.init(&buf, 1, 1);
    b2.putNewId(2);
    try req(&comp2, try b2.finish());
    seen = 0;
    pos = 0;
    const bytes2 = comp2.takeOut();
    while (try pipe.peelUnit(bytes2[pos..])) |p| {
        const body = p.unit.payload[wire.header_size..];
        try t.expect(std.mem.indexOf(u8, body, "zwp_linux_dmabuf") == null);
        seen += 1;
        pos += p.consumed;
    }
    try t.expectEqual(globals.len - 1, seen);
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

test "JBR binds: seat v5 frame-grouped input, data_device_manager v3" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    { // get_registry(2)
        var b = wire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try req(&comp, try b.finish());
    }
    { // bind seat(name 3) at v5 → id 3 — JBR binds 5 unconditionally
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(3);
        b.putString("wl_seat");
        b.putUint(5);
        b.putNewId(3);
        try req(&comp, try b.finish());
    }
    { // bind data_device_manager(name 6) at v3 → id 4
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(6);
        b.putString("wl_data_device_manager");
        b.putUint(3);
        b.putNewId(4);
        try req(&comp, try b.finish());
    }
    try t.expect(!comp.dead);
    try t.expectEqual(@as(u32, 5), comp.seat_version);

    { // bind compositor → 5, create surface 6
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(1);
        b.putString("wl_compositor");
        b.putUint(4);
        b.putNewId(5);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 5, 0);
        b2.putNewId(6);
        try req(&comp, try b2.finish());
    }
    { // get_pointer(7)
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(7);
        try req(&comp, try b.finish());
    }
    comp.clearOut();

    // Every pointer event group must close with frame (opcode 5) —
    // v5-bound clients buffer input until it arrives.
    try comp.pointerEnter(6, 1.0, 2.0);
    try comp.pointerMotion(3.0, 4.0);
    try comp.pointerButton(0x110, true);
    try comp.pointerAxis(0, 15.0, 0);
    try comp.pointerLeave();

    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    const expect = [_][2]u32{
        .{ 7, 0 }, .{ 7, 5 }, // enter + frame
        .{ 7, 2 }, .{ 7, 5 }, // motion + frame
        .{ 7, 3 }, .{ 7, 5 }, // button + frame
        .{ 7, 4 }, .{ 7, 5 }, // axis + frame
        .{ 7, 1 }, .{ 7, 5 }, // leave + frame
    };
    try t.expectEqualSlices([2]u32, &expect, evs.items);

    { // wl_seat.release (v5 request) must not be a protocol error
        var b = wire.Builder.init(&buf, 3, 3);
        try req(&comp, try b.finish());
    }
    try t.expect(!comp.dead);
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

    // Wayland strings are not limited to the old fixed 128/256-byte
    // scratch buffers. A long but legal MIME must remain a normal offer.
    comp.clearOut();
    evs.clearRetainingCapacity();
    const long_mime = "application/x-sketerm-" ++ ("a" ** 512);
    try comp.offerSelection(long_mime);
    try drainEvents(&comp, &evs);
    try t.expectEqual(@as(usize, 3), evs.items.len);
    try t.expect(!comp.dead);
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

test "wlr-data-control: surfaceless copy + paste, distinct opcodes" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [80]u8 = undefined;

    { // registry(2) + bind manager(name 12) → 3
        var b = wire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try req(&comp, try b.finish());
        var b1 = wire.Builder.init(&buf, 2, 0);
        b1.putUint(12);
        b1.putString("zwlr_data_control_manager_v1");
        b1.putUint(1);
        b1.putNewId(3);
        try req(&comp, try b1.finish());
    }
    comp.clearOut(); // drop the registry globals; only events below matter
    { // create_data_source(4) + offer + get_data_device(5, seat 0)
        var b = wire.Builder.init(&buf, 3, 0); // create_data_source
        b.putNewId(4);
        try req(&comp, try b.finish());
        var b1 = wire.Builder.init(&buf, 4, 0); // source.offer(mime)
        b1.putString("text/plain;charset=utf-8");
        try req(&comp, try b1.finish());
        var b2 = wire.Builder.init(&buf, 3, 1); // get_data_device(id, seat)
        b2.putNewId(5);
        b2.putObject(0);
        try req(&comp, try b2.finish());
    }
    // get_data_device must advertise the current selection right away
    // (no focus event drives it for a surfaceless client): data_offer,
    // offer(mime), selection — selection on op 1 (vs wl_data_device 5).
    {
        var evs: std.ArrayList([2]u32) = .empty;
        defer evs.deinit(t.allocator);
        try drainEvents(&comp, &evs);
        try t.expectEqual(@as(usize, 3), evs.items.len);
        try t.expectEqual([2]u32{ 5, 0 }, evs.items[0]); // data_offer
        try t.expectEqual([2]u32{ 0xff000000, 0 }, evs.items[1]); // offer(mime)
        try t.expectEqual([2]u32{ 5, 1 }, evs.items[2]); // selection (op 1)
    }
    { // device.set_selection(source 4) — op 0, no serial arg
        var b = wire.Builder.init(&buf, 5, 0);
        b.putObject(4);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(u32, 4), tv.clip_source);
    try t.expectEqualStrings("text/plain;charset=utf-8", tv.clip_mime[0..tv.clip_mime_len]);

    // The other direction: receive on the offer-on-bind object → read.
    comp.clearOut();
    {
        var b = wire.Builder.init(&buf, 0xff000000, 0); // offer.receive (op 0)
        b.putString("text/plain;charset=utf-8");
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.clip_reads);
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

test "state_sync: serialize, restore into replica, windows replay" {
    var tv = TestView{};
    var brain = try Compositor.init(t.allocator, tv.view());
    defer brain.deinit();
    var buf: [128]u8 = undefined;

    { // get_registry(2)
        var b = wire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try req(&brain, try b.finish());
    }
    inline for (.{
        .{ 1, "wl_compositor", 4, 3 },
        .{ 2, "wl_shm", 1, 4 },
        .{ 5, "xdg_wm_base", 2, 5 },
    }) |bind| {
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(bind[0]);
        b.putString(bind[1]);
        b.putUint(bind[2]);
        b.putNewId(bind[3]);
        try req(&brain, try b.finish());
    }
    { // create_surface -> 6
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(6);
        try req(&brain, try b.finish());
    }
    { // get_xdg_surface(7, 6)
        var b = wire.Builder.init(&buf, 5, 2);
        b.putNewId(7);
        b.putObject(6);
        try req(&brain, try b.finish());
    }
    { // get_toplevel(8)
        var b = wire.Builder.init(&buf, 7, 1);
        b.putNewId(8);
        try req(&brain, try b.finish());
    }
    { // set_title("hello")
        var b = wire.Builder.init(&buf, 8, 2);
        b.putString("hello");
        try req(&brain, try b.finish());
    }
    { // initial commit (xdg dance)
        var b = wire.Builder.init(&buf, 6, 6);
        try req(&brain, try b.finish());
    }
    { // create_pool(9, fd, 16)
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(9);
        b.putInt(16);
        try req(&brain, try b.finish());
    }
    var px: [16]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(i + 100);
    { // pool bytes side-band
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(t.allocator);
        try pipe.appendPoolUpdate(&unit, t.allocator, 9, 0, &px);
        try brain.feed(unit.items);
    }
    { // create_buffer(10, 0, 2x2, stride 8, xrgb)
        var b = wire.Builder.init(&buf, 9, 0);
        b.putNewId(10);
        b.putInt(0);
        b.putInt(2);
        b.putInt(2);
        b.putInt(8);
        b.putUint(1);
        try req(&brain, try b.finish());
    }
    { // attach + commit
        var b = wire.Builder.init(&buf, 6, 1);
        b.putObject(10);
        b.putInt(0);
        b.putInt(0);
        try req(&brain, try b.finish());
        var b2 = wire.Builder.init(&buf, 6, 6);
        try req(&brain, try b2.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.frames);

    const blob = try brain.serializeState(t.allocator);
    defer t.allocator.free(blob);

    // Replica: pool units first (as the daemon replays its mirrors),
    // then state_sync -- windows and pixels must re-fire.
    var tv2 = TestView{};
    var replica = try Compositor.init(t.allocator, tv2.view());
    defer replica.deinit();
    {
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(t.allocator);
        try pipe.appendPoolMeta(&units, t.allocator, .pool_create, 9, 16);
        try pipe.appendPoolUpdate(&units, t.allocator, 9, 0, &px);
        try pipe.appendUnit(&units, t.allocator, .state_sync, blob);
        try replica.feed(units.items);
    }
    try t.expectEqual(@as(usize, 1), tv2.new_count);
    try t.expectEqualStrings("hello", tv2.title_buf[0..tv2.title_len]);
    try t.expectEqual(@as(usize, 1), tv2.frames);
    try t.expectEqual(@as(i32, 2), tv2.last_w);
    try t.expectEqual(@as(i32, 2), tv2.last_h);
    try t.expectEqual(@as(u8, 100), tv2.last_pixels[0]);

    // The replica keeps tracking the LIVE stream: a set_title on the
    // restored object id must land (objects map survived the trip).
    { // set_title("world") on toplevel 8
        var b = wire.Builder.init(&buf, 8, 2);
        b.putString("world");
        try req(&replica, try b.finish());
    }
    try t.expectEqualStrings("world", tv2.title_buf[0..tv2.title_len]);

    // Replica output is DISCARDED by callers; verify discarding is
    // safe (events were generated but nobody ships them).
    replica.clearOut();
    try t.expect(!replica.dead);
}

test "applyIntent: configure and request_close reach the app" {
    var tv = TestView{};
    var brain = try Compositor.init(t.allocator, tv.view());
    defer brain.deinit();
    var buf: [128]u8 = undefined;

    { // registry + binds + surface + toplevel (condensed)
        var b = wire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try req(&brain, try b.finish());
    }
    inline for (.{
        .{ 1, "wl_compositor", 4, 3 },
        .{ 5, "xdg_wm_base", 2, 5 },
    }) |bind| {
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(bind[0]);
        b.putString(bind[1]);
        b.putUint(bind[2]);
        b.putNewId(bind[3]);
        try req(&brain, try b.finish());
    }
    {
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(6);
        try req(&brain, try b.finish());
        var b2 = wire.Builder.init(&buf, 5, 2);
        b2.putNewId(7);
        b2.putObject(6);
        try req(&brain, try b2.finish());
        var b3 = wire.Builder.init(&buf, 7, 1);
        b3.putNewId(8);
        try req(&brain, try b3.finish());
        var b4 = wire.Builder.init(&buf, 6, 6); // commit -> configured
        try req(&brain, try b4.finish());
    }
    brain.clearOut();

    { // configure intent: 640x480, activated|maximized
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(t.allocator);
        try pipe.appendConfigure(&units, t.allocator, 6, 640, 480, 1 | 2);
        const p = (try pipe.peelUnit(units.items)).?;
        brain.applyIntent(p.unit.tag, p.unit.payload);
    }
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&brain, &evs);
    try t.expectEqual(@as(usize, 2), evs.items.len);
    try t.expectEqual([2]u32{ 8, 0 }, evs.items[0]); // toplevel.configure
    try t.expectEqual([2]u32{ 7, 0 }, evs.items[1]); // xdg.configure

    { // request_close intent
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(t.allocator);
        try pipe.appendRequestClose(&units, t.allocator, 6);
        const p = (try pipe.peelUnit(units.items)).?;
        brain.applyIntent(p.unit.tag, p.unit.payload);
    }
    evs.clearRetainingCapacity();
    try drainEvents(&brain, &evs);
    try t.expectEqual(@as(usize, 1), evs.items.len);
    try t.expectEqual([2]u32{ 8, 1 }, evs.items[0]); // toplevel.close

    // Malformed intents must be inert, never fatal.
    brain.applyIntent(.seat_enter, "xx");
    brain.applyIntent(.configure, "");
    try t.expect(!brain.dead);
}

// ─── modern-protocol tests ──────────────────────────────────────

/// registry(2) + one bind, matching the client-side dance.
fn bindGlobal(comp: *Compositor, name: u32, iface: []const u8, ver: u32, id: u32) !void {
    var buf: [96]u8 = undefined;
    var b = wire.Builder.init(&buf, 2, 0);
    b.putUint(name);
    b.putString(iface);
    b.putUint(ver);
    b.putNewId(id);
    try req(comp, try b.finish());
}

fn getRegistry(comp: *Compositor) !void {
    var buf: [16]u8 = undefined;
    var b = wire.Builder.init(&buf, 1, 1);
    b.putNewId(2);
    try req(comp, try b.finish());
}

test "v6 compositor / v6 wm_base / v4 output obligations" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 1, "wl_compositor", 6, 3);
    try bindGlobal(&comp, 5, "xdg_wm_base", 6, 4);
    comp.clearOut();

    try bindGlobal(&comp, 4, "wl_output", 4, 5);
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    // geometry, mode, scale, name, description, done — in order.
    const out_expect = [_][2]u32{
        .{ 5, 0 }, .{ 5, 1 }, .{ 5, 3 }, .{ 5, 4 }, .{ 5, 5 }, .{ 5, 2 },
    };
    try t.expectEqualSlices([2]u32, &out_expect, evs.items);

    { // create_surface → preferred buffer scale + transform
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(6);
        try req(&comp, try b.finish());
    }
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    const surf_expect = [_][2]u32{ .{ 6, 2 }, .{ 6, 3 } };
    try t.expectEqualSlices([2]u32, &surf_expect, evs.items);

    { // xdg dance
        var b = wire.Builder.init(&buf, 4, 2); // get_xdg_surface(7, 6)
        b.putNewId(7);
        b.putObject(6);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 7, 1); // get_toplevel(8)
        b2.putNewId(8);
        try req(&comp, try b2.finish());
    }
    comp.clearOut();
    { // first commit → bounds + capabilities + configure
        var b = wire.Builder.init(&buf, 6, 6);
        try req(&comp, try b.finish());
    }
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    const cfg_expect = [_][2]u32{
        .{ 8, 2 }, // configure_bounds
        .{ 8, 3 }, // wm_capabilities
        .{ 8, 0 }, // toplevel configure
        .{ 7, 0 }, // xdg_surface configure
    };
    try t.expectEqualSlices([2]u32, &cfg_expect, evs.items);
    try t.expect(!comp.dead);
}

test "seat v8: wheel scrolls carry axis_value120" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 3, "wl_seat", 8, 3);
    try bindGlobal(&comp, 1, "wl_compositor", 4, 4);
    { // surface 5, pointer 6
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(5);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 3, 0);
        b2.putNewId(6);
        try req(&comp, try b2.finish());
    }
    try comp.pointerEnter(5, 1, 1);
    comp.clearOut();

    try comp.pointerAxis(0, 20.0, 240); // two wheel detents
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    const wheel_expect = [_][2]u32{
        .{ 6, 9 }, // axis_value120
        .{ 6, 4 }, // axis
        .{ 6, 5 }, // frame
    };
    try t.expectEqualSlices([2]u32, &wheel_expect, evs.items);

    try comp.pointerAxis(0, 3.5, 0); // touchpad: no discrete info
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    const smooth_expect = [_][2]u32{ .{ 6, 4 }, .{ 6, 5 } };
    try t.expectEqualSlices([2]u32, &smooth_expect, evs.items);
}

test "relative pointer + pointer lock: locked suppresses absolute motion" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 3, "wl_seat", 8, 3);
    try bindGlobal(&comp, 1, "wl_compositor", 4, 4);
    try bindGlobal(&comp, 14, "zwp_relative_pointer_manager_v1", 1, 5);
    try bindGlobal(&comp, 15, "zwp_pointer_constraints_v1", 1, 6);
    { // surface 7, pointer 8, relative pointer 9, lock 10
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(7);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 3, 0);
        b2.putNewId(8);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 5, 1); // get_relative_pointer
        b3.putNewId(9);
        b3.putObject(8);
        try req(&comp, try b3.finish());
        var b4 = wire.Builder.init(&buf, 6, 1); // lock_pointer
        b4.putNewId(10);
        b4.putObject(7);
        b4.putObject(8);
        b4.putObject(0); // region: whole surface
        b4.putUint(2); // persistent
        try req(&comp, try b4.finish());
    }
    comp.clearOut();

    try comp.pointerEnter(7, 5, 5);
    try t.expect(tv.locked);
    try t.expectEqual(@as(u32, 7), tv.locked_sid);
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    const enter_expect = [_][2]u32{
        .{ 8, 0 }, .{ 8, 5 }, // enter + frame
        .{ 10, 0 }, // locked
    };
    try t.expectEqualSlices([2]u32, &enter_expect, evs.items);

    try comp.pointerMotion(8, 6);
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    const motion_expect = [_][2]u32{
        .{ 9, 0 }, // relative_motion (NO absolute 8,2)
        .{ 8, 5 }, // frame
    };
    try t.expectEqualSlices([2]u32, &motion_expect, evs.items);

    try comp.pointerLeave();
    try t.expect(!tv.locked);
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    const leave_expect = [_][2]u32{
        .{ 10, 1 }, // unlocked
        .{ 8, 1 }, .{ 8, 5 }, // leave + frame
    };
    try t.expectEqualSlices([2]u32, &leave_expect, evs.items);
}

test "primary selection: offer both ways + receive routing" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [96]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 13, "zwp_primary_selection_device_manager_v1", 1, 3);
    { // source 4 with a text mime, device 5
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(4);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 4, 0);
        b2.putString("text/plain;charset=utf-8");
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 3, 1);
        b3.putNewId(5);
        b3.putObject(0);
        try req(&comp, try b3.finish());
    }
    { // app sets its primary selection → view offer
        var b = wire.Builder.init(&buf, 5, 0);
        b.putObject(4);
        b.putUint(1);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(u32, 4), tv.primary_source);

    // Host announces ITS primary selection toward the device.
    comp.clearOut();
    try comp.offerPrimary("text/plain;charset=utf-8");
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    const offer_id = comp.next_server_id - 1;
    const offer_expect = [_][2]u32{
        .{ 5, 0 }, // data_offer
        .{ offer_id, 0 }, // offer(mime)
        .{ 5, 1 }, // selection
    };
    try t.expectEqualSlices([2]u32, &offer_expect, evs.items);

    { // app pastes from it → primary_read (separate fd FIFO)
        var b = wire.Builder.init(&buf, offer_id, 0); // receive
        b.putString("text/plain;charset=utf-8");
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.primary_reads);

    // Answer flows as a primary_data unit, not clip_data.
    comp.clearOut();
    try comp.sendPrimaryData("hi");
    const bytes = comp.takeOut();
    const p = (try pipe.peelUnit(bytes)).?;
    try t.expectEqual(pipe.Tag.primary_data, p.unit.tag);
    try t.expectEqualStrings("hi", p.unit.payload);
}

test "text-input v3: enable/commit gates IM, commit_string + done" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 16, "zwp_text_input_manager_v3", 1, 3);
    try bindGlobal(&comp, 1, "wl_compositor", 4, 4);
    { // surface 5, text input 6
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(5);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 3, 1); // get_text_input
        b2.putNewId(6);
        b2.putObject(0);
        try req(&comp, try b2.finish());
    }
    try comp.keyboardEnter(5);
    comp.clearOut();

    { // enable + commit → active
        var b = wire.Builder.init(&buf, 6, 1);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 6, 7);
        try req(&comp, try b2.finish());
    }
    try t.expect(tv.text_active);
    try t.expectEqual(@as(usize, 1), tv.text_flips);

    try comp.commitString("héllo");
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    const ti_expect = [_][2]u32{
        .{ 6, 3 }, // commit_string
        .{ 6, 5 }, // done
    };
    try t.expectEqualSlices([2]u32, &ti_expect, evs.items);

    { // disable + commit → inactive
        var b = wire.Builder.init(&buf, 6, 2);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 6, 7);
        try req(&comp, try b2.finish());
    }
    try t.expect(!tv.text_active);
    try t.expectEqual(@as(usize, 2), tv.text_flips);
}

test "within-app dnd: start_drag through drop, transfer, finish" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [96]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 3, "wl_seat", 8, 3);
    try bindGlobal(&comp, 1, "wl_compositor", 4, 4);
    try bindGlobal(&comp, 6, "wl_data_device_manager", 3, 5);
    { // surface 6, source 7 (uri-list, copy|move), device 8, pointer 9
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(6);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 5, 0);
        b2.putNewId(7);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 7, 0);
        b3.putString("text/uri-list");
        try req(&comp, try b3.finish());
        var b4 = wire.Builder.init(&buf, 7, 2); // set_actions(copy|move)
        b4.putUint(3);
        try req(&comp, try b4.finish());
        var b5 = wire.Builder.init(&buf, 5, 1);
        b5.putNewId(8);
        b5.putObject(3);
        try req(&comp, try b5.finish());
        var b6 = wire.Builder.init(&buf, 3, 0);
        b6.putNewId(9);
        try req(&comp, try b6.finish());
    }
    try comp.pointerEnter(6, 4, 4);
    try comp.pointerButton(0x110, true);
    comp.clearOut();

    { // start_drag(source 7, origin 6, no icon, serial)
        var b = wire.Builder.init(&buf, 8, 0);
        b.putObject(7);
        b.putObject(6);
        b.putObject(0);
        b.putUint(99);
        try req(&comp, try b.finish());
    }
    try t.expect(comp.drag.active);
    const offer_id = comp.drag.offer;
    try t.expect(offer_id != 0);
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    const start_expect = [_][2]u32{
        .{ 9, 1 }, .{ 9, 5 }, // pointer leave + frame
        .{ 8, 0 }, // data_offer
        .{ offer_id, 0 }, // offer(mime)
        .{ offer_id, 1 }, // source_actions
        .{ 8, 1 }, // dd enter
    };
    try t.expectEqualSlices([2]u32, &start_expect, evs.items);

    // Motion is dd.motion, not pointer.motion.
    try comp.pointerMotion(10, 10);
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    try t.expectEqualSlices([2]u32, &[_][2]u32{.{ 8, 3 }}, evs.items);

    { // target negotiates: set_actions + accept
        var b = wire.Builder.init(&buf, offer_id, 4); // set_actions(copy, copy)
        b.putUint(1);
        b.putUint(1);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, offer_id, 0); // accept
        b2.putUint(99);
        b2.putString("text/uri-list");
        try req(&comp, try b2.finish());
    }
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    const nego_expect = [_][2]u32{
        .{ offer_id, 2 }, // offer.action
        .{ 7, 5 }, // source.action
        .{ 7, 0 }, // source.target
    };
    try t.expectEqualSlices([2]u32, &nego_expect, evs.items);

    // Release → drop.
    try comp.pointerButton(0x110, false);
    try t.expect(!comp.drag.active);
    try t.expect(comp.drag.dropped);
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    const drop_expect = [_][2]u32{
        .{ 8, 4 }, // drop
        .{ 7, 3 }, // dnd_drop_performed
    };
    try t.expectEqualSlices([2]u32, &drop_expect, evs.items);

    { // receive routes to the SOURCE via a dnd_send unit
        var b = wire.Builder.init(&buf, offer_id, 1);
        b.putString("text/uri-list");
        try req(&comp, try b.finish());
    }
    {
        const bytes = comp.takeOut();
        var pos: usize = 0;
        var saw_dnd_send = false;
        while (try pipe.peelUnit(bytes[pos..])) |p| {
            if (p.unit.tag == .dnd_send) {
                try t.expectEqual(@as(u32, 7), std.mem.readInt(u32, p.unit.payload[0..4], .little));
                try t.expectEqual(offer_id, std.mem.readInt(u32, p.unit.payload[4..8], .little));
                try t.expectEqualStrings("text/uri-list", p.unit.payload[8..]);
                saw_dnd_send = true;
            }
            pos += p.consumed;
        }
        try t.expect(saw_dnd_send);
        comp.clearOut();
    }

    { // finish → dnd_finished, drag state cleared
        var b = wire.Builder.init(&buf, offer_id, 3);
        try req(&comp, try b.finish());
    }
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    try t.expectEqualSlices([2]u32, &[_][2]u32{.{ 7, 4 }}, evs.items);
    try t.expect(!comp.drag.dropped);
    try t.expect(!comp.dead);
}

test "xdg-activation, presentation-time, idle-inhibit, gestures" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 17, "xdg_activation_v1", 1, 3);
    try bindGlobal(&comp, 1, "wl_compositor", 4, 4);
    { // surface 5
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(5);
        try req(&comp, try b.finish());
    }
    comp.clearOut();
    { // token dance: get(6), commit → done
        var b = wire.Builder.init(&buf, 3, 1);
        b.putNewId(6);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 6, 3); // commit
        try req(&comp, try b2.finish());
    }
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    try t.expectEqualSlices([2]u32, &[_][2]u32{.{ 6, 0 }}, evs.items);
    { // activate(token, surface 5) → raise
        var b = wire.Builder.init(&buf, 3, 2);
        b.putString("whatever");
        b.putObject(5);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(u32, 5), tv.raised);

    // Presentation: clock_id at bind, presented at commit.
    comp.clearOut();
    try bindGlobal(&comp, 18, "wp_presentation", 1, 7);
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    try t.expectEqualSlices([2]u32, &[_][2]u32{.{ 7, 0 }}, evs.items); // clock_id
    { // feedback(surface 5, id 8) + commit
        var b = wire.Builder.init(&buf, 7, 1);
        b.putObject(5);
        b.putNewId(8);
        try req(&comp, try b.finish());
        comp.clearOut();
        var b2 = wire.Builder.init(&buf, 5, 6); // commit
        try req(&comp, try b2.finish());
    }
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    const pres_expect = [_][2]u32{
        .{ 8, 1 }, // presented
        .{ 1, 1 }, // delete_id(8) — one-shot object
    };
    try t.expectEqualSlices([2]u32, &pres_expect, evs.items);

    // Idle inhibit + gestures: accepted, inert, never fatal.
    try bindGlobal(&comp, 19, "zwp_idle_inhibit_manager_v1", 1, 9);
    try bindGlobal(&comp, 20, "zwp_pointer_gestures_v1", 3, 10);
    {
        var b = wire.Builder.init(&buf, 9, 1); // create_inhibitor(11, 5)
        b.putNewId(11);
        b.putObject(5);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 11, 0); // inhibitor destroy
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 10, 0); // get_swipe(12, pointer 0)
        b3.putNewId(12);
        b3.putObject(0);
        try req(&comp, try b3.finish());
        var b4 = wire.Builder.init(&buf, 10, 3); // get_hold(13, pointer 0)
        b4.putNewId(13);
        b4.putObject(0);
        try req(&comp, try b4.finish());
        var b5 = wire.Builder.init(&buf, 12, 0); // swipe destroy
        try req(&comp, try b5.finish());
    }
    try t.expect(!comp.dead);
}

test "xdg_popup.reposition: repositioned + configure + view move" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [96]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 1, "wl_compositor", 4, 3);
    try bindGlobal(&comp, 5, "xdg_wm_base", 6, 4);
    { // parent: surface 5 → xdg 6 → toplevel 7, committed
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(5);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 4, 2);
        b2.putNewId(6);
        b2.putObject(5);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 6, 1);
        b3.putNewId(7);
        try req(&comp, try b3.finish());
        var b4 = wire.Builder.init(&buf, 5, 6); // commit
        try req(&comp, try b4.finish());
    }
    { // popup: surface 8 → xdg 9, positioner 10 (anchor tl, gravity br)
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(8);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 4, 2);
        b2.putNewId(9);
        b2.putObject(8);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 4, 1); // create_positioner
        b3.putNewId(10);
        try req(&comp, try b3.finish());
        var b4 = wire.Builder.init(&buf, 10, 1); // set_size(100, 50)
        b4.putInt(100);
        b4.putInt(50);
        try req(&comp, try b4.finish());
        var b5 = wire.Builder.init(&buf, 10, 2); // set_anchor_rect(10, 20, 1, 1)
        b5.putInt(10);
        b5.putInt(20);
        b5.putInt(1);
        b5.putInt(1);
        try req(&comp, try b5.finish());
        var b6 = wire.Builder.init(&buf, 10, 3); // anchor top-left
        b6.putUint(5);
        try req(&comp, try b6.finish());
        var b7 = wire.Builder.init(&buf, 10, 4); // gravity bottom-right
        b7.putUint(8);
        try req(&comp, try b7.finish());
        var b8 = wire.Builder.init(&buf, 9, 2); // get_popup(11, parent 6, pos 10)
        b8.putNewId(11);
        b8.putObject(6);
        b8.putObject(10);
        try req(&comp, try b8.finish());
        var b9 = wire.Builder.init(&buf, 8, 6); // commit → initial configure
        try req(&comp, try b9.finish());
    }
    try t.expectEqual(@as(i32, 10), tv.popup_x);
    try t.expectEqual(@as(i32, 20), tv.popup_y);
    comp.clearOut();

    { // move the anchor, reposition(pos 10, token 77)
        var b = wire.Builder.init(&buf, 10, 2); // set_anchor_rect(30, 40, 1, 1)
        b.putInt(30);
        b.putInt(40);
        b.putInt(1);
        b.putInt(1);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 11, 2); // reposition
        b2.putObject(10);
        b2.putUint(77);
        try req(&comp, try b2.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.popup_moves);
    try t.expectEqual(@as(i32, 30), tv.popup_x);
    try t.expectEqual(@as(i32, 40), tv.popup_y);
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    const repos_expect = [_][2]u32{
        .{ 11, 2 }, // repositioned(token)
        .{ 11, 0 }, // popup configure
        .{ 9, 0 }, // xdg_surface configure
    };
    try t.expectEqualSlices([2]u32, &repos_expect, evs.items);
}

test "state sync v2: versions and input-protocol state round-trip" {
    var tv = TestView{};
    var brain = try Compositor.init(t.allocator, tv.view());
    defer brain.deinit();
    var buf: [64]u8 = undefined;

    try getRegistry(&brain);
    try bindGlobal(&brain, 3, "wl_seat", 8, 3);
    try bindGlobal(&brain, 1, "wl_compositor", 6, 4);
    try bindGlobal(&brain, 5, "xdg_wm_base", 6, 5);
    try bindGlobal(&brain, 16, "zwp_text_input_manager_v3", 1, 6);
    { // surface 7, text input 8, enabled
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(7);
        try req(&brain, try b.finish());
        var b2 = wire.Builder.init(&buf, 6, 1);
        b2.putNewId(8);
        b2.putObject(0);
        try req(&brain, try b2.finish());
        var b3 = wire.Builder.init(&buf, 8, 1); // enable
        try req(&brain, try b3.finish());
        var b4 = wire.Builder.init(&buf, 8, 7); // commit
        try req(&brain, try b4.finish());
    }
    try brain.keyboardEnter(7);

    const blob = try brain.serializeState(t.allocator);
    defer t.allocator.free(blob);

    var tv2 = TestView{};
    var replica = try Compositor.init(t.allocator, tv2.view());
    defer replica.deinit();
    replica.lenient = true;
    try replica.restoreState(blob);

    try t.expectEqual(@as(u32, 8), replica.seat_version);
    try t.expectEqual(@as(u32, 6), replica.compositor_version);
    try t.expectEqual(@as(u32, 6), replica.wm_base_version);
    try t.expectEqual(@as(u32, 1), replica.text_inputs.count());
    // The replica's view learns the enabled text input on replay.
    try t.expect(tv2.text_active);
}

test "fractional scale: set_scale re-announces, viewport sets logical size" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 1, "wl_compositor", 6, 3);
    try bindGlobal(&comp, 8, "wp_viewporter", 1, 4);
    try bindGlobal(&comp, 21, "wp_fractional_scale_manager_v1", 1, 5);
    try bindGlobal(&comp, 2, "wl_shm", 1, 6);
    { // surface 7
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(7);
        try req(&comp, try b.finish());
    }
    comp.clearOut();
    { // get_fractional_scale(8, surface 7) → immediate preferred_scale
        var b = wire.Builder.init(&buf, 5, 1);
        b.putNewId(8);
        b.putObject(7);
        try req(&comp, try b.finish());
    }
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    try t.expectEqualSlices([2]u32, &[_][2]u32{.{ 8, 0 }}, evs.items);

    // Viewer announces 1.5×: preferred_scale re-fires with 180 and
    // preferred_buffer_scale (v6) says ceil = 2.
    comp.applyIntent(.set_scale, &[_]u8{ 180, 0, 0, 0 });
    try t.expectEqual(@as(u32, 180), comp.scale120);
    try t.expectEqual(@as(i32, 2), comp.output_scale);
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    const rescale_expect = [_][2]u32{
        .{ 8, 0 }, // preferred_scale(180)
        .{ 7, 2 }, // preferred_buffer_scale(2)
    };
    try t.expectEqualSlices([2]u32, &rescale_expect, evs.items);

    { // viewport(9) destination 100×50 logical
        var b = wire.Builder.init(&buf, 4, 1); // get_viewport
        b.putNewId(9);
        b.putObject(7);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 9, 2); // set_destination
        b2.putInt(100);
        b2.putInt(50);
        try req(&comp, try b2.finish());
    }

    // Commit a 150×75 physical buffer (1.5 × the 100×50 logical):
    // toplevel_frame must report lw=100, lh=50 with scale 1.
    { // pool 10 (via side-band), buffer 11, attach + commit
        var meta: [8]u8 = undefined;
        std.mem.writeInt(u32, meta[0..4], 10, .little);
        std.mem.writeInt(u32, meta[4..8], 150 * 75 * 4, .little);
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(t.allocator);
        try pipe.appendUnit(&unit, t.allocator, .pool_create, &meta);
        try comp.feed(unit.items);

        // create_pool wl_msg so the object exists — the 'h' fd arg
        // carries no wire bytes (pool bytes ride the side-band unit).
        var pb = wire.Builder.init(&buf, 6, 0);
        pb.putNewId(10);
        pb.putInt(150 * 75 * 4);
        try req(&comp, try pb.finish());
        var bb = wire.Builder.init(&buf, 10, 0); // create_buffer
        bb.putNewId(11);
        bb.putInt(0);
        bb.putInt(150);
        bb.putInt(75);
        bb.putInt(150 * 4);
        bb.putUint(0);
        try req(&comp, try bb.finish());
        var ab = wire.Builder.init(&buf, 7, 1); // attach
        ab.putObject(11);
        ab.putInt(0);
        ab.putInt(0);
        try req(&comp, try ab.finish());
        // Needs a mapped role for pushFrame — make it a subsurface-free
        // toplevel via xdg? Simpler: subsurface role isn't available
        // here; bind wm_base and do the dance.
        try bindGlobal(&comp, 5, "xdg_wm_base", 6, 12);
        var xb = wire.Builder.init(&buf, 12, 2); // get_xdg_surface(13, 7)
        xb.putNewId(13);
        xb.putObject(7);
        try req(&comp, try xb.finish());
        var tb = wire.Builder.init(&buf, 13, 1); // get_toplevel(14)
        tb.putNewId(14);
        try req(&comp, try tb.finish());
        var cb = wire.Builder.init(&buf, 7, 6); // commit
        try req(&comp, try cb.finish());
    }
    try t.expect(tv.frames >= 1);
    try t.expectEqual(@as(i32, 150), tv.last_w);
    try t.expectEqual(@as(i32, 75), tv.last_h);
    try t.expectEqual(@as(i32, 100), tv.last_lw);
    try t.expectEqual(@as(i32, 50), tv.last_lh);
    try t.expectEqual(@as(i32, 1), tv.last_scale);
    try t.expect(!comp.dead);
}

test "transient dialog: set_parent is delivered before the child's first frame" {
    // Reproduces the JBR/AWT modal-dialog sequence: a second toplevel
    // that calls set_parent(first) at creation, then commits its first
    // buffer later. The parent MUST reach the view before the frame —
    // the GUI builds the window on that first frame, so a parent that
    // arrived earlier has to be latched (pending_parents in wlapp) or
    // the dialog opens as a standalone taskbar window instead of a
    // modal over its parent.
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 1, "wl_compositor", 6, 3);
    try bindGlobal(&comp, 5, "xdg_wm_base", 6, 4);
    try bindGlobal(&comp, 2, "wl_shm", 1, 12);

    // Parent toplevel: surface 6 → xdg_surface 7 → toplevel 8.
    {
        var b = wire.Builder.init(&buf, 3, 0); // create_surface(6)
        b.putNewId(6);
        try req(&comp, try b.finish());
        var xb = wire.Builder.init(&buf, 4, 2); // get_xdg_surface(7, 6)
        xb.putNewId(7);
        xb.putObject(6);
        try req(&comp, try xb.finish());
        var tb = wire.Builder.init(&buf, 7, 1); // get_toplevel(8)
        tb.putNewId(8);
        try req(&comp, try tb.finish());
    }

    // Dialog toplevel: surface 9 → xdg_surface 10 → toplevel 11, and
    // set_parent(8) at creation — BEFORE any buffer commit.
    tv.child_sid = 9;
    {
        var b = wire.Builder.init(&buf, 3, 0); // create_surface(9)
        b.putNewId(9);
        try req(&comp, try b.finish());
        var xb = wire.Builder.init(&buf, 4, 2); // get_xdg_surface(10, 9)
        xb.putNewId(10);
        xb.putObject(9);
        try req(&comp, try xb.finish());
        var tb = wire.Builder.init(&buf, 10, 1); // get_toplevel(11)
        tb.putNewId(11);
        try req(&comp, try tb.finish());
        var pb = wire.Builder.init(&buf, 11, 1); // set_parent(8)
        pb.putObject(8);
        try req(&comp, try pb.finish());
    }

    // Parent resolved to the parent surface, and no frame yet.
    try t.expectEqual(@as(u32, 6), tv.child_parent);
    try t.expectEqual(@as(usize, 0), tv.child_frames);

    // Now the dialog commits its first buffer (400×300).
    {
        var meta: [8]u8 = undefined;
        std.mem.writeInt(u32, meta[0..4], 20, .little);
        std.mem.writeInt(u32, meta[4..8], 400 * 300 * 4, .little);
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(t.allocator);
        try pipe.appendUnit(&unit, t.allocator, .pool_create, &meta);
        try comp.feed(unit.items);
        var pb = wire.Builder.init(&buf, 12, 0); // wl_shm.create_pool(20)
        pb.putNewId(20);
        pb.putInt(400 * 300 * 4);
        try req(&comp, try pb.finish());
        var bb = wire.Builder.init(&buf, 20, 0); // create_buffer(21)
        bb.putNewId(21);
        bb.putInt(0);
        bb.putInt(400);
        bb.putInt(300);
        bb.putInt(400 * 4);
        bb.putUint(0);
        try req(&comp, try bb.finish());
        var ab = wire.Builder.init(&buf, 9, 1); // attach(21) to surface 9
        ab.putObject(21);
        ab.putInt(0);
        ab.putInt(0);
        try req(&comp, try ab.finish());
        var cb = wire.Builder.init(&buf, 9, 6); // commit
        try req(&comp, try cb.finish());
    }

    // The frame landed, and the parent was known strictly before it.
    try t.expect(tv.child_frames >= 1);
    try t.expect(tv.child_parent_before_frame != null);
    try t.expect(tv.child_parent_before_frame.?);
    try t.expect(!comp.dead);
}

test "host_drop: synthesized dnd delivers host data via drop_data" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 1, "wl_compositor", 4, 3);
    try bindGlobal(&comp, 3, "wl_seat", 8, 4);
    try bindGlobal(&comp, 6, "wl_data_device_manager", 3, 5);
    { // surface 6, data device 7
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(6);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 5, 1);
        b2.putNewId(7);
        b2.putObject(4);
        try req(&comp, try b2.finish());
    }
    comp.clearOut();

    { // host_drop intent: file uri onto surface 6 at (12, 34)
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(t.allocator);
        try pipe.appendHostDrop(&units, t.allocator, 6, 12.0, 34.0, "text/uri-list", "file:///tmp/x.txt\r\n");
        const p = (try pipe.peelUnit(units.items)).?;
        comp.applyIntent(p.unit.tag, p.unit.payload);
    }
    const offer_id = comp.host_drag.offer;
    try t.expect(offer_id != 0);
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    const drop_expect = [_][2]u32{
        .{ 7, 0 }, // data_offer
        .{ offer_id, 0 }, // offer(mime)
        .{ offer_id, 1 }, // source_actions
        .{ 7, 1 }, // enter
        .{ offer_id, 2 }, // action
        .{ 7, 3 }, // motion
        .{ 7, 4 }, // drop
    };
    try t.expectEqualSlices([2]u32, &drop_expect, evs.items);

    { // client receives → drop_data unit with the payload
        var b = wire.Builder.init(&buf, offer_id, 1); // receive
        b.putString("text/uri-list");
        try req(&comp, try b.finish());
    }
    {
        const bytes = comp.takeOut();
        var pos: usize = 0;
        var saw = false;
        while (try pipe.peelUnit(bytes[pos..])) |p| {
            if (p.unit.tag == .drop_data) {
                try t.expectEqual(offer_id, std.mem.readInt(u32, p.unit.payload[0..4], .little));
                try t.expectEqualStrings("file:///tmp/x.txt\r\n", p.unit.payload[4..]);
                saw = true;
            }
            pos += p.consumed;
        }
        try t.expect(saw);
        comp.clearOut();
    }
    { // finish clears the host drag
        var b = wire.Builder.init(&buf, offer_id, 3);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(u32, 0), comp.host_drag.offer);
    try t.expect(!comp.dead);
}

test "linux-dmabuf: modifiers at bind, create_immed pixels + release, create fails over to shm" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [96]u8 = undefined;

    { // get_registry(2)
        var b = wire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try req(&comp, try b.finish());
    }
    comp.clearOut();
    { // bind dmabuf(name 22) v3 -> id 3
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(22);
        b.putString("zwp_linux_dmabuf_v1");
        b.putUint(3);
        b.putNewId(3);
        try req(&comp, try b.finish());
    }
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    // ARGB + XRGB, each as legacy format + LINEAR modifier.
    const bind_expect = [_][2]u32{
        .{ 3, 0 }, .{ 3, 1 },
        .{ 3, 0 }, .{ 3, 1 },
    };
    try t.expectEqualSlices([2]u32, &bind_expect, evs.items);

    { // bind compositor(name 1) -> 4
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(1);
        b.putString("wl_compositor");
        b.putUint(4);
        b.putNewId(4);
        try req(&comp, try b.finish());
    }
    { // bind xdg_wm_base(name 5) -> 5
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(5);
        b.putString("xdg_wm_base");
        b.putUint(2);
        b.putNewId(5);
        try req(&comp, try b.finish());
    }
    { // create_surface -> 6
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(6);
        try req(&comp, try b.finish());
    }
    { // get_xdg_surface(7, 6)
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
    { // initial commit (no buffer)
        var b = wire.Builder.init(&buf, 6, 6);
        try req(&comp, try b.finish());
    }

    { // create_params(9)
        var b = wire.Builder.init(&buf, 3, 1);
        b.putNewId(9);
        try req(&comp, try b.finish());
    }
    { // add(fd, plane 0, offset 0, stride 8, LINEAR)
        var b = wire.Builder.init(&buf, 9, 1);
        b.putUint(0);
        b.putUint(0);
        b.putUint(8);
        b.putUint(0);
        b.putUint(0);
        try req(&comp, try b.finish());
    }
    { // create_immed(10, 2x2, XR24, 0)
        var b = wire.Builder.init(&buf, 9, 3);
        b.putNewId(10);
        b.putInt(2);
        b.putInt(2);
        b.putUint(protocol.DRM_FORMAT_XRGB8888);
        b.putUint(0);
        try req(&comp, try b.finish());
    }
    // Synthetic pool under the buffer id, filled by pipe units like
    // any shm pool.
    try t.expect(comp.pools.get(10) != null);
    try t.expectEqual(@as(usize, 16), comp.pools.get(10).?.bytes.items.len);
    {
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(t.allocator);
        var px: [16]u8 = undefined;
        for (&px, 0..) |*p, i| p.* = @intCast(i + 50);
        try pipe.appendPoolUpdate(&unit, t.allocator, 10, 0, &px);
        try comp.feed(unit.items);
    }
    { // attach(10)
        var b = wire.Builder.init(&buf, 6, 1);
        b.putObject(10);
        b.putInt(0);
        b.putInt(0);
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
    try t.expectEqual(@as(u8, 50), tv.last_pixels[0]);
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    try t.expect(evs.items.len >= 1);
    try t.expectEqual([2]u32{ 10, 0 }, evs.items[0]); // wl_buffer.release

    // Non-immed create is declined with `failed` -> shm fallback.
    { // create_params(11)
        var b = wire.Builder.init(&buf, 3, 1);
        b.putNewId(11);
        try req(&comp, try b.finish());
    }
    {
        var b = wire.Builder.init(&buf, 11, 1);
        b.putUint(0);
        b.putUint(0);
        b.putUint(8);
        b.putUint(0);
        b.putUint(0);
        try req(&comp, try b.finish());
    }
    comp.clearOut();
    { // create (non-immed)
        var b = wire.Builder.init(&buf, 11, 2);
        b.putInt(2);
        b.putInt(2);
        b.putUint(protocol.DRM_FORMAT_XRGB8888);
        b.putUint(0);
        try req(&comp, try b.finish());
    }
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    try t.expectEqualSlices([2]u32, &[_][2]u32{.{ 11, 1 }}, evs.items); // failed
    try t.expect(!comp.dead);

    // Destroying the dmabuf buffer frees its synthetic pool.
    {
        var b = wire.Builder.init(&buf, 10, 0);
        try req(&comp, try b.finish());
    }
    try t.expect(comp.pools.get(10) == null);
}

test "state_sync v3: dmabuf buffer survives replica restore with pixels" {
    var tv = TestView{};
    var brain = try Compositor.init(t.allocator, tv.view());
    defer brain.deinit();
    var buf: [96]u8 = undefined;

    { // get_registry(2)
        var b = wire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try req(&brain, try b.finish());
    }
    inline for (.{
        .{ 1, "wl_compositor", 4, 3 },
        .{ 5, "xdg_wm_base", 2, 5 },
        .{ 22, "zwp_linux_dmabuf_v1", 3, 4 },
    }) |bind| {
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(bind[0]);
        b.putString(bind[1]);
        b.putUint(bind[2]);
        b.putNewId(bind[3]);
        try req(&brain, try b.finish());
    }
    { // surface(6) + xdg(7) + toplevel(8) + initial commit
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(6);
        try req(&brain, try b.finish());
        var b2 = wire.Builder.init(&buf, 5, 2);
        b2.putNewId(7);
        b2.putObject(6);
        try req(&brain, try b2.finish());
        var b3 = wire.Builder.init(&buf, 7, 1);
        b3.putNewId(8);
        try req(&brain, try b3.finish());
        var b4 = wire.Builder.init(&buf, 6, 6);
        try req(&brain, try b4.finish());
    }
    { // create_params(9) + add(plane 0, stride 8, LINEAR) + create_immed(10, 2x2 XR24)
        var b = wire.Builder.init(&buf, 4, 1);
        b.putNewId(9);
        try req(&brain, try b.finish());
        var b2 = wire.Builder.init(&buf, 9, 1);
        b2.putUint(0);
        b2.putUint(0);
        b2.putUint(8);
        b2.putUint(0);
        b2.putUint(0);
        try req(&brain, try b2.finish());
        var b3 = wire.Builder.init(&buf, 9, 3);
        b3.putNewId(10);
        b3.putInt(2);
        b3.putInt(2);
        b3.putUint(protocol.DRM_FORMAT_XRGB8888);
        b3.putUint(0);
        try req(&brain, try b3.finish());
    }
    var px: [16]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(i + 60);
    { // pixels side-band into the synthetic pool (as the daemon ships)
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(t.allocator);
        try pipe.appendPoolUpdate(&unit, t.allocator, 10, 0, &px);
        try brain.feed(unit.items);
    }
    { // attach + commit
        var b = wire.Builder.init(&buf, 6, 1);
        b.putObject(10);
        b.putInt(0);
        b.putInt(0);
        try req(&brain, try b.finish());
        var b2 = wire.Builder.init(&buf, 6, 6);
        try req(&brain, try b2.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.frames);

    const blob = try brain.serializeState(t.allocator);
    defer t.allocator.free(blob);

    // Replica: synthetic-pool units first (as replayNativeChannels
    // ships dmabuf mirrors), then state_sync.
    var tv2 = TestView{};
    var replica = try Compositor.init(t.allocator, tv2.view());
    defer replica.deinit();
    {
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(t.allocator);
        try pipe.appendPoolMeta(&units, t.allocator, .pool_create, 10, 16);
        try pipe.appendPoolUpdate(&units, t.allocator, 10, 0, &px);
        try pipe.appendUnit(&units, t.allocator, .state_sync, blob);
        try replica.feed(units.items);
    }
    try t.expectEqual(@as(usize, 1), tv2.new_count);
    try t.expectEqual(@as(usize, 1), tv2.frames);
    try t.expectEqual(@as(u8, 60), tv2.last_pixels[0]);
    try t.expect(!replica.dead);
}

test "shm pool bytes reclaim only after pool destroy AND last buffer destroy" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [96]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 2, "wl_shm", 1, 4);
    { // create_pool(9, fd, 16)
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(9);
        b.putInt(16);
        try req(&comp, try b.finish());
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
    try t.expectEqual(@as(u32, 1), comp.pools.get(9).?.buffers);

    { // wl_shm_pool.destroy(9) — buffer 10 still references the bytes
        var b = wire.Builder.init(&buf, 9, 1);
        try req(&comp, try b.finish());
    }
    try t.expect(comp.pools.get(9) != null);
    try t.expect(comp.pools.get(9).?.destroyed);

    { // wl_buffer.destroy(10) — last reference: bytes reclaim
        var b = wire.Builder.init(&buf, 10, 0);
        try req(&comp, try b.finish());
    }
    try t.expect(comp.pools.get(9) == null);

    // Reverse order: destroying a buffer-less pool reclaims at once.
    { // create_pool(11, fd, 16)
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(11);
        b.putInt(16);
        try req(&comp, try b.finish());
    }
    try t.expect(comp.pools.get(11) != null);
    { // destroy(11)
        var b = wire.Builder.init(&buf, 11, 1);
        try req(&comp, try b.finish());
    }
    try t.expect(comp.pools.get(11) == null);
    try t.expect(!comp.dead);
}

test "recycled pool id: old buffer's destroy must not reclaim the new incarnation (GTK4 Vulkan probe pools)" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [96]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 1, "wl_compositor", 4, 3);
    try bindGlobal(&comp, 2, "wl_shm", 1, 4);
    try bindGlobal(&comp, 5, "xdg_wm_base", 2, 5);

    { // create_surface(6), get_xdg_surface(7), get_toplevel(8), map
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(6);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 5, 2);
        b.putNewId(7);
        b.putObject(6);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 7, 1);
        b.putNewId(8);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 6, 6); // initial commit
        try req(&comp, try b.finish());
    }

    // Probe pool (id 9) + probe buffer 10; pool destroyed at once —
    // Vulkan WSI's format probing. Buffer 10 stays alive.
    { // create_pool(9, fd, 16)
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(9);
        b.putInt(16);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 9, 0); // create_buffer(10, 2x2)
        b.putNewId(10);
        b.putInt(0);
        b.putInt(2);
        b.putInt(2);
        b.putInt(8);
        b.putUint(1);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 9, 1); // pool destroy
        try req(&comp, try b.finish());
    }

    // Client recycles id 9 for the real 4x4 swapchain pool.
    { // create_pool(9, fd, 64) — recycled id
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(9);
        b.putInt(64);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), comp.orphan_pools.count());
    { // pool bytes via side-band update
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(t.allocator);
        var px: [64]u8 = undefined;
        for (&px, 0..) |*p, i| p.* = @intCast((i + 200) & 0xff);
        try pipe.appendPoolUpdate(&unit, t.allocator, 9, 0, &px);
        try comp.feed(unit.items);
    }
    { // create_buffer(11, 4x4), pool destroy — swapchain steady state
        var b = wire.Builder.init(&buf, 9, 0);
        b.putNewId(11);
        b.putInt(0);
        b.putInt(4);
        b.putInt(4);
        b.putInt(16);
        b.putUint(1);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 9, 1);
        try req(&comp, try b.finish());
    }

    // THE regression: destroying the probe buffer released the NEW
    // pool's refcount (same id) and reclaimed the swapchain bytes,
    // so baobab's first frame silently vanished.
    { // wl_buffer.destroy(10)
        var b = wire.Builder.init(&buf, 10, 0);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 0), comp.orphan_pools.count());
    try t.expect(comp.pools.get(9) != null);
    try t.expectEqual(@as(usize, 64), comp.pools.get(9).?.bytes.items.len);

    { // attach(11) + commit → the frame MUST reach the view
        var b = wire.Builder.init(&buf, 6, 1);
        b.putObject(11);
        b.putInt(0);
        b.putInt(0);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 6, 6);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.frames);
    try t.expectEqual(@as(i32, 4), tv.last_w);
    try t.expectEqual(@as(u8, 200), tv.last_pixels[0]);

    // state_sync v4: the still-live buffer 11 binds to the replayed
    // pool; a buffer referencing a displaced incarnation must not.
    { // fresh orphan-referencing buffer: pool 12 + buffer 13, pool
        // destroyed, id 12 recycled — buffer 13 now references the
        // orphaned incarnation.
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(12);
        b.putInt(16);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 12, 0);
        b.putNewId(13);
        b.putInt(0);
        b.putInt(2);
        b.putInt(2);
        b.putInt(8);
        b.putUint(1);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 12, 1);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(12);
        b.putInt(16);
        try req(&comp, try b.finish());
    }
    const blob = try comp.serializeState(t.allocator);
    defer t.allocator.free(blob);

    var rv = TestView{};
    var replica = try Compositor.init(t.allocator, rv.view());
    defer replica.deinit();
    replica.lenient = true;
    {
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(t.allocator);
        try pipe.appendPoolMeta(&units, t.allocator, .pool_create, 9, 64);
        try pipe.appendPoolMeta(&units, t.allocator, .pool_create, 12, 16);
        try pipe.appendUnit(&units, t.allocator, .state_sync, blob);
        try replica.feed(units.items);
    }
    // Buffer 11 bound to the replayed pool 9; buffer 13 keeps its
    // displaced incarnation's raw serial (v5) — it must not count
    // against the current pool 12 (destroying it must not free pool
    // 12), and with no replayed orphan pool it stays unresolvable.
    try t.expectEqual(@as(u32, 1), replica.pools.get(9).?.buffers);
    try t.expectEqual(replica.pools.get(9).?.serial, replica.buffers.get(11).?.pool_serial);
    try t.expectEqual(@as(u32, 0), replica.pools.get(12).?.buffers);
    try t.expectEqual(comp.buffers.get(13).?.pool_serial, replica.buffers.get(13).?.pool_serial);
    try t.expect(replica.buffers.get(13).?.pool_serial != replica.pools.get(12).?.serial);
    try t.expect(!comp.dead);
}

test "orphaned pool incarnation: serial adoption + pool_update_s keep a displaced buffer's pixels live" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [96]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 1, "wl_compositor", 4, 3);
    try bindGlobal(&comp, 2, "wl_shm", 1, 4);
    try bindGlobal(&comp, 5, "xdg_wm_base", 2, 5);

    { // surface 6 → xdg_surface 7 → toplevel 8, initial commit
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(6);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 5, 2);
        b.putNewId(7);
        b.putObject(6);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 7, 1);
        b.putNewId(8);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 6, 6);
        try req(&comp, try b.finish());
    }

    { // create_pool(9, 64) — then ADOPT the daemon's serial (7000)
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(9);
        b.putInt(64);
        try req(&comp, try b.finish());
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(t.allocator);
        try pipe.appendPoolSerial(&unit, t.allocator, 9, 7000);
        try comp.feed(unit.items);
    }
    try t.expectEqual(@as(u64, 7000), comp.pools.get(9).?.serial);

    { // create_buffer(10, 4x4) — inherits the adopted serial
        var b = wire.Builder.init(&buf, 9, 0);
        b.putNewId(10);
        b.putInt(0);
        b.putInt(4);
        b.putInt(4);
        b.putInt(16);
        b.putUint(1);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(u64, 7000), comp.buffers.get(10).?.pool_serial);

    { // destroy pool 9, recycle its id (DirectDraw mode switch)
        var b = wire.Builder.init(&buf, 9, 1);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(9);
        b.putInt(64);
        try req(&comp, try b.finish());
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(t.allocator);
        try pipe.appendPoolSerial(&unit, t.allocator, 9, 7001);
        try comp.feed(unit.items);
    }
    // Old incarnation orphaned under its ADOPTED serial.
    try t.expect(comp.orphan_pools.get(7000) != null);

    { // serial-addressed pixels land in the orphan
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(t.allocator);
        var px: [64]u8 = undefined;
        for (&px, 0..) |*p, i| p.* = @intCast((i + 40) & 0xff);
        const enc = pixcodec.Encoded{ .coder = .raw, .filter = .none, .bytes = &px };
        try pipe.appendPoolUpdateS(&unit, t.allocator, 7000, 0, enc, 64, 16);
        try comp.feed(unit.items);
    }
    try t.expectEqual(@as(u8, 40), comp.orphan_pools.get(7000).?.bytes.items[0]);

    { // attach the displaced buffer + commit → frame with the bytes
        var b = wire.Builder.init(&buf, 6, 1);
        b.putObject(10);
        b.putInt(0);
        b.putInt(0);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 6, 6);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.frames);
    try t.expectEqual(@as(u8, 40), tv.last_pixels[0]);

    // A stale serial (already released) must be skipped, not fatal.
    {
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(t.allocator);
        var px: [16]u8 = undefined;
        @memset(&px, 1);
        const enc = pixcodec.Encoded{ .coder = .raw, .filter = .none, .bytes = &px };
        try pipe.appendPoolUpdateS(&unit, t.allocator, 4242, 0, enc, 16, 16);
        try comp.feed(unit.items);
    }
    try t.expect(!comp.dead);
}

test "pool_orphan replay: v5 state_sync binds a displaced buffer to the replayed orphan" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [96]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 1, "wl_compositor", 4, 3);
    try bindGlobal(&comp, 2, "wl_shm", 1, 4);
    try bindGlobal(&comp, 5, "xdg_wm_base", 2, 5);

    { // surface 6 → toplevel 8, mapped
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(6);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 5, 2);
        b.putNewId(7);
        b.putObject(6);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 7, 1);
        b.putNewId(8);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 6, 6);
        try req(&comp, try b.finish());
    }
    { // pool 9 (serial 1) + buffer 10, pool destroyed, id recycled
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(9);
        b.putInt(64);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 9, 0);
        b.putNewId(10);
        b.putInt(0);
        b.putInt(4);
        b.putInt(4);
        b.putInt(16);
        b.putUint(1);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 9, 1);
        try req(&comp, try b.finish());
        b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(9);
        b.putInt(64);
        try req(&comp, try b.finish());
    }
    const orphan_serial = comp.buffers.get(10).?.pool_serial;
    try t.expect(comp.orphan_pools.get(orphan_serial) != null);

    const blob = try comp.serializeState(t.allocator);
    defer t.allocator.free(blob);

    var rv = TestView{};
    var replica = try Compositor.init(t.allocator, rv.view());
    defer replica.deinit();
    replica.lenient = true;
    {
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(t.allocator);
        // Daemon replay: current pool + its serial, the orphan, its
        // bytes serial-addressed, then the state blob.
        try pipe.appendPoolMeta(&units, t.allocator, .pool_create, 9, 64);
        try pipe.appendPoolSerial(&units, t.allocator, 9, comp.pools.get(9).?.serial);
        try pipe.appendPoolOrphan(&units, t.allocator, orphan_serial, 64);
        var px: [64]u8 = undefined;
        for (&px, 0..) |*p, i| p.* = @intCast((i + 90) & 0xff);
        const enc = pixcodec.Encoded{ .coder = .raw, .filter = .none, .bytes = &px };
        try pipe.appendPoolUpdateS(&units, t.allocator, orphan_serial, 0, enc, 64, 16);
        try pipe.appendUnit(&units, t.allocator, .state_sync, blob);
        try replica.feed(units.items);
    }
    // The displaced buffer resolves to the replayed orphan (refcount
    // included), and a commit renders ITS bytes.
    try t.expectEqual(orphan_serial, replica.buffers.get(10).?.pool_serial);
    try t.expectEqual(@as(u32, 1), replica.orphan_pools.get(orphan_serial).?.buffers);
    {
        var b = wire.Builder.init(&buf, 6, 1);
        b.putObject(10);
        b.putInt(0);
        b.putInt(0);
        try req(&replica, try b.finish());
        b = wire.Builder.init(&buf, 6, 6);
        try req(&replica, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), rv.frames);
    try t.expectEqual(@as(u8, 90), rv.last_pixels[0]);
}

test "zxdg_output v3: logical geometry then wl_output.done" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [96]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 23, "zxdg_output_manager_v1", 3, 3);
    try bindGlobal(&comp, 4, "wl_output", 4, 4);
    comp.clearOut();

    { // get_xdg_output(5, output 4)
        var b = wire.Builder.init(&buf, 3, 1);
        b.putNewId(5);
        b.putObject(4);
        try req(&comp, try b.finish());
    }
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    // v3 + name/description (since 2), completion via wl_output.done.
    try t.expectEqualSlices([2]u32, &[_][2]u32{
        .{ 5, 0 }, // logical_position
        .{ 5, 1 }, // logical_size
        .{ 5, 3 }, // name
        .{ 5, 4 }, // description
        .{ 4, 2 }, // wl_output.done (xdg done is deprecated at v3)
    }, evs.items);
    try t.expect(!comp.dead);
}
