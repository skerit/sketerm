# Autonomous build session — 2026-04-25

This file is a record of the autonomous implementation session that
took the project from "13 markdown plan documents" to a working
v0.1 binary.

## Time
- Started: ~00:44 local
- ~100 commits, ~7.0 kLOC of Zig + 8 kLOC vendored stb_image

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
zig build test                     # 46/46 tests
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

Things added between commits 67 → 100:

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

## What's left

Remaining post-checkpoint TODO list:

1. Reflow with soft-wrap tracking on resize. Today resize pads /
   truncates per row.
2. PTY worker thread allocations leak on hard SIGTERM (cleanup
   ordering wrt thread join).
3. NVIDIA proprietary GL — falls back to llvmpipe on this laptop.
4. OSC 8 in selection-extract — preserves text but not the URI.
5. OSC 4 palette query/set — palette is currently a comptime const
   in `render/grid_pass.zig`, would need to become runtime state.
6. OSC 12 cursor-color set/query.
7. modifyOtherKeys (CSI > 4 ; Pp m) — for emacs/vim users who want
   distinct codes for Ctrl-Shift-A vs Ctrl-A.

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
