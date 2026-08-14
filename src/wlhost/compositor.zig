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
const dmabuf = @import("dmabuf.zig");
const pipe = @import("pipe.zig");
const pixcodec = @import("pixcodec.zig");
const vcodec = @import("vcodec.zig");
const build_options = @import("build_options");
const native_endian = @import("builtin").cpu.arch.endian();

pub const DEFAULT_OUTPUT_WIDTH: u32 = 1920;
pub const DEFAULT_OUTPUT_HEIGHT: u32 = 1080;

/// Default pc105/us xkb keymap; alternatives in keymaps.zig, chosen
/// per session via the spawn `kb_layout` option (Compositor.keymap).
pub const us_keymap = @import("keymaps.zig").us;

pub fn removeId(list: *std.ArrayList(u32), id: u32) void {
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
    /// Whether a subsurface is stacked below its parent. This matters
    /// for toolkits such as JBR, which put the drop shadow in a larger,
    /// input-transparent subsurface below the actual toplevel.
    subsurface_below: ?*const fn (ctx: ?*anyopaque, surface: u32, below: bool) void = null,
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
    /// zxdg_imported_v2.set_parent_of — the SESSION-WIDE form of
    /// set_parent: `conn` names the connection that exported the
    /// parent toplevel (`Compositor.conn_id`; equal to this
    /// compositor's own id when both ends are one client) and
    /// `parent` is a surface id in THAT connection's space. Both zero
    /// clears the relationship.
    ///
    /// Fired by the AUTHORITATIVE brain when it resolves the import,
    /// and by a replica when the daemon replays the resolved relation
    /// as a `foreign_parent` pipe unit — a replica cannot resolve the
    /// handle itself, since handles are minted by the brain.
    toplevel_foreign_parent: ?*const fn (ctx: ?*anyopaque, surface: u32, conn: u32, parent: u32) void = null,
    /// xdg_dialog_v1 set_modal/unset_modal: the toplevel wants to
    /// block input to the rest of its (foreign or local) parent chain.
    toplevel_modal: ?*const fn (ctx: ?*anyopaque, surface: u32, modal: bool) void = null,
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

/// libc CSPRNG. Declared directly rather than through a `@cImport`
/// module so wlhost keeps its "no C bindings" property: every target
/// that compiles this file already links libc, and both glibc/musl
/// and macOS provide getentropy.
extern "c" fn getentropy(buf: [*]u8, len: usize) c_int;

/// xdg-foreign handle: 16 bytes of kernel entropy, lowercase hex.
pub const foreign_handle_len = 32;
pub const ForeignHandle = [foreign_handle_len]u8;

/// One live zxdg_exported_v2. Handles are fixed-size arrays, so an
/// entry owns no allocation and a purge can never fail.
pub const ForeignExport = struct {
    handle: ForeignHandle,
    /// Compositor (= client connection) that exported. Compositors are
    /// never moved after their first request, so the pointer is a
    /// stable client identity; every entry is purged in deinit.
    owner: *Compositor,
    /// zxdg_exported_v2 object id in the owner's id space.
    id: u32,
    /// Exported wl_surface id in the owner's id space.
    surface: u32,
};

/// One live zxdg_imported_v2. `live` goes false once `destroyed` has
/// been sent; the object itself survives until the client destroys it.
pub const ForeignImport = struct {
    handle: ForeignHandle,
    owner: *Compositor,
    /// zxdg_imported_v2 object id in the owner's id space.
    id: u32,
    /// Child wl_surface set via set_parent_of (0 = none yet).
    child: u32 = 0,
    live: bool = true,

    /// Undo whatever this import established on its child. Always
    /// reported to the owner's view: the relationship is one the view
    /// acted on whether or not the parent was the same connection.
    fn clearParent(imp: *ForeignImport) void {
        if (imp.child == 0) return;
        const child = imp.child;
        imp.child = 0;
        const surf = imp.owner.surfaces.getPtr(child) orelse return;
        if (surf.foreign_parent == 0 and surf.foreign_parent_conn == 0) return;
        surf.foreign_parent = 0;
        surf.foreign_parent_remote = false;
        surf.foreign_parent_conn = 0;
        imp.owner.emitForeignParent(child, 0, 0);
    }
};

/// The handle namespace xdg-foreign resolves against. One Compositor
/// serves exactly one client connection, so a registry shared by every
/// connection of a session is what makes cross-client import work; the
/// per-compositor fallback keeps a standalone Compositor self-contained.
pub const ForeignRegistry = struct {
    exports: std.ArrayList(ForeignExport) = .empty,
    imports: std.ArrayList(ForeignImport) = .empty,
    /// Latched from the first compositor that appends. Every sharer is
    /// expected to use the same allocator (the daemon's gpa).
    allocator: ?std.mem.Allocator = null,
    /// Called after an event was queued on a compositor OTHER than the
    /// one currently being fed — that compositor's output would
    /// otherwise sit until its own client next sends something.
    wake: ?*const fn (ctx: ?*anyopaque, comp: *Compositor) void = null,
    wake_ctx: ?*anyopaque = null,

    pub fn deinit(self: *ForeignRegistry) void {
        const a = self.allocator orelse return;
        self.exports.deinit(a);
        self.imports.deinit(a);
        self.* = .{};
    }

    fn find(self: *ForeignRegistry, handle: []const u8) ?*ForeignExport {
        if (handle.len != foreign_handle_len) return null;
        for (self.exports.items) |*e| {
            if (std.mem.eql(u8, &e.handle, handle)) return e;
        }
        return null;
    }
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

    pub fn free(self: *HostDrag, a: std.mem.Allocator) void {
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
pub const globals = [_]Global{
    // v6: surfaces get preferred_buffer_scale/transform on creation
    // (GTK4 at v6 sizes buffers from it instead of wl_output scale).
    // v7: release, so a client can drop the global without leaking a
    // server object. Adds no events.
    .{ .name = 1, .iface = &protocol.wl_compositor, .version = 7 },
    // GTK3 maps tooltips / tree-view type-ahead popups as subsurfaces;
    // without this its GdkDisplay->subcompositor is NULL and it crashes
    // (wl_proxy_get_version(NULL)) the first time it shows one.
    .{ .name = 11, .iface = &protocol.wl_subcompositor, .version = 1 },
    // v2: release (destructor only).
    .{ .name = 2, .iface = &protocol.wl_shm, .version = 2 },
    // v4: keyboards get repeat_info — held keys repeat client-side.
    // v5: pointer events are frame-grouped (JBR hard-requires >= 5
    // and binds 5 unconditionally; v5-bound clients queue pointer
    // events until the frame, so every injection emits one).
    // v8: wheel scrolls carry axis_value120.
    // v9: every axis event is preceded by axis_relative_direction.
    // v10: wl_keyboard.key may report the `repeated` state — we never
    // repeat server-side (clients do, from repeat_info), which is
    // exactly what the enum's absence means.
    .{ .name = 3, .iface = &protocol.wl_seat, .version = 10 },
    // v4: name/description events at bind.
    .{ .name = 4, .iface = &protocol.wl_output, .version = 4 },
    // v3 popup reposition; v4 configure_bounds; v5 wm_capabilities
    // (all honored in the configure/reposition paths).
    .{ .name = 5, .iface = &protocol.xdg_wm_base, .version = 6 },
    // v3 wire surface (JBR binds 3 unconditionally). Selection plus
    // WITHIN-APP dnd (start_drag drives a real drag state machine —
    // both ends are the same client, so data flows daemon-locally);
    // cross-app dnd stays out of scope.
    // v4: release (destructor only; no new offer/source/device events).
    .{ .name = 6, .iface = &protocol.wl_data_device_manager, .version = 4 },
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
    // linux-dmabuf. Format/modifier announcements come from the
    // daemon importer's capability slice; replicas restore the
    // synthetic CPU pixels. The version actually announced is
    // Compositor.dmabufVersion() — v4 only with a main DRM device.
    .{ .name = 22, .iface = &protocol.zwp_linux_dmabuf_v1, .version = 4 },
    // xdg-output: wl_output's LOGICAL geometry. SDL probes for it and
    // logs a scary "protocol missing: disabling" without it.
    .{ .name = 23, .iface = &protocol.zxdg_output_manager_v1, .version = 3 },
    // wl_registry has no destructor of its own; this is how a client
    // drops one without leaking a server object.
    .{ .name = 24, .iface = &protocol.wl_fixes, .version = 1 },
    // xdg-foreign, v2 ONLY (both unstable interfaces are at version 1).
    // GDK binds whichever of v1/v2 it sees, but picks the EXPORTER v2
    // first and the IMPORTER v1 first — so a compositor advertising
    // both must share one handle namespace between them or GTK exports
    // a v2 handle it then cannot import. Advertising v2 alone removes
    // that trap, and v2 is what GTK4 and Qt use; no toolkit here is
    // v1-only (GTK3 has no xdg-foreign at all).
    .{ .name = 25, .iface = &protocol.zxdg_exporter_v2, .version = 1 },
    .{ .name = 26, .iface = &protocol.zxdg_importer_v2, .version = 1 },
    // xdg-dialog: the only modality request in xdg-shell. Withholding
    // it does not make a dialog non-modal, it makes it unannounceable
    // — the app has no other way to say so.
    .{ .name = 27, .iface = &protocol.xdg_wm_dialog_v1, .version = 1 },
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

    pub fn deinit(self: *Pool, a: std.mem.Allocator) void {
        self.bytes.deinit(a);
        if (self.vdec) |*d| d.deinit();
    }
};

pub const Buffer = struct {
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

pub const Surface = struct {
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
    /// Effective stacking relative to the parent. Other sibling-order
    /// details are immaterial to the full-copy views, but below-parent
    /// decorations must not become independent windows.
    sub_below: bool = false,
    /// Popup placement (parent surface coords) from the positioner.
    parent: u32 = 0,
    px: i32 = 0,
    py: i32 = 0,
    pw: i32 = 0,
    ph: i32 = 0,
    /// wl_callback ids awaiting frame done.
    frame_cbs: std.ArrayList(u32) = .empty,
    /// wl_surface.get_release callbacks (v7): double-buffered state
    /// bound to the pending buffer, fired with the wl_buffer.release
    /// of the commit that consumed it.
    release_cbs: std.ArrayList(u32) = .empty,
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
    /// zxdg_imported_v2.set_parent_of: the exported wl_surface id, in
    /// the EXPORTING client's id space (0 = none). It equals tl_parent
    /// when the exporter is this same connection; otherwise it names a
    /// surface this compositor cannot address.
    foreign_parent: u32 = 0,
    /// True when `foreign_parent` lives in another client connection.
    foreign_parent_remote: bool = false,
    /// Connection that owns `foreign_parent` (`Compositor.conn_id`).
    foreign_parent_conn: u32 = 0,
    /// xdg_dialog_v1.set_modal is in effect for this toplevel.
    modal: bool = false,

    pub fn freeOwned(self: *Surface, a: std.mem.Allocator) void {
        self.frame_cbs.deinit(a);
        self.release_cbs.deinit(a);
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
    pub fn place(p: *const Positioner) [2]i32 {
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
    /// Virtual output mode in physical pixels. Display sessions may
    /// override this; ordinary forwarded sessions keep the defaults.
    output_width: u32 = DEFAULT_OUTPUT_WIDTH,
    output_height: u32 = DEFAULT_OUTPUT_HEIGHT,
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
    dmabuf_params: std.AutoHashMapUnmanaged(u32, dmabuf.Params) = .empty,
    /// Live zwp_linux_dmabuf_feedback_v1 objects (v4). Value = the
    /// wl_surface a per-surface feedback was requested for, 0 for the
    /// default feedback; we answer both with the same tranche, but a
    /// re-send on capability change would need the distinction.
    dmabuf_feedbacks: std.AutoHashMapUnmanaged(u32, u32) = .empty,
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
    /// Version of the LAST wl_seat bind — the fallback for devices
    /// whose own seat is unknown (state_sync restore).
    seat_version: u32 = 1,
    /// Interface version per bound object id. A client may bind the
    /// SAME global at DIFFERENT versions (Firefox binds wl_seat at
    /// both v5 and v8, from separate registries) and every event has
    /// to be gated against the version of the object it goes to — a
    /// v8-only event on a v5 wl_pointer hits a NULL listener slot and
    /// aborts the client outright. Seat devices inherit their seat's
    /// version at get_pointer/get_keyboard/get_touch.
    obj_versions: std.AutoHashMapUnmanaged(u32, u32) = .empty,
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
    /// Format/modifier pairs announced at bind and accepted by the
    /// authoritative brain. Replicas deliberately ignore this policy.
    dmabuf_capabilities: []const dmabuf.Capability = &dmabuf.linear_capabilities,
    /// dev_t of the DRM node clients should allocate on, as the v4
    /// feedback `main_device`. Zero = unknown, which caps the
    /// advertised linux-dmabuf at v3: a v4 client that gets no usable
    /// main device has nowhere to allocate from. The daemon resolves
    /// it (mux/drmdev.zig) on the APP's host, which is also the
    /// importer's host, so it is always a device the app can open.
    dmabuf_main_device: u64 = 0,
    /// The app actually created a v4 feedback object. Only then does
    /// the request stream contain something a pre-v8 replica cannot
    /// parse — advertising v4 costs nothing to a client that never
    /// uses it, so the viewer gate keys on this, not on the
    /// announcement.
    used_dmabuf_feedback: bool = false,
    /// The app used a request added after the state-sync v8 tables
    /// (wl_compositor/wl_shm/wl_data_device_manager release,
    /// wl_fixes, wl_surface.get_release). Same purpose as
    /// `used_dmabuf_feedback`, one version later.
    used_post_v8_request: bool = false,
    /// The app bound an xdg-foreign global. Same viewer gate as
    /// `used_post_v8_request`: a replica whose tables predate
    /// zxdg_exporter_v2 cannot even parse the bind, let alone restore
    /// a state blob naming the interface.
    used_foreign: bool = false,
    /// The app bound xdg_wm_dialog_v1. Same viewer gate again, one
    /// version later: a v10 replica's tables have neither
    /// xdg_wm_dialog_v1 nor xdg_dialog_v1, so the bind alone is fatal
    /// there and a state blob naming either interface is unrestorable.
    used_dialog: bool = false,
    /// Identifies this connection inside its session. The daemon sets
    /// it to the app channel's id, which is the SAME number the viewer
    /// knows the channel by — so it doubles as the connection half of
    /// a session-wide window identity (conn_id, surface id). Zero on a
    /// standalone compositor.
    conn_id: u32 = 0,
    /// Live xdg_dialog_v1 objects: object id -> the surface it wraps.
    dialogs: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Handle namespace for xdg-foreign. Left null, every compositor
    /// exports into its own `foreign_local` and only its own client can
    /// import — pointing every connection of a session at one shared
    /// registry is what makes cross-client parenting resolve.
    foreign_shared: ?*ForeignRegistry = null,
    foreign_local: ForeignRegistry = .{},
    /// The daemon brain tracks pool identity but has no pixel consumer;
    /// replicas retain the default and allocate their renderable copy.
    materialize_dmabuf_pools: bool = true,
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
    pub fn freshPool(self: *Compositor, id: u32, size: usize) Error!*Pool {
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
    pub fn poolFor(self: *Compositor, info: Buffer) ?*Pool {
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
    pub fn releaseBufferRef(self: *Compositor, info: Buffer) void {
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
        // Before anything else: a client that exited without destroying
        // its objects still owes every importer a `destroyed`, and the
        // sends below need this compositor's queue to still exist.
        self.foreignPurgeClient();
        self.foreign_local.deinit();
        self.dialogs.deinit(a);
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
        self.dmabuf_feedbacks.deinit(a);
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
        self.obj_versions.deinit(a);
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
    /// Interface version an object was bound/created at (falls back to
    /// the last wl_seat bind for devices restored from a state_sync,
    /// which carries no per-object versions).
    pub fn objVersion(self: *const Compositor, id: u32) u32 {
        return self.obj_versions.get(id) orelse self.seat_version;
    }

    /// A child object speaks the version of the object that made it.
    pub fn inheritVersion(self: *Compositor, id: u32, parent: u32) Error!void {
        self.obj_versions.put(self.allocator, id, self.objVersion(parent)) catch
            return Error.OutOfMemory;
    }

    pub fn pointerAxis(self: *Compositor, axis: u32, value: f64, value120: i32) Error!void {
        if (self.pointer_focus == 0 or self.drag.active) return;
        for (self.pointers.items) |p| {
            const pv = self.objVersion(p);
            // v9 guarantees each axis_relative_direction is followed
            // by exactly one axis event for the same axis inside the
            // frame, so it goes FIRST. Injected scroll is never
            // natural-scroll inverted: always `identical`.
            if (pv >= 9) {
                var rbuf: [16]u8 = undefined;
                var rb = wire.Builder.init(&rbuf, p, 10); // axis_relative_direction
                rb.putUint(axis);
                rb.putUint(0); // identical
                try self.send(try rb.finish());
            }
            if (value120 != 0) {
                if (pv >= 8) {
                    var vbuf: [16]u8 = undefined;
                    var vb = wire.Builder.init(&vbuf, p, 9); // axis_value120
                    vb.putUint(axis);
                    vb.putInt(value120);
                    try self.send(try vb.finish());
                } else if (pv >= 5) {
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
        if (self.objVersion(p) < 5) return;
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
    pub fn activateConstraints(self: *Compositor, sid: u32) Error!void {
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
    pub fn bestTextMime(self: *Compositor, source: u32) ?[]const u8 {
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
    pub fn offerToDevice(self: *Compositor, dev: u32, mime: []const u8, control: bool) Error!void {
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

    pub fn dragEnter(self: *Compositor, sid: u32, x: f64, y: f64) Error!void {
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

    pub fn dragLeave(self: *Compositor) Error!void {
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
    pub fn dragDrop(self: *Compositor) Error!void {
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
            // …and then LEAVE. The drag-and-drop session ends at the
            // drop even though the OFFER stays valid until the client
            // finishes reading it, and a toolkit binds its drop object
            // to that session: without the leave, GTK still holds the
            // finished drop when the next drag's enter arrives, warns
            // ("self->drop == crossing->drop"), and silently delivers no
            // motion to any drop target — the second drag of a session
            // could never be dropped anywhere. Weston and mutter both
            // send it; this replica did not.
            for (self.data_devices.items) |dev| {
                var buf: [8]u8 = undefined;
                var b = wire.Builder.init(&buf, dev, 2); // leave
                try self.send(try b.finish());
            }
            self.drag.focus = 0;
            self.drag.accepted = false;
            self.drag.action = 0;
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

    /// Reports whether this client currently owns any xdg toplevels.
    pub fn hasToplevels(self: *const Compositor) bool {
        var it = self.surfaces.valueIterator();
        while (it.next()) |surface| if (surface.toplevel != 0) return true;
        return false;
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
            .foreign_parent => {
                // The brain's resolved answer, which a replica cannot
                // compute: record it on the surface (so a later
                // serialize/inspect agrees) and hand the view the
                // session-wide (connection, surface) identity.
                if (payload.len >= 12) {
                    const sid = std.mem.readInt(u32, payload[0..4], .little);
                    const conn = std.mem.readInt(u32, payload[4..8], .little);
                    const parent = std.mem.readInt(u32, payload[8..12], .little);
                    if (self.surfaces.getPtr(sid)) |surf| {
                        surf.foreign_parent = parent;
                        surf.foreign_parent_conn = conn;
                        surf.foreign_parent_remote = conn != self.conn_id;
                    }
                    if (self.view.toplevel_foreign_parent) |cb| cb(self.view.ctx, sid, conn, parent);
                }
            },
            else => {}, // forward compat
        }
    }

    // ── Request dispatch: split out to requests.zig ──
    const requests_mod = @import("requests.zig");
    const request = requests_mod.request;
    const surfaceRequest = requests_mod.surfaceRequest;
    const xdgSurfaceRequest = requests_mod.xdgSurfaceRequest;
    const toplevelRequest = requests_mod.toplevelRequest;
    const commit = requests_mod.commit;
    const pushFrame = requests_mod.pushFrame;

    // ── surface-tree queries (renderer-facing) ──────────────────
    // A window is a TREE: the root surface's own buffer plus every
    // subsurface descendant. Firefox/Camoufox is the extreme case —
    // the xdg_toplevel surface only ever carries the CSD background,
    // and 100% of the chrome and page content lives in one
    // desync'd subsurface that the client attaches to forever after.
    // A renderer that presents only the root buffer therefore shows
    // a single flat frame and never updates again.

    /// One subsurface layer of a window tree, placeable directly in
    /// root-local coordinates.
    pub const SubLayer = struct {
        sid: u32,
        /// Offset from the ROOT surface's origin (offsets accumulate
        /// down the tree).
        x: i32,
        y: i32,
        /// Paint BEFORE the root's own buffer (stacked below the
        /// parent). Inherited from the topmost ancestor's placement.
        below: bool,
    };

    /// Cycle guard for the recursive tree walks: a malicious or
    /// confused client cannot make us recurse without bound.
    const max_sub_depth = 16;

    /// Count of leading `below` entries in a `subtreeLayers` result
    /// (the group painted before the root's own buffer).
    pub fn belowCount(layers: []const SubLayer) usize {
        var n: usize = 0;
        while (n < layers.len and layers[n].below) n += 1;
        return n;
    }

    /// Subsurface descendants of `root` in PAINT order (bottom to
    /// top): every `below` layer first, then the caller paints the
    /// root's own buffer, then the remainder.
    ///
    /// Siblings order by surface id — Wayland ids are handed out in
    /// increasing creation order, so that is creation order in
    /// practice. `wl_subsurface.place_above`/`place_below` against a
    /// SIBLING (rather than the parent) is not modeled.
    pub fn subtreeLayers(
        self: *const Compositor,
        a: std.mem.Allocator,
        root: u32,
        out: *std.ArrayList(SubLayer),
    ) Error!void {
        var tree: std.ArrayList(SubLayer) = .empty;
        defer tree.deinit(a);
        try self.collectSubLayers(a, root, 0, 0, null, 0, &tree);
        // Paint order: the below-parent group first, each group in
        // tree order (no reliance on sort stability).
        for (tree.items) |l| if (l.below)
            out.append(a, l) catch return Error.OutOfMemory;
        for (tree.items) |l| if (!l.below)
            out.append(a, l) catch return Error.OutOfMemory;
    }

    fn collectSubLayers(
        self: *const Compositor,
        a: std.mem.Allocator,
        parent: u32,
        base_x: i32,
        base_y: i32,
        group_below: ?bool,
        depth: u32,
        out: *std.ArrayList(SubLayer),
    ) Error!void {
        if (depth >= max_sub_depth) return;
        // Direct children, sorted by sid (= creation order).
        var kids: std.ArrayList(u32) = .empty;
        defer kids.deinit(a);
        var it = self.surfaces.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.subparent == parent and e.key_ptr.* != parent)
                kids.append(a, e.key_ptr.*) catch return Error.OutOfMemory;
        }
        std.mem.sort(u32, kids.items, {}, std.sort.asc(u32));
        for (kids.items) |sid| {
            const s = self.surfaces.getPtr(sid) orelse continue;
            const below = group_below orelse s.sub_below;
            const x = base_x + s.sub_x;
            const y = base_y + s.sub_y;
            out.append(a, .{ .sid = sid, .x = x, .y = y, .below = below }) catch
                return Error.OutOfMemory;
            try self.collectSubLayers(a, sid, x, y, below, depth + 1, out);
        }
    }

    /// The root of `sid`'s surface tree: `sid` itself unless it is a
    /// subsurface, in which case the topmost non-subsurface ancestor
    /// (the toplevel or popup whose window it is part of).
    pub fn rootSurface(self: *const Compositor, sid: u32) u32 {
        var cur = sid;
        var depth: u32 = 0;
        while (depth < max_sub_depth) : (depth += 1) {
            const s = self.surfaces.getPtr(cur) orelse return cur;
            if (s.subparent == 0 or s.subparent == cur) return cur;
            cur = s.subparent;
        }
        return cur;
    }

    /// A surface's LOGICAL extent (what its offsets and input region
    /// are expressed in): the viewport destination when set, else the
    /// committed buffer size divided by the buffer scale. Null when
    /// the surface has no content (unmapped).
    pub fn surfaceExtent(self: *const Compositor, sid: u32) ?struct { w: i32, h: i32 } {
        const s = self.surfaces.getPtr(sid) orelse return null;
        if (s.vp_w > 0 and s.vp_h > 0) return .{ .w = s.vp_w, .h = s.vp_h };
        if (s.committed_buffer == 0) return null;
        const info = self.buffers.get(s.committed_buffer) orelse return null;
        const scale = @max(1, s.buffer_scale);
        return .{ .w = @divTrunc(info.width, scale), .h = @divTrunc(info.height, scale) };
    }

    /// Whether `sid` accepts pointer input at the surface-local point
    /// (inside its extent AND its committed input region).
    fn acceptsInput(self: *const Compositor, sid: u32, x: f64, y: f64) bool {
        const ext = self.surfaceExtent(sid) orelse return false;
        if (x < 0 or y < 0) return false;
        if (x >= @as(f64, @floatFromInt(ext.w)) or y >= @as(f64, @floatFromInt(ext.h))) return false;
        const s = self.surfaces.getPtr(sid) orelse return false;
        if (s.input_whole) return true;
        for (s.input_rects.items) |r| {
            const fx = @as(f64, @floatFromInt(r.x));
            const fy = @as(f64, @floatFromInt(r.y));
            if (x >= fx and y >= fy and
                x < fx + @as(f64, @floatFromInt(r.w)) and
                y < fy + @as(f64, @floatFromInt(r.h))) return true;
        }
        return false;
    }

    /// Where a pointer at `root`-local (`x`,`y`) actually lands.
    pub const Hit = struct { sid: u32, x: f64, y: f64 };

    /// Topmost input-accepting surface of `root`'s tree under the
    /// point, with the point translated into that surface's own
    /// coordinate space. Falls back to `root` unchanged when nothing
    /// (not even the root) claims the point — a caller must always
    /// get a deliverable target, never a dropped event.
    pub fn hitTest(self: *const Compositor, a: std.mem.Allocator, root: u32, x: f64, y: f64) Hit {
        const fallback = Hit{ .sid = root, .x = x, .y = y };
        var layers: std.ArrayList(SubLayer) = .empty;
        defer layers.deinit(a);
        self.subtreeLayers(a, root, &layers) catch return fallback;
        // Top to bottom: above-parent layers (reverse paint order),
        // then the root itself, then the below-parent layers.
        const n_below = belowCount(layers.items);
        var i = layers.items.len;
        while (i > n_below) {
            i -= 1;
            const l = layers.items[i];
            const lx = x - @as(f64, @floatFromInt(l.x));
            const ly = y - @as(f64, @floatFromInt(l.y));
            if (self.acceptsInput(l.sid, lx, ly)) return .{ .sid = l.sid, .x = lx, .y = ly };
        }
        if (self.acceptsInput(root, x, y)) return fallback;
        var j = n_below;
        while (j > 0) {
            j -= 1;
            const l = layers.items[j];
            const lx = x - @as(f64, @floatFromInt(l.x));
            const ly = y - @as(f64, @floatFromInt(l.y));
            if (self.acceptsInput(l.sid, lx, ly)) return .{ .sid = l.sid, .x = lx, .y = ly };
        }
        return fallback;
    }

    /// The effective display scale × 120 (fractional-scale wire unit).
    pub fn effScale120(self: *const Compositor) u32 {
        if (self.scale120 != 0) return self.scale120;
        return @intCast(self.output_scale * 120);
    }

    /// Virtual output dimensions in logical coordinates at the current scale.
    pub fn logicalOutputSize(self: *const Compositor) [2]i32 {
        const s120 = @max(120, self.effScale120());
        return .{
            @intCast(@max(1, @as(u64, self.output_width) * 120 / s120)),
            @intCast(@max(1, @as(u64, self.output_height) * 120 / s120)),
        };
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

    /// Announce an xdg_output's logical geometry at the effective scale.
    pub fn sendXdgOutputState(self: *Compositor, id: u32) Error!void {
        const logical = self.logicalOutputSize();
        var pbuf: [24]u8 = undefined;
        var pb = wire.Builder.init(&pbuf, id, 0); // logical_position
        pb.putInt(0);
        pb.putInt(0);
        try self.send(try pb.finish());
        var sbuf: [24]u8 = undefined;
        var sb = wire.Builder.init(&sbuf, id, 1); // logical_size
        sb.putInt(logical[0]);
        sb.putInt(logical[1]);
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

    /// linux-dmabuf version this compositor may announce. v4's
    /// feedback events are only answerable with a main DRM device.
    pub fn dmabufVersion(self: *const Compositor) u32 {
        if (self.dmabuf_main_device == 0) return 3;
        // An empty format table is not a legal feedback answer, and
        // a v4 client has no other way to learn our formats.
        if (dmabuf.tableEntryCount(self.dmabuf_capabilities) == 0) return 3;
        return 4;
    }

    /// Register a v4 feedback object and answer it once. Feedback is
    /// static here: the capability set is fixed for the session, so
    /// there is never a second `done` (the protocol allows re-sends
    /// but does not require them).
    pub fn newDmabufFeedback(self: *Compositor, id: u32, surface: u32) Error!void {
        try self.register(id, &protocol.zwp_linux_dmabuf_feedback_v1);
        // Latched, never cleared: a replica that cannot parse this
        // request must stay excluded for the rest of the session,
        // even after the app drops the object again.
        self.used_dmabuf_feedback = true;
        try self.dmabuf_feedbacks.put(self.allocator, id, surface);
        // Replica output is discarded by the viewer; only the
        // authoritative brain answers the app.
        if (self.lenient) return;
        try self.sendDmabufFeedback(id);
    }

    fn sendDmabufFeedback(self: *Compositor, id: u32) Error!void {
        var table: std.ArrayList(u8) = .empty;
        defer table.deinit(self.allocator);
        try dmabuf.appendFormatTable(self.allocator, &table, self.dmabuf_capabilities);
        const entries: u32 = @intCast(table.items.len / dmabuf.table_entry_size);

        // format_table carries an fd, so it rides a side-band unit
        // the daemon materializes (see pipe.Tag.dmabuf_feedback).
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(self.allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, id, .little);
        try unit.appendSlice(self.allocator, &idb);
        try unit.appendSlice(self.allocator, table.items);
        try pipe.appendUnit(&self.out, self.allocator, .dmabuf_feedback, unit.items);

        var dev: [8]u8 = undefined;
        std.mem.writeInt(u64, &dev, self.dmabuf_main_device, native_endian);
        var mbuf: [24]u8 = undefined;
        var mb = wire.Builder.init(&mbuf, id, 2); // main_device
        mb.putArray(&dev);
        try self.send(try mb.finish());

        // One tranche: everything we can import, from the same
        // device, with no scanout promise.
        var tbuf: [24]u8 = undefined;
        var tb = wire.Builder.init(&tbuf, id, 4); // tranche_target_device
        tb.putArray(&dev);
        try self.send(try tb.finish());

        const indices = try self.allocator.alloc(u8, entries * 2);
        defer self.allocator.free(indices);
        for (0..entries) |i| {
            std.mem.writeInt(u16, indices[i * 2 ..][0..2], @intCast(i), native_endian);
        }
        const fmt_msg = try self.allocator.alloc(u8, wire.header_size + 4 + ((indices.len + 3) & ~@as(usize, 3)));
        defer self.allocator.free(fmt_msg);
        var fb = wire.Builder.init(fmt_msg, id, 5); // tranche_formats
        fb.putArray(indices);
        try self.send(try fb.finish());

        var flbuf: [16]u8 = undefined;
        var flb = wire.Builder.init(&flbuf, id, 6); // tranche_flags
        flb.putUint(0);
        try self.send(try flb.finish());

        var tdbuf: [8]u8 = undefined;
        var tdb = wire.Builder.init(&tdbuf, id, 3); // tranche_done
        try self.send(try tdb.finish());

        var dbuf: [8]u8 = undefined;
        var db = wire.Builder.init(&dbuf, id, 0); // done
        try self.send(try db.finish());
    }

    pub fn boundGlobal(self: *Compositor, id: u32, iface: *const protocol.Interface, ver: u32) Error!void {
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
            // v4 deprecates both announcements: the spec forbids
            // sending them, and the client waits for feedback instead.
            if (ver >= 4) return;
            for (self.dmabuf_capabilities, 0..) |capability, i| {
                if (ver < 3) {
                    // Pre-v3 clients cannot name an explicit modifier.
                    if (capability.modifier != dmabuf.DRM_FORMAT_MOD_INVALID) continue;
                    var format_seen = false;
                    for (self.dmabuf_capabilities[0..i]) |prior| {
                        format_seen = format_seen or (prior.format == capability.format and
                            prior.modifier == dmabuf.DRM_FORMAT_MOD_INVALID);
                    }
                    if (format_seen) continue;
                    var fbuf: [16]u8 = undefined;
                    var fb = wire.Builder.init(&fbuf, id, 0); // format (legacy)
                    fb.putUint(capability.format);
                    try self.send(try fb.finish());
                    continue;
                }

                var pair_seen = false;
                for (self.dmabuf_capabilities[0..i]) |prior| {
                    pair_seen = pair_seen or (prior.format == capability.format and
                        prior.modifier == capability.modifier);
                }
                if (pair_seen) continue;
                var mbuf: [24]u8 = undefined;
                var mb = wire.Builder.init(&mbuf, id, 1); // modifier
                mb.putUint(capability.format);
                mb.putUint(@truncate(capability.modifier >> 32));
                mb.putUint(@truncate(capability.modifier));
                try self.send(try mb.finish());
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
            m.putInt(@intCast(self.output_width));
            m.putInt(@intCast(self.output_height));
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

    pub fn register(self: *Compositor, id: u32, iface: *const protocol.Interface) Error!void {
        if (id == 0) return Error.Protocol;
        const slot = try self.objects.getOrPut(self.allocator, id);
        if (slot.found_existing) return Error.Protocol;
        slot.value_ptr.* = iface;
    }

    /// Remove a destroyed object and confirm to the client so it
    /// can reuse the id.
    pub fn destroyObject(self: *Compositor, id: u32) Error!void {
        _ = self.objects.remove(id);
        try self.deleteId(id);
    }

    pub fn deleteId(self: *Compositor, id: u32) Error!void {
        _ = self.objects.remove(id);
        _ = self.obj_versions.remove(id);
        var buf: [16]u8 = undefined;
        var b = wire.Builder.init(&buf, 1, 1); // wl_display.delete_id
        b.putUint(id);
        try self.send(try b.finish());
    }

    pub fn notifyGone(self: *Compositor, sid: u32) void {
        self.foreignSurfaceGone(sid);
        self.dialogSurfaceGone(sid);
        if (self.view.toplevel_gone) |cb| cb(self.view.ctx, sid);
    }

    // ── xdg-foreign v2 ──────────────────────────────────────────
    // The registry may be shared by every connection of a session, so
    // these run against `foreignReg()`, never against a private map,
    // and every event is addressed to the entry's OWN compositor.

    pub fn foreignReg(self: *Compositor) *ForeignRegistry {
        return self.foreign_shared orelse &self.foreign_local;
    }

    /// 16 bytes of kernel entropy as lowercase hex. Unguessable is the
    /// point: a handle is the only capability needed to parent a window
    /// onto someone else's toplevel, and it travels over D-Bus where an
    /// unrelated peer may observe the traffic. A counter would be
    /// trivially forgeable. getentropy cannot fail for 16 bytes on a
    /// live kernel; the mix below only exists so a hypothetical failure
    /// degrades to "still unique" instead of "all-zero handle".
    fn mintHandle(self: *Compositor) ForeignHandle {
        var raw: [16]u8 = undefined;
        if (getentropy(&raw, raw.len) != 0) {
            var seed: u64 = @intFromPtr(self) ^ (@as(u64, self.serial) << 32) ^ self.pool_serial_ctr;
            for (0..2) |i| {
                seed +%= 0x9e3779b97f4a7c15;
                var z = seed;
                z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
                z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
                z ^= z >> 31;
                std.mem.writeInt(u64, raw[i * 8 ..][0..8], z, .little);
            }
        }
        var out: ForeignHandle = undefined;
        const hex = "0123456789abcdef";
        for (raw, 0..) |byte, i| {
            out[i * 2] = hex[byte >> 4];
            out[i * 2 + 1] = hex[byte & 0xf];
        }
        return out;
    }

    /// zxdg_exporter_v2.export_toplevel. `exported` is already
    /// registered; the handle event goes out immediately, per spec.
    pub fn exportToplevel(self: *Compositor, exported: u32, sid: u32) Error!void {
        const is_toplevel = if (self.surfaces.get(sid)) |s| s.toplevel != 0 else false;
        if (!is_toplevel) {
            // zxdg_exporter_v2.error.invalid_surface. Replicas re-parse
            // an authoritative stream and must not judge it.
            if (self.lenient) return;
            return self.fatalCode(exported, 0, "zxdg_exporter_v2.export_toplevel: not an xdg_toplevel");
        }
        const reg = self.foreignReg();
        if (reg.allocator == null) reg.allocator = self.allocator;
        var handle = self.mintHandle();
        // Collision is a ~2^-128 event; retrying is cheaper than
        // reasoning about what a duplicate would mean.
        while (reg.find(&handle) != null) handle = self.mintHandle();
        try reg.exports.append(reg.allocator.?, .{
            .handle = handle,
            .owner = self,
            .id = exported,
            .surface = sid,
        });
        // A handle the client never learned would sit in the registry
        // until its object died; drop it with the failed send instead.
        errdefer _ = reg.exports.pop();
        const cap = wire.header_size + 4 + ((foreign_handle_len + 1 + 3) & ~@as(usize, 3));
        var buf: [cap]u8 = undefined;
        var b = wire.Builder.init(&buf, exported, 0); // handle
        b.putString(&handle);
        try self.send(try b.finish());
    }

    /// zxdg_importer_v2.import_toplevel. An unknown (or already
    /// revoked) handle is answered with `destroyed` right away — the
    /// object stays alive and inert until the client destroys it.
    pub fn importToplevel(self: *Compositor, imported: u32, handle: []const u8) Error!void {
        const reg = self.foreignReg();
        if (reg.allocator == null) reg.allocator = self.allocator;
        const known = reg.find(handle) != null;
        var entry = ForeignImport{
            .handle = undefined,
            .owner = self,
            .id = imported,
            .live = known,
        };
        if (known) {
            @memcpy(&entry.handle, handle[0..foreign_handle_len]);
        } else {
            @memset(&entry.handle, 0);
        }
        try reg.imports.append(reg.allocator.?, entry);
        if (!known) try self.sendImportDestroyed(imported);
    }

    fn sendImportDestroyed(self: *Compositor, imported: u32) Error!void {
        var buf: [8]u8 = undefined;
        var b = wire.Builder.init(&buf, imported, 0); // destroyed
        try self.send(try b.finish());
    }

    /// Report a foreign parent relation to the view. Silent on a
    /// replica: a replica cannot mint or resolve handles (they are the
    /// brain's entropy), so its own import bookkeeping is meaningless
    /// and the authoritative answer arrives as a `foreign_parent` pipe
    /// unit instead, which lands in `feedUnit`.
    fn emitForeignParent(self: *Compositor, child: u32, conn: u32, parent: u32) void {
        if (self.lenient) return;
        if (self.view.toplevel_foreign_parent) |cb| cb(self.view.ctx, child, conn, parent);
    }

    /// zxdg_imported_v2.set_parent_of. One path for both cases: the
    /// relation is recorded as `Surface.foreign_parent` plus the
    /// exporting connection's id and reported through
    /// `toplevel_foreign_parent`, whether or not the exporter is this
    /// same client. `Surface.tl_parent` stays reserved for
    /// xdg_toplevel.set_parent, so the two mechanisms never fight over
    /// one field.
    pub fn importedSetParentOf(self: *Compositor, imported: u32, child: u32) Error!void {
        const child_is_toplevel = if (self.surfaces.get(child)) |s| s.toplevel != 0 else false;
        if (!child_is_toplevel) {
            // zxdg_imported_v2.error.invalid_surface.
            if (self.lenient) return;
            return self.fatalCode(imported, 0, "zxdg_imported_v2.set_parent_of: not an xdg_toplevel");
        }
        const reg = self.foreignReg();
        var slot: ?*ForeignImport = null;
        for (reg.imports.items) |*imp| {
            if (imp.owner == self and imp.id == imported) slot = imp;
        }
        const imp = slot orelse return;
        // A dead import's relationship is invalid by definition.
        if (!imp.live) return;
        const exp = reg.find(&imp.handle) orelse return;
        imp.child = child;
        const surf = self.surfaces.getPtr(child) orelse return;
        surf.foreign_parent = exp.surface;
        surf.foreign_parent_remote = exp.owner != self;
        surf.foreign_parent_conn = exp.owner.conn_id;
        self.emitForeignParent(child, exp.owner.conn_id, exp.surface);
    }

    /// Revoke an export: every importer holding the handle is told
    /// `destroyed` and loses its relationship. Used by
    /// zxdg_exported_v2.destroy, by the exported surface dying, and by
    /// the exporting client disappearing.
    fn revokeExport(self: *Compositor, idx: usize) void {
        const reg = self.foreignReg();
        const handle = reg.exports.items[idx].handle;
        _ = reg.exports.swapRemove(idx);
        for (reg.imports.items) |*imp| {
            if (!imp.live or !std.mem.eql(u8, &imp.handle, &handle)) continue;
            imp.live = false;
            imp.clearParent();
            imp.owner.sendImportDestroyed(imp.id) catch {};
            // The importing client is a different connection whose
            // queue nobody is about to drain.
            if (imp.owner != self) {
                if (reg.wake) |w| w(reg.wake_ctx, imp.owner);
            }
        }
    }

    /// zxdg_exported_v2.destroy.
    pub fn dropExport(self: *Compositor, exported: u32) void {
        const reg = self.foreignReg();
        var i = reg.exports.items.len;
        while (i > 0) {
            i -= 1;
            const e = reg.exports.items[i];
            if (e.owner == self and e.id == exported) self.revokeExport(i);
        }
    }

    /// zxdg_imported_v2.destroy.
    pub fn dropImport(self: *Compositor, imported: u32) void {
        const reg = self.foreignReg();
        var i = reg.imports.items.len;
        while (i > 0) {
            i -= 1;
            const imp = &reg.imports.items[i];
            if (imp.owner != self or imp.id != imported) continue;
            imp.clearParent();
            _ = reg.imports.swapRemove(i);
        }
    }

    /// A toplevel (or its surface) went away: exports of it are
    /// revoked, and imports parented ONTO it forget their child.
    fn foreignSurfaceGone(self: *Compositor, sid: u32) void {
        const reg = self.foreignReg();
        var i = reg.exports.items.len;
        while (i > 0) {
            i -= 1;
            const e = reg.exports.items[i];
            if (e.owner == self and e.surface == sid) self.revokeExport(i);
        }
        for (reg.imports.items) |*imp| {
            if (imp.owner == self and imp.child == sid) imp.child = 0;
        }
    }

    /// Drop everything this client owns. Called from deinit, so it
    /// covers a client that exited without destroying a single object.
    fn foreignPurgeClient(self: *Compositor) void {
        const reg = self.foreignReg();
        var i = reg.exports.items.len;
        while (i > 0) {
            i -= 1;
            if (reg.exports.items[i].owner == self) self.revokeExport(i);
        }
        i = reg.imports.items.len;
        while (i > 0) {
            i -= 1;
            if (reg.imports.items[i].owner != self) continue;
            // No clearParent: our own surfaces are going away
            // with us, and a cross-client child is never ours.
            _ = reg.imports.swapRemove(i);
        }
    }

    // ── xdg-dialog v1 ───────────────────────────────────────────

    /// xdg_wm_dialog_v1.get_xdg_dialog. `toplevel` is an xdg_toplevel
    /// object id; the dialog object is bound to the surface behind it.
    pub fn dialogCreate(self: *Compositor, id: u32, toplevel: u32) Error!void {
        const sid = self.xdg_map.get(toplevel) orelse {
            // The toplevel must exist per spec; a replica re-parsing an
            // authoritative stream still tracks the object so the id
            // space stays in step.
            if (self.lenient) return;
            return Error.Protocol;
        };
        try self.dialogs.put(self.allocator, id, sid);
    }

    /// xdg_dialog_v1.set_modal / unset_modal.
    pub fn dialogSetModal(self: *Compositor, id: u32, modal: bool) void {
        const sid = self.dialogs.get(id) orelse return;
        const surf = self.surfaces.getPtr(sid) orelse return;
        if (surf.modal == modal) return;
        surf.modal = modal;
        if (self.view.toplevel_modal) |cb| cb(self.view.ctx, sid, modal);
    }

    /// xdg_dialog_v1.destroy — modality dies with the object.
    pub fn dialogDrop(self: *Compositor, id: u32) void {
        const entry = self.dialogs.fetchRemove(id) orelse return;
        self.dialogSetModalSurface(entry.value, false);
    }

    /// A surface lost its dialog object (or its toplevel role).
    fn dialogSetModalSurface(self: *Compositor, sid: u32, modal: bool) void {
        const surf = self.surfaces.getPtr(sid) orelse return;
        if (surf.modal == modal) return;
        surf.modal = modal;
        if (self.view.toplevel_modal) |cb| cb(self.view.ctx, sid, modal);
    }

    /// Drop any dialog object bound to a dying surface.
    fn dialogSurfaceGone(self: *Compositor, sid: u32) void {
        var it = self.dialogs.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == sid) e.value_ptr.* = 0;
        }
    }

    pub fn nextSerial(self: *Compositor) u32 {
        self.serial +%= 1;
        return self.serial;
    }

    /// destroyObject for a request that did not exist in the protocol
    /// tables shipped with state-sync v8 (the core destructors and
    /// wl_fixes). A pre-v9 replica re-parsing it would take it as a
    /// fatal unknown opcode, so latch the fact for the daemon's
    /// viewer gate — same contract as `used_dmabuf_feedback`.
    pub fn destroyPostV8(self: *Compositor, id: u32) Error!void {
        self.used_post_v8_request = true;
        try self.destroyObject(id);
    }

    pub fn send(self: *Compositor, msg: []const u8) Error!void {
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
    // v7 (mux protocol 6) stores all pending dmabuf planes, their
    // modifiers, and the single-use bit; older snapshots carried only
    // a LINEAR plane 0.
    // v8 adds no fields. It is the capability signal for
    // linux-dmabuf v4: a v7 replica's protocol tables have no
    // feedback interface, so re-parsing the app's
    // get_default_feedback would be a fatal unknown opcode there.
    // v9 adds the surface's pending get_release callbacks and is the
    // capability signal for the core version bumps (wl_compositor 7,
    // wl_shm 2, wl_data_device_manager 4, wl_seat 10, wl_fixes): a v8
    // replica's tables lack those requests.
    // v10 adds no fields either: it is the capability signal for
    // xdg-foreign. A v9 replica has no zxdg_exporter_v2 in its tables,
    // so both the app's bind and an objects list naming the interface
    // are fatal there. Foreign relations themselves are NOT serialized
    // — the brain is the authority for them and a replica only needs to
    // keep parsing.
    // v11 adds the surface's xdg-dialog modality flag AND is the
    // capability signal for xdg-dialog: a v10 replica has neither
    // xdg_wm_dialog_v1 nor xdg_dialog_v1 in its tables, so the app's
    // bind and an objects list naming either are fatal there.
    const state_sync_version: u8 = 11;

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
        return self.serializeStateVersion(a, state_sync_version);
    }

    /// Serialize state for a v6 or newer replica, downgrading only
    /// the v7 dmabuf tail (v8 is a pure capability bump).
    pub fn serializeStateVersion(self: *const Compositor, a: std.mem.Allocator, max_version: u8) Error![]u8 {
        if (max_version < 6) return Error.Protocol;
        const version = @min(max_version, state_sync_version);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);

        try putU8(&out, a, version);
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
            try putU8(&out, a, @intFromBool(s.sub_below));
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
            if (version >= 11) try putU8(&out, a, @intFromBool(s.modal));
            try putU32(&out, a, @intCast(s.frame_cbs.items.len));
            for (s.frame_cbs.items) |cb| try putU32(&out, a, cb);
            if (version >= 9) {
                try putU32(&out, a, @intCast(s.release_cbs.items.len));
                for (s.release_cbs.items) |cb| try putU32(&out, a, cb);
            }
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

        // v11: live xdg_dialog_v1 objects, so a reattached replica can
        // keep parsing set_modal on dialogs created before it arrived.
        if (version >= 11) {
            try putU32(&out, a, self.dialogs.count());
            var dit = self.dialogs.iterator();
            while (dit.next()) |e| {
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

        // In-flight dmabuf params. v6 can represent only one unused LINEAR
        // plane; sessions advertising modifiers are gated to v7 viewers.
        try putU32(&out, a, self.dmabuf_params.count());
        var dpit = self.dmabuf_params.iterator();
        while (dpit.next()) |e| {
            try putU32(&out, a, e.key_ptr.*);
            if (version >= 7) {
                try putU8(&out, a, @intFromBool(e.value_ptr.used));
                for (e.value_ptr.planes) |plane_opt| {
                    const plane = plane_opt orelse {
                        try putU8(&out, a, 0);
                        continue;
                    };
                    try putU8(&out, a, 1);
                    try putU32(&out, a, plane.offset);
                    try putU32(&out, a, plane.stride);
                    try putU32(&out, a, @truncate(plane.modifier >> 32));
                    try putU32(&out, a, @truncate(plane.modifier));
                }
            } else {
                const plane = e.value_ptr.planes[0];
                const usable = !e.value_ptr.used and plane != null and
                    plane.?.modifier == dmabuf.DRM_FORMAT_MOD_LINEAR;
                try putU32(&out, a, if (usable) plane.?.offset else 0);
                try putU32(&out, a, if (usable) plane.?.stride else 0);
                try putU8(&out, a, @intFromBool(usable));
            }
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
        // Per-object versions are NOT in the blob (a replica never
        // sends protocol events, and live binds after the restore
        // repopulate it): drop stale entries and fall back to
        // seat_version for anything the replay does not rebind.
        self.obj_versions.clearRetainingCapacity();
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
            if (ver >= 6) s.sub_below = try r.u8v() != 0;
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
            if (ver >= 11) s.modal = try r.u8v() != 0;
            const n_cbs = try r.u32v();
            for (0..n_cbs) |_| try s.frame_cbs.append(a, try r.u32v());
            if (ver >= 9) {
                const n_rel = try r.u32v();
                for (0..n_rel) |_| try s.release_cbs.append(a, try r.u32v());
            }
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

        if (ver >= 11) {
            const n_dlg = try r.u32v();
            for (0..n_dlg) |_| {
                const k = try r.u32v();
                try self.dialogs.put(a, k, try r.u32v());
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
                var dp = dmabuf.Params{};
                if (ver >= 7) {
                    const used = try r.u8v() != 0;
                    for (0..dmabuf.MAX_PLANES) |plane_index| {
                        if (try r.u8v() == 0) continue;
                        const offset = try r.u32v();
                        const stride = try r.u32v();
                        const mod_hi: u64 = try r.u32v();
                        const mod_lo: u64 = try r.u32v();
                        dp.add(@intCast(plane_index), .{
                            .offset = offset,
                            .stride = stride,
                            .modifier = mod_hi << 32 | mod_lo,
                        }) catch return Error.Protocol;
                    }
                    dp.used = used;
                } else {
                    const offset = try r.u32v();
                    const stride = try r.u32v();
                    const ok = try r.u8v() != 0;
                    if (ok) dp.add(0, .{
                        .offset = offset,
                        .stride = stride,
                        .modifier = dmabuf.DRM_FORMAT_MOD_LINEAR,
                    }) catch return Error.Protocol;
                }
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
            // Foreign parents are NOT in the blob: they resolve against
            // the brain's handle namespace, and the daemon replays them
            // as `foreign_parent` units right after this state_sync.
            if (s.modal) if (self.view.toplevel_modal) |cb| cb(self.view.ctx, sid, true);
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
                if (s.sub_below) if (self.view.subsurface_below) |cb| cb(self.view.ctx, sid, true);
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
        try self.fatalCode(object, 1, text);
    }

    /// fatal with the erroring interface's own error code (wl_surface
    /// no_buffer = 5, and so on) — clients log the code, not the text.
    pub fn fatalCode(self: *Compositor, object: u32, code: u32, text: []const u8) Error!void {
        var buf: [128]u8 = undefined;
        var b = wire.Builder.init(&buf, 1, 0); // wl_display.error
        b.putObject(object);
        b.putUint(code);
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
    sub_below: bool = false,
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
    // xdg-foreign / xdg-dialog: last relation and modality reported.
    foreign_events: usize = 0,
    foreign_child: u32 = 0,
    foreign_conn: u32 = 0,
    foreign_sid: u32 = 0,
    modal_events: usize = 0,
    modal_sid: u32 = 0,
    modal: ?bool = null,

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
    fn onForeignParent(ctx: ?*anyopaque, surface: u32, conn: u32, parent: u32) void {
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.foreign_events += 1;
        self.foreign_child = surface;
        self.foreign_conn = conn;
        self.foreign_sid = parent;
    }
    fn onModal(ctx: ?*anyopaque, surface: u32, modal: bool) void {
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.modal_events += 1;
        self.modal_sid = surface;
        self.modal = modal;
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
    fn onSubBelow(ctx: ?*anyopaque, surface: u32, below: bool) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.sub_below = below;
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
            .subsurface_below = onSubBelow,
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
            .toplevel_foreign_parent = onForeignParent,
            .toplevel_modal = onModal,
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

/// Assert the raw 32-bit body words of one queued Wayland event.
fn expectEventWords(comp: *Compositor, object: u32, opcode: u16, expected: []const u32) !void {
    var pos: usize = 0;
    const bytes = comp.takeOut();
    while (try pipe.peelUnit(bytes[pos..])) |p| {
        if (p.unit.tag == .wl_msg) {
            const hdr = (try wire.parseHeader(p.unit.payload)).?;
            if (hdr.object == object and hdr.opcode == opcode) {
                const body = p.unit.payload[wire.header_size..hdr.size];
                try t.expectEqual(expected.len * 4, body.len);
                for (expected, 0..) |word, i|
                    try t.expectEqual(word, std.mem.readInt(u32, body[i * 4 ..][0..4], native_endian));
                return;
            }
        }
        pos += p.consumed;
    }
    try t.expect(false);
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

    // An authoritative client cannot guess the stable global name.
    var guessed = wire.Builder.init(&buf, 2, 0);
    guessed.putUint(22);
    guessed.putString("zwp_linux_dmabuf_v1");
    guessed.putUint(3);
    guessed.putNewId(3);
    try req(&comp2, try guessed.finish());
    try t.expect(comp2.dead);
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

    { // JBR shadow pattern: child is explicitly placed below parent.
        var b = wire.Builder.init(&buf, 7, 3);
        b.putObject(5);
        try req(&comp, try b.finish());
    }
    try t.expect(tv.sub_below);

    { // Moving it back above the parent updates the retained state.
        var b = wire.Builder.init(&buf, 7, 2);
        b.putObject(5);
        try req(&comp, try b.finish());
    }
    try t.expect(!tv.sub_below);

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

test "Firefox: per-object seat versions gate pointer axis and repeat_info" {
    // Firefox binds wl_seat TWICE from separate registries — v5 for
    // its widget code, v8 for the compositor thread — and takes a
    // pointer + keyboard from each. A single global seat_version sent
    // axis_value120 (v8, opcode 9) to the v5 pointer, whose listener
    // slot for it is NULL: libwayland aborts the client ("listener
    // function for opcode 9 of wl_pointer is NULL"). Every event must
    // be gated on the version of the object it goes to.
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [96]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 1, "wl_compositor", 6, 3);
    try bindGlobal(&comp, 3, "wl_seat", 5, 4); // old seat
    try bindGlobal(&comp, 3, "wl_seat", 8, 5); // modern seat
    { // seat 4 (v5): get_pointer(6) + get_keyboard(7)
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(6);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 4, 1);
        b2.putNewId(7);
        try req(&comp, try b2.finish());
    }
    { // seat 5 (v8): get_pointer(8)
        var b = wire.Builder.init(&buf, 5, 0);
        b.putNewId(8);
        try req(&comp, try b.finish());
    }
    { // create_surface(10) so the pointer has a focus target
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(10);
        try req(&comp, try b.finish());
    }
    comp.clearOut();

    try comp.pointerEnter(10, 4, 4);
    comp.clearOut();
    try comp.pointerAxis(0, 15.0, 120);

    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    // Pointer 6 is v5: axis_discrete (8), never axis_value120 (9).
    // Pointer 8 is v8: axis_value120 (9), never axis_discrete.
    const expect = [_][2]u32{
        .{ 6, 8 }, .{ 6, 4 }, .{ 6, 5 }, // discrete, axis, frame
        .{ 8, 9 }, .{ 8, 4 }, .{ 8, 5 }, // value120, axis, frame
    };
    try t.expectEqualSlices([2]u32, &expect, evs.items);

    // A v3 seat's keyboard predates repeat_info (v4) and must not get it.
    try bindGlobal(&comp, 3, "wl_seat", 3, 11);
    comp.clearOut();
    { // get_keyboard(12) on the v3 seat
        var b = wire.Builder.init(&buf, 11, 1);
        b.putNewId(12);
        try req(&comp, try b.finish());
    }
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    for (evs.items) |e| try t.expect(!(e[0] == 12 and e[1] == 5));
    // ...while the v8 seat's keyboard does.
    comp.clearOut();
    { // get_keyboard(13) on the v8 seat
        var b = wire.Builder.init(&buf, 5, 1);
        b.putNewId(13);
        try req(&comp, try b.finish());
    }
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    var saw_repeat = false;
    for (evs.items) |e| if (e[0] == 13 and e[1] == 5) {
        saw_repeat = true;
    };
    try t.expect(saw_repeat);

    // A v3 pointer gets neither the v5 frame nor any discrete event.
    { // get_pointer(14) on the v3 seat
        var b = wire.Builder.init(&buf, 11, 0);
        b.putNewId(14);
        try req(&comp, try b.finish());
    }
    comp.clearOut();
    try comp.pointerAxis(0, 15.0, 120);
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    for (evs.items) |e| if (e[0] == 14) try t.expectEqual(@as(u32, 4), e[1]);
}

test "Firefox: content subsurface layers above the CSD root and takes input" {
    // Firefox's xdg_toplevel surface only ever carries the CSD
    // background; chrome and page content live in one desync'd
    // subsurface it re-attaches to forever. A renderer needs the tree
    // (subtreeLayers) to compose the window, and input has to land on
    // the subsurface (hitTest), not the root.
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [96]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 1, "wl_compositor", 6, 3);
    try bindGlobal(&comp, 2, "wl_shm", 1, 4);
    try bindGlobal(&comp, 5, "xdg_wm_base", 6, 5);
    try bindGlobal(&comp, 11, "wl_subcompositor", 1, 6);

    { // root surface 7 + xdg toplevel
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(7);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 5, 2); // get_xdg_surface(8, 7)
        b2.putNewId(8);
        b2.putObject(7);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 8, 1); // get_toplevel(9)
        b3.putNewId(9);
        try req(&comp, try b3.finish());
        var b4 = wire.Builder.init(&buf, 7, 6); // commit → configure
        try req(&comp, try b4.finish());
    }
    { // content surface 10, subsurface of 7 at (10, 5)
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(10);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 6, 1); // get_subsurface(11, 10, 7)
        b2.putNewId(11);
        b2.putObject(10);
        b2.putObject(7);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 11, 1); // set_position(10, 5)
        b3.putInt(10);
        b3.putInt(5);
        try req(&comp, try b3.finish());
    }
    { // pool 12 with room for both buffers
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(12);
        b.putInt(5600);
        try req(&comp, try b.finish());
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(t.allocator);
        const px = try t.allocator.alloc(u8, 5600);
        defer t.allocator.free(px);
        @memset(px, 0x40);
        try pipe.appendPoolUpdate(&unit, t.allocator, 12, 0, px);
        try comp.feed(unit.items);
    }
    { // create_buffer(13) root 40x30, create_buffer(14) sub 20x10
        var b = wire.Builder.init(&buf, 12, 0);
        b.putNewId(13);
        b.putInt(0);
        b.putInt(40);
        b.putInt(30);
        b.putInt(160);
        b.putUint(0); // argb8888
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 12, 0);
        b2.putNewId(14);
        b2.putInt(4800);
        b2.putInt(20);
        b2.putInt(10);
        b2.putInt(80);
        b2.putUint(0);
        try req(&comp, try b2.finish());
    }
    { // attach + commit both surfaces
        var b = wire.Builder.init(&buf, 7, 1);
        b.putObject(13);
        b.putInt(0);
        b.putInt(0);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 7, 6);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 10, 1);
        b3.putObject(14);
        b3.putInt(0);
        b3.putInt(0);
        try req(&comp, try b3.finish());
        var b4 = wire.Builder.init(&buf, 10, 6);
        try req(&comp, try b4.finish());
    }

    // Both surfaces reached the view as frames (the subsurface is a
    // repaint of the window, not a separate window).
    try t.expectEqual(@as(usize, 2), tv.frames);
    try t.expectEqual(@as(u32, 7), comp.rootSurface(10));
    try t.expectEqual(@as(u32, 7), comp.rootSurface(7));

    var layers: std.ArrayList(Compositor.SubLayer) = .empty;
    defer layers.deinit(t.allocator);
    try comp.subtreeLayers(t.allocator, 7, &layers);
    try t.expectEqual(@as(usize, 1), layers.items.len);
    try t.expectEqual(@as(u32, 10), layers.items[0].sid);
    try t.expectEqual(@as(i32, 10), layers.items[0].x);
    try t.expectEqual(@as(i32, 5), layers.items[0].y);
    try t.expect(!layers.items[0].below);
    try t.expectEqual(@as(usize, 0), Compositor.belowCount(layers.items));

    // Inside the subsurface: input goes there, in ITS coordinates.
    const inside = comp.hitTest(t.allocator, 7, 15, 8);
    try t.expectEqual(@as(u32, 10), inside.sid);
    try t.expectEqual(@as(f64, 5), inside.x);
    try t.expectEqual(@as(f64, 3), inside.y);
    // Outside it, but inside the root: the root takes it unchanged.
    const outside = comp.hitTest(t.allocator, 7, 2, 2);
    try t.expectEqual(@as(u32, 7), outside.sid);
    try t.expectEqual(@as(f64, 2), outside.x);

    // A nested subsurface accumulates offsets and wins the hit.
    { // surface 15, subsurface(16) of 10 at (2, 1)
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(15);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 6, 1);
        b2.putNewId(16);
        b2.putObject(15);
        b2.putObject(10);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 16, 1); // set_position(2, 1)
        b3.putInt(2);
        b3.putInt(1);
        try req(&comp, try b3.finish());
        var b4 = wire.Builder.init(&buf, 15, 1); // attach the sub buffer
        b4.putObject(14);
        b4.putInt(0);
        b4.putInt(0);
        try req(&comp, try b4.finish());
        var b5 = wire.Builder.init(&buf, 15, 6);
        try req(&comp, try b5.finish());
    }
    layers.clearRetainingCapacity();
    try comp.subtreeLayers(t.allocator, 7, &layers);
    try t.expectEqual(@as(usize, 2), layers.items.len);
    try t.expectEqual(@as(u32, 15), layers.items[1].sid);
    try t.expectEqual(@as(i32, 12), layers.items[1].x); // 10 + 2
    try t.expectEqual(@as(i32, 6), layers.items[1].y); // 5 + 1
    const nested = comp.hitTest(t.allocator, 7, 13, 7);
    try t.expectEqual(@as(u32, 15), nested.sid);
    try t.expectEqual(@as(f64, 1), nested.x);
    try t.expectEqual(@as(f64, 1), nested.y);

    // JBR's pattern: place the content subsurface BELOW the root. It
    // paints first and the root's own buffer covers it, so the hit
    // goes to the root.
    { // place_below(sibling = parent 7)
        var b = wire.Builder.init(&buf, 11, 3);
        b.putObject(7);
        try req(&comp, try b.finish());
    }
    layers.clearRetainingCapacity();
    try comp.subtreeLayers(t.allocator, 7, &layers);
    try t.expectEqual(@as(usize, 2), Compositor.belowCount(layers.items));
    const covered = comp.hitTest(t.allocator, 7, 15, 8);
    try t.expectEqual(@as(u32, 7), covered.sid);

    // A root that rejects the point (CSD shadow: input region excludes
    // it) hands the hit to the below-parent layer under it.
    { // create_region(17), no rects → set_input_region + commit
        var b = wire.Builder.init(&buf, 3, 1);
        b.putNewId(17);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 7, 5); // set_input_region(17)
        b2.putObject(17);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 7, 6);
        try req(&comp, try b3.finish());
    }
    const through = comp.hitTest(t.allocator, 7, 15, 8);
    try t.expectEqual(@as(u32, 15), through.sid);
}

test "v6 compositor / v6 wm_base / v4 output obligations" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    comp.output_width = 1234;
    comp.output_height = 777;
    var buf: [64]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 1, "wl_compositor", 6, 3);
    try bindGlobal(&comp, 5, "xdg_wm_base", 6, 4);
    comp.clearOut();

    try bindGlobal(&comp, 4, "wl_output", 4, 5);
    try expectEventWords(&comp, 5, 1, &.{ 3, 1234, 777, 60000 });
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
    try expectEventWords(&comp, 8, 2, &.{ 1234, 777 });
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

test "seat v9: every axis event is preceded by axis_relative_direction" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 3, "wl_seat", 9, 3);
    // Seat 9/10 adds no requests, so the bind is the ONLY thing an
    // old replica (tables cap seat at 8) chokes on — it must latch
    // the viewer gate by itself.
    try t.expect(comp.used_post_v8_request);
    try bindGlobal(&comp, 1, "wl_compositor", 4, 4);
    { // surface 5, pointer 6 (v9), plus a v8 pointer 7 from a v8 seat
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(5);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 3, 0);
        b2.putNewId(6);
        try req(&comp, try b2.finish());
    }
    try bindGlobal(&comp, 3, "wl_seat", 8, 8);
    {
        var b = wire.Builder.init(&buf, 8, 0);
        b.putNewId(7);
        try req(&comp, try b.finish());
    }
    try comp.pointerEnter(5, 1, 1);
    comp.clearOut();

    try comp.pointerAxis(0, 20.0, 240);
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    // The v9 pointer leads with direction (spec: it is always
    // followed by exactly one axis event for that axis in the frame);
    // the v8 pointer must never see opcode 10 — its listener slot is
    // NULL and libwayland aborts the client.
    const expect = [_][2]u32{
        .{ 6, 10 }, // axis_relative_direction
        .{ 6, 9 }, // axis_value120
        .{ 6, 4 }, // axis
        .{ 6, 5 }, // frame
        .{ 7, 9 }, // v8 pointer: value120
        .{ 7, 4 },
        .{ 7, 5 },
    };
    try t.expectEqualSlices([2]u32, &expect, evs.items);

    // Smooth scroll carries the direction too (it is coupled to the
    // axis event, not to the discrete info).
    try comp.pointerAxis(1, 3.5, 0);
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    const smooth = [_][2]u32{ .{ 6, 10 }, .{ 6, 4 }, .{ 6, 5 }, .{ 7, 4 }, .{ 7, 5 } };
    try t.expectEqualSlices([2]u32, &smooth, evs.items);
}

test "core destructors: release drops the global, not what it made" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    try getRegistry(&comp);
    // Pre-v9 replica tables cap these binds at 6/1/3, so binding
    // above that must latch the viewer gate by itself.
    try bindGlobal(&comp, 1, "wl_compositor", 6, 30);
    try t.expect(!comp.used_post_v8_request);
    try bindGlobal(&comp, 1, "wl_compositor", 7, 3);
    try t.expect(comp.used_post_v8_request);
    try bindGlobal(&comp, 2, "wl_shm", 2, 4);
    try bindGlobal(&comp, 6, "wl_data_device_manager", 4, 5);

    { // a surface (3) and a data source (5) that must outlive their factories
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(6);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 5, 0);
        b2.putNewId(7);
        try req(&comp, try b2.finish());
    }

    { // wl_compositor.release
        var b = wire.Builder.init(&buf, 3, 2);
        try req(&comp, try b.finish());
    }
    { // wl_shm.release
        var b = wire.Builder.init(&buf, 4, 1);
        try req(&comp, try b.finish());
    }
    { // wl_data_device_manager.release
        var b = wire.Builder.init(&buf, 5, 2);
        try req(&comp, try b.finish());
    }
    try t.expect(!comp.dead);
    try t.expect(comp.objects.get(3) == null);
    try t.expect(comp.objects.get(4) == null);
    try t.expect(comp.objects.get(5) == null);
    // The children are untouched: the surface still exists and the
    // data source still takes offers.
    try t.expect(comp.surfaces.get(6) != null);
    {
        var b = wire.Builder.init(&buf, 7, 0); // wl_data_source.offer
        b.putString("text/plain");
        try req(&comp, try b.finish());
    }
    try t.expect(!comp.dead);
    // Pre-v9 replicas have no such requests in their tables.
    try t.expect(comp.used_post_v8_request);
}

test "wl_fixes: destroy_registry frees the registry, rejects other objects" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 24, "wl_fixes", 1, 3);
    try bindGlobal(&comp, 1, "wl_compositor", 7, 4);

    { // destroy_registry on the compositor, not a registry: refused
        var b = wire.Builder.init(&buf, 3, 1);
        b.putObject(4);
        try req(&comp, try b.finish());
    }
    try t.expect(comp.dead);

    var tv2 = TestView{};
    var comp2 = try Compositor.init(t.allocator, tv2.view());
    defer comp2.deinit();
    try getRegistry(&comp2);
    try bindGlobal(&comp2, 24, "wl_fixes", 1, 3);
    { // destroy_registry(2)
        var b = wire.Builder.init(&buf, 3, 1);
        b.putObject(2);
        try req(&comp2, try b.finish());
    }
    try t.expect(!comp2.dead);
    try t.expect(comp2.objects.get(2) == null);
    // Binding through the dead registry is now a protocol error.
    try bindGlobal(&comp2, 1, "wl_compositor", 7, 5);
    try t.expect(comp2.dead);
}

test "wl_surface.get_release: done rides the buffer release, no_buffer otherwise" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [96]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 1, "wl_compositor", 7, 3);
    try bindGlobal(&comp, 2, "wl_shm", 2, 4);
    try bindGlobal(&comp, 5, "xdg_wm_base", 2, 5);
    { // surface 6 + xdg dance + first commit
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(6);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 5, 2);
        b2.putNewId(7);
        b2.putObject(6);
        try req(&comp, try b2.finish());
        var b3 = wire.Builder.init(&buf, 7, 1);
        b3.putNewId(8);
        try req(&comp, try b3.finish());
        var b4 = wire.Builder.init(&buf, 6, 6);
        try req(&comp, try b4.finish());
    }
    { // pool 9 (2x2 xrgb) + buffer 10
        // create_pool sig "nhi": the fd occupies no wire bytes.
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(9);
        b.putInt(16);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 9, 0);
        b2.putNewId(10);
        b2.putInt(0);
        b2.putInt(2);
        b2.putInt(2);
        b2.putInt(8);
        b2.putUint(1);
        try req(&comp, try b2.finish());
    }

    { // attach(10) + get_release(11) + commit
        var b = wire.Builder.init(&buf, 6, 1);
        b.putObject(10);
        b.putInt(0);
        b.putInt(0);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 6, 11);
        b2.putNewId(11);
        try req(&comp, try b2.finish());
    }
    comp.clearOut();
    {
        var b = wire.Builder.init(&buf, 6, 6);
        try req(&comp, try b.finish());
    }
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    // wl_buffer.release, then the release callback's done, then its
    // delete_id on wl_display.
    try t.expect(!comp.dead);
    try t.expectEqualSlices([2]u32, &[_][2]u32{
        .{ 10, 0 }, // wl_buffer.release
        .{ 11, 0 }, // wl_callback.done
        .{ 1, 1 }, // wl_display.delete_id
    }, evs.items);
    try t.expect(comp.objects.get(11) == null);
    try t.expect(comp.used_post_v8_request);

    // A content update with no attached buffer is the no_buffer error.
    {
        var b = wire.Builder.init(&buf, 6, 11);
        b.putNewId(12);
        try req(&comp, try b.finish());
        var b2 = wire.Builder.init(&buf, 6, 6); // commit, nothing attached
        try req(&comp, try b2.finish());
    }
    try t.expect(comp.dead);
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
        // The session is over even though the offer below still works:
        // a toolkit that never gets this leave keeps the finished drop
        // and ignores the NEXT drag entirely.
        .{ 8, 2 }, // dd leave
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

test "linux-dmabuf announces configured modifiers without legacy overadvertisement" {
    const custom_modifier: u64 = 0x0123_4567_89ab_cdef;
    const capabilities = [_]dmabuf.Capability{
        .{ .format = dmabuf.DRM_FORMAT_ARGB8888, .modifier = dmabuf.DRM_FORMAT_MOD_LINEAR },
        .{ .format = dmabuf.DRM_FORMAT_ARGB8888, .modifier = custom_modifier },
        .{ .format = dmabuf.DRM_FORMAT_XRGB8888, .modifier = dmabuf.DRM_FORMAT_MOD_INVALID },
    };
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    comp.advertise_dmabuf = true;
    comp.dmabuf_capabilities = &capabilities;

    try getRegistry(&comp);
    comp.clearOut();
    try bindGlobal(&comp, 22, "zwp_linux_dmabuf_v1", 3, 3);

    var formats: std.ArrayList(u32) = .empty;
    defer formats.deinit(t.allocator);
    var pairs: std.ArrayList([2]u64) = .empty;
    defer pairs.deinit(t.allocator);
    var pos: usize = 0;
    const bytes = comp.takeOut();
    while (try pipe.peelUnit(bytes[pos..])) |peeled| {
        if (peeled.unit.tag == .wl_msg) {
            const hdr = (try wire.parseHeader(peeled.unit.payload)).?;
            const body = peeled.unit.payload[wire.header_size..hdr.size];
            if (hdr.opcode == 0) {
                var args = wire.ArgIter.init(body, "u");
                try formats.append(t.allocator, (try args.next()).?.uint);
            } else if (hdr.opcode == 1) {
                var args = wire.ArgIter.init(body, "uuu");
                const format = (try args.next()).?.uint;
                const hi: u64 = (try args.next()).?.uint;
                const lo: u64 = (try args.next()).?.uint;
                try pairs.append(t.allocator, .{ format, hi << 32 | lo });
            }
        }
        pos += peeled.consumed;
    }
    try t.expectEqual(@as(usize, 0), formats.items.len);
    try t.expectEqualSlices([2]u64, &.{
        .{ dmabuf.DRM_FORMAT_ARGB8888, dmabuf.DRM_FORMAT_MOD_LINEAR },
        .{ dmabuf.DRM_FORMAT_ARGB8888, custom_modifier },
        .{ dmabuf.DRM_FORMAT_XRGB8888, dmabuf.DRM_FORMAT_MOD_INVALID },
    }, pairs.items);
}

test "linux-dmabuf legacy bind announces only implicit formats" {
    const capabilities = [_]dmabuf.Capability{
        .{ .format = dmabuf.DRM_FORMAT_ARGB8888, .modifier = dmabuf.DRM_FORMAT_MOD_LINEAR },
        .{ .format = dmabuf.DRM_FORMAT_XRGB8888, .modifier = dmabuf.DRM_FORMAT_MOD_INVALID },
    };
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    comp.advertise_dmabuf = true;
    comp.dmabuf_capabilities = &capabilities;

    try getRegistry(&comp);
    comp.clearOut();
    try bindGlobal(&comp, 22, "zwp_linux_dmabuf_v1", 2, 3);

    var formats: std.ArrayList(u32) = .empty;
    defer formats.deinit(t.allocator);
    var pos: usize = 0;
    const bytes = comp.takeOut();
    while (try pipe.peelUnit(bytes[pos..])) |peeled| {
        if (peeled.unit.tag == .wl_msg) {
            const hdr = (try wire.parseHeader(peeled.unit.payload)).?;
            if (hdr.opcode == 0) {
                var args = wire.ArgIter.init(peeled.unit.payload[wire.header_size..hdr.size], "u");
                try formats.append(t.allocator, (try args.next()).?.uint);
            }
        }
        pos += peeled.consumed;
    }
    try t.expectEqualSlices(u32, &.{dmabuf.DRM_FORMAT_XRGB8888}, formats.items);
}

test "linux-dmabuf lenient replay accepts modifiers and restores tight pools" {
    const custom_modifier: u64 = 0x0123_4567_89ab_cdef;
    var tv = TestView{};
    var brain = try Compositor.init(t.allocator, tv.view());
    defer brain.deinit();
    brain.advertise_dmabuf = true;
    var buf: [96]u8 = undefined;

    try getRegistry(&brain);
    try bindGlobal(&brain, 22, "zwp_linux_dmabuf_v1", 3, 3);
    { // create_params(4)
        var b = wire.Builder.init(&buf, 3, 1);
        b.putNewId(4);
        try req(&brain, try b.finish());
    }
    { // padded source: plane 0, offset 8, stride 16, custom modifier
        var b = wire.Builder.init(&buf, 4, 1);
        b.putUint(0);
        b.putUint(8);
        b.putUint(16);
        b.putUint(@truncate(custom_modifier >> 32));
        b.putUint(@truncate(custom_modifier));
        try req(&brain, try b.finish());
    }
    const state = try brain.serializeState(t.allocator);
    defer t.allocator.free(state);

    var tv2 = TestView{};
    var replica = try Compositor.init(t.allocator, tv2.view());
    defer replica.deinit();
    replica.lenient = true;
    try replica.restoreState(state);
    { // create_immed replays despite the replica's default LINEAR policy
        var b = wire.Builder.init(&buf, 4, 3);
        b.putNewId(5);
        b.putInt(2);
        b.putInt(2);
        b.putUint(dmabuf.DRM_FORMAT_ARGB8888);
        b.putUint(dmabuf.FLAG_Y_INVERT);
        try req(&replica, try b.finish());
    }
    const info = replica.buffers.get(5).?;
    try t.expectEqual(@as(i32, 0), info.offset);
    try t.expectEqual(@as(i32, 8), info.stride);
    try t.expectEqual(@as(u32, 0), info.format);
    try t.expectEqual(@as(usize, 16), replica.pools.get(5).?.bytes.items.len);
    try t.expect(!replica.dead);
}

test "linux-dmabuf authoritative create requires an announced capability" {
    const custom_modifier: u64 = 77;
    const capabilities = [_]dmabuf.Capability{
        .{ .format = dmabuf.DRM_FORMAT_XRGB8888, .modifier = custom_modifier },
    };
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    comp.advertise_dmabuf = true;
    comp.dmabuf_capabilities = &capabilities;
    var buf: [96]u8 = undefined;

    try getRegistry(&comp);
    try bindGlobal(&comp, 22, "zwp_linux_dmabuf_v1", 3, 3);
    {
        var b = wire.Builder.init(&buf, 3, 1);
        b.putNewId(4);
        try req(&comp, try b.finish());
    }
    {
        var b = wire.Builder.init(&buf, 4, 1);
        b.putUint(0);
        b.putUint(0);
        b.putUint(8);
        b.putUint(0);
        b.putUint(0); // LINEAR was not announced
        try req(&comp, try b.finish());
    }
    {
        var b = wire.Builder.init(&buf, 4, 3);
        b.putNewId(5);
        b.putInt(2);
        b.putInt(2);
        b.putUint(dmabuf.DRM_FORMAT_XRGB8888);
        b.putUint(0);
        try req(&comp, try b.finish());
    }
    try t.expect(comp.dead);
    try t.expect(comp.buffers.get(5) == null);
}

test "linux-dmabuf: modifiers at bind, create_immed pixels + release, create fails over to shm" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    comp.advertise_dmabuf = true;
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
    // ARGB + XRGB, each as a LINEAR modifier tuple.
    const bind_expect = [_][2]u32{
        .{ 3, 1 },
        .{ 3, 1 },
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

/// Peel every unit, returning the announced version of the
/// zwp_linux_dmabuf_v1 global (0 = not announced).
fn announcedDmabufVersion(comp: *Compositor) !u32 {
    var pos: usize = 0;
    var found: u32 = 0;
    const bytes = comp.takeOut();
    while (try pipe.peelUnit(bytes[pos..])) |p| {
        pos += p.consumed;
        if (p.unit.tag != .wl_msg) continue;
        const body = p.unit.payload[wire.header_size..];
        var it = wire.ArgIter.init(body, "usu");
        _ = try it.next();
        const iname = (try it.next()).?.string orelse continue;
        if (!std.mem.eql(u8, iname, "zwp_linux_dmabuf_v1")) continue;
        found = (try it.next()).?.uint;
    }
    comp.clearOut();
    return found;
}

test "linux-dmabuf v4 is announced only with a main device" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    comp.advertise_dmabuf = true;

    // No main device: v3, and a v4 bind is a protocol error (the
    // client would wait forever for feedback we cannot answer).
    try getRegistry(&comp);
    try t.expectEqual(@as(u32, 3), try announcedDmabufVersion(&comp));
    try bindGlobal(&comp, 22, "zwp_linux_dmabuf_v1", 4, 3);
    try t.expect(comp.dead);

    var tv2 = TestView{};
    var comp2 = try Compositor.init(t.allocator, tv2.view());
    defer comp2.deinit();
    comp2.advertise_dmabuf = true;
    comp2.dmabuf_main_device = 0xe280; // any nonzero dev_t
    try getRegistry(&comp2);
    try t.expectEqual(@as(u32, 4), try announcedDmabufVersion(&comp2));

    // A main device with nothing importable stays at v3: an empty
    // format table is not a legal feedback answer.
    var tv3 = TestView{};
    var comp3 = try Compositor.init(t.allocator, tv3.view());
    defer comp3.deinit();
    comp3.advertise_dmabuf = true;
    comp3.dmabuf_main_device = 0xe280;
    comp3.dmabuf_capabilities = &.{};
    try getRegistry(&comp3);
    try t.expectEqual(@as(u32, 3), try announcedDmabufVersion(&comp3));
}

test "dmabuf v4 feedback answers with a table, a device and one tranche" {
    // mpv/mesa bind v4 and block until `done`; a v3-only compositor
    // makes --vo=dmabuf-wayland refuse to initialize.
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    comp.advertise_dmabuf = true;
    comp.dmabuf_main_device = 0xe280;

    try getRegistry(&comp);
    comp.clearOut();
    // Announcing v4 must not exclude pre-v8 replicas from the
    // session; a v4 BIND must, since their protocol tables cap the
    // global at 3 and the bind alone kills them.
    try t.expect(!comp.used_dmabuf_feedback);
    try bindGlobal(&comp, 22, "zwp_linux_dmabuf_v1", 4, 3);
    try t.expect(!comp.dead);
    try t.expect(comp.used_dmabuf_feedback);

    // v4 forbids the legacy format/modifier announcements.
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    try t.expectEqual(@as(usize, 0), evs.items.len);

    { // get_default_feedback(4)
        var buf: [32]u8 = undefined;
        var b = wire.Builder.init(&buf, 3, 2);
        b.putNewId(4);
        try req(&comp, try b.finish());
    }
    try t.expect(comp.used_dmabuf_feedback);

    var table: ?[]const u8 = null;
    var opcodes: std.ArrayList(u16) = .empty;
    defer opcodes.deinit(t.allocator);
    var main_device: u64 = 0;
    var tranche_indices: std.ArrayList(u16) = .empty;
    defer tranche_indices.deinit(t.allocator);
    var pos: usize = 0;
    const bytes = comp.takeOut();
    while (try pipe.peelUnit(bytes[pos..])) |p| {
        pos += p.consumed;
        switch (p.unit.tag) {
            .dmabuf_feedback => {
                try t.expectEqual(@as(u32, 4), std.mem.readInt(u32, p.unit.payload[0..4], .little));
                table = p.unit.payload[4..];
                try opcodes.append(t.allocator, 1); // format_table
            },
            .wl_msg => {
                const hdr = (try wire.parseHeader(p.unit.payload)).?;
                try t.expectEqual(@as(u32, 4), hdr.object);
                try opcodes.append(t.allocator, hdr.opcode);
                const body = p.unit.payload[wire.header_size..];
                if (hdr.opcode == 2) { // main_device
                    var it = wire.ArgIter.init(body, "a");
                    const arr = (try it.next()).?.array;
                    try t.expectEqual(@as(usize, 8), arr.len);
                    main_device = std.mem.readInt(u64, arr[0..8], native_endian);
                } else if (hdr.opcode == 5) { // tranche_formats
                    var it = wire.ArgIter.init(body, "a");
                    const arr = (try it.next()).?.array;
                    var i: usize = 0;
                    while (i + 2 <= arr.len) : (i += 2)
                        try tranche_indices.append(t.allocator, std.mem.readInt(u16, arr[i..][0..2], native_endian));
                }
            },
            else => {},
        }
    }

    // Spec order: format_table, main_device, then the tranche
    // (target_device, formats, flags, done), then done.
    try t.expectEqualSlices(u16, &[_]u16{ 1, 2, 4, 5, 6, 3, 0 }, opcodes.items);
    try t.expectEqual(@as(u64, 0xe280), main_device);

    // Default capabilities: ARGB + XRGB, both LINEAR.
    const tbl = table.?;
    try t.expectEqual(@as(usize, 2 * dmabuf.table_entry_size), tbl.len);
    try t.expectEqualSlices(u16, &[_]u16{ 0, 1 }, tranche_indices.items);
    try t.expectEqual(
        dmabuf.DRM_FORMAT_ARGB8888,
        std.mem.readInt(u32, tbl[0..4], native_endian),
    );
    try t.expectEqual(
        dmabuf.DRM_FORMAT_MOD_LINEAR,
        std.mem.readInt(u64, tbl[8..16], native_endian),
    );
    try t.expectEqual(
        dmabuf.DRM_FORMAT_XRGB8888,
        std.mem.readInt(u32, tbl[16..20], native_endian),
    );

    // Per-surface feedback answers identically, and destroy releases
    // the object without touching the default feedback.
    { // get_surface_feedback(5, surface 0) — no surface needed here
        var buf: [32]u8 = undefined;
        var b = wire.Builder.init(&buf, 3, 3);
        b.putNewId(5);
        b.putObject(0);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 2), comp.dmabuf_feedbacks.count());
    comp.clearOut();
    {
        var buf: [16]u8 = undefined;
        var b = wire.Builder.init(&buf, 5, 0); // destroy
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), comp.dmabuf_feedbacks.count());
    try t.expect(comp.objects.get(5) == null);
    try t.expect(!comp.dead);
}

test "current state_sync: dmabuf buffer survives replica restore with pixels" {
    var tv = TestView{};
    var brain = try Compositor.init(t.allocator, tv.view());
    defer brain.deinit();
    brain.advertise_dmabuf = true;
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

test "v6 state_sync serializes legacy pending LINEAR dmabuf params" {
    var tv = TestView{};
    var brain = try Compositor.init(t.allocator, tv.view());
    defer brain.deinit();
    brain.advertise_dmabuf = true;
    var buf: [96]u8 = undefined;

    try getRegistry(&brain);
    try bindGlobal(&brain, 22, "zwp_linux_dmabuf_v1", 3, 3);
    { // create_params(4) + add a pending LINEAR plane
        var b = wire.Builder.init(&buf, 3, 1);
        b.putNewId(4);
        try req(&brain, try b.finish());
        var b2 = wire.Builder.init(&buf, 4, 1);
        b2.putUint(0);
        b2.putUint(12);
        b2.putUint(64);
        b2.putUint(0);
        b2.putUint(0);
        try req(&brain, try b2.finish());
    }
    const legacy = try brain.serializeStateVersion(t.allocator, 6);
    defer t.allocator.free(legacy);
    try t.expectEqual(@as(u8, 6), legacy[0]);

    var tv2 = TestView{};
    var replica = try Compositor.init(t.allocator, tv2.view());
    defer replica.deinit();
    try replica.restoreState(legacy);
    const params = replica.dmabuf_params.get(4).?;
    try t.expect(!params.used);
    try t.expectEqual(@as(u32, 12), params.planes[0].?.offset);
    try t.expectEqual(@as(u32, 64), params.planes[0].?.stride);
    try t.expectEqual(dmabuf.DRM_FORMAT_MOD_LINEAR, params.planes[0].?.modifier);
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
    comp.output_width = 1024;
    comp.output_height = 768;
    comp.scale120 = 180;
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
    try expectEventWords(&comp, 5, 1, &.{ 682, 512 });
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

test "virtual output size follows configured pixels and fractional scale" {
    var comp = try Compositor.init(t.allocator, .{});
    defer comp.deinit();
    comp.output_width = 1024;
    comp.output_height = 768;
    try t.expectEqual([2]i32{ 1024, 768 }, comp.logicalOutputSize());
    comp.scale120 = 180;
    try t.expectEqual([2]i32{ 682, 512 }, comp.logicalOutputSize());
}

// ─── xdg-foreign v2 tests ───────────────────────────────────────

/// wl_compositor(3) + xdg_wm_base(4) bound, then one toplevel built
/// as surface `sid` → xdg_surface `sid+1` → xdg_toplevel `sid+2`.
fn foreignToplevel(comp: *Compositor, sid: u32) !void {
    var buf: [64]u8 = undefined;
    var b = wire.Builder.init(&buf, 3, 0); // create_surface
    b.putNewId(sid);
    try req(comp, try b.finish());
    var xb = wire.Builder.init(&buf, 4, 2); // get_xdg_surface
    xb.putNewId(sid + 1);
    xb.putObject(sid);
    try req(comp, try xb.finish());
    var tb = wire.Builder.init(&buf, sid + 1, 1); // get_toplevel
    tb.putNewId(sid + 2);
    try req(comp, try tb.finish());
}

/// registry + wl_compositor(3) + xdg_wm_base(4) + both xdg-foreign
/// managers (exporter 5, importer 6), the id layout every test below
/// builds on.
fn foreignSetup(comp: *Compositor) !void {
    try getRegistry(comp);
    try bindGlobal(comp, 1, "wl_compositor", 6, 3);
    try bindGlobal(comp, 5, "xdg_wm_base", 6, 4);
    try bindGlobal(comp, 25, "zxdg_exporter_v2", 1, 5);
    try bindGlobal(comp, 26, "zxdg_importer_v2", 1, 6);
}

/// export_toplevel(exported, surface) on the exporter bound as id 5,
/// returning the handle string carried by the handle event.
fn foreignExport(comp: *Compositor, exported: u32, sid: u32) !ForeignHandle {
    var buf: [64]u8 = undefined;
    var b = wire.Builder.init(&buf, 5, 1);
    b.putNewId(exported);
    b.putObject(sid);
    try req(comp, try b.finish());

    var out: ForeignHandle = undefined;
    var found = false;
    var pos: usize = 0;
    const bytes = comp.takeOut();
    while (try pipe.peelUnit(bytes[pos..])) |p| {
        if (p.unit.tag == .wl_msg) {
            const hdr = (try wire.parseHeader(p.unit.payload)).?;
            if (hdr.object == exported and hdr.opcode == 0) {
                const body = p.unit.payload[wire.header_size..hdr.size];
                var it = wire.ArgIter.init(body, "s");
                const s = (try it.next()).?.string.?;
                try t.expectEqual(foreign_handle_len, s.len);
                @memcpy(&out, s);
                found = true;
            }
        }
        pos += p.consumed;
    }
    comp.clearOut();
    try t.expect(found);
    return out;
}

/// import_toplevel(imported, handle) on the importer bound as id 6.
fn foreignImport(comp: *Compositor, imported: u32, handle: []const u8) !void {
    var buf: [96]u8 = undefined;
    var b = wire.Builder.init(&buf, 6, 1);
    b.putNewId(imported);
    b.putString(handle);
    try req(comp, try b.finish());
}

/// Whether a `destroyed` event (opcode 0) for `imported` is queued.
fn sawImportDestroyed(comp: *Compositor, imported: u32) !bool {
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(comp, &evs);
    for (evs.items) |e| {
        if (e[0] == imported and e[1] == 0) return true;
    }
    return false;
}

test "xdg-foreign: globals bind at v1 and a higher bind is refused" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();

    // The announcement carries version 1 for both managers.
    try getRegistry(&comp);
    var seen: usize = 0;
    var pos: usize = 0;
    const bytes = comp.takeOut();
    while (try pipe.peelUnit(bytes[pos..])) |p| {
        const hdr = (try wire.parseHeader(p.unit.payload)).?;
        const body = p.unit.payload[wire.header_size..hdr.size];
        var it = wire.ArgIter.init(body, "usu");
        _ = try it.next();
        const name = (try it.next()).?.string.?;
        const ver = (try it.next()).?.uint;
        if (std.mem.eql(u8, name, "zxdg_exporter_v2") or
            std.mem.eql(u8, name, "zxdg_importer_v2"))
        {
            try t.expectEqual(@as(u32, 1), ver);
            seen += 1;
        }
        pos += p.consumed;
    }
    comp.clearOut();
    try t.expectEqual(@as(usize, 2), seen);

    // v1 is the only legal bind; the gate latches the viewer version.
    try t.expect(!comp.used_foreign);
    try bindGlobal(&comp, 25, "zxdg_exporter_v2", 1, 5);
    try t.expect(!comp.dead);
    try t.expect(comp.used_foreign);

    // Binding above the advertised version is a protocol error.
    try bindGlobal(&comp, 26, "zxdg_importer_v2", 2, 6);
    try t.expect(comp.dead);
}

test "xdg-foreign: export mints an unguessable handle, non-toplevels are refused" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    try foreignSetup(&comp);
    try foreignToplevel(&comp, 10); // surface 10, toplevel 12
    comp.clearOut();

    const h1 = try foreignExport(&comp, 20, 10);
    const h2 = try foreignExport(&comp, 21, 10);
    // A surface may be exported repeatedly; each export is distinct.
    try t.expect(!std.mem.eql(u8, &h1, &h2));
    for (h1) |ch| try t.expect(std.mem.indexOfScalar(u8, "0123456789abcdef", ch) != null);
    // Entropy, not a counter: the two handles differ in most bytes.
    var same: usize = 0;
    for (h1, h2) |a, b| same += @intFromBool(a == b);
    try t.expect(same < foreign_handle_len / 2);
    try t.expectEqual(@as(usize, 2), comp.foreignReg().exports.items.len);

    // A surface with no toplevel role is invalid_surface (fatal).
    var buf: [64]u8 = undefined;
    var b = wire.Builder.init(&buf, 3, 0); // create_surface(30)
    b.putNewId(30);
    try req(&comp, try b.finish());
    _ = try foreignExportRefused(&comp, 31, 30);
}

fn foreignExportRefused(comp: *Compositor, exported: u32, sid: u32) !void {
    var buf: [64]u8 = undefined;
    var b = wire.Builder.init(&buf, 5, 1);
    b.putNewId(exported);
    b.putObject(sid);
    try req(comp, try b.finish());
    try t.expect(comp.dead);
}

test "xdg-foreign: same-client import parents through the foreign path too" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    comp.conn_id = 7;
    try foreignSetup(&comp);
    try foreignToplevel(&comp, 10); // parent surface 10
    tv.child_sid = 40;
    try foreignToplevel(&comp, 40); // child surface 40
    comp.clearOut();

    const handle = try foreignExport(&comp, 20, 10);
    try foreignImport(&comp, 21, &handle);
    // A known handle is NOT answered with destroyed.
    try t.expect(!try sawImportDestroyed(&comp, 21));

    var buf: [32]u8 = undefined;
    var b = wire.Builder.init(&buf, 21, 1); // set_parent_of(40)
    b.putObject(40);
    try req(&comp, try b.finish());

    // ONE mechanism for both cases: the relation is reported through
    // toplevel_foreign_parent naming this connection, and tl_parent
    // stays reserved for xdg_toplevel.set_parent.
    try t.expectEqual(@as(u32, 0), comp.surfaces.get(40).?.tl_parent);
    try t.expectEqual(@as(u32, 10), comp.surfaces.get(40).?.foreign_parent);
    try t.expectEqual(@as(u32, 7), comp.surfaces.get(40).?.foreign_parent_conn);
    try t.expect(!comp.surfaces.get(40).?.foreign_parent_remote);
    try t.expectEqual(@as(u32, 0), tv.child_parent);
    try t.expectEqual(@as(usize, 1), tv.foreign_events);
    try t.expectEqual(@as(u32, 40), tv.foreign_child);
    try t.expectEqual(@as(u32, 7), tv.foreign_conn);
    try t.expectEqual(@as(u32, 10), tv.foreign_sid);

    // Destroying the zxdg_imported_v2 invalidates the relationship.
    var db = wire.Builder.init(&buf, 21, 0);
    try req(&comp, try db.finish());
    try t.expectEqual(@as(u32, 0), comp.surfaces.get(40).?.foreign_parent);
    try t.expectEqual(@as(usize, 2), tv.foreign_events);
    try t.expectEqual(@as(u32, 0), tv.foreign_conn);
    try t.expectEqual(@as(u32, 0), tv.foreign_sid);
    try t.expectEqual(@as(usize, 0), comp.foreignReg().imports.items.len);
    try t.expect(!comp.dead);
}

test "xdg-foreign: an unknown handle is answered with destroyed" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    try foreignSetup(&comp);
    try foreignToplevel(&comp, 10);
    comp.clearOut();

    try foreignImport(&comp, 21, "ffffffffffffffffffffffffffffffff");
    try t.expect(try sawImportDestroyed(&comp, 21));

    // A dead import is inert: set_parent_of establishes nothing, and
    // the object still destroys cleanly.
    var buf: [32]u8 = undefined;
    var b = wire.Builder.init(&buf, 21, 1);
    b.putObject(10);
    try req(&comp, try b.finish());
    try t.expectEqual(@as(u32, 0), comp.surfaces.get(10).?.tl_parent);
    var db = wire.Builder.init(&buf, 21, 0);
    try req(&comp, try db.finish());
    try t.expect(!comp.dead);

    // A handle of the wrong length can never match either.
    try foreignImport(&comp, 22, "short");
    try t.expect(try sawImportDestroyed(&comp, 22));
    try t.expect(!comp.dead);
}

test "xdg-foreign: cross-client import resolves and the exporter's death notifies it" {
    // Two connections = two Compositors, which is exactly the portal
    // case (app exports, the picker process imports). Only the shared
    // registry makes the handle resolvable at all.
    var reg = ForeignRegistry{};
    defer reg.deinit();

    var atv = TestView{};
    var app = try Compositor.init(t.allocator, atv.view());
    defer app.deinit();
    app.foreign_shared = &reg;
    app.conn_id = 3;

    var dtv = TestView{};
    var dialog = try Compositor.init(t.allocator, dtv.view());
    defer dialog.deinit();
    dialog.foreign_shared = &reg;
    dialog.conn_id = 4;

    try foreignSetup(&app);
    try foreignToplevel(&app, 10);
    app.clearOut();
    try foreignSetup(&dialog);
    dtv.child_sid = 10;
    try foreignToplevel(&dialog, 10); // same ids, different id space
    dialog.clearOut();

    const handle = try foreignExport(&app, 20, 10);
    try foreignImport(&dialog, 21, &handle);
    try t.expect(!try sawImportDestroyed(&dialog, 21));

    var buf: [32]u8 = undefined;
    var b = wire.Builder.init(&buf, 21, 1); // set_parent_of(10)
    b.putObject(10);
    try req(&dialog, try b.finish());

    // The relation is recorded and flagged as pointing outside this
    // connection's id space; tl_parent stays clear because surface 10
    // in THIS compositor is the child itself, not the parent. The view
    // learns the parent by its SESSION-wide identity: the exporting
    // connection's id plus the surface id in that connection's space.
    try t.expectEqual(@as(u32, 10), dialog.surfaces.get(10).?.foreign_parent);
    try t.expect(dialog.surfaces.get(10).?.foreign_parent_remote);
    try t.expectEqual(@as(u32, 0), dialog.surfaces.get(10).?.tl_parent);
    try t.expectEqual(@as(u32, 0), dtv.child_parent);
    try t.expectEqual(@as(usize, 1), dtv.foreign_events);
    try t.expectEqual(@as(u32, 10), dtv.foreign_child);
    try t.expectEqual(@as(u32, 3), dtv.foreign_conn);
    try t.expectEqual(@as(u32, 10), dtv.foreign_sid);
    // The exporter's own view heard nothing: only the importing
    // connection has a relation to act on.
    try t.expectEqual(@as(usize, 0), atv.foreign_events);

    // The exporting toplevel goes away: the importer is told, its
    // relationship is dropped, and the handle stops resolving.
    var tb = wire.Builder.init(&buf, 12, 0); // xdg_toplevel.destroy
    try req(&app, try tb.finish());
    try t.expect(try sawImportDestroyed(&dialog, 21));
    try t.expectEqual(@as(usize, 0), reg.exports.items.len);
    try t.expectEqual(@as(u32, 0), dialog.surfaces.get(10).?.foreign_parent);
    // A parent that dies while the child is showing must actively
    // release the child, not leave a stale reference behind.
    try t.expectEqual(@as(usize, 2), dtv.foreign_events);
    try t.expectEqual(@as(u32, 10), dtv.foreign_child);
    try t.expectEqual(@as(u32, 0), dtv.foreign_conn);
    try t.expectEqual(@as(u32, 0), dtv.foreign_sid);
    try t.expectEqual(@as(u32, 0), dialog.surfaces.get(10).?.foreign_parent_conn);

    // A re-import of the revoked handle is refused immediately.
    try foreignImport(&dialog, 22, &handle);
    try t.expect(try sawImportDestroyed(&dialog, 22));
    try t.expect(!app.dead);
    try t.expect(!dialog.dead);
}

test "xdg-foreign: an exporting client that just vanishes still notifies importers" {
    var reg = ForeignRegistry{};
    defer reg.deinit();

    var dtv = TestView{};
    var dialog = try Compositor.init(t.allocator, dtv.view());
    defer dialog.deinit();
    dialog.foreign_shared = &reg;
    try foreignSetup(&dialog);

    var handle: ForeignHandle = undefined;
    var woken: usize = 0;
    const Wake = struct {
        fn cb(ctx: ?*anyopaque, comp: *Compositor) void {
            _ = comp;
            const n: *usize = @ptrCast(@alignCast(ctx.?));
            n.* += 1;
        }
    };
    reg.wake = Wake.cb;
    reg.wake_ctx = &woken;

    { // The exporting client's whole connection, then gone.
        var atv = TestView{};
        var app = try Compositor.init(t.allocator, atv.view());
        defer app.deinit(); // no destroy requests at all — a crash
        app.foreign_shared = &reg;
        try foreignSetup(&app);
        try foreignToplevel(&app, 10);
        app.clearOut();
        handle = try foreignExport(&app, 20, 10);
        try foreignImport(&dialog, 21, &handle);
        try t.expect(!try sawImportDestroyed(&dialog, 21));
    }

    // deinit purged the export and told the importer, on the
    // importer's own queue, with a wake so the daemon flushes it.
    try t.expectEqual(@as(usize, 0), reg.exports.items.len);
    try t.expect(try sawImportDestroyed(&dialog, 21));
    try t.expect(woken > 0);
    try t.expect(!dialog.dead);
}

test "xdg-foreign: a client's own imports and exports die with it" {
    var reg = ForeignRegistry{};
    defer reg.deinit();
    {
        var tv = TestView{};
        var comp = try Compositor.init(t.allocator, tv.view());
        defer comp.deinit();
        comp.foreign_shared = &reg;
        try foreignSetup(&comp);
        try foreignToplevel(&comp, 10);
        comp.clearOut();
        const handle = try foreignExport(&comp, 20, 10);
        try foreignImport(&comp, 21, &handle);
        try t.expectEqual(@as(usize, 1), reg.exports.items.len);
        try t.expectEqual(@as(usize, 1), reg.imports.items.len);
    }
    try t.expectEqual(@as(usize, 0), reg.exports.items.len);
    try t.expectEqual(@as(usize, 0), reg.imports.items.len);
}

test "xdg-foreign: a replica never judges the authoritative stream" {
    // Replicas re-parse the brain's request stream and have no shared
    // registry, so every foreign request must be inert there rather
    // than fatal.
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    comp.lenient = true;
    try foreignSetup(&comp);
    try foreignToplevel(&comp, 10);
    comp.clearOut();

    var buf: [64]u8 = undefined;
    var b = wire.Builder.init(&buf, 3, 0); // create_surface(30), no role
    b.putNewId(30);
    try req(&comp, try b.finish());
    var eb = wire.Builder.init(&buf, 5, 1); // export a non-toplevel
    eb.putNewId(31);
    eb.putObject(30);
    try req(&comp, try eb.finish());
    try t.expect(!comp.dead);

    try foreignImport(&comp, 32, "0123456789abcdef0123456789abcdef");
    var sb = wire.Builder.init(&buf, 32, 1); // set_parent_of(30), no role
    sb.putObject(30);
    try req(&comp, try sb.finish());
    try t.expect(!comp.dead);
}

test "xdg-foreign: a replica learns cross-connection parents from the daemon's unit" {
    // A replica mints its OWN handles while re-parsing export_toplevel,
    // so the handle the app then imports never resolves there — which
    // is exactly why the brain ships the resolved relation instead.
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    comp.lenient = true;
    comp.conn_id = 4;
    try foreignSetup(&comp);
    tv.child_sid = 10;
    try foreignToplevel(&comp, 10);
    comp.clearOut();

    // The replica's own bookkeeping says nothing.
    const local = try foreignExport(&comp, 20, 10);
    try foreignImport(&comp, 21, &local);
    var buf: [32]u8 = undefined;
    var b = wire.Builder.init(&buf, 21, 1);
    b.putObject(10);
    try req(&comp, try b.finish());
    try t.expectEqual(@as(usize, 0), tv.foreign_events);

    // The daemon's answer does, and names a window in ANOTHER
    // connection (conn 3, surface 10 — an id this compositor also
    // uses, for a different window).
    var units: std.ArrayList(u8) = .empty;
    defer units.deinit(t.allocator);
    try pipe.appendForeignParent(&units, t.allocator, 10, 3, 10);
    try comp.feed(units.items);
    try t.expectEqual(@as(usize, 1), tv.foreign_events);
    try t.expectEqual(@as(u32, 10), tv.foreign_child);
    try t.expectEqual(@as(u32, 3), tv.foreign_conn);
    try t.expectEqual(@as(u32, 10), tv.foreign_sid);
    try t.expectEqual(@as(u32, 10), comp.surfaces.get(10).?.foreign_parent);
    try t.expectEqual(@as(u32, 3), comp.surfaces.get(10).?.foreign_parent_conn);
    try t.expect(comp.surfaces.get(10).?.foreign_parent_remote);
    // The local xdg_toplevel.set_parent path is untouched by all this.
    try t.expectEqual(@as(u32, 0), comp.surfaces.get(10).?.tl_parent);
    try t.expectEqual(@as(u32, 0), tv.child_parent);

    // The parent dies: the clear arrives the same way.
    units.clearRetainingCapacity();
    try pipe.appendForeignParent(&units, t.allocator, 10, 0, 0);
    try comp.feed(units.items);
    try t.expectEqual(@as(usize, 2), tv.foreign_events);
    try t.expectEqual(@as(u32, 0), comp.surfaces.get(10).?.foreign_parent);
    try t.expect(!comp.dead);
}

test "xdg-foreign: an old replica skips the unit instead of dying" {
    // The unit tag is append-only and unknown tags skip cleanly, so a
    // viewer that predates it degrades to no cross-connection
    // parenting rather than to a broken stream. (The state-sync gate
    // is the belt: pre-v10 viewers stop receiving the channel at all
    // the moment an app binds xdg-foreign.)
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    comp.lenient = true;
    try foreignSetup(&comp);
    try foreignToplevel(&comp, 10);
    comp.clearOut();

    var units: std.ArrayList(u8) = .empty;
    defer units.deinit(t.allocator);
    // A tag from the future, then a normal one: the stream survives.
    try pipe.appendUnit(&units, t.allocator, @enumFromInt(250), "junk");
    try pipe.appendForeignParent(&units, t.allocator, 10, 3, 10);
    try comp.feed(units.items);
    try t.expect(!comp.dead);
    try t.expectEqual(@as(usize, 1), tv.foreign_events);
}

// ─── xdg-dialog v1 tests ────────────────────────────────────────

/// xdg_wm_dialog_v1.get_xdg_dialog(id, toplevel) on `manager`.
fn dialogCreateReq(comp: *Compositor, manager: u32, id: u32, toplevel: u32) !void {
    var buf: [32]u8 = undefined;
    var b = wire.Builder.init(&buf, manager, 1);
    b.putNewId(id);
    b.putObject(toplevel);
    try req(comp, try b.finish());
}

/// xdg_dialog_v1.set_modal / unset_modal.
fn dialogModalReq(comp: *Compositor, id: u32, modal: bool) !void {
    var buf: [16]u8 = undefined;
    var b = wire.Builder.init(&buf, id, if (modal) 1 else 2);
    try req(comp, try b.finish());
}

/// registry + wl_compositor(3) + xdg_wm_base(4) + xdg_wm_dialog_v1(7).
fn dialogSetup(comp: *Compositor) !void {
    try getRegistry(comp);
    try bindGlobal(comp, 1, "wl_compositor", 6, 3);
    try bindGlobal(comp, 5, "xdg_wm_base", 6, 4);
    try bindGlobal(comp, 27, "xdg_wm_dialog_v1", 1, 7);
}

test "xdg-dialog: set_modal reaches the view and the gate latches at bind" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    try getRegistry(&comp);
    try bindGlobal(&comp, 1, "wl_compositor", 6, 3);
    try bindGlobal(&comp, 5, "xdg_wm_base", 6, 4);
    try t.expect(!comp.used_dialog);
    try bindGlobal(&comp, 27, "xdg_wm_dialog_v1", 1, 7);
    try t.expect(!comp.dead);
    // A v10 replica has no xdg_wm_dialog_v1 at all, so the bind alone
    // must raise the viewer floor.
    try t.expect(comp.used_dialog);

    try foreignToplevel(&comp, 10); // surface 10, xdg_toplevel 12
    comp.clearOut();

    try dialogCreateReq(&comp, 7, 30, 12);
    try dialogModalReq(&comp, 30, true);
    try t.expect(comp.surfaces.get(10).?.modal);
    try t.expectEqual(@as(usize, 1), tv.modal_events);
    try t.expectEqual(@as(u32, 10), tv.modal_sid);
    try t.expectEqual(@as(?bool, true), tv.modal);

    // Repeats are idempotent; unset reports once.
    try dialogModalReq(&comp, 30, true);
    try t.expectEqual(@as(usize, 1), tv.modal_events);
    try dialogModalReq(&comp, 30, false);
    try t.expect(!comp.surfaces.get(10).?.modal);
    try t.expectEqual(@as(usize, 2), tv.modal_events);
    try t.expectEqual(@as(?bool, false), tv.modal);

    // Modality dies with the dialog object.
    try dialogModalReq(&comp, 30, true);
    try t.expect(comp.surfaces.get(10).?.modal);
    var buf: [32]u8 = undefined;
    var db = wire.Builder.init(&buf, 30, 0); // destroy
    try req(&comp, try db.finish());
    try t.expect(!comp.surfaces.get(10).?.modal);
    try t.expectEqual(@as(?bool, false), tv.modal);
    try t.expect(!comp.dead);
}

test "xdg-dialog: modality survives a state_sync into a fresh replica" {
    var btv = TestView{};
    var brain = try Compositor.init(t.allocator, btv.view());
    defer brain.deinit();
    try dialogSetup(&brain);
    try foreignToplevel(&brain, 10);
    try dialogCreateReq(&brain, 7, 30, 12);
    try dialogModalReq(&brain, 30, true);
    brain.clearOut();

    const blob = try brain.serializeState(t.allocator);
    defer t.allocator.free(blob);

    var rtv = TestView{};
    var replica = try Compositor.init(t.allocator, rtv.view());
    defer replica.deinit();
    replica.lenient = true;
    var units: std.ArrayList(u8) = .empty;
    defer units.deinit(t.allocator);
    try pipe.appendUnit(&units, t.allocator, .state_sync, blob);
    try replica.feed(units.items);
    try t.expect(replica.surfaces.get(10).?.modal);
    try t.expectEqual(@as(?bool, true), rtv.modal);
    replica.clearOut();

    // The dialog object came across too, so a later unset still lands.
    try dialogModalReq(&replica, 30, false);
    try t.expect(!replica.surfaces.get(10).?.modal);
    try t.expectEqual(@as(?bool, false), rtv.modal);
    try t.expect(!replica.dead);
}


test "state-sync: a v10 replica gets no modality field and no dialog table" {
    // Downgrade must be lossless for the OLD reader: it never sees a
    // byte it cannot place. (It also never receives such a session —
    // the bind raises native_state_min to 11 — but serializing for it
    // must still be well-formed.)
    var btv = TestView{};
    var brain = try Compositor.init(t.allocator, btv.view());
    defer brain.deinit();
    try getRegistry(&brain);
    try bindGlobal(&brain, 1, "wl_compositor", 6, 3);
    try bindGlobal(&brain, 5, "xdg_wm_base", 6, 4);
    try foreignToplevel(&brain, 10);
    brain.clearOut();

    const v10 = try brain.serializeStateVersion(t.allocator, 10);
    defer t.allocator.free(v10);
    const v11 = try brain.serializeStateVersion(t.allocator, 11);
    defer t.allocator.free(v11);
    try t.expectEqual(@as(u8, 10), v10[0]);
    try t.expectEqual(@as(u8, 11), v11[0]);
    // One modality byte per surface + the (empty) dialog table count.
    try t.expectEqual(v10.len + 1 + 4, v11.len);

    var rtv = TestView{};
    var replica = try Compositor.init(t.allocator, rtv.view());
    defer replica.deinit();
    replica.lenient = true;
    var units: std.ArrayList(u8) = .empty;
    defer units.deinit(t.allocator);
    try pipe.appendUnit(&units, t.allocator, .state_sync, v10);
    try replica.feed(units.items);
    try t.expect(!replica.dead);
    try t.expect(!replica.surfaces.get(10).?.modal);
    try t.expectEqual(@as(usize, 0), rtv.modal_events);
}
