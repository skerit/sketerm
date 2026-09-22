# Architecture

## Module tree

Directory-level, since the file list churns. Each entry says who may
depend on it — the dependency direction is the part that must not drift.

```
src/
├── main.zig                GUI entry: CLI args, argv0 identity dispatch
├── mux_main.zig            sketerm-mux entry (libc only)
├── c.zig                   @cImport bundle for the GUI target
├── config.zig              config.conf loader + ProfileSettings
├── pty.zig                 PTY spawn + read loop (daemon side)
├── terminal.zig            one mirror Screen + its Remote session connection
├── layout.zig              tab/pane tree ↔ JSON persistence
│
├── parser/                 VT state machine → Event; sixel, kitty and
│                           iTerm2 image protocols. GTK-free.
├── grid/                   Cell (8 bytes) + side tables, Screen,
│                           scrollback, reflow, selection. GTK-free.
├── editor/                 rope, transactions, syntax, search — the
│                           editor model. GTK-free.
├── lsp/                    LSP client (see src/lsp/CLAUDE.md). GTK-free.
├── filebrowser/            file-browser model, jobs, previews. GTK-free.
├── mux/                    daemon, wire protocol, transports, app
│                           forwarding (see src/mux/CLAUDE.md). GTK-free.
├── ipc/                    remote control, MCP server, appdrive
│                           (see src/ipc/CLAUDE.md).
├── web/                    CEF browser helper — the only CEF linkage
│                           (see src/web/CLAUDE.md). Its own binary.
├── render/                 atlas, GL wrapper, grid/cell/image/bg passes,
│                           shader passes, editor text layout.
├── ui/                     everything GTK: window, pane,
│                           terminal_surface, the faces (browser/, panel/,
│                           editor*, webface), prefs, menus, palette.
└── util/                   platform primitives, codecs, recording,
                            small helpers shared by everything.
build.zig
build.zig.zon               toolchain pin + the single version source
```

The hard rule in that list: **`ui/` and `render/` may depend on
everything, but nothing depends on them.** Anything the daemon imports
(`mux/`, `parser/`, `grid/`, `config.zig`) must stay free of GTK and
GLib, which `zig build mux-portable` checks against musl.

## Data flow

Steady-state path from child process byte to pixel. The PTY read and
the VT parse both happen in the DAEMON — the GUI process owns no pty
and runs no parser thread:

```
   child process (bash)
          │
          ▼  writes bytes to slave fd
   PTY (kernel)
          │
          ▼  poll() in the daemon's single-threaded loop
   ┌──────────────────┐    sketerm-mux (separate process)
   │   PTY read       │
   │   Parser (VT)    │
   │   emits Events   │
   └────────┬─────────┘
            │ EVENTS frames (parsed events, never re-encoded
            │ escape sequences); SNAPSHOT on attach/resync
            ▼
   ┌──────────────────┐    unix socket / ssh transport
   │   mux wire       │
   └────────┬─────────┘
            │ g_unix_fd_add, non-blocking, never read blocking
            ▼
   ┌──────────────────┐    GUI, main thread (GLib main loop)
   │  apply to Screen │
   │  update images   │
   │  queue_draw      │
   └────────┬─────────┘
            │ gtk_widget_queue_draw (coalesced by frame clock)
            ▼
   ┌──────────────────┐    main thread, next vsync
   │  render signal   │
   │   grid pass      │
   │   image pass     │
   └────────┬─────────┘
            ▼
         pixels
```

Back-pressure is natural: the socket buffer fills, the daemon's write
blocks, its PTY read stops, and the child blocks on write.
Self-regulating, no explicit flow control needed.

The in-process path this replaced — a worker thread per pane, a
lock-free SPSC ring, a `drain_pending` cross-thread wakeup and a
`mainDrain` callback — is GONE, and deliberately so. Do not
reintroduce it.

## Threading model

| Thread          | Owns                                                     |
| --------------- | -------------------------------------------------------- |
| GTK main        | Everything: GTK/GDK/GL objects, Screen, ImageStore, UI    |
| detached worker | Short-lived blocking IO ONLY, touching none of the above  |

Terminal rendering has no worker thread at all; the off-thread parsing
happens in another process. The one exception is short-lived **detached**
workers for blocking IO that touches no widget, render or Screen state:
panel transport setup, panel asset file reads, gdk-pixbuf decode (see
`src/ui/panelhost.zig`). They hand back through `g_idle_add`, and ONLY
the idle handback frees the job, so a cancelled worker can never race
its own teardown. A worker that needs GTK is a bug, not a pattern to
copy.

Never block the GLib main loop on a socket read. Every socket the GUI
watches — the daemon connection, the browser helper — is non-blocking
and watched with `g_unix_fd_add`.

See `docs/lifecycle.md` for start/stop/signal details, and `docs/gpu.md`
for the full GL-integration rationale.

## Deferred callbacks and liveness

The hazard that outlived the worker is a callback firing into freed
user data. `DrainHandle` is the fence for callbacks that are not
attached to a widget and so have no widget lifetime to borrow: idle
callbacks, timers, async sink replies (the OSC 52 clipboard read),
reconnect handbacks, retry timers. It is allocated per `Terminal` and
outlives it; `alive` lets a queued callback detect a teardown between
queue and dispatch, and `terminal` is the fenced back-pointer those
callbacks resolve through.

For widget-attached callbacks the mechanisms are different and must not
be mixed — `CLAUDE.md`'s memory-ownership section is the reference.

`gtk_widget_queue_draw` coalesces automatically within a frame, so
several applied event batches inside one frame still produce one
render. Frame-clock-driven animation uses a tick callback that is
installed only while something is animating and removes itself when
that ends.

## Allocator strategy

Zig's explicit allocation discipline, two domains:

1. **App allocator** — the process `GeneralPurposeAllocator`. All
   long-lived state (windows, tab trees, screens, scrollback, image
   textures). Main thread only in the GUI. A daemon session parses
   with its own general allocator too (`daemon_sessions.zig`); there
   is no per-drain arena. An `Event`'s variable-length payload (OSC,
   APC and DCS bodies) is a heap slice the event owns, freed by
   `Event.deinit` right after it is applied or put on the wire; CSI
   parameters are fixed-size and never allocate.
2. **Config arena** — `applyConfigChange` clones the config into a
   fresh arena and frees the old one, so anything holding
   config-arena slices must be re-pointed in that same loop.

No GC. Every allocation has a defined owner and a defined free
site. Leak detection via GPA's debug mode during development.

GTK signal contexts are the subtle case, because a callback can
outlive what it points at: `CLAUDE.md`'s memory-ownership section is
the reference, and its central rule is that the three mechanisms
(widget-owned destroy notify, disconnect at teardown, liveness fence)
are alternatives — never layers.

## GL context lifecycle

Summarized here; full detail in `docs/gpu.md`.

- Each pane's `GtkGLArea` has its own `GdkGLContext`.
- Shaders, VBOs, and the glyph atlas are allocated lazily when the
  GLArea fires `realize`.
- **Re-realize on reparent.** `gtk_widget_unparent` unrealizes the
  GLArea, which destroys its `GdkGLContext`. Splits / tab moves /
  layout shuffles all reparent and therefore cycle the context.
  `TerminalSurface`'s realize handler (`src/ui/terminal_surface.zig`)
  treats every realize as potentially a re-realize: the prior
  `Atlas` is `deinit`-ed, then `forgetGL()` zeros the cached handles
  on `GridPass` / `ImagePass` / `ImageStore` so the realize path
  actually rebuilds against the fresh context. Without this,
  `program != 0` early-returns leak dead-context shader IDs and
  `glUseProgram` silently renders nothing.
- Surface GL resources (per-pane VBOs) are released in `unrealize`.
- **Pane vs TerminalSurface.** `Pane` (src/ui/pane.zig) is the
  interactive workspace cell: input, menus, faces, Window sinks,
  split-tree participation. The rendering half — GtkGLArea +
  lifecycle, all render passes, ImageStore, visual timers — is
  `TerminalSurface` (src/ui/terminal_surface.zig), composed by value
  inside Pane and reusable without it (e.g. a cast-playback viewer).
  The surface carries the presentation-geometry policy
  (`Geometry.live_terminal` = allocation drives the grid;
  `Geometry.fixed_grid` = letterboxed fixed cols x rows, no
  geometry propagation).

## Key design decisions

### D1 — Events, not callbacks, from parser to grid
Decouples threading. Events are batchable, testable (record/replay
fixtures), and natural to drain atomically.

### D2 — One Parser per PTY
Parser state is per-stream, owned by the daemon session that owns
the PTY.

### D3 — Cell is 8 bytes; heavy data in side tables

Each `Cell` is:

```zig
pub const Cell = extern struct {
    rune: u32,                // Unicode codepoint (0 = blank)
    style_ref: u16,           // index into the StylePool (fg+bg+attrs)
    flags: u8,                // bits: wide left/continuation, has_link,
                              //       has_image, is_cluster, ...
    reserved: u8,             // OSC 8 link id while has_link is set
};
comptime {
    std.debug.assert(@sizeOf(Cell) == 8);
    std.debug.assert(@alignOf(Cell) == 4);
}
```

**`extern struct`, not `packed struct`.** In Zig a `packed struct`
has bitfield semantics (each field occupies exactly its bit width,
no padding). For a predictable 8-byte byte-level layout we want
C ABI — `extern struct`. The comptime assert locks the size.

**8 bytes flat.** At 200 cols × 10 000 scrollback = **16 MB** per
screen. Tight.

Side tables (all on `Screen`, per pane, main-thread-owned in the GUI):

- `pool` (`grid/style_pool.zig`) — interned `{fg, bg, underline
  colour, attrs}` entries; deduplicated.
- `links: AutoHashMap(u8, []u8)` — OSC 8 id to URI; the id rides in
  the cell's `reserved` byte.
- `clusters: AutoHashMap(u32, ArrayList(u32))` — the extending
  codepoints of a multi-codepoint grapheme, keyed by `(row << 16) |
  col`.
- `glyphs` — the Glyph Protocol glossary (`grid/glyph_glossary.zig`).
- Images are not in a cell side table: placements live in the pane's
  `ImageStore` (see `images.md`), plus `virtual_placements` for kitty
  Unicode-placeholder images.

Rationale:
- <1 % of cells carry images, OSC 8 links, or multi-codepoint
  clusters in normal use. Paying 8 B per cell for optional data
  was wasteful.
- Interning `{fg, bg, attrs}` exploits the fact that runs of
  consecutive cells almost always share style.
- Side-table design sets up post-v1 grapheme-cluster and ligature
  support cleanly — no cell-struct surgery needed.

### D4 — Dual atlas (R8 grayscale + RGBA8 color)
Most glyphs are grayscale → R8 saves VRAM. Color bitmap glyphs
(emoji) go into RGBA8. Eviction at page level, not glyph.

### D5 — OpenGL ES 3.0 via GtkGLArea (not GSK)
Direct shader control, for the TERMINAL surface. See `docs/gpu.md`.
Browser panes are the deliberate exception: their frames are
`GdkTexture`s composited by GSK, because a GL area resamples them
twice on fractional-scale outputs.

### D6 — Image model: placement-based, per-pane `ImageStore`
Full details in `docs/images.md`. Summary:

- `Image`: decoded RGBA + GL texture handle + refcount.
- `Placement`: `{id, image_id, cell_rect, z, protocol}`.
- Cell references `PlacementId` via sparse side table (D3).
- Per-pane, per-screen (alt screen isolated).
- Reflow translates placement coords via line map.
- Kitty protocol's image cache honored (images persist without
  placements until explicit delete).

### D7 — Tab/pane tree is pure Zig data; GTK widgets are the view
Serialization is trivial (our own tree). GTK widgets rebuild from
tree state on layout load. No persistence logic tangled with GTK.

### D8 — Wayland first
Plasma 6 Wayland is primary. GTK4 is excellent on Wayland. X11
works via XWayland without effort. No native X11 backend.

### D9 — One GtkGLArea per pane, nothing shared at the GL level
Each pane owns its GL context, and each `TerminalSurface` owns its
own `Atlas`, built in its realize handler against that context. There
is no window-level root context and no share group: context loss on
one pane stays local to it. See `docs/gpu.md` "Contexts and the
atlas".

Soft limit: ~32 panes per window — empirical, based on per-context
driver overhead. Note this differs from `docs/layout.md`'s
per-tab caps (64 tabs × 32 panes per tab at load time); the D9
limit is the *rendering* soft ceiling for a single window, not a
storage cap. For typical workloads (≤ 4 panes/tab × ≤ 8 tabs = 32
panes) there is no issue. Above that, consolidate to one
`GtkGLArea` + viewport-per-pane — post-v1 optimization. See
`docs/gpu.md` share-groups section.

### D10 — Input encoding is table-driven
Static tables map `(keyval, modifiers, mode)` → byte sequence and
are audited against xterm's reference; `modifyOtherKeys` and the
kitty keyboard protocol (CSI u, every progressive-enhancement flag)
are layered on the same `input.encode` (see `docs/protocols.md`).

### D11 — Screen buffer reflows on resize (not truncate)
Alacritty-style reflow: lines re-wrap to new width; content
preserved. Soft-wraps are tracked via `Line.continues` flag so
logical lines can re-wrap correctly on subsequent resize.

### D12 — Cursor-blink via frame clock
`gdk_frame_clock_add_tick_callback` drives the blink. No separate
timer thread; vsync-locked to the compositor.

## Mux subsystem (durable sessions)

The terminal core (parser → `Event` → `Screen`) has no GTK
dependency, which makes it host-agnostic: the same pipeline runs
inside `sketerm-mux`, a libc-only daemon that owns PTYs so shells
survive the GUI.

```
src/mux/
├── wire.zig        framed binary protocol; append-only FrameType/
│                   EventTag bytes; every parser Event round-trips
├── snapshot.zig    lossless Screen serialization (grid, alt,
│                   scrollback, styles, links, clusters, modes,
│                   palette, prompt marks)
├── daemon.zig      single-threaded poll loop; one PTY + Parser +
│                   authoritative Screen per session; events applied
│                   once, broadcast to attached clients
├── client.zig      Conn (frame IO over any fd), connectSsh,
│                   connectUdp, daemon spawn helpers
└── rudp.zig        encrypted reliable-datagram transport (UDP)
src/mux_main.zig    sketerm-mux entry: daemon / --proxy /
                    --udp-listen / --udp-connect modes
```

**Events on the wire, never escape sequences.** The protocol carries
the parsed `Event` representation, so every feature (kitty graphics,
OSC 52, hyperlinks, underline colors) works through the mux with no
per-feature support — the property tmux structurally cannot have.
Attach sends a sequence-stamped snapshot, then streams live events;
the client applies them to its local `Screen` through the same code
path every session uses — there is no separate "local" path left.

**Transports.** One protocol, three pipes:
- *Local*: Unix socket at `$XDG_RUNTIME_DIR/sketerm/mux.sock`.
- *SSH*: `ssh -T -o BatchMode=yes host sketerm-mux --proxy`; the
  proxy bridges stdio to the remote daemon's socket, auto-starting
  it. sshd is the auth boundary. `$SKETERM_SSH` overrides the ssh
  binary (used by the test rig to fake a remote host).
- *UDP* (mosh-style): an SSH bootstrap runs `--udp-listen`, which
  announces `SKETERM-UDP <port> <keyhex>` and detaches; the session
  then runs over ChaCha20-Poly1305-sealed datagrams. The u64 crypto
  sequence doubles as nonce and feeds an anti-replay window; the
  server re-learns the peer address only from authenticated packets,
  which is what makes roaming (IP changes, suspend) free. A
  go-back-N stream with piggybacked acks runs on top so the framed
  protocol is unchanged. `rudp.zig` is a pure state machine with
  injectable clock/emit — loss, replay, and tamper are unit-tested.

**File transfer (proto v3).** Because the daemon *is* the session,
moving a file is just streaming bytes over the mux connection.
*Upload*: the GUI sends `file_open`/`file_data`/`file_close`, the daemon
writes into the shell's working directory (`/proc/<pid>/cwd`), using
only the basename (no traversal) and a non-clobber rename. *Download*:
the GUI sends `file_get`, the daemon opens the file (regular files only)
and streams it back over the SAME `file_data` frame the other way —
paced by the client's write-buffer high-water mark (`pumpDownloads`,
beside `pumpWinstreams`) so a huge file can't balloon memory. Both
answer with `file_reply` (ready/progress/done/error). A third pair,
`file_list`/`file_listing`, reads a remote directory (dirs-first,
size-stamped) so the GUI can offer a **remote file picker** instead of
making the user type a path. No shell help, no transport-specific code —
works over local/SSH/UDP alike. The GUI drives upload from a
drag-and-drop onto a remote pane or "Upload File…", and download from
"Download File…" (which opens the `src/ui/remote_browser.zig` picker); a
tab progress ring + `AdwToastOverlay` report both.

**Broker and workers.** The default local daemon is a BROKER plus
one WORKER process per session (`SKETERM_NO_BROKER=1` selects the
single-process monolith). The broker holds no session state: it
listens, accepts, spawns, answers `list` from metadata the workers
push, is the authority for renames, and routes attaches. A worker is
the same `Daemon` machinery with exactly one session (its PTY,
parser, authoritative Screen, Wayland hub and channels), forked
without exec, and fed clients through a control socketpair
(`platform.controlSocketpair`) instead of `accept`: on attach the
broker passes the client's socket fd over `SCM_RIGHTS`, so the hot
path is client to worker directly, with no relay. A worker crash, OOM
or hang is contained to its session. `zig build smoke-broker` guards
the split; `src/mux/CLAUDE.md` holds its invariants.

**GUI side.** `Terminal.initRemote` builds a Terminal with no PTY,
no parser and no worker thread: the connection fd is watched via
`g_unix_fd_add` on the main loop, EVENTS frames apply directly to
`Screen`, SNAPSHOT swaps the screen wholesale. `writeRaw` /
`requestResize` send INPUT / RESIZE frames. The GUI holds no `Pty`
at all; the daemon-side `Pty.reap` / `closeAndReap` keep their
`child_pid <= 0` guard because a `waitpid(-1)` there would reap an
unrelated child (another session's).

**Failure boundary.** GUI crash/restart/disconnect: sessions
survive, reattach restores screen + scrollback exactly. Daemon
death (server reboot, kill -9): sessions are gone — orphaned PTYs
SIGHUP their children. Same boundary as tmux.

## Browser subsystem (integrated CEF)

A pane can host a real browser instead of a terminal. The engine is
CEF (Chromium) in windowless/off-screen mode, hosted by a separate
`sketerm-webengine` process; the GUI keeps its own chrome, tab model
and MCP layer. See `src/web/CLAUDE.md` for the invariants and
`src/ui/webface.zig`'s header for presentation and pacing detail.

**Process split.** `sketerm-webengine` is the only binary linking CEF,
and it is a separate process for **crash isolation** — an engine crash
must not take the terminal and its shells with it. It also lets the
engine run with no GUI at all (headless MCP), and leaves room for the
helper to run on a remote host later. It is NOT a GTK3-vs-GTK4
workaround; libcef links no GTK.

**Wire.** One unix socket, one helper per GUI process, frames
length-prefixed and little-endian with append-only tags, capabilities
instead of version bumps — the same discipline as the mux protocol, and
deliberately engine-neutral so a future engine means a new helper rather
than a rewrite. Buffers travel as file descriptors over `SCM_RIGHTS`.
`src/web/protocol.zig` is the source of truth.

**Frames.** Two families, both ending as a `GdkTexture` on the face's
`GtkPicture`: dma-buf planes imported by GSK with zero copies (GPU
rasterisation, only under `--ozone-platform=wayland`), or a memfd
mapping whose damage rects become the texture's update region (software
fallback). Presenting through a `GtkGLArea` is forbidden — its integer
scale factor resamples twice on fractional-scale outputs and visibly
softens text.

**Pacing.** The engine's own scheduler paints, throttled by a per-view
cap that the GUI clamps to the current output's refresh. An unchanged
page paints nothing and a hidden view is stopped outright, so idle cost
is zero without a frame-clock tick.

**Semantic layer.** An injected script publishes a page walker in an
authenticated channel established before any page script runs; the
helper keeps a shadow tree with stable element ids, emits deltas rather
than whole snapshots, and carries ids across navigations by subtree
fingerprint. This one layer feeds both the MCP `web_*` tools and
(eventually) accessibility projection.

**Identity.** `sketerm web` / the `sketerm-web` hardlink register their
own application id, desktop entry and icon, so the browser is its own
taskbar application and can be set as the system default browser.

## Module ownership

- `main.zig` — owns the `AdwApplication` and spawns windows.
- `ui/window.zig` — owns `AdwApplicationWindow`, `AdwTabView`, and
  one `PaneTree` model per tab (`ui/tree.zig`, attached to its
  `AdwTabPage` as qdata so it travels with a dragged tab).
- `ui/pane.zig` — owns one `Terminal`, one `TerminalSurface` (by
  value), and the pane's faces (file browser, editor, panel,
  app embed, web).
- `ui/terminal_surface.zig` — owns the pane's `GtkGLArea` and its
  GL lifecycle, its `Atlas`, the render passes, one `ImageStore`,
  and the visual timers (cursor blink, trail, bell).
- `terminal.zig` — owns one mirror `Screen` and the `Remote`
  connection to the daemon. It owns NO pty, no parser and no worker
  thread: the PTY read and the parse both happen in `sketerm-mux`,
  and what arrives here is already-parsed events.
- `grid/screen.zig` — owns active screen, alternate screen,
  scrollback ring.
- `grid/image_store.zig` — owned by `ui/terminal_surface.zig`; owns
  all placements and decoded images for a pane. (GL texture handles
  freed on main thread only.)
- `ui/webface.zig` — owns one browser view and the client shared by
  every web face in the process; the CEF engine itself is a
  separate process.
- `render/atlas.zig` — owned by `ui/terminal_surface.zig`, one per
  pane (see D9).

## Companion documents

- `docs/gpu.md` — GL integration, share groups, fractional scaling,
  driver notes, shader strategy
- `docs/images.md` — placement model, protocol semantics, reflow,
  alt-screen isolation, eviction
- `docs/layout.md` — persistence format, save/load triggers,
  degraded-load behavior
- `docs/lifecycle.md` — PTY spawn, session lifetime, signal
  handling, teardown
- `docs/REMOTE.md` — durable and remote sessions from the user's side
- `docs/config.md` — every config key, with the profile rules
- `docs/mcp.md` — the MCP server and its tool families
- `docs/lsp.md` — the editor's LSP client
- `docs/display.md` — external display sessions (the headless test rig)
- `docs/macos.md` — the macOS port's state and its platform seams
- `docs/testing.md` — test roots, smoke rigs, what may not be Xvfb'd
- `docs/protocols.md` — the escape sequences and protocols supported

Nested `CLAUDE.md` files carry the invariants for the subsystems that
have earned them: `src/mux/`, `src/ipc/`, `src/web/`, `src/lsp/` and
`src/ui/browser/`. Read the one for the subsystem before changing it.

Planning documents (`plan*.md`, `milestones.md`, `risks.md`,
`references.md`, `mux-design.md`, `render-thread-analysis.md`) are
HISTORICAL. They record what was intended and why, not what exists;
where they disagree with the code, the code wins.
