# Images

Sixel, Kitty graphics, and iTerm2 inline images. `protocols.md`
lists the wire-level sequences; this doc is the internal model the
three normalize to.

## Why a separate doc

Three protocols with non-trivial differences in transmission,
placement, lifetime, and delete semantics could become three
disjoint implementations. They do not: there is one **source cache**
and one **placement store**, and every protocol feeds both. The cell
grid carries no image pixel data.

## The two stores

Splitting source pixels from on-screen placements is what makes
Kitty's "transmit now, place later, place again" model work without
special-casing it.

**`grid/kitty_images.zig` `Manager` - the source cache.** Owned by
`Screen` (`screen.kitty_images`), so it is GTK-free and lives
daemon-side as well as GUI-side. Keyed by Kitty `image_id`:

- `store: AutoHashMap(u32, StoredImage)` - decoded RGBA plus, for
  animations, a `frames` list, `current_frame`, `playing`,
  `loops_remaining` and a `generation` counter placements compare
  against to notice a frame flip.
- `accums` - in-flight chunked transmissions (`m=1` until `m=0`),
  keyed by image id, capped at `MAX_ACCUMS` (32).
- `budget_bytes` / `store_bytes` - retained-source accounting, fed
  from `config.image_memory_mb`, with FIFO eviction by `seq`.
- `number` - the client's `I=` image NUMBER, so `d=n` / `d=N` can
  delete by it.

**`grid/image_store.zig` `Store` - the placement store.** Owned by
`TerminalSurface` (`surface.image_store`), NOT by `Terminal`: it
holds GL texture handles and is therefore render-side state, one per
terminal surface, main thread only.

It is a flat `images: ArrayList(Image)` where each entry IS one
placement. Fields that matter:

- `image_id` / `placement_id` - Kitty's ids; both 0 for sixel and
  iTerm2, which have no protocol-level identity.
- `cell_row` / `cell_col` - top-left at placement time.
- `anchor_id` - the stable `Line.id` of the placement's top row.
  0 means pinned (never scrolls). This is the whole scrolling
  mechanism; see *Anchoring* below.
- `draw_row` / `on_screen` - recomputed every frame by
  `resolveImageRows` in `terminal_surface.zig`.
- `pending` - the source RGBA, RETAINED after upload so a lost GL
  context can re-upload rather than lose the image.
- `gl_tex`, `pending_dirty`, `deleting` - upload/teardown state.
- `cells_wide` / `cells_high`, `cell_x_offset` / `cell_y_offset`,
  `src_x/y/w/h` - Kitty's scaling, intra-cell offset and source
  crop.
- `live_bytes` / `budget_bytes` - the same `image_memory_mb` budget
  applied to retained placement pixels, with FIFO eviction
  (`evictForBudget`).

API worth knowing: `addFull(AddOpts)` (every add path funnels here),
`markByIdForDelete` / `markByPlacementForDelete` /
`markSelectedForDelete` / `markAllForDelete`, `replacePending` and
`uploadFrame` for animation, `flushUploads` (the once-per-frame GL
sync point), and `forgetGL` / `releaseGL` for context loss.

`Cell.Flags` reserves a `has_image` bit, but nothing sets or reads
it: placements are resolved from the store, not from the grid.

## Per-protocol semantics

### Sixel (DCS q)
- `DCS P1 ; P2 ; P3 q` header params: P1 selects a pixel aspect ratio
  from the VT330/VT340 macro table (0/1/5/6 = 2:1, 2 = 5:1, 3/4 = 3:1,
  7/8/9 = 1:1), applied by whole-pixel replication; P2 = 0 or 2 fills
  unpainted pixels with the current SGR background (a default
  background stays transparent so a pane background image still shows),
  P2 = 1 keeps them transparent; P3 (horizontal grid size) is ignored,
  as it is everywhere else.
- A `" Pan ; Pad ; Ph ; Pv` raster attribute overrides P1's ratio — it
  states the ratio outright instead of selecting a macro — and sizes
  the buffer via Ph/Pv.
- One placement per received sixel stream, anchored at the cursor
  position at receive time. No entry in the Kitty source cache.
- Dropped when its anchor line falls out of scrollback.
- Decoded dimensions are clamped to `MAX_DIM` (10000) per side in
  `parser/sixel.zig`, before any allocation or painting.

### Kitty graphics (APC G=...)
- **Image and placement are decoupled.** Kitty's protocol supports
  transmitting an image without placing it (cache for later) and
  placing an already-transmitted image without retransmission.
- Wire commands:
  - `a=t` transmit -> decode into the Manager's `store` under `i=N`.
  - `a=T` transmit + place → both above.
  - `a=p` place → add placement referencing existing image id.
  - `a=f` / `a=a` -> animation frame append / playback control.
  - `a=d` delete - the selector set lives in
    `Screen.ImageDeleteEvent.selects`: `a` (all), `i` (by image id),
    `n` (by image NUMBER `I=`), `c`/`p` (placement covering a cell),
    `q` (cell + z), `x` / `y` (column / row), `z` (z-index),
    `r` (inclusive image-id range). `f` deletes animation frames
    rather than placements.
  - **Case matters.** Lowercase deletes only placements and KEEPS
    the source image, so `a=p` can re-place without retransmitting.
    Uppercase also drops the source. Getting this wrong is what
    broke `kitten icat --hold` and similar apps, which clear
    placements every frame with `d=a` and rely on the source
    sticking around.
- **Chunked transmit** (`m=1` continuation) is reassembled in
  `Manager.accums` before decode.
- Persistent cache: an image with zero placements stays in the
  Manager's `store` until an uppercase delete removes it or the
  `image_memory_mb` budget evicts it oldest-first. There is no
  refcount.
- **`q=` quiet-response level.** The parser records `q` per command
  (`kitty_image.zig` `quiet`). Verified behaviour today: the `a=q`
  capability probe replies `OK` at `q=0` and stays silent at
  `q>=1`. `q` has nothing to do with alt-screen scoping.
- **Negative z-order** (`z=-1`, `z=-2`, …): places image *beneath*
  cell glyphs. Renderer implication in §Render pass.
- **Unicode placeholders** (`U=1` plus U+10EEEE cells with
  row/column diacritics) are implemented: the tables are in
  `grid/kitty_placeholder.zig`, the tiling in `screen.zig`
  (`virtual_placements` / `flushPlaceholder`).

### iTerm2 OSC 1337 File=
- Payload is base64 of a full image file.
- **PNG only.** `parser/iterm_image.zig` checks the 8-byte PNG magic
  before handing the bytes to the vendored `stb_image.h`; anything
  else is dropped silently (`format = .unsupported`, no pixels, no
  message).
- Base64 decode handled by our parser; streams may span multiple
  OSC writes (buffer across until terminator).
- `inline=0`, the protocol's default, means "transfer, do not
  display". We have no download side, so those are dropped rather
  than drawn where the app expects nothing.
- Placement at cursor. The requested box (`width=` / `height=` in
  cells, pixels, percent or auto) is resolved against the pane's
  real cell metrics via `iterm.resolveCells`.
- No protocol-level id: `image_id` and `placement_id` are 0, one
  placement, same lifetime as sixel.

## Anchoring, scrolling and eviction

There is no coordinate remapping and no `old_row -> new_row` map.
Every placement stores `anchor_id`, the stable `Line.id` of its top
row, and `resolveImageRows` (in `ui/terminal_surface.zig`) asks
`Screen.imageRowForAnchor` for a live display row once per frame:

- `.visible(row)` - draw at that row. Scroll, scrollback paging and
  a straddled top edge all fall out of this for free; a tall image
  whose anchor has just left the viewport still draws its lower
  rows, with GL clipping the rest.
- `.offscreen` - skip the draw, keep the image; it may come back.
- `.evicted` - the anchor is older than the oldest surviving line,
  so the content is gone from the scrollback ring. Mark `deleting`;
  `flushUploads` frees the texture and the pixels.

`anchor_id == 0` means pinned: `draw_row` stays at `cell_row`.

**Column resize destroys placements.** `Screen.reflowMain` stamps a
fresh `Line.id` on every reflowed row, because cells were
redistributed and the pre-reflow ids are irretrievable. Every
existing anchor then resolves `.evicted`, so images placed before a
width change do not survive it. Row-only resizes and font-size
changes keep their line ids and are unaffected.

## Alt screen

There is ONE `Store` per terminal surface, shared by the main and
alternate buffers; there is no per-`Screen` store and DECSET 1049
does not swap one.

Visibility still separates, and it separates for the anchoring
reason above: alt-buffer lines are minted with fresh ids, so a
main-screen placement resolves `.offscreen` while the alt buffer is
up and draws again on return. An alt-screen app that places an image
and then leaves the alt buffer loses it, since its anchor lines are
cleared.

## GL texture lifecycle

- Uploads happen in `Store.flushUploads`, called once per frame from
  the surface's render callback with the area's context current.
  `pending_dirty` marks what needs (re-)uploading.
- `pending` pixels are retained AFTER upload, so a lost GL context
  (a split, a tab drag) re-uploads instead of losing the image.
- `Store.deinit` frees pixel buffers but deliberately does NOT call
  `glDeleteTextures`: textures belong to the context, GTK destroys
  the context on unrealize, and deleting without a current context
  is at best a no-op. `forgetGL` (context already gone) and
  `releaseGL` (context still current) are the two explicit paths.
- Textures are never shared across panes: each surface owns its own
  atlas and its own placement textures, so two panes showing the
  same Kitty image id decode and upload independently.

## Render pass

Kitty's z-ordering spec places negative-z images *below glyphs but
above cell backgrounds*. The passes are ordered to honor that
(`onRender` in `ui/terminal_surface.zig`):

1. **`BgPass`** - the pane background (gradient / image).
2. **`ImagePass.drawZ(.below)`** - placements with `z_index < 0`.
3. **`CellPass`** - per-cell backgrounds and glyphs.
4. **`GridPass`** - the overlay (cursor, selection, complex rows).
5. **`ImagePass.drawZ(.above)`** - placements with `z_index >= 0`.

Before step 2, `resolveImageRows` fixes each placement's `draw_row`
and `flushUploads` syncs textures, so the two image passes draw from
settled state. `ImagePass.pad` is set from `GridPass.pad` so images
line up with the cells that placed them.

## Animation

Kitty animation is implemented, not deferred. `a=f` appends frames
with per-frame delays; `a=a` controls playback (stop / run, loop
count, set current frame). `TerminalSurface.onTick` calls
`Manager.advanceAnimations`, and when a `StoredImage.generation`
moves, the matching placements pull the new frame's bytes through
`Store.uploadFrame`. Unmapped panes skip the advance entirely, so a
background tab burns nothing.

## Security and size limits

- **Retained-pixel budget**: `config.image_memory_mb` (default 320)
  is applied TWICE - to the Manager's decoded sources
  (`store_bytes`) and to the placement store's retained pixels
  (`live_bytes`). Both evict oldest-first rather than refusing new
  images, and both allow a single over-budget image through so one
  large image cannot be starved out.
- **Sixel dimensions**: clamped to `MAX_DIM` (10000) per side
  before allocation.
- **Kitty in-flight transfers**: `MAX_ACCUMS` (32) concurrent
  chunked transmissions; `MAX_FRAMES` (1024) animation frames per
  image; a per-transmission payload cap that tracks the memory
  budget (`DEFAULT_ACCUM_CAP` when no budget is set).
- **Kitty media**: `t=d` (direct), `t=f` (file path) and `t=t`
  (tempfile, read then `unlink`) are supported. `t=s` (POSIX shared
  memory) is NOT.
- **Snapshot retention**: `Screen.RETAIN_IMAGE_BUDGET` (12 MB) caps
  the pixels a daemon-side Screen keeps for mux snapshots, staying
  under the 16 MB wire frame cap. Dropped placements reappear when
  the app redraws.

## Testing

Automated:
- `src/parser/graphics_conformance_test.zig` - protocol-level
  behaviour against a real `Store`.
- `src/grid/image_pipeline_test.zig` - the parse-to-placement path.
- Unit tests in `grid/kitty_images.zig` (budget eviction, frames)
  and `parser/sixel.zig` (dimension clamping, aspect scaling).
- `zig build smoke-image` - headless EGL render of a known image
  through `ImagePass` + `Store`, with pixel readback.

Manual corpus: `chafa` / `img2sixel` / `yazi` for sixel,
`kitten icat` / `timg` / `viu` for Kitty, `imgcat` for iTerm2.

## Not implemented

- Kitty `t=s` (shared-memory) media.
- JPEG/GIF/TIFF/WebP for iTerm2 - PNG only, by an explicit magic
  check in `parser/iterm_image.zig` before handing to stb_image.
- Cross-pane texture sharing.
- dma-buf / GPU-direct import for terminal images (browser frames
  do import dma-bufs; see `gpu.md`).
- Placement survival across a column resize (see *Anchoring*).
