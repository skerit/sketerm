# Proposal: remote GUI apps on a macOS client

Goal: `sketerm app <host> <cmd>` (and eventually durable-tab app
forwarding) working when the LOCAL machine is a Mac, as transparently
as the Linux waypipe path — the user never names a backend.

## STATUS (2026-06-12, evening)

Linux side COMPLETE and DEFAULT. All milestones landed in
src/wlhost/ + daemon + GUI: wire codec/tables, daemon endpoint,
compositor brain, input (pc105/us keymap over the pipe), resize,
damage-row copies + deflate, popups, text clipboard, cursor-shape/
viewporter/fractional-scale. Validated live: weston-terminal, GTK4,
libadwaita (ghostty: known-incompatible, exits pre-map, app-side).
Native pipe is the session default; waypipe is opt-in
(SKETERM_MUX_WAYLAND=waypipe, per-session wl_mode for the headless
`sketerm app -u` bridge). REMAINING: the macOS merge milestone
(needs the Mac hardware), waypipe code removal after a cool-down,
dnd + non-text clipboard as demand appears.

## DECISION (2026-06-12)

After the analysis below: **go fully native, skip every interim.**

- xpra backend (option A): REJECTED — throwaway work.
- Darwin waypipe port (option C step 2 / "phase 2a"): REJECTED —
  waypipe is dropped entirely, on every OS, both ends. (The build
  spike data stays below for the record: 30 errors / 6 patterns /
  3 files, so the door is reopenable if priorities change.)
- BUILD: the sketerm-native pipe. Daemon (`sketerm-mux`) grows a
  Wayland wire endpoint + fd/buffer replication on its per-session
  display socket; the GUI grows the compositor brain (`src/wlhost/`,
  GTK-free core) rendering into sketerm-owned windows. Rides the
  existing chan_* frames over all transports. End state: server
  install = sketerm-mux alone, client install = sketerm alone — no
  third-party display tooling anywhere.
- Primary development happens on the LINUX machine (real Wayland
  clients + reference compositors for trace-diffing). The Mac is the
  merge-milestone validator (GTK-macOS input/scaling quirks, cross-OS
  run against a Linux remote). The existing Linux↔Linux waypipe path
  stays untouched until the native path matures, then retires.
- Milestone order: wire codec + protocol tables (pure Zig, unit
  tests) → daemon endpoint with full-copy buffers → compositor
  renders `foot` → input → GTK apps → damage diff + compression →
  popups/clipboard tail.

## What already works (verified on hardware, 2026-06)

The architecture split was done right for this:

- **Remote side is client-OS-agnostic.** The daemon wraps sessions in
  `waypipe server`; `sketerm app` runs stock waypipe on the Linux
  remote. Nothing there knows what renders the windows.
- **Transports are byte streams.** chan_open/data/close over ssh, mux
  socket, or roaming UDP — all verified working FROM macOS this
  session (terminal sessions over all three).
- **The dispatch seam exists.** `remoteapp.zig` probes the remote and
  switches on `RemoteKind`; the comment literally reserves this as
  the place future backends plug in. The GUI side cleanly refuses
  channels it can't render (`wlbridge.connectApp() == null` →
  chan_close), so a macOS GUI attached to a Linux session degrades
  gracefully today.

## The gap

`wlbridge.zig` spawns `waypipe client`, which needs two things macOS
doesn't have:

1. **A waypipe binary.** Upstream (Rust, 0.10+) does not build for
   Darwin — Linuxisms: `memfd_create`, socket details, epoll-ish IO.
2. **A Wayland compositor to render into.** macOS has none usable:
   - `owl` (ObjC/Cocoa): years stale, "lack of manpower".
   - `cocoa-way` + `waypipe-darwin` (J-x-Z, 2026): EXACTLY the right
     shape (Smithay compositor on Cocoa + Darwin-patched waypipe) —
     but single-commit, no history, vendored unauditable deps,
     community calls it vibecoded slop. Useful as a feasibility
     proof and a map of the Darwin patch surface; not a dependency.

## Options

### A. xpra backend (pragmatic, ~days of work)

xpra is the mature waypipe-equivalent for X11 with a NATIVE macOS
client (its own Quartz windows — no XQuartz needed). Seamless mode:
each remote app window is a native local window; clipboard, audio,
notifications, tray sync.

- Local: xpra macOS client app. **Wart: not notarized; the brew cask
  is deprecated for exactly that and dies 2026-09-01.** Install is
  xpra.org DMG + right-click-open (or `xattr -d
  com.apple.quarantine`). Fine for us; rough edge for "transparent".
- Remote: needs `xpra` installed there (Python + Xvfb stack — much
  heavier than waypipe, but apt/pacman one-liner). Probe line 2
  extends to also `command -v xpra`.
- Dispatch: `run()` keys the LOCAL capability check on the OS —
  Linux local → require WAYLAND_DISPLAY+waypipe (as today); macOS
  local → require the xpra client app. Remote probe returns what's
  available; pick the backend both ends support.
- Invocation (one-shot): exec
  `xpra start ssh://[user@]host/ --start-child=CMD
   --exit-with-children --attach=yes` — xpra handles spawn, attach,
  and teardown over its own ssh. Honors `$SKETERM_SSH`? xpra has
  `--ssh=CMD` — yes.
- Scope limits: covers `sketerm app host cmd` only. Durable-tab GUI
  forwarding and `-u` roaming stay Linux-local-only in this phase
  (xpra's one-session-per-client model needs more design to ride the
  mux channels; xpra does support unix-socket attach, so it's
  possible later, one `xpra attach socket://` per app session).

### B. XQuartz + ssh -X fallback (near-zero work)

XQuartz 2.8.5 is alive, signed, auto-updating (cask fine). Remote
needs only xauth. Rootless windows. SLOW — uncompressed X11 round
trips; the thing waypipe/xpra exist to fix. Worth shipping only as
the "nothing else available" tier with a slow-path warning, or not
at all.

### C. Native end-state: sketerm IS the compositor (months)

The from-scratch answer, and the only one that makes ALL existing
transports light up unchanged (ssh, durable tabs, UDP roaming):

1. **Minimal Wayland compositor in-tree.** A Unix socket speaking
   the Wayland wire protocol (fd-passing via SCM_RIGHTS — works on
   Darwin), implementing wl_compositor/wl_surface, wl_shm (waypipe
   in --no-gpu mode transfers ONLY shm buffers — no dmabuf needed),
   xdg_wm_base/xdg_surface/xdg_toplevel, wl_seat (+ xkb keymap
   generation; GTK keyval → evdev code mapping is the fiddly bit),
   wl_output. Render shm buffers through the existing GL/texture
   infra into GTK windows (or, post-AppKit-frontend, NSWindows —
   this is where the tree.zig de-GTK plan and this proposal meet).
   Ballpark 3–6k lines of Zig; wire format is simple and we already
   write protocol parsers for a living.
2. **Darwin waypipe.** The local `waypipe client` binary still must
   exist (the remote speaks waypipe's compressed protocol; we don't
   want to reimplement THAT). Patch surface per the waypipe-darwin
   fork: memfd_create → shm_open/tmpfile, unnamed-socket handling,
   log paths. Try upstreaming to gitlab.freedesktop.org/mstoeckl/
   waypipe first; vendor a patched build if rejected.
3. `wlbridge.zig` then changes ONE thing on macOS: instead of
   requiring $WAYLAND_DISPLAY, it points the spawned waypipe client
   at sketerm's own compositor socket. Everything upstream of it —
   channels, daemon wrapping, roaming — is already verified on Mac.

## Recommendation

- **Phase 1 (now): option A.** Small, fits the existing probe seam,
  delivers `sketerm app mac→linux` end-to-end. Document the xpra
  install friction honestly. Skip option B unless someone asks.
- **Phase 2 (the real goal): option C.** Track it as the milestone
  after the AppKit frontend work, since the compositor's render side
  wants to reuse whatever the native frontend settles on. Watch
  cocoa-way/waypipe-darwin for ideas only; depend on neither.

## Open questions

- xpra `--ssh` pass-through of `$SKETERM_SSH` wrapper args: verify on
  hardware before relying on it for the test rig.
- Keyboard layouts in the Phase-2 compositor: ship a fixed pc105/us
  xkb keymap first and translate GTK keyvals, or generate keymaps
  from the macOS input source? Start fixed, iterate.
- Phase-2 clipboard: wl_data_device ↔ NSPasteboard bridging — scope
  to text first.

## Addendum: the REVERSE direction — Linux client, remote macOS apps

No display protocol crosses this wire: macOS apps speak private Mach
IPC to WindowServer, there is no DISPLAY= equivalent, and XQuartz
only covers X11 apps (no real Mac apps). Protocol forwarding is
impossible by construction → this direction is pixel streaming.

Design: a **window-streaming agent** on the Mac, as an extension of
sketerm-mux (already verified running on Darwin):

- **Capture**: ScreenCaptureKit (macOS 12.3+) streams a SINGLE
  window (SCContentFilter per window) hardware-accelerated, with
  window metadata; can also capture app audio. Frames as
  CVPixelBuffers → damage-tracked raw/LZ4 first, VideoToolbox H.264
  later if bandwidth demands it.
- **Input**: CGEventPost for keyboard/mouse; window enumeration via
  SCShareableContent/CGWindowList. App launch + lifecycle via
  NSRunningApplication.
- **Transport**: the existing chan_open/data/close byte channels,
  with a new ChanKind (e.g. .winstream) next to .wayland. All three
  transports (ssh / mux / roaming UDP) work unchanged.
- **Linux render side is the easy half**: sketerm opens a GTK window
  per remote window and blits frames through the existing GL upload
  path. No compositor involvement needed.
- `remoteapp.zig` already reserves `RemoteKind.darwin` for this.

Hard constraints to document up front:
- The remote Mac needs a logged-in GUI session (WindowServer must be
  running; headless racks need auto-login).
- One-time TCC grants on the Mac: Screen Recording + Accessibility.
  Not scriptable, by design.

## Decision summary (the full matrix)

| Client \ Apps on | Linux remote            | macOS remote              |
|------------------|-------------------------|---------------------------|
| Linux            | waypipe (DONE)          | ScreenCaptureKit agent    |
| macOS            | xpra now → sketerm-as-compositor + Darwin waypipe | same agent (render side is portable) |

Note the agent also solves mac→mac, and its Linux render side is the
same code that phase-2's compositor would feed — the GL blit path is
shared either way.
