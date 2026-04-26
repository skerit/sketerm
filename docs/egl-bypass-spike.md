# EGL bypass research spike (K)

**Status:** Research only. No code change. Follows plan-v3 K.
**Conclusion:** Defer indefinitely; integration cost outweighs measured
benefit on the current target stack (NVIDIA + Mesa-zink + GTK4).

## Goal recap

Replace the current pipeline:

```
cell_pass GL ES draws into GtkGLArea framebuffer
   ↓ GSK compositor renders that texture into the GdkSurface
   ↓ Wayland presents the surface
```

with:

```
sketerm owns its own EGLSurface backed by a wl_subsurface
   ↓ wl_subsurface composites onto the parent GdkSurface
   ↓ Wayland presents the composite
```

In theory this saves one GSK frame of latency (Kitty / WezTerm /
Foot all do this). In practice the cost is...

## Cost breakdown

### Build-time

- `c.zig` adds `gdk/wayland/gdkwayland.h` (and pulls in
  `wayland-client-protocol.h`). Roughly +1500 lines of header noise
  through the @cImport.
- `pkg-config gtk4` provides the include flags; `wayland-client` is
  already a transitive dep.
- New dependency: nothing new at runtime, but we'd link `wayland-egl`
  for `wl_egl_window`.

### Architecture

The current pipeline owns **one** GdkSurface (the toplevel) plus
managed-by-GTK GdkGLContexts per GtkGLArea. All sub-widgets
(AdwTabBar, AdwTabView, GtkPaned, GtkBox holding our wrapper for
each Pane, the per-pane GtkGLArea, the AdwHeaderBar) composite via
GSK into that one GdkSurface. GTK chooses where each widget sits.

To bypass this for **just our cell content**, we'd need:

1. **Per-Pane wl_subsurface** rooted at the toplevel's wl_surface,
   positioned to cover the cell-grid rectangle within the GtkGLArea
   widget's allocation.
2. **GTK widget allocation tracking** so the subsurface's position
   updates whenever GtkPaned resizes / scrolls / a tab switches /
   the user resizes the toplevel. This means hooking into
   `GtkWidget::size-allocate` for every Pane's GtkGLArea AND the
   ancestor chain (any of which can move the GLArea).
3. **EGL setup**: per-Pane EGLDisplay (shared across panes via
   `eglGetDisplay(wl_display)`), per-Pane EGLContext + EGLSurface
   bound to a `wl_egl_window`. Our existing share-group across
   panes (for the atlas texture) needs preserving.
4. **GTK rendering coordination**: the GtkGLArea's own framebuffer
   must NOT contend with our subsurface for the same pixel region.
   Either:
   - Make the GtkGLArea fully-transparent (we already pull this off
     for `background_opacity`) AND draw nothing in its render
     callback. The wl_subsurface draws over it.
   - Replace the GtkGLArea entirely with a custom `GtkWidget`
     subclass that does nothing more than forward size-allocate.
5. **Frame clock**: today the GtkGLArea drives its own frame timing
   (`gtk_widget_add_tick_callback`). Our subsurface would need to
   commit at the same cadence — straightforward via the toplevel's
   `GdkFrameClock`, but it has to interleave with GTK's own paint
   pass for the chrome (header bar, tabs).
6. **Input routing**: clicks / motion / scroll currently arrive as
   GTK events on the GtkGLArea. With a subsurface on top of it,
   pointer events go to the subsurface's wl_surface — we'd need to
   forward them back to GTK or attach our own pointer-event
   handlers to the wl_surface and translate to the existing
   handlers' callbacks. **This is the worst part.**
7. **Title-bar visibility** (the per-pane Terminator-style red bar
   shipped earlier). It currently lives inside the wrapper GtkBox
   above the GtkGLArea. With a subsurface covering the GLArea
   region only, the GTK bar still composites correctly above —
   that part is fine.
8. **Image overlays** (Kitty graphics + Sixel + iTerm2 1337) all
   live in the same GL pipeline today. The subsurface replaces the
   GLArea, so they continue to work — provided the subsurface size
   matches the cell-grid rectangle.

### Measured benefit

Latency win: at most one frame of the GSK compositor's render-to-
texture step. On a 60 Hz display that's 16.6 ms; in practice GSK
is typically much faster than a full frame (~1-2 ms at our pixel
counts). Real user-visible benefit on a dark TUI: imperceptible.

The fps-uncapped spike on a 165 Hz NVIDIA setup might shave ~3 ms
off keystroke-to-pixel latency. Against the AdwTabBar + GtkPaned
chrome cost — which we keep regardless — it's noise.

### Effort estimate (corrected from plan-v3)

- Spike (red triangle on subsurface inside sketerm): 1 day.
- Per-Pane subsurface + GtkGLArea coordination: 3-5 days.
- Input event routing rewrite: 4-6 days.
- Reconciling with AdwTabView reparenting (close-page / page-
  attached / split / unparent): 2-3 days.
- Per-driver compatibility matrix (NVIDIA blob, Intel/AMD via Mesa,
  Mali/Adreno via vendor): 3-5 days.

Total: **2-3 weeks of focused work** for a latency win we can't
measure on the current hardware.

## Recommendation

**Do not pursue.** The current pipeline already runs at hardware
refresh rate on the NVIDIA RTX 3050 + Wayland + Mesa-zink target.
GSK overhead is small on this hardware. The integration cost
trumps the benefit by an order of magnitude.

If a future user reports measurable input latency on a slow
hardware target (e.g. Pi 5 + Mali GPU), revisit and limit the
work to that target.

## What would actually help if we needed lower latency

These are bounded changes inside the current pipeline that would
ship measurable wins **without** restructuring around subsurfaces:

1. **`I` persistent-mapped VBO** (already partly plumbed, gated
   off pending an EXT-symbol fix). 1-2 days. Removes the
   driver-side staging copy on every cell upload.
2. **`gtk_gl_area_set_use_msaa(0)`** if not already set. Tiny win
   but free.
3. **Compositor-side direct scanout**: nothing we can request
   directly from GTK4, but a future GdkVulkanRenderer upgrade
   (currently used by GTK4 master) may give us what subsurface
   bypass would.
