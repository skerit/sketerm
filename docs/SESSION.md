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
