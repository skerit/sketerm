//! EditorView — the text-editor face on a Pane (browser-face
//! precedent: attach/detach via Pane's five-pointer contract, key
//! fallback to the pane's binding table, deferred teardown fenced by
//! `widgets_dead`).
//!
//! Structure: a TabHost whose notebook is a STRIP ONLY (pages are
//! empty zero-height boxes) above ONE GtkGLArea that renders the
//! active tab through editor_layout + editor_pass. Inactive tabs keep
//! models only. The GL realize/unrealize contract is Pane's exactly:
//! adoptAreaApi + forget-all on realize, releaseGL under a current
//! context on unrealize.
//!
//! Deliberate v1 simplifications (documented, not accidental):
//! - No soft wrap: line i sits at y = i * line_h, long lines overflow
//!   to the right (follow the caret with Home/End).
//! - IM preedit is not drawn; committed text inserts at all carets.
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
const Document = @import("../editor/document.zig").Document;
const sel_mod = @import("../editor/selection.zig");
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const vm = @import("../editor/view_model.zig");
const editor_model = @import("../editor/model.zig");
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

const BG_COLOR = [4]f32{ 0.09, 0.09, 0.12, 1.0 };

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
    scroll_y: f32 = 0,
    goal_x: ?f32 = null,
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

    fn destroy(self: *ETab) void {
        const a = self.view.allocator;
        self.layout.deinit();
        self.sels.deinit(a);
        self.doc.deinit();
        if (self.spec) |s| a.free(s);
        a.destroy(self);
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

    drag_anchor: ?usize = null,

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
        if (spec) |s| self.openSpec(s, null) else _ = self.newTab(null);
        return self;
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
        self.widgets_dead = true;
    }

    fn focusCb(ctx: *anyopaque) void {
        const self: *EditorView = @ptrCast(@alignCast(ctx));
        if (!self.widgets_dead)
            _ = c.gtk_widget_grab_focus(@ptrCast(self.area));
    }

    pub fn deinit(self: *EditorView) void {
        self.fence.close();
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

        // The document canvas.
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
        c.gtk_box_append(@ptrCast(vbox), area_widget);

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
        const im = c.gtk_im_context_simple_new();
        c.gtk_im_context_set_client_widget(@ptrCast(im), area_widget);
        _ = c.g_signal_connect_data(im, "commit", @ptrCast(&onImCommit), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        self.im_ctx = @ptrCast(im);
        const keys = c.gtk_event_controller_key_new();
        c.gtk_event_controller_key_set_im_context(@ptrCast(keys), @ptrCast(im));
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKeyPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(keys));

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
        };
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
        c.glClearColor(BG_COLOR[0], BG_COLOR[1], BG_COLOR[2], BG_COLOR[3]);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        const atlas = self.atlas orelse return 1;
        const tab = self.active orelse return 1;
        self.clampScroll(tab, @floatFromInt(ph));
        const view = editor_pass.View{
            .width_px = @floatFromInt(pw),
            .height_px = @floatFromInt(ph),
            .scroll_y = tab.scroll_y,
        };
        self.pass.buildFrame(&tab.layout, &tab.doc, &tab.sels, self.colors, view) catch return 1;
        self.pass.draw(atlas, pw, ph);
        return 1;
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

    fn clampScroll(self: *EditorView, tab: *ETab, view_h: f32) void {
        const line_h = self.lineHeight();
        const total: f32 = @as(f32, @floatFromInt(tab.doc.rope.lineCount())) * line_h;
        const max_scroll = @max(0.0, total - @max(line_h, view_h * 0.5));
        tab.scroll_y = std.math.clamp(tab.scroll_y, 0.0, max_scroll);
    }

    /// x offset where document text starts (gutter + margin), the
    /// mirror of EditorPass.buildFrame's computation.
    fn textOriginX(self: *EditorView, tab: *ETab) f32 {
        const atlas = self.atlas orelse return 0;
        var digits: usize = 1;
        var v = tab.doc.rope.lineCount();
        while (v >= 10) : (v /= 10) digits += 1;
        const digit_g = atlas.lookupOrLoad('0', false, false) catch return 0;
        const gutter_pad: f32 = 6;
        const gutter_w = @as(f32, @floatFromInt(digits)) * digit_g.advance + gutter_pad * 2;
        return gutter_w + 8; // View.margin_x default
    }

    /// Widget-space (logical) coordinates → document byte offset.
    fn hitTest(self: *EditorView, tab: *ETab, lx: f64, ly: f64) usize {
        if (self.atlas == null) return 0;
        const scale: f32 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
        const x: f32 = @as(f32, @floatCast(lx)) * scale;
        const y: f32 = @as(f32, @floatCast(ly)) * scale + tab.scroll_y;
        const line_h = self.lineHeight();
        const n_lines = tab.doc.rope.lineCount();
        var li: usize = if (y <= 0) 0 else @intFromFloat(@floor(y / line_h));
        if (li >= n_lines) li = n_lines - 1;
        const ll = tab.layout.line(&tab.doc, li) catch return 0;
        const rel = Layout.xToByte(ll, 0, x - self.textOriginX(tab));
        return ll.byte_start + rel;
    }

    fn ensureCaretVisible(self: *EditorView, tab: *ETab) void {
        if (self.widgets_dead) return;
        const line_h = self.lineHeight();
        const lb = vm.lineBoundsAt(&tab.doc, tab.sels.primary().head);
        const y: f32 = @as(f32, @floatFromInt(lb.line)) * line_h;
        const view_h = self.viewportHeightPx();
        if (view_h <= 0) return;
        if (y < tab.scroll_y) tab.scroll_y = y;
        if (y + line_h > tab.scroll_y + view_h) tab.scroll_y = y + line_h - view_h;
        if (tab.scroll_y < 0) tab.scroll_y = 0;
    }

    // ---- shared post-edit refresh ------------------------------------

    fn refresh(self: *EditorView, tab: *ETab) void {
        if (self.widgets_dead) return;
        tab.handle.setTitle(tab.title());
        tab.handle.setDirty(tab.isDirty());
        self.ensureCaretVisible(tab);
        self.updateStatus();
        self.queueRender();
    }

    fn updateStatus(self: *EditorView) void {
        if (self.widgets_dead) return;
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
        const txt = if (carets > 1)
            std.fmt.bufPrintZ(&buf, "Ln {d}, Col {d}  —  {d} carets", .{ lc.line + 1, lc.col + 1, carets }) catch return
        else
            std.fmt.bufPrintZ(&buf, "Ln {d}, Col {d}", .{ lc.line + 1, lc.col + 1 }) catch return;
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
                tab.layout.invalidateAll();
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

    fn saveTabAs(self: *EditorView, tab: *ETab) void {
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
        r.view.refresh(r.tab);
        r.view.startSave(r.tab, null);
    }

    const OpenCtx = struct {
        fence: *Fence,
    };

    fn openPicker(self: *EditorView) void {
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
        self.refresh(tab);
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
        self.refresh(tab);
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

    /// Up/down by visual row (== line, wrap being off) preserving the
    /// goal column through the layout's caret x.
    fn moveVertical(self: *EditorView, tab: *ETab, delta: isize, extend: bool) void {
        const n_lines = tab.doc.rope.lineCount();
        var goal_set = tab.goal_x;
        for (tab.sels.sels.items) |*s| {
            const lb = vm.lineBoundsAt(&tab.doc, s.head);
            var x: f32 = 0;
            if (self.atlas != null) {
                if (tab.layout.line(&tab.doc, lb.line)) |ll| {
                    x = Layout.caretPos(ll, s.head - lb.start).x;
                } else |_| {}
            }
            const use_x = goal_set orelse x;
            if (goal_set == null) goal_set = x;
            const target_line_i: isize = @as(isize, @intCast(lb.line)) + delta;
            var head: usize = undefined;
            if (target_line_i < 0) {
                head = 0;
            } else if (target_line_i >= @as(isize, @intCast(n_lines))) {
                head = tab.doc.rope.len();
            } else {
                const tl: usize = @intCast(target_line_i);
                const tstart = tab.doc.rope.lineToOffset(tl);
                if (self.atlas != null) {
                    if (tab.layout.line(&tab.doc, tl)) |tll| {
                        head = tstart + Layout.xToByte(tll, 0, use_x);
                    } else |_| {
                        head = tstart;
                    }
                } else {
                    head = tstart;
                }
            }
            s.head = head;
            if (!extend) s.anchor = head;
        }
        tab.goal_x = goal_set;
        tab.sels.normalize();
        self.ensureCaretVisible(tab);
        self.updateStatus();
        self.queueRender();
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
                            tab.layout.invalidateAll();
                            self.refresh(tab);
                            return 1;
                        },
                        c.GDK_KEY_y => {
                            vm.redo(&tab.doc, &tab.sels) catch {};
                            tab.layout.invalidateAll();
                            self.refresh(tab);
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
                            tab.layout.invalidateAll();
                            self.refresh(tab);
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
                if (ctrl) vm.moveDocEdge(&tab.doc, &tab.sels, false, shift) else vm.moveLineEdge(&tab.doc, &tab.sels, false, shift);
                tab.goal_x = null;
                self.afterMove(tab);
                return true;
            },
            c.GDK_KEY_End, c.GDK_KEY_KP_End => {
                if (ctrl) vm.moveDocEdge(&tab.doc, &tab.sels, true, shift) else vm.moveLineEdge(&tab.doc, &tab.sels, true, shift);
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
                self.refresh(tab);
                return true;
            },
            c.GDK_KEY_Delete, c.GDK_KEY_KP_Delete => {
                vm.deleteForward(a, &tab.doc, &tab.sels, ctrl) catch {};
                tab.goal_x = null;
                self.refresh(tab);
                return true;
            },
            c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => {
                vm.insertNewlineIndent(a, &tab.doc, &tab.sels) catch {};
                tab.goal_x = null;
                self.refresh(tab);
                return true;
            },
            c.GDK_KEY_Tab => {
                if (ctrl or shift) return false;
                vm.insertTabStop(a, &tab.doc, &tab.sels) catch {};
                tab.goal_x = null;
                self.refresh(tab);
                return true;
            },
            c.GDK_KEY_Escape => {
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

    fn onScroll(_: *c.GtkEventControllerScroll, _: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *EditorView = @ptrCast(@alignCast(user.?));
        const tab = self.active orelse return 0;
        if (dy == 0) return 0;
        const line_h = self.lineHeight();
        tab.scroll_y += @as(f32, @floatCast(dy)) * line_h * 3.0;
        self.clampScroll(tab, self.viewportHeightPx());
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
                self.refresh(tab);
            } else if (std.mem.eql(u8, chord, "tab")) {
                vm.insertTabStop(self.allocator, &tab.doc, &tab.sels) catch return false;
                self.refresh(tab);
            } else if (std.mem.eql(u8, chord, "backspace")) {
                vm.deleteBackward(self.allocator, &tab.doc, &tab.sels, false) catch return false;
                self.refresh(tab);
            } else if (std.mem.eql(u8, chord, "delete")) {
                vm.deleteForward(self.allocator, &tab.doc, &tab.sels, false) catch return false;
                self.refresh(tab);
            } else if (std.mem.eql(u8, chord, "escape")) {
                vm.collapseToPrimary(&tab.sels);
                self.refresh(tab);
            } else if (std.mem.eql(u8, chord, "ctrl+s")) {
                self.saveTab(tab);
            } else if (std.mem.eql(u8, chord, "ctrl+z")) {
                vm.undo(&tab.doc, &tab.sels) catch {};
                tab.layout.invalidateAll();
                self.refresh(tab);
            } else if (std.mem.eql(u8, chord, "ctrl+y")) {
                vm.redo(&tab.doc, &tab.sels) catch {};
                tab.layout.invalidateAll();
                self.refresh(tab);
            } else {
                return false;
            }
        }
        return true;
    }
};
