# external/ — reference implementations (not committed)

Shallow clones of Kitty and WezTerm, kept here as test references and
for porting their conformance tests. The whole directory is in
`.gitignore` — nothing here ships.

## Re-clone

```
mkdir -p external && cd external
git clone --depth 1 https://github.com/kovidgoyal/kitty.git
git clone --depth 1 https://github.com/wez/wezterm.git
```

## Where the test material lives

### Kitty

`external/kitty/kitty_tests/` — Python test suite. The pattern that
maps cleanly to our Zig tests:

```python
def test_simple_parsing(self):
    s = self.create_screen()
    pb = partial(self.parse_bytes_dump, s)
    pb('12', '12')
    self.ae(str(s.line(0)), '12')
```

Build a screen, feed bytes, assert on observable state. We mirror this
in `src/parser/conformance_test.zig` via the `Harness` helper:

```zig
var h = try Harness.init(std.testing.allocator, 5, 4);
h.feed("12");
const r = try h.line(std.testing.allocator, 0);
try std.testing.expectEqualStrings("12", r);
```

Files worth porting (in priority order):

- `parser.py` — the canonical battery; we've ported a sample. Big.
- `keys.py` — keyboard encoding (DECCKM, modifyOtherKeys, F-keys with mods).
- `mouse.py` — mouse-mode 1000/1002/1003/1006 sequences.
- `graphics.py` — kitty graphics protocol (image_id, deletion).
- `notifications.py` — OSC 9 / 99 / 777 notification dispatch.
- `clipboard.py` — OSC 52 round-trip.
- `multicell.py` — wide-char + grapheme handling.
- `fonts.py` — won't port; HarfBuzz isn't wired yet.

### WezTerm

`external/wezterm/term/src/test/` — Rust integration tests.

- `csi.rs` — CSI dispatch with `k9::snapshot!` for full-state diff.
- `c0.rs`, `c1.rs` — control character handling.
- `selection.rs` — selection model (commented out in their tree pending render-layer port).

WezTerm's tests use whole-screen snapshots which are noisy to port
verbatim — pick the bug-regression tests (`#[test] fn test_<issue>`)
and write minimal asserting-the-fix versions in our style.

## Running their suites (optional, requires their toolchains)

Kitty: `cd external/kitty && python test.py` (needs CPython + their
build pre-compiled — non-trivial).

WezTerm: `cd external/wezterm && cargo test -p wezterm-term` (needs
recent stable Rust).

We don't depend on either; they're for cross-reference only.
