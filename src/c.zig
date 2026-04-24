// Aggregated C bindings for sketerm.
//
// Imported as:
//   const c = @import("c.zig").c;
//
// Then used as `c.gtk_application_new(...)` etc.
//
// `usingnamespace` was removed in Zig 0.15; this `pub const c = …`
// pattern replaces it.

pub const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("adwaita.h");
    @cInclude("epoxy/gl.h");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
});
