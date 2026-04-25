# Protocols

Escape sequences and protocols sketerm supports in v1.
"Deferred" = not in v1; architecturally permitted.

## C0 control codes

| Byte  | Name | v1                        |
|-------|------|---------------------------|
| 0x07  | BEL — bell              | audible + urgency hint via `AdwWindow.urgency-hint` |
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
either implemented or stub. Implemented in v1:

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

DECSET / DECRST (`?`-prefixed):
- 1  — DECCKM — application cursor keys
- 5  — DECSCNM — reverse video
- 6  — DECOM — origin mode
- 7  — DECAWM — autowrap
- 12 — cursor blink (steady/blink)
- 25 — DECTCEM — cursor visible
- 1000 — X10 mouse
- 1002 — cell-motion mouse
- 1003 — all-motion mouse
- 1004 — **focus reporting** ✓ (v1 req)
- 1006 — SGR mouse (preferred modern) ✓
- 1047 — alt screen (simple)
- 1049 — alt screen + save cursor
- 2004 — **bracketed paste mode** ✓ (v1 req)

### Character attributes
SGR — reset, bold, dim, italic, underline, slow-blink, reverse,
conceal, strike, 256-color fg/bg (`38/48;5;n`), truecolor
(`38/48;2;r;g;b`), default (`39/49`), framed / encircled /
overlined (subset).

### Device status / version
- DA1 (`CSI c`) — primary device attributes
- DA2 (`CSI > c`) — secondary device attributes
- DA3 (`CSI = c`) — tertiary (stub response, spec says optional)
- DSR (`CSI 5n` / `CSI 6n`) — device status / cursor position
- XTVERSION (`CSI > 0 q`) — ✓

### Window manipulation (XTWINOPS) — read-only subset in v1
- `CSI 14 t` — report text-area size **in pixels**: `CSI 4 ; H ; W t`
- `CSI 18 t` — report text-area size **in cells**: `CSI 8 ; rows ; cols t`
- `CSI 19 t` — report screen size in cells (same as 18t for us)

**We never implement the set-window subset** (move/resize/raise).
htop and btop need the report subset for accurate rendering.

### Cursor shape — DECSCUSR
`CSI Ps SP q` — ✓ v1 requirement.
- `0`/`1` — blinking block (default)
- `2` — steady block
- `3` — blinking underline
- `4` — steady underline
- `5` — blinking bar
- `6` — steady bar

### Scroll region — DECSTBM
`CSI t ; b r` — set top and bottom scrolling margins. ✓

### Deferred in v1
- DECDHL / DECDWL (double-height / double-width lines)
- SS2 / SS3 single-shifts (LS0 / LS1 done as SI / SO)

### Done in v1 (originally listed deferred)
- Character set designation (SCS for G0/G1 → DEC graphics, SI/SO).
- ED 3 (erase scrollback).
- Selective erase (DECSED / DECSEL routed to plain ED/EL — we
  don't model the protection bit).

## OSC sequences

| Number | Purpose                                   | v1 |
|--------|-------------------------------------------|----|
| 0, 2   | Set window/icon title                     | ✓ (per pane) |
| 4      | Set color palette entry                   | ✓ |
| 7      | Report working directory (file://…)       | ✓ |
| 8      | Hyperlinks                                | ✓ |
| 10/11/12 | Default fg / bg / cursor color          | ✓ |
| 52     | Clipboard set/get                         | ✓ (get gated; 1 MB cap) |
| 104    | Reset color palette                       | ✓ |
| 110/111/112 | Reset fg/bg/cursor                   | ✓ |
| 133    | Shell integration (FinalTerm prompt marks)| deferred |
| 9      | iTerm2 desktop notification               | ✓ |
| 777    | Desktop notifications (notify variant)    | ✓ |
| 1337   | iTerm2 proprietary — `File=` only         | ✓ |

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

| Prefix | Purpose                                   | v1 |
|--------|-------------------------------------------|----|
| `q`    | Sixel image                               | ✓ (M9b) |
| `$q`   | DECRQSS — report setting (m/r/" q)        | ✓ |
| `+q`   | XTGETTCAP — terminfo query                | deferred |
| `P`    | DECUDK — user-defined keys                | never |

## APC frames

| Prefix | Purpose                                   | v1 |
|--------|-------------------------------------------|----|
| `G…`   | Kitty graphics protocol                   | ✓ (M9a) |

## Mouse protocols

| Mode | Name                     | v1 |
|------|--------------------------|----|
| 1000 | X10 button               | ✓ |
| 1002 | Cell-motion tracking     | ✓ |
| 1003 | All-motion tracking      | ✓ |
| 1005 | UTF-8 extended           | deferred |
| 1006 | **SGR extended**         | ✓ (preferred modern) |
| 1015 | URXVT extended           | deferred |
| 1016 | SGR-pixels               | deferred |

## Keyboard protocols

| Mode                                  | v1 |
|---------------------------------------|----|
| xterm baseline (modifyOtherKeys=0)    | ✓ |
| Cursor + tilde + SS3 keys with Shift/Alt/Ctrl modifier codes | ✓ |
| modifyOtherKeys=1                     | deferred |
| modifyOtherKeys=2                     | deferred |
| DECCKM — application-cursor-keys mode | ✓ |
| DECPAM / DECPNM — keypad mode         | stub |
| Kitty progressive enhancement         | deferred |
| CSI u (libtermkey)                    | deferred |
| Kitty progressive enhancement (CSI =…)| deferred |

## Character encodings

**UTF-8 only in v1.** No ISO 2022 designation / invocation. No
VT100 character sets (SO/SI ignored). Legacy encodings never
supported.

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
  `d` (delete), `q` (query support).
- Formats v1: `f=32` RGBA, `f=24` RGB, `f=100` PNG.
- Media v1: `t=d` direct inline.
- Media **deferred v1**: `t=t` temp file, `t=s` shared memory
  (security review required).
- Chunked transmit via `m=1` / `m=0`.
- Placement IDs, image IDs, z-index — all per spec.
- Delete variants — full set supported.

### iTerm2 OSC 1337
- Only `File=` key in v1.
- Payload: base64. Streamed decode; buffer across OSC writes
  until terminator.
- Format v1: PNG only (via vendored `stb_image.h`).
- Format **deferred v1**: JPEG, GIF, TIFF, WebP.
- Placement at cursor, sized by `width=` / `height=` or image
  dimensions.

## Terminal responses

| Query                           | Response                                                   |
|---------------------------------|------------------------------------------------------------|
| DA1 (`CSI c`)                   | `CSI ? 62 ; 4 ; 8 ; 22 ; 28 c` — VT220 + sixel + color     |
| DA2 (`CSI > c`)                 | `CSI > 42 ; M ; m c` — vendor id 42 = sketerm; M/m = version |
| DA3 (`CSI = c`)                 | stub empty response                                        |
| DSR cursor (`CSI 6 n`)          | `CSI row ; col R`                                          |
| XTVERSION (`CSI > 0 q`)         | `DCS > ` `\|sketerm vMAJOR.MINOR.PATCH` `\e\\`             |
| Kitty query (`APC G a=q,i=1 ; ...`) | per Kitty spec: `OK` or diagnostic              |
| CSI 14 t                        | `CSI 4 ; H ; W t` (pixels)                                 |
| CSI 18 t                        | `CSI 8 ; rows ; cols t`                                    |
| CSI 19 t                        | `CSI 9 ; rows ; cols t`                                    |
| Focus in/out                    | `CSI I` / `CSI O` (when mode 1004 enabled)                 |

**Note on DA1 `4`**: advertises sixel. Do not advertise until
sixel decoding (M9b) is solid. Until then, respond with
`CSI ? 62 ; 22 c` and let apps fall back to ASCII.

## Environment variables set for child

| Variable                | Value                                            |
|-------------------------|--------------------------------------------------|
| `TERM`                  | `sketerm-256color` (or `xterm-256color` fallback) |
| `COLORTERM`             | `truecolor`                                      |
| `TERM_PROGRAM`          | `sketerm`                                        |
| `TERM_PROGRAM_VERSION`  | semver string                                    |
| `COLUMNS`               | current cell columns                             |
| `LINES`                 | current cell rows                                |

## Terminfo

v1 ships **`sketerm-256color.src`** compiled via `tic`. Declared
capabilities:
- Truecolor (`Tc`, `RGB`)
- Sixel (`sixel`)
- OSC 52 (`Ms`)
- OSC 8 (custom `u8`)
- Full xterm-256color base
- Focus reporting (`fe`, `fd`)
- Bracketed paste (`BE`, `BD`)
- DECSCUSR variants (`Ss`, `Se`)

Fallback behavior: if the remote host doesn't have the
`sketerm-256color` terminfo file, sketerm falls back to advertising
`$TERM=xterm-256color` for that child (future: a probe step; v1
just uses the env var unconditionally and lets `tput` fail
silently where it must).

## Feature-detect heuristics apps use

Documented so we don't surprise app heuristics:

- Sixel: apps check terminfo `sixel`, or sniff `$TERM` for
  `xterm-kitty` / `wezterm` / `foot` / `mlterm`, or probe DA1.
  With our `sketerm-256color`, terminfo check passes (when sixel
  is advertised post-M9b).
- Kitty graphics: apps probe with `APC Gi=…,a=q,t=d,f=24;...`.
  We respond per spec.
- Truecolor: apps check `COLORTERM=truecolor`. We set it
  unconditionally.
- Hyperlinks (OSC 8): apps check `$TERM` against a known list.
  We add `sketerm-256color` to such lists informally by being
  fully compatible.

## What we never implement

- `DECUDK` (user-defined keys) — security-adjacent, obsolete.
- `DECBI` / `DECFI` (back/forward index) — VT420-specific, unused.
- Arbitrary set-window XTWINOPS (move, resize, iconify, raise) —
  we respond to size-report subsets only (14t / 18t / 19t).
- `DECRQSS` — deferred, not rejected architecturally.
