/* Lean C header aggregate for GTK-free binaries built on the terminal
 * core (sketerm-mux, smoke-mux, mux-portable). Translated by the same
 * out-of-process TranslateC step as cimport_root.h — see that file for
 * the why. Keep this to what a SERVER needs: libc, fribidi decls
 * (parse-only; never linked by the daemon), vendored stb_image.
 *
 * This set must stay translatable against musl (`zig build
 * mux-portable` targets x86_64-linux-musl) — no glibc-only headers.
 */

/* musl declares struct timespec with zero-width padding bitfields
 * (for 32-bit big-endian layouts), which Aro demotes to an opaque
 * type — taking struct stat and struct tm down with it. On 64-bit
 * targets the padding is empty and time_t == long, so define the
 * struct ourselves and claim musl's alltypes.h guard. 32-bit musl
 * targets would need a different layout — unsupported. */
#include <features.h>
#ifndef __GLIBC__
struct timespec { long tv_sec; long tv_nsec; };
#define __DEFINED_struct_timespec
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

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
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <regex.h>

#include <fribidi.h>

#include <stb_image.h>
