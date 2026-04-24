# sketerm

A native GTK4 terminal emulator for Linux, written in Zig from
scratch.

Built around a feature set that no single existing terminal
emulator satisfies: full image-protocol support (Sixel + Kitty +
iTerm2), real xdg_popup context menus with first-class
split/tab/rename actions, stable group-named tabs, layout
persistence — without being Electron, without being a
multiplexer-in-a-terminal, and without being VTE-based (which on
current Arch lacks OSC 52).

## Philosophy

Own the stack. Read existing implementations closely —
understand the algorithms — then reimplement cleanly in our own
code. No vendored terminal cores, no wrapper crates around other
people's emulator libraries. The escape-sequence specs are public,
the image-protocol specs are public, and Paul Williams documented
the state machine forty years ago. There is no magic here, only
craft.

External dependencies are limited to system C libraries every
Linux terminal depends on:

- `gtk4` + `libadwaita` — windowing, tabs, splits, popover menus
- `freetype` + `harfbuzz` — glyph rasterization + text shaping
- OpenGL ES + `libepoxy` — grid rendering
- `lua` — plugin scripting (post-v1)
- `glib` — event loop (ships with gtk)

## Status

**Planning.** No code yet. See [`docs/`](docs/).

## Documentation

**Start here**
- [Plan](docs/plan.md) — goals, non-goals, v1 hard requirements,
  success criteria
- [Architecture](docs/architecture.md) — module layout, data flow,
  design decisions
- [Milestones](docs/milestones.md) — phased execution plan

**Deep-dives**
- [GPU / GL](docs/gpu.md) — `GtkGLArea` lifecycle, context share
  groups, fractional scaling, driver notes
- [Images](docs/images.md) — unified placement model for Sixel,
  Kitty, iTerm2
- [Layout persistence](docs/layout.md) — save/restore design,
  trust model
- [Lifecycle](docs/lifecycle.md) — PTY spawn, workers, signals,
  teardown
- [Config](docs/config.md) — config file schema, keybinding model
- [Testing](docs/testing.md) — parser fixtures, record/replay,
  differential diffing, fuzzing, benchmarks

**Reference**
- [Protocols](docs/protocols.md) — escape sequences supported
- [References](docs/references.md) — specs and study targets
- [Risks](docs/risks.md) — risks and mitigations

## License

TBD.
