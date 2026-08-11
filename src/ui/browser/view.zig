//! The BrowserView struct: its state, its lifecycle, and the index of
//! where each responsibility lives.
//!
//! A BrowserView rides a regular terminal Pane as its second face:
//! the pane keeps its shell session (that IS "Open Terminal Here" --
//! one toggle away), the browser renders on top. Internal tab strip
//! per pane (the Nemo per-split-tabs model): browser tabs are cheap
//! VIEW state; the heavy session state stays with the pane.
//!
//! Every tab references a shared per-view HostConn (null host = local
//! daemon, "user@box" = SSH, "udp:box" = UDP -- same host strings as
//! terminals), so a remote tab is the same code path as a local one.
//!
//! The struct body below is a two-part index: the fields, then one
//! decl alias per method grouped by the module that owns it. The
//! aliases keep `self.foo()` working from anywhere while the bodies
//! live in the topic module.

const std = @import("std");
const c = @import("../../c.zig").c;
const browser_model = @import("../../filebrowser/model.zig");
const clipboard_mod = @import("../../filebrowser/clipboard.zig");
const places_mod = @import("../../filebrowser/places.zig");
const emblems_mod = @import("../../filebrowser/emblems.zig");
const gitstatus = @import("../../filebrowser/gitstatus.zig");
const iconload = @import("../iconload.zig");
const toolbtn = @import("../toolbtn.zig");
const Pane = @import("../pane.zig").Pane;
const file_transfers = @import("../file_transfers.zig");
const image_canvas = @import("../image_canvas.zig");

const ActiveTransfer = @import("types.zig").ActiveTransfer;
const AttrRequest = @import("props.zig").AttrRequest;
const SnapRequest = @import("props.zig").SnapRequest;
const BTab = @import("types.zig").BTab;
const CompareCtx = @import("compare.zig").CompareCtx;
const CopyAck = @import("jobs.zig").CopyAck;
const CopyQueue = @import("jobs.zig").CopyQueue;
const DeferredTransfer = @import("jobs.zig").DeferredTransfer;
const CopyRetry = @import("types.zig").CopyRetry;
const conflict_mod = @import("conflict.zig");
const DupState = @import("search.zig").DupState;
const EditWatch = @import("types.zig").EditWatch;
const EditorRename = @import("ops.zig").EditorRename;
const FileColor = @import("types.zig").FileColor;
const HostAction = @import("types.zig").HostAction;
const HostConn = @import("types.zig").HostConn;
const JobPanel = @import("jobpanel.zig").Panel;
const JobRow = @import("types.zig").JobRow;
const LabelProbe = @import("props.zig").LabelProbe;
const MAX_ATTR_COLUMNS = @import("render.zig").MAX_ATTR_COLUMNS;
const OpenWithCtx = @import("open.zig").OpenWithCtx;
const PendingOpen = @import("open.zig").PendingOpen;
const OwnedSearch = @import("types.zig").OwnedSearch;
const PathCompletion = @import("nav.zig").PathCompletion;
const Pending = @import("types.zig").Pending;
const PendingHistory = @import("types.zig").PendingHistory;
const PendingJob = @import("types.zig").PendingJob;
const PendingUndo = @import("types.zig").PendingUndo;
const PreviewRead = @import("preview.zig").PreviewRead;
const PreviewState = @import("preview.zig").State;
const RemoteThumb = @import("preview.zig").RemoteThumb;
const RestoreRead = @import("ops.zig").RestoreRead;
const DropProbe = @import("ops.zig").DropProbe;
const PasteRun = @import("ops.zig").PasteRun;
const ThumbCtx = @import("preview.zig").ThumbCtx;
const UndoOp = @import("types.zig").UndoOp;
const colkeys = @import("../../filebrowser/colkeys.zig");
const input = @import("../input.zig");
const locbar = @import("locbar.zig");
const mediacols = @import("mediacols.zig");
const parseSpec = @import("../../filebrowser/paths.zig").parseSpec;
const selmod = @import("selection.zig");
const tabsmod = @import("tabs.zig");
const tabhost_mod = @import("../tabhost.zig");
const templates_mod = @import("templates.zig");
const viewsmod = @import("views.zig");

/// Constrained-presentation hooks for the file PICKER (src/ui/
/// picker.zig). `null` on a BrowserView means normal browsing --
/// every picker branch in the browser modules is behind that check,
/// so a null-picker view provably behaves exactly as before.
pub const PickerHooks = struct {
    ctx: *anyopaque,
    /// Double-click/Enter on a FILE reports it here instead of
    /// opening it (directories still navigate normally).
    on_activate_file: *const fn (ctx: *anyopaque, host: ?[]const u8, path: []const u8) void,
    /// Selection or location changed; the picker re-reads the
    /// current tab's selection.
    on_selection_changed: *const fn (ctx: *anyopaque) void,
    /// A daemon fs_reply whose request the PICKER issued itself (the
    /// typed-name stat probe). Returns true when the picker owned
    /// `req`, which ends the dispatch. `is_dir` is null when the
    /// reply carried no entry.
    on_reply: ?*const fn (ctx: *anyopaque, req: u32, ok: bool, is_dir: ?bool) bool = null,
    /// Extra visibility predicate composed with views.entryVisible
    /// (the mode's file/dir rule plus the active name filter).
    visible: ?*const fn (ctx: *anyopaque, name: []const u8, is_dir: bool) bool = null,
    /// Disable file operations: entry context menus, entry drag
    /// sources, listing drops and the mutating keyboard chords.
    suppress_ops: bool = true,
};

pub const BrowserView = struct {
    allocator: std.mem.Allocator,
    /// The terminal pane this face rides -- null for a paneless
    /// picker embed (attachForPicker), where every pane-coupled verb
    /// (shell here, split, close pane, cwd sync) must be dead code.
    pane: ?*Pane = null,
    /// Picker presentation hooks; null = normal browsing.
    picker: ?*PickerHooks = null,
    conns: std.ArrayList(*HostConn) = .empty,
    /// Backoff timers re-dialing hosts whose connection dropped while
    /// tabs were still on them (conn.zig scheduleReconnect).
    reconnects: std.ArrayList(*@import("conn.zig").Reconnect) = .empty,
    next_req: u32 = 1,
    next_remote_thumb_id: u64 = 1,
    next_view: u32 = 1,
    tabs: std.ArrayList(*BTab) = .empty,
    pending: std.ArrayList(*Pending) = .empty,
    /// Remote opens whose host mount is still starting.
    pending_opens: std.ArrayList(*PendingOpen) = .empty,
    pending_jobs: std.ArrayList(*PendingJob) = .empty,
    drop_probes: std.ArrayList(*DropProbe) = .empty,
    /// Paste commands are admitted one durable item per idle dispatch,
    /// keeping large selections responsive while fsync runs.
    paste_runs: std.ArrayList(*PasteRun) = .empty,
    paste_idle: c.guint = 0,
    jobs: std.ArrayList(*JobRow) = .empty,
    transfers: std.ArrayList(*ActiveTransfer) = .empty,
    /// Cross-host copies waiting for their destination (jobs.zig).
    copy_queue: CopyQueue = .{},
    /// Failed cross-host copies waiting out their automatic-resume
    /// delay, and the one timer that submits them (jobs.zig).
    retry_pending: std.ArrayList(*CopyRetry) = .empty,
    mediated_retry_tokens: std.ArrayList([]u8) = .empty,
    retry_timer: c.guint = 0,
    /// Terminal user-copy jobs awaiting daemon acknowledgment.
    copy_acks: std.ArrayList(CopyAck) = .empty,
    /// Pastes/sends held while a source or destination host is still
    /// connecting; released by wireReady, dropped on host death.
    deferred_transfers: std.ArrayList(*DeferredTransfer) = .empty,

    root_box: *c.GtkWidget = undefined,
    notebook: *c.GtkNotebook = undefined,
    /// Shared notebook tab-strip mechanics (label recipe, close,
    /// middle-click, scroll-to-switch, strip gestures). Owns
    /// `notebook`, which stays mirrored here for the existing code.
    tabhost: tabhost_mod.TabHost = undefined,
    /// Editable face of the location control; the breadcrumb face
    /// and the history dropdowns live in `locbar`.
    path_entry: *c.GtkEntry = undefined,
    locbar: locbar.State = .{},
    /// Closed-tab ring (undo-close-tab), session state.
    closed_tabs: tabsmod.State = .{},
    /// Grouping / zoom / filter / flat view / per-folder view memory.
    views: viewsmod.State = .{},
    /// Sticky selection, visual range mode, persistent registers.
    sel: selmod.State = .{},
    back_button: *c.GtkWidget = undefined,
    fwd_button: *c.GtkWidget = undefined,
    completion_popover: ?*c.GtkWidget = null,
    completion_request: ?*PathCompletion = null,
    completion_source: c.guint = 0,
    syncing_path_entry: bool = false,
    status_label: *c.GtkLabel = undefined,
    jobs_box: *c.GtkWidget = undefined,
    /// Rate meters, expansion state and the sampling tick of the jobs
    /// panel -- all owned by jobpanel.zig.
    jobs_panel: JobPanel = .{},
    /// Parked paste collisions and their decision dialog. A collision
    /// never stalls the rest of the batch (conflict.zig).
    conflicts: conflict_mod.State = .{},
    /// The one open New-from-Template menu (templates.zig).
    templates: templates_mod.State = .{},
    /// Undo stack (newest last), bounded.
    undo_stack: std.ArrayList(*UndoOp) = .empty,
    redo_stack: std.ArrayList(*UndoOp) = .empty,
    pending_undo: std.ArrayList(PendingUndo) = .empty,
    pending_history: std.ArrayList(PendingHistory) = .empty,
    history_busy: bool = false,
    search_bar: *c.GtkWidget = undefined,
    search_entry: *c.GtkEntry = undefined,
    search_content: *c.GtkWidget = undefined,
    hidden_toggle: *c.GtkToggleButton = undefined,
    /// Information side panel (toggleable), Dolphin-style: preview
    /// stage, bold name, key/value metadata grid, note, content head.
    preview_box: *c.GtkWidget = undefined,
    preview_pic: *c.GtkWidget = undefined,
    preview_canvas: ?image_canvas.Canvas = null,
    preview_image: image_canvas.Session = .{},
    /// Big themed icon shown in the stage while there is no rendered
    /// preview (exactly one of pic/icon is visible).
    preview_icon: *c.GtkWidget = undefined,
    preview_name: *c.GtkLabel = undefined,
    preview_grid: *c.GtkWidget = undefined,
    preview_grid_rows: i32 = 0,
    preview_text: *c.GtkLabel = undefined,
    /// The content head's own scroller (horizontal only, for hex).
    preview_text_scroll: *c.GtkWidget = undefined,
    preview_meta: *c.GtkLabel = undefined,
    /// The notebook|panel paned; position drives preview_px.
    info_paned: *c.GtkWidget = undefined,
    /// Persisted panel width (places.json).
    preview_px: i32 = 300,
    /// Compact info card at the bottom of the places sidebar
    /// (places.json; independent of the full panel).
    side_info: bool = false,
    preview_on: bool = false,
    preview_read: ?*PreviewRead = null,
    preview_generation: u64 = 0,
    /// Handler registry, result cache, bounded preloader and the
    /// Quick Look overlay -- all owned by preview.zig.
    preview_state: PreviewState = .{},
    restore_read: ?*RestoreRead = null,
    /// Row-thumbnail cache: "path\x00mtime" -> owned texture ref.
    thumbs: std.StringHashMap(*c.GdkTexture) = undefined,
    /// Keys that failed to thumbnail (skip re-tries this session).
    thumb_failed: std.StringHashMap(void) = undefined,
    /// Async thumbnail worker (freedesktop cache; lazily started).
    thumb_ctx: ?*ThumbCtx = null,
    /// Remote-thumbnail pipeline: the fetches in flight (bounded by
    /// REMOTE_THUMB_CONCURRENCY) plus the waiting queue.
    remote_thumbs: std.ArrayList(*RemoteThumb) = .empty,
    remote_thumb_queue: std.ArrayList(*RemoteThumb) = .empty,
    /// Silence deadline for the fetches in flight; runs only while
    /// the pipeline is busy (preview.zig), so an unanswered reply
    /// frees its slot instead of wedging it forever.
    remote_thumb_watch: c.guint = 0,
    /// Coalesced re-render after thumbnails land.
    thumb_render_src: c.guint = 0,
    /// Leading-edge throttle for socket-driven listing renders
    /// (streaming chunks, watch deltas): pending one-shot source and
    /// the stamp of the last listing render (render.zig).
    listing_render_src: c.guint = 0,
    last_listing_render_ms: i64 = 0,
    /// Live local-edit sync-back watches (remote files opened here).
    watches: std.ArrayList(*EditWatch) = .empty,
    /// The one open Open With chooser (its popover owns the ctx).
    openwith: ?*OpenWithCtx = null,
    /// The one open compare/sync window.
    compare: ?*CompareCtx = null,
    /// Places sidebar (bookmarks / recent / devices).
    places_scroller: *c.GtkWidget = undefined,
    /// The sidebar column (places list + optional info card); what
    /// the Places toggle shows and hides.
    places_box: *c.GtkWidget = undefined,
    /// Compact info card widgets (bottom of the sidebar).
    side_card: *c.GtkWidget = undefined,
    side_card_img: *c.GtkWidget = undefined,
    side_card_title: *c.GtkLabel = undefined,
    side_card_sub: *c.GtkLabel = undefined,
    side_card_sub2: *c.GtkLabel = undefined,
    places_list: *c.GtkListBox = undefined,
    places_on: bool = false,
    /// The Places toggle, so the persisted open state and the button
    /// can never disagree.
    places_toggle: *c.GtkToggleButton = undefined,
    /// Sidebar splitter: places on the left, listing + preview right.
    content_paned: *c.GtkWidget = undefined,
    /// Persisted sidebar width, and the debounce that writes it (a
    /// drag emits notify::position per pixel).
    sidebar_px: i32 = places_mod.DEFAULT_SIDEBAR_PX,
    sidebar_save_src: c.guint = 0,
    /// Persisted sidebar open state; null = never toggled, so the
    /// default follows the application identity.
    sidebar_open: ?bool = null,
    /// Alternating row background in the list views (persisted in
    /// places.json, toggled from the view-options menu).
    zebra: bool = false,
    /// The live inline-rename editor, if any (see ops.InlineRename).
    inline_rename: ?*@import("ops.zig").InlineRename = null,
    /// False until the persisted chrome state has been applied, so the
    /// programmatic initial toggle does not write places.json back.
    chrome_ready: bool = false,
    /// Toolbar overflow. `right_box` is the whole right end of the
    /// toolbar; `right_cluster` is the part that HIDES when the bar
    /// runs out of room -- the hamburger menu then offers the same
    /// toggles as check rows, so nothing is lost.
    right_box: *c.GtkWidget = undefined,
    right_cluster: *c.GtkWidget = undefined,
    /// The Information-panel toolbar toggle (the hamburger's check
    /// row flips it so both stay in sync).
    info_toggle: *c.GtkToggleButton = undefined,
    bar_collapsed: bool = false,
    /// The one-shot post-layout overflow evaluation (0 = none).
    bar_idle_src: c.guint = 0,
    /// Delayed pane close while the toolbar popover dismisses.
    close_pane_src: c.guint = 0,
    /// Set from the root box's ::destroy. Closing a pane destroys the
    /// browser's widgets IMMEDIATELY but defers `Pane.deinit` (and so
    /// this view's deinit) -- a deferred callback scheduled before the
    /// close would otherwise run against destroyed widgets.
    widgets_dead: bool = false,
    /// True only after the root's destroy signal has actually fired.
    root_destroyed: bool = false,
    /// Toolbar width the collapsed cluster gives back, so expanding
    /// cannot immediately re-trip the collapse (hysteresis).
    bar_reclaim: c_int = 0,
    bookmarks: std.ArrayList([]u8) = .empty,
    /// Custom bookmark labels, parallel to `bookmarks` ("" = derive
    /// from the spec).
    bookmark_labels: std.ArrayList([]u8) = .empty,
    /// Custom bookmark icons, parallel to `bookmarks` ("" = default;
    /// otherwise an icon name, emoji, or absolute image path).
    bookmark_icons: std.ArrayList([]u8) = .empty,
    recent: std.ArrayList([]u8) = .empty,
    /// Visit statistics behind the frecency jump (Ctrl+J).
    frecency: std.ArrayList(places_mod.FrecOwned) = .empty,
    /// Sidebar sections the user folded shut, by header text (owned,
    /// persisted with places).
    collapsed: std.ArrayList([]u8) = .empty,
    /// Sidebar sections hidden entirely, by section key (owned,
    /// persisted with places).
    hidden_sections: std.ArrayList([]u8) = .empty,
    /// Preferred sidebar section order, by key (owned, persisted).
    section_order: std.ArrayList([]u8) = .empty,
    /// User sidebar widget sections (persisted with places) and their
    /// live command/graph state.
    widgets: @import("sidewidgets.zig").Store = .{},
    widget_runs: std.ArrayList(*@import("sidewidgets.zig").Run) = .empty,
    /// Saved queries (persisted with places): the root spec plus the
    /// query text exactly as typed. A live query and a one-shot search
    /// are ONE concept here -- what a query text means is decided by
    /// filebrowser/query.zig when it runs, not by a stored mode.
    saved_searches: std.ArrayList(OwnedSearch) = .empty,
    /// The most recent query run (owned), for the save button.
    last_search: ?OwnedSearch = null,
    /// Relative-time filter for the NEXT find job ("@7d pattern").
    search_within_ms: u64 = 0,
    /// Match-cap override for the NEXT find job (compare scans).
    search_max_matches: u64 = 0,
    /// User file-coloring rules (~/.config/sketerm/filecolors.conf).
    file_colors: std.ArrayList(FileColor) = .empty,
    /// Version-control overlay for the browsed root: path relative to
    /// that root -> folded state, ancestors included so a directory
    /// row can show that something inside it changed. Filled by the
    /// daemon's `git_status` job (gitstat.zig) for local and remote
    /// roots alike -- the GUI never runs git itself.
    git: gitstatus.Overlay = undefined,
    /// Which (host, root) the overlay describes. Both are compared
    /// before a badge is drawn: a same-named folder on another host
    /// is another repository.
    git_root: []u8 = &.{},
    git_host: []u8 = &.{},
    /// Roots asked recently, so navigating back and forth (or sitting
    /// outside any repository) does not respawn git per step.
    git_cache: gitstatus.Cache = undefined,
    /// Branch header of the overlay's root: the answer to "is this a
    /// repository at all", which an empty overlay cannot give.
    git_repo: gitstatus.Repo = undefined,
    /// Trailing debounce for change-driven refreshes (0 = none).
    git_delta_src: c.guint = 0,
    /// Re-poll timer for changes DEEPER than the watched views (0 =
    /// none), and how long the last git job took, which paces it.
    git_poll_src: c.guint = 0,
    git_poll_ms: i64 = 0,
    git_started_ms: i64 = 0,
    /// The in-flight `git_status` daemon job (gitstat.zig feedGit).
    /// req 0 + job 0 = idle.
    git_rhc: ?*HostConn = null,
    git_rreq: u32 = 0,
    git_rjob: u64 = 0,
    /// The one in-flight compare-two-files job (diffview.zig).
    diff: @import("diffview.zig").DiffState = .{},
    /// Running "Calculate Size" scan (0 = none).
    calc_job: u64 = 0,
    calc_hc: ?*HostConn = null,
    calc_total: u64 = 0,
    calc_files: u64 = 0,
    /// Running duplicate scan: size-bucket phase then hash-confirm.
    dup: ?*DupState = null,
    /// Running archive listing job and its results tab.
    arch_job: u64 = 0,
    arch_hc: ?*HostConn = null,
    arch_tab: ?*BTab = null,
    /// Live $EDITOR batch-rename session (at most one).
    editor_rename: ?*EditorRename = null,
    switch_idle: c.guint = 0,
    /// The one open register tab (its register name lives in the
    /// tab's `virtual_spec`).
    register_tab: ?*BTab = null,
    /// Window-level abilities, installed by the owning Window.
    hooks_ctx: ?*anyopaque = null,
    on_host_term: ?HostAction = null,
    on_host_open: ?HostAction = null,
    /// Run a shell command as an app session on a host (declarative
    /// .action files with RunsOnHost).
    on_host_exec: ?HostAction = null,
    /// In-flight attr_list for an open Properties dialog.
    attr_request: ?AttrRequest = null,
    /// In-flight snapshot ("Previous Versions") discovery for an open
    /// Properties dialog.
    snap_request: ?*SnapRequest = null,
    /// The open column picker, so editing a column can close it.
    column_picker: ?*c.GtkWidget = null,
    /// Emblem rules (name globs / attribute predicates -> badge icon).
    emblems: emblems_mod.Rules = undefined,
    /// Media-metadata columns: the answer cache, the one batch in
    /// flight and its coalescing timer (mediacols.zig).
    media: mediacols.State = .{},
    /// Label probes in flight (folder size, checksum, media info).
    probes: std.ArrayList(LabelProbe) = .empty,
    /// Background-click folder Properties: the one stat in flight
    /// (props.zig folderProperties/feedFolderProps).
    props_stat_req: u32 = 0,
    props_stat_tab: ?*BTab = null,
    /// Resolve the other browser face in this sketerm tab (the
    /// orthodox dual-pane destination); null when there is only one.
    on_peer: ?*const fn (ctx: *anyopaque, pane: *Pane) ?*BrowserView = null,
    /// Window-owned service: durable downloads and sync-back survive
    /// this pane, this window, and GUI process restarts.
    transfer_service: ?*file_transfers.Service = null,
    /// Scratch for a transient preview note handed out as a slice
    /// (preview.zig previewNoteScratch). Deliberately NOT shared with
    /// anything else: a second borrower would rewrite a live note.
    note_scratch: [128]u8 = undefined,
    /// Type-ahead jump buffer; cleared after TYPEAHEAD_RESET_US idle.
    ta_buf: [64]u8 = undefined,
    ta_len: usize = 0,
    ta_last_us: i64 = 0,

    // Method index: the bodies live in the named module, these decl
    // aliases keep `self.foo()` resolving from every call site.

    // conn.zig -- per-host connections, the fs wire, replies and deltas
    pub const hostConnFor = @import("conn.zig").hostConnFor;
    pub const connectThreadMain = @import("conn.zig").connectThreadMain;
    pub const onConnectIdle = @import("conn.zig").onConnectIdle;
    pub const wireReady = @import("conn.zig").wireReady;
    pub const hostDied = @import("conn.zig").hostDied;
    pub const sendOp = @import("conn.zig").sendOp;
    pub const sendOpOk = @import("conn.zig").sendOpOk;
    pub const closeViewOf = @import("conn.zig").closeViewOf;
    pub const ensureWriteFlush = @import("conn.zig").ensureWriteFlush;
    pub const scheduleReconnect = @import("conn.zig").scheduleReconnect;
    pub const clearReconnect = @import("conn.zig").clearReconnect;
    pub const requestHostDirs = @import("conn.zig").requestHostDirs;
    pub const attrSpec = @import("conn.zig").attrSpec;
    pub const sendListingOp = @import("conn.zig").sendListingOp;
    pub const requestFreeSpace = @import("conn.zig").requestFreeSpace;
    pub const openDir = @import("conn.zig").openDir;
    pub const refreshDir = @import("conn.zig").refreshDir;
    pub const clearFailureCaches = @import("preview.zig").clearFailureCaches;
    pub const queueListing = @import("conn.zig").queueListing;
    pub const nextReq = @import("conn.zig").nextReq;
    pub const onFdReadable = @import("conn.zig").onFdReadable;
    pub const onReply = @import("conn.zig").onReply;
    pub const listingRefused = @import("conn.zig").listingRefused;
    pub const failPendingListings = @import("conn.zig").failPendingListings;
    pub const dropPending = @import("conn.zig").dropPending;
    pub const cancelPendingDir = @import("conn.zig").cancelPendingDir;
    pub const onDelta = @import("conn.zig").onDelta;
    pub const makeDir = @import("conn.zig").makeDir;

    // nav.zig -- tabs, navigation, path bar, type-ahead
    pub const newTabSpec = @import("nav.zig").newTabSpec;
    pub const newTab = @import("nav.zig").newTab;
    pub const currentTab = @import("nav.zig").currentTab;
    pub const onTabCloseClicked = @import("nav.zig").onTabCloseClicked;
    pub const closeTab = @import("nav.zig").closeTab;
    pub const navigate = @import("nav.zig").navigate;
    pub const navigateMode = @import("nav.zig").navigateMode;
    pub const navigateSpec = @import("nav.zig").navigateSpec;
    pub const navigateSpecMode = @import("nav.zig").navigateSpecMode;
    pub const goBack = @import("nav.zig").goBack;
    pub const goForward = @import("nav.zig").goForward;
    pub const commitNavigation = @import("nav.zig").commitNavigation;
    pub const goUp = @import("nav.zig").goUp;
    pub const toggleExpand = @import("nav.zig").toggleExpand;
    pub const updateTabLabel = @import("nav.zig").updateTabLabel;
    pub const applyPaneFaceTitle = @import("nav.zig").applyPaneFaceTitle;
    pub const syncPathEntry = @import("nav.zig").syncPathEntry;
    pub const setStatus = @import("nav.zig").setStatus;
    pub const setStatusFmt = @import("nav.zig").setStatusFmt;
    pub const countSelected = @import("nav.zig").countSelected;
    pub const entryForPath = @import("nav.zig").entryForPath;
    pub const onBrowserKey = @import("nav.zig").onBrowserKey;
    pub const onBackClicked = @import("nav.zig").onBackClicked;
    pub const onFwdClicked = @import("nav.zig").onFwdClicked;
    pub const onUpClicked = @import("nav.zig").onUpClicked;
    pub const onNewTabClicked = @import("nav.zig").onNewTabClicked;
    pub const onTerminalClicked = @import("nav.zig").onTerminalClicked;
    pub const onCwdSyncClicked = @import("nav.zig").onCwdSyncClicked;
    pub const onHiddenToggled = @import("nav.zig").onHiddenToggled;
    pub const cancelPathCompletion = @import("nav.zig").cancelPathCompletion;
    pub const closePathCompletion = @import("nav.zig").closePathCompletion;
    pub const onPathChanged = @import("nav.zig").onPathChanged;
    pub const onCompletionTimeout = @import("nav.zig").onCompletionTimeout;
    pub const renderPathCompletion = @import("nav.zig").renderPathCompletion;
    pub const showCompletionNames = @import("nav.zig").showCompletionNames;
    pub const onCompletionActivated = @import("nav.zig").onCompletionActivated;
    pub const onPathKey = @import("nav.zig").onPathKey;
    pub const showSelectPattern = @import("nav.zig").showSelectPattern;
    pub const showFrecencyJump = @import("nav.zig").showFrecencyJump;
    pub const onPatternActivate = @import("nav.zig").onPatternActivate;
    pub const selectPattern = @import("nav.zig").selectPattern;
    pub const selectPatternDirs = @import("nav.zig").selectPatternDirs;
    pub const typeaheadReset = @import("nav.zig").typeaheadReset;
    pub const typeaheadBackspace = @import("nav.zig").typeaheadBackspace;
    pub const typeahead = @import("nav.zig").typeahead;
    pub const typeaheadJump = @import("nav.zig").typeaheadJump;
    pub const onPathActivate = @import("nav.zig").onPathActivate;
    pub const onSwitchPage = @import("nav.zig").onSwitchPage;
    pub const idleAfterSwitch = @import("nav.zig").idleAfterSwitch;
    pub const applyHistoryIntent = @import("nav.zig").applyHistoryIntent;

    // locbar.zig -- breadcrumb face, sibling and history dropdowns
    pub const installLocationFace = @import("locbar.zig").installLocationFace;
    pub const installHistoryMenuGesture = @import("locbar.zig").installHistoryMenuGesture;
    pub const rebuildCrumbs = @import("locbar.zig").rebuildCrumbs;
    pub const cancelSiblings = @import("locbar.zig").cancelSiblings;
    pub const feedSiblings = @import("locbar.zig").feedSiblings;
    pub const showSiblingPopover = @import("locbar.zig").showSiblingPopover;
    pub const toggleLocationFace = @import("locbar.zig").toggleLocationFace;
    pub const showEntryFace = @import("locbar.zig").showEntryFace;
    pub const showCrumbFace = @import("locbar.zig").showCrumbFace;
    pub const foldLocationFace = @import("locbar.zig").foldLocationFace;
    pub const showHistoryMenu = @import("locbar.zig").showHistoryMenu;
    pub const historyJump = @import("locbar.zig").historyJump;
    pub const installNavGestures = @import("locbar.zig").installNavGestures;

    // tabs.zig -- tab conveniences (duplicate, reopen, middle click)
    pub const tabStateOf = @import("tabs.zig").tabStateOf;
    pub const duplicateTab = @import("tabs.zig").duplicateTab;
    pub const stashClosedTab = @import("tabs.zig").stashClosedTab;
    pub const reopenClosedTab = @import("tabs.zig").reopenClosedTab;
    pub const installTabConveniences = @import("tabs.zig").installTabConveniences;
    pub const installGridMiddleClick = @import("tabs.zig").installGridMiddleClick;

    // render.zig -- listing rendering, columns, rows, emblems
    pub const renderCurrent = @import("render.zig").renderCurrent;
    pub const scheduleListingRender = @import("render.zig").scheduleListingRender;
    pub const renderTab = @import("render.zig").renderTab;
    pub const applyViewChrome = @import("render.zig").applyViewChrome;
    pub const headerButton = @import("render.zig").headerButton;
    pub const attrHeaderButton = @import("render.zig").attrHeaderButton;
    pub const onAttrHeaderClicked = @import("render.zig").onAttrHeaderClicked;
    pub const onAttrColumnRemove = @import("render.zig").onAttrColumnRemove;
    pub const onAttrColumnAdd = @import("render.zig").onAttrColumnAdd;
    pub const closeColumnPicker = @import("render.zig").closeColumnPicker;
    pub const reopenTabListing = @import("render.zig").reopenTabListing;
    pub const onHeaderClicked = @import("render.zig").onHeaderClicked;
    pub const updateSortHeader = @import("render.zig").updateSortHeader;
    pub const onColumnPicker = @import("render.zig").onColumnPicker;
    pub const onColumnToggled = @import("render.zig").onColumnToggled;
    pub const renderList = @import("render.zig").renderList;
    pub const ensureFlowbox = @import("render.zig").ensureFlowbox;
    pub const renderGrid = @import("render.zig").renderGrid;
    pub const appendTile = @import("render.zig").appendTile;
    pub const onGridChildActivated = @import("render.zig").onGridChildActivated;
    pub const onGridSelectionChanged = @import("render.zig").onGridSelectionChanged;
    pub const onGridRightClick = @import("render.zig").onGridRightClick;
    pub const renderMillerCols = @import("render.zig").renderMillerCols;
    pub const onMillerRowActivated = @import("render.zig").onMillerRowActivated;
    pub const renderDirRows = @import("render.zig").renderDirRows;
    pub const appendRowTree = @import("render.zig").appendRowTree;
    pub const renderGroupedRows = @import("render.zig").renderGroupedRows;
    pub const appendGroupHeader = @import("render.zig").appendGroupHeader;
    pub const freeRowCtx = @import("render.zig").freeRowCtx;
    pub const appendRow = @import("render.zig").appendRow;
    pub const emblemFor = @import("render.zig").emblemFor;
    pub const appendColumnCell = @import("render.zig").appendColumnCell;
    pub const freeRowCtxClosure = @import("render.zig").freeRowCtxClosure;
    pub const onExpandClicked = @import("render.zig").onExpandClicked;
    pub const onSelectionChanged = @import("render.zig").onSelectionChanged;
    pub const onRowActivated = @import("render.zig").onRowActivated;
    pub const activateEntry = @import("render.zig").activateEntry;
    pub const loadFileColors = @import("render.zig").loadFileColors;
    pub const fileColorFor = @import("render.zig").fileColorFor;
    pub const sortClicked = @import("render.zig").sortClicked;

    // mediacols.zig -- media-metadata columns (batched, bounded fetch)
    pub const mediaApplyValues = @import("mediacols.zig").applyValues;
    pub const mediaSchedule = @import("mediacols.zig").schedule;
    pub const mediaCancel = @import("mediacols.zig").cancel;
    pub const mediaResetForNavigation = @import("mediacols.zig").resetForNavigation;
    pub const mediaHostDied = @import("mediacols.zig").hostDied;
    pub const mediaFeed = @import("mediacols.zig").feed;
    pub const mediaLookup = @import("mediacols.zig").lookup;
    pub const mediaBeginSortFill = @import("mediacols.zig").beginSortFill;

    // views.zig -- grouping, zoom, filter, flat view, folder memory
    pub const installViewMenu = @import("views.zig").installViewMenu;
    pub const installViewGestures = @import("views.zig").installViewGestures;
    pub const toggleFilter = @import("views.zig").toggleFilter;
    pub const setFilter = @import("views.zig").setFilter;
    pub const syncFilterEntry = @import("views.zig").syncFilterEntry;
    pub const zoomBy = @import("views.zig").zoomBy;
    pub const setGrouping = @import("views.zig").setGrouping;
    pub const toggleGroup = @import("views.zig").toggleGroup;
    pub const toggleFlat = @import("views.zig").toggleFlat;
    pub const startFlat = @import("views.zig").startFlat;
    pub const stopFlat = @import("views.zig").stopFlat;
    pub const applyFolderMemory = @import("views.zig").applyFolderMemory;
    pub const rememberFolder = @import("views.zig").rememberFolder;
    pub const forgetFolder = @import("views.zig").forgetFolder;
    pub const forgetAllFolders = @import("views.zig").forgetAllFolders;

    // selection.zig -- sticky selection, visual mode, registers
    pub const installSelectionMenu = @import("selection.zig").installSelectionMenu;
    pub const installSelectionGestures = @import("selection.zig").installSelectionGestures;
    pub const migrateCollection = @import("selection.zig").migrateCollection;
    pub const regStore = @import("selection.zig").regStore;
    pub const toggleSticky = @import("selection.zig").toggleSticky;
    pub const toggleMarkFocused = @import("selection.zig").toggleMarkFocused;
    pub const toggleVisual = @import("selection.zig").toggleVisual;
    pub const commitVisual = @import("selection.zig").commitVisual;
    pub const cancelVisual = @import("selection.zig").cancelVisual;
    pub const visualForget = @import("selection.zig").visualForget;
    pub const markDialog = @import("selection.zig").markDialog;
    pub const markResultsDialog = @import("selection.zig").markResultsDialog;
    pub const markPaths = @import("selection.zig").markPaths;
    pub const markEntries = @import("selection.zig").markEntries;
    pub const registerTab = @import("selection.zig").registerTab;
    pub const appendRegisterRow = @import("selection.zig").appendRegisterRow;
    pub const selectRegisterHere = @import("selection.zig").selectRegisterHere;
    pub const copyRegisterHere = @import("selection.zig").copyRegisterHere;
    pub const deleteRegister = @import("selection.zig").deleteRegister;

    // menu.zig -- the entry context menu
    pub const menuButton = @import("menu.zig").menuButton;
    pub const onRightClick = @import("menu.zig").onRightClick;
    pub const showEntryMenu = @import("menu.zig").showEntryMenu;
    pub const onPopoverClosed = @import("menu.zig").onPopoverClosed;
    pub const connectPopoverAutoUnparent = @import("menu.zig").connectPopoverAutoUnparent;
    pub const menuDone = @import("menu.zig").menuDone;
    pub const onMenuTerminalHere = @import("menu.zig").onMenuTerminalHere;
    pub const onMenuOpenTab = @import("menu.zig").onMenuOpenTab;
    pub const onMenuCopy = @import("menu.zig").onMenuCopy;
    pub const onMenuCut = @import("menu.zig").onMenuCut;
    pub const onMenuCopyToPeer = @import("menu.zig").onMenuCopyToPeer;
    pub const onMenuMoveToPeer = @import("menu.zig").onMenuMoveToPeer;
    pub const onMenuCopyPath = @import("menu.zig").onMenuCopyPath;
    pub const onMenuPaste = @import("menu.zig").onMenuPaste;
    pub const onMenuTermTab = @import("menu.zig").onMenuTermTab;
    pub const onMenuHostOpen = @import("menu.zig").onMenuHostOpen;
    pub const onMenuOpenWith = @import("menu.zig").onMenuOpenWith;
    pub const onMenuCollectionOpen = @import("menu.zig").onMenuCollectionOpen;
    pub const onMenuCompare = @import("menu.zig").onMenuCompare;
    pub const onMenuBookmark = @import("menu.zig").onMenuBookmark;
    pub const onMenuPin = @import("menu.zig").onMenuPin;
    pub const onMenuEvict = @import("menu.zig").onMenuEvict;
    pub const onMenuTrashRestoreItem = @import("menu.zig").onMenuTrashRestoreItem;
    pub const onMenuUndo = @import("menu.zig").onMenuUndo;
    pub const onMenuCalcSize = @import("menu.zig").onMenuCalcSize;
    pub const onMenuAnalyzeUsage = @import("menu.zig").onMenuAnalyzeUsage;
    pub const onMenuFindDups = @import("menu.zig").onMenuFindDups;
    pub const onMenuNewFolder = @import("menu.zig").onMenuNewFolder;
    pub const onMenuRename = @import("menu.zig").onMenuRename;
    pub const onMenuBrowseArchive = @import("menu.zig").onMenuBrowseArchive;
    pub const onMenuExtractMember = @import("menu.zig").onMenuExtractMember;
    pub const onMenuExtractHere = @import("menu.zig").onMenuExtractHere;
    pub const onMenuArchiveCreate = @import("menu.zig").onMenuArchiveCreate;
    pub const appendActionItems = @import("menu.zig").appendActionItems;
    pub const onActionClicked = @import("menu.zig").onActionClicked;

    // ops.zig -- clipboard, rename, delete/trash, undo, archives, tags
    pub const copyToClip = @import("ops.zig").copyToClip;
    pub const beginPaste = @import("ops.zig").beginPaste;
    pub const pasteOne = @import("ops.zig").pasteOne;
    pub const resolvePasteConflict = @import("ops.zig").resolvePasteConflict;
    pub const settleUserBatch = @import("ops.zig").settleUserBatch;
    pub const tabAlive = @import("ops.zig").tabAlive;
    pub const uniqueDstName = @import("ops.zig").uniqueDstName;
    pub const duplicateEntry = @import("ops.zig").duplicateEntry;
    pub const linkHere = @import("ops.zig").linkHere;
    pub const hardlinkPossible = @import("ops.zig").hardlinkPossible;
    pub const findEntryTags = @import("ops.zig").findEntryTags;
    pub const onMenuTags = @import("ops.zig").onMenuTags;
    pub const onTagsActivate = @import("ops.zig").onTagsActivate;
    pub const onMenuExportSel = @import("ops.zig").onMenuExportSel;
    pub const onMenuEditorRename = @import("ops.zig").onMenuEditorRename;
    pub const onEditorRenameDone = @import("ops.zig").onEditorRenameDone;
    pub const onMenuBatchRename = @import("ops.zig").onMenuBatchRename;
    pub const onBatchRenameApply = @import("ops.zig").onBatchRenameApply;
    pub const setMountXattr = @import("ops.zig").setMountXattr;
    pub const onMenuTrash = @import("ops.zig").onMenuTrash;
    pub const onMenuDelete = @import("ops.zig").onMenuDelete;
    pub const onDeleteConfirmed = @import("ops.zig").onDeleteConfirmed;
    pub const entryDialog = @import("ops.zig").entryDialog;
    pub const startInlineRename = @import("ops.zig").startInlineRename;
    pub const onEntryDialogActivate = @import("ops.zig").onEntryDialogActivate;
    pub const startTrashRestore = @import("ops.zig").startTrashRestore;
    pub const feedRestore = @import("ops.zig").feedRestore;
    pub const clearRedo = @import("ops.zig").clearRedo;
    pub const pushUndo = @import("ops.zig").pushUndo;
    pub const pushHistoryStack = @import("ops.zig").pushHistoryStack;
    pub const makeUndo = @import("ops.zig").makeUndo;
    pub const deferUndo = @import("ops.zig").deferUndo;
    pub const deferUndoMode = @import("ops.zig").deferUndoMode;
    pub const recordTrashUndo = @import("ops.zig").recordTrashUndo;
    pub const performUndo = @import("ops.zig").performUndo;
    pub const performRedo = @import("ops.zig").performRedo;
    pub const beginHistory = @import("ops.zig").beginHistory;
    pub const deferHistory = @import("ops.zig").deferHistory;
    pub const finishHistory = @import("ops.zig").finishHistory;
    pub const restoreHistory = @import("ops.zig").restoreHistory;
    pub const updateTrashResult = @import("ops.zig").updateTrashResult;
    pub const startArchiveBrowse = @import("ops.zig").startArchiveBrowse;
    pub const onArchiveMember = @import("ops.zig").onArchiveMember;
    pub const extractAndOpenMember = @import("ops.zig").extractAndOpenMember;
    pub const onListDrop = @import("ops.zig").onListDrop;
    pub const dropSpecInto = @import("ops.zig").dropSpecInto;
    pub const peerView = @import("ops.zig").peerView;
    pub const sendToPeer = @import("ops.zig").sendToPeer;

    // jobs.zig -- daemon jobs and client-mediated transfers
    pub const feedTransfers = @import("jobs.zig").feedTransfers;
    pub const verifyCopies = @import("jobs.zig").verifyCopies;
    pub const pumpTransferQueue = @import("jobs.zig").pumpTransferQueue;
    pub const moveTransfer = @import("jobs.zig").moveTransfer;
    pub const setTransferPaused = @import("jobs.zig").setTransferPaused;
    pub const unclaimMediated = @import("jobs.zig").unclaimMediated;
    pub const pumpCopyQueue = @import("jobs.zig").pumpCopyQueue;
    pub const pumpCopyAcks = @import("jobs.zig").pumpCopyAcks;
    pub const pumpDeferredTransfers = @import("jobs.zig").pumpDeferredTransfers;
    pub const cancelQueuedCopy = @import("jobs.zig").cancelQueuedCopy;
    pub const cancelDeferredTransfer = @import("jobs.zig").cancelDeferredTransfer;
    pub const moveQueuedCopy = @import("jobs.zig").moveQueuedCopy;
    pub const reapTransfers = @import("jobs.zig").reapTransfers;
    pub const startTransfer = @import("jobs.zig").startTransfer;
    pub const startBatchTransfer = @import("jobs.zig").startBatchTransfer;
    pub const retryCopyJob = @import("jobs.zig").retryCopyJob;
    pub const dropSupersededRetryRows = @import("jobs.zig").dropSupersededRetryRows;
    pub const cancelPendingRetries = @import("jobs.zig").cancelPendingRetries;
    pub const cancelScheduledRetry = @import("jobs.zig").cancelScheduledRetry;
    pub const startDaemonJob = @import("jobs.zig").startDaemonJob;
    pub const startDaemonJobResumable = @import("jobs.zig").startDaemonJobResumable;
    pub const startDaemonJobKind = @import("jobs.zig").startDaemonJobKind;
    pub const onJobEvent = @import("jobs.zig").onJobEvent;
    pub const startDaemonJobUndo = @import("jobs.zig").startDaemonJobUndo;
    pub const startHistoryJob = @import("jobs.zig").startHistoryJob;
    pub const startDaemonJobTo = @import("jobs.zig").startDaemonJobTo;
    pub const markJob = @import("jobs.zig").markJob;

    // conflict.zig -- the non-blocking paste-collision queue + dialog
    pub const feedConflicts = @import("conflict.zig").feedConflicts;

    // templates.zig -- New from Template (the HOST's Templates dir)
    pub const showTemplateMenu = @import("templates.zig").showTemplateMenu;
    pub const feedTemplates = @import("templates.zig").feedTemplates;
    pub const templatesHostDirs = @import("templates.zig").onHostDirs;
    pub const instantiateTemplate = @import("templates.zig").instantiate;

    // jobpanel.zig -- the jobs/transfers panel (rows, rate, controls)
    pub const jobsButton = @import("jobpanel.zig").jobsButton;
    pub const onJobBtn = @import("jobpanel.zig").onJobBtn;
    pub const renderJobs = @import("jobpanel.zig").renderJobs;

    // open.zig -- opening files, Open With, edit sync-back
    pub const openRemoteFile = @import("open.zig").openRemoteFile;
    pub const openRemoteFileHc = @import("open.zig").openRemoteFileHc;
    pub const openPathOnHost = @import("open.zig").openPathOnHost;
    pub const openWithDialog = @import("open.zig").openWithDialog;
    pub const launchViewer = @import("open.zig").launchViewer;
    pub const launchCastPlayer = @import("open.zig").launchCastPlayer;
    pub const appChoiceButton = @import("open.zig").appChoiceButton;
    pub const onAppBtnClicked = @import("open.zig").onAppBtnClicked;
    pub const populateHostApps = @import("open.zig").populateHostApps;
    pub const registerEditWatch = @import("open.zig").registerEditWatch;
    pub const onEditWatchChanged = @import("open.zig").onEditWatchChanged;
    pub const uploadEditWatch = @import("open.zig").uploadEditWatch;

    // preview.zig -- preview pane, Quick Look overlay, thumbnails
    pub const ensureThumbWorker = @import("preview.zig").ensureThumbWorker;
    pub const thumbWorkerMain = @import("preview.zig").thumbWorkerMain;
    pub const thumbProcess = @import("preview.zig").thumbProcess;
    pub const thumbSaveLocal = @import("preview.zig").thumbSaveLocal;
    pub const onThumbIdle = @import("preview.zig").onThumbIdle;
    pub const applyThumbResult = @import("preview.zig").applyThumbResult;
    pub const scheduleThumbRender = @import("preview.zig").scheduleThumbRender;
    pub const applyThumbTexture = @import("render.zig").applyThumbTexture;
    pub const onThumbRenderTick = @import("preview.zig").onThumbRenderTick;
    pub const thumbLookup = @import("preview.zig").thumbLookup;
    pub const enqueueRemoteThumb = @import("preview.zig").enqueueRemoteThumb;
    pub const pumpRemoteThumbs = @import("preview.zig").pumpRemoteThumbs;
    pub const dropQueuedThumbs = @import("preview.zig").dropQueuedThumbs;
    pub const finishRemoteThumb = @import("preview.zig").finishRemoteThumb;
    pub const feedRemoteThumb = @import("preview.zig").feedRemoteThumb;
    pub const queueRemoteDecode = @import("preview.zig").queueRemoteDecode;
    pub const releaseRemoteThumbFor = @import("preview.zig").releaseRemoteThumbFor;
    pub const markThumbFailed = @import("preview.zig").markThumbFailed;
    pub const clearThumbCache = @import("preview.zig").clearThumbCache;
    pub const clearPreviewContent = @import("preview.zig").clearPreviewContent;
    pub const severPreviewAnimation = @import("preview.zig").severPreviewAnimation;
    pub const previewHostDied = @import("preview.zig").previewHostDied;
    pub const abandonPreviewRead = @import("preview.zig").abandonPreviewRead;
    pub const abandonPreload = @import("preview.zig").abandonPreload;
    pub const shutdownPreviewTransfers = @import("preview.zig").shutdownTransfers;
    pub const updatePreview = @import("preview.zig").updatePreview;
    pub const feedPreview = @import("preview.zig").feedPreview;
    pub const queuePreviewDecode = @import("preview.zig").queuePreviewDecode;
    pub const onPreviewToggled = @import("preview.zig").onPreviewToggled;
    pub const clearPreloadQueue = @import("preview.zig").clearPreloadQueue;
    pub const schedulePreload = @import("preview.zig").schedulePreload;
    pub const pumpPreload = @import("preview.zig").pumpPreload;
    pub const quickLookToggle = @import("preview.zig").quickLookToggle;
    pub const quickLookOpen = @import("preview.zig").quickLookOpen;
    pub const quickLookClose = @import("preview.zig").quickLookClose;

    // props.zig -- Properties dialog, attributes, probes
    pub const endProbe = @import("props.zig").endProbe;
    pub const endProbesFor = @import("props.zig").endProbesFor;
    pub const startProbe = @import("props.zig").startProbe;
    pub const feedProbes = @import("props.zig").feedProbes;
    pub const propsRow = @import("props.zig").propsRow;
    pub const onMenuProperties = @import("props.zig").onMenuProperties;
    pub const endAttrRequest = @import("props.zig").endAttrRequest;
    pub const requestAttrs = @import("props.zig").requestAttrs;
    pub const feedAttrRequest = @import("props.zig").feedAttrRequest;
    pub const endSnapRequest = @import("props.zig").endSnapRequest;
    pub const requestSnapshots = @import("props.zig").requestSnapshots;
    pub const feedSnapRequest = @import("props.zig").feedSnapRequest;
    pub const attrLabel = @import("props.zig").attrLabel;
    pub const onAttrRowSet = @import("props.zig").onAttrRowSet;
    pub const onAttrRowActivate = @import("props.zig").onAttrRowActivate;
    pub const onPropsAttrAdd = @import("props.zig").onPropsAttrAdd;
    pub const onPropsChecksum = @import("props.zig").onPropsChecksum;
    pub const onPropsMediaInfo = @import("props.zig").onPropsMediaInfo;
    pub const onPropsOpenWith = @import("props.zig").onPropsOpenWith;
    pub const onPropsBitToggled = @import("props.zig").onPropsBitToggled;
    pub const onPropsOctalChanged = @import("props.zig").onPropsOctalChanged;
    pub const onPropsCalcSize = @import("props.zig").onPropsCalcSize;
    pub const onPropsApply = @import("props.zig").onPropsApply;
    pub const parseId = @import("props.zig").parseId;

    // places.zig -- places sidebar, bookmarks, saved searches
    pub const onPlacesToggled = @import("places.zig").onPlacesToggled;
    pub const placeHeader = @import("places.zig").placeHeader;
    pub const placeRow = @import("places.zig").placeRow;
    pub const renderPlaces = @import("places.zig").renderPlaces;
    pub const onPlaceActivated = @import("places.zig").onPlaceActivated;
    pub const onPlacesRightClick = @import("places.zig").onPlacesRightClick;
    pub const runSavedSearch = @import("places.zig").runSavedSearch;
    pub const onSaveSearchClicked = @import("places.zig").onSaveSearchClicked;
    pub const savePlaces = @import("places.zig").savePlaces;
    pub const addBookmark = @import("places.zig").addBookmark;
    pub const recordRecentSpec = @import("places.zig").recordRecentSpec;

    // search.zig -- live queries, greps, panels, duplicate finder
    pub const startSearch = @import("search.zig").startSearch;
    pub const runQuery = @import("search.zig").runQuery;
    pub const queryStart = @import("search.zig").queryStart;
    pub const queryForget = @import("search.zig").queryForget;
    pub const queryStarted = @import("search.zig").queryStarted;
    pub const queryConsumeEvent = @import("search.zig").queryConsumeEvent;
    pub const promoteResults = @import("search.zig").promoteResults;
    pub const onPresetClicked = @import("search.zig").onPresetClicked;
    pub const onPresetPicked = @import("search.zig").onPresetPicked;
    pub const onPromoteClicked = @import("search.zig").onPromoteClicked;
    pub const startDupScan = @import("search.zig").startDupScan;
    pub const dupConsumeEvent = @import("search.zig").dupConsumeEvent;
    pub const dupStartHashPhase = @import("search.zig").dupStartHashPhase;
    pub const dupMaybeFinish = @import("search.zig").dupMaybeFinish;
    pub const onSearchToggled = @import("search.zig").onSearchToggled;
    pub const onSearchActivate = @import("search.zig").onSearchActivate;

    // compare.zig -- the compare/sync window
    pub const onMenuSyncHere = @import("compare.zig").onMenuSyncHere;
    pub const startCompare = @import("compare.zig").startCompare;

    // gitstat.zig -- the version-control overlay
    pub const refreshGitOverlay = @import("gitstat.zig").refreshGitOverlay;
    pub const refreshGitForced = @import("gitstat.zig").refreshGitForced;
    pub const scheduleGitRefresh = @import("gitstat.zig").scheduleGitRefresh;
    pub const gitBadgeFor = @import("gitstat.zig").badgeFor;
    pub const gitSummaryNote = @import("gitstat.zig").summaryNote;
    pub const gitTooltipFor = @import("gitstat.zig").tooltipFor;
    pub const feedGit = @import("gitstat.zig").feedGit;
    pub const feedDiff = @import("diffview.zig").feedDiff;
    pub const compareSelected = @import("diffview.zig").compareSelected;

    /// Create a browser face on `pane`, starting at `start_spec`
    /// (a path or host-qualified spec; null/relative = $HOME).
    pub fn attach(allocator: std.mem.Allocator, pane: *Pane, start_spec: ?[]const u8) !*BrowserView {
        // A pane owns at most one browser face; re-attaching would
        // orphan the previous one together with its connections.
        if (fromPane(pane)) |existing| return existing;
        const self = try createCommon(allocator, null);
        self.pane = pane;

        self.buildUi();
        @import("places.zig").registerView(self);
        // The view and selection menus ride the toolbar buildUi just
        // built.
        self.installViewMenu();
        self.installSelectionMenu();
        // After the menus: their two buttons belong to the collapsible
        // cluster, and the sidebar toggle below renders places.
        self.applyChromeState();
        pane.attachBrowser(self.root_box, @ptrCast(self), prepareDestroyCb, destroyCb, focusCb);

        self.openStartSpec(start_spec);
        // The face is already showing (attachBrowser raised it) but had
        // no tab to focus at the time.
        self.focusListing();
        return self;
    }

    /// A paneless browser face for the file picker: same widgets,
    /// same connections, no pane coupling. The caller (PickerWindow)
    /// owns teardown: destroy the widget tree, then call deinit()
    /// once the destroy has unwound. `hooks` must outlive the view.
    pub fn attachForPicker(allocator: std.mem.Allocator, hooks: *PickerHooks, start_spec: ?[]const u8) !*BrowserView {
        const self = try createCommon(allocator, hooks);
        self.buildUi();
        // The picker is one location, not a tab set.
        c.gtk_notebook_set_show_tabs(self.notebook, 0);
        @import("places.zig").registerView(self);
        self.installViewMenu();
        self.installSelectionMenu();
        // The sidebar is part of the picker's fixed shape.
        self.sidebar_open = true;
        self.applyChromeState();
        self.openStartSpec(start_spec);
        return self;
    }

    fn openStartSpec(self: *BrowserView, start_spec: ?[]const u8) void {
        const home = if (c.getenv("HOME")) |h| std.mem.span(@as([*:0]const u8, @ptrCast(h))) else "/";
        if (start_spec) |sp| {
            const loc = parseSpec(sp);
            const path = if (loc.path.len > 0 and loc.path[0] == '/') loc.path else home;
            _ = self.newTab(loc.host, path);
        } else {
            _ = self.newTab(null, home);
        }
    }

    /// Allocate the view and load its persisted user state (places,
    /// file colors); no widgets yet. `picker` must be set this early
    /// because buildUi and the render path both branch on it.
    fn createCommon(allocator: std.mem.Allocator, picker: ?*PickerHooks) !*BrowserView {
        const self = try allocator.create(BrowserView);
        self.* = .{ .allocator = allocator, .picker = picker };
        self.emblems = emblems_mod.load(allocator);
        self.media.init(allocator);
        self.thumbs = std.StringHashMap(*c.GdkTexture).init(allocator);
        self.thumb_failed = std.StringHashMap(void).init(allocator);
        self.git = gitstatus.Overlay.init(allocator);
        self.git_cache = gitstatus.Cache.init(allocator);
        self.git_repo = gitstatus.Repo.init(allocator);
        if (places_mod.load(allocator)) |parsed| {
            defer parsed.deinit();
            for (parsed.value.bookmarks, 0..) |b, i| {
                const owned = allocator.dupe(u8, b) catch continue;
                self.bookmarks.append(allocator, owned) catch {
                    allocator.free(owned);
                    continue;
                };
                const lbl: []const u8 = if (i < parsed.value.bookmark_labels.len) parsed.value.bookmark_labels[i] else "";
                const lowned = allocator.dupe(u8, lbl) catch continue;
                self.bookmark_labels.append(allocator, lowned) catch allocator.free(lowned);
                // Older files have no icons list; pad with "" so the
                // three lists stay strictly parallel.
                const ico: []const u8 = if (i < parsed.value.bookmark_icons.len) parsed.value.bookmark_icons[i] else "";
                const iowned = allocator.dupe(u8, ico) catch continue;
                self.bookmark_icons.append(allocator, iowned) catch allocator.free(iowned);
            }
            for (parsed.value.hidden_sections) |k| {
                const owned = allocator.dupe(u8, k) catch continue;
                self.hidden_sections.append(allocator, owned) catch allocator.free(owned);
            }
            for (parsed.value.section_order) |k| {
                const owned = allocator.dupe(u8, k) catch continue;
                self.section_order.append(allocator, owned) catch allocator.free(owned);
            }
            self.widgets.loadFrom(allocator, parsed.value.widget_sections);
            for (parsed.value.recent) |r| {
                var normalized_buf: [4300]u8 = undefined;
                const normalized = places_mod.normalizeRecentSpec(r, &normalized_buf);
                const owned = allocator.dupe(u8, normalized) catch continue;
                self.recent.append(allocator, owned) catch allocator.free(owned);
            }
            for (parsed.value.collapsed) |s| {
                const owned = allocator.dupe(u8, s) catch continue;
                self.collapsed.append(allocator, owned) catch allocator.free(owned);
            }
            for (parsed.value.frecency) |fe| {
                if (fe.spec.len == 0) continue;
                const owned = allocator.dupe(u8, fe.spec) catch continue;
                self.frecency.append(allocator, .{ .spec = owned, .count = fe.count, .last_ms = fe.last_ms }) catch allocator.free(owned);
            }
            self.sidebar_px = places_mod.clampSidebarPx(parsed.value.sidebar_px);
            self.sidebar_open = parsed.value.sidebar_open;
            self.zebra = parsed.value.zebra;
            self.preview_px = std.math.clamp(parsed.value.preview_px, 220, 700);
            self.side_info = parsed.value.side_info;
            for (parsed.value.searches) |sq| {
                const spec = allocator.dupe(u8, sq.spec) catch continue;
                const pat = allocator.dupe(u8, sq.pattern) catch {
                    allocator.free(spec);
                    continue;
                };
                self.saved_searches.append(allocator, .{ .spec = spec, .pattern = pat, .content = sq.content }) catch {
                    allocator.free(spec);
                    allocator.free(pat);
                };
            }
            // The collection shelf is now the `collection` register;
            // a shelf written by an older build moves over here (and
            // leaves places.json) exactly once.
            self.migrateCollection(parsed.value.collection);
        }
        self.loadFileColors();
        return self;
    }

    /// The Window whose widget tree hosts this browser face (null
    /// before attach or after teardown).
    pub fn ownerWindow(self: *BrowserView) ?*@import("../window.zig").Window {
        const root = c.gtk_widget_get_root(self.root_box) orelse return null;
        return @import("../remotectl.zig").windowFromGtk(@ptrCast(@alignCast(root)));
    }

    fn destroyCb(ctx: *anyopaque) void {
        const self: *BrowserView = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn prepareDestroyCb(ctx: *anyopaque) void {
        const self: *BrowserView = @ptrCast(@alignCast(ctx));
        self.widgets_dead = true;
        self.severPreviewAnimation();
    }

    fn focusCb(ctx: *anyopaque) void {
        const self: *BrowserView = @ptrCast(@alignCast(ctx));
        // Raising the face re-asserts its title on the pane titlebar
        // (the flip cleared whatever the previous face had put there).
        self.applyPaneFaceTitle();
        self.focusListing();
    }

    /// Re-focus the listing when a rebuild DESTROYED the focused widget
    /// (navigating from a clicked row or breadcrumb does exactly that,
    /// leaving the window with no focus at all -- and therefore no
    /// working chords). Focus that has legitimately moved elsewhere,
    /// including into another pane, is left alone.
    pub fn refocusListingIfLost(self: *BrowserView) void {
        const root = c.gtk_widget_get_root(self.root_box) orelse return;
        if (c.gtk_root_get_focus(root)) |focused| {
            // Focus on a widget that is not actually visible is LOST
            // focus, not focus that moved: hiding the scroller (the
            // empty/failed placeholder states) leaves the clicked row
            // as the window's focus widget while no key can ever reach
            // it -- every chord went dead there.
            if (c.gtk_widget_is_visible(focused) != 0) return;
        }
        self.focusListing();
    }

    /// Select a host-qualified file once the current streamed listing contains it.
    pub fn queueReveal(self: *BrowserView, spec: []const u8) void {
        const tab = self.currentTab() orelse return;
        const loc = parseSpec(spec);
        const same_host = if (loc.host) |host|
            if (tab.hc.host) |tab_host| std.mem.eql(u8, host, tab_host) else false
        else
            tab.hc.host == null;
        if (!same_host or loc.path.len == 0) return;
        const owned_path = self.allocator.dupe(u8, loc.path) catch return;
        const owned_host = self.allocator.dupe(u8, loc.host orelse "") catch {
            self.allocator.free(owned_path);
            return;
        };
        if (tab.pending_reveal) |old| self.allocator.free(old);
        if (tab.pending_reveal_host) |old| self.allocator.free(old);
        tab.pending_reveal = owned_path;
        tab.pending_reveal_host = owned_host;
        if (std.fs.path.basename(loc.path).len > 0 and std.fs.path.basename(loc.path)[0] == '.') tab.show_hidden = true;
        if (tab.filter.len > 0) {
            self.allocator.free(tab.filter);
            tab.filter = &.{};
        }
        tab.vs.collapsed.clearRetainingCapacity();
        self.renderCurrent();
    }

    /// After a NAVIGATION, focus belongs inside the face. Destroying
    /// the clicked row makes GTK move focus to some visible widget
    /// OUTSIDE the browser (the window tab bar), where the lost-focus
    /// guard above cannot tell it from focus the user moved -- and
    /// every chord went dead after entering a folder. Navigation is
    /// always browser-initiated, so pulling focus back is correct.
    pub fn refocusListingAfterNav(self: *BrowserView) void {
        const root = c.gtk_widget_get_root(self.root_box) orelse return;
        if (c.gtk_root_get_focus(root)) |focused| {
            if (c.gtk_widget_is_visible(focused) != 0 and
                c.gtk_widget_is_ancestor(focused, self.root_box) != 0) return;
        }
        self.focusListing();
    }

    /// Capture-phase press anywhere in the face. Focus already inside
    /// is left alone -- the clicked widget claims it in the target
    /// phase, which is the normal path. Only focus sitting in ANOTHER
    /// pane is pulled over, and the location face that pane was
    /// editing folds back so exactly one address bar is ever open.
    fn onFaceClicked(_: *c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        if (self.widgets_dead) return;
        const root = c.gtk_widget_get_root(self.root_box) orelse return;
        if (c.gtk_root_get_focus(root)) |focused| {
            if (focused == self.root_box or c.gtk_widget_is_ancestor(focused, self.root_box) != 0) return;
        }
        if (self.peerView()) |peer| _ = peer.foldLocationFace();
        self.focusListing();
    }

    /// Put GTK focus on the current tab's rows, so the browser's chords
    /// (Ctrl+L, Ctrl+Shift+B, type-ahead) reach its key controller.
    /// Falls back to the first focusable widget in the face -- what
    /// matters is that focus is INSIDE it, since the controller sits on
    /// the root and runs in the bubble phase.
    pub fn focusListing(self: *BrowserView) void {
        if (self.currentTab()) |tab| {
            // The rows are HIDDEN whenever the empty/failed message
            // shows, and a hidden widget cannot take focus -- so the
            // message itself is the target in that state.
            const target: *c.GtkWidget = if (c.gtk_widget_get_visible(tab.empty_box) != 0)
                tab.empty_box
            else if (tab.view_mode == .icons and tab.flowbox != null)
                @ptrCast(@alignCast(tab.flowbox.?))
            else
                @ptrCast(@alignCast(tab.colview));
            if (c.gtk_widget_grab_focus(target) != 0) return;
        }
        _ = c.gtk_widget_child_focus(self.root_box, c.GTK_DIR_TAB_FORWARD);
    }

    /// The file-manager clipboard. Process-wide on purpose: a copy in
    /// one pane must paste in every other one, local or remote.
    pub fn clipboard(self: *BrowserView) *clipboard_mod.Board {
        return clipboard_mod.shared(self.allocator);
    }

    /// The BrowserView riding `pane`, if any. Safe cast: browser_ctx
    /// is only ever set by attach().
    pub fn fromPane(pane: *Pane) ?*BrowserView {
        const ctx = pane.browser_ctx orelse return null;
        return @ptrCast(@alignCast(ctx));
    }

    /// The current tab's location as a host-qualified spec, written
    /// into the CALLER's `buf` (size it `paths.SPEC_BUF_LEN`): a
    /// shared scratch buffer would alias between two calls in one
    /// expression. The result may point at the tab's own path when
    /// `buf` is too small, so it is only valid while the tab is.
    pub fn currentSpec(self: *BrowserView, buf: []u8) ?[]const u8 {
        const tab = self.currentTab() orelse return null;
        return tab.spec(buf);
    }

    /// Internal tab location specs in notebook order (layout
    /// persistence; host-qualified for remote tabs).
    pub fn tabPaths(self: *BrowserView, arena: std.mem.Allocator) ![]const []const u8 {
        const out = try arena.alloc([]const u8, self.tabs.items.len);
        for (self.tabs.items, 0..) |t, i| {
            var buf: [4200]u8 = undefined;
            out[i] = try arena.dupe(u8, t.spec(&buf));
        }
        return out;
    }

    /// Full GTK-free state projection used by layout persistence.
    /// Per-tab snapshotting is tabs.zig's tabStateOf, which
    /// duplicate-tab and the closed-tab ring share.
    pub fn paneState(self: *BrowserView, arena: std.mem.Allocator) !browser_model.PaneState {
        const tabs = try arena.alloc(browser_model.TabState, self.tabs.items.len);
        for (self.tabs.items, 0..) |tab, i| tabs[i] = try tabsmod.tabStateOf(arena, tab);
        const active = c.gtk_notebook_get_current_page(self.notebook);
        return .{
            .active_tab = if (active >= 0) @intCast(active) else 0,
            .tabs = tabs,
        };
    }

    fn appendHistoryRef(self: *BrowserView, list: *std.ArrayList([]u8), ref: browser_model.FileRef) void {
        var buf: [4300]u8 = undefined;
        const spec = ref.format(&buf) catch return;
        const owned = self.allocator.dupe(u8, spec) catch return;
        list.append(self.allocator, owned) catch self.allocator.free(owned);
    }

    /// Apply a GTK-free tab snapshot to a freshly created tab
    /// (layout restore, duplicate-tab, undo-close-tab).
    pub fn restoreTabState(self: *BrowserView, tab: *BTab, state: browser_model.TabState) void {
        for (state.back) |ref| self.appendHistoryRef(&tab.back, ref);
        for (state.forward) |ref| self.appendHistoryRef(&tab.fwd, ref);
        for (state.selected) |ref| {
            if (!std.mem.eql(u8, ref.host, tab.hc.host orelse "")) continue;
            const p = self.allocator.dupe(u8, ref.path) catch continue;
            tab.selected.append(self.allocator, p) catch self.allocator.free(p);
        }
        tab.show_hidden = state.show_hidden;
        tab.view_mode = state.view;
        if (state.columns.len > 0) {
            tab.columns = .initEmpty();
            for (state.columns) |col| tab.columns.insert(col);
        }
        for (state.attr_columns) |name| {
            // Both column sources persist through the same list; an
            // unrecognized namespace is dropped rather than restored
            // as a column nothing can ever fill.
            if (colkeys.sourceOf(name) == null) continue;
            if (tab.attr_columns.items.len >= MAX_ATTR_COLUMNS) break;
            const owned = self.allocator.dupe(u8, name) catch continue;
            tab.attr_columns.append(self.allocator, owned) catch self.allocator.free(owned);
        }
        // Positional against the two column lists filled just above.
        @import("render.zig").applyColumnWidths(tab, state);
        tab.sort_key = state.sort;
        tab.descending = state.descending;
        tab.dirs_first = state.dirs_first;
        tab.vs.grouped = state.grouped;
        tab.vs.zoom = @min(state.zoom, viewsmod.ZOOM_STEPS.len - 1);
        if (state.filter.len > 0) tab.filter = self.allocator.dupe(u8, state.filter) catch &.{};
        if (state.virtual_spec.len > 0) tab.virtual_spec = self.allocator.dupe(u8, state.virtual_spec) catch &.{};
        for (state.expanded) |ref| {
            if (!std.mem.eql(u8, ref.host, tab.hc.host orelse "")) continue;
            if (tab.subdirByPath(ref.path) != null) continue;
            const d = self.makeDir(ref.path) orelse continue;
            tab.subdirs.append(self.allocator, d) catch {
                d.deinit();
                continue;
            };
            self.openDir(tab, d);
        }
    }

    /// Restore the versioned browser model, retaining location-only layout compatibility.
    pub fn attachState(allocator: std.mem.Allocator, pane: *Pane, state: browser_model.PaneState) !*BrowserView {
        if (state.tabs.len == 0) return attach(allocator, pane, null);
        var first_buf: [4300]u8 = undefined;
        const self = try attach(allocator, pane, try state.tabs[0].location.format(&first_buf));
        self.restoreTabState(self.tabs.items[0], state.tabs[0]);
        for (state.tabs[1..]) |ts| {
            var buf: [4300]u8 = undefined;
            const tab = self.newTabSpec(ts.location.format(&buf) catch continue) orelse continue;
            self.restoreTabState(tab, ts);
        }
        if (state.active_tab < self.tabs.items.len)
            c.gtk_notebook_set_current_page(self.notebook, @intCast(state.active_tab));
        if (self.currentTab()) |tab|
            c.gtk_toggle_button_set_active(self.hidden_toggle, @intFromBool(tab.show_hidden));
        return self;
    }

    pub fn deinit(self: *BrowserView) void {
        @import("places.zig").unregisterView(self);
        // Close the quick-look viewer FIRST: its destroy handler and
        // activate callback carry a raw pointer to this view, and the
        // choke-point contract (see preview.State.quick_look) is that
        // the window never outlives the view.
        self.quickLookClose();
        // The client-mediated transfers this view runs are recorded in
        // the durable ledger; hand them back before their Xfers die so
        // the next browser face -- or another process -- resumes them.
        if (self.transfer_service) |service| {
            self.unclaimMediated();
            service.removeMediatedDriver(@ptrCast(self));
        }
        if (self.switch_idle != 0) {
            _ = c.g_source_remove(self.switch_idle);
            self.switch_idle = 0;
        }
        if (self.sidebar_save_src != 0) {
            _ = c.g_source_remove(self.sidebar_save_src);
            self.sidebar_save_src = 0;
        }
        if (self.bar_idle_src != 0) {
            _ = c.g_source_remove(self.bar_idle_src);
            self.bar_idle_src = 0;
        }
        if (self.close_pane_src != 0) {
            _ = c.g_source_remove(self.close_pane_src);
            self.close_pane_src = 0;
        }
        // detachBrowser unparents the root before deinit, so its destroy
        // fence has normally fired already. Other teardown paths can still
        // deinit a live widget tree, and must disconnect the raw self pointer.
        if (!self.root_destroyed) {
            _ = c.g_signal_handlers_disconnect_matched(
                @ptrCast(self.root_box),
                c.G_SIGNAL_MATCH_FUNC | c.G_SIGNAL_MATCH_DATA,
                0,
                0,
                null,
                @ptrCast(@constCast(&onRootDestroy)),
                @ptrCast(self),
            );
        }
        self.widgets_dead = true;
        for (self.reconnects.items) |r| r.destroy(self.allocator);
        self.reconnects.deinit(self.allocator);
        for (self.pending_opens.items) |pending| pending.view = null;
        self.pending_opens.deinit(self.allocator);
        self.jobs_panel.deinit(self.allocator);
        self.copy_queue.deinit(self.allocator);
        for (self.deferred_transfers.items) |d| d.destroy(self.allocator);
        self.deferred_transfers.deinit(self.allocator);
        self.cancelPendingRetries();
        for (self.copy_acks.items) |ack| self.allocator.free(ack.token);
        self.copy_acks.deinit(self.allocator);
        self.conflicts.deinit(self.allocator);
        self.templates.deinit(self.allocator);
        for (self.transfers.items) |t| {
            t.x.deinit();
            self.allocator.free(t.label);
            t.freeExtras(self.allocator);
            self.allocator.destroy(t);
        }
        self.transfers.deinit(self.allocator);
        for (self.watches.items) |wt| wt.destroy(self.allocator);
        self.watches.deinit(self.allocator);
        if (self.compare) |cmp| cmp.close();
        for (self.tabs.items) |t| {
            @import("colview.zig").invalidateBackingRefs(t);
            t.deinit();
        }
        self.tabs.deinit(self.allocator);
        for (self.pending.items) |p| {
            for (p.staged.items) |*e| e.deinit(self.allocator);
            p.staged.deinit(self.allocator);
            // A navigation candidate is owned by the request until it
            // commits; the tabs above never saw it.
            if (p.navigation != null) p.dir.deinit();
            self.allocator.destroy(p);
        }
        self.pending.deinit(self.allocator);
        for (self.pending_jobs.items) |pj| {
            if (pj.undo_op) |u| u.destroy(self.allocator);
            if (pj.undo_trash_orig) |o| self.allocator.free(o);
            if (pj.history_op) |op| op.destroy(self.allocator);
            if (pj.retry) |r| r.destroy(self.allocator);
            self.allocator.free(pj.label);
            self.allocator.destroy(pj);
        }
        self.pending_jobs.deinit(self.allocator);
        for (self.drop_probes.items) |probe| probe.destroy(self.allocator);
        self.drop_probes.deinit(self.allocator);
        if (self.paste_idle != 0) _ = c.g_source_remove(self.paste_idle);
        for (self.paste_runs.items) |run| run.destroy(self.allocator);
        self.paste_runs.deinit(self.allocator);
        for (self.jobs.items) |j| {
            if (j.undo_op) |u| u.destroy(self.allocator);
            if (j.undo_trash_orig) |o| self.allocator.free(o);
            if (j.history_op) |op| op.destroy(self.allocator);
            if (j.retry) |r| r.destroy(self.allocator);
            self.allocator.free(j.label);
            self.allocator.destroy(j);
        }
        self.jobs.deinit(self.allocator);
        self.shutdownPreviewTransfers();
        for (self.conns.items) |hc| {
            if (hc.state == .connecting) {
                // A worker thread still owns the connect; the idle
                // handback frees the struct.
                hc.orphaned = true;
            } else {
                hc.destroy(self.allocator);
            }
        }
        self.conns.deinit(self.allocator);
        // The clipboard is process-wide: closing one pane must not
        // empty it for the others.
        self.closePathCompletion();
        if (self.completion_source != 0) _ = c.g_source_remove(self.completion_source);
        if (self.completion_request) |request| request.destroy(self.allocator);
        self.locbar.deinit(self.allocator);
        self.closed_tabs.deinit(self.allocator);
        self.views.deinit(self.allocator);
        self.sel.deinit(self.allocator);
        self.emblems.deinit();
        self.media.deinit(self.allocator);
        self.endProbesFor(null, "");
        self.probes.deinit(self.allocator);
        self.endAttrRequest();
        self.endSnapRequest();
        self.preview_state.deinit(self.allocator);
        self.preview_image.deinit(self.allocator);
        if (self.restore_read) |rr| rr.destroy(self.allocator);
        if (self.dup) |d| d.destroy(self.allocator);
        if (self.editor_rename) |er| er.destroy(self.allocator);
        if (self.thumb_render_src != 0) _ = c.g_source_remove(self.thumb_render_src);
        if (self.listing_render_src != 0) _ = c.g_source_remove(self.listing_render_src);
        if (self.git_delta_src != 0) _ = c.g_source_remove(self.git_delta_src);
        if (self.git_poll_src != 0) _ = c.g_source_remove(self.git_poll_src);
        if (self.thumb_ctx) |tc| {
            tc.lock();
            tc.orphaned = true;
            tc.shutdown = true;
            _ = c.pthread_cond_signal(&tc.cond);
            tc.unlock();
            tc.unref(); // the view's ref; thread + idles drop theirs
        }
        self.remote_thumbs.deinit(self.allocator);
        self.remote_thumb_queue.deinit(self.allocator);
        for (self.undo_stack.items) |u| u.destroy(self.allocator);
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |u| u.destroy(self.allocator);
        self.redo_stack.deinit(self.allocator);
        for (self.pending_undo.items) |pu| pu.op.destroy(self.allocator);
        self.pending_undo.deinit(self.allocator);
        for (self.pending_history.items) |ph| ph.op.destroy(self.allocator);
        self.pending_history.deinit(self.allocator);
        for (self.bookmarks.items) |b| self.allocator.free(b);
        self.bookmarks.deinit(self.allocator);
        for (self.bookmark_labels.items) |b| self.allocator.free(b);
        self.bookmark_labels.deinit(self.allocator);
        for (self.bookmark_icons.items) |b| self.allocator.free(b);
        self.bookmark_icons.deinit(self.allocator);
        for (self.recent.items) |r| self.allocator.free(r);
        self.recent.deinit(self.allocator);
        for (self.frecency.items) |fe| self.allocator.free(fe.spec);
        self.frecency.deinit(self.allocator);
        self.diff.deinit(self.allocator);
        for (self.collapsed.items) |s| self.allocator.free(s);
        self.collapsed.deinit(self.allocator);
        for (self.hidden_sections.items) |s| self.allocator.free(s);
        self.hidden_sections.deinit(self.allocator);
        for (self.section_order.items) |s| self.allocator.free(s);
        self.section_order.deinit(self.allocator);
        @import("sidewidgets.zig").resetRuns(self);
        self.widget_runs.deinit(self.allocator);
        self.widgets.deinit(self.allocator);
        for (self.saved_searches.items) |sq| sq.deinitOwned(self.allocator);
        self.saved_searches.deinit(self.allocator);
        if (self.last_search) |ls| ls.deinitOwned(self.allocator);
        for (self.file_colors.items) |fc| self.allocator.free(fc.glob);
        self.file_colors.deinit(self.allocator);
        self.git.deinit();
        self.git_cache.deinit();
        self.git_repo.deinit();
        if (self.git_root.len > 0) self.allocator.free(self.git_root);
        if (self.git_host.len > 0) self.allocator.free(self.git_host);
        self.clearThumbCache();
        self.thumbs.deinit();
        var fit = self.thumb_failed.iterator();
        while (fit.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.thumb_failed.deinit();
        self.allocator.destroy(self);
    }

    /// One toolbar button, with THIS view as its user data. The shape
    /// (flat, labelled when the icon name does not resolve) is the
    /// shared one every face toolbar uses.
    fn barButton(self: *BrowserView, bar: *c.GtkWidget, icon: [*:0]const u8, text: [*:0]const u8, tip: [*:0]const u8, cb: anytype) *c.GtkWidget {
        return toolbtn.barButton(bar, icon, text, tip, cb, @ptrCast(self));
    }

    /// The hamburger button: builds its classic menu fresh per open,
    /// so every check row and submenu reflects the current state.
    fn onBurgerClicked(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        @import("menu.zig").showHamburgerMenu(self, @ptrCast(@alignCast(btn)));
    }

    /// `barButton` for a toggle. Same icon guarantee.
    fn barToggle(self: *BrowserView, bar: *c.GtkWidget, icon: [*:0]const u8, text: [*:0]const u8, tip: [*:0]const u8, cb: anytype) *c.GtkWidget {
        return toolbtn.barToggle(bar, icon, text, tip, cb, @ptrCast(self));
    }

    /// The browser's own stylesheet, on top of the shared toolbar one
    /// (`toolbtn.installCss`): the breadcrumb holder has to read as a
    /// single control, which no stock GTK class does for a plain box
    /// of flat buttons. Installed once per display, at APPLICATION
    /// priority, so a user theme still wins. It also states the
    /// hover/active feedback outright: Breeze draws NOTHING for a
    /// `.flat` button, so without this the breadcrumb reads as dead
    /// pixels under the pointer.
    var css_installed: bool = false;

    fn installCss(any_widget: *c.GtkWidget) void {
        toolbtn.installCss(any_widget);
        if (css_installed) return;
        css_installed = true;
        const css =
            \\.sketerm-fb-path {
            \\  border: 1px solid rgba(128,128,128,0.35);
            \\  border-radius: 7px;
            \\}
            \\.sketerm-fb-path button {
            \\  border-radius: 6px;
            \\  margin: 0;
            \\  min-height: 24px;
            \\}
            \\.sketerm-fb-section arrow, .sketerm-fb-section image { opacity: 0.6; }
            \\.sketerm-fb-path button:hover {
            \\  background: alpha(currentColor, 0.10);
            \\}
            \\.sketerm-fb-path button:active {
            \\  background: alpha(currentColor, 0.20);
            \\}
            \\.sketerm-fb-gitchip {
            \\  font-size: 0.72em;
            \\  font-weight: bold;
            \\  padding: 0 3px;
            \\  border-radius: 4px;
            \\  background: alpha(@theme_bg_color, 0.85);
            \\}
        ;
        const provider = c.gtk_css_provider_new();
        c.gtk_css_provider_load_from_string(provider, css);
        const display = c.gtk_widget_get_display(any_widget);
        c.gtk_style_context_add_provider_for_display(display, @ptrCast(@alignCast(provider)), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    }

    /// Re-list what the tab is showing, without touching history or
    /// the view: the same one-shot `list` the resync path uses, for
    /// the root and for every miller/column directory beside it.
    fn onRefreshClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        const tab = self.currentTab() orelse return;
        self.clearFailureCaches();
        self.refreshDir(tab, tab.root);
        for (tab.subdirs.items) |d| self.refreshDir(tab, d);
        // An explicit reload always re-asks git: the recency cache is
        // exactly what the user is overriding by pressing this.
        self.refreshGitForced(tab);
    }

    /// Split into a second browser pane. The pane binding table owns
    /// what a split IS (it can differ per profile), so this forwards
    /// the action rather than reimplementing it.
    pub fn onSplitClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        const pane = self.pane orelse return;
        const ictx = pane.input_ctx orelse return;
        // splitFocused acts on the WINDOW's focused pane; a toolbar
        // click does not focus anything (the buttons are out of the
        // focus chain), so focus is pointed here first or the action
        // silently hits whichever pane last had it.
        self.focusOwnPane();
        _ = input.runAction(ictx, .new_browser_split);
    }

    /// Point the window's focus at THIS pane, so pane-scoped window
    /// actions (split, close) act on the pane whose control was
    /// clicked rather than wherever focus happened to sit.
    pub fn focusOwnPane(self: *BrowserView) void {
        if (self.currentTab()) |tab| {
            if (c.gtk_widget_grab_focus(@ptrCast(@alignCast(tab.colview))) != 0) return;
        }
        _ = c.gtk_widget_grab_focus(self.root_box);
    }

    fn buildUi(self: *BrowserView) void {
        const vbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(vbox, 1);
        c.gtk_widget_set_vexpand(vbox, 1);

        installCss(vbox.?);

        // Nemo's shape: a flat icon-only nav cluster on the left, the
        // path control filling the middle, a flat icon-only tool
        // cluster on the right.
        const bar = toolbtn.newBar();

        const left = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 2);
        const navpair = toolbtn.newNavPair();
        const back = self.barButton(navpair, "go-previous-symbolic", "Back", "Back (Alt+Left)", &onBackClicked);
        c.gtk_widget_set_sensitive(back, 0);
        const fwd = self.barButton(navpair, "go-next-symbolic", "Forward", "Forward (Alt+Right)", &onFwdClicked);
        c.gtk_widget_set_sensitive(fwd, 0);
        // The per-side history list is a right-click on the button it
        // belongs to; the two extra arrow buttons are gone.
        self.installHistoryMenuGesture(back, .back);
        self.installHistoryMenuGesture(fwd, .forward);
        c.gtk_box_append(@ptrCast(left), navpair);
        _ = self.barButton(left, "go-up-symbolic", "Up", "Up one folder (Alt+Up)", &onUpClicked);
        _ = self.barButton(left, "view-refresh-symbolic", "Refresh", "Re-list this folder", &onRefreshClicked);
        c.gtk_box_append(@ptrCast(bar), left);

        const entry = c.gtk_entry_new();
        c.gtk_widget_set_hexpand(entry, 1);
        c.gtk_entry_set_placeholder_text(@ptrCast(entry), "/path — or host:/path, user@host:/path, udp:host:/path, local:/path");
        _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onPathActivate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(entry, "changed", @ptrCast(&onPathChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        const entry_keys = c.gtk_event_controller_key_new();
        c.gtk_event_controller_set_propagation_phase(@ptrCast(entry_keys), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(entry_keys, "key-pressed", @ptrCast(&onPathKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(entry, @ptrCast(entry_keys));
        // Breadcrumb + entry are the two faces of one control; the
        // breadcrumb shows by default, Ctrl+L swaps to the entry.
        self.installLocationFace(bar, entry);

        // The right end of the toolbar, in two halves: `cluster`
        // collapses into the hamburger when the bar runs out of room,
        // `keep` never does (search and the way back to the shell stay
        // one click away at any width).
        //
        // Dolphin's uncluttered-toolbar rule applies: only the
        // constantly-used toggles stay as buttons; everything else
        // lives in the always-visible hamburger menu.
        const right = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 2);
        const cluster = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 2);
        const places_btn = self.barToggle(cluster, "user-bookmarks-symbolic", "Places", "Places sidebar (bookmarks, recent, devices)", &onPlacesToggled);
        const info_btn = self.barToggle(cluster, "sketerm-preview-pane-symbolic", "Information", "Information panel (preview, metadata)", &onPreviewToggled);
        self.info_toggle = @ptrCast(@alignCast(info_btn));
        c.gtk_box_append(@ptrCast(right), cluster);

        const keep = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 2);
        _ = self.barToggle(keep, "system-search-symbolic", "Search", "Search this directory (daemon-side, recursive)", &onSearchToggled);
        // Its own bundled icon: Adwaita ships utilities-terminal-symbolic
        // only under symbolic/legacy/, so on a Breeze theme chain this
        // button -- the one that leaves the browser -- rendered blank.
        // A paneless picker has no shell to show, so no button.
        if (self.picker == null) _ = self.barButton(
            keep,
            "sketerm-terminal-symbolic",
            "Shell",
            "Show this pane's shell. Ctrl+Shift+B (or the strip above the shell) brings the browser back.",
            &onTerminalClicked,
        );
        c.gtk_box_append(@ptrCast(right), keep);
        c.gtk_box_append(@ptrCast(bar), right);

        // The state anchor for "show hidden files": not in any menu
        // (the classic menus rebuild per open and read/flip THIS), but
        // still a real toggle so nav.zig/view.zig sync keeps working.
        const hidden = c.gtk_toggle_button_new();
        _ = c.g_object_ref_sink(@ptrCast(hidden));
        _ = c.g_signal_connect_data(hidden, "toggled", @ptrCast(&onHiddenToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        // The hamburger: always visible; its menu is a classic menu
        // built fresh per open (Dolphin's shape -- Create New on top,
        // check rows for the toggles, a View Mode submenu).
        const burger = self.barButton(right, "open-menu-symbolic", "Menu", "Menu", &onBurgerClicked);
        _ = burger;

        c.gtk_box_append(@ptrCast(vbox), bar);

        const sbar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_widget_set_margin_start(sbar, 4);
        c.gtk_widget_set_margin_end(sbar, 4);
        c.gtk_widget_set_margin_bottom(sbar, 4);
        const sentry = c.gtk_entry_new();
        c.gtk_widget_set_hexpand(sentry, 1);
        c.gtk_entry_set_placeholder_text(@ptrCast(sentry), "name/glob (live), @7d for a time window, or !command to panelize host output");
        _ = c.g_signal_connect_data(sentry, "activate", @ptrCast(&onSearchActivate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(sbar), sentry);
        const scontent = c.gtk_check_button_new_with_label("in contents");
        c.gtk_box_append(@ptrCast(sbar), scontent);
        _ = self.barButton(sbar, "sketerm-terminal-symbolic", "Presets", "Panelize presets: browse a command's output as a listing", &onPresetClicked);
        _ = self.barButton(sbar, "folder-saved-search-symbolic", "Keep", "Keep these results: mark every row into a named register", &onPromoteClicked);
        _ = self.barButton(sbar, "starred-symbolic", "Save", "Save this query (shows in the Places sidebar, reopens live)", &onSaveSearchClicked);
        c.gtk_widget_set_visible(sbar, 0);
        c.gtk_box_append(@ptrCast(vbox), sbar);

        self.tabhost = tabhost_mod.TabHost.init(self.allocator);
        self.tabhost.ctx = @ptrCast(self);
        self.tabhost.on_close = &hostCloseCb;
        self.tabhost.on_new = &hostNewCb;
        self.tabhost.on_strip_menu = &hostStripMenuCb;
        self.tabhost.tab_menu = tabsmod.tabMenuSpec();
        const notebook = self.tabhost.widget();
        _ = c.g_signal_connect_data(notebook, "switch-page", @ptrCast(&onSwitchPage), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        // Content row: places | (notebook | preview). The sidebar is a
        // real splitter so its width is the user's to set; the handle
        // disappears with the sidebar, because GtkPaned draws none for
        // an invisible child.
        const content = c.gtk_paned_new(c.GTK_ORIENTATION_HORIZONTAL);
        c.gtk_widget_set_hexpand(content, 1);
        c.gtk_widget_set_vexpand(content, 1);

        const pl_scroll = c.gtk_scrolled_window_new();
        c.gtk_widget_set_size_request(pl_scroll, places_mod.MIN_SIDEBAR_PX, -1);
        const pl_list = c.gtk_list_box_new();
        c.gtk_list_box_set_selection_mode(@ptrCast(pl_list), c.GTK_SELECTION_NONE);
        c.gtk_list_box_set_activate_on_single_click(@ptrCast(pl_list), 1);
        _ = c.g_signal_connect_data(pl_list, "row-activated", @ptrCast(&onPlaceActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        // Right-click a sidebar row for its context menu.
        const pl_rclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(pl_rclick), 3);
        _ = c.g_signal_connect_data(pl_rclick, "pressed", @ptrCast(&onPlacesRightClick), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(pl_list, @ptrCast(pl_rclick));
        c.gtk_scrolled_window_set_child(@ptrCast(pl_scroll), pl_list);
        // The sidebar column: the places list above, an optional
        // compact info card pinned at the bottom (iTunes-style
        // "now playing" slot for the current selection).
        const pl_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_vexpand(pl_scroll, 1);
        c.gtk_box_append(@ptrCast(pl_box), pl_scroll);
        c.gtk_box_append(@ptrCast(pl_box), @import("preview.zig").buildSideCard(self));
        c.gtk_widget_set_visible(pl_box, 0);
        c.gtk_paned_set_start_child(@ptrCast(content), pl_box);
        // The sidebar keeps its width when the window resizes; the
        // listing side absorbs the difference.
        c.gtk_paned_set_resize_start_child(@ptrCast(content), 0);
        c.gtk_paned_set_shrink_start_child(@ptrCast(content), 0);
        c.gtk_paned_set_position(@ptrCast(content), self.sidebar_px);
        _ = c.g_signal_connect_data(content, "notify::position", @ptrCast(&onSidebarPosition), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        // Listing | Information panel. A paned, so the panel's width
        // belongs to the user (drag the divider) and can never be
        // pushed around by whatever content the panel shows.
        const main_side = c.gtk_paned_new(c.GTK_ORIENTATION_HORIZONTAL);
        c.gtk_widget_set_hexpand(main_side, 1);
        c.gtk_widget_set_vexpand(main_side, 1);
        c.gtk_paned_set_end_child(@ptrCast(content), main_side);
        c.gtk_paned_set_resize_end_child(@ptrCast(content), 1);

        c.gtk_paned_set_start_child(@ptrCast(main_side), notebook);
        c.gtk_paned_set_resize_start_child(@ptrCast(main_side), 1);
        c.gtk_paned_set_shrink_start_child(@ptrCast(main_side), 1);

        const pbox = @import("preview.zig").buildInfoPanel(self);
        c.gtk_paned_set_end_child(@ptrCast(main_side), pbox);
        c.gtk_paned_set_resize_end_child(@ptrCast(main_side), 0);
        c.gtk_paned_set_shrink_end_child(@ptrCast(main_side), 0);
        c.gtk_widget_set_visible(pbox, 0);
        self.info_paned = main_side.?;
        _ = c.g_signal_connect_data(main_side, "notify::position", @ptrCast(&onInfoPanedPosition), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        c.gtk_box_append(@ptrCast(vbox), content);

        const jobs_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
        c.gtk_widget_set_visible(jobs_box, 0);
        c.gtk_box_append(@ptrCast(vbox), jobs_box);

        const status = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(status), 0);
        c.gtk_widget_add_css_class(status, "dim-label");
        c.gtk_widget_set_margin_start(status, 6);
        c.gtk_widget_set_margin_bottom(status, 2);
        c.gtk_box_append(@ptrCast(vbox), status);

        // Pane-level keybinds (palette, save-layout, splits, …) must
        // keep working while browser widgets hold focus: bindings
        // normally live on the hidden GL area's controllers, so a
        // bubble-phase forwarder on the browser root re-runs the same
        // match+dispatch. Plain typing is untouched (entries consume
        // their keys before this fires; chords don't match entries).
        const keys = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onBrowserKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(vbox, @ptrCast(keys));

        // Clicking anywhere in this face makes it the pane the chords
        // act on. Lots of it cannot take focus (the places sidebar's
        // empty space, the toolbar, the status line, a column header),
        // so "click the other pane, press Ctrl+L" used to reach the
        // pane the user had just left.
        const claim = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(claim), 0);
        c.gtk_event_controller_set_propagation_phase(@ptrCast(claim), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(claim, "pressed", @ptrCast(&onFaceClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(vbox, @ptrCast(claim));

        // The fence for every deferred callback below: see
        // `widgets_dead`.
        _ = c.g_signal_connect_data(vbox, "destroy", @ptrCast(&onRootDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        self.root_box = vbox;
        self.notebook = self.tabhost.notebook;
        self.path_entry = @ptrCast(@alignCast(entry));
        self.back_button = back;
        self.fwd_button = fwd;
        self.status_label = @ptrCast(@alignCast(status));
        self.jobs_box = jobs_box;
        self.search_bar = sbar;
        self.search_entry = @ptrCast(@alignCast(sentry));
        self.search_content = scontent;
        self.hidden_toggle = @ptrCast(@alignCast(hidden));
        self.places_scroller = pl_scroll;
        self.places_box = pl_box.?;
        self.places_list = @ptrCast(@alignCast(pl_list));
        self.places_toggle = @ptrCast(@alignCast(places_btn));
        self.content_paned = content.?;
        self.right_box = right.?;
        self.right_cluster = cluster.?;
        self.tabhost.installStripGestures();
    }

    /// TabHost close request (close button / middle click on a tab
    /// label): route to the browser's own closeTab.
    fn hostCloseCb(ctx: ?*anyopaque, page: *c.GtkWidget) void {
        const self: *BrowserView = @ptrCast(@alignCast(ctx.?));
        for (self.tabs.items) |t| {
            if (t.page == page) {
                self.closeTab(t);
                return;
            }
        }
    }

    /// TabHost strip double-click: same behavior as the new-tab
    /// button — the new tab opens on the current tab's directory.
    fn hostNewCb(ctx: ?*anyopaque) void {
        BrowserView.onNewTabClicked(undefined, ctx);
    }

    fn hostStripMenuCb(ctx: ?*anyopaque, x: f64, y: f64) void {
        const self: *BrowserView = @ptrCast(@alignCast(ctx.?));
        tabsmod.showStripMenu(self, x, y);
    }

    /// The browser's widgets are gone: nothing deferred may touch them
    /// again. The view itself lives on until the pane's deferred
    /// deinit, so this cannot free anything -- it only fences.
    fn onRootDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        self.widgets_dead = true;
        self.root_destroyed = true;
        self.severPreviewAnimation();
        if (self.bar_idle_src != 0) {
            _ = c.g_source_remove(self.bar_idle_src);
            self.bar_idle_src = 0;
        }
    }

    // -- responsive toolbar ------------------------------------------

    /// Breadcrumb viewport width below which the toolbar has no room
    /// left for the tool cluster.
    const BAR_COLLAPSE_PX: f64 = 200;

    /// Fallback for the width a collapse gives back, used only when
    /// the cluster has no allocation to measure yet.
    const BAR_RECLAIM_FALLBACK: c_int = 220;

    /// notify::page-size on the breadcrumb adjustment.
    pub fn onCrumbViewport(_: *c.GObject, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        self.evaluateBarOverflow();
    }

    /// ::changed on the same adjustment -- the crumb rebuild. A pane
    /// born too narrow to show ANY path never moves page-size off
    /// zero, so the notify alone would never fire for it.
    pub fn onCrumbConfigured(_: *c.GtkAdjustment, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        self.evaluateBarOverflow();
    }

    /// Ask for the overflow state to be re-decided. The signals that
    /// call this are emitted from INSIDE the layout pass (the crumb
    /// adjustment is configured there), and moving widgets during a
    /// size-allocate leaves the boxes measuring stale requests -- the
    /// cluster came back into a bar that laid it out at its popover
    /// width and clipped it. So the decision is taken, and applied, on
    /// an idle once the frame has settled. Same reason pinCrumbTail
    /// defers (locbar.zig).
    pub fn evaluateBarOverflow(self: *BrowserView) void {
        if (self.widgets_dead or self.bar_idle_src != 0) return;
        self.bar_idle_src = c.g_idle_add(@ptrCast(&barOverflowIdle), @ptrCast(self));
    }

    pub fn barOverflowIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        self.bar_idle_src = 0;
        if (self.widgets_dead) return 0;
        if (self.wantBarCollapsed()) |want| self.setBarCollapsed(want);
        return 0;
    }

    /// Should the tool cluster be in the hamburger right now? The
    /// breadcrumb scroller's page size IS the width the toolbar has
    /// left over for the path, so that is the measure.
    /// @return null when the toolbar has never been laid out.
    fn wantBarCollapsed(self: *BrowserView) ?bool {
        const sw = self.locbar.scroller orelse return null;
        // Zero page size is a REAL answer here (the path was squeezed
        // out of the bar entirely); what has to be ignored is the
        // state before the toolbar has ever been allocated.
        if (c.gtk_widget_get_width(self.right_box) <= 0) return null;
        const page = c.gtk_adjustment_get_page_size(c.gtk_scrolled_window_get_hadjustment(@ptrCast(sw)));
        if (!self.bar_collapsed) return page < BAR_COLLAPSE_PX;
        // Expanding hands the cluster's width straight back to this
        // viewport, so the threshold has to sit above what a
        // re-collapse needs or the two states flip-flop forever.
        const back: f64 = @floatFromInt(self.bar_reclaim);
        return page <= BAR_COLLAPSE_PX + back + 24;
    }

    /// Collapse = hide the tool cluster; the hamburger menu carries
    /// the same toggles as check rows, so nothing becomes unreachable
    /// and no widget is reparented mid-layout.
    fn setBarCollapsed(self: *BrowserView, on: bool) void {
        if (self.bar_collapsed == on) return;
        const cluster = self.right_cluster;
        if (on) {
            const w = c.gtk_widget_get_width(cluster);
            self.bar_reclaim = if (w > 0) w else BAR_RECLAIM_FALLBACK;
        }
        c.gtk_widget_set_visible(cluster, @intFromBool(!on));
        self.bar_collapsed = on;
    }

    /// Close this pane (un-split) once the click that asked for it has
    /// unwound: running it inline would destroy the widget tree the
    /// button's own handler is still standing on.
    ///
    /// A plain idle is too early. The popover the button lives in is
    /// only POPPED DOWN at that point -- it dismisses over an
    /// animation, and tearing its parent widget tree out from under a
    /// popover still in that state crashes the process later, during
    /// application teardown. One dismiss animation is the wait.
    pub fn closePaneDeferred(self: *BrowserView) void {
        if (self.close_pane_src != 0) return;
        self.close_pane_src = c.g_timeout_add(250, @ptrCast(&closePaneIdle), @ptrCast(self));
    }

    fn closePaneIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        self.close_pane_src = 0;
        if (self.widgets_dead) return 0;
        const pane = self.pane orelse return 0;
        const ictx = pane.input_ctx orelse return 0;
        // closeFocusedPane closes the WINDOW's focused pane; see
        // onSplitClicked for why focus must be pointed here first.
        self.focusOwnPane();
        _ = input.runAction(ictx, .close_pane);
        return 0;
    }

    // -- sidebar width persistence -----------------------------------

    /// A drag emits this per pixel; the write is debounced so a resize
    /// costs one places.json save, not hundreds.
    fn onInfoPanedPosition(obj: *c.GObject, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        // Position is the LISTING side; the panel width is the rest.
        if (self.widgets_dead or !self.preview_on or !self.chrome_ready) return;
        const total = c.gtk_widget_get_width(@ptrCast(@alignCast(obj)));
        if (total <= 0) return;
        const px = total - c.gtk_paned_get_position(@ptrCast(@alignCast(obj)));
        if (px < 220) return;
        self.preview_px = @min(px, 700);
        if (self.sidebar_save_src != 0) _ = c.g_source_remove(self.sidebar_save_src);
        self.sidebar_save_src = c.g_timeout_add(400, @ptrCast(&onSidebarSaveTick), @ptrCast(self));
    }

    fn onSidebarPosition(obj: *c.GObject, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        // A hidden sidebar reports whatever GtkPaned last computed;
        // only a visible one describes a width the user chose.
        if (self.widgets_dead or !self.places_on or !self.chrome_ready) return;
        const pos = c.gtk_paned_get_position(@ptrCast(@alignCast(obj)));
        if (pos < places_mod.MIN_SIDEBAR_PX) return;
        self.sidebar_px = places_mod.clampSidebarPx(pos);
        if (self.sidebar_save_src != 0) _ = c.g_source_remove(self.sidebar_save_src);
        self.sidebar_save_src = c.g_timeout_add(400, @ptrCast(&onSidebarSaveTick), @ptrCast(self));
    }

    fn onSidebarSaveTick(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        self.sidebar_save_src = 0;
        self.savePlaces();
        return 0;
    }

    /// Apply the persisted chrome state once the widgets exist: the
    /// sidebar's last width and, when the user has never toggled it,
    /// the identity default (open in the dedicated file manager).
    fn applyChromeState(self: *BrowserView) void {
        c.gtk_paned_set_position(@ptrCast(self.content_paned), self.sidebar_px);
        // Imported here rather than at file scope: the browser modules
        // are below the window in the dependency order.
        const want = self.sidebar_open orelse @import("../window.zig").Window.filesIdentity();
        if (want) c.gtk_toggle_button_set_active(self.places_toggle, 1);
        if (self.side_info) {
            c.gtk_widget_set_visible(self.side_card, 1);
            @import("preview.zig").updateSideCard(self);
        }
        self.chrome_ready = true;
        // One post-layout evaluation, for a pane that is born too
        // narrow: the adjustment signals only describe CHANGES.
        self.evaluateBarOverflow();
    }
};
