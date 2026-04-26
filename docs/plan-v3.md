# sketerm plan v3

Drives the next push: medium UX wins → big UX features → niche-but-iconic
→ perf. All milestones in plan-v2.md and the small-win + titlebar +
inactive-dim batches are already shipped.

Reordered after review: **A → C → B → D → E → F → G → H → I → J → K**.
Rationale per item.

**Backend assumption:** Wayland is the reference target. X11 is
best-effort; behaviour differences are documented per item.

## A — Confirm-on-close (~1.5-2 h)

**Why first:** smallest, easiest, prevents data loss, builds momentum.

- Config: `confirm_close: enum { never, multiple, always } = .multiple`
  (matches Terminator's `ask_before_closing` semantics).
- Window-level `close-request` handler on `app_window`. Show a
  **`AdwAlertDialog`** (libadwaita 1.5+; check at runtime, fall back
  to `GtkAlertDialog` if missing) docked into the window.
- AdwTabView: connect `close-page` signal. **Always return
  `GDK_EVENT_STOP` (= TRUE) to signal async handling**, then
  `adw_tab_view_close_page_finish(view, page, accept)` after the
  dialog resolves. Do not return FALSE conditionally — that races.
- Prefs UI: combo row in Window page (Never / If multiple / Always).

## C — Transparency + blur (~3-5 h, was ~3-4 h)

**Why second:** focused 1-day item with clear acceptance. Front-load.

**Day-1 spike before any wiring**: confirm that `GtkGLArea` actually
composites with non-1.0 alpha on Adwaita + Wayland. `gtk_gl_area_set_has_alpha`
was removed in GTK4; the framebuffer is RGBA but bugs have shipped
(kgx hit them historically). If the spike fails: document and skip
this item. If it passes:

- Config: `background_opacity: f32 = 1.0` (clamped 0..1).
- Wire alpha into `default_bg[3]`; `cell_pass` already passes
  `a_bg.a` through to fragment.
- `gdk_surface_set_opaque_region(surface, NULL)` so compositor blends.
- Set `glClearColor` with the actual `default_bg.a`, not 1.0.
- **Drop the KWin blur claim**: `_KDE_NET_WM_BLUR_BEHIND_REGION` is
  X11-only. On Wayland, KWin uses the `org_kde_kwin_blur` protocol,
  which GTK4 doesn't expose. Document as "blur is the user's
  responsibility via compositor window rules."
- Prefs UI: spin row 0..1 step 0.05 in Appearance > Background.
- New `smoke-transparency`: spawn window with `bg_opacity=0.5`,
  read pixels via `glReadPixels` from the smoke runner, assert
  alpha < 1.0 in the cell area. Otherwise transparency regressions
  ship silently.

## B — URL auto-link (~4-5 h, was ~2-3 h)

**Why now:** depends on per-row scan that's bounded; hover handling
is the time sink.

- Hand-rolled URL matcher: scan visible cells for `http://` /
  `https://`, consume URL-allowed chars (`A-Za-z0-9._~:/?#[]@!$&'()*+,;=%-`)
  until whitespace/non-URL. Trim trailing punctuation (`.,;:?!`).
- Cache `(row, col_start, col_end, uri)` per row; invalidate on dirty.
  Skip rows that already have OSC 8 hyperlinks at the same range.
- **Render: emit underlines via grid_pass (NOT cell_pass attribute
  mutation).** The cell_pass dirty-row coalescing logic doesn't
  cope with per-frame attribute injection. grid_pass already does
  per-frame line drawing — add a "URL underlines" call there.
- Hover: `onMotion` looks up the cell, finds matching URL match,
  swaps cursor to "pointer". Throttle: only update on cell change.
- Click: `onDragEnd` (we already do Ctrl+click for OSC 8) — same
  path, fall back to URL match if no OSC 8 link on the cell.
- Honour `link_single_click`; otherwise Ctrl+click.
- Config: `auto_url_detect: bool = true`. Off skips the per-row scan.

## D — Quake mode (~4-6 h, was ~3-4 h)

**Why now:** Wayland constraints make this more involved than expected.

- `main.zig` activation refactor: switch flags to
  `G_APPLICATION_HANDLES_COMMAND_LINE`, add a `command-line` signal
  handler that parses `--toggle`. Also register a `toggle` GAction
  on the application so D-Bus clients can call it directly.
- Single-instance via `g_application_register`. Second instance with
  `--toggle` sends the action and exits.
- **Toggle hides via `gtk_window_minimize`, NOT `gtk_widget_set_visible(false)`.**
  Hiding destroys the GdkSurface → re-realize on show → GL context
  loss → atlas rebuild → cold-start flicker. Minimize keeps GL alive.
- Optional config: `hide_on_lose_focus: bool = false`.
- Document: user binds the keystroke at compositor level (KWin
  Custom Shortcuts; GNOME Settings → Keyboard).
- **Caveat (Wayland):** `gtk_window_present` honours focus-stealing
  prevention. On KWin Wayland, an unfocused-app raise may not steal
  focus. Document; not a sketerm bug.

## E — Custom keybindings (~12-16 h, was ~6-8 h)

**Why now:** biggest user-visible win; F (profiles) prefs UI builds
on E's rebind plumbing.

**Action enum extension first.** `input.zig::dispatchShortcut`
currently inlines work for shortcuts that are NOT in `Action`:
`paste_clipboard` (line 254), smart-copy interrupt / `interrupt`
(line 262), `clear_and_scrollback` (line 287). Before any binding
table swap, extend the enum to cover **every** shortcut so the
behaviour can move to data:
- `paste_clipboard, paste_primary, copy_selection, smart_interrupt`
- `clear_and_scrollback, scrollback_page_up, scrollback_page_down`
- `scrollback_home, scrollback_end, scrollback_line_up, line_down`
- `select_all, search_next, search_prev, search_close`

After that:

- Defaults table: `[]const struct { action: Action, accel: []const u8 }`.
- Config: `keybind.<action> = <accel>` per action; empty unbinds.
  `keybind.<action> = reset` restores default.
- Parse via `gtk_accelerator_parse(accel, &keyval, &mods)` at config-
  load. Cache as `[]struct { keyval: u32, mods: u32, action: Action }`,
  sorted for fast match in `onKeyPressed`.
- Conflict detection at parse time: warn (not error) on collision
  via stderr.
- Prefs UI: one row per action. Click-to-rebind GtkButton showing
  current accelerator. On activate, swap the button into a transient
  "press a key…" mode via `GtkEventControllerKey`; capture the next
  press, validate, update. Esc cancels; Backspace clears; conflict
  banner if the new combo collides with another action.
- "Reset to defaults" per row + "Reset all" at the page.
- Test harness: synthesize `GdkEvent`s for each binding, assert the
  right `Action` fires (no live GTK; mock the controller path).

## F — Profiles (~16-24 h, was ~6-8 h)

**Why now:** biggest architectural item; benefits from E's rebind
plumbing for a dialog-driven editor.

**Architectural prerequisite:** rewrite `applyConfigChange`
(`window.zig:1036-1156`) from a flat `for each pane: pane.X = config.X`
loop into an `EffectiveConfig.from(pane, window).apply(pane)`
resolver. The resolver picks per-pane fields from
`pane.profile orelse window.config`. The function gets fully
rewritten — its 100-line body is the actual surface area.

- New struct `Profile`: per-pane subset (font, palette, scheme,
  default_fg/bg, cursor_*, scrollback, shell, term/colorterm,
  login_shell, exit_action, bracketed_paste, modify_other_keys,
  word_chars, ligatures, bidi, allow_bold, bold_is_bright,
  line_pad_px, padding, bell_*).
- Config additions:
  - INI section support in `config.zig` parser. `[profile.name]`
    starts a profile block; flat keys above the first section
    remain global. **Round-trip test mandatory** — hand-edited
    configs must not lose data on dialog save. Preserve unknown
    keys + unknown sections.
  - `default_profile: []const u8 = ""`.
- Pane: `active_profile: ?[]const u8 = null`.
- Spawn paths (`newShellTab`, `splitFocused`, layout restore) accept
  `profile_name: ?[]const u8`.
- Layout v3 schema: each pane gains `"profile": "name"`.
  Backwards-compat: missing field = global config (current behaviour).
- UI:
  - Right-click menu → "New tab as…" / "Split horizontal as…" /
    "Split vertical as…" submenus listing profile names.
  - Prefs page "Profiles": combo to pick the editing target;
    fields below mirror the global pages but bound to the profile.
  - "Add" / "Remove" / "Duplicate" / "Set default" buttons.
- Prefs serializer round-trip property test before merging.

## G — Pane groups + broadcast typing (~5-6 h, was ~4-5 h)

**Why now:** Terminator-iconic; benefits from F's per-pane state
infrastructure.

**Critical: separate writeReply from writeUserInput.**
`pty.writeAll` has 4 caller categories — only user keystrokes
should broadcast:
1. `terminal.zig::sinkWritePty` — parser response channel (DA, DSR,
   OSC 52, kitty kbd reports). **MUST stay per-pane.**
2. `clipboard.zig` paste path — Terminator broadcasts paste; we'll
   do the same when broadcast is on, configurable.
3. `input.zig` smart-copy interrupt / Ctrl-C fastpath — broadcastable.
4. `input.zig::onCommit` + key encoding — broadcastable.

Implementation: add `Terminal.writeReply(bytes)` (direct, parser
replies) and `Terminal.writeUserInput(bytes)` (routed through
Window's broadcast filter). Update `sinkWritePty` to call writeReply.

- Pane: `group: ?[]const u8 = null`.
- Window: `groupsend: enum { off, group, all } = .off`.
- Window's `broadcastBytes(source, bytes)` receives user-input,
  fans out per `groupsend`.
- input.zig `Ctx.broadcast_sink` callback; if set, replaces direct
  `pty.writeUserInput`. Else still direct.
- Mouse selection while broadcasting: do NOT broadcast mouse
  events (they're position-relative, meaningless across panes).
  Document. Decide: if broadcast on `.all`, does Ctrl+Shift+C
  copy from the focus pane only? Yes — copy is read-only.
- UI:
  - Keybind: `Ctrl+Shift+G` toggle (off → group → all → off).
  - Visual: titlebar gains a `broadcast` CSS class when active;
    icon at the right edge.
  - Group label inline-editable on the titlebar (click to edit).

## H — SIMD UTF-8 decoder (perf, ~6-8 h)

**Why before I:** parser is independent and isolated; mergeable
without touching render. Banking SIMD wins is risk-free.

- Existing `advance()` SIMD-scans for printable runs (ASCII fast
  path). Add a vectorized UTF-8 validator + decoder for the bulk-
  print path so multi-byte runs go straight to u32 codepoints.
- Reference: simdutf's algorithm (re-implement in Zig).
- Fall back to per-byte decoder for partial sequences.
- New bench-parser case: pure-UTF-8 prose (Greek, Cyrillic, CJK).
  Target 5×+ on those workloads.
- **Differential fuzzer** before merging: random + adversarial byte
  streams (overlong, surrogate halves, truncated tails) compared to
  `std.unicode.utf8Decode` cell-by-cell. One bad run breaks every
  CJK user.

## I — Persistent-mapped cell VBO (perf, ~6-8 h, was ~3 h)

**Why now:** GL ES 3.2 supports it on NVIDIA; mandatory fallback for
older Mali/Adreno via `EXT_buffer_storage` detection.

- Replace `glBufferData` + `glBufferSubData` with `glBufferStorage`
  (`GL_DYNAMIC_STORAGE_BIT | GL_MAP_PERSISTENT_BIT | GL_MAP_COHERENT_BIT`).
- `glMapBufferRange` once at realize, keep pointer.
- Triple-buffer: 3 sub-regions, one per frame in flight, gated by
  `glFenceSync` + `glClientWaitSync` so CPU can't write to a region
  the GPU is reading.
- **Mandatory fallback** when `GL_ARB_buffer_storage` /
  `EXT_buffer_storage` is missing: keep current path. Detect via
  `epoxy_has_gl_extension`.
- Resize regrows the buffer → unmap, regenerate, re-map. Test path.
- Add `smoke-cell` runs before/after to confirm no regression.

## J — Render thread (refactor, ~2-3 days)

**Why now:** scoped down — only move buildVertices to a worker.

- Don't move GL itself off main (GtkGLArea owns context).
- Move `cell_pass.rebuildRow` and `grid_pass.buildVertices` (CPU
  work) to a thread pool (`std.Thread.Pool`).
- Main-thread render: wait for pool's per-pane future, upload VBO,
  draw.
- **Two snapshots required**, not one:
  1. Per-row generation counter on `Line` for snapshot consistency
     (worker bails / retries if it sees a generation mid-build that
     differs from start). Avoid full Screen snapshot — scrollback
     is too big.
  2. **Frame-snapshot of render config** (palette, default_fg/bg,
     scheme, dim factors) at the moment the worker starts. Without
     this, an `applyConfigChange` mid-frame could mutate state the
     worker reads with no lock.
- Backout plan: feature flag, fall back to main-thread render if
  the worker pool is unavailable.

## K — EGL bypass (research-spike, may defer)

**Why last and conditional:** highest risk, longest tail.

- Spike scope (1 day max): get a red triangle drawn via direct
  EGL on a wl_subsurface inside a sketerm window using
  `gdk_wayland_surface_get_wl_surface`.
- **Even if the spike works, integration is a separate problem.**
  AdwTabView and GtkPaned want to manage their own subsurfaces;
  reconciling our subsurface with their layout is multi-week.
- Spike does NOT commit to integration. Document findings either way.

## Out of scope (reaffirmed)

- Lab/oklch colour spaces.
- Background images.
- macOS / Windows port.
- Plugin system.

## Process

- One feature at a time, committed per logical unit.
- After each commit: `zig build && zig build test`.
- **Standing smoke-cell rule**: any commit touching `cell_pass.zig`,
  `grid_pass.zig`, `atlas.zig`, or `screen.zig` runs `zig build smoke-cell`
  even if not "obvious render code." Image code: `smoke-image`.
- Cron `5c32eb79` ticks every 30 min for 7 days.
  - **Cron risk**: partial commits on half-complete refactors (E/F/J)
    make the next firing harder to ground. Each cron firing first
    runs `git status` — if a multi-step refactor is mid-flight,
    finish the current commit-able unit before picking up new work.
  - Sentinel: a `.plan-v3-active-feature` file naming the in-progress
    feature; cleared when the feature ships. Cron checks this first.

## Test/regression coverage to add

- **Differential UTF-8 fuzzer** before H ships.
- **`smoke-transparency`** before C ships.
- **Input dispatch test harness** (synthesize GdkEvents → assert
  Action) before E ships.
- **Config round-trip property test** (`parse(serialize(cfg)) == cfg`
  on a randomized Config) before F ships.

## Items the review surfaced as unverified ("done?")

These get a verify-then-ship-or-fix pass interleaved with the above:

- `bell_visible` — flash actually rendered? Should be in `grid_pass`
  bell-flash overlay.
- Search bar "highlight all matches" — already implemented or just
  current-match-only?
- OSC 4 query reply — set works; query form (cmus, emacs) verified?
- AdwTabView drag-to-reorder — supposed to work for free; verify.
- Per-pane title manual override — Terminator allows the user to set
  a title that survives OSC 0/1/2 updates. Pair with the new titlebar.
- Save-as-default for current layout — quick win adjacent to D.
- Reflow on resize — Kitty/WezTerm reflow scrollback when window grows.
  Confirm sketerm behaviour or document.
