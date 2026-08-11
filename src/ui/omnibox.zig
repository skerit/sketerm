//! Omnibox — the web face's as-you-type address-bar dropdown.
//!
//! A GtkPopover under the address entry, fed by the shared suggestion
//! framework (src/util/suggest.zig): the typed input's URL/search
//! interpretation, open web tabs (switch, don't navigate), cached
//! bookmarks, and daemon-side history (async; replies for a stale
//! query are dropped). The entry is NEVER blocked: history rides the
//! webstore's non-blocking socket and the dropdown re-renders when a
//! reply lands.
//!
//! Lifetime is the webreader shape: created by WebFace, `sever`ed at
//! the face's prepare-destroy choke point (mechanism 2 — one
//! disconnect for everything carrying this omnibox as user-data, plus
//! the debounce timer), destroyed from WebFace.deinit. Webstore
//! replies resolve through two distinct anchor bytes so cancelling a
//! superseded history query never drops the bookmark fetch.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const suggest = @import("../util/suggest.zig");
const webstore = @import("webstore.zig");
const webface = @import("webface.zig");
const WebFace = webface.WebFace;

const DEBOUNCE_MS: c_uint = 120;
const MAX_ROWS: usize = 10;
const HISTORY_MAX: u32 = 8;

/// What activating a row does. `spec` is render-arena owned and
/// rebuilt on every refresh; rows only ever index the CURRENT items.
const Item = struct {
    kind: suggest.Kind,
    /// For navigating kinds: handed to `WebFace.navigate` (a URL, or
    /// the raw query — navigate's normalization does the rest).
    spec: []const u8 = "",
    /// open_tab: the target face's view id, resolved at click time so
    /// a face that died in between is a no-op, not a stale pointer.
    view: u32 = 0,
};

pub const Omnibox = struct {
    allocator: std.mem.Allocator,
    face: *WebFace,
    entry: *c.GtkWidget,
    popover: *c.GtkWidget,
    listbox: *c.GtkWidget,

    /// Per-refresh strings (query copy aside) + row payloads.
    render_arena: std.heap.ArenaAllocator,
    /// History hits for the CURRENT query, duplicated out of the reply
    /// payload (the payload dies with the dispatch).
    hist_arena: std.heap.ArenaAllocator,
    hits: std.ArrayList(webstore.HistoryHit) = .empty,
    /// Bookmark cache: fetched once per dropdown session, filtered
    /// locally per keystroke.
    bm_arena: std.heap.ArenaAllocator,
    bookmarks: std.ArrayList(webstore.BookmarkEntry) = .empty,
    bm_state: enum { empty, loading, ready } = .empty,

    items: std.ArrayList(Item) = .empty,
    debounce_id: c.guint = 0,
    /// Distinct webstore-callback anchors: cancelling one class of
    /// pending reply must not drop the other.
    hist_anchor: u8 = 0,
    bm_anchor: u8 = 0,
    q_buf: [512]u8 = undefined,
    q_len: usize = 0,
    severed: bool = false,

    pub fn create(allocator: std.mem.Allocator, face: *WebFace, entry: *c.GtkWidget) !*Omnibox {
        const self = try allocator.create(Omnibox);
        self.* = .{
            .allocator = allocator,
            .face = face,
            .entry = entry,
            .popover = undefined,
            .listbox = undefined,
            .render_arena = std.heap.ArenaAllocator.init(allocator),
            .hist_arena = std.heap.ArenaAllocator.init(allocator),
            .bm_arena = std.heap.ArenaAllocator.init(allocator),
        };

        // Autohide OFF: the popover must never grab focus away from
        // the entry the user is typing into.
        const pop = c.gtk_popover_new();
        c.gtk_popover_set_autohide(@ptrCast(pop), 0);
        c.gtk_popover_set_has_arrow(@ptrCast(pop), 0);
        c.gtk_popover_set_position(@ptrCast(pop), c.GTK_POS_BOTTOM);
        c.gtk_widget_set_parent(pop, entry);
        self.popover = pop;

        const scroller = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(scroller), 1);
        c.gtk_scrolled_window_set_max_content_height(@ptrCast(scroller), 360);
        c.gtk_widget_set_size_request(scroller, 480, -1);

        const listbox = c.gtk_list_box_new();
        c.gtk_list_box_set_selection_mode(@ptrCast(listbox), c.GTK_SELECTION_SINGLE);
        c.gtk_widget_set_can_focus(listbox, 0);
        _ = c.g_signal_connect_data(@ptrCast(listbox), "row-activated", @ptrCast(&onRowActivated), self, null, 0);
        self.listbox = listbox;
        c.gtk_scrolled_window_set_child(@ptrCast(scroller), listbox);
        c.gtk_popover_set_child(@ptrCast(pop), scroller);

        // As-you-type refresh, debounced. `changed` also fires for the
        // programmatic address rewrite on navigation, which only ever
        // touches an UNFOCUSED entry — the focus gate filters it out.
        _ = c.g_signal_connect_data(@ptrCast(entry), "changed", @ptrCast(&onChanged), self, null, 0);

        // CAPTURE phase, the palette's trick: the entry's inner
        // GtkText swallows Return at the target phase.
        const keys = c.gtk_event_controller_key_new();
        c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(@ptrCast(keys), "key-pressed", @ptrCast(&onKeyPressed), self, null, 0);
        c.gtk_widget_add_controller(entry, @ptrCast(keys));

        // Focus leaving the entry dismisses the dropdown (rows are
        // not focusable, so clicking one never counts as leaving).
        const focus = c.gtk_event_controller_focus_new();
        _ = c.g_signal_connect_data(@ptrCast(focus), "leave", @ptrCast(&onFocusLeave), self, null, 0);
        c.gtk_widget_add_controller(entry, @ptrCast(focus));

        return self;
    }

    /// The face's prepare-destroy choke point: disconnect everything
    /// resolving to this omnibox, stop the timer, drop pending
    /// webstore replies, unparent the popover while the entry still
    /// exists. Idempotent.
    pub fn sever(self: *Omnibox, widgets_dead: bool) void {
        if (self.severed) return;
        self.severed = true;
        if (self.debounce_id != 0) {
            _ = c.g_source_remove(self.debounce_id);
            self.debounce_id = 0;
        }
        webstore.cancelFor(@ptrCast(&self.hist_anchor));
        webstore.cancelFor(@ptrCast(&self.bm_anchor));
        if (!widgets_dead) {
            // The key/focus controllers live ON the entry; matching by
            // data severs their handlers, and the controllers
            // themselves die with the widget.
            inline for (.{ self.entry, self.listbox }) |w| {
                _ = c.g_signal_handlers_disconnect_matched(
                    @ptrCast(w),
                    c.G_SIGNAL_MATCH_DATA,
                    0,
                    0,
                    null,
                    null,
                    @ptrCast(self),
                );
            }
            if (c.gtk_widget_get_parent(self.popover) != null)
                c.gtk_widget_unparent(self.popover);
        }
    }

    pub fn destroy(self: *Omnibox) void {
        self.sever(true);
        self.items.deinit(self.allocator);
        self.hits.deinit(self.allocator);
        self.bookmarks.deinit(self.allocator);
        self.render_arena.deinit();
        self.hist_arena.deinit();
        self.bm_arena.deinit();
        self.allocator.destroy(self);
    }

    // ---- input ------------------------------------------------------

    fn onChanged(_: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Omnibox, user);
        if (self.severed) return;
        // Programmatic rewrites only touch an unfocused entry.
        if (c.gtk_widget_has_focus(self.entry) == 0) return;
        const text_c = c.gtk_editable_get_text(@ptrCast(self.entry)) orelse return;
        const text = std.mem.span(@as([*:0]const u8, @ptrCast(text_c)));
        const n = @min(text.len, self.q_buf.len);
        @memcpy(self.q_buf[0..n], text[0..n]);
        self.q_len = n;
        if (self.debounce_id != 0) _ = c.g_source_remove(self.debounce_id);
        self.debounce_id = c.g_timeout_add(DEBOUNCE_MS, &onDebounce, self);
    }

    fn onDebounce(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Omnibox, user);
        self.debounce_id = 0;
        if (!self.severed) self.refresh();
        return 0; // one-shot
    }

    fn onKeyPressed(
        _: *c.GtkEventControllerKey,
        keyval: c_uint,
        _: c_uint,
        _: c.GdkModifierType,
        user: ?*anyopaque,
    ) callconv(.c) c.gboolean {
        const self = cast.userData(Omnibox, user);
        if (self.severed) return 0;
        const shown = c.gtk_widget_get_visible(self.popover) != 0;
        switch (keyval) {
            c.GDK_KEY_Down, c.GDK_KEY_KP_Down => {
                if (!shown) return 0;
                self.moveSelection(1);
                return 1;
            },
            c.GDK_KEY_Up, c.GDK_KEY_KP_Up => {
                if (!shown) return 0;
                self.moveSelection(-1);
                return 1;
            },
            c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => {
                if (!shown) return 0;
                const row = c.gtk_list_box_get_selected_row(@ptrCast(self.listbox));
                if (row == null) return 0; // fall through: navigate the typed text
                self.activateRow(row.?);
                return 1;
            },
            c.GDK_KEY_Escape => {
                if (!shown) return 0;
                self.hide();
                return 1;
            },
            else => return 0,
        }
    }

    fn onFocusLeave(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Omnibox, user);
        if (self.severed) return;
        self.hide();
    }

    fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Omnibox, user);
        if (self.severed) return;
        self.activateRow(row);
    }

    fn moveSelection(self: *Omnibox, delta: i32) void {
        const lb: *c.GtkListBox = @ptrCast(@alignCast(self.listbox));
        const cur = c.gtk_list_box_get_selected_row(lb);
        const cur_idx: i32 = if (cur == null) -1 else c.gtk_list_box_row_get_index(cur);
        const total: i32 = @intCast(self.items.items.len);
        var next = cur_idx + delta;
        if (next < 0) next = total - 1;
        if (next >= total) next = 0;
        const row = c.gtk_list_box_get_row_at_index(lb, next) orelse return;
        c.gtk_list_box_select_row(lb, row);
    }

    fn activateRow(self: *Omnibox, row: *c.GtkListBoxRow) void {
        const idx = c.gtk_list_box_row_get_index(row);
        if (idx < 0 or @as(usize, @intCast(idx)) >= self.items.items.len) return;
        const item = self.items.items[@intCast(idx)];
        self.hide();
        switch (item.kind) {
            .open_tab => if (webface.faceByView(item.view)) |target| target.reveal(),
            else => {
                // navigate() normalizes: URLs pass through, raw
                // queries become a search on the configured engine.
                // Stack copy: the next refresh resets the arena the
                // spec lives in.
                var spec_buf: [2048]u8 = undefined;
                const n = @min(item.spec.len, spec_buf.len);
                @memcpy(spec_buf[0..n], item.spec[0..n]);
                self.face.navigate(spec_buf[0..n]);
                _ = c.gtk_widget_grab_focus(self.face.view_area);
            },
        }
    }

    fn hide(self: *Omnibox) void {
        c.gtk_popover_popdown(@ptrCast(self.popover));
    }

    // ---- refresh ----------------------------------------------------

    fn query(self: *const Omnibox) []const u8 {
        return self.q_buf[0..self.q_len];
    }

    fn refresh(self: *Omnibox) void {
        const q = self.query();
        if (q.len == 0) {
            self.items.clearRetainingCapacity();
            self.hide();
            return;
        }
        // Hits belong to the query they answered; a new query starts
        // from none and the async reply fills them back in.
        self.hits.clearRetainingCapacity();
        _ = self.hist_arena.reset(.retain_capacity);
        webstore.cancelFor(@ptrCast(&self.hist_anchor));
        _ = webstore.historyQuery(self.allocator, q, HISTORY_MAX, @ptrCast(&self.hist_anchor), &onHistoryReply);
        if (self.bm_state == .empty) {
            self.bm_state = .loading;
            if (!webstore.bookmarkList(self.allocator, @ptrCast(&self.bm_anchor), &onBookmarksReply))
                self.bm_state = .empty; // degraded daemon: filter nothing
        }
        self.render();
    }

    fn onHistoryReply(ctx: ?*anyopaque, ok: bool, payload: []const u8) void {
        const self: *Omnibox = @alignCast(@fieldParentPtr("hist_anchor", @as(*u8, @ptrCast(ctx.?))));
        if (self.severed or !ok) return;
        // The payload dies with this dispatch: keep our own copies.
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const parsed = webstore.parseHits(scratch.allocator(), payload);
        const arena = self.hist_arena.allocator();
        self.hits.clearRetainingCapacity();
        for (parsed) |hit| {
            self.hits.append(self.allocator, .{
                .url = arena.dupe(u8, hit.url) catch continue,
                .title = arena.dupe(u8, hit.title) catch continue,
                .visits = hit.visits,
                .last_ms = hit.last_ms,
                .score = hit.score,
            }) catch break;
        }
        self.render();
    }

    fn onBookmarksReply(ctx: ?*anyopaque, ok: bool, payload: []const u8) void {
        const self: *Omnibox = @alignCast(@fieldParentPtr("bm_anchor", @as(*u8, @ptrCast(ctx.?))));
        if (self.severed) return;
        if (!ok) {
            self.bm_state = .empty;
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const parsed = webstore.parseBookmarks(scratch.allocator(), payload);
        const arena = self.bm_arena.allocator();
        self.bookmarks.clearRetainingCapacity();
        for (parsed) |bm| {
            self.bookmarks.append(self.allocator, .{
                .id = bm.id,
                .url = arena.dupe(u8, bm.url) catch continue,
                .title = arena.dupe(u8, bm.title) catch continue,
                .folder = "",
            }) catch break;
        }
        self.bm_state = .ready;
        self.render();
    }

    // ---- sources ----------------------------------------------------

    /// The typed input itself: its URL/host reading (top-ranked when
    /// it has one) and its web-search reading (top-ranked otherwise,
    /// a low-scored fallback when the input already looks like an
    /// address).
    fn inputSource(ctx: ?*anyopaque, q: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList(suggest.Candidate)) void {
        const self: *Omnibox = @ptrCast(@alignCast(ctx.?));
        const arena = self.render_arena.allocator();
        const class = suggest.classify(q);
        if (class != .search) {
            var buf: [2048]u8 = undefined;
            if (suggest.normalizeUrl(&buf, q, webface.searchTemplate())) |url| {
                const owned = arena.dupe(u8, url) catch return;
                out.append(gpa, .{
                    .title = owned,
                    .detail = "Open address",
                    .kind = .url,
                    .score = 1.0,
                    .key = owned,
                }) catch {};
            }
        }
        out.append(gpa, .{
            .title = arena.dupe(u8, q) catch return,
            .detail = "Web search",
            .kind = .search,
            .score = if (class == .search) 1.0 else 0.35,
        }) catch {};
    }

    /// Open web tabs across every window of this process; activating
    /// one switches to it instead of loading the page twice.
    fn tabsSource(ctx: ?*anyopaque, q: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList(suggest.Candidate)) void {
        const self: *Omnibox = @ptrCast(@alignCast(ctx.?));
        const arena = self.render_arena.allocator();
        var qbuf: [256]u8 = undefined;
        const ql = suggest.toLower(&qbuf, q);
        for (webface.openFaces()) |f| {
            if (f == self.face or f.attached or f.widgets_dead) continue;
            const url = f.url orelse continue;
            const title: []const u8 = f.title orelse url;
            const tl = suggest.toLower(arena.alloc(u8, title.len) catch continue, title);
            const ul = suggest.toLower(arena.alloc(u8, url.len) catch continue, url);
            const score = suggest.fieldsScore(ql, tl, ul);
            if (score <= 0) continue;
            out.append(gpa, .{
                .title = arena.dupe(u8, title) catch continue,
                .detail = arena.dupe(u8, url) catch continue,
                .kind = .open_tab,
                .score = score,
                .payload = f.view,
            }) catch {};
        }
    }

    fn bookmarksSource(ctx: ?*anyopaque, q: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList(suggest.Candidate)) void {
        const self: *Omnibox = @ptrCast(@alignCast(ctx.?));
        const arena = self.render_arena.allocator();
        var qbuf: [256]u8 = undefined;
        const ql = suggest.toLower(&qbuf, q);
        for (self.bookmarks.items) |bm| {
            const tl = suggest.toLower(arena.alloc(u8, bm.title.len) catch continue, bm.title);
            const ul = suggest.toLower(arena.alloc(u8, bm.url.len) catch continue, bm.url);
            const score = suggest.fieldsScore(ql, tl, ul);
            if (score <= 0) continue;
            out.append(gpa, .{
                .title = if (bm.title.len > 0) bm.title else bm.url,
                .detail = bm.url,
                .kind = .bookmark,
                .score = score,
                .key = bm.url,
            }) catch {};
        }
    }

    /// Daemon-ranked history for the current query: frecency scores
    /// are unbounded, so this source runs normalized.
    fn historySource(ctx: ?*anyopaque, q: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList(suggest.Candidate)) void {
        _ = q; // the daemon already filtered on it
        const self: *Omnibox = @ptrCast(@alignCast(ctx.?));
        for (self.hits.items) |hit| {
            out.append(gpa, .{
                .title = if (hit.title.len > 0) hit.title else hit.url,
                .detail = hit.url,
                .kind = .history,
                .score = @floatFromInt(hit.score +| 1),
                .key = hit.url,
            }) catch {};
        }
    }

    // ---- rendering --------------------------------------------------

    fn render(self: *Omnibox) void {
        _ = self.render_arena.reset(.retain_capacity);
        self.items.clearRetainingCapacity();
        const q = self.query();

        const sources = [_]suggest.Source{
            .{ .ctx = self, .query = inputSource },
            .{ .ctx = self, .weight = 0.9, .query = tabsSource },
            .{ .ctx = self, .weight = 0.85, .query = bookmarksSource },
            .{ .ctx = self, .normalize = true, .weight = 0.8, .query = historySource },
        };
        var cands: std.ArrayList(suggest.Candidate) = .empty;
        defer cands.deinit(self.allocator);
        suggest.merge(self.allocator, &sources, q, MAX_ROWS, &cands) catch return;

        const lb: *c.GtkListBox = @ptrCast(@alignCast(self.listbox));
        while (c.gtk_widget_get_first_child(self.listbox)) |child|
            c.gtk_list_box_remove(lb, @ptrCast(child));

        const arena = self.render_arena.allocator();
        for (cands.items) |cand| {
            const item: Item = switch (cand.kind) {
                .open_tab => .{ .kind = .open_tab, .view = @intCast(cand.payload) },
                .url => .{ .kind = .url, .spec = cand.title },
                .search => .{ .kind = .search, .spec = cand.title },
                // history/bookmark rows navigate to their URL.
                else => .{ .kind = cand.kind, .spec = arena.dupe(u8, cand.detail) catch continue },
            };
            self.items.append(self.allocator, item) catch break;

            const row_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
            c.gtk_widget_set_margin_start(row_box, 8);
            c.gtk_widget_set_margin_end(row_box, 8);
            c.gtk_widget_set_margin_top(row_box, 4);
            c.gtk_widget_set_margin_bottom(row_box, 4);
            c.gtk_box_append(@ptrCast(row_box), c.gtk_image_new_from_icon_name(kindIcon(cand.kind)));

            const title = c.gtk_label_new(null);
            setLabel(title, cand.title, arena);
            c.gtk_label_set_xalign(@ptrCast(title), 0);
            c.gtk_label_set_ellipsize(@ptrCast(title), c.PANGO_ELLIPSIZE_END);
            c.gtk_box_append(@ptrCast(row_box), title);

            const detail = c.gtk_label_new(null);
            setLabel(detail, cand.detail, arena);
            c.gtk_label_set_xalign(@ptrCast(detail), 1);
            c.gtk_label_set_ellipsize(@ptrCast(detail), c.PANGO_ELLIPSIZE_MIDDLE);
            c.gtk_widget_set_hexpand(detail, 1);
            c.gtk_widget_add_css_class(detail, "dim-label");
            c.gtk_box_append(@ptrCast(row_box), detail);

            const row = c.gtk_list_box_row_new();
            c.gtk_widget_set_focusable(row, 0);
            c.gtk_list_box_row_set_child(@ptrCast(row), row_box);
            c.gtk_list_box_append(lb, row);
        }

        // Arrow keys opt into a row; plain Enter keeps meaning "go to
        // what I typed" (the entry's own activate).
        c.gtk_list_box_unselect_all(lb);

        if (self.items.items.len == 0 or c.gtk_widget_has_focus(self.entry) == 0) {
            self.hide();
            return;
        }
        if (c.gtk_widget_get_visible(self.popover) == 0)
            c.gtk_popover_popup(@ptrCast(self.popover));
    }

    fn setLabel(label: *c.GtkWidget, text: []const u8, arena: std.mem.Allocator) void {
        const z = arena.dupeZ(u8, text) catch return;
        c.gtk_label_set_text(@ptrCast(label), z.ptr);
    }

    fn kindIcon(kind: suggest.Kind) [*:0]const u8 {
        return switch (kind) {
            .url => "web-browser-symbolic",
            .search => "system-search-symbolic",
            .history => "document-open-recent-symbolic",
            .bookmark => "starred-symbolic",
            .open_tab => "tab-new-symbolic",
            .command => "utilities-terminal-symbolic",
        };
    }
};
