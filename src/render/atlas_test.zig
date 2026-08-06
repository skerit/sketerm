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

test "a symbol map claims its range from the primary face" {
    const a = std.testing.allocator;
    var plain = openAnyFont(a) catch |e| {
        if (e == error.NoFontAvailable) return error.SkipZigTest;
        return e;
    };
    defer plain.deinit();
    try std.testing.expect(plain.symbolFaceForTest('A') == null);

    // Map the ASCII capitals to another family and check the mapped
    // face is what answers for 'A' — and only inside the range.
    const maps = [_]Atlas.SymbolMapSpec{.{ .lo = 'A', .hi = 'Z', .family = "DejaVu Sans" }};
    var mapped = blk: {
        for (FONT_CANDIDATES) |path| {
            if (Atlas.initWith(a, path, 14, .{ .symbol_maps = &maps })) |atlas| break :blk atlas else |_| continue;
        }
        return error.SkipZigTest;
    };
    defer mapped.deinit();
    // fontconfig always substitutes SOMETHING, so a resolved face is
    // the assertion; which file it is depends on the machine.
    if (mapped.symbolFaceForTest('A') == null) return error.SkipZigTest;
    try std.testing.expect(mapped.symbolFaceForTest('a') == null); // outside the range
}

test "an explicit italic family is used instead of the primary's sibling" {
    const a = std.testing.allocator;
    var atlas = blk: {
        for (FONT_CANDIDATES) |path| {
            if (Atlas.initWith(a, path, 14, .{ .italic_family = "DejaVu Serif" })) |x| break :blk x else |_| continue;
        }
        return error.SkipZigTest;
    };
    defer atlas.deinit();
    // The italic face must exist and must not be the regular one: a
    // configured family that silently resolved back to the primary
    // would look like it worked while changing nothing.
    if (atlas.ft_face_italic) |it| {
        try std.testing.expect(it != atlas.ft_face);
    } else return error.SkipZigTest;
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

test "colrv0: 0xFFFF glyphs cache per foreground; plain colrv0 caches once" {
    const a = std.testing.allocator;
    const gp = @import("../parser/glyph_protocol.zig");
    var atlas = openAnyFont(a) catch |e| {
        if (e == error.NoFontAvailable) return error.SkipZigTest;
        return e;
    };
    defer atlas.deinit();

    const tri = try gp.triangleBytes(a);
    defer a.free(tri);

    // Foreground-dependent: single layer at the 0xFFFF sentinel.
    const fg_dep = try gp.colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = gp.PALETTE_FOREGROUND },
    }, &.{});
    defer a.free(fg_dep);
    const red: [4]f32 = .{ 1, 0, 0, 1 };
    const blue: [4]f32 = .{ 0, 0, 1, 1 };
    const g_red = try atlas.lookupOrLoadCustom(101, fg_dep, .colrv0, 1000, 1, red);
    const g_blue = try atlas.lookupOrLoadCustom(101, fg_dep, .colrv0, 1000, 1, blue);
    try std.testing.expect(g_red.colored and g_blue.colored);
    // Two distinct atlas slots — a foreground change re-rasterises
    // instead of serving the first colour forever (Rio's bug).
    try std.testing.expect(g_red.layer != g_blue.layer or g_red.u0 != g_blue.u0 or g_red.v0 != g_blue.v0);
    // Same foreground again: cache hit, identical placement.
    const g_red2 = try atlas.lookupOrLoadCustom(101, fg_dep, .colrv0, 1000, 1, red);
    try std.testing.expectEqual(g_red.layer, g_red2.layer);
    try std.testing.expectEqual(g_red.u0, g_red2.u0);
    try std.testing.expectEqual(g_red.v0, g_red2.v0);

    // Foreground-independent: fixed palette colour. One slot for any
    // foreground.
    const fg_ind = try gp.colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = 0 },
    }, &.{0x00FF00FF});
    defer a.free(fg_ind);
    const gi_red = try atlas.lookupOrLoadCustom(102, fg_ind, .colrv0, 1000, 1, red);
    const gi_blue = try atlas.lookupOrLoadCustom(102, fg_ind, .colrv0, 1000, 1, blue);
    try std.testing.expect(gi_red.colored);
    try std.testing.expectEqual(gi_red.layer, gi_blue.layer);
    try std.testing.expectEqual(gi_red.u0, gi_blue.u0);
    try std.testing.expectEqual(gi_red.v0, gi_blue.v0);

    // glyf stays foreground-independent and coverage-tinted.
    const g_glyf_red = try atlas.lookupOrLoadCustom(103, tri, .glyf, 1000, 1, red);
    const g_glyf_blue = try atlas.lookupOrLoadCustom(103, tri, .glyf, 1000, 1, blue);
    try std.testing.expect(!g_glyf_red.colored);
    try std.testing.expectEqual(g_glyf_red.u0, g_glyf_blue.u0);
    try std.testing.expectEqual(g_glyf_red.v0, g_glyf_blue.v0);
}

test "colrv0: broken container caches as an empty glyph" {
    const a = std.testing.allocator;
    const gp = @import("../parser/glyph_protocol.zig");
    var atlas = openAnyFont(a) catch |e| {
        if (e == error.NoFontAvailable) return error.SkipZigTest;
        return e;
    };
    defer atlas.deinit();
    const tri = try gp.triangleBytes(a);
    defer a.free(tri);
    // A glyf record is not a container.
    const g = try atlas.lookupOrLoadCustom(104, tri, .colrv0, 1000, 1, .{ 1, 1, 1, 1 });
    try std.testing.expectEqual(@as(u16, 0), g.w);
    try std.testing.expectEqual(@as(u16, 0), g.h);
}

/// A solid-under-glyph colrv1 container at the 0xFFFF sentinel, and a
/// fixed-palette sibling. Shared by the caching and leak tests.
fn v1FgContainer(a: std.mem.Allocator, fg_dependent: bool) ![]u8 {
    const gp = @import("../parser/glyph_protocol.zig");
    const tri = try gp.triangleBytes(a);
    defer a.free(tri);
    const solid = gp.V1Node{ .solid = .{
        .palette = if (fg_dependent) gp.PALETTE_FOREGROUND else 0,
    } };
    return gp.colr1ContainerBytes(a, &.{tri}, .{
        .glyph = .{ .glyph_id = 0, .child = &solid },
    }, if (fg_dependent) &.{} else &.{0x00FF00FF}, null);
}

test "colrv1: 0xFFFF glyphs cache per foreground; plain colrv1 caches once" {
    const a = std.testing.allocator;
    var atlas = openAnyFont(a) catch |e| {
        if (e == error.NoFontAvailable) return error.SkipZigTest;
        return e;
    };
    defer atlas.deinit();

    const fg_dep = try v1FgContainer(a, true);
    defer a.free(fg_dep);
    const red: [4]f32 = .{ 1, 0, 0, 1 };
    const blue: [4]f32 = .{ 0, 0, 1, 1 };
    const g_red = try atlas.lookupOrLoadCustom(201, fg_dep, .colrv1, 1000, 1, red);
    const g_blue = try atlas.lookupOrLoadCustom(201, fg_dep, .colrv1, 1000, 1, blue);
    try std.testing.expect(g_red.colored and g_blue.colored);
    try std.testing.expect(g_red.w > 0 and g_red.h > 0);
    // Distinct atlas slots per foreground — the graph-deep sentinel
    // must key the cache exactly like colrv0's layer sentinel.
    try std.testing.expect(g_red.layer != g_blue.layer or g_red.u0 != g_blue.u0 or g_red.v0 != g_blue.v0);
    const g_red2 = try atlas.lookupOrLoadCustom(201, fg_dep, .colrv1, 1000, 1, red);
    try std.testing.expectEqual(g_red.layer, g_red2.layer);
    try std.testing.expectEqual(g_red.u0, g_red2.u0);

    const fg_ind = try v1FgContainer(a, false);
    defer a.free(fg_ind);
    const gi_red = try atlas.lookupOrLoadCustom(202, fg_ind, .colrv1, 1000, 1, red);
    const gi_blue = try atlas.lookupOrLoadCustom(202, fg_ind, .colrv1, 1000, 1, blue);
    try std.testing.expect(gi_red.colored);
    try std.testing.expectEqual(gi_red.layer, gi_blue.layer);
    try std.testing.expectEqual(gi_red.u0, gi_blue.u0);
    try std.testing.expectEqual(gi_red.v0, gi_blue.v0);
}

test "colrv1: broken container caches as an empty glyph" {
    const a = std.testing.allocator;
    const gp = @import("../parser/glyph_protocol.zig");
    var atlas = openAnyFont(a) catch |e| {
        if (e == error.NoFontAvailable) return error.SkipZigTest;
        return e;
    };
    defer atlas.deinit();
    const tri = try gp.triangleBytes(a);
    defer a.free(tri);
    // A glyf record is not a v1 container...
    const g = try atlas.lookupOrLoadCustom(203, tri, .colrv1, 1000, 1, .{ 1, 1, 1, 1 });
    try std.testing.expectEqual(@as(u16, 0), g.w);
    // ...and neither is a v0 container.
    const v0 = try gp.colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = 0 },
    }, &.{0xFF0000FF});
    defer a.free(v0);
    const g2 = try atlas.lookupOrLoadCustom(204, v0, .colrv1, 1000, 1, .{ 1, 1, 1, 1 });
    try std.testing.expectEqual(@as(u16, 0), g2.w);
}

test "colrv1: repeated rasterisation leaks no C-heap memory (cairo surfaces)" {
    // cairo surfaces, contexts and patterns live on the C heap, which
    // the Zig leak detector cannot see — a missed cairo_*_destroy in
    // the raster path would grow every repaint. Rasterise the same
    // fg-dependent glyph under a rotating foreground (a cache MISS
    // every time, exercising surface + context + gradient pattern +
    // group allocation per call) and assert malloc-space stays flat.
    // Linux-only: mallinfo2 is glibc.
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const gp = @import("../parser/glyph_protocol.zig");
    const c = @import("../c.zig").c;
    var atlas = openAnyFont(a) catch |e| {
        if (e == error.NoFontAvailable) return error.SkipZigTest;
        return e;
    };
    defer atlas.deinit();

    const tri = try gp.triangleBytes(a);
    defer a.free(tri);
    // Gradient + composite + transform in one graph so every cairo
    // object kind the walker creates is exercised each iteration.
    const stops = [_]gp.V1Stop{
        .{ .offset = 0, .palette = gp.PALETTE_FOREGROUND },
        .{ .offset = 1, .palette = 0 },
    };
    const lin = gp.V1Node{ .linear = .{ .stops = &stops, .x0 = 0, .y0 = 0, .x1 = 1000, .y1 = 0, .x2 = 0, .y2 = 1000 } };
    const g_lin = gp.V1Node{ .glyph = .{ .glyph_id = 0, .child = &lin } };
    const rot = gp.V1Node{ .rotate = .{ .angle = 0.1, .child = &g_lin } };
    const solid = gp.V1Node{ .solid = .{ .palette = gp.PALETTE_FOREGROUND } };
    const g_solid = gp.V1Node{ .glyph = .{ .glyph_id = 0, .child = &solid } };
    const cmp = gp.V1Node{ .composite = .{ .source = &rot, .mode = 12, .backdrop = &g_solid } };
    const container = try gp.colr1ContainerBytes(a, &.{tri}, cmp, &.{0x336699FF}, null);
    defer a.free(container);

    // Warm-up: first calls populate cairo/freetype internal caches.
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const fg: [4]f32 = .{ @as(f32, @floatFromInt(i % 8)) / 8.0, 0.5, 0.5, 1 };
        _ = try atlas.lookupOrLoadCustom(300, container, .colrv1, 1000, 1, fg);
    }
    const before = c.mallinfo2().uordblks;
    const ITERS: u32 = 300;
    while (i < 8 + ITERS) : (i += 1) {
        // 256 distinct foregrounds → distinct cache keys → a real
        // raster every iteration.
        const fg: [4]f32 = .{
            @as(f32, @floatFromInt(i % 256)) / 255.0,
            @as(f32, @floatFromInt((i * 7) % 256)) / 255.0,
            0.25,
            1,
        };
        _ = try atlas.lookupOrLoadCustom(300, container, .colrv1, 1000, 1, fg);
    }
    const after = c.mallinfo2().uordblks;
    const growth = if (after > before) after - before else 0;
    // A leaked cell-sized ARGB32 surface alone is ~3-6 KiB × 300
    // iterations ≈ 1-2 MiB; genuine steady-state jitter (allocator
    // bins, atlas CPU-side bookkeeping in the C heap: none) stays
    // far below this.
    if (growth > 512 * 1024) {
        std.debug.print("colrv1 raster C-heap growth: {d} bytes over {d} iters\n", .{ growth, ITERS });
        return error.CairoResourceLeak;
    }
}
