# GPU / graphics

OpenGL integration, `GtkGLArea` lifecycle, context sharing across
panes, fractional-scaling discipline, driver-specific concerns.
Referenced by `architecture.md` (D5, D6, D9) and `milestones.md`
(M0.5, M3).

## Stack choice

- **`GtkGLArea` + OpenGL ES 3.0 + `libepoxy`.**
  - `GtkGLArea` is GTK4's widget for native GL rendering; proven by
    Inkscape, GNOME Builder, Xournal++.
  - OpenGL ES 3.0 is the portable subset: no extensions required for
    our instanced-quad grid and textured image quads.
  - `libepoxy` is GTK4's built-in GL function loader — no GLEW/GLAD
    needed, already pulled in by the GTK4 dep chain.
- **No GSK.** GSK's scene-graph model obscures batching; we need
  direct shader control over the grid pass.
- **No Vulkan in v1.** Cost/benefit doesn't justify; post-v1 option.

## GL context lifecycle

`GtkGLArea` has no usable GL context at construction time. The
context exists only between `realize` and `unrealize`. Shader
compilation, atlas allocation, and VBO setup must happen within
that window.

### Signals (order of first fire)

| Signal            | When it fires                           | What we do                                           |
|-------------------|------------------------------------------|------------------------------------------------------|
| `create-context`  | GTK needs a `GdkGLContext`              | Return a shared context (see *Share groups* below)   |
| `realize`         | Context current for the first time      | Compile shaders, allocate VBO/VAO, init atlas refs   |
| `resize`          | Widget dim or scale factor changed      | Recompute cell metrics, update uniform block         |
| `render`          | A frame must be drawn                   | Grid pass → image pass                               |
| `unrealize`       | Widget being destroyed                  | Release per-pane GL resources (VBO/VAO/private tex)  |

Shared resources (atlas, shader programs, global uniforms) are owned
at the window level and survive individual pane creation/destruction.

## Share groups

Each pane is a separate `GtkGLArea` with its own `GdkGLContext`. By
default, textures created in one context are not visible from
another. The atlas must be shared across panes; otherwise each
pane rebuilds its own and blows VRAM.

Pattern:

1. On window creation, create a **root `GdkGLContext`** attached to
   the window's `GdkSurface` via
   `gdk_surface_create_gl_context(surface, &err)`. `GdkGLContext`
   is not fully freestanding — it requires a surface to attach to.
   Realize it with `gdk_gl_context_realize`, then store the pointer
   on the `Window` struct.
2. Every pane's `GtkGLArea` also explicitly opts into GL ES:
   ```zig
   c.gtk_gl_area_set_use_es(area, 1);
   ```
   This matters because `GtkGLArea` otherwise picks desktop GL on
   most Linux systems; our shaders target ES 3.0 specifically.
3. Each pane's `GtkGLArea` connects `create-context`:
   ```zig
   fn onCreateContext(area: *GtkGLArea, user: *Window) callconv(.C) *GdkGLContext {
       var err: ?*c.GError = null;
       return c.gdk_gl_context_create_shared(user.root_ctx, &err);
       // On error return NULL; GTK falls back to default-create and
       // we log the error. This should not happen in practice on
       // a working driver.
   }
   ```
4. All shared contexts can see textures/buffers created while *any*
   shared context is current.
5. **Atlas updates happen outside pane render callbacks**, typically
   in the main-drain path before `gtk_widget_queue_draw`. On that
   path we `gdk_gl_context_make_current(root_ctx)`, upload new
   glyphs, then pane render callbacks run with their own contexts
   current and sample from the atlas read-only.

**Important**: do not `make_current(root_ctx)` from inside a pane's
`render` signal handler. GDK tracks current context per thread and
assumes the widget's context is current for the duration of render;
switching mid-frame is undefined.

GDK manages context lifecycle; we never `gdk_gl_context_dispose`
manually.

## Fractional scaling

Plasma 6 defaults to per-monitor fractional scaling (1.25×, 1.5×,
etc). Four distinct pixel spaces exist:

| Space                     | Unit              | Source                                           |
|---------------------------|-------------------|--------------------------------------------------|
| Widget logical size       | logical px        | `gtk_widget_get_width` / `_get_height`           |
| Framebuffer physical size | physical px       | logical × `gdk_surface_get_scale` (f64 scale)    |
| Font rasterization DPI    | dots/physical in  | 96 × scale                                       |
| Cell grid / hit-test      | logical px        | derived from rasterized metrics ÷ scale          |

Discipline:

- `glViewport(0, 0, phys_w, phys_h)` — GL works in physical pixels.
- Grid layout (cols × rows) is computed in logical pixels.
- `FT_Set_Pixel_Sizes(face, 0, physical_cell_px)` — FreeType at
  physical DPI.
- After glyph raster, advance/ascent/descent are divided by scale
  to yield logical cell metrics.
- Atlas stores glyphs at physical size; vertex shader computes quad
  sizes in physical pixels directly.

**Target GTK ≥ 4.12** (for `gdk_surface_get_scale`). Older GTK4
only exposes `gtk_widget_get_scale_factor` which returns an
integer. `gdk_surface_get_scale` (fractional f64) landed in
GTK 4.12. KDE Plasma 6 commonly reports 1.5× — integer scale
factor would return 2 and over-rasterize by 33%.

Separately, target GTK ≥ 4.16 for stable NVIDIA + Wayland
explicit-sync behavior (see Driver notes below).

### Scale-change handling

When `gdk_surface_get_scale` changes (monitor move, compositor
reconfig):

1. Record the new scale in `Window.scale`.
2. Invalidate the atlas (drop all glyph-by-face slots).
3. Re-rasterize Latin-1 + cached-recently glyphs at new physical size.
4. Update per-pane cell metrics.
5. `gtk_widget_queue_draw` on all panes.

Rebuild is fast (< 50 ms on a warm FreeType cache).

## Frame scheduling

**Do not use `g_idle_add` for redraws.** Idle callbacks do not
coalesce: schedule one with another pending, you get both executed.
Correct primitive is `gtk_widget_queue_draw` — GTK coalesces draw
requests within a frame.

Cross-thread path (worker → main):

```zig
// worker, after parsing a batch:
_ = c.g_main_context_invoke(null, main_drain_events, @ptrCast(pane));
```

`g_main_context_invoke` marshals the callback onto the main thread
safely. The callback:

1. Drains the SPSC ring into the Screen.
2. If any line became dirty: `gtk_widget_queue_draw(pane.glarea)`.
3. Returns `G_SOURCE_REMOVE` (one-shot).

Multiple workers calling `g_main_context_invoke` concurrently is
safe; GLib serializes.

For cursor blink and animations, use
`gdk_frame_clock_add_tick_callback` on the pane's frame clock.
The clock is vsync-locked to the compositor.

## Driver notes

### Mesa (Intel, AMD)
Smooth. No known `GtkGLArea` issues on Plasma 6 Wayland.

### NVIDIA proprietary
Historically flaky on Wayland: stuttering, occasional context loss,
swap anomalies. Much of this is **mitigated** by Wayland explicit
sync (`wp_linux_drm_syncobj_v1`), which landed across the stack in
2024-2025 — but NVIDIA + Plasma 6 Wayland remains the most
regression-prone configuration even in 2026. Target:

- NVIDIA driver ≥ 555
- KWin ≥ 6.2 (explicit sync support)
- GTK ≥ 4.16

Before v1 ship: test on NVIDIA hardware (beg/borrow/VM). If
`GtkGLArea` is unusable, emergency fallback is XWayland
(`GDK_BACKEND=x11`) — functional but a regression.

### NVIDIA open kernel module
Same as proprietary for our purposes.

### llvmpipe (software)
Works for dev/test; too slow for interactive use (< 30 fps on a
non-trivial grid).

## Shader programs

Two programs, compiled once per share group on `realize` of the
root context:

### Grid program
- VS: reads per-instance cell data from VBO; emits a screen-space
  quad for the cell.
- FS: samples the appropriate atlas (R8 for grayscale, RGBA8 for
  color emoji); modulates with fg color; blends over bg.
- One draw call per frame per pane:
  `glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, visible_cells)`.

### Image program
- VS: per-placement quad with explicit pixel coords.
- FS: samples the placement's RGBA texture.
- Sorted by (z, texture_id). Draws are grouped per texture to
  minimize state churn.

## Atlas strategy

Two atlases per window (living on the root context):

- **R8** — 2048×2048 page(s), grayscale Latin/CJK/symbol glyphs.
- **RGBA8** — 2048×2048 page(s), color bitmap glyphs (emoji, COLR).

- Packing: shelf packing algorithm.
- Growth: allocate new page when current fills.
- Eviction: at 16 pages per atlas (~64 MB), LRU-evict a whole page.
  Not per-glyph (page-level eviction avoids pointer/slot-id churn).

## Debug tooling

- `GL_KHR_debug` callback on root-context realize — but **check
  availability first** via `glGetString(GL_EXTENSIONS)` or
  `epoxy_has_gl_extension("GL_KHR_debug")`. On GL ES it's an
  extension (not core until ES 3.2); on desktop GL it's common
  but not universal. Degrade gracefully to `glGetError` polling
  at suspect points if the extension is absent.
- `GDK_DEBUG=opengl` — GDK-level GL tracing.
- `MESA_DEBUG=1` — driver-level diagnostics.
- RenderDoc captures work on `GtkGLArea` (confirmed in 2024+).

## What we do NOT do

- No Vulkan backend (v2 maybe).
- No software fallback beyond llvmpipe.
- No HDR; sRGB only.
- No multi-GPU discrimination; let GTK/Wayland pick.
- No custom DMA-BUF importing; images go through CPU → texture.
