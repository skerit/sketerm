# Architecture

## Module tree

```
src/
├── main.zig                application entry, CLI args, signal wiring
├── c.zig                   @cImport bundle: gtk4, adwaita, freetype,
│                           harfbuzz, epoxy (GL), lua, glib, gio
├── config.zig              config file loader (ZON)
├── pty.zig                 PTY spawn + read loop (per-pane worker)
├── terminal.zig            composes pty + parser + screen per pane
│
├── parser/
│   ├── vt.zig              Paul Williams VT state machine → Event
│   ├── event.zig           Event tagged union (Print, CSI, OSC, DCS, APC, …)
│   ├── osc.zig             OSC dispatcher (52, 8, 7, 11, 1337, palette)
│   ├── dcs.zig             DCS frame framing (sixel passthrough)
│   ├── apc.zig             APC frame framing (kitty graphics)
│   ├── sixel.zig           DCS q…ST → RGBA + placement metadata
│   ├── kitty_image.zig     APC G=… → image commands (transmit/put/del)
│   └── iterm_image.zig     OSC 1337;File=… → RGBA (PNG via stb_image)
│
├── grid/
│   ├── cell.zig            Cell struct (8 bytes) — see D3
│   ├── style_pool.zig      interned StyleEntry for fg/bg/attrs
│   ├── rune_pool.zig       interned multi-codepoint clusters
│   ├── link_table.zig      OSC 8 link_id ↔ URL table
│   ├── line.zig            Line + dirty flag + wrap flag
│   ├── screen.zig          active + alternate + scrollback ring
│   ├── image_store.zig     per-pane image placements (see images.md)
│   ├── selection.zig       selection model
│   └── width.zig           Unicode width tables (generated)
│
├── render/
│   ├── atlas.zig           FreeType glyphs → GL texture pages, LRU
│   ├── gl.zig              minimal GL wrapper + shader compilation
│   ├── grid_pass.zig       instanced-quad grid renderer
│   ├── image_pass.zig      textured-quad image renderer
│   └── cursor.zig          cursor styles (DECSCUSR), blink timer
│
├── ui/
│   ├── app.zig             AdwApplication singleton
│   ├── window.zig          AdwApplicationWindow + AdwTabView + root GL context
│   ├── tab.zig             one tab = one pane_tree + sticky title
│   ├── pane.zig            interactive pane: input/menus/faces around a surface
│   ├── terminal_surface.zig terminal renderer: GLArea + passes + visual timers
│   ├── pane_tree.zig       binary tree {Leaf(Pane) | Split(H|V, a, b)}
│   ├── menu.zig            GMenu / GActionMap builder
│   ├── clipboard.zig       GdkClipboard ↔ OSC 52 bridge
│   ├── input.zig           GdkEvent → xterm byte encoding
│   └── ime.zig             GtkIMMulticontext (fcitx5/ibus)
│
├── layout.zig              serialize/deserialize tab tree (ZON)
└── util/
    ├── ring.zig            SPSC lock-free ring buffer
    ├── utf8.zig            utf-8 decode helpers
    ├── base64.zig          streaming base64 decoder (for OSC 52, iTerm2)
    └── eventfd.zig         eventfd wrapper for worker wakeup
build.zig
build.zig.zon               Zig toolchain pin; no package deps (all system libs)
```

## Data flow

Steady-state path from child process byte to pixel:

```
   child process (bash)
          │
          ▼  writes bytes to slave fd
   PTY (kernel)
          │
          ▼  poll(master_fd, shutdown_fd)
   ┌──────────────────┐    worker thread (one per pane)
   │   PTY read       │
   │   Parser (VT)    │
   │   emits Events   │
   └────────┬─────────┘
            │ push
            ▼
   ┌──────────────────┐    lock-free SPSC ring (64 KB, fixed-size)
   │   Event Ring     │
   └────────┬─────────┘
            │  g_main_context_invoke(main_drain)
            ▼
   ┌──────────────────┐    main thread (GLib main loop)
   │  main_drain:     │
   │   drain ring     │
   │   apply to Screen│
   │   update images  │
   │   queue_draw     │
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

Back-pressure is natural: if the main thread falls behind, the ring
fills. When full, the worker blocks on push, which blocks PTY read,
which blocks the child on write. Self-regulating, no explicit flow
control needed.

## Threading model

| Thread        | Owns                                                   |
| ------------- | ------------------------------------------------------ |
| GTK main      | All GTK/GDK/GL objects, Screen, ImageStore, UI state   |
| PTY worker    | PTY fd + Parser state + ring producer + shutdown eventfd |
| (none others) | v1 has no other threads                                |

One worker **per pane**. All GTK/GDK/GL objects live exclusively
on the main thread. The worker never touches anything but the PTY
fd, its shutdown eventfd, and its ring producer side.

See `docs/lifecycle.md` for start/stop/signal details.

## Cross-thread wakeup

**Do not use `g_idle_add`** — it does not coalesce. But
`g_main_context_invoke` doesn't self-coalesce either: 1000 calls
schedule 1000 sources. Coalesce explicitly with a per-pane
atomic flag:

```zig
// Worker, after parsing a batch and pushing events:
const was_pending = term.drain_pending.swap(true, .acq_rel);
if (!was_pending) {
    // We transitioned false → true; we own the wakeup.
    _ = c.g_main_context_invoke(null, mainDrainEvents, @ptrCast(term));
}
// If was_pending == true, an earlier wakeup is already in flight;
// the main-thread drain will see our new events.

// Main thread drain callback:
fn mainDrainEvents(user: ?*anyopaque) callconv(.C) c.gboolean {
    const term: *Terminal = @ptrCast(@alignCast(user.?));
    // Clear flag BEFORE draining. If worker pushes during drain,
    // it will reschedule us.
    term.drain_pending.store(false, .release);
    // Drain ring → Screen → ImageStore → queue_draw
    while (term.ring.pop()) |ev| term.screen.apply(ev);
    c.gtk_widget_queue_draw(term.glarea);
    return c.G_SOURCE_REMOVE;
}
```

This guarantees at most one `g_main_context_invoke` in flight per
pane, regardless of how many events the worker produces. Many
events per batch → one wakeup, one drain, one `queue_draw`.

`gtk_widget_queue_draw` itself coalesces automatically within a
frame, so multiple drain cycles within one frame still produce
one render.

Frame-clock-driven animations (cursor blink) use
`gdk_frame_clock_add_tick_callback` per widget.

See `docs/gpu.md` for the full GL-integration rationale.

## Allocator strategy

Zig's explicit allocation discipline, three domains:

1. **App allocator** — `std.heap.GeneralPurposeAllocator` with
   `.safety = true` in debug. Long-lived objects (windows, tab
   trees, screens, scrollback, image textures). Main thread only.
2. **Parser arena** — `std.heap.ArenaAllocator` per worker. Reset
   once per ring-drain cycle (not per event — too fine; not per
   connection lifetime — too coarse). Holds transient event
   payloads (CSI params, short OSC strings).
3. **Event ring** — per pane, fixed-size (64 KB). Payloads ≤ 32 B
   inline; larger payloads (long OSC, image bytes) heap-allocated
   on the worker and ownership transfers to the main thread via
   the ring entry.

**OSC payload pool** (M5+): a per-worker slab pool for ≤ 4 KB OSC
payloads avoids GPA contention under rapid OSC 52 writes. Large
payloads still go through GPA.

No GC. Every allocation has a defined owner and a defined free
site. Leak detection via GPA's debug mode during development.

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
Parser state is per-stream. Each pane's worker owns its own state.

### D3 — Cell is 8 bytes; heavy data in side tables

Each `Cell` is:

```zig
pub const Cell = extern struct {
    rune_or_cluster: u32,     // scalar codepoint or ClusterId in rune_pool
    style_ref: u16,           // index into StyleEntry pool (fg+bg+attrs)
    flags: u8,                // bits: is_cluster | has_link | has_image |
                              //       is_wide_left | is_wide_cont | …
    reserved: u8,
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

Side tables (all main-thread-owned, per-pane):

- `rune_pool: AutoHashMap(ClusterId, []const u21)` — interned
  grapheme clusters.
- `style_pool: ArrayList(StyleEntry)` — interned `{fg, bg, attrs}`
  triples; deduplicated.
- `link_table: AutoHashMap(CellCoord, LinkId)` — sparse OSC 8 map.
- `cell_images: AutoHashMap(CellCoord, PlacementId)` — sparse
  image map (see `images.md`).

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
Direct shader control. See `docs/gpu.md`.

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

### D9 — One GtkGLArea per pane, context share group at window level
Each pane owns its GL context; window owns the root. All contexts
share via `gdk_gl_context_create_shared`. Atlas lives at window
level, reachable from every pane's context.

Soft limit: ~32 panes per window — empirical, based on per-context
driver overhead. Note this differs from `docs/layout.md`'s
per-tab caps (64 tabs × 32 panes per tab at load time); the D9
limit is the *rendering* soft ceiling for a single window, not a
storage cap. For typical workloads (≤ 4 panes/tab × ≤ 8 tabs = 32
panes) there is no issue. Above that, consolidate to one
`GtkGLArea` + viewport-per-pane — post-v1 optimization. See
`docs/gpu.md` share-groups section.

### D10 — Input encoding is table-driven
Static tables map `(keyval, modifiers, mode)` → byte sequence.
Easy to audit against xterm's reference; easy to extend for CSI u
(post-v1). `modifyOtherKeys=1` in v1 because emacs needs it.

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
the client applies them to its local `Screen` through the exact code
path the local PTY worker uses.

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

**GUI side.** `Terminal.initRemote` builds a Terminal with no PTY
and no worker thread: the connection fd is watched via
`g_unix_fd_add` on the main loop, EVENTS frames apply directly to
`Screen`, SNAPSHOT swaps the screen wholesale. `writeRaw` /
`requestResize` abstract PTY-vs-socket so `src/ui` never touches
`terminal.pty`. Remote terminals have `child_pid = -1`; exit-reaping
guards on `child_pid <= 0` (a `waitpid(-1)` would reap arbitrary
GUI children).

**Failure boundary.** GUI crash/restart/disconnect: sessions
survive, reattach restores screen + scrollback exactly. Daemon
death (server reboot, kill -9): sessions are gone — orphaned PTYs
SIGHUP their children. Same boundary as tmux.

## Module ownership

- `ui/app.zig` — owns `AdwApplication`, spawns windows.
- `ui/window.zig` — owns `AdwApplicationWindow`, the root
  `GdkGLContext`, `AdwTabView`, shared atlas.
- `ui/tab.zig` — owns one `pane_tree` and the sticky tab title.
- `ui/pane.zig` — owns one `Terminal` and one `GtkGLArea`.
- `terminal.zig` — owns one `pty`, one `parser.State`, one
  `Screen`, one `ImageStore`, one `Renderer`, one SPSC ring,
  and the worker thread handle.
- `grid/screen.zig` — owns active screen, alternate screen,
  scrollback ring.
- `grid/image_store.zig` — owns all placements and decoded images
  for a pane. (GL texture handles freed on main thread only.)
- `render/atlas.zig` — owned by `ui/window.zig`; shared across all
  of the window's panes.

## Companion documents

- `docs/gpu.md` — GL integration, share groups, fractional scaling,
  driver notes, shader strategy
- `docs/images.md` — placement model, protocol semantics, reflow,
  alt-screen isolation, eviction
- `docs/layout.md` — persistence format, save/load triggers,
  degraded-load behavior
- `docs/lifecycle.md` — PTY spawn, worker management, signal
  handling, teardown
