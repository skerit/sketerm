# References

Per component: the spec(s) to follow, reference implementation(s)
to study, what to extract. We **never vendor or copy code.** We
read, understand, reimplement in our own Zig.

License check: every referenced project is under a permissive
license (MIT, BSD, Apache-2.0). Reimplementation of documented
algorithms is not derivative work.

## Primary reference: Ghostty

Ghostty (https://github.com/ghostty-org/ghostty) is our single
most directly applicable reference. Reasons:

- Same language (Zig)
- Same UI toolkit on Linux (GTK4)
- Full image protocol support (Sixel, Kitty, iTerm2)
- Active, high code quality, MIT

Ghostty is **not** our product. We read Ghostty's code for
algorithms and integration patterns, then reimplement in sketerm's
own types and error handling.

**Caveat on paths**: Ghostty's internal structure evolves. This
document lists the areas to study by responsibility, not fragile
file paths. When reading, browse the current repo organization:

- Terminal emulation core lives under `src/terminal/` (Parser,
  Screen, PageList, kitty/, etc.)
- Rendering lives under `src/renderer/` with per-backend
  subdirectories (`opengl/`, `metal/`, `webgl/`)
- GTK integration lives under `src/apprt/gtk/` and has recently
  shifted to **Blueprint (`.blp`) files** in `src/apprt/gtk/ui/<gtk-version>/`
  plus `Surface.zig`, `App.zig`, and subdirectories like
  `class/`, `ext/`, `winproto/`. The older Window.zig / Tab.zig /
  Split.zig / Menu.zig organization the casual reader might expect
  is no longer the layout — read the current `src/apprt/gtk/`
  contents to find what you need.
- PTY handling is in `src/pty.zig` or near-path equivalents
- Input encoding is in `src/input/`

## VT parser (state machine)

**Spec**
- **Paul Williams VT500 state machine**:
  https://vt100.net/emu/dec_ansi_parser — the authoritative diagram.
- **xterm ctlseqs**:
  https://invisible-island.net/xterm/ctlseqs/ctlseqs.html —
  reference for every CSI/OSC/DCS/APC sequence we'll dispatch.
- **ECMA-48** — ISO standard; occasionally clarifies ambiguity.

**Reference implementations**
- **Ghostty's VT parser** (`src/terminal/Parser.zig`) — Zig,
  closest mirror of Williams. Best first read.
- **`alacritty/vte` crate** (~1544 lines in `src/lib.rs`) —
  clean, test-covered Williams implementation. Half the file is
  the table + tests; the state machine itself is compact.
  https://github.com/alacritty/vte
- **`wezterm-escape-parser`** — more feature-rich, less canonical.

**What to extract**: state machine shape, transition tables, how
to thread parameter accumulation through CsiEntry/CsiParam. Don't
copy the event type — define our own.

## Grid / screen / scrollback

**Reference implementations**
- **Ghostty** `src/terminal/Screen.zig`, `PageList.zig` —
  sophisticated page-list scrollback. Over-engineered for v1 but
  the right reference for post-v1 upgrade when memory pressure
  arrives.
- **`alacritty_terminal/src/grid/`** — simple flat grid + ring
  scrollback; closer to v1 ambition.
- **`wezterm-term/src/terminalstate/`** — most feature-rich; read
  for edge-case inspiration (alt screen, SRM, LNM, DECSTBM/DECOM
  interaction).

**What to extract**: Cell struct *shape* (ours is 8-byte packed,
see `architecture.md` D3), scrollback ring behavior, resize/reflow
policy (Alacritty reflows; we follow that). Start flat; upgrade
to page-list if profiling demands.

## Sixel

**Spec**
- **DEC STD 070** "Video Systems Reference Manual," Sixel chapter.
- https://vt100.net/docs/vt3xx-gp/chapter14.html — DEC's
  chapter-14 subset online.
- https://www.arewesixelyet.com/ — status tracker, good overview.

**Reference implementations**
- **foot's `sixel.c`** — small, focused Wayland-terminal decoder.
  Cleaner read than libsixel. Primary recommendation.
  https://codeberg.org/dnkl/foot
- **libsixel** — reference C decoder by saitoha. Read
  **`src/fromsixel.c`** (the decode side). `src/decoder.c` is the
  CLI driver, not what you want.
  https://github.com/saitoha/libsixel
- **Ghostty's sixel support** — lives inside the parser and image
  handling paths of `src/terminal/`. Browse the current layout.
- **WezTerm's sixel decoder** — clean Rust.

**Look at real emitters too**
- **chafa** (https://hpjansson.org/chafa/) — read its sixel
  encoder to see exactly what sketerm will receive.
- **img2sixel** — libsixel's CLI; useful corpus generator.

**What to extract**: raster-attribute / color-register command
parsing, 6-pixel row packing, palette handling (private vs
shared). Support the subset chafa and yazi actually emit first;
treat DEC-specific corners as best-effort.

## Kitty graphics protocol

**Spec**
- https://sw.kovidgoyal.net/kitty/graphics-protocol/ —
  authoritative, single-page, complete.

**Reference implementations**
- **Kitty itself** — `kitty/graphics/` (C + Python). Read
  `graphics.c` for command parsing and packing.
  https://github.com/kovidgoyal/kitty
- **Ghostty's Kitty handling** — `src/terminal/kitty/` has
  multiple files (`graphics_command.zig`, `graphics_image.zig`,
  graphics storage). Best Zig reference.
- **WezTerm's Kitty image code** — clean Rust.

**What to extract**: command key/value parsing (`a=T,f=32,s=…`),
chunked transmit (`m=1`), placement semantics, z-index, image/
placement ID tables, delete-command semantics (lower-case
keep-cache, upper-case free-cache).

## iTerm2 inline images

**Spec**
- https://iterm2.com/documentation-images.html — one page, complete.

**Reference implementations**
- **iTerm2 itself** — Objective-C, macOS. Skim for intent.
- **WezTerm** — cleanest non-ObjC reference (Rust).
- **Ghostty** — Zig implementation.

**What to extract**: key=value attribute parsing, base64 streaming
decode. v1 accepts PNG only (via vendored stb_image).

## Glyph rasterization + atlas

**Docs**
- FreeType tutorial: https://freetype.org/freetype2/docs/tutorial/
- HarfBuzz user manual: https://harfbuzz.github.io/

**Reference implementations**
- **Alacritty's renderer** (`alacritty/src/renderer/text/`) — the
  canonical GPU-atlas reference. Rust but structurally clear.
- **Ghostty's font + renderer** — `src/font/` for FreeType
  integration, `src/renderer/opengl/` for the GPU side.
- **foot's `grid.c`, `render.c`** — CPU rasterization via pixman;
  useful for understanding subpixel placement.

**What to extract**: atlas packing algorithm (shelf or skyline),
LRU page-level eviction, separate R8 (grayscale) and RGBA8 (color)
pages, glyph metric caching. v1 is monospace single-font — skip
their font-fallback logic.

## OpenGL grid renderer

**Reference implementations**
- **Alacritty's `alacritty/src/renderer/`** — instanced-quad
  technique, minimal shader footprint.
- **Ghostty's `src/renderer/opengl/` + siblings** — Zig + GL, same
  technique as Alacritty.
- **Kitty's `kitty/shaders/*.glsl`** — very optimized GLSL; good
  source for shader-technique inspiration.

**What to extract**: instanced rendering pattern (one quad mesh,
per-cell instance VBO), uniform layout for font metrics + colors,
single-pass grid fragment shader that handles background + glyph.

## GTK4 integration

**Reference implementations**
- **Ghostty `src/apprt/gtk/`** — our closest Zig + GTK4 reference.
  Current structure uses Blueprint `.blp` files for UI definition
  plus Zig files (`Surface.zig`, `App.zig`) plus subdirectories
  (`class/`, `ext/`, `winproto/`). Don't assume older file names.
- **Fractal** — Rust + GTK4 Matrix client. Excellent idiomatic
  GObject subclassing. Our Zig manual FFI maps one-to-one to
  what Fractal does via `glib::subclass::ObjectSubclass`.
  https://gitlab.gnome.org/GNOME/fractal
- **Black Box** — Vala + GTK4 + VTE. Not our path (VTE) but good
  UX reference for tabs and splits.

**What to extract**: how Ghostty subclasses `GtkGLArea` / `GtkBox`
(Zig `g_type_register_static_simple` dance), signal connection
idioms, main-thread / worker-thread separation patterns. From
Fractal: idiomatic GObject subclassing that translates directly
to Zig's manual-FFI approach.

## PTY handling

**Reference implementations**
- **Ghostty `src/pty.zig`** — direct Zig reference.
- **`alacritty_terminal/src/tty/unix.rs`** — Rust, documented.
- `man openpty(3)`, `man pty(7)`, `man tty_ioctl(4)`.

**What to extract**: `openpty` vs `posix_openpt` (we use the
former; simpler), TIOCSWINSZ on resize, TIOCSCTTY in child,
SIGCHLD handling, avoiding orphan children on crash.

## Input encoding

**Spec**
- xterm ctlseqs "PC-Style Function Keys" section.

**Reference implementations**
- **Alacritty's `alacritty/src/input.rs`** — clean mapping tables.
- **Ghostty's `src/input/` KeyEncoder** — Zig reference.
- **`libtermkey`** (LeoNerd) — authoritative for edge cases.

**What to extract**: modifier-encoding tables (e.g. `CSI 1;5A`),
application-cursor-mode (DECCKM) switching, numpad encoding,
`modifyOtherKeys=1` mapping. Defer compose-key handling to GTK's
`IMContext`.

## Clipboard bridge

No project-level reference needed. GTK4's `GdkClipboard` API is
well-documented.

Pattern:
- OSC 52 set: `gdk_clipboard_set_text`.
- OSC 52 query: `gdk_clipboard_read_text_async` → format OSC 52
  response back onto PTY.
- Paste: same async read → forward bytes to PTY; wrap with
  bracketed-paste markers if mode enabled.

## Layout persistence

**Inspiration (not reimplementation targets)**
- Zellij KDL layouts: `~/.config/zellij/layouts/*.kdl` — clean
  layout DSL.
- Kitty session files — closest precedent for a terminal (vs.
  multiplexer) doing this.
- Tmuxinator YAML — rougher but informative about what fields
  users want.
- Tilix session JSON — GSettings-backed; instructive on
  scope-creep pitfalls.

**What to extract**: what fields *must* round-trip (tree shape,
cwd, command, ratios, titles), what *should not* (env, running
state), how to version the schema. See `docs/layout.md` for our
decisions.

## Unicode width

**Spec**
- Unicode East Asian Width: https://www.unicode.org/reports/tr11/
- Grapheme Cluster Boundaries: https://www.unicode.org/reports/tr29/

**Reference implementations**
- **wcwidth.c** by Markus Kuhn:
  https://www.cl.cam.ac.uk/~mgk25/ucs/wcwidth.c
- Alacritty's generated width tables.
- Ghostty's generated width tables.

**What to extract**: ship as auto-generated `grid/width.zig` from
the Unicode database (`DerivedEastAsianWidth.txt`). The table, not
the code.

## Testing

**Tools**
- **vttest** (Arch: `pacman -S vttest`) — canonical integration test.
- **vt100-test** — additional corpus.
- **Custom record/replay** — capture byte streams from real
  bash / zsh / vim / nvim / htop / less / yazi / lazygit sessions,
  feed to parser+grid, snapshot the grid, diff on regression.

## What we deliberately don't take from

- **WezTerm's Lua config** — too baroque for our plugin ambitions.
  v1 uses ZON; post-v1 plugin host will be simpler.
- **Alacritty's image-rejection philosophy** — disagreement.
- **VTE's event-based clipboard API** — we own the event pump.
- **Kitty's Python config surface** — we use ZON; no Python at
  runtime.
- **GNOME-terminal's Profiles UI** — one default profile in v1.
