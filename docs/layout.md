# Layout persistence

Save/restore of tab/split/pane layouts. The model is
`src/layout.zig` (the schema and the file IO) and
`src/ui/winlayout.zig` (collect from / rebuild into the window).
`lifecycle.md` covers how restored panes actually spawn processes.

## Scope

A layout is a **topology + launch-intent snapshot.** It preserves
the skeleton, not the session.

### Preserved

- Tab tree (ordered list of tabs), each with its sticky title,
  pinned flag, colour swatch, title-locked flag and the per-tab
  `show_activity` / `warn_inactive` toggles
- Tree-style tab nesting: each tab's parent tab (`tree_parent`) and
  whether its subtree was folded away (`collapsed`)
- Per-tab split tree (nested horizontal/vertical splits with ratios)
- Per-pane cwd and initial command (argv)
- Per-pane profile name, font-size override, and shader pick
  (preset name, explicit path, or a sticky "cleared")
- Per-pane durable mux session name and transport host
- Browser-face state (its internal tabs) and editor-face state
  (open file specs, active index, cursor offsets)
- Web-face state: every page of the pane's browser group in strip
  order, with its address, page zoom, scroll offset, identity
  container and tree-style parent page, plus which page was showing
- Schema version

### Not preserved

- Scrollback contents
- Cursor position, selection, bracketed-paste state
- Environment variables
- Running job / shell state / aliases / history
- Clipboard contents
- Images currently displayed (ImageStore state)
- Unsaved (dirty) editor buffers - by design; see
  `src/editor/model.zig`

## Rationale

Session state cannot round-trip reliably. Scrollback is large and
often sensitive (credentials in command output). Env variables
contain tokens and sockets that are session-specific. Running
jobs cannot be serialized. Shell-managed state (history, aliases)
is the shell's responsibility — sketerm stays out of it.

The layout is a starting point. Shell init files (`.bashrc`,
`.zshrc`), tmux / direnv / starship, and similar restore whatever
per-session state the user wants.

The exception is a pane with a `mux_session`: the layout stores only
the session NAME, but reattaching to a session the daemon still owns
brings back the live process and its scrollback. Durability is the
daemon's job, not the layout file's.

## File format

**JSON**, written with `std.json.Stringify` and read with
`std.json.parseFromSlice`. Not ZON: the schema carries optional and
nullable fields that std's JSON round-trips directly, and
`ignore_unknown_fields` gives forward compatibility for free.

### Example

```json
{
  "version": 2,
  "tabs": [
    {
      "title": "Editor",
      "tree": {
        "split": {
          "orientation": "vertical",
          "ratio": 0.6,
          "children": [
            { "pane": { "cwd": "/home/user/projects/sketerm",
                        "command": ["nvim", "."] } },
            { "pane": { "cwd": "/home/user/projects/sketerm",
                        "command": ["bash"] } }
          ]
        }
      }
    }
  ]
}
```

## Schema

Current: **version 2** - every tab carries a recursive `Tree`.
Abbreviated (see `src/layout.zig` for the full `PaneSpec`):

```zig
pub const Layout = struct {
    version: u32 = 2,
    tabs: []const TabSpec,
};

pub const TabSpec = struct {
    title: []const u8,
    tree: Tree,
    pinned: bool = false,
    color: ?[]const u8 = null,      // "#RRGGBB"
    title_locked: ?bool = null,
    show_activity: bool = true,
    warn_inactive: bool = false,
    tree_parent: ?u32 = null,       // index into `tabs`; null = root
    collapsed: bool = false,        // subtree folded in tree-style tabs
};

pub const Tree = union(enum) { pane: PaneSpec, split: SplitSpec };

pub const SplitSpec = struct {
    orientation: Orient,            // horizontal | vertical
    ratio: f32,                     // 0.0-1.0, first/total
    children: []const Tree,         // length must be 2
};

pub const PaneSpec = struct {
    cwd: []const u8,
    command: []const []const u8,    // argv; [0] is the exec target
    font_size: ?u16 = null,
    profile: []const u8 = "",
    custom_shader: []const u8 = "",
    shader_preset: []const u8 = "",
    shader_cleared: bool = false,
    mux_session: []const u8 = "",
    mux_host: []const u8 = "",
    browser: ?browser_model.PaneState = null,
    editor: ?editor_model.PaneState = null,
    web: ?web_model.PaneState = null,
    // plus `browser_tabs`, the compatibility reader for layouts
    // written by the first browser prototype.
};
```

### Tree-style tab nesting

`tree_parent` is the index, in this file's `tabs` array, of the tab a
tab nests under; `null` makes it a root. Indices name SAVED positions,
which is why `collectLayout` records the pages it actually serialised
(a tab with no restorable pane is skipped, so a view position is not an
array index). On load a parent index that is out of range, points at
the tab itself, or would close a cycle leaves the tab a root rather
than failing the load. `collapsed` restores the fold. A file written
before tree-style tabs existed has neither field, so every tab loads as
a root, flat, exactly as it was saved.

### Web-face state

`web` is `src/web/model.zig`'s `PaneState`: `pages` lists every page
of the pane's browser group in strip order, each a `PageState` with its
`url`, `zoom_level_x100` (a CEF zoom LEVEL x100, not a percentage),
`scroll_x`/`scroll_y` in the engine's own units, `container` (the
identity container id the daemon's web store persists; one it no longer
has restores in the default jar) and `parent` (index of its parent page
for tree nesting, -1 for a root). `active_page` indexes the page that
was showing. The top-level `url`, `zoom_level_x100` and `container`
duplicate the active page so a build that knows only one page per pane
still restores the right one; a layout written before pages existed has
an empty `pages` and restores from those fields alone. Scroll offsets
are replayed uninterpreted, so a restore lands where the save happened.

## Schema versioning

The loader does not branch on `version` today. Compatibility comes
from the two mechanisms in the code instead:

- `ignore_unknown_fields = true`, so a file from a newer sketerm
  loads with its unknown fields dropped rather than failing.
- Every field added since v2 carries a default, so an older file
  parses and the missing fields take the default. The defaults are
  chosen to reproduce the old behaviour (e.g. `title_locked = null`
  means "treat restored titles as renamed", which is what pre-field
  files did).

There is no v1 reader: v1 (a flat cwd/command per tab) was never
released, so v2 is the oldest shape any user has on disk.

A real bump would be needed if a field's SEMANTICS changed or the
tree shape changed; adding optional fields with safe defaults, as
above, does not need one.

## The three files

`src/layout.zig` names two well-known paths under
`$XDG_STATE_HOME/sketerm/` (falling back to `~/.local/state/...`,
then `/tmp`), plus whatever the user picks explicitly:

| Path             | Written by                                  | Read by                               |
|------------------|---------------------------------------------|---------------------------------------|
| `last.json`      | auto-save on clean exit, and the `save_layout` action | `--restore`                  |
| `default.json`   | the `save_default_layout` action            | startup, when neither flag was passed |
| any path         | the `save_layout_as` action                 | `--layout <path>` / `load_layout`     |

Crash (uncaught signal) does not save. `--no-save` disables the
auto-save entirely, and it is skipped for `files` and `web` mode
windows.

## Load triggers

| Trigger                    | Behavior                                                        |
|----------------------------|-----------------------------------------------------------------|
| `--layout <path>`          | Load from path; on failure log to stderr and continue empty      |
| `--restore`                | Load `last.json` if present, else the normal default window      |
| neither flag               | Load `default.json` if present, else the normal default window   |
| `load_layout` action       | File chooser, then the same path as `--layout`                   |

`--layout` also accepts the `.layout` text format (dispatched on the
extension): an indent-based, comment-supporting alternative parsed
by `src/layout_simple.zig`, meant to be written by hand.

```
Dev
  hsplit
    pane bash @ /tmp
    pane fish @ /home
```

## Degraded-load behavior

The loader is tolerant in the sense that one bad tab or pane does
not stop the rest: `newTabFromSpec` failures are logged to stderr
and the loop continues. Beyond that, the behaviour is what the
spawn path does, not a layout-specific policy:

- **Binary not found on PATH** - `execvp` fails in the child, which
  writes `sketerm: execvp failed` and `_exit(127)`. The pane shows
  `[process exited with status 127]` and then follows `exit_action`
  (default `close`; `--hold` or `exit_action = hold` keeps it).
  There is no `$SHELL` fallback and no separate diagnostic line.
- **cwd missing or unreadable** - the `chdir` simply fails and the
  child starts in the inherited working directory. No message.
- **Durable mux pane whose session cannot be restored** - logged,
  then a plain local shell is spawned in its place. Remote mux panes
  never block startup: they get a local placeholder and reattach
  asynchronously via `startMuxRestoreJob`, because connecting over
  ssh/udp on the main loop would freeze the GUI.
- **Malformed JSON, unreadable file, or file over 1 MB** - the whole
  load fails with a stderr diagnostic; nothing is overwritten, so
  the file can be fixed by hand.
- **Split with fewer than 2 children** - `error.InvalidLayout`; a
  ratio outside (0,1) is silently replaced with 0.5.

## Environment policy

Layouts never store `env`. A restored pane's child gets exactly the
same environment as any other pane: the daemon process's env plus
the vars `pty.zig` sets. `protocols.md` has that list; the layout
adds nothing to it.

Shell init files configure user-specific env.

## Path handling

- All paths UTF-8. No normalization applied.
- **Absolute paths expected but not validated.** `paneSpec` writes
  the OSC 7 cwd the shell reported, or `"/"` when it reported none,
  so saved paths are absolute. A hand-written relative `cwd` is not
  rejected at load: the `chdir` is simply attempted and, failing,
  the pane starts in the inherited directory.
- No home expansion (`~/foo` stays literal and is treated as a
  missing directory). Users should write absolute paths;
  sketerm's own save path always writes absolute.
- JSON string escape rules are the standard.

## Atomic save

`layout.save` (in `src/layout.zig`):

1. `makeParentDirs` - each component `mkdir`ed 0755, existing
   directories left alone.
2. Serialize into a fixed 16 KB buffer with
   `std.json.Stringify.value` (indent 2).
3. `fopen`/`fwrite`/`fclose` to `<target>.tmp`.
4. `rename(tmp, target)` - atomic on the same filesystem. A failed
   rename unlinks the temp file.

There is no `fsync` before the rename, so the write survives a crash
of sketerm but is not guaranteed against a machine-level power loss.

## Size limits

Enforced:

- **File size on load**: 1 MB (`error.BadFile` past it). Legitimate
  layouts are single-digit KB.
- **Serialized size on save**: the 16 KB stringify buffer. A layout
  that overflows it fails the save with a stderr diagnostic rather
  than writing a truncated file.
- **Path length**: 4096 bytes for the target path and for a pane's
  cwd (the latter in `pty.zig`, which skips the `chdir` rather than
  truncating).

There are NO caps on tab count, nesting depth, panes per tab, argv
length or title length. `architecture.md` D9's ~32-panes-per-window
figure is a rendering-cost rule of thumb, not something this loader
checks.

## Security / trust model

**Treat layout files as code.** A malicious layout can launch
arbitrary commands on load — just like a malicious `.desktop` file,
tmux-resurrect file, or shell rc file. The attack surface is small
because:

- `--layout <path>` and the `load_layout` action require an explicit
  user action.
- The two auto-loaded paths (`last.json`, `default.json`) live under
  `$XDG_STATE_HOME/sketerm/` and are written by sketerm itself.

Guidance:
- Never `--layout` a file from an untrusted download without reading
  it first.
- sketerm does not sign layouts; treat files as plaintext.

Defensive behavior:
- No env-var storage (layouts cannot leak tokens).
- File-size cap (1 MB) prevents OOM.
- Command not-found / cwd-invalid degrade to an exited or
  differently-rooted pane, not a crash.

## CLI reference

```
--layout <path>          Load from a specific path at startup
                         (.json, or .layout for the text format)
--restore                Load last.json from XDG_STATE_HOME
--no-save                Don't write last.json on exit
--hold                   Keep panes open after their command exits
```

There is no `--save-on-exit`; the auto-save destination is fixed.

## Not implemented

- Named layout presets (`sketerm --preset editor`)
- Include / composition (one layout embeds another)
- Partial load (single tab from a multi-tab file)
- Event hooks: run a shell command after restore
- Per-pane environment overlays
