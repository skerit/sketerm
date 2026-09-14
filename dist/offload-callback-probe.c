// Why an offloaded sketerm window is killed by KWin: does a compositor retire
// a wl_surface.frame callback on a subsurface that carries no buffer?
//
// GTK asks for one per toplevel paint on EVERY subsurface, attached or not
// (gdksurface-wayland.c gdk_wayland_surface_request_frame loops over
// gdk_surface_get_n_subsurfaces and calls gdk_wayland_subsurface_request_frame,
// which does wl_surface_frame + wl_surface_commit unconditionally). When GSK
// declines to offload a frame it detaches the subsurface with
// wl_surface_attach(surface, NULL) (gdksubsurface-wayland.c) but keeps the
// GdkSubsurface alive, so the request keeps going out against a surface the
// compositor will never present. Still true on GTK main as of 2026-09.
//
//   build: wayland-scanner client-header \
//            /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
//            xdg-shell-client-protocol.h
//          wayland-scanner private-code \
//            /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
//            xdg-shell-protocol.c
//          gcc -D_GNU_SOURCE -O1 -o probe offload-callback-probe.c \
//            xdg-shell-protocol.c $(pkg-config --cflags --libs wayland-client)
//
//   ./probe 0 600   bufferless subsurface, the detached-offload case
//   ./probe 1 600   subsurface with a buffer, the accepted-offload case
//   ./probe 2 1200  bufferless, but retired and rebuilt every 128 paints,
//                   which is what src/ui/offload.zig does
//
// Measured 2026-09-14 on KWin 6.7.5 (mode 0/1 at 600 paints, mode 2 at 1200):
//   bufferless      600 requested,   0 done, 600 outstanding and still growing
//   with a buffer   600 requested, 600 done,   0 outstanding
//   renewed         outstanding never above 128; each retirement releases
//                   ~3 KB of delete_id instead of an unbounded burst
// KWin's outgoing buffer holds 1048576/12 = 87381 twelve-byte delete_id
// events, which a single detached subsurface reaches in ~24 minutes at 60 Hz.
// Overflowing it logs "Data too big for buffer (1048572 + 12 > 1048576)" and
// drops the client -- the six sketerm kills in the journal between 2026-08-27
// and 2026-09-13.
//
// Run the same binary under `sketerm run -- ./probe 0 300` and mode 0 reports
// 300 done, 0 outstanding: sketerm's own compositor retires frame callbacks on
// bufferless subsurfaces, so no rig built on it can observe this failure.
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

static struct wl_compositor *comp;
static struct wl_subcompositor *subcomp;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static int configured = 0;

static int top_req, top_done, kid_req, kid_done;
static int frames_left;

static void reg_global(void *d, struct wl_registry *r, uint32_t id,
                       const char *iface, uint32_t ver) {
  (void)d; (void)ver;
  if (!strcmp(iface, "wl_compositor"))
    comp = wl_registry_bind(r, id, &wl_compositor_interface, 4);
  else if (!strcmp(iface, "wl_subcompositor"))
    subcomp = wl_registry_bind(r, id, &wl_subcompositor_interface, 1);
  else if (!strcmp(iface, "wl_shm"))
    shm = wl_registry_bind(r, id, &wl_shm_interface, 1);
  else if (!strcmp(iface, "xdg_wm_base"))
    wm_base = wl_registry_bind(r, id, &xdg_wm_base_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t id) { (void)d;(void)r;(void)id; }
static const struct wl_registry_listener reg_l = { reg_global, reg_remove };

static void ping(void *d, struct xdg_wm_base *b, uint32_t s) { (void)d; xdg_wm_base_pong(b, s); }
static const struct xdg_wm_base_listener wm_l = { ping };

static void surf_configure(void *d, struct xdg_surface *s, uint32_t serial) {
  (void)d; xdg_surface_ack_configure(s, serial); configured = 1;
}
static const struct xdg_surface_listener xsurf_l = { surf_configure };
static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *st) {
  (void)d;(void)t;(void)w;(void)h;(void)st;
}
static void top_close(void *d, struct xdg_toplevel *t) { (void)d;(void)t; frames_left = 0; }
static const struct xdg_toplevel_listener xtop_l = { top_configure, top_close };

static void top_frame(void *d, struct wl_callback *cb, uint32_t t);
static void kid_frame(void *d, struct wl_callback *cb, uint32_t t);
static const struct wl_callback_listener top_l = { top_frame };
static const struct wl_callback_listener kid_l = { kid_frame };
static void top_frame(void *d, struct wl_callback *cb, uint32_t t) {
  (void)d;(void)t; top_done++; wl_callback_destroy(cb);
}
static void kid_frame(void *d, struct wl_callback *cb, uint32_t t) {
  (void)d;(void)t; kid_done++; wl_callback_destroy(cb);
}

static struct wl_buffer *make_buffer(int w, int h, uint32_t argb) {
  int stride = w * 4, size = stride * h;
  int fd = memfd_create("sk-probe", 0);
  if (fd < 0) { perror("memfd"); exit(1); }
  if (ftruncate(fd, size) < 0) { perror("ftruncate"); exit(1); }
  uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  for (int i = 0; i < w * h; i++) px[i] = argb;
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
  struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
  wl_shm_pool_destroy(pool);
  close(fd);
  return b;
}

int main(int argc, char **argv) {
  int mode = argc > 1 ? atoi(argv[1]) : 0;   // 0 = bufferless kid, 1 = kid gets a buffer
  frames_left = argc > 2 ? atoi(argv[2]) : 300;

  struct wl_display *dpy = wl_display_connect(NULL);
  if (!dpy) { fprintf(stderr, "no display\n"); return 1; }
  struct wl_registry *reg = wl_display_get_registry(dpy);
  wl_registry_add_listener(reg, &reg_l, NULL);
  wl_display_roundtrip(dpy);
  if (!comp || !subcomp || !shm || !wm_base) { fprintf(stderr, "missing globals\n"); return 1; }
  xdg_wm_base_add_listener(wm_base, &wm_l, NULL);

  struct wl_surface *top = wl_compositor_create_surface(comp);
  struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, top);
  xdg_surface_add_listener(xs, &xsurf_l, NULL);
  struct xdg_toplevel *xt = xdg_surface_get_toplevel(xs);
  xdg_toplevel_add_listener(xt, &xtop_l, NULL);
  xdg_toplevel_set_title(xt, "sketerm offload probe");
  wl_surface_commit(top);
  while (!configured) wl_display_dispatch(dpy);

  struct wl_buffer *tb = make_buffer(400, 300, 0xff202020);
  wl_surface_attach(top, tb, 0, 0);
  wl_surface_damage_buffer(top, 0, 0, 400, 300);
  wl_surface_commit(top);
  wl_display_roundtrip(dpy);

  struct wl_surface *kid = wl_compositor_create_surface(comp);
  struct wl_subsurface *sub = wl_subcompositor_get_subsurface(subcomp, kid, top);
  wl_subsurface_set_position(sub, 20, 20);
  wl_subsurface_set_desync(sub);
  if (mode == 1) {
    struct wl_buffer *kb = make_buffer(100, 100, 0xff40c040);
    wl_surface_attach(kid, kb, 0, 0);
    wl_surface_damage_buffer(kid, 0, 0, 100, 100);
  }
  wl_surface_commit(kid);
  wl_surface_commit(top);
  wl_display_roundtrip(dpy);

  // mode 2: what src/ui/offload.zig does — retire and rebuild the subsurface
  // every RENEW paints, so the backlog can never grow past one generation.
  if (mode == 2) {
    const int RENEW = 128;
    int paints = 0, worst_outstanding = 0, worst_burst = 0, generations = 1;
    int gen_req = 0, gen_done = 0, done_at_gen_start = 0;
    while (frames_left > 0) {
      struct wl_callback *c1 = wl_surface_frame(top);
      wl_callback_add_listener(c1, &top_l, NULL);
      top_req++;
      wl_surface_damage_buffer(top, 0, 0, 400, 300);
      wl_surface_commit(top);

      struct wl_callback *c2 = wl_surface_frame(kid);
      wl_callback_add_listener(c2, &kid_l, NULL);
      kid_req++; gen_req++;
      wl_surface_commit(kid);

      if (wl_display_dispatch(dpy) < 0) break;
      gen_done = kid_done - done_at_gen_start;
      if (gen_req - gen_done > worst_outstanding) worst_outstanding = gen_req - gen_done;
      paints++; frames_left--;

      if (paints % RENEW == 0) {
        if (gen_req - gen_done > worst_burst) worst_burst = gen_req - gen_done;
        wl_subsurface_destroy(sub);
        wl_surface_destroy(kid);
        kid = wl_compositor_create_surface(comp);
        sub = wl_subcompositor_get_subsurface(subcomp, kid, top);
        wl_subsurface_set_position(sub, 20, 20);
        wl_subsurface_set_desync(sub);
        wl_surface_commit(kid);
        wl_surface_commit(top);
        wl_display_roundtrip(dpy);
        generations++; gen_req = 0; done_at_gen_start = kid_done;
      }
    }
    printf("mode=renewed-every-%d paints=%d generations=%d\n", RENEW, paints, generations);
    printf("  subsurface frame requests=%d done=%d\n", kid_req, kid_done);
    printf("  worst outstanding at any moment     = %d\n", worst_outstanding);
    printf("  worst delete_id burst per retirement= %d  (%d bytes)\n", worst_burst, worst_burst * 12);
    wl_display_flush(dpy);
    return 0;
  }

  // GTK's loop: one frame callback on the toplevel and one on every
  // subsurface, every paint, with a commit on each.
  int paints = 0;
  while (frames_left > 0) {
    struct wl_callback *c1 = wl_surface_frame(top);
    wl_callback_add_listener(c1, &top_l, NULL);
    top_req++;
    wl_surface_damage_buffer(top, 0, 0, 400, 300);
    wl_surface_commit(top);

    struct wl_callback *c2 = wl_surface_frame(kid);
    wl_callback_add_listener(c2, &kid_l, NULL);
    kid_req++;
    wl_surface_commit(kid);

    if (wl_display_dispatch(dpy) < 0) { fprintf(stderr, "display error: %s\n", strerror(errno)); break; }
    paints++;
    frames_left--;
  }
  printf("mode=%s paints=%d\n", mode ? "kid-has-buffer" : "kid-bufferless", paints);
  printf("  toplevel   frame requests=%d  done=%d  outstanding=%d\n", top_req, top_done, top_req - top_done);
  printf("  subsurface frame requests=%d  done=%d  outstanding=%d\n", kid_req, kid_done, kid_req - kid_done);

  // What the compositor sends when the surface holding the backlog dies.
  fprintf(stderr, "### DESTROYING SUBSURFACE WITH %d OUTSTANDING\n", kid_req - kid_done);
  wl_subsurface_destroy(sub);
  wl_surface_destroy(kid);
  wl_display_roundtrip(dpy);
  wl_display_roundtrip(dpy);
  fprintf(stderr, "### DESTROY SETTLED\n");
  wl_display_flush(dpy);
  return 0;
}
