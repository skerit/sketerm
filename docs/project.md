# The editor's project layer

What turns a set of open files into a development environment: a
project model, project-wide search and replace, a symbol outline, a
per-line VCS gutter, and session restoration.

Everything here works for REMOTE documents, because everything here is
a job the `sketerm-mux` daemon runs on the FILE'S OWN HOST. The GUI
never touches a disk and never runs a process.

```
src/editor/project.zig    root discovery + the project set        GTK-free
src/editor/psearch.zig    search results + the replace planner    GTK-free
src/editor/gitdiff.zig    unified-diff -> anchored gutter marks   GTK-free
src/editor/outline.zig    symbol list, LSP or tree-sitter fed     GTK-free
src/ui/editorproj.zig     the daemon jobs + the search panel      GTK
src/ui/editoroutline.zig  the outline panel                       GTK
```

The four GTK-free modules are in BOTH test roots.

---

## 1. The project model

A project is a `(host, root)` pair. `root` is the nearest ancestor of
the document's directory that holds a MARKER file.

Discovery reuses `lsp/servers.zig`'s `findRoot` machinery rather than
inventing a second scheme. Two differences:

* the marker LIST is a superset — every VCS directory (`.git`, `.hg`,
  `.svn`, `.jj`) plus the language markers the built-in servers already
  name (`build.zig`, `Cargo.toml`, `package.json`, `go.mod`,
  `pyproject.toml`, `CMakeLists.txt`, …), configurable with
  `editor_project_markers`;
* a MISS answers `null` instead of falling back to the document's own
  directory. A loose file therefore has NO project, and every
  project-scoped feature is simply off for it. That is what keeps
  opening one file exactly as cheap as it was: no jobs are started, no
  panels change, nothing is resolved.

**Nearest marker wins.** In a monorepo with `~/w/.git` and
`~/w/sub/package.json`, a file under `sub/` belongs to `~/w/sub`. The
walk stops at the first directory holding ANY marker, so the order of
the marker list never decides anything.

### Several documents in different roots

An editor face holds a **`project.Set`**: as many projects as its open
tabs need, deduplicated by `(host, root)` and refcounted per tab.

* A window has as many projects as its files do — not one.
* Each TAB has at most one project, so there is never a question of
  which root a document belongs to.
* Anything that needs a single root (project search, the git gutter,
  the status label) uses the **active tab's** project, so the answer
  follows the document the user is looking at.
* The same root on two hosts is two projects.

### Relationship to the LSP session root

Deliberately separate. A language server picks its root from its own
`root_files` (`[lsp.<name>] root_files`), because a server's workspace
is narrower and server-specific: clangd wants the directory with
`compile_commands.json`, which may be a build subdirectory. The two
normally coincide (both walk up to `.git`); when they do not, the
project is the USER's unit and the LSP root is the SERVER's.

Nothing in `project.zig` feeds `editorlsp.Manager.attachTab`.
`Project.lspRootHint` exists only so a UI can explain the difference.

### Resolution is asynchronous

Discovery needs one directory listing per ancestor on the file's host,
so it runs on a worker thread (`editorproj.resolveProject`) and lands
through a fenced `g_idle_add`, exactly like the editor's load, save and
disk-probe jobs. One `fsdrive.list` per ancestor, cached — never one
`stat` per marker.

---

## 2. Project-wide search and replace

`Ctrl+Shift+F` (search) and `Ctrl+Shift+H` (search + replace) open the
panel below the canvas. Both shadow the global bindings while the
editor face has focus, the same way `Ctrl+Shift+S` already does.

### grep vs the editor's engine — the honest answer

They are DIFFERENT ENGINES and there is no pretending otherwise:

| | daemon `grep` verb | editor `search.zig` |
|---|---|---|
| pattern | literal substring | literal or regex |
| case | always insensitive | `Aa` toggle |
| whole word | no | `␣W` toggle |
| unit | line | byte range |
| skips | binary files, files over its size cap | nothing |
| caps | matches per file, matches total, line length | none |

So **grep chooses which FILES to read, and nothing else.** Every hit
the user sees and every byte a replace writes comes from running the
editor's own engine over the file's real content. A project search
therefore means precisely what the same query means in the open buffer
— which is what makes replace safe.

`psearch.literalSeed` extracts the literal every match must contain and
hands THAT to grep. It is deliberately conservative: only literal runs
at nesting depth zero count, a run loses its last character to a
following `?`, `*` or `{`, and an alternation anywhere disqualifies the
pattern. When there is no seed (`\w+`), the prefilter is skipped and
the daemon's `find` verb enumerates files instead — slower, and bounded
by `editor_project_search_max_files`.

**The divergence that remains**, and cannot be removed from the GUI
side: the daemon's own caps mean a file that is too big, has too many
matches, or has a very long line can be missing from the CANDIDATE set.
That is reported as a truncated result on the panel's status line, not
swallowed.

### Navigating

Rows are one header per file and one per hit. Activating a hit opens
the file in an editor tab at the hit's line and BYTE column — the
column comes from the editor's own engine, so it lands on the match
rather than on a re-guessed offset.

### Replace: preview, then apply

1. **Preview** re-runs the whole search and computes, per file, the
   full rewritten content plus the file's mtime at that moment.
2. The panel shows which files will be rewritten and how many hits
   each has. Nothing has been written.
3. **Apply**:
   * a file OPEN in a tab is replaced through its Document as ONE
     transaction, so `Ctrl+Z` undoes that file's whole replacement and
     the highlighter, the folds, the outline and the language server
     all see the edit;
   * every other file is written by the same atomic path an ordinary
     `Ctrl+S` uses (temp file + `install` with the expected mtime), so
     a file that changed since the preview is REFUSED, not clobbered.
     The panel says how many were refused.
4. The search re-runs, so the list reflects what is on disk now.

Undo is therefore **per file**, and only for files that were open. That
asymmetry is the reason the preview exists and is not optional.

---

## 3. Symbol outline

`Ctrl+Shift+O` toggles the panel beside the canvas.

Two sources, never three:

* **`textDocument/documentSymbol`** whenever a server is attached and
  advertises the capability;
* **the Tree-sitter tree** the highlighter already keeps otherwise.

The tree answer is filled in FIRST and replaced when (if) the server
answers, so the panel is never blank while a request is in flight. A
server that errors falls back to the tree silently — a missing server
is never a dialog.

The tree walker has a per-language table of symbol node types and of
bodies it refuses to descend into (`block` in Zig, `compound_statement`
in C), which is what keeps a function's local variables out of the
outline and the walk cheap. Zig's `const Foo = struct {…}` is resolved
through its wrapper, so `Foo` shows as a struct with its fields and
methods nested under it.

**No flicker.** Rows are rebuilt only when `Outline.signature()` — a
hash of names, kinds and depths, NOT of ranges — changes. Typing inside
a function changes every range and no name, so the list stays put while
the ranges are carried through the edit by `Outline.mapThrough`.
Following the caret then only moves the SELECTION.

`Ctrl+Shift+O` used to raise a transient document-symbol popup. The
panel is the same data in a form you can keep open, and it works
without a server, so it took the chord; the popup path now serves
workspace symbols (`Ctrl+T`) only.

---

## 4. The git change gutter

Added / modified / deleted markers at the gutter's RIGHT edge (the
diagnostic stripe owns the left one, and a line can carry both).
`F7` / `Shift+F7` step between hunks. `editor_git_gutter` switches it
off, and off means no job is ever started.

### Where the data comes from, and what is missing

The gutter needs the file's COMMITTED content, and:

* `git_status` reports per-FILE status letters. No line information at
  all.
* `diff` diffs two files that both exist on the host. There is no verb
  that materializes a committed blob.

So neither verb can answer this on its own. What the editor does
instead is ask the daemon's **`panelize`** verb — a host-side
`/bin/sh -lc` whose output lines the daemon resolves against a root —
to run, with the repository root as its cwd:

```sh
{ git diff -U0 --no-color --no-ext-diff HEAD -- <rel> ;
  git ls-files --error-unmatch -- <rel> >/dev/null 2>&1 ||
      echo '@@SKETERM-UNTRACKED@@' ; } > <tmp> 2>/dev/null
printf '%s\n' '<tmp>'
```

then reads `<tmp>` back with the ordinary `read` verb and unlinks it.
The process runs on the file's own host, so a remote document gets its
gutter from the remote repository, and the GUI still runs nothing.

**The clean fix is a daemon change we did not make**: a `git_diff` job
verb taking `path` (and optionally a revision) and streaming the
unified diff the way `diff` already streams one would remove the
temp-file dance entirely. It is a tidiness win, not a correctness one —
which is why it was reported rather than done.

### Marks are anchors, not line numbers

A refresh is a round trip; the user keeps typing during it. Each mark
stores the BYTE OFFSET of its line's first byte and is carried through
every edit by `transaction.mapOffset` — the same machinery folds,
selections and diagnostics use, through the same single ETab document
observer. The line a mark paints on is re-derived from its anchor at
draw time, so inserting a line above a hunk moves the hunk down for
free and nothing flickers between refreshes.

`gitdiff.parseUnified` bounds each hunk body by the header's counts, so
a payload line that begins `---` or `diff ` stays payload. A `-` run
immediately followed by a `+` run reads as MODIFIED for as many lines
as both have; the surplus is added, or leaves a deletion tick on the
line that closed the gap.

Refreshed on load, on save, and when a tab becomes active.

---

## 5. Session restoration

Rides `layout.zig`'s existing `PaneSpec.editor` (`editor/model.zig`) —
there is no parallel store. `FileState` gained two fields:

* `top_line` — the first VISIBLE line. A line, not the editor's
  `(line, wrapped row, px)` anchor: the wrapped row depends on the pane
  width and the soft-wrap flag, so it is meaningless in a pane of a
  different size.
* `project` — the host-qualified root the document belonged to. The
  association is RE-DERIVED from the path on restore (deterministic,
  and the authoritative answer); the recorded value is what the face
  shows until that round trip lands, so a restored window does not
  flash "no project" at every tab.

Both default, so a layout file written before this change restores.

### Restore vs recover — the rule

> **The layout decides WHICH files are open. The crash journal decides
> their CONTENT.**

Recovery runs from `attach`, before the restore opens anything, so a
recovered buffer already occupies its spec's tab; `openSpec`'s
dedupe-by-spec then makes the restore FOCUS that tab instead of opening
a second one, and the unsaved bytes win over the on-disk copy.
`recoverOne` additionally ADOPTS an existing tab for its spec
(orphaning that tab's in-flight load) rather than opening a new one, so
the two cannot produce duplicates whichever order they run in.

An unsaved buffer is still never written to the layout — `paneState`
persists paths, carets and scroll only, exactly as before.

---

## Config

All app-level, next to `editor_lsp` and for the same reason: a project
is a property of the filesystem, not of the pane profile a file happens
to be open under. All four are on the Editor page of Preferences.

| key | default | meaning |
|---|---|---|
| `editor_project_markers` | *(empty)* | comma-separated root markers; empty = the built-in list |
| `editor_git_gutter` | `true` | per-line VCS markers + `F7` hunk navigation |
| `editor_outline` | `false` | open the outline panel with every editor face |
| `editor_project_search_max_files` | `4000` | cap on files one project search may read |

## Keys

| chord | action |
|---|---|
| `Ctrl+Shift+F` | find in project |
| `Ctrl+Shift+H` | find and replace in project |
| `Ctrl+Shift+O` | toggle the outline panel |
| `F7` / `Shift+F7` | next / previous change hunk |
