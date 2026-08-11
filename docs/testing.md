# Testing strategy

Two unit-test roots, a set of conformance suites ported from other
emulators, headless GL render smokes, and end-to-end rigs that drive
the real GUI on sketerm's own compositor. Parser and grid
correctness is the top project risk; this document is how we contain
it.

Every step below is a real `zig build` step. `zig build --help`
lists all of them with their own descriptions - consult that rather
than a copy here, which will drift.

## Philosophy

- **Tests live next to the code.** Zig `test` blocks in the module
  they cover, plus dedicated `*_test.zig` files for the larger
  conformance suites. There is no separate `tests/` tree.
- **Conformance over invention.** The parser and screen suites are
  ported from kitty's `kitty_tests/*.py` and wezterm's
  `term/src/test/*.rs`, so a disagreement is a real disagreement
  with a shipped emulator rather than with our own assumptions.
- **Real byte streams for the hard cases.** `zig build replay`
  pushes a captured PTY stream through parser + Screen and dumps the
  grid, which is the fastest route from an "app X renders wrong"
  report to a diagnosis.
- **No mocks for GL.** The render smokes create a real surfaceless
  EGL context via Mesa and read pixels back.
- **No mocks for the GUI either.** The end-to-end rigs start a real
  sketerm against a real compositor. See *Never Xvfb* below.

## The two test roots

```bash
zig build test        # everything, GUI included
zig build test-core   # the GTK-free subset
```

- `src/tests.zig` imports every module containing `test` blocks.
  **A new test file must be added here or `zig build test` will not
  see it.**
- `src/tests_core.zig` is the GTK-free subset, built with the same
  lean dependency set as `sketerm-mux`. It exists because
  `zig build test` compiles the GUI: on a host whose GTK predates
  what the GUI calls into, the entire suite is unrunnable, daemon
  logic included.

**A new core-side test file belongs in BOTH roots.** Anything
reaching into `ui/` or `render/` belongs only in `tests.zig` -
putting it in `tests_core.zig` breaks the build for `mux-portable`
users.

On x86_64 Linux both steps deliberately use Zig's self-hosted x86
backend and linker: the monolithic roots then compile in seconds
instead of minutes. `-Dtest-llvm=true` switches to LLVM, for
production-codegen parity or a suspected compiler-specific failure.

There is no `--test-filter` wired through `build.zig`. To run a
single test, either invoke `zig test` on the file directly with the
same `linkSystemLibrary` flags, or add a temporary `b.option(...)`
filter to the `tests` step.

## Conformance suites

Ported suites, all reachable from both roots unless noted:

| File                                        | Covers                                    |
|---------------------------------------------|-------------------------------------------|
| `src/parser/conformance_test.zig`           | VT parsing, CSI/OSC dispatch              |
| `src/parser/screen_conformance_test.zig`    | Screen state after real sequences         |
| `src/parser/wezterm_conformance_test.zig`   | wezterm's CSI corpus                      |
| `src/parser/multicell_conformance_test.zig` | wide chars, clusters                      |
| `src/parser/graphics_conformance_test.zig`  | Kitty/sixel/iTerm2 image protocols        |
| `src/parser/clipboard_conformance_test.zig` | OSC 52 paths                              |
| `src/grid/selection_conformance_test.zig`   | selection semantics                       |
| `src/grid/reflow_screen_test.zig`           | reflow across width changes               |
| `src/grid/image_pipeline_test.zig`          | parse -> placement -> store               |
| `src/ui/input_conformance_test.zig`         | key encoding (GUI root only)              |

`src/parser/test_harness.zig` is the shared shape: build a Screen of
known size, feed bytes, assert on observable state and on the
response bytes the screen wrote back to the PTY. Mirrors kitty's
`parse_bytes_dump` pattern.

**Regression discipline**: a parser or grid bug that gets fixed
gains a test in the matching suite.

## Headless GL smokes

Each creates a surfaceless EGL context (no display server needed),
renders, and reads pixels back:

| Step                            | What it proves                                     |
|---------------------------------|----------------------------------------------------|
| `zig build smoke-image`         | ImagePass + ImageStore put the right pixels on screen |
| `zig build smoke-cell`          | the instanced cell pipeline                        |
| `zig build smoke-transparency`  | background alpha                                   |
| `zig build smoke-editor`        | the editor text pipeline                           |
| `zig build smoke-gl-core`       | every shader compiles under desktop GL 3.3 core, i.e. the macOS path, on a Linux box |

`smoke-gl-core` is the cheap guard for the rule that shaders carry
no `#version` line of their own: `gl.zig` injects one per API, and a
shader that hardcodes a version breaks exactly one of the two
platforms.

## Daemon and protocol end-to-end

| Step                       | What it drives                                        |
|----------------------------|-------------------------------------------------------|
| `zig build smoke-mux`      | daemon lifecycle, wire protocol, sessions; hosts the backlog / display / panel-relay / ticket sub-stages |
| `zig build smoke-broker`   | broker + per-session-worker process isolation, running the same sub-stages |
| `zig build smoke-udp`      | UDP transport and hole punching                       |
| `zig build smoke-fs`       | the mux file service                                  |
| `zig build smoke-fuse`     | the FUSE mount                                        |
| `zig build smoke-foreign`  | xdg-foreign cross-connection parenting                |
| `zig build smoke-mcp`      | MCP isolation and headless terminals                  |
| `zig build smoke-web`      | the CEF browser helper end to end                     |
| `zig build mux-portable`   | the musl cross-compile check for the daemon's dep graph |

`zig build smoke-web` needs the helper, which is opt-in:
`zig build fetch-cef` then `zig build web` first.

## GUI end-to-end

| Step                       | What it drives                                          |
|----------------------------|---------------------------------------------------------|
| `zig build smoke-e2e`      | the real GUI: input, panes, layout restore, panels, editor, cast playback, dead keys |
| `zig build smoke-lsp-gui`  | the real editor against a real language server          |
| `zig build smoke-atspi`    | terminal-pane accessibility on a private a11y bus       |
| `zig build smoke-a11y`     | macOS NSAccessibility round-trip (native macOS only)    |
| `zig build measure-web`    | browser latency and sharpness measurement               |

`smoke-e2e` runs with `SKETERM_VERIFY_TREE=1`, which cross-checks
the `Window.PaneTree` model against the GTK widget tree after every
mutation and aborts on divergence.

### Never Xvfb

**sketerm is its own display.** Do not use Xvfb, do not set
`GDK_BACKEND=x11`, do not reach for xdotool. X11 changes the code
under test: `GtkIMMulticontext` resolves to `GtkIMContextSimple`
there, so IM and dead-key behaviour under Xvfb is not the behaviour
on any Wayland compositor advertising `zwp_text_input_manager_v3`.
An Xvfb run of smoke-e2e once went green while dead keys were broken
everywhere real. Any input- or compositor-related result from an X
session is untrustworthy.

The replacement is an external display session:

```bash
sketerm-mux display create --name <n> --ttl <secs> --json \
    --socket <isolated mux.sock>
```

which returns `{session, environment:{WAYLAND_DISPLAY,
XDG_RUNTIME_DIR, PULSE_SERVER, LIBGL_ALWAYS_SOFTWARE}}`. Export
that to the GUI, set `GDK_BACKEND=wayland`, unset `DISPLAY`, and
never derive `wl-*` paths yourself. `src/smoke_e2e.zig` is the
worked example, and `src/ipc/appdrive.zig` gives clicks, keys,
screenshots and pixel diffs from Zig; `sketerm mcp`'s app tools give
the same interactively.

Two rig rules that cost real debugging time:

- **Attach a viewer BEFORE starting the GUI.** The compositor brain
  is client-side, so an unattended hub never configures the toplevel
  it is handed and nothing ever paints.
- **Isolate `XDG_CONFIG_HOME` / `XDG_STATE_HOME` and set
  `SKETERM_APP_ID`.** Otherwise prefs auto-save clobbers the real
  `config.conf` and GApplication uniqueness hands your test to a
  live instance.

Dead keys are covered end to end (`deadKeyStage`), using
`display create --kb-layout` for the session keymap and
`appdrive.App.tapKeyCodes` for raw evdev keycodes, because
`typeText` / `pressKey` map CHARACTERS and skip every dead keysym.

## Benchmarks and tools

Report-only, never gating:

```bash
zig build bench-parser        # parser microbenchmark
zig build bench-editor        # rope / document, large files
zig build bench-cell-upload   # cell upload, GL isolated from GTK
zig build replay -- cap.bin [cols rows]   # PTY bytes -> Screen dump
zig build spike-shell         # headless PTY/parser/screen smoke
```

`SKETERM_PROFILE=1` on a real run records per-pass render timings
(`src/util/profile.zig`).

## vttest

`pacman -S vttest`, then run it inside a sketerm pane. We do not
target full VT420. `docs/vttest.md` is the checklist of what we
expect to pass and what we knowingly do not; it is a manual gate,
not automated.

## Known flakes and traps

- The OCR (tesseract) tests can fail spuriously with leak warnings.
  Rerun once before diagnosing.
- A failed `smoke-e2e` run leaks processes that poison the next run,
  and the failures then cascade into unrelated stages. Clean up
  before re-running.
- **Never `pkill` / `killall` / `pgrep -f` on anything named
  "sketerm", including `pkill -x sketerm-mux`.** A by-name kill
  destroys the user's real daemon and their durable sessions. Kill
  test instances by exact pid; for a daemon, list read-only with
  `pgrep -x sketerm-mux` and kill only the pid whose
  `/proc/<pid>/environ` contains your isolated `XDG_RUNTIME_DIR=`.
- A detached daemon that re-exec'd via `/proc/self/exe` has comm
  **"exe"**, so `pgrep -x sketerm-mux` misses it. A stale test
  daemon can keep serving an old binary on its socket.
- Keep isolated socket paths SHORT (`sockaddr_un` caps at ~108
  bytes). A daemon under a deep scratch path fails to bind and the
  GUI silently autostarts the INSTALLED daemon instead.
- Warm `fc-cache` when isolating `XDG_*`, or GUI tests crash
  randomly inside pango/fontconfig.

## Not covered

- No CI: there is no workflow file and no `scripts/ci.sh`. The
  steps above are run by hand.
- No differential harness against another emulator; the conformance
  suites carry that role, statically.
- No fuzz build step. `src/editor/fuzz.zig` is the only fuzz driver
  and is invoked directly.
- No golden-image regression corpus; the render smokes assert on
  specific pixels instead.
- Cross-platform: macOS is compile-checked
  (`zig build mux-portable -Dportable-target=aarch64-macos`) and has
  `smoke-a11y`, but a green macOS build is not a working macOS
  build. Run the rigs.
