# Layout persistence

Save/restore of tab/split/pane layouts. Supplements `milestones.md`
M8 and `plan.md` requirement 7. `lifecycle.md` covers how restored
panes actually spawn processes.

## Scope

A layout is a **topology + launch-intent snapshot.** It preserves
the skeleton, not the session.

### Preserved

- Tab tree (ordered list of tabs)
- Per-tab sticky title
- Per-tab split tree (nested horizontal/vertical splits with ratios)
- Per-pane cwd
- Per-pane initial command (argv)
- Schema version

### Not preserved

- Scrollback contents
- Cursor position, selection, bracketed-paste state
- Environment variables
- Running job / shell state / aliases / history
- Clipboard contents
- Font or color overrides per pane (v1 uses window-global font)
- Images currently displayed (ImageStore state)

## Rationale

Session state cannot round-trip reliably. Scrollback is large and
often sensitive (credentials in command output). Env variables
contain tokens and sockets that are session-specific. Running
jobs cannot be serialized. Shell-managed state (history, aliases)
is the shell's responsibility — sketerm stays out of it.

The layout is a starting point. Shell init files (`.bashrc`,
`.zshrc`), tmux / direnv / starship, and similar restore whatever
per-session state the user wants.

## File format

ZON (Zig Object Notation). Chosen because:

- Native — no external parser dependency.
- Human-readable and human-editable.
- Comment support.
- Zig struct literals round-trip cleanly.

### Example

```zig
.{
    .version = 1,
    .tabs = &.{
        .{
            .title = "Editor",
            .tree = .{ .split = .{
                .orientation = .vertical,
                .ratio = 0.6,
                .first  = .{ .pane = .{
                    .cwd = "/home/user/projects/sketerm",
                    .command = &.{ "nvim", "." },
                }},
                .second = .{ .pane = .{
                    .cwd = "/home/user/projects/sketerm",
                    .command = &.{ "bash" },
                }},
            }},
        },
        .{
            .title = "Logs",
            .tree = .{ .pane = .{
                .cwd = "/var/log",
                .command = &.{ "bash", "-c", "journalctl -fe" },
            }},
        },
    },
}
```

## Schema

```zig
pub const Layout = struct {
    version: u32,       // current: 1
    tabs: []const Tab,
};

pub const Tab = struct {
    title: []const u8,
    tree: Tree,
};

pub const Tree = union(enum) {
    pane: Pane,
    split: Split,
};

pub const Split = struct {
    orientation: enum { horizontal, vertical },
    ratio: f32,         // 0.0–1.0, first/total
    first: *const Tree,
    second: *const Tree,
};

pub const Pane = struct {
    cwd: []const u8,                 // absolute path
    command: []const []const u8,     // argv; [0] is exec target
};
```

## Schema versioning

`version` starts at 1. Loader policy:

- **Equal**: load directly.
- **Lower**: run in-order migrations (each migration is a function
  `v_N_to_N+1(Layout) Layout`; documented in `docs/MIGRATIONS.md`
  when we first bump).
- **Higher**: error — *"layout requires sketerm ≥ vX; upgrade"*.

When to bump:
- Field removed or renamed
- Field semantics changed (e.g. `ratio` meaning reversed)
- Tree shape changed

Additive optional fields with safe defaults do not require a bump.

## Save triggers

| Trigger                            | Destination                                   |
|------------------------------------|-----------------------------------------------|
| *Save Layout…* menu action         | User-chosen path via `GtkFileChooserNative`   |
| App shutdown (clean exit)          | `$XDG_STATE_HOME/sketerm/last.zon`            |
| `--save-on-exit=<path>` CLI flag   | Given path, overrides auto destination        |

Crash (uncaught signal) does **not** save. Users get the last
clean save via `--restore`.

## Load triggers

| Trigger                          | Behavior                                        |
|----------------------------------|-------------------------------------------------|
| `--layout <path>`                | Load from path, error if missing/invalid        |
| `--restore`                      | Load `$XDG_STATE_HOME/sketerm/last.zon` if exists; else default 1-pane |
| *Open Layout…* menu action       | Opens file chooser; replaces current window's tabs (confirm prompt if unsaved) |

## Degraded-load behavior

The loader is tolerant — a layout should open even if individual
panes can't fully realize.

### Binary not found on PATH

```
Policy:
    1. Still create the pane.
    2. Spawn $SHELL (fallback: /bin/sh).
    3. Print to pane grid, dim colour:
       [sketerm: command 'foo' not found; started $SHELL]
```

Rationale: user can investigate and relaunch manually from inside
the pane.

### cwd does not exist

```
Policy:
    1. Fall back to $HOME.
    2. Fall back to / if $HOME is unset.
    3. Print to pane grid:
       [sketerm: cwd '/tmp/gone' not accessible; started in /home/user]
    4. Continue pane load.
```

### cwd exists but permission denied

Treated identically to nonexistent cwd.

### Child exits immediately

Command exec succeeded but child returned non-zero (or zero)
quickly. Per `plan.md` shell-exit-handling policy:

```
    [process exited with status N]
```

Pane stays open by default (`hold-on-exit = true` config).
Closing pane is a manual action.

### Malformed ZON file

Whole-layout error. Prompt user with file path + Zon error
location. Do not auto-fallback — user may want to fix the file
rather than lose it silently.

### version > CURRENT

Whole-layout error with explicit message.

## Environment policy

Layouts never store `env`. At load time, each restored pane's
child inherits:

- The sketerm parent process's env
- Plus sketerm-set vars:
  - `TERM=sketerm-256color` (fallback `xterm-256color`)
  - `COLORTERM=truecolor`
  - `TERM_PROGRAM=sketerm`
  - `TERM_PROGRAM_VERSION=<version>`
  - `COLUMNS`, `LINES`

Shell init files configure user-specific env.

## Path handling

- All paths UTF-8. No normalization applied.
- **Absolute paths required.** Relative paths in `cwd` are
  rejected at load time with a diagnostic. Rationale: relative
  resolution against the process cwd at load time is surprising;
  resolution against the layout-file directory is magical; better
  to disallow and keep behavior unambiguous.
- No home expansion (`~/foo` stays literal and is treated as a
  missing directory). Users should write absolute paths;
  sketerm's own save path always writes absolute.
- ZON string escape rules are the standard.

## Atomic save

To prevent mid-write corruption:

1. Serialize in memory.
2. Write to `<target>.tmp`.
3. `fsync(tmp_fd)`.
4. `rename(tmp, target)` — atomic on same filesystem.

`$XDG_STATE_HOME/sketerm/` is created with mode 0700 if absent.

## Size limits

- Max **file size**: 1 MB. Larger rejected outright — legitimate
  layouts are single-digit KB.
- Max **tabs per layout**: 64
- Max **nesting depth**: 16
- Max **panes per tab**: 32 (note: `architecture.md` D9 has a
  per-window soft limit of ~32 panes total for rendering reasons;
  a layout with many panes may load but render sluggishly — the
  caps in this doc are *storage* caps, D9 is the *rendering* ceiling).
- Max **argv length**: 64 args, 4 KB total bytes
- Max **cwd length**: 4 KB
- Max **tab title length**: 256 bytes

Exceeding any limit at load time: diagnostic + layout rejected.
Exceeding at save time: diagnostic + save aborted with "reduce
the layout" suggestion.

## Security / trust model

**Treat layout files as code.** A malicious layout can launch
arbitrary commands on load — just like a malicious `.desktop` file,
tmux-resurrect file, or shell rc file. The attack surface is small
because:

- Loading requires explicit user action (`--layout <path>`,
  `--restore`, or menu *Open Layout…*).
- Auto-load only reads `$XDG_STATE_HOME/sketerm/last.zon`, written
  by sketerm itself.

Guidance:
- Never pipe untrusted layout files to `sketerm --layout -`.
- Never `--layout` a file from an untrusted download without reading
  it first.
- sketerm does not sign layouts in v1; treat files as plaintext.

Defensive behavior:
- No env-var storage (layouts cannot leak tokens).
- File-size cap (1 MB) prevents OOM.
- Command not-found / cwd-invalid → diagnostic, not crash.
- Loader bounded by the size limits above.

Post-v1: consider a "quarantine" mode that wraps spawned panes
in a confirmation prompt when loaded from a layout file outside
`$XDG_STATE_HOME/sketerm/`.

## CLI reference

```
--layout <path>          Load from specific path at startup
--restore                Load last.zon from XDG_STATE_HOME
--save-on-exit <path>    Override auto-save destination
--no-save                Disable auto-save
```

## Future extensions (post-v1, non-binding)

- Per-pane font size / color palette
- Named layout presets (`sketerm --preset editor`)
- Include / composition (one layout embeds another)
- Partial load (single tab from multi-tab file)
- Event hooks: run a shell command after restore
- Per-pane environment overlays (allow-listed keys only)
