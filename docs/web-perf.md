# Browser performance tools (`web_perf`, `web_cpu_profile`, `cpu_throttle`)

Measuring a page from outside, through the engine's own DevTools protocol, so
no probe runs in the page it measures. Headless MCP tabs only (a GUI tab is
refused: its helper session belongs to the user). Helper capability
`web-perf`; `capabilities` reports `web_perf`, `web_cpu_profile` and
`web_cpu_throttle` (null before the helper handshake).

Scope: the main thread of the tab's renderer. Workers, service workers and
other processes are not covered.

## `cpu_throttle`

`Emulation.setCPUThrottlingRate`: 1 = off, up to 20. Accepted by `web_open`
(applied right after the view's first navigation starts, so the very first
scripts of that document may run unthrottled) and by `web_perf` /
`web_cpu_profile` (applied to the tab before measuring, and kept). The helper
re-applies it at every main-frame load, so it survives navigations, including
cross-origin ones that swap the renderer. Every perf result reports the rate
the helper says is ACTIVE (`cpu_throttle`), so two runs are never compared
across different rates unknowingly.

Measured (smoke-mcp stage wp): a fixed busy loop took 29.3 ms at 1x, 80.8 ms
at 4x, and 80.4 ms at 4x after a cross-origin navigation.

## `web_perf`

Two `Performance.getMetrics` samples and their difference; nothing runs in the
page. `duration_ms` (max 60000) measures that window; without it the window is
the time since the tab's previous `web_perf`, and the first call on a tab is a
`baseline:true` of totals since the DevTools agent attached (`window_ms` 0).
The key set never changes (it is `perf/metrics.zig`'s `Report`, which also
generates the output schema):

`baseline, window_ms, script_ms, style_ms, style_count, layout_ms,
layout_count, task_ms, main_thread_busy_pct, dom_nodes, dom_nodes_delta,
js_heap_used_bytes, js_heap_delta_bytes, event_listeners, frames, fps,
cpu_throttle`

`frames` is the number of paints the helper received for the view in the
window (a static page paints only on damage); `fps` is that over the window.
Both are null on a baseline. Counts such as `layout_count` and `dom_nodes`
belong to the current document, so a navigation inside the window can make a
delta negative.

Long tasks are NOT reported: the only passive source is a buffered
`PerformanceObserver('longtask')`, which would have to be installed in every
page before it is needed. Timer-lateness and mutation-rate probes are
deliberately absent: they disturb what they measure.

## `web_cpu_profile`

V8's sampling profiler (`Profiler.enable`, `setSamplingInterval`, `start`,
`stop`). `action:"start"` then `action:"stop"`, or `duration_ms` (max 120000)
for one call. `interval_us` defaults to 1000 (min 100). A second start is
refused; a forgotten profile is stopped by the helper at 120 s and handed to
the next stop. A stop reports how many main-frame loads happened while
profiling (`navigations`): a cross-process navigation swaps the renderer and
its samples end there; a profiler that is gone is reported as such, never as
an empty profile.

The raw profile never rides a wire frame: the helper writes it into a staging
file of its own (`cefhost.stagingFile`, the print-pdf staging path) and the
MCP server moves it to `save` (default: a temp file) after checking it is a
regular file inside the helper's staging root. A helper on another host
(`on:<host>` route) is therefore refused for `web_cpu_profile`; `web_perf`
and throttling work there.

The summary is computed in the MCP process by `src/ipc/perf/cpuprofile.zig`:
a sample lasts until the next one (DevTools' convention), self time is per
function (function, url, line, column; 1-based), total time counts a
function once per stack (recursion is not double-counted), and the
`(idle)`, `(program)` and `(garbage collector)` nodes become the `buckets`.
`self_pct` is the share of busy (non-idle) time. Frames of sketerm's own page
bridge (`sketerm://`, what carries a `web_eval`) are left out of the lists;
the raw file keeps everything.

Source maps (`source_maps`, default true) resolve only the listed functions.
The page fetches the script (its cookies, its route), only its `SourceMap` /
`X-SourceMap` header and last 8 KiB come back; the trailing
`//# sourceMappingURL=` (or `/*# ... */`) names the map, `data:` urls are
decoded locally, others are fetched by the page relative to the script url.
`source_map_files` (script url or url suffix -> local `.map` path) wins over
all of that and is the way past the 4 MiB page-eval budget. The decoder is
`src/ipc/perf/sourcemap.zig` (VLQ `mappings`, `sources`, `sourceRoot`,
`names`); index maps with `sections` are reported unsupported. A map without
`names` (TeaVM) still gives `source` and `source_line`. Every failure is per
function plus one `source_maps` line: `resolved N of M; <url>: <reason>`.

Example (smoke-mcp stage wp, a minified script with a hand-made map):

```
CPU profile 1609.95ms, 6144 samples, cpu_throttle 1x: script 1503.26ms, program 1.03ms, gc 0.26ms, idle 99.3ms
1. hot self 1498.38ms (99.6%) total 1498.38ms http://localhost:41997/app.min.js:1:13 -> src/app.ts:10 hotOriginal
```

## What attaches an agent

Nothing until a perf tool (or `cpu_throttle`, or media emulation) is used on a
tab; then that tab's ONE DevTools session (`cefhost/devtools_session.zig`)
stays attached for the life of its browser. `Runtime.enable` and
`Debugger.enable` are never sent: an attached inspector is what devtools
detectors measure, and smoke-web's dt stage fails a helper that attaches one
by default.

## The thread-stack fix this needed

`Profiler.start` first killed the renderer: V8's `CHECK(StartSynchronously())`
for its 64 KiB sampler thread. The helper binary carried a 256 KiB static TLS
block (Zig std's per-thread alternate signal stack, `std.Options.
signal_stack_size`), and glibc carves static TLS out of every thread's stack,
so any engine thread asking for a small stack failed to start. The helper now
sets `signal_stack_size = null` (`src/webengine.zig`); its TLS segment went
from 0x40018 to 0x18 bytes.
