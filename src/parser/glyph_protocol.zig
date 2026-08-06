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
//! This build accepts `fmt=glyf` only; `colrv0`/`colrv1` are treated
//! exactly like an unknown fmt (silently dropped), which is what a
//! conforming client discovers via the `s` advertisement.
//!
//! Pure Zig, no libc — compiles into `sketerm-mux`.

const std = @import("std");

/// Protocol identifier prefixing every Glyph Protocol APC body.
pub const PREFIX = "25a1";

/// Post-base64-decode cap on a single registered payload (spec 64 KiB).
pub const MAX_PAYLOAD_BYTES: usize = 64 * 1024;

/// Formats advertised in the `s` reply.
pub const SUPPORTED_FORMATS = "glyf";

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
    /// Decoded glyf record, allocated with the allocator handed to
    /// `parse`. Caller owns (frees or adopts into the glossary).
    payload: []u8,
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

    // fmt=glyf only in this build; anything else (incl. colrv0/colrv1)
    // is dropped like an unknown fmt — see the module doc.
    if (params.get("fmt")) |fmt| {
        if (!std.mem.eql(u8, fmt, "glyf")) return .malformed;
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

    return .{ .register = .{ .cp = cp, .payload = raw, .upm = upm, .width = width, .reply = reply } };
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

test "register: unknown fmt (and unsupported colrv0/colrv1) are dropped" {
    const a = testing.allocator;
    const payload = try b64(a, "x");
    defer a.free(payload);
    for ([_][]const u8{ "svg", "colrv0", "colrv1" }) |fmt| {
        const res = try parseFmt(a, "25a1;r;cp=E0A0;fmt={s};upm=1000;{s}", .{ fmt, payload });
        try testing.expectEqual(Result.malformed, res);
    }
    const ok = try parseFmt(a, "25a1;r;cp=E0A0;fmt=glyf;upm=1000;{s}", .{payload});
    defer freeResult(a, ok);
    try testing.expect(ok == .register);
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
    try testing.expectEqualStrings("\x1b_25a1;s;fmt=glyf\x1b\\", fmtSupport(&buf));
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
