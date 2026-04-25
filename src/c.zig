// Aggregated C bindings for sketerm.
//
// Imported as:
//   const c = @import("c.zig").c;
//
// Then used as `c.gtk_application_new(...)`, `c.openpty(...)`, etc.
//
// `usingnamespace` was removed in Zig 0.15; this `pub const c = …`
// pattern replaces it.

pub const c = @cImport({
    // GUI / GL
    @cInclude("gtk/gtk.h");
    @cInclude("adwaita.h");
    @cInclude("epoxy/gl.h");

    // Text
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");

    // POSIX (for PTY, signals, polling). Order matters slightly:
    // sys/types.h first, then platform-specific.
    @cInclude("sys/types.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/eventfd.h");
    @cInclude("termios.h");
    @cInclude("pty.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("poll.h");
    @cInclude("errno.h");

    // GLib UNIX signal helpers.
    @cInclude("glib-unix.h");

    // Vendored stb_image (PNG decode for iTerm2 OSC 1337).
    @cInclude("stb_image.h");
});
