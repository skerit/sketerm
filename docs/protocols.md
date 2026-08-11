# Protocols

Escape sequences and protocols sketerm supports. The dispatcher is
`Screen.csi` in `src/grid/screen_ops.zig`, which routes by
`params.private` to `csiPrivate` (`?`), `csiAux` (`>`),
`csiKittyKbd` (`=` / `<`) or `csiPublic`; OSC lands in
`Screen.onOsc` in `src/grid/screen.zig`.

A tick in the tables below means the sequence is implemented
today. Sequences we have decided never to implement are listed at
the end.

## C0 control codes

| Byte  | Name | Supported                 |
|-------|------|---------------------------|
| 0x07  | BEL — bell              | visual flash overlay (~200ms) via `bell_at_us` |
| 0x08  | BS  — backspace         | ✓ |
| 0x09  | HT  — horizontal tab    | ✓ |
| 0x0A  | LF  — line feed         | ✓ |
| 0x0B  | VT  — vertical tab      | treated as LF |
| 0x0C  | FF  — form feed         | treated as LF |
| 0x0D  | CR  — carriage return   | ✓ |
| 0x05  | ENQ — answerback        | ✓ (empty reply) |
| 0x0E  | SO  — shift out (G1)    | ✓ |
| 0x0F  | SI  — shift in (G0)     | ✓ |
| 0x1B  | ESC                     | ✓ (enters Escape state) |

## CSI sequences

All canonical CSI handlers from the Williams spec dispatch to
either implemented or stub. Implemented:

### Cursor movement
- CUU, CUD, CUF, CUB — cursor up/down/forward/back
- CUP / HVP — cursor position
- CHA — cursor horizontal absolute
- VPA — vertical position absolute
- CNL / CPL — cursor next/previous line
- SCOSC / SCORC — save/restore cursor (DECSC/DECRC)

### Erase
- ED — erase in display (0/1/2/3)
- EL — erase in line (0/1/2)
- ECH — erase character

### Scroll / edit
- SU — scroll up
- SD — scroll down
- IL — insert lines
- DL — delete lines
- ICH — insert characters
- DCH — delete characters

### Modes (SM / RM; ANSI + DECSET/DECRST)
ANSI modes:
- IRM (4) — insert/replace
- LNM (20) — line feed mode

DECSET / DECRST (`?`-prefixed), per `modeSet` in `screen_ops.zig`:
- 1  — DECCKM — application cursor keys
- 2  - DECANM - reset enters VT52, set returns to ANSI
- 3  - DECCOLM - 80/132 columns, honoured only when 40 is set
- 5  — DECSCNM — reverse video
- 6  — DECOM — origin mode
- 7  — DECAWM — autowrap
- 25 — DECTCEM — cursor visible
- 40 - allow DECCOLM
- 1000 — X10 mouse
- 1002 — cell-motion mouse
- 1003 — all-motion mouse
- 1004 - **focus reporting** ✓
- 1005 / 1006 / 1015 / 1016 - mouse encodings, see *Mouse protocols*
- 47 / 1047 - alt screen (simple)
- 1049 — alt screen + save cursor
- 2004 - **bracketed paste mode** ✓
- 2026 — synchronized output ✓
- 2027 — grapheme clustering: always on; DECRQM reports "permanently set" ✓
- 2031 — color-scheme change reports (`CSI ? 997 ; 1|2 n` on dark/light flips; query via `CSI ? 996 n`) ✓
- 2048 — in-band resize reports (`CSI 48;rows;cols;hpx;wpx t` on set + every resize) ✓

**Not implemented:** mode 12 (cursor blink enable). `modeSet` has no
arm for it; blinking is selected through DECSCUSR instead.

Over the mux, protocol replies come from exactly one side: the
daemon's authoritative Screen answers state queries (DSR, DA,
DECRQM, color/palette); GUI-owned queries (OSC 52 read, DSR ?996
color scheme) are deferred by the daemon and answered by the
attached client's mirror.

### Character attributes
SGR — reset, bold, dim, italic, underline, slow-blink, reverse,
conceal, strike, 256-color fg/bg (`38/48;5;n`), truecolor
(`38/48;2;r;g;b`), default (`39/49`), framed / encircled /
overlined (subset).

### Device status / version
- DA1 (`CSI c`), and DECID (`CSI Z`) with the same payload
- DA2 (`CSI > c`) — secondary device attributes
- DA3 (`CSI = c`) - **no response at all**; the spec allows this
- DSR (`CSI 5n` / `CSI 6n`) — device status / cursor position
- XTVERSION (`CSI > 0 q`) — ✓
- XTMODKEYS (`CSI > 4 ; Pp m`) - the level is recorded; key encoding
  does not yet act on it

### Window manipulation (XTWINOPS) - read-only subset
- `CSI 14 t` — report text-area size **in pixels**: `CSI 4 ; H ; W t`
- `CSI 18 t` — report text-area size **in cells**: `CSI 8 ; rows ; cols t`
- `CSI 19 t` — report screen size in cells (same as 18t for us)

**We never implement the set-window subset** (move/resize/raise).
htop and btop need the report subset for accurate rendering.

### Cursor shape — DECSCUSR
`CSI Ps SP q` - ✓
- `0`/`1` — blinking block (default)
- `2` — steady block
- `3` — blinking underline
- `4` — steady underline
- `5` — blinking bar
- `6` — steady bar

### Scroll region — DECSTBM
`CSI t ; b r` — set top and bottom scrolling margins. ✓

### Implemented, and once planned not to be
- SS2 / SS3 single-shifts (ESC N / ESC O — bypass charset
  translation for the next codepoint; G2/G3 not modelled).
- Character set designation (SCS for G0/G1 → DEC graphics, SI/SO).
- ED 3 (erase scrollback).
- Selective erase (DECSED / DECSEL routed to plain ED/EL — we
  don't model the protection bit).
- DECDHL / DECDWL (double-height / double-width lines).
- DECSCNM (reverse-video mode).
- DECCOLM (80/132 column, gated behind DECSET 40).
- VT52 mode (DECRST 2 enters VT52, DECSET 2 returns to ANSI).

## OSC sequences

| Number | Purpose                                   | Supported |
|--------|-------------------------------------------|----|
| 0, 2   | Set window/icon title                     | ✓ (per pane) |
| 1      | Set icon name                             | accepted and ignored (no separate icon-name surface) |
| 4      | Color palette query + set (multi-pair)    | ✓ |
| 7      | Report working directory (file://…)       | ✓ |
| 8      | Hyperlinks                                | ✓ |
| 10/11/12 | Default fg / bg / cursor color (query+set)| ✓ |
| 52     | Clipboard set + read query                | ✓ (read gated behind `clipboard_read = allow`, empty reply when denied; 1 MB cap both ways) |
| 99     | Kitty desktop notifications               | ✓ (chunked title/body, buttons + activation reports, themed-icon names + image payloads, urgency, occasion filter, close/withdraw, `p=?` capability reply; NOT supported: close events `c=`, `p=alive`, sounds, timeouts — GNotification gives no closure feedback) |
| 104    | Reset color palette (bare / index list)   | ✓ |
| 110/111/112 | Reset fg/bg/cursor (incl. bare form) | ✓ |
| 133    | Shell integration (FinalTerm prompt marks)| ✓ (A-marks navigate via Ctrl+Shift+Up/Down; C/D bound the command-output zone behind "Copy Command Output" / `copy_command_output`) |
| 9      | iTerm2 desktop notification               | ✓ |
| 9;4    | ConEmu progress (tab ring + taskbar)      | ✓ |
| 9;9    | ConEmu/Cmder cwd report (quotes stripped) | ✓ |
| 17, 19 | Selection bg / fg color, query + set      | ✓ |
| 21     | Kitty unified color query/set protocol    | ✓ |
| 117, 119 | Reset selection bg / fg                 | ✓ |
| 633    | VS Code shell integration (superset of 133) | ✓ |
| 777    | Desktop notifications (notify variant)    | ✓ |
| 22     | Set X11 / GTK mouse-cursor shape          | ✓ |
| 50     | Font query (set is no-op)                 | ✓ |
| 1337   | iTerm2 proprietary - `File=` plus CursorShape, ClearScrollback, SetMark, RequestAttention, CopyToClipboard, EndCopy, ReportCellSize, SetUserVar, SetColors, SetProfile, StealFocus-deny | ✓ |

## Bracketed paste (DECSET 2004)

When enabled (via shell or explicit DECSET), paste is wrapped:

```
ESC [ 200 ~  <paste bytes>  ESC [ 201 ~
```

sketerm wraps paste when mode 2004 is enabled in the pane, across
all paste paths:
- `Ctrl+Shift+V` keybinding → `GdkClipboard` (CLIPBOARD selection)
- Menu *Paste* → same
- Middle-click → `gdk_display_get_primary_clipboard` (PRIMARY
  selection) — configurable via `config.mouse.middle_click_paste`.

Shells use bracketed paste to avoid interpreting pasted Enter as
command execution.

Default behavior per app:
- bash (readline ≥ 7): emits DECSET 2004 itself; we honor it.
- zsh: same.
- vim: toggles mode as needed via `autocmd InsertEnter`.

## DCS frames

| Prefix | Purpose                                   | Supported |
|--------|-------------------------------------------|----|
| `q`    | Sixel image                               | ✓ |
| `$q`   | DECRQSS — report setting (m/r/" q)        | ✓ |
| `+q`   | XTGETTCAP — terminfo query                | ✓ (TN, Co, RGB, Tc, bce, U8, civis/cnorm, csr, Su) |
| `P`    | DECUDK — user-defined keys                | never |

## APC frames

| Prefix | Purpose                                   | Supported |
|--------|-------------------------------------------|----|
| `G...`   | Kitty graphics protocol                   | ✓ |

## Mouse protocols

| Mode | Name                     | Supported |
|------|--------------------------|----|
| 1000 | X10 button               | ✓ |
| 1002 | Cell-motion tracking     | ✓ |
| 1003 | All-motion tracking      | ✓ |
| 1005 | UTF-8 extended           | ✓ |
| 1006 | **SGR extended**         | ✓ (preferred modern) |
| 1015 | URXVT extended           | ✓ |
| 1016 | SGR-pixels               | ✓ |

## Keyboard protocols

| Mode                                  | Supported |
|---------------------------------------|----|
| xterm baseline (modifyOtherKeys=0)    | ✓ |
| Cursor + tilde + SS3 keys with Shift/Alt/Ctrl modifier codes | ✓ |
| modifyOtherKeys=1 (ambiguous combos)  | ✓ |
| modifyOtherKeys=2 (all printable)     | ✓ |
| DECCKM — application-cursor-keys mode | ✓ |
| DECPAM / DECPNM — keypad mode         | ✓ (numpad emits ESC O X under DECPAM) |
| CSI u (libtermkey)                                             | ✓ |

Kitty keyboard protocol (`csiAux` / `csiKittyKbd` in
`screen_ops.zig`) - note which form does what, they are easy to
confuse:

| Sequence          | Effect                                              |
|-------------------|-----------------------------------------------------|
| `CSI > flags u`   | PUSH current flags, then set - how apps enable it    |
| `CSI = flags ; mode u` | Set WITHOUT touching the stack; mode 1 assign, 2 or-in, 3 clear |
| `CSI < N u`       | Pop N levels                                        |
| `CSI ? u`         | Query, replies `CSI ? flags u`                      |

The push stack drops its oldest entry when full rather than
refusing, so a program that pushes without popping cannot wedge the
protocol for everything after it.

## Character encodings

**UTF-8 for text.** No ISO 2022 designation / invocation, and no
legacy encodings.

The VT100 line-drawing set IS supported, contrary to what this
section used to claim: `Screen.Charset` is `{ ascii, dec_graphics }`
with independent G0/G1 slots, SI/SO switch the active slot, SCS
designates, and SS2/SS3 single-shift the next codepoint. G2/G3 are
not modelled, so a single shift with nothing designated is consumed
without effect.

## Image protocols — wire details

### Sixel (DCS q)
- Private params `P1` (aspect), `P2` (background handling),
  `P3` (horizontal grid).
- Raster attributes `" Pan;Pad;Ph;Pv`.
- Color registers `#n;2;r;g;b` (RGB) or `#n;1;h;l;s` (HLS).
- Decoded to RGBA8. Uploaded as GL texture. Placed at cursor.
- Scrolls with content. See `docs/images.md`.

### Kitty graphics (APC G…)
- Commands: `t` / `T` (transmit, transmit+place), `p` (put),
  `d` (delete), `q` (query support), `f` (frame data),
  `a` (animation control).
- Formats: `f=32` RGBA, `f=24` RGB, `f=100` PNG.
- Media: `t=d` direct inline, `t=t` tempfile (read then unlink),
  `t=f` file path. `t=s` (shared memory) is NOT supported.
- Compression: `o=z` zlib via `std.compress.flate`.
- Chunked transmit via `m=1` / `m=0`.
- Placement IDs, image IDs, z-index — all per spec.
- Delete variants — full set supported.
- **Animation** — `a=f` appends frames with per-frame `z=delay_ms`;
  `a=a` controls playback (`c=1` stop / `c=2` run, `r=loop_count`,
  `s=set_current_frame`). Pane.onTick advances active animations
  via monotonic-time elapsed comparisons; the placement texture
  is updated in place via `glTexSubImage2D`.

### iTerm2 OSC 1337
- `File=` carries images; the other directives are listed in the OSC
  table above.
- Payload: base64, buffered across OSC writes until the terminator.
- **PNG only**, enforced by an explicit magic check in
  `parser/iterm_image.zig` before stb_image sees the bytes. JPEG,
  GIF, TIFF and WebP are not accepted.
- `inline=0` (the protocol default) means "transfer, do not show";
  we have no download side, so those payloads are dropped rather
  than drawn where the app expects nothing.
- Placement at cursor; the requested box (`width=` / `height=` in
  cells, pixels, percent or auto) is resolved against the pane's
  real cell metrics.

## Terminal responses

| Query                           | Response                                                   |
|---------------------------------|------------------------------------------------------------|
| DA1 (`CSI c`)                   | `CSI ? 62 ; 4 ; 22 c` - VT220 + sixel + ANSI color         |
| DA2 (`CSI > c`)                 | `CSI > 42 ; 1 ; 0 c` - vendor id 42 = sketerm              |
| DA3 (`CSI = c`)                 | no response                                                |
| DSR cursor (`CSI 6 n`)          | `CSI row ; col R`                                          |
| XTVERSION (`CSI > 0 q`)         | `DCS > \|sketerm 0.1.0 ESC \\`                             |
| Kitty query (`APC G a=q,i=1 ; ...`) | per Kitty spec: `OK` or diagnostic              |
| CSI 14 t                        | `CSI 4 ; H ; W t` (pixels)                                 |
| CSI 18 t                        | `CSI 8 ; rows ; cols t`                                    |
| CSI 19 t                        | `CSI 9 ; rows ; cols t`                                    |
| Focus in/out                    | `CSI I` / `CSI O` (when mode 1004 enabled)                 |

**Version strings are hardcoded.** Both the DA2 payload and
XTVERSION carry literal constants in `screen_ops.zig` rather than
`version.string`, so they do not track `.version` in
`build.zig.zon`. Anything parsing them is reading a fixed value.

## Environment variables set for child

Set by `Pty.spawn` (`src/pty.zig`) in the forked child:

| Variable                | Value                                            |
|-------------------------|--------------------------------------------------|
| `TERM`                  | `xterm-256color` by default; the `term` config key selects something else, e.g. `sketerm-256color` |
| `COLORTERM`             | `truecolor` (config `color_term`)                |
| `TERM_PROGRAM`          | `sketerm`                                        |
| `TERM_PROGRAM_VERSION`  | `version.string`                                 |
| `KITTY_WINDOW_ID`       | `1` - the hint most tools (yazi, lf, btop, chafa, viu) check for kitty-graphics capability, and it is accurate |
| `SKETERM_PANE_ID`       | pane id, so `sketerm cli` inside the pane can self-address |
| `SKETERM_SOCKET`, `SKETERM_MUX_SOCKET` | control + daemon sockets, when set |
| `SKETERM_SESSION`, `SKETERM_SESSION_ORIGIN_ID` | durable session identity |

`COLUMNS` / `LINES` are NOT set: the kernel's winsize is the source
of truth and the shell derives them itself. A session may also get
`WAYLAND_DISPLAY`, `PULSE_SERVER`, `XDG_RUNTIME_DIR` and a11y bus
variables when the daemon is hosting forwarded apps.

## Terminfo

`terminfo/sketerm-256color.src` is compiled with `tic -x` and
installed by the PKGBUILD. It is `use=xterm-256color` plus:

- Truecolor (`Tc`, `RGB`)
- OSC 52 clipboard (`Ms`)
- Bracketed paste (`BE`, `BD`, `PS`, `PE`)
- Cursor shape (`Ss`, `Se`)
- Focus reporting (`fe`, `fd`)

It does NOT declare a `sixel` capability or an OSC 8 extension,
despite the header comment mentioning sixel in the description
string. Sixel capability reaches apps through DA1's `;4;` instead.

Because the default `$TERM` is `xterm-256color`, a child only sees
`sketerm-256color` when the user opts in with `term =` in the
config - which is also what makes remote hosts without our terminfo
file a non-issue by default.

## Feature-detect heuristics apps use

Documented so we don't surprise app heuristics:

- Sixel: apps check terminfo `sixel`, or sniff `$TERM` for
  `xterm-kitty` / `wezterm` / `foot` / `mlterm`, or probe DA1. Our
  terminfo does NOT carry the capability, so the DA1 `;4;`
  advertisement is what these probes land on.
- Kitty graphics: apps probe with `APC Gi=...,a=q,t=d,f=24;...` and we
  reply `OK` (silently, at `q>=1`). Many tools skip the probe
  entirely and trust `$KITTY_WINDOW_ID`, which we set to `1`.
- Truecolor: apps check `COLORTERM=truecolor`. We set it
  unconditionally.
- Hyperlinks (OSC 8): apps check `$TERM` against a known list, so a
  pane running the default `xterm-256color` inherits xterm's
  standing there.

## What we never implement

- `DECUDK` (user-defined keys) — security-adjacent, obsolete.
- `DECBI` / `DECFI` (back/forward index) — VT420-specific, unused.
- Arbitrary set-window XTWINOPS (move, resize, iconify, raise) —
  we respond to size-report subsets only (14t / 18t / 19t).
- Windows. (macOS is NOT on this list any more: the platform seams
  exist and the cross-compile check is
  `zig build mux-portable -Dportable-target=aarch64-macos`. See
  `docs/macos.md`.)
