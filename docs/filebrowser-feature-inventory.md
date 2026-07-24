# File Browser Feature Inventory (research synthesis)

Untracked research document. Sources: six parallel deep-dives into
(1) GTK family: Nemo, Nautilus, Thunar, Caja; (2) KDE: Dolphin, Konqueror,
KIO/Baloo; (3) Windows Explorer + CfAPI; (4) macOS Finder + FileProvider +
Path Finder/ForkLift/Commander One; (5) other-DE/obscure: Haiku Tracker,
ROX-Filer, SpaceFM, Krusader, elementary Files, COSMIC Files, Deepin FM,
PCManFM, xplorer2, Directory Opus, spatial Nautilus; (6) orthodox/TUI:
Total Commander, Directory Opus, Double Commander, Far, Midnight Commander,
ranger, nnn, lf, yazi, vifm, broot.

Markers:
- [TS]   table stakes -- users expect it, ship it
- [DIFF] differentiator -- most managers lack it, worth having
- [MUX]  sketerm-mux structural advantage -- we can do this better than
         anyone because the daemon runs on the file's host

---

## 1. Navigation

- [TS] Tabs (all modern managers). New/close/reorder/detach; middle-click
  folder opens in tab; drag files onto a tab to drop there; duplicate tab;
  undo-close-tab (Dolphin).
- [TS] Dual-pane / split view (Nemo F3, Dolphin F3, Krusader, TC, DC,
  SpaceFM up to quad). Source/target semantics: copy defaults from active
  pane to inactive pane (orthodox model). Users cite its removal as the
  reason Nautilus forks exist.
- [TS] Breadcrumb path bar with clickable segments, each segment a drop
  target; per-segment dropdown listing SIBLING folders (Explorer, Dolphin)
  for lateral jumps; toggle to editable text path (Ctrl+L) accepting URIs
  and remote paths with completion (COSMIC does remote completion in the
  breadcrumb).
- [TS] Back/forward/up history per pane with dropdown history list;
  mouse side buttons.
- [TS] Sidebar/places: bookmarks, devices, remotes, trash; drag to
  reorder; drag files onto entries to move; sections collapsible. Shared
  with file dialogs (KDE Places, GTK bookmarks).
- [TS] Tree sidebar mode (Nemo/Thunar/Caja/MC) as an alternative to
  places.
- [TS] Type-ahead jump-to-name in the view; distinct from search. GNOME
  removing this caused a decade of complaints. Haiku extends type-ahead to
  a filtering mode that narrows the list.
- [DIFF] Miller columns view (Finder, elementary, ranger/yazi's
  parent-current-preview layout, OneCommander). Deep-tree keyboard
  traversal: left=parent, right=child, last column previews. The ergonomic
  winner for tree walking.
- [DIFF] Frecency jump (zoxide-style in yazi/lf/nnn; Explorer Quick
  Access "frequent folders"). Jump to a directory by fuzzy substring
  ranked by frequency+recency. [MUX] can be per-host, daemon-side.
- [DIFF] Directory hotlist with single-key named bookmarks (ranger m/',
  nnn, MC Ctrl+backslash, TC Ctrl+D hierarchical).
- [DIFF] Spring-loaded folders (Finder): hover during drag auto-opens the
  folder so you can drill into a drop target mid-drag.
- [DIFF] Proxy icon (Finder): the window's own folder is a draggable
  object; Cmd-click shows ancestor menu.
- [DIFF] Spatial per-folder memory (spatial Nautilus, Haiku, .DS_Store):
  each folder remembers view mode/sort/zoom/scroll. Ship the memory
  WITHOUT the .DS_Store-style sidecar pollution (store client-side or in
  daemon state, never in the browsed tree).
- [DIFF] cd-on-quit + bidirectional cwd sync with a terminal (Dolphin F4
  panel follows the view and vice versa; nnn/lf/yazi cd-on-quit). [MUX]
  natural: the browser pane and terminal pane can share one session cwd.
- [TS] Go-to-path dialog accepting ~, absolute, and remote URIs; recent
  locations.
- [TS] Session restore: reopen tabs/splits/paths on relaunch (Dolphin,
  DO layouts, TC saved tabs).

## 2. Views and rendering

- [TS] View modes: icon grid, list/details, compact (dense names-only,
  Nemo/Caja/TC brief), tree-expand-inline (disclosure triangles).
  Gallery/content view (Explorer, Finder) is nice-to-have.
- [TS] Configurable list columns: name, size, type, mtime/ctime/atime,
  permissions, owner, group, symlink target; reorder/resize/toggle.
  Explorer exposes 300+ metadata columns; DO/TC allow plugin-computed
  columns. [DIFF] computed/custom columns.
- [TS] Sorting: any column, natural numeric sort, folders-first toggle,
  case sensitivity option.
- [DIFF] Grouping with collapsible headers (Explorer, Finder Arrange-By,
  Dolphin). None of the GTK four have it.
- [TS] Zoom slider / Ctrl+wheel icon sizing.
- [TS] Thumbnails: images, video frames, PDFs, fonts; size-capped;
  REMOTE thumbnailing must be explicitly bounded (GVFS's per-file
  round-trips are a top pain point). [MUX] thumbnails generated
  daemon-side on the file's host, shipped as pixels, cached client-side.
- [DIFF] Column-header filter facets (Explorer: checkbox facets and
  date/size buckets straight from the header).
- [DIFF] Filter-as-you-type view narrowing (Dolphin Ctrl+I, broot, yazi,
  vifm persistent filters) -- live substring/regex narrowing, independent
  of search.
- [DIFF] Flat/branch view (DO Flat View, TC Ctrl+B, vifm :tree, broot):
  flatten an entire subtree into one operable list. Combined with
  wildcard-select and batch rename, this is the orthodox power cluster.
  [MUX] the daemon walks the tree server-side and streams one list.
- [DIFF] File coloring rules (TC by wildcard/attr, Far highlighting
  groups, DO labels, vifm :highlight, LS_COLORS) -- rule-driven visual
  classes.
- [TS] Status bar: selection count/size, free space; item info tooltips.
- [TS] Hidden files toggle; .hidden file support; show-full-path option.
- [DIFF] Per-file inline annotation column toggle (yazi linemode:
  size/mtime/perms/owner one keystroke away).

## 3. Selection model

- [TS] Rubber band, Ctrl/Shift multi-select, select-all/invert.
- [TS] Select-by-pattern dialog (Dolphin Ctrl+S, TC gray-plus wildcard
  mask, ROX minibuffer regex select).
- [DIFF] Sticky/checkbox selection (xplorer2, Explorer checkboxes,
  Dolphin hover +/- markers): toggle items without holding Ctrl; survives
  misclicks. Great for building large curated sets.
- [DIFF] Persistent selection registers across directories and sessions
  (nnn/lf/vifm; DO stored selections; lf shares selection between
  instances via its server). Mark files in several places, then act once.
- [DIFF] Visual/range select mode (yazi/vifm, vim-like).
- [DIFF] Selection exported to shell (SpaceFM bash variables, MC %f/%d,
  ranger %s, nnn NNN_FIFO streaming selection to external consumers).
  [MUX] browser selection should be visible to sibling terminal panes as
  env/FIFO -- sketerm IS a terminal; this is the single best-fit
  integration primitive.

## 4. File operations

- [TS] Copy/cut/paste, DnD with modifier override (Ctrl=copy Shift=move
  Alt/right-drag=menu), paste-into-folder, move-to/copy-to submenus with
  recent destinations.
- [TS] Conflict dialog: skip/replace/rename/keep-both + apply-to-all,
  side-by-side size/date/thumbnail of both files, newer/older indication.
  Explorer's non-blocking model is the bar: conflicts queue for later
  decision while the rest of the batch keeps copying.
- [TS] Folder collision merge vs replace (Finder merge semantics).
- [TS] Multi-level undo/redo across copy/move/rename/trash/create/link
  (KIO FileUndoManager, Nautilus, Finder, DO).
- [TS] Trash: freedesktop spec, restore-to-original ("Put Back"),
  per-volume, size caps, Shift+Del permanent with confirm.
- [TS] New folder, new-from-template (~/Templates), new folder WITH
  selection (Finder). Haiku templates can carry preset attributes.
- [TS] Inline rename selecting basename not extension; F2.
- [TS] Batch rename: find/replace, counters with padding, date/metadata
  tokens, case transforms, live preview, regex (PowerRename, TC MRT,
  DO Advanced Rename, KRename). [DIFF] rename-via-$EDITOR buffer
  (ranger/vifm/nnn/lf/yazi bulkrename): dump names into the editor, apply
  the diff -- perfect for a terminal-native browser.
- [TS] Duplicate; symlink/hardlink creation; "paste as link".
- [TS] Compress/extract: archive-as-folder browsing (MC VFS, KIO krarc,
  Commander One even edits inside archives), extract-here/to, compress-to
  with format choice, encrypted zip (Nautilus). [MUX] extraction/creation
  ALWAYS runs on the host that owns the archive -- a daemon job, only the
  command crosses the wire.
- [TS] Permissions/owner editor with recursive apply; octal presets;
  ACLs advanced page.
- [DIFF] Batch attribute/timestamp editing (TC change-attributes).
- [DIFF] Checksum generate + verify in properties (Dolphin checksums tab,
  DC sfv/md5 sidecars). Verify-after-copy option (TC, DC). [MUX] hashing
  runs daemon-side; cross-host copy verify compares digests computed at
  both ends -- no re-reading over the network.
- [DIFF] Split/combine files (TC/DC/MC).
- [DIFF] Wipe/secure delete (TC, Far).
- [DIFF] Duplicate finder by content hash (DO, nnn plugin).
- [DIFF] Directory synchronizer (TC Synchronize Dirs, Krusader
  Synchronizer, DO, ForkLift Sync): compare two trees by date/size/
  content, color-coded diff, asymmetric/bidirectional selective mirror.
  [MUX] both sides can be scanned daemon-side in parallel; only the
  digests/listing diff crosses the network. Nobody else can do that.
- [DIFF] Compare-by-content / diff viewer on two selected files (MC
  mcdiff, TC, vifm vimdiff).
- [DIFF] APFS-style instant clone / server-side copy: same-host copy
  never streams through the client (cp --reflink where supported).

## 5. Transfers: queue, progress, resume

- [TS] Unified progress UI aggregating concurrent jobs: per-job speed,
  ETA, current file; expandable detail (Explorer Win8 dialog, Nautilus
  popover, KIO notifications). Explorer's live throughput graph is loved.
- [TS] Pause/resume/cancel per job (Explorer, TC BTM, DC queue).
- [DIFF] Queue management: serialize jobs targeting the same device
  instead of thrashing (Nemo queueing, KIO queue-vs-parallel, TC/DC
  reorderable queues, mixed-op queues).
- [DIFF] Resumable transfers across interruption (TC FTP resume,
  robocopy /Z; absent from every mainstream Linux GUI manager -- GVFS
  restarts from scratch, a top user complaint).
- [MUX] Daemon-owned transfer jobs: queue lives in the daemon, survives
  client disconnect, resumes across reconnect/roaming (UDP transport),
  journaled chunks with per-chunk hashes for restart-after-crash,
  progress replayed to any attaching client. This is the single largest
  structural win over every manager surveyed.
- [DIFF] Background "shelf"/drop stack (Path Finder Drop Stack): a
  persistent basket you drag files into from many places over time, then
  drop the accumulated set at a destination. Pairs with persistent
  selections.

## 6. Search and queries

- [TS] Recursive filename search under current folder; scope toggle
  (this folder / everywhere); filename vs content toggle.
- [TS] Filter facets: kind, size buckets, date ranges (Explorer AQS,
  Finder tokens, Dolphin facets, TC Alt+F7 with depth/attr/archive
  options).
- [TS] Query syntax for power users (AQS `kind:doc size:>100MB
  datemodified:this week`, Spotlight raw predicates).
- [DIFF] Content/full-text search backed by an index (Tracker, Baloo,
  Windows Search, Everything for instant names). Remote mounts are
  never indexed by any of them -- documented pain point everywhere.
  [MUX] per-host daemon-side index (or at minimum daemon-side rg/find
  execution) makes remote search as fast as local. Only results cross
  the wire.
- [DIFF] Saved searches as virtual folders (.savedSearch smart folders,
  .search-ms, Baloo places entries).
- [MUX/DIFF] LIVE queries (Haiku Tracker, the standout idea of the whole
  survey): a saved search is a durable object; the FS pushes
  notifications so the query view updates in real time as files start
  and stop matching, including relative-time predicates ("modified in
  last 7 days") that stay true as time passes. The mux daemon already
  owns inotify + an event wire -- match/unmatch deltas stream like
  terminal events. No polling.
- [DIFF] Panelize (MC): run any command (find, git ls-files, rg -l, fd)
  and use its output AS the file listing, fully operable (Far TmpPanel,
  vifm custom views, TC feed-to-listbox). Terminal-native gold; [MUX]
  the command runs on the session's host.
- [DIFF] Search results into collections you can keep (DO Find Results
  collections).

## 7. Remote/network architecture (models compared)

Surveyed models, worst to best:

- GVFS (GNOME family): per-op round trips, no write batching (SFTP ~10x
  slower than scp), no cache, no resume, fragile reconnect, FUSE bridge
  gaps. The negative reference.
- KIO (KDE): richer protocol set, uniform URLs, archive/virtual schemes;
  but per-file stat on listing, 30s stale caches, no remote change
  notification, kio-fuse whole-file download fallback, per-app
  connections re-authing. kio-fuse DESIGN.md is worth reading -- its
  single-threaded async event-loop FUSE lowlevel design matches how a
  sketerm FUSE client should be built (their pain: no push invalidation;
  we have push).
- MC FISH: file ops over a plain SSH shell -- proof that "run commands
  on the remote side" beats emulating POSIX over a wire protocol.
- TC WFX / SpaceFM protocol handlers: pluggable/scriptable virtual
  filesystems -- extensibility model to imitate (user-defined schemes).
- CfAPI / OneDrive Files-On-Demand (Windows) and FileProvider / iCloud
  (macOS): THE reference model for slow backends. Dataless placeholders
  (metadata-only entries) enumerate instantly; hydration on access,
  including RANGE hydration (stream the head of a 4GB video without
  downloading it); explicit pin ("always keep local") and evict ("free
  up space") states with per-item status badges; disk-pressure driven
  auto-eviction; provider-supplied thumbnails without hydration.
  [MUX] our FUSE mount should implement exactly this placeholder/
  hydrate/evict/pin model, with the daemon pushing invalidations.

What [MUX] adds over all of them:
- One persistent authenticated connection per host (no per-app
  reconnect/reauth), roaming over UDP.
- High-level verbs: "list dir with full stat+symlink targets+git status
  in one reply", server-side find/grep/du/hash/extract.
- Push change notification (inotify daemon-side -> event stream), so
  caches are aggressive AND correct; live views, live queries.
- Range reads over the existing channel model for preview/hydration.
- Credentials: none beyond the SSH session you already have.

Standard remote features to keep from the field: [TS] saved server
bookmarks with keychain credentials and one-click reconnect; network
neighborhood discovery is optional (skip for v1); drag-drop upload onto a
remote view; remote paths typed directly into the location bar.

## 8. Virtual folders, collections, VFS

- [DIFF] File collections / scrap containers (DO Collections, xplorer2
  scrap windows, Far temp panel): persistent named sets of references to
  files from anywhere (including multiple hosts), operable as one list.
  [MUX] a collection can span hosts -- entries are (host, path).
- [DIFF] Archive-as-folder VFS (MC, KIO, TC packer plugins, Commander
  One in-archive editing).
- [TS] Virtual locations: trash:, recent:, starred/favorites, computer.
- [DIFF] Libraries (Windows): aggregate several physical folders into
  one view with a default save target.
- [DIFF] Tag-based virtual folders (tags:/ in KDE, Finder tag sidebar).

## 9. Metadata, tags, attributes

- [TS] Properties dialog: sizes (logical vs on-disk), timestamps, MIME,
  free space, permissions tab, open-with tab; recursive folder size
  calculation on demand (never automatic on remote).
- [DIFF] Tags: colored + named, multiple per file, searchable, stored in
  xattrs (Finder com.apple.metadata pattern, Baloo, elementary, Deepin,
  DO labels/ratings/descriptions). No mainstream GTK manager has real
  tags -- a gap worth filling. [MUX] xattr-stored so they live with the
  files on their host; daemon indexes them.
- [MUX/DIFF] Haiku typed attributes as columns, editable inline, indexed
  and queryable. Full BFS semantics need FS support, but xattrs + a
  daemon-side index emulate the UX: show any attribute as a column, edit
  it in place, query it in live searches.
- [DIFF] Per-file comments/descriptions (Far Descript.ion, Finder
  Spotlight comments, DO descriptions).
- [DIFF] Emblems/badges (Nemo/Caja; Explorer overlay handlers; sync
  status badges) -- overlay icons driven by rules or state (VCS, sync,
  pinned/placeholder state for our FUSE mount).
- [DIFF] VCS status integration: per-file git status overlays + context
  actions in-view (Dolphin plugins, Files App, broot :gf, ForkLift
  badges). [MUX] daemon runs git status host-side; ideal fit.
- [DIFF] Checksums tab (Dolphin); "where from" download-URL xattr
  (Finder); MIME/default-app editing from properties.
- Media/EXIF/ID3 metadata columns and panels (Explorer property
  handlers, Baloo, TC WDX plugins): [TS] display, [DIFF] as sortable
  columns and rename tokens.

## 10. Preview

- [TS] Quick Look-style single-key preview overlay (Space): images,
  video/audio playback, PDF, text with syntax highlight, archives,
  fonts; arrow-key through selection without closing (Finder Quick Look,
  Sushi, TC lister/Ctrl+Q quick-view pane).
- [TS] Preview/information side panel with metadata + editable
  tags/rating (Dolphin F11, Explorer Alt+P, DO viewer pane).
- [DIFF] Pluggable preview handlers per type (ranger scope.sh, yazi Lua
  previewers, TC WLX, Quick Look extensions): a script/plugin registry
  keyed on MIME.
- [DIFF] Async, non-blocking preview pipeline with preloading (yazi is
  the modern bar: previews never freeze the UI, preloaders warm the next
  files). Mandatory for remote.
- [MUX] Remote preview = daemon-side generation (thumbnail, pdftotext,
  ffmpeg frame, head-of-file) streamed as pixels/text; range hydration
  for media scrubbing. TUI managers' remote preview breakage (sshfs
  latency) is a known pain point we structurally avoid.
- [DIFF] Hex view fallback for any file (MC, TC, Far).

## 11. Open-with, apps, desktop integration

- [TS] Open-with menu with per-MIME defaults (mimeapps.list), "always
  open with" per-file override (Finder xattr pattern optional).
- [MUX/DIFF] Open in LOCAL app via FUSE placeholder path, or in REMOTE
  app via existing Wayland app forwarding (file never crosses the wire).
  One merged menu, each entry labeled local/remote. No other file
  manager on any platform can offer the remote half.
- [TS] Open Terminal Here -- for us: open a sketerm pane whose session
  is ALREADY on that host in that cwd. Zero-cost, uniquely natural.
- [DIFF] Default-app associations per host (a remote host has its own
  installed apps; we already have list_installed_apps daemon-side).
- [TS] Drag and drop to/from other local apps (XDS/portal on Wayland);
  drag out of the browser into a terminal pane inserts the (host-aware)
  path.
- [DIFF] Send-to targets; share menu -- low priority.
- [DIFF] Template "New Document" menu from ~/Templates (per host).
- [DIFF] Set as wallpaper, image rotate/convert quick actions (GTK
  extensions, Finder Quick Actions) -- action-system material, not core.

## 12. Extensibility and automation

- [DIFF] Declarative context-menu actions: Nemo Actions (.nemo_action
  INI with rich conditions: mimetypes, extensions, selection count,
  exec-presence), Thunar UCA, KDE service menus, ROX SendTo. The model
  to copy: small config files, conditions, token substitution
  (%f %F %d %U), no code required.
- [DIFF] Script/plugin API beyond that (nautilus-python, TC's four-type
  plugin ABI: packer/filesystem/lister/content; DO scripting with
  custom columns and event handlers; yazi Lua + ya pack; ranger
  commands.py; Far Lua macros).
- [DIFF] User menu / command palette running shell with selection tokens
  (MC F2 user menu, broot verbs, SpaceFM design mode editing menus in
  place).
- [MUX] Actions declare WHERE they run: client-side or on the file's
  host via a daemon job. An action like "ffmpeg-compress this video"
  runs host-side with progress as a job. This turns the action system
  into a remote batch tool.
- [DIFF] Custom columns computed by plugins (TC WDX, DO script columns).
- [DIFF] Macro/replay of UI operations (Far LuaMacro) -- we already have
  the MCP journal/macro machinery; low-cost to extend.

## 13. Tabs, sessions, layouts, workspaces

- [TS] Per-pane tabs; locked/pinned tabs (TC, DO).
- [DIFF] Saved tab sets / named layouts (DO Layouts+Styles, DC tab sets,
  TC saved tabs): reopen a whole working context (local+remote paths).
  We already serialize pane trees to JSON -- browser panes join
  layout.zig persistence naturally, including their remote paths.
- [DIFF] Contexts/workspaces with independent selections (nnn's 4
  contexts).
- [TS] Session restore on relaunch including remote locations
  (reconnect via existing daemon sessions).

## 14. Accessibility of power (keyboard model)

- [TS] Complete keyboard operation: orthodox F-key verbs (F3 view F4
  edit F5 copy F6 move F7 mkdir F8 delete) as an optional profile;
  fully rebindable keys (we have a keybind system).
- [TS] Always-available command line (orthodox model): a browser pane
  should let you start typing a shell command against the cwd/selection
  -- sketerm can open/attach a real terminal session in one keystroke,
  which beats every OFM's embedded mini-shell.
- [DIFF] Vim-mode navigation (ranger/vifm/yazi audience).

## 15. Pain points to design against (from the field)

- Per-entry stat round trips on remote listings (GVFS 5000-file dir:
  ~160s vs ~10s raw; kio_sftp per-file stat). One-shot rich listings.
- Whole-file download before open (kio-fuse cache mode). Range
  hydration.
- Stale caches with no invalidation (KIO 30s windows). Push
  invalidation from daemon inotify.
- Blocking UI on stalled mounts (Finder beachballs on dead SMB; Explorer
  hangs on dead UNC). Every remote call bounded + async; a dead host
  degrades ONE pane with a described error, never the app. (Our no-hang
  invariant already says this.)
- .DS_Store-style sidecar pollution of browsed trees. Never write state
  into the tree being browsed.
- No transfer resume anywhere in mainstream Linux GUI managers.
- Remote search unindexed everywhere. Daemon-side execution/index.
- Thumbnail storms over the network. Daemon-side generation, bounded,
  cached, size-capped.
- Fragile reconnect erroring mid-copy. Jobs are daemon-owned and
  journaled; reconnect resumes or reports precisely.
- Icon-overlay slot exhaustion (Windows 15-slot fiasco): make badges a
  first-class rule system, not a global registry.
- "Folder forgot my view settings" (Explorer view bags): per-folder view
  memory must be deterministic and user-clearable.

## 16. Ranked steal-list (the shortlist that should shape v1)

1. Placeholder/hydrate/evict/pin model for the FUSE mount (CfAPI +
   FileProvider) with push invalidation -- the remote story.
2. Daemon-owned journaled transfer jobs: queue, pause/resume, verify,
   survive disconnect, cross-host with both-ends hashing.
3. One-shot rich directory listings + push change events (kills the
   GVFS/KIO latency class).
4. Live queries as durable virtual folders (Haiku Tracker), daemon-side
   inotify + match/unmatch deltas over the existing event wire.
5. Panelize: command output as an operable listing, executed on the
   session's host (MC), incl. git ls-files/rg/fd presets.
6. Selection/cwd exported to sibling terminal panes (SpaceFM/nnn FIFO
   model) + cwd-synced terminal (Dolphin F4) + Open Terminal Here on
   the remote host.
7. Open-with spanning local apps (FUSE path) and remote apps (Wayland
   forwarding) in one menu.
8. Dual-pane + directory synchronizer with server-side scanning on both
   ends (TC/Krusader, but remote-fast).
9. Declarative actions with a runs-here/runs-on-host flag (Nemo Actions
   model + daemon jobs).
10. Async pluggable preview pipeline, daemon-side generation for remote
    (yazi bar, Quick Look UX).
11. Tags/attributes as xattrs with daemon index, editable as columns,
    queryable in live searches (Haiku UX on Linux xattrs).
12. Collections/scrap folders that can span hosts; Drop Stack shelf for
    staged multi-source operations.
13. Flat view + select-by-pattern + $EDITOR bulk rename (the power
    cluster, remote-capable).
14. Per-folder view memory without in-tree sidecars; saved layouts
    including remote paths.
15. Miller columns as an alternate view mode.

Everything in sections 1-14 not on this list is still inventory: table
stakes to keep in mind when designing pane UI, or later-phase features.

## 17. Confirmed requirements from Jelle (2026-07-23)

- Split view + tabs are load-bearing (the reason he uses Nemo). Each
  browser PANE carries its OWN internal tab strip (Nemo per-split-tabs
  model). Browser tabs are browser-model state (location, history, view
  state, selection), never PaneTree leaves; a browser tab never owns a
  connection, it references the shared per-host daemon connection.
  Layout persistence serializes browser tabs incl. remote locations.
- Tree-expand-inline in list view is core (daily use). Expanded set ==
  daemon watch set; one rich listing per expand, push events keep every
  visible node live, collapse = unwatch.
- Mount bypass: detect locally mounted NFS/sshfs paths (/proc/mounts
  source field gives host + path prefix), match host against daemon
  sessions/ssh config (ask-and-remember on alias ambiguity), verify
  identity (daemon-side stat vs mount view), then transparently reroute
  browser operations to the mux protocol with a "via sketerm" badge.
  Copies between mounts of the same host become host-local jobs;
  extract/search run host-side. Fall back to the plain mount path when
  the host is unreachable. Only accelerates the sketerm browser; the
  long-term replacement for sshfs itself is the placeholder FUSE mount.
