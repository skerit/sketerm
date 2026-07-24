# File Browser Roadmap

Untracked design document. Companion to filebrowser-feature-inventory.md.
Ordering principle: each phase only ADDS frames/verbs/views; nothing from
an earlier phase gets reshaped. The anti-rewrite decisions below are
locked from the first commit.

## Anti-rewrite decisions (locked before phase 1)

1. A directory listing is a SUBSCRIPTION, not a one-shot reply.
   fs_open_view returns entries and keeps pushing deltas while the view
   is open (collapse/close = unsubscribe). Live queries, tree-expand
   liveness, and auto-refresh are then "more of the same". One-shot
   convenience reads can exist, but the view primitive subscribes.
2. Every mutation is a JOB with an id, even mkdir/rename (may complete
   synchronously daemon-side but still reports as a job). Progress,
   queueing, pause/resume, journaled resume, and undo hang off job
   identity.
3. The model never holds a bare path: always (host, path) via one
   FileRef type. null-host-means-local stays confined to the connection
   layer.
4. Listing entries use a versioned, extensible format (fixed core +
   tail blocks, snapshot-v4 style). Older daemons must remain usable:
   durable sessions on a pre-upgrade daemon stay attachable.
5. Browser model is plain Zig data; GTK widgets are the view (PaneTree
   discipline). Nothing in the model imports GTK.

Also locked: the no-hang invariant applies to every fs path from birth
(non-blocking fds, deadline recvs, bounded sends); heavy ops run as
sketerm-mux --job subprocesses, never threads in the daemon; never write
browser state into the tree being browsed (no .DS_Store analogs).

## Phase 1 -- daemon file service + fsdrive client

- New fs_* wire frame family: fs_open_view/fs_close_view (rich listing
  + pushed deltas), fs_stat, fs_read (ranged), fs_write, fs_mkdir,
  fs_rename, fs_symlink, fs_delete.
- Rich listing entry: name, size, mode, mtime/ctime, owner/group,
  symlink target, entry-count for dirs -- one round trip per directory.
- inotify watching bound to open views; delta computation daemon-side.
- fsdrive.zig client module in the appdrive/termdrive mold: GTK-free,
  non-blocking, deadline-bounded, musl-clean.
- MCP file tools riding fsdrive (cheap win + test surface).
- Proof: zig build smoke-fs headless against local daemon AND the
  fake-SSH rig ($SKETERM_SSH); unit tests for delta computation.

## Phase 2 -- job engine

- Two job tiers, one job-id shape: INLINE jobs (mkdir, rename, symlink,
  single-file delete) execute synchronously in the poll loop, no fork --
  the job id is bookkeeping only. SUBPROCESS jobs (recursive copy/
  delete, extract, hash, search) spawn one sketerm-mux --job helper per
  OPERATION (not per file: a 40k-file copy is one process). Process
  lifetime = job lifetime; kill = cancel; no worker pool (it would
  forfeit kill-cancellation and crash isolation to save ~1ms/op). Small-
  op floods are handled by batching at the verb level (copy takes a
  source LIST), never by pooling.
- Helper: job spec in, progress frames out over a pipe the poll loop
  watches.
- Job journal in daemon state dir; job ids stable across daemon
  restart; wire frames job_start/job_progress/job_done/job_cancel/
  job_pause/job_resume/job_list.
- First verbs: copy, move, delete, hash. Resumable copy via chunk
  journal with per-chunk hashes (single-host).
- Proof: smoke test incl. kill-daemon-mid-copy resume.

## Phase 3 -- GTK browser pane (local daily driver)

- Browser model: internal per-pane tab strip (Nemo model), tree-expand
  state (expanded set == watch set), selection, per-folder view memory,
  history. Plain Zig; unit-testable without display.
- GTK view: list view with tree-expand-inline, breadcrumb/editable
  location bar, minimal sidebar, sort/hidden toggles.
- New PaneTree leaf kind; layout.zig persistence incl. browser tabs and
  remote locations; SKETERM_VERIFY_TREE covers the new leaf.
- Mutations wired to jobs: DnD with modifier overrides, conflict
  dialogs (non-blocking, Explorer model), multi-level undo, progress UI
  fed by job events, trash, rename (basename-selected), new folder/
  template.
- Proof: smoke-e2e drives the pane over the IPC socket.

## Phase 4 -- remote for real

- Browser tabs on SSH/UDP hosts (protocol already host-agnostic; this
  phase is connection UX + hardening: reconnect, dead-host degradation
  of one pane only).
- Dual-pane with source/target semantics; per-pane tabs each side.
- Cross-host copy routed through the client, resumable via the phase-2
  journal; both-ends hash verify; transfer queue UI (serialize per
  device/host, reorder, pause).
- Proof: fake-SSH rig transfers with induced disconnects.

## Phase 5 -- openers + terminal integration

- Open-with: LOCAL apps via download-to-cache (hydrating cache path,
  FUSE's simpler predecessor -- same daemon reads, no kernel); REMOTE
  apps via existing Wayland app forwarding (file never crosses the
  wire); per-host installed-app lists; one merged menu labeled
  local/remote.
- Open Terminal Here = sketerm pane whose session is already on that
  host in that cwd. Drag entry into a terminal inserts host-aware path.
- Selection/cwd exported to sibling terminal panes (env/FIFO).

## Phase 6 -- FUSE mount

- Pure-Zig /dev/fuse client (no libfuse), single-threaded async in the
  kio-fuse structural mold but with push invalidation from phase-1
  watches.
- Placeholder/hydrate/evict/pin model (CfAPI/FileProvider): dataless
  entries, range hydration, explicit pin + free-up-space, badges in the
  browser.
- macOS later/optional: localhost NFSv3 serve (rclone precedent) or
  FileProvider extension once a native frontend exists. Never gates
  Linux.

## Phase 7 -- search + live queries

- Daemon-side find/grep/du verbs as jobs; results stream into a
  panelize-style listing (command output as operable file list, incl.
  git ls-files/rg/fd presets).
- Live queries (Haiku model): saved query = durable virtual folder;
  daemon evaluates against watch deltas, streams match/unmatch; relative
  -time predicates re-evaluated daemon-side.

## Phase 8 -- power features

- Batch rename incl. $EDITOR-buffer mode; directory synchronizer with
  both-ends daemon scanning; collections/scrap folders spanning hosts +
  drop-stack shelf; tags via xattrs + daemon index, editable as columns;
  mount bypass (NFS/sshfs detection -> mux reroute, "via sketerm"
  badge); declarative actions (.action files, Nemo-style conditions,
  runs-here vs runs-on-host flag); standalone window mode (second
  .desktop entry, own icon/menu); Miller columns view; flat/branch
  view; file coloring rules.

## macOS notes

- Daemon as file host: works via mux-portable aarch64-macos; watcher
  needs an FSEvents backend behind a watcher.zig abstraction (delta
  output identical to inotify backend). getmntinfo() replaces
  /proc/mounts for mount detection.
- GUI: GTK pane works on macOS as-is; the GTK-free model keeps a future
  AppKit frontend possible.
- Rule: nothing on Linux is ever sacrificed or delayed for macOS.
