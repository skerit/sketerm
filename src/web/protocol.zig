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
    sem_eval = 0xA0,
    sem_eval_result = 0xA1,
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

/// `sem_snapshot_req` mode byte.
pub const SnapMode = enum(u8) { auto = 0, full = 1, _ };

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

/// `sem_query` kind byte.
pub const SemQuery = enum(u8) { find_text = 0, subtree = 1, focused = 2, _ };

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

pub const ViewDestroy = struct {
    pub const tag: Tag = .view_destroy;
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

pub const EvPopupRequest = struct {
    pub const tag: Tag = .ev_popup_request;
    view: u32,
    url: []const u8,
    disposition: u8,
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
/// Types with list fields provide `decodeAlloc` instead.
pub fn decode(comptime T: type, payload: []const u8) !T {
    if (@hasDecl(T, "decodeAlloc")) @compileError(@typeName(T) ++ " needs decodeAlloc");
    var cur = Cur{ .buf = payload };
    var out: T = undefined;
    inline for (std.meta.fields(T)) |f| {
        @field(out, f.name) = switch (f.type) {
            u8 => try cur.readU8(),
            u16 => try cur.readU16(),
            u32 => try cur.readU32(),
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
    try roundTrip(ViewDestroy, .{ .view = 7 });
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
    try roundTrip(EvPopupRequest, .{ .view = 7, .url = "http://x/p", .disposition = 0 });
    try roundTrip(EvCursor, .{ .view = 7, .cursor = 1 });
    try roundTrip(EvConsole, .{ .view = 7, .level = 2, .msg = "boom" });
    try roundTrip(EvCrashed, .{ .view = 7 });
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
    // A frame from a newer peer: the still-reserved a11y block.
    try buf.appendSlice(gpa, &[_]u8{ 3, 0, 0, 0, 0x70, 0xAA, 0xBB });
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
