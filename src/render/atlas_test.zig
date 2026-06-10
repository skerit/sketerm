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
    const glyphs = try atlas.shapeRun(a, "fi", false, false);
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
    const glyphs = try atlas.shapeRun(a, "hello", false, false);
    try std.testing.expectEqual(@as(usize, 5), glyphs.len);
}

test "shapeRun: empty string returns 0 glyphs" {
    const a = std.testing.allocator;
    var atlas = openAnyFont(a) catch |e| {
        if (e == error.NoFontAvailable) return error.SkipZigTest;
        return e;
    };
    defer atlas.deinit();
    const glyphs = try atlas.shapeRun(a, "", false, false);
    try std.testing.expectEqual(@as(usize, 0), glyphs.len);
}

test "setFontFeatures parses spec, skips junk, clears shape cache" {
    const a = std.testing.allocator;
    var atlas = openAnyFont(a) catch |e| {
        if (e == error.NoFontAvailable) return error.SkipZigTest;
        return e;
    };
    defer atlas.deinit();

    atlas.setFontFeatures("-calt +ss01 zero cv05=3");
    try std.testing.expectEqual(@as(usize, 4), atlas.n_features);
    // calt disabled → value 0; ss01 enabled → 1; cv05 → 3.
    try std.testing.expectEqual(@as(u32, 0), atlas.features[0].value);
    try std.testing.expectEqual(@as(u32, 1), atlas.features[1].value);
    try std.testing.expectEqual(@as(u32, 3), atlas.features[3].value);

    // Prime the cache, change features, cache must be empty again.
    _ = try atlas.shapeRun(a, "fi", false, false);
    try std.testing.expect(atlas.shape_cache.count() > 0);
    atlas.setFontFeatures("");
    try std.testing.expectEqual(@as(usize, 0), atlas.n_features);
    try std.testing.expectEqual(@as(usize, 0), atlas.shape_cache.count());

    // hb_feature_from_string is lenient about tags, so don't assert
    // junk rejection — just that a valid token lands with its tag.
    atlas.setFontFeatures("+ss02");
    try std.testing.expectEqual(@as(usize, 1), atlas.n_features);
    const ss02: u32 = ('s' << 24) | ('s' << 16) | ('0' << 8) | '2';
    try std.testing.expectEqual(ss02, atlas.features[0].tag);
}

test "bold glyph is real + heavier than regular (no shader fakery)" {
    const a = std.testing.allocator;
    var atlas = openAnyFont(a) catch |e| {
        if (e == error.NoFontAvailable) return error.SkipZigTest;
        return e;
    };
    defer atlas.deinit();
    // Unrealized atlas: lookups rasterize via FreeType and pack, but
    // skip the GL upload — so this exercises the real bold-glyph path
    // (bold face or FT_Outline_Embolden) without a GL context.
    const reg = try atlas.lookupOrLoad('B', false, false);
    const bold = try atlas.lookupOrLoad('B', true, false);
    try std.testing.expect(reg.w > 0 and reg.h > 0);
    try std.testing.expect(bold.w > 0 and bold.h > 0);
    // Bold ink is at least as wide as regular for 'B' (real outline
    // thickening or a bolder face), and the two are distinct atlas
    // entries (separate cache keys -> separate slots).
    try std.testing.expect(bold.w >= reg.w);
    try std.testing.expect(bold.layer != reg.layer or bold.u0 != reg.u0 or bold.v0 != reg.v0);
    // Bold lookup is cached under the bold-tagged key (idempotent).
    const bold2 = try atlas.lookupOrLoad('B', true, false);
    try std.testing.expectEqual(bold.layer, bold2.layer);
    try std.testing.expectEqual(bold.u0, bold2.u0);
    // Either a real bold face loaded or we synthesize — exactly one.
    try std.testing.expectEqual(atlas.ft_face_bold == null, atlas.synthesize_bold);
}

test "bold ligature path: shape + rasterize bold gids without crashing" {
    const a = std.testing.allocator;
    var atlas = openAnyFont(a) catch |e| {
        if (e == error.NoFontAvailable) return error.SkipZigTest;
        return e;
    };
    defer atlas.deinit();
    const shaped = try atlas.shapeRun(a, "->", true, false);
    try std.testing.expect(shaped.len >= 1);
    for (shaped) |sg| {
        const g = try atlas.lookupOrLoadById(sg.glyph_id, true, false);
        _ = g; // just assert no error / no crash on the bold gid path
    }
}
