# Overstrike

sketerm implements mintty's overstrike mode: while it is on, a printed
character is drawn on top of the cell under the cursor instead of
replacing it.

## Supported

- `CSI 8:7 m` turns it on. Only the colon form: `CSI 8;7 m` keeps
  meaning conceal + reverse, and any other `8:N` is ignored whole.
- `CSI 28 m` turns it off (and clears conceal), as do `CSI 0 m` and a
  bare `CSI m`.
- `CSI ? 20 h` / `CSI ? 20 l` set and clear the same flag (DEC VK100
  overstrike). The public mode 20 is still LNM.
- DECRQM `CSI ? 20 $ p` reports it; DECRQSS `m` reports it as `8:7`.
- DECSC/DECRC and modes 1048/1049 save and restore it with the cursor;
  DECRC with nothing saved clears it. DECSTR clears it, RIS clears it
  and the saved copy.

What an overstrike print does, following mintty's `write_char`:

1. A pending autowrap is taken first, but only with autowrap on and
   never for a zero-width codepoint (mintty never wraps for those);
   otherwise the pending wrap is just dropped.
2. The struck cell is the one under the cursor, or the base of the wide
   pair whose right half the cursor is on.
3. The codepoint becomes a layer on that cell, drawn in the CURRENT
   rendition (its own colour, bold, underline, ...). The cell keeps its
   glyph, its rendition and its background. A blank cell keeps its
   blank base and shows just the layer.
4. Insert mode shifts nothing.
5. The cursor advances one column as for a narrow print, wide
   codepoints included, and sets a pending wrap at the right margin.

Every codepoint is a layer in this mode, combining marks included
(mintty forces width 0 and targets the cursor cell, not the previous
one). A wide overstruck codepoint draws from the struck cell's left
edge at its own width, overflowing to the right like any wide glyph.

## Not supported, and limits

- At most 4 layers per cell (`overlay.max_layers`). A fifth overstrike
  drops the OLDEST layer, so the four most recent stay visible.
- mintty precomposes a combining mark with a same-coloured base into
  one codepoint; sketerm always draws the mark as a separate layer.
- Text consumers read only the base character: selection, copy,
  search, URL detection, word motion and accessibility see the cell as
  it was before anything was struck onto it, and an overstruck blank
  copies as blank.
- A layer never paints a background; its own background colour only
  matters as its text colour under reverse video.
- The tmux-style tty mirror does not re-emit layers to an outer
  terminal.

## Storage

A cell's layers are part of its style, like cell borders:
`style_pool.Entry.overlay` is a `u16` ID into `Pool.overlay_table`, a
`grid/slot_table.zig` table of interned layer lists (ID 0 is none; slots
are stable and recycled through a free list). The border-set table is
the same generic table. `Cell` stays 8 bytes and `Cell.rune` stays the
base codepoint.

A layer (`grid/overlay.zig`) is a 128-bit value: the codepoint and a
value copy of the rendition it was drawn with (packed fg, bg, underline
colour, attributes). It names nothing in the pool, so collecting has
nothing nested to root.

An overstrike print re-interns the struck cell's entry with the layer
appended. Every operation that copies a style reference therefore
carries layers for free: scrolling, scrollback, ICH/DCH, reflow, the
alternate screen. `cur_style` and `blankStyle()` never carry a layer
list, so an ordinary print or any erase removes the layers. Reflow
counts a blank cell with layers as content.

The flag itself is cursor state on `Screen` (`overstrike`,
`saved_overstrike`), not a style attribute, so it never multiplies
style entries. Style GC (`compactStylePool`) frees the layer lists no
surviving style uses, through the same reclaim and back-off as border
sets.

## Rendering

Layers belong to the text layer of `render/scene.zig`'s paint order:
above every base glyph, below above-text cell borders. CellPass appends
one instance per layer behind its cell instances; the background draw
covers only the cells, the glyph and decoration draws cover both.
GridPass rows (bidi, complex scripts, DECDWL/DECDHL) draw base glyphs,
then layers, then decorations, the same order. Both resolve a layer's
colour with `style.Resolver.resolveOver`, against the struck cell's
background. With no layer list in the pool neither pass looks.

## Daemon and snapshots

The daemon parses; the SGR sub-parameters and DECSET 20 reach the GUI as
parsed CSI events and are applied to its own Screen. Snapshot v14
carries each style entry's layer-list ID, the layer-list table (slot
count, live count, then each live slot as ID, layer count and one
128-bit layer each, validated on restore) and the two flags. A v13 or
older body restores without layers, so old daemons keep working with
new GUIs.
