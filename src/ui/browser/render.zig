//! Rendering the listing: details/compact rows, the icon grid, the
//! Miller columns, the sort header and column picker, plus the
//! per-row decoration (emblems, file-color rules, thumbnails).

const std = @import("std");
const c = @import("../../c.zig").c;
const browser_model = @import("../../filebrowser/model.zig");
const clock = @import("../../util/clock.zig");
const fsjob = @import("../../mux/fsjob.zig");
const grouping = @import("../../filebrowser/grouping.zig");
const profile = @import("../../util/profile.zig");
const searchmod = @import("search.zig");
const views = @import("views.zig");
const dnd = @import("dnd.zig");

const colkeys = @import("../../filebrowser/colkeys.zig");
const fileicon = @import("../../filebrowser/fileicon.zig");
const iconload = @import("iconload.zig");
const format = @import("../../filebrowser/format.zig");
const mediacols = @import("mediacols.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const Dir = @import("types.zig").Dir;
const Entry = @import("types.zig").Entry;
const extensionOf = @import("types.zig").extensionOf;
const FileColor = @import("types.zig").FileColor;
const connectPopoverAutoUnparent = @import("menu.zig").connectPopoverAutoUnparent;
const copyZ = @import("../../filebrowser/format.zig").copyZ;
const copyZN = @import("../../filebrowser/format.zig").copyZN;
const isPreviewMediaName = @import("../../filebrowser/paths.zig").isPreviewMediaName;
const fmtModeZ = @import("../../filebrowser/format.zig").fmtModeZ;
const fmtSize = @import("../../filebrowser/format.zig").fmtSize;
const fmtTimeZ = @import("../../filebrowser/format.zig").fmtTimeZ;
const launchLocal = @import("open.zig").launchLocal;
const millerNextSegment = @import("../../filebrowser/paths.zig").millerNextSegment;
const parseSpec = @import("../../filebrowser/paths.zig").parseSpec;
const tagColorHex = @import("../../filebrowser/format.zig").tagColorHex;

/// Horizontal gap between two adjacent widgets of a name cell
/// (expander, icon, label, chips). Shared with colview.zig.
pub const CELL_SPACING = 4;

/// A themed, full-colour icon image for a listing entry, sized `px`.
///
/// Directories get the theme's `folder`; everything else is resolved
/// from the content type GUESSED FROM THE NAME -- never from the
/// content, which for a remote entry would mean reading the file. That
/// is how the user's icon theme (Papirus, Breeze, ...) ends up
/// deciding what a .png or a .zip looks like, exactly as in Nemo.
fn entryIconImage(anchor: *c.GtkWidget, e: Entry, px: i32) ?*c.GtkWidget {
    if (fileicon.folderIconName(e.kind, e.tdir)) |name| {
        var fz: [32:0]u8 = undefined;
        return iconload.newImageIcon(anchor, copyZN(&fz, name), px);
    }
    var nz: [512:0]u8 = undefined;
    _ = copyZN(&nz, e.name);
    var uncertain: c.gboolean = 0;
    const ctype = c.g_content_type_guess(&nz, null, 0, &uncertain);
    if (ctype != null) {
        defer c.g_free(ctype);
        // g_content_type_get_icon hands back a ref we own; the image
        // takes its own, so ours is dropped right after.
        if (c.g_content_type_get_icon(ctype)) |gicon| {
            defer c.g_object_unref(gicon);
            return iconload.newImageGicon(anchor, @ptrCast(gicon), px);
        }
    }
    var gz: [32:0]u8 = undefined;
    return iconload.newImageIcon(anchor, copyZN(&gz, fileicon.GENERIC_ICON), px);
}

pub fn renderCurrent(self: *BrowserView) void {
    if (self.widgets_dead) return;
    if (self.currentTab()) |t| self.renderTab(t);
}

/// Leading-edge throttle for SOCKET-driven renders (streaming listing
/// chunks, watch-delta storms): render immediately when the last one
/// is old enough, otherwise coalesce into ONE deferred render when
/// the window reopens. Interaction-driven renders stay direct — a
/// click's feedback must never wait on this.
const LISTING_RENDER_THROTTLE_MS: i64 = 120;

pub fn scheduleListingRender(self: *BrowserView) void {
    if (self.widgets_dead or self.listing_render_src != 0) return;
    const elapsed = clock.nowMs() - self.last_listing_render_ms;
    if (elapsed >= LISTING_RENDER_THROTTLE_MS) {
        self.renderCurrent();
        return;
    }
    const delay: c.guint = @intCast(LISTING_RENDER_THROTTLE_MS - elapsed);
    self.listing_render_src = c.g_timeout_add(delay, @ptrCast(&onListingRenderTick), @ptrCast(self));
}

fn onListingRenderTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.listing_render_src = 0;
    self.renderCurrent();
    return 0; // one-shot
}

pub fn renderTab(self: *BrowserView, tab: *BTab) void {
    if (self.widgets_dead) return;
    // Every full render restamps the throttle window, whoever asked
    // for it — a socket render right after a click render is still a
    // back-to-back rebuild.
    self.last_listing_render_ms = clock.nowMs();
    // Media values are stitched onto the entries BEFORE the sort:
    // they arrive from a batched job long after the listing, and a
    // sort by a media column reads them straight off the entries.
    mediacols.applyValues(self, tab);
    tab.applySort();
    self.updateSortHeader(tab);
    self.applyViewChrome(tab);
    // The filter is per tab; the shared entry follows the visible one.
    views.syncFilterEntry(self, tab);
    tab.vs.total = tab.root.entries.items.len;
    tab.vs.shown = 0;
    for (tab.root.entries.items) |e| {
        if (views.entryVisible(tab, e)) tab.vs.shown += 1;
    }
    switch (tab.view_mode) {
        .details, .compact => self.renderList(tab),
        .icons => self.renderGrid(tab),
        .miller => {
            self.renderMillerCols(tab);
            self.renderList(tab);
        },
    }
    // What an empty listing area MEANS, decided once and shown in both
    // places (the area itself and the status line) so they cannot
    // disagree.
    const state = applyListingState(tab);

    var count_buf: [560]u8 = undefined;
    // Its own buffer: a note printed into count_buf would be
    // overwritten by the print that reads it.
    var note_buf: [96]u8 = undefined;
    const note = mediaSortNote(tab, &note_buf);
    // The query note rides every render on purpose: a truncated result
    // or a panel line that was not a path has to stay visible, not be
    // erased by whatever status message comes next.
    var query_buf: [200]u8 = undefined;
    const qnote = searchmod.queryNote(tab, &query_buf);
    // Free space of the filesystem behind the tab root, when known.
    var free_buf: [64]u8 = undefined;
    var free_size_buf: [48:0]u8 = undefined;
    const fnote: []const u8 = if (tab.free_bytes) |free|
        std.fmt.bufPrint(&free_buf, ", {s} free", .{format.fmtSize(&free_size_buf, free)}) catch ""
    else
        "";
    // The count phrase, or -- when there is nothing to count -- what the
    // emptiness means. Both are then prefixed by a refused navigation,
    // which stays visible until the next one lands.
    const counted: []const u8 = if (failureReason(tab)) |why|
        std.fmt.bufPrint(&count_buf, "cannot open {s}: {s}", .{ tab.root.path, why }) catch
            "cannot open this folder"
    else if (tab.filter.len > 0)
        std.fmt.bufPrint(&count_buf, "showing {d} of {d} items (filter \"{s}\"){s}{s}{s}", .{
            tab.vs.shown, tab.vs.total, tab.filter[0..@min(tab.filter.len, 48)], note, qnote, fnote,
        }) catch ""
    else if (tab.vs.total == 0)
        std.fmt.bufPrint(&count_buf, "{s}{s}{s}{s}", .{ format.listingStatus(state), note, qnote, fnote }) catch ""
    else if (tab.root.streaming)
        // Rows are landing chunk by chunk; the count is a floor.
        std.fmt.bufPrint(&count_buf, "listing… {d} items so far{s}{s}{s}", .{ tab.vs.total, note, qnote, fnote }) catch ""
    else
        std.fmt.bufPrint(&count_buf, "{d} items{s}{s}{s}", .{ tab.vs.total, note, qnote, fnote }) catch "";
    var status_buf: [700]u8 = undefined;
    const cmsg: []const u8 = if (tab.nav_error) |refused|
        std.fmt.bufPrint(&status_buf, "{s} -- still showing {s} ({s})", .{
            refused, tab.root.path, counted,
        }) catch refused
    else
        counted;
    self.setStatus(cmsg);
    applyPendingReveal(self, tab);

    // Fetching runs LAST: the rows it measures against are the ones
    // just built, and the request itself is coalesced behind a timer.
    if (mediacols.tabWantsMedia(tab)) {
        mediacols.ensureScrollWatch(self, tab);
        mediacols.schedule(self);
    }

    // A rebuild can have destroyed or hidden the focused widget (the
    // clicked row, most navigations); without focus INSIDE the face
    // every chord goes dead. Self-guarding: focus that legitimately
    // sits elsewhere is left alone.
    if (self.currentTab() == tab) self.refocusListingIfLost();
}

fn applyPendingReveal(self: *BrowserView, tab: *BTab) void {
    const path = tab.pending_reveal orelse return;
    switch (tab.view_mode) {
        .details, .compact, .miller => {
            const pos = @import("colview.zig").positionForPath(tab, path) orelse return revealMissing(self, tab, path);
            @import("colview.zig").focusRow(tab, pos, true);
        },
        .icons => {
            const flowbox = tab.flowbox orelse return;
            var index: c_int = 0;
            while (c.gtk_flow_box_get_child_at_index(flowbox, index)) |child| : (index += 1) {
                const data = c.g_object_get_data(@ptrCast(child), "sketerm-row") orelse continue;
                const row: *RowCtx = @ptrCast(@alignCast(data));
                if (!std.mem.eql(u8, row.path, path)) continue;
                c.gtk_flow_box_unselect_all(flowbox);
                c.gtk_flow_box_select_child(flowbox, child);
                _ = c.gtk_widget_grab_focus(@ptrCast(child));
                break;
            } else return revealMissing(self, tab, path);
        },
    }
    const name = std.fs.path.basename(path);
    self.setStatusFmt("selected {s}", .{name});
    self.allocator.free(path);
    tab.pending_reveal = null;
    if (tab.pending_reveal_host) |host| self.allocator.free(host);
    tab.pending_reveal_host = null;
}

fn revealMissing(self: *BrowserView, tab: *BTab, path: []u8) void {
    if (!tab.root.loaded or tab.root.streaming) return;
    const name = std.fs.path.basename(path);
    self.setStatusFmt("could not select {s}: it is not in this folder", .{name});
    self.allocator.free(path);
    tab.pending_reveal = null;
    if (tab.pending_reveal_host) |host| self.allocator.free(host);
    tab.pending_reveal_host = null;
}

/// How much of the directory a media-column sort actually covers.
/// Only the rows whose metadata has been READ have a value, and
/// saying so is the difference between an honest sort and one that
/// silently pretends the unread rows have none.
fn mediaSortNote(tab: *BTab, buf: []u8) []const u8 {
    const i = tab.attr_sort orelse return "";
    if (i >= tab.attr_columns.items.len) return "";
    const name = tab.attr_columns.items[i];
    if (colkeys.sourceOf(name) != .media) return "";
    const counted = mediacols.valuedCount(tab);
    if (counted.total == 0 or counted.have >= counted.total) return "";
    return std.fmt.bufPrint(buf, " ({s} read for {d} of {d} files)", .{
        colkeys.label(name), counted.have, counted.total,
    }) catch "";
}

/// Why this tab's listing area cannot be taken at face value, or null.
///
/// Two sources, deliberately kept apart from the entry count: the
/// directory's own refusal, and a query job that DIED. A query that
/// died with rows already in keeps them (they are real), so only an
/// empty result would otherwise read as "nothing matched".
fn failureReason(tab: *BTab) ?[]const u8 {
    if (tab.root.load_error) |why| return why;
    if (tab.query) |q| {
        if (q.failed and tab.root.entries.items.len == 0)
            return "the query failed - see the jobs panel";
    }
    return null;
}

/// Put the meaning of an empty listing area INTO the listing area, and
/// answer what that meaning was.
///
/// The rows, the grid and the miller columns are all hidden while this
/// shows: a refusal has to replace the listing, not sit beside an
/// expanse of white that reads as "this folder is empty". Runs after
/// applyViewChrome, whose per-mode visibility it deliberately
/// overrides.
pub fn applyListingState(tab: *BTab) format.ListingState {
    const state = format.listingState(
        tab.root.loaded,
        failureReason(tab) != null,
        tab.root.isFlat(),
        tab.root.entries.items.len,
    );
    const show = state != .populated;
    c.gtk_widget_set_visible(tab.empty_box, @intFromBool(show));
    if (show) {
        c.gtk_widget_set_visible(tab.scroller, 0);
        if (tab.flow_scroller) |fs| c.gtk_widget_set_visible(fs, 0);
        // The miller ancestor columns stay: they are how you leave a
        // folder that turned out to be empty or unreadable.
        // Sortable column headers over a refusal would suggest there is
        // a listing under them.
        var title_buf: [256:0]u8 = undefined;
        var detail_buf: [256:0]u8 = undefined;
        if (failureReason(tab)) |why| {
            c.gtk_label_set_text(tab.empty_title, copyZ(&title_buf, "This folder could not be opened"));
            var detail: [400]u8 = undefined;
            const text = std.fmt.bufPrint(&detail, "{s}: {s}", .{ tab.root.path, why }) catch why;
            c.gtk_label_set_text(tab.empty_detail, copyZ(&detail_buf, text));
        } else {
            c.gtk_label_set_text(tab.empty_title, copyZ(&title_buf, format.listingHeadline(state)));
            c.gtk_label_set_text(tab.empty_detail, copyZ(&detail_buf, switch (state) {
                .no_matches => "Nothing matched this query.",
                .empty => "This folder has no items. Hidden files may exist -- use the eye button to show them.",
                else => "",
            }));
        }
        c.gtk_widget_set_visible(@ptrCast(@alignCast(tab.empty_detail)), @intFromBool(state != .listing));
    }
    return state;
}

/// Show/hide the chrome that belongs to the tab's view mode.
pub fn applyViewChrome(self: *BrowserView, tab: *BTab) void {
    _ = self;
    const mode = tab.view_mode;
    c.gtk_widget_set_visible(tab.miller_box, @intFromBool(mode == .miller));
    c.gtk_widget_set_visible(tab.scroller, @intFromBool(mode != .icons));
    if (tab.flow_scroller) |fs| c.gtk_widget_set_visible(fs, @intFromBool(mode == .icons));
    if (mode != .miller and tab.ancestors.items.len > 0) tab.dropAncestors();
}

/// Heap context for one header button (a column or the picker).
pub const HeaderCtx = struct {
    allocator: std.mem.Allocator,
    tab: *BTab,
    column: ?browser_model.Column,

    fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const ctx: *HeaderCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.destroy(ctx);
    }
};

/// Which column a header widget is about: one of the fixed set, or
/// an index into the tab's extra columns. The one currency the width
/// helpers and the resize grips deal in.
pub const ColumnRef = union(enum) {
    /// The name column. 0 stored width = auto (take the leftover).
    name,
    fixed: browser_model.Column,
    attr: usize,
};

/// Below this a dragged Name column is nothing but an icon stub.
pub const MIN_NAME_WIDTH: i32 = 80;

/// The width of a column when the user has never dragged it.
pub fn defaultColumnWidth(ref: ColumnRef) i32 {
    return switch (ref) {
        // Auto: the name column takes the leftover width instead of a
        // fixed number; callers treat 0 as that mode.
        .name => 0,
        .fixed => |col| col.width(),
        .attr => browser_model.ATTR_COLUMN_WIDTH,
    };
}

/// THE width of one details column, in the header and in every row.
///
/// Both the header button and the data cell are budgeted from this
/// one number, so a column's title and its values can never end up
/// over different pixels. `.name` answers 0 while the column is in
/// its default take-the-leftover mode.
pub fn columnWidthOf(tab: *BTab, ref: ColumnRef) i32 {
    const stored: i32 = switch (ref) {
        .name => tab.name_width,
        .fixed => |col| tab.col_widths.get(col),
        // Deliberately tolerant: the width list may be shorter than
        // the name list (a restore fills the names first).
        .attr => |i| if (i < tab.attr_col_widths.items.len) tab.attr_col_widths.items[i] else 0,
    };
    if (stored <= 0) return defaultColumnWidth(ref);
    if (ref == .name) return @max(stored, MIN_NAME_WIDTH);
    return @max(stored, browser_model.MIN_COLUMN_WIDTH);
}

/// Record a dragged width. Growing the extra-column list here is what
/// lets it stay shorter than `attr_columns` until someone drags.
pub fn setColumnWidth(tab: *BTab, ref: ColumnRef, width: i32) void {
    switch (ref) {
        .name => tab.name_width = @max(width, MIN_NAME_WIDTH),
        .fixed => |col| tab.col_widths.set(col, @max(width, browser_model.MIN_COLUMN_WIDTH)),
        .attr => |i| {
            while (tab.attr_col_widths.items.len <= i)
                tab.attr_col_widths.append(tab.view.allocator, 0) catch return;
            tab.attr_col_widths.items[i] = @max(width, browser_model.MIN_COLUMN_WIDTH);
        },
    }
}

/// Forget a dragged width (double-click on the grip).
pub fn resetColumnWidth(tab: *BTab, ref: ColumnRef) void {
    switch (ref) {
        .name => tab.name_width = 0,
        .fixed => |col| tab.col_widths.set(col, 0),
        .attr => |i| if (i < tab.attr_col_widths.items.len) {
            tab.attr_col_widths.items[i] = 0;
        },
    }
}

/// Apply a restored snapshot's column widths. Both lists are
/// positional (parallel to `columns` / `attr_columns`) and may be
/// short or absent, which is what makes a pre-resize state file load
/// as "every column at its default".
pub fn applyColumnWidths(tab: *BTab, state: browser_model.TabState) void {
    if (state.name_width > 0) setColumnWidth(tab, .name, state.name_width);
    for (state.columns, 0..) |col, i| {
        if (i >= state.col_widths.len) break;
        if (state.col_widths[i] > 0) setColumnWidth(tab, .{ .fixed = col }, state.col_widths[i]);
    }
    for (state.attr_col_widths, 0..) |w, i| {
        if (i >= tab.attr_columns.items.len) break;
        if (w > 0) setColumnWidth(tab, .{ .attr = i }, w);
    }
}

/// Cap on extra (key-named) columns. XATTR-sourced ones are capped
/// separately at the daemon's per-listing attribute-name budget
/// (daemon MAX_ATTR_NAMES = 8; more would be silently truncated);
/// media columns ride no listing, so they get a roomier total.
pub const MAX_ATTR_COLUMNS = 16;
pub const MAX_XATTR_COLUMNS = 8;

/// Heap context for an attribute-column header, remove button, or
/// the add-column entry.
pub const AttrColumnCtx = struct {
    allocator: std.mem.Allocator,
    tab: *BTab,
    index: usize,
    entry: ?*c.GtkWidget,

    fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const ctx: *AttrColumnCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.destroy(ctx);
    }
};

/// Heap context for name-keyed extra-column actions (checkboxes and
/// custom-column remove rows): the name is looked up at CLICK time,
/// so a column set that changed since the widget was built can never
/// remove the wrong slot.
const MetaColCtx = struct {
    allocator: std.mem.Allocator,
    tab: *BTab,
    key: []u8,

    fn free(user: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
        _ = closure;
        const self: *MetaColCtx = @ptrCast(@alignCast(user.?));
        self.allocator.free(self.key);
        self.allocator.destroy(self);
    }
};

fn attrColumnShown(tab: *BTab, key: []const u8) bool {
    for (tab.attr_columns.items) |existing| {
        if (std.mem.eql(u8, existing, key)) return true;
    }
    return false;
}

fn countXattrColumns(tab: *BTab) usize {
    var n: usize = 0;
    for (tab.attr_columns.items) |name| {
        if (colkeys.sourceOf(name) == .xattr) n += 1;
    }
    return n;
}

/// Add an extra column by key. Reports the reason and returns false
/// when it cannot; already-shown is success.
fn addAttrColumnByName(tab: *BTab, name: []const u8) bool {
    const self = tab.view;
    const source = colkeys.sourceOf(name) orelse {
        self.setStatus("column keys are user.*, media.*, tag.*, exif.*, image.* or doc.*");
        return false;
    };
    if (attrColumnShown(tab, name)) return true;
    if (tab.attr_columns.items.len >= MAX_ATTR_COLUMNS) {
        self.setStatusFmt("at most {d} extra columns", .{MAX_ATTR_COLUMNS});
        return false;
    }
    if (source == .xattr and countXattrColumns(tab) >= MAX_XATTR_COLUMNS) {
        self.setStatusFmt("at most {d} attribute (user.*) columns", .{MAX_XATTR_COLUMNS});
        return false;
    }
    const owned = self.allocator.dupe(u8, name) catch return false;
    tab.attr_columns.append(self.allocator, owned) catch {
        self.allocator.free(owned);
        return false;
    };
    applyColumnChange(self, tab, source == .xattr);
    return true;
}

fn removeAttrColumnByName(tab: *BTab, name: []const u8) void {
    const self = tab.view;
    for (tab.attr_columns.items, 0..) |existing, i| {
        if (!std.mem.eql(u8, existing, name)) continue;
        const removed = tab.attr_columns.orderedRemove(i);
        // The width list is positional; drop the same slot or every
        // column after this one inherits its neighbour's width.
        if (i < tab.attr_col_widths.items.len)
            _ = tab.attr_col_widths.orderedRemove(i);
        const was_xattr = colkeys.sourceOf(removed) == .xattr;
        self.allocator.free(removed);
        tab.attr_sort = null;
        applyColumnChange(self, tab, was_xattr);
        return;
    }
}

/// A known-metadata-column checkbox in the picker flipped.
pub fn onMetaColToggled(check: *c.GtkCheckButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MetaColCtx = @ptrCast(@alignCast(user.?));
    const on = c.gtk_check_button_get_active(check) != 0;
    const shown = attrColumnShown(ctx.tab, ctx.key);
    if (on and !shown) {
        // A refused add (cap) must not leave a lying checkmark; the
        // recursive toggle is a no-op because nothing is shown.
        if (!addAttrColumnByName(ctx.tab, ctx.key))
            c.gtk_check_button_set_active(check, 0);
    } else if (!on and shown) {
        removeAttrColumnByName(ctx.tab, ctx.key);
    }
}

/// Remove button of a CUSTOM extra-column row in the picker.
pub fn onAttrColumnRemove(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MetaColCtx = @ptrCast(@alignCast(user.?));
    const tab = ctx.tab;
    // The picker's custom-row list is now stale; close it.
    tab.view.closeColumnPicker();
    removeAttrColumnByName(tab, ctx.key);
}

/// Re-fetch whatever a changed column set invalidated.
///
/// Only an XATTR change needs the listing re-SUBSCRIBED (the daemon
/// stores the requested attributes with the view, so a plain re-list
/// would leave the next delta blanking the new column). A media
/// column rides no listing at all, so it costs a re-stitch and a
/// batch instead of a remote round trip.
fn applyColumnChange(self: *BrowserView, tab: *BTab, xattr_changed: bool) void {
    mediacols.cancel(self);
    if (xattr_changed) {
        self.reopenTabListing(tab);
    } else {
        self.updateSortHeader(tab);
        self.renderTab(tab);
    }
}

pub fn onAttrColumnAdd(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx: *AttrColumnCtx = @ptrCast(@alignCast(user.?));
    const tab = ctx.tab;
    const raw = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(entry)))));
    const name = std.mem.trim(u8, raw, " ");
    if (name.len == 0) return;
    const owned = ctx.allocator.dupe(u8, name) catch return;
    defer ctx.allocator.free(owned);
    tab.view.closeColumnPicker();
    _ = addAttrColumnByName(tab, owned);
}

pub fn closeColumnPicker(self: *BrowserView) void {
    const pop = self.column_picker orelse return;
    self.column_picker = null;
    c.gtk_popover_popdown(@ptrCast(pop));
}

fn onColumnPickerClosed(pop: *c.GtkPopover, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    if (self.column_picker == @as(*c.GtkWidget, @ptrCast(pop))) self.column_picker = null;
}

/// Re-SUBSCRIBE the tab's directories so both the listing and the
/// pushed deltas carry the new attribute set. A plain re-list
/// would leave the daemon-side view on the old attributes, and the
/// next delta would blank the new column.
pub fn reopenTabListing(self: *BrowserView, tab: *BTab) void {
    self.cancelPendingDir(tab.root);
    self.closeViewOf(tab.hc, tab.root);
    self.openDir(tab, tab.root);
    for (tab.subdirs.items) |d| {
        self.cancelPendingDir(d);
        self.closeViewOf(tab.hc, d);
        self.openDir(tab, d);
    }
    self.updateSortHeader(tab);
}

/// Make the column view match the tab's column set, widths and sort
/// (colview.zig owns the real work; the name survives for the many
/// callers that predate the migration).
pub fn updateSortHeader(self: *BrowserView, tab: *BTab) void {
    @import("colview.zig").syncColumns(self, tab);
}

pub fn onColumnPicker(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *HeaderCtx = @ptrCast(@alignCast(user.?));
    showColumnPicker(ctx.tab, @ptrCast(@alignCast(btn)), null);
}

pub const PickerPoint = struct { x: f64, y: f64 };

/// One dim section heading inside the column picker.
fn pickerHeading(box: *c.GtkWidget, text: [*:0]const u8, top_gap: bool) void {
    const lbl = c.gtk_label_new(text);
    c.gtk_label_set_xalign(@ptrCast(lbl), 0);
    c.gtk_widget_add_css_class(lbl, "dim-label");
    if (top_gap) c.gtk_widget_set_margin_top(lbl, 8);
    c.gtk_box_append(@ptrCast(box), lbl);
}

/// The picker's metadata sections: every known key, grouped the way
/// Dolphin groups its "Additional Information" roles.
const PICKER_GROUPS = [_]struct { title: [*:0]const u8, prefixes: []const []const u8 }{
    .{ .title = "Media", .prefixes = &.{ "media.", "image." } },
    .{ .title = "Audio tags", .prefixes = &.{"tag."} },
    .{ .title = "Camera (EXIF)", .prefixes = &.{"exif."} },
    .{ .title = "Document", .prefixes = &.{"doc."} },
};

fn keyInGroup(key: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, key, p)) return true;
    }
    return false;
}

fn isKnownKey(key: []const u8) bool {
    for (colkeys.KNOWN) |k| {
        if (std.mem.eql(u8, k.key, key)) return true;
    }
    return false;
}

/// Build and pop the column picker, anchored at `btn` -- whichever
/// header widget was clicked, since a right-click anywhere in the
/// header opens it too.
pub fn showColumnPicker(tab: *BTab, btn: *c.GtkWidget, point: ?PickerPoint) void {
    const self = tab.view;
    // Right-clicking a second header while one is open would otherwise
    // leave two pickers stacked, only one of them reachable.
    self.closeColumnPicker();
    const popover = c.gtk_popover_new();
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    c.gtk_widget_set_margin_start(box, 10);
    c.gtk_widget_set_margin_end(box, 10);
    c.gtk_widget_set_margin_top(box, 10);
    c.gtk_widget_set_margin_bottom(box, 10);
    pickerHeading(box, "File", false);
    for (std.enums.values(browser_model.Column)) |col| {
        const check = c.gtk_check_button_new_with_label(col.title());
        c.gtk_check_button_set_active(@ptrCast(check), @intFromBool(tab.columns.contains(col)));
        const cctx = self.allocator.create(HeaderCtx) catch continue;
        cctx.* = .{ .allocator = self.allocator, .tab = tab, .column = col };
        _ = c.g_signal_connect_data(check, "toggled", @ptrCast(&onColumnToggled), @ptrCast(cctx), @ptrCast(&HeaderCtx.free), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), check);
    }
    // Known metadata columns as one-click checkboxes, Dolphin-style.
    // Values are extracted on the host that owns the file.
    for (PICKER_GROUPS) |group| {
        pickerHeading(box, group.title, true);
        for (colkeys.KNOWN) |k| {
            if (!keyInGroup(k.key, group.prefixes)) continue;
            var tz: [256:0]u8 = undefined;
            const check = c.gtk_check_button_new_with_label(copyZ(&tz, k.title));
            var kz: [256:0]u8 = undefined;
            c.gtk_widget_set_tooltip_text(check, copyZ(&kz, k.key));
            c.gtk_check_button_set_active(@ptrCast(check), @intFromBool(attrColumnShown(tab, k.key)));
            const mctx = self.allocator.create(MetaColCtx) catch continue;
            mctx.* = .{
                .allocator = self.allocator,
                .tab = tab,
                .key = self.allocator.dupe(u8, k.key) catch {
                    self.allocator.destroy(mctx);
                    continue;
                },
            };
            _ = c.g_signal_connect_data(check, "toggled", @ptrCast(&onMetaColToggled), @ptrCast(mctx), @ptrCast(&MetaColCtx.free), c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(box), check);
        }
    }
    c.gtk_box_append(@ptrCast(box), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));
    pickerHeading(box, "Custom columns", false);
    for (tab.attr_columns.items) |name| {
        // Known keys already have their checkbox above; this list is
        // for free-form user.* attributes and the like.
        if (isKnownKey(name)) continue;
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        var nz: [256:0]u8 = undefined;
        const lbl = c.gtk_label_new(copyZ(@ptrCast(&nz), name));
        c.gtk_label_set_xalign(@ptrCast(lbl), 0);
        c.gtk_widget_set_hexpand(lbl, 1);
        c.gtk_box_append(@ptrCast(row), lbl);
        const remove = c.gtk_button_new_from_icon_name("list-remove-symbolic");
        const rctx = self.allocator.create(MetaColCtx) catch continue;
        rctx.* = .{
            .allocator = self.allocator,
            .tab = tab,
            .key = self.allocator.dupe(u8, name) catch {
                self.allocator.destroy(rctx);
                continue;
            },
        };
        _ = c.g_signal_connect_data(remove, "clicked", @ptrCast(&onAttrColumnRemove), @ptrCast(rctx), @ptrCast(&MetaColCtx.free), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), remove);
        c.gtk_box_append(@ptrCast(box), row);
    }
    const add = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(add), "user.name or media.duration_ms - Enter to add");
    c.gtk_widget_set_tooltip_text(
        add,
        "user.* reads an extended attribute; media.* tag.* exif.* image.* doc.* " ++
            "read file metadata on the host that owns the file",
    );
    const actx = self.allocator.create(AttrColumnCtx) catch return;
    actx.* = .{ .allocator = self.allocator, .tab = tab, .index = 0, .entry = add };
    _ = c.g_signal_connect_data(add, "activate", @ptrCast(&onAttrColumnAdd), @ptrCast(actx), @ptrCast(&AttrColumnCtx.free), c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(box), add);

    // The full catalog is tall; scroll it rather than overflow the
    // window.
    const sw = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(sw), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_propagate_natural_width(@ptrCast(sw), 1);
    c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(sw), 1);
    c.gtk_scrolled_window_set_max_content_height(@ptrCast(sw), 540);
    c.gtk_scrolled_window_set_child(@ptrCast(sw), box);
    c.gtk_popover_set_child(@ptrCast(popover), sw);
    // Parent to the PAGE, not the anchor: a column toggle re-renders,
    // which would destroy a listing-parented popover and close the
    // picker after a single click. The anchor is the whole column
    // view; pointing at its HEADER strip (not its full extent, whose
    // midpoint is the bottom of a tall listing) is what drops the
    // picker where the columns live.
    if (point) |p| {
        var src = c.graphene_point_t{ .x = @floatCast(p.x), .y = @floatCast(p.y) };
        var dst = c.graphene_point_t{ .x = 0, .y = 0 };
        if (c.gtk_widget_compute_point(btn, tab.page, &src, &dst) != 0) {
            const rect = c.GdkRectangle{
                .x = @intFromFloat(dst.x),
                .y = @intFromFloat(dst.y),
                .width = 1,
                .height = 1,
            };
            c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
        }
    } else {
        var bounds: c.graphene_rect_t = undefined;
        if (c.gtk_widget_compute_bounds(@ptrCast(btn), tab.page, &bounds) != 0) {
            const rect = c.GdkRectangle{
                .x = @intFromFloat(bounds.origin.x),
                .y = @intFromFloat(bounds.origin.y),
                .width = @intFromFloat(bounds.size.width),
                .height = @min(@as(c_int, @intFromFloat(bounds.size.height)), 28),
            };
            c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
        }
    }
    c.gtk_widget_set_parent(popover, tab.page);
    _ = c.g_signal_connect_data(popover, "closed", @ptrCast(&onColumnPickerClosed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    connectPopoverAutoUnparent(popover);
    self.column_picker = popover;
    c.gtk_popover_popup(@ptrCast(popover));
}

pub fn onColumnToggled(check: *c.GtkCheckButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *HeaderCtx = @ptrCast(@alignCast(user.?));
    const col = ctx.column orelse return;
    const on = c.gtk_check_button_get_active(check) != 0;
    if (on) ctx.tab.columns.insert(col) else ctx.tab.columns.remove(col);
    const self = ctx.tab.view;
    // A hidden column must not keep sorting the view.
    if (!on and ctx.tab.sort_key == col.sortKey() and col != .target) {
        ctx.tab.sort_key = .name;
        ctx.tab.applySort();
    }
    views.rememberFolder(self, ctx.tab);
    self.updateSortHeader(ctx.tab);
    self.renderTab(ctx.tab);
}

pub fn renderList(self: *BrowserView, tab: *BTab) void {
    @import("colview.zig").renderList(self, tab);
}

pub fn ensureFlowbox(self: *BrowserView, tab: *BTab) *c.GtkFlowBox {
    if (tab.flowbox) |fb| return fb;
    const fs = c.gtk_scrolled_window_new();
    c.gtk_widget_set_hexpand(fs, 1);
    c.gtk_widget_set_vexpand(fs, 1);
    const fb = c.gtk_flow_box_new();
    c.gtk_widget_add_css_class(fb, "sketerm-fb-flow");
    c.gtk_flow_box_set_selection_mode(@ptrCast(fb), c.GTK_SELECTION_MULTIPLE);
    c.gtk_flow_box_set_activate_on_single_click(@ptrCast(fb), 0);
    c.gtk_flow_box_set_homogeneous(@ptrCast(fb), 1);
    c.gtk_flow_box_set_max_children_per_line(@ptrCast(fb), 32);
    c.gtk_scrolled_window_set_child(@ptrCast(fs), fb);
    // content box = miller_box | scroller | flow_scroller
    const content = c.gtk_widget_get_parent(tab.scroller);
    c.gtk_box_append(@ptrCast(content), fs);
    _ = c.g_signal_connect_data(fb, "child-activated", @ptrCast(&onGridChildActivated), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(fb, "selected-children-changed", @ptrCast(&onGridSelectionChanged), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    // Capture phase for the same reason as the list view: GtkFlowBox
    // selects on any button, which would collapse a multi-selection
    // the context menu is about to act on (see menu.onRightClick).
    const rclick = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(rclick), 3);
    c.gtk_event_controller_set_propagation_phase(@ptrCast(rclick), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(rclick, "pressed", @ptrCast(&onGridRightClick), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(@ptrCast(fb), @ptrCast(rclick));
    tab.flow_scroller = fs;
    tab.flowbox = @ptrCast(@alignCast(fb));
    // Middle-click-a-folder-in-a-new-tab, grid half.
    self.installGridMiddleClick(tab, tab.flowbox.?);
    // Sticky toggling works in the grid too, same capture-phase rule.
    self.installSelectionGestures(tab, @ptrCast(fb), true);
    const dropt = dnd.newTarget(tab);
    _ = c.g_signal_connect_data(dropt, "drop", @ptrCast(&onGridDrop), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(fb, @ptrCast(dropt));
    return tab.flowbox.?;
}

pub fn renderGrid(self: *BrowserView, tab: *BTab) void {
    const fb = self.ensureFlowbox(tab);
    c.gtk_widget_set_visible(tab.flow_scroller.?, 1);
    tab.rendering = true;
    defer tab.rendering = false;
    while (c.gtk_flow_box_get_child_at_index(fb, 0)) |child| {
        c.gtk_flow_box_remove(fb, @ptrCast(child));
    }
    for (tab.root.entries.items) |e| {
        if (!views.entryVisible(tab, e)) continue;
        self.appendTile(tab, fb, e);
    }
    // Restore selection.
    var i: c_int = 0;
    while (c.gtk_flow_box_get_child_at_index(fb, i)) |child| : (i += 1) {
        const data = c.g_object_get_data(@ptrCast(child), "sketerm-row") orelse continue;
        const ctx: *RowCtx = @ptrCast(@alignCast(data));
        for (tab.selected.items) |path| {
            if (std.mem.eql(u8, path, ctx.path)) {
                c.gtk_flow_box_select_child(fb, child);
                break;
            }
        }
    }
}

/// Make an entry widget (list row or grid tile) a drag source
/// carrying its host-qualified spec as text. A terminal drop types
/// it; a drop on another browser tab moves (same host) or copies
/// (cross-host). Local entries deliberately drag as a BARE path, not
/// "local:/x", so a terminal drop is directly usable.
pub fn addEntryDragSource(_: *BTab, widget: *c.GtkWidget) void {
    const dsrc = c.gtk_drag_source_new();
    dnd.configureSource(dsrc.?);
    _ = c.g_signal_connect_data(dsrc, "prepare", @ptrCast(&onGridDragPrepare), @ptrCast(widget), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(widget, @ptrCast(dsrc));
}

fn onGridDragPrepare(_: *c.GtkDragSource, _: f64, _: f64, user: ?*anyopaque) callconv(.c) ?*c.GdkContentProvider {
    const child: *c.GtkWidget = @ptrCast(@alignCast(user.?));
    const data = c.g_object_get_data(@ptrCast(@alignCast(child)), "sketerm-row") orelse return null;
    const ctx: *RowCtx = @ptrCast(@alignCast(data));
    return dnd.provider(ctx.tab, ctx.path);
}

fn onGridDrop(target: *c.GtkDropTarget, value: *c.GValue, x: f64, y: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    var dst_dir: []const u8 = tab.root.path;
    if (tab.flowbox) |fb| {
        if (c.gtk_flow_box_get_child_at_pos(fb, @intFromFloat(x), @intFromFloat(y))) |child| {
            if (c.g_object_get_data(@ptrCast(child), "sketerm-row")) |data| {
                const ctx: *RowCtx = @ptrCast(@alignCast(data));
                if (ctx.is_dir) dst_dir = ctx.path;
            }
        }
    }
    return @intFromBool(@import("ops.zig").dropValueIntoAction(tab.view, tab, value, dst_dir, dnd.dropAction(target, tab)));
}

pub fn appendTile(self: *BrowserView, tab: *BTab, fb: *c.GtkFlowBox, e: Entry) void {
    var full_buf: [4096]u8 = undefined;
    const full = tab.root.fullPath(e, &full_buf) orelse return;

    const step = tab.vs.step();
    const tile = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
    c.gtk_widget_set_size_request(tile, step.tile_px, -1);
    var icon: ?*c.GtkWidget = null;
    var thumb_pending = false;
    if (self.thumbLookup(tab.hc, full, e)) |tex| {
        const img = c.gtk_image_new_from_paintable(@ptrCast(tex));
        c.gtk_image_set_pixel_size(@ptrCast(img), step.tile_icon_px);
        icon = img;
    } else {
        thumb_pending = std.mem.eql(u8, e.kind, "file") and isPreviewMediaName(e.name);
    }
    if (icon == null) icon = entryIconImage(@ptrCast(@alignCast(fb)), e, step.tile_icon_px);
    c.gtk_box_append(@ptrCast(tile), icon);

    var name_z: [256:0]u8 = undefined;
    const nn = @min(e.name.len, name_z.len - 1);
    @memcpy(name_z[0..nn], e.name[0..nn]);
    name_z[nn] = 0;
    const lab = c.gtk_label_new(&name_z);
    c.gtk_label_set_ellipsize(@ptrCast(lab), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_label_set_max_width_chars(@ptrCast(lab), 12);
    c.gtk_box_append(@ptrCast(tile), lab);

    const child = c.gtk_flow_box_child_new();
    c.gtk_flow_box_child_set_child(@ptrCast(child), tile);
    const ctx = self.allocator.create(RowCtx) catch return;
    ctx.* = .{
        .allocator = self.allocator,
        .tab = tab,
        .path = self.allocator.dupe(u8, full) catch {
            self.allocator.destroy(ctx);
            return;
        },
        .is_dir = e.tdir,
    };
    c.g_object_set_data_full(@ptrCast(child), "sketerm-row", @ptrCast(ctx), @ptrCast(&freeRowCtx));
    if (thumb_pending) if (icon) |ic| {
        c.g_object_set_data(@ptrCast(child), "sketerm-thumb-img", @ptrCast(ic));
        c.g_object_set_data(@ptrCast(child), "sketerm-thumb-px", @ptrFromInt(@as(usize, @intCast(step.tile_icon_px))));
    };
    addEntryDragSource(tab, child);
    c.gtk_flow_box_append(fb, child);
}

pub fn onGridChildActivated(_: *c.GtkFlowBox, child: *c.GtkFlowBoxChild, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const data = c.g_object_get_data(@ptrCast(child), "sketerm-row") orelse return;
    const ctx: *RowCtx = @ptrCast(@alignCast(data));
    activateEntry(tab, ctx);
}

pub fn onGridSelectionChanged(fb: *c.GtkFlowBox, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    if (tab.rendering) return;
    const a = tab.view.allocator;
    for (tab.selected.items) |p| a.free(p);
    tab.selected.clearRetainingCapacity();
    var children = c.gtk_flow_box_get_selected_children(fb);
    const head = children;
    while (children != null) : (children = children.*.next) {
        const child: *c.GtkWidget = @ptrCast(@alignCast(children.*.data orelse continue));
        const data = c.g_object_get_data(@ptrCast(child), "sketerm-row") orelse continue;
        const ctx: *RowCtx = @ptrCast(@alignCast(data));
        const owned = a.dupe(u8, ctx.path) catch continue;
        tab.selected.append(a, owned) catch a.free(owned);
    }
    if (head != null) c.g_list_free(head);
    tab.view.updatePreview();
}

pub fn onGridRightClick(gesture: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    _ = n_press;
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const self = tab.view;
    const fb = tab.flowbox orelse return;
    var path: ?[]u8 = null;
    var name: ?[]u8 = null;
    var is_dir = false;
    if (c.gtk_flow_box_get_child_at_pos(fb, @intFromFloat(x), @intFromFloat(y))) |child| {
        if (c.g_object_get_data(@ptrCast(child), "sketerm-row")) |data| {
            const rctx: *RowCtx = @ptrCast(@alignCast(data));
            path = self.allocator.dupe(u8, rctx.path) catch null;
            name = self.allocator.dupe(u8, std.fs.path.basename(rctx.path)) catch null;
            is_dir = rctx.is_dir;
            // Same rule as the list view: a right-click inside a
            // multi-selection must not collapse it, and the press has
            // to be claimed or GtkFlowBox collapses it regardless
            // (see menu.keepOrSelect).
            _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
            if (c.gtk_flow_box_child_is_selected(child) == 0) {
                // Outside the selection: retarget to just this tile
                // (select_child alone ADDS in multiple mode).
                c.gtk_flow_box_unselect_all(fb);
                c.gtk_flow_box_select_child(fb, child);
            }
        }
    }
    self.showEntryMenu(tab, @as(*c.GtkWidget, @ptrCast(@alignCast(fb))), x, y, path, name, is_dir);
}

/// Rebuild the ancestor-column strip: one subscribed Dir per
/// ancestor of the current root, "/" first.
pub fn renderMillerCols(self: *BrowserView, tab: *BTab) void {
    // Desired chain: every ancestor of root (excluding root).
    var chain_buf: [64][]const u8 = undefined;
    var chain_n: usize = 0;
    {
        var p: []const u8 = tab.root.path;
        while (chain_n < chain_buf.len) {
            const parent = std.fs.path.dirname(p) orelse break;
            chain_buf[chain_n] = parent;
            chain_n += 1;
            if (parent.len <= 1) break;
            p = parent;
        }
    }
    // chain_buf is child-to-root; reverse into root-first order.
    var want: [64][]const u8 = undefined;
    for (0..chain_n) |i| want[i] = chain_buf[chain_n - 1 - i];

    // Resubscribe when the chain changed.
    var same = tab.ancestors.items.len == chain_n;
    if (same) {
        for (tab.ancestors.items, 0..) |d, i| {
            if (!std.mem.eql(u8, d.path, want[i])) same = false;
        }
    }
    if (!same) {
        tab.dropAncestors();
        for (want[0..chain_n]) |ap| {
            const d = self.makeDir(ap) orelse continue;
            tab.ancestors.append(self.allocator, d) catch {
                d.deinit();
                continue;
            };
            self.queueListing(tab, d, .open_view);
        }
    }

    // Rebuild the column widgets.
    while (c.gtk_widget_get_first_child(tab.miller_box)) |child| {
        c.gtk_box_remove(@ptrCast(tab.miller_box), child);
    }
    for (tab.ancestors.items) |d| {
        const col_scroll = c.gtk_scrolled_window_new();
        c.gtk_widget_set_size_request(col_scroll, 190, -1);
        c.gtk_widget_set_vexpand(col_scroll, 1);
        const col = c.gtk_list_box_new();
        c.gtk_list_box_set_selection_mode(@ptrCast(col), c.GTK_SELECTION_SINGLE);
        c.gtk_list_box_set_activate_on_single_click(@ptrCast(col), 1);
        _ = c.g_signal_connect_data(col, "row-activated", @ptrCast(&onMillerRowActivated), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
        c.gtk_scrolled_window_set_child(@ptrCast(col_scroll), col);
        // The child on the path to root gets selected.
        const next_seg = millerNextSegment(d.path, tab.root.path);
        for (d.entries.items) |e| {
            if (!tab.show_hidden and e.name.len > 0 and e.name[0] == '.') continue;
            if (!e.tdir) continue; // ancestor columns list directories only
            const row_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
            c.gtk_widget_set_margin_start(row_box, 6);
            const icon = iconload.newImageIcon(@ptrCast(@alignCast(tab.colview)), "folder", 16);
            c.gtk_box_append(@ptrCast(row_box), icon);
            var nz: [256:0]u8 = undefined;
            const nn = @min(e.name.len, nz.len - 1);
            @memcpy(nz[0..nn], e.name[0..nn]);
            nz[nn] = 0;
            const lab = c.gtk_label_new(&nz);
            c.gtk_label_set_xalign(@ptrCast(lab), 0);
            c.gtk_label_set_ellipsize(@ptrCast(lab), c.PANGO_ELLIPSIZE_MIDDLE);
            c.gtk_box_append(@ptrCast(row_box), lab);
            const row = c.gtk_list_box_row_new();
            c.gtk_list_box_row_set_child(@ptrCast(row), row_box);
            var full_buf: [4096]u8 = undefined;
            const full = d.fullPath(e, &full_buf) orelse continue;
            const ctx = self.allocator.create(RowCtx) catch continue;
            ctx.* = .{
                .allocator = self.allocator,
                .tab = tab,
                .path = self.allocator.dupe(u8, full) catch {
                    self.allocator.destroy(ctx);
                    continue;
                },
                .is_dir = true,
            };
            c.g_object_set_data_full(@ptrCast(row), "sketerm-row", @ptrCast(ctx), @ptrCast(&freeRowCtx));
            c.gtk_list_box_append(@ptrCast(col), row);
            if (next_seg != null and std.mem.eql(u8, e.name, next_seg.?))
                c.gtk_list_box_select_row(@ptrCast(col), @ptrCast(row));
        }
        c.gtk_box_append(@ptrCast(tab.miller_box), col_scroll);
        const sep = c.gtk_separator_new(c.GTK_ORIENTATION_VERTICAL);
        c.gtk_box_append(@ptrCast(tab.miller_box), sep);
    }
}

pub fn onMillerRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const data = c.g_object_get_data(@ptrCast(row), "sketerm-row") orelse return;
    const ctx: *RowCtx = @ptrCast(@alignCast(data));
    var buf: [4096]u8 = undefined;
    if (ctx.path.len >= buf.len) return;
    @memcpy(buf[0..ctx.path.len], ctx.path);
    const path = buf[0..ctx.path.len];
    var hbuf: [256]u8 = undefined;
    var host: ?[]const u8 = null;
    if (tab.hc.host) |h| {
        if (h.len >= hbuf.len) return;
        @memcpy(hbuf[0..h.len], h);
        host = hbuf[0..h.len];
    }
    tab.view.navigate(tab, host, path);
}

/// Swap a landed thumbnail into every live row/tile showing the
/// entry, IN PLACE. This is what makes a trickle of async thumbnails
/// cheap: before it, every arrival scheduled a full listing rebuild
/// (70ms+ for a few hundred rows, 8x/s while a remote folder's
/// thumbnails stream in).
/// @param key the thumb-cache key, "identity\x00mtime" with identity
/// "host:path" (remote) or the bare path (local).
/// @return true when at least one widget was updated.
pub fn applyThumbTexture(self: *BrowserView, key: []const u8, tex: *c.GdkTexture) bool {
    const key_end = std.mem.indexOfScalar(u8, key, 0) orelse key.len;
    const identity = key[0..key_end];
    var updated = false;
    for (self.tabs.items) |tab| {
        // Match the row path against the identity WITHOUT allocating:
        // strip the host prefix when the tab is remote.
        var want: []const u8 = identity;
        if (tab.hc.host) |host| {
            if (identity.len <= host.len + 1) continue;
            if (!std.mem.startsWith(u8, identity, host)) continue;
            if (identity[host.len] != ':') continue;
            want = identity[host.len + 1 ..];
        } else if (std.mem.indexOf(u8, identity, ":/") != null) continue;
        // List rows: only cells currently BOUND can show a pixel;
        // scrolled-away rows pick the texture up from the cache at
        // their next bind.
        if (tab.name_cells.get(want)) |root| {
            if (swapCellThumb(root, tab, tex)) updated = true;
        }
        if (tab.flowbox) |fb| {
            var j: c_int = 0;
            while (c.gtk_flow_box_get_child_at_index(fb, j)) |child| : (j += 1) {
                if (swapThumbWidget(@ptrCast(child), want, tex)) updated = true;
            }
        }
    }
    return updated;
}

/// Point a bound name cell's icon at the landed texture, if it still
/// waits for one.
fn swapCellThumb(root: *c.GtkWidget, tab: *BTab, tex: *c.GdkTexture) bool {
    if (c.g_object_get_data(@ptrCast(@alignCast(root)), "sketerm-thumb-pending") == null) return false;
    const nc_data = c.g_object_get_data(@ptrCast(@alignCast(root)), "sketerm-namecell") orelse return false;
    // The NameCell struct is private to colview.zig; go through its
    // helper instead of duplicating the layout here.
    const icon_widget = @import("colview.zig").iconOfNameCell(nc_data) orelse return false;
    c.gtk_image_set_from_paintable(@ptrCast(icon_widget), @ptrCast(tex));
    c.gtk_image_set_pixel_size(@ptrCast(icon_widget), tab.vs.step().icon_px);
    c.g_object_set_data(@ptrCast(@alignCast(root)), "sketerm-thumb-pending", null);
    return true;
}

/// One grid tile: if it shows `path` and still waits for a
/// thumbnail, point its icon at the texture.
fn swapThumbWidget(row: *c.GObject, path: []const u8, tex: *c.GdkTexture) bool {
    const data = c.g_object_get_data(row, "sketerm-row") orelse return false;
    const ctx: *RowCtx = @ptrCast(@alignCast(data));
    if (!std.mem.eql(u8, ctx.path, path)) return false;
    const img_data = c.g_object_get_data(row, "sketerm-thumb-img") orelse return false;
    const img: *c.GtkImage = @ptrCast(@alignCast(img_data));
    c.gtk_image_set_from_paintable(img, @ptrCast(tex));
    const px_data = c.g_object_get_data(row, "sketerm-thumb-px");
    const px: c_int = @intCast(@min(@intFromPtr(px_data), 512));
    if (px > 0) c.gtk_image_set_pixel_size(img, px);
    c.g_object_set_data(row, "sketerm-thumb-img", null);
    return true;
}

pub const RowCtx = struct {
    allocator: std.mem.Allocator,
    tab: *BTab,
    /// Full path of the entry.
    path: []u8,
    is_dir: bool,
};

pub fn freeRowCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx: *RowCtx = @ptrCast(@alignCast(user.?));
    ctx.allocator.free(ctx.path);
    ctx.allocator.destroy(ctx);
}

/// One extra-column cell's text: the raw value resolved from the
/// source that feeds it, rendered through the shared display form so
/// an ESTIMATED duration is never shown as a measurement.
/// A value-less cell is deliberately blank, not "unknown": a media
/// value that has not landed yet is indistinguishable from one the
/// file does not carry, and inventing either claim would be a lie.
pub fn columnCellText(tab: *BTab, dir: *Dir, e: Entry, name: []const u8, i: usize, buf: []u8) []const u8 {
    const source = colkeys.sourceOf(name) orelse return "";
    const sub = colkeys.subIndex(tab.attr_columns.items, i);
    const values = switch (source) {
        .xattr => e.attrs,
        .media => e.meta,
    };
    const raw = if (sub < values.len) values[sub] else "";
    if (raw.len == 0) return "";
    return colkeys.display(name, raw, mediaEstimated(tab, dir, e), false, buf);
}

/// Whether this entry's duration was DERIVED from a bitrate. Read
/// from the media column set when it is shown, else from the cached
/// answer, so the marker never depends on the user also adding
/// media.duration_estimated as its own column.
fn mediaEstimated(tab: *BTab, dir: *Dir, e: Entry) bool {
    for (tab.attr_columns.items, 0..) |name, i| {
        if (!std.mem.eql(u8, name, "media.duration_estimated")) continue;
        const sub = colkeys.subIndex(tab.attr_columns.items, i);
        if (sub < e.meta.len) return std.mem.eql(u8, e.meta[sub], "1");
    }
    var path_buf: [4096]u8 = undefined;
    const full = dir.fullPath(e, &path_buf) orelse return false;
    const v = mediacols.lookup(tab.view, tab.hc, full, e.mtime_ms, "media.duration_estimated") orelse return false;
    return std.mem.eql(u8, v, "1");
}

/// Resolve an entry's badge icon from the emblem rules. Attribute
/// values come from the listing itself: the rules' attributes were
/// requested with it, so this costs no round trip.
pub fn emblemFor(self: *BrowserView, tab: *BTab, e: Entry) ?[]const u8 {
    if (self.emblems.list.len == 0) return null;
    var spec_buf: [1024]u8 = undefined;
    const spec = self.attrSpec(tab, &spec_buf);
    const Lookup = struct {
        spec: []const u8,
        entry: Entry,
        fn get(self2: @This(), name: []const u8) ?[]const u8 {
            var i: usize = 0;
            var it = std.mem.splitScalar(u8, self2.spec, ',');
            while (it.next()) |requested| : (i += 1) {
                if (!std.mem.eql(u8, requested, name)) continue;
                return if (i < self2.entry.attrs.len) self2.entry.attrs[i] else null;
            }
            return null;
        }
    };
    return self.emblems.iconFor(e.name, Lookup{ .spec = spec, .entry = e }, Lookup.get);
}

/// Nemo's coarse category for a generic icon name; null falls back
/// to the full content-type description.
fn coarseFromIcon(icon: []const u8) ?[*:0]const u8 {
    const Map = struct { icon: []const u8, title: [*:0]const u8 };
    const map = [_]Map{
        .{ .icon = "application-x-executable", .title = "Program" },
        .{ .icon = "audio-x-generic", .title = "Audio" },
        .{ .icon = "font-x-generic", .title = "Font" },
        .{ .icon = "image-x-generic", .title = "Image" },
        .{ .icon = "package-x-generic", .title = "Archive" },
        .{ .icon = "text-html", .title = "Markup" },
        .{ .icon = "text-x-generic", .title = "Text" },
        .{ .icon = "video-x-generic", .title = "Video" },
        .{ .icon = "x-office-address-book", .title = "Contacts" },
        .{ .icon = "x-office-calendar", .title = "Calendar" },
        .{ .icon = "x-office-document", .title = "Document" },
        .{ .icon = "x-office-presentation", .title = "Presentation" },
        .{ .icon = "x-office-spreadsheet", .title = "Spreadsheet" },
    };
    for (map) |m| {
        if (std.mem.eql(u8, icon, m.icon)) return m.title;
    }
    return null;
}

/// Content type guessed FROM THE NAME (never the content; a remote
/// entry would mean reading the file). Caller g_free's the result.
fn guessContentType(name: []const u8) ?[*c]u8 {
    var nz: [512:0]u8 = undefined;
    _ = copyZN(&nz, name);
    var uncertain: c.gboolean = 0;
    return c.g_content_type_guess(&nz, null, 0, &uncertain);
}

/// The coarse Nemo-style Type cell ("Folder", "Image", "Program"...).
pub fn coarseTypeZ(e: Entry, buf: *[256:0]u8) [*:0]const u8 {
    if (std.mem.eql(u8, e.kind, "dir")) return "Folder";
    if (std.mem.eql(u8, e.kind, "link")) return if (e.tdir) "Link to folder" else "Link";
    if (!std.mem.eql(u8, e.kind, "file")) return "Other";
    const ctype = guessContentType(e.name) orelse return "File";
    defer c.g_free(ctype);
    const ctype_s = std.mem.span(@as([*:0]const u8, @ptrCast(ctype)));
    if (std.mem.eql(u8, ctype_s, "application/octet-stream"))
        return if (e.mode & 0o111 != 0) "Program" else "Binary";
    const icon = c.g_content_type_get_generic_icon_name(ctype);
    if (icon != null) {
        defer c.g_free(icon);
        if (coarseFromIcon(std.mem.span(@as([*:0]const u8, @ptrCast(icon))))) |t| return t;
    }
    const desc = c.g_content_type_get_description(ctype);
    if (desc != null) {
        defer c.g_free(desc);
        return copyZ(buf, std.mem.span(@as([*:0]const u8, @ptrCast(desc))));
    }
    return "File";
}

/// Detailed type ("PNG image") or raw MIME string for a cell.
fn contentTypeCellZ(e: Entry, raw_mime: bool, buf: *[256:0]u8) [*:0]const u8 {
    if (std.mem.eql(u8, e.kind, "dir")) return if (raw_mime) "inode/directory" else "Folder";
    if (std.mem.eql(u8, e.kind, "link") and !e.tdir and e.target == null) return "";
    const ctype = guessContentType(e.name) orelse return "";
    defer c.g_free(ctype);
    if (raw_mime) return copyZ(buf, std.mem.span(@as([*:0]const u8, @ptrCast(ctype))));
    const desc = c.g_content_type_get_description(ctype) orelse return "";
    defer c.g_free(desc);
    return copyZ(buf, std.mem.span(@as([*:0]const u8, @ptrCast(desc))));
}

/// One fixed column's cell text, rendered into the caller's buffers.
pub fn fixedCellText(
    dir: *Dir,
    e: Entry,
    col: browser_model.Column,
    buf: *[256:0]u8,
    mode_buf: *[16:0]u8,
    size_buf: *[48:0]u8,
    items_buf: *[32]u8,
    time_buf: *[40:0]u8,
) [*:0]const u8 {
    return switch (col) {
        .kind => coarseTypeZ(e, buf),
        .detailed_type => contentTypeCellZ(e, false, buf),
        .mime => contentTypeCellZ(e, true, buf),
        .extension => copyZ(buf, extensionOf(e.name)),
        .permissions => fmtModeZ(mode_buf, e.mode, e.tdir),
        .octal => if (std.fmt.bufPrintZ(buf, "{o:0>3}", .{e.mode})) |v| v.ptr else |_| "",
        .owner => if (e.owner.len > 0)
            copyZ(buf, e.owner)
        else if (std.fmt.bufPrintZ(buf, "{d}", .{e.uid})) |v|
            v.ptr
        else |_|
            "",
        .group => if (e.group.len > 0)
            copyZ(buf, e.group)
        else if (std.fmt.bufPrintZ(buf, "{d}", .{e.gid})) |v|
            v.ptr
        else |_|
            "",
        .nlink => if (std.fmt.bufPrintZ(buf, "{d}", .{e.nlink})) |v| v.ptr else |_| "",
        // A directory has no meaningful byte size; Nemo shows what it
        // holds instead, and so do we when the daemon counted it.
        .size => if (std.mem.eql(u8, e.kind, "dir"))
            copyZN(size_buf, fileicon.fmtItems(items_buf, e.children))
        else
            @as([*:0]const u8, fmtSize(size_buf, e.size).ptr),
        // st_blocks are 512-byte units regardless of the fs block size.
        .allocated => @as([*:0]const u8, fmtSize(size_buf, e.blocks * 512).ptr),
        .mtime => if (e.mtime_ms == 0) "" else fmtTimeZ(time_buf, e.mtime_ms),
        .ctime => if (e.ctime_ms == 0) "" else fmtTimeZ(time_buf, e.ctime_ms),
        .atime => if (e.atime_ms == 0) "" else fmtTimeZ(time_buf, e.atime_ms),
        .btime => if (e.btime_ms == 0) "" else fmtTimeZ(time_buf, e.btime_ms),
        .where => copyZ(buf, dir.path),
        .target => copyZ(buf, e.target orelse ""),
    };
}

pub fn activateEntry(tab: *BTab, ctx: *RowCtx) void {
    activatePath(tab, ctx.path, ctx.is_dir);
}

/// Open an activated entry: navigate a directory, launch a file
/// (locally or via the remote open-cache), or the archive/collection
/// special cases. `path` may live in storage the activation frees
/// (an item, a RowCtx) — it is copied out before anything re-renders.
pub fn activatePath(tab: *BTab, path_in: []const u8, is_dir: bool) void {
    const self = tab.view;
    var pathbuf: [4096]u8 = undefined;
    if (path_in.len >= pathbuf.len) return;
    @memcpy(pathbuf[0..path_in.len], path_in);
    const path = pathbuf[0..path_in.len];
    // Picker mode: activating a FILE reports it to the picker
    // instead of opening it; directories still navigate below.
    if (self.picker) |pk| {
        if (!is_dir) {
            pk.on_activate_file(pk.ctx, tab.hc.host, path);
            return;
        }
    }
    if (tab.root.archive.len > 0) {
        if (!is_dir) self.extractAndOpenMember(tab, path);
        return;
    }
    if (tab.root.collection) {
        // Collection rows hold host-qualified specs: open the
        // entry (dir) or its parent (file) in a NEW tab.
        const loc = parseSpec(path);
        var pbuf: [4096]u8 = undefined;
        const kind_dir = blk: {
            const i = tab.root.find(path) orelse break :blk false;
            break :blk std.mem.eql(u8, tab.root.entries.items[i].kind, "dir");
        };
        const dirp = if (kind_dir) loc.path else (std.fs.path.dirname(loc.path) orelse loc.path);
        if (dirp.len >= pbuf.len) return;
        @memcpy(pbuf[0..dirp.len], dirp);
        var hbuf: [256]u8 = undefined;
        var host: ?[]const u8 = null;
        if (loc.host) |h| {
            if (h.len >= hbuf.len) return;
            @memcpy(hbuf[0..h.len], h);
            host = hbuf[0..h.len];
        }
        _ = self.newTab(host, pbuf[0..dirp.len]);
        return;
    }
    if (is_dir) {
        var hbuf: [256]u8 = undefined;
        var host: ?[]const u8 = null;
        if (tab.hc.host) |h| {
            if (h.len >= hbuf.len) return;
            @memcpy(hbuf[0..h.len], h);
            host = hbuf[0..h.len];
        }
        self.navigate(tab, host, path);
    } else if (tab.hc.host == null) {
        // Local file: default application, straight from disk.
        launchLocal(path);
    } else {
        // Remote file: download into the local open-cache, then
        // launch (phase-5's hydrating cache predecessor).
        self.openRemoteFile(tab, path, null);
    }
}

/// ~/.config/sketerm/filecolors.conf: one "glob=#RRGGBB" per
/// line; first matching rule colors the file name.
pub fn loadFileColors(self: *BrowserView) void {
    var pbuf: [4096:0]u8 = undefined;
    const cfg = c.g_get_user_config_dir();
    const path = std.fmt.bufPrintZ(&pbuf, "{s}/sketerm/filecolors.conf", .{cfg}) catch return;
    const f = c.fopen(path.ptr, "rb") orelse return;
    defer _ = c.fclose(f);
    var content: [16 * 1024]u8 = undefined;
    const n = c.fread(&content, 1, content.len, f);
    var it = std.mem.tokenizeScalar(u8, content[0..n], '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const glob = std.mem.trim(u8, line[0..eq], " ");
        const color = std.mem.trim(u8, line[eq + 1 ..], " ");
        if (glob.len == 0 or color.len != 7 or color[0] != '#') continue;
        var fc = FileColor{
            .glob = self.allocator.dupe(u8, glob) catch continue,
            .color = undefined,
        };
        @memcpy(&fc.color, color[0..7]);
        self.file_colors.append(self.allocator, fc) catch self.allocator.free(fc.glob);
    }
}

pub fn fileColorFor(self: *BrowserView, name: []const u8) ?*const [7]u8 {
    for (self.file_colors.items) |*fc| {
        if (fsjob.nameMatches(fc.glob, name)) return &fc.color;
    }
    return null;
}

pub fn sortClicked(tab: *BTab, key: browser_model.SortKey) void {
    // Only one key orders the view; picking a fixed column drops
    // any attribute ordering.
    tab.attr_sort = null;
    if (tab.sort_key == key) {
        tab.descending = !tab.descending;
    } else {
        tab.sort_key = key;
        tab.descending = false;
    }
    tab.view.updateSortHeader(tab);
    views.rememberFolder(tab.view, tab);
    tab.view.renderTab(tab);
}
