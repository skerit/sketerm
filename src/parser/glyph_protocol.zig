//! Rio Glyph Protocol (v1.9) wire parser + `glyf` structural decoder.
//!
//! Framing: `ESC _ 25a1 ; <verb> [; key=value]* [; <base64>] ESC \`.
//! This module sees the APC BODY only (introducer/terminator already
//! stripped by the VT parser). Bodies not starting with the literal
//! `25a1` are not ours and must fall through to other APC consumers.
//!
//! Where the published spec and Rio's implementation disagree, this
//! follows the implementation (`rio-vt/src/ansi/glyph_protocol.rs`):
//! notably `width` is a render-span hint only — layout, cursor and
//! selection keep following wcwidth — and unknown parameters
//! (including the spec's aw/lh/size/align/pad) are silently ignored.
//! This build accepts `fmt=glyf`, `fmt=colrv0` and `fmt=colrv1` —
//! full format parity with Rio.
//!
//! One deliberate departure from Rio for the colour formats: Rio hands
//! the COLR/CPAL tables to the renderer unvalidated; we validate the
//! whole container at register time (like glyf) so a broken payload is
//! rejected on the wire instead of caching as an invisible glyph. For
//! colrv1 that includes a bounded walk of the whole paint graph
//! (formats, offsets, indices, cycles, boundedness) — only geometric
//! degeneracy that needs raster arithmetic (zero-length gradients,
//! repeat-extend colour lines whose stops coincide, singular
//! transforms) is left to the GUI rasteriser, which degrades those
//! nodes to nothing rather than failing the glyph.
//!
//! Pure Zig, no libc — compiles into `sketerm-mux`.

const std = @import("std");

/// Protocol identifier prefixing every Glyph Protocol APC body.
pub const PREFIX = "25a1";

/// Post-base64-decode cap on a single registered payload (spec 64 KiB).
pub const MAX_PAYLOAD_BYTES: usize = 64 * 1024;

/// Formats advertised in the `s` reply.
pub const SUPPORTED_FORMATS = "glyf,colrv0,colrv1";

/// Payload container format of a registration. The u8 tag rides the
/// snapshot wire — append-only, never renumber.
pub const Format = enum(u8) {
    glyf = 0,
    colrv0 = 1,
    colrv1 = 2,
};

/// The three Unicode Private Use Areas. Note the FFFD ends — the two
/// plane-final noncharacters are excluded.
pub fn isPua(cp: u32) bool {
    return (cp >= 0xE000 and cp <= 0xF8FF) or
        (cp >= 0xF0000 and cp <= 0xFFFFD) or
        (cp >= 0x100000 and cp <= 0x10FFFD);
}

/// Three-level reply control for `r` (`reply=0/1/2`). Unknown values
/// fall back to `.all` per the unknown-params conformance rule.
pub const ReplyMode = enum {
    none,
    all,
    errors_only,

    pub fn emitSuccess(self: ReplyMode) bool {
        return self == .all;
    }
    pub fn emitError(self: ReplyMode) bool {
        return self != .none;
    }

    fn fromWire(raw: []const u8) ReplyMode {
        if (std.mem.eql(u8, raw, "0")) return .none;
        if (std.mem.eql(u8, raw, "2")) return .errors_only;
        return .all;
    }
};

/// `reason=` codes for register/clear failures (spec section 6.2).
pub const RegisterError = enum {
    out_of_namespace,
    composite_unsupported,
    hinting_unsupported,
    malformed_payload,
    payload_too_large,

    pub fn str(self: RegisterError) []const u8 {
        return switch (self) {
            .out_of_namespace => "out_of_namespace",
            .composite_unsupported => "composite_unsupported",
            .hinting_unsupported => "hinting_unsupported",
            .malformed_payload => "malformed_payload",
            .payload_too_large => "payload_too_large",
        };
    }
};

pub const Register = struct {
    cp: u32,
    /// Decoded payload (glyf record or colrv0 container), allocated
    /// with the allocator handed to `parse`. Caller owns (frees or
    /// adopts into the glossary).
    payload: []u8,
    fmt: Format,
    upm: u16,
    /// Render span (1 or 2). A paint hint only, never layout.
    width: u8,
    reply: ReplyMode,
};

/// Parse outcome. `.malformed` covers everything the dispatcher must
/// silently drop (bad framing, unknown verbs/fmt, invalid cp hex);
/// `.register_failed` carries the reply level so error suppression
/// (`reply=0`) is honoured on parse-time rejections too.
pub const Result = union(enum) {
    not_glyph_protocol,
    malformed,
    support,
    query: u32,
    register: Register,
    register_failed: struct { cp: u32, reason: RegisterError, reply: ReplyMode },
    clear: ?u32,
    clear_out_of_namespace,
};

/// Parse a raw APC body. On `.register` the payload is allocated with
/// `allocator`; every other variant allocates nothing.
pub fn parse(allocator: std.mem.Allocator, body: []const u8) Result {
    if (!std.mem.startsWith(u8, body, PREFIX)) return .not_glyph_protocol;
    var rest = body[PREFIX.len..];
    if (rest.len == 0 or rest[0] != ';') return .malformed;
    rest = rest[1..];

    const semi = std.mem.indexOfScalar(u8, rest, ';');
    const verb = trim(if (semi) |s| rest[0..s] else rest);
    const after: []const u8 = if (semi) |s| rest[s + 1 ..] else "";
    if (verb.len != 1) return .malformed;
    return switch (verb[0]) {
        's' => .support,
        'q' => parseQuery(after),
        'r' => parseRegister(allocator, after),
        'c' => parseClear(after),
        else => .malformed,
    };
}

fn parseQuery(rest: []const u8) Result {
    var params = Params.init(rest);
    const raw = params.get("cp") orelse return .malformed;
    if (std.mem.indexOfScalar(u8, raw, ',') != null) return .malformed;
    const cp = parseHexCp(raw) orelse return .malformed;
    return .{ .query = cp };
}

fn parseRegister(allocator: std.mem.Allocator, rest: []const u8) Result {
    // Control params and the base64 payload split at the LAST `;` —
    // base64 contains no `;` so this is unambiguous.
    const last = std.mem.lastIndexOfScalar(u8, rest, ';');
    const control = if (last) |p| rest[0..p] else rest;
    const payload_b64 = trim(if (last) |p| rest[p + 1 ..] else "");

    var params = Params.init(control);
    const cp_raw = params.get("cp") orelse return .malformed;
    if (std.mem.indexOfScalar(u8, cp_raw, ',') != null) return .malformed;
    const cp = parseHexCp(cp_raw) orelse return .malformed;

    // Extract `reply` before any can-fail validation so every error
    // path below honours the level.
    const reply: ReplyMode = if (params.get("reply")) |r| ReplyMode.fromWire(r) else .all;

    if (!isPua(cp))
        return .{ .register_failed = .{ .cp = cp, .reason = .out_of_namespace, .reply = reply } };

    // All three advertised formats; anything else is dropped like an
    // unknown fmt — see the module doc.
    var fmt: Format = .glyf;
    if (params.get("fmt")) |raw_fmt| {
        if (std.mem.eql(u8, raw_fmt, "glyf")) {
            fmt = .glyf;
        } else if (std.mem.eql(u8, raw_fmt, "colrv0")) {
            fmt = .colrv0;
        } else if (std.mem.eql(u8, raw_fmt, "colrv1")) {
            fmt = .colrv1;
        } else return .malformed;
    }

    var upm: u16 = 1000;
    if (params.get("upm")) |raw| {
        upm = parseDecimalU16(raw) orelse return .malformed;
    }
    if (upm == 0) return .malformed;

    var width: u8 = 1;
    if (params.get("width")) |raw| {
        const w = trim(raw);
        if (std.mem.eql(u8, w, "1")) {
            width = 1;
        } else if (std.mem.eql(u8, w, "2")) {
            width = 2;
        } else return .malformed;
    }

    const decoder = std.base64.standard.Decoder;
    const out_len = decoder.calcSizeForSlice(payload_b64) catch
        return .{ .register_failed = .{ .cp = cp, .reason = .malformed_payload, .reply = reply } };
    if (out_len > MAX_PAYLOAD_BYTES)
        return .{ .register_failed = .{ .cp = cp, .reason = .payload_too_large, .reply = reply } };
    // Empty payload is never a valid registration: it usually means
    // the trailing `;<base64>` segment was omitted altogether, and
    // accepting it would register an empty glyph for the slot.
    if (out_len == 0)
        return .{ .register_failed = .{ .cp = cp, .reason = .malformed_payload, .reply = reply } };
    const raw = allocator.alloc(u8, out_len) catch return .malformed;
    decoder.decode(raw, payload_b64) catch {
        allocator.free(raw);
        return .{ .register_failed = .{ .cp = cp, .reason = .malformed_payload, .reply = reply } };
    };

    return .{ .register = .{ .cp = cp, .payload = raw, .fmt = fmt, .upm = upm, .width = width, .reply = reply } };
}

fn parseClear(rest: []const u8) Result {
    var params = Params.init(rest);
    const raw = params.get("cp") orelse return .{ .clear = null };
    if (std.mem.indexOfScalar(u8, raw, ',') != null) return .malformed;
    const cp = parseHexCp(raw) orelse return .malformed;
    if (!isPua(cp)) return .clear_out_of_namespace;
    return .{ .clear = cp };
}

/// Semicolon-separated `key=value` scanner. Later duplicates win,
/// matching Rio; unknown keys are simply never asked for.
const Params = struct {
    data: []const u8,

    fn init(data: []const u8) Params {
        return .{ .data = data };
    }

    fn get(self: *Params, key: []const u8) ?[]const u8 {
        var found: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, self.data, ';');
        while (it.next()) |part_raw| {
            const part = trim(part_raw);
            if (part.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
            if (std.mem.eql(u8, trim(part[0..eq]), key)) found = trim(part[eq + 1 ..]);
        }
        return found;
    }
};

/// Hex codepoint: no `0x`, up to 6 digits, must be a Unicode scalar
/// value (<= 0x10FFFF, not a surrogate).
fn parseHexCp(raw_in: []const u8) ?u32 {
    const raw = trim(raw_in);
    if (raw.len == 0 or raw.len > 6) return null;
    var out: u32 = 0;
    for (raw) |b| {
        const d: u32 = switch (b) {
            '0'...'9' => b - '0',
            'a'...'f' => b - 'a' + 10,
            'A'...'F' => b - 'A' + 10,
            else => return null,
        };
        out = (out << 4) | d;
    }
    if (out > 0x10FFFF or (out >= 0xD800 and out <= 0xDFFF)) return null;
    return out;
}

fn parseDecimalU16(raw_in: []const u8) ?u16 {
    const raw = trim(raw_in);
    if (raw.len == 0) return null;
    var out: u32 = 0;
    for (raw) |b| {
        if (b < '0' or b > '9') return null;
        out = out * 10 + (b - '0');
        if (out > std.math.maxInt(u16)) return null;
    }
    return @intCast(out);
}

fn trim(data: []const u8) []const u8 {
    return std.mem.trim(u8, data, " \t\r\n");
}

// ── reply formatting ─────────────────────────────────────────────

pub fn fmtSupport(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b_25a1;s;fmt=" ++ SUPPORTED_FORMATS ++ "\x1b\\", .{}) catch unreachable;
}

/// `status=` is a comma set of coverage names; empty means tofu.
pub fn fmtQuery(buf: []u8, cp: u32, system: bool, glossary: bool) []const u8 {
    const status: []const u8 = if (system and glossary)
        "system,glossary"
    else if (system)
        "system"
    else if (glossary)
        "glossary"
    else
        "";
    return std.fmt.bufPrint(buf, "\x1b_25a1;q;cp={x};status={s}\x1b\\", .{ cp, status }) catch unreachable;
}

pub fn fmtRegisterOk(buf: []u8, cp: u32) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b_25a1;r;cp={x};status=0\x1b\\", .{cp}) catch unreachable;
}

pub fn fmtRegisterErr(buf: []u8, cp: u32, reason: RegisterError) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b_25a1;r;cp={x};status=1;reason={s}\x1b\\", .{ cp, reason.str() }) catch unreachable;
}

pub fn fmtClearOk(buf: []u8, cp: ?u32) []const u8 {
    if (cp) |v| return std.fmt.bufPrint(buf, "\x1b_25a1;c;cp={x};status=0\x1b\\", .{v}) catch unreachable;
    return std.fmt.bufPrint(buf, "\x1b_25a1;c;status=0\x1b\\", .{}) catch unreachable;
}

pub fn fmtClearErrOutOfNamespace(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b_25a1;c;status=1;reason=out_of_namespace\x1b\\", .{}) catch unreachable;
}

// ── glyf simple-glyph decoder ────────────────────────────────────

pub const DecodeError = error{
    /// numberOfContours < 0 — composite glyph reference.
    Composite,
    /// instructionLength > 0 — hinting bytecode is not accepted.
    Hinted,
    Malformed,
    OutOfMemory,
};

pub const Point = struct {
    x: i32,
    y: i32,
    on_curve: bool,
};

/// Decoded simple glyph: a flat point list plus per-contour last-point
/// indices — deliberately the same shape as FreeType's FT_Outline so
/// the GUI rasteriser can feed it straight in.
pub const Outline = struct {
    points: []Point,
    /// Index of each contour's LAST point (inclusive), ascending.
    ends: []u16,
    x_min: i32,
    y_min: i32,
    x_max: i32,
    y_max: i32,

    pub fn deinit(self: *Outline, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.ends);
        self.* = undefined;
    }
};

const FLAG_ON_CURVE: u8 = 0x01;
const FLAG_X_SHORT: u8 = 0x02;
const FLAG_Y_SHORT: u8 = 0x04;
const FLAG_REPEAT: u8 = 0x08;
const FLAG_X_SAME_OR_POS: u8 = 0x10;
const FLAG_Y_SAME_OR_POS: u8 = 0x20;

/// Decode a bare OpenType simple-glyph record. Trailing bytes after
/// the coordinate arrays are tolerated (fonts pad records to even
/// length); truncation anywhere is `Malformed`.
pub fn decodeGlyf(allocator: std.mem.Allocator, data: []const u8) DecodeError!Outline {
    if (data.len < 10) return error.Malformed;
    const n_contours_raw = std.mem.readInt(i16, data[0..2], .big);
    if (n_contours_raw < 0) return error.Composite;
    const n_contours: usize = @intCast(n_contours_raw);

    const x_min: i32 = std.mem.readInt(i16, data[2..4], .big);
    const y_min: i32 = std.mem.readInt(i16, data[4..6], .big);
    const x_max: i32 = std.mem.readInt(i16, data[6..8], .big);
    const y_max: i32 = std.mem.readInt(i16, data[8..10], .big);

    var pos: usize = 10;
    if (pos + n_contours * 2 + 2 > data.len) return error.Malformed;
    const ends = try allocator.alloc(u16, n_contours);
    errdefer allocator.free(ends);
    for (ends) |*e| {
        e.* = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;
    }
    // End-points must be strictly increasing.
    var ci: usize = 1;
    while (ci < ends.len) : (ci += 1) {
        if (ends[ci] <= ends[ci - 1]) return error.Malformed;
    }

    const instr_len = std.mem.readInt(u16, data[pos..][0..2], .big);
    pos += 2;
    if (instr_len != 0) return error.Hinted;

    const n_points: usize = if (n_contours == 0) 0 else @as(usize, ends[n_contours - 1]) + 1;
    const points = try allocator.alloc(Point, n_points);
    errdefer allocator.free(points);

    // Flags, with REPEAT expansion. A repeat spilling past n_points is
    // a structural error, not a clamp.
    const flags = try allocator.alloc(u8, n_points);
    defer allocator.free(flags);
    var fi: usize = 0;
    while (fi < n_points) {
        if (pos >= data.len) return error.Malformed;
        const f = data[pos];
        pos += 1;
        flags[fi] = f;
        fi += 1;
        if (f & FLAG_REPEAT != 0) {
            if (pos >= data.len) return error.Malformed;
            const n_rep = data[pos];
            pos += 1;
            if (fi + n_rep > n_points) return error.Malformed;
            var r: usize = 0;
            while (r < n_rep) : (r += 1) {
                flags[fi] = f;
                fi += 1;
            }
        }
    }

    // X coordinates (deltas), then Y.
    var x_acc: i32 = 0;
    for (flags, 0..) |f, i| {
        if (f & FLAG_X_SHORT != 0) {
            if (pos >= data.len) return error.Malformed;
            const d: i32 = data[pos];
            pos += 1;
            x_acc += if (f & FLAG_X_SAME_OR_POS != 0) d else -d;
        } else if (f & FLAG_X_SAME_OR_POS == 0) {
            if (pos + 2 > data.len) return error.Malformed;
            x_acc += std.mem.readInt(i16, data[pos..][0..2], .big);
            pos += 2;
        }
        points[i] = .{ .x = x_acc, .y = 0, .on_curve = f & FLAG_ON_CURVE != 0 };
    }
    var y_acc: i32 = 0;
    for (flags, 0..) |f, i| {
        if (f & FLAG_Y_SHORT != 0) {
            if (pos >= data.len) return error.Malformed;
            const d: i32 = data[pos];
            pos += 1;
            y_acc += if (f & FLAG_Y_SAME_OR_POS != 0) d else -d;
        } else if (f & FLAG_Y_SAME_OR_POS == 0) {
            if (pos + 2 > data.len) return error.Malformed;
            y_acc += std.mem.readInt(i16, data[pos..][0..2], .big);
            pos += 2;
        }
        points[i].y = y_acc;
    }

    return .{
        .points = points,
        .ends = ends,
        .x_min = x_min,
        .y_min = y_min,
        .x_max = x_max,
        .y_max = y_max,
    };
}

/// Structural validation only — decode and discard. Returns the wire
/// error code a failing payload should be rejected with, null when OK.
pub fn validateGlyf(allocator: std.mem.Allocator, data: []const u8) ?RegisterError {
    var outline = decodeGlyf(allocator, data) catch |err| return switch (err) {
        error.Composite => .composite_unsupported,
        error.Hinted => .hinting_unsupported,
        error.Malformed => .malformed_payload,
        // OOM at validation time: the payload itself may be fine, but
        // we cannot store what we cannot decode — report it oversized
        // rather than structurally bad.
        error.OutOfMemory => .payload_too_large,
    };
    outline.deinit(allocator);
    return null;
}

// ── colrv0 container ─────────────────────────────────────────────

/// Upper bound on outlines carried in one colour payload (Rio's
/// MAX_COLR_GLYPHS).
pub const MAX_COLR_GLYPHS: usize = 1024;

/// CPAL palette index meaning "the current SGR foreground". Layers
/// using it make the rasterisation foreground-dependent.
pub const PALETTE_FOREGROUND: u16 = 0xFFFF;

pub const ColrLayer = struct {
    /// Index into the carried outline array.
    glyph: u16,
    /// Resolved straight RGBA (0xRRGGBBAA) from CPAL palette 0.
    /// Undefined-but-zero when `is_fg` — the renderer substitutes the
    /// live foreground.
    rgba: u32,
    is_fg: bool,
};

/// Decoded colrv0 container. `outlines` are borrowed slices into the
/// input payload; only the arrays are allocated.
pub const Colr = struct {
    outlines: []const []const u8,
    /// The base glyph's layer run, painter's order (first painted
    /// first). May be empty — a zero-layer base renders blank.
    layers: []const ColrLayer,
    /// Any layer references PALETTE_FOREGROUND, so the rasterisation
    /// depends on the current foreground colour.
    uses_fg: bool,

    pub fn deinit(self: *Colr, allocator: std.mem.Allocator) void {
        allocator.free(self.outlines);
        allocator.free(self.layers);
        self.* = undefined;
    }
};

pub const ColrDecodeError = error{ Malformed, OutOfMemory };

const BeCursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn u16be(self: *BeCursor) ?u16 {
        if (self.pos + 2 > self.data.len) return null;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
        self.pos += 2;
        return v;
    }

    fn slice(self: *BeCursor, n: usize) ?[]const u8 {
        if (self.pos + n > self.data.len) return null;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
};

fn readU16(data: []const u8, off: usize) ?u16 {
    if (off + 2 > data.len) return null;
    return std.mem.readInt(u16, data[off..][0..2], .big);
}

fn readU32(data: []const u8, off: usize) ?u32 {
    if (off + 4 > data.len) return null;
    return std.mem.readInt(u32, data[off..][0..4], .big);
}

/// Shared container framing for both colour formats: `u16 n_glyphs,
/// n×(u16 len + glyf bytes), u16 colr_len + COLR, u16 cpal_len +
/// CPAL`. Trailing bytes are malformed (Rio parity). `outlines` is
/// the only allocation; the table slices borrow the input.
const Container = struct {
    outlines: [][]const u8,
    colr: []const u8,
    cpal: []const u8,
};

fn splitContainer(allocator: std.mem.Allocator, data: []const u8) ColrDecodeError!Container {
    var cur = BeCursor{ .data = data };
    const n_glyphs = cur.u16be() orelse return error.Malformed;
    if (n_glyphs == 0 or n_glyphs > MAX_COLR_GLYPHS) return error.Malformed;

    const outlines = try allocator.alloc([]const u8, n_glyphs);
    errdefer allocator.free(outlines);
    for (outlines) |*o| {
        const len = cur.u16be() orelse return error.Malformed;
        o.* = cur.slice(len) orelse return error.Malformed;
    }

    const colr_len = cur.u16be() orelse return error.Malformed;
    if (colr_len == 0) return error.Malformed;
    const colr = cur.slice(colr_len) orelse return error.Malformed;

    const cpal_len = cur.u16be() orelse return error.Malformed;
    const cpal = cur.slice(cpal_len) orelse return error.Malformed;

    if (cur.pos != data.len) return error.Malformed;
    return .{ .outlines = outlines, .colr = colr, .cpal = cpal };
}

/// Parsed view of the (optional) CPAL table. Only palette 0 is
/// consulted. Absent CPAL (`data.len == 0`) is legal — then every
/// colour reference must be the 0xFFFF foreground sentinel.
pub const CpalView = struct {
    data: []const u8,
    n_entries: u16,
    first: u16,
    records_off: usize,

    /// Straight 0xRRGGBBAA for a palette index, null when out of
    /// range (records are BGRA on disk).
    pub fn rgba(self: *const CpalView, idx: u16) ?u32 {
        if (idx >= self.n_entries) return null;
        const co = self.records_off + (@as(usize, self.first) + idx) * 4;
        const b: u32 = self.data[co];
        const g: u32 = self.data[co + 1];
        const r: u32 = self.data[co + 2];
        const a: u32 = self.data[co + 3];
        return (r << 24) | (g << 16) | (b << 8) | a;
    }
};

/// CPAL header: version, numPaletteEntries, numPalettes,
/// numColorRecords, colorRecordsArrayOffset, u16 indices[palettes].
fn parseCpal(cpal: []const u8) error{Malformed}!CpalView {
    if (cpal.len == 0)
        return .{ .data = cpal, .n_entries = 0, .first = 0, .records_off = 0 };
    if (cpal.len < 12) return error.Malformed;
    const cpal_version = readU16(cpal, 0).?;
    // v1 adds trailing offset fields we don't consult; both parse.
    if (cpal_version > 1) return error.Malformed;
    const n_palette_entries = readU16(cpal, 2).?;
    const n_palettes = readU16(cpal, 4).?;
    const n_color_records = readU16(cpal, 6).?;
    const records_off: usize = readU32(cpal, 8).?;
    if (n_palette_entries == 0 or n_palettes == 0) return error.Malformed;
    if (12 + @as(usize, n_palettes) * 2 > cpal.len) return error.Malformed;
    const palette0_first = readU16(cpal, 12).?;
    if (@as(usize, palette0_first) + n_palette_entries > n_color_records) return error.Malformed;
    if (records_off + @as(usize, n_color_records) * 4 > cpal.len) return error.Malformed;
    return .{
        .data = cpal,
        .n_entries = n_palette_entries,
        .first = palette0_first,
        .records_off = records_off,
    };
}

/// Decode the custom big-endian colrv0 container (NOT an sfnt).
/// The base layer run is the COLR record for GlyphId 0 (the spec's
/// base glyph); with no record for 0 the first record is used
/// defensively. Carried outlines are NOT glyf-decoded here — see
/// `validateColr` for the register-time structural check.
pub fn decodeColr(allocator: std.mem.Allocator, data: []const u8) ColrDecodeError!Colr {
    const cont = try splitContainer(allocator, data);
    const outlines = cont.outlines;
    errdefer allocator.free(outlines);
    const colr = cont.colr;
    const n_glyphs = outlines.len;

    const cpal_view = parseCpal(cont.cpal) catch return error.Malformed;
    const n_palette_entries = cpal_view.n_entries;
    const palette0_first = cpal_view.first;
    const records_off = cpal_view.records_off;
    const cpal = cont.cpal;

    // COLR v0 header: version, numBaseGlyphRecords,
    // baseGlyphRecordsOffset, layerRecordsOffset, numLayerRecords.
    if (colr.len < 14) return error.Malformed;
    if (readU16(colr, 0).? != 0) return error.Malformed; // v1 table under fmt=colrv0
    const n_base = readU16(colr, 2).?;
    const base_off: usize = readU32(colr, 4).?;
    const layers_off: usize = readU32(colr, 8).?;
    const n_layer_records = readU16(colr, 12).?;
    if (n_base == 0) return error.Malformed;
    if (base_off + @as(usize, n_base) * 6 > colr.len) return error.Malformed;
    if (layers_off + @as(usize, n_layer_records) * 4 > colr.len) return error.Malformed;

    // Base record for GlyphId 0, else the first record.
    var chosen: usize = 0;
    var bi: usize = 0;
    while (bi < n_base) : (bi += 1) {
        if (readU16(colr, base_off + bi * 6).? == 0) {
            chosen = bi;
            break;
        }
    }
    const first_layer = readU16(colr, base_off + chosen * 6 + 2).?;
    const n_layers = readU16(colr, base_off + chosen * 6 + 4).?;
    if (@as(usize, first_layer) + n_layers > n_layer_records) return error.Malformed;

    const layers = try allocator.alloc(ColrLayer, n_layers);
    errdefer allocator.free(layers);
    var uses_fg = false;
    for (layers, 0..) |*l, i| {
        const rec = layers_off + (@as(usize, first_layer) + i) * 4;
        const glyph = readU16(colr, rec).?;
        const palette = readU16(colr, rec + 2).?;
        if (glyph >= n_glyphs) return error.Malformed;
        if (palette == PALETTE_FOREGROUND) {
            l.* = .{ .glyph = glyph, .rgba = 0, .is_fg = true };
            uses_fg = true;
        } else {
            if (palette >= n_palette_entries) return error.Malformed;
            const co = records_off + (@as(usize, palette0_first) + palette) * 4;
            // BGRA on disk → straight 0xRRGGBBAA.
            const b: u32 = cpal[co];
            const g: u32 = cpal[co + 1];
            const r: u32 = cpal[co + 2];
            const a: u32 = cpal[co + 3];
            l.* = .{ .glyph = glyph, .rgba = (r << 24) | (g << 16) | (b << 8) | a, .is_fg = false };
        }
    }

    return .{ .outlines = outlines, .layers = layers, .uses_fg = uses_fg };
}

/// Register-time structural validation of a colrv0 container:
/// container framing + COLR/CPAL structure via `decodeColr`, then
/// EVERY carried outline through the glyf decoder so a composite or
/// hinted glyph anywhere in the array is rejected with its own code.
pub fn validateColr(allocator: std.mem.Allocator, data: []const u8) ?RegisterError {
    var colr = decodeColr(allocator, data) catch |err| return switch (err) {
        error.Malformed => .malformed_payload,
        error.OutOfMemory => .payload_too_large,
    };
    defer colr.deinit(allocator);
    for (colr.outlines) |o| {
        if (validateGlyf(allocator, o)) |reason| return reason;
    }
    return null;
}

/// Format-dispatching register-time validation.
pub fn validatePayload(allocator: std.mem.Allocator, fmt: Format, data: []const u8) ?RegisterError {
    return switch (fmt) {
        .glyf => validateGlyf(allocator, data),
        .colrv0 => validateColr(allocator, data),
        .colrv1 => validateColr1(allocator, data),
    };
}

/// Cheap foreground-dependence probe for a stored colour payload.
/// False on anything that fails to decode (broken payloads raster as
/// empty, which is foreground-independent) — and for glyf, which is
/// coverage-tinted rather than colour-baked.
pub fn colrUsesForeground(allocator: std.mem.Allocator, fmt: Format, data: []const u8) bool {
    switch (fmt) {
        .glyf => return false,
        .colrv0 => {
            var colr = decodeColr(allocator, data) catch return false;
            defer colr.deinit(allocator);
            return colr.uses_fg;
        },
        .colrv1 => {
            var c1 = decodeColr1(allocator, data) catch return false;
            defer c1.deinit(allocator);
            return c1.uses_fg;
        },
    }
}

// ── colrv1 container ─────────────────────────────────────────────
//
// Same container framing as colrv0; the COLR table inside is version
// 1 and holds a paint GRAPH (a DAG of solid fills, gradients, affine
// transforms, glyph clips, composites and glyph references) instead
// of v0's flat layer list. Everything here is pure Zig — the decoded
// form is both the daemon's register-time validator and the GUI
// rasteriser's input; the GUI walks the graph again with cairo.
//
// Deliberately NOT interpreted anywhere (parsed and ignored):
// variation deltas — `PaintVar*` nodes read like their non-var
// siblings at the default instance (the protocol cannot carry
// variation coordinates), and varIndexBase/VarIndexMap/
// ItemVariationStore bytes are never consulted.

/// Traversal caps for the paint graph — a walk exceeding either is
/// rejected as malformed. Depth guards true cycles (an offset already
/// on the walk stack is also an immediate reject); the node budget
/// guards ttf-parser's `branching^depth` shared-subgraph blowup.
pub const MAX_V1_DEPTH: usize = 32;
pub const MAX_V1_NODES: usize = 4096;

/// ClipBox for the base glyph, font units.
pub const ClipBox = struct { x_min: i16, y_min: i16, x_max: i16, y_max: i16 };

/// Decoded colrv1 container. Table slices borrow the input payload;
/// only `outlines` is allocated. The paint graph itself stays in
/// `colr` bytes and is re-read node by node via `readPaint` — decode
/// time already walked and validated every reachable node.
pub const Colr1 = struct {
    outlines: []const []const u8,
    colr: []const u8,
    cpal: CpalView,
    /// Absolute offset of BaseGlyphList in `colr`.
    base_list: usize,
    n_base: u32,
    /// Absolute offset of LayerList in `colr`; 0 = absent.
    layer_list: usize,
    n_layer_paints: u32,
    /// Absolute offset of the chosen base glyph's root paint.
    root_paint: usize,
    /// Clip box for the chosen base glyph, if the ClipList has one.
    clip_box: ?ClipBox,
    /// Any reachable colour reference is the 0xFFFF foreground
    /// sentinel, so rasterisation depends on the SGR foreground.
    uses_fg: bool,

    pub fn deinit(self: *Colr1, allocator: std.mem.Allocator) void {
        allocator.free(self.outlines);
        self.* = undefined;
    }

    /// Root paint offset for a referenced COLR glyph (PaintColrGlyph),
    /// null when the BaseGlyphList has no record for `glyph_id`.
    pub fn baseRootPaint(self: *const Colr1, glyph_id: u16) ?usize {
        return baseListFind(self.colr, self.base_list, self.n_base, glyph_id);
    }
};

/// Reference to a ColorLine table. Var colour lines carry a
/// varIndexBase per stop (stride 10 instead of 6) that is skipped.
pub const ColorLineRef = struct { off: usize, var_stops: bool };

pub const ColorLine = struct {
    /// 0 = pad, 1 = repeat, 2 = reflect.
    extend: u8,
    n_stops: u16,
    stops_off: usize,
    stride: usize,
};

pub const ColorStop = struct {
    /// Stop offset — NOT clamped; COLR allows values outside [0,1].
    offset: f32,
    palette: u16,
    alpha: f32,
};

/// One decoded paint node. All offsets are ABSOLUTE into the COLR
/// table slice. The ten transform formats (12–31, var included) fold
/// into `.transform` with the equivalent affine already computed
/// (matrix order xx yx xy yy dx dy, point map x' = xx·x + xy·y + dx);
/// angles are F2Dot14 × 180 counter-clockwise degrees per the spec.
pub const Paint = union(enum) {
    layers: struct { first: u32, count: u8 },
    solid: struct { palette: u16, alpha: f32 },
    linear: struct { color_line: ColorLineRef, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32 },
    radial: struct { color_line: ColorLineRef, x0: f32, y0: f32, r0: f32, x1: f32, y1: f32, r1: f32 },
    /// Angles in degrees with the spec's +1.0 (i.e. +180°) bias
    /// applied. Carried for completeness: the rasteriser degrades
    /// sweep gradients to the first stop's solid colour.
    sweep: struct { color_line: ColorLineRef, cx: f32, cy: f32, start_deg: f32, end_deg: f32 },
    glyph: struct { child: usize, glyph_id: u16 },
    colr_glyph: struct { glyph_id: u16 },
    transform: struct { child: usize, m: [6]f32 },
    composite: struct { source: usize, mode: u8, backdrop: usize },
};

/// COLR composite modes (u8 0..27), spec order. Kept as raw u8 in
/// `Paint.composite`; this is the validation ceiling.
pub const MAX_COMPOSITE_MODE: u8 = 27;

fn readI16(data: []const u8, off: usize) ?i16 {
    const v = readU16(data, off) orelse return null;
    return @bitCast(v);
}

fn readF2Dot14(data: []const u8, off: usize) ?f32 {
    const v = readI16(data, off) orelse return null;
    return @as(f32, @floatFromInt(v)) / 16384.0;
}

fn readFixed(data: []const u8, off: usize) ?f32 {
    const v = readU32(data, off) orelse return null;
    return @as(f32, @floatFromInt(@as(i32, @bitCast(v)))) / 65536.0;
}

fn readOffset24(data: []const u8, off: usize) ?u32 {
    if (off + 3 > data.len) return null;
    return (@as(u32, data[off]) << 16) | (@as(u32, data[off + 1]) << 8) | data[off + 2];
}

/// Fword coordinate as f32.
fn readCoord(data: []const u8, off: usize) ?f32 {
    const v = readI16(data, off) orelse return null;
    return @floatFromInt(v);
}

/// Child offset: Offset24 relative to the referencing paint table's
/// own start, zero forbidden (a paint is never its own child).
fn childOffset(colr: []const u8, paint_off: usize, field_off: usize) ?usize {
    const rel = readOffset24(colr, paint_off + field_off) orelse return null;
    if (rel == 0) return null;
    const abs = paint_off + rel;
    if (abs >= colr.len) return null;
    return abs;
}

/// Decode one paint node at an absolute offset. Var formats read as
/// their non-var siblings (default instance; varIndexBase skipped).
pub fn readPaint(colr: []const u8, off: usize) error{Malformed}!Paint {
    if (off >= colr.len) return error.Malformed;
    const format = colr[off];
    switch (format) {
        1 => { // PaintColrLayers
            if (off + 6 > colr.len) return error.Malformed;
            return .{ .layers = .{
                .count = colr[off + 1],
                .first = readU32(colr, off + 2).?,
            } };
        },
        2, 3 => { // PaintSolid / PaintVarSolid
            if (off + 5 > colr.len) return error.Malformed;
            return .{ .solid = .{
                .palette = readU16(colr, off + 1).?,
                .alpha = readF2Dot14(colr, off + 3).?,
            } };
        },
        4, 5 => { // Paint(Var)LinearGradient
            if (off + 16 > colr.len) return error.Malformed;
            const cl = childOffset(colr, off, 1) orelse return error.Malformed;
            return .{ .linear = .{
                .color_line = .{ .off = cl, .var_stops = format == 5 },
                .x0 = readCoord(colr, off + 4).?,
                .y0 = readCoord(colr, off + 6).?,
                .x1 = readCoord(colr, off + 8).?,
                .y1 = readCoord(colr, off + 10).?,
                .x2 = readCoord(colr, off + 12).?,
                .y2 = readCoord(colr, off + 14).?,
            } };
        },
        6, 7 => { // Paint(Var)RadialGradient
            if (off + 16 > colr.len) return error.Malformed;
            const cl = childOffset(colr, off, 1) orelse return error.Malformed;
            return .{ .radial = .{
                .color_line = .{ .off = cl, .var_stops = format == 7 },
                .x0 = readCoord(colr, off + 4).?,
                .y0 = readCoord(colr, off + 6).?,
                .r0 = @floatFromInt(readU16(colr, off + 8).?),
                .x1 = readCoord(colr, off + 10).?,
                .y1 = readCoord(colr, off + 12).?,
                .r1 = @floatFromInt(readU16(colr, off + 14).?),
            } };
        },
        8, 9 => { // Paint(Var)SweepGradient
            if (off + 12 > colr.len) return error.Malformed;
            const cl = childOffset(colr, off, 1) orelse return error.Malformed;
            return .{ .sweep = .{
                .color_line = .{ .off = cl, .var_stops = format == 9 },
                .cx = readCoord(colr, off + 4).?,
                .cy = readCoord(colr, off + 6).?,
                .start_deg = readF2Dot14(colr, off + 8).? * 180.0 + 180.0,
                .end_deg = readF2Dot14(colr, off + 10).? * 180.0 + 180.0,
            } };
        },
        10 => { // PaintGlyph
            if (off + 6 > colr.len) return error.Malformed;
            const child = childOffset(colr, off, 1) orelse return error.Malformed;
            return .{ .glyph = .{ .child = child, .glyph_id = readU16(colr, off + 4).? } };
        },
        11 => { // PaintColrGlyph
            if (off + 3 > colr.len) return error.Malformed;
            return .{ .colr_glyph = .{ .glyph_id = readU16(colr, off + 1).? } };
        },
        12, 13 => { // Paint(Var)Transform — Affine2x3 of six Fixed
            if (off + 7 > colr.len) return error.Malformed;
            const child = childOffset(colr, off, 1) orelse return error.Malformed;
            const t = childOffset(colr, off, 4) orelse return error.Malformed;
            if (t + 24 > colr.len) return error.Malformed;
            return .{ .transform = .{ .child = child, .m = .{
                readFixed(colr, t).?, // xx
                readFixed(colr, t + 4).?, // yx
                readFixed(colr, t + 8).?, // xy
                readFixed(colr, t + 12).?, // yy
                readFixed(colr, t + 16).?, // dx
                readFixed(colr, t + 20).?, // dy
            } } };
        },
        14, 15 => { // Paint(Var)Translate
            if (off + 8 > colr.len) return error.Malformed;
            const child = childOffset(colr, off, 1) orelse return error.Malformed;
            return .{ .transform = .{ .child = child, .m = .{
                1, 0, 0, 1,
                readCoord(colr, off + 4).?,
                readCoord(colr, off + 6).?,
            } } };
        },
        16...23 => { // Paint(Var)Scale[Uniform][AroundCenter]
            const uniform = format >= 20;
            const around = format == 18 or format == 19 or format == 22 or format == 23;
            const scale_len: usize = if (uniform) 2 else 4;
            const need = 4 + scale_len + @as(usize, if (around) 4 else 0);
            if (off + need > colr.len) return error.Malformed;
            const child = childOffset(colr, off, 1) orelse return error.Malformed;
            const sx = readF2Dot14(colr, off + 4).?;
            const sy = if (uniform) sx else readF2Dot14(colr, off + 6).?;
            var cx: f32 = 0;
            var cy: f32 = 0;
            if (around) {
                cx = readCoord(colr, off + 4 + scale_len).?;
                cy = readCoord(colr, off + 6 + scale_len).?;
            }
            return .{ .transform = .{ .child = child, .m = .{
                sx, 0, 0, sy, cx - sx * cx, cy - sy * cy,
            } } };
        },
        24...27 => { // Paint(Var)Rotate[AroundCenter]
            const around = format >= 26;
            const need: usize = if (around) 10 else 6;
            if (off + need > colr.len) return error.Malformed;
            const child = childOffset(colr, off, 1) orelse return error.Malformed;
            const rad = readF2Dot14(colr, off + 4).? * std.math.pi;
            const cos_v = @cos(rad);
            const sin_v = @sin(rad);
            var cx: f32 = 0;
            var cy: f32 = 0;
            if (around) {
                cx = readCoord(colr, off + 6).?;
                cy = readCoord(colr, off + 8).?;
            }
            return .{ .transform = .{ .child = child, .m = .{
                cos_v,                        sin_v,
                -sin_v,                       cos_v,
                sin_v * cy + (1 - cos_v) * cx, -sin_v * cx + (1 - cos_v) * cy,
            } } };
        },
        28...31 => { // Paint(Var)Skew[AroundCenter]
            const around = format >= 30;
            const need: usize = if (around) 12 else 8;
            if (off + need > colr.len) return error.Malformed;
            const child = childOffset(colr, off, 1) orelse return error.Malformed;
            const tan_x = @tan(readF2Dot14(colr, off + 4).? * std.math.pi);
            const tan_y = @tan(readF2Dot14(colr, off + 6).? * std.math.pi);
            var cx: f32 = 0;
            var cy: f32 = 0;
            if (around) {
                cx = readCoord(colr, off + 8).?;
                cy = readCoord(colr, off + 10).?;
            }
            return .{ .transform = .{ .child = child, .m = .{
                1, tan_y, -tan_x, 1, tan_x * cy, -tan_y * cx,
            } } };
        },
        32 => { // PaintComposite
            if (off + 8 > colr.len) return error.Malformed;
            const source = childOffset(colr, off, 1) orelse return error.Malformed;
            const backdrop = childOffset(colr, off, 5) orelse return error.Malformed;
            return .{ .composite = .{
                .source = source,
                .mode = colr[off + 4],
                .backdrop = backdrop,
            } };
        },
        else => return error.Malformed,
    }
}

pub fn readColorLine(colr: []const u8, ref: ColorLineRef) error{Malformed}!ColorLine {
    if (ref.off + 3 > colr.len) return error.Malformed;
    const extend = colr[ref.off];
    if (extend > 2) return error.Malformed;
    const n_stops = readU16(colr, ref.off + 1).?;
    const stride: usize = if (ref.var_stops) 10 else 6;
    const stops_off = ref.off + 3;
    if (stops_off + @as(usize, n_stops) * stride > colr.len) return error.Malformed;
    return .{ .extend = extend, .n_stops = n_stops, .stops_off = stops_off, .stride = stride };
}

pub fn readStop(colr: []const u8, cl: ColorLine, i: usize) ColorStop {
    const off = cl.stops_off + i * cl.stride;
    return .{
        .offset = readF2Dot14(colr, off).?,
        .palette = readU16(colr, off + 2).?,
        .alpha = readF2Dot14(colr, off + 4).?,
    };
}

fn baseListFind(colr: []const u8, base_list: usize, n_base: u32, glyph_id: u16) ?usize {
    var i: usize = 0;
    while (i < n_base) : (i += 1) {
        const rec = base_list + 4 + i * 6;
        if (readU16(colr, rec).? == glyph_id) {
            const rel = readU32(colr, rec + 2).?;
            const abs = base_list + rel;
            if (rel == 0 or abs >= colr.len) return null;
            return abs;
        }
    }
    return null;
}

const Walk = struct {
    colr: []const u8,
    n_glyphs: usize,
    n_palette_entries: u16,
    base_list: usize,
    n_base: u32,
    layer_list: usize,
    n_layer_paints: u32,
    uses_fg: bool = false,
    budget: usize = MAX_V1_NODES,
    /// Offsets on the current root-to-leaf path (cycle detection —
    /// DAG sharing across siblings stays legal).
    stack: [MAX_V1_DEPTH]usize = undefined,

    fn checkPalette(self: *Walk, palette: u16) error{Malformed}!void {
        if (palette == PALETTE_FOREGROUND) {
            self.uses_fg = true;
            return;
        }
        if (palette >= self.n_palette_entries) return error.Malformed;
    }

    fn checkColorLine(self: *Walk, ref: ColorLineRef) error{Malformed}!void {
        const cl = try readColorLine(self.colr, ref);
        var i: usize = 0;
        while (i < cl.n_stops) : (i += 1) {
            try self.checkPalette(readStop(self.colr, cl, i).palette);
        }
    }

    /// Validate the subgraph at `off`; returns whether it is BOUNDED
    /// (paints within a finite region) per the spec's rules.
    fn walk(self: *Walk, off: usize, depth: usize) error{Malformed}!bool {
        if (depth >= MAX_V1_DEPTH) return error.Malformed;
        if (self.budget == 0) return error.Malformed;
        self.budget -= 1;
        for (self.stack[0..depth]) |seen| {
            if (seen == off) return error.Malformed; // true cycle
        }
        self.stack[depth] = off;
        switch (try readPaint(self.colr, off)) {
            .layers => |l| {
                if (@as(u64, l.first) + l.count > self.n_layer_paints) return error.Malformed;
                var bounded = true;
                var i: usize = 0;
                while (i < l.count) : (i += 1) {
                    const rec = self.layer_list + 4 + (@as(usize, l.first) + i) * 4;
                    const rel = readU32(self.colr, rec).?;
                    const abs = self.layer_list + rel;
                    if (rel == 0 or abs >= self.colr.len) return error.Malformed;
                    if (!try self.walk(abs, depth + 1)) bounded = false;
                }
                return bounded;
            },
            .solid => |s| {
                try self.checkPalette(s.palette);
                return false;
            },
            .linear => |g| {
                try self.checkColorLine(g.color_line);
                return false;
            },
            .radial => |g| {
                try self.checkColorLine(g.color_line);
                return false;
            },
            .sweep => |g| {
                try self.checkColorLine(g.color_line);
                return false;
            },
            .glyph => |g| {
                // Glyph ids index the container's carried outlines.
                if (g.glyph_id >= self.n_glyphs) return error.Malformed;
                _ = try self.walk(g.child, depth + 1);
                return true;
            },
            .colr_glyph => |g| {
                const root = baseListFind(self.colr, self.base_list, self.n_base, g.glyph_id) orelse
                    return error.Malformed;
                return self.walk(root, depth + 1);
            },
            .transform => |t| return self.walk(t.child, depth + 1),
            .composite => |cmp| {
                if (cmp.mode > MAX_COMPOSITE_MODE) return error.Malformed;
                const src = try self.walk(cmp.source, depth + 1);
                const back = try self.walk(cmp.backdrop, depth + 1);
                // Spec boundedness table (Porter-Duff region algebra):
                // CLEAR always; SRC/SRC_OUT source; DEST/DEST_OUT
                // backdrop; IN modes either; everything else both.
                return switch (cmp.mode) {
                    0 => true, // clear
                    1, 7 => src, // src, src_out
                    2, 8 => back, // dest, dest_out
                    5, 6 => src or back, // src_in, dest_in
                    9 => back, // src_atop confines to backdrop
                    10 => src, // dest_atop confines to source
                    else => src and back,
                };
            },
        }
    }
};

pub const Colr1DecodeError = error{ Malformed, OutOfMemory };

/// Decode AND validate a colrv1 container: framing, CPAL, the v1
/// header, and a full bounded walk of the base glyph's paint graph
/// (offsets, formats, indices, colour lines, cycles, composite
/// modes, boundedness). The base glyph is the BaseGlyphList record
/// for GlyphId 0, defensively the first record. A root that is
/// unbounded AND has no clip box is rejected — the spec forbids
/// rendering it, so accepting it would only cache an invisible glyph.
pub fn decodeColr1(allocator: std.mem.Allocator, data: []const u8) Colr1DecodeError!Colr1 {
    const cont = try splitContainer(allocator, data);
    const outlines = cont.outlines;
    errdefer allocator.free(outlines);
    const colr = cont.colr;
    const cpal = parseCpal(cont.cpal) catch return error.Malformed;

    // v1 header = the 14-byte v0 header + 5 Offset32s (base glyph
    // list, layer list, clip list, var index map, item variation
    // store). The v0 record fields may legally be zero.
    if (colr.len < 34) return error.Malformed;
    if (readU16(colr, 0).? != 1) return error.Malformed; // v0 table under fmt=colrv1
    const base_list: usize = readU32(colr, 14).?;
    const layer_list: usize = readU32(colr, 18).?;
    const clip_list: usize = readU32(colr, 22).?;

    if (base_list == 0 or base_list + 4 > colr.len) return error.Malformed;
    const n_base = readU32(colr, base_list).?;
    if (n_base == 0) return error.Malformed;
    if (base_list + 4 + @as(u64, n_base) * 6 > colr.len) return error.Malformed;

    var n_layer_paints: u32 = 0;
    if (layer_list != 0) {
        if (layer_list + 4 > colr.len) return error.Malformed;
        n_layer_paints = readU32(colr, layer_list).?;
        if (layer_list + 4 + @as(u64, n_layer_paints) * 4 > colr.len) return error.Malformed;
    }

    // Chosen base glyph: GlyphId 0, else the first record.
    var chosen: usize = 0;
    var bi: usize = 0;
    while (bi < n_base) : (bi += 1) {
        if (readU16(colr, base_list + 4 + bi * 6).? == 0) {
            chosen = bi;
            break;
        }
    }
    const root_glyph_id = readU16(colr, base_list + 4 + chosen * 6).?;
    const root_rel = readU32(colr, base_list + 4 + chosen * 6 + 2).?;
    const root_paint = base_list + root_rel;
    if (root_rel == 0 or root_paint >= colr.len) return error.Malformed;

    // ClipList (optional): format 1, u32 count, records of
    // {startGlyphID, endGlyphID, Offset24 clipBox} with offsets
    // relative to the ClipList start. Validated whole; only the
    // chosen base glyph's box is kept.
    var clip_box: ?ClipBox = null;
    if (clip_list != 0) {
        if (clip_list + 5 > colr.len) return error.Malformed;
        if (colr[clip_list] != 1) return error.Malformed;
        const n_clips = readU32(colr, clip_list + 1).?;
        if (clip_list + 5 + @as(u64, n_clips) * 7 > colr.len) return error.Malformed;
        var ci: usize = 0;
        while (ci < n_clips) : (ci += 1) {
            const rec = clip_list + 5 + ci * 7;
            const start_gid = readU16(colr, rec).?;
            const end_gid = readU16(colr, rec + 2).?;
            if (end_gid < start_gid) return error.Malformed;
            const box_rel = readOffset24(colr, rec + 4).?;
            const box_off = clip_list + box_rel;
            if (box_rel == 0 or box_off + 9 > colr.len) return error.Malformed;
            const box_format = colr[box_off];
            // Format 2 (var) adds a varIndexBase we ignore.
            if (box_format != 1 and box_format != 2) return error.Malformed;
            if (box_format == 2 and box_off + 13 > colr.len) return error.Malformed;
            if (root_glyph_id >= start_gid and root_glyph_id <= end_gid and clip_box == null) {
                clip_box = .{
                    .x_min = readI16(colr, box_off + 1).?,
                    .y_min = readI16(colr, box_off + 3).?,
                    .x_max = readI16(colr, box_off + 5).?,
                    .y_max = readI16(colr, box_off + 7).?,
                };
            }
        }
    }

    var w = Walk{
        .colr = colr,
        .n_glyphs = outlines.len,
        .n_palette_entries = cpal.n_entries,
        .base_list = base_list,
        .n_base = n_base,
        .layer_list = layer_list,
        .n_layer_paints = n_layer_paints,
    };
    const bounded = w.walk(root_paint, 0) catch return error.Malformed;
    if (!bounded and clip_box == null) return error.Malformed;

    return .{
        .outlines = outlines,
        .colr = colr,
        .cpal = cpal,
        .base_list = base_list,
        .n_base = n_base,
        .layer_list = layer_list,
        .n_layer_paints = n_layer_paints,
        .root_paint = root_paint,
        .clip_box = clip_box,
        .uses_fg = w.uses_fg,
    };
}

/// Register-time validation of a colrv1 container: `decodeColr1`
/// already walks the whole paint graph, so this only adds the carried
/// outlines through the glyf decoder (composite/hinted rejects keep
/// their own reason codes, exactly like colrv0).
pub fn validateColr1(allocator: std.mem.Allocator, data: []const u8) ?RegisterError {
    var c1 = decodeColr1(allocator, data) catch |err| return switch (err) {
        error.Malformed => .malformed_payload,
        error.OutOfMemory => .payload_too_large,
    };
    defer c1.deinit(allocator);
    for (c1.outlines) |o| {
        if (validateGlyf(allocator, o)) |reason| return reason;
    }
    return null;
}

// ── tests (ported from Rio's glyph_protocol.rs / glyf_decode.rs) ──

const testing = std.testing;

fn b64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(data.len));
    _ = enc.encode(out, data);
    return out;
}

fn parseFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Result {
    const body = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(body);
    return parse(allocator, body);
}

fn freeResult(allocator: std.mem.Allocator, res: Result) void {
    if (res == .register) allocator.free(res.register.payload);
}

test "rejects non-glyph-protocol bodies" {
    const a = testing.allocator;
    try testing.expectEqual(Result.not_glyph_protocol, parse(a, "G,a=T;payload"));
    try testing.expectEqual(Result.not_glyph_protocol, parse(a, ""));
}

test "isPua covers all three ranges and excludes text/emoji/noncharacters" {
    try testing.expect(isPua(0xE000));
    try testing.expect(isPua(0xE0A0));
    try testing.expect(isPua(0xF8FF));
    try testing.expect(isPua(0xF0000));
    try testing.expect(isPua(0xFFFFD));
    try testing.expect(isPua(0x100000));
    try testing.expect(isPua(0x10FFFD));
    try testing.expect(!isPua(0x61));
    try testing.expect(!isPua(0x2D));
    try testing.expect(!isPua(0x1F600));
    try testing.expect(!isPua(0xFFFE));
    try testing.expect(!isPua(0xFFFFE));
    try testing.expect(!isPua(0x10FFFF));
}

test "query: single codepoint, non-PUA allowed, sequences/surrogates rejected" {
    const a = testing.allocator;
    try testing.expectEqual(Result{ .query = 0xE0A0 }, parse(a, "25a1;q;cp=E0A0"));
    try testing.expectEqual(Result{ .query = 0x61 }, parse(a, "25a1;q;cp=61"));
    try testing.expectEqual(Result.malformed, parse(a, "25a1;q;cp=2D,3E"));
    try testing.expectEqual(Result.malformed, parse(a, "25a1;q;cp=D800"));
    try testing.expectEqual(Result.malformed, parse(a, "25a1;q;cp=110000"));
    try testing.expectEqual(Result.malformed, parse(a, "25a1;q"));
}

test "register: PUA codepoint with defaults" {
    const a = testing.allocator;
    const payload = try b64(a, &.{ 0x01, 0x02, 0x03 });
    defer a.free(payload);
    const res = try parseFmt(a, "25a1;r;cp=E0A0;upm=1000;{s}", .{payload});
    defer freeResult(a, res);
    try testing.expectEqual(@as(u32, 0xE0A0), res.register.cp);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03 }, res.register.payload);
    try testing.expectEqual(@as(u16, 1000), res.register.upm);
    try testing.expectEqual(ReplyMode.all, res.register.reply);
    try testing.expectEqual(@as(u8, 1), res.register.width);
}

test "register: upm defaults to 1000" {
    const a = testing.allocator;
    const payload = try b64(a, &.{0x01});
    defer a.free(payload);
    const res = try parseFmt(a, "25a1;r;cp=E0A0;{s}", .{payload});
    defer freeResult(a, res);
    try testing.expectEqual(@as(u16, 1000), res.register.upm);
}

test "register: width defaults narrow, accepts wide, rejects junk" {
    const a = testing.allocator;
    const payload = try b64(a, &.{0x01});
    defer a.free(payload);
    {
        const res = try parseFmt(a, "25a1;r;cp=E0A0;upm=1000;width=2;{s}", .{payload});
        defer freeResult(a, res);
        try testing.expectEqual(@as(u8, 2), res.register.width);
    }
    {
        const res = try parseFmt(a, "25a1;r;cp=E0A0;upm=1000;width=1;{s}", .{payload});
        defer freeResult(a, res);
        try testing.expectEqual(@as(u8, 1), res.register.width);
    }
    for ([_][]const u8{ "0", "3", "two", "" }) |bad| {
        const res = try parseFmt(a, "25a1;r;cp=E0A0;upm=1000;width={s};{s}", .{ bad, payload });
        defer freeResult(a, res);
        try testing.expectEqual(Result.malformed, res);
    }
}

test "register: each PUA range accepted" {
    const a = testing.allocator;
    const payload = try b64(a, "x");
    defer a.free(payload);
    for ([_]u32{ 0xE0A0, 0xF0000, 0x100000 }) |cp| {
        const res = try parseFmt(a, "25a1;r;cp={x};upm=1000;{s}", .{ cp, payload });
        defer freeResult(a, res);
        try testing.expectEqual(cp, res.register.cp);
    }
}

test "register: non-PUA cp rejected with out_of_namespace, reply propagated" {
    const a = testing.allocator;
    const payload = try b64(a, &.{0x01});
    defer a.free(payload);
    {
        const res = try parseFmt(a, "25a1;r;cp=61;upm=1000;{s}", .{payload});
        try testing.expectEqual(@as(u32, 0x61), res.register_failed.cp);
        try testing.expectEqual(RegisterError.out_of_namespace, res.register_failed.reason);
        try testing.expectEqual(ReplyMode.all, res.register_failed.reply);
    }
    {
        const res = try parseFmt(a, "25a1;r;cp=61;reply=0;upm=1000;{s}", .{payload});
        try testing.expectEqual(ReplyMode.none, res.register_failed.reply);
    }
}

test "register: missing cp / empty cp are malformed" {
    const a = testing.allocator;
    const payload = try b64(a, &.{0x01});
    defer a.free(payload);
    {
        const res = try parseFmt(a, "25a1;r;upm=1000;{s}", .{payload});
        try testing.expectEqual(Result.malformed, res);
    }
    {
        const res = try parseFmt(a, "25a1;r;cp=;upm=1000;{s}", .{payload});
        try testing.expectEqual(Result.malformed, res);
    }
}

test "register: unknown fmt dropped; all three supported formats parse" {
    const a = testing.allocator;
    const payload = try b64(a, "x");
    defer a.free(payload);
    for ([_][]const u8{ "svg", "colrv2", "COLRV0", "COLRV1" }) |fmt| {
        const res = try parseFmt(a, "25a1;r;cp=E0A0;fmt={s};upm=1000;{s}", .{ fmt, payload });
        try testing.expectEqual(Result.malformed, res);
    }
    {
        const ok = try parseFmt(a, "25a1;r;cp=E0A0;fmt=glyf;upm=1000;{s}", .{payload});
        defer freeResult(a, ok);
        try testing.expect(ok == .register);
        try testing.expectEqual(Format.glyf, ok.register.fmt);
    }
    {
        const ok = try parseFmt(a, "25a1;r;cp=E0A0;fmt=colrv0;upm=1000;{s}", .{payload});
        defer freeResult(a, ok);
        try testing.expect(ok == .register);
        try testing.expectEqual(Format.colrv0, ok.register.fmt);
    }
    {
        const ok = try parseFmt(a, "25a1;r;cp=E0A0;fmt=colrv1;upm=1000;{s}", .{payload});
        defer freeResult(a, ok);
        try testing.expect(ok == .register);
        try testing.expectEqual(Format.colrv1, ok.register.fmt);
    }
    {
        // Omitted fmt defaults to glyf.
        const ok = try parseFmt(a, "25a1;r;cp=E0A0;upm=1000;{s}", .{payload});
        defer freeResult(a, ok);
        try testing.expectEqual(Format.glyf, ok.register.fmt);
    }
}

test "register: bad base64 rejects malformed_payload" {
    const a = testing.allocator;
    const res = parse(a, "25a1;r;cp=E0A0;upm=1000;$$$$not_base64");
    try testing.expectEqual(RegisterError.malformed_payload, res.register_failed.reason);
}

test "register: oversized payload rejects payload_too_large" {
    const a = testing.allocator;
    const big = try a.alloc(u8, MAX_PAYLOAD_BYTES + 1);
    defer a.free(big);
    @memset(big, 0);
    const payload = try b64(a, big);
    defer a.free(payload);
    const res = try parseFmt(a, "25a1;r;cp=E0A0;upm=1000;{s}", .{payload});
    try testing.expectEqual(RegisterError.payload_too_large, res.register_failed.reason);
}

test "register: zero upm is malformed" {
    const a = testing.allocator;
    const payload = try b64(a, "x");
    defer a.free(payload);
    const res = try parseFmt(a, "25a1;r;cp=E0A0;upm=0;{s}", .{payload});
    try testing.expectEqual(Result.malformed, res);
}

test "register: empty payload and missing payload separator reject" {
    const a = testing.allocator;
    {
        const res = parse(a, "25a1;r;cp=E0A0;upm=1000;");
        try testing.expectEqual(@as(u32, 0xE0A0), res.register_failed.cp);
        try testing.expectEqual(RegisterError.malformed_payload, res.register_failed.reason);
    }
    {
        // No `;` between control and payload: the last-`;` split leaves
        // the payload segment holding `cp=E0A0` — not valid base64.
        const res = parse(a, "25a1;r;cp=E0A0");
        try testing.expectEqual(RegisterError.malformed_payload, res.register_failed.reason);
    }
}

test "register: cp above U+10FFFF is malformed" {
    const a = testing.allocator;
    const payload = try b64(a, "x");
    defer a.free(payload);
    for ([_][]const u8{ "110000", "FFFFFF" }) |cp| {
        const res = try parseFmt(a, "25a1;r;cp={s};upm=1000;{s}", .{ cp, payload });
        try testing.expectEqual(Result.malformed, res);
    }
}

test "register: reply levels 0/1/2, unknown values fall back to all" {
    const a = testing.allocator;
    const payload = try b64(a, &.{0x01});
    defer a.free(payload);
    const cases = [_]struct { raw: []const u8, want: ReplyMode }{
        .{ .raw = "0", .want = .none },
        .{ .raw = "1", .want = .all },
        .{ .raw = "2", .want = .errors_only },
        .{ .raw = "3", .want = .all },
        .{ .raw = "true", .want = .all },
        .{ .raw = "yes", .want = .all },
        .{ .raw = "01", .want = .all },
        .{ .raw = "", .want = .all },
    };
    for (cases) |case| {
        const res = try parseFmt(a, "25a1;r;cp=E0A0;reply={s};upm=1000;{s}", .{ case.raw, payload });
        defer freeResult(a, res);
        try testing.expectEqual(case.want, res.register.reply);
    }
}

test "reply mode emit matrix" {
    try testing.expect(ReplyMode.all.emitSuccess());
    try testing.expect(ReplyMode.all.emitError());
    try testing.expect(!ReplyMode.errors_only.emitSuccess());
    try testing.expect(ReplyMode.errors_only.emitError());
    try testing.expect(!ReplyMode.none.emitSuccess());
    try testing.expect(!ReplyMode.none.emitError());
}

test "clear: one slot, all, non-PUA, sequence" {
    const a = testing.allocator;
    try testing.expectEqual(Result{ .clear = 0xE0A0 }, parse(a, "25a1;c;cp=E0A0"));
    try testing.expectEqual(Result{ .clear = null }, parse(a, "25a1;c"));
    try testing.expectEqual(Result.clear_out_of_namespace, parse(a, "25a1;c;cp=61"));
    try testing.expectEqual(Result.clear_out_of_namespace, parse(a, "25a1;c;cp=1F600"));
    try testing.expectEqual(Result.malformed, parse(a, "25a1;c;cp=E0A0,E0A1"));
}

test "support: no params, unknown params ignored" {
    const a = testing.allocator;
    try testing.expectEqual(Result.support, parse(a, "25a1;s"));
    try testing.expectEqual(Result.support, parse(a, "25a1;s;future=1;anything=else"));
}

test "unknown verb is malformed; unknown params on query ignored" {
    const a = testing.allocator;
    try testing.expectEqual(Result.malformed, parse(a, "25a1;z;cp=0061"));
    try testing.expectEqual(Result{ .query = 0xE0A0 }, parse(a, "25a1;q;cp=E0A0;future=1"));
}

test "reply formatting matches Rio's wire strings" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("\x1b_25a1;s;fmt=glyf,colrv0,colrv1\x1b\\", fmtSupport(&buf));
    try testing.expectEqualStrings("\x1b_25a1;q;cp=e0a0;status=\x1b\\", fmtQuery(&buf, 0xE0A0, false, false));
    try testing.expectEqualStrings("\x1b_25a1;q;cp=e0a0;status=system\x1b\\", fmtQuery(&buf, 0xE0A0, true, false));
    try testing.expectEqualStrings("\x1b_25a1;q;cp=e0a0;status=glossary\x1b\\", fmtQuery(&buf, 0xE0A0, false, true));
    try testing.expectEqualStrings("\x1b_25a1;q;cp=e0a0;status=system,glossary\x1b\\", fmtQuery(&buf, 0xE0A0, true, true));
    try testing.expectEqualStrings("\x1b_25a1;r;cp=e0a0;status=0\x1b\\", fmtRegisterOk(&buf, 0xE0A0));
    try testing.expectEqualStrings("\x1b_25a1;r;cp=61;status=1;reason=out_of_namespace\x1b\\", fmtRegisterErr(&buf, 0x61, .out_of_namespace));
    try testing.expectEqualStrings("\x1b_25a1;r;cp=e0a0;status=1;reason=composite_unsupported\x1b\\", fmtRegisterErr(&buf, 0xE0A0, .composite_unsupported));
    try testing.expectEqualStrings("\x1b_25a1;c;cp=e0a0;status=0\x1b\\", fmtClearOk(&buf, 0xE0A0));
    try testing.expectEqualStrings("\x1b_25a1;c;status=0\x1b\\", fmtClearOk(&buf, null));
    try testing.expectEqualStrings("\x1b_25a1;c;status=1;reason=out_of_namespace\x1b\\", fmtClearErrOutOfNamespace(&buf));
}

// ── glyf decoder tests ───────────────────────────────────────────

/// Hand-encode a triangle: (500,900) (100,100) (900,100), all
/// on-curve, full 16-bit deltas (no short/same flags).
pub fn triangleBytes(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = struct {
        fn i16be(l: *std.ArrayList(u8), a: std.mem.Allocator, v: i16) !void {
            var tmp: [2]u8 = undefined;
            std.mem.writeInt(i16, &tmp, v, .big);
            try l.appendSlice(a, &tmp);
        }
        fn u16be(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
            var tmp: [2]u8 = undefined;
            std.mem.writeInt(u16, &tmp, v, .big);
            try l.appendSlice(a, &tmp);
        }
    };
    try w.i16be(&out, allocator, 1); // numberOfContours
    try w.i16be(&out, allocator, 100); // xMin
    try w.i16be(&out, allocator, 100); // yMin
    try w.i16be(&out, allocator, 900); // xMax
    try w.i16be(&out, allocator, 900); // yMax
    try w.u16be(&out, allocator, 2); // endPtsOfContours[0]
    try w.u16be(&out, allocator, 0); // instructionLength
    try out.appendSlice(allocator, &.{ FLAG_ON_CURVE, FLAG_ON_CURVE, FLAG_ON_CURVE });
    for ([_]i16{ 500, -400, 800 }) |dx| try w.i16be(&out, allocator, dx);
    for ([_]i16{ 900, -800, 0 }) |dy| try w.i16be(&out, allocator, dy);
    return out.toOwnedSlice(allocator);
}

test "glyf: decodes triangle" {
    const a = testing.allocator;
    const bytes = try triangleBytes(a);
    defer a.free(bytes);
    var out = try decodeGlyf(a, bytes);
    defer out.deinit(a);
    try testing.expectEqual(@as(usize, 1), out.ends.len);
    try testing.expectEqual(@as(u16, 2), out.ends[0]);
    try testing.expectEqual(@as(usize, 3), out.points.len);
    try testing.expectEqual(Point{ .x = 500, .y = 900, .on_curve = true }, out.points[0]);
    try testing.expectEqual(Point{ .x = 100, .y = 100, .on_curve = true }, out.points[1]);
    try testing.expectEqual(Point{ .x = 900, .y = 100, .on_curve = true }, out.points[2]);
    try testing.expectEqual(@as(i32, 100), out.x_min);
    try testing.expectEqual(@as(i32, 900), out.y_max);
}

test "glyf: rejects composite" {
    const a = testing.allocator;
    var v: [10]u8 = @splat(0);
    std.mem.writeInt(i16, v[0..2], -1, .big);
    try testing.expectError(error.Composite, decodeGlyf(a, &v));
}

test "glyf: rejects hinting" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(i16, &tmp, 1, .big);
    try out.appendSlice(a, &tmp); // numberOfContours
    try out.appendSlice(a, &(.{0} ** 8)); // bbox
    std.mem.writeInt(u16, &tmp, 0, .big);
    try out.appendSlice(a, &tmp); // endPtsOfContours[0] = 0
    std.mem.writeInt(u16, &tmp, 1, .big);
    try out.appendSlice(a, &tmp); // instructionLength = 1
    try out.append(a, 0x00); // one instruction byte
    try out.append(a, FLAG_ON_CURVE);
    std.mem.writeInt(i16, &tmp, 0, .big);
    try out.appendSlice(a, &tmp);
    try out.appendSlice(a, &tmp);
    try testing.expectError(error.Hinted, decodeGlyf(a, out.items));
}

test "glyf: truncation at every field boundary is malformed" {
    const a = testing.allocator;
    try testing.expectError(error.Malformed, decodeGlyf(a, &.{}));
    const bytes = try triangleBytes(a);
    defer a.free(bytes);
    // Every proper prefix of a valid record must fail cleanly (the
    // record has no trailing padding, so the only accepted length is
    // the full one).
    var cut: usize = 0;
    while (cut < bytes.len) : (cut += 1) {
        try testing.expectError(error.Malformed, decodeGlyf(a, bytes[0..cut]));
    }
}

test "glyf: handles repeat flag" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(i16, &tmp, 1, .big);
    try out.appendSlice(a, &tmp);
    try out.appendSlice(a, &(.{0} ** 8));
    std.mem.writeInt(u16, &tmp, 3, .big);
    try out.appendSlice(a, &tmp); // endPts
    std.mem.writeInt(u16, &tmp, 0, .big);
    try out.appendSlice(a, &tmp); // instr len
    try out.append(a, FLAG_ON_CURVE | FLAG_REPEAT);
    try out.append(a, 3); // 4 points total
    for ([_]i16{ 10, 10, 10, 10 }) |dx| {
        std.mem.writeInt(i16, &tmp, dx, .big);
        try out.appendSlice(a, &tmp);
    }
    for ([_]i16{ 0, 10, 0, -10 }) |dy| {
        std.mem.writeInt(i16, &tmp, dy, .big);
        try out.appendSlice(a, &tmp);
    }
    var got = try decodeGlyf(a, out.items);
    defer got.deinit(a);
    try testing.expectEqual(@as(usize, 4), got.points.len);
    try testing.expectEqual(@as(i32, 40), got.points[3].x);
    try testing.expectEqual(@as(i32, 0), got.points[3].y);
}

test "glyf: short/same coordinate encodings" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(i16, &tmp, 1, .big);
    try out.appendSlice(a, &tmp);
    try out.appendSlice(a, &(.{0} ** 8));
    std.mem.writeInt(u16, &tmp, 2, .big);
    try out.appendSlice(a, &tmp);
    std.mem.writeInt(u16, &tmp, 0, .big);
    try out.appendSlice(a, &tmp);
    // p0: x short positive, y same (delta 0)
    try out.append(a, FLAG_ON_CURVE | FLAG_X_SHORT | FLAG_X_SAME_OR_POS | FLAG_Y_SAME_OR_POS);
    // p1: x short negative, y short positive
    try out.append(a, FLAG_ON_CURVE | FLAG_X_SHORT | FLAG_Y_SHORT | FLAG_Y_SAME_OR_POS);
    // p2: x same, y full i16 negative
    try out.append(a, FLAG_ON_CURVE | FLAG_X_SAME_OR_POS);
    try out.append(a, 50); // p0 dx = +50
    try out.append(a, 20); // p1 dx = -20
    try out.append(a, 30); // p1 dy = +30
    std.mem.writeInt(i16, &tmp, -10, .big);
    try out.appendSlice(a, &tmp); // p2 dy
    var got = try decodeGlyf(a, out.items);
    defer got.deinit(a);
    try testing.expectEqual(@as(i32, 50), got.points[0].x);
    try testing.expectEqual(@as(i32, 0), got.points[0].y);
    try testing.expectEqual(@as(i32, 30), got.points[1].x);
    try testing.expectEqual(@as(i32, 30), got.points[1].y);
    try testing.expectEqual(@as(i32, 30), got.points[2].x);
    try testing.expectEqual(@as(i32, 20), got.points[2].y);
}

test "glyf: implied-midpoint contours keep off-curve flags" {
    // on, off, off, on — adjacent off-curves imply an on-curve
    // midpoint. The decoder preserves the raw flags; the implied
    // point is the rasteriser's job (FreeType handles it natively).
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(i16, &tmp, 1, .big);
    try out.appendSlice(a, &tmp);
    try out.appendSlice(a, &(.{0} ** 8));
    std.mem.writeInt(u16, &tmp, 3, .big);
    try out.appendSlice(a, &tmp);
    std.mem.writeInt(u16, &tmp, 0, .big);
    try out.appendSlice(a, &tmp);
    try out.append(a, FLAG_ON_CURVE);
    try out.append(a, 0);
    try out.append(a, 0);
    try out.append(a, FLAG_ON_CURVE);
    for ([_]i16{ 0, 100, 100, 0 }) |dx| {
        std.mem.writeInt(i16, &tmp, dx, .big);
        try out.appendSlice(a, &tmp);
    }
    for ([_]i16{ 0, 100, -100, -100 }) |dy| {
        std.mem.writeInt(i16, &tmp, dy, .big);
        try out.appendSlice(a, &tmp);
    }
    var got = try decodeGlyf(a, out.items);
    defer got.deinit(a);
    try testing.expect(got.points[0].on_curve);
    try testing.expect(!got.points[1].on_curve);
    try testing.expect(!got.points[2].on_curve);
    try testing.expect(got.points[3].on_curve);
}

test "glyf: non-increasing contour ends and repeat overflow are malformed" {
    const a = testing.allocator;
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(i16, &tmp, 2, .big);
        try out.appendSlice(a, &tmp);
        try out.appendSlice(a, &(.{0} ** 8));
        std.mem.writeInt(u16, &tmp, 3, .big);
        try out.appendSlice(a, &tmp);
        std.mem.writeInt(u16, &tmp, 3, .big); // equal — not increasing
        try out.appendSlice(a, &tmp);
        std.mem.writeInt(u16, &tmp, 0, .big);
        try out.appendSlice(a, &tmp);
        try testing.expectError(error.Malformed, decodeGlyf(a, out.items));
    }
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(i16, &tmp, 1, .big);
        try out.appendSlice(a, &tmp);
        try out.appendSlice(a, &(.{0} ** 8));
        std.mem.writeInt(u16, &tmp, 1, .big); // 2 points
        try out.appendSlice(a, &tmp);
        std.mem.writeInt(u16, &tmp, 0, .big);
        try out.appendSlice(a, &tmp);
        try out.append(a, FLAG_ON_CURVE | FLAG_REPEAT);
        try out.append(a, 5); // repeat past n_points
        try testing.expectError(error.Malformed, decodeGlyf(a, out.items));
    }
}

// ── colrv0 container tests ───────────────────────────────────────

/// Test/smoke builder for a well-formed colrv0 container: one base
/// record for GlyphId 0 covering all `layers`, CPAL palette 0 with
/// `palette_colors` straight-RGBA entries (empty slice = cpal_len 0).
pub fn colrContainerBytes(
    allocator: std.mem.Allocator,
    outlines: []const []const u8,
    layers: []const struct { glyph: u16, palette: u16 },
    palette_colors: []const u32,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = struct {
        fn u16be(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
            var tmp: [2]u8 = undefined;
            std.mem.writeInt(u16, &tmp, v, .big);
            try l.appendSlice(a, &tmp);
        }
        fn u32be(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, v, .big);
            try l.appendSlice(a, &tmp);
        }
    };
    try w.u16be(&out, allocator, @intCast(outlines.len));
    for (outlines) |o| {
        try w.u16be(&out, allocator, @intCast(o.len));
        try out.appendSlice(allocator, o);
    }
    // COLR v0: header(14) + 1 base record(6) + layer records.
    const colr_len: u16 = @intCast(14 + 6 + layers.len * 4);
    try w.u16be(&out, allocator, colr_len);
    try w.u16be(&out, allocator, 0); // version
    try w.u16be(&out, allocator, 1); // numBaseGlyphRecords
    try w.u32be(&out, allocator, 14); // baseGlyphRecordsOffset
    try w.u32be(&out, allocator, 20); // layerRecordsOffset
    try w.u16be(&out, allocator, @intCast(layers.len));
    try w.u16be(&out, allocator, 0); // base GlyphId
    try w.u16be(&out, allocator, 0); // firstLayerIndex
    try w.u16be(&out, allocator, @intCast(layers.len));
    for (layers) |l| {
        try w.u16be(&out, allocator, l.glyph);
        try w.u16be(&out, allocator, l.palette);
    }
    // CPAL v0: header(12) + 1 index(2) + BGRA records.
    if (palette_colors.len == 0) {
        try w.u16be(&out, allocator, 0);
    } else {
        const cpal_len: u16 = @intCast(12 + 2 + palette_colors.len * 4);
        try w.u16be(&out, allocator, cpal_len);
        try w.u16be(&out, allocator, 0); // version
        try w.u16be(&out, allocator, @intCast(palette_colors.len)); // numPaletteEntries
        try w.u16be(&out, allocator, 1); // numPalettes
        try w.u16be(&out, allocator, @intCast(palette_colors.len)); // numColorRecords
        try w.u32be(&out, allocator, 14); // colorRecordsArrayOffset
        try w.u16be(&out, allocator, 0); // colorRecordIndices[0]
        for (palette_colors) |rgba| {
            try out.append(allocator, @truncate(rgba >> 8)); // B
            try out.append(allocator, @truncate(rgba >> 16)); // G
            try out.append(allocator, @truncate(rgba >> 24)); // R
            try out.append(allocator, @truncate(rgba)); // A
        }
    }
    return out.toOwnedSlice(allocator);
}

test "colrv0: decodes a two-layer container with resolved palette colours" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    const bytes = try colrContainerBytes(a, &.{ tri, tri }, &.{
        .{ .glyph = 0, .palette = 0 },
        .{ .glyph = 1, .palette = 1 },
    }, &.{ 0xFF0000FF, 0x00FF00FF });
    defer a.free(bytes);
    var colr = try decodeColr(a, bytes);
    defer colr.deinit(a);
    try testing.expectEqual(@as(usize, 2), colr.outlines.len);
    try testing.expectEqualSlices(u8, tri, colr.outlines[0]);
    try testing.expectEqual(@as(usize, 2), colr.layers.len);
    try testing.expectEqual(@as(u32, 0xFF0000FF), colr.layers[0].rgba);
    try testing.expectEqual(@as(u32, 0x00FF00FF), colr.layers[1].rgba);
    try testing.expect(!colr.uses_fg);
    try testing.expectEqual(@as(?RegisterError, null), validateColr(a, bytes));
}

test "colrv0: 0xFFFF palette resolves as foreground, empty CPAL accepted" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    const bytes = try colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = PALETTE_FOREGROUND },
    }, &.{});
    defer a.free(bytes);
    var colr = try decodeColr(a, bytes);
    defer colr.deinit(a);
    try testing.expect(colr.uses_fg);
    try testing.expect(colr.layers[0].is_fg);
    try testing.expectEqual(@as(?RegisterError, null), validateColr(a, bytes));
    try testing.expect(colrUsesForeground(a, .colrv0, bytes));
}

test "colrv0: n_glyphs bounds" {
    const a = testing.allocator;
    // n_glyphs = 0.
    try testing.expectError(error.Malformed, decodeColr(a, &.{ 0, 0 }));
    // n_glyphs = 1025 (over MAX_COLR_GLYPHS) — truncation would also
    // fail, but the bound must reject before reading records.
    var big: [2]u8 = undefined;
    std.mem.writeInt(u16, &big, 1025, .big);
    try testing.expectError(error.Malformed, decodeColr(a, &big));
}

test "colrv0: truncation at every byte boundary is malformed" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    const bytes = try colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = 0 },
    }, &.{0x336699FF});
    defer a.free(bytes);
    var cut: usize = 0;
    while (cut < bytes.len) : (cut += 1) {
        try testing.expectError(error.Malformed, decodeColr(a, bytes[0..cut]));
    }
}

test "colrv0: trailing bytes rejected" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    const bytes = try colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = 0 },
    }, &.{0x336699FF});
    defer a.free(bytes);
    const padded = try std.mem.concat(a, u8, &.{ bytes, &.{0x00} });
    defer a.free(padded);
    try testing.expectError(error.Malformed, decodeColr(a, padded));
}

test "colrv0: zero-length COLR rejected" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(u16, &tmp, 1, .big);
    try out.appendSlice(a, &tmp); // n_glyphs
    std.mem.writeInt(u16, &tmp, @intCast(tri.len), .big);
    try out.appendSlice(a, &tmp);
    try out.appendSlice(a, tri);
    std.mem.writeInt(u16, &tmp, 0, .big);
    try out.appendSlice(a, &tmp); // colr_len = 0
    try out.appendSlice(a, &tmp); // cpal_len = 0
    try testing.expectError(error.Malformed, decodeColr(a, out.items));
}

test "colrv0: layer glyph id / palette index out of range rejected" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    {
        const bytes = try colrContainerBytes(a, &.{tri}, &.{
            .{ .glyph = 1, .palette = 0 }, // only outline 0 exists
        }, &.{0x336699FF});
        defer a.free(bytes);
        try testing.expectError(error.Malformed, decodeColr(a, bytes));
        try testing.expectEqual(RegisterError.malformed_payload, validateColr(a, bytes).?);
    }
    {
        const bytes = try colrContainerBytes(a, &.{tri}, &.{
            .{ .glyph = 0, .palette = 1 }, // palette 0 has one entry
        }, &.{0x336699FF});
        defer a.free(bytes);
        try testing.expectError(error.Malformed, decodeColr(a, bytes));
    }
    {
        // Non-sentinel palette index with NO CPAL at all.
        const bytes = try colrContainerBytes(a, &.{tri}, &.{
            .{ .glyph = 0, .palette = 0 },
        }, &.{});
        defer a.free(bytes);
        try testing.expectError(error.Malformed, decodeColr(a, bytes));
    }
}

test "colrv0: carried composite / hinted glyph rejected through the glyf decoder" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    var comp: [10]u8 = @splat(0);
    std.mem.writeInt(i16, comp[0..2], -1, .big);
    {
        const bytes = try colrContainerBytes(a, &.{ tri, &comp }, &.{
            .{ .glyph = 0, .palette = PALETTE_FOREGROUND },
        }, &.{});
        defer a.free(bytes);
        // Container structure is fine (glyph 1 unreferenced), but the
        // carried composite must still be rejected at register time.
        try testing.expectEqual(RegisterError.composite_unsupported, validateColr(a, bytes).?);
    }
    {
        // Hinted glyph: 1 contour, 1 point, instructionLength 1.
        var hinted: std.ArrayList(u8) = .empty;
        defer hinted.deinit(a);
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(i16, &tmp, 1, .big);
        try hinted.appendSlice(a, &tmp);
        try hinted.appendSlice(a, &(.{0} ** 8));
        std.mem.writeInt(u16, &tmp, 0, .big);
        try hinted.appendSlice(a, &tmp); // endPts
        std.mem.writeInt(u16, &tmp, 1, .big);
        try hinted.appendSlice(a, &tmp); // instr len
        try hinted.append(a, 0);
        try hinted.append(a, FLAG_ON_CURVE);
        std.mem.writeInt(i16, &tmp, 0, .big);
        try hinted.appendSlice(a, &tmp);
        try hinted.appendSlice(a, &tmp);
        const bytes = try colrContainerBytes(a, &.{hinted.items}, &.{
            .{ .glyph = 0, .palette = PALETTE_FOREGROUND },
        }, &.{});
        defer a.free(bytes);
        try testing.expectEqual(RegisterError.hinting_unsupported, validateColr(a, bytes).?);
    }
}

test "colrv0: COLR v1 table under fmt=colrv0 is malformed" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    const bytes = try colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = PALETTE_FOREGROUND },
    }, &.{});
    defer a.free(bytes);
    const mut = try a.dupe(u8, bytes);
    defer a.free(mut);
    // COLR version field sits right after the container's colr_len:
    // 2 (n_glyphs) + 2 + tri.len (outline) + 2 (colr_len).
    const colr_start = 2 + 2 + tri.len + 2;
    std.mem.writeInt(u16, mut[colr_start..][0..2], 1, .big);
    try testing.expectError(error.Malformed, decodeColr(a, mut));
}

test "validatePayload dispatches by format" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    try testing.expectEqual(@as(?RegisterError, null), validatePayload(a, .glyf, tri));
    // A glyf record is not a container...
    try testing.expect(validatePayload(a, .colrv0, tri) != null);
    const bytes = try colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = PALETTE_FOREGROUND },
    }, &.{});
    defer a.free(bytes);
    try testing.expectEqual(@as(?RegisterError, null), validatePayload(a, .colrv0, bytes));
    // ...and a container is not a glyf record.
    try testing.expect(validatePayload(a, .glyf, bytes) != null);
}

// ── colrv1 test/smoke container builder ──────────────────────────

pub const V1Stop = struct { offset: f32, palette: u16, alpha: f32 = 1.0 };

/// Declarative paint-graph node for building test containers.
/// `rotate` takes the raw F2Dot14 value (×180° per the spec).
pub const V1Node = union(enum) {
    layers: []const V1Node,
    solid: struct { palette: u16, alpha: f32 = 1.0 },
    linear: struct { extend: u8 = 0, stops: []const V1Stop, x0: i16, y0: i16, x1: i16, y1: i16, x2: i16, y2: i16 },
    radial: struct { extend: u8 = 0, stops: []const V1Stop, x0: i16, y0: i16, r0: u16, x1: i16, y1: i16, r1: u16 },
    sweep: struct { extend: u8 = 0, stops: []const V1Stop, cx: i16 = 0, cy: i16 = 0, start: f32 = 0, end: f32 = 1 },
    glyph: struct { glyph_id: u16, child: *const V1Node },
    colr_glyph: struct { glyph_id: u16 },
    transform: struct { m: [6]f32, child: *const V1Node },
    rotate: struct { angle: f32, child: *const V1Node },
    composite: struct { source: *const V1Node, mode: u8, backdrop: *const V1Node },
};

fn v1CountLayers(node: *const V1Node) usize {
    return switch (node.*) {
        .layers => |ch| blk: {
            var n: usize = ch.len;
            for (ch) |*sub| n += v1CountLayers(sub);
            break :blk n;
        },
        .glyph => |g| v1CountLayers(g.child),
        .transform => |t| v1CountLayers(t.child),
        .rotate => |r| v1CountLayers(r.child),
        .composite => |cmp| v1CountLayers(cmp.source) + v1CountLayers(cmp.backdrop),
        else => 0,
    };
}

const V1Emit = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    /// LayerList Offset32 slots (relative to LayerList start),
    /// assigned in reservation order.
    layer_slots: []u32,
    next_slot: usize = 0,
    /// Absolute COLR-table offset where the paint region begins.
    region_base: usize,
    layer_list_off: usize,

    fn u8w(self: *V1Emit, v: u8) !void {
        try self.buf.append(self.allocator, v);
    }
    fn u16w(self: *V1Emit, v: u16) !void {
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(u16, &tmp, v, .big);
        try self.buf.appendSlice(self.allocator, &tmp);
    }
    fn i16w(self: *V1Emit, v: i16) !void {
        try self.u16w(@bitCast(v));
    }
    fn f2dot14(self: *V1Emit, v: f32) !void {
        try self.i16w(@intFromFloat(@round(v * 16384.0)));
    }
    fn fixed(self: *V1Emit, v: f32) !void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(i32, &tmp, @intFromFloat(@round(v * 65536.0)), .big);
        try self.buf.appendSlice(self.allocator, &tmp);
    }
    fn off24Placeholder(self: *V1Emit) !void {
        try self.buf.appendSlice(self.allocator, &.{ 0, 0, 0 });
    }
    fn patch24(self: *V1Emit, at: usize, v: usize) void {
        self.buf.items[at] = @truncate(v >> 16);
        self.buf.items[at + 1] = @truncate(v >> 8);
        self.buf.items[at + 2] = @truncate(v);
    }

    fn colorLine(self: *V1Emit, extend: u8, stops: []const V1Stop) !void {
        try self.u8w(extend);
        try self.u16w(@intCast(stops.len));
        for (stops) |s| {
            try self.f2dot14(s.offset);
            try self.u16w(s.palette);
            try self.f2dot14(s.alpha);
        }
    }

    /// Serialize `node` at the current end; returns its start offset
    /// within the paint region. Children land after their parent so
    /// unsigned Offset24s always work.
    fn emit(self: *V1Emit, node: *const V1Node) !usize {
        const start = self.buf.items.len;
        switch (node.*) {
            .layers => |children| {
                try self.u8w(1);
                try self.u8w(@intCast(children.len));
                var tmp: [4]u8 = undefined;
                std.mem.writeInt(u32, &tmp, @intCast(self.next_slot), .big);
                try self.buf.appendSlice(self.allocator, &tmp);
                const first = self.next_slot;
                self.next_slot += children.len;
                for (children, 0..) |*child, i| {
                    const child_start = try self.emit(child);
                    self.layer_slots[first + i] =
                        @intCast(self.region_base + child_start - self.layer_list_off);
                }
            },
            .solid => |s| {
                try self.u8w(2);
                try self.u16w(s.palette);
                try self.f2dot14(s.alpha);
            },
            .linear => |g| {
                try self.u8w(4);
                try self.off24Placeholder();
                try self.i16w(g.x0);
                try self.i16w(g.y0);
                try self.i16w(g.x1);
                try self.i16w(g.y1);
                try self.i16w(g.x2);
                try self.i16w(g.y2);
                self.patch24(start + 1, self.buf.items.len - start);
                try self.colorLine(g.extend, g.stops);
            },
            .radial => |g| {
                try self.u8w(6);
                try self.off24Placeholder();
                try self.i16w(g.x0);
                try self.i16w(g.y0);
                try self.u16w(g.r0);
                try self.i16w(g.x1);
                try self.i16w(g.y1);
                try self.u16w(g.r1);
                self.patch24(start + 1, self.buf.items.len - start);
                try self.colorLine(g.extend, g.stops);
            },
            .sweep => |g| {
                try self.u8w(8);
                try self.off24Placeholder();
                try self.i16w(g.cx);
                try self.i16w(g.cy);
                try self.f2dot14(g.start);
                try self.f2dot14(g.end);
                self.patch24(start + 1, self.buf.items.len - start);
                try self.colorLine(g.extend, g.stops);
            },
            .glyph => |g| {
                try self.u8w(10);
                try self.off24Placeholder();
                try self.u16w(g.glyph_id);
                const child_start = try self.emit(g.child);
                self.patch24(start + 1, child_start - start);
            },
            .colr_glyph => |g| {
                try self.u8w(11);
                try self.u16w(g.glyph_id);
            },
            .transform => |t| {
                try self.u8w(12);
                try self.off24Placeholder(); // paint
                try self.off24Placeholder(); // transform
                self.patch24(start + 4, self.buf.items.len - start);
                for (t.m) |v| try self.fixed(v);
                const child_start = try self.emit(t.child);
                self.patch24(start + 1, child_start - start);
            },
            .rotate => |r| {
                try self.u8w(24);
                try self.off24Placeholder();
                try self.f2dot14(r.angle);
                const child_start = try self.emit(r.child);
                self.patch24(start + 1, child_start - start);
            },
            .composite => |cmp| {
                try self.u8w(32);
                try self.off24Placeholder(); // source
                try self.u8w(cmp.mode);
                try self.off24Placeholder(); // backdrop
                const src_start = try self.emit(cmp.source);
                const back_start = try self.emit(cmp.backdrop);
                self.patch24(start + 1, src_start - start);
                self.patch24(start + 5, back_start - start);
            },
        }
        return start;
    }
};

/// Test/smoke builder for a colrv1 container: one BaseGlyphPaint
/// record for GlyphId 0 rooted at `root`, CPAL palette 0 with
/// straight-RGBA `palette_colors` (empty = cpal_len 0), optional
/// clip box `{x_min, y_min, x_max, y_max}` covering every glyph id.
pub fn colr1ContainerBytes(
    allocator: std.mem.Allocator,
    outlines: []const []const u8,
    root: V1Node,
    palette_colors: []const u32,
    clip_box: ?[4]i16,
) ![]u8 {
    const n_layers = v1CountLayers(&root);
    const base_list_off: usize = 34;
    const layer_list_off: usize = if (n_layers > 0) 44 else 0;
    const layer_list_size: usize = if (n_layers > 0) 4 + 4 * n_layers else 0;
    const clip_off: usize = if (clip_box != null) 44 + layer_list_size else 0;
    const clip_size: usize = if (clip_box != null) 5 + 7 + 9 else 0;
    const region_base: usize = 44 + layer_list_size + clip_size;

    const layer_slots = try allocator.alloc(u32, n_layers);
    defer allocator.free(layer_slots);
    var emitter = V1Emit{
        .allocator = allocator,
        .layer_slots = layer_slots,
        .region_base = region_base,
        .layer_list_off = layer_list_off,
    };
    defer emitter.buf.deinit(allocator);
    const root_start = try emitter.emit(&root);

    var colr: std.ArrayList(u8) = .empty;
    defer colr.deinit(allocator);
    const w = struct {
        fn u16be(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
            var tmp: [2]u8 = undefined;
            std.mem.writeInt(u16, &tmp, v, .big);
            try l.appendSlice(a, &tmp);
        }
        fn u32be(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, v, .big);
            try l.appendSlice(a, &tmp);
        }
        fn i16be(l: *std.ArrayList(u8), a: std.mem.Allocator, v: i16) !void {
            try u16be(l, a, @bitCast(v));
        }
        fn u24be(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
            try l.appendSlice(a, &.{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) });
        }
    };
    // v1 header: v0 part zeroed, then the five Offset32s.
    try w.u16be(&colr, allocator, 1); // version
    try w.u16be(&colr, allocator, 0); // numBaseGlyphRecords
    try w.u32be(&colr, allocator, 0); // baseGlyphRecordsOffset
    try w.u32be(&colr, allocator, 0); // layerRecordsOffset
    try w.u16be(&colr, allocator, 0); // numLayerRecords
    try w.u32be(&colr, allocator, @intCast(base_list_off));
    try w.u32be(&colr, allocator, @intCast(layer_list_off));
    try w.u32be(&colr, allocator, @intCast(clip_off));
    try w.u32be(&colr, allocator, 0); // varIndexMapOffset
    try w.u32be(&colr, allocator, 0); // itemVariationStoreOffset
    // BaseGlyphList: one record for GlyphId 0.
    try w.u32be(&colr, allocator, 1);
    try w.u16be(&colr, allocator, 0);
    try w.u32be(&colr, allocator, @intCast(region_base + root_start - base_list_off));
    if (n_layers > 0) {
        try w.u32be(&colr, allocator, @intCast(n_layers));
        for (layer_slots) |slot| try w.u32be(&colr, allocator, slot);
    }
    if (clip_box) |box| {
        try colr.append(allocator, 1); // ClipList format
        try w.u32be(&colr, allocator, 1); // numClips
        try w.u16be(&colr, allocator, 0); // startGlyphID
        try w.u16be(&colr, allocator, 0xFFFE); // endGlyphID
        try w.u24be(&colr, allocator, 12); // clipBoxOffset (rel ClipList)
        try colr.append(allocator, 1); // ClipBox format
        for (box) |v| try w.i16be(&colr, allocator, v);
    }
    try colr.appendSlice(allocator, emitter.buf.items);

    // Container framing + CPAL, same shape as colrContainerBytes.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try w.u16be(&out, allocator, @intCast(outlines.len));
    for (outlines) |o| {
        try w.u16be(&out, allocator, @intCast(o.len));
        try out.appendSlice(allocator, o);
    }
    try w.u16be(&out, allocator, @intCast(colr.items.len));
    try out.appendSlice(allocator, colr.items);
    if (palette_colors.len == 0) {
        try w.u16be(&out, allocator, 0);
    } else {
        const cpal_len: u16 = @intCast(12 + 2 + palette_colors.len * 4);
        try w.u16be(&out, allocator, cpal_len);
        try w.u16be(&out, allocator, 0); // version
        try w.u16be(&out, allocator, @intCast(palette_colors.len)); // numPaletteEntries
        try w.u16be(&out, allocator, 1); // numPalettes
        try w.u16be(&out, allocator, @intCast(palette_colors.len)); // numColorRecords
        try w.u32be(&out, allocator, 14); // colorRecordsArrayOffset
        try w.u16be(&out, allocator, 0); // colorRecordIndices[0]
        for (palette_colors) |rgba| {
            try out.append(allocator, @truncate(rgba >> 8)); // B
            try out.append(allocator, @truncate(rgba >> 16)); // G
            try out.append(allocator, @truncate(rgba >> 24)); // R
            try out.append(allocator, @truncate(rgba)); // A
        }
    }
    return out.toOwnedSlice(allocator);
}

// ── colrv1 tests ─────────────────────────────────────────────────

test "colrv1: solid-under-glyph container decodes; fg detection walks the graph" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    // The 0xFFFF sentinel sits DEEP: glyph → rotate → solid. A layer-
    // list-only scan would miss it.
    const solid = V1Node{ .solid = .{ .palette = PALETTE_FOREGROUND } };
    const rot = V1Node{ .rotate = .{ .angle = 0.25, .child = &solid } };
    const bytes = try colr1ContainerBytes(a, &.{tri}, .{
        .glyph = .{ .glyph_id = 0, .child = &rot },
    }, &.{}, null);
    defer a.free(bytes);
    var c1 = try decodeColr1(a, bytes);
    defer c1.deinit(a);
    try testing.expect(c1.uses_fg);
    try testing.expectEqual(@as(?RegisterError, null), validateColr1(a, bytes));
    try testing.expect(colrUsesForeground(a, .colrv1, bytes));
    // A fixed-palette variant is foreground-independent.
    const solid2 = V1Node{ .solid = .{ .palette = 0 } };
    const bytes2 = try colr1ContainerBytes(a, &.{tri}, .{
        .glyph = .{ .glyph_id = 0, .child = &solid2 },
    }, &.{0xFF0000FF}, null);
    defer a.free(bytes2);
    var c2 = try decodeColr1(a, bytes2);
    defer c2.deinit(a);
    try testing.expect(!c2.uses_fg);
}

test "colrv1: readPaint decodes gradients, layers, transforms, composite" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    const stops = [_]V1Stop{
        .{ .offset = 0.0, .palette = 0 },
        .{ .offset = 1.0, .palette = 1 },
    };
    const lin = V1Node{ .linear = .{ .stops = &stops, .x0 = 0, .y0 = 0, .x1 = 1000, .y1 = 0, .x2 = 0, .y2 = 1000 } };
    const g_lin = V1Node{ .glyph = .{ .glyph_id = 0, .child = &lin } };
    const rad = V1Node{ .radial = .{ .extend = 2, .stops = &stops, .x0 = 500, .y0 = 500, .r0 = 0, .x1 = 500, .y1 = 500, .r1 = 400 } };
    const g_rad = V1Node{ .glyph = .{ .glyph_id = 0, .child = &rad } };
    const cmp = V1Node{ .composite = .{ .source = &g_lin, .mode = 12, .backdrop = &g_rad } };
    const bytes = try colr1ContainerBytes(a, &.{tri}, .{ .layers = &.{cmp} }, &.{ 0xFF0000FF, 0x0000FFFF }, null);
    defer a.free(bytes);
    var c1 = try decodeColr1(a, bytes);
    defer c1.deinit(a);
    const root = try readPaint(c1.colr, c1.root_paint);
    try testing.expect(root == .layers);
    try testing.expectEqual(@as(u8, 1), root.layers.count);
    try testing.expect(!c1.uses_fg);
    try testing.expectEqual(@as(?RegisterError, null), validateColr1(a, bytes));
    // Walk down: layer 0 is the composite.
    const rec = c1.layer_list + 4;
    const rel = std.mem.readInt(u32, c1.colr[rec..][0..4], .big);
    const cmp_paint = try readPaint(c1.colr, c1.layer_list + rel);
    try testing.expect(cmp_paint == .composite);
    try testing.expectEqual(@as(u8, 12), cmp_paint.composite.mode);
    const src = try readPaint(c1.colr, cmp_paint.composite.source);
    try testing.expect(src == .glyph);
    const src_lin = try readPaint(c1.colr, src.glyph.child);
    try testing.expect(src_lin == .linear);
    try testing.expectEqual(@as(f32, 1000), src_lin.linear.x1);
    const cl = try readColorLine(c1.colr, src_lin.linear.color_line);
    try testing.expectEqual(@as(u16, 2), cl.n_stops);
    try testing.expectEqual(@as(u16, 1), readStop(c1.colr, cl, 1).palette);
    const back = try readPaint(c1.colr, cmp_paint.composite.backdrop);
    const back_rad = try readPaint(c1.colr, back.glyph.child);
    try testing.expect(back_rad == .radial);
    try testing.expectEqual(@as(f32, 400), back_rad.radial.r1);
    const rcl = try readColorLine(c1.colr, back_rad.radial.color_line);
    try testing.expectEqual(@as(u8, 2), rcl.extend);
}

test "colrv1: transform matrices fold with spec signs" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    const solid = V1Node{ .solid = .{ .palette = PALETTE_FOREGROUND } };
    const g = V1Node{ .glyph = .{ .glyph_id = 0, .child = &solid } };
    // 90° counter-clockwise (F2Dot14 0.5 × 180°).
    const bytes = try colr1ContainerBytes(a, &.{tri}, .{
        .rotate = .{ .angle = 0.5, .child = &g },
    }, &.{}, null);
    defer a.free(bytes);
    var c1 = try decodeColr1(a, bytes);
    defer c1.deinit(a);
    const p = try readPaint(c1.colr, c1.root_paint);
    try testing.expect(p == .transform);
    const m = p.transform.m;
    try testing.expectApproxEqAbs(@as(f32, 0), m[0], 1e-4); // cos 90
    try testing.expectApproxEqAbs(@as(f32, 1), m[1], 1e-4); // sin 90 (yx)
    try testing.expectApproxEqAbs(@as(f32, -1), m[2], 1e-4); // -sin (xy)
    try testing.expectApproxEqAbs(@as(f32, 0), m[3], 1e-4);
    // Explicit Affine2x3 round-trips through Fixed.
    const bytes2 = try colr1ContainerBytes(a, &.{tri}, .{
        .transform = .{ .m = .{ 2, 0.5, -0.5, 1, 30, -40 }, .child = &g },
    }, &.{}, null);
    defer a.free(bytes2);
    var c2 = try decodeColr1(a, bytes2);
    defer c2.deinit(a);
    const p2 = try readPaint(c2.colr, c2.root_paint);
    try testing.expectApproxEqAbs(@as(f32, 2), p2.transform.m[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), p2.transform.m[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -0.5), p2.transform.m[2], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 30), p2.transform.m[4], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -40), p2.transform.m[5], 1e-4);
}

test "colrv1: sweep angles carry the +180° bias" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    const stops = [_]V1Stop{.{ .offset = 0, .palette = PALETTE_FOREGROUND }};
    const sweep = V1Node{ .sweep = .{ .stops = &stops, .start = -1.0, .end = 0.5 } };
    const bytes = try colr1ContainerBytes(a, &.{tri}, .{
        .glyph = .{ .glyph_id = 0, .child = &sweep },
    }, &.{}, null);
    defer a.free(bytes);
    var c1 = try decodeColr1(a, bytes);
    defer c1.deinit(a);
    const g = try readPaint(c1.colr, c1.root_paint);
    const sw = try readPaint(c1.colr, g.glyph.child);
    try testing.expect(sw == .sweep);
    try testing.expectApproxEqAbs(@as(f32, 0), sw.sweep.start_deg, 1e-3); // -1.0 → 0°
    try testing.expectApproxEqAbs(@as(f32, 270), sw.sweep.end_deg, 1e-3); // 0.5 → 270°
}

test "colrv1: v0 table under fmt=colrv1 and v1 under fmt=colrv0 both reject" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    const v0_bytes = try colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = PALETTE_FOREGROUND },
    }, &.{});
    defer a.free(v0_bytes);
    try testing.expectEqual(RegisterError.malformed_payload, validateColr1(a, v0_bytes).?);
    const solid = V1Node{ .solid = .{ .palette = PALETTE_FOREGROUND } };
    const v1_bytes = try colr1ContainerBytes(a, &.{tri}, .{
        .glyph = .{ .glyph_id = 0, .child = &solid },
    }, &.{}, null);
    defer a.free(v1_bytes);
    try testing.expectEqual(RegisterError.malformed_payload, validateColr(a, v1_bytes).?);
    // validatePayload dispatches each to its own decoder.
    try testing.expectEqual(@as(?RegisterError, null), validatePayload(a, .colrv1, v1_bytes));
    try testing.expect(validatePayload(a, .colrv1, tri) != null);
}

test "colrv1: truncation at every byte boundary is malformed" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    const stops = [_]V1Stop{
        .{ .offset = 0, .palette = 0 },
        .{ .offset = 1, .palette = PALETTE_FOREGROUND },
    };
    const lin = V1Node{ .linear = .{ .stops = &stops, .x0 = 0, .y0 = 0, .x1 = 1000, .y1 = 0, .x2 = 0, .y2 = 1000 } };
    const bytes = try colr1ContainerBytes(a, &.{tri}, .{
        .glyph = .{ .glyph_id = 0, .child = &lin },
    }, &.{0xFF00FFFF}, .{ 0, 0, 1000, 1000 });
    defer a.free(bytes);
    var cut: usize = 0;
    while (cut < bytes.len) : (cut += 1) {
        try testing.expectError(error.Malformed, decodeColr1(a, bytes[0..cut]));
    }
}

test "colrv1: out-of-range indices reject" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    {
        // PaintGlyph glyph id beyond the carried outline array.
        const solid = V1Node{ .solid = .{ .palette = PALETTE_FOREGROUND } };
        const bytes = try colr1ContainerBytes(a, &.{tri}, .{
            .glyph = .{ .glyph_id = 1, .child = &solid },
        }, &.{}, null);
        defer a.free(bytes);
        try testing.expectError(error.Malformed, decodeColr1(a, bytes));
    }
    {
        // Solid palette index beyond CPAL.
        const solid = V1Node{ .solid = .{ .palette = 2 } };
        const bytes = try colr1ContainerBytes(a, &.{tri}, .{
            .glyph = .{ .glyph_id = 0, .child = &solid },
        }, &.{0xFF0000FF}, null);
        defer a.free(bytes);
        try testing.expectError(error.Malformed, decodeColr1(a, bytes));
    }
    {
        // Gradient stop palette beyond CPAL.
        const stops = [_]V1Stop{.{ .offset = 0, .palette = 9 }};
        const lin = V1Node{ .linear = .{ .stops = &stops, .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 0, .x2 = 0, .y2 = 1 } };
        const bytes = try colr1ContainerBytes(a, &.{tri}, .{
            .glyph = .{ .glyph_id = 0, .child = &lin },
        }, &.{0xFF0000FF}, null);
        defer a.free(bytes);
        try testing.expectError(error.Malformed, decodeColr1(a, bytes));
    }
    {
        // PaintColrGlyph referencing an absent base record.
        const bytes = try colr1ContainerBytes(a, &.{tri}, .{
            .colr_glyph = .{ .glyph_id = 7 },
        }, &.{}, .{ 0, 0, 100, 100 });
        defer a.free(bytes);
        try testing.expectError(error.Malformed, decodeColr1(a, bytes));
    }
    {
        // Composite mode above the ceiling.
        const solid = V1Node{ .solid = .{ .palette = PALETTE_FOREGROUND } };
        const g = V1Node{ .glyph = .{ .glyph_id = 0, .child = &solid } };
        const bytes = try colr1ContainerBytes(a, &.{tri}, .{
            .composite = .{ .source = &g, .mode = 28, .backdrop = &g },
        }, &.{}, null);
        defer a.free(bytes);
        try testing.expectError(error.Malformed, decodeColr1(a, bytes));
    }
}

test "colrv1: self-referencing PaintColrGlyph cycle rejects" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    // The builder roots at GlyphId 0; a PaintColrGlyph back to 0 is a
    // true cycle the walk stack must catch (not just the budget).
    const bytes = try colr1ContainerBytes(a, &.{tri}, .{
        .colr_glyph = .{ .glyph_id = 0 },
    }, &.{}, .{ 0, 0, 100, 100 });
    defer a.free(bytes);
    try testing.expectError(error.Malformed, decodeColr1(a, bytes));
}

test "colrv1: unbounded root rejects; clip box or glyph wrap accepts" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    const solid = V1Node{ .solid = .{ .palette = PALETTE_FOREGROUND } };
    {
        // Bare solid root: unbounded, no clip box → rejected.
        const bytes = try colr1ContainerBytes(a, &.{tri}, solid, &.{}, null);
        defer a.free(bytes);
        try testing.expectError(error.Malformed, decodeColr1(a, bytes));
    }
    {
        // Same root with a clip box → accepted, box surfaced.
        const bytes = try colr1ContainerBytes(a, &.{tri}, solid, &.{}, .{ 0, -200, 1000, 800 });
        defer a.free(bytes);
        var c1 = try decodeColr1(a, bytes);
        defer c1.deinit(a);
        try testing.expectEqual(@as(i16, -200), c1.clip_box.?.y_min);
        try testing.expectEqual(@as(i16, 1000), c1.clip_box.?.x_max);
    }
    {
        // PaintGlyph bounds it without a clip box.
        const bytes = try colr1ContainerBytes(a, &.{tri}, .{
            .glyph = .{ .glyph_id = 0, .child = &solid },
        }, &.{}, null);
        defer a.free(bytes);
        var c1 = try decodeColr1(a, bytes);
        defer c1.deinit(a);
        try testing.expect(c1.clip_box == null);
    }
}

test "colrv1: carried composite / hinted outline rejected with its own code" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    var comp: [10]u8 = @splat(0);
    std.mem.writeInt(i16, comp[0..2], -1, .big);
    const solid = V1Node{ .solid = .{ .palette = PALETTE_FOREGROUND } };
    const bytes = try colr1ContainerBytes(a, &.{ tri, &comp }, .{
        .glyph = .{ .glyph_id = 0, .child = &solid },
    }, &.{}, null);
    defer a.free(bytes);
    // Graph is fine (outline 1 unreferenced by any paint), but the
    // carried composite still rejects at register time.
    try testing.expectEqual(RegisterError.composite_unsupported, validateColr1(a, bytes).?);
}

test "validateGlyf maps decode errors to wire reasons" {
    const a = testing.allocator;
    const tri = try triangleBytes(a);
    defer a.free(tri);
    try testing.expectEqual(@as(?RegisterError, null), validateGlyf(a, tri));
    var comp: [10]u8 = @splat(0);
    std.mem.writeInt(i16, comp[0..2], -1, .big);
    try testing.expectEqual(RegisterError.composite_unsupported, validateGlyf(a, &comp).?);
    try testing.expectEqual(RegisterError.malformed_payload, validateGlyf(a, &.{ 1, 2 }).?);
}
