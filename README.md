# sketerm

A native GTK4 terminal emulator for Linux, written in Zig from
scratch.

Built around a feature set that no single existing terminal
emulator satisfies: full image-protocol support (Sixel + Kitty +
iTerm2), real xdg_popup context menus with first-class
split/tab/rename actions, stable group-named tabs, layout
persistence — without being Electron, without being a
multiplexer-in-a-terminal, and without being VTE-based (which on
current Arch lacks OSC 52).

## Philosophy

Own the stack. Read existing implementations closely —
understand the algorithms — then reimplement cleanly in our own
code. No vendored terminal cores, no wrapper crates around other
people's emulator libraries. The escape-sequence specs are public,
the image-protocol specs are public, and Paul Williams documented
the state machine forty years ago. There is no magic here, only
craft.

External dependencies are limited to system C libraries every
Linux terminal depends on:

- `gtk4` + `libadwaita` — windowing, tabs, splits, popover menus
- `freetype` + `harfbuzz` — glyph rasterization + text shaping
- OpenGL ES + `libepoxy` — grid rendering
- `lua` — plugin scripting (post-v1)
- `glib` — event loop (ships with gtk)

## Status

**v0 in progress.** Most of M0-M9 prototyped over a single autonomous
build session. See `git log --oneline` for what's landed.

### What works
- **M0** — `zig build` (Zig 0.15.2; ReleaseSafe default to dodge
  gcc 15's `.sframe` linker incompatibility); GTK4/libadwaita
  window opens.
- **M0.5** — GL spike: `GtkGLArea` + `set_use_es(TRUE)` + share
  groups verified (PASS via Mesa llvmpipe; NVIDIA EGL fails on
  this hardware → falls through to software renderer).
- **M1** — PTY spawn/poll/read in worker thread; SPSC ring with
  `drain_pending` coalescing; main-thread drain via
  `g_main_context_invoke`.
- **M2** — `Cell` (`extern struct`, 8 B), `StylePool`, `Screen`
  with active + alternate buffers and 10k scrollback. Apply for
  Print, CR/LF/BS/TAB, cursor moves, erase, scroll, modes (1049,
  7, 6, 2004, 1004, 25), full SGR with truecolor, DECSCUSR.
  Resize preserves content + pushes to scrollback.
- **M3** — FreeType atlas (R8 page, shelf-pack), GL ES 3.0 grid
  shader (textured quads, two-pass bg+glyph), `GtkGLArea` pane,
  cursor with shape variants + 500 ms blink.
- **M4** — Keyboard (xterm encoding, `modifyOtherKeys=1`), paste
  with bracketed-paste-mode awareness, resize → `TIOCSWINSZ`,
  selection (mouse drag → `Ctrl+Shift+C` copy via `GdkClipboard`),
  IME via `GtkIMMulticontext` (fcitx5 / ibus).
- **M5** — OSC 0/2 title, OSC 7 cwd, OSC 8 hyperlinks (storage:
  `Cell.reserved` holds u8 id, `Screen.links` maps id → URI),
  OSC 52 clipboard set, DSR (`CSI 6 n`), CSI 14t/18t/19t size
  reports, DECSET 1004 focus reporting.
- **M6** — `AdwTabView` tabs with sticky titles, `GtkPopoverMenu`
  right-click menu (Copy/Paste/Split/Tab/Close), tab rename via
  popover with entry, keyboard shortcuts.
- **M7** — splits via `GtkPaned`, nestable. `Ctrl+Shift+D` /
  `Ctrl+Shift+R` for horizontal/vertical. `close_pane` collapses
  the parent paned (or closes the tab if last pane).
- **M8** — JSON layout save (v2 schema) on shutdown to
  `$XDG_STATE_HOME/sketerm/last.json`. Each tab carries a
  recursive Tree (pane | split). `--restore` and
  `--layout <path>` rebuild the full split topology including
  the GtkPaned hierarchy.
- **M9** — Sixel decoder (RGB color regs, RLE, raster attrs, HLS
  fallback). Kitty graphics APC parser (transmit/place/delete,
  RGBA). iTerm2 OSC 1337 with full PNG decode via vendored
  `stb_image.h`. `ImageStore` + `ImagePass` upload RGBA pixels
  to GL textures and draw them as quads after the grid pass —
  **end-to-end image rendering through the GL pipeline.**

### What's still missing (post-checkpoint)
  surface (tooltip on hover, click-to-open via `xdg-open`) not yet.
- **OSC 8 in selection** — link IDs stored, hover tooltip works,
  Ctrl+click opens; selection-extract preserves text but not the
  underlying URI.
- **Selection in scrollback** — model accepts negative rows but
  the mouse-drag handler hasn't been taught to map screen →
  scrollback coords.
- **IME preedit positioning** — commit signal works; preedit
  display at the cursor position not wired.
- **Font fallback** — single face; missing glyphs render as tofu.
- **Pane focus highlight** — focused pane is not visually
  distinguished beyond what GTK4 provides on the underlying GLArea.

### Tests
46/46 passing across:
- VT parser state machine (CSI/OSC/DCS/APC + ESC final)
- UTF-8 reassembly
- Cell / StylePool / Screen apply paths
- Selection rect normalization
- SPSC ring
- Sixel decode (color def, RLE, raster attrs, all-on/partial)
- iTerm2 PNG dimension extraction
- Kitty command parsing
- Layout JSON round-trip

Headless smoke: `zig build spike-shell` runs bash through the full
PTY → parser → screen pipeline and dumps the grid. Confirmed
sixel + Kitty image events fire end-to-end (`got image 1: 6x6 …`,
`got image 2: 2x2 …`).

GL spike: `zig build spike-gl` opens a `GtkGLArea`, queries driver
info, draws a clear, and reports realize / render flags.

## Build & run

```bash
zig build              # Release-safe binary at zig-out/bin/sketerm
zig-out/bin/sketerm    # opens a tab in the default $SHELL
zig-out/bin/sketerm --restore   # rebuilds last.json layout
zig-out/bin/sketerm --help
```

## Keybindings (built-in)

| Shortcut          | Action                |
|-------------------|-----------------------|
| `Ctrl+Shift+T`    | New tab               |
| `Ctrl+Shift+W`    | Close tab / pane      |
| `Ctrl+Tab`        | Next tab              |
| `Ctrl+Shift+Tab`  | Previous tab          |
| `Ctrl+Shift+D`    | Split horizontal      |
| `Ctrl+Shift+R`    | Split vertical        |
| `Ctrl+Shift+C`    | Copy selection        |
| `Ctrl+Shift+V`    | Paste                 |
| Right-click       | Context menu          |
| Mouse wheel       | Scrollback (10k lines)|

## Documentation

**Start here**
- [Plan](docs/plan.md) — goals, non-goals, v1 hard requirements,
  success criteria
- [Architecture](docs/architecture.md) — module layout, data flow,
  design decisions
- [Milestones](docs/milestones.md) — phased execution plan

**Deep-dives**
- [GPU / GL](docs/gpu.md) — `GtkGLArea` lifecycle, context share
  groups, fractional scaling, driver notes
- [Images](docs/images.md) — unified placement model for Sixel,
  Kitty, iTerm2
- [Layout persistence](docs/layout.md) — save/restore design,
  trust model
- [Lifecycle](docs/lifecycle.md) — PTY spawn, workers, signals,
  teardown
- [Config](docs/config.md) — config file schema, keybinding model
- [Testing](docs/testing.md) — parser fixtures, record/replay,
  differential diffing, fuzzing, benchmarks

**Reference**
- [Protocols](docs/protocols.md) — escape sequences supported
- [References](docs/references.md) — specs and study targets
- [Risks](docs/risks.md) — risks and mitigations

## Shell integration

**zsh and fish are integrated automatically** — sketerm injects the
script at spawn (disable with `shell_integration = off` in the
config). bash users source `data/shell-integration/sketerm.bash`
from their `.bashrc`. The integration enables:

- **OSC 7 cwd reporting** so layout save remembers each pane's
  directory, and `Ctrl+Shift+T` / `Ctrl+Shift+D` inherit it.
- **OSC 133 prompt marks** so `Ctrl+Shift+Up/Down` jumps between
  prompts in scrollback.
- **`sketerm_copy`** helper — pipe text through it to set the
  local clipboard via OSC 52, even over SSH.

Each script self-skips when `$TERM_PROGRAM` is not `sketerm`, so
sourcing unconditionally is safe.

## License

GPL-3.0-or-later (see `LICENSE`). Selling copies is permitted —
what the GPL forbids is closed-source redistribution: anyone who
distributes sketerm (modified or not) must provide the source under
the same terms.

Shader presets under `data/shaders/` carry per-file licenses (MIT,
public domain, GPL — see `data/shaders/README`); all are compatible
with the GPL-3 core.
