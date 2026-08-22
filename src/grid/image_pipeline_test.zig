//! Image pipeline integration tests — feed real kitty/iterm/sixel
//! escapes through Parser → Screen and confirm the on_image sink
//! fires with usable RGBA. No GL involvement; this proves the
//! "receive + decode" half of the path independently of rendering.

const std = @import("std");
const Harness = @import("../parser/test_harness.zig").Harness;

// 1×1 RGBA red, kitty graphics, single-chunk a=T f=32.
test "kitty f=32 single-chunk transmit_and_place fires sink" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    // 1×1 RGBA = 4 bytes. base64 encoded.
    const rgba = [_]u8{ 0xFF, 0x00, 0x00, 0xFF };
    var b64_buf: [16]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &rgba);

    var seq_buf: [128]u8 = undefined;
    const seq = try std.fmt.bufPrint(&seq_buf, "\x1b_Gi=42,a=T,f=32,s=1,v=1;{s}\x1b\\", .{b64});
    h.feed(seq);

    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u32, 1), h.image.width);
    try std.testing.expectEqual(@as(u32, 1), h.image.height);
    try std.testing.expectEqual(@as(u32, 42), h.image.image_id);
    try std.testing.expectEqual(@as(usize, 4), h.image.rgba.?.len);
    try std.testing.expectEqual(@as(u8, 0xFF), h.image.rgba.?[0]);
}

// f=24 (RGB) is expanded to RGBA inside the manager.
test "kitty f=24 single-chunk RGB fires sink with RGBA" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    // 2×1 RGB: red, green
    const rgb = [_]u8{ 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00 };
    var b64_buf: [32]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &rgb);

    var seq_buf: [128]u8 = undefined;
    const seq = try std.fmt.bufPrint(&seq_buf, "\x1b_Gi=7,a=T,f=24,s=2,v=1;{s}\x1b\\", .{b64});
    h.feed(seq);

    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u32, 2), h.image.width);
    try std.testing.expectEqual(@as(u32, 1), h.image.height);
    // 2 pixels × 4 bytes = 8 bytes of RGBA.
    try std.testing.expectEqual(@as(usize, 8), h.image.rgba.?.len);
    try std.testing.expectEqual(@as(u8, 0xFF), h.image.rgba.?[3]); // alpha
    try std.testing.expectEqual(@as(u8, 0xFF), h.image.rgba.?[7]);
}

// f=100 (PNG) — uses a real well-formed 1×1 PNG.
test "kitty f=100 PNG single-chunk fires sink" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    // 1×1 RGB red PNG (correct CRCs).
    const png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        // IHDR
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE,
        // IDAT — zlib-deflated single red pixel
        0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
        0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x01, 0x5A, 0xD2, 0x18, 0xF8,
        // IEND
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
        0xAE, 0x42, 0x60, 0x82,
    };
    var b64_buf: [128]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &png);

    var seq_buf: [256]u8 = undefined;
    const seq = try std.fmt.bufPrint(&seq_buf, "\x1b_Gi=99,a=T,f=100,m=0;{s}\x1b\\", .{b64});
    h.feed(seq);

    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u32, 1), h.image.width);
    try std.testing.expectEqual(@as(u32, 1), h.image.height);
    try std.testing.expectEqual(@as(u32, 99), h.image.image_id);
    try std.testing.expectEqual(@as(usize, 4), h.image.rgba.?.len);
}

// Multi-chunk PNG split across two escapes.
test "kitty f=100 PNG multi-chunk fires sink only after final chunk" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    const png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x00, 0x03, 0x00, 0x01, 0x5A, 0xD2, 0x18,
        0xF8, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    };
    var b64_buf: [128]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &png);
    const mid = b64.len / 2;

    var s1: [256]u8 = undefined;
    var s2: [256]u8 = undefined;
    const seq1 = try std.fmt.bufPrint(&s1, "\x1b_Gi=11,a=T,f=100,m=1;{s}\x1b\\", .{b64[0..mid]});
    const seq2 = try std.fmt.bufPrint(&s2, "\x1b_Gi=11,m=0;{s}\x1b\\", .{b64[mid..]});

    h.feed(seq1);
    try std.testing.expect(!h.image.fired); // shouldn't fire yet

    h.feed(seq2);
    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u32, 1), h.image.width);
    try std.testing.expectEqual(@as(u32, 1), h.image.height);
}

// a=t (transmit only) stores image; a=p later places it.
test "kitty a=t then a=p places previously-transmitted image" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    const rgba = [_]u8{ 0xFF, 0x00, 0xFF, 0xFF };
    var b64_buf: [16]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &rgba);

    var s1: [128]u8 = undefined;
    var s2: [64]u8 = undefined;
    const tx = try std.fmt.bufPrint(&s1, "\x1b_Gi=5,a=t,f=32,s=1,v=1;{s}\x1b\\", .{b64});
    const place = try std.fmt.bufPrint(&s2, "\x1b_Gi=5,a=p\x1b\\", .{});

    h.feed(tx);
    try std.testing.expect(!h.image.fired); // a=t alone doesn't fire on_image
    try std.testing.expect(h.screen.kitty_images.get(5) != null);

    h.feed(place);
    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u32, 1), h.image.width);
    try std.testing.expectEqual(@as(u32, 5), h.image.image_id);

    // Appending the second frame turns the stored image into active
    // playback and must notify the render host before its first tick.
    var frame_buf: [128]u8 = undefined;
    const frame = try std.fmt.bufPrint(&frame_buf, "\x1b_Gi=5,a=f,f=32,s=1,v=1;{s}\x1b\\", .{b64});
    h.feed(frame);
    try std.testing.expectEqual(@as(usize, 1), h.image.animation_changes);

    h.feed("\x1b_Gi=5,a=a,c=1\x1b\\");
    try std.testing.expectEqual(@as(usize, 2), h.image.animation_changes);
}

// Sixel via DCS — should also fire the same on_image sink.
test "sixel DCS payload fires sink" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    // Minimal sixel: P 0;0;0 q  " 1;1;2;2  #0;2;100;100;100  !2~  - !2~  ST
    // 2×2 image filled with white. DCS introducer is `P` (0x90) but we
    // write the 7-bit form: ESC P ... ESC \\
    const sx = "\x1bPq\"1;1;2;2#0;2;100;100;100!2~-!2~\x1b\\";
    h.feed(sx);

    try std.testing.expect(h.image.fired);
    try std.testing.expect(h.image.width >= 2);
    try std.testing.expect(h.image.height >= 1);
}

// DCS P2 = 0 (and its omitted-parameter default) means "pixels the
// data never paints take the current background colour"; P2 = 1 means
// leave them alone. Inverting these is the classic sixel bug, so both
// directions are pinned here with an explicit SGR background.
test "sixel P2=0 paints the current background behind the image" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    // SGR 48;2;0;0;255 = blue background, then a 2x6 sixel whose right
    // column is never painted.
    h.feed("\x1b[48;2;0;0;255m\x1bP0;0;0q#1;2;100;0;0#1~?\x1b\\");

    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u32, 2), h.image.width);
    const px = h.image.rgba.?;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, px[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, px[4..8]);
}

test "sixel P2=1 leaves unpainted pixels transparent" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    h.feed("\x1b[48;2;0;0;255m\x1bP0;1;0q#1;2;100;0;0#1~?\x1b\\");

    try std.testing.expect(h.image.fired);
    const px = h.image.rgba.?;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, px[0..4]);
    try std.testing.expectEqual(@as(u8, 0), px[7]); // alpha
}

test "sixel P2=2 behaves like P2=0" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    h.feed("\x1b[48;5;46m\x1bP0;2;0q#1;2;100;0;0#1~?\x1b\\");

    try std.testing.expect(h.image.fired);
    const px = h.image.rgba.?;
    try std.testing.expectEqual(@as(u8, 255), px[7]); // opaque fill
    // Palette index 46 resolved through the screen's 256-colour table.
    try std.testing.expectEqualSlices(u8, px[4..7], &h.screen.palette[46]);
}

test "sixel background select with a default background stays transparent" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    // No SGR background: the "current background" is whatever the pane
    // paints, which alpha 0 reproduces exactly.
    h.feed("\x1bP0;0;0q#1;2;100;0;0#1~?\x1b\\");

    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u8, 0), h.image.rgba.?[7]);
}

test "sixel P1 aspect ratio scales, and a raster attribute overrides it" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    // P1 = 2 -> 5:1, no raster attribute: 6 sixel rows -> 30 pixels.
    h.feed("\x1bP2;1;0q#1;2;100;0;0#1~\x1b\\");
    try std.testing.expectEqual(@as(u32, 30), h.image.height);

    // Same P1, but the body states 1:1 — the raster attribute wins.
    h.feed("\x1bP2;1;0q\"1;1;1;6#1;2;100;0;0#1~\x1b\\");
    try std.testing.expectEqual(@as(u32, 6), h.image.height);
}

test "sixel P3 is ignored" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    h.feed("\x1bP7;1;0q\"1;1;2;6#1;2;100;0;0#1~?\x1b\\");
    const w = h.image.width;
    const height = h.image.height;
    // A wildly different P3 changes nothing about the decode.
    h.feed("\x1bP7;1;9999q\"1;1;2;6#1;2;100;0;0#1~?\x1b\\");
    try std.testing.expectEqual(w, h.image.width);
    try std.testing.expectEqual(height, h.image.height);
}

// EmberGlyph pattern: multi-chunk transmit where continuation chunks
// drop the `i=` field. The kitty spec allows this; we route to the
// active in-progress transmit by id.
test "kitty multi-chunk: continuation chunks may omit i=" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    // 4×4 RGBA, 64 bytes — long enough to exercise chunking.
    var rgba: [64]u8 = undefined;
    @memset(&rgba, 0xC0);
    var b64_buf: [128]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &rgba);
    const mid = b64.len / 2;

    var s1: [256]u8 = undefined;
    var s2: [256]u8 = undefined;
    var s3: [128]u8 = undefined;

    // Emberglyph: a=t (transmit only) on first chunk, then bare `m=`
    // on continuations. After all chunks: a=p to place.
    const tx1 = try std.fmt.bufPrint(&s1, "\x1b_Gi=77,a=t,f=32,s=4,v=4,m=1;{s}\x1b\\", .{b64[0..mid]});
    const tx2 = try std.fmt.bufPrint(&s2, "\x1b_Gm=0;{s}\x1b\\", .{b64[mid..]});
    const place = try std.fmt.bufPrint(&s3, "\x1b_Ga=p,i=77,p=1,c=2,r=2,C=1\x1b\\", .{});

    h.feed(tx1);
    try std.testing.expect(!h.image.fired); // mid-transfer
    h.feed(tx2);
    try std.testing.expect(!h.image.fired); // a=t alone, no place
    try std.testing.expect(h.screen.kitty_images.get(77) != null);
    h.feed(place);
    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u32, 77), h.image.image_id);
    // Placement parameters should propagate.
    try std.testing.expectEqual(@as(u32, 2), h.image.cells_wide);
    try std.testing.expectEqual(@as(u32, 2), h.image.cells_high);
}

// Ensure cells_wide / cells_high arrive in the sink event so the
// renderer can scale.
test "kitty a=T,c=W,r=H propagates cell scale to sink" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();
    const rgba = [_]u8{ 0xFF, 0x00, 0x00, 0xFF };
    var b64_buf: [16]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &rgba);
    var seq_buf: [128]u8 = undefined;
    const seq = try std.fmt.bufPrint(&seq_buf, "\x1b_Gi=88,a=T,f=32,s=1,v=1,c=8,r=4;{s}\x1b\\", .{b64});
    h.feed(seq);
    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u32, 8), h.image.cells_wide);
    try std.testing.expectEqual(@as(u32, 4), h.image.cells_high);
}

// EmberGlyph regression: every frame the renderer sends
// `a=d,d=a` (delete all visible placements) then re-places via
// `a=p,i=N`. Per kitty spec, lowercase `d=a` deletes only the
// placements, NOT the source image data. Earlier code dropped the
// source image too, causing the second `a=p` to silently fail —
// "images don't render in real apps".
test "kitty d=a (lowercase) keeps source data — re-place succeeds" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    // Transmit only.
    const rgba = [_]u8{ 0x12, 0x34, 0x56, 0xFF };
    var b64_buf: [16]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &rgba);
    var s1: [128]u8 = undefined;
    const tx = try std.fmt.bufPrint(&s1, "\x1b_Gi=42,a=t,f=32,s=1,v=1;{s}\x1b\\", .{b64});
    h.feed(tx);
    try std.testing.expect(h.screen.kitty_images.get(42) != null);

    // First place — should fire sink.
    const place = "\x1b_Gi=42,a=p\x1b\\";
    h.feed(place);
    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u32, 42), h.image.image_id);

    // Reset capture flag.
    h.image.fired = false;

    // Lowercase `d=a` — delete all visible placements. Source data
    // for image 42 must remain so the re-place works.
    h.feed("\x1b_Ga=d,d=a,q=2;\x1b\\");
    try std.testing.expect(h.screen.kitty_images.get(42) != null);

    // Re-place — should fire again.
    h.feed(place);
    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u32, 42), h.image.image_id);
}

test "kitty d=A (uppercase) drops source data — re-place becomes a no-op" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    const rgba = [_]u8{ 0x12, 0x34, 0x56, 0xFF };
    var b64_buf: [16]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &rgba);
    var s1: [128]u8 = undefined;
    const tx = try std.fmt.bufPrint(&s1, "\x1b_Gi=42,a=t,f=32,s=1,v=1;{s}\x1b\\", .{b64});
    h.feed(tx);
    h.feed("\x1b_Gi=42,a=p\x1b\\");
    h.image.fired = false;

    // Uppercase A — also frees source data.
    h.feed("\x1b_Ga=d,d=A,q=2;\x1b\\");
    try std.testing.expect(h.screen.kitty_images.get(42) == null);

    // Re-place — Manager has nothing to place; sink does NOT fire.
    h.feed("\x1b_Gi=42,a=p\x1b\\");
    try std.testing.expect(!h.image.fired);
}

// iTerm2 OSC 1337 inline image — small PNG.
test "iterm2 OSC 1337 PNG fires sink" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    const png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x00, 0x03, 0x00, 0x01, 0x5A, 0xD2, 0x18,
        0xF8, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    };
    var b64_buf: [128]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &png);

    var seq_buf: [256]u8 = undefined;
    const seq = try std.fmt.bufPrint(&seq_buf, "\x1b]1337;File=name=t.png;inline=1:{s}\x1b\\", .{b64});
    h.feed(seq);

    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u32, 1), h.image.width);
    try std.testing.expectEqual(@as(u32, 1), h.image.height);
}

/// A 4x2 truecolour PNG — a 2:1 aspect, so a sizing request that keeps
/// the aspect is visible in the resulting cell counts.
const png_4x2 = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x02, 0x00, 0x00, 0x00, 0xF0, 0xCA, 0xEA, 0x34, 0x00, 0x00, 0x00,
    0x18, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0xB0, 0xA9, 0xD8,
    0xF2, 0x41, 0x27, 0x63, 0xC9, 0x03, 0x99, 0x88, 0x29, 0x0C, 0xC8, 0x1C,
    0x00, 0x89, 0x42, 0x0A, 0xF1, 0x52, 0x5E, 0x60, 0x67, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

/// Feed `png_4x2` through OSC 1337 with the given `File=` attributes on
/// an 80x24 grid of 8x16 pixel cells (a 640x384 window).
fn feedIterm(h: *Harness, attrs: []const u8) !void {
    h.screen.cell_pixel_w = 8;
    h.screen.cell_pixel_h = 16;
    h.image.fired = false;
    var b64_buf: [256]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &png_4x2);
    var seq_buf: [512]u8 = undefined;
    const seq = try std.fmt.bufPrint(&seq_buf, "\x1b]1337;File={s}:{s}\x1b\\", .{ attrs, b64 });
    h.feed(seq);
}

test "iterm2 sizing: every unit form reaches the placement as cells" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    // Bare number = cells. 4 cells = 32px wide, so 16px = 1 cell high.
    try feedIterm(&h, "inline=1;width=4");
    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u32, 4), h.image.width); // intrinsic
    try std.testing.expectEqual(@as(u32, 4), h.image.cells_wide);
    try std.testing.expectEqual(@as(u32, 1), h.image.cells_high);

    // Pixels: 64px = 8 cells, 32px = 2 cells.
    try feedIterm(&h, "inline=1;width=64px");
    try std.testing.expectEqual(@as(u32, 8), h.image.cells_wide);
    try std.testing.expectEqual(@as(u32, 2), h.image.cells_high);

    // Percent of the window: 50% of 640px = 320px = 40 cells.
    try feedIterm(&h, "inline=1;width=50%");
    try std.testing.expectEqual(@as(u32, 40), h.image.cells_wide);
    try std.testing.expectEqual(@as(u32, 10), h.image.cells_high);

    // Explicit auto on both axes is native size — no scaling at all.
    try feedIterm(&h, "inline=1;width=auto;height=auto");
    try std.testing.expectEqual(@as(u32, 0), h.image.cells_wide);
    try std.testing.expectEqual(@as(u32, 0), h.image.cells_high);
}

test "iterm2 sizing: preserveAspectRatio decides fit vs stretch" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();

    // Box 8x8 cells = 64x128px. The 2:1 image fits as 64x32px = 8x2.
    try feedIterm(&h, "inline=1;width=8;height=8");
    try std.testing.expectEqual(@as(u32, 8), h.image.cells_wide);
    try std.testing.expectEqual(@as(u32, 2), h.image.cells_high);

    // Same box, aspect waived: it fills the box exactly.
    try feedIterm(&h, "inline=1;width=8;height=8;preserveAspectRatio=0");
    try std.testing.expectEqual(@as(u32, 8), h.image.cells_wide);
    try std.testing.expectEqual(@as(u32, 8), h.image.cells_high);
}

test "iterm2 sizing: no size attributes still means native pixels" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();
    try feedIterm(&h, "inline=1;name=dC5wbmc=");
    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u32, 0), h.image.cells_wide);
    try std.testing.expectEqual(@as(u32, 0), h.image.cells_high);
}

test "iterm2: inline=0 is a file transfer, not a placement" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();
    // The protocol's default is inline=0, so an omitted key must be
    // dropped just the same as an explicit one.
    try feedIterm(&h, "inline=0;width=4");
    try std.testing.expect(!h.image.fired);
    try feedIterm(&h, "name=dC5wbmc=;size=81");
    try std.testing.expect(!h.image.fired);
}

// Append a codepoint's UTF-8 to an ArrayList — placeholder + diacritic
// helper for the Unicode-placeholder tests.
fn appendCp(list: *std.ArrayList(u8), a: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &buf);
    try list.appendSlice(a, buf[0..n]);
}

// Kitty Unicode placeholder: a U=1 virtual placement registers without
// drawing; U+10EEEE cells then tile the image. Cell (0,0) with two
// "row 0 / col 0" diacritics shows the top-left tile.
test "kitty unicode placeholder tiles the image" {
    const a = std.testing.allocator;
    var h = try Harness.init(a, 80, 24);
    defer h.deinit();
    h.arm();

    // 2×2 RGBA: (0,0)=red (1,0)=green (0,1)=blue (1,1)=white.
    const rgba = [_]u8{
        0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    };
    var b64_buf: [32]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &rgba);

    // Transmit + virtual placement: i=5, U=1, 2×2 cell grid (c=2,r=2).
    var tx_buf: [128]u8 = undefined;
    const tx = try std.fmt.bufPrint(&tx_buf, "\x1b_Gi=5,a=T,U=1,f=32,s=2,v=2,c=2,r=2;{s}\x1b\\", .{b64});
    h.feed(tx);
    // Virtual placement does NOT draw at the cursor.
    try std.testing.expect(!h.image.fired);
    try std.testing.expect(h.screen.kitty_images.get(5) != null);

    // fg = palette 5 (the image id), then U+10EEEE + row(0) + col(0)
    // diacritics (0x0305 = index 0), then a newline to finalize.
    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(a);
    try seq.appendSlice(a, "\x1b[38;5;5m");
    try appendCp(&seq, a, 0x10EEEE);
    try appendCp(&seq, a, 0x0305); // row 0
    try appendCp(&seq, a, 0x0305); // col 0
    try seq.append(a, '\n');
    h.feed(seq.items);

    try std.testing.expect(h.image.fired);
    // tile_w = 2/2 = 1, tile_h = 1 → single pixel.
    try std.testing.expectEqual(@as(u32, 1), h.image.width);
    try std.testing.expectEqual(@as(u32, 1), h.image.height);
    try std.testing.expectEqual(@as(u32, 5), h.image.image_id);
    try std.testing.expectEqual(@as(u32, 1), h.image.cells_wide);
    // Top-left tile is the red pixel.
    try std.testing.expectEqual(@as(u8, 0xFF), h.image.rgba.?[0]);
    try std.testing.expectEqual(@as(u8, 0x00), h.image.rgba.?[1]);
    try std.testing.expectEqual(@as(u8, 0x00), h.image.rgba.?[2]);
}

// Column auto-increment: a second placeholder cell to the right with
// only a row diacritic continues to the next image column.
test "kitty unicode placeholder auto-increments the column" {
    const a = std.testing.allocator;
    var h = try Harness.init(a, 80, 24);
    defer h.deinit();
    h.arm();

    const rgba = [_]u8{
        0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    };
    var b64_buf: [32]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &rgba);
    var tx_buf: [128]u8 = undefined;
    const tx = try std.fmt.bufPrint(&tx_buf, "\x1b_Gi=6,a=T,U=1,f=32,s=2,v=2,c=2,r=2;{s}\x1b\\", .{b64});
    h.feed(tx);

    // Two placeholder cells: first row 0 col 0 (explicit), second only a
    // row(0) diacritic → column auto-increments to 1 (the green pixel).
    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(a);
    try seq.appendSlice(a, "\x1b[38;5;6m");
    try appendCp(&seq, a, 0x10EEEE);
    try appendCp(&seq, a, 0x0305); // row 0
    try appendCp(&seq, a, 0x0305); // col 0
    try appendCp(&seq, a, 0x10EEEE);
    try appendCp(&seq, a, 0x0305); // row 0 only → col auto = 1
    try seq.append(a, '\n');
    h.feed(seq.items);

    // The last tile emitted is image column 1 = the green pixel.
    try std.testing.expect(h.image.fired);
    try std.testing.expectEqual(@as(u8, 0x00), h.image.rgba.?[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), h.image.rgba.?[1]);
    try std.testing.expectEqual(@as(u8, 0x00), h.image.rgba.?[2]);
}
