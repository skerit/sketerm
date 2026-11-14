# Browser performance tools (`web_perf`, `web_cpu_profile`, `web_trace`, `cpu_throttle`)

Measuring a page from outside, through the engine's own DevTools protocol, so
no probe runs in the page it measures. Headless MCP tabs only (a GUI tab is
refused: its helper session belongs to the user). Helper capabilities
`web-perf` and `web-trace`; `capabilities` reports `web_perf`,
`web_cpu_profile`, `web_cpu_throttle` and `web_trace` (null before the helper
handshake).

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

## `web_trace`

The engine's own performance trace (`Tracing.start`/`Tracing.end` on the
tab's DevTools session), summarized for an assistant and kept raw for DevTools
or Perfetto. `action:"start"` then `action:"stop"` to bracket an action, or
`duration_ms` (max 30000) for one call. A second start is refused; a
forgotten trace is ended by the helper at 30 s and handed to the next stop. A
CPU profile may run at the same time (the rig runs one alongside): the trace
does not record V8 samples, so the two do not share a profiler.

Category preset (fixed, `cefhost/trace.zig`): `devtools.timeline`,
`disabled-by-default-devtools.timeline`, `...timeline.frame`,
`...timeline.stack` (the JS stack of a forced style/layout), `v8.execute`,
`v8`, `blink.user_timing`, `toplevel`, `__metadata`. `selector_stats:true`
adds `disabled-by-default-blink.debug`, which records every selector's match
cost in every style recalc and is therefore opt-in. The V8 sampler
(`disabled-by-default-v8.cpu_profiler`) is deliberately absent: that is
`web_cpu_profile`'s job.

Collection: the helper writes `{"traceEvents":[` into a staging file and
appends each `Tracing.dataCollected` chunk's events as it arrives, so it never
holds a trace in memory; `Tracing.tracingComplete` closes the array. The
result of `Tracing.end` itself never arrives on this engine, so nothing waits
on it. Past 256 MiB the helper stops collecting, ends the trace and reports
`truncated:true`; an engine that never reports completion within 60 s also
yields a closed, `truncated` file of what had arrived. The file is moved to
`save` like a profile (local helper only).

The summary (`src/ipc/perf/trace.zig`) streams the file twice and never loads
it: pass one finds the tab's renderer (the `processId` of the outermost main
frame in `TracingStartedInBrowser`, plus any `FrameCommittedInBrowser` of that
frame after a cross-process navigation) and its `CrRendererMain` thread; pass
two keeps that thread's events. Another tab's renderer never counts (the rig
keeps a second site busy to prove it). One key set, always present:

- `window_ms`, `events`, `bytes`, `truncated`, `navigations`, `trace_path`,
  `cpu_throttle`.
- `main_thread`: `task_ms` (all `RunTask`s), then SELF time of script
  (`FunctionCall`, `TimerFire`, `EvaluateScript`, `RunMicrotasks`, ...),
  style (`UpdateLayoutTree`), layout (`Layout`), paint and gc (`MinorGC`,
  `MajorGC`), with style and layout counts. `source` says how the thread was
  found.
- `long_tasks`: tasks of 50 ms or more, longest first, with the start offset
  and the dominant cause. For `script` the named function is the heaviest JS
  ENTRY in the task (the function the engine called: a timer callback, an
  event listener), since without the sampler the trace records no deeper
  frames.
- `forced_reflows`: style and layout that ran inside JS, grouped by the frame
  on top of the stack the engine records for it (`beginData.stackTrace`), else
  the enclosing JS entry.
- `selector_stats`: `SelectorStats` events summed per selector and sheet;
  `style_sheet` is the engine's sheet id, not a url (the trace gives none).
- `frames`: `DrawFrame`s of the tab's renderer; a static page draws only on
  damage, so this is frames drawn, not a frame rate. Dropped frames are not
  reported: the engine's `PipelineReporter` marks frames `STATE_DROPPED`
  even on an idle static page.
- `user_timing`: `performance.mark` (instant events) and
  `performance.measure` (async pairs) on the main thread; the engine's own
  navigation marks in that category (`R` events) are left out.

Lines and columns are 1-based as the trace writes them. `source_maps` and
`source_map_files` resolve the forced-reflow frames and the long-task causes
through the same resolver as `web_cpu_profile`.

Example (smoke-mcp stage wt, `SKETERM_SMOKE_MCP_WEBTRACE_ONLY=1`):

```
trace 827.5ms, 1501 events, cpu_throttle 1x: tasks 219.97ms, script 203.8ms, style 2.35ms (41x), layout 5.65ms (41x), paint 2.7ms, gc 0ms; raw trace at .../run.trace.json
<long_tasks>
1. 200.35ms at +70.03ms script slow http://127.0.0.1:45901/trace.min.js:2:14 -> src/trace.ts:15 slowOriginal
</long_tasks>
<forced_reflows>
1. 80x 5.04ms (40 style, 40 layout) thrash http://127.0.0.1:45901/trace.min.js:1:118 -> src/trace.ts:5 thrashOriginal
</forced_reflows>
<selector_stats>
1. 0.06ms attempts 200 matches 0 .card:has(> .needle-zz9) (style-sheet-3366157-1)
</selector_stats>
```

An older `web-perf` helper does not advertise `web-trace`; the client refuses
`web_trace` before sending anything (an op the helper does not know would be
answered `unknown perf op`, never left hanging).

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
