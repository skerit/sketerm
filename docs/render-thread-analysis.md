# Render-thread analysis (J)

**Status:** Analysis only. Deferred until profiling shows main-thread
CPU is actually the bottleneck on real workloads.

## Plan v3's J scope

> Move `cell_pass.rebuildRow` and `grid_pass.buildVertices` (CPU
> work) to a thread pool. Main-thread render: wait for the pool's
> per-pane future, upload the prebuilt instance buffer + draw.
>
> Two snapshots required:
> 1. Per-row generation counter on Line for snapshot consistency
> 2. Frame-snapshot of render config (palette, default_fg/bg, scheme,
>    dim factors)

## Cost / benefit

### CPU profile of the current main thread per frame

Measured by static analysis (no live profiler attached):

- `cell_pass.rebuildRow`: dirty rows only. Per row, walks `cols`
  cells, dereferences StylePool entry, populates one `Instance`
  struct (~64 B). Touches 80 cells × 64 B = 5 KB per dirty row.
- `grid_pass.buildVertices`: full rebuild every frame today (no per-
  row dirty bit on the overlay). For a typical 80×24 grid with no
  bidi rows it's near-empty (just selection / cursor / focus border
  / a handful of search highlights). For a 200×80 grid full of
  CJK / DW / DH it's ~16k vertices.

For the typical "one dirty row per keystroke" case, CPU work is
**bounded by ~10 KB/frame of memcpy + arithmetic** = microseconds.

### Hardware-bound scaling

The main thread's hot path on this hardware (NVIDIA RTX 3050 +
Mesa-zink + GTK4) sits well below the 16.6 ms / 60 Hz budget. We
have no measurement showing main-thread CPU as the latency
bottleneck.

A `cat huge.log`-style burst stresses the **parser** thread (worker
already off main) and the **screen apply** path, neither of which
benefits from moving buildVertices off main.

The case where moving buildVertices off main DOES help is the
**bidi-heavy / DW-heavy fullscreen redraw** — `grid_pass.buildVertices`
runs full-line for every overlay row. Even there, on this hardware
it's microseconds.

## Implementation cost

The plan's "two snapshots required" lists are correct but
incomplete. The actual interaction surface:

1. **`std.Thread.Pool`** — Zig has it; per-Pane Future tracking is
   straightforward. ~1 day.
2. **Per-row generation counter** on `Line`. Currently 0 fields
   for "version". Add `gen: u32` bumped in every `Line.clear`,
   `Line.copy`, mid-line edit, etc. Worker reads `gen` at start
   and at end of build; mismatch = bail + retry on main. ~1 day,
   but **every Line mutation site needs the bump**, and we have
   ~30 of them.
3. **Frame snapshot of render config**: not just palette + colors;
   also `scrollback_capacity`, `mouse_mode`, `view_offset`, dim
   factors, ligature/bidi flags, focused state, scheme name,
   selection state, search highlights, OSC 8 link table pointer.
   That's ~20 fields to capture atomically before kicking workers.
   ~1 day.
4. **Mid-build mutation retry policy**: when a worker bails, do we
   retry on main, retry on a different worker, or skip the frame?
   Each has consequences. ~1 day to design + test.
5. **Frame-clock coordination**: workers must finish before the
   GtkGLArea render callback runs. Either block-on-future on main
   (which serializes anyway and is no win) or trigger queue_draw
   from worker on completion (which races with the next frame
   clock tick). ~1-2 days.
6. **Per-driver / per-thread GL state**: GtkGLArea owns its GL
   context; workers don't share it. So the worker can't upload
   atlas glyphs (e.g. when buildVertices encounters a glyph not in
   the atlas, the current path uploads it inline). We'd need a
   "missing glyph" channel that defers the actual upload to main.
   ~2-3 days.
7. **Tests + smoke runners**: hard to test multi-threaded GL;
   regression risk is real. ~2 days.

**Total: 9-13 days of focused work** for a measurement-free win on
hardware that doesn't currently exhibit the bottleneck.

## Recommendation

Defer until one of these signals shows up:

- A user reports stuttering / dropped frames during heavy redraws
  on a target where CPU is plausibly the bottleneck (e.g. Pi 5).
- A profiler attached to a `cat huge.log` workload shows
  buildVertices as a top-3 hotspot.

In the meantime, lower-cost wins inside the current pipeline:

- **`I` persistent-mapped VBO** (gated off pending EXT-symbol
  fix). Removes driver-side staging copy. 1-2 days; bounded.
- **Per-row dirty bit on `grid_pass`** (today only `cell_pass`
  has one). Would let us skip rebuilding the overlay vbuf entirely
  on frames where nothing changed. ~1-2 days; isolated.
- **Frame-clock-aware throttling** of `screen.dirty` redraws so
  we don't issue queue_draw on every PTY drain. ~1 day; isolated.

Any one of these gets us a measurable win without the threading
risk. Recommended next step if perf becomes a concern.
