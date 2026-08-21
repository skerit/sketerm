//! The monospace font roster the headless GL rigs fall back through.
//!
//! Separate from `eglboot.zig` on purpose: smoke-image and smoke-gl-core
//! need a surfaceless context but no Atlas, and folding the font roster
//! into the EGL module would hand them a freetype/harfbuzz dependency
//! they do not have today.

const std = @import("std");
const Atlas = @import("../render/atlas.zig").Atlas;

/// Tried in order; the first that Atlas can open wins. Distro paths,
/// because the rigs must not depend on a fontconfig cache being warm.
pub const CANDIDATES = [_][*:0]const u8{
    "/usr/share/fonts/TTF/Hack-Regular.ttf",
    "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf",
    "/usr/share/fonts/TTF/VeraMono.ttf",
    "/usr/share/fonts/gnu-free/FreeMono.otf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
};

/// First openable candidate as a realized-capable Atlas, or null when
/// the host ships none of them. The caller owns the result.
pub fn openAtlas(allocator: std.mem.Allocator, font_size: u16) ?*Atlas {
    for (CANDIDATES) |path| {
        if (Atlas.init(allocator, path, font_size)) |a| return a else |_| continue;
    }
    return null;
}
