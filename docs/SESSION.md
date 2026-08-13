# Autonomous build session — 2026-04-25

## 2026-08-13: reader-mode semantic IDs

`web_read` now returns reader markdown and a structured `entities` list
for useful sections, headings, links and list items. Every entity ID is
from the same per-view stable semantic space as `web_snapshot`, so it can
be passed directly to `web_act` without taking a snapshot first. Labels,
URLs and markdown remain explicitly page-authored data.

The wire change is append-only and capability-gated: `reader-ids` adds
`sem_read_ids` 0x6A, `sem_read_ids_result` 0x6B and
`sem_act_guarded` 0x6C. The result carries unchanged markdown plus
`doc_gen`, `rev`, and `{id, guard, kind, text, url}` records. A guarded
action refreshes the semantic walk and requires the exact document,
revision, stable ID and opaque action fingerprint (including renderer
element identity and exact link href)
before using the existing trusted pointer/focus/value path. A stale or
retargeted entity returns `sem_act_result ok=0`; it never falls through
to a node on the changed page. Clients retain typed provenance for every
reader ID they exposed. New reads refresh matching guards and invalidate
absent ones; snapshots leave provenance intact, while navigation, stop,
discard, renderer crash and helper replacement make the guards deliberately
stale.

Compatibility is explicit in `mcp_web.zig`: a helper without
`reader-ids` is sent the old `sem_read` and its response is treated only
as markdown, even if the page made that markdown look like the new JSON
model. The response tells the caller to use `web_snapshot` before
acting. No existing frame layout or meaning changed.

Unit coverage in both roots pins rich-result serialization, page data
escaping, stable-ID rewrite, revision invalidation, action fingerprints,
the reserved tags, navigation reissue bookkeeping and old-capability
fallback. Helper requests now carry a navigation generation and renderer
document token; reads/snapshots/hints are reissued after the new context
loads, while actions are failed explicitly. Pending owned arguments have
a 120s deadline and are released on reply, timeout, renderer crash,
browser close/discard and helper teardown.

The follow-up correctness pass added capability
`semantic-request-ids`: `sem_request` 0x6D and `sem_result` 0x6E wrap the
unchanged semantic request/result payloads with a client operation ID.
New GUI and headless clients correlate on that ID, so a reply arriving
after a client timeout cannot satisfy a later same-kind request. Legacy
helpers remain supported, but a timed-out kind is quarantined until its
uncorrelated reply arrives or the connection resets. `webdrive.runOp`
also resolves the view by ID after every pump and its cleanup does the
same, so helper loss cannot leave a defer writing through a freed view.
Stop-load and renderer termination now invalidate the helper shadow tree
without resetting stable-ID/document counters, preventing pre-crash
reader IDs from aliasing a later document. The GTK/CEF-free navigation
state machine lives in `web/semnav.zig`; the shared client guard store lives
in `web/reader_guards.zig`. Both are imported by both test roots.

Measured E2E coverage now spans all three adapter cases. smoke-web stage
41 reads an ID without a snapshot, activates exactly its trusted link,
refuses an href-retargeted entity, correlates two overlapping rich reads
whose replies arrive in reverse order, reissues legacy and rich reads
across navigation, rejects a guarded action interrupted by navigation,
and explicitly answers a rich read canceled by stop-load. The
focused real headless MCP stage exercises `web_read` -> `web_act` ->
stale refusal and capability-suppressed markdown fallback. The focused
external-display GUI stage exercises the same reader-ID flow through the
real control-socket `web-request`/`web-result` adapter. All focused stages
pass. The full smoke-web run passed stage 41 and later reached stage 27
before the command budget expired; the full smoke-e2e run failed earlier
in the existing Kitty keyboard stage (the shell did not run its protocol
enable command), before browser coverage.

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

## Automatic asciicast recording of MCP terminals

Every headless terminal the MCP server spawns — term_open sessions
(incl. SSH), the new_tab fallback, and the scp/ssh/forward helper
terminals behind upload_file/download_file/port_forward — is now
recorded automatically as an asciicast v2 file, the terminal
counterpart of the --log message/screenshot trace. The daemon does
the recording (existing `rec_start` wire frame; fire-and-forget from
termdrive, finalized with the session, fflushed per event so files
replay even mid-session). Casts land in the --log session folder
when logging is on, else $XDG_STATE_HOME/sketerm/mcp-casts/
<stamp>-<pid>/ (`term-<id>.cast`, `aux-<n>-<label>.cast`); the paths
surface in the term_open reply, term_list, and capabilities.
`--no-record` opts out. Verified by smoke-mcp (isolated
XDG_STATE_HOME; header + recorded output asserted) and a live run:
an SSH terminal's cast contains the remote command output, and an
upload produced aux-1-scp / aux-2-ssh casts next to the mcp log.

## Feedback round 9 — interactive-prompt observability for term_exec

The field report's key defect: an apt run hit a needrestart dialog,
term_exec burned its whole timeout blind (hiding the dialog), the
blocked single-threaded loop made term_list/term_read time out too,
and the client aborted term_exec_wait. Fixes: a pending exec now
returns `pending:true` + tracker id + the LIVE rendered screen +
`alt_screen` + `output_idle_ms` + `interactive_prompt` (prompt
heuristic over the output tail: y/n suffixes, trailing ?/:,
password/press-enter, or alt-screen active), and returns EARLY when
output goes quiet behind such a prompt instead of waiting out the
timeout — answer via term_send_text, term_exec_wait (always
reattachable, incl. after client-side aborts) completes it. All term
wait timeouts clamp to 120s, under the 150s watchdog. Plus:
`noninteractive:true` (DEBIAN_FRONTEND + debconf + needrestart env on
the sh -c child only), `output_file` (full output to a local file,
tail inline), upload staging that preserves the file extension
(hohenheim.sketerm-part.service) with `verify_command` running a
remote validation against the staged file before the atomic move
(nonzero = discarded, destination untouched), and remote transfer
scripts now travel base64→sh (dialect-proof like term_exec).

Verified: 766 unit tests (prompt heuristic, staged naming), smoke-mcp
(read -p flow: early pending + screen + tracker, answer, resume;
output_file on disk), and live SSH runs — `less` returning pending
with alt_screen after 2.6s idle then completing via q, verify_command
accept/reject with clean staging, noninteractive env reaching only
the child.

## Feedback round 10 — shadow-DOM browser automation + network inspection

The field report's top asks after provisioning Hohenheim (a custom-
element pl-input/pl-select/pl-switch admin UI): structured browser
tools could not see inside shadow roots, there was no clean way to
pick options in custom dropdowns, navigation completion was guessy,
and network diagnostics required leaving the tool family.

Browser: every element script now shares JS_HELPERS — deepQuery
(walks open shadow roots), labelText (labels/aria/host text/shadow
labels), activeDeep (nested activeElement). browser_fill text_label
finds the editable input inside a custom host; browser_elements
reports role/label/name/value/checked/disabled/expanded/options for
custom hosts; new browser_form_state = one-call form inventory
(host + inner control merged, password values as counts, select AND
[role=option] options with selected marked, validationMessage, form
owner); new browser_choose picks options in native selects, shadow
selects, and ARIA/custom dropdowns (trusted click on the shadow
trigger, poll for [role=option], click the match, read back; failure
lists the options that WERE visible and presses Escape). Navigation
honesty: browser_click reports navigated / navigation_pending (and
wait_navigation:true blocks until the load ends); browser_fill
reports field_detached_after_submit / navigation_started instead of
a bogus empty readback; browser_wait grew url_exact / url_path /
url_regex (url_contains substring false-positives) and network_idle.
New browser_network: CDP Network.* capture (bounded 300-entry ring
in cdp.Client, on from browser_open, re-enabled on reattach, pumped
during calls) listing method/url/status/type/mime/failure/redirect
chain (redirected_from keeps a 303'd POST findable) with request-body
FIELD NAMES only — values are never stored.

Terminal: term_exec `shell:"bash"` swaps the command-file interpreter
(pipefail semantics) with the name validated against metacharacters;
the isolated transport now writes the command into a second temp file
via quoted heredoc and runs `<shell> /tmp/.sk_<nonce>.c`, so the
command text never appears on any process command line (pgrep/ps
noise gone — smoke asserts the canary count is exactly 1).

Verified: 762 unit tests + 6 skip (new: extractPostKeys redaction,
validShellName, heredoc/shell transport shape), smoke-mcp (bash
pipefail, shell-injection rejection, ps canary), and two live
Chromium runs against a custom-element page served over HTTP: full
form_state before/after, shadow fill, choose on pl-select and native
select, switch toggle via click (checked false→true), network_idle
wait over a 2s fetch, POST→303 login with post_keys "user,pass" and
the secret nowhere, wait_navigation across pages, url_path negative
staying an error.

## MCP: click-and-settle input capture + resilient app_log (round 11)

Feedback from the AFU reverse-engineering assistant: post-click
screenshots were frequently the PRE-click frame (the idle-only wait
returns instantly-quiet on an app that takes a moment to react), and
app_log could time out with a bare error while the app was demonstrably
alive.

Click-and-settle: app_click/app_key/app_type/app_drag/app_scroll now
capture their FrameRef (commit counter + optional pixel copy,
appdrive.frameRef) BEFORE injecting input; when a screenshot is
requested the capture waits — bounded, default on — for a frame
committed strictly AFTER the input (appdrive.waitChangeSince; unlike
waitWindowChange it ignores the screenshot baseline, so frames landed
between the last screenshot and the input can't satisfy it, and
PostInputWait.begin drains the mirror first so queued pre-input frames
don't either). The caption states 'repainted Nms after the input' or
'NO repaint within Nms' — a dead click is structurally distinct from a
late frame. settle_ms adds settle-then-capture (visual settle with
min_change_pct), wait_change:false opts out, timeout_ms bounds it
(default 1500ms when defaulted-on, 5000ms when explicit).
screenshot:true is new on key/type/drag/scroll.

app_log: appdrive.logGet now returns LogFetch{json, stale} — when the
daemon's fresh reply is still queued behind streamed frame data at the
deadline, the last cached reply is served with a [STALE] banner
(partial beats nothing; single-line id fetches refuse stale data
honestly). The hard-timeout error (no cache at all) reports app
liveness, window count, and frames committed so 'log stuck' and 'app
wedged' are distinguishable.

Verified: 762 unit tests + smoke-mcp pass; live Chromium runs — click
on a page with an 800ms-delayed repaint reports 'repainted 916ms after
the input and settled' (settle_ms:300) and captures the post-flip
frame (hashes differ), min_change_pct:50 + timeout 500ms yields the
explicit NO-repaint note with the screenshot still delivered, app_key
F5 screenshot:true and app_drag screenshot:true both work, app_log
serves fresh lines normally.

## MCP: default crosshair clicks, default settle, frame-flood-proof app_log

Round-11 follow-up from live testing on AFU (a continuously-committing
game): the crosshair earned default status, the first post-input frame
was sometimes a mid-repaint, and app_log still starved because the
daemon-side queue toward the PRIMARY appdrive connection grows without
bound between tool calls (nobody pumps it), burying log_data
arbitrarily deep.

app_click now replies with the marked post-click screenshot BY DEFAULT
(mark:false for plain text). All five input tools settle 250ms by
default before capturing (settle_ms:0 opts out). Schemas state the
honesty limits: on always-animating apps the dead/live verdict needs
min_change_pct, and 'NO repaint within Nms' is not proof of a dead
click on a slow-reacting app.

app_log: logGet now falls back to a FRESH side connection
(appdrive.logGetFresh — proto-1 hello so the daemon replays no native
channels, empty write queue so log_data lands right after the attach
snapshot), then the [STALE] cache, then the PTY grid mirror; an error
only when nothing is reachable. Testing exposed a correlation bug: a
reply buried from an EARLIER request surfaced during a later wait and
served OLDER ring content as fresh (next_id went backwards across
calls). log_get requests are now nonce-stamped; the daemon echoes the
nonce in the reply header (before "lines" — line text is arbitrary app
output and is never scanned) and the client skips non-matching strays.
No-nonce replies (old daemons, the pre-exit push) are accepted as
before, so durable sessions on a pre-upgrade daemon stay usable.

Verified: 763 unit tests + smoke-mcp pass (new logNonceOf test;
appdrive.zig now registered in tests.zig); live Chromium with a
full-window CSS animation — app_log served fresh lines with monotonic
next_id (14, 14, 27) across idle-separated calls where the previous
build regressed to older content, daemon log shows the proto-1 side
attaches; bare app_click returned the marked frame with 'repainted 5ms
after the input and settled'.

## 2026-07-22: MCP input fidelity + env-tunable timing defaults

Feedback from an agent driving a DOS-game port via the app tools
(slow app, edge-polling input loop, buttons that need a second press)
landed as six changes:

- app_click hold_ms (default 100, human-like): the button stays down
  between press and release. An instantaneous press+release can be
  collapsed into one sample by apps polling per-tick edge counts, and
  press-armed repeat widgets never fired at all. appdrive.clickEx
  pumps frames during the hold (never a blind sleep). Every
  server-synthesized click (template/OCR match clicks) goes through
  the same default (clickTuned).
- app_click count:2/3 = real double/triple click (~80ms apart) — two
  separate MCP calls always exceed any double-click threshold.
- app_click retry:N re-clicks when the post-input wait produced a NO
  qualifying repaint verdict (default 0; only on a WAITED verdict, a
  repainted window never gets a second press).
- app_key hold_ms (+ per-step hold_ms/count in app_actions click/key
  steps; appdrive.pressKeyHold): held keys drive client-side
  key-repeat. Journal records hold/count so macros replay faithfully.
- Env-tunable defaults for the timing knobs (project .mcp.json env):
  SKETERM_MCP_HOLD_MS / SKETERM_MCP_SETTLE_MS / SKETERM_MCP_TIMEOUT_MS
  / SKETERM_MCP_CLICK_RETRY (clamped; the explicit-wait budget stays
  >= 5s). Config sets the NEW DEFAULT and tools/list SAYS SO: the
  static TOOLS_JSON carries %..._DEF% tokens rendered from the same
  Tuning struct the handlers read (renderedToolsJson) — description
  and behavior cannot drift; an override renders as "default 15000 —
  PROJECT OVERRIDE via SKETERM_MCP_TIMEOUT_MS, built-in 1500".
  capabilities reports the effective values + override flags, and
  overrides are logged at startup.
- min_change_pct is deliberately NOT env-tunable: it decides the
  dead/live VERDICT, not a timing bound — an invisible default there
  manufactures false verdicts. The schema now says so.

## 2026-07-22: MCP stale-frame fix — backlog gap + live-mirror resync

Feedback from an assistant reverse-engineering an SDL2 game:
screenshot_app returned frames whole SCREENS old (persisting for tens
of seconds while the app's own readback checksums proved it was
rendering correctly), launch_app dropped an `args` array, and
app_mouse_move never moved the app's internal cursor.

Root cause of the stale screenshots: between MCP tool calls nobody
drains the appdrive connection, so the daemon-side wbuf for that
client grows without bound; past NATIVE_BACKLOG (8MB) the daemon
skipped PIXEL units but kept streaming the tiny wl_msg commits, and
the client's 100ms time-boxed drain() chewed only part of the backlog
per call — frames incremented, pixels lagged by whole screens
(exactly the reported 652 -> 1348 -> 2731 frame counts with an
unchanged image). Landed as:

- Daemon: native app-channel units toward an "mcp"-kind client STOP
  entirely once its wbuf crosses NATIVE_BACKLOG — a `native_gap`
  frame (wire 83) marks the pause, and the cap is re-checked AFTER
  queueing each unit run (one burst batch can blow past it in a
  single queueUnits call). When the client fully drains,
  clientWritable rebuilds its replicas from the LIVE pool mirrors via
  replayNativeChannels (video keyframes forced) and closes the replay
  with `native_sync` (wire 84). GUI clients keep the old
  stream-always behavior.
- Daemon: commits whose pixel copy was skipped (no viewer with queue
  room) accumulate their damage per surface (Native.skipped,
  RowRange.mergeOpt in track.zig — null = full buffer); the next
  SHIPPED commit merges it into its copy range, so partial-damage
  clients no longer keep permanently stale regions after a viewer
  recovers. Benefits GUI viewers too.
- appdrive: repeated chan_open for a live channel rebuilds the
  replica IN PLACE (Window objects survive — ensureWindow dedupes by
  chan+sid, so public window ids stay stable); windows the replay
  never re-announces are pruned at native_sync (they died during the
  gap). `behind` tracks gap→sync; drainLive(max_ms) pumps to the LIVE
  head including a pending resync. mcp.zig calls drainLive at appTool
  entry and before post-input FrameRef baselines (CATCHUP_MS 1500);
  screenshot captions warn if a capture happened while still behind.
- launch_app grew the `args` array the reporter assumed existed (it
  was silently dropped -> argc==1): appended after an argv command;
  with a STRING command the string becomes the bare executable (not
  shell-parsed). buildLaunchArgv extracted + unit-tested.
- app_mouse_move dx/dy on FIRST contact was swallowed: the enter
  event resets the brain's delta base to the enter coords, so the
  entering motion derived relative_motion (0,0) — the documented
  corner-slam calibration did nothing on pointer-locked apps (SDL
  games, the exact reporter scenario). moveMouseRel now places the
  pointer at the base first, then moves by the delta in a second
  motion. Schema notes that pointer-locked apps suppress ABSOLUTE
  motion (use dx/dy).

Verification: smoke-mux gained nativeBacklogStage — a fake Wayland
app floods 250 x 64KB incompressible commits at a stalled mcp-kind
client, with registry-reply barriers pinning WHICH content each
commit was encoded against; asserts gap, replay chan_open,
state_sync, native_sync, and that the replayed pool bytes equal the
LIVE mirror (the final content), not the flood-era content. Unit
tests: replica rebuild keeps window identity + prunes gone windows,
first-contact moveMouseRel emits place-then-move, buildLaunchArgv
shapes, RowRange.mergeOpt. Full: zig build test (772 pass),
smoke-mux, smoke-mcp, smoke-e2e (xvfb), mux-portable (musl +
aarch64-macos), sketerm-mux still links libc only.

## 2026-07-22: stale-frame fix round 2 — the broker handoff dropped `kind`

The DS9DW assistant retested and both bugs "reproduced" — because the
installed package (/usr/bin/sketerm, r993.gecfca39) predated the fix.
But rebuilding and reproducing locally with a ground-truth A/B app
(weston-terminal running a raw-mode bash loop that flips the whole
screen A->B on a keypress, driven over real MCP NDJSON) surfaced a
REAL hole anyway: `sketerm mcp` isolation runs the daemon in BROKER
mode, and the 'A' worker-handoff datagram carried only [proto][video]
— the worker saw `Client.kind == .unknown`, so the entire mcp-gated
gap/resync policy silently never engaged. Monolith smokes were green;
the actual MCP stack stayed stale. Landed as:

- The 'A' handoff datagram grew a kind byte ([proto][video][kind],
  `Client.Kind` enum with stable wire values; absent byte = unknown,
  so old broker + new worker degrades to the old behavior).
  addPassedClient logs the kind and now also broadcasts peer_info.
- `MCP_NATIVE_BACKLOG` (1MB) split from `NATIVE_BACKLOG` (8MB): a
  sub-cap backlog is chewed at replica-COMPOSE speed (full-window
  memcpy per intermediate frame), so 8MB of queue was seconds of
  catch-up — over the tool-entry budget, silently stale. 1MB bounds
  catch-up under the budget. CATCHUP_MS raised to 2500.
- drainLive() now RETURNS whether the live head was reached and sets
  `App.lagging` on a deadline exit; screenshot captions warn
  ("frame stream still catching up") on behind OR lagging — a capture
  can no longer silently pretend to be current.
- The backlog smoke stage moved to `src/smoke_backlog.zig` and runs
  in BOTH smoke-mux (monolith) and smoke-broker (real forked broker +
  worker) — single-mode coverage is exactly how the handoff bug
  shipped. The stage discovers the newest wl-* display socket (works
  for wl-N and broker wl-w<pid> naming) and kills via a fresh
  connection (the attached conn is worker-served in broker mode).

Verification: end-to-end over real `sketerm mcp` NDJSON — after a 45s
no-tool-call gap on a continuously-committing app, gap+resync engage
(daemon log), and the screenshot taken immediately after the A->B
keypress shows the B screen (23.6% pixel diff vs pre-press, 1.9%
noise vs settled B; the same test on the pre-fix build showed the
stale A screen). launch_app args verified end-to-end: new binary
delivers ["ARG1","ARG2"] to /bin/echo, installed pre-fix binary drops
them — confirming the retest ran old binaries. Full suite: 772 tests,
smoke-mux (6x, flake-checked against a baseline build), smoke-broker,
smoke-mcp, mux-portable musl + aarch64-macos, daemon still libc-only.

Known pre-existing issue surfaced while validating (NOT from these
changes; reproduces at ecfca39): smoke-mux occasionally logs a
DebugAllocator "Allocation size 38 does not match free size 37" —
some 37/38-byte string is freed with a mismatched length somewhere in
the daemon. Worth a separate hunt.

## 2026-07-23: MCP crash-debug loop — gdb_commands, exit-during-wait, region diffs

Driven by field feedback from an assistant iterating on game crashes
headlessly (relaunch-per-crash was the dominant cost; a click-caused
crash read as "post-click screenshot failed (no pixels yet?)").

- `launch_app gdb_commands:[...]` (debug:"gdb" only): extra gdb
  commands appended as `-ex` args AFTER the automatic `bt full` +
  `info registers` and BEFORE `--args`, so they execute at the crash
  point — `["frame 3","p *ctx","x/8xw $rcx"]` dumps the state that
  previously needed a relaunch. Entirely client-side in mcp.zig (the
  wrapper argv rides SpawnReq.argv; no wire/daemon change). Extracted
  the wrapper block into `applyDebugWrap` + unit tests; rejected for
  valgrind and without `debug`.
- Exit-during-wait honesty: every post-input/wait path now reports an
  app exit AS an exit with the signal, instead of a misleading
  verdict. `PostInputWait.finish` re-checks `app.exited` after a
  false change-wait (the appdrive wait primitives bail on exit but
  collapse it into plain bools) and returns "app EXITED during the
  post-input wait (status N = killed by SIGSEGV)"; `inputResult` and
  app_click then skip the doomed screenshot and attach the full exit
  summary (signal/crashed/recent_output). Teardown race: the window
  vanishes BEFORE the `.exit` frame is parsed, so a gone window pumps
  bounded (`App.windowGone` + `App.settleExit(1s)`) before judging.
  app_wait no longer says "settled" when the app died mid-wait;
  app_actions wait_idle/wait_change steps print the exit too.
- Region-scoped change detection: `pctDiffRegion` in appdrive.zig
  (stride-walking variant of pctDiffBuf; clamped, out-of-bounds rect
  diffs 0 — never a false "changed"), threaded as `?Region` through
  waitChangeSince/waitVisualSettle/waitWindowChange/peekDiffPct/
  diffStats. `region:{x,y,w,h}` on app_click/type/key/scroll/drag
  scopes min_change_pct ("assert the tactical viewport repainted");
  on app_wait it scopes change_pct; on app_actions wait steps via
  step-level `region`; on screenshot_app the existing crop region now
  ALSO scopes stats_only (`diff_scope:"region"` in the reply),
  wait_change, stable_ms and burst gating. Bare region on
  screenshot_app without a threshold stays a plain crop.
- launch_app description now advertises the OSC 5522 marker escape as
  a build-it-in tracing primitive (feedback: good primitive, easy to
  miss).

Verification: 774 tests pass (2 new: applyDebugWrap argv shape,
pctDiffRegion semantics), smoke-mcp, smoke-mux, plus live end-to-end
over real `sketerm mcp` NDJSON: a compiled segfaulting C binary under
debug:"gdb" with gdb_commands ["frame 1","p c","p c.magic + 1"]
landed `magic = 42424242` and `42424243` in app_log; weston-clickdot
under `timeout 2` reported "app EXITED during the post-input wait" on
a click (previously "screenshot failed"); region stats on clickdot
discriminated dot-adjacent (2.72%) from far (0.00%) rects, and
app_click with region passed at the dot and reported "NO repaint in
the given region" away from it.

Deliberately NOT built (from the same feedback): interactive gdb
transport (gdb_commands covers the stated goal; a breakpoint/step
session over MCP is a much larger design) and launch_app waiting on
an app-private a11y socket (app-specific protocol; needs a design
decision on what a generic hook would even speak).

## Modifier-backed linux-dmabuf import

The forwarded-app compositor now supports hardware-rendered ARGB/XRGB
dmabufs beyond the old LINEAR-only mmap path. Native Linux session workers
runtime-load one shared EGL/GLES importer, query importable non-external
format/modifier pairs, union those with the guaranteed LINEAR tuples,
import EGLImages, render/read them back as tight top-down BGRA, and feed
the existing zstd synthetic-pool transport. LINEAR remains a direct mmap
fast path; portable/non-Linux builds compile EGL import out, and no
EGL/GLES/libdrm ELF dependency was added.

DMABUF params now reject duplicate/out-of-range planes, mixed modifiers,
reuse, unsupported flags/formats, overflow, the protocol-defined
offset+stride*height bound, and tight images over 256 MiB. Finalized
buffers use offset 0 and width*4 stride in replicas. Every commit is
captured before the brain emits wl_buffer.release, including with no
viewer, so durable replay serves the last committed staging image instead
of rereading producer storage after the client was allowed to reuse it.
Modifier-defined auxiliary planes are forwarded to EGL; a commit without
a fresh attach never rereads a buffer that was already released.
Initial create_immed import failure queues INVALID_WL_BUFFER before closing;
a later capture failure retains the last good image and still commits and
releases, as required by linux-dmabuf.

Coverage includes pure metadata tests, v3 modifier and legacy implicit
announcements, lenient replica replay, state-sync v7 plus a synthesized v6
compatibility fixture, EGL loader/context/capability tests, exact modifier
attributes, tight staging, channel conversion and Y_INVERT, and a scripted
real-daemon smoke using SCM_RIGHTS with offset+padded-stride LINEAR storage.
The smoke proves legal object-id reuse orphans an old shm pool, pixels
precede commit, wl_buffer.release follows capture, a no-viewer commit is
still captured, post-release source overwrite cannot affect replay, and a
second viewer receives tight pixels before state_sync. Protocol 6 daemons emit
the new state format; protocol 6 clients retain the protocol 5 state decoder
for rolling upgrades.
The worker rejects nested session spawns, and a11y teardown now removes its
private runtime tree in-process; no post-EGL fork remains in the worker, and
the old sentinel-slice allocator mismatch is gone.

Verification: `zig build test --summary all` passes 811 tests with 6
environment skips; `-Ddmabuf-import=false` passes 810 with 7 skips. Native
and LINEAR-only `smoke-mux`, `smoke-broker`, the GUI build, native mux,
Linux static-musl portable mux, aarch64-macOS portable cross-build, and all
GL renderer smokes pass. Native `sketerm-mux` has only libc/libm/loader
DT_NEEDED entries; the Linux portable artifact is static with no dynamic
section.

This host has no /dev/dri or /dev/udmabuf, so a real tiled exporter could
not be exercised locally; multi-GPU device matching remains limited to
EGL's selected surfaceless/default display, and external-only modifiers
remain unadvertised because the readback shader requires TEXTURE_2D.
Default broker workers fork before loading EGL and never fork another
session. The legacy monolith remains LINEAR-only because its later PTY
forks are unsafe after a vendor EGL driver has initialized threads.

## Protocol 6 client compatibility with protocol 5 daemons

Mux handshakes now accept daemon protocols in an explicit supported range
instead of requiring an exact match. A protocol 6 client accepts protocol 5:
the daemon receives the client's newest-version hello, emits only protocol 5
features and state, and the client uses its retained protocol 5 snapshot and
state-sync decoders. Daemons newer than the client and daemons older than
protocol 5 remain rejected before attach with a diagnostic that names the
supported range. The shared predicate is used by local, SSH, and UDP probes.

Verification: 814 tests pass with 6 environment skips, including compatibility
range boundaries. An isolated daemon built from the last protocol 5 commit was
left running while the current client connected directly and through the real
SSH proxy path, spawned a shell, attached to send input, restored/read its
snapshot and output, and killed only the test session. The protocol 5 daemon
was not restarted or upgraded between those client connections.

## Forwarded-app taskbar identity and icon lifecycle

Forwarded windows now acquire the remote application's desktop identity at
the backend-specific point where it can take effect. X11 still receives
`WM_CLASS` during realize, before map. Wayland receives the app id again from
an after-map callback, because GTK's Wayland backend does not create the
`xdg_toplevel` role until map and silently ignores
`gdk_wayland_toplevel_set_application_id` before that role exists. Shipped
icon pixels are reapplied after every app-id update so the icon-name fallback
cannot replace the daemon-host icon.

Daemon icon replay is now keyed by surface id instead of suppressing every
window after the first occurrence of an app id. Each live toplevel therefore
receives and replays its own icon, destroyed surfaces release their cached
bytes, and multi-window apps retain correct icons after reattach. Icon theme
resolution also preserves explicit `.png`, `.svg`, and `.svgz` suffixes
instead of searching for names such as `app.png.png`.

Verification: 814 tests pass with 6 environment skips, including new
multi-surface replay/removal and explicit-suffix tests. `smoke-mux`,
`smoke-broker`, GUI/mux builds, Linux static-musl portable mux, and the
aarch64-macOS portable cross-build pass. The native mux still links only
libc/libm/loader and the portable artifact has no dynamic section. A private
Xvfb run of a real forwarded Weston terminal observed remote
`WM_CLASS = org.freedesktop.weston.wayland-terminal` plus `_NET_WM_ICON`.
A separate private nested-Weston run captured the outer GTK client sending
`xdg_toplevel.set_app_id("org.freedesktop.weston.wayland-terminal")` after
map. Neither integration run used the live desktop runtime or compositor.

## smoke-e2e runtime isolation

`smoke-e2e` now sets private runtime, config, and state directories before
starting anything, launches its own broker as a tracked child, waits for that
private socket, and terminates the exact broker PID after the GUI exits. Its
failure path uses SIGTERM for the broker so workers are reaped. When
`xvfb-run` supplies `DISPLAY`, the GUI explicitly selects X11 and drops an
inherited `WAYLAND_DISPLAY` instead of opening on a live forwarded display.

This closes a destructive regression exposed during protocol 6 testing: the
previous unisolated smoke connected its v6 GUI to the user's running v5 local
daemon, classified that daemon as stale under the old exact-match handshake,
and sent it a shutdown frame. Verification reran that same command,
`xvfb-run -a zig build smoke-e2e`, which now passes entirely inside the
private runtime. The full 814-test suite and normal GUI build also pass.

## Progressive mux negotiation and non-destructive daemon upgrades

Mux compatibility now selects the highest shared core profile and negotiates
snapshot, native-state, audio, and winstream capabilities independently.
Current clients read historical snapshot bodies and both snapshot envelopes;
current daemons emit snapshot v3 and native state-sync v6 for protocol-5
clients. State-sync v7 remains required only for sessions that advertise
modifier-backed dmabufs, so older viewers retain terminal access without
misdecoding GPU protocol traffic. Protocol 1 is discovery-only because three
indistinguishable snapshot revisions shipped under that number. Peers with no
safe overlap receive profile 0: list remains available, while every mutating
or attach-scoped frame is refused server-side and sessions stay untouched.

Daemon startup no longer retires or replaces a live socket owner. Stale-socket
recovery and teardown share an advisory lock, teardown unlinks only its own
recorded inode, and a second daemon returns `AlreadyRunning`. The macOS deploy
script signs and atomically installs a sibling file, atomically replaces the
LaunchAgent plist, preserves a loaded daemon, and updates both the loaded and
next-login binary paths when `SKETERM_MUX_BIN` changes. Explicit restarts remain
operator actions because they destroy live sessions.

Durable shell creation now resolves the configured Default or saved named
profile for shell, login-shell mode, TERM, and COLORTERM. Remote clients use an
old-daemon-compatible account-shell launcher, prefer the configured shell when
present, and no longer inherit the daemon service's unrelated `$SHELL`.
Malformed snapshots release their connection, doctor warns on profile 0 and
live-but-unresponsive daemons, and MCP's fresh log side channel negotiates a
normal terminal profile while disabling native/audio/winstream replay.

Verification: 823 tests pass with 6 environment skips; `zig build`,
`smoke-mux`, `smoke-broker`, `smoke-mcp`, isolated Xvfb `smoke-e2e`, Linux
static-musl mux, and aarch64-macOS portable mux pass. Cross-version integration
used an actual protocol-5 daemon with the current client over local and SSH
proxy transports, and an actual protocol-5 client against the current broker.
The ownership test proved a second daemon cannot replace the first and its
session remains interactive. No test used or restarted the live user daemon.

## 2026-07-24: negotiation review — hello-less legacy clients need the proto-4 envelope

Independent re-verification of the progressive-negotiation work found one real
regression the original matrix missed: released v4/v5 builds send bare
attach/kill frames with NO hello on their local CLI paths (`mux send`,
`get-text`, `kill` — only spawn probed). The daemon's hello-less default of
proto 1 framed their snapshots with the 8-byte `[seq]` envelope, but every
daemon those builds ever met used the protocol-4 `[seq][app]` envelope — the
v5 client parsed the version byte as the app flag and reported "bad snapshot"
(surfaced as a bogus "no such session" on send paths). The default is now
proto 4 with the legacy snapshot body: envelope correct for the entire real
hello-less population, app/audio/native channels still gated behind an
explicit hello. Regression test pins the default; live verification drove an
actual v5 client's spawn/send/get-text/kill against the current daemon
(TERM/COLORTERM expansion included) and the reverse direction unchanged.
The original session's "v5 client vs v6 daemon" pass was traced to a stale
`zig-out/bin/sketerm-mux` — plain `zig build` does not rebuild the daemon.

Verification: 824 tests pass (6 skips); `zig build`, `zig build mux`,
`smoke-mux`, `smoke-broker`, `smoke-mcp`, Linux static-musl and aarch64-macOS
portable builds pass. No live user daemon was touched.

Follow-up in the same review: the current CLI's own quick paths (`mux send`,
`get-text`, `kill`) now negotiate via `connectProbed` instead of riding the
hello-less legacy defaults, and `smoke-mux` gained a `noHelloStage` driving a
real hello-less client end to end (spawn, legacy-body attach, kill) so the
served-legacy contract cannot silently regress. Verified live: actual v5
client spawn/send/get-text/kill and the v6 CLI against the current daemon,
the current CLI against an actual v5 daemon, all sessions and daemons intact.

## 2026-07-24: post-mortem log delivery — crash backtraces must outlive the app

ST:AFU feedback: after `app_actions` reported `app_exited`, `app_log`
intermittently answered "no log data for this app", losing the gdb backtrace.
Three cooperating holes, all in the delivery path (the daemon-side ordering —
final log flushed on PTY EOF, i.e. wrapper exit, then pushed ahead of `.exit`
— was already correct): appdrive's `pumpOnce` set `exited` when EOF landed in
the same `fillAvailable` read that buffered the final frames, stranding them
forever (pumpOnce refuses to run once exited); `logGet` returned NotConnected
on an EPIPE'd send without draining what the worker HAD flushed; and a worker
whose session died exited after run()'s 8x50ms flush even though an MCP
client only reads between tool calls — everything beyond the socket buffer
died with the worker's write queue. Fixes: peel all buffered frames before
declaring EOF-exit, drain-then-serve-stash on send failure, and a bounded
(10s) worker linger while a live client still has queued bytes. `app_log`
for an exited app with an empty stash now says so explicitly instead of the
ambiguous "no log data". The `app_exited` batch reply already inlines
`recent_output` + the debugger-caught signal once the stash survives.

Tests: an appdrive unit test pins the EOF-peel (frame stream sized to exactly
one 16384-byte read so EOF lands in the same call; fails with "expected -11,
found 0" without the fix), and a smoke-broker stage pins the worker linger
(2MB backlog toward a non-reading mcp-kind client, sleep past the old final
flush, then assert the sentinel log push + exit status 7 arrive; fails with
"post-mortem log push lost in worker teardown" without it). Live validation
through the real `sketerm mcp` stdio stack: bare crash (sentinel served),
`debug:"gdb"` crash (SIGSEGV backtrace + `gdb_commands` output readable after
exit), unknown-app error distinct, and a 15x crash/app_log loop with zero
losses. 825 tests pass (6 skips); smoke-mux/broker/mcp, GUI + mux builds,
Linux static-musl and aarch64-macOS portable builds pass.
## 2026-07-23: file service phase 1 — live directory views + fsdrive

First slice of the file browser (design: docs/filebrowser-roadmap.md,
untracked): the mux daemon is now a file server with SUBSCRIPTION
listings, not one-shot replies.

- Wire: `fs_op` (JSON, op-discriminated: open_view/close_view/list/
  stat/read/mkdir/rename/delete/symlink) + binary `fs_write`;
  daemon→client `fs_reply` (req-nonce in the header — the log_get
  lesson), `fs_delta` (pushed view changes), `fs_data` (ranged read
  chunks). Not attach-scoped: the broker itself serves fs clients
  (they never attach, so no worker handoff is involved).
- `src/mux/fsserve.zig`: rich one-round-trip listings (lstat + symlink
  target + follow-dir bit per entry, dirs-first ci sort, 512-entry
  reply chunks, 100k cap), alignment-safe inotify event parsing,
  Watcher gated to Linux (macOS compiles; deltas need a later FSEvents
  backend — Linux never waits for it).
- daemon: FsView registry ((client, client-chosen view id) → shared
  inotify wd, refcounted across equal paths), per-tick coalesced
  deltas (last state wins; stat decides upsert-vs-del, not the event
  kind), IN_Q_OVERFLOW → honest `resync:true`, watched-dir deletion →
  `gone:true`, views die with their client (reap) and a failed open
  never leaks a view. IN_MODIFY deliberately unwatched (flood).
- `src/ipc/fsdrive.zig`: GTK-free client in the appdrive mold —
  deadline-bounded waits everywhere, replies matched by req nonce,
  fs_delta frames stashed (never dropped) while awaiting replies.
  Gotcha fixed en route: std.json's default alloc_if_needed returns
  strings ALIASING the input buffer; frame payloads die with the call,
  so every fsdrive parse pins `.allocate = .alloc_always` (was a
  flaky SEGV in the smoke).
- `zig build smoke-fs`: daemon-thread + fsdrive end-to-end — listing
  richness, live deltas for external create/write/rename/delete (a
  create is TWO deltas by design: IN_CREATE at size 0, then
  IN_CLOSE_WRITE), mutation verbs observed through the view, 300KB
  write + ranged read-back + eof, stat/symlink, 1300-entry chunked
  listing, dir-gone views, close_view silence, error paths, abrupt
  client death, leak-checked (DebugAllocator), run in BOTH monolith
  and broker modes (smoke-backlog lesson).

Verification: smoke-fs 10/10 runs green (both modes), full test suite
776/782 (6 skipped, 0 failed), GUI + mux + mux-portable musl +
aarch64-macos cross all build, daemon still links libc only,
smoke-broker + smoke-mcp pass. smoke-mux still shows the KNOWN
pre-existing DebugAllocator size-mismatch (reproduced unchanged on
base 66433f2 before any of this landed).

Phase 2 next: job engine (inline vs subprocess jobs, journaled
resumable copy); MCP fs tools ride once those verbs exist.

## 2026-07-23: file browser phases 2+3 — job engine, MCP tools, GUI pane

Continuing docs/filebrowser-roadmap.md on the worktree-filebrowser
branch (three commits after phase 1).

- Job engine (src/mux/fsjob.zig + fs_job frame): `sketerm-mux --job`
  runs one subprocess per copy/delete_tree/hash operation — spec on
  stdin, JSON-lines progress on stdout, kill = cancel (proven against
  a helper stuck in uninterruptible open(2) on a FIFO), SIGSTOP/CONT
  = pause/resume. Resumable copy needs NO journal: the staged
  `<dst>.skpart` IS the journal — resume hashes it against the
  same-length source prefix and continues only on a match (a corrupt
  partial honestly restarts; smoke covers both). Tree copy preserves
  symlinks, sizes first for real progress totals, skips equal-size
  files on resume. Jobs are daemon-owned and OUTLIVE their client;
  job_list serves any client; finished jobs retained (bounded 64).
- MCP file_* tools (twelve): daemon-side listings/read/write/mkdir/
  rename/delete + copy/delete_tree/hash as jobs with honest timeout
  replies ("still running — file_jobs / file_job"), binary reads as
  base64. Lazy fsdrive connection to the app daemon (isolated or
  --shared), dropped+reconnected on loss. New smoke-mcp stage incl.
  copy-then-hash equality and error honesty.
- GUI browser pane (src/ui/browser.zig): BrowserView rides a regular
  Pane as a SECOND FACE in wrapper_box — the shell session underneath
  is "Open Terminal Here" (one toolbar click, lands in the browsed
  dir). Internal per-pane tab strip (Nemo per-split-tabs model,
  confirmed requirement); tree-expand-inline where the expanded set
  == the daemon watch set; back/forward/up/path-entry navigation;
  hidden toggle; dirs-first with sizes/mtimes; double-click enters
  dirs, files open via the default app. Fully async: one nonblocking
  mux conn per view on g_unix_fd_add, listings accumulate across
  reply chunks, fs_delta upserts/dels apply to the model and
  re-render — the GLib loop never blocks (fsdrive's synchronous waits
  are NOT used GUI-side). Pane.attachBrowser/detachBrowser mirror the
  app-host embed rules (fd watch must die before the widget tree).
  Entry points: palette "New File Browser Tab" (new_browser_tab
  action) + IPC "new-browser-tab".
- Verified in a LIVE headless GUI (Xvfb + isolated XDG dirs + IPC):
  screenshots confirm the rendered pane, an externally-created file
  appearing via pushed deltas with no refresh, src/ tree-expanding
  inline, navigation, and the terminal-face toggle showing the
  pane's shell in the browsed directory.

Verification: full suite 777 pass / 6 skip / 0 fail (783); smoke-fs
(both daemon modes) OK; smoke-broker, smoke-mcp PASS; GUI + musl
mux-portable + aarch64-macos cross build; daemon still libc-only.
Tooling note: `zig build test` twice DEADLOCKED (runner in
futex_wait, spawned test binary starved on --listen stdin, 0 CPU
both) while a second Claude session ran heavy builds against the
shared ~/.cache/zig (load ~20) — worked around by executing the
compiled test binary directly. smoke-mux still shows only the KNOWN
pre-existing DebugAllocator mismatch (reproduced on base 66433f2).

Not yet (next phases): file-operation UI (context menu, conflict
dialogs, DnD), layout persistence of browser tabs, remote-host
browser tabs, transfer queue UI, FUSE mount, live queries.

## 2026-07-23: browser ops menu + browser-tab layout persistence

- Context menu on browser rows (GtkPopover, MenuCtx owned by the
  popover via set_data_full): Copy/Paste Here (paste = daemon copy
  job; same-name collision gets a "-copy" suffix instead of a silent
  overwrite; job progress streams into the status bar), Rename + New
  Folder entry popovers (RenameCtx pattern), Delete behind a
  destructive confirm popover (dirs = delete_tree job), Copy Path to
  the clipboard, Open Terminal Here (quotes + cd's the pane's shell,
  flips the face), Open in New Browser Tab. All mutations land in the
  view via fs_delta pushes — no local refresh logic exists.
- layout.zig PaneSpec grows `browser_tabs` (internal tab paths, older
  files parse via ignore_unknown_fields); paneSpec serializes via
  BrowserView.fromPane/tabPaths, restore reattaches the face and
  reopens every tab. Verified end-to-end under Xvfb: save via
  Ctrl+Shift+S from a terminal pane, kill, --restore → browser pane
  back with both internal tabs live.

Surfaced while verifying (both worth separate attention):
1. PRE-EXISTING: closing the window via the X saves an EMPTY
   last.json — gtk_window_destroy tears the tabs down before the
   GApplication shutdown hook calls saveLayoutQuietly, so --restore
   after an X-close restores nothing (terminals too, not browser-
   specific). Only explicit saves (Ctrl+Shift+S / palette) capture
   state.
2. LIMITATION of the browser face: pane keybinds (Ctrl+Shift+S,
   palette, ...) are dead while browser widgets hold focus — the
   bindings live on the hidden GLArea's controllers. Needs a
   window-level shortcut controller or a browser key-forwarder.

## 2026-07-23: phase 4 — remote browser tabs, cross-host transfers, jobs panel

- src/ipc/fstransfer.zig: client-mediated cross-host transfer engine
  (GTK-free, libc-only, no blocking waits — a pure state machine over
  two caller-owned Conns; the caller pumps sockets and offers frames
  via feed()). Transfer = one file: stat → optional staged-partial
  probe → 1MB read/write chunks (fs_data → fs_write at explicit
  offsets) → rename .skpart into place → BOTH-ENDS verify: the client
  hashes every byte it forwards and compares against a daemon-side
  hash job on the destination (a resumed file falls back to hash jobs
  on both ends, since the client never saw the partial's bytes);
  mismatch = destination deleted + honest failure. Xfer = file OR
  tree: walks source listings, recreates dirs + symlinks, streams
  files sequentially; tree rerun with resume skips completed
  same-size files (fsjob parity); resumed_bytes/files_skipped are
  proof counters.
- smoke-fs grew a cross-daemon stage (two daemons at once, client
  mediates): single 5MB file with hash oracle + no leftover .skpart;
  induced disconnect at 3MB → staged partial survives → second Xfer
  RESUMES (resumed_bytes > 0) and content matches; corrupted partial
  → verify FAILS and the corrupt destination is deleted; tree copy
  (dirs/files/symlink) + skip-rerun; cancel drops the staged partial.
  All green first run.
- browser.zig phase 4: every internal tab references a shared
  per-view HostConn (null = local, "user@box" = SSH, "udp:box" = UDP
  — terminal host strings). Remote connects run on a WORKER THREAD
  (Conn buffers use the C allocator; g_idle_add handback; an orphaned
  handback frees itself if the view died) so a dead host degrades one
  tab, never the GUI. Location specs: "host:/path", "user@h:/path",
  "udp:h:/path", "local:/path"; bare "/path" keeps the tab's host.
  History entries are host-qualified specs (back/forward cross
  hosts). Dead conn → transfers on it fail first, socket closes,
  status says "navigate to reconnect"; navigating spawns a fresh
  HostConn. Cross-host Paste Here rides fstransfer.Xfer; same-host
  paste stays a daemon copy job. Remote double-click downloads into
  $XDG_CACHE_HOME/sketerm/fsopen/<hash>-<name> and opens the default
  app (phase-5 hydrating cache predecessor). Jobs/transfers panel
  above the status bar: live rows for client transfers (percent,
  cancel) and daemon jobs (percent, pause/resume/cancel, dismiss).
  Layout persistence now records host-qualified specs (older plain
  paths parse unchanged).
- Keybind gap FIXED (previous session's limitation 2): a bubble-phase
  key controller on the browser root re-runs matchBinding/runAction
  against the pane's input ctx — palette/save-layout/etc. work while
  browser widgets hold focus; plain typing in entries is unaffected
  (entries consume their keys first).
- Crash found + fixed during live verify: onFdReadable freed frames
  with the VIEW's allocator, but a remote conn's frames belong to the
  conn's own allocator (c_allocator on thread-connected remotes) →
  DebugAllocator "Invalid free" abort. Frames are now freed with
  hc.conn.allocator. (Gotcha class: payload ownership follows the
  CONN, not the consumer.)
- Verified in a LIVE headless GUI (Xvfb, isolated XDG dirs, fake-ssh
  rig serving a genuinely separate daemon instance in its own runtime
  dir): remote tab listing via "fakehost:/…" in the path bar; live
  delta from an externally-created file on the REMOTE host; Copy on
  remote big.dat + Paste Here in a local tab → transfer done, sha256
  identical; remote alpha.txt double-click → cache download + opened
  in the default app (content verified); Ctrl+Shift+P palette opens
  from browser focus; killing the remote daemon degrades one tab with
  "connection to fakehost lost — navigate to reconnect" (GUI alive);
  Enter in the path bar reconnects (fresh listing incl. a file
  created while down); save_layout records "fakehost:/…" and
  --restore brings the remote tab back, reconnected, live.

Verification: full suite 778 pass / 6 skip / 0 fail (784, +parseSpec
unit test); smoke-fs (mono + broker + NEW cross-daemon xfer stage)
OK, leak-checked; GUI, mux, musl mux-portable, aarch64-macos cross
all build; sketerm-mux still links libc only. The zig-build-test
runner deadlock reproduced again under cross-session load (same
signature); same workaround (run the compiled test binary directly).

Not yet (next phases): dual-pane source/target UX, transfer-queue
reordering/serialization, FUSE mount, live queries + panelize,
mount bypass, batch rename, standalone-window mode.

## 2026-07-23: INCIDENT — smoke-e2e retired the user's real daemon; harness now isolated

What happened: `zig build smoke-e2e` (this worktree, proto 5) spawned
the app WITHOUT isolating XDG_RUNTIME_DIR. The app connected to the
REAL per-user daemon — a proto-6 build from the main checkout — hit
MuxProtoMismatch, and connectLocalAutostart's retireStaleDaemon shut
it down BY DESIGN, killing the user's live sessions (Zenit,
Hohenheim, Traffic Giant, BOTF, STDS9W, ST:AFU at 19:59; mux.log has
the full trail). A worktree proto-5 daemon then squatted the real
socket (removed afterwards by exact PID). This is the second
proto-skew casualty (first: 18:47, main-repo session) — the
retire-on-mismatch policy itself deserves a rethink (migrate/warn
instead of silent kill; separate design discussion).

Fixes to the harness (smoke_e2e.zig):
- The run now mkdtemps a private XDG_RUNTIME_DIR/CONFIG_HOME/
  STATE_HOME before fork, so the app can never reach the real daemon
  regardless of build skew; the isolated autostarted daemon is shut
  down on both pass and fail paths (shutdownIsoDaemon).
- The e2e "marker appears twice" check failed under xvfb-run's
  640x480 default screen: the TYPED echo line wraps mid-marker, so
  the count saw 1. The check now de-wraps (strips JSON \n escapes)
  before counting, and prints the final get-text on failure.

## 2026-07-23: phases 5-8 sweep — search, openers, power features, FUSE

- Daemon search verbs (fsjob subprocess jobs, capped streams): `find`
  = recursive name match (ci substring, or glob when the pattern has
  wildcards — pure-Zig iterative matcher, unit-tested) and `grep` =
  recursive ci content match with line numbers + sanitized previews,
  binary files (NUL probe) and >8MB files skipped. Matches stream as
  fs_job "match" events (daemon forwards them verbatim; done carries
  matches+truncated). fsdrive startFind/startGrep; smoke-fs grew a
  search stage (ci find, glob find, grep line numbers, binary skip)
  — green in monolith and broker.
- `tag_set` verb + tags in every listing entry (user.sketerm.tags
  xattr via l*etxattr; Linux-gated, macOS compiles). Browser renders
  [tags] dimmed on rows (live via IN_ATTRIB deltas) and edits them
  through a Tags… popover.
- Browser: search bar (toolbar toggle) → results stream into a
  panelize-style FLAT tab (full path in target; rows open/navigate);
  a new search cancels the previous job. Internal tabs got close
  buttons. Transfer queue: at most 2 client-mediated transfers run,
  the rest show [queued] and start as slots free (also gated on host
  connect). Mount bypass: navigation into a fuse.sshfs/NFS mountpoint
  (longest /proc/mounts prefix, octal-unescaped) silently reroutes to
  direct mux on the source host with a "via sketerm" status. Batch
  rename (multi-select, find/replace on basenames). Cross-host
  collection shelf (flat tab of host-qualified specs; open/remove;
  session-local). Sync Here = resumable mirror paste without the
  -copy suffix (same-host: daemon copy resume; cross-host: Xfer skip-
  completed). Declarative actions: $XDG_CONFIG_HOME/sketerm/actions/
  *.action (Name/Exec with %f quoted/Ext filter/RunsOnHost) — local
  actions g_spawn, RunsOnHost actions run as app sessions on the
  file's host via a window hook (windows forward). Rows are DnD
  sources (path as text — terminal panes already accept string
  drops). Remote files: "Open on Host (app forward)" menu item
  (xdg-open in an app session); dirs: "Open Terminal Tab Here" =
  durable session on the tab's host cd'ed to the dir (window hook →
  newDurableSessionAt; remote cwd travels in spawn).
- `sketerm files [spec]` + dev.sker.sketerm.files.desktop (PKGBUILD
  installs it): standalone file-manager entry point. Fresh start
  opens a browser-only window at the spec; against a RUNNING
  instance the command-line handler opens the tab there instead.
- Phase 6 FUSE: src/fsmount.zig — pure-Zig /dev/fuse client, NO
  libfuse. fd via fusermount3's _FUSE_COMMFD SCM_RIGHTS handshake
  (the unprivileged path); INIT negotiation (BIG_WRITES, 128K
  max_write), LOOKUP/GETATTR/FORGET(+BATCH)/OPENDIR/READDIR/
  RELEASEDIR/OPEN(O_TRUNC honored)/READ (ranged, chunked over
  MAX_READ)/WRITE/CREATE/MKDIR/UNLINK/RMDIR/RENAME(2) with subtree
  path rewrite/SYMLINK/READLINK/SETATTR(size 0 or no-op; else
  EOPNOTSUPP — the wire has no ftruncate)/STATFS. Node table with
  slot reuse (unit-tested: ensure/forget/reuse, rename subtree,
  errno mapping). `sketerm mount <host>[:/path] <mountpoint>`,
  Ctrl-C or fusermount3 -u to stop. smoke-fuse runs REAL kernel file
  ops through the mount (readdir/read incl. multi-chunk/write-
  through/mkdir/rename/unlink/symlink/O_TRUNC) against a daemon
  thread — SKIPs honestly where /dev/fuse is missing.

Verification: unit suite 782 pass / 6 skip / 0 fail (788; +glob,
+3 fsmount); smoke-fs (search + xfer stages, both modes) OK;
smoke-broker, smoke-mcp PASS; GUI + mux + musl portable + aarch64-
macos cross builds; daemon still libc-only (ldd). GUI features
verified live under Xvfb with screenshots: files-mode window, grep
results tab with line previews + jobs-panel row, tags set via
popover and rendered from the ATTRIB delta (xattr confirmed on
disk), Count Lines .action button (ext-filtered) executed, batch
rename applied on disk, collection tab created. NOT runtime-
verified here: the FUSE mount itself — this container has no
/dev/fuse (fusermount3 present, device absent); `zig build
smoke-fuse` is the one-command proof on a real host.

Still open (deliberate scope calls, not oversights): Miller-columns
view (large GTK view-mode work), Haiku-style PUSH-live saved queries
(needs daemon-side whole-tree watch registration; searches re-run on
demand today), collection persistence across sessions, per-rule file
coloring config, FUSE placeholder/pin/evict cache tiers (reads are
ranged+direct today; the CfAPI-style cache is the phase-6 second
step), $EDITOR-buffer batch rename.

## 2026-07-24: durable file jobs, live queries, and FUSE hydration cache

- Added the GTK-free browser state model (`filebrowser/model.zig`) and
  versioned full-pane layout persistence: explicit host/path file refs,
  per-tab history, expansion, selection, view/sort/filter state, and
  virtual-folder specifications survive save/restore.
- Added atomic daemon job journals (`mux/fsjournal.zig`) with stable job
  ids and restart reconstruction. Local copies resume only after prefix
  verification; detached helpers are rediscovered after daemon failure.
  Cross-host copies now run as daemon jobs connecting both endpoints,
  preserve trees/symlinks/metadata, resume `.skpart` files, and verify
  SHA-256 at both ends.
- Added host-side archive create/extract with archive-path traversal
  rejection, freedesktop home-trash move/restore, command panelization,
  and recursive live filename queries. Live queries maintain recursive
  inotify registrations and stream match/unmatch/resync events instead
  of rerunning a one-shot search.
- Added browser actions for trash, permanent delete, archive operations,
  metadata/permission editing, and matching MCP file tools. Directory
  listings now own tag strings correctly; failed/truncated tree copies,
  vanished files, symlink failures, and corrupt equal-size resume targets
  fail honestly instead of being silently skipped.
- Added Linux `/proc/self/mounts` and macOS `getmntinfo()` source parsing,
  including NFS/SSH normalization, root mounts, and bracketed IPv6.
- Completed the FUSE sparse hydration layer (`filebrowser/cache.zig`).
  Mount namespaces include the full host/path specification; entries
  persist sparse hydrated ranges atomically and expose
  `user.sketerm.cache-state`, `user.sketerm.pin`, and
  `user.sketerm.evict`. Pinning hydrates incrementally between kernel
  requests, survives remounts, retries transient failures with bounded
  backoff, and migrates across file/directory renames. Unlink removes pin
  metadata rather than creating retrying zombie entries.
- FUSE directory handles now use live mux views. Delta changes invalidate
  affected kernel dentries/inodes and sparse cache entries; resync events
  invalidate every known child. Renamed open directories establish the
  replacement subscription before dropping the old one. Transport HUP
  terminates the mount loop rather than spinning. `FUSE_EXPLICIT_INVAL_DATA`
  is deliberately not negotiated because subscriptions are scoped to open
  directory handles; normal kernel cache expiry remains the correctness
  fallback when no directory is open.
- File content generations include nanosecond mtime/ctime when available
  and retain millisecond fields for older-daemon compatibility. Persisted
  range metadata is accepted only when bounded by both remote size and the
  local sparse file. Synthetic xattrs parse the compatibility FUSE header,
  validate flags, reject non-regular pin targets, and report persistence
  failures.

Verification: `zig build -Dstrip=false`, `zig build mux`, and
`zig build mux-portable -Dportable-target=aarch64-macos` pass. The freshly
linked direct test executable reports 790 passed, 6 skipped, 0 failed (796
total). `ldd zig-out/bin/sketerm-mux` remains limited to libc/libm and the
loader. `zig build test --summary all` still deadlocks in the known Zig
build runner after linking, so the linked artifact was executed directly.
Kernel FUSE runtime coverage remains unavailable on this host because
`/dev/fuse` is absent; `zig build smoke-fuse` remains the real-host proof.

## 2026-07-24: browser high-importance batch — conflicts, preview, Open With, edit sync-back, compare/sync

Five daily-driver features for the file browser, all live-verified under
Xvfb against a genuinely separate fake-SSH daemon:

- Conflict resolution for paste: the clipboard is now MULTI-item (Copy
  captures the whole selection when it includes the clicked row), and a
  paste that collides with the live target listing raises a popover with
  Keep Both (unique -copy/-copyN name) / Skip Existing / Overwrite
  (destructive-styled), one choice applying to all conflicting items.
  Pasting a file onto itself is a guarded no-op. Verified on disk for all
  three choices (keep-both created suffixed copies; overwrite replaced
  content; skip left the modified target untouched).
- Preview panel (toolbar toggle): metadata always; images render via
  bounded gdk-pixbuf decode (local) or chunked fs reads (remote, capped
  8MB); text files show a 4KB head with NUL-probe binary detection and
  UTF-8 sanitization. Local image rows also get real 24px thumbnails,
  cached by path+mtime (cap 256, decode bounded). Remote preview fetches
  ride the SAME nonblocking conn as listings — new fs_data/fs_reply
  consumers in browser.zig (feedPreview), abandoned safely on host death.
- Unified Open With chooser on files: local GAppInfo handlers for the
  guessed content type, PLUS on remote tabs a host-side application list
  served by the new daemon `apps` fs op (one round trip; scans
  usr/local/user .desktop dirs, skips NoDisplay/Hidden, user entries
  shadow system ones, cap 400). Host apps are MIME-filtered client-side;
  choosing one substitutes the Exec line (%f/%F/%u/%U quoted, %% literal,
  stray codes dropped — unit-tested) and runs it as a forwarded app
  session via on_host_exec. Choosing a local app on a remote file
  downloads to the open-cache and launches THAT app by id.
  Gotcha fixed: the chooser popover must popdown the context menu BEFORE
  popping itself up, or its grab dies with the menu (blank popover).
- Local-edit sync-back: every remote file opened locally registers a
  GFileMonitor EditWatch on its cache copy; CHANGES_DONE_HINT uploads the
  edit back to the origin host via a client-mediated transfer (staged
  .skpart + both-ends hash verify), deduped per (host, remote path), with
  an uploading latch so rapid saves cannot stack transfers. Verified
  end-to-end: appended to the cache copy, remote file gained the edit.
- Compare / Sync window ("Compare / Sync with Copied…" on a directory
  when the clipboard holds one): BOTH trees are scanned host-side (find
  jobs, pattern *, streaming path+kind+size+mtime digests — only digests
  cross the wire; find match events now carry mtime_ms), diffed
  client-side, and shown as rows (only-in-source / only-in-target /
  differs with newer-side annotation) each with a direction dropdown
  defaulting to copy-from-the-side-that-has-it / newer-wins. Comma-
  separated exclude globs (fsjob.nameMatches). Execute runs mkdirs
  (path-sorted, parents first) + same-host copy jobs or cross-host
  durable transfers; copy-only by design (no deletes — a wrong direction
  cannot destroy data). A truncated scan (2000-entry cap) is banner-
  flagged as PARTIAL. Verified live: cross-host sync copied 3 files to
  the target, overwrote the differing file (source newer), created the
  missing directory + file back on the source side, and honored the
  exclusion glob.

Also in this batch:
- FIXED pre-existing musl break: `zig build mux-portable` failed at the
  baseline commit because musl's struct statvfs translates as opaque
  (anonymous bitfield); the statfs op now comptime-gates on that and
  serves conservative defaults on musl daemons.
- smoke-fs was RED at the baseline commit: the corrupt-partial stage
  still expected the old fail-hard contract, but fstransfer (previous
  session) now deletes the corrupt destination and retries once from
  zero. The stage now asserts the new contract: transfer ends OK,
  content hash-matches the source, no staged partial left.

Verification: GUI + mux + mux-portable (musl) + aarch64-macos builds
pass; sketerm-mux links libc/libm only (ldd-checked). Direct test run:
846 passed, 6 skipped, 0 failed (852 total; +3 unit tests for exec-line
substitution, MIME list matching, image-extension gate). smoke-fs
(monolith + broker + xfer + search stages), smoke-broker, smoke-mcp,
smoke-e2e (xvfb) all PASS. The zig-build-test runner deadlock persists
(documented workaround used). Live GUI proof: 20+ screenshots covering
every feature above; isolated world torn down by exact PID (2 daemons,
0 leftovers).

## 2026-07-24: browser completion sweep — views, places, move/undo, trash, metadata, integrations

The remaining feature backlog, implemented and live-verified under Xvfb
(screenshots for every headline item; disk-state checks for every
mutation flow):

- FIXED (pre-existing, all pane types): X-button close saved an EMPTY
  last.json — the widget tree died before the shutdown hook ran. The
  close-request path now saves FIRST (both the immediate-close and
  confirm-dialog branches) and latches layout_saved_final so the
  shutdown hook cannot overwrite the good save with post-teardown
  emptiness. Verified: X-close now persists the full layout including
  browser tabs.
- View modes: the toolbar cycles details / compact / icon-grid /
  Miller columns. Details gained a clickable sort header (Name/Size/
  Modified with ^/v indicators; strict-weak-order safe descending) and
  an rwx permissions column; grid is a GtkFlowBox with 48px thumbnails
  in its OWN scroller (the listbox never leaves the tree, so popovers
  survive mode switches); Miller keeps the normal listbox as the
  RIGHTMOST column with subscribed ancestor columns to its left — all
  existing menus/popovers/tree-expand keep working, and each ancestor
  is a live view (dirByView covers them). Dir sort params live on the
  Dir so delta-driven re-sorts need no tab lookup.
- Places sidebar (toggle): Home / File System / Trash / Collection,
  persisted bookmarks (Add Bookmark on dirs, inline remove), saved
  searches, recent locations (deduped, cap 12, recorded on every
  navigate), and Devices parsed from /proc/mounts (/dev-backed, nfs,
  sshfs). Persistence in state-dir places.json via the new GTK-free
  src/filebrowser/places.zig (unit-tested recent-dedupe).
- Cut/Move + DnD + undo: Cut in the menu (multi-selection aware);
  paste after cut MOVES — same-host as one rename (undoable), cross-
  host as a verified transfer chained with source deletion; the cut
  clipboard is one-shot. Row drags now carry host-qualified specs and
  every listbox is a drop target: same-host drop moves (undoable),
  cross-host drop copies, row-under-pointer targeting when it is a
  directory. Undo (Ctrl+Z in the browser, or the context-menu entry
  showing what it will undo): rename/move goes back, copy deletes the
  created item, mkdir removes the folder, trash restores — recorded
  only after the operation actually succeeded (deferred on the op
  reply / job completion), bounded stack of 20.
- Trash: freedesktop home trash PLUS the $topdir/.Trash-$UID fallback
  when rename hits EXDEV (tmpfs and other filesystems trash correctly
  now — verified live after the honest "XDEV" failure surfaced in the
  jobs panel). "Restore from Trash" appears on entries inside any
  trash files dir (home or topdir), fetches the .trashinfo over the
  fs wire (RestoreRead), URL-unescapes Path=, and runs a trash_restore
  job. Verified end-to-end including info-file cleanup.
- Duplicate finder: "Find Duplicates Here" runs a host-side scan,
  buckets by size, hash-confirms candidates with daemon hash jobs
  (bounded 200), and opens a flat results tab of confirmed groups
  only. Verified: 2-file group found, different-content file excluded.
- Search/metadata: searches accept a "@7d pat" / "@12h" / "@30m"
  prefix (server-side mtime filter — new within_ms on the find spec);
  the star button saves the last search, saved searches persist and
  re-run from the sidebar. Tags render as deterministic color chips;
  ~/.config/sketerm/filecolors.conf ("glob=#RRGGBB") colors file
  names (verified: red readme.md). Git status overlays for local
  dirs: a worker thread runs git status --porcelain via popen (never
  on the GLib loop), the idle handback is generation-checked and
  orphan-safe, statuses aggregate onto immediate children ([M]
  modified vs [?] untracked verified live).
- Integrations: Open With gained "Always use for this file type"
  (g_app_info_set_as_default_for_type); a toolbar button jumps to the
  shell's OSC 7 cwd; "Export Selection to Shell" sets $SK_SEL /
  $SK_SEL_ALL in the pane shell; the collection shelf persists across
  restarts (places.json) with a sidebar entry; "Batch Rename in
  $EDITOR" writes basenames to a temp file, runs $EDITOR in the
  pane's shell, and a sentinel done-file (GFileMonitor) applies the
  renames — count-mismatch aborts, each rename undoable. Verified by
  simulating the editor.
- Compare/sync deepening: scans now request a 100k match cap
  (PARTIAL banner updated); a "Hash-verify equal-size rows" button
  hash-jobs both sides of equal-size differs rows (cap 40) and flips
  identical content to Skip with an [content IDENTICAL] annotation;
  the direction dropdown gained "Delete (from the side that has it)"
  plus a "Mirror: mark target-only rows for deletion" button —
  deletion never happens without an explicit per-row setting.
- FUSE: the stale "no ftruncate" comment was wrong — SETATTR size
  already maps to the wire truncate op; comment fixed. Pin (keep
  hydrated) / Evict Cached Data appear on files under a fuse.sketerm
  mount and set the user.sketerm.pin/evict xattrs.
- Files-mode identity: `sketerm files` windows title as "Sketerm
  Files" with the files .desktop icon.

DELIBERATE SKIP (user-authorized): the macOS live-delta watcher
(FSEvents/kqueue). Blind-writing kernel-event plumbing for a platform
this environment cannot run, inside the daemon's event path, is the
"too difficult on macOS" case Jelle explicitly said to skip; the
watcher seam stays documented, macOS still browses without live
deltas.

Not individually live-verified (machinery shared with verified flows):
compact view rendering, the DnD drop handler (xdotool cannot
synthesize reliable drags; same code path as verified cut-move),
export-to-shell terminal output, cwd-sync (test shell has no OSC 7),
pin/evict effects (no /dev/fuse here), compare hash-verify/mirror
buttons (verified primitives: hash jobs + execute).

Verification: GUI + mux + musl-portable + aarch64-macos builds; daemon
libc/libm only (ldd). Tests 847 passed / 6 skipped / 0 failed (854
total; +1 places test). smoke-fs (5 stages), smoke-broker, smoke-mcp,
smoke-e2e (xvfb) all PASS. The zig-build-test runner deadlock
persists; direct-binary workaround used throughout.

## 2026-07-24: freedesktop thumbnails (host-side, fully async) + archive browsing

Replacing the admittedly crude first-pass thumbnails ("serious miss,
unforgivable" — correctly) and adding archive browsing:

- Thumbnails now use the REAL freedesktop thumbnail spec, verified
  against the spec's canonical example hash (new GTK-free
  src/filebrowser/thumbs.zig: percent-encoded file:// URI, md5 key,
  thumbnails/normal/<md5>.png; unit-tested). Local files: a persistent
  worker thread (pthread mutex/cond; refcounted ctx so a dying view
  orphans in-flight results instead of racing them) probes the local
  cache FIRST — thumbnails Nemo/GNOME already generated are reused
  as-is, verified by unchanged file mtimes across an app restart —
  validates Thumb::MTime, and only then decodes (bounded 128px) and
  saves spec-compliant: tEXt Thumb::URI + Thumb::MTime chunks, dirs
  0700, files 0600, temp+rename. Verified on-disk: correct keys,
  correct chunks, correct permissions.
- REMOTE thumbnails live on the HOST THAT OWNS THE FILES, never on
  the viewer: a serial per-view pipeline reads the remote cache path
  over the fs wire (new `homedir` op resolves the remote cache dir
  once per connection), validates MTime, and on miss fetches the
  source bytes (capped), decodes/encodes on the worker, displays, and
  WRITES THE PNG BACK into the remote host's cache (mkdirs + fs_write
  + rename, req-0 best-effort) — so the remote machine's own apps
  share it. Verified: remote cache gained exactly the two expected
  md5-keyed PNGs, the local cache did not, and a restart re-served
  thumbnails from the remote cache without regeneration (mtimes
  unchanged) with pixel-exact renders.
- Everything is async by construction: render shows generic icons
  and never waits; results trickle in via idle handbacks with a
  coalesced 120ms re-render; failures are negative-cached. The old
  synchronous decode-in-render path is deleted.
- Archive browsing: "Browse Archive" on any archive opens a members
  tab streamed by a new `archive_list` job (bsdtar -tf host-side —
  only the member table crosses the wire; tar/zip/7z alike, capped
  with truncation flag). Members activate (or "Extract and Open" via
  their restricted menu) through `archive_extract`: ONE member is
  extracted host-side into a private mkdtemp and then opened — local
  directly, remote via the download-open path (which also registers
  the edit sync-back watch). Verified live for a local tar.gz and a
  REMOTE archive over the fake-SSH rig, including the extracted file
  landing in the viewer (Chromium showed the image).
- FIXED while verifying: the daemon's job DONE events never forwarded
  the result path/text fields (fsJobEmit dropped them), which had
  silently broken undo-of-trash (it needs the trashed+info paths from
  the done event) and would have broken member-open. FsJob now
  retains done_path/done_text and forwards them. Undo-of-trash
  re-verified live: trash via menu removed the file, Ctrl+Z restored
  it. Also fixed: the archive job op mapping initially fell through
  to `hash` (a silent no-op patch); the members tab showed 0 items
  until the mapping was corrected — caught by instrumented live
  testing, not by review.

Verification: GUI + mux + musl-portable + aarch64-macos build; daemon
libc/libm only. Tests 850 passed / 6 skipped / 0 failed (857 total;
+3 thumbs spec tests incl. the canonical hash example). smoke-fs (5
stages) / smoke-broker / smoke-mcp / smoke-e2e (xvfb) PASS. Rig torn
down by exact PID (2 daemons), /tmp/sketerm-arx-* cleaned.

## 2026-07-24: durable browser transfers, richer previews, redo + navigation

- Remote open/edit is now process-owned rather than pane-owned. A
  locked, atomically replaced `file-transfers.json` ledger stores
  downloads, sync-back watches, retries, cancellation intent, source
  fingerprints, and pending daemon acknowledgments. Browser tab moves
  rebind to the destination window, multiple windows subscribe safely,
  corrupt/partial ledgers fail closed, and a second GUI process cannot
  overwrite the active coordinator's state.
- Daemon filesystem jobs accept stable client tokens. Reclaim returns
  the original job and replays terminal outcomes; terminal events are
  delivered only after the journal is durable. Helpers remain gated on
  stdin until their initial record is fsynced. Client acknowledgments
  are themselves persisted and trim only acknowledged token records.
- Cross-host and local copies verify staged data before replacement.
  File/symlink renames and new destination directories fsync their
  parents, preserving existing targets on creation failure. Offline
  cache edits resume after GUI restart; edits made during an upload
  schedule another generation. Existing watched cache files are never
  implicitly replaced by a later open request.
- Preview/thumbnail helpers are ephemeral and cancellable. Host-side
  generation covers raster images, SVG, AVIF/HEIC fallbacks, video
  frames, audio waveforms, PDF first pages, and media metadata. Cache
  PNGs validate metadata, chunk CRCs, and IEND; remote request identity
  includes its host/generation so late worker results cannot release a
  newer request. Text previews safely carry an escaped 4 KiB head.
- Browser navigation is transactional and generation-guarded. Added
  bounded back/forward history, Ctrl+L path entry with async directory
  completion, Alt+Left/Right/Up, select-all/invert/glob selection, and
  completion-gated redo alongside undo.

Verification: native GUI/mux, static-musl portable mux, and
aarch64-macOS portable builds pass; `ldd` shows mux links only libc and
libm. Direct unit artifact: 855 passed / 6 skipped / 0 failed (861
total). smoke-fs, smoke-broker, smoke-mcp, and xvfb smoke-e2e pass. A
fresh isolated fake-SSH run changed a watched cache while the GUI was
closed, then proved automatic sync-back, an empty intent/ack queue, and
matching persisted generations after restart. FUSE runtime remains
unavailable because this container has no `/dev/fuse`; PDF runtime
generation remains unexercised because poppler tools are not installed.

### Review pass on the above batch (same day)

Defects found reviewing that change set, all fixed and re-verified in a
live isolated GUI:

- `hostDied` never dropped in-flight listings. Since navigation became
  transactional, the request OWNS its candidate directory, so a host
  dying mid-navigation leaked it and left a navigation that could never
  resolve. `BrowserView.deinit` leaked the same way.
- Path completion listed the WRONG directory: `std.fs.path.dirname` on
  a trailing-slash path ("/a/b/") answers "/a", so typing the usual
  `dir/` showed the grandparent's children. Split at the last slash.
- The completion debounce timer was not canceled on Enter, so the
  popup re-opened after navigating — and it is autohide-free, so
  nothing dismissed it. Now canceled on activate and on path sync.
- Aborting a preview canceled an ephemeral helper that had usually
  already finished and been reaped, surfacing "operation failed: no
  such job" on every selection change. Sent with req 0 now.
- Preview left the "loading…" placeholder under a rendered image.
- Preview thumbnails were written at 512px into the freedesktop
  `large` tier, which is a 256px contract other file managers rely on.
  They go to `x-large` now.
- `navigate`/`navigateSpec` still took a `push_history` bool whose two
  branches were both `.push`. Removed rather than left lying.
- Durable queue reordering swapped `order` but not array position, so
  the visible queue never moved.
- Remote open hard-failed when the ledger was unavailable (another
  process holding the lock). It now degrades to the in-view transfer
  and says the download is not restart-durable.
- Daemon: `kill(-pid)` for an ephemeral job with a dead owner had no
  `pid > 0` guard (would signal the daemon's own group); `out_pipe[0]`
  could be closed twice on the journal-failure path; the transfer
  service left a stale GSource id after an early return.

Re-verified live (isolated rig, fake-SSH remote, torn down by exact
PID): cross-host back/forward with correct button sensitivity, durable
download landing with an armed watch, local-edit sync-back, offline-edit
recovery across a GUI restart, completion listing the typed directory,
remote image + text previews with no false errors, and thumbnails
written into the REMOTE host's cache with the local cache untouched.
Direct thumbnail/preview helper runs confirmed spec-conformant PNGs
(tEXt Thumb::URI/MTime, 0700 dirs, 0600 files) and cache reuse on a
second run. Full matrix re-run green: 855 passed / 6 skipped / 0 failed,
smoke-fs / smoke-broker / smoke-mcp / smoke-e2e PASS, GUI + mux + musl +
aarch64-macOS builds, mux still libc/libm only.

## 2026-07-25: type-ahead, configurable columns, properties, dual-pane

Four inventory items from sections 1-4 and 9.

**Type-ahead jump.** Plain printable keys in a details/compact listing
build a prefix and jump to the first matching name (case-insensitive),
shown in the status bar; Backspace shortens it, Escape clears it, and a
1.2s idle gap starts a fresh prefix. Handled in the browser's
bubble-phase key controller, so a focused entry keeps its own input, and
the prefix resets on navigation.

**Configurable columns.** `browser_model.Column` (kind, perms, owner,
group, size, mtime, ctime, target) carries its own title, fixed width
and sort key; the details header is now REBUILT from the tab's column
set rather than being three fixed buttons, every column header sorts,
and a picker at the right end toggles columns. Hiding the column a view
is sorted by falls back to name order. The set persists per tab in
`TabState.columns`; an older state file without the key keeps the
default (perms, size, mtime).

**Properties.** Replaced the one-label popover: identity, location,
host, kind + MIME (guessed from the NAME so a remote entry is never
read), symlink target, size (on-disk figure omitted where st_blocks is
0), link count, mtime/atime/ctime, an on-demand recursive size, a 3x3
permission grid plus setuid/setgid/sticky wired two-way to an octal
entry, uid/gid entries, and "apply to enclosed files and folders".
Recursive size and recursive chmod/chown are new daemon job verbs
(`dir_size`, `perm_tree` in fsjob.zig): both walk on the host that owns
the tree, and perm_tree never follows symlinks, so a link inside the
tree cannot redirect the change outside it. dir_size is ephemeral (no
journal, dies with its client); the browser holds one probe at a time
with a g_object_ref'd label so a closed dialog cannot dangle.

**Dual-pane source/target.** A window hook resolves the other browser
face in the same sketerm tab from the pane-tree model. F5 copies the
selection there, F6 moves it, and both appear in the context menu
labelled with the destination. The paste path was generalized: source
host, cut-ness and clipboard ownership are now parameters, so a
dual-pane send and Paste Here share one conflict dialog. A new
`new_browser_split` action (palette: "Split into Two File Browsers")
creates the layout.

Two pre-existing bugs surfaced while wiring that action: `focusedPane`
and `splitFocused` matched only a pane's GLArea, so EVERY focused-pane
action (split, close pane) silently did nothing while a browser face
had focus; both now climb the widget tree (`Window.paneForWidget`).
`BrowserView.attach` on a pane that already had a browser orphaned the
first one; it now returns the existing view.

GTK gotcha worth keeping: a popover with no `pointing_to` rect and a
large child silently fails to map. Properties was invisible until it
got an explicit rect (the same workaround Open With already used). And
a popover parented to a header button dies when the header rebuilds:
the column picker parents to the page instead, with pointing_to
computed from the button's bounds.

Verification: unit suite 857 passed / 6 skipped / 0 failed (+3 model
tests); smoke-fs grew dir_size/perm_tree stages (recursive apply
confirmed on a subdirectory) and passes in both modes; smoke-broker,
smoke-mcp, smoke-e2e PASS; GUI + mux + musl + aarch64-macOS builds;
mux still links libc/libm only. Live in an isolated Xvfb rig: column
picker toggling three columns in one session with rows aligned to the
header, type-ahead jumps plus a no-match prefix, properties on a
directory (recursive size 7 B in 3 items, octal 0700 syncing the
checkboxes, recursive apply verified with stat on four entries), and a
dual-pane split where F5 copied two files, F6 moved one, and a
colliding F5 raised the conflict dialog in the TARGET pane (Keep Both
produced alpha.txt-copy). Rig torn down by exact PID.

## 2026-07-25: metadata — attributes, emblems, richer properties

Section 9 of the inventory, on top of the tags that already existed.

**Extended attributes are first-class.** fsserve grew get/set/list for
`user.*` attributes (anything outside that namespace is refused: the
browser must not be a path to editing security attributes), and a
listing can now carry the values of attributes the CLIENT asked for —
`attrs` on open_view/list, remembered per view so pushed deltas re-stat
with the same set. New ops: `attr_list` (all user attributes of one
path) and `attr_set` (set, or remove with an empty value). The daemon
caps a listing at 8 attribute names, since each one costs an lgetxattr
per entry.

**Attribute columns.** A details view can show any `user.*` attribute
as a column: values ride the listing itself, so a remote attribute
column costs no round trip per row. Columns are added and removed in
the column picker, sort by value (entries WITHOUT the attribute sort
last either way — an empty value is absence, not "smallest"), and
persist per tab in `TabState.attr_columns`. Adding or removing one
re-SUBSCRIBES the tab's directories: a plain re-list would leave the
daemon-side view on the old attribute set and the next delta would
blank the new column (found in live testing).

**Properties grew the metadata half.** All `user.*` attributes are
listed and editable in place, with an add row; `user.xdg.comment` and
`user.xdg.origin.url` render as "Comment" and "Where from". Files also
get an on-demand SHA-256 (a daemon hash job, so a remote checksum never
streams the file here), the current default application with a Change…
button that opens the same Open With chooser, and for audio/video/PDF
an on-demand media-info line from the preview helper's ffprobe/pdfinfo
metadata. The one-off size probe became a general `LabelProbe` list
feeding size, checksum, and media labels.

**Emblems.** `src/filebrowser/emblems.zig` (GTK-free, unit-tested)
parses `$XDG_CONFIG_HOME/sketerm/emblems.conf`: `*.md = icon-name` for
name globs, `attr:user.rating=5 = icon-name` for attribute predicates
(`attr:user.foo` alone matches presence). First match wins. The
attributes the rules reference are appended to the listing's attribute
request automatically, so a badge needs no column and no extra query.
This is the rule system the inventory asks for instead of a fixed
overlay registry.

Verification: unit suite 859 passed / 6 skipped / 0 failed (+2 emblem
tests); smoke-fs grew an attribute stage (set, per-entry values in a
listing, namespace refusal, clear-removes-rather-than-empties) and
passes in both modes; smoke-broker, smoke-mcp, smoke-e2e PASS; GUI +
mux + musl + aarch64-macOS builds; mux still links libc/libm only.
Live in an isolated Xvfb rig: a `user.rating` column showing 3/blank/5
straight from the listing, sorting by it with unrated entries last, an
external `setfattr` arriving as a live delta (5 -> 7) in the column,
Properties showing Where from / Comment / rating with working in-place
edits (verified with getfattr), a checksum matching sha256sum, "Opens
with: Vim", and emblem badges from both a glob rule and an attribute
rule with no column configured. Rig torn down by exact PID.

## 2026-07-25: browser package split, Quick Look, breadcrumb navigation

Three commits, each verified independently of the agent that wrote it.

**`src/ui/browser.zig` became a package.** At 9909 lines and ~378
methods on one `BrowserView`, it was both a merge hazard and a wall for
anyone reading it. The bodies moved into `src/ui/browser/`, one module
per responsibility (view, types, conn, render, nav, locbar, tabs, menu,
ops, jobs, open, preview, props, places, search, compare, gitstat), and
`browser.zig` is now a 24-line facade re-exporting exactly the symbols
other code already used.

The technique is worth remembering: Zig 0.16 has no `usingnamespace`,
but a decl alias inside a struct preserves method-call syntax --
`pub const foo = @import("x.zig").foo;` makes `self.foo()` resolve to a
body living in another file. So `view.zig` carries the struct plus a
grouped index of 284 aliases, and NOT ONE internal call site changed.
That kept the diff a pure move, which is what made it reviewable: a
declaration-by-declaration comparison of the original against the new
modules found 398 declarations, 0 missing, and exactly 1 body differing
(`uniqueDstName`, deliberately reduced to an adapter over a new tested
`paths.uniqueName`).

Pure helpers left the GTK layer for `src/filebrowser/`, per the roadmap
rule that the model imports no GTK: `paths.zig` (spec parsing, mount
bypass, trash/archive/media predicates), `format.zig` (size/mode/time
labels), `desktop.zig` (MIME list matching, Exec field codes). All with
unit tests they never had.

**Quick Look, and one preview code path.** Space opens a full preview
of the focused entry, Left/Right walk the current selection (or the
listing) without closing, Enter opens, Escape returns.

The structural change is that previews now resolve through ONE
registry. The old hardcoded "media goes to the daemon generator, else
text head" chain is gone: `filebrowser/previewers.zig` expresses the
built-ins (`thumbnail`, `head`, `hex`, `metadata`) as handlers, and
`$XDG_CONFIG_HOME/sketerm/previewers.conf` adds user rules in the
`emblems.conf` idiom -- `*.zip = text:host bsdtar -tf %f`, `mime:image/*
= image:thumbnail`. A rule's producer may be a command run on the
FILE's host, so a remote preview is generated where the file lives and
only the result crosses the wire. Handlers are rejected at parse time
when they cannot work (an `image:host` command that never names `%o`),
which beats a handler that silently yields nothing forever.

Unhandled types fall back to a bounded hex dump
(`filebrowser/hexdump.zig`) instead of a blank panel, and settling on
an entry warms a fixed 2-ahead/1-behind window. Boundedness was
measured, not asserted: identical interactions in a 50-file and a
10-file directory each generated exactly 6 previews (4 visited + the
lookahead), so a big remote directory cannot become a job storm.

**Breadcrumb location bar.** The path control has two faces now: a
scrollable row of clickable segments, each carrying a dropdown of its
SIBLING directories for lateral jumps and each a drop target, with the
host as the root segment on remote locations; and the existing editable
entry, reached with Ctrl+L and left with Escape. The entry, its
completion popup and its `host:/path` parsing are reused rather than
reimplemented -- `filebrowser/crumbs.zig` holds the GTK-free segment
splitting and elision with its own tests.

Back/forward grew dropdowns listing real history entries, which forced
a good change: `NavigationIntent` now carries the number of steps and
all the stack surgery moved into one `applyHistoryIntent`, including
the "already there" early-return path that previously skipped it.
Mouse buttons 8/9 navigate. Tabs gained middle-click open and close,
Duplicate Tab, drag-onto-tab targeting, and a bounded reopen-closed
ring that restores the tab's history and not just its location.

Verification: unit suite 893 passed / 6 skipped / 0 failed (899 total,
+34); smoke-fs, smoke-broker, smoke-mcp, smoke-e2e all PASS; GUI, mux,
musl and aarch64-macOS builds green; mux still links libc/libm only.
The nav work was based on master from before Quick Look and both had
edited the same key handler and the same struct, so it landed as a real
three-way merge with the overlapping regions read by hand, then the
MERGED tree was exercised live: breadcrumb segments, Space on a text
file, an image fit to window, the hex fallback on a random binary,
arrow stepping both directions, Escape, and the Ctrl+L round trip, with
a clean log. Rig torn down by exact PID.

## 2026-07-25: views, selection, transfers, file ops, media metadata

Six more commits, each reviewed and independently re-verified before
merging rather than taken on the implementing agent's word.

**Views.** Grouping with collapsible headers bucketed by the active
sort key (name initial, size, date, kind, owner, mode), with
directories forming a leading "Folders" group so a bucket never
appears twice. Five zoom steps on Ctrl+wheel, capped at 128px because
that is the freedesktop tier the thumbnail pipeline already generates
-- zooming can therefore never trigger a re-thumbnail. Ctrl+I
filter-as-you-type that narrows the current listing and survives a
pushed delta. Ctrl+B flat view, flattening a subtree into one operable
list over the existing `live_find` job and `Dir.flat` mode rather than
a new verb. Per-folder view memory keyed on (host, path) in
`viewmem.json`, bounded to 256 folders with LRU eviction and an
explicit forget action -- never a sidecar in the browsed tree.

**Selection.** Sticky mode makes a plain click toggle rather than
replace, in both list and grid, so a misclick cannot destroy a curated
set. Registers are named (host, path) mark sets that survive cd, tab
close and restart, and can be opened, selected, copied into a folder
or deleted as a unit, grouped by host so one gesture copies a register
spanning several machines. The collection shelf was the same concept
unnamed and singular, so it was UNIFIED into registers rather than
shipped alongside them, with a one-time migration of an existing
places.json shelf (verified end to end, including a cross-host entry).

**Transfers.** Per-job smoothed rate, computed ETA, expandable detail
and a throughput sparkline. `MAX_ACTIVE_TRANSFERS` was a global cap of
2, which both thrashed one destination and needlessly serialized
unrelated ones; the scheduling decision is now a pure, unit-tested
function -- same destination host (and local device) serializes,
different destinations run in parallel, under an overall ceiling.
Cross-host copies previously bypassed the queue entirely, so a
ten-file paste put ten helpers on one disk; they now flow through it.
Unknowns stay unknown: no total means no ETA, a stalled job withholds
its stale rate.

**File operations.** A collision no longer stalls a paste -- free
names start immediately and only colliders park, decided against a
side-by-side view with a newer/older verdict and apply-to-all.
Directory collisions distinguish merge (keeps destination-only files)
from replace (removes the destination tree first); both are honestly
non-undoable, since undo of a merge would delete files that were never
copied. New from Template reads the templates of the host that owns
the directory. Hard links are offered only where they can work,
decided from a device id the daemon ships once per listing, and the
verb re-checks rather than trusting the client.

**Media metadata, host-side.** `src/mux/mediameta.zig` parses EXIF,
ID3, Vorbis comments, MP4 atoms, dimensions, duration and bitrate in
pure Zig on the host that owns the file. Requests are batched and
answered one event per name, so a listing never becomes one round trip
per row. Reads are windowed (head prefix plus tail suffix), so a 4 GB
video costs a few hundred KB and an mp4 whose moov sits at the end
still resolves; results cache on the daemon host keyed on path, mtime
and size.

Any key from that namespace is now a sortable column, carried by the
SAME mechanism as the existing `user.*` xattr columns -- the namespace
prefix decides the source, so there is one add/remove/sort/persist
path and adding a media column costs no re-subscription. Sorting is
type-aware and the comparator is a proven strict weak ordering;
malformed values rank as missing, because mixing numeric and lexical
comparison in one column breaks transitivity. Bounded fetching was
MEASURED at the wire, not asserted: a 50-file and a 5000-file remote
directory each cost one request, and 120 scroll events coalesced into
six.

**Two infrastructure findings worth remembering.**

A test block in any `src/ui/browser/*.zig` module SILENTLY NEVER RAN.
`src/tests.zig` imported only the facade, and re-exporting a few decls
does not pull a package's tests in. Proven by putting a deliberately
failing canary in `render.zig` and watching the suite report 897
passed / 0 failed without mentioning it. `tests.zig` now imports every
module by name, re-proven by watching the canary fail before removing
it. Every agent since has been required to confirm new tests BY NAME
in the runner output, since a count going up by the right number would
not have caught this.

The browser face intercepts keys bubble-phase, which silently hides
global bindings. `Ctrl+Shift+Z` was swallowing `restore_closed_tab`
and `Ctrl+Shift+A` was taking `copy_screen`. The chords are now a
table, deliberate shadowing is declared with its reason, and a test
fails on any new undeclared shadow -- the collision class is caught by
the suite instead of by review.

Also fixed: `currentSpec()` returned a slice into a shared scratch
buffer that the preview code had already started borrowing for
something else; the remote-thumbnail pipeline never released its
single in-flight slot on a failed handoff, killing remote thumbnails
for the life of the view; tab labels collapsed to "..." because an
ellipsizing label reports the ellipsis as its minimum width; grid
tiles were not drag sources, so dragging in icon view rubber-band
selected instead; two popovers were unreffed while still floating; and
`saveLayoutQuietly` swallowed three errors, making a lost layout
indistinguishable from a saved one.

Known and unfixed: `HostConn.cache_req` is read and cleared but never
assigned, so `hc.cache_dir` stays null and `thumbWriteBack` returns
early -- remote ROW thumbnails are recomputed every session instead of
caching on the owning host. Confirmed pre-existing (never assigned even
before the package split). The daemon-generated x-large preview
thumbnails are a different path and do work, which is why earlier live
verification looked convincing.

Verification: unit suite 983 passed / 6 skipped / 0 failed (989
total); smoke-fs (with new policy and media stages, monolith AND
broker), smoke-broker, smoke-mcp, smoke-e2e all PASS; GUI, mux, musl
and aarch64-macOS builds green; mux still links libc/libm only. Every
live rig torn down by exact PID.

## 2026-07-25 (later): live queries, cleanup, and the test-runner bug

**The "zig build test runner deadlock" was our own bug.** For several
sessions the suite could only be run by killing the wedged runner and
executing the compiled binary directly, and this was written up as a
toolchain quirk. It was not. `fsjob.emitRaw` writes progress lines to
fd 1 because that is the job protocol -- but under `zig build test
--listen=-` fd 1 is the BUILD RUNNER's IPC pipe. A test that ran a
real copy streamed JSON into that protocol, corrupted it, and hung the
run at "run test". `emitRaw` is now a no-op in test builds so the
class cannot return, and the two tests that drive `copyOneFile` ask
for a quiet Progress as well. `zig build test` completes in about a
second again. `dist/PKGBUILD` also lost its `check()`: installing is
not the time to run the suite.

**Live queries.** A filename query opens a tab that keeps updating --
rows appear as files start matching and vanish as they stop, no
polling, no re-run -- and any number stay live at once, each owning
its own daemon job, cancelled exactly when its tab closes. Relative
time is re-evaluated by DEADLINE, not by rescanning: each match
records the instant its mtime leaves the window and the poll sleeps
until the nearest one, capped at 5 minutes so a clock jump cannot
strand the view. The tree is walked once, at startup.

Saved searches and saved queries turned out to be ONE record: whether
opening it subscribes or scans once follows from the query text, so
nothing new is persisted. In the same spirit the flat view, which was
a second `live_find` singleton, became the same per-tab query with
pattern `*` -- so several subtrees can be flat at once and 115 lines
of parallel machinery went away. Panelize gained presets and honesty:
output lines naming nothing on disk are counted and reported rather
than dropped or turned into bogus rows.

**Cleanup pass.** The `homedir` round trip had grown TWO request paths
because `HostConn.cache_req` was read and cleared but never assigned;
conn.zig now owns the single request. The client-side thumbnail
write-back it was supposed to feed is DELETED rather than revived --
the daemon already leaves the spec thumbnail in the owning host's
cache, so a second writer would only fight it. (That also corrects
the note in the previous entry: remote row thumbnails were never
being recomputed every session; the write-back was redundant, not
merely unreachable.)

Also fixed: the remote-thumbnail pipeline could hold its single
in-flight slot forever when a reply never came, killing remote
thumbnails for the life of the view; `entryForPath` could not resolve
flat rows at all, silently breaking properties, preview and register
marks for every search and panelize result; right-clicking inside a
multi-selection collapsed it, because the list and flow box claim
button 0 themselves; the entry menu had outgrown its popover and
simply failed to map on a short screen, and is now grouped into
scrolling submenu pages; `nowMs` was copy-pasted in nine modules and
moved to `src/util/clock.zig`; and `Dir.upsert` re-sorted on every
delta using media values that are only stitched on at render time.

And three more found by the query work: the daemon never forwarded
`ready` or `mtime_ms` to any client, so the flat view's ready branch
had been dead since it shipped; `fsdrive.stashJobEvent` silently
dropped every field it did not name -- the "carry new fields
explicitly" trap one layer further out; and a `live_find` helper whose
daemon died held its recursive watcher open forever instead of
noticing the closed pipe.

Verification: **998 passed / 6 skipped / 0 failed (1004 total)**, now
via plain `zig build test`; smoke-fs (with new policy, media and query
stages, monolith AND broker), smoke-broker, smoke-mcp, smoke-e2e all
PASS; GUI, mux, musl and aarch64-macOS builds green; mux still links
libc/libm only.

## 2026-07-25 (later still): `sketerm files` is its own application

`sketerm files` used to reach into the RUNNING terminal instance and
turn one of its existing panes into a file browser. Four separate
defects stacked up: `newBrowserTabAt` created a tab and then attached
the browser to `focusedPane()`, which is not the pane it just made --
so a pre-existing pane became a browser while the new tab kept an
unused shell; `onActivate` built a second is_primary window every time
(closing either then quit the app); the target was always the single
global `g_app.window`, so a command typed in a second window acted on
the first; and the start location was the pane's bare `cwd`, which for
a remote pane is a path on the OTHER machine.

**The default form is now a separate application identity.** Launched
as `sketerm files [spec]`, the process registers
`dev.sker.sketerm.files` (the base id plus `.files`, so `SKETERM_APP_ID`
still isolates a test rig) and calls `g_set_prgname` with it, because
the Wayland app_id and the X11 WM_CLASS come from the process, not from
any per-window call -- `gtk_window_set_icon_name` alone can never give
the file manager its own taskbar group. Verified: WM_CLASS is
`"dev.sker.sketerm.files", "dev.sker.sketerm.files"` while the terminal
stays `"sketerm", "sketerm"`. Repeat launches open another browser
window in that process (file-manager behaviour), each at the requested
location. `file://` URIs are accepted and percent-decoded, and a URI
naming a FILE opens its parent directory -- the start location cannot
say "and select this entry".

Files mode deliberately does NOT participate in layout persistence:
`last.json` / `default.json` hold one window of terminal tabs and
belong to the terminal identity, so the file manager neither saves nor
restores them (proven byte-identical across a files-app lifetime). Its
control socket is `files-<pid>.sock`, which `sketerm cli` discovery
skips -- opening a file browser must not make terminal scripting
ambiguous -- while an explicit `--socket` still reaches it.

**`--here` and `--tab` are the opposite case** and stay inside the
terminal: they are pure socket clients (no GApplication, no window of
their own) that address the invoking pane through `$SKETERM_SESSION` /
`$SKETERM_PANE_ID` and land on `browser-here` / `new-browser-tab` in
the running instance. Both resolve STRICTLY: an address that does not
resolve is an error, not a fallback to the focused pane -- a
`$SKETERM_SESSION` from another sketerm instance would otherwise turn
a pane nobody named into a browser, which is the original bug wearing
a different hat. Inside a durable REMOTE shell the window's socket is
on the other machine, and the error says exactly that.

**Window targeting is now deterministic.** Pane, tab and window ids
became process-global (a per-window counter gave two windows a "pane
1" each, so "the window owning pane N" had no answer);
`Window.liveWindows` and `Window.windowForPane` walk the
GtkApplication window list, which already carries each Zig Window as
qdata, so there is no second registry to keep in sync. `onActivate`
opens a SECONDARY window when a primary exists; `onShutdown` saves the
primary's layout and tears down EVERY window (a secondary owned panes
and GUI-owned daemon sessions that used to leak), first detaching its
signal handlers so the destroy GTK runs afterwards cannot call back
into freed state. A secondary window closing no longer overwrites
`last.json` with its handful of tabs. SIGUSR1 reloads the config in
every window. The IPC dispatch states its window-resolution rule in
one comment: a named pane acts on that pane's window, a named tab is
found across windows, anything else acts on the active window; `list`
reports every window and tags each tab with a `window` id.

The in-terminal browser is untouched and stayed proven: the palette
`new_browser_tab` puts a browser on the NEW pane (the pane that was
already there keeps its shell and its scrollback),
`new_browser_split` still gives the dual-pane layout with working
F5/F6 copy/move, `sketerm cli new-browser-tab` works, a saved layout
containing browser panes restores into a terminal window, and a
terminal window with browser panes runs alongside the dedicated files
app with each keeping its own identity.

Known and unfixed: the durable-transfer ledger is process-exclusive
(flock), so whichever process opens a browser face first owns it and
the other degrades to in-view transfers with an honest status line
("download is not restart-durable (recovery ledger unavailable)", then
the normal transfer-done and edit-sync notices). With a dedicated
files process that is now the common case rather than an edge one.

## Desktop integration for the file manager (2026-07-25)

The files identity now has the desktop-side half it was missing.
`main.zig` had always asked windows for the icon name
`dev.sker.sketerm.files`, but no such icon existed anywhere in the
repo or on the system, and `dev.sker.sketerm.files.desktop` pointed
`Icon=` at the terminal's icon instead: the file manager has never had
an icon of its own. `data/icons/hicolor/scalable/apps/dev.sker.sketerm.files.svg`
is that icon, drawn in the same family as the terminal one (same
bezel, same title-bar dots) with a folder in place of the prompt
chevron so the two stay distinguishable at taskbar sizes; checked
rendered at 128/48/32/22 px.

The entry also could not be chosen as a default file manager: it
declared no `MimeType`. It now declares `inode/directory` and
`x-scheme-handler/file`, takes `%U` rather than `%f` so KDE may hand
it a `file://` URI (decoded by `filebrowser/entry.zig`), carries a
"New Window" desktop action, and its `StartupWMClass` matches the
GApplication id / WM_CLASS measured live (`dev.sker.sketerm.files`).
Set it as the default with
`xdg-mime default dev.sker.sketerm.files.desktop inode/directory`.
Both entries pass `desktop-file-validate`.

Packaging: `makepkg -si` was silently refusing to install. `pkgver()`
derives from HEAD and uncommitted source changes do not move it, so a
rebuild of the same commit hits makepkg's "A package has already been
built" gate, exits 13 before building, and leaves the previously
installed binary in place -- which is how a stale sketerm kept running
after an apparently successful install. `dist/install.sh` (=
`makepkg -sif`) is now the documented command. The perpetually dirty
`pkgver=` line in `git status` is makepkg's own rewrite of the
PKGBUILD, not a local edit; that had been mistaken for a user change
across several sessions.

## External display sessions + the controller lease (2026-07-25)

An outside automation system (Playwright driving a browser) wants to
render into a sketerm-mux session that sketerm did NOT spawn, and have
a human attach the normal GUI later and take over. Two pieces landed.

**`sketerm-mux display create|inspect|list|destroy`** (`src/mux/display.zig`,
dispatched from `mux_main.zig`) creates a named app session whose child
is a keeper process — `--keep` (`src/mux/keep.zig`), which blocks on its
PTY until the session dies. The session therefore exists only to own a
Wayland display socket and a PulseAudio hub. `create --json` answers
with the exact environment to export:

```json
{"session":"d1","environment":{"WAYLAND_DISPLAY":"/run/.../wl-w1234",
 "XDG_RUNTIME_DIR":"...","PULSE_SERVER":"unix:...",
 "LIBGL_ALWAYS_SOFTWARE":"1"}}
```

Callers must never derive `wl-w<pid>` themselves — the naming differs
between monolith and broker mode. `--gpu` drops the software-GL force,
`--isolated` gives the session a private runtime dir, `--ttl SECS`
kills it after that long with no attached viewer (counted from creation
if it is never attached, so an abandoned create cannot leak a hub).
Duplicate names are refused.

The keeper is spawned as the DAEMON'S OWN binary (`/proc/self/exe
--keep`), resolved daemon-side: a client — possibly on another host
over SSH — cannot know the daemon's binary path, and a mismatched build
would exit instantly. The consequence is that any process hosting a
Daemon must answer `--keep`, which is why `keep.zig` is shared and the
smoke rigs (whose binaries host a daemon in-process) dispatch to it
too. Without that, the keeper re-runs the smoke, recursively.

Spawn `.ok` now carries `wl_display` / `pulse_server` / `runtime_dir`,
and so does session `list`. In broker mode the worker owns the hubs, so
those paths ride its `'Y'` ready datagram, which became `Y{json}`
(`WorkerReady`; the bare-int form is still parsed defensively).

**Controller lease.** Every attached viewer sees a forwarded app, but
only ONE may drive its Wayland seat. The first attach that did not ask
read-only takes a free lease; later ones are viewers. New frames:
`control_req` (client -> daemon: acquire / release / takeover) and
`control_state` (daemon -> every attached client on every change, with
`controller` meaning "do YOU hold it"). Enforcement is daemon-side in
`nativeClientData`: `isSeatIntent` units from a non-controller are
DROPPED, never queued. Deliberately excluded from the gate are the
data-transfer replies (`clip_send`/`clip_data`/`primary_data`/
`drop_data` answer a request the daemon made of that specific viewer)
and the selection offers / `set_scale`, which describe the viewer
rather than drive the app. A controller that detaches or dies hands the
lease to the oldest remaining eligible viewer (`Client.id`, because the
clients list is `swapRemove`d and its order says nothing about age).

`list`/`inspect` report `viewers` and `controller`. `sketerm mux <host>
attach <name>` grew `--read-only` and `--control` (force takeover),
plumbed through the GUI IPC (`Request.read_only`/`control`) into the
attach handshake. MCP (`appdrive`) attaches with `control:true` so
existing app tools keep driving; its log side-connection and the
one-shot `mux send`/`get-text` attach read-only so they cannot steal
the lease. The GUI logs a line when it is view-only — deliberately not
a dialog.

`smoke_display.zig` runs in BOTH `smoke-mux` (monolith) and
`smoke-broker` (real worker processes): create/duplicate/inspect/list/
ttl/destroy, an EXTERNAL weston-terminal rendering into the returned
`WAYLAND_DISPLAY`, and the lease itself. The lease observable is
`request_close`: a non-controller's does nothing, the controller's
closes the app — binary, and immune to the app's own idle repaints
(a cursor blink defeats any "no new frames" assertion).
## Firefox under the session compositor (2026-07-25)

Firefox (and its forks: Camoufox) came up as a window that showed one
flat frame -- black on a dark theme -- and never updated again, and
scrolling it killed the process outright. Two independent bugs, both
proven from a `WAYLAND_DEBUG=1` capture of the real client.

**All of Firefox's UI lives in a subsurface.** Its `xdg_toplevel`
surface carries only the CSD background: one `attach` at startup and
never again. Chrome and page content go into a single desync'd
`wl_subsurface` (a `wp_viewport`-scaled MozContainer) that it
re-attaches to forever. The daemon shipped those frames correctly --
`mux.log` showed `commit pixels: shipping (surface 48, ...)` -- but
`ipc/appdrive.zig` (the headless replica used by every MCP app tool)
*dropped* every frame whose surface had the subsurface role. So the
only frame a window ever got was the CSD background, `frames` stayed
at 1, and the screenshot was the theme's flat window colour. The GUI
renderer was never affected: it maps subsurfaces onto GTK overlay
children.

The replica now composes the window TREE. `wlhost/compositor.zig`
grew the tree queries a renderer needs -- `subtreeLayers` (subsurface
descendants in paint order, offsets accumulated into root-local
coordinates, below-parent group first), `rootSurface`, `surfaceExtent`
and `hitTest` -- and appdrive keeps the root's own buffer in
`Window.base_pixels`, holds each subsurface's latest content, and
recomposites `Window.pixels` (premultiplied-alpha `blendLayer`) on any
frame, move, restack or destroy in the tree. Subsurface repaints count
as window frames, so `wait_change`/`wait_idle`/marker stashes and
recordings all see the real repaint rate. Pointer input goes through
`hitTest`, so clicks/drags/scrolls land on the subsurface that owns
the point, in ITS coordinates, instead of on a toplevel that ignores
them.

**Events were gated on one global seat version.** Firefox binds
`wl_seat` TWICE from separate registries -- v5 for its widget code, v8
for the compositor thread -- and takes a pointer from each. The
compositor kept a single `seat_version` (last bind wins, 8) and sent
`axis_value120` (opcode 9, v8-only) to BOTH pointers; libwayland finds
a NULL listener slot for it on the v5 proxy and aborts the client:
"Wayland protocol error: listener function for opcode 9 of wl_pointer
is NULL", followed by a minidump. Object versions are now tracked per
id (`obj_versions`, seat devices inheriting their seat's version), and
`axis_value120` / `axis_discrete` / pointer `frame` / keyboard
`repeat_info` are each gated on the version of the object they go to.

Verified against Firefox 153 (downloaded, run user-level) on both
paths: MCP screenshots show chrome, page content and a cross-origin
iframe; keyboard (ctrl+l, typed URL, Return) navigates; the wheel
scrolls without crashing; the hamburger menu opens as a real popup
surface; `app_resize` reflows the window. The GUI path (Xvfb +
xdotool) renders the same page and takes motion/keyboard/wheel with no
crash. Chromium is unchanged (scroll repaints, menu popup opens).

## FUSE mount: first real-kernel run, deadlock root-caused and fixed (2026-07-25)

`/dev/fuse` finally became available and `zig build smoke-fuse` ran for
the first time. It found two real defects. (1) The smoke's own
`readFileAlloc` returned `ArrayList.items` (length != capacity) which
callers then freed -- invalid free, aborted the run. Now
`toOwnedSlice`. (2) The real one: the mount deadlocked on the first
write through it. Proven at syscall level: the writer holds the target
folio lock while waiting in `request_wait_answer` for its FUSE WRITE;
the serve thread was meanwhile stuck in `writev` on `/dev/fuse` inside
`folio_wait_bit_common` -- a reverse invalidation
(`FUSE_NOTIFY_INVAL_INODE`) whose kernel side needs that same folio
lock. Synchronous notify from the request-serving thread is a
guaranteed self-deadlock whenever an invalidation races an in-flight
request on the same inode (the WRITE handler even invalidated the
inode it was serving). Fix in `src/fsmount.zig`: all
`notifyInvalInode`/`notifyInvalEntry` calls now enqueue fixed-format
records into a pipe consumed by a dedicated notifier thread; the serve
loop never blocks on the kernel's invalidation locks, and a full pipe
drops the notification (our own read cache is invalidated
synchronously; kernel staleness is bounded by the next open). The
smoke also neuters SIGPIPE like the real binaries (teardown races
surfaced as process death) and prints stage markers.

Verified: smoke-fuse OK 6/6 consecutive runs (leak-checked
DebugAllocator); live `sketerm mount local:...` against an isolated
autostarted daemon: readdir/read/nested/write-through/mkdir/rename all
correct on disk, and an external backend edit -- the exact racing
scenario that deadlocked -- now shows coherently on the next read.
Unit suite 1025 passed / 6 skipped / 0 failed (direct binary run);
mux, musl mux-portable, aarch64-macos builds green; sketerm-mux still
links libc/libm only.
## Per-record transfer ledger, and pausable client transfers (2026-07-25)

Durable file transfers were the property of ONE process: the ledger
was a single JSON document under one exclusive lock, so whichever GUI
opened a browser face first owned every durable transfer and the
others degraded to in-view transfers with an honest status line. Since
`sketerm files` became its own application identity, two GUI processes
at once is the normal case, so that model had to go.

**Ownership is now per record.** `$XDG_STATE_HOME/sketerm/
file-transfers.d/` holds one file per durable transfer (`i-<token>.json`)
and per edit watch (`w-<token>.json`), each owned through its own
`flock`ed `.lock` sidecar. The lock is taken BEFORE the record exists
and held for as long as the process runs it, so a lock that can be
taken means "no live owner"; the record itself is replaced atomically
(temp + rename), which is why the lock lives in a separate file whose
identity survives every rewrite. `flock` and not `fcntl`: fcntl locks
are per PROCESS and are dropped by closing ANY descriptor to the file,
so a second open of a record we already own would silently release it.

Any process creates records and runs its own transfers; orphans (the
owner crashed: record present, lock free, not terminal) are adopted at
startup and every 15 s, exactly once, because adoption IS taking the
lock. Adoption resubmits under the record's `client_token`, which the
daemon answers by handing back the SAME job with its event stream
re-owned -- so an adopted transfer continues rather than restarting.
The record's identity and that idempotency key are now separate
fields: a retry mints a fresh `client_token` (a terminal daemon job
cannot be restarted under the old one) while the record keeps its
name, so a retry no longer resets the panel row's measured rate.

Cross-process duplicate work is prevented where it would actually
collide: `submitDownload` reads the whole ledger, not just the records
this process owns, and refuses to start a download of a file another
window is already fetching (both would write the same staged
`.skpart`); a cache copy another window holds a watch for is opened
instead of re-fetched.

`job_ack` survives a crash: a finished transfer's record is retired
(hidden, never resubmitted) rather than deleted, and disappears only
when the daemon has acknowledged the job. Migration imports a
pre-upgrade `file-transfers.json` losslessly -- intents, watches and
orphan acknowledgments (each as a retired record of its own) -- then
renames it `.migrated`. The one compromise: a PRE-upgrade binary holds
that document's exclusive lock for its whole life, and while it does,
migration is skipped rather than run twice; the old process keeps
running its own transfers from its own file, and the records this
build mints are separate, so nothing is corrupted either way.

The degraded in-view path is now reachable only when the ledger
DIRECTORY cannot be created at all (an unwritable state dir); it is
kept, with an honest message naming that cause, rather than refusing
to open a remote file on a read-only home.

**Client-mediated transfers pause.** `fstransfer` (the pure chunk
state machine the client pumps over two Conns -- cross-host moves and
degraded downloads) had cancel only, because it has no daemon helper
to SIGSTOP. It now holds at the CHUNK BOUNDARY in `requestRead`, the
one point where nothing is in flight and the staged `.skpart` plus
`off` are a consistent checkpoint, and `Xfer` holds between files the
same way. Resume needs no second path: it is the existing
hash-verified resume from the staged partial, in this session or after
a restart. A held transfer occupies no scheduler slot and holds no
destination (it is doing no work), and its ledger record carries
`paused`, so the hold survives a GUI restart -- the row comes back as
`[paused]` with frozen counters, no rate and no ETA. Mediated records
are adopted only while a browser face is registered as their driver
(nothing else has both host connections), and are handed to the next
face, or released for another process, when that view goes away.

Proven live in an isolated Xvfb rig (two GUI processes sharing one
state dir and one daemon, a rate-capped fake ssh host): the files app
and the terminal app each ran a durable download at the same time,
holding disjoint record locks; a `kill -9` mid-transfer was adopted by
the surviving process, which finished the file with a matching
SHA-256; a paused cross-host move stayed byte-frozen (size and mtime)
across the pause, across a `kill -9`, and across the restart, then
resumed to a byte-identical result with the source removed; and a
hand-written legacy ledger was imported into records and retired.

## Browser: keyboard cut/copy/paste, empty-folder menu, files "+" (2026-07-26)

Three usability defects from the transfer session's report. (1)
Ctrl+X/Ctrl+C/Ctrl+V now cut/copy/paste in the browser face -- new
chords in the audited table (all three free in input.zig, audit test
green), backed by a ctx-free `clipSelection`/`pasteIntoCurrent` in
ops.zig sharing `clipStore` with the context menu. (2) An empty (or
failed) folder had NO context menu: the placeholder hides the
scroller, so the listbox gesture could never fire -- and a popover
parented to the hidden listbox would not map anyway. A second button-3
gesture on the always-visible content box, gated on empty_box
visibility so it cannot double the listbox's own background menu,
shows the background menu (Paste/New Folder/Templates/Undo) parented
to the content box. (3) The "+" header button in a files-identity
window opens a BROWSER tab (at the focused browser's location);
terminal windows keep the shell tab.

Chasing (1) live exposed the real killer: after ANY navigation the
clicked row is destroyed and GTK moves focus to some visible widget
OUTSIDE the browser (the window tab bar), so every chord went dead --
`refocusListingIfLost`'s focus-is-non-null guard could not tell that
from focus the user moved. Navigation now uses
`refocusListingAfterNav` (focus must be visible AND inside the
browser root, else pull it back -- navigation is always
browser-initiated), `refocusListingIfLost` treats focus on a
non-visible widget as lost, and renderTab re-checks after rebuilds.

Live proof (Xvfb files-app rig, screenshots read): Ctrl+C on a row ->
navigate into an empty folder -> Ctrl+V lands the file; Ctrl+X then
paste via the new empty-area menu MOVES it (source gone on disk);
"+" gave a browser tab at $HOME in files mode and a fish shell tab in
a terminal window. Suite 1030/6/0 with the chord-shadow audit named
green; smoke-e2e PASS.

## Files UX: Nemo-shaped chrome, real dialogs, terminal integration (2026-07-26)

Jelle's feedback batch ("too fisherprice, too separate-buttons-y")
addressed in five commits, implemented by four parallel worktree
agents plus an orchestrator-authored wire change, each reviewed and
independently re-verified before merging:

- a86af5e fs: listings carry a per-directory child count, counted by
  the OWNING daemon (getdents sweep, >100k = -1 unknown) so remote
  listings get "N items" for free. Unit-tested in fsserve.
- 0bea828 chrome: toolbar reshaped to Nemo's three clusters -- linked
  bordered Back/Forward pair (right-click = that side's history; the
  two pan-down arrow buttons are gone), Up, NEW Refresh, breadcrumb
  path control drawn as one bordered unit expanding in the middle,
  flat icon-only right cluster with a NEW split button (forwards
  new_browser_split through the pane binding table). Sidebar sections
  (Places/Registers/Bookmarks/Saved Queries/Recent/Devices) fold via
  their header rows, persisted as `collapsed` in places.json (absent
  = all expanded). Recent rows show dimmed-parent + plain-name labels
  (splitRecentLabel, unit-tested; local: dropped, remote host kept in
  the dimmed lead, raw spec in the tooltip).
- aa03f78 listing: theme row padding zeroed via a sketerm-fb-list
  scoped stylesheet -> 23px row pitch (Nemo density; ZOOM_STEPS
  untouched). Row/tile/miller icons now come FULL-COLOUR from the
  user's icon theme via g_content_type_guess(name)->
  g_content_type_get_icon (name-only: remote-safe; folder for dirs,
  text-x-generic fallback) -- this is the "why doesn't it use Nemo's
  icons" answer: we hardcoded three symbolic names before. Dirs show
  "N items"/"--" in Size (fileicon.fmtItems, unit-tested). Sort caret
  is a pan-up/down icon right of the title, not " ^"/" v" label text.
  Right-click on ANY header button opens the column picker (still
  parented to tab.page + pointing_to, still survives header rebuilds).
  Context-menu submenu rows carry a trailing pan-end icon and back
  rows a leading go-previous icon (Pages.linkRow) instead of ">"/"<"
  text.
- c2b5d9e term: pane context menu grew a "Files" submenu -- Browse
  Here in Pane (openBrowserHere), Browse Here in New Tab
  (newBrowserTabFrom), Open in Sketerm Files (g_spawn_async of our
  own exe `files <spec>`; GApplication uniqueness forwards into a
  running files instance -- proven live: same pid, rig-isolated).
  paneMenuPrePopup now FOCUSES the clicked pane first, fixing a
  pre-existing bug where every menu row acted on the previously
  focused pane. Files-identity windows never show the per-pane
  titlebar strip (show_titlebar stays honored in terminal windows).
- 978931b props: Properties is a real non-modal AdwWindow (header
  bar, "<name> Properties", 420x560 default, Escape closes via
  gtk_window_close, transient-for the browser toplevel, several open
  side by side). New exposure handled: dialogs outlive tabs/panes, so
  callbacks resolve the host via liveHost() (closed tab = status
  note) and BrowserView teardown destroys its dialogs through
  endProbesFor's existing null-host path.

Taskbar identity mystery resolved WITHOUT code: the installed package
(r1064.g8939e1b, Jul 25) predates eef440b's files-identity work --
the installed .files.desktop still had Icon=dev.sker.sketerm +
StartupWMClass=sketerm. Master is correct end to end (prgname before
GTK init, own desktop entry + SVG, PKGBUILD installs both);
`cd dist && ./install.sh` is the fix.

Verification on the merged tree: unit suite 1033/6/0 (three new
tests: splitRecentLabel, fmtItems, folderIconName); smoke-fs,
smoke-mux, smoke-broker, smoke-mcp, smoke-fuse, smoke-e2e all PASS
run sequentially; GUI + mux + musl mux-portable + aarch64-macos
cross all build; sketerm-mux still links libc/libm only. Live merged
Xvfb pass (10 screenshots read): three-cluster toolbar, dir counts,
colored icons, 23px rows, header right-click picker, submenu arrows,
real Properties window, foldable sidebar, terminal Files submenu
opening the location in the running files instance, red titlebar in
terminal windows / none in files windows.

Deliberate scope notes: browser Refresh does not re-list inline
tree-expanded rows; an insensitive Back/Forward (empty history)
cannot take the right-click history gesture; section fold state is
user-global; file-symlinks now get their target-type icon (symlink
identity rides emblems).

## Files UX batch 2: columns, overflow, un-split, sidebar (2026-07-26)

Second round of Nemo-parity feedback, again orchestrator + two Opus
agents in disjoint worktrees, patches reviewed and re-verified on the
merged tree.

- 8719ea4 pane: widgets_dead fence. Closing a browser pane emitted
  two Gtk-CRITICALs (gtk_box_remove/set_visible from detachBrowser at
  the DEFERRED Pane.deinit, after the widget tree died). wrapper_box
  ::destroy now flags the pane; detachBrowser skips the GTK calls
  past it. Pre-existing (reproduced on master via cli close-pane),
  promoted to a fix because Close Pane is now a first-class action.
- da21f1d columns: ONE width authority (render.columnWidthOf over a
  ColumnRef union) budgets header buttons AND data cells; header box
  now shares the rows' spacing/margins (CELL_SPACING/EDGE_MARGIN
  comptime-asserted against the CSS literals), header buttons lose
  their theme padding via box.sketerm-fb-header CSS, cells gain the
  same 4px inset (label.sketerm-fb-cell), the header's trailing
  3-dots picker is GONE (header right-click + a "Columns..." row in
  the view menu instead), the listing scroller is forced to overlay
  scrolling (header sits outside it). Result: header text and cell
  text start on the same pixel (agent measured deltas 0/0/1/0; size
  stays right-aligned by design). Sort caret: always-reserved 16px
  slot at the column's RIGHT edge -- toggling sort shifts nothing.
  Drag grips between headers (col-resize cursor, live header during
  the drag, one row re-render on release, double-click resets,
  min 40px). Widths persist THREE ways: TabState.col_widths/
  attr_col_widths (positional, absent/short = defaults -- old state
  files load unchanged), duplicate-tab/undo-close/layout restore, and
  NEW per-folder view memory (viewmem Record.col_widths) so a fresh
  files-app start keeps them -- proven live across a restart
  (viewmem.json col_widths [174,0,0] -> Perms back at 174px).
  Column.width() defaults grew 12px to keep text room after the
  insets; ATTR_COLUMN_WIDTH/MIN_COLUMN_WIDTH live in model.zig now.
- 217db85 chrome: right tool cluster collapses into a hamburger
  GtkMenuButton when the breadcrumb viewport drops under 200px
  (expand needs 200 + measured reclaimed width + 24 -- hysteresis, no
  oscillation). Event-driven: notify::page-size + changed on the
  crumb hadjustment, decisions applied on an idle (moving widgets
  inside the layout pass clips the cluster). The SAME widgets
  reparent (ref/remove/append + re-orient vertical AFTER reparent),
  so toggle state survives; search + shell stay inline always; the
  two attach-time menu buttons collapse with the cluster because they
  insert after hidden_toggle whose parent IS the cluster.
  Un-split: new close_pane input action -> Window.closeFocusedPane,
  in the palette, at the bottom of the browser background context
  menu, and as a permanent hamburger row; runs via g_timeout(250)
  because closing inside the popover's own dismiss crashed at app
  teardown (a plain idle is too early). Split button/palette renamed
  to say it ADDS a pane. Sidebar: content row is a GtkPaned
  (resize=false/shrink=false start child), width persisted in
  places.json (sidebar_px, clamped 120..900, 400ms debounced save),
  sidebar_open tri-state (null = follow identity: OPEN in the files
  app, closed in terminal panes; only a real user toggle writes it).
  Double-click the path strip = editable entry (bubble-phase gesture,
  n_press==2, through toggleLocationFace). Explicit
  hover/active/checked CSS via alpha(currentColor,...) because Breeze
  draws nothing for .flat buttons; breadcrumb segments + sibling
  arrows now go through flatten() so the rules reach them.

Taskbar identity: re-investigated with measurements this time. GTK
sends set_app_id("dev.sker.sketerm.files") on the Wayland wire
(WAYLAND_DEBUG=1 under a sketerm display session) and WM_CLASS
"dev.sker.sketerm.files" on X11 (xprop under Xvfb); installed desktop
files/icons on this machine are current and the two SVGs are clearly
distinct at 48px. Every app-side surface is provably correct; no KDE
in this container to reproduce the Plasma-side matching. Next step is
on a Plasma machine: `qdbus org.kde.KWin /KWin supportInformation |
grep -B2 -A8 -i sketerm` (X11) or the KWin debug console (Wayland)
to see the resourceClass/desktopFile KWin actually resolved.

Verification (merged tree): unit suite 1038/5/0 (new: places sidebar
fields x3, model col_widths round-trip, viewmem widths in the
round-trip test); smoke-fs, smoke-mux, smoke-broker, smoke-mcp,
smoke-fuse, smoke-e2e sequentially PASS; GUI + mux + musl
mux-portable + aarch64-macos cross build; sketerm-mux links
libc/libm only. Live merged-tree Xvfb pass: default-open resizable
sidebar persisting 300px across restart, split -> hamburger with
live toggle state -> Close Pane -> survivor re-expands with ZERO
Gtk-CRITICALs, column drag +60px with header/cells in lockstep,
caret right-aligned, width surviving files-app restart via viewmem,
double-click path editing, hover highlight, terminal "+" still
opens a shell tab.

Notes: the columns agent reported "browser tabs lost on --restore" as
pre-existing; NOT reproducible on master via the canonical save ->
--restore flow (browser tab restored fine, screenshot-verified) --
treat as that rig's artifact. Known small gap: a dragged attr-column
width persists per tab but not in viewmem (fixed columns only there).

## Files taskbar identity: a real sketerm-files binary (2026-07-27)

Third report of Plasma merging Sketerm Files into the terminal's
taskbar entry, despite proven-correct app_id/WM_CLASS and current
desktop files. Root cause finally accepted as Plasma-side heuristics:
libtaskmanager falls back to matching by process cmdline/executable,
and both identities ran /usr/bin/sketerm (files desktop entry was
Exec=sketerm files), which resolves to the terminal's desktop entry.

Fix: ship the file manager as its own executable. /usr/bin/sketerm-
files is a HARDLINK to sketerm (PKGBUILD ln; zig-out gets a copy via
a second addInstallArtifact); filebrowser/entry.zig treats argv[0]
basename "sketerm-files" as the files subcommand. Desktop entry now
TryExec/Exec=sketerm-files, and Window.openInFilesApp prefers the
sibling binary when present. Every surface a taskbar can match is
now distinct: exe path, cmdline[0], comm, WM_CLASS/app_id.

Verified under Xvfb + private session bus: sketerm-files window has
WM_CLASS dev.sker.sketerm.files with comm/cmdline/exe all sketerm-
files; repeat invocations of BOTH spellings (sketerm-files, sketerm
files) forward into the one files primary (same _NET_WM_PID, one
process); plain sketerm windows keep WM_CLASS "sketerm" alongside.
Unit suite 1039/5/0 (new: "the sketerm-files binary name IS the
subcommand"); mux + mux-portable build, ldd libc/libm only;
smoke-e2e PASS. Requires reinstall (cd dist && ./install.sh).

## MCP: shell integration reaches SSH terms + idle honesty (2026-07-27)

Bug report: `term_open host:` sessions had no OSC 133 on stock
remotes, so `term_run wait_for:"command"` always refused (the local
spawn-time injection keys on argv[0]="ssh" and never reaches the
remote shell), and idle mode silently queued text typed while a
foreground command ran, with term_wait_idle reporting "idle" during
a sleep.

Fix 1 — remote bootstrap: term_open host sessions now ship a forced
ssh command (termdrive.buildSshBootstrap) whose outer line is quote-
free (parses under any login shell, fish/csh included) and whose
base64 payload is a self-deleting sh script casing on $SHELL: bash
re-execs with --rcfile (temp rcfile emulates the login profile
chain, then sources the shipped sketerm.bash), zsh re-execs -l with
a temp ZDOTDIR carrying the shipped .zshenv shim + sketerm.zsh,
anything else execs plainly (no integration, honest not-ready
refusal). Temp files self-delete on both arms; needs remote base64
(term_exec already does). `integration:false` opts out; an explicit
remote command skips injection. Zsh shim fix that this surfaced:
$precmd_functions is expanded once per cycle, so hooks registered
during the first precmd skipped the FIRST prompt's A mark — the
loader now emits it itself (also fixes local GUI zsh panes'
unmarked first prompt).

Fix 2 — idle honesty (needs active integration): term_run idle mode
sent while a command zone is open appends a "went to that program's
stdin / queued as pending input" note, and term_wait_idle answers
"idle at shell prompt" vs "idle, but a foreground command is still
RUNNING" instead of a bare "idle".

Verified live against a stock Debian 11 VPS over real ssh: bash
(full bug repro incl. sleep-then-queue scenario, exit statuses 0/1,
completion_source shell_integration, no /tmp litter), zsh (temp
user, marks + cleanup), dash (fallback: session usable, honest
refusal, term_exec fine). Unit suite 1041/5/0 (new bootstrap
builder tests), smoke-mcp PASS, mux-portable builds.

Follow-up (same day): tool steering made explicit. term_run's schema
now states it types INTO the live session shell (session dialect,
state persists — cd/export/aliases/venv) and is preferred for
ordinary commands on integrated terminals; term_exec's schema points
back at term_run for those and positions itself as the isolation/
dialect-proof/noninteractive/output_file tool (its on-screen base64
line = the visible cost of isolation). term_open's ssh reply steers
the same way when integration was injected. Rationale: with OSC 133
now reaching remotes, the readable stateful path covers the common
case, so a watching user sees real commands instead of base64 walls,
and history stays truthful. Live-verified on the Debian VPS: state
persists across term_run calls (cd + export observed from a later
command) with exact exit statuses; full 14-check repro suite PASS;
unit suite 1041/5/0; smoke-mcp PASS.

Follow-up 2: term_open always reports the session's shell. Local
terms name it from the spawn-time resolution (reply: "shell: bash,
integration: active"). SSH bootstraps now print a visible
"[sketerm] remote shell: <name> (integration injected|no
integration)" line before exec'ing the shell; term_open waits
(bounded 8s after the idle wait, bailing early when the screen
looks like an auth prompt so interactive auth is never delayed) for
it, parses it (termdrive.scanShellAnnounce), and the reply names
the remote shell. A "no integration" announce (dash/fish remote)
flips Term.integration off, so wait_for=command refuses instantly
with the clean "unsupported" verdict instead of burning the 10s
first-prompt wait, and the term_open steering note switches to
term_exec accordingly. term_list carries "shell"/"integration"
fields (fills in post-auth for sessions that were still connecting
at open). integration:false ssh reports "shell: unknown
(integration disabled; nothing injected to report it)" — honest,
never guessed. Live-verified on the VPS: local bash, remote bash,
remote zsh, remote dash (inactive + instant refusal), opt-out
unknown, term_list fields for all; full 14-check repro suite still
PASS; unit suite 1041/5/0; smoke-mcp PASS; mux-portable builds.

## MCP: transparent sketerm-mux transport for remote terms (2026-07-27)

term_open host: now upgrades its transport automatically: if the
remote host has sketerm-mux in PATH (key auth; a scp'd mux-portable
binary is exactly this), the session is spawned on the REMOTE
host's own daemon over `ssh host sketerm-mux --proxy` instead of a
local `ssh -tt` PTY. Nothing for the assistant to choose: `auto` is
the default, `transport:"mux"` forces (error instead of fallback),
`transport:"ssh"` opts out. Wins: the session survives connection
drops (termdrive reattaches transparently on transport loss — one
bounded connectSshOnce + attach + snapshot resync per drop, re-armed
on success; state like cwd/exports is intact because the session
never died), the integration bootstrap rides the spawn argv
(invisible: not typed, no history entry, no /tmp staging file), and
exit statuses come from the daemon's real waitpid. The bootstrap
script itself was split (buildBootstrapScript inner / b64 ssh
wrapper outer) and now resolves the account shell via the
remote_login_argv ladder (SKETERM_REMOTE_SHELL -> getent -> dscl ->
$SHELL) instead of trusting an inherited $SHELL, since a
daemon-spawned session's env is not an sshd login env. SpawnReq
needed NO wire changes (spawn argv + existing fields only), so any
existing remote daemon version works. Mux terms skip auto-recording
(the .cast would land on the remote host); ttl_secs=3600 reaps
orphans if the MCP client dies without term_close. term_list gains
"transport":"sketerm-mux" + "host". No daemon code changed;
client.zig only made connectSshOnce pub for the bounded reattach.

Verified live (Debian 11 VPS, mux-portable at /usr/local/bin):
auto picks mux (reply says durable + shell: bash + integration
active), command mode + state persistence over mux, kill of the
remote proxy mid-session -> next term_run transparently reattaches
with cd/export intact and exact exit status, transport:"ssh" forces
the old path, deleting the remote binary makes auto fall back to
plain ssh with full integration. The 14-check bug-repro suite
passes over BOTH transports. Unit suite 1041/5/0, smoke-mcp +
smoke-mux PASS, mux-portable builds, sketerm-mux still links
libc/libm only. VPS restored afterwards.

## Files fixes: helper exec, listing perf, sidebar, QL (2026-07-27)

"job helper died" on remote previews root-caused on a live host: the
long-running daemon predated a pacman upgrade, so readlink of
/proc/self/exe yielded "/usr/bin/sketerm-mux (deleted)" and every
job-helper execv failed at spawn. All self-spawn sites (job helper,
display keeper, daemon autostart) now exec the literal /proc/self/exe
via platform.selfExecPathZ (Linux; macOS keeps the resolved path).
Old daemons keep failing until restarted with a fixed binary.

Remote-listing "takes a second" measured end-to-end: wire was 7ms for
353 entries; the cost was client-side. Navigation rendered the listing
twice per drain (commitNavigation + dirty pass -> now once), and each
async thumbnail scheduled a full listing rebuild (70ms+ x 8/s while a
remote folder streamed thumbs -> rows carry a pending-thumb marker and
applyThumbTexture swaps the texture into the live widget in place).

Sidebar: top section is now "Local Places" with local:-qualified specs
(Home/Trash/Devices used bare paths resolved against the CURRENT tab's
host -- wrong machine on a remote tab), plus a per-host "<Host> Places"
section (Home from the homedir reply, now kept on HostConn.home_dir).
Right-click context menus on all sidebar rows (open/copy/bookmark/
remove, matched to row kind). Scroll on the files tab strip switches
tabs like the terminal bar. Quick Look restyled (header split, rounded
image stage, carded text, centered hint), capped at 90% of the
monitor, decode bound 480 -> 1024px.

Verified: suite 1040/5/0, smoke-fs/mux/e2e PASS, mux-portable + ldd
clean; Xvfb screenshot runs for sidebar sections, row menus, QL and
tab-strip scrolling. smoke-mcp term_run-idle failure reproduces on
clean HEAD (pre-existing, unrelated).

## Files: classic context menus (2026-07-27)

The entry/tab/places context menus are now real menus: GtkPopoverMenu
over a GMenuModel (src/ui/browser/classicmenu.zig) with NESTED
submenus -- compact native rows, submenus open to the side ON HOVER,
no more click-to-swap stack pages or button-sized rows. One "run"
GSimpleAction (int target = item index) dispatches into the
unchanged legacy handlers; per-menu ctx structs still ride the
popover as qdata, and the Root (model + dispatch table) is released
via a DEFERRED unparent because GtkPopoverMenu can emit closed
before the activation that still needs the table.

Two GTK 4.22 landmines found standalone-reproducing the "last item
missing" symptom: (1) a popover anchored to a widget INSIDE a
GtkViewport (listing rows, sidebar) gets its height miscomputed and
silently clips its final item -- menus therefore anchor to root_box
with click coordinates translated via gtk_widget_compute_point
(classicmenu.popupVia); (2) the popover's internal scrolled window
under-reports its natural height, so popup() re-asserts min content
height from the CHILD's measure, bounded by the window.

User .action commands ride the New submenu as items (ActionCtx owned
by the menu root). menuButton survives for the non-menu popovers
(view options, selection tools). Verified under Xvfb: full item set
incl. the tail section, hover flyouts, item activation (entry Copy,
places Open-in-New-Tab), submenu labels with '_' escaped. Suite
1043/5/0 (new classicmenu escape test), smoke-e2e PASS.

## linux-dmabuf v4 feedback (2026-07-27)

mpv on a forwarded session refused every GPU video output:
"Compositor doesn't support the zwp_linux_dmabuf_v1 (ver. 4)
protocol!". The brain advertised v3, and mesa/mpv only learn formats
through v4 feedback objects -- the deprecated format/modifier events
are not a fallback for them.

The compositor now speaks v4: get_default_feedback and
get_surface_feedback create zwp_linux_dmabuf_feedback_v1 objects
answered with format_table + main_device + one tranche
(target_device, formats, flags, done) + done. The table is 16-byte
entries (format, pad, u64 modifier) built from the same importer
capability slice the v3 announcements used, so what a client may
allocate still matches exactly what create_immed accepts.

format_table carries an fd, which the brain cannot: it emits a new
`dmabuf_feedback` pipe unit (object id + table bytes) and the daemon
materializes an anon fd and sends the real event -- the same
side-band trick as wl_keyboard.keymap.

main_device is a real dev_t or there is no v4: mux/drmdev.zig picks
the first /dev/dri/renderD* this process can read+write
(SKETERM_MUX_DRM_DEVICE overrides). No render node, or an empty
format table, and the announcement stays at v3 -- a v4 client with
no device to allocate on is worse than a v3 client. A v4 bind
against a v3 announcement is a protocol error, and v4 binds get no
format/modifier events (the spec forbids them).

Replica compatibility: a pre-v8 replica has no feedback interface in
its protocol tables, so re-parsing the app's get_default_feedback
would be a fatal unknown opcode there. State-sync/native-state
version bumped to 8, and Session.native_requires_v7 became
Session.native_state_min (6 legacy, 7 dmabuf modifiers, 8 feedback).
The gate keys on the app's requests, not on the advertisement: a v4
BIND or a feedback object latches Compositor.used_dmabuf_feedback
(pre-v8 tables cap the global at 3, so the bind alone is fatal
there). Old viewers keep rendering GPU sessions whose apps stay at
v3.

Verified: suite 1048/5/0, smoke-mux/broker/mcp/e2e PASS,
mux-portable + ldd clean. smoke-mux gained a scripted v4 stage that
binds v4, requests feedback, receives the fd over SCM_RIGHTS, mmaps
the table and checks the tranche indices address it; it pins
SKETERM_MUX_DRM_DEVICE=/dev/null so hosts without /dev/dri (this
dev box, CI) run the stage instead of skipping it.

## Core Wayland version bumps: compositor 7, shm 2, ddm 4, seat 10, wl_fixes (2026-07-27)

The globals table's "deliberately low versions" stance is right for
protocols we haven't implemented, but wrong for versions whose only
addition is a destructor: a client that binds unconditionally above
what we advertise gets a protocol error and dies. The table already
records two apps that do exactly that (JBR binds wl_seat 5 and
wl_data_device_manager 3 unconditionally), so this is an observed
failure mode, not a theoretical one. Advertise the highest version we
can honestly serve; the obligations are what decide "honestly".

Bumped, with every obligation implemented:

- wl_compositor 6 -> 7, wl_shm 1 -> 2, wl_data_device_manager 3 -> 4:
  each adds only `release`. Handled as destroy-the-global-only --
  surfaces, pools, sources and devices deliberately survive their
  factory, per spec.
- wl_seat 8 -> 10. v9 obliges `wl_pointer.axis_relative_direction`,
  which now precedes every axis event on v9+ pointer objects (the
  spec guarantees it is followed by exactly one axis event for that
  axis in the frame). Always `identical` -- injected scroll is never
  natural-scroll inverted. Gated per pointer object, like
  axis_value120: a v8 pointer receiving opcode 10 is a NULL listener
  slot and an aborted client. v10's `key_state.repeated` needs
  nothing: we never repeat server-side, which is what its absence
  means.
- wl_surface 6 -> 7 (`get_release`): per-commit buffer-release
  callbacks, double-buffered with the pending buffer and fired at the
  same instant as wl_buffer.release. get_release in a content update
  that attaches no buffer is the spec's no_buffer error, which needed
  `fatalCode` -- the old `fatal` hardcoded code 1.
- wl_fixes (new global): `destroy_registry`, so clients that create
  and drop registries stop leaking a server object each time.

Replica compatibility, same shape as the dmabuf-v4 gate one commit
earlier: a pre-v9 replica's tables lack these requests and would take
them as a fatal unknown opcode. State-sync/native-state version 9
(it also carries the surface's pending release callbacks), and
Session.native_state_min rises to 9 only when the app ACTUALLY sends
one of them (Compositor.used_post_v8_request). Review follow-up: the
BIND is fatal to old replicas too (their tables cap seat at 8,
compositor at 6, shm at 1, ddm at 3, and have no wl_fixes), and
bindGlobal's version check is not lenient -- so binding seat 9+,
compositor 7, shm 2, ddm 4 or wl_fixes latches the flag as well.
Advertising still costs old viewers nothing until an app binds high.

Verified: suite 1049/5/0 (four new tests: v9 axis direction incl. the
v8-pointer exclusion, the three release destructors incl. children
surviving, wl_fixes destroy_registry incl. refusing a non-registry
object, get_release both ways), smoke-mux/broker/mcp/e2e PASS,
mux-portable + ldd clean.

Still deliberately absent, and not a version question: wp_fifo_v1,
commit-timing, linux-drm-syncobj-v1, colour management. Advertising a
protocol we do not honour is worse than not having it -- a client
that binds wp_fifo and waits on barriers we never release stalls,
where the same client with no fifo global just uses frame callbacks.

## 2026-07-27: files — Nemo parity batch (clipboard, rename, selection, menus)

Eleven browser gaps closed against Nemo as the reference:

- Copy/cut now also lands on the GDK clipboard: newline-delimited
  absolute paths as text (pastes into editors, no file:// noise) plus
  x-special/gnome-copied-files with the copy/cut verb + URIs, so
  Nautilus/Nemo can paste the actual files. Internal paste unchanged;
  remote-host copies deliberately not exported.
- Inline rename: F2 or the context menu swaps the row's name label
  for a borderless GtkText in place (stem preselected, extension
  kept); Enter commits through the same daemon rename op + undo
  record (`commitRename`), Escape/focus-out cancels. Grid falls back
  to the old popover.
- Zebra stripes (optional, persisted in places.json) + a hover value
  distinctly stronger than the stripe.
- Uniform row heights: one icon/thumbnail size per zoom step (the old
  thumb size, the height the user preferred); async thumbs can no
  longer grow their row.
- Context menus start with "Open with <Default>" and an "Open With"
  hover submenu (up to 20 apps + Other Application...); the chooser
  dialog survives as the "always use"/host-apps path.
- Quick Look: generator output (ffprobe/pdfinfo) is prettified
  client-side (duration as a clock, TAG: lines labelled) and rendered
  as a styled note, never a raw text dump.
- Right-click outside a selection collapses it first (list + grid).
- Rubber-band selection on empty listing space (drawing-area overlay,
  scrolls with content); drags on rows stay file DnD.
- Properties: taller default, no horizontal scrollbars, ellipsized
  heading/labels.
- Toolbar: bundled preview-pane icon, "Split pane" wording, a visible
  Close Pane button; Close Pane also on entry right-clicks.

## 2026-07-27 (later): files — the "best file manager" overhaul

Dolphin and Nemo both mined for their best parts; the browser's
column system rebuilt for real this time.

- Full column set: 17 stat columns (coarse Type a la Nemo, detailed
  type, MIME, extension, permissions, octal, owner, group, links,
  size, on-disk, the four timestamps incl. btime via statx, location,
  target). The daemon resolves owner/group NAMES on the owning host
  (memoized getpwuid/getgrgid) and ships btime_ms; wire-compatible
  additive fields. New SortKeys + grouping buckets for all of them.
- The ~40 known metadata columns (media.*, tag.*, exif.*, doc.*) are
  now one-click checkboxes in a scrollable, grouped column picker
  (File / Media / Audio tags / Camera / Document), Dolphin's
  "Additional Information" style; free-form user.* entry stays.
  Extra-column cap raised to 16 (xattr-sourced still 8, the daemon's
  per-listing budget); name-keyed add/remove helpers so picker
  checkboxes cannot act on stale indices.
- Column resize is LIVE: cells are tagged with their column ref and
  follow the grip per motion frame (no rebuild); the Name column
  gained its own grip (auto "take the leftover" mode until dragged,
  double-click resets), persisted per folder + in tab state.
- Header/rows are structurally linked: the header rides a
  scrollbar-less GtkScrolledWindow LOCKED to the listing's horizontal
  adjustment, so an over-wide column set scrolls as one surface.
  Rows wrap everything left of the data cells in one name-area box
  (fixed and indent-compensated when Name is pinned). Two GTK
  landmines documented in render.zig: GtkBox hands spare width to
  children up to their NATURAL size even without hexpand (so cell
  and name labels cap natural via max-width-chars), and ellipsized
  name labels are END now, like Nemo.
- Dolphin-style Information panel replaces the old preview side box:
  lives in a GtkPaned (user-owned width, persisted; content can never
  resize it), fixed-height preview stage (texture or themed icon),
  bold centered wrapping name, small-font key/value grid (stat facts
  + cached media fields), folder summary when nothing is selected,
  "N items selected" aggregate for multi-selections, content head /
  hexdump in a sideways-scrolling card.
- Optional compact info card at the bottom of the places sidebar
  ("now playing" style: thumb/icon + name + two fact lines),
  independent of the full panel, fetch-free, persisted.
- Toolbar decluttered per Dolphin's philosophy: only Places,
  Information, selection menu, view options, search and shell remain
  as buttons; hidden files, view-mode cycle, new tab, split, close
  pane and go-to-shell-cwd moved into the always-visible hamburger.
  View mode is also a radio group at the top of the view-options
  menu.
- Tree keys: Right expands the focused directory, Left collapses it
  or jumps to the parent row (Dolphin behavior), details view only.
- Header restyled: real padding, bottom border, wider cell insets.

Verified: suite 1052/5 (same skip set), mux-portable, smoke-e2e PASS,
plus a full manual Xvfb GUI drive (columns, live resize incl. Name,
picker groups, info panel incl. multi-select + long-name wrap,
sidebar card, hamburger, tree keys, F2 inline rename on disk).

Known limitations: no horizontal scrollbar UI for over-wide column
sets yet (the shared adjustment scrolls via touchpad/shift-wheel);
media columns need the media_meta job to have answered (blank until
then); the picker's custom-row list closes the popover on remove.


## 2026-07-28: files -- third feedback round (menus rebuilt, icons, columns fixed)

User feedback on the overhaul batch: broken folder icons, a ghosting/
half-speed column drag, a dead strip after the last column, scroll
jumps on expand, missing tab-strip gestures, flaky Split/Close Pane,
menu-structure complaints (cycle-view row, Close Pane on file menus,
no icons, no Create New), an invisible rename editor, and a wish list
straight from Nemo/Dolphin (background menu shape, Compress formats,
menu icons). All of it landed:

- Folder icons showed the missing-image icon on the user's desktop:
  their theme's icon-theme.cache lies about which sizes exist, GTK
  trusts it and fails the load silently, and our 16->24px row-icon
  bump moved HiDPI lookups into the broken slot. New
  `ui/browser/iconload.zig`: every themed icon the browser draws
  validates the lookup's backing FILE and falls back across sizes,
  scales, and the non-symbolic name variant when the cache lied.
  Wired into rows, tiles, miller, places sidebar, info panel/card
  and the toolbar (the invisible Places toggle icon was the same
  disease). Repro: GDK_SCALE=2 + Wings-Dark-Icons.
- Column drag rebuilt: the drag gesture reports offsets relative to
  the MOVING grip, so drags landed at roughly half the pointer
  travel; the math now re-translates into header_box space each
  update (self-correcting, verified 1:1 live and at drag-end). The
  invisible fat-grip bug underneath: the separator line inside the
  grip has hexpand, which propagated to the grip box and split the
  Name slot's leftover 50/50 between button and grip. The mid-drag
  "ghost" was the grip's tooltip popping up under the pointer; the
  tooltip is gone (the col-resize cursor is the affordance).
- Name column is now Nemo's expand column for real: always absorbs
  the leftover width (no dead strip after Modified), a dragged width
  is its MINIMUM (matters once columns overflow), double-click still
  resets. Rows mirror the header (name_area always hexpands).
- Expanding/refreshing no longer yanks the view to the selection:
  the listing viewport's scroll-to-focus is OFF (focus falls back to
  a selected row when the focused row dies in the rebuild -- that was
  the whole bug), the listbox is handed the vadjustment explicitly
  so arrow-key navigation still scrolls, and renderList pins the
  scroll value across the rebuild (captured BEFORE rows are removed;
  the empty list clamps the adjustment synchronously). Navigation
  still starts at the top (per-tab listing hash).
- classicmenu rebuilt as real widget menus: GTK4's model popovers
  cannot render per-item icons (the icon attribute is ignored; the
  custom-child escape hatch cannot reach NESTED submenus -- verified
  empirically), so rows are now flat GtkButtons with a 16px icon
  slot, check rows, and hover side submenus. API kept (item/
  submenu/section + new itemIcon/itemGicon/check/submenuIcon);
  escapeLabel is now a plain sentinel copy (GtkLabel has no
  mnemonics). HARD LIMIT documented in the module: a popover three
  surfaces deep never receives pointer input under the top
  popover's autohide grab, so submenus must all hang off the top
  menu -- menu structures are flattened accordingly (Dolphin's
  KNewFileMenu shape for Create New; Compress as its own submenu).
- Entry context menu, Nemo's shape: Open with <default app, its
  icon>, Open With > (app icons), Cut/Copy (icons), Paste >,
  Rename, Copy To >, Organize >, Compress > (zip/tar.gz/tar.xz/
  tar.zst/7z/tar -- bsdtar derives the format from the destination
  name), Create New > (New Folder + templates + Empty Document,
  flat), user .actions, Move to Trash (icon), Delete Permanently,
  Undo, Properties LAST. Close Pane is gone from entry menus.
- Background menu, Nemo's order: Create New Folder / Create New
  Document > (the local Templates directory listed inline with type
  icons, remote tabs keep the async popover), Paste + Paste
  Special >, Show Hidden Files as a real CHECK row, Open in
  Terminal, user .actions, Undo, Close Pane, and folder Properties
  last (the folder is stat'ed via the daemon -- new feedFolderProps
  routing -- and the dialog opens on the reply; props.zig grew
  showProperties(entry) split out of onMenuProperties).
- Hamburger rebuilt as a classic menu built fresh per open: Create
  New block on top (Dolphin), Show Hidden Files check row, View
  Mode > submenu with check marks (the blind "Cycle view mode" row
  is gone), New Tab/Split Pane/Close Pane, Go to Shell Directory.
  When the toolbar collapses, Places Sidebar and Information Panel
  appear as check rows in the menu instead of reparenting the widget
  cluster (that machinery is deleted).
- Split Pane / Close Pane no-ops fixed: both window actions resolve
  the FOCUSED pane, and toolbar/menu clicks don't move focus; the
  browser now points focus at its own listbox first (focusOwnPane).
- Tab strip: right-click on empty strip space opens New Tab /
  Reopen Closed Tab; double-click opens a new tab on the current
  directory. Clicks on tab labels are excluded by hit-test.
- Click on empty listing space now clears the selection immediately
  (the rubber-band drag-end doubles as the click detector).
- Inline rename editor is visible: the GtkText gets the view's base
  color + rounded corners on the selected row, Nemo-style.
- Empty Document: new `.newfile` entry-dialog mode + daemon `create`
  op (O_CREAT|O_EXCL so nothing can be clobbered); an old daemon
  answers "unknown fs op" cleanly.
- Dead code removed: the cycle-view handler, the overflow
  reparenting slot, the fat-grip tooltip.

Verified: suite 1052/5 skip (same set; classicmenu's test replaced),
mux-portable, smoke-e2e PASS, and a full manual Xvfb drive of every
item above (screenshots at each step): icons at GDK_SCALE=2 with the
corrupt-cache theme, 1:1 live column drag + double-click reset, Name
fill, scroll pinned across refresh, keyboard scrolling intact, all
menus incl. app icons + templates + Compress-to-zip producing a real
archive + Empty Document creating on disk via the new op, folder
Properties from a background click, tab-strip gestures, empty-click
deselect, F2 editor styling, sidebar info card, Split/Close Pane.

Known limitations: dragging Name NARROWER than the leftover is a
no-op while nothing overflows (same as Nemo's expand column); the
classicmenu depth limit means no submenu may contain another; a
long-running daemon needs a restart to learn the `create` op.

## 2026-07-28 (later): files -- columns rebuilt on GtkColumnView, panel width pinned

Fourth feedback round. The headline: the hand-rolled header/rows
column system (two synchronized widget sets) is GONE, replaced by
GtkColumnView -- the machinery GNOME Files runs on. Header and rows
are ONE widget now; they cannot disagree, by construction.

- New src/ui/browser/colview.zig: a GListStore of SkFbItem GObjects
  (registered from Zig; payload freed in finalize) spliced per
  render, GtkMultiSelection, signal factories per column with
  recycled cells, a row factory that makes group headers
  unselectable, native resizable columns (fixed-width persisted into
  the same viewmem/TabState fields as before), Name as the GTK
  expand column, native rubber-band, native horizontal scrollbar,
  gtk_column_view_sort_by_column arrows driven by (and driving) the
  tab's own sort state via dummy sorters -- the model is spliced
  pre-sorted, GTK only tracks the clicked column.
- Grouping, tree expansion, filtering, zebra parity and depth
  indents all resolve into the flat item list (same walk as before,
  emitting items instead of widgets). Zebra parity is computed per
  ENTRY and stamped on the row widget, so stripes stay in phase
  across group headers now (old nth-child bug gone).
- Ported onto the model/positions API: sticky click, visual range
  mode, tree Left/Right keys, type-ahead, register select-here,
  context-menu hit tests (gtk_widget_pick + qdata climb), DnD drop
  targeting, middle-click, batch rename (reads tab.selected), inline
  rename (live path->cell map; also feeds thumbnails and the media
  fetch window), scroll pinning across splices.
- Deleted: header buttons/grips/liveResizeCells/cellRefCode/
  nameBoxWidth, the overlay rubber band, per-row widget builders --
  net ~500 lines of synchronization code replaced by GTK's own.
- Click on empty space clears the selection (rubberband handles the
  drag case; a zero-travel release is ours). Column picker points at
  the header strip. Right-click a header title = picker, unchanged.
- Information panel can no longer GROW past its configured width:
  every label WORD_CHAR-wraps with a tiny natural (max_width_chars),
  so no content can force the paned divider (which then persisted
  the forced width -- a ratchet). Verified with a 90-char unbroken
  name and a 100KB unbroken text head: divider pixel-identical.
- Split view: a durable download's progress row now shows ONLY in
  the pane that started it (Intent.origin, volatile). Records with
  no living submitter (restart recovery, watch sync-backs) show in
  the primary pane only. Verified: 700MB download in a split, bar in
  one pane; after a GUI restart the recovered record surfaced once.
- Remote folder "N items", Owner/Group names, Created: verified
  end-to-end over a fake-SSH remote -- they are computed by the
  daemon on the OWNING host (fsserve countChildren) and simply
  require a current sketerm-mux on that host. No GUI-side fallback
  exists or is wanted (no duplication).

Verified: suite 1052/5 skip (same set), mux-portable, smoke-e2e
PASS, and a manual Xvfb drive: native drag-resize (header+cells move
as one), sort arrows both directions, expanders + nested subdir rows,
group collapse, zebra on/off, all four view modes round-trip, F2
rename landing on disk, rubber band, empty-click deselect, visual
mode, context/background menus, column picker incl. adding 7 columns
with h-scroll, remote tab over fake ssh, split + single progress row.

Known notes: GtkColumnView recycles cells -- anything holding a cell
pointer must go through tab.name_cells (bind-scoped); items borrow
*Entry between renders (splice-on-every-change is the invariant that
keeps that sound). Dragging Name narrower than the leftover is still
a no-op until columns overflow (GTK expand-column semantics, same as
Nemo). Miller ancestor columns and the icon grid keep their old
widgets by design.

## 2026-07-28: automatic mux transport + live reattach

Bare remote hosts now use an explicit auto policy: select encrypted
roaming UDP when reachable, then fall back to the SSH pipe. `udp:` and
`ssh:` force one transport; named domains default to auto and accept
`transport = auto|udp|ssh`. Selection is centralized in mux/client.zig
and used by the mux CLI, GUI attach/restore, browser hosts, FUSE mounts,
cross-host jobs and remote apps. Conn records the selected transport.
UDP bootstrap pipe reads, child reaping and welcome negotiation share
one absolute deadline and every helper fd is CLOEXEC.

Interactive GUI connects keep their existing SSH startup latency, then
upgrade the live attachment to UDP from a worker so an automatic UDP
probe never adds a multi-second GTK main-loop stall. The replacement
snapshot, controller lease, read-only state, pending resize and session
identity transfer in place; a takeover frame is ordered before any user
input on the replacement stream. CLI/background callers probe UDP
directly and CLI reports an SSH fallback. Both UDP bridge ends retire
after 30s without authenticated traffic; byte queues are bounded and
stream backpressure stays non-blocking, so a dead path triggers reattach
instead of leaking a viewer or memory.

GUI durable panes now distinguish transport loss from session exit.
EOF freezes the last screen, destroys connection-scoped app/audio/
transfer state, and reattaches the SAME session in the existing
Terminal from a worker thread. The main loop installs the fresh
snapshot + fd watch in place; pane/tree/profile identity never moves.
Retries are immediate then 1/2/4/8/16/30s indefinitely, with a
persistent clickable pane banner and tabless-app loss/recovery toasts.
Input is dropped while disconnected; the latest resize is resent on
reattach. Clean EXIT/GONE still follows normal exit handling, while
only protocol corruption reaches the crash panel. Reconnect jobs ride
DrainHandle + generation fencing, so pane close/detach safely discards
late worker results. A daemon-confirmed missing session stops automatic
retry and becomes a manual-retry pane state; tabless apps are reaped or
materialized as an explicitly unavailable log tab. In-flight rename and
controller state are reconciled without consuming another operation's
acknowledgement.

Verified: build, mux-portable, suite 1058 pass / 5 skip (1063 total),
smoke-mux and Xvfb smoke-e2e. Fake-SSH tests proved direct UDP success,
unsupported-bootstrap SSH fallback, and an interactive GUI's live
SSH-to-UDP upgrade; commands typed after the upgrade reached the same
session. In a second isolated Xvfb run, the exact GUI proxy process was
killed: the GUI logged loss, reattached over a new SSH proxy, stayed in
the same pane, and commands before and after reconnect both completed.

## 2026-07-28: code-quality pass (dedup, dead code, window.zig split)

Five refactors, no behavior change, each its own commit. config.zig is
now importable from the mux graph (ParamKV moved out of render/
shader_pass — the only GUI dependency), so cross-host fsjobs parse the
REAL config instead of a one-key scanner, and Config.udpRange()
replaces the load-and-extract port-range boilerplate at every
transport call site; the configured UDP range now also reaches mounts,
browser hosts and cross-host jobs (sketerm-mux still links libc only —
checked with ldd). wire.compactConsumed replaces three hand-rolled
buffer slide-downs; reconnectDone/finishTransportUpgrade share one
install-and-replay epilogue; Remote.bumpGeneration owns the fence
counter. Dead worker-era code removed: EventRing/RING_CAP and
util/ring.zig had no consumer, stale mainDrain/worker comments now
describe the daemon-backed reality, spawnFsJob's fourteen parameters
collapsed into FsJobArgs. Remote's connection flags stay booleans
(the axes are genuinely orthogonal — a closed session keeps its
transport until deinit for kill/detach), but ~20 hand-assembled guard
clauses became named predicates (canSend/isLive/awaitingReconnect)
documented once on the fields. window.zig shrank 8854 → 7320 lines via
two extractions using the browser-split pattern (functions keep their
*Window receiver, aliased back into Window so call sites are
unchanged): ui/muxtabs.zig (durable tabs, session attach, layout-
restore jobs, tabless app sessions) and ui/remotectl.zig (ipcDispatch,
cross-window pane/tab lookup, notification slots).

Verified per commit: build, mux-portable, suite (1056 pass / 5 skip —
two util/ring tests removed with the module), smoke-mux, Xvfb
smoke-e2e (which drives the moved ipcDispatch and the daemon-backed
pane path end to end).

## 2026-07-28: god-file split (round 2) + smoke-mcp isolation fix

Every multi-responsibility file is now split along its own section
banners using one pattern (functions keep their receiver, moved to a
sibling file, aliased back into the owning struct so call sites read
unchanged): window.zig 8854 -> 3687 across ui/{muxtabs,remotectl,
modes,winlayout,winconfig,termsinks,tabchrome}.zig; daemon.zig
8427 -> 3951 across mux/daemon_{serve,fsjobs,native,sessions}.zig;
mcp.zig 7658 -> 3897 across ipc/mcp_{browser,term,app}.zig (shared
server state stays in mcp.zig and is referenced through it);
screen.zig's CSI/cursor/erase/scroll/modes/SGR ops moved to
grid/screen_ops.zig and compositor.zig's request dispatch to
wlhost/requests.zig — both those files are roughly half unit tests,
which stayed put and cover the moved code directly. Every remaining
3-4k file is one cohesive core (grid model, compositor brain, daemon
loop+types, MCP server state, window shell) plus tests.

Found en route: smoke-mcp was failing on machines whose real
~/.bashrc loads a prompt manager — the headless bash sourced it and
oh-my-posh replaced the prompt hooks, killing the injected OSC 133
marks. The smoke now runs with an isolated empty HOME (and prints
both replies on failure). NOTE the underlying product gap is real
and unfixed: sketerm's bash integration loses its command marks
under oh-my-posh/starship on real user machines.

Verified per split commit: build, mux-portable (sketerm-mux still
libc-only), suite 1056 pass / 5 skip, smoke-mux, smoke-broker,
smoke-mcp, Xvfb smoke-e2e.

## 2026-07-29: Files interaction fixes + compressed remote previews

Finished the GtkColumnView migration's user-facing edge cases. Native
sort indicators now sit at the right edge of their headers; assigning
an explicit Name width transfers expansion to the last visible column;
the column picker points at the actual header click and can be closed
and reopened without retaining dead widgets. Space is intercepted in
capture phase so Quick Look wins over GtkColumnView's selection toggle,
uses the focused row, expires stale type-ahead state, and refreshes when
the window manager closes it. Register/custom-column activation copies
entry text before destroying its popover. Recent remote rows keep the
hostname in a dedicated non-ellipsized label and truncate only the path.

Remote previews no longer transfer a freedesktop-cache PNG. The file-
owning host still installs the spec-required 128/512px PNG cache entry,
then runtime-loaded libjxl encodes a distance-1 JPEG XL transport image
with exact alpha; runtime-loaded libwebp quality 92 is the fallback.
The receiver advertises its codecs, decodes directly into RGBA, and
accepts at most 512x512 / 2 MiB. Neither codec is an ELF dependency of
sketerm-mux, and no common codec is an explicit preview error rather
than a PNG/original-file fallback. Host-command images use a separate
preview_transport job: box resize + transcode happens on the owning
host without polluting the freedesktop cache.

Temporary ownership is daemon-enforced. A completed panelize preview
authorizes transfer of its random /tmp scratch to the transport job;
the source and exclusive random sidecar are independently tracked,
released on unlink, client death, helper exit, or a five-minute TTL.
The helper announces the sidecar before writing so cancellation can
remove partial output. Browser teardown cancels jobs and unlinks assets
while host connections still exist. Tests pin encoder dimension/size
guards, JXL preference, WebP fallback, RGBA/alpha round trips, and the
source-vs-result ownership invariant.

Remote terminal-to-Files handoff now gets cwd from authoritative mux
session metadata (`session_meta = 90`, append-only after snapshots).
Terminal owns the copied cwd and embedded Files preserves its host;
missing remote cwd falls back to remote `/`, never a local directory.

Verified: build + diff check, suite 1061 pass / 5 skip (1066 total),
mux-portable, smoke-mux, smoke-broker, smoke-fs, and Xvfb smoke-e2e.
Manual isolated Xvfb checks covered right-aligned sort arrows, column
expansion, picker positioning/lifetime, local and fake-SSH Quick Look,
remote terminal Open in Sketerm Files, the remote Recent hostname/path
layout, and a custom image:host preview through preview_transport. A
9.4MB source produced a 545KB host-local cache PNG and a 29KB JXL wire
asset; the custom scratch and new transport sidecar were gone after
display and no custom cache entry was created. Final guardian review
reported no findings.

A follow-up review round hardened the same work. Terminal-to-Files and
the cwd-sync button now canonicalize the pane's host through
`paths.browserHost` (ssh:/udp: transport prefixes strip to the bare
host so the spec reads `host:/path` and shares the connection identity
a typed location gets; `sock:` sessions map to local). The local
daemon's previews advertise and receive plain PNG sidecars —
`wireImageCodecs` in preview.zig, a `PngSink` fast path in
`transportPreview`, and a gdk-pixbuf fallback decode — so local Quick
Look neither transcodes over a unix socket nor requires libjxl/libwebp
(remote stays strict JXL/WebP per design). JXL encodes at effort 4
(distance unchanged) for interactive latency. Review fixes: the
finished-jobs trim loop no longer destroys TTL-held ephemeral preview
jobs (it also mis-decremented a count that never included them);
transport sidecars moved from the thumbnail-cache directory to
/tmp/.sketerm-preview-* so a daemon killed mid-preview cannot orphan
files in the freedesktop cache; and image previewers' transport
authorization ignores stray stdout paths (only the registered %o temp
is consumable). smoke-fs gained an image-preview stage (PNG and
JXL/WebP variants, sidecar read + ownership-aware unlink) under an
isolated XDG_CACHE_HOME, and fsdrive grew `startPreviewCodecs`.
Re-verified: suite 1062 pass / 5 skip (1067), mux ldd libc/libm only,
mux-portable, smoke-mux, smoke-broker, smoke-fs, smoke-e2e, plus a
live Xvfb check of local Space Quick Look over the PNG transport with
sidecar cleanup confirmed.

## Debian/Ubuntu install path

`dist/install.sh` grew a second packaging path. It was a three-line
`exec makepkg -sif`; it now detects the host and either delegates to
makepkg as before (Arch), builds and installs a real `.deb` via
`dpkg-deb` (Debian/Ubuntu), or falls back to a plain prefix install.
Flags: `--mux-only`, `--gui-only`, `--deps`, `--prefix`, `--no-install`.
Both packaging paths share one `stage()` so the layout cannot drift
from the PKGBUILD's `package()`. `.deb` Depends are derived from the
built binary's real `NEEDED` libraries via `dpkg -S` rather than a
hardcoded list that rots across releases (libvpx7 vs libvpx9);
dlopen'd optionals (opus, tesseract) stay Recommends/Suggests, since
their absence is a supported runtime state. Full and mux-only installs
use distinct package names so they cannot claim each other's file
lists.

The script probes gtk4 >= 4.14, libadwaita >= 1.4 and glib >= 2.74 --
the floors below which the GUI does not compile at all -- and degrades
to a daemon-only build with a warning rather than failing, because the
daemon is the useful half on a headless server. Verified on Ubuntu
22.04 (gtk4 4.6.9 / libadwaita 1.1.7, so GUI-ineligible): sketerm-mux
packaged and installed, `ldd` libc/libm only, smoke-mux, smoke-broker
and smoke-fs pass, and the installed binary served `display
create/list/destroy` end to end.

Terminfo needs the SYSTEM `tic`, not the first one on PATH: a
conda/homebrew ncurses writes hex-named directories (`73/sketerm-*`)
while Debian's reader only looks in the letter directory (`s/`), so a
foreign tic installs an entry that silently never resolves. Observed
exactly that on the test host.

`vendor/cimport_root.h` gained three version-gated GLib fallbacks so
translate-c survives pre-2.74 hosts: the 2.74 API pin now applies only
when the system GLib actually reaches 2.74 (glib `#error`s otherwise),
`G_APPLICATION_DEFAULT_FLAGS`/`G_CONNECT_DEFAULT` get pre-2.74
spellings, and `<gio/gunixsocketaddress.h>` is included explicitly
because GLib only folded the gio-unix headers into `<gio/gio.h>` in
2.80. Inert on 2.74+.

`smoke_backlog.zig`'s `newestWlDisplay` compared `st_mtim.tv_sec` only.
Both sessions spawn back to back, so on a fast host they share a whole
second, the strict `>` keeps whichever `readdir` returned first, and
the fake Wayland app connects to the wrong session -- the mcp client
then waits out its 30s recv timeout as "first-commit read". Now
compares nanoseconds too. This was a latent flake on any fast machine,
not an artifact of the test host.

## UDP transport respects the ssh config

`sketerm ssh vastai` reported "UDP unavailable ... connected over SSH"
for every host whose name is an ssh_config alias. The bootstrap ran
`ssh <spec> sketerm-mux --udp-listen` -- where ssh resolves the alias
through the user's config -- but handed the SAME literal string, minus
any `user@`, to the local bridge as `--udp-connect <host>`, which does a
plain `getaddrinfo`. An alias resolves to nothing there, the bridge died
with "cannot resolve", and since `.auto` swallowed the error the only
visible result was a silent downgrade.

`connectUdpFor` now asks ssh itself (`ssh -G <spec>`, which prints the
resolved config and never connects) and targets the resolved `hostname`.
Reimplementing the config parser locally would have been a second source
of truth; ssh already owns `Host`/`HostName`/`Match`. The lookup runs
BEFORE the bootstrap fork, so a `ProxyJump`/`ProxyCommand` host -- which
has no directly reachable address, whatever we resolve -- returns
`error.UdpProxiedHost` immediately instead of burning the probe timeout.
`ssh` missing or too old for `-G` falls back to the literal host, the
previous behaviour.

Fallback reasons are no longer swallowed. `Conn.udp_error` records why
`.auto` came up on SSH and `Conn.udpErrorText` renders it, so the CLI
now prints the cause plus the `sketerm mux udp:<host>` command that
reproduces it loudly. The post-bootstrap handshake failure is
`error.UdpBridgeUnreachable`, distinct from "the remote never announced"
(`error.SshTransportFailed`) -- that split is what separates filtered or
NAT-mapped UDP from an old/missing remote binary.

This came from reading mosh, which defaults to `--experimental-remote-ip=proxy`:
it re-execs itself as ssh's `ProxyCommand`, so ssh expands `%h`/`%p`
post-config and mosh learns the exact address the TCP landed on, printing
`MOSH IP <addr>` for the UDP leg (its `remote` mode instead reads
`$SSH_CONNECTION` off the server). `ssh -G` was chosen over the
ProxyCommand trick because injecting a ProxyCommand overrides any
ProxyJump the user configured, and for a NAT-mapped container
`$SSH_CONNECTION` reports the useless container-internal address while
the resolved `HostName` is the public endpoint.

Note this fixes the ADDRESS, not NAT port-mapping: the bootstrap still
announces the port bound inside the container. See docs/REMOTE.md for
the identity-mapping requirement.

Tests: parser cases (alias, proxyjump, proxycommand, the "none"
spelling, missing hostname), a fake-`ssh` spawn test through
SKETERM_SSH covering the fork/exec/read half, and the auto-fallback
cause recording. Verified with a core-only test build (261 pass),
smoke-mux and smoke-broker. The full `zig build test` and the two GUI
fallback messages (`ui/browser/conn.zig`, `ui/muxtabs.zig`) could NOT be
compiled on this host -- GTK 4.6 vs the 4.14 the GUI needs -- so those
two messages still print without a reason.

## `zig build test-core`: the GTK-free test subset

`zig build test` compiles the GUI, so on a host whose GTK is older than
what the GUI calls into, the ENTIRE suite is unrunnable -- parser, grid,
mux, wlhost and all. That was the state on the Ubuntu 22.04 box this
session ran on (GTK 4.6 against the 4.14 the GUI needs): the daemon
built and its smokes passed, but not one unit test could execute.

`src/tests_core.zig` is a second test root built with the same lean
`configureCoreDeps` set as `sketerm-mux` itself, so the core is testable
wherever the daemon builds. Its membership was not hand-picked: the
transitive `@import` closure of `src/mux_main.zig` gives 66 modules that
are GTK-free by construction, and a generous superset of plausible
additions was then pruned by the compiler until it built clean. What
dropped out was exactly what reaches the GUI -- `ipc/mcp.zig` and
`ipc/appdrive.zig` (via wlapp/winapp), `a11y/nsax.zig`,
`filebrowser/transfers.zig` and `util/gifrec.zig`. 120 modules remain:
902 pass, 7 skip.

It is a SUBSET, never a replacement -- `zig build test` stays the gate.
The rule for new files is in CLAUDE.md: core-side tests go in BOTH
roots, anything touching `ui/`/`render/` only in `tests.zig`. Adding a
GTK-reaching module here would break the build for exactly the
mux-portable users the step exists to serve.

## NAT hole punching for the UDP transport (2026-07-29)

The UDP bootstrap now carries a best-effort, infrastructure-free NAT
hole punch. The insight that keeps it small: everything hard about
traversal was already built. The ssh bootstrap is an authenticated
bidirectional signaling channel (what other systems run a rendezvous
server for), and rudp's roaming rule -- peer address moves only on
AUTHENTICATED packets -- is exactly the latch a punch phase needs.

Mechanics (`src/mux/punch.zig` + both ends of the bootstrap): the
client binds its UDP socket BEFORE ssh starts and writes
"SKETERM-PUNCH <port>" to ssh stdin, so by the time the remote reads
stdin the line is already buffered (zero added latency). The remote
combines it with the client address in $SSH_CONNECTION and pre-aims
its rudp channel there; the channel's own sealed keepalives double as
punch probes, opening the server-side NAT for the client's
retransmitted hello. The client inherits its pre-bound socket into
the bridge child (4th `--udp-connect` arg) and now roams too, so SNAT
port rewrites on either side converge. Old binaries on either end
ignore every piece of this and connect exactly as before.

`zig build smoke-udp` proves the traversal end to end with the REAL
binaries: a fake ssh execs the freshly built `sketerm-mux
--udp-listen` against an isolated daemon, and a second stage rewrites
the announced port so client hellos go into a void -- only the punch
can complete that connect. Run against the OLD daemon binary the same
stage fails with UdpBridgeUnreachable while the straight stage still
passes, which is both the discrimination proof and the version-skew
proof in one.

What this cannot do: symmetric/port-randomizing NAT (nothing without
a relay can) -- the connection falls back to SSH and names the reason.
The pinned-range identity mapping in docs/REMOTE.md stays the
reliable answer for providers that drop outbound UDP entirely.

## Dialect-proof portable-mux deployment (2026-07-29)

The auto-deploy handshake now works regardless of the remote login
shell. The original check/upload scripts were POSIX syntax handed to
`ssh host <script>`, which the LOGIN shell parses -- fish or csh would
fail every deployment (gracefully, but always). The fix is structural:
the remote command is now always a SINGLE word, which no dialect can
misparse. The check phase runs `sh` with the script on stdin; the
upload phase runs the uploader script the check staged, as one bare
word, with stdin carrying only the raw binary.

The interesting failure this surfaced: the first design appended the
payload after the script on sh's stdin, relying on POSIX byte-exact
reads -- and the new real-sh unit test immediately caught dash
(Debian/Ubuntu /bin/sh) BUFFERING stdin scripts and eating the payload
(`head -c` got 0 bytes where bash got all of them). Hence the staged
uploader: heredocs are parsed as script text so read-ahead cannot hurt
the staging, and the payload gets a connection of its own.

Tested at three levels: FakeRunner shape assertions (upload command is
one whitespace-free word), a real-sh round trip through the actual
runSshCommand streaming (deploy /bin/true into an isolated $HOME:
check-miss, stage, upload, verify, republish-check, wrong-arch
refusal), and a third smoke-udp stage that deploys the real mux
through an emulated login shell and completes a hole-punched UDP
connect FROM the deployed copy.

## Dual-pane file-manager fixes + mounted remote opens (2026-07-29)

Five reported problems, four of them one root cause each and all of
them found by reproducing rather than guessing.

**The clipboard was per PANE.** `clip_host/clip_path/clip_paths/
clip_cut/clip_dev` were fields on `BrowserView`, and a BrowserView is
one pane's face. Copying in one pane therefore left the other pane's
clipboard empty: Ctrl+V answered "clipboard is empty" and the context
menu hid Paste entirely, because both Paste rows are gated on
`clip_path != null`. That read as "remote folders cannot be pasted
into", but the host never mattered -- `ops.pasteOne` already routed
same-host to a daemon `copy` job and cross-host to `cross_copy`. The
store is now one process-wide `filebrowser/clipboard.zig` board
reached through `BrowserView.clipboard()`; nothing else about the
paste path changed.

**A dropped link killed a cross-host copy.** `CrossCopy` returned bare
`false` from every failure, so a three-gigabyte transfer that lost its
ssh link at 316 MB reported the literal string "cross-host copy
failed" and stopped. The `.skpart` staging already gave byte-level
resume; nothing used it after a transport error. Now every remote call
goes through a wrapper that classifies Timeout/NotConnected as
transport, re-dials that side (6 attempts, 1-30s backoff) and retries
at the same offset -- every read and write is offset-addressed and the
staged partial holds what was acknowledged, so a reconnect costs a
reconnect and not the bytes. Everything else records which operation,
which path, which host and the daemon's own errno text. A running job
reports why it is stalled (the daemon keeps non-terminal messages
sticky, like the in-flight path), and the GUI resumes a failed copy
three times before leaving the row with its reason and a Retry button.

`zig build smoke-fs` grew a stage that proves it with the real
binaries: a fake ssh bridges stdio to a source daemon and is made to
DIE after 5 MB of a 6 MB file. The copy must still finish, hash equal,
never let its byte counter regress, tell the client about the drop,
and resume at a non-zero offset. Two rig lessons are baked into it: a
bare host makes `connectRemote` spawn ssh twice (UDP probe, then ssh),
so the test forces `ssh:` mode or it severs the wrong connection; and
an in-job reconnect legitimately reports `resumed_from == 0`, because
that counter only describes what a `.skpart` probe found at file
start.

**Opening a remote file downloaded the whole thing.** The FUSE client
had existed unused since phase 6 (`src/fsmount.zig`: ranged reads,
write-through, no libfuse). `ui/hostmount.zig` is now its lifecycle --
one child per host under `$XDG_RUNTIME_DIR/sketerm/mnt/<pid>/<host>`,
shared by every pane and window, unmounted at shutdown, orphans of a
SIGKILL swept at the next start. Per-process mount points on purpose:
no stacking when two instances browse one host, and no live mount
pulled out from under one when the other exits. Downloading survives
only as the fallback, and the status line names the reason.

**Ctrl+L reached the wrong pane.** Not a chord problem: much of a
browser face cannot take focus (the places sidebar's empty space, the
toolbar, the status line), so clicking the other pane left focus in
the pane you came from and the chord bubbled there. A capture-phase
click on each face pulls focus over only when it is currently in
another pane. Ctrl+L also OPENS the entry now instead of toggling it,
and folds the peer's, so exactly one address bar is ever open.

**Column widths never re-fit.** A dragged Name width was persisted per
folder and then treated as a floor forever (a real `viewmem.json` held
`name_width: 1762`), so splitting a pane left Name alone on screen
with every other column behind a horizontal scrollbar. A stored width
is now a preference clamped to the room the viewport actually has, and
re-applied on resize -- GTK4 has no widget resize signal, so the hook
is the scrolled window's hadjustment page-size, which IS the viewport
width. The stored value is never rewritten by the clamp, so widening
restores it.

## Review pass on the file-manager batch

A review of the previous batch fixed four things and one build.

**One row per cross-copy.** Every dropped link left a spent `.failed`
row (with a live Retry button) stacked next to the copy that resumed
it -- up to four rows for one transfer, and the button could submit
the same copy twice while an automatic attempt was armed. A resumed
attempt's row now supersedes the failed one (`dropSupersededRetryRows`
on the daemon's job reply), and `retry_scheduled` hides the button
while a resume is pending.

**Failed mounts age out.** hostmount kept a host `.unavailable` until
app restart, so one ssh hiccup meant downloading forever. A failure
now retries after a 30s cooldown, a mount that dies while ready says
"the mount ended", and `shutdownAll` fences waiter ticks so nothing
respawns into a dying process.

**The cross-copy smoke tested the wrong daemon.** Its "local
destination" resolves `$XDG_RUNTIME_DIR/sketerm/mux.sock`; daemon B
listened one level up, so `connectLocalAutostart` silently spawned the
INSTALLED `sketerm-mux` and leaked a broker per run. B now sits at the
default path and the stage exercises the code under test.

**fsjob duplication.** Eight retry wrappers shared one
classify-reconnect-or-fail pattern; `recoverOrFail` is now the single
copy, symlinks reconnect like everything else, and the initial dial
names the side and host in its retry notices.

**aarch64 cross-build.** `zig build mux-portable
-Dportable-target=aarch64-macos` was broken by bare `@ptrCast` on
dlsym results (fn pointers have real alignment on aarch64); every
dlsym site now `@alignCast`s.

## Session overview (the "what is playing that sound?" fix)

The app switcher grew into a real task overview (palette: "Session
Overview…", action `app_windows`). One dialog lists open forwarded-app
windows (thumbnails), every attached session — panes AND tabless app
sessions whose window is closed, the classic invisible-sound case —
and attachable sessions on the local daemon, on every REMOTE host the
window has sessions on, and on assistant (MCP) instances. Daemon
lists are fetched on worker threads (`pending_ops`/`dead` keep the
struct alive until the last op lands); unattached rows get a kill
button riding the same thread pattern.

Audio is first-class: the daemon's `list` reply now carries
`audio:true` for any session with an uncorked stream
(`sessionAudioRunning`, broker via a new WorkerMeta field on the 'M'
push), the CLI/TUI show `[audio]`, and attached rows use the LOCAL
sink truth (`AudioSink.playing` -> `Terminal.audioPlaying`). The
smoke-display audio stage speaks the native PA protocol against a
real session socket and asserts the flag flips on and off in BOTH
monolith and broker modes — the broker 'M' hop is exactly where such
fields have silently regressed before.

## Files-browser usability pass (Nemo-alignment round)

**Columns.** Header titles are left-aligned (the hexpanded
GtkColumnViewTitle label kept GTK's centered xalign; now pinned to 0).
The expand policy no longer hands surplus width to the LAST column
when Name has an explicit width — closing a split grew Modified to
half the window. Now: auto Name expands; an explicit Name width means
NO column expands and the surplus stays blank at the right, Nemo-style
(the shrink-clamp in `fittedNameWidth` is unchanged, so narrow panes
still never scroll horizontally).

**Selection + delete.** Selected rows have explicit accent CSS (list
and icon grid), so an open context-menu grab no longer greys them into
looking dropped. Move to Trash and Delete Permanently now act on the
WHOLE selection when the clicked row is inside it (`menuTargets`, same
rule as copy). Delete Permanently confirms via a real window-modal
GtkAlertDialog with Nemo's wording (names one item, counts many)
instead of the unanchored top-of-page balloon. New chords: Delete =
trash (undoable, no prompt), Shift+Delete = confirmed permanent
delete, Ctrl+D = bookmark the current folder.

**Sidebar.** Sections are now identity-keyed ("local", "remote",
"registers", "bookmarks", "searches", "recent", "devices",
"widgets:<name>"): right-click anywhere in the sidebar gets a config
menu with per-section show/hide checks, headers get Move Section
Up/Down, and the order/hidden sets persist in places.json
(`section_order`/`hidden_sections`, merged by
`places.orderSections`). Bookmarks got labels (`bookmark_labels`,
parallel array — old files load unchanged), rename via a prompt,
move up/down, and a menubar Bookmarks menu. NEW: user widget
sections (`src/ui/browser/sidewidgets.zig`) — title/text labels,
local command output (optional refresh interval), images, and
command-fed sparkline graphs; model in places.json
(`widget_sections`), runtime (GSubprocess fetches, timers, history)
lives per view and resets on edit. The model is deliberately
sidebar-independent for reuse elsewhere later.

**Menubar + About.** Files-mode windows get a classic File / Edit /
View / Go / Bookmarks / Help menubar (`src/ui/browser/menubar.zig`),
built per click from live state on the classicmenu machinery. Help >
About is a non-modal AdwAboutWindow whose version badge carries the git
describe + commit date embedded at build time (`runCapture` in
build.zig -> `build_options.commit`/`commit_date`; tarball builds
degrade to "unknown").

**Preferences.** Now an AdwPreferencesWindow — a real toplevel,
transient but NOT modal and no longer an attached sheet. Files mode
can reach it (menubar Edit, background context menu, hamburger). New
"Files" page backed by three config.conf keys: `files_default_view`
(details|compact|icons|miller), `files_show_hidden`,
`files_confirm_delete` (false skips the permanent-delete prompt).
Defaults apply at newTab; per-folder view memory still wins.

## Listings: stream, count async, never block the loop

The "open a 307-item NFS folder = 5 seconds of Listing..." fix, in
three parts. (1) The daemon no longer builds a listing synchronously
inside the fs_op callback: `fsStartListing` reads and sorts the NAMES
up front (one cheap readdir, so open errors still reply
synchronously), then `pumpFsListings` — a tick pump beside
pumpDownloads with the same wbuf watermark — stats entries in
time-boxed batches (8ms) and streams them as the fs_reply `more:true`
chunk run every consumer already accumulates; the poll timeout clamps
to 0 while listings are pending. (2) `countChildren` (a full readdir
of EVERY subdirectory, inline per entry) left the listing path
entirely: after the stat stream, the same pump counts the listed
directories in 5ms batches and ships the numbers as idempotent upsert
deltas on the open view — the GUI's existing delta path fills the "N
items" cells in place; single-entry stats (properties, watch deltas)
still count inline. (3) The GUI renders each chunk as it lands:
navigation commits on the FIRST chunk (Nemo-style, rows immediately),
`Dir.streaming` keeps the status honest ("listing… N items so far"),
and a refresh (`list` op) keeps the old swap-at-end so live rows never
half-disappear. Wire format unchanged — old daemon/new GUI and new
daemon/old GUI both degrade to the previous behavior. smoke_fs grew an
async-child-count stage; the 1300-file chunk test now really crosses
poll ticks. Also confirmed (not new): the browser's ssh connection
already rides OpenSSH ControlMaster multiplexing from the terminal's
session, so no reconnect cost was left there.

## UDP connection tickets: reuse the session's transport (2026-07-30)

"Open in sketerm files" from a UDP session used to pay a full ssh
handshake + `--udp-listen` bootstrap for the browser's own connection
(the ControlMaster from the original bootstrap dies after 120s — a
long-lived UDP session holds no ssh at all). Now any client holding a
live authenticated channel can ask the daemon to mint a **connection
ticket**: the daemon spawns one unchanged `--udp-listen` sibling
(`--socket` aims it back at the minting instance) and returns
`{port, key}` over the existing sealed channel (wire frames
`udp_ticket_req` 26 / `udp_ticket` 91, gated on a `udp_ticket:true`
welcome capability so old daemons are never asked). A new client dials
it with `Conn.connectUdpTicket` — no ssh, ~1 RTT on an already-proven
path; every failure falls back to the normal transports.

Consumers: `openInFilesApp` pre-mints over the pane's UDP terminal
conn (async, 3s bound) and hands the ticket to the spawned files
process via `$SKETERM_UDP_TICKET` (single-use, host-matched); a
browser pane inside the terminal GUI mints in-process
(`remotectl.mintUdpTicket` — pending slot on `Remote`, resolved
exactly once via frame/loss/teardown/timeout, DrainHandle-fenced).
No hole punch rides the ticket path: a filtered port costs one
bounded timeout, then the ssh bootstrap — the status quo.

The live-rig bug worth remembering: a detached daemon has fds 0-2
closed, so the ticket listener's UDP socket landed on **fd 2** and
`runUdpListen`'s post-announce `close(0..2)` detach destroyed it —
announced port, nobody listening. Fixed by parking the socket above
the stdio range (and giving the spawned listener a full /dev/null
stdio set). The smokes never caught it because smoke rigs have real
stderr; the fix was found by driving the real GUI over the MCP rig.

Proof: `smoke-ticket.zig` shared stage runs in BOTH smoke-mux and
smoke-broker (unattached = broker-served, attached = WORKER-served via
the new `Daemon.broker_sock`), smoke-udp gained a stage that mints
over a live UDP conn and reconnects with ssh refusing to run anything
but `-G`, plus a live end-to-end pass through the real GUI (context
menu -> files app over ticket; Browse Here in New Tab -> in-process
mint) with `mux.log` showing the mints and `ssh.log` showing zero
bootstraps.

## Files: selection, real menubar behavior, non-modal About

Selected rows now use the GTK theme's selected background/foreground
colors instead of libadwaita-only accent aliases (Breeze did not
define those aliases, so the override erased its blue selection).

The custom menubar now owns an open-menu state: its heading keeps the
theme accent tint + underline, pointer hover switches headings while a
menu is open (motion is captured on the grabbed popover and translated
back to bar coordinates), and F10/Left/Right/Escape provide the
classic keyboard path while GTK handles row traversal. The target
browser pane is pinned while the menu chain is open so focus moving
into menu chrome cannot redirect an action to another split. Menubar
dropdowns have compact, scoped
padding/radii; ordinary context menus are unchanged. `classicmenu`
again measures each populated row box after parenting and pins the
scroller's bounded minimum height, removing the one-item opening jump.

Help > About now creates a separate transient, non-modal
`AdwAboutWindow`, matching Preferences, rather than an attached
`AdwAboutDialog`. Verified through the isolated Sketerm MCP compositor:
blue row selection, File -> Edit hover switching, 192x58 one-row Help
menu, separate 388x340 About window. Full suite 1090/5/0 and
smoke-e2e PASS.

Follow-up field test: the Help menu still visibly resized because the
settled screenshot missed its opening commits. The populated row box
was stable; GTK's always-automatic vertical scrollbar contributed its
theme minimum during realization, then disappeared after adjustment
visibility resolved. `stabilizeScroll` now pins measured min/max
content height and uses `GTK_POLICY_NEVER` for genuinely short menus
(<=96px), retaining automatic scrolling for longer or cap-constrained
menus. MCP frame trace changed from two popup commits settling at
192x56 to one first-and-final 192x34 commit; File likewise opens in one
192x148 commit. Scrollers retain the real row box as qdata so submenu
measurement and F10 focus do not stop at GTK's intermediary viewport.

## 2026-07-31: big remote folders stop freezing the browser

Opening a large remote folder (vastai, 1500+ entries) left the UI
dead for minutes: hover flickered, clicks were eaten, Up did nothing.
Four compounding causes, all fixed:

1. Every child-count fs_delta batch full-rebuilt the listing model
   (all row items destroyed + respliced, plus one full sort per
   upserted entry via Dir.upsert). Count deltas now take
   Dir.countOnlyIndex: the count is written in place ("children" is
   never a sort input) and colview.refreshEntryRow resplices ONE row,
   so hover/selection/scroll stay untouched. Structural deltas still
   rebuild, but through the throttle below.
2. Socket-driven renders (streaming chunks, watch deltas) now go
   through scheduleListingRender, a 120ms leading-edge throttle;
   interaction renders stay direct.
3. Navigating away did not stop the daemon: dropFsViewAt only ended
   the count phase while the stat stream kept queueing chunks for the
   dead view ahead of the next request (the dead Up button). A
   close_view now aborts the listing with an `aborted:true`
   terminator; LISTING_WATERMARK dropped 8MB -> 1MB. smoke-fs gained
   an abort stage (mono + broker).
4. Remote thumbnails ran strictly one-at-a-time, each paying a
   host-side job round trip (minutes for a folder of photos). The
   pipeline is now a 4-wide pool (BrowserView.remote_thumbs), and the
   queue is purged on navigation.

Verified live by driving the real files GUI through a scripted
`sketerm mcp` instance against a fake-ssh remote rate-limited to
150KB/s with 1540 entries + 80 dirs + 60 photos: rows stream in,
counts fill without a rebuild, selection stays accent-blue through
clicks (~100-200ms repaints), Up supersedes a pending slow navigation
instantly, thumbnails trickle in. Suite 1092/5/0, test-core 926/5/0,
smoke-fs, smoke-mux, smoke-e2e all pass; new unit test for
countOnlyIndex.

## 2026-07-31: local persistent cache for remote thumbnails

Remote thumbnails only lived in a 256-entry in-memory map, so every
new browser process re-fetched them (job round trip + transfer per
file). The transport sidecar bytes (JXL/WebP, 3-6x smaller than the
spec PNG the remote's freedesktop cache stores) now persist under
$XDG_CACHE_HOME/sketerm/remote-thumbs/: filename md5("host:path"),
12-byte header (magic + mtime_ms) validates freshness, stale entries
overwrite in place, a lazy oldest-first sweep (once per process, cap
4096 files) bounds growth. thumbLookup checks the disk before the
wire; a hit decodes on the existing worker thread. Local-daemon
fetches never land there (their freedesktop cache is already local).

Proven on the 150KB/s fake-remote rig by timeline: run 1 wrote all 59
sidecars; run 2 (fresh process) rendered every thumbnail with zero
cache rewrites (= zero wire fetches); touching a photo on the remote
re-fetched exactly that one entry once. Suite 1094/5/0; new unit
tests for the header round-trip and cache-name derivation.

## 2026-07-31: remote hosts cache thumbnails as JXL, not PNG

Decision: local daemons keep installing spec freedesktop PNGs (shared
with the desktop's other file managers and pickers); remote hosts
stop generating PNGs entirely. The browser sends wire_cache:true on
thumbnail ops to remote hosts; the remote daemon then caches the
transport codec bytes themselves (~/.cache/sketerm/thumbs/<md5>.jxl
or .webp, 3-6x smaller than the PNG tier, freshness = file mtime
stamped to the source's) and serves that file directly — no spec PNG,
no per-fetch re-encode. Miss path reads through a valid freedesktop
PNG when one exists (interop hits still count); no codec libs on the
remote falls back to the legacy PNG path. The done event carries
keep:true: the GUI skips its asset unlink and FsJob.done_kept keeps
daemon job reaping from unlinking the cache. Old daemons ignore the
field (unchanged); old GUIs never send it.

smoke-fs gained a wire-thumb stage (mono + broker): keep flag, cache
path, no freedesktop PNG installed, stat-validated hit (same inode),
mtime-change refresh. Live rig verified: 60 photos -> 60 .jxl on the
"remote", zero PNGs, thumbnails render, client-cache-cleared revisit
serves the same inodes and the cache survives the client's cleanup.
Rig lesson recorded in CLAUDE.md: a re-exec'd daemon has comm "exe",
so pgrep -x sketerm-mux misses stale test daemons — one served a
deleted pre-feature binary and mimicked a broken feature for an hour.

## 2026-07-31: 512px previews join the wire cache (no remote PNG at all)

The preview op (Quick Look / side panel, x-large tier) was the last
path installing spec PNGs on remote hosts. runWireThumb now serves
both tiers: 128px thumbnails at sketerm/thumbs/<md5>.<ext>, 512px
previews at sketerm/thumbs/xl/<md5>.<ext> (own directory so the two
tiers of one source never collide), same mtime-stamp freshness, same
keep:true / read-through / no-codec-lib fallback semantics. Media
metadata (ffprobe/pdfinfo) is computed per fetch on hit and miss,
exactly as the spec-PNG path always did. GUI: the preview op sends
wire_cache to remote hosts and PreviewRead.keep guards both unlink
sites (endRead + temp replacement in the done arm).

smoke-fs wire-thumb stage extended (mono + broker): preview keep +
xl/ path + tier non-collision + no x-large freedesktop PNG + hit
same-inode. Live rig: Quick Look on a fake-remote photo landed xl/
jxl entries (plus neighbor preloads), zero freedesktop PNGs, close +
reopen left inodes untouched; a standalone --job wav preview carried
duration metadata on both miss and hit.

## 2026-07-31: direct remote-to-remote transfers + daemon-owned moves

Two transfer fixes. (1) Cross-host MOVES left the client-mediated
path (GUI relaying bytes, dying with the window) and became
cross_copy jobs with a new delete_src flag: the helper deletes the
verified source strictly after the rename, a failed delete fails the
job with the copy intact (retry = cheap hash-skip re-verify + redo
the delete), and the flag is journaled so a daemon-restart respawn
stays a move. (2) Remote-to-remote copies no longer relay through
this machine: pickCoordinator submits the job to the DESTINATION
host's daemon, whose helper dials the source directly. Gated on a
new cross_move welcome capability; host strings on the wire are
coordinator-relative. An unreachable peer (e.g. two hosts with no
keys for each other) fails one capped dial (dial_tries) with the
error stamped kind:"unreachable", and fallbackDirectCopy resubmits
the same job through the local daemon — same staged partial, no
auto-resume attempt spent.

smoke-fs crossStage grew: file move + tree move (source gone only
after verify), and the dead-host stage now asserts the unreachable
kind and rides dial_tries. Live rig (three fake hosts, per-host
daemons): A-to-B copy coordinated by B (its journal owns the job,
the GUI-local daemon journal stayed empty), A-to-B cut-paste moved
with delete_src:true, and A-to-C (C's outbound ssh dead) failed one
direct attempt then relayed via the local daemon 33ms later with a
matching hash.

## 2026-07-31: hover-stable listings, instant navigation, daemon self-upgrade

The vastai flicker report came back "not fixed" — and the root cause
was double. First, the daemon on that host had been RUNNING for two
days: every daemon-side fix shipped this week was invisible there
(deploy is content-addressed but never restarts a live daemon).
Second, the GUI still full-rebuilt the listing model on STRUCTURAL
watch deltas (only count deltas were surgical) — an actively-written
directory rebuilds forever, old daemon or new.

Three fixes, all verified against the REAL vastai host with its OLD
busy daemon still serving:

1. renderList now splices a WINDOW: build the desired items as
before, match common prefix/suffix by identity (path/depth/zebra
parity; rows named in BTab.changed_paths are forced into the
window), re-aim reused rows' nulled dir/entry pointers, splice only
the middle. Unchanged rows keep their GObjects — GTK never rebinds
them, so hover, selection and clicks survive delta storms.
mediacols.applyToDir change-detects stitched meta into
noteChangedFull. Local churn rig (3 writes/sec): hovered and
selected rows pixel-stable (single-frame bursts), clicks land in
~100-170ms. Real artifact_hunt: same, with thumbnails streaming.

2. Navigation commits INSTANTLY: navigateMode adopts the empty
streaming candidate at click time (location bar, tab, history move
NOW; rows fill in as chunks land; failures land as a load error on
the visible dir). Real vastai: 280ms from double-click to committed
location + "Listing..." page, against the old synchronous daemon
that used to freeze the click for seconds.

3. Daemons self-upgrade when idle: the welcome announces the build
id (git describe, now in every binary's build_options);
Conn.upgradeStaleIdle probes sessions + running jobs over
LONG-STANDING verbs and uses the ancient .shutdown frame, so even
pre-announce daemons are replaceable. Wired into GUI startup (before
the window spawns its own pane session — learned live: from inside a
running GUI the local daemon is never idle) and the browser's remote
connect worker. Busy daemons are never bounced; the status line says
they serve an older build. Verified: an installed-binary daemon on
an isolated socket was replaced by the dev binary at GUI start;
vastai's daemon (2 live sessions) was correctly left alone and its
sessions confirmed intact after the whole test round.

## 2026-07-31: PNG preview fallback, forwarded-app subsurface offset, menubar icons, queued GUI sends

1. Remote previews/thumbnails no longer die on hosts without
libjxl/libwebp: the GUI's advertised codec list now always ends in
"png" for remote hosts, and the daemon's transportPreview tries
jxl/webp first with an stb-PNG last resort (compiled in — works on a
static mux-portable where dlopen can never load a codec). The wire
cache stays jxl/webp-only; PNG rides the legacy freedesktop path.
imagecodec's dlopen probe re-probes while nothing loaded (installing
a codec mid-session upgrades transfers without a restart; APIs are
returned as copies under a spinlock). Explicit Reload clears the
preview/thumbnail negative caches so a fixed host is observable in
the same session. Error message now names the real condition.

2. Forwarded CSD apps (Firefox) drew their content subsurface offset
~20px from the window border: wlapp's parentPlacement added the
parent's xdg window-geometry origin (the CSD shadow inset) to BOTH
popups and subsurfaces. Per spec (and per our own daemon-side
compositor model) wl_subsurface positions are parent-BUFFER
relative; only xdg_popup anchors are geometry-relative. Placement
now takes a role, and cropped views (macOS/embedded) subtract the
crop origin for both roles. updateShadowLayout moved after the crop
store so re-resolves see current crops.

3. Files menubar dropdowns carry icons (tab-new, window-new/close,
edit-cut/copy/paste/select-all, prefs, view-refresh, go-prev/next/up,
user-home, user-trash, bookmark-new, help-about — Nemo's mapping);
check rows keep the checkmark slot like Nemo's iconless toggles.

4. No-block-UI hardening: fstransfer sends now QUEUE
(queueFrame/queueJson) — the browser flushes wbuf remainders via a
per-HostConn G_IO_OUT watch (ensureWriteFlush/onFdWritable), so a
1 MiB chunk into a slow host's full socket buffer can no longer hold
the GTK loop in sendFrame's 30s poll; smoke_fs pumps flush queued
writes itself. hostmount.isMounted answers from /proc/self/mounts
instead of stat'ing the mountpoint (a wedged FUSE helper hung the
old device-compare). sendOp/closeViewOf queue too.

5. Natural filename sort: naturalLess in filebrowser/format.zig
(digit runs compare numerically, case-insensitive text, deterministic
padding/case tiebreaks) replaces lessThanIgnoreCase for every name
comparison in applySort — "file2" before "file10" in all views.

Verified: zig build test 1097 pass / test-core 929 pass (new
transportPreview-PNG + naturalLess tests), smoke-fs OK (transfer
pause/resume/disconnect stages over the queued-send path),
smoke-mux PASS, xvfb smoke-e2e PASS, mux-portable builds.

## 2026-07-31: file browser gap sweep (audit follow-up)

The feature-audit gaps, all closed in one pass:

1. DnD modifier overrides: Ctrl forces copy, Shift forces move at
drop time (listing drops read the controller's modifier state);
no modifier keeps the topology default. Cross-host Shift-drop is a
delete-after-verify move via the existing transfer machinery.

2. Free space in the status line: a statfs rides every ROOT listing
(navigation/reload/resync) and the count phrase appends ", N free".

3. Auto-reconnect: a dropped remote host with tabs still on it is
re-dialed on a backoff timer (3s/8s/20s/45s, then give up —
every attempt may spawn a real ssh). wireReady adopts stranded tabs
onto the fresh connection and re-subscribes their views.

4. Remote git overlays: refreshGitOverlay submits a `git_status`
daemon job on remote roots — porcelain runs on the repo's host,
prefix-stripped records stream back as match events (gitstat.zig
feedGit), same aggregation as the local worker-thread path.

5. Frecency jump (Ctrl+J): visits recorded per location spec
(count + last-visit, capped 200, lowest-score eviction) in
places.json; the popover ranks by zoxide-style recency buckets and
filters as you type. Enter = top match, click = that row.

6. Compare Files (two selected files, same host): a `diff -u`
daemon job streamed as line events into a transient monospace
window. Cross-host pairs refuse honestly.

7. Split/Combine (TC convention): Tools submenu splits into
10M/100M/1G `.NNN` parts beside the file (refuses existing parts);
a `.NNN` file offers Combine Parts (999 max, refuses an existing
destination). Both daemon jobs with progress.

8. Secure Delete… (files only): one PRNG overwrite pass + fsync +
unlink, daemon-side; always confirms (config cannot skip it), the
dialog says CoW filesystems make it best-effort.

9. files_verify_copy (prefs toggle, default off): copy jobs hash the
staged .skpart against the source BEFORE the rename installs it; a
mismatch discards the stage and fails the file.

10. Frame-parse budget: the browser socket drain parses at most 8ms
per main-loop dispatch and continues on an idle (per-HostConn
drain_idle), so a 4MB fillAvailable burst can no longer stall input.

Verified: 1098/930 tests green (frecency model test added), smoke-fs
+ smoke-mux + xvfb smoke-e2e PASS, mux-portable builds, and every
new daemon verb exercised end-to-end through `sketerm-mux --job`
(split→combine byte-identical, secure delete unlinks, diff streams,
git_status M/? records, verified copy).

## 2026-07-31 — remote transport honesty sweep

Root-caused the "copying is an atrocity" report: three compounding
defects, all fixed.

1. rudp reorder buffer + fast retransmit: a lost datagram no longer
discards up to 127 delivered segments behind it (receiver holds them;
one head retransmit releases the run), duplicate cumulative acks
resend the head before the RTO, and the send backlog drains by offset
instead of an O(n^2) memmove per segment.

2. Inactivity timeouts: fsdrive's flat 10s completion deadline
classified any chunk slower than ~210 KB/s as a DEAD LINK, tearing
down and re-bootstrapping a healthy connection per chunk (the
"unreachable / reconnected; resuming" flap). Waits now die only after
10s with no bytes arriving (recvFrameProgressive, 120s hard cap under
the MCP watchdog); bulk write waits budget for the upload itself.

3. Paste-while-connecting: startTransfer dropped the job outright
when a host was still dialing. Deferred transfers now queue on the
view and fire from wireReady (dropped with a message if the host
dies). Covers paste, drag, dual-pane send, cross-host moves.

Also: hostmount's dead-end (a mount finishing after the 20s ready
timeout was never used again — every open silently downloaded) now
promotes to ready whenever the live child's mountpoint appears, and
wireReady warms the host mount eagerly so the first double-click open
does not pay the whole dial. connectRemote keeps a per-host UDP-down
stamp (10 min) so mount/copy helper processes stop re-paying a failed
6s UDP probe, plus a deploy-verified stamp that skips the ssh check
leg; both under $XDG_CACHE_HOME/sketerm/mux. Transfer panel buttons
got tooltips.

Verified: 1100 tests green (2 new rudp tests), test-core, smoke-mux,
smoke-udp, smoke-mcp, xvfb smoke-e2e all PASS; mux-portable +
aarch64-macos cross build; sketerm-mux still links libc only.

## 2026-07-31 (later) — transfer polish + sidebar/props features

1. rudp AIMD congestion window (start 16, +1/ack, halve on fast
retransmit, floor 4 on RTO): full-window blasts were inducing the
loss behind the 3 MiB/s -> 300 KiB/s throughput sawtooth. Display
side smoothed too: PROGRESS_BYTES 4->1 MiB, SMOOTHING_MS 2->5s,
STALL_MS 5->10s.

2. Transfer panel redesign (jobpanel.zig): per-row state icon with
Adwaita color classes, bold name, link-state pill badge (connecting/
reconnecting/reconnected parsed out of the job message instead of
prose on the head line), percent-labelled bar, right-aligned rate
label; detail area is now an aligned key/value grid (Source/
Destination/Current file/Files/Bytes/Rate/ETA/Status) beside the
sparkline. applyRow shared by build+refresh.

3. Continue Copy: interrupted cross-host copies (retry budget spent,
or canceled) are journaled in $XDG_STATE_HOME/sketerm/
incomplete-copies.json (filebrowser/incomplete.zig, capped 64); a
re-paste of the same src->dst shows a suggested "Continue Copy"
button in the conflict dialog riding the daemon's resume semantics.
Completion clears the entry.

4. Per-bookmark icons (theme-icon name, emoji, or absolute image
path scaled to 16px; "Change Icon…" context-menu prompt; places.json
gains a parallel bookmark_icons list, old files pad defaults) and the
redundant per-row X remove button is gone (context menu has Remove).

5. Properties "Previous Versions": the file across Timeshift
(/run/timeshift/backup/timeshift-btrfs/snapshots/*/localhost|@) and
snapper (/.snapshots/N/snapshot) btrfs snapshots, discovered with
existing daemon list/stat ops (works on remote hosts), newest-first,
capped 64, identical runs deduped keeping the oldest; rows offer
Open and Restore-a-Copy (never overwrites). Pure logic in
filebrowser/snapshots.zig (in both test roots).

Verified: zig build clean, full test suite + test-core exit 0 (1108/
941 incl. new rudp fast-retransmit/reorder, incomplete round-trip,
places icon round-trip, 6 snapshots tests), smoke-mux + smoke-udp +
xvfb smoke-e2e PASS, mux-portable builds.

## 2026-08-02: durable transfer batches and aggregate selection facts

Large multi-item paste/drop commands now render as one collapsed row
with aggregate byte/file progress and optional per-item details. The
cross-host admission path persists one bounded v5 batch manifest first,
then materializes deterministic child tokens from GTK idle callbacks;
expanded children stay hidden until admission ends, avoiding quadratic
widget rebuilds. Retry predecessor/successor rows deduplicate by the
durable item token, and panel rebuilds preserve the user's scroll
position.

The manifest owns the complete command, including conflicts and drop
probes. Child records carry their parent token, terminal tombstones live
until the parent is durably retired, Skip is one terminal write, and
owner identity prevents two panes from submitting one child. Recovery
routes an ownerless batch through registered panes until one can accept
its destination. Record creation/deletion fsyncs the ledger directory;
an ambiguous failed rename is poisoned to an unreadable version rather
than becoming runnable after a crash.

Multi-selection information now totals sizes from already-loaded file
metadata without synchronous filesystem work, naming excluded folders
and unavailable sizes honestly. Inline rename selection has an explicit
theme-safe foreground/background rule.

Verified: zig build; 1134/1139 full tests and 945/950 core tests (five
skipped in each); smoke-fs, smoke-mux, smoke-broker, smoke-mcp,
smoke-udp and xvfb smoke-e2e PASS; Linux-musl and aarch64-macos
mux-portable builds; sketerm-mux still links libc/libm only. Live GUI
checks covered a responsive 400-file batch, final-build grouped copy,
34-byte aggregate selection total, expansion and rename selection.

## 2026-08-02: MCP app tools — freshness receipts, log events, honest verdicts

Feedback from three assistants driving real applications through the MCP
app tools (a 2001 Win32 game under a Vulkan compat layer, Star Trek:
Armada, and an ASAN build of a 1995 DOS game) reported the same root
problem in different shapes: several tools could not distinguish "I do
not know" from "no", and the resulting confident-but-wrong readings were
written into project documentation and later retracted. The work below
makes those states structurally distinct.

**Frame numbers are now the freshness currency.** Every screenshot
caption states the window's commit counter (`App.Shot.frame`), every
input tool reports the frame it acted at, and `screenshot_app min_frame`
blocks until the window has committed something strictly newer —
returning a described error rather than an image that is not. `wait_change`
is relative to the caller's last screenshot and can never express "newer
than the input I just sent"; `min_frame` can. app_click builds its
handle from the FIRST attempt's frame, so an auto-retry cannot hand back
a number that accepts pixels the earlier presses already produced.

**Events can be waited on directly.** `app_wait_log` blocks until a log
line matches and returns it with the current frame number, which is the
synchronisation primitive for apps whose interesting moments are
announced in their own stderr and which never visually quiesce. `app_log`
grew real pattern filtering over a documented regex subset
(`src/util/pattern.zig`: literals, `.`, classes, `* + ?`, `^ $`,
top-level `|`; no groups, so parentheses are literal). Zero matches is
reported as "0 of N scanned lines match" with nothing shown — the
unfiltered tail is never silently substituted, because to anyone diffing
output that reads as matched content.

**Verdicts say which state they mean.** `app_wait` reports the frame
delta it observed with every outcome, gained `min_frames` (liveness by
commit count), and reports never-settling as a normal ALIVE AND
ANIMATING state rather than a timeout. App selection separates "no
sessions exist" / "no app has id N" / "AMBIGUOUS, here is the roster";
the previous single "unknown app" message read exactly like a crash and
was misdiagnosed as one. `app_a11y_tree` recognises a registry with no
widgets under it and says the app publishes no accessible tree at all,
so falling back to coordinates is a decision instead of a guess.

**Process teardown and debugging.** `Pty.signalTree` escalates
SIGTERM/SIGKILL to the child's whole process GROUP, so wrapper scripts
and forked workers die with the session instead of accumulating as
orphans, and `close_app` waits for the daemon's acknowledgement and says
so plainly when it does not arrive. The gdb wrapper passes SIGPIPE and
glibc's thread signals through (batch mode otherwise stops at the first
harmless signal, reports against it, and quits before the real fault)
and dumps all threads' backtraces; because the wrapper survives the
fault and exits 0, `appSummary` marks `exit_status_is_wrapper` with a
note whenever a debugger signal is inferred.

Smaller: `include_log_delta` on the input tools, a one-shot pointer at
app_macro_save once 12 inputs are journalled, `[x,y,w,h]` accepted
alongside `{x,y,w,h}` for regions with an error naming the shape, all
app-side waits clamped to 120s (under the watchdog) with the schemas
saying so, `capabilities` explaining that isolated-mode sessions end
with the server and not on an idle timeout, and the leaked `%%` in four
schema descriptions fixed.

Verified: zig build; 1149/1154 tests pass (5 skipped), including a new
test that parses the whole advertised tool list (a mis-nested brace in
one schema breaks tools/list for every tool and is otherwise invisible)
and unit tests for the pattern matcher, app selection, frame counters,
bare a11y trees and region parsing. A scripted MCP session against the
real server proved end to end: launch args reaching the process verbatim,
zero-match reporting, pattern classes and alternation, app_wait_log,
the ambiguity message, capability lifetime text, frame numbers in
captions, min_frame returning strictly newer pixels and erroring when
unreachable, app_wait min_frames and animating verdicts, the no-a11y-tree
message, region shorthands, and a forked child confirmed alive before
close_app and gone after.

## 2026-08-02: Sketerm Viewer V1

`sketerm view` and the installed `sketerm-viewer` alias now run a
separate `dev.sker.sketerm.viewer` image-viewer identity. The Viewer
loads local and remote resources through the daemon file service:
bounded preview first, explicit full-resolution ranged read second,
with no FUSE mount in the data path. Existing Sketerm mount paths are
refused so they cannot loop back into the same daemon.

Linux decoding prefers runtime-loaded Glycin 2 and its sandboxed
loaders; GdkPixbuf is the portable fallback. Both paths normalize to
RGBA and enforce source and pixel limits before retaining a decoded
image. One active loader plus one replaceable pending request bounds
rapid navigation, and generation/liveness fencing prevents stale or
post-destroy callbacks.

The shared image canvas now powers the Files information panel, Quick
Look, and the standalone Viewer with fit, actual-size, zoom and pan.
Files launches the exact visible image order, including filtered and
expanded-tree rows. A private mode-0600 runtime manifest replaces an
unbounded argv list; consumption verifies directory, owner, type,
permissions and symlink safety, while timed and age-based cleanup
remove abandoned handoffs.

Packaging installs the Viewer desktop entry, icon and alias. Arch
depends on Glycin and libheif; Debian recommends the Glycin 2 library
and loaders. Verified: build 33/33; full suite 1146 pass / 5 skip;
core suite 955 pass / 5 skip; aarch64-macos mux-portable; desktop and
shell validation; sketerm-mux still links only libc/libm. Isolated GUI
checks covered preview/full loading, decoder fallback, source-size
rejection, filtered and expanded-row ordering, rapid navigation,
manifest cleanup/error handling, side-panel rendering, and Quick Look
closing during a full-resolution load without GTK criticals.

### Viewer V1 completion

The shared canvas now has fit, fill, actual-size and manual modes,
pointer-anchored wheel zoom, pinch zoom, drag pan, swipe navigation and
temporary quarter-turn rotation. Standalone Viewer and Quick Look expose
the same controls and keyboard equivalents. Their accessible image state
reports the resource, sequence position, dimensions, effective zoom,
rotation, loading state and animation playback state.

Glycin and GdkPixbuf decoding now retain bounded multi-frame GIF, APNG
and animated WebP sequences. Frame delays, finite play counts, a shared
per-session animation clock, pause/resume, monotonic catch-up and cached
rotated frames keep playback correct without one timer per canvas.
Decoded animation bytes, frame count and per-frame pixels all have
independent limits, and cancellation is checked while frame rows are
copied.

Viewer actions now include Copy Image, reload, Open With and Show in
Sketerm Files. Internal image loading still never creates FUSE mounts;
Open With may explicitly mount a remote resource for an unrelated local
application and falls back to a bounded daemon download when mounting is
unavailable. Temporary copies live in a verified private cache, canceled
copies are removed, launched copies expire, and stale copies are swept.
Show in Files opens the parent and selects the exact local or remote file
after its streamed listing arrives, including hidden, filtered and
grouped views.

Verified on the completed V1: build 33/33; full suite 1166 pass / 5
skip; core suite 967 pass / 5 skip; aarch64-macos portable mux build;
desktop/SVG validation; and the mux binary still links only libc/libm.
Isolated GUI runs proved infinite and finite animation, replay,
pause/resume, fill, rotation, copy, metadata/accessibility, Quick Look
promotion, exact Files reveal, and clean status-0 shutdown without GTK
or GLib criticals.

## 2026-08-03: Session Overview redesign — audio identity, thumbnails, reuse

The Session Overview (palette, formerly "App Windows") is now a real
task overview: an Adwaita CSD window with search, grouped boxed lists
(Playing Audio / Application Windows / Attached Sessions / Available
Sessions), live GtkWidgetPaintable thumbnails for native and streamed
windows, per-row attach/focus/stop actions, and keyboard navigation
with selection preserved across refreshes.

Audio is identified, not just flagged. The session's internal
PulseAudio server now parses client and stream proplists (application
name/binary/pid/icon, media name/title; bounded, UTF-8-safe, PA
merge/replace/set semantics) and ships them as a `metadata` audio unit
plus `audio_streams` summaries in `list` replies, through the broker's
'M' push as well. Stream descriptors (open/metadata/cork) replay on
subscribe over the audio-priority lane, closing the startup race that
produced audible-but-unidentified sound; smoke-mux and smoke-broker
assert the replay, ordering and cork transitions end to end.

The overview polls without connection churn: one persistent connection
per daemon serves every list poll and session stop (serialized ops,
one redial on a dead idle conn), the first remote dial rides a UDP
ticket minted over an existing attached connection when possible, and
attaching a session consumes the idle connection instead of dialing.
Daemon discovery re-runs each refresh cycle and prunes vanished
assistant daemons. Stops in flight keep every matching button
insensitive across re-renders; the status line derives from live
state. The broker worker-control buffer is comptime-sized from the
metadata constants so growth cannot silently truncate 'M' datagrams.

Verified: full suite 1172 pass / 5 skip; core 971 pass / 5 skip;
smoke-mux, smoke-broker, smoke-e2e; portable mux build; mux binary
still links only libc/libm. Isolated GUI runs proved stable
connection counts across polls, kill and attach flows, live
thumbnails, and search filtering.

## 2026-08-03: display sessions as an xvfb-run replacement

`sketerm-mux display run [--size WxH] -- COMMAND...` now owns the complete
headless-test lifecycle: collision-resistant generated names, environment
application without shell evaluation, software GL by default, inherited X11
display removal, direct argv execution, command exit-status propagation,
process-group signal forwarding, and guarded teardown. Persistent `create`
also generates a name when omitted. Parent and subcommand help are wired.

Output geometry is daemon state, not keeper PTY geometry. It travels through
spawn/list and broker ready/metadata JSON, initializes each authoritative
compositor brain, and drives wl_output mode, scale-adjusted xdg-output logical
size, and configure_bounds. Inspect/create JSON reports the effective mode and
GPU policy. `display_v2` prevents a new CLI from trusting old daemons that
would silently ignore geometry or the display-only kill fence.

Collisions now name the occupied session and remediation. Inspect/destroy
reject ordinary terminal sessions, destroy waits for the Wayland socket to
vanish, and failed create output is rolled back. TTL occupancy now includes
live external Wayland channels, so a long unattended render is not reaped;
the complete TTL starts after its client disconnects.

Coverage in both smoke-mux and smoke-broker exercises custom size metadata,
help without a daemon, exact collision diagnostics, GPU inspect fidelity,
scoped-run environment/status/cleanup, guarded shell-session destruction,
and active-renderer TTL pause followed by expiry. `docs/display.md` records
the Xvfb mapping and native-Wayland limitations.

Verified: full suite 1173 pass / 5 skip; core suite 972 pass / 5 skip;
smoke-mux and smoke-broker PASS with the shared display stage; normal build,
static-musl mux, and aarch64-macOS portable mux build; `sketerm-mux` retains
only libc/libm runtime dependencies.

## 2026-08-04: rootless Xwayland display compatibility

External displays now auto-enable rootless X11 when Xwayland and
xwayland-satellite 0.8.1+ are available. `--xwayland` makes compatibility a
hard requirement and `--no-xwayland` keeps a display Wayland-only. Successful
create/list/inspect replies report `xwayland`, `DISPLAY`, and `XAUTHORITY`;
`display run` applies them directly, including Java's non-reparenting hint.
The CLI proves readiness with an authenticated X11 setup handshake. A broken
automatic runtime is destroyed and recreated Wayland-only rather than taking
the requested display down; required mode fails honestly.

`src/mux/xwayland.zig` owns display-number allocation, pre-populated atomic
lock publication, stale-owner reclamation, filesystem and Linux abstract X11
listeners, a random mode-0600 MIT-MAGIC-COOKIE-1 record, process-group
supervision, parent-death handling, and exact normal teardown. `/tmp/.X11-unix`
is accepted only as a sticky world-writable directory owned by root or this
uid. Existing lock nodes are inspected nonblocking under `flock`, and socket
probes are bounded, so hostile FIFOs or listeners cannot wedge the daemon.
Satellite stdout/stderr is detached from the creating CLI and the broker
control descriptor is close-on-exec. TCP listening is disabled.

Satellite remains the XWM and maps X windows into the existing xdg-shell
pipeline; the mux daemon gained no XCB dependency. Its host Wayland connection
is marked auxiliary: it forwards frames and input normally, but only a live X
toplevel (not idle infrastructure) pauses display TTL. X11 metadata crosses
both worker ready and ongoing broker metadata messages.

The shared display smoke now runs a real X11-only xterm in monolith and broker
modes. It validates authenticated `display run`, mode-0600 authority, frame
forwarding, viewerless active-window TTL retention, controller close,
post-window TTL expiry, and lock/socket/authority cleanup. Unit coverage also
checks dead/live lock handling and nonblocking rejection of a FIFO lock node.

Verified: full suite 1175 pass / 5 skip; core suite 972 pass / 5 skip;
smoke-mux and smoke-broker PASS with the real-xterm stage; normal build,
static-musl mux, and aarch64-macOS portable mux build; `sketerm-mux` retains
only libc/libm runtime dependencies. Cross-protocol drag and drop remains
toolkit/upstream-dependent and is not part of the compatibility contract.

## 2026-08-04: assistant-feedback fixes for headless GUI ergonomics

An external AI assistant used the MCP + CLI as an Xvfb replacement and filed
detailed feedback; this session lands the fixes.

MCP: `capabilities` now reports `headless_gui` (what launch_app actually
depends on) with explicit hints on it and on `gui_socket`, plus a
`mode_hint` for non-shared modes explaining the private-daemon split — a
bare `gui_socket:false` had been read as "no GUI capability at all".
`launch_app` gained `size:"WxH"` (virtual output mode, rides
SpawnReq.output_width/height through appdrive; the spawn ok confirms it and
the reply WARNs when an older daemon ignored it) and `stable_ms` (default
500): the inline launch screenshot now waits for painting to quiesce so it
lands past the blank pre-paint frame, with honest caption notes for
still-repainting and first-frame captures. The schema also states the
daemon-side environment (cwd = daemon's own, minimal env, absolute paths).

CLI: `sketerm run <command...>` is the new xvfb-run-shaped alias for
`sketerm-mux display run -- <command...>` (inserts the `--` itself,
`display.runCommandStart`); top-level and mux help point at it. `sketerm
app` no longer prints a hard failure when no GUI window is present: the
session runs headless by design, the notice says so with attach/list hints
and exits 0, and `--headless` skips the viewer attach on purpose. `sketerm
mux <cmd> --help` prints help instead of creating a session named
"--help". `sketerm doctor` now unlinks the stale GUI sockets it used to
only count.

Verified: full suite 1177 pass / 5 skip; smoke-mux and smoke-mcp PASS;
`sketerm run --size 3840x2160` shows the requested wl_output mode via
wayland-info and forwards the command's exit status; a driven MCP session
confirmed the new capabilities fields and a settled gnome-calculator
launch screenshot; mux-portable stays libc-only.
## Text editor foundations, native file picker, portal backend

The editor is a new pane face on the terminal's GPU stack. A headless
spike (spike-editor-text) first proved the existing atlas, HarfBuzz
shapeRun and gl.zig render proportional shaped text with cluster-exact
hit testing unchanged; the productionized stack adds FontBook font
itemization (script/coverage run splitting with per-fallback-face
hb_fonts), bidi-aware line layout with grapheme cluster maps, soft wrap
and revision/generation caching, and EditorPass on the CellPass
template (selections, carets, gutter). smoke-editor renders the whole
pipeline offscreen with round-trip asserts.

The GTK-free document core (src/editor/) is an AVL rope with line
index, revisioned atomic multi-edit transactions, undo grouping with
word-boundary breaks, first-class multi-selection with edit mapping,
and UAX #29 grapheme plus word boundaries, fuzz-tested against a naive
oracle and registered in both test roots.

EditorView hosts document tabs on the new shared TabHost (the browser's
inner-tab notebook mechanics extracted and adopted by both consumers),
one GL canvas for the active document, IME-based input, multi-caret
editing, clipboard, mouse selection, undo/redo, and daemon-backed
open/save: reads remember mtime_ns, saves go through the daemon's new
atomic install op (fsync-staged rename preserving mode/owner) with an
expected-mtime conflict guard surfaced as Overwrite/Reload/Cancel.
Layouts persist open editor files per pane; new-editor-tab rides the
CLI/IPC surface and smoke-e2e types into a real editor and asserts the
saved bytes.

The native file picker presents a constrained paneless BrowserView
(activation/selection funnels, visibility filter, file-ops suppressed)
in a modal Viewer-styled window: modes for open/multi/dir/save/
destination, glob filters, overwrite confirmation, remote hosts via the
usual host connections. The prefs font chooser is the first consumer.
`sketerm portal` exposes the same picker to any portal-using app as an
opt-in org.freedesktop.impl.portal.FileChooser backend (OpenFile/
SaveFile/SaveFiles plus Request.Close, file:// results, packaging files
and docs/portal.md; nothing enabled without portals.conf).

Verified: full suite 1253 pass / 6 skip; core suite 1044 pass / 5 skip;
mux-portable still builds and sketerm-mux links only libc/libm;
smoke-editor, spike-editor-text, smoke-fs (atomic save, monolith and
broker), smoke-gl-core and xvfb smoke-e2e (with the new editor stage)
all green; portal driven end to end over an isolated session bus.

## Sketerm Editor as its own application

`sketerm edit [files...]` is the fourth application identity, built on
the same three precedents as the others: a GTK-free invocation module
(`src/editor_app.zig`, mirroring `viewer.zig` and
`filebrowser/entry.zig`), a `Mode` in main.zig that suffixes the
GApplication id (`dev.sker.sketerm.editor`) and the program name, and a
`sketerm-editor` alias of the same executable so taskbars cannot merge
it with the terminal. Desktop entry, app icon and packaging follow the
Files/Viewer shape; the entry declares a text MimeType set so it can be
the session's default text editor.

The window (`src/ui/editorwin.zig`) is composition, not a second
editor: it hosts a PANELESS `EditorView` through the new
`EditorView.attachStandalone`, exactly as `ui/picker.zig` hosts a
paneless BrowserView. `EditorView.pane` was already optional, so the
view needed only a config pointer to read settings from with no Window
in the tree, a handle on its own toolbar (the header bar carries
Open/Save/Save As instead), a change hook for the window title, and
`gotoLineCol` for `--line N[:col]`. The status line stays the view's
own footer. Unsaved buffers veto the close with Cancel / Discard /
Save All, and Save All waits (bounded) for the async saves before the
window goes.

`--here` / `--tab` are pure IPC into a running terminal, like
`sketerm files`: `--tab` reuses `new-editor-tab`, `--here` is the new
`editor-here` verb (explicit pane address required, same rule as
`browser-here`). The browser's context menu grew "Edit in a Sketerm
Editor Window" next to the in-pane item, spawning the sibling binary
through the new `src/ui/siblingapp.zig` — the Viewer's cross-identity
spawn generalized.

## Editor: external-modification detection, reload UX, undo selections

An open document now notices when its file changes underneath it.

**Detection is a batched stat poll, not a daemon directory watch.**
`EditorView.checkDisk` groups every open document by HOST, and each
host gets ONE detached-thread job that opens ONE connection and stats
every one of that host's documents through it (`ProbeJob`), delivered
back with `g_idle_add` like the existing load/save jobs. The rejected
alternative was `fs_op open_view`: it is DIRECTORY-scoped (opening one
file in a large tree would cost a full stat-per-entry listing of its
siblings), it needs a persistent connection parked on the GLib loop
(which for a remote host cannot be established without a worker
thread), its inotify backend is Linux-only — so a remote macOS/BSD
host would behave differently, breaking "remote works identically" —
and its mask deliberately omits `IN_MODIFY`, so a writer holding the
fd open produces nothing until close and a stat backstop is needed
anyway. Batching per host is strictly stronger than the required
per-(host, dir) dedupe: twenty tabs are one round trip whether they
share a directory or not. Triggers are canvas focus-in, pane/IPC
focus, tab switch and a click into the canvas, rate-limited to one
probe per 400 ms with never more than one in flight. There is no
before-save probe on purpose: the save is an mtime-guarded daemon-side
install, which is race-free in a way no client poll can be.

**The predicate is pure and shared** (`src/editor/reload.zig`,
GTK-free, in both test roots): `(present, mtime_ns/ms, size, ino,
mode)` in, `unchanged | modified | replaced | permissions | deleted |
reappeared` out. `ino` is what catches the atomic writer (temp +
rename): the replacement's mtime can legitimately be OLDER than the
baseline. Symlinked documents are followed — the daemon's `stat` is an
LSTAT, so a dotfile symlink would otherwise report an identity that
never moves; `fsdrive.Fs.statFollow` resolves up to 8 hops. A probe
that could not be TAKEN (dead link) is discarded, never reported as a
deletion.

**UX.** A clean buffer reloads silently, keeping caret, selections and
scroll anchor (clamped into the new text), with a status-line note. A
dirty buffer raises a non-modal inline banner above the canvas —
Reload / Save Anyway / Dismiss — never a dialog, because it fires
while the user is typing. A deleted file raises the same banner with
Save (recreate); the buffer keeps its content and the absent baseline
drops the save guard. Dismiss silences only THAT on-disk state. A
permission-only change re-baselines silently. The old modal save
conflict dialog is GONE: a refused save raises the SAME banner with
"Save refused" wording, so a refusal and an observed change can never
produce two competing prompts.

**Undo selections are mapped, not clamped.** `Document.undo`/`redo`
now return a `Change` carrying the edits they applied (borrowed from
the consumed history entry, valid until the next mutation) plus the
selection recorded before the undone transaction
(`applyTransactionSel`, coalesced typing keeps the group's FIRST
snapshot). `view_model.undo` restores that selection when present and
otherwise maps the live selections through the inverse edits.

Covered by unit tests in both roots (predicate, clamping, undo
mapping), a new `smoke-fs` stage (`probeStage`, monolith AND broker)
that walks a real daemon through atomic rewrite / in-place rewrite /
chmod / symlink / delete / recreate, and a `smoke-e2e` stage asserting
the clean-buffer auto-reload after an external `rename()` over the
open file.

## Shared IM host: one input-method path, configurable strategy

**The bug.** On any Wayland display advertising
`zwp_text_input_manager_v3`, GTK resolves a `GtkIMMulticontext` to its
`wayland` module — which derives from `GtkIMContext`, not
`GtkIMContextSimple`, carries no compose engine, and only commits
`gdk_keyval_to_unicode(keyval)` (0 for every dead keysym). The editor
canvas and the forwarded-app host IM were both unconditional
multicontexts, so `^`+`e` produced `e` there while the terminal (a
`GtkIMContextSimple`) composed `ê` correctly. The editor's original
verification was a false green: it ran under Xvfb, where a
multicontext falls back to Simple. GtkGraphicsOffload, blamed in an
earlier comment, has nothing to do with it.

**`src/ui/imhost.zig`** is now the single implementation: create the
context, `set_client_widget`, connect commit + all three preedit
signals, install on the `GtkEventControllerKey`, `focusIn`/`focusOut`
for the owner's focus controller to call, a DEBOUNCED
`setCursorLocation`, and an idempotent `detach()` that must run while
the client widget is still alive. It owns the
`get_preedit_string`/`g_free`/`pango_attr_list_unref` dance once and
hands consumers a borrowed slice plus a CHARACTER cursor.

**`input_method = auto | simple | multi`** picks the strategy. There is
no value that gives both dead keys and CJK input methods, so the key
documents the trade. `auto` resolves to `multi` only where the session
declares an input method (`$GTK_IM_MODULE` / the `gtk-im-module`
GtkSettings property naming something other than none/simple).
Deliberate asymmetry: the TERMINAL always resolves to `simple` under
`auto` (its dead-key behaviour is load-bearing), while the editor and
the app-host IM follow the heuristic. Explicit values override every
face.

**Behaviour gained.** The terminal connects `preedit-start`/`-end` for
the first time (a cancelled composition no longer leaves stale text);
the editor gains the cursor-location debounce (that call can be a
D-Bus round trip); the forwarded-app host gains `focus_in`/`focus_out`
and composes dead keys itself instead of depending on the host
compositor's IME.

**Testable forever.** `sketerm cli im-probe <hwcodes>` feeds hardware
keycodes through the FOCUSED face's IM (`gtk_im_context_filter_key`,
the way `GtkEventControllerKey` does) and reports what it committed —
`send-text`/`send-keys` bypass the IM entirely, so this was previously
unmeasurable without a human at a keyboard. Verified inside a sketerm
display session (`sketerm-mux display create --kb-layout be`, which is
a real text-input-v3 Wayland display), NOT under Xvfb.

### Testing moved off X entirely

`smoke-e2e` no longer needs a display server: it creates its own
session (`sketerm-mux display create --json`, environment used
verbatim), attaches a viewer BEFORE starting the GUI (the compositor
brain is client-side, so an unattended hub never configures the
toplevel and nothing paints), drives the real seat, and tears session
and daemon down by exact pid/name on every exit path.

This was a correctness fix, not housekeeping. The old harness forced
`GDK_BACKEND=x11` whenever `DISPLAY` was set, so the whole suite ran on
X whenever Xvfb was present -- and on X a `GtkIMMulticontext` falls
back to `GtkIMContextSimple`, which is exactly why the editor's IME
verification passed while dead keys were broken on every Wayland
compositor advertising text-input-v3. The suite also never checked that
the GUI painted at all, since IPC `send-text` bypasses input and the
daemon holds the screen state.

New coverage: real pointer and evdev-keycode input reaching the shell
with an asserted repaint; a real Ctrl+F opening the editor search bar;
the existence of a `zwp_text_input_v3` object on the seat (impossible
under X11), with a comptime guard so the compositor cannot silently
stop advertising it; and dead-key composition end to end on a
`--kb-layout be` session, asserted in both a terminal pane and an
editor tab. The GUI children run with `GTK_A11Y=none` so a dev box's
real accessibility bus is never touched.

### IM teardown: the IM held the last widget reference

GTK's Wayland IM module `g_set_object`s its client widget, so the IM
owned the LAST reference to the `GtkGLArea`. The widget's `::destroy`
-- the hook used to sever the IM in time -- could not fire until the IM
let go, and `set_client_widget(NULL)` then finalized the widget mid-call
and walked its own dangling pointer. No ordering rule could fix that,
so `ImHost` now holds a strong reference for its whole lifetime and
releases it last; every detach path is valid at any time.

Found alongside it: `Window.unlistPane` severed the IM, browser and
app-host faces but never the editor face, so the editor was only
severed from the deferred `Pane.deinit`. The four hand-copied detach
lists are now one `Pane.severFaces`, and `editor_prepare_destroy` takes
a `widgets_dead` flag so the compiler forces each caller to state
whether the widgets are still alive.

## Editor: bracket matching, code folding, structural selection

Three structure-aware features on the GPU editor, all reading the
tree-sitter trees `editor/syntax.zig` already keeps incrementally.
There is no second parser and no hand-rolled brace scanner on the
primary path; the query machinery grew inside `syntax.zig`
(`bracketAt`, `expandRange`, `foldRegionAtLine`, `foldRegionEnclosing`,
`foldRegionsIn`) and the plain-data half lives in a new GTK-free,
tree-sitter-free `editor/structure.zig`.

**Bracket matching.** The pair around or adjacent to each caret is
boxed, and Ctrl+M jumps to the match (Ctrl+Shift+M extends). The tree
is the primary source and its "no pair" answer is FINAL, which is what
makes a bracket inside a string or a comment not match: in the tree a
literal is one token, so a bracket byte inside it is not a leaf of its
own. The depth-counting scanner in `structure.zig` is consulted only
when there is no tree at all (no grammar, or `editor_syntax = false`)
and is documented as unable to see strings or comments.

**Code folding.** Gutter fold column with clickable chevrons, a `...`
badge on a folded header, Ctrl+Shift+[ / ] at the caret and
Ctrl+Alt+[ / ] for all. Regions come from the tree (any node spanning
at least two lines, NARROWEST per header so a grammar's whole-file
container cannot fold the document from line 0) and from indentation
for files with no grammar.

A fold is anchored to the BYTE OFFSET of its header's first content
byte, mapped through every transaction with `transaction.mapOffset` —
the same machinery selections use, so undo and redo are free — and then
RE-RESOLVED against the tree. That is what makes "delete the closing
brace" unfold rather than hide the wrong lines, and it needed a second
pre-edit observer slot on `Document` (the highlighter owns the first).

Folding does NOT reintroduce an absolute `scroll_y`. A hidden line
weighs zero rows in the Fenwick `RowIndex`, so the anchor, the
scrollbar and every row conversion stay fold-correct with no second
code path; the index is now allocated whenever folds exist, even with
soft wrap off. Folding a region containing carets pulls them to the
header; a caret moving INTO hidden text (Right off a header, a find
match, goto-line) unfolds instead.

**Structural selection.** Shift+Alt+Right grows every selection to its
smallest strictly-enclosing syntax node; Shift+Alt+Left pops a recorded
stack rather than re-deriving a smaller node, because with several
carets those are not the same set. Any non-structural move or edit
drops the stack.

Config: `editor_bracket_match`, `editor_folding`,
`editor_fold_indent_fallback` (all app level, like the other editor
view flags), with prefs switches. Caches are keyed on
`(doc.revision, highlighter.gen)` plus whatever else the answer depends
on — the caret hash for brackets, the visible line range and fold epoch
for gutter markers — so nothing runs a whole-document tree query per
frame.

## Portal FileChooser: filters, parents, and honest refusals

The opt-in `sketerm portal` backend grew the pieces its first cut
deliberately skipped, all of them driven for real over an isolated
`dbus-run-session` bus with a small GDBus client and screenshotted on
sketerm's own compositor.

**Filters.** `fpicker.Filter` now carries `mimes` alongside its glob
patterns, so portal type-1 entries are honoured instead of dropped
(and a mimetype-only filter is no longer thrown away). The mime of a
listed name comes from GIO's guess on the NAME -- never file content,
since the row may live on another host and the GUI never touches the
disk -- with `g_content_type_is_a` as a second chance so a `text/plain`
filter still takes `text/x-zig`. `current_filter` selects the entry on
open (one the caller did not list is appended rather than ignored),
and the filter the user accepted under is echoed back in the results
as the caller's OWN variant, which is why `mapFilters` reports source
indices.

**The filter governs typed names -- in portal mode only.** An app that
asked for `*.png` must not be handed `notes.txt` because someone typed
it, so `enforce_filter` refuses that in the dialog (status line + error
entry). The plain picker keeps GTK's rule, where the filter is about
the listing; "All files" is always in the dropdown, so the strict rule
is a confirmation step and never a dead end.

**Refusals are stated, not silent.** A pick on a remote host raises
"File is on another host" and leaves the dialog open (`local_only`),
instead of being dropped on the way out and answering the app with a
generic failure. Materialising remote files locally remains an open
design question, not a gap to fill in passing. A typed save path whose
parent directory does not exist costs one extra daemon `stat` and a
refusal, rather than succeeding here and failing later inside the
consumer's write; no directory is ever created implicitly.

**Parent windows.** `parent_window` is imported at realize:
`gdk_wayland_toplevel_set_transient_for_exported` on Wayland, and on
X11 `XSetTransientForHint` on the raw XIDs, because GTK4 dropped
GTK3's foreign windows and offers nothing else. Both backends are
reached through `dlsym` (libX11 through `dlopen`, only when an `x11:`
handle actually arrives), so a GTK built without a backend degrades to
an unparented dialog instead of a binary that will not link.

Also: a frontend that vanishes from the bus mid-call now takes its
dialog with it, and `choices` defaults are echoed in the results even
though the widgets are not drawn yet.

## LSP: the editor speaks Language Server Protocol

The editor is a language-server client. Everything protocol-shaped
lives in `src/lsp/` and is GTK-free (both test roots); the only GTK is
`src/ui/editorlsp.zig`. `docs/lsp.md` is the reference.

**Transport.** JSON-RPC over the server's stdio with Content-Length
framing. `src/lsp/proc.zig` forks with three non-blocking pipes;
stdout is watched with `g_unix_fd_add` exactly like the mux socket,
stdin gets a `G_IO_OUT` watch only while a write comes up short, and
stderr is drained (a server whose stderr fills stops serving). No
worker thread, no blocking read — the GUI is single-threaded.
`session.zig` itself never touches an fd: bytes in through `feed`,
bytes out into `out`, which is what lets the whole lifecycle be
unit-tested against a scripted in-process server.

**Remote is a documented follow-up, not a gap left open.** A server
must run near the files, so a remote document needs the daemon to spawn
it and tunnel its stdio over the existing byte channels. `attachTab`
therefore REFUSES a host-qualified spec outright rather than resolving
imports against the wrong filesystem; only `pumpWrite`/`onReadable`
know the transport is a local pipe.

**Positions.** LSP `character` is UTF-16 code units by default — an
emoji is 4 bytes, 1 codepoint, 2 characters. `position.zig` converts
both ways for utf-8/16/32, clamps past-the-line positions and resolves
a `character` inside a surrogate pair to the codepoint start. We
advertise both encodings and honour the server's choice. The tests
round-trip every codepoint boundary of a mixed-script document in all
three encodings.

**Sync.** didChange ranges are captured in `Document`'s THIRD observer
slot (pre-edit, like the highlighter's) and queued DESCENDING by
offset, which reproduces the document's own back-to-front application
so no range needs adjusting for its predecessors. Debounced 250 ms,
always flushed before a feature request.

**Staleness.** Every request carries its document revision; a stale
completion/hover/formatting answer is dropped. Diagnostics are the
exception: they are converted once to byte offsets and then carried
through edits by `mapThrough`, the same primitive selections and fold
anchors use.

**Features.** Diagnostics (squiggles through the existing per-cluster
decoration path plus a gutter stripe inside the existing gutter width,
so publishing never shifts the text), F8 navigation, Ctrl+Space
completion with lazy `completionItem/resolve`, Ctrl+I hover, the F12
family, Ctrl+Shift+O / Ctrl+T symbols, F2 rename and Ctrl+Shift+I
formatting. One popup widget serves completion, results and symbols;
it does not take focus, so the editor's own key handler drives it and
typing keeps flowing into the document. Rename and formatting each fold
into ONE transaction per document. Results open through the ordinary
tab machinery.

**Config.** App-level `[lsp.<name>]` sections (command, args,
languages, root markers, init_options, enabled) seeded from the
built-ins for zls / clangd / rust-analyzer, plus `editor_lsp`,
`editor_lsp_diagnostics` and `editor_lsp_debounce_ms`. Resolution picks
the first server that both claims the language AND is installed. The
Editor prefs page carries all of it and reports whether each command is
on PATH. A missing server is silent — visible only where the user asked
for a feature.

**Verification.** `sketerm-lsp-stub` is a REAL scripted server process:
`zig build smoke-editor` drives diagnostics, incremental sync, hover,
definition, references, symbols, completion+resolve, rename and
formatting through it over real pipes, twice, once per position
encoding. Because the stub rebuilds its own copy of the document from
the contentChanges it receives, an off-by-one range fails the run.
`zig build smoke-lsp-gui` then drives the REAL editor GUI on sketerm's
own compositor against `typescript-language-server` when it is
installed (the stub otherwise), asserting the diagnostic stripe renders
and that the hover and completion popups actually open, with
screenshots in `zig-out/`.

## Git awareness in the file browser

**One path for local and remote.** The browser's version-control
overlay used to run `git status` through `popen` on a GUI-side worker
thread for local roots, and paint badges only when `tab.hc.host ==
null` -- so a remote repository silently showed nothing even though the
daemon's `git_status` job was already being submitted for it. Both
kinds of root now submit that same job to the daemon that owns the
files, and the GUI runs no git of its own. An ssh host renders exactly
what a local one does.

**The decisions moved out of the widgets.** `filebrowser/gitstatus.zig`
owns the porcelain character mapping, the precedence ladder
(`conflicted > deleted > renamed > modified > typechange > added >
untracked > ignored`), the ancestor rollup, the badge/CSS choice, the
status summary and the refresh cache -- GTK-free, so both test roots
cover it.

**Visual language.** A row that a record names carries the porcelain
LETTER in a libadwaita status class (`success` for added/untracked,
`warning` for modified, `error` for deleted/conflicted, `accent` for
renamed), so both themes stay readable without a hardcoded hex. A
directory whose badge came from something BELOW it gets a neutral `*`
instead, in the rolled-up colour, so it can never be misread as a
changed file. Ignored entries get no chip at all -- just a faded name,
which is informative without competing with real changes. Icons view
puts the same chip on a shrink-wrapped `GtkOverlay` over the tile icon:
no extra row, no ragged grid, tile widths unchanged.

**Rollup and cost.** One record folds into its exact path plus every
ancestor segment, so a directory row is a single hash probe and no
extra job is ever issued per row. Ignored never propagates upward: a
directory of build output would otherwise wear a permanent badge, which
is the opposite of what the ignore rule asked for. The daemon caps the
record stream at 4096; the fold is capped at 20000 entries.

**Refresh policy.** Navigation, tab switch, explicit reload, host
connect, and the watch deltas that a completed file operation produces
(750 ms trailing debounce) -- never a poll. A 30 s per-(host, root)
recency cache suppresses repeated asks for the SAME root; a different
root always re-asks, because the overlay is per view and would
otherwise be empty.

**What `git_status` does not give a browser.** `runGitStatus` in
`src/mux/fsjob.zig` runs `git status --porcelain --no-renames -z` and
emits one collapsed status CHARACTER per record. So: renames arrive as
a separate delete + add (`--no-renames`), ignored files never arrive at
all (no `--ignored`), staged-vs-unstaged is lost (the X/Y pair is
collapsed to one char), `AA`/`DD` conflicts are reported as plain
add/delete, and there is no branch name, no ahead/behind, and no way to
tell a clean repository from a directory that is not in one (both
answer `done` with zero records). The browser therefore shows the
change summary it can compute and no branch. Widening that is a daemon
change, not a browser one.

## Version-control decoration, part 2: the daemon actually answers

The previous entry ended by listing what `git_status` could not tell a
browser. All of it is now on the wire.

**The verb.** `runGitStatus` runs `git status --porcelain=v2 --branch
--ignored -z` and scans it with `gitstatus.Scanner` -- the SAME parser
the browser folds records with, so producer and consumer cannot drift
(`src/filebrowser/gitstatus.zig`, GTK-free, in both test roots). Per
record it emits `path` + `text` (the pre-v2 collapsed character,
byte-identical to what the old verb produced) + `xy` (both porcelain
columns) + `orig` (rename/copy source) + `kind:"submodule"`. After the
records comes one `repo` event: `repo` (is this a repository at all),
`branch`, `upstream`, `ahead`/`behind`, `detached`, `initial`, `root`
(the browsed dir IS the repo root) and `truncated`.

**Skew, both directions.** No FrameType or EventTag byte changed; the
whole enrichment is JSON fields on the existing `fs_job` frame, and
every parser on the path uses `ignore_unknown_fields`. A NEW browser
against an OLD daemon sees no `repo` event -- which is exactly the
signal it keys on (`Repo.known`), so it keeps the old branch-less
phrasing instead of claiming "not a repository", and renders the
collapsed `text` character as the single letter it always did. An OLD
browser against a NEW daemon reads `path`+`text` and ignores the rest;
the only difference in that stream is that a rename now arrives as one
`R` record instead of a delete plus an add, and ignored entries arrive
as `!` -- both of which the old `fromChar` already maps. Verified for
real over `ssh localhost`, where the installed daemon predates this
work.

**`--ignored` is unconditional, and that is affordable.** Its default
`traditional` mode collapses a wholly ignored DIRECTORY into ONE
record, so the record count tracks the number of ignore rules that
match, not the tree they hide. Measured on a synthetic 50k-tracked /
50k-ignored-file repository: 0.08s and 92 records without `--ignored`,
0.11s and 293 with (200 individually-ignored files plus one collapsed
`build/`). The pathological shape -- 20k files ignored one by one --
costs 0.13s and 412 KB, which the caps absorb: 4096 CHANGE records,
8192 total, ignored emitted in a SECOND pass so truncation always
sacrifices ignored decoration before a real change. The read cap rose
to 1 MiB and a mid-record cut is trimmed to the last NUL and reported
as `truncated`.

**What the browser now shows.** The chip prints git's own column pair
for a row a record named -- `M.` staged, `.M` unstaged, `MM` both,
`??`, `UU`/`AA` for conflicts, `R.` for a rename -- with a tooltip that
spells it out in words and names the rename source. Ignored entries
fade (they arrive now, so that path stopped being dead code). The
status line gained the branch: `, on main +2 -1, 3 modified`, `,
detached at 2b4d84f8, 1 modified`, `, on main (no commits yet)`, and --
the case that used to be invisible -- `, clean` for a clean repository,
`, no changes here` below its root, and nothing at all outside a
repository.

**Two staleness holes closed.** A clean repository used to make the
whole summary disappear, indistinguishable from a non-repo; it now says
so. And a change DEEPER than the watched views raises no delta at all,
so `gitstat.ensurePoll` re-polls a repository root on a timer paced at
40x the last job's measured cost (20s floor, 5min ceiling), skipping a
face that is not mapped. Focus is deliberately NOT part of that gate: a
wrong badge in a visible unfocused window is still wrong, and window
activation is not a state the GUI can rely on resolving.

## Cross-connection window parenting: xdg-foreign that reaches the GUI

xdg-foreign already worked at the protocol level -- one client of a
session exported a toplevel, another imported the handle, and
`sketerm portal` stopped hearing "Server is missing xdg_foreign
support". What it did NOT do was reach the window: the relation was
recorded in compositor state and the view was told only when both ends
happened to be the same client connection. The portal case is by
construction two connections, so the dialog opened as an unparented
taskbar window.

**The identity problem.** `View.toplevel_parent` carries a surface id,
and surface ids are per-connection: a compositor cannot name a surface
owned by another connection. Three answers were considered. Minting a
new session-wide window id was rejected -- a fresh id space needs an
owner, a lifetime and a reconnect story, all of which already exist
somewhere else. Keying on the xdg-foreign HANDLE was rejected for a
sharper reason: a replica re-parsing `export_toplevel` mints its own
handle from its own entropy, so the handle an app then imports never
resolves on the viewer side; handles are brain-private by
construction. What shipped reuses what both ends already agree on --
the app channel's id. `Compositor.conn_id` is set to `Channel.id`, so
`(conn_id, surface)` names a window session-wide with no new id space,
no new lifetime, and no new failure mode: the channel closing IS the
window going away.

**Daemon-authoritative, like the icons.** The brain resolves the
import and fires `View.toplevel_foreign_parent(child, conn, parent)`;
the daemon turns that into a `foreign_parent` pipe unit toward the
viewer (child sid, parent connection id, parent sid), injected exactly
like `toplevel_icon` and replayed on reattach from
`Native.foreign_parents`. The GUI latches it per surface and resolves
the connection half through `Terminal` -- every app channel of a
session rides one mux connection, so the sibling `AppHost` is always
one list walk away -- then applies `gtk_window_set_transient_for`.
Windows race in both directions (a dialog sets its parent before
either window has painted), so both sides sweep: a new window rebinds
children latched onto it, and a dying one releases them.

**One mechanism, not two.** `importedSetParentOf` no longer writes
`Surface.tl_parent` for a same-connection import. `tl_parent` is
`xdg_toplevel.set_parent` and nothing else; every foreign relation,
local or cross-connection, now travels the same path. The GUI resolves
an effective parent per surface with the foreign latch outranking the
local one, so a client that sends both gets the one it meant.

**Modality, because nothing else could express it.** xdg-shell has no
modality request at all -- `xdg_wm_dialog_v1` is it, and GTK4 binds it
for every `gtk_window_set_modal` dialog. Withholding it does not make a
dialog non-modal, it makes modality unannounceable, so it is now
advertised: `set_modal`/`unset_modal` land as `View.toplevel_modal` and
become `gtk_window_set_modal` on the host window.

**Skew, both directions.** The bind latches `used_dialog` and raises
`Session.native_state_min` to 11, so a v10 viewer stops receiving a
session's app channels the moment an app binds xdg-dialog rather than
dying on an interface its tables do not contain -- the same gate
xdg-foreign got at v10 and dmabuf feedback at v8. State-sync v11 adds
`Surface.modal` plus the live dialog objects and downgrades cleanly to
v10 (one byte per surface and one table count shorter). In the other
direction a new viewer against an old daemon simply never receives a
`foreign_parent` unit and behaves as before; and an old viewer that
does receive one skips the unknown tag, because pipe tags are
append-only and unknown ones skip cleanly.

**Proven end to end, not merely handshaken.** A GTK4 exporter and a
separate GTK4 importer process (real GDK: `export_handle` /
`set_transient_for_exported`, the portal's own code path) ran as one
forwarded app session inside a sketerm GUI, which itself rendered into
a sketerm display session. The daemon log shows the app session
resolving `chan=4 surface=34 <- chan=1 surface=34`, and then the GUI's
OWN connection to the outer display emitting
`set_parent surface=91 parent=82` and `set_modal surface=91
modal=true` -- i.e. a real transient-for and a real modal on the host
windows, not just protocol bookkeeping. Killing the exporter produced
the clear on both layers (`<- chan=0 surface=0`, then
`set_parent parent=0`), leaving no stuck modal. A brand-new GUI
process handed the already-parented session rebuilt both from the
reattach replay alone. `set_parent`/`set_modal`/`xdg-foreign parent`
are now `SKETERM_MUX_LOG=debug` lines for exactly this reason: window
parenting is the one relation with no visible trace when it silently
fails.

---

# The editor's project layer (roadmap phase 7)

The editor stops being a file editor and becomes a project editor:
root discovery, project-wide search and replace, a symbol outline, a
per-line VCS gutter, and a session that survives a restart. All of it
works for REMOTE documents, because all of it is a job the daemon runs
on the file's own host -- the GUI still never touches a disk and never
runs a process. `docs/project.md` is the reference; this is the
argument.

**The model is one paragraph, and the interesting half is what it
refuses.** A project is a `(host, root)` pair found by walking up to
the nearest ancestor holding a marker, reusing `lsp/servers.zig`'s
`findRoot` machinery rather than a second discovery scheme. Two
differences: the marker list is a superset (every VCS directory plus
the language markers the built-in servers already name), and a MISS
answers `null` instead of falling back to the document's directory. So
a loose file has NO project and every project-scoped feature is off for
it -- no jobs started, no panels changed, nothing resolved. That is
what keeps opening one file exactly as cheap as it was. A face holds a
refcounted `project.Set`, so a window showing three repositories has
three projects; each TAB has at most one, and anything needing a single
root uses the ACTIVE tab's. The LSP root stays separate on purpose: a
server's workspace is narrower and server-specific (clangd wants the
directory with `compile_commands.json`), so the project is the user's
unit and the LSP root is the server's, and `Project.lspRootHint` exists
only so a UI can say which is which.

**grep and the editor's regex engine are different engines, so only one
of them decides anything.** The daemon's grep is a case-insensitive
literal substring scan with per-file and per-line caps; the find bar is
literal-or-regex with match-case and whole-word. Pretending they agree
would make replace unsafe. So grep chooses which FILES to read and
nothing else: every hit shown and every byte written comes from running
`editor/search.zig` over the file's real content, which is why a
project search means precisely what the same query means in the open
buffer. `psearch.literalSeed` extracts the literal every match must
contain (conservative: depth-zero runs only, a run loses its last
character to a following `?`/`*`/`{`, any alternation disqualifies the
pattern) and hands THAT to grep; with no seed the `find` verb
enumerates instead, bounded by `editor_project_search_max_files`. The
divergence that remains is the daemon's own caps hiding a candidate
FILE, and that is reported as truncated, not swallowed. Replace is
previewed (per file, the full rewritten content plus its mtime), then
applied: an open buffer through its Document as ONE transaction and
then saved, everything else through the same atomic install an ordinary
Ctrl+S uses, so a file that changed since the preview is REFUSED.

**The gutter needed a verb that does not exist, and the workaround is
named rather than hidden.** `git_status` reports per-FILE letters with
no line information; `diff` diffs two files that both exist. Neither
can materialize a committed blob. So the editor asks the `panelize`
verb -- a host-side `/bin/sh -lc` -- to run `git diff -U0 HEAD -- <rel>`
into a temp file and reads that back through the ordinary `read` verb.
It runs on the file's own host, so a remote document gets a remote
gutter, and the GUI still runs nothing. A dedicated `git_diff` job verb
would remove the temp-file dance; it is a tidiness win, not a
correctness one, which is why it was reported and not done. Marks are
BYTE ANCHORS carried through every edit by `transaction.mapOffset` --
through the same single ETab observer folds already used, which now
carries the gutter and the outline too -- so a refresh in flight never
fights the typing that continues during it. Known limitation, written
down rather than discovered later: the gutter compares HEAD against the
file ON DISK, so it refreshes on load, on save and on tab activation,
not on every keystroke.

**The outline has two sources and no third.** LSP `documentSymbol`
where a server answers, the tree-sitter tree where none does, tree
first so the panel is never blank while a request is in flight. Rows
are rebuilt only when a hash of names, kinds and depths changes -- not
of ranges -- so typing inside a function moves the ranges (mapped
through the edit) and not the list, and caret tracking only moves the
selection. Ctrl+Shift+O took the chord from the transient
document-symbol popup, which was a strictly worse version of the same
thing; the popup path now serves workspace symbols only.

**Restore vs recover has a rule, and it is one sentence.** The layout
decides WHICH files are open; the crash journal decides their CONTENT.
Recovery runs from `attach`, before the restore opens anything, so a
recovered buffer already occupies its spec's tab and `openSpec`'s
dedupe makes the restore focus it -- and `recoverOne` now ADOPTS an
existing tab for its spec rather than opening a second one, so the two
cannot duplicate whichever order they run in. `PaneSpec.editor` gained
`top_line` (a LINE, because the editor's wrapped-row anchor is
meaningless in a pane of a different width) and `project`; both default,
so an old layout file restores.

**Verification.** `zig build test` (1530 tests), `test-core`,
`mux-portable` with `ldd` showing libc/libm only, and `smoke-editor`
with a new stage covering diff parsing, anchored marks through an edit,
hunk navigation, the gutter actually painting all three mark kinds,
the tree outline with caret tracking, and the search/replace model.
`smoke-e2e` gained the real thing: a scratch git repository, the gutter
painting after a save, F7 landing on the hunk (proved by typing a
marker and reading the document back), Ctrl+Shift+F finding a token and
a hit row opening the file it names, a previewed replace that writes
nothing until Ctrl+Enter, the same layer over `ssh localhost`, and a
second GUI started with `--restore` bringing the session back with its
active tab. `smoke-lsp-gui` proves the outline is fed by a live server
process ("2 symbol(s) -- language server"). Its completion-popup stage
fails, and a worktree at the commit before this work fails identically:
pre-existing, not a regression.

## Terminal canvas AT-SPI: selection, live notifications, and a bus of its own

The June bridge (`a11y/atspi.zig` + the neutral `a11y/view.zig`) made
the pane's GtkGLArea answer GtkAccessibleText pulls -- text, caret,
line/word ranges -- but a screen reader also needs to be TOLD when
things change, selections were reported as "none", the pane had no
label, and nothing in the tree proved any of it. This session closes
those four gaps.

**Selection is part of the snapshot now.** `view.build` maps the
grid selection to a flat character range: `.normal` end-col-exclusive
runs and `.line_select` whole-row spans (newline included), clamped
against scrollback (fully-invisible selections report none, straddling
ones clamp to text start/end). `.rectangular` deliberately stays
unexposed -- a block is not a flat range, and announcing the wrong text
is worse than announcing none. The bridge's `get_selection` vfunc
serves it as the single AT-SPI Text selection.

**Notification policy.** `notifyChanged` fires per applied event batch
(and now also from every host-side selection mutation in `pane.zig`,
which never passes through the daemon drain), but emission is
trailing-edge coalesced to one burst per 75ms -- a busy TUI redraws far
faster than speech. Each burst diffs the previous announced text
against the fresh snapshot (`view.diffChars`, common prefix/suffix
hull in codepoints) and emits text-REMOVE/INSERT for the hull,
caret-moved and selection-changed only when those actually moved. The
whole diff path is gated on `at_active`: until a real AT invokes any
vfunc, an emission is one no-op'd caret nudge and no snapshot is ever
built -- a session without a screen reader pays nothing. Lifetime: the
coalescing timer refs the widget; `Pane.severFaces` (and the area's own
`::destroy`, for paths that never reach it) cancels the timer and drops
the Terminal back-pointer before the Terminal can die. The accessible
label starts as "Terminal" and tracks OSC 0/1/2 titles.

**`zig build smoke-atspi`** is the proof, and the reason it exists is
that smoke-e2e pins `GTK_A11Y=none` (its GUI children must never
register on the developer's real a11y bus). Same self-hosted rig --
private daemon, display session, viewer attached first -- plus a
private accessibility bus from `mux/a11yhub.zig`, whose `Hub.setup`
already encodes all five independent requirements for a populated
tree. The GUI runs with `GTK_A11Y=atspi` on that bus, and the harness
asserts real `org.a11y.atspi.Text` replies via the Hub's new
`textState`/`textNSelections`/`textSelection` (libc-only, also useful
to MCP later): a TERMINAL-role node exists, typed text comes back with
the caret right after it, the caret advances by exactly the typed
count, a real pointer drag becomes exactly one multi-line selection,
and a click clears it. SKIPs cleanly where dbus-daemon/registryd are
not installed.

Not covered: the emitted change events are not themselves captured off
the bus (that needs Registry event subscription in the Zig D-Bus
client); the smoke asserts state, and the notification path is the
same code emitting it. Attributes (colors/bold) still report empty.
The macOS twin can adopt selection by reading the same snapshot
fields. Verification: 1539 tests, test-core, mux-portable (ldd:
libc/libm only), smoke-atspi PASS, smoke-e2e PASS.

## Editor: editing verbs, multi-caret ergonomics, typing behaviour, canvas context menu

The editor face grew the day-to-day editing verbs, all implemented
GTK-free in `src/editor/commands.zig` over Document + SelectionSet:
duplicate line/selection (up/down), move lines (blocks merge, edges
no-op), join, sort, toggle line comment, indent/dedent, trim trailing
whitespace, upper/lower/title case, go-to-line dialog, plus the
multi-caret makers: select next/skip/all occurrences (Ctrl+D family),
add caret above/below, split selection into line carets, and
Shift+Alt+drag block selection (byte columns, no virtual space --
documented in docs/editor-commands.md with the reasoning). Every
command is ONE transaction through applyTransactionSel, so one undo
step restores text AND selection across any caret count. Comment
toggle resolves the prefix from the document's detected language
(`Lang.lineComment`), never an extension table; JSON/Markdown report
"no line-comment syntax" on the status line; mixed selections follow
the all-commented-uncomments rule.

Typing behaviour, each with an app-level config key defaulting on and
a prefs row (Editor page, "Typing" group): `editor_auto_indent`
(Enter deepens after an opening bracket, drops a pending closer onto
its own line -- bracket adjacency only, no tree walk),
`editor_auto_close_pairs` (pair insertion with type-over, surround-
selection, backspace-pair; refuses before word chars, after word
chars for quotes, and inside grammar-declared strings/comments; multi-
caret is all-or-nothing), `editor_smart_backspace` (leading-space
retreat to the previous tab stop).

Bindings are a separate `editor_keybind.<command>` config namespace
(never consulted by the terminal, so Ctrl+D can be Ctrl+D), resolved
in syncConfig over defaults from commands.zig, editable on the prefs
Keybindings page ("Editor Commands" group), and every command appears
in the command palette (with its chord) when the focused pane wears
an editor face. `src/ui/editormenu.zig` adds the canvas right-click
menu (ui/menu.zig idiom): cut/copy/paste/select-all, the new
commands, LSP rows shown only while a server is attached, folding,
find/replace/goto-line; rows that cannot act are insensitive.

Verification: 1618 unit tests (46 new in commands.zig + config
round-trips), test-core 1385, smoke-editor, smoke-lsp-gui, smoke-e2e,
mux-portable (ldd libc/libm only) + aarch64-macos cross all green;
driven live on the mux display rig with screenshots (context menu,
Ctrl+D multi-caret, Ctrl+/ on a real Zig file, auto-close + type-over
+ wrap-closer Enter, smart backspace, Ctrl+G line:col).

## Cross-host transfers: real resume across retries, pipelined bytes, reboot-durable journals

Root-caused the "move kept retrying, then left a 6+ GB
`.sketerm-copy-47-*` orphan next to `-50-*`" report: the browser mints
a fresh daemon idempotency token per attempt, the daemon then mints a
fresh JOB, and a no-replace move's destination stage is named by the
job id -- so no retry could ever adopt the previous attempt's staged
bytes. Fixed structurally, not by widening a special case:

- Two-tier retry identity. Every cross_copy now also carries the
  ledger's stable `transfer_token` (client_token still rotates per
  attempt). `fsStartJob` restarts a FAILED matching job from its own
  journal under its own id -- same `.skpart`s, same destination stage,
  same quarantine/phase -- and adopts a still-RUNNING one instead of
  duplicating it. Old daemons ignore the unknown field and behave as
  before; old clients simply never send it.
- ALL no_replace cross copies stage (previously only moves), so an
  interrupted no-replace tree copy resumes instead of failing against
  its own partial root.
- Fs-job journals moved from the runtime dir to
  `$XDG_STATE_HOME/sketerm/fsjobs/<sock-hash>/` (`Daemon.fsJobsDirAlloc`,
  one-time copy-based migration), so staged data and move-cleanup
  state survive a reboot; created lazily so isolated test daemons
  leave no litter.
- Post-commit honesty: a move failing after the `copied` phase reports
  "the copy is complete and installed; ..." -- the destination stays
  under its final name and the retry redoes ONLY source cleanup
  (proved by inode identity in the smoke).
- Throughput: `CrossCopy.transferBytes` replaces the stop-and-wait
  chunk loop with a bounded 4-deep read/write pipeline over new
  fsdrive submit/await primitives (replies match by req nonce; blocking
  ops route pipelined frames instead of dropping them). Reconnects
  restart the window from the acknowledged contiguous prefix.
- A per-run digest cache (`hashCached`, stat-identity keyed, rebound
  across rename/utimens) collapses the move flow's four-to-six full
  re-reads of both files into one hash per side; a lost rename ACK is
  now disambiguated by claiming a destination that carries the
  verified digest (`renameDstClaimed`).

smoke-fs grew two stages: a mid-transfer SIGKILLed copy retried with a
rotated client_token must return the SAME job id and a non-zero
resumed_from; a move whose quarantine is blocked (read-only source
parent) must fail with the installed-copy message and finish via a
cleanup-only retry. Three existing kill-window stages were made
structural (watch the growing `.skpart` / add a trailing tree file)
because the digest cache shrank the windows they raced.

Verification: smoke-fs (mono + broker incl. all new stages), smoke-mux,
smoke-broker, mux-portable, `zig build`, full unit suite 1623 pass /
0 fail (test-core 1385; the build-step exit flake is the known
tesseract ObjectCache leak noise).

## Transfers UI: the two-tier redesign (ambient strip + Transfer Center)

The per-pane jobs strip was replaced with the two tiers proposed in the
transfer-UI review:

- Tier 1, the ambient strip: ONE line at the bottom of the browser face
  -- progress ring (cairo), "Copying 2 items to mercer -- file.bin",
  and percent/rate/ETA. Green summary with a clear button when
  everything finished, red with the failure sentence when something
  failed, dim while only queued. Clicking it (or Ctrl+Shift+J, or its
  Details button) toggles tier 2.
- Tier 2, the Transfer Center: header ("Transfers -- 1 active - 2
  queued - 6.1 MB/s total" + Clear finished), then one CARD per
  operation: name-first head line (destination as host:parent/, host
  prefix stripped), right-aligned mono stats ("434 / 700 MB - 6.0 MB/s
  - 2:41 left"), a custom-drawn byte bar whose RESUMED prefix renders
  dimmer, a "resumed at N MB" chip, the in-flight file line, and an
  area-filled sparkline. Failed cards get a red edge and the full
  failure sentence, selectable. Cards keep their position for their
  lifetime (stable meter-order sort); full endpoints live in the
  tooltip and a right-click "Copy Source/Destination Path" menu
  (classicmenu). Batch bars blend finished members with the running
  member's byte fraction, so one big file no longer parks at 0%.

Chasing the "duplicate identical rows" complaint live (headless rig,
fake-ssh throttled through pv) surfaced three deeper defects, all
fixed:

- Restarted jobs SUMMED the dead attempt's journaled progress with the
  fresh run's counting (done reached 1.66x the file size) -- the
  progress seed now applies only when the copy step is skipped
  (resume_phase > 0). Reproduced and pinned in the retry-resume smoke
  stage (max_done <= total asserts there and in the flaky stage).
- A re-paste of endpoints an older intent still holds now ADOPTS that
  intent (same ledger token => daemon restarts the old job, staged
  data and all -- verified live: "resumed at 92.0 MB" after killing
  GUI + helper mid-transfer and pasting again), and other stale
  duplicates are retired as superseded, at materialization and again
  when the same endpoints complete.
- A restarted no_replace job whose destination already carries EXACTLY
  the source content (shape + hashes) now reports success instead of
  "destination exists" -- but only with a journaled prior attempt
  (stage/phase/progress); a fresh job still refuses, preserving the
  collision smoke's "identical bytes are not proof this job installed
  them" invariant for moves.

Known limitation: a crashed session's unclaimed recovered intent can
sit as one dormant "queued -- waiting to start" card until dispatched
or canceled; it no longer races or duplicates anything.

Verification: full suite 1626/0 (3 new jobpanel tests: strip aggregate,
failure/done lines, batch fraction hint), test-core 1386/0, smoke-fs
(mono+broker) incl. the hardened kill-window stages, mux-portable +
aarch64-macos cross, and the live rig end to end: paste -> SIGKILL
helper mid-flight -> auto-retry resumes in place -> kill GUI+helper ->
relaunch + re-paste -> adoption resumes at 92 MB -> both files land
sha256-identical.

## Inner document tabs: a shared per-tab context menu (and winapp's host menu)

The inner tab strip that the file browser and the editor share
(`src/ui/tabhost.zig`) had a menu hook for the strip's EMPTY area and
none at all for a tab. The browser carried its own right-click gesture
and its own three-row popover; right-clicking an editor document tab
did nothing.

`TabHost` now owns the per-tab menu. The mechanical rows are the same
verbs in any tabbed host, so it builds them itself — Close Tab, Close
Other Tabs, Close Tabs to the Right, Close Unmodified Tabs, Duplicate
Tab, Open in New Window — driving them through the existing `on_close`
callback and a `TabMenu` struct of optional hooks. A null hook removes
its row (the browser has no `modified` predicate, so it has no Close
Unmodified row; the editor has no `duplicate`, because opening the
same file twice is refused by design), and every predicate is asked at
POPUP time, so a row that cannot act is built insensitive rather than
present and inert. Consumers add only their domain rows through
`TabMenu.extra`: the editor's Save / Save As… / Revert / Copy Full
Path / Copy Relative Path / Reveal in File Browser, the browser's
Reopen Closed Tab. Rows are `browser/classicmenu.zig`, which grew an
`itemIconEnabled` for the insensitive case.

Keyboard parity comes from a key controller on the notebook (a tab's
label box never sees the key: GtkNotebook focuses its own per-tab
gizmo, which is the label's PARENT) that answers Menu / Shift+F10
while focus is in the strip, and `menu.returnFocusTo` is factored out
of the pane menu's focus-return so a keyboard-opened menu cannot
strand focus in a dead popover. The editor also gained the strip menu
it never had (New Document / Open File…).

`Revert` is `EditorView.revertTab`, the external-change banner's
Reload path given a name so any tab can reach it; Copy Relative Path
is insensitive when the document has no project, which is the normal
answer for a loose file (`editor/project.zig` returns null on a marker
miss). Nothing new was invented: Reveal opens a browser tab with the
file revealed (`newBrowserTabFromReveal`) or, with no window to host
one, the Sketerm Files identity — exactly what the standalone editor
window's own Reveal button does.

`winapp.zig` (the winstream backend) had no host menu at all while
`wlapp.zig` had one on Ctrl+right-click. wlapp's construction is now
shared rather than copied: `popupHostMenu` (rows + popover + deferred
unparent), `screenshotPicture` and `WindowRec` (the GIF/WebM
start/stop/save state) are public, wlapp uses them for its own menu,
and winapp answers Ctrl+right-click with Screenshot / Record (WebM) /
Record (GIF) / Close. The embedding rows stay wlapp's: a streamed
window is always a floating toplevel.

Splitter handles were left alone deliberately. A useful row there
("equalize this split") does not exist as behaviour anywhere:
`winlayout.zig`'s `PanedRatioCtx` only tracks and re-applies a ratio
across remaps and layout saves, there is no `input.Action` for
resizing or resetting a split and no palette entry, so the row would
have meant writing new window management to fill a menu.

Two GTK bugs surfaced on the way and are fixed with it: closing ANY
file-browser tab aborted GTK in `gtk_column_view_sorter_dispose` (the
tab's extra reference on the column view's sorter outlived the view,
which is what empties that sorter's sequence) and ran
`invalidateBackingRefs` after the list model it reads was gone; and a
press on a tab's very top edge popped the strip menu on top of the tab
menu (the strip's empty-area hit test picks the notebook's own tab
gizmo there), so the tab gesture now stamps the press's event time and
the strip gesture skips a press already answered.

Verification: 1624 unit tests / 6 skipped (one new: the relative-path
helper), test-core 1386/5, smoke-e2e, smoke-editor, smoke-atspi,
mux-portable (ldd: libc/libm only) and the aarch64-macos cross all
green. smoke-atspi gained a stage that drives BOTH consumers on the
real seat: the tab strip is located by clicking down a column until
the accessibility tree reports that tab selected (GTK4 on Wayland
reports every accessible rect at 0,0, so extents cannot aim a click),
the menu is then counted as its own popup SURFACE, its rows are read
off the a11y bus with their sensitivity, Copy Full Path is activated
and the clipboard checked, Shift+F10 opens the same menu, and Close
Other Tabs really closes the others. Reverting either consumer's
`tab_menu` assignment, or the strip key controller, fails exactly the
matching assertion.

## MCP app observability: measuring instead of sampling (2026-08-06)

Field feedback from an assistant driving a ported DOS-era game through
these tools reported five places where the harness cost time or led to
a wrong conclusion. All five are addressed.

**app_watch** — there was no primitive for "did anything happen in the
next N seconds". `screenshot_app` samples an instant, `app_wait` counts
frames; neither answers it. The reporter published a false bug report
off that gap: a menu row was called dead after two investigations, when
the action actually had a ~5.7s pre-roll followed by a 6s clip, so every
capture landed before or after it. `App.watchChanges` samples
continuously and returns a change timeline with inline thumbnails of the
first few change points, encoded after the run from stashed pixels so
the encode cannot perturb the sampling. Zero changes with frames still
committing is reported as a measurement; zero frames is a separate
verdict.

**app_backtrace** — a crash dumps a full report into `app_log`; a hang
gave nothing, because `gdb -p` against a daemon-hosted app returns
EPERM: Yama's default `ptrace_scope=1` only lets an ancestor trace, and
the app's ancestor is the daemon, not the caller. Both halves now live
in the daemon. `SpawnReq.debuggable` makes the forked child call
`prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY)` before exec (verified to
survive execve — which is why it cannot be granted retroactively to an
app that has already hung); appdrive sets it for every app it launches,
interactive panes never do. New `app_debug`/`app_debug_data` frames run
gdb as a daemon subprocess whose pipe is polled per tick like a file
job, so a multi-second attach never stalls the poll loop. Jobs resolve
back to their client by ID, output is capped, and a deadline SIGKILLs
the debugger so a slow attach yields a partial dump rather than nothing.

**app_hover_map** — with no accessibility tree, finding clickable things
was pure coordinate guessing (the reporter spent a long click sequence
failing to leave a room whose exit was a door drawn as background art).
The sweep moves the pointer over a grid and reports which cells repaint.
It refuses up front on an app that repaints by itself, detected with
three pointer-still control samples, rather than answering with a map of
noise, and an empty map says explicitly that "draws no hover feedback"
is not "nothing here is clickable".

**app_wait `min_frames`** no longer claims "NOT LIVE / it is not
painting (frozen...)" when the app simply paints slower than the
requested frames-per-timeout arithmetic allows. 1400 frames at 12fps
needs ~117s; against a 115s timeout that was a false alarm frequent
enough to train callers into ignoring the message, which is exactly the
wrong reflex since the identical sentence is how a real freeze
announces itself. Only zero frames makes a liveness claim now.

**PostInputWait** records the window's last commit time before the input,
so a dry wait on a window that had already been silent for seconds
reports an app-liveness warning pointing at `app_backtrace` instead of
leading with "it may have hit a dead area". In the field that ambiguity
buried the first evidence of a hang. app_click also stops auto-retrying
in that state.

Files: `src/ipc/appdrive.zig` (watchChanges, peekChangeVs, windowSize,
lastCommitMs, debugBacktrace, encodePixelsPng extracted from the window
encoder), `src/ipc/mcp.zig` + `src/ipc/mcp_app.zig` (three tools,
schemas, verdicts), `src/mux/daemon_debug.zig` (new), `src/mux/wire.zig`
(app_debug 29 / app_debug_data 93), `src/mux/daemon.zig`,
`src/mux/daemon_sessions.zig`, `src/mux/daemon_serve.zig`,
`src/pty.zig`, `src/util/platform.zig`.

Verification: full suite 1630/0, test-core 1387/0 (4 new tests),
`mux-portable` musl + `aarch64-macos` cross green, `ldd sketerm-mux`
still libc+libm only. Driven live against `sketerm mcp` with real apps
under a private daemon: app_watch timed two scripted screen changes at
t=4502ms and t=7507ms (scheduled 6s and 9s after launch) and reported
capped timelines on a continuously-animating app; app_hover_map refused
that same animating app "3 of 3 control samples changed"; app_wait
reported "about 6.5 fps ... 400 frames needs roughly 61738ms"; a
SIGSTOPped app produced "APP LIVENESS WARNING ... had ALREADY not
painted for 5512ms" from app_click and a real thread table from
app_backtrace.

Known limitation: app_hover_map only finds controls that draw hover
feedback, so an app with none yields an empty map — that is reported,
not implied. Clicking every cell would find more but is destructive, so
it is deliberately not offered.

## Editor: word wrap (UAX #14), reloads that keep undo history, exact a11y ranges

Two V1 limits a person actually feels while editing are gone. Soft
wrap no longer breaks mid-word: `src/editor/linebreak.zig` is a UAX
#14 rule engine in `unicode.zig`'s idiom (complete engine, compact
class table) covering LB7-LB31's load-bearing subset — break after
spaces/hyphens/ZWSP, never before closers/nonstarters/quotes, numeric
runs like "3.14"/"-5"/"1,234" hold together, NBSP/WJ glue — and the
CJK/kana/Hangul/emoji planes resolve to ID so ideographic text breaks
between characters and fills each row (no spaces required). The
layout's greedy wrap takes the last opportunity on the row, testing
the LOGICAL seam (byte_end for RTL flow), and falls back to the old
cluster break only when a single unbreakable token exceeds the width.
Whitespace clusters never trigger a wrap, so trailing spaces hang
past the column like every editor. Hint-shifted x positions flow into
the same overflow test, so an inlay hint moves breaks correctly.
`editor_wrap_words` (default true, prefs row) restores anywhere-wrap
— a real preference for logs/minified text, and an escape hatch for
the compact class table. Thai/Lao/Khmer classify as AL (no dictionary
breaking): long SA runs glue like Latin words until the fallback.

An external reload no longer throws away undo history.
`editor/diff.zig` diffs the disk bytes onto the LIVE document —
common prefix/suffix trim snapped to codepoint boundaries, then
line-granularity Myers, O((N+M)*D) time and O(D^2) space with N+M
capped at 50k lines and D at 512, past which the middle collapses to
one replace — and applies the hunks as ONE transaction. Undo restores
the pre-reload text (and the pre-reload carets, via the selection
snapshot), redo returns to the disk content, and the highlighter,
fold/git/outline anchors and LSP didChange all ride the ordinary
edit-observer path, so `onDocumentReplaced` and the kept-position
clamp machinery are gone from the reload. Line-ending style is
re-detected but is metadata: undo does not put a CRLF flag back.

The a11y hole ("an edit outside the caret's 32-line block goes
unannounced") now has its missing half: `Document` grew the fourth
edit-observer slot, and `docview.ChangeLog` records each
transaction's REAL remove/insert ranges (deleted-char counts taken
pre-edit, byte→char conversion deferred to `take()` so a burst with
no reader attached costs almost nothing), surfaced through
`DocSource.takeChanges`. Honesty rule: one transaction per take — a
second one marks the log stale and the consumer must fall back to the
region diff rather than compose coordinates. The final wire into
`atspi.zig`'s `emitNow` (prefer exact changes over the region diff)
is deliberately not in this change: that file was concurrently owned;
the proposed shape is an optional `changes` vtable entry the bridge
consults first.
## 2026-08-05 — feature completion pass 1: kitty keyboard, copy mode, hints

Three of the "finish what we already started" items, each verified in
`smoke-e2e` on a real seat as well as by unit tests.

**Kitty keyboard protocol conformance.** The flag stack had the wrong
shape: `CSI > flags u` SET the flags instead of pushing them (so a
program enabling the protocol destroyed its caller's flags, and the
matching `CSI < 1 u` restored zero), and `CSI = flags ; mode u` treated
modes 2/3 as push/pop rather than or/clear. Both fixed, main and alt
screens now keep separate stacks (`kitty_kbd_other_*`, swapped in
`toggleAltScreen`), and a full stack drops its oldest entry instead of
refusing the push. Encoding was rewritten around `KeyInput` +
`emitCsi`: keys with a legacy VT sequence KEEP it under report-all
(Up was being sent as `CSI 57352 u`, a Private Use Area alias only
kitty's own decoder understands — arrows were effectively dead in
report-all apps), Enter/Tab/Backspace stay control bytes under
disambiguate unless modified, the modifier set widened to
super/hyper/meta/caps/num, and the functional table gained F13-F35,
the keypad, media keys, lock keys and the modifier keys themselves.
Releases and repeats now work for every key class. Alternate keys are
real: the hardware keycode is translated back through GDK for the
unmodified and shifted key and mapped to a US PC-101 codepoint, so
Ctrl+C bindings survive a Cyrillic layout. Behaviour was checked
against the specification AND kitty's own `kitty_tests/keys.py`, which
is the only authority on the cases the prose leaves implicit (e.g. a
control-byte key has no release form, while a text key does).

**Overlay modes were losing every plain printable key.** A mode's key
sink lives in `key-pressed`, which GTK only emits for keys the input
method did not claim — and an IM claims exactly the letters that hint
labels and vi motions are made of. `w`, `y` and every hint letter was
being committed as text into the shell. `modes.imBypass` now routes a
pane's keys around its IM for the duration of hint and copy mode
(`ImHost.setEnabled`, so the context and any half-finished compose
survive). Found by the new smoke-e2e stage, not by reading.

**Copy mode** gained H/M/L, page and half-page motions, word ends
(e/E), WORD variants (W/B), `^`/`_`, paragraph `{`/`}`, `%` for the
matching bracket, f/F/t/T with `;`/`,`, and n/N to walk the search
bar's matches without leaving the mode. `grid/word_motion.zig` grew
end-motions, a blank-delimited WORD alphabet and the find primitives;
`grid/bracket.zig` is new and pure, with a row budget so one keystroke
cannot scan a whole scrollback.

**Hints are configurable.** New config keys: `hint_alphabet` (label
characters, in order — ignored unless at least two distinct printable
ASCII characters), `hint_multiple` (start in multi-select), and
`hint.<name>.regex` / `.action` / `.command` for user rules. Actions
are open/copy/paste/select/command; `{match}` in a command is replaced
with the shell-quoted match and run detached via `sh -c` in the pane's
cwd. Rules are POSIX EREs compiled once per mode entry (a pattern that
does not compile disables only its own rule) and scanned BEFORE the
built-in URL/path/hash scanners, sharing their per-row dedupe window,
so a rule can claim text a built-in would have taken. In-mode:
Shift+label forces copy, Alt+label forces paste, Tab toggles
multi-select and Enter copies everything collected.

Not covered: the prefs UI has no rows for the new hint keys (rules
need a list editor); `docs/config.md` still documents a ZON format
that never shipped and is unrelated drift.

## Automatic config reload

**config.conf is watched, and saving it applies the new settings with
no keystroke.** A `GFileMonitor` per window (`src/ui/configwatch.zig`),
debounced 200 ms, gated on the new app-level key `config_auto_reload`
(default on; the prefs Behavior page has a switch for it). Rename-over
— how editors actually save — re-arms the monitor before the reload, so
the feature does not work exactly once and then stop.

Three things make it safe to run on every save rather than on a
keybind. An automatic reload does NOT write the file back
(`ApplyOpts.persist = false`): the serialiser emits non-default keys
only, so persisting would strip the comments and ordering of the file
being edited, and would feed our own write back in forever. Every
in-app write (`persistConfig`, sliders included) stamps the file's
content hash, and an event whose content hashes the same is dropped —
that is what keeps the prefs dialog, which persists on every tick,
from bouncing off the watcher. And `Config.loadFromPath` is a new
entry point that ERRORS on an unreadable file instead of returning
defaults the way startup's `loadWithOverride` does: a reload that
raced a rename must leave the running config alone, not reset every
setting the user has.

`reload_config` / SIGUSR1 changed with it: they now honour a `--config
<path>` override (they silently reloaded the XDG file before, i.e. a
different file from the one the process was started with) and no
longer rewrite the file either. `persistConfig` writes to the override
path too.

Two dangling-pointer bugs came out of auditing `applyConfigChange`
against the current field set, both from the per-style font work:

- **`Pane.font_opts` was never re-pointed.** It holds five slices out
  of the config arena — `font_family_bold` / `_italic` /
  `_bold_italic`, plus the symbol-map list whose backing array
  `rebuildSymbolSpecs` reallocates — and only `applyPaneConfig` (a
  pane-creation path) ever set it. Every config reload freed the arena
  underneath it. Now rebuilt in the pane loop through the shared
  `fontOptsFor`, and `fontOptsDiffer` puts styled families, weights and
  `builtin_box_drawing` into the "needs a font rebuild" test they were
  missing from.
- **`rebuildSymbolSpecs` was never called at startup**, only from
  `applyConfigChange` — so a configured `symbol_map.*` did nothing at
  all until the first reload.

Covered by a smoke-e2e stage (in-place write, then a temp-file rename
over the target, asserting the grid re-flows and flows back through
`screen-info`), verified non-vacuous by disabling the watcher and
watching the stage fail.

## Feature completion pass 2: a real scrollbar, quake geometry, pane chrome

Three things that already existed halfway and now go all the way.

**The scrollback indicator became a scrollbar.** It was a display-only
strip drawn by `GridPass`; the geometry moved into a pure
`src/render/scrollbar.zig` (track + thumb rects, hit-test, thumb-top →
`view_offset`, page-toward-click), which both the render pass and
`Pane`'s pointer handlers now read — so the thumb a user grabs is
exactly the thumb they see. Ten unit tests cover the arithmetic with
no GUI, including the case that used to be wrong by construction: with
the 8 px minimum thumb clamping, position maps over `track_h -
thumb_h`, not `track_h`, or the last screenful of scrollback is
unreachable.

The wiring rule is "consult the scrollbar first, but only when the
pointer is actually over it". `onDragBegin` / `onMousePressed` /
`onMouseReleased` / `onMotion` all yield to it BEFORE the mouse-mode
branch, so the scrollbar keeps working inside tmux/vim/htop while
every other pixel of the pane still reaches the app. Config:
`scrollbar` (never/auto/always), `scrollbar_width`, and three colours.
`auto` means "once there is scrollback"; there is no timed fade.

**Quake mode got geometry** — `quake_enabled`, `quake_monitor`
(active / primary / index / connector name), `quake_edge`,
`quake_width_percent`, `quake_height_percent`, applied at window
creation, on every `--toggle` reveal, and on config reload. Full
coverage takes `gtk_window_fullscreen_on_monitor`, the one GTK4 call
that names a monitor; anything less is `gtk_window_set_default_size`.
**The edge cannot be honoured and is documented as advisory**: GTK4
removed toplevel positioning on every backend and Wayland forbids a
client placing its own toplevel, so a partial-size quake window lands
wherever the compositor puts it. `gdk_monitor_get_workarea` is gone
too — "work area" is the monitor rectangle. Recording the edge anyway
keeps it available to a compositor window rule and to a future
layer-shell backend.

**Pane presentation.** The unfocused dim was already built and already
configurable (`inactive_darken` / `inactive_desaturate`); what was
missing was everything around it. Added per profile — a red border on
a `prod` profile is the point — `pane_border_width`,
`pane_border_color_active`, `pane_border_color` (the hard-coded focus
border became these three, defaults unchanged) and
`pane_corner_radius`, plus window-level `pane_gap` / `pane_gap_color`
for the separator, since one CSS provider styles every GtkPaned and no
single profile owns the space between two panes.

The corner radius is an alpha cut in the shader footer, so it reveals
what is behind the pane rather than painting a fake corner. That means
a non-zero radius forces the offscreen post-process on for a focused,
shader-less pane — `wantsDim()` covers it — and the SDF is guarded on
`radius > 0`, because at radius 0 the edge pixels sit exactly on the
boundary and an unguarded smoothstep halves them. Both facts are
asserted on read-back pixels in `smoke-cell`.

Verification: `smoke-e2e` gained a scrollbar stage that drags the
thumb and clicks the trough with real seat input, then repeats the
drag with DECSET 1000 on under `cat -v` — a pane that forwarded the
press would both fail to scroll and leave an `^[[<` report in the
grid, so one assertion catches either mistake. It measures the pane's
right edge off a real frame instead of assuming the toplevel edge: the
CSD shadow is ~25 px at the sides and ~33 px at the bottom, and every
hard-coded guess landed in it.

## Sixel DCS parameters: P1 aspect, P2 background select, P3 ignored

The sixel decoder had honoured exactly one thing from the DCS header:
nothing. `DCS P1 ; P2 ; P3 q` was parsed by the VT state machine and
then dropped on the floor, and the raster attribute's `Pan`/`Pad` were
read into locals and discarded (only `Ph`/`Pv` sized the buffer).

`sixel.decode` now takes an `Options` — an aspect ratio and an
optional background fill — and `Screen.onDcs` resolves both from the
header. P1 goes through `aspectFromP1`, the VT330/VT340 macro table
(0/1/5/6 = 2:1, 2 = 5:1, 3/4 = 3:1, 7/8/9 = 1:1; anything above 9 is
not in the table and gets 1:1 rather than a guess), and the ratio is
applied by whole-pixel replication after painting, clamped to the same
`MAX_DIM` the allocation is. A raster attribute that states a ratio
overrides P1 — P1 picks one of nine macros, `Pan;Pad` says the ratio
outright — which is also why this is safe for modern encoders: they
all emit `"1;1;...`, so their `P1 = 0` never doubles anything.
`Pan;Pad` count on their own now, so a `"2;1` prefix with no size is
honoured.

P2 is the one that is easy to invert: 0 and 2 mean "pixels the data
never paints take the current background colour", 1 means leave them
transparent. Painted pixels are unaffected either way. `.default` as
the current background resolves to transparent rather than to an
opaque box in the default colour, because a pane background image or
window transparency IS the current background there; a palette or RGB
SGR background fills opaque.

P3 (horizontal grid size) stays unread, deliberately: DEC defined it
for the VT240's device grid and xterm and libsixel ignore it. A test
pins that a wildly different P3 changes nothing.

`img2sixel` is not installed here, so the real-producer check ran
against ImageMagick's sixel coder (`magick x.png sixel:x.six`), which
emits `\x1bP0;1;0q"1;1;W;H` — P2 = 1, raster 1:1 — plus hand-edited
variants of that same output for P2 = 0, a 5:1 P1 with the raster
ratio removed, and a junk P3. `zig build replay` now prints an
`image WxH at (row,col) ... px0=(r,g,b,a)` line per image event, since
images leave no cells behind and the grid dump alone could not show
any of this.

## Light and dark as colour variants, and prefs rows that edit what renders

`auto_theme` followed the system, but it did it by substituting a fixed
pair of colours, so "which profile is this pane" and "is the desktop in
dark mode" were not independent axes. `ProfileSettings` now carries a
`light` and a `dark` `ColorSet` (six optional fields), settable at top
level and inside `[profile.<name>]` as `light.<key>` / `dark.<key>`, and
`forScheme` overlays the variant - user's, else the built-in pair - over
the flat base.

`forScheme` returns a COPY rather than swapping in place, which was a
deliberate reversal of the original brief. Two reasons, both load
bearing: the serialiser emits the flat colour keys, so an in-place swap
would let the next persist write the dark colours out as the user's
`default_bg`, and one theme flip would silently rewrite the config; and
prefs binds rows at those same flat fields, so it would edit whichever
half happened to be showing.

That second reason was already a live bug, and the variants only made it
visible: with `auto_theme` on - the default - every colour row in
Preferences edited a base that the variant then covered, so the swatches
looked inert. The Colors page now shows Light and Dark groups whenever
`auto_theme` is on, each row reading the effective value and writing into
`light.*` / `dark.*`, and the toggle rebuilds the section in place. The
resolve-and-write rule lives in `ProfileSettings` with every reader
defined through `forScheme`, so "the row shows what renders" is true by
construction rather than by two copies of the logic agreeing.

Found on the way: `onThemeChanged` pushed the Default profile's fg/bg to
every pane regardless of that pane's own profile, and never touched
palette or cursor at all. Per-profile colours were already half-broken on
every system theme change. One `pushPaneColors`, per pane, now.

## The daemons the e2e rig never forked

`smoke-e2e` was flaky in a way that cascaded: a failed run left around
twenty processes alive under its isolated runtime dir, and the next run
inherited them as "socket never appeared" or an unrelated stage failing.
Green runs were getting hard to trust.

The teardown was correct for the processes the rig forked. That was the
wrong set. When the private daemon dies mid-run the GUI's reconnect path
autostarts a REPLACEMENT, double-forked and detached, so it is neither a
child (PDEATHSIG cannot reach it, and is cleared across `fork` anyway)
nor the tracked `daemon_pid`. Every pane opened after that became a
session worker of a daemon nobody owned, each dragging in Xwayland, dbus
and the at-spi stack. The run then deleted its own tree while that daemon
was still bound inside it, so a directory-based sweep would have found
nothing - which is why both sweeps key on each process's own environ
instead, at startup and at teardown.

Proven on the failure path rather than the happy one: baseline success
runs leaked nothing, forced stage failures leaked nothing, and only
killing the broker mid-run reproduced it. One orphan before, zero after.

The underlying behaviour is left alone on purpose. Any client whose
daemon connection drops silently autostarts a detached replacement, which
is exactly right for the GUI - it is what makes sessions durable - and
exactly wrong for an isolated harness, which would rather fail loudly.
`sketerm mcp` has the same exposure and defends the same way. Both sweeps
are Linux-only (`/proc` environ); on macOS they no-op and the ordered
teardown still runs.

## config.conf, documented from the parser and editable from the dialog

`docs/config.md` described a ZON format with a `version` field and nested
`.font = .{ ... }` tables. That format never shipped. It has been
rewritten from `src/config.zig` itself: every key table, the
profile-level vs app-level split (an app-level key inside a profile
section is rejected, not merged), the prefix families, precedence, and
reload semantics. The key list was diffed both directions against the
parser, so a documented key that does not parse and a parsed key that is
not documented are both build-time findable by hand. Two keys are
deliberately absent from the tables and explained in prose:
`inactive_fg_dim` / `inactive_bg_dim` are retired no-ops, still accepted
so old configs do not warn.

One thing the doc had to say plainly rather than describe as intended
behaviour: `quake_edge` parses, serialises and moves nothing. Wayland
does not permit a client to position its own toplevel and GTK4 removed
`gtk_window_move` on every backend. Real edge anchoring needs
`zwlr_layer_shell_v1`, and the protocol is not the obstacle - the tables
in `src/wlhost/protocol.zig` already cover all of xdg-shell and the wire
codec is direction-agnostic. The obstacle is that GDK owns the GUI's
Wayland connection, so we cannot mint object IDs on it, and a surface
takes its role once and permanently, so switching it means interposing on
libwayland's marshalling mid-realize. `gtk4-layer-shell` exists precisely
to do that (it ships an LD_PRELOAD shim and its header requires being
linked ahead of libwayland), which also means it cannot be taken as a
lazily `dlopen`ed optional dependency. Tabled.

The other half: everything added in this completion pass was file-only.
Styled font families, weights, box drawing, symbol maps, hint rules and
alphabet, the scrollbar set, quake geometry and pane presentation now
have Preferences rows. The two list-shaped families get add/remove rows
rather than a text box holding raw config syntax, and validation lives in
`config.zig` so it matches the parser exactly rather than approximately:
weights are a combo because `parseWeight` errors outside 100..900 instead
of clamping (a spin row would let you stop on a value the next load would
drop), clamped floats use spin rows bounded at the parser's own limits,
and an uncompilable hint regex is flagged rather than refused, because
the file accepts it and hint mode skips it. `ui/hints.zig:validAlphabet`
now delegates to the config-side implementation so there is one.

`quake_edge` kept its row, labelled as having no effect on this backend.
A key that parses and serialises but that the dialog cannot see would be
a worse trap than a row that explains itself.

## a11y: rope character aggregate, anchor table deleted, preedit announced

The editor canvas's AT-SPI layer converted byte offsets to characters
through a sparse anchor table in `a11y/docview.zig` that was dropped
whole on every document revision, so the first conversion after each
edit re-counted from byte 0 to the caret - O(caret) per keystroke with
Orca attached, measurably worse the deeper in the file you type. The
clean fix landed: `editor/rope.zig` now carries a per-node character
aggregate (non-continuation bytes) next to bytes/newlines, maintained
through split, join, `joinCompact` seam fusing and the in-place leaf
paths, asserted by `checkInvariants`, and fuzzed against a naive
recount every step of `editor/fuzz.zig` (soaked at 40k steps/seed).
Node grows 8 bytes (48 -> 56); ~8KB per MB of well-packed document.
`charsBefore`/`charToOffset`/`charCount` are O(log n) descents;
`docview.Index` and its revision invalidation are deleted, and the
ChangeLog/queries take a Document directly. Measured on a 32MB file,
edit-then-convert at the far end: 17.2 ms -> 6 us per cycle.

IME preedit is now announced: AT-SPI has no composition event on the
text widget (GTK's own editables are silent during preedit; the
INPUT_METHOD_WINDOW role belongs to the IM's popup), so the bridge
speaks the composing string via `gtk_accessible_announce` (AT-SPI
`object:announcement`, POLITE - Orca's `_on_announcement` path),
debounced 150ms trailing-edge, cancelled on preedit end; the
accessible TEXT stays equal to the document so offsets never include
uncommitted bytes. `DocSource.setPreedit/clearPreedit` are the relay;
the two one-line calls from `EditorView.onPreedit`/`onPreeditEndCb`
were left to the editorview owner (file was fenced this session).

CharacterCount stays a cliff, in GTK not here: GtkAccessibleText has
no character-count vfunc, and GTK 4.22's AT-SPI adapter derives the
property via `get_contents(0, G_MAXUINT)` + `g_utf8_strlen`
(gtkaccessibletext.c), i.e. an AT polling it on a 60MB buffer forces
one full materialization per poll regardless of our O(1) count.

## MCP tool exposure policy: whitelist, groups, read-only mode

`sketerm mcp` offered all ~104 tools to every client, which is a lot of
noise for an assistant that only needs to drive a Wayland app - and for
someone running three assistants at once there was no way to give each a
different reach. A policy now narrows the tool set per server instance.

`src/ipc/mcpfilter.zig` holds the grammar and a `TOOL_META` table giving
every tool a group (`panes app term files net browser ui core`) and a
`mutates` flag. Terms are comma/space separated: `all`, `<group>`,
`<group>:ro`, `<tool>`, and `-`-prefixed denials. Deny is absolute and
order-independent, any allow term flips the baseline to deny-all (so a
spec of only denials is a plain blocklist), and `core` - the
`capabilities` tool - is never filtered, because an assistant must
always be able to ask what it is allowed to do.

The policy resolves once at startup from `[mcp.<name>]` in config.conf
(`sketerm mcp --profile <name>`), then `SKETERM_MCP_TOOLS`, then
`--tools <spec>`; an unknown term prints the offending term, its source
and the valid group names and exits 2. A typo that silently withheld a
whole group would look, from the far side, exactly like a missing
feature.

Two decisions carry the design. **Filtering `tools/list` is
presentation, not enforcement**: `tools/call` consults the same policy,
and refuses with a message saying the tool exists, that the operator
restricted this connection, and the exact term that would enable it -
not `-32601`, which an assistant reads as "sketerm cannot do this" and
spends turns working around. **Group metadata lives in typed Zig**, not
as extra fields in TOOLS_JSON, so the payload stays a pure MCP document;
the drift that creates is the one real risk, so a test asserts the two
lists name exactly the same tools and names the offender when they do
not. `capabilities` reports the active spec, its source and the
suppressed groups.

`zig build smoke-mcp` grew two stages: a real server started with
`SKETERM_MCP_TOOLS=app:ro, term_list` whose `tools/list` is filtered,
whose `term_open` is refused rather than executed, and whose
`capabilities` explains why; and a typo'd spec that refuses to start.

## Panels: hosting the renderer, and the panel-* control commands

`src/ui/panel/` renders a declarative document; nothing hosted it. It
now has three homes and one addressing scheme.

**Pane face.** `Pane.attachPanel` is the editor face's five-pointer
contract verbatim (widget, ctx, prepare-destroy taking `widgets_dead`,
deinit, focus), and `detachPanel` is in `Pane.severFaces()` - the one
place a face may be added, which is exactly the bug the editor face
carried for a while. Faces stay mutually exclusive: raising any of
terminal / browser / editor / panel hides the others.

**Standalone window.** `src/ui/panelwin.zig` wraps a `PanelView` in an
AdwApplicationWindow on editorwin.zig's model - view struct teardown
deferred to the window's finalize, because GtkWindow dispose destroys
children before ::destroy. The window title follows the document title
through `view.on_changed`.

**Control socket.** `panel-show` / `panel-patch` / `panel-events` /
`panel-list` / `panel-close`, dispatched out of `remotectl` into
`src/ui/panelhost.zig`, with matching `sketerm cli` subcommands
(`--file DOC.json`, or `-` for stdin, because a JSON document does not
survive shell quoting). Replies are flat (`{"ok":true,"panel_id":3,
"session":"s"}`) via `protocol.writeOkFlat`.

Three decisions carry it. **Panels are keyed by (session, name)**:
several assistants drive one sketerm, so a panel is scoped to the
daemon session of the pane that asked for it (`$SKETERM_SESSION`), and
re-showing a name REPLACES that panel's document in place instead of
opening a second window - which is what makes a training loop's "here
is epoch 42" cheap. **`panel-events` never blocks**: it runs on the
GLib main loop, so it drains whatever is queued and answers, empty or
not; `events.Queue.waitAny` is for a thread that may sleep and is not
called here. **A rejected document answers with `doc.Diag`'s message
verbatim** - it names the offending component, and the assistant that
wrote the document is the one who has to fix it.

Liveness has exactly one path: the registry entry IS the pane face's
context pointer, so every pane teardown route reaches
`paneFaceDestroy`, which unregisters before freeing; a window panel
unregisters from its ::destroy. A `panel_id` therefore never outlives
its widgets, and addressing a dead one is a plain refusal.

`smoke-e2e` grew a panel stage: a document rendered into its own
window, a real seat click on the button read back as an event, a real
drag on a slider read back as a change, an image_compare drag asserted
to repaint, `panel-patch`/`panel-list`/scoping/replace-in-place, all
three targets closed the way each should (a pane panel gives the pane
back to its shell, a tab panel takes its tab with it), plus the same
feature driven through `sketerm cli` with the document in a file.

## `ui_*`: the panel feature as MCP tools

The renderer, the hosting and the disk store existed; nothing exposed
them to an assistant. Seven tools now do, in `src/ipc/mcp.zig`:
`ui_show` (inline `document`, or `load` a saved one; target
pane/tab/window, default tab), `ui_patch`, `ui_wait_event`,
`ui_panels`, `ui_save`, `ui_close`, `ui_delete`. Each is a thin adapter
over the five `panel-*` control-socket commands plus `panelstore.zig`,
and each carries a `mcpfilter.TOOL_META` entry in the `ui` group, which
had been reserved and empty (`suppressedGroups`' "a group with no tools
is absent, not withheld" branch now actually has a populated group to
report, and its test says so).

Three things were easy to get wrong and are therefore stated in
`src/ipc/CLAUDE.md`:

**`ui_wait_event` polls; it must never block the GUI.** `panel-events`
answers immediately by design - it is dispatched on the GLib main loop,
where blocking would freeze every window - so the blocking semantics
belong to the MCP side. It polls at 100ms, drains rather than samples
(an interaction between calls is still delivered), clamps `timeout_ms`
to `WAIT_CAP_MS` (120s, under the 150s watchdog) and says so in the
schema, and reports a non-zero `dropped` count with an explicit note:
a silently truncated interaction stream is a wrong conclusion waiting
to happen. A timeout is answered plainly, not as an error, and a panel
the user closed ends the wait immediately with its own message.

**The session is resolved once, for both halves.** Explicit argument,
else `$SKETERM_SESSION`, else the sessionless bucket - and the result
is passed explicitly to the GUI, so a live panel and its saved document
can never end up under different keys while several assistants share
one sketerm.

**Panels need a GUI socket.** `sketerm mcp` is isolated by default;
without `--shared` (or `--socket`) the four live-panel tools return a
described error naming the flag, while `ui_save`/`ui_panels`/
`ui_delete` keep working on the store. `capabilities` reports `panels`
with a hint saying exactly that, next to `gui_socket`.

`doc.Diag` messages pass through verbatim everywhere - they name the
offending component id, which is what the authoring assistant needs.
`ui_close` and `ui_delete` are deliberately separate tools with
descriptions that say what the other one does; `ui_save` with no
document uses the server's own mirror of what it showed (kept in step
by re-applying every ACCEPTED patch through the same document model),
and a mirror that cannot follow is dropped so `ui_save` says it cannot
see the live document rather than storing a stale one.

**A wrong instruction, corrected.** `panelstore` validated the SESSION
against `[A-Za-z0-9._-]`, but the daemon only length-checks session
names - so a perfectly legal session called `my work` could never store
a panel, and the user could not fix it from their side. The session is
now percent-encoded into one directory component (`my%20work`,
`a%2Fb`); a leading `.` or `_` encodes too, so the component can never
be `.`, `..` or the reserved `_no-session` bucket, and the mapping is
injective because `%` encodes as well. The caller-chosen PANEL name is
still rejected rather than sanitized.

`PanelView.prepareDestroy` had `widgets_dead = self.widgets_dead or
dead;` immediately followed by `widgets_dead = true;`, so the parameter
read as if it were honoured and was not. Every caller is about to
destroy the subtree, so the unconditional fence is the correct line; it
stays, with a comment saying why and `_ = dead`.

Verification: `zig build test` / `test-core` / `mux-portable` green.
`smoke-mcp` grew a stage that runs a server with
`SKETERM_MCP_TOOLS=ui`: the seven tools are listed, `term_open` is
refused, `ui_show` explains that panels need `--shared`, and
`ui_save`/`ui_panels`/`ui_delete` work anyway - under a session named
`smoke ui`, whose panel lands in `panels/smoke%20ui/`. `smoke-e2e` grew
`mcpPanelStage`: a real `sketerm mcp --shared --socket` child against
the real GUI in a display session - `ui_show` renders a panel window,
`ui_wait_event` is started, a real seat click lands on it, and the tool
returns that click; then patch, save-from-live, close, re-show by
`load`, and delete. Its reads pump the compositor while they wait,
because this harness IS the brain for that toplevel.

## Panels: one sessionless bucket, and `panel-get` instead of a mirror

Two defects the panel subsystem shipped with, both found by the agents
that built it and both left as decisions rather than guesses.

**The sessionless bucket had two names.** `panelhost.NO_SESSION` was
`"default"` while `panelstore.NO_SESSION` was `"_no-session"`. The MCP
tools always pass an explicit session, so it could not bite through
them - but a `sketerm cli panel-show` from outside any pane scoped the
LIVE panel to `default`, while a store operation from the same place
scoped the SAVED document to `_no-session`. One constant now, defined
in `panelstore.zig` and re-exported by `panelhost.zig`. `_no-session`
is the surviving name because `default` is a perfectly ordinary daemon
session name - a real session called `default` would have shared the
bucket outright - whereas `encodeSession` percent-encodes a leading
`_`, so every real session name lands somewhere else. A test in
`panelhost.zig` pins the agreement: what `scopeOf` resolves to with
neither an explicit session nor a pane is what `panelstore
.resolveSession(null)` resolves to, it encodes to itself in one
directory component, and `default` demonstrably does not.

**The per-server document mirror is gone.** `ui_save` with no
`document` used to read `UiMirror`, this MCP process's own copy of what
it had shown, maintained by re-applying every accepted patch. That copy
could go stale, needed an extra `panel-list` round-trip per `ui_patch`
just to stay keyed, carried a "the mirror could not follow" refusal
path - and structurally could not save a panel shown by a DIFFERENT
process or before an MCP restart.

The GUI already holds the document, so it now answers for it. A sixth
control command, `panel-get {panel_id}`, returns
`{"document","name","session","title"}` with the document straight from
the live `doc.Document` via `toJson` (canonical, byte-stable, which is
what makes the reply diffable against the store). `ui_save` fetches
through it; `UiMirror`, `uiNameForId` and `uiMirrorPatch` are deleted,
along with every `set`/`drop` call site and the mirror's test
scaffolding. Net: less state, one fewer round-trip on `ui_patch`, one
fewer failure mode, and `ui_save` works against any panel on screen no
matter who opened it. Without a GUI socket that half of `ui_save` now
refuses (naming `--shared` and the `document` argument) instead of
silently saving from a mirror that never existed in that mode.

Verification: `zig build test` (1835 pass), `test-core` (1529 pass),
`mux-portable`, `smoke-mcp` and `smoke-e2e` all green. Unit tests
replaced the mirror ones: `ui_save` reads back over `panel-get` and the
stored bytes equal the reported document byte for byte; a panel this
server never showed saves anyway; a panel that is not on screen is a
refusal; no GUI socket is a described refusal that writes nothing.
`smoke-e2e`'s `mcpPanelStage` proves the same live: `ui_save` with no
`document`, then `panel-get` over the control socket compared byte for
byte against the file the store wrote - once for the panel the MCP
server showed and once for a panel the SMOKE PROCESS showed over the
control socket, which is exactly the case the mirror could not serve.

## `ui_show_files`: the one-call image case on top of `ui_show`

The panel primitive is correct and stays, but the driving use case -
"show me these images" while a super-resolution model trains - cost
roughly thirty lines of hand-authored JSON per call. `ui_show_files`
is a document GENERATOR over the exact `ui_show` path: it builds the
document server-side, validates it through `doc.Document.parse`, and
hands it to the same `panel-show`. No new component type, no new
control command, no second rendering path, and what it makes is an
ordinary panel that `ui_patch`/`ui_save`/`ui_close`/`ui_wait_event`
all address normally.

```
ui_show_files {files: [{path, caption?} | "/abs/path"], name?, title?,
               target?, session?, compare?}
```

The decisions worth recording:

- **`compare:true` needs exactly two files** and emits one
  `image_compare` with each caption as its side label - the A/B slider
  the review actually turns on. Any other count is refused, naming the
  count it got, rather than silently falling back to a stack.
- **`name` defaults to `files`.** A unique default name would have made
  "here is the next epoch" open a new tab every epoch; a fixed one
  replaces the panel in place (same window, same `panel_id`, an
  `image_compare` keeps its zoom/pan/split), which is the behavior the
  use case wants. The description says so.
- **Missing paths are pre-validated, but only an ALL-missing set is
  refused.** The renderer already draws an explicit placeholder for an
  unreadable image rather than failing the panel, so one file that
  vanished mid-training is not worth losing the panel over: it is shown
  and named back in `unreadable`. But a panel made entirely of
  placeholders reads as a sketerm bug rather than a wrong `--out-dir`,
  so that case is a refusal that lists the paths.
- **Captions default to the basename**, so a bare array of paths still
  labels itself, and **the cap is 64 files** (`doc.MAX_CHILDREN` is 128;
  the heading takes one).

Files: `src/ipc/mcp.zig` (`uiFilesDocument` + the `ui_show_files`
branch of `uiTool` + the schema), `src/ipc/mcpfilter.zig` (group `ui`,
mutating), `src/smoke_mcp.zig`, `docs/mcp.md`.

Verification: `zig build test` (1840 pass), `test-core`,
`mux-portable`, `smoke-mcp` all green. Three unit tests: the generator
output parses back through `doc.Document.parse` for the stacked,
untitled, compare, hostile-caption and full-cap shapes (compare
asserted down to `left.label`/`right.label`); a `handleMessage` test
proving the document leaves over `panel-show` under the default name
with the captions intact and that an unreadable file is shown AND
reported; and a refusal test covering bad arity both ways, an empty
list, relative and `..` paths, an all-missing set and the cap - with
nothing reaching the backend. `smoke-mcp` grew a stage that serves a
STAND-IN GUI control socket (`FakeGui`) and reads the generated
document off the wire, so the compare document and the refusals are
proven end to end through a real `sketerm mcp` process without a GTK
window.

### Saved panels are reachable from the GUI (command palette)

Panels persisted fine, but only an assistant could bring one back
(`ui_show load=<name>`) — the user had no way to reopen his own saved
panel. Two palette actions close that:

- **Open Saved Panel…** (`panel_open`) opens `src/ui/panelpicker.zig`:
  every document stored for the FOCUSED PANE'S SESSION
  (`panelhost.sessionForPane`, the same scoping rule as the rest of the
  subsystem), one row each with the document's title, size and age.
  Activating a row goes through `panelhost.openSaved` →
  `showDocument`, the same single mounting path `panel-show` uses, so
  the (session, name) keying and the replace-in-place rule cannot
  diverge between an assistant's call and the user's click. Target is a
  TAB of its own: "open" must not take away the shell of the pane it
  was invoked from.
- **Close Panel** (`panel_close`) → `panelhost.closeNearest`: the
  focused pane's panel, else that pane's tab, else the window's only
  one. The ladder is load-bearing — a panel face has no key controller,
  so the palette can only ever be opened from a pane that is NOT the
  panel, and "the focused pane's panel" alone would be unreachable.

A document that no longer parses is LISTED with the parser's own
message as its subtitle and is not activatable — `panelstore`
distinguishes Corrupt from Invalid on purpose, and hiding the broken
one reads as "my panel is gone". Deleting is a per-row trash button
confirmed with an AdwAlertDialog (destructive), not a palette action of
its own: it needs this list to pick from anyway.

`panelShow` was split so `showDocument` is the one mounting path and
`closeEntry` the one teardown path; `panel-show`/`panel-close` are now
thin request wrappers over them.

Covered by `zig build smoke-e2e` (`panelPickerStage`): a good and a
corrupt document written into the pane's session store, the action
invoked on the real seat, Enter on the corrupt row mounting nothing,
the good one coming back keyed (session, name) on its own tab, and
Close Panel taking it down without touching the stored documents. The
stage reaches the actions through a config keybind rather than by
typing into the palette's search entry: with `GTK_IM_MODULE=wayland`
and a session advertising text-input-v3, a GtkText expects the
compositor to produce its text and the harness plays no IME, so the
entry cannot be filled there. Everything after dispatch is identical
(`dispatchAction` is the one path) and the picker itself has no text
entry.

### A panel face on a pane killed the GUI seconds after it closed

`panel-show target=pane` followed by `panel-close` answered "ok" and
then SIGSEGV'd the whole GUI a second or two later. `PanelView.create`
connects a last-resort ::destroy fence on `root_box` with the view
itself as raw user data, and `deinit` unref'd that widget and freed the
view immediately after. The view owns a reference to `root_box`, but on
a pane face it does not own the LAST one: the host unparents the widget
and GTK (with an accessibility bus up, the AT context) can hold on for
frames, so the widget's ::destroy fired after the free and
`onRootDestroy` wrote `widgets_dead` into freed memory.

The fix is to DISCONNECT the handler in `deinit`, before dropping the
reference. A GDestroyNotify — the usual rule for a heap context — does
not help here: it runs when the closure dies, i.e. at that same too-late
moment, and cannot stop `onRootDestroy` from running first. Disconnecting
is the only thing that makes "no callback outlives the struct" true.

The same fuse burns on the per-component contexts (`CompCtx`), which sit
on descendant widgets and therefore outlive the view exactly as long as
`root_box` does — and a GtkDropDown emits `notify::selected` from its own
dispose. Those keep their GDestroyNotify (they are heap contexts and must
free themselves), but the view now tracks them and NULLs their `view`
back-pointer in `deinit`; the three handlers bail on a null view.

Audited the rest of the subsystem for the same shape. `panelwin.zig`'s
::destroy is safe because the window frees the `PanelWindow` from its
qdata destroy-notify at FINALIZE, strictly after ::destroy. `Compare`'s
gesture handlers are safe because the gestures are owned by the drawing
area and die at its dispose, while `Compare` itself is freed by that
widget's qdata notify at finalize. `panelpicker.zig`'s null-notify
connections (the per-row delete button, the listbox's row-activated) are
safe because their widgets are children of the dialog whose "closed"
destroy-notify owns the `Ctx`: the children are disposed before the
dialog finalizes.

Regression: `panePanelLifetimeStage` in `src/smoke_e2e.zig` — three
show/close rounds of a panel face on pane 1, each followed by three
seconds of pumping the display session while `screen-info` round-trips
prove the GUI is still serving. A unit test cannot reach this; it needs
a real widget lifecycle on a real frame clock. The stage fails (GUI
SIGSEGV, first round) without the fix.
## New capabilities, pass 1: the version fix and title templates

The completion pass finished what sketerm already half-had; this one
adds what it did not have at all. Two small things first.

`TERM_PROGRAM_VERSION` was hardcoded `"0.1.0"` in `pty.zig`, so every
terminal ever spawned advertised a version that was true only by
coincidence. `.version` in `build.zig.zon` is the single source of
truth and `pty.zig` compiles into a target that has `build_options`, so
it takes `version.string` like everything else. Bumped to 0.1.1 in the
same commit, and both binaries were asked rather than the source read:
`sketerm --version` and `sketerm-mux --version` agree.

Then title templates. Tab labels showed whatever OSC 0/2 last emitted
and the window title never followed a pane at all. Both are now
templates over a CLOSED placeholder set - Rio's six (`TITLE`,
`PROGRAM`, `ABSOLUTE_PATH`, `RELATIVE_PATH`, `COLUMNS`, `LINES`) plus
`index`, `session`, `profile` and `zoom` - with Rio's `{{ NAME }}`
syntax and `||` fallback chains, so a Rio config transfers unchanged.
Nothing Rio offers turned out to be structurally impossible here.

Defaults preserve today's behaviour exactly: the tab template is
`{{ TITLE }}` and the window template is empty, because a window title
that suddenly began following the focused pane would be a visible
regression rather than a feature.

Two rules earn their place. An empty placeholder consumes one adjacent
punctuation-only literal, so a missing fact cannot leave `nvim - `
hanging; the tests caught two bugs in that rule before it shipped, one
eating BOTH separators in `{{A}} - {{B}} - {{C}}` and one losing the
closing paren of `{{PROGRAM}} ({{COLUMNS}}x{{LINES}})`. And an unknown
placeholder is a parse error naming the valid set, not a silent blank:
the set is closed, so `{{ TITEL }}` can only ever be a typo, and
per-key fallback means the rest of the config still loads.

`{{ PROGRAM }}` needed a fact nothing tracked - there was no
`/proc/comm` read anywhere and `PaneInfo.pid` was hardcoded 0. The
daemon samples `tcgetpgrp` + `/proc/<pgid>/comm` and pushes it on the
existing `session_meta` JSON frame only when it changes, so no wire
byte moved. Idle cost was the constraint, since this daemon holds
durable sessions: sampling runs only from the PTY read drain, never a
timer, rate-limited to 500ms, only while a client is attached, with one
direct sample on attach so a fresh client is not blank until the next
output.

The loop hazard here is real and was closed by construction:
`paneFacts` sources `title` from `Screen.last_title`, never from
`adw_tab_page_get_title`. Reading the rendered label back would make
`"{{ TITLE }} !"` append a `!` per render, forever.

## The Glyph Protocol, all three formats

Rio invented this in April 2026 and is still its only other
implementation - twelve spec revisions in three weeks, and the spec and
Rio's own code contradict each other in two places. Jelle's call was to
follow the IMPLEMENTATION where they diverge, which matters most for
`width`: the spec says it overrides UAX #11 and is authoritative for
cursor advance, wrapping and selection, while Rio keeps layout on
wcwidth and merely PAINTS across that many cells. The spec's reading
has an ordering bug - a registration arriving after its codepoint is
already on screen would retroactively change wrapping - and real client
libraries are tested against Rio, not the prose.

An application registers an outline at a Private Use Area codepoint and
then emits that codepoint as ordinary text, so a TUI can ship its own
icons without a patched font. The cell buffer stays authoritative:
copy, select and search return the raw codepoint.

Three things made this far cheaper than the survey implied. The parser
needed NO state-machine change - `vt.zig` already accumulates whole APC
bodies and `onApc` already drops anything not starting with `G`, which
is exactly the ignore-it behaviour the spec demands. The live wire path
needed no change either: `EventTag.apc` carries APC bodies losslessly
and both the authoritative and the mirror `Screen` run the same
handler, precisely as kitty graphics does, so a glossary replicates for
free and only the SNAPSHOT grew a tail for clients attaching later. And
the rasteriser already existed - the standalone `FT_Outline` API is in
the translated bindings, and `glyf`'s quadratic contours map natively
onto freetype's conic tags, implied midpoints and all, so no path
walker was needed.

Custom glyphs get their own atlas key space rather than joining the
codepoint-keyed cache, because the Atlas is per WINDOW and shared by
every pane while a glossary is per Screen: two panes may legally
register different outlines at the same codepoint.

The design was wrong in exactly one place and the pixel rig caught it.
It said to rasterise and then Y-flip, since freetype bitmaps are Y-down
while `glyf` is Y-up. Freetype performs that flip itself and returns a
positive-pitch buffer, so the extra flip would have rendered every
glyph upside down - a change that compiles, passes every unit test, and
is visible only as two centroids in `smoke-cell` landing at the wrong
heights.

`colrv0` then made glyphs real multi-colour icons rather than
foreground-tinted silhouettes: layers painted back to front with flat
CPAL colours. Palette index `0xFFFF` means "the current foreground",
which makes such a glyph's pixels depend on SGR state - and Rio has a
bug there we deliberately did not inherit, since their atlas key omits
the foreground, so one of their `0xFFFF` glyphs keeps whatever colour
it was first drawn in forever. Ours keys those, and only those, by
resolved foreground; everything else stays cached exactly once. The
snapshot also needed a per-entry format byte, contradicting the design's
claim that raw payload bytes would round-trip unchanged - without it a
colrv0 payload restores as a glyf record and misrenders.

`colrv1` is a paint graph rather than a layer list, and cairo is our
tiny-skia: gradients with all three extend modes, affine transforms,
clipping, and the full Porter-Duff and separable operator set. The v1
table is decoded in pure Zig rather than by synthesising an in-memory
sfnt for freetype's paint API, which keeps validation daemon-side with
the rest of the container and avoids a second font object per glyph.
Correctness budget, stated Rio-style at the code site: solid fills,
linear and radial gradients, glyph clips, all ten transform forms,
PaintColrLayers, PaintColrGlyph and all 28 composite modes are painted
for real; sweep gradients degrade to their first stop, because neither
cairo nor tiny-skia has a sweep shader; variation deltas are ignored,
since the protocol cannot carry variation coordinates. Two places we
beat the reference: stops outside [0,1] are remapped by moving the
gradient geometry where Rio truncates, and the foreground keying above.

C resources are invisible to Zig's leak detector, so a missed
`cairo_surface_destroy` would grow on every repaint. `mallinfo2` joined
the cimport set for a test that rasterises a gradient + composite +
transform graph 300 times under a rotating foreground - a genuine cache
miss each time - and asserts malloc-space stays flat.

We also validate more than Rio does: they check only the framing and
let the renderer meet whatever survives, while the daemon here
validates COLR and CPAL structure, layer glyph ids, palette ranges and
every carried outline before storing.

## Per-platform config sections

`[platform.linux]` / `[platform.macos]`, so one config file can behave
differently per OS instead of forcing two.

Not Rio's syntax. Rio puts a single `[platform]` table with dotted keys
(`macos.window.opacity`) on top of TOML's nested tables; our keys
already use dots for prefix families (`keybind.new_tab`,
`hint.jira.regex`), so `macos.keybind.new_tab` would give one separator
two meanings. A section header also lets EVERY key work inside, where
Rio allows a fixed subset with per-struct merge rules.

Sections apply inline, in file order - a conditional splice of the top
level - because profile seeding already happens mid-parse and is
already order-sensitive. Collect-and-replay would need a second,
contradictory ordering rule and would silently miss profiles seeded
earlier. So there is one rule to learn and it is the existing one; the
consequence is that a section edits the Default bundle, and per-OS
per-profile means placing the section BEFORE the `[profile.*]`
sections, which is also the order the serialiser now emits.

Keys for the platform you are not on are still validated, by applying
them to a throwaway Config with its own scratch arena. A typo in the
macOS block is reported on Linux with the message it would get at top
level, instead of waiting to break on a machine you have not booted.

One sharp edge, documented rather than hidden: a prefs save retains
every platform section verbatim, but the CURRENT platform's values are
flattened into the top level, because inline application leaves nothing
downstream able to tell where a value came from. Undoing that needs
per-key provenance through ~150 serialiser branches, which is
disproportionate against a dialog that already destroys comments and
ordering. `Config.save` warns on stderr when sections are present, and
a test pins the exact flattening so changing it has to be deliberate.

## Cursor trails

Cursor trails landed. Rio's `[effects] trail-cursor` is a neovide port
built on a critically-damped spring per corner of the cursor rect; the
leading corners snap to the new cell while the trailing one lags, so
the quad they span stretches along the path and then contracts.
`render/cursor_trail.zig` is that state machine as pure math (no GL, no
GTK, no allocator), `GridPass` gained an arbitrary-convex-quad emit and
a `trail_quad` input hashed into its Snapshot, and `Pane` drives it
from `onRender` behind a 60 fps GLib timeout.

The timeout is the whole design constraint. An installed frame-clock
tick leaks Wayland object ids on KWin (see the `tick_id` doc), so the
trail follows the bell fade's precedent instead: a plain `g_timeout`
that queues renders for one pane, self-removing the frame the trail
settles - which is also the frame that publishes a null quad and
erases it. `cursor_trail_ms` is a hard deadline, not a time constant,
because a critically-damped spring's absolute settle time grows with
jump distance; cutting at the deadline leaves under a fifth of a pixel
of residual for any jump a terminal can produce. Termination is
unconditional: dt is clamped to a 1 ms floor so a frozen clock cannot
stall the deadline either.

Proven, not asserted: `smoke-cell` renders one mid-flight frame and
checks lit pixels halfway between the old and new cursor cells, then
runs the trail to rest and checks the same probe reads zero (and that
the cursor quad survived). `smoke-e2e` measures the GUI's own CPU
jiffies - idle with the trail off, during two seconds of repeated
cursor jumps, and idle again after settling: 6 / 103 / 10 per
measurement window, i.e. the animation costs 17x idle while it runs
and nothing at all once it lands.

Rio's other effect, `custom-mouse-cursor`, was NOT ported: it hides
the system pointer and paints a hardcoded 21x25 pixel-art hand from an
RLE table at the last known mouse position. On Wayland that trades a
compositor-driven pointer for one that lags every frame of input
latency, for a novelty sprite. The feature-parity list called the item
"cursor trails and custom pointer effects"; only the first half is a
feature.

## Text blending: gamma space, linear light, and the corrected middle

sRGB values are not proportional to light - 128 carries about 21% of
255's light, not half - so blending antialiased glyph coverage on the
encoded values, which is what this renderer has always done at all six
blend sites, leaves partially covered edge pixels too dark. The visible
symptoms are a dark fringe where complementary colours meet along a
glyph edge (red on green is the classic) and light-on-dark text reading
thinner than it should.

`text_blending` now picks the space: `native` (unchanged, and the
default), `linear`, or `linear_corrected`. Ghostty's `linear-corrected`
spelling parses too, so a value copied from its docs works. The reason
the third mode exists is that font rasterisation has been tuned against
gamma-space blending for decades: correcting the maths alone thins dark
text and thickens light text, which reads as "my font broke" rather
than as a fix, so the corrected mode puts perceived weight back where
native had it while keeping the fringe gone.

Both linear modes detour through an sRGB offscreen target, because a
GtkGLArea's framebuffer is a hardcoded GL_RGBA8 texture with no way to
ask for an sRGB format - the same GTK limitation that made Display P3
unimplementable here. The detour sits INSIDE the existing custom-shader
and pane-dim detour, so the scene resolves back to sRGB-encoded RGBA8
before a user shader ever sees it and a CRT shader keeps operating on
the pixels it always did. If that target cannot be built the frame
renders `native` rather than handing linear light to a plain RGBA8
framebuffer, which would wash the whole pane out; every pass writing
into the framebuffer is set from one value so they cannot disagree.
`glClearColor` is the one colour that never passes through a fragment
shader, so the linear modes owe it linear light explicitly.

`smoke-cell` is what makes any of this checkable. Per mode it probes a
glyph EDGE pixel, a fully covered INTERIOR pixel and an untouched
BACKGROUND pixel, on both shader pairs - CellPass for an ASCII row,
GridPass for a DECDWL row, since emoji and CJK rows route through the
other pair and a correction applied to one only would leave adjacent
lines looking different:

    blend CellPass(ASCII)  edge=390 interior=110 bg=940
                           moved(lin/cor)=390/390 lighter=390 darker=0
                           native_drift=0
    blend GridPass(DECDWL) edge=610 interior=1008 bg=634
                           moved(lin/cor)=610/610 lighter=610 darker=0
                           native_drift=0

`native_drift=0` is the regression guard that makes "the default is
byte-identical" a measurement instead of a claim. Every edge pixel
moves in both new modes while interior and background pixels do not,
which is what proves the change is confined to antialiased coverage
rather than tinting whole cells; and all 390/610 of them move LIGHTER,
which is the fringe collapse being undone rather than some other
difference.

Default stays `native` deliberately. Ghostty defaults to
linear-corrected on Linux and there is a good case for following, but
flipping it changes how every glyph looks for every existing user, so
it is one line and a taste call rather than something to slip into a
release.

## Panels: "no session" is a shape, not a name

`panelstore` filed sessionless panels under a reserved session NAME,
`NO_SESSION = "_no-session"`, in the same directory namespace as every
real session. `encodeSession` percent-encoded a leading `_` so real
names could not spell it - but it made an explicit exception for that
literal, so a daemon session actually CALLED `_no-session` encoded to
itself and landed in the sessionless bucket. The two then saw and
overwrote each other's panels. Classic in-band signalling: a value
inside the normal range used to mean "not a normal value".

The namespaces are separate on disk now:

    panels/by-session/<encoded-session>/<name>.json
    panels/no-session/<name>.json

Two PARENTS, so there is no shared directory and nothing to collide -
a session may be called `_no-session`, `no-session` or `by-session`
and it is still just one more directory under `by-session/`. The
percent-encoding of real session names stays (it is what makes `my
work`, `a/b` and `..` storable as ONE component), minus two things that
only existed to protect the sentinel: the reserved-literal exception,
and the leading-`_` escape. A leading `.` still encodes, which is what
keeps `.` and `..` unreachable as component names.

In the code the sessionless case is `?[]const u8`, not a string that
might be magic. `panelstore.resolveSession` - where the sentinel used
to be born, as `explicit orelse $SKETERM_SESSION orelse NO_SESSION` -
returns `null`, and every store entry point (`save`/`saveJson`/`load`/
`loadJson`/`exists`/`delete`/`list`/`sessionDir`) takes `?[]const u8`.
`panelhost` follows: `Entry.session` is optional, `scopeOf` returns an
optional, and `byKey` compares through `sameSession`, where sessionless
matches only sessionless. `panel-list`'s filter became a three-way
`Filter` union (`all` / `none` / `session`) because "no session
identity in the request at all -> show everything" and "explicitly
sessionless -> show the sessionless panels" are different questions
that a `?[]const u8` filter had to answer with the same `null`.

Where the optional STOPS is the string-typed edges, deliberately:

- The control socket carries JSON, and absence already means something
  else there ("scope me to the requesting pane"). So the wire spelling
  of sessionless is an EMPTY `session` field - `panelhost
  .NO_SESSION_WIRE`, documented as a wire encoding and never as a
  session name. `panelstore` accepts `""` as `null` for the same
  reason, in ONE place (`norm`), and it is safe because the daemon caps
  a session at 1..64 bytes: no session can ever be the empty string.
- `panelhost.sessionForPane` keeps returning `[]const u8` for the GUI's
  saved-panel picker, which both displays it and hands it to the store;
  `sessionScopeForPane` is the typed answer used everywhere inside.
  Making the picker's call optional would have churned four call sites
  (a dupe, a `{s}` format, a struct field) for no additional safety -
  the picker cannot construct a wrong key either way.

`panelhost.NO_SESSION` is gone with `panelstore.NO_SESSION`; the test
that pinned the two spellings together now pins the shapes: what
`scopeOf` resolves to with neither an explicit session nor a pane is
`null`, so is `panelstore.resolveSession(null)`, an explicitly empty
`session` field resolves to the same thing rather than falling through
to a pane, and the directory that resolves to is not the directory of a
session called `_no-session`, `no-session` or `default`.

Tests: `panelstore` grew "the sessionless bucket shares no namespace
with any session" (full sessionless save/load/list/delete/exists; a
session literally named `_no-session` round-tripping to its own file
with its own content; the same for `no-session` and `by-session`; and
`""` reaching the sessionless bucket); the encoder test pins
`_no-session` encoding to itself as an ordinary name; the traversal
test now proves the encoded component sits under `by-session/` with no
separator of its own. `panelhost`'s registry test grew a sessionless
third entry that no session name can address. `smoke-mcp` stage 5
checks `panels/by-session/smoke%20ui/vsr.json` (the encoding proof it
always was), plus a sessionless `ui_save` landing in
`panels/no-session/`, a `ui_panels session=_no-session` that cannot see
it, and a sessionless `ui_panels`/`ui_delete` that can.

No migration code: pre-release, and the only stored panels were from
the same day's testing. A `panels/<session>/` directory left over from
the old layout is simply never read again - `list` only ever looks in
the two new parents - so a stale one is dead weight, not a source of
wrong answers.

Verification: `zig build test`, `test-core`, `mux-portable`,
`smoke-mcp` green.

### Signal-lifetime rule + a panel-context use-after-free detector

The `panel/view.zig` `::destroy` use-after-free had no written rule
behind it: the codebase solves that class three ways (disconnect at
teardown, the widget owns the data, a liveness fence) and nothing said
which to reach for. CLAUDE.md's memory-ownership section now states the
choice, the condition each mechanism depends on, and the trap that a
`GDestroyNotify` on a signal connection is freed BY the disconnect - so
"do both for safety" turns a disconnect into a free and is worse than
either alone. Qdata-at-finalize is the exception, and is why
`panelwin.zig`'s ordering is sound.

On top of one correct owner, `src/ui/panel/canary.zig` adds a DETECTOR
rather than more redundancy: every panel heap context (`PanelView`,
`CompCtx`, `Compare`, `PanelWindow`, the picker's `Ctx`/`DeleteCtx`)
carries a magic word poisoned at free, and each callback resolves its
user-data through `canary.live`, bailing loudly on a mismatch instead of
running into freed memory. Guarding the free paths too means a second
free leaks rather than double-frees. It is an explicit branch, not an
assert: this project builds ReleaseFast only. Eight tests, including
double-free shapes the testing allocator would catch if the guard failed
to fire.

An audit of all 454 `g_signal_connect*` sites in `src/ui/**` found one
live bug, fixed separately: `window.zig:709` hung `notify::dark` off the
process-global AdwStyleManager with a raw `*Window` and never
disconnected, so closing a secondary window and then flipping the system
theme ran `onThemeChanged` on freed memory.

### The AdwStyleManager use-after-free, fixed and covered end to end

The bug the audit above named is now fixed and has a smoke stage of its
own. `Window.init` connected `notify::dark` on
`adw_style_manager_get_default()` - a PROCESS-GLOBAL singleton - with a
heap `*Window` and no destroy-notify, while `Window.deinit` ends in
`allocator.destroy(self)`. Detach a tab into a secondary window (or
`openShellWindow` / `openFilesWindow`), close it, and
`onWindowDestroyed` -> `deferredWindowFree` frees the Window; the
singleton then still holds a handler pointing at it.

Reproduced before fixing: with pointer-identity tracing,
`deferredWindowFree` freed `Window@...b3a60000` and the very next
colour-scheme flip ran `winconfig.onThemeChanged` on that exact
pointer. Left running, the GUI stops answering its control socket.

`Window.deinit` now calls `detachGlobalSignals`, which is
`g_signal_handlers_disconnect_matched` with `G_SIGNAL_MATCH_DATA` -
mechanism 2 of the memory-ownership rules, because the data must
outlive the widgets and the target is shared. Its precondition holds:
`deinit` is the one choke point every teardown path reaches, the
secondary-window idle and `main.zig`'s `shutdownWindow` both landing
there.

A second instance of the same shape turned up in the same file and is
fixed alongside: the app-scoped `notify-act` GAction (desktop
notification activation) is registered once, on the GApplication's
action map, with the registering window as user data. Its
`GSimpleAction` lives as long as the application, so the handler
outlived that window too. The action is now removed with its handler,
which also repairs a second defect - the next window's init finds it
missing and re-registers against itself, where before a closed
registrant left notification activation permanently pointed at freed
memory.

Covered by `themeSingletonStage` in `smoke_e2e.zig`. `notify::dark` has
no trigger outside the process (libadwaita 1.9 takes the system
preference from the desktop portal only - its GSettings fallback is
gone, and `system_supports_color_schemes` reads 0 without a portal), so
the GUI gained one env-gated test hook, `SKETERM_THEME_FLIP_MS=<ms>`,
which flips the scheme on a timer. The stage runs its OWN GUI instance
on the shared display session: the variable has to be set at exec time,
and a window repainting five times a second would wreck every pixel
assertion the other stages make. Negative control: with the disconnect
removed the stage fails on "the GUI went unhealthy after a secondary
window was closed under a theme flip"; with it, green.

Verification: `zig build test`, `test-core`, `mux-portable`,
`smoke-mcp`, `smoke-e2e` green.

## Daemon-side asciicast playback sessions

`SpawnReq.cast_path` spawns a session whose "child" is an asciicast
v2/v3 file replayed by the daemon on its own monotonic clock - no
child process, no keeper, no PTY, no Wayland/audio/a11y hubs. The
structural change is that `Session` is now source-aware:
`source: union(enum) { pty: Pty, cast: *CastPlayback }`, with
`ptyPtr()/masterFd()/childPid()` helpers that degrade to null/-1 so
the ~24 former `.pty` call sites (poll registration, drain, input,
resize, fg/cwd sampling, kill fences, broker meta, debug) stop
assuming a child exists. Broker mode needed nothing special: the
worker's `spawnSession` takes the same early branch.

Playback rides a `pulseTick`-shaped `castTick`: events whose
normalized time falls due are dispatched, output bytes going through
the SAME ingestion path PTY reads use - the byte-parsing half of
`drainSession` was refactored into `ingestBegin`/`ingestBytes`/
`ingestFinish`, so the wire stays parsed-events-only and the events
backlog/resync machinery applies unchanged. Catch-up work is bounded
(256 KiB output / 500 events / 512 KiB file reads per tick, then an
immediate re-tick; output is never dropped). Recorded resizes flush
the batch, resize the Screen and broadcast a fresh SNAPSHOT. EOF
retains the final screen and marks the playback finished - the
session stays alive for late viewers; it never goes through
`sessionExited`.

A cast is untrusted content: `EventCollector.untrusted` drops kitty
`t=f`/`t=t`/`t=s` APCs before they can reach `kitty_inline.rewrite`
or `grid/kitty_images.zig` (both open - and for tempfiles DELETE -
daemon-host paths named by the file); Screen-generated responses
discard through the source-aware `sinkWritePty`; client `.input` is
dropped and client `.resize` ignored (recorded dimensions win);
`rec_start` on a playback is refused.

Controls are two append-only frames: `play_control` (30, JSON
op play|pause|restart|seek|speed, speed clamped to [0.1, 10]) and
`play_state` (94, state/position/duration/speed/markers, throttled
>=500ms while playing, sent per attach). The welcome advertises
`cast_playback:true` and `Conn.cast_playback` parses it. Playback
starts paused at 0 and auto-plays on the first attach. Seek resets
parser + Screen (fresh style pool, images gone with it) and replays
from the file start in bounded silent chunks across ticks
("seeking" play_state), then one SNAPSHOT; restart is seek 0.

Tests (`src/mux/daemon_cast.zig`, in both roots) drive the engine on
a synthetic clock: ordered delivery, resize snapshots, input/resize
rejection, kitty neutralization (t=t survives untouched, t=d passes),
EOF retention, pause/play/speed clamp, and seek-vs-linear grid
equality at a mid position and at EOF.

Verification: `zig build test` (2019 pass), `test-core`, `smoke-mux`,
`smoke-broker`, `mux-portable` (+ aarch64-macos) green; `ldd
sketerm-mux` still libc/libm only.
## TerminalSurface: the renderer extracted from Pane

`src/ui/pane.zig` had grown into both the terminal RENDERER and the
interactive workspace container (~3900 lines). The rendering half now
lives in `src/ui/terminal_surface.zig` as `TerminalSurface`, composed
by value inside Pane (`pane.surface`): the GtkGLArea and its
realize/unrealize/re-realize lifecycle (the every-realize-is-a-
re-realize invariant moved with it), all render passes (grid, cell,
image, bg, custom shader, the linear-light blend target and the
one-effective-blend-mode coordination), the ImageStore, the Atlas
reference, and every visual timer that exists purely to redraw the
surface - cursor blink, cursor trail, bell fade, kitty animation,
shader animation - behind a single `stopVisualSources()`.

Pane keeps input, menus, selection, faces, banners, Window sinks and
split-tree participation, and drives the surface through a narrow
API. The post-atlas-rebuild invariant (markAllDirty + the GridPass
vbuf/row-cache resets) is now one method, `surface.onAtlasRebuilt()`,
so it can never be half-applied again. What the render half notices
but only a session owner can act on goes out through nullable host
hooks: `on_child_exit` (tick saw the PTY child die),
`on_before_redraw` (IME caret placement), `on_grid_geometry` (column/
row COUNT changed).

The point of the split is a future cast-playback viewer: a
`TerminalSurface` renders a terminal without inheriting Pane's input
or faces. That is also why the surface carries an explicit
presentation-geometry policy, `TerminalSurface.Geometry`:
`live_terminal` (the pane behaviour - allocation drives the grid,
resizes propagate to the session) vs `fixed_grid` (a fixed cols x
rows grid letterboxed and scaled into the allocation, geometry never
propagated). Nothing exercises `fixed_grid` yet; the viewport math is
real (offscreen detours render at the grid's native size, the final
hop to the window framebuffer letterboxes), and under `live_terminal`
every expression degenerates to the old 1:1 path.

Zero behavior change intended: same frames, same invalidation, same
teardown order; signal lifetime mechanisms preserved per connection
(area signals still rely on Pane's deferred free outliving the widget
tree; the blink/bell/trail timeouts are still severed before free,
now inside the surface; the frame tick stays widget-owned).

Verification: `zig build`, `test`, `smoke-gl-core`, `mux-portable`,
`smoke-e2e` green.

## GUI cast playback: `sketerm play <file.cast>`

The client half of the daemon's cast-playback sessions. `sketerm play
<path>` (terminal application identity, no suffix - a forwarded
invocation opens its window in the running instance, several
invocations several windows) spawns an EPHEMERAL cast session
(`SpawnReq.cast_path`) on the local autostarted daemon - or, for
`host:/path`, on that host's daemon over the usual transports - and
opens a `CastView` (`src/ui/castview.zig`): an AdwApplicationWindow
owning a `Terminal` (initRemote) and a `TerminalSurface` in
`fixed_grid` geometry, plus a transport bar (play/pause, restart,
seek slider with `gtk_scale_add_mark` ticks for recorded markers,
m:ss position/duration, speed dropdown 0.25x-4x). Keyboard: Space
play/pause (Space on finished restarts), Left/Right seek 5s, Shift
30s, R restart, Q/Escape close. Ephemeral means Terminal.deinit
KILLS the session, so closing the window leaks nothing; a GUI crash
leaves it reattachable.

Terminal-side plumbing (`src/terminal.zig`): `play_state` frames
parse into `Terminal.PlayState` (markers callback-scoped; a scalar
copy stays on `last_play_state`), dispatched via the new
`on_play_state` sink - covered automatically by the clearSinks
reflection guard - and `sendPlayControl(op, ms, speed)` emits
op-specific JSON, gated on the welcome's `cast_playback` so an old
daemon never sees the frame.

The sink wiring is deliberately PASSIVE (the cast is untrusted
content): render request, images, glyph coverage, title, play_state -
and nothing else. No clipboard, notifications, pointer shape, cwd,
command status, bell side effects or profile switches can reach the
GUI from a recording, and the view never sends input or resize.
Recorded resizes arrive as snapshot swaps; the render-request sink
tracks `screen.cols/rows` into the fixed_grid dims. Fonts follow the
user's config; colors/theme stay at renderer defaults for now.

`fixed_grid` held up on its first real render: letterboxing, the
offscreen-detour viewport ordering and the resize path all worked
unmodified. The one bug found was CastView's own: the post-seek
slider guard also swallowed seek-COMPLETION play_state pushes, so
the thumb stuck at the drag point; only throttled `.playing` pushes
can be stale, and event-driven states now always land.

Slider seeks are throttled to one per 250ms - every seek is a full
daemon-side replay from byte zero, and a drag must not stream one
per pixel. Selection/copy inside the view is out of scope for v1;
`sketerm play` with a dead file prints the daemon's reason and opens
no window (exit status stays 0 when GApplication had nothing else
to show - known cosmetic gap).

smoke-e2e grew a `castPlaybackStage`: a hand-written v2 cast (red
block, recorded resize, green block, marker, blue block at 30s so
normal playback never reaches it), `sketerm play` launched into the
display session, pixels asserted per color, every control driven on
the real seat, and the daemon's play_state stream cross-checked over
a read-only side attachment (playing -> paused -> playing ->
finished at 30000/30000 with the 1400ms marker -> restart) - ending
with Q, a clean GUI exit and the session gone from the daemon list.
Broker gotcha the stage found: `.list` on a broker answers with a
refreshed `.welcome`, not `.ok`.

Verification: `zig build`, unit suite (2027 tests via the test
binary; the `zig build test` wrapper trips a pre-existing tesseract
leak flake on this host, also on clean master), `smoke-e2e`,
`mux-portable` (+ aarch64-macos cross) green; `ldd sketerm-mux`
still libc/libm only.

Files surfaces it: a `.cast` entry's context menu grew "Play in
Sketerm" next to the Viewer/Editor items (`paths.isCastName`,
`menu.onMenuCastPlay`, `open.launchCastPlayer`), spawning `sketerm
play <host-qualified spec>` as its own process - the sibling
`sketerm` binary, never our own exe, because a `sketerm-files`
argv[0] would parse `play` as a files spec. Double-click is
unchanged: activation has no internal-viewer routing (not even for
images), so a cast still opens in the system default handler.

## Cast playback inside the Sketerm Viewer

Opening a `.cast` file with the Viewer (`sketerm view x.cast`,
`sketerm-viewer x.cast`, viewer batches, the file picker's new
"Recordings" filter) now plays it in place, with batch navigation
intact. First step of the planned "Viewer = shell + content
controllers" split.

The playback core moved out of `castview.zig` into a shared
component, `src/ui/castbox.zig` (`CastPlayerBox`): the Terminal
(initRemote, passive sink policy), the fixed_grid TerminalSurface,
the transport bar (play/pause, restart, seek slider with markers,
speed dropdown), all play_state/seek-throttle/seek-guard logic, and
the ephemeral-session lifecycle (connect -> cast_playback capability
check -> spawn(cast_path) -> attach; destroy() kills the session).
`CastView` is now a thin window shell: window + title + the
standalone key bindings, zero transport or sink code of its own. The
box exposes `surfaceWidget()` and `barWidget()` separately rather
than one container so castview keeps the bar as a real Adw bottom
bar (pixel-identical window) while the viewer stacks both in its
content area. Hosts hand the box `on_title`/`on_state` callbacks;
transport-bar signal handlers carry the raw box pointer with no
destroy-notify, valid because both hosts guarantee the widgets die
before `destroy()` runs (single teardown choke point).

ViewerWindow grew a content boundary: `Content = union(enum) {
image, cast: *CastPlayerBox }`. `.image` is the window-owned
canvas/loader pipeline, which persists for the window's whole life
exactly as before (zero behavior change; the payload-less tag is
deliberate - moving the persistent canvas/LoadTarget pipeline into a
per-item struct would have meant rebuilding it on every navigation).
`.cast` is a per-item controller. `showCurrent` routes by
`paths.isCastName` (landed by the Files work) BEFORE any image load
starts, and cancels the image LoadTarget when showing a cast so a
stale preview can't deliver into cast mode. Image-only header
controls (zoom cluster, fit/fill/actual, rotate, animation
play/pause, the hamburger) hide via visibility toggles; the status
line shows recording title + position/duration where images show
dimensions. Navigation teardown is synchronous and complete:
severLive (timers + sinks fenced), widgets removed from the slot
(their last ref), destroy() (session killed), then the image chrome
returns. Window close severs on `destroy` and frees at finalize,
castview-style.

Keyboard policy (documented divergence): in the VIEWER, Left/Right
stay batch navigation ALWAYS - mixed image+cast batches need
consistent arrows - so cast seeking is `,`/`.` (5s) and `<`/`>`
(30s), Space = play/pause (it was animation-only before, and casts
never have an animated image loaded), R = RESTART the recording
(images keep R = reload). The STANDALONE `sketerm play` window keeps
its original bindings, arrows = seek 5s/30s. Remote casts ride the
same `host:/path` spec plumbing as `sketerm play host:/path`
(`mux_cli.muxConnect` inside the box).

Registration: `data/dev.sker.sketerm.viewer.desktop` gained
`application/x-asciicast` and a widened Comment/Keywords; the batch
collector needed nothing (it is extension-agnostic). Files' "Open in
Sketerm Viewer" menu exposure for casts was left alone (browser
files off-limits this run) - follow-up if wanted. That follow-up
landed right after: `paths.isViewerName` (images + casts) now gates
both the Files "Open in Sketerm Viewer" row and all three branches
of `open.launchViewer`'s sequence builder (multi-selection, icons
walk, column-view walk), so a folder holding both hands the Viewer
one mixed batch with the clicked item as initial, while "Play in
Sketerm" stays as the dedicated-window route.

smoke-e2e grew `viewerCastStage`: `sketerm view <png> <cast>` into
the display session, Right -> red+green blocks render in place, a
read-only side attachment cross-checks Space pause/resume, Left ->
the frame clears AND the ephemeral session vanishes from the daemon
list (the no-leak invariant), Right again -> a fresh session
renders, then a WM window close -> clean exit and the second
session dies too. Exact-PID cleanup only.

Verification: `zig build`, `zig build test` (tesseract flake noise
unchanged, exit 0), `test-core`, `smoke-e2e` (viewer + cast +
viewer-cast stages green), `mux-portable` + `ldd sketerm-mux` still
libc/libm only (no daemon changes).

## Viewer unification Phase A: universal text/hex content + host policy

The Sketerm Viewer is becoming the one viewer shell (Phase B will put
it behind Files' Quick Look Space), so it gained Quick Look's "preview
ANY file" ability now. `Content` grew a third tag: `.text`, a
window-lifetime read-only monospace GtkTextView in its own scroller
slot, shown by `setContentMode` (now a three-way image/text/cast
enum). Routing lives in the GTK-free model (`viewer.contentKind`):
`.cast` -> cast player, anything `paths.isPreviewMediaName` covers
(images plus pdf/video/audio, which the daemon preview codecs already
rasterized before this change - routing those to text would have
REGRESSED them, a deliberate deviation from "image extension only") ->
the image pipeline, EVERYTHING ELSE -> text. Consequence: `sketerm
view anything.txt` (or any unknown file) now displays instead of
erroring - intended.

Loading: `Variant` gained `.head`; `fetch` reads a bounded 256 KiB
head (`HEAD_BYTES_MAX`) over the same ranged fsdrive reads, with NO
size ceiling (a 10 GB binary still hex-dumps its head - the
ORIGINAL_BYTES_MAX guard moved below the head branch). The head rides
the window's MAIN LoadTarget, so an in-flight text load is fenced by
the exact same generation discipline as an image load (navigation
supersedes, showCast cancels, close() kills). `LoadResult.head`
carries the raw bytes to the main thread; classification and rendering
happen in `onHeadLoaded`: `hexdump.looksBinary` (the SAME shared
GTK-free helper Files' preview uses, `src/filebrowser/hexdump.zig` -
nothing was copied) decides text vs binary, text is sanitized with
`g_utf8_make_valid` (Files parity, truncation can split a sequence),
binary renders through `hexdump.write` (offset | 16 hex | ASCII
gutter, identical conventions). Status line: "UTF-8 text 12.3 KiB" or
"Binary (hex dump)  showing first 256.0 KiB of 4.2 MiB". Image header
controls hide exactly as they do for casts; R reloads.

Host policy: `ViewerWindow.open` now takes `ViewerWindow.Options` -
`transient_for` (set on the window), `close_on_space` (Space CLOSES in
every content mode; cast play/pause moves to K), `show_in_files_action`
(false hides the hamburger row AND skips the context-menu row),
`on_activate` + `activate_ctx` (Enter on the current item, receives
the spec; ctx must OUTLIVE the window - no fence, safe because the
callback only fires from the window's own key controller). Standalone
invocation passes `.{}`: nothing user-visible changes for `sketerm
view`/`sketerm-viewer`/`sketerm play`. Phase B consumes the struct.

smoke-e2e: `viewerCastStage` grew to a 4-item batch (png, cast, txt,
bin). After the existing cast checks: Right -> text item (cast frame
clears, session-leak check in the cast->text direction, OCR asserts
the file's QUILL token rendered), Right -> binary (OCR asserts
HEXPROOF from the hex dump's ASCII gutter), Left -> text again, Left
-> cast renders afresh, then the unchanged WM-close teardown. OCR uses
util/ocr.zig (dlopen'd tesseract) and SKIPS with a note when
unavailable, keeping the structural checks. Unit: `viewer.contentKind`
routing test in BOTH roots (hexdump/classifier tests already were).

Verification: `zig build`, `zig build test` 2024/0 (exit 0 direct;
the build-step wrapper still trips on tesseract's leak noise exactly
as on clean master - baselined), `test-core` 1690/0, `smoke-e2e` PASS
including all pre-existing stages, `mux-portable` + `ldd sketerm-mux`
libc/libm only.

Follow-ups for Phase B: the viewer's Open picker still filters to
images+recordings (no "All Files" filter yet); Files' isViewerName
gate on "Open in Sketerm Viewer" still excludes plain files; no
syntax highlighting (out of scope by design).

## 2026-08-07: viewer Phase B - Files' Quick Look hosts the shared Viewer

Files' Quick Look is no longer its own window implementation: Space now
opens the REAL `ViewerWindow` (src/ui/viewer.zig) in quick-look mode
and the ~550-line duplicate in src/ui/browser/preview.zig (the
`QuickLook` struct, its control strip + 19 signal handlers, keyboard
dispatch, CSS, position label, private full-res LoadTarget) is deleted.
Entry points unchanged: `quickLookToggle` keeps its name and the
nav.zig chord / selection.zig capture-phase Space wiring is untouched;
`quickLookStep`/`quickLookActivate` are gone (the viewer navigates
itself; Enter is `Options.on_activate`).

Batch: the tab's rendered listing in display order, EVERY non-directory
entry (the viewer displays anything since Phase A). The per-view-mode
walk was extracted from `launchViewer` into `open.collectListingSpecs`
+ `SpecWalk`, parameterized by a name predicate - launchViewer passes
`paths.isViewerName`, quick look passes an accept-all - so the two
sequences cannot drift. Focused row first (last-selected fallback,
same semantics as before); specs host-qualified via
`paths.formatSpecAlloc`; the ViewerWindow owns the Batch from open.

Options: transient_for = the browser's toplevel, close_on_space,
show_in_files_action=false, on_activate = copy the path out (the spec
dies with the window), close, then `render.activatePath` - the same
funnel a double-click takes, so picker/archive/collection modes keep
their activation semantics.

Lifetime: `preview.State.quick_look` tracks the open window. ONE
mechanism: a plain `g_signal_connect_data(window, "destroy", ...)`
with the BrowserView as user-data and NO notify/disconnect, correct
because every path that frees the view destroys the window first -
Space toggle, the tab-switch close in nav.onSwitchPage, and a new
`quickLookClose()` at the top of BrowserView.deinit. A user-initiated
close (Space inside the viewer, WM close) lands in the same destroy
handler and clears the pointer, which the smoke stage proves by
reopening.

Fallout removed with the overlay: `previewTargetPath` no longer has a
QL cursor branch, `updatePreview` lost the overlay header path (and
with it `describeEntry`/`appendMediaLines`/`setPreviewMeta` - the
panel's `preview_meta` label stays in the layout, now always empty),
`paintPreview`/`showPreviewNote`/`startPreview` lost their QL mirrors,
and `schedulePreload` only runs for the side panel now. `NavList`
stays (preload ordering). Information panel and the thumbnail/preview
pipeline untouched.

Accepted behavior changes (deliberate, not regressions): loading goes
through the Viewer's own daemon/LoadTarget path instead of the
browser's HostConn preview pipeline (no preload-cache reuse, no
browser-side preview cache hit); Viewer chrome replaces the minimal
strip; casts now PLAY in quick look; navigation keys are the Viewer's
(arrows no longer clamp against a selection-only NavList, and the
browser's focused row no longer follows the viewer's cursor).

smoke-e2e: new `quickLookStage` (6c-11) - a real `sketerm files`
window (own SKETERM_APP_ID, exact-pid kill, teardown entry), two text
files with distinct OCR tokens, click-to-focus + type-ahead 'a' +
Escape, Space -> viewer window maps and OCR shows the focused file's
token, Right -> next file's token, Space -> window gone, second Space
-> REOPENS (the tracked pointer really cleared), closed again, files
window still healthy. A `waitVisualSettle` before keying into the
reopened window matters: keying into a just-mapped window raced once.
Plus a `dumpWindowRoster` forensics helper for failure paths.

Verification: `zig build`; `zig build test` 2024 passed/0 failed and
`test-core` 1690/0 (both suites exit 0 run directly; the build-step
wrapper trips on tesseract's atexit leak noise exactly as on clean
master - re-baselined this session); `smoke-e2e` PASS including all
pre-existing stages; `mux-portable` green; `ldd sketerm-mux` still
libc/libm only. Net -548 lines in src/ui/browser.

## 2026-08-07: doctor reports daemon and active MCP process PIDs

`sketerm doctor` now prints the PID of the main daemon beside its
version. New daemons include `daemon_pid` in additive welcome/list JSON;
for the upgrade case that motivated this work, a new doctor also reads
the connected Unix socket's peer PID, so an already-running old daemon
which cannot know the new field is still identifiable. Linux uses
SO_PEERCRED and Darwin uses LOCAL_PEERPID in `platform.unixPeerPid`.

Active MCP servers have their own section. Every new `sketerm mcp`
holds an exclusive flock under `$XDG_RUNTIME_DIR/sketerm/mcp-servers/`
and atomically publishes its PID, mode, optional name/profile/log label,
and mux socket. The flock, not `kill(pid, 0)` or a process-name scan, is
the liveness predicate: normal exit removes the record and SIGKILL
releases the lock so doctor can discard stale debris. Existing
pre-registry `mcp-tmp-<pid>` instances are included through the old
runtime-directory/PID convention and marked `[pre-registry]`, making the
first doctor run after this upgrade useful without restarting assistants.

Each row distinguishes a lazy MCP whose private mux has not started from
a running mux, and reports that mux's PID plus live session/app counts.
Doctor never autostarts an MCP daemon while inspecting it. Shared,
isolated and durable modes use distinct colors; labels, healthy states,
notes and warnings are also colored on a TTY. Piped output stays plain,
and `NO_COLOR` or `TERM=dumb` disables ANSI output.

Coverage: core tests pin flock liveness/stale cleanup, legacy discovery
and Unix peer credentials; doctor tests pin color policy and plain/color
row formatting. `smoke-mcp` proves a live server appears before its lazy
mux starts, then shows the mux PID and session count after `term_open`,
with no ANSI on captured stdout. `smoke-broker` proves `daemon_pid` is
the broker PID rather than a worker. Verification: `zig build`,
`test-core`, `smoke-mcp`, `smoke-broker`, `mux-portable`, and the full
suite pass; the known tesseract atexit leak noise remains. `ldd` for the
daemon remains libc/libm only.

## 2026-08-07: preview/viewer/tab papercuts from a usage report

Six fixes from one round of user feedback, each implemented in its own
worktree and merged in sequence.

`paths.classify(name) -> ContentClass{cast, media, text}` is now the
single by-name content oracle. Three classifiers had drifted apart: the
sidebar's Type row asked `g_content_type_guess`, the preview-handler
picker used its own extension sets, and the viewer had `contentKind`.
The visible symptom was an asciicast labelled "Binary" while it showed
raw JSON in the sidebar and played fine under Space. All three now route
through `classify`; `g_content_type_guess` survives only as a label
refinement inside a class. A cast preview renders parsed v2/v3 header
metadata (version, terminal size, title, recorded date, term type, idle
limit) via a new `text:cast` builtin producer, users can name it in
`previewers.conf`, and a file merely named `.cast` that is not one falls
back to the text/hex renderer. Casts stay out of the image/thumbnail
sets because the daemon still cannot thumbnail them. Sidebar metadata
strings are sanitized before reaching a GTK label: control bytes
flattened, invalid UTF-8 fields dropped.

The preview stage no longer letterboxes. It requested a flat 240px
height and the picture filled it, so a 16:9 image sat in a black band;
now `setStageHeight` fits `min(240, width * h / w)` from the decoded
texture on every paint, which matters because a cached preview is
re-shown without a re-decode. The stage also had to stop inheriting
`vexpand` from its children, or the size request was ignored entirely.
Icon and text previews keep the full 240 so the panel does not jump
while arrowing through a folder.

Local images skip the thumbnail detour. Every image opened in the viewer
started as a 512px daemon preview with a "View full resolution" button,
with no size threshold and regardless of locality. Local decodable
images now auto-chain to the original after the preview paints, so the
button is what it was always meant to be: the bounded-transfer affordance
for remote files. Local video/audio/pdf keep the daemon-rendered poster
and now HIDE the button, which previously could only produce
`DecodeFailed` since there is no client-side container decoder. The
existing caps still bound the cost, and an over-cap image falls back to
preview plus button.

`src/ui/playbar.zig` is a shared transport bar (play/pause, restart,
seek scale, position label, optional speed dropdown) behind a `Source`
vtable, with the seek throttle and guard as per-source options. The cast
player is now a consumer of it with no user-visible change, and animated
images in the viewer get the same bar: GIF/APNG/WebP/AVIF/JXL can be
paused, scrubbed and restarted, with the bar hidden for stills. To make
that possible `image_canvas.Session` gained a cumulative timeline
(`total_ms`, `timelineTotalMs/StartMs/IndexForMs`), `seekToMs`/
`seekToFrame` that reset the deadline bookkeeping and pull an exhausted
finite play count back so resume does not snap to frame 0, and a
playback callback that carries position per frame instead of firing only
on toggle.

Leaving the editor face returns where it came from. "Edit in Sketerm
Editor" converts a pane in place, and every way back raised the terminal,
leaving an attached-but-hidden browser and no banner. `Pane` now records
one `PrevFace` on an editor raise and restores it on hide, cleared in
both detaches so a dead face cannot be resurrected; the editor's back
button switches to a folder icon and "Back to the file browser" when
that is the destination. The files context menu gained "Edit in a new
Editor Tab" beside the existing in-pane and separate-window items.

Unselected tabs paint their own background. They had none, only
`opacity: 0.55`, so they showed the toolbar colour, which in files mode
is the menubar colour sitting directly above them. `tabbar tab` now
carries `rgba(0, 0, 0, 0.22)` plus an explicit `:hover` rule, since our
provider runs at APPLICATION priority and would otherwise swallow the
theme's hover background. A background was the right layer: the activity
and inactivity washes are drawn inside the tab's snapshot on top of the
CSS box, so they still composite correctly, and the existing opacity
dimming is untouched.

Verification: `zig build`, `zig build test`, `test-core` and
`mux-portable` all green on the merged tree. Each UI change was proven
in a headless sketerm display session with screenshots rather than by
compiling only.

## 2026-08-07: animated sidebar previews, short-clip posters, a cast toggle race

Follow-on wave to the papercut round above, plus two bugs the first
wave's verification turned up.

Animated GIFs autoplay in the file browser's information panel. An
animated-capable LOCAL entry under an 8 MiB source cap now fetches its
ORIGINAL bytes through chunked ranged reads instead of the daemon's
512px still, decodes every frame on the existing thumb worker, and
loops forever in the preview stage, which already auto-sizes to the
image's aspect ratio. Over the cap, an entry whose decode fails, a
video, or anything reached by a user previewer rule keeps today's
still. No transport controls: the sidebar is an ambient preview and
scrubbing is the Viewer's job.

Two consequences were load-bearing. Animated results are never cached,
because one animation outweighs the whole 12-entry texture cache, so
the preloader must skip exactly the entries that would animate or a
warmed still would shadow the animation forever after; both call sites
share one predicate rather than restating the condition. And the
sidebar `Session` had never held more than one frame, so `scheduleNext`
always returned early and NO animation timer had ever existed there.
Introducing one made stopping it a teardown obligation that nothing
satisfied: hiding the panel left it ticking, and the destroy fences set
`widgets_dead` without stopping it, so a tick could publish into a dead
`GtkPicture`. `severPreviewAnimation` now detaches the canvas before
clearing (so the stop publishes to nobody) and runs from both fences
and from panel-hide.

The animation is local-only, and that is the remote preview contract
rather than a size worry: a remote entry fetches bounded codec bytes
that persist in `remote-thumbs/`, so revisiting it costs no traffic at
all, while an animation pulls the whole original and is deliberately
uncached, so every re-selection would re-pull it over the link. A
remote GIF still animates in the Viewer, one click away, where the user
has asked for it.

Videos shorter than the poster seek now produce a poster. `ffmpeg -ss 1`
does not fail on a 0.5s clip: it exits 0 and writes no file at all, so
the daemon reported success for a path that did not exist and the user
got "cannot install thumbnail cache entry" from the install step much
further downstream, which is why this was hard to attribute from the
GUI. Exactly-1.0s clips were broken too, the seek landing at or past
the last frame's PTS. `videoPosterPng` retries once without the seek
when the output is missing or empty, which beats an ffprobe duration
clamp because the thumbnail tier runs no probe today and a clamp would
add a subprocess to every video on every scroll. Normal-length clips
keep byte-identical argv, verified by sha256 across the x-large PNG and
both wire-thumb tiers. `generateThumbPng` now also verifies its output
has bytes before claiming success, as its docblock always promised.

A cast play/pause toggle followed the daemon's last CONFIRMED state, so
two quick presses could both send pause. Instrumenting the long-standing
smoke-e2e failure showed the second Space reaching the key handler 65
microseconds BEFORE the GUI read the first press's `play_state` frame
off the socket; the toggle recomputed from the stale "playing" and sent
pause again, the daemon folded the redundant pause into a no-op and
re-broadcast "paused", and no resume ever came. This was a real user-
reachable defect, not a rig artifact, and the standalone player has the
same shape and passed only on scheduling luck. `CastPlayerBox` now
remembers the kind its last command ASKED for and toggles against that
until the daemon confirms it, with a 2s backstop for commands the
daemon folds into something else (a pause mid-seek broadcasts
"seeking").

That unblocked the quick-look stage, which then failed for an unrelated
rig reason: the driver's window-gone wait counted 200 per ITERATION
rather than by wall clock, and because the daemon withholds app frames
while a busy native stream drains, `pumpOnce` returned instantly and a
nominal 10s wait burned in about 1s, right when the pending resync had
not yet landed. `waitWindowGone` uses a wall-clock deadline plus
`drainLive`, which pumps to the live head including a pending resync.

Verification: `zig build`, `zig build test`, `test-core` and
`mux-portable` green on the merged tree, `ldd sketerm-mux` still libc
and libm only, and `zig build smoke-e2e` PASS twice back to back from a
verified-clean process table, reaching both previously blocked stages.
GIF motion was proven by a burst capture reading frames 0-5 in order
with every frame differing from the last, and the over-cap GIF proven
static by a change-watch that timed out. One intermittent remains,
unreproduced in six of seven runs: `viewerCastStage` once failed to OCR
restored text after navigating back; the OCR timeout path now dumps the
screen and the recognized text for next time.

## 2026-08-07: remote-capable disk usage analyzer

The file browser now opens a disk usage analyzer for its current folder
or a selected directory from the main menu. The analyzer links a
size-sorted hierarchy to a treemap, supports on-disk and apparent-byte
metrics, drills into folders from either view, returns to parent folders,
optionally crosses filesystem boundaries, and can cancel or rescan without
leaving the tab. The same UI works for local and remote locations because
the GUI never reads the filesystem.

Scanning is a new ephemeral daemon file job. Its iterative walker does not
follow descendant symlinks, follows a selected symlinked root once,
deduplicates hard-linked files, detects repeated directory identities from
same-filesystem bind aliases, reports unreadable and skipped content, and
keeps exact aggregate totals. Retained detail is value-prioritized and
bounded to 50,000 wire events plus two 4 MiB raw-path budgets, with half the
event capacity reserved for reachable directories so large files cannot be
starved by wide trees. Progress is paced to two updates per second and job
cancellation remains daemon-authoritative while the GUI suppresses late
progress repaint churn.

The protocol reuses additive JSON fields on the existing `fs_job` frame;
no frame number changed. `fsdrive.JobEvent`, the browser connection binder,
and the per-tab analyzer own the new fields and lifecycle. Analyzer state is
fenced across delayed render callbacks, widget-first teardown, tab closure,
host loss, and remote reconnect. A completed remote result survives a later
disconnect unchanged; only an interrupted scan asks for a rescan.

Tests cover accounting, hard-link and directory-identity deduplication,
sparse-file metrics, selected-root symlinks, retained count and path-byte
bounds, model sorting, hidden remainder calculation, and treemap geometry.
`smoke-fs` now verifies detail and final aggregate events through helper,
daemon, wire, and `fsdrive` in both monolith and broker modes. The analyzer
was also exercised in an isolated headless Files window: both metrics,
table and treemap drill-down, parent navigation, rescan after a fixture
change, and cancellation of a large root scan were driven through the real
GTK UI.

Verification: `zig build`, `zig build smoke-fs`, `mux`, native
`mux-portable`, and `mux-portable -Dportable-target=aarch64-macos` pass;
`ldd zig-out/bin/sketerm-mux` still shows only libc and libm. The direct
full test executable reports 2050 passed, 6 skipped, 0 failed, and the
direct core executable reports 1708 passed, 5 skipped, 0 failed. The two
`zig build test*` listener wrappers still classify tesseract's known
process-exit `ObjectCache` warnings as a failed command after those tests
have passed.

## 2026-08-08: MCP panels follow their mux session without --shared

Live `ui_*` calls now prefer a panel-only connection to the panel's origin
session, independently of the private daemon used by MCP app, terminal,
file and browser tools. The session comes from the explicit tool argument
then `SKETERM_SESSION`; `SKETERM_MUX_SOCKET` selects the exact daemon. When
that variable is absent, compatibility connects only to the canonical
default socket and never autostarts or discovers another daemon.

`paneldrive.zig` keeps nonblocking, deadline-bounded connections keyed by
daemon and session. Requests carry correlation IDs, stale replies are
skipped, and uncertain delivery is surfaced without automatically
resending a mutation. Sessionless calls and unsupported old daemons retain
the explicit direct GUI socket path. `capabilities` now reports
`gui_socket`, `panels`, and structured `panel_transport` state separately.
Store-only behavior is unchanged. This relay-only step kept panel JSON opaque;
the GUI-side remote-image hydration recorded in the next section builds on
that boundary without teaching `paneldrive` about documents.

Core tests cover stale IDs, repeated calls, session-keyed isolation and
no-resend timeout behavior. `smoke-mcp` covers isolated origin routing,
private app-daemon isolation, repeated event polling, live list/save,
missing and unsupported daemons, no viewer, disconnect, timeout, direct
fallback and capability reporting. `zig build test-core`, `zig build
smoke-mcp`, and `git diff --check` pass.

## 2026-08-08: remote mux panels hydrate images on the GUI host

The panel relay now carries remote image panels end to end without adding a
wire frame or linking image libraries into `sketerm-mux`. `paneldrive` keeps
the document opaque. The selected GUI collects `image` and `image_compare`
logical paths, issues bounded ranged `fs_op read` requests on the same
Terminal connection that received the panel request, and stores successful
bytes under their SHA-256 in `$XDG_CACHE_HOME/sketerm/panel-assets`. Decode
and dimension validation remain GUI-only. Local mux and direct-socket panels
keep their ordinary local-file path.

The renderer owns a separate logical-path resolver, so the `Document` never
contains cache names. `panel-get`, `ui_save`, and save/load round trips retain
the remote path byte for byte. Rewriting a file at the same path produces a
new content hash and refreshes both `image` and `image_compare` widgets.
Failures commit explicit per-path placeholders and return structured
`assets`/`asset_failures` reports through `ui_show`, `ui_show_files`, and
`ui_patch` rather than silently drawing nothing.

Show/patch is transactional and serialized per Terminal through hydration and
deferred tab construction. A queued patch is prepared only after its
predecessor commits, so it resolves the actual resulting document rather than
stale paths. The bounds are 64 unique assets,
16 MiB per asset, 64 MiB per operation, four ranged reads, and 30 seconds.
The cache is capped at 256 MiB/2048 blobs per locked process-incarnation
namespace; installs are staged, fsynced and atomically renamed, active hashes
are leased across pruning, and a bounded startup sweep removes complete
unlocked namespaces left by dead GUIs without confusing PID reuse.
Remote reads reject non-regular paths, never block the daemon on a FIFO, and
restat after each range to detect a one-chunk rewrite race. Transport loss
cancels and generation-fences all uncommitted panel work while preserving
already-mounted panels for reconnect.

`smoke-panel-relay` now proves attached ranged reads while terminal events
continue. `smoke-e2e` gives only the fake-SSH daemon an unlinked PNG on fd
900, confirms the GUI did not inherit it, renders `/proc/self/fd/900`, rewrites
that same remote-only path to a different color, and verifies the repaint plus
logical-path preservation through `panel-get`, `ui_save`, and `ui_show load`.

## 2026-08-08: panel relay review hardening

The origin relay now carries both immutable ownership coordinates into every
session child: `SKETERM_SESSION` remains the spawn-time name and
`SKETERM_MUX_SOCKET` is the daemon's canonical absolute listener path. Session
renames retain the origin and each intermediate name as live attachment aliases;
aliases remain reserved against another session until teardown. Spawn, attach,
list and session metadata expose `origin_name`, while `name` remains the current
display identity. The same rules apply in monolith and broker workers.

Panel requester sockets become nonblocking before connect. Connect, `SO_ERROR`
validation, hello/welcome, panel-only attach, queued writes and reply receive all
share one absolute deadline, and the central MCP watchdog can abort a descriptor
created after the tool call began. `ui_wait_event` likewise starts one deadline
before name resolution and passes only the remaining budget to each direct or
relayed exchange and sleep.

Transport selection is deterministic: an exact `SKETERM_MUX_SOCKET` origin,
then an explicit GUI `--socket`, then connect-only canonical-default
compatibility. A GUI socket found by discovery cannot redirect a sessionful
panel mutation. An explicit GUI socket can recover an exact daemon's capability
or attach failure only while delivery is proven not to have started; uncertain
delivery never falls back. `capabilities` reports the direct GUI source separately from the
selected panel source and state. A presenter reply with invalid JSON invalidates
the pooled requester connection and is reported as uncertain delivery without a
retry. Malformed or oversized envelopes whose route id is still readable remove
the daemon route immediately and return the same no-resend guarantee instead of
waiting for the generic route timeout.

Panel-only clients no longer count as terminal viewers or TTL occupancy. Broker
metadata pushes now change-detect and carry the explicit viewer count; newer
clients use it while retaining `clients` as an old-daemon fallback. Direct GUI
deadline reads also accept readable bytes delivered with `POLLHUP`, letting a
one-request server close immediately after its newline reply.

Panel-only teardown now sends `.gone`, and pooled identities consume lifecycle
frames before reuse. Attach metadata must contain the full non-empty immutable
`origin_name`; a missing, empty, or overlong value is malformed rather than
falling back to the requested alias. Direct GUI and mux-relay writes track the
first byte: pre-delivery failures report `mutation_may_have_applied:false` and
`resend_safe:true`, while partial/full writes with a lost reply report uncertain
delivery and are never retried. A lost `panel-events` reply explicitly warns
that events may already have been drained. The direct request cap is 4 MiB while
the panel document parser remains capped at exactly 1 MiB.

Verification: core and full suites; `smoke-mcp`, `smoke-e2e`, `smoke-mux`, and
`smoke-broker` PASS. The smoke coverage includes two daemons with the same
session name, exact/explicit/default/discovered precedence, a safe default relay,
an exact unsupported daemon with explicit direct fallback, an exact 1 MiB
document over direct and relay paths, a long-lived uniquely named private app
proved present only on its private daemon while alive and then closed exactly,
malformed presenter JSON,
multiple renames and inherited-origin attachment in both daemon modes. Native
musl and aarch64-macOS portable mux builds pass.

## 2026-08-08: panel lifetime identity, durable migration, and broker rename hardening

Saved panels now follow one session lifetime rather than a reusable session
name. Every monolith or broker-created session gets a random 128-bit
`origin_id`; spawn/list/session metadata, worker handoff, panel-only attach and
the child environment all carry the same value. The persistence key is now
`(physical canonical daemon socket, origin_id, panel name)` under
`by-origin-v2`, while `origin_name` remains immutable compatibility and
migration metadata. A same-name reincarnation therefore starts with an empty
store, and a rename retains the original store. Old clients ignore the
additive metadata; new panel requesters reject missing or malformed IDs rather
than silently substituting a reusable alias. Daemon-owned requesters also send
their inherited ID as an attach fence, so a stale process cannot bind through
a reused name to the replacement lifetime.

Pre-ID exact daemons use a disjoint `by-legacy-origin-v1` namespace. First v2
access can claim data from `by-origin-v1`, that pre-ID namespace, and the old
global `by-session` layout. Claim/source identities are tagged,
length-prefixed hashes; legacy writers and migrators share `flock` locks.
Atomic publication now syncs files and every newly created ancestor before
deleting a source, and syncs parents after publication, unlink and directory
removal. Fault-injection and racing-writer tests cover the power-loss and
concurrency boundaries. Canonical daemon paths now resolve symlinked existing
parents while preserving nonexistent leaves, with journal migration from both
raw and earlier lexical-only path hashes.

Session rename accounting now caps every non-origin name, including the
current one, while returning to an issued alias remains legal at the cap.
Broker rename is a prepare/commit/final-ack transaction; a worker whose commit
cannot be confirmed is killed by exact pid rather than left live with identity
divergent from the broker, even if its control socket is backpressured.
Presenter retirement classifies each route independently, so
untouched queued requests remain pre-delivery and resend-safe. Relay-to-direct
fallback now consumes one absolute call deadline instead of receiving a fresh
timeout for each transport.

Tests cover lifetime ID propagation and reincarnation isolation, all storage
migrations, injective claim keys, ancestor fsync failures, migration/write
races, physical socket equivalence, journal migration, alias-cap return,
failed broker rename, per-route presenter outcomes, pre-panel store-only MCP,
and the shared fallback deadline. `zig build`, `zig build test-core`, `zig
build test`, `smoke-mcp`, `smoke-mux`, `smoke-broker`, `smoke-e2e`, native
`mux-portable`, and aarch64-macOS `mux-portable` pass. The MCP and Wayland
smokes assert the actual attached `origin_id` and same-name reincarnation
isolation. `ldd zig-out/bin/sketerm-mux` remains libc/libm only.

## 2026-08-09: panel release-gate hardening

Panel RPC is now v2. Every panel-capable Terminal attachment in one GUI
process carries the same random 128-bit endpoint token. A panel-only requester
binds to one token on its first routed call and cannot silently fail over to a
different GUI. Temporary absence returns structured, retry-safe
`panel_endpoint_unavailable`; the same GUI token resumes after reconnect, and
requester reconnect is the explicit endpoint-selection boundary. RPC v1 GUIs
remain valid terminal viewers but are not compatible panel presenters.

The broker shutdown path now queues graceful worker `K` controls, continues
polling backpressured control sockets, and waits for worker control EOF after
the worker flushes `.gone`. A 10-second absolute deadline is the force-retire
backstop. Direct panels retain a liveness-fenced Terminal asset origin; after
that Terminal is destroyed, new unresolved image paths are rejected before
patch commit while non-image and already-resolved edits remain usable.

`ui_wait_event` now distinguishes confirmed panel absence, pre-delivery
unavailability with unknown open/closed and queue state, and uncertain delivery
where events may already have drained. A current daemon with only RPC v1 GUI
viewers reports `no_compatible_gui`; that proven pre-delivery state may use an
explicit direct GUI socket, but selected-endpoint absence, identity mismatch,
and uncertain delivery cannot fall back. Structured daemon failures retain the
healthy requester connection and endpoint binding; partial requester writes
still retire the connection.

The final release audit tightened seven failure boundaries. Every `ui_*` tool
rejects a present non-string `session` before environment fallback or side
effects. A valid but unexpected origin ID is an identity mismatch, not malformed
attach metadata, and remains ineligible for direct fallback. Expired absolute
deadlines are checked before panel connect, hello/attach queueing, flush and
request send, and before direct GUI mutations or event drains, so an already
expired call dispatches no bytes. Migration now propagates source unlink,
source-directory sync and removed-directory parent-sync failures while a retry
preserves the canonical target-wins rule. `panel_endpoint_unavailable` stays a
distinct code through RPC validation, pooled transport, MCP errors and
capabilities, with `reconnect_same_gui_endpoint` and
`reconnect_panel_requester` as machine-readable recovery actions. Finally, the
relay smoke waits to observe the full `{total:4,guis:2,drivers:2}` roster under
one deadline instead of assuming it appears in the first four metadata frames.

Focused tests cover endpoint A/B stickiness and requester reconnect, queued
broker shutdown under forced backpressure, event delivery-state wording, and
requester connection retention. Audit regressions cover every invalid JSON
session type across all eight `ui_*` tools, origin mismatch classification,
zero-byte expired mux and direct dispatch, migration cleanup retry, endpoint
error/capability recovery metadata, and complete peer-roster observation.
`smoke-panel-relay` runs the endpoint contract in monolith and broker modes,
`smoke-mcp` covers current-daemon plus legacy-GUI direct fallback, and
`smoke-e2e` destroys a direct panel's source Terminal before an image patch.

The final scope audit varies both registry coordinates independently: changing
only the process endpoint or only `origin_id` creates a disjoint namespace,
while exact duplicate attachments share one pointer-stable scope. The real GUI
smoke attaches two panes from one process to one lifetime, shows through the
oldest daemon-selected presenter, closes it, reads the same panel through the
survivor, closes the last viewer, then reattaches the same endpoint and proves
the old panel is gone. This churn exposed a separate context-menu lifetime bug:
GTK closure destroy-notifies outlived `Pane.menu_arena`. Menu contexts are now
allocated from their recorded allocator and owned only by those closures.

Prepared images now have document-wide 32 MP and 128 MiB ceilings in addition
to the existing per-image and encoded-operation limits. Unit tests inject all
64 individually valid maximum-size image headers without allocating pixels,
exercise rowstride-byte overflow independently of the pixel limit, and compose
concurrent half-budget updates at the exact boundary. The excess mapping
becomes an explicit failure, retains no cache lease, and leaves the live
resolver at exactly the aggregate ceiling. Transport loss still preserves
already-committed direct local hydration while canceling relay mutations;
permanent origin teardown clears `panel_assets_live`, cancels the hydration,
and rejects unresolved image patches before document commit.

The GUI now also limits native panel hosts to 8 per exact relay scope and 32
for the whole process, including direct-socket panels. Deferred tab creation
reserves both slots before spawning its pane and releases them on every failed
or canceled path; replacing an existing name consumes no slot. Relay show,
patch and close operations share one scope lane through image hydration and
deferred tab construction, so a close cannot acknowledge before an older show
has committed and then let that show recreate the panel.

Decoded panel images have a process-wide 128 MP/512 MiB ceiling. Header
dimensions reserve that aggregate before the full pixbuf decode, decoded
rowstride reconciles the reservation atomically, and failure/cancellation
releases it. The charge then moves into the prepared-image lease shared by the
resolver and widgets: GtkPicture qdata and image-compare sides retain that
lease, so deferred GTK or accessibility widget references retain the process
charge too.

Closing one of several same-process viewers now rehosts its shared pane panel
onto an empty surviving same-scope pane without changing the panel id, target,
or pane tree. An occupied survivor is deliberately not evicted; if no empty
survivor exists, the departing viewer's pane panel closes. The end-to-end
assertions wait through only the explicit transient `panel_endpoint_unavailable`
state while daemon presenter/controller handoff catches up.

Verification: `zig build test` reports 2187 passed and 6 skipped; `zig build
test-core` reports 1793 passed and 5 skipped. `smoke-mux`, `smoke-broker`,
`smoke-mcp`, and the complete Wayland `smoke-e2e` pass. Native x86-64 musl and
aarch64-macOS `mux-portable` builds pass, `git diff --check` is clean, and
native daemon `ldd` lists only libc/libm plus the loader.

## 2026-08-10: panel review fallout — delete the invented complexity

A review of the whole uncommitted panel change set found the feature itself
correct and end-to-end proven, and a large amount of hardening around it that
nobody asked for and that made the product worse. This entry is the removal.

**A GUI restart no longer wedges panels.** The daemon binds a panel requester
to one GUI process token so a follow-up `ui_patch` cannot land on a different
GUI than the `ui_show` did. That binding was only ever cleared on detach, and
the MCP pool kept the connection alive across `panel_endpoint_unavailable` — so
restarting sketerm left every later `ui_*` call failing forever, advising the
model to "reconnect the panel requester", which it has no way to do. The pooled
connection is now dropped on that exact failure. Nothing was delivered when it
is reported, so the next call simply rebinds to whichever compatible GUI is
attached. `smoke-mcp` proves the recovery with a second presenter process.

**Panel persistence went from five namespaces to three.** `by-origin-v2`,
`by-origin-v1`, `by-legacy-origin-v1`, two claim directories, two lock
directories, `flock`-serialized migration, permanent length-prefixed-hash
ownership records, fsync-of-every-created-ancestor, `renameNoReplace`
publication and a `CommittedNotDurable` error class all existed to migrate
between namespaces that had never shipped: `git show HEAD:src/ipc/panelstore.zig`
knows only `by-session` and `no-session`. What remains is
`by-origin/<sha256(socket)>/<origin_id>/` for a session reached through a known
daemon, `by-session/<encoded>/` for a session without one, `no-session/` for no
session at all, and nothing migrating between them. A panel document is cheap
to re-save; a migration a crash can only leave half-done is not worth carrying.
Writes are still staged and renamed, so a save either happened or did not.
`OriginScope` lost `origin_name` and `legacy_session` (both migration-only) and
gained a diagnostics-only `label`. 588 lines of tests for the deleted machinery
went with it; the two that used compile-time fault injection were rewritten to
use a real read-only directory instead.

**The live-panel caps are gone.** `MAX_LIVE_PANELS_PER_RELAY_SCOPE = 8` and
`MAX_LIVE_PANELS_PROCESS = 32`, plus the `PanelSlot` reserve/release
transaction threaded through deferred tab construction, restricted a legitimate
user action nobody had complained about — and asymmetrically, since direct
control-socket panels were never scope-capped. The `smoke-e2e` stage that
proved the refusal now proves the opposite: twelve panels across pane, tab and
window targets coexist in one scope, same-name replacement reuses the panel in
place, and all of them close. The image-memory budgets are unrelated and stay:
those bound decoding untrusted files into RAM.

**A bad presenter reply no longer costs a GUI its panels.** `retirePanelPresenter`
set `panel_rpc = 0` on the attachment, so one malformed reply from one handler
silently turned off panels for that whole GUI until the user reattached. It is
now `failPanelPresenterRoutes`: in-flight routes still fail with their exact
per-route delivery classification, and the presenter keeps its capability, so a
handler bug surfaces on every call instead of hiding behind a dead feature.

**Tool descriptions are edited, not rewritten at runtime.** `renderedToolsJson`
chained ten `replaceAll` calls against exact legacy sentences and then reparsed
and re-serialized the entire ~104-tool document to append a paragraph. It was
fragile by construction, and it had already failed: `ui_show_files` says "start
this server with --shared" while the replacement targeted "start the MCP server
with --shared", so that tool advertised the removed requirement the whole time.
The guidance now lives in the `TOOLS_JSON` literals. The `%..._DEF%` timing
substitution stays — that one exists so the schema cannot drift from `Tuning`.

**Eleven `SKETERM_TEST_*` fault-injection env hooks are gone from the shipped
binary.** Zero existed before this work. Each was a live branch in a production
path (image decode, local file read, cache init, panel-tab construction, picker
IO, reconnect) whose only purpose was letting a smoke stage wedge a race. The
`test_delay_ms` fields survive as plain fields that in-process unit tests set
directly, which is where that kind of control belongs.

**`CLAUDE.md`'s threading rule was false and is corrected.** The GUI is no
longer single-threaded: panel transport setup, asset file reads and GdkPixbuf
decode run on short-lived detached workers. The rule now states the actual
contract — those workers touch no GTK or Screen state, hand back through
`g_idle_add`, and only the idle handback frees the job.

Also deduplicated along the way: the daemon's four near-identical panel-failure
reply builders (one of which duplicated a whole struct literal just to add an
optional field) collapsed into one `queuePanelFailure`, and `uiStoreScope`'s
five repetitions of the same by-session fallback into one named value.

Removing the hooks cost four smoke assertions that only held because of an
injected stall — "the tab setup has not finished yet", "the decode overlapped
the probe", "the picker IO overlapped", and a transport loss aimed at a
worker's artificial delay. The surrounding probes are kept, because those
measure the real invariant (the GTK loop answered a control request within
600ms while the work ran) without needing the work to be artificially slow.
The transport-loss sub-stage was dropped; the lifetime-fence sub-stage next to
it now kills and respawns the session name directly, which needs no injection.
The in-flight-decode-versus-teardown race became a straight teardown stage: the
origin closes, a later patch into it is refused, and the GUI stays healthy.

Verification: `zig build`, `test`, `test-core`, `mux-portable`,
`mux-portable -Dportable-target=aarch64-macos`, `smoke-mux`, `smoke-broker`,
`smoke-mcp` and the full Wayland `smoke-e2e` all pass; `git diff --check` is
clean and `ldd zig-out/bin/sketerm-mux` still lists only libc/libm plus the
loader. `smoke-e2e` is timing-sensitive under heavy parallel load — two runs
during this work failed at unrelated late stages and passed on a quiet box.

## 2026-08-10: panel review follow-up - safety, opacity, and scope cleanup

A full line-read of the uncommitted panel work found nine issues; all are
fixed here.

**Tab adoption could write out of bounds.** `Window.adoptPane` used
`appendAssumeCapacity` on the strength of a comment saying every foreign
attach reserves first. Two paths do (`transferPageFrom`, `onCreateWindow`),
but a page can also arrive by dragging between two tab OVERVIEWS, which
reaches `onPageAttached` with nothing reserved - an out-of-bounds write in a
ReleaseFast-only build. `adoptPane` now reserves for itself, before
unhooking the source; the up-front reservations stay so a doomed move is
still refused before libadwaita reparents anything.

**`fs_op read` stopped answering for files that grow under it.** The
second-`fstat` "file changed during read" check was added for panel assets
but sits on the path behind MCP `file_read`, browser previews and ranged
downloads, so reading a live log became an error. It is gone; the panel path
already compares `size`/`mtime`/`ino` across replies itself
(`Terminal.handleRemoteFileReply`). The `O_NONBLOCK` open and the regular-file
check stay - a FIFO path must not park the daemon's poll loop.

**The daemon no longer parses panel JSON at all.** It was calling
`panelrpc.requestOp` on every request and `validateReply` on every reply,
which meant a full JSON parse of up to 4 MiB inside the single-threaded poll
loop, stalling every other session, and contradicted the documented
relay-is-opaque invariant. Both are removed along with `PanelRoute.op`;
the daemon inspects only the envelope. Reply validation was always duplicated
on the MCP side, which is where it belongs and where it is tested.

**Refusing to reconnect now says why.** A daemon older than session identity
sends no lifetime id, and `transportLost` closed such panes permanently with
a message that did not name the cause. It now states that the daemon reports
no lifetime id and that restarting `sketerm-mux` is the fix.

**Two thirds of the fs-journal migration was self-inflicted.** Introducing
`canonicalSocketPath` changed the hash of every existing job directory, and
three extra namespace migrations plus staged-copy/fsync/re-parse machinery
were written to cover the break. Pre-release, that is not worth carrying:
only the original pre-state-dir socket-sibling adoption remains, as rename
with a staged-copy EXDEV fallback (~45 lines instead of ~200).

**Relay scopes are freed again.** `RelayScope` was retained forever as an
async-handback tombstone, so every session lifetime a GUI ever attached to
leaked one. `releaseRelayScopeIfIdle` frees it once no viewer, hydration,
queued operation, panel-tab job or registry entry can still name it.

**`capabilities` is a preflight again.** It was opening a relay connection
with a 40s budget and calling `panelstore.validateScope`, which CREATED the
store directory and wrote a probe file - side effects in a read-only report.
The probe now runs under its own 2s deadline, `validateScope` is deleted, and
`panels_store` reports whether the scope RESOLVES. A filesystem that refuses
the write is reported by `ui_save`, which already says so exactly.

**Then the over-built layers came out.** The review flagged three of them as
disproportionate to "show a panel through the daemon", and they are gone:

- **Two image budgets became one.** A per-document 32MP/128MiB budget sat on
  top of the process-wide 128MP/512MiB one, double-counting the same bytes and
  threading `prepared_budget` through Hydration, CacheJob, Resolver and the
  decode path. Only the process budget remains, still reserved from header
  dimensions before decode and reconciled to the actual rowstride.
- **Session alias history is gone.** A session answers to its current name and
  to its immutable spawn name; nothing else. The bounded 16-entry history, its
  cap arithmetic, `PreparedIdentity` and the reserved-forever semantics served
  no request anyone made, and an unbounded set of names one session routes
  under is a hazard rather than a feature.
- **Broker rename is one authoritative step again.** The broker renames its
  own record and sends the worker one `R`; a worker forwards an attached
  client's request as `N` and answers from the broker's `n`. The
  prepare/commit/abort transaction, transaction ids, retries, deadlines and
  kill-the-worker-on-missing-ack are deleted. The broker's record is what
  routes, so a worker that misses the `R` only shows a stale display name.
- **The broker/worker control queue is gone.** `ControlOut`, POLLOUT wiring,
  per-packet deadlines, graceful-termination bookkeeping and the shutdown
  admission control were ~450 lines guarding a datagram socket that carries a
  handful of small messages. Control sends are plain `sendmsg` again; the one
  whose loss a client can actually see, the `A` client-fd handoff, now reports
  the failure to that client instead of dropping the descriptor.

`identity_first` was considered for removal and kept: without it there is a
window between attach and the first `session_meta` in which a transport loss
would close the pane permanently, so it earns its wire capability.

Also: a dead `platform` import in `panelstore.zig`, and the retroactive
"historical transport at this revision" amendments to older SESSION entries
are reverted - this log is chronological, and superseding notes belong in the
entry that supersedes.

Verification: `zig build`, `test`, `test-core`, `mux-portable`,
`mux-portable -Dportable-target=aarch64-macos`, `smoke-mux`, `smoke-broker`,
`smoke-mcp` and `smoke-e2e` all RC=0; `ldd zig-out/bin/sketerm-mux` is still
libc/libm; `git diff --check` clean. The daemon relay test now proves opacity
directly (a non-JSON reply body is relayed byte for byte) and drives
per-route delivery classification from a malformed ENVELOPE instead of an
invalid document.

## 2026-08-10: panel review round three - full residue sweep

A four-way line-level audit of the entire uncommitted panel diff (mux daemon,
GUI presenter, MCP/persistence, docs+tests) found ~45 pieces of residue the
two earlier cleanup rounds missed, plus three latent defects. All fixed:

Defects: session death/exit now clears the client's panel endpoint binding
through one shared `clearClientAttachment` (removeSession/sessionExited had
hand-rolled a subset that left `panel_endpoint_valid=true` on unattached
clients); a rename requester dying before the broker's `n` reply no longer
wedges the worker's rename slot (cleared in the dead-client sweep); an
OOM-path relay scope orphan in `attachOrigin` now releases through
`releaseRelayScopeIfIdle`.

Dead code deleted: the unreachable `error.AliasLimit` branch and its
"historical alias limit" message; `spawnCastSession` and
`connectPanelRequesterFromEnv` (zero callers); panelstore's entire unscoped
API (`save`/`load`/`exists`/`delete`/`list` and friends - production is
`*Scoped`-only; tests ported); `panelrpc.requestOp` (relay replies are now
validated once, in paneldrive, keyed by `opFromCommand`); the write-only
per-document `prepared_info` chain; three never-set `test_delay_ms` fields
and their dead branches; the revision fence `installAssetResolver` could
never trip; the test-only `runPanelTabWorker` fn-pointer seam;
`Pool.activeFd`; `RelayScope.attachments` (mirror of `viewers.items.len`);
two dead test helpers; three tool-list asserts locking phrases that never
existed.

Dedup/simplification: hydration construction shares one
`startHydrationOperation` (id wraparound written once); rename validation
and the 64-byte name bound live in one `MAX_SESSION_NAME`; `workerShutdown`
shared by the EOF and `K` paths; `fsJobsDirAlloc` canonicalizes internally
again (the one path rule); `uiStoreScope` takes an explicit deadline
(capabilities passes its 2s probe budget); store READ paths no longer create
directories or write the origin marker (save-only, with a
nothing-on-disk test); the unreachable `.legacy_daemon` arm collapsed; the
`panel_endpoint_unavailable` error is prose like every other arm; session
origin id validation moved to `wire.zig` so panelstore no longer imports the
daemon; `deferredWindowFree` no longer busy-spins (completion-driven free);
`closeEntry`'s `.window => unreachable` is a `return` (ReleaseFast UB);
panelhost's GTK trampolines and `PreparedLease` now carry canary magic words
like every other panel module.

Docs/tests: the `CommittedNotDurable` paragraph (documented a deleted error),
the `--shared`-requirement paragraph (a test asserts the opposite), and
"serialized per Terminal" (it is per RelayScope) are corrected; the five
smoke-e2e probes that only made sense with the deleted fault-injection
stalls were rebuilt as real fences (overlapping liveness probes, a positive
old-lifetime-gone fence plus held-refusal window, `waitPaneGone` plus exact
dead-origin error codes, bounded panel-list polls instead of settle sleeps).

## 2026-08-10: panel scope decision - endpoint identity out, cache and codes stay

After the residue sweep, one more deliberate scope cut and two deliberate
keeps, decided with Jelle:

Removed: the per-GUI-process panel endpoint identity layer (32-hex endpoint
tokens in attach metadata, requester-to-endpoint binding in the daemon, the
`panel_endpoint_unavailable` failure code and the MCP invalidate-on-that-code
recovery dance, the `(endpoint token, origin_id)` GUI registry key).
PANEL_RPC_VERSION is back to 1; `PassedClient` shrank 45 -> 12 wire bytes.
Replacement routing is stateless: the daemon delivers a panel request to THE
panel-capable attachment of the session (earliest by client id when several
exist); when it goes away the next request selects whoever is attached, and
no candidate is a pre-delivery `no_compatible_gui`. The layer's only
observable behavior was its failure mode (a restarted GUI left a stale
binding that wedged every later ui_show until the recovery dance ran); the
stateless rule makes that wedge impossible by construction and is the right
base for panel mirroring (deliver to ALL attachments) if that is ever wanted.
Renumbering exposed one silent test rot: the "legacy v1 viewer" smoke fixture
had become a compatible presenter when v1 became current; it now attaches
with no panel_rpc at all.

Kept, deliberately (proposed for deletion, rejected on review): the on-disk
content-addressed asset cache (real benefit for image re-shows over SSH and
across GUI restarts; already built and proven) and the granular
machine-readable panel failure codes (an assistant branching on `error_code`
is more reliable than one parsing prose; already tested end to end). The
line between these and the endpoint layer: the cache and the codes have a
user; the endpoint binding only had a failure mode.

## 2026-08-10: two e2e reds root-caused - one product race, one test geometry

The recurring smoke-e2e failures were not load flake. (1) Real race: the
deferred window free (gated behind pending page-detach idles) extended the
window in which the AdwStyleManager theme handler could fire into a
destroyed secondary window's pane widgets - "GUI stopped serving after a
secondary window was closed under a theme flip". Fixed structurally:
`onWindowDestroyed` severs the process-global handlers immediately
(idempotent with deinit's call), and `onThemeChanged` gained a `destroying`
guard. (2) Test bug, root-caused from a failure
screenshot after a first geometry hypothesis proved wrong: the picker
stage's close-confirm cancel pressed Escape without waiting for the
AdwAlertDialog to map. When Escape raced the dialog, the ORPHANED MODAL's
scrim dimmed the whole window for every later stage, shifting each pixel
just enough that the pane-face stage's exact-color probe (>=400 exact
matches) failed while the panel had rendered perfectly (traced: prepared
lease installed, updateOne=true; screenshot showed the dialog over a
correct panel). Two instances of the same
race class were found and fenced: the close-confirm Escape and the
teardown picker's Escape (fired 150ms after the chord, before the picker
mapped). Both now wait for the modal to visibly appear, then require the
visual change of it closing, retrying Escape; the pane-face probe dumps
every window as PNG before failing so the next silent pixel mismatch
names itself. Neither failure was the "known flaky stages"
pattern - both attributions were wrong and both had real causes.

## 2026-08-10: the "flaky" e2e stages were four real bugs

Runs that had been written off as load flake were chased to root cause with
failure screenshots, core-dump capture and a pid-aware fuse. Four distinct
causes, none of them flake:

1. The close-tab confirm's Escape raced the AdwAlertDialog's asynchronous
   presentation. The orphaned modal's scrim then dimmed every later window,
   which broke the pane-face stage's exact-color probe -- that is what the
   wandering "pane panel image did not decode" red always was.
2. The teardown picker's Escape had the same race (fired 150ms after the
   chord). Both sites now wait for the modal to appear, settle its open
   animation, and require the visual change of it closing.
3. The theme-flip stage identified its detached window by diffing a window
   snapshot taken BEFORE it forked the theme GUI. The control socket exists
   before the toplevel reaches the hub, so the GUI's own primary window
   could qualify as the "secondary" -- and closing a primary quits the
   application (a clean exit: no core, no panic, socket gone). The stage now
   pins both windows by the app_id that instance sets for exactly this
   purpose, polling for each rather than assuming announcement order.
4. A genuine product hazard found while chasing 3: the deferred window free
   can be gated behind pending page-detach idles, leaving the destroyed
   window's AdwStyleManager handler connected. Severing global signals at
   destroy (idempotent with deinit) fixed it -- real, though not the cause
   of 3.

Verification: 10/10 consecutive smoke-e2e passes at loads 2.4-19.3. The one
genuinely load-sensitive stage is the OCR hex dump, which fails above load
~50 because tesseract cannot finish inside its deadline; unrelated runaway
processes on the box were the cause both times that appeared.

## 2026-08-10: integrated browser, phase 1 - CEF helper + web pane face

The browser feature (design: untracked docs/proposal-browser*.md; engine
decision CEF after a six-item spike proved Zig binding, headless OSR,
trusted input, Widevine key-system access, and per-request-context SOCKS
egress) landed its first vertical slice, orchestrated as reviewed agent
tasks with a commit per piece:

- `zig build fetch-cef` caches the pinned prebuilt CEF distro (default
  build never touches it or the network); `zig build web` builds
  `sketerm-web`, a single-threaded windowless-CEF helper speaking an
  engine-agnostic protocol v1 (src/web/protocol.zig, append-only tags,
  memfd+SCM_RIGHTS frames, XKB keysyms on the wire). The LD_PRELOAD
  re-exec inside main works around Zig's DT_NEEDED order breaking
  libcef's RTLD_NEXT close lookup (SIGTRAP otherwise). cef_api_hash
  must be the first libcef call - it configures the API version, and
  without it cef_execute_process spins forever with zero syscalls.
- `zig build smoke-web`: eight-stage rig (handshake, pixel-checked
  paint, trusted click, typing, resize buffer swap, popup-request
  event, history, teardown) that speaks protocol.zig itself.
- new_web_tab/new_web_split: a web pane face (src/ui/webface.zig) -
  chrome bar + GtkPicture over the helper's frames, one lazily-spawned
  helper per GUI, popups become new web tabs, missing helper degrades
  to a hint label, helper death to a Reload overlay. Proven headless:
  example.com render, link click, two concurrent views, crash-restart
  cycle, exact channel order via an orange test page.

Known v1 limits (deliberate): 1x scale only, full-texture upload per
damage batch (GL/ImagePass upgrade planned, damage rects already on the
wire), no IME into pages yet, global keybinds win over the page.

## 2026-08-10: browser identity + distro CEF (the codec risk collapsed)

`sketerm-web` is now the GUI's browser IDENTITY hardlink (argv0
dispatch, own app id / title / icon / desktop entry, http+https scheme
handlers so it can be the default browser) exactly like
`sketerm-files`; the CEF helper was renamed `sketerm-webengine` to free
that name. Verified headless: app_id `dev.sker.sketerm.web` for both
spellings, files/terminal identities unregressed.

`makepkg -si` builds and installs the browser automatically, and does
it by DEPENDING on the distro `cef` package rather than shipping
Chromium. Measured, not assumed: Arch's cef 150.0.17 has
proprietary_codecs ON — h264 and aac probe true (the upstream tarball
has both false), and Widevine grants an avc1 key-system access once a
CDM is seeded. That deletes the "build codec-enabled Chromium
ourselves" workstream that looked like the feature's biggest risk, and
keeps ~300MB out of the package. build.zig grew -Dcef-include /
-Dcef-lib (split system layout) and -Dcef-runtime-dir (rpath +
LD_PRELOAD target when the runtime lives elsewhere at install time);
`zig build fetch-cef` remains the dev path and now checks a pinned
SHA-256. All 8 smoke-web stages pass against the system CEF.

## 2026-08-10: `web_*` MCP tools; the CDP `browser_*` family deleted

Browser automation now drives the GUI's OWN web views instead of an
external Chromium: MCP -> GUI control socket -> `src/ui/webface.zig` ->
the one `sketerm-webengine` connection -> the view backing a pane. The
handle is the PANE id, so it matches `list_terminals`; a click is real
trusted input on the pixels the user is looking at.

Twelve tools (`src/ipc/mcp_web.zig`): web_tabs, web_open, web_navigate,
web_snapshot, web_act, web_expand, web_query, web_read, web_wait,
web_scroll, web_eval, web_screenshot (the last one reuses
`screenshot_pane`'s capture path, and the GUI's `screenshot` command
now photographs a web-visible pane as the PAGE). `web_network` is
deliberately absent until the 0x80 interception frames exist.

Semantic operations are asynchronous and the control socket answers
synchronously, so `web-request` returns a TOKEN and `web-result` polls
it — the `ui_wait_event` shape, and for the same reason: the GLib loop
must keep running for the helper's reply to arrive. One operation of
each kind per view; in-flight ops are dropped on helper restart and
expire after 120s. Unsolicited deltas from the mutation observer are
BUFFERED in the face: dropping them made the next snapshot say
"nothing changed" about the very change it was asked for.

New protocol frames `sem_eval`/`sem_eval_result` (0xA0 block): the
result is serialized in-page with graceful degradation (undefined,
functions, symbols, cycles -> described placeholders; DOM elements ->
`{semantic_id, role, name}`, rewritten helper-side from engine-local
ids so they feed straight back into web_act), `await` resolves a
promise inside the budget, an exception returns message AND stack, and
a big result truncates with a `web_expand id=0` paging affordance.

Nothing from the old set was dropped except `browser_path` (it named an
external Chromium to launch — the thing this removes). The two
capabilities worth naming: `browser_choose` became `web_act set_value`,
which now picks a native `<select>` by option TEXT or value (including
one inside an open shadow root) and drives a custom ARIA dropdown with
a trusted click to open, a shadow-piercing poll for the appearing
`[role=option]`, and a trusted click on the match; `browser_form_state`
became ordinary snapshot content — the walk carries required, invalid
(validity + aria-invalid), checked, disabled, readonly and the current
value, with passwords reported as a LENGTH, never their content. The
walk also descends open shadow roots now.

Deleted: `src/ipc/mcp_browser.zig`, `src/ipc/cdp.zig`, the CDP session
state in mcp.zig, and every `browser_*` name in TOOLS_JSON and
`mcpfilter.TOOL_META` (the `browser` policy group stays and now selects
the web tools). `capabilities` reports `web_helper` instead of a
Chromium binary path.

smoke-web grew stages 15-17 (eval, both dropdown kinds, form
validation state) and is green on both the pinned CEF and the system
one. The tools were also driven end to end through a real `sketerm mcp`
process against a headless GUI: open -> snapshot -> trusted click (the
page reported `isTrusted true`) -> delta -> eval -> read -> scroll ->
wait -> screenshot.

## 2026-08-10: adaptive browser frame pacing — the client drives the frames

CEF's windowless (OSR) path schedules its own paints and clamps
`windowless_frame_rate` at 60, so a browser pane could never follow a
120Hz or 165Hz output, and an idle page still got a 60Hz scheduler
running behind it. Every helper browser is now created with
`external_begin_frame_enabled`: the engine paints exactly once per
`send_external_begin_frame` and never on its own. The flag is fixed at
browser creation, so all adaptivity lives in how often somebody asks.

Asking is the GUI's job. `src/web/pace.zig` is the (GTK-free,
unit-tested) state machine and `src/ui/webface.zig` the GTK half:

- IDLE — a 5Hz GLib timeout, and NO frame-clock tick. That is the KWin
  crash guard from `terminal_surface.zig`'s `tick_id` doc, not an
  optimisation: an installed tick cycles GDK's frame clock at monitor
  refresh even when nothing is drawn, leaking a Wayland object id per
  offload subsurface per cycle.
- ACTIVE — a tick on the picture widget, paced from
  `gdk_frame_clock_get_refresh_info` (so it follows the output the
  window is actually on) and clamped by the new app-level
  `browser_max_fps` config key (0 = follow the display).
- Any input, navigation, resize or automation call promotes instantly;
  ~250ms of requests that produced no paint demotes, and the tick then
  REMOVES ITSELF exactly like the terminal surface's animation tick.
- A background tab's picture is unmapped, which now sends `view_hide`
  (the face never sent it before) and stops the pacing entirely.

New wire frame `frame_request` (0x33, client -> helper). There is
deliberately no per-request ack: "did this produce pixels" is already
observable as a `frame_damage`, and an ack would double the socket
traffic of the whole path. WATCHDOG: a client that stops asking would
freeze its pages indefinitely, so the helper self-paces any visible view
that has gone 250ms without a begin frame — 4fps, alive and obviously
degraded. The GUI's idle floor is faster on purpose, so a live GUI is
always the pacer.

MEASURED (Arch, CEF 151, software raster). smoke-web, animating page at
640x480: 228 paints in 2.00s = **114 fps** driven at 227 requests/s
(before: exactly 60, the cap); at a 30/s request rate, 29 paints/s.
Static page: 354 begin frames, **0 paints** over 3s. Watchdog with zero
client requests: 6 paints in 1.5s. Click-to-paint: 11-29ms. Isolated
GUI (private mux display session, 60Hz virtual output), background tab
holding an animating page over 10s: **before** 60fps of frames
delivered for a tab nobody can see, 98 jiffies of helper CPU and
110MiB/s of buffer traffic; **after** zero frames, 7 jiffies. Idle
static page is unchanged at ~0 (0-1 GUI jiffies, 6-9 helper jiffies per
10s — headless OSR was already cheap when nothing damaged). Foreground
animating page at 60Hz costs slightly MORE helper CPU than before (146
vs 113 jiffies/10s): externalising the frame source adds a socket
wakeup per frame. `SKETERM_WEB_PACE=1` logs every transition and aborts
if an idle face ever holds a tick — verified over 131 idle intervals in
the isolated GUI, all `tick_id=0`.

smoke-web grew stages 19-22 (frame rate uncapped + capped, idle page
costs zero paints, watchdog, input-to-paint latency) and every stage now
drives begin frames while it waits; stage 6's click is retried, since a
page whose first compositor frame has not landed swallows input.

## Browser: input latency and fractional-scale sharpness (2026-08-11)

Two user-facing defects, both root-caused with instrumentation before
any fix (`SKETERM_WEB_LAT` hover probe in webface, `hostlat:` trace in
cefhost, and the new `zig build measure-web` rig — a smoke-e2e-shaped
display-session harness that can set a FRACTIONAL viewer scale via a
`set_scale` intent, plus `SKETERM_WEB_DUMP` for the engine's raw
buffer).

**Hover latency ("UNUSABLE"):** external begin frames carry a constant
~30ms input->paint penalty. The helper trace showed a hover's paint
landing only after the 2nd-3rd begin frame REGARDLESS of their spacing
— an immediate begin frame on input, a 0.3/5/10/15ms burst, and every
windowless_frame_rate from 60 to 1000 all left input->paint pinned at
39ms, while CEF's internal scheduler does the same work in 5-19ms. So
the default is now the internal scheduler; `frame_request` became
advisory (watchdog keep-alive) and the cap moved to the append-only
`view_max_fps` frame (0x15), applied per view through
`set_windowless_frame_rate` — the GUI ships `browser_max_fps` clamped
to the CURRENT output's refresh and re-ships it when the window
changes outputs. MEASURED (60Hz session, idle start, the user's exact
scenario): input->first-paint-arrival 39ms -> 5.7ms, input->pixel in
our framebuffer 52ms -> 18ms; smoke-web click-to-paint 6ms; static
page still 0 paints; view_max_fps 30 delivers exactly 30/s and 5
bounds an unattended animating page to 7 paints/1.5s. The idle no-tick
invariant is untouched (verified under SKETERM_WEB_PACE).

**Soft/blurry text at fractional scale:** the GtkGLArea framebuffer is
at GTK's INTEGER scale (2 on the 1.5 desktop), so CEF's true-1.5 frame
was resampled TWICE (web_pass 1.5->2 linear, then GSK 2->1.5).
MEASURED at 1.5: a 1px-stripe page leaves the engine with hard 0/255
edges and reached the screen as [5,117,127] mush (extreme-pixel
fraction 0.33). Frames are now presented as GdkTextures on a
GtkPicture in GTK's scene graph, which GSK composites at the REAL
fractional scale: dma-buf frames via GdkDmabufTextureBuilder (GSK
imports, still zero-copy, cached per pool id), shm frames via
GdkMemoryTextureBuilder with `update_texture`/`update_region` so GSK
uploads ONLY the damage rects (the old GL pass's economy, now GTK's
job — measured 60fps steady, ~50us/frame client cost on an animating
1500x840 page). `render/web_pass.zig` and the EGL importer are
deleted. THE ALIGNMENT CATCH: a 1:1 texture at a half-device-pixel
offset measurably collapses 1px stripes into uniform gray, so
`snapAlignment` nudges the picture onto the device pixel grid by whole
logical pixels (<=1 at 1.5, <=3 at 1.25) and input coordinates
subtract the nudge. After: presented pixels are BIT-EXACT against the
engine buffer (extreme fraction 1.00), text hard-edge count 60 ->
1615 in the same band. Residual vs Firefox: Chromium's software OSR
raster is grayscale-AA — 0 of 6793 ink pixels carry color even with
an opaque background_color and --enable-lcd-text (both kept; the GPU
raster path may honour the flag and is only verifiable on real
hardware).

## 2026-08-11: headless `web_*` — the browser tools work with NO GUI

The `web_*` family hard-failed with "no GUI control socket ... restart
with --shared" in the DEFAULT isolated MCP mode — the mode assistants
actually run in, which made the whole family unusable out of the box
(the same failure shape as the old bare `gui_socket:false`).

New `src/ipc/webdrive.zig` (appdrive's sibling: GTK-free, in both test
roots): the MCP server spawns and owns a `sketerm-webengine` of its
own on `<instance-dir>/web.sock` (+ `web.json` presence metadata, +
`web-cache` profile — all torn down with the instance), speaks the v1
protocol directly (hello identity `sketerm-mcp[:name]`), and runs the
semantic round trips itself under non-blocking deadline IO. Backend
selection lives in ONE place (`pick` in mcp_web.zig): GUI socket
attached -> the user's real tabs exactly as before (handle = pane id);
no GUI -> headless helper views (handle = view id, reported as
`"view"` — never dressed up as a pane). All twelve tools share the
same handlers and formatting; `web_screenshot` headless encodes a PNG
from the shm frame (`png.encodeRgba`), and `web_open` takes
width/height (default 1280x800) headless. `capabilities` now reports
`web`/`web_backend` and says the tools work RIGHT NOW with no GUI.
Helper-binary lookup deduped into `src/web/findbin.zig` (webface +
webdrive + capabilities all use it).

Also fixed: deleting `mcp_browser.zig` (CDP removal) had taken
`mkdirs` with it, so `recDir()` never created the mcp-casts dir and
terminal auto-recording silently turned off (smoke-mcp caught it).

Validation: smoke-mcp grew a headless web stage (isolated, no GUI:
open file:// page -> snapshot ids -> trusted click with delta ->
eval-mutation proven in a follow-up delta -> web_read -> real PNG ->
teardown reaps the helper); smoke-web 25/25 on pinned CEF (distro CEF
build currently needs glibc 2.44, host has 2.43 — pre-existing);
mux-portable green. Forward-compat kept for a future "view along":
discoverable socket + presence file, no new single-client assumptions,
frame delivery isolated behind one seam (inline-frames family would be
a new arm, not a rewrite).

## 2026-08-11: coalesced semantic deltas — churn cancels instead of replaying

Field waste bug: on a self-mutating page, one `web_snapshot` answered
with a base tree plus a replay of every intermediate revision (~19k
chars where ~10k carried the information; two 56-node blocks were the
page re-rendering the SAME rows under fresh ids). Root cause was
structural: the helper rendered a delta per MutationObserver walk and
pushed it, both clients (webface.zig, webdrive.zig) buffered the pushes
as OPAQUE TEXT (`pending_delta`), and text cannot cancel.

Fix, helper-side in `semantic.zig`: the LIVE shadow tree still folds
every walk (ids, engine-id routing and queries stay fresh), but the
tree as last CONSUMED by the client is now a separate base copy. A
snapshot request answers with ONE delta base→live (`View.consume`);
spontaneous walks post nothing. `SnapMode.history` (append-only value
2; `web_snapshot history:true`) opts back into the per-revision replay
from a bounded helper-side buffer — for debugging things that appear
and vanish between snapshots. Intra-document id carry (subtree
fingerprint, anchored to a matched parent so look-alikes in different
places can never swap) keeps a re-rendered identical row's id, so it
vanishes from deltas entirely. `rev` now only advances on actual
change, which also makes `web_wait for:"idle"`'s rev polling settle.
A snapshot request in flight across a navigation is re-issued into the
fresh V8 context (`semRearm`) instead of silently dying with the old
one. Client-side `pending_delta` buffering is deleted in both clients.

Measured (56-row list re-rendering + popup blinking, 6 unattended
cycles, then one snapshot): OLD buffered replay 63,888 bytes — just
under the old 64KB cap — vs NEW coalesced delta 124 bytes; history
opt-in 492 bytes. First-full snapshot unchanged (8,938 bytes).
smoke-web gained stage 13b (churn page, exactly one delta section, no
cancelled churn, ids stable, history still replays; measured there:
replay 708 B vs coalesced 66 B). smoke-web 26/26, smoke-mcp, test-core
1808 pass, mux-portable all green (pinned CEF; distro CEF still blocked
by the pre-existing glibc 2.44 skew).

## 2026-08-11: `web_open` returns the page it asked for; multi-view made legible

Field report: `web_open <url>` came back with a first snapshot reading
`doc 1 rev 1` for **about:blank**, the real page only appearing later as
doc 2. Two independent causes, both fixed.

**The blank document existed at all.** `cefhost.createView` always
created the CEF browser at `about:blank` and the requested url arrived
as a separate `Navigate` right after `ViewCreate`, so every addressed
view minted TWO documents. New append-only frame `view_create_url`
(tag 0x16) carries the initial url, gated by the new capability
`view-create-url`; `ViewCreate`'s layout is untouched, which is why it
is a new frame and not a field. `webdrive.zig` (headless, creates views
after the handshake) uses it whenever a url is given and falls back to
create-then-navigate against an older helper. `webface.zig` deliberately
does NOT adopt it: the GUI creates its view the instant the socket
connects, before the `hello_ack` that advertises capabilities — so
blank GUI tabs keep working exactly as before, at the cost of one
about:blank per addressed tab.

**The settle accepted the wrong document.** `web_open` broke out of its
wait on `url.len > 0 and !loading`, which the about:blank load finishing
satisfies. `openSettled` now requires a FINISHED load (`load_seq`, a
counter both backends report — `loading:false` is equally true in the
gap before the requested navigation starts), nothing in flight, and a
non-blank document. It deliberately does not compare against the
requested url: redirects and normalisation make the settled one
legitimately different. The reply gained `settled` (with a note when the
budget ran out — the "call web_snapshot" fallback is unchanged) plus
`document`/`revision`, so "no blank document was ever created" is
checkable from the reply itself.

**Multi-view was undocumented.** A handle-less `web_*` call resolves to
the CURRENT view (last touched). `web_tabs` now prints `current:true`
in headless mode too (it only ever printed `focused` with a GUI) and
explains the rule; `web_open`'s description says it always creates a NEW
view and becomes the default target; every `pane`-taking tool says
omitting the handle means the current view and passing one switches it.

Returning that early also made a LATENT bug reachable: the engine has
nothing to hit-test until it has composited once, so a `web_act` click
issued immediately after `web_open` landed on nothing and came back with
a delta of no changes (smoke-web stage 6 documents the same swallowing,
and the wasted about:blank document used to hide it by delaying every
caller). `webdrive.awaitFirstPaint` bounds-waits for the view's first
frame before any synthesized input, and costs nothing after it.

Coverage: smoke-web stage 22b (create a view AT a url; its first
snapshot is `doc 1` and describes the page, and no about:blank load
arrives — with the blank load of the stage-2 view asserted first so the
contrast is measured, not assumed). smoke-mcp's web stage opens a page
whose head blocks for 3s and asserts the reply is settled, carries
SLOWMARKER, mentions no about:blank and reports `document:1`, then that
`web_tabs` marks the current view and that an explicit handle moves it.

## 2026-08-11: an unstyled page screenshotted as a solid black frame

Reported as `web_screenshot` returning a correctly sized, uniformly
black 1280x800 PNG while the same view's tree, `web_read` and clicks all
worked. Measured cause: a windowless CEF browser defaults to a
TRANSPARENT canvas, so a page that specifies no background of its own
paints (0,0,0,0) everywhere; the screenshot path forces alpha to 255 and
that is black. Proof it was the canvas and not the capture: the SAME
view goes black -> red -> black again as `document.body.style.background`
is set and cleared, and with the fix reverted smoke-web reads the centre
pixel as exactly {0,0,0,0}.

`CefSettings.background_color` (in `cefhost.initialize`) has been opaque
white since the subpixel-AA work and is documented as the fallback for a
zero per-browser value — it measurably does not reach an alloy
windowless browser. The fix is `background_color = 0xffffffff` on
`cef_browser_settings_t` in `createViewAt`. smoke-web stage 22c opens a
page with no background at all (`<html><body>hi</body></html>`) and
asserts a white canvas; it was confirmed RED without the fix.

Hardening in the same pass, for a hazard found by reading rather than by
failing: `onPaint` drops any paint that arrives before the view's shared
buffer exists (`map.len == 0`) and otherwise copies only the damaged
rects, so a first paint that raced `allocBuffer` could leave a freshly
zeroed buffer black forever on a page that never repaints. `allocBuffer`
now marks the mapping `buf_unpainted` — the next paint is copied WHOLE
whatever the damage rects say — and invalidates the view so a dropped
first paint is re-requested (skipped while hidden; `showView` already
invalidates on unhide). This was NOT the cause of the black frames
above.

## 2026-08-11: web face parity — find-in-page, context menu, zoom, file drop

Four gaps between the web face and the other faces, closed in one pass.
Protocol grows an append-only 0x50 block (`protocol.zig` stays the
source of truth): `find` 0x50 / `find_stop` 0x51 / `set_zoom` 0x52
client-to-helper, `ev_find_result` 0x53 / `ev_context_menu` 0x54 back,
advertised as capabilities `find`, `zoom`, `context-menu`. An old helper
drops the unknown tags on the floor (the Reader's append-only rule), so
the GUI sends unconditionally.

- **Find-in-page**: Ctrl+F on the web face opens a hand-built bar (this
  tree has no shared findbar helper) — search entry, N/M match counter,
  prev/next/close. Text changes start a fresh engine search
  (`cef_browser_host_t.find`, `find_next=0`), Enter / the arrows step
  (`find_next=1`), Escape or close stops (`stop_finding`, selection
  cleared). Match counts ride `on_find_result` -> `ev_find_result`.
- **Context menu**: the helper's context-menu handler clears CEF's
  default model and `run_context_menu` cancels the engine display
  outright, posting `ev_context_menu` with LOGICAL coordinates, a
  link flag + url from the hit test, and an editable flag. The face
  shows a `classicmenu` popover there: Back/Forward (sensitivity from
  nav state), Reload, and — on a link — Open Link in New Tab + Copy
  Link URL, plus Copy Page URL. A page that preventDefault()s
  contextmenu suppresses ours too, exactly like a normal browser.
- **Zoom**: Ctrl+= / Ctrl+- / Ctrl+0 and Ctrl+wheel set a USER zoom,
  carried as the engine's log-scale level x100 (factor 1.2^level, one
  step = 100 = the conventional 120% browser step, clamped to
  Chromium's ~28%..430% preset range). The helper ADDS it to the DPR
  zoom that `applyZoom` already uses in accelerated mode (levels are
  logarithmic, so the device scale and the user zoom compose by
  addition) and re-applies both on every load start, since Chromium
  resets zoom per navigation. The GUI re-sends it in `ensureView` so a
  helper restart keeps the level.
- **File drop**: a GtkDropTarget on the view area (pane.zig's shape)
  navigates to the first dropped file's `g_file_get_uri` (file:// or
  whatever the GFile really is); dropped text goes through the address
  bar's normalizeUrl.

Also fixed while wiring the menu: `classicmenu.Root.destroy` ignored
`g_object_ref_sink`'s return value — latent (never referenced before,
so lazy analysis skipped it) until the web face's error path became its
first caller.

## 2026-08-11: cross-face cleanup — one look, shared chrome, no private frameworks

A duplication and look-and-feel audit across the five faces (terminal,
files, editor, viewer, web) turned into a 20-commit cleanup. The
headline user-facing fixes:

- The per-pane titlebar is suppressed for the web identity like the
  files identity (same redundancy argument), and non-terminal faces
  now feed it real titles (page title / directory / document name)
  instead of showing the hidden shell's stale OSC title. Manual lock
  still wins; the OSC title returns when the shell face does.
- `font_inc`/`font_dec`/`font_reset` act on the VISIBLE face via
  `Pane.faceZoom`: the editor zooms its own font (plus Ctrl+wheel)
  instead of silently resizing the hidden terminal.
- The editor gained `new_editor_split` (palette, toolbar button,
  bindable action) mirroring `new_browser_split` — the global tree
  needed zero changes.
- Inner tabs (files + editor, shared `tabhost.zig`) drag-reorder with
  model sync, and the editor has a 10-deep reopen-closed-tab ring like
  the browser's.
- Files: Ctrl+F opens directory search. Editor and viewer accept file
  drops. Web face: see the parity entry above.
- Theme correctness: image canvas no longer hardcodes dark, the web
  canvas no longer hardcodes white, tab accents follow the theme.

New shared modules, replacing per-face copies: `ui/confirm.zig`
(AdwAlertDialog pattern, ~16 sites), `ui/findbar.zig` (find chrome for
editor find + project grep), `ui/toolbtn.zig` + promoted
`ui/iconload.zig` (face toolbars; fixes the blank terminal icon under
Breeze in web/editor toolbars), `ui/cssutil.zig` (one CSS installer,
also fixes provider leaks), `ui/widgets.zig` (actionButton), shared
clipboard copy/read helpers in `ui/clipboard.zig` (three async-read
machines deleted), `input.fallbackToPaneBindings` (four copies), and a
463-site `cast.userData`/`destroyCtx` adoption sweep. The viewer lost
its private menu framework (now `classicmenu`), its deprecated
GtkAppChooserDialog (now the files chooser, host apps included), its
private byte formatter (MiB -> MB, matching files), and its
keybinding-deaf hardcoded switch (zoom/copy chords now honor config).

Verification: `zig build`, `zig build web`, `zig build test-core`
green; `zig build test` is 2199 pass / 5 skip / 6 fail, and the 6
failures (`ipc.mcp.test.ui_*`) reproduce IDENTICALLY on the pre-cleanup
base commit on this machine — pre-existing, not from this work, left
for a separate investigation. GUI behavior (menus, zoom, drops, find
bars) is compile- and trace-verified; none of it was exercised on a
live display this session.

## 2026-08-11 — Link hints for the web face (Vimium-style)

The human skin over the MCP semantic layer: `web_hints` (palette "Link
Hints (Web Page)", bindable) labels every visible interactive element
of the page; typing a label clicks it through the SAME trusted-input
path and semantic id `web_act` uses, so hints double as a visual debug
of the semantic layer. Shift/Ctrl on the completing key opens a link's
url in a new web tab (`newWebTabAt`). Escape, a dead-end prefix, a real
click, scroll, zoom, resize or navigation cancels; Backspace un-types.
While labels are up the key controller consumes EVERYTHING — nothing
leaks to the page or the chord table. `hints_open` (Ctrl+Shift+E)
delegates to web hints when the pane wears the web face and stays the
terminal quick-select otherwise, so one chord always hints what is on
screen.

Plumbing — no new frame tags: hints are `sem_query` kind `visible = 3`
(arg "vw vh" in page CSS px). Unlike other queries the helper answers
it AFTER soliciting a fresh DOM walk (scrolling moves every rect
without one DOM mutation), then renders `semantic.View.renderHints`
from the live tree — the consumed base is deliberately untouched, so a
hints pass never eats a snapshot's delta. Walk nodes now carry the
resolved anchor url (`InNode.url`, additive JSON field, excluded from
fingerprints/deltas). `semRearm` re-solicits pending hints across a
navigation like snapshots. GUI-side rects are CSS px: label placement
multiplies the user-zoom factor (1.2^(level/100)) back in plus the
snap_dx/dy nudge; the request divides the viewport by it.

New `src/web/hints.zig` (std-only, both test roots): Vimium-style
prefix-free shortest-label generator over the home-row alphabet plus
the TSV payload parser shared by the overlay. Files:
`web/{protocol,semantic,cefhost,hints}.zig`, `semantic.js`,
`ui/{webface,input,window,palette}.zig`, smoke stage 13c.

Verification: `zig build`, `zig build web` green; `zig build test-core`
1820 pass / 6 skip / 0 fail; `zig build test` 2217 pass / 5 skip / 0
fail; `zig build smoke-web` all stages PASS including new stage 13c
(fresh rects, urls, viewport clip, disabled filtering over the wire).
The GTK overlay interaction itself (labels, typing, activation) is
widget-side and not smoke-covered — verified by compile + review only,
not on a live display.
## 2026-08-11: reader mode for humans, on the extraction the tools already had

`web_read` (MCP) has extracted a page's article to Markdown since the
semantic layer landed; the browser face had no way to show it. It does
now: a **Reader** toggle on the web toolbar (plus a `Reader View` check
row in the page context menu and a bindable `web_reader` action in the
palette) swaps the page for its article, laid out as text, and back.

- The request is the SAME round trip the tool uses — `sem_read` out,
  `sem_read_result` in — sent from the face's own helper socket and
  correlated by the existing `AutoKind.read` token, so a `web_read`
  running against the same view at the same moment is not stolen and
  does not steal.
- Rendering is a `GtkTextView` with text tags, NOT a `data:` URL loaded
  back into the engine: a reader that navigates would discard the live
  page's state and write junk into its history. The page keeps running
  underneath the overlay, so leaving reader mode is one visibility flip
  and costs no reload. Navigation of any kind (link, address bar,
  reload, redirect, helper restart, renderer crash) exits it.
- New `src/util/markdown.zig` — a compact block+inline walker for the
  dialect `semantic.js` emits (headings, paragraphs, fenced code,
  quotes, `-`/`N.` items, rules, `**bold**` `*italic*` `` `code` ``
  `[link](url)` `![alt](src)`). Pure data, no GTK, so it is in BOTH
  test roots. There was no markdown renderer anywhere in the tree
  before this (`editorlsp.zig` still flattens LSP hover markdown to
  plain text and says so; a richer hover could reuse this walker).
- New `src/ui/webreader.zig` — the GTK half: tags for headings/bold/
  italic/code/quote/links, an `AdwClamp` holding a 700px reading
  measure, serif body text on `@view_bg_color`/`@view_fg_color` so it
  follows light and dark, clickable links (resolved against the page's
  own address, absolute/root-relative/protocol-relative/relative) that
  navigate the page underneath and leave reader mode, and Escape to
  leave. Unhandled keys fall through to the pane bindings, so a focused
  reader is not a keyboard trap.
- `sketerm-reader-symbolic` ships in `data/icons` (and the PKGBUILD):
  `view-reader-mode-symbolic` is a GNOME Web name that a Breeze chain
  never resolves, and an unresolvable icon name renders an invisible
  button.

Lifetimes follow the face's own discipline: the reader's controllers
carry the READER as user-data, so the face's signal-disconnect loop
cannot reach them — `Reader.sever` is called from the face's
prepare-destroy (the same choke point, mechanism 2) and `Reader.destroy`
from `WebFace.deinit`.
## Web faces: real tab discard (`view_discard`, cap `discard`)

A hidden web pane used to keep its whole browser: `view_hide` stops the
painting and nothing else. It can now be let go entirely.

- Wire: `view_discard` = **0x17** (view id), capability `discard`.
  Append-only as always; a helper without the capability never receives
  the frame and every pane behaves exactly as before.
- Helper (`cefhost.zig`): the frame destroys the browser (force-close),
  unmaps the frame buffer, drops the pending script requests and the
  semantic shadow tree, and clears the CEF id so a late callback from
  the dying browser resolves to nobody — while the VIEW RECORD (id,
  logical geometry, scale, fps cap, user zoom, url) stays. `view_show`,
  `navigate`, `nav_action` and every input frame revive it through
  `findWake`/`reviveAt`, which re-enters the same `spawnBrowser` a
  first creation uses, so the revived view is identical but for one
  thing: **the navigation history is gone** (documented on the frame,
  in `src/web/CLAUDE.md` and in `docs/config.md`). A resize only
  records the new geometry and `frame_request` is ignored, so a
  background pane cannot resurrect itself.
- A discarded view ANSWERS what it cannot serve — one explanatory
  `discarded_msg` for every semantic frame, an empty final
  `ev_find_result` for find — because a client waiting on a reply frame
  has no other way out. `webdrive`'s screenshot path was already
  bounded and returns the last buffer it holds.
- GUI (`webface.zig`): a face unmapped for `web_discard_minutes`
  (config, default 30, 0 = never) sends the frame. The pane KEEPS the
  last delivered frame, dimmed through a `sketerm-web-discarded` class
  installed with the rest of the webview CSS via `cssutil`; map, focus,
  navigation and any automation request revive it. The countdown is a
  one-shot GLib timeout severed at `prepareDestroyCb` and `deinit`, the
  same mechanism the pacing timers use.
- Palette: **Discard Background Web Tabs** (`web_discard_background`)
  does it to every off-screen face now, with a toast counting them.

Verification: `zig build`, `zig build web` green; `zig build smoke-web`
green including a new stage 22d that creates a view at a titled green
page, discards it, proves a semantic request against the discarded view
is ANSWERED (not left to time out) and that no buffer is announced
while it is gone, then shows it and asserts a fresh frame buffer, the
same title and the same green centre pixel. `zig build test-core` fails
at the build-step level on this machine — identically on the base
commit, with the test binary itself reporting 1813 passed / 0 failed
when run directly, so pre-existing.

## 2026-08-11: TLS interstitials, permission prompts, popup policy

Three security/UX gaps in the browser face, all of them "the engine
asked a question nobody was answering".

- **TLS interstitials.** A certificate error used to fall into the
  generic `onLoadError` and read like a DNS failure. The helper now
  implements `on_certificate_error`, HOLDS the request and posts
  `ev_cert_error` (tag 0x55, capability `tls`) with the host, the
  symbolic error name, subject, issuer and the certificate's SHA-256;
  `cert_decision` (0x56) continues or cancels it. The GUI raises a
  full-face dark interstitial that COVERS the page — "Back to safety"
  (default, leaves via history or about:blank) and "Proceed anyway
  (unsafe)". Proceeding accepts the certificate for that one request:
  nothing is remembered on either side.
- **Permission prompts.** `cef_permission_handler_t` is installed
  (`on_show_permission_prompt` plus `on_request_media_access_permission`,
  whose media callback has no prompt id of its own and gets a
  helper-minted one in a disjoint id space). A held prompt travels as
  `ev_permission` (0x57, capability `permissions`) with an
  engine-agnostic permission bitmask, and `permission_decision` (0x58)
  answers it. The GUI shows a NON-MODAL banner above the page and
  remembers the answer per (origin, permission bits) for the face's
  lifetime, reporting each one to `webface.SiteSettingSink` — the one
  named hook a daemon-side site-settings store plugs into. Nothing is
  persisted here.
  **Not reachable yet, measured:** the installed CEF never asks an
  ALLOY windowless browser's client for a permission handler at all and
  denies the request internally, so the banner cannot appear today.
  smoke-web stage 22g pins that behaviour and FAILS the day it changes.
- **Popup policy.** `on_before_popup`'s `user_gesture` now rides the
  wire as an OPTIONAL TRAILING byte on `ev_popup_request` — the only
  frame allowed to grow, and only because its decoder reads a short
  payload as "absent, assume a gesture", so an older helper keeps
  opening every popup instead of having them all blocked. The new
  `web_popup_policy` config key (`block-gestureless` default, `allow`,
  `block-all`) decides: a blocked popup becomes a window toast naming
  the host with an `Open` button. Chromium's own popup blocker eats a
  gestureless `window.open` before the callback runs (smoke-web stage
  6b pins that too), so the policy is a second line of defence and the
  lever for `block-all`.

Verified: `zig build`, `zig build web`, `zig build test`, `zig build
test-core` and `zig build smoke-web` all green. New protocol round-trip
tests cover the four frames plus an old-layout `ev_popup_request`
decoding as "gesture". New smoke stage 22f drives a REAL self-signed
`openssl s_server` on loopback: held request, cancel -> load error,
error again (a denial is remembered by nobody), proceed -> page loads.
The stage skips instead of failing where openssl is absent.
## 2026-08-11: web DevTools and print-to-PDF (and what CEF refuses)

Two new verbs on a web pane, both as context-menu rows (greyed out, not
hidden, when the helper is too old) and both as palette actions
(`web_devtools`, `web_print_pdf`):

- **Print to PDF…** — a save dialog (the native picker, `local_only`,
  defaulting to `<page title>.pdf`), then `print_pdf` (0xA4, cap
  `print-pdf`) to the helper, which renders the page itself and answers
  `ev_print_pdf_done` (0xA5). A toast reports the result and carries an
  **Open** button that hands the file to the desktop. The helper writes
  the file, so a pick on another host is refused in the dialog.
- **Open DevTools** — `devtools_show` (0xA2, cap `devtools`) asks for
  the inspector as ANOTHER windowless view; `ev_devtools_view` (0xA3)
  answers with a helper-minted view id, and the GUI splits the pane and
  gives the new one a web face ATTACHED to that existing view
  (`WebFace.attachView` / `Window.openDevToolsSplit`) — one helper
  process, one socket, no second connection. No debugging port exists
  anywhere in the design.

**CEF 151 refuses the windowless inspector** — measured identically on
the Arch `cef` package and the pinned upstream build: `show_dev_tools`
logs "Windowless rendering is not supported for this DevTools window"
and hands back a WINDOWED browser (`is_window_rendering_disabled() ==
0`). The helper therefore keeps that browser owned (so `cef_shutdown`
finds nothing open — leaving it unowned killed the helper on a signal)
and answers `devtools = 0, reason = "windowed"`; the GUI toasts
"DevTools opened in its own window". The in-a-pane path is written,
reachable and tested for the answer shape, and runs the day an engine
honours the request. Details in `src/web/CLAUDE.md`.

Verification: `zig build`, `zig build web`, `zig build test`,
`zig build test-core` green; `zig build smoke-web` green against BOTH
CEF builds, with a new stage 22d (a real 18 KB PDF on disk, plus an
unwritable path and an unknown view both answered as failures) and
stage 22e (DevTools: asserts the view path when the engine gives one,
the window fallback otherwise, and that either way every request is
answered and the inspected page survives). The GUI split was not
exercised on a live display — no engine here produces the view it
needs.
## 2026-08-11: daemon-side web store — history, bookmarks, site settings

The browser's persistence backbone. Browsing state lives with the
`sketerm-mux` daemon under `$XDG_STATE_HOME/sketerm/web/`, accessed
over the wire protocol — so a GUI attached to a remote daemon sees
that host's browsing state ("daemon-side => follows you across
machines").

- `src/mux/webstore.zig` (GTK-free, both test roots): history as an
  append-only JSONL log (`history.jsonl`) replayed into an in-memory
  per-URL index (visit count + last-visit ms for omnibox ranking),
  compacted atomically once the log passes 2x live entries + slack,
  pruned at 50k entries; ranked substring queries (frecency weight x
  visit count, 4x prefix bonus on url/host). Bookmarks: ordered JSON
  with cheap string folders and monotonic ids. Site settings: JSON
  keyed by case-normalized origin — zoom_x100, popup policy,
  content-blocking override, named permission decisions; an
  all-default site is removed from the file.
- Wire: `web_op = 32` (client→daemon, `{req, op, ...}` — the fs_op
  shape, so new verbs are op strings, not frame types) and
  `web_reply = 96` (echoes `req`). Ops: history_add / history_title /
  history_query / history_delete / history_clear, bookmark_add /
  remove / update / list, site_get / site_set. Gated on the welcome
  capability `web_store:true`; NOT attach-scoped (the broker serves it
  in broker mode). `Conn.web_store` carries the capability client-side.
- `src/ui/webstore.zig`: one process-wide non-blocking connection to
  the local daemon (webface Client singleton shape), `g_unix_fd_add`
  read watch + EAGAIN-safe write watch, nonce-correlated callbacks.
  Liveness is disconnect-at-teardown: `webstore.cancelFor(face)` from
  `WebFace.deinit` is the single choke point.
- Web face wiring (minimal, no UI): a committed navigation records a
  visit immediately and files the title later via `history_title`
  (no double count); an origin change fetches the stored per-site
  zoom and applies it without writing back; a USER zoom change
  persists per origin (0 clears). about:/data: URLs never make
  history.

Verification: `zig build`, `zig build mux`, `zig build mux-portable`
green; `ldd zig-out/bin/sketerm-mux` shows libc/libm only. The
webstore unit tests (round-trip, compaction, ranking, bookmarks,
site merge/clear) pass in both roots; the `zig build test-core`
RUNNER failure seen this session reproduces identically on the base
commit (the test binary itself exits 0 with all tests passing) —
pre-existing, not from this work.

## 2026-08-12: browser downloads (offer/decide wire, strip, send-to-host)

The downloads family, absent entirely before. New 0x78 tag block +
capability "downloads" in `src/web/protocol.zig` (append-only, u64
byte counts): `ev_download_offer` HOLDS the engine's target decision,
`download_decide` continues into a client path ("" cancels),
`ev_download_progress` is coalesced one-frame-per-poll-iteration per
download (the intercept_status pattern), `download_cancel` aborts.

- Helper (`cefhost.zig`): `cef_download_handler_t` with the held
  `before_download_callback` released exactly once (the cert_cb
  discipline); the latest `download_item_callback` is kept as the
  cancel handle. `dropBrowser` cancels a dying/discarded view's
  downloads and posts their terminal frame. TWO measured gotchas:
  a held target callback must ALWAYS be run (a cancel CONTINUES into
  a /tmp throwaway, then cancels — dropping it unanswered wedges
  Chromium's target determiner), and the post-disconnect drain now
  pumps until `on_before_close` fired for every browser, because a
  cancelled download's cleanup outlives any fixed pump count and
  stalled `cef_shutdown` past stage 23's 10s.
- GUI (`webface.zig`): offer -> save dialog (PickerWindow save_file,
  suggested name, last dir remembered per window) or, with the new
  `web_download_ask = false` (docs/config.md), auto-accept into
  ~/Downloads with " (n)" uniquify. A bottom strip row per download:
  name, progress bar, byte count via the shared `format.fmtSize`,
  cancel/dismiss, and on completion Open + Show in Files
  (`siblingapp.showInFiles`). Row buttons carry a `DlBtnCtx` owned by
  the button (mechanism 1) and resolve the face through the client
  registry, PrintCtx-style.
- REDIRECT-TO-SERVER: the save dialog browses remote hosts natively;
  a `host:` pick stages under `$XDG_CACHE_HOME/sketerm/webdl/`, then
  hands off via `file_transfers.Service.submitUpload` (new; a plain
  durable cross_copy upload intent, no edit watch) — v1 routes
  origin -> local -> server, never fetch-on-server. The strip's second
  phase polls `intentProgress` at 2Hz, unlinks the staging file when
  the daemon transfer lands, and the transfer survives the pane (it
  is the ledger's, not the GUI's).

Verification: `zig build`, `zig build web`, `zig build mux-portable`,
`zig build test` (full GUI suite), `zig build test-core` green;
`zig build smoke-web` green end to end including the NEW stage 22j
(trusted click on a download anchor -> offer held -> decided path
lands the exact bytes -> terminal done frame; decide-"" cancels with
a terminal failed frame; unknown ids ignored). Protocol round-trips
for all four frames in both test roots. Not covered: a GUI-level
end-to-end of the dialog/strip (would need a display session +
helper); the smoke covers the wire and helper halves.

## 2026-08-12: omnibox + palette on one suggestion framework

The proposal's "command palette synthesis": URL / search / history /
bookmarks / open-tabs / commands as pluggable sources in a shared
ranking framework, consumed by the web face's address bar AND the
command palette.

- `src/util/suggest.zig` (GTK-free, both test roots): `Source`
  vtable (`query(q) -> Candidate{title, detail, kind, score,
  payload}`), a merger that drops non-matches, normalizes unbounded
  scales (frecency) per source batch, weights, stably interleaves,
  dedupes by key (URL) and caps; `matchScore` (prefix 1.0 > word
  boundary 0.8 > substring 0.6, secondary field x0.7); the
  address-bar `classify`/`normalizeUrl`/`searchUrl` heuristic with a
  `{q}` engine template. `percent.zig` gained the RFC 3986 query
  encoder.
- `web_search_engine` config key (app-level string, default
  `https://duckduckgo.com/?q={q}`): validated at parse (http(s) +
  `{q}` required, bad line skipped), round-trips, clones. Search
  queries are now PERCENT-ENCODED — the old normalizeUrl pasted the
  raw query into the DDG URL. webface holds the template in a module
  buffer (`setSearchEngine`, applied at window init + config apply)
  because the config arena dies with its window.
- Omnibox (`src/ui/omnibox.zig`): autohide-off GtkPopover under the
  address entry; debounced (120ms) as-you-type refresh. Sources:
  the input's URL/host reading (score 1.0) + its web-search reading
  (1.0 when it IS a search, 0.35 fallback), open web tabs across all
  windows (weight .9, activation SWITCHES via view-id →
  `WebFace.reveal`, never a second load), bookmarks (weight .85,
  fetched once per session, filtered locally), daemon history
  (weight .8, normalized frecency; async — superseded queries are
  `cancelFor`-ed on a dedicated anchor byte so replies cannot
  mis-rank, and the bookmark fetch rides a second anchor). Keyboard:
  Down/Up select (capture phase, the palette trick), Enter activates
  a selection and otherwise stays "go to what I typed", Escape
  closes. Never blocks the entry. Lifetime is the reader shape:
  `sever` at the face's prepare-destroy choke point, destroy in
  deinit.
- Palette: matching/ranking moved onto the framework — the curated
  list is a command `Source`, merge scores rows, a listbox sort func
  puts the best match on top (tie-break on build order keeps the
  curated ordering for bare queries, pinned by a test). DECISION:
  the palette stays commands-only. Web sources there would need the
  omnibox's async plumbing inside a modal dialog and mix "do an
  action" rows with "go somewhere" rows the palette's dispatch model
  (`dispatchAction`) has no verb for; the shared framework was the
  deliverable and either consumer can gain sources later by
  appending to its source array.

Verification: `zig build`, `mux`, `mux-portable` green; full
`zig build test` binary run directly: 2271 passed / 0 failed
(the RUNNER-mode failure again reproduces on the clean base).
Omnibox dropdown behavior is compile+trace verified (no CEF display
rig in this session); the merger/scoring/encoding/config paths are
unit-tested.
## 2026-08-12: tree-style tabs for the whole suite

One tab system for ALL of sketerm (the proposal's decision): a
window-level tab TREE — not browser-private — with the TST clone as
the behavioral spec (behaviors ported, no code).

- `src/ui/tabforest.zig`: toolkit-free `Forest(Ref)` model, sibling of
  `ui/tree.zig`'s PaneTree discipline (model first, widgets are a
  view). Parent/child + collapse per node; promote-on-remove splices
  children into the removed node's position; reparent moves whole
  subtrees and rejects cycles; visible-flatten / wrap-around stepping;
  `validate()` for the verifier. Unit-tested on `Forest(u32)`.
- `Window.tab_forest` (`TabForest = Forest(*AdwTabPage)`) is kept in
  sync inside the page-attached / page-detached handlers: a page
  entering the view gets a node (child of a pending opener, else
  root); a page leaving has its children PROMOTED — so cross-window
  drags move one page and its children stay behind, and the model can
  never diverge from the page set. `verifyTabForest`
  (SKETERM_VERIFY_TREE=1) aborts if it ever does.
- Vertical sidebar `src/ui/tabsidebar.zig` (GtkListBox in the content
  hbox): rows in visible tree order, indent by depth, expander on
  parents, close button, middle-click close; row drag reparents the
  subtree (drop on a row = child of it, drop on empty space = root).
  Selecting a hidden page (Ctrl+Tab, goto_tab_N) auto-expands its
  ancestors. The strip stays: collapsed subtrees just hide from it
  (`TabBar.refreshHidden` + a Window-supplied predicate).
- Opener nesting: web popups, hint-modifier opens and
  open-link-in-new-tab go through `newWebTabFrom(url, opener_page)`;
  collapsing a subtree also discards its hidden web panes'
  renderers (`WebFace.discardNow`, the tab-unloading synergy).
- Close policy: every accept branch of the close-page gate funnels
  through `acceptTabClose`; `tab_close_parent = close-subtree` sweeps
  the descendants (captured before the forest promotes them),
  reentrancy-guarded so each child still gets its dirty-editor veto.
- Config: `show_tab_sidebar`, `tab_close_parent`, `tab_child_insert`.
  Actions: toggle_tab_sidebar, tab_collapse, tab_expand,
  tab_tree_next/prev (visible TREE order). Layout: append-only
  `tree_parent` + `collapsed` on TabSpec; old files load flat;
  restore rebuilds nesting after all tabs exist.

Verification: `zig build` green; new model/layout/config tests pass in
the full suite (2267 passed, 0 failed when the test binary runs
directly — the `zig build test` RUNNER failure reproduces identically
on the clean base). smoke-e2e (with SKETERM_VERIFY_TREE=1, now
including the forest check) progresses exactly as far as the base
does: the copy-mode-yank stage fails on the base too (deep worktree
path wraps the prompt). Sidebar interaction is compile+trace verified.
## 2026-08-12: the web page's accessibility tree, engine to screen reader

The browser roadmap's a11y block, read-only tree first. Three layers,
each tested on its own:

**Wire (0x70 block, capability `a11y`).** `a11y_enable` gates
per-view streaming — nothing flows unsolicited (backlog rule);
`ev_a11y_tree` carries INCREMENTAL node lists (Chromium's update
shape kept: changed nodes with full content + child lists,
`node_id_to_clear`, root/focus ids) via a shared
`A11yNodeWriter`/`A11yNodeIter` binary encoding; `ev_a11y_loc` is
pure geometry so scroll storms stay cheap to skip; `ev_a11y_event`
speaks a tiny token vocabulary ("focus", "load-complete"). Roles are
ARIA-ish lowercase tokens, states are our own `ax_*` bits — no engine
enum crosses the wire. Round-trip unit tests in both roots.

**Helper.** `set_accessibility_state(STATE_ENABLED)` per view on
demand; `cef_accessibility_handler_t` translates the serialized
payloads (shapes verified empirically on CEF 151 with
`SKETERM_WEB_AX_DEBUG=1`). The callbacks carry no browser pointer, so
attribution joins on the payload's `ax_tree_id` token, rebinding an
unknown token only when exactly one view is enabled. Found+fixed en
route: the post-disconnect drain was 100 tight pumps — an
a11y-enabled browser needs wall-clock IPC to close and `cef_shutdown`
then hangs forever; the drain now waits on `openBrowsers() == 0`
(life-span `on_before_close`). smoke-web stage 22k asserts the
enable gate, roles+names, checked/disabled state bits, and silence
after disable.

**Projection.** Seam chosen: (a) — the org.a11y.atspi interfaces
served DIRECTLY on the session a11y bus, as a pure-Zig D-Bus server
over `mux/dbus.zig` (no GDBus, no libatspi). The page tree registers
as its OWN accessible application via `Socket.Embed` on the registry,
which is Chromium's own shape on Linux; nesting under the pane's
GtkAccessible is not possible because GTK4's AT-SPI backend cannot
answer a child walk with a foreign bus reference. `web/axtree.zig`
mirrors the stream (incremental apply + reachability prune, unit
tests both roots); `a11y/webproj.zig` serves Accessible / Component
(extents through the offset-container chain) / Application /
Properties / Cache. `zig build smoke-webax` proves it end to end with
NO CEF and NO GUI: private dbus-daemon + at-spi2-registryd
(`a11yhub`), tree fed through real wire bytes, then the daemon's own
AT-SPI client walks the REGISTRY desktop and finds the application,
the DOCUMENT_WEB root, HEADING/PUSH_BUTTON role numbers, chain-
resolved extents, and an incremental rename on re-walk.

**GUI.** Web faces mirror `ev_a11y_tree`/`ev_a11y_loc` per view; a
detached worker does the blocking bus connect (idle handback resolves
through the client's faces list), the projection follows the page
title, and every view-minting path re-asserts `a11y_enable`. Gated by
`SKETERM_WEB_A11Y=1` for now — the flag IS the "a client asked"
signal until org.a11y.Status screen-reader detection lands.

Explicit follow-ups (not this pass, by design): object event
emission (children-changed/state-changed — a reader must re-walk
today), focus/caret/Action/Text interfaces, iframe (child-tree)
flattening, screen-reader auto-detection, screen-coordinate origin
(extents are window-relative until the GUI feeds `setOrigin`).
Manual GUI verification: run with `SKETERM_WEB_A11Y=1` on a desktop
with a live a11y bus, open a web tab, then
`busctl --user tree :1.<n>` / Accerciser should list "sketerm web:
<title>" as an application whose tree matches the page.
## 2026-08-12: the web store gets a face — history, bookmarks, site memory

The store from the previous entry had no UI and three persistence
loops still ran in memory only. Both are closed.

- `src/ui/webhistory.zig` (new): the History and Bookmarks windows,
  one file because they share every list idiom. Transient toplevels
  over the window that opened them (the `app_launcher.zig` shape),
  non-modal so the page a row navigates to is visible behind them.
  History searches through `history_query`'s OWN ranking — re-queried
  per keystroke rather than filtered in the listbox, or a match past
  the first page would never appear — and rows show title, url,
  relative time and visit count. Bookmarks group by folder with a
  `set_header_func` (headers are not rows, so nothing there can be
  activated or deleted), filter client-side, and can be renamed,
  re-foldered, reordered and opened in a new tab. Row activation
  navigates the pane that opened the window, or opens a new web tab
  when that pane is gone. "Clear History…" goes through `confirm.zig`.
  Lifetime: one heap `List` freed on the window's "destroy", which is
  also the `webstore.cancelFor` choke point the store client requires.
- Palette + keybind actions `web_history` / `web_bookmarks`, and
  History/Bookmarks rows in the web face's context menu. Neither needs
  a web pane: they list the daemon's store and open a tab if asked.
- Bookmark star in the web toolbar, reflecting whether THIS address is
  bookmarked. State comes from a `bookmark_list` per committed
  navigation rather than a local cache, so a page starred in another
  window shows starred here. A plain button, not a toggle: a toggle
  driven by an async reply would visibly flip back.
- Permission decisions now persist. `webface.setSiteSettingSink` was
  a hook nobody had installed; `installStoreSiteSink` (called where
  the app-level popup policy is applied) makes it write `site_set`,
  and `onSiteReply` pre-loads an origin's stored decisions into the
  face's memory on every origin change — so a stored allow/block
  answers `ev_permission` with NO banner, and a prompt already on
  screen when the reply lands is drained instead of left asking a
  question the store has answered. The bitmask is keyed as its
  '+'-joined bit names (`camera+microphone`); a mask carrying a bit
  this build cannot name is not persisted at all, because a key that
  cannot be read back would answer the wrong prompt.
- Per-site content blocking persists through the named `netStoreApply`
  hook: the shield writes `site_set`, an origin change re-applies the
  stored answer, and an origin with no override goes back to the
  global default rather than inheriting the previous site's answer.
  Choosing the default clears the override instead of pinning it.
- Per-site popup override (`Site.popup`, already in the schema) now
  actually decides in `onPopup`, over the app-level policy in both
  directions, with an "Allow Popups on This Site" check row.
- `bookmark_update.folder` became optional daemon-side (absent =
  unchanged, "" = top level). It was "" = unchanged, which left a
  bookmark with no way back out of a folder; the alternative was a
  sentinel folder name, which is a hack.
- `classicmenu.checkEnabled`: a check row that is greyed rather than
  hidden when it has nothing to act on, matching `itemIconEnabled`.

Tests: permission-key round-trip incl. combinations, unnamed bits and
a too-small buffer; `site_get` reply parsing with perms; the relative
time formatter at every scale (including a zero and a future stamp);
bookmark folder grouping. Verification: `zig build`, `zig build mux`,
`zig build mux-portable` green; `zig build test` 2264 passed / 0
failed and `zig build test-core` 1859 passed / 0 failed (its runner
"failed command" line is the pre-existing one noted above). Every
commit was built at its own revision. The UI itself is compile- and
trace-verified, not driven headlessly.

Known limitation: the permission banner is still unreachable in the
CEF build this helper uses (see the `webface.zig` header and smoke-web
stage 22g), so the stored-decision path cannot be exercised end to end
yet. Its origin matching also assumes the engine reports an origin in
the same `scheme://host[:port]` form `originOf` normalizes to — a
mismatch would mean the banner still appears, never a wrong answer.
## 2026-08-12: browser containers (per-tab identity contexts) + per-tab remote egress

Per-tab identity contexts land end to end, plus the flagship "browse via
server X" egress: a container whose traffic exits from a connected remote
host with remote DNS. A container is a private cookie jar / cache (CEF
request context), optionally routed through a proxy; incognito is the
ephemeral (in-memory) preset. Proven through real CEF by two new
smoke-web stages.

- `src/web/protocol.zig` (both test roots): new 0x90 block —
  `context_create` (id, ephemeral, name, proxy) / `context_destroy`,
  capability `CAP_CONTEXTS`. Append-only; round-trip tests added. The
  `context: u32` field already on `view_create`/`view_create_url` is now
  honored.
- `src/web/cefhost.zig`: a request-context registry on `Host`. Each
  `context_create` builds `cef_request_context_create_context` with its
  own cache dir under the profile (ephemeral = empty cache_path =
  in-memory incognito store, nothing to scrub), and, per the browser
  spike, `set_preference("proxy", {mode:"fixed_servers", server:<url>})`
  on the context's base preference manager. `spawnBrowser` passes the
  looked-up context as `create_browser_sync`'s 6th arg (0 = default,
  null context); `View.context` survives a discard/revive.
  `src/web/server.zig` advertises the cap (array grown 15->16) and
  dispatches the two frames; `src/web/main.zig` hands the cache dir to
  the server so per-context dirs sit under it.
- `src/mux/wire.zig` + `src/mux/daemon.zig` + `src/mux/daemon_serve.zig`:
  new `stream_open` verb (frame 33) / `stream_reply` (96->97 reply
  family), welcome capability `stream_open:true`. The daemon resolves an
  ARBITRARY host:port at ITS end (remote DNS via getaddrinfo), nonblocking
  connect, and answers `chan_open` (kind tcp_forward) + `stream_reply`.
  It is the arbitrary-host analog of the pre-existing loopback-only
  `forward_open`; that verb did NOT suffice (port-only, 127.0.0.1-only),
  so a new one was added, keeping `sketerm-mux` libc-only
  (`zig build mux-portable` stays green). getaddrinfo runs on the poll
  loop (blocking) — acceptable v1 tradeoff, documented at the handler.
- `src/ipc/socks5.zig` (NEW, both test roots): minimal RFC1928 codec —
  greeting + CONNECT request (atyp ipv4/domain/ipv6), reply headers,
  host formatting. Incremental parsers, fully unit-tested.
- `src/ipc/socksbridge.zig` (NEW, both test roots): the local loopback
  SOCKS5 listener that relays each CONNECT over the mux `stream_open`
  verb (GTK-free poll loop, mirrors `mux forward`). `Socks` driver
  unit-tested (greeting/request/pipelining/auth-refusal/BIND-refusal);
  `Egress` binds the listener on the caller thread (so the proxy port is
  known synchronously) and connects+serves on a worker via an injected
  connect fn.
- `src/ui/webface.zig`: process-wide container registry (name + accent
  color from an 8-swatch palette + ephemeral + proxy + egress host +
  live `Egress`). `createContainer`/`createIncognito` mint an id, spin
  the egress bridge when a host is given (proxy = `socks5://127.0.0.1:
  <port>`), and publish `context_create`. `Client.cap_contexts`; every
  container is re-published to a fresh helper BEFORE its faces re-create
  views. `WebFace.container` (immutable, survives restart) feeds
  `view_create.context`.
- `src/ui/window.zig`: `newWebTabInContainer` / `newIncognitoWebTab`;
  the tab gets the container's accent via `setTabColor`.
  `src/ui/input.zig` + `src/ui/palette.zig`: `new_incognito_web_tab`
  action + palette row. Web-face context menu gains "New Incognito Web
  Tab" and a "New Tab in Container" submenu listing live containers.
- `src/smoke_web.zig`: stage 26 (per-context SOCKS5 proxy: a navigation
  on a proxied context reaches an in-process SOCKS5 probe with
  atyp=domain, hostname unresolved = remote DNS) and stage 27 (two
  contexts -> two proxies -> independent egress = isolation). Both run on
  their own helper AFTER teardown, because a proxied request context
  makes CEF's cef_shutdown noisy (it exits on SIGSEGV even after clean
  per-object teardown — a shutdown-path engine artifact, reported not
  failed; a hang still fails). The probe uses the shared `socks5.zig`.

Verification: `zig build`, `zig build web`, `zig build mux-portable`,
`zig build test` (rc 0), `zig build test-core` (rc 0) all green;
`zig build smoke-web` PASS with stages 26 + 27 passing. The daemon
`stream_open` verb is covered by build + mux-portable + the codec/driver
unit tests; a dedicated smoke-mux stage for it was not added (it mirrors
the proven `forward_open` path). Known limitation: daemon-side DNS is
blocking on the poll loop; the GUI egress bridge connect happens on a
worker thread and degrades to refused connections if the host is
unreachable.

## 2026-08-12: browser roadmap wave 2 — integration notes

The six features above (tree tabs, containers+egress, downloads,
history/bookmarks UI, omnibox, a11y) were built in parallel worktrees
and merged one at a time, each gated on `zig build` + `zig build web`
(+ `mux-portable` and `ldd` for the container branch, which is the only
one that touched the daemon). What the integration cost, so the next
parallel wave can pre-empt it:

- The `hello_ack` capability list in `src/web/server.zig` is a FIXED-SIZE
  array with a separate count (`var caps: [N]` + `ncaps`, plus a
  conditional dmabuf slot). Three branches each appended one capability;
  a textual union merges the entries but NOT the size or the count, and
  the result compiles only if both are corrected by hand. It is now
  `[18]` / `17` advertising downloads, a11y and contexts. A list that
  carried its own length would not have this failure mode.
- Two branches independently discovered that the post-disconnect drain's
  fixed pump count hangs `cef_shutdown`, and each added its own live
  browser counter (`open_browsers`/`openBrowserCount` vs
  `g_open_browsers`/`openBrowsers`). Merged to ONE counter; the comment
  names both causes (a cancelled download's cleanup, an a11y-enabled
  renderer's teardown IPC) because either alone re-motivates it.
- Two branches minted the same smoke stage label "22j"; the a11y stage
  is now 22k (`src/web/CLAUDE.md` and this log follow). Stage labels are
  a flat namespace across a file no single agent owns — grep before
  naming.
- Both-added struct definitions that share a closing brace (`Dl` and
  `Ctx` in `cefhost.zig`) are the one shape a union resolution silently
  corrupts: it keeps both bodies and one `};`. Every conflicted file was
  re-read after resolution, and the tag enum was checked for duplicate
  values (70 tags, none duplicated — the pre-assigned per-agent ranges
  held).

## Browser: userscripts, userstyles, cosmetic filtering

Three "sketerm-shaped differentiators" from the proposal, one wire block
(0xC0-0xC1, capability `userscripts`; caps array now `[19]`/`18`):

- **Cosmetic filtering** (`src/web/filter.zig`): `##sel`,
  `a.com,~b.com##sel` and `#@#` exceptions parse into a cosmetic set;
  `cosmeticFor(host)` compiles the applicable sheet (one
  `{display:none !important}` rule per selector, so one bad selector
  cannot kill its siblings). `#?#`/`#$#` are refused and counted
  (`cos_dropped`). Hiding follows the SAME shield gate as the network
  verdicts — shield off = no cosmetic CSS injected.
- **Userscripts** (`src/web/userscript.zig`): `==UserScript==` parse
  (@name/@match/@include/@exclude/@run-at/@grant) with MV2 match
  patterns; regex includes refused+counted. The helper receives RAW
  sources (`us_script_set`, replace-all) and injects per navigation
  grouped by run-at. GM_* is a no-op `GM_info` only, by design.
- **Userstyles**: per-site user CSS in the daemon web store
  (`userstyles.json`, one style per lowercased host, "" = global),
  pushed as `us_style_set` and applied INSTANTLY to live matching
  views plus at every navigation.
- Storage: daemon web store grew `userscripts.json`/`userstyles.json`
  and web_op verbs `userscript_add/remove/enable/list`,
  `userstyle_set/get/list` (append-only). GUI: `refreshUserContent`
  pushes both sets on every hello_ack and after each edit; management
  UI in `src/ui/webuserscripts.zig` (script list with enable/remove +
  add-from-file, per-site CSS editor), menu rows on the web face.
- Injection limitations (documented at `injectUserContent` in
  cefhost.zig): browser-side `execute_java_script` at load start, so
  `document-start` means "at commit" and cosmetic hiding can flash;
  scripts run in the page's MAIN world (no isolated world on the C API
  path); main frame only.
- smoke-web stages 28 (cosmetic rule hides, sibling kept, shield
  gates), 29 (document-end userscript mutates DOM, replace-all clears),
  30 (userstyle instant apply, survives navigation, clear removes).

## 2026-08-12: per-site cookie / site-data UI (the padlock popover)

The last "table stakes" item from the browser proposal: a site-info
popover on the web toolbar that shows what a site IS, what it was
allowed to do, and what it has stored — with the way to undo each.
Permissions already existed but could never be found again once
answered, and cookies could not be seen at all.

- `src/web/protocol.zig` (both test roots): new append-only 0xC8 block
  — `cookies_req`/`ev_cookies`, `cookie_delete`, `cookies_clear`,
  `sitedata_clear`/`ev_sitedata_done` — plus capability
  `CAP_SITEDATA`. **Cookie VALUES never cross the wire**: an entry
  carries name, domain, path, flags, SameSite, expiry and the value's
  LENGTH. Shipping values would put every open tab's session tokens in
  the GUI's address space for a panel that never renders them; stage 31
  asserts the value byte string is absent from the frame.
- `src/web/cefhost.zig`: `CookieJob`, the only really refcounted
  client-side struct in the file. `visit_url_cookies` TAKES ownership
  of the visitor reference (CEF's CToCpp wrappers transfer, never add)
  and may drop it before returning when the manager refuses, so the job
  is created with two references and one is released after the call —
  the return value is still readable when the answer is composed, and
  the final release is both the "visiting finished" signal and the free.
  Deletion goes through the visitor with `deleteCookie = 1`, never
  `delete_cookies(url, …)`, whose url-only form deliberately spares
  DOMAIN cookies and would leave `.example.com` behind.
- Two engine limits are REPORTED, not hidden, in
  `EvSitedataDone.detail`: `clear_http_cache` is the only cache verb
  the C API has and it clears the whole request context
  (`cache-whole-context`), and localStorage/sessionStorage/IndexedDB/
  Cache Storage have no browser-process API at all, so they are cleared
  by running script in the document — which only works while the view
  is still on that origin (`storage-skipped-origin`). Both documented
  in `src/web/CLAUDE.md`.
- `src/ui/websiteinfo.zig` (new): the popover. Origin, TLS state
  (secure / not secure / certificate exception accepted), the
  permission decisions remembered for the origin with a reset per row,
  the content-blocking switch, the cookie count with an expandable
  list, and Clear cookies / Clear site data behind `ui/confirm.zig`.
  **Nothing here points at the face**: every callback carries the
  view id and resolves it through `webface.faceByView`, so a face torn
  down between a click and its handler resolves to null rather than to
  freed memory. Row contexts own their strings and die with their row
  (GDestroyNotify); the popover itself is severed at the face's
  prepare-destroy choke point and freed in its deinit.
- `src/ui/webface.zig`: padlock button left of the address entry,
  `cap_sitedata`, the `ev_cookies`/`ev_sitedata_done` dispatch, and a
  `cert_exception` flag so the padlock stops claiming a verified
  identity once the user overrode an interstitial (cleared on every
  origin change).
- New bindable action `web_site_info` (palette entry + `sketerm cli
  action`), which is also what made the popover drivable for the
  runtime check below.
- Verification: `zig build`, `web`, `test`, `test-core`, `smoke-web`
  all green. New smoke-web **stage 31** serves ONE page over loopback
  HTTP — a `data:` URL has an opaque origin and stores no cookie at all
  — lets its script set one, enumerates it with scope/flags/value
  length, clears, and re-enumerates to zero; it also checks that a
  request naming an unknown view is ANSWERED rather than ignored.
  Unit tests cover the new frames' round trips and the cookie subtitle
  formatter. The GUI half was additionally driven for real through
  `measure-web` (private daemon + display session + viewer attached
  first): the padlock renders in the toolbar, `sketerm cli action
  web_site_info` opens the popover, and the compositor log shows its
  surface mapping and committing pixels.
- Known limits: the popover's own pixels are an xdg_popup, i.e. a
  separate Wayland surface, so an `appdrive` screenshot of the toplevel
  does not contain them — the runtime evidence is the popup surface's
  commit, not a picture of the rows.
## 2026-08-12: remote browsing — the helper on the mux host, frames inline

Remote-helper frames-inline (browser roadmap): a web pane can now be
backed by a `sketerm-webengine` running on ANOTHER machine's mux
daemon, with paint frames riding the wire in-band — the browser IS
there (pages render, resolve DNS, and keep cookies on the remote host),
not merely proxied through there as an egress container does.

- `src/web/protocol.zig`: 0xD0 block, capability `frames-inline`.
  `frame_mode` (0xD0, shm|inline, sent right after hello, applies to
  buffers allocated afterwards, never turned back off) and
  `frame_inline` (0xD1): per-rect physical-pixel payloads, enc 0 = raw
  BGRA rows, enc 1 = raw-deflate of exactly those bytes via
  `wlhost/zpool.zig` — the SAME codec pool updates on the native app
  pipe use, no new dependency. Large damage is banded (~2MB raw per
  rect) so no message approaches MAX_FRAME; each message is
  self-contained and presentable on receipt.
- `src/web/cefhost.zig` + `server.zig` + `main.zig`: inline mode
  allocates the view buffer as an ANONYMOUS mapping (no memfd, nothing
  announced, no SCM_RIGHTS ever), accumulates paint damage as one union
  rect per view and flushes it only while the outbox is short
  (union-and-flush: a slow wire coalesces bursts instead of ballooning
  helper memory). `--frames-inline` forces the mode AND the software
  path from spawn (dma-buf fds cannot cross a bridge); `--socket-fd N`
  adopts a pre-connected socketpair end (cloexec'd at parse time so CEF
  subprocesses never inherit it), skipping listen/accept entirely.
  `findbin`'s `$SKETERM_WEB_BIN` pin is now authoritative: set-but-
  unusable fails the lookup instead of silently falling through.
- `src/mux/wire.zig` + `daemon.zig` + `daemon_serve.zig` (append-only):
  `web_helper_open` = 34 / `web_helper_reply` = 98 /
  `ChannelKind.web_helper` = 7, welcome capability `web_helper:true`.
  The daemon spawns the helper with the socketpair on `--socket-fd`
  (both ends parked above stdio — the detached-daemon fd-0 trap) and
  bridges the raw protocol bytes as a tcp-style byte channel with the
  LSP lifecycle: own process group, dies with the channel (client
  disconnect included), SIGTERM->SIGKILL via `lsp_reaps`. Missing
  binary = described `ok:false` ("sketerm-webengine is not installed on
  this host"), never a hang. NOT attach-scoped (the fs_op/lsp shape),
  so it works identically under the broker. `sketerm-mux` stays
  libc-only (ldd re-checked) and `mux-portable` stays green.
- `src/ui/webremote.zig` (new): the GUI bridge — a socketpair whose GUI
  end a `webface.Client` adopts as its ordinary helper fd, and whose
  other end a detached worker pumps to the remote daemon
  (`mux_cli.muxConnect`, so ssh/udp/`sock:` hosts all work). Failure
  reporting is by construction: the worker records a reason and closes
  its end; the HUP is the notification and `Client.lost()` shows the
  copied reason. No idle handback, nothing to fence.
- `src/ui/webface.zig`: `Client` is no longer a singleton — a per-host
  registry (`clientForHost`, never freed: that immortality is the
  existing liveness fence) beside the local `g_client`; every `WebFace`
  carries `cl: *Client` and view ids are minted from one process-wide
  counter so id-only widget contexts resolve via `findFaceGlobal`.
  Remote clients post `frame_mode inline` before any view and FAIL
  LOUDLY (described, not black) when the daemon lacks `web_helper` or
  the helper lacks `frames-inline`. `onInline` materialises the buffer
  the memfd path would have mapped (anonymous mapping in the same
  `MapRef` shape) and presents through the ordinary `onDamage` path, so
  GSK still uploads only the damaged region. Containers gain
  `remote_host` (`createRemoteContainer`; mutually exclusive with
  egress); a container's proxy url is stripped when published to a
  remote helper (its loopback is the wrong machine). Devtools splits
  pin the SOURCE face's client. Input/navigation/find/zoom/semantic/
  a11y ride the protocol unchanged over the bridge.
- Surfacing: remote containers appear in the existing "New Tab in
  Container" submenu; `web-container` (control socket: name, host,
  remote:true, ephemeral) creates one and `web-open` grew `container=` —
  the same scriptable surface the rest of the container feature has.
- Degradation seams (documented, deliberate): downloads on a remote
  helper are DECLINED with a toast and Print-to-PDF is greyed out —
  both would write files on the helper's host at a local-looking path.
  The fetch-back design (helper staging dir -> daemon `file_get` ->
  local pick) plugs into `onDownloadOffer`'s `isRemote()` branch.
- Tests: protocol round-trips for the 0xD0 block (both roots via
  protocol.zig), wire append-only values, and a daemon unit test
  (missing helper = described refusal; a spawn bridges chan_open +
  reply and retires on child EOF, env pin saved/restored). Smoke:
  stage 32 in `smoke-web` runs the WHOLE remote path on one machine —
  a private `sketerm-mux` (spawned from argv[2], SKETERM_WEB_BIN
  pinned, isolated XDG_STATE_HOME, killed by exact pid) serves
  `web_helper_open`; the rig bridges the byte channel onto a socketpair
  (the webremote shape) and asserts: inline frames arrive and the red
  page's centre pixel is red with ZERO frame_buffer frames and ZERO
  descriptors crossing (32a); deflate engaged; steady-state damage on a
  16x16 animating box stays under 1/8 of the surface (32b — no full
  frames for cursor blinks); a mousedown over the bridge repaints
  (32c); helper dies with the channel and the daemon exits on SIGTERM.

Verification: `zig build`, `zig build web`, `zig build test` (rc 0),
`zig build test-core` (rc 0), `zig build mux-portable` + `ldd
zig-out/bin/sketerm-mux` (libc/libm only), `zig build smoke-web` PASS
including 32a/32b/32c/teardown. Tradeoff recorded: raw-deflate over
banded damage rects was chosen over a video codec — it is in-tree,
daemon-transparent (the bridge never parses pixels), and the damage
economy already bounds steady-state cost; a video-encoded family can
land later as ANOTHER capability without touching these tags. Known
limitations: remote downloads/print-pdf (seam above), one bridge
reconnect requires the pane's Reload (no auto-retry), and a remote
helper's stderr goes to /dev/null on the daemon host (CEF refusal
detail is only visible as the described channel failure).
## Hamburger menus harmonized across the suite

Five surfaces had a primary menu and three different families behind
them; they are one family now (`classicmenu`), all ending in the same
Help tail:

- **Terminal window** (`src/ui/winmenu.zig`, new): a hamburger END-MOST
  on the headerbar, carrying the 6px flush-right margin the overview
  button used to have. Its rows are `menu.zig`'s spec rows, taken
  through the new `menu.labelFor`/`menu.iconFor` and dispatched through
  `Pane.runMenuAction` — the same `Sink` a right-click row uses, so no
  verb is wired twice.
- **Web face**: a toolbar hamburger sharing the page context menu's
  handlers and `MenuCtx`; only the row list differs (no link rows, plus
  find, zoom and the downloads strip toggle).
- **Standalone editor and viewer**: their private popover-of-buttons
  menus are gone. The viewer's four popover-only verbs became one
  `VERB_ROWS` table that the canvas context menu expands too, and its
  metadata block became owned TEXT rendered per popup (a widget cannot
  outlive a menu that is rebuilt on every open). `src/ui/widgets.zig`
  went with them.
- **Shared** (`src/ui/appmenu.zig`, new): one `AdwAboutWindow` builder
  per identity plus a Keyboard Shortcuts window generated from the
  ACTIVE binding table (`input.rebuildBindings`), so the cheat sheet
  cannot drift from what `input.zig` dispatches. `appendHelp` puts both
  on any classicmenu in two lines. Files' menubar About is now this one.

`smoke-atspi` gained a stage that activates the hamburger over the a11y
bridge (every rect reports 0,0 on Wayland, so there is no honest pixel
to click) and asserts its rows are real accessible objects.
## 2026-08-12: WebExtensions MV2 host foundation (stage 3 of the staged plan)

The browser can now host targeted MV2/Firefox-flavor WebExtensions —
the FOUNDATION of proposal stage 3, built to grow toward the curated
tier-1 list (uBO etc.) without restructuring.

- Pure modules (`src/web/webext/`, both test roots): MV2 match-pattern
  engine (`match.zig` — `*` scheme means http/https/ws/wss only, `*.`
  subdomain boundary, `<all_urls>`, query-stripped path glob), Manifest
  V2 parser (`manifest.zig` — name/version/description/permissions/
  content_scripts/background/browser_action/default_locale; MV3 is
  REJECTED loudly), `storage.local` JSON model with `onChanged` deltas
  (`storage.zig`), and a from-scratch ZIP/XPI reader on
  `std.compress.flate` (`zip.zig` — central-directory driven, STORE +
  DEFLATE; no zip reader existed in-tree).
- Protocol: capability `webext`, tags 0xB0-0xB3 (`webext_set`,
  `webext_remove`, `webext_list_req`, `ev_webext_state`); 0xB4-0xBF
  reserved for the later blocking-webRequest held-request pair. The
  `hello_ack` caps array is now `[19]`/`18`.
- Helper: `webext/host.zig` owns the loaded-extension registry,
  storage persistence under `$XDG_DATA_HOME/sketerm/webext/<id>/`, and
  `dispatchApi` — THE seam a later wave extends for webRequest.
  `cefhost.zig` hosts each background page as a hidden 1x1 windowless
  browser (never announced, `was_hidden`), injects match-filtered
  content scripts per `run_at` phase from the load handlers, and routes
  `runtime.sendMessage` content->background->reply by gid.
- The content-script bridge REUSES the authenticated semantic channel
  (`semantic.js` gained the `ext-*` sub-protocol): per-extension
  CLOSURES with their own promise-based `browser`/`chrome`
  (runtime/storage.local/tabs/i18n). NOT a true isolated world — CEF's
  OSR capi has none; documented as the ceiling in `src/web/CLAUDE.md`.
- GUI: `src/ui/webext.zig` — registry persisted to `registry.json`,
  republished to a fresh helper on connect, and a "Browser Extensions"
  manager (web pane context menu -> "Extensions…", gated on the
  capability): enable switches, Remove, "Load Unpacked…", "Load
  Extension File…" (XPI unpacked via the zip reader).
- Found + fixed: a browser process that ever hosted a background page
  HANGS in libc's atexit path after a clean `cef_shutdown` (a CEF
  worker outlives it); `web/main.zig` now runs teardown in a block and
  `_exit`s.
- Proof: smoke-web stage 33 with a committed fixture extension — run 1:
  content script injected at document_end mutates the DOM, messages the
  background and gets `{n:42}` back, `i18n.getMessage` resolves; run 2
  (fresh helper, same XDG_DATA_HOME): `storage.local` round-trips
  across the restart. Unit tests for match patterns, manifest parse,
  storage JSON and the zip reader in both roots.

## WebExtensions: MV2 blocking webRequest

- `browser.webRequest.onBeforeRequest` / `onBeforeSendHeaders` /
  `onHeadersReceived` with the MV2 `["blocking"]` opt — the API MV3
  removed, which is the whole reason the host targets the Firefox
  surface. `{cancel:true}`, `{redirectUrl}` and `requestHeaders`
  rewriting all take effect; a listener may return a Promise.
- The decision round trip is IN-HELPER and never touches the GUI or the
  mux wire: CEF's IO thread holds the request (`RV_CONTINUE_ASYNC`),
  the main loop dispatches into the extension's hidden background
  browser, its renderer runs the listener, and the answer comes back
  over the same nonce-authenticated bridge. 0xB4/0xB5 carry
  OBSERVABILITY ONLY (`webext_wreq_stats_req` / `ev_webext_wreq_stats`)
  — there is deliberately no GUI-side decision frame, and the reserved
  range's original note now says why.
- Precedence: the native `filter.zig` verdict runs first and its cancel
  is final; extensions see only what it let through; the per-view
  shield gates both. First cancel wins among extensions.
- EVERY held request is answered on every exit (decision, deadline,
  extension disabled/removed/reparsed, background page or view
  destroyed, helper shutdown). The 500ms deadline CONTINUES the
  request — a broken extension costs filtering, never page loads.
- Two short-circuits keep the fast path fast, both proven by
  `zig build bench-webreq`: an extension whose RequestFilter does not
  match costs +0us (one relaxed atomic load), and a non-blocking
  listener never holds (0.2ms, a fire-and-forget mailbox drop).
  A blocking decision costs ~1.3ms, dominated by the helper's own
  poll/pump granularity, not by IPC or by the listener's work — a
  uBO-shaped listener measures the same as one returning `{}`, and
  spinning the poll cuts the helper-side trip 1307us -> 552us. Numbers,
  config and date are committed in `src/web/CLAUDE.md`.
- MEASURED ceiling: `on_resource_response` has no async callback in CEF,
  so a blocking `onHeadersReceived` RUNS and sees real headers but its
  `responseHeaders` cannot be applied; the drop is counted on the wire
  and pinned by smoke-web stage 34d.
- uBlock Origin 1.73.0 (real Firefox MV2 build) was loaded and does NOT
  run — and blocking webRequest is not what stops it: its background is
  a `page:` ES-module graph we never execute, and there is no
  `chrome-extension://` scheme handler. Full honest gap list in
  `src/web/CLAUDE.md`.
- Proof: smoke-web stage 34a-34d (cancel never reaches the network,
  redirect lands, modified header arrives, held request released by a
  mid-flight `webext_remove`, never-answering listener times out and
  fails open), plus `webext/webrequest.zig` unit tests in both roots.
## 2026-08-12: browser roadmap wave 3 integration notes

Six parallel branches (userscripts/userstyles/cosmetic filtering, per-site
cookie + site-data UI, the smalls batch, remote-helper frames-inline,
hamburger-menu harmonization, the WebExtensions MV2 host) landed in one
integration pass. Gate at `ced8ae6`: `zig build`, `web`, `test`,
`test-core`, `mux-portable` (+`ldd`: libc/libm only) all exit 0, and
smoke-web passes all 52 stages. What the merges themselves taught:

- **The capability array stopped being a merge hazard.** For three waves
  every branch touching `hello_ack` had to be hand-resolved, because
  `src/web/server.zig` carried a fixed-size array plus a separate `ncaps`
  count and a textual union keeps the entries while silently dropping the
  size. The smalls batch replaced it with `unconditional_caps` + a
  `CapList` whose capacity is comptime-derived from the number of `CAP_*`
  decls in `protocol.zig`. The three merges that followed each proved it:
  a new capability is now one appended line, with no size and no count to
  keep in step.

- **A teardown assertion that depends on scheduling passes its own gate
  and then wedges the next run.** `smoke_web.zig`'s `RigBridge.stop()`
  closed the bridge socketpair and then joined the pump thread, commented
  as "closing the socketpair end wakes the loop". It does not: closing a
  descriptor never wakes a `poll` already blocked on it in another thread,
  and the `-1` left behind made every later `poll` ignore the socket
  outright, so the only remaining exit was a `chan_close` an idle helper
  never sends. The stage passed whenever the pump happened to observe the
  client's EOF in the window before `stop()` ran — a coin flip that landed
  heads on its merge gate and then deadlocked the suite for hours. It now
  uses the flag/join/close order its two sibling probes in the same file
  already used. The SHIPPING bridge in `src/ui/webremote.zig` was checked
  and does not share the flaw (self-pipe wake, close after join).

- **Do not resolve a conflict with a blanket textual union.** The
  WebExtensions merge was unioned file-wide by regex and damaged three
  files at once: `EvSitedataDone` lost the closing brace the appended
  section was written over, `cap_webext` landed after `Client`'s methods
  (a field between declarations), and both branches' loopback HTTP servers
  were spliced into each other. Only the first was caught by the compiler
  in the obvious place; `zig ast-check` PER FILE found the rest in
  seconds. Run it on every file a merge touched before trusting a build.

- **Two branches independently needed the same test fixture.** The
  cookie stage and the webext stage each grew a loopback HTTP server,
  differing only in the document served. They are now one `HttpProbe`
  with a `body` field, which is what the no-duplication rule asks for and
  what the collision made obvious.

- **Smoke stage labels are a namespace shared across branches.** Three of
  the six minted "stage 28". Current map: 28-30 cosmetic/userscripts, 31
  site-data, 32 remote frames-inline (32a/32b/32c + teardown), 33 webext.
  Grep `pass("stage` before naming, and remember a rename also has to
  reach `src/web/CLAUDE.md` and this file.

## 2026-08-12: tree-style tabs are the BROWSER's tab surface

The tree sidebar shipped as a mirror of the window's tab strip, which is
not what tree-style tabs are for. It now has two sources, and in a
browser it lists the pages open INSIDE that browser — the window tab is
"the browser", exactly as the editor face owns its own document tabs.

**A pane holds several browser pages (`src/ui/webgroup.zig`).** The new
`WebGroup` owns N whole `WebFace`s in a `TabHost` notebook plus a
`Forest(*WebFace)` for opener nesting, and it — not a face — is what
`Pane.web_ctx` points at. `WebFace.fromPane` answers with the ACTIVE
page, so the ~100 existing pane-scoped callers (navigate, zoom, find,
screenshot, every `web_*` MCP tool) kept working untouched.

Why N faces rather than one face owning N views, which is what a reading
of `webface.zig` first suggests: everything that binds a view to its
widgets is already per-face and already correct — the refcounted frame
mapping, the dmabuf import cache, the pacer and its frame-clock tick,
the discard countdown, held cert/permission decisions, hints, the a11y
mirror, and the `signal_objs` array whose overflow silently drops a
disconnect. A `GtkNotebook` UNMAPS the pages it is not showing, and
`WebFace.setOnScreen` already turns `view_area` map/unmap into
`view_show`/`view_hide` plus the discard timer. So a background page
stops painting, stops costing the engine anything and eventually
discards itself with **no new code and no new state machine**, and a
page is resized when it is shown rather than N times per pane resize.
The alternative would have re-implemented all of that and re-derived
every invariant it encodes.

**The sidebar's visibility is also its mode switch.** While it is open
it is the browser's tab surface: `new_tab`, popups, `target=_blank`,
open-link-in-new-tab and the hint new-tab modifier all become PAGES,
nested under the page that opened them (`WebFace.openInNewTab` is the
one place that decides). While it is closed they are window tabs as
before, and the group falls back to drawing its own in-pane strip so
pages opened earlier are never stranded.

**Rows.** The indent moves the whole ROW (18px per level), so a child's
chip visibly steps in; indenting only the row's content left every chip
the same width and the nesting read as ragged text. The twisty is a
16px column reserved on EVERY row — invisible and untargetable when a
tab has no children — because a title that shifts sideways when a tab
gains a child is what made the old rows unreadable. Rows are our own
chips, not `navigation-sidebar` list rows: that class paints inactive
rows in the background colour, so the list read as a flat wall of text.

**The sidebar is resizable.** The window content box became a
`GtkPaned`; the divider writes `tab_sidebar_width` back, debounced 400ms
(a drag emits notify::position per pixel). Two traps the file browser's
places sidebar had already found: a position set while the start child
is hidden is forgotten, so it is re-asserted on reveal; and the window
paints every `paned > separator` as a solid pane-gap bar, so this one
needs a higher-specificity rule to look like a control. `show_tab_sidebar`
and the width now also apply on `reload_config` — they previously needed
a restart, which made the reload look broken for them.

**Lifetime notes worth keeping.** `Group.adopt` runs every fallible step
BEFORE the widget gets a parent, so a failure leaves `root_box` floating
and the caller's ref_sink/unref is correct — rolling the notebook page
back instead would destroy the box and turn that disposal into a double
free. The sidebar's `group` field is a CHANGE MARKER, never a handle: a
group dies with its pane's web face, so every use re-resolves through
`Window.sidebarGroup()` and the stale pointer is only ever compared.
Closing the last page detaches the whole face, which FREES the group, so
the window is resolved before the call and nothing touches `self` after.

**Verified**, not just compiled: smoke-e2e gained a stage that drives the
real GUI on a display session — it opens a browser tab, asserts that with
the sidebar CLOSED `new_tab` adds a window tab and no page, that with it
OPEN the same action adds a second page to the same pane and no window
tab, then measures the sidebar's width from the selected row's own pixels,
drags the divider, and asserts both the widening and that
`tab_sidebar_width` reached config.conf. `web-list` now reports one row
per page rather than per pane. Layout persistence carries every page and
its parent index (`web/model.zig`), falling back to the single `url` for
a layout written before pages existed.

Unchanged and still red: `copyModeStage` in the same rig, which fails at
the pre-work baseline for unrelated reasons.

## 2026-08-12: the plan audit, and the half of smoke-e2e that never ran

An audit of `docs/proposal-browser.md` section by section against the
code (six parallel readers, claims re-verified by hand) turned up two
things that were WRONG rather than missing, plus a list of genuinely
unbuilt items. The two defects, and a third the fixes uncovered:

**Tree-tab nesting did not survive a restore.** `tree_parent` was
written as the parent's live AdwTabView POSITION and read as an index
into the saved `tabs` array. `collectLayout` skips tabs — one with no
root widget, or a tab whose every pane is transient — and every skip
shifts the two index spaces apart, so a layout containing one restored
children under the wrong parent, or flat. The mapping is now
`Forest.parentIndices`, unit-tested on plain integers in both roots,
and `webgroup.zig` uses it too rather than its own copy of the loop.
`ui/tabforest.zig` is now in the core test root, where a GTK-free
model belonged all along.

**The tree actions acted on a tree the user could not see.**
`tab_collapse`/`tab_expand`/`tab_tree_next`/`tab_tree_prev` always
walked the WINDOW's tab forest, so with the sidebar listing a browser's
pages they folded something invisible. They now follow whatever the
sidebar is showing, and smoke-e2e asserts it: stepping moves the PAGE
while the window's tab selection stays put, collapsing puts a child out
of a step's reach, expanding brings it back.

**`copyModeStage` was red, and had been for long enough that the ~30
stages behind it were dead code.** It was not a product bug: the stage
assumed the shell's output line sat exactly one `k` above the cursor,
which a two-line prompt — or one that swaps itself for a taller one
once the shell finishes starting — makes false, so the motions yanked
from the prompt instead. The row is measured now (`get-text` +
`screen-info`). Unblocking it immediately exposed two more rig bugs
that had never had a chance to run: hardcoded pane ids ("the pane the
split just made is id 2"), which any earlier stage that opens a tab
shifts, and a restore step that DELETED config.conf — which
deliberately keeps the running config, so the defaults never came back.
A dead test is worse than an absent one: it reads as coverage.

Also from the audit list: `web_snapshot`'s `detail` is now a real
session default (the plan asked for per-request AND session default;
only the per-request half existed, hardcoded on every call), and the
history store's daemon is choosable. That last one was a false claim in
our own docs — "daemon-side so it follows you across machines" while
the client always dialled the per-user local daemon. `web_store_socket`
then `$SKETERM_MUX_SOCKET` then the default: a forwarded socket now
gives every machine ONE history, and an isolated instance stops writing
into the user's real store.

## 2026-08-12: command palette synthesis — one ranking system, two views

`docs/proposal-browser.md` asked for the omnibox and the palette to
become "ONE grown-up system: URL / search / history / bookmarks /
open-tabs / commands as pluggable sources in a shared ranking
framework". Ranking was already shared (`src/util/suggest.zig`); the
three things that kept the surfaces apart were dispatch, async, and the
fact that the command set could not be queried without a dialog on
screen. All three are gone.

**Activation moved into the framework.** A `Candidate` used to carry an
opaque `payload: u64` and every consumer re-invented what to do with it.
Sources now declare an `activate` fn that `merge` stamps onto each
candidate, so a row is dispatched by calling `cand.fire()` — one merged
list can hold rows from any number of sources and neither view has a
per-kind switch left. `Source.activate_ctx` exists because a source's
query storage and its dispatch target are often different objects (the
command catalogue reads rows out of itself but dispatches through a
Window).

**Async became a framework concern.** `suggest.Model` owns the query, a
generation counter, and the two hooks a view needs. An IO-backed source
declares `refresh`, gets handed the generation its request answers, and
checks `Model.accepts(gen)` before storing the reply. The omnibox had
hand-rolled this against two anchor bytes and a hits cache. Note that
`webstore.cancelFor` did NOT go away and must not: generations answer
"does this reply still answer the current question", not "is my
callback's user-data still allocated" — different problems, and dropping
the second is a use-after-free.

**The command catalogue is data now** (`src/ui/commandcat.zig`, GTK-free,
in both test roots). It used to be built inside `palette.zig`'s `open()`
interleaved with AdwActionRow construction. Extracting it required
splitting the `Action` enum out of `input.zig` into `src/ui/action.zig`,
because `input.zig` imports `c.zig` and dragged GTK in with it — one
more step of the de-GTK-ing that `tree.zig` and `tabforest.zig` started.

**The source sets genuinely cross over.** The palette gained a tab
switcher: every tab of every window, ranked in the same list as the
commands, activating by switching rather than by doing. The omnibox
gained the command catalogue at weight 0.5 — an address bar is for
addresses first, so a command must be named almost exactly before it
outranks what the typed text already means.

**Terminal-side win: recency.** Activating a command moves it up among
EQUALLY good matches, in one process-wide store shared by both surfaces
("recently used" is a property of the user, not of the window he reached
for). The bonus is capped at 0.04 against the 0.1 gap between match
grades, so it can never promote a row across a grade — recency breaks
ties, it never overrules what was typed. Both halves are pinned by
tests, including that a boosted substring match still loses to a prefix
match.

**Deliberately NOT shared: the list widget.** A shared suggestion-list
view looks like the obvious next step and is the wrong one. The palette's
rows are AdwActionRows carrying icon-theme and keybind lookups, built
once then only re-sorted and shown/hidden; the omnibox rebuilds cheap
GtkBox rows every keystroke because its candidate set changes per query.
One view would have to branch on that, on popover-vs-dialog, on focus
policy and on what Enter means — and it would be GTK code, so everything
moved into it would leave the `test-core` root. The split is one model,
two thin views. The visible consequence: the palette hosts every source
it can ENUMERATE when it opens, and the omnibox additionally hosts the
async ones.

**The sibling pickers adopted the matcher, not the merger.** Three of the
four now match through `suggest.zig` — `app_launcher` and `webhistory`
take `containsFold`, `editorlsp` takes `subsequenceMatch`. None adopts
`merge`, and that is correct: each returns a boolean into a GTK filter
func or a visibility index, and each has a domain order (recency-then-
alphabetical, folder grouping plus manual ordering, server ranking or
document hierarchy) that a global score sort would destroy. The
docblocks say so at the call site now. `editorlsp`'s matcher had claimed
to be "the filtering every fuzzy picker in this codebase already uses"
while being the only subsequence matcher in the tree; adding
`subsequenceMatch` to the framework made the claim true rather than
deleting it. `app_launcher`'s version also failed OPEN — it lowercased
into 256/512-byte stack buffers and returned "matches" on overflow, so a
long query showed every long-named app.

`app_switcher` keeps its own matcher, on purpose. Its rows are
application and session names that need `g_utf8_casefold`, and
`suggest.zig` cannot use GLib because it compiles into `sketerm-mux`'s
test root; the shared ASCII matcher would regress the Música/MÚSICA case
its own test pins. That is a structural limit of the framework, not an
oversight, and it is written down where the next reader will look.

**Verified**, not just compiled. `suggest.zig` and `commandcat.zig` are
GTK-free and carry unit tests in BOTH roots covering activation stamping
and `fire()`, generation-gated async replies (a superseded reply is
refused outright, not merely un-rendered), the before/after merge hook
ordering an arena reset depends on, query truncation, the subsequence
grading axes, `containsFold`'s absent length ceiling, the MRU's
move-to-front and overflow, and the grade-boundary safety property.

One of those tests pins the exact ranking the GUI stage asserts: typing
"tab" puts "New Tab" above "Keyboard Hints", whose DESCRIPTION mentions
Tab and which sits earlier in the catalogue. So a ranking regression
fails in CI with no GUI at all.

smoke-e2e gained `commandPaletteStage`, before `copyModeStage` for the
same reason the tree-sidebar stage is: it opens the palette on the
display session, types "tab", presses Enter, and asserts a window tab
appeared. That assertion is self-validating, which is why it is the one
that matters — with an empty entry the top row is the catalogue's first,
"Copy", and `copy_selection` opens no tab, so a tab appearing proves
both that the entry took the text and that ranking beat the decoys.
Green on every run that reached it; one further run flaked in GUI
startup ("socket never appeared"), before any stage executed.

The stage takes no screenshot on the happy path, which is deliberate
and worth not undoing: AdwDialog presents with a fade and the frame
this rig captures reliably predates the filter being painted, so a
success artefact showed an UNFILTERED palette and read as though the
assertion were bogus. The verdict is behavioural and needs no pixels; a
frame is kept only on failure.

The stage was written while `copyModeStage` was still red and therefore
placed ahead of it. That blocker is gone (see the audit entry above —
the stage assumed a one-line shell prompt), so the ordering is now a
convenience, not a requirement.

## Web accessibility: focus, actions and a caret (2026-08-12)

Stage 1 of the browser a11y plan (a read-only tree projected onto the
session AT-SPI bus) already worked. Stages 2-4 did not, and the env gate
meant none of it ran by default. All four moved.

**A reader is now TOLD, not made to re-walk.** `Proj.publish` diffs the
mirrored tree against a shadow of what the bus was last told and emits
`org.a11y.atspi.Event.Object` signals for what actually changed: focus
(both edges — un-focus the old node, focus the new one, in that order,
or a reader announces the stale one), children added/removed, name
changes, and a small set of states a reader acts on. Two properties are
load-bearing. The FIRST publish primes the shadow silently, because a
reader that just embedded learns the tree by walking it and replaying it
as thousands of signals is pure noise. And a change bigger than a
threshold collapses to one children-changed on the root — a navigation
would otherwise emit a per-node storm saying exactly that. The shadow
deliberately holds no parent: resolving one per node per frame made
publish quadratic in page size, and nothing read it.

**A press is a real click.** `org.a11y.atspi.Action` is served on
actionable nodes, but the projection does not act — it cannot reach the
engine and must not learn how, which is what keeps it GLib-free and lets
the smoke rig substitute its own hook. `DoAction` resolves the node to a
point through the same offset-container chain `GetExtents` walks and
hands it out; the GUI turns that into real `input_pointer` frames at the
node's centre, landing on the same CEF call a human click does. Not a
DOM `click()`: that is not user-activated, so it cannot open a popup or
start media, and pages reject it. `GrabFocus` stays false on purpose —
the only trusted route back is a pointer event, and clicking an element
to focus it would also activate it. The action NAME is Chromium's own
verb ("press", "uncheck"), since the engine already labels every node;
`clickAncestor` is filtered, or every label becomes pressable.

**The caret crosses the wire.** New `ev_a11y_caret` (0x76, capability
`a11y-caret`), because a selection is a pair of (node, offset) endpoints
that may straddle nodes and belongs beside the tree, not on a node.
Offsets are UTF-16 code units — the unit the DOM itself defines text
offsets in, so no engine has to convert — and become character offsets
in the mirror, the only layer that also has the node TEXT. An astral
codepoint is two units but one character, so that conversion cannot be a
subtraction. Converting at the bus boundary is not pedantry either: an
unsnapped byte offset can split a codepoint, and D-Bus rejects a string
that is not valid UTF-8, so the whole reply would vanish. libatspi reads
the caret through the `CaretOffset` PROPERTY, not `GetCaretOffset`.

**MEASURED CEILING, CEF 151.3.16.** A text selection arrives COLLAPSED
to its anchor. Tried three ways: an `<input>` via `setSelectionRange(2,6)`
gave `a=2@2 f=2@2`, a contenteditable via a DOM Range gave `a=5@2 f=5@2`,
and real shift+Right key events produced no frame at all. No
`textSelStart`/`textSelEnd` node attributes exist either. The wire, the
mirror and `org.a11y.atspi.Text` all carry and serve a real range —
smoke-webax proves that whole path against a live bus — so this is the
engine's half alone: a braille display following this browser gets the
caret, not the selected range. smoke-web stage 36 reports it distinctly
and passes, the way the Widevine probe does, and starts announcing the
day an engine reports an extent.

**The env gate is gone.** `a11y/detect.zig` asks the desktop, via
`org.a11y.Status` on the session bus: `ScreenReaderEnabled` (a reader is
running now) or `IsEnabled` (the toolkit-accessibility switch). It asks
`NameHasOwner` FIRST, because `org.a11y.Bus` is ACTIVATABLE and a bare
property read would start the accessibility stack on a desktop that has
none — a side effect we have no business causing and a way to talk
ourselves into a false positive. Every failure resolves to OFF; the only
way to ON is an explicit true from a bus that was already there.
`SKETERM_WEB_A11Y` still overrides both ways. The probe is a D-Bus round
trip, so it runs on the same detached worker as the bus connect and never
on the main loop; a negative answer is cached 30s only, so a user who
starts Orca mid-session is picked up at the next view mint. Whatever the
answer, the CEF state is still set EXPLICITLY on both edges — leaving it
implicit is what let Chromium switch accessibility on by itself and
serialize every page (669f208).

**Proof.** smoke-webax gained three stages, each asserted through the BUS
rather than through our own objects: a focus change received as a real
signal on a SECOND connection with a match rule (the only way to prove
something was EMITTED rather than merely pollable), an Action press
reaching the hook at the node's resolved centre (57,79 through the
container chain, so a routing that clicked the wrong element fails), and
Text answering the field's CONTENT rather than its label. smoke-web
stage 36 is the engine half: it takes the button's rect from the streamed
tree, clicks its centre, and requires the page's own handler to have run.

## 2026-08-12: containers become a product — persistence, a manager, per-site rules

The container ENGINE was already real (a `cef_request_context_t` each,
per-context proxy egress, stages 26/27). The product half was missing:
no way for a user to make a container, and the registry died with the
process — so a "Work" tab came back after a restart looking right (the
tab accent is saved with the tab) while actually browsing in the shared
jar. That is a correctness bug, not a convenience one: the user believes
they are in an identity they are not.

- `src/mux/webstore.zig` (both test roots): `containers.json` —
  `{next_id, containers[], sites[]}`, the whole-file JSON + atomic write
  shape `bookmarks.json` uses. `containerAdd/Update/Remove/Find`,
  `containerSiteSet/SiteFor`. Two keys are deliberately separate: the
  **id** is persisted because the engine derives its on-disk jar path
  from it (`contexts/{jar}-{id}`), and an immutable **jar key** is split
  from the display name so a RENAME keeps the cookies. Ephemeral
  (incognito) containers are never stored — persisting one would
  resurrect a throwaway as a named identity. Egress and remote host are
  refused as a pair on both add and update.
- `src/mux/daemon_serve.zig`: `container_list/add/update/remove` and
  `container_site_set` as `web_op` sub-verbs (append-only; no new mux
  frame number, so nothing collides with other work in flight).
  `sketerm-mux` stays libc-only.
- `src/ui/webstore.zig`: the client half plus `parseContainers` /
  `parseContainerId`, with parse tests.
- `src/ui/webface.zig`: `Container` gains `jar`; `createContainerAt`
  ADOPTS a stored id instead of re-minting per process;
  `createStoredContainer` (the store mints the id, since it is the jar
  key), `renameContainer`, `recolorContainer`, `destroyContainer` (the
  first code to ever send `context_destroy`). `loadContainers` merges
  the store in at `Window.initWithConfig`. Three races closed and
  commented: a container-bound face **holds its view back** until the
  registry lands (an unknown context id silently resolves to the shared
  jar); incognito ids come from a disjoint high range so they cannot
  collide with stored ones; and the helper is published the jar key, not
  the display name.
- Restore: `src/web/model.zig` `PageState.container` + a pane-level copy
  (the `url` duplication rationale), written by `webgroup.paneState`,
  rebuilt by `restorePages` via the new `newPageIn` (the SAVED container,
  not the opener's — a restored tree may mix identities), and
  `winlayout.zig` now uses `attachContainer` for page 0.
- `src/ui/webcontainers.zig` (new): the manager — create / rename /
  recolour / delete, and routing as ONE dropdown (direct / via server /
  browser runs on), which makes the mutually exclusive pair
  unexpressible rather than merely rejected. Reached from "Containers…"
  in the page and burger menus. Rows are built from the live registry,
  so a row can never show an identity the helper lacks.
- Per-site rules: "Always Open This Site In" in both menus;
  `containerForUrl` lets a rule outrank the inherited container, applied
  when a page or tab is CREATED (`attachPage`, `newWebTabAt`).
- `src/ui/tabsidebar.zig`: a container dot on browser PAGE rows — the
  window tab's accent says nothing about which page in a pane is where.
- `src/smoke_web.zig`: **stage 37**. Stages 26/27 assert egress
  isolation and say nothing about STORAGE, which is the half a user
  notices. Both views load the SAME loopback origin in two containers
  (so same-origin policy cannot be what separates them) and the query
  string decides which writes the cookie: it is present in A's
  enumeration and absent from B's, and B's own `document.cookie` cannot
  see it either.

The egress/remote-host exclusion was re-examined and KEPT, with the
reason now in a docblock: an egress proxy is `socks5://127.0.0.1:<port>`
in the GUI process, so on a helper running on another host that url
names the wrong machine's loopback. Lifting it needs the bridge
reachable from the helper's host (a reverse tunnel), which is a
transport feature, not a flag.

Verification: `zig build`, `zig build web`, `zig build test`,
`zig build test-core`, `zig build mux-portable` + `ldd` (libc only),
`zig build smoke-web` with stage 37 passing.

Known limits, deliberate: a navigation INSIDE an open page is not
re-homed into an assigned container — a view's request context is fixed
at `view_create`, so moving it would mean reloading the page under the
user; the rule governs what opens next. Deleting a container does not
scrub its on-disk jar (the daemon does not own the helper's profile
dir, which may be on another host). A container's routing change only
affects views created afterwards, which the manager says in as many
words.

## 2026-08-12 — real MV2 extensions: uBlock Origin blocks

Stage 3 of the WebExtensions plan set the bar at a curated tier-1 list
with uBO as the benchmark. Before this, **none of the four ran** — the
host loaded them, reported them enabled and `ok`, and they did nothing.
uBlock Origin 1.73.0 now runs and blocks; smoke-web stage 35b asserts it
against the real signed XPI.

**An extension needs an ORIGIN, not just a way to run scripts.** That is
the change everything else hangs off. `chrome-extension` turned out to be
unusable — MEASURED: `add_custom_scheme("chrome-extension")` returns 0
(Chromium owns the name, and CEF's alloy runtime serves nothing for it)
while `cef_register_scheme_handler_factory` still answers 1, so the
registration looks fine and every load fails `ERR_BLOCKED_BY_CLIENT` with
the factory never consulted. The origin is therefore
`sketerm-extension://<16 hex>/`, served from the unpacked directory by a
resource handler on CEF's IO thread, with the host derived by hashing the
id (a Gecko id like `uBlock0@raymondhill.net` cannot be a url host).
Firefox splits these the same way.

**Six silent failures, in the order they had to be found.** Each one left
the extension enabled and inert, with nothing in any log:
our own request handler cancelling the extension origin; the
`web_accessible_resources` gate 403ing uBO's serializer WEB WORKER (a
load with no frame) so `serializeAsync` never settled; `browserAction`
being undefined, whose TypeError aborted uBO's own boot; every registered
listener running on every request, so uBO's WAR guard cancelled every
page; a hard-coded `tabId:-1`, which sends uBO down its behind-the-scene
path and made it cancel top-level navigations; and `runtime.reload()`
being a no-op, so uBO's first-run `vAPI.app.restart()` never came back.
The last two are the ones worth remembering: **`tabId` is load-bearing**,
and **an extension that asks to restart and is not restarted just stops**.

**Diagnostics were the actual bottleneck**, so they are now permanent:
a background page's load failures reach the client as console frames
(they previously went nowhere), the API bootstrap reports its own failure
instead of swallowing it, and `SKETERM_WEB_SCHEME_DEBUG`,
`SKETERM_WEB_WREQ_DEBUG` and `SKETERM_WEB_EXT_DEBUG` print the scheme
registration, every blocking decision with its url, and every `browser.*`
call/reply pairing. `SKETERM_SMOKE_WEB_CONSOLE=1` echoes page console
output in the rig, and `SKETERM_SMOKE_UBO_TRACE=1` un-silences uBO's own
boot log, which is what finally located the stall.

**Where each tier-1 extension stands, measured not assumed:**

- **uBlock Origin 1.73.0 — runs and blocks.** Filter lists parse ~2.4s
  after launch; a request named by `ublock-filters` is cancelled before
  it reaches the network. Not working: scriptlet injection (it needs
  `webRequest.onResponseStarted`, a notification-only event here),
  cosmetic filtering beyond the shared-world ceiling, `filterResponseData`
  (no CEF equivalent), and `onHeadersReceived` decisions (counted and
  dropped, the previously measured `on_resource_response` ceiling).
- **Violentmonkey 2.47.0 — does not run.** Its background boot throws a
  TypeError reading `getURL` on an undefined object, and it registers no
  webRequest listener. Its content scripts additionally read
  `window.browser` rather than the injected closure parameter — that half
  is the isolated-world CEILING, since publishing that global in the
  shared main world would hand any page the extension's `storage.local`.
- **Dark Reader 4.9.129 and Stylus 2.4.10 — not claimed to work.** Both
  load and parse; neither was driven to a user-visible result.

`browser.tabs` became real in the process: the GUI owns the tab set and
posts the whole list as `webext_tabs` (0xB6, capability `webext-tabs`),
which the helper DIFFS to synthesise MV2's `onCreated`/`onUpdated`/
`onRemoved`/`onActivated`. Replace-all, like `us_script_set`, so a
dropped frame cannot desynchronise anything. `runtime.connect` Ports,
`tabs.sendMessage` into content frames, a real `sender` (`tab`, `url`,
`frameId`), per-frame `all_frames` injection, object storage defaults and
i18n placeholder substitution all landed alongside.

Two install defects went with it: the extension id no longer moves with
the version (it prefers `browser_specific_settings.gecko.id`), so
installing v2 REPLACES v1 instead of minting a second enabled copy with
empty storage and orphaned files; and a failed install says why, rather
than `catch {}` leaving a picked MV3 XPI to do nothing at all.

## 2026-08-12: closing the plan audit — five branches integrated

The audit's list, worked to completion except where an engine or an
absent machine stops it. Five agent branches were rebased onto master
(never merged) with a gate between each, plus the direct work recorded
above.

**Scroll is on the wire now.** `web/model.zig` used to say scroll was
absent "on purpose: the helper protocol reports no scroll offset". It
does now — `ev_scroll` / `scroll_to` (0xC2, capability `scroll`),
straight from Chromium's `OnScrollOffsetChanged`. The numbers are
carried through UNINTERPRETED: whatever the engine reports is what goes
back, so a restore lands where the save happened without our arithmetic
having to agree with the engine's units. Reporting is throttled to
150ms (the callback fires per scroll step) and the resting position
still gets out, because the throttle owes the client whatever differs
from what it last sent and the watchdog turn flushes it. The offset is
applied only after the load finishes: a document still growing clamps an
early scroll to its current height and lands short.

**OCR had two real defects**, both in the path the MCP `app_read_text` /
`app_wait_text` tools ride on:

- We handed CEF's B,G,R,A frames to an API documented as taking R,G,B,A,
  alpha channel and all. It gets 8-bit luma now, which is what tesseract
  thresholds anyway.
- "auto" scale upscaled by 4096/longest-edge, so every window under
  ~1365px — nearly all of them — was recognized at 2x-3x nearest
  neighbour. MEASURED: an ordinary GTK dialog reads its label correctly
  at 1:1 and reads as NOTHING at 2x. Auto now means native first,
  upscale only if that found nothing.

A dark-image inversion pre-pass is deliberately absent and the docblock
says why with numbers: it is the obvious idea, tesseract already handles
inverted text, and a global invert makes it invert twice — the same
frame reads "cannot load /LEFTFAILURE cannot load /RIGHTFAILURE" as
captured and "- -" inverted. I added it, measured it, and took it out.

**An OCR limit is left open and named**: feeding identical pixels
through our binding still under-reads badly (psm 6 -> "- -", psm 11 ->
nothing) where the tesseract CLI on the same file reads every word, and
sweeping psm and ppi changes nothing. Something in the binding is still
wrong. The e2e stage that tripped over it no longer treats OCR as a
product verdict: the click assertion beneath it (the button paints, is
hittable, routes a trusted interaction back to MCP) is strictly
stronger, so OCR is advisory there.

> **CORRECTED 2026-08-13.** The binding was never wrong. `toGray` was
> dropping the frame's premultiplied alpha, which turned a real window's
> transparent shadow into pure black and pulled tesseract's global Otsu
> threshold off the text. See "the binding was never broken" below —
> this paragraph is kept for the record, not as a live claim.

### Still open, and what each needs

- **Filter-list subscription.** Lists are still hand-dropped into
  `$XDG_CONFIG_HOME/sketerm/filters`. The helper is the only process
  that can fetch over HTTPS, so this needs a refcounted
  `cef_urlrequest` client — and the one genuinely refcounted
  client-side struct we have (`CookieJob`) is documented as droppable by
  CEF *before the call returns*. Worth doing carefully, not quickly.
- **`"...and N more"` list collapsing** in the semantic walk: today it
  stops at `MAX_NODES` with no marker.
- **Reader results carry no semantic ids**, so a `web_read` hit cannot
  be fed to `web_act` without a separate snapshot.
- **Capability-based helper routing** is designed for (20 flags, latched
  per client) but has nothing to route to until a second engine exists.
  Building a selection policy now would be untestable scaffolding.
- **macOS/Windows for the browser.** Needs a macOS CEF distribution and
  the signed-helper-bundle layout; this repo's own lesson is that a
  green cross-compile is not a working macOS build, so it stays
  unproven rather than claimed.

> **CORRECTED 2026-08-13.** Filter-list subscriptions are now fetched
> and proven end to end. See "filter-list subscriptions: stateful and
> failure-open" below; the earlier bullet remains as the record of the
> previous gap.

## 2026-08-13: a full audit of the unpushed range — 28 defects, one critical

A ten-dimension adversarial audit of the whole `origin/master..master` range
(42 commits, ~12.6k added lines), every finding then handed to a separate
reader whose job was to REFUTE it. 28 survived, 6 did not. All 28 are fixed
here. The three that matter most were all invisible to a green suite.

**A percent-encoded slash escaped the extension package (critical).**
`webext/assets.zig` split the url on the RAW `/` and percent-decoded each
piece AFTERWARDS, so `%2e%2e%2f%2e%2e%2fetc%2fpasswd` arrived as ONE segment,
decoded to `../../etc/passwd`, matched neither `.` nor `..`, and was memcpy'd
whole into the on-disk path — then served with `Access-Control-Allow-Origin:
*`. Any page on any site could read any file the helper's uid could, as soon
as one extension was installed. The test named "resolve REFUSES every escape,
however spelled" passed the entire time because every escape in it is spelled
with a literal `/`. A decoded separator is now refused outright, there is a
containment backstop as an explicit branch (this tree builds ReleaseFast,
where `assert` compiles away), and the test grew the spellings that were open
plus a property check over attacker-shaped inputs.

**Any page could mint a live `browser.*` for an installed extension.** Only
`publishGlobals` was nonce-gated; `extInject` built the real api for ANY
`ext-inject` and passed it to `new Function(...)` as `browser`/`chrome`/
`self`. The comment reasoned that running your own code in your own closure
costs a page nothing — true, but the closure is HANDED the api, so it
isolated nothing. `window[SLOT]` is discoverable, so a page could read the
whole tab list, navigate the active tab, and read/rewrite that extension's
`storage.local`. The nonce now authenticates every `ext-inject` (the
content-script producer carried none at all); `priv` still authorizes the
globals. Authentication and authorization are different questions.

**And that fix would have been defeated by the next one.** An `about:blank`
iframe bypassed the whole `web_accessible_resources` gate, and what it could
fetch includes the generated bootstrap — which carries the bridge nonce in
plaintext. The `about:` relaxation is now limited to real navigations, and
the generated paths require a strict host match. Measured before designing
it, with the gate's own debug print: the generated background document and an
author's `background.html` arrive as `RT_MAIN_FRAME` with a frame, the
bootstrap as `RT_SCRIPT` with the frame already at the extension origin.

Two more that made the suite itself untrustworthy:

- **stage 35b never asserted the zero-hit network check** that its own
  comment and `src/web/CLAUDE.md` both cite as the proof uBO blocks. The hit
  count was loaded and PRINTED. A cancel landing after dispatch, a
  redirect-to-abort, or an unrelated socket reset all look identical from the
  page. The per-attempt baseline now exists.
- **`browser.tabs` was advertised and never produced.** The only producer of
  `webext_tabs` in the tree was the smoke rig, so the shipped GUI sent no tab
  list and every extension saw `tabId -1` — which MV2 defines as "not
  associated with a tab" and which, by the measurement recorded two commits
  above it, makes uBO cancel the top-level navigation of every page. The GUI
  posts its real tab list now.

The rest, briefly: `spawnBackground` never set an accessibility state, so an
extension's hidden page could have a11y auto-enabled and its tree adopted by
the one enabled client view (the same defect as 669f208, on the other browser
creation path); the extension scheme factory was registered only on the
global request context, so extension urls failed silently in every container;
the daemon's `containerAdd`/`containerSiteSet` errdefers spanned the store
write and freed records the list still owned; `g_store_socket` aliased a
per-WINDOW config arena; `loadContainers` ran before `web_store_socket` was
applied and its failure LATCHED an empty registry for the session; the a11y
connect handback scanned only the local client; deleting a container left its
per-site rules live; `ext-port-close` ignored the calling view, so gid
enumeration disconnected other tabs' Ports; and extension-supplied JSON ints
were narrowed with `@intCast` in a ReleaseFast build, so `windowId: 2**32+1`
answered with window 1's tabs.

### The OCR defect: the binding was never broken

The previous entry recorded that "something in the binding is still wrong",
because identical pixels read perfectly through the tesseract CLI and came
back as `- -` through us. That conclusion was wrong, and it is worth
correcting rather than leaving in the log.

Reproduced standalone (no repo deps, pixels embedded, the API dlopen'd
exactly as `ocr.zig` does it), then split: the CLI gives the SAME `- -` when
fed our exact grayscale bytes, while reading the colour PNG perfectly. So the
binding was fine and `toGray` was destroying the image.

Our frames are PREMULTIPLIED Wayland ARGB, and a real window is transparent
wherever its shadow and rounded corners are — 7% of the measured 928x709
panel snapshot. Dropping alpha turned all of that into pure BLACK, a colour
nothing on screen had. Tesseract's default global Otsu then split
black-vs-everything and put the actual text (0.2% of the pixels) on the
background side of the threshold. The PNG we dumped to compare against
CARRIED its alpha, so leptonica blended it over white and the CLI never saw
the fabricated black — which is exactly why "same pixels, different result"
looked impossible.

Compositing the premultiplied alpha over white restores the CLI's exact
reading, and measured better than any thresholder change (Sauvola reads it
too, but with character errors). Byte 0 is red, not blue, verified from a
real snapshot; the weights follow, so `toGray` and `meanLuma` no longer
disagree about an identically laid-out buffer.

`smoke-e2e` passes end to end again as a result, which also un-hid the rest
of that rig: it now runs 34 stages.

### A timing bet, replaced

stage 33 failed once and passed on the re-run. Its cause was a fixed 1500ms
sleep whose own comment said what it was for — "give the background page a
moment to come up (its listener must exist before the content script's
message arrives)". A wall-clock bet loses on a loaded machine, and it loses
as `reply:null:hello`: i18n and storage working, only the reply missing. The
fixture's content script now RETRIES its `sendMessage` until the background
answers, so the assertion means "the message got through" rather than "it got
through within a budget".

## 2026-08-13: filter-list subscriptions: stateful and failure-open

Configured `filter_list` URLs now reach the helper after capability
negotiation, including an empty REPLACE-ALL when the final subscription is
removed. The GUI owns transactional copies independent of each window's config
arena; the helper owns the deduplicated subscription set, refresh schedule,
cache reconciliation and live filter-engine reload. URLs must be bounded
`http://` or `https://` values with a host before they enter config or the
helper's network stack.

The wire gained append-only completion event 0xC5. It reports the reconcile
serial and active/fetched/updated/failed/rule counts only after every fetch has
retired and accepted files have been reloaded. This replaces timing guesses in
callers and in smoke-web. Removed subscriptions delete only exact generated
cache and staging names, then reload immediately; similarly-prefixed user files
remain untouched.

Fetching is failure-open and bounded. Requests bypass the HTTP cache and do not
retry 5xx responses; only successful 2xx responses below 16 MiB that look like
filter syntax reach a sibling `.part` file. That file is opened with
`O_NOFOLLOW|O_CLOEXEC`, written through EINTR, fsynced, closed and atomically
renamed. HTTP errors, HTML/captive-portal bodies, oversize responses, allocation
failures and write failures leave the previous working list in place.

`FilterFetch` is Host-owned and genuinely refcounted. CEF's CToCpp
`cef_urlrequest_create` wrapper consumes both the request and client references;
the Host owns the returned URLRequest handle plus a second client reference
until later-loop retirement. Releasing the request after create caused a CEF
SIGTRAP on the first successful fetch and was caught by the new stage. A new
subscription generation cancels older requests and ignores their stale
completion; disconnect cancels all requests and pumps CEF until their callbacks
drain, bounded by the existing helper shutdown deadline.

Tests cover URL/cache-name/body/staleness decisions in both unit roots, config
parse/serialize/clone and protocol round trips. smoke-web stage 39 uses a
loopback list/resource server to prove one fetch for duplicate URLs, accepted
bytes on disk, zero network hits for the blocked resource while a control
request arrives, empty removal, preservation across HTTP 503, HTML and oversize
replacements, and teardown while a request is still in flight.

Verification: changed-file `zig ast-check`, direct `zig test` for
`filtersub.zig` (5/5) and `protocol.zig` (32/32), `zig build web`,
`zig build test-core --summary all` (2028 passed, 6 skipped), and
`zig build test --summary all` (2448 passed, 5 skipped). smoke-web stage 39
passes end to end. The latest full modified run continued through stage 37,
then failed the independent stage 34a; an untouched `5b84a00` worktree likewise
continued past its known request-context CEF shutdown SIGSEGV and failed stage
34c. The full rig is therefore not claimed as a clean pass here.
## 2026-08-13: WebExtension browser actions and real popup pages

Installed MV2 extensions now put their declared `browser_action` or visible
`page_action` in the active browser page's GTK toolbar. The two manifest keys
stay distinct: browser actions start visible, while page actions start hidden
and `pageAction.show`/`hide` changes one tab. The button carries the extension
icon, title, UTF-8-safe badge, badge colors and enabled state. Runtime calls
update global or per-tab action state, and a toolbar click either fires the
declared action namespace's `onClicked` with the active tab or opens the
declared popup. JavaScript exposes only the declared MV2 namespace: page
actions do not inherit browser-action badge/enablement methods, and neither
kind receives the MV3 `action` alias. `browserAction.openPopup()` from a privileged
extension page opens the active focused tab's native toolbar popup; content
scripts and hidden, disabled or popup-less actions reject. Popup controls
receive pointer, scroll, key and focus input; Escape and clicking away close
the popover.

The responsibility split is explicit. `web/webext/action.zig` owns pure
manifest-default and tab-override state. The helper validates that an
activation names a live enabled extension and the active mirrored tab, then
either dispatches the click into its background page or creates a real
extension-origin CEF browser. `ui/webaction.zig` owns only GTK presentation,
frame import and trusted input. Action snapshots update existing buttons in
place when the extension ids are unchanged; rebuilding the anchor on every
badge update would close a popup from inside its own startup. WebExtensions
are deliberately local-browser only: installed-package paths belong to the
GUI host, and no package-transfer/remote-registry protocol exists. Remote
clients therefore suppress the three WebExtension capabilities and the menu
says `Extensions (local browsers only)` rather than sending unusable paths.

The append-only wire additions are capability `webext-action` and frames
0xB7 action snapshot, 0xB8 trusted activation, 0xB9 popup lifecycle and 0xBA
programmatic popup request.
Client-minted popup views start at `0x60000000`, separate from ordinary
client views, DevTools and the helper's hidden background range. Popup CEF
browsers force software frames: local clients receive memfd damage and remote
clients receive the existing inline-frame family. Closing the GTK popover
destroys the helper view; owner-page teardown and extension disable/removal
close it in the other direction.

The security boundary was tested rather than inferred. Popup HTML receives
the extension bootstrap before its first author script, including
`runtime.getManifest()`. CEF can still report the previous frame URL while
that parser-blocking bootstrap is fetched, so the scheme handler accepts an
exact target-scheme AND target-host match from
`get_first_party_for_cookies`. Smoke stage 40 proves ordinary pages,
`about:blank`, `data:`, same-host HTTP, same-host self-signed HTTPS and another
extension's origin cannot fetch the privileged bootstrap or obtain extension
globals. Extension ids are validated at every persisted, GUI and helper wire
boundary before they can reach fixed buffers, registry slots or paths.

Files affected: the action, manifest, host, asset, origin, tab and webRequest
modules under `src/web/webext/`; `src/web/cefhost.zig`, protocol and semantic
bridge; the web action/face/group/registry UI plus sidebar, remote-control and
window routing; `src/smoke_web.zig`, `src/smoke_e2e.zig` and subsystem/session
documentation.

Tests added: pure action-state coverage for global/per-tab separation,
page-action visibility, badge colors, sized icons, popup clearing, tab cleanup
and invalid tab ids; manifest action separation and sized-icon selection;
protocol round trips; smoke-web stage 40 for popup paint/runtime APIs,
declared namespace shapes, page-action visibility/clicks, background
`openPopup`, no-popup clicks, missing assets without frames, malformed wire
ids, exact-origin isolation and both teardown directions. The
GTK E2E installs an isolated extension before launch, checks per-tab blue and
orange icons across WebGroup switches, opens and drives the native popup with
trusted input, closes it with Escape and owner teardown, and requires the
exact helper pid to exit with the GUI. It runs when `sketerm-webengine` is
built and reports a clear skip otherwise.

Final verification: `node --check src/web/semantic.js`, `git diff --check`,
`zig build --summary all` (59/59), `zig build web --summary all` (7/7),
`zig build test` (2462 passed, 5 skipped) and `zig build test-core` (2041
passed, 6 skipped). `SKETERM_WEB_GPU=0 zig build smoke-web --summary all`
passed 10/10, including every stage 40 assertion and real uBlock Origin stage
35b. `SKETERM_WEB_GPU=0 zig build smoke-e2e --summary all` passed 61/61,
including the required native browser-action toolbar/popup stage.

The native-GPU smoke path was also attempted twice. Stage 24 advertised
`frames-dmabuf`, but CEF logged `Unable to allocate frame for first frame
capture: OOM?` and delivered no dma-buf frame. This is a host GPU allocation
failure outside the action path; the complete forced-software helper and GTK
matrices pass. A native GTK run independently completed the browser-action
stage before a later unrelated palette assertion failed.

The GTK correction pass also exposed an existing tree-sidebar lifetime bug:
rows borrowed an `AdwTabPage` past finalization and later disconnected its
title handler. Window-tab rows now retain the page until their handler is
disconnected. Remote-control focus now targets a visible web face instead of
its hidden shell, and `close_tab` follows the visible browser-page sidebar the
same way new/step/collapse already do, so popup-owner teardown is deterministic
and the action surface stays internally consistent.

Known limits: `setIcon` accepts extension package paths but not `ImageData`;
popup size is a fixed 420x520 logical pixels rather than manifest/content
negotiated. WebExtensions remain unavailable for remote browser helpers until
package transfer and a remote registry exist.

## 2026-08-13: WebExtension capability and focus hardening

Every enabled extension instance now receives a random 128-bit capability.
The privileged bootstrap, API calls/results, routed messages/replies, Ports,
webRequest holds, events and action clicks carry it; the helper authorises the
capability before accepting the claimed extension id. Reinstall, enable/disable,
`runtime.reload`, removal and helper restart rotate or revoke the capability.
The bridge sends `ext-revoke` before destroying an instance, which disconnects
old Ports and rejects pending and future calls made through stale API objects.
An extension can no longer impersonate another by replacing only the `ext`
field, and stale pages cannot retain browser authority after lifecycle changes.

Helper failures now reject JavaScript Promises with their error text instead of
resolving `undefined`. APIs that are present for compatibility but not
implemented also reject explicitly; `runtime.getPlatformInfo()` and
`runtime.getBrowserInfo()` remain real resolved calls. Routed messages record
both endpoint views and their owning extension, and view/extension teardown
retires routes, Ports, webRequest holds, popups and origin slots without leaving
a Promise waiting on a dead recipient. The CEF extension resource handler's
`has_at_least_one_ref` callback now tests `refs >= 1` rather than reusing the
exactly-one predicate.

`browserAction.openPopup()` no longer resolves when the helper merely posts a
request. Append-only frame 0xBB (`webext_open_popup_result`) correlates the GUI
attempt, and the Promise resolves or rejects only after the focused native
toolbar reports whether it created the popover. Failure details and GTK badge,
tooltip and popup error truncation preserve complete UTF-8 codepoints.

The GUI tab mirror now publishes real process-wide window ids, per-window tab
indices, the GTK-selected tab, focused split pane, active WebGroup page and the
application's active toplevel. Per-tab action state stays cached, while native
presentation is gated locally: only the active window's focused pane presents
its toolbar, focus changes hide or restore cached state without a helper round
trip, and a late replace-all snapshot cannot make an inactive split or window
clickable. Programmatic popup authorization uses the same focus rule.

Files affected: `src/web/semantic.js`, `src/web/cefhost.zig`,
`src/web/protocol.zig`, `src/web/server.zig`, `src/web/webext/host.zig`,
`src/web/webext/origins.zig`, the WebExtension fixture scripts,
`src/ui/webaction.zig`, `src/ui/webface.zig`, `src/ui/window.zig`,
`src/ui/tabchrome.zig`, `src/ui/termsinks.zig`, both test roots and the two
smoke rigs.

Tests added or expanded: core host tests prove capabilities are extension-bound,
rotate and expose no MV3 `action` alias. Smoke-web proves two-extension
impersonation rejection; helper and local unsupported-API Promise rejection;
rotation across reinstall, toggle, reload, removal and helper restart; stale API
rejection; positive, negative, mismatched and UTF-8 popup acknowledgement; and
same-host HTTP/HTTPS plus inherited-origin isolation. Smoke-e2e drives real
split panes and real GTK toplevels, checks stale toolbar clearing in both, opens
a popup from the focused second window and verifies the primary window's cached
action returns when focus does.

Verification: changed Zig files passed `zig ast-check`, `node --check
src/web/semantic.js` passed, `git diff --check` passed, `zig build test-core
--summary all` passed 2042 tests and `zig build web --summary all` passed.
`SKETERM_WEB_GPU=0 LIBGL_ALWAYS_SOFTWARE=1 zig build smoke-web --summary all`
passed all 40 stages and real uBlock Origin. The native GPU run reached stage 24
then hit the existing CEF `Unable to allocate frame for first frame capture:
OOM?` path with no dma-buf frame. The software GTK smoke repeatedly passed the
new browser-action stage, including split/window focus and popup teardown, then
failed in the unrelated terminal scrollbar mouse-reporting stage. A detached
run of the pre-hardening commit also failed in terminal protocol input, earlier
than that stage, so this host cannot supply a green full smoke-e2e verdict for
either revision.

Known limits remain unchanged: popup size is fixed at 420x520 logical pixels,
`setIcon` does not accept `ImageData`, and WebExtensions remain local-browser
only.
