# Testing strategy

Per-module unit tests, parser golden fixtures, record/replay of
grid state against real byte streams, differential diffing against
Ghostty, fuzzing, and the `vttest` corpus with an expected-fail
list. Parser correctness is the top project risk
(`risks.md` R1); this document is how we contain it.

## Philosophy

- **Tests gate commits** on any module in the critical path
  (parser, grid, image decoders, layout).
- **Record/replay over synthetic inputs** — real shell output
  reveals corners synthetic tests don't.
- **Differential testing** against Ghostty catches spec
  ambiguities. Where a spec leaves a choice, we match Ghostty
  unless we have a written reason not to.
- **Fuzzing** targets bytes-in surfaces: VT parser, sixel
  decoder, Kitty parser, OSC base64, ZON layout loader.
- **No mocks for GL or GTK.** Render tests use an off-screen
  framebuffer; GTK widget tests use `gtk_init` in headless mode.

## Layers

### 1. Unit tests (Zig `test` blocks)

Every module has inline tests covering its public surface.

```bash
zig build test
```

Coverage target:
- `parser/`, `grid/`, `layout.zig`, `util/` — **80 %+**.
- `ui/`, `render/` — best-effort; integration catches what
  unit can't.

### 2. Parser golden fixtures

`tests/parser/` — inputs + expected event streams.

```
tests/parser/csi-cup/
├── input.bin          \e[10;20H
└── expected.txt       CsiDispatch [10,20] '' 'H'
```

`zig build test-parser` streams input through parser, serializes
events, diffs against `expected.txt`.

**Regression discipline**: every parser bug we fix becomes a new
fixture. The directory only grows.

### 3. Grid snapshot tests

`tests/grid/` — event streams → expected grid state.

```
tests/grid/scroll-region/
├── input.bin          (bytes exercising DECSTBM + scroll)
└── expected.snap      (text dump of cell grid)
```

Snapshot format:
- one ASCII char per cell (unprintable → `·`)
- `^` at cursor position
- `~` at wrapped-line tail
- `#` for image-bearing cells
- attribute runs annotated in a second block below the grid

### 4. Record/replay corpus

`tests/corpus/` — raw byte streams captured from real sessions.

| Fixture                 | What it exercises                          |
|-------------------------|--------------------------------------------|
| `bash-prompt.bin`       | 10 s idle bash prompt                      |
| `bash-history.bin`      | up/down history navigation                 |
| `vim-edit.bin`          | open, edit, `:wq`                          |
| `nvim-lsp.bin`          | nvim with live LSP diagnostics             |
| `htop-30s.bin`          | 30 s of htop                               |
| `less-large.bin`        | `less /var/log/messages` with PgDown       |
| `yazi-preview.bin`      | yazi with sixel thumbnails                 |
| `lazygit.bin`           | repo browse + staging                      |
| `kitten-icat.bin`       | kitty-icat PNG display                     |
| `chafa-sixel.bin`       | chafa sixel output                         |
| `imgcat.bin`            | iTerm2 OSC 1337 PNG                        |
| `resize-storm.bin`      | terminal with multiple SIGWINCH mid-draw   |

`zig build test-corpus` feeds each stream through parser+grid,
dumps final grid, diffs against golden snapshot.

Rationale: synthetic tests miss interactions (DECSTBM × DECOM ×
1049 cascades, mode-switch reflows, obscure CSI from less).
Real sessions catch these.

### 5. Differential testing vs. Ghostty

`zig build test-diff` — runs corpus through both emulators,
compares grid state.

Divergences fall in three buckets:
1. **Bug** — our parser/grid is wrong. Fix.
2. **Spec ambiguity** — both are legal per spec. Adopt Ghostty's
   behavior (tie-break toward larger ecosystem) and record the
   decision in `tests/diff/notes.md`.
3. **Intentional divergence** — we chose differently with reason;
   record in the same notes file.

Skipped automatically if `$GHOSTTY_BIN` is unset.

### 6. Fuzzing

Drivers in `tests/fuzz/`:
- `fuzz_vt.zig` — bytes → parser; assert no crash / no OOB.
- `fuzz_sixel.zig` — DCS bodies.
- `fuzz_kitty.zig` — APC bodies.
- `fuzz_iterm.zig` — OSC 1337 + base64.
- `fuzz_layout.zig` — mutated valid ZON.
- `fuzz_base64.zig` — util/base64.zig.

Ran via afl++ or `zig build fuzz-N` wrappers. Release gate:
1 hour per target, no crashes. Dev discipline: whenever a new
decoder lands, add a fuzz driver in the same PR.

### 7. vttest

`pacman -S vttest`. VT420+ tester; we don't target full VT420.

`tests/vttest-expected.txt` — explicit expected-fail list
(SCS, DECDHL/DECDWL, etc). CI gate fails only on unexpected
failures.

### 8. Performance benchmarks

`zig build bench` (report-only, does not gate):

| Benchmark          | Target                                     |
|--------------------|--------------------------------------------|
| Sustained output   | `cat /dev/urandom | head -c 100M` ≥ 20 MB/s |
| Cold start         | `time sketerm -c exit` < 300 ms            |
| Idle memory        | 3 tabs, 5 min idle, < 150 MB               |
| Sixel decode       | 512×512 RGBA ≥ 60 MB/s                     |
| Atlas glyph upload | < 0.5 ms per new glyph (amortized)         |

Baseline on Mesa (AMD/Intel). NVIDIA recorded separately.

## CI

`scripts/ci.sh` runs (in order):
1. `zig build test`
2. `zig build test-parser`
3. `zig build test-grid`
4. `zig build test-corpus`
5. `zig build test-diff` (skip if `$GHOSTTY_BIN` unset)
6. `tests/run-vttest.sh` (diff vs expected-fail)
7. `zig build bench` (report)

Pinned to the Zig version in `build.zig.zon`.

## Manual smoke (pre-release)

The "v1 daily driver for two consecutive weeks" criterion
(see `plan.md`) is the real integration test. Additional pre-release
smoke:

1. SSH into 3 different remote hosts; OSC 52 copy works from each.
2. `yazi` with sixel preview across 50+ files.
3. `kitten icat` with a large PNG (> 2 MB).
4. Resize the window rapidly for 30 s; grid stable; no GL errors.
5. Suspend (`Ctrl+Z`) + `fg` a shell; pane state recovers.
6. IME: input 20 Chinese characters via fcitx5; correct rendering.
7. Layout save/load with 3 tabs × 2 splits; all cwds and commands
   preserved.
8. `Ctrl+Shift+V` paste of 10 KB text; bracketed paste works.
9. Close 32 tabs in rapid succession; no leaks reported by GPA.

## Tree layout

```
tests/
├── parser/
├── grid/
├── corpus/
├── render/           # M0.5 baseline + image-pixel diffs
├── input/            # key-encoding fixtures (modifier tables)
├── clipboard/        # OSC 52 round-trip via headless GdkClipboard
├── diff/
│   ├── harness.zig
│   └── notes.md
├── fuzz/
├── bench/
├── vttest-expected.txt
└── run-vttest.sh
```

## M0.5 baseline

`tests/render/triangle-baseline.png` is the first artifact: the
colored triangle from the M0.5 spike, captured via framebuffer
readback. A hash of its pixel data is committed; M0.5's test passes
if the hash matches on the same driver family (Mesa baseline; other
drivers recorded per-platform).

Rationale: this is the first regression gate the project has.
Every subsequent render milestone (M3, M9a/b/c) produces more
baselines in `tests/render/`.

## Not tested in v1

- Cross-platform (Linux Wayland only).
- Accessibility APIs (AT-SPI) — post-v1.
- Full i18n suite (CJK smoke only).
- Multiple compositors (KWin 6 only; other compositors best-effort).
- Graphics-card diversity beyond "Mesa AMD/Intel baseline + one
  NVIDIA smoke".
