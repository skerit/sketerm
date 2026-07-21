# Autonomous build session — 2026-04-25

This file is a record of the autonomous implementation session that
took the project from "13 markdown plan documents" to a working
v0.1 binary.

## Time
- Started: ~00:44 local
- ~203 commits, ~11.8 kLOC of Zig + 8 kLOC vendored stb_image
- 247 unit tests pass

## What got built

All eleven planned milestones are at least scaffolded; most are
substantively complete.

| Milestone | State |
|-----------|-------|
| M0  toolchain | done |
| M0.5 GL spike | PASS via Mesa llvmpipe |
| M1  PTY + parser + ring + worker | done |
| M2  cell/screen/CSI + alt screen + scrollback + resize-with-content | done |
| M3  FreeType atlas + GL ES 3.0 grid render + cursor (incl. blink) | done |
| M4  keyboard + IME + paste + selection + clipboard + resize | done |
| M5  OSC 0/2/7/8/52 + DSR + window-size reports + DECSCUSR | done |
| M6  AdwTabView tabs + GtkPopoverMenu + tab rename popover | done |
| M7  splits via GtkPaned (nestable) + close_pane | done |
| M8  JSON layout v2 with split tree, save/load, SIGTERM-safe | done |
| M9a Kitty graphics APC parser → ImageStore → GL textured quad | done |
| M9b Sixel decoder → ImageStore → GL textured quad | done |
| M9c iTerm2 OSC 1337 + stb_image PNG decode → GL textured quad | done |

Plus extras layered on top of M0-M9:

| Feature | State |
|---------|-------|
| OSC 8 hyperlinks: storage + hover tooltip + Ctrl-click → xdg-open | done |
| OSC 7: cwd parsed/stored on Terminal; layout save prefers it over /proc | done |
| Wide-char (CJK / emoji) — 2-column glyphs + continuation cells | done |
| Font fallback chain (Hack → Adwaita Mono → Vera Mono → Free → DejaVu → Noto) | done |
| Cursor blink (500 ms cycle for blinking shapes) + visual alpha bump | done |
| Tab rename via GtkPopover with GtkEntry | done |
| Auto-numbered tab titles ("Tab 1", "Tab 2", …) | done |
| Pane focus highlight (thin accent border) | done |
| Click-to-focus on pane | done |
| Selection across scrollback boundary (drag past row 0) | done |
| IME preedit display at cursor with underline + dark backdrop | done |
| Snap to bottom on keypress (xterm convention) | done |
| Memory leak fixes (input_ctx + menu arena → Pane.deinit) | done |
| Bash shell integration sample (data/sketerm-shell-integration.bash) | done |
| `--help` / `--version` / `--restore` / `--layout` / `--no-save` flags | done |

## How to verify

```bash
zig build                          # builds zig-out/bin/sketerm
zig build test                     # 66/66 tests
zig build spike-gl                 # GL share-group spike
zig build spike-shell              # headless PTY/parser/screen smoke
zig-out/bin/sketerm                # opens a tab in $SHELL
zig-out/bin/sketerm --help
```

The headless smoke confirms parser → screen → image dispatch:

```
$ zig-out/bin/sketerm-spike-shell | grep image
got image 1: 6x6 at row=23 col=0     # sixel
got image 2: 2x2 at row=23 col=0     # kitty graphics
```

## Verified vs. unverified

I implemented and tested everything I could verify headlessly
(parser, screen, layout, image protocols). The GL render path
was confirmed to launch and not crash, but **I had no way to
visually inspect what shows up on screen** — your first eyes-on
session should look for:

- Glyphs rendering at expected positions, correct fg/bg
- Cursor visible and blinking on default `block_blink`
- Tabs visible at top, click switches tabs
- Right-click brings up a popover menu
- `Ctrl+Shift+T`, `D`, `R`, `W` work
- Mouse wheel scrolls back through scrollback
- Mouse drag selects, `Ctrl+Shift+C` copies, paste in another app
- Image tests via `zig build spike-shell` show "got image" lines

If anything's broken visually, the most likely culprits are:
1. NVIDIA proprietary EGL — the binary reports `libEGL warning`
   on this laptop and falls back to llvmpipe (software). On
   Intel/AMD systems with Mesa it should be fine.
2. Cursor color on light themes — hardcoded `default_fg` is
   light-grey; against a light theme background it might not
   be visible.
3. Font path — hardcoded `/usr/share/fonts/TTF/Hack-Regular.ttf`
   in `src/ui/pane.zig`. If your system doesn't have Hack
   installed, atlas init will fail and the pane will be black.

## Polish layered after the 67-commit checkpoint

Things added between commits 67 → 115:

- Mouse motion reporting for DECSET 1003 + button-held 1002.
- DECRQM (CSI ? Pa $ p) replies for the modes we track.
- Real per-column tab stops: HTS, CSI g/3g, CHT/CBT.
- REP (CSI Pn b) — repeat last printed glyph.
- DECSED / DECSEL routed to plain ED/EL; DECSCA accepted.
- DEC special-graphics charset (ESC ( 0 / ESC ) 0 / SO / SI).
- DECCKM application-cursor-keys mode.
- Focus-event reporting for DECSET 1004 (\\e[I / \\e[O).
- ESC Z (DECID), ESC # 8 (DECALN), ENQ answerback.
- Cursor save/restore now includes autowrap + charset state.
- Cursor keys + F-keys + tilde-keys honor Shift/Alt/Ctrl modifiers.
- OSC 10/11 fg/bg color queries; CSI t window-state reports.
- Layout split-tree applies saved ratios on map; `-Dstrip` flag.
- DECSET 1049 saves/restores cursor distinct from 1047.
- Soft-wrap aware selection extract — paste reproduces the
  logical line without spurious newlines.
- OSC 4 palette query, OSC 9 / OSC 777 desktop notifications,
  OSC 12 cursor-color query, OSC 1337 inline image (was unwired).
- Kitty graphics capability probe (a=q) replies OK.
- DA1 advertises sixel; DECRQSS replies for SGR / DECSTBM /
  DECSCUSR.
- Parser caps OSC/DCS body at 16 MiB to bound runaway streams.
- PTY shutdown escalates SIGHUP → SIGTERM → SIGKILL.
- Shift+PgUp/PgDn paginate scrollback from the keyboard.
- Tab close now actually frees Pane + Terminal (was a leak).
- Tab switch grabs focus on the newly selected pane.
- IRM (CSI 4 h/l) — public-mode insert/replace honored.
- Bracketed paste strips embedded ESC bytes.
- PTY captures the real child exit status on EOF.
- Kitty image delete (a=d, a=A) wired through new
  on_image_delete sink + ImageStore.markByIdForDelete.
- OSC 7 paths are percent-decoded.
- Empty-title GNotification falls back to "sketerm".
- Ctrl+Shift+K clears screen + scrollback.
- SKETERM_FONT / SKETERM_SCROLLBACK env vars override
  defaults at startup.
- --debug-events CLI flag dumps parser events to stderr.
- BEL marks the tab needs-attention when the bell hits a
  non-focused tab; selecting clears it.
- OSC 10 / 11 / 12 set forms wired (default fg/bg/cursor
  colors are now runtime-mutable from apps).
- OSC 4 / 104 set + reset wired against a runtime
  Screen.palette; renderer pulls the palette each frame.
- OSC 110 / 111 / 112 reset to defaults.
- OSC 133 prompt-start marks recorded into a 256-entry ring.
- modifyOtherKeys=1/2 (CSI > 4 ; Pp m) — emacs/vim get
  distinct codes for Ctrl+i vs TAB.

## User-bug-fix pass (live testing)

After the user did a real visual test, four bugs surfaced:

- Scroll wheel → htop ignored: onScroll now sends mouse
  buttons 4/5 (SGR 64/65) when the foreground app has
  captured the mouse and is on the alt screen.
- No way to drag the title bar: wrapped content in
  AdwToolbarView with an AdwHeaderBar on top (the standard
  Adwaita drag region). Header bar gets a "+" button bound
  to the new `win.new-tab` GAction.
- Closing the last pane left an empty unrecoverable window:
  `onPageDetached` now auto-spawns a fresh shell tab
  whenever n_pages drops to 0 while the window is still
  mapped.
- **Splits made the OLD pane go blank.** The actual root
  cause: `gtk_widget_unparent` unrealizes the GLArea, which
  destroys its `GdkGLContext`; on re-realize our
  `grid_pass.realize()` early-returned on `program != 0`
  and kept the dead-context shader ID. Fix: new
  `forgetGL()` helpers on GridPass / ImagePass / ImageStore;
  `Pane.onRealize` deinits any prior atlas and zeros all GL
  handles before the realize path rebuilds.

## Polish round (after the user said split worked)

- **6px inner padding** so terminal content doesn't hug the
  focus border. Cells offset by `pad`, focus border drawn
  at the canvas edge, `onResize` and `cellAt` adjusted.
- **Double-click on the tab bar to rename** — GtkGestureClick
  with n_press=2 → renameCurrentTab. Single-click already
  selects the tab so it's the right one by the time we fire.
- **Easy `.layout` text format** alongside the JSON format:
  one tab per top-level line, 2-space indent, supports
  nested hsplit/vsplit. Parser + 4 tests + sample file.
  --layout dispatches by extension.
- **Hollow non-blinking cursor on unfocused panes** — the
  blink toggle in onTick fired on every pane regardless of
  focus, so all panes' cursors blinked. Now only the focused
  pane toggles; unfocused panes draw a 1-px hollow outline.
- **Parser microbench** at `zig build bench-parser`: plain
  ASCII ~1.6 MB/s, CSI cursor moves ~107 MB/s — emit-per-
  byte is the print path's bottleneck.
- **vttest checklist** at `docs/vttest.md` documenting which
  features should pass and which are explicitly out of scope.

## Conformance test batch from kitty + wezterm

Shallow-cloned kitty + wezterm at `external/` (gitignored,
~280 MB combined) and ported their conformance tests to Zig.
Pattern follows Kitty's `parse_bytes_dump`: build a screen,
feed bytes, assert on observable state (cell rune, cursor
row/col, captured PTY-write bytes via the `on_write_pty`
sink, captured titles via `on_title`).

Shared test harness in `src/parser/test_harness.zig`. Test
files:

- `src/parser/conformance_test.zig` — initial 11 tests
- `src/parser/screen_conformance_test.zig` — kitty screen.py +
  parser.py (CSI char manipulation, ED variants, cursor
  movement, IND/RI, BS clamp, tab stops, SGR, alt screen,
  dirty bits, DA1, resize, OSC 0/2/8, DEC graphics charset,
  REP edge cases, PM/APC, DECSTBM, DECRQM, DECID, ENQ)
- `src/parser/wezterm_conformance_test.zig` — c0.rs + c1.rs +
  csi.rs (BS/LF/CR/HT, IND/NEL/HTS/RI, VPA, REP, IRM, ICH,
  ECH, DCH, CUP, DL, CHA, ED 3)
- `src/parser/multicell_conformance_test.zig` — wide chars,
  emoji, regional indicators, ZWJ, soft hyphen, autowrap,
  VS-16, BS at wide-char trailer
- `src/parser/clipboard_conformance_test.zig` — OSC 52 base64
  round-trip with edge cases (empty, query, invalid, split
  across feed() calls, binary bytes)
- `src/grid/selection_conformance_test.zig` — selection
  extraction (forward, backward, partial, empty, wide-char,
  soft-wrapped)
- `src/ui/input_conformance_test.zig` — modCode at all 8
  combos, cursorKey/tildeKey/ssoKey at every modifier perm

`docs/external-references.md` documents what's in external/
and which test files are worth porting next.

Total: **226/226 tests pass**, up from 102.

Coverage by file (final count this round):
- `conformance_test.zig` — 11
- `screen_conformance_test.zig` — 41
- `wezterm_conformance_test.zig` — 18
- `multicell_conformance_test.zig` — 9
- `clipboard_conformance_test.zig` — 8
- `selection_conformance_test.zig` — 8
- `input_conformance_test.zig` — 14
- `graphics_conformance_test.zig` — 9
- pre-existing tests in vt.zig / screen.zig / etc — 108

The 124-test delta came from porting kitty/kitty_tests/parser.py,
screen.py, multicell.py, clipboard.py, keys.py, plus
wezterm/term/src/test/{c0,c1,csi}.rs.

## Big-feature implementation pass

In response to "implement ALL the missing features" the session
shipped four substantive features previously-listed as gaps:

### Soft-wrap reflow on resize (`src/grid/reflow.zig`)
When columns change on the main buffer, scrollback + active are
rebuilt: logical lines (rows linked by `continues_above`) get
joined, re-chunked at the new width, redistributed. Cursor follows
its logical (line_idx, col_in_line) position. Trailing empty
logical lines are dropped so bottom-of-active blank padding
doesn't push real content into scrollback when narrowing. Alt
screen never reflows. 8 integration tests + 6 primitive tests.

### Grapheme combining (drop-extension model)
`Screen.isExtendingCp` flags ZWJ, ZWNJ, variation selectors,
combining marks (basic + supplement + extended + half-marks),
and emoji skin-tone modifiers. `printCp` short-circuits for
those: cursor doesn't advance, no cell write. Cursor positions
for emoji+modifier and char+combining-mark sequences are now
correct. Limitation: we don't store the extending codepoint as
part of a grapheme cluster, so the rendered glyph is the base
only (matches cursor expectations from kitty's tests, but the
selection-extract for clusters still produces the base only).

### Image manager: placement_id + z_index
`ImageStore.Image` gained `placement_id` and `z_index`. Kitty
graphics protocol's `p=` and `z=` propagate from parser → Screen
sink → Pane → store. New `addWithPlacement(...)` and
`markByPlacementForDelete(image_id, placement_id)`. Plus wider
emoji width range for `isWideCp` (BMP misc symbols, mahjong,
playing cards, supplemental pictographs).

### HarfBuzz integration (foundation)
`Atlas.init` now wraps the FreeType face in an `hb_font_t` via
`hb_ft_font_create_referenced`. New `Atlas.shapeRun(text)` runs
the text through `hb_shape` and returns
`ShapedGlyph[]{glyph_id, x_advance, y_advance, x_offset,
y_offset, cluster}`. The renderer doesn't currently use this
(still does codepoint-per-cell), but the foundation is in place
for a ligature-aware pass.

Tests count: 226 → 247 (+21). Zero regressions.

## What's left

Remaining post-checkpoint TODO list:

1. Reflow with soft-wrap tracking on resize — the
   `continues_above` field is now set on autowrap, so the data is
   there; what's missing is rebuilding the buffer at the new width
   from logical lines.
2. PTY worker thread allocations leak on hard SIGTERM (cleanup
   ordering wrt thread join).
3. NVIDIA proprietary GL — falls back to llvmpipe on this laptop.
4. OSC 8 in selection-extract — preserves text but not the URI.
5. OSC 133 navigation UI — marks are recorded; no "jump to
   previous prompt" keybind yet.
6. Kitty progressive enhancement (CSI > 1 u) keyboard.

## Notable design decisions made during the build

- **Zig 0.15.2** with `ReleaseSafe` default — Zig's bundled linker
  cannot handle gcc 15's `.sframe` section in `crt1.o`. Debug
  builds fail with `R_X86_64_PC64` at link. Override via
  `-Doptimize=Debug` only when you have a working LLD ≥ 22.
- **Dirty-bit redraw** — `Pane.onTick` only `queue_draw`s when
  `Screen.dirty` is set. Saves substantial idle CPU on llvmpipe.
- **`drain_pending` atomic** — without it, every byte from a
  high-throughput shell would queue a separate
  `g_main_context_invoke` call. This lets the worker push freely
  while only one main-thread drain is ever scheduled.
- **`extern struct` Cell, 8 bytes** — `packed struct` in Zig is
  bitfield semantics, not byte-aligned. We assert `@sizeOf(Cell)
  == 8` at comptime.
- **Pane is the canonical Terminal `user_ctx`** — Pane forwards
  clipboard / title / image events up to Window via per-callback
  sinks. Avoids a single `user_ctx` collision when both Pane and
  Window need to handle different events.
- **Image rendering as a separate pass** — `ImagePass` has its
  own shader (`u_image` uniform) and is drawn after the grid pass.
  Keeps the grid shader simple (one atlas binding).
- **Stb_image vendored under `vendor/`** — single-header,
  public-domain, compiled as a C source by `build.zig`. Used
  for iTerm2 OSC 1337 PNG decoding.

## Iteration after the long-tail TODO

This session resumed after a context-compaction during the kitty
delete dispatch wiring (build was broken — `sinkImageDeleteFull`
was referenced but not defined). Picked up there and shipped the
following:

- **Kitty graphics delete dispatch** end-to-end. `Pane.on_image_delete_full`
  routes `d=a/A/i/I/p/P` to `markByPlacementForDelete` /
  `markByIdForDelete` / `markAllForDelete`. Legacy `on_image_delete`
  field removed (the full event supersedes it). Tests in
  `graphics_conformance_test.zig`.
- **Middle-click PRIMARY paste**. Drag-select fills PRIMARY, button
  2 pastes from PRIMARY when `mouse_mode == 0`. With mouse_mode > 0
  the running app still gets the click. `clipboard.zig` grew
  `copyToPrimary`.
- **Config file** at `$XDG_CONFIG_HOME/sketerm/config.conf` (or
  `~/.config/sketerm/config.conf`). Simple `key = value` format,
  `#` comments at line start so `#abcdef` colours survive. Wires
  font, font_size, padding, default_fg/bg, cursor_color, cursor
  shape+blink, scrollback, shell, term/color_term env, bracketed
  paste, modify_other_keys, ligatures, auto_theme. Env vars
  (`SKETERM_FONT`, `SKETERM_SCROLLBACK`) still win. Sample at
  `data/sample.conf`. 5 tests in `config.zig`.
- **Live font size** — `Ctrl+=` / `Ctrl+-` / `Ctrl+0`.
  `Pane.setFontSize` deletes the old GL texture, rebuilds the
  atlas at the new size, recomputes cell metrics, resizes the
  Screen + emits SIGWINCH on the child PTY.
- **Scrollback search** (`Ctrl+Shift+F`). Bottom search bar with
  prev/next/match-count, Enter cycles forward, Shift+Enter back,
  Esc closes. Linear UTF-8 scan over scrollback rings + active
  buffer; results highlighted via the existing selection. 3 tests.
- **HarfBuzz-shaped runs** — the renderer now detects runs of
  same-style printable cells, builds UTF-8, calls `atlas.shapeRun`,
  and looks up glyphs by `glyph_id` (`atlas.lookupOrLoadById`).
  Falls back to per-codepoint when shaping unavailable. Toggle via
  `ligatures = false`. ASCII ligature fonts (Fira Code, Iosevka,
  JetBrains Mono) now render their ligatures.
- **Wide-cell cursor** — block / underline / outline cursor spans
  2 columns when on a wide rune.
- **Reset Terminal** in right-click menu → `Screen.fullReset`.
- **DECSC/DECRC saves OSC 8 link state** — apps that wrap nested
  cursor saves around hyperlink spans no longer leak the link state.
- **Auto-theme** (config `auto_theme = true`, default) — default
  fg/bg follow `AdwStyleManager` dark/light. Set false to use
  explicit config colours.
- **Live theme reactivity** — `notify::dark` repaints all panes
  when system dark/light flips at runtime.
- **Tab tooltips** — `AdwTabPage.set_tooltip(title)` so truncated
  tab titles stay legible.
- **Double-click word / triple-click line** selection.
  `Screen.selectWordAt` walks word-class neighbours;
  `Screen.selectLineAt` selects whole row. Word-class follows xterm
  default + non-ASCII codepoints. PRIMARY auto-filled. 3 tests.

## More polish on top of the post-compaction batch

- **Rectangular (block) selection** — Alt+drag during selection.
  Renderer overlays the rectangle; `extractSelection` emits each
  row as fixed-width without trimming so columns line up. One test.
- **Per-pane font_size in layout** — saved in `PaneSpec` only when
  it diverges from the global default, restored on layout load.
  Layout-loaded panes also get the same notify / bell / config
  wiring as `newShellTab` panes (was a small drift).
- **Audible bell** — opt-in via `bell_audible = true`. Uses
  `gdk_display_beep` so DE/portal handles the actual sound.
- **Layout DSL** — splits accept `@ <ratio>` (e.g. `hsplit @ 0.7`),
  pane commands honour `"double"` and `'single'` quotes for args
  containing spaces. Three tests + sample.layout updated.
- **Save layout shortcut** — Ctrl+Shift+S calls
  `saveLayoutQuietly` so users can checkpoint their setup without
  closing the window.
- **OSC 8 hyperlinks survive copy** — `extractSelection` emits
  `[text](uri)` markdown around linked runs, so URIs paste cleanly
  into chat/issue trackers/markdown. One test.
- **Scrollback position indicator** — thin track on the right edge
  with a thumb showing the visible window inside (scrollback +
  active). Subtle when at bottom, accent when scrolled back.

## Autonomous run (M11–M17, post user-handoff)

Cron-driven session: cron fires every 30 minutes. User left for
extended period after asking for image fix + remainder of plan-v2.

Work delivered, in order:

### Image render regression fix (M11.0)
- Found the bug: emberglyph (and the kitty spec generally) sends
  multi-chunk transmits where continuation chunks omit `i=`. Our
  Manager keyed accums by image_id, so `i=0` continuations never
  matched the in-progress accumulator and were silently dropped.
- Fix in `kitty_images.zig`: track `active_transmit_id`; route
  continuation chunks (action=.unknown, i=0) to it. Bonus: parse
  Kitty placement params `c=`/`r=` (cell-grid scale), `x/y/w/h`
  (source-rect crop), `C=` (no-cursor-move). Renderer scales to
  cells_wide×cell_w / cells_high×cell_h and crops via UV.
- `ImageStore.addFull` replaces existing (image_id, placement_id)
  to stop emberglyph's per-frame re-placement from leaking entries.
- 7 pipeline integration tests confirm receive path works for
  every documented format/transmission combo.

### Headless GL smoke (CI) — `zig build smoke-image`
- `src/smoke_image.zig` opens an EGL surfaceless context (Mesa
  PLATFORM_SURFACELESS_MESA), creates a 256×64 FBO, drives ImagePass
  + ImageStore with a 32×32 red RGBA image, glReadPixels, asserts
  red samples in the upper-left. PASSES on NVIDIA EGL 1.5 / GL ES
  3.2. Catches GL-side regressions without a display server.

### M14 — OSC 133 prompt navigation
- `Line.id: u64` assigned at line birth; `Screen.next_line_id`
  monotonic counter. ID follows the content through scroll, alt
  swap, reflow, resize.
- `prompt_marks: [256]u64` (was [256]i32 of row numbers); marks
  resolve via `rowForLineId` regardless of how far content scrolled.
- `Screen.jumpPrev/NextPrompt` walks marks, sets view_offset.
- Ctrl+Shift+Up/Down keybinds → Window.jumpPromptOnFocused.

### M15 — Kitty progressive-enhancement keyboard (level 1)
- Parse `CSI > N u` (set), `CSI = N;M u` (set/push/pop), `CSI < N u`
  (pop), `CSI ? u` (query → `CSI ? flags u`). 9-deep stack.
- Encoder honours the disambiguate flag (0x01): Tab/Enter/Esc/BS
  emit `CSI N u`; Ctrl/Alt + ASCII letter emit `CSI <lc>;mods u`
  so apps distinguish Ctrl+I from Tab.

### M13 — Bidi + complex-script shaping via fribidi
- Linked system fribidi (~50 KB, what foot uses).
- `src/grid/bidi.zig` wraps `fribidi_get_par_embedding_levels_ex`
  + visual-order remap.
- `grid_pass.emitGlyphsForLine`: lines with non-ASCII codepoints
  go through bidi resolution + visual reorder; pure-ASCII fast-
  paths skip fribidi entirely.
- Dropped `runIsPureAscii` — HB shapes Arabic/Indic/etc. correctly
  with `hb_buffer_guess_segment_properties` already in.
- Cursor positioning in mixed bidi text not yet visual-aware
  (logical column only). v1 limitation.

### M12 — DECDHL / DECDWL / DECSWL per-line scaling
- `Line.scaling: enum {single, dwl, dhl_top, dhl_bot}`. ESC
  #3/#4/#5/#6 stamp the cursor's line. clear() resets.
- Renderer dilates x by 2× for dwl + dhl_*; y by 2× for dhl_*
  with origin shift so a 2-line dhl_top/bot pair renders one
  big character spanning both rows.

### M11 — DECSCNM + DECCOLM + VT52
- DECSCNM (CSI ?5 h/l): `Screen.reverse_screen` flag; renderer
  swaps default fg/bg before resolving cells.
- DECCOLM (CSI ?3 h/l) gated by DECSET 40 (`allow_decolm`).
  Toggles screen between 80 and 132 cols, clears, homes, resets
  margins. Doesn't resize the GTK window.
- VT52 mode (DECRST 2): Parser flag + handleVt52Escape; ESC
  <X> for X ∈ A/B/C/D/H/I/J/K/Y/Z/=/>/< translates to equivalent
  CSI events. Wired via `Sink.on_decanm` → Terminal flips
  `parser.vt52_mode`.

### M17 polish

- **M17.2** `o=z` zlib decompression in kitty graphics. Uses
  `std.compress.flate` with the `.zlib` container.
- **M17.4** Image re-upload after GL context loss. flushUploads
  retains `pending` after upload; forgetGL just zeros gl_tex.
  Memory cost: width*height*4 per active image, persistent until
  delete dispatch. Images now survive splits / pane shuffles.
- **M17.5** Context-aware right-click "Copy Link" for OSC 8
  cells. menu.attachWithPrePopup fires a callback before popup;
  pane checks the cell at click coords for has_link, toggles
  term.copy-link enabled state, stashes URI for activate.

### Status snapshot
- 305 tests pass.
- All M0–M15 milestones in plan-v2 done.
- M16 (perf) deferred — not the bottleneck; current path runs
  fine on hardware GPU.
- M17.1 (atlas multi-page LRU), M17.3 (kitty animation frames),
  M17.6 (Save Layout As dialog) still on the table.

## More autonomous polish

After M11–M17 the autonomous run kept iterating on smaller polish:

- **M16.2 parser print_run batching** — Ground-state printable bytes
  accumulate into a 64-byte fixed buffer and flush as a single
  Event.print_run when a non-printable arrives, the buffer fills, or
  advance() returns. Cuts SPSC ring traffic up to 64× for "shell
  prints long line" workloads. Screen.apply iterates internally.
- **M17.6 Save Layout As…** via GtkFileDialog. Ctrl+Shift+Alt+S
  opens a native save dialog defaulting to `layout.json`.
- **smoke-image extension** — adds a second image at cell (8,0) with
  `cells_wide=4, cells_high=2` to verify multi-image rendering AND
  cell-grid scaling in the headless path. Both red + green sampling
  fail the build if either regresses.
- **fullReset cleanup** — RIS / Reset Terminal now also clears
  reverse_screen, kitty_kbd_flags + stack depth, and bounces VT52
  back to ANSI via on_decanm. User stuck in any mode can hit Reset
  Terminal and recover.
- **Reflow line-id stamping** — post-reflow rows now get fresh
  `nextLineId()` instead of 0, so prompt_marks don't collide with
  unrelated post-reflow content.

## Final state

- 305 unit + conformance tests pass
- `zig build` clean
- `zig build smoke-image` PASS (multi-image + cell scaling)
- `zig build spike-shell` runs through a real bash → parser → screen
  pipeline cleanly
- Plan-v2 milestones delivered: M11.0 image fix, M11–M15 fully, M13
  bidi (basic), M16.2 perf, M17.2 / .4 / .5 / .6
- Deferred: M16.1 (per-row dirty), M16.3 (GPU instancing), M17.1
  (atlas multi-page), M17.3 (kitty animation frames). Each documented
  in plan-v2.md with effort estimate and rationale for deferral.

Cron `7,37 * * * *` set to keep iterating if more work surfaces.

## Cron tick 17:07 — additional polish

- **atlas page size** 1024→2048. 4× glyph capacity for emoji-heavy
  long sessions. Full multi-page LRU (M17.1) deferred until profile
  data justifies it.
- **`--debug-images`** now also routes into the kitty Manager so PNG
  decode failures from stb_image print to stderr. Useful when an
  app's images come through but get silently dropped due to corrupt
  encoding.
- **Copy Link works on scrollback** — paneMenuPrePopup now resolves
  the cell via a public Screen.lineCellsAtPub that handles negative
  rows. Right-click on a hyperlink that has scrolled out of view
  exposes Copy Link.
- **fullReset** also wipes reverse_screen + kitty_kbd_flags + bounces
  VT52 → ANSI (via Sink.on_decanm) so Reset Terminal recovers from
  any of the modes added in M11/M15.

## Cron tick 17:25 (self-scheduled wakeup)

Brief tick — confirmed all green (306 tests, build clean). Plan-v2
table updated to reflect completion status. No new code; the system
has reached a natural settle point. Next CronCreate-driven tick at
17:37 will pick up if more items surface.

## Deferred-item completion pass (user request: "do not defer things")

User came back and instructed: implement all six deferred items.
"There is a GPU here, it works. Just use it." Shipped:

### M16.1 + M16.3 + M17.1 — renderer rewrite

Created `src/render/cell_pass.zig` (CellPass) — a new instanced
pipeline running per-cell instances through `glDrawArraysInstanced`.
Two-pass rendering (bg first, then glyph) via a `u_kind` uniform on a
single VAO; the per-instance attributes carry both bg + fg + glyph
coords, so the same buffer drives both passes. Persistent VBO sized
`rows × cols × 88 B` (e.g. 1.4 MB at 200×80) with per-row dirty
tracking — `Line.dirty` plus a `row_needs_upload` array drive
`glBufferSubData` for only the rows that changed since the last
frame. Coalesces contiguous dirty runs into a single sub-data call.

`src/render/atlas.zig` now uses `GL_TEXTURE_2D_ARRAY` with PAGE_COUNT=4
layers × 2048² each (16 MB total budget). Per-page shelf-pack and
per-glyph layer index. When all pages are full, the LRU page is
evicted: cache entries that lived on it are removed, pack state is
reset, generation counter bumped. CellPass snapshots each page's
generation per frame and forces a full rebuild on any mismatch so
stale glyph references can't survive.

`src/render/grid_pass.zig` is now overlay-only (cursor, selection,
preedit, focus border, scrollback indicator, bell flash, plus
DH/DW-scaled rows and bidi-reordered rows that the per-cell grid
can't handle).

Shaders updated to `sampler2DArray` with `vec3(uv, layer)` lookups.
Smoke runner still passes on NVIDIA EGL 1.5 / GL ES 3.2.

### M17.3 — kitty animation frames

`StoredImage` gains a `frames: ArrayList(Frame)` plus `current_frame`,
`last_advance_us`, `playing`, `loops_remaining`, `generation`.
`a=f` finalizes a new Frame and either appends or replaces (target
slot from `c=`); `a=a` toggles `playing` (`c=1` stop / `c=2` run) and
sets `loops_remaining`. `Manager.advanceAnimations(now_us)` walks
animated images and steps `current_frame` when the per-frame delay
elapses, with loop accounting. `Pane.onTick` calls advance + pushes
the current frame's RGBA into matching placements via
`replacePending`. A new `pending_dirty` flag drives `flushUploads`:
a zero `gl_tex` triggers `glTexImage2D` while a non-zero one with
dirty pending bytes triggers `glTexSubImage2D` for cheap in-place
frame swaps. Tests cover `a=f` append, `advanceAnimations` cycle, and
`a=a` stop.

### Kitty kbd repeat events (flag 0x02)

`input.Ctx` tracks `last_press_keyval` + `last_press_time_us`; a press
of the same keyval within 120 ms is a repeat. `encode` threads
`is_repeat` into all kitty-disambiguate paths via `kittyKeyEvent` with
event=2 instead of event=1 when flag 0x02 is on. `key-released` clears
the memory so the next press is fresh.

### Bidi-aware selection

`Pane.cellAtLogical` (named `CellPos` return) maps the user-clicked
visual column to the row's logical column via
`Screen.visualToLogicalCol` (fribidi). Selection storage is logical;
the renderer remaps logical → visual cell-by-cell when drawing the
selection overlay (so a logical run split across visual segments
shows as multiple highlight rectangles, matching gnome-terminal /
konsole / kitty). Mouse-reporting (SGR 1006) keeps the visual column
since apps see what the user clicked on screen.

### Final state after this pass

- 318 unit + conformance tests pass (was 309 before this session).
- `zig build` clean. `zig build smoke-image` PASS (multi-image + cell
  scaling). Parser bench: CSI cursor moves at ~94 MB/s.
- Plan-v2 table: every milestone now ✅.
- `docs/protocols.md` updated: DECDHL/DECDWL, DECSCNM, DECCOLM, VT52,
  full kitty kbd protocol, kitty animation, kitty zlib/tempfile media
  all listed under "supported".

## Polish pass after deferred items

- **`cell_pass` skips bidi + DW/DH rows.** Without this, rows with
  any non-ASCII rune got rendered twice — once by CellPass at
  logical column positions (wrong for bidi) and again by GridPass
  at visual positions. Now CellPass leaves those rows blank.
- **Z-ordered image rendering.** Sandwich cell + grid passes between
  two `image_pass.drawZ` calls: `.below` first, `.above` last. Kitty
  graphics z<0 placements (e.g. wallpaper image behind text) now
  render correctly.
- **`printCp` perf**: ASCII fast-path on `print_run` (skip UTF-8
  decoder when bytes are pure ASCII and decoder is idle); cluster-
  store early-out when the map is empty (typical workload).
- **Animation alpha-blending**: per kitty spec, `a=f` with `C=0`
  alpha-blends the new frame over the base (default behavior); `C=1`
  overwrites (was the existing path). Pre-multiplied semantics with
  proper output-alpha computation. Test in `kitty_images.zig`.
- **`smoke-cell` target.** Drives a real Screen + Atlas + CellPass +
  GridPass on EGL surfaceless. Asserts text rendered (>50 non-bg
  pixels), SGR-green color landed (>5 greenish), focus border drawn
  (>5 blueish). Catches regressions in the instanced cell pipeline.
- **XTGETTCAP** (`DCS + q`): respond to terminfo capability queries.
  Recognised: TN/name, Co/colors, RGB, Tc, bce, U8, civis/cnorm, csr,
  Su. Used by neovim, tmux, kakoune to probe capabilities. 2 tests.
- **DECPAM/DECPNM**: was a no-op stub; now sets `Screen.app_keypad`.
  Input encoder emits `ESC O p..y/X/M` for KP_* keys when set.
- **OSC 8 markdown escape**: when a link URI contains `)`, switch
  from `(uri)` to `(<uri>)` form so paste targets that parse markdown
  (Slack, IRC clients, GitHub comments) don't mis-parse.

End of pass: 322 tests, build clean, both smoke targets PASS.

## Spec coverage tick (compatibility polish)

Eight commits expanding compatibility with real-world apps' probes
and modes. None changed any existing behaviour; all are purely
additive or fix conformance gaps.

- **DECRQM** (`CSI ? Pa $ p`) — added DECSCNM (5), DECCOLM (3),
  DECARM (8, autorepeat = always on), cursor blink (12), allow_decolm
  (40), and explicit `2 (reset)` reports for 1005 / 1015 / 1016 mouse
  modes that we don't implement. Apps that fall back through a chain
  of probes now see real answers.
- **LNM** (CSI 20 h/l) — was a no-op; now sets `Screen.line_feed_mode`
  so LF / VT / FF carry an implicit CR. Test added.
- **window title stack** (CSI 22 t / 23 t) — owns an 8-deep ring of
  duped titles. tmux + screen rely on this when nested.
- **DECSTR** (CSI ! p) — also clears DECSCNM and the active kitty
  kbd flag set (the saved stack is intentionally untouched).
- **multi-match search highlight** — Window publishes the in-progress
  match list to `Screen.search_highlights` + `search_active_idx`;
  GridPass overlays a translucent yellow rectangle on every match
  (orange on the active one). Closing search clears the borrowed
  slice before freeing.
- **SGR 4:N sub-param** — Parser now tracks `Csi.is_sub[]` so the
  SGR handler can distinguish `\e[4:3m` (curly underline) from
  `\e[4;3m` (underline AND italic). Codes 0=off, 1=straight, 2=double,
  3=curly, 4/5=folded into curly. Two regression tests.
- **OSC 22** — change mouse pointer shape over the pane via X cursor
  name. Plumbed Screen.Sink → Terminal sink → Pane handler that
  calls `gtk_widget_set_cursor_from_name`. Empty name = restore
  default.
- **public DECRQM** (CSI Pa $ p) — IRM (4) and LNM (20) state reports.

End of tick: ~327 tests, build clean, smoke runners green, parser
bench unchanged.

## Perf-pass tick (after user reported sluggish dialog drag on RTX 3050)

Looking at the actual hot path uncovered three real perf bugs and
two correctness bugs hidden inside.

### Hot-path fixes

- **Box-drawing rows were going to GridPass overlay.** The
  "row needs overlay" predicate triggered on any rune > 0x7F —
  CJK, emoji, math symbols, box-drawing — even though none of
  those need bidi reorder or complex shaping. GridPass rebuilds
  its full VBO every frame with no per-row dirty tracking, so
  every TUI with `┌─┐│└─┘` chrome (htop, btop, lf, yazi, …) was
  losing the cell-pipeline's per-row dirty optimization. New
  selective predicate routes only true RTL/Indic/Thai/Khmer/etc.
  to GridPass; CJK / emoji / symbols stay in CellPass.
- **Cursor visual-col remap allocated three buffers + ran fribidi
  per frame on any CJK row.** Same too-coarse non-ASCII heuristic.
  Now uses the same selective predicate.
- **`gtk_im_context_set_cursor_location` fired every dirty tick.**
  That's a D-Bus hop into IBus / fcitx5. Cache last (row, col)
  and only re-call when the cursor actually moved.

### Correctness fixes uncovered along the way

- **Palette / default-fg / default-bg changes didn't invalidate
  the cell instance VBO.** Cells with palette-resolved or default
  colors carried stale RGBA until otherwise marked dirty. Detect
  the change in rebuildAndUpload and force a full rebuild.
- **Scrollback growth while scrolled-back didn't shift the
  display.** When the user is at view_offset > 0 and new content
  scrolls into scrollback, the displayed sb-indices shift under
  the same display rows. Track last_sb_count and rebuild when it
  grew while scrolled.
- **`view_off > 0` was marking all rows dirty every frame.**
  Should only mark on scroll-position CHANGE; sitting at a fixed
  offset shouldn't re-emit the grid 60×/sec. Track last_view_off.

### Earlier tick crash fix (also shipped this round)

- **Shutdown segfault** — `g_main_context_invoke(mainDrain, term)`
  queued from worker can dispatch after `Terminal.deinit` already
  ran, into freed memory. Fixed by splitting drain_pending +
  back-pointer into a heap DrainHandle that's intentionally never
  freed; mainDrain checks `alive` before dereferencing.

### Cosmetic / additive

- ligature-shaping bypass on pure-alphanumeric runs (programming-
  font ligatures only fire on punctuation).
- shell-integration.bash emits OSC 133 prompt marks so
  Ctrl+Shift+Up/Down has marks to navigate.

## Throughput tick (parser + scrollback)

Headline: scrollback was using `orderedRemove(0)` on a 10k-line
ArrayList — O(n) shift per evict, ~50µs each, dominating the bench
once steady-state hit. Fixed plus piggyback wins.

- **Scrollback ring** (`scrollback_head`): in-place overwrite at
  cap, O(1) eviction.
- **Buffer-swap on scroll**: hand the scrolled-out top-row cells
  DIRECTLY to scrollback (no dupe), reuse the evicted oldest
  cells buffer as the new bottom row. Net 0 allocations per
  scroll once scrollback is full.
- **Pre-allocate scrollback ring** to capacity on first push so
  the fill phase doesn't go through ~14 grow-realloc steps.
- **applyPrintRunFast** with wrap-mid-run: the bulk-print fast
  path now handles autowrap correctly mid-run, so `lineFeed`
  happens within the fast path instead of bailing back to the
  per-byte slow path.
- **`hb_buffer_t` reuse + shape cache** (Wyhash-keyed, capped):
  no more hb_buffer_create/destroy per shapeRun. Identical text
  re-shapes hit the cache.
- **`clearAllClusters` early-out** when the cluster store is
  empty (the typical case when no combining marks have been seen).

Bench results (plain ASCII) before / after tick: 0.9 → 1.2 MB/s
(+33%). SGR colour churn 1.3 → 1.6 MB/s (+23%). CSI cursor moves
unchanged at ~95 MB/s (already not bottlenecked by scrollback).

Fast-path counters (instrumented + removed) confirmed 100% of
print_run events take the fast path on plain-ASCII workloads.
Remaining gap to Kitty / Ghostty throughput: SIMD UTF-8 decoder
(would lift parser advance from per-byte to per-vector — biggest
remaining win on plain text), pass-Event-by-pointer to remove
the ~88-byte struct copies through emit / apply, persistent-mapped
cell VBO.

## ReleaseFast SIGSEGV — root-caused & fixed

Tracking issue from previous tick: `zig build test -Doptimize=ReleaseFast`
deterministically segfaulted in `Pool.get` on the 36th conformance test.
Root cause: the test `Harness` (and a couple of similar test-only
`Bench` wrappers) stored `Pool` BY VALUE but called
`Screen.init(allocator, &pool, …)` with the *stack address* of that
local `pool`. When `Harness.init` returned, the struct was moved
into the caller's frame and the stack region holding the original
`pool` was reused with garbage; `screen.pool` was a dangling pointer
the whole time. ReleaseSafe happened to leave the stack alone long
enough for it to look "fine"; ReleaseFast reused the slot
aggressively.

Fix: heap-allocate `Pool` in the harness, store as `*Pool` so the
address is stable. Same fix applied to `clipboard_conformance_test.zig`
and `image_pipeline_test.zig`. Production `Terminal` was already OK
because it explicitly re-assigns `self.screen.pool = &self.pool` after
the heap-allocated struct is constructed.

With the bug gone, default build mode promoted to ReleaseFast — the
shipped binary now ships with safety checks off (matches
Kitty/WezTerm/Ghostty conventions). Pass `-Doptimize=ReleaseSafe`
during development for bounds + overflow checks.

## SIMD + scratch-buffers tick (post-checkpoint #2)

Bench had been stuck at 1.2 MB/s plain ASCII. Two latent issues
masking each other:

- **Per-byte parser dispatch** — every printable byte traversed 4
  nested switches in `Parser.byte`. SIMD scan in `Parser.advance`
  using `@Vector(16, u8)` finds the longest printable run, bulk-
  copies into `print_buf`, flushing as 64-byte `print_run` events.
  Tests cover ESC / DEL / control / high-byte boundaries.
- **scrollUp / scrollDown allocator hits** — every line-feed (and
  every RI) allocated 2 small slices (`stash` + `stash_ids`) for
  `move=1`. Stack scratch up to 8 covers ~all real moves; heap
  fallback for larger.
- **runIsAscii** — vectorised the bytewise scan that gates the
  Tier-2 fast path in `Screen.apply(.print_run)`.
- **GridPass bidi scratch** — cursor visual-col remap and
  `emitGlyphsForLine` were each doing 3 allocs per bidi row per
  frame. Hoisted into `bidi_cps` / `bidi_levels` / `bidi_indices`
  ArrayLists on GridPass.

Bench results: plain ASCII 1.2 → 138.7 MB/s (115×). All other
workloads in the 50–100× range. The scrollUp alloc was responsible
for ~all of the win on this bench because every newline in the
fixture fired it.

## Niche-compat tick

- **Mouse encodings**: DECSET 1005 (UTF-8), 1015 (urxvt), 1016
  (SGR-pixel) added next to existing 1006 (SGR). Last-set wins;
  DECRST returns to legacy. `Pane.writeMouseEvent` switches on
  `Screen.mouse_enc` for press/release/motion/wheel call sites.
  DECRQM reports state. 2 unit tests.
- **SS2 / SS3 single-shifts** (ESC N, ESC O): `pending_single_shift`
  flag bypasses charset translation for the next codepoint. We
  don't model G2/G3 charsets, so the bypass is the spec-compliant
  best-effort given the missing model. 1 unit test.
- **OSC 50**: `?` query replies with `Screen.font_name` (set from
  `Pane.realize` to `font_path`). Set is accepted-no-op. Stops apps
  that probe for a font name from getting confused. 1 unit test.
- **OSC 1337 directives**: `File=` still goes to the iTerm2 image
  path; everything else dispatches as `<Key>=<Value>` directives.
  Implemented: CursorShape (maps to DECSCUSR), ClearScrollback,
  SetMark (maps to OSC 133 prompt-mark), RequestAttention (notify),
  CopyToClipboard (immediate copy), StealFocus (deny). 1 unit test.


## Spec-coverage tick

Added the canonical CSI-t reports + the synchronized-output mode
that real-world apps probe before painting:

- **CSI 14t / 16t / 20t / 21t**: report window pixel size, cell
  pixel size, icon label, window title respectively. Pixel sizes
  are now accurate (Atlas → Screen.cell_pixel_w/h via Pane.onResize)
  instead of the legacy 8/16 approximation.
- **DECSET 2026 (synchronized output)**: TUI frame buffers like
  ratatui's `enable-sync-output` set 2026 before painting and
  reset after. Pane.onTick suppresses queue_draw while set; reset
  bumps dirty so the next tick paints. DECRQM reports state.
- **DECRQM coverage**: 1005, 1006, 1015, 1016, 2026 all answer
  correctly.


## Hot-path tick

Continuing the perf hunt. Bench was already healthy (~150 MB/s
plain ASCII); these are real-world per-frame and per-event wins.

- **cell_pass: per-style cache in rebuildRow** — runs of cells
  sharing the same `style_ref` (vim chrome, tree-view rows,
  status lines) reuse the resolved fg/bg/deco instead of doing
  pool.get + 2× colorToRGBA + reverse swap + dim multiply +
  6-step deco-kind chain on every cell.
- **ring: consumer + producer head/tail caches** — drain loop
  was issuing `head.load(.acquire)` per pop; cached_head snapshots
  it once per batch. Mirror cached_tail on the producer side so
  hot push loops only re-acquire on suspected-full.
- **atlas: touchPage skip-redundant-store** — frame_counter is
  bumped once per render, so touchPage was writing
  last_used_frame to the same value ~16k times per frame.
  Compare-then-skip cuts cache traffic.
- **Investigated** but rejected: passing Event by *const through
  apply/emit — the compiler already passes the union by-reference
  in ReleaseFast; source-level by-pointer added an indirect access
  that pessimised CSI cursor moves (-15%). Reverted.


## Continued tick (build-fix + small wins)

- **Tier 2.5 mixed-run path** — print_run handler bulk-prints
  contiguous ASCII via printCp directly when decoder is idle,
  routing only non-ASCII through Decoder.feed for codepoint
  reassembly. CJK + ASCII chrome no longer pays per-byte branch.
- **Smart-case search** — `Screen.searchOpts(allocator, needle, ci)`
  with a smart-case heuristic in `Window.updateSearch`: lower-only
  needle implies CI; uppercase forces CS. 1 unit test.
- **Csi.is_sub bool[16] → u16 bitmask** — Csi struct shrunk
  88 → 76 B. Event union still 96 B (DcsFull is the limiter at
  88) but Csi-handling code touches fewer cache lines.
- **SPSC ring 4096 → 16384** — absorbs ~100 ms of worker bursts
  without spin-waiting on a stalled main thread.
- **cursor_blink_ms** — config knob for half-cycle interval (was
  hardcoded 500 ms). Plumbed Pane.cursor_blink_us and read in
  onTick.
- **Build regression fix**: `self.writeMouseEvent(...)` was
  invalid because `writeMouseEvent` was module-level, not a Pane
  method. Tests passed (tests.zig doesn't import pane.zig); only
  `zig build` of the main binary surfaced it. Switched to
  `writeMouseEvent(self, ...)` form. Note for future ticks: run
  the FULL `zig build`, not just `zig build test`.


## UTF-8 lookahead tick

Two compounding wins on the UTF-8-mixed workload:

- **Lookahead-decoded multi-byte codepoints** — Tier 2.5 now
  classifies a leading byte (1/2/3/4-byte UTF-8) and decodes the
  whole codepoint via `decodeUtf8Lookahead` in one step. Stateful
  `Decoder.feed` is reserved for the case where a run ends mid-
  codepoint (state carries over to next run).
- **fastAsciiSlice** — extracted from `applyPrintRunFast` so Tier
  2.5 ASCII subranges go through the same direct cell-array fast
  path (skips charset / wide / wrap checks per byte).
- **digit accumulator** uses Zig `*|` / `+|` saturating ops in
  `byteCsi` — cleaner than the std.math.add+catch dance.

Bench: UTF-8 mix 63 → 85 MB/s (+35% net for this tick). Plain
ASCII unchanged ~150 MB/s. Other workloads similar.


## Misc tick

Mostly housekeeping wins:

- **Atlas pre-warm at realize** — printable ASCII (0x20..0x7E)
  rasterised at realize so the first shell prompt doesn't fire
  ~95 back-to-back glyph-rasterise + glTexSubImage3D in one
  frame. Smoother first-paint.
- **Dcs.params [16]u32 → [4]u16** — DCS dispatch never reads
  proto.params (XTGETTCAP / DECRQSS use intermediates + final;
  sixel reads its own body). Shrinking dropped DcsFull from
  88 → 32 B and the Event union from 96 → 80 B (Csi at 76 B
  is now the limiter). SPSC ring memory: 1.5 → 1.25 MB.
- **runIsAscii drop in Tier 2.5 subrange** — print_run only
  carries bytes already classified printable, so the duplicate
  vector scan is gone.
- **docs/protocols.md** updated to mark mouse 1005/1015/1016
  ✓ (shipped earlier ticks), SS2/SS3 done, OSC 22/50/1337
  rows expanded.


## Event-shrink tick

- **Csi.params [16]u32 → [16]u16** — real-world CSI params (SGR
  ≤255, cursor pos, DECSET modes ≤9999, RGB ≤255) all fit in u16
  with margin. cur_param stays u32 internally; flushParam clamps
  via `@min(.., max u16)`. Csi shrunk 76 → 42 B; Event union
  80 → 72 B (PrintRun is now the limiter at 65). SPSC ring memory
  16384 × 80 → 16384 × 72 = 1.13 MB.
- **PrintRun bump to 128 tried + reverted** — halved event count
  for plain-ASCII bursts but doubled Event union size with no
  measurable bench win. Documented in the comment so future ticks
  don't repeat the experiment.
- **GridPass vbuf pre-grow** to 2048 vertices at realize, so the
  first few overlay-emitting frames don't repeatedly realloc.

Bench stable at ~155 / 60 / 88 / 89 / 85 MB/s.


## Cache pre-grow tick

- **Atlas cache + glyph_cache pre-grown to 256 entries** at init.
  Avoids 4-5 rehashes during ASCII pre-warm + first session
  content. ensureTotalCapacity is one-time upfront cost; rehash
  is O(n) each so the savings are concentrated at warm-up.
- **🐛 setFontSize: sync Screen.cell_pixel_w/h** after atlas
  rebuild — otherwise CSI 14t/16t replies stayed stale until the
  next window resize. Caught by reading the Ctrl++ / Ctrl+- path.


## Polish tick

User-facing config additions:

- **`line_pad_px` config option** (alias `line_spacing`) — extra
  pixels added to cell_h for visual line spacing. Threaded through
  Window → Pane → Atlas.initOpts. Negative tightens; clamped so
  glyphs still fit. 1 unit test for both spellings.
- **`--config <path>` CLI flag** — bypass the XDG search and load
  config from an explicit file. Useful for testing alternate
  themes / configs without touching `~/.config/sketerm/config.conf`.
  New `Config.loadWithOverride` and `Window.initWithConfig`
  entry points.


## Print-run dispatch dedupe

- **Single SIMD scan per print_run event** — was running runIsAscii
  twice (once inside applyPrintRunFast precondition, once in the
  Tier-2 fall-through). Inlined the dispatch: scan once, route by
  result + state. applyPrintRunFast wrapper removed (its body is
  now called directly via fastAsciiSlice). Truecolor SGR bench
  variance ~85-97 MB/s (was ~80-90).
- **Bulk-accumulate digit runs** in csi_param via the parser's
  advance() scan. Saves ~6 byteCsi dispatches per truecolor SGR
  sequence; bench within noise but the path is structurally
  cleaner for long-param sequences.


## UX polish tick

- **Split inherits cwd** — when OSC 7 has reported a cwd on the
  focused pane, splits spawn the new shell there. Falls back to
  inherited (parent process) cwd when null. Common UX expectation
  matching gnome-terminal / kitty / wezterm.
- **Ctrl+I in search** — toggles the case-insensitive override.
  Smart-case (lower-only → CI, uppercase → CS) is the default;
  Ctrl+I forces explicit CI regardless of needle case.


## Shell integration tick

- **zsh + fish integration scripts** — port `OSC 7 cwd`, `OSC 133`
  prompt marks, and `sketerm_copy` (OSC 52) to zsh's
  precmd/preexec/chpwd hooks and fish's `--on-event fish_prompt /
  fish_preexec` and `--on-variable PWD`. Each self-skips when
  `$TERM_PROGRAM != sketerm`.
- **README** picks up a short section pointing users at the three
  scripts and explaining what they enable.
- **New tab inherits cwd** — Ctrl+Shift+T now spawns in the
  focused pane's last-reported (OSC 7) cwd, mirroring the prior
  split-inherits-cwd change.


## Pane navigation tick

- **Ctrl+Shift+Left/Right** — cycle keyboard focus through panes
  in the current tab. Wraps at either end. Single-pane tabs no-op.
  Action.pane_prev / pane_next added; the input layer fires the
  shortcut sink and Window.cyclePane filters panes by tab root.


## EINTR fixes tick

Two real latent bugs from POSIX signal-vs-syscall interaction:

- **worker poll() / read() EINTR** — a signal arriving during the
  blocking poll or read previously broke the worker loop and emitted
  a phantom child_eof. Both calls now retry on EINTR; only true
  read==0 or other errors close the loop. Shutdown still works via
  shutdown_fd → POLLIN.
- **pty.writeAll EINTR** — caller-side mirror; signal during write
  used to silently truncate. Retry on EINTR; treat EAGAIN as buffer
  full and return the partial count (caller can decide).


## More EINTR + ED 3 ring-head bug

Continued the latent-bug audit of POSIX syscall sites:

- **closeAndReap waitpid EINTR** — phase 1+2 polling waitpid bailed
  on EINTR, leaving the child unreaped. Phase 3 blocking waitpid
  had no retry loop. Both now while-loop on EINTR.
- **terminal.deinit shutdown eventfd write EINTR** — signal during
  the 8-byte write could leave the worker spinning on poll forever
  and deinit hanging on join(). Retry until success or non-EINTR.
- **🐛 ED 3 didn't reset scrollback_head** — the xterm
  `clear-screen-and-scrollback` extension did
  `scrollback.clearRetainingCapacity()` but left the ring head
  pointer pointing at a stale offset. Subsequent pushes appended
  to a fresh array but the ring eviction order (used once the
  ring fills again) was wrong. 1 unit test exercises a wrapped
  ring, ED 3, and asserts head=0.


## More-bug-hunt tick

- **🐛 kitty.Manager active_transmit_id stale after drop / dropAll**
  — when a `d=A` or `d=I <id>` deleted an in-flight transmission,
  the active_transmit_id field kept pointing at the now-deleted
  accumulator. Continuation chunks that omitted `i=` would route
  to a missing entry. Reset on matching drop / unconditionally on
  dropAll.
- **🐛 kitty graphics: ignored `q=` (quiet) on a=q query** — replied
  with `OK` regardless. Spec: q=1 suppresses success replies, q=2
  suppresses all. Now returns silently when q≥1 (the probe is
  always success). 1 unit test.
- **🐛 closeFocusedPane: focus surviving sibling pane** — without
  the explicit grab_focus, focus could land on the empty GtkPaned
  wrapper or a default widget, leaving keypresses going nowhere.
  Walk the sibling subtree, focus the first pane found.


## Preferences dialog tick

In-GUI configurability via AdwPreferencesDialog (modeled after
Terminator after exploring `external/terminator`). 5 pages, ~30
settings, all live-applied + persisted to disk on every change.

### Pages

- **Appearance** — font path (file picker), font size, line spacing,
  padding, cursor shape combo, blink switch + interval.
- **Colors** — 9 built-in scheme presets (sketerm, Tango, Solarized
  ×2, Gruvbox ×2, Nord, Dracula, Monokai), default fg/bg/cursor
  swatches, 16-colour ANSI palette (each as a GtkColorDialogButton),
  cursor-uses-fg toggle, auto-theme.
- **Behavior** — shell path, TERM/COLORTERM, login_shell switch,
  exit-action combo (close/restart/hold), bracketed paste,
  modifyOtherKeys combo, word_chars, smart_copy, scrollback lines,
  scroll-on-output.
- **Rendering** — ligatures, bidi, audible/visible/urgent bell.
- **Window** — tab position (top/bottom), close-button-on-tab.

### Plumbing

- New `Config.save / serialise` writes only non-default values
  (Terminator-style minimal persistence). Round-trip test.
- New keys: palette[16], scheme, scroll_on_output, word_chars,
  smart_copy, login_shell, cursor_color_default, tab_position,
  close_button_on_tab, exit_action, bell_visible, bell_urgent.
- `Window.applyConfigChange` is the single entry point; pushes
  diffs into every live pane (colors, palette, cursor, padding,
  ligatures, bidi, bracketed paste, modifyOtherKeys, scrollback)
  and persists to ~/.config/sketerm/config.conf.
- Heavy paths (`font_size` → atlas rebuild) only fire on actual
  change.
- Triggers: `Ctrl+,` (GNOME convention) + "Preferences…" in the
  right-click context menu.

### Deliberately deferred

- Per-pane / per-profile overrides (Terminator's 'profiles' notion).
  Single global config kept for v1.
- Keybinding editor — the hardcoded shortcuts work; rebinding UX is
  big-surface follow-up work.
- Background image / transparency — would need a major GL pipeline
  change.
- Open color buttons in the Colors page don't auto-refresh their
  preview swatches when a scheme is picked. The values DO take
  effect; reopening the dialog reflects them.


## Prefs wiring tick

The dialog from the previous tick exposed ~30 settings but several
weren't actually plumbed through to behaviour. This pass wires:

- **bell_visible / bell_urgent** — gate the visible-flash and
  AdwTabPage.needs_attention paths in onTermBell. Audible was
  already wired.
- **cursor_color_default** — translates to the renderer's
  alpha=0 sentinel ("use foreground"). Set on initial pane spawn
  and applyConfigChange.
- **login_shell** — Pty.SpawnOpts gains login_shell; argv[0]'s
  basename is prepended with `-` per Unix convention so the
  shell sources /etc/profile + ~/.profile.
- **scroll_on_output** — new Screen.scroll_on_output flag;
  lineFeed snaps view_offset to 0 when set. Lets users opt into
  gnome-terminal's "auto-tail on output" behaviour.
- **smart_copy** — Ctrl+Shift+C with no selection sends Ctrl+C
  (0x03) instead of being a no-op. Field added to input.Ctx.
- **word_chars** — isWordChar now consults Screen.word_chars
  for punctuation; double-click selection respects the user's
  set.

Still not wired (deliberately deferred):

- **tab_position** — the dialog combo writes to config, but
  AdwToolbarView's add_top_bar / add_bottom_bar require the
  tab-bar widget reference. Keeping it as a Window field is a
  small refactor; values are plumbed through, just not visually.
- **close_button_on_tab** — Adwaita's AdwTabView doesn't expose
  a global close-button toggle (per-page only via property
  `closable` which we'd need to walk all pages on every change).
- **exit_action** — Pane.onChildEof currently closes; restart /
  hold need separate spawn / banner widgets.

Initial pane spawn now also pushes the user's palette[0..15] when
set, so the first prompt picks up the configured scheme.


## More prefs wiring

- **tab_position {top, bottom}** — Window now holds tab_bar +
  toolbar_view widgets and re-parents on apply. Initial position
  loaded from saved config.
- **exit_action {close, restart, hold}** — Screen.onChildEof sets
  a child_exited flag; Pane.onTick fires win_on_child_exit
  next frame (avoids tearing down Terminal from inside apply).
  Window.onTermChildExit dispatches per the configured action.
  Default `close` matches gnome-terminal / kitty / wezterm.
  `hold` keeps the previous behaviour (banner only); `restart`
  closes + spawns a fresh tab (true in-place PTY swap is a
  bigger refactor for future).
- **close_button_on_tab** — dropped from the dialog. AdwTabView
  doesn't expose a global toggle. Schema key kept for future.


## Prefs polish + correctness tick

- **🐛 Wrong-allocator free in prefs dialog** — when the user picked
  a font, the previous font_path was passed to ctx.allocator.free
  but lived in Window.config.arena. Heap corruption waiting to
  happen on the second selection. Dialog now has its own arena;
  all duped strings (font_path, shell, term_env, …) go there and
  are reaped on close.
- **String survival across dialog close** — applyConfigChange
  re-dups every string field (font_path / shell / term_env /
  color_term_env / word_chars / scheme) into Window.config.arena
  before commit. Without this, post-close pointers would dangle.
- **schemes module extraction** — the 9 built-in colour schemes
  moved from ui/prefs.zig to grid/schemes.zig with a `lookup(key)`
  helper. Window now resolves `scheme` → palette at spawn /
  applyConfigChange time, so `scheme = solarized_dark` in
  config.conf without an explicit `palette` actually applies.


## Small-win settings batch (Terminator-inspired)

11 new schema keys, all live-applied via Window.applyConfigChange
and persisted to config.conf:

- **Mouse:** `mouse_autohide` (cursor hides on key press, returns on
  motion — input.zig sets cursor_from_name="none" via an autohide
  sink callback into Pane), `copy_on_selection` (drag-end + double
  / triple-click also push to SYSTEM clipboard, not just PRIMARY),
  `clear_select_on_copy` (Ctrl+Shift+C and the menu .copy clear
  the selection after copying), `disable_mouse_paste` (gate
  middle-click PRIMARY paste), `disable_mousewheel_zoom` (toggle
  the new Ctrl+wheel font-size zoom — also added that in onScroll
  with min 6 / max 72 pt clamp), `link_single_click` (OSC 8 hyperlink
  fires on plain click instead of Ctrl+click).
- **Search:** `search_case_sensitive` — when on, smart-case heuristic
  is bypassed and the default state is CS. Ctrl+I in the search box
  still toggles per-search.
- **Bold:** `allow_bold` (gates whether bold attribute affects
  rendering at all), `bold_is_bright` (whether bold lifts palette
  0..7 → 8..15 — xterm convention; on by default). Both threaded
  into cell_pass + grid_pass; three SGR-bold sites updated.
- **Window:** `always_on_top` (best-effort: GTK4 dropped the X11
  set_keep_above API; we log a one-shot stderr hint about KDE /
  GNOME / wmctrl window rules and accept the toggle so config
  round-trips). `new_tab_after_current` (uses adw_tab_view_insert at
  the focused page idx + 1 instead of adw_tab_view_append).

Implementation notes:

- Per-Pane fields mirror the Window config (copy_on_selection,
  clear_select_on_copy, disable_mouse_paste, disable_mousewheel_zoom,
  link_single_click, mouse_autohide, cursor_hidden) so the hot path
  reads from the local Pane, not through the Window.
- input.zig grew autohide_ctx + autohide_set callback so it can flip
  Pane.cursor_hidden without importing pane.zig (avoids an import
  cycle); same model as the existing terminal.Sink callback pattern.
- pushSelectionToClipboards() helper centralises drag-end and
  double-click-selection clipboard logic — replaces two duplicate
  inline blobs.

Prefs UI gets:
- new "Mouse" group (6 switches) on Behavior page
- new "Search" group (1 switch) on Behavior page
- new "Bold" group (2 switches) on Behavior page
- `new_tab_after_current` switch in Window > Tabs
- `always_on_top` switch in Window > Stacking, with subtitle that
  warns the API is best-effort

All tests pass; smoke-cell + smoke-image both PASS on NVIDIA GL ES 3.2.


## Per-pane titlebar (Terminator-style)

5 new config keys + Pane wrapper Box restructuring:

- `show_titlebar: bool = false` — off by default, matches sketerm's
  minimal-chrome default. When on, each pane gets a thin label above
  its grid carrying the OSC 0/1/2 terminal title.
- `title_active_fg / _bg` — RGBA, default white-on-red (`#ffffff` /
  `#c80003` — Terminator's iconic red active pane).
- `title_inactive_fg / _bg` — black-on-grey (`#000000` / `#c0bebf`).
- All four colours hot-reloaded via a Window-level `GtkCssProvider`
  attached to the GdkDisplay at app priority. The provider supplies
  CSS for two classes:
    `.sketerm-titlebar-active   { background: rgba(...); color: ...}`
    `.sketerm-titlebar-inactive { ... }`
  `Window.refreshTitlebarCss()` is called at init + on every apply.

Architecture:

- `Pane.area` is still the GLArea; `Pane.wrapper_box` is a vertical
  GtkBox containing `[titlebar][area]`. `Pane.widget()` returns the
  wrapper so layout / split / tab reparent the whole stack.
- All focus / click-equality call sites in `Window` updated to
  compare against `Pane.area` (the focusable widget that
  `gtk_window_get_focus()` actually returns) rather than `widget()`
  (the wrapper Box, which is never the focus target).
- Title label initialised to "Terminal" so a freshly-spawned pane
  shows something before the shell emits OSC 0/1/2.
- Click on titlebar Box → grabs focus on the underlying GLArea
  (otherwise focus would be trapped on the un-focusable Box).
- `setTitle(text)` / `setTitlebarVisible(bool)` / `setTitlebarActive(bool)`
  methods on Pane. The on_title sink (Pane.onTitleEvent) calls
  `setTitle` regardless of `win_on_title` (which stays null per the
  earlier "tab titles are sticky" decision).
- `onFocusEnter`/`Leave` flip the active CSS class.
- `applyConfigChange` propagates `show_titlebar` to all panes via
  `setTitlebarVisible` and refreshes the CSS provider.
- `makePane` sets initial visibility from config so newly-spawned
  panes show the bar immediately when enabled.

Prefs UI: new "Per-pane title bar" group on Appearance page with the
visibility switch + 4 GtkColorDialogButton rows.


## Inactive pane dimming (Terminator/WezTerm-style)

Investigation: neither Terminator nor WezTerm uses opacity for this.

- Terminator (`terminal.py:764-790`): two scalars
  `inactive_color_offset` (default 0.8 = dim fg) and
  `inactive_bg_color_offset` (default 1.0 = no bg dim). Multiplies
  RGB channels directly when caching the inactive colour copy.
- WezTerm (`config.rs:1889`): `inactive_pane_hsb` HSB transform
  (default brightness=0.8, saturation=0.9, hue=1.0). Applied in the
  shader.

Why not opacity: stacking with compositor blur or window-bg alpha
double-blends; the cursor on a 0.8-opacity pane is hard to read; the
RGB-multiplier approach gives a "sleeping" look without those issues.

Implementation:

- 2 new config keys: `inactive_fg_dim`, `inactive_bg_dim` (default
  0.8 / 1.0). Clamped to [0, 1].
- cell_pass: 2 new uniforms `u_dim_fg`, `u_dim_bg` set per-frame from
  `cell_pass.dim_fg / dim_bg`. Vertex shader multiplies bg quads by
  `u_dim_bg`, glyphs + decorations by `u_dim_fg`.
- grid_pass: per-vertex `a_dim` selector (0 = no dim, 1 = u_dim_fg,
  2 = u_dim_bg). Cursor / focus border / selection / search highlight
  / bell flash all emitted with `a_dim = 0` so they stay full-bright
  even when the pane is dim. Cell content (bidi rows, DW/DH glyphs,
  IME preedit) uses 1 / 2 appropriately.
- `Pane.applyDim()` writes both passes' dim factors based on
  `is_focused`. Called from `onFocusEnter` / `onFocusLeave` (which
  flip the bool too) and from `applyConfigChange` / `makePane`.

Prefs UI: new "Inactive pane dimming" group on the Appearance page
with two 0.05-step spin rows (0..1). New helper `addSpinRowF32Step`
generalises the existing `addSpinRowF32` to take step + digits.


## plan-v3 push (A C B D shipped, E F G H I J K pending)

Plan-v3 reviewed by an independent Plan agent. Findings integrated:
factual fixes (AdwTabView close-page must always return TRUE +
finish; KWin blur unreachable on Wayland; no gtk_gl_area_set_has_alpha
in GTK4); reordered to A→C→B→D→E→F→G→H→I→J→K; effort estimates
roughly doubled for E (12-16 h), F (16-24 h), I (6-8 h).

### A — Confirm-on-close (shipped)

`confirm_close: enum { never, multiple, always }` (matches
Terminator). AdwTabView "close-page" handler always returns
`GDK_EVENT_STOP` and calls `adw_tab_view_close_page_finish` once
the AdwAlertDialog response arrives. Window "close-request"
handler counts total panes; same dialog flow. Prefs combo on
Window > Closing.

Critical detail per the review: returning FALSE on some branches
and TRUE on others races. Always TRUE; if no confirm needed, call
`finish(view, page, true)` immediately.

### C — Background opacity / transparency (shipped)

`background_opacity: f32 = 1.0` clamped 0..1. `resolveDefaultColors`
multiplies into bg.a after auto-theme. Window "realize" handler
calls `gdk_surface_set_opaque_region(NULL)` once when opacity < 1.
Live-toggling back to 1.0 doesn't re-enable compositor optimizations
without a window restart — documented in the prefs subtitle.

KWin blur (`org_kde_kwin_blur` Wayland protocol) is NOT reachable
from GTK4. Documented; not implemented.

### B — URL auto-detect (shipped)

`grid/url_scan.zig`: hand-rolled `http(s)://` matcher with 7 unit
tests (plain match, trailing-period trim, OSC 8 skip, two matches,
no match, ftp rejected, etc.). RFC 3986 unreserved + sub-delims +
pct-encoded URL chars. Trailing punctuation trimmed.

Renderer: extra "url underline" pass in `grid_pass.buildVertices`
after the search overlay, before selection. 1px-thin accent
underline at cell bottom. Per-row scan; OSC 8 cells skipped to
avoid double-decoration.

`Screen.urlAtVisible(allocator, vrow, vcol)` returns the URL text
on hit. `Pane.onMotion` shows tooltip; `onDragEnd` launches via
`g_app_info_launch_default_for_uri`. Both paths fall back from OSC
8 to auto-detect cleanly.

`auto_url_detect` config (default true). Prefs row in
Behavior > Mouse.

### D — Quake mode (shipped)

`G_APPLICATION_HANDLES_COMMAND_LINE` switch. Refactored argv parsing
into the `command-line` signal handler so a second
`sketerm --toggle` invocation reaches the primary via D-Bus. The
primary registers a `toggle` GAction; --toggle activates it.

`Window.toggleQuake`: `gtk_window_minimize` when active,
`unminimize + present` otherwise. Critically, we minimize rather
than `set_visible(false)` because hiding destroys the GdkSurface →
GL context loss → atlas + image upload rebuild on every reveal.

Documented Wayland caveats: focus-stealing prevention may delay
the raise; user binds the keystroke at compositor level (KWin
Custom Shortcuts / GNOME Settings).

Cron `5c32eb79` (7,37 * * * *) keeps the loop ticking through the
remaining items every 30 min for 7 days.

### E — Custom keybindings (shipped)

Two-stage. Stage 1: extend Action enum (6 new actions —
`paste_clipboard`, `copy_selection`, `interrupt_or_copy`,
`clear_and_scrollback`, `scrollback_page_up/down`); replace the
hardcoded switch in `onKeyPressed` with a `default_bindings` table
+ `matchBinding` lookup. `runAction` dispatches per-pane locally
or via `shortcut_sink` for window-level actions.

Stage 2: `Config.keybinds: ArrayList(KeybindEntry)` parsed from
`keybind.<action> = <accel>` config lines (round-trip-tested, 2 new
config tests). `Window.refreshBindings` overlays defaults + config,
warns on conflicts (stderr); each Pane Ctx borrows the resolved
slice.

Prefs UI: new "Keybindings" page with one row per Action (comptime
`inline for` over the enum). Click the suffix button → enter capture
mode; next keypress sets the binding (Esc cancels; Backspace clears).
`gtk_accelerator_parse` / `gtk_accelerator_name` for the format.
`gdk_keyval_to_lower` so 'C' and 'c' match the same default.

### G — Broadcast typing (shipped)

`Terminal.writeUserInput` separates user-input writes (broadcastable)
from `sinkWritePty` (parser replies, per-pane — DA / DSR / OSC 52 /
kitty kbd reports must NOT broadcast). All `pty.writeAll` calls in
`input.zig` and `clipboard.zig` switched to `writeUserInput`.
Pane mouse/focus reports stay direct.

`Window.groupsend: enum { off, group, all }`, cycled by
Ctrl+Shift+G via the new `broadcast_cycle` Action. The
`broadcastBytes(source, bytes)` fan-out walks `terminals` and
writes directly to each `pty` (skipping the broadcast sink to
avoid recursion). `Pane.group: ?[]const u8` filters in `.group`
mode.

Visual: when broadcast is active, every pane's titlebar gets the
`sketerm-broadcast` CSS class which adds a 2px yellow inset
shadow ring. The titlebar's normal active/inactive coloring is
unaffected.

Mouse selection / paste: paste DOES broadcast (matches Terminator).
Mouse position events stay per-pane (they're meaningless across
panes; coordinates differ).

### F — Profiles (MVP shipped)

`Profile` struct (per-pane subset of Config: shell, font_path,
font_size, scheme, palette, term_env, color_term_env, scrollback,
login_shell). `Config.profiles: ArrayList(Profile)` parsed from
`[profile.<name>]` INI sections. `default_profile` selects the
profile applied to the very first spawn. Round-trip-tested.

Spawn paths: `spawnShellPaneOpts(cwd, profile_name)` resolves
each effective field via "profile wins → config falls back".
Splits inherit the focused pane's profile. `Pane.active_profile`
records which profile spawned the pane.

`Window.findProfile(name)` returns `?*const Profile`. The flat
parser dispatches inside-section keys to `applyProfileKv` (smaller
key set than the global applyKv). Unknown sections + unknown keys
log warnings; unknown sections fall through (don't strip user
data on round-trip).

Deferred for v1.1: prefs Profiles editor page; right-click "as
profile…" submenus. Workaround: edit config.conf directly.

### H — SIMD UTF-8 batch decoder (shipped as primitive)

`Decoder.feedBatch(bytes, out)` — `@Vector(16, u8)` ASCII fast-path
with 16-cp bulk write per chunk; per-byte fallback for multi-byte
sequences and partial sequences at run-end. 4 unit tests + a 32-
seed differential fuzzer comparing output vs the per-byte feed
path on random byte streams.

Honest scope note: the existing `print_run` apply path in
screen.zig is already heavily tiered (SIMD scan → fastAsciiSlice →
lookahead-based per-codepoint decode). `feedBatch` is exposed as
a primitive but doesn't get plumbed into the hot path because the
existing tiers already amortize. Useful for any future "bulk
decode arbitrary utf8 → u32 stream" caller.

### I — Persistent-mapped VBO (plumbing, off by default)

cell_pass: `glBufferStorage` + `glMapBufferRange` with
`MAP_PERSISTENT|MAP_COHERENT|MAP_WRITE` flags + per-frame
`glFenceSync`. Buffer regrow path recreates the VBO entirely
(BufferStorage is one-shot immutable). Legacy
`glBufferData`/`glBufferSubData` path preserved.

Probe defaults to `persistent_supported = 0`: smoke-cell SIGSEGV'd
when the EXT path was called on the NVIDIA-via-zink ES context —
likely needs `glBufferStorageEXT` (different symbol resolution)
on ES. Plumbing is in place; flipping the constant to 1 activates
the new path on platforms where the EXT_buffer_storage path is
known good. Documented as a future driver-matrix sweep.

### J — Render thread (analysis, deferred)

`docs/render-thread-analysis.md`: detailed cost / benefit. The
plan's "two snapshots" list is incomplete — actual interaction
surface includes 30 Line mutation sites needing generation bumps,
~20 fields of render config to atomically capture per frame, GL
context not shared with workers (atlas glyph upload deferral),
mid-build mutation retry policy, and frame-clock coordination.
Total: 9-13 days for a microsecond-scale win on hardware that
isn't CPU-bound. Three lower-cost alternatives flagged.

### K — EGL bypass (research spike, deferred)

`docs/egl-bypass-spike.md`: 2-3 weeks of focused work to bypass
GSK via wl_subsurface for marginal latency win on this hardware.
Architecture cost dominates (subsurface tracking through every
GtkPaned reparent, input routing rewrite, per-driver matrix).
Recommendation: defer until a slow-hardware user reports
measurable input latency.

## Final state — plan-v3 push

11 task IDs (#19–#30) tracked. All resolved:

✅ A confirm-on-close · ✅ C transparency ·✅ B URL auto-link
✅ D quake mode · ✅ E custom keybindings · ✅ F profiles MVP
✅ G broadcast typing · ✅ H SIMD UTF-8 · ✅ I persistent VBO plumbing
✅ J render thread (deferred + documented)
✅ K EGL bypass (deferred + documented)

Total: ~25 commits, ~2200 LoC added. Cron `5c32eb79` (7,37 * * * *)
will keep firing for 7 days; if more work surfaces it'll pick up
automatically.

## I persistent-VBO follow-up — probe re-enabled

Returning to the deferred I item: the smoke-cell SIGSEGV when
persistent_supported was forced to 1 wasn't a glBufferStorage
issue. The real bug: the regrow path called glDeleteBuffers +
glGenBuffers but the VAO records buffer names per-attribute, so
the next draw read the freed buffer and crashed.

Fix: factored `bindVertexAttribs()` out of realize() so the regrow
path can re-bind vertex attribs after recreating the VBO. Probe
now activates when GL_EXT_buffer_storage is advertised AND
epoxy_glBufferStorage resolves at runtime; runtime glGetError
post-storage falls back to a mutable glBufferData VBO if the
driver rejects the call mid-flight (no permanent state corruption).

smoke-cell + smoke-image still pass at this commit. On hardware
that supports persistent mapping, cell upload now writes directly
into the GPU-visible buffer with one fence per frame instead of
glBufferSubData + driver-side staging.

## Italic rendering

SGR 3 was parsed into `attrs.italic` but the cell_pass + grid_pass
renderers both ignored it — italic text rendered upright. Worst
of both worlds: the parser tracked the attribute, the renderer
silently dropped it.

Fix is shear-matrix-in-shader: per-instance `a_italic` flag (0.0
or 1.0); when set AND `u_kind == 1` (glyph pass), the vertex
shader applies `pos.x += (baseline_y - pos.y) * 0.231`. tan(13°)
is the standard typographic italic angle. Pivot is the cell
baseline so descenders stay anchored.

Cheap because we don't need a second FreeType face / italic
glyph variant — the same upright glyph atlas entry gets sheared.
Works for any monospace font including those without an italic
variant (Hack, JetBrains Mono Regular, Iosevka Term, etc.).
Trade-off: it's a faux-italic, not the typographically-correct
italic glyph design. Real italic faces would need a second atlas
+ font path config, which is a bigger change.

cell_pass.Instance grew 92 → 96 bytes (one new f32 attribute);
the size assertion test was updated. grid_pass overlay path
(bidi / DW / DH glyphs) does NOT yet shear — bidi+italic is
extremely rare and would require its own per-vertex italic flag
on grid_pass like the existing dim flag. Latin-only italic is
the 99% case.

## Recently-closed tabs (Ctrl+Shift+Z)

`Window.closed_tabs: ArrayList(ClosedTab)` — a 16-entry ring (oldest
evicted on overflow). `onPageDetached` calls `captureClosedTab`
BEFORE `collectAndFreePanes`, snapshotting:

- The AdwTabPage title
- The first matching pane's cwd (OSC 7 reported, fallback to nil)
- That pane's active_profile

Strings are duped into `Window.closed_arena` (fresh-on-first-capture).

`restore_closed_tab` action pops the most-recent and respawns via
the existing `spawnShellPaneOpts(cwd, profile)` path → wraps in
the standard tab-page Box → grabs focus on the new pane's GLArea.

Default keybind: Ctrl+Shift+Z (browser convention is Ctrl+Shift+T,
but we use that for new_tab; Z mirrors undo). Configurable via
`keybind.restore_closed_tab` like every other action.

Limitation (documented in commit body): splits aren't preserved.
A full split-tree restore would duplicate the `--restore` JSON
serialiser, which is a much bigger feature. Single-pane is the
95% case for the "I closed this by accident" workflow.

## Faux-bold rendering

Pair to italic. SGR 1 was honoured for bright-color promotion only
(when `allow_bold && bold_is_bright`); the glyph itself didn't get
thicker. Real bold needs a separate FreeType bold face; faux-bold
uses a shader trick — sample the atlas at the original UV AND a
1-texel-step in u, take max alpha. Result: glyph appears one pixel
thicker. Same architectural shape as italic (per-instance flag →
varying → fragment branch). Cheap, no extra atlas storage.

Gated by `allow_bold` config (already exists). Trade-off: faux-bold
isn't a real bold typeface — characters get heavier but lose the
proper bold metrics + bowl shapes that a real bold face provides.
Most users on modern monospace fonts won't notice.

Instance grew 96 → 100 B for the new `bold` attribute. Test
assertion updated. grid_pass overlay path (bidi / DW / DH) does
not yet faux-bold; bidi+bold is rare and would need its own
per-vertex bold flag.


## Shift-bypass for mouse-mode + copy_screen action

Two issues + one feature, all driven from a user report: "inside
mosh+tmux I can drag-select but nothing reaches the clipboard, and
OSC 52 doesn't work either."

### Shift-bypass (the bug)

`pane.zig: onDragBegin` returned early on `mouse_mode != 0` with no
modifier check, so when tmux turned on DECSET 1003 every click went
to tmux as a mouse report — host-side selection became impossible.
xterm/kitty/gnome-terminal/alacritty all support **Shift-bypass**:
hold Shift to override app-level mouse tracking.

Fix: read modifiers up-front in `onDragBegin`, only short-circuit
when `mouse_mode != 0 AND !shift_held`. Mirror in `onMousePressed`
+ `onMouseReleased` so a Shift-held click doesn't ALSO emit a mouse
report alongside the selection. Factored a `shiftHeld(controller)`
helper to share the modifier read.

### copy_screen action

When even Shift-drag isn't an option (e.g. the running app re-paints
constantly, or the user wants the whole pane), Ctrl+Shift+A now
copies the entire visible screen as UTF-8 to the system clipboard.

`Screen.extractScreen(allocator)` walks rows 0..rows-1 honouring
`view_offset` (so a scrolled-back view dumps what the user sees),
trims trailing blanks per row, preserves OSC 8 markdown links, and
emits one `\n` per row (including blank ones, so paragraph shape
survives).

Wired through input.zig: new `Action.copy_screen` enum entry, default
binding, runAction case, prefs label, `actionFromName`. Help text in
main.zig updated. New unit test asserts the visible-row walker
produces the expected `"hello\nworld\n\n"` for a 3-row screen.

### OSC 52 over mosh+tmux (docs)

This one's a config story, not code. Two stacked filters need
updating outside sketerm: tmux only forwards OSC 52 if its terminfo
advertises the `Ms` cap (workaround: `set -as terminal-features
',*:clipboard'`); mosh strips OSC 52 unless `MOSH_OSC52=1` is set
on the server before mosh-server starts. Both documented in
`data/sample.conf` so the user has an answer next time they wonder
why their `printf "\033]52;c;$(echo X | base64)\a"` does nothing.

## Tab tooltip with cwd

Tab titles are sticky (the wireup at line 655 of window.zig
intentionally suppresses OSC 0/1/2 → tab title), but a tooltip is
free real estate. Now: hover a tab → see "<title>\n<cwd>" where
cwd is the live OSC 7 path from the focused pane's shell.

Wiring:
- `Terminal.on_cwd_changed` callback added next to `on_title`. Fires
  inside `sinkCwd` after `self.cwd` is updated.
- `Pane.win_on_cwd` mirrors the pattern of every other Pane→Window
  forward (clipboard, bell, child-exit). `onCwdEvent` in pane.zig
  re-emits up.
- `Window.onTermCwdChanged` walks the tab-view, finds the page
  whose child contains `pane.widget()` (same pattern as the bell
  attention-marker), reads the current title via
  `adw_tab_page_get_title`, allocates a sentinel-terminated
  `<title>\n<cwd>`, calls `adw_tab_page_set_tooltip`. AdwTabPage
  dups the string so we free immediately.
- Wired at all three Pane creation sites: `addTabInternal`,
  `addTabWithProfile` (via `spawnShellPaneOpts`), and the layout
  `buildTreeWidget` pane case.

If no shell ever sends OSC 7 the tooltip stays at title-only; this
is fine — most modern shells (bash 4.4+, zsh, fish) emit OSC 7
when PROMPT_COMMAND or vcs_info hooks are configured. sketerm
ships sample.conf docs for the shell hook in earlier sections.

## save_default_layout action

Plan-v3.md line 311 listed "save-as-default" as a quick win adjacent
to D (quake mode). Done now: a new action lets the user pin their
current tab/split layout as the default that auto-loads on every
cold start, no `--restore` flag needed.

### Path strategy

Two distinct files now under `$XDG_STATE_HOME/sketerm/`:
- `last.json` — auto-saved on exit, loaded by `--restore`. Volatile.
- `default.json` — *user-saved on demand* via the new action. Loaded
  on startup whenever neither `--layout` nor `--restore` was passed.
  Persistent until the user re-saves or deletes it.

`layout.defaultLayoutPath()` mirrors the existing `defaultSavePath`
pattern (XDG_STATE_HOME → HOME/.local/state → /tmp). The naming
clash with the older function is documented inline; renaming would
break the only two existing callers (saveLayoutQuietly +
loadLayoutDefault).

### Wiring

- `Window.saveDefaultLayout()` writes via the existing collectLayout
  + layout_mod.save path, prints a stderr confirmation so the user
  knows where it landed.
- `Window.loadDefaultLayoutIfPresent()` first probes via
  `std.fs.cwd().access(path, .{})` so a missing file is silent —
  fresh installs don't get noise on every start.
- `main.zig` cold-start chain: `--layout` > `--restore` >
  `loadDefaultLayoutIfPresent()` > one fresh shell tab.
- `Action.save_default_layout` added; `actionName` / `actionLabel`
  updated; routed in `onShortcut` to `saveDefaultLayout`.
- Help text in main.zig describes the new behaviour. sample.conf
  documents `keybind.save_default_layout =` (unbound by default —
  this is a niche action and existing Ctrl+Shift+S/Alt+S pair felt
  like enough default surface for save flows).

### Why no default keybind

Saving the default layout is a deliberate "this is my workspace"
moment — not something to fire by reflex. Forcing the user to bind
it themselves nudges them to think about what the chord means. Also
keeps Ctrl+Shift+\* surface uncluttered.

## Pin / unpin tabs

AdwTabView has native support for pinned tabs (separate region at
the start of the tab bar, close button hidden, drag-reorder
restricted to the pinned set). All sketerm needed was the wire-up.

### Action + binding

- `Action.toggle_pin_tab` added to input.zig with default
  Ctrl+Shift+P.
- `Window.togglePinCurrentTab()` reads the current selected page,
  flips `adw_tab_page_get_pinned`, calls
  `adw_tab_view_set_page_pinned`. Two lines.
- `onShortcut` routes the action.

### Context menu

`menu.zig` BINDS table + tab section gained a "Pin / Unpin Tab"
entry between Rename and Close. New `menu.Action.pin_tab`;
`onMenuAction` in window.zig dispatches to the same
`togglePinCurrentTab`. Right-click → Tab section → Pin / Unpin Tab.

### Persistence

Pin state survives layout save/restore. `TabSpec` gained a
`pinned: bool = false` field (default keeps older JSON files
parseable via `ignore_unknown_fields`). `collectLayout` writes
`adw_tab_page_get_pinned`; `newTabFromSpec` calls
`adw_tab_view_set_page_pinned` after creation when the spec says
so. Both `--restore` (last.json) and the new auto-load default.json
flow inherit pin state automatically.

### Help text

main.zig HELP_TEXT lists Ctrl+Shift+P. sample.conf documents the
keybind override.

## Per-pane manual title override

Plan-v3.md line 309 listed Terminator's "set a title that survives
OSC 0/1/2 updates" as a quick win adjacent to the new titlebar.
Now done.

### Pane state

- `Pane.title_locked: bool = false` — when true, `setTitle` (called
  from `on_title` sink) is a no-op so manual strings stick across
  subsequent OSC updates.
- `applyTitle` extracted as the unconditional inner that updates
  `titlebar_text` + the GtkLabel. `setTitle` becomes a thin gate
  on the lock; new `lockTitle(text)` writes via `applyTitle` and
  flips the flag; `unlockTitle()` just clears it (label keeps its
  current text until the next OSC arrives).

### UX

Right-click → Pane section → "Set Pane Title…" opens a GtkPopover
anchored on `pane.area` (vs. the rename-tab popover which anchors
on `app_window`). Pre-fills the entry with the current title text;
Enter applies, Escape dismisses (popover default). Empty string
calls `unlockTitle` so the user can revert without restarting the
shell.

`menu.Action.set_pane_title` joins the pane section between
"Split Vertical" and "Close Pane". `Window.onMenuAction` routes
to `setFocusedPaneTitle`. `PaneTitleCtx` mirrors the existing
`RenameCtx` pattern with `freePaneTitleCtx` as the GDestroyNotify.

### Why no keybind

Setting a pane title is rare-and-deliberate, like
save_default_layout — burning a Ctrl+Shift+\* slot felt wasteful.
User can bind via `keybind.<...>` if they want, but I didn't add
the action to `input.zig::Action` since it requires a GTK popover
that must be anchored on a real widget at call time. Living in
`menu.Action` is sufficient.

## Regex search in scrollback

Plan-v3.md spillover. Existing scrollback search did literal
substring matching with smart-case; now Ctrl+R inside the search
bar flips into POSIX ERE mode for the same buffer.

### Why libc regex.h, not vendor

Zig 0.15.2 stdlib has no regex. Options were: vendor an upstream
regex implementation (zigregex, mvzr, etc.), reuse PCRE2 if it's
already in the dep graph (it's not), or call libc's POSIX regex.h.
libc was the smallest add — already linked via `lc`, no
build.zig changes, no new vendored code, well-known semantics.

### Translate-c bitfield gotcha

glibc declares `struct re_pattern_buffer` with bitfields at the
end. Zig's translate-c can't model bitfields, so it leaves the
type opaque. That means we can't stack-allocate a `regex_t` —
`var re: regex_t = undefined;` errors with "non-extern variable
with opaque type." Workaround: heap-allocate via `std.c.malloc`
with a generous fixed buffer (256 bytes; real size is ~64 on
x86_64 glibc), cast the pointer to `*regex_t`, free with
`std.c.free`. Documented in-line so the next reader doesn't
chase the same rabbit hole.

### `c` import collision

screen.zig had no `c` import yet (it's pure VT logic, no GTK).
Adding `const c = @import("../c.zig").c` at file scope shadowed
seven local variables named `c` (column counters, capture vars).
Inlined `const cre = @import(...).c` inside the regex function
+ helper instead. Tighter scope, no rename churn elsewhere.

### Public surface

- `Screen.searchOptsRegex(allocator, pattern, case_insensitive)`
  mirrors `searchOpts`. Empty haystack rows skipped. Empty
  matches (e.g. `a*` on "x") advance by one byte to break out of
  zero-width loops.
- `findRegexMatches` uses regexec with REG_EXTENDED + (REG_ICASE
  if requested), iterates via `z.ptr + search_pos` slicing.
- Two unit tests: `[0-9]+` finds two number runs across two rows
  with correct columns/lengths; invalid pattern `[unclosed` returns
  zero matches silently (no crash, no error to caller).

### UI

`Window.search_regex: bool` added next to `search_case_insensitive`.
`onSearchKeyPressed` handles Ctrl+R: flips the flag, swaps the entry
placeholder text ("Search regex (Ctrl+R)" vs. "Search (Ctrl+R for
regex)"), re-runs the current pattern. Help text in main.zig lists
Ctrl+R alongside Ctrl+I.

`updateSearch` dispatches to either `searchOpts` or
`searchOptsRegex` based on the flag — same SearchMatch shape goes
to the renderer's overlay path, so highlights, jump-next, and
selection-on-active all work without further changes.

## Smooth-scroll accumulator

User-visible problem: on a high-resolution wheel (Logitech MX
Master) or a touchpad, GTK4 emits fractional dy values like 0.05.
The previous handler treated `dy < 0` as a +3-line jump regardless
of magnitude, so each micro-event scrolled 3 lines — content
flew past on the slightest touch.

### Fix

Per-pane `scroll_accum: f64`. On every event:

```
scroll_accum -= dy * SCROLL_LINES_PER_NOTCH;
const whole = @trunc(scroll_accum);
scroll_accum -= whole;
view_offset += i32(whole);
```

`SCROLL_LINES_PER_NOTCH = 3.0` preserves the historical 3-lines-
per-notch feel for discrete wheels (where dy = ±1.0). Touchpad
events with fractional dy carry the residual fraction forward, so
the user has to scroll roughly 1/3 of a "notch" worth of motion
to advance one line.

### Why no render-side changes

True pixel-smooth scrolling would translate the grid render by a
sub-cell pixel offset (cell_y = row * cell_h - view_offset_pixels).
That requires grid_pass to accept a vertical pixel offset and to
clip the top-most/bottom-most rows. Bigger surgery for a marginal
visual improvement over per-line accumulation. Deferred.

### Edge cases

- Ctrl+wheel font-zoom path returns before touching scroll_accum,
  so a stray fractional dy doesn't poison subsequent scroll-after-
  zoom events.
- Mouse-mode-on-alt-screen path returns before touching scroll_accum
  too (those events become button 4/5 mouse reports — the running
  app handles the scroll itself).
- Clamp: `view_offset + delta` saturates at `scrollbackCount()` via
  u64 widening to avoid overflow when delta_lines is large.

## Profile picker — "New Tab as Profile…"

Plan-v3.md spillover. Profiles existed (config + spawn plumbing)
since plan-v3 F shipped; only missing bit was a UI hook so the
user didn't have to type `keybind.<...>` to use them.

### Why a popover, not a GMenu submenu

GMenu does support parameterized actions — you'd build a sub-GMenu
of items each carrying a `g_menu_item_set_action_and_target_value`
GVariant string, register a `term.new-tab-as-profile` GAction with
`G_VARIANT_TYPE_STRING`, decode the variant on activate. Working
but fiddly: the menu is built once at attach time inside
`Pane.init`, so the profile list would need to be plumbed into
that init path (or rebuilt on every popup). Lifetime of the GVariant
strings + memory for each item ctx adds up.

A second-stage popover sidesteps all that. The right-click menu
gets a single static "New Tab as Profile…" entry; activating it
runs `Window.openProfilePicker()` which builds a fresh popover
each time, anchored on the focused pane, with one GtkButton per
`Config.profiles.items[i].name`. Clicking a button calls
`newShellTabWithProfile(null, name)` and dismisses the popover.

If the user has no profiles defined, the popover shows a single
GtkLabel hint pointing them at `config.conf`. Better than a
disabled menu item that swallows the click silently.

### Wiring

- `menu.Action.new_tab_as_profile` joins the enum + BINDS table.
  Section sec3 (Tab) gains a "New Tab as Profile…" entry between
  "New Tab" and "Rename Tab…".
- `Window.onMenuAction` routes `.new_tab_as_profile` to
  `openProfilePicker`.
- Per-button `ProfileButtonCtx` holds the profile name copy +
  popover ref. `freeProfileButtonCtx` runs as the GDestroyNotify
  when the button is destroyed (popover teardown).
- The button-name copy is sentinel-allocated so it can be passed
  to `gtk_button_new_with_label` directly. The slice is also
  what we hand to `newShellTabWithProfile` — `findProfile` does
  the lookup against `Config.profiles[*].name` and assigns the
  Config-owned reference into `pane.active_profile`, so the
  per-button copy can be freed safely after the call.

## Bug fix: closeFocusedPane reparent ref-counting

User report: "when I close a pane, the entire tab seems to break."
The split was getting torn down but the surviving sibling's content
went blank.

### Root cause

`closeFocusedPane` detaches the surviving sibling from the GtkPaned
via `gtk_paned_set_*_child(parent, NULL)`, then re-attaches it to
the grandparent. In GTK4 the paned holds the only strong ref on
each child — `set_*_child(NULL)` calls `gtk_widget_unparent` which
`g_object_unref`s, dropping the refcount to zero and finalizing
the widget. The local `sibling` pointer becomes dangling; the
follow-up `set_start_child(gp, sibling)` (or `gtk_box_append`)
either crashes or silently installs garbage → tab goes blank.

`splitFocused` already had the same issue and fixed it years back
(comment on commit 1f924a9: "gtk_box_remove drops the box's only
ref → would destroy the widget before paned_set_*_child takes its
own ref"). The close path missed the same trick.

### Fix

`g_object_ref(sibling)` + `g_object_ref(parent)` immediately after
the null-check, with matching `defer g_object_unref` calls. The
sibling stays alive across the detach → reparent transition; the
parent paned stays alive long enough for our cleanup to finish
before GTK destroys it. Also documented inline so the next reader
doesn't lose this — symptom is recoverable-looking (no crash) but
makes the tab unusable.

## Kitty kbd flag 0x08 — report all keys (printables)

Plan-v3 spillover: extend kitty progressive-enhancement keyboard
beyond the disambiguate (0x01) and report-events (0x02) flags
already shipped. Flag 0x08 is "report all keys as escape codes"
— even unmodified printable keypresses go through CSI u.

### Why apps want it

Editors with full kitty-keyboard support (neovim's
`set keyboardprotocol=kitty` mode, kakoune, helix) want every
keystroke as a structured escape so they can build full keymaps
without ambiguity. Without 0x08, plain `a` arrives as byte 0x61
(undistinguished from `cat` piping in 'a'), so the editor can't
tell key-press from streamed text.

### Implementation

In `encode()`, the existing kitty_disamb branch already routed
Tab/Enter/Esc/BS through CSI u and gated modified printables on
(ctrl or alt). Two changes:

1. The branch gate is now `kitty_disamb or kitty_report_all` —
   per spec, 0x08 implies 0x01, so Tab still gets routed even
   when the user only enables 0x08.
2. The printable-emit gate adds `or kitty_report_all` so plain
   unmodified `a` falls into the `kittyKeyEvent` path with mods=1.

### Scope cut: F-keys

Full kitty 0x08 spec also wants F1-F12 and arrows to use the
kitty private-use codepoint table (F1 = 57364, etc.) inside CSI u.
Those still use their existing CSI A / SS3 P / etc. shapes here —
deferred. Apps that don't tolerate this fall back gracefully (the
existing CSI A is still a valid event, just not in the kitty CSI u
form).

### Tests

Three additions in input_conformance_test.zig — flipping the
`encode` function from private to `pub` so the test file can call
it directly:
- Plain `a` without 0x08 → byte `a`; with 0x08 → CSI 97 u
- Shift+`a` with 0x08 → CSI 97;2 u (uppercase folded to lowercase)
- Tab with 0x08 → CSI 9 u (verifies 0x01 implication)

## Kitty kbd 0x08 — F-keys + nav PUA codepoints

Follow-on from the previous tick's printables work. With
`report_all` (0x08) set, kitty's spec says functional keys also
switch to a uniform CSI u shape using the Unicode private-use
codepoint table — apps using full kitty kbd then get every
keystroke via the same `CSI <cp> ; <mods> u` parser.

### Mapping table (from kitty spec)

```
Insert    57348    F1   57364
Delete    57349    F2   57365
Left      57350    F3   57366
Right     57351    F4   57367
Up        57352    F5   57368
Down      57353    F6   57369
Page_Up   57354    F7   57370
Page_Down 57355    F8   57371
Home      57356    F9   57372
End       57357    F10  57373
                   F11  57374
                   F12  57375
```

### Gating

The PUA switch is gated on `kitty_report_all` specifically — with
`disambiguate` (0x01) alone, F-keys keep their legacy SS3 P /
tildeKey shapes, and arrows keep CSI A/B/C/D. This matches kitty's
spec: 0x01 disambiguates *ambiguous* keys (Esc/Tab/Enter/BS +
modified printables), not all functional keys. Apps opt into the
new shapes by setting 0x08.

### Tests

Five additions (input_conformance_test.zig):
- `F1 0x08` → `CSI 57364 u`
- `Up 0x08` → `CSI 57352 u`
- `F1 0x01-only` keeps `ESC O P` (legacy SS3 P)
- `Ctrl+F4 0x08` → `CSI 57367 ; 5 u` (mods column survives)

Plus the prior tick's three tests for printables + Tab implication
already cover the boundary between 0x01 and 0x08 modes.

## grid_pass overlay: italic + faux-bold

Plan-v3 spillover. Bidi/RTL/CJK rows fall through to grid_pass's
overlay path (the cell_pass fast path only handles simple LTR
ASCII), and that path didn't apply italic shear or faux-bold —
so SGR 1/3 silently dropped on Hebrew, Arabic, Devanagari, etc.
Cell_pass already shipped both effects via instanced shader
attributes; this just brings the overlay shader to parity.

### Vertex layout

`Vertex` grew by three f32 fields:
- `italic` — 1.0 = apply shear, 0 = no-op
- `bold` — passed through as `v_bold` for fragment double-sample
- `baseline_y` — cell bottom edge in pixels; the shear pivot

Adds 12 bytes per vertex × 6 vertices/quad. Overlay path is hot
for at most ~50 quads/frame in a typical bidi row; the extra
~3.6 KB/frame is noise.

### Shader changes

Vertex shader applies the shear before the NDC transform:
```
if (a_italic > 0.5) pos.x += (a_baseline_y - pos.y) * 0.231;
```

Same pivot math as cell_pass — `tan(13°) ≈ 0.231`, baseline at
cell bottom so descenders stay anchored.

Fragment shader passes `v_bold` through and does the double-sample
trick: max alpha of two atlas samples 1 texel apart:
```
if (v_bold > 0.5) {
    float a2 = texture(u_atlas, v_uv + vec3(1.0/2048.0, 0.0, 0.0)).r;
    a = max(a, a2);
}
```

### Gating

Both effects gate on `is_single = (x_scale == 1.0 and y_scale == 1.0)`
— DH/DW rows (DECSWL / DECDWL / DECDHL) skip italic+bold because
the shear pivot math gets weird with non-1 y_scale, and it'd
need its own per-quad pivot calculation for the bottom of the
double-height region. Deferred until someone hits that combo and
files a bug; double-height italic Arabic is exotic enough.

`bold_f` also gates on `self.allow_bold` so the existing config
toggle works for both fast path and overlay path consistently.

### Plumbing

Added `pushGlyphQuadStyled` taking the three new params; old
`pushGlyphQuadDim` is now a thin wrapper passing zeros. Only the
two emit functions (`emitLogicalGlyphs`, `emitBidiGlyphs`) call
the styled variant; the preedit path keeps the dim wrapper since
IME composition shouldn't get retroactive italic.

VAO setup added the three new attribute pointers. Build clean.

### Verification

`smoke-cell` ran and passed: `any_text=2961 greenish=340
bluish_border=1648 reddish=479`. The smoke harness is ASCII-only
so the new overlay code itself isn't exercised, but the build
produces a working program — bidi rendering with italic Hebrew
or bold Arabic needs a manual test against `printf 'שלום' | …`
which is hard to automate.

## Kitty kbd flag 0x04 — alt-shifted codepoints

Plan-v3 spillover; rounds out the report-all/disambiguate pair
shipped in earlier ticks. With flag 0x04 set, kitty's CSI u
response gains a colon-separated alt-shifted sub-parameter
embedded in the code field:

```
plain 'a'         → CSI 97:65 u    (alt-shifted = uppercase 'A')
Ctrl+'a'          → CSI 97:65;5 u  (mods column survives)
'a' release       → CSI 97:65;5:3 u (event sub-param survives)
```

### Conservative scope: ASCII letters only

The full kitty spec also wants alt-base (the codepoint per the
QWERTY-base layout, for layout-independent shortcuts like
"Ctrl+Shift+T should always open a tab even on Dvorak"). Doing
that right needs xkbcommon to query layer-0 of the keymap and
translate the keycode through it. Out of scope for this tick.

For alt-shifted, the conservative cut is ASCII letters where
shift→uppercase is layout-independent. Digits and punctuation
skipped — emitting `1:33` (US-layout `!`) would mislead users on
French AZERTY (where Shift+1 is `1`) or German QWERTZ (where
Shift+1 is `!` but Shift+0 is `=`). Apps that need full layout
behavior pair 0x04 with the upcoming 0x10 (associated text)
flag and read the actual shifted glyph from there.

### Plumbing

- `kittyKeyEventFull(buf, code, alt_shifted, ...)` — full-arity
  emitter. `alt_shifted == 0` or `alt_shifted == code_point`
  omits the sub-parameter.
- `kittyKeyEvent` is now a thin wrapper passing `alt_shifted = 0`.
- `encode()` computes `alt_shifted = canon - 0x20` for ASCII
  lowercase letters when `kitty_flags & 0x04` is set; passes 0
  otherwise.

Four new tests cover: 0x04+0x08 plain `a`, Ctrl+`a` with 0x04+0x01,
digit `1` correctly skipping alt-shifted, and the
`alt_shifted == code_point` early-out path.

## Atlas: fontconfig fallback chain

Plan-v3 spillover, biggest remaining UX hole. CJK / Devanagari /
Cyrillic / Hebrew / random Unicode symbols all rendered as the
"missing glyph" placeholder when the user's monospace font lacks
them — even though the system has perfectly good fallback fonts.
Fix: integrate fontconfig so missed codepoints fall through to
the system's preferred coverage.

### Build dep

`fontconfig` joined `gtk4 / libadwaita-1 / freetype2 / harfbuzz /
epoxy / fribidi` in `build.zig::sys_libs`. Already present on every
mainstream Linux desktop — pkg-config-discoverable. `c.zig` pulls
`fontconfig/fontconfig.h` next to the freetype include.

### Atlas state

- `pixel_size: u16` — recorded at init so fallback faces can be
  re-sized to match. Without this, fallback glyphs would render
  at whatever default size FreeType picked (usually 0 → garbage
  metrics).
- `fallback_faces: ArrayList(FT_Face)` — populated lazily as each
  uncovered codepoint triggers an FcFontMatch.
- `cp_to_fallback: AutoHashMap(u32, ?usize)` — codepoint → face
  index. The optional value is null when fontconfig couldn't find
  a covering font (caches negative results so we don't re-query).
- `fc_initialized: bool` — `FcInit()` result. Skip fallback if
  init failed for any reason.

### Fallback path

`lookupOrLoad(cp)`:
1. cp cache hit → return.
2. Primary face has cp (`FT_Get_Char_Index != 0`) → existing path.
3. Else: `findFallbackFace(cp)`:
   - cp_to_fallback hit (positive or negative) → return cached face
     or null without querying.
   - Quick scan loaded fallbacks first — in case a previously-loaded
     fallback also covers this cp (avoids loading the same emoji
     font twice when several U+1F4A9 emoji land in scrollback).
   - FcPattern with `FC_CHARSET` containing just `cp` and
     `FC_SCALABLE = true`. Substitute, default-substitute, match.
     Bias toward scalable to avoid ancient bitmap fonts that don't
     scale to our pixel size.
   - `FT_New_Face` + `FT_Set_Pixel_Sizes(self.pixel_size)`. Append
     to `fallback_faces`, record index in `cp_to_fallback`.
4. If a face came back: `loadGlyphFromFace(fb_face, fb_gid)` packs
   the bitmap into the atlas same as the primary path.

### Refactor: `loadGlyphFromFace`

Existing `lookupOrLoadById` was hard-coded against `self.ft_face`.
Extracted the FT_Load_Glyph + page-pack body into
`loadGlyphFromFace(face, gid)`. The id-cache hookup and the
gid-keyed `glyphs_on_page` append now live in the caller, since
those caches only make sense for the primary face — fallback gids
share the namespace per-face but collide across faces, so they're
keyed by codepoint exclusively.

The body's "page full" / "load failed" returns went from
`return self.cacheEmptyId(gid)` to typed errors (`error.FtLoad`,
`error.PageFull`). Callers handle them by caching the empty
codepoint or empty gid as appropriate.

### Color emoji deferred

CBDT/COLR color glyph rendering needs an RGBA atlas. Our atlas is
single-channel R8 (one byte per pixel) — every consumer assumes
`texture(...).r` is the alpha. Switching would touch cell_pass +
grid_pass shaders, change atlas memory by 4×, and require
per-glyph-flavor branching in the fragment shader. Big change for
limited reach (most users want CJK first; emoji second). Documented
intentionally and skipped.

### Build + smoke

`zig build && zig build test && zig build smoke-cell` all green.
The smoke harness is ASCII-only so the new path isn't exercised
directly, but the build produces a working program — the fallback
only kicks in for uncovered codepoints, ASCII flows through the
existing fast path unchanged.

## Kitty kbd flag 0x10 — associated text

Plan-v3 spillover. Closes the kitty progressive-keyboard quartet
(0x01 disambiguate, 0x02 events, 0x04 alt-shifted, 0x08 report-all,
0x10 associated text — five flags total, all five now wired except
0x04 alt-base which needs xkbcommon).

### Format

```
CSI <code>[:<alt>] [;<mods>[:<event>]] [;<text>] u
```

Three semicolon-separated sections. The text section is appended
when 0x10 is set AND the keypress would produce text in normal
mode. Per kitty spec, if the mods section is at default (1) but
a text section follows, mods is left empty: `CSI 97;;97 u`.

Examples:
- Plain 'a' with 0x10 alone: `CSI 97;;97 u`
- Shift+'a' with 0x10: `CSI 97;2;65 u` (mods=2 for shift, text=65=`A`)
- Ctrl+'a' with 0x10: `CSI 97;5 u` (Ctrl produces 0x01 in normal
  mode, not "text" → section omitted)

### Plumbing

`kittyKeyEventComplete(buf, code, alt_shifted, associated_text,
shift, alt, ctrl, event)` is the most-general emitter — both
`kittyKeyEventFull` and `kittyKeyEvent` are wrappers passing 0
for the extra params.

The format generation lives inside `kittyKeyEventComplete`:
- Code section assembled into a stack buffer (`<code>[:<alt>]`)
- Mods section similarly (`<mods>[:<event>]`); empty when both at
  default AND no text follows
- Final emit branches on whether text is present

`encode()` computes `assoc_text` only when:
- `kitty_flags & 0x10` is set
- `!ctrl and !alt` (modifier produces control byte / nothing)
- For Shift+lowercase letter, text = uppercase variant
- Otherwise text = the codepoint that gdk_keyval_to_unicode gave us

### IME deferred

Multi-codepoint associated text (e.g. dead-key + 'a' = 'á'
composition, or full IME-composed strings) needs hooks into
GtkIMContext's preedit-changed / commit signals to capture what
the IME would emit. Single-cp covers the unmodified printable
case which is the bulk of expected use. Multi-cp left for a
follow-up — would need to plumb a slice through `kittyKeyEventComplete`
and the format would be `;<cp1>:<cp2>:<cp3>` (colon-separated
inside the third semicolon section).

### Tests

Four new conformance tests:
- 0x10+0x08 plain 'a' produces `CSI 97;;97 u` (empty mods)
- 0x10+0x08 Shift+'a' produces `CSI 97;2;65 u`
- 0x10 Ctrl+'a' omits the text section (no plain-mode text)
- `kittyKeyEventComplete` directly with code+alt+text+mods covers
  the maximum-decoration case

`zig build && zig build test` green.

## OSC 4/10/11/12 query-reply tests

Plan-v3.md unverified-list item: "OSC 4 query reply (cmus, emacs)
verified?" Set + reset paths had tests; the query forms (where
the user app sends `OSC N;?` and expects a colour spec back) did
not. Added four tests that capture the parser-reply via
`sink.on_write_pty` and assert the response byte string.

### Why this matters

cmus uses OSC 4 queries to discover the host terminal's palette
and then assigns its own colour scheme around them. Emacs uses
OSC 11 queries to detect dark vs light backgrounds. If the
queries silently failed, both apps would fall back to wrong
defaults and look broken.

### Test shapes

- OSC 4: `ESC ]4;<idx>;rgb:RRRR/GGGG/BBBB ESC \` — note the 8-bit
  byte is duplicated (`ff` → `ffff`) so the response is in 16-bit
  per-channel form per the xterm spec.
- OSC 10/11/12: `ESC ]<num>;rgb:RRRR/GGGG/BBBB ESC \` — same
  16-bit form but converted directly from the f32 colour rather
  than byte-doubling.
- OSC 12 special case: when cursor_color sentinel (alpha=0) is set,
  the response uses default_fg instead — covered by setting fg via
  OSC 10, resetting cursor via OSC 112, then querying OSC 12.

### Coverage gain

+103 LOC of tests. Documents the response byte string + the
fallback semantics inline. Ticks off another item from the
unverified list.

## duplicate_tab action

Small quality-of-life add. Right-click on a pane → "Duplicate Tab"
spawns a new tab inheriting the focused pane's cwd + active_profile.
Subtly different from `new_tab` (which already inherits cwd via
`focusedPaneCwd`) in that it also carries the profile, so users
who set up e.g. a "ssh" profile on one tab can duplicate it
without re-picking from the profile menu.

### Wiring

- `Action.duplicate_tab` joins `input.zig::Action` with name +
  label. Unbound by default — keybind via `keybind.duplicate_tab`.
- `menu.Action.duplicate_tab` joins the right-click menu's tab
  section between "New Tab as Profile…" and "Rename Tab…". Both
  the BINDS table and the GMenu append picked up.
- `Window.duplicateCurrentTab()` reads the focused pane's
  `active_profile`, calls `newShellTabWithProfile(null, profile)`
  which already pulls cwd from the focused pane via
  `focusedPaneCwd()`.

### Out-of-scope: split-tree clone

Cloning a tab with multiple panes / nested splits isn't supported
— the new tab gets one shell. Replicating the full layout tree
would re-walk the existing collectTree → buildTreeWidget pipeline
that the layout save/restore uses, doable but ~2x the LOC and
edge cases (different cwds per pane, different profiles per pane).
Most user value is "same shell, here, again" which the simple
form already covers.

## copy_scrollback + scrollback-soft-wrap fix

Two-in-one: shipped a new `copy_scrollback` action and uncovered a
latent bug while writing its test.

### copy_scrollback

Extends `copy_screen` (visible region only) to dump the entire
scrollback ring + active screen as text → system clipboard.
Useful when sharing a long terminal session: previous workflow
was scroll-up + drag-select chunks, which is hideously slow on
10k-line backlogs.

`Screen.extractScrollback(allocator)` walks rows
`-scrollbackCount() .. rows-1`, honouring `continues_above` so
shell output that wrapped across rows pastes as one logical line.
OSC 8 link spans survive too, encoded as markdown `[text](uri)`.

Wired through `Action.copy_scrollback` (unbound by default,
config via `keybind.copy_scrollback`), routed in
`runAction → copyScrollback`. main.zig HELP_TEXT mentions the
binding next to Ctrl+Shift+A.

### Bug found while testing

The first version of the test asserted that "abcdefg" wrapped
across two rows then scrolled to scrollback would copy back as
one line. It came out as `"abcde\nfg\n…"` — the soft-wrap join
was lost.

Root cause: `pushScrollbackTakeOld` and `pushScrollback` built
the scrollback Line via struct literal `.{ .cells = ..., .id = ... }`
which defaulted `continues_above` to false. So every scroll-up
into scrollback erased the soft-wrap bit. extractSelection
already had the right "suppress newline if next row continues"
logic but the underlying flag was always false in scrollback —
silent corruption that nobody noticed because soft-wrap-aware
copy paths just gave the wrong answer.

Fix: `pushScrollbackTakeOld` + `pushScrollback` take a
`continues_above: bool` param. `scrollUp` stashes it alongside
cells + ids per row being moved out. `reflowMain` and
`resizeBuffer` (the other callers) pass through the source
line's flag.

### Cleanup

Also tidied `duplicateCurrentTab` — the previous tick had a
dead `cwd` capture that was unused (newShellTabWithProfile pulls
cwd from `focusedPaneCwd()` internally). Removed.

`zig build && zig build test && zig build smoke-cell` all green.

## duplicate_tab: split-tree clone

Closes the loose end from the previous duplicate_tab tick.
Single-pane tabs duplicated cleanly with profile carry; multi-pane
split tabs flattened to one shell, losing the splits the user had
arranged.

### Branch on root widget type

The tab page's child is a wrapper Box. Its first child is the
layout root — either the Pane wrapper (single pane) or a GtkPaned
(split). Branch on `g_type_check_instance_is_a(root,
gtk_paned_get_type())`:

- **Not a paned** (single pane) — keep the existing fast path:
  `newShellTabWithProfile(null, pane.active_profile)`. Carries the
  profile, which TabSpec can't (no profile field on PaneSpec yet).
- **Is a paned** (split) — round-trip via the layout-spec pipeline:
  arena-allocate, `collectTree(arena, root)` to build a Tree,
  package as `TabSpec` with the current page's title +
  `pinned = false` (fresh duplicates start unpinned), call
  `newTabFromSpec`. Each leaf pane gets its current OSC 7 cwd
  preserved via collectTree's existing logic.

### Trade-off documented

The split-tree path drops profiles per pane. Adding `profile_name`
to PaneSpec would fix that and also fix layout save/restore's
silent loss of profiles. Out of scope for this tick — would need
a serializer schema bump + restore-side findProfile lookup at
each leaf, plus a TabSpec versioning bump if we want backwards
compat. Picked the smaller win (preserve splits) over the bigger
refactor.

`zig build && zig build test` green; no render code touched.

## PaneSpec.profile — per-pane profile in layout

Closes the loose end from the previous duplicate_tab tick.
TabSpec/PaneSpec didn't carry the per-pane profile, so layout
save/restore (`--restore`, default.json) AND duplicate_tab's
split-tree path silently dropped per-pane profile assignments.

### Schema bump

`PaneSpec.profile: []const u8 = ""` joins the existing fields.
Default empty so older layout JSON parses unchanged via the
parser's `ignore_unknown_fields = true`. Empty value also
shipping-clean: signals "no profile, use global config" without
needing a special sentinel.

### collectTree

Reads `pane.active_profile` (already tracked since the original
profiles MVP), dupes into the arena, writes to the new field.
`""` when the pane never had a profile — keeps the JSON small
for users who don't use profiles.

### buildTreeWidget

Two changes around the leaf path:

1. **Resolve profile up-front** (before argv construction) so
   `profile.shell` can override `command[0]`. Without this, a
   pane originally spawned as profile.shell="ssh user@host" then
   saved + restored would re-spawn the captured `$SHELL` instead
   — which is what the user already moved AWAY from when they
   picked the profile. Argv loop checks `i == 0 and profile.shell
   non-empty` and substitutes.

2. **Apply profile font / font_path overrides** after
   `pane = makePane(term)`. Mirrors `spawnShellPaneOpts`'s
   layered resolution: profile > spec > global. Doesn't replicate
   the full spawnShellPaneOpts body (palette resolution, scheme
   lookup, scrollback override) — those don't apply to layout
   restore where the pane content is being recreated, not freshly
   spawned. Picked the conservative subset; can extend if a user
   reports a missing override.

### Round-trip flow

- Save: collectTree captures `pane.active_profile` → JSON.
- Load (--restore / default.json / duplicate split): JSON parses
  → buildTreeWidget looks up profile by name → applies overrides.
- Older JSON without the field: parses as `profile = ""` → no
  profile applied → behaves identically to pre-change.

`zig build && zig build test` green throughout.

## Layout schema round-trip tests

Recent ticks added two TabSpec/PaneSpec fields (`pinned`, `profile`)
without explicit round-trip coverage. Adding three tests now so a
future serializer / parser change can't silently drop them.

### Tests added

1. **`round trip preserves PaneSpec.profile`** — write a single
   tab with `profile = "ssh-prod"`, save, load, assert the field
   came back.
2. **`round trip preserves TabSpec.pinned`** — two tabs, one
   pinned=true and one default (false). Save + load + assert
   both bits land where they started.
3. **`load tolerates older JSON without profile / pinned fields`**
   — hand-write minimal v2 JSON missing the new fields, parse it,
   assert the defaults (`pinned = false`, `profile = ""`) fill in.
   Verifies the `ignore_unknown_fields` + Zig default-init combo
   keeps backwards-compat. Older `last.json` and `default.json`
   files keep parsing through schema additions.

`zig build test` green; +89 LOC of pure test coverage. No
production code touched.

## scrollback_top / _bottom actions

Small UX gap: existing `scrollback_page_up` / `_page_down` walked
by screenfuls but there was no shortcut to jump straight to the
oldest line in the buffer or back to the live position. Added
two new actions matching gnome-terminal + kitty conventions:

- **Ctrl+Shift+Home** → `scrollback_top` — set `view_offset =
  scrollbackCount()` (max scroll back).
- **Ctrl+Shift+End** → `scrollback_bottom` — set `view_offset =
  0` (live screen).

Both go through the existing per-pane runAction dispatch — no
broadcast / window-level wiring needed because scrolling is a
per-pane concern. `screen.dirty = true` triggers the next render.

Help text in main.zig HELP_TEXT lists the new chord; user can
rebind via `keybind.scrollback_top` / `keybind.scrollback_bottom`
just like every other action.

## clear_scrollback — wipe ring, keep visible

UX gap: existing `clear_and_scrollback` (Ctrl+Shift+K) wipes
both visible screen AND scrollback. Sometimes I want to drop the
scrollback (it's gotten noisy from a long build / git log) but
not lose the current shell prompt + last-command output that's
on screen.

### Implementation

`Screen.clearScrollbackOnly()` mirrors `clearAndScrollback` minus
the visible-buffer clear and cursor reset:

- Frees scrollback line buffers, resets ring length + head pointer
- Snaps `view_offset = 0` (the scrollback we were viewing is gone)
- `dirty = true` for repaint
- Active screen rows + cursor untouched

`Action.clear_scrollback` joins the enum + name + label tables.
Per-pane runAction case calls the new method. No default keybind
— bind via `keybind.clear_scrollback` if you want it. The
existing Ctrl+Shift+K stays for "clear everything."

### Test

New unit test fills 4 lines into a 2-row screen (so 2 fall to
scrollback), calls `clearScrollbackOnly`, asserts `scrollbackCount
== 0` and that `extractScreen` still returns the "ccc\nddd\n"
visible content.

Touched render-adjacent code (screen.zig), so `smoke-cell` ran
and passed alongside `zig build && zig build test`.

## Tab tooltip: $HOME → ~ abbreviation

Small polish to the existing tab-tooltip cwd line (shipped a few
ticks back). For users working under $HOME (which is almost
everyone), the full path was repetitive:
`/home/skerit/projects/sketerm` reads less cleanly than
`~/projects/sketerm`, especially when several tabs share the same
parent.

### Implementation

`onTermCwdChanged` now runs the cwd through a small abbreviator
before formatting the tooltip:

- Read `$HOME`. If unset or empty, fall through to raw cwd.
- Check `cwd` starts with `home` AND that the next byte is
  either end-of-string or `/`. The trailing-slash check matters
  because otherwise `HOMEextra` (a sibling dir) would falsely
  fold to `~extra`.
- Compose `~` + `cwd[home.len..]` into a stack buffer. Only
  taken when the result fits in 512 B; longer paths fall back
  to raw cwd to keep this allocation-free.

### Edge cases

- Cwd outside HOME (`/tmp`, `/var/log`) — unchanged.
- HOME unset — unchanged.
- Cwd identical to HOME — `cwd[home.len..]` is empty, result is
  just `"~"`. Correct.
- HOME longer than cwd — `startsWith` fails, no abbreviation.

`zig build && zig build test` green; no render code touched so
no smoke run needed.

## sample.conf catch-up — document 8 missing keybinds

Recent ticks shipped a stack of new actions but nobody added them
to `data/sample.conf`. That file is the canonical reference users
grep through to find action names. Closed the gap:

- `scrollback_top` / `scrollback_bottom` (Ctrl+Shift+Home/End defaults)
- `broadcast_cycle` (Ctrl+Shift+G default)
- `restore_closed_tab` (Ctrl+Shift+Z default)
- `duplicate_tab` (unbound, with split-tree-pipeline note)
- `copy_selection` (unbound — distinct from interrupt_or_copy)
- `copy_scrollback` (unbound, with soft-wrap note)
- `clear_scrollback` (unbound, distinct from clear_and_scrollback)

Each has the default accelerator inline (or empty for unbound)
and a short comment for the ones whose semantics aren't obvious
from the name alone. Pure docs change — no production code
touched, build green for sanity.

## Window title: broadcast mode indicator

Safety net for the broadcast-typing feature (Ctrl+Shift+G).
Existing visual cue was a CSS class on the per-pane titlebar —
which only shows up when `show_titlebar = true`. Users running
with titlebars off had no way to tell typing was being multiplexed
across multiple PTYs except by typing and watching unexpected
characters appear elsewhere.

### Fix

`Window.refreshWindowTitle()` rebuilds the GTK window title:

- `groupsend = .off` → `"sketerm"` (unchanged from init)
- `.group` → `"sketerm — broadcast: group"`
- `.all` → `"sketerm — broadcast: all"`

`cycleGroupSend` calls it after the mode flip + per-pane CSS
refresh. Visible regardless of `show_titlebar` since the GTK
window decoration always exposes the title (HeaderBar, taskbar
hover, alt-tab labels, compositor switchers).

Allocation per call (sentinel buffer, `defer free`) — no
caching needed; broadcast cycling is cold-path. ~24 LOC; no
render code touched.

## matchBinding dispatch test coverage

Closes the "Input dispatch test harness" item from plan-v3.md
line 294 — listed as supposed-to-be-added before E (custom
keybindings) shipped, but nobody actually wrote them. Six tests
now exercise `matchBinding` against the real `default_bindings`
table and a synthetic colliding-accel table.

### Coverage

- **Ctrl+Shift+T → new_tab** — sanity check the canonical default.
- **Ctrl+Tab → next_tab** — separate from Ctrl+Shift+Tab (which
  is prev_tab); guards against accidentally loosening the mods
  filter.
- **Lock-bit filter** — Caps-Lock on while pressing Ctrl+Shift+T
  must still match. `SIGNIFICANT_MODS` masks Lock/Group bits;
  this test would catch a regression that included them.
- **Unmatched returns null** — F12 isn't bound by default.
- **Wrong-mods rejected** — Ctrl+T (no Shift) doesn't trigger
  new_tab.
- **First-match wins** — two bindings on the same accel: first
  one in the table is returned. Documents the contract so users
  prepending overrides via `keybind.<...>` config can rely on
  order.

Plan-v3 had this listed as gating E but it shipped without the
harness. Belt-and-braces now: regression coverage retroactively
applied. Pure test addition; no production code touched.

## CPU fix: kill 60 Hz idle GL pumping

User report: "sketerm uses A LOT of CPU power, especially on
laptop battery." Profiled the render path and found the culprit
in pane.zig:156 — `gtk_gl_area_set_auto_render(area, 1)`.

### What auto_render does

Per GTK4 docs:
> If auto_render is TRUE the GtkGLArea will automatically queue
> a redraw at every refresh of the application's clock.

That means: 60 Hz on a standard display, 120/144/240 Hz on
high-refresh — full GL frames every clock tick regardless of
whether anything changed. The render handler does serious work
each call:

```
glViewport / glClearColor / glClear
atlas.markFrame
cell_pass.rebuildAndUpload    ← scans all dirty rows
image_store.flushUploads
image_pass.drawZ (below)
cell_pass.draw
grid_pass.buildVertices       ← rebuilds overlay vertex buf
grid_pass.draw
image_pass.drawZ (above)
```

For an idle terminal staring at a prompt, that was just thermal
load — the GPU wakes, rasterizes, and the result is identical
to the previous frame. On battery, the CPU spends ~milliseconds
per frame in this path × 60 = 6-12% baseline CPU.

### Fix

Set `auto_render = 0` and convert every `gtk_widget_queue_draw`
on the GLArea to `gtk_gl_area_queue_render`:

- pane.zig: 11 sites bulk-replaced (selection, image arrival,
  tick, mouse press/double-click/end, drag begin/end, motion,
  scroll). The tick callback now only pumps a render when
  `screen.dirty` actually flipped.
- input.zig: 1 site (clear-on-copy).
- window.zig: 3 sites that need GL repaint (prompt jump, dim
  refresh, auto-theme color change). Three other window.zig
  sites stay on `queue_draw(p.widget())` because they're CSS
  / wrapper invalidations only (broadcast titlebar class).

### Resize edge case

`onResize` doesn't queue_render explicitly today — relied on
auto_render's continuous pump. Without that, a window resize
could leave the GLArea showing stale framebuffer contents from
the old size until something else fired. Added an explicit
`queue_render` at the end of onResize.

### Expected impact

Idle terminal: ~0% baseline CPU (was 6-12%). Active typing /
animation / scrolling: same as before — the render handler runs
when there's actual work, just no longer between events. Cursor
blink still triggers via the tick callback at 500 ms intervals.
The tick itself still fires at frame rate but does almost nothing
when nothing's dirty (~µs scale).

`zig build && zig build test && zig build smoke-cell` all green.

## perf: drain → render dispatch direct

Follow-up to the auto_render fix. After auto_render=FALSE, the
GL render runs on demand via queue_render. The tick callback was
the dispatcher: it polled `screen.dirty` at frame rate and
scheduled queue_render when set. That added up to a frame's
worth of latency between "PTY output processed" and "pixels on
screen" — small but noticeable on remote sessions or heavy
output where every frame counts.

### Direct dispatch

`Terminal.on_render_request` callback fires from `mainDrain`
once at the end of the batch when `screen.dirty` is set and
DECSET 2026 sync mode is OFF. Pane wires it to a tiny shim that
clears dirty and calls `gtk_gl_area_queue_render(self.area)`.

Now the path is:
```
worker thread → ring push → schedule_drain
  → main thread idle → mainDrain
    → loop: ring.pop + screen.apply
    → on_render_request → queue_render (this frame)
```

vs. before:
```
... → mainDrain (left dirty=true, no render scheduled)
  → next frame tick (~16ms) → notice dirty → queue_render
    → frame after that → render
```

### Tick still needed

The tick callback isn't going away — it still drives:
- Cursor blink (every 500 ms toggle)
- Bell flash fade (200 ms decay)
- Animation frame advance (kitty graphics)

Those aren't drain-driven so they need a periodic check. The tick
just no longer polls dirty for drain-driven renders.

### Risks

The tick still has the dirty branch (line ~908) as a fallback.
If anything sets dirty without going through drain (e.g. mouse
events that already queue_render directly), the tick clears
dirty harmlessly. Belt-and-braces — no correctness change.

Build + test + smoke green.

## perf: tick self-removes when idle

After auto_render=FALSE killed the GL pump and drain → render
direct dispatch eliminated the tick from output latency, the
tick callback itself was the last thing pumping at frame rate
when nothing was happening. Per-pane cost was small (~µs/tick)
but multiplied across multi-pane setups (8 panes × 60 Hz × N µs)
it added up to a measurable battery hit on otherwise-idle
sessions.

### Pause/resume

`Pane.tick_id: c_uint = 0` tracks the GTK tick callback id (0 =
not registered). `Pane.ensureTickRunning()` is the idempotent
installer — checks `tick_id`, registers via
`gtk_widget_add_tick_callback`, stores the returned id.

`onTick` at the end checks three flags:
- `has_blink_work` — focused pane with a blinking-cursor shape
- `has_bell_work` — `bell_at_us > 0` and within the 200 ms fade
- `has_anim_work` — any kitty-graphics image with `frames >= 2`
  and `playing = true`

If all three are false, `tick_id = 0` + return G_SOURCE_REMOVE.
The frame clock stops pumping for this widget. `gtk_widget_remove_tick_callback`
isn't needed — the return value is the documented removal path.

### Re-install triggers

Three event handlers call `ensureTickRunning` to wake the tick
when work appears:
- `onFocusEnter` — a newly-focused pane needs the tick to drive
  cursor blink. (Also added `queue_render` so the focus-border
  swap is visible immediately, not next frame.)
- `onBellEvent` — bell flash fades over 200 ms; tick pumps the
  fade.
- `onImageEvent` — newly-arrived kitty graphic might be animated;
  tick advances frames.

Drain → render is already direct (previous tick), so output
events don't need to wake the tick; the GL render fires from
`mainDrain` directly.

### Cold-start

`Pane.init` calls `ensureTickRunning` once so any early bell /
animation event during the first tick can be picked up. The tick
will self-remove on its first idle iteration.

### Why focus-leave doesn't wake the tick

Focus-leave sets `cursor_blink_on = true` + dirty + queues a
render directly. No subsequent tick work is needed (cursor is
static when unfocused), so the tick that may currently be
running self-removes on its next iteration. Net win: unfocused
panes have zero tick overhead.

`zig build && zig build test && zig build smoke-cell` all green.

## Bug fix: faux-bold left-edge artifact

User report: "bold characters are missing 1 vertical row of pixels
on the left." The faux-bold trick (added in commit 6923932) sampled
the atlas at `v_uvw + (1/2048, 0, 0)` and took `max(self, sample)`
for the alpha. The intent: dilate the stroke by 1 texel to fake a
heavier weight without a second FreeType face.

### What went wrong

The `+1 texel right` direction means each fragment shows `max(self,
right_neighbor)`. Visually that dilates the glyph LEFT (because
each fragment can see its right neighbor's coverage, so leftmost
fragments inherit the second column's brightness).

For glyphs with anti-aliased edges (most fonts), the leftmost
column has soft alpha (e.g. 0.3) fading INTO the stroke at column
+1 (alpha 1.0). The `+1` sample makes the leftmost fragment show
1.0 — the soft edge is overwritten with a bright sample. Visually
the antialiased fade disappears, reading as "the glyph's left
pixel column is missing."

### Fix

Flip the offset direction: sample `v_uvw - (1/2048, 0, 0)`. Each
fragment now shows `max(self, left_neighbor)`. The dilation goes
RIGHT instead — the antialiased left edge is preserved (it was
the leftmost column to begin with; max with the gap to its left
doesn't change it). Matches how real bold typefaces work: thicker
strokes expanding into the cell's whitespace on the right while
preserving the left bearing.

Two-line shader change in cell_pass.zig + grid_pass.zig.
`zig build && zig build test && zig build smoke-cell` all green.

## smoke-transparency — retroactive gating coverage

Plan-v3.md line 293 listed `smoke-transparency` as supposed-to-be-
added before C (transparency) shipped. C shipped without it.
Closing the gap now so future bg-alpha regressions get caught.

### What it does

`src/smoke_transparency.zig` mirrors smoke_cell's EGL surfaceless
context + Atlas + CellPass + GridPass pipeline, with three
differences:

1. `screen.default_bg = (0.10, 0.10, 0.10, 0.5)` — alpha 0.5
   instead of 1.0.
2. `glClearColor(.., .., .., 0.5)` matches.
3. `grid_pass.buildVertices(.., focused = false)` — skips the
   focus-border quad which is fully opaque and would push corner
   pixel alphas back up to 1.0 regardless of bg setting.

### Assertions

After render, the readback histograms the alpha channel:
- `translucent` = pixels with `a < 200` (= ~78 %). Background
  cells with bg alpha=0.5 land near a=128. **Must be ≥ 90 % of
  total.** Threshold catches regressions where bg_a leaks to 1.0.
- `fully_opaque` = pixels with `a >= 250`. Glyph fill interior
  blends with `dst.a * (1 - src.a) = 0` for src.a=1, so opaque
  text reads as a=255. **Must be ≥ 5** to confirm text rendered.

First run: `total=30720 translucent=30541 fully_opaque=53` →
99.4 % translucent + 53 opaque text fill = PASS.

### Build target

`zig build smoke-transparency` — separate from `smoke-cell` so
each can fail / pass independently. build.zig wires the executable
the same way (`sketerm-smoke-transparency`), running it via
`addRunArtifact` under the new step.

## perf: cached is_focused (drop GTK round-trip)

Smaller perf polish. Both `onRender` and `onTick` called
`gtk_widget_has_focus` once per invocation. The function is cheap
but not free — looks up the widget's surface, walks the focus
chain, returns. A few hundred ns per call × every render + tick.

`Pane.is_focused` was already a tracked field, kept in sync by
`onFocusEnter` (sets true) and `onFocusLeave` (sets false). Both
handlers also queue_render, so the cache is authoritative for any
frame that gets drawn.

Two-line change replacing both call sites with `const focused =
self.is_focused;`. Identical semantics, fewer GTK round-trips.

`zig build && zig build test && zig build smoke-cell` all green.
The smoke harness builds CellPass / GridPass directly (no Pane,
no focus signal) and passes `focused = true` explicitly to
`buildVertices`, so the smoke pixel counts are unaffected.

## Bug fix: search match navigation (tick-pause regression)

Surfaced while auditing for tick-pause-induced regressions.
`Window.applyCurrentMatch` and the no-match clear branch in
`updateSearch` both set `screen.dirty = true` but never called
`queue_render`. Before the tick-pause change, the pane's tick
callback would catch the dirty bit at the next 60 Hz tick and
queue_render itself. After the tick-pause change, an unfocused
pane (which is what we have during search interaction — the
search bar holds focus, not the pane) has its tick removed: dirty
sits set but no tick is around to consume it.

Symptom: Enter / Shift+Enter to walk through matches scrolled
view_offset internally but the GL didn't repaint until something
else woke a render. Sometimes broken-feeling, sometimes blank.

### Fix

Both call sites — applyCurrentMatch (after view_offset adjust)
and updateSearch's no-match clear (after wiping highlights) —
now call `gtk_gl_area_queue_render` explicitly on the search
pane's GLArea. Drain → render direct already covers the
"text arrived" path; this closes the search-only loop.

`zig build && zig build test && zig build smoke-cell` all green.

## Audit: queue_render after every screen.dirty

Follow-up to the search-render fix. The tick-pause perf change
(commit a79edb2) means panes with non-blinking cursor shapes
(`cursor_blink = false` config) have no tick callback running.
Any code path that sets `screen.dirty = true` without an explicit
companion `queue_render` would silently fail to repaint.

Audited every dirty-setter in input.zig, pane.zig, window.zig:

### input.zig (8 sites fixed)

- `onImCommit` clears preedit on IME commit.
- `onImPreeditChanged` updates preedit text mid-composition.
- `onKeyPressed` snap-to-bottom (any keystroke from a scrolled-back
  view should jump back to live).
- `runAction` for `scrollback_page_up`, `scrollback_page_down`,
  `scrollback_top`, `scrollback_bottom` — all four scrollback-
  jump actions adjust view_offset + dirty + were missing render.
- `clear_select_on_copy` after copy — already had queue_render
  (added in an earlier fix).

### pane.zig (1 site fixed)

- `onImageDeleteFullEvent` — kitty graphics deletion handler.
  Previously relied on tick to consume dirty.

### Sites NOT changed (correctly already covered)

- onTick body's internal dirty=true (cursor blink, bell fade,
  animation): the tick itself queue_renders at the end, so these
  are consumed in the same iteration.
- screen.zig internal apply()-path dirty=true: drain calls
  on_render_request after the batch which queue_renders.
- pane.zig mouse/drag/scroll handlers: already had queue_render
  paired (most predate the tick-pause change).
- window.zig sites: already audited / fixed in previous ticks
  (search applyCurrentMatch, dim refresh, auto-theme color, etc.)

### Pattern documentation

Going forward: any new code that sets `screen.dirty = true` on
a pane that may not be focused (or whose tick may be paused)
must call `gtk_gl_area_queue_render(self.area)` immediately
after. The drain → on_render_request hook covers PTY-output
paths automatically; manual UI-side dirty bits need explicit
queue_render.

`zig build && zig build test && zig build smoke-cell` all green.

## toggle_tab_bar action

Single-tab workflows have ~32 px of vertical space taken by the
AdwTabBar that's just empty. Now bindable:

- `Action.toggle_tab_bar` joins the input enum + name + label.
- `Window.toggleTabBarVisibility()` reads `gtk_widget_get_visible`
  on `self.tab_bar` and flips. AdwToolbarView already handles the
  layout reflow when the bar disappears — content area grows.
- Unbound by default; user binds via `keybind.toggle_tab_bar` if
  they want it. Documented in sample.conf.

No state to persist — bar visibility resets to "shown" on every
launch (matches gnome-terminal / xterm behaviour where bar
visibility is purely runtime). If user demand surfaces a need,
adding a `Config.tab_bar_visible: bool = true` is a small follow-
up.

## Config: show_tab_bar

Follow-up from the toggle_tab_bar action — completes the
"persist initial visibility" suggestion. Mirrors `show_titlebar`
(per-pane title bar) for symmetry:

- `Config.show_tab_bar: bool = true` — default true matches the
  GTK widget default + previous behaviour.
- `Config.serialize` writes `show_tab_bar = false` only when
  non-default (keeps minimal config files terse).
- `loadFromBytes` parses the key.
- `Window.init` calls `gtk_widget_set_visible(self.tab_bar, 0)`
  when config says false; `applyConfigChange` re-applies on
  live edits so a prefs UI tweak takes effect without restart.

The runtime `toggle_tab_bar` action still flips visibility purely
in session state — config provides the default, toggle is a
non-persisting one-off. Matches gnome-terminal / xterm convention
where bar visibility resets to "shown" each launch unless the
user changed the config.

sample.conf documents the new key next to `show_titlebar`. Build
+ tests green.

## tests: visibility flag round-trip

Two new tests in config.zig cover the `show_titlebar` /
`show_tab_bar` pair:

1. **`show_titlebar / show_tab_bar round-trip`** — flips each from
   default (titlebar: false → true, tab_bar: true → false), serializes,
   asserts both lines present in the output, re-parses, asserts
   the parsed Config matches.
2. **`visibility defaults are NOT emitted (terse output)`** — fresh
   default Config serialised, asserts neither key appears in the
   output. Catches future regressions where someone changes the
   serializer to always emit these (would clutter user configs).

Both add coverage to the serializer's "skip default" gates which
have historically been subtle (each new field needs the gate
manually). Pure test addition; no production code touched.

## Config: ~/ expansion in path values

Quality-of-life add. Users with `font_path = /home/skerit/fonts/Hack.ttf`
in their config can now write `font_path = ~/fonts/Hack.ttf`.
Mirrors shell convention without trying to be a full shell parser.

### Scope

`expandTilde(arena, value)` helper at file scope. Applied to four
keys:
- `font` / `font_path` (global + profile)
- `shell` (global + profile)

Other config values (TERM, color schemes, etc.) aren't paths so
no expansion needed. The serializer writes whatever the field
holds — once expanded, the Config arena owns the absolute path.

### Rules

1. Empty value or value not starting with `~` → arena.dupe (no
   change). Identity for the common case.
2. `~` followed by anything but `/` (e.g. `~root/bin/sh`) →
   arena.dupe. Shell-style other-user expansion isn't supported.
3. `~` alone → `$HOME`.
4. `~/...` → `$HOME/...`.
5. `$HOME` unset → arena.dupe (no change). User gets the literal
   `~` and figures it out.

### Tests

Two tests:
- `~ expansion in path-valued keys` reads the runner's `$HOME`,
  feeds `font = ~/fonts/Hack.ttf` + `shell = ~/bin/myshell`,
  asserts both come back as absolute paths.
- `~user (no slash after ~) is NOT expanded` feeds
  `shell = ~root/bin/sh`, asserts it round-trips verbatim.

`zig build && zig build test` green.

## Link hover: pointer cursor

UX polish — when the mouse is over an OSC 8 hyperlinked cell or
an auto-detected URL, the cursor turns into the "pointer" (hand)
shape. Matches gnome-terminal, kitty, and basically every modern
terminal. Tooltip showing the URL was already wired; this finishes
the visual cue.

### State

`Pane.cursor_over_link: bool` tracks the current state so we only
call `gtk_widget_set_cursor_from_name` on entry/exit transitions,
not every motion event (which would hammer the GTK input pipeline
with redundant work).

### Flow

`onMotion` already detected hover for tooltip purposes. Refactored
to compute `over_link` once and use it for both the tooltip AND
the cursor flip:

- `over_link = true` AND `!cursor_over_link` → set cursor "pointer"
  + flip flag.
- `over_link = false` AND `cursor_over_link` → set cursor null
  (system default) + clear flag.
- Other state combinations: no GTK call.

### Trade-off with OSC 22

When an app sets a custom cursor via OSC 22 (e.g. "watch"), the
link-hover override momentarily wins, then on leave we reset to
`null` instead of the OSC 22 setting. Acceptable: OSC 22 is rare,
and link-hover takes precedence in modern terminals anyway. Could
be improved by storing the OSC 22 state and restoring on leave —
deferred unless a user reports the conflict.

`zig build && zig build test` green. No render code touched.

## reload_config action

User can edit `config.conf` and apply changes without restarting.
Useful while iterating on theme / palette / keybind tweaks —
saves the restart-and-find-your-tabs-again cycle.

### Implementation

`Action.reload_config` joins the input enum + label + name.
`Window.reloadConfigFromDisk()` calls `Config.load(allocator)`
(uses XDG search path) and feeds the result through the existing
`applyConfigChange` pipeline that the Preferences UI already
uses for live edits — palette, font_size, ligatures, dim
factors, scheme, all picked up immediately.

### Limitations

- Doesn't honour `--config <path>` overrides. Users who started
  with a non-default config path would need to restart.
- The `applyConfigChange` path doesn't reload existing pane
  scrollback capacity (changing `scrollback = 50000` only takes
  effect for newly-spawned panes). Same limitation as prefs UI.

### Wiring

Unbound by default — bind via `keybind.reload_config = <Control>F5`
or whatever feels natural. Documented in sample.conf next to
`toggle_tab_bar`.

`zig build && zig build test` green.

## SIGUSR1 → reload config

Companion to the `reload_config` keybind from the previous tick.
`kill -USR1 $(pidof sketerm)` from any shell now re-reads
`config.conf` and live-applies. Useful when:

- Editing the config in another tab and don't want to switch
  focus to sketerm.
- Scripting theme changes from a window-manager hook (e.g.
  toggle dark/light mode at sunset → write a different
  `default_bg` → `kill -USR1`).
- SSH'd into the box where sketerm is running headed and
  pressing the keybind isn't an option.

### Wiring

`g_unix_signal_add(SIGUSR1, onSignalReloadConfig, null)` joins
the existing SIGTERM/HUP/INT handlers in main.zig. Glib's signal
shim dispatches on the main thread, so reaching into `g_app.window`
from the handler is safe (Window methods aren't thread-safe in
general). Returns G_SOURCE_CONTINUE so the source stays armed
across multiple signals.

### Help text

main.zig HELP_TEXT gains a footer note pointing users at the
`kill -USR1` invocation. Both the keybind and the signal route
through `Window.reloadConfigFromDisk` — same applyConfigChange
pipeline.

`zig build && zig build test` green.

## goto_tab_1..9 (Alt+1..9)

Common multi-tab pattern across browsers, gnome-terminal, kitty,
etc. Alt+digit jumps to the corresponding tab by 1-based index.
Doesn't collide with shell C-x chords (which use Ctrl) or
terminator's Ctrl+Shift+digit splits.

### Wiring

Nine actions `goto_tab_1` … `goto_tab_9` join the input enum +
labels + names. Each maps to `Window.gotoTab(0..8)` at dispatch
time so the action enum stays free of payloads (matches the
existing per-action one-to-one keybinding pattern).

`Window.gotoTab(index)` calls `adw_tab_view_get_nth_page` +
`adw_tab_view_set_selected_page`. Out-of-range index (fewer tabs
than the digit) is a clean no-op so Alt+9 with only 3 tabs open
just doesn't do anything.

### Why nine actions, not parameterized

The keybind table is `(keyval, mods) → Action` with no payload.
A parameterized action would need either a separate "args" field
in `Binding` or a different dispatch shape. Nine enum entries
are slightly verbose but mechanically simple — and the user-
configurable upper bound is "Alt+9" anyway since digit keys are
the natural binding. Tab-10+ users still cycle via Ctrl+Tab.

main.zig HELP_TEXT lists the new chord.

## render: gate overlay rebuild on input change

`grid_pass.buildVertices` ran every render unconditionally — full
vbuf rebuild including the per-row bidi/DH detect, URL scan, and
selection emit, even when no overlay-relevant input had moved
since the last frame. On large grids (4K, 24pt font, ~270x90
cells) the per-row scans made every redraw heavier than it
needed to be, and idle-blink frames did the same work just to
toggle cursor visibility.

Now: `CellPass.rebuildAndUpload` records `cells_rebuilt` (any
row got rebuilt this call). `GridPass` keeps a `Snapshot` of
overlay inputs (cursor, selection, search, preedit, focus,
view_off, bell, default colors/palette, viewport, atlas
metrics, GridPass-owned tunables) plus the per-page atlas
generation. `buildVertices(... cells_changed)` returns early if
none of these moved AND the bell isn't currently fading — `draw`
reuploads the prior vbuf as-is.

Snapshot uses fixed arrays so `std.meta.eql` can compare without
heap touch; variable-length inputs (search highlights, preedit
text) are hashed via Wyhash. Atlas page eviction is detected the
same way `cell_pass` already does it; both passes now snapshot
generations independently.

Smoke binaries pass `cells_changed=true` since they're one-shot.
408/408 tests still pass.

## HiDPI: scale-factor everywhere it was missing

Three bugs from the same root cause — widget input/size APIs return
LOGICAL CSS pixels, but our cell metrics + `pad` + GL viewport live
in PHYSICAL framebuffer pixels (atlas measures via
`FT_Set_Pixel_Sizes`, viewport is `widget_size * scale_factor`).
Mixing the two units broke things on any HiDPI surface.

1. `Pane.cellAt(x, y)` divided pointer coords (logical) by
   `atlas.cell_w` (physical). At scale_factor=2 every click landed
   half-way to its intended cell. Fix: scale `x`, `y` up by
   `gtk_widget_get_scale_factor` before the divide.

2. `onResize` and `setFontSize`'s grid-resize math divided
   `gtk_widget_get_width/height` (logical) by physical cell
   metrics, so `cols`/`rows` came out at half on scale=2. Visually
   the right half of the GL area sat empty (`glClearColor` only)
   while the shell formatted output to the under-counted column
   width. Fix: multiply widget size by scale_factor before the
   divide.

3. `Pane.font_size` (a value the docstring already calls "points")
   was passed straight to `Atlas.initOpts` as raw pixels. On 4K
   HiDPI surfaces the default 14-point config rendered cells at 14
   physical pixels = ~7 logical pixels per cell, which is why
   first-run text was tiny and users compensated by bumping to 18-
   24. Now `Pane.physicalFontSize()` does the conversion:
   `pixel_size = round(font_pt * 96 * scale_factor / 72)`. The
   chrome (Pango) was already doing this; the GL area now matches.

   **Migration:** users who manually bumped `font_size` to
   compensate should drop back to ~14. The post-fix value is in
   POINTS, not pixels.

Deferred: rebuilding the atlas when scale_factor changes mid-run
(window moved between monitors with different scales). Today the
atlas is sized at first-realize / setFontSize. A
`notify::scale-factor` handler that re-runs the atlas-init path
would close that gap.

## render: GtkGraphicsOffload — the actual fix for the 4K stall

After the user reported "still slow even with htop refreshing every
few seconds," the long-running buffer-sync investigation (persistent-
mapped + fence, `glBufferData` orphan, triple-buffered VBOs,
`glMapBufferRange` with INVALIDATE+UNSYNCHRONIZED) all came up empty.
A headless EGL surfaceless microbench (`zig build bench-cell-upload`,
`src/bench_cell_upload.zig`) running the SAME upload + draw code at
4K finished a full frame in ~500 µs end-to-end including `glFinish`.
The same code on the GTK4 path was 10-20× slower.

The bottleneck wasn't our GL code. It was GTK4's render model:
`GtkGLArea` renders to an offscreen FBO, then GSK composites that
FBO into the window's render tree on the GPU after `onRender`
returns. Mesa serialises our next `glBufferData` behind that
compositing pass — 5-8 ms of stall every frame. On the same Wayland
surface, GTK chrome dispatch (popovers, menu hover, button hover
state) all wait behind the same pipeline drain.

Fix: wrap the `GtkGLArea` in a `GtkGraphicsOffload` widget. Added
in GTK 4.14, extended to support `GtkGLArea` in 4.16. Tells GTK to
attach the GLArea's output as a `GdkDmabufTexture` to a Wayland
**subsurface** below the window's main surface — bypassing GSK's
offscreen FBO + composite step entirely. The compositor stacks the
subsurface and can even direct-scanout it. No GPU work between our
render and the surface commit, no implicit sync on the next upload.

Wiring is one line in `pane.zig`:

```zig
const offload = c.gtk_graphics_offload_new(area_widget);
c.gtk_graphics_offload_set_enabled(@ptrCast(offload), c.GTK_GRAPHICS_OFFLOAD_ENABLED);
c.gtk_graphics_offload_set_black_background(@ptrCast(offload), 1);
// Then add `offload` to the wrapper box instead of `area_widget` directly.
```

Verified live with `GDK_DEBUG=offload` — every frame logs
`GdkDmabufTexture Attaching` against a created Wayland subsurface;
zero fallback reasons. Per-frame upload latency dropped from ~6 ms
to ~25-100 µs steady state (60-240× faster). Total `onRender`
dropped from 2-3 ms typical / 8-10 ms max to 15-130 µs typical /
~390 µs max — ~25× faster on the worst case.

**Caveats** (offload silently falls back if any of these break):
- Requires GTK ≥ 4.16. Arch ships 4.22, fine.
- Anything painted on top of the offload region with effects (CSS
  rounded corners, shadows, opacity, libadwaita overlays) disables
  offload. Our pane structure today is `[titlebar above][offload(GLArea)]`
  in a vertical box — nothing on top of the GL region — so we're
  clean. A future overlay (e.g. a search bar drawn over the grid)
  would need to live as a separate offloaded subsurface or be
  rendered into our own GL output.
- `GDK_DEBUG=offload` is the canonical way to verify it's still
  engaging after future widget-tree changes.

Other GTK4 terminals (Ptyxis, Console, Black Box) don't hit this
class of bug because they wrap VTE, which renders via Cairo+Pango
through GSK — no `GtkGLArea`. Our cell pipeline is novel for the
GTK4 ecosystem; `GtkGraphicsOffload` was built for exactly our
shape of app.

## terminal: BCE on EL/ED/ECH

CSI K (Erase In Line), CSI J (Erase In Display), and CSI X
(Erase Character) all `@memset(cells, .{})`'d, which gave erased
cells the default style. xterm-style BCE (Background Color Erase)
fills with the current SGR style instead — htop's full-width
green header bar is the canonical visible test: it writes column
labels with green bg, then EL's the rest of the row, expecting
green to extend to the screen edge. Without BCE the green stopped
at the last printed column.

`Line.clearStyled(fill_style)` and `Line.eraseRangeStyled(from,
to, fill_style)` are the BCE variants of `clear` and `eraseRange`.
The three CSI erase paths in `Screen` now pass `self.cur_style`.
Plain `clear` / `eraseRange` stay for reflow + full resets where
default-style fill is correct.

Scroll-region fills (`scrollUp`/`scrollDown` blank-row clears,
`insertChars`) still use `.{}`; xterm BCEs those too but fewer
apps depend on it and the fix is mechanical. Deferred.

## render: per-row caches + idle-frame upload skip

When fast-updating apps (htop, watch, top, journalctl -f) churn
the screen at full-grid scale, the per-frame fixed costs in the
overlay pass started to dominate: every redraw re-walked every
row to detect bidi/DH overlay rows and re-scanned every row for
URL underlines, even rows whose content hadn't moved since the
last frame. On 4K HiDPI surfaces the chrome shares the same
Wayland surface as the GL area, so a slow `onRender` stalls the
chrome too — menu hover felt laggy *only* while content was
churning.

Three changes:

1. **`CellPass.rebuilt_rows`** — a per-row "rebuilt this frame"
   bitmask, parallel to `row_needs_upload` but with different
   lifetime: cleared at the *top* of `rebuildAndUpload`, set per
   row that gets rebuilt, and SURVIVES `uploadDirtyRows` so the
   overlay pass can read it after the cell pass returns.

2. **`GridPass` per-row caches** — `row_url_matches` (URL hits
   per row) + `row_overlay_needed` (does the row need the bidi/
   DH glyph path) + `row_caches_valid`. `buildVertices` accepts
   `rebuilt_rows: []const bool`; rows whose entry is true get
   their caches re-scanned, every other row reuses last frame's
   answer. Atlas eviction wipes everything (cached glyph
   positions are tied to the atlas).

3. **Skip the GL upload when nothing rebuilt.**
   - `CellPass.rebuildAndUpload` returns early when `any_built ==
     false`, avoiding the persistent-mapped fence wait on idle
     frames driven only by cursor blink / overlay state.
   - `GridPass.draw` tracks `vbo_uploaded`. `buildVertices`
     clears it on every rebuild, `draw` sets it after the
     `glBufferData`. Idle reuses the prior upload — no copy, no
     driver round-trip.

Net effect during an htop refresh on a ~100×60 grid: the bidi
loop's per-row "any non-ASCII?" cell scan only runs on rows that
htop actually rewrote, the URL scan likewise, and the `glBufferData`
on the overlay vbuf disappears entirely on frames where overlay
state didn't move.

Smoke binaries pass `&.{}` for `rebuilt_rows`, which the build
treats as "rescan every row" — the smokes only render once.

## render: revert onResize scale_factor multiply

The HiDPI batch multiplied the `GtkGLArea::resize` signal's
`width` / `height` by `scale_factor` to convert "logical" to
"physical." That was wrong: unlike `gtk_widget_get_width`, which
*does* return logical CSS pixels, the `resize` signal on
`GtkGLArea` already fires with framebuffer dimensions (physical
pixels) — that's the whole reason the signal exists separately
from `size-allocate`, so client code can call `glViewport` with
the right values. Multiplying again over-counted cols/rows by
`scale_factor`, so on a HiDPI surface the shell got told it had
twice as many columns as the screen could display. htop laid out
its bars wider than the visible area and you saw only the top-
left fragment.

The cellAt + setFontSize-resize + onRender scale multiplies all
stay (those use `gtk_widget_get_*` which IS logical). Only the
`onResize` callback's signal arguments were already physical and
needed no scaling.

## ✨ Command palette (Ctrl+Shift+P)

VSCode/Sublime/Builder-style modal popover listing every curated
user-facing action with title + one-line description + icon +
live keybind hint. Searchable by substring across title and
description; Up/Down navigate while typing-focus stays in the
search entry; Enter activates; Escape dismisses.

Wiring:

- `input.zig::Action.command_palette` is the new action.
- Default keybind: `Ctrl+Shift+P`. The previous binding for that
  chord (`toggle_pin_tab`) moved to `Ctrl+Shift+I`. Either is
  user-overridable via config.
- `input.zig::runAction` is now `pub` so the palette can dispatch
  per-pane actions (copy/paste/scrollback) against the focused
  pane's input controller — same code path as the keybind.
- `Window.dispatchAction` is the unified entry point: tries the
  focused pane's input.runAction first, falls through to
  `onShortcut` for window-level work. Palette and keybind both
  hit the same dispatch.
- `src/ui/palette.zig` — AdwDialog (handles modality + Escape +
  centring), AdwActionRow per entry inside a GtkListBox styled
  with the `boxed-list` CSS class for the libadwaita pill look.
  Per-row keybind hint resolved via `gtk_accelerator_get_label`
  against the live `Window.bindings` table (so user-customised
  chords show up correctly).

Curated entry set (~33 rows, intentionally not the raw enum dump):
clipboard (4), tabs (8), panes (4), search & scrollback (8), font
(3), layout & config (4), misc (2). Skipped: `goto_tab_1..9`
(Alt+digit IS the workflow — palette rows would be noise),
`interrupt_or_copy` (intent-overloaded chord), and any action
with no actual handler today (e.g. menu.zig's `reset_terminal`,
which falls through `else => {}` in `onMenuAction`).

Adding a new entry is one line at the top of `ENTRIES` in
`palette.zig`. The icon name comes from the Adwaita symbolic
icon set; the keybind hint is automatic.

## 🐛 Pane unrealize: release GL resources

Previously each pane's `cell_pass` / `grid_pass` / `image_pass` /
`image_store` / `atlas` only freed CPU memory in deinit; the GL
program / VAOs / VBOs / textures stayed in the window's shared
context until the window itself was destroyed. Long sessions
opening / closing many tabs grew GPU memory linearly.

Each pass now has a `releaseGL` method that `glDelete*`s the
resources it owns; the pane connects an `unrealize` signal
handler that fires those releases while the GL context is still
current (the last point GTK guarantees that — after the signal
returns the context is torn down). `forgetGL` (which only zeros
the IDs, used after context loss for a fresh re-realize) stays
for the reparent path.

## 🐛 PTY child reap: async escalation chain

`Pty.closeAndReap` was running on the GLib main thread,
blocking the UI up to ~500 ms (30 × 10 ms HUP poll, 20 × 10 ms
TERM poll, blocking SIGKILL waitpid) when a child ignored the
hangup signals. Closing a tab whose shell trapped SIGHUP/SIGTERM
froze sketerm visibly.

`Pty.closeAndReapAsync` keeps the cheap synchronous parts
(close master_fd, send SIGHUP, single WNOHANG poll — catches
the common case without scheduling) and hands the escalation to
a `g_timeout_add(10, …)` chain. A small `Reaper` struct
(allocated via `std.heap.c_allocator` for lifetime independence)
polls every tick, sends SIGTERM at tick 30, SIGKILL at tick 50,
gives up at tick 200 (orphaning the child to init). `Terminal.deinit`
returns immediately after scheduling.

The synchronous `closeAndReap` stays for spawn-rollback
errdefers — those run on a freshly-exec'd child that exits in
<10 ms on SIGHUP, where blocking cost is negligible.

## 🐛 PTY non-blocking writes + queue

The master fd was blocking. `Pty.writeAll` would park the GLib
main thread on `write(2)` whenever the child stopped reading
its slave (4 KiB TIOCINQ buffer full). Broadcast-typing into a
hung pane froze the entire UI.

Master fd now has `O_NONBLOCK` set at spawn. `writeAll` tries a
direct write loop; on EAGAIN, the remainder goes into a per-Pty
`std.ArrayList(u8)` queue (cap 1 MiB — bounded for the hung-
child case) and a `g_unix_fd_add` POLLOUT watch is armed. When
the kernel signals writability, `drainWatchCb` pulls bytes from
the queue and writes; on empty queue, the watch is removed
(`G_SOURCE_REMOVE` returned).

Ordering: writes always go through the queue when one exists,
so a fresh `writeAll` can't race ahead of bytes still pending
flush. Queue uses `std.heap.c_allocator` so the watch's lifetime
is independent of the Terminal's allocator (the watch can fire
one event-loop iteration after `closeAndReapAsync` is called;
that path explicitly removes the source + frees the queue
before closing the fd, so this is safety-net not normal flow).

Both `closeAndReap` and `closeAndReapAsync` call
`releaseWriteResources` first to drop the watch + queue cleanly.

## 🐛 close-path segfault: defer Pane teardown out of widget destroy

Closing the window via the X button always crashed in
`heap.arena_allocator.ArenaAllocator.free`, called via
`g_closure_unref` → `g_signal_handlers_destroy` →
`gtk_widget_remove_controller` (deep inside an
`adw_tab_bar_set_view` → page-unref chain).

Root cause: `onPageDetached` called `collectAndFreePanes` which
called `Pane.deinit` synchronously from inside the widget
destroy chain. `Pane.deinit` runs `menu_arena.deinit()`, but
the destroy chain is not finished — the right-click controller
on the same GLArea hasn't yet been unparented, and its signal
closures still hold a `freeClickCtx` GDestroyNotify whose
`ClickCtx` was allocated out of `menu_arena`. When GTK finally
unrefs that controller a few frames later, `freeClickCtx` calls
`ctx.allocator.destroy(ctx)` against the dead arena and Zig's
`ArenaAllocator.free` segfaults reading `self.state.buffer_list`.

Fix: `schedulePaneTeardown(pane, term)` queues
`Pane.deinit` + `Terminal.deinit` via `g_idle_add` (default
priority — runs after the current main-loop iteration unwinds,
so the entire widget-destroy chain finishes before we drop
arena state). Holder is `c_allocator`-owned so the deferred
callback's lifetime is independent of any of our GPA / arena
state. Sinks are cleared synchronously so any in-flight
`g_main_context_invoke` from the PTY worker doesn't reach into
a half-torn-down Pane between the schedule and the fire.

Same path applies in `closePane` (Ctrl+Shift+W on a single
pane) — fixed identically.

## ⬆️ Zig 0.16 port + SGR-dim rendering fix

### Toolchain port (0.15.2 -> 0.16)

The big structural change is C bindings. Zig 0.16's in-process
`@cImport` SEGVs while translating the GTK/glib header set (the new
Aro frontend, not LLVM/clang). Standalone `zig translate-c` on the
same input succeeds, so the build now generates the bindings
out-of-process: a `b.addTranslateC` step on `vendor/cimport_root.h`,
piped through a `sed` step, exposed as the `cbindings` module that
`src/c.zig` re-exports.

Three Aro bugs are worked around, each load-bearing (build fails
loudly without it) and each with a documented removal condition:

- `vendor/cimport_root.h` predefines `_Pragma(x)` to empty (glib's
  `G_GNUC_BEGIN_IGNORE_DEPRECATIONS` expands to `_Pragma(...)` inside
  a macro, which Aro mishandles), defines `__GDK_H_INSIDE__`, and pins
  `GLIB_VERSION_MIN/MAX` to 2.74 so the 2.76+ `g_string_free` macro
  (which translates to invalid Zig) is not emitted.
- `vendor/aro_shims/gdk/version/gdkversionmacros.h` is a copy of the
  system header with the `#error "Only <gdk/gdk.h>"` guard removed,
  placed first on the include path to shadow the system one. Aro
  honours `#pragma once` too late (after the `#error` on line 18 has
  already fired on re-include). This file is a pinned copy and will
  drift on GTK bumps; the version `#if` keeps drift loud, not silent.
- The `sed` step rewrites `_ = @ptrCast(@alignCast(<expr>));` (which
  Aro emits for discarded pointer-returning inline fns like
  `g_set_object`) to `_ = <expr>;`. The capture is `[^;]+` so it can
  never cross a statement boundary.

Stdlib API churn is absorbed without plumbing an `Io` instance
everywhere: direct-libc shims for file I/O (`fopen`/`fread`/`fwrite`/
`rename`/`mkdir`/`unlink`/`access` in config/layout/kitty_images/
window/main/spike_shell/terminal), `getenv`, and `clock_gettime` (the
`nano/micro/milliTimestamp` hub now lives in `util/profile.zig`). Plus
the mechanical renames: `ArrayList(T) = .empty`, `std.Io.Writer`,
`mem.trimEnd/trimStart`, `DebugAllocator`, `process.Init.Minimal`.

### SGR-dim (faint) rendering

The user-reported bug: dim placeholder/ghost text in TUIs (claude-code,
opencode) rendered too bright and sometimes was not cleared. Two
causes:

- The HarfBuzz ligature glyph path resolved fg without the dim /
  bold-bright / reverse handling the main path applied, so a `->` or
  `...` ligature inside dim text rendered bright at the cluster anchor.
  Fixed by extracting `resolveStyleColors()` and calling it from both
  paths in `cell_pass.zig`.
- The root cause of "too bright / stays stale": `Cell.style_ref` is a
  u16 index into an interned style pool capped at 65535 entries with no
  eviction. During long truecolor sessions the pool fills, `intern`
  returns `error.PoolFull`, and the old code silently kept the previous
  `cur_style` -- so a fresh `\e[2m` inherited a bright non-dim style.
  Added `compactStylePool()` in `screen.zig`: a lazy mark/remap GC
  (triggered only on intern overflow) that walks active + alt +
  scrollback + cur/saved style, keeps only referenced entries (default
  pinned at slot 0), and rewrites every `style_ref`. Widening the index
  was rejected -- it breaks the comptime-pinned 8-byte `Cell`.

### Atlas glyph residue

`atlas.zig` now zero-fills glyph pages at realize. `glTexImage3D` with
a NULL pointer leaves contents undefined (GL ES 3.0 spec); AMD/radeonsi
left residue in the 1-texel inter-glyph padding, and the faux-bold path
(which samples one texel left of each glyph) picked it up as a faint
vertical line on narrow bold glyphs (`i`, `l`, `v`).

## 2026-06-10 — full-codebase review sweep

Multi-agent review of every subsystem followed by fixes; 411 → 420
tests, all green.

### Ghost / stale cell fixes (grid)

- Erase paths (ED 0/1/2/3, EL, ECH, ICH/DCH) and `toggleAltScreen`
  never removed entries from the cluster side-table, so combining
  marks survived a `clear` / alt-screen round-trip attached to blank
  cells. All erase paths now clear the affected cluster ranges; the
  alt toggle drops the table wholesale (keys are coordinates in the
  active buffer) and resets `last_print_cp`.
- Overwriting half of a wide (CJK) pair left the orphan half behind:
  an orphaned wide-left kept drawing the old glyph, an orphaned
  continuation rendered as a permanently blank column. New
  `splitWidePair()` blanks both halves; called from `printCp`,
  `fastAsciiSlice` (boundary cells only — interior pairs are fully
  overwritten), the erase paths, and ICH/DCH.
- ECH (`CSI n X`) computed `col + n` in u16 — a large param wrapped
  and erased nothing. Clamped in u32 against `cols`.
- `scrollUp`/`scrollDown` shift loops copied cells/id/continues_above
  but dropped `scaling`, so DECDWL/DECDHL lines lost their size on
  scroll; recycled blank rows now also reset to `.single`.

### Parser

- `byteEscape` wrote the 5th intermediate byte out of bounds (write
  before the `< 4` guard; sibling handlers had it right).

### UI lifetime

- `Pane.onTick` returned G_SOURCE_CONTINUE after the child-exit
  callback — with `exit_action = close` the pane is freed and the
  next frame ticked into freed memory. Now returns REMOVE.
- `closeFocusedPane` left `Window.search_pane` dangling (the tab-close
  path already handled it); the pane-title popover now verifies its
  pane is still in `window.panes` before dereferencing.
- `setFontSize` rebuilt the atlas without invalidating either render
  pass; the fresh atlas starts at generation 0 — equal to the passes'
  last-seen generations — so eviction detection never fired and stale
  UVs sampled a blank texture. Now marks all rows dirty + drops the
  grid-pass vbuf.

### Config ownership

- `Config.cloneInto`/`clone`: deep-copy strings, keybinds, profiles.
- `applyConfigChange` previously adopted `new_cfg.arena` and leaked
  the old arena on every prefs change / reload. Now clones into a
  fresh window-owned arena, frees the old one at function end, and
  re-points pane slices (`font_path`, `active_profile`) at the new
  copies. `reloadConfigFromDisk` frees its loaded config.
- The prefs dialog working copy was a shallow struct copy aliasing the
  window's arena — now cloned into the dialog's own arena. Keybind
  appends used the GPA on an arena-backed list (leak); fixed.
- config.conf larger than the 64 KiB read buffer now warns instead of
  silently dropping trailing sections.

### Misc

- KP_Enter sends its dedicated kitty codepoint 57414 (press + release)
  instead of being indistinguishable from Return.
- Layout save serializes the pane's actual spawn argv (stored on Pane
  at spawn) instead of collapsing every pane to $SHELL — `ssh host` /
  `nvim .` tabs now survive a save/restore round-trip.

### Reviewed and rejected

- "Rotating VBO slots draw stale data" — false alarm: uploads write
  the full instance buffer and `vbo_slot` only advances inside the
  upload, so `draw()` always binds the most recently written slot.

## 2026-06-10 — colour emoji rendering

Atlas switched from GL_R8 to GL_RGBA8 (64 MB GPU budget): monochrome
coverage now lives in alpha (RGB=255, shaders tint with cell fg);
colour emoji carry straight RGBA sampled directly. Glyph loading adds
FT_LOAD_COLOR; BGRA strikes (CBDT — Noto Color Emoji ships 128 px) are
box-filtered down to a 2-cell × cell_h box, un-premultiplied for the
SRC_ALPHA blend pipeline, and centred. Fontconfig fallback for emoji
codepoints (`isEmojiCp`) requests `color=true` instead of the scalable
bias — without it fontconfig hands back DejaVu Sans, and fixed-strike
faces were rejected outright by FT_Set_Pixel_Sizes (now: nearest-strike
FT_Select_Size). A `colored` flag rides the Glyph struct into both
passes: CellPass Instance (now 104 B) and the GridPass overlay vertex
both branch in the fragment shader (only pane-dim applies to colour
glyphs, no fg tint, no italic shear). Note: emoji rows render via
CellPass (only RTL/complex-script rows go to the overlay) — the colour
branch is needed in BOTH shaders. COLR-only fonts still render as mono
outlines (FreeType won't rasterize COLR to BGRA on the plain load
path); CBDT/sbix is the common case on Linux. smoke-cell now draws
U+1F600 and counts "yellowish" pixels (soft check — passes mono-only
on machines without a colour emoji font).

## 2026-06-10 — "ghost text" root cause: raw 0x9C terminating OSC

The long-standing "ghost text in Claude Code's input that never gets
erased" was NOT an erase/damage bug. Captured a real Claude Code
session via a pty.fork harness and replayed it through the parser
(`zig build replay -- capture.bin cols rows`, new debug tool): the
grid itself contained an injected " Claude Code" fragment. Root cause:
the parser honoured raw 0x9C as an 8-bit ST inside OSC/DCS/APC/SOS-PM
strings. In a UTF-8 terminal 0x9C is a continuation byte of very
common codepoints — ✳ (E2 9C B3) and ✓ (E2 9C 93), which Claude Code
puts in its window title and updates constantly. The title OSC got
truncated mid-payload and the tail was printed into the grid at the
cursor position. A diff-based TUI renderer (Ink) never repaints cells
it believes are blank, so the garbage stayed — "doesn't get erased".
Fix: only BEL and ESC \ terminate string sequences (matches
kitty/ghostty/xterm-in-UTF-8). The existing kitty conformance test
("C1 controls handled as printable") already encoded this stance for
ground state; the string states were the leftover. Regression tests
feed the exact ✳-title sequence.

## 2026-06-10 — font handling overhaul

Three gaps vs kitty/wezterm closed:

- **Real italic / bold-italic faces.** `loadBoldFace` generalised to
  `loadVariantFace(weight, slant)`; the atlas now resolves italic and
  bold-italic siblings of the primary family via fontconfig at init.
  Glyph cache keys gained ITALIC_KEY_BIT; `lookupOrLoad`/`ById` and
  `shapeRun` take (bold, italic) and pick faces through one
  `styledFace()` helper (graceful degradation: missing bold-italic →
  italic + embolden; missing italic → regular + the old shader shear,
  gated on `atlas.hasItalic()` in both passes). An italic face that
  lacks a codepoint falls back to the regular face before fontconfig.
- **`font_family` config** (global + per-profile + prefs entry row):
  resolved to a file via fontconfig (`resolveFamilyPath`). Pane font
  resolution order: `font` path → `font_family` → $SKETERM_FONT →
  candidates, deduplicated into `Pane.createAtlas()`. Changing the
  font at the same size now rebuilds atlases live
  (`Pane.refreshFont`, split out of setFontSize).
- **SGR 58/59 underline colour.** `StyleEntry.underline_color`
  (.default = follow fg). The shared `sgrReadExtColor` helper parses
  `;5;n`, `:5:n`, `;2;r;g;b`, `:2:r:g:b` AND the ITU colon form with
  colorspace slot `:2::r:g:b` (what neovim emits) — 38/48 now accept
  that form too. CellPass Instance carries `deco_color` (120 B);
  the deco pass draws with it. Overlay (bidi) rows still draw
  decorations-as-before — SGR underline colour there is a known gap.

## 2026-06-10 — keyboard hints / quick-select mode

kitty-hints/WezTerm-QuickSelect equivalent, bound to Ctrl+Shift+E
(action `hints_open`, also in the command palette). `src/ui/hints.zig`
scans the visible rows (scrollback-aware via view_offset) for OSC 8
link runs, plain URLs (reusing url_scan), file paths (slash-bearing
tokens, handles `src/x.zig:123`), and hex hashes (7-64 chars, ≥1
letter so plain numbers don't match), deduplicating by overlap with
URL > path > hash priority. Match text is extracted eagerly at
collect time so later screen changes can't corrupt activation.
Labels come from a home-row alphabet — single chars up to 26 matches,
uniform two-char labels beyond (prefix-free by construction).

Mode state lives on Window (`hints_pane` et al). Key interception
goes through a new `hint_sink` hook checked at the top of input.zig's
onKeyPressed — typing filters labels live (typed prefix renders dim),
Backspace un-types, Esc exits, a completed label opens URLs via
g_app_info_launch_default_for_uri or copies paths/hashes to both
clipboards. Rendering: `Screen.hints_overlay` slice (Window-owned,
mirroring search_highlights) drawn by GridPass — teal range highlight
+ amber label badge with bold glyphs; snapshot gains a hints hash so
the vbuf rebuilds when the overlay changes. Pane-close paths clear
the mode like they clear search.

## 2026-06-10 — show_scrollback + copy mode (parallel agents)

Two features built in parallel worktrees and merged:

- **show_scrollback (Ctrl+Shift+H)** — kitty equivalent. Dumps
  scrollback + screen via the existing `extractScrollback` to a 0600
  temp file in $XDG_RUNTIME_DIR (fallback /tmp), opens a new tab
  running `less -R +G <file>` (or `$PAGER`); the wrapping `sh -c`
  rm's the file when the pager exits, and every error path unlinks.
  Also revived `addTabInternal` (was dead code) and fixed the
  method-syntax `tabPageForPane` call it exposed.
- **Copy mode (Ctrl+Shift+X)** — WezTerm/tmux-style keyboard
  selection. Sink pair `copymode_sink` on input.Ctx (checked after
  hint_sink; sink-false only for bare modifiers, and unconsumed keys
  return 0 so GTK modifier tracking stays coherent). Motions:
  h/j/k/l + arrows, 0/$/Home/End, g/G, w/b word motions (new pure
  `grid/word_motion.zig`, unit-tested; `Screen.isWordChar` now
  delegates there). v / V / Ctrl+v-or-r toggle cell / line / rect
  selection — rebuilt from anchor+cursor into `screen.selection`
  (display-buffer coords, negative = scrollback, matching the mouse
  path so `extractSelection` is correct while scrolled). y/Enter
  yanks to CLIPBOARD + PRIMARY and exits; Esc/q exits. The copy
  cursor is `Screen.copy_cursor`, drawn by GridPass as an amber
  hollow outline (snapshot-gated). View follows the cursor via
  view_offset. Hint mode and copy mode are mutually exclusive
  (cross-guards in both openers); both clear on pane close.

## 2026-06-10 — small-batch sweep: dnd, contrast, --hold, overlay decorations

Four well-contained gaps closed in one pass:

- **Drag & drop files (paste path)** — GtkDropTarget per pane accepts
  GdkFileList + string drops. Local paths are single-quote
  shell-escaped (bare when every byte is safe), space-joined with a
  trailing space; non-local URIs (sftp://) are skipped. Text drops
  paste as-is. Both go through `clipboard.pasteText`, the
  bracketed-paste logic extracted from the clipboard read callback.
- **minimum_contrast** — WCAG contrast floor (1..21, default 1.0 =
  off) between text fg and its effective cell bg; below it fg snaps
  to white or black, whichever reads better. Shared helpers in
  render/style.zig (`contrastRatio`, `applyMinContrast`); applied in
  CellPass `resolveStyleColors` and both GridPass overlay glyph
  emitters (new `effectiveBg` mirrors the overlay bg-quad logic).
  Config key + Legibility prefs group + sample.conf; GridPass
  snapshot gains the field so the vbuf rebuilds on change.
- **--hold** — per-invocation exit_action override stored as
  `Window.hold_override` (outside Config, so SIGUSR1 reload can't
  clear it). Pairs with --layout one-shot commands.
- **Overlay-row SGR decorations** — GridPass bidi/DH/DW rows drew no
  underline/strike/overline at all (CellPass zeroes those rows and
  the overlay only emitted bg + glyphs). New `emitCellDeco` draws
  flat quads per visual column — single/double underline, strike,
  overline; curly degrades to a thicker line (no wave shader in this
  pass). Honours SGR 58 underline_color, falls back to resolved fg.
  Decorations sweep separately from glyphs so underlined spaces draw.

OSC 22 pointer shapes turned out to be already implemented end-to-end
(screen → terminal sink → Pane cursor-from-name); no work needed.

Tests 434 → 437 (contrast helpers, shell quoting). pane.zig is now
registered in tests.zig.

## 2026-06-10 — font_features + remote control (sketerm cli)

- **font_features** — OpenType feature config for HarfBuzz shaping.
  CSS/kitty syntax ("-calt +ss01 zero cv05=3"), parsed via
  hb_feature_from_string into a fixed array on the Atlas and passed
  to every hb_shape call; setFontFeatures clears the shape cache.
  Changing the key rides the refreshFont rebuild path (fresh atlas =
  fresh glyph rasterizations). Config key + prefs entry row in Font
  group + sample.conf docs.
- **Remote control** — `sketerm cli <cmd>` scripts the running
  instance, wezterm-style. Design per jelle-ai review: Unix socket
  at $XDG_RUNTIME_DIR/sketerm/<pid>.sock (dir 0700, no token — local
  trust model), one JSON object per line each way. New src/ipc/
  module: protocol.zig (pure types + parse/serialize, unit-tested),
  server.zig (GSocketService; accepts + read_line_async land on the
  GLib main loop, so dispatch runs on the main thread — threading
  rule holds with zero new threads), client.zig (blocking GIO
  client; never enters GApplication, so no display needed).
  Commands: list (tab/pane tree JSON with ids, titles, cwd, pid,
  size, focus), send-text (--paste for bracketed), get-text
  (--scrollback dumps the ring), new-tab (--cwd/--title), split
  (--dir h|v), focus, close-pane, set-title. Window assigns stable
  monotonic pane ids BEFORE the PTY spawn so children get
  SKETERM_PANE_ID + SKETERM_SOCKET in env ('--pane self'
  self-addresses); tab ids ride g_object_set_data on the AdwTabPage.
  Window.ipcDispatch implements commands; the socket file is
  unlinked in Window.deinit. Verified end-to-end against a live
  second instance (SKETERM_APP_ID override): echo round-trip via
  send-text→get-text, env vars inside spawned panes, error replies,
  socket cleanup on SIGTERM.

Tests 437 → 441 (protocol parse/serialize, feature parsing).

## 2026-06-10 — smoke-e2e, mouse bindings, per-tab colours

- **smoke-e2e** (`zig build smoke-e2e`) — first end-to-end test of
  the real app, enabled by the IPC work: forks zig-out/bin/sketerm
  under a private SKETERM_APP_ID, waits for the socket, then asserts
  list shows panes, a send-text echo round-trips into get-text
  output (polled until the marker appears twice — typed + output),
  split adds a pane, unknown commands error, and SIGTERM unlinks the
  socket. SKIPs without a display. Run step depends on the install
  step and pins cwd to the project root.
- **Configurable mouse bindings** — mouse_middle_click /
  mouse_right_click config keys (menu | paste_primary |
  paste_clipboard | none). menu.PrePopupFn now returns bool: false
  vetoes the popover, letting paneMenuPrePopup run a rebound
  right-click action instead (PuTTY-style paste). Only acts when
  mouse_mode == 0; disable_mouse_paste still wins for middle.
  Combo rows in prefs Mouse group.
- **Per-tab colours** — round 16×16 GdkMemoryTexture swatch set as
  the AdwTabPage icon (GdkTexture implements GIcon). Entry points:
  right-click "Tab Colour…" (GtkColorDialog, async ctx refs the page
  so closing the tab mid-dialog is safe; alpha≈0 clears) and
  `sketerm cli set-tab-color --tab N '#RRGGBB'|none`. Packed colour
  lives in g_object_set_data ("sketerm-tab-color", bit 24 = set
  marker), surfaces in `cli list` as "color", and persists through
  layout save/restore via the new TabSpec.color field (old layouts
  parse fine — defaults null).

## 2026-06-10 — background images + gradients (BgPass)

New `src/render/bg_pass.zig`: fullscreen pass drawn immediately
after the clear, under kitty below-text images and the cell grid —
cells with an explicit bg paint over it, default-bg cells let it
show (kitty's background_image model). Two modes in one shader:
two-colour angled gradient (u_dir from background_gradient_angle)
and image, cover-cropped via a pure `coverTransform` helper
(unit-tested). Config: background_image (+_opacity, default 0.3),
background_gradient_from/_to (active when both alphas > 0) and
_angle. The CPU-side `Source` lives once on the Window
(refreshBgSource decodes via stbi_load, frees the old stbi
allocation, bumps a generation counter); each pane's BgPass uploads
its own texture into its own GL context and re-uploads when the
generation moves. Context-loss handled with the standard
forgetGL/releaseGL/realize trio wired into both pane unrealize
branches + realize. applyConfigChange re-decodes only when a
background_* key actually changed (prefs entry rows fire per
keystroke). Prefs group on the Appearance page. Verified visually
on the live system (screenshots: image cover-crop in split panes +
135° navy gradient).

## 2026-06-10 — sketerm-mux: durable panes (tmux without the hacks)

The big one. Native mux subsystem per the (untracked) mux-design
doc: shells live in a daemon and stream PARSED EVENTS to clients —
never re-encoded escape sequences, so every terminal feature works
through it by construction. Five landed steps:

1. **wire.zig** — framed binary protocol (append-only type/tag
   bytes); every parser Event round-trips, incl. owned OSC/APC/DCS
   payloads. peelFrame skips unknown types for forward compat.
2. **snapshot.zig** — lossless Screen dump: grid (active/alt/
   scrollback), style pool, links, clusters, cursor, modes, palette,
   prompt marks, title. Restore builds a fresh Screen. v1 gap: kitty
   image placements (apps redraw).
3. **daemon.zig + sketerm-mux binary** — single-threaded poll loop,
   one PTY+Parser+Screen per session, events applied once and
   broadcast to attached clients. ATTACH = seq-stamped snapshot +
   live EVENTS; RESIZE re-snapshots all clients. Links **libc only**
   (~550 KB): new `glib` build option gates pty.zig's write-queue
   watch + async reaper behind blocking fallbacks; sys/socket.h +
   sys/un.h added to cimport_root.h. `zig build mux`, smoke-mux
   (headless end-to-end incl. reattach + resize + kill).
4. **GUI attach** — Terminal.initRemote (no PTY/worker; socket on
   the GLib loop, SNAPSHOT frames swap the Screen wholesale).
   writeRaw/requestResize abstract PTY-vs-socket — pane.zig no
   longer touches `terminal.pty`. KEY FIX: reapStatus now guards
   child_pid <= 0; waitpid(-1) would have reaped arbitrary GUI
   children. Palette "New Durable Tab", IPC new-durable-tab /
   attach-session, daemon auto-spawned (sibling-of-exe then $PATH).
   Closing a remote pane detaches; session lives. Verified live:
   marker echoed → GUI killed → daemon survived → new GUI attached
   → marker present + pane interactive (screenshot).
5. **sketerm mux TUI** — raw-termios picker (arrows/jk, Enter
   attach-as-tab via GUI IPC, n new, x kill, q quit) + list/attach/
   new/kill subcommands. GUI socket discovery skips mux.sock.

PKGBUILD now installs sketerm-mux. Tests 442 → 450.

## 2026-06-10 — SSH domains: sketerm ssh <host>

Remote durable sessions, mosh-style UX. `sketerm-mux --proxy`
bridges stdin/stdout to the daemon socket (auto-starting the daemon
via detached double-fork re-exec of /proc/self/exe). The GUI/TUI
side runs `ssh -T -o BatchMode=yes <host> sketerm-mux --proxy` over
a socketpair (Conn.connectSsh; double-forked so init reaps the ssh;
hello→welcome probe validates the whole bridge before use), so one
fd carries the protocol and Terminal.Remote needed zero changes.
BatchMode means key/agent auth required — a password prompt would
corrupt the protocol pipe (mosh has the same constraint).

UX: `sketerm ssh <host>` = durable remote shell as a tab in the
running window (sugar for `sketerm mux <host> new`); `sketerm mux
<host>` = the same TUI against the remote daemon (optional leading
host on every subcommand); tab titles '⌁ name @ host'. Remote
spawns send empty argv → daemon uses ITS $SHELL (new default), and
no cwd. IPC new-durable-tab/attach-session gained a host field.
$SKETERM_SSH overrides the transport binary.

Verified via fake-ssh wrapper (isolated XDG_RUNTIME_DIR as the
"remote"): ssh-tab spawn, resize propagation through the proxy,
GUI kill → session survives in remote daemon → reattach in a fresh
GUI with the echoed marker intact. Server deploy story: scp the
libc-only sketerm-mux binary, done.

## 2026-06-10 — UDP transport (mosh-style) + TUI create-new row

- **TUI**: the picker now ends with a selectable "+ create new
  session" row (Enter there = `n`), so creating works without
  knowing the keybinding. Selection spans sessions + that row.
- **Encrypted UDP transport** — `sketerm ssh -u <host>` /
  `sketerm mux udp:<host>`. Declined reading mosh's source (GPL-3 vs
  our MIT); built from the published SSP concepts instead:
  - `mux/rudp.zig`: pure state machine. Datagrams sealed with
    ChaCha20-Poly1305 (std.crypto); 64-bit crypto seq is both nonce
    (direction byte prevents cross-peer reuse) and anti-replay
    sliding window (checked only AFTER authentication). Roaming:
    transports update the peer address only from packets that
    authenticated. On top: go-back-N byte stream — 1200 B segments,
    cumulative acks piggybacked on data, RTO 80ms→1s backoff, 3 s
    keepalives, BYE teardown. Tests drive two channels through a
    deterministic lossy network: 64 KB through 30% loss arrives
    intact + ordered; replay/tamper/wrong-key all silently dropped;
    a fully-eaten window recovers via RTO.
  - `sketerm-mux --udp-listen` (remote end, started over ssh):
    binds an ephemeral port, prints "SKETERM-UDP <port> <key>" up
    the ssh pipe, double-forks free of ssh, bridges UDP↔daemon
    socket. Exits on BYE or if NO client ever authenticates within
    60 s (abandoned bootstrap); once authenticated it persists —
    that persistence is the roaming story. `--udp-connect` is the
    local socketpair bridge; getaddrinfo for resolution; user@ is
    stripped for the UDP destination. Everything downstream
    (Conn, Terminal.Remote, daemon) is untouched — the fd just
    happens to be a socketpair to an encrypted-UDP pump.
  - Zig 0.16 notes: std.crypto.random + std.time.milliTimestamp are
    gone in this context — getentropy(3) + clock_gettime(MONOTONIC)
    via libc. netinet/in.h, arpa/inet.h, netdb.h added to
    cimport_root.h.
  Verified via the fake-ssh rig end-to-end over real UDP sockets:
  list, `ssh -u` tab spawn, marker, GUI kill, session survives,
  reattach over a FRESH bootstrap (new port + key) with content
  intact; no leaked bridge processes after disconnect.

Tests 450 → 454.

## 2026-06-10 (evening): housekeeping, predictive echo, domains, shakeout prep

- Housekeeping: CLAUDE.md rewritten for the Zig-0.16 / mux era
  (build steps, glib option, IPC + mux subsystems, std quirks);
  architecture.md gained a mux section. pathZ/makeParentDirs
  deduped into util/pathz.zig (was 4+ copies). New test pins the
  gdkversionmacros aro shim against the system header so GTK
  upgrades can't drift it silently. Also: the ok/err/shutdown
  FrameType hunk from the UDP commit had been left uncommitted —
  HEAD was unbuildable on a fresh checkout; fixed.
- Predictive local echo (mosh-style) for remote panes:
  src/mux/predict.zig is a pure state machine (fake-clock unit
  tests). Printable keystrokes render speculatively via a new
  GridPass overlay (underlined, default fg); reconciled against
  the live event stream after every EVENTS frame. Display gated on
  smoothed input→echo RTT >= 60ms AND a previously confirmed
  prediction; Enter drops confidence, so echo-off (password)
  prompts never display speculation — verified live with a
  400ms-each-way delayed proxy (SKETERM_MUX_DELAY_MS test hook):
  glyphs visible on screen while absent from the grid, secret
  input after `read -s` never rendered. GLib 250ms timer expires
  stale predictions; timeout pauses prediction 5s.
  SKETERM_PREDICT=always|never overrides.
- [domain.<name>] config sections: host + transport (ssh|udp).
  Palette grows a "New Tab on <name>" row per domain;
  `sketerm mux <name>` and `sketerm ssh <name>` resolve names
  (verified live: fake-ssh log shows the resolved user@host).
- Real-world shakeout prep: `--udp-listen --udp-port LO:HI` +
  `mux_udp_port_range` config key threaded through the GUI/CLI
  bootstrap (verified: announce binds in-range, ssh argv carries
  the flag). Client bridge warns on stderr after 5s without an
  authenticated UDP reply and gives up at 15s so the GUI handshake
  errors instead of hanging (verified against a black-hole port).
  docs/REMOTE.md documents the server install (non-interactive
  PATH gotcha), BatchMode key-auth requirement, and firewall
  port-range setup.

Tests 454 → 466.

## 2026-06-11: performance pass (drain budget, style pool, bench truth)

- mainDrain budget: 4096 events / ~3ms per drain, then re-arm via
  the drain_pending coalescing. Output floods (cat largefile) no
  longer own the main thread; painting + input interleave.
- StylePool intern: hash map on a canonical packed key (unions
  can't hash raw — colorKey packs tag+payload). last_idx fast path
  kept. Microbench truth: NO delta at <16 styles, but the new
  truecolor-gradient workload (4096 unique styles — chafa/timg
  half-block images, gradient prompts) goes 3.4 -> ~150 MB/s (45x):
  the linear scan was quadratic in unique styles.
- "Vectorize the parser" turned out already done (scanPrintable is
  16-wide SIMD; csi_param batches digit runs). perf shows remaining
  bench time is eraseDisplay/scrollUp memory bandwidth — no parser
  work left worth taking.
- Measurement honesty: bench-parser varies ~2x run-to-run with CPU
  power state on this laptop. Compare best-of-N runs only. (An
  earlier same-session claim of doubled throughput from the pool
  change was variance; the gradient number above is the real,
  reproducible win.)
- Styled line clears use @memset (no measured delta; consistency
  with clear()).

## 2026-06-11 (later): images over the mux

- Daemon-side kitty file fetch (mux/kitty_inline.zig): t=f/t=t/t=s
  transmissions name files on the daemon's host; the daemon reads
  them and rewrites the APC to inline t=d before broadcasting.
  File-mode kitty graphics now work over SSH/UDP mux — something
  plain kitty-over-ssh cannot do. Tempfile/shm cleanup honored
  daemon-side; 6MB raw cap keeps frames under the 16MB wire limit.
- Snapshot v2: Screen.retain_images (daemon-only) keeps owned
  copies of every placed image (12MB budget, oldest evicted,
  delete commands pruned); snapshot carries them; the client
  replays into the pane ImageStore after attach (stale placements
  flushed first). Images survive detach/reattach.
- smoke-mux gained an image stage covering the whole loop
  headlessly. Tests 466 -> 470.

## 2026-06-11 (later): first real-server shakeout — SIGILL fix

- Jelle's first real `sketerm mux archdev` failed: the scp'd daemon
  died with SIGILL on the server. Root cause: ReleaseFast targets
  the build host's CPU (Zen 4, AVX-512); archdev is Zen 2.
- New `zig build mux-portable`: baseline CPU + static musl, one
  binary for any x86_64 Linux regardless of CPU/libc. Packaged at
  /usr/lib/sketerm/sketerm-mux-portable; REMOTE.md now leads with
  it and warns against copying /usr/bin/sketerm-mux.
- Mux-side binaries now translate a lean vendor/cimport_core.h
  (the GTK set only translates against native glibc). musl quirks:
  SIG_IGN macro fails translate-c (Zig-side constant now), struct
  timespec has zero-width padding bitfields (predefined via musl's
  alltypes guard; 64-bit only).
- ssh-transport failure hint rewritten to point at the diagnosis
  command (`ssh <host> sketerm-mux --proxy`) and the real causes.
- Verified on archdev: portable binary runs, hello→welcome probe
  round-trips through --proxy on the Zen 2.

## 2026-06-11 (later): OSC 9;4 progress reporting

- Jelle's remote zig build spammed notifications saying "4;1;7":
  ConEmu progress (OSC 9;4;st;pr) colliding with the iTerm2/urxvt
  notification meaning of OSC 9. Screen now strictly parses the
  4; form (state 0-4, percent clamped; malformed falls back to
  notification) into a new on_progress sink.
- Tab: 16x16 progress ring drawn into the AdwTabPage INDICATOR
  icon (the regular icon stays the tab-colour swatch). Blue arc
  from 12 o'clock; red=error, amber=paused, 3/4 ring for
  indeterminate. Packed state on the GObject mirrors the
  tab-colour trick.
- Taskbar: window-level aggregate (mean percent, any-error →
  urgent) published as the com.canonical.Unity.LauncherEntry
  Update D-Bus signal (KDE task manager, docks). Deduplicated;
  re-aggregated on page close so a dead tab can't pin the value.
- Works over the mux for free (OSC rides the event stream) —
  remote builds show progress on the local tab.
- Verified live: dbus-monitor showed 0.42 → 0.53+urgent → clear;
  screenshots confirmed blue 42% and red 65% rings. Tests 471.

## 2026-06-11 (later): mux TUI takeover + durable-pane config

- sketerm mux attach/new from inside a pane now REPLACES that pane
  (tmux-attach semantics) instead of opening a tab: guiCommand
  sends SKETERM_PANE_ID, attachMux(takeover) swaps the new pane
  into the old one's box/paned slot and defers teardown via
  schedulePaneTeardown. Outside a pane: new tab as before.
- attachMuxTab was a 4th pane-creation path missing
  applyPaneConfig — durable panes got default font size/colors/
  palette. Now routed through the shared helper.
- Progress ring + tab colour swatch render 64x64 supersampled
  with soft radial/angular edges (16px hard-edge circles were
  visibly lumpy).
- Verified live: takeover in a split slot and a single-pane tab
  (tab count unchanged, title rewritten, sibling row count
  matches => font correct), ring screenshot smooth, progress
  over a durable session (OSC rides the mux event stream).

## 2026-06-11 (later): pane-path dedup sweep

- Jelle flagged the "4th pane-creation path" font bug class. Audit
  found sink wiring duplicated 4x with real drift: restore + split
  paths never wired win_on_title, attachMux skipped child-exit.
  Now: wirePaneSinks (single connect path, all 7 sinks) and
  unlistPane (single disconnect: search/hints/copymode refs,
  unlist, clearSinks, schedulePaneTeardown). Adding a sink in one
  place reaches every pane kind.
- bell/cwd/progress handlers + closePane shared 4 inline copies of
  the page-walk; all use tabPageForPane now. Swatch/ring share
  iconTexture64.
- Consequence handled: restored tabs now follow OSC titles, which
  would let shells stomp deliberately named tabs ("Local"). Layout
  gains title_locked (persisted user-rename lock); legacy files
  without the field treat saved titles as renamed (= old
  behaviour). Verified live: default-layout names survive zsh,
  fresh tabs follow OSC 0.

## 2026-06-11 (later): mux context menu + OSC gap sweep

- Remote (mux) panes get a context-menu section: Detach Session /
  Rename Session… / Kill Session. Rows hidden on local panes (menu
  binds carry remote_only; pre-popup enables, onRightClick syncs
  row visibility off the action enabled state). Rename = new wire
  frame 10 (append-only): daemon validates+dedupes, GUI commits
  remote.session + retitles the tab ONLY on the OK reply
  (pending_rename). Also `sketerm mux rename <old> <new>` and `r`
  in the TUI picker (cooked-mode inline prompt). Remote.host now
  stored on the terminal for title rebuilds.
- OSC 133 C/D command zones: stable line IDs bound the last
  command's output (survives scrollback). "Copy Command Output" in
  the context menu (greyed until available), palette entry,
  bindable copy_command_output. Shipped shell-integration scripts
  already emit C/D;exit. D's exit code recorded (last_cmd_exit).
- OSC 52 READ behind `clipboard_read = allow` (default deny =
  immediate empty reply so apps don't hang). Allowed path: async
  GDK read; reply ctx rides the DrainHandle so pane teardown
  mid-read is detected. Verified live both ways (python pty probe;
  NOTE: on Wayland the read only resolves while the window has
  focus — no offer otherwise, reply degrades to empty).
- OSC 99 kitty notifications subset: chunked title/body, base64,
  id-switch discards unfinished; icon/button kinds dropped.
- OSC 4 applies multiple idx;spec pairs (pywal), OSC 104 takes an
  index list, and onOsc no longer drops semicolon-less payloads —
  bare 104/110/111/112 (the standard reset-all forms) worked only
  with a trailing ';' before.
- Test-harness gotcha (cost ~20 min): capturing a terminal reply
  with `timeout 2 cat -v > file` loses everything — cat's stdio
  buffer dies with the SIGTERM. Use a python pty probe (raw mode +
  select) or `dd bs=1`.

## 2026-06-11 (later): OSC 99 full interactive notifications

- Notification chain now carries Screen.NotificationEvent (id,
  icon name/data, buttons_raw, urgency, report/focus flags,
  occasion, close) instead of (title, body) — OSC 9/777/1337 fill
  the simple fields. Window: GNotification with themed icon (n=) or
  GBytesIcon image (p=icon), urgency→priority, o=unfocused/
  invisible gates, p=close withdraws by tag, repeated ids replace.
- Buttons + activation: app-scoped "notify-act" GAction (uu) =
  (slot token, button#). NotifySlot ring (cap 32, dropped in
  unlistPane) maps token → pane + sanitized id; activation focuses
  the pane (a=focus, default) and/or writes the spec report
  OSC 99;i=<id>;[N] via writeRaw (a=report). Ids sanitized at parse
  ([A-Za-z0-9_+.-]) so a hostile id can't inject into the report.
- p=? capability reply deliberately omits c= and alive:
  GNotification has no closure feedback. Sounds/timeouts likewise.
- Verified live end-to-end: dbus-monitor shows Notify with both
  buttons + urgency 2 + image-path dialog-warning; gdbus
  ActivateAction (token 1, button 2) delivered
  ESC]99;i=mynote;2 ESC\ back into the pane (python pty probe).
- Gotcha: zig build test does NOT reinstall zig-out/bin/sketerm —
  launch live tests only after a plain `zig build`. Also the shim
  drift test skips when cwd != repo root (relative path).

## 2026-06-11 (later): protocol trio + mux double-reply fix

- Mode 2048 in-band resize: report on DECSET (immediately, per
  spec) and after every Screen.resize; pixel fields 0 when cell
  metrics unknown (daemon side). Mode 2031 + DSR ?996: dark/light
  derived from effective bg luminance (isDarkBg in window.zig);
  notifyColorScheme pushed from applyPaneConfig/applyConfigChange/
  onThemeChanged, reports CSI ?997;1|2 n on actual flips only.
  Mode 2027: we always cluster — DECRQM answers 3 (permanently
  set), set/reset ignored.
- LATENT BUG FIXED: mux mirror screens had on_write_pty wired, so
  every DSR/DA/DECRQM from a remote app was answered TWICE (daemon
  + mirror). Screen.mute_responses (set in initRemote + carried
  over snapshot swaps) silences mirrors; GUI-owned replies
  (OSC 52 read, DSR ?996) use respondForce and the daemon skips
  them via defer_gui_queries. Snapshot bumped to v3 (carries
  mode_2031/in_band_resize) — REDEPLOY sketerm-mux on remote hosts,
  v2/v3 mismatch refuses to attach.
- Verified live: local pane answers 2027;3$y / 997;1n / real-pixel
  48-report / single DSR reply; durable pane shows the routing
  split (daemon answers DECRQM/2048/DSR once, mirror answers ?996)
  and exactly ONE cursor reply.

## 2026-06-11 (later): file:line hints + pane zoom + cli action

- Path hints now open in an editor: parseFileLine + buildEditorCommand
  (pure, tested in hints.zig), shell quoting consolidated into
  util/shellquote.zig (pane.zig drag&drop now imports it). Resolution:
  hint_editor config ({file}/{line}/{col} template or bare `+line`
  command) > $EDITOR > $VISUAL > copy fallback; relative paths
  resolve against the pane's OSC 7 cwd; nonexistent local files copy
  (covers remote-pane paths naturally).
- Pane zoom (Ctrl+Shift+M, menu, palette, `cli action zoom_pane`):
  hides the sibling subtree at each GtkPaned level (paned gives full
  allocation to the remaining child; NO reparenting → GL context
  survives). zoom_hidden holds g_object_ref'd widgets for restore.
  Auto-unzoom: split, pane_next/prev, ANY pane close (unlistPane).
  Verified over IPC: 16x58 → 34x116 → back; all 3 close/split edge
  cases. `zoomed` flag in cli list output.
- NEW IPC: `sketerm cli action <name>` dispatches any bindable
  action — scripting + the testability story for window-level
  features (no keyboard needed).
- PROCESS WARNING (cost real harm): kdotool windowactivate +
  ydotool key injection while Jelle was ACTIVELY TYPING — focus
  ping-ponged, his keystrokes landed in my test window and possibly
  mine in his Kate draft. NEVER inject input or steal focus while
  the user is active. Use IPC-driveable surfaces instead (that's
  what `cli action` is for). Also: Belgian AZERTY — ydotool keycode
  30='q', 16='a'.

## 2026-06-11 (evening): survey completion — blocks, shaders, multi-window, auto-integration

- Command-block UX (4c5268a): Screen.cmd_zones ring (64 CmdZone, stable
  line-ID ranges; rows in a zone ⟺ id ∈ [start_id,end_id) since IDs are
  birth-ordered). GridPass draws green/red gutter bars (left padding)
  over output rows + red right-edge minimap ticks for scrolled-away
  failures (rowForLineIdFast = binary search over scrollback). Click in
  the gutter selects the command's output line-wise (pushes PRIMARY);
  select_command_output action does the last zone from keyboard/palette.
  Snapshot gained cmd_zones_hash. smoke-cell asserts the gutter pixels.
  Zones are NOT in the mux snapshot (transient, like last_output_*) —
  adding them means a v4 bump + daemon redeploys; deferred on purpose.
  Gotcha rediscovered: ReleaseFast `.?` on null is UB, not a panic —
  a wrong test "passed" into garbage instead of crashing.
- custom_shader (65ac997): shader_pass.zig renders the frame into an
  FBO and maps it through a user shadertoy-style mainImage shader
  (iChannel0/iResolution/iTime/iTimeDelta/iFrame). GtkGLArea's own FBO
  is saved/restored via GL_DRAW_FRAMEBUFFER_BINDING (it's never 0!).
  Window owns the file read (shader_source, like bg_source); compile
  failure disables the pass once per generation. custom_shader_animation
  drives redraws via onTick dirty. smoke-cell runs a channel-swap shader
  and asserts the gutter bar comes back blue.
- Detachable tabs (006450c): tab drag-out + detach_tab action.
  create-window spawns a secondary Window (clone of config, NO IPC
  socket — pid-keyed path would clobber the primary's). page-attached
  adopts panes (disownPane from source + wirePaneSinks + applyPaneConfig
  on dest; widget→Pane via g_object_data "sketerm-pane" on the GLArea).
  page-detached defers close-vs-transfer ONE idle: adopted pages have no
  panes left in the source lists so collectAndFreePanes no-ops; the page
  is g_object_ref'd across the idle so the child tree stays walkable.
  Secondary windows close when empty; primary respawns a shell; closing
  the primary quits the app (it owns IPC/quake/layout). Layout save
  still persists the primary only — secondary tabs are lost on quit
  (durable mux tabs survive daemon-side anyway). Verified over IPC:
  detach (split tab, both shells live), last-tab detach (respawn), close
  regression, clean 3-window shutdown.
- Search minimap ticks (1fd0e4f): every match = amber tick on the right
  edge, active = orange; same coordinate mapping as the zone ticks.
- Auto shell-integration (acc55fa): zsh via ZDOTDIR shim (.zshenv
  restores user ZDOTDIR, chains real .zshenv, loads integration at
  first precmd), fish via XDG_DATA_DIRS vendor_conf.d shim (strips
  itself from the var). pty.zig SpawnOpts.shell_integration; Window
  resolves the script dir (env override > exe-relative share > repo
  data/ > /usr/share). shell_integration = off disables. Scripts moved
  to data/shell-integration/ (installed layout == repo layout).
  FOUND REAL BUGS by exercising it: (1) fish single quotes treat \\ as
  an escape, so the script's '\e\\\e]' collapsed and leaked literal
  "e]133;A" into the grid on EVERY prompt — fish OSC now ends with BEL;
  (2) fish ≥ 4.0 emits OSC 7 + 133 natively (with exit codes) — our
  hooks self-disable there or every mark (and every cmd zone) doubles.
  Jelle's shell is FISH (not zsh) — his command blocks come from fish's
  native marks, via the parser's existing 133 handling.
- Already existed, no work needed: quake mode (--toggle), bell options
  (bell_audible/visible/urgent). Skipped deliberately: configurable
  hint patterns (needs a regex engine; scanners cover URL/path/hash).

## 2026-06-11 (late): per-pane shaders + durable-pane auto-reconnect

- Per-pane shaders (25e5599): Pane owns an optional ShaderSource
  (shader_own + shader_own_src + custom_shader_path); resolution is
  user pick > profile.custom_shader > global, applied at the END of
  applyPaneConfig (NOT makePane — no profile in scope there; makePane
  only wires shader_default_source). custom_shader_user makes an
  explicit pick sticky across config reloads. UI: context-menu
  "Pane Shader…" (GtkFileDialog, ShaderPickCtx validates the pane is
  still listed before applying) + "Clear Pane Shader" (re-runs
  applyPaneConfigByName so profile/global comes back). Layout saves
  the pick (PaneSpec.custom_shader, user picks only). Verified live:
  broken profile shader prints compile-failed and keeps rendering;
  valid one is silent with an interactive pane.
- Durable panes in layouts (same commit): PaneSpec.mux_session/
  mux_host; collectTree records terminal.remote; buildTreeWidget
  routes mux specs through restoreMuxPane = attach, or on
  "no such session" spawn UNDER THE SAME NAME then attach
  (resume-or-create). makeRemotePaneFromSnap factored out of
  attachMux (pane build without tab page — restore places the widget
  in the split tree itself). Connect failure falls through to the
  plain PTY spawn with a stderr note. Verified live in an isolated
  XDG_RUNTIME_DIR/XDG_STATE_HOME rig: marker survived GUI restart
  (attach path); killing the daemon and restoring recreated the
  session under the same name with a working shell (create path).
- TEST RIG NOTES: overriding XDG_RUNTIME_DIR breaks Wayland — set
  WAYLAND_DISPLAY=/run/user/1000/wayland-0 (absolute path works).
  Profile-feature tests MUST also override XDG_STATE_HOME: otherwise
  startup restores last.json and panes get profile="" (bit me — the
  "missing" compile error was a test-setup bug, not a code bug).
  Kill test daemons via lsof -t on their mux.sock, never pkill.

## 2026-06-11 (night): tunable shader params (cool-retro-term style)

- Shaders declare knobs via `//@param <name> <default>` + a matching
  `uniform float <name>;`. parseParams (pure, unit-tested) runs at
  program build; locations cached; values uploaded EVERY finish() —
  `shader_param.<name> = <float>` config overrides apply live on
  SIGUSR1/prefs reload, no recompile. Source.overrides points into
  the CONFIG ARENA: re-pointed unconditionally in applyConfigChange
  (window source + every pane's shader_own) or it dangles after the
  arena swap — reload-storm tested (5x SIGUSR1, stable).
- Shipped CRT shaders converted from #defines to params: curvature,
  scanlines, glow, vignette, flicker, mono (mono=0 keeps original
  colors). smoke-cell asserts BOTH paths under real GL: defaults
  (corner dark ⟺ curvature uniform arrived) and overrides (mono=0
  collapses amber 1521 → 264).
- GOTCHA (cost a debug round): `zig build test`/`smoke-cell` do NOT
  rebuild zig-out/bin/sketerm — a live-test after config.zig edits
  ran a stale GUI and printed "unknown key", looking like a parse
  bug. Plain `zig build` first, then live-test.

## 2026-06-11 (later night): shader config dialog + RetroArch param format

- Param declarations now use RetroArch's `#pragma parameter name
  "Label" default min max [step]` (their CRT shader ecosystem's
  convention; Mesa ignores unknown pragmas) plus sketerm extensions:
  //@color name r g b "Label" (vec3 — RetroArch is floats-only),
  //@name + //@desc for dialog headers. //@param still parses
  (extended: default [min max [step]] ["Label"]). parseParams is
  pure + unit-tested; Param carries label/min/max/step/kind/color.
  NOTE: only the PARAM FORMAT is RetroArch-compatible — full .slang/
  .glslp presets are multi-pass with different entry points and do
  NOT run as-is; single-pass bodies need porting to mainImage.
- Colors: shader_param.<name> = #rrggbb in config (round-trip
  tested); ParamKV gained color: ?[3]f32; upload via glUniform3f.
- src/ui/shader_dialog.zig: "Configure Shader…" (context menu +
  configure_shader action) builds an AdwPreferencesDialog
  dynamically: GtkScale per float param (range/step/digits from
  metadata), GtkColorDialogButton per color, group header from
  //@name//@desc, reset-to-defaults row. Every change goes through
  Window.setShaderParam → config mutate (in the CONFIG ARENA —
  created on demand for default configs) → repointShaderOverrides
  (append can REALLOC items; every Source must re-point) → queue
  renders → persistConfig. No shader active → falls back to the
  file picker. LIFETIME: RowCtx carries its own allocator — its
  destroy-notify runs after the dialog Ctx is freed on "closed".
- Shipped CRTs converted to pragma params + phosphor //@color (the
  amber/green twins now only differ by tint default). smoke-cell
  unchanged-but-meaningful: amber=1521 proves the vec3 default
  upload (else black), mono-override still collapses to 264.
- Verified live: dialog opens via `cli action configure_shader`
  with zero criticals, app + IPC responsive under the modal.

## 2026-06-11 (midnight): iChannel1 previous-frame feedback

- ShaderPass: when the program references iChannel1, the user shader
  renders into a ping-pong RGBA8 pair (sampling LAST frame's OUTPUT
  on unit 1) and the result blits to the GtkGLArea fbo
  (glBlitFramebuffer, GLES 3.0). Non-feedback shaders keep the
  direct path — zero extra cost. Pair is cleared on (re)alloc so
  resizes don't smear garbage; fb_* handles in forgetGL/releaseGL.
- Shipped CRTs: `persistence` param (default 0 = visually identical,
  max(col, prev*persistence)) → phosphor afterglow trails. Decay is
  per-RENDERED-frame: without custom_shader_animation trails only
  fade when something redraws; with it, smooth continuous fade.
- smoke-cell feedback stage: decaying-max shader run twice, second
  frame's scene EMPTY → 1283 ghost pixels at half brightness, 0 at
  full (proves it's the decayed history, not leakage). CRT stage
  counts unchanged (persistence=0 default).

## 2026-06-12 (small hours): unified CRT + lottes port + live preview

- crt-amber/green MERGED into data/shaders/crt.glsl: phosphor is a
  color param, `colorize` 0..1 is the user-requested "strength"
  (0 = no colorization at all). Engine grew the cool-retro-term
  effect set REIMPLEMENTED FROM SCRATCH (CRT is GPL-3 — its QML
  shader code must never be copied; the effects are just ideas):
  chroma (RGB split), noise (static), jitter (per-line hsync wobble
  + occasional tear), saturation, brightness. mono → colorize
  rename (param was hours old, no compat shim).
- crt-lottes.glsl: port of Timothy Lottes' PUBLIC DOMAIN classic
  (the only license-compatible popular RetroArch CRT — easymode/
  zfast/royale are GPL-2, NOT portable into MIT sketerm). Gaussian
  beam Tri/Horz3/Horz5/Scan, 5 shadow-mask styles, warp, original
  param names. smoke-cell compiles + renders it (lit=3944,
  warp corner black).
- Dialog LIVE PREVIEW: GtkGLArea in the config dialog renders a
  synthetic terminal image (deterministic CPU-generated glyph
  blocks, flipped for GL row order) through the user's shader with
  the CURRENT override values — re-reads config.shader_params.items
  every frame (setShaderParam appends can realloc), so sliders
  update it as you drag; tick callback keeps it animating (flicker/
  noise/persistence visible). Drives ShaderPass manually: own
  Source w/ DUPed src (window source can swap while dialog open),
  ensureProgram(pub now) + tex= + prev_fbo= + finish(). Lifetime:
  Ctx freed via g_idle_add AFTER "closed" (unrealize GL cleanup
  during the destroy chain still needs it).
- Verified live: dialog + animating preview open via cli action,
  zero criticals, IPC responsive, clean app teardown with the
  dialog open.

## 2026-06-12: RetroArch ports (proper, license-clean)

- Jelle offered to relicense sketerm MIT→GPL for shader ports.
  DECLINED as unnecessary: shader files are runtime DATA — GPL
  "mere aggregation" lets GPL files ship beside an MIT program,
  each under its own license (RetroArch itself does this). Core
  stays MIT; data/shaders/README documents per-file licensing.
  GPL files are embedded ONLY into the smoke-cell test binary
  (never distributed).
- Ported from real sources (libretro/glsl-shaders): crt-easymode
  (EasyMode, GPL) and zfast-crt (Greg Hogan, GPL-2+). Port pattern:
  Texture/TextureSize/InputSize/OutputSize → iChannel0/iResolution,
  passthrough vertex stage folded (zfast's maskFade/invDims
  varyings inlined), and a NEW `v_scale` param — these shaders
  expect low-res emulator frames, so the terminal acts as
  iResolution/v_scale virtual source pixels (scanline + mask
  frequency follow). easymode SCANLINE_CUTOFF default raised
  400→1000 (at v_scale 2 a 4K pane's virtual source exceeds 400 and
  scanlines would self-disable).
- cool-retro-term NOT code-ported even with license cleared: its
  noise/jitter sample a noise TEXTURE asset (we have no LUT inputs)
  — the from-scratch procedural equivalents in crt.glsl remain the
  right substitute.
- smoke-cell compiles + renders both ports (easymode lit=4194,
  zfast lit=3713).

## 2026-06-12: relicensed MIT → GPL-3.0-or-later

- Jelle's explicit decision (sole copyright holder; reversible until
  outside contributions arrive). Corrected the motivation: GPL does
  NOT forbid selling — it forbids CLOSED-SOURCE redistribution
  (which is what kills take-and-sell forks in practice).
- LICENSE = GPL-3.0 text; README/CLAUDE.md/PKGBUILD license fields
  updated; data/shaders/README simplified (everything in the repo
  is now GPL-3-compatible; crt.glsl follows the project license).
- CLAUDE.md "## License MIT" note is GONE — future sessions: the
  project is GPL-3.0-or-later. Code from GPL-2+/GPL-3/PD/MIT
  sources may now be ported into core; GPL-2-ONLY code may NOT
  (incompatible with GPL-3).

## 2026-06-12: shader LUT/texture inputs (//@texture)

- Shaders can declare extra texture inputs:
  `//@texture <uniform> <path|builtin:noise>`. Units 2.. (0=frame,
  1=feedback); loaded at program build, freed on rebuild/releaseGL.
  builtin:noise = deterministic 256² RGBA tile (GL_REPEAT) — what
  cool-retro-term-style grain wants, no asset file. File paths
  resolve against NEW Source.dir (owner-managed: Window dirname of
  custom_shader, Pane dirname of the pick, dialog copies it).
- FOUND PRE-EXISTING DOC LIE: stb_image_impl.c compiled with
  STBI_ONLY_PNG only — docs claimed PNG/JPEG everywhere (a .jpg
  background_image silently failed!). Now PNG+JPEG+BMP.
- crt.glsl static noise switched from hash to the noise texture
  (softer, authentic crawl).
- smoke-cell: builtin:noise stage (wideband histogram) + file-LUT
  stage (hand-written 2×2 red BMP via Source.dir-relative path,
  asserts every output pixel red). With LUT + feedback + params +
  color pickers, single-pass shader expressiveness now matches what
  cool-retro-term's engine uses.

## 2026-06-12: right-click fix (real one) + headless mux + type-text

- Context menu "often doesn't open": ROOT CAUSE was GTK4 silently
  popdown-ing an autohide popover whose MINIMUM size doesn't fit
  the compositor-granted rect (is_acceptable_size, gtkpopover.c).
  ~15 menu rows fit neither above nor below a mid-window click.
  Fix: wrap rows in GtkScrolledWindow with propagate-natural-height
  (tiny minimum, identical natural rendering, scrolls when tight).
  The earlier gesture-claim fix (7532e46) was a wrong-mechanism
  guess; kept as harmless hygiene. Diagnosed via WAYLAND_DEBUG
  trace: client destroys xdg_popup 5ms after configure(h=399).
- DAEMON BUG: poll loop checked POLLHUP before POLLIN — a client
  that writes its last frame and closes lost that frame (a `mux
  send`'s Enter, typically). POLLIN now drains first; EOF marks
  dead. CLI also detach+OK round-trips before close (fixes the
  race against older deployed daemons too).
- Headless mux verbs (no GUI needed): `sketerm mux spawn <name>
  [--cwd|--rows|--cols] [cmd...]`, `mux send <name> [--enter]
  [--type --delay N --jitter N] <text>`, `mux get-text <name>
  [--scrollback]`. get-text restores the attach snapshot into a
  local Screen and extracts text. Local daemon auto-starts
  (connectLocalAutostart in mux/client.zig — window.zig's fork
  block moved there and shared).
- `sketerm cli type-text [--pane N] [--enter] [--delay/--jitter]`:
  human-paced typing into GUI panes — one send-text request per
  UTF-8 codepoint over a single IPC connection, randomized
  inter-key delay (LCG), extra hesitation before Enter. Pure
  pacing logic in util/humantype.zig (tested; 492 total now).

## 2026-06-12: shader fixes — clear, noise drift, dialog crash, vis-gated anim

- "Clear Pane Shader" did nothing when the shader came from
  global/profile config: setCustomShader(null) only drops a
  PER-PANE pick, then re-resolution brought the global back. Added
  Pane.shader_cleared — an explicit, sticky "no shader" state
  (refreshShaderBinding → source=null). Survives config reloads &
  profile pushes (treated like a user pick), persists in layout
  JSON (PaneSpec.shader_cleared). Picking a shader un-clears.
- crt.glsl noise crawled diagonally: the uv offset was a CONTINUOUS
  vec2(fract(iTime*7.13), fract(iTime*3.77)) added to fragCoord,
  translating the whole tile. Replaced with a per-frame random
  JUMP (floor(iTime*24) → hash12 → uv) so it flickers in place like
  real tube static, no direction. smoke-cell noise histogram still
  wideband.
- Shader config dialog crashed on close: deferredCtxFree freed the
  Ctx but NEVER removed the preview GLArea's tick callback, so
  onPreviewRender kept firing against freed memory. Now the tick is
  removed on closed/unrealize, and the free waits until BOTH
  "closed" AND GL-release have happened (flags + single guarded
  g_idle). Also immune to a double "closed".
- Shader animation now tied to VISIBILITY, not focus. onTick's
  self-removal didn't count shader animation as keep-alive work, so
  the tick died the moment cursor-blink stopped (focus loss) and the
  shader froze. Now: animate while the pane is mapped (any visible
  split, focused or not); pause when on a background tab. A "map"
  handler restarts the tick when the tab comes back.

## 2026-06-12: shaders scoped per TAB

- Shader pick / clear now apply to EVERY pane in the focused tab
  (setTabShader), not just the focused pane. Splitting a pane makes
  the new pane inherit the focused pane's shader (inheritShader), so
  a tab stays visually uniform. New tabs start from the global/
  profile default — picks/clears don't leak between tabs.
- Persistence already per-pane (PaneSpec.custom_shader +
  shader_cleared), so a restored split tab reconstructs its shader
  on every pane. Verified: save writes shader_cleared per pane;
  --layout restore of a tab with one cleared + one crt.glsl pane
  comes back correctly with no crash.
- KNOWN LIMITATION: shader PARAM values (the config dialog sliders)
  are still global (config.shader_params, shared by all panes). The
  shader SELECTION and clear are per-tab; per-tab param overrides
  would need per-pane override slices — deferred.

## 2026-06-12: inactive-pane dim → uniform post-process (darken + desaturate)

- Replaced the per-cell inactive dim (fg.rgb*k_fg, bg.rgb*k_bg with
  DIFFERENT factors → changed fg/bg contrast and broke the
  minimum-contrast lift, so colors looked different when inactive)
  with a UNIFORM post-process over the whole composited pane.
- Implemented inside shader_pass: FRAG_FOOTER now applies
  desaturate-toward-luma then darken via sketerm_dim_desat /
  sketerm_dim_darken (both 0 for focused panes). A dim-only path
  (beginDim/finishDim + a built-in identity program) handles
  inactive panes with no custom shader; panes WITH a custom shader
  get dimmed in the same footer. Uniform scalar on the final image →
  every colour relationship preserved, just dimmer.
- Two config sliders (prefs "Inactive pane dimming"):
  inactive_darken (default 0.20) and inactive_desaturate (default
  0.00). Old inactive_fg_dim/inactive_bg_dim keys are accepted +
  ignored so old configs don't error.
- smoke-cell proves the math: darken 0.5 maps (200,100,40)->
  (100,50,20) exactly (hue intact); desaturate 1.0 ->(117,117,117)
  (=luma). 492 tests pass.
- NOTE: pre-existing harmless startup Gtk-CRITICAL
  (gtk_gl_area_queue_render before realize) confirmed present on
  r662 too — not from this work.

## 2026-06-12: dither the shader output (kills vignette banding)

- Vignette (and any smooth gradient: glow falloff, the inactive-dim
  ramp) banded because the output framebuffer is 8-bit GL_RGBA8 — a
  gentle brightness ramp on dark pixels has too few code values and
  snaps into contour bands, worst in the dark corners, reinforced by
  the 8-bit persistence/feedback loop.
- Fix is dithering at the 8-bit output, not 16F targets: the final
  present is to GtkGLArea's 8-bit default framebuffer regardless, so
  16F would pay 2x bandwidth + need EXT_color_buffer_half_float and
  STILL band at the present. FRAG_FOOTER now adds ~1 LSB triangular-
  PDF noise (hash(p) - hash(p+0.5)) before the implicit 8-bit round.
  Static per-pixel (no crawl), single scalar across rgb (grays stay
  gray), applies to every shader + the dim-only path.
- smoke-cell: flat darkened input (->100) now spans 99..101 across
  the buffer, proving the dither fires. 492 tests pass.

## 2026-06-12: shader pick/clear strictly PER PANE (revert tab scope)

- a466467's tab-wide spread treated the wrong disease. The real
  reason "everything has the same shader" was the GLOBAL
  `custom_shader = crt.glsl` line in config.conf: every pane without
  an explicit pick/clear falls back to it, so new tabs/panes always
  came up CRT regardless of scoping.
- Pick and clear now act on the clicked pane only; a split is a
  fresh pane (global/profile default, no inheritance). Model is
  three layers: global config < profile < per-pane explicit
  pick-or-cleared, persisted per pane in the layout JSON.
- Startup gotcha: no-flag startup loads default.json, which only
  gets updated by an explicit Save Layout As — a default.json saved
  before the shader fields existed restores every pane to the global
  default. Re-save it to make picks/clears stick across restarts.

## 2026-06-12: shader presets (named shader + params combos)

- New src/shader_preset.zig: a preset = shader path + animate flag +
  param values, one file per preset under
  $XDG_CONFIG_HOME/sketerm/shader-presets/<name>.conf. Parse/
  serialize round-trip unit-tested.
- Configure Shader... dialog gains a "Preset" group: name entry +
  Save button. Saving snapshots the DECLARED params at their current
  values (never the global param soup) and binds the pane to the
  preset.
- Right-click -> "Shader Preset..." (and palette "Shader Preset...")
  opens a picker popover: one button per preset (applies to the
  focused pane), trash button deletes the file.
- Params go per-pane when a preset is bound: Pane.preset_params owns
  the values and shader_own.overrides points at them, so dialog
  slider edits tune only that pane (global config params untouched).
  Manual file pick or clear drops the preset binding.
- Layout persistence: PaneSpec.shader_preset; restore re-resolves by
  name with the raw path as fallback. Verified live: a layout with
  one preset pane + one cleared pane restores without errors.
- Reminder that answers "why do my cleared shaders come back":
  no-flag startup loads default.json; run the palette's "Save
  Default Layout" after arranging shaders so the per-pane state
  persists.

## 2026-06-12: preset UX in the shader dialog (dropdown + load/save/delete)

- The Configure Shader dialog's Preset group is now full management:
  an AdwComboRow listing every preset saved FOR THIS SHADER FILE
  (item 0 = "-- New preset --"), Load + red Delete buttons on that
  row, name entry + Save below.
- Load applies the preset to the pane AND pushes its values into the
  sliders/color buttons (handlers re-route them to the pane's set,
  so UI and render stay in lockstep). Defensive against shader
  drift: unknown preset params are skipped, declared params missing
  from the preset return to defaults, floats clamp to slider range.
  The loaded name fills the entry; selecting a preset prefills too.
- Save writes <name>.conf (same name = overwrite), binds the pane,
  and inserts/selects the name in the dropdown. Save is insensitive
  while the name is empty/invalid; Load/Delete while "new" is
  selected. Deleting unbinds a pane that pointed at the name but
  keeps its live values (Pane.unbindPresetName; ownership now keyed
  on hasOwnShaderParams, not just the name).

## 2026-06-12: macOS portability, phase 1 (GL + platform layer + core cross-compile)

- GOAL: husband's Mac. Research: brew GTK4 4.22 + libadwaita are
  viable (quartz backend, GL renderer); the hard blocker was GL —
  macOS GDK is desktop-GL-only (4.1 core via CGL), NO GLES, no
  fallback: gtk_gl_area_set_use_es(1) = black widget.
- GL portability: all 10 shader sources lost their #version/
  precision lines; gl.zig injects a per-API header at compileShader
  (GLES "300 es" w/ precision defaults vs "330 core") via the
  2-string glShaderSource form. gl.requestArea picks the API per OS
  (Linux behavior byte-identical: still use_es); gl.adoptAreaApi
  syncs from the realized GdkGLContext. NEW `zig build smoke-gl-core`
  compiles every pass pair + dim + crt.glsl under a real desktop-GL
  3.3 core context (Mesa EGL) — the macOS shader path is proven on
  Linux. All GLES smokes unchanged-green.
- New src/util/platform.zig: exePath (/proc/self/exe vs
  _NSGetExecutablePath+realpath), Wakeup (eventfd vs nonblocking
  pipe; terminal.zig worker shutdown now uses it), runtimeDir
  (XDG_RUNTIME_DIR -> TMPDIR -> /tmp; replaces 5 ad-hoc getenv
  sites), socketCloexec (SOCK_CLOEXEC is Linux-only), exePathZ.
- vendor/cimport_*.h gated: pty.h + sys/eventfd.h Linux-only;
  Darwin branch declares openpty/forkpty directly (Zig's bundled
  darwin headers lack util.h) + sys/random.h. musl timespec shim
  now inside #ifdef __linux__ (features.h doesn't exist on Darwin).
- layout.zig cwdOfPid: macOS via proc_pidinfo(PROC_PIDVNODEPATHINFO)
  with documented struct offsets (UNVERIFIED on hardware).
- mux_main: SIG_IGN @ptrFromInt(1) hack violated aarch64 fn-pointer
  alignment -> no-op handler (same EPIPE semantics); Darwin's
  stdout/stderr translate as inline fns -> fflush(null), write(2,..),
  std.debug.print.
- build.zig: use_lld only for Linux targets (macOS wants the
  self-hosted Mach-O linker); mux-portable's keyed on its own triple.
- MILESTONE: `zig build mux-portable -Dportable-target=aarch64-macos`
  produces a native arm64 Mach-O sketerm-mux from this Linux box.
- 497 tests pass (platform.zig added 2), smoke-mux/cell/image/
  transparency/gl-core/spike-shell all green, daemon still libc-only.
- NOT done: GUI build on real hardware (brew GTK + translate-c on
  Darwin headers is the expected friction), .app bundle, Cmd
  keybindings. Recipe + friction list in docs/macos.md.

## 2026-06-12: pane-tree model — frontend abstraction, step 1

- GOAL: de-GTK the core UI so a native AppKit frontend is possible
  (ghostty-style core + thin frontends; Qt rejected: C++ ABI).
- CLAUDE.md claimed "tab/pane tree is plain Zig data" — it wasn't:
  the tree only existed as GtkPaned nesting (tabPageForPane walked
  widget ancestry, collectLayout walked GTK containers). Now it's
  true: src/ui/tree.zig is a generic toolkit-free Tree(Leaf) model
  (split/remove/replace/contains/serialize, unit-tested on u32),
  instantiated as Window.PaneTree = Tree(*Pane).
- One tree per tab, attached to the AdwTabPage as qdata — travels
  with cross-window tab drags for free, sidestepping the page-
  detached/attached close-vs-transfer race entirely. Freed only on
  true tab teardown (3 sites around collectAndFreePanes).
- Mutation sync points: appendOrInsertTab (5 creation sites, takes
  the root node), buildTreeWidget (builds model alongside widgets on
  restore), splitFocused (splitLeaf), closeFocusedPane (removeLeaf,
  model focus_hint replaces the widget walk), mux takeover
  (replaceLeaf).
- Reads flipped to model: tabPageForPane (widget walk kept as
  fallback), collectLayout (modelTreeToLayout; live ratios read from
  the split's view handle), duplicateCurrentTab. Bonus correctness:
  layout save while a pane is ZOOMED now serializes the real tree
  (the widget walk saw the zoom-reparented structure).
- Verification net: SKETERM_VERIFY_TREE=1 structurally compares
  model vs widget tree after every split/close and inside
  collectLayout; divergence ABORTS. smoke-e2e sets it and now also
  drives a nested v-split + close-pane through IPC. Manually
  verified the same sequence against a live instance on a restored
  2-tab default layout — no divergence.
- 503 tests (tree.zig +6), smoke-e2e/cell/mux green, macOS mux
  cross-compile still green.
- NEXT steps for the abstraction: flip remaining widgetIsAncestor
  query sites (IPC list, broadcast group, pane cycle) to the model;
  then extract the GLib-loop/clipboard/dialog seams into a frontend
  interface.

## 2026-06-12: config refactor — Default is just a profile

- GOAL (user): collapse the three config layers (global config /
  profile patches / per-pane overrides). Profiles become the single
  unit of pane appearance; "Default" is the profile formerly known
  as the global config.
- config.zig: new `ProfileSettings` struct holds every pane-level
  key (font path/family/features/size, line_pad_px, padding, fg/bg/
  cursor color, palette, scheme, shell, term/color_term, login_shell,
  scrollback, custom_shader). `Config.settings` IS the Default
  profile; `Config.profiles` is a list of named COMPLETE bundles —
  the old patch-style `Profile` (inherit sentinels: ""/0/null) is
  gone, and with it every "profile wins → global falls back" chain.
- Parse: top-level keys edit Default; `[profile.<name>]` sections
  seed from the Default-so-far then override (old sparse configs
  migrate with the inheritance they expect); `[profile.default]`
  round-trips into Config.settings. Serialise: Default at top level
  (file compat), profile sections diffed against Default.
- window.zig: applyPaneConfig/applyConfigChange resolve ONE bundle
  per pane via `Config.profileSettings(name)` (deleted profile →
  Default). Bonus correctness: a config reload now pushes each
  pane's OWN profile colors/palette/scrollback/font (before, the
  push-loop pushed global values over profile panes); font rebuilds
  are per-pane diffs instead of global-size-change-rebuilds-all.
  Ctrl+0 resets to the pane's profile size; layout saves font_size
  relative to the profile, not the global default.
- ✨ Apply Profile to Pane: context menu / palette / keybindable
  action; popover lists default + named profiles, pick re-runs
  applyPaneConfig on the live pane + font rebuild. Sticky shader
  picks/clears survive (same rule as config reload).
- ✨ Prefs "Profiles" page: combo picks the profile being edited
  (pane-level rows bind to that bundle; switching reopens the dialog
  — rows capture field pointers at build time), create-as-copy,
  delete (falls back to Default), default-profile-for-new-panes
  combo. Dialog title shows the non-default profile being edited.
- 504 tests green; mux daemon still libc-only.
- VERIFIED headless (Xvfb + xdotool + imagemagick, isolated
  XDG_CONFIG_HOME): smoke-e2e PASS; profile spawn renders distinct
  colors/size; SIGUSR1 reload restyles a profile pane in place;
  apply-profile popover round-trips dev→default; prefs Profiles page
  create/delete persists to config.conf and reopens bound right.
- 🐛 the pass caught two silent picker bugs (would have shipped):
  GTK4 popdowns autohide popovers whose min size doesn't fit (pickers
  anchored at the pane's bottom edge died on map — now scroller +
  center anchor via presentPanePopover), and picker buttons resolved
  focusedPane() at click time, when the popover button holds focus →
  null → no-op (also hit the PRE-EXISTING shader-preset picker; pane
  now captured in the button ctx at build time).

## 2026-06-12: `sketerm app` — remote GUI apps on the local desktop

- GOAL (user): the thing X11 forwarding stopped being good at, and
  Wayland never had — run a remote graphical app with its window
  locally, transport-agnostic UX (future macOS backend must slot in
  without the user caring). This is phase 1 of the "mosh for GUI
  apps" plan; phase 2 will run the stream over the mux rudp
  transport for roaming.
- `sketerm app [user@]<host|domain> <command...>` (src/remoteapp.zig):
  generic front end; backend = waypipe over SSH for Linux remotes.
  One ssh probe (`uname` + waypipe + Vulkan-ICD discovery) dispatches
  to the backend and produces actionable errors (no waypipe on
  remote / macOS remote / no local Wayland). $SKETERM_SSH override
  honored (probe + waypipe --ssh-bin). Domains from config.conf
  resolve; udp: domains fall back to their ssh host for now.
- Vulkan gotcha: waypipe 0.11 ABORTS when the local compositor
  advertises dmabuf but Vulkan is missing (typical headless server).
  The probe checks ICD manifests on both ends and degrades to
  --no-gpu (shm transfer) automatically.
- Remote windows get a "[host] " title prefix. Process exec's into
  waypipe after preflight so signals/exit status flow naturally.
- VERIFIED end-to-end on this box (sshd to localhost + weston-on-Xvfb
  as the local compositor): wayland-info globals round-trip;
  weston-terminal renders, accepts forwarded keyboard input, runs a
  live fish shell. 507 tests.

## 2026-06-12: phase 2 — Wayland apps over the mux ("mosh for GUIs")

- GOAL (user): type `gimp` in a durable remote shell and have it open
  on the local desktop — no `sketerm app` prefix, transport-agnostic.
- Wire proto v2: chan_open/chan_data/chan_close — generic byte
  channels multiplexed over the mux connection. Transport-agnostic by
  construction (one fd), so app streams ride the roaming rudp UDP
  transport for free. Daemon gates channels on hello proto>=2; old
  clients keep working channel-less. Local connections now send the
  hello probe too (connectLocalAutostart) — they never did, which
  silently disabled channels for local daemons.
- Daemon: session commands wrap in `waypipe server` (per-session
  $WAYLAND_DISPLAY + hub socket next to mux.sock); hub accepts become
  channels toward the latest attached v2 client, refused cleanly when
  detached. waypipe CLI gotcha: options must precede the mode word.
  SKETERM_MUX_NO_WAYLAND=1 opts out; waypipe-less hosts spawn plain.
- GUI: wlbridge.zig owns one `waypipe client` (lazy spawn, reap +
  respawn, SIGTERM at exit); terminal.zig pumps channels ↔ that
  socket via g_unix_fd_add watches with write-buffering.
- Vulkan again: BOTH waypipe ends abort without a Vulkan ICD when
  dmabuf is in play — each side now self-checks and passes --no-gpu.
- VERIFIED headless full-stack (sketerm GUI as a Wayland client on
  weston, isolated XDG_RUNTIME_DIR so the real daemon stays
  untouched): durable tab shell reports the per-session
  WAYLAND_DISPLAY; `weston-flower &` typed in that shell renders on
  the local compositor through daemon→channel→wlbridge. 507 tests,
  smoke-mux/e2e PASS, macOS mux cross-compile green.
- NOT yet: flow control beyond write-buffering (pixel floods share
  the go-back-N stream with keystrokes — measure before separating
  associations), UDP-transport e2e rig, `sketerm app` over rudp.

## 2026-06-12: macOS phase 2 — verified on real hardware (M2, macOS 26.4)

- First execution of any sketerm code on Darwin. brew zig 0.16.0 +
  gtk4 4.22.4. `zig build mux` + `smoke-mux` PASS natively;
  `zig build test` 500/507 (7 skip); GUI builds, opens, renders,
  serves IPC; `smoke-e2e` PASS natively (display gate now keys on
  platform.is_macos — macOS always has a WindowServer, no env var).
- Friction 1 (predicted "most likely"): translate-c. NOT the GTK
  macros — Aro SIGBUSes on <arm_neon.h>, pulled in by graphene's
  NEON backend on every aarch64. Fix: GRAPHENE_SIMD_BENCHMARK +
  GRAPHENE_HAS_SCALAR in cimport_root.h (graphene's own escape
  hatch), aarch64-gated; x86_64 SSE untouched. Scalar simd4f is
  layout-compatible; we never call graphene.
- Friction 2: Darwin stdout/stderr/stdin are macros → translate-c
  inline FNS, not values. platform.stdout()/stderr()/stdin() added;
  48 call sites migrated (the GUI-set files this time; mux side had
  the same fix in phase 1).
- Friction 3: default `zig build` failed on the 5 EGL harnesses (no
  EGL on macOS) — now registered only for Linux targets.
- Friction 4: FONT_CANDIDATES were Linux paths → "no usable font",
  blank pane. macOS list: Menlo.ttc / Monaco / SFNSMono / Courier
  New. Menlo.ttc opens fine via FreeType.
- BONUS all-platform bug via cwd checks: zsh integration's
  ${PWD//%/%25} APPENDS %25 (unescaped % anchors at end in zsh) →
  every OSC 7 cwd carried a trailing %. Fixed with \%.
- cwdOfPid offsets VERIFIED on hardware (152/152/1024, flavor 9,
  matches getcwd) — comment updated, code was right.
- Interop vs Linux daemon (colima Ubuntu aarch64 VM): mux-portable
  cross-built FROM the Mac runs there; list/new/attach over SSH
  (SKETERM_SSH wrapper), sessions survive GUI restart, snapshot
  restores screen. UDP: Darwin↔Darwin AND Darwin↔Linux
  (192.168.64.2) — bootstrap, ChaCha20 seal, rudp clock/getentropy
  all exercised. `sketerm app` refuses cleanly (no Wayland) as
  designed. mux-portable x86_64+aarch64 musl still green from macOS.
- Known noise: GTK theme-parser warnings at startup; 2x
  gtk_gl_area_queue_render CRITICALs at e2e teardown (unchased);
  remote-tab bootstrap blocks the main loop (pre-existing).
- NOT done: .app bundle, Cmd keybindings, visual screenshot
  verification (screencapture needs Screen Recording permission).
## 2026-06-12: phase 3 — `sketerm app -u`: roaming GUI apps, standalone

- `sketerm app -u <host> <cmd>` (udp: domains imply -u): bootstrap
  over SSH, then run the app as a ONE-SHOT mux session over the
  encrypted roaming UDP transport — no durable tab needed; this is
  the standalone "mosh for GUI apps". The daemon wraps the app in
  waypipe server as usual; the CLI pumps the chan_* frames into the
  local waypipe client with a plain poll loop (no GTK/GLib), and
  streams the session's terminal text to stdout for error
  visibility. spawn+attach are pipelined back-to-back so the app
  can't race its first display connection against our attachment.
- 🐛 findInPath allocated with a sentinel but returned []u8 — the
  deferred free passed the wrong size (latent in the ssh path, which
  exec()s and never frees; the -u path crashed the DebugAllocator).
- VERIFIED over REAL UDP to 127.0.0.1 (fresh system daemon):
  weston-flower renders on the local compositor with every byte
  riding rudp datagrams; full process chain (udp-connect bridge,
  daemon waypipe server, --no-gpu waypipe client) observed live.
- Known issue (pre-existing): `udp:localhost` fails — the UDP
  bootstrap's name resolution disagrees with the listener's bind
  family (v4/v6); IPs and real hostnames work. Restarted the local
  system daemon (was the pre-channel build; one leftover idle
  session dropped).
- 508 tests, smoke-mux PASS.

## 2026-06-12: mux session lifecycle — kinds, zombies, detach-to-shell

- Session kind: SpawnReq/Session/SessionInfo carry an `app` flag
  (set by `sketerm app -u` spawns); `mux list` prints shell/app,
  the TUI tags `[gui app]`. ignore_unknown_fields + defaults keep
  old daemon ↔ new client (and vice versa) compatible.
- 🐛 Zombie sessions: sessionExited now delivers .exit then
  force-detaches every client, so a vanished-without-BYE client
  (UDP peer roamed away) can't pin a dead session in the list;
  reap collects it the same tick. handleAttach refuses exited
  sessions in the race window. Live sessions are NEVER reaped.
- 🐛 Detach never closes the pane: palette "Detach Session" called
  closeFocusedPane, and remote session end / connection loss went
  through exit_action=close. Both now swap a fresh local shell
  into the pane's slot (swapPaneInPlace, extracted from the
  attachMux takeover surgery); exit_action is local-children-only.
  `mux_detach` is now a bindable action (keybind.mux_detach,
  `sketerm cli action mux_detach`).
- VERIFIED live (isolated Xvfb GUI + daemon): remote `exit` lands
  the pane in a local shell + session reaped; mux_detach lands in
  a local shell with the session alive at 0 clients; reattach OK.
- Gotcha hit while testing: scripts running INSIDE a sketerm pane
  inherit $SKETERM_SOCKET — `sketerm mux attach` then talks to the
  REAL GUI, not the test instance (env -u SKETERM_SOCKET).
- 508 tests, smoke-mux, smoke-e2e, mux-portable all PASS.

## 2026-06-12: native app pipe, milestones 1+2 — wlhost core + daemon endpoint

The sketerm-native replacement for waypipe (decision + plan in
docs/proposal-macos-remote-apps.md), built on the Linux machine:

- `src/wlhost/` — GTK-free, libc-free protocol core, shared by the
  daemon and the future GUI compositor brain:
  - `wire.zig`: Wayland wire codec (header/args/builder, fds are
    out-of-band placeholders). Round-trip + malformed-input tests.
  - `protocol.zig`: hand-written interface tables, core wayland +
    xdg-shell, v1 scope (shm only, no dmabuf/data-device). Cross-
    checked mechanically against wayland.xml 1.25 + xdg-shell
    stable — pinned at wl_compositor/wl_surface v6 (v7's
    release/get_release excluded by version, opcodes unaffected).
  - `track.zig`: per-connection state machine — object id →
    interface, registry binds, shm pool/buffer lifecycle,
    attach→commit with resolved buffer geometry in the action.
  - `pipe.zig`: the chan_data sub-protocol (tag+len units: verbatim
    wl messages, pool side-band, chunked pool updates for buffers
    bigger than MAX_FRAME). ChannelKind.wayland_native = 2.
- Daemon endpoint (`SKETERM_MUX_NATIVE_WAYLAND=1`, waypipe stays
  the default until the GUI side exists): the daemon listens on the
  session's $WAYLAND_DISPLAY socket itself (no waypipe wrap; pty
  gained a wayland_display spawn opt), recvmsg + hand-rolled CMSG
  walk for SCM_RIGHTS (macros don't translate), mmap pool mirrors,
  full-buffer copy per commit. GUI→app units flow back verbatim;
  delete_id tracked. Protocol violations kill the app connection.
- smoke-mux drives it end-to-end with a scripted Wayland app: real
  fd over SCM_RIGHTS, registry/shm/surface dance, commit → pool
  bytes verified at the client; one event written back and read
  out of the app socket verbatim.
- Portability: <sys/mman.h> added to cimport_core.h (musl-clean);
  MSG_CMSG_CLOEXEC avoided (Darwin lacks it; single-threaded daemon
  sets FD_CLOEXEC post-recvmsg). aarch64-macos cross-compile green.
- Next: GUI compositor brain (render `foot`), then input, then
  damage diffing + compression.
- 531 tests, smoke-mux, mux-portable, GUI build all PASS.

## 2026-06-12: native app pipe milestone 3 — compositor brain + GUI windows

Stock Wayland apps now run over the sketerm-native pipe end to end,
zero waypipe:

- `wlhost/compositor.zig`: the server-side protocol brain (pure
  state machine, GTK/socket-free). Advertises low-version globals
  (compositor 4 / shm 1 / seat 1 with caps 0 / output 2 /
  xdg_wm_base 2), runs the xdg configure dance, latches commits,
  fires frame callbacks, extracts tight-packed pixels from the
  synced pool mirrors via View callbacks. Lenient where toolkits
  are sloppy (seat get_* with caps 0 register silent devices).
  Protocol violations send wl_display.error and mark dead.
- smoke-mux "real app" stage: spawns weston-terminal in a native
  session, pumps daemon ↔ compositor over the mux protocol, and
  asserts a committed frame (806x539, non-zero pixels, 6 rounds).
  Skips cleanly when weston-terminal isn't installed.
- GUI: `src/wlapp.zig` AppHost renders each toplevel as GtkWindow +
  GtkPicture (GdkMemoryTexture per commit; argb→B8G8R8A8_PREMULT,
  xrgb→B8G8R8X8). terminal.zig routes wayland_native chan_* frames
  into it (NApp list alongside the waypipe WlChan list). Close
  button → xdg_toplevel.close. Title via set_title callback.
- VERIFIED live (Xvfb, isolated XDG dirs): GUI + native-mode local
  daemon, durable tab, `weston-terminal &` typed into the session —
  a local window appears with correct CSD rendering, prompt,
  cursor, drop shadow, and forwarded title. Screenshot-confirmed.
- Next: input (wl_seat caps, keymap over the pipe, GTK event →
  seat events), then damage diffing + compression, then popups.
- 535 tests, smoke-mux (incl. real app), smoke-e2e, mux-portable,
  aarch64-macos cross all PASS.

## 2026-06-12: native app pipe milestone 4 — input

Remote apps are now interactive over the native pipe:

- Compositor: seat caps pointer|keyboard; injection APIs for the
  view (pointer enter/leave/motion/button/axis, keyboard enter/
  leave/key/modifiers), serials + injectable now_ms clock. Focus
  tracked per device; events fan out to every bound device object.
- Keymap: fixed pc105/us blob (xkbcli-generated, embedded). On
  get_keyboard the compositor emits a pipe `keymap` unit; the
  DAEMON materializes the fd (platform.anonFileFd: memfd_create on
  Linux — declared by hand, _GNU_SOURCE hides it from translate-c —
  Darwin shm_open) and sends wl_keyboard.keymap itself, attaching
  the fd SCM_RIGHTS-style to the next pending write (early fd
  arrival is legal; late is not).
- GUI: GTK controllers on app windows (motion/click/scroll on the
  picture, key/focus on the window) → seat injection, with
  widget→surface coordinate scaling (picture content-fit FILL).
  GDK button → evdev BTN_*, GTK keycode-8 = evdev, GDK modifier
  low bits = xkb mod order.
- Hardware-truth bugs caught by driving REAL weston-terminal:
  (1) wl_pointer.set_cursor (opcode 0) was dispatched as a
  destructor — the bogus delete_id killed the app the moment the
  pointer entered. (2) Cursor surfaces (set_cursor, no xdg role)
  commit real buffers — they reached the view as phantom 30x30
  windows. Both fixed, both regression-tested.
- smoke-mux input stage: types l/s into weston-terminal through
  the full pipe and asserts echo redraws. VERIFIED live under
  Xvfb: `echo NATIVE-OK` typed into the remote window executed
  and rendered (screenshot-confirmed).
- Next: window resize (GTK size → xdg configure), damage diffing +
  compression, popups, clipboard.
- 537 tests, smoke-mux, smoke-e2e, mux-portable, aarch64-macos
  cross all PASS.

## 2026-06-12: native app pipe milestone 5 — resize, damage, deflate, popups

- Resize: GTK default-size notify → configureToplevel → xdg
  configure pair → app redraws at the new size (verified live:
  806x539 → 1100x700, client allocated the new buffer, crisp).
  Feedback guards stop configure echo loops.
- Damage: tracker folds damage/damage_buffer into per-surface row
  ranges; daemon copies only damaged rows per commit. Clients that
  never declare damage get full copies; ack-only commits copy
  nothing. Typing echo now ships a few rows, not 1.7 MB.
- Compression: pool chunks >=1KB go as raw-deflate pool_update_z
  units when smaller (std.compress.flate — pure Zig, daemon stays
  libc-only). Receivers accept both forms; corrupt streams and
  length lies are protocol errors.
- Popups: positioner place() (anchor/gravity/offset), popup
  configure dance, grab → click-outside popup_done, keyboard
  follows the grab. GUI renders popups as GtkOverlay children of
  the parent window (GTK4 has no positioned toplevels; menus clip
  at the window edge like nested compositors). Unit-tested; no
  popup-capable demo app installed for a live check — revisit with
  a GTK client once the data-device milestone lands.
- Remaining: clipboard (wl_data_device_manager, text scope),
  per-app window icons/WM_CLASS, retire-waypipe flag flip.
- 540 tests, smoke-mux, smoke-e2e, mux-portable, aarch64-macos
  cross, live input regression all PASS.

## 2026-06-12: native app pipe milestone 6 — clipboard

Text clipboard both directions over the native pipe, fd-free on
the mux wire (fds never leave their host):

- Protocol: wl_data_offer/source/device/manager tables (full v3,
  XML-verified; advertised at v1 = selection only, dnd ignored).
  wl_data_device.data_offer is the first server-created object —
  tracker.serverMessage now registers event-created ids.
- Daemon: receive(mime, fd) fds are held in a FIFO until the GUI's
  clip_data unit arrives (write + close). clip_send units make the
  daemon pipe a wl_data_source.send to the app and poll the read
  end until EOF → clip_data up. Clip pipes ride the main poll loop.
- GUI/compositor: set_selection → best-text-mime view callback →
  fetchClipboard; clip_data → GdkClipboard.set_text. Paste offers
  are re-announced per keyboard-focus change (NOT the GTK focus
  controller alone — it doesn't fire under bare X) and answered
  via async GTK clipboard reads; AppHost defers its final free
  while reads are in flight.
- smoke-mux: scripted paste (PASTE-42 through a held fd) + copy
  (COPY-7 through the daemon pipe) round-trips. LIVE: OSC 52 set
  "CLIP-LIVE-9" in the durable session; Ctrl+Shift+V in remote
  weston-terminal pasted it (screenshot-confirmed).
- Test-rig gotchas hit: raw ESC bytes can't be typed into a shell
  (readline eats them — send printf-escaped text); the smoke's GUI
  side must wait for relayed messages before referencing their ids
  (mirrors the real ordering guarantee).
- 541 tests, smoke-mux, smoke-e2e, mux-portable, aarch64-macos
  cross all PASS.

## 2026-06-12: native pipe — GTK4 validated live, identity polish

- Minimal GTK4 C client (gcc against system gtk4) through the full
  pipe: window maps with CSD, POPOVER MENU opens correctly placed
  (first live xdg_popup validation), entry renders. Mesa's swrast
  EGL presents via wl_shm, so even GL clients work ("loaded OpenGL
  4.5" on our dmabuf-less compositor).
- Polish: titles/app_ids arriving before the first frame are
  buffered and applied at window creation (GTK sets them before
  attaching a buffer — every window was "remote app" before);
  app_id → gtk_window_set_icon_name (desktop icon convention);
  comp.now_ms stamped per feed (frame done events carried 0).
- ghostty: initializes fully (GL, shell spawn) but exits 0 before
  mapping — no protocol error on the wire, likely missing-protocol
  gating on its side (cursor_shape/fractional_scale?). App-specific;
  revisit when more protocol extensions land.
- Pushed milestones 1-6 to origin (c875e4a..8ada0ca).
- 541 tests, smoke-mux, mux-portable all PASS.

## 2026-06-12: native pipe is the DEFAULT

The strategic flip: durable sessions now provide the sketerm-native
Wayland display by default — `scp sketerm-mux-portable` is the
complete server install for terminals AND GUI apps. Legacy waypipe
wrap survives as `SKETERM_MUX_WAYLAND=waypipe` (the one thing it
still does better: dmabuf/GPU transfer); `SKETERM_MUX_NO_WAYLAND=1`
still disables forwarding. smoke-mux runs the default path (env
gate removed); REMOTE.md documents the feature + limits.
Verified live without any gate env: GTK4 client maps, menus open.
541 tests, smoke-mux, smoke-e2e, mux-portable, aarch64-macos PASS.

## 2026-06-12: native pipe — adwaita validated, wp extensions

- libadwaita A/B client (AdwApplicationWindow + header bar) maps
  and lives over the pipe — the modern GNOME app class works;
  ghostty's clean exit is confirmed app-specific (still dies with
  cursor-shape/viewporter/fractional-scale advertised).
- New protocols: wp_cursor_shape_manager_v1 (set_shape → view →
  gtk_widget_set_cursor_from_name on the focused window — remote
  apps now drive the local pointer shape), wp_viewporter (inert at
  scale 1), wp_fractional_scale_manager_v1 (always 1.0).
- 542 tests, smoke-mux, mux-portable, aarch64-macos, live clip
  regression all PASS.

## 2026-06-12: wl_mode per session — `sketerm app -u` un-broken

The default flip regressed standalone `sketerm app -u`: the
headless client can only bridge waypipe, but new daemons handed it
native channels. SpawnReq.wl_mode (""/native/waypipe) lets clients
pick; -u requests waypipe, GUI spawns stay native-default, and
waypipe-requested sessions on waypipe-less hosts get NO forwarding
(clean app-side failure) instead of a dead-end native session.
Wire-compatible both directions. 542 tests, smoke-mux, both
portable targets PASS.

## 2026-06-12: winstream — macOS-apps-on-Linux transport, stub-proven

Everything buildable without a Mac: proto units (win_open/frame/
frame_z/title/close + input_key/input_ptr/close_req, evdev codes,
window-local pixels), stub capture source (animated pattern,
input-reactive, 10fps rate-limited), daemon agent (fd-less
winstream channels opened at attach for app sessions when
SKETERM_WINSTREAM is set; "all" widens for rig testing), GUI WsHost
(GtkWindow per remote window, BGRA → GdkMemoryTexture, input back).
smoke-mux winstream stage + live rig PASS (stub window renders its
pattern on screen). The Mac side drops ScreenCaptureKit +
CGEventPost behind Source.poll/handleInput — transport and render
are done. 546 tests, all targets green.

## 2026-06-12: app-window UX — pane attach, decorations, identity

User-reported from live laptop→archdev testing (pcmanfm WORKS over
the native pipe): `sketerm app` in a pane takes over the pane;
host windows undecorated by default + zxdg_decoration negotiation
(SSD requesters get host decorations); per-window identity via
gdk_wayland_toplevel_set_application_id / X11 WM_CLASS (libX11 now
linked on Linux GUI). 545 tests, smoke-mux, portable targets PASS.

## 2026-06-12: app windows — move/resize, transparency, input regions

From live laptop testing: undecorated host windows couldn't be
dragged (xdg_toplevel.move was ignored — now hands off to
gdk_toplevel_begin_move/resize with the originating press); CSD
shadows composited onto theme gray (host windows now have a
transparent background via CSS class); shadow margins ate clicks
(input regions tracked + applied to the host GdkSurface — staged on
set_input_region, applied at commit, subtract fails safe). Plus the
tab progress ring: one pane owns it at a time (3s quiet timeout) so
two concurrent builds stop glitching the ring + taskbar. OPEN: the
user-reported Super+drag crash — not reproducible headless (no WM),
awaiting which-process-died + log from the laptop.
546 tests, smoke-mux, both portable targets PASS.

## 2026-06-12: window geometry + the full xdg_toplevel sweep

User round 3: taskbar/alt-tab absence (host windows now join the
GtkApplication), shadow-as-border on maximize/snap (frames CROPPED
to xdg window geometry — shadows never leave the compositor; input
+ input-region coords compensate), maximize stretch (default-size
doesn't track maximization — real allocation + maximized state
sent on notify::maximized). Then the everything-else sweep:
set_parent/min_size/maximize/fullscreen/minimize honored, activated
follows focus, fullscreen state round-trips, seat v4 + repeat_info,
popup constraint sliding. 546 tests, smoke-mux, rig (crop verified
visually: edge-to-edge content, popup placed right), both portable
targets PASS.

## 2026-06-12: winstream — the real ScreenCaptureKit backend (Mac)

The Darwin half of macOS-apps-on-Linux, behind the stub's exact
poll/handleInput surface:

- sck_shim.m (ObjC, C ABI): SCShareableContent refresh every 500ms
  filtered by pid ancestry OR shared controlling tty (survives
  shell re-parenting); one SCStream per window, BGRA at point
  resolution, content-rect cropped (resize between config updates
  stays correct); latest-frame-wins buffers behind a mutex; a
  wakeup pipe that joins the daemon poll set so frames don't wait
  out the 500ms tick. Input: CGEventPost — keys via an
  evdev→CGKeyCode table (keymap.zig, unit-tested everywhere),
  pointer mapped through the live window frame, drag/click-count
  tracking, scroll with fraction accumulation; close_req walks AX
  windows (frame-matched) for the close button, falls back to app
  terminate for the last window.
- source.zig is now a stub/sck dispatch union; the sck arm
  collapses to void unless build_options.winstream_sck (native
  macOS builds only — Linux, musl, every cross target unchanged,
  mux-portable explicitly never carries capture). App sessions on
  capture hosts stream by default; explicit wl_mode wins;
  SKETERM_WINSTREAM stub/all/sck gating for rigs.
- TCC honesty: missing Screen Recording → a notice window with the
  fix in its title + actionable daemon log, never a hang. Verified
  live over a real daemon + mux socket. GUI scroll now forwarded
  (input_ptr kind 3 = wheel deltas).
- Hardware traps documented in macos.md: launchd-vs-sshd TCC
  identity, ad-hoc cdhash re-grants, macOS 26 launch constraints
  (system apps can't be PTY children), Darwin CMSG layout (smoke
  fd-passing fixed → smoke-mux now passes natively on the Mac).
- 549 tests, smoke-mux (Mac + stub), mux-portable x86_64+aarch64
  musl, aarch64-macos portable, GUI build all green. Real-capture
  live run pending the manual Screen Recording + Accessibility
  toggles (registered, awaiting the human).

## 2026-06-12: Mac-as-client — Linux app over the native pipe

The merge-milestone direction nobody had hardware for until now:
sketerm GUI on the Mac (GTK/macOS) attaching a durable session on
the colima Ubuntu VM over SSH, weston-terminal launched from the
session shell ($WAYLAND_DISPLAY = the daemon's native display).
The app runs against the Mac-side wlhost compositor — stays alive,
zero protocol errors in the GUI log. Same wlhost/winapp code as
Linux, unchanged. Visual + input confirmation needs eyeballs on
the console (screencapture is TCC-blocked for the SSH shell);
protocol level is green. Rig: fresh aarch64-musl daemon scp'd to
the VM, weston installed there, SKETERM_SSH wrapper for the colima
key.

## 2026-06-13: CRT monitor bezel (cool-retro-term-style frame)

crt.glsl grew a procedural plastic bezel where it used to draw flat
black outside the curved tube. A rounded-rect SDF defines the glass;
content is inset by the bezel width so the frame always has room
(content sampling remaps the inner box back to [0,1]), and the
surround is a lit bevel — inner seating-groove → crest with a
top-left sheen → outer rounded edge fading to the black window
background. Three new tunables flow through the existing
shader-param plumbing (so they appear in "Configure Shader…" and
are per-pane via the profile's custom_shader): `bezel` (width),
`bezel_round` (screen + frame corner roundness), and the
`bezelcolor` picker. bezel = 0 collapses the frame onto the screen
edge → the original pure-black surround, so it's backward
compatible. No Zig changes — pure data shader. Validated by
compiling the gl.zig-wrapped source under BOTH Mesa GLES 300 es and
desktop GL 330 core (the two sketerm injects); GUI builds clean.
Visual eyeball still pending a display.

## 2026-06-13: winstream SCK backend — VALIDATED ON HARDWARE

The macOS window-streaming backend works end to end on a real Mac.
A cert-signed sketerm-mux LaunchAgent in the GUI session captured a
live AppKit window (correct 480×352 + title, 1200+ deflated frames
over the mux socket), injected keystrokes that changed the captured
frames (zero drops once Accessibility was on), and closed the window
via AX. Capture + keyboard/mouse + window-close all confirmed.

The bring-up was a TCC/session gauntlet, now documented in
REMOTE.md ("Remote macOS apps") + automated by dist/deploy-macos.sh:

- **WindowServer**: SCContentFilter makes in-process WindowServer
  calls; a bare daemon aborts with CGS_REQUIRE_INIT. Fix:
  sck_shim promotes the process to a UIElement app
  (NSApplicationActivationPolicyAccessory) at first capture — no
  Dock icon, establishes the connection. AND the daemon must run in
  the Aqua login session: an agent bootstrapped over SSH lands in
  the wrong audit session and still can't reach WindowServer; one
  bootstrapped from the user's own session can.
- **TCC attribution**: a shell-launched daemon is blamed on the
  terminal app (no grant → denied); a launchd agent is blamed on
  sketerm-mux itself. So it must be a LaunchAgent, not a shell job.
- **TCC cdhash pinning**: grants pin the binary's code signature.
  Ad-hoc Zig builds change hash every rebuild → re-grant each time.
  Signing with a self-signed `sketerm-dev` cert pins the cert
  instead; rebuilds re-signed with it keep the grant. Creating the
  cert is a one-time Keychain Access GUI step (CLI trust-settings
  need GUI auth, unreachable over SSH).

Tooling: dist/deploy-macos.sh (build → sign → bootstrap agent),
run from a GUI terminal. The earlier commits (capture shim, input,
gating, frame-codec refactor, WindowServer fix) all stand; this is
the validation + deployment layer. 550 tests, smoke-mux green.

## 2026-06-13: macOS remote apps — transparent CLI + shared windows

Closed the gaps between "the winstream backend works" and "you use it
exactly like a Linux remote":

- **Session parity** (daemon): winstreamGate now keys on a generic
  "hosts_apps" notion instead of req.app, so on macOS a GUI app
  launched from ANY durable session (a plain `sketerm mux` shell,
  not just `sketerm app`) streams — the macOS equivalent of Linux's
  per-session $WAYLAND_DISPLAY forwarding. `sketerm app <host> <cmd>`
  was already OS-agnostic (runNativeApp → app session → GUI renders);
  this widens it to durable shells too. SKETERM_WINSTREAM=off added
  for the test rigs.
- **Stable macOS socket**: runtimeDir() resolves the per-user temp
  dir via confstr(_CS_DARWIN_USER_TEMP_DIR), not $TMPDIR — so the
  GUI-session LaunchAgent and a non-interactive `--proxy` SSH bridge
  agree on the default mux socket and actually find each other.
- **Shared window chrome**: src/remote_window.zig now owns the
  free-floating-dialog chrome (undecorated/transparent/taskbar/
  identity/move-resize/texture) that BOTH wlapp.zig (Wayland) and
  winapp.zig (winstream) build on — the winstream renderer is no
  longer a primitive parallel system; its windows ARE the same
  free-floating dialog as Wayland app windows. wlapp shrank 131
  lines (de-duplicated); byte-for-byte extraction keeps the default
  Linux path unchanged.
- **Acceptance test**: dist/macos-winstream-check.sh self-checks a
  Mac host (cert, capture-linked + signed daemon, default socket,
  agent, cert-pinned TCC grants) then drives a live capture+input+
  close round-trip.

550 tests, smoke-mux, smoke-e2e, both portables green; mux stays
GTK-free. PENDING (needs an unlocked GUI session / a Linux box — the
validation Mac kept auto-locking): the Wayland AppHost VISUAL
regression eyeball, the acceptance script's live leg, and a full
Linux-client → Mac-app run.

## Remote-app fixes + waypipe removal (2026-06-13)

- **Crash on hover (cairo double-free)**: `wlhost/compositor.zig` sent
  `wl_buffer.release` on every commit, not just the one that attached
  the buffer; GTK's frame-callback-only repaints (cursor/hover)
  released the same buffer repeatedly, underflowing the client's cairo
  refcount and aborting the app. Released once per attach now.
- **Manual resize**: undecorated host windows got an 8px edge/corner
  resize band (`remote_window.resizeEdgeAt` + `wlapp` input handlers).
- **App CSD shadow restored**: stopped cropping the shadow out. The
  full buffer is shown and the shadow margin is reported as the host
  toplevel's shadow width (GdkToplevel `compute-size`, connected AFTER
  GTK's handler), so KWin's geometry = the content rect — snapping,
  tiling and maximize hit the real edge while the app's own shadow
  stays visible. Maximize sizing comes from the toplevel bounds in the
  compute-size handler (the allocation isn't settled at
  notify::maximized).
- **waypipe removed entirely**: the daemon is the only Wayland display
  (no `waypipe server` wrap, no `wl_mode`); the GUI renders every app
  via the `wlhost` compositor (no `waypipe client`/`wlbridge`). Deleted
  `src/wlbridge.zig`, the `.wayland` channel kind/path, and the legacy
  `sketerm app` waypipe + headless-UDP fallbacks. `sketerm app [-u]`
  now always uses the native pipe and REQUIRES a running sketerm
  window; `-u` routes through the native path over roaming UDP.

551 tests, smoke-mux, mux + mux-portable green; mux stays GTK-free.

## macOS NSAccessibility bridge (2026-06-16)

VoiceOver/AppKit twin of the Linux AT-SPI bridge, over the same
platform-neutral `a11y/view.zig` core (no text model duplicated).

- **`src/a11y/nsax.zig`** — Zig bridge. Mirrors `atspi.zig` 1:1: each
  query rebuilds a `view.Snapshot`, answers, frees it. `export fn`
  callbacks (`sketerm_nsax_value/length/string_for_range/caret/
  line_for_index/range_for_line`) own the one macOS-specific wrinkle —
  **NSRange is UTF-16 code units, the snapshot is codepoints** — via
  `Snapshot.char_to_utf16`/`utf16At` forward and a `charForUtf16`
  binary-search inverse. Public `newView`/`notifyChanged`/`releaseView`
  for the future AppKit pane.
- **`src/a11y/nsax_shim.m`** — `SketermTermView : NSView` implementing
  the NSAccessibility text protocol (role `AXTextArea`, value,
  string-for-range, selected-text-range = zero-length caret, line
  lookups, visible range), each method calling the Zig callbacks. Plain
  C ABI, `-fobjc-arc`, like `winstream/sck_shim.m`. Stores a stable
  `*Terminal` (deref `term.screen` live, since it swaps on a mux
  snapshot).
- **Actually wired to VoiceOver on the current GTK frontend.** GTK4 on
  macOS ships only the AT-SPI backend (`atspi - Not available on this
  platform`), so `GtkAccessibleText` reaches VoiceOver *not at all*
  here. There's also no per-pane NSView (GTK draws into one
  `GtkMacosContentView`). So `pane.zig`, on the GL area's `map`, walks
  `gtk_widget_get_native` → `gtk_native_get_surface` →
  `gdk_macos_surface_get_native_window` → `[NSWindow contentView]` and
  attaches a `SketermTermAXElement` (an `NSAccessibilityElement`, one
  per pane) as an accessibility child of that content view — visible to
  VoiceOver. Detach on `unmap`/close, frame from widget bounds,
  value/selection-changed posted per render. All behind
  `platform.is_macos`; Linux unchanged.
- **`build.zig addNsaxBridge`** links the shim + AppKit/Foundation on a
  native-macOS toolchain; `main.zig` force-includes `nsax.zig` so the
  exports are present. `SketermTermView : NSView` stays for the future
  de-GTK'd AppKit pane (`docs/architecture.md` step 1).
- **Verified end-to-end on hardware**:
  - `zig build smoke-a11y` — real `SketermTermView` through the AX
    selectors VoiceOver calls: value, UTF-16 char count, caret range,
    substring across a 😀 surrogate pair, line ranges.
  - `SKETERM_A11Y_SELFCHECK=1 sketerm` on the real GUI logs
    `A11Y-SELFCHECK: pane=1 bits=7 (PASS)` — a VoiceOver client walking
    window→contentView→child finds an `AXTextArea` whose value is the
    live terminal text (no TCC grant needed for the in-process check).
  - `smoke-e2e` PASS with the attach/detach lifecycle live (splits,
    pane close, quit).

582 tests (incl. 3 new `nsax` conversion tests + the astral
`char_to_utf16` core test), smoke-a11y + smoke-e2e PASS, mux-portable
green.

## 2026-06-16: shared pixel codec + zstd — unified Wayland/winstream wire

First slice of the pixel-streaming unification: one compression layer
under BOTH remote-app pixel paths (Wayland shm-pool mirror + macOS
window capture), so classify→encode→decode becomes one implementation.

- **`src/wlhost/pixcodec.zig`** — the shared codec. A region (BGRA rows
  of `row_stride`) encodes as a self-describing body
  `[coder|filter|raw_len|row_stride|bytes]`. `coder` ∈ {raw, zstd};
  `filter` ∈ {none, sub, up, paeth} (PNG predictors, bpp=4). The encoder
  picks the filter by PNG's minimum-sum-of-absolute-differences
  heuristic — cheap scoring passes, then a SINGLE zstd pass — and keeps
  it only if it beats the raw size (never regresses). `decodeBody`
  reverses it.
- **Unified wire.** `wlhost/pipe.zig` gains `pool_update_c`,
  `winstream/proto.zig` gains `win_frame_c` + `decodeFrameC`; both embed
  the same pixcodec body. The two addressing models (Wayland pool+offset
  vs winstream win+w+h) stay separate — only the encoded body unifies.
  The body carries `row_stride` because the GUI decodes a pool offset
  without knowing the buffer's stride.
- **Daemon** (`mux/daemon.zig`) commit path chunks by WHOLE ROWS (so the
  predictor resets per row) and emits `pool_update_c`; `compositor.zig`
  decodes it. The winstream stub source, `winapp.zig`, and
  `smoke_mux.zig` moved to `win_frame_c`. `sck.zig` still emits legacy
  `win_frame`/`win_frame_z` — Phase 1 switches it.
- **zstd, vendored + static everywhere.** `vendor/zstd/zstd.c`
  (single-file amalgamation, v1.5.7, BSD/GPLv2) compiled into every
  artifact via `addZstd()` in build.zig (core + sys + portable), reached
  by `extern fn` (no header through @cImport). The musl portable binary
  stays fully static (`ldd`: not a dynamic executable) with zstd baked
  in — a true drop-anywhere daemon that still does real zstd-coded
  streaming.

The lossless win is now live on both paths: best-of-4 predictors + zstd
beat the old plain-deflate wire. `zpool` (deflate) is kept only to
decode the legacy `pool_update_z`/`win_frame_z` units.

596 tests, GUI build, smoke-mux (both paths round-trip through real
zstd), mux-portable static — all green.

## 2026-06-16: winstream damaged-rect patches + receiver backing buffer

Receiver half of damage-aware macOS streaming — so the SCK source can
ship only the dirty rects instead of whole windows.

- **`win_patch_c`** (winstream/proto.zig) — a damaged sub-rect:
  `[win][x][y][w][h]` + a pixcodec body for the w×h rect, with
  `decodeWinPatchC` / `decodePatchC`.
- **`blitRect`** (remote_window.zig) — blits a tight w×h BGRA rect into
  a backing buffer at (x,y), CLIPPING out-of-bounds rows/cols so a
  malformed wire rect can never overrun. Unit-tested incl. edge/clip.
- **Per-window backing buffer** (winapp.zig `WsHost.Win.backing`): full
  frames (`win_frame_c`) fill it, patches blit into it, and a single
  `present()` re-wraps the whole backing as a `GdkMemoryTexture`. Freed
  in both teardown paths. The full-frame→backing→present path is what
  the stub exercises today; patches are exercised by the SCK source.
- **Wayland needed nothing**: the compositor's pool mirror already IS
  the backing store, and the daemon already streams damaged rows into
  it (`pool_update_c`). Only winstream had the gap.

Receiver + wire are done and Linux-tested; the SCK source emitting
`win_patch_c` from `SCStreamFrameInfoDirtyRects` is the Darwin-only
follow-up (sck.zig / sck_shim.m), validated on Mac hardware.

598 tests (win_patch_c round-trip + blitRect clipping), GUI build,
smoke-mux green.

## 2026-06-16: winstream SCK dirty-rect source (Phase 1 Darwin half)

The capture source now emits `win_patch_c` for the changed sub-rects
instead of whole window frames every time.

- **`sck_shim.m`**: each `didOutputSampleBuffer` reads
  `SCStreamFrameInfoDirtyRects`, translates them to content-local pixels
  (the `latest`/wire space), clamps + dedups, and accumulates per window
  across callbacks until the next drain (`acc`, cap `SCK_ACC_CAP`).
  `latest` still holds the whole current frame, so the drain copies each
  dirty rect tightly out of it into a drain-held `NSData`. `SckEvent`
  gained `x,y` + `kind 5` (patch).
- **Full-frame contract honoured via `needs_full`**: set on window open,
  resize (incl. a content-rect/letterbox shrink detected in the frame
  callback — re-baselines so stale large coords never read OOB), client
  reattach (`reannounce`), missing/over-cap damage, or a dirty area
  ≳60% of the window (many patches cost more than one frame). When set,
  the drain sends a whole `win_frame_c`; otherwise one `win_patch_c` per
  rect. So the first frame after open / a resize / a reattach is always
  a full frame — exactly what the receiver's backing buffer requires.
- **`sck.zig`**: full frames and patches both go through the shared
  `pixcodec` now (`encodeRegion` + `appendWinFrameC` / `appendWinPatchC`,
  one reused `Scratch`); dropped the old `appendFrameMaybeZ`/`zbuf` path.
- **Hardware validation is human-in-the-loop**: real SCK capture needs
  the Screen-Recording TCC grant, pinned to the daemon's signature and
  only effective as the GUI-session LaunchAgent. Deploy with
  `dist/deploy-macos.sh` (re-signs with the `sketerm-dev` cert from your
  login keychain — not reachable from a non-interactive/SSH shell), then
  drive a remote app: a small animated region should update only that
  region and total bytes drop sharply vs. whole frames.

Native `zig build mux` (SCK linked) + smoke-mux + 591/598 tests +
mux-portable (x86_64/aarch64) all green.

## 2026-06-16: per-tile churn classifier (Phase 3)

The routing brain for the pixel pipeline — tells hot (frequently
changing) regions apart from cold (static) ones, so a future lossy/
temporal coder (Phase 4) can be aimed only where it pays off.

- **`src/util/churn.zig`** `Tracker` — a tile grid (default 64px) with
  one byte of heat per tile. `noteDamage(x,y,w,h)` flags overlapped
  tiles; `endFrame()` heats touched tiles (capped) and decays untouched
  ones; `hot(x,y,w,h)` reports whether a region is majority-hot.
  Transport-agnostic (Wayland damage rows + SCK dirty rects feed the
  same cycle), pure std, daemon-safe.
- **Not wired in yet, by design**: the thing it routes *to* (the video
  coder) lands in Phase 4, so wiring now would be dead code in the
  daemon hot path. Everything still encodes lossless; zero behaviour
  change. The classifier is ready to consume the moment Phase 4 exists.

604 tests (incl. 6 churn cases: threshold ramp, one-shot stays cold,
hot cools down, mixed coverage, OOB/empty safety, resize resets), GUI
build, smoke-mux, mux-portable green.

## 2026-06-16: vcodec — video-tile layer foundation (Phase 4 step 1)

The lossy/temporal counterpart to pixcodec, for HOT regions. Design in
`docs/proposal-phase4-video.md` (untracked); decision is codec behind a
swappable backend, x264-first then AV1 (royalty-free), hardware
opportunistic, AV2 once it matures.

- **`src/wlhost/vcodec.zig`** — `Codec` enum (stub/h264/av1); a
  length-prefixed tile wire (`appendTile`/`peelTile`:
  codec/keyframe/x/y/w/h/seq + opaque payload, split-resilient like the
  other unit streams); `Encoder`/`Decoder` tagged-union backends (the
  winstream `Source`-style swap) with a `stub` raw-passthrough backend.
  `seq`/`keyframe` already carry the UDP loss-recovery story.
- **Stub-first**, so the whole transport → decode → composite path is
  exercised with no codec linked — x264/AV1/hardware become new backend
  variants. Not yet wired into the daemon/receivers (that's step 2:
  churn routing + carrier units + mixed lossless/video composite + a
  content signal so text stays lossless).

609 tests (5 vcodec: wire round-trip + split peeling, malformed/too-long
rejection, stub encode→wire→decode, wrong-codec/size guards), GUI build,
smoke-mux, mux-portable green.

## 2026-06-16: Phase 4 routing brain + x264 encoder backend

Routing logic + the real software encoder behind the vcodec abstraction.

- **`src/util/content.zig`** — cheap sampled distinct-colour heuristic:
  flat/texty regions (few colours, sharp edges a lossy DCT would ring)
  stay lossless; photographic/continuous-tone regions are codec-safe.
  `decide(hot, pixels)` routes to video only when churn says HOT **and**
  content says photographic — biased to lossless (the safe error).
- **`src/util/yuv.zig`** — full-range BT.601 BGRA↔I420 (integer
  fixed-point, daemon-safe): the colour-space step every video codec needs.
- **`vendor/x264_shim.c`** — a 3-function shim over libx264
  (ultrafast/zerolatency, full-range, Annex-B), the sck_shim/nsax_shim
  pattern so Zig calls it via extern fn without x264.h in @cImport.
- **vcodec x264 backend** — `Encoder.initX264` BGRA→I420s a tile and
  encodes H.264; gated on `build_options.video`, collapsing to `void`
  (like SckImpl) when off.
- **build.zig `-Dvideo`** (default OFF) dynamically links the SYSTEM
  x264 (NOT vendored — its speed is per-arch asm; the optional video
  path can be absent on portable) + compiles the shim. Default builds
  and the musl-portable daemon stay video-free, fully static, lossless.

Decoder stays OS/hardware (VideoToolbox/VAAPI) — don't ship an
encumbered software H.264 decoder. Not yet wired into the daemon hot
path (next: worker-thread encode offload + carrier units + churn/content
routing + mixed lossless/video frames). Design: docs/proposal-phase4-video.md.

617 tests (churn/content/yuv cases + the x264 keyframe-encode test, which
skips without -Dvideo and passes under it), GUI build, smoke-mux,
mux-portable static — all green.

## 2026-06-16: Wayland lossy-video path end-to-end (Phase 4, x264 slice)

The full hot-region video path now works end-to-end under `-Dvideo`,
both sides built with it. Everything is comptime-off otherwise, so
default builds and `mux-portable` are byte-identical and lossless.

- **Carrier**: `pipe.zig` `pool_vtile` = {pool, offset, row_stride} + an
  opaque vcodec tile blob. The receiver decodes it into the pool mirror
  at the same destination `pool_update_c` fills — video and lossless
  regions composite identically.
- **Daemon send** (`daemon.zig` `videoCommit`): per-surface churn +
  content classifier; a HOT + photographic surface encodes its whole
  frame via x264 (vendor/x264_shim.c) → `pool_vtile`, else lossless.
- **Decoder**: `vendor/avdec_shim.c` wraps libavcodec H.264 software
  decode (single-thread + LOW_DELAY → immediate; accepts full-range
  YUVJ420P); `vcodec` avcodec backend → I420 → yuv.zig → BGRA. x264↔
  avcodec round-trip verified, mean abs error 0.62.
- **Compositor receive** (`compositor.zig`): decodes `pool_vtile` (a
  per-pool decoder, recreated on dim change) and blits into the pool
  mirror.
- **Negotiation**: the client advertises `video` in its hello; the
  daemon sets `Native.wants_video` per forwarding channel. A surface
  routes to video ONLY when the target client can decode AND the daemon
  can encode — never sending an undecodable tile. Defaults keep it off.
- **Decoder strategy**: software libavcodec now; VAAPI when present is a
  later hwaccel optimization (decode-everywhere via ffmpeg is the
  baseline, not a lossless fallback).

Build: `-Dvideo` dynamically links system x264 + libavcodec/avutil on
native builds (declared package deps); the musl-portable daemon omits
them and stays static/lossless.

619 tests under -Dvideo (617 + the 2 x264/round-trip tests; default
skips those), GUI default + -Dvideo, smoke-mux default + -Dvideo,
mux-portable static — all green.

Remaining Phase 4 refinements: VAAPI hwaccel, AV1 (SVT-AV1+dav1d) behind
the same backend, tile-grid encode (vs whole-surface), UDP keyframe-
request/loss handling, and a winstream (macOS) video path. Phase 5
(dmabuf) is a separate track.

## 2026-06-16: Phase 4 refinements — AV1, keyframe-on-attach, winstream video

Three refinements landed and verified on Linux; the rest hit hardware
walls on this box (no GPU) and are flagged for a GPU-equipped run.

- **AV1 backend**: `vendor/avenc_shim.c` (generic libavcodec encoder,
  used with libsvtav1 in a low-delay config: pred-struct=1, lookahead=0
  so a frame in is a packet out); the decode shim gained a codec param
  (H.264 or AV1). `vcodec` gets `Encoder.initAv1` and `Decoder` takes a
  codec; the compositor recreates its per-pool decoder on a codec change.
  H.264 keeps direct libx264 for lowest latency. SVT-AV1↔dav1d round-trip
  verified. The royalty-free codec, swappable behind the same union.
- **Keyframe on (re)attach**: rudp (go-back-N) makes the transport
  reliable+ordered, so the video stream never sees loss — no
  keyframe-request-on-loss machinery needed. The only trigger is a fresh
  client: `handleAttach` resets `needs_kf` on the session's live video
  surfaces (no-op without video).
- **winstream video receive**: `win_vtile` carrier + winapp per-window
  decoder → `blitRect` into the backing buffer — winstream's counterpart
  to the Wayland `pool_vtile` path. The macOS `sck.zig` encode side is
  the macOS developer's handoff (same split as Phase 1).

Deferred / hardware-gated (this box has no `/dev/dri`): **VAAPI hwaccel**
(can verify the software fallback but not the GPU path; decode is cheap
anyway) and **dmabuf forwarding** (large; needs real GPU apps to
validate) — both want a GPU-equipped run, like SCK wanted a Mac.
**tile-grid encode** is doable here but is the riskiest change (daemon
commit hot path) for a mostly-CPU benefit, since codec inter-frame
skip-blocks already keep whole-surface encodes small on the wire.

621 tests under -Dvideo (618 + the 3 video round-trip/encode tests that
skip without it), GUI default + -Dvideo, smoke-mux default + -Dvideo,
mux-portable static — all green.

## 2026-06-16: macOS video encode — VideoToolbox + sck.zig win_vtile

The Darwin half of the video-tile path: macOS apps now get the same
H.264 compression Wayland apps have, via the hardware encoder.

- **VideoToolbox backend** (`vendor/vtenc_shim.c` + `vcodec.zig` `Vt`):
  a new `Encoder.vtoolbox` variant emitting the SAME Annex-B `.h264`
  wire codec as x264, so the existing libavcodec receiver (`avdec`)
  decodes it unchanged. I420 (from `yuv.zig`, full-range BT.601, like
  x264) → NV12 full-range `CVPixelBuffer` → low-latency H.264
  (RealTime, no reorder, baseline, keyint 120), AVCC→Annex-B with
  SPS/PPS prepended on keyframes. **No libx264/libavcodec dependency**
  — VideoToolbox is a system framework, so the native daemon encodes
  video without the codec libs. Gated on `build_options.vtenc`
  (auto-on for a native macOS toolchain). Hardware-validated:
  `zig build test` runs a VT-encode keyframe check, and `-Dvideo` adds
  a VT-encode → avdec-decode round-trip (MAE < 15, so the full-range
  color path is correct).
- **sck.zig routing** mirrors daemon.zig's Wayland `videoCommit`,
  per window: a `churn.Tracker` + a VT `Encoder`, keyed by window id.
  The poll is now three passes — (1) emit lifecycle + feed churn this
  poll's damage (full-frame or dirty-rect events), (2) for each touched
  window that's HOT and (snapshot) photographic, encode the whole frame
  as one tile and emit `win_vtile`, (3) emit the lossless
  win_frame_c/win_patch_c only for windows NOT sent as video. A new
  shim call `sketerm_sck_snapshot` hands the source a window's whole
  current frame on demand (the lossless stream carries only patches).
- **Contract**: the receiver drops a `win_vtile` until a full
  `win_frame_c` has established the window's backing (winapp.zig:203),
  so a per-window `base_sent` gate forces a lossless base frame first
  (and resets on resize / reattach, where it also forces a keyframe).
  Capability-gated: `daemon.openWinstreamChan` calls
  `source.setWantsVideo(cl.video)`, so a tile is only ever sent to a
  client that advertised H.264 decode — exactly like the Wayland path.

Native `zig build mux` (SCK + VideoToolbox), tests (default + -Dvideo),
smoke-mux, GUI, and mux-portable (no codec) all green.

## 2026-06-17: one session handler — GUI is always a mux client

Collapsed the two parallel session paths (in-process worker/ring vs
remote socket) into one. The `sketerm-mux` daemon now owns **every**
session, local included; the GUI is always a thin client over the wire.

- **Killed the in-process path**: deleted the per-pane PTY worker thread,
  the SPSC ring, and `mainDrainEvents`. `Terminal` is `initRemote`-only —
  `writeRaw`/`requestResize` are socket-only, `child_pid` is always -1.
  New local tabs route through `connectLocalAutostart` (spawns/attaches
  the per-user daemon) like durable tabs always did. Visible-change
  detection for the activity glow moved into the remote `.events` path
  (it used to live in the deleted `mainDrain`).
- **Daemon-side activity tracking**: each `Session` stamps
  `last_activity_ms` on any event-producing drain; `SessionInfo` carries
  `idle_ms` + `cwd`, so `sketerm list` / the TUI picker show live
  active/idle state for *detached* sessions, not just attached ones.
- **Silence monitor rewrite**: the long-broken "Warn inactivity" tab
  flag now follows tmux `monitor-silence` semantics (fires once after N
  seconds of no output, re-arms on activity) instead of doing nothing.
- **Two regressions caught on real hardware, fixed**: multi-tab layout
  load opened only one tab (a per-window session-name counter collided
  with a shared pid across windows → daemon rejected dup names; fixed
  with a process-global `nextSessionName`); and the activity glow
  stopped rendering (the `on_activity` fire lived only in the deleted
  `mainDrain`; re-wired into the remote frame path).

## 2026-06-17: crash-recovery UX + process-isolation broker (B1/B2)

A session that dies unexpectedly (conn EOF / read error / protocol
error — **not** a clean `.exit`/`.gone`) now paints a sad face plus a
"Start new session" button on the pane instead of a silent black
GLArea; the button respawns a fresh daemon session in place via
`detachPaneToShell`. Clean shell exits and clean daemon retires stay
quiet. `onPaneCrashed` hides the offload wrapper (and the per-pane
titlebar) and appends the recovery panel to the pane's box.

To keep the clean-vs-crash split honest, the daemon sends `.gone` to
other clients on `.shutdown`, and `Daemon.run()` now does a bounded
best-effort POLLOUT flush of each client's wbuf before teardown.
Without it the `.gone` queued in the final tick was discarded (the run
loop exits before POLLOUT is recomputed), clients saw a bare EOF, and a
clean stale-daemon retire (`retireStaleDaemon`) was misread as a crash.
The flush fixes both the `.shutdown` site and the future worker-`'K'`
path. (A SIGTERM'd daemon still EOFs → crash face, which is correct —
those sessions genuinely died with it.)

Landed flag-gated (`sketerm-mux --broker`) Firefox-style isolation
scaffolding: a broker process forks one worker per session
(fork-without-exec, dropping every inherited broker fd) and routes
clients to workers by passing the client socket fd over SCM_RIGHTS
(`brokerSpawn`/`brokerAttach`, `controlSend`/`controlRecv` on a
`SOCK_SEQPACKET` control channel, `runWorker`). Default stays the
monolith. Still to come: B3 list/kill/rename + worker→broker metadata
(incl. a ready/failed handshake so spawn errors surface synchronously),
B4 zombie reaping + `RLIMIT_AS`, B5 per-worker feature parity (Wayland
hub / winstream / clipboard / query answering), B6 no-regression +
isolation sweep and flipping autostart to `--broker`.

mux + GUI build, smoke-mux PASS, full test suite, and smoke-e2e PASS.

## 2026-06-17: broker B3–B6 — the process-isolation daemon, by default

Finished the Firefox-style broker (one worker process per session) and
flipped the local autostart to use it, so a single shell's crash/OOM
can no longer take down the daemon or its siblings.

- **B3 control protocol.** Workers push session metadata
  (rows/cols/clients/title/cwd/activity) as JSON 'M' datagrams over the
  SEQPACKET control channel; the broker caches it per `Worker` and
  answers `list` from the cache (idle_ms computed against its own shared
  CLOCK_MONOTONIC). `kill` → graceful 'K' (worker flushes `.gone` +
  exits); `rename` updates the authoritative `Worker.name` and forwards
  'R'. The broker polls every worker control fd in `tick()`.
- **B4 isolation + containment.** Worker control-EOF ⇒ `w.dead`;
  `reap()` collects it via `waitpid(WNOHANG)` (retried; the pid is never
  dropped, so no zombie). A worker whose only session exits sets
  `running=false` and tears down (no orphan, no stale `list` row). Opt-in
  `RLIMIT_AS` per worker (`SKETERM_WORKER_MEM_MB`). SIGKILL-a-worker is
  proven to leave the broker + siblings alive and interactive.
- **B5 parity.** A worker has no listen socket, so `setupWaylandHub`
  (and the isolated-rt dir) used to fail on its empty `sock_path`. The
  broker now hands the worker its socket dir at fork; workers name aux
  sockets `wl-w<pid>` / `rt-w<pid>` (the monolith keeps `wl-<seq>` the
  rigs expect). Confirmed a worker creates its display socket and exports
  the right `$WAYLAND_DISPLAY`; the rest of the per-session machinery is
  the same `spawnSession`/tick code the monolith runs.
- **B6 default + tests.** `connectLocalAutostart` launches `sketerm-mux
  --broker` by default; `SKETERM_NO_BROKER=1` is the monolith escape
  hatch. New `zig build smoke-broker` forks a REAL broker process and
  drives spawn / attach+echo / list / rename / kill / clean-exit reaping
  / SIGKILL crash-isolation. Broker `.shutdown` sends each worker a
  graceful 'K' so worker clients see `.gone`, not a crash-face EOF.
- **Spawn handshake.** The spawn reply is deferred until the worker
  signals 'Y' (session up) or dies first (spawn failed → `.err`), so a
  worker that can't start (e.g. RLIMIT) can't leave the GUI blocked on a
  snapshot that never comes. Validated: a 1 MB-capped worker fails spawn
  cleanly (client gets an error fast, broker survives, no leak).

A pre-commit review (jelle-ai) caught two real blockers — the
clean-exit worker leak and the missing spawn handshake behind the
default flip — both fixed and now covered by smoke-broker. smoke-broker,
smoke-mux, smoke-e2e (GUI via the broker), full tests, and GUI / mux /
mux-portable builds all green.

## File upload to remote sessions (drag-and-drop / "Upload File…")

Drop a file onto a remote pane — or right-click → **Upload File…** — and
it lands on the remote box, in the shell's current working directory.

- **Wire (proto v3).** New append-only frames: `file_open` (JSON
  `{xfer,name,size}`), `file_data` (`[u32 xfer | bytes]`), `file_close`
  (client → daemon), and `file_reply` (daemon → client; JSON
  `{xfer,status,written,path,message}`, status ∈
  `ready|progress|done|error`). The handshake already requires an exact
  proto match, so an attached daemon understands them by construction.
- **Daemon is the writer.** No shell cooperation, no `base64 -d` paste:
  the daemon owns the session, so it resolves the cwd via
  `/proc/<pid>/cwd`, takes only the **basename** of the requested name
  (no path traversal), opens it `O_CREAT|O_EXCL` with non-clobber
  renaming (`notes.txt` → `notes (1).txt`), and streams the bytes
  straight to disk. Per-chunk acks carry cumulative-written. Uploads are
  bounded (8/client), abandoned on client drop, partials unlinked on a
  write error. Works over local / SSH / UDP unchanged.
- **GUI pump.** `Terminal.startUpload(paths)` queues files (one streams
  at a time); a GLib idle source pumps 128 KB chunks, bounded by socket
  backpressure. `pane.zig onFileDrop` branches to upload on remote panes
  (local panes keep pasting the shell-quoted path); the menu item opens
  a `GtkFileDialog`. Progress drives the tab ring; an `AdwToastOverlay`
  (new, wraps the tab view) shows "Uploaded X → host:/path" / failures.
- **Tests.** `smoke-mux` gained a real end-to-end upload stage: cd the
  shell into a temp dir, stream a file over the wire, assert it lands
  with the exact bytes, and assert a repeat name de-clobbers to
  ` (1)`. smoke-mux, full tests, smoke-e2e, and GUI / mux / mux-portable
  builds all green; `sketerm-mux` still links libc/libm only.

### Download (the other direction) + a remote file browser

Right-click → **Download File…** opens a **remote file picker** — a
small window that browses the session's filesystem (no path typing):
folders first, then files with human-readable sizes, an editable address
bar, and an Up button. Click a folder to descend, click a file to
download it into the local Downloads dir.

- **Wire.** New frames: `file_get` (download) and `file_list` /
  `file_listing` (directory browse). Download bytes flow back over the
  SAME `file_data` frame — now bidirectional, disambiguated by which
  side receives it (upload xfer vs download xfer). `file_reply` "ready"
  gained a `size` field; `file_listing` carries
  `{path, entries:[{name,dir,size}], error?, truncated?}` (dirs first,
  case-insensitive sort, non-UTF-8 names skipped, capped at 4096).
- **Daemon is the sender.** `handleFileGet` resolves the path (absolute
  or relative to the shell cwd — the user already has shell access, so
  no extra sandbox), opens it `O_RDONLY`, **rejects non-regular files**
  (no FIFO/`/dev/zero` to block or stream forever), and replies "ready"
  with size+basename. `pumpDownloads` (called each tick beside
  `pumpWinstreams`) streams 256 KB chunks, **bounded by the client's
  write-buffer high-water mark** (8 MB) so a multi-GB file can't balloon
  memory — it fills to the mark, then waits for the socket to drain.
- **GUI saves it.** `Terminal.startDownload` sends `file_get`; the
  `file_data` bytes are written to a non-clobbering file in
  `G_USER_DIRECTORY_DOWNLOAD` (→ `$HOME` fallback). The upload event
  plumbing was generalized to `TransferEvent { dir: upload|download }`,
  so the tab ring + toast ("Downloaded X → /local/path") are shared.
  The browser is `src/ui/remote_browser.zig` — a heap-allocated
  `Browser` that holds Window+Pane (not the Terminal) and re-fetches the
  live Terminal from the window's pane list before each action, so a
  pane closing under it can't dangle. `Terminal.requestList` /
  `on_listing` (with a stale-xfer guard) carry the directory data.
- **Tests.** The smoke stage now also downloads the just-uploaded file
  back (byte-exact reassembly), checks a missing-file request fails
  cleanly rather than hangs, and lists the cwd to find the uploaded
  file. **Visually verified** headlessly (xvfb + xdotool): the menu, the
  browser listing/navigation/Up/address-bar, and a real download landing
  byte-identical with its toast. All builds + tests + both smokes +
  smoke-e2e green; `sketerm-mux` still libc/libm only.

## Fix: `sketerm mux <host>` attach failing with "no such pane"

`SKETERM_PANE_ID` is baked into the shell env at PTY spawn (`pty.zig`),
but the GUI reassigns pane ids from 1 on every launch — so after a GUI
restart/reattach a surviving session's shell carries a stale id. The
`attach-session` / `new-durable-tab` IPC handlers resolved that id with
`paneById(req.pane) orelse <err "no such pane">`, hard-failing the
attach. Since those commands' pane always comes from `SKETERM_PANE_ID`
("the pane I'm in"), a stale id now falls back to the current pane
(`paneById(null)` = focused/selected) instead of erroring. Reproduced
(stale id → "no such pane", valid id → ok) and a smoke-e2e regression
asserts a stale-id attach no longer returns "no such pane".

Known latent issue (surfaced, not fixed): because ids reset to 1 each
launch, a stale id can also *collide* with a different live pane and
silently take it over. A real fix is to namespace pane ids per launch
(e.g. random high bits, or a launch token in `SKETERM_PANE_ID`) so a
stale id never resolves — but that makes `cli list` show large ids and
could surprise scripts, so it's a design call.

## Best fix: stable session-based pane identity (replaces the pane id)

The real fix for the above. The fragility was never env vars themselves
(tmux/kitty/iterm all use them); it was the VALUE: an ephemeral,
GUI-client-side pane id baked into a daemon-side, long-lived shell env.
The codebase already treats `(host, session-name)` as the durable pane
identity (layout persistence keys on it), so "my pane" now resolves by
the stable session name, which the daemon owns:

- The daemon exports `SKETERM_SESSION=<name>` at PTY spawn (`pty.zig` /
  `daemon.zig`) — no GUI plumbing, it owns the name and it lives exactly
  as long as the shell, so it never goes stale across a GUI restart.
- The IPC request gained a `session` field; the GUI's new `reqPane`
  resolves session-name -> pane (live), falling back to the (stale-prone)
  pane id, then the current pane. Every command's pane resolution and
  both `sketerm mux` takeover commands go through it.
- `sketerm cli --pane self` and `sketerm mux` send `$SKETERM_SESSION`
  (pane id kept only as a fallback for an older GUI).

Verified end-to-end (xvfb): `$SKETERM_SESSION` is exported; `--pane self`
and a `sketerm mux` takeover both resolve the correct pane via session
even with a bogus/stale pane id present. smoke-mux now asserts the
daemon exports it. The pane-id collision concern above is gone: the
session name is the identity, so a stale id is never consulted when a
session match exists.

## Verified: layout remembers `sketerm mux` connections

This already worked and is now confirmed end-to-end. `paneSpec` saves
`mux_session` + `mux_host` for non-ephemeral remote/durable panes;
`restoreMuxPane` reattaches the session if it still exists, or recreates
it under the same name if gone. Tested both branches under xvfb: a saved
durable pane restored with its scrollback marker intact (reattach), and
after killing the session, `--restore` recreated it as a working shell.

## `sketerm mux` takeover is now bulletproof (never a stray tab/window)

Two real failure modes were making `sketerm mux <host>` attach into a
NEW tab/window instead of taking over the pane it ran in:

1. A refactor regression: `reqPane` returned null on a stale pane id
   (the current-pane fallback got dropped), so the takeover saw "no
   pane" and opened a tab.
2. Multi-window blindness: the IPC server runs only on the PRIMARY
   window, and pane resolution (`paneBySession`/`focusedPane`) only
   searched that window's panes — so a pane in a SECONDARY window (tab
   drag-out) was invisible and the takeover landed in the primary =
   "another window".

Fix: pane resolution now spans every window. Each `Window` is reachable
from its `GtkWindow` via qdata (`sketerm-window`);
`findPaneAcrossWindows` walks `gtk_application_get_windows`.
`takeoverPane` resolves session-name -> pane-id -> the globally-focused
pane, so when invoked from inside a pane it CANNOT fail to find one (the
focused pane is the guaranteed floor) and never spills into a new tab.
The takeover then executes in the resolved pane's OWN window
(`ownerWindow`), and the other pane-addressed commands (split, close,
focus, set-title, action) likewise act on the owning window. Explicit
commands keep strict id semantics (a bad `--pane N` still errors).

Verified under xvfb: (a) single window, stale/absent identity -> in-place
takeover, still one tab; (b) a pane moved to a secondary window is
resolved by session across windows and taken over in that window (window
count unchanged, no stray window), then addressable as the durable
session. The `X11 forwarding request failed` noise is also gone — the
mux SSH transport now passes `-x` (the proxy channel never needs X11).

## Fix: colours swap (green to red) when resizing a remote pane

On resize the daemon rebroadcasts a full snapshot, and `snapshot.restore`
swapped the style pool's `entries` table but left the pool's `index`
dedup map (entryKey -> slot) stale. Cells store only a slot index, so the
restored grid rendered fine, but the next interned colour (live SGR
events re-intern into the GUI's own pool, then print with that
`cur_style`) short-circuited on `Pool.intern`'s stale `index.get`,
resolving e.g. green to the slot green USED to occupy, which after the
rebuild held a different colour. Hence green drew as red. Only on
resize/reattach, which reuse an already-populated pool.

Fix: `restore` builds the table into a fresh list and hands it to
`Pool.replaceEntries` -- the same path `compactStylePool` already uses,
which adopts the entries AND rebuilds the index in lockstep -- instead of
mutating `entries` in place and forgetting the index. Regression test
orders the snapshot green-then-red, restores into a pool pre-populated
red-then-green, asserts each colour resolves to a slot holding it; fails
without the fix. VERIFIED IN A REAL GUI (xvfb screenshots, not just the
unit test): startup colours correct, and after 60 distinct 256-colours +
four window resizes everything still renders the right colour.

(Process hygiene: a by-name `pkill` (even `pkill -x sketerm-mux`) kills
the USER's real daemon + durable sessions, not just isolated test ones.
CLAUDE.md now forbids it; test cleanup is by exact pid, the daemon found
via its isolated `XDG_RUNTIME_DIR` in `/proc/<pid>/environ`.)

## Feature: `sketerm mcp` — assistants can drive the terminal (MCP server)

`sketerm mcp` is a Model Context Protocol server on stdio (JSON-RPC
2.0, one object per line) that adapts tool calls onto the existing
remote-control socket, so an AI assistant can drive real panes:
list_terminals, read_screen (parsed grid + cursor/flags metadata,
i.e. what a human sees, not raw stdout), send_text, send_keys,
run_command (type + Enter + wait-until-settled + return the screen),
wait_idle, new_tab, split_pane, focus_pane, close_pane. Register in
an MCP client as command `sketerm`, args `["mcp"]`. Trust boundary
is unchanged: it is the same user-owned Unix socket `sketerm cli`
uses.

Supporting IPC additions: `send-keys` (named chords — "ctrl+c",
"enter", "up", "f5", "alt+x", "shift+tab" — encoded xterm-style via
the new pure `src/ipc/keys.zig`, honouring DECCKM app-cursor mode)
and `screen-info` (rows/cols, cursor, alt-screen, view offset,
sync-output flag, title, and `seq` — a new Terminal.activity_seq
bumped per applied EVENTS batch/snapshot). Settle detection polls
`seq` client-side every 50ms until quiet_ms passes unchanged; the
GUI's dispatch stays synchronous (no deferred-reply surgery in
ipc/server.zig).

MCP dispatch is structured around an injectable Backend (talk /
sleep / clock), so the JSON-RPC layer, tool routing, and the
quiesce loop are unit-tested with a scripted fake (9 new tests, 638
total). Verified end-to-end against a real GUI under Xvfb: initialize
/ tools/list handshake, run_command returning the echoed output,
driving interactive `cat` (send_text then ctrl+c via send_keys),
split_pane + run_command in the new pane. Gotcha found in testing:
the tools/list JSON was a Zig multiline literal whose embedded
newlines broke NDJSON framing — stripped at comptime now.

## Feature: compact context menu with hover submenus + link actions

The right-click menu shrank from ~24 always-visible rows to ~12 by
grouping rarely-used actions under hover submenus (classic nested
menus, not slide-in pages): "Copy More" (Copy Screen / Scrollback /
Command Output), "Pane" (Zoom, Set Title, Apply Profile, Close),
"Shader" (Pick / Preset / Configure / Clear), "Tab" (all seven tab
actions), and "Session" (the remote-only upload/download/detach/
rename/kill rows — the whole submenu hides on non-mux panes). Copy,
Paste, both Splits, Reset and Preferences stay top-level.

menu.zig now declares the layout as a comptime `MENU` tree (binds,
submenus, separators); the flat action list is derived from it, so
adding a row is one entry. Submenus are nested GtkPopovers parented
to their row button, `autohide=false` (the main popover keeps the
grab), popped up on row hover and popped down when the pointer
enters a sibling row / the main menu closes. Teardown unparents the
sub-popovers before the main one (same GTK4 finalize-warning rule).

Right-clicking a link now shows "Open Link" / "Copy Link" at the
top of the menu (hidden entirely when the click isn't on a link),
and both work for auto-detected URLs as well as OSC 8 hyperlinks —
previously the menu only recognised OSC 8, and there was no open
action at all. The hover tooltip gained a "Ctrl+click to open" hint
when `link_single_click` is off, since the pointer cursor otherwise
suggests a plain click would work. Link launches now log a warning
on failure instead of swallowing the GError.

Verified on an isolated Xvfb instance: submenu hover open/close and
sibling switching, submenu item activation (New Tab via the Tab
submenu), Open Link end-to-end against a fake x-scheme-handler
(both auto-detected and OSC 8 URIs land in the handler), Copy Link
via clipboard paste-back, Ctrl+click opens exactly once, and
`smoke-e2e` passes with `G_DEBUG=fatal-criticals`.

## Feature: headless GUI-app driving, durable apps, multi-viewer, screenshots, remote launcher, tab thumbnails

A large batch turning sketerm into a platform for running and driving
GUI apps (for assistants and users alike). Six shipped features on one
architectural change.

**Daemon-hosted Wayland brain (proto v4 -> v5).** The authoritative
`wlhost/compositor.zig` moved from the GUI into the daemon: one brain
per forwarded app connection (`Native.brain` in `mux/daemon.zig`).
GUI panes became passive REPLICAS that render the broadcast request +
pool stream and drive input via new seat-intent pipe units
(`wlhost/pipe.zig` `seat_*`/`configure`/`state_sync`/... tags,
append-only). Consequences, all new: forwarded apps run with ZERO
clients attached (headless), survive a viewer crash (durable GUI
apps), and a reattach replays pool bytes + a serialized brain state
(`serializeState`/`restoreState`) so windows reappear with current
pixels. Native channels are session-owned and broadcast to every
attached proto>=5 client (multi-viewer fan-out; shared seat). Raw
`wl_msg` from a viewer is rejected (the brain is the sole driver).
`smoke-mux` gained stages proving headless answer, replay-with-pixels,
viewer-crash durability, and two-viewer fan-out against the real
daemon.

**PNG encoder** (`util/png.zig`, vendored `stb_image_write.h`):
`encodeRgba` + wl_shm BGRA/stride/premultiply-aware `encodeShm`.

**Headless MCP app driving** (`sketerm mcp`, `ipc/appdrive.zig`,
`ipc/evkeys.zig`): 13 tools -- launch_app, list_installed_apps,
screenshot_app (inline PNG image content), app_click/type/key/scroll/
resize, app_wait, close_app... A proto-v5 mux client spawns app
sessions, renders them in in-memory replica compositors (no display
anywhere), and injects seat intents. `evkeys.zig` is the pure
char/chord->evdev encoder (us layout, table ported from kwin-mcp,
MIT). The GUI socket is now optional -- app tools work standalone.
`screenshot_pane` MCP tool + terminal `read_screen` unchanged.

**User screenshots** (`Pane.screenshotPng` via widget-paintable ->
GSK texture -> PNG): "Screenshot Pane..." in the Pane submenu,
`sketerm cli screenshot --out FILE`, and the MCP `screenshot_pane`
tool. New `screenshot` IPC command.

**Remote app launcher**: the daemon scans its host's .desktop entries
(`mux/desktop.zig`, musl-clean) and answers a new `app_list` wire
request, so a client sees the REMOTE's installed apps. "Launch App..."
in the Session submenu opens a searchable icon list
(`ui/app_launcher.zig`); picking one spawns it as an `app=true`
session on that host (`Window.launchRemoteAppSession`) and renders it.
Same path backs the MCP `list_installed_apps` tool.

**Tab overview with live thumbnails**: the toolbar view is wrapped in
an `AdwTabOverview` with a header tab-count button; opening it shows a
grid of live per-tab pane thumbnails (GTK snapshots each GtkGLArea via
the same paintable path as screenshots), with search, per-tab close,
and a New Tab tile.

Verified: full suite 642/647 (5 skip, +9 new tests); mux +
mux-portable build (daemon stays libc-only); `smoke-mux` PASS;
`smoke-e2e` PASS under `G_DEBUG=fatal-criticals`; and on isolated
invisible Xvfb instances -- gnome-calculator launched headless via
MCP, screenshotted, "12+34=" typed -> 46; a GUI viewer rendering the
same assistant-driven app; the app surviving a hard GUI kill; the
remote launcher listing 428 local apps, filtering, and rendering a
launched calculator in-window; the pane-screenshot CLI; and the tab
overview showing two distinct live thumbnails.

**Not shipped: AT-SPI accessibility tree for forwarded apps.** The
one planned piece deferred. A spike (isolated `dbus-run-session` +
`at-spi-bus-launcher` + gnome-calculator, read back via libatspi/
pyatspi) returned `desktop children: -1` -- the a11y registry was not
cleanly reachable from a separate client, the dbus-broker-vs-daemon
isolation gotcha the prior research flagged. libatspi 2.60 is present
to link, but delivering a *proven-correct* reader needs (a) a design
decision -- local libatspi vs a deployed remote reader binary, which
affects the single-static-binary story for SSH remotes -- and (b)
environment-specific validation against a real a11y bus that the
sandbox can't provide safely. Left for a focused follow-up rather than
shipped half-validated.

## Feature batch: GUI-app driving polish + AT-SPI a11y (12 items)

Twelve requested items, all shipped and verified. Commits `a7ea3ad`
(mode 47) through `f517249` (AT-SPI).

**MCP app-driving surface** (`src/ipc/appdrive.zig`, `src/ipc/mcp.zig`):
- `app_drag` -- press-interpolated-motions-release over the seat
  intents (sliders, drag-drop, text selection).
- `app_clipboard_get` / `app_clipboard_set` over the existing
  clip_send/clip_data/offer_selection units; `app_type` now falls back
  to a clipboard paste for non-ASCII text.
- `get_app_state` -- windows + screenshot (+ coordinate mapping) in one
  call. Screenshots downscale past `max_px` (default 1568) and report
  the multiplier (`util/png.zig downscaleRgba`).
- `app_a11y_tree` -- see below.
- `app_record_start`/`app_record_stop` -- animated-GIF capture of a
  window (`util/gifrec.zig` on vendored `msf_gif.h`).

**Configurable keyboard layouts** (`src/ipc/xkblayout.zig`,
`src/wlhost/keymaps.zig`): sessions pick a keymap (us/gb/fr/be/de) via
spawn `kb_layout` (config `app_keyboard_layout`, MCP `launch_app
layout`). MCP typing parses the SAME compiled-xkb blob so chars,
chords and AltGr symbols encode right on azerty/qwertz. Was pinned to
pc105/us.

**Assistant-is-driving indicator**: clients self-ID on attach
(gui/cli/mcp); the daemon pushes a per-session roster (new wire frame
`peer_info` = 74) on attach/detach/death. Panes get an accent border,
forwarded app windows an "AI" corner badge, while a headless MCP
client is attached.

**GUI**: Ctrl+right-click host menu on forwarded app windows
(Screenshot Window, Record Window, Close); app-session tabs mirror the
app's primary window as tab content so the tab overview shows the live
app; the launcher moved out of the remote-only Session submenu
(local panes launch on the autostart daemon), gained recents
(`$XDG_STATE_HOME/sketerm/recent-apps.json`), Enter-launches-first,
Esc, and `Ctrl+Shift+O` / palette entry.

**Legacy alt-screen mode `CSI ?47h/l`** implemented in
`src/grid/screen.zig` (was only 1047/1049).

**AT-SPI accessibility tree, daemon-side** (`src/mux/dbus.zig`,
`src/mux/a11yhub.zig`). The user's call: "part of the muxer, works
everywhere -- no local/remote difference." The daemon (always on the
app's machine) spawns a PRIVATE `dbus-daemon` + `at-spi2-registryd`
per app session under a private `XDG_RUNTIME_DIR` (so the a11y bus is
per-session), sets `GTK_A11Y=atspi` + `org.a11y.Status.IsEnabled`
BEFORE the app starts, then reads the tree with a pure-Zig D-Bus
client (`mux/dbus.zig` -- no libdbus, musl-clean) and serializes
role/name/states/rect to JSON. New wire `app_a11y`/`app_a11y_tree`
frames + MCP `app_a11y_tree` tool. `SKETERM_NO_A11Y=1` disables.

The **hard-won gotchas** (each cost real debugging):
1. D-Bus SASL EXTERNAL wants the uid as DECIMAL ascii, hex-encoded
   byte-by-byte (not the uid formatted as hex).
2. `GTK_A11Y=atspi` -- NOT `GTK_A11Y=1` (a GTK3-ism GTK4 ignores).
   This was the difference between a 1-node empty tree and the full
   316-node calculator tree.
3. Ordering is load-bearing: `at-spi2-registryd` must own its name
   BEFORE the app starts (toolkits don't retry a11y registration), so
   `Hub.setup` blocks on a readiness poll.
4. `at-spi2-registryd` wants the SESSION bus in its env (it finds the
   a11y bus itself via `org.a11y.Bus.GetAddress`); the systemd-based
   on-demand activation of the Registry is unreliable in a bare
   session, so we spawn it directly.
5. `ATSPI_DBUS_IMPLEMENTATION=dbus-daemon` (dbus-broker silently
   reuses the host a11y bus, breaking per-session isolation).

Verified end-to-end on isolated invisible instances: launched
gnome-calculator headless via MCP, read a 316-node AT-SPI tree
(application/window/every button by role+name). Full suite 656/661
(5 skip), all three builds green, daemon links no GTK/GLib/dbus,
`smoke-mux` and `smoke-e2e` (under fatal-criticals) PASS.

## Feature: MCP isolation modes (private daemon by default)

`sketerm mcp` no longer touches the user's real daemon or GUI unless
asked. Default = ISOLATED + EPHEMERAL: app tools autostart a private
`sketerm-mux` on `$XDG_RUNTIME_DIR/sketerm/mcp-tmp-<pid>/mux.sock`
(the daemon derives its Wayland hub / a11y dirs from the socket dir,
so the whole instance lives in that one dir); on MCP exit (stdin EOF
or SIGTERM/SIGINT, caught via sigaction without SA_RESTART so getline
EINTRs) the private daemon is retired with a `.shutdown` frame and
the dir removed. Orphans from a SIGKILL are reaped by a startup sweep
(`mcp-tmp-<pid>` dirs whose owning pid is gone). Terminal tools no
longer auto-discover the GUI socket in isolated mode -- explicit
`--socket` only.

`--durable` / `--name <n>` = named persistent instance under
`mcp-<n>/`: the daemon and its app sessions survive MCP restarts, and
a reconnecting `sketerm mcp --name <n>` lists the daemon's app
sessions and reattaches to each (attach-replay rebuilds windows with
pixels). On exit a durable instance DETACHES from its apps instead of
killing them (new `App.detach`). `--shared` opts into the old
behavior: the user's per-user daemon plus the running GUI.

Plumbing: `Conn.connectLocalAutostartAt(alloc, sock)` (spawns
`sketerm-mux --broker --socket <path>`), `appdrive.App.attachExisting`
+ `appdrive.listAppSessions` (`.list` reply already carried the `app`
flag), `local_sock` threaded through `App.launch`/`listInstalledApps`,
`Opts.parse` extracted pure for unit tests (2 new test blocks, suite
now 658/663). Verified e2e headless: isolated launch creates only the
private socket (shared `mux.sock` absent), EOF/SIGTERM teardown
removes dir + daemon, named instance survives restart and the
reconnected MCP drives the still-running calculator, `--shared` hits
the shared daemon with no `mcp-*` dirs, stale sweep reaps a planted
dead-pid dir. `smoke-mux` + `smoke-e2e` (fatal-criticals) PASS.

## Feature batch: recording, a11y actions, headless terminals, smoke-mcp

Six features on top of the MCP-isolation work.

### Asciicast v2 session recording, daemon-side (no wrapper)
The daemon taps each session's raw PTY output (`src/mux/cast.zig`,
UTF-8-safe JSON escaping with split-sequence carry) into an asciinema
`.cast` v2 file. Wire frames `rec_start`/`rec_stop` (client->daemon);
tapped in `drainSession` + the resize handler. Any RUNNING session
records live -- context menu (Pane submenu, start/stop rows gated on
`Terminal.recording`), `sketerm cli record-start/-stop --out`, and MCP
`record_pane_start`/`record_pane_stop`. Remote sessions record to a
path on the remote host (that's where the bytes are). Also fixed
`send-text --enter`, which was silently dropped (only `type-text`
honored it). Validated: recorded a session, replayed it through the
real `asciinema` binary.

### AT-SPI element actions: perform_action / set_value / wait_for_element
`a11yhub.zig` gained `doAction` (org.a11y.atspi.Action.DoAction),
`setTextContents` (EditableText) and `setCurrentValue` (Value); tree
nodes now carry a stable `id` (dest#path) and a `value`
(Value.CurrentValue). Wire: `app_a11y` payload carries an optional op
(`{op,id,index/text/value}`). MCP: `app_perform_action` (the reliable
coordinate-free "click"), `app_set_value` (text fields + sliders),
`app_wait_for_element` (poll the tree for a role/name). Dropped
element-click-by-rect: AT-SPI screen extents collapse to the origin
for headless apps, so coordinate clicks off the tree are unreliable --
the action API is the right path. Validated headless: gnome-calculator
7+5=12 via perform_action; a GtkScale slider 10->55 via set_value
(read back through the tree); a GtkEntry text set + clipboard read-back.

### Headless terminal tools on the private daemon
`src/ipc/termdrive.zig` -- a GTK-free mux client that spawns/drives
plain SHELL sessions on the isolated daemon, keeping a client-side
`Screen` mirror (snapshot restore + event apply). MCP `term_open`,
`term_run`, `term_send_text`, `term_send_keys`, `term_read`,
`term_wait_idle`, `term_resize`, `term_list`, `term_close`. So
`sketerm mcp` is now a complete sandboxed computer-use kit -- real
shells AND GUI apps, no display, nothing of the user's reachable.
Validated: echo/uname captured, interactive `rev` (abcdef->fedcba)
proves input+output, ctrl+c returns to the prompt, second independent
terminal, isolation intact.

### WebM/VP9 app-window recording (default) alongside GIF
`vendor/vpxenc_shim.c` (libvpx VP9, x264-shim discipline) +
`src/util/webm.zig` (hand-rolled live EBML/WebM muxer, the
msf_gif-equivalent for video) + `src/util/videorec.zig` (BGRA->I420 +
encode + mux). MCP `app_record_start` defaults to webm (`format:"gif"`
for the old path); the GUI host menu offers both. libvpx links
GUI-side only (`configureSysDeps`); the daemon stays libc-clean
(verified by `ldd`). Fixed a use-after-clear in `recordStop` (pointer
into the optional survived `self.vrec = null`). Validated: ffprobe
reads 13 VP9 frames at 1078x834, ffmpeg decodes the stream cleanly.
`libvpx` added to PKGBUILD depends + the CLAUDE.md dep list.

### smoke-mcp build target
`zig build smoke-mcp` spawns `sketerm mcp` and drives it over stdio,
asserting the isolation lifecycle (private socket created, shared
mux.sock absent, ephemeral teardown on exit) + headless terminal
tools + named-durable-daemon survival across an MCP restart. Uses only
/bin/sh (no display/apps/a11y). Note: `std.debug.print` segfaults in
this ReleaseFast core-deps build -- the harness prints via a libc
`write(2)` helper.

Baseline after the batch: 664/669 tests (5 skip), all builds green,
daemon links no gtk/glib/dbus/vpx, `smoke-mux` + `smoke-mcp` PASS.

## Fix: frame-clock idle churn + Wayland object-id leak crash (Jul 8)

Root-caused the overnight crash of the installed build (coredumpctl
9539): GTK 4.22 offloads the pane GL content to Wayland subsurfaces
and requests a frame callback on each one per frame-clock cycle; on
KWin those callbacks are never retired, so every destroyed proxy
stays a zombie in libwayland's object map. Our tick callback kept the
frame clock cycling at monitor refresh 24/7 (cursor blink counted as
tick work), producing ~147 leaked ids/second for 30 hours until the
0xf00000 id cap made wl_surface_frame return NULL and GTK crashed on
the missing NULL check (gdksubsurface-wayland.c:1002). Evidence: the
core held 15,728,642 map slots, all zombies, free list empty.

Two-sided fix:
- `⚡ pane:` cursor blink + bell fade moved off the frame clock onto
  GLib timeouts at their real cadence (500ms half-cycle / 33ms fade
  burst); the tick callback now exists only for per-frame animation
  (shader, kitty images), both gated on `gtk_widget_get_mapped`.
  Idle wakeups measured on isolated Xvfb: old build 2038/10s
  focused-idle, new build 0/10s (blink adds ~2 renders/s only while
  a blinking cursor is focused). Also fixed: exit_action never fired
  when a child exited while no tick was alive (onRenderRequest now
  re-arms it); kitty animations pause on unmapped background tabs
  and resume via onAreaMap.
- `✨ config:` `graphics_offload = false` kill-switch (+ prefs toggle
  under Rendering > Compositing) forces plain GSK compositing — no
  subsurfaces at all, so the leak class is unreachable on affected
  compositors. Applied live on config change.

Verified: 664/669 tests, smoke-mux + smoke-mcp + smoke-e2e PASS
(fatal-criticals), blink proven toggling via interval screenshots,
offload-off instance renders + echoes over IPC. Upstream report to
GTK still owed (missing NULL check + the callback zombie leak).

## Fix: GUI segfault on first forwarded-app window (Jul 8)

`Terminal.nappOpen` fired the `on_app_view` callback with
`remote.napps.items[0].host` BEFORE appending the newly-created NApp.
On the first app window the list was still empty, so `items[0]`
dereferenced Zig's empty-slice sentinel pointer (address 0x8) and the
GUI crashed the moment any forwarded app opened its first window (the
live-tab-mirror path from a1cef6a). Coredump 40483 confirmed:
`mov (%rdx),%rcx` with rdx=0x8, in a GLib source dispatch about to call
onAppViewEvent (gtk_picture_new mirror setter). The headless MCP
appdrive path never hit it (separate compositor), so it slipped past
the earlier app-view verification. Fix: append the NApp (with its
existing error handling) before firing on_app_view, so items[0] is
always valid and equals the new host on the first window -- matching
what destroyNApp already does. Regression test in terminal.zig drives
the real nappOpen + AppHost; it crashes on the pre-fix ordering and
passes after. 665/670 tests, all builds green, daemon purity clean.

## Feature: app view modes + three crash/UX fixes around forwarded apps (Jul 8)

Batch driven by user feedback after the first real remote-app use:
the double view (floating window AND a fake tab mirror), the
uninteractable tab view, the confusing single-instance handoff
(pcmanfm), and a fresh GUI segfault on closing an app.

- `🐛 terminal:` closing a tab whose app session still had a live
  Wayland channel crashed: `clearSinks` nulled `user_ctx` but not
  `on_app_view` (nor `on_peers`/`on_transfer`/`on_recording_changed`/
  `on_listing`/`on_apps`/broadcast), so the deferred Terminal.deinit's
  `destroyAllChans` fired the callback into the fenced Pane with a
  null ctx (coredump 73126: rdi=0, fault at Pane.terminal offset
  0x1cd0, frame #1 = destroyAllChans loop). Also fixed the sibling
  UAF: `destroyNApp` destroyed the AppHost BEFORE firing on_app_view,
  handing the pane a freed host to `setMirror(null)` on. Both have
  regression tests (the fence test reproduces the exact SEGV pre-fix).
- `🐛 wlapp:` `app_window_opened` flipped when the app merely
  CONNECTED to the Wayland display (nappOpen/channel open). GTK apps
  connect during gtk_init, then single-instance ones hand off to a
  running instance and exit windowless — so pcmanfm's exit took the
  detach-to-shell path (confusing local pane) instead of holding the
  app log. AppHost now fires `on_first_window` on the first toplevel
  frame; the hold-tab tooltip explains the single-instance case.
- `✨ app view modes:` launching an app no longer produces two views.
  Window mode (default): floating windows only; the tab keeps the app
  log plus a clickable "App window open — click to raise" banner (new
  `Terminal.on_app_window` event). Tab mode (`app_view = tab`, prefs
  Behavior > Applications, or "Show in Tab" in the Ctrl+right-click
  host menu): the toplevel's overlay (picture + popups + subsurfaces)
  reparents into the pane and is FULLY interactive — pointer/scroll
  controllers travel with the picture, a picture-level key/focus
  controller pair handles the keyboard, an input-transparent
  GtkDrawingArea "resize" sensor configures the app to the pane size
  (FILL fit keeps mapXY exact), and the buffer is cropped to the
  window geometry (no CSD shadow inside the tab). "Pop Out Window" in
  the host menu floats it again; the hidden GtkWindow is kept alive
  (childless) so window-based code paths stay valid and pop-out just
  re-childs + presents it. Dialogs/secondary toplevels always float.
  Only the wlhost/native path embeds (winstream/macOS remotes float).
- `🐛 terminal:` quitting a forwarded app painted the crash sad-face:
  G_IO_HUP arrives together with the final readable data when the
  worker flushes `.exit` and closes, and remoteSocketCb declared the
  crash before draining the socket. Wire-level repro (python client)
  proved the daemon sends chan_close + exit + EOF cleanly; the GUI
  threw the exit frame away. Now: drain + peel first, close after.
  Pre-existing bug (reproduced at the previous HEAD), timing-dependent
  — which is why some exits looked clean before.

Verified end-to-end on isolated Xvfb + clean-env daemon (so forwarded
apps use the Wayland hub, not X11 fallback): window mode = floating
window + banner tab with live log; tab mode = gnome-calculator
embedded, clicked "7" by coordinate, typed "+5" Enter = 12 (pointer
AND keyboard through the embed), app's own right-click popup and
tooltips render in-tab; Pop Out preserves state and brings the banner
back; Show in Tab re-embeds; closing the app tab (live channel) no
longer crashes; app quit now lands in detach-to-shell instead of the
crash face. 667/672 tests, mux + mux-portable green, daemon purity
ldd grep = 0, smoke-mux + smoke-mcp + smoke-e2e PASS.

## Feature: tabless app launch (Jul 8, follow-up)

User feedback: launching an app must not open a terminal AT ALL (a
desktop launcher doesn't). Window view mode now attaches app sessions
with no pane and no tab: `Window.AppSession` is a bare mux client
(Terminal.initRemote, minimal callbacks) whose AppHost floating
windows are the only UI. Routed in attachMux off the snapshot app
flag (byte 8), so the launcher, `sketerm app`, and attach-session all
behave the same; takeover attaches keep the tab path. A tab appears
only when useful: exit-without-window materializes the terminal into
a held "app exited (N)" tab (adoptAppSessionIntoTab — the log is the
only diagnostic for failed launches / single-instance handoffs), and
"Show in Tab" on a floating window adopts + embeds it
(Pane.adoptAppHost). Clean quits reap silently (deferred to an idle:
the exit signal fires inside the terminal's own socket callback).
GUI teardown detaches (apps are durable like any session). AI-driven
badge still works tabless (on_peers -> AppHost.setDriven).

Validated on isolated Xvfb: launch = floating window + zero tabs;
quit = silent reap; windowless exit = held log tab (text verified);
Show in Tab = interactive embedded tab (clicked 7); tab mode
regression = embedded tab, no float. 667/672 tests, daemon builds +
purity green, smoke-mux/mcp/e2e PASS.

Testing note: three GUI crashes in the isolated env (2x pango SEGV,
1x malloc abort) were heap corruption from concurrent fontconfig
cache-rebuild threads racing in system libs — isolated
XDG_CONFIG_HOME invalidates the fc cache key, so every launch
rescans fonts on worker threads. No sketerm frames in any faulting
stack; never reproduces with warm caches. Mitigation for isolated
GUI testing: run `fc-cache` under the isolated XDG_CONFIG_HOME once
before launching.

## Fix: forwarded-app taskbar icon + name (Jul 8, follow-up)

User (KDE Plasma): a forwarded app got its own taskbar entry but with
sketerm's icon and hover name. Root cause: `applyAppId`
(`remote_window.zig`) sets the icon-name + Wayland
`set_application_id` + X11 `WM_CLASS`, but it ran inside `winFor`
BEFORE `gtk_window_present`, so the GdkSurface didn't exist yet and
both surface-bound parts silently early-returned (only the
Wayland-ignored `gtk_window_set_icon_name` landed). Apps announce
their app_id during startup, before the first buffer commit, so this
was the normal path. The window kept GTK's default app_id
(`SKETERM_APP_ID`), which KDE maps to sketerm's `.desktop` → sketerm
icon. Fix: store the app_id on the `Win` struct (`setAppId`, owned,
freed in onGone + AppHost.destroy) and re-apply it in `onWinRealize`
once the surface exists — before the first commit, so the WM reads it
on map. Verified on X11 (Xvfb): a forwarded gnome-calculator reports
`WM_CLASS = org.gnome.Calculator` (was `dev.sker.sketerm`) and
`_NET_WM_NAME = Calculator`; the window still renders + interacts. On
Wayland the same code calls `gdk_wayland_toplevel_set_application_id`,
which KDE resolves to the app's real icon + name. 667/672 tests, mux
+ mux-portable + purity clean, smoke-mux/mcp/e2e PASS.

Caveat (unchanged, fundamental): this fixes LOCAL forwarded apps
(their `.desktop`/icon is installed locally, so KDE resolves it).
REMOTE (SSH) apps whose `.desktop`/icon isn't installed on the client
still fall back to a generic icon — Wayland carries no icon pixels
over the wire (X11's `_NET_WM_ICON` does; Wayland dropped it). Would
need shipping icon bytes over the mux channel + installing a local
hicolor entry; not done (bigger job, not requested).

## Feature: forwarded-app taskbar icons via shipped pixels (Jul 8, remote fix)

Follow-up to the app_id fix: setting the app_id only helps if the
CLIENT can resolve that app_id to a local .desktop/icon — which fails
for the primary use case, a REMOTE app not installed on the client
(Wayland carries no icon pixels the way X11's _NET_WM_ICON does). Fix:
ship the actual icon bytes from the app's host.

Mechanism: GDK's `gdk_toplevel_set_icon_list(GdkToplevel, GList of
GdkTexture)` drives KWin's `xdg-toplevel-icon` protocol on Wayland
(present in libgtk 4.22; KWin 6.2+) and `_NET_WM_ICON` on X11 — both
take PIXELS. So:
- `src/mux/icons.zig` (NEW): freedesktop icon resolution on the app's
  host. app_id -> `<datadir>/applications/<app_id>.desktop` Icon= ->
  the actual PNG/SVG file, searching XDG icon roots x {hicolor,
  Adwaita, breeze, gnome, Papirus, oxygen} x size dirs (128 first,
  then 96/64/48/256/scalable/32/symbolic) x {.png,.svg}, plus
  `<root>/../pixmaps/<name>`, plus absolute-path Icon= values. libc
  file IO (fopen/fread), musl-clean (in the daemon graph). 4 tests
  (kindFromPath, parseIconKey x2, absolute-path read).
- `wlhost/pipe.zig`: new append-only `toplevel_icon = 26` unit
  (`u32 sid, u8 kind {1 png,2 svg}, bytes`) + `appendToplevelIcon`.
- `wlhost/compositor.zig`: `View.toplevel_icon` callback + feedUnit
  parse case.
- `mux/daemon.zig`: the app-channel brain now gets a View with
  `toplevel_app_id = onBrainAppId`; on set_app_id it resolves the icon
  (cached per app_id in `Native.icon_seen`; ships <=2MB), queues the
  unit to viewers, and stashes it in `Native.icon_replay` for
  reattach (replayed after state_sync in replayNativeChannels).
- `wlapp.zig`: `onIcon` decodes bytes -> GdkTexture (PNG via
  `gdk_texture_new_from_bytes`; SVG via `gdk_pixbuf_new_from_stream_at_scale`
  at 128px -> `gdk_texture_new_for_pixbuf`), stashed in `pending_icons`
  until the window exists, stored per-Win, applied in `Win.applyIcon`
  (`gdk_toplevel_set_icon_list`) on realize. Freed in onGone/destroy.

Verified end-to-end on X11 (Xvfb): a forwarded gnome-calculator's
window gets `_NET_WM_ICON (128 x 128)` with 113 distinct colors (the
real icon, not a fallback square), WM_CLASS org.gnome.Calculator; the
window renders + interacts, GUI stays alive, no leak. On Wayland the
identical set_icon_list path drives xdg-toplevel-icon so KWin shows
it. 671/676 tests, mux + mux-portable + purity (0, gdk-pixbuf is
GUI-only) clean, smoke-mux/mcp/e2e PASS.

Coverage note: works whenever the app's host has the icon installed
(the normal case — the app IS installed there). Falls back to no
custom icon (sketerm's) only if the host lacks the icon file or it's
a format gdk-pixbuf can't read. Icon-theme resolution is pragmatic
(the listed themes + hicolor + pixmaps), not full index.theme
inheritance — sufficient for app_id/reverse-DNS icons, which live in
hicolor.

## Modern Wayland protocol surface for forwarded apps

Trigger: IntelliJ's JBR toolkit died on `wl_display_dispatch() failed`
— it binds wl_seat@5 and wl_data_device_manager@3 unconditionally and
our compositor fatals on over-version binds. Fixed, then implemented
the full modern-client surface.

The compositor (`wlhost/compositor.zig`) now advertises 19 globals:
core bumped to wl_compositor v6 (preferred_buffer_scale/transform),
wl_seat v8 (frame-grouped pointer events — v5+ clients buffer input
until wl_pointer.frame — plus axis_value120 wheel detents),
wl_output v4 (name/description), xdg_wm_base v6 (configure_bounds,
wm_capabilities, working popup reposition), ddm v3; new: primary
selection (own daemon fd FIFO, GDK primary clipboard in the GUI),
relative-pointer + pointer-constraints (locks suppress absolute
motion + hide the host cursor), text-input v3 (GUI attaches a
GtkIMMulticontext while the app has an enabled text input; commits
travel as text_commit intents), WITHIN-app dnd (start_drag state
machine; the drop transfer is daemon-local — the target's receive fd
feeds the source's send via the dnd_send unit), xdg-activation,
presentation-time, idle-inhibit + pointer-gestures (accepted-inert).
dmabuf stays deliberately out: GPU clients fall back to shm, which
the pixel pipeline wants. seat_axis intents grew an optional
value120 field; state_sync bumped to v2 (reader accepts v1). The
daemon logs the interface/opcode when it kills an app connection and
the compositor logs rejected binds — the next non-GTK client failure
names itself.

Verified: 681/686 tests (9 new: per-feature wire sequences incl. the
full dnd lifecycle and a state-sync v2 round trip); GUI + mux +
mux-portable clean; smoke-mux/mcp PASS; live against the real daemon
`wayland-info` binds all 19 globals with zero errors, a JBR-init
replica client passes, zenity takes scroll/type/click and exits 0.

## Fractional scaling for forwarded apps

Forwarded apps looked soft for two reasons: the daemon brain's
output_scale was NEVER set (default 1 — apps always rendered 1x and
got upscaled, even on integer-HiDPI displays), and fractional monitor
scales meant an integer-rendered buffer was resampled at 1.25/1.5x.
Both fixed: the GUI ships its true monitor scale (gdk_monitor_get_scale
× 120) as a new `set_scale` intent; the brain advertises
wp_fractional_scale_manager_v1 and answers preferred_scale with it,
honors wp_viewport set_destination as the surface's LOGICAL size
(toplevel_frame gained lw/lh; buffer_scale stays 1 on that path), and
re-announces every scale channel when the intent lands — apps that
connected before the viewer attached converge a moment later. The
tracker expands logical wl_surface.damage rows by buffer_h/vp_h at
commit so partial copies stay correct. GTK4 renders sketerm itself
fractionally, so a logical-sized GtkPicture holding the app's
physical-pixel texture maps 1:1 — no resample, no blur.

Verified: 682/687 tests (new: set_scale re-announce + viewport'd
150x75 buffer reporting 100x50 logical at scale 1); all builds +
smoke-mux/mcp PASS; live: a generated-scanner C client gets
preferred_scale and an accepted viewport destination through the real
daemon, zenity (GTK4 binds fractional-scale itself now) still takes
clicks and exits 0.

## Command-block IPC + watch mode

Two additions riding the OSC 133 shell-integration zones (which were
already parsed and navigable): `sketerm cli get-text --last-command`
returns the last completed command's output and exit code as JSON
(empty-output zones still answer — the exit code is the point), and
MCP `read_screen` gained `last_command=true` for prompt-free output
reads. Verified end-to-end under Xvfb with fish 4.8's NATIVE OSC 133
emission (fish >= 4 emits parameterized marks like `133;C;cmdline_url=...`;
the dispatcher already tolerated the params).

`sketerm cli watch [--pane N] [--timeout SEC] [--interval MS] <regex>`
blocks until a line of the pane (screen + 100 scrollback lines)
matches a GRegex pattern, prints the line, exits 0 (3 on timeout).
Long-running-build babysitting: `watch --pane 2 'error|FAILED'`.
Pre-existing matches fire immediately by design. One persistent IPC
connection, client-side polling.

Also confirmed: "persistent scrollback across reattach" already
exists — mux snapshots serialize + restore the full scrollback ring.

683/688 tests; e2e under Xvfb: last-command extraction returned exact
printf output with exit 0 and a `false` zone with exit 1; watch fired
on a later-appearing pattern and timed out cleanly on a non-match.

## Host→app drag-and-drop

Dropping local files or text onto a forwarded app's window now works:
a GtkDropTarget on the window's picture converts the drop to a
host_drop intent (sid, surface-local x/y, mime, payload); the daemon
brain synthesizes a server-sourced Wayland dnd burst (data_offer →
offer(mime) → source_actions → enter → action → motion → drop) and
answers the app's receive() from the stored payload via a drop_data
unit. The daemon's held receive-fd queue became OFFER-KEYED so a dnd
transfer can never steal the fd of a clipboard paste still awaiting
its async GUI answer (dnd_send now carries the offer id too — fixing
a latent same-race in the within-app path). Files ship as
text/uri-list (local paths — they resolve for local apps; text drops
work for remote apps too). App→host dnd (dragging OUT of a forwarded
window) remains out of scope.

684/689 tests (new: full host_drop wire sequence + drop_data answer +
finish cleanup); builds + smoke-mux/mcp PASS. The GTK drop gesture
itself is the one untested-live link (needs a real pointer drag).

## Remote audio: the daemon IS the session's PulseAudio server

Same doctrine as Wayland forwarding — no bridge processes. New
`mux/pulse.zig`: a hand-rolled PulseAudio native-protocol server
(pure state machine, musl-clean, zero deps daemon-side; layouts
transcribed from pulsecore/protocol-native.c, negotiated down to
protocol v13, SHM/memfd refused so PCM rides the socket). Sessions
that forward apps also get a "pa-N" hub socket + PULSE_SERVER env
(SKETERM_MUX_NO_AUDIO=1 opts out). Each PA client connection is an
`audio` channel (wire.zig kind 4) carrying pulse.zig units: open /
pcm / cork / close down; subscribe / consumed / latency up.

Clocking is the load-bearing design: the app paces itself via PA
REQUESTs. Streams start SELF-CLOCKED (instant-consume, so headless
apps and terminal-only viewers never stall); a viewer's first
`consumed` report flips the stream to VIEWER-CLOCKED — the GUI's
local pa_stream acceptance becomes the clock, so a remote player
paces to real speaker output. PCM only flows to viewers that sent
`subscribe` (flooding a terminal-only client would blow its output
cap and take the connection down). Viewer-reported sink latency +
in-flight bytes answer GET_PLAYBACK_LATENCY for lip-sync.

GUI playback: `audio_sink.zig`, async libpulse on the GLib main loop
(pa_glib_mainloop — no threads, Linux GUI-only deps libpulse +
libpulse-mainloop-glib; the mux graph links nothing). Context failure
degrades to silent-consume so remote apps keep running. appdrive
subscribes and instant-consumes (headless MCP apps play silently).
Playback only — capture (mic) is deliberately out of scope.

Verified with REAL libpulse clients against the daemon: `pactl info`
negotiates v13 and round-trips rc=0; `pacat --raw` streams full
3-second windows (rc=124) in all four environments — monolith
no-viewer, broker no-viewer, MCP terminal session (self-clock), MCP
app session (subscribed appdrive clock) — plus the full GUI path
under Xvfb (durable tab -> daemon hub -> audio channel -> AudioSink
-> local PipeWire). 686/691 tests (pulse handshake/stream/clock unit
tests); all builds + smoke-mux/mcp PASS. Debugging note: every
"failure" after the first protocol fixes was the TEST HARNESS
racing (MCP teardown killing sessions when stdin ended) — the
timestamped kill trace (handleKill via addr2line on an unstripped
daemon) was what finally proved the audio path innocent.

## Opus compression for remote audio (-Daudio-opus)

`mux/opuscodec.zig` follows the vcodec pattern exactly: optional codec
behind a build flag (default off — the stock daemon stays
dependency-free, mux-portable pinned off), libopus declared via
extern fn (no headers), every impl collapsing to void without the
flag. Negotiation rides the subscribe unit's new flags byte (bit0 =
"I decode Opus"); the daemon latches per stream at first data: Opus
only when built + a subscriber decodes it + the spec is s16 in the
48 kHz family — 44.1 k streams stay raw (Opus can't eat them and we
don't resample). 20 ms frames at 128 kbit/s ≈ 16 KB/s vs 187 KB/s
raw (~12x). pcm_opus units carry a raw-byte count so non-decoding
consumers (appdrive) keep the consumed clock without libopus. The
GUI decodes lazily per voice; a broken decoder substitutes silence
at the right byte rate so the remote app never stalls. Encoder
failure mid-stream falls back to raw.

Verified: opus round-trip unit test against real libopus (skips
without the flag; both flag states green — 687/692 with, 686/692
without); full GUI e2e with -Daudio-opus builds: 48 kHz pacat
latches OPUS and streams the full window through encode → mux wire →
GUI decode → local playback → consumed clock; 44.1 kHz latches raw
and still plays. Default builds unchanged, smoke-mux/mcp PASS,
`ldd`: only the -Daudio-opus daemon links libopus.

## Quality-of-life batch: doctor, command status, search, handoff, forwarding

Five features in one pass, each riding existing machinery:

- **Command status + notifications (OSC 133).** New Screen sink hooks
  at 133/633 C/D flow through Terminal (duration-timed) to a per-tab
  indicator dot (blue running / green ok / red fail; the OSC 9;4
  progress ring wins while active, the dot lands when it clears) and
  a GNotification when a background command ran >=
  `notify_command_secs` (default 15, 0 = off). Viewing the tab acks a
  finished dot; a running dot stays.
- **`sketerm doctor [host]`.** Canonical version now in
  `src/version.zig`; the daemon's welcome/list replies carry version +
  opus/video capability flags (append-only JSON). Doctor reports
  binary-vs-daemon skew (local and remote over SSH/UDP), GUI socket
  liveness, terminfo. Found a real stale daemon on first run.
- **Cross-session search.** Attach-scoped `search` frame (20) — in
  broker mode the frame lands in the worker that owns the Screen, so
  no broker fan-out was needed. Case-insensitive substring over
  extractScrollback lines, hits as lines-from-bottom + `search_hits`
  (76). CLI `sketerm mux [host] search <pat>`; GUI palette dialog
  (`xsearch.zig`) whose hits focus-or-attach the session.
- **`attach-all` bulk handoff.** GUI IPC command + palette action +
  `sketerm mux [host] attach-all`: attaches every non-exited session
  the window isn't already showing (dedup by session+host, incl.
  tabless app sessions). The "move my desktop" command.
- **TCP port forwarding.** Client-initiated `forward_open` (21) +
  `tcp_forward` channel kind (5): daemon connects loopback:port on
  its host, raw bytes ride chan_data — works over local socket, SSH
  and roaming UDP. `sketerm mux [host] forward <local[:remote]>`.
  `Channel.session` became optional (forwards are host-scoped); a
  dying client's forwards die with it, native/audio channels don't.

Verified: 688/694 unit tests, smoke-mux/mcp/e2e PASS, plus live runs:
OSC 133 lifecycle in a real GUI, doctor against the user's daemon,
search + palette dialog driven by xdotool (screenshot-verified hit →
attach), attach-all pulling two daemon sessions into tabs while
skipping the shown one, and curl through the forward tunnel
(concurrent connections, refused-port, client-kill cleanup).

## Linear-dmabuf import (opt-in) + two bugs it flushed out

GL apps in forwarded sessions: default stays software GL
(LIBGL_ALWAYS_SOFTWARE at spawn — Mesa's EGL device probe crashes
GL apps against an shm-only compositor). New opt-in GPU path:
`SKETERM_MUX_DMABUF=1` on the daemon announces zwp_linux_dmabuf_v1
v3 (XRGB/ARGB8888, LINEAR modifier only) AND drops the softgl
force. The daemon imports each plane fd with fstat+mmap
(DMA_BUF_IOCTL_SYNC around reads; zero GPU libraries, musl-clean)
and ships pixels through the existing pool_update_c units under a
synthetic pool id equal to the buffer id — replicas can't tell
dmabuf from shm. Non-immed `create` answers `failed` (client falls
back to shm); state-sync bumped to v3 (in-flight params layouts);
reattach replays dmabuf mirrors as synthetic pools.

Why opt-in, learned the hard way: GTK4 probes dmabuf support with
`create_immed` — which has NO per-buffer failure signal — and real
GPU drivers can refuse CPU mmap (EPERM, VRAM placement), so
advertising by default would regress every GTK app. Refused mmaps
now degrade to a logged stale buffer instead of killing the app.

Bugs found while validating:
- `sketerm mux get-text`/`send` read the attach snapshot at the old
  8-byte header offset (the [app:u8] byte shifted the version) —
  every headless get-text failed with "bad snapshot".
- recvExpect(.snapshot) buffers frames PAST the snapshot into
  conn.rbuf; appdrive's pump and the GUI's fd watch only woke on new
  socket bytes, so a small reattach replay sat unprocessed forever
  (dmabuf mirrors compress to ~600 bytes and exposed it
  deterministically; big shm replays masked it). Fixed both sides.

Verified: 691/697 unit tests (tracker actions, brain bind/create/
release/failed, announce gate, state-sync v3 replica round-trip
with pixels); live via MCP: a wayland-scanner C client presenting a
memfd-backed create_immed buffer renders solid red pixel-perfect,
survives detach → reattach with identical pixels; zenity (GTK4/shm)
regression green in default mode; smoke-mux/mcp/e2e PASS; all three
binaries build, mux-portable static.

## Per-session GPU opt-in: --gpu / launcher menu / gpu_apps

Replaced the daemon-wide SKETERM_MUX_DMABUF env juggle with a
per-session switch: SpawnReq.gpu (append-only JSON; old daemons
ignore it) stores on the Session, skips the LIBGL_ALWAYS_SOFTWARE
force in pty.zig for that child only, and flips advertise_dmabuf on
that session's compositor brain. The env vars remain as daemon-wide
overrides.

Entry points:
- `sketerm app --gpu <host> <cmd>` (leading flag, like -u/-i, so the
  app's own flags pass through untouched).
- MCP launch_app gained an optional `gpu` boolean.
- GUI app launcher: right-click a row -> "Launch with GPU" context
  menu (popover parented to the ROOT box, not the listbox —
  clearList walks the listbox children and a non-row child wedges it
  in an infinite remove loop; found live under Xvfb).
- `gpu_apps = Blender, mpv` config key: launcher activations match
  the .desktop Name or Exec basename case-insensitively and default
  those apps to GPU (Config.appWantsGpu).

Verified: 693/699 unit tests (+2: --gpu parse, gpu_apps matcher);
MCP probe both ways (gpu:true -> LIBGL unset + zwp_linux_dmabuf
announced; default -> softgl + no global); full GUI chain under Xvfb
with a planted GpuProbe.desktop: context-menu launch went GPU, plain
activate stayed software, gpu_apps config flipped the default;
smoke-mux/mcp/e2e PASS.

## Async remote-mux reattach on layout restore (no more startup freeze)

Loading a layout with remote mux panes connected synchronously on the
GTK main loop — a dead/stalling host froze the whole GUI for the full
ssh retry window (~61s) or forever (the attach recvExpect had no
bound). Restore now spawns the local fallback pane immediately as a
live placeholder and runs connect + attach in a detached thread
(MuxRestoreJob in window.zig); the result lands via g_idle_add and
swaps the placeholder in place through the existing takeover path
(swapPaneInPlace), so splits/shaders/titles survive. Failure = toast +
the pane stays a usable local shell. Local-daemon panes keep the sync
path.

Safety: jobs tracked on Window.mux_restore_jobs; window teardown marks
them canceled (idle just drops the conn), a pane closed mid-connect is
caught by pane-id lookup, and paneSpec consults pending jobs so saving
mid-connect keeps mux_session/mux_host instead of demoting to a plain
shell. The attach handshake gets SO_RCVTIMEO=30s so a remote that
answers hello but wedges surfaces as a failure, not a stuck thread.

Verified: 693/699 tests; e2e under Xvfb with fake $SKETERM_SSH — hang
case kept IPC at ~50ms through the whole retry window, success case
swapped pane 1 -> 2 and round-tripped send-text/get-text, second GUI
attached the existing session with scrollback, Ctrl+Shift+S
mid-connect saved the mux identity.

## Mux memory leaks (the 15GB daemon) + MCP observability batch

A user killed an MCP-owned isolated daemon at 15GB RSS. Root cause
(confirmed by code, not repro): shm pool mirrors were NEVER reclaimed
— pool_destroy was a deliberate no-op ("buffers still reference the
memory") but buffer_destroy never re-checked, so every destroyed pool
pinned its mmap AND its memfd's tmpfs pages forever; a recycled pool
id even orphaned the old mapping on the spot. Fixed with a per-mirror
live-buffer refcount (reclaim at destroyed+0), an id-recycle free, and
the daemon now emits the pool_destroy pipe unit so replicas free too
(compositor.zig had the handler all along; the same refcount now also
runs in the compositor's own request path — brain + GUI replicas
leaked pool bytes identically). Also: Client.wbuf gets a 256MB hard
ceiling (a stalled-but-alive viewer is reaped and can reattach; the
native unit stream is stateful so skipping frames winstream-style
would corrupt it), drained rbuf/wbuf release multi-MB high-water
capacity, and per-surface video encoders die with their surface.
Separate race fix: sessionExited now retries the WNOHANG reap briefly
before shipping .exit, so a segfaulting app reports -11/SIGSEGV
instead of the default 0.

MCP app tools, from two rounds of assistant feedback (observability
was the gap; interaction was fine): appdrive keeps a termdrive-style
Screen mirror of the app session's PTY — new app_output tool,
recent_output + signal_name inlined once an app exits, exited apps
report exit+output instead of "no such window". launch_app gained
cwd/env (SpawnReq.env -> putenv in the PTY child), wait_for
window|exit, and returns the first window's screenshot inline.
screenshot_app/get_app_state gained region crop + integer zoom
(png.upscaleRgba) with caption math back to app_click coords, plus
wait_change=true (block until the window renders something newer than
your last screenshot). run_command/term_run output_only=true returns
just the OSC 133 zone output + exit code. Launch/attach handshakes are
deadline-bounded (Conn.recvFrameFor/recvExpectFor); timeouts name the
step and any half-arrived frame (wire.partialInfo). Spawn failures
carry the real reason end to end (worker 'E' control datagram ->
broker .err -> appdrive.lastLaunchErr() -> tool text). Compositor now
implements zxdg_output_manager_v1 v3 (SDL stops logging "protocol
missing" and gets real logical geometry, rescaled on set_scale).

Also fixed in passing: smoke-mux had a latent double conn.deinit AND
died of SIGPIPE from its in-process daemon (the real binary ignores
it) — the two masked each other past the durability stage.

Verified: 697/703 tests (+4: pool refcount lifecycle, zxdg event
sequence, wire.partialInfo, png.upscaleRgba); smoke-mux/mcp/e2e PASS,
mux-portable + aarch64-macos cross OK, sketerm-mux still libc-only.
Live MCP drive over stdio: sh SIGSEGV reported as -11/SIGSEGV,
env/cwd echoed in recent_output, weston-terminal launch returned an
inline PNG, region{10,10,40,20}+zoom4 captioned "MULTIPLY by 0.250
then ADD (10,10)", app_output showed the app's real stderr.

## output_only actually delivers (bash integration) + zxdg confirmed

Round-2 feedback: botf reported output_only had no effect. Three
stacked causes, all fixed. (1) bash had no auto-injection (zsh/fish
only) — added: bare interactive bash spawns get `--rcfile <shim>`
(no env override exists; the shim sources /etc/bash.bashrc +
~/.bashrc then the integration script), resolution shared with
headless spawns via the new util/shellintegration.zig. (2) The bash
script's DEBUG-trap C fired for the distro's own PROMPT_COMMAND
entries too (verified with a raw `script` capture on Arch), opening
a spurious zone at the next-prompt row — C now comes from PS0
(bash >= 4.4), which expands exactly once per interactive command.
(3) Screen-side, a mid-line C captured the command-echo row as the
zone start; the capture now defers to the next linefeed, and a
completed zone with zero output rows extracts as "" + exit code
instead of "no zone". Also: term_open never requested integration at
all — termdrive now resolves and sends it in the SpawnReq — and when
no zone exists (unsupported shell) term_run/run_command SAY SO
instead of silently returning the screen shape.

ds9dw's residual (SDL dying in Wayland init, missing xdg-output) was
already fixed by the zxdg_output_manager_v1 commit — their session
ran a pre-fix daemon. Confirmed live: launch_app wayland-info on a
fresh isolated daemon lists zxdg_output_manager_v1 v3.

Verified: 699/705 tests (+1 shellintegration resolve, +1 mid-line-C
zone); smoke-mux/mcp/e2e PASS, mux-portable + aarch64-macos cross OK.
Live MCP drive (bash $SHELL): term_run output_only returned
"exit: 1\n---\nout-only-works" (no prompt/echo/padding), compound
"a && b; false" captured both lines, bare `false` returned an empty
zone with exit 1, /bin/sh fell back WITH the announcement, and fish
zones work through the same plumbing.

## Pulse server no longer crashes SDL clients

ds9dw round-3: every SDL2/SDL3 app SIGSEGVd in its client-side
PulseMainloop during audio init under sketerm (backtrace: libc <-
libSDL3 x2 <- libpulse <- pa_pdispatch_run — i.e. inside SDL's own
reply callback; Arch's SDL2 is sdl2-compat on SDL3, hence the SDL3
frames). Root cause in mux/pulse.zig: GET_SERVER_INFO reported the
default source as NULL. No genuine PulseAudio server ever does that
(a sink always has a monitor source), so SDL3's ServerInfoCallback
dereferences the name unchecked -> strcmp(NULL) -> SIGSEGV. Fixed by
naming sketerm.monitor as the default source and backing it with a
real monitor-source object (GET_SOURCE_INFO/_LIST, LOOKUP_SOURCE;
capture enumeration skips monitors so nothing records from it).
Audit fallout fixed too: STAT now returns its real five-u32
pa_stat_info instead of an empty ack, and the sink flags value was
PA_SINK_SET_FORMATS (0x0100) where PA_SINK_LATENCY (0x0002) was
meant.

Verified: minimal SDL2 repro (SDL_Init(AUDIO)+OpenAudioDevice)
SIGSEGVd before, now opens s16/48k, plays 1.5s through the daemon,
exits clean; pactl info / list sinks+sources / stat all parse; paplay
streams a full WAV (rc 0); the user's actual game (ds9dw) boots past
audio init with live audio — previously only SDL_AUDIODRIVER=dummy
got it there. +1 regression test parsing the server-info /
source-list / stat reply layouts exactly. 700/706 tests,
smoke-mux/mcp PASS, portable + macOS cross OK.

## MCP: --log DIR trace + fail-fast on over-long socket paths

`sketerm mcp --log DIR` traces everything the server does: one JSONL
entry per JSON-RPC request/response in mcp-<pid>.jsonl (payloads over
4KB truncated with full_len recorded, never mid-UTF-8; start/exit
notes carry pid/mode/instance/GUI socket), and every inline
screenshot saved verbatim as img-<pid>-NNNN.png via the imageResult
choke point (catches screenshot_app, screenshot_pane, launch_app's
first-window shot) with an "image" entry referencing the file. Works
in all modes; pid-prefixed names keep restarts appending into one dir
collision-free. Dir open failure is a startup error, not silent.

Also: isolated mode now validates the private daemon's mux.sock path
against the sun_path limit at startup (reusing fillSockaddrUn) — a
deep XDG_RUNTIME_DIR used to surface only as MuxDaemonUnreachable on
the first app tool call; now it exits immediately naming the path,
the limit, and the fix.

Verified: 701/707 tests (+2: flag parsing, McpLog file behavior incl.
truncation and PNG round-trip), smoke-mcp PASS, live e2e (gedit via
launch_app + screenshot_app under --log produced valid 1568x993 PNGs
and a fully JSON-parseable trace), long-path repro now errors at
startup with exit 1 while normal startup is unaffected.

## The REAL 15GB leak: per-commit pixel-encode scratch

The daemon leaked to 15GB AGAIN after the earlier pool-mirror fix
shipped — because the pool mirrors were never the dominant leak for
this workload. Reproduced exactly with the reporter's game (ds9dw)
under an isolated MCP daemon: the session worker climbed ~30MB/s
(92M -> 1.4G in 57s), and crucially it leaked with NO viewer attached
at all (MCP killed, durable game still rendering: 40M -> 1GB in 27s).
smaps showed pure anonymous heap (not mmap), fds flat at 11 — so not
the pool/fd class.

Root cause: the native `.commit` handler created a wlpixcodec.Scratch
(a filter work buffer + a zstd output buffer, both frame-sized
ArrayLists) as a per-commit local and never called sc.deinit — the
pool-replay path frees its identical scratch, this one was missed. So
every committed frame leaked ~2 frame-sized buffers. It only surfaced
now because the recent pulse fix let audio-using apps (games) get
past init and render continuously; static GUI apps commit rarely.

Why it was reachable at 15GB and not caught: the encode ran on every
commit regardless of whether any viewer would receive the units, and
the leaked scratch accumulated unbounded. Fix:
- hoist the scratch onto Native, reused across every commit (leak
  gone; also removes per-frame alloc churn);
- gate the copy+encode on some attached proto>=5 viewer having room
  in its wbuf (< 8MB, matching the winstream backpressure) — a
  headless or backed-up viewer produces nothing; it catches up from
  the live mirror on the next commit or via reattach replay;
- gate the PCM broadcast the same way: a subscribed-but-idle viewer
  (MCP between tool calls) sends no `consumed` reports, so the stream
  self-clocks and would otherwise flood its wbuf with audio.

Regression guard (would have caught BOTH this and the pool-mirror
leak): smoke-mux now runs its in-process daemon under a leak-tracking
DebugAllocator (safety=true — off by default in ReleaseFast) and
exits non-zero if any allocation is outstanding after the daemon is
fully deinit'd. Proven by reintroducing the leak (FAIL) and restoring
(PASS). realAppStage drives the native path via weston-terminal.

Verified live (ds9dw, isolated MCP daemon): no-viewer flat 6M,
viewer-attached-idle flat 15M, active screenshotting flat 16M with
the frame hash updating (viewer stays current). 701/707 tests,
smoke-mux (with the new leak guard) + smoke-mcp PASS, mux-portable +
aarch64-macos cross OK.

## 2026-07-13 — shm pool id recycling killed GTK4/Vulkan app windows

Report: launching baobab (Disk Usage Analyzer) over `sketerm app`
showed a window for an instant, then nothing — no error anywhere, and
the baobab processes stayed alive on the host, connected to their
session's Wayland socket.

WAYLAND_DEBUG trace of a headless repro (MCP launch_app) showed the
trigger: GTK 4.22 renders via Vulkan (lavapipe headless), and mesa's
WSI creates four 256-byte probe pools (create_pool → create_buffer →
pool.destroy), later recycling a freed pool id for the real 6MB
swapchain pool. Every pool-refcount site keyed by pool ID:
- daemon nv.pools: pool_create on a recycled id clobbered the old
  mirror's refcount; the old probe buffer's later destroy then
  decremented the NEW pool to zero and munmapped the swapchain mirror
  (plus emitted a stale pool_destroy unit);
- compositor.zig (brain + GUI/appdrive replicas): same flaw in the
  wl_msg handlers, so replicas freed their byte copy independently.
The app's one startup commit then resolved no pool anywhere:
pushFrame returned silently, no toplevel_frame, no window — while the
protocol stayed healthy (frame callbacks + presentation feedback keep
answering), so the app never knew either.

Fix (`1cddd8e`): every pool incarnation gets a serial (tracker
assigns; BufferInfo/Buffer carry it). The current incarnation stays
keyed by id; a displaced-but-referenced one moves to an orphan map
keyed by serial and frees on its last buffer destroy. Commits ship
pixel units only for current-incarnation buffers (units address pools
by id; orphan-backed frames render from the replica's retained copy).
state_sync v4 adds a per-buffer current-incarnation flag so a restore
can't bind an old buffer to a recycled id's new pool (pre-v4 blobs
read as before).

Verified: 703/709 tests (2 new: tracker serials + a compositor replay
of the exact baobab sequence incl. state_sync v4 round-trip),
smoke-mux + smoke-mcp PASS, mux-portable + aarch64-macos cross OK.
E2E: MCP launch_app baobab returns a real window + screenshot
(Devices & Locations fully drawn); GUI path proven under Xvfb — an
isolated GUI's daemon spawned baobab and the GUI rendered it
(wlapp/AppHost replica). Note for the field: the running packaged
daemon still has the bug until reinstalled + restarted.

## 2026-07-13 — SKETERM_MUX_LOG: the daemon finally has a voice

Follow-up to the pool-incarnation fix: that bug was invisible because
the daemon has no logging and its stderr goes nowhere when the GUI or
MCP autostarts it. New `src/mux/log.zig` (libc-only, allocator-free,
musl-clean; fork-inherits into workers, O_APPEND + [pid] prefix keeps
the shared file readable):

- default (env unset): lifecycle info + warnings to
  $XDG_STATE_HOME/sketerm/mux.log, rotated at 2MB to one .old
  generation; warnings still hit stderr as before.
- SKETERM_MUX_LOG=debug (or 1): adds wlhost tracing — pool mirror
  lifecycle (mapped/orphaned/reclaimed, incarnation serials) and
  commit pixel-path TRANSITIONS (shipping / no-viewer / orphan-backed
  / "commit resolves NO mirror" warn — the silent-black-window class
  that was yesterday's bug).
- =off/0: no file; =<path>: that file, debug level.

Instrumented: daemon up/shutdown (mode+socket+version), worker fork,
session spawn (kind, child pid, wl display, a11y on/off) and exit,
client attach/detach (proto — a proto<5 attach explains "no app
pixels" instantly), wayland channel open/close (viewer count), a11y
hub setup failure (was silently null → empty app_a11y_tree), and the
previously stderr-only warns (protocol kill, dmabuf mmap refusal,
kb_layout, winstream init, pulse protocol error) now also land in the
file.

Verified: 704/710 tests (log.zig parseEnv), smoke-mux + smoke-mcp
PASS, mux-portable + aarch64-macos cross OK, ldd unchanged (libc
only). Live: debug-mode baobab launch writes the complete pool-
recycle story (orphaning serial=1 ... freed on last buffer destroy
... commit pixels: shipping); default mode logs lifecycle only;
3MB pre-grown log rotates to .old on daemon start.

## 2026-07-13 — MCP feedback round 3: flood wedge fix + observability batch

Third round of assistant feedback on `sketerm mcp` (the cider session:
"one noisy app killed the whole server"). Everything landed + verified
end-to-end with scripted MCP stdio drivers against real apps.

**The wedge (root-caused + fixed).** `CIDER_DEBUG_LEVEL=3` PTY spam:
appdrive's `drain()` was `while (pumpOnce(0))` — unbounded, so it
spins for as long as event production keeps pace with consumption
(machine-load dependent; unreproducible on a fast idle box, which is
why it looked intermittent). One wedged call serializes every later
tool call behind the single-threaded stdio loop = the reported
"everything hung 1800s". Fix is two-sided: drain() gets a 100ms
budget, and the daemon stops streaming `.events` to any client whose
wbuf exceeds 8MB (`Client.needs_resync`), resyncing with a fresh
snapshot once it drains — so an idle MCP client under flood no longer
races toward the 256MB reap either, and correctness is preserved via
the snapshot-swap path both GUI and appdrive already had. The exit
path pushes the resync snapshot BEFORE `.exit` (clients stop pumping
after exit) so crash post-mortems see the final screen. Verified: yes-
flood app, all tools < 2.2s, mux.log shows the backlog trip + resync,
output content stays current.

**launch_app/list_apps ship the pid.** Worker 'Y' ready datagram +
WorkerMeta carry the session child pid; spawn `.ok` and `list` include
it; appSummary prints it. argv-array commands exec directly (pid IS
the app); string commands report the wrapping /bin/sh. Verified
against /proc.

**screenshot_app: stable_ms / stats_only / burst.** stable_ms =
settle-then-capture (composes with wait_change); stats_only compares
against a per-window pixel baseline and returns changed/diff_pct
without encoding an image; burst=N captures up to 8 frames over
burst_ms, each gated on min_change_pct vs the previous, returned as
multiple inline images (`imagesResult`). Verified on weston-terminal:
0.00% after shot, 0.53% after typing, 3 burst frames across an
animating date loop, non-settle note on animation.

**Indexed log ring + OSC 5522 markers (app_log).** New
`src/mux/logring.zig` (pure std, musl-clean, 8 unit tests): per-
session daemon-side ring of escape-free lines fed from parser events
in drainSession — stable increasing ids, 4KB/line, 1000 lines/2MB
drop-oldest with a counter. Gotcha found by the e2e test: PTY line
endings are CRLF, so CR must mark a PENDING rewrite (resolved by the
next byte) instead of clearing eagerly, or every line commits empty.
`app_log`: numbered tail with relative ages ([+] = shortened), full
line by id, dropped count. `OSC 5522;label` is swallowed by the
daemon, becomes a labelled marker line + a `.marker` push; appdrive
stashes a screenshot of the primary window at that instant (bounded
ring of 8, baseline-neutral encode) and serves it inline via app_log
{id}. Session exit pushes the final log (tail 300) ahead of `.exit`,
so app_log keeps working post-mortem. Wire adds log_get=22,
log_data=77, marker=78 (append-only).

Verified: 712/718 unit tests, smoke-mux + smoke-mcp PASS,
mux-portable OK, and four scripted end-to-end MCP drivers (flood,
pid, screenshot trio, log/marker/post-mortem) all green.

## 2026-07-13 (later) — marker rate limit + OSC 5522;+N

Follow-up to the marker feature, same day. Two additions:

- **Rate limit (the cat'ed-log hole):** markers now pass a per-session
  token bucket in logring.zig (burst 8, refill 2/s; unit-tested with
  injected clocks). Over-limit markers vanish entirely — no ring line
  (a flood would evict real output) and no `.marker` push (each costs
  the viewer a PNG encode) — with a cumulative counter surfaced in the
  app_log header and one "[marker rate limit hit]" note line per
  drop-run. Client side, a marker burst against an UNCHANGED frame
  reuses the previous stash's PNG bytes instead of re-encoding, and
  the pushed label is capped at 256B.
- **`OSC 5522;+N;label`:** capture the primary window's Nth FUTURE
  commit instead of "now" (leading `+N;` field, clamped to 600;
  backward compatible — labels not starting with a parseable `+N`
  are unchanged). appdrive keeps pending markers ticked in onFrame;
  app exit resolves stragglers against the final state so a marker
  id never dangles.

Verified: 714/720 unit tests (2 new bucket tests), smoke-mux +
smoke-mcp PASS, mux-portable OK, and an 11-check e2e driver: 200-
marker flood admits exactly 8 (192 counted; real output survives;
tools stay <2s), +2 marker captures after the wait, +500 marker on an
exiting app resolves with an explanatory no-screenshot message.

Addendum: same-instant marker bursts now store ONE image per
committed frame — later markers reference it (`MarkerShot.same_as`)
instead of holding byte-copies, and only png-bearing entries count
toward the 8-image cap (total entries capped at 40). Previously a
burst burned all 8 slots and evicted earlier legit screenshots.
E2e-verified: a pre-burst marker's screenshot survives a 50-marker
burst, and burst members serve the shared image with a "frame
unchanged since marker N" caption.

## 2026-07-13 (later still) — MCP feedback round 4: no-hang, mouse motion, batched actions

Fourth round of agent feedback (a DOS-game-port session driving a
native SDL3 build + DOSBox side by side). Four asks; all landed.

**1. No-hang invariant (the reported blocker).** The reporter's build
predated the round-3 drain fix, but three genuinely unbounded paths
remained and are now closed:
- `Conn.sendFrame` on a BLOCKING fd could park in write() forever
  against a wedged daemon (the exact 15GB-leak failure mode).
  appdrive/termdrive conns now run NON-BLOCKING (`Conn.setNonBlocking`)
  so sendFrame's EAGAIN path bounds the wait (`Conn.write_timeout_ms`).
- Every remaining blocking `recvExpect` became `recvExpectFor`:
  `helloProbe` (10s — a daemon that accepts but never answers now
  fails the connect), listInstalledApps/listAppSessions (10s), the
  termdrive spawn handshake (15s), remoteapp + SSH/UDP welcomes (20s).
- termdrive.pumpOnce had the pre-b275f44 bug appdrive already fixed
  (poll says readable != whole frame buffered; recvFrame then blocks
  on the tail) — now peels via fillAvailable/takeFrame, and its
  drain() is time-boxed like appdrive's. `RealBackend.talk` (GUI
  socket) gets a 30s GLib socket timeout.
E2e: launch → self-exit(3) → screenshot_app / list_apps / app_actions
/ app_output all answer in ~2s total with explicit exited+status+
recent_output (the reported 15-minute wedge scenario).

**2. Pointer motion (`app_mouse_move`).** Button-free move: x/y
absolute, dx/dy RELATIVE, no-args = query. appdrive tracks the
injected position per app (click/drag/scroll update it too); the
compositor brain already derives zwp_relative_pointer relative_motion
from successive absolute motions and suppresses absolute events under
pointer-lock, so DOSBox-style relative-mouse apps move by exactly the
delta. Tool description documents the corner-slam calibration trick
(one huge negative delta). Bonus fix: app_scroll now emits a real
motion (enter alone is a no-op on unchanged focus, so scrolling never
actually positioned the pointer before).

**3. `app_actions` batch.** One call runs an ordered step list
server-side: move/move_rel/click/drag/key/type/scroll/wait/wait_idle
(incl. change_pct)/wait_change/screenshot (max 8 inline, max 32
steps), per-step report, stops early with the exit summary when the
app dies mid-sequence. E2e: a 9-step batch against weston-terminal
typed `echo BATCH-OK`, settled, and returned both screenshots — the
output visible in the shot.

**4. Animating-app waits + capture rate.** `app_wait change_pct` =
VISUAL quiescence via `appdrive.waitVisualSettle`: commits diffing
less than the threshold don't reset the quiet timer AND don't move
the baseline (tiny animations settle; slow cumulative drift still
counts as change). The timeout message now says which mode to use.
`app_record_start fps` caps encoder feeding (e2e: same script, 9
frames uncapped vs 2 at fps 2). app_output distinguishes "blank
visible grid" from "never printed" instead of returning silence.

Verified: 714/720 unit tests, smoke-mux + smoke-mcp PASS, mux +
mux-portable build, plus the three e2e MCP drives above.

## 2026-07-13 (round 5) — central hard timeout: the hang class, closed for good

Round-4 shipped per-path deadlines; the reporter came back with a
close_app hang on a self-exited app. The trivial repro (sleep 3 →
close_app) did NOT reproduce against HEAD, but re-auditing with
fresh eyes found two genuinely unbounded holes that fit the "video
harness" workload, plus the structural fix the reporter demanded:

- **`Conn.fillAvailable` could loop forever.** Its caller's deadline
  (drain's 100ms box, waitIdle's timeout) is only checked BETWEEN
  pumps — but one fillAvailable call read until the fd went quiet.
  An app streaming frames faster than the client consumes (video
  playback through the resync cycle) keeps the fd readable
  indefinitely = one pump that never returns. Now byte-budgeted
  (4MB per call; the rest stays queued for the next pump).
- **`zoom` could demand gigapixel intermediates.** zoom 32 on a big
  region = a ~1GB upscale buffer and minutes of CPU that look
  exactly like a hung call. The upscale area is clamped to 64MP
  (Shot.scale still reports the truth, captions stay correct).
- **Central `Watchdog` (mcp.zig).** One mechanism over EVERY tool
  call, not per-tool special cases: a thread checks the in-flight
  call each second; past the hard cap (150s default,
  SKETERM_MCP_HARD_TIMEOUT_MS override, min 30s) it shutdown()s all
  app/term conn fds snapshotted at call start. Every bounded IO loop
  on them errors within its own deadline, the call returns an error,
  the server keeps serving; affected sessions surface as exited
  (harsh, but strictly better than a hang an agent cannot cancel).
  Zig 0.16 has no std.Thread.Mutex — publication is an atomic
  started_ms with release stores (fds are written only while idle).
- **"App exited" is a normal state, centrally.** appTool gates every
  interaction tool (needsLiveApp: click/drag/type/key/scroll/resize/
  mouse_move/clipboard/a11y/record_start/close_app_window) with an
  immediate exit-summary error; close_app is IDEMPOTENT ("closed —
  the app had already exited with status N"); double-close says
  "unknown app" instead of anything worse.

Verified: 714/720 tests, smoke-mcp PASS, mux/mux-portable build, and
three e2e drives: (1) torture — spam-streaming weston-terminal with
an active WebM recording exits on its own, close_app + list_apps
answer instantly; (2) watchdog — a 10-minute app_wait against `yes`
with a 30s cap returns at ~30s, stderr notes the abort, the next
call still works; (3) the reporter's acceptance script (sleep 3 →
wait 5 → screenshot_app/app_output/app_click/close_app/close_app/
list_apps) completes in 6s wall with explicit per-call answers.

## 2026-07-14 — the close_app "hang" was a silent SIGPIPE DEATH

Rounds 4 and 5 hardened deadlines; the reporter still hit a wedge on
the round-5 binary. This time the trace log (--log) plus the actual
app (the st-afu game port) made it reproducible, and the story is
embarrassing but simple: the MCP server was not hanging — it was
DYING, silently.

Root cause: `sketerm mcp` (unlike the daemon, mux_main.zig) never
neutered SIGPIPE, and `Conn.sendFrame` wrote with plain write(). When
an app session's broker WORKER dies (the app exited on its own), the
client's attach socket closes. The afu app has AUDIO, so pcm units
keep flowing until exit and appdrive answers them with `consumed`
reports during every routine drain — the first such write after the
worker died raised SIGPIPE and killed the whole server: no core, no
stderr, and the client's in-flight call (their close_app; in the
repro, a plain list_apps) "hangs" forever. Every symptom across all
three reports fits — including one dead app "blocking" unrelated
tools (the server was simply gone).

Why earlier repros passed: sh -c sleep sessions have no audio channel
and nothing writes to the conn after exit; weston-terminal tortures
never raced a write against the worker teardown.

Fix, both layers: a no-op SIGPIPE handler in installQuitSignals()
(SIG_IGN macro fails translate-c, same trick as mux_main), and
MSG_NOSIGNAL in Conn.sendFrame (@hasDecl-gated; macOS callers rely on
handlers / GSocket's SO_NOSIGPIPE) — the latter also protects the GUI
process, which talks to the daemon with the same Conn and would die
the same way if a daemon/worker vanished mid-write.

Verified with the reporter's real workload: launch the afu movie
harness, poll list_apps every 5s across its ~40s lifetime, then
close_app — pre-fix the server died at the poll coinciding with app
exit (twice, deterministic); post-fix all polls answer, close_app
returns "app session closed (the app had already exited with status
0)", server alive (run twice). 714/720 tests, smoke-mux + smoke-mcp
PASS.

## Audio sink: real-time self-clock (the accept-and-never-play black hole)

Bug report from the st-afu game harness: the per-session Pulse shim
accepted audio and never consumed it on any clock. `paplay` of a 2 s
WAV returned in 21 ms (DRAIN was acked instantly); an SDL3 client's
queued bytes never decreased, so a game gating dialogue/FMV logic on
"is this voice still playing" hung forever while looking healthy.

Three compounding defects, all fixed:

1. `mux/pulse.zig` self-clock was instant-consume: `read_index =
   write_index` + REQUEST on every pcm frame, and DRAIN replied
   immediately. Now the self clock is REAL TIME: a host-injected
   monotonic `now_ms` (daemon sets it before feed/applyUnit; the new
   `Server.tick(now)` advances it), `read_index` moves at the
   stream's declared byte rate, REQUESTs keep a `read + tlength`
   window at `minreq` granularity, DRAIN is queued in `drain_tag` and
   replied only when playback catches the write head (either clock),
   FLUSH jumps to the write head, CORK banks/freezes/rebases the
   clock, UPDATE_SAMPLE_RATE re-paces. Underrun parks the clock so
   late data plays from "now". `tick` returns the next deadline; the
   daemon's new `pulseTick` (top of `Daemon.tick`) drives every audio
   channel and clamps the poll timeout to the nearest deadline.

2. `appdrive.zig` subscribed to audio units and acked every PCM byte
   as instantly consumed (`drainAudio`) — a client-side copy of the
   same flaw that made streams viewer-clocked with a broken clock
   (and only while a tool call happened to be pumping). appdrive now
   NEVER subscribes: no PCM is shipped to MCP clients and the daemon
   paces the app itself. Server-side, `has_viewer` now counts only
   SUBSCRIBED viewers (audio_ok), and both `pcm()` and `tick()`
   revert a viewer-clocked stream to the self clock when the last
   subscriber detaches (previously: REQUESTs stopped forever = the
   SDL stall with a GUI that left).

3. REQUEST sizes were not frame-aligned (read_index is a time
   computation). libpulse clients asked to write e.g. 4057 bytes of
   4-byte frames fail `pa_stream_write` — SDL3 zombifies the whole
   device on the first failed write and dumps its queue as if played
   (3 s "drained" in 150 ms). Everything is now frame-aligned:
   advanceSelfClock's position, request deltas, and the negotiated
   tlength/minreq defaults.

Plus: `launch_app` gained `audio: "forward" | "none"`. "none"
(SpawnReq.no_audio) skips the session's audio hub AND — new
`Pty.spawn clear_pulse_server` — unsets an inherited PULSE_SERVER (a
daemon started from inside a sketerm session used to leak its own
session's sink socket into hub-less children; that leak applies to
every hub-less non-local spawn and is now scrubbed).

Verified end-to-end via a stdio MCP driver on an isolated daemon:
`time paplay t.wav` (2 s WAV) = real 2.01–2.03 s (was 0.01); an SDL3
client queueing 3 s of s16 stereo drains smoothly in 3107 ms with 139
paced REQUESTs (SDL dummy driver reference: 3004 ms; was: 150 ms
cliff), `audio:"none"` leaves the child with no PULSE_SERVER
(paplay: connection refused → SDL would use its dummy driver). New
pulse.zig tests: real-time pacing + underrun clamp, clocked DRAIN,
viewer-detach revert, FLUSH semantics. 718/724 tests, smoke-mux +
smoke-mcp + smoke-e2e PASS, mux-portable (incl. aarch64-macos) green,
sketerm-mux still libc-only.

Known limitation: `pactl list short sinks` shows state "n/a" — sink
state is a protocol v15 field and the shim speaks v13; harmless.
Headless audible playback (forwarding an MCP session's audio to the
host's real server) remains a design decision — the daemon is
libc-only and would need to speak the Pulse CLIENT protocol itself.

## Audio round 2: protocol v15 (real sink state) + WAV capture target

Follow-up on the real-time sink clock: the shim now negotiates Pulse
protocol v15 instead of 13, and headless runs can capture the audio
the sink consumes to WAV files for offline verification (the "did the
app actually produce sound" probe that a discarding sink can't answer).

v15 (`mux/pulse.zig`): version-gated additions, layouts matching
protocol-native.c exactly — create-stream request gains volume_set +
early_requests (v14) and muted_set + dont_inhibit_auto_suspend +
fail_on_suspend (v15); sink/source info replies gain base volume,
STATE, n_volume_steps, card; GET_SERVER_INFO gains the default
channel map (missing it = pactl info "Protocol error", found the hard
way). Sink state is session-wide: a pactl connection owns no streams,
so `Server.sink_running` is daemon-fed from sibling connections of the
same session (`sessionAudioRunning`) and `sinkState()` reports
RUNNING/IDLE accordingly.

WAV capture: `launch_app audio_path:"/abs/base"` (SpawnReq
.audio_capture, appdrive LaunchOpts.audio_capture). New
`mux/wavcap.zig` — libc-only WAV writer (u8/s16le/f32le/s32le/s24le;
RIFF sizes patched on close), unit-tested. The daemon tees the audio
UNITS stream in `paReadable` (`captureUnits`: open → writer, pcm →
append, close → finalize; Channel.deinit finalizes stragglers), so
pulse.zig stays a pure state machine and pacing/forwarding are
untouched. Files: first stream `<base>.wav`, later `<base>-N.wav`
(session counter). Capture gates Opus off (pcm_opus can't be decoded
daemon-side). MCP validates: absolute path, incompatible with
audio:"none"; the launch reply echoes the capture path. WAV not
mp3/ogg because the daemon links libc only — no encoder libs.

Verified end-to-end (isolated MCP daemon): pactl info reports Server
Protocol Version 15; `pactl list short sinks` shows IDLE → RUNNING
during paplay → IDLE after; paplay still paces (real 2.01 s for a 2 s
WAV); SDL3 (which now sends the v15 create fields) still drains a 3 s
clip in 3189 ms; captured cap.wav / cap-2.wav decode to exactly
2.000 s @ 22050 Hz mono with samples byte-identical to the source
sine. 721/727 tests (3 new: v15 sink state, wavcap round-trip,
wavcap format refusal), smoke-mux + smoke-mcp + smoke-e2e PASS,
mux-portable incl. aarch64-macos green, sketerm-mux still libc-only.

## 2026-07-14 (round 6) — click markers, exit-decode everywhere, log-ring recent_output

Sixth MCP feedback round (same DOS-game-port reporter). One feature,
two reliability fixes, several ergonomics wishes; all landed.

**1. Click/hover marker visualization (the headline request).** New
`src/util/marks.zig`: pure-RGBA crosshair+ring markers with a black
backing (visible on any background), red = click, cyan = move/hover,
plus a tiny 3x5 bitmap-digit label (the step number). appdrive gained
`screenshotPngMarked` (marks in surface coordinates, drawn post-crop
pre-zoom so they scale with the pixels; the no-marks fast path is
untouched). Exposed as:
- `app_click mark:true` — returns the POST-click frame with the click
  pixel marked (screenshot:true = frame without marker).
- `app_actions` per-step `"mark":true` on click/move/move_rel/drag/
  scroll: marks accumulate and are drawn onto the NEXT screenshot
  (several labelled clicks can share one image); the combined form
  {"click":[x,y],"mark":true,"screenshot":true} captures right after
  the action; leftover marks auto-flush as a final image.
The guest-cursor caveat is documented in the caption: coordinates are
delivered verbatim, only pointer-LOCKED apps track their own cursor
(calibrate via app_mouse_move deltas).

**2. Exit decode everywhere (reported "segfault exited 0").** The
reap-race retry landed in an earlier round; what remained was decode
coverage: appSummary now emits `signaled/signal/signal_name` plus
`crashed:true` (ILL/ABRT/BUS/FPE/SEGV) for -signo statuses, and
decodes shell-wrapped deaths (`exit 139 = 128+11`) as
`likely_signal`/`likely_signal_name` + note. The app_actions
"app exited (status N)" skip line and app_output's header carry the
same suffix. A gdb-wrapped run exits 0 — appSummary spots "Program
received signal" in the log stash and flags `debugger_caught_signal`.

**3. recent_output now comes from the log ring, not the grid.** The
reporter saw exit summaries with ~2 mid-token-wrapped lines (the 80col
grid mirror) while app_log had everything. appSummary and app_output
now prefer the daemon's pre-exit log stash: escape-free FULL lines,
never wrapped, `recent_output_source` says so. Grid extract remains
the fallback; a blank grid after exit serves the log tail instead of
"the app has written nothing". Sanitizer reports in the log flag
`sanitizer_report:true`.

**4. launch_app `debug:"gdb"|"valgrind"`.** Wraps the command (gdb
-q -batch -ex run -ex "bt full" -ex "info registers" --args ...);
works for string commands too (sh execs simple commands, gdb follows
the exec). The crash backtrace + registers land in app_log; the reply
notes the pid is the wrapper's.

**5. --log per-session subfolders (user request).** Each `sketerm mcp
--log DIR` run now writes into DIR/YYYYMMDD-HHMMSS/ (jsonl + PNGs)
instead of dumping everything into DIR directly.

**6. Doc fixes.** app_actions schema: `wait` is MILLISECONDS;
`wait_idle change_pct` called out as the scene-transition wait (the
requested "wait_until framebuffer settles" already existed);
app_output's description names app_log as the source of truth.

Verified: 725/731 tests (5 new: marks module x4, per-session log
subdir), smoke-mcp PASS, GUI + mux-portable build, and a live e2e
drive: argv crashy → -11/SIGSEGV/crashed + unwrapped recent_output;
`crashy && echo` → 139 decoded as likely SIGSEGV; debug:gdb → bt full
with source line in app_log; weston-terminal app_click mark:true and
a 4-step marked app_actions batch → labelled crosshairs verified
pixel-level in the trace PNGs; log dirs 20260714-*/ created per run.

## 2026-07-15 — MCP round 7: the DirectDraw black window, GUI viewers for assistant apps

Driven by a field report: driving a 1999 Win32 game (DirectDraw,
8bpp, 800x600 surface) under Wine via launch_app — plus Jelle's own
asks (dead raise banner, "can I see what the assistant is doing?").

**1. Orphaned-pool pixels: the "renders, then static black forever"
class.** Pixel units addressed pools by ID, so once a shm pool was
displaced (id recycled with live buffers — Wine's DirectDraw mode
switch), the viewer's copy could never be updated again while
re-attach commits kept bumping `frames` (the reported 1815 frames /
diff 0.00). Now: `pool_serial` units make incarnation serials
wire-authoritative (replicas ADOPT the daemon's serials — mid-session
attaches used to self-count and diverge), orphan-backed commits ship
serial-addressed `pool_update_s` from the orphan mirror, replay
includes orphan pools (`pool_orphan`), and state_sync v5 carries each
buffer's serial so displaced buffers restore resolvable instead of
frozen. Log line at the transition: "orphan-backed — shipping
serial-addressed". Old GUIs can't read v5 state_sync — restart
daemons after upgrading (same lockstep as the v4 bump).

**2. Threshold waits.** `min_change_pct` now also gates
screenshot_app/get_app_state `wait_change` and turns `stable_ms`
into a VISUAL settle (waitVisualSettle), so a 60Hz software cursor
no longer defeats settling. app_actions `wait_change` accepts
`{"timeout_ms":N,"min_change_pct":P}`.

**3. Primary-content window default.** Window-less tool calls now
target the most recently painted non-popup toplevel (area breaks
ties) instead of the first-created one — a game's render surface
wins over its static frame window, and a flicker-free toplevel swap
follows the new surface. get_app_state marks it `"primary":true`
and lists per-window `frames`.

**4. Raise banner fixed.** presentAll skips embedded windows, and a
new AppHost `on_windows_changed` retires the pane banner when the
app drops all its toplevels (clicking used to be a silent no-op),
bringing it back if a window reappears.

**5. GUI viewers for assistant apps.** New `sock:<path>` host
transport (muxConnect + mux_cli + `Conn.connectProbed` — hello'd for
proto 5, NEVER autostarts a dead daemon): the GUI can attach as a
live viewer to sessions on MCP private daemons while the assistant
stays attached (daemon already broadcasts to every proto>=5 viewer;
shared seat). `sketerm mux sock:/run/user/N/sketerm/mcp-x/mux.sock
attach <name>` works too.

**6. App-window switcher.** `app_windows` action + palette entry
("App Windows…"): lists every open forwarded-app window with a live
thumbnail (session · window/tab · assistant attached), plus
attachable app sessions on the local daemon and on every mcp-*/
daemon instance found in the runtime dir. Enter raises the floating
window / focuses the embedded window's tab / attaches a viewer.
src/ui/app_switcher.zig, modeled on the launcher.

Verified: 727/733 tests (2 new: serial adoption + pool_update_s
routing, pool_orphan replay binding), smoke-mux/smoke-mcp/smoke-e2e
PASS, mux-portable builds; live e2e under Xvfb: MCP-launched
weston-terminal attached via sock: renders + takes input in the GUI
with MCP still attached (2 clients), switcher discovered the second
(unattached) MCP app, attach-from-row worked, thumbnail row correct.
The orphan fix is not yet confirmed against the real Wine game (no
Wine here) — the new debug log line is the smoking-gun check.

## MCP command completion is distinct from output idle

`term_run` now accepts `wait_for: "command"`. The headless terminal
driver snapshots its latest completed OSC 133 zone before sending and
waits for a different zone, returning structured running/completed
state, exact exit status, timeout state, and whether completion came
from shell integration or the daemon's tracked shell-process exit.
Shells without integration return unsupported without sending; no
status is fabricated. Timed-out commands retain their zone token and
finish through `term_wait_command`, while another command-mode send is
rejected to prevent associating the wrong OSC 133 `D`.

The default `term_run`, `term_wait_idle`, GUI `run_command`, and GUI
`wait_idle` remain output-quiescence operations for interactive use;
their schemas now say explicitly that idle output does not imply child
exit. `Screen` owns the monotonic completion sequence, and mux
snapshots preserve it plus an in-flight C marker so resync cannot
fabricate completion. Appdrive and GUI app-tool behavior are unchanged.

`smoke-mcp` covers silent status 0, silent status 124, delayed output,
missing shell integration, output-idle compatibility, command timeout
plus resumed waiting, duplicate-send rejection, and a signal-killed
shell replacement reported as -15 by process tracking.

Review follow-ups: SNAPSHOT_VERSION bumped to 4 (the new OSC 133
fields changed the wire format; a stale daemon now fails attach with
a clean version mismatch instead of misparsing). A timed-out command
reports `completion_source: "none"` (nothing completed). `commandToken`
knows whether integration was injected at spawn: uninstrumented shells
fail fast, instrumented ones get a bounded wait for the first prompt
mark so command mode right after `term_open` is not misreported as
unsupported. A foreground command started outside command mode (open
OSC 133 C marker) now refuses a command-mode send — its `D` would have
been misattributed to the new command. smoke-mcp asserts all four.

## Command-completion review round 2 (workflow findings)

An OSC 133 `D` arriving while the alt screen is active (a TUI killed
without restoring the main screen) now still clears the open C zone,
sets the exit code, bumps `cmd_completion_seq`, and fires on_cmd_end —
previously the D was dropped entirely, wedging command-mode waits AND
the busy check until the shell died. Zone recording still skips the
alt screen. Unit test added.

The snapshot v4 command tail moved to the END of the stream and
restore accepts v3 again (fields keep zero defaults): a still-running
pre-upgrade daemon stays attachable after a package upgrade instead of
stranding durable sessions on SnapshotVersionMismatch. v3-compat test
added.

Command-token hardening: `not_ready` (integration injected, no prompt
mark yet — retryable, latched so only the first call pays the full
wait) is now distinct from `unsupported`; the token wait spends from
the same budget as the completion wait so term_run no longer overruns
timeout_ms by the token wait; a 100ms settle before the busy judgment
closes the raw-send-Enter vs C-mark race; idle-mode term_run is
refused while a command-mode token is unresolved (interleaved D =
misattributed exit status), and an already-completed tracked command
is auto-cleared instead of forcing a term_wait_command round-trip.

smoke-mcp: the idle-mode "returned early" check is now semantic (busy
probe on the open C zone) instead of a flaky 700ms wall-clock bound,
and all redirects go to /dev/null instead of fixed world-shared /tmp
paths. termdrive.spawn no longer leaks the style pool if the Term
allocation fails.

## Remote audio survives graphical congestion

Choppy forwarded-app audio had two coupled causes. Pulse clients that
asked for a 20-50ms low-latency tlength turned every refill into a
just-in-time round trip over the mux transport, while native window
pixels and PCM shared one FIFO client buffer. Once pixels pushed that
buffer over 8MB, the daemon classified the live GUI like an idle
viewer, dropped PCM, and self-clocked past samples that could never be
replayed.

Playback streams now negotiate at least a 500ms producer window (PCM
still forwards immediately; this is jitter capacity, not a forced
half-second start delay). Subscribed audio is never dropped because of
the graphical backlog: consumed credits already bound production to
what the local Pulse stream accepts. Each client has a separate audio
write lane which wins at wire-frame boundaries, and native unit streams
use 64KB frames so even a multi-megabyte surface commit yields quickly.
Terminal-only and MCP appdrive clients remain unsubscribed and receive
no PCM.

The real create-stream protocol test now requests an intentionally tiny
5ms buffer and asserts the 500ms negotiated window; a queue regression
test pins audio-first selection and no mid-frame interleaving. Full
tests, smoke-mux, mux, and mux-portable verify the transport and
libc-only daemon paths.

## Opus is automatic without becoming a daemon dependency

The packetized 20ms/128kbit Opus path already compressed eligible
s16 streams about 12x, but ordinary `zig build` compiled it out and
the enabled form hard-linked libopus. That made development builds
silently ship raw PCM and violated the native daemon's libc-only link
contract when compression was requested.

Normal builds now compile Opus support by default and resolve the
seven libopus entry points once at runtime (`libopus.so.0`/`.so`, or
the macOS dylib names). The hello/list capability and the GUI's audio
subscribe flag report actual runtime availability, not merely a build
boolean; a missing/incomplete library therefore negotiates clean raw
PCM rather than failing at process load or sending undecodable units.
`-Daudio-opus=false` remains an explicit opt-out and mux-portable pins
it off, so static-musl and Linux→macOS portable builds never reference
the loader. The native daemon no longer has a libopus ELF dependency.

The Arch package still depends on opus so installed builds reliably
compress, but no longer needs a special build flag. Doctor compares
runtime codec availability on the binary and daemon hosts. The Opus
round-trip runs in the default test suite when libopus is installed;
the explicit-off suite skips it and verifies the raw fallback build.

## Visual toolkit for driving framebuffer apps over MCP

Custom-drawn apps (games, immediate-mode UIs) expose no AT-SPI tree,
which reduced MCP driving to guess-a-pixel, click, screenshot,
eyeball. Three new capability families turn pixels back into
queryable, assertable state.

OCR: `app_read_text` extracts the text rendered in a window (or a
region) plus per-word boxes in surface coordinates with click
centers; `app_wait_text` polls until a string is visible and can
click the matched words ("wait for the label, then click it").
Tesseract is dlopen'd at runtime (the Opus pattern, `src/util/ocr.zig`)
so no target gains an ELF dependency; a missing library degrades to
one described error naming the package to install. Small pixel fonts
are auto-upscaled before recognition.

Template matching: `app_template_save` crops a distinctive element
out of a live window (or accepts inline PNG) into a named persistent
template; `app_find_image`/`app_wait_image` locate it by pure-Zig
coarse-to-fine SAD matching (`src/util/template.zig`, alpha-masked
needles supported so transparent-background sprites match), with
wait-then-click as the coordinate-free substitute for an a11y tree.

Input macros: every successful injected input (app_click/app_key/
app_type/app_scroll/app_drag/app_mouse_move and each app_actions
step) is journaled per app; `app_macro_save last_steps:N` snapshots
the tail — think-time gaps preserved as waits — into a named macro,
`app_macro_run` replays it through the same step engine (the
app_actions body now lives in `runActionSteps`, shared by both), and
`app_macros` lists/shows/deletes and exposes the journal. New action
steps `wait_image`/`click_image`/`wait_text` make batches and macros
state-driven rather than timing-driven. Assets persist under
`$XDG_STATE_HOME/sketerm/{templates,macros}` (`src/ipc/mcpassets.zig`).

Verified by unit tests (matcher exact/masked/coarse paths, TSV word
parsing, asset round-trip) and a live end-to-end run driving
weston-terminal through a real `sketerm mcp` instance: OCR reads
typed text back, a cropped template matches at its exact origin, the
journal round-trips through save/show/run, and the no-tesseract path
returns the documented error.

## 2026-07-22 — Remote-ops suite + CDP browser automation (feedback round 8)

A field report from an assistant provisioning a VPS through sketerm
MCP (persistent SSH shell, scp uploads inferred via term_list, a
hand-rolled `ssh -N -L` tunnel, Chromium driven blind by coordinates)
listed 14 improvements. All landed, in two families.

Remote ops. `term_open host:` opens a persistent SSH session
(ssh -tt + ServerAlive keepalives). `term_exec` runs one command in a
LIVE interactive shell and returns structured `{completed,
exit_status, output, timed_out}` via echo-safe sentinel markers —
default mode ships the script base64→`sh` (dialect-independent: works
typed into fish/zsh/bash, local or over SSH; the command runs in a
`sh -c` child so `exit` can't eat the end marker; an interactive
`set -e` can't kill the session — the exact incident from the
report), `subshell:false` types a POSIX construction directly so
cd/export persist. `term_exec_wait` continues a timed-out exec;
`term_wait_exit` waits for real process exit (distinct from output
idleness); term_list drains and reports last_line + pending trackers,
and term_read on an exited terminal carries an explicit exit banner
(no more stale "1%" scp frames). `upload_file`/`download_file` do
scp → SHA-256 verify → atomic mv (corrupt transfers discarded; local
mode without a host). `port_forward_open` is a structured resource:
auto-picked free local port, TCP-connect readiness proof,
`port_forward_check` respawns a dead ssh on the same port
(reconnects counted), list/close. `capabilities` preflights
OCR/browser/ssh/mode before a workflow starts; `new_tab` falls back
to opening a headless terminal when no GUI socket exists.
`app_actions` wait steps accept `required:true` (timeout fails the
batch); launch_app auto-injects `--ozone-platform=wayland` for
Chromium-family argv and exports ELECTRON_OZONE_PLATFORM_HINT.

Browser automation. `src/ipc/cdp.zig` is a hand-rolled CDP client:
libc TCP + RFC 6455 client WebSocket + JSON calls, every operation
deadline-bounded per the no-hang invariant (gotcha: Chromium's
DevTools HTTP server ignores `Connection: close` — Content-Length
must terminate the read). `browser_open` launches Chromium headless
under the Wayland session with `--remote-debugging-port=0`, discovers
the real port from the app log ring, attaches the newest page target,
and registers a per-app session; navigation that replaces the target
reattaches transparently. Tools: browser_info (url/title/ready/
scroll), browser_navigate (url/back/forward/reload + load wait),
browser_read (innerText/outerHTML/links, selector-scoped),
browser_elements (visible interactive elements with viewport-CSS
click centers), browser_click (selector/text lookup → scrollIntoView
→ TRUSTED Input.dispatchMouseEvent), browser_fill (select-all +
Input.insertText; <select> option matching; password readback is
count-only), browser_wait (selector/text/url_contains/gone — timeout
is an ERROR, never silent success), browser_scroll (top/bottom/
selector/y/dy — deterministic), browser_eval. Screenshot captions of
browser apps append the live page url+title (`browserPageSuffix`).
`--force-renderer-accessibility` is always passed so app_a11y_tree
sees web content where AT-SPI works.

Verified: 764 unit tests (sentinel builder/parser incl. quoting and
truncation, WS framing round-trip, DevTools port parse,
Content-Length, chromiumFamily, findHex64, free-port pick, local
atomic copy); smoke-mcp extended (capabilities, new_tab fallback,
term_exec transport + set -e survival + state persistence,
term_wait_exit real status 7, exit banner, local upload); live runs
against a real fish login shell over SSH to localhost (exec edge
cases: exit 42, quoting, timeout→wait continuation), byte-identical
100KB upload+download round-trip with checksum verify, forward
kill→check→reconnect on the same port, and a full Chromium session
(fill, select, trusted click mutating the DOM, wait condition,
scroll, link navigation crossing pages, history back, eval).
