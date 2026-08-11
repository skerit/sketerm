//! EditorView — the text-editor face on a Pane (browser-face
//! precedent: attach/detach via Pane's five-pointer contract, key
//! fallback to the pane's binding table, deferred teardown fenced by
//! `widgets_dead`).
//!
//! Structure: a TabHost whose notebook is a STRIP ONLY (pages are
//! empty zero-height boxes) above a GtkGrid holding ONE GtkGLArea
//! (inside a GtkOverlay that carries the find bar) plus a vertical and
//! a horizontal GtkScrollbar. Inactive tabs keep models only. The GL
//! realize/unrealize contract is Pane's exactly: adoptAreaApi +
//! forget-all on realize, releaseGL under a current context on
//! unrealize.
//!
//! ## Scroll position is an ANCHOR, not a pixel
//!
//! Each tab stores `(line, wrapped row, px offset)` plus an estimated
//! `RowIndex` — see render/editor_viewport.zig for the full rationale.
//! Consequences for anyone editing this file:
//! - NEVER reintroduce an absolute `scroll_y`; every jump goes through
//!   `setAnchorRow` / `scrollByPx`, which lay out only what they pass.
//! - Anything that changes the LINE COUNT, the wrap width or the wrap
//!   flag must call `resetRows` (the estimate is per-line).
//! - The vertical scrollbar's adjustment is in ESTIMATED rows; the
//!   `sb_guard` flag stops its value-changed handler from fighting the
//!   value we push into it.
//!
//! ## External changes
//!
//! Every open document's file is stat-probed when the user returns to
//! the editor (focus, tab switch, click); a clean buffer reloads
//! itself, a dirty one raises the inline banner. See the
//! "external-change detection" section below for why this is a poll
//! and not a daemon directory watch, and `editor/reload.zig` for the
//! predicate.
//!
//! Deliberate simplifications (documented, not accidental):
//! - Soft wrap breaks at UAX #14 opportunities (editor/linebreak.zig;
//!   CJK breaks between ideographs, trailing spaces hang) and falls
//!   back to a cluster boundary only for a token wider than the view;
//!   `editor_wrap_words = false` restores the anywhere-wrap.
//! - Find is literal by default; the `.*` toggle switches the bar to
//!   regular expressions (editor/search.zig + editor/regex.zig, which
//!   lists the syntax and what it deliberately leaves out).
//!   Replacements then expand `$1`..`$9` capture references.
//! - An external reload is applied as ONE transaction against the live
//!   document (editor/diff.zig), so undo history survives it and
//!   undoing past a reload restores the pre-reload text; only a FIRST
//!   load builds a fresh document.
//! - The IME preedit is laid out in its own throwaway Document, drawn
//!   OVER the text it will displace behind an opaque backing rect
//!   rather than reflowing the line; with several carets it shows at
//!   the primary caret only and commits to all of them.
//! - Undo/redo restore selections properly: Document hands back the
//!   edits it applied plus the pre-edit selection, so view_model
//!   restores or MAPS rather than clamping.
//! - Ctrl+Shift+S / Ctrl+Shift+Z are claimed by the editor face
//!   (Save As / Redo), shadowing the global save_layout /
//!   restore_closed_tab while the editor has focus.
//!
//! ## Structure (brackets / folding / expand-selection)
//!
//! All three read the tree-sitter trees the highlighting already
//! keeps — see editor/syntax.zig for the queries and
//! editor/structure.zig for the fold-anchoring rationale. Behaviour
//! that is a DECISION rather than a consequence:
//! - Bracket matching asks the tree first and takes its "no pair"
//!   answer as final; that is what keeps a bracket inside a string or
//!   a comment from matching. The depth-counting scanner runs only
//!   when there is no tree at all (no grammar, or `editor_syntax`
//!   off), and cannot see strings or comments.
//! - Folding never adds an absolute `scroll_y`. A folded line weighs
//!   ZERO rows in the RowIndex, so the anchor, the scrollbar and every
//!   row conversion stay correct with no second code path — which is
//!   also why the index is now allocated when folds exist even with
//!   soft wrap off.
//! - Folding a region containing carets pulls them to the header line;
//!   moving a caret INTO hidden text (Right off the end of a header, a
//!   find match, goto-line) unfolds instead. Up/Down never need that:
//!   `stepVisualRow` steps over folds.
//! - Fold regions are re-derived from the tree after every parse and
//!   NOT while it lags, so a fold keeps its last known lines for the
//!   length of the debounce rather than snapping to the indentation
//!   fallback for one frame.
//! - Shrink-selection replays a recorded stack, it never re-derives a
//!   smaller node: with several carets those are different sets. Any
//!   non-structural caret move or edit drops the stack.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const gl_mod = @import("../render/gl.zig");
const atlas_mod = @import("../render/atlas.zig");
const Atlas = atlas_mod.Atlas;
const font_mod = @import("../render/editor_font.zig");
const FontBook = font_mod.FontBook;
const layout_mod = @import("../render/editor_layout.zig");
const Layout = layout_mod.Layout;
const editor_pass = @import("../render/editor_pass.zig");
const EditorPass = editor_pass.EditorPass;
const viewport_mod = @import("../render/editor_viewport.zig");
const Anchor = viewport_mod.Anchor;
const RowIndex = viewport_mod.RowIndex;
const search = @import("../editor/search.zig");
const Document = @import("../editor/document.zig").Document;
const reload = @import("../editor/reload.zig");
const journal = @import("../editor/journal.zig");
const sel_mod = @import("../editor/selection.zig");
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const vm = @import("../editor/view_model.zig");
const ecmd = @import("../editor/commands.zig");
const editormenu = @import("editormenu.zig");
const toolbtn = @import("toolbtn.zig");
const confirm = @import("confirm.zig");
const editor_model = @import("../editor/model.zig");
const syntax = @import("../editor/syntax.zig");
const structure = @import("../editor/structure.zig");
const project_mod = @import("../editor/project.zig");
const gitdiff = @import("../editor/gitdiff.zig");
const outline_mod = @import("../editor/outline.zig");
const psearch = @import("../editor/psearch.zig");
const tr = @import("../editor/transaction.zig");
const ediff = @import("../editor/diff.zig");
const theme_mod = @import("../editor/theme.zig");
const tabhost_mod = @import("tabhost.zig");
const TabHost = tabhost_mod.TabHost;
const pane_mod = @import("pane.zig");
const Pane = pane_mod.Pane;
const paths = @import("../filebrowser/paths.zig");
const imhost = @import("imhost.zig");
const clipboard = @import("clipboard.zig");
const fsdrive = @import("../ipc/fsdrive.zig");
const muxclient = @import("../mux/client.zig");
const input = @import("input.zig");
const findbar = @import("findbar.zig");
const Config = @import("../config.zig").Config;
const fpicker = @import("../filebrowser/picker.zig");
const editorlsp = @import("editorlsp.zig");
const lsp_session = @import("../lsp/session.zig");
const lsp_pos = @import("../lsp/position.zig");
const PickerWindow = @import("picker.zig").PickerWindow;
const editorproj = @import("editorproj.zig");
const editoroutline = @import("editoroutline.zig");
const a11y = @import("../a11y/atspi.zig");
const a11ydoc = @import("../a11y/docsource.zig");
const docview = @import("../a11y/docview.zig");
const clock = @import("../util/clock.zig");

/// Open size cap: bigger files are refused with a clear error.
pub const MAX_FILE_BYTES: usize = 64 << 20;

/// Documents up to this size re-parse SYNCHRONOUSLY on every edit —
/// a full tree-sitter parse of ~100KB is well under a frame, and the
/// incremental path makes the common keystroke far cheaper still.
/// Bigger documents debounce (see `scheduleParse`); the GUI is
/// single-threaded by design, so a timer is the only lever.
const SYNC_PARSE_LIMIT: usize = 128 * 1024;
const PARSE_DEBOUNCE_MS: c_uint = 40;
/// Bytes of the first line inspected for a shebang when the filename
/// carries no usable extension.
const SHEBANG_PROBE: usize = 256;

// ---- crash recovery ---------------------------------------------------
//
// See editor/journal.zig for the record format and the flock-based
// crash predicate. The five steps of its UI contract land here:
// `armJournal`/`journalTick` (open + debounced write), `onIoDone`
// (clear after save), `ETab.destroy` (discard on close), `offerRecovery`
// (the startup offer) and the `prune` inside it.

/// Debounce between snapshots of a dirty buffer. Long enough that
/// typing never pays for it, short enough that a crash costs a second.
const JOURNAL_DEBOUNCE_MS: c_uint = 1500;
/// Records nobody claimed in a week are dropped (contract step 5).
const JOURNAL_MAX_AGE_MS: i64 = 7 * 24 * 60 * 60 * 1000;
/// Seed for the "is the buffer identical to what was saved" hash. See
/// `journalTick` for why a revision comparison is not enough.
const SAVED_HASH_SEED: u64 = 0x5a7ed;

/// The recovery offer is per PROCESS, not per face: several editor
/// faces must not each open the same records.
var recovery_offered: bool = false;

/// Refcounted liveness fence shared by IO worker threads, GLib idle
/// deliveries, clipboard reads and dialog callbacks. The mutex only
/// matters for the worker threads; everything else runs on the main
/// loop.
pub const Fence = struct {
    mutex: c.pthread_mutex_t = undefined,
    refs: u32 = 1,
    alive: bool = true,
    view: *EditorView,

    fn create(view: *EditorView) ?*Fence {
        const self = std.heap.c_allocator.create(Fence) catch return null;
        self.* = .{ .view = view };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) {
            std.heap.c_allocator.destroy(self);
            return null;
        }
        return self;
    }

    pub fn ref(self: *Fence) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.refs += 1;
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    pub fn unref(self: *Fence) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.refs -= 1;
        const destroy = self.refs == 0;
        _ = c.pthread_mutex_unlock(&self.mutex);
        if (destroy) {
            _ = c.pthread_mutex_destroy(&self.mutex);
            std.heap.c_allocator.destroy(self);
        }
    }

    /// Kill + drop the owning reference (view teardown).
    fn close(self: *Fence) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.alive = false;
        _ = c.pthread_mutex_unlock(&self.mutex);
        self.unref();
    }

    pub fn viewIfAlive(self: *Fence) ?*EditorView {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        return if (self.alive) self.view else null;
    }
};

/// One daemon-backed read or atomic write, run on a detached thread
/// (fsdrive calls block; the GLib loop must not). Owned allocations
/// via c_allocator; delivered with g_idle_add.
const IoJob = struct {
    fence: *Fence,
    /// Matches ETab.io_gen; a mismatch at delivery = orphaned.
    gen: u64,
    kind: enum { load, save },
    spec: []u8,
    save_bytes: []u8 = &.{},
    expected_mtime: ?i64 = null,
    /// Document revision the save snapshot was taken at.
    revision: u64 = 0,

    ok: bool = false,
    conflict: bool = false,
    /// Load of a path that does not exist (yet): a new empty file.
    not_found: bool = false,
    binary: bool = false,
    err_buf: [96]u8 = undefined,
    err_len: usize = 0,
    bytes: []u8 = &.{},
    /// Post-op identity of the file: the new conflict baseline after a
    /// load/save, and the OTHER file's identity after a conflict.
    disk: reload.DiskState = .{},
    /// Reload that must land on the current cursor/scroll, not at the
    /// top of the document.
    keep_position: bool = false,

    fn setErr(self: *IoJob, text: []const u8) void {
        self.err_len = @min(text.len, self.err_buf.len);
        @memcpy(self.err_buf[0..self.err_len], text[0..self.err_len]);
    }

    fn errText(self: *const IoJob) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    fn destroy(self: *IoJob) void {
        const a = std.heap.c_allocator;
        a.free(self.spec);
        if (self.save_bytes.len > 0) a.free(self.save_bytes);
        if (self.bytes.len > 0) a.free(self.bytes);
        self.fence.unref();
        a.destroy(self);
    }
};

pub fn connectFs(host: ?[]const u8) !fsdrive.Fs {
    const allocator = std.heap.c_allocator;
    const conn = if (host) |remote| blk: {
        var config = Config.load(allocator);
        defer config.deinit();
        break :blk try muxclient.Conn.connectRemote(allocator, remote, config.udpRange());
    } else try muxclient.Conn.connectLocalAutostart(allocator);
    return fsdrive.Fs.initConn(allocator, conn);
}

/// Observe one path's identity, following symlinks (fsdrive.statFollow
/// explains why the follow is mandatory).
///
/// A missing path answers `present = false`; a TRANSPORT failure
/// returns false, so a dead link can never be mistaken for a deleted
/// file.
fn probePath(fs: *fsdrive.Fs, path: []const u8, out: *reload.DiskState) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const e = fs.statFollow(arena.allocator(), path) catch |err| {
        if (err == fsdrive.Error.FsOpFailed or err == fsdrive.Error.BadRequest) {
            out.* = .{ .known = true, .present = false };
            return true;
        }
        return false;
    };
    out.* = .{
        .known = true,
        .present = true,
        .mtime_ns = e.mtime_ns,
        .mtime_ms = e.mtime_ms,
        .size = e.size,
        .ino = e.ino,
        .mode = e.mode,
    };
    return true;
}

/// Read a whole host-side file into `out`, refusing anything over
/// `MAX_FILE_BYTES`. The project layer reads files through this too,
/// so a candidate that is too big is refused identically to one the
/// user tries to open.
pub fn readAllCapped(fs: *fsdrive.Fs, path: []const u8, out: *std.ArrayList(u8), cap: usize) !void {
    var info: fsdrive.ReadInfo = .{ .size = 0, .eof = true };
    return readAllInto(fs, path, out, cap, &info);
}

fn readAllInto(fs: *fsdrive.Fs, path: []const u8, out: *std.ArrayList(u8), cap: usize, info_out: *fsdrive.ReadInfo) !void {
    const allocator = std.heap.c_allocator;
    const probe = try fs.read(path, 0, 0, out);
    if (probe.size > cap) return error.SourceTooLarge;
    info_out.* = probe;
    try out.ensureTotalCapacity(allocator, @intCast(probe.size));
    var offset: u64 = 0;
    while (offset < probe.size) {
        const before = out.items.len;
        const remaining = probe.size - offset;
        const requested: u32 = @intCast(@min(remaining, fsdrive.fsserve.MAX_READ));
        const info = try fs.read(path, offset, requested, out);
        const received = out.items.len - before;
        if (received == 0) return error.ShortRead;
        offset += received;
        if (out.items.len > cap) return error.SourceTooLarge;
        if (info.eof) break;
    }
    if (offset != probe.size) return error.ShortRead;
}

fn ioThread(job: *IoJob) void {
    const allocator = std.heap.c_allocator;
    const loc = paths.parseSpec(job.spec);
    run: {
        var fs = connectFs(loc.host) catch |err| {
            job.setErr(@errorName(err));
            break :run;
        };
        defer fs.deinit();
        switch (job.kind) {
            .load => {
                var out: std.ArrayList(u8) = .empty;
                var info: fsdrive.ReadInfo = .{ .size = 0, .eof = true };
                readAllInto(&fs, loc.path, &out, MAX_FILE_BYTES, &info) catch |err| {
                    out.deinit(allocator);
                    if (err == error.SourceTooLarge or err == error.ShortRead) {
                        job.setErr(@errorName(err));
                    } else {
                        // Unreadable = treat as a NEW file (editor
                        // convention); a transport failure was caught
                        // by connectFs above.
                        job.not_found = true;
                        job.ok = true;
                    }
                    break :run;
                };
                if (std.mem.indexOfScalar(u8, out.items, 0) != null) {
                    out.deinit(allocator);
                    job.binary = true;
                    job.setErr("binary file (NUL bytes) — refusing to edit");
                    break :run;
                }
                job.bytes = out.toOwnedSlice(allocator) catch {
                    out.deinit(allocator);
                    job.setErr("OutOfMemory");
                    break :run;
                };
                // Identity from the FD the bytes came through (never a
                // separate stat, which could see a newer file than the
                // one just read) — with the permission bits filled in
                // from a follow-stat, since a read cannot report them.
                job.disk = .{
                    .known = true,
                    .present = true,
                    .mtime_ns = info.mtime_ns,
                    .size = info.size,
                    .ino = info.ino,
                };
                var st: reload.DiskState = .{};
                if (probePath(&fs, loc.path, &st) and st.present) {
                    job.disk.mode = st.mode;
                    if (job.disk.mtime_ns == 0) job.disk.mtime_ns = st.mtime_ns;
                    job.disk.mtime_ms = st.mtime_ms;
                }
                job.ok = true;
            },
            .save => {
                const res = fs.writeFileAtomic(loc.path, job.save_bytes, job.expected_mtime) catch |err| {
                    if (err == fsdrive.Error.Conflict) {
                        job.conflict = true;
                        if (fs.lastConflict()) |ci| job.disk = .{
                            .known = true,
                            .present = true,
                            .mtime_ns = ci.mtime_ns,
                            .mtime_ms = ci.mtime_ms,
                            .size = ci.size,
                            .ino = ci.ino,
                            .mode = ci.mode,
                        };
                    } else {
                        const detail = fs.lastErr();
                        if (detail.len > 0) job.setErr(detail) else job.setErr(@errorName(err));
                    }
                    break :run;
                };
                job.disk = .{
                    .known = true,
                    .present = true,
                    .mtime_ns = res.mtime_ns,
                    .mtime_ms = res.mtime_ms,
                    .size = res.size,
                    .ino = res.ino,
                    .mode = res.mode,
                };
                job.ok = true;
            },
        }
    }
    _ = c.g_idle_add(@ptrCast(&ioIdle), @ptrCast(job));
}

/// One batched disk-identity probe: every open document on ONE host,
/// statted through ONE connection. This is the whole external-change
/// detector (see `EditorView.checkDisk` for why it is a poll and not a
/// daemon watch).
const ProbeItem = struct {
    tab_id: u64,
    path: []u8,
    state: reload.DiskState = .{},
    /// False when the probe could not be taken (transport failure) —
    /// which must never be reported as "the file is gone".
    ok: bool = false,
};

const ProbeJob = struct {
    fence: *Fence,
    /// Owned copy of the host part of the specs ("" = local).
    host: []u8,
    items: []ProbeItem,

    fn destroy(self: *ProbeJob) void {
        const a = std.heap.c_allocator;
        for (self.items) |it| a.free(it.path);
        a.free(self.items);
        a.free(self.host);
        self.fence.unref();
        a.destroy(self);
    }
};

fn probeThread(job: *ProbeJob) void {
    const host: ?[]const u8 = if (job.host.len == 0) null else job.host;
    if (connectFs(host)) |fs_val| {
        var fs = fs_val;
        defer fs.deinit();
        for (job.items) |*it| it.ok = probePath(&fs, it.path, &it.state);
    } else |_| {}
    _ = c.g_idle_add(@ptrCast(&probeIdle), @ptrCast(job));
}

fn probeIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job: *ProbeJob = @ptrCast(@alignCast(user.?));
    if (job.fence.viewIfAlive()) |view| view.onProbeDone(job);
    job.destroy();
    return 0;
}

fn ioIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job: *IoJob = @ptrCast(@alignCast(user.?));
    if (job.fence.viewIfAlive()) |view| view.onIoDone(job);
    job.destroy();
    return 0;
}

/// One open document tab. Models only — the shared GLArea renders
/// whichever tab is active.
pub const ETab = struct {
    view: *EditorView,
    id: u64,
    /// Empty strip-only notebook page (zero height).
    page: *c.GtkWidget,
    handle: *tabhost_mod.TabLabel,
    doc: Document,
    sels: SelectionSet,
    layout: Layout,
    /// First visible (line, wrapped row, px into that row).
    anchor: Anchor = .{},
    /// Estimated wrapped-row count per line (scrollbar geometry).
    rows: RowIndex,
    /// Line count / wrap width the `rows` index was built for; a
    /// mismatch means it must be reset before it is trusted.
    rows_lines: usize = 0,
    rows_wrap_width: f32 = 0,
    /// Fold epoch the row index's hidden flags were stamped for.
    rows_folds: u64 = 0,
    /// Horizontal scroll, px (wrap off only).
    scroll_x: f32 = 0,
    /// Widest row seen so far, px — the horizontal scrollbar's range
    /// (grows as the user scrolls, like the vertical estimate).
    max_width: f32 = 0,
    /// Soft wrap for this tab (seeded from `editor_soft_wrap`).
    wrap: bool = false,
    goal_x: ?f32 = null,
    /// Find-bar state, per tab so switching tabs keeps each one's
    /// matches. Matches are owned.
    matches: []search.Match = &.{},
    current_match: ?usize = null,
    /// Needle the current `matches` were computed for (owned, so a
    /// document edit can recompute without re-reading the entry).
    needle: []u8 = &.{},
    /// Host-qualified spec; null = unsaved Untitled buffer.
    spec: ?[]u8 = null,
    /// Identity of the file as of the last load/save: the save
    /// conflict baseline AND the reference every disk probe compares
    /// against.
    disk: reload.DiskState = .{},
    /// The most recent probe result, whatever the verdict.
    seen: reload.DiskState = .{},
    /// Probe result the user dismissed the banner for; the banner stays
    /// down until the file moves on from it.
    dismissed: ?reload.DiskState = null,
    /// Which inline banner this tab wants (per tab: switching tabs
    /// switches the banner).
    alert: Alert = .none,
    /// The banner was raised by a REFUSED SAVE rather than by a probe —
    /// same state, different wording.
    alert_from_save: bool = false,
    /// The in-flight load is a history-preserving reload: the arriving
    /// bytes are DIFFED onto the live document as one transaction
    /// (editor/diff.zig) instead of replacing it, so carets/scroll map
    /// through and undo walks back through the reload.
    keep_active: bool = false,
    loading: bool = false,
    /// Generation for in-flight IO; 0 = idle.
    io_gen: u64 = 0,
    /// Caret to restore once an async load lands.
    want_cursor: ?usize = null,
    close_after_save: bool = false,
    /// Syntax highlighter, null for plain text (unknown language or
    /// `editor_syntax = false`). Owned.
    hl: ?*syntax.Highlighter = null,
    hl_lang: ?syntax.Lang = null,
    /// Non-zero while a debounced re-parse is queued.
    parse_timer: c_uint = 0,

    // ---- structure (brackets / folds / expand-selection) -------------
    //
    // Every cache below is keyed on `(doc.revision, hl.gen)` — the same
    // pair the layout cache and the highlighter's own kind window use —
    // plus whatever else the answer depends on. Nothing here may run a
    // whole-document tree query per frame.

    /// Folded regions, anchored by byte offset (editor/structure.zig
    /// explains why an offset and not a line number).
    folds: structure.FoldState,
    /// Bumped whenever the HIDDEN set actually changes; `ensureRows`
    /// watches it to know when to re-stamp the row index.
    folds_epoch: u64 = 0,
    /// (revision, highlighter gen) `folds` was last re-resolved at.
    folds_rev: u64 = 0,
    folds_gen: u64 = 0,
    folds_valid: bool = false,

    /// Gutter fold affordances for the visible line range.
    fold_markers: std.ArrayList(editor_pass.FoldMarker) = .empty,
    /// Cache key for `fold_markers`: revision, highlighter gen, the
    /// visible line range, and the fold epoch (folding changes which
    /// markers point which way).
    fm_rev: u64 = 0,
    fm_gen: u64 = 0,
    fm_epoch: u64 = 0,
    fm_from: usize = 0,
    fm_to: usize = 0,
    fm_valid: bool = false,

    /// Bracket boxes for the current carets (two ranges per matched
    /// caret).
    brackets: std.ArrayList(structure.Range) = .empty,
    /// Cache key: revision, highlighter gen, and a hash of the caret
    /// heads — a caret move is the only other thing that can change the
    /// answer.
    br_rev: u64 = 0,
    br_gen: u64 = 0,
    br_carets: u64 = 0,
    br_valid: bool = false,

    /// Expand/shrink trail (structure.SelectionStack).
    sel_stack: structure.SelectionStack,
    /// True while an expand/shrink is running, so the trail is not
    /// cleared by its own selection change.
    structural_move: bool = false,

    /// Language-server state: document sync queue, diagnostics store
    /// and the connection this document is attached to. Null until a
    /// server claims the file (no configured server, no installed
    /// binary, an unknown language and a remote spec all leave it
    /// null, silently).
    lsp: ?*editorlsp.TabState = null,
    /// LSP position (0-based, in the server's encoding) to put the
    /// caret on once the async load lands — a go-to-definition that
    /// had to open the file first.
    want_pos: ?lsp_pos.Position = null,

    // ---- project layer -----------------------------------------------
    //
    // See editor/project.zig for the model and ui/editorproj.zig for the
    // daemon round trips. Everything here is null/empty for a loose file
    // with no project, which is what keeps single-file editing free.

    /// The project this document belongs to (refcounted in
    /// `EditorView.projects`), resolved asynchronously once the spec is
    /// known. Null = no project.
    project: ?*project_mod.Project = null,
    /// Non-zero while a project resolution is in flight; a mismatch at
    /// delivery means the tab was reused for another file.
    proj_gen: u64 = 0,

    /// Per-line VCS marks for the gutter, anchored by byte offset and
    /// carried through every edit by `observeEdits`.
    git: gitdiff.Marks,
    /// Non-zero while a gutter refresh is in flight.
    git_gen: u64 = 0,

    /// Symbol outline: LSP `documentSymbol` where a server answers, the
    /// Tree-sitter tree otherwise.
    outline: outline_mod.Outline,
    /// Document revision the outline was built at, and whether an LSP
    /// request for it is outstanding.
    outline_rev: u64 = 0,
    outline_pending: bool = false,

    /// Top visible LINE restored from the layout, applied once the
    /// async load lands (the anchor itself is a wrap-dependent quantity
    /// and cannot be persisted).
    want_top_line: ?usize = null,
    /// Project root recorded by the layout, shown until the async
    /// re-derivation lands. Owned; dropped as soon as it does.
    restored_project: ?[]u8 = null,

    /// Crash-recovery slot: opened on the first edit that dirties this
    /// buffer and held (lock included) for the tab's lifetime, so no
    /// other process offers OUR record while we are alive.
    journal: ?journal.Handle = null,
    /// Hash of the buffer as of the last load/save. `Document.isDirty`
    /// compares REVISIONS, so undoing back to the saved state still
    /// reads dirty; this is what keeps a record for a buffer identical
    /// to disk from being offered as recovered work.
    saved_hash: u64 = 0,
    saved_hash_valid: bool = false,
    /// Journaling gave up on this buffer (over `journal.MAX_CONTENT`).
    /// Reported once; never retried.
    journal_off: bool = false,

    fn destroy(self: *ETab) void {
        const a = self.view.allocator;
        // Project first: the set is owned by the view and outlives us.
        self.view.projects.release(self.project);
        self.project = null;
        self.git.deinit();
        self.outline.deinit();
        if (self.restored_project) |rp| a.free(rp);
        // Closing a tab (or a clean quit, which destroys every tab) is
        // exactly the "no crash happened" case: drop the record.
        if (self.journal) |*h| {
            h.discard();
            self.journal = null;
        }
        // Normally `Manager.detachTab` has already run (closeTabForce);
        // this is the last-resort free for a tab destroyed on an error
        // path before it was ever listed.
        if (self.lsp) |st| {
            st.destroy();
            self.lsp = null;
        }
        // A queued parse timer is fenced (DlgCtx) and resolves to
        // nothing once this tab's id is gone — no removal needed.
        if (self.hl) |hl| {
            hl.deinit();
            a.destroy(hl);
            self.hl = null;
        }
        self.doc.clearObservers();
        self.folds.deinit();
        self.fold_markers.deinit(a);
        self.brackets.deinit(a);
        self.sel_stack.deinit();
        self.layout.hl = null;
        self.layout.deinit();
        self.rows.deinit();
        self.sels.deinit(a);
        self.doc.deinit();
        self.clearMatches();
        if (self.needle.len > 0) a.free(self.needle);
        if (self.spec) |s| a.free(s);
        a.destroy(self);
    }

    /// Everything this tab anchors by POSITION maps through every edit
    /// exactly like selections do — and because the hook is on
    /// `applyEdits`, undo and redo carry them all too. Fold anchors, the
    /// git gutter's marks and the symbol outline's ranges share this one
    /// observer slot rather than each claiming another.
    fn observeEdits(ctx: *anyopaque, _: *const Document, edits: []const tr.Edit) void {
        const self: *ETab = @ptrCast(@alignCast(ctx));
        if (!self.folds.isEmpty()) self.folds.mapThrough(edits);
        self.git.mapThrough(edits);
        self.outline.mapThrough(edits);
        self.folds_valid = false;
        self.fm_valid = false;
        self.br_valid = false;
    }

    fn clearMatches(self: *ETab) void {
        if (self.matches.len > 0) self.view.allocator.free(self.matches);
        self.matches = &.{};
        self.current_match = null;
    }

    pub fn isDirty(self: *const ETab) bool {
        return self.doc.isDirty();
    }

    fn title(self: *const ETab) []const u8 {
        const s = self.spec orelse return "Untitled";
        const loc = paths.parseSpec(s);
        const base = std.fs.path.basename(loc.path);
        return if (base.len == 0) s else base;
    }
};

/// The inline banner's state for one document.
pub const Alert = enum {
    none,
    /// The file changed on disk under a DIRTY buffer (a clean one is
    /// reloaded silently instead), or a save was refused.
    changed,
    /// The file is not on disk any more.
    deleted,
};

const DlgCtx = struct {
    fence: *Fence,
    tab_id: u64,

    fn create(view: *EditorView, tab: *ETab) ?*DlgCtx {
        const ctx = std.heap.c_allocator.create(DlgCtx) catch return null;
        view.fence.ref();
        ctx.* = .{ .fence = view.fence, .tab_id = tab.id };
        return ctx;
    }

    fn destroy(self: *DlgCtx) void {
        self.fence.unref();
        std.heap.c_allocator.destroy(self);
    }

    fn resolve(self: *DlgCtx) ?struct { view: *EditorView, tab: *ETab } {
        const view = self.fence.viewIfAlive() orelse return null;
        const tab = view.findTabById(self.tab_id) orelse return null;
        return .{ .view = view, .tab = tab };
    }
};

/// One frame's worth of scrollbar geometry. Vertical values are in
/// ESTIMATED rows, horizontal ones in pixels.
const ScrollGeom = struct {
    v_value: f64,
    v_upper: f64,
    v_page: f64,
    h_value: f64,
    h_upper: f64,
    h_page: f64,
    want_h: bool,
};

pub const EditorView = struct {
    allocator: std.mem.Allocator,
    pane: ?*Pane = null,
    fence: *Fence = undefined,

    root_box: *c.GtkWidget = undefined,
    tabhost: TabHost = undefined,
    area: *c.GtkGLArea = undefined,
    /// AT-SPI document source for `area` (role TEXT_BOX). Holds the
    /// byte<->character index; must outlive the GL area, which is why
    /// it is a field rather than a local. Severed with the face.
    a11y_src: a11ydoc.DocSource = .{},
    /// Accessible label last pushed to the canvas, so a status refresh
    /// that did not change the document name costs no GTK call.
    a11y_label: [260]u8 = [_]u8{0} ** 260,
    status_label: *c.GtkLabel = undefined,
    /// Shared IM plumbing (compose / dead keys / IME). Severed at the
    /// first sign of teardown, and unconditionally by `deinit` — the
    /// host keeps its client widget alive on its own (ImHost.detach),
    /// so no call site owns an ordering rule.
    im: ?*imhost.ImHost = null,
    widgets_dead: bool = false,

    // Scrollbars (vertical range in ESTIMATED rows, horizontal in px).
    vscroll: *c.GtkWidget = undefined,
    hscroll: *c.GtkWidget = undefined,
    vadj: *c.GtkAdjustment = undefined,
    hadj: *c.GtkAdjustment = undefined,
    /// True while WE are writing an adjustment — its value-changed
    /// handler must not treat that as a user drag.
    sb_guard: bool = false,
    /// Scrollbar geometry queued by the render pass, applied from an
    /// idle (see syncScrollbars). `sb_applied` is the last state
    /// actually pushed into the adjustments, so an unchanged frame
    /// queues nothing.
    sb_pending: ?ScrollGeom = null,
    sb_applied: ?ScrollGeom = null,
    sb_source: c_uint = 0,

    // Find/replace bar.
    find_bar: *c.GtkWidget = undefined,
    find_entry: *c.GtkWidget = undefined,
    replace_row: *c.GtkWidget = undefined,
    replace_entry: *c.GtkWidget = undefined,
    find_count: *c.GtkLabel = undefined,
    find_case: *c.GtkWidget = undefined,
    find_word: *c.GtkWidget = undefined,
    find_regex: *c.GtkWidget = undefined,
    find_open: bool = false,
    /// The needle is regex mode and did not compile; the count label
    /// says so instead of reporting an honest-looking "No results".
    find_bad_pattern: bool = false,

    // External-change banner (inline, above the canvas — never a
    // modal: it fires while the user is typing).
    banner_box: *c.GtkWidget = undefined,
    banner_label: *c.GtkLabel = undefined,
    banner_reload: *c.GtkWidget = undefined,
    banner_save: *c.GtkWidget = undefined,

    // Crash-recovery offer: the SAME inline vocabulary as the
    // external-change banner, deliberately not a modal — it appears
    // while the user is starting to work, may list several buffers, and
    // declining it must cost one click and lose nothing.
    recover_box: *c.GtkWidget = undefined,
    recover_label: *c.GtkLabel = undefined,
    /// Recoverable records this face is offering. Owned; entries are
    /// consumed by Recover and Discard, and merely dropped (records
    /// left ON DISK) by Dismiss.
    recovery: []journal.Entry = &.{},
    /// Debounced journal writer while any tab is dirty; 0 = disarmed.
    journal_timer: c_uint = 0,
    /// `editor_crash_recovery`, re-read by syncConfig.
    crash_recovery: bool = true,

    /// Monotonic ms of the last disk probe (rate limit) and how many
    /// probe jobs are in flight (never stack them).
    last_probe_ms: i64 = 0,
    probes_in_flight: u32 = 0,

    // ---- sticky transient status ------------------------------------
    //
    // `updateStatus` REBUILDS the status label from scratch on every
    // caret move, edit, tab switch, fold change and diagnostic publish.
    // A message written straight into the label is therefore gone
    // within milliseconds of being written — a rename that reported its
    // outcome, a "No VCS information for this file.", a "Formatted."
    // all vanished before they could be read. So a message is not
    // painted, it is POSTED: it lives here and every rebuild re-emits
    // it until it expires. See `postStatus`.
    note: [320]u8 = undefined,
    note_len: usize = 0,
    note_at_ms: i64 = 0,
    /// Fires once at expiry so a note also disappears from an IDLE
    /// face (nothing else would rebuild the label).
    note_timer: c_uint = 0,

    // Caret blink. A g_timeout, never a frame-clock tick: a tick
    // callback on a GtkGLArea leaks on Wayland (same reason Pane uses
    // blink_timer).
    blink_timer: c_uint = 0,
    caret_on: bool = true,
    /// Suppresses the blink for one interval after each keystroke, so
    /// the caret stays solid while typing.
    typing_hold: bool = false,

    // IME preedit, laid out in its own throwaway document so it shapes
    // exactly like real text.
    preedit_doc: ?Document = null,
    preedit_layout: ?Layout = null,
    preedit_cursor: usize = 0,

    atlas: ?*Atlas = null,
    /// Valid iff `atlas != null`; address handed to every Layout.
    book: FontBook = undefined,
    pass: EditorPass,
    /// sRGB offscreen detour for the non-native `text_blending` modes
    /// — the editor face owns its own GtkGLArea, so it needs its own.
    linear_target: @import("../render/blend.zig").LinearTarget = .{},
    text_blending: @import("../render/blend.zig").Mode = .native,
    colors: editor_pass.Colors = .{},

    tabs: std.ArrayList(*ETab) = .empty,
    active: ?*ETab = null,
    next_tab_id: u64 = 1,
    next_io_gen: u64 = 1,

    // Owned copies of the pane's font resolution inputs (the pane's
    // own fields live in the Config arena and re-point on config
    // reload; the editor face keeps its attach-time values).
    font_path: ?[]u8 = null,
    font_family: ?[]u8 = null,
    font_size: u16 = 14,
    line_pad: i16 = 0,

    /// Editor settings, OWNED copies re-resolved through
    /// `ownerWindow().config` (never slices into the config arena —
    /// applyConfigChange frees it under us).
    tab_width: u16 = 4,
    insert_spaces: bool = true,
    soft_wrap_default: bool = false,
    /// Soft wrap prefers UAX #14 break opportunities (config
    /// `editor_wrap_words`); false = anywhere-wrap.
    wrap_words: bool = true,
    line_numbers: bool = true,
    highlight_current_line: bool = true,
    syntax_on: bool = true,
    /// Box the bracket pair around the caret (`editor_bracket_match`).
    bracket_match: bool = true,
    /// Code folding: gutter column, chevrons, fold actions
    /// (`editor_folding`).
    folding: bool = true,
    /// Derive fold regions from INDENTATION when the file has no
    /// grammar (`editor_fold_indent_fallback`). Off means files with no
    /// grammar simply have no folds.
    fold_indent_fallback: bool = true,
    /// Colours for text, chrome and every highlight kind. Points at a
    /// comptime constant in `editor/theme.zig`, so it never dangles
    /// across a config-arena swap.
    theme: *const theme_mod.Theme = &theme_mod.dark,
    /// Typing behaviour toggles (`editor_auto_indent`,
    /// `editor_auto_close_pairs`, `editor_smart_backspace`).
    auto_indent: bool = true,
    auto_close: bool = true,
    smart_backspace: bool = true,
    /// Resolved editor-command bindings: `editor/commands.zig` defaults
    /// overlaid with `editor_keybind.*` config entries. Rebuilt by
    /// syncConfig; owned.
    ed_bindings: std.ArrayList(EdBinding) = .empty,
    /// Corner of an in-progress Shift+Alt block selection, in
    /// (line, byte column). Null when no block drag is active.
    block_anchor: ?struct { line: usize, col: usize } = null,
    /// The go-to-line dialog's entry while it is up (same lifetime
    /// contract as `rename_entry`).
    goto_entry: ?*c.GtkWidget = null,

    // ---- project layer -------------------------------------------------
    //
    // ui/editorproj.zig owns the daemon round trips and the
    // search-results panel; ui/editoroutline.zig owns the outline panel.
    // The state lives here so a tab and a panel can find each other
    // without a second lifetime to fence.

    /// Every project the open tabs belong to, deduplicated by
    /// (host, root) and refcounted per tab.
    projects: project_mod.Set = undefined,
    /// Project-wide search results + replace plan (one live search per
    /// face; starting another resets it).
    results: psearch.Results = undefined,
    /// Generation of the running project search; a reply stamped with
    /// anything else is from a superseded query.
    search_gen: u64 = 0,
    next_job_gen: u64 = 1,

    /// Bottom panel (project search) and right panel (outline), each
    /// inside its own GtkPaned so the user can size them.
    vpaned: *c.GtkWidget = undefined,
    hpaned: *c.GtkWidget = undefined,
    search_panel: *c.GtkWidget = undefined,
    search_entry: *c.GtkWidget = undefined,
    search_replace_entry: *c.GtkWidget = undefined,
    search_replace_row: *c.GtkWidget = undefined,
    search_status: *c.GtkLabel = undefined,
    search_list: *c.GtkWidget = undefined,
    search_preview_btn: *c.GtkWidget = undefined,
    search_apply_btn: *c.GtkWidget = undefined,
    search_case: *c.GtkWidget = undefined,
    search_word: *c.GtkWidget = undefined,
    search_regex: *c.GtkWidget = undefined,
    search_open: bool = false,
    /// A replace has been planned and is waiting for Apply.
    replace_previewed: bool = false,

    outline_panel: *c.GtkWidget = undefined,
    outline_list: *c.GtkWidget = undefined,
    outline_status: *c.GtkLabel = undefined,
    outline_open: bool = false,
    /// Shape hash the outline rows were built for, and the row the
    /// caret last selected — both guard against rebuilding (which is
    /// what would flicker).
    outline_sig: u64 = 0,
    outline_row: ?usize = null,
    /// True while WE are moving the outline selection, so its
    /// `selected-rows-changed` handler does not navigate.
    outline_guard: bool = false,

    /// `editor_git_gutter`, `editor_outline` and the project marker
    /// list, re-read by syncConfig. The marker list is an OWNED copy
    /// (config arenas are swapped under us).
    git_gutter: bool = true,
    outline_default: bool = false,
    project_markers: ?[]u8 = null,
    search_max_files: u32 = 4000,

    drag_anchor: ?usize = null,

    /// STANDALONE hosting (ui/editorwin.zig): the face has no pane and
    /// no sketerm Window, so `ownerWindow()` never resolves and these
    /// three fields carry what the window would otherwise supply — the
    /// config to read settings from, the toolbar to hide (the window's
    /// header bar carries those buttons instead), and a change hook the
    /// host uses to keep its title in sync. All null/unused for a pane
    /// face, which keeps the pane path exactly as it was.
    /// Language-server client, created lazily the first time a document
    /// with a servable language is opened. Null costs nothing, so an
    /// editor face that only ever shows plain text never builds one.
    lsp: ?*editorlsp.Manager = null,
    /// The rename dialog's entry while it is up (its response callback
    /// has to read the text back out). Owned by the dialog.
    rename_entry: ?*c.GtkWidget = null,

    standalone_config: ?*const Config = null,
    toolbar_box: ?*c.GtkWidget = null,
    /// The toolbar's "leave the editor" button. Its icon and tooltip
    /// follow the pane's recorded previous face, so a pane converted
    /// from the file browser says so instead of promising a shell.
    /// Borrowed: owned by the toolbar box.
    back_button: ?*c.GtkWidget = null,
    on_changed: ?*const fn (ctx: *anyopaque) void = null,
    changed_ctx: ?*anyopaque = null,

    // ---- attach / teardown ------------------------------------------

    /// Create an editor face on `pane` (browser precedent). A pane
    /// already wearing one gains a document tab instead.
    pub fn attach(allocator: std.mem.Allocator, pane: *Pane, spec: ?[]const u8) !*EditorView {
        if (fromPane(pane)) |existing| {
            if (spec) |s| existing.openSpec(s, null);
            pane.setEditorVisible(true);
            return existing;
        }
        const self = try allocator.create(EditorView);
        self.* = .{ .allocator = allocator, .pass = EditorPass.init(allocator) };
        errdefer allocator.destroy(self);
        self.projects = project_mod.Set.init(allocator);
        self.results = psearch.Results.init(allocator);
        self.fence = Fence.create(self) orelse return error.OutOfMemory;
        self.pane = pane;
        self.font_size = pane.surface.font_size;
        self.line_pad = pane.surface.line_pad_px;
        if (pane.surface.font_path) |fp| self.font_path = allocator.dupe(u8, fp) catch null;
        if (pane.surface.font_family) |ff| self.font_family = allocator.dupe(u8, ff) catch null;

        self.buildUi();
        pane.attachEditor(self.root_box, @ptrCast(self), prepareDestroyCb, destroyCb, focusCb);
        // The face is in the widget tree now, so ownerWindow() (and
        // therefore the config) resolves.
        self.syncConfig();
        self.startBlink();
        if (spec) |s| self.openSpec(s, null) else _ = self.newTab(null);
        self.offerRecovery();
        return self;
    }

    /// Re-read every editor setting from the window config into our
    /// OWNED copies. Safe to call at any time (and required after
    /// applyConfigChange, which frees the arena those slices lived in
    /// — Window.applyConfigChange calls it for every editor face).
    pub fn syncConfig(self: *EditorView) void {
        const cfg: *const Config = if (self.ownerWindow()) |win|
            &win.config
        else
            self.standalone_config orelse return;
        self.tab_width = @max(1, cfg.editor_tab_width);
        self.insert_spaces = cfg.editor_insert_spaces;
        self.soft_wrap_default = cfg.editor_soft_wrap;
        if (self.wrap_words != cfg.editor_wrap_words) {
            self.wrap_words = cfg.editor_wrap_words;
            // Break positions move: every cached layout and row
            // estimate is stale (same contract as a wrap-width change).
            for (self.tabs.items) |t| {
                t.layout.wrap_words = self.wrap_words;
                t.layout.invalidateAll();
                t.rows_lines = 0;
            }
            if (self.tabs.items.len > 0) self.queueRender();
        }
        self.line_numbers = cfg.editor_line_numbers;
        self.highlight_current_line = cfg.editor_highlight_current_line;
        self.syntax_on = cfg.editor_syntax;
        self.bracket_match = cfg.editor_bracket_match;
        self.folding = cfg.editor_folding;
        self.fold_indent_fallback = cfg.editor_fold_indent_fallback;
        self.crash_recovery = cfg.editor_crash_recovery;
        self.auto_indent = cfg.editor_auto_indent;
        self.auto_close = cfg.editor_auto_close_pairs;
        self.smart_backspace = cfg.editor_smart_backspace;
        self.rebuildEdBindings(cfg);
        self.text_blending = switch (cfg.text_blending) {
            .native => .native,
            .linear => .linear,
            .linear_corrected => .linear_corrected,
        };
        self.git_gutter = cfg.editor_git_gutter;
        self.outline_default = cfg.editor_outline;
        self.search_max_files = @max(1, cfg.editor_project_search_max_files);
        // OWNED: the config arena this slice lives in is freed under us
        // by applyConfigChange, and project.Set borrows the list.
        if (self.project_markers) |old| self.allocator.free(old);
        self.project_markers = if (cfg.editor_project_markers.len > 0)
            self.allocator.dupe(u8, cfg.editor_project_markers) catch null
        else
            null;
        self.projects.markers = self.project_markers orelse "";
        self.theme = theme_mod.byName(cfg.editor_theme);
        self.applyThemeColors();

        // Font: the editor keys win, else this profile's terminal font.
        const pane = self.pane;
        const prof = if (pane) |p| p.active_profile orelse "" else "";
        const s = cfg.profileSettings(prof);
        const want_family: []const u8 = if (s.editor_font_family.len > 0)
            s.editor_font_family
        else
            s.font_family;
        const want_size: u16 = if (s.editor_font_size > 0) s.editor_font_size else s.font_size;
        // An explicit editor family overrides the profile font FILE
        // (a path pointing at a monospace terminal font must not win
        // over "use Cantarell in the editor").
        const drop_path = s.editor_font_family.len > 0;

        var font_changed = false;
        if (want_size != self.font_size) {
            self.font_size = want_size;
            font_changed = true;
        }
        const have_family: []const u8 = self.font_family orelse "";
        if (!std.mem.eql(u8, have_family, want_family)) {
            if (self.font_family) |old| self.allocator.free(old);
            self.font_family = if (want_family.len > 0)
                self.allocator.dupe(u8, want_family) catch null
            else
                null;
            font_changed = true;
        }
        if (drop_path and self.font_path != null) {
            self.allocator.free(self.font_path.?);
            self.font_path = null;
            font_changed = true;
        }
        if (font_changed) self.rebuildAtlas();

        for (self.tabs.items) |t| {
            t.layout.tab_cols = self.tab_width;
            t.layout.theme = self.theme;
            // Language/on-off may have changed with the config; this
            // also re-invalidates the layout cache.
            self.ensureHighlighter(t);
            t.layout.invalidateAll();
            self.applyWrapWidth(t);
        }
        // LSP: switching it off tears every server down; switching it
        // on (or changing a [lsp.*] section) re-attaches every tab, so
        // a config change lands without restarting the editor.
        if (!cfg.editor_lsp) {
            if (self.lsp) |m| {
                m.destroy();
                self.lsp = null;
                for (self.tabs.items) |t| t.lsp = null;
            }
        } else {
            for (self.tabs.items) |t| self.attachLsp(t);
        }
        if (self.outline_default and !self.outline_open) editoroutline.setOpen(self, true);
        if (!self.git_gutter) {
            for (self.tabs.items) |t| t.git.clear();
        } else if (self.active) |t| editorproj.refreshGit(self, t);
        self.queueRender();
    }

    /// Project the theme onto the pass's chrome colours. The per-glyph
    /// foreground comes from the theme directly (Frame.theme); these
    /// are the things the pass paints AROUND the text.
    fn applyThemeColors(self: *EditorView) void {
        const t = self.theme;
        self.colors = .{
            .text = t.fg,
            .selection = t.selection,
            .caret = t.caret,
            .gutter_bg = t.gutter_bg,
            .gutter_fg = t.gutter_fg,
            .current_line = t.current_line,
            .match = t.match,
            .match_current = t.match_current,
            .preedit_bg = t.preedit_bg,
        };
    }

    // ---- syntax highlighting -------------------------------------------

    /// Language for `tab`: filename first, then a shebang read out of
    /// the document head. Null = plain text (also when highlighting is
    /// switched off).
    fn detectLang(self: *EditorView, tab: *ETab) ?syntax.Lang {
        if (!self.syntax_on) return null;
        var buf: [SHEBANG_PROBE]u8 = undefined;
        var head: []const u8 = "";
        const n = @min(buf.len, tab.doc.rope.len());
        if (n > 0) {
            var it = tab.doc.rope.iterateRange(0, n);
            var w: usize = 0;
            while (it.next()) |chunk| {
                @memcpy(buf[w .. w + chunk.len], chunk);
                w += chunk.len;
            }
            head = buf[0..w];
            if (std.mem.indexOfScalar(u8, head, '\n')) |nl| head = head[0..nl];
        }
        return syntax.detect(tab.spec, head);
    }

    fn dropHighlighter(self: *EditorView, tab: *ETab) void {
        tab.layout.hl = null;
        if (tab.hl) |hl| {
            tab.doc.removeObserver(@ptrCast(hl));
            hl.deinit();
            self.allocator.destroy(hl);
        }
        tab.hl = null;
        tab.hl_lang = null;
    }

    /// Bring `tab`'s highlighter in line with its spec, its content and
    /// the config. Call after anything that changes the language, the
    /// document IDENTITY (a load replaces `tab.doc` wholesale, which
    /// drops the observer with it) or the `editor_syntax` setting.
    fn ensureHighlighter(self: *EditorView, tab: *ETab) void {
        const want = self.detectLang(tab);
        if (want == null) {
            if (tab.hl != null) {
                self.dropHighlighter(tab);
                tab.layout.invalidateAll();
            }
            return;
        }
        if (tab.hl == null or tab.hl_lang.? != want.?) {
            self.dropHighlighter(tab);
            const hl = self.allocator.create(syntax.Highlighter) catch return;
            hl.* = syntax.Highlighter.init(self.allocator, want.?) catch {
                self.allocator.destroy(hl);
                return;
            };
            tab.hl = hl;
            tab.hl_lang = want;
        } else {
            // Same language, new (or reloaded) text: no incremental
            // relationship to the old tree.
            tab.hl.?.reset();
        }
        tab.hl.?.attach(&tab.doc);
        tab.layout.hl = tab.hl;
        tab.layout.theme = self.theme;
        tab.layout.invalidateAll();
        self.scheduleParse(tab);
    }

    /// Re-parse now for a small document, or at most once per
    /// `PARSE_DEBOUNCE_MS` for a big one. Never a worker thread: the
    /// GUI is single-threaded (CLAUDE.md), and a stale highlighter is
    /// a supported state — the affected lines simply render
    /// unhighlighted until the parse lands.
    fn scheduleParse(self: *EditorView, tab: *ETab) void {
        const hl = tab.hl orelse return;
        if (!hl.isStale(&tab.doc)) return;
        if (tab.doc.rope.len() <= SYNC_PARSE_LIMIT) {
            hl.parse(&tab.doc) catch {};
            return;
        }
        if (tab.parse_timer != 0) return;
        const ctx = DlgCtx.create(self, tab) orelse return;
        tab.parse_timer = c.g_timeout_add(PARSE_DEBOUNCE_MS, @ptrCast(&onParseTimer), @ptrCast(ctx));
    }

    fn onParseTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const ctx: *DlgCtx = @ptrCast(@alignCast(user.?));
        defer ctx.destroy();
        if (ctx.resolve()) |r| {
            r.tab.parse_timer = 0;
            if (r.tab.hl) |hl| {
                hl.parse(&r.tab.doc) catch {};
                r.view.queueRender();
            }
        }
        return 0; // G_SOURCE_REMOVE
    }

    // ---- structure: brackets, folds, expand-selection -----------------
    //
    // Everything here is derived from the SAME tree-sitter trees the
    // highlighting uses (editor/syntax.zig grew the queries; there is
    // no second parser). The documented fallbacks in
    // editor/structure.zig — a depth-counting bracket scanner and
    // indentation-derived fold regions — are consulted ONLY when there
    // is no usable tree, i.e. no grammar for the file type or
    // `editor_syntax = false`. A tree that merely LAGS the document is
    // not a fallback trigger for folds (the last known regions stand
    // until the parse lands) but IS one for brackets, where a wrong box
    // for one frame is cheaper than none.

    /// Carets past this many stop getting bracket boxes. A thousand
    /// carets times two tree descents per frame is not worth it, and
    /// nobody can read that many highlights anyway.
    const MAX_BRACKET_CARETS: usize = 64;

    /// Hash of every selection's endpoints — the third key (after
    /// revision and highlighter generation) the bracket cache needs,
    /// because moving a caret changes the answer without touching
    /// either of the other two.
    fn caretHash(sels: *const SelectionSet) u64 {
        var h = std.hash.Wyhash.init(0);
        for (sels.sels.items) |s| {
            h.update(std.mem.asBytes(&s.anchor));
            h.update(std.mem.asBytes(&s.head));
        }
        return h.final();
    }

    fn hlGen(tab: *ETab) u64 {
        return if (tab.hl) |h| h.gen else 0;
    }

    /// Gutter width for this tab, with the SAME flags the render pass
    /// uses. Hit testing and the wrap width both go through here so
    /// they cannot drift from what was drawn.
    fn gutterWidthOf(self: *EditorView, tab: *ETab) f32 {
        const atlas = self.atlas orelse return 0;
        return EditorPass.gutterWidth(
            atlas,
            tab.doc.rope.lineCount(),
            self.line_numbers,
            self.folding,
        ) catch 0;
    }

    /// Width of the line-number field alone (the fold column sits to
    /// its right).
    fn numberFieldWidth(self: *EditorView, tab: *ETab) f32 {
        const w = self.gutterWidthOf(tab);
        return if (self.folding) @max(0, w - EditorPass.FOLD_COL_W) else w;
    }

    // ---- folds ---------------------------------------------------------

    /// The foldable region headed by `line`: from the tree when one is
    /// current, from indentation otherwise.
    fn foldRegionAtLine(self: *EditorView, tab: *ETab, line: usize) ?structure.FoldRegion {
        if (tab.hl) |hl| {
            if (!hl.isStale(&tab.doc)) return hl.foldRegionAtLine(&tab.doc, line) catch null;
            return null;
        }
        if (!self.fold_indent_fallback) return null;
        return structure.indentRegionAt(&tab.doc, line, self.tab_width);
    }

    /// The innermost region CONTAINING `offset` whose header is another
    /// line — "fold the block I am inside".
    fn foldRegionEnclosing(self: *EditorView, tab: *ETab, offset: usize) ?structure.FoldRegion {
        if (tab.hl) |hl| {
            if (!hl.isStale(&tab.doc)) return hl.foldRegionEnclosing(&tab.doc, offset) catch null;
            return null;
        }
        if (!self.fold_indent_fallback) return null;
        // Indentation fallback: walk up looking for a shallower header.
        const line = tab.doc.rope.offsetToLineCol(offset).line;
        var l = line;
        while (l > 0) {
            l -= 1;
            const r = structure.indentRegionAt(&tab.doc, l, self.tab_width) orelse continue;
            if (r.hides(line)) return r;
        }
        return null;
    }

    const FoldCtx = struct {
        view: *EditorView,
        tab: *ETab,

        fn atLine(ctx: ?*anyopaque, line: usize) ?structure.FoldRegion {
            const self: *FoldCtx = @ptrCast(@alignCast(ctx.?));
            return self.view.foldRegionAtLine(self.tab, line);
        }
    };

    /// Re-derive every fold's region from its (already mapped) anchor.
    ///
    /// Deliberately SKIPPED while a highlighted document's tree lags:
    /// resolving against the indentation fallback there would quietly
    /// replace tree-derived regions with indentation ones. The last
    /// known regions stand until the re-parse lands, which for anything
    /// under SYNC_PARSE_LIMIT is the same turn of the main loop.
    fn syncFolds(self: *EditorView, tab: *ETab) void {
        if (tab.folds.isEmpty()) return;
        var gen: u64 = 0;
        if (tab.hl) |hl| {
            if (hl.isStale(&tab.doc)) return;
            gen = hl.gen;
        }
        if (tab.folds_valid and tab.folds_rev == tab.doc.revision and tab.folds_gen == gen) return;
        const before = self.foldSignature(tab);
        var ctx = FoldCtx{ .view = self, .tab = tab };
        tab.folds.resolve(&tab.doc, .{ .ctx = &ctx, .at_line = FoldCtx.atLine }) catch {};
        tab.folds_rev = tab.doc.revision;
        tab.folds_gen = gen;
        tab.folds_valid = true;
        if (self.foldSignature(tab) != before) {
            tab.folds_epoch += 1;
            tab.fm_valid = false;
            self.ensureRows(tab);
        }
    }

    /// Cheap identity of the HIDDEN set — only a real change may bump
    /// the epoch, or every parse would rebuild the row index.
    fn foldSignature(self: *EditorView, tab: *ETab) u64 {
        _ = self;
        var h = std.hash.Wyhash.init(0xF01D);
        for (tab.folds.hidden.items) |sp| {
            h.update(std.mem.asBytes(&sp.start_line));
            h.update(std.mem.asBytes(&sp.end_line));
        }
        return h.final();
    }

    /// First and last line the next frame will draw, folds accounted
    /// for. O(viewport).
    fn visibleLineSpan(self: *EditorView, tab: *ETab) struct { from: usize, to: usize } {
        const n = tab.doc.rope.lineCount();
        if (n == 0) return .{ .from = 0, .to = 0 };
        var li = tab.folds.nextVisible(@min(tab.anchor.line, n - 1));
        if (li >= n) li = tab.folds.prevVisible(n - 1);
        const from = li;
        var rows_left: isize = @intCast(self.viewportRows() + 1);
        while (li + 1 < n and rows_left > 0) {
            rows_left -= @max(1, @as(isize, tab.rows.rowsOf(li)));
            const next = tab.folds.nextVisible(li + 1);
            if (next >= n) break;
            li = next;
        }
        return .{ .from = from, .to = @min(li, n - 1) };
    }

    /// Gutter fold affordances for [from, to]. Cached on (revision,
    /// highlighter gen, fold epoch, line range) so scrolling one row
    /// recomputes and sitting still does not.
    fn ensureFoldMarkers(self: *EditorView, tab: *ETab, from: usize, to: usize) void {
        if (!self.folding) {
            tab.fold_markers.clearRetainingCapacity();
            return;
        }
        const gen = hlGen(tab);
        if (tab.fm_valid and tab.fm_rev == tab.doc.revision and tab.fm_gen == gen and
            tab.fm_epoch == tab.folds_epoch and tab.fm_from == from and tab.fm_to == to) return;
        tab.fm_rev = tab.doc.revision;
        tab.fm_gen = gen;
        tab.fm_epoch = tab.folds_epoch;
        tab.fm_from = from;
        tab.fm_to = to;
        tab.fm_valid = true;
        tab.fold_markers.clearRetainingCapacity();

        const n = tab.doc.rope.lineCount();
        if (n == 0) return;
        const b0 = tab.doc.rope.lineToOffset(from);
        const b1 = if (to + 1 < n) tab.doc.rope.lineToOffset(to + 1) else tab.doc.rope.len();

        var regions: []structure.FoldRegion = &.{};
        var owned = false;
        if (tab.hl) |hl| {
            if (!hl.isStale(&tab.doc)) {
                if (hl.foldRegionsIn(self.allocator, &tab.doc, b0, b1)) |r| {
                    regions = r;
                    owned = true;
                } else |_| {}
            }
        } else if (self.fold_indent_fallback) {
            if (structure.indentRegions(self.allocator, &tab.doc, from, to, self.tab_width)) |r| {
                regions = r;
                owned = true;
            } else |_| {}
        }
        defer if (owned) self.allocator.free(regions);

        for (regions) |r| {
            if (r.start_line < from or r.start_line > to) continue;
            tab.fold_markers.append(self.allocator, .{
                .line = r.start_line,
                .folded = tab.folds.entryAtLine(r.start_line) != null,
            }) catch return;
        }
    }

    /// Bookkeeping every fold mutation shares: bump the epoch (which is
    /// what makes `ensureRows` re-stamp the row index), pull the anchor
    /// off a line that just became hidden, repaint.
    fn noteFoldChange(self: *EditorView, tab: *ETab) void {
        tab.folds_epoch += 1;
        tab.fm_valid = false;
        tab.folds_valid = false;
        self.ensureRows(tab);
        if (tab.folds.isHidden(tab.anchor.line)) {
            tab.anchor = .{ .line = tab.folds.prevVisible(tab.anchor.line), .row = 0, .offset = 0 };
        }
        self.clampAnchor(tab, self.viewportHeightPx());
        self.updateStatus();
        self.queueRender();
    }

    /// Move any caret that just went behind a fold to the end of the
    /// header line — a caret you cannot see is worse than a caret that
    /// moved.
    fn pullCaretsOutOfFolds(self: *EditorView, tab: *ETab) void {
        _ = self;
        if (tab.folds.isEmpty()) return;
        for (tab.sels.sels.items) |*s| {
            const lh = tab.doc.rope.offsetToLineCol(s.head).line;
            if (tab.folds.isHidden(lh)) {
                const header = tab.folds.prevVisible(lh);
                s.head = vm.lineBoundsAt(&tab.doc, tab.doc.rope.lineToOffset(header)).end;
            }
            const la = tab.doc.rope.offsetToLineCol(s.anchor).line;
            if (tab.folds.isHidden(la)) {
                const header = tab.folds.prevVisible(la);
                s.anchor = vm.lineBoundsAt(&tab.doc, tab.doc.rope.lineToOffset(header)).end;
            }
        }
        tab.sels.normalize();
    }

    /// Unfold whatever hides a caret. Called after every ordinary move,
    /// so walking Right off the end of a folded header opens it rather
    /// than teleporting the caret into invisible text. (Up/Down never
    /// need it: `stepVisualRow` steps over folds.)
    fn revealCaretLines(self: *EditorView, tab: *ETab) void {
        if (tab.folds.isEmpty()) return;
        var changed = false;
        for (tab.sels.sels.items) |s| {
            const l = tab.doc.rope.offsetToLineCol(s.head).line;
            if (!tab.folds.isHidden(l)) continue;
            changed = (tab.folds.revealLine(l) catch false) or changed;
        }
        if (changed) self.noteFoldChange(tab);
    }

    fn applyFold(self: *EditorView, tab: *ETab, region: structure.FoldRegion) void {
        const anchor = structure.firstNonBlankOffset(&tab.doc, region.start_line);
        tab.folds.fold(anchor, region) catch return;
        tab.folds_valid = true;
        tab.folds_rev = tab.doc.revision;
        tab.folds_gen = hlGen(tab);
        self.pullCaretsOutOfFolds(tab);
        self.noteFoldChange(tab);
    }

    /// Fold the region headed by the caret's line, or the innermost one
    /// containing it.
    pub fn foldAtCaret(self: *EditorView, tab: *ETab) void {
        if (!self.folding) return;
        self.syncFolds(tab);
        const head = tab.sels.primary().head;
        const line = tab.doc.rope.offsetToLineCol(head).line;
        const region = self.foldRegionAtLine(tab, line) orelse
            self.foldRegionEnclosing(tab, head) orelse return;
        self.applyFold(tab, region);
    }

    /// Unfold the region headed by the caret's line, else whichever one
    /// hides it.
    pub fn unfoldAtCaret(self: *EditorView, tab: *ETab) void {
        if (!self.folding) return;
        const head = tab.sels.primary().head;
        const line = tab.doc.rope.offsetToLineCol(head).line;
        var changed = tab.folds.unfoldAtLine(line) catch false;
        if (!changed) changed = (tab.folds.unfoldCovering(line) catch null) != null;
        if (!changed) return;
        self.noteFoldChange(tab);
    }

    /// Toggle the fold headed by `line` (the gutter chevron's action).
    pub fn toggleFoldLine(self: *EditorView, tab: *ETab, line: usize) void {
        if (!self.folding) return;
        self.syncFolds(tab);
        if (tab.folds.entryAtLine(line) != null) {
            _ = tab.folds.unfoldAtLine(line) catch {};
            self.noteFoldChange(tab);
            return;
        }
        const region = self.foldRegionAtLine(tab, line) orelse return;
        self.applyFold(tab, region);
    }

    pub fn foldAll(self: *EditorView, tab: *ETab) void {
        if (!self.folding) return;
        const n = tab.doc.rope.lineCount();
        if (n == 0) return;
        var regions: []structure.FoldRegion = &.{};
        var owned = false;
        if (tab.hl) |hl| {
            if (hl.isStale(&tab.doc)) hl.parse(&tab.doc) catch {};
            if (hl.foldRegionsIn(self.allocator, &tab.doc, 0, tab.doc.rope.len())) |r| {
                regions = r;
                owned = true;
            } else |_| {}
        } else if (self.fold_indent_fallback) {
            if (structure.indentRegions(self.allocator, &tab.doc, 0, n - 1, self.tab_width)) |r| {
                regions = r;
                owned = true;
            } else |_| {}
        }
        defer if (owned) self.allocator.free(regions);
        if (regions.len == 0) return;
        for (regions) |r| {
            tab.folds.fold(structure.firstNonBlankOffset(&tab.doc, r.start_line), r) catch break;
        }
        tab.folds_valid = true;
        tab.folds_rev = tab.doc.revision;
        tab.folds_gen = hlGen(tab);
        self.pullCaretsOutOfFolds(tab);
        self.noteFoldChange(tab);
    }

    pub fn unfoldAll(self: *EditorView, tab: *ETab) void {
        if (tab.folds.isEmpty()) return;
        tab.folds.clear();
        self.noteFoldChange(tab);
    }

    // ---- brackets ------------------------------------------------------

    /// The pair around/adjacent to `offset`. The TREE is the primary
    /// source and its "no pair" answer is final — that is what keeps a
    /// bracket inside a string or a comment from matching. The scanner
    /// runs only when there is no tree at all.
    fn bracketPairAt(self: *EditorView, tab: *ETab, offset: usize) ?structure.BracketPair {
        _ = self;
        if (tab.hl) |hl| {
            if (!hl.isStale(&tab.doc)) return hl.bracketAt(&tab.doc, offset) catch null;
        }
        return structure.scanMatch(&tab.doc.rope, offset);
    }

    fn ensureBrackets(self: *EditorView, tab: *ETab) void {
        if (!self.bracket_match) {
            tab.brackets.clearRetainingCapacity();
            return;
        }
        const gen = hlGen(tab);
        const carets = caretHash(&tab.sels);
        if (tab.br_valid and tab.br_rev == tab.doc.revision and
            tab.br_gen == gen and tab.br_carets == carets) return;
        tab.br_rev = tab.doc.revision;
        tab.br_gen = gen;
        tab.br_carets = carets;
        tab.br_valid = true;
        tab.brackets.clearRetainingCapacity();
        for (tab.sels.sels.items, 0..) |sel, i| {
            if (i >= MAX_BRACKET_CARETS) break;
            const pair = self.bracketPairAt(tab, sel.head) orelse continue;
            tab.brackets.append(self.allocator, pair.open) catch return;
            tab.brackets.append(self.allocator, pair.close) catch return;
        }
    }

    /// Jump every caret to the other half of its bracket pair.
    pub fn gotoMatchingBracket(self: *EditorView, tab: *ETab, extend: bool) void {
        var moved = false;
        for (tab.sels.sels.items) |*s| {
            const pair = self.bracketPairAt(tab, s.head) orelse continue;
            const at_open = s.head <= pair.open.end;
            const target = if (at_open) pair.close.start else pair.open.start;
            s.head = target;
            if (!extend) s.anchor = target;
            moved = true;
        }
        if (!moved) {
            self.setStatus("No matching bracket.");
            return;
        }
        tab.sels.normalize();
        tab.goal_x = null;
        self.afterMove(tab);
    }

    // ---- structural selection ------------------------------------------

    /// Grow every selection to its smallest strictly-enclosing syntax
    /// node, remembering the previous set so `shrinkSelection` retraces
    /// it exactly.
    pub fn expandSelection(self: *EditorView, tab: *ETab) void {
        const hl = tab.hl orelse {
            self.setStatus("No syntax tree for this file.");
            return;
        };
        if (hl.isStale(&tab.doc)) hl.parse(&tab.doc) catch return;
        tab.sel_stack.syncRevision(tab.doc.revision);
        tab.sel_stack.push(&tab.sels) catch return;
        var any = false;
        for (tab.sels.sels.items) |*s| {
            const r = (hl.expandRange(&tab.doc, s.start(), s.end()) catch null) orelse continue;
            const reversed = s.anchor > s.head;
            s.anchor = if (reversed) r.end else r.start;
            s.head = if (reversed) r.start else r.end;
            any = true;
        }
        if (!any) {
            tab.sel_stack.dropTop();
            return;
        }
        tab.sels.normalize();
        tab.structural_move = true;
        defer tab.structural_move = false;
        self.afterMove(tab);
    }

    /// Undo one expand step. Nothing to do when the trail is empty —
    /// shrink never GUESSES a smaller node, because with several carets
    /// re-derivation and the recorded set are not the same thing.
    pub fn shrinkSelection(self: *EditorView, tab: *ETab) void {
        tab.sel_stack.syncRevision(tab.doc.revision);
        const ok = tab.sel_stack.pop(&tab.sels) catch false;
        if (!ok) return;
        tab.structural_move = true;
        defer tab.structural_move = false;
        self.afterMove(tab);
    }

    /// Rebuild the atlas against the current font inputs under the
    /// GLArea's context (same discipline as onRealize).
    fn rebuildAtlas(self: *EditorView) void {
        if (self.widgets_dead) return;
        if (c.gtk_widget_get_realized(@ptrCast(self.area)) == 0) return;
        c.gtk_gl_area_make_current(self.area);
        if (c.gtk_gl_area_get_error(self.area) != null) return;
        if (self.atlas) |old| {
            old.deinit();
            self.atlas = null;
        }
        self.atlas = self.createAtlas() orelse return;
        self.atlas.?.realize();
        self.book = FontBook.init(self.atlas.?);
        for (self.tabs.items) |t| {
            t.layout.invalidateAll();
            t.rows_lines = 0; // row heights changed: re-estimate
        }
    }

    /// Restore an editor face from persisted layout state.
    pub fn attachState(allocator: std.mem.Allocator, pane: *Pane, state: editor_model.PaneState) !*EditorView {
        const self = try attach(allocator, pane, null);
        // attach() opened a fresh Untitled tab; replace it with the
        // saved set when there is one.
        if (state.files.len > 0) {
            const placeholder = self.active;
            for (state.files) |f| self.openSpecRestored(
                f.spec,
                @intCast(f.cursor),
                if (f.top_line > 0) @intCast(f.top_line) else null,
                f.project,
            );
            if (placeholder) |ph| {
                if (!ph.isDirty() and ph.spec == null and self.tabs.items.len > 1)
                    self.closeTabForce(ph);
            }
            const idx = @min(state.active, state.files.len -| 1);
            // Tabs were appended in file order after any placeholder.
            var seen: u64 = 0;
            for (self.tabs.items) |t| {
                if (t.spec == null) continue;
                if (seen == idx) {
                    self.tabhost.setCurrentPage(t.page);
                    break;
                }
                seen += 1;
            }
        }
        return self;
    }

    /// A PANELESS editor face for the standalone Sketerm Editor window
    /// (ui/editorwin.zig), the same shape BrowserView.attachForPicker
    /// has: identical widgets and IO, no pane coupling. `cfg` must
    /// outlive the view (the host window owns it); the caller parents
    /// `root_box`, and owns teardown — destroy the widget tree, then
    /// deinit() once the destroy has unwound.
    pub fn attachStandalone(allocator: std.mem.Allocator, cfg: *const Config) !*EditorView {
        const self = try allocator.create(EditorView);
        self.* = .{ .allocator = allocator, .pass = EditorPass.init(allocator) };
        errdefer allocator.destroy(self);
        self.projects = project_mod.Set.init(allocator);
        self.results = psearch.Results.init(allocator);
        self.fence = Fence.create(self) orelse return error.OutOfMemory;
        self.standalone_config = cfg;
        self.buildUi();
        // The window's header bar carries Open / Save / Save As, and
        // "show this pane's shell" means nothing with no pane.
        if (self.toolbar_box) |bar| c.gtk_widget_set_visible(bar, 0);
        self.syncConfig();
        self.startBlink();
        self.offerRecovery();
        return self;
    }

    /// Move the caret to 1-based `line` / `col` (BYTE column, clamped
    /// to the line) and reveal it. The standalone `--line N[:col]`
    /// entry point; the host applies it once the async load has landed.
    pub fn gotoLineCol(self: *EditorView, tab: *ETab, line: usize, col: usize) void {
        const lines = tab.doc.rope.lineCount();
        const target_line = @min(line -| 1, lines -| 1);
        const start = tab.doc.rope.lineToOffset(target_line);
        const line_end = if (target_line + 1 < lines)
            tab.doc.rope.lineToOffset(target_line + 1) -| 1
        else
            tab.doc.rope.len();
        const off = @min(start + (col -| 1), line_end);
        tab.sels.keepPrimaryOnly();
        if (tab.sels.sels.items.len == 0) {
            tab.sels.sels.append(self.allocator, Selection.caret(off)) catch return;
        } else tab.sels.sels.items[0] = Selection.caret(off);
        tab.goal_x = null;
        // Jumping to a line inside a folded region opens it — a goto
        // that leaves the caret invisible is a bug, not a feature.
        self.revealCaretLines(tab);
        self.refresh(tab);
    }

    /// The EditorView riding `pane`, if any.
    pub fn fromPane(pane: *Pane) ?*EditorView {
        const ctx = pane.editor_ctx orelse return null;
        return @ptrCast(@alignCast(ctx));
    }

    fn destroyCb(ctx: *anyopaque) void {
        const self: *EditorView = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    /// Phase 1 of the pane's two-phase teardown (`Pane.severFaces`).
    ///
    /// `widgets_dead` is the pane telling us whether our widget subtree
    /// is still up. It is TRUE only on the last-resort sever from the
    /// deferred `Pane.deinit`; the ordinary paths sever while the tree
    /// is alive, which is the only time the AdwTabView shortcut restore
    /// below can (or may) run — `ownerWindow()` walks `root_box`.
    fn prepareDestroyCb(ctx: *anyopaque, widgets_dead: bool) void {
        const self: *EditorView = @ptrCast(@alignCast(ctx));
        // Before anything else: drop the AT-SPI bridge's back-pointer
        // into this face and cancel its coalescing timer, while the
        // GL area is still a live widget. Idempotent, and the area's
        // own ::destroy severs again on the paths that skip this one.
        if (!self.widgets_dead and !widgets_dead) a11y.sever(@ptrCast(self.area));
        self.widgets_dead = self.widgets_dead or widgets_dead;
        // No-ops itself (through ownerWindow) once widgets_dead is set,
        // which is why the pane's verdict has to be folded in first and
        // our own unconditional `= true` comes after.
        self.suppressTabViewEdgeKeys(false);
        self.widgets_dead = true;
        self.stopBlink();
        self.stopScrollbarSync();
        self.stopJournalTimer();
        self.detachIm();
        // LSP popovers are parented to the GLArea with
        // gtk_widget_set_parent and MUST be unparented before it
        // finalizes (menu.zig documents the same rule).
        if (self.lsp) |m| m.unparentPopups();
    }

    /// The GLArea can die without detachEditor running (whole-window
    /// teardown). Nothing here has to beat the widget's finalize any
    /// more — ImHost owns a reference to its client widget, so a
    /// detach from `deinit` is just as safe — but severing at the
    /// first sign of teardown still keeps the IM from delivering
    /// commits into a face that is on its way out.
    fn onAreaDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        self.widgets_dead = true;
        self.stopBlink();
        self.stopScrollbarSync();
        self.stopJournalTimer();
        self.stopNoteExpiry();
        self.detachIm();
    }

    fn focusCb(ctx: *anyopaque) void {
        const self: *EditorView = @ptrCast(@alignCast(ctx));
        self.focusFace();
    }

    /// Focus the document canvas (pane focus, IPC `focus`). Probes the
    /// disk directly rather than waiting for the GTK focus signal,
    /// which a headless/unfocused toplevel may never deliver.
    pub fn focusFace(self: *EditorView) void {
        if (self.widgets_dead) return;
        // Raising the face re-asserts its title on the pane titlebar
        // (the flip cleared whatever the previous face had put there).
        self.applyPaneFaceTitle();
        self.syncBackButton();
        _ = c.gtk_widget_grab_focus(@ptrCast(self.area));
        self.checkDisk();
    }

    /// Name the back button after where it actually goes. The pane
    /// calls our focus callback every time it raises this face, which
    /// is exactly when the recorded previous face can have changed.
    fn syncBackButton(self: *EditorView) void {
        const btn = self.back_button orelse return;
        const pane = self.pane orelse return;
        if (pane.editorReturnsToBrowser()) {
            toolbtn.setIcon(btn, btn, "folder-symbolic", "Files");
            c.gtk_widget_set_tooltip_text(btn, "Back to the file browser");
        } else {
            toolbtn.setIcon(btn, btn, "sketerm-terminal-symbolic", "Shell");
            c.gtk_widget_set_tooltip_text(btn, "Show this pane's shell");
        }
    }

    pub fn deinit(self: *EditorView) void {
        self.fence.close();
        // Last resort — every ordinary path severed already (either
        // `prepareDestroyCb` or the area's ::destroy). Only safe while
        // the widget is alive; once it is finalized its own destroy
        // handler has run and `self.area` dangles.
        if (!self.widgets_dead) a11y.sever(@ptrCast(self.area));
        self.a11y_src.deinit();
        self.stopBlink();
        self.stopScrollbarSync();
        self.stopJournalTimer();
        self.stopNoteExpiry();
        self.dropRecovery();
        self.clearPreedit();
        self.detachIm();
        // Before the tabs: the manager owns each tab's TabState and
        // tells every server its documents are closing.
        if (self.lsp) |m| {
            m.destroy();
            self.lsp = null;
        }
        for (self.tabs.items) |t| t.destroy();
        self.tabs.deinit(self.allocator);
        // After the tabs: each one releases its project reference.
        self.projects.deinit();
        self.results.deinit();
        if (self.project_markers) |m| self.allocator.free(m);
        if (self.atlas) |a| {
            a.deinit();
            self.atlas = null;
        }
        self.ed_bindings.deinit(self.allocator);
        self.pass.deinit();
        if (self.font_path) |s| self.allocator.free(s);
        if (self.font_family) |s| self.allocator.free(s);
        self.allocator.destroy(self);
    }

    /// Same reasoning as Pane.detachIm: the IM context is not owned
    /// by the widget tree, so it must be severed before/at teardown.
    fn detachIm(self: *EditorView) void {
        const im = self.im orelse return;
        self.im = null;
        im.deinit();
    }

    /// The Window whose widget tree hosts this face.
    pub fn ownerWindow(self: *EditorView) ?*@import("window.zig").Window {
        if (self.widgets_dead) return null;
        const root = c.gtk_widget_get_root(self.root_box) orelse return null;
        return @import("remotectl.zig").windowFromGtk(@ptrCast(@alignCast(root)));
    }

    /// Unsaved tabs (window-close veto + reporting).
    pub fn dirtyCount(self: *EditorView) usize {
        var n: usize = 0;
        for (self.tabs.items) |t| {
            if (t.isDirty()) n += 1;
        }
        return n;
    }

    // ---- UI construction --------------------------------------------

    fn buildUi(self: *EditorView) void {
        const vbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(vbox, 1);
        c.gtk_widget_set_vexpand(vbox, 1);

        // Toolbar: open/save/save-as on the left, the way back to the
        // shell on the right. Flat icon buttons, browser-toolbar style.
        const bar = toolbtn.newBar();
        toolbtn.installCss(bar);
        _ = self.barButton(bar, "document-open-symbolic", "Open", "Open a file (Ctrl+O)", &onOpenClicked);
        _ = self.barButton(bar, "document-save-symbolic", "Save", "Save (Ctrl+S)", &onSaveClicked);
        _ = self.barButton(bar, "document-save-as-symbolic", "Save As", "Save As (Ctrl+Shift+S)", &onSaveAsClicked);
        const spacer = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_widget_set_hexpand(spacer, 1);
        c.gtk_box_append(@ptrCast(bar), spacer);
        _ = self.barButton(bar, "view-dual-symbolic", "Split", "Split into a second editor pane", &onSplitClicked);
        self.back_button = self.barButton(bar, "sketerm-terminal-symbolic", "Shell", "Show this pane's shell", &onTerminalClicked);
        c.gtk_box_append(@ptrCast(vbox), bar);
        self.toolbar_box = bar;

        // Document tabs: the shared strip mechanics, pages are empty
        // placeholders (one GLArea below renders the active tab).
        self.tabhost = TabHost.init(self.allocator);
        self.tabhost.ctx = @ptrCast(self);
        self.tabhost.on_close = &hostCloseCb;
        self.tabhost.on_new = &hostNewCb;
        self.tabhost.on_strip_menu = &hostStripMenuCb;
        self.tabhost.tab_menu = editormenu.tabMenuSpec();
        const nb = self.tabhost.widget();
        c.gtk_widget_set_vexpand(nb, 0);
        _ = c.g_signal_connect_data(nb, "switch-page", @ptrCast(&onSwitchPage), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(vbox), nb);
        self.tabhost.installStripGestures();

        // The document canvas, inside an overlay that carries the find
        // bar, in a grid that carries the two scrollbars.
        // A SketermEditArea (GtkGLArea subclass) rather than a bare GL
        // area, so the document's text, caret and selections reach a
        // screen reader through GtkAccessibleText — the same bridge
        // the terminal canvas uses, over the rope instead of the grid.
        self.a11y_src = a11ydoc.DocSource.init(self.allocator, @ptrCast(self), &a11yTarget);
        const area_widget = a11ydoc.newArea(&self.a11y_src, "Editor");
        gl_mod.requestArea(@ptrCast(area_widget));
        c.gtk_gl_area_set_auto_render(@ptrCast(area_widget), 0);
        c.gtk_widget_set_vexpand(area_widget, 1);
        c.gtk_widget_set_hexpand(area_widget, 1);
        c.gtk_widget_set_focusable(area_widget, 1);
        self.area = @ptrCast(area_widget);
        _ = c.g_signal_connect_data(area_widget, "realize", @ptrCast(&onRealize), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(area_widget, "unrealize", @ptrCast(&onUnrealize), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(area_widget, "render", @ptrCast(&onRender), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(area_widget, "resize", @ptrCast(&onAreaResize), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(area_widget, "destroy", @ptrCast(&onAreaDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        const overlay = c.gtk_overlay_new();
        c.gtk_widget_set_hexpand(overlay, 1);
        c.gtk_widget_set_vexpand(overlay, 1);
        c.gtk_overlay_set_child(@ptrCast(overlay), area_widget);
        self.buildFindBar();
        c.gtk_overlay_add_overlay(@ptrCast(overlay), self.find_bar);

        // The external-change banner sits between the tab strip and
        // the canvas (a real child, not an overlay: it must not cover
        // the find bar, and it must not steal a click from the text).
        self.buildBanner();
        self.buildRecoverBanner();
        // Above the change banner: it is about work that predates this
        // session, so it reads first.
        c.gtk_box_append(@ptrCast(vbox), self.recover_box);
        c.gtk_box_append(@ptrCast(vbox), self.banner_box);

        const grid = c.gtk_grid_new();
        c.gtk_widget_set_hexpand(grid, 1);
        c.gtk_widget_set_vexpand(grid, 1);
        c.gtk_grid_attach(@ptrCast(grid), overlay, 0, 0, 1, 1);

        // Vertical range is in ESTIMATED rows (see the module header),
        // horizontal in pixels.
        self.vadj = @ptrCast(@alignCast(c.gtk_adjustment_new(0, 0, 1, 1, 10, 1)));
        self.hadj = @ptrCast(@alignCast(c.gtk_adjustment_new(0, 0, 1, 20, 200, 1)));
        const vsb = c.gtk_scrollbar_new(c.GTK_ORIENTATION_VERTICAL, self.vadj);
        const hsb = c.gtk_scrollbar_new(c.GTK_ORIENTATION_HORIZONTAL, self.hadj);
        self.vscroll = vsb.?;
        self.hscroll = hsb.?;
        c.gtk_grid_attach(@ptrCast(grid), vsb, 1, 0, 1, 1);
        c.gtk_grid_attach(@ptrCast(grid), hsb, 0, 1, 1, 1);
        _ = c.g_signal_connect_data(self.vadj, "value-changed", @ptrCast(&onVAdjChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(self.hadj, "value-changed", @ptrCast(&onHAdjChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        // Panels. The canvas keeps its grid; the outline sits beside it
        // and the project-search results below both, each behind a
        // GtkPaned so the split is the user's. Both start hidden, so a
        // face that never opens one is the widget tree it always was
        // plus two panes with an invisible child.
        const hp = c.gtk_paned_new(c.GTK_ORIENTATION_HORIZONTAL);
        c.gtk_paned_set_start_child(@ptrCast(hp), grid);
        c.gtk_paned_set_resize_start_child(@ptrCast(hp), 1);
        c.gtk_paned_set_shrink_start_child(@ptrCast(hp), 0);
        self.hpaned = hp.?;
        editoroutline.buildPanel(self);
        c.gtk_paned_set_end_child(@ptrCast(hp), self.outline_panel);
        c.gtk_paned_set_resize_end_child(@ptrCast(hp), 0);
        c.gtk_paned_set_shrink_end_child(@ptrCast(hp), 0);

        const vp = c.gtk_paned_new(c.GTK_ORIENTATION_VERTICAL);
        c.gtk_paned_set_start_child(@ptrCast(vp), hp);
        c.gtk_paned_set_resize_start_child(@ptrCast(vp), 1);
        c.gtk_paned_set_shrink_start_child(@ptrCast(vp), 0);
        self.vpaned = vp.?;
        editorproj.buildPanel(self);
        c.gtk_paned_set_end_child(@ptrCast(vp), self.search_panel);
        c.gtk_paned_set_resize_end_child(@ptrCast(vp), 0);
        c.gtk_paned_set_shrink_end_child(@ptrCast(vp), 0);
        c.gtk_widget_set_vexpand(vp, 1);
        c.gtk_box_append(@ptrCast(vbox), vp);

        // Status line.
        const status = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(status), 0);
        c.gtk_widget_add_css_class(status, "dim-label");
        c.gtk_widget_set_margin_start(status, 6);
        c.gtk_widget_set_margin_bottom(status, 2);
        c.gtk_box_append(@ptrCast(vbox), status);
        self.status_label = @ptrCast(@alignCast(status));
        // Right-click on the status line: the verbs behind what it
        // reports (wrap, position, changes, diagnostics).
        editormenu.attachStatusMenu(self, status.?);

        // Keyboard: IM context first (dead keys / compose), our chord
        // handler for what the IM leaves, pane bindings as fallback.
        const keys = c.gtk_event_controller_key_new();
        // imhost.zig owns the IM plumbing (shared with the terminal
        // pane and the forwarded-app host). Under `input_method =
        // auto` this face resolves to GtkIMContextSimple unless the
        // session declares a real input method — it used to be an
        // unconditional multicontext, which silently dropped every
        // dead key on Wayland.
        self.im = imhost.ImHost.attach(
            self.allocator,
            area_widget,
            @ptrCast(keys),
            .editor,
            .{
                .ctx = @ptrCast(self),
                .on_commit = onImCommit,
                .on_preedit = onPreedit,
                .on_preedit_end = onPreeditEndCb,
            },
        ) catch null;
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKeyPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(keys));

        // GtkEventControllerKey does NOT drive focus_in/out on the IM
        // context (GtkText does it from its own focus handler) — and
        // without focus_in, Wayland text-input-v3 never enables, so no
        // IME ever produces a preedit here. Same reasoning as Pane.
        const focus = c.gtk_event_controller_focus_new();
        _ = c.g_signal_connect_data(focus, "enter", @ptrCast(&onFocusEnter), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(focus, "leave", @ptrCast(&onFocusLeave), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(focus));

        // Mouse: caret placement, drag select, double/triple click.
        const click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click), c.GDK_BUTTON_PRIMARY);
        _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&onClickPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(click, "released", @ptrCast(&onClickReleased), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(click));
        const motion = c.gtk_event_controller_motion_new();
        _ = c.g_signal_connect_data(motion, "motion", @ptrCast(&onMotion), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(motion));

        // Right-click context menu on the canvas.
        editormenu.attach(self, area_widget, self.allocator) catch {};

        // Wheel scrolling.
        const scroll = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
        _ = c.g_signal_connect_data(scroll, "scroll", @ptrCast(&onScroll), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(scroll));

        self.root_box = vbox;
    }

    /// One toolbar button, with THIS view as its user data. The shape
    /// (flat, labelled when the icon name does not resolve) is the
    /// shared one every face toolbar uses.
    fn barButton(self: *EditorView, box: *c.GtkWidget, icon: [*:0]const u8, text: [*:0]const u8, tooltip: [*:0]const u8, cb: *const fn (*c.GtkButton, ?*anyopaque) callconv(.c) void) *c.GtkWidget {
        return toolbtn.barButton(box, icon, text, tooltip, cb, @ptrCast(self));
    }

    /// Browser-style find bar, floating at the canvas's top-right.
    /// Two rows: find (always) and replace (only in replace mode).
    fn buildFindBar(self: *EditorView) void {
        const outer = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
        c.gtk_widget_add_css_class(outer, "toolbar");
        c.gtk_widget_add_css_class(outer, "osd");
        c.gtk_widget_set_halign(outer, c.GTK_ALIGN_END);
        c.gtk_widget_set_valign(outer, c.GTK_ALIGN_START);
        c.gtk_widget_set_margin_top(outer, 8);
        c.gtk_widget_set_margin_end(outer, 8);
        c.gtk_widget_set_visible(outer, 0);

        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        const parts = findbar.build(row, .{
            .placeholder = "Find",
            .width_chars = 22,
            .count_width_chars = 9,
            .regex_tooltip = "Regular expression. Replacements expand $1..$9 (and $0 for the whole match).",
        }, .{
            .ctx = @ptrCast(self),
            .on_changed = @ptrCast(&onFindChanged),
            .on_activate = @ptrCast(&onFindActivate),
            .on_stop = @ptrCast(&onFindStop),
            .on_toggle_changed = @ptrCast(&onFindOptionToggled),
        });
        self.find_entry = parts.entry;
        self.find_count = parts.count.?;
        self.find_case = parts.case_btn;
        self.find_word = parts.word_btn;
        self.find_regex = parts.regex_btn;
        _ = findbar.navButton(row, "go-up-symbolic", "Previous match (Shift+Enter)", @ptrCast(&onFindPrevClicked), @ptrCast(self));
        _ = findbar.navButton(row, "go-down-symbolic", "Next match (Enter)", @ptrCast(&onFindNextClicked), @ptrCast(self));
        _ = findbar.navButton(row, "window-close-symbolic", "Close (Escape)", @ptrCast(&onFindCloseClicked), @ptrCast(self));
        c.gtk_box_append(@ptrCast(outer), row);

        const rrow = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        const rentry = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(rentry), "Replace with");
        c.gtk_editable_set_width_chars(@ptrCast(rentry), 22);
        _ = c.g_signal_connect_data(rentry, "activate", @ptrCast(&onReplaceActivate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(rrow), rentry);
        self.replace_entry = rentry.?;
        const rbtn = c.gtk_button_new_with_label("Replace");
        _ = c.g_signal_connect_data(rbtn, "clicked", @ptrCast(&onReplaceClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(rrow), rbtn);
        const abtn = c.gtk_button_new_with_label("All");
        c.gtk_widget_set_tooltip_text(abtn, "Replace every match (one undo step)");
        _ = c.g_signal_connect_data(abtn, "clicked", @ptrCast(&onReplaceAllClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(rrow), abtn);
        c.gtk_widget_set_visible(rrow, 0);
        c.gtk_box_append(@ptrCast(outer), rrow);
        self.replace_row = rrow.?;

        // Escape anywhere in the bar closes it and returns focus.
        const keys = c.gtk_event_controller_key_new();
        c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onFindKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(outer, @ptrCast(keys));

        self.find_bar = outer.?;
    }

    /// Full-width inline banner for external file changes. Same
    /// Adwaita vocabulary as the find bar ("toolbar" styling), hidden
    /// until a document needs it.
    fn buildBanner(self: *EditorView) void {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        c.gtk_widget_add_css_class(row, "toolbar");
        c.gtk_widget_add_css_class(row, "warning");
        c.gtk_widget_set_margin_start(row, 6);
        c.gtk_widget_set_margin_end(row, 6);
        c.gtk_widget_set_margin_top(row, 2);
        c.gtk_widget_set_margin_bottom(row, 2);
        c.gtk_widget_set_visible(row, 0);

        const icon = c.gtk_image_new_from_icon_name("dialog-warning-symbolic");
        c.gtk_box_append(@ptrCast(row), icon);

        const label = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_label_set_wrap(@ptrCast(label), 1);
        c.gtk_widget_set_hexpand(label, 1);
        c.gtk_box_append(@ptrCast(row), label);
        self.banner_label = @ptrCast(@alignCast(label));

        const reload_btn = c.gtk_button_new_with_label("Reload");
        c.gtk_widget_set_tooltip_text(reload_btn, "Replace the buffer with the version on disk");
        _ = c.g_signal_connect_data(reload_btn, "clicked", @ptrCast(&onBannerReload), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), reload_btn);
        self.banner_reload = reload_btn.?;

        const save_btn = c.gtk_button_new_with_label("Save Anyway");
        c.gtk_widget_add_css_class(save_btn, "destructive-action");
        c.gtk_widget_set_tooltip_text(save_btn, "Write this buffer over the version on disk");
        _ = c.g_signal_connect_data(save_btn, "clicked", @ptrCast(&onBannerSave), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), save_btn);
        self.banner_save = save_btn.?;

        const dismiss = c.gtk_button_new_from_icon_name("window-close-symbolic");
        c.gtk_button_set_has_frame(@ptrCast(dismiss), 0);
        c.gtk_widget_set_tooltip_text(dismiss, "Dismiss");
        _ = c.g_signal_connect_data(dismiss, "clicked", @ptrCast(&onBannerDismiss), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), dismiss);

        self.banner_box = row.?;
    }

    /// The crash-recovery offer. Same shape as the external-change
    /// banner (inline, dismissible, never modal) because it is the same
    /// kind of news: something happened to your files while you were
    /// not looking, and only you can decide what to do about it.
    fn buildRecoverBanner(self: *EditorView) void {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        c.gtk_widget_add_css_class(row, "toolbar");
        c.gtk_widget_add_css_class(row, "accent");
        c.gtk_widget_set_margin_start(row, 6);
        c.gtk_widget_set_margin_end(row, 6);
        c.gtk_widget_set_margin_top(row, 2);
        c.gtk_widget_set_margin_bottom(row, 2);
        c.gtk_widget_set_visible(row, 0);

        const icon = c.gtk_image_new_from_icon_name("document-revert-symbolic");
        c.gtk_box_append(@ptrCast(row), icon);

        const label = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_label_set_wrap(@ptrCast(label), 1);
        c.gtk_widget_set_hexpand(label, 1);
        c.gtk_box_append(@ptrCast(row), label);
        self.recover_label = @ptrCast(@alignCast(label));

        const recover_btn = c.gtk_button_new_with_label("Recover");
        c.gtk_widget_add_css_class(recover_btn, "suggested-action");
        c.gtk_widget_set_tooltip_text(recover_btn, "Open each unsaved buffer in a tab, still unsaved");
        _ = c.g_signal_connect_data(recover_btn, "clicked", @ptrCast(&onRecoverClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), recover_btn);

        const discard_btn = c.gtk_button_new_with_label("Discard");
        c.gtk_widget_add_css_class(discard_btn, "destructive-action");
        c.gtk_widget_set_tooltip_text(discard_btn, "Delete these snapshots for good");
        _ = c.g_signal_connect_data(discard_btn, "clicked", @ptrCast(&onRecoverDiscardClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), discard_btn);

        const later = c.gtk_button_new_from_icon_name("window-close-symbolic");
        c.gtk_button_set_has_frame(@ptrCast(later), 0);
        c.gtk_widget_set_tooltip_text(later, "Not now — the snapshots are kept");
        _ = c.g_signal_connect_data(later, "clicked", @ptrCast(&onRecoverLaterClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), later);

        self.recover_box = row.?;
    }

    // ---- tabs ---------------------------------------------------------

    fn findTabByPage(self: *EditorView, page: *c.GtkWidget) ?*ETab {
        for (self.tabs.items) |t| {
            if (t.page == page) return t;
        }
        return null;
    }

    fn findTabById(self: *EditorView, id: u64) ?*ETab {
        for (self.tabs.items) |t| {
            if (t.id == id) return t;
        }
        return null;
    }

    fn findTabByGen(self: *EditorView, gen: u64) ?*ETab {
        if (gen == 0) return null;
        for (self.tabs.items) |t| {
            if (t.io_gen == gen) return t;
        }
        return null;
    }

    /// New tab; with a spec, an async load starts immediately.
    pub fn newTab(self: *EditorView, spec: ?[]const u8) ?*ETab {
        const tab = self.allocator.create(ETab) catch return null;
        const page = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        tab.* = .{
            .view = self,
            .id = self.next_tab_id,
            .page = page.?,
            .handle = undefined,
            .doc = Document.initEmpty(self.allocator),
            .sels = SelectionSet.initSingle(self.allocator, Selection.caret(0)) catch {
                self.allocator.destroy(tab);
                return null;
            },
            .layout = Layout.init(self.allocator, &self.book),
            .rows = RowIndex.init(self.allocator),
            .wrap = self.soft_wrap_default,
            .folds = structure.FoldState.init(self.allocator),
            .sel_stack = structure.SelectionStack.init(self.allocator),
            .git = gitdiff.Marks.init(self.allocator),
            .outline = outline_mod.Outline.init(self.allocator),
        };
        tab.doc.addObserver(.{ .ctx = tab, .before_apply = ETab.observeEdits });
        tab.doc.addObserver(self.a11y_src.editObserver());
        tab.layout.tab_cols = self.tab_width;
        tab.layout.wrap_words = self.wrap_words;
        self.next_tab_id += 1;
        if (spec) |s| tab.spec = self.allocator.dupe(u8, s) catch null;
        const handle = self.tabhost.addPage(page.?, tab.title()) orelse {
            tab.destroy();
            return null;
        };
        tab.handle = handle;
        self.tabs.append(self.allocator, tab) catch {
            self.tabhost.removePage(page.?);
            tab.destroy();
            return null;
        };
        self.tabhost.setCurrentPage(page.?);
        self.active = tab;
        self.applyWrapWidth(tab);
        tab.layout.theme = self.theme;
        self.ensureHighlighter(tab);
        if (tab.spec != null) self.startLoad(tab);
        self.attachLsp(tab);
        editorproj.resolveProject(self, tab);
        self.refresh(tab);
        return tab;
    }

    /// Open (or focus) `spec`; `cursor` restores after the load.
    pub fn openSpec(self: *EditorView, spec: []const u8, cursor: ?usize) void {
        self.openSpecRestored(spec, cursor, null, "");
    }

    /// `openSpec` plus the session state a layout restore carries. An
    /// ALREADY OPEN spec is focused, never opened twice — which is what
    /// keeps a crash-recovered buffer (opened first, from `attach`) and
    /// the restored session from producing two tabs for one file.
    pub fn openSpecRestored(
        self: *EditorView,
        spec: []const u8,
        cursor: ?usize,
        top_line: ?usize,
        project_root: []const u8,
    ) void {
        if (self.tabForSpec(spec)) |t| {
            self.tabhost.setCurrentPage(t.page);
            return;
        }
        const tab = self.newTab(spec) orelse return;
        tab.want_cursor = cursor;
        tab.want_top_line = top_line;
        if (project_root.len > 0)
            tab.restored_project = self.allocator.dupe(u8, project_root) catch null;
    }

    fn hostCloseCb(ctx: ?*anyopaque, page: *c.GtkWidget) void {
        const self: *EditorView = @ptrCast(@alignCast(ctx.?));
        const tab = self.findTabByPage(page) orelse return;
        self.requestCloseTab(tab);
    }

    fn hostNewCb(ctx: ?*anyopaque) void {
        const self: *EditorView = @ptrCast(@alignCast(ctx.?));
        _ = self.newTab(null);
    }

    fn hostStripMenuCb(ctx: ?*anyopaque, x: f64, y: f64) void {
        const self: *EditorView = @ptrCast(@alignCast(ctx.?));
        editormenu.showStripMenu(self, x, y);
    }

    fn onSwitchPage(_: *c.GtkNotebook, page: *c.GtkWidget, _: c.guint, user: ?*anyopaque) callconv(.c) void {
        const self: *EditorView = @ptrCast(@alignCast(user.?));
        if (self.widgets_dead) return;
        self.active = self.findTabByPage(page);
        self.updateBanner();
        self.applyPaneFaceTitle();
        if (self.active) |tab| {
            editorproj.onTabActivated(self, tab);
            editoroutline.refresh(self, tab, true);
        }
        self.updateStatus();
        self.queueRender();
        self.checkDisk();
    }

    /// Close with the dirty confirmation.
    pub fn requestCloseTab(self: *EditorView, tab: *ETab) void {
        if (!tab.isDirty()) {
            self.closeTabForce(tab);
            return;
        }
        const ctx = DlgCtx.create(self, tab) orelse return;
        var body: [300:0]u8 = undefined;
        const b = std.fmt.bufPrintZ(&body, "\"{s}\" has unsaved changes.", .{tab.title()}) catch "This file has unsaved changes.";
        if (confirm.present(self.dialogParent(), .{
            .heading = "Save changes?",
            .body = b.ptr,
            .responses = &.{
                .{ .id = "cancel", .label = "Cancel", .is_close = true },
                .{ .id = "discard", .label = "Discard", .appearance = .destructive },
                .{ .id = "save", .label = "Save", .appearance = .suggested, .is_default = true },
            },
        }, .{ .allocator = self.allocator, .cb = &onCloseDirtyResponse, .ctx = @ptrCast(ctx) }) == null) ctx.destroy();
    }

    fn dialogParent(self: *EditorView) ?*c.GtkWidget {
        if (self.widgets_dead) return null;
        const root = c.gtk_widget_get_root(self.root_box) orelse return null;
        return @ptrCast(@alignCast(root));
    }

    fn onCloseDirtyResponse(user: ?*anyopaque, resp: []const u8) void {
        const ctx: *DlgCtx = @ptrCast(@alignCast(user.?));
        defer ctx.destroy();
        const r = ctx.resolve() orelse return;
        if (std.mem.eql(u8, resp, "discard")) {
            r.view.closeTabForce(r.tab);
        } else if (std.mem.eql(u8, resp, "save")) {
            r.tab.close_after_save = true;
            r.view.saveTab(r.tab);
        }
    }

    fn closeTabForce(self: *EditorView, tab: *ETab) void {
        tab.io_gen = 0; // orphan any in-flight IO
        // didClose + drop this tab's pending requests, while the
        // document (and its URI) still exist.
        if (self.lsp) |m| m.detachTab(tab);
        for (self.tabs.items, 0..) |t, i| {
            if (t == tab) {
                _ = self.tabs.orderedRemove(i);
                break;
            }
        }
        if (self.active == tab) self.active = null;
        if (!self.widgets_dead) self.tabhost.removePage(tab.page);
        tab.destroy();
        if (!self.widgets_dead) {
            if (self.tabhost.currentPage()) |page| {
                self.active = self.findTabByPage(page);
            }
            // No documents left: hand the pane back to whichever face
            // the editor displaced (its shell, or the file browser).
            if (self.tabs.items.len == 0) {
                if (self.pane) |p| p.setEditorVisible(false);
            }
            self.applyPaneFaceTitle();
            self.updateStatus();
            self.queueRender();
        }
    }

    // ---- language server ----------------------------------------------
    //
    // The LSP client lives in editorlsp.zig; everything here is the
    // narrow surface it needs back from the view. Keeping it to named
    // methods (rather than reaching into fields from the other module)
    // is what lets the pane face and the standalone window share it
    // without either knowing about the other.

    /// Give `tab` a language server if one is configured and installed.
    /// Creates the manager on first use; silent when nothing claims the
    /// document's language.
    fn attachLsp(self: *EditorView, tab: *ETab) void {
        const conf: *const Config = if (self.ownerWindow()) |win|
            &win.config
        else
            self.standalone_config orelse return;
        if (!conf.editor_lsp) return;
        if (self.lsp == null) self.lsp = editorlsp.Manager.create(self);
        const m = self.lsp orelse return;
        m.attachTab(tab);
    }

    pub fn activeTab(self: *EditorView) ?*ETab {
        return self.active;
    }

    pub fn findTabByIdPublic(self: *EditorView, id: u64) ?*ETab {
        return self.findTabById(id);
    }

    /// The open tab holding `spec`, if any — how a project-wide replace
    /// tells "rewrite the file" from "edit the buffer".
    pub fn tabForSpec(self: *EditorView, spec: []const u8) ?*ETab {
        for (self.tabs.items) |t| {
            const ts = t.spec orelse continue;
            if (specEql(ts, spec)) return t;
        }
        return null;
    }

    /// Two specs name the same document when their (host, path) agree.
    /// A raw string compare is not enough: `paths.formatSpec` writes a
    /// local path as `local:/x` while the picker and the CLI hand over
    /// a bare `/x`, and both must resolve to ONE tab.
    fn specEql(a: []const u8, b: []const u8) bool {
        if (std.mem.eql(u8, a, b)) return true;
        const la = paths.parseSpec(a);
        const lb = paths.parseSpec(b);
        if (!std.mem.eql(u8, la.host orelse "", lb.host orelse "")) return false;
        return std.mem.eql(u8, la.path, lb.path);
    }

    /// Post a transient message to the status line. It survives the
    /// rebuilds `updateStatus` does on every caret move / edit / tab
    /// switch, for `STATUS_NOTE_MS`, then disappears on its own.
    pub fn setStatusText(self: *EditorView, text: [*:0]const u8) void {
        self.postStatus(std.mem.span(text));
    }

    pub fn queueRenderExternal(self: *EditorView) void {
        self.queueRender();
    }

    pub fn updateStatusExternal(self: *EditorView) void {
        self.updateStatus();
    }

    /// Post-edit bookkeeping for an edit the LSP client applied
    /// (completion accept, rename, formatting) — the same path a typed
    /// edit takes, so highlighting, folds, find results and the server
    /// itself all follow.
    pub fn afterExternalEdit(self: *EditorView, tab: *ETab) void {
        tab.goal_x = null;
        self.afterDocEdit(tab);
    }

    pub fn afterExternalMove(self: *EditorView, tab: *ETab) void {
        tab.goal_x = null;
        self.afterMove(tab);
    }

    /// Open `spec` and put the caret on (line, col). Goes through the
    /// ordinary tab machinery: an already-open file is focused rather
    /// than opened twice, and a not-yet-loaded one gets its caret once
    /// the async load lands.
    pub fn openSpecAtLineCol(self: *EditorView, spec: []const u8, line: u32, col: u32) void {
        for (self.tabs.items) |t| {
            const ts = t.spec orelse continue;
            if (!std.mem.eql(u8, ts, spec)) continue;
            self.tabhost.setCurrentPage(t.page);
            self.active = t;
            self.applyWantPos(t, .{ .line = line, .character = col });
            return;
        }
        const tab = self.newTab(spec) orelse return;
        tab.want_pos = .{ .line = line, .character = col };
    }

    /// Put the caret on an LSP position. `character` is in the server's
    /// negotiated encoding, so it goes through the position mapper
    /// rather than being treated as a byte column.
    fn applyWantPos(self: *EditorView, tab: *ETab, p: lsp_pos.Position) void {
        const enc: lsp_pos.Encoding = blk: {
            const st = tab.lsp orelse break :blk .utf16;
            const cn = st.conn orelse break :blk .utf16;
            break :blk cn.sess.caps.encoding;
        };
        const off = lsp_pos.positionToOffset(&tab.doc.rope, p, enc);
        tab.sels.keepPrimaryOnly();
        if (tab.sels.sels.items.len == 0) {
            tab.sels.sels.append(self.allocator, Selection.caret(off)) catch return;
        } else tab.sels.sels.items[0] = Selection.caret(off);
        tab.goal_x = null;
        self.revealCaretLines(tab);
        self.refresh(tab);
    }

    /// The caret's rectangle in WIDGET coordinates — what a popover
    /// points at. Deliberately the same geometry `setImCursorLocation`
    /// ships to the input method, so a completion list and an IME
    /// candidate window never disagree about where the caret is.
    /// Visible logical line range — what an inlay-hint range request
    /// asks for.
    pub fn visibleLineSpanPublic(self: *EditorView, tab: *ETab) struct { from: usize, to: usize } {
        const span = self.visibleLineSpan(tab);
        return .{ .from = span.from, .to = span.to };
    }

    /// Byte offset under a WIDGET-coordinate point, or null when the
    /// point is over the gutter (where a dwell means nothing).
    pub fn offsetAtPointPublic(self: *EditorView, tab: *ETab, lx: f64, ly: f64) ?usize {
        if (self.widgets_dead or self.atlas == null) return null;
        const scale: f32 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
        if (@as(f32, @floatCast(lx)) * scale < self.gutterWidthOf(tab)) return null;
        return self.hitTest(tab, lx, ly);
    }

    /// A one-cell rectangle at a WIDGET-coordinate point — what a
    /// pointer-anchored popover points at.
    pub fn pointRectPx(self: *EditorView, lx: f64, ly: f64) ?c.GdkRectangle {
        if (self.widgets_dead) return null;
        const scale: f32 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
        if (scale <= 0) return null;
        return .{
            .x = @intFromFloat(lx),
            .y = @intFromFloat(ly),
            .width = 1,
            .height = @intFromFloat(self.lineHeight() / scale),
        };
    }

    pub fn caretRectPx(self: *EditorView) ?c.GdkRectangle {
        if (self.widgets_dead) return null;
        const tab = self.active orelse return null;
        if (self.atlas == null) return null;
        const scale: f32 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
        if (scale <= 0) return null;
        self.ensureRows(tab);
        const cv = self.caretVisual(tab, tab.sels.primary().head);
        const line_h = self.lineHeight();
        const rel_row: f32 = @floatFromInt(
            (tab.rows.rowsBefore(cv.line) + cv.row) -| viewport_mod.anchorRow(&tab.rows, tab.anchor),
        );
        return .{
            .x = @intFromFloat((self.pass.text_origin_x + cv.x) / scale),
            .y = @intFromFloat((rel_row * line_h - tab.anchor.offset) / scale),
            .width = 1,
            .height = @intFromFloat(line_h / scale),
        };
    }

    /// Ask for a new symbol name, then hand it to the LSP client.
    pub fn promptRename(self: *EditorView, current: []const u8) void {
        if (self.widgets_dead) return;
        const tab = self.active orelse return;
        const ctx = DlgCtx.create(self, tab) orelse return;
        const entry = c.gtk_entry_new();
        const z = self.allocator.dupeZ(u8, current) catch {
            ctx.destroy();
            return;
        };
        defer self.allocator.free(z);
        c.gtk_editable_set_text(@ptrCast(entry), z.ptr);
        c.gtk_editable_select_region(@ptrCast(entry), 0, -1);
        // The entry lives on the dialog, so it is alive for as long as
        // the response callback can fire.
        self.rename_entry = entry;
        if (confirm.present(self.dialogParent(), .{
            .heading = "Rename symbol",
            .responses = &.{
                .{ .id = "cancel", .label = "Cancel", .is_close = true },
                .{ .id = "rename", .label = "Rename", .appearance = .suggested, .is_default = true },
            },
            .extra_child = entry,
        }, .{ .allocator = self.allocator, .cb = &onRenameResponse, .ctx = @ptrCast(ctx) }) == null) {
            self.rename_entry = null;
            // Nothing adopted the floating entry.
            _ = c.g_object_ref_sink(@ptrCast(entry));
            c.g_object_unref(@ptrCast(entry));
            ctx.destroy();
        }
    }

    fn onRenameResponse(user: ?*anyopaque, resp: []const u8) void {
        const ctx: *DlgCtx = @ptrCast(@alignCast(user.?));
        defer ctx.destroy();
        const r = ctx.resolve() orelse return;
        const entry = r.view.rename_entry;
        r.view.rename_entry = null;
        if (!std.mem.eql(u8, resp, "rename")) return;
        const e = entry orelse return;
        const raw = c.gtk_editable_get_text(@ptrCast(e));
        if (raw == null) return;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        const m = r.view.lsp orelse return;
        m.submitRename(name);
    }

    // ---- GL lifecycle -------------------------------------------------

    fn physicalFontSize(self: *EditorView) u16 {
        const scale: f64 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
        const dpi: f64 = 96.0 * scale;
        const px: f64 = @as(f64, @floatFromInt(self.font_size)) * dpi / 72.0;
        return @intFromFloat(@max(1.0, @round(px)));
    }

    /// Pane.createAtlasInner's resolution order over the attach-time
    /// copies: explicit path → family (fontconfig) → $SKETERM_FONT →
    /// built-in candidates.
    fn createAtlas(self: *EditorView) ?*Atlas {
        const size = self.physicalFontSize();
        if (self.font_path) |fp| {
            if (self.tryAtlasPath(fp, size)) |a| return a;
        }
        if (self.font_family) |fam| {
            if (atlas_mod.resolveFamilyPath(self.allocator, fam)) |path| {
                defer self.allocator.free(path);
                if (Atlas.initOpts(self.allocator, path.ptr, size, self.line_pad)) |a| return a else |_| {}
            }
        }
        if (@import("../util/profile.zig").getenv("SKETERM_FONT")) |env_path| {
            if (self.tryAtlasPath(env_path, size)) |a| return a;
        }
        for (pane_mod.FONT_CANDIDATES) |path| {
            if (Atlas.initOpts(self.allocator, path, size, self.line_pad)) |a| return a else |_| continue;
        }
        return null;
    }

    fn tryAtlasPath(self: *EditorView, fp: []const u8, size: u16) ?*Atlas {
        const z = self.allocator.allocSentinel(u8, fp.len, 0) catch return null;
        defer self.allocator.free(z);
        @memcpy(z, fp);
        return Atlas.initOpts(self.allocator, z.ptr, size, self.line_pad) catch null;
    }

    fn onRealize(area: *c.GtkGLArea, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        c.gtk_gl_area_make_current(area);
        gl_mod.adoptAreaApi(area);
        if (c.gtk_gl_area_get_error(area) != null) {
            const err = c.gtk_gl_area_get_error(area);
            const msg: [*:0]const u8 = if (err != null) err.*.message else "<no message>";
            std.debug.print("sketerm: editor realize GL error: {s}\n", .{msg});
            return;
        }
        // Every realize is potentially a re-realize (reparent killed
        // the old context): drop stale handles first.
        if (self.atlas) |old| {
            old.deinit();
            self.atlas = null;
        }
        self.pass.forgetGL();
        self.linear_target.forgetGL();
        self.atlas = self.createAtlas();
        if (self.atlas == null) {
            std.debug.print("sketerm: editor realize found no usable font\n", .{});
            return;
        }
        self.atlas.?.realize();
        self.book = FontBook.init(self.atlas.?);
        for (self.tabs.items) |t| t.layout.invalidateAll();
        self.pass.realize() catch {
            std.debug.print("sketerm: editor pass realize failed\n", .{});
            return;
        };
    }

    fn onUnrealize(area: *c.GtkGLArea, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        c.gtk_gl_area_make_current(area);
        if (c.gtk_gl_area_get_error(area) != null) {
            self.pass.forgetGL();
            return;
        }
        self.pass.releaseGL();
        self.linear_target.releaseGL();
        if (self.atlas) |a| a.releaseGL();
    }

    fn onRender(area: *c.GtkGLArea, _: ?*c.GdkGLContext, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(EditorView, user);
        const w = c.gtk_widget_get_width(@ptrCast(area));
        const h = c.gtk_widget_get_height(@ptrCast(area));
        const scale = c.gtk_widget_get_scale_factor(@ptrCast(area));
        const pw: c_int = w * scale;
        const ph: c_int = h * scale;
        const linear_on = self.linear_target.begin(self.text_blending, pw, ph);
        const eff_mode = if (linear_on) self.text_blending else .native;
        self.pass.blend_mode = eff_mode;
        c.glViewport(0, 0, pw, ph);
        const bg = self.theme.bg;
        self.pass.default_bg = bg;
        // glClear writes through the target's sRGB encode too.
        const clear = @import("../render/blend.zig").clearColor(eff_mode, bg);
        c.glClearColor(clear[0], clear[1], clear[2], clear[3]);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        defer if (linear_on) self.linear_target.finish(pw, ph);
        const atlas = self.atlas orelse return 1;
        const tab = self.active orelse return 1;
        self.syncFolds(tab);
        self.ensureRows(tab);
        self.clampAnchor(tab, @floatFromInt(ph));
        const span = self.visibleLineSpan(tab);
        self.ensureFoldMarkers(tab, span.from, span.to);
        self.ensureBrackets(tab);
        // Language-server decorations are BORROWED by the layout for
        // exactly this frame; a stale set is unbound here rather than
        // filtered later (editorlsp.applyDecorations).
        if (self.lsp) |m| {
            m.applyDecorations(tab);
            m.onViewportMoved();
        } else {
            tab.layout.sem = &.{};
            tab.layout.sem_gen = 0;
            tab.layout.hints = &.{};
            tab.layout.hints_gen = 0;
        }
        const view = editor_pass.View{
            .width_px = @floatFromInt(pw),
            .height_px = @floatFromInt(ph),
            .anchor = tab.anchor,
            .scroll_x = tab.scroll_x,
            .show_line_numbers = self.line_numbers,
            .show_fold_column = self.folding,
            .highlight_current_line = self.highlight_current_line,
            .caret_on = self.caret_on or self.typing_hold,
        };
        var frame = editor_pass.Frame{
            .layout = &tab.layout,
            .doc = &tab.doc,
            .sels = &tab.sels,
            .colors = self.colors,
            .view = view,
            .rows = &tab.rows,
            .matches = tab.matches,
            .current_match = tab.current_match,
            .folds = &tab.folds,
            .fold_markers = tab.fold_markers.items,
            .brackets = tab.brackets.items,
            .diagnostics = if (self.lsp) |m| m.diagnosticsFor(tab) else &.{},
            .git_marks = if (self.git_gutter) tab.git.list.items else &.{},
            // Only when this tab is actually highlighted: with no
            // highlighter every glyph's kind is `.none`, and paying the
            // theme lookup to arrive back at `colors.text` is noise.
            .theme = if (tab.hl != null) self.theme else null,
        };
        if (self.preeditLine()) |pl| {
            frame.preedit = .{
                .line = pl,
                .at = tab.sels.primary().head,
                .cursor = self.preedit_cursor,
            };
        }
        self.pass.buildFrame(frame) catch return 1;
        self.pass.draw(atlas, pw, ph);
        tab.max_width = @max(tab.max_width, self.pass.max_row_width);
        self.syncScrollbars(tab, @floatFromInt(pw), @floatFromInt(ph));
        return 1;
    }

    fn onAreaResize(_: *c.GtkGLArea, _: c_int, _: c_int, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        const tab = self.active orelse return;
        self.applyWrapWidth(tab);
    }

    fn queueRender(self: *EditorView) void {
        if (self.widgets_dead) return;
        c.gtk_gl_area_queue_render(self.area);
    }

    // ---- geometry -----------------------------------------------------

    fn lineHeight(self: *EditorView) f32 {
        const atlas = self.atlas orelse return 16;
        return @floatFromInt(atlas.cell_h);
    }

    fn viewportHeightPx(self: *EditorView) f32 {
        const h = c.gtk_widget_get_height(@ptrCast(self.area));
        const scale = c.gtk_widget_get_scale_factor(@ptrCast(self.area));
        return @floatFromInt(h * scale);
    }

    fn viewportWidthPx(self: *EditorView) f32 {
        const w = c.gtk_widget_get_width(@ptrCast(self.area));
        const scale = c.gtk_widget_get_scale_factor(@ptrCast(self.area));
        return @floatFromInt(w * scale);
    }

    fn viewportRows(self: *EditorView) usize {
        const line_h = self.lineHeight();
        const vh = self.viewportHeightPx();
        if (line_h <= 0 or vh <= 0) return 1;
        return @max(1, @as(usize, @intFromFloat(@floor(vh / line_h))));
    }

    // ---- wrap ---------------------------------------------------------

    /// Push the tab's wrap setting into its Layout. Any change to the
    /// wrap width invalidates the layout cache AND the row estimate,
    /// since both are keyed on it.
    fn applyWrapWidth(self: *EditorView, tab: *ETab) void {
        const want: ?f32 = if (!tab.wrap) null else blk: {
            const atlas = self.atlas orelse break :blk null;
            const total = self.viewportWidthPx();
            if (total <= 0) break :blk null;
            _ = atlas;
            const gutter = self.gutterWidthOf(tab);
            // The right margin keeps the last glyph off the scrollbar.
            break :blk @max(40.0, total - gutter - 8 - 8);
        };
        const same = if (want) |w|
            tab.layout.wrap_width != null and @abs(tab.layout.wrap_width.? - w) < 0.5
        else
            tab.layout.wrap_width == null;
        if (same) return;
        tab.layout.wrap_width = want;
        tab.layout.invalidateAll();
        tab.rows_lines = 0;
        if (tab.wrap) tab.scroll_x = 0;
        self.queueRender();
    }

    /// Toggle soft wrap for the active tab, keeping the caret in view.
    pub fn toggleWrap(self: *EditorView, tab: *ETab) void {
        tab.wrap = !tab.wrap;
        if (!tab.wrap) tab.rows_lines = 0;
        self.applyWrapWidth(tab);
        self.ensureCaretVisible(tab);
        self.updateStatus();
        self.queueRender();
    }

    // ---- anchored scrolling -------------------------------------------

    /// Rebuild the row estimate when the document or the wrap width
    /// moved under it. Cheap: O(n) memset, and nothing at all with
    /// wrap off.
    fn ensureRows(self: *EditorView, tab: *ETab) void {
        _ = self;
        const n = tab.doc.rope.lineCount();
        const ww = tab.layout.wrap_width orelse 0;
        // Folds need the index even with wrap off: a hidden line weighs
        // zero rows, which is how the scrollbar and every row<->anchor
        // conversion stay fold-correct (render/editor_viewport.zig).
        const want_enabled = tab.layout.wrap_width != null or !tab.folds.isEmpty();
        if (tab.rows_lines == n and tab.rows.enabled == want_enabled and
            tab.rows_folds == tab.folds_epoch and
            @abs(tab.rows_wrap_width - ww) < 0.5) return;
        tab.rows.reset(want_enabled, n);
        tab.rows_lines = n;
        tab.rows_wrap_width = ww;
        tab.rows_folds = tab.folds_epoch;
        for (tab.folds.hidden.items) |sp| {
            var l = sp.start_line;
            while (l <= sp.end_line and l < n) : (l += 1) tab.rows.setHidden(l, true);
        }
    }

    /// Wrapped rows of `line`, laying it out only when wrap is on.
    fn rowsOfLine(self: *EditorView, tab: *ETab, line: usize) u32 {
        if (tab.layout.wrap_width == null or self.atlas == null) return 1;
        const ll = tab.layout.line(&tab.doc, line) catch return tab.rows.rowsOf(line);
        const n: u32 = @intCast(ll.rows.len);
        tab.rows.note(line, n);
        return n;
    }

    /// Move the anchor by `dy` pixels, laying out ONLY the lines
    /// stepped over (wheel scrolling covers a handful; big jumps go
    /// through setAnchorRow instead).
    fn scrollByPx(self: *EditorView, tab: *ETab, dy: f32) void {
        self.ensureRows(tab);
        const line_h = self.lineHeight();
        if (line_h <= 0) return;
        const n_lines = tab.doc.rope.lineCount();
        var acc = tab.anchor.offset + dy;
        var line = tab.folds.nextVisible(@min(tab.anchor.line, n_lines -| 1));
        if (line >= n_lines) line = tab.folds.prevVisible(n_lines -| 1);
        var row: i64 = tab.anchor.row;
        while (acc >= line_h) {
            const rows = self.rowsOfLine(tab, line);
            if (row + 1 < rows) {
                row += 1;
            } else {
                const next = tab.folds.nextVisible(line + 1);
                if (next >= n_lines) break;
                line = next;
                row = 0;
            }
            acc -= line_h;
        }
        while (acc < 0) {
            if (row > 0) {
                row -= 1;
            } else if (line > 0) {
                const prev = tab.folds.prevVisible(line - 1);
                if (prev == line) {
                    acc = 0;
                    break;
                }
                line = prev;
                row = @as(i64, self.rowsOfLine(tab, line)) - 1;
            } else {
                acc = 0;
                break;
            }
            acc += line_h;
        }
        tab.anchor = .{ .line = line, .row = @intCast(@max(0, row)), .offset = @max(0, acc) };
        self.clampAnchor(tab, self.viewportHeightPx());
    }

    /// Jump to an ESTIMATED global row (scrollbar drag, Ctrl+End).
    fn setAnchorRow(self: *EditorView, tab: *ETab, row: usize) void {
        self.ensureRows(tab);
        tab.anchor = tab.rows.anchorAtRow(tab.doc.rope.lineCount(), row);
        self.clampAnchor(tab, self.viewportHeightPx());
    }

    /// Never scroll past the last row (keeping one screen minus a row
    /// of content visible), nor above the top.
    fn clampAnchor(self: *EditorView, tab: *ETab, view_h: f32) void {
        self.ensureRows(tab);
        const n_lines = tab.doc.rope.lineCount();
        if (n_lines == 0) {
            tab.anchor = .{};
            return;
        }
        if (tab.anchor.line >= n_lines) tab.anchor = .{ .line = n_lines - 1, .row = 0 };
        const line_h = self.lineHeight();
        const vis: usize = if (line_h > 0 and view_h > 0)
            @max(1, @as(usize, @intFromFloat(@floor(view_h / line_h))))
        else
            1;
        const total = tab.rows.totalRows(n_lines);
        const max_row = total -| @max(1, vis - 1);
        const cur = viewport_mod.anchorRow(&tab.rows, tab.anchor);
        if (cur > max_row) {
            tab.anchor = tab.rows.anchorAtRow(n_lines, max_row);
            tab.anchor.offset = 0;
        }
        const max_x = @max(0.0, tab.max_width - @max(50.0, self.viewportWidthPx() - self.pass.text_origin_x));
        tab.scroll_x = std.math.clamp(tab.scroll_x, 0, if (tab.wrap) 0 else max_x);
    }

    /// Widget-space (logical) coordinates → document byte offset. Walks
    /// forward from the anchor, so it costs O(viewport) like the frame.
    fn hitTest(self: *EditorView, tab: *ETab, lx: f64, ly: f64) usize {
        const atlas = self.atlas orelse return 0;
        const scale: f32 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
        const x: f32 = @as(f32, @floatCast(lx)) * scale;
        const y: f32 = @as(f32, @floatCast(ly)) * scale;
        const line_h = self.lineHeight();
        const n_lines = tab.doc.rope.lineCount();
        if (n_lines == 0) return 0;
        _ = atlas;
        _ = line_h;
        const gutter = self.gutterWidthOf(tab);
        const text_x0 = gutter + 8 - tab.scroll_x;
        const hit = self.locateY(tab, y) orelse return 0;
        const ll = tab.layout.line(&tab.doc, hit.line) catch
            return tab.doc.rope.lineToOffset(hit.line);
        return ll.byte_start + Layout.xToByte(ll, hit.row, x - text_x0);
    }

    /// Device-pixel y -> (visible line, wrapped row within it). Walks
    /// forward from the anchor, SKIPPING folded lines exactly the way
    /// the render pass does, so a click lands on what was drawn.
    fn locateY(self: *EditorView, tab: *ETab, y: f32) ?struct { line: usize, row: u32 } {
        const n_lines = tab.doc.rope.lineCount();
        if (n_lines == 0) return null;
        const line_h = self.lineHeight();
        if (line_h <= 0) return null;
        var li = tab.folds.nextVisible(@min(tab.anchor.line, n_lines - 1));
        if (li >= n_lines) li = tab.folds.prevVisible(n_lines - 1);
        var top: f32 = -tab.anchor.offset - @as(f32, @floatFromInt(tab.anchor.row)) * line_h;
        while (true) {
            const ll = tab.layout.line(&tab.doc, li) catch return .{ .line = li, .row = 0 };
            const bottom = top + @as(f32, @floatFromInt(ll.rows.len)) * line_h;
            const next = tab.folds.nextVisible(li + 1);
            if (y < bottom or next >= n_lines) {
                var row: u32 = 0;
                if (y > top) {
                    const r: usize = @intFromFloat(@floor((y - top) / line_h));
                    row = @intCast(@min(r, ll.rows.len - 1));
                }
                return .{ .line = li, .row = row };
            }
            top = bottom;
            li = next;
        }
    }

    /// Visual row of the primary caret within its line, plus its x.
    fn caretVisual(self: *EditorView, tab: *ETab, offset: usize) struct { line: usize, row: u32, x: f32 } {
        const lb = vm.lineBoundsAt(&tab.doc, offset);
        if (self.atlas != null) {
            if (tab.layout.line(&tab.doc, lb.line)) |ll| {
                tab.rows.note(lb.line, @intCast(ll.rows.len));
                const cp = Layout.caretPos(ll, offset - lb.start);
                return .{ .line = lb.line, .row = cp.row, .x = cp.x };
            } else |_| {}
        }
        return .{ .line = lb.line, .row = 0, .x = 0 };
    }

    /// Scroll so the primary caret is on screen, vertically AND
    /// horizontally. Called after every cursor change.
    fn ensureCaretVisible(self: *EditorView, tab: *ETab) void {
        if (self.widgets_dead) return;
        const view_h = self.viewportHeightPx();
        if (view_h <= 0) return;
        self.ensureRows(tab);
        const cv = self.caretVisual(tab, tab.sels.primary().head);
        const caret_row = tab.rows.rowsBefore(cv.line) + cv.row;
        const anchor_row = viewport_mod.anchorRow(&tab.rows, tab.anchor);
        const vis = self.viewportRows();
        if (caret_row < anchor_row or (caret_row == anchor_row and tab.anchor.offset > 0)) {
            self.setAnchorRow(tab, caret_row);
            tab.anchor.offset = 0;
        } else if (caret_row >= anchor_row + vis) {
            self.setAnchorRow(tab, caret_row + 1 - vis);
            tab.anchor.offset = 0;
        }
        // Horizontal (wrap off only — wrapped text never overflows).
        if (!tab.wrap) {
            const text_w = @max(50.0, self.viewportWidthPx() - self.pass.text_origin_x - tab.scroll_x);
            if (cv.x < tab.scroll_x) tab.scroll_x = @max(0, cv.x - 24);
            if (cv.x > tab.scroll_x + text_w - 8) tab.scroll_x = cv.x - text_w + 24;
            tab.max_width = @max(tab.max_width, cv.x + 40);
            if (tab.scroll_x < 0) tab.scroll_x = 0;
        } else {
            tab.scroll_x = 0;
        }
        self.setImCursorLocation(tab, cv);
    }

    /// Where the IME should put its candidate window.
    fn setImCursorLocation(self: *EditorView, tab: *ETab, cv: anytype) void {
        const im = self.im orelse return;
        if (self.atlas == null) return;
        const scale: f32 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
        if (scale <= 0) return;
        self.ensureRows(tab);
        const line_h = self.lineHeight();
        const rel_row: f32 = @floatFromInt(
            (tab.rows.rowsBefore(cv.line) + cv.row) -| viewport_mod.anchorRow(&tab.rows, tab.anchor),
        );
        // Debounced inside ImHost against the last rectangle sent —
        // this runs from every caret move, and the call can be a D-Bus
        // round trip to ibus/fcitx.
        im.setCursorLocation(.{
            .x = @intFromFloat((self.pass.text_origin_x + cv.x) / scale),
            .y = @intFromFloat((rel_row * line_h - tab.anchor.offset) / scale),
            .width = 1,
            .height = @intFromFloat(line_h / scale),
        });
    }

    // ---- scrollbars ---------------------------------------------------

    /// Compute the scrollbar geometry for the frame being rendered and
    /// queue it for application OUTSIDE the frame.
    ///
    /// The caller is the GtkGLArea ::render handler, i.e. we are inside
    /// GTK's snapshot pass. Touching the adjustments there is illegal:
    /// `gtk_adjustment_configure` makes GtkRange invalidate its slider's
    /// allocation, and the same snapshot then walks into a slider gizmo
    /// that has no allocation any more ("Trying to snapshot GtkGizmo
    /// without a current allocation" — and a frame of missing
    /// scrollbar). Same reason the horizontal scrollbar's `set_visible`
    /// was already change-guarded; the adjustments need the same care,
    /// which they can only get by moving off the render pass entirely.
    fn syncScrollbars(self: *EditorView, tab: *ETab, view_w: f32, view_h: f32) void {
        if (self.widgets_dead) return;
        const line_h = self.lineHeight();
        if (line_h <= 0) return;
        const n_lines = tab.doc.rope.lineCount();
        const total: f64 = @floatFromInt(tab.rows.totalRows(n_lines));
        const page: f64 = @max(1.0, @as(f64, view_h / line_h));
        const value: f64 = @floatFromInt(viewport_mod.anchorRow(&tab.rows, tab.anchor));
        // Horizontal: only meaningful with wrap off.
        const text_w: f64 = @max(1.0, view_w - self.pass.text_origin_x - tab.scroll_x);
        const hupper: f64 = @max(@as(f64, tab.max_width + 40), text_w);
        const geom: ScrollGeom = .{
            .v_value = value,
            .v_upper = @max(total, page),
            .v_page = page,
            .h_value = tab.scroll_x,
            .h_upper = hupper,
            .h_page = text_w,
            .want_h = !tab.wrap and hupper > text_w + 1,
        };
        if (self.sb_applied) |old| {
            if (std.meta.eql(old, geom)) return;
        }
        self.sb_pending = geom;
        if (self.sb_source == 0)
            self.sb_source = c.g_idle_add(@ptrCast(&applyScrollbars), @ptrCast(self));
    }

    fn applyScrollbars(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(EditorView, user);
        self.sb_source = 0;
        const geom = self.sb_pending orelse return 0;
        self.sb_pending = null;
        if (self.widgets_dead) return 0;
        self.sb_guard = true;
        c.gtk_adjustment_configure(self.vadj, geom.v_value, 0, geom.v_upper, 1, @max(1.0, geom.v_page - 1), geom.v_page);
        c.gtk_adjustment_configure(self.hadj, geom.h_value, 0, geom.h_upper, 20, geom.h_page * 0.9, geom.h_page);
        self.sb_guard = false;
        if ((c.gtk_widget_get_visible(self.hscroll) != 0) != geom.want_h)
            c.gtk_widget_set_visible(self.hscroll, if (geom.want_h) 1 else 0);
        self.sb_applied = geom;
        return 0;
    }

    /// Drop the queued scrollbar update — it carries a raw *EditorView.
    fn stopScrollbarSync(self: *EditorView) void {
        if (self.sb_source != 0) {
            _ = c.g_source_remove(self.sb_source);
            self.sb_source = 0;
        }
        self.sb_pending = null;
    }

    fn onVAdjChanged(adj: *c.GtkAdjustment, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        if (self.sb_guard or self.widgets_dead) return;
        const tab = self.active orelse return;
        const v = c.gtk_adjustment_get_value(adj);
        const row: usize = if (v <= 0) 0 else @intFromFloat(v);
        self.setAnchorRow(tab, row);
        self.queueRender();
    }

    fn onHAdjChanged(adj: *c.GtkAdjustment, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        if (self.sb_guard or self.widgets_dead) return;
        const tab = self.active orelse return;
        if (tab.wrap) return;
        tab.scroll_x = @floatCast(@max(0.0, c.gtk_adjustment_get_value(adj)));
        self.queueRender();
    }

    // ---- caret blink ---------------------------------------------------

    /// g_timeout, NOT a frame-clock tick: a tick callback on a
    /// GtkGLArea leaks under Wayland (TerminalSurface.blink_timer, same reason).
    fn startBlink(self: *EditorView) void {
        if (self.blink_timer != 0) return;
        self.blink_timer = c.g_timeout_add(530, @ptrCast(&onBlinkTimer), @ptrCast(self));
    }

    fn stopBlink(self: *EditorView) void {
        if (self.blink_timer == 0) return;
        _ = c.g_source_remove(self.blink_timer);
        self.blink_timer = 0;
    }

    fn onBlinkTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(EditorView, user);
        if (self.widgets_dead) {
            self.blink_timer = 0;
            return 0;
        }
        // One interval of solid caret after each keystroke, then blink
        // resumes — the "stop while typing" behaviour.
        if (self.typing_hold) {
            self.typing_hold = false;
            self.caret_on = true;
        } else {
            self.caret_on = !self.caret_on;
        }
        self.queueRender();
        return 1;
    }

    /// Called from every edit/movement: hold the caret solid.
    fn noteActivity(self: *EditorView) void {
        self.typing_hold = true;
        self.caret_on = true;
    }

    // ---- IME preedit ----------------------------------------------------

    fn clearPreedit(self: *EditorView) void {
        if (self.preedit_layout) |*l| {
            l.deinit();
            self.preedit_layout = null;
        }
        if (self.preedit_doc) |*d| {
            d.deinit();
            self.preedit_doc = null;
        }
        self.preedit_cursor = 0;
    }

    fn preeditLine(self: *EditorView) ?*const layout_mod.LaidLine {
        if (self.atlas == null) return null;
        const doc = &(self.preedit_doc orelse return null);
        if (doc.rope.len() == 0) return null;
        const l = &(self.preedit_layout orelse return null);
        return l.line(doc, 0) catch null;
    }

    /// Rebuild the throwaway preedit document from the IM text.
    /// `cursor_chars` is GTK's character offset; the pass wants bytes.
    fn setPreedit(self: *EditorView, span: []const u8, cursor_chars: usize) void {
        self.clearPreedit();
        // Speech-only channel: the composing string is ANNOUNCED, never
        // routed into the document. The accessible text stays
        // byte-for-byte the committed rope, so no accessible offset
        // ever covers uncommitted composition; the commit announces
        // itself through the ordinary text-changed events.
        self.a11y_src.setPreedit(span);
        if (span.len == 0) return;
        var doc = Document.initFromBytes(self.allocator, span) catch return;
        self.preedit_doc = doc;
        doc = undefined;
        self.preedit_layout = Layout.init(self.allocator, &self.book);
        self.preedit_layout.?.tab_cols = self.tab_width;
        var byte: usize = 0;
        var seen: usize = 0;
        while (byte < span.len and seen < cursor_chars) : (seen += 1) {
            byte += std.unicode.utf8ByteSequenceLength(span[byte]) catch 1;
        }
        self.preedit_cursor = @min(byte, span.len);
        self.noteActivity();
    }

    fn onPreedit(user: ?*anyopaque, text: []const u8, cursor_chars: usize) void {
        const self = cast.userData(EditorView, user);
        self.setPreedit(text, cursor_chars);
        if (self.active) |tab| self.ensureCaretVisible(tab);
        self.queueRender();
    }

    fn onPreeditEndCb(user: ?*anyopaque) void {
        const self = cast.userData(EditorView, user);
        // Composition ended (committed or cancelled): drop a pending
        // announcement so a composition the user abandoned is not read
        // out after the fact.
        self.a11y_src.clearPreedit();
        self.clearPreedit();
        self.queueRender();
    }

    /// AdwTabView's Ctrl+Home / Ctrl+End shortcuts are MANAGED scope,
    /// i.e. handled by the window in the capture phase — they beat any
    /// controller on the focused widget, so without this the editor's
    /// document-edge keys silently switched window tabs instead. Lift
    /// them only while the canvas has focus; the terminal and browser
    /// keep them untouched.
    fn suppressTabViewEdgeKeys(self: *EditorView, suppress: bool) void {
        const win = self.ownerWindow() orelse return;
        const edge: c.AdwTabViewShortcuts = @intCast(
            c.ADW_TAB_VIEW_SHORTCUT_CONTROL_HOME | c.ADW_TAB_VIEW_SHORTCUT_CONTROL_END,
        );
        const cur = c.adw_tab_view_get_shortcuts(win.tab_view);
        const next: c.AdwTabViewShortcuts = if (suppress) cur & ~edge else cur | edge;
        if (next != cur) c.adw_tab_view_set_shortcuts(win.tab_view, next);
    }

    fn onFocusEnter(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        if (self.im) |im| im.focusIn();
        self.suppressTabViewEdgeKeys(true);
        // Coming back to the editor is exactly when a stale buffer
        // starts to matter (this also covers the toplevel regaining
        // activation: GTK drops widget focus while the window is not
        // active).
        self.checkDisk();
        self.noteActivity();
        self.queueRender();
    }

    fn onFocusLeave(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        if (self.im) |im| im.focusOut();
        self.suppressTabViewEdgeKeys(false);
        self.clearPreedit();
        self.caret_on = true;
        self.queueRender();
    }

    // ---- find / replace -------------------------------------------------

    fn findOptions(self: *EditorView) search.Options {
        return .{
            .case_sensitive = c.gtk_toggle_button_get_active(@ptrCast(self.find_case)) != 0,
            .whole_word = c.gtk_toggle_button_get_active(@ptrCast(self.find_word)) != 0,
            .regex = c.gtk_toggle_button_get_active(@ptrCast(self.find_regex)) != 0,
        };
    }

    /// GtkEditable-based so it works for the GtkSearchEntry needle and
    /// the plain GtkEntry replace field alike.
    fn entryText(w: *c.GtkWidget) []const u8 {
        const buf = c.gtk_editable_get_text(@ptrCast(w));
        if (buf == null) return "";
        const z: [*:0]const u8 = @ptrCast(buf);
        return z[0..std.mem.len(z)];
    }

    /// Open (or focus) the find bar; `replace` also reveals the second
    /// row. A selection on one line seeds the needle.
    pub fn openFind(self: *EditorView, replace: bool) void {
        const tab = self.active orelse return;
        if (!self.find_open) {
            const sel = tab.sels.primary();
            if (!sel.isCaret() and sel.end() - sel.start() < 120) {
                const text = tab.doc.rope.sliceAlloc(self.allocator, sel.start(), sel.end()) catch null;
                if (text) |t| {
                    defer self.allocator.free(t);
                    if (std.mem.indexOfScalar(u8, t, '\n') == null) {
                        const z = self.allocator.dupeZ(u8, t) catch null;
                        if (z) |zz| {
                            defer self.allocator.free(zz);
                            c.gtk_editable_set_text(@ptrCast(self.find_entry), zz.ptr);
                        }
                    }
                }
            }
        }
        self.find_open = true;
        c.gtk_widget_set_visible(self.find_bar, 1);
        c.gtk_widget_set_visible(self.replace_row, if (replace) 1 else 0);
        // With a needle already typed, Ctrl+H should land in the
        // replacement field; otherwise the needle comes first.
        if (replace and entryText(self.find_entry).len > 0) {
            _ = c.gtk_widget_grab_focus(self.replace_entry);
        } else {
            _ = c.gtk_widget_grab_focus(self.find_entry);
            c.gtk_editable_select_region(@ptrCast(self.find_entry), 0, -1);
        }
        self.recomputeMatches(tab, true);
    }

    fn closeFind(self: *EditorView) void {
        if (!self.find_open) return;
        self.find_open = false;
        c.gtk_widget_set_visible(self.find_bar, 0);
        if (self.active) |tab| tab.clearMatches();
        _ = c.gtk_widget_grab_focus(@ptrCast(self.area));
        self.queueRender();
    }

    /// Re-run the search for the active needle. `select` moves the
    /// current match to the one nearest the caret.
    fn recomputeMatches(self: *EditorView, tab: *ETab, select: bool) void {
        const needle = entryText(self.find_entry);
        if (tab.needle.len > 0) self.allocator.free(tab.needle);
        tab.needle = self.allocator.dupe(u8, needle) catch &.{};
        tab.clearMatches();
        self.find_bad_pattern = false;
        if (needle.len > 0) {
            tab.matches = search.findAll(self.allocator, &tab.doc, needle, self.findOptions()) catch |e| blk: {
                // A pattern the user is still typing is invalid most of
                // the time; that is a label, not an error dialog.
                self.find_bad_pattern = e != error.OutOfMemory;
                break :blk &.{};
            };
        }
        if (select and tab.matches.len > 0) {
            tab.current_match = search.pick(tab.matches, tab.sels.primary().start(), true);
        }
        self.updateFindCount(tab);
        self.queueRender();
    }

    fn updateFindCount(self: *EditorView, tab: *ETab) void {
        var buf: [40:0]u8 = undefined;
        const txt: [:0]const u8 = if (self.find_bad_pattern)
            "Bad pattern"
        else if (tab.matches.len == 0)
            (if (entryText(self.find_entry).len == 0) "" else "No results")
        else if (tab.current_match) |i|
            std.fmt.bufPrintZ(&buf, "{d} of {d}", .{ i + 1, tab.matches.len }) catch ""
        else
            std.fmt.bufPrintZ(&buf, "{d} matches", .{tab.matches.len}) catch "";
        c.gtk_label_set_text(self.find_count, txt.ptr);
    }

    /// Step to the next/previous match (wrapping) and select it.
    fn stepMatch(self: *EditorView, forward: bool) void {
        const tab = self.active orelse return;
        if (!std.mem.eql(u8, tab.needle, entryText(self.find_entry))) self.recomputeMatches(tab, false);
        if (tab.matches.len == 0) {
            self.updateFindCount(tab);
            return;
        }
        const caret = tab.sels.primary();
        const from = if (forward) caret.end() else caret.start();
        // Stepping off the match we are sitting on, not onto it again.
        var idx = search.pick(tab.matches, from, forward) orelse return;
        if (search.indexOfRange(tab.matches, caret.start(), caret.end())) |cur| {
            if (idx == cur) {
                idx = if (forward)
                    (cur + 1) % tab.matches.len
                else
                    (cur + tab.matches.len - 1) % tab.matches.len;
            }
        }
        tab.current_match = idx;
        const m = tab.matches[idx];
        tab.sels.keepPrimaryOnly();
        tab.sels.sels.items[0] = .{ .anchor = m.start, .head = m.end };
        tab.goal_x = null;
        // A match inside a folded region unfolds it, for the same
        // reason goto does.
        self.revealCaretLines(tab);
        self.updateFindCount(tab);
        self.ensureCaretVisible(tab);
        self.updateStatus();
        self.queueRender();
    }

    /// Compiled needle for the replace paths, or null in literal mode
    /// (and when the pattern does not compile, which the count label
    /// has already reported).
    fn replaceRegex(self: *EditorView, tab: *ETab) ?search.Regex {
        const opts = self.findOptions();
        if (!opts.regex) return null;
        return search.Regex.init(self.allocator, tab.needle, opts) catch null;
    }

    fn replaceCurrent(self: *EditorView) void {
        const tab = self.active orelse return;
        const idx = tab.current_match orelse {
            self.stepMatch(true);
            return;
        };
        if (idx >= tab.matches.len) return;
        const m = tab.matches[idx];
        const template = entryText(self.replace_entry);

        // In regex mode the replacement is the template EXPANDED against
        // this match's captures, so it differs per match.
        var expanded: std.ArrayList(u8) = .empty;
        defer expanded.deinit(self.allocator);
        var with = template;
        if (self.replaceRegex(tab)) |re_val| {
            var re = re_val;
            defer re.deinit();
            const caps = (re.capturesAt(&tab.doc, m.start) catch null) orelse return;
            re.expand(&tab.doc, caps, template, &expanded) catch return;
            with = expanded.items;
        } else if (self.findOptions().regex) return;

        tab.sels.keepPrimaryOnly();
        tab.sels.sels.items[0] = .{ .anchor = m.start, .head = m.end };
        vm.insertText(self.allocator, &tab.doc, &tab.sels, with) catch return;
        self.afterDocEdit(tab);
        self.stepMatch(true);
    }

    /// Every match replaced in ONE transaction, so it is one undo step.
    fn replaceAll(self: *EditorView) void {
        const tab = self.active orelse return;
        self.recomputeMatches(tab, false);
        if (tab.matches.len == 0) return;
        const template = entryText(self.replace_entry);
        var tx = tr.Transaction.init(tab.doc.revision);
        defer tx.deinit(self.allocator);

        // The transaction BORROWS its inserted slices, so every expanded
        // replacement has to outlive the apply — hence the arena.
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var re_opt = self.replaceRegex(tab);
        defer if (re_opt) |*r| r.deinit();
        if (re_opt == null and self.findOptions().regex) return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var prev_end: usize = 0;
        var applied: usize = 0;
        for (tab.matches) |m| {
            if (m.start < prev_end) continue; // overlapping (can't happen, defensive)
            var with = template;
            if (re_opt) |*re| {
                buf.clearRetainingCapacity();
                const caps = (re.capturesAt(&tab.doc, m.start) catch null) orelse continue;
                re.expand(&tab.doc, caps, template, &buf) catch continue;
                with = arena.dupe(u8, buf.items) catch continue;
            }
            tx.addReplace(self.allocator, m.start, m.end - m.start, with) catch return;
            prev_end = m.end;
            applied += 1;
        }
        _ = tab.doc.applyTransactionSel(&tx, vm.snapshotOf(&tab.sels)) catch return;
        tab.sels.mapThrough(tx.edits.items, .editor);
        vm.clampSelections(&tab.doc, &tab.sels);
        var msg_buf: [64:0]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&msg_buf, "Replaced {d} occurrence(s).", .{applied}) catch "Replaced.";
        self.afterDocEdit(tab);
        self.setStatus(msg.ptr);
    }

    /// Post-edit bookkeeping shared by every path that mutates the
    /// document: the layout cache and the row estimate are both keyed
    /// on the document, and open find results go stale.
    /// (The Layout cache and the row estimate self-heal: the former is
    /// keyed on `doc.revision`, the latter on the line count plus the
    /// per-line `note` the renderer makes.)
    fn afterDocEdit(self: *EditorView, tab: *ETab) void {
        // The edit already replayed onto the syntax trees through the
        // document's observer (Document.EditObserver); this only picks
        // the moment to re-parse.
        self.scheduleParse(tab);
        // The fold anchors already mapped through the edit (ETab's
        // second document observer); this re-derives their regions from
        // the fresh tree.
        tab.sel_stack.clear();
        self.syncFolds(tab);
        if (self.find_open) self.recomputeMatches(tab, false);
        // The edit was already captured by the LSP document observer
        // (Document slot 2); this only arms the debounce that flushes
        // it, and lets an open completion list follow the caret.
        if (self.lsp) |m| {
            m.onEdited(tab);
            m.onCaretMoved();
        }
        // Crash recovery: the first edit that dirties a buffer opens its
        // journal slot on the next tick (editor/journal.zig).
        self.armJournal();
        editoroutline.onDocumentChanged(self, tab);
        self.refresh(tab);
    }

    fn onFindChanged(_: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        const tab = self.active orelse return;
        self.recomputeMatches(tab, true);
    }

    fn onFindActivate(_: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        self.stepMatch(true);
    }

    fn onReplaceActivate(_: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        self.replaceCurrent();
    }

    fn onFindOptionToggled(_: *c.GtkToggleButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        const tab = self.active orelse return;
        self.recomputeMatches(tab, true);
    }

    fn onFindNextClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        cast.userData(EditorView, user).stepMatch(true);
    }

    fn onFindPrevClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        cast.userData(EditorView, user).stepMatch(false);
    }

    fn onFindCloseClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        cast.userData(EditorView, user).closeFind();
    }

    /// GtkSearchEntry "stop-search" (Esc in the entry). The bar's own
    /// capture-phase Esc handler normally wins; this is the backstop.
    fn onFindStop(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
        cast.userData(EditorView, user).closeFind();
    }

    fn onReplaceClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        cast.userData(EditorView, user).replaceCurrent();
    }

    fn onReplaceAllClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        cast.userData(EditorView, user).replaceAll();
    }

    fn onFindKey(
        _: *c.GtkEventControllerKey,
        keyval: c_uint,
        _: c_uint,
        state: c.GdkModifierType,
        user: ?*anyopaque,
    ) callconv(.c) c.gboolean {
        const self = cast.userData(EditorView, user);
        const mods = state & input.SIGNIFICANT_MODS;
        const shift = (mods & c.GDK_SHIFT_MASK) != 0;
        const ctrl = (mods & c.GDK_CONTROL_MASK) != 0;
        // Ctrl+F / Ctrl+H must also work from INSIDE the bar (the
        // canvas controller never sees these — the entry has focus).
        if (ctrl and !shift) {
            switch (c.gdk_keyval_to_lower(keyval)) {
                c.GDK_KEY_f => {
                    self.openFind(false);
                    return 1;
                },
                c.GDK_KEY_h => {
                    self.openFind(true);
                    return 1;
                },
                else => {},
            }
        }
        switch (keyval) {
            c.GDK_KEY_Escape => {
                self.closeFind();
                return 1;
            },
            c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => {
                // Shift+Enter steps backwards from either entry; plain
                // Enter in the replace entry replaces (its "activate").
                if (shift) {
                    self.stepMatch(false);
                    return 1;
                }
                return 0;
            },
            else => return 0,
        }
    }

    // ---- shared post-edit refresh ------------------------------------

    /// Feed the pane's inner titlebar the active document's name
    /// (with a dirty marker) while the editor face is the one showing.
    fn applyPaneFaceTitle(self: *EditorView) void {
        const pane = self.pane orelse return;
        if (!pane.editorFaceVisible()) return;
        const tab = self.active orelse return;
        const name = tab.title();
        var buf: [300]u8 = undefined;
        const txt = if (tab.isDirty())
            std.fmt.bufPrint(&buf, "{s} *", .{name}) catch name
        else
            name;
        pane.setFaceTitle(txt);
    }

    fn refresh(self: *EditorView, tab: *ETab) void {
        if (self.widgets_dead) return;
        tab.handle.setTitle(tab.title());
        tab.handle.setDirty(tab.isDirty());
        if (tab == self.active) self.applyPaneFaceTitle();
        self.noteActivity();
        self.ensureCaretVisible(tab);
        self.updateStatus();
        self.queueRender();
    }

    /// `docview.Target` resolver for the AT-SPI document source: the
    /// ACTIVE tab's rope + selections. Null while a tab is still
    /// loading — its `doc` is an empty placeholder that would be
    /// announced as a wiped document.
    fn a11yTarget(ctx: *anyopaque) ?docview.Target {
        const self: *EditorView = @ptrCast(@alignCast(ctx));
        if (self.widgets_dead) return null;
        const tab = self.active orelse return null;
        if (tab.loading) return null;
        return .{ .doc = &tab.doc, .sels = &tab.sels };
    }

    /// Keep the canvas's accessible label on the active document's file
    /// name (the reader announces "main.zig" on focus, not "Editor"),
    /// and tell the bridge the text/caret/selection may have moved.
    /// Coalesced and gated on an attached AT inside the bridge.
    fn a11yRefresh(self: *EditorView) void {
        if (self.widgets_dead) return;
        const name: []const u8 = if (self.active) |t| t.title() else "Editor";
        const n = @min(name.len, self.a11y_label.len - 1);
        if (!std.mem.eql(u8, self.a11y_label[0..n], name[0..n]) or self.a11y_label[n] != 0) {
            @memcpy(self.a11y_label[0..n], name[0..n]);
            self.a11y_label[n] = 0;
            a11y.setLabel(@ptrCast(self.area), @ptrCast(&self.a11y_label));
        }
        a11y.notifyChanged(@ptrCast(self.area));
    }

    fn updateStatus(self: *EditorView) void {
        if (self.widgets_dead) return;
        // Every caret move, edit, tab switch and dirty-flag change
        // funnels through here, so this is also where the screen
        // reader's view of the canvas is refreshed.
        self.a11yRefresh();
        // Every path that changes the caret, the active tab, the tab
        // set or a dirty flag funnels through here, so this is the one
        // place a standalone host has to watch to keep its window title
        // honest.
        if (self.on_changed) |cb| cb(self.changed_ctx orelse undefined);
        const note = self.statusNote() orelse "";
        const tab = self.active orelse return self.paintStatus("", note);
        var buf: [520:0]u8 = undefined;
        if (tab.loading) return self.paintStatus("Loading…", note);
        const lc = tab.doc.rope.offsetToLineCol(tab.sels.primary().head);
        const carets = tab.sels.count();
        const wrap_note: []const u8 = if (tab.wrap) "  —  Wrap" else "";
        // The diagnostic under the caret (or the document's error /
        // warning counts) rides the same line — the editor has no
        // second status surface to put it on.
        var lsp_buf: [260]u8 = undefined;
        const lsp_note: []const u8 = if (self.lsp) |m| m.statusSummary(tab, &lsp_buf) else "";
        // Project + gutter summary. Empty string for a loose file, so a
        // document with no project reads exactly as it always did.
        var proj_buf: [160]u8 = undefined;
        const proj_note = editorproj.statusFragment(self, tab, &proj_buf);
        const txt = if (carets > 1)
            std.fmt.bufPrint(&buf, "Ln {d}, Col {d}  —  {d} carets{s}{s}{s}", .{ lc.line + 1, lc.col + 1, carets, wrap_note, lsp_note, proj_note }) catch return
        else
            std.fmt.bufPrint(&buf, "Ln {d}, Col {d}{s}{s}{s}", .{ lc.line + 1, lc.col + 1, wrap_note, lsp_note, proj_note }) catch return;
        self.paintStatus(txt, note);
    }

    /// The composed status line: what the document IS (position, wrap,
    /// diagnostics, project) plus whatever transient message is still
    /// live, in that order. The message goes LAST so the standing
    /// facts never move around under the eye when one arrives.
    fn paintStatus(self: *EditorView, base: []const u8, note: []const u8) void {
        var out: [900:0]u8 = undefined;
        const txt = blk: {
            if (note.len == 0) break :blk std.fmt.bufPrintZ(&out, "{s}", .{base}) catch return;
            if (base.len == 0) break :blk std.fmt.bufPrintZ(&out, "{s}", .{note}) catch return;
            break :blk std.fmt.bufPrintZ(&out, "{s}  —  {s}", .{ base, note }) catch return;
        };
        c.gtk_label_set_text(self.status_label, txt.ptr);
    }

    /// Post a NUL-terminated message (the in-module spelling; the
    /// exported one is `setStatusText`).
    fn setStatus(self: *EditorView, text: [*:0]const u8) void {
        self.postStatus(std.mem.span(text));
    }

    // ---- sticky transient status --------------------------------------

    /// How long a posted message keeps re-appearing on the status line.
    ///
    /// Long enough to survive the burst of `updateStatus` calls that
    /// the action which produced it causes (a cross-file rename fires
    /// several within a few hundred ms) and to actually be read; short
    /// enough that it is not still sitting there next time the user
    /// looks at the line for the caret position.
    ///
    /// ONE duration for every message, errors included. The editor has
    /// no error/info channel distinction at any call site (they are all
    /// `setStatusText`), and inventing one would mean reclassifying
    /// forty LSP call sites on a guess about which sentences are
    /// "errors" — several of them ("Already formatted.", "No results.")
    /// are neither. A message that must not be missed does not belong
    /// on a dim one-line label at all; that is what the inline banners
    /// are for.
    pub const STATUS_NOTE_MS: i64 = 8_000;

    /// Post `text` to the status line for `STATUS_NOTE_MS`.
    ///
    /// A newer message REPLACES an older one unconditionally: each is
    /// the answer to the most recent thing the user asked for, and
    /// holding the previous answer on screen would be answering the
    /// wrong question.
    pub fn postStatus(self: *EditorView, text: []const u8) void {
        if (self.widgets_dead) return;
        const n = @min(text.len, self.note.len);
        @memcpy(self.note[0..n], text[0..n]);
        self.note_len = n;
        self.note_at_ms = clock.nowMs();
        self.armNoteExpiry();
        self.updateStatus();
    }

    /// Drop the posted message now. Escape on the canvas does this
    /// (without consuming the key).
    pub fn clearStatusNote(self: *EditorView) void {
        if (self.note_len == 0) return;
        self.note_len = 0;
        self.stopNoteExpiry();
        self.updateStatus();
    }

    /// The live message, or null once it has expired.
    fn statusNote(self: *EditorView) ?[]const u8 {
        if (self.note_len == 0) return null;
        if (clock.nowMs() -| self.note_at_ms > STATUS_NOTE_MS) {
            self.note_len = 0;
            return null;
        }
        return self.note[0..self.note_len];
    }

    fn armNoteExpiry(self: *EditorView) void {
        self.stopNoteExpiry();
        self.note_timer = c.g_timeout_add(
            @intCast(STATUS_NOTE_MS + 50),
            @ptrCast(&onNoteExpiry),
            @ptrCast(self),
        );
    }

    fn stopNoteExpiry(self: *EditorView) void {
        if (self.note_timer == 0) return;
        _ = c.g_source_remove(self.note_timer);
        self.note_timer = 0;
    }

    fn onNoteExpiry(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(EditorView, user);
        self.note_timer = 0;
        if (self.widgets_dead) return 0;
        // statusNote() re-checks the clock, so a note re-posted since
        // this timer was armed simply keeps its own (later) deadline —
        // armNoteExpiry cancelled this source in that case anyway.
        self.updateStatus();
        return 0; // G_SOURCE_REMOVE
    }

    // ---- IO -----------------------------------------------------------

    fn startLoad(self: *EditorView, tab: *ETab) void {
        self.startLoadEx(tab, false);
    }

    fn startLoadEx(self: *EditorView, tab: *ETab, keep_position: bool) void {
        const spec = tab.spec orelse return;
        const a = std.heap.c_allocator;
        const job = a.create(IoJob) catch return;
        const owned = a.dupe(u8, spec) catch {
            a.destroy(job);
            return;
        };
        self.fence.ref();
        tab.io_gen = self.next_io_gen;
        self.next_io_gen += 1;
        job.* = .{
            .fence = self.fence,
            .gen = tab.io_gen,
            .kind = .load,
            .spec = owned,
            .keep_position = keep_position,
        };
        tab.loading = true;
        self.updateStatus();
        const thread = std.Thread.spawn(.{}, ioThread, .{job}) catch {
            tab.loading = false;
            tab.io_gen = 0;
            job.destroy();
            return;
        };
        thread.detach();
    }

    pub fn saveTab(self: *EditorView, tab: *ETab) void {
        if (tab.loading) {
            self.setStatus("Still loading — try again in a moment.");
            return;
        }
        if (tab.io_gen != 0) {
            self.setStatus("A save is already in flight.");
            return;
        }
        if (tab.spec == null) {
            self.saveTabAs(tab);
            return;
        }
        // The guarded save IS the before-save disk check: the daemon
        // compares the baseline against the destination inside the
        // install, which no client-side poll can do race-free.
        const guard: ?i64 = if (tab.disk.present and tab.disk.mtime_ns != 0) tab.disk.mtime_ns else null;
        self.startSave(tab, guard);
    }

    fn startSave(self: *EditorView, tab: *ETab, expected_mtime: ?i64) void {
        const spec = tab.spec orelse return;
        const a = std.heap.c_allocator;
        const bytes = tab.doc.materialize(a) catch return;
        const job = a.create(IoJob) catch {
            a.free(bytes);
            return;
        };
        const owned = a.dupe(u8, spec) catch {
            a.free(bytes);
            a.destroy(job);
            return;
        };
        self.fence.ref();
        tab.io_gen = self.next_io_gen;
        self.next_io_gen += 1;
        job.* = .{
            .fence = self.fence,
            .gen = tab.io_gen,
            .kind = .save,
            .spec = owned,
            .save_bytes = bytes,
            .expected_mtime = expected_mtime,
            .revision = tab.doc.revision,
        };
        self.setStatus("Saving…");
        const thread = std.Thread.spawn(.{}, ioThread, .{job}) catch {
            tab.io_gen = 0;
            job.destroy();
            return;
        };
        thread.detach();
    }

    fn onIoDone(self: *EditorView, job: *IoJob) void {
        const tab = self.findTabByGen(job.gen) orelse return;
        tab.io_gen = 0;
        switch (job.kind) {
            .load => {
                tab.loading = false;
                if (job.binary) {
                    self.errorDialog("Cannot edit binary file", job.errText());
                    self.closeTabForce(tab);
                    return;
                }
                if (!job.ok) {
                    self.errorDialog("Could not open file", job.errText());
                    self.closeTabForce(tab);
                    return;
                }
                if (job.not_found) {
                    // New file (or an unreadable one): keep the empty
                    // document and record NO baseline, so the disk
                    // probe stays silent about a file we never read.
                    tab.disk = .{};
                    tab.keep_active = false;
                    self.clearAlert(tab);
                    // No document-replace rides on this branch, so the
                    // (empty, but now FINAL) buffer has to be opened on
                    // the server from here — `openDocument` defers
                    // while `loading` is set, which it no longer is.
                    if (self.lsp) |m| m.ensureOpen(tab) else self.attachLsp(tab);
                    self.setStatus("New file.");
                    self.refresh(tab);
                    return;
                }
                if (job.keep_position and tab.keep_active) {
                    self.finishReloadInPlace(tab, job);
                    return;
                }
                var new_doc = Document.initFromBytes(self.allocator, job.bytes) catch {
                    self.errorDialog("Could not open file", "OutOfMemory");
                    self.closeTabForce(tab);
                    return;
                };
                tab.doc.deinit();
                tab.doc = new_doc;
                new_doc = undefined;
                // The loaded text is a different document: re-detect
                // the language (a shebang only becomes visible now) and
                // re-attach the observer the swap just dropped.
                self.ensureHighlighter(tab);
                // Folds anchor into the OLD document's byte space and
                // the trail describes its offsets; both die with it.
                tab.folds.clear();
                tab.folds_epoch += 1;
                tab.folds_valid = false;
                tab.fm_valid = false;
                tab.br_valid = false;
                tab.sel_stack.clear();
                tab.doc.addObserver(.{ .ctx = tab, .before_apply = ETab.observeEdits });
        tab.doc.addObserver(self.a11y_src.editObserver());
                // The observer the swap dropped has to be re-installed
                // and the server told the content changed wholesale;
                // a first-time load is where the server is attached.
                if (self.lsp) |m| m.onDocumentReplaced(tab) else self.attachLsp(tab);
                tab.layout.invalidateAll();
                tab.rows_lines = 0;
                tab.anchor = .{};
                tab.scroll_x = 0;
                tab.max_width = 0;
                self.applyWrapWidth(tab);
                tab.disk = job.disk;
                tab.seen = job.disk;
                self.clearAlert(tab);
                {
                    const caret = @min(tab.want_cursor orelse 0, tab.doc.rope.len());
                    tab.want_cursor = null;
                    tab.sels.keepPrimaryOnly();
                    tab.sels.sels.items[0] = Selection.caret(caret);
                }
                if (tab.want_pos) |p| {
                    tab.want_pos = null;
                    self.applyWantPos(tab, p);
                } else if (tab.want_top_line) |top| {
                    // Restored scroll: a LINE, so it survives a
                    // different pane width and wrap setting. Applied
                    // only when nothing else claimed the viewport.
                    tab.want_top_line = null;
                    const lines = tab.doc.rope.lineCount();
                    tab.anchor = .{ .line = @min(top, lines -| 1), .row = 0, .offset = 0 };
                }
                self.noteSavedHash(tab);
                tab.keep_active = false;
                // The document is new: its project may be too, and the
                // gutter marks anchored into the old byte space are gone.
                tab.git.clear();
                tab.outline.clear();
                tab.outline_rev = 0;
                editorproj.resolveProject(self, tab);
                editorproj.refreshGit(self, tab);
                editoroutline.refresh(self, tab, true);
                self.refresh(tab);
            },
            .save => {
                if (job.conflict) {
                    tab.close_after_save = false;
                    // NOT a modal: the same inline banner the probe
                    // raises, so a refused save and an observed change
                    // can never produce two competing prompts.
                    tab.seen = job.disk;
                    tab.dismissed = null;
                    tab.alert = .changed;
                    tab.alert_from_save = true;
                    self.updateBanner();
                    self.setStatus("Save refused: the file changed on disk.");
                    return;
                }
                if (!job.ok) {
                    tab.close_after_save = false;
                    self.errorDialog("Save failed", job.errText());
                    self.updateStatus();
                    return;
                }
                tab.disk = job.disk;
                tab.seen = job.disk;
                self.clearAlert(tab);
                if (tab.doc.revision == job.revision) tab.doc.markSaved();
                // Contract step 3: the record goes, the lock stays.
                if (!tab.isDirty()) {
                    if (tab.journal) |*h| h.clear();
                }
                self.noteSavedHash(tab);
                if (self.lsp) |m| m.onSaved(tab);
                editorproj.refreshGit(self, tab);
                if (tab.close_after_save) {
                    tab.close_after_save = false;
                    if (!tab.isDirty()) {
                        self.closeTabForce(tab);
                        return;
                    }
                }
                self.refresh(tab);
                self.setStatus("Saved.");
            },
        }
    }

    /// A reload that KEEPS the document: the arriving bytes are diffed
    /// onto the live buffer as ONE transaction (editor/diff.zig), so
    /// undo restores the pre-reload text, every edit observer
    /// (highlighter, folds/git/outline anchors, LSP didChange, a11y
    /// change log) sees ordinary edits, and carets/selections map
    /// through instead of clamping.
    fn finishReloadInPlace(self: *EditorView, tab: *ETab, job: *IoJob) void {
        tab.keep_active = false;
        const changed = ediff.reloadFromBytes(self.allocator, &tab.doc, job.bytes, &tab.sels) catch {
            // Out of memory mid-diff: the transaction applied atomically
            // or not at all, so the buffer is intact — just stale.
            self.setStatus("Reload failed: out of memory.");
            return;
        };
        tab.disk = job.disk;
        tab.seen = job.disk;
        self.clearAlert(tab);
        self.noteSavedHash(tab);
        // Contract step 3 (same as a save): clean buffer, record goes.
        if (!tab.isDirty()) {
            if (tab.journal) |*h| h.clear();
        }
        if (!changed) {
            self.refresh(tab);
            return;
        }
        // A changed line count moves the whole row estimate.
        tab.rows_lines = 0;
        // A reload only changes the language via a new shebang. The
        // same language keeps the incrementally-updated tree (the
        // highlighter observer already saw the edits) and just needs
        // the debounced re-parse; a different one swaps grammars.
        if (!std.meta.eql(self.detectLang(tab), tab.hl_lang)) {
            self.ensureHighlighter(tab);
        } else {
            self.scheduleParse(tab);
        }
        self.clampAnchor(tab, self.viewportHeightPx());
        editorproj.refreshGit(self, tab);
        editoroutline.refresh(self, tab, true);
        self.refresh(tab);
        self.setStatus("Reloaded: the file changed on disk.");
    }

    fn errorDialog(self: *EditorView, heading: [*:0]const u8, detail: []const u8) void {
        var body: [200:0]u8 = undefined;
        const b = std.fmt.bufPrintZ(&body, "{s}", .{detail}) catch "unknown error";
        _ = confirm.present(self.dialogParent(), .{
            .heading = heading,
            .body = b.ptr,
            .responses = &.{
                .{ .id = "ok", .label = "OK", .is_default = true, .is_close = true },
            },
        }, null);
    }

    // ---- external-change detection -------------------------------------
    //
    // Detection is a BATCHED STAT POLL, not a daemon directory watch.
    // The daemon's live views (`open_view`) are directory-scoped: they
    // cost a full stat-per-entry listing of the containing directory
    // (opening one file in a huge tree would list thousands of
    // siblings), they need a persistent connection parked on the GLib
    // loop (which for a remote host cannot be established without a
    // worker thread — the thing the GUI must not grow), and their
    // inotify backend is Linux-only, so a remote macOS/BSD host would
    // behave DIFFERENTLY. They also carry no IN_MODIFY, so a writer
    // holding the fd open produces nothing until close — a poll is
    // needed as a backstop regardless.
    //
    // A stat probe has none of that: one connection per HOST carries
    // every open document's stat (so twenty tabs in one directory —
    // or twenty directories — are one round trip, strictly stronger
    // than per-(host, dir) dedupe), it is identical local and remote,
    // and it runs on the same detached-thread + g_idle_add path the
    // loads and saves already use. It fires when the user comes back
    // to the editor (canvas focus, pane focus, tab switch), which is
    // exactly when a stale buffer starts to matter, and the save path
    // is guarded by the daemon-side mtime check, which is race-free in
    // a way no poll can be.

    /// Rate limit: focus-in storms (click, alt-tab, tab switch) must
    /// not turn into a round trip each.
    const PROBE_MIN_INTERVAL_MS: i64 = 400;

    /// Probe every open document's file for external changes. Cheap,
    /// idempotent and safe to call from any user-facing event.
    pub fn checkDisk(self: *EditorView) void {
        if (self.widgets_dead) return;
        if (self.probes_in_flight > 0) return;
        const now = @import("../util/clock.zig").nowMs();
        if (now - self.last_probe_ms < PROBE_MIN_INTERVAL_MS) return;
        self.last_probe_ms = now;

        const a = std.heap.c_allocator;
        var hosts: std.ArrayList([]const u8) = .empty;
        defer hosts.deinit(a);
        for (self.tabs.items) |t| {
            const spec = t.spec orelse continue;
            if (t.io_gen != 0 or t.loading) continue;
            const host = paths.parseSpec(spec).host orelse "";
            var seen = false;
            for (hosts.items) |h| {
                if (std.mem.eql(u8, h, host)) seen = true;
            }
            if (!seen) hosts.append(a, host) catch return;
        }
        for (hosts.items) |host| self.probeHost(host);
    }

    /// One probe job for every document on `host` — one connection,
    /// one thread, N stats.
    fn probeHost(self: *EditorView, host: []const u8) void {
        const a = std.heap.c_allocator;
        var items: std.ArrayList(ProbeItem) = .empty;
        defer items.deinit(a);
        for (self.tabs.items) |t| {
            const spec = t.spec orelse continue;
            if (t.io_gen != 0 or t.loading) continue;
            const loc = paths.parseSpec(spec);
            if (!std.mem.eql(u8, loc.host orelse "", host)) continue;
            const path = a.dupe(u8, loc.path) catch continue;
            items.append(a, .{ .tab_id = t.id, .path = path }) catch {
                a.free(path);
                continue;
            };
        }
        if (items.items.len == 0) return;
        const owned_items = items.toOwnedSlice(a) catch return;
        const owned_host = a.dupe(u8, host) catch {
            for (owned_items) |it| a.free(it.path);
            a.free(owned_items);
            return;
        };
        const job = a.create(ProbeJob) catch {
            for (owned_items) |it| a.free(it.path);
            a.free(owned_items);
            a.free(owned_host);
            return;
        };
        self.fence.ref();
        job.* = .{ .fence = self.fence, .host = owned_host, .items = owned_items };
        self.probes_in_flight += 1;
        const thread = std.Thread.spawn(.{}, probeThread, .{job}) catch {
            self.probes_in_flight -= 1;
            job.destroy();
            return;
        };
        thread.detach();
    }

    fn onProbeDone(self: *EditorView, job: *ProbeJob) void {
        if (self.probes_in_flight > 0) self.probes_in_flight -= 1;
        if (self.widgets_dead) return;
        for (job.items) |it| {
            // A probe that could not be TAKEN (dead link, unreachable
            // host) says nothing — it must never read as "deleted".
            if (!it.ok) continue;
            const tab = self.findTabById(it.tab_id) orelse continue;
            // A load/save started after the probe owns the baseline.
            if (tab.io_gen != 0 or tab.loading) continue;
            self.applyDiskState(tab, it.state);
        }
        self.updateBanner();
    }

    /// The whole external-change state machine for one document.
    fn applyDiskState(self: *EditorView, tab: *ETab, obs: reload.DiskState) void {
        tab.seen = obs;
        switch (reload.compare(tab.disk, obs)) {
            .unchanged => {
                // Reverted underneath us: a banner about a change that
                // is no longer there is noise.
                if (tab.alert != .none) self.clearAlert(tab);
                tab.dismissed = null;
            },
            .permissions => {
                // Content is identical; only the bits moved. Re-baseline
                // silently so the next save is not refused for it.
                tab.disk.mode = obs.mode;
                self.setStatus("Permissions changed on disk.");
            },
            .deleted => {
                if (tab.dismissed) |d| {
                    if (reload.sameState(d, obs)) return;
                }
                // Keep the content; the buffer is simply no longer
                // backed by a file, and Save recreates it (the absent
                // baseline drops the conflict guard).
                tab.disk = obs;
                tab.dismissed = null;
                tab.alert = .deleted;
                tab.alert_from_save = false;
            },
            .modified, .replaced, .reappeared => {
                if (tab.dismissed) |d| {
                    if (reload.sameState(d, obs)) return;
                }
                tab.dismissed = null;
                if (!tab.isDirty()) {
                    // Clean buffer: reload quietly, keeping the caret
                    // and the scroll position. No prompt — that is what
                    // good editors do.
                    self.reloadKeepingPosition(tab);
                    return;
                }
                tab.alert = .changed;
                tab.alert_from_save = false;
            },
        }
    }

    fn reloadKeepingPosition(self: *EditorView, tab: *ETab) void {
        tab.keep_active = true;
        self.startLoadEx(tab, true);
    }

    // ---- the inline banner ----------------------------------------------

    fn clearAlert(self: *EditorView, tab: *ETab) void {
        tab.alert = .none;
        tab.alert_from_save = false;
        tab.dismissed = null;
        self.updateBanner();
    }

    /// Render the ACTIVE tab's alert (each document carries its own).
    fn updateBanner(self: *EditorView) void {
        if (self.widgets_dead) return;
        const tab = self.active orelse {
            c.gtk_widget_set_visible(self.banner_box, 0);
            return;
        };
        if (tab.alert == .none) {
            c.gtk_widget_set_visible(self.banner_box, 0);
            return;
        }
        var buf: [320:0]u8 = undefined;
        const text: [:0]const u8 = switch (tab.alert) {
            .none => unreachable,
            .changed => if (tab.alert_from_save)
                std.fmt.bufPrintZ(&buf, "Save refused: \"{s}\" changed on disk since you opened it.", .{tab.title()}) catch "The file changed on disk."
            else
                std.fmt.bufPrintZ(&buf, "\"{s}\" changed on disk.", .{tab.title()}) catch "The file changed on disk.",
            .deleted => std.fmt.bufPrintZ(&buf, "\"{s}\" no longer exists on disk.", .{tab.title()}) catch "The file no longer exists on disk.",
        };
        c.gtk_label_set_text(self.banner_label, text.ptr);
        c.gtk_widget_set_visible(self.banner_reload, if (tab.alert == .changed) 1 else 0);
        c.gtk_button_set_label(
            @ptrCast(self.banner_save),
            if (tab.alert == .deleted) "Save" else "Save Anyway",
        );
        c.gtk_widget_set_visible(self.banner_box, 1);
    }

    fn onBannerReload(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        const tab = self.active orelse return;
        self.revertTab(tab);
    }

    /// Replace a buffer with the version on disk — the banner's
    /// "Reload", reachable for any tab (the tab context menu's
    /// "Revert"). A dirty buffer asks first; losing unsaved work stays
    /// behind a confirmation.
    pub fn revertTab(self: *EditorView, tab: *ETab) void {
        if (tab.isDirty()) {
            // Losing unsaved work is the one thing that still deserves
            // a confirmation — and it follows a deliberate click.
            self.confirmReloadDirty(tab);
            return;
        }
        self.clearAlert(tab);
        self.reloadKeepingPosition(tab);
    }

    fn onBannerSave(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        const tab = self.active orelse return;
        self.clearAlert(tab);
        // Deliberate overwrite (or re-create): no conflict guard.
        self.startSave(tab, null);
    }

    fn onBannerDismiss(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        const tab = self.active orelse return;
        // Stay quiet for THIS on-disk state only: a further change
        // raises the banner again, and the save baseline is untouched,
        // so Ctrl+S is still refused.
        tab.dismissed = tab.seen;
        tab.alert = .none;
        tab.alert_from_save = false;
        self.updateBanner();
    }

    fn confirmReloadDirty(self: *EditorView, tab: *ETab) void {
        const ctx = DlgCtx.create(self, tab) orelse return;
        if (confirm.present(self.dialogParent(), .{
            .heading = "Discard your changes?",
            .body = "Reloading replaces the buffer with the on-disk version; your unsaved edits are lost.",
            .responses = &.{
                .{ .id = "cancel", .label = "Cancel", .is_default = true, .is_close = true },
                .{ .id = "reload", .label = "Discard and Reload", .appearance = .destructive },
            },
        }, .{ .allocator = self.allocator, .cb = &onReloadDirtyResponse, .ctx = @ptrCast(ctx) }) == null) ctx.destroy();
    }

    fn onReloadDirtyResponse(user: ?*anyopaque, resp: []const u8) void {
        const ctx: *DlgCtx = @ptrCast(@alignCast(user.?));
        defer ctx.destroy();
        const r = ctx.resolve() orelse return;
        if (std.mem.eql(u8, resp, "reload")) {
            r.view.clearAlert(r.tab);
            r.view.reloadKeepingPosition(r.tab);
        }
    }

    // ---- crash recovery -------------------------------------------------
    //
    // Journal writes are DEBOUNCED off one timer for the whole face
    // rather than one per tab: the tick is a cheap walk over the tabs,
    // and a single source is a single thing to disarm at teardown
    // (`stopJournalTimer`, called from every path that kills the
    // widgets, exactly like the blink timer).

    /// Arm the debounce after any edit. No-op when it is already
    /// running or the feature is off.
    fn armJournal(self: *EditorView) void {
        if (!self.crash_recovery or self.journal_timer != 0) return;
        self.journal_timer = c.g_timeout_add(JOURNAL_DEBOUNCE_MS, @ptrCast(&onJournalTimer), @ptrCast(self));
    }

    fn stopJournalTimer(self: *EditorView) void {
        if (self.journal_timer != 0) {
            _ = c.g_source_remove(self.journal_timer);
            self.journal_timer = 0;
        }
    }

    fn onJournalTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(EditorView, user);
        var any = false;
        for (self.tabs.items) |t| {
            if (self.journalTick(t)) any = true;
        }
        if (!any) {
            self.journal_timer = 0;
            return 0;
        }
        return 1;
    }

    /// One tab's snapshot decision. True while the tab still wants the
    /// timer running.
    fn journalTick(self: *EditorView, tab: *ETab) bool {
        if (!self.crash_recovery) {
            if (tab.journal) |*h| {
                h.discard();
                tab.journal = null;
            }
            return false;
        }
        if (!tab.isDirty()) {
            // Clean: drop the snapshot but KEEP the lock, so the slot is
            // still ours when the buffer goes dirty again.
            if (tab.journal) |*h| h.clear();
            return false;
        }
        // Given up on (too large): nothing more to do for this tab, so
        // it must not keep the timer spinning either.
        if (tab.journal_off) return false;
        if (tab.loading) return true;
        if (tab.journal == null) {
            tab.journal = journal.open(self.allocator, tab.spec orelse "") catch {
                tab.journal_off = true;
                return false;
            };
        }
        const h = &tab.journal.?;
        if (!h.shouldWrite(tab.doc.revision)) return true;

        const text = tab.doc.textAlloc(self.allocator) catch return true;
        defer self.allocator.free(text);
        // `isDirty` is a revision comparison, so undoing back to the
        // saved state still reads dirty. Keeping a record for a buffer
        // that is byte-identical to disk would offer the user their own
        // unchanged file as "unsaved work" after a crash, so compare
        // the CONTENT here — the bytes are in hand anyway, which is why
        // this is cheaper than teaching Document a second dirty rule.
        if (tab.saved_hash_valid and std.hash.Wyhash.hash(SAVED_HASH_SEED, text) == tab.saved_hash) {
            h.clear();
            return true;
        }
        var hdr = journal.Header{
            .spec = tab.spec orelse "",
            .remote = if (tab.spec) |s| paths.parseSpec(s).host != null else false,
            .crlf = tab.doc.line_ending == .crlf,
            .revision = tab.doc.revision,
            .saved_revision = tab.doc.saved_revision,
            .cursor = @intCast(tab.sels.primary().head),
        };
        hdr.setBaseline(tab.disk);
        h.write(hdr, text) catch |e| {
            if (e == journal.Error.BufferTooLarge) {
                tab.journal_off = true;
                self.setStatus("Buffer too large for crash recovery — save often.");
            }
            return true;
        };
        return true;
    }

    /// Record the content hash of the buffer as it now sits on disk.
    fn noteSavedHash(self: *EditorView, tab: *ETab) void {
        const text = tab.doc.textAlloc(self.allocator) catch {
            tab.saved_hash_valid = false;
            return;
        };
        defer self.allocator.free(text);
        tab.saved_hash = std.hash.Wyhash.hash(SAVED_HASH_SEED, text);
        tab.saved_hash_valid = true;
    }

    /// Prune stale records and offer whatever a previous run left
    /// behind. Runs ONCE per process, from the first editor face.
    fn offerRecovery(self: *EditorView) void {
        if (recovery_offered or !self.crash_recovery) return;
        recovery_offered = true;
        _ = journal.prune(self.allocator, JOURNAL_MAX_AGE_MS) catch {};
        const entries = journal.list(self.allocator) catch return;
        if (entries.len == 0) {
            journal.freeEntries(self.allocator, entries);
            return;
        }
        self.recovery = entries;
        self.updateRecoverBanner();
    }

    fn dropRecovery(self: *EditorView) void {
        if (self.recovery.len == 0) return;
        journal.freeEntries(self.allocator, self.recovery);
        self.recovery = &.{};
    }

    fn updateRecoverBanner(self: *EditorView) void {
        if (self.widgets_dead) return;
        if (self.recovery.len == 0) {
            c.gtk_widget_set_visible(self.recover_box, 0);
            return;
        }
        var names: [180]u8 = undefined;
        var n: usize = 0;
        for (self.recovery, 0..) |e, i| {
            const name = recoveryName(e.header.spec);
            const sep: []const u8 = if (i == 0) "" else ", ";
            if (n + sep.len + name.len + 4 > names.len) {
                const more = std.fmt.bufPrint(names[n..], ", ...", .{}) catch break;
                n += more.len;
                break;
            }
            @memcpy(names[n .. n + sep.len], sep);
            n += sep.len;
            @memcpy(names[n .. n + name.len], name);
            n += name.len;
        }
        var buf: [320:0]u8 = undefined;
        const text = std.fmt.bufPrintZ(
            &buf,
            "{d} unsaved buffer(s) from a previous session ({s}), last changed {s}: {s}",
            .{
                self.recovery.len,
                if (self.recovery.len == 1) "one editor" else "earlier editors",
                agoText(self.recovery[0].header.updated_ms),
                names[0..n],
            },
        ) catch "Unsaved buffers from a previous session are recoverable.";
        c.gtk_label_set_text(self.recover_label, text.ptr);
        c.gtk_widget_set_visible(self.recover_box, 1);
    }

    fn recoveryName(spec: []const u8) []const u8 {
        if (spec.len == 0) return "Untitled";
        const loc = paths.parseSpec(spec);
        const base = std.fs.path.basename(loc.path);
        return if (base.len == 0) spec else base;
    }

    /// "4 minutes ago" for the banner. Wall clock, because that is what
    /// the record carries and what the user recognises.
    fn agoText(updated_ms: i64) []const u8 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        const now: i64 = @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
        const delta = @max(0, now - updated_ms);
        const mins = @divTrunc(delta, 60_000);
        if (mins < 1) return "moments ago";
        if (mins < 60) return "in the last hour";
        const hours = @divTrunc(mins, 60);
        if (hours < 24) return "earlier today";
        return "over a day ago";
    }

    fn onRecoverClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        const entries = self.recovery;
        self.recovery = &.{};
        defer journal.freeEntries(self.allocator, entries);
        var opened: usize = 0;
        for (entries) |e| {
            if (self.recoverOne(e)) opened += 1;
            // Consumed either way: a record we could not read is
            // corrupt, and one we opened now lives in a tab with its
            // own (fresh) slot.
            journal.remove(self.allocator, e.key) catch {};
        }
        self.updateRecoverBanner();
        var buf: [80:0]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "Recovered {d} unsaved buffer(s).", .{opened}) catch "Recovered.";
        self.setStatus(msg.ptr);
        // Show whether each file moved on since the crash, rather than
        // writing anything back: the ordinary probe compares the
        // recovered baseline and raises the ordinary banner.
        self.last_probe_ms = 0;
        self.checkDisk();
    }

    /// Build one tab from a record: the snapshot's bytes, its caret,
    /// its line-ending style, still DIRTY, and the disk identity it was
    /// taken against as the buffer's baseline.
    fn recoverOne(self: *EditorView, entry: journal.Entry) bool {
        var rec = journal.read(self.allocator, entry.key) catch return false;
        defer rec.deinit(self.allocator);

        // Restore-vs-recover: the layout decides WHICH files are open,
        // the journal decides their CONTENT. A tab already holding this
        // spec is ADOPTED (its in-flight load orphaned) rather than
        // duplicated, so the two can never produce two tabs for one
        // file whichever order they run in — and the unsaved bytes win
        // over the on-disk copy.
        const existing = if (rec.header.spec.len > 0) self.tabForSpec(rec.header.spec) else null;
        const tab = existing orelse self.newTab(null) orelse return false;
        if (existing != null) tab.io_gen = 0;
        if (existing == null and rec.header.spec.len > 0) {
            if (self.allocator.dupe(u8, rec.header.spec)) |s| {
                if (tab.spec) |old| self.allocator.free(old);
                tab.spec = s;
            } else |_| {}
        }
        var new_doc = Document.initFromBytes(self.allocator, rec.content) catch return false;
        // The snapshot is LF-normalized in-memory text, so the style
        // comes from the header, not from sniffing the content.
        new_doc.line_ending = if (rec.header.crlf) .crlf else .lf;
        tab.doc.deinit();
        tab.doc = new_doc;
        tab.doc.markUnsaved();
        tab.doc.addObserver(.{ .ctx = tab, .before_apply = ETab.observeEdits });
        tab.doc.addObserver(self.a11y_src.editObserver());
        self.ensureHighlighter(tab);
        if (self.lsp) |m| m.onDocumentReplaced(tab) else self.attachLsp(tab);
        tab.layout.invalidateAll();
        tab.rows_lines = 0;
        tab.anchor = .{};
        self.applyWrapWidth(tab);
        tab.disk = rec.header.baseline();
        tab.seen = tab.disk;
        // The recovered bytes are NOT what is on disk, so the saved
        // hash must stay unknown or journalTick would drop the record.
        tab.saved_hash_valid = false;
        const caret = @min(@as(usize, @intCast(rec.header.cursor)), tab.doc.rope.len());
        tab.sels.keepPrimaryOnly();
        tab.sels.sels.items[0] = Selection.caret(caret);
        self.refresh(tab);
        self.ensureCaretVisible(tab);
        // Immediately re-journal: a recovered buffer that is never
        // touched must survive a SECOND crash.
        _ = self.journalTick(tab);
        self.armJournal();
        return true;
    }

    fn onRecoverLaterClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        // Only the offer goes away. The records stay on disk and are
        // offered again next launch — declining must never destroy work.
        self.dropRecovery();
        self.updateRecoverBanner();
    }

    fn onRecoverDiscardClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        if (self.recovery.len == 0) return;
        var body: [160:0]u8 = undefined;
        const b = std.fmt.bufPrintZ(
            &body,
            "{d} unsaved buffer(s) from a previous session will be deleted. This cannot be undone.",
            .{self.recovery.len},
        ) catch "These unsaved buffers will be deleted.";
        const ctx = std.heap.c_allocator.create(DlgCtx) catch return;
        self.fence.ref();
        ctx.* = .{ .fence = self.fence, .tab_id = 0 };
        if (confirm.present(self.dialogParent(), .{
            .heading = "Discard recovered work?",
            .body = b.ptr,
            .responses = &.{
                .{ .id = "cancel", .label = "Cancel", .is_default = true, .is_close = true },
                .{ .id = "discard", .label = "Discard", .appearance = .destructive },
            },
        }, .{ .allocator = self.allocator, .cb = &onRecoverDiscardResponse, .ctx = @ptrCast(ctx) }) == null) ctx.destroy();
    }

    fn onRecoverDiscardResponse(user: ?*anyopaque, resp: []const u8) void {
        const ctx: *DlgCtx = @ptrCast(@alignCast(user.?));
        defer ctx.destroy();
        // tab_id 0 never resolves to a tab, so this one uses the fence
        // directly: the records are the view's, not a tab's.
        const view = ctx.fence.viewIfAlive() orelse return;
        if (!std.mem.eql(u8, resp, "discard")) return;
        for (view.recovery) |e| journal.remove(view.allocator, e.key) catch {};
        view.dropRecovery();
        view.updateRecoverBanner();
        view.setStatus("Discarded the recovered snapshots.");
    }

    // ---- Save As / Open pickers ---------------------------------------

    pub fn saveTabAs(self: *EditorView, tab: *ETab) void {
        const ctx = DlgCtx.create(self, tab) orelse return;
        var name_buf: [256]u8 = undefined;
        const suggested: []const u8 = blk: {
            const t = tab.title();
            if (std.mem.eql(u8, t, "Untitled")) break :blk "untitled.txt";
            const n = @min(t.len, name_buf.len);
            @memcpy(name_buf[0..n], t[0..n]);
            break :blk name_buf[0..n];
        };
        const win: ?*c.GtkWindow = if (self.ownerWindow()) |w| @ptrCast(w.app_window) else null;
        _ = PickerWindow.open(self.allocator, win, .{
            .mode = .save_file,
            .title = "Save As",
            .suggested_name = suggested,
        }, &onSaveAsPicked, @ptrCast(ctx)) catch {
            ctx.destroy();
            self.setStatus("Could not open the save dialog.");
        };
    }

    fn onSaveAsPicked(user: ?*anyopaque, result: ?fpicker.Result) void {
        const ctx: *DlgCtx = @ptrCast(@alignCast(user.?));
        defer ctx.destroy();
        const r = ctx.resolve() orelse return;
        const res = result orelse {
            r.tab.close_after_save = false;
            return;
        };
        if (res.specs.len == 0) return;
        const owned = r.view.allocator.dupe(u8, res.specs[0]) catch return;
        if (r.tab.spec) |old| r.view.allocator.free(old);
        r.tab.spec = owned;
        r.tab.disk = .{};
        r.tab.seen = .{};
        r.view.clearAlert(r.tab);
        // "Save As untitled.zig" is the moment the language becomes
        // knowable for a buffer that never had a filename.
        r.view.ensureHighlighter(r.tab);
        r.view.refresh(r.tab);
        r.view.startSave(r.tab, null);
    }

    const OpenCtx = struct {
        fence: *Fence,
    };

    pub fn openPicker(self: *EditorView) void {
        const ctx = std.heap.c_allocator.create(OpenCtx) catch return;
        self.fence.ref();
        ctx.* = .{ .fence = self.fence };
        const win: ?*c.GtkWindow = if (self.ownerWindow()) |w| @ptrCast(w.app_window) else null;
        _ = PickerWindow.open(self.allocator, win, .{
            .mode = .open_files,
            .title = "Open Files",
        }, &onOpenPicked, @ptrCast(ctx)) catch {
            ctx.fence.unref();
            std.heap.c_allocator.destroy(ctx);
            self.setStatus("Could not open the file dialog.");
        };
    }

    fn onOpenPicked(user: ?*anyopaque, result: ?fpicker.Result) void {
        const ctx: *OpenCtx = @ptrCast(@alignCast(user.?));
        defer {
            ctx.fence.unref();
            std.heap.c_allocator.destroy(ctx);
        }
        const view = ctx.fence.viewIfAlive() orelse return;
        const res = result orelse return;
        for (res.specs) |spec| view.openSpec(spec, null);
    }

    // ---- toolbar ------------------------------------------------------

    fn onOpenClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        self.openPicker();
    }

    fn onSaveClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        if (self.active) |tab| self.saveTab(tab);
    }

    fn onSaveAsClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        if (self.active) |tab| self.saveTabAs(tab);
    }

    /// Split into a second editor pane. The pane binding table owns
    /// what a split IS (it can differ per profile), so this forwards
    /// the action rather than reimplementing it.
    fn onSplitClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        const pane = self.pane orelse return;
        const ictx = pane.input_ctx orelse return;
        // splitFocused acts on the WINDOW's focused pane; a toolbar
        // click does not focus anything (the buttons are out of the
        // focus chain), so focus is pointed here first or the action
        // silently hits whichever pane last had it.
        _ = c.gtk_widget_grab_focus(@ptrCast(self.area));
        _ = input.runAction(ictx, .new_editor_split);
    }

    fn onTerminalClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        const pane = self.pane orelse return;
        pane.setEditorVisible(false);
    }

    // ---- editing entry points ----------------------------------------

    fn insertText(self: *EditorView, tab: *ETab, text: []const u8) void {
        vm.insertText(self.allocator, &tab.doc, &tab.sels, text) catch return;
        tab.goal_x = null;
        self.afterDocEdit(tab);
    }

    fn onImCommit(user: ?*anyopaque, text: []const u8) void {
        const self: *EditorView = @ptrCast(@alignCast(user.?));
        const tab = self.active orelse return;
        if (text.len == 0) return;
        // A symbol/results popup filters on typed characters instead of
        // inserting them; a completion popup lets them through so the
        // document keeps up with the prefix.
        if (self.lsp) |m| {
            if (m.handleText(text)) return;
        }
        // Auto-close intercepts single typed brackets/quotes ONLY on
        // the IM commit path — paste, IPC inserts and multi-byte
        // commits go straight through.
        if (self.auto_close and text.len == 1) {
            const gate: ecmd.Gate = .{ .ctx = @ptrCast(tab), .is_code = &gateIsCode };
            switch (ecmd.autoClose(self.allocator, &tab.doc, &tab.sels, text[0], gate) catch .not_handled) {
                .not_handled => {},
                .typed_over => {
                    tab.goal_x = null;
                    self.afterMove(tab);
                    return;
                },
                .inserted_pair, .surrounded => {
                    tab.goal_x = null;
                    self.afterDocEdit(tab);
                    if (self.lsp) |m| m.maybeTrigger(text);
                    return;
                },
            }
        }
        self.insertText(tab, text);
        if (self.lsp) |m| m.maybeTrigger(text);
    }

    fn copySelection(self: *EditorView, tab: *ETab) void {
        const text = vm.selectedText(self.allocator, &tab.doc, &tab.sels) catch return;
        defer self.allocator.free(text);
        if (text.len == 0) return;
        clipboard.copyText(@ptrCast(self.area), text);
    }

    fn cutSelection(self: *EditorView, tab: *ETab) void {
        var any = false;
        for (tab.sels.sels.items) |s| {
            if (!s.isCaret()) any = true;
        }
        if (!any) return;
        self.copySelection(tab);
        vm.insertText(self.allocator, &tab.doc, &tab.sels, "") catch return;
        self.afterDocEdit(tab);
    }

    fn pasteClipboard(self: *EditorView) void {
        // The Fence ref is the liveness guard: taken here, dropped in
        // onPasteRead (which always runs, text or not).
        self.fence.ref();
        if (!clipboard.readText(std.heap.c_allocator, @ptrCast(self.area), onPasteRead, @ptrCast(self.fence)))
            self.fence.unref();
    }

    fn onPasteRead(ctx: ?*anyopaque, text: ?[]const u8) void {
        const fence: *Fence = @ptrCast(@alignCast(ctx.?));
        defer fence.unref();
        const pasted = text orelse return;
        const view = fence.viewIfAlive() orelse return;
        const tab = view.active orelse return;
        view.insertText(tab, pasted);
    }

    const VisualPos = struct { line: usize, row: u32 };

    /// Step `delta` VISUAL rows from (line, row), crossing line
    /// boundaries. Null = fell off an end of the document.
    fn stepVisualRow(self: *EditorView, tab: *ETab, start: VisualPos, delta: isize) ?VisualPos {
        const n_lines = tab.doc.rope.lineCount();
        if (n_lines == 0) return null;
        var line = start.line;
        var row: i64 = start.row;
        var left = delta;
        // Folded lines are stepped OVER, never into: Down at the last
        // visible row of a folded header lands on the line after the
        // region, which is what makes arrow keys sane across a fold.
        while (left > 0) : (left -= 1) {
            const rows = self.rowsOfLine(tab, line);
            if (row + 1 < rows) {
                row += 1;
            } else {
                const next = tab.folds.nextVisible(line + 1);
                if (next >= n_lines) return null;
                line = next;
                row = 0;
            }
        }
        while (left < 0) : (left += 1) {
            if (row > 0) {
                row -= 1;
            } else if (line > 0) {
                const prev = tab.folds.prevVisible(line - 1);
                if (prev == line) return null;
                line = prev;
                row = @as(i64, self.rowsOfLine(tab, line)) - 1;
            } else return null;
        }
        return .{ .line = line, .row = @intCast(@max(0, row)) };
    }

    /// Up/down by VISUAL row (a wrapped line is several rows),
    /// preserving the goal column through the layout's caret x.
    fn moveVertical(self: *EditorView, tab: *ETab, delta: isize, extend: bool) void {
        var goal_set = tab.goal_x;
        for (tab.sels.sels.items) |*s| {
            const cv = self.caretVisual(tab, s.head);
            const use_x = goal_set orelse cv.x;
            if (goal_set == null) goal_set = cv.x;
            var head: usize = undefined;
            if (self.stepVisualRow(tab, .{ .line = cv.line, .row = cv.row }, delta)) |tp| {
                const tstart = tab.doc.rope.lineToOffset(tp.line);
                if (tab.layout.line(&tab.doc, tp.line)) |tll| {
                    head = tll.byte_start + Layout.xToByte(tll, tp.row, use_x);
                } else |_| {
                    head = tstart;
                }
            } else {
                head = if (delta < 0) 0 else tab.doc.rope.len();
            }
            s.head = head;
            if (!extend) s.anchor = head;
        }
        tab.goal_x = goal_set;
        tab.sels.normalize();
        self.noteActivity();
        self.ensureCaretVisible(tab);
        self.updateStatus();
        self.queueRender();
    }

    /// Home/End at VISUAL-row boundaries when the line is wrapped;
    /// plain line edges otherwise (identical when wrap is off).
    fn moveRowEdge(self: *EditorView, tab: *ETab, to_end: bool, extend: bool) void {
        if (tab.layout.wrap_width == null or self.atlas == null) {
            vm.moveLineEdge(&tab.doc, &tab.sels, to_end, extend);
            return;
        }
        for (tab.sels.sels.items) |*s| {
            const cv = self.caretVisual(tab, s.head);
            const ll = tab.layout.line(&tab.doc, cv.line) catch continue;
            const head = if (ll.rows.len <= 1) blk: {
                const lb = vm.lineBoundsAt(&tab.doc, s.head);
                break :blk if (to_end) lb.end else lb.start;
            } else ll.byte_start + Layout.xToByte(ll, cv.row, if (to_end) 1e9 else -1e9);
            s.head = head;
            if (!extend) s.anchor = head;
        }
        tab.sels.normalize();
    }

    fn pageRows(self: *EditorView) isize {
        const line_h = self.lineHeight();
        const vh = self.viewportHeightPx();
        if (line_h <= 0 or vh <= 0) return 20;
        const rows: isize = @intFromFloat(@floor(vh / line_h));
        return @max(1, rows - 1);
    }

    fn onKeyPressed(
        _: *c.GtkEventControllerKey,
        keyval: c_uint,
        _: c_uint,
        state: c.GdkModifierType,
        user: ?*anyopaque,
    ) callconv(.c) c.gboolean {
        const self: *EditorView = @ptrCast(@alignCast(user.?));
        const mods = state & input.SIGNIFICANT_MODS;
        const ctrl = (mods & c.GDK_CONTROL_MASK) != 0;
        const shift = (mods & c.GDK_SHIFT_MASK) != 0;
        const alt = (mods & c.GDK_ALT_MASK) != 0;
        const lower = c.gdk_keyval_to_lower(keyval);

        // An open LSP popup owns the navigation keys first: Up/Down
        // move its selection, Enter/Tab accept, Escape dismisses.
        if (self.lsp) |m| {
            if (m.handleKey(keyval, ctrl)) return 1;
        }
        // Ctrl+Shift+O is the outline PANEL. It used to raise a
        // transient document-symbol popup; the panel is the same data
        // in a form you can keep open (and it falls back to the syntax
        // tree where no server answers), so it takes the chord and the
        // popup path now only serves workspace symbols (Ctrl+T).
        if (ctrl and shift and !alt and lower == c.GDK_KEY_o) {
            editoroutline.toggle(self);
            return 1;
        }
        if (self.handleLspKey(keyval, lower, ctrl, shift, alt)) return 1;

        // Editor-command bindings (editor/commands.zig): defaults
        // overlaid with `editor_keybind.*`, resolved in syncConfig. A
        // user override deliberately wins over the hardcoded chords
        // below.
        if (self.active) |tab| {
            if (self.matchEdBinding(keyval, lower, mods)) |cmd| {
                self.runCommand(tab, cmd);
                return 1;
            }
        }

        if (!alt) {
            if (self.active) |tab| {
                if (self.handleEditKey(tab, keyval, ctrl, shift)) return 1;
                if (ctrl and !shift) {
                    switch (lower) {
                        c.GDK_KEY_a => {
                            vm.selectAll(&tab.doc, &tab.sels);
                            self.refresh(tab);
                            return 1;
                        },
                        c.GDK_KEY_c => {
                            self.copySelection(tab);
                            return 1;
                        },
                        c.GDK_KEY_x => {
                            self.cutSelection(tab);
                            return 1;
                        },
                        c.GDK_KEY_v => {
                            self.pasteClipboard();
                            return 1;
                        },
                        c.GDK_KEY_z => {
                            vm.undo(self.allocator, &tab.doc, &tab.sels) catch {};
                            self.afterDocEdit(tab);
                            return 1;
                        },
                        c.GDK_KEY_y => {
                            vm.redo(self.allocator, &tab.doc, &tab.sels) catch {};
                            self.afterDocEdit(tab);
                            return 1;
                        },
                        c.GDK_KEY_f => {
                            self.openFind(false);
                            return 1;
                        },
                        c.GDK_KEY_h => {
                            self.openFind(true);
                            return 1;
                        },
                        c.GDK_KEY_s => {
                            self.saveTab(tab);
                            return 1;
                        },
                        c.GDK_KEY_o => {
                            self.openPicker();
                            return 1;
                        },
                        c.GDK_KEY_w => {
                            self.requestCloseTab(tab);
                            return 1;
                        },
                        // Go to matching bracket. Ctrl+M is free here
                        // (the global Ctrl+SHIFT+M is zoom_pane and is
                        // NOT shadowed).
                        c.GDK_KEY_m => {
                            self.gotoMatchingBracket(tab, false);
                            return 1;
                        },
                        else => {},
                    }
                }
                if (ctrl and shift) {
                    switch (lower) {
                        // Fold / unfold at the caret — VS Code's
                        // Ctrl+Shift+[ and Ctrl+Shift+]. GDK reports
                        // the SHIFTED keyvals, so both spellings are
                        // matched.
                        c.GDK_KEY_bracketleft, c.GDK_KEY_braceleft => {
                            self.foldAtCaret(tab);
                            return 1;
                        },
                        c.GDK_KEY_bracketright, c.GDK_KEY_braceright => {
                            self.unfoldAtCaret(tab);
                            return 1;
                        },
                        c.GDK_KEY_m => {
                            // Extend the selection to the match.
                            self.gotoMatchingBracket(tab, true);
                            return 1;
                        },
                        c.GDK_KEY_z => {
                            vm.redo(self.allocator, &tab.doc, &tab.sels) catch {};
                            self.afterDocEdit(tab);
                            return 1;
                        },
                        c.GDK_KEY_s => {
                            self.saveTabAs(tab);
                            return 1;
                        },
                        // Project-wide search / replace. Shadows the
                        // global bindings while the editor has focus,
                        // exactly like Ctrl+Shift+S above.
                        c.GDK_KEY_f => {
                            editorproj.openSearch(self, false);
                            return 1;
                        },
                        c.GDK_KEY_h => {
                            editorproj.openSearch(self, true);
                            return 1;
                        },
                        else => {},
                    }
                }
            }
            // Change-hunk navigation, next to F8's diagnostics.
            if (keyval == c.GDK_KEY_F7 and !ctrl) {
                editorproj.stepHunk(self, !shift);
                return 1;
            }
        } else if (self.active) |tab| {
            // Alt+Z: soft wrap toggle (the VS Code chord).
            if (lower == c.GDK_KEY_z and !ctrl and !shift) {
                self.toggleWrap(tab);
                return 1;
            }
            // Shift+Alt+Right / Left: expand / shrink the selection to
            // the enclosing syntax node (VS Code's chord).
            if (shift and !ctrl) {
                switch (keyval) {
                    c.GDK_KEY_Right, c.GDK_KEY_KP_Right => {
                        self.expandSelection(tab);
                        return 1;
                    },
                    c.GDK_KEY_Left, c.GDK_KEY_KP_Left => {
                        self.shrinkSelection(tab);
                        return 1;
                    },
                    else => {},
                }
            }
            // Ctrl+Alt+[ / ]: fold all / unfold all.
            if (ctrl and !shift) {
                switch (lower) {
                    c.GDK_KEY_bracketleft, c.GDK_KEY_braceleft => {
                        self.foldAll(tab);
                        return 1;
                    },
                    c.GDK_KEY_bracketright, c.GDK_KEY_braceright => {
                        self.unfoldAll(tab);
                        return 1;
                    },
                    else => {},
                }
            }
        }

        // Unclaimed chords fall back to the pane's binding table so
        // window-level actions keep working (browser template).
        const pane = self.pane orelse return 0;
        const ictx = pane.input_ctx orelse return 0;
        const bindings: []const input.Binding = if (ictx.bindings.len > 0) ictx.bindings else &input.default_bindings;
        if (input.matchBinding(bindings, lower, state) orelse input.matchBinding(bindings, keyval, state)) |action| {
            return input.runAction(ictx, action);
        }
        return 0;
    }

    /// Language-server chords. Deliberately the VS Code set, so muscle
    /// memory carries over:
    ///
    ///   Ctrl+Space          completion
    ///   Ctrl+I              hover (also shows the diagnostic at the caret)
    ///   F12 / Shift+F12     definition / references
    ///   Ctrl+F12            type definition
    ///   Ctrl+Shift+F12      declaration
    ///   F8 / Shift+F8       next / previous diagnostic
    ///   Ctrl+Shift+O        document symbols
    ///   Ctrl+T              workspace symbols
    ///   F2                  rename
    ///   Ctrl+Shift+I        format (the selection, when there is one)
    ///
    /// A chord whose feature has no server behind it reports on the
    /// status line and is still CONSUMED: falling through to the pane's
    /// binding table would make F12 do something unrelated depending on
    /// whether zls happens to be installed.
    fn handleLspKey(self: *EditorView, keyval: c_uint, lower: c_uint, ctrl: bool, shift: bool, alt: bool) bool {
        if (alt) return false;
        if (self.active == null) return false;
        const conf: *const Config = if (self.ownerWindow()) |win|
            &win.config
        else
            self.standalone_config orelse return false;
        if (!conf.editor_lsp) return false;

        const want: ?enum {
            completion,
            hover,
            definition,
            declaration,
            type_definition,
            references,
            workspace_symbols,
            rename,
            format,
            diag_next,
            diag_prev,
            signature,
            code_action,
        } = blk: {
            if (ctrl and shift and keyval == c.GDK_KEY_space) break :blk .signature;
            if (ctrl and !shift and keyval == c.GDK_KEY_space) break :blk .completion;
            // Ctrl+. — VS Code's Quick Fix. `period` and `KP_Decimal`
            // are different keyvals and both reach here.
            if (ctrl and (keyval == c.GDK_KEY_period or keyval == c.GDK_KEY_KP_Decimal))
                break :blk .code_action;
            if (ctrl and !shift and lower == c.GDK_KEY_i) break :blk .hover;
            if (ctrl and shift and lower == c.GDK_KEY_i) break :blk .format;
            if (ctrl and !shift and lower == c.GDK_KEY_t) break :blk .workspace_symbols;
            if (keyval == c.GDK_KEY_F2 and !ctrl and !shift) break :blk .rename;
            if (keyval == c.GDK_KEY_F8) break :blk if (shift) .diag_prev else .diag_next;
            if (keyval == c.GDK_KEY_F12) {
                if (ctrl and shift) break :blk .declaration;
                if (ctrl) break :blk .type_definition;
                if (shift) break :blk .references;
                break :blk .definition;
            }
            break :blk null;
        };
        const action = want orelse return false;

        if (self.lsp == null) {
            // Nothing has ever claimed a document here; create the
            // manager so the "no language server" report is honest
            // about the CURRENT tab rather than silently doing nothing.
            if (self.active) |tab| self.attachLsp(tab);
        }
        const m = self.lsp orelse {
            self.setStatus("No language server for this file.");
            return true;
        };
        switch (action) {
            .completion => m.requestCompletion(true),
            .hover => m.requestHover(),
            .definition => m.requestDefinition(.definition),
            .declaration => m.requestDefinition(.declaration),
            .type_definition => m.requestDefinition(.type_definition),
            .references => m.requestDefinition(.references),
            .workspace_symbols => m.requestWorkspaceSymbols(),
            .rename => m.startRename(),
            .format => m.requestFormatting(),
            .diag_next => m.stepDiagnostic(true),
            .diag_prev => m.stepDiagnostic(false),
            .signature => m.requestSignatureHelp(true, 1, 0),
            .code_action => m.requestCodeActions(),
        }
        return true;
    }

    /// Movement + structural edit keys. @return true when consumed.
    fn handleEditKey(self: *EditorView, tab: *ETab, keyval: c_uint, ctrl: bool, shift: bool) bool {
        const a = self.allocator;
        switch (keyval) {
            c.GDK_KEY_Left, c.GDK_KEY_KP_Left => {
                vm.moveHorizontal(a, &tab.doc, &tab.sels, -1, shift, ctrl);
                tab.goal_x = null;
                self.afterMove(tab);
                return true;
            },
            c.GDK_KEY_Right, c.GDK_KEY_KP_Right => {
                vm.moveHorizontal(a, &tab.doc, &tab.sels, 1, shift, ctrl);
                tab.goal_x = null;
                self.afterMove(tab);
                return true;
            },
            c.GDK_KEY_Up, c.GDK_KEY_KP_Up => {
                if (ctrl) return false;
                self.moveVertical(tab, -1, shift);
                return true;
            },
            c.GDK_KEY_Down, c.GDK_KEY_KP_Down => {
                if (ctrl) return false;
                self.moveVertical(tab, 1, shift);
                return true;
            },
            c.GDK_KEY_Home, c.GDK_KEY_KP_Home => {
                if (ctrl) vm.moveDocEdge(&tab.doc, &tab.sels, false, shift) else self.moveRowEdge(tab, false, shift);
                tab.goal_x = null;
                self.afterMove(tab);
                return true;
            },
            c.GDK_KEY_End, c.GDK_KEY_KP_End => {
                if (ctrl) vm.moveDocEdge(&tab.doc, &tab.sels, true, shift) else self.moveRowEdge(tab, true, shift);
                tab.goal_x = null;
                self.afterMove(tab);
                return true;
            },
            c.GDK_KEY_Page_Up, c.GDK_KEY_KP_Page_Up => {
                self.moveVertical(tab, -self.pageRows(), shift);
                return true;
            },
            c.GDK_KEY_Page_Down, c.GDK_KEY_KP_Page_Down => {
                self.moveVertical(tab, self.pageRows(), shift);
                return true;
            },
            c.GDK_KEY_BackSpace => {
                if (!ctrl) {
                    // Pair delete, then indent-stop retreat; both are
                    // one transaction and decline cleanly.
                    if (self.auto_close and (ecmd.backspacePair(a, &tab.doc, &tab.sels) catch false)) {
                        tab.goal_x = null;
                        self.afterDocEdit(tab);
                        return true;
                    }
                    if (self.smart_backspace and
                        (ecmd.smartBackspace(a, &tab.doc, &tab.sels, self.tab_width) catch false))
                    {
                        tab.goal_x = null;
                        self.afterDocEdit(tab);
                        return true;
                    }
                }
                vm.deleteBackward(a, &tab.doc, &tab.sels, ctrl) catch {};
                tab.goal_x = null;
                self.afterDocEdit(tab);
                return true;
            },
            c.GDK_KEY_Delete, c.GDK_KEY_KP_Delete => {
                vm.deleteForward(a, &tab.doc, &tab.sels, ctrl) catch {};
                tab.goal_x = null;
                self.afterDocEdit(tab);
                return true;
            },
            c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => {
                if (self.auto_indent) {
                    ecmd.newlineAutoIndent(a, &tab.doc, &tab.sels, .{
                        .width = self.tab_width,
                        .spaces = self.insert_spaces,
                        .auto_indent = true,
                    }) catch {};
                } else {
                    vm.insertNewlineIndent(a, &tab.doc, &tab.sels) catch {};
                }
                tab.goal_x = null;
                self.afterDocEdit(tab);
                return true;
            },
            c.GDK_KEY_Tab, c.GDK_KEY_ISO_Left_Tab => {
                if (ctrl) return false;
                if (shift or keyval == c.GDK_KEY_ISO_Left_Tab) {
                    ecmd.dedentLines(a, &tab.doc, &tab.sels, self.tab_width) catch {};
                    self.afterDocEdit(tab);
                    return true;
                }
                // Tab with any real selection indents the covered
                // lines (the universal editor rule); a bare caret
                // inserts a tab stop.
                var any_range = false;
                for (tab.sels.sels.items) |s| {
                    if (!s.isCaret()) any_range = true;
                }
                if (any_range) {
                    ecmd.indentLines(a, &tab.doc, &tab.sels, self.tab_width, self.insert_spaces) catch {};
                } else {
                    vm.insertTabStop(a, &tab.doc, &tab.sels, self.tab_width, self.insert_spaces) catch {};
                }
                tab.goal_x = null;
                self.afterDocEdit(tab);
                return true;
            },
            c.GDK_KEY_Escape => {
                if (self.find_open) {
                    self.closeFind();
                    return true;
                }
                // A posted status message is dismissible: Escape is
                // already "put this away" everywhere else in the face.
                // It does NOT consume the key — collapsing extra carets
                // is the more visible meaning and must still happen.
                self.clearStatusNote();
                if (tab.sels.count() <= 1) return false;
                vm.collapseToPrimary(&tab.sels);
                self.refresh(tab);
                return true;
            },
            else => return false,
        }
    }

    fn afterMove(self: *EditorView, tab: *ETab) void {
        if (self.lsp) |m| m.onCaretMoved();
        // A caret that walked into hidden text opens the fold; a caret
        // move that is not an expand/shrink drops the structural trail
        // (otherwise Shrink would replay a selection you have left).
        self.revealCaretLines(tab);
        if (!tab.structural_move) tab.sel_stack.clear();
        self.ensureCaretVisible(tab);
        editoroutline.onCaretMoved(self, tab);
        self.updateStatus();
        self.queueRender();
    }

    // ---- editor commands (editor/commands.zig) ------------------------

    pub const EdBinding = struct {
        keyval: c_uint,
        mods: c_uint,
        cmd: ecmd.Command,
    };

    /// Resolve the editor-command binding table: each command's default
    /// accelerator, overridden (or unbound, empty accel) by
    /// `editor_keybind.<command>` config entries. A separate table from
    /// the window/pane bindings on purpose: these chords exist only
    /// while the editor canvas has focus and can never eat a terminal
    /// key.
    fn rebuildEdBindings(self: *EditorView, cfg: *const Config) void {
        self.ed_bindings.clearRetainingCapacity();
        inline for (@typeInfo(ecmd.Command).@"enum".fields) |f| {
            const cmd: ecmd.Command = @enumFromInt(f.value);
            var accel: []const u8 = ecmd.defaultAccel(cmd);
            for (cfg.editor_keybinds.items) |kb| {
                if (std.mem.eql(u8, kb.name, f.name)) accel = kb.accel;
            }
            if (accel.len > 0) {
                if (input.parseAccel(accel)) |p| {
                    self.ed_bindings.append(self.allocator, .{
                        .keyval = p.keyval,
                        .mods = p.mods & input.SIGNIFICANT_MODS,
                        .cmd = cmd,
                    }) catch return;
                } else {
                    std.debug.print("sketerm: editor_keybind: bad accelerator '{s}' for '{s}'\n", .{ accel, f.name });
                }
            }
        }
    }

    fn matchEdBinding(self: *EditorView, keyval: c_uint, lower: c_uint, mods: c_uint) ?ecmd.Command {
        for (self.ed_bindings.items) |b| {
            if ((b.keyval == lower or b.keyval == keyval) and b.mods == mods) return b.cmd;
        }
        return null;
    }

    /// Language for comment toggling: like `detectLang` but NOT gated
    /// on `editor_syntax` — the comment prefix is a fact about the
    /// file, not about whether highlighting is drawn.
    fn commentLang(self: *EditorView, tab: *ETab) ?syntax.Lang {
        _ = self;
        if (tab.hl_lang) |l| return l;
        var buf: [SHEBANG_PROBE]u8 = undefined;
        var head: []const u8 = "";
        const n = @min(buf.len, tab.doc.rope.len());
        if (n > 0) {
            var it = tab.doc.rope.iterateRange(0, n);
            var w: usize = 0;
            while (it.next()) |chunk| {
                @memcpy(buf[w .. w + chunk.len], chunk);
                w += chunk.len;
            }
            head = buf[0..w];
            if (std.mem.indexOfScalar(u8, head, '\n')) |nl| head = head[0..nl];
        }
        return syntax.detect(tab.spec, head);
    }

    /// Dispatch one editor command (keybinding, palette or context
    /// menu). Every mutation is one transaction = one undo step.
    pub fn runCommand(self: *EditorView, tab: *ETab, cmd: ecmd.Command) void {
        const a = self.allocator;
        switch (cmd) {
            .duplicate_line_up, .duplicate_line_down => {
                ecmd.duplicate(a, &tab.doc, &tab.sels, cmd == .duplicate_line_down) catch return;
                tab.goal_x = null;
                self.afterDocEdit(tab);
            },
            .move_line_up, .move_line_down => {
                ecmd.moveLines(a, &tab.doc, &tab.sels, cmd == .move_line_down) catch return;
                tab.goal_x = null;
                self.afterDocEdit(tab);
            },
            .join_lines => {
                ecmd.joinLines(a, &tab.doc, &tab.sels) catch return;
                tab.goal_x = null;
                self.afterDocEdit(tab);
            },
            .sort_lines => {
                var any = false;
                for (tab.sels.sels.items) |s| {
                    if (!s.isCaret()) any = true;
                }
                if (!any) {
                    self.setStatus("Select the lines to sort.");
                    return;
                }
                ecmd.sortLines(a, &tab.doc, &tab.sels) catch return;
                self.afterDocEdit(tab);
            },
            .toggle_comment => {
                const lang = self.commentLang(tab) orelse {
                    self.setStatus("No known language for this file — no comment syntax.");
                    return;
                };
                const prefix = lang.lineComment() orelse {
                    self.setStatus("This language has no line-comment syntax.");
                    return;
                };
                _ = ecmd.toggleComment(a, &tab.doc, &tab.sels, prefix) catch return;
                tab.goal_x = null;
                self.afterDocEdit(tab);
            },
            .indent => {
                ecmd.indentLines(a, &tab.doc, &tab.sels, self.tab_width, self.insert_spaces) catch return;
                self.afterDocEdit(tab);
            },
            .dedent => {
                ecmd.dedentLines(a, &tab.doc, &tab.sels, self.tab_width) catch return;
                self.afterDocEdit(tab);
            },
            .trim_trailing_ws => {
                ecmd.trimTrailingWhitespace(a, &tab.doc, &tab.sels) catch return;
                self.afterDocEdit(tab);
            },
            .upper_case, .lower_case, .title_case => {
                const mode: ecmd.CaseMode = switch (cmd) {
                    .upper_case => .upper,
                    .lower_case => .lower,
                    else => .title,
                };
                ecmd.changeCase(a, &tab.doc, &tab.sels, mode) catch return;
                self.afterDocEdit(tab);
            },
            .goto_line => self.promptGotoLine(),
            .select_next_occurrence => {
                const found = ecmd.selectNextOccurrence(a, &tab.doc, &tab.sels) catch false;
                self.afterMove(tab);
                if (!found) self.setStatus("No further occurrence.");
            },
            .skip_occurrence => {
                const found = ecmd.skipOccurrence(a, &tab.doc, &tab.sels) catch false;
                self.afterMove(tab);
                if (!found) self.setStatus("No further occurrence.");
            },
            .select_all_occurrences => {
                const n = ecmd.selectAllOccurrences(a, &tab.doc, &tab.sels) catch 0;
                self.afterMove(tab);
                if (n > 0) {
                    var buf: [48]u8 = undefined;
                    if (std.fmt.bufPrintZ(&buf, "{d} occurrence(s) selected.", .{n})) |z| {
                        self.setStatus(z.ptr);
                    } else |_| {}
                }
            },
            .add_caret_above, .add_caret_below => {
                ecmd.addCaretVertical(a, &tab.doc, &tab.sels, cmd == .add_caret_below) catch return;
                self.afterMove(tab);
            },
            .split_selection_lines => {
                ecmd.splitSelectionIntoLines(a, &tab.doc, &tab.sels) catch return;
                self.afterMove(tab);
            },
        }
    }

    /// Syntax gate for quote auto-close: an offset whose token is a
    /// string or comment is content, not code. No tree (or a stale
    /// one) gates nothing — small documents re-parse synchronously on
    /// every edit, so staleness is a one-keystroke window.
    fn gateIsCode(ctx: ?*anyopaque, offset: usize) bool {
        const tab: *ETab = @ptrCast(@alignCast(ctx.?));
        const hl = tab.hl orelse return true;
        if (hl.isStale(&tab.doc)) return true;
        const kind = hl.kindAt(&tab.doc, offset) catch return true;
        return switch (kind) {
            .string, .comment, .escape => false,
            else => true,
        };
    }

    fn promptGotoLine(self: *EditorView) void {
        if (self.widgets_dead) return;
        const tab = self.active orelse return;
        const ctx = DlgCtx.create(self, tab) orelse return;
        const entry = c.gtk_entry_new();
        // AdwAlertDialog does not run Enter through the default-widget
        // machinery, so the entry's own activate is the Enter path;
        // the "Go" button is the response path. Both share
        // applyGotoText; the fenced ctx carries its own free.
        const ectx = DlgCtx.create(self, tab) orelse {
            ctx.destroy();
            return;
        };
        _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onGotoLineActivate), @ptrCast(ectx), @ptrCast(&freeDlgCtx), c.G_CONNECT_DEFAULT);
        self.goto_entry = entry;
        if (confirm.present(self.dialogParent(), .{
            .heading = "Go to line",
            .body = "Line, or line:column",
            .responses = &.{
                .{ .id = "cancel", .label = "Cancel", .is_close = true },
                .{ .id = "go", .label = "Go", .appearance = .suggested, .is_default = true },
            },
            .extra_child = entry,
            // Without this the dialog maps with nothing focused and
            // typed digits vanish into the modal barrier.
            .focus = entry,
        }, .{ .allocator = self.allocator, .cb = &onGotoLineResponse, .ctx = @ptrCast(ctx) }) == null) {
            self.goto_entry = null;
            // Nothing adopted the floating entry (which owns `ectx`).
            _ = c.g_object_ref_sink(@ptrCast(entry));
            c.g_object_unref(@ptrCast(entry));
            ctx.destroy();
        }
    }

    fn freeDlgCtx(user: ?*anyopaque) callconv(.c) void {
        if (user) |u| {
            const ctx: *DlgCtx = @ptrCast(@alignCast(u));
            ctx.destroy();
        }
    }

    /// Parse "line" or "line:col" (1-based) and jump.
    fn applyGotoText(view: *EditorView, tab: *ETab, text: []const u8) void {
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0) return;
        var line_part = trimmed;
        var col: usize = 1;
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
            line_part = trimmed[0..colon];
            col = std.fmt.parseInt(usize, trimmed[colon + 1 ..], 10) catch 1;
        }
        const line = std.fmt.parseInt(usize, line_part, 10) catch return;
        view.gotoLineCol(tab, @max(1, line), @max(1, col));
        _ = c.gtk_widget_grab_focus(@ptrCast(view.area));
    }

    fn onGotoLineActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
        const ctx: *DlgCtx = @ptrCast(@alignCast(user.?));
        const r = ctx.resolve() orelse return;
        const raw = c.gtk_editable_get_text(@ptrCast(entry));
        if (raw != null) {
            applyGotoText(r.view, r.tab, std.mem.span(@as([*:0]const u8, @ptrCast(raw))));
        }
        r.view.goto_entry = null;
        if (c.gtk_widget_get_ancestor(@ptrCast(entry), c.adw_dialog_get_type())) |dlg| {
            c.adw_dialog_force_close(@ptrCast(@alignCast(dlg)));
        }
    }

    fn onGotoLineResponse(user: ?*anyopaque, resp: []const u8) void {
        const ctx: *DlgCtx = @ptrCast(@alignCast(user.?));
        defer ctx.destroy();
        const r = ctx.resolve() orelse return;
        const entry = r.view.goto_entry;
        r.view.goto_entry = null;
        if (!std.mem.eql(u8, resp, "go")) return;
        const e = entry orelse return;
        const raw = c.gtk_editable_get_text(@ptrCast(e));
        if (raw == null) return;
        applyGotoText(r.view, r.tab, std.mem.span(@as([*:0]const u8, @ptrCast(raw))));
    }

    // ---- context menu (ui/editormenu.zig) -----------------------------

    /// Per-popup state for the context menu: place the caret when the
    /// click lands outside every selection, then enable/disable rows
    /// that cannot act. Returning false suppresses the menu.
    pub fn menuPrePopup(self: *EditorView, group: *c.GSimpleActionGroup, x: f64, y: f64) bool {
        if (self.widgets_dead) return false;
        const tab = self.active orelse return false;
        _ = c.gtk_widget_grab_focus(@ptrCast(self.area));
        const pos = self.hitTest(tab, x, y);
        var inside = false;
        for (tab.sels.sels.items) |s| {
            if (!s.isCaret() and pos >= s.start() and pos <= s.end()) inside = true;
        }
        if (!inside) {
            tab.sels.keepPrimaryOnly();
            tab.sels.sels.items[0] = Selection.caret(pos);
            tab.goal_x = null;
            self.afterMove(tab);
        }
        var has_selection = false;
        for (tab.sels.sels.items) |s| {
            if (!s.isCaret()) has_selection = true;
        }
        const lsp_on = tab.lsp != null and self.lsp != null;
        const lang = self.commentLang(tab);
        const has_comment = lang != null and lang.?.lineComment() != null;
        setActionEnabled(group, "cut", has_selection);
        setActionEnabled(group, "copy", has_selection);
        setActionEnabled(group, "sort", has_selection);
        setActionEnabled(group, "toggle-comment", has_comment);
        setActionEnabled(group, "fold", self.folding);
        setActionEnabled(group, "unfold", self.folding);
        setActionEnabled(group, "fold-all", self.folding);
        setActionEnabled(group, "unfold-all", self.folding);
        for ([_][*:0]const u8{ "goto-def", "references", "rename", "format", "code-actions" }) |n| {
            setActionEnabled(group, n, lsp_on);
        }
        return true;
    }

    fn setActionEnabled(group: *c.GSimpleActionGroup, name: [*:0]const u8, on: bool) void {
        if (c.g_action_map_lookup_action(@ptrCast(group), name)) |act| {
            c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), @intFromBool(on));
        }
    }

    /// Context-menu dispatch. Rows that reduce to an editor command go
    /// through `runCommand` (same code path as the keybindings).
    pub fn menuAction(self: *EditorView, act: editormenu.Action) void {
        if (self.widgets_dead) return;
        const tab = self.active orelse return;
        switch (act) {
            .cut => self.cutSelection(tab),
            .copy => self.copySelection(tab),
            .paste => self.pasteClipboard(),
            .select_all => {
                vm.selectAll(&tab.doc, &tab.sels);
                self.refresh(tab);
            },
            .toggle_comment => self.runCommand(tab, .toggle_comment),
            .duplicate => self.runCommand(tab, .duplicate_line_down),
            .move_up => self.runCommand(tab, .move_line_up),
            .move_down => self.runCommand(tab, .move_line_down),
            .join => self.runCommand(tab, .join_lines),
            .sort => self.runCommand(tab, .sort_lines),
            .indent => self.runCommand(tab, .indent),
            .dedent => self.runCommand(tab, .dedent),
            .trim_ws => self.runCommand(tab, .trim_trailing_ws),
            .case_upper => self.runCommand(tab, .upper_case),
            .case_lower => self.runCommand(tab, .lower_case),
            .case_title => self.runCommand(tab, .title_case),
            .goto_def, .references, .rename, .format, .code_actions => {
                const m = self.lsp orelse {
                    self.setStatus("No language server for this file.");
                    return;
                };
                switch (act) {
                    .goto_def => m.requestDefinition(.definition),
                    .references => m.requestDefinition(.references),
                    .rename => m.startRename(),
                    .format => m.requestFormatting(),
                    .code_actions => m.requestCodeActions(),
                    else => unreachable,
                }
            },
            .fold => self.foldAtCaret(tab),
            .unfold => self.unfoldAtCaret(tab),
            .fold_all => self.foldAll(tab),
            .unfold_all => self.unfoldAll(tab),
            .find => self.openFind(false),
            .replace => self.openFind(true),
            .goto_line => self.promptGotoLine(),
        }
    }

    // ---- gutter and status-line menus ----------------------------------
    //
    // The gutter is part of the SAME GtkGLArea as the text, so its
    // right-click arrives on the canvas gesture and is routed here by
    // x-coordinate. It gets its own menu because a click there is
    // line-oriented: the line under the pointer, not the caret and not
    // the selection.

    /// The document line under (x, y) when the point is inside the
    /// gutter, null when it is over the text (or there is no gutter).
    /// Widget coordinates, exactly what the click gesture reports.
    pub fn gutterLineAt(self: *EditorView, x: f64, y: f64) ?usize {
        if (self.widgets_dead) return null;
        const tab = self.active orelse return null;
        if (tab.loading) return null;
        const gw = self.gutterWidthOf(tab);
        if (gw <= 0) return null;
        const scale: f32 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
        if (@as(f32, @floatCast(x)) * scale >= gw) return null;
        const hit = self.locateY(tab, @as(f32, @floatCast(y)) * scale) orelse return null;
        return hit.line;
    }

    /// What the gutter menu's rows may do on `line`, resolved at popup
    /// time — never cached (menus reflect state when they open).
    pub const GutterState = struct {
        /// `editor_folding` is on at all.
        folding: bool,
        /// A fold is currently collapsed AT this line.
        folded: bool,
        /// A foldable region is headed by this line.
        foldable: bool,
        /// Any fold is collapsed anywhere in the document.
        any_folded: bool,
        /// The git gutter is on and this document has change marks.
        has_hunks: bool,
        /// 1-based line number, for the labels.
        line_no: usize,
    };

    pub fn gutterState(self: *EditorView, line: usize) ?GutterState {
        if (self.widgets_dead) return null;
        const tab = self.active orelse return null;
        const folded = self.folding and tab.folds.entryAtLine(line) != null;
        return .{
            .folding = self.folding,
            .folded = folded,
            .foldable = self.folding and !folded and self.foldRegionAtLine(tab, line) != null,
            .any_folded = self.folding and !tab.folds.isEmpty(),
            .has_hunks = self.git_gutter and !tab.git.isEmpty(),
            .line_no = line + 1,
        };
    }

    /// Gutter-menu dispatch. `line` is the 0-based line the menu was
    /// opened on, carried from popup time (the caret may have moved,
    /// and these verbs are about the clicked line either way).
    pub fn gutterAction(self: *EditorView, act: editormenu.GutterAction, line: usize) void {
        if (self.widgets_dead) return;
        const tab = self.active orelse return;
        switch (act) {
            .toggle_fold => self.toggleFoldLine(tab, line),
            .fold_all => self.foldAll(tab),
            .unfold_all => self.unfoldAll(tab),
            .goto_line => self.promptGotoLine(),
            .copy_line_number => {
                var buf: [24:0]u8 = undefined;
                const z = std.fmt.bufPrintZ(&buf, "{d}", .{line + 1}) catch return;
                clipboard.copyText(@ptrCast(self.area), z);
                var msg: [48:0]u8 = undefined;
                const m = std.fmt.bufPrintZ(&msg, "Copied line number {d}.", .{line + 1}) catch return;
                self.setStatus(m.ptr);
            },
            .select_line => {
                const at = tab.doc.rope.lineToOffset(@min(line, tab.doc.rope.lineCount() -| 1));
                tab.sels.keepPrimaryOnly();
                tab.sels.sels.items[0] = vm.lineRangeAt(&tab.doc, at);
                tab.goal_x = null;
                self.afterMove(tab);
            },
            .next_hunk => editorproj.stepHunk(self, true),
            .prev_hunk => editorproj.stepHunk(self, false),
        }
    }

    /// What the status-line menu's rows may do, resolved at popup time.
    pub const StatusState = struct {
        wrap: bool,
        has_hunks: bool,
        /// A language server is attached to the active document, so
        /// the diagnostics this line reports can be stepped through.
        lsp: bool,
    };

    pub fn statusState(self: *EditorView) ?StatusState {
        if (self.widgets_dead) return null;
        const tab = self.active orelse return null;
        return .{
            .wrap = tab.wrap,
            .has_hunks = self.git_gutter and !tab.git.isEmpty(),
            .lsp = tab.lsp != null and self.lsp != null,
        };
    }

    /// Status-line menu dispatch. Every row here acts on something the
    /// status line itself reports — there is deliberately nothing else
    /// on it.
    pub fn statusAction(self: *EditorView, act: editormenu.StatusAction) void {
        if (self.widgets_dead) return;
        const tab = self.active orelse return;
        switch (act) {
            .toggle_wrap => self.toggleWrap(tab),
            .goto_line => self.promptGotoLine(),
            .next_hunk => editorproj.stepHunk(self, true),
            .prev_hunk => editorproj.stepHunk(self, false),
            .next_diag => if (self.lsp) |m| m.stepDiagnostic(true),
            .prev_diag => if (self.lsp) |m| m.stepDiagnostic(false),
        }
    }

    // ---- mouse --------------------------------------------------------

    fn onClickPressed(gesture: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const self: *EditorView = @ptrCast(@alignCast(user.?));
        const tab = self.active orelse return;
        _ = c.gtk_widget_grab_focus(@ptrCast(self.area));
        if (self.lsp) |m| m.cancelDwell();
        // Clicking into an ALREADY focused canvas raises no focus
        // event, and is just as much a "I am back at this document"
        // signal (rate-limited like every other trigger).
        self.checkDisk();
        const state = c.gtk_event_controller_get_current_event_state(@ptrCast(gesture));
        const mods = state & input.SIGNIFICANT_MODS;
        const ctrl = (mods & c.GDK_CONTROL_MASK) != 0;
        const shift = (mods & c.GDK_SHIFT_MASK) != 0;
        // Fold column: a click there toggles, never moves the caret.
        if (self.folding and n_press == 1) {
            const scale: f32 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
            const dx: f32 = @as(f32, @floatCast(x)) * scale;
            const num_w = self.numberFieldWidth(tab);
            if (dx >= num_w and dx < num_w + EditorPass.FOLD_COL_W) {
                if (self.locateY(tab, @as(f32, @floatCast(y)) * scale)) |hit| {
                    self.toggleFoldLine(tab, hit.line);
                }
                self.drag_anchor = null;
                return;
            }
        }
        const pos = self.hitTest(tab, x, y);
        tab.goal_x = null;
        const alt = (mods & c.GDK_ALT_MASK) != 0;
        // Shift+Alt+drag: block (column) selection — one range per
        // line between the press corner and the pointer.
        if (alt and shift and n_press == 1) {
            const lc = tab.doc.rope.offsetToLineCol(pos);
            self.block_anchor = .{ .line = lc.line, .col = pos - tab.doc.rope.lineToOffset(lc.line) };
            self.drag_anchor = null;
            tab.sels.keepPrimaryOnly();
            tab.sels.sels.items[0] = Selection.caret(pos);
            self.updateStatus();
            self.queueRender();
            return;
        }
        self.block_anchor = null;
        if (n_press >= 3) {
            const sel = vm.lineRangeAt(&tab.doc, pos);
            tab.sels.keepPrimaryOnly();
            tab.sels.sels.items[0] = sel;
            self.drag_anchor = sel.anchor;
        } else if (n_press == 2) {
            const sel = vm.wordRangeAt(self.allocator, &tab.doc, pos);
            tab.sels.keepPrimaryOnly();
            tab.sels.sels.items[0] = sel;
            self.drag_anchor = sel.anchor;
        } else if (ctrl) {
            tab.sels.add(self.allocator, Selection.caret(pos)) catch {};
            self.drag_anchor = null;
        } else if (shift) {
            const p = tab.sels.primary_index;
            tab.sels.sels.items[p].head = pos;
            tab.sels.normalize();
            self.drag_anchor = tab.sels.primary().anchor;
        } else {
            tab.sels.keepPrimaryOnly();
            tab.sels.sels.items[0] = Selection.caret(pos);
            self.drag_anchor = pos;
        }
        self.updateStatus();
        self.queueRender();
    }

    fn onClickReleased(_: *c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const self: *EditorView = @ptrCast(@alignCast(user.?));
        self.drag_anchor = null;
        self.block_anchor = null;
    }

    fn onMotion(_: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const self: *EditorView = @ptrCast(@alignCast(user.?));
        // Dwell hover: this only RESTARTS a timer, it never issues a
        // request (editorlsp.onPointerMoved).
        if (self.lsp) |m| m.onPointerMoved(x, y);
        if (self.block_anchor) |ba| {
            const btab = self.active orelse return;
            const pos = self.hitTest(btab, x, y);
            const lc = btab.doc.rope.offsetToLineCol(pos);
            const col = pos - btab.doc.rope.lineToOffset(lc.line);
            ecmd.blockSelection(self.allocator, &btab.doc, &btab.sels, ba.line, ba.col, lc.line, col) catch return;
            self.updateStatus();
            self.queueRender();
            return;
        }
        const anchor = self.drag_anchor orelse return;
        const tab = self.active orelse return;
        const pos = self.hitTest(tab, x, y);
        const p = tab.sels.primary_index;
        tab.sels.sels.items[p] = .{ .anchor = anchor, .head = pos };
        tab.sels.normalize();
        self.updateStatus();
        self.queueRender();
    }

    /// Wheel: vertical by 3 rows; horizontal (or Shift+wheel) pans when
    /// wrap is off.
    fn onScroll(ctl: *c.GtkEventControllerScroll, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *EditorView = @ptrCast(@alignCast(user.?));
        const tab = self.active orelse return 0;
        if (self.lsp) |m| m.cancelDwell();
        const state = c.gtk_event_controller_get_current_event_state(@ptrCast(ctl));
        const shift = (state & input.SIGNIFICANT_MODS & c.GDK_SHIFT_MASK) != 0;
        const line_h = self.lineHeight();
        var handled = false;
        if (shift and dy != 0 and !tab.wrap) {
            tab.scroll_x += @as(f32, @floatCast(dy)) * line_h * 3.0;
            handled = true;
        } else if (dy != 0) {
            self.scrollByPx(tab, @as(f32, @floatCast(dy)) * line_h * 3.0);
            handled = true;
        }
        if (dx != 0 and !tab.wrap) {
            tab.scroll_x += @as(f32, @floatCast(dx)) * line_h * 3.0;
            handled = true;
        }
        if (!handled) return 0;
        self.clampAnchor(tab, self.viewportHeightPx());
        self.queueRender();
        return 1;
    }

    // ---- persistence + IPC helpers ------------------------------------

    /// GTK-free projection for layout persistence. Untitled/dirty
    /// buffers are not persisted (documented in editor/model.zig).
    pub fn paneState(self: *EditorView, arena: std.mem.Allocator) !editor_model.PaneState {
        var files: std.ArrayList(editor_model.FileState) = .empty;
        var active_idx: u64 = 0;
        var i: u64 = 0;
        for (self.tabs.items) |t| {
            const spec = t.spec orelse continue;
            if (t == self.active) active_idx = i;
            var root_buf: [paths.SPEC_BUF_LEN]u8 = undefined;
            const root: []const u8 = if (t.project) |p|
                p.rootSpec(&root_buf)
            else
                t.restored_project orelse "";
            try files.append(arena, .{
                .spec = try arena.dupe(u8, spec),
                .cursor = @intCast(t.sels.primary().head),
                .top_line = @intCast(t.anchor.line),
                .project = try arena.dupe(u8, root),
            });
            i += 1;
        }
        return .{ .files = files.items, .active = active_idx };
    }

    /// IPC get-text on an editor-visible pane: the active document's
    /// text, in its on-disk line-ending style. Caller frees.
    pub fn ipcGetText(self: *EditorView, alloc: std.mem.Allocator) ?[]u8 {
        const tab = self.active orelse return null;
        return tab.doc.materialize(alloc) catch null;
    }

    /// IPC send-text routed at an editor-visible pane: insert at all
    /// carets of the active tab.
    pub fn ipcInsertText(self: *EditorView, text: []const u8) bool {
        const tab = self.active orelse return false;
        self.insertText(tab, text);
        return true;
    }

    /// IPC send-keys for an editor-visible pane. A deliberately small
    /// chord set (scripting/smoke): enter, tab, backspace, delete,
    /// escape, ctrl+s, ctrl+z, ctrl+y.
    pub fn ipcSendKeys(self: *EditorView, chords: []const u8) bool {
        const tab = self.active orelse return false;
        var it = std.mem.tokenizeScalar(u8, chords, ' ');
        while (it.next()) |chord| {
            if (std.mem.eql(u8, chord, "enter")) {
                vm.insertNewlineIndent(self.allocator, &tab.doc, &tab.sels) catch return false;
                self.afterDocEdit(tab);
            } else if (std.mem.eql(u8, chord, "tab")) {
                vm.insertTabStop(self.allocator, &tab.doc, &tab.sels, self.tab_width, self.insert_spaces) catch return false;
                self.afterDocEdit(tab);
            } else if (std.mem.eql(u8, chord, "backspace")) {
                vm.deleteBackward(self.allocator, &tab.doc, &tab.sels, false) catch return false;
                self.afterDocEdit(tab);
            } else if (std.mem.eql(u8, chord, "delete")) {
                vm.deleteForward(self.allocator, &tab.doc, &tab.sels, false) catch return false;
                self.afterDocEdit(tab);
            } else if (std.mem.eql(u8, chord, "escape")) {
                vm.collapseToPrimary(&tab.sels);
                self.refresh(tab);
            } else if (std.mem.eql(u8, chord, "ctrl+s")) {
                self.saveTab(tab);
            } else if (std.mem.eql(u8, chord, "ctrl+z")) {
                vm.undo(self.allocator, &tab.doc, &tab.sels) catch {};
                self.afterDocEdit(tab);
            } else if (std.mem.eql(u8, chord, "ctrl+y")) {
                vm.redo(self.allocator, &tab.doc, &tab.sels) catch {};
                self.afterDocEdit(tab);
            } else if (std.mem.eql(u8, chord, "alt+z")) {
                self.toggleWrap(tab);
            } else if (std.mem.eql(u8, chord, "ctrl+home")) {
                vm.moveDocEdge(&tab.doc, &tab.sels, false, false);
                self.afterMove(tab);
            } else if (std.mem.eql(u8, chord, "ctrl+end")) {
                vm.moveDocEdge(&tab.doc, &tab.sels, true, false);
                self.afterMove(tab);
            } else {
                return false;
            }
        }
        return true;
    }
};
