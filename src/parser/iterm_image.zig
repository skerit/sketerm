//! iTerm2 OSC 1337 inline image parser.
//!
//! Format: `OSC 1337 ; File = key=value;... : <base64 payload> ST`
//!
//! Only PNG payloads decode to pixels (via the vendored stb_image);
//! anything else comes back as `.unsupported` with its requested
//! geometry still filled in, so a caller can report the drop.

const std = @import("std");
const c = @import("../c.zig").c;

/// One `width=` / `height=` value. iTerm2 accepts four spellings and
/// `auto` is indistinguishable from "not sent" — both mean "derive me
/// from the other dimension".
pub const Dim = union(enum) {
    auto,
    cells: u32,
    pixels: u32,
    percent: u32,

    /// The dimension in pixels, given the cell size and the extent of
    /// the terminal window along this axis. Null for `auto`.
    pub fn toPixels(self: Dim, cell: u32, window: u32) ?f64 {
        return switch (self) {
            .auto => null,
            .cells => |n| @as(f64, @floatFromInt(n)) * @as(f64, @floatFromInt(cell)),
            .pixels => |n| @floatFromInt(n),
            .percent => |n| @as(f64, @floatFromInt(n)) / 100.0 * @as(f64, @floatFromInt(window)),
        };
    }
};

pub const Decoded = struct {
    /// Decoded RGBA pixel buffer, or empty if format not supported.
    rgba: []u8,
    /// The image's own pixel dimensions, 0 when it did not decode.
    width: u32,
    height: u32,
    /// Original payload format hint.
    format: Format,
    /// Requested display size. `auto` on both means "native size".
    req_width: Dim = .auto,
    req_height: Dim = .auto,
    /// `preserveAspectRatio=` (default 1). Only consulted when BOTH
    /// dimensions are given: one-sided requests always derive the
    /// other from the aspect, which is what `auto` means.
    preserve_aspect: bool = true,
    /// `inline=` (default 0). A 0 means "transfer this file, do not
    /// show it" — we have no download side, so those are dropped.
    inline_display: bool = false,
    /// `size=` in bytes, iTerm2's progress-indicator hint. Advisory
    /// only; the real length comes from the base64.
    declared_size: u64 = 0,
    /// `name=`, base64-decoded. Truncated rather than allocated; it
    /// only ever feeds diagnostics.
    name_buf: [128]u8 = undefined,
    name_len: u8 = 0,

    pub fn name(self: *const Decoded) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const Format = enum { png, unsupported };

pub fn decodePayload(allocator: std.mem.Allocator, payload: []const u8) !Decoded {
    // Find the colon separating attrs from base64.
    const colon = std.mem.indexOfScalar(u8, payload, ':') orelse return error.InvalidFormat;
    const attrs_str = payload[0..colon];
    const b64 = payload[colon + 1 ..];

    var out = Decoded{ .rgba = &.{}, .width = 0, .height = 0, .format = .unsupported };
    if (std.mem.startsWith(u8, attrs_str, "File=")) {
        var it = std.mem.tokenizeScalar(u8, attrs_str[5..], ';');
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            const key = kv[0..eq];
            const val = kv[eq + 1 ..];
            if (std.mem.eql(u8, key, "width")) {
                out.req_width = parseDim(val);
            } else if (std.mem.eql(u8, key, "height")) {
                out.req_height = parseDim(val);
            } else if (std.mem.eql(u8, key, "preserveAspectRatio")) {
                out.preserve_aspect = !(val.len == 1 and val[0] == '0');
            } else if (std.mem.eql(u8, key, "inline")) {
                out.inline_display = val.len > 0 and val[0] != '0';
            } else if (std.mem.eql(u8, key, "size")) {
                out.declared_size = std.fmt.parseInt(u64, val, 10) catch 0;
            } else if (std.mem.eql(u8, key, "name")) {
                decodeName(&out, val);
            }
        }
    }

    // Decode base64. Strip whitespace/newlines.
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(allocator);
    for (b64) |b| {
        if (b == ' ' or b == '\n' or b == '\r' or b == '\t') continue;
        try stripped.append(allocator, b);
    }
    const decoder = std.base64.standard.Decoder;
    const out_len = decoder.calcSizeForSlice(stripped.items) catch return error.InvalidBase64;
    const decoded = try allocator.alloc(u8, out_len);
    defer allocator.free(decoded);
    decoder.decode(decoded, stripped.items) catch return error.InvalidBase64;

    // PNG detection — first 8 bytes are 89 50 4E 47 0D 0A 1A 0A.
    const png_magic = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    if (decoded.len < 8 or !std.mem.eql(u8, decoded[0..8], &png_magic)) return out;

    // Decode PNG → RGBA via vendored stb_image.
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const pix_ptr = c.stbi_load_from_memory(
        decoded.ptr,
        @intCast(decoded.len),
        &w,
        &h,
        &channels,
        4,
    );
    if (pix_ptr == null or w <= 0 or h <= 0) return error.PngDecode;

    const npix: usize = @intCast(w * h * 4);
    const out_rgba = try allocator.alloc(u8, npix);
    @memcpy(out_rgba, pix_ptr[0..npix]);
    c.stbi_image_free(pix_ptr);

    out.rgba = out_rgba;
    out.width = @intCast(w);
    out.height = @intCast(h);
    out.format = .png;
    return out;
}

/// The display size in whole cells, or `{0,0}` for "draw at native
/// pixel size" (both dimensions `auto`). `cell_w`/`cell_h` are the
/// cell size in pixels and `cols`/`rows` the terminal grid, which
/// together give the window extent that `N%` is a percentage of.
///
/// Cell counts are rounded to nearest and floored at 1, so a request
/// is never satisfied by drawing nothing; the aspect a caller asked to
/// preserve therefore holds only to within half a cell.
pub fn resolveCells(d: Decoded, cell_w: u32, cell_h: u32, cols: u32, rows: u32) [2]u32 {
    if (d.width == 0 or d.height == 0) return .{ 0, 0 };
    if (cell_w == 0 or cell_h == 0) return .{ 0, 0 };

    const win_w = cols * cell_w;
    const win_h = rows * cell_h;
    var want_w = d.req_width.toPixels(cell_w, win_w);
    var want_h = d.req_height.toPixels(cell_h, win_h);
    if (want_w == null and want_h == null) return .{ 0, 0 };

    const iw: f64 = @floatFromInt(d.width);
    const ih: f64 = @floatFromInt(d.height);

    if (want_w) |bw| {
        if (want_h) |bh| {
            if (d.preserve_aspect) {
                // Fit inside the box: fill it as far as one axis
                // allows without stretching the other.
                const s = @min(bw / iw, bh / ih);
                want_w = iw * s;
                want_h = ih * s;
            }
        } else {
            want_h = bw * ih / iw;
        }
    } else {
        want_w = want_h.? * iw / ih;
    }

    // Never larger than the window. Scaling both by the same factor
    // keeps a preserved aspect preserved; a deliberate stretch is
    // clamped per axis instead.
    var fw = @max(want_w.?, 1.0);
    var fh = @max(want_h.?, 1.0);
    if (d.preserve_aspect) {
        const s = @min(@as(f64, 1.0), @min(
            @as(f64, @floatFromInt(win_w)) / fw,
            @as(f64, @floatFromInt(win_h)) / fh,
        ));
        fw *= s;
        fh *= s;
    } else {
        fw = @min(fw, @as(f64, @floatFromInt(win_w)));
        fh = @min(fh, @as(f64, @floatFromInt(win_h)));
    }

    return .{
        toCells(fw, cell_w, cols),
        toCells(fh, cell_h, rows),
    };
}

fn toCells(px: f64, cell: u32, limit: u32) u32 {
    const n = @round(px / @as(f64, @floatFromInt(cell)));
    if (n < 1) return 1;
    const i: u32 = @intFromFloat(@min(n, @as(f64, @floatFromInt(limit))));
    return @max(i, 1);
}

fn parseDim(s: []const u8) Dim {
    if (s.len == 0) return .auto;
    if (std.mem.eql(u8, s, "auto")) return .auto;
    var digits: usize = 0;
    while (digits < s.len and s[digits] >= '0' and s[digits] <= '9') digits += 1;
    if (digits == 0) return .auto;
    const n = std.fmt.parseInt(u32, s[0..digits], 10) catch return .auto;
    const suffix = s[digits..];
    if (std.mem.eql(u8, suffix, "px")) return .{ .pixels = n };
    if (std.mem.eql(u8, suffix, "%")) return .{ .percent = n };
    if (suffix.len == 0) return .{ .cells = n };
    return .auto;
}

fn decodeName(out: *Decoded, b64: []const u8) void {
    const decoder = std.base64.standard.Decoder;
    const n = decoder.calcSizeForSlice(b64) catch return;
    if (n == 0 or n > out.name_buf.len) return;
    decoder.decode(out.name_buf[0..n], b64) catch return;
    out.name_len = @intCast(n);
}

test "rejects non-PNG payload" {
    const out = try decodePayload(std.testing.allocator, "File=name=t.png:bm9wZQ==");
    defer if (out.rgba.len > 0) std.testing.allocator.free(out.rgba);
    try std.testing.expectEqual(Format.unsupported, out.format);
    try std.testing.expectEqual(@as(u32, 0), out.width);
}

test "parses every width/height unit form" {
    try std.testing.expectEqual(Dim{ .cells = 12 }, parseDim("12"));
    try std.testing.expectEqual(Dim{ .pixels = 200 }, parseDim("200px"));
    try std.testing.expectEqual(Dim{ .percent = 50 }, parseDim("50%"));
    try std.testing.expectEqual(Dim.auto, parseDim("auto"));
    try std.testing.expectEqual(Dim.auto, parseDim(""));
    // Junk is not a size; falling back to auto beats guessing.
    try std.testing.expectEqual(Dim.auto, parseDim("wide"));
    try std.testing.expectEqual(Dim.auto, parseDim("10em"));
}

test "attribute defaults and overrides" {
    const a = try decodePayload(std.testing.allocator, "File=:bm9wZQ==");
    defer if (a.rgba.len > 0) std.testing.allocator.free(a.rgba);
    try std.testing.expectEqual(Dim.auto, a.req_width);
    try std.testing.expectEqual(Dim.auto, a.req_height);
    try std.testing.expect(a.preserve_aspect);
    try std.testing.expect(!a.inline_display); // iTerm2's default is 0

    const b = try decodePayload(
        std.testing.allocator,
        "File=inline=1;size=99;name=aGkudHh0;width=50%;height=3;preserveAspectRatio=0:bm9wZQ==",
    );
    defer if (b.rgba.len > 0) std.testing.allocator.free(b.rgba);
    try std.testing.expect(b.inline_display);
    try std.testing.expectEqual(@as(u64, 99), b.declared_size);
    try std.testing.expectEqualStrings("hi.txt", b.name());
    try std.testing.expectEqual(Dim{ .percent = 50 }, b.req_width);
    try std.testing.expectEqual(Dim{ .cells = 3 }, b.req_height);
    try std.testing.expect(!b.preserve_aspect);
}

/// 100x50 image in a 10x20 pixel cell on an 80x24 grid.
fn sample(w: Dim, h: Dim, preserve: bool) [2]u32 {
    var d = Decoded{ .rgba = &.{}, .width = 100, .height = 50, .format = .png };
    d.req_width = w;
    d.req_height = h;
    d.preserve_aspect = preserve;
    return resolveCells(d, 10, 20, 80, 24);
}

test "sizing: auto on both axes means native pixels" {
    try std.testing.expectEqual([2]u32{ 0, 0 }, sample(.auto, .auto, true));
}

test "sizing: units resolve against cells, pixels and the window" {
    // 6 cells wide = 60px; aspect gives 30px high = 1.5 cells -> 2.
    try std.testing.expectEqual([2]u32{ 6, 2 }, sample(.{ .cells = 6 }, .auto, true));
    // 40px wide = 4 cells; 20px high = 1 cell.
    try std.testing.expectEqual([2]u32{ 4, 1 }, sample(.{ .pixels = 40 }, .auto, true));
    // 50% of an 800px-wide window = 400px = 40 cells; 200px high = 10.
    try std.testing.expectEqual([2]u32{ 40, 10 }, sample(.{ .percent = 50 }, .auto, true));
    // A height-only request derives the width the same way: 4 cells =
    // 80px high, so 160px = 16 cells wide.
    try std.testing.expectEqual([2]u32{ 16, 4 }, sample(.auto, .{ .cells = 4 }, true));
}

test "sizing: preserveAspectRatio fits the box, 0 stretches to fill it" {
    // Box 20 cells x 10 cells = 200x200px. The 2:1 image fits as
    // 200x100 -> 20x5 cells.
    try std.testing.expectEqual(
        [2]u32{ 20, 5 },
        sample(.{ .cells = 20 }, .{ .cells = 10 }, true),
    );
    // Same box, stretched: exactly what was asked for.
    try std.testing.expectEqual(
        [2]u32{ 20, 10 },
        sample(.{ .cells = 20 }, .{ .cells = 10 }, false),
    );
    // preserveAspectRatio is irrelevant when only one axis is given —
    // `auto` on the other already means "keep the aspect".
    try std.testing.expectEqual(
        sample(.{ .cells = 6 }, .auto, true),
        sample(.{ .cells = 6 }, .auto, false),
    );
}

test "sizing: an oversized request is clamped to the window" {
    // 4000px wide on an 800x480 window: the fit scales BOTH axes, so
    // the 2:1 aspect survives (80x20 cells, not 80x24).
    const fit = sample(.{ .pixels = 4000 }, .{ .pixels = 4000 }, true);
    try std.testing.expectEqual([2]u32{ 80, 20 }, fit);
    // A deliberate stretch clamps per axis instead.
    try std.testing.expectEqual(
        [2]u32{ 80, 24 },
        sample(.{ .pixels = 4000 }, .{ .pixels = 4000 }, false),
    );
}

test "sizing: a request never rounds down to nothing" {
    // 1px is a fraction of a cell, but zero cells would draw nothing.
    try std.testing.expectEqual([2]u32{ 1, 1 }, sample(.{ .pixels = 1 }, .{ .pixels = 1 }, false));
}
