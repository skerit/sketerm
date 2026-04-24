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
- M0 — `zig build` (Zig 0.15.2; ReleaseSafe default to dodge gcc 15's
  `.sframe` linker incompatibility); GTK4/libadwaita window opens.
- M0.5 — GL spike confirms `GtkGLArea` + `set_use_es(TRUE)` + share
  groups (PASS via Mesa llvmpipe; NVIDIA EGL fails on this hardware).
- M1 — PTY spawn/poll/read in worker thread; SPSC ring with
  `drain_pending` coalescing; main-thread drain via
  `g_main_context_invoke`.
- M2 — Cell (`extern struct`, 8 B), `StylePool`, `Screen` with active
  + alternate buffers and 10k scrollback. Apply for Print, CR/LF/BS/
  TAB, cursor moves, erase, scroll, modes (1049/7/6/2004/1004), full
  SGR with truecolor.
- M3 — FreeType atlas (R8 page, shelf-pack), GL ES 3.0 grid
  shader (instanced quads), GtkGLArea pane.
- M4 — Keyboard (xterm encoding, modifyOtherKeys=1), paste with
  bracketed-paste mode awareness, resize → TIOCSWINSZ.
- M5 — OSC 0/2 title, OSC 7 cwd, OSC 52 clipboard set, OSC 8
  hyperlinks (parsed; no UI yet), DSR (`CSI 6 n`), CSI 14t/18t
  size reports, DECSCUSR cursor shapes.
- M6 — `AdwTabView` tabs, sticky titles, `GtkPopoverMenu` context
  menu, keyboard shortcuts (`Ctrl+Shift+T`/`W`/`Tab`).
- M7 — splits via `GtkPaned`, nestable; `Ctrl+Shift+D`/`R`;
  `close_pane` collapses the parent.
- M8 — JSON layout save on shutdown to `$XDG_STATE_HOME/sketerm/last.json`;
  `--restore` and `--layout <path>` flags rebuild tabs.
- M9 — Sixel decoder (full minimal subset). Kitty graphics APC
  parser (transmit/place/delete commands). iTerm2 OSC 1337 PNG
  dimension extraction. Image events fire to a `Sink.on_image`
  callback. **Rendering integration deferred** — events arrive but
  the image_pass + GL upload is post-checkpoint work.

### What doesn't yet
- **Image rendering** — sixel/Kitty/iTerm2 decode but pixels never
  reach a GtkGLArea quad. The infrastructure (image event sink) is
  in place; an `ImageStore` + image pass shader is the missing
  piece.
- **Tab rename UI** — actions wired but no popover entry.
- **OSC 8 hover/Ctrl-click** — link IDs not yet stored on cells.
- **Selection in scrollback** — selection model uses live screen
  coords; scrollback range coords are computed but unfocused.
- **IME preedit positioning** — `GtkIMMulticontext` not wired.
- **Font fallback** — single face; missing glyphs render as tofu.
- **Splits via tab restore** — layout save records tabs only,
  not the per-tab pane tree (M8 partial).

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
sixel + Kitty image events fire end-to-end.

GL spike: `zig build spike-gl` opens a `GtkGLArea` and reports
realize / render / driver info.

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

## License

TBD.
