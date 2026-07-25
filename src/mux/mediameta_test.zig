//! Unit tests for `mediameta.zig`.
//!
//! Every sample is synthesised byte-for-byte here so the expectations
//! are derived from the format specs rather than from whatever happens
//! to be installed on the build host. The last section is the
//! adversarial pass: every sample truncated at every length and mutated
//! byte-wise, asserting the parsers stay bounded and never emit an
//! implausible value.

const std = @import("std");
const mm = @import("mediameta.zig");

const t = std.testing;
const alloc = std.testing.allocator;

// ── builders ────────────────────────────────────────────────────

const B = struct {
    list: std.ArrayList(u8) = .empty,

    fn deinit(self: *B) void {
        self.list.deinit(alloc);
    }

    fn s(self: *B, bytes: []const u8) void {
        self.list.appendSlice(alloc, bytes) catch unreachable;
    }

    fn b(self: *B, v: u8) void {
        self.list.append(alloc, v) catch unreachable;
    }

    fn be16(self: *B, v: u16) void {
        self.s(&.{ @intCast(v >> 8), @truncate(v) });
    }

    fn le16(self: *B, v: u16) void {
        self.s(&.{ @truncate(v), @intCast(v >> 8) });
    }

    fn be32(self: *B, v: u32) void {
        self.s(&.{ @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) });
    }

    fn le32(self: *B, v: u32) void {
        self.s(&.{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16), @truncate(v >> 24) });
    }

    fn le64(self: *B, v: u64) void {
        self.le32(@truncate(v));
        self.le32(@truncate(v >> 32));
    }

    fn word(self: *B, big: bool, v: u16) void {
        if (big) self.be16(v) else self.le16(v);
    }

    fn dword(self: *B, big: bool, v: u32) void {
        if (big) self.be32(v) else self.le32(v);
    }

    fn zeros(self: *B, n: usize) void {
        for (0..n) |_| self.b(0);
    }

    fn items(self: *B) []const u8 {
        return self.list.items;
    }
};

/// size + fourcc + body, the ISO-BMFF / QuickTime box framing.
fn box(out: *B, typ: []const u8, body: []const u8) void {
    out.be32(@intCast(8 + body.len));
    out.s(typ);
    out.s(body);
}

fn parse(bytes: []const u8, name: []const u8) mm.Meta {
    var scratch: [64 * 1024]u8 = undefined;
    return mm.extract(mm.Input.fromSlice(bytes, name, &scratch));
}

fn expectField(m: *const mm.Meta, key: []const u8, want: []const u8) !void {
    const got = m.get(key) orelse {
        std.debug.print("missing key {s}\n", .{key});
        return error.MissingField;
    };
    try t.expectEqualStrings(want, got);
}

// ── still images ────────────────────────────────────────────────

fn pngSample() B {
    var out = B{};
    out.s("\x89PNG\r\n\x1a\n");
    out.be32(13);
    out.s("IHDR");
    out.be32(320);
    out.be32(200);
    out.b(8); // bit depth
    out.b(6); // colour type
    out.s(&.{ 0, 0, 0 });
    out.be32(0); // crc placeholder
    return out;
}

test "png header yields dimensions and depth" {
    var s = pngSample();
    defer s.deinit();
    var m = parse(s.items(), "a.png");
    try t.expectEqual(mm.Kind.image, m.kind);
    try expectField(&m, "media.format", "png");
    try expectField(&m, "media.width", "320");
    try expectField(&m, "media.height", "200");
    try expectField(&m, "media.bit_depth", "8");
    try expectField(&m, "media.kind", "image");
}

fn gifSample() B {
    var out = B{};
    out.s("GIF89a");
    out.le16(64);
    out.le16(48);
    out.s(&.{ 0xF7, 0x00, 0x00 });
    return out;
}

test "gif logical screen descriptor" {
    var s = gifSample();
    defer s.deinit();
    var m = parse(s.items(), "a.gif");
    try expectField(&m, "media.width", "64");
    try expectField(&m, "media.height", "48");
}

fn bmpSample(core_header: bool) B {
    var out = B{};
    out.s("BM");
    out.le32(1000);
    out.le32(0);
    out.le32(54);
    if (core_header) {
        out.le32(12);
        out.le16(24);
        out.le16(12);
        out.le16(1);
        out.le16(24);
    } else {
        out.le32(40);
        out.le32(1024);
        out.le32(@bitCast(@as(i32, -768))); // top-down rows
        out.le16(1);
        out.le16(32);
        out.zeros(24);
    }
    return out;
}

test "bmp info and core headers, top-down height" {
    var s = bmpSample(false);
    defer s.deinit();
    var m = parse(s.items(), "a.bmp");
    try expectField(&m, "media.width", "1024");
    try expectField(&m, "media.height", "768");
    try expectField(&m, "media.bit_depth", "32");

    var s2 = bmpSample(true);
    defer s2.deinit();
    var m2 = parse(s2.items(), "a.bmp");
    try expectField(&m2, "media.width", "24");
    try expectField(&m2, "media.height", "12");
}

fn webpSample(variant: enum { x, lossy, lossless }) B {
    var out = B{};
    var body = B{};
    defer body.deinit();
    switch (variant) {
        .x => {
            body.s("VP8X");
            body.le32(10);
            body.s(&.{ 0x10, 0, 0, 0 });
            body.s(&.{ 0x3F, 0x00, 0x00 }); // width-1 = 63
            body.s(&.{ 0x1F, 0x00, 0x00 }); // height-1 = 31
        },
        .lossy => {
            body.s("VP8 ");
            body.le32(10);
            body.s(&.{ 0, 0, 0, 0x9D, 0x01, 0x2A });
            body.le16(200);
            body.le16(100);
        },
        .lossless => {
            body.s("VP8L");
            body.le32(5);
            body.b(0x2F);
            // 14 bits width-1 = 149, next 14 bits height-1 = 99.
            const bits: u32 = 149 | (@as(u32, 99) << 14);
            body.le32(bits);
        },
    }
    out.s("RIFF");
    out.le32(@intCast(4 + body.items().len));
    out.s("WEBP");
    out.s(body.items());
    return out;
}

test "webp extended, lossy and lossless dimensions" {
    var a = webpSample(.x);
    defer a.deinit();
    var ma = parse(a.items(), "a.webp");
    try expectField(&ma, "media.width", "64");
    try expectField(&ma, "media.height", "32");

    var b2 = webpSample(.lossy);
    defer b2.deinit();
    var mb = parse(b2.items(), "b.webp");
    try expectField(&mb, "media.width", "200");
    try expectField(&mb, "media.height", "100");

    var c2 = webpSample(.lossless);
    defer c2.deinit();
    var mc = parse(c2.items(), "c.webp");
    try expectField(&mc, "media.width", "150");
    try expectField(&mc, "media.height", "100");
}

// ── JPEG + EXIF ─────────────────────────────────────────────────

/// A complete little- or big-endian EXIF TIFF block with an IFD0, an
/// Exif sub-IFD and a GPS IFD. Offsets below are hand-laid-out; the
/// comments give the running position so the table stays checkable.
fn exifTiff(big: bool) B {
    var out = B{};
    out.s(if (big) "MM" else "II");
    out.word(big, 42);
    out.dword(big, 8); // IFD0 at 8

    // IFD0: 5 entries = 2 + 60 + 4 = 66 bytes, data area starts at 74.
    const make_off: u32 = 74; // "TestCam\0"      (8)
    const model_off: u32 = 82; // "Model-1\0"      (8)
    const exif_off: u32 = 90; // Exif sub-IFD
    // Exif IFD: 6 entries = 2 + 72 + 4 = 78 bytes -> data at 168.
    const exposure_off: u32 = 168; // rational      (8)
    const fnumber_off: u32 = 176; // rational       (8)
    const date_off: u32 = 184; // ASCII[20]         (20)
    const focal_off: u32 = 204; // rational         (8)
    const lens_off: u32 = 212; // "50mm Prime\0"    (11)
    const gps_off: u32 = 224; // GPS IFD: 2 entries = 2 + 24 + 4 = 30 -> data at 254
    const lat_off: u32 = 254; // 3 rationals        (24)
    const lon_off: u32 = 278; // 3 rationals        (24)

    out.word(big, 5); // IFD0 entry count
    entry(&out, big, 0x010F, 2, 8, make_off);
    entry(&out, big, 0x0110, 2, 8, model_off);
    entryInline(&out, big, 0x0112, 3, 1, 6); // orientation
    entry(&out, big, 0x8769, 4, 1, exif_off);
    entry(&out, big, 0x8825, 4, 1, gps_off);
    out.dword(big, 0); // no IFD1

    out.s("TestCam\x00");
    out.s("Model-1\x00");

    out.word(big, 6); // Exif IFD entry count
    entry(&out, big, 0x829A, 5, 1, exposure_off);
    entry(&out, big, 0x829D, 5, 1, fnumber_off);
    entryInline(&out, big, 0x8827, 3, 1, 800); // ISO
    entry(&out, big, 0x9003, 2, 20, date_off);
    entry(&out, big, 0x920A, 5, 1, focal_off);
    entry(&out, big, 0xA434, 2, 11, lens_off);
    out.dword(big, 0);

    out.dword(big, 1); // exposure 1/250
    out.dword(big, 250);
    out.dword(big, 28); // f/2.8
    out.dword(big, 10);
    out.s("2024:05:06 12:34:56\x00");
    out.dword(big, 35); // 35mm
    out.dword(big, 1);
    out.s("50mm Prime\x00");
    out.b(0); // pad to the GPS IFD offset

    out.word(big, 2); // GPS IFD entry count
    entry(&out, big, 0x0002, 5, 3, lat_off);
    entry(&out, big, 0x0004, 5, 3, lon_off);
    out.dword(big, 0);

    // 51 deg 30' 0" N, 4 deg 15' 30" E
    out.dword(big, 51);
    out.dword(big, 1);
    out.dword(big, 30);
    out.dword(big, 1);
    out.dword(big, 0);
    out.dword(big, 1);
    out.dword(big, 4);
    out.dword(big, 1);
    out.dword(big, 15);
    out.dword(big, 1);
    out.dword(big, 30);
    out.dword(big, 1);
    return out;
}

fn entry(out: *B, big: bool, tag: u16, typ: u16, count: u32, value_off: u32) void {
    out.word(big, tag);
    out.word(big, typ);
    out.dword(big, count);
    out.dword(big, value_off);
}

/// An entry whose value fits the 4-byte inline field. SHORTs occupy the
/// FIRST two bytes of that field, which differs per endianness.
fn entryInline(out: *B, big: bool, tag: u16, typ: u16, count: u32, value: u16) void {
    out.word(big, tag);
    out.word(big, typ);
    out.dword(big, count);
    if (typ == 3) {
        out.word(big, value);
        out.word(big, 0);
    } else {
        out.dword(big, value);
    }
}

fn jpegSample(big: bool, with_exif: bool) B {
    var out = B{};
    out.s(&.{ 0xFF, 0xD8 });
    if (with_exif) {
        var tiff = exifTiff(big);
        defer tiff.deinit();
        out.s(&.{ 0xFF, 0xE1 });
        out.be16(@intCast(2 + 6 + tiff.items().len));
        out.s("Exif\x00\x00");
        out.s(tiff.items());
    }
    // SOF0: precision, height, width, components.
    out.s(&.{ 0xFF, 0xC0 });
    out.be16(11);
    out.b(8);
    out.be16(1080);
    out.be16(1920);
    out.b(1);
    out.s(&.{ 1, 0x11, 0 });
    out.s(&.{ 0xFF, 0xDA });
    return out;
}

fn checkExif(m: *const mm.Meta) !void {
    try expectField(m, "exif.make", "TestCam");
    try expectField(m, "exif.model", "Model-1");
    try expectField(m, "exif.lens", "50mm Prime");
    try expectField(m, "image.orientation", "6");
    try expectField(m, "exif.datetime_original", "2024-05-06 12:34:56");
    try expectField(m, "exif.exposure_time", "1/250");
    try expectField(m, "exif.f_number", "2.8");
    try expectField(m, "exif.iso", "800");
    try expectField(m, "exif.focal_length", "35");
    try expectField(m, "exif.gps_lat", "51.500000");
    try expectField(m, "exif.gps_lon", "4.258333");
}

test "jpeg SOF dimensions and EXIF in both byte orders" {
    for ([_]bool{ false, true }) |big| {
        var s = jpegSample(big, true);
        defer s.deinit();
        var m = parse(s.items(), "a.jpg");
        try t.expectEqual(mm.Kind.image, m.kind);
        try expectField(&m, "media.format", "jpeg");
        try expectField(&m, "media.width", "1920");
        try expectField(&m, "media.height", "1080");
        try checkExif(&m);
    }
}

test "jpeg without EXIF still reports dimensions" {
    var s = jpegSample(false, false);
    defer s.deinit();
    var m = parse(s.items(), "a.jpg");
    try expectField(&m, "media.width", "1920");
    try t.expect(!m.has("exif.make"));
}

test "standalone tiff reads IFD0" {
    var s = exifTiff(false);
    defer s.deinit();
    var m = parse(s.items(), "a.tif");
    try t.expectEqual(mm.Kind.image, m.kind);
    try expectField(&m, "media.format", "tiff");
    try expectField(&m, "exif.make", "TestCam");
}

// ── ID3 / MP3 ───────────────────────────────────────────────────

fn syncsafe(out: *B, v: u32) void {
    out.s(&.{
        @intCast((v >> 21) & 0x7F),
        @intCast((v >> 14) & 0x7F),
        @intCast((v >> 7) & 0x7F),
        @intCast(v & 0x7F),
    });
}

fn textFrame(out: *B, major: u8, id: []const u8, enc: u8, payload: []const u8) void {
    out.s(id);
    const size: u32 = @intCast(1 + payload.len);
    if (major == 2) {
        out.s(&.{ @intCast(size >> 16), @truncate(size >> 8), @truncate(size) });
    } else if (major == 4) {
        syncsafe(out, size);
        out.s(&.{ 0, 0 });
    } else {
        out.be32(size);
        out.s(&.{ 0, 0 });
    }
    out.b(enc);
    out.s(payload);
}

/// One MPEG1 Layer III 128 kbps / 44.1 kHz stereo frame header.
const MP3_HEADER = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 };
const MP3_FRAME_LEN = 417;

fn mp3Sample(major: u8, unsync: bool, with_xing: bool, frames: u32) B {
    var body = B{};
    defer body.deinit();
    switch (major) {
        2 => {
            textFrame(&body, 2, "TT2", 0, "Old Title");
            textFrame(&body, 2, "TP1", 0, "Old Artist");
            textFrame(&body, 2, "TRK", 0, "3/9");
        },
        4 => {
            textFrame(&body, 4, "TIT2", 3, "UTF8 Title");
            textFrame(&body, 4, "TPE1", 3, "Bj\xc3\xb6rk");
            textFrame(&body, 4, "TALB", 3, "Album 4");
            textFrame(&body, 4, "TDRC", 3, "2019-08-01T10:00");
            textFrame(&body, 4, "TRCK", 3, "7/12");
            textFrame(&body, 4, "TCON", 3, "(17)");
        },
        else => {
            textFrame(&body, 3, "TIT2", 0, "Latin Title");
            // UTF-16LE with BOM, the common v2.3 encoding.
            textFrame(&body, 3, "TPE1", 1, "\xff\xfeA\x00r\x00t\x00i\x00s\x00t\x00");
            textFrame(&body, 3, "TALB", 0, "Album 3");
            textFrame(&body, 3, "TYER", 0, "2001");
            textFrame(&body, 3, "TRCK", 0, "5/11");
            textFrame(&body, 3, "TCON", 0, "(9)Metal");
            textFrame(&body, 3, "COMM", 0, "engShort\x00A comment");
        },
    }

    var stored = B{};
    defer stored.deinit();
    if (unsync) {
        // Re-synchronise: FF -> FF 00. v2.3 stores DECODED frame sizes,
        // so the walker must undo this before reading them.
        for (body.items()) |ch| {
            stored.b(ch);
            if (ch == 0xFF) stored.b(0);
        }
    } else {
        stored.s(body.items());
    }

    var out = B{};
    out.s("ID3");
    out.b(major);
    out.b(0);
    out.b(if (unsync) 0x80 else 0x00);
    syncsafe(&out, @intCast(stored.items().len));
    out.s(stored.items());

    // Audio frames.
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const start = out.items().len;
        out.s(&MP3_HEADER);
        if (i == 0 and with_xing) {
            out.zeros(32); // side info
            out.s("Xing");
            out.be32(1); // frames field present
            out.be32(frames);
        }
        out.zeros(MP3_FRAME_LEN - (out.items().len - start));
    }
    return out;
}

test "id3v2.3 text frames, utf-16, comment, genre and track split" {
    var s = mp3Sample(3, false, true, 100);
    defer s.deinit();
    var m = parse(s.items(), "a.mp3");
    try t.expectEqual(mm.Kind.audio, m.kind);
    try expectField(&m, "media.format", "mp3");
    try expectField(&m, "tag.title", "Latin Title");
    try expectField(&m, "tag.artist", "Artist");
    try expectField(&m, "tag.album", "Album 3");
    try expectField(&m, "tag.year", "2001");
    try expectField(&m, "tag.track", "5");
    try expectField(&m, "tag.track_total", "11");
    try expectField(&m, "tag.genre", "Metal");
    try expectField(&m, "tag.comment", "A comment");
    try expectField(&m, "media.sample_rate", "44100");
    try expectField(&m, "media.channels", "2");
    // 100 frames * 1152 samples / 44100 Hz.
    try expectField(&m, "media.duration_ms", "2612");
    try t.expect(!m.has("media.duration_estimated"));
}

test "id3v2.3 tag-level unsynchronisation is undone before frame walking" {
    var s = mp3Sample(3, true, true, 100);
    defer s.deinit();
    var m = parse(s.items(), "a.mp3");
    try expectField(&m, "tag.title", "Latin Title");
    try expectField(&m, "tag.album", "Album 3");
}

test "id3v2.3 unsync without scratch degrades instead of misparsing" {
    var s = mp3Sample(3, true, true, 100);
    defer s.deinit();
    var m = mm.extract(mm.Input.fromSlice(s.items(), "a.mp3", &.{}));
    try t.expect(!m.has("tag.title"));
    // The audio stream is still readable - only the tag was skipped.
    try expectField(&m, "media.sample_rate", "44100");
}

test "id3v2.4 syncsafe sizes, utf-8 text, TDRC year and numeric genre" {
    var s = mp3Sample(4, false, true, 250);
    defer s.deinit();
    var m = parse(s.items(), "a.mp3");
    try expectField(&m, "tag.title", "UTF8 Title");
    try expectField(&m, "tag.artist", "Bj\xc3\xb6rk");
    try expectField(&m, "tag.year", "2019");
    try expectField(&m, "tag.track", "7");
    try expectField(&m, "tag.track_total", "12");
    try expectField(&m, "tag.genre", "Rock");
    try expectField(&m, "media.duration_ms", "6530");
}

test "id3v2.2 three-character frame ids" {
    var s = mp3Sample(2, false, true, 10);
    defer s.deinit();
    var m = parse(s.items(), "a.mp3");
    try expectField(&m, "tag.title", "Old Title");
    try expectField(&m, "tag.artist", "Old Artist");
    try expectField(&m, "tag.track", "3");
}

fn id3v1Sample() B {
    var out = B{};
    // A bare CBR stream, then the trailing 128-byte v1 tag.
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        out.s(&MP3_HEADER);
        out.zeros(MP3_FRAME_LEN - 4);
    }
    out.s("TAG");
    padded(&out, "V1 Title", 30);
    padded(&out, "V1 Artist", 30);
    padded(&out, "V1 Album", 30);
    padded(&out, "1999", 4);
    padded(&out, "hello", 28);
    out.b(0);
    out.b(4); // track 4
    out.b(17); // Rock
    return out;
}

fn padded(out: *B, text: []const u8, width: usize) void {
    out.s(text);
    out.zeros(width - text.len);
}

test "id3v1 fallback and constant-bitrate duration estimate" {
    var s = id3v1Sample();
    defer s.deinit();
    var m = parse(s.items(), "a.mp3");
    try expectField(&m, "tag.title", "V1 Title");
    try expectField(&m, "tag.artist", "V1 Artist");
    try expectField(&m, "tag.album", "V1 Album");
    try expectField(&m, "tag.year", "1999");
    try expectField(&m, "tag.track", "4");
    try expectField(&m, "tag.genre", "Rock");
    try expectField(&m, "tag.comment", "hello");
    try expectField(&m, "media.bitrate_kbps", "128");
    // Estimated, and labelled so the browser can say so.
    try expectField(&m, "media.duration_estimated", "1");
    const ms = try std.fmt.parseInt(u64, m.get("media.duration_ms").?, 10);
    try t.expect(ms > 400 and ms < 700);
}

test "id3v2 tag values beat the id3v1 tag on the same file" {
    var s = mp3Sample(3, false, true, 100);
    defer s.deinit();
    var full = B{};
    defer full.deinit();
    full.s(s.items());
    full.s("TAG");
    padded(&full, "SHOULD NOT WIN", 30);
    full.zeros(95);
    var m = parse(full.items(), "a.mp3");
    try expectField(&m, "tag.title", "Latin Title");
}

// ── FLAC / Ogg ──────────────────────────────────────────────────

fn vorbisComments(out: *B, items: []const []const u8) void {
    out.le32(0); // empty vendor string
    out.le32(@intCast(items.len));
    for (items) |item| {
        out.le32(@intCast(item.len));
        out.s(item);
    }
}

fn flacSample() B {
    var comments = B{};
    defer comments.deinit();
    vorbisComments(&comments, &.{ "TITLE=Flac Song", "ARTIST=Flac Artist", "ALBUM=Flac Album", "DATE=2012-03-04", "TRACKNUMBER=2" });

    var out = B{};
    out.s("fLaC");
    out.b(0); // STREAMINFO, not last
    out.s(&.{ 0, 0, 34 });
    out.be16(4096);
    out.be16(4096);
    out.s(&.{ 0, 0, 0, 0, 0, 0 }); // min/max frame size
    // 44100 Hz, 2 channels, 16 bits, 88200 samples (2 seconds).
    out.s(&.{ 0x0A, 0xC4, 0x42, 0xF0, 0x00, 0x01, 0x58, 0x88 });
    out.zeros(16); // md5
    out.b(0x84); // VORBIS_COMMENT, last
    const n: u32 = @intCast(comments.items().len);
    out.s(&.{ @intCast(n >> 16), @truncate(n >> 8), @truncate(n) });
    out.s(comments.items());
    return out;
}

test "flac streaminfo and vorbis comments" {
    var s = flacSample();
    defer s.deinit();
    var m = parse(s.items(), "a.flac");
    try t.expectEqual(mm.Kind.audio, m.kind);
    try expectField(&m, "media.format", "flac");
    try expectField(&m, "media.sample_rate", "44100");
    try expectField(&m, "media.channels", "2");
    try expectField(&m, "media.bit_depth", "16");
    try expectField(&m, "media.duration_ms", "2000");
    try expectField(&m, "tag.title", "Flac Song");
    try expectField(&m, "tag.artist", "Flac Artist");
    try expectField(&m, "tag.album", "Flac Album");
    try expectField(&m, "tag.year", "2012");
    try expectField(&m, "tag.track", "2");
}

fn oggPage(out: *B, header_type: u8, granule: u64, seq: u32, data: []const u8) void {
    out.s("OggS");
    out.b(0);
    out.b(header_type);
    out.le64(granule);
    out.le32(0x1234); // serial
    out.le32(seq);
    out.le32(0); // crc (never validated: a checksum mismatch must not
    // hide metadata the user can plainly see in a player)
    var segs: usize = data.len / 255 + 1;
    if (data.len % 255 == 0 and data.len != 0) segs = data.len / 255;
    out.b(@intCast(segs));
    var left = data.len;
    for (0..segs) |_| {
        const take = @min(left, 255);
        out.b(@intCast(take));
        left -= take;
    }
    out.s(data);
}

fn oggVorbisSample() B {
    var ident = B{};
    defer ident.deinit();
    ident.s("\x01vorbis");
    ident.le32(0);
    ident.b(2); // channels
    ident.le32(44100);
    ident.le32(0); // max bitrate
    ident.le32(192000); // nominal bitrate
    ident.le32(0);
    ident.b(0xB8);
    ident.b(1);

    var comment = B{};
    defer comment.deinit();
    comment.s("\x03vorbis");
    vorbisComments(&comment, &.{ "TITLE=Ogg Song", "ARTIST=Ogg Artist", "DATE=2005" });
    comment.b(1);

    var out = B{};
    oggPage(&out, 2, 0, 0, ident.items());
    oggPage(&out, 0, 0, 1, comment.items());
    oggPage(&out, 4, 88200, 2, &.{0}); // EOS, 2 seconds at 44.1 kHz
    return out;
}

test "ogg vorbis identification, comments and granule duration" {
    var s = oggVorbisSample();
    defer s.deinit();
    var m = parse(s.items(), "a.ogg");
    try t.expectEqual(mm.Kind.audio, m.kind);
    try expectField(&m, "media.format", "ogg");
    try expectField(&m, "media.channels", "2");
    try expectField(&m, "media.sample_rate", "44100");
    try expectField(&m, "media.duration_ms", "2000");
    try expectField(&m, "tag.title", "Ogg Song");
    try expectField(&m, "tag.artist", "Ogg Artist");
    try expectField(&m, "tag.year", "2005");
}

fn oggOpusSample() B {
    var ident = B{};
    defer ident.deinit();
    ident.s("OpusHead");
    ident.b(1);
    ident.b(2); // channels
    ident.le16(312); // pre-skip
    ident.le32(48000);
    ident.le16(0);
    ident.b(0);

    var comment = B{};
    defer comment.deinit();
    comment.s("OpusTags");
    vorbisComments(&comment, &.{"TITLE=Opus Song"});

    var out = B{};
    oggPage(&out, 2, 0, 0, ident.items());
    oggPage(&out, 0, 0, 1, comment.items());
    oggPage(&out, 4, 144000, 2, &.{0}); // 3 seconds at the fixed 48 kHz clock
    return out;
}

test "ogg opus header, tags and 48 kHz granule clock" {
    var s = oggOpusSample();
    defer s.deinit();
    var m = parse(s.items(), "a.opus");
    try expectField(&m, "media.format", "opus");
    try expectField(&m, "media.channels", "2");
    try expectField(&m, "media.duration_ms", "3000");
    try expectField(&m, "tag.title", "Opus Song");
}

// ── ISO base media ──────────────────────────────────────────────

fn ilstText(out: *B, atom: []const u8, text: []const u8) void {
    var data = B{};
    defer data.deinit();
    data.be32(1); // well-known type 1 = UTF-8
    data.be32(0); // locale
    data.s(text);
    var item = B{};
    defer item.deinit();
    box(&item, "data", data.items());
    box(out, atom, item.items());
}

fn mp4Sample(brand: []const u8, video: bool) B {
    var mvhd = B{};
    defer mvhd.deinit();
    mvhd.b(0); // version 0
    mvhd.s(&.{ 0, 0, 0 });
    mvhd.be32(0); // creation
    mvhd.be32(0); // modification
    mvhd.be32(1000); // timescale
    mvhd.be32(5250); // duration -> 5250 ms
    mvhd.zeros(80);

    var tkhd = B{};
    defer tkhd.deinit();
    tkhd.b(0);
    tkhd.s(&.{ 0, 0, 7 });
    tkhd.zeros(72); // through the display matrix
    tkhd.be32(@as(u32, 640) << 16);
    tkhd.be32(@as(u32, 360) << 16);

    var hdlr = B{};
    defer hdlr.deinit();
    hdlr.be32(0);
    hdlr.be32(0);
    hdlr.s(if (video) "vide" else "soun");
    hdlr.zeros(12);

    var mdia = B{};
    defer mdia.deinit();
    box(&mdia, "hdlr", hdlr.items());

    var trak = B{};
    defer trak.deinit();
    if (video) box(&trak, "tkhd", tkhd.items());
    box(&trak, "mdia", mdia.items());

    var ilst = B{};
    defer ilst.deinit();
    ilstText(&ilst, "\xA9nam", "Mp4 Title");
    ilstText(&ilst, "\xA9ART", "Mp4 Artist");
    ilstText(&ilst, "\xA9alb", "Mp4 Album");
    ilstText(&ilst, "\xA9day", "2018-07-01");
    {
        var data = B{};
        defer data.deinit();
        data.be32(0); // binary
        data.be32(0);
        data.s(&.{ 0, 0, 0, 3, 0, 9, 0, 0 }); // track 3 of 9
        var item = B{};
        defer item.deinit();
        box(&item, "data", data.items());
        box(&ilst, "trkn", item.items());
    }

    var meta = B{};
    defer meta.deinit();
    meta.be32(0); // FullBox version+flags
    box(&meta, "ilst", ilst.items());

    var udta = B{};
    defer udta.deinit();
    box(&udta, "meta", meta.items());

    var moov = B{};
    defer moov.deinit();
    box(&moov, "mvhd", mvhd.items());
    box(&moov, "trak", trak.items());
    box(&moov, "udta", udta.items());

    var ftyp = B{};
    defer ftyp.deinit();
    ftyp.s(brand);
    ftyp.be32(512);
    ftyp.s(brand);

    var out = B{};
    box(&out, "ftyp", ftyp.items());
    box(&out, "mdat", "payload bytes");
    box(&out, "moov", moov.items());
    return out;
}

test "mp4 mvhd duration, tkhd dimensions and ilst tags" {
    var s = mp4Sample("isom", true);
    defer s.deinit();
    var m = parse(s.items(), "a.mp4");
    try t.expectEqual(mm.Kind.video, m.kind);
    try expectField(&m, "media.format", "mp4");
    try expectField(&m, "media.duration_ms", "5250");
    try expectField(&m, "media.width", "640");
    try expectField(&m, "media.height", "360");
    try expectField(&m, "tag.title", "Mp4 Title");
    try expectField(&m, "tag.artist", "Mp4 Artist");
    try expectField(&m, "tag.album", "Mp4 Album");
    try expectField(&m, "tag.year", "2018");
    try expectField(&m, "tag.track", "3");
    try expectField(&m, "tag.track_total", "9");
}

test "m4a brand with only a sound track reads as audio" {
    var s = mp4Sample("M4A ", false);
    defer s.deinit();
    var m = parse(s.items(), "a.m4a");
    try t.expectEqual(mm.Kind.audio, m.kind);
    try expectField(&m, "media.format", "m4a");
    try expectField(&m, "media.duration_ms", "5250");
    try t.expect(!m.has("media.width"));
}

test "mp4 tail-only moov is reachable through the tail window" {
    var s = mp4Sample("isom", true);
    defer s.deinit();
    const all = s.items();
    // Simulate a huge file: a head that stops inside mdat, plus the real
    // tail that carries moov (where every muxer that streams puts it).
    const split = std.mem.indexOf(u8, all, "moov").? - 4;
    var scratch: [4096]u8 = undefined;
    const in = mm.Input{
        // Head stops just past the mdat box header; the mdat payload in
        // between is deliberately NOT resident.
        .head = all[0..28],
        .tail = all[split..],
        .size = all.len,
        .name = "big.mp4",
        .scratch = &scratch,
    };
    var m = mm.extract(in);
    try expectField(&m, "media.duration_ms", "5250");
    try expectField(&m, "tag.title", "Mp4 Title");
}

test "mvhd version 1 uses the 64-bit layout" {
    var mvhd = B{};
    defer mvhd.deinit();
    mvhd.b(1);
    mvhd.s(&.{ 0, 0, 0 });
    mvhd.zeros(16); // 64-bit creation + modification
    mvhd.be32(600); // timescale
    mvhd.be32(0);
    mvhd.be32(1800); // duration (low half of the 64-bit value) -> 3000 ms
    mvhd.zeros(80);

    var moov = B{};
    defer moov.deinit();
    box(&moov, "mvhd", mvhd.items());

    var out = B{};
    defer out.deinit();
    var ftyp = B{};
    defer ftyp.deinit();
    ftyp.s("isom");
    ftyp.be32(0);
    box(&out, "ftyp", ftyp.items());
    box(&out, "moov", moov.items());

    var m = parse(out.items(), "a.mp4");
    try expectField(&m, "media.duration_ms", "3000");
}

// ── RIFF audio/video, documents ─────────────────────────────────

/// `payload` real PCM bytes follow the data header. The adversarial
/// pass uses 0 to keep its per-byte loops small; the unit test writes a
/// full second so the derived file bitrate is checkable.
fn wavSample(payload: usize) B {
    var out = B{};
    out.s("RIFF");
    out.le32(@intCast(36 + payload));
    out.s("WAVE");
    out.s("fmt ");
    out.le32(16);
    out.le16(1); // PCM
    out.le16(2); // channels
    out.le32(44100);
    out.le32(176400); // byte rate
    out.le16(4);
    out.le16(16); // bits
    out.s("data");
    out.le32(176400); // exactly one second of declared audio
    out.zeros(payload);
    return out;
}

test "wav fmt chunk and data-chunk duration" {
    var s = wavSample(176400);
    defer s.deinit();
    var m = parse(s.items(), "a.wav");
    try t.expectEqual(mm.Kind.audio, m.kind);
    try expectField(&m, "media.format", "wav");
    try expectField(&m, "media.channels", "2");
    try expectField(&m, "media.sample_rate", "44100");
    try expectField(&m, "media.bit_depth", "16");
    try expectField(&m, "media.duration_ms", "1000");
    try expectField(&m, "media.bitrate_kbps", "1411");
}

fn aviSample() B {
    var avih = B{};
    defer avih.deinit();
    avih.le32(33333); // microseconds per frame (30 fps)
    avih.zeros(12);
    avih.le32(300); // total frames -> 10 seconds
    avih.zeros(12);
    avih.le32(720);
    avih.le32(480);
    avih.zeros(16);

    var out = B{};
    out.s("RIFF");
    out.le32(0);
    out.s("AVI ");
    out.s("LIST");
    out.le32(@intCast(4 + 8 + avih.items().len));
    out.s("hdrl");
    out.s("avih");
    out.le32(@intCast(avih.items().len));
    out.s(avih.items());
    return out;
}

test "avi main header dimensions and duration" {
    var s = aviSample();
    defer s.deinit();
    var m = parse(s.items(), "a.avi");
    try t.expectEqual(mm.Kind.video, m.kind);
    try expectField(&m, "media.width", "720");
    try expectField(&m, "media.height", "480");
    try expectField(&m, "media.duration_ms", "9999");
}

test "pdf and matroska are identified without a demuxer" {
    var m = parse("%PDF-1.7\n1 0 obj\n", "a.pdf");
    try t.expectEqual(mm.Kind.document, m.kind);
    try expectField(&m, "media.format", "pdf");
    try expectField(&m, "doc.version", "1.7");

    var mk = parse("\x1a\x45\xdf\xa3\x01\x00\x00\x00webm\x00", "a.webm");
    try t.expectEqual(mm.Kind.video, mk.kind);
    try expectField(&mk, "media.format", "webm");
}

test "unrecognised content stays unknown" {
    const m = parse("just some text, nothing to see", "notes.txt");
    try t.expectEqual(mm.Kind.unknown, m.kind);
    try t.expectEqual(@as(usize, 0), m.count);
}

// ── value hygiene ───────────────────────────────────────────────

test "values are sanitised: control characters, NULs and overlong text" {
    var body = B{};
    defer body.deinit();
    const long = "y" ** 400;
    textFrame(&body, 3, "TIT2", 0, "Ti\x07tle\x00trailing");
    textFrame(&body, 3, "TALB", 0, long);
    textFrame(&body, 3, "TPE1", 0, "   ");

    var out = B{};
    defer out.deinit();
    out.s("ID3");
    out.b(3);
    out.b(0);
    out.b(0);
    syncsafe(&out, @intCast(body.items().len));
    out.s(body.items());

    var m = parse(out.items(), "a.mp3");
    // The bell becomes a space and the NUL terminates the value.
    try expectField(&m, "tag.title", "Ti tle");
    try t.expectEqual(@as(usize, mm.MAX_VALUE), m.get("tag.album").?.len);
    // Whitespace-only text is not a value.
    try t.expect(!m.has("tag.artist"));
}

test "invalid utf-8 in a declared utf-8 frame is dropped, not shipped" {
    var body = B{};
    defer body.deinit();
    textFrame(&body, 4, "TIT2", 3, "bad\xff\xfe\x80byte");
    textFrame(&body, 4, "TALB", 3, "good");

    var out = B{};
    defer out.deinit();
    out.s("ID3");
    out.b(4);
    out.b(0);
    out.b(0);
    syncsafe(&out, @intCast(body.items().len));
    out.s(body.items());

    var m = parse(out.items(), "a.mp3");
    try t.expect(!m.has("tag.title"));
    try expectField(&m, "tag.album", "good");
    for (0..m.count) |i| try t.expect(std.unicode.utf8ValidateSlice(m.value(i)));
}

test "field and value caps are enforced" {
    var m = mm.Meta{};
    var key_storage: [mm.MAX_FIELDS + 8][8]u8 = undefined;
    for (0..mm.MAX_FIELDS + 8) |i| {
        const key = std.fmt.bufPrint(&key_storage[i], "k{d}", .{i}) catch unreachable;
        m.put(key, "0123456789");
    }
    try t.expect(m.count <= mm.MAX_FIELDS);
    try t.expect(m.dropped);
    // First writer wins.
    var m2 = mm.Meta{};
    m2.put("k", "first");
    m2.put("k", "second");
    try expectField(&m2, "k", "first");
}

// ── adversarial pass ────────────────────────────────────────────

const Sample = struct { name: []const u8, bytes: []const u8 };

fn collectSamples(list: *std.ArrayList(B)) void {
    list.append(alloc, pngSample()) catch unreachable;
    list.append(alloc, gifSample()) catch unreachable;
    list.append(alloc, bmpSample(false)) catch unreachable;
    list.append(alloc, bmpSample(true)) catch unreachable;
    list.append(alloc, webpSample(.x)) catch unreachable;
    list.append(alloc, webpSample(.lossy)) catch unreachable;
    list.append(alloc, webpSample(.lossless)) catch unreachable;
    list.append(alloc, jpegSample(false, true)) catch unreachable;
    list.append(alloc, jpegSample(true, true)) catch unreachable;
    list.append(alloc, exifTiff(false)) catch unreachable;
    list.append(alloc, mp3Sample(3, false, true, 100)) catch unreachable;
    list.append(alloc, mp3Sample(3, true, true, 100)) catch unreachable;
    list.append(alloc, mp3Sample(4, false, true, 250)) catch unreachable;
    list.append(alloc, mp3Sample(2, false, false, 0)) catch unreachable;
    list.append(alloc, id3v1Sample()) catch unreachable;
    list.append(alloc, flacSample()) catch unreachable;
    list.append(alloc, oggVorbisSample()) catch unreachable;
    list.append(alloc, oggOpusSample()) catch unreachable;
    list.append(alloc, mp4Sample("isom", true)) catch unreachable;
    list.append(alloc, mp4Sample("M4A ", false)) catch unreachable;
    list.append(alloc, wavSample(0)) catch unreachable;
    list.append(alloc, aviSample()) catch unreachable;
}

/// Nothing a parser reports may be structurally impossible; a value
/// that survives to the wire is one the browser will render.
fn checkPlausible(m: *const mm.Meta) !void {
    for (0..m.count) |i| {
        const v = m.value(i);
        try t.expect(v.len <= mm.MAX_VALUE);
        try t.expect(std.unicode.utf8ValidateSlice(v));
    }
    if (m.get("media.width")) |w| {
        const n = try std.fmt.parseInt(u64, w, 10);
        try t.expect(n > 0 and n <= 1 << 20);
    }
    if (m.get("media.duration_ms")) |d| {
        const n = try std.fmt.parseInt(u64, d, 10);
        // No sample is longer than a month; anything above is a
        // misparse dressed up as data.
        try t.expect(n < 30 * 24 * 3600 * 1000);
    }
    if (m.get("image.orientation")) |o| {
        const n = try std.fmt.parseInt(u64, o, 10);
        try t.expect(n >= 1 and n <= 8);
    }
}

test "adversarial: every prefix of every sample parses safely" {
    var samples: std.ArrayList(B) = .empty;
    defer {
        for (samples.items) |*s| s.deinit();
        samples.deinit(alloc);
    }
    collectSamples(&samples);
    var scratch: [64 * 1024]u8 = undefined;
    for (samples.items) |*s| {
        const full = s.items();
        var len: usize = 0;
        while (len <= full.len) : (len += 1) {
            const m = mm.extract(mm.Input.fromSlice(full[0..len], "x.bin", &scratch));
            try checkPlausible(&m);
        }
    }
}

test "adversarial: single-byte mutations never produce nonsense" {
    var samples: std.ArrayList(B) = .empty;
    defer {
        for (samples.items) |*s| s.deinit();
        samples.deinit(alloc);
    }
    collectSamples(&samples);
    var scratch: [64 * 1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rand = prng.random();
    var mutated: std.ArrayList(u8) = .empty;
    defer mutated.deinit(alloc);
    for (samples.items) |*s| {
        const full = s.items();
        for (0..600) |_| {
            mutated.clearRetainingCapacity();
            try mutated.appendSlice(alloc, full);
            const hits = 1 + rand.uintLessThan(usize, 4);
            for (0..hits) |_| {
                const at = rand.uintLessThan(usize, mutated.items.len);
                mutated.items[at] = switch (rand.uintLessThan(u8, 4)) {
                    0 => 0xFF,
                    1 => 0x00,
                    2 => 0x80,
                    else => rand.int(u8),
                };
            }
            const m = mm.extract(mm.Input.fromSlice(mutated.items, "x.bin", &scratch));
            try checkPlausible(&m);
        }
    }
}

test "adversarial: hostile headers claiming absurd sizes" {
    var scratch: [4096]u8 = undefined;
    const hostile = [_][]const u8{
        // PNG claiming 4-gigapixel dimensions.
        "\x89PNG\r\n\x1a\n\xff\xff\xff\xffIHDR\xff\xff\xff\xff\xff\xff\xff\xff\x08\x06\x00\x00\x00",
        // JPEG with a zero-length segment (an infinite-loop invitation).
        "\xff\xd8\xff\xe1\x00\x00\xff\xc0\x00\x00",
        // JPEG APP1 claiming EXIF with a TIFF header pointing past the end.
        "\xff\xd8\xff\xe1\x00\x20Exif\x00\x00II\x2a\x00\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        // RIFF/WEBP with a chunk size larger than the file.
        "RIFF\x10\x00\x00\x00WEBPVP8X\xff\xff\xff\xff\x00",
        // ID3 header with a syncsafe size far past the end.
        "ID3\x03\x00\x00\x7f\x7f\x7f\x7f",
        // ID3v2.4 frame claiming a size that wraps the walker.
        "ID3\x04\x00\x00\x00\x00\x00\x20TIT2\x7f\x7f\x7f\x7f\x00\x00\x03hello",
        // Ogg page with a segment table longer than the file.
        "OggS\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff",
        // FLAC block claiming 16 MB of STREAMINFO.
        "fLaC\x00\xff\xff\xff",
        // mp4 box with size 1 (64-bit) but no extended size field.
        "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isom\x00\x00\x00\x01moov",
        // mp4 box whose 64-bit size is zero.
        "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isom\x00\x00\x00\x01moov\x00\x00\x00\x00\x00\x00\x00\x00",
        // WAV with a byte rate of zero (division guard).
        "RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x02\x00\x44\xac\x00\x00\x00\x00\x00\x00\x04\x00\x10\x00",
        // BMP with i32 minimum height (negation overflow).
        "BM\x00\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x28\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x80\x01\x00\x20\x00",
    };
    for (hostile) |bytes| {
        const m = mm.extract(mm.Input.fromSlice(bytes, "x.bin", &scratch));
        try checkPlausible(&m);
    }
}
