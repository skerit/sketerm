# Plan

## Why this project

Every existing terminal emulator fails at least one of the author's
hard requirements. The requirement set is not esoteric — it is the
intersection of features that individually exist in many terminals
but do not coexist in any one of them:

| Requirement                      | Terminals that fail it                        |
| -------------------------------- | --------------------------------------------- |
| OSC 52 clipboard over SSH        | VTE-based (Terminator, Tilix, gnome-terminal) |
| Native xdg_popup context menu    | Kitty (text-only), WezTerm (internal overlay) |
| Splits *inside* the context menu | Kitty, Ghostty, Konsole                       |
| Stable tab names (group-level)   | Konsole (tab follows active pane's title)     |
| Sixel + Kitty + iTerm2 images    | Alacritty (refuses by design)                 |
| Layout persistence               | Most; partial in Tilix / WezTerm              |
| Native (not Electron)            | Tabby, Hyper                                  |

Rather than compromise or stitch together multiple projects,
sketerm is built as a single coherent codebase with this full set
as design-first constraints.

## Target user

A single technically proficient user (the author). No product
roadmap, no stakeholders, no user surveys. This grants freedom to
drop features that don't serve the author, to prioritize clarity
over generality, and to make opinionated defaults.

## Hard requirements (v1)

### Clipboard

1. **OSC 52 clipboard writes and reads.** Write path always allowed.
   Read path default-deny, per-session opt-in prompt on first
   attempt. Max payload 1 MB per OSC 52 message (guard against DoS).
2. **Bracketed paste mode (DECSET 2004)** — on by default. Ctrl+Shift+V
   wraps paste with the begin/end markers so shells can detect it.
3. **GTK paste path** — integrates with `GdkClipboard` read (async)
   so paste from any app works.

### UI — context menu and structure

4. **Native GTK `PopoverMenu`** backed by `GMenu` + `GActionMap`,
   rendered as a real Wayland xdg_popup so it floats outside the
   parent surface.
5. **Context menu actions (minimum)** — *Copy*, *Paste*,
   *Split Horizontal*, *Split Vertical*, *Close Pane*, *New Tab*,
   *Rename Tab…*, *Close Tab*. Future plugins may extend.
6. **Stable tab names.** A tab's title is set by the user (or a
   layout file) and is never overwritten by a pane's shell title.
7. **Pane shell title visible somewhere** — since tab titles are
   frozen, each pane displays its shell-reported title (OSC 0/2)
   along the pane top or in a tooltip. Specific UI surface TBD in
   M6 design.
8. **Splits** — nestable horizontal / vertical, resizable drag
   handles, click-to-focus. Navigable via keyboard shortcuts.

### Rendering

9. **Truecolor + 256-color palette + 16-color palette** — full SGR.
10. **`COLORTERM=truecolor`** exported into child env so apps detect
    truecolor support regardless of `$TERM`.
11. **DECSCUSR cursor shapes (`CSI space q`)** — block / underline /
    bar, blinking/steady. vim/nvim/fish emit this.
12. **Scrollback** — 10 000 lines default, configurable.
13. **UTF-8 only.** No ISO 2022 designation. Wide-char width tables.

### Input

14. **Keyboard**: xterm baseline encoding; `modifyOtherKeys=1` supported
    (emacs needs this); full progressive CSI u deferred to post-v1.
15. **Mouse**: SGR mouse mode (DECSET 1006); click-focus for panes;
    selection + copy.
16. **IME**: `GtkIMMulticontext` wired for fcitx5/ibus. Preedit
    rendered at cursor location inside the GL grid.

### Images

17. **Sixel (DCS q)**.
18. **Kitty graphics (APC G=)**.
19. **iTerm2 inline images (OSC 1337 File=)** — PNG only in v1;
    other formats deferred.

See `docs/images.md` for the unified placement model.

### Terminal protocol

20. **Focus reporting (DECSET 1004)** — vim/tmux use it.
21. **Window-size reports (CSI 14t, CSI 18t)** — read-only. btop
    and htop need these for reliable rendering. Never implement the
    dangerous set-window subset.
22. **OSC 7** — track per-pane cwd (reported by shell
    integration scripts or via VTE-compatible `$PROMPT_COMMAND`).
    Required for layout persistence.
23. **OSC 8 hyperlinks** — cells carry link ids; hover shows URL;
    Ctrl-click opens via `xdg-open`.
24. **DA1 / DA2 / XTVERSION responses** — correct capability
    reporting so apps enable truecolor, images, and modern modes.

### Session

25. **Layout persistence** — tab/split tree + per-pane cwd + initial
    command serialize to a ZON file. See `docs/layout.md`.
26. **Shell-exit handling** — configurable. Default:
    `hold-on-exit = true`, pane stays open with
    `[process exited with status N]` overlay; user closes manually.
27. **SIGWINCH propagation** — every resize calls `TIOCSWINSZ` on
    the master fd so the child receives SIGWINCH. See
    `docs/lifecycle.md`.

### Terminfo

28. **`sketerm-256color` terminfo entry** — ships with v1. Declares
    truecolor, sixel, OSC 52, OSC 8, and related capabilities. The
    child env is set `TERM=sketerm-256color` by default; falls back
    to `xterm-256color` if the terminfo file is not installed on
    the remote host (automatic via sketerm's probe).

## Non-goals (v1)

Explicitly out of scope, to keep a realistic shipping date:

- Ligatures (per-cluster HarfBuzz shaping)
- ZWJ emoji sequences (family 👨‍👩‍👧, skin tones, flags). **Known
  v1 rough edge** — users will see these render as separate glyphs
  with wrong widths. See `risks.md`.
- Font fallback chain — v1 is single-face; missing glyphs render
  as tofu (⬜). Fallback lands in M10.
- LCD subpixel antialiasing — grayscale AA only in v1; LCD modes
  accepted in config but silently downgrade.
- Bidirectional text (FriBidi)
- Full Kitty progressive-enhancement keyboard protocol
- Tmux control mode integration
- Cross-platform — Linux Wayland primary; X11 via XWayland;
  macOS/Windows never.
- Settings UI (config file only)
- Plugin host (architecture permits it; implementation deferred)
- Multiple profiles beyond one default
- Search in scrollback
- URL auto-detection beyond OSC 8
- Session recording / replay
- Theme files beyond palette + font settings
- Animated images, GIF, animated PNG
- Kitty `t=t` / `t=s` image media (temp file / shared memory)
- Persistent environment variables in layouts (security, see
  `layout.md`)

## Success criteria for v1

sketerm is *v1 done* when **all** of:

1. The author daily-drives it for two consecutive weeks without
   falling back to another terminal.
2. `vttest` passes every test within the v1 feature subset (with
   a documented expected-fail list for VT220+ features we don't
   target: SCS, DECDHL/DECDWL, etc.).
3. Representative SSH workflow end-to-end: connect to remote,
   run `htop`, run `yazi` with sixel preview, OSC 52 copy into
   local clipboard.
4. A layout with 3 tabs × 2 splits saves and reloads faithfully
   (cwd, command, split ratios).
5. Idle memory footprint under 150 MB for a 3-tab workload on
   Mesa (AMD/Intel). NVIDIA proprietary may differ; documented
   separately.
6. Cold start to interactive prompt under 300 ms on NVMe.
7. No GL context-loss or black-frame regressions in a 30-minute
   `cat /dev/urandom` stress test.

## Schedule posture

Honest estimate summed from `docs/milestones.md`:
**12-14 weeks focused full-time work** baseline, **16-20 weeks
with a 30 % contingency** for first-time-in-GTK4 tax and
unexpected Zig stdlib churn.

Part-time (10-15 h/wk): **9-12 months** with contingency
included.

No external deadline. Correctness and code clarity beat speed.

## Post-v1 roadmap (non-binding)

Ordered by rough interest:

1. Lua plugin host with event hooks and menu-extension API
2. HarfBuzz shaping → ligatures + emoji ZWJ sequences
3. Kitty progressive-enhancement keyboard protocol (CSI u)
4. Bidirectional text (FriBidi)
5. Multiple profiles + settings UI
6. Search in scrollback
7. Tmux control mode integration
8. Animated images
9. Cross-pane texture sharing for duplicate Kitty images
10. Kitty `t=t` temp-file medium (after security review)

## Referenced companion docs

- `docs/architecture.md` — module layout and data flow
- `docs/milestones.md` — phased execution plan
- `docs/references.md` — specs and reference implementations
- `docs/protocols.md` — escape sequences supported
- `docs/risks.md` — risks and mitigations
- `docs/gpu.md` — GL / GTK4 integration, share groups, scaling
- `docs/images.md` — unified image placement model
- `docs/layout.md` — layout persistence design
- `docs/lifecycle.md` — PTY, workers, signals, teardown
