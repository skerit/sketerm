# Milestones

Each milestone lists scope, entry criteria, exit demo, estimate,
and the reference material to read before starting it. "Study X"
means *read, understand, reimplement cleanly* — never copy-paste.

Estimates reflect the second-pass review: initial estimates were
optimistic; these include a 30% contingency for first-time-in-GTK4
tax.

---

## M0 — Toolchain setup (0.5 d)

**Scope**
- Pin Zig version in `build.zig.zon`. **Target: Zig 0.14.x**
  (most recent stable as of project start; `std.atomic.Value`
  and `std.posix` surfaces we rely on are stable there).
  Record exact version (e.g. `0.14.1`) in the minimum-zig field
  plus a comment.
- `build.zig` with `pkg-config` linkage for gtk4, libadwaita,
  freetype2, harfbuzz, epoxy, lua.
- `src/c.zig` aggregating `@cImport` of all C headers.
- `src/main.zig` — bare `AdwApplication` that opens an empty window
  and exits cleanly on close.
- `sketerm-256color` terminfo source in `terminfo/sketerm-256color.src`
  (compiled via `tic` in build step).
- `.desktop` file + app icon in `data/` — registers with KDE
  (`AdwApplication` app-id `dev.sker.sketerm`).

**Entry**: packages installed.

**Exit demo**: `zig build run` opens an empty GTK4 window on Plasma 6
Wayland; closes cleanly; no GTK warnings in stderr; no leaks
reported by GPA debug.

**Read first**: GTK4 "Getting Started" for C. Ghostty's `build.zig`
(linkage patterns, though current structure may differ). Paul
Williams' VT parser spec overview.

**Note**: `@cImport` aggregation of all six C libraries is
compile-time heavy (3-10 s rebuild). Split into focused sub-modules
if rebuild cost becomes painful.

---

## M0.5 — GL triangle spike (1 d)

**Scope**
- Standalone throwaway: 100-line Zig program that creates a
  `GtkGLArea`, connects `create-context`/`realize`/`render`.
- Compile a trivial shader, upload a triangle VBO, draw a colored
  triangle on `render`.
- Verify context share group: create a window-level root
  `GdkGLContext`; make a second `GtkGLArea` share with it; confirm
  a texture uploaded on root is sampleable from the second.
- Test on the author's hardware + at least one other GPU vendor
  if accessible.

**Entry**: M0 done.

**Exit demo**: a triangle renders; texture-share test passes.
`gtk_gl_area_set_use_es(TRUE)` call verified — confirm via
`epoxy_gl_version()` that ES 3.0+ is actually active; desktop GL
accidentally active would be caught here, not in M3.

**Rationale**: the realize/create-context/share-group dance is
where first-time GTK4 GL developers lose a week. Doing it here with
zero stakes exposes the pipeline shape before any parser or grid
work sinks time into assumptions that don't survive `realize`.

**Read first**: `docs/gpu.md` in full. GTK4 docs for
`GtkGLArea::create-context`, `::realize`,
`gtk_gl_area_set_use_es`, `gdk_surface_create_gl_context`,
`gdk_gl_context_create_shared`.

---

## M1 — PTY + parser skeleton (3 d)

**Scope**
- `pty.zig`: fork + `openpty(3)` + `execvp` into `$SHELL` with the
  child-setup sequence from `docs/lifecycle.md` (setsid, TIOCSCTTY,
  dup2, signal reset, env construction).
- Worker thread with `poll()` on master fd + shutdown `eventfd`.
- SPSC ring (`util/ring.zig`), 64 KB.
- `parser/vt.zig`: skeleton state machine (Ground, Escape, CsiEntry,
  CsiParam, OscString states). Emits `Print(u32)`, `Execute(u8)`,
  `CsiDispatch{params, intermediates, final}`, `OscDispatch(string)`.
- Main thread drains ring via `g_main_context_invoke`; prints
  decoded events to stdout for verification.

**Entry**: M0.5 done.

**Exit demo**: launch sketerm; in parent stdout, see live decode of
what bash is sending — escape sequences identified, text printed.

**Read first**: Paul Williams' VT parser spec (vt100.net).
Ghostty's `src/terminal/Parser.zig` for Zig state-machine
idioms. `alacritty/vte` crate's `src/lib.rs` as a concise
reference. `man openpty`.

---

## M2 — Grid model + CSI handling (5-7 d)

**Scope**
- `grid/cell.zig`, `line.zig`, `screen.zig` per `architecture.md` D3.
- `style_pool.zig` + `rune_pool.zig` + `link_table.zig`.
- Active + alternate screen buffers. Scrollback ring (10 000 lines).
- Apply events: `Print`, `LF`, `CR`, `BS`, `TAB`; cursor movement
  (CUU/CUD/CUF/CUB/CUP/CHA/VPA/CNL/CPL/SCOSC/SCORC); erase
  (ED/EL/ECH); scroll (SU/SD/IL/DL/ICH/DCH); insert/replace modes
  (IRM/SM/RM); scroll region (DECSTBM); origin mode (DECOM);
  autowrap (DECAWM); alternate screen (DECSET 1049); SGR.
- Debug dump: print grid to stdout after each event batch.
- **Critical**: correct DECSTBM × DECOM × 1049 interactions.

**Entry**: M1 done.

**Exit demo**: `vim` launched in child shell; vim's UI visible as
grid dumps to stdout; quitting vim restores main screen; scroll
region correctly constrains scrolling inside less.

**Read first**: xterm ctlseqs (invisible-island.net/xterm/ctlseqs).
Alacritty's `alacritty_terminal/src/term/mod.rs`. Ghostty's
`src/terminal/Screen.zig`. ECMA-48 for mode semantics ambiguities.

---

## M3 — Text rendering (10 d)

**Scope**
- `render/atlas.zig`: FreeType load → glyph bitmap → pack into R8
  GL texture page (shelf packing). Grow to new page on fill.
- `render/gl.zig`: shader compilation, VAO/VBO setup, uniform block
  for font metrics.
- `render/grid_pass.zig`: instanced quads (one per visible cell);
  vertex shader computes quad position; fragment shader samples
  atlas and mixes fg/bg.
- `ui/pane.zig`: `GtkGLArea` subclass. Wire `create-context` for
  share group, `realize` for resource init, `render` for draw,
  `resize` for viewport + cell-metric recompute.
- Fractional scaling: query `gdk_surface_get_scale` (f64);
  rasterize at physical DPI; atlas at physical size; cell grid in
  logical.
- Monospace font only. Latin-1 glyphs cached eagerly; others lazy.
- No HarfBuzz, no ligatures, no emoji, no fallback. UTF-8 decode
  of a codepoint → look up glyph index → rasterize if absent.

**Entry**: M2 done.

**Exit demo**: vim inside the sketerm window renders visibly and
legibly. Grid redraws promptly on shell output.

**Read first**: `docs/gpu.md` (whole document — especially
share-group and fractional-scale sections). Alacritty's
`alacritty/src/renderer/` + `alacritty/src/renderer/text/`.
Ghostty's `src/renderer/opengl/` and `src/font/`. FreeType
tutorial. LearnOpenGL atlas chapter.

---

## M4 — Input, selection, clipboard, terminfo (6-8 d)

**Scope**
- `ui/input.zig`: `GdkKeyEvent` → xterm byte encoding. Table-driven.
  Modifiers, arrow keys, function keys, printable runes.
  `modifyOtherKeys=1` supported (emacs requirement).
- `ui/ime.zig`: wire `GtkIMMulticontext`; preedit rendered at cursor
  in the grid.
- `grid/selection.zig`: click-drag selection; double-click word
  (Unicode word boundaries); triple-click line; rectangular-select
  modifier.
- `ui/clipboard.zig`: `GdkClipboard` read/write via GIO async.
  Ctrl+Shift+C / Ctrl+Shift+V keybindings wired.
- Colors: full SGR — 16 palette, 256 palette, truecolor (38/48;2;…).
- DECSCUSR (cursor shape): block/underline/bar × steady/blinking.
- Install `sketerm-256color.src` → `tic` → packaged terminfo;
  build-step writes to `$out/share/terminfo`. On first run,
  probe and copy to `$XDG_DATA_HOME/terminfo` if not present.

**Entry**: M3 done.

**Exit demo**: fully usable single-pane terminal. Type, edit files,
copy from scrollback, paste. `echo $TERM` shows `sketerm-256color`.
CJK input via fcitx5 works. Cursor shape changes as neovim requests.

**Read first**: xterm ctlseqs input-encoding section. Ghostty's
`src/input/` for Zig mapping patterns. Alacritty's
`alacritty/src/input.rs` for table structure. GTK4 clipboard docs.
`terminfo(5)`, `tic(1)`.

### ► Checkpoint: working single-pane, single-tab terminal usable
### as author's SSH client.

---

## M5 — OSC 52 / OSC 8 / OSC 7 / focus / window-reports (2-3 d)

**Scope**
- OSC 52 set-selection → `GdkClipboard` write; 1 MB payload cap;
  streaming base64 decode.
- OSC 52 query → default-deny; per-session allow via `GtkPopover`
  confirm prompt.
- OSC 8 hyperlinks → cells carry `link_id` via `link_table` side
  table; hover tooltip shows URL; Ctrl-click → `g_app_info_launch_default_for_uri`.
- OSC 7 cwd reporting → parse `file://host/path` → store on
  `Terminal.cwd`; used by layout save.
- DECSET 1004 focus reporting → on focus-in/out signal, write
  `CSI I` / `CSI O`.
- CSI 14t / 18t window-size queries → respond with grid dims
  (cells for 18t, pixels for 14t). Never implement set-size.

**Entry**: M4 done.

**Exit demo**: SSH to remote; `printf '\e]52;c;$(base64 <<< hi)\a'`
lands "hi" in local clipboard. `printf '\e]8;;https://…\e\\foo\e]8;;\e\\'`
renders as hoverable link. vim's focus-lost autocmd fires when
switching windows.

**Read first**: xterm OSC spec sections. Alacritty's OSC 52 for
sanity check. `docs/layout.md` cwd-handling section.

---

## M6 — Tabs + context menu (4-5 d)

**Scope**
- `ui/tab.zig` + `AdwTabView` + `AdwTabBar`.
- Tab titles: `AdwTabPage.title` set explicitly, never follows
  pane title. Rename via GtkPopover + GtkEntry, triggered from
  menu action.
- Pane shell-title surface: displayed as a small strip above the
  GtkGLArea within each pane (design fully in M6).
- `ui/menu.zig`: build `GMenu` with actions — *Copy*, *Paste*,
  *New Tab*, *Rename Tab…*, *Close Tab*, *Split Horizontal*,
  *Split Vertical* (stub until M7), *Close Pane* (stub).
- Right-click on pane pops `GtkPopoverMenu` at cursor.
- Keyboard accelerators via `GtkApplication::set_accels_for_action`.

**Entry**: M5 done.

**Exit demo**: multi-tab usage with right-click menu; tab titles
stay as user sets them regardless of shell activity; per-pane shell
title visible.

**Read first**: libadwaita `AdwTabView` docs. GTK4 `GMenu` +
`GAction` tutorial. For widget-subclass-from-Zig patterns see
Ghostty's current `src/apprt/gtk/` (note: structure has shifted
to Blueprint + Surface.zig + App.zig + class/+ext/+winproto/ —
read the current state, don't assume older layout). Fractal
source for general GObject-subclass idioms.

---

## M7 — Splits (5-7 d)

**Scope**
- `ui/pane_tree.zig`: recursive tree `Tree = Leaf(Pane) |
  Split(orientation, ratio, first, second)`.
- GTK view: `GtkPaned` nested per tree shape.
- Split action: replace focused leaf with `Split` node, spawn a
  new pane in the second half.
- Close pane: remove leaf; if sibling now alone, collapse parent
  split so sibling replaces the split in the tree.
- Focus: click-to-focus; `Ctrl+Tab` / `Ctrl+Shift+Tab` cycle.
- Context menu operates on pane under cursor; keyboard shortcuts
  operate on focused pane.
- Per-pane GL context created with share-group to window root.

**Entry**: M6 done.

**Exit demo**: arbitrary nested splits; right-click → Split H →
new pane spawns; drag paned handle to resize; close collapses
cleanly without visual artifacts.

**Read first**: GTK4 `GtkPaned` docs. Tmux's pane-tree data model
for inspiration. Ghostty's split handling (read its current source
as Blueprint-based UI).

### ► Checkpoint: feature-complete except images and layout persistence.

---

## M8 — Layout persistence (2-3 d)

**Scope**
- `layout.zig`: serialize tab tree + per-pane cwd + initial
  command to ZON per `docs/layout.md` schema.
- `--layout <file>` CLI arg loads on startup.
- `--restore` loads `$XDG_STATE_HOME/sketerm/last.zon`.
- Menu actions: *Save Layout…*, *Open Layout…*.
- Auto-save `last.zon` on clean exit (atomic tmp + rename + fsync).
- Degraded load: binary-not-found, cwd-missing — per spec in
  `docs/layout.md`.
- Schema version field, version-mismatch diagnostic.

**Entry**: M7 done.

**Exit demo**: complex layout saved; sketerm relaunched with
`--layout`; tree reconstructed; each pane runs its command in its
cwd. Deliberately delete one binary, reload — pane still opens
with the diagnostic overlay.

**Read first**: `docs/layout.md`. Zellij KDL layouts for inspiration.
Tilix session JSON for field scope.

---

## M9a — Kitty graphics (7-10 d)

**Scope**
- `parser/apc.zig`: APC frame extraction.
- `parser/kitty_image.zig`: key=value parameter parser; commands
  `t` (transmit), `T` (transmit+place), `p` (put), `d` (delete).
- Chunked transmit (`m=1` continuation) reassembly.
- Image/placement ID tables; z-ordering.
- Format support: `f=32` RGBA, `f=24` RGB, `f=100` PNG. Media:
  `t=d` direct only (`t=t` / `t=s` deferred, see `docs/images.md`).
- `grid/image_store.zig`: full implementation per `docs/images.md`.
- `render/image_pass.zig`: textured quads; sort (z, texture_id);
  draw visible.
- Kitty's persistent-cache semantics: images live without
  placements until explicit delete.

**Entry**: M8 done.

**Exit demo**: `kitten icat sample.png` displays; `timg file.gif`
shows first frame; placement + delete by id work; images survive
pane resize and scroll.

**Rationale for before sixel**: Kitty is modern, well-specified,
less DEC-era cruft. Its image-store plumbing generalizes to sixel;
reverse is harder.

**Read first**: `docs/images.md`. Kitty graphics protocol spec
(sw.kovidgoyal.net/kitty/graphics-protocol/). Kitty's
`kitty/graphics/` source. Ghostty's `src/terminal/kitty/`
directory.

---

## M9b — Sixel (7-10 d)

**Scope**
- `parser/dcs.zig`: DCS frame extraction (`ESC P … ST`).
- `parser/sixel.zig`: decode DCS `q` — private params, raster
  attributes `" Pan;Pad;Ph;Pv`, color-register commands
  `#n;2;r;g;b` (RGB) or `#n;1;h;l;s` (HLS), sixel data rows.
  Output: RGBA buffer.
- Integrate with `image_store` as a new placement on the active
  screen at cursor row/col.
- Handle the subset `chafa` and `yazi` emit. Private palettes,
  shared palettes, background-fill semantics.
- Reflow/scroll integration per `docs/images.md`.

**Entry**: M9a done.

**Exit demo**: `chafa --format=sixel sample.png` displays;
`yazi` preview renders sixel thumbnails; scrolling past makes
them disappear; resizing preserves them.

**Read first**: libsixel — read **`src/fromsixel.c`** (decoder;
`src/decoder.c` is the CLI driver). DEC STD 070 chapter 14.
foot's `sixel.c` — small, focused, cleaner than libsixel's sprawl.
chafa source to see what emitted sixel looks like.

---

## M9c — iTerm2 inline images (3-4 d)

**Scope**
- `parser/iterm_image.zig`: parse
  `OSC 1337 File=name=…;size=…;inline=1;…:<base64>ST`. Support
  attributes: `name`, `size`, `inline`, `width`, `height`,
  `preserveAspectRatio`.
- Streaming base64 decode (payloads can span multiple OSC writes
  if the sender doesn't buffer; our parser buffers until terminator).
- PNG decode via vendored `stb_image.h` (~8 kLOC header-only with
  implementation, dual MIT / public domain). Other formats rejected
  with diagnostic (deferred).
- Integrate with `image_store` as sixel-style placement.
- 32 MB max payload.

**Entry**: M9b done.

**Exit demo**: `imgcat sample.png` (iterm2 utility) displays
correctly; streaming a large PNG via SSH works.

**Read first**: iTerm2 docs (iterm2.com/documentation-images.html).
WezTerm's iTerm2 image handling (Rust).
`stb_image.h` header docs.

### ► Checkpoint: v1 feature-complete.

---

## M10 — Fit & finish (ongoing)

Post-M9 polish, prioritized by what bites first in real use:

- Font fallback chain (Noto Sans Mono → Noto Color Emoji → DejaVu);
  atlas integration.
- HarfBuzz shaping → ligatures + emoji ZWJ.
- Config file hot-reload.
- Performance: coalesce redraws, throttle background pane
  rendering, benchmark sustained throughput (`cat /dev/urandom |
  head -c 100M`) targeting 20+ MB/s.
- `vttest` suite green within expected-fail list.
- FriBidi integration.
- Kitty progressive-enhancement keyboard protocol (CSI u).
- Settings UI.
- Plugin host (Lua via `liblua`).
- Minimal SIGSEGV handler that writes crash layout.

No tight schedule on M10 — ship v1, polish continuously.

---

## Total estimate

Summed ranges (upper bounds) by phase:

| Phase       | Days            | Weeks (full-time) |
| ----------- | --------------- | ----------------- |
| M0–M0.5     | ~1.5 d          | 0.3               |
| M1          | 3 d             | 0.6               |
| M2          | 5-7 d           | 1.0-1.4           |
| M3          | 10 d            | 2.0               |
| M4          | 6-8 d           | 1.2-1.6           |
| M5          | 2-3 d           | 0.4-0.6           |
| M6          | 4-5 d           | 0.8-1.0           |
| M7          | 5-7 d           | 1.0-1.4           |
| M8          | 2-3 d           | 0.4-0.6           |
| M9a         | 7-10 d          | 1.4-2.0           |
| M9b         | 7-10 d          | 1.4-2.0           |
| M9c         | 3-4 d           | 0.6-0.8           |
| **v1 total (baseline)** | **56-71.5 d** | **~12-14 wk** |
| **+ 30 % contingency**  |               | **~16-20 wk** |
| M10         | ongoing         | —                 |

Part-time (10-15 h/wk): **9-12 months** for v1 including
contingency. First-time-in-GTK4 tax and Zig stdlib churn are the
largest sources of variance.

---

## Per-milestone companion docs

- M0.5, M3, M7, M9 → `docs/gpu.md`
- M1, M4, M7, M8 → `docs/lifecycle.md`
- M8 → `docs/layout.md`
- M9a, M9b, M9c → `docs/images.md`
