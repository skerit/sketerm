# macOS support

Status: **verified on real hardware** (Apple Silicon, macOS 26.5.1,
Homebrew GTK 4.22.4, Zig 0.16.0). The GUI builds and runs natively,
`zig build test` passes (1299/1319, 20 skipped), `test-core`,
`smoke-mux`, `smoke-e2e` and `smoke-a11y` PASS, remote macOS app
windows stream to a client, and mux interop with a Linux daemon works
over both SSH and UDP. Remaining gaps are listed at the bottom.

> **Re-verified 2026-08-04** after ~450 commits of drift. Four compile
> breaks and, more importantly, **five behavioural bugs that a build
> alone would never surface** — the daemon could not spawn a single
> session, and every file transfer failed. Building is not the same as
> working here; run the smoke rigs.

## Verified on hardware (2026-06)

- **Native mux daemon**: `zig build mux && zig build smoke-mux` —
  PASS. The binary links libSystem + brew's libfribidi (the Mach-O
  linker does not drop the unused fribidi dep the way `--as-needed`
  does on Linux; harmless, but the native build is not
  single-file-portable — use `mux-portable` for that).
- **`cwdOfPid` offsets** (now `util/platform.zig`): confirmed against the real
  SDK and a live call — sizeof(struct vnode_info)=152, vip_path at
  offset 152, MAXPATHLEN=1024, flavor 9, result matches getcwd().
- **GUI**: builds, opens a window, panes realize (GL via GDK's
  desktop-GL path), zsh runs, IPC socket + `sketerm cli` round-trips,
  OSC 7 cwd reporting works, `zig build smoke-e2e` passes natively
  (no DISPLAY env needed — gated on `platform.is_macos`).
- **Cross-direction builds**: `zig build mux-portable` (x86_64- and
  aarch64-linux-musl) cross-compiles green FROM macOS; a Mac-built
  aarch64-musl daemon runs unmodified on Ubuntu aarch64.
- **Mux interop from macOS**: `sketerm mux <host> list/new/attach`
  against a Linux daemon over SSH; durable sessions survive GUI
  restarts; snapshot-attach restores screen content. UDP transport
  (`udp:<ip>`) verified Darwin↔Darwin and Darwin↔Linux (ChaCha20
  datagrams, SSH bootstrap on Darwin, getentropy/clock paths in
  rudp.zig all exercised on hardware).
- **`sketerm app`** — superseded: a macOS host now streams its app
  windows to a client via the ScreenCaptureKit `winstream` backend
  (kind 3), so `sketerm app <mac-host> <binary>` works. It is only
  Wayland *forwarding* that a Mac cannot do; the session carries
  `wl_display = "-"` there and the client renders captured pixels.

## Real-hardware friction found (and fixed)

1. **Aro SIGBUS on `<arm_neon.h>`** — the first GUI build failure.
   graphene-config.h picks its NEON backend on any aarch64, and Zig's
   translate-c (Aro) crashes outright on arm_neon.h. Fixed in
   `vendor/cimport_root.h`: `GRAPHENE_SIMD_BENCHMARK` +
   `GRAPHENE_HAS_SCALAR` force graphene's scalar backend during
   translation (aarch64 only; x86_64 keeps SSE). Scalar simd4f is
   layout-compatible and sketerm never calls graphene itself.
2. **`c.stdout` is not a value on Darwin** — <stdio.h> defines the
   std streams as macros over `__stdoutp` etc., which translate-c
   renders as inline *functions*; glibc exports extern variables.
   Use `platform.stdout()/stderr()/stdin()` — never `c.stdout`.
3. **EGL smoke harnesses** don't exist on macOS (no EGL). They are
   registered in build.zig only for Linux targets; the default
   `zig build` would otherwise fail before compiling anything.
4. **Font candidates** were Linux distro paths; a default config
   found no font and panes never realized. macOS now falls back to
   Menlo/Monaco/SF Mono/Courier New (`pane.zig FONT_CANDIDATES`).
   FreeType opens Menlo.ttc fine (face index 0).
5. **zsh OSC 7 trailing `%`** — `${PWD//%/%25}` in zsh anchors an
   empty match at the END (it doesn't escape `%`), appending `%25` to
   every reported cwd. All-platform bug, surfaced by cwd checks here.
6. **`zig build mux` requires the full GTK dev set installed** even
   though the daemon doesn't use GTK: build.zig resolves pkg-config
   for every package eagerly at configure time. On a GTK-less host
   the daemon can't be built from source (cross-compile mux-portable
   from elsewhere instead). Known wart, not yet fixed.

## Behavioural bugs found on the 2026-08 re-verification

None of these were build failures. Each compiled cleanly and then did
the wrong thing at runtime — the reason the smoke rigs exist.

1. **No AF_UNIX SOCK_SEQPACKET on Darwin.** `socketpair()` fails with
   EPROTONOSUPPORT, so the broker↔worker control channel could never
   open and **every session spawn failed** ("spawn failed (name
   taken?)" — a guess, not the cause). Now `platform.controlSocketpair`,
   using SOCK_DGRAM there. Two consequences it has to absorb: a closed
   peer reports `-1`/ECONNRESET rather than `0` (so "channel gone" must
   test `n <= 0`), and a datagram is capped at `net.local.dgram.maxdgram`
   = **2048** unless SO_SNDBUF/SO_RCVBUF are raised — far under one
   worker metadata push, and an over-limit datagram is refused with
   EMSGSIZE and never retried, so the daemon would go permanently stale.
2. **`cwdOfPid` had no macOS branch in the daemon.** There were two
   copies: `layout.zig` had the libproc one, `daemon.zig` a bare
   `/proc/<pid>/cwd` readlink. So the daemon could not resolve any
   session's directory and **every file upload/download failed** with
   "cannot determine session directory". Both now share
   `platform.cwdOfPid`.
3. **The autostarted daemon inherited the client's stdio.** Not
   macOS-specific, but found here: the daemon outlives its client, so
   `sketerm mux spawn x | cat` hangs FOREVER the one time it also has
   to start the daemon — the shell waits for every pipe writer.
4. **fcntl and flock share one lock space on Darwin.** XNU keeps one
   advisory-lock list per vnode with the two kinds as distinct owners,
   so they conflict *with each other in the same process*. The transfer
   ledger's migration lock took both on one fd and could therefore never
   be acquired. Verified both directions cross-process, which is also
   why the fcntl lock alone suffices there.
5. **winstream counted a window at channel open**, not at the first
   frame — so an app that died before presenting anything (see the
   launch-constraints trap below) was dropped silently instead of
   materializing the log tab that explains the exit.

Smaller: `SIGBUS` is 7 on Linux and 10 on Darwin, which overflowed
crashlog's fixed truncating fallback into returning the empty string;
`tic` writes `~/.terminfo/73/…` (hex bucket) on a case-insensitive
filesystem, not `s/`, so `doctor` reported an installed terminfo as
missing.

## Building on a Mac (verified recipe)

```bash
brew install zig pkgconf gtk4 libadwaita adwaita-icon-theme \
             freetype harfbuzz libepoxy fribidi fontconfig libvpx

zig build            # GUI → zig-out/bin/sketerm
zig build mux        # session daemon
zig build test       # 1299/1319 (20 skipped)
zig build test-core  # GTK-free subset
zig build smoke-mux  # daemon end-to-end
zig build smoke-fs   # file service end-to-end
zig build smoke-e2e  # GUI end-to-end (opens a real window)
zig build smoke-a11y # NSAccessibility / VoiceOver bridge
```

**`libvpx` is not optional** — `configureSysDeps` links it
unconditionally for the VP9/WebM app-window recorder. It is missing
from every older copy of this recipe, and pkg-config resolves eagerly
at configure time, so its absence fails the build before anything
compiles.

On Linux `smoke-e2e` hosts its own display (a `sketerm-mux display`
session); macOS has no Wayland hub, so the GUI talks to the WindowServer
and the harness skips the real-seat stages (click/type/pixel diffs and
the Wayland input-method assertion). Those are Linux-only coverage.

```
```

brew's zig 0.16.0 matches the pinned toolchain; `/opt/homebrew/bin`
must be on PATH (pkg-config lives there). No PKG_CONFIG_PATH fiddling
was needed — pkgconf's defaults cover the brew prefix.

## Known noise / open items

- GTK prints a stream of `Theme parser warning: gtk.css ...` at
  startup (brew's default theme vs GTK 4.22) — cosmetic.
- Two `gtk_gl_area_queue_render: assertion 'GTK_IS_GL_AREA' failed`
  CRITICALs during smoke-e2e teardown — timing issue on the macOS
  backend, not yet chased; test still passes.
- Visual rendering confirmed only indirectly (no GL errors, e2e text
  assertions pass). `screencapture` needs Screen Recording permission
  — eyeball a window when working interactively.
- Creating/attaching a remote tab runs the SSH/UDP bootstrap on the
  GTK main thread — a slow or failing connect freezes the UI for the
  duration (pre-existing on Linux too, just easier to hit over real
  networks).
- `udp:localhost` v4/v6 resolution bug still applies — use a real IP
  or hostname.
- **`smoke-e2e` is FLAKY on macOS — the top open bug.** It fails part
  of the time at the browser-split stage with
  `{"ok":false,"error":"internal error: Disconnected"}`: the GUI's mux
  connection to its private daemon drops while that split is asking for
  the new pane's session. Measured 2026-08-04: 4/4 failures at
  `d00438d`, roughly 4-in-10 passes at the branch tip, so it is NOT a
  regression from the winstream/split work landed above — the split fix
  made it better without curing it.
  What is already ruled out: 40/40 bare `mux spawn` calls against a
  broker daemon succeed, and 25/25 `cli split` + `close-pane` cycles
  against a plain GUI succeed. So it needs the rig's fuller daemon
  state to show up, and the prime suspect is the winstream stage —
  the smoke's daemon has no Screen Recording grant (it runs from
  `.zig-cache`, which is a different code identity), so that stage
  hammers the capture-denied path. Whether the Darwin datagram control
  channel contributes cannot be A/B tested, because without it macOS
  spawns no sessions at all.
  Next step for whoever picks this up: preserve the rig's runtime dir
  (it is `removeTreeBestEffort`'d on exit) so its `mux.log` survives a
  failing run, and check for fd exhaustion across repeated denied
  captures.
- `.app` bundle / packaging not started (run from zig-out/bin).
- Cmd-vs-Ctrl keybinding conventions not started.
- **No filesystem watcher backend — the one real feature gap.**
  `fsserve.Watcher` is inotify-backed and inert elsewhere
  (`fsserve.live_deltas` is the predicate), so on macOS:
  * a directory VIEW serves its initial listing and never updates —
    including for changes the daemon itself makes through the mutation
    verbs, since those are observed through the same watch rather than
    synthesised. A browser listing goes stale until re-listed.
  * live queries (`live_find`) refuse honestly: "live queries need the
    platform watcher backend".

  The `smoke-fs` stages asserting either are gated on that predicate;
  the mutation verbs stay under test there via a re-list. **This gate
  is a placeholder for the backend, not the intended end state.**

  Design notes for whoever lands it — the choice is not obvious:
  * **kqueue** (`EVFILT_VNODE` on a directory fd) is the natural fit
    for a poll loop, but reports only *that* a directory changed, not
    which entry, so it needs a per-watch snapshot and a readdir+diff to
    synthesise per-name events. Worse, a child's *content* change does
    not fire the directory's event at all, so `IN_CLOSE_WRITE`
    equivalence needs one fd per FILE — an fd-budget problem on large
    trees (macOS ships a 256 soft `RLIMIT_NOFILE`).
  * **FSEvents** gives recursive path notifications including content
    changes, but wants a CFRunLoop, so it needs a dedicated thread
    feeding the poll loop through a pipe — which cuts against the
    daemon's single-threaded design, though CoreServices itself is
    fine (the daemon already links AppKit/ScreenCaptureKit here).

  Whichever lands must keep the inotify bit vocabulary as the neutral
  event encoding (`EventIter` decodes it, and both consumers —
  `daemon_serve.fsWatchReadable` and `fsjob.runLiveFind` — read the
  watcher fd directly, so they need a `Watcher.readInto`-shaped seam
  rather than a raw `read()`).

## Window-streaming agent friction (2026-06, hardware)

Found while landing the ScreenCaptureKit winstream backend:

1. **TCC identity is the whole game.** A daemon spawned from an SSH
   shell gets attributed to `sshd-session` and capture is refused
   outright ("user declined TCCs") — no prompt. Run the daemon as a
   LaunchAgent in the gui domain (`launchctl bootstrap gui/$UID`);
   the first capture attempt then registers the binary (disabled)
   in System Settings → Screen Recording for the user to enable.
   Ad-hoc-signed Zig binaries are re-identified per build (cdhash):
   grant a stable copy, not `zig-out/bin/`.
2. **System apps can't be PTY children.** macOS 26 launch
   constraints kill `/System/Applications/Calculator.app/...` (and
   friends) instantly when fork/exec'd from a shell — single-frame
   sessions that exit before attach. Validate with third-party apps
   or a custom AppKit binary; `src/winstream` testing here used a
   60-line ObjC test app (window + event counter).
3. **Darwin CMSG layout** bit the smoke: 12-byte cmsghdr, 4-byte
   alignment, and XNU rejects a `msg_controllen` padded to Linux's
   24 — `sendWithFd` now computes CMSG_SPACE per-OS. Same class of
   bug to watch for in any future fd-passing code.
4. **weston-terminal doesn't exist here**, so smoke-mux's real-app
   stage skips and the Wayland hub numbering shifts — the pending
   stage derives the hub id instead of hardcoding wl-3.

Verified on this hardware: stub winstream round-trip (smoke-mux
PASS natively), SCK daemon launch via LaunchAgent, missing-grant
notice window + actionable daemon log end-to-end over the real mux
socket. Real-capture validation requires the manual TCC toggles.

## Accessibility (VoiceOver / NSAccessibility)

The macOS twin of the Linux AT-SPI bridge. `src/a11y/nsax.zig` (Zig) +
`src/a11y/nsax_shim.m` (ObjC) implement the NSAccessibility text
protocol (role `AXTextArea`; value, ranges, caret) over the SAME
platform-neutral `src/a11y/view.zig` the Linux bridge uses — no text
model duplicated. The one macOS wrinkle — NSRange is in **UTF-16 code
units** while the neutral snapshot is in **codepoints** — is handled by
`Snapshot.char_to_utf16` + the bridge's `charForUtf16` inverse; astral
chars (emoji) count as 2 units, BMP (incl. Nerd-font glyphs) as 1.

**Why it can't reuse `atspi.zig`:** GTK4 on macOS ships only the AT-SPI
a11y backend, which is *unavailable on this platform* (`GTK_A11Y=help`
lists `atspi - Not available`). So `GtkAccessibleText` (atspi.zig)
reaches VoiceOver **not at all** here — the pane's text has to be put on
an NSAccessibility object directly.

**How it's wired (current GTK frontend):** there is no per-pane NSView
(GTK draws everything into one `GtkMacosContentView`). So `pane.zig`,
on the GL area's `map`, walks `gtk_widget_get_native` →
`gtk_native_get_surface` → `gdk_macos_surface_get_native_window` →
`[NSWindow contentView]` and attaches a `SketermTermAXElement`
(`NSAccessibilityElement`, one per pane) as an accessibility child of
that content view — which IS visible to VoiceOver. It detaches on
`unmap`/close, updates the element frame from the pane's widget bounds,
and posts value/selection-changed on each render (the macOS arm of the
spot that calls `a11y.notifyChanged` on Linux). All of this is behind
`platform.is_macos`; the Linux path is unchanged.

`src/a11y/nsax_shim.m` also has a `SketermTermView : NSView` (same
answers, shared statics) ready for the future de-GTK'd AppKit pane —
that pane just uses `nsax.newView(term)` instead of attaching an element.

**Verifying:**
- `zig build smoke-a11y` (native macOS) — drives a real
  `SketermTermView` through the AX selectors VoiceOver uses and asserts
  value text, UTF-16 char count, caret range, substring across a 😀
  surrogate pair, and line ranges against a known screen.
- Live, in the real GUI (no TCC grant needed):
  `SKETERM_A11Y_SELFCHECK=1 ./zig-out/bin/sketerm --no-save` logs
  `A11Y-SELFCHECK: pane=N bits=7 (PASS)` once a VoiceOver client walking
  window → contentView → child would find an `AXTextArea` whose value is
  the live terminal text (bit0 in children, bit1 role, bit2 non-empty).
- With VoiceOver (Cmd-F5) or Xcode's Accessibility Inspector, focus the
  sketerm window: the terminal reads as a text area whose value is the
  screen contents.

## Remote macOS apps (window streaming)

Streaming this Mac's app windows to a sketerm client (ScreenCaptureKit
capture + CGEvent input) has its own setup — code signing, a
GUI-session LaunchAgent, and TCC grants. The complete runbook is
**`docs/macos-winstream-setup.md`**; `dist/deploy-macos.sh` automates
the repeatable build and signing step without replacing a live daemon.
