# Autonomous build session — 2026-04-25

This file is a record of the autonomous implementation session that
took the project from "13 markdown plan documents" to a working
v0.1 binary.

## Time
- Started: ~00:44 local
- ~194 commits, ~10.9 kLOC of Zig + 8 kLOC vendored stb_image
- 209 unit tests pass

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

Total: **209/209 tests pass**, up from 102.

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
