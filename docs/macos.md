# macOS support

Status: **verified on real hardware** (Apple Silicon M2, macOS 26.4,
Homebrew GTK 4.22, Zig 0.16.0). The GUI builds and runs natively, the
full unit-test suite passes (500/507, 7 skipped), `smoke-mux` and
`smoke-e2e` PASS, and mux interop with a Linux daemon works over both
SSH and UDP transports. Remaining gaps are listed at the bottom.

## Verified on hardware (2026-06)

- **Native mux daemon**: `zig build mux && zig build smoke-mux` —
  PASS. The binary links libSystem + brew's libfribidi (the Mach-O
  linker does not drop the unused fribidi dep the way `--as-needed`
  does on Linux; harmless, but the native build is not
  single-file-portable — use `mux-portable` for that).
- **`cwdOfPid` offsets** (`layout.zig`): confirmed against the real
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
- **`sketerm app`** correctly refuses on macOS (no Wayland session) —
  Linux-only by design.

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

## Building on a Mac (verified recipe)

```bash
brew install zig pkgconf gtk4 libadwaita adwaita-icon-theme \
             freetype harfbuzz libepoxy fribidi fontconfig

zig build            # GUI → zig-out/bin/sketerm
zig build mux        # session daemon
zig build test       # 500/507 (7 skipped)
zig build smoke-mux  # daemon end-to-end
zig build smoke-e2e  # GUI end-to-end (opens a real window)
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
- `.app` bundle / packaging not started (run from zig-out/bin).
- Cmd-vs-Ctrl keybinding conventions not started.

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
