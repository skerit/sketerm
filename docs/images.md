# Images

Unified design for Sixel, Kitty graphics, and iTerm2 inline images.
Referenced by `architecture.md` (D6) and `milestones.md` (M9a/b/c).
`protocols.md` lists the wire-level sequences.

## Why a separate doc

Three protocols with non-trivial differences in transmission,
placement, lifetime, and delete semantics could become three
disjoint implementations. This doc defines a single internal model
— **image + placement** — that all three normalize to. The cell
model carries no image pixel data, only a lightweight placement
reference.

## Core types

```zig
pub const ImageId      = u32;   // stable across placements (Kitty)
pub const PlacementId  = u32;   // per-instance; many per image
pub const ImageProtocol = enum { sixel, kitty, iterm };

pub const Image = struct {
    id: ImageId,
    rgba: []u8,                 // decoded RGBA8 pixels (heap)
    width: u32,
    height: u32,
    gl_tex: u32,                // GL texture handle (0 until uploaded)
    refcount: u32,              // Kitty: 1 + placements; others: placements only
};

pub const Placement = struct {
    id: PlacementId,
    image_id: ImageId,
    cell_row: i32, cell_col: i32,  // top-left in grid logical coords; i32
                                   // because placements may anchor in
                                   // scrollback (negative rows relative to
                                   // current top-of-active-screen)
    cell_rows: u16, cell_cols: u16,// extent
    z: i32,                        // z-order; negative = below glyphs
    proto: ImageProtocol,
};
```

The `Cell` struct does *not* embed image data or a full reference.
It has a `flags: u8` bit marking "has image"; the actual
`PlacementId` lives in a side table keyed by `CellCoord`
(see `architecture.md` D3 reversal).

## ImageStore

Per-pane. Owned by `Terminal`.

Fields:
- `images: AutoHashMap(ImageId, Image)`
- `placements: AutoHashMap(PlacementId, Placement)`
- `by_image: AutoHashMap(ImageId, ArrayList(PlacementId))`
- `cell_index: AutoHashMap(CellCoord, PlacementId)` — fast lookup
  during scroll / reflow.
- `next_image_id: ImageId`, `next_placement_id: PlacementId`.

API (main thread only — touches GL):
- `decodeAndStore(rgba, w, h, proto) ImageId`
- `place(image_id, row, col, z, proto) PlacementId`
- `deletePlacement(pid)`
- `deleteImage(iid)` — cascades to placements
- `scrollRegionOut(from_row, to_row)` — drop placements whose
  bottom row falls above `from_row`; decrement image refcounts;
  free images whose refcount hits zero (non-Kitty only).
- `iterVisible(row_range) Iterator(Placement)`
- `reflow(line_map: AutoHashMap(OldRow, NewRow))`

## Per-protocol semantics

### Sixel (DCS q)
- One placement per received sixel stream.
- Anchored at the cursor position at receive time.
- `image_id` is synthetic (fresh, never reused).
- Refcount == 1 always (single placement); dropped when placement dropped.
- Dropped when the placement's bottom row falls out of scrollback.
- Clipped (not dropped) if horizontally overflowing after resize.

### Kitty graphics (APC G=...)
- **Image and placement are decoupled.** Kitty's protocol supports
  transmitting an image without placing it (cache for later) and
  placing an already-transmitted image without retransmission.
- Wire commands:
  - `a=t` transmit → `decodeAndStore` with protocol-supplied ID
    (`i=N`). Image refcount starts at 1 (protocol-held).
  - `a=T` transmit + place → both above.
  - `a=p` place → add placement referencing existing image id.
  - `a=d` delete — many variants:
    - `d=a` all placements for image id
    - `d=i` image (and all its placements)
    - `d=p` placement by id
    - `d=r` placements intersecting a region
    - Upper-case variants (`d=A`, `d=I`, `d=P`, `d=R`) also free
      the image data (decrement protocol-held refcount).
- **Chunked transmit** (`m=1` continuation) is reassembled in the
  parser before handoff to `decodeAndStore`.
- Persistent cache: an image with zero placements is still kept
  until explicit delete. (Our refcount = placement count + 1 for
  protocol-held; image freed only at refcount 0.)
- **`q=` quiet-response level** (not "scope" — common confusion):
  - `q=0` (default): we send OK/error responses after commands.
  - `q=1`: suppress OK responses, still send error responses.
  - `q=2`: suppress all responses.
  - The parser records `q` per command and conditions the response
    path accordingly. `q` has nothing to do with alt-screen scoping.
- **Negative z-order** (`z=-1`, `z=-2`, …): places image *beneath*
  cell glyphs. Renderer implication in §Render pass.

### iTerm2 OSC 1337 File=
- Payload is base64 of a full image file (PNG/JPEG/GIF/etc).
- v1 decodes **PNG only**, via vendored `stb_image.h` (~8 kLOC
  header-only including implementation, dual MIT / public domain,
  `#define STB_IMAGE_IMPLEMENTATION`). Other formats return a
  diagnostic.
- Base64 decode handled by our parser; streams may span multiple
  OSC writes (buffer across until terminator).
- Placement at cursor, sized by explicit `width=`/`height=` attrs
  or decoded image dimensions.
- Ephemeral (no protocol-level id). Synthetic `image_id`, single
  placement, same lifetime as sixel.

## Reflow and resize

The screen's `reflow(new_cols, new_rows)` re-wraps content.
Placement coordinates must translate.

Call order:
1. `Screen.reflow` collects an `old_row → new_row` map of logical
   lines that survived reflow.
2. After the grid is re-wrapped: `ImageStore.reflow(line_map)`.
3. Inside:
   - For each placement, translate `cell_row` via the map.
   - `cell_rows` / `cell_cols` are untouched (pixel-extent is
     preserved; grid width changes cause horizontal clipping, not
     deletion).
   - Update `cell_index` entries.
4. Placements whose anchor line was dropped (e.g. scrolled out
   during truncation) are deleted.

Font-size change (distinct from pane resize) recomputes
`cell_rows`/`cell_cols` as `ceil(pixel_height / new_cell_h)` so
the image retains its pixel extent across font-size changes.

## Alt-screen isolation

Each `Screen` (main, alternate) owns a distinct `ImageStore`.

- Switching buffers (DECSET 1049) does not mutate either store.
- Images transmitted on the main screen are not visible from the
  alt screen, and vice versa.
- Rationale: avoids cross-buffer leakage (alt screen `less` should
  not see main-screen plot images); matches user expectation from
  existing terminals.

v1 hardcodes per-screen isolation. Cross-screen sharing is post-v1
if a real need emerges. (Note: Kitty's `q=` parameter is *not*
related — that's quiet-response level; see §Per-protocol above.)

## Scrollback eviction

Screen scrollback is a fixed-capacity ring. On a row falling off
the top:

1. Iterate `cell_index` entries with `cell_row == evicted_row`.
2. For each, look up placement.
3. If `placement.cell_row + placement.cell_rows ≤ evicted_row + 1`
   (placement fully above live content): delete placement.
4. On placement delete, decrement `image.refcount`. If 0 and
   protocol ≠ Kitty-cached: delete image.

Kitty images with no placements live on until explicit `d=I`/`d=A`
per spec. This is correct but means long sessions with transient
Kitty images can accumulate; log a warning if the store exceeds
1 GB of decoded RGBA.

## GL texture lifecycle

- Texture creation (`glTexImage2D`): inside `Image.upload`, called
  on main thread with root context current.
- Texture deletion (`glDeleteTextures`): inside `Image.deinit`,
  same requirement. Asserted via a thread-id check in debug builds.
- On pane close: iterate all images in `ImageStore`, deinit each,
  then deinit placements, then drop the store.
- Textures are **never shared across panes in v1**. Two panes
  receiving the same Kitty image-id decode independently. (See
  `gpu.md` share groups for why sharing is theoretically possible
  — just not worth the complexity in v1.)

## Render pass

Kitty's z-ordering spec places negative-z images *below glyphs but
above cell backgrounds*. To honor that, the grid pass itself splits
into background and glyph sub-passes, with image sub-passes
interleaved:

1. **Grid — backgrounds pass** — draw each cell's bg color fill.
2. **Image pass (negative z only)** — `z < 0`, sorted ascending by z.
3. **Grid — glyphs pass** — draw each cell's foreground glyph.
4. **Image pass (non-negative z)** — `z ≥ 0`, sorted ascending by z.

Within each image sub-pass:
- `iterVisible(viewport_row_range)` yields placements overlapping
  the viewport.
- Group by `image.gl_tex` to minimize binds.
- For each placement, compute screen-space rect:
  - `x = col × cell_logical_w`
  - `y = (row - top_visible_row) × cell_logical_h`
  - `w = cell_cols × cell_logical_w`
  - `h = cell_rows × cell_logical_h`
- Draw textured quad.

Within a single z bucket, protocol order is stable:
`sixel < iterm < kitty` (convention, no semantic weight).
Placements fully outside the viewport are skipped.

**Shader implication**: the grid program's vertex shader accepts a
`pass` uniform (`bg_only` / `glyph_only`) so the same instance VBO
is drawn twice per frame. Alternative — two specialized programs —
is equally valid; benchmark during M3 and pick.

## Security and size limits

- **Per-image cap**: 64 MB decoded RGBA (~4 Mpx). Decoder rejects
  larger.
- **Per-pane cap**: 256 MB total decoded. Reject new decodes;
  emit warning into pane scrollback.
- **Per-window cap**: 1 GB across all panes. A hostile multi-pane
  session cannot chew unlimited memory by opening more panes.
  Enforced at the `Window` level via a cross-pane accounting object.
- **Kitty `t=t` (temp file) medium**: NOT supported in v1. The spec
  lets the server name arbitrary paths; security review needed.
- **Kitty `t=s` (shared memory) medium**: NOT supported in v1.
- **iTerm2 payloads > 32 MB**: rejected. Protects against OOM
  from malicious remotes.
- **Base64 decode** uses a streaming decoder with bounded allocation.

## Testing

- Corpus: sixel output from `chafa`, `img2sixel`, `yazi`.
- Kitty: `kitten icat` against sample images; `timg`; `viu`.
- iTerm2: `imgcat` (ships with iterm2 utilities).
- Unit tests for delete variants (ensure every `d=X` maps correctly).
- Reflow tests: place an image, resize, verify placement tracks.
- Alt-screen tests: place image, `tput smcup`, return, verify.

## Deferred to post-v1

- Global-scope Kitty images (`q=0`).
- Kitty `t=t` / `t=s` media.
- JPEG/GIF/TIFF for iTerm2.
- Cross-pane texture sharing.
- DMA-BUF / GPU-direct image import.
- Animated images (APNG, animated GIF).
- Unicode placeholder-based placement (Kitty extension).
