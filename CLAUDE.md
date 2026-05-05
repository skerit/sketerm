# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`sketerm` — native GTK4 terminal emulator written from scratch in Zig. No vendored terminal cores, no wrapper crates: parser/screen/atlas/render are all in-tree. Dependencies are system C libraries (`gtk4`, `libadwaita-1`, `freetype2`, `harfbuzz`, `epoxy`, `fribidi`, `fontconfig`) plus vendored `stb_image.h` for PNG decode.

## Toolchain pin

Zig **0.15.2**. The default optimize mode is `ReleaseFast` because **`Debug` builds fail to link on Arch + gcc 15** — Zig's bundled LLD can't handle gcc 15's `.sframe` section in `crt1.o`. Use `-Doptimize=ReleaseSafe` if you want bounds/overflow checks while developing.

`use_lld = true` is set on every artifact for the same reason: the self-hosted linker chokes on `crt1.o`'s SFrame relocs.

## Build / run / test

```bash
zig build                       # main binary at zig-out/bin/sketerm
zig build run -- [args]         # build + run with optional CLI args
zig build test                  # full test suite (currently 408 tests)
zig build test --summary all    # show test count + timings
zig build spike-gl              # GL share-group + driver-info spike
zig build spike-shell           # headless PTY → parser → screen smoke
zig build bench-parser          # parser microbenchmark
zig build smoke-image           # headless GL image render
zig build smoke-cell            # headless GL cell-pipeline render
zig build smoke-transparency    # headless GL bg-alpha render
```

Tests are discovered via `src/tests.zig`, which `_ = @import(...)`s every module containing `test` blocks. **When adding a new test file, add it to `src/tests.zig`** or `zig build test` won't pick it up.

There's no `--test-filter` wired through `build.zig`; to run a single test, either invoke `zig test src/path/to/file.zig` directly with the same `linkSystemLibrary` flags, or add a temporary `b.option(...)` filter to the `tests` step.

## Architecture (read `docs/architecture.md` for full detail)

**Events, not callbacks, parser → grid.** One PTY worker thread per pane parses bytes into a tagged-union `Event` and pushes to a lock-free SPSC ring. The main thread drains the ring under GLib's main loop, applies events to `Screen`, and queues a redraw.

**Cross-thread wakeup is coalesced via a per-Terminal `drain_pending: Atomic(bool)`.** Worker swaps it `true`; only the worker that observes the false→true transition calls `g_main_context_invoke(mainDrainEvents, term)`. Main-thread drain stores `false` *before* draining so the worker reschedules if it pushes during the drain. This guarantees one wake-up per drain cycle, regardless of event volume.

**Threading rule:** all GTK/GDK/GL/Screen/ImageStore state lives on the main thread. The PTY worker only touches its PTY fd, parser state, ring producer, and shutdown eventfd. Never call GTK from a worker.

**`Cell` is `extern struct`, 8 bytes flat.** Heavy data (OSC 8 links, images, multi-codepoint clusters, styles) lives in side tables on `Screen` (`StylePool`, `links`, `clusters`, `cell_images`). `comptime` asserts pin the size at 8.

**One `GtkGLArea` per pane; share-group at the window level.** Atlas lives on `Window`, reachable from every pane's GL context. **Reparenting unrealizes the `GtkGLArea` and destroys its `GdkGLContext`** — `Pane.onRealize` therefore treats every realize as potentially a re-realize: `Atlas.deinit`, then `forgetGL()` on `GridPass`/`ImagePass`/`ImageStore` so the realize path rebuilds against the fresh context. Without this, cached non-zero shader IDs from a dead context cause silent black renders.

**Tab/pane tree is plain Zig data; GTK widgets are the view.** Layout persistence (`layout.zig`) serializes the tree to JSON; widgets rebuild from the tree on load. Saved at shutdown to `$XDG_STATE_HOME/sketerm/last.json`; restored via `--restore` or `--layout <path>`.

**CSI handling is split.** `Screen.csi()` is a small dispatcher that routes by `params.private` to `csiPrivate` (`?`), `csiAux` (`>`), `csiKittyKbd` (`=`/`<`), or `csiPublic`. Don't fold logic back into one giant function.

**Helpers worth knowing.** `cast.userData(T, user)` in `src/util/cast.zig` collapses `@ptrCast(@alignCast(user.?))` for GTK callbacks. `style.colorToVec` / `style.colorToRGBA` in `src/render/style.zig` are the shared color-resolution path used by both `cell_pass` and `grid_pass` — don't copy that logic into a third place.

## Memory ownership

- All long-lived state via the app `GeneralPurposeAllocator`.
- Per-worker `ArenaAllocator` reset once per ring drain for transient parse payloads.
- GTK signal contexts allocated on the heap (`*Ctx` types) **must** carry their own `allocator: std.mem.Allocator` and pass a matching `freeXxxCtx` callback as `g_signal_connect_data`'s 5th arg. The pattern is in `menu.zig` (`freeActionSlot`, `freeClickCtx`), `window.zig` (`PanedRatioCtx`/`freePanedRatio`, `RenameCtx`/`freeRenameCtx`), and every `add*Row` builder in `prefs.zig`. Skip the destroy-notify only when the user-data is the dialog's main `Ctx` (managed elsewhere) or is a non-heap pointer.

## Commit style

Gitmoji + scope + short subject (≤70 chars), then a 2-3 line body explaining why. Examples from `git log`:
```
🐛 prefs: free row-builder signal contexts via GDestroyNotify
♻️ render: extract shared color resolution into style.zig
✨ goto_tab_1..9 actions (Alt+1..9)
📝 SESSION: log goto_tab_1..9
```
`🐛` bug fix · `✨` feature · `♻️` refactor · `✅` tests · `📝` docs/SESSION

`docs/SESSION.md` is a running log of what's landed; many `📝 SESSION:` commits update it after a feature commit. Keep that pattern when adding sizable features.

## Packaging

`dist/PKGBUILD` builds the locally-checked-out repo (no remote source). Run `cd dist && makepkg -si`. The `.desktop` file lives at `data/dev.sker.sketerm.desktop`; the icon at `data/icons/hicolor/scalable/apps/dev.sker.sketerm.svg`. Terminfo source at `terminfo/sketerm-256color.src` — `tic`-compiled into `/usr/share/terminfo` by the PKGBUILD.

## License

MIT (see `LICENSE`).
