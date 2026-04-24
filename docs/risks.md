# Risks

Risks rated by likelihood and impact on v1 shipping. Each has a
concrete mitigation.

## High impact

### R1 — VT parser correctness

**Likelihood:** medium · **Impact:** high

A subtly wrong parser breaks everything above it. Bugs often
surface only with obscure tools (old `less`, `nano`, `vim` with
specific plugins).

**Mitigation**
- Start from Paul Williams' spec, not a casual rewrite.
- Test fixtures: `vttest` + captured real-session byte streams
  from bash/zsh, vim/nvim, htop, less, tmux's inner pipes, yazi,
  lazygit.
- Record/replay harness: byte stream → parser → grid → snapshot;
  snapshot diffs gate commits in that module.
- Differential testing: run the same corpus through Ghostty and
  sketerm; compare grid state. Diffs are either bugs in ours or
  spec ambiguities where we can choose.

### R2 — Sixel edge cases

**Likelihood:** high · **Impact:** medium-high

Sixel has DEC-era ambiguities: aspect ratios, color-register
inheritance, background semantics, private vs shared palette.
Real emitters (chafa, yazi, img2sixel) exercise different corners.

**Mitigation**
- Implement the subset chafa and yazi emit first. Treat other
  DEC-specific modes as best-effort.
- Test corpus from libsixel + foot + our own generated samples.
- Fuzz the decoder with synthetic inputs.
- Read foot's `sixel.c` before writing ours; it's the cleanest
  reference.

### R3 — GTK main-loop starvation

**Likelihood:** medium · **Impact:** medium-high

`cat large_file` can flood events faster than the main thread
applies them. If worker blocks on ring-full, PTY blocks, shell
blocks — usually fine. But pathological cases make the UI feel
stuck.

**Mitigation**
- Measure target: sustained 20 MB/s throughput, UI responsive.
- Coalesce events: consecutive `Print`s merge; consecutive CSI
  for overlapping ops collapse.
- Rate-limit redraws to the GTK frame clock — one redraw per
  frame no matter how many events drained.
- Profile with `cat /dev/urandom | head -c 100M` as stress test.

### R4 — Zig pre-1.0 language / stdlib churn

**Likelihood:** high (ongoing) · **Impact:** medium

Zig syntax and stdlib move between releases. Recent churn:
allocator API shape, `ArrayList` reorganization, async removal/
rewrite. Mid-project upgrades can break large swaths.

**Mitigation**
- Pin toolchain version in `build.zig.zon`.
- Upgrade deliberately between milestones, never within one.
- Local CI script runs against pinned version on every commit.
- Budget ~1 week per Zig version bump during the project's
  lifetime. A 6-8 month v1 likely spans 2 upgrades.

### R5 — NVIDIA proprietary driver + GTK4 + Wayland

**Likelihood:** medium (author's hardware may differ) · **Impact:** medium-high

Historically `GtkGLArea` on Wayland with NVIDIA proprietary has
had stuttering, occasional context loss, swap anomalies. Mostly
fixed by Wayland explicit sync, which shipped across the stack
in 2024-2025.

**Mitigation**
- Target NVIDIA driver ≥ 555, KWin ≥ 6.2 (explicit sync), GTK ≥ 4.16.
- Test on NVIDIA hardware before declaring v1 done (beg/borrow/VM).
- Emergency fallback: XWayland via `GDK_BACKEND=x11`. Documented
  in README as a known-issue escape hatch.
- Document minimum supported stack; users below it get a gentle
  startup warning.

### R6 — Fractional scaling on Plasma 6 Wayland

**Likelihood:** high (KDE default) · **Impact:** medium

Four pixel spaces coexist (logical widget / physical framebuffer
/ font raster DPI / cell metrics). Four places to get it wrong,
one to get right.

**Mitigation**
- `docs/gpu.md` documents the discipline.
- M0.5 GL triangle spike exercises the scale path with trivial
  content before any grid work.
- Test at 1.0×, 1.25×, 1.5×, 2.0×.
- Unit tests for cell-metric computation given mock scale.

## Medium impact

### R7 — Kitty graphics protocol complexity

**Likelihood:** medium · **Impact:** medium

Many edge cases: chunked transmit with fragment loss, placement
IDs colliding across images, z-index with cells, delete-variant
combinations.

**Mitigation**
- Implement baseline (direct transmit + simple placement) first.
- Read Kitty's source closely before writing the commands table.
- Disable `t=t` (temp file) and `t=s` (shared memory) in v1 per
  `docs/images.md`.
- Unit-test every delete variant.

### R8 — GTK4 Zig FFI friction

**Likelihood:** medium · **Impact:** medium

GObject wants `G_DEFINE_TYPE` macros and dynamic vtables. From
Zig we do the underlying `g_type_register_static` / `g_signal_new`
calls manually. Mistakes are silent.

**Mitigation**
- Ghostty has solved this pattern — read its current `src/apprt/gtk/`
  before first widget subclass.
- Fractal (Rust + GTK4) shows idiomatic subclassing which maps 1:1
  to our manual Zig FFI.
- Test: subclass `GtkBox` as a throwaway; confirm `GtkInspector`
  recognizes the type.
- Subclass only when necessary — `GtkGLArea` for panes, everything
  else composes stock widgets.

### R9 — OpenGL context per pane cost

**Likelihood:** low · **Impact:** medium

Each `GtkGLArea` owns a `GdkGLContext`. 20+ panes means 20+
contexts. GPU memory for per-context state could bite.

**Mitigation**
- Atlas shared per-window via share group (`docs/gpu.md`).
  Only per-pane VBOs are duplicated (small).
- Soft limit: ~32 panes. Above, consolidate to one GLArea +
  viewports — post-v1.

### R10 — OSC 52 read as a security footgun

**Likelihood:** low attack · high annoyance · **Impact:** medium

Malicious SSH output can emit `OSC 52 ; ; ? BEL` to exfiltrate
clipboard contents. Default-deny is correct; prompting every
session is annoying.

**Mitigation**
- Default-deny reads.
- Per-pane-session opt-in prompt on first read.
- Write-only OSC 52 always allowed (low-risk direction).
- 1 MB payload cap on writes (DoS protection).

### R11 — wcwidth disagreements

**Likelihood:** high · **Impact:** medium

No two terminals and no two libc wcwidth implementations fully
agree on widths of emoji, pictographs, extended grapheme clusters.
Shell (zsh/fish) runs its own wcwidth; sketerm runs its own;
they disagree; cursor ends in wrong column.

**Mitigation**
- Generate width table from a specific Unicode version; pin it.
- Match what recent WezTerm / Kitty use (they've converged on a
  subset that works).
- Document the Unicode version in terminfo / config so shells that
  respect `$TERM_VERSION` can align.
- Post-v1: consider emitting a width-query response per xterm's
  XTGETTCAP or Kitty's width-query extension.

### R12 — IME on Wayland is materially harder than "just wire it"

**Likelihood:** medium · **Impact:** medium

`GtkIMMulticontext` works but `text-input-v3` protocol behavior
varies across fcitx5/ibus/compositor versions. Preedit positioning
inside a GL-rendered grid is not automatic — we must position the
preedit popup at the cursor in widget coords.

**Mitigation**
- Allocate real time in M4 (estimate updated from 3-4d to 6-8d).
- Test with fcitx5 and ibus both, with at least two input methods
  (pinyin, Japanese).
- Read Ghostty's IME handling for the positioning pattern.

## Medium-low impact

### R13 — ZWJ emoji as known v1 rough edge

**Likelihood:** certain · **Impact:** low-medium (cosmetic)

Family emoji (👨‍👩‍👧), skin-tone modifiers, flag sequences —
all use ZWJ clusters. v1 has no HarfBuzz; they render as separate
glyphs with wrong widths.

**Mitigation**
- Documented in `plan.md` non-goals.
- Width table approximates ZWJ sequences as width 2 (same as the
  base emoji); cursor columns will be wrong but not by much for
  common cases.
- HarfBuzz shaping is a post-v1 item; sets up the fix.

### R14 — D-Bus / xdg-desktop-portal integration expectations

**Likelihood:** medium · **Impact:** low

On Plasma 6 users expect: desktop notifications via xdg-portal,
file dialogs via portal, icon/desktop-file registration, possibly
KRunner / krunner-activities integration.

**Mitigation**
- Ship a `.desktop` file + app icon in M0.
- `AdwApplication` handles the portal integrations automatically
  via GIO — we just use standard GTK APIs (file chooser, URI
  launcher, notifications).
- No custom D-Bus service in v1.

### R15 — FreeType font-load latency

**Likelihood:** low · **Impact:** low

`FT_New_Face` on a large .ttf can cost ~50 ms. Cold-start target
is 300 ms; this leaves margin.

**Mitigation**
- Lazy-load glyph ranges; pre-cache Latin-1 + common punctuation.
- Load font synchronously on startup; cache `FT_Face` for session
  lifetime.

### R16 — Clipboard async races

**Likelihood:** low · **Impact:** low

`gdk_clipboard_read_text_async` is callback-based. User typing
during paste completion could surprise.

**Mitigation**
- Serialize paste through the PTY-write queue.
- Reject concurrent paste initiation.
- Bracketed-paste markers let the shell handle internal races.

### R17 — vttest over-strict gatekeeping

**Likelihood:** medium · **Impact:** low

vttest covers VT320-era features we deliberately don't support
(SCS, DECDHL/DECDWL). Green gating would block otherwise-ready
releases.

**Mitigation**
- Maintain explicit expected-fail list.
- Gate on complement only.

### R18 — Zig GObject FFI signature drift

**Likelihood:** low · **Impact:** medium

GObject's `GCallback` signatures are specified per signal. We match
them via Zig's `callconv(.C)` function pointers. Silently wrong
signatures compile cleanly but crash at signal dispatch (stack
corruption or segfault during emission). GLib / GTK ABI additions
between versions can introduce new signal shapes.

**Mitigation**
- Define callback prototypes against a pinned GTK version matched
  in `build.zig.zon`.
- Wrap signal connections in a small typed helper (`connect_T`)
  that derives the prototype from the signal name at comptime.
  Once infrastructure is in place, adding signals stays typed.
- When upgrading GTK, run the full manual-smoke suite from
  `docs/testing.md` — signal mismatches surface as crashes, not
  compile errors.

## Posture summary

No single risk is fatal. Profile is "many medium risks, each with
a known mitigation." Ambitious but bounded — no unsolved
computer-science problems; just discipline, references, time.

Notable high-likelihood items to plan explicit calendar time for:
- R2 sixel edge cases (M9b — allocate full 10 d)
- R4 Zig upgrades (budget 2 weeks across project lifetime)
- R6 fractional scaling (M0.5 + M3 — test at 1.0, 1.25, 1.5, 2.0)
- R11 wcwidth (pick Unicode version early; document)
- R13 ZWJ emoji (document as known rough edge; plan post-v1 fix)
