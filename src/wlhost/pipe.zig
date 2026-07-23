//! Framing of the sketerm-native app pipe: the byte stream INSIDE
//! a chan_data channel of kind `wayland_native` (mux/wire.zig).
//!
//! Both directions carry length-prefixed units (u32 len, u8 tag,
//! payload — same shape as the mux frame itself) so receivers peel
//! units regardless of how chan_data frames split them, and unknown
//! tags skip cleanly. Tags are append-only.
//!
//! Daemon → GUI: wl_msg (verbatim client request, fd args stripped
//! from the byte stream by Wayland's own encoding) + pool_* side
//! band replacing the fds: the GUI compositor treats a pool as plain
//! memory kept in sync by the daemon. A pool update may be CHUNKED —
//! any number of units covering arbitrary [offset, offset+len)
//! ranges — because buffers can exceed the mux MAX_FRAME.
//!
//! GUI → daemon: wl_msg (verbatim compositor event). Events that
//! carry an fd on a real Wayland socket (wl_keyboard.keymap) get a
//! side-band unit the daemon materializes into a memfd.

const std = @import("std");
const pixcodec = @import("pixcodec.zig");

pub const Tag = enum(u8) {
    /// Raw Wayland message, both directions.
    wl_msg = 1,
    /// u32 pool id, u32 size. Follows the create_pool wl_msg.
    pool_create = 2,
    /// u32 pool id, u32 offset, bytes. Chunked at will.
    pool_update = 3,
    /// u32 pool id, u32 new size.
    pool_resize = 4,
    /// u32 pool id. Mirror may be dropped (all buffers dead).
    pool_destroy = 5,
    /// u32 keymap format, bytes. GUI→daemon; daemon materializes a
    /// memfd and emits the real wl_keyboard.keymap event itself.
    keymap = 6,
    /// Deflated pool_update: u32 pool id, u32 offset, u32 raw len,
    /// raw-deflate bytes (wlhost/zpool.zig). Senders use it only
    /// when it shrinks; receivers must accept both forms.
    pool_update_z = 7,
    /// u32 data_source id, mime string. GUI→daemon: fetch the
    /// app's clipboard offer — the daemon creates a pipe, sends
    /// wl_data_source.send(mime, fd) itself, and answers with a
    /// clip_data unit when the app closes its end. One outstanding
    /// fetch at a time per channel (FIFO pairing).
    clip_send = 8,
    /// Raw clipboard bytes. Daemon→GUI: the answer to clip_send.
    /// GUI→daemon: paste bytes for the oldest held receive-fd
    /// (wl_data_offer.receive's fd, FIFO-paired).
    clip_data = 9,
    /// Codec-tagged pool update: u32 pool id, u32 offset, then a
    /// pixcodec body (tag + raw_len + row_stride + bytes). Supersedes
    /// pool_update / pool_update_z — one tag covers raw, deflate, and
    /// the predictor codecs. Receivers still accept the legacy two.
    pool_update_c = 10,
    /// Video-coded pool region (the LOSSY path for hot regions): u32
    /// pool id, u32 offset, u32 row_stride, then an opaque vcodec tile
    /// blob (wlhost/vcodec.zig appendTile). The GUI decodes the tile to
    /// BGRA and writes it into the pool mirror at offset, w*4 bytes per
    /// row, stepping by row_stride — same destination as pool_update_c,
    /// just a temporal coder instead of a per-region one.
    pool_vtile = 11,
    /// Serialized Compositor protocol state (compositor.zig
    /// serializeState), daemon brain -> freshly attached replica.
    /// Pool BYTES are not inside — they precede it as pool_create +
    /// pool_update_c units replayed from the daemon's mirrors.
    state_sync = 12,
    /// Seat intents, replica -> daemon brain (proto>=6). Little-endian
    /// payloads; f64 rides as its u64 bit pattern.
    seat_enter = 13, // u32 sid, u64 x, u64 y
    seat_leave = 14,
    seat_motion = 15, // u64 x, u64 y
    seat_button = 16, // u32 button, u8 pressed
    seat_axis = 17, // u32 axis, u64 value, [i32 value120 — len>=16]
    seat_kbd_enter = 18, // u32 sid
    seat_kbd_leave = 19,
    seat_key = 20, // u32 key, u8 pressed
    seat_mods = 21, // u32 depressed, latched, locked, group
    /// u32 sid, i32 w, i32 h, u32 state bits (1 activated,
    /// 2 maximized, 4 fullscreen, 8 resizing).
    configure = 22,
    dismiss_popups = 23,
    /// mime string; the brain announces a host-clipboard selection.
    offer_selection = 24,
    request_close = 25, // u32 sid
    /// The app's window icon as image bytes, daemon -> client. u32
    /// sid, u8 kind (icons.Kind: 1 png, 2 svg), then the file bytes.
    /// Daemon-injected (only the daemon can read the app host's icon
    /// theme); the client decodes and calls gdk_toplevel_set_icon_list.
    toplevel_icon = 26,
    /// mime string; the brain announces a host PRIMARY selection
    /// (middle-click paste) — the wl-clipboard twin of offer_selection.
    offer_primary = 27,
    /// Raw primary-selection paste bytes. GUI→daemon: for the oldest
    /// held PRIMARY receive-fd (separate FIFO from clip_data so
    /// interleaved clipboard/primary pastes can't swap).
    primary_data = 28,
    /// utf8 string, viewer → daemon brain: IME-committed text for
    /// the focused+enabled zwp_text_input_v3.
    text_commit = 29,
    /// u32 source id, u32 offer id, mime string. Brain → daemon
    /// (LOCAL, never on the mux wire): a within-app dnd drop wants
    /// the source's data — take the held receive-fd FOR THAT OFFER
    /// and emit source.send(mime, fd). Offer-keyed so it can't steal
    /// the fd of a clipboard paste still awaiting its GUI answer.
    dnd_send = 30,
    /// u32 scale×120, viewer → daemon brain: the display's TRUE
    /// (possibly fractional) scale. The brain re-announces
    /// wl_output.scale (ceil), preferred_buffer_scale (ceil) and
    /// wp_fractional_scale preferred_scale to the app.
    set_scale = 31,
    /// Viewer → daemon brain: the user dropped host data onto a
    /// forwarded window. u32 sid, f64 x, f64 y (surface-local), u32
    /// mime len, mime, then the payload bytes. The brain synthesizes
    /// a server-sourced dnd (enter/action/drop) at those coords.
    host_drop = 32,
    /// u32 offer id, payload bytes. Brain → daemon (LOCAL): answer a
    /// host_drop offer's receive — write the bytes into the held fd
    /// for that offer.
    drop_data = 33,
    /// u32 pool id, u64 incarnation serial. Daemon → replica, trails
    /// every pool_create (live AND replay): the replica ADOPTS the
    /// daemon's serial for that pool incarnation, so serial-addressed
    /// units (pool_update_s) and state_sync buffer serials resolve on
    /// replicas attached mid-session (their self-counted serials
    /// would otherwise diverge from the daemon's).
    pool_serial = 34,
    /// u64 serial, u32 size. Replay only: recreate a displaced
    /// (orphaned) pool incarnation still referenced by live buffers,
    /// filled by pool_update_s units.
    pool_orphan = 35,
    /// Serial-addressed pool_update_c: u64 incarnation serial, u32
    /// offset, pixcodec body. Reaches a pool the id can no longer
    /// address — a client committing a buffer from a displaced pool
    /// incarnation (Wine's DirectDraw mode switches) keeps updating.
    pool_update_s = 36,
    _,
};

pub const header_size = 5;

pub const Unit = struct {
    tag: Tag,
    payload: []const u8,
};

/// Append one unit. Payload must fit u32 minus the tag byte.
pub fn appendUnit(out: *std.ArrayList(u8), allocator: std.mem.Allocator, tag: Tag, payload: []const u8) !void {
    var hdr: [header_size]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload.len + 1), .little);
    hdr[4] = @intFromEnum(tag);
    try out.appendSlice(allocator, &hdr);
    try out.appendSlice(allocator, payload);
}

/// Convenience: unit whose payload starts with ids/sizes then bytes.
pub fn appendPoolUpdate(out: *std.ArrayList(u8), allocator: std.mem.Allocator, pool: u32, offset: u32, bytes: []const u8) !void {
    var hdr: [header_size + 8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(8 + bytes.len + 1), .little);
    hdr[4] = @intFromEnum(Tag.pool_update);
    std.mem.writeInt(u32, hdr[5..9], pool, .little);
    std.mem.writeInt(u32, hdr[9..13], offset, .little);
    try out.appendSlice(allocator, &hdr);
    try out.appendSlice(allocator, bytes);
}

/// Deflated pool update; `raw_len` is the inflated size.
pub fn appendPoolUpdateZ(out: *std.ArrayList(u8), allocator: std.mem.Allocator, pool: u32, offset: u32, raw_len: u32, z: []const u8) !void {
    var hdr: [header_size + 12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(12 + z.len + 1), .little);
    hdr[4] = @intFromEnum(Tag.pool_update_z);
    std.mem.writeInt(u32, hdr[5..9], pool, .little);
    std.mem.writeInt(u32, hdr[9..13], offset, .little);
    std.mem.writeInt(u32, hdr[13..17], raw_len, .little);
    try out.appendSlice(allocator, &hdr);
    try out.appendSlice(allocator, z);
}

/// Codec-tagged pool update. `enc` is the chosen encoding from
/// pixcodec.encodeRegion; `raw_len` is its decoded size and `row_stride`
/// the buffer's bytes-per-row (for the predictor's inverse on the GUI).
pub fn appendPoolUpdateC(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    pool: u32,
    offset: u32,
    enc: pixcodec.Encoded,
    raw_len: u32,
    row_stride: u32,
) !void {
    const payload_len = 8 + pixcodec.body_header + enc.bytes.len;
    var hdr: [header_size + 8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload_len + 1), .little);
    hdr[4] = @intFromEnum(Tag.pool_update_c);
    std.mem.writeInt(u32, hdr[5..9], pool, .little);
    std.mem.writeInt(u32, hdr[9..13], offset, .little);
    try out.appendSlice(allocator, &hdr);
    try pixcodec.appendBody(out, allocator, enc, raw_len, row_stride);
}

pub const PoolUpdateC = struct { pool: u32, offset: u32, body: pixcodec.Body };

pub fn decodePoolUpdateC(payload: []const u8) ?PoolUpdateC {
    if (payload.len < 8) return null;
    const body = pixcodec.peelBody(payload[8..]) orelse return null;
    return .{
        .pool = std.mem.readInt(u32, payload[0..4], .little),
        .offset = std.mem.readInt(u32, payload[4..8], .little),
        .body = body,
    };
}

/// Video-coded pool region. `blob` is an opaque wlhost/vcodec.zig tile
/// (this layer doesn't decode it — the GUI does); we only carry the
/// pool placement (id, byte offset, row stride).
pub fn appendPoolVtile(out: *std.ArrayList(u8), allocator: std.mem.Allocator, pool: u32, offset: u32, row_stride: u32, blob: []const u8) !void {
    const payload_len = 12 + blob.len;
    var hdr: [header_size + 12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload_len + 1), .little);
    hdr[4] = @intFromEnum(Tag.pool_vtile);
    std.mem.writeInt(u32, hdr[5..9], pool, .little);
    std.mem.writeInt(u32, hdr[9..13], offset, .little);
    std.mem.writeInt(u32, hdr[13..17], row_stride, .little);
    try out.appendSlice(allocator, &hdr);
    try out.appendSlice(allocator, blob);
}

pub const PoolVtile = struct { pool: u32, offset: u32, row_stride: u32, blob: []const u8 };

pub fn decodePoolVtile(payload: []const u8) ?PoolVtile {
    if (payload.len < 12) return null;
    return .{
        .pool = std.mem.readInt(u32, payload[0..4], .little),
        .offset = std.mem.readInt(u32, payload[4..8], .little),
        .row_stride = std.mem.readInt(u32, payload[8..12], .little),
        .blob = payload[12..],
    };
}

pub fn appendPoolMeta(out: *std.ArrayList(u8), allocator: std.mem.Allocator, tag: Tag, pool: u32, size: u32) !void {
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], pool, .little);
    std.mem.writeInt(u32, payload[4..8], size, .little);
    try appendUnit(out, allocator, tag, &payload);
}

/// pool_serial: the daemon's incarnation serial for a pool id.
pub fn appendPoolSerial(out: *std.ArrayList(u8), allocator: std.mem.Allocator, pool: u32, serial: u64) !void {
    var payload: [12]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], pool, .little);
    std.mem.writeInt(u64, payload[4..12], serial, .little);
    try appendUnit(out, allocator, .pool_serial, &payload);
}

pub fn decodePoolSerial(payload: []const u8) ?struct { pool: u32, serial: u64 } {
    if (payload.len < 12) return null;
    return .{
        .pool = std.mem.readInt(u32, payload[0..4], .little),
        .serial = std.mem.readInt(u64, payload[4..12], .little),
    };
}

/// pool_orphan: (re)create a displaced pool incarnation, replay only.
pub fn appendPoolOrphan(out: *std.ArrayList(u8), allocator: std.mem.Allocator, serial: u64, size: u32) !void {
    var payload: [12]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], serial, .little);
    std.mem.writeInt(u32, payload[8..12], size, .little);
    try appendUnit(out, allocator, .pool_orphan, &payload);
}

pub fn decodePoolOrphan(payload: []const u8) ?struct { serial: u64, size: u32 } {
    if (payload.len < 12) return null;
    return .{
        .serial = std.mem.readInt(u64, payload[0..8], .little),
        .size = std.mem.readInt(u32, payload[8..12], .little),
    };
}

/// Serial-addressed codec-tagged pool update (see Tag.pool_update_s).
pub fn appendPoolUpdateS(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    serial: u64,
    offset: u32,
    enc: pixcodec.Encoded,
    raw_len: u32,
    row_stride: u32,
) !void {
    const payload_len = 12 + pixcodec.body_header + enc.bytes.len;
    var hdr: [header_size + 12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload_len + 1), .little);
    hdr[4] = @intFromEnum(Tag.pool_update_s);
    std.mem.writeInt(u64, hdr[5..13], serial, .little);
    std.mem.writeInt(u32, hdr[13..17], offset, .little);
    try out.appendSlice(allocator, &hdr);
    try pixcodec.appendBody(out, allocator, enc, raw_len, row_stride);
}

pub const PoolUpdateS = struct { serial: u64, offset: u32, body: pixcodec.Body };

pub fn decodePoolUpdateS(payload: []const u8) ?PoolUpdateS {
    if (payload.len < 12) return null;
    const body = pixcodec.peelBody(payload[12..]) orelse return null;
    return .{
        .serial = std.mem.readInt(u64, payload[0..8], .little),
        .offset = std.mem.readInt(u32, payload[8..12], .little),
        .body = body,
    };
}

// ── seat-intent encoders (viewer → daemon brain) ────────────────

fn putF64(b: []u8, off: usize, v: f64) void {
    std.mem.writeInt(u64, b[off..][0..8], @bitCast(v), .little);
}

fn putU32At(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}

pub fn appendSeatEnter(out: *std.ArrayList(u8), a: std.mem.Allocator, sid: u32, x: f64, y: f64) !void {
    var pl: [20]u8 = undefined;
    putU32At(&pl, 0, sid);
    putF64(&pl, 4, x);
    putF64(&pl, 12, y);
    try appendUnit(out, a, .seat_enter, &pl);
}

pub fn appendSeatMotion(out: *std.ArrayList(u8), a: std.mem.Allocator, x: f64, y: f64) !void {
    var pl: [16]u8 = undefined;
    putF64(&pl, 0, x);
    putF64(&pl, 8, y);
    try appendUnit(out, a, .seat_motion, &pl);
}

pub fn appendSeatButton(out: *std.ArrayList(u8), a: std.mem.Allocator, button: u32, pressed: bool) !void {
    var pl: [5]u8 = undefined;
    putU32At(&pl, 0, button);
    pl[4] = @intFromBool(pressed);
    try appendUnit(out, a, .seat_button, &pl);
}

/// `value120` is the high-resolution wheel amount (±120 per detent,
/// wl_pointer.axis_value120 semantics); 0 = smooth/finger scroll.
/// Old receivers read only the first 12 bytes — compatible both ways.
pub fn appendSeatAxis(out: *std.ArrayList(u8), a: std.mem.Allocator, axis: u32, value: f64, value120: i32) !void {
    var pl: [16]u8 = undefined;
    putU32At(&pl, 0, axis);
    putF64(&pl, 4, value);
    putU32At(&pl, 12, @bitCast(value120));
    try appendUnit(out, a, .seat_axis, &pl);
}

pub fn appendSeatKbdEnter(out: *std.ArrayList(u8), a: std.mem.Allocator, sid: u32) !void {
    var pl: [4]u8 = undefined;
    putU32At(&pl, 0, sid);
    try appendUnit(out, a, .seat_kbd_enter, &pl);
}

pub fn appendSeatKey(out: *std.ArrayList(u8), a: std.mem.Allocator, key: u32, pressed: bool) !void {
    var pl: [5]u8 = undefined;
    putU32At(&pl, 0, key);
    pl[4] = @intFromBool(pressed);
    try appendUnit(out, a, .seat_key, &pl);
}

pub fn appendSeatMods(out: *std.ArrayList(u8), a: std.mem.Allocator, depressed: u32, latched: u32, locked: u32, group: u32) !void {
    var pl: [16]u8 = undefined;
    putU32At(&pl, 0, depressed);
    putU32At(&pl, 4, latched);
    putU32At(&pl, 8, locked);
    putU32At(&pl, 12, group);
    try appendUnit(out, a, .seat_mods, &pl);
}

/// Host data dropped onto surface `sid` at surface-local (x, y).
pub fn appendHostDrop(out: *std.ArrayList(u8), a: std.mem.Allocator, sid: u32, x: f64, y: f64, mime: []const u8, data: []const u8) !void {
    var hdr: [header_size + 24]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(24 + mime.len + data.len + 1), .little);
    hdr[4] = @intFromEnum(Tag.host_drop);
    std.mem.writeInt(u32, hdr[5..9], sid, .little);
    std.mem.writeInt(u64, hdr[9..17], @bitCast(x), .little);
    std.mem.writeInt(u64, hdr[17..25], @bitCast(y), .little);
    std.mem.writeInt(u32, hdr[25..29], @intCast(mime.len), .little);
    try out.appendSlice(a, &hdr);
    try out.appendSlice(a, mime);
    try out.appendSlice(a, data);
}

/// state bits: 1 activated, 2 maximized, 4 fullscreen, 8 resizing.
pub fn appendConfigure(out: *std.ArrayList(u8), a: std.mem.Allocator, sid: u32, w: i32, h: i32, state_bits: u32) !void {
    var pl: [16]u8 = undefined;
    putU32At(&pl, 0, sid);
    putU32At(&pl, 4, @bitCast(w));
    putU32At(&pl, 8, @bitCast(h));
    putU32At(&pl, 12, state_bits);
    try appendUnit(out, a, .configure, &pl);
}

pub fn appendToplevelIcon(out: *std.ArrayList(u8), a: std.mem.Allocator, sid: u32, kind: u8, bytes: []const u8) !void {
    var hdr: [header_size + 5]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(5 + bytes.len + 1), .little);
    hdr[4] = @intFromEnum(Tag.toplevel_icon);
    std.mem.writeInt(u32, hdr[5..9], sid, .little);
    hdr[9] = kind;
    try out.appendSlice(a, &hdr);
    try out.appendSlice(a, bytes);
}

pub fn appendRequestClose(out: *std.ArrayList(u8), a: std.mem.Allocator, sid: u32) !void {
    var pl: [4]u8 = undefined;
    putU32At(&pl, 0, sid);
    try appendUnit(out, a, .request_close, &pl);
}

pub const max_unit = 16 << 20; // matches mux MAX_FRAME; sanity bound

/// Split one unit off `bytes`; null when incomplete. `consumed` is
/// what to drop from the stream.
pub fn peelUnit(bytes: []const u8) error{ Malformed, TooLong }!?struct { unit: Unit, consumed: usize } {
    if (bytes.len < header_size) return null;
    const len = std.mem.readInt(u32, bytes[0..4], .little);
    if (len == 0) return error.Malformed;
    if (len > max_unit) return error.TooLong;
    if (bytes.len < 4 + len) return null;
    return .{
        .unit = .{
            .tag = @enumFromInt(bytes[4]),
            .payload = bytes[5 .. 4 + len],
        },
        .consumed = 4 + len,
    };
}

/// Decoded pool_update payload view.
pub fn decodePoolUpdate(payload: []const u8) ?struct { pool: u32, offset: u32, bytes: []const u8 } {
    if (payload.len < 8) return null;
    return .{
        .pool = std.mem.readInt(u32, payload[0..4], .little),
        .offset = std.mem.readInt(u32, payload[4..8], .little),
        .bytes = payload[8..],
    };
}

/// Decoded pool_update_z payload view.
pub fn decodePoolUpdateZ(payload: []const u8) ?struct { pool: u32, offset: u32, raw_len: u32, z: []const u8 } {
    if (payload.len < 12) return null;
    return .{
        .pool = std.mem.readInt(u32, payload[0..4], .little),
        .offset = std.mem.readInt(u32, payload[4..8], .little),
        .raw_len = std.mem.readInt(u32, payload[8..12], .little),
        .z = payload[12..],
    };
}

pub fn decodePoolMeta(payload: []const u8) ?struct { pool: u32, size: u32 } {
    if (payload.len < 8) return null;
    return .{
        .pool = std.mem.readInt(u32, payload[0..4], .little),
        .size = std.mem.readInt(u32, payload[4..8], .little),
    };
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

test "units peel across arbitrary split points" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    try appendUnit(&out, a, .wl_msg, "\x01\x00\x00\x00\x0c\x00\x01\x00\x02\x00\x00\x00");
    try appendPoolMeta(&out, a, .pool_create, 4, 4096);
    try appendPoolUpdate(&out, a, 4, 128, "pixels");

    // No split point yields a unit boundary error; partial = null.
    var pos: usize = 0;
    var units: usize = 0;
    var cut: usize = 0;
    while (cut <= out.items.len) : (cut += 1) {
        pos = 0;
        units = 0;
        while (try peelUnit(out.items[pos..@min(cut, out.items.len)])) |p| {
            pos += p.consumed;
            units += 1;
        }
        if (cut == out.items.len) try t.expectEqual(@as(usize, 3), units);
    }

    pos = 0;
    const first = (try peelUnit(out.items[pos..])).?;
    try t.expectEqual(Tag.wl_msg, first.unit.tag);
    pos += first.consumed;
    const second = (try peelUnit(out.items[pos..])).?;
    const meta = decodePoolMeta(second.unit.payload).?;
    try t.expectEqual(@as(u32, 4), meta.pool);
    try t.expectEqual(@as(u32, 4096), meta.size);
    pos += second.consumed;
    const third = (try peelUnit(out.items[pos..])).?;
    const upd = decodePoolUpdate(third.unit.payload).?;
    try t.expectEqual(@as(u32, 128), upd.offset);
    try t.expectEqualStrings("pixels", upd.bytes);
}

test "pool_update_c carries addressing + a decodable pixcodec body" {
    const a = t.allocator;
    var sc: pixcodec.Scratch = .{};
    defer sc.deinit(a);

    // A compressible BGRA region (horizontal ramp → predictor wins).
    const stride = 8 * 4;
    const rows = 4;
    var px: [stride * rows]u8 = undefined;
    for (0..rows) |y| for (0..8) |x| {
        const i = (y * 8 + x) * 4;
        px[i + 0] = @truncate(x * 11 + y * 7);
        px[i + 1] = @truncate(x * 5);
        px[i + 2] = 0x10;
        px[i + 3] = 0xff;
    };
    const enc = try pixcodec.encodeRegion(&sc, a, &px, stride);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendPoolUpdateC(&out, a, 4, 256, enc, px.len, stride);

    const p = (try peelUnit(out.items)).?;
    try t.expectEqual(Tag.pool_update_c, p.unit.tag);
    try t.expectEqual(out.items.len, p.consumed);
    const upd = decodePoolUpdateC(p.unit.payload).?;
    try t.expectEqual(@as(u32, 4), upd.pool);
    try t.expectEqual(@as(u32, 256), upd.offset);
    try t.expectEqual(@as(u32, px.len), upd.body.raw_len);

    var dst: [stride * rows]u8 = undefined;
    try pixcodec.decodeBody(upd.body, &dst);
    try t.expectEqualSlices(u8, &px, &dst);
}

test "pool_vtile carries pool placement + an opaque video blob" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const blob = "an-opaque-vcodec-tile-bitstream";
    try appendPoolVtile(&out, a, 4, 4096, 1280, blob);

    const p = (try peelUnit(out.items)).?;
    try t.expectEqual(Tag.pool_vtile, p.unit.tag);
    try t.expectEqual(out.items.len, p.consumed);
    const vt = decodePoolVtile(p.unit.payload).?;
    try t.expectEqual(@as(u32, 4), vt.pool);
    try t.expectEqual(@as(u32, 4096), vt.offset);
    try t.expectEqual(@as(u32, 1280), vt.row_stride);
    try t.expectEqualStrings(blob, vt.blob);
}

test "unknown tags peel cleanly for forward compat" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendUnit(&out, a, @enumFromInt(200), "future");
    const p = (try peelUnit(out.items)).?;
    try t.expectEqualStrings("future", p.unit.payload);
}

test "zero-length unit is malformed" {
    const zero = [_]u8{ 0, 0, 0, 0, 0 };
    try t.expectError(error.Malformed, peelUnit(&zero));
}
