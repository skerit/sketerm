//! Pure-Zig media metadata extraction (EXIF, ID3, Vorbis, ISO-BMFF, ...).
//!
//! Parses UNTRUSTED file bytes, so every walker is bounded: iteration
//! caps, depth caps, explicit slice bounds, and no allocator at all.
//! The result is a fixed-size `Meta` with a flat, stable key namespace
//! (see `keys` below) - the browser sorts and columns on those keys.
//!
//! Input is a bounded WINDOW, never the whole file: a head prefix plus
//! an optional tail suffix (`Input.range` answers only from what is
//! actually resident). That is what keeps extraction cheap on a
//! multi-gigabyte video and what lets the tests drive every parser
//! from an in-memory slice.
//!
//! Deliberately NOT covered here: page counts for PDF and container
//! formats needing a full demuxer (Matroska, AVI streams). Those are
//! reported as kind/format only; the job process fills the rest from
//! ffprobe/pdfinfo when present.

const std = @import("std");

// ── key namespace ───────────────────────────────────────────────
//
// media.kind          image | audio | video | document
// media.format        jpeg png gif webp bmp tiff heif avif mp4 mov
//                     m4a mp3 flac ogg opus wav avi matroska pdf
// media.width         pixels (images AND video) - decimal integer
// media.height        pixels
// media.duration_ms   decimal integer milliseconds
// media.duration_estimated  "1" when derived from a bitrate, not a header
// media.bitrate_kbps  overall FILE bitrate (bytes over duration)
// media.sample_rate   Hz
// media.channels      count
// media.bit_depth     bits per sample (image or audio)
// image.orientation   EXIF 1..8
// tag.title tag.artist tag.album tag.album_artist tag.composer
// tag.comment tag.genre tag.year tag.track tag.track_total
// tag.disc
// exif.datetime_original  "YYYY-MM-DD HH:MM:SS" (sortable)
// exif.datetime           same, file-modification EXIF tag
// exif.make exif.model exif.lens
// exif.exposure_time  "1/250" or "2.5" (seconds)
// exif.f_number       decimal (2.8)
// exif.iso            decimal integer
// exif.focal_length   millimetres, decimal
// exif.gps_lat exif.gps_lon  decimal degrees, MAGNITUDE only (the
//                     N/S/E/W reference tag is not applied)
// doc.version         PDF header version
//
// Keys only the job process fills, from its external-probe fallback
// (see fsjob.zig): media.codec, doc.pages, doc.title, doc.author,
// doc.producer, doc.page_size.

pub const Kind = enum {
    unknown,
    image,
    audio,
    video,
    document,

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }
};

/// Field cap and value cap. Both bound the JSON one result turns into,
/// which must fit the job helper's emit buffer with room for escaping.
pub const MAX_FIELDS = 32;
pub const MAX_VALUE = 192;
const VALUE_BYTES = 2048;

/// Extraction result: keys are static strings, values are offsets into
/// an inline buffer so the whole struct is copyable (no self-pointers).
pub const Meta = struct {
    kind: Kind = .unknown,
    count: usize = 0,
    keys: [MAX_FIELDS][]const u8 = @splat(""),
    offs: [MAX_FIELDS]u16 = @splat(0),
    lens: [MAX_FIELDS]u16 = @splat(0),
    buf: [VALUE_BYTES]u8 = @splat(0),
    used: u16 = 0,
    /// A field or value had to be dropped for lack of room.
    dropped: bool = false,

    pub fn keyAt(self: *const Meta, i: usize) []const u8 {
        if (i >= self.count) return "";
        return self.keys[i];
    }

    pub fn value(self: *const Meta, i: usize) []const u8 {
        if (i >= self.count) return "";
        return self.buf[self.offs[i]..][0..self.lens[i]];
    }

    pub fn get(self: *const Meta, key: []const u8) ?[]const u8 {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.keys[i], key)) return self.value(i);
        }
        return null;
    }

    /// Decimal value of a numeric field, or null when absent or
    /// unparsable (every numeric key in the namespace is plain base 10).
    pub fn getInt(self: *const Meta, key: []const u8) ?u64 {
        const text = self.get(key) orelse return null;
        return std.fmt.parseInt(u64, text, 10) catch null;
    }

    pub fn has(self: *const Meta, key: []const u8) bool {
        return self.get(key) != null;
    }

    /// Record `text` under `key`. First writer wins: parsers run
    /// most-authoritative-source first (a JPEG SOF beats the EXIF
    /// PixelXDimension it disagrees with). Non-UTF-8 or empty-after-
    /// cleanup text is dropped rather than shipped to a JSON wire.
    pub fn put(self: *Meta, key: []const u8, text: []const u8) void {
        if (self.has(key)) return;
        var clean_buf: [MAX_VALUE]u8 = undefined;
        const clean = sanitize(text, &clean_buf) orelse return;
        if (clean.len == 0) return;
        if (self.count >= MAX_FIELDS or self.used + clean.len > VALUE_BYTES) {
            self.dropped = true;
            return;
        }
        @memcpy(self.buf[self.used..][0..clean.len], clean);
        self.keys[self.count] = key;
        self.offs[self.count] = self.used;
        self.lens[self.count] = @intCast(clean.len);
        self.used += @intCast(clean.len);
        self.count += 1;
    }

    pub fn putInt(self: *Meta, key: []const u8, v: u64) void {
        var buf: [24]u8 = undefined;
        self.put(key, std.fmt.bufPrint(&buf, "{d}", .{v}) catch return);
    }

    /// Latin-1 (ISO-8859-1) text, the ID3v1 and ID3v2 encoding-0 case.
    fn putLatin1(self: *Meta, key: []const u8, bytes: []const u8) void {
        var out: [MAX_VALUE * 2]u8 = undefined;
        var n: usize = 0;
        for (bytes) |b| {
            if (n + 2 > out.len) break;
            if (b < 0x80) {
                out[n] = b;
                n += 1;
            } else {
                out[n] = 0xC0 | (b >> 6);
                out[n + 1] = 0x80 | (b & 0x3F);
                n += 2;
            }
        }
        self.put(key, out[0..n]);
    }

    /// UTF-16 text; `default_big` picks the order when no BOM is present.
    fn putUtf16(self: *Meta, key: []const u8, bytes_in: []const u8, default_big: bool) void {
        var bytes = bytes_in;
        var big = default_big;
        if (bytes.len >= 2) {
            if (bytes[0] == 0xFF and bytes[1] == 0xFE) {
                big = false;
                bytes = bytes[2..];
            } else if (bytes[0] == 0xFE and bytes[1] == 0xFF) {
                big = true;
                bytes = bytes[2..];
            }
        }
        var out: [MAX_VALUE * 2]u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i + 1 < bytes.len and n + 4 <= out.len) : (i += 2) {
            var cp: u32 = if (big)
                (@as(u32, bytes[i]) << 8) | bytes[i + 1]
            else
                (@as(u32, bytes[i + 1]) << 8) | bytes[i];
            if (cp == 0) break;
            if (cp >= 0xD800 and cp <= 0xDBFF) {
                if (i + 3 >= bytes.len) break;
                const lo: u32 = if (big)
                    (@as(u32, bytes[i + 2]) << 8) | bytes[i + 3]
                else
                    (@as(u32, bytes[i + 3]) << 8) | bytes[i + 2];
                if (lo < 0xDC00 or lo > 0xDFFF) break;
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            } else if (cp >= 0xDC00 and cp <= 0xDFFF) break;
            n += std.unicode.utf8Encode(@intCast(cp), out[n..]) catch break;
        }
        self.put(key, out[0..n]);
    }
};

/// Trim, strip control characters, validate UTF-8 and cap length on a
/// codepoint boundary. Returns null when nothing usable remains.
fn sanitize(text: []const u8, out: *[MAX_VALUE]u8) ?[]const u8 {
    var n: usize = 0;
    for (text) |b| {
        if (n >= out.len) break;
        if (b == 0) break;
        out[n] = if (b < 0x20 or b == 0x7F) ' ' else b;
        n += 1;
    }
    // Never cut a multi-byte sequence in half.
    while (n > 0 and (out[n - 1] & 0xC0) == 0x80) n -= 1;
    if (n > 0 and (out[n - 1] & 0x80) != 0) n -= 1;
    const trimmed = std.mem.trim(u8, out[0..n], " \t\r\n");
    if (trimmed.len == 0) return null;
    if (!std.unicode.utf8ValidateSlice(trimmed)) return null;
    return trimmed;
}

/// A bounded read window over a file: `head` covers [0, head.len) and
/// `tail` covers [size - tail.len, size). Anything else reads as absent.
pub const Input = struct {
    head: []const u8 = &.{},
    tail: []const u8 = &.{},
    size: u64 = 0,
    /// File name; only used as a hint when the magic bytes are absent.
    name: []const u8 = "",
    /// Working space for ID3 de-unsynchronisation and Ogg de-paging.
    /// Empty is legal: the affected formats degrade instead of guessing.
    scratch: []u8 = &.{},

    /// A whole in-memory file (what the tests use).
    pub fn fromSlice(bytes: []const u8, name: []const u8, scratch: []u8) Input {
        return .{ .head = bytes, .tail = bytes, .size = bytes.len, .name = name, .scratch = scratch };
    }

    /// Bytes [off, off+len) if the window covers them contiguously.
    pub fn range(self: Input, off: u64, len: usize) ?[]const u8 {
        const end = off +| @as(u64, len);
        if (end > self.size) return null;
        if (end <= @as(u64, self.head.len)) return self.head[@intCast(off)..@intCast(end)];
        if (self.tail.len > 0) {
            const tstart = self.size - @as(u64, self.tail.len);
            if (off >= tstart) return self.tail[@intCast(off - tstart)..@intCast(end - tstart)];
        }
        return null;
    }
};

// ── byte readers (slice-bounded, never panic) ────────────────────

fn u16be(b: []const u8) u16 {
    if (b.len < 2) return 0;
    return (@as(u16, b[0]) << 8) | b[1];
}

fn u16le(b: []const u8) u16 {
    if (b.len < 2) return 0;
    return (@as(u16, b[1]) << 8) | b[0];
}

fn u32be(b: []const u8) u32 {
    if (b.len < 4) return 0;
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

fn u32le(b: []const u8) u32 {
    if (b.len < 4) return 0;
    return (@as(u32, b[3]) << 24) | (@as(u32, b[2]) << 16) | (@as(u32, b[1]) << 8) | b[0];
}

fn u64be(b: []const u8) u64 {
    if (b.len < 8) return 0;
    return (@as(u64, u32be(b[0..4])) << 32) | u32be(b[4..8]);
}

fn u24le(b: []const u8) u32 {
    if (b.len < 3) return 0;
    return (@as(u32, b[2]) << 16) | (@as(u32, b[1]) << 8) | b[0];
}

fn u64le(b: []const u8) u64 {
    if (b.len < 8) return 0;
    return (@as(u64, u32le(b[4..8])) << 32) | u32le(b[0..4]);
}

fn startsWith(b: []const u8, prefix: []const u8) bool {
    return b.len >= prefix.len and std.mem.eql(u8, b[0..prefix.len], prefix);
}

fn extIs(name: []const u8, exts: []const []const u8) bool {
    for (exts) |e| if (std.ascii.endsWithIgnoreCase(name, e)) return true;
    return false;
}

/// Sane pixel bound: anything above is a corrupt header, not a photo.
const MAX_DIM: u64 = 1 << 20;
/// A month. Longer "durations" are a misparse dressed up as data.
const MAX_DURATION_MS: u64 = 30 * 24 * 3600 * 1000;

fn putDims(m: *Meta, w: u64, h: u64) void {
    if (w == 0 or h == 0 or w > MAX_DIM or h > MAX_DIM) return;
    m.putInt("media.width", w);
    m.putInt("media.height", h);
}

fn putDim(m: *Meta, key: []const u8, v: u64) void {
    if (v == 0 or v > MAX_DIM) return;
    m.putInt(key, v);
}

fn putDuration(m: *Meta, ms: u64) void {
    if (ms == 0 or ms > MAX_DURATION_MS) return;
    m.putInt("media.duration_ms", ms);
}

fn putRate(m: *Meta, hz: u64) void {
    if (hz == 0 or hz > 3_000_000) return;
    m.putInt("media.sample_rate", hz);
}

fn putChannels(m: *Meta, n: u64) void {
    if (n == 0 or n > 64) return;
    m.putInt("media.channels", n);
}

fn putBitrate(m: *Meta, kbps: u64) void {
    if (kbps == 0 or kbps > 1_000_000) return;
    m.putInt("media.bitrate_kbps", kbps);
}

// ── entry point ─────────────────────────────────────────────────

/// Identify `in` and extract everything cheap. Never fails: an
/// unrecognised or truncated file simply yields `kind == .unknown`.
pub fn extract(in: Input) Meta {
    var m = Meta{};
    const h = in.head;
    if (startsWith(h, "\x89PNG\r\n\x1a\n")) {
        png(&m, in);
    } else if (h.len >= 3 and h[0] == 0xFF and h[1] == 0xD8 and h[2] == 0xFF) {
        jpeg(&m, in);
    } else if (startsWith(h, "GIF87a") or startsWith(h, "GIF89a")) {
        gif(&m, in);
    } else if (h.len >= 12 and startsWith(h, "RIFF")) {
        if (std.mem.eql(u8, h[8..12], "WEBP")) {
            webp(&m, in);
        } else if (std.mem.eql(u8, h[8..12], "WAVE")) {
            wav(&m, in);
        } else if (std.mem.eql(u8, h[8..12], "AVI ")) {
            avi(&m, in);
        }
    } else if (h.len >= 26 and h[0] == 'B' and h[1] == 'M') {
        bmp(&m, in);
    } else if (startsWith(h, "II\x2a\x00") or startsWith(h, "MM\x00\x2a")) {
        m.kind = .image;
        m.put("media.format", "tiff");
        tiff(&m, h);
    } else if (h.len >= 12 and std.mem.eql(u8, h[4..8], "ftyp")) {
        isobmff(&m, in);
    } else if (startsWith(h, "fLaC")) {
        flac(&m, in);
    } else if (startsWith(h, "OggS")) {
        ogg(&m, in);
    } else if (startsWith(h, "%PDF-")) {
        pdf(&m, in);
    } else if (startsWith(h, "\x1a\x45\xdf\xa3")) {
        matroska(&m, in);
    } else if (startsWith(h, "ID3") or
        (h.len >= 2 and h[0] == 0xFF and (h[1] & 0xE0) == 0xE0) or
        extIs(in.name, &.{".mp3"}))
    {
        mp3(&m, in);
    }
    if (m.kind != .unknown) m.put("media.kind", m.kind.name());
    // Overall FILE bitrate (bytes over duration), the convention every
    // player and ffprobe report. Container headers only carry one
    // stream's NOMINAL rate, which disagrees with what the file
    // actually costs; `put` is first-wins so a format that genuinely
    // knows better still wins.
    if (m.getInt("media.duration_ms")) |ms| {
        if (ms > 0 and in.size > 0) putBitrate(&m, in.size *| 8 / ms);
    }
    return m;
}

// ── still images ────────────────────────────────────────────────

fn png(m: *Meta, in: Input) void {
    m.kind = .image;
    m.put("media.format", "png");
    const h = in.head;
    if (h.len < 26 or !std.mem.eql(u8, h[12..16], "IHDR")) return;
    putDims(m, u32be(h[16..20]), u32be(h[20..24]));
    if (h[24] > 0 and h[24] <= 16) m.putInt("media.bit_depth", h[24]);
}

fn gif(m: *Meta, in: Input) void {
    m.kind = .image;
    m.put("media.format", "gif");
    const h = in.head;
    if (h.len < 10) return;
    putDims(m, u16le(h[6..8]), u16le(h[8..10]));
}

fn bmp(m: *Meta, in: Input) void {
    m.kind = .image;
    m.put("media.format", "bmp");
    const h = in.head;
    if (h.len < 26) return;
    const dib = u32le(h[14..18]);
    if (dib == 12) {
        // BITMAPCOREHEADER: 16-bit dimensions.
        putDims(m, u16le(h[18..20]), u16le(h[20..22]));
        if (h.len >= 26) m.putInt("media.bit_depth", u16le(h[24..26]));
        return;
    }
    if (h.len < 30) return;
    const w: i32 = @bitCast(u32le(h[18..22]));
    const hh: i32 = @bitCast(u32le(h[22..26]));
    putDims(m, @abs(w), @abs(hh));
    m.putInt("media.bit_depth", u16le(h[28..30]));
}

fn webp(m: *Meta, in: Input) void {
    m.kind = .image;
    m.put("media.format", "webp");
    const h = in.head;
    var off: usize = 12;
    var guard: usize = 0;
    while (off + 8 <= h.len and guard < 16) : (guard += 1) {
        const fourcc = h[off .. off + 4];
        const size = u32le(h[off + 4 .. off + 8]);
        const body_start = off + 8;
        if (size > h.len - body_start) {
            // Truncated chunk: still usable for the fixed-size headers.
            if (std.mem.eql(u8, fourcc, "VP8X") and body_start + 10 <= h.len) {
                const p = h[body_start..];
                putDims(m, @as(u64, u24le(p[4..7])) + 1, @as(u64, u24le(p[7..10])) + 1);
            }
            return;
        }
        const p = h[body_start..][0..size];
        if (std.mem.eql(u8, fourcc, "VP8X") and p.len >= 10) {
            putDims(m, @as(u64, u24le(p[4..7])) + 1, @as(u64, u24le(p[7..10])) + 1);
            return;
        }
        if (std.mem.eql(u8, fourcc, "VP8 ") and p.len >= 10 and
            p[3] == 0x9D and p[4] == 0x01 and p[5] == 0x2A)
        {
            putDims(m, u16le(p[6..8]) & 0x3FFF, u16le(p[8..10]) & 0x3FFF);
            return;
        }
        if (std.mem.eql(u8, fourcc, "VP8L") and p.len >= 5 and p[0] == 0x2F) {
            const bits = u32le(p[1..5]);
            putDims(m, (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
            return;
        }
        off = body_start + size + (size & 1); // RIFF chunks are padded even
    }
}

fn jpeg(m: *Meta, in: Input) void {
    m.kind = .image;
    m.put("media.format", "jpeg");
    const h = in.head;
    var off: usize = 2;
    var guard: usize = 0;
    while (off + 4 <= h.len and guard < 256) : (guard += 1) {
        if (h[off] != 0xFF) return;
        const marker = h[off + 1];
        if (marker == 0xFF) {
            off += 1; // fill byte
            continue;
        }
        if (marker == 0xD8 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)) {
            off += 2;
            continue;
        }
        if (marker == 0xD9 or marker == 0xDA) return; // EOI / start of scan
        const seglen = u16be(h[off + 2 .. off + 4]);
        if (seglen < 2) return;
        const body_start = off + 4;
        const body_len = @min(@as(usize, seglen) - 2, h.len -| body_start);
        const body = h[@min(body_start, h.len)..][0..body_len];
        const is_sof = marker >= 0xC0 and marker <= 0xCF and
            marker != 0xC4 and marker != 0xC8 and marker != 0xCC;
        if (is_sof and body.len >= 5) {
            putDims(m, u16be(body[3..5]), u16be(body[1..3]));
        } else if (marker == 0xE1 and startsWith(body, "Exif\x00\x00")) {
            tiff(m, body[6..]);
        }
        off = body_start + seglen - 2;
    }
}

// ── TIFF / EXIF IFD ─────────────────────────────────────────────

const IfdKind = enum { main, exif, gps };

const Rational = struct { num: i64, den: i64 };

/// EXIF/TIFF value types, indexed by the on-disk type code.
fn typeSize(t: u16) usize {
    return switch (t) {
        1, 2, 6, 7 => 1,
        3, 8 => 2,
        4, 9, 11 => 4,
        5, 10, 12 => 8,
        else => 0,
    };
}

const Tiff = struct {
    data: []const u8,
    big: bool,

    fn u16at(self: Tiff, off: usize) u16 {
        if (off + 2 > self.data.len) return 0;
        return if (self.big) u16be(self.data[off..]) else u16le(self.data[off..]);
    }

    fn u32at(self: Tiff, off: usize) u32 {
        if (off + 4 > self.data.len) return 0;
        return if (self.big) u32be(self.data[off..]) else u32le(self.data[off..]);
    }

    fn read16(self: Tiff, b: []const u8) u16 {
        return if (self.big) u16be(b) else u16le(b);
    }

    fn read32(self: Tiff, b: []const u8) u32 {
        return if (self.big) u32be(b) else u32le(b);
    }

    /// One element of an entry's value array, widened to u64.
    fn elem(self: Tiff, typ: u16, bytes: []const u8, idx: usize) u64 {
        const sz = typeSize(typ);
        if (sz == 0 or (idx + 1) * sz > bytes.len) return 0;
        const b = bytes[idx * sz ..][0..sz];
        return switch (typ) {
            1, 2, 6, 7 => b[0],
            3, 8 => self.read16(b),
            4, 9, 11 => self.read32(b),
            else => 0,
        };
    }

    /// Numerator/denominator of a RATIONAL (type 5) or SRATIONAL (10).
    fn rational(self: Tiff, typ: u16, bytes: []const u8, idx: usize) ?Rational {
        if (typ != 5 and typ != 10) return null;
        if ((idx + 1) * 8 > bytes.len) return null;
        const b = bytes[idx * 8 ..][0..8];
        const n = self.read32(b[0..4]);
        const d = self.read32(b[4..8]);
        if (d == 0) return null;
        if (typ == 10) return .{ .num = @as(i32, @bitCast(n)), .den = @as(i32, @bitCast(d)) };
        return .{ .num = n, .den = d };
    }
};

fn tiff(m: *Meta, data: []const u8) void {
    if (data.len < 8) return;
    const big = if (std.mem.eql(u8, data[0..2], "MM")) true else if (std.mem.eql(u8, data[0..2], "II")) false else return;
    const t = Tiff{ .data = data, .big = big };
    if (t.u16at(2) != 42) return;
    const ifd0 = t.u32at(4);
    ifd(m, t, ifd0, .main);
}

fn ifd(m: *Meta, t: Tiff, off_in: u32, which: IfdKind) void {
    const off: usize = off_in;
    if (off + 2 > t.data.len) return;
    var n: usize = t.u16at(off);
    if (n == 0) return;
    if (n > 512) n = 512; // adversarial entry count
    const first = off + 2;
    if (first + n * 12 > t.data.len) n = (t.data.len -| first) / 12;
    for (0..n) |i| {
        const e = t.data[first + i * 12 ..][0..12];
        const tag = t.read16(e[0..2]);
        const typ = t.read16(e[2..4]);
        const count: u64 = t.read32(e[4..8]);
        const sz = typeSize(typ);
        if (sz == 0) continue;
        const total = count *| @as(u64, sz);
        if (total > 65536) continue;
        var bytes: []const u8 = undefined;
        if (total <= 4) {
            bytes = e[8..][0..@intCast(total)];
        } else {
            const voff: usize = t.read32(e[8..12]);
            if (voff + @as(usize, @intCast(total)) > t.data.len) continue;
            bytes = t.data[voff..][0..@intCast(total)];
        }
        entry(m, t, which, tag, typ, bytes);
    }
}

fn entry(m: *Meta, t: Tiff, which: IfdKind, tag: u16, typ: u16, bytes: []const u8) void {
    switch (which) {
        .main => switch (tag) {
            0x0100 => putDim(m, "media.width", t.elem(typ, bytes, 0)),
            0x0101 => putDim(m, "media.height", t.elem(typ, bytes, 0)),
            0x0112 => {
                const o = t.elem(typ, bytes, 0);
                if (o >= 1 and o <= 8) m.putInt("image.orientation", o);
            },
            0x010F => m.putLatin1("exif.make", ascii(bytes)),
            0x0110 => m.putLatin1("exif.model", ascii(bytes)),
            0x0132 => putExifDate(m, "exif.datetime", ascii(bytes)),
            0x8769 => ifd(m, t, @intCast(t.elem(typ, bytes, 0)), .exif),
            0x8825 => ifd(m, t, @intCast(t.elem(typ, bytes, 0)), .gps),
            else => {},
        },
        .exif => switch (tag) {
            0x9003 => putExifDate(m, "exif.datetime_original", ascii(bytes)),
            0x829A => {
                const r = t.rational(typ, bytes, 0) orelse return;
                var buf: [32]u8 = undefined;
                // Shutter speeds read as fractions; anything at or above a
                // second reads as a decimal, the way a camera shows it.
                const text = if (r.num != 0 and @divTrunc(r.den, r.num) >= 1)
                    std.fmt.bufPrint(&buf, "1/{d}", .{@divTrunc(r.den, r.num)}) catch return
                else
                    std.fmt.bufPrint(&buf, "{d:.3}", .{ratio(r.num, r.den)}) catch return;
                m.put("exif.exposure_time", text);
            },
            0x829D => putDecimal(m, "exif.f_number", t.rational(typ, bytes, 0)),
            0x8827 => m.putInt("exif.iso", t.elem(typ, bytes, 0)),
            0x920A => putDecimal(m, "exif.focal_length", t.rational(typ, bytes, 0)),
            0xA002 => putDim(m, "media.width", t.elem(typ, bytes, 0)),
            0xA003 => putDim(m, "media.height", t.elem(typ, bytes, 0)),
            0xA434 => m.putLatin1("exif.lens", ascii(bytes)),
            else => {},
        },
        .gps => switch (tag) {
            0x0002 => putGps(m, t, "exif.gps_lat", typ, bytes),
            0x0004 => putGps(m, t, "exif.gps_lon", typ, bytes),
            else => {},
        },
    }
}

fn ratio(num: i64, den: i64) f64 {
    if (den == 0) return 0;
    return @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
}

fn putDecimal(m: *Meta, key: []const u8, r: ?Rational) void {
    const v = r orelse return;
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.2}", .{ratio(v.num, v.den)}) catch return;
    m.put(key, std.mem.trimEnd(u8, std.mem.trimEnd(u8, text, "0"), "."));
}

/// GPS coordinates are three rationals (deg, min, sec). The N/S/E/W
/// reference tag is deliberately ignored: the sign is cosmetic for a
/// sortable column and reading it needs a second entry lookup.
fn putGps(m: *Meta, t: Tiff, key: []const u8, typ: u16, bytes: []const u8) void {
    const d = t.rational(typ, bytes, 0) orelse return;
    const mi = t.rational(typ, bytes, 1) orelse return;
    const s = t.rational(typ, bytes, 2) orelse return;
    const deg = ratio(d.num, d.den) + ratio(mi.num, mi.den) / 60.0 + ratio(s.num, s.den) / 3600.0;
    if (deg < -180 or deg > 180) return;
    var buf: [32]u8 = undefined;
    m.put(key, std.fmt.bufPrint(&buf, "{d:.6}", .{deg}) catch return);
}

fn ascii(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..end];
}

/// EXIF stores "YYYY:MM:DD HH:MM:SS"; the colons in the date half make
/// it unsortable as text, so normalise to ISO-ish dashes.
fn putExifDate(m: *Meta, key: []const u8, text: []const u8) void {
    if (text.len < 19) return;
    var buf: [19]u8 = undefined;
    @memcpy(&buf, text[0..19]);
    if (buf[4] != ':' or buf[7] != ':') return;
    buf[4] = '-';
    buf[7] = '-';
    for (buf[0..4]) |ch| if (!std.ascii.isDigit(ch)) return;
    m.put(key, &buf);
}

// ── ISO base media (mp4 / m4a / mov / heif / avif) ───────────────

const BoxState = struct {
    m: *Meta,
    in: Input,
    has_video: bool = false,
    has_audio: bool = false,
    timescale: u32 = 0,
    duration: u64 = 0,
    /// Handler type of the trak currently being walked.
    track_is_video: bool = false,
};

fn isobmff(m: *Meta, in: Input) void {
    const brand = if (in.head.len >= 12) in.head[8..12] else "    ";
    var image_brand = false;
    if (std.mem.eql(u8, brand, "M4A ") or std.mem.eql(u8, brand, "M4B ")) {
        m.kind = .audio;
        m.put("media.format", "m4a");
    } else if (std.mem.eql(u8, brand, "qt  ")) {
        m.kind = .video;
        m.put("media.format", "mov");
    } else if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis")) {
        m.kind = .image;
        m.put("media.format", "avif");
        image_brand = true;
    } else if (std.mem.eql(u8, brand, "heic") or std.mem.eql(u8, brand, "heix") or
        std.mem.eql(u8, brand, "mif1") or std.mem.eql(u8, brand, "msf1"))
    {
        m.kind = .image;
        m.put("media.format", "heif");
        image_brand = true;
    } else {
        m.kind = .video;
        m.put("media.format", "mp4");
    }

    var st = BoxState{ .m = m, .in = in };
    boxes(&st, 0, in.size, 0);
    if (!image_brand) {
        if (st.has_video) {
            m.kind = .video;
        } else if (st.has_audio) {
            // A moov with only sound tracks is an audio file whatever the
            // ftyp brand claims; the container format label stays as-is.
            m.kind = .audio;
        }
    }
    if (st.timescale > 0 and st.duration > 0)
        putDuration(m, st.duration *| 1000 / st.timescale);
}

const CONTAINER_BOXES = [_][]const u8{ "moov", "trak", "mdia", "minf", "stbl", "udta", "iprp", "ipco", "edts", "moof", "traf" };

fn boxes(st: *BoxState, start: u64, end: u64, depth: u32) void {
    if (depth > 6) return;
    var off = start;
    var guard: usize = 0;
    while (off + 8 <= end and guard < 512) : (guard += 1) {
        const hdr = st.in.range(off, 8) orelse return;
        var size: u64 = u32be(hdr[0..4]);
        const btype = hdr[4..8];
        var hdr_len: u64 = 8;
        if (size == 1) {
            const ext = st.in.range(off + 8, 8) orelse return;
            size = u64be(ext);
            hdr_len = 16;
        } else if (size == 0) {
            size = end - off;
        }
        if (size < hdr_len or off +| size > end) return;
        const body = off + hdr_len;
        const box_end = off + size;

        if (containerBox(btype)) {
            if (std.mem.eql(u8, btype, "trak")) st.track_is_video = false;
            boxes(st, body, box_end, depth + 1);
        } else if (std.mem.eql(u8, btype, "meta")) {
            // FullBox: 4 bytes of version+flags before the children.
            boxes(st, body + 4, box_end, depth + 1);
        } else if (std.mem.eql(u8, btype, "mvhd")) {
            mvhd(st, body, box_end);
        } else if (std.mem.eql(u8, btype, "tkhd")) {
            tkhd(st, body, box_end);
        } else if (std.mem.eql(u8, btype, "hdlr")) {
            hdlr(st, body, box_end);
        } else if (std.mem.eql(u8, btype, "ilst")) {
            ilst(st, body, box_end);
        } else if (std.mem.eql(u8, btype, "ispe")) {
            const b = st.in.range(body, 12) orelse {
                off = box_end;
                continue;
            };
            putDims(st.m, u32be(b[4..8]), u32be(b[8..12]));
        }
        off = box_end;
    }
}

fn containerBox(btype: []const u8) bool {
    for (CONTAINER_BOXES) |name| {
        if (std.mem.eql(u8, btype, name)) return true;
    }
    return false;
}

fn mvhd(st: *BoxState, body: u64, end: u64) void {
    const v = st.in.range(body, 1) orelse return;
    if (v[0] == 0) {
        const b = st.in.range(body + 12, 8) orelse return;
        st.timescale = u32be(b[0..4]);
        st.duration = u32be(b[4..8]);
    } else if (v[0] == 1) {
        const b = st.in.range(body + 20, 12) orelse return;
        st.timescale = u32be(b[0..4]);
        st.duration = u64be(b[4..12]);
    }
    _ = end;
}

/// Track dimensions live in the LAST eight bytes of the tkhd payload as
/// 16.16 fixed point, in both version 0 and version 1 layouts.
fn tkhd(st: *BoxState, body: u64, end: u64) void {
    if (end < body + 8) return;
    const b = st.in.range(end - 8, 8) orelse return;
    const w = @as(u64, u32be(b[0..4])) >> 16;
    const h = @as(u64, u32be(b[4..8])) >> 16;
    if (w == 0 or h == 0) return;
    st.has_video = true;
    putDims(st.m, w, h);
}

fn hdlr(st: *BoxState, body: u64, end: u64) void {
    _ = end;
    const b = st.in.range(body + 8, 4) orelse return;
    if (std.mem.eql(u8, b, "vide")) st.has_video = true;
    if (std.mem.eql(u8, b, "soun")) st.has_audio = true;
}

/// iTunes-style metadata: each child is a typed atom holding one `data`
/// box (version+flags, locale, payload).
fn ilst(st: *BoxState, start: u64, end: u64) void {
    var off = start;
    var guard: usize = 0;
    while (off + 8 <= end and guard < 64) : (guard += 1) {
        const hdr = st.in.range(off, 8) orelse return;
        const size: u64 = u32be(hdr[0..4]);
        if (size < 8 or off +| size > end) return;
        const atom = hdr[4..8];
        const item_end = off + size;
        // Find this atom's `data` child.
        var doff = off + 8;
        var dguard: usize = 0;
        while (doff + 8 <= item_end and dguard < 8) : (dguard += 1) {
            const dh = st.in.range(doff, 8) orelse break;
            const dsize: u64 = u32be(dh[0..4]);
            if (dsize < 16 or doff +| dsize > item_end) break;
            if (std.mem.eql(u8, dh[4..8], "data")) {
                const meta = st.in.range(doff + 8, 8) orelse break;
                const dtype = u32be(meta[0..4]) & 0x00FFFFFF;
                const plen: usize = @intCast(dsize - 16);
                const payload = st.in.range(doff + 16, @min(plen, 512)) orelse break;
                ilstValue(st.m, atom, dtype, payload);
                break;
            }
            doff += dsize;
        }
        off = item_end;
    }
}

fn ilstValue(m: *Meta, atom: []const u8, dtype: u32, payload: []const u8) void {
    const text_key: ?[]const u8 = if (std.mem.eql(u8, atom, "\xA9nam"))
        "tag.title"
    else if (std.mem.eql(u8, atom, "\xA9ART"))
        "tag.artist"
    else if (std.mem.eql(u8, atom, "\xA9alb"))
        "tag.album"
    else if (std.mem.eql(u8, atom, "aART"))
        "tag.album_artist"
    else if (std.mem.eql(u8, atom, "\xA9wrt"))
        "tag.composer"
    else if (std.mem.eql(u8, atom, "\xA9cmt"))
        "tag.comment"
    else if (std.mem.eql(u8, atom, "\xA9gen"))
        "tag.genre"
    else
        null;
    if (text_key) |key| {
        if (dtype == 1) m.put(key, payload);
        return;
    }
    if (std.mem.eql(u8, atom, "\xA9day")) {
        if (dtype == 1 and payload.len >= 4) m.put("tag.year", payload[0..4]);
        return;
    }
    if (std.mem.eql(u8, atom, "gnre") and payload.len >= 2) {
        const idx = u16be(payload[0..2]);
        if (idx >= 1) m.put("tag.genre", genreName(idx - 1));
        return;
    }
    if (std.mem.eql(u8, atom, "trkn") and payload.len >= 6) {
        if (u16be(payload[2..4]) > 0) m.putInt("tag.track", u16be(payload[2..4]));
        if (payload.len >= 8 and u16be(payload[4..6]) > 0) m.putInt("tag.track_total", u16be(payload[4..6]));
        return;
    }
    if (std.mem.eql(u8, atom, "disk") and payload.len >= 4) {
        if (u16be(payload[2..4]) > 0) m.putInt("tag.disc", u16be(payload[2..4]));
    }
}

// ── MPEG audio (mp3) + ID3 ──────────────────────────────────────

const BITRATES_V1 = [3][16]u16{
    // Layer I
    .{ 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0 },
    // Layer II
    .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0 },
    // Layer III
    .{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 },
};
const BITRATES_V2 = [3][16]u16{
    .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0 },
    .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 },
    .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 },
};
const SAMPLE_RATES = [4][3]u32{
    .{ 11025, 12000, 8000 }, // MPEG 2.5
    .{ 0, 0, 0 }, // reserved
    .{ 22050, 24000, 16000 }, // MPEG 2
    .{ 44100, 48000, 32000 }, // MPEG 1
};

const FrameHeader = struct {
    version: u2,
    layer: u2,
    bitrate_kbps: u32,
    sample_rate: u32,
    channels: u8,
    frame_len: u32,
    samples: u32,
    /// Offset from the frame header to a Xing/Info tag, if present.
    side_info: u32,
};

fn frameHeader(b: []const u8) ?FrameHeader {
    if (b.len < 4) return null;
    if (b[0] != 0xFF or (b[1] & 0xE0) != 0xE0) return null;
    const version: u2 = @intCast((b[1] >> 3) & 3);
    const layer: u2 = @intCast((b[1] >> 1) & 3);
    if (version == 1 or layer == 0) return null; // reserved
    const br_index = b[2] >> 4;
    const sr_index = (b[2] >> 2) & 3;
    if (br_index == 0 or br_index == 15 or sr_index == 3) return null;
    const layer_idx: usize = 3 - @as(usize, layer); // layer bits: 3=I, 2=II, 1=III
    const mpeg1 = version == 3;
    const kbps: u32 = if (mpeg1) BITRATES_V1[layer_idx][br_index] else BITRATES_V2[layer_idx][br_index];
    const sr = SAMPLE_RATES[version][sr_index];
    if (kbps == 0 or sr == 0) return null;
    const padding: u32 = (b[2] >> 1) & 1;
    const mono = (b[3] >> 6) == 3;
    const samples: u32 = if (layer_idx == 0) 384 else if (mpeg1) 1152 else if (layer_idx == 2) 576 else 1152;
    const bps = kbps * 1000;
    const frame_len: u32 = if (layer_idx == 0)
        (12 * bps / sr + padding) * 4
    else
        samples / 8 * bps / sr + padding;
    const side: u32 = if (mpeg1) (if (mono) 17 else 32) else (if (mono) 9 else 17);
    return .{
        .version = version,
        .layer = layer,
        .bitrate_kbps = kbps,
        .sample_rate = sr,
        .channels = if (mono) 1 else 2,
        .frame_len = frame_len,
        .samples = samples,
        .side_info = side,
    };
}

fn syncsafe(b: []const u8) u32 {
    if (b.len < 4) return 0;
    return (@as(u32, b[0] & 0x7F) << 21) | (@as(u32, b[1] & 0x7F) << 14) |
        (@as(u32, b[2] & 0x7F) << 7) | (b[3] & 0x7F);
}

fn mp3(m: *Meta, in: Input) void {
    m.kind = .audio;
    m.put("media.format", "mp3");
    var audio_start: u64 = 0;
    if (startsWith(in.head, "ID3") and in.head.len >= 10) {
        const size = syncsafe(in.head[6..10]);
        audio_start = 10 + @as(u64, size);
        if (in.head[5] & 0x10 != 0) audio_start += 10; // footer
        id3v2(m, in, in.head[3], in.head[5], size);
    }
    // ID3v1 fills only what v2 left empty (put is first-wins).
    id3v1(m, in);
    mpegStream(m, in, audio_start);
}

/// Locate the first real frame at or after `start` and derive stream
/// facts. Bounded scan: a file that is not MPEG audio costs 64 KB.
fn mpegStream(m: *Meta, in: Input, start: u64) void {
    var off = start;
    const limit = start +| 64 * 1024;
    var found: ?FrameHeader = null;
    var frame_off: u64 = 0;
    while (off < limit) : (off += 1) {
        const b = in.range(off, 4) orelse break;
        const fh = frameHeader(b) orelse continue;
        // Confirm with the next frame header where the window allows it;
        // a lone 11-bit sync pattern in tag padding is common.
        if (in.range(off + fh.frame_len, 4)) |nb| {
            if (frameHeader(nb) == null) continue;
        }
        found = fh;
        frame_off = off;
        break;
    }
    const fh = found orelse return;
    putRate(m, fh.sample_rate);
    putChannels(m, fh.channels);

    // Xing/Info (after the side info) or VBRI (fixed offset 36).
    var frames: u64 = 0;
    if (in.range(frame_off + 4 + fh.side_info, 12)) |x| {
        if (std.mem.eql(u8, x[0..4], "Xing") or std.mem.eql(u8, x[0..4], "Info")) {
            const flags = u32be(x[4..8]);
            if (flags & 1 != 0) frames = u32be(x[8..12]);
        }
    }
    if (frames == 0) {
        if (in.range(frame_off + 36, 18)) |v| {
            if (std.mem.eql(u8, v[0..4], "VBRI")) frames = u32be(v[14..18]);
        }
    }
    if (frames > 0 and frames < (1 << 32)) {
        putDuration(m, frames *| fh.samples *| 1000 / fh.sample_rate);
        return;
    }
    // No VBR header: a constant-bitrate estimate, labelled as such.
    const audio_bytes = in.size -| frame_off;
    if (audio_bytes == 0) return;
    putDuration(m, audio_bytes *| 8 / fh.bitrate_kbps);
    m.put("media.duration_estimated", "1");
}

fn id3v1(m: *Meta, in: Input) void {
    if (in.size < 128) return;
    const b = in.range(in.size - 128, 128) orelse return;
    if (!std.mem.eql(u8, b[0..3], "TAG")) return;
    m.putLatin1("tag.title", trimPad(b[3..33]));
    m.putLatin1("tag.artist", trimPad(b[33..63]));
    m.putLatin1("tag.album", trimPad(b[63..93]));
    m.putLatin1("tag.year", trimPad(b[93..97]));
    // ID3v1.1 steals the last two comment bytes for the track number.
    if (b[125] == 0 and b[126] != 0) m.putInt("tag.track", b[126]);
    m.putLatin1("tag.comment", trimPad(b[97..125]));
    if (b[127] < 126) m.put("tag.genre", genreName(b[127]));
}

fn trimPad(b: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, b, 0) orelse b.len;
    return std.mem.trim(u8, b[0..end], " ");
}

/// Strip ID3 unsynchronisation (FF 00 -> FF) into `out`.
fn deUnsync(src: []const u8, out: []u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len and n < out.len) {
        out[n] = src[i];
        n += 1;
        if (src[i] == 0xFF and i + 1 < src.len and src[i + 1] == 0x00) i += 2 else i += 1;
    }
    return out[0..n];
}

fn id3v2(m: *Meta, in: Input, major: u8, flags: u8, size: u32) void {
    if (major > 4) return;
    const body = in.range(10, @min(@as(usize, size), 1 << 20)) orelse return;
    var frames = body;
    // v2.2/v2.3 unsynchronise the WHOLE tag and store DECODED frame
    // sizes, so the body must be restored before walking. v2.4 keeps
    // per-frame unsync with stored sizes and must NOT be pre-decoded.
    if (flags & 0x80 != 0 and major < 4) {
        if (in.scratch.len < body.len) return; // no room: skip rather than misparse
        frames = deUnsync(body, in.scratch);
    }
    var off: usize = 0;
    // v2.3+ optional extended header.
    if (flags & 0x40 != 0 and major >= 3) {
        if (frames.len < 4) return;
        const ext = if (major == 4) syncsafe(frames[0..4]) else u32be(frames[0..4]) + 4;
        if (ext >= frames.len) return;
        off = ext;
    }
    const id_len: usize = if (major == 2) 3 else 4;
    const hdr_len: usize = if (major == 2) 6 else 10;
    var guard: usize = 0;
    while (off + hdr_len <= frames.len and guard < 128) : (guard += 1) {
        const id = frames[off..][0..id_len];
        if (id[0] == 0) return; // padding
        const fsize: u64 = if (major == 2)
            (@as(u32, frames[off + 3]) << 16) | (@as(u32, frames[off + 4]) << 8) | frames[off + 5]
        else if (major == 4)
            syncsafe(frames[off + 4 ..][0..4])
        else
            u32be(frames[off + 4 ..][0..4]);
        if (fsize == 0 or off + hdr_len + fsize > frames.len) return;
        var data = frames[off + hdr_len ..][0..@intCast(fsize)];
        if (major >= 3) {
            const fmt_flags = frames[off + 9];
            if (fmt_flags & 0x0C != 0) { // compressed or encrypted
                off += hdr_len + @as(usize, @intCast(fsize));
                continue;
            }
            if (major == 4) {
                if (fmt_flags & 0x01 != 0 and data.len >= 4) data = data[4..]; // data length indicator
                if ((fmt_flags & 0x02 != 0 or flags & 0x80 != 0) and in.scratch.len >= data.len)
                    data = deUnsync(data, in.scratch);
            }
        }
        id3Frame(m, id, data);
        off += hdr_len + @as(usize, @intCast(fsize));
    }
}

fn id3Key(id: []const u8) ?[]const u8 {
    const table = [_]struct { id: []const u8, key: []const u8 }{
        .{ .id = "TIT2", .key = "tag.title" },
        .{ .id = "TPE1", .key = "tag.artist" },
        .{ .id = "TALB", .key = "tag.album" },
        .{ .id = "TPE2", .key = "tag.album_artist" },
        .{ .id = "TCOM", .key = "tag.composer" },
        .{ .id = "TRCK", .key = "tag.track" },
        .{ .id = "TPOS", .key = "tag.disc" },
        .{ .id = "TCON", .key = "tag.genre" },
        .{ .id = "TYER", .key = "tag.year" },
        .{ .id = "TDRC", .key = "tag.year" },
        .{ .id = "TDRL", .key = "tag.year" },
        .{ .id = "COMM", .key = "tag.comment" },
        .{ .id = "TT2", .key = "tag.title" },
        .{ .id = "TP1", .key = "tag.artist" },
        .{ .id = "TAL", .key = "tag.album" },
        .{ .id = "TP2", .key = "tag.album_artist" },
        .{ .id = "TCM", .key = "tag.composer" },
        .{ .id = "TRK", .key = "tag.track" },
        .{ .id = "TPA", .key = "tag.disc" },
        .{ .id = "TCO", .key = "tag.genre" },
        .{ .id = "TYE", .key = "tag.year" },
        .{ .id = "COM", .key = "tag.comment" },
    };
    for (table) |row| {
        if (std.mem.eql(u8, row.id, id)) return row.key;
    }
    return null;
}

fn id3Frame(m: *Meta, id: []const u8, data_in: []const u8) void {
    const key = id3Key(id) orelse return;
    if (data_in.len < 2) return;
    const enc = data_in[0];
    var data = data_in[1..];
    // COMM/COM carry a 3-byte language and a NUL-terminated descriptor
    // before the actual comment.
    if (std.mem.eql(u8, key, "tag.comment")) {
        if (data.len < 3) return;
        data = data[3..];
        const term: usize = if (enc == 1 or enc == 2) 2 else 1;
        var i: usize = 0;
        while (i + term <= data.len) : (i += term) {
            if (std.mem.allEqual(u8, data[i..][0..term], 0)) break;
        }
        if (i + term > data.len) return;
        data = data[i + term ..];
    }
    var scratch: Meta = .{};
    switch (enc) {
        0 => scratch.putLatin1("v", data),
        1 => scratch.putUtf16("v", data, false),
        2 => scratch.putUtf16("v", data, true),
        3 => scratch.put("v", data),
        else => return,
    }
    const text = scratch.get("v") orelse return;
    if (std.mem.eql(u8, key, "tag.genre")) return putGenre(m, text);
    if (std.mem.eql(u8, key, "tag.year")) {
        if (text.len >= 4) m.put("tag.year", text[0..4]);
        return;
    }
    if (std.mem.eql(u8, key, "tag.track") or std.mem.eql(u8, key, "tag.disc")) {
        const slash = std.mem.indexOfScalar(u8, text, '/');
        m.put(key, if (slash) |s| text[0..s] else text);
        if (slash) |s| {
            if (std.mem.eql(u8, key, "tag.track")) m.put("tag.track_total", text[s + 1 ..]);
        }
        return;
    }
    m.put(key, text);
}

/// ID3 genres may be a name, a bare index, or the "(17)Rock" hybrid.
fn putGenre(m: *Meta, text: []const u8) void {
    const body = text;
    if (body.len >= 3 and body[0] == '(') {
        if (std.mem.indexOfScalar(u8, body, ')')) |close| {
            const parsed: ?u8 = std.fmt.parseInt(u8, body[1..close], 10) catch null;
            if (parsed) |idx| {
                if (close + 1 < body.len) {
                    m.put("tag.genre", body[close + 1 ..]);
                } else {
                    m.put("tag.genre", genreName(idx));
                }
                return;
            }
        }
    }
    const numeric: ?u8 = std.fmt.parseInt(u8, body, 10) catch null;
    if (numeric) |idx| {
        m.put("tag.genre", genreName(idx));
        return;
    }
    m.put("tag.genre", body);
}

const GENRES = [_][]const u8{
    "Blues",       "Classic Rock",      "Country",           "Dance",            "Disco",
    "Funk",        "Grunge",            "Hip-Hop",           "Jazz",             "Metal",
    "New Age",     "Oldies",            "Other",             "Pop",              "R&B",
    "Rap",         "Reggae",            "Rock",              "Techno",           "Industrial",
    "Alternative", "Ska",               "Death Metal",       "Pranks",           "Soundtrack",
    "Euro-Techno", "Ambient",           "Trip-Hop",          "Vocal",            "Jazz+Funk",
    "Fusion",      "Trance",            "Classical",         "Instrumental",     "Acid",
    "House",       "Game",              "Sound Clip",        "Gospel",           "Noise",
    "AlternRock",  "Bass",              "Soul",              "Punk",             "Space",
    "Meditative",  "Instrumental Pop",  "Instrumental Rock", "Ethnic",           "Gothic",
    "Darkwave",    "Techno-Industrial", "Electronic",        "Pop-Folk",         "Eurodance",
    "Dream",       "Southern Rock",     "Comedy",            "Cult",             "Gangsta",
    "Top 40",      "Christian Rap",     "Pop/Funk",          "Jungle",           "Native American",
    "Cabaret",     "New Wave",          "Psychadelic",       "Rave",             "Showtunes",
    "Trailer",     "Lo-Fi",             "Tribal",            "Acid Punk",        "Acid Jazz",
    "Polka",       "Retro",             "Musical",           "Rock & Roll",      "Hard Rock",
    "Folk",        "Folk-Rock",         "National Folk",     "Swing",            "Fast Fusion",
    "Bebob",       "Latin",             "Revival",           "Celtic",           "Bluegrass",
    "Avantgarde",  "Gothic Rock",       "Progressive Rock",  "Psychedelic Rock", "Symphonic Rock",
    "Slow Rock",   "Big Band",          "Chorus",            "Easy Listening",   "Acoustic",
    "Humour",      "Speech",            "Chanson",           "Opera",            "Chamber Music",
    "Sonata",      "Symphony",          "Booty Bass",        "Primus",           "Porn Groove",
    "Satire",      "Slow Jam",          "Club",              "Tango",            "Samba",
    "Folklore",    "Ballad",            "Power Ballad",      "Rhythmic Soul",    "Freestyle",
    "Duet",        "Punk Rock",         "Drum Solo",         "A capella",        "Euro-House",
    "Dance Hall",
};

/// Genre index to name; out-of-table indices render as the number so
/// the value is honest rather than invented.
fn genreName(idx: usize) []const u8 {
    if (idx < GENRES.len) return GENRES[idx];
    return "";
}

// ── FLAC / Ogg ──────────────────────────────────────────────────

fn flac(m: *Meta, in: Input) void {
    m.kind = .audio;
    m.put("media.format", "flac");
    flacBlocks(m, in, 4);
}

/// Walk FLAC metadata blocks from `start`.
fn flacBlocks(m: *Meta, in: Input, start: u64) void {
    var off = start;
    var guard: usize = 0;
    var total_samples: u64 = 0;
    var sample_rate: u32 = 0;
    while (guard < 32) : (guard += 1) {
        const hdr = in.range(off, 4) orelse break;
        const last = hdr[0] & 0x80 != 0;
        const btype = hdr[0] & 0x7F;
        const blen: usize = (@as(usize, hdr[1]) << 16) | (@as(usize, hdr[2]) << 8) | hdr[3];
        if (btype == 0 and blen >= 34) {
            const b = in.range(off + 4, 18) orelse break;
            sample_rate = (@as(u32, b[10]) << 12) | (@as(u32, b[11]) << 4) | (@as(u32, b[12]) >> 4);
            const channels: u8 = ((b[12] >> 1) & 7) + 1;
            const bps: u8 = @intCast((((@as(u16, b[12]) & 1) << 4) | (@as(u16, b[13]) >> 4)) + 1);
            total_samples = (@as(u64, b[13] & 0x0F) << 32) | (@as(u64, b[14]) << 24) |
                (@as(u64, b[15]) << 16) | (@as(u64, b[16]) << 8) | b[17];
            putRate(m, sample_rate);
            putChannels(m, channels);
            m.putInt("media.bit_depth", bps);
        } else if (btype == 4 and blen > 0) {
            if (in.range(off + 4, @min(blen, 64 * 1024))) |b| vorbisComment(m, b);
        }
        if (last) break;
        off += 4 + @as(u64, blen);
    }
    if (sample_rate == 0 or total_samples == 0) return;
    putDuration(m, total_samples *| 1000 / sample_rate);
}

/// Vorbis comment block: vendor string then a bounded key=value list.
fn vorbisComment(m: *Meta, b: []const u8) void {
    if (b.len < 8) return;
    const vendor_len = u32le(b[0..4]);
    var off: usize = 4 + @as(usize, vendor_len);
    if (off + 4 > b.len) return;
    var count = u32le(b[off..][0..4]);
    off += 4;
    if (count > 256) count = 256;
    for (0..count) |_| {
        if (off + 4 > b.len) return;
        const len = u32le(b[off..][0..4]);
        off += 4;
        if (len > b.len -| off) return;
        const item = b[off..][0..@intCast(len)];
        off += @intCast(len);
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse continue;
        vorbisField(m, item[0..eq], item[eq + 1 ..]);
    }
}

fn vorbisField(m: *Meta, name: []const u8, value: []const u8) void {
    var upper_buf: [32]u8 = undefined;
    if (name.len > upper_buf.len) return;
    for (name, 0..) |ch, i| upper_buf[i] = std.ascii.toUpper(ch);
    const upper = upper_buf[0..name.len];
    const table = [_]struct { name: []const u8, key: []const u8 }{
        .{ .name = "TITLE", .key = "tag.title" },
        .{ .name = "ARTIST", .key = "tag.artist" },
        .{ .name = "ALBUM", .key = "tag.album" },
        .{ .name = "ALBUMARTIST", .key = "tag.album_artist" },
        .{ .name = "COMPOSER", .key = "tag.composer" },
        .{ .name = "GENRE", .key = "tag.genre" },
        .{ .name = "TRACKNUMBER", .key = "tag.track" },
        .{ .name = "TRACKTOTAL", .key = "tag.track_total" },
        .{ .name = "TOTALTRACKS", .key = "tag.track_total" },
        .{ .name = "DISCNUMBER", .key = "tag.disc" },
        .{ .name = "COMMENT", .key = "tag.comment" },
        .{ .name = "DESCRIPTION", .key = "tag.comment" },
    };
    for (table) |row| {
        if (std.mem.eql(u8, row.name, upper)) return m.put(row.key, value);
    }
    if (std.mem.eql(u8, upper, "DATE") and value.len >= 4) m.put("tag.year", value[0..4]);
}

/// Strip Ogg page framing off the head so the logical packets can be
/// parsed as one buffer. Bounded by the caller's scratch.
fn oggUnpage(in: Input, out: []u8) []u8 {
    var off: u64 = 0;
    var n: usize = 0;
    var pages: usize = 0;
    while (pages < 16 and n < out.len) : (pages += 1) {
        const hdr = in.range(off, 27) orelse break;
        if (!std.mem.eql(u8, hdr[0..4], "OggS")) break;
        const nsegs: usize = hdr[26];
        const table = in.range(off + 27, nsegs) orelse break;
        var body: usize = 0;
        for (table) |s| body += s;
        const data = in.range(off + 27 + nsegs, body) orelse break;
        const take = @min(data.len, out.len - n);
        @memcpy(out[n..][0..take], data[0..take]);
        n += take;
        off += 27 + @as(u64, nsegs) + @as(u64, body);
    }
    return out[0..n];
}

fn ogg(m: *Meta, in: Input) void {
    m.kind = .audio;
    // Without caller scratch only the identification header is reachable
    // (channels/rate); comments need the second packet and thus room.
    var scratch_buf: [256]u8 = undefined;
    const scratch = if (in.scratch.len >= scratch_buf.len) in.scratch else &scratch_buf;
    const s = oggUnpage(in, scratch);
    var rate: u32 = 0;
    var opus = false;
    if (startsWith(s, "\x01vorbis") and s.len >= 28) {
        m.put("media.format", "ogg");
        putChannels(m, s[11]);
        rate = u32le(s[12..16]);
        putRate(m, rate);
    } else if (startsWith(s, "OpusHead") and s.len >= 16) {
        m.put("media.format", "opus");
        putChannels(m, s[9]);
        rate = 48000;
        putRate(m, u32le(s[12..16]));
        opus = true;
    } else if (startsWith(s, "\x7fFLAC")) {
        m.put("media.format", "flac");
        // The native FLAC stream (including "fLaC") starts at byte 9.
        if (std.mem.indexOf(u8, s, "fLaC")) |i| {
            var sub = in;
            sub.head = s;
            sub.tail = &.{};
            sub.size = s.len;
            flacBlocks(m, sub, @as(u64, i) + 4);
        }
        return;
    } else {
        m.put("media.format", "ogg");
    }
    // Comments live in the second logical packet; the signature search
    // is bounded by the unpaged buffer we already hold.
    if (std.mem.indexOf(u8, s, "\x03vorbis")) |i| {
        vorbisComment(m, s[i + 7 ..]);
    } else if (std.mem.indexOf(u8, s, "OpusTags")) |i| {
        vorbisComment(m, s[i + 8 ..]);
    }
    if (rate == 0) return;
    // Duration = the last page's granule position, read from the tail.
    if (in.tail.len < 27) return;
    var idx = in.tail.len - 27;
    while (true) : (idx -= 1) {
        if (std.mem.eql(u8, in.tail[idx..][0..4], "OggS")) {
            const granule = u64le(in.tail[idx + 6 ..][0..8]);
            if (granule != std.math.maxInt(u64))
                putDuration(m, granule *| 1000 / rate);
            return;
        }
        if (idx == 0) return;
    }
}

// ── RIFF audio/video ────────────────────────────────────────────

fn riffChunk(h: []const u8, want: []const u8) ?[]const u8 {
    var off: usize = 12;
    var guard: usize = 0;
    while (off + 8 <= h.len and guard < 32) : (guard += 1) {
        const id = h[off .. off + 4];
        const size = u32le(h[off + 4 .. off + 8]);
        const body = off + 8;
        if (std.mem.eql(u8, id, want)) {
            const avail = @min(@as(usize, size), h.len -| body);
            return h[body..][0..avail];
        }
        if (std.mem.eql(u8, id, "LIST") and body + 4 <= h.len) {
            off = body + 4; // descend
            continue;
        }
        const step = @as(usize, size) + (size & 1);
        if (step == 0) return null;
        off = body + step;
    }
    return null;
}

fn wav(m: *Meta, in: Input) void {
    m.kind = .audio;
    m.put("media.format", "wav");
    const fmt = riffChunk(in.head, "fmt ") orelse return;
    if (fmt.len < 16) return;
    const channels = u16le(fmt[2..4]);
    const rate = u32le(fmt[4..8]);
    const byte_rate = u32le(fmt[8..12]);
    putChannels(m, channels);
    putRate(m, rate);
    if (fmt.len >= 16) m.putInt("media.bit_depth", u16le(fmt[14..16]));
    if (byte_rate > 0) {
        // The data chunk length is authoritative; the file size is a
        // safe upper bound when the head window stops short of it.
        var data_bytes: u64 = in.size -| 44;
        var off: usize = 12;
        var guard: usize = 0;
        while (off + 8 <= in.head.len and guard < 32) : (guard += 1) {
            const id = in.head[off .. off + 4];
            const size = u32le(in.head[off + 4 .. off + 8]);
            if (std.mem.eql(u8, id, "data")) {
                data_bytes = size;
                break;
            }
            const step = @as(usize, size) + (size & 1);
            if (step == 0) break;
            off += 8 + step;
        }
        putDuration(m, data_bytes *| 1000 / byte_rate);
    }
    if (riffChunk(in.head, "INAM")) |v| m.putLatin1("tag.title", trimPad(v));
    if (riffChunk(in.head, "IART")) |v| m.putLatin1("tag.artist", trimPad(v));
    if (riffChunk(in.head, "IPRD")) |v| m.putLatin1("tag.album", trimPad(v));
}

fn avi(m: *Meta, in: Input) void {
    m.kind = .video;
    m.put("media.format", "avi");
    const avih = riffChunk(in.head, "avih") orelse return;
    if (avih.len < 40) return;
    const us_per_frame = u32le(avih[0..4]);
    const total_frames = u32le(avih[16..20]);
    putDims(m, u32le(avih[32..36]), u32le(avih[36..40]));
    if (us_per_frame > 0 and total_frames > 0)
        putDuration(m, @as(u64, us_per_frame) *| total_frames / 1000);
}

// ── formats we identify but hand to the job's external fallback ──

fn matroska(m: *Meta, in: Input) void {
    m.kind = .video;
    // The DocType string sits in the EBML header, well inside the head.
    const probe = in.head[0..@min(in.head.len, 256)];
    if (std.mem.indexOf(u8, probe, "webm") != null) {
        m.put("media.format", "webm");
    } else {
        m.put("media.format", "matroska");
    }
}

fn pdf(m: *Meta, in: Input) void {
    m.kind = .document;
    m.put("media.format", "pdf");
    if (in.head.len >= 8 and std.ascii.isDigit(in.head[5]) and in.head[6] == '.' and std.ascii.isDigit(in.head[7]))
        m.put("doc.version", in.head[5..8]);
}
