//! Sketerm Editor's standalone window: an AdwApplicationWindow hosting
//! a PANELESS `EditorView` (EditorView.attachStandalone), the same way
//! ui/picker.zig hosts a paneless BrowserView. Composition, not a
//! second editor — every document, every keybinding and all the IO is
//! the pane face's code, unchanged.
//!
//! What the window adds on top of the view: the header bar (the view's
//! own toolbar is hidden — the buttons live up there instead), the
//! title (active document + dirty marker), and the close-request veto
//! for unsaved buffers. The STATUS LINE is the view's own footer; this
//! file deliberately does not build a second one.
//!
//! Teardown follows PickerWindow, not ViewerWindow: GtkWindow dispose
//! destroys children before emitting "destroy", so the view's struct
//! teardown is deferred to an idle after the destroy storm has
//! unwound. The qdata is only how a dialog callback finds us again.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const model = @import("../editor_app.zig");
const paths = @import("../filebrowser/paths.zig");
const Config = @import("../config.zig").Config;
const editorview = @import("editorview.zig");
const EditorView = editorview.EditorView;
const ETab = editorview.ETab;
const confirm = @import("confirm.zig");
const classicmenu = @import("browser/classicmenu.zig");
const appmenu = @import("appmenu.zig");

const EDITOR_QDATA = "sketerm-editor-window";

/// Poll interval for the two bounded waits below (async load, async
/// save-all). 10s of ticks is far longer than a local file needs and
/// still bounded for a wedged remote host.
const POLL_MS: c_uint = 50;
const POLL_TICKS: u32 = 200;

pub const EditorWindow = struct {
    allocator: std.mem.Allocator,
    window: *c.GtkWidget,
    /// The editor face reads its settings through this; the address
    /// must stay stable, which it does (we are heap-allocated).
    config: Config,
    view: *EditorView,

    /// `--line N[:col]`: applied to the first document once its async
    /// load lands. Bounded — a file that never arrives simply leaves
    /// the caret where it was.
    goto_pos: ?model.Position = null,
    goto_tab: ?*ETab = null,
    goto_timer: c_uint = 0,
    goto_ticks: u32 = 0,

    /// "Save All" from the close confirmation: the saves are async, so
    /// the close waits for them here.
    close_timer: c_uint = 0,
    close_ticks: u32 = 0,
    /// The close confirmation has been answered: the next close-request
    /// is allowed straight through.
    force_close: bool = false,
    /// Suppresses the "always keep one document open" rule while the
    /// window is on its way out.
    closing: bool = false,
    destroyed: bool = false,
    /// Queued "reopen an empty document" idle (0 = none); removed at
    /// destroy so it can never run against a freed window.
    replace_source: c_uint = 0,

    title_buf: [512:0]u8 = undefined,

    /// Open the standalone editor on `req`'s documents. `req` is
    /// borrowed: every spec is copied into the view's own tabs.
    pub fn open(
        allocator: std.mem.Allocator,
        app: ?*c.GtkApplication,
        req: model.Request,
        config_path: ?[]const u8,
    ) !*EditorWindow {
        const self = try allocator.create(EditorWindow);
        errdefer allocator.destroy(self);
        const window = c.adw_application_window_new(app) orelse return error.OutOfMemory;
        errdefer c.gtk_window_destroy(@ptrCast(window));

        self.* = .{
            .allocator = allocator,
            .window = window,
            .config = Config.loadWithOverride(allocator, config_path),
            .view = undefined,
        };
        errdefer self.config.deinit();

        self.view = try EditorView.attachStandalone(allocator, &self.config);
        self.view.on_changed = &onViewChanged;
        self.view.changed_ctx = @ptrCast(self);

        c.gtk_window_set_title(@ptrCast(window), model.APP_NAME);
        c.gtk_window_set_default_size(@ptrCast(window), 1000, 740);
        self.buildChrome();

        // Self-ownership, the ViewerWindow way: the notify runs at
        // window FINALIZE, i.e. after the destroy has fully unwound and
        // still inside the main loop, so closing the last window (which
        // quits the application) tears the view down instead of leaking
        // it past the loop. The qdata is also how a dialog callback
        // finds us again.
        c.g_object_set_data_full(@ptrCast(window), EDITOR_QDATA, @ptrCast(self), @ptrCast(&finalizeEditorWindow));
        _ = c.g_signal_connect_data(window, "close-request", @ptrCast(&onCloseRequest), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onWindowDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        // Window-level chords, CAPTURE phase like the Viewer's. Only
        // keys the editor itself does NOT claim are handled here; every
        // other press falls through to the document.
        const keys = c.gtk_event_controller_key_new();
        c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(window, @ptrCast(keys));

        if (req.specs.len == 0) {
            _ = self.view.newTab(null);
        } else {
            for (req.specs) |spec| self.view.openSpec(spec, null);
            if (req.position) |pos| self.armGoto(pos);
        }

        self.syncTitle();
        c.gtk_window_present(@ptrCast(window));
        _ = c.gtk_widget_grab_focus(@ptrCast(self.view.area));
        return self;
    }

    // ---- chrome ------------------------------------------------------

    fn buildChrome(self: *EditorWindow) void {
        const toolbar = c.adw_toolbar_view_new().?;
        const header = c.adw_header_bar_new().?;

        const open_button = c.gtk_button_new_from_icon_name("document-open-symbolic").?;
        c.gtk_widget_set_tooltip_text(open_button, "Open (Ctrl+O)");
        const save_button = c.gtk_button_new_from_icon_name("document-save-symbolic").?;
        c.gtk_widget_set_tooltip_text(save_button, "Save (Ctrl+S)");
        const save_as_button = c.gtk_button_new_from_icon_name("document-save-as-symbolic").?;
        c.gtk_widget_set_tooltip_text(save_as_button, "Save As (Ctrl+Shift+S)");
        const new_button = c.gtk_button_new_from_icon_name("tab-new-symbolic").?;
        c.gtk_widget_set_tooltip_text(new_button, "New Document (Ctrl+N)");
        c.adw_header_bar_pack_start(@ptrCast(header), new_button);
        c.adw_header_bar_pack_start(@ptrCast(header), open_button);
        c.adw_header_bar_pack_start(@ptrCast(header), save_button);
        c.adw_header_bar_pack_start(@ptrCast(header), save_as_button);

        // The hamburger: a flat button whose classic menu is built
        // fresh per open, like every other hamburger in the suite, and
        // END-MOST on the bar.
        const menu_button = c.gtk_button_new_from_icon_name("open-menu-symbolic").?;
        c.gtk_widget_set_tooltip_text(menu_button, "Main Menu");
        _ = c.g_signal_connect_data(menu_button, "clicked", @ptrCast(&onBurgerClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.adw_header_bar_pack_end(@ptrCast(header), menu_button);

        c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar), header);
        c.gtk_widget_set_vexpand(self.view.root_box, 1);
        c.adw_toolbar_view_set_content(@ptrCast(toolbar), self.view.root_box);
        c.adw_application_window_set_content(@ptrCast(self.window), toolbar);

        _ = c.g_signal_connect_data(new_button, "clicked", @ptrCast(&onNewDocument), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(open_button, "clicked", @ptrCast(&onOpen), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(save_button, "clicked", @ptrCast(&onSave), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(save_as_button, "clicked", @ptrCast(&onSaveAs), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    }

    /// The document verbs that have no header button of their own,
    /// plus the suite's shared Help tail.
    fn onBurgerClicked(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorWindow, user);
        if (self.destroyed) return;
        const anchor: *c.GtkWidget = @ptrCast(@alignCast(btn));
        const root = classicmenu.Root.create(self.allocator) orelse return;
        const m = root.top();
        const has_doc = self.view.active != null;
        m.itemIcon("Find…", .{ .name = "edit-find-symbolic" }, &onFind, @ptrCast(self));
        m.itemIcon("Find and Replace…", .{ .name = "edit-find-replace-symbolic" }, &onReplace, @ptrCast(self));
        m.itemIconEnabled("Toggle Soft Wrap", .{ .name = "format-justify-left-symbolic" }, has_doc, &onWrap, @ptrCast(self));
        const doc = m.section();
        // Only a SAVED document has a path to show or reveal.
        const has_path = if (self.view.active) |t| t.spec != null else false;
        doc.itemIconEnabled("Show in Sketerm Files", .{ .name = "folder-open-symbolic" }, has_path, &onReveal, @ptrCast(self));
        doc.itemIconEnabled("Close Document", .{ .name = "window-close-symbolic" }, has_doc, &onCloseDocument, @ptrCast(self));
        appmenu.appendHelp(m, self.allocator, @ptrCast(@alignCast(self.window)), .editor);
        _ = root.popup(
            anchor,
            @floatFromInt(@divTrunc(c.gtk_widget_get_width(anchor), 2)),
            @floatFromInt(c.gtk_widget_get_height(anchor)),
        );
    }

    // ---- title -------------------------------------------------------

    /// The view calls this through `on_changed` whenever the caret,
    /// active tab, tab set or a dirty flag moved.
    fn onViewChanged(ctx: *anyopaque) void {
        const self: *EditorWindow = @ptrCast(@alignCast(ctx));
        self.syncTitle();
        // A standalone window with no documents is a dead end (there is
        // no shell underneath to fall back to, the way a pane has), so
        // closing the last one starts a fresh buffer instead.
        //
        // Deferred to an idle, NEVER called inline: this hook fires
        // from the middle of tab bookkeeping (adding a page selects it,
        // and that switch-page lands here while the tab list is still
        // empty), so creating a tab from here directly recurses without
        // bound. The idle runs once the operation has finished, when
        // "no documents" is a real state rather than a half-built one.
        if (self.closing or self.destroyed or self.replace_source != 0) return;
        if (self.view.tabs.items.len != 0) return;
        self.replace_source = c.g_idle_add(@ptrCast(&replaceTabIdle), @ptrCast(self));
    }

    fn replaceTabIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(EditorWindow, user);
        self.replace_source = 0;
        if (self.closing or self.destroyed) return 0;
        if (self.view.tabs.items.len == 0) _ = self.view.newTab(null);
        return 0;
    }

    fn syncTitle(self: *EditorWindow) void {
        if (self.destroyed) return;
        const tab = self.view.active orelse {
            c.gtk_window_set_title(@ptrCast(self.window), model.APP_NAME);
            return;
        };
        const name: []const u8 = if (tab.spec) |s| blk: {
            const base = std.fs.path.basename(paths.parseSpec(s).path);
            break :blk if (base.len == 0) s else base;
        } else "Untitled";
        const mark: []const u8 = if (tab.isDirty()) "*" else "";
        const title = std.fmt.bufPrintZ(
            &self.title_buf,
            "{s}{s} - {s}",
            .{ mark, name, model.APP_NAME },
        ) catch model.APP_NAME;
        c.gtk_window_set_title(@ptrCast(self.window), title.ptr);
    }

    // ---- --line ------------------------------------------------------

    fn armGoto(self: *EditorWindow, pos: model.Position) void {
        const tab = self.view.active orelse return;
        self.goto_pos = pos;
        self.goto_tab = tab;
        self.goto_ticks = 0;
        self.goto_timer = c.g_timeout_add(POLL_MS, @ptrCast(&gotoTick), @ptrCast(self));
    }

    fn gotoTick(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(EditorWindow, user);
        const pos = self.goto_pos orelse {
            self.goto_timer = 0;
            return 0;
        };
        const want = self.goto_tab orelse {
            self.goto_timer = 0;
            self.goto_pos = null;
            return 0;
        };
        // The tab may have been closed while the load was in flight.
        var live = false;
        for (self.view.tabs.items) |t| {
            if (t == want) live = true;
        }
        self.goto_ticks += 1;
        if (!live or self.goto_ticks > POLL_TICKS) {
            self.goto_timer = 0;
            self.goto_pos = null;
            self.goto_tab = null;
            return 0;
        }
        if (want.loading) return 1;
        self.view.gotoLineCol(want, pos.line, pos.col);
        self.goto_timer = 0;
        self.goto_pos = null;
        self.goto_tab = null;
        return 0;
    }

    // ---- close -------------------------------------------------------

    fn onCloseRequest(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(EditorWindow, user);
        if (self.force_close) return 0;
        const dirty = self.view.dirtyCount();
        if (dirty == 0) return 0;

        var body: [256:0]u8 = undefined;
        const text = if (dirty == 1)
            std.fmt.bufPrintZ(&body, "One document has unsaved changes.", .{}) catch "Unsaved changes."
        else
            std.fmt.bufPrintZ(&body, "{d} documents have unsaved changes.", .{dirty}) catch "Unsaved changes.";
        // The ref keeps the window (and the qdata resolving back to
        // `self`) alive until the one-shot callback runs.
        _ = c.g_object_ref(@ptrCast(self.window));
        if (confirm.present(self.window, .{
            .heading = "Save changes?",
            .body = text.ptr,
            .responses = &.{
                .{ .id = "cancel", .label = "Cancel", .is_close = true },
                .{ .id = "discard", .label = "Discard", .appearance = .destructive },
                .{ .id = "save", .label = "Save All", .appearance = .suggested, .is_default = true },
            },
        }, .{ .allocator = self.allocator, .cb = &onCloseResponse, .ctx = @ptrCast(self.window) }) == null) {
            c.g_object_unref(@ptrCast(self.window));
            return 0;
        }
        return 1;
    }

    fn onCloseResponse(user: ?*anyopaque, resp: []const u8) void {
        const window: *c.GtkWidget = @ptrCast(@alignCast(user.?));
        defer c.g_object_unref(@ptrCast(window));
        const raw = c.g_object_get_data(@ptrCast(window), EDITOR_QDATA) orelse return;
        const self: *EditorWindow = @ptrCast(@alignCast(raw));
        if (self.destroyed) return;
        if (std.mem.eql(u8, resp, "discard")) {
            self.force_close = true;
            self.closing = true;
            c.gtk_window_destroy(@ptrCast(window));
        } else if (std.mem.eql(u8, resp, "save")) {
            self.closing = true;
            for (self.view.tabs.items) |t| {
                if (!t.isDirty()) continue;
                t.close_after_save = true;
                self.view.saveTab(t);
            }
            self.close_ticks = 0;
            if (self.close_timer == 0)
                self.close_timer = c.g_timeout_add(POLL_MS, @ptrCast(&closeTick), @ptrCast(self));
        }
    }

    /// Saves are async; close once every buffer is clean. A Save As the
    /// user cancels leaves the window open rather than losing the text.
    fn closeTick(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(EditorWindow, user);
        if (self.destroyed) {
            self.close_timer = 0;
            return 0;
        }
        self.close_ticks += 1;
        if (self.view.dirtyCount() == 0) {
            self.close_timer = 0;
            self.force_close = true;
            c.gtk_window_destroy(@ptrCast(self.window));
            return 0;
        }
        if (self.close_ticks > POLL_TICKS) {
            self.close_timer = 0;
            self.closing = false;
            return 0;
        }
        return 1;
    }

    fn onWindowDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorWindow, user);
        if (self.destroyed) return;
        self.destroyed = true;
        self.view.on_changed = null;
        // The window's widgets are being finalized: the view's area
        // signals go with them and its unrealize has run, so record the
        // sever now rather than at the qdata finalize below.
        self.view.sever(true);
        self.view.widgets_dead = true;
        if (self.goto_timer != 0) {
            _ = c.g_source_remove(self.goto_timer);
            self.goto_timer = 0;
        }
        if (self.close_timer != 0) {
            _ = c.g_source_remove(self.close_timer);
            self.close_timer = 0;
        }
        if (self.replace_source != 0) {
            _ = c.g_source_remove(self.replace_source);
            self.replace_source = 0;
        }
        // The struct teardown itself is the qdata notify at finalize,
        // once this destroy has fully unwound.
    }

    fn finalizeEditorWindow(user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorWindow, user);
        self.view.deinit();
        self.config.deinit();
        self.allocator.destroy(self);
    }

    // ---- header-bar and menu handlers --------------------------------

    fn onNewDocument(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorWindow, user);
        _ = self.view.newTab(null);
    }

    fn onOpen(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        cast.userData(EditorWindow, user).view.openPicker();
    }

    fn onSave(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorWindow, user);
        if (self.view.active) |tab| self.view.saveTab(tab);
    }

    fn onSaveAs(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorWindow, user);
        if (self.view.active) |tab| self.view.saveTabAs(tab);
    }

    fn onFind(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(EditorWindow, user).view.openFind(false);
    }

    fn onReplace(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(EditorWindow, user).view.openFind(true);
    }

    fn onWrap(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorWindow, user);
        if (self.view.active) |tab| self.view.toggleWrap(tab);
    }

    fn onCloseDocument(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorWindow, user);
        if (self.view.active) |tab| self.view.requestCloseTab(tab);
    }

    /// Cross-identity handoff, the Viewer's "Show in Sketerm Files"
    /// precedent: spawn the sibling binary rather than invent IPC.
    fn onReveal(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(EditorWindow, user);
        const tab = self.view.active orelse return;
        const spec = tab.spec orelse return;
        _ = @import("siblingapp.zig").showInFiles(spec);
    }

    // ---- keys --------------------------------------------------------

    fn onKey(
        _: *c.GtkEventControllerKey,
        keyval: c_uint,
        _: c_uint,
        state: c.GdkModifierType,
        user: ?*anyopaque,
    ) callconv(.c) c.gboolean {
        const self = cast.userData(EditorWindow, user);
        const ctrl = (state & c.GDK_CONTROL_MASK) != 0;
        const shift = (state & c.GDK_SHIFT_MASK) != 0;
        if (!ctrl or shift) return 0;
        // Only chords the editor face does NOT claim: everything else
        // must reach the document (this controller is in CAPTURE).
        switch (c.gdk_keyval_to_lower(keyval)) {
            c.GDK_KEY_n => {
                _ = self.view.newTab(null);
                return 1;
            },
            c.GDK_KEY_q => {
                c.gtk_window_close(@ptrCast(self.window));
                return 1;
            },
            else => return 0,
        }
    }
};
