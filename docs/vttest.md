# vttest checklist

[`vttest`](https://invisible-island.net/vttest/) is the de-facto VT-family
compliance test program (curses-based, prints visual patterns). Until we
have automated visual diffs, it's our smoke-test for protocol
correctness.

```
# Most distros
sudo pacman -S vttest      # Arch
sudo apt install vttest    # Debian/Ubuntu
```

Run it inside a sketerm pane:

```
$ vttest
```

## Tests we should pass

Numbers refer to the vttest menu.

- **1** Cursor movement — DECCKM, CUU/CUD/CUF/CUB, CUP, HVP, save/restore.
  We pass the basics. Origin mode (DECOM) is honored. Cursor wraps around
  pending-wrap matches xterm convention.

- **2** Screen features — ED/EL with all variants (0/1/2). DECSED/DECSEL
  routed to plain ED/EL (we don't model selective protection).

- **3** Character attributes — SGR coverage. Bold, dim, italic, underline,
  blink, reverse, strikethrough, double-underline. Truecolor via `38;2;r;g;b`.

- **5** General test of escape sequences — DA1 (`\e[?62;4;22c`), DA2
  (`\e[>42;1;0c`), XTVERSION, DSR cursor position, window-state CSI t.

- **6** Test of vt52 mode — **not implemented**, will fail.

- **7** Test of VT102 features — IRM (insert mode) ✓, IL/DL ✓, ICH/DCH ✓,
  DECSTBM ✓, smooth scroll (DECSCLM) — accepted but no-op.

- **8** Test of known bugs — most don't apply (we're not VT100/VT220 in
  hardware). DECCOLM (132 cols) explicitly not implemented.

- **9** Reset / restore — RIS (`\ec`) and DECSTR (`\e[!p`) both wired,
  including charset/mouse-mode/palette reset.

- **B** Test ECMA-48 SGR — full SGR menu including curly underline (we
  parse 4:3 but don't render curly yet).

## Things vttest doesn't cover

- Sixel — try `img2sixel` + an image:
  `convert image.png sixel:-` then `cat` the result.
- Kitty graphics — `kitten icat image.png` (requires `kitten` from
  the kitty package).
- iTerm2 OSC 1337 — `imgcat image.png` from iTerm2's tools.
- OSC 52 clipboard — `printf '\e]52;c;%s\a' "$(echo hello | base64)"`
  then paste somewhere; should be "hello".
- OSC 7 cwd — source `data/shell-integration/sketerm.bash` from your
  bashrc, then check `--restore` picks up the right cwd.
- DECSET 1004 focus — `cat -v`, then click in/out of the pane;
  should see `^[[I` / `^[[O`.
- modifyOtherKeys — `infocmp -L | grep modifyOtherKeys` (set via
  `\e[>4;1m`); pressing Ctrl+i should produce `\e[27;5;105~` instead
  of TAB.

## Things known not to pass

- DECCOLM (80/132 column switch) — not implemented; pane resize is
  driven by GTK allocation only.
- DECSCNM (screen reverse-video) — not implemented.
- Soft / hard reset interactions with charset — partial (G0/G1 reset
  to ASCII, no G2/G3 / SS2 / SS3 / LS1R machinery).
- Double-height / double-width lines (DECDHL / DECDWL) — not
  implemented and not planned for v1.
- VT52 emulation mode — not implemented.

## Reading the output

Expected behavior:
- All ASCII art aligns column-perfect across panes.
- No phantom cells outside the focus border (the 6 px padding).
- Scroll regions don't leak into headers/footers.
- BEL (`\a`) flashes the pane white for ~200 ms.

If anything renders wrong, file a tiny repro: `printf 'EXACT BYTES'` that
triggers it, plus what you expected. Compare against `xterm` or `kitty`
behavior — those are the reference.
