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
#ifdef __linux__
#include <features.h>
#ifndef __GLIBC__
struct timespec { long tv_sec; long tv_nsec; };
#define __DEFINED_struct_timespec
#endif
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/resource.h> /* broker: per-worker RLIMIT_AS memory containment */
#include <sys/file.h>     /* X display lock reclamation */
#ifdef __linux__
#include <sys/prctl.h>    /* satellite dies with its owning daemon */
#include <sys/eventfd.h> /* Wakeup fast path (pipe fallback elsewhere) */
#include <sys/inotify.h> /* fsserve: live directory-view deltas */
#include <sys/xattr.h>   /* fsserve: user.sketerm.tags file tags */
#include <linux/fuse.h>  /* fsmount: pure-Zig /dev/fuse client */
#include <sys/uio.h>     /* fsmount: writev for big read replies */
#include <pty.h>         /* openpty/forkpty live here on glibc/musl */
#else
/* macOS: openpty/forkpty live in libSystem, but their declaring
 * header (util.h) ships with the Xcode SDK, not with Zig's bundled
 * libc headers — declare them directly so Linux→macOS cross builds
 * work. Symbols resolve at link time. */
struct termios;
struct winsize;
int openpty(int *amaster, int *aslave, char *name,
            struct termios *termp, struct winsize *winp);
int forkpty(int *amaster, char *name,
            struct termios *termp, struct winsize *winp);
int login_tty(int fd);
#include <sys/random.h>  /* macOS: getentropy lives here */
#endif
#include <termios.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <poll.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/time.h> /* fsjob: utimes stamps the wire-thumb cache freshness */
#ifndef __linux__
#include <sys/mount.h>
#endif
#include <sys/mman.h> /* mux daemon: shm pool mirrors for the native app pipe */
#include <dirent.h>  /* mux daemon: Vulkan ICD discovery for waypipe --no-gpu */
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <pwd.h>
#include <grp.h>
#include <regex.h>

#include <fribidi.h>

#include <stb_image.h>
#include <stb_image_write.h>
