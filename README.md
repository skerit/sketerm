# sketerm

A native GTK4 terminal emulator for Linux, written in Zig from scratch,
that grew a session daemon, remote and headless GUI-app display, a file
manager, a text editor, a browser, and an MCP server so AI assistants
can drive all of it.

No vendored terminal core, no wrapper crates: the VT parser, screen
model, glyph atlas and GL renderer are all in-tree. Full image-protocol
support (Sixel, Kitty graphics, iTerm2), real xdg_popup context menus,
tree-style tabs, splits, layout persistence, durable sessions that
survive a GUI restart -- without being Electron, without being a
multiplexer-in-a-terminal, and without being VTE-based.

## Philosophy

Own the stack. Read existing implementations closely, understand the
algorithms, then reimplement cleanly in our own code. The escape-sequence
specs are public, the image-protocol specs are public, and Paul Williams
documented the state machine forty years ago. There is no magic here,
only craft.

External dependencies are system C libraries:

- `gtk4` + `libadwaita` -- windowing, tabs, splits, popover menus
- `freetype2` + `harfbuzz` + `fontconfig` + `fribidi` -- glyphs, shaping, bidi
- OpenGL ES via `libepoxy` -- grid, cell, image and shader passes
- `libvpx` -- VP9/WebM app-window recording (GUI only)
- `cef` -- OPTIONAL, linked only by the browser helper `sketerm-webengine`
- `tesseract` -- OPTIONAL, OCR for the MCP `app_read_text`/`app_wait_text` tools

Vendored: `stb_image`/`stb_image_write`/`msf_gif` (image + GIF encode) and
a Tree-sitter runtime with generated grammars (editor highlighting,
compiled into the GUI only). The session daemon links **libc only**.

## What ships

Three binaries:

- **`sketerm`** -- the GUI, plus the `cli`, `mcp`, `mux`, `ssh`, `run`,
  `app`, `files`, `edit`, `web`, `view`, `play`, `mount`, `portal` and
  `doctor` subcommands (`sketerm --help` lists them all). `sketerm-files`,
  `sketerm-editor`, `sketerm-viewer` and `sketerm-web` are argv0 identity
  hardlinks of the same binary: each mode is its own desktop application
  with its own app id, icon and taskbar entry.
- **`sketerm-mux`** -- the session daemon. Every terminal, local or
  remote, is a session it owns; the GUI is always a client. It also hosts
  headless Wayland displays, forwarded GUI apps, the file service, and
  the broker that keeps everything alive across GUI restarts.
  `zig build mux-portable` produces a static-musl build to scp onto a
  server.
- **`sketerm-webengine`** -- the optional CEF browser helper, kept in its
  own process for crash isolation. Without it the browser face says so
  and everything else keeps working.

## Features

**Terminal.** Truecolor SGR with all line decorations, Sixel + Kitty +
iTerm2 images rendered through the GL pipeline, OSC 8 hyperlinks, OSC 52
clipboard, Kitty keyboard protocol, bracketed paste, focus reporting,
OSC 133 prompt marks (jump between prompts), scrollback search with
regex and smart-case, hint mode, copy mode, cell and background shaders
with presets, bidi/complex-script shaping, IME through GtkIMMulticontext,
dead keys, and a `sketerm-256color` terminfo.

**Workspace.** Tabs with sticky titles, colours and pins, a tree-style
tab sidebar, nestable splits with zoom, a command palette, layouts saved
as JSON and restored with `--restore`/`--layout`, a Quake-mode
`--toggle`, per-profile settings bundles, live config reload, and a
preferences dialog.

**Sessions and remote.** Terminals are daemon sessions that survive a
GUI crash or restart (`sketerm mux` picks them up). `sketerm ssh <host>`
opens a durable remote shell on the host's own daemon with automatic
reattach; transport is encrypted roaming UDP with hole punching when
reachable and SSH otherwise. `sketerm mount` FUSE-mounts a remote host's
files; `sketerm app <host> <cmd>` runs a GUI app on another machine and
renders its windows here.

**Headless GUI.** `sketerm run <cmd>` runs a GUI app against a private
Wayland display with no screen at all (the Xvfb replacement, rootless
X11 via Xwayland when installed); `sketerm-mux display create` makes
persistent ones. Apps can be screenshotted, driven, recorded and
inspected over AT-SPI from the MCP tools or from Zig.

**File manager, editor, viewer, browser.** `sketerm files` is a file
manager (local or `host:/path`, every file operation goes through the
daemon) that can also be the default `inode/directory` handler.
`sketerm edit` is a text editor with Tree-sitter highlighting, multiple
carets, a project layer and a Language Server Protocol client.
`sketerm view` shows images, `sketerm play` plays asciicast recordings,
`sketerm web` is a Chromium-based browser (via CEF) with a reader mode,
a built-in ad filter, identity containers, and a network route per tab
(direct, Tor, via one of your SSH hosts, or the browser running on that
host) with cookies shared across routes. Every one of these also works
as a *face* on a pane inside a terminal window (`--here`/`--tab`).

**MCP server.** `sketerm mcp` is a Model Context Protocol server on stdio
with 120 tools in eight groups (`panes app term files net browser ui
core`): read and type into terminals, run commands and wait for them,
launch and drive GUI apps headlessly with screenshots, pixel diffs,
hover maps and backtraces, transfer files and forward ports over SSH,
browse the web headlessly in named cookie-jar profiles under an
enforced network policy, and render native panels from a declarative
document. Whatever an assistant does is watchable from your own window
by default: a chip in the tab bar lists live assistants and their
browsers, terminals and apps, one click watches, another takes control.
A per-connection tool policy narrows what each assistant gets;
`capabilities` is the preflight that names every capability the server
has. See `docs/mcp.md`.

**Portal.** `sketerm portal` is an opt-in xdg-desktop-portal FileChooser
backend, so any portal-using app gets the native sketerm picker
(`docs/portal.md`).

## Build, install, run

Zig **0.16** is required. The default optimize mode is `ReleaseFast`
(`Debug` does not link on Arch + gcc 15). `zig build --help` lists every
step with a description.

```bash
zig build                      # GUI + daemon into zig-out/bin
zig build mux                  # sketerm-mux only (no GTK needed)
zig build mux-portable         # static-musl daemon for remote hosts
zig build fetch-cef && zig build web   # the optional browser helper

zig-out/bin/sketerm            # opens a tab in $SHELL
zig-out/bin/sketerm --restore  # rebuild the last saved layout
zig-out/bin/sketerm doctor     # daemon/version/socket/terminfo check
```

To install, `cd dist && ./install.sh`: Arch-compatible hosts go through
the PKGBUILD (`makepkg -sif`), dpkg hosts get a `.deb`, anything else a
plain prefix install. `--mux-only` builds just the daemon, `--deps`
installs build dependencies, `--no-install` only builds the package.
Five desktop entries and icons are installed (terminal, files, editor,
viewer, browser).

Config lives at `~/.config/sketerm/config.conf` (see `data/sample.conf`
and `docs/config.md`); saving it applies immediately.

## Keybindings (built-in, all rebindable)

| Shortcut               | Action                             |
|------------------------|------------------------------------|
| `Ctrl+Shift+T` / `W`   | New tab / close tab or pane        |
| `Ctrl+Tab`, `Alt+1..9` | Next tab, jump to tab N            |
| `Ctrl+Shift+D` / `R`   | Split horizontal / vertical        |
| `Ctrl+Shift+Left/Right`| Cycle focus between panes          |
| `Ctrl+Shift+C` / `V`   | Copy / paste                       |
| `Ctrl+Shift+F`         | Scrollback search                  |
| `Ctrl+Shift+E`         | Hint mode                          |
| `Ctrl+Shift+P`         | Command palette                    |
| `Ctrl+Shift+Up/Down`   | Previous / next prompt             |
| `Ctrl+Shift+Z`         | Re-open last closed tab            |
| `Ctrl+Shift+S`         | Save layout                        |
| `Ctrl+Shift+Alt+B`     | Tree-style tab sidebar             |
| `Ctrl+=` / `-` / `0`   | Font size                          |
| `Ctrl+,`               | Preferences                        |

`sketerm --help` prints the full list; `keybind.<action>` in the config
rebinds any of them (`docs/config.md`).

## Tests

```bash
zig build test        # unit tests (GUI build)
zig build test-core   # GTK-free subset, same deps as sketerm-mux
zig build smoke-e2e   # real GUI on sketerm's own compositor, no X
zig build smoke-mux   # daemon end to end; also smoke-mcp, smoke-fs,
                      # smoke-web, smoke-broker, smoke-lsp-gui, ...
```

GUI tests run on sketerm's own headless Wayland display, never under
Xvfb. See `docs/testing.md`.

## Documentation

**Start here**
- [Architecture](docs/architecture.md) -- module tree, data flow, design decisions
- [Config](docs/config.md) -- complete `config.conf` reference
- [Remote sessions](docs/REMOTE.md) -- `sketerm-mux`, SSH/UDP transports, reattach
- [MCP tools](docs/mcp.md) -- the assistant-facing tool set
- [Headless displays](docs/display.md) -- `sketerm run` and persistent displays

**Deep-dives**
- [mux design](docs/mux-design.md) -- durable panes and remote domains
- [GPU / GL](docs/gpu.md) -- `GtkGLArea` lifecycle, share groups, scaling
- [Images](docs/images.md) -- unified placement model for Sixel, Kitty, iTerm2
- [Layout persistence](docs/layout.md) -- save/restore, trust model
- [Lifecycle](docs/lifecycle.md) -- spawn, signals, teardown
- [Editor commands](docs/editor-commands.md), [Project layer](docs/project.md), [LSP](docs/lsp.md)
- [Portal](docs/portal.md) -- the FileChooser backend
- [macOS](docs/macos.md) -- the in-progress port
- [Testing](docs/testing.md) -- fixtures, record/replay, smoke rigs

**Reference**
- [Protocols](docs/protocols.md) -- escape sequences supported
- [References](docs/references.md) -- specs and study targets
- [SESSION](docs/SESSION.md) -- running log of what has landed

## Shell integration

zsh, fish and bash are integrated automatically: sketerm injects the
scripts under `data/shell-integration/` at spawn (`shell_integration =
off` disables it). The integration enables OSC 7 cwd reporting (layouts
remember each pane's directory; new tabs and splits inherit it), OSC 133
prompt marks (prompt jumping, `copy_command_output`), and the
`sketerm_copy` helper that sets the local clipboard via OSC 52 even over
SSH. Each script self-skips when `$TERM_PROGRAM` is not `sketerm`, so
sourcing unconditionally is safe.

## License

GPL-3.0-or-later (see `LICENSE`). Selling copies is permitted; what the
GPL forbids is closed-source redistribution: anyone who distributes
sketerm (modified or not) must provide the source under the same terms.

Shader presets under `data/shaders/` carry per-file licenses (MIT,
public domain, GPL; see `data/shaders/README`); all are compatible with
the GPL-3 core.

The vendored Tree-sitter runtime and grammars under `vendor/tree-sitter/`
(editor syntax highlighting) are MIT, with an ICU-derived unicode
subdirectory; upstream commits, licenses and the layout rationale are
recorded in its `PROVENANCE.txt`.
