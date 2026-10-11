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

const screen_mod = @import("screen.zig");
const kitty_ph = @import("kitty_placeholder.zig");

/// 2x2 RGBA: (0,0)=red (1,0)=green (0,1)=blue (1,1)=white.
const quad_rgba = [_]u8{
    0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF,
    0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
};

/// Transmit `quad_rgba` as image `id` with a 2x2-cell virtual placement.
fn feedQuadImage(h: *Harness, id: u32) !void {
    var b64_buf: [32]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &quad_rgba);
    var tx_buf: [128]u8 = undefined;
    h.feed(try std.fmt.bufPrint(&tx_buf, "\x1b_Gi={d},a=T,U=1,f=32,s=2,v=2,c=2,r=2;{s}\x1b\\", .{ id, b64 }));
}

/// One placeholder cell with explicit row and column diacritics.
fn appendPlaceholder(list: *std.ArrayList(u8), a: std.mem.Allocator, img_row: usize, img_col: usize) !void {
    try appendCp(list, a, kitty_ph.PLACEHOLDER);
    try appendCp(list, a, @intCast(kitty_ph.diacritics[img_row]));
    try appendCp(list, a, @intCast(kitty_ph.diacritics[img_col]));
}

/// The placeholder runs on screen right now.
fn runsOf(h: *Harness) !std.ArrayList(screen_mod.PlaceholderRun) {
    var runs: std.ArrayList(screen_mod.PlaceholderRun) = .empty;
    errdefer runs.deinit(std.testing.allocator);
    try h.screen.collectPlaceholderRuns(std.testing.allocator, &runs);
    return runs;
}

// Kitty Unicode placeholder: a U=1 virtual placement registers without
// drawing; U+10EEEE cells then name their image cell, which the renderer
// resolves. Cell (0,0) with two "row 0 / col 0" diacritics shows the
// top-left tile, and nothing reaches the placement sink.
test "kitty unicode placeholder records the tile its cell shows" {
    const a = std.testing.allocator;
    var h = try Harness.init(a, 80, 24);
    defer h.deinit();
    h.arm();

    try feedQuadImage(&h, 5);
    // Virtual placement does NOT draw at the cursor.
    try std.testing.expect(!h.image.fired);
    try std.testing.expect(h.screen.kitty_images.get(5) != null);

    // fg = palette 5 (the image id), then U+10EEEE + row(0) + col(0)
    // diacritics, then a newline to finalize.
    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(a);
    try seq.appendSlice(a, "\x1b[38;5;5m");
    try appendPlaceholder(&seq, a, 0, 0);
    try seq.append(a, '\n');
    h.feed(seq.items);

    try std.testing.expect(!h.image.fired);
    const tile = h.screen.placeholderTileAt(&h.screen.active[0], 0).?;
    try std.testing.expectEqual(screen_mod.PlaceholderTile{ .image_id = 5, .img_row = 0, .img_col = 0 }, tile);
    try std.testing.expectEqual(screen_mod.Screen.PlaceholderGrid{ .cols = 2, .rows = 2 }, h.screen.placeholderGrid(5, 10, 20).?);
    var runs = try runsOf(&h);
    defer runs.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), runs.items.len);
    try std.testing.expectEqual(screen_mod.PlaceholderRun{ .display_row = 0, .col = 0, .len = 1, .image_id = 5, .img_row = 0, .img_col = 0 }, runs.items[0]);
}

// Column auto-increment: a second placeholder cell to the right with
// only a row diacritic continues to the next image column, so the two
// cells form one run.
test "kitty unicode placeholder auto-increments the column" {
    const a = std.testing.allocator;
    var h = try Harness.init(a, 80, 24);
    defer h.deinit();
    try feedQuadImage(&h, 6);

    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(a);
    try seq.appendSlice(a, "\x1b[38;5;6m");
    try appendPlaceholder(&seq, a, 0, 0);
    try appendCp(&seq, a, kitty_ph.PLACEHOLDER);
    try appendCp(&seq, a, @intCast(kitty_ph.diacritics[0])); // row 0 only -> col auto = 1
    try seq.append(a, '\n');
    h.feed(seq.items);

    try std.testing.expectEqual(@as(u16, 1), h.screen.placeholderTileAt(&h.screen.active[0], 1).?.img_col);
    var runs = try runsOf(&h);
    defer runs.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), runs.items.len);
    try std.testing.expectEqual(@as(u16, 2), runs.items[0].len);
    try std.testing.expectEqual(@as(u16, 0), runs.items[0].img_col);
}

// The order opencode's TUI uses: the frame's cells (with placeholders)
// are written BEFORE the upload and the U=1 placement. The tile must
// resolve once the image arrives, without the cells being printed again
// (the diff renderer never reprints unchanged cells), and the transmit
// itself must ask for a redraw.
test "placeholder cells printed before their image resolve when it arrives" {
    const a = std.testing.allocator;
    var h = try Harness.init(a, 20, 4);
    defer h.deinit();

    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(a);
    try seq.appendSlice(a, "\x1b[38;2;0;0;9m");
    try appendPlaceholder(&seq, a, 0, 0);
    try appendPlaceholder(&seq, a, 0, 1);
    try seq.appendSlice(a, "\x1b[m");
    h.feed(seq.items);

    try std.testing.expect(h.screen.placeholderTileAt(&h.screen.active[0], 0) != null);
    try std.testing.expect(h.screen.placeholderGrid(9, 10, 20) == null);
    h.screen.dirty = false;

    var b64_buf: [32]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &quad_rgba);
    var tx_buf: [128]u8 = undefined;
    h.feed(try std.fmt.bufPrint(&tx_buf, "\x1b_Ga=t,f=32,s=2,v=2,i=9,q=2;{s}\x1b\\", .{b64}));
    try std.testing.expect(h.screen.dirty);
    h.feed("\x1b_Ga=p,U=1,i=9,p=1,c=2,r=2,q=2\x1b\\");
    try std.testing.expectEqual(screen_mod.Screen.PlaceholderGrid{ .cols = 2, .rows = 2 }, h.screen.placeholderGrid(9, 10, 20).?);
    var runs = try runsOf(&h);
    defer runs.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), runs.items.len);
    try std.testing.expectEqual(@as(u16, 2), runs.items[0].len);
}

// Text written over a placeholder cell takes its tile with it. Before
// tiles were resolved per frame, every placeholder cell became a pinned
// placement that nothing ever removed.
test "text over a placeholder cell retires its tile" {
    const a = std.testing.allocator;
    var h = try Harness.init(a, 20, 4);
    defer h.deinit();
    try feedQuadImage(&h, 5);

    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(a);
    try seq.appendSlice(a, "\x1b[38;5;5m");
    try appendPlaceholder(&seq, a, 0, 0);
    try appendPlaceholder(&seq, a, 0, 1);
    try seq.appendSlice(a, "\x1b[m\x1b[1;2HX");
    h.feed(seq.items);

    try std.testing.expect(h.screen.placeholderTileAt(&h.screen.active[0], 0) != null);
    try std.testing.expect(h.screen.placeholderTileAt(&h.screen.active[0], 1) == null);
    // A placeholder of ANOTHER image printed over a recorded cell shows
    // the new tile, never the old one.
    seq.clearRetainingCapacity();
    try seq.appendSlice(a, "\x1b[1;1H\x1b[38;5;7m");
    try appendPlaceholder(&seq, a, 1, 1);
    // The next event is what completes a placeholder cell.
    try seq.appendSlice(a, "\x1b[m");
    h.feed(seq.items);
    try std.testing.expectEqual(screen_mod.PlaceholderTile{ .image_id = 7, .img_row = 1, .img_col = 1 }, h.screen.placeholderTileAt(&h.screen.active[0], 0).?);
}

// The reported bug, end to end: a TUI on the alternate screen scrolls its
// content by redrawing, so the image's placeholder cells move up a row
// and the cells they left are rewritten as blanks. Only the new position
// may show the image; the old rows show nothing.
test "a redrawn alt-screen frame leaves no stale placeholder rows" {
    const a = std.testing.allocator;
    var h = try Harness.init(a, 10, 6);
    defer h.deinit();
    try feedQuadImage(&h, 5);
    h.feed("\x1b[?1049h");

    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(a);
    // Frame 1: the image's top row only, on the bottom row.
    try frame.appendSlice(a, "\x1b[6;3H\x1b[38;5;5m");
    try appendPlaceholder(&frame, a, 0, 0);
    try appendPlaceholder(&frame, a, 0, 1);
    try frame.appendSlice(a, "\x1b[m");
    h.feed(frame.items);

    // Frame 2: scrolled by one row, so the image starts a row higher and
    // shows both rows; nothing else on the old row 5 but blanks.
    frame.clearRetainingCapacity();
    try frame.appendSlice(a, "\x1b[5;3H\x1b[38;5;5m");
    try appendPlaceholder(&frame, a, 0, 0);
    try appendPlaceholder(&frame, a, 0, 1);
    try frame.appendSlice(a, "\x1b[6;3H");
    try appendPlaceholder(&frame, a, 1, 0);
    try appendPlaceholder(&frame, a, 1, 1);
    try frame.appendSlice(a, "\x1b[m");
    h.feed(frame.items);

    var runs = try runsOf(&h);
    defer runs.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), runs.items.len);
    try std.testing.expectEqual(@as(u16, 4), runs.items[0].display_row);
    try std.testing.expectEqual(@as(u16, 0), runs.items[0].img_row);
    try std.testing.expectEqual(@as(u16, 5), runs.items[1].display_row);
    try std.testing.expectEqual(@as(u16, 1), runs.items[1].img_row);

    // Frame 3: the image scrolled off the top entirely (blanked rows).
    h.feed("\x1b[5;1H\x1b[2K\x1b[6;1H\x1b[2K");
    var gone = try runsOf(&h);
    defer gone.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), gone.items.len);
}

// Lines that scroll keep their tiles (they are keyed by the line's id),
// including into scrollback on the main screen.
test "placeholder tiles scroll with their line" {
    const a = std.testing.allocator;
    var h = try Harness.init(a, 10, 3);
    defer h.deinit();
    try feedQuadImage(&h, 5);

    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(a);
    try seq.appendSlice(a, "\x1b[3;1H\x1b[38;5;5m");
    try appendPlaceholder(&seq, a, 0, 0);
    try seq.appendSlice(a, "\x1b[m\r\n");
    h.feed(seq.items);

    var runs = try runsOf(&h);
    defer runs.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), runs.items.len);
    try std.testing.expectEqual(@as(u16, 1), runs.items[0].display_row);

    h.feed("\r\n\r\n");
    var scrolled_off = try runsOf(&h);
    defer scrolled_off.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), scrolled_off.items.len);
    // Scrolled back into view, it shows again.
    h.screen.view_offset = 1;
    var back = try runsOf(&h);
    defer back.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), back.items.len);
    try std.testing.expectEqual(@as(u16, 0), back.items[0].display_row);
}

// ICH/DCH move cells sideways; their tiles move with them, and the tile
// of a deleted cell goes.
test "insert and delete characters carry placeholder tiles with their cells" {
    const a = std.testing.allocator;
    var h = try Harness.init(a, 10, 3);
    defer h.deinit();
    try feedQuadImage(&h, 5);

    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(a);
    try seq.appendSlice(a, "\x1b[38;5;5m");
    try appendPlaceholder(&seq, a, 0, 0);
    try appendPlaceholder(&seq, a, 0, 1);
    try seq.appendSlice(a, "\x1b[m\x1b[1;1H\x1b[2@");
    h.feed(seq.items);

    const ln = &h.screen.active[0];
    try std.testing.expect(h.screen.placeholderTileAt(ln, 0) == null);
    try std.testing.expectEqual(@as(u16, 0), h.screen.placeholderTileAt(ln, 2).?.img_col);
    try std.testing.expectEqual(@as(u16, 1), h.screen.placeholderTileAt(ln, 3).?.img_col);

    // Delete the first image cell: the second slides into column 2.
    h.feed("\x1b[1;3H\x1b[P");
    try std.testing.expectEqual(@as(u16, 1), h.screen.placeholderTileAt(ln, 2).?.img_col);
    try std.testing.expect(h.screen.placeholderTileAt(ln, 3) == null);
}

// A main-screen resize reflows text; a placeholder cell keeps its tile
// on whatever line and column the reflow moved it to.
test "reflow carries a placeholder tile to its cell's new position" {
    const a = std.testing.allocator;
    var h = try Harness.init(a, 10, 3);
    defer h.deinit();
    try feedQuadImage(&h, 5);

    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(a);
    try seq.appendSlice(a, "abcdefgh\x1b[38;5;5m");
    try appendPlaceholder(&seq, a, 1, 1);
    try seq.appendSlice(a, "\x1b[m");
    h.feed(seq.items);
    try std.testing.expect(h.screen.placeholderTileAt(&h.screen.active[0], 8) != null);

    try h.screen.resize(5, 3);
    var runs = try runsOf(&h);
    defer runs.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), runs.items.len);
    try std.testing.expectEqual(@as(u16, 3), runs.items[0].col);
    try std.testing.expectEqual(@as(u16, 1), runs.items[0].img_row);
    try std.testing.expectEqual(@as(u16, 1), runs.items[0].img_col);
}

// Re-entering the alternate screen starts a new alt session: the tiles
// of the previous one are dropped, not left to accumulate.
test "re-entering the alternate screen drops the previous session's tiles" {
    const a = std.testing.allocator;
    var h = try Harness.init(a, 10, 3);
    defer h.deinit();
    try feedQuadImage(&h, 5);

    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(a);
    try seq.appendSlice(a, "\x1b[?1049h\x1b[38;5;5m");
    try appendPlaceholder(&seq, a, 0, 0);
    try seq.appendSlice(a, "\x1b[m\x1b[?1049l");
    h.feed(seq.items);
    try std.testing.expectEqual(@as(u32, 1), h.screen.ph_tiles.count());
    h.feed("\x1b[?1049h");
    try std.testing.expectEqual(@as(u32, 0), h.screen.ph_tiles.count());
}
