//! sketerm-web wire protocol v1: framing plus payload (de)serialization.
//!
//! THE compatibility surface between the GUI and a browser helper, and
//! deliberately engine-agnostic: no CEF type, id or enum may ever appear
//! here, so a future Servo/Ladybird helper can speak it unchanged. Rules
//! (same as src/mux/wire.zig, whose discipline this follows):
//!   - little-endian, length-prefixed frames and payloads
//!   - tag values are APPEND-ONLY; readers skip unknown frames
//!   - optional features are new frames gated by capabilities, never a
//!     version bump
//!
//! Pure code: std only, no CEF, no GTK, no sockets. Unit-tested headless
//! in both test roots.

const std = @import("std");

/// Protocol revision carried by `hello`/`hello_ack`.
pub const PROTO_VERSION: u32 = 1;

/// Capabilities a v1 helper advertises. Reserved-but-unimplemented
/// names live in docs/proposal-browser-protocol.md, not here.
pub const CAP_FRAMES_SHM = "frames-shm";
/// Frames delivered as dma-buf planes (`frame_dmabuf`) instead of a
/// memfd of pixels. Advertised only when the helper actually got a GPU
/// process; a client must keep handling `frame_damage` regardless,
/// because the engine falls back to software compositing on its own.
pub const CAP_FRAMES_DMABUF = "frames-dmabuf";
pub const CAP_INPUT = "input";
pub const CAP_NAVIGATION = "navigation";
pub const CAP_SEMANTIC = "semantic";
/// The helper accepts `view_create_url`: a view created directly AT a
/// url, so no blank document is ever minted for it. A client without
/// this capability keeps using `view_create` + `navigate`, which mints
/// two documents (about:blank, then the page) and lets a settle that
/// watches "some url loaded" answer for the blank one.
pub const CAP_VIEW_CREATE_URL = "view-create-url";
/// The helper accepts `view_discard`: a view whose browser is destroyed
/// outright while its ID and address survive, revived on the next
/// `view_show`, navigation or input. A client without this capability
/// keeps sending `view_hide`, which only stops the painting.
pub const CAP_DISCARD = "discard";
/// The helper accepts `devtools_show`: the engine's own inspector,
/// opened as ANOTHER windowless view the client presents like any
/// other. No remote debugging port is ever opened.
pub const CAP_DEVTOOLS = "devtools";
/// The helper accepts `print_pdf`: render a view to a PDF file at a
/// path IT can write (helper and client are the same machine in v1).
pub const CAP_PRINT_PDF = "print-pdf";
/// The helper accepts `find`/`find_stop` and answers with
/// `ev_find_result`.
pub const CAP_FIND = "find";
/// The helper accepts `set_zoom` (user zoom, on top of any DPR zoom).
pub const CAP_ZOOM = "zoom";
/// The helper suppresses the engine's own context menu and posts
/// `ev_context_menu` instead.
pub const CAP_CONTEXT_MENU = "context-menu";
/// The helper runs an in-process network filter engine and accepts the
/// 0x80-block interception frames. Blocking decisions NEVER round-trip
/// to the client — the client only configures, polls the bounded
/// request log, and receives coalesced per-view counters.
pub const CAP_INTERCEPT = "intercept";
/// The helper reports certificate errors as `ev_cert_error` and waits
/// for a `cert_decision` instead of failing the load. A client without
/// it sees only the generic `ev_load_error` an older helper produced,
/// which is exactly the pre-interstitial behaviour.
pub const CAP_TLS = "tls";
/// The helper hands permission prompts to the client (`ev_permission` /
/// `permission_decision`) instead of letting the engine's default
/// handling deny them.
pub const CAP_PERMISSIONS = "permissions";
/// The helper reports file downloads: an `ev_download_offer` HOLDS the
/// engine's target decision until a `download_decide` answers it, then
/// coalesced `ev_download_progress` frames follow, and a
/// `download_cancel` aborts a running one. A client without it never
/// sees a download at all (the engine cancels them without a handler),
/// which is the pre-downloads behaviour.
pub const CAP_DOWNLOADS = "downloads";
/// The helper accepts `a11y_enable` and, for a view it was enabled on,
/// streams the engine's accessibility tree as `ev_a11y_tree` /
/// `ev_a11y_loc` / `ev_a11y_event` frames (the 0x70 block). Nothing is
/// streamed for a view that never asked: engine-side accessibility is
/// not free, and an unsolicited stream would break the backlog rule.
pub const CAP_A11Y = "a11y";
/// The helper accepts `context_create`/`context_destroy`: per-tab
/// identity contexts (separate cookie jars / caches), each optionally
/// pointed at a proxy. A view's `context` field then selects one
/// (0 = the shared default context). A client without this capability
/// keeps sending `context = 0` and every view shares one jar.
pub const CAP_CONTEXTS = "contexts";

/// Refuse to buffer a frame larger than this; a peer claiming more is
/// desynchronised, not ambitious.
pub const MAX_FRAME: u32 = 16 * 1024 * 1024;

/// Frame tags, allocated in per-family blocks (see the spec's reserved
/// ranges). Non-exhaustive because an unknown tag must be a value, not
/// a decode failure.
pub const Tag = enum(u8) {
    hello = 0x01,
    hello_ack = 0x02,
    view_create = 0x10,
    view_destroy = 0x11,
    view_resize = 0x12,
    view_show = 0x13,
    view_hide = 0x14,
    view_max_fps = 0x15,
    view_create_url = 0x16,
    view_discard = 0x17,
    navigate = 0x18,
    nav_action = 0x19,
    input_pointer = 0x20,
    input_scroll = 0x21,
    input_key = 0x22,
    input_ime = 0x23,
    input_focus = 0x24,
    frame_buffer = 0x30,
    frame_damage = 0x31,
    frame_release = 0x32,
    frame_request = 0x33,
    frame_dmabuf = 0x34,
    ev_load = 0x40,
    ev_load_error = 0x41,
    ev_title = 0x42,
    ev_favicon = 0x43,
    ev_nav_state = 0x44,
    ev_popup_request = 0x45,
    ev_cursor = 0x46,
    ev_console = 0x47,
    ev_crashed = 0x48,
    find = 0x50,
    find_stop = 0x51,
    set_zoom = 0x52,
    ev_find_result = 0x53,
    ev_context_menu = 0x54,
    ev_cert_error = 0x55,
    cert_decision = 0x56,
    ev_permission = 0x57,
    permission_decision = 0x58,
    sem_snapshot_req = 0x60,
    sem_snapshot = 0x61,
    sem_act = 0x62,
    sem_act_result = 0x63,
    sem_expand = 0x64,
    sem_expand_result = 0x65,
    sem_query = 0x66,
    sem_query_result = 0x67,
    sem_read = 0x68,
    sem_read_result = 0x69,
    a11y_enable = 0x70,
    ev_a11y_tree = 0x71,
    ev_a11y_loc = 0x72,
    ev_a11y_event = 0x73,
    ev_download_offer = 0x78,
    download_decide = 0x79,
    ev_download_progress = 0x7A,
    download_cancel = 0x7B,
    intercept_set = 0x80,
    intercept_lists = 0x81,
    intercept_status_req = 0x82,
    intercept_status = 0x83,
    intercept_log_req = 0x84,
    intercept_log = 0x85,
    context_create = 0x90,
    context_destroy = 0x91,
    sem_eval = 0xA0,
    sem_eval_result = 0xA1,
    devtools_show = 0xA2,
    ev_devtools_view = 0xA3,
    print_pdf = 0xA4,
    ev_print_pdf_done = 0xA5,
    _,

    /// Whether this build knows the frame; unknown tags are skipped.
    pub fn known(self: Tag) bool {
        return switch (self) {
            _ => false,
            else => true,
        };
    }
};

/// `nav_action` action byte.
pub const NavAct = enum(u8) {
    back = 0,
    forward = 1,
    reload = 2,
    stop = 3,
    reload_no_cache = 4,
    _,
};

/// `input_pointer` kind byte.
pub const PointerKind = enum(u8) { move = 0, down = 1, up = 2, leave = 3, _ };

/// `input_key` kind byte.
pub const KeyKind = enum(u8) { down = 0, up = 1, _ };

/// `input_ime` kind byte.
pub const ImeKind = enum(u8) { compose = 0, commit = 1, cancel = 2, _ };

/// `ev_load` state byte.
pub const LoadState = enum(u8) { started = 0, committed = 1, finished = 2, failed = 3 };

/// `ev_popup_request` disposition byte.
pub const Disposition = enum(u8) { new_tab = 0, new_window = 1, popup = 2 };

/// `ev_cursor` cursor byte: a deliberately small CSS-cursor subset;
/// anything else resolves to `default`.
pub const Cursor = enum(u8) {
    default = 0,
    pointer = 1,
    text = 2,
    wait = 3,
    crosshair = 4,
    not_allowed = 5,
    grab = 6,
    grabbing = 7,
    ew_resize = 8,
    ns_resize = 9,
};

/// Modifier bits shared by every input frame.
pub const mod_shift: u32 = 1;
pub const mod_ctrl: u32 = 2;
pub const mod_alt: u32 = 4;
pub const mod_super: u32 = 8;
pub const mod_capslock: u32 = 16;
pub const mod_numlock: u32 = 32;

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

/// A u32-length payload, distinct from a `str` (u16) because a semantic
/// snapshot of a real page routinely exceeds 64KB. Wrapped in a struct
/// so the generic encoder can tell the two apart by field TYPE.
pub const Text = struct { s: []const u8 };

/// `sem_snapshot_req` mode byte (append-only values).
///
/// `auto` answers with ONE coalesced delta from the tree as the client
/// last CONSUMED it straight to the current tree — spontaneous
/// mutations are folded helper-side and never pushed, so intermediate
/// churn cancels out. `full` restates the whole tree. `history` opts
/// back into the per-revision replay of every fold since the last
/// consume (bounded helper-side), for debugging pages whose changes
/// appear and vanish between snapshots.
pub const SnapMode = enum(u8) { auto = 0, full = 1, history = 2, _ };

/// `sem_snapshot_req` detail byte.
pub const SnapDetail = enum(u8) { minimal = 0, normal = 1, full_text = 2, _ };

/// `sem_snapshot` kind byte; mirrors `semantic.Kind`.
pub const SnapKind = enum(u8) { full = 0, delta = 1, _ };

/// `sem_act` action byte. `click` and `hover` are synthesized through
/// the ORDINARY input path at the element centre, never scripted, so
/// the page sees `isTrusted`.
pub const SemAct = enum(u8) {
    click = 0,
    focus = 1,
    set_value = 2,
    scroll_into_view = 3,
    hover = 4,
    _,
};

/// `sem_query` kind byte (append-only values).
///
/// `visible` is the link-hints request: `arg` is "<vw> <vh>" (logical
/// px), and unlike the other kinds the helper answers it AFTER a fresh
/// DOM walk — hint rects must reflect the current scroll position,
/// which mutation observation alone never sees. The reply payload is
/// the tab-separated format of `semantic.View.renderHints`; the walk
/// folds into the live tree and deliberately does NOT advance the
/// consumed base.
pub const SemQuery = enum(u8) { find_text = 0, subtree = 1, focused = 2, visible = 3, _ };

// ---------------------------------------------------------------------
// Frame payload types. Field ORDER is the wire order; every type carries
// its tag. Slice fields borrow from the decoded payload buffer.
// ---------------------------------------------------------------------

pub const Hello = struct {
    pub const tag: Tag = .hello;
    proto: u32,
    client_name: []const u8,
};

pub const HelloAck = struct {
    pub const tag: Tag = .hello_ack;
    proto: u32,
    engine_name: []const u8,
    engine_version: []const u8,
    caps: []const []const u8,

    pub fn encodeTo(self: HelloAck, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.proto);
        try putStr(gpa, out, self.engine_name);
        try putStr(gpa, out, self.engine_version);
        try putU16(gpa, out, @intCast(self.caps.len));
        for (self.caps) |cap| try putStr(gpa, out, cap);
    }

    /// Caller owns the returned `caps` slice (the strings themselves
    /// still borrow from `payload`).
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !HelloAck {
        var cur = Cur{ .buf = payload };
        const proto = try cur.readU32();
        const name = try cur.readStr();
        const ver = try cur.readStr();
        const n = try cur.readU16();
        const caps = try gpa.alloc([]const u8, n);
        errdefer gpa.free(caps);
        for (caps) |*cap| cap.* = try cur.readStr();
        return .{ .proto = proto, .engine_name = name, .engine_version = ver, .caps = caps };
    }
};

pub const ViewCreate = struct {
    pub const tag: Tag = .view_create;
    view: u32,
    w: u16,
    h: u16,
    scale_x1000: u16,
    context: u32,
};

/// `view_create` with the first url built in, gated by
/// `CAP_VIEW_CREATE_URL`.
///
/// It is a NEW frame rather than a url field on `ViewCreate` because the
/// wire is append-only: adding a field would change an existing frame's
/// layout, and an older peer would decode the next frame's bytes as
/// part of this one. The two frames are mutually exclusive per view —
/// send exactly one.
///
/// An empty `url` means the same as `view_create` (a blank document).
/// The point of the frame is that a NON-empty url produces exactly ONE
/// document: create-then-navigate always produced two (about:blank plus
/// the page), so a "did the load settle" test could be satisfied by the
/// blank one and hand back a snapshot of an empty page.
pub const ViewCreateUrl = struct {
    pub const tag: Tag = .view_create_url;
    view: u32,
    w: u16,
    h: u16,
    scale_x1000: u16,
    context: u32,
    url: []const u8,
};

pub const ViewDestroy = struct {
    pub const tag: Tag = .view_destroy;
    view: u32,
};

/// Destroy a view's BROWSER while keeping the view (capability
/// `discard`): the id, its logical geometry, its scale and its current
/// address survive, everything the engine held for it does not.
///
/// Distinct from `view_hide`, which only stops the painting: after this
/// the page is gone from memory entirely. The next `view_show`,
/// `navigate`, `nav_action` or input frame for the id recreates the
/// browser at the stored address, so a client sees nothing but a
/// reload. NAVIGATION HISTORY IS LOST — back/forward start empty again,
/// as does any unsubmitted form state, which is the price of the
/// memory and the reason this is a deliberate client decision rather
/// than something the helper does on its own.
///
/// Discarding a view that has no browser is a no-op, so a client may
/// send it twice.
pub const ViewDiscard = struct {
    pub const tag: Tag = .view_discard;
    view: u32,
};

pub const ViewResize = struct {
    pub const tag: Tag = .view_resize;
    view: u32,
    w: u16,
    h: u16,
    scale_x1000: u16,
};

pub const ViewShow = struct {
    pub const tag: Tag = .view_show;
    view: u32,
};

pub const ViewHide = struct {
    pub const tag: Tag = .view_hide;
    view: u32,
};

pub const Navigate = struct {
    pub const tag: Tag = .navigate;
    view: u32,
    url: []const u8,
};

pub const NavAction = struct {
    pub const tag: Tag = .nav_action;
    view: u32,
    action: u8,
};

pub const InputPointer = struct {
    pub const tag: Tag = .input_pointer;
    view: u32,
    kind: u8,
    x: i32,
    y: i32,
    button: u8,
    clicks: u8,
    mods: u32,
};

pub const InputScroll = struct {
    pub const tag: Tag = .input_scroll;
    view: u32,
    x: i32,
    y: i32,
    dx: i32,
    dy: i32,
    mods: u32,
};

pub const InputKey = struct {
    pub const tag: Tag = .input_key;
    view: u32,
    kind: u8,
    keyval: u32,
    keycode: u32,
    mods: u32,
    text: []const u8,
};

pub const InputIme = struct {
    pub const tag: Tag = .input_ime;
    view: u32,
    kind: u8,
    text: []const u8,
    cursor: i32,
};

pub const InputFocus = struct {
    pub const tag: Tag = .input_focus;
    view: u32,
    focused: u8,
};

pub const FrameBuffer = struct {
    pub const tag: Tag = .frame_buffer;
    view: u32,
    buf_id: u32,
    w: u16,
    h: u16,
    stride: u32,
};

pub const FrameDamage = struct {
    pub const tag: Tag = .frame_damage;
    view: u32,
    buf_id: u32,
    gen: u32,
    rects: []const Rect,

    pub fn encodeTo(self: FrameDamage, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putU32(gpa, out, self.buf_id);
        try putU32(gpa, out, self.gen);
        try putU16(gpa, out, @intCast(self.rects.len));
        for (self.rects) |r| {
            try putU16(gpa, out, r.x);
            try putU16(gpa, out, r.y);
            try putU16(gpa, out, r.w);
            try putU16(gpa, out, r.h);
        }
    }

    /// Caller owns the returned `rects` slice.
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !FrameDamage {
        var cur = Cur{ .buf = payload };
        const view = try cur.readU32();
        const buf_id = try cur.readU32();
        const gen = try cur.readU32();
        const n = try cur.readU16();
        const rects = try gpa.alloc(Rect, n);
        errdefer gpa.free(rects);
        for (rects) |*r| {
            r.x = try cur.readU16();
            r.y = try cur.readU16();
            r.w = try cur.readU16();
            r.h = try cur.readU16();
        }
        return .{ .view = view, .buf_id = buf_id, .gen = gen, .rects = rects };
    }
};

pub const FrameRelease = struct {
    pub const tag: Tag = .frame_release;
    view: u32,
    buf_id: u32,
};

/// Ask the engine to produce ONE frame ("external begin frame"). The
/// client's request rate IS the view's frame rate, so a client that
/// stops asking gets a still page — see the helper's watchdog, which
/// keeps a self-paced floor under exactly that case.
///
/// There is deliberately no per-request acknowledgement: whether a
/// request produced pixels is already observable as a `frame_damage`
/// for the view, and an ack frame would double the socket traffic of
/// the whole path to say something the client can count.
pub const FrameRequest = struct {
    pub const tag: Tag = .frame_request;
    view: u32,
    /// Reserved, must be 0. Room for future per-request hints (force a
    /// full repaint, "this one is a resize settle", …) without a tag.
    flags: u8,
};

/// Client -> helper: cap this view's frame production at `fps` (0 =
/// engine maximum). With the engine's own scheduler pacing paints —
/// the default since external begin frames measured a fixed ~30ms of
/// added input latency — this is how `browser_max_fps` and the display's
/// real refresh rate reach the engine (`set_windowless_frame_rate`).
pub const ViewMaxFps = struct {
    pub const tag: Tag = .view_max_fps;
    view: u32,
    fps: u16,
};

/// Max planes in a `frame_dmabuf`; matches CEF's
/// kAcceleratedPaintMaxPlanes and DRM's own limit.
pub const MAX_PLANES = 4;

/// One dma-buf plane: where it sits in the object its fd names.
pub const Plane = struct { stride: u32, offset: u32 };

/// A GPU frame: the planes of a dma-buf the engine just rendered into,
/// with one SCM_RIGHTS descriptor per plane attached to the frame.
///
/// `buf_id` identifies the underlying BUFFER, not the paint: the engine
/// renders into a small pool and cycles through it, so a client that
/// caches its imported texture per `buf_id` imports each pool member
/// once instead of once per frame. The descriptors are sent every time
/// anyway (a stateless sender is worth four `dup`s a frame); a client
/// that already has the buffer just closes them.
///
/// There are deliberately no damage rects: the import is zero-copy, so
/// there is nothing for the client to upload selectively. `gen` is the
/// same monotonic per-view paint counter `frame_damage` carries.
///
/// Buffer contents are NOT owned by the client: the engine writes into
/// the pool again as soon as it comes round, which is the same benign
/// tearing the memfd path documents.
pub const FrameDmabuf = struct {
    pub const tag: Tag = .frame_dmabuf;
    view: u32,
    buf_id: u32,
    gen: u32,
    /// PHYSICAL pixels, like `frame_buffer`'s w/h.
    w: u16,
    h: u16,
    /// DRM FourCC (`DRM_FORMAT_ARGB8888` and friends), not a CEF enum.
    fourcc: u32,
    /// DRM format modifier; 0 is LINEAR.
    modifier: u64,
    nplanes: u8,
    planes: [MAX_PLANES]Plane,

    pub fn encodeTo(self: FrameDmabuf, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putU32(gpa, out, self.buf_id);
        try putU32(gpa, out, self.gen);
        try putU16(gpa, out, self.w);
        try putU16(gpa, out, self.h);
        try putU32(gpa, out, self.fourcc);
        try putU32(gpa, out, @truncate(self.modifier));
        try putU32(gpa, out, @truncate(self.modifier >> 32));
        try putU8(gpa, out, self.nplanes);
        for (self.planes[0..self.nplanes]) |p| {
            try putU32(gpa, out, p.stride);
            try putU32(gpa, out, p.offset);
        }
    }

    /// Not `decodeAlloc`: the plane count is bounded, so the frame
    /// decodes into a fixed array and needs no allocator.
    pub fn decodeFrom(payload: []const u8) !FrameDmabuf {
        var cur = Cur{ .buf = payload };
        var out: FrameDmabuf = .{
            .view = try cur.readU32(),
            .buf_id = try cur.readU32(),
            .gen = try cur.readU32(),
            .w = try cur.readU16(),
            .h = try cur.readU16(),
            .fourcc = try cur.readU32(),
            .modifier = 0,
            .nplanes = 0,
            .planes = @splat(.{ .stride = 0, .offset = 0 }),
        };
        const lo = try cur.readU32();
        const hi = try cur.readU32();
        out.modifier = @as(u64, lo) | (@as(u64, hi) << 32);
        const n = try cur.readU8();
        if (n == 0 or n > MAX_PLANES) return error.BadPlaneCount;
        out.nplanes = n;
        for (out.planes[0..n]) |*p| {
            p.stride = try cur.readU32();
            p.offset = try cur.readU32();
        }
        return out;
    }
};

pub const EvLoad = struct {
    pub const tag: Tag = .ev_load;
    view: u32,
    state: u8,
    url: []const u8,
};

pub const EvLoadError = struct {
    pub const tag: Tag = .ev_load_error;
    view: u32,
    code: i32,
    url: []const u8,
    msg: []const u8,
};

pub const EvTitle = struct {
    pub const tag: Tag = .ev_title;
    view: u32,
    title: []const u8,
};

pub const EvFavicon = struct {
    pub const tag: Tag = .ev_favicon;
    view: u32,
    url: []const u8,
};

pub const EvNavState = struct {
    pub const tag: Tag = .ev_nav_state;
    view: u32,
    can_back: u8,
    can_fwd: u8,
    loading: u8,
    url: []const u8,
};

/// A page asked for a popup. The helper never opens one: it cancels
/// and reports, so the client decides between a tab, a window and a
/// refusal.
///
/// `user_gesture` is an OPTIONAL TRAILING field — the one shape in
/// which this wire tolerates growing a frame, and only because the
/// decoder below treats a payload that ends early as "field absent"
/// instead of `error.Truncated`. It defaults to 1 (a gesture) when
/// absent, so a client with a popup policy keeps a pre-gesture helper's
/// popups working exactly as before rather than blocking all of them.
/// Nothing may be appended after it unless the same rule is kept, and
/// no EXISTING field may ever be widened or reordered.
pub const EvPopupRequest = struct {
    pub const tag: Tag = .ev_popup_request;
    view: u32,
    url: []const u8,
    disposition: u8,
    /// 1 when the page asked from inside a real user interaction.
    user_gesture: u8 = 1,

    pub fn encodeTo(self: EvPopupRequest, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putStr(gpa, out, self.url);
        try putU8(gpa, out, self.disposition);
        try putU8(gpa, out, self.user_gesture);
    }

    pub fn decodeFrom(payload: []const u8) !EvPopupRequest {
        var cur = Cur{ .buf = payload };
        return .{
            .view = try cur.readU32(),
            .url = try cur.readStr(),
            .disposition = try cur.readU8(),
            .user_gesture = cur.readU8() catch 1,
        };
    }
};

pub const EvCursor = struct {
    pub const tag: Tag = .ev_cursor;
    view: u32,
    cursor: u8,
};

pub const EvConsole = struct {
    pub const tag: Tag = .ev_console;
    view: u32,
    level: u8,
    msg: []const u8,
};

pub const EvCrashed = struct {
    pub const tag: Tag = .ev_crashed;
    view: u32,
};

// -- find / zoom / context menu (0x50 block, caps "find"/"zoom"/
//    "context-menu") --------------------------------------------------

/// Find-in-page. `find_next = 0` starts a NEW search for `text`
/// (highlighting every match and selecting the first); `find_next = 1`
/// steps through the current search's matches in `forward` direction.
pub const Find = struct {
    pub const tag: Tag = .find;
    view: u32,
    forward: u8,
    match_case: u8,
    find_next: u8,
    text: []const u8,
};

/// End the search. `clear_selection = 1` also drops the highlight the
/// active match left behind.
pub const FindStop = struct {
    pub const tag: Tag = .find_stop;
    view: u32,
    clear_selection: u8,
};

/// USER zoom for a view, as the engine's log-scale zoom LEVEL x100:
/// factor = 1.2 ^ (level_x100 / 100), so +100 is one conventional
/// browser zoom step (120%) and 0 resets. Distinct from the DPR zoom
/// the helper applies internally in accelerated mode — the helper adds
/// the two, so the client only ever speaks user intent.
pub const SetZoom = struct {
    pub const tag: Tag = .set_zoom;
    view: u32,
    level_x100: i32,
};

/// Match count for the current search. Several non-final updates may
/// precede the `final = 1` one as the engine keeps counting.
pub const EvFindResult = struct {
    pub const tag: Tag = .ev_find_result;
    view: u32,
    /// Total matches found so far.
    count: i32,
    /// 1-based ordinal of the active match, 0 when there is none.
    active: i32,
    final: u8,
};

/// `ev_context_menu` flags bit: the hit test found a link, and
/// `link_url` carries it.
pub const ctx_flag_link: u8 = 1;
/// `ev_context_menu` flags bit: the hit test is an editable field.
pub const ctx_flag_editable: u8 = 2;

/// The page asked for a context menu (the engine's own menu is
/// suppressed). x/y are LOGICAL view coordinates, same space as
/// `input_pointer`.
pub const EvContextMenu = struct {
    pub const tag: Tag = .ev_context_menu;
    view: u32,
    x: i32,
    y: i32,
    flags: u8,
    link_url: []const u8,
};

// -- TLS interstitials (capability "tls") -----------------------------

/// The engine refused a certificate and is HOLDING the request. Exactly
/// one `cert_decision` for the same view resolves it; until then the
/// load is neither committed nor failed, so a client that never answers
/// leaves the page hanging (view destruction cancels it helper-side).
///
/// `code` is the engine's own error number, the same space
/// `ev_load_error` uses, and `msg` its symbolic name. `fingerprint` is
/// the certificate's SHA-256 as lowercase hex, or empty when the engine
/// gave no certificate to hash — never trust it to be present.
pub const EvCertError = struct {
    pub const tag: Tag = .ev_cert_error;
    view: u32,
    code: i32,
    /// The url whose request is held.
    url: []const u8,
    /// Host of `url`, extracted helper-side so every client agrees on
    /// what the interstitial names.
    host: []const u8,
    msg: []const u8,
    subject: []const u8,
    issuer: []const u8,
    fingerprint: []const u8,
};

/// Answer to `ev_cert_error`. `proceed = 1` continues the request with
/// the certificate accepted FOR THIS REQUEST only — nothing is
/// remembered helper-side, deliberately: a persisted exception is a
/// stored security decision and belongs to whoever owns site settings,
/// not to a stateless render helper.
pub const CertDecision = struct {
    pub const tag: Tag = .cert_decision;
    view: u32,
    proceed: u8,
};

// -- permission prompts (capability "permissions") --------------------

/// Permission bits, deliberately OUR OWN numbering: an engine's
/// permission enum is not part of this wire. Anything the helper cannot
/// map lands in `perm_other`, which a client must still be able to name
/// and prompt for.
pub const perm_geolocation: u32 = 1 << 0;
pub const perm_notifications: u32 = 1 << 1;
pub const perm_camera: u32 = 1 << 2;
pub const perm_microphone: u32 = 1 << 3;
pub const perm_midi: u32 = 1 << 4;
pub const perm_clipboard: u32 = 1 << 5;
pub const perm_pointer_lock: u32 = 1 << 6;
pub const perm_idle_detection: u32 = 1 << 7;
pub const perm_storage_access: u32 = 1 << 8;
pub const perm_window_management: u32 = 1 << 9;
pub const perm_protected_media: u32 = 1 << 10;
pub const perm_local_fonts: u32 = 1 << 11;
pub const perm_file_system: u32 = 1 << 12;
pub const perm_downloads: u32 = 1 << 13;
pub const perm_sensors: u32 = 1 << 14;
pub const perm_vr: u32 = 1 << 15;
pub const perm_other: u32 = 1 << 31;

/// A page asked for a permission and the engine is HOLDING the request.
/// `prompt` identifies it for the matching `permission_decision`; ids
/// are unique per helper process, not per view.
pub const EvPermission = struct {
    pub const tag: Tag = .ev_permission;
    view: u32,
    prompt: u64,
    /// Origin as the engine reports it ("https://example.com").
    origin: []const u8,
    /// One or more `perm_*` bits; a single prompt can carry several
    /// (a call asking for camera AND microphone is one decision).
    types: u32,
};

/// Answer to `ev_permission`. An id the helper no longer holds — the
/// page navigated away, the view went — is ignored, so a client may
/// always answer late.
pub const PermissionDecision = struct {
    pub const tag: Tag = .permission_decision;
    view: u32,
    prompt: u64,
    allow: u8,
};

// -- downloads (0x78 block, capability "downloads") -------------------

/// The page started a download and the engine is HOLDING its target
/// decision. Exactly one `download_decide` for the same id resolves it;
/// until then the bytes may already be streaming into the engine's own
/// staging, but nothing lands anywhere the user can see. `id` is the
/// ENGINE's download id, unique per helper process. View destruction
/// (and `view_discard`) cancels every held or running download of the
/// view helper-side, so a client that never answers leaks nothing.
///
/// `total` is 0 when the server sent no length. `mime` may be empty.
pub const EvDownloadOffer = struct {
    pub const tag: Tag = .ev_download_offer;
    view: u32,
    id: u32,
    total: u64,
    url: []const u8,
    /// Engine-suggested file name, never a path.
    name: []const u8,
    mime: []const u8,
};

/// Answer to `ev_download_offer`. A non-empty `path` continues the
/// download INTO that path (helper-side, same machine as the client in
/// v1; existing bytes there are overwritten). An empty `path` cancels
/// it. An id the helper no longer holds is ignored, so a client may
/// always answer late.
pub const DownloadDecide = struct {
    pub const tag: Tag = .download_decide;
    view: u32,
    id: u32,
    path: []const u8,
};

/// Coalesced progress for a decided download: at most one frame per
/// poll iteration per download, however often the engine updates.
/// Exactly one terminal frame (`done` or `failed`) ends every decided
/// download — including one the client cancelled, and one whose view
/// went away mid-flight.
pub const EvDownloadProgress = struct {
    pub const tag: Tag = .ev_download_progress;
    view: u32,
    id: u32,
    received: u64,
    /// 0 while unknown; the engine may learn it mid-download.
    total: u64,
    done: u8,
    /// Canceled or interrupted. `done` and `failed` are exclusive.
    failed: u8,
};

/// Abort a running download. Unknown ids are ignored (the download may
/// have finished in flight).
pub const DownloadCancel = struct {
    pub const tag: Tag = .download_cancel;
    view: u32,
    id: u32,
};

// -- accessibility (0x70 block, capability "a11y") --------------------
//
// The engine's accessibility tree, streamed to the client so a
// PLATFORM projection (AT-SPI on Linux, NSAccessibility on macOS) can
// re-expose the page to a screen reader. Shape rules:
//
//   - Nothing flows until the client sends `a11y_enable` for a view;
//     engine-side accessibility costs real CPU and the stream would
//     otherwise violate the backlog rule.
//   - `ev_a11y_tree` is an INCREMENTAL update, mirroring how engines
//     produce them: a list of nodes that changed (with their full new
//     content and child lists), not a restatement of the whole tree.
//     The first update after enabling restates everything reachable.
//   - Node ids are engine-assigned, stable for the lifetime of a
//     document, and only unique WITHIN a view. Only the root frame's
//     tree is streamed in v1; child-frame (iframe) trees are dropped,
//     so a child id naming a node that never arrives must be treated
//     as an absent child, not an error.
//   - Roles are lowercase tokens: the WAI-ARIA role name where one
//     exists ("button", "heading", "link", "checkbox", ...), plus a
//     small documented extension set ("text" for a static text run,
//     "document" for the root, "generic" for a plain container).
//     Unknown roles must be presented as a generic node, not dropped.

/// Enable (1) or disable (0) accessibility streaming for a view.
/// Idempotent; disabling also stops the engine-side tree production.
pub const A11yEnable = struct {
    pub const tag: Tag = .a11y_enable;
    view: u32,
    enabled: u8,
};

/// One incremental tree update. `nodes` is a sequence of
/// `A11yNode`-encoded records (see `A11yNodeWriter`/`A11yNodeIter`).
/// `node_id_to_clear` names a node whose CHILDREN should be dropped
/// before applying the node list (0 = none); `root_id` is the current
/// root node id; `focus_id` the currently focused node (0 = none).
pub const EvA11yTree = struct {
    pub const tag: Tag = .ev_a11y_tree;
    view: u32,
    root_id: u32,
    node_id_to_clear: u32,
    focus_id: u32,
    nodes: Text,
};

/// Pure geometry deltas (scrolling, layout shifts): a sequence of
/// `A11yLoc` records (see `putA11yLoc`/`A11yLocIter`). Split from
/// `ev_a11y_tree` because scrolling produces them at frame rate and a
/// client that only mirrors structure may skip them cheaply.
pub const EvA11yLoc = struct {
    pub const tag: Tag = .ev_a11y_loc;
    view: u32,
    locs: Text,
};

/// A discrete accessibility event on one node. `event` is a lowercase
/// token from a deliberately small set ("focus", "load-complete");
/// helpers map their engine's vocabulary onto it and DROP what has no
/// mapping, so unknown tokens are new protocol, not engine leakage.
pub const EvA11yEvent = struct {
    pub const tag: Tag = .ev_a11y_event;
    view: u32,
    id: u32,
    event: []const u8,
};

/// `A11yNode.state` bits — OUR numbering, engine enums never cross the
/// wire. Append-only: a bit once assigned is never reused.
pub const ax_focusable: u64 = 1 << 0;
pub const ax_focused: u64 = 1 << 1;
pub const ax_disabled: u64 = 1 << 2;
pub const ax_editable: u64 = 1 << 3;
pub const ax_checked: u64 = 1 << 4;
pub const ax_checked_mixed: u64 = 1 << 5;
pub const ax_selected: u64 = 1 << 6;
pub const ax_expanded: u64 = 1 << 7;
pub const ax_collapsed: u64 = 1 << 8;
pub const ax_invisible: u64 = 1 << 9;
pub const ax_ignored: u64 = 1 << 10;
pub const ax_required: u64 = 1 << 11;
pub const ax_readonly: u64 = 1 << 12;
pub const ax_busy: u64 = 1 << 13;
pub const ax_modal: u64 = 1 << 14;
pub const ax_multiline: u64 = 1 << 15;
pub const ax_protected: u64 = 1 << 16;
pub const ax_hovered: u64 = 1 << 17;
pub const ax_default: u64 = 1 << 18;
pub const ax_visited: u64 = 1 << 19;
pub const ax_multiselectable: u64 = 1 << 20;
pub const ax_autofill_available: u64 = 1 << 21;

/// One node of an `ev_a11y_tree` payload as the decoder yields it.
/// Rect coordinates are CSS pixels RELATIVE to `offset_container`
/// (0 = the tree root / no container); child ids and attribute pairs
/// stay in their raw encoded form so decoding allocates nothing.
pub const A11yNode = struct {
    id: u32,
    state: u64,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    offset_container: u32,
    role: []const u8,
    name: []const u8,
    value: []const u8,
    description: []const u8,
    nchildren: u16,
    child_bytes: []const u8,
    nattrs: u16,
    attr_bytes: []const u8,

    pub fn childAt(self: *const A11yNode, i: usize) u32 {
        return std.mem.readInt(u32, self.child_bytes[i * 4 ..][0..4], .little);
    }

    pub fn attrs(self: *const A11yNode) A11yAttrIter {
        return .{ .cur = .{ .buf = self.attr_bytes }, .left = self.nattrs };
    }
};

pub const A11yAttr = struct { key: []const u8, value: []const u8 };

pub const A11yAttrIter = struct {
    cur: Cur,
    left: u16,

    pub fn next(self: *A11yAttrIter) !?A11yAttr {
        if (self.left == 0) return null;
        self.left -= 1;
        const k = try self.cur.readStr();
        const v = try self.cur.readStr();
        return .{ .key = k, .value = v };
    }
};

/// What a producer hands `A11yNodeWriter.put` — same fields as
/// `A11yNode`, with the lists as real slices.
pub const A11yNodeSpec = struct {
    id: u32,
    state: u64 = 0,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    offset_container: u32 = 0,
    role: []const u8 = "",
    name: []const u8 = "",
    value: []const u8 = "",
    description: []const u8 = "",
    children: []const u32 = &.{},
    attributes: []const A11yAttr = &.{},
};

/// Appends `A11yNode` records to a buffer that becomes an
/// `EvA11yTree.nodes` payload. Shared by the helper and the tests so
/// the encoding cannot fork.
pub const A11yNodeWriter = struct {
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    count: u32 = 0,

    pub fn put(self: *A11yNodeWriter, n: A11yNodeSpec) !void {
        if (n.children.len > std.math.maxInt(u16)) return error.TooManyChildren;
        if (n.attributes.len > std.math.maxInt(u16)) return error.TooManyAttrs;
        try putU32(self.gpa, self.buf, n.id);
        try putU64(self.gpa, self.buf, n.state);
        try putI32(self.gpa, self.buf, n.x);
        try putI32(self.gpa, self.buf, n.y);
        try putI32(self.gpa, self.buf, n.w);
        try putI32(self.gpa, self.buf, n.h);
        try putU32(self.gpa, self.buf, n.offset_container);
        try putStr(self.gpa, self.buf, n.role);
        try putStr(self.gpa, self.buf, n.name);
        try putStr(self.gpa, self.buf, n.value);
        try putStr(self.gpa, self.buf, n.description);
        try putU16(self.gpa, self.buf, @intCast(n.children.len));
        for (n.children) |id| try putU32(self.gpa, self.buf, id);
        try putU16(self.gpa, self.buf, @intCast(n.attributes.len));
        for (n.attributes) |a| {
            try putStr(self.gpa, self.buf, a.key);
            try putStr(self.gpa, self.buf, a.value);
        }
        self.count += 1;
    }
};

/// Walks an `EvA11yTree.nodes` payload. Slices borrow from the
/// payload; nothing allocates.
pub const A11yNodeIter = struct {
    cur: Cur,

    pub fn init(payload: []const u8) A11yNodeIter {
        return .{ .cur = .{ .buf = payload } };
    }

    pub fn next(self: *A11yNodeIter) !?A11yNode {
        if (self.cur.pos >= self.cur.buf.len) return null;
        var n: A11yNode = undefined;
        n.id = try self.cur.readU32();
        n.state = try self.cur.readU64();
        n.x = try self.cur.readI32();
        n.y = try self.cur.readI32();
        n.w = try self.cur.readI32();
        n.h = try self.cur.readI32();
        n.offset_container = try self.cur.readU32();
        n.role = try self.cur.readStr();
        n.name = try self.cur.readStr();
        n.value = try self.cur.readStr();
        n.description = try self.cur.readStr();
        n.nchildren = try self.cur.readU16();
        const cb = @as(usize, n.nchildren) * 4;
        if (self.cur.pos + cb > self.cur.buf.len) return error.Truncated;
        n.child_bytes = self.cur.buf[self.cur.pos..][0..cb];
        self.cur.pos += cb;
        n.nattrs = try self.cur.readU16();
        const attr_start = self.cur.pos;
        var i: u16 = 0;
        while (i < n.nattrs) : (i += 1) {
            _ = try self.cur.readStr();
            _ = try self.cur.readStr();
        }
        n.attr_bytes = self.cur.buf[attr_start..self.cur.pos];
        return n;
    }
};

/// One geometry delta of an `ev_a11y_loc` payload.
pub const A11yLoc = struct {
    id: u32,
    offset_container: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub fn putA11yLoc(gpa: std.mem.Allocator, out: *std.ArrayList(u8), l: A11yLoc) !void {
    try putU32(gpa, out, l.id);
    try putU32(gpa, out, l.offset_container);
    try putI32(gpa, out, l.x);
    try putI32(gpa, out, l.y);
    try putI32(gpa, out, l.w);
    try putI32(gpa, out, l.h);
}

pub const A11yLocIter = struct {
    cur: Cur,

    pub fn init(payload: []const u8) A11yLocIter {
        return .{ .cur = .{ .buf = payload } };
    }

    pub fn next(self: *A11yLocIter) !?A11yLoc {
        if (self.cur.pos >= self.cur.buf.len) return null;
        return .{
            .id = try self.cur.readU32(),
            .offset_container = try self.cur.readU32(),
            .x = try self.cur.readI32(),
            .y = try self.cur.readI32(),
            .w = try self.cur.readI32(),
            .h = try self.cur.readI32(),
        };
    }
};

// -- semantic layer (capability "semantic") ---------------------------

pub const SemSnapshotReq = struct {
    pub const tag: Tag = .sem_snapshot_req;
    view: u32,
    mode: u8,
    detail: u8,
    /// 0 = whole document, else the stable id of a subtree root.
    scope: u32,
};

pub const SemSnapshot = struct {
    pub const tag: Tag = .sem_snapshot;
    view: u32,
    doc_gen: u32,
    rev: u32,
    kind: u8,
    payload: Text,
};

pub const SemAction = struct {
    pub const tag: Tag = .sem_act;
    view: u32,
    id: u32,
    action: u8,
    arg: []const u8,
};

pub const SemActResult = struct {
    pub const tag: Tag = .sem_act_result;
    view: u32,
    id: u32,
    ok: u8,
    msg: []const u8,
};

pub const SemExpand = struct {
    pub const tag: Tag = .sem_expand;
    view: u32,
    id: u32,
    off: u32,
    len: u32,
};

pub const SemExpandResult = struct {
    pub const tag: Tag = .sem_expand_result;
    view: u32,
    id: u32,
    off: u32,
    text: []const u8,
};

pub const SemQueryReq = struct {
    pub const tag: Tag = .sem_query;
    view: u32,
    kind: u8,
    arg: []const u8,
};

pub const SemQueryResult = struct {
    pub const tag: Tag = .sem_query_result;
    view: u32,
    payload: Text,
};

pub const SemRead = struct {
    pub const tag: Tag = .sem_read;
    view: u32,
};

pub const SemReadResult = struct {
    pub const tag: Tag = .sem_read_result;
    view: u32,
    markdown: Text,
};

// -- script evaluation (0xA0 block, capability "semantic") ------------

/// Evaluate `code` in the view's main frame. `flags` bit 0 = resolve a
/// returned promise before answering; `timeout_ms` bounds that wait
/// helper-side so a never-settling promise still produces one reply.
pub const SemEval = struct {
    pub const tag: Tag = .sem_eval;
    view: u32,
    flags: u8,
    timeout_ms: u32,
    code: Text,
};

/// `flags` bit of `SemEval`: await a thenable result.
pub const eval_flag_await: u8 = 1;

/// `ok = 0` means the page threw (or the await timed out): `json` is
/// then `{"error":...,"stack":...}`. Otherwise `json` is the serialized
/// value, always valid JSON — never raw JS.
pub const SemEvalResult = struct {
    pub const tag: Tag = .sem_eval_result;
    view: u32,
    ok: u8,
    json: Text,
};

// -- request interception (0x80 block, capability "intercept") --------

/// Resource classes as the wire names them; mirrors `filter.RType`
/// (engine-agnostic — a Servo helper maps its own enum onto these).
pub const NetResource = enum(u8) {
    other = 0,
    document = 1,
    subdocument = 2,
    stylesheet = 3,
    script = 4,
    image = 5,
    font = 6,
    xhr = 7,
    media = 8,
    websocket = 9,
    ping = 10,
    _,
};

/// Enable/disable blocking. `view` 0 is the process-wide default; a
/// nonzero view carries the per-view (per-site, as the client sees it)
/// override. Effective = global AND per-view. The filter lists stay
/// loaded either way — disabling only stops the verdicts.
pub const InterceptSet = struct {
    pub const tag: Tag = .intercept_set;
    view: u32,
    enabled: u8,
};

/// Reload the filter set: the built-in seed list plus the helper's
/// `$XDG_CONFIG_HOME/sketerm/filters/*.txt` plus every path named
/// here (absolute paths, read helper-side). An empty list just
/// re-reads seed + config dir. No network fetching, by design.
pub const InterceptLists = struct {
    pub const tag: Tag = .intercept_lists;
    paths: []const []const u8,

    pub fn encodeTo(self: InterceptLists, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU16(gpa, out, @intCast(self.paths.len));
        for (self.paths) |p| try putStr(gpa, out, p);
    }

    /// Caller owns the returned `paths` slice (strings borrow from
    /// `payload`).
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !InterceptLists {
        var cur = Cur{ .buf = payload };
        const n = try cur.readU16();
        const paths = try gpa.alloc([]const u8, n);
        errdefer gpa.free(paths);
        for (paths) |*p| p.* = try cur.readStr();
        return .{ .paths = paths };
    }
};

pub const InterceptStatusReq = struct {
    pub const tag: Tag = .intercept_status_req;
    view: u32,
};

/// Per-view counters. Answered on `intercept_status_req` AND pushed
/// unsolicited when they change — coalesced helper-side (dirty flag,
/// one frame per poll iteration at most) so a busy page never streams
/// a frame per request. `rules` is the loaded-rule count (global).
pub const InterceptStatus = struct {
    pub const tag: Tag = .intercept_status;
    view: u32,
    enabled: u8,
    rules: u32,
    blocked: u32,
    total: u32,
};

/// Pull entries with seq > `since` from the view's bounded ring (the
/// MCP backlog rule: the log is polled, never streamed).
pub const InterceptLogReq = struct {
    pub const tag: Tag = .intercept_log_req;
    view: u32,
    since: u32,
    max: u16,
};

/// One observed request. `done` = the load finished and
/// `status`/`size`/`dur_ms` are real; a blocked entry is complete at
/// birth (it never touches the network). `size` is the received body
/// length, clamped.
pub const NetEntry = struct {
    seq: u32,
    blocked: u8,
    rtype: u8,
    done: u8,
    status: u16,
    dur_ms: u32,
    size: u32,
    method: []const u8,
    url: []const u8,
};

pub const InterceptLog = struct {
    pub const tag: Tag = .intercept_log;
    view: u32,
    /// One past the newest seq in the ring; the client's next `since`.
    next_seq: u32,
    entries: []const NetEntry,

    pub fn encodeTo(self: InterceptLog, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putU32(gpa, out, self.next_seq);
        try putU16(gpa, out, @intCast(self.entries.len));
        for (self.entries) |e| {
            try putU32(gpa, out, e.seq);
            try putU8(gpa, out, e.blocked);
            try putU8(gpa, out, e.rtype);
            try putU8(gpa, out, e.done);
            try putU16(gpa, out, e.status);
            try putU32(gpa, out, e.dur_ms);
            try putU32(gpa, out, e.size);
            try putStr(gpa, out, e.method);
            try putStr(gpa, out, e.url);
        }
    }

    /// Caller owns the returned `entries` slice (strings borrow from
    /// `payload`).
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !InterceptLog {
        var cur = Cur{ .buf = payload };
        const view = try cur.readU32();
        const next_seq = try cur.readU32();
        const n = try cur.readU16();
        const entries = try gpa.alloc(NetEntry, n);
        errdefer gpa.free(entries);
        for (entries) |*e| {
            e.seq = try cur.readU32();
            e.blocked = try cur.readU8();
            e.rtype = try cur.readU8();
            e.done = try cur.readU8();
            e.status = try cur.readU16();
            e.dur_ms = try cur.readU32();
            e.size = try cur.readU32();
            e.method = try cur.readStr();
            e.url = try cur.readStr();
        }
        return .{ .view = view, .next_seq = next_seq, .entries = entries };
    }
};

/// Render log entries as one newline-free JSON object — the shared
/// presentation both clients (the GUI face's `web-network` command and
/// the headless webdrive) hand to the `web_network` MCP tool. Kept
/// here because both already depend on this module and a third copy of
/// the format is how the two would drift. Caller frees.
pub fn netLogJson(gpa: std.mem.Allocator, next_seq: u32, entries: []const NetEntry) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\"next_seq\":{d},\"entries\":[", .{next_seq});
    for (entries, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        const rt: NetResource = @enumFromInt(e.rtype);
        const rt_name = switch (rt) {
            .other, .document, .subdocument, .stylesheet, .script, .image, .font, .xhr, .media, .websocket, .ping => @tagName(rt),
            _ => "other",
        };
        try w.print("{{\"seq\":{d},\"blocked\":{s},\"type\":\"{s}\",\"method\":", .{
            e.seq,
            if (e.blocked != 0) "true" else "false",
            rt_name,
        });
        try std.json.Stringify.value(e.method, .{}, w);
        try w.writeAll(",\"url\":");
        try std.json.Stringify.value(e.url, .{}, w);
        if (e.blocked == 0) {
            if (e.done != 0) {
                try w.print(",\"status\":{d},\"duration_ms\":{d},\"size\":{d}", .{ e.status, e.dur_ms, e.size });
            } else {
                try w.writeAll(",\"pending\":true");
            }
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

// -- devtools (0xA2 block, capability "devtools") ---------------------

/// Open the engine's inspector for `view`. The helper answers with
/// exactly one `ev_devtools_view`, whether or not it could open one.
///
/// The inspector is a NORMAL view: the helper creates it windowless,
/// gives it a view id of its own and paints, resizes, inputs and
/// destroys it through the frames every other view uses. There is
/// deliberately no debugging PORT anywhere in this design — nothing
/// listens on TCP, and the inspector is only reachable through this
/// socket.
///
/// `x`/`y` are LOGICAL coordinates in the SOURCE view to inspect
/// ("inspect element at"); both 0 means "just open it".
pub const DevToolsShow = struct {
    pub const tag: Tag = .devtools_show;
    view: u32,
    x: i32,
    y: i32,
};

/// The inspector view for `view`, or `devtools = 0` when there is no
/// view to present.
///
/// The id is allocated by the HELPER, not by the client, so it comes
/// from a range client-allocated ids never reach (see
/// `DEVTOOLS_VIEW_BASE`). A client must treat it as an ordinary view
/// id from then on: resize it, show/hide it, and `view_destroy` it
/// when the surface presenting it goes away.
///
/// `reason` explains a zero, because the outcomes are not equivalent
/// and a client says different things about them. It is a short
/// machine-readable token, empty on success:
///   - `windowed` — the inspector IS open, in a window of the ENGINE's
///     own making, because the engine refused to render it off-screen.
///     Nothing was lost; there is simply no view to put in a pane.
///     (CEF 151 always answers this — see `Host.adoptBrowser`.)
///   - `no such view` / `no browser` / `unsupported` — nothing opened.
pub const EvDevToolsView = struct {
    pub const tag: Tag = .ev_devtools_view;
    view: u32,
    devtools: u32,
    reason: []const u8,
};

/// First view id a helper may mint for an inspector. Client ids are
/// allocated from 1 upwards, so the two ranges cannot collide without
/// a client opening two billion views first.
pub const DEVTOOLS_VIEW_BASE: u32 = 0x4000_0000;

// -- print to PDF (0xA4 block, capability "print-pdf") ----------------

/// Render `view` to a PDF at `path`. The path is interpreted by the
/// HELPER, which is on the same machine as the client in v1; the
/// helper never creates directories and never overwrites anything the
/// engine's own writer would not.
pub const PrintPdf = struct {
    pub const tag: Tag = .print_pdf;
    view: u32,
    /// `print_flag_*` bits.
    flags: u8,
    /// `Paper` value; anything unknown means the engine default.
    paper: u8,
    path: []const u8,
};

/// `PrintPdf.flags` bits.
pub const print_flag_landscape: u8 = 1;
pub const print_flag_background: u8 = 2;

/// `PrintPdf.paper` presets, in the engine-agnostic terms every
/// engine has: a named sheet, not a driver's page-setup blob.
pub const Paper = enum(u8) { default = 0, a4 = 1, letter = 2, legal = 3, _ };

/// A sheet in INCHES — the unit both CDP's `Page.printToPDF` and
/// CEF's settings struct speak.
pub const PaperSize = struct { w: f64, h: f64 };

/// Paper size for a preset, or null for "let the engine decide".
pub fn paperInches(paper: u8) ?PaperSize {
    return switch (@as(Paper, @enumFromInt(paper))) {
        .a4 => .{ .w = 8.27, .h = 11.69 },
        .letter => .{ .w = 8.5, .h = 11.0 },
        .legal => .{ .w = 8.5, .h = 14.0 },
        else => null,
    };
}

/// The print finished (or failed). `path` echoes the request, so a
/// client with several prints in flight can tell them apart without
/// keeping a correlation id.
pub const EvPrintPdfDone = struct {
    pub const tag: Tag = .ev_print_pdf_done;
    view: u32,
    ok: u8,
    path: []const u8,
};

// -- containers / identity contexts (0x90 block, capability "contexts") --

/// Create a per-tab identity context: its own cookie jar and cache,
/// optionally routed through `proxy`. A view created with a matching
/// `context` id then lives entirely inside it — cookies, storage and
/// egress are isolated from every other context.
///
/// `id` is CLIENT-allocated (like a view id) and must be nonzero;
/// context 0 is the shared default and is never created or destroyed.
/// Re-creating a live id is a no-op.
///
/// `ephemeral = 1` gives the context a throwaway cache directory wiped
/// when the context is destroyed (or the helper exits) — the "incognito"
/// shape. `ephemeral = 0` persists under the profile dir keyed by `name`,
/// so a named container's cookies survive a helper restart.
///
/// `proxy` is empty for a direct connection, or a fixed-server proxy url
/// the engine understands ("socks5://127.0.0.1:19180", "http://host:port").
/// A socks5 url makes the engine resolve DNS at the proxy end, which is
/// what "browse via server X" needs.
pub const ContextCreate = struct {
    pub const tag: Tag = .context_create;
    id: u32,
    ephemeral: u8,
    name: []const u8,
    proxy: []const u8,
};

/// Destroy a context and everything it held. Views still bound to it
/// keep their live browsers (CEF holds its own reference) but no new
/// view may name the id afterwards; an ephemeral context's cache dir is
/// wiped here. Destroying an unknown id is a no-op.
pub const ContextDestroy = struct {
    pub const tag: Tag = .context_destroy;
    id: u32,
};

// ---------------------------------------------------------------------
// Primitive writers
// ---------------------------------------------------------------------

fn putU8(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u8) !void {
    try out.append(gpa, v);
}

fn putU16(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
}

fn putU32(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
}

fn putU64(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u64) !void {
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u64, v)));
}

fn putI32(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: i32) !void {
    try putU32(gpa, out, @bitCast(v));
}

fn putStr(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    if (s.len > std.math.maxInt(u16)) return error.StringTooLong;
    try putU16(gpa, out, @intCast(s.len));
    try out.appendSlice(gpa, s);
}

fn putText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), t: Text) !void {
    if (t.s.len > MAX_FRAME) return error.FrameTooLarge;
    try putU32(gpa, out, @intCast(t.s.len));
    try out.appendSlice(gpa, t.s);
}

// ---------------------------------------------------------------------
// Primitive reader
// ---------------------------------------------------------------------

/// Payload cursor. Every accessor fails with `error.Truncated` rather
/// than reading past the frame, so a malformed peer cannot walk memory.
pub const Cur = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn readU8(self: *Cur) !u8 {
        if (self.pos + 1 > self.buf.len) return error.Truncated;
        defer self.pos += 1;
        return self.buf[self.pos];
    }

    pub fn readU16(self: *Cur) !u16 {
        if (self.pos + 2 > self.buf.len) return error.Truncated;
        defer self.pos += 2;
        return std.mem.readInt(u16, self.buf[self.pos..][0..2], .little);
    }

    pub fn readU32(self: *Cur) !u32 {
        if (self.pos + 4 > self.buf.len) return error.Truncated;
        defer self.pos += 4;
        return std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
    }

    pub fn readU64(self: *Cur) !u64 {
        if (self.pos + 8 > self.buf.len) return error.Truncated;
        defer self.pos += 8;
        return std.mem.readInt(u64, self.buf[self.pos..][0..8], .little);
    }

    pub fn readI32(self: *Cur) !i32 {
        return @bitCast(try self.readU32());
    }

    pub fn readStr(self: *Cur) ![]const u8 {
        const n = try self.readU16();
        if (self.pos + n > self.buf.len) return error.Truncated;
        defer self.pos += n;
        return self.buf[self.pos..][0..n];
    }

    pub fn readText(self: *Cur) !Text {
        const n = try self.readU32();
        if (self.pos + n > self.buf.len) return error.Truncated;
        defer self.pos += n;
        return .{ .s = self.buf[self.pos..][0..n] };
    }
};

// ---------------------------------------------------------------------
// Generic frame (de)serialization
// ---------------------------------------------------------------------

/// Append one complete frame ([len:u32][tag:u8][payload]) for `value`.
pub fn encode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    const T = @TypeOf(value);
    const start = out.items.len;
    try out.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0 });
    try putU8(gpa, out, @intFromEnum(T.tag));
    if (@hasDecl(T, "encodeTo")) {
        try value.encodeTo(gpa, out);
    } else {
        inline for (std.meta.fields(T)) |f| {
            const v = @field(value, f.name);
            switch (f.type) {
                u8 => try putU8(gpa, out, v),
                u16 => try putU16(gpa, out, v),
                u32 => try putU32(gpa, out, v),
                u64 => try putU64(gpa, out, v),
                i32 => try putI32(gpa, out, v),
                []const u8 => try putStr(gpa, out, v),
                Text => try putText(gpa, out, v),
                else => @compileError("unsupported wire field type " ++ @typeName(f.type)),
            }
        }
    }
    const len = out.items.len - start - 4;
    if (len > MAX_FRAME) return error.FrameTooLarge;
    std.mem.writeInt(u32, out.items[start..][0..4], @intCast(len), .little);
}

/// Decode a payload into `T`. String fields BORROW from `payload`.
/// Types with list fields provide `decodeAlloc` instead; a type with a
/// `decodeFrom` (a bounded array, or an optional trailing field) owns
/// its own reader and is routed to it, so callers never have to know
/// which shape a frame has.
pub fn decode(comptime T: type, payload: []const u8) !T {
    if (@hasDecl(T, "decodeAlloc")) @compileError(@typeName(T) ++ " needs decodeAlloc");
    if (@hasDecl(T, "decodeFrom")) return T.decodeFrom(payload);
    var cur = Cur{ .buf = payload };
    var out: T = undefined;
    inline for (std.meta.fields(T)) |f| {
        @field(out, f.name) = switch (f.type) {
            u8 => try cur.readU8(),
            u16 => try cur.readU16(),
            u32 => try cur.readU32(),
            u64 => try cur.readU64(),
            i32 => try cur.readI32(),
            []const u8 => try cur.readStr(),
            Text => try cur.readText(),
            else => @compileError("unsupported wire field type " ++ @typeName(f.type)),
        };
    }
    return out;
}

// ---------------------------------------------------------------------
// Stream framing
// ---------------------------------------------------------------------

pub const Frame = struct { tag: Tag, payload: []const u8 };

/// Length-prefix framer over an accumulated byte stream.
///
/// `next` returns null when the buffer holds no COMPLETE frame yet, and
/// silently drops frames whose tag this build does not know (the
/// append-only rule: a newer peer's extra frames must cost nothing).
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn next(self: *Reader) !?Frame {
        while (true) {
            if (self.pos + 4 > self.buf.len) return null;
            const len = std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
            if (len == 0 or len > MAX_FRAME) return error.BadFrame;
            if (self.pos + 4 + len > self.buf.len) return null;
            const tag: Tag = @enumFromInt(self.buf[self.pos + 4]);
            const payload = self.buf[self.pos + 5 ..][0 .. len - 1];
            self.pos += 4 + len;
            if (!tag.known()) continue;
            return .{ .tag = tag, .payload = payload };
        }
    }

    /// Bytes consumed so far — what the caller may drop from its
    /// accumulation buffer.
    pub fn consumed(self: Reader) usize {
        return self.pos;
    }
};

// ---------------------------------------------------------------------
// Outbox
// ---------------------------------------------------------------------

/// One queued message: encoded frame bytes plus the descriptors to
/// attach with it (SCM_RIGHTS — one memfd for `frames-shm`, one per
/// plane for `frames-dmabuf`). Pure data: the fds are integers here and
/// sending them is the server's job.
pub const Message = struct {
    bytes: []u8,
    fds: [MAX_PLANES]i32 = @splat(-1),
    nfds: u8 = 0,

    pub fn one(bytes: []u8, fd: ?i32) Message {
        var m = Message{ .bytes = bytes };
        if (fd) |f| {
            m.fds[0] = f;
            m.nfds = 1;
        }
        return m;
    }

    /// The descriptors still attached, as a slice.
    pub fn fdSlice(self: *const Message) []const i32 {
        return self.fds[0..self.nfds];
    }
};

/// FIFO of messages awaiting transmission, with a partial-write cursor.
///
/// It owns the bytes and, until sent, the fd: `deinit` closes nothing,
/// so a caller that abandons an outbox with pending fds must drain them.
pub const Outbox = struct {
    gpa: std.mem.Allocator,
    queue: std.ArrayList(Message) = .empty,
    head: usize = 0,
    sent: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Outbox {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Outbox) void {
        for (self.queue.items[self.head..]) |m| self.gpa.free(m.bytes);
        self.queue.deinit(self.gpa);
    }

    /// Queue `value` as a frame, optionally carrying `fd`.
    pub fn post(self: *Outbox, value: anytype, fd: ?i32) !void {
        return self.postFds(value, if (fd) |f| &[_]i32{f} else &.{});
    }

    /// Queue `value` carrying every descriptor in `fds` (SCM_RIGHTS
    /// takes them as one array, so they ride the same message).
    pub fn postFds(self: *Outbox, value: anytype, fds: []const i32) !void {
        if (fds.len > MAX_PLANES) return error.TooManyFds;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.gpa);
        try encode(self.gpa, &buf, value);
        var m = Message{ .bytes = try buf.toOwnedSlice(self.gpa), .nfds = @intCast(fds.len) };
        for (fds, 0..) |f, i| m.fds[i] = f;
        try self.queue.append(self.gpa, m);
    }

    pub fn empty(self: *const Outbox) bool {
        return self.head >= self.queue.items.len;
    }

    /// Messages still awaiting transmission — the backpressure signal
    /// for a producer whose frames pin descriptors.
    pub fn pending(self: *const Outbox) usize {
        return self.queue.items.len - self.head;
    }

    /// The unsent remainder of the front message, or null when drained.
    /// Descriptors ride the FIRST write only; a partial write must not
    /// send them twice.
    pub fn front(self: *const Outbox) ?Message {
        if (self.empty()) return null;
        const m = self.queue.items[self.head];
        var out = Message{ .bytes = m.bytes[self.sent..] };
        if (self.sent == 0) {
            out.fds = m.fds;
            out.nfds = m.nfds;
        }
        return out;
    }

    /// Record `n` bytes of the front message as written.
    pub fn advance(self: *Outbox, n: usize) void {
        if (self.empty()) return;
        const m = self.queue.items[self.head];
        self.sent += n;
        if (self.sent < m.bytes.len) return;
        self.gpa.free(m.bytes);
        self.sent = 0;
        self.head += 1;
        if (self.empty()) {
            self.queue.clearRetainingCapacity();
            self.head = 0;
        }
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

fn roundTrip(comptime T: type, value: T) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(gpa, &buf, value);

    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(T.tag, frame.tag);
    try std.testing.expectEqual(buf.items.len, r.consumed());
    const got = try decode(T, frame.payload);
    inline for (std.meta.fields(T)) |f| {
        if (f.type == []const u8) {
            try std.testing.expectEqualStrings(@field(value, f.name), @field(got, f.name));
        } else if (f.type == Text) {
            try std.testing.expectEqualStrings(@field(value, f.name).s, @field(got, f.name).s);
        } else {
            try std.testing.expectEqual(@field(value, f.name), @field(got, f.name));
        }
    }
}

test "round-trip: scalar and string frames" {
    try roundTrip(Hello, .{ .proto = 1, .client_name = "sketerm-gui" });
    try roundTrip(ViewCreate, .{ .view = 7, .w = 800, .h = 600, .scale_x1000 = 1000, .context = 0 });
    try roundTrip(ViewCreateUrl, .{
        .view = 7,
        .w = 800,
        .h = 600,
        .scale_x1000 = 1000,
        .context = 0,
        .url = "https://example.com/",
    });
    try roundTrip(ViewDestroy, .{ .view = 7 });
    try roundTrip(ViewDiscard, .{ .view = 7 });
    try roundTrip(ViewResize, .{ .view = 7, .w = 1024, .h = 768, .scale_x1000 = 1500 });
    try roundTrip(ViewShow, .{ .view = 7 });
    try roundTrip(ViewHide, .{ .view = 7 });
    try roundTrip(Navigate, .{ .view = 7, .url = "https://example.com/" });
    try roundTrip(NavAction, .{ .view = 7, .action = 2 });
    try roundTrip(InputPointer, .{
        .view = 7,
        .kind = 1,
        .x = -3,
        .y = 400,
        .button = 0,
        .clicks = 2,
        .mods = mod_ctrl | mod_shift,
    });
    try roundTrip(InputScroll, .{ .view = 7, .x = 10, .y = 20, .dx = 0, .dy = -120, .mods = 0 });
    try roundTrip(InputKey, .{
        .view = 7,
        .kind = 0,
        .keyval = 0xff0d,
        .keycode = 36,
        .mods = 0,
        .text = "",
    });
    try roundTrip(InputIme, .{ .view = 7, .kind = 1, .text = "ê", .cursor = 1 });
    try roundTrip(InputFocus, .{ .view = 7, .focused = 1 });
    try roundTrip(FrameBuffer, .{ .view = 7, .buf_id = 3, .w = 800, .h = 600, .stride = 3200 });
    try roundTrip(FrameRelease, .{ .view = 7, .buf_id = 2 });
    try roundTrip(FrameRequest, .{ .view = 7, .flags = 0 });
    try roundTrip(ViewMaxFps, .{ .view = 7, .fps = 144 });
    try roundTrip(EvLoad, .{ .view = 7, .state = 2, .url = "about:blank" });
    try roundTrip(EvLoadError, .{ .view = 7, .code = -105, .url = "http://x/", .msg = "NAME_NOT_RESOLVED" });
    try roundTrip(EvTitle, .{ .view = 7, .title = "hello" });
    try roundTrip(EvFavicon, .{ .view = 7, .url = "http://x/favicon.ico" });
    try roundTrip(EvNavState, .{ .view = 7, .can_back = 1, .can_fwd = 0, .loading = 0, .url = "http://x/" });
    try roundTrip(EvPopupRequest, .{ .view = 7, .url = "http://x/p", .disposition = 0, .user_gesture = 1 });
    try roundTrip(EvPopupRequest, .{ .view = 7, .url = "http://x/p", .disposition = 2, .user_gesture = 0 });
    try roundTrip(EvCursor, .{ .view = 7, .cursor = 1 });
    try roundTrip(EvConsole, .{ .view = 7, .level = 2, .msg = "boom" });
    try roundTrip(EvCrashed, .{ .view = 7 });
    try roundTrip(Find, .{ .view = 7, .forward = 1, .match_case = 0, .find_next = 0, .text = "needle" });
    try roundTrip(FindStop, .{ .view = 7, .clear_selection = 1 });
    try roundTrip(SetZoom, .{ .view = 7, .level_x100 = -300 });
    try roundTrip(EvFindResult, .{ .view = 7, .count = 12, .active = 3, .final = 1 });
    try roundTrip(EvContextMenu, .{
        .view = 7,
        .x = 40,
        .y = 220,
        .flags = ctx_flag_link,
        .link_url = "https://example.com/a",
    });
}

test "round-trip: tls and permission frames" {
    try roundTrip(EvCertError, .{
        .view = 7,
        .code = -202,
        .url = "https://self-signed.example/",
        .host = "self-signed.example",
        .msg = "CERT_AUTHORITY_INVALID",
        .subject = "self-signed.example",
        .issuer = "self-signed.example",
        .fingerprint = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    });
    try roundTrip(CertDecision, .{ .view = 7, .proceed = 1 });
    try roundTrip(EvPermission, .{
        .view = 7,
        .prompt = 0xdead_beef_0000_0001,
        .origin = "https://example.com",
        .types = perm_camera | perm_microphone,
    });
    try roundTrip(PermissionDecision, .{ .view = 7, .prompt = 0xdead_beef_0000_0001, .allow = 0 });
}

test "round-trip: download frames" {
    try roundTrip(EvDownloadOffer, .{
        .view = 7,
        .id = 41,
        .total = 5_000_000_000,
        .url = "https://example.com/big.iso",
        .name = "big.iso",
        .mime = "application/octet-stream",
    });
    try roundTrip(EvDownloadOffer, .{ .view = 7, .id = 42, .total = 0, .url = "data:,x", .name = "x", .mime = "" });
    try roundTrip(DownloadDecide, .{ .view = 7, .id = 41, .path = "/home/x/Downloads/big.iso" });
    try roundTrip(DownloadDecide, .{ .view = 7, .id = 41, .path = "" });
    try roundTrip(EvDownloadProgress, .{
        .view = 7,
        .id = 41,
        .received = 1_234_567_890_123,
        .total = 5_000_000_000_000,
        .done = 0,
        .failed = 0,
    });
    try roundTrip(EvDownloadProgress, .{ .view = 7, .id = 41, .received = 10, .total = 10, .done = 1, .failed = 0 });
    try roundTrip(EvDownloadProgress, .{ .view = 7, .id = 41, .received = 3, .total = 0, .done = 0, .failed = 1 });
    try roundTrip(DownloadCancel, .{ .view = 7, .id = 41 });
}

// The one growable frame on this wire: a helper that predates the
// gesture flag sends three fields, and a client built with four must
// read that as "a gesture" rather than as a truncated frame — the
// difference between an old helper behaving as it always did and one
// whose every popup is silently blocked.
test "an ev_popup_request without the trailing gesture byte still decodes" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    // Hand-built in the OLD layout: [view][url][disposition], no more.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try putU32(gpa, &body, 7);
    try putStr(gpa, &body, "http://x/p");
    try putU8(gpa, &body, 1);
    try putU32(gpa, &buf, @intCast(body.items.len + 1));
    try putU8(gpa, &buf, @intFromEnum(Tag.ev_popup_request));
    try buf.appendSlice(gpa, body.items);

    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    const got = try decode(EvPopupRequest, frame.payload);
    try std.testing.expectEqualStrings("http://x/p", got.url);
    try std.testing.expectEqual(@as(u8, 1), got.disposition);
    try std.testing.expectEqual(@as(u8, 1), got.user_gesture);
}

test "round-trip: container/context frames" {
    try roundTrip(ContextCreate, .{
        .id = 3,
        .ephemeral = 1,
        .name = "Work",
        .proxy = "socks5://127.0.0.1:19180",
    });
    try roundTrip(ContextCreate, .{ .id = 4, .ephemeral = 0, .name = "", .proxy = "" });
    try roundTrip(ContextDestroy, .{ .id = 3 });
}

test "round-trip: semantic layer frames" {
    try roundTrip(SemSnapshotReq, .{ .view = 7, .mode = 1, .detail = 2, .scope = 0 });
    try roundTrip(SemSnapshot, .{
        .view = 7,
        .doc_gen = 3,
        .rev = 12,
        .kind = @intFromEnum(SnapKind.delta),
        .payload = .{ .s = "delta rev 11->12\n~ [4] button \"Go\"\n" },
    });
    try roundTrip(SemAction, .{
        .view = 7,
        .id = 4,
        .action = @intFromEnum(SemAct.set_value),
        .arg = "hello",
    });
    try roundTrip(SemActResult, .{ .view = 7, .id = 4, .ok = 1, .msg = "click at 40,20" });
    try roundTrip(SemExpand, .{ .view = 7, .id = 4, .off = 160, .len = 4096 });
    try roundTrip(SemExpandResult, .{ .view = 7, .id = 4, .off = 160, .text = "the rest of it" });
    try roundTrip(SemQueryReq, .{ .view = 7, .kind = @intFromEnum(SemQuery.subtree), .arg = "4" });
    try roundTrip(SemQueryResult, .{ .view = 7, .payload = .{ .s = "query subtree [4]\n" } });
    try roundTrip(SemRead, .{ .view = 7 });
    try roundTrip(SemReadResult, .{ .view = 7, .markdown = .{ .s = "# Heading\n\ntext\n" } });
    try roundTrip(SemEval, .{
        .view = 7,
        .flags = eval_flag_await,
        .timeout_ms = 5000,
        .code = .{ .s = "document.title" },
    });
    try roundTrip(SemEvalResult, .{ .view = 7, .ok = 1, .json = .{ .s = "{\"value\":\"x\"}" } });
}

test "round-trip: a11y frames" {
    try roundTrip(A11yEnable, .{ .view = 7, .enabled = 1 });
    try roundTrip(EvA11yTree, .{
        .view = 7,
        .root_id = 1,
        .node_id_to_clear = 0,
        .focus_id = 4,
        .nodes = .{ .s = "" },
    });
    try roundTrip(EvA11yLoc, .{ .view = 7, .locs = .{ .s = "" } });
    try roundTrip(EvA11yEvent, .{ .view = 7, .id = 4, .event = "focus" });
}

test "a11y node list round-trips through writer and iterator" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var w = A11yNodeWriter{ .gpa = gpa, .buf = &buf };
    try w.put(.{
        .id = 1,
        .state = ax_busy,
        .x = 0,
        .y = 0,
        .w = 800,
        .h = 600,
        .role = "document",
        .name = "Example page",
        .children = &[_]u32{ 2, 3 },
    });
    try w.put(.{
        .id = 2,
        .state = 0,
        .x = 8,
        .y = 8,
        .w = 200,
        .h = 32,
        .offset_container = 1,
        .role = "heading",
        .name = "Hello",
        .attributes = &[_]A11yAttr{.{ .key = "level", .value = "1" }},
    });
    try w.put(.{
        .id = 3,
        .state = ax_focusable | ax_focused,
        .x = 8,
        .y = 48,
        .w = 80,
        .h = 24,
        .offset_container = 1,
        .role = "button",
        .name = "Go",
        .value = "",
        .description = "submits the form",
    });
    try std.testing.expectEqual(@as(u32, 3), w.count);

    var it = A11yNodeIter.init(buf.items);
    const n1 = (try it.next()).?;
    try std.testing.expectEqual(@as(u32, 1), n1.id);
    try std.testing.expectEqualStrings("document", n1.role);
    try std.testing.expectEqual(@as(u16, 2), n1.nchildren);
    try std.testing.expectEqual(@as(u32, 2), n1.childAt(0));
    try std.testing.expectEqual(@as(u32, 3), n1.childAt(1));
    const n2 = (try it.next()).?;
    try std.testing.expectEqualStrings("heading", n2.role);
    try std.testing.expectEqualStrings("Hello", n2.name);
    var attrs = n2.attrs();
    const a = (try attrs.next()).?;
    try std.testing.expectEqualStrings("level", a.key);
    try std.testing.expectEqualStrings("1", a.value);
    try std.testing.expectEqual(@as(?A11yAttr, null), try attrs.next());
    const n3 = (try it.next()).?;
    try std.testing.expectEqual(ax_focusable | ax_focused, n3.state);
    try std.testing.expectEqualStrings("submits the form", n3.description);
    try std.testing.expectEqual(@as(u32, 1), n3.offset_container);
    try std.testing.expectEqual(@as(?A11yNode, null), try it.next());

    // A truncated payload is an error, never a read past the buffer.
    var short = A11yNodeIter.init(buf.items[0 .. buf.items.len - 3]);
    _ = try short.next();
    _ = try short.next();
    try std.testing.expectError(error.Truncated, short.next());
}

test "a11y location list round-trips" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try putA11yLoc(gpa, &buf, .{ .id = 4, .offset_container = 1, .x = -2, .y = 300, .w = 80, .h = 24 });
    try putA11yLoc(gpa, &buf, .{ .id = 5, .offset_container = 0, .x = 0, .y = 0, .w = 800, .h = 600 });
    var it = A11yLocIter.init(buf.items);
    const l1 = (try it.next()).?;
    try std.testing.expectEqual(@as(i32, -2), l1.x);
    try std.testing.expectEqual(@as(u32, 1), l1.offset_container);
    const l2 = (try it.next()).?;
    try std.testing.expectEqual(@as(u32, 5), l2.id);
    try std.testing.expectEqual(@as(?A11yLoc, null), try it.next());
}

test "round-trip: interception frames" {
    try roundTrip(InterceptSet, .{ .view = 0, .enabled = 0 });
    try roundTrip(InterceptSet, .{ .view = 7, .enabled = 1 });
    try roundTrip(InterceptStatusReq, .{ .view = 7 });
    try roundTrip(InterceptStatus, .{ .view = 7, .enabled = 1, .rules = 1234, .blocked = 5, .total = 61 });
    try roundTrip(InterceptLogReq, .{ .view = 7, .since = 41, .max = 50 });
}

test "round-trip: intercept_lists path list" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const paths = [_][]const u8{ "/tmp/a.txt", "/home/x/.config/sketerm/filters/easylist.txt" };
    try encode(gpa, &buf, InterceptLists{ .paths = &paths });
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.intercept_lists, frame.tag);
    const got = try InterceptLists.decodeAlloc(frame.payload, gpa);
    defer gpa.free(got.paths);
    try std.testing.expectEqual(@as(usize, 2), got.paths.len);
    try std.testing.expectEqualStrings(paths[1], got.paths[1]);
}

test "round-trip: intercept_log entry list" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const entries = [_]NetEntry{
        .{ .seq = 40, .blocked = 1, .rtype = @intFromEnum(NetResource.image), .done = 1, .status = 0, .dur_ms = 0, .size = 0, .method = "GET", .url = "https://ads.example/px.gif" },
        .{ .seq = 41, .blocked = 0, .rtype = @intFromEnum(NetResource.script), .done = 1, .status = 200, .dur_ms = 12, .size = 4096, .method = "GET", .url = "https://site.example/app.js" },
    };
    try encode(gpa, &buf, InterceptLog{ .view = 7, .next_seq = 42, .entries = &entries });
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.intercept_log, frame.tag);
    const got = try InterceptLog.decodeAlloc(frame.payload, gpa);
    defer gpa.free(got.entries);
    try std.testing.expectEqual(@as(u32, 42), got.next_seq);
    try std.testing.expectEqual(@as(usize, 2), got.entries.len);
    try std.testing.expectEqual(@as(u8, 1), got.entries[0].blocked);
    try std.testing.expectEqualStrings("https://site.example/app.js", got.entries[1].url);
    try std.testing.expectEqual(@as(u16, 200), got.entries[1].status);
}

test "netLogJson is one newline-free JSON object" {
    const gpa = std.testing.allocator;
    const entries = [_]NetEntry{
        .{ .seq = 1, .blocked = 1, .rtype = @intFromEnum(NetResource.image), .done = 1, .status = 0, .dur_ms = 0, .size = 0, .method = "GET", .url = "https://ads.example/px.gif" },
        .{ .seq = 2, .blocked = 0, .rtype = @intFromEnum(NetResource.script), .done = 0, .status = 0, .dur_ms = 0, .size = 0, .method = "GET", .url = "https://site.example/a\njs" },
        .{ .seq = 3, .blocked = 0, .rtype = 99, .done = 1, .status = 404, .dur_ms = 7, .size = 11, .method = "POST", .url = "https://site.example/api" },
    };
    const json = try netLogJson(gpa, 4, &entries);
    defer gpa.free(json);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, json, '\n'));
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 4), obj.get("next_seq").?.integer);
    const arr = obj.get("entries").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expect(arr[0].object.get("blocked").?.bool);
    try std.testing.expect(arr[1].object.get("pending").?.bool);
    // An unknown wire type byte renders as "other", not a crash.
    try std.testing.expectEqualStrings("other", arr[2].object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 404), arr[2].object.get("status").?.integer);
}

test "round-trip: devtools and print-to-pdf frames" {
    try roundTrip(DevToolsShow, .{ .view = 7, .x = 0, .y = 0 });
    try roundTrip(DevToolsShow, .{ .view = 7, .x = 120, .y = -4 });
    try roundTrip(EvDevToolsView, .{ .view = 7, .devtools = DEVTOOLS_VIEW_BASE + 1, .reason = "" });
    try roundTrip(EvDevToolsView, .{ .view = 7, .devtools = 0, .reason = "windowed" });
    try roundTrip(PrintPdf, .{
        .view = 7,
        .flags = print_flag_landscape | print_flag_background,
        .paper = @intFromEnum(Paper.a4),
        .path = "/tmp/page.pdf",
    });
    try roundTrip(EvPrintPdfDone, .{ .view = 7, .ok = 1, .path = "/tmp/page.pdf" });
    try roundTrip(EvPrintPdfDone, .{ .view = 7, .ok = 0, .path = "" });
}

test "a helper-minted devtools id cannot collide with a client-minted one" {
    // Clients allocate from 1 upwards; the helper's range starts far
    // above anything a session reaches.
    try std.testing.expect(DEVTOOLS_VIEW_BASE > 1_000_000);
    try std.testing.expectEqual(@as(?PaperSize, null), paperInches(@intFromEnum(Paper.default)));
    try std.testing.expectEqual(@as(f64, 8.27), paperInches(@intFromEnum(Paper.a4)).?.w);
    // An unknown preset from a newer client is the engine default, not
    // a decode failure.
    try std.testing.expectEqual(@as(?PaperSize, null), paperInches(200));
}

test "a text payload carries more than a str's u16 length" {
    const gpa = std.testing.allocator;
    const big = try gpa.alloc(u8, 200_000);
    defer gpa.free(big);
    @memset(big, 'x');
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(gpa, &buf, SemSnapshot{
        .view = 1,
        .doc_gen = 1,
        .rev = 1,
        .kind = 0,
        .payload = .{ .s = big },
    });
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    const got = try decode(SemSnapshot, frame.payload);
    try std.testing.expectEqual(big.len, got.payload.s.len);
}

test "round-trip: hello_ack capability list" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const caps = [_][]const u8{ CAP_FRAMES_SHM, CAP_INPUT, CAP_NAVIGATION };
    try encode(gpa, &buf, HelloAck{
        .proto = PROTO_VERSION,
        .engine_name = "cef",
        .engine_version = "151",
        .caps = &caps,
    });

    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.hello_ack, frame.tag);
    const got = try HelloAck.decodeAlloc(frame.payload, gpa);
    defer gpa.free(got.caps);
    try std.testing.expectEqual(PROTO_VERSION, got.proto);
    try std.testing.expectEqualStrings("cef", got.engine_name);
    try std.testing.expectEqualStrings("151", got.engine_version);
    try std.testing.expectEqual(@as(usize, 3), got.caps.len);
    try std.testing.expectEqualStrings(CAP_INPUT, got.caps[1]);
}

test "round-trip: frame_damage rect list" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const rects = [_]Rect{ .{ .x = 0, .y = 0, .w = 800, .h = 600 }, .{ .x = 4, .y = 8, .w = 16, .h = 32 } };
    try encode(gpa, &buf, FrameDamage{ .view = 1, .buf_id = 5, .gen = 42, .rects = &rects });

    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    const got = try FrameDamage.decodeAlloc(frame.payload, gpa);
    defer gpa.free(got.rects);
    try std.testing.expectEqual(@as(u32, 42), got.gen);
    try std.testing.expectEqual(@as(usize, 2), got.rects.len);
    try std.testing.expectEqual(@as(u16, 32), got.rects[1].h);
}

test "reader skips unknown tags" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(gpa, &buf, EvTitle{ .view = 1, .title = "a" });
    // A frame from a newer peer: an unassigned tag in the a11y block.
    try buf.appendSlice(gpa, &[_]u8{ 3, 0, 0, 0, 0x77, 0xAA, 0xBB });
    try encode(gpa, &buf, EvCrashed{ .view = 2 });

    var r = Reader.init(buf.items);
    const first = (try r.next()).?;
    try std.testing.expectEqual(Tag.ev_title, first.tag);
    const second = (try r.next()).?;
    try std.testing.expectEqual(Tag.ev_crashed, second.tag);
    try std.testing.expectEqual(@as(u32, 2), (try decode(EvCrashed, second.payload)).view);
    try std.testing.expectEqual(@as(?Frame, null), try r.next());
    try std.testing.expectEqual(buf.items.len, r.consumed());
}

test "reader holds back partial frames" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(gpa, &buf, Navigate{ .view = 1, .url = "https://example.com/" });

    // Every prefix short of the whole frame yields nothing and consumes
    // nothing, so the caller keeps accumulating.
    var cut: usize = 0;
    while (cut < buf.items.len) : (cut += 1) {
        var r = Reader.init(buf.items[0..cut]);
        try std.testing.expectEqual(@as(?Frame, null), try r.next());
        try std.testing.expectEqual(@as(usize, 0), r.consumed());
    }
    var full = Reader.init(buf.items);
    try std.testing.expect((try full.next()) != null);
}

test "truncated payload is an error, not a read past the frame" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(gpa, &buf, Navigate{ .view = 1, .url = "https://example.com/" });
    // Claim a 4-byte payload for a frame that needs far more.
    var short: [9]u8 = undefined;
    std.mem.writeInt(u32, short[0..4], 5, .little);
    short[4] = @intFromEnum(Tag.navigate);
    @memcpy(short[5..9], buf.items[9..13]);
    var r = Reader.init(&short);
    const frame = (try r.next()).?;
    try std.testing.expectError(error.Truncated, decode(Navigate, frame.payload));

    var bad = Reader.init(&[_]u8{ 0, 0, 0, 0, 1 });
    try std.testing.expectError(error.BadFrame, bad.next());
}

test "outbox drains in order with partial writes" {
    const gpa = std.testing.allocator;
    var ob = Outbox.init(gpa);
    defer ob.deinit();
    try ob.post(EvTitle{ .view = 1, .title = "one" }, null);
    try ob.post(EvCrashed{ .view = 2 }, 7);
    try std.testing.expect(!ob.empty());

    const first = ob.front().?;
    try std.testing.expectEqual(@as(u8, 0), first.nfds);
    ob.advance(1);
    try std.testing.expectEqual(first.bytes.len - 1, ob.front().?.bytes.len);
    ob.advance(first.bytes.len - 1);

    const second = ob.front().?;
    try std.testing.expectEqualSlices(i32, &[_]i32{7}, second.fdSlice());
    ob.advance(second.bytes.len);
    try std.testing.expect(ob.empty());
}

test "a dma-buf frame round-trips its planes" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const sent = FrameDmabuf{
        .view = 3,
        .buf_id = 9,
        .gen = 1234,
        .w = 3840,
        .h = 2160,
        .fourcc = 0x34325241, // DRM_FORMAT_ARGB8888
        .modifier = 0x0100000000000005,
        .nplanes = 2,
        .planes = .{
            .{ .stride = 15360, .offset = 0 },
            .{ .stride = 7680, .offset = 33_177_600 },
            .{ .stride = 0, .offset = 0 },
            .{ .stride = 0, .offset = 0 },
        },
    };
    try encode(gpa, &buf, sent);
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.frame_dmabuf, frame.tag);
    const got = try FrameDmabuf.decodeFrom(frame.payload);
    try std.testing.expectEqual(sent.modifier, got.modifier);
    try std.testing.expectEqual(sent.fourcc, got.fourcc);
    try std.testing.expectEqual(@as(u8, 2), got.nplanes);
    try std.testing.expectEqual(@as(u32, 15360), got.planes[0].stride);
    try std.testing.expectEqual(@as(u32, 33_177_600), got.planes[1].offset);
    try std.testing.expectEqual(@as(u16, 2160), got.h);
}

test "a dma-buf frame with an impossible plane count is refused" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(gpa, &buf, FrameDmabuf{
        .view = 1,
        .buf_id = 1,
        .gen = 1,
        .w = 8,
        .h = 8,
        .fourcc = 0,
        .modifier = 0,
        .nplanes = 1,
        .planes = @splat(.{ .stride = 32, .offset = 0 }),
    });
    // The plane count sits right after the 8 modifier bytes.
    const n_off = 4 + 1 + 4 + 4 + 4 + 2 + 2 + 4 + 8;
    buf.items[n_off] = 7;
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectError(error.BadPlaneCount, FrameDmabuf.decodeFrom(frame.payload));
}

test "one message carries a descriptor per plane, and only on the first write" {
    const gpa = std.testing.allocator;
    var ob = Outbox.init(gpa);
    defer ob.deinit();
    try ob.postFds(EvCrashed{ .view = 1 }, &[_]i32{ 11, 12, 13 });
    const m = ob.front().?;
    try std.testing.expectEqualSlices(i32, &[_]i32{ 11, 12, 13 }, m.fdSlice());
    ob.advance(2);
    try std.testing.expectEqual(@as(u8, 0), ob.front().?.nfds);
    ob.advance(m.bytes.len - 2);
    try std.testing.expect(ob.empty());
    try std.testing.expectError(error.TooManyFds, ob.postFds(EvCrashed{ .view = 1 }, &[_]i32{ 1, 2, 3, 4, 5 }));
}
