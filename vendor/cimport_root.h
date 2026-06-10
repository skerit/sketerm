/* C header aggregate for sketerm — fed to `zig translate-c` via a
 * Build.Step.TranslateC step so the @cImport doesn't run in-process
 * during `zig build-exe`.
 *
 * Why: Zig 0.16's `@cImport` triggers a SEGV inside `zig build-exe`
 * when translating this header set, even though `zig translate-c` on
 * the same input succeeds. The out-of-process step works around the
 * crash by running translate-c in its own subprocess and caching the
 * generated Zig file. The two `#define`s below paper over Aro bugs
 * with `_Pragma` inside macro expansion and gdkversionmacros.h's
 * `#error` guard sitting before its `#pragma once`.
 */

/* Neutralise `_Pragma("GCC diagnostic push")` style expansions inside
 * glib's G_GNUC_BEGIN_IGNORE_DEPRECATIONS / G_DEFINE_AUTO_CLEANUP_*
 * macros. Aro accepts `_Pragma(...)` standalone but not inside macro
 * replacement lists. */
#define _Pragma(x)

/* `gdkversionmacros.h` `#error`s when re-included without one of these
 * guards; Aro's `#pragma once` skip happens AT the directive, but the
 * `#error` is on a line BEFORE it. We shadow the system header via
 * `vendor/aro_shims/` and also predefine the guard for belt-and-braces. */
#define __GDK_H_INSIDE__ 1

/* Pin GLib API floor to 2.74 so the 2.76+ `g_string_free` macro
 * doesn't get defined. That macro expands into a `__builtin_constant_p`
 * ternary chain that translate-c lowers to invalid Zig (statement-
 * position `if (cond) _ = a else _ = b`). Pinning to 2.74 leaves the
 * plain `g_string_free()` function declaration in place. */
#define GLIB_VERSION_MIN_REQUIRED GLIB_VERSION_2_74
#define GLIB_VERSION_MAX_ALLOWED GLIB_VERSION_2_74

#include <gtk/gtk.h>
#include <adwaita.h>
#include <epoxy/gl.h>

#include <ft2build.h>
#include <freetype/freetype.h>
#include <freetype/ftoutln.h>
#include <hb.h>
#include <hb-ft.h>
#include <fribidi.h>
#include <fontconfig/fontconfig.h>

#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/eventfd.h>
#include <termios.h>
#include <pty.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <poll.h>
#include <errno.h>
/* Unix-domain sockets for the sketerm-mux daemon + clients. */
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>

#include <glib-unix.h>
#include <regex.h>

#include <stb_image.h>
