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
//! Deliberate simplifications (documented, not accidental):
//! - Soft wrap breaks at cluster boundaries, not word boundaries
//!   (editor_layout's greedy wrap).
//! - Find is LITERAL only — no regex (editor/search.zig).
//! - The IME preedit is laid out in its own throwaway Document, drawn
//!   OVER the text it will displace behind an opaque backing rect
//!   rather than reflowing the line; with several carets it shows at
//!   the primary caret only and commits to all of them.
//! - Undo restores selections by clamping (Document does not expose
//!   its inverse edits).
//! - Ctrl+Shift+S / Ctrl+Shift+Z are claimed by the editor face
//!   (Save As / Redo), shadowing the global save_layout /
//!   restore_closed_tab while the editor has focus.

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
const sel_mod = @import("../editor/selection.zig");
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const vm = @import("../editor/view_model.zig");
const editor_model = @import("../editor/model.zig");
const syntax = @import("../editor/syntax.zig");
const theme_mod = @import("../editor/theme.zig");
const tabhost_mod = @import("tabhost.zig");
const TabHost = tabhost_mod.TabHost;
const pane_mod = @import("pane.zig");
const Pane = pane_mod.Pane;
const paths = @import("../filebrowser/paths.zig");
const fsdrive = @import("../ipc/fsdrive.zig");
const muxclient = @import("../mux/client.zig");
const input = @import("input.zig");
const Config = @import("../config.zig").Config;
const fpicker = @import("../filebrowser/picker.zig");
const PickerWindow = @import("picker.zig").PickerWindow;

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

/// Refcounted liveness fence shared by IO worker threads, GLib idle
/// deliveries, clipboard reads and dialog callbacks. The mutex only
/// matters for the worker threads; everything else runs on the main
/// loop.
const Fence = struct {
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

    fn ref(self: *Fence) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.refs += 1;
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn unref(self: *Fence) void {
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

    fn viewIfAlive(self: *Fence) ?*EditorView {
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
    mtime_ns: i64 = 0,

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

fn connectFs(host: ?[]const u8) !fsdrive.Fs {
    const allocator = std.heap.c_allocator;
    const conn = if (host) |remote| blk: {
        var config = Config.load(allocator);
        defer config.deinit();
        break :blk try muxclient.Conn.connectRemote(allocator, remote, config.udpRange());
    } else try muxclient.Conn.connectLocalAutostart(allocator);
    return fsdrive.Fs.initConn(allocator, conn);
}

fn readAllCapped(fs: *fsdrive.Fs, path: []const u8, out: *std.ArrayList(u8), mtime_out: *i64) !void {
    const allocator = std.heap.c_allocator;
    const probe = try fs.read(path, 0, 0, out);
    if (probe.size > MAX_FILE_BYTES) return error.SourceTooLarge;
    mtime_out.* = probe.mtime_ns;
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
        if (out.items.len > MAX_FILE_BYTES) return error.SourceTooLarge;
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
                var mtime: i64 = 0;
                readAllCapped(&fs, loc.path, &out, &mtime) catch |err| {
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
                job.mtime_ns = mtime;
                job.ok = true;
            },
            .save => {
                const res = fs.writeFileAtomic(loc.path, job.save_bytes, job.expected_mtime) catch |err| {
                    if (err == fsdrive.Error.Conflict) {
                        job.conflict = true;
                        if (fs.lastConflict()) |ci| job.mtime_ns = ci.mtime_ns;
                    } else {
                        const detail = fs.lastErr();
                        if (detail.len > 0) job.setErr(detail) else job.setErr(@errorName(err));
                    }
                    break :run;
                };
                job.mtime_ns = res.mtime_ns;
                job.ok = true;
            },
        }
    }
    _ = c.g_idle_add(@ptrCast(&ioIdle), @ptrCast(job));
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
    /// Conflict baseline from the last load/save (0 = none).
    mtime_ns: i64 = 0,
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

    fn destroy(self: *ETab) void {
        const a = self.view.allocator;
        // A queued parse timer is fenced (DlgCtx) and resolves to
        // nothing once this tab's id is gone — no removal needed.
        if (self.hl) |hl| {
            hl.deinit();
            a.destroy(hl);
            self.hl = null;
        }
        self.doc.observer = null;
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

const PasteCtx = struct {
    fence: *Fence,
};

pub const EditorView = struct {
    allocator: std.mem.Allocator,
    pane: ?*Pane = null,
    fence: *Fence = undefined,

    root_box: *c.GtkWidget = undefined,
    tabhost: TabHost = undefined,
    area: *c.GtkGLArea = undefined,
    status_label: *c.GtkLabel = undefined,
    im_ctx: ?*c.GtkIMContext = null,
    widgets_dead: bool = false,

    // Scrollbars (vertical range in ESTIMATED rows, horizontal in px).
    vscroll: *c.GtkWidget = undefined,
    hscroll: *c.GtkWidget = undefined,
    vadj: *c.GtkAdjustment = undefined,
    hadj: *c.GtkAdjustment = undefined,
    /// True while WE are writing an adjustment — its value-changed
    /// handler must not treat that as a user drag.
    sb_guard: bool = false,

    // Find/replace bar.
    find_bar: *c.GtkWidget = undefined,
    find_entry: *c.GtkWidget = undefined,
    replace_row: *c.GtkWidget = undefined,
    replace_entry: *c.GtkWidget = undefined,
    find_count: *c.GtkLabel = undefined,
    find_case: *c.GtkWidget = undefined,
    find_word: *c.GtkWidget = undefined,
    find_open: bool = false,

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
    line_numbers: bool = true,
    highlight_current_line: bool = true,
    syntax_on: bool = true,
    /// Colours for text, chrome and every highlight kind. Points at a
    /// comptime constant in `editor/theme.zig`, so it never dangles
    /// across a config-arena swap.
    theme: *const theme_mod.Theme = &theme_mod.dark,

    drag_anchor: ?usize = null,

    /// STANDALONE hosting (ui/editorwin.zig): the face has no pane and
    /// no sketerm Window, so `ownerWindow()` never resolves and these
    /// three fields carry what the window would otherwise supply — the
    /// config to read settings from, the toolbar to hide (the window's
    /// header bar carries those buttons instead), and a change hook the
    /// host uses to keep its title in sync. All null/unused for a pane
    /// face, which keeps the pane path exactly as it was.
    standalone_config: ?*const Config = null,
    toolbar_box: ?*c.GtkWidget = null,
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
        self.fence = Fence.create(self) orelse return error.OutOfMemory;
        self.pane = pane;
        self.font_size = pane.font_size;
        self.line_pad = pane.line_pad_px;
        if (pane.font_path) |fp| self.font_path = allocator.dupe(u8, fp) catch null;
        if (pane.font_family) |ff| self.font_family = allocator.dupe(u8, ff) catch null;

        self.buildUi();
        pane.attachEditor(self.root_box, @ptrCast(self), prepareDestroyCb, destroyCb, focusCb);
        // The face is in the widget tree now, so ownerWindow() (and
        // therefore the config) resolves.
        self.syncConfig();
        self.startBlink();
        if (spec) |s| self.openSpec(s, null) else _ = self.newTab(null);
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
        self.line_numbers = cfg.editor_line_numbers;
        self.highlight_current_line = cfg.editor_highlight_current_line;
        self.syntax_on = cfg.editor_syntax;
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
        tab.doc.observer = null;
        tab.layout.hl = null;
        if (tab.hl) |hl| {
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
            for (state.files) |f| self.openSpec(f.spec, @intCast(f.cursor));
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
        self.fence = Fence.create(self) orelse return error.OutOfMemory;
        self.standalone_config = cfg;
        self.buildUi();
        // The window's header bar carries Open / Save / Save As, and
        // "show this pane's shell" means nothing with no pane.
        if (self.toolbar_box) |bar| c.gtk_widget_set_visible(bar, 0);
        self.syncConfig();
        self.startBlink();
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

    fn prepareDestroyCb(ctx: *anyopaque) void {
        const self: *EditorView = @ptrCast(@alignCast(ctx));
        // Before widgets_dead: ownerWindow() stops resolving after it.
        self.suppressTabViewEdgeKeys(false);
        self.widgets_dead = true;
        self.stopBlink();
        // Sever the IM context here, not in deinit: a multicontext's
        // set_client_widget(NULL) reaches into the client widget's
        // settings, and by deinit the GLArea can already be finalized
        // (GTK criticals, then a NULL instance in the disconnect).
        self.detachIm();
    }

    /// The GLArea can die without detachEditor running (whole-window
    /// teardown); its destroy is the last moment the IM context's
    /// client widget is still a live GObject.
    fn onAreaDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        self.widgets_dead = true;
        self.stopBlink();
        self.detachIm();
    }

    fn focusCb(ctx: *anyopaque) void {
        const self: *EditorView = @ptrCast(@alignCast(ctx));
        if (!self.widgets_dead)
            _ = c.gtk_widget_grab_focus(@ptrCast(self.area));
    }

    pub fn deinit(self: *EditorView) void {
        self.fence.close();
        self.stopBlink();
        self.clearPreedit();
        self.detachIm();
        for (self.tabs.items) |t| t.destroy();
        self.tabs.deinit(self.allocator);
        if (self.atlas) |a| {
            a.deinit();
            self.atlas = null;
        }
        self.pass.deinit();
        if (self.font_path) |s| self.allocator.free(s);
        if (self.font_family) |s| self.allocator.free(s);
        self.allocator.destroy(self);
    }

    /// Same reasoning as Pane.detachIm: the IM context is not owned
    /// by the widget tree, so it must be severed before/at teardown.
    fn detachIm(self: *EditorView) void {
        const im = self.im_ctx orelse return;
        self.im_ctx = null;
        const im_obj: ?*anyopaque = @ptrCast(im);
        _ = c.g_signal_handlers_disconnect_matched(
            im_obj,
            c.G_SIGNAL_MATCH_DATA,
            0,
            0,
            null,
            null,
            @ptrCast(self),
        );
        c.gtk_im_context_set_client_widget(@ptrCast(im), null);
        c.g_object_unref(im_obj);
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
        const bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        c.gtk_widget_set_margin_start(bar, 3);
        c.gtk_widget_set_margin_end(bar, 3);
        c.gtk_widget_set_margin_top(bar, 3);
        c.gtk_widget_set_margin_bottom(bar, 3);
        _ = self.barButton(bar, "document-open-symbolic", "Open a file (Ctrl+O)", &onOpenClicked);
        _ = self.barButton(bar, "document-save-symbolic", "Save (Ctrl+S)", &onSaveClicked);
        _ = self.barButton(bar, "document-save-as-symbolic", "Save As (Ctrl+Shift+S)", &onSaveAsClicked);
        const spacer = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_widget_set_hexpand(spacer, 1);
        c.gtk_box_append(@ptrCast(bar), spacer);
        _ = self.barButton(bar, "sketerm-terminal-symbolic", "Show this pane's shell", &onTerminalClicked);
        c.gtk_box_append(@ptrCast(vbox), bar);
        self.toolbar_box = bar;

        // Document tabs: the shared strip mechanics, pages are empty
        // placeholders (one GLArea below renders the active tab).
        self.tabhost = TabHost.init(self.allocator);
        self.tabhost.ctx = @ptrCast(self);
        self.tabhost.on_close = &hostCloseCb;
        self.tabhost.on_new = &hostNewCb;
        const nb = self.tabhost.widget();
        c.gtk_widget_set_vexpand(nb, 0);
        _ = c.g_signal_connect_data(nb, "switch-page", @ptrCast(&onSwitchPage), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(vbox), nb);
        self.tabhost.installStripGestures();

        // The document canvas, inside an overlay that carries the find
        // bar, in a grid that carries the two scrollbars.
        const area_widget = c.gtk_gl_area_new();
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
        c.gtk_box_append(@ptrCast(vbox), grid);

        // Status line.
        const status = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(status), 0);
        c.gtk_widget_add_css_class(status, "dim-label");
        c.gtk_widget_set_margin_start(status, 6);
        c.gtk_widget_set_margin_bottom(status, 2);
        c.gtk_box_append(@ptrCast(vbox), status);
        self.status_label = @ptrCast(@alignCast(status));

        // Keyboard: IM context first (dead keys / compose), our chord
        // handler for what the IM leaves, pane bindings as fallback.
        const im = c.gtk_im_multicontext_new();
        c.gtk_im_context_set_client_widget(@ptrCast(im), area_widget);
        _ = c.g_signal_connect_data(im, "commit", @ptrCast(&onImCommit), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(im, "preedit-start", @ptrCast(&onPreeditStart), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(im, "preedit-changed", @ptrCast(&onPreeditChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(im, "preedit-end", @ptrCast(&onPreeditEnd), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        self.im_ctx = @ptrCast(im);
        const keys = c.gtk_event_controller_key_new();
        c.gtk_event_controller_key_set_im_context(@ptrCast(keys), @ptrCast(im));
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

        // Wheel scrolling.
        const scroll = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
        _ = c.g_signal_connect_data(scroll, "scroll", @ptrCast(&onScroll), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(scroll));

        self.root_box = vbox;
    }

    fn barButton(self: *EditorView, box: ?*c.GtkWidget, icon: [*:0]const u8, tooltip: [*:0]const u8, cb: *const fn (*c.GtkButton, ?*anyopaque) callconv(.c) void) *c.GtkWidget {
        const btn = c.gtk_button_new_from_icon_name(icon);
        c.gtk_button_set_has_frame(@ptrCast(btn), 0);
        c.gtk_widget_set_tooltip_text(btn, tooltip);
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(cb), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), btn);
        return btn.?;
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
        const entry = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(entry), "Find");
        c.gtk_editable_set_width_chars(@ptrCast(entry), 22);
        _ = c.g_signal_connect_data(entry, "changed", @ptrCast(&onFindChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onFindActivate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), entry);
        self.find_entry = entry.?;

        const count = c.gtk_label_new("");
        c.gtk_widget_add_css_class(count, "dim-label");
        c.gtk_label_set_width_chars(@ptrCast(count), 9);
        c.gtk_label_set_xalign(@ptrCast(count), 0);
        c.gtk_box_append(@ptrCast(row), count);
        self.find_count = @ptrCast(@alignCast(count));

        self.find_case = self.toggleButton(row, "Aa", "Match case");
        self.find_word = self.toggleButton(row, "\u{2423}W", "Whole word only");
        _ = self.barButton(row, "go-up-symbolic", "Previous match (Shift+Enter)", &onFindPrevClicked);
        _ = self.barButton(row, "go-down-symbolic", "Next match (Enter)", &onFindNextClicked);
        _ = self.barButton(row, "window-close-symbolic", "Close (Escape)", &onFindCloseClicked);
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

    fn toggleButton(self: *EditorView, box: ?*c.GtkWidget, label: [*:0]const u8, tooltip: [*:0]const u8) *c.GtkWidget {
        const btn = c.gtk_toggle_button_new_with_label(label);
        c.gtk_button_set_has_frame(@ptrCast(btn), 0);
        c.gtk_widget_set_tooltip_text(btn, tooltip);
        _ = c.g_signal_connect_data(btn, "toggled", @ptrCast(&onFindOptionToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), btn);
        return btn.?;
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
        };
        tab.layout.tab_cols = self.tab_width;
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
        self.refresh(tab);
        return tab;
    }

    /// Open (or focus) `spec`; `cursor` restores after the load.
    pub fn openSpec(self: *EditorView, spec: []const u8, cursor: ?usize) void {
        for (self.tabs.items) |t| {
            if (t.spec) |ts| {
                if (std.mem.eql(u8, ts, spec)) {
                    self.tabhost.setCurrentPage(t.page);
                    return;
                }
            }
        }
        if (self.newTab(spec)) |tab| tab.want_cursor = cursor;
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

    fn onSwitchPage(_: *c.GtkNotebook, page: *c.GtkWidget, _: c.guint, user: ?*anyopaque) callconv(.c) void {
        const self: *EditorView = @ptrCast(@alignCast(user.?));
        if (self.widgets_dead) return;
        self.active = self.findTabByPage(page);
        self.updateStatus();
        self.queueRender();
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
        const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(c.adw_alert_dialog_new("Save changes?", b.ptr)));
        c.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
        c.adw_alert_dialog_add_response(dialog, "discard", "Discard");
        c.adw_alert_dialog_add_response(dialog, "save", "Save");
        c.adw_alert_dialog_set_response_appearance(dialog, "discard", c.ADW_RESPONSE_DESTRUCTIVE);
        c.adw_alert_dialog_set_response_appearance(dialog, "save", c.ADW_RESPONSE_SUGGESTED);
        c.adw_alert_dialog_set_default_response(dialog, "save");
        c.adw_alert_dialog_set_close_response(dialog, "cancel");
        c.adw_alert_dialog_choose(dialog, self.dialogParent(), null, onCloseDirtyResponse, @ptrCast(ctx));
    }

    fn dialogParent(self: *EditorView) ?*c.GtkWidget {
        if (self.widgets_dead) return null;
        const root = c.gtk_widget_get_root(self.root_box) orelse return null;
        return @ptrCast(@alignCast(root));
    }

    fn onCloseDirtyResponse(source: [*c]c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
        const ctx: *DlgCtx = @ptrCast(@alignCast(user.?));
        defer ctx.destroy();
        const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(source));
        const resp = std.mem.span(@as([*:0]const u8, @ptrCast(c.adw_alert_dialog_choose_finish(dialog, result))));
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
            // No documents left: hand the pane back to its shell.
            if (self.tabs.items.len == 0) {
                if (self.pane) |p| p.setEditorVisible(false);
            }
            self.updateStatus();
            self.queueRender();
        }
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
        if (self.atlas) |a| a.releaseGL();
    }

    fn onRender(area: *c.GtkGLArea, _: ?*c.GdkGLContext, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(EditorView, user);
        const w = c.gtk_widget_get_width(@ptrCast(area));
        const h = c.gtk_widget_get_height(@ptrCast(area));
        const scale = c.gtk_widget_get_scale_factor(@ptrCast(area));
        const pw: c_int = w * scale;
        const ph: c_int = h * scale;
        c.glViewport(0, 0, pw, ph);
        const bg = self.theme.bg;
        c.glClearColor(bg[0], bg[1], bg[2], bg[3]);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        const atlas = self.atlas orelse return 1;
        const tab = self.active orelse return 1;
        self.ensureRows(tab);
        self.clampAnchor(tab, @floatFromInt(ph));
        const view = editor_pass.View{
            .width_px = @floatFromInt(pw),
            .height_px = @floatFromInt(ph),
            .anchor = tab.anchor,
            .scroll_x = tab.scroll_x,
            .show_line_numbers = self.line_numbers,
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
            const gutter = EditorPass.gutterWidth(atlas, tab.doc.rope.lineCount(), self.line_numbers) catch 0;
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
        if (tab.rows_lines == n and tab.rows.enabled == (tab.layout.wrap_width != null) and
            @abs(tab.rows_wrap_width - ww) < 0.5) return;
        tab.rows.reset(tab.layout.wrap_width != null, n);
        tab.rows_lines = n;
        tab.rows_wrap_width = ww;
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
        var line = @min(tab.anchor.line, n_lines -| 1);
        var row: i64 = tab.anchor.row;
        while (acc >= line_h) {
            const rows = self.rowsOfLine(tab, line);
            if (row + 1 < rows) {
                row += 1;
            } else if (line + 1 < n_lines) {
                line += 1;
                row = 0;
            } else break;
            acc -= line_h;
        }
        while (acc < 0) {
            if (row > 0) {
                row -= 1;
            } else if (line > 0) {
                line -= 1;
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
        const gutter = EditorPass.gutterWidth(atlas, n_lines, self.line_numbers) catch 0;
        const text_x0 = gutter + 8 - tab.scroll_x;

        var li = @min(tab.anchor.line, n_lines - 1);
        var top: f32 = -tab.anchor.offset - @as(f32, @floatFromInt(tab.anchor.row)) * line_h;
        while (true) {
            const ll = tab.layout.line(&tab.doc, li) catch return tab.doc.rope.lineToOffset(li);
            const bottom = top + @as(f32, @floatFromInt(ll.rows.len)) * line_h;
            if (y < bottom or li + 1 >= n_lines) {
                var row: u32 = 0;
                if (y > top) {
                    const r: usize = @intFromFloat(@floor((y - top) / line_h));
                    row = @intCast(@min(r, ll.rows.len - 1));
                }
                return ll.byte_start + Layout.xToByte(ll, row, x - text_x0);
            }
            top = bottom;
            li += 1;
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
        const im = self.im_ctx orelse return;
        if (self.atlas == null) return;
        const scale: f32 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
        if (scale <= 0) return;
        self.ensureRows(tab);
        const line_h = self.lineHeight();
        const rel_row: f32 = @floatFromInt(
            (tab.rows.rowsBefore(cv.line) + cv.row) -| viewport_mod.anchorRow(&tab.rows, tab.anchor),
        );
        var rect: c.GdkRectangle = .{
            .x = @intFromFloat((self.pass.text_origin_x + cv.x) / scale),
            .y = @intFromFloat((rel_row * line_h - tab.anchor.offset) / scale),
            .width = 1,
            .height = @intFromFloat(line_h / scale),
        };
        c.gtk_im_context_set_cursor_location(im, &rect);
    }

    // ---- scrollbars ---------------------------------------------------

    fn syncScrollbars(self: *EditorView, tab: *ETab, view_w: f32, view_h: f32) void {
        if (self.widgets_dead) return;
        const line_h = self.lineHeight();
        if (line_h <= 0) return;
        const n_lines = tab.doc.rope.lineCount();
        const total: f64 = @floatFromInt(tab.rows.totalRows(n_lines));
        const page: f64 = @max(1.0, @as(f64, view_h / line_h));
        const value: f64 = @floatFromInt(viewport_mod.anchorRow(&tab.rows, tab.anchor));
        self.sb_guard = true;
        c.gtk_adjustment_configure(self.vadj, value, 0, @max(total, page), 1, @max(1.0, page - 1), page);
        // Horizontal: only meaningful with wrap off.
        const text_w: f64 = @max(1.0, view_w - self.pass.text_origin_x - tab.scroll_x);
        const hupper: f64 = @max(@as(f64, tab.max_width + 40), text_w);
        c.gtk_adjustment_configure(self.hadj, tab.scroll_x, 0, hupper, 20, text_w * 0.9, text_w);
        self.sb_guard = false;
        // Only when it CHANGES: this runs inside the render handler, and
        // an unconditional set_visible queues a resize every frame.
        const want_h = !tab.wrap and hupper > text_w + 1;
        if ((c.gtk_widget_get_visible(self.hscroll) != 0) != want_h)
            c.gtk_widget_set_visible(self.hscroll, if (want_h) 1 else 0);
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
    /// GtkGLArea leaks under Wayland (Pane.blink_timer, same reason).
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

    /// Rebuild the throwaway preedit document from the IM context.
    fn refreshPreedit(self: *EditorView) void {
        const im = self.im_ctx orelse return;
        var text: [*c]u8 = null;
        var attrs: ?*c.PangoAttrList = null;
        var cursor: c_int = 0;
        c.gtk_im_context_get_preedit_string(im, &text, @ptrCast(&attrs), &cursor);
        defer {
            if (text != null) c.g_free(text);
            if (attrs) |a| c.pango_attr_list_unref(a);
        }
        self.clearPreedit();
        if (text == null) return;
        const span = std.mem.span(@as([*:0]const u8, @ptrCast(text)));
        if (span.len == 0) return;
        var doc = Document.initFromBytes(self.allocator, span) catch return;
        self.preedit_doc = doc;
        doc = undefined;
        self.preedit_layout = Layout.init(self.allocator, &self.book);
        self.preedit_layout.?.tab_cols = self.tab_width;
        // `cursor` is a CHARACTER offset; the pass wants bytes.
        const cp_idx: usize = if (cursor < 0) 0 else @intCast(cursor);
        var byte: usize = 0;
        var seen: usize = 0;
        while (byte < span.len and seen < cp_idx) : (seen += 1) {
            byte += std.unicode.utf8ByteSequenceLength(span[byte]) catch 1;
        }
        self.preedit_cursor = @min(byte, span.len);
        self.noteActivity();
    }

    fn onPreeditStart(_: *c.GtkIMContext, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        self.refreshPreedit();
        self.queueRender();
    }

    fn onPreeditChanged(_: *c.GtkIMContext, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        self.refreshPreedit();
        if (self.active) |tab| self.ensureCaretVisible(tab);
        self.queueRender();
    }

    fn onPreeditEnd(_: *c.GtkIMContext, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
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
        if (self.im_ctx) |im| c.gtk_im_context_focus_in(im);
        self.suppressTabViewEdgeKeys(true);
        self.noteActivity();
        self.queueRender();
    }

    fn onFocusLeave(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorView, user);
        if (self.im_ctx) |im| c.gtk_im_context_focus_out(im);
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
        };
    }

    fn entryText(w: *c.GtkWidget) []const u8 {
        const buf = c.gtk_entry_buffer_get_text(c.gtk_entry_get_buffer(@ptrCast(w)));
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
        if (needle.len > 0) {
            tab.matches = search.findAll(self.allocator, &tab.doc, needle, self.findOptions()) catch &.{};
        }
        if (select and tab.matches.len > 0) {
            tab.current_match = search.pick(tab.matches, tab.sels.primary().start(), true);
        }
        self.updateFindCount(tab);
        self.queueRender();
    }

    fn updateFindCount(self: *EditorView, tab: *ETab) void {
        var buf: [40:0]u8 = undefined;
        const txt: [:0]const u8 = if (tab.matches.len == 0)
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
        self.updateFindCount(tab);
        self.ensureCaretVisible(tab);
        self.updateStatus();
        self.queueRender();
    }

    fn replaceCurrent(self: *EditorView) void {
        const tab = self.active orelse return;
        const idx = tab.current_match orelse {
            self.stepMatch(true);
            return;
        };
        if (idx >= tab.matches.len) return;
        const m = tab.matches[idx];
        const with = entryText(self.replace_entry);
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
        const with = entryText(self.replace_entry);
        const tr = @import("../editor/transaction.zig");
        var tx = tr.Transaction.init(tab.doc.revision);
        defer tx.deinit(self.allocator);
        var prev_end: usize = 0;
        var applied: usize = 0;
        for (tab.matches) |m| {
            if (m.start < prev_end) continue; // overlapping (can't happen, defensive)
            tx.addReplace(self.allocator, m.start, m.end - m.start, with) catch return;
            prev_end = m.end;
            applied += 1;
        }
        _ = tab.doc.applyTransaction(&tx) catch return;
        tab.sels.mapThrough(tx.edits.items, .editor);
        vm.clampSelections(&tab.doc, &tab.sels);
        var buf: [64:0]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "Replaced {d} occurrence(s).", .{applied}) catch "Replaced.";
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
        if (self.find_open) self.recomputeMatches(tab, false);
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

    fn refresh(self: *EditorView, tab: *ETab) void {
        if (self.widgets_dead) return;
        tab.handle.setTitle(tab.title());
        tab.handle.setDirty(tab.isDirty());
        self.noteActivity();
        self.ensureCaretVisible(tab);
        self.updateStatus();
        self.queueRender();
    }

    fn updateStatus(self: *EditorView) void {
        if (self.widgets_dead) return;
        // Every path that changes the caret, the active tab, the tab
        // set or a dirty flag funnels through here, so this is the one
        // place a standalone host has to watch to keep its window title
        // honest.
        if (self.on_changed) |cb| cb(self.changed_ctx orelse undefined);
        const tab = self.active orelse {
            c.gtk_label_set_text(self.status_label, "");
            return;
        };
        var buf: [200:0]u8 = undefined;
        if (tab.loading) {
            c.gtk_label_set_text(self.status_label, "Loading…");
            return;
        }
        const lc = tab.doc.rope.offsetToLineCol(tab.sels.primary().head);
        const carets = tab.sels.count();
        const wrap_note: []const u8 = if (tab.wrap) "  —  Wrap" else "";
        const txt = if (carets > 1)
            std.fmt.bufPrintZ(&buf, "Ln {d}, Col {d}  —  {d} carets{s}", .{ lc.line + 1, lc.col + 1, carets, wrap_note }) catch return
        else
            std.fmt.bufPrintZ(&buf, "Ln {d}, Col {d}{s}", .{ lc.line + 1, lc.col + 1, wrap_note }) catch return;
        c.gtk_label_set_text(self.status_label, txt.ptr);
    }

    fn setStatus(self: *EditorView, text: [*:0]const u8) void {
        if (self.widgets_dead) return;
        c.gtk_label_set_text(self.status_label, text);
    }

    // ---- IO -----------------------------------------------------------

    fn startLoad(self: *EditorView, tab: *ETab) void {
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
        job.* = .{ .fence = self.fence, .gen = tab.io_gen, .kind = .load, .spec = owned };
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
        self.startSave(tab, if (tab.mtime_ns != 0) tab.mtime_ns else null);
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
                    // New file: keep the empty document, no baseline.
                    tab.mtime_ns = 0;
                    self.setStatus("New file.");
                    self.refresh(tab);
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
                tab.layout.invalidateAll();
                tab.rows_lines = 0;
                tab.anchor = .{};
                tab.scroll_x = 0;
                tab.max_width = 0;
                self.applyWrapWidth(tab);
                tab.mtime_ns = job.mtime_ns;
                const caret = @min(tab.want_cursor orelse 0, tab.doc.rope.len());
                tab.want_cursor = null;
                tab.sels.keepPrimaryOnly();
                tab.sels.sels.items[0] = Selection.caret(caret);
                self.refresh(tab);
            },
            .save => {
                if (job.conflict) {
                    tab.close_after_save = false;
                    self.conflictDialog(tab, job.mtime_ns);
                    self.updateStatus();
                    return;
                }
                if (!job.ok) {
                    tab.close_after_save = false;
                    self.errorDialog("Save failed", job.errText());
                    self.updateStatus();
                    return;
                }
                tab.mtime_ns = job.mtime_ns;
                if (tab.doc.revision == job.revision) tab.doc.markSaved();
                if (tab.close_after_save) {
                    tab.close_after_save = false;
                    if (!tab.isDirty()) {
                        self.closeTabForce(tab);
                        return;
                    }
                }
                self.setStatus("Saved.");
                self.refresh(tab);
            },
        }
    }

    fn errorDialog(self: *EditorView, heading: [*:0]const u8, detail: []const u8) void {
        var body: [200:0]u8 = undefined;
        const b = std.fmt.bufPrintZ(&body, "{s}", .{detail}) catch "unknown error";
        const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(c.adw_alert_dialog_new(heading, b.ptr)));
        c.adw_alert_dialog_add_response(dialog, "ok", "OK");
        c.adw_alert_dialog_set_default_response(dialog, "ok");
        c.adw_alert_dialog_set_close_response(dialog, "ok");
        c.adw_dialog_present(@ptrCast(dialog), self.dialogParent());
    }

    /// The file on disk changed since load/last save.
    fn conflictDialog(self: *EditorView, tab: *ETab, disk_mtime: i64) void {
        _ = disk_mtime;
        const ctx = DlgCtx.create(self, tab) orelse return;
        const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(c.adw_alert_dialog_new(
            "File changed on disk",
            "The file was modified outside this editor since it was loaded. Overwrite the on-disk version, or reload it (discarding your changes)?",
        )));
        c.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
        c.adw_alert_dialog_add_response(dialog, "reload", "Reload");
        c.adw_alert_dialog_add_response(dialog, "overwrite", "Overwrite");
        c.adw_alert_dialog_set_response_appearance(dialog, "overwrite", c.ADW_RESPONSE_DESTRUCTIVE);
        c.adw_alert_dialog_set_default_response(dialog, "cancel");
        c.adw_alert_dialog_set_close_response(dialog, "cancel");
        c.adw_alert_dialog_choose(dialog, self.dialogParent(), null, onConflictResponse, @ptrCast(ctx));
    }

    fn onConflictResponse(source: [*c]c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
        const ctx: *DlgCtx = @ptrCast(@alignCast(user.?));
        defer ctx.destroy();
        const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(source));
        const resp = std.mem.span(@as([*:0]const u8, @ptrCast(c.adw_alert_dialog_choose_finish(dialog, result))));
        const r = ctx.resolve() orelse return;
        if (std.mem.eql(u8, resp, "overwrite")) {
            r.view.startSave(r.tab, null);
        } else if (std.mem.eql(u8, resp, "reload")) {
            if (r.tab.isDirty()) {
                r.view.confirmReloadDirty(r.tab);
            } else {
                r.view.startLoad(r.tab);
            }
        }
    }

    fn confirmReloadDirty(self: *EditorView, tab: *ETab) void {
        const ctx = DlgCtx.create(self, tab) orelse return;
        const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(c.adw_alert_dialog_new(
            "Discard your changes?",
            "Reloading replaces the buffer with the on-disk version; your unsaved edits are lost.",
        )));
        c.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
        c.adw_alert_dialog_add_response(dialog, "reload", "Discard and Reload");
        c.adw_alert_dialog_set_response_appearance(dialog, "reload", c.ADW_RESPONSE_DESTRUCTIVE);
        c.adw_alert_dialog_set_default_response(dialog, "cancel");
        c.adw_alert_dialog_set_close_response(dialog, "cancel");
        c.adw_alert_dialog_choose(dialog, self.dialogParent(), null, onReloadDirtyResponse, @ptrCast(ctx));
    }

    fn onReloadDirtyResponse(source: [*c]c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
        const ctx: *DlgCtx = @ptrCast(@alignCast(user.?));
        defer ctx.destroy();
        const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(source));
        const resp = std.mem.span(@as([*:0]const u8, @ptrCast(c.adw_alert_dialog_choose_finish(dialog, result))));
        const r = ctx.resolve() orelse return;
        if (std.mem.eql(u8, resp, "reload")) r.view.startLoad(r.tab);
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
        r.tab.mtime_ns = 0;
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

    fn onImCommit(_: *c.GtkIMContext, text: [*:0]const u8, user: ?*anyopaque) callconv(.c) void {
        const self: *EditorView = @ptrCast(@alignCast(user.?));
        const tab = self.active orelse return;
        const len = std.mem.len(text);
        if (len == 0) return;
        self.insertText(tab, text[0..len]);
    }

    fn copySelection(self: *EditorView, tab: *ETab) void {
        const text = vm.selectedText(self.allocator, &tab.doc, &tab.sels) catch return;
        defer self.allocator.free(text);
        if (text.len == 0) return;
        const z = self.allocator.dupeZ(u8, text) catch return;
        defer self.allocator.free(z);
        const display = c.gtk_widget_get_display(@ptrCast(self.area));
        const clipboard = c.gdk_display_get_clipboard(display);
        c.gdk_clipboard_set_text(clipboard, z.ptr);
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
        const ctx = std.heap.c_allocator.create(PasteCtx) catch return;
        self.fence.ref();
        ctx.* = .{ .fence = self.fence };
        const display = c.gtk_widget_get_display(@ptrCast(self.area));
        const clipboard = c.gdk_display_get_clipboard(display);
        c.gdk_clipboard_read_text_async(clipboard, null, @ptrCast(&onPasteRead), @ptrCast(ctx));
    }

    fn onPasteRead(source: ?*c.GObject, result: *c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
        const ctx: *PasteCtx = @ptrCast(@alignCast(user.?));
        defer {
            ctx.fence.unref();
            std.heap.c_allocator.destroy(ctx);
        }
        const clipboard: *c.GdkClipboard = @ptrCast(source);
        const text_ptr = c.gdk_clipboard_read_text_finish(clipboard, result, null);
        if (text_ptr == null) return;
        defer c.g_free(text_ptr);
        const view = ctx.fence.viewIfAlive() orelse return;
        const tab = view.active orelse return;
        const cstr: [*:0]const u8 = @ptrCast(text_ptr);
        view.insertText(tab, cstr[0..std.mem.len(cstr)]);
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
        while (left > 0) : (left -= 1) {
            const rows = self.rowsOfLine(tab, line);
            if (row + 1 < rows) {
                row += 1;
            } else if (line + 1 < n_lines) {
                line += 1;
                row = 0;
            } else return null;
        }
        while (left < 0) : (left += 1) {
            if (row > 0) {
                row -= 1;
            } else if (line > 0) {
                line -= 1;
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
                            vm.undo(&tab.doc, &tab.sels) catch {};
                            self.afterDocEdit(tab);
                            return 1;
                        },
                        c.GDK_KEY_y => {
                            vm.redo(&tab.doc, &tab.sels) catch {};
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
                        else => {},
                    }
                }
                if (ctrl and shift) {
                    switch (lower) {
                        c.GDK_KEY_z => {
                            vm.redo(&tab.doc, &tab.sels) catch {};
                            self.afterDocEdit(tab);
                            return 1;
                        },
                        c.GDK_KEY_s => {
                            self.saveTabAs(tab);
                            return 1;
                        },
                        else => {},
                    }
                }
            }
        } else if (self.active) |tab| {
            // Alt+Z: soft wrap toggle (the VS Code chord).
            if (lower == c.GDK_KEY_z and !ctrl and !shift) {
                self.toggleWrap(tab);
                return 1;
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
                vm.insertNewlineIndent(a, &tab.doc, &tab.sels) catch {};
                tab.goal_x = null;
                self.afterDocEdit(tab);
                return true;
            },
            c.GDK_KEY_Tab => {
                if (ctrl or shift) return false;
                vm.insertTabStop(a, &tab.doc, &tab.sels, self.tab_width, self.insert_spaces) catch {};
                tab.goal_x = null;
                self.afterDocEdit(tab);
                return true;
            },
            c.GDK_KEY_Escape => {
                if (self.find_open) {
                    self.closeFind();
                    return true;
                }
                if (tab.sels.count() <= 1) return false;
                vm.collapseToPrimary(&tab.sels);
                self.refresh(tab);
                return true;
            },
            else => return false,
        }
    }

    fn afterMove(self: *EditorView, tab: *ETab) void {
        self.ensureCaretVisible(tab);
        self.updateStatus();
        self.queueRender();
    }

    // ---- mouse --------------------------------------------------------

    fn onClickPressed(gesture: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const self: *EditorView = @ptrCast(@alignCast(user.?));
        const tab = self.active orelse return;
        _ = c.gtk_widget_grab_focus(@ptrCast(self.area));
        const state = c.gtk_event_controller_get_current_event_state(@ptrCast(gesture));
        const mods = state & input.SIGNIFICANT_MODS;
        const ctrl = (mods & c.GDK_CONTROL_MASK) != 0;
        const shift = (mods & c.GDK_SHIFT_MASK) != 0;
        const pos = self.hitTest(tab, x, y);
        tab.goal_x = null;
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
    }

    fn onMotion(_: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const self: *EditorView = @ptrCast(@alignCast(user.?));
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
            try files.append(arena, .{
                .spec = try arena.dupe(u8, spec),
                .cursor = @intCast(t.sels.primary().head),
            });
            i += 1;
        }
        return .{ .files = files.items, .active = active_idx };
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
                vm.undo(&tab.doc, &tab.sels) catch {};
                self.afterDocEdit(tab);
            } else if (std.mem.eql(u8, chord, "ctrl+y")) {
                vm.redo(&tab.doc, &tab.sels) catch {};
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
