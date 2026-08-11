# GPU / graphics

OpenGL integration, `GtkGLArea` lifecycle, the atlas, fractional
scaling, driver-specific concerns. The terminal renderer lives in
`src/ui/terminal_surface.zig` (widget + GL lifecycle) and
`src/render/` (the passes); `architecture.md` summarizes the same
lifecycle in its "GL context lifecycle" section.

## Stack choice

- **`GtkGLArea` + OpenGL ES 3.0 + `libepoxy`.**
  - `GtkGLArea` is GTK4's widget for native GL rendering; proven by
    Inkscape, GNOME Builder, Xournal++.
  - OpenGL ES 3.0 is the portable subset: no extensions required for
    our instanced-quad grid and textured image quads.
  - `libepoxy` is GTK4's built-in GL function loader — no GLEW/GLAD
    needed, already pulled in by the GTK4 dep chain.
  - macOS GDK realizes desktop GL only, so `render/gl.zig` keeps a
    process-wide `api` (`gles` / `gl_core`) and injects the matching
    `#version` header into every shader. Never set the API on a
    `GtkGLArea` by hand: `gl.requestArea` before realize,
    `gl.adoptAreaApi` after `make_current`.
- **No GSK for the terminal surface.** GSK's scene-graph model
  obscures batching; we need direct shader control over the grid.
  Browser panes are the deliberate exception - `src/ui/webface.zig`
  presents engine frames as `GdkTexture`s on a `GtkPicture` and lets
  GSK composite them (see *Fractional scaling* below for why).
- **No Vulkan backend of our own.** GSK may well be running on
  Vulkan underneath; our passes are GL either way.

## GL context lifecycle

`GtkGLArea` has no usable GL context at construction time. The
context exists only between `realize` and `unrealize`. Shader
compilation, atlas allocation, and VBO setup must happen within
that window.

### Signals (order of first fire)

| Signal            | When it fires                           | What we do                                           |
|-------------------|------------------------------------------|------------------------------------------------------|
| `realize`         | Context current for the first time      | `adoptAreaApi`, drop stale GL state, build atlas, realize every pass |
| `resize`          | Framebuffer reallocated                 | Recompute cols/rows from cell metrics, `requestResize` the session |
| `render`          | A frame must be drawn                   | bg -> images(z<0) -> cell -> overlay -> images(z>=0)  |
| `unrealize`       | Context going away                      | `releaseGL` (or `forgetGL` when the context is already gone) |

There is no `create-context` handler: GDK creates each area's
context itself. `auto_render` is switched OFF in
`TerminalSurface.initInPlace`, so a frame is only drawn when
something calls `gtk_gl_area_queue_render` - an idle pane costs no
GL work at all.

### Every realize is potentially a RE-realize

`gtk_widget_unparent` unrealizes a widget, and unrealizing a
`GtkGLArea` destroys its `GdkGLContext`. Splits, tab moves, drags
between windows and layout rebuilds all reparent, so a pane's
context is cycled routinely. `onRealize` in
`src/ui/terminal_surface.zig` therefore assumes nothing survived:
it `deinit`s the previous `Atlas`, calls `forgetGL()` on
`GridPass` / `CellPass` / `ImagePass` / `BgPass` / `ShaderPass` /
the linear-light target / `ImageStore`, and only then rebuilds. Skip
that and each pass's `realize()` early-returns on its cached
non-zero program id, and `glUseProgram` on a dead id renders
silently black.

`onUnrealize` is the mirror: `releaseGL` when the context is still
current, `forgetGL` when GTK has already taken it away.

## Contexts and the atlas

Each pane is a separate `GtkGLArea` with its own `GdkGLContext`, and
**each `TerminalSurface` owns its own `Atlas`** (`surface.atlas`),
built in its realize handler against its own context. Nothing is
shared between panes at the GL level and no window-level root
context exists. The cost is one atlas texture per pane; the benefit
is that context loss on one pane is entirely local, which is what
made the re-realize discipline above tractable.

GDK manages context lifecycle; we never `gdk_gl_context_dispose`
manually.

**Renderer invariant.** After any atlas rebuild or swap, call
`surface.onAtlasRebuilt()`. It marks every cell dirty and resets the
GridPass vertex-buffer validity flags in one place; hand-copying
that list is how stale glyph UVs get drawn from a fresh texture.

## Fractional scaling

Plasma 6 defaults to per-monitor fractional scaling (1.25x, 1.5x,
etc). **There are two different scales and picking the wrong one is
a real, shipped-bug-shaped mistake:**

- `gtk_widget_get_scale_factor()` is an INTEGER. On a 1.5x output it
  returns 2.
- `gdk_surface_get_scale()` is the true fractional f64 (GTK >= 4.12),
  and it needs a realized surface.

### The terminal surface: integer, deliberately

A `GtkGLArea`'s framebuffer is sized by GTK at the INTEGER scale, so
the terminal path is integer throughout and unit-consistent with it:

| Space                     | Unit             | Source                                                  |
|---------------------------|------------------|---------------------------------------------------------|
| Widget logical size       | logical px       | `gtk_widget_get_width` / `_get_height`                  |
| Framebuffer physical size | framebuffer px   | logical x `gtk_widget_get_scale_factor`                 |
| Font rasterization        | framebuffer px   | `physicalFontSize()` = pt x (96 x scale_factor) / 72    |
| Cell grid                 | framebuffer px   | `atlas.cell_w` / `cell_h`, straight from the raster     |

Discipline:

- `glViewport(0, 0, phys_w, phys_h)` - GL works in framebuffer pixels.
- Cell counts are `(framebuffer size - 2*pad) / cell size`; both
  operands are already framebuffer pixels, so no scale appears in
  the divide. `onResize` receives framebuffer dimensions directly
  (that is why `GtkGLArea::resize` exists separately from
  `size-allocate`) and must NOT multiply by the scale factor again.
- The atlas stores glyphs at framebuffer size; the passes compute
  quad geometry in framebuffer pixels.

At 1.5x this means we rasterize at 2x and the pane is composited
down to the surface's real scale: one resampling of text that was
oversampled to begin with. It is not the double resampling the
browser path used to suffer, described below.

**Known gap (verified absent, not a design choice):** nothing
watches `notify::scale-factor` on a terminal surface. Cell metrics
and the atlas are (re)built from the scale factor at realize and on
font-size change, so dragging a window between differently scaled
monitors without triggering either leaves the atlas at the old
raster size until something else rebuilds it.

### Browser panes: fractional, mandatory

`src/ui/webface.zig` asks `gdk_surface_get_scale()` (falling back to
a monitor's scale before realize) and ships that fractional value to
the engine, which renders at it. The frame comes back as a
`GdkTexture` that GSK composites at the surface's real scale: 1:1
texels, zero resampling.

This is why browser frames are NOT a `GtkGLArea` any more. The
deleted `render/web_pass.zig` + `ui/webdmabuf.zig` pair drew engine
frames through a GL area, whose framebuffer is integer-scaled: a
frame rendered at 1.5 was upscaled 1.5 -> 2 by the pass and then
downscaled 2 -> 1.5 by GSK. Two resamplings, measurably destroying
1px detail (hard 0/255 stripes arriving as [5,117,127] mush). The
texture also has to sit on the device pixel grid to keep that
property, which is what `Window.alignmentForScale` / `snapDown` do
for `GtkPaned` divider positions.

## Frame scheduling

**Do not use `g_idle_add` for redraws.** Idle callbacks do not
coalesce: schedule one with another pending, you get both executed.
The correct primitive is `gtk_gl_area_queue_render` (GTK coalesces
within a frame); `auto_render` is off, so it is also the ONLY thing
that produces a frame.

**There is no render worker thread and no cross-thread wakeup.**
PTY reads and VT parsing happen in the `sketerm-mux` daemon, a
separate process. The GUI's terminal is a mirror: `Terminal`
(`src/terminal.zig`) watches the daemon socket with `g_unix_fd_add`
on the main thread, applies parsed events straight into `Screen`,
and the pane queues a render. Nothing marshals between threads on
this path, so `g_main_context_invoke`, an SPSC ring, an atomic
`drain_pending` flag and a shutdown eventfd all no longer exist -
do not reintroduce them.

Per-frame work that is genuinely per-frame rides
`gtk_widget_add_tick_callback` (`TerminalSurface.ensureTickRunning`
/ `onTick`): custom-shader animation, kitty image animation, child
exit. Slow visual timers deliberately do NOT: cursor blink, cursor
trail and the bell fade are `g_timeout_add` handlers, so an idle
focused pane leaves the frame clock stopped instead of pinning it at
the display refresh rate.

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

NVIDIA behaviour here is UNVERIFIED by this project - no NVIDIA
hardware has been tested against. Treat the version floors above as
what the ecosystem recommends, not as something we measured. Note
also that `GDK_BACKEND=x11` is not an acceptable diagnostic detour:
X11 changes the code under test (see `testing.md`).

### NVIDIA open kernel module
Same as proprietary for our purposes.

### llvmpipe (software)
Works for dev/test; too slow for interactive use (< 30 fps on a
non-trivial grid).

## Render passes

Each pass is its own program pair, realized per surface. Draw order
inside `onRender` (`src/ui/terminal_surface.zig`):

1. **`BgPass`** (`render/bg_pass.zig`) - pane background gradient or
   image, under everything including below-text kitty images.
2. **`ImagePass`, z < 0** (`render/image_pass.zig`) - kitty's
   negative-z placements, which the spec puts under glyphs.
3. **`CellPass`** (`render/cell_pass.zig`) - the instanced cell
   pipeline: per-cell background and glyph for ordinary rows, with a
   persistent VBO that only re-uploads dirty rows.
4. **`GridPass`** (`render/grid_pass.zig`) - the per-vertex overlay:
   cursor, selection, focus border, scrollback indicator, preedit,
   bell, plus any row needing bidi reorder or double-height /
   double-width scaling.
5. **`ImagePass`, z >= 0** - foreground placements.

Two wrappers can bracket the lot, both drawing the scene into an
offscreen texture first: `linear_target` (blend in linear light,
resolve back to sRGB) and `ShaderPass` (user CRT-style shader, or a
dim-only post for an inactive pane). Both must agree on one blend
mode per frame, which is why `eff_mode` is computed once and pushed
into every pass.

Two consequences worth remembering:

- **Glyphs render through TWO pass pairs.** Ordinary rows go through
  CellPass, complex-script/RTL and DH/DW rows through GridPass. A
  glyph-rendering change that touches only one of them is half done.
- **`GridPass.Snapshot` must learn about any new overlay state.**
  Add a field or hash contribution for it, or the vertex buffer will
  not rebuild when that state changes.

## Atlas strategy

One atlas per `TerminalSurface` (`render/atlas.zig`):

- A single **`GL_TEXTURE_2D_ARRAY`, RGBA8**, `PAGE_COUNT` (4) layers
  of `PAGE_SIZE` (2048) squared - a 64 MB GPU budget. Grayscale
  coverage and color (emoji / COLR) glyphs share it; `Glyph.colored`
  tells the shader whether to tint with the cell fg or sample RGBA
  directly.
- Packing: shelf packing, per page.
- Eviction: when packing fails on every page, the page with the
  smallest `last_used_frame` is dropped whole and reused.
  `markFrame()` is called once per render to keep those timestamps
  meaningful.
- `Glyph.generation` is bumped on eviction so callers that cache
  UVs can detect a stale reference.

## Debug tooling

- `SKETERM_PROFILE=1` - per-pass nanosecond timings
  (`util/profile.zig`); the render path records `cell_rebuild`,
  `cell_draw`, `grid_build`, `grid_draw` and `image_pass`.
- `--debug-images` - image upload and draw diagnostics on stderr.
- `GDK_DEBUG=opengl` — GDK-level GL tracing.
- `MESA_DEBUG=1` — driver-level diagnostics.
- `zig build smoke-gl-core` - compiles every pass's shaders under a
  desktop GL 3.3 core context, i.e. the macOS code path, on Linux.

No `GL_KHR_debug` callback is installed today. If one is added,
check `epoxy_has_gl_extension("GL_KHR_debug")` first: on GL ES it is
an extension, not core until ES 3.2.

## What we do NOT do

- No Vulkan backend of our own.
- No software fallback beyond llvmpipe.
- No HDR; sRGB only (with an optional linear-light blend stage).
- No multi-GPU discrimination; let GTK/Wayland pick.
- No dma-buf import in the TERMINAL path - terminal images go
  CPU -> texture. Browser frames do import dma-bufs, via
  `GdkDmabufTextureBuilder` in `ui/webface.zig`, so GSK samples the
  engine's buffers with no copy.
