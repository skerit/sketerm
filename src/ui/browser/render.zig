//! Rendering the listing: details/compact rows, the icon grid, the
//! Miller columns, the sort header and column picker, plus the
//! per-row decoration (emblems, file-color rules, thumbnails).

const std = @import("std");
const c = @import("../../c.zig").c;
const browser_model = @import("../../filebrowser/model.zig");
const fsjob = @import("../../mux/fsjob.zig");
const grouping = @import("../../filebrowser/grouping.zig");
const profile = @import("../../util/profile.zig");
const searchmod = @import("search.zig");
const views = @import("views.zig");

const colkeys = @import("../../filebrowser/colkeys.zig");
const fileicon = @import("../../filebrowser/fileicon.zig");
const format = @import("../../filebrowser/format.zig");
const mediacols = @import("mediacols.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const Dir = @import("types.zig").Dir;
const Entry = @import("types.zig").Entry;
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

/// Width of the per-row expander button, and of the spacer that stands
/// in for it on rows that cannot expand. They must agree or the name
/// column would not line up between folders and files.
const EXPANDER_PX = 16;

/// Horizontal gap between two adjacent widgets of a row or of the
/// header. The header box and every row box MUST use this same
/// spacing (and the same start/end margins) or the columns cannot
/// line up.
pub const CELL_SPACING = 4;

/// Row/header inset from the listing edges. Same reason.
pub const EDGE_MARGIN = 6;

/// Inset between a column's slot and its text, applied by CSS to
/// BOTH the header button and the data cell, so their content boxes
/// start at the same x. Doubled between two columns, plus
/// CELL_SPACING, is the whitespace that separates them.
pub const CELL_PAD = 4;

/// Width of the drag handle at a column's right edge. It is budgeted
/// INSIDE the column's width (the header button gets width - this),
/// so adding grips cannot shift the columns away from the rows.
pub const GRIP_PX = 6;

var css_installed = false;

/// Zero the theme's list-row padding and minimum height for the
/// browser listing.
///
/// Adwaita gives every `list > row` a generous padding and a 34px
/// min-height meant for settings rows; over a file listing that is
/// pure whitespace, and no per-widget margin can shrink it. Installed
/// once per process at APPLICATION priority, scoped to the
/// `sketerm-fb-list` class so it can never reach another list.
fn installCss(any_widget: *c.GtkWidget) void {
    // The stylesheet below is a literal; these are the numbers the
    // measuring code budgets with.
    comptime std.debug.assert(CELL_PAD == 4);
    comptime std.debug.assert(EXPANDER_PX == 16);
    if (css_installed) return;
    css_installed = true;
    const css =
        \\list.sketerm-fb-list > row {
        \\  padding: 0;
        \\  min-height: 0;
        \\}
        \\button.sketerm-fb-expander {
        \\  padding: 0;
        \\  margin: 0;
        \\  min-width: 16px;
        \\  min-height: 16px;
        \\}
        \\box.sketerm-fb-header button {
        \\  padding: 0 4px;
        \\  margin: 0;
        \\  border: none;
        \\  min-height: 0;
        \\  min-width: 0;
        \\}
        \\label.sketerm-fb-cell {
        \\  padding: 0 4px;
        \\}
        \\box.sketerm-fb-grip separator {
        \\  margin: 2px 0;
        \\  background: alpha(currentColor, 0.25);
        \\}
    ;
    const provider = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(provider, css);
    const display = c.gtk_widget_get_display(any_widget);
    c.gtk_style_context_add_provider_for_display(display, @ptrCast(@alignCast(provider)), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

/// A themed, full-colour icon image for a listing entry, sized `px`.
///
/// Directories get the theme's `folder`; everything else is resolved
/// from the content type GUESSED FROM THE NAME -- never from the
/// content, which for a remote entry would mean reading the file. That
/// is how the user's icon theme (Papirus, Breeze, ...) ends up
/// deciding what a .png or a .zip looks like, exactly as in Nemo.
fn entryIconImage(e: Entry, px: i32) ?*c.GtkWidget {
    const img: ?*c.GtkWidget = blk: {
        if (fileicon.folderIconName(e.kind, e.tdir)) |name| {
            var fz: [32:0]u8 = undefined;
            break :blk c.gtk_image_new_from_icon_name(copyZN(&fz, name));
        }
        var nz: [512:0]u8 = undefined;
        _ = copyZN(&nz, e.name);
        var uncertain: c.gboolean = 0;
        const ctype = c.g_content_type_guess(&nz, null, 0, &uncertain);
        if (ctype == null) break :blk null;
        defer c.g_free(ctype);
        // g_content_type_get_icon hands back a ref we own; the image
        // takes its own, so ours is dropped right after.
        const gicon = c.g_content_type_get_icon(ctype) orelse break :blk null;
        defer c.g_object_unref(gicon);
        break :blk c.gtk_image_new_from_gicon(gicon);
    } orelse fallback: {
        var gz: [32:0]u8 = undefined;
        break :fallback c.gtk_image_new_from_icon_name(copyZN(&gz, fileicon.GENERIC_ICON));
    };
    if (img) |i| c.gtk_image_set_pixel_size(@ptrCast(i), px);
    return img;
}

pub fn renderCurrent(self: *BrowserView) void {
    if (self.currentTab()) |t| self.renderTab(t);
}

pub fn renderTab(self: *BrowserView, tab: *BTab) void {
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
    // The count phrase, or -- when there is nothing to count -- what the
    // emptiness means. Both are then prefixed by a refused navigation,
    // which stays visible until the next one lands.
    const counted: []const u8 = if (failureReason(tab)) |why|
        std.fmt.bufPrint(&count_buf, "cannot open {s}: {s}", .{ tab.root.path, why }) catch
            "cannot open this folder"
    else if (tab.filter.len > 0)
        std.fmt.bufPrint(&count_buf, "showing {d} of {d} items (filter \"{s}\"){s}{s}", .{
            tab.vs.shown, tab.vs.total, tab.filter[0..@min(tab.filter.len, 48)], note, qnote,
        }) catch ""
    else if (tab.vs.total == 0)
        std.fmt.bufPrint(&count_buf, "{s}{s}{s}", .{ format.listingStatus(state), note, qnote }) catch ""
    else
        std.fmt.bufPrint(&count_buf, "{d} items{s}{s}", .{ tab.vs.total, note, qnote }) catch "";
    var status_buf: [700]u8 = undefined;
    const cmsg: []const u8 = if (tab.nav_error) |refused|
        std.fmt.bufPrint(&status_buf, "{s} -- still showing {s} ({s})", .{
            refused, tab.root.path, counted,
        }) catch refused
    else
        counted;
    self.setStatus(cmsg);

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
        if (state == .failed) c.gtk_widget_set_visible(tab.header_box, 0);
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
    c.gtk_widget_set_visible(tab.header_box, @intFromBool(mode == .details or mode == .compact));
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

/// How a header button renders the sort it carries: not at all, or
/// with the caret that says which way this column is ordered.
pub const SortMark = enum { none, ascending, descending };

pub fn sortMark(marked: bool, descending: bool) SortMark {
    if (!marked) return .none;
    return if (descending) .descending else .ascending;
}

/// Which column a header widget is about: one of the fixed set, or
/// an index into the tab's extra columns. The one currency the width
/// helpers and the resize grips deal in.
pub const ColumnRef = union(enum) {
    fixed: browser_model.Column,
    attr: usize,
};

/// The width of a column when the user has never dragged it.
pub fn defaultColumnWidth(ref: ColumnRef) i32 {
    return switch (ref) {
        .fixed => |col| col.width(),
        .attr => browser_model.ATTR_COLUMN_WIDTH,
    };
}

/// THE width of one details column, in the header and in every row.
///
/// Both the header button and the data cell are budgeted from this
/// one number, so a column's title and its values can never end up
/// over different pixels.
pub fn columnWidthOf(tab: *BTab, ref: ColumnRef) i32 {
    const stored: i32 = switch (ref) {
        .fixed => |col| tab.col_widths.get(col),
        // Deliberately tolerant: the width list may be shorter than
        // the name list (a restore fills the names first).
        .attr => |i| if (i < tab.attr_col_widths.items.len) tab.attr_col_widths.items[i] else 0,
    };
    if (stored <= 0) return defaultColumnWidth(ref);
    return @max(stored, browser_model.MIN_COLUMN_WIDTH);
}

/// Record a dragged width. Growing the extra-column list here is what
/// lets it stay shorter than `attr_columns` until someone drags.
pub fn setColumnWidth(tab: *BTab, ref: ColumnRef, width: i32) void {
    const w = @max(width, browser_model.MIN_COLUMN_WIDTH);
    switch (ref) {
        .fixed => |col| tab.col_widths.set(col, w),
        .attr => |i| {
            while (tab.attr_col_widths.items.len <= i)
                tab.attr_col_widths.append(tab.view.allocator, 0) catch return;
            tab.attr_col_widths.items[i] = w;
        },
    }
}

/// Forget a dragged width (double-click on the grip).
pub fn resetColumnWidth(tab: *BTab, ref: ColumnRef) void {
    switch (ref) {
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
    for (state.columns, 0..) |col, i| {
        if (i >= state.col_widths.len) break;
        if (state.col_widths[i] > 0) setColumnWidth(tab, .{ .fixed = col }, state.col_widths[i]);
    }
    for (state.attr_col_widths, 0..) |w, i| {
        if (i >= tab.attr_columns.items.len) break;
        if (w > 0) setColumnWidth(tab, .{ .attr = i }, w);
    }
}

/// Give a header button its label, plus the sort caret when it is the
/// column the listing is ordered by.
///
/// Nemo's layout: the title is LEFT-aligned over the cells below it
/// and the caret sits at the far right of the column. The caret slot
/// is reserved even when unsorted (an empty image), so toggling the
/// sort cannot shift a single column's x.
fn headerLabel(btn: *c.GtkWidget, label: [*:0]const u8, mark: SortMark) void {
    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, CELL_SPACING);
    const lab = c.gtk_label_new(label);
    c.gtk_label_set_xalign(@ptrCast(lab), 0);
    c.gtk_widget_set_halign(lab, c.GTK_ALIGN_START);
    c.gtk_widget_set_hexpand(lab, 1);
    // The title never grows the button past its budgeted width.
    c.gtk_label_set_ellipsize(@ptrCast(lab), c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(@ptrCast(box), lab);
    const arrow = switch (mark) {
        .none => c.gtk_image_new(),
        .descending => c.gtk_image_new_from_icon_name("pan-down-symbolic"),
        .ascending => c.gtk_image_new_from_icon_name("pan-up-symbolic"),
    };
    c.gtk_image_set_pixel_size(@ptrCast(arrow), 16);
    c.gtk_widget_set_halign(arrow, c.GTK_ALIGN_END);
    c.gtk_box_append(@ptrCast(box), arrow);
    c.gtk_button_set_child(@ptrCast(btn), box);
}

/// Right-click anywhere on the header strip opens the column picker,
/// the way every file manager's column header does. The visible
/// control is "Columns..." in the view-options menu.
pub fn installHeaderMenu(self: *BrowserView, tab: *BTab, btn: *c.GtkWidget) void {
    const ctx = self.allocator.create(HeaderCtx) catch return;
    ctx.* = .{ .allocator = self.allocator, .tab = tab, .column = null };
    const gesture = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(gesture), 3);
    _ = c.g_signal_connect_data(gesture, "pressed", @ptrCast(&onHeaderRightClick), @ptrCast(ctx), @ptrCast(&HeaderCtx.free), c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(btn, @ptrCast(gesture));
}

pub fn onHeaderRightClick(gesture: *c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const ctx: *HeaderCtx = @ptrCast(@alignCast(user.?));
    const btn = c.gtk_event_controller_get_widget(@ptrCast(gesture)) orelse return;
    showColumnPicker(ctx.tab, btn);
}

/// The Name header: the one column that takes the leftover width, so
/// it carries no fixed size and no resize grip.
pub fn nameHeaderButton(self: *BrowserView, tab: *BTab, mark: SortMark) void {
    const btn = c.gtk_button_new();
    c.gtk_button_set_has_frame(@ptrCast(btn), 0);
    c.gtk_widget_set_can_focus(btn, 0);
    headerLabel(btn.?, "Name", mark);
    c.gtk_widget_set_hexpand(btn, 1);
    const ctx = self.allocator.create(HeaderCtx) catch return;
    ctx.* = .{ .allocator = self.allocator, .tab = tab, .column = null };
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onHeaderClicked), @ptrCast(ctx), @ptrCast(&HeaderCtx.free), c.G_CONNECT_DEFAULT);
    installHeaderMenu(self, tab, btn.?);
    c.gtk_box_append(@ptrCast(tab.header_box), btn);
}

/// One sizeable column header: the sort button plus the drag grip at
/// its right edge, together exactly `columnWidthOf` pixels wide.
fn columnHeader(
    self: *BrowserView,
    tab: *BTab,
    ref: ColumnRef,
    label: [*:0]const u8,
    mark: SortMark,
    clicked: *const anyopaque,
    ctx: ?*anyopaque,
    free_ctx: ?*const anyopaque,
) void {
    const width = columnWidthOf(tab, ref);
    const slot = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    // GTK propagates a descendant's hexpand up the tree unless a
    // parent sets its own explicitly -- and the header title inside
    // the button DOES expand (that is what pushes the caret right).
    // Without these two, every column claimed a share of the leftover
    // width and the header ended up at twice the rows' column widths.
    c.gtk_widget_set_hexpand(slot, 0);
    const btn = c.gtk_button_new();
    c.gtk_widget_set_hexpand(btn, 0);
    c.gtk_button_set_has_frame(@ptrCast(btn), 0);
    c.gtk_widget_set_can_focus(btn, 0);
    headerLabel(btn.?, label, mark);
    c.gtk_widget_set_size_request(btn, width - GRIP_PX, -1);
    if (ctx != null)
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(clicked), ctx, @ptrCast(free_ctx), c.G_CONNECT_DEFAULT);
    installHeaderMenu(self, tab, btn.?);
    c.gtk_box_append(@ptrCast(slot), btn);
    c.gtk_box_append(@ptrCast(slot), makeGrip(self, tab, ref, btn.?));
    c.gtk_box_append(@ptrCast(tab.header_box), slot);
}

pub fn headerButton(self: *BrowserView, tab: *BTab, label: [*:0]const u8, column: browser_model.Column, mark: SortMark) void {
    const ctx = self.allocator.create(HeaderCtx) catch return;
    ctx.* = .{ .allocator = self.allocator, .tab = tab, .column = column };
    columnHeader(self, tab, .{ .fixed = column }, label, mark, &onHeaderClicked, @ptrCast(ctx), &HeaderCtx.free);
}

/// Cap on extra (key-named) columns: an xattr column costs an
/// lgetxattr per entry per listing and the daemon refuses more than
/// this anyway, and a media column costs host-side file reads.
pub const MAX_ATTR_COLUMNS = 8;

pub fn attrHeaderButton(self: *BrowserView, tab: *BTab, label: [*:0]const u8, index: usize, mark: SortMark) void {
    const ctx = self.allocator.create(AttrColumnCtx) catch return;
    ctx.* = .{ .allocator = self.allocator, .tab = tab, .index = index, .entry = null };
    columnHeader(self, tab, .{ .attr = index }, label, mark, &onAttrHeaderClicked, @ptrCast(ctx), &AttrColumnCtx.free);
}

/// Heap context for one column's resize grip.
pub const GripCtx = struct {
    allocator: std.mem.Allocator,
    tab: *BTab,
    ref: ColumnRef,
    /// The header button whose size request follows the pointer while
    /// the drag is in flight (the rows follow on release).
    button: *c.GtkWidget,
    /// Column width when this drag began.
    start: i32 = 0,

    fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const ctx: *GripCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.destroy(ctx);
    }
};

/// The thin draggable divider at a column's right edge: Nemo's
/// column resize handle, cursor and all. Double-clicking it puts the
/// column back at its default width.
fn makeGrip(self: *BrowserView, tab: *BTab, ref: ColumnRef, button: *c.GtkWidget) *c.GtkWidget {
    const grip = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_add_css_class(grip, "sketerm-fb-grip");
    c.gtk_widget_set_size_request(grip, GRIP_PX, -1);
    c.gtk_widget_set_tooltip_text(grip, "Drag to resize this column; double-click to reset it");
    c.gtk_widget_set_cursor_from_name(grip, "col-resize");
    const line = c.gtk_separator_new(c.GTK_ORIENTATION_VERTICAL);
    c.gtk_widget_set_halign(line, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_hexpand(line, 1);
    c.gtk_box_append(@ptrCast(grip), line);

    const ctx = self.allocator.create(GripCtx) catch return grip.?;
    ctx.* = .{ .allocator = self.allocator, .tab = tab, .ref = ref, .button = button };
    const drag = c.gtk_gesture_drag_new();
    _ = c.g_signal_connect_data(drag, "drag-begin", @ptrCast(&onGripDragBegin), @ptrCast(ctx), @ptrCast(&GripCtx.free), c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(drag, "drag-update", @ptrCast(&onGripDragUpdate), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(drag, "drag-end", @ptrCast(&onGripDragEnd), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(grip, @ptrCast(drag));
    const click = c.gtk_gesture_click_new();
    _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&onGripPressed), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(grip, @ptrCast(click));
    return grip.?;
}

pub fn onGripDragBegin(_: *c.GtkGestureDrag, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const ctx: *GripCtx = @ptrCast(@alignCast(user.?));
    ctx.start = columnWidthOf(ctx.tab, ctx.ref);
}

/// Live feedback while dragging: only the HEADER follows the pointer.
/// Re-rendering every row per motion frame would cost a full listing
/// rebuild per frame; the rows catch up on release.
pub fn onGripDragUpdate(_: *c.GtkGestureDrag, dx: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    dragTo(@ptrCast(@alignCast(user.?)), dx);
}

fn dragTo(ctx: *GripCtx, dx: f64) void {
    const width = @max(ctx.start + @as(i32, @intFromFloat(dx)), browser_model.MIN_COLUMN_WIDTH);
    setColumnWidth(ctx.tab, ctx.ref, width);
    c.gtk_widget_set_size_request(ctx.button, width - GRIP_PX, -1);
}

pub fn onGripDragEnd(_: *c.GtkGestureDrag, dx: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const ctx: *GripCtx = @ptrCast(@alignCast(user.?));
    dragTo(ctx, dx);
    // A press that moved nothing is not a resize -- and re-rendering
    // it would destroy this grip mid-click, which is exactly what
    // stops the second press of a double-click from ever arriving.
    if (columnWidthOf(ctx.tab, ctx.ref) == ctx.start) return;
    // The re-render rebuilds the header, which destroys this grip and
    // frees `ctx` -- so nothing may be read from it afterwards. This
    // is the one re-render that moves the rows under the new header.
    const tab = ctx.tab;
    // A dragged width is a view setting like sort or zoom: it joins
    // the folder's remembered view, so revisiting the folder (or a
    // fresh files-app start) keeps it.
    @import("views.zig").rememberFolder(tab.view, tab);
    tab.view.renderTab(tab);
}

/// Double-click a grip: back to the column's built-in width.
pub fn onGripPressed(_: *c.GtkGestureClick, n_press: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    if (n_press != 2) return;
    const ctx: *GripCtx = @ptrCast(@alignCast(user.?));
    resetColumnWidth(ctx.tab, ctx.ref);
    // Same teardown rule as drag-end: read everything first.
    const tab = ctx.tab;
    @import("views.zig").rememberFolder(tab.view, tab);
    tab.view.renderTab(tab);
}

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

pub fn onAttrHeaderClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *AttrColumnCtx = @ptrCast(@alignCast(user.?));
    const tab = ctx.tab;
    if (ctx.index >= tab.attr_columns.items.len) return;
    if (tab.attr_sort != null and tab.attr_sort.? == ctx.index) {
        tab.descending = !tab.descending;
    } else {
        tab.attr_sort = ctx.index;
        tab.descending = false;
    }
    // Extra-column order is its own key; the fixed-column key stops
    // claiming the header marker.
    tab.sort_key = .name;
    // Sorting by a media column is only meaningful for rows whose
    // value has been read, so this ONE user action opts into a
    // bounded read-ahead past the visible window. The status line
    // reports how much of the directory the sort actually covers.
    if (colkeys.sourceOf(tab.attr_columns.items[ctx.index]) == .media)
        mediacols.beginSortFill(tab.view);
    tab.view.updateSortHeader(tab);
    tab.view.renderTab(tab);
}

pub fn onAttrColumnRemove(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *AttrColumnCtx = @ptrCast(@alignCast(user.?));
    const tab = ctx.tab;
    if (ctx.index >= tab.attr_columns.items.len) return;
    const self = tab.view;
    const removed = tab.attr_columns.orderedRemove(ctx.index);
    // The width list is positional; drop the same slot or every
    // column after this one inherits its neighbour's width.
    if (ctx.index < tab.attr_col_widths.items.len)
        _ = tab.attr_col_widths.orderedRemove(ctx.index);
    const was_xattr = colkeys.sourceOf(removed) == .xattr;
    self.allocator.free(removed);
    tab.attr_sort = null;
    self.closeColumnPicker();
    applyColumnChange(self, tab, was_xattr);
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
    const self = tab.view;
    const raw = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(entry)))));
    const name = std.mem.trim(u8, raw, " ");
    if (name.len == 0) return;
    if (colkeys.sourceOf(name) == null)
        return self.setStatus("column keys are user.*, media.*, tag.*, exif.*, image.* or doc.*");
    if (tab.attr_columns.items.len >= MAX_ATTR_COLUMNS)
        return self.setStatusFmt("at most {d} extra columns", .{MAX_ATTR_COLUMNS});
    for (tab.attr_columns.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return self.setStatus("that column is already shown");
    }
    const owned = self.allocator.dupe(u8, name) catch return;
    tab.attr_columns.append(self.allocator, owned) catch {
        self.allocator.free(owned);
        return;
    };
    self.closeColumnPicker();
    applyColumnChange(self, tab, colkeys.sourceOf(name) == .xattr);
}

pub fn closeColumnPicker(self: *BrowserView) void {
    const pop = self.column_picker orelse return;
    self.column_picker = null;
    c.gtk_popover_popdown(@ptrCast(pop));
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

pub fn onHeaderClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *HeaderCtx = @ptrCast(@alignCast(user.?));
    sortClicked(ctx.tab, if (ctx.column) |col| col.sortKey() else .name);
}

/// Rebuild the sort header for the tab's current column set. Also
/// the single place that renders sort direction.
pub fn updateSortHeader(self: *BrowserView, tab: *BTab) void {
    installCss(tab.header_box);
    while (c.gtk_widget_get_first_child(tab.header_box)) |child|
        c.gtk_box_remove(@ptrCast(tab.header_box), child);
    // The header's leading spacer stands in for a row's expander
    // slot, less the header button's own text inset, so "Name" lands
    // exactly over the row icons -- the Nemo layout. Without it the
    // whole header sat one expander to the left of the rows.
    const lead = c.gtk_label_new("");
    c.gtk_widget_set_size_request(lead, EXPANDER_PX - CELL_PAD, -1);
    c.gtk_box_append(@ptrCast(tab.header_box), lead);
    // The name column carries the sort only while no extra column
    // claims it (an attribute sort parks sort_key back on .name).
    const name_marked = tab.sort_key == .name and tab.attr_sort == null;
    nameHeaderButton(self, tab, sortMark(name_marked, tab.descending));
    if (tab.view_mode == .details) {
        for (std.enums.values(browser_model.Column)) |col| {
            if (!tab.columns.contains(col)) continue;
            const marked = tab.sort_key == col.sortKey() and col != .target and tab.attr_sort == null;
            self.headerButton(tab, col.title(), col, sortMark(marked, tab.descending));
        }
        for (tab.attr_columns.items, 0..) |name, i| {
            var cb: [64:0]u8 = undefined;
            const marked = tab.attr_sort != null and tab.attr_sort.? == i;
            const txt: [*:0]const u8 = if (std.fmt.bufPrintZ(&cb, "{s}", .{colkeys.label(name)})) |v| v.ptr else |_| "column";
            self.attrHeaderButton(tab, txt, i, sortMark(marked, tab.descending));
        }
    }
}

pub fn onColumnPicker(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *HeaderCtx = @ptrCast(@alignCast(user.?));
    showColumnPicker(ctx.tab, @ptrCast(@alignCast(btn)));
}

/// Build and pop the column picker, anchored at `btn` -- whichever
/// header widget was clicked, since a right-click anywhere in the
/// header opens it too.
pub fn showColumnPicker(tab: *BTab, btn: *c.GtkWidget) void {
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
    for (std.enums.values(browser_model.Column)) |col| {
        const check = c.gtk_check_button_new_with_label(col.title());
        c.gtk_check_button_set_active(@ptrCast(check), @intFromBool(tab.columns.contains(col)));
        const cctx = self.allocator.create(HeaderCtx) catch continue;
        cctx.* = .{ .allocator = self.allocator, .tab = tab, .column = col };
        _ = c.g_signal_connect_data(check, "toggled", @ptrCast(&onColumnToggled), @ptrCast(cctx), @ptrCast(&HeaderCtx.free), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), check);
    }
    c.gtk_box_append(@ptrCast(box), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));
    const attr_head = c.gtk_label_new("Attribute and metadata columns");
    c.gtk_label_set_xalign(@ptrCast(attr_head), 0);
    c.gtk_widget_add_css_class(attr_head, "dim-label");
    c.gtk_box_append(@ptrCast(box), attr_head);
    for (tab.attr_columns.items, 0..) |name, i| {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        var nz: [256:0]u8 = undefined;
        const lbl = c.gtk_label_new(copyZ(@ptrCast(&nz), name));
        c.gtk_label_set_xalign(@ptrCast(lbl), 0);
        c.gtk_widget_set_hexpand(lbl, 1);
        c.gtk_box_append(@ptrCast(row), lbl);
        const remove = c.gtk_button_new_from_icon_name("list-remove-symbolic");
        const rctx = self.allocator.create(AttrColumnCtx) catch continue;
        rctx.* = .{ .allocator = self.allocator, .tab = tab, .index = i, .entry = null };
        _ = c.g_signal_connect_data(remove, "clicked", @ptrCast(&onAttrColumnRemove), @ptrCast(rctx), @ptrCast(&AttrColumnCtx.free), c.G_CONNECT_DEFAULT);
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

    c.gtk_popover_set_child(@ptrCast(popover), box);
    // Parent to the PAGE, not the button: every toggle rebuilds
    // the header, which would destroy a button-parented popover
    // and close the picker after a single click.
    var bounds: c.graphene_rect_t = undefined;
    if (c.gtk_widget_compute_bounds(@ptrCast(btn), tab.page, &bounds) != 0) {
        const rect = c.GdkRectangle{
            .x = @intFromFloat(bounds.origin.x),
            .y = @intFromFloat(bounds.origin.y),
            .width = @intFromFloat(bounds.size.width),
            .height = @intFromFloat(bounds.size.height),
        };
        c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
    }
    c.gtk_widget_set_parent(popover, tab.page);
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
    // Full rebuild — simple and correct; fine for the row counts
    // a human browses. (Optimization: diff rows later.)
    tab.rendering = true;
    defer tab.rendering = false;
    // The listbox is built in nav.zig; its density styling is claimed
    // here, on the first render, because this is where the pointer is.
    const listbox: *c.GtkWidget = @ptrCast(@alignCast(tab.listbox));
    if (c.gtk_widget_has_css_class(listbox, "sketerm-fb-list") == 0) {
        c.gtk_widget_add_css_class(listbox, "sketerm-fb-list");
        installCss(listbox);
    }
    while (c.gtk_list_box_get_row_at_index(tab.listbox, 0)) |row| {
        c.gtk_list_box_remove(tab.listbox, @ptrCast(row));
    }
    if (tab.vs.grouped) self.renderGroupedRows(tab) else self.renderDirRows(tab, tab.root, 0);
    var row_idx: c_int = 0;
    while (c.gtk_list_box_get_row_at_index(tab.listbox, row_idx)) |row| : (row_idx += 1) {
        const data = c.g_object_get_data(@ptrCast(row), "sketerm-row") orelse continue;
        const ctx: *RowCtx = @ptrCast(@alignCast(data));
        for (tab.selected.items) |path| {
            if (std.mem.eql(u8, path, ctx.path)) {
                c.gtk_list_box_select_row(tab.listbox, @ptrCast(row));
                break;
            }
        }
    }
}

pub fn ensureFlowbox(self: *BrowserView, tab: *BTab) *c.GtkFlowBox {
    if (tab.flowbox) |fb| return fb;
    const fs = c.gtk_scrolled_window_new();
    c.gtk_widget_set_hexpand(fs, 1);
    c.gtk_widget_set_vexpand(fs, 1);
    const fb = c.gtk_flow_box_new();
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
pub fn addEntryDragSource(tab: *BTab, widget: *c.GtkWidget, full: []const u8) void {
    var pz: [4500:0]u8 = undefined;
    const spec_res = if (tab.hc.host) |h|
        std.fmt.bufPrintZ(&pz, "{s}:{s}", .{ h, full })
    else
        std.fmt.bufPrintZ(&pz, "{s}", .{full});
    const pzs = spec_res catch return;
    const provider = c.gdk_content_provider_new_typed(c.G_TYPE_STRING, pzs.ptr);
    const dsrc = c.gtk_drag_source_new();
    c.gtk_drag_source_set_content(dsrc, provider);
    c.g_object_unref(provider);
    c.gtk_widget_add_controller(widget, @ptrCast(dsrc));
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
    if (icon == null) icon = entryIconImage(e, step.tile_icon_px);
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
    addEntryDragSource(tab, child, full);
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
            if (c.gtk_flow_box_child_is_selected(child) == 0)
                c.gtk_flow_box_select_child(fb, child);
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
            const icon = c.gtk_image_new_from_icon_name("folder");
            c.gtk_image_set_pixel_size(@ptrCast(icon), 16);
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

pub fn renderDirRows(self: *BrowserView, tab: *BTab, dir: *Dir, depth: u32) void {
    for (dir.entries.items) |e| {
        if (!views.entryVisible(tab, e)) continue;
        self.appendRowTree(tab, dir, e, depth);
    }
}

/// One row plus the rows of its expanded subdirectory, if any. The
/// shared step of the plain and the grouped list walk.
pub fn appendRowTree(self: *BrowserView, tab: *BTab, dir: *Dir, e: Entry, depth: u32) void {
    self.appendRow(tab, dir, e, depth);
    if (!e.tdir) return;
    var buf: [4096]u8 = undefined;
    const child = dir.fullPath(e, &buf) orelse return;
    const sub = tab.subdirByPath(child) orelse return;
    if (sub.loaded) self.renderDirRows(tab, sub, depth + 1);
}

/// One group run of the root listing, for the header's count.
const GroupRun = struct { id: u64, count: usize };

/// Grouped list rendering: one collapsible header per bucket of the
/// ROOT listing, carrying that group's visible count. Entries are
/// already sorted by the same key the buckets come from, so a run
/// ends exactly when the bucket id changes. Expanded subdirectories
/// keep rendering under their parent row, inside its group.
pub fn renderGroupedRows(self: *BrowserView, tab: *BTab) void {
    const now_ms = profile.milliTimestamp();
    // First pass: the visible count of each run, in listing order.
    var runs: std.ArrayList(GroupRun) = .empty;
    defer runs.deinit(self.allocator);
    for (tab.root.entries.items) |e| {
        if (!views.entryVisible(tab, e)) continue;
        const g = views.groupFor(tab, e, now_ms);
        if (runs.items.len > 0 and runs.items[runs.items.len - 1].id == g.id) {
            runs.items[runs.items.len - 1].count += 1;
            continue;
        }
        runs.append(self.allocator, .{ .id = g.id, .count = 1 }) catch return;
    }
    // Second pass: a header per run, then its rows unless collapsed.
    var run: usize = 0;
    var last_id: ?u64 = null;
    for (tab.root.entries.items) |e| {
        if (!views.entryVisible(tab, e)) continue;
        const g = views.groupFor(tab, e, now_ms);
        if (last_id == null or last_id.? != g.id) {
            last_id = g.id;
            const count = if (run < runs.items.len) runs.items[run].count else 0;
            run += 1;
            self.appendGroupHeader(tab, g, count);
        }
        if (views.groupCollapsed(tab, g.id)) continue;
        self.appendRowTree(tab, tab.root, e, 0);
    }
}

/// Heap context for one group header button.
pub const GroupCtx = struct {
    allocator: std.mem.Allocator,
    tab: *BTab,
    id: u64,

    fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const ctx: *GroupCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.destroy(ctx);
    }
};

pub fn appendGroupHeader(self: *BrowserView, tab: *BTab, g: grouping.Group, count: usize) void {
    const collapsed = views.groupCollapsed(tab, g.id);
    var text: [96:0]u8 = undefined;
    const label: [*:0]const u8 = if (std.fmt.bufPrintZ(&text, "{s}  ({d})", .{
        g.label(), count,
    })) |v| v.ptr else |_| "group";
    const btn = c.gtk_button_new();
    c.gtk_button_set_has_frame(@ptrCast(btn), 0);
    const btn_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    const arrow = c.gtk_image_new_from_icon_name(if (collapsed) "pan-end-symbolic" else "pan-down-symbolic");
    c.gtk_box_append(@ptrCast(btn_box), arrow);
    const lab = c.gtk_label_new(label);
    c.gtk_label_set_xalign(@ptrCast(lab), 0);
    c.gtk_widget_set_hexpand(lab, 1);
    c.gtk_widget_add_css_class(lab, "heading");
    c.gtk_box_append(@ptrCast(btn_box), lab);
    c.gtk_button_set_child(@ptrCast(btn), btn_box);
    const ctx = self.allocator.create(GroupCtx) catch return;
    ctx.* = .{ .allocator = self.allocator, .tab = tab, .id = g.id };
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onGroupHeaderClicked), @ptrCast(ctx), @ptrCast(&GroupCtx.free), c.G_CONNECT_DEFAULT);

    const row = c.gtk_list_box_row_new();
    c.gtk_list_box_row_set_child(@ptrCast(row), btn);
    // Headers are chrome: never selected, never type-ahead targets
    // (they carry no "sketerm-row" data).
    c.gtk_list_box_row_set_selectable(@ptrCast(row), 0);
    c.gtk_list_box_row_set_activatable(@ptrCast(row), 0);
    c.gtk_list_box_append(tab.listbox, row);
}

pub fn onGroupHeaderClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *GroupCtx = @ptrCast(@alignCast(user.?));
    views.toggleGroup(ctx.tab.view, ctx.tab, ctx.id);
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
        var i: c_int = 0;
        while (c.gtk_list_box_get_row_at_index(tab.listbox, i)) |row| : (i += 1) {
            if (swapThumbWidget(@ptrCast(row), want, tex)) updated = true;
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

/// One row/tile: if it shows `path` and still waits for a thumbnail,
/// point its icon at the texture.
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

pub fn appendRow(self: *BrowserView, tab: *BTab, dir: *Dir, e: Entry, depth: u32) void {
    // Zoom drives both the icon size and the row height.
    const step = tab.vs.step();
    // Spacing and margins are shared with the header box; they are
    // half of what makes the columns line up.
    const row_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, CELL_SPACING);
    c.gtk_widget_set_margin_start(row_box, @intCast(EDGE_MARGIN + depth * 18));
    c.gtk_widget_set_margin_end(row_box, EDGE_MARGIN);
    c.gtk_widget_set_margin_top(row_box, step.row_pad);
    c.gtk_widget_set_margin_bottom(row_box, step.row_pad);

    var full_buf: [4096]u8 = undefined;
    const full = dir.fullPath(e, &full_buf) orelse return;

    if (e.tdir and !dir.flat) {
        const expanded = tab.subdirByPath(full) != null;
        const exp = c.gtk_button_new_from_icon_name(if (expanded) "pan-down-symbolic" else "pan-end-symbolic");
        c.gtk_button_set_has_frame(@ptrCast(exp), 0);
        c.gtk_widget_add_css_class(exp, "sketerm-fb-expander");
        c.gtk_widget_set_valign(exp, c.GTK_ALIGN_CENTER);
        const ctx = self.allocator.create(RowCtx) catch return;
        ctx.* = .{
            .allocator = self.allocator,
            .tab = tab,
            .path = self.allocator.dupe(u8, full) catch {
                self.allocator.destroy(ctx);
                return;
            },
            .is_dir = true,
        };
        _ = c.g_signal_connect_data(exp, "clicked", @ptrCast(&onExpandClicked), @ptrCast(ctx), @ptrCast(&freeRowCtxClosure), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row_box), exp);
    } else {
        const spacer = c.gtk_label_new("");
        c.gtk_widget_set_size_request(spacer, EXPANDER_PX, -1);
        c.gtk_box_append(@ptrCast(row_box), spacer);
    }

    // Image files get a real freedesktop thumbnail (async: rows
    // show the generic icon until the texture lands); works for
    // local AND remote entries.
    var icon: ?*c.GtkWidget = null;
    var thumb_pending = false;
    if (self.thumbLookup(tab.hc, full, e)) |tex| {
        const img = c.gtk_image_new_from_paintable(@ptrCast(tex));
        c.gtk_image_set_pixel_size(@ptrCast(img), step.thumb_px);
        icon = img;
    } else {
        thumb_pending = std.mem.eql(u8, e.kind, "file") and isPreviewMediaName(e.name);
    }
    if (icon == null) icon = entryIconImage(e, step.icon_px);
    c.gtk_box_append(@ptrCast(row_box), icon);

    if (self.emblemFor(tab, e)) |emblem| {
        var iz: [128:0]u8 = undefined;
        const badge = c.gtk_image_new_from_icon_name(copyZ(@ptrCast(&iz), emblem));
        c.gtk_image_set_pixel_size(@ptrCast(badge), 12);
        c.gtk_widget_set_valign(badge, c.GTK_ALIGN_END);
        c.gtk_box_append(@ptrCast(row_box), badge);
    }

    var name_buf: [512:0]u8 = undefined;
    const nn = @min(e.name.len, name_buf.len - 1);
    @memcpy(name_buf[0..nn], e.name[0..nn]);
    name_buf[nn] = 0;
    const name_label = c.gtk_label_new(&name_buf);
    if (self.fileColorFor(e.name)) |color| {
        const esc = c.g_markup_escape_text(&name_buf, -1);
        var mk: [640:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&mk, "<span foreground=\"{s}\">{s}</span>", .{
            color, std.mem.span(@as([*:0]const u8, @ptrCast(esc))),
        })) |m| {
            c.gtk_label_set_markup(@ptrCast(name_label), m.ptr);
        } else |_| {}
        c.g_free(esc);
    }
    c.gtk_label_set_xalign(@ptrCast(name_label), 0);
    c.gtk_widget_set_hexpand(name_label, 1);
    c.gtk_label_set_ellipsize(@ptrCast(name_label), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_box_append(@ptrCast(row_box), name_label);

    // Git status badge (local current dir only).
    if (tab.hc.host == null and dir == tab.root) {
        if (self.git_map.get(e.name)) |st| {
            var gz: [8:0]u8 = undefined;
            const gtxt = std.fmt.bufPrintZ(&gz, "[{c}]", .{st}) catch "";
            const gl = c.gtk_label_new(gtxt.ptr);
            c.gtk_widget_add_css_class(gl, if (st == '?') "dim-label" else "warning");
            c.gtk_box_append(@ptrCast(row_box), gl);
        }
    }

    if (e.tags.len > 0) {
        var tag_z: [128:0]u8 = undefined;
        const ttxt = std.fmt.bufPrintZ(&tag_z, "[{s}]", .{e.tags}) catch "";
        const tag_label = c.gtk_label_new(ttxt.ptr);
        // Deterministic per-tagset color chip (markup only when
        // the text is markup-safe).
        if (std.mem.indexOfAny(u8, e.tags, "<>&\"") == null) {
            var mk: [192:0]u8 = undefined;
            if (std.fmt.bufPrintZ(&mk, "<span foreground=\"{s}\">[{s}]</span>", .{
                tagColorHex(e.tags), e.tags,
            })) |m| {
                c.gtk_label_set_markup(@ptrCast(tag_label), m.ptr);
            } else |_| {}
        } else {
            c.gtk_widget_add_css_class(tag_label, "dim-label");
        }
        c.gtk_box_append(@ptrCast(row_box), tag_label);
    }

    // Compact view is name (+tags) only; details renders the
    // tab's chosen columns, in Column declaration order.
    if (tab.view_mode == .details) {
        for (std.enums.values(browser_model.Column)) |col| {
            if (!tab.columns.contains(col)) continue;
            self.appendColumnCell(tab, row_box, e, col);
        }
        for (tab.attr_columns.items, 0..) |name, i| {
            var vz: [256:0]u8 = undefined;
            var disp_buf: [256]u8 = undefined;
            const label = c.gtk_label_new(copyZ(
                @ptrCast(&vz),
                columnCellText(tab, dir, e, name, i, &disp_buf),
            ));
            c.gtk_widget_add_css_class(label, "dim-label");
            cellLabel(tab, label.?, .{ .attr = i }, 0);
            c.gtk_box_append(@ptrCast(row_box), label);
        }
    }

    const row = c.gtk_list_box_row_new();
    c.gtk_list_box_row_set_child(@ptrCast(row), row_box);

    // Row context for activation, freed with the row.
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
    c.g_object_set_data_full(@ptrCast(row), "sketerm-row", @ptrCast(ctx), @ptrCast(&freeRowCtx));

    // The icon a landed thumbnail may replace IN PLACE (see
    // applyThumbTexture) -- a trickle of async thumbnails must not
    // cost one full listing rebuild each.
    if (thumb_pending) if (icon) |ic| {
        c.g_object_set_data(@ptrCast(row), "sketerm-thumb-img", @ptrCast(ic));
        c.g_object_set_data(@ptrCast(row), "sketerm-thumb-px", @ptrFromInt(@as(usize, @intCast(step.thumb_px))));
    };

    addEntryDragSource(tab, row, full);

    c.gtk_list_box_append(tab.listbox, row);
}

/// One extra-column cell's text: the raw value resolved from the
/// source that feeds it, rendered through the shared display form so
/// an ESTIMATED duration is never shown as a measurement.
/// A value-less cell is deliberately blank, not "unknown": a media
/// value that has not landed yet is indistinguishable from one the
/// file does not carry, and inventing either claim would be a lie.
fn columnCellText(tab: *BTab, dir: *Dir, e: Entry, name: []const u8, i: usize, buf: []u8) []const u8 {
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

/// Size one data cell exactly like its header: the same budgeted
/// width and the same text inset (the CSS class), so the column's
/// title and its values start on the same pixel.
fn cellLabel(tab: *BTab, label: *c.GtkWidget, ref: ColumnRef, xalign: f32) void {
    c.gtk_widget_add_css_class(label, "sketerm-fb-cell");
    c.gtk_label_set_xalign(@ptrCast(label), xalign);
    c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_widget_set_size_request(label, columnWidthOf(tab, ref), -1);
}

/// One details-view column cell. Widths match the header buttons
/// so the columns line up without a size group.
pub fn appendColumnCell(self: *BrowserView, tab: *BTab, row_box: *c.GtkWidget, e: Entry, col: browser_model.Column) void {
    _ = self;
    var buf: [256:0]u8 = undefined;
    var mode_buf: [16:0]u8 = undefined;
    var size_buf: [48:0]u8 = undefined;
    var items_buf: [32]u8 = undefined;
    var time_buf: [40:0]u8 = undefined;
    const text: [*:0]const u8 = switch (col) {
        .kind => copyZ(&buf, e.kind),
        .permissions => fmtModeZ(&mode_buf, e.mode, e.tdir),
        .owner => if (std.fmt.bufPrintZ(&buf, "{d}", .{e.uid})) |v| v.ptr else |_| "",
        .group => if (std.fmt.bufPrintZ(&buf, "{d}", .{e.gid})) |v| v.ptr else |_| "",
        // A directory has no meaningful byte size; Nemo shows what it
        // holds instead, and so do we when the daemon counted it.
        .size => if (std.mem.eql(u8, e.kind, "dir"))
            copyZN(&size_buf, fileicon.fmtItems(&items_buf, e.children))
        else
            @as([*:0]const u8, fmtSize(&size_buf, e.size).ptr),
        .mtime => if (e.mtime_ms == 0) "" else fmtTimeZ(&time_buf, e.mtime_ms),
        .ctime => if (e.ctime_ms == 0) "" else fmtTimeZ(&time_buf, e.ctime_ms),
        .target => copyZ(&buf, e.target orelse ""),
    };
    const label = c.gtk_label_new(text);
    c.gtk_widget_add_css_class(label, "dim-label");
    if (col == .permissions) c.gtk_widget_add_css_class(label, "monospace");
    // Sizes read as numbers, right-aligned; everything else lines up
    // with its (left-aligned) header title.
    cellLabel(tab, label.?, .{ .fixed = col }, if (col == .size) 1.0 else 0.0);
    c.gtk_box_append(@ptrCast(row_box), label);
}

/// Signal-closure variant of freeRowCtx (GClosureNotify shape).
pub fn freeRowCtxClosure(user: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
    _ = closure;
    freeRowCtx(user);
}

pub fn onExpandClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *RowCtx = @ptrCast(@alignCast(user.?));
    ctx.tab.view.toggleExpand(ctx.tab, ctx.path);
}

pub fn onSelectionChanged(_: *c.GtkListBox, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    if (tab.rendering) return;
    const a = tab.view.allocator;
    for (tab.selected.items) |p| a.free(p);
    tab.selected.clearRetainingCapacity();
    var rows = c.gtk_list_box_get_selected_rows(tab.listbox);
    const head = rows;
    while (rows != null) : (rows = rows.*.next) {
        const row: *c.GtkListBoxRow = @ptrCast(@alignCast(rows.*.data orelse continue));
        const data = c.g_object_get_data(@ptrCast(row), "sketerm-row") orelse continue;
        const ctx: *RowCtx = @ptrCast(@alignCast(data));
        const owned = a.dupe(u8, ctx.path) catch continue;
        tab.selected.append(a, owned) catch a.free(owned);
    }
    if (head != null) c.g_list_free(head);
    tab.view.updatePreview();
}

pub fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const data = c.g_object_get_data(@ptrCast(row), "sketerm-row") orelse return;
    const ctx: *RowCtx = @ptrCast(@alignCast(data));
    activateEntry(tab, ctx);
}

pub fn activateEntry(tab: *BTab, ctx: *RowCtx) void {
    const self = tab.view;
    if (tab.root.archive.len > 0) {
        if (!ctx.is_dir) {
            var mbuf: [4096]u8 = undefined;
            if (ctx.path.len >= mbuf.len) return;
            @memcpy(mbuf[0..ctx.path.len], ctx.path);
            self.extractAndOpenMember(tab, mbuf[0..ctx.path.len]);
        }
        return;
    }
    if (tab.root.collection) {
        // Collection rows hold host-qualified specs: open the
        // entry (dir) or its parent (file) in a NEW tab.
        const loc = parseSpec(ctx.path);
        var pbuf: [4096]u8 = undefined;
        const kind_dir = blk: {
            const i = tab.root.find(ctx.path) orelse break :blk false;
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
    if (ctx.is_dir) {
        // navigate() frees rows (and this ctx) — copy the path out.
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
        self.navigate(tab, host, path);
    } else if (tab.hc.host == null) {
        // Local file: default application, straight from disk.
        launchLocal(ctx.path);
    } else {
        // Remote file: download into the local open-cache, then
        // launch (phase-5's hydrating cache predecessor).
        self.openRemoteFile(tab, ctx.path, null);
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

pub fn onViewModeClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const tab = self.currentTab() orelse return;
    tab.view_mode = switch (tab.view_mode) {
        .details => .compact,
        .compact => .icons,
        .icons => .miller,
        .miller => .details,
    };
    self.setStatusFmt("view: {s}", .{@tagName(tab.view_mode)});
    views.rememberFolder(self, tab);
    self.renderTab(tab);
}

