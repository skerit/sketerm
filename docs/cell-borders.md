# Cell borders

sketerm implements the mandatory baseline of the draft cell-border
protocol, version 1: `DCS 1 + b cell-border ; OP [; FIELD]* ST`. Borders
are thin lines on a cell's edges and centrelines that cost no character
positions; they move, scroll, erase and reflow with the cells that carry
them.

## Supported

- Operations `q`, `pen`, `pen-clear`, `set`, `clear`.
- All twelve segments (half edges and centre arms) and every mask.
- Colours `RRGGBB`, `pN` and `fg`. Palette and `fg` resolve when drawing,
  so OSC 4/10 and theme changes recolour existing borders.
- `WIDTH` in 1/256 of the cell width, never thinner than one device pixel.
- Placement inside or centred (centred strokes bleed half their width
  into the neighbour; strokes past the grid edge are clipped).
- Layers below text and above text. Paint order: backgrounds, below-text
  strokes, text, a focused block cursor, above-text strokes, every other
  cursor shape and the pane chrome.
- Shared-edge merging of two centred strokes: the wider wins, a tie goes
  to the right or lower cell.
- The whole pen lifecycle (print, wide characters, erases, ICH/DCH,
  IL/DL/scrolling, SGR 0, DECSC/DECRC, modes 1048/1049, DECSTR, RIS,
  DECCOLM, DECALN), rectangles, reflow, scrollback and the alternate
  screen.
- The capability reply is `ok;1;pen,rect,half,center,palette`.

## Not supported

Joint operations (`pen-round`, `pen-square`, `round`, `square`) are
unknown operations and so ignored whole. The `style`, `priority`,
`outside` and `radius` extension keys are syntax-checked and ignored, so
every stroke draws solid and shared edges never consult a priority.
DECDWL/DECDHL rows (undefined in version 1) draw at single-cell geometry.
Selective erase does not model protected cells (sketerm has no DECSCA),
so it erases like ED/EL. The translucent selection overlay is drawn
above below-text strokes, so it tints them as it tints text; above-text
strokes keep their colour. The tmux-style tty mirror does not re-emit
borders to an outer terminal.

## Storage

A cell's border set is part of its style, not a separate cell field:
`style_pool.Entry.border` is a `u16` ID into `Pool.border_table`, a
`grid/slot_table.zig` table interned like the style entries themselves
(ID 0 is the empty set; slots are stable, unused ones are recycled
through a free list). Overstrike layers (`docs/overstrike.md`) use the
same table type. `Cell` stays 8 bytes.

That makes the pen simply `cur_style`'s border set. Every path that
already copies a style reference carries borders for free: printing,
BCE erases, scrolling into scrollback, reflow, DECSC/DECRC and 1049, and
SGR 0 resetting the entry clears the pen. The paths that blank cells
without BCE (scroll and ICH/DCH fill, a split wide pair, DECALN) take
`Screen.blankStyle()`: default rendition plus the pen's borders, which
is the default style whenever the pen is empty. Reflow counts a blank
cell with borders as content.

Style GC (`compactStylePool`) also frees the border sets no surviving
style uses. A pool full of live styles is not rescanned per cell: a
reclaim that frees nothing backs off for `Pool.reclaim_backoff` failed
interns, and a failed intern releases the border set it interned.

The vocabulary (segment bits, named masks, line shapes, shared-edge
pairs, the stroke encoding, the parser) lives in `src/grid/borders.zig`;
nothing else spells a bit or a mask. Pixels come from one renderer,
`src/render/border_pass.zig`, which walks the visible grid (merging needs
the neighbours) and serves CellPass and GridPass rows alike;
`src/render/scene.zig` is the one copy of the paint order.

## Daemon and snapshots

The daemon parses and answers `q` (GUI mirrors are muted); the DCS event
reaches the GUI through the wire unchanged and is applied to its Screen.
Snapshot v13 carries each style entry's border ID and the border-set
table (slot count, then each live slot as ID, segment mask and one
stroke per set bit), validated on restore. A v12 or older body restores
without borders, so old daemons keep working with new GUIs.
