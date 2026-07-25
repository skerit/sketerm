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
const places_mod = @import("../../filebrowser/places.zig");
const emblems_mod = @import("../../filebrowser/emblems.zig");
const Pane = @import("../pane.zig").Pane;
const file_transfers = @import("../file_transfers.zig");

const ActiveTransfer = @import("types.zig").ActiveTransfer;
const AttrRequest = @import("props.zig").AttrRequest;
const BTab = @import("types.zig").BTab;
const CompareCtx = @import("compare.zig").CompareCtx;
const CopyQueue = @import("jobs.zig").CopyQueue;
const DupState = @import("search.zig").DupState;
const EditWatch = @import("types.zig").EditWatch;
const EditorRename = @import("ops.zig").EditorRename;
const FileColor = @import("types.zig").FileColor;
const GitCtx = @import("gitstat.zig").GitCtx;
const HostAction = @import("types.zig").HostAction;
const HostConn = @import("types.zig").HostConn;
const JobPanel = @import("jobpanel.zig").Panel;
const JobRow = @import("types.zig").JobRow;
const LabelProbe = @import("props.zig").LabelProbe;
const MAX_ATTR_COLUMNS = @import("render.zig").MAX_ATTR_COLUMNS;
const OpenWithCtx = @import("open.zig").OpenWithCtx;
const OwnedColl = @import("types.zig").OwnedColl;
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
const ThumbCtx = @import("preview.zig").ThumbCtx;
const UndoOp = @import("types.zig").UndoOp;
const locbar = @import("locbar.zig");
const parseSpec = @import("../../filebrowser/paths.zig").parseSpec;
const tabsmod = @import("tabs.zig");
const viewsmod = @import("views.zig");

pub const BrowserView = struct {
    allocator: std.mem.Allocator,
    pane: *Pane,
    conns: std.ArrayList(*HostConn) = .empty,
    next_req: u32 = 1,
    next_remote_thumb_id: u64 = 1,
    next_view: u32 = 1,
    tabs: std.ArrayList(*BTab) = .empty,
    pending: std.ArrayList(*Pending) = .empty,
    pending_jobs: std.ArrayList(*PendingJob) = .empty,
    jobs: std.ArrayList(*JobRow) = .empty,
    transfers: std.ArrayList(*ActiveTransfer) = .empty,
    /// Cross-host copies waiting for their destination (jobs.zig).
    copy_queue: CopyQueue = .{},

    root_box: *c.GtkWidget = undefined,
    notebook: *c.GtkNotebook = undefined,
    /// Editable face of the location control; the breadcrumb face
    /// and the history dropdowns live in `locbar`.
    path_entry: *c.GtkEntry = undefined,
    locbar: locbar.State = .{},
    /// Closed-tab ring (undo-close-tab), session state.
    closed_tabs: tabsmod.State = .{},
    /// Grouping / zoom / filter / flat view / per-folder view memory.
    views: viewsmod.State = .{},
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
    /// Copy-source for the context menu's Copy/Paste (owned).
    /// clip_paths holds the full multi-selection; clip_path mirrors
    /// its first item (single-source verbs: Sync Here, Compare).
    clip_host: ?[]u8 = null,
    clip_path: ?[]u8 = null,
    clip_paths: std.ArrayList([]u8) = .empty,
    /// Cut mode: paste MOVES (rename same-host, transfer+delete
    /// cross-host) and then clears the clipboard.
    clip_cut: bool = false,
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
    /// Preview side panel (toggleable): metadata always, image or
    /// text-head content when recognizably previewable.
    preview_box: *c.GtkWidget = undefined,
    preview_pic: *c.GtkWidget = undefined,
    preview_text: *c.GtkLabel = undefined,
    preview_meta: *c.GtkLabel = undefined,
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
    /// Serial remote-thumbnail pipeline.
    remote_thumb: ?*RemoteThumb = null,
    remote_thumb_queue: std.ArrayList(*RemoteThumb) = .empty,
    /// Coalesced re-render after thumbnails land.
    thumb_render_src: c.guint = 0,
    /// Live local-edit sync-back watches (remote files opened here).
    watches: std.ArrayList(*EditWatch) = .empty,
    /// The one open Open With chooser (its popover owns the ctx).
    openwith: ?*OpenWithCtx = null,
    /// The one open compare/sync window.
    compare: ?*CompareCtx = null,
    /// Places sidebar (bookmarks / recent / devices).
    places_scroller: *c.GtkWidget = undefined,
    places_list: *c.GtkListBox = undefined,
    places_on: bool = false,
    bookmarks: std.ArrayList([]u8) = .empty,
    recent: std.ArrayList([]u8) = .empty,
    /// Saved searches (persisted with places).
    saved_searches: std.ArrayList(OwnedSearch) = .empty,
    /// Persistent collection shelf (specs + kind).
    collection_items: std.ArrayList(OwnedColl) = .empty,
    /// The most recent search run (owned), for the save button.
    last_search: ?OwnedSearch = null,
    /// Relative-time filter for the NEXT find job ("@7d pattern").
    search_within_ms: u64 = 0,
    /// Match-cap override for the NEXT find job (compare scans).
    search_max_matches: u64 = 0,
    /// User file-coloring rules (~/.config/sketerm/filecolors.conf).
    file_colors: std.ArrayList(FileColor) = .empty,
    /// Git status overlay for the current LOCAL root: child name ->
    /// porcelain status char. Rebuilt by a worker thread per navigate.
    git_map: std.StringHashMap(u8) = undefined,
    git_root: []u8 = &.{},
    git_gen: u64 = 0,
    git_inflight: ?*GitCtx = null,
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
    /// Running search job (0 = none) and its host + results tab.
    search_job: u64 = 0,
    search_hc: ?*HostConn = null,
    search_tab: ?*BTab = null,
    collection_tab: ?*BTab = null,
    /// Window-level abilities, installed by the owning Window.
    hooks_ctx: ?*anyopaque = null,
    on_host_term: ?HostAction = null,
    on_host_open: ?HostAction = null,
    /// Run a shell command as an app session on a host (declarative
    /// .action files with RunsOnHost).
    on_host_exec: ?HostAction = null,
    /// In-flight attr_list for an open Properties dialog.
    attr_request: ?AttrRequest = null,
    /// The open column picker, so editing a column can close it.
    column_picker: ?*c.GtkWidget = null,
    /// Emblem rules (name globs / attribute predicates -> badge icon).
    emblems: emblems_mod.Rules = undefined,
    /// Label probes in flight (folder size, checksum, media info).
    probes: std.ArrayList(LabelProbe) = .empty,
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
    pub const closeViewOf = @import("conn.zig").closeViewOf;
    pub const attrSpec = @import("conn.zig").attrSpec;
    pub const sendListingOp = @import("conn.zig").sendListingOp;
    pub const openDir = @import("conn.zig").openDir;
    pub const refreshDir = @import("conn.zig").refreshDir;
    pub const queueListing = @import("conn.zig").queueListing;
    pub const nextReq = @import("conn.zig").nextReq;
    pub const onFdReadable = @import("conn.zig").onFdReadable;
    pub const onReply = @import("conn.zig").onReply;
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
    pub const appendHistoryArrow = @import("locbar.zig").appendHistoryArrow;
    pub const rebuildCrumbs = @import("locbar.zig").rebuildCrumbs;
    pub const cancelSiblings = @import("locbar.zig").cancelSiblings;
    pub const feedSiblings = @import("locbar.zig").feedSiblings;
    pub const showSiblingPopover = @import("locbar.zig").showSiblingPopover;
    pub const toggleLocationFace = @import("locbar.zig").toggleLocationFace;
    pub const showEntryFace = @import("locbar.zig").showEntryFace;
    pub const showCrumbFace = @import("locbar.zig").showCrumbFace;
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
    pub const showTabMenu = @import("tabs.zig").showTabMenu;

    // render.zig -- listing rendering, columns, rows, emblems
    pub const renderCurrent = @import("render.zig").renderCurrent;
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
    pub const onViewModeClicked = @import("render.zig").onViewModeClicked;

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
    pub const flatForget = @import("views.zig").flatForget;
    pub const flatConsumeEvent = @import("views.zig").flatConsumeEvent;
    pub const applyFolderMemory = @import("views.zig").applyFolderMemory;
    pub const rememberFolder = @import("views.zig").rememberFolder;
    pub const forgetFolder = @import("views.zig").forgetFolder;
    pub const forgetAllFolders = @import("views.zig").forgetAllFolders;

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
    pub const onMenuFindDups = @import("menu.zig").onMenuFindDups;
    pub const onMenuNewFolder = @import("menu.zig").onMenuNewFolder;
    pub const onMenuRename = @import("menu.zig").onMenuRename;
    pub const onMenuBrowseArchive = @import("menu.zig").onMenuBrowseArchive;
    pub const onMenuExtractMember = @import("menu.zig").onMenuExtractMember;
    pub const onMenuExtractHere = @import("menu.zig").onMenuExtractHere;
    pub const onMenuArchiveCreate = @import("menu.zig").onMenuArchiveCreate;
    pub const appendActionButtons = @import("menu.zig").appendActionButtons;
    pub const onActionClicked = @import("menu.zig").onActionClicked;

    // ops.zig -- clipboard, rename, delete/trash, undo, archives, tags
    pub const copyToClip = @import("ops.zig").copyToClip;
    pub const beginPaste = @import("ops.zig").beginPaste;
    pub const pasteChoiceButton = @import("ops.zig").pasteChoiceButton;
    pub const onPasteOverwrite = @import("ops.zig").onPasteOverwrite;
    pub const onPasteKeepBoth = @import("ops.zig").onPasteKeepBoth;
    pub const onPasteSkip = @import("ops.zig").onPasteSkip;
    pub const uniqueDstName = @import("ops.zig").uniqueDstName;
    pub const pasteExecute = @import("ops.zig").pasteExecute;
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
    pub const onEntryDialogActivate = @import("ops.zig").onEntryDialogActivate;
    pub const startTrashRestore = @import("ops.zig").startTrashRestore;
    pub const feedRestore = @import("ops.zig").feedRestore;
    pub const clearRedo = @import("ops.zig").clearRedo;
    pub const pushUndo = @import("ops.zig").pushUndo;
    pub const pushHistoryStack = @import("ops.zig").pushHistoryStack;
    pub const makeUndo = @import("ops.zig").makeUndo;
    pub const deferUndo = @import("ops.zig").deferUndo;
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
    pub const pumpTransferQueue = @import("jobs.zig").pumpTransferQueue;
    pub const moveTransfer = @import("jobs.zig").moveTransfer;
    pub const pumpCopyQueue = @import("jobs.zig").pumpCopyQueue;
    pub const cancelQueuedCopy = @import("jobs.zig").cancelQueuedCopy;
    pub const moveQueuedCopy = @import("jobs.zig").moveQueuedCopy;
    pub const reapTransfers = @import("jobs.zig").reapTransfers;
    pub const startTransfer = @import("jobs.zig").startTransfer;
    pub const startDaemonJob = @import("jobs.zig").startDaemonJob;
    pub const startDaemonJobResumable = @import("jobs.zig").startDaemonJobResumable;
    pub const startDaemonJobKind = @import("jobs.zig").startDaemonJobKind;
    pub const onJobEvent = @import("jobs.zig").onJobEvent;
    pub const startDaemonJobUndo = @import("jobs.zig").startDaemonJobUndo;
    pub const startHistoryJob = @import("jobs.zig").startHistoryJob;
    pub const startDaemonJobTo = @import("jobs.zig").startDaemonJobTo;
    pub const markJob = @import("jobs.zig").markJob;

    // jobpanel.zig -- the jobs/transfers panel (rows, rate, controls)
    pub const jobsButton = @import("jobpanel.zig").jobsButton;
    pub const onJobBtn = @import("jobpanel.zig").onJobBtn;
    pub const renderJobs = @import("jobpanel.zig").renderJobs;

    // open.zig -- opening files, Open With, edit sync-back
    pub const openRemoteFile = @import("open.zig").openRemoteFile;
    pub const openRemoteFileHc = @import("open.zig").openRemoteFileHc;
    pub const openPathOnHost = @import("open.zig").openPathOnHost;
    pub const openWithDialog = @import("open.zig").openWithDialog;
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
    pub const thumbWriteBack = @import("preview.zig").thumbWriteBack;
    pub const scheduleThumbRender = @import("preview.zig").scheduleThumbRender;
    pub const onThumbRenderTick = @import("preview.zig").onThumbRenderTick;
    pub const thumbLookup = @import("preview.zig").thumbLookup;
    pub const enqueueRemoteThumb = @import("preview.zig").enqueueRemoteThumb;
    pub const pumpRemoteThumbs = @import("preview.zig").pumpRemoteThumbs;
    pub const finishRemoteThumb = @import("preview.zig").finishRemoteThumb;
    pub const feedRemoteThumb = @import("preview.zig").feedRemoteThumb;
    pub const queueRemoteDecode = @import("preview.zig").queueRemoteDecode;
    pub const releaseRemoteThumbFor = @import("preview.zig").releaseRemoteThumbFor;
    pub const markThumbFailed = @import("preview.zig").markThumbFailed;
    pub const clearThumbCache = @import("preview.zig").clearThumbCache;
    pub const clearPreviewContent = @import("preview.zig").clearPreviewContent;
    pub const previewHostDied = @import("preview.zig").previewHostDied;
    pub const abandonPreviewRead = @import("preview.zig").abandonPreviewRead;
    pub const abandonPreload = @import("preview.zig").abandonPreload;
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
    pub const quickLookStep = @import("preview.zig").quickLookStep;
    pub const quickLookActivate = @import("preview.zig").quickLookActivate;

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
    pub const runSavedSearch = @import("places.zig").runSavedSearch;
    pub const onSaveSearchClicked = @import("places.zig").onSaveSearchClicked;
    pub const onBookmarkRemove = @import("places.zig").onBookmarkRemove;
    pub const savePlaces = @import("places.zig").savePlaces;
    pub const addBookmark = @import("places.zig").addBookmark;
    pub const recordRecentSpec = @import("places.zig").recordRecentSpec;

    // search.zig -- find/grep, collections, duplicate finder
    pub const onMenuCollectionAdd = @import("search.zig").onMenuCollectionAdd;
    pub const ensureCollectionTab = @import("search.zig").ensureCollectionTab;
    pub const appendCollectionEntry = @import("search.zig").appendCollectionEntry;
    pub const onMenuCollectionRemove = @import("search.zig").onMenuCollectionRemove;
    pub const startSearch = @import("search.zig").startSearch;
    pub const onSearchMatch = @import("search.zig").onSearchMatch;
    pub const onSearchUnmatch = @import("search.zig").onSearchUnmatch;
    pub const startDupScan = @import("search.zig").startDupScan;
    pub const dupConsumeEvent = @import("search.zig").dupConsumeEvent;
    pub const dupStartHashPhase = @import("search.zig").dupStartHashPhase;
    pub const dupMaybeFinish = @import("search.zig").dupMaybeFinish;
    pub const onSearchToggled = @import("search.zig").onSearchToggled;
    pub const onSearchActivate = @import("search.zig").onSearchActivate;

    // compare.zig -- the compare/sync window
    pub const onMenuSyncHere = @import("compare.zig").onMenuSyncHere;
    pub const startCompare = @import("compare.zig").startCompare;

    // gitstat.zig -- the git status overlay
    pub const clearGitMap = @import("gitstat.zig").clearGitMap;
    pub const refreshGitOverlay = @import("gitstat.zig").refreshGitOverlay;
    pub const gitThreadMain = @import("gitstat.zig").gitThreadMain;
    pub const finishGit = @import("gitstat.zig").finishGit;
    pub const onGitIdle = @import("gitstat.zig").onGitIdle;

    /// Create a browser face on `pane`, starting at `start_spec`
    /// (a path or host-qualified spec; null/relative = $HOME).
    pub fn attach(allocator: std.mem.Allocator, pane: *Pane, start_spec: ?[]const u8) !*BrowserView {
        // A pane owns at most one browser face; re-attaching would
        // orphan the previous one together with its connections.
        if (fromPane(pane)) |existing| return existing;
        const self = try allocator.create(BrowserView);
        self.* = .{ .allocator = allocator, .pane = pane };
        self.emblems = emblems_mod.load(allocator);
        self.thumbs = std.StringHashMap(*c.GdkTexture).init(allocator);
        self.thumb_failed = std.StringHashMap(void).init(allocator);
        self.git_map = std.StringHashMap(u8).init(allocator);
        if (places_mod.load(allocator)) |parsed| {
            defer parsed.deinit();
            for (parsed.value.bookmarks) |b| {
                const owned = allocator.dupe(u8, b) catch continue;
                self.bookmarks.append(allocator, owned) catch allocator.free(owned);
            }
            for (parsed.value.recent) |r| {
                const owned = allocator.dupe(u8, r) catch continue;
                self.recent.append(allocator, owned) catch allocator.free(owned);
            }
            for (parsed.value.collection) |ci| {
                const spec = allocator.dupe(u8, ci.spec) catch continue;
                self.collection_items.append(allocator, .{ .spec = spec, .dir = ci.dir }) catch allocator.free(spec);
            }
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
        }
        self.loadFileColors();

        self.buildUi();
        // The view menu rides the toolbar buildUi just built.
        self.installViewMenu();
        pane.attachBrowser(self.root_box, @ptrCast(self), destroyCb);

        const home = if (c.getenv("HOME")) |h| std.mem.span(@as([*:0]const u8, @ptrCast(h))) else "/";
        if (start_spec) |sp| {
            const loc = parseSpec(sp);
            const path = if (loc.path.len > 0 and loc.path[0] == '/') loc.path else home;
            _ = self.newTab(loc.host, path);
        } else {
            _ = self.newTab(null, home);
        }
        return self;
    }

    fn destroyCb(ctx: *anyopaque) void {
        const self: *BrowserView = @ptrCast(@alignCast(ctx));
        self.deinit();
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
            if (!std.mem.startsWith(u8, name, "user.")) continue;
            if (tab.attr_columns.items.len >= MAX_ATTR_COLUMNS) break;
            const owned = self.allocator.dupe(u8, name) catch continue;
            tab.attr_columns.append(self.allocator, owned) catch self.allocator.free(owned);
        }
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
        if (self.switch_idle != 0) {
            _ = c.g_source_remove(self.switch_idle);
            self.switch_idle = 0;
        }
        self.jobs_panel.deinit(self.allocator);
        self.copy_queue.deinit(self.allocator);
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
        for (self.tabs.items) |t| t.deinit();
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
            self.allocator.free(pj.label);
            self.allocator.destroy(pj);
        }
        self.pending_jobs.deinit(self.allocator);
        for (self.jobs.items) |j| {
            if (j.undo_op) |u| u.destroy(self.allocator);
            if (j.undo_trash_orig) |o| self.allocator.free(o);
            if (j.history_op) |op| op.destroy(self.allocator);
            self.allocator.free(j.label);
            self.allocator.destroy(j);
        }
        self.jobs.deinit(self.allocator);
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
        if (self.clip_host) |s| self.allocator.free(s);
        if (self.clip_path) |s| self.allocator.free(s);
        for (self.clip_paths.items) |p| self.allocator.free(p);
        self.clip_paths.deinit(self.allocator);
        self.closePathCompletion();
        if (self.completion_source != 0) _ = c.g_source_remove(self.completion_source);
        if (self.completion_request) |request| request.destroy(self.allocator);
        self.locbar.deinit(self.allocator);
        self.closed_tabs.deinit(self.allocator);
        self.views.deinit(self.allocator);
        self.emblems.deinit();
        self.endProbesFor(null, "");
        self.probes.deinit(self.allocator);
        self.endAttrRequest();
        if (self.preview_read) |pr| pr.destroy(self.allocator);
        self.preview_state.deinit(self.allocator);
        if (self.restore_read) |rr| rr.destroy(self.allocator);
        if (self.dup) |d| d.destroy(self.allocator);
        if (self.editor_rename) |er| er.destroy(self.allocator);
        if (self.thumb_render_src != 0) _ = c.g_source_remove(self.thumb_render_src);
        if (self.thumb_ctx) |tc| {
            tc.lock();
            tc.orphaned = true;
            tc.shutdown = true;
            _ = c.pthread_cond_signal(&tc.cond);
            tc.unlock();
            tc.unref(); // the view's ref; thread + idles drop theirs
        }
        if (self.remote_thumb) |rt| rt.destroy(self.allocator);
        for (self.remote_thumb_queue.items) |rt| rt.destroy(self.allocator);
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
        for (self.recent.items) |r| self.allocator.free(r);
        self.recent.deinit(self.allocator);
        for (self.saved_searches.items) |sq| sq.deinitOwned(self.allocator);
        self.saved_searches.deinit(self.allocator);
        for (self.collection_items.items) |ci| self.allocator.free(ci.spec);
        self.collection_items.deinit(self.allocator);
        if (self.last_search) |ls| ls.deinitOwned(self.allocator);
        for (self.file_colors.items) |fc| self.allocator.free(fc.glob);
        self.file_colors.deinit(self.allocator);
        if (self.git_inflight) |g| g.orphaned = true;
        self.clearGitMap();
        self.git_map.deinit();
        if (self.git_root.len > 0) self.allocator.free(self.git_root);
        self.clearThumbCache();
        self.thumbs.deinit();
        var fit = self.thumb_failed.iterator();
        while (fit.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.thumb_failed.deinit();
        self.allocator.destroy(self);
    }

    fn buildUi(self: *BrowserView) void {
        const vbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(vbox, 1);
        c.gtk_widget_set_vexpand(vbox, 1);

        const bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_widget_set_margin_start(bar, 4);
        c.gtk_widget_set_margin_end(bar, 4);
        c.gtk_widget_set_margin_top(bar, 4);
        c.gtk_widget_set_margin_bottom(bar, 4);

        const back = c.gtk_button_new_from_icon_name("go-previous-symbolic");
        c.gtk_widget_set_sensitive(back, 0);
        _ = c.g_signal_connect_data(back, "clicked", @ptrCast(&onBackClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), back);
        self.appendHistoryArrow(bar, .back);
        const fwd = c.gtk_button_new_from_icon_name("go-next-symbolic");
        c.gtk_widget_set_sensitive(fwd, 0);
        _ = c.g_signal_connect_data(fwd, "clicked", @ptrCast(&onFwdClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), fwd);
        self.appendHistoryArrow(bar, .forward);
        const up = c.gtk_button_new_from_icon_name("go-up-symbolic");
        _ = c.g_signal_connect_data(up, "clicked", @ptrCast(&onUpClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), up);

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

        const hidden = c.gtk_toggle_button_new();
        c.gtk_button_set_icon_name(@ptrCast(hidden), "view-reveal-symbolic");
        c.gtk_widget_set_tooltip_text(hidden, "Show hidden files");
        _ = c.g_signal_connect_data(hidden, "toggled", @ptrCast(&onHiddenToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), hidden);

        const search_toggle = c.gtk_toggle_button_new();
        c.gtk_button_set_icon_name(@ptrCast(search_toggle), "system-search-symbolic");
        c.gtk_widget_set_tooltip_text(search_toggle, "Search this directory (daemon-side, recursive)");
        _ = c.g_signal_connect_data(search_toggle, "toggled", @ptrCast(&onSearchToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), search_toggle);

        const places_toggle = c.gtk_toggle_button_new();
        c.gtk_button_set_icon_name(@ptrCast(places_toggle), "user-bookmarks-symbolic");
        c.gtk_widget_set_tooltip_text(places_toggle, "Places sidebar (bookmarks, recent, devices)");
        _ = c.g_signal_connect_data(places_toggle, "toggled", @ptrCast(&onPlacesToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), places_toggle);

        const viewmode = c.gtk_button_new_from_icon_name("view-grid-symbolic");
        c.gtk_widget_set_tooltip_text(viewmode, "Cycle view: details / compact / grid / columns");
        _ = c.g_signal_connect_data(viewmode, "clicked", @ptrCast(&onViewModeClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), viewmode);

        const preview_toggle = c.gtk_toggle_button_new();
        c.gtk_button_set_icon_name(@ptrCast(preview_toggle), "view-dual-symbolic");
        c.gtk_widget_set_tooltip_text(preview_toggle, "Preview panel (images, text head, metadata)");
        _ = c.g_signal_connect_data(preview_toggle, "toggled", @ptrCast(&onPreviewToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), preview_toggle);

        const newtab = c.gtk_button_new_from_icon_name("tab-new-symbolic");
        c.gtk_widget_set_tooltip_text(newtab, "New browser tab");
        _ = c.g_signal_connect_data(newtab, "clicked", @ptrCast(&onNewTabClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), newtab);

        const cwdbtn = c.gtk_button_new_from_icon_name("go-jump-symbolic");
        c.gtk_widget_set_tooltip_text(cwdbtn, "Go to the shell's current directory (OSC 7)");
        _ = c.g_signal_connect_data(cwdbtn, "clicked", @ptrCast(&onCwdSyncClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), cwdbtn);

        const term = c.gtk_button_new_from_icon_name("utilities-terminal-symbolic");
        c.gtk_widget_set_tooltip_text(term, "Show the pane's terminal (browser stays one click away)");
        _ = c.g_signal_connect_data(term, "clicked", @ptrCast(&onTerminalClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), term);

        c.gtk_box_append(@ptrCast(vbox), bar);

        const sbar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_widget_set_margin_start(sbar, 4);
        c.gtk_widget_set_margin_end(sbar, 4);
        c.gtk_widget_set_margin_bottom(sbar, 4);
        const sentry = c.gtk_entry_new();
        c.gtk_widget_set_hexpand(sentry, 1);
        c.gtk_entry_set_placeholder_text(@ptrCast(sentry), "name/glob, content toggle, or !command to panelize host output");
        _ = c.g_signal_connect_data(sentry, "activate", @ptrCast(&onSearchActivate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(sbar), sentry);
        const scontent = c.gtk_check_button_new_with_label("in contents");
        c.gtk_box_append(@ptrCast(sbar), scontent);
        const ssave = c.gtk_button_new_from_icon_name("starred-symbolic");
        c.gtk_widget_set_tooltip_text(ssave, "Save the last search (shows in the Places sidebar)");
        _ = c.g_signal_connect_data(ssave, "clicked", @ptrCast(&onSaveSearchClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(sbar), ssave);
        c.gtk_widget_set_visible(sbar, 0);
        c.gtk_box_append(@ptrCast(vbox), sbar);

        const notebook = c.gtk_notebook_new();
        c.gtk_notebook_set_scrollable(@ptrCast(notebook), 1);
        c.gtk_widget_set_hexpand(notebook, 1);
        c.gtk_widget_set_vexpand(notebook, 1);
        _ = c.g_signal_connect_data(notebook, "switch-page", @ptrCast(&onSwitchPage), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        // Content row: places | notebook | preview (side panels
        // hidden until toggled).
        const content = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_widget_set_hexpand(content, 1);
        c.gtk_widget_set_vexpand(content, 1);

        const pl_scroll = c.gtk_scrolled_window_new();
        c.gtk_widget_set_size_request(pl_scroll, 190, -1);
        const pl_list = c.gtk_list_box_new();
        c.gtk_list_box_set_selection_mode(@ptrCast(pl_list), c.GTK_SELECTION_NONE);
        c.gtk_list_box_set_activate_on_single_click(@ptrCast(pl_list), 1);
        _ = c.g_signal_connect_data(pl_list, "row-activated", @ptrCast(&onPlaceActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_scrolled_window_set_child(@ptrCast(pl_scroll), pl_list);
        c.gtk_widget_set_visible(pl_scroll, 0);
        c.gtk_box_append(@ptrCast(content), pl_scroll);

        c.gtk_box_append(@ptrCast(content), notebook);

        const pbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
        c.gtk_widget_set_size_request(pbox, 300, -1);
        c.gtk_widget_set_margin_start(pbox, 8);
        c.gtk_widget_set_margin_end(pbox, 8);
        c.gtk_widget_set_margin_top(pbox, 8);
        const pmeta = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(pmeta), 0);
        c.gtk_label_set_wrap(@ptrCast(pmeta), 1);
        c.gtk_label_set_selectable(@ptrCast(pmeta), 1);
        c.gtk_box_append(@ptrCast(pbox), pmeta);
        const ppic = c.gtk_picture_new();
        c.gtk_widget_set_size_request(ppic, 284, 200);
        c.gtk_box_append(@ptrCast(pbox), ppic);
        const ptext_scroll = c.gtk_scrolled_window_new();
        c.gtk_widget_set_vexpand(ptext_scroll, 1);
        const ptext = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(ptext), 0);
        c.gtk_label_set_yalign(@ptrCast(ptext), 0);
        c.gtk_label_set_wrap(@ptrCast(ptext), 1);
        c.gtk_label_set_selectable(@ptrCast(ptext), 1);
        c.gtk_widget_add_css_class(ptext, "monospace");
        c.gtk_scrolled_window_set_child(@ptrCast(ptext_scroll), ptext);
        c.gtk_box_append(@ptrCast(pbox), ptext_scroll);
        c.gtk_widget_set_visible(pbox, 0);
        c.gtk_box_append(@ptrCast(content), pbox);

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

        self.root_box = vbox;
        self.notebook = @ptrCast(@alignCast(notebook));
        self.path_entry = @ptrCast(@alignCast(entry));
        self.back_button = back;
        self.fwd_button = fwd;
        self.status_label = @ptrCast(@alignCast(status));
        self.jobs_box = jobs_box;
        self.search_bar = sbar;
        self.search_entry = @ptrCast(@alignCast(sentry));
        self.search_content = scontent;
        self.hidden_toggle = @ptrCast(@alignCast(hidden));
        self.preview_box = pbox;
        self.preview_pic = ppic;
        self.preview_text = @ptrCast(@alignCast(ptext));
        self.preview_meta = @ptrCast(@alignCast(pmeta));
        self.places_scroller = pl_scroll;
        self.places_list = @ptrCast(@alignCast(pl_list));
    }
};
