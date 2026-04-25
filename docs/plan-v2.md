# sketerm — plan v2

A continuation plan covering everything outstanding after the v1
milestones (M0–M10) shipped. v1 documents (`plan.md`, `architecture.md`,
`milestones.md`, etc.) describe what's already done; this file is the
forward-looking roadmap.

## Status snapshot (entry to v2)

- **Done**: M0 toolchain, M0.5 GL spike, M1 PTY+parser, M2 grid+CSI,
  M3 GL renderer, M4 input/IME/clipboard, M5 OSC 52/8/7/133-mark,
  M6 tabs+context menu, M7 splits, M8 layout JSON+DSL, M9a kitty
  graphics (full receive: chunked, PNG, transmit/place split),
  M9b sixel, M9c iTerm2 inline images, plus M10 polish:
  HarfBuzz ligature shaping, config file, live font resize,
  scrollback search, soft-wrap reflow, grapheme clusters,
  rectangular selection, OSC 8 markdown copy, audible bell,
  scrollback indicator, save-layout shortcut, theme integration.
- **Tests**: 280+ unit + conformance tests (kitty + wezterm ports).
- **Binary**: ~13.6k LOC Zig + vendored stb_image. Daily-driver.

## What's left (this plan)

Eight milestones. **M11.0 is highest priority — known regression: images
do not actually render in real-world use.** Receive pipeline tests
prove the parser path works (7 integration tests in
`src/grid/image_pipeline_test.zig`), so the bug is GL-side.

| #     | Milestone                            | Status   | User-visible?                                |
| ----- | ------------------------------------ | -------- | -------------------------------------------- |
| M11.0 | ✅ Image render regression — fix #1 | done     | Receive bug; verified via smoke-image.       |
| M11   | ✅ Legacy DEC modes (SCNM/COLM/VT52) | done     | Niche; spec compliance.                      |
| M12   | ✅ Per-line scaling (DECDHL/DECDWL)  | done     | Visible if any DEC app uses it.              |
| M13   | ✅ Bidi + complex-script shaping     | done     | Cursor + selection visual-aware now too.     |
| M14   | ✅ OSC 133 prompt navigation         | done     | Stable u64 line IDs.                         |
| M15   | ✅ Kitty progressive-enhancement kbd | done     | Level 1 + flag 0x02 release+repeat events.   |
| M16.1 | ✅ Per-row dirty + persistent VBO    | done     | Per-row glBufferSubData via row_needs_upload.|
| M16.2 | ✅ Parser print_run batching         | done     | 64-byte fixed-size batches.                  |
| M16.3 | ✅ GPU instancing                    | done     | New CellPass — one quad template, N inst.    |
| M17.1 | ✅ Atlas multi-page LRU              | done     | GL_TEXTURE_2D_ARRAY, 4 pages, LRU eviction.  |
| M17.2 | ✅ Kitty `o=z` zlib                  | done     | std.compress.flate `.zlib`.                  |
| M17.3 | ✅ Kitty animation frames            | done     | a=f appends, a=a controls, time-driven tick. |
| M17.4 | ✅ Image re-upload after GL loss     | done     | Pending pixels retained.                     |
| M17.5 | ✅ Right-click "Copy Link"           | done     | Context-aware; works on scrollback.          |
| M17.6 | ✅ Save Layout As… via GtkFileDialog | done     | Ctrl+Shift+Alt+S.                            |
| —     | ✅ Bidi-aware selection              | done     | Click+drag in logical space; visual remap.   |

¹ M13 covers paragraph-level bidi + complex-script shaping. Cursor
positioning visual-aware. Selection in mixed bidi text remains
logical-anchored — visually-correct only for line-aligned selections.

² M15 covers level-1 disambiguate flag (Tab vs Ctrl+I etc). Event
types (release/repeat — flag 0x02), alt-keys (0x04), all-keys-as-
escape (0x08), associated-text (0x10) require GTK key-released
wiring + larger encoder rewrite. Most apps don't enable them.

Total: ~34–41 focused days.

### M11.0 — Fix image rendering regression

**Status**: Receive pipeline confirmed working. Kitty graphics PNG +
multi-chunk + a=t/a=p / sixel / iTerm2 1337 all parse, decode to RGBA,
and fire `Screen.Sink.on_image` correctly (proven by integration
tests). The break is somewhere between `Pane.onImageEvent` and what
the user sees on screen.

**Diagnostic instrumentation shipped** (`--debug-images` flag):
- `image_store.flushUploads` prints upload outcomes + `glGetError`.
- `image_pass.draw` prints viewport, image count, per-image position
  + size + tex id + glError.

**Workflow to diagnose**:
```
./zig-out/bin/sketerm --debug-images 2>&1 | tee /tmp/img.log
# Inside: send a kitty graphics escape (e.g. via `chafa some.png`).
# Quit, paste /tmp/img.log.
```
The log tells us exactly where the path is breaking:
1. **No `[image] upload` line** → sink wiring is broken (ingest never
   fired into Pane).
2. **Upload line with `glErr=0x501` (invalid value)** → texture upload
   failed; likely format / pixel data mismatch.
3. **Upload `tex=N` with `[image] draw N=0`** → image got dropped
   between flush and draw (atlas re-realize wiped it without keeping
   pending data, despite the M9 fix).
4. **Draw fires with valid tex, glErr=0** but nothing on screen →
   coordinate / blending / Y-flip issue. Most likely culprits:
   - `cell_w/cell_h` set in widget pixels instead of physical (we
     fixed this once; it may have regressed).
   - Image rendered before `glClear` is finished (race in command
     ordering).
   - Pad offset mismatch puts image outside scissored region.
5. **Draw fires correctly but image upside down / wrong color** →
   PNG decode flipped or premultiplied alpha mismatch.

**Likely root cause hypotheses (highest probability first)**:
1. **`cell_w`/`cell_h` mismatch on HiDPI**: `image_store.cell_w` set
   from `atlas.cell_w` (physical px). Viewport in physical px. Should
   match — unless `gtk_widget_get_scale_factor` reports >1 and the
   GLArea framebuffer has an unexpected scale.
2. **Atlas re-realize drops images via `forgetGL`**: when split / tab
   / resize triggers an unrealize, `forgetGL` deletes images that have
   already been uploaded (no `pending`). Result: any image more than
   one frame old vanishes on context loss. The fix at M17.4 keeps
   pixels around for re-upload but it's not in yet.
3. **`gtk_gl_area_make_current` not called before `flushUploads`**:
   `onRender` hands us a current context, but only AFTER `realize`
   completes. If `flushUploads` runs while `program == 0`, the texture
   gets uploaded into a stale context.
4. **`image_pass.program` is 0 after split-and-re-realize** because
   `forgetGL` was called but `realize` for image_pass didn't run.

**Fix plan**:
1. Implement M17.4 (keep RGBA after upload) — eliminates hypothesis 2.
2. Assert `program != 0` in image_pass.draw, log if zero.
3. Add `glGetError()` after every GL call in flushUploads (logged when
   `debug == true`).
4. Build the smoke-image binary (below) so future regressions are
   caught by `zig build smoke-image` in CI rather than human testing.

### M11.0a — Headless image render smoke (CI)

A binary target that:
1. Initializes EGL with `EGL_PLATFORM_SURFACELESS_MESA`.
2. Creates a 256×256 framebuffer.
3. Realizes ImagePass + ImageStore.
4. Adds a known 32×32 RGBA image at cell (0,0).
5. Calls flushUploads + draw.
6. `glReadPixels` and asserts at least one pixel matches input.
7. Exits 0 on pass, non-zero on fail.

Run as `zig build smoke-image`. Catches all GL-side regressions
without requiring an X session.

**Effort**: 1-2 days for diagnose-fix-test. EGL surfaceless is ~150
lines of well-trodden boilerplate.

---

## M11 — Legacy DEC modes

Three small DEC features that existing v1 apps occasionally test.

### M11.1 — DECSCNM (CSI ?5 h/l) — reverse video screen

**Goal**: when set, the entire screen renders with fg/bg swapped.

**Architecture**:
- Add `Screen.reverse_screen: bool` (default false).
- Mode toggle in `csi('h')` / `csi('l')` for `?5`.
- Renderer: when `reverse_screen` is true, swap `default_fg` ↔
  `default_bg` *and* invert the resolved fg/bg of every cell whose
  color resolves to default. Per-cell explicit colors are unaffected
  (matches xterm).
- Reset by DECSTR (CSI ! p) and RIS (ESC c).

**Reference**:
- WezTerm: `term/src/terminalstate/mod.rs` — search `ReverseVideo`.
- Kitty: `kitty/screen.c` — `set_mode_from_const(SCREEN_REVERSE_VIDEO)`.

**Tests**: feed `\e[?5h X \e[?5l Y`, assert cell at row 0 col 0 has
default attrs; assert renderer's effective fg/bg swapped during the
window.

**Effort**: 0.5 day.

### M11.2 — DECCOLM (CSI ?3 h/l) — 80/132 column

**Goal**: switch the screen between 80 and 132 columns; clear screen,
home cursor, reset DECSTBM as a side effect.

**Architecture**:
- Most modern terminals gate this behind DECSET 40 ("Allow 80 ↔ 132
  column switching"). We follow suit. `Screen.allow_decolm: bool`,
  default false.
- When `allow_decolm` is set and DECSET 3 fires:
  - Resize the *Screen* to 132 cols (or 80 on DECRST 3) at the
    current pixel width — cells visually compress/expand.
  - Clear screen, home, reset margins, exit alt screen.
- We do NOT resize the GTK window. Modern hardware-resolution
  windows are user-controlled; commanding a window resize from a
  child PTY is hostile.

**Reference**:
- WezTerm: `term/src/terminalstate/mod.rs:1615` (commented spec link).
- xterm-spec: https://vt100.net/docs/vt510-rm/DECCOLM.html

**Tests**: feed `\e[?40h\e[?3h`, assert `screen.cols == 132` and
screen is cleared; `\e[?3l` returns to 80 (the current width before
the toggle).

**Effort**: 1 day.

### M11.3 — VT52 mode (DECRST 2 / DECANM)

**Goal**: when DECANM is unset (DECRST 2), interpret escape sequences
in VT52 format. DECSET 2 returns to ANSI/VT100 mode.

**Architecture**:
- Add `parser.vt52: bool`.
- New parser branch from ESCAPE state: when in VT52 mode, the next
  byte is a single-letter VT52 command (no CSI dispatch).
- VT52 command set:
  | Cmd | Action                                        |
  | --- | --------------------------------------------- |
  | A   | cursor up                                     |
  | B   | cursor down                                   |
  | C   | cursor right                                  |
  | D   | cursor left                                   |
  | F   | enter graphics charset                        |
  | G   | exit graphics charset                         |
  | H   | cursor home                                   |
  | I   | reverse line feed                             |
  | J   | erase to end of screen                        |
  | K   | erase to end of line                          |
  | Y   | direct cursor address: row, col = next 2 bytes - 0x20 |
  | Z   | identify → respond `ESC / Z`                  |
  | =   | enter alt keypad                              |
  | >   | exit alt keypad                               |
  | <   | exit VT52, return to ANSI                     |

**Reference**:
- xterm-spec: https://vt100.net/docs/vt100-ug/chapter3.html#S3.4
- Neither WezTerm nor Kitty implement VT52; we're alone here.

**Tests**: enter VT52 (`\e[?2l`), feed `\eA`, assert cursor moved up.
Feed `\eY!"`, assert cursor at row 1 col 2 (`!` = 0x21 → row=1; `"` =
0x22 → col=2). Feed `\e<`, assert ANSI mode restored.

**Effort**: 1.5 days.

---

## M12 — Per-line scaling (DECDHL/DECDWL)

**Goal**: support `ESC #3/#4/#5/#6` line attributes:
- `#3` — DECDHL top half (line is double-width and renders the upper
  half of double-height glyphs)
- `#4` — DECDHL bottom half (lower half of double-height glyphs)
- `#5` — DECSWL — single width, single height (default)
- `#6` — DECDWL — double width, single height

**Architecture**:
- `Line.scaling: enum(u8) { single, dwl, dhl_top, dhl_bot }` (1 byte
  added to Line struct — fits without growing it).
- Apply on the cursor's current line. Idempotent (no clear).
- Renderer effects per-line:
  - `dwl`: render glyphs at 2× horizontal scale, halve effective col
    count (cells beyond `cols/2` are not visible).
  - `dhl_top`: 2× scale on both axes, render only the top half of
    each glyph (clip to upper half of cell rect).
  - `dhl_bot`: same but render lower half.
- Cursor: stays at logical column; visual position is `logical_col ×
  2` for non-`single` lines.
- Selection: per-cell, no special handling needed (renderer scales
  the overlay too).
- Soft-wrap: when reflowing, lines preserve their scaling attribute.

**Reference**:
- WezTerm: `wezterm-surface/src/line/line.rs:343` —
  `set_double_height_top`, `set_double_height_bottom` plus
  `LineBits::DOUBLE_WIDTH`.
- Kitty: `line.c` — line-level scale flags in line attrs.

**Tests**:
- Feed `\e#6Hello`, assert line[0].scaling == .dwl.
- Render path: physical pixel width of cell on dwl line is `2 ×
  cell_w`.
- DECDHL top/bottom pair renders the same logical content but only
  the upper/lower half of glyphs.

**Effort**: 3-4 days. Edge cases: cursor across DH lines, scrollback
entry, mixed scaling within scroll region.

---

## M13 — Bidi + complex script shaping

The big one. Goal: Arabic, Hebrew, Indic, Thai render correctly.

### Design

We will **link system fribidi** (`extra/fribidi` on Arch — already
on every Linux distro). It provides UAX #9 in ~50 KB, well-tested,
identical to what foot uses. We do *not* port WezTerm's `bidi/` crate
(5 kLOC Rust; significant porting work for ~no advantage over
fribidi).

For complex shaping (Arabic contextual forms, Indic reordering,
Thai), HarfBuzz already does the work — provided we shape per
unicode-script run rather than ASCII-only.

### M13.1 — Link fribidi

- Add `-lfribidi` to `build.zig` via pkg-config.
- `c.zig` adds `@cInclude("fribidi.h")`.
- Wrapper `src/grid/bidi.zig` exposes:
  ```zig
  pub fn lineLevels(text: []const u32, levels: []u8, base_dir: Dir) Dir
  ```
  Maps to `fribidi_get_par_embedding_levels_ex`. Returns the resolved
  paragraph direction.

### M13.2 — Per-line bidi resolution in renderer

Today's render path walks cells L→R. Replace with:

1. For each rendered line, build `cps[]` of base codepoints (one per
   non-wide-cont cell).
2. Call `bidi.lineLevels(cps, levels, .auto)`.
3. Group cells into runs of equal level + equal style + equal script.
4. For each run:
   - If level is even (LTR): emit cells L→R as today.
   - If level is odd (RTL): reverse the visual cell order, emit at
     descending visual columns; HarfBuzz shaping is asked to produce
     glyphs in visual order (set `HB_DIRECTION_RTL`).

### M13.3 — Extend HB shaping path to non-ASCII

Currently `runIsPureAscii(cells)` gates the HB path because we
hardcoded LATIN earlier. With `hb_buffer_guess_segment_properties`
already in (post-tofu fix), the path is correct for non-Latin —
remove the ASCII-only gate but split runs at script boundaries:

```zig
fn detectScriptRuns(cells, scripts_out) usize
```

Splits a same-style run into sub-runs of same Unicode Script (using
`hb_unicode_script` on representative codepoints).

### M13.4 — Cursor in bidi text

In a mixed line, logical column N may not map to visual column N.
Use fribidi's level array to compute visual column.

```zig
pub fn visualColForLogical(line, logical_col) u32
```

The cursor renders at the visual column.

### M13.5 — Selection in bidi

Selection stays *logical* (rows + cols in source order). The visual
overlay is per-cell, so a logical run that wraps visually shows as
disjoint highlight rectangles — that's correct UX (matches GNOME
Terminal, Konsole).

### M13.6 — Tests

- Pure Hebrew line: `אבג` ("ABC" Hebrew) renders with
  cell0 at the *rightmost* visual column.
- Mixed: `Hello אבג world` — Latin LTR, Hebrew RTL
  embedded.
- Arabic contextual forms: `بلله` ("Allah") —
  HarfBuzz produces a single ligature glyph; we render it.
- Indic reordering: `कि` (KA + i-vowel) — visual order has
  the i-vowel rendered BEFORE the KA. HB handles this.

### Scope warning

Bidi correctness has no end of edge cases (numeric runs in RTL
context, neutral characters, paired brackets, line-breaking). We aim
for "correct for paragraph-direction text and simple mixed runs",
matching foot's level. Full UBA conformance is out of v2 scope.

**Reference**:
- fribidi docs: https://github.com/fribidi/fribidi/blob/master/lib/fribidi-bidi.h
- WezTerm UBA port (for understanding, not direct porting):
  `external/wezterm/bidi/src/lib.rs`
- foot bidi integration: small example we can mirror.

**Effort**: 7-10 days.

---

## M14 — OSC 133 prompt navigation

**Goal**: bind Ctrl+Shift+Up / Ctrl+Shift+Down to jump between OSC
133 prompt marks (recorded by every modern shell with shell-
integration: bash via vsc, fish, zsh, atuin, etc.).

**Problem**: current `prompt_marks` ring stores display-row
coordinates which become stale as content scrolls.

**Solution**: monotonic absolute line IDs.

### Architecture

- Add `Screen.next_line_id: u64`, increments on every NEW line
  birth (LF on bottom row when scroll-up occurs, or new row in
  initial fill). Each `Line` carries an `id: u64`.
- On reflow / resize, IDs propagate by content (split lines inherit
  the parent's ID; rejoined lines take the first source ID).
- `prompt_marks` becomes `[]u64` of line IDs, capacity 256, ring
  semantics preserved.
- Navigation:
  - `Action.prompt_prev` / `Action.prompt_next`.
  - Keybind: Ctrl+Shift+Up / Ctrl+Shift+Down.
  - Implementation: scan prompt_marks for a mark whose line ID is
    visible (in scrollback or active), translate to view_offset,
    set it.

### Tests

- Feed `\e]133;A\e\\` 3 times across multiple LFs, verify 3 distinct
  IDs in the ring.
- Force scroll-out (1000 LFs), verify the recorded IDs still resolve
  to the right scrollback rows.

**Effort**: 2-3 days.

---

## M15 — Kitty progressive-enhancement keyboard

**Goal**: implement the Kitty keyboard protocol so neovim/emacs see
disambiguated key codes (e.g. `Ctrl+i` ≠ `Tab`, `Shift+Enter` ≠
`Enter`).

Spec: https://sw.kovidgoyal.net/kitty/keyboard-protocol/

### Architecture

- `Screen.kitty_kbd_flags: u8` (bitmask) and `flags_stack: [9]u8`
  for push/pop.
- Recognised CSI sequences:
  | Sequence       | Action                                  |
  | -------------- | --------------------------------------- |
  | `CSI > N u`    | Set flags = N                           |
  | `CSI = N ; M u` | M=1 set, M=2 push+set, M=3 pop          |
  | `CSI < N u`    | Pop N levels (default 1)                |
  | `CSI ? u`      | Query — reply `CSI ? <flags> u`         |

- Flag bits:
  - 0x01 disambiguate
  - 0x02 report event types (press/release/repeat)
  - 0x04 alternate keys
  - 0x08 all keys as escape codes
  - 0x10 associated text

- Encoder in `src/ui/input.zig`:
  - Plain key: `CSI <unicode-key-code> u`
  - With mods: `CSI <key> ; <mods> u`
  - With event: `CSI <key> ; <mods> : <event> u`
  - Where `event` ∈ {1=press, 2=repeat, 3=release}.

- Modifiers numerically:
  shift=1, alt=2, ctrl=4, super=8, hyper=16, meta=32, caps_lock=64,
  num_lock=128. Modifier value = `1 + sum_of_held_modifiers`.

### Implementation steps

1. Parse the new CSI variants (M15.0 — half day).
2. Flag stack management (M15.1 — half day).
3. Encoder rewrite under `kitty_kbd_flags != 0` (M15.2 — 2 days).
4. Disambiguation rules (M15.3 — 1 day):
   - Tab vs Ctrl+i, Enter vs Shift+Enter, Esc vs the literal Escape
     key; Ctrl+letter combos.
5. Handle release events (M15.4 — 1 day):
   - Wire to GTK key-released signal which we currently ignore.
6. Tests (parser + encoder).

**Reference**:
- Kitty spec (linked above) is the authoritative source.
- WezTerm has it: `wezterm-input-types/src/lib.rs::KeyboardEncoding`.

**Effort**: 4-5 days.

---

## M16 — Render + parser performance

Optional unless profiling on hardware GPU shows pain. Current llvmpipe
path is acceptable for typical screens.

### M16.1 — Per-row dirty tracking + persistent VBO

- `GridPass` retains the VBO across frames.
- Per-row vertex byte-range table.
- `buildVertices` skips rows where `Line.dirty == false` and
  `cursor_row != row` and selection didn't intersect this row last
  frame.
- Cursor / selection / preedit / bell flash live in a separate
  per-frame "overlay VBO" so they don't dirty static grid rows.

**Effort**: 3-4 days.

### M16.2 — Parser print_byte batching

Today: 1 event per print byte. Bench: ASCII at ~1.6 MB/s, CSI at ~107
MB/s. Goal: fold runs of consecutive printable bytes into a single
event.

- New event variant `print_run: { bytes: [N]u8, len: u8 }` (N up to 64).
- Parser ground state batches printable bytes into a buffer; flushes
  on any non-printable byte or buffer full.
- Screen.apply for `print_run` decodes UTF-8 and prints each.

**Effort**: 2 days.

### M16.3 — GPU instancing

- Replace per-cell 6-vertex quads with a single 6-vertex template
  drawn N times via `glDrawArraysInstanced`.
- Per-instance attributes: cell_x, cell_y, fg, bg, glyph_uv0_uv1.
- VBO size from `cells × 192 B` to `cells × ~32 B`.

**Effort**: 3-4 days.

---

## M17 — Edge polish

Six small reliability items. Each ships independently.

### M17.1 — Atlas multi-page LRU

When the single 2048×2048 R8 page fills, today's path returns the
empty placeholder. Long sessions with many unique CJK + emoji glyphs
hit this.

- Atlas grows pages on demand (cap at 4 pages = 16 MB).
- LRU eviction: track per-glyph "last used frame", evict oldest when
  a new page would be needed.
- Renderer binds the right page per glyph (split runs by atlas page
  in the worst case).

**Effort**: 2-3 days.

### M17.2 — Kitty graphics `o=z` zlib

- Use `std.compress.flate.inflate` against the base64-decoded payload
  when `cmd.compression == 1`.
- Apply between base64-decode and format-decode in `kitty_images.zig`.

**Effort**: half day.

### M17.3 — Kitty graphics animation frames

- Kitty `a=f` (frame add) appends a frame to an existing image.
- `StoredImage` becomes `StoredAnimation` with `frames: []Frame` and
  per-frame `delay_ms`.
- Rendered frame index advances on a g_timeout_add tick.

**Effort**: 3-4 days.

### M17.4 — Image re-upload after GL context loss

`ImageStore.forgetGL` currently drops uploaded images (no source
pixels retained). On split-and-re-realize, those images vanish.

- Keep RGBA in `Image.source` after upload (memory cost: image px
  bytes, capped by image-store quota).
- forgetGL: set `gl_tex = 0`, keep `source` and `pending`. On next
  flush, re-upload from `source`.

**Effort**: 1 day.

### M17.5 — Context-aware right-click menu

Today's menu is built once at pane attach. Result: "Copy Link" can't
appear conditionally on hyperlinked cells.

- `menu.attach` takes a `pre_popup_fn(GMenu, ctx)` callback.
- Pane's pre_popup checks the cell at the right-click coords for
  `has_link`, adds/removes "Copy Link" entry.
- "Copy Link" action puts the URI on the clipboard.

**Effort**: 1-2 days.

### M17.6 — "Save Layout As..." menu item

Today: only auto-save and Ctrl+Shift+S to last.json.

- Menu: File → Save Layout As… opens GtkFileChooserNative.
- Writes `.json` or `.layout` based on extension.

**Effort**: 1 day.

---

## Cross-cutting concerns

### Build dependencies (additions)

- `fribidi` (M13) — link via pkg-config, system package.

### Testing strategy

- M11–M12 / M14 / M15: extend conformance tests in
  `src/parser/screen_conformance_test.zig` and
  `src/ui/input_conformance_test.zig`.
- M13: new file `src/grid/bidi_test.zig` with golden cases:
  bidirectional fixture text from the Unicode Bidi Test (UBT) suite.
  Sample size: ~50 cases, not the full 700k UBT lines.
- M16: extend `src/bench_parser.zig`; add `src/bench_render.zig`
  (offscreen GL context, time `buildVertices` for big grids).
- M17.3: animation frames need a fixture sequence.

### Documentation updates

- `docs/architecture.md`: add sections for bidi pipeline and per-line
  scaling.
- `docs/protocols.md`: mark M11–M15 sequences as supported.
- `docs/SESSION.md`: append per-milestone progress.
- `docs/external-references.md`: update WezTerm/Kitty source paths
  cited above.

### Risks

| Risk                                                                | Mitigation                                                                              |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| **R1**: bidi rendering breaks existing LTR-only tests              | Gate behind `Line.bidi_enabled` (default true once ready). Roll out as an opt-out flag. |
| **R2**: DECCOLM clears scrollback unexpectedly                      | Spec says clear screen, NOT scrollback. Verify both directions.                         |
| **R3**: HarfBuzz shaping per-script run blows up perf for long lines| Cache shape results per (script, style, content-hash) — already have `glyph_cache`.    |
| **R4**: line ID overflow in long sessions                           | u64 — won't wrap in any plausible session.                                              |
| **R5**: kitty kbd protocol release events spam PTY                  | Most apps that enable level 0x02 are designed for it; others won't enable.              |
| **R6**: animation frame timer drift                                 | Use g_get_monotonic_time-driven scheduling, not naive g_timeout intervals.              |

### Order recommendation

If you tackle this serially, the most impactful first sequence is:

1. **M14** (prompt nav) — small + immediate quality-of-life.
2. **M13** (bidi) — biggest user-visible feature, longest tail.
3. **M15** (kitty kbd) — power users will notice.
4. **M12** (per-line scaling) — visible if you encounter DEC apps.
5. **M11** (DEC modes) — completeness; very few apps emit these.
6. **M16** (perf) — only if profiling shows pain.
7. **M17** (polish) — pick items as they bite.

---

## What's explicitly NOT in v2

- **Lab/oklch color spaces** — no consumer-software demand; revisit
  when an actual TUI emits the syntax.
- **Network multiplexer / SSH integration** — out of scope; tmux works.
- **Mosh** — different protocol; out of scope.
- **GPU font rasterization** (msdfgen / sdf) — current FreeType is
  fine.
- **Touchscreen / two-finger swipe** — nobody asked.

This list is firm — additions require a real user request first.
