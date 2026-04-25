//! Tests for the HarfBuzz shaping wrapper. We need a real font on
//! disk, so these gate on one of the FONT_CANDIDATES being present
//! and skip otherwise (lets the suite still run on minimal systems).

const std = @import("std");
const Atlas = @import("atlas.zig").Atlas;

const FONT_CANDIDATES = [_][*:0]const u8{
    "/usr/share/fonts/TTF/Hack-Regular.ttf",
    "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf",
    "/usr/share/fonts/TTF/VeraMono.ttf",
    "/usr/share/fonts/gnu-free/FreeMono.otf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
};

fn openAnyFont(allocator: std.mem.Allocator) !*Atlas {
    for (FONT_CANDIDATES) |path| {
        if (Atlas.init(allocator, path, 14)) |a| {
            return a;
        } else |_| continue;
    }
    return error.NoFontAvailable;
}

test "shapeRun: 'fi' produces glyph IDs" {
    const a = std.testing.allocator;
    var atlas = openAnyFont(a) catch |e| {
        if (e == error.NoFontAvailable) return error.SkipZigTest;
        return e;
    };
    defer atlas.deinit();
    // Atlas owns the cached shape slice — do not free.
    const glyphs = try atlas.shapeRun(a, "fi");
    // We get either 2 glyphs (no ligature) or 1 (ligature). Either
    // is fine — assert we got something.
    try std.testing.expect(glyphs.len >= 1 and glyphs.len <= 2);
    // The first glyph's cluster is byte 0.
    try std.testing.expectEqual(@as(u32, 0), glyphs[0].cluster);
}

test "shapeRun: 'hello' produces 5 glyphs (no ligatures in monospace)" {
    const a = std.testing.allocator;
    var atlas = openAnyFont(a) catch |e| {
        if (e == error.NoFontAvailable) return error.SkipZigTest;
        return e;
    };
    defer atlas.deinit();
    const glyphs = try atlas.shapeRun(a, "hello");
    try std.testing.expectEqual(@as(usize, 5), glyphs.len);
}

test "shapeRun: empty string returns 0 glyphs" {
    const a = std.testing.allocator;
    var atlas = openAnyFont(a) catch |e| {
        if (e == error.NoFontAvailable) return error.SkipZigTest;
        return e;
    };
    defer atlas.deinit();
    const glyphs = try atlas.shapeRun(a, "");
    try std.testing.expectEqual(@as(usize, 0), glyphs.len);
}
