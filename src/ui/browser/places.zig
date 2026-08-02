//! The places sidebar: bookmarks, recent locations, saved queries and
//! the daemon-reported devices, persisted through filebrowser/places.
//!
//! A saved query and a saved search are ONE record: the root spec plus
//! the query text as typed. Whether opening it subscribes (a live name
//! query) or scans once (a grep, a panel command) follows from the
//! text, so there is one list and one label rather than two mechanisms
//! for one concept.

const std = @import("std");
const c = @import("../../c.zig").c;
const places_mod = @import("../../filebrowser/places.zig");
const paths = @import("../../filebrowser/paths.zig");
const query_mod = @import("../../filebrowser/query.zig");

const BrowserView = @import("view.zig").BrowserView;
const trashFilesDir = @import("../../filebrowser/paths.zig").trashFilesDir;
const classicmenu = @import("classicmenu.zig");
const iconload = @import("iconload.zig");
const sidewidgets = @import("sidewidgets.zig");

/// Browser faces in this process. `authoritative` owns the one
/// process-wide places snapshot; registered views are synchronized to
/// it after every save so any later writer starts from current state.
const LiveView = struct {
    view: *BrowserView,
    /// False only when an allocation failure prevented synchronization.
    synced: bool = true,
};

var live_views: std.ArrayList(LiveView) = .empty;
var live_allocator: ?std.mem.Allocator = null;

const Authority = struct {
    arena: std.heap.ArenaAllocator,
    value: places_mod.Places,

    fn capture(self: *BrowserView) ?Authority {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const value = capturePlaces(self, arena.allocator()) catch {
            arena.deinit();
            return null;
        };
        return .{ .arena = arena, .value = value };
    }

    fn captureMerged(allocator: std.mem.Allocator, base: places_mod.Places, sources: MergeSources) ?Authority {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const value = captureMergedPlaces(base, sources, arena.allocator()) catch {
            arena.deinit();
            return null;
        };
        return .{ .arena = arena, .value = value };
    }

    fn deinit(self: *Authority) void {
        self.arena.deinit();
    }
};

var authoritative: ?Authority = null;

fn freeStrings(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
    list.* = .empty;
}

fn cloneStrings(allocator: std.mem.Allocator, source: anytype) ?std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    for (source) |item| {
        const owned = allocator.dupe(u8, item) catch {
            freeStrings(allocator, &out);
            return null;
        };
        out.append(allocator, owned) catch {
            allocator.free(owned);
            freeStrings(allocator, &out);
            return null;
        };
    }
    return out;
}

fn cloneConstStrings(allocator: std.mem.Allocator, source: anytype) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, source.len);
    for (source, 0..) |item, i| out[i] = try allocator.dupe(u8, item);
    return out;
}

/// Build an arena-owned snapshot of every field written to places.json.
fn capturePlaces(self: *BrowserView, allocator: std.mem.Allocator) !places_mod.Places {
    const bookmarks = try cloneConstStrings(allocator, self.bookmarks.items);
    const labels = try allocator.alloc([]const u8, bookmarks.len);
    const icons = try allocator.alloc([]const u8, bookmarks.len);
    for (bookmarks, 0..) |_, i| {
        labels[i] = try allocator.dupe(u8, if (i < self.bookmark_labels.items.len) self.bookmark_labels.items[i] else "");
        icons[i] = try allocator.dupe(u8, if (i < self.bookmark_icons.items.len) self.bookmark_icons.items[i] else "");
    }
    const recent = try cloneConstStrings(allocator, self.recent.items);
    const collapsed = try cloneConstStrings(allocator, self.collapsed.items);
    const hidden = try cloneConstStrings(allocator, self.hidden_sections.items);
    const order = try cloneConstStrings(allocator, self.section_order.items);

    const frecency = try allocator.alloc(places_mod.FrecEntry, self.frecency.items.len);
    for (self.frecency.items, 0..) |entry, i| {
        frecency[i] = .{
            .spec = try allocator.dupe(u8, entry.spec),
            .count = entry.count,
            .last_ms = entry.last_ms,
        };
    }
    const searches = try allocator.alloc(places_mod.SavedSearch, self.saved_searches.items.len);
    for (self.saved_searches.items, 0..) |search, i| {
        searches[i] = .{
            .spec = try allocator.dupe(u8, search.spec),
            .pattern = try allocator.dupe(u8, search.pattern),
            .content = search.content,
        };
    }
    const widget_sections = try allocator.alloc(places_mod.WidgetSection, self.widgets.sections.items.len);
    for (self.widgets.sections.items, 0..) |section, i| {
        const widgets = try allocator.alloc(places_mod.Widget, section.widgets.items.len);
        for (section.widgets.items, 0..) |widget, j| {
            widgets[j] = .{
                .kind = try allocator.dupe(u8, widget.kind.name()),
                .text = try allocator.dupe(u8, widget.text),
                .command = try allocator.dupe(u8, widget.command),
                .path = try allocator.dupe(u8, widget.path),
                .interval_secs = widget.interval_secs,
            };
        }
        widget_sections[i] = .{
            .name = try allocator.dupe(u8, section.name),
            .widgets = widgets,
        };
    }
    return .{
        .bookmarks = bookmarks,
        .bookmark_labels = labels,
        .bookmark_icons = icons,
        .recent = recent,
        .frecency = frecency,
        .searches = searches,
        .collection = &.{},
        .collapsed = collapsed,
        .hidden_sections = hidden,
        .section_order = order,
        .widget_sections = widget_sections,
        .sidebar_px = self.sidebar_px,
        .sidebar_open = self.sidebar_open,
        .zebra = self.zebra,
        .preview_px = self.preview_px,
        .side_info = self.side_info,
    };
}

fn stringsMatch(view_items: anytype, saved: []const []const u8) bool {
    if (view_items.len != saved.len) return false;
    for (view_items, saved) |view_item, saved_item| {
        if (!std.mem.eql(u8, view_item, saved_item)) return false;
    }
    return true;
}

fn bookmarksMatch(self: *BrowserView, saved: places_mod.Places) bool {
    if (!stringsMatch(self.bookmarks.items, saved.bookmarks)) return false;
    for (self.bookmarks.items, 0..) |_, i| {
        const view_label = if (i < self.bookmark_labels.items.len) self.bookmark_labels.items[i] else "";
        const saved_label = if (i < saved.bookmark_labels.len) saved.bookmark_labels[i] else "";
        if (!std.mem.eql(u8, view_label, saved_label)) return false;
        const view_icon = if (i < self.bookmark_icons.items.len) self.bookmark_icons.items[i] else "";
        const saved_icon = if (i < saved.bookmark_icons.len) saved.bookmark_icons[i] else "";
        if (!std.mem.eql(u8, view_icon, saved_icon)) return false;
    }
    return true;
}

fn frecencyMatches(self: *BrowserView, saved: places_mod.Places) bool {
    if (self.frecency.items.len != saved.frecency.len) return false;
    for (self.frecency.items, saved.frecency) |view_entry, saved_entry| {
        if (!std.mem.eql(u8, view_entry.spec, saved_entry.spec) or
            view_entry.count != saved_entry.count or
            view_entry.last_ms != saved_entry.last_ms) return false;
    }
    return true;
}

fn searchesMatch(self: *BrowserView, saved: places_mod.Places) bool {
    if (self.saved_searches.items.len != saved.searches.len) return false;
    for (self.saved_searches.items, saved.searches) |view_search, saved_search| {
        if (!std.mem.eql(u8, view_search.spec, saved_search.spec) or
            !std.mem.eql(u8, view_search.pattern, saved_search.pattern) or
            view_search.content != saved_search.content) return false;
    }
    return true;
}

fn widgetStoreMatches(store: *const sidewidgets.Store, saved: []const places_mod.WidgetSection) bool {
    if (store.sections.items.len != saved.len) return false;
    for (store.sections.items, saved) |view_section, saved_section| {
        if (!std.mem.eql(u8, view_section.name, saved_section.name) or
            view_section.widgets.items.len != saved_section.widgets.len) return false;
        for (view_section.widgets.items, saved_section.widgets) |view_widget, saved_widget| {
            if (!std.mem.eql(u8, view_widget.kind.name(), saved_widget.kind) or
                !std.mem.eql(u8, view_widget.text, saved_widget.text) or
                !std.mem.eql(u8, view_widget.command, saved_widget.command) or
                !std.mem.eql(u8, view_widget.path, saved_widget.path) or
                view_widget.interval_secs != saved_widget.interval_secs) return false;
        }
    }
    return true;
}

fn widgetsMatch(self: *BrowserView, saved: places_mod.Places) bool {
    return widgetStoreMatches(&self.widgets, saved.widget_sections);
}

/// Per-field providers whose local state differs from the previous
/// authoritative snapshot. Unrelated unsaved changes in another view
/// therefore join this save instead of being overwritten by it.
const MergeSources = struct {
    bookmarks: ?*BrowserView = null,
    recent: ?*BrowserView = null,
    frecency: ?*BrowserView = null,
    searches: ?*BrowserView = null,
    collapsed: ?*BrowserView = null,
    hidden_sections: ?*BrowserView = null,
    section_order: ?*BrowserView = null,
    widgets: ?*BrowserView = null,
    sidebar_px: ?*BrowserView = null,
    sidebar_open: ?*BrowserView = null,
    zebra: ?*BrowserView = null,
    preview_px: ?*BrowserView = null,
    side_info: ?*BrowserView = null,

    fn consider(self: *MergeSources, view: *BrowserView, base: places_mod.Places) void {
        if (!bookmarksMatch(view, base)) self.bookmarks = view;
        if (!stringsMatch(view.recent.items, base.recent)) self.recent = view;
        if (!frecencyMatches(view, base)) self.frecency = view;
        if (!searchesMatch(view, base)) self.searches = view;
        if (!stringsMatch(view.collapsed.items, base.collapsed)) self.collapsed = view;
        if (!stringsMatch(view.hidden_sections.items, base.hidden_sections)) self.hidden_sections = view;
        if (!stringsMatch(view.section_order.items, base.section_order)) self.section_order = view;
        if (!widgetsMatch(view, base)) self.widgets = view;
        if (view.sidebar_px != base.sidebar_px) self.sidebar_px = view;
        if (view.sidebar_open != base.sidebar_open) self.sidebar_open = view;
        if (view.zebra != base.zebra) self.zebra = view;
        if (view.preview_px != base.preview_px) self.preview_px = view;
        if (view.side_info != base.side_info) self.side_info = view;
    }
};

fn captureMergedPlaces(base: places_mod.Places, sources: MergeSources, allocator: std.mem.Allocator) !places_mod.Places {
    const bookmarks = if (sources.bookmarks) |view|
        try cloneConstStrings(allocator, view.bookmarks.items)
    else
        try cloneConstStrings(allocator, base.bookmarks);
    const labels = try allocator.alloc([]const u8, bookmarks.len);
    const icons = try allocator.alloc([]const u8, bookmarks.len);
    for (bookmarks, 0..) |_, i| {
        if (sources.bookmarks) |view| {
            labels[i] = try allocator.dupe(u8, if (i < view.bookmark_labels.items.len) view.bookmark_labels.items[i] else "");
            icons[i] = try allocator.dupe(u8, if (i < view.bookmark_icons.items.len) view.bookmark_icons.items[i] else "");
        } else {
            labels[i] = try allocator.dupe(u8, if (i < base.bookmark_labels.len) base.bookmark_labels[i] else "");
            icons[i] = try allocator.dupe(u8, if (i < base.bookmark_icons.len) base.bookmark_icons[i] else "");
        }
    }

    const recent = if (sources.recent) |view|
        try cloneConstStrings(allocator, view.recent.items)
    else
        try cloneConstStrings(allocator, base.recent);
    const collapsed = if (sources.collapsed) |view|
        try cloneConstStrings(allocator, view.collapsed.items)
    else
        try cloneConstStrings(allocator, base.collapsed);
    const hidden_sections = if (sources.hidden_sections) |view|
        try cloneConstStrings(allocator, view.hidden_sections.items)
    else
        try cloneConstStrings(allocator, base.hidden_sections);
    const section_order = if (sources.section_order) |view|
        try cloneConstStrings(allocator, view.section_order.items)
    else
        try cloneConstStrings(allocator, base.section_order);

    const frecency_len = if (sources.frecency) |view| view.frecency.items.len else base.frecency.len;
    const frecency = try allocator.alloc(places_mod.FrecEntry, frecency_len);
    if (sources.frecency) |view| {
        for (view.frecency.items, 0..) |entry, i| {
            frecency[i] = .{ .spec = try allocator.dupe(u8, entry.spec), .count = entry.count, .last_ms = entry.last_ms };
        }
    } else {
        for (base.frecency, 0..) |entry, i| {
            frecency[i] = .{ .spec = try allocator.dupe(u8, entry.spec), .count = entry.count, .last_ms = entry.last_ms };
        }
    }

    const searches_len = if (sources.searches) |view| view.saved_searches.items.len else base.searches.len;
    const searches = try allocator.alloc(places_mod.SavedSearch, searches_len);
    if (sources.searches) |view| {
        for (view.saved_searches.items, 0..) |search, i| {
            searches[i] = .{
                .spec = try allocator.dupe(u8, search.spec),
                .pattern = try allocator.dupe(u8, search.pattern),
                .content = search.content,
            };
        }
    } else {
        for (base.searches, 0..) |search, i| {
            searches[i] = .{
                .spec = try allocator.dupe(u8, search.spec),
                .pattern = try allocator.dupe(u8, search.pattern),
                .content = search.content,
            };
        }
    }

    const widget_len = if (sources.widgets) |view| view.widgets.sections.items.len else base.widget_sections.len;
    const widget_sections = try allocator.alloc(places_mod.WidgetSection, widget_len);
    if (sources.widgets) |view| {
        for (view.widgets.sections.items, 0..) |section, i| {
            const widgets = try allocator.alloc(places_mod.Widget, section.widgets.items.len);
            for (section.widgets.items, 0..) |widget, j| {
                widgets[j] = .{
                    .kind = try allocator.dupe(u8, widget.kind.name()),
                    .text = try allocator.dupe(u8, widget.text),
                    .command = try allocator.dupe(u8, widget.command),
                    .path = try allocator.dupe(u8, widget.path),
                    .interval_secs = widget.interval_secs,
                };
            }
            widget_sections[i] = .{ .name = try allocator.dupe(u8, section.name), .widgets = widgets };
        }
    } else {
        for (base.widget_sections, 0..) |section, i| {
            const widgets = try allocator.alloc(places_mod.Widget, section.widgets.len);
            for (section.widgets, 0..) |widget, j| {
                widgets[j] = .{
                    .kind = try allocator.dupe(u8, widget.kind),
                    .text = try allocator.dupe(u8, widget.text),
                    .command = try allocator.dupe(u8, widget.command),
                    .path = try allocator.dupe(u8, widget.path),
                    .interval_secs = widget.interval_secs,
                };
            }
            widget_sections[i] = .{ .name = try allocator.dupe(u8, section.name), .widgets = widgets };
        }
    }

    return .{
        .bookmarks = bookmarks,
        .bookmark_labels = labels,
        .bookmark_icons = icons,
        .recent = recent,
        .frecency = frecency,
        .searches = searches,
        .collection = &.{},
        .collapsed = collapsed,
        .hidden_sections = hidden_sections,
        .section_order = section_order,
        .widget_sections = widget_sections,
        .sidebar_px = if (sources.sidebar_px) |view| view.sidebar_px else base.sidebar_px,
        .sidebar_open = if (sources.sidebar_open) |view| view.sidebar_open else base.sidebar_open,
        .zebra = if (sources.zebra) |view| view.zebra else base.zebra,
        .preview_px = if (sources.preview_px) |view| view.preview_px else base.preview_px,
        .side_info = if (sources.side_info) |view| view.side_info else base.side_info,
    };
}

/// Owned replacement for one view's persisted fields, built before
/// its current state is released so synchronization is transactional.
const PersistedState = struct {
    bookmarks: std.ArrayList([]u8) = .empty,
    bookmark_labels: std.ArrayList([]u8) = .empty,
    bookmark_icons: std.ArrayList([]u8) = .empty,
    recent: std.ArrayList([]u8) = .empty,
    frecency: std.ArrayList(places_mod.FrecOwned) = .empty,
    collapsed: std.ArrayList([]u8) = .empty,
    hidden_sections: std.ArrayList([]u8) = .empty,
    section_order: std.ArrayList([]u8) = .empty,
    widgets: sidewidgets.Store = .{},
    searches: std.ArrayList(@import("types.zig").OwnedSearch) = .empty,
    sidebar_px: i32 = places_mod.DEFAULT_SIDEBAR_PX,
    sidebar_open: ?bool = null,
    zebra: bool = false,
    preview_px: i32 = 300,
    side_info: bool = false,

    fn init(allocator: std.mem.Allocator, places: places_mod.Places) ?PersistedState {
        var out: PersistedState = .{};
        out.bookmarks = cloneStrings(allocator, places.bookmarks) orelse return null;
        out.bookmark_labels = cloneStrings(allocator, places.bookmark_labels) orelse {
            out.deinit(allocator);
            return null;
        };
        out.bookmark_icons = cloneStrings(allocator, places.bookmark_icons) orelse {
            out.deinit(allocator);
            return null;
        };
        out.recent = cloneStrings(allocator, places.recent) orelse {
            out.deinit(allocator);
            return null;
        };
        out.collapsed = cloneStrings(allocator, places.collapsed) orelse {
            out.deinit(allocator);
            return null;
        };
        out.hidden_sections = cloneStrings(allocator, places.hidden_sections) orelse {
            out.deinit(allocator);
            return null;
        };
        out.section_order = cloneStrings(allocator, places.section_order) orelse {
            out.deinit(allocator);
            return null;
        };
        for (places.frecency) |entry| {
            const spec = allocator.dupe(u8, entry.spec) catch {
                out.deinit(allocator);
                return null;
            };
            out.frecency.append(allocator, .{ .spec = spec, .count = entry.count, .last_ms = entry.last_ms }) catch {
                allocator.free(spec);
                out.deinit(allocator);
                return null;
            };
        }
        for (places.searches) |search| {
            const spec = allocator.dupe(u8, search.spec) catch {
                out.deinit(allocator);
                return null;
            };
            const pattern = allocator.dupe(u8, search.pattern) catch {
                allocator.free(spec);
                out.deinit(allocator);
                return null;
            };
            out.searches.append(allocator, .{ .spec = spec, .pattern = pattern, .content = search.content }) catch {
                allocator.free(spec);
                allocator.free(pattern);
                out.deinit(allocator);
                return null;
            };
        }
        out.widgets.loadFrom(allocator, places.widget_sections);
        if (!widgetStoreMatches(&out.widgets, places.widget_sections)) {
            out.deinit(allocator);
            return null;
        }
        out.sidebar_px = places_mod.clampSidebarPx(places.sidebar_px);
        out.sidebar_open = places.sidebar_open;
        out.zebra = places.zebra;
        out.preview_px = std.math.clamp(places.preview_px, 220, 700);
        out.side_info = places.side_info;
        return out;
    }

    fn deinit(self: *PersistedState, allocator: std.mem.Allocator) void {
        freeStrings(allocator, &self.bookmarks);
        freeStrings(allocator, &self.bookmark_labels);
        freeStrings(allocator, &self.bookmark_icons);
        freeStrings(allocator, &self.recent);
        for (self.frecency.items) |entry| allocator.free(entry.spec);
        self.frecency.deinit(allocator);
        self.frecency = .empty;
        freeStrings(allocator, &self.collapsed);
        freeStrings(allocator, &self.hidden_sections);
        freeStrings(allocator, &self.section_order);
        self.widgets.deinit(allocator);
        self.widgets = .{};
        for (self.searches.items) |search| search.deinitOwned(allocator);
        self.searches.deinit(allocator);
        self.searches = .empty;
    }

    fn install(self: *PersistedState, view: *BrowserView, places: places_mod.Places) void {
        const allocator = view.allocator;
        if (!bookmarksMatch(view, places)) {
            freeStrings(allocator, &view.bookmarks);
            freeStrings(allocator, &view.bookmark_labels);
            freeStrings(allocator, &view.bookmark_icons);
            view.bookmarks = self.bookmarks;
            self.bookmarks = .empty;
            view.bookmark_labels = self.bookmark_labels;
            self.bookmark_labels = .empty;
            view.bookmark_icons = self.bookmark_icons;
            self.bookmark_icons = .empty;
        }
        if (!stringsMatch(view.recent.items, places.recent)) {
            freeStrings(allocator, &view.recent);
            view.recent = self.recent;
            self.recent = .empty;
        }
        if (!frecencyMatches(view, places)) {
            for (view.frecency.items) |entry| allocator.free(entry.spec);
            view.frecency.deinit(allocator);
            view.frecency = self.frecency;
            self.frecency = .empty;
        }
        if (!stringsMatch(view.collapsed.items, places.collapsed)) {
            freeStrings(allocator, &view.collapsed);
            view.collapsed = self.collapsed;
            self.collapsed = .empty;
        }
        if (!stringsMatch(view.hidden_sections.items, places.hidden_sections)) {
            freeStrings(allocator, &view.hidden_sections);
            view.hidden_sections = self.hidden_sections;
            self.hidden_sections = .empty;
        }
        if (!stringsMatch(view.section_order.items, places.section_order)) {
            freeStrings(allocator, &view.section_order);
            view.section_order = self.section_order;
            self.section_order = .empty;
        }
        if (!widgetsMatch(view, places)) {
            sidewidgets.resetRuns(view);
            view.widgets.deinit(allocator);
            view.widgets = self.widgets;
            self.widgets = .{};
        }
        if (!searchesMatch(view, places)) {
            for (view.saved_searches.items) |search| search.deinitOwned(allocator);
            view.saved_searches.deinit(allocator);
            view.saved_searches = self.searches;
            self.searches = .empty;
        }
        view.sidebar_px = self.sidebar_px;
        view.sidebar_open = self.sidebar_open;
        view.zebra = self.zebra;
        view.preview_px = self.preview_px;
        view.side_info = self.side_info;
    }
};

fn syncView(view: *BrowserView, places: places_mod.Places) bool {
    var state = PersistedState.init(view.allocator, places) orelse return false;
    defer state.deinit(view.allocator);
    state.install(view, places);
    return true;
}

fn registeredIndex(self: *BrowserView) ?usize {
    for (live_views.items, 0..) |entry, i| if (entry.view == self) return i;
    return null;
}

pub fn registerView(self: *BrowserView) void {
    if (registeredIndex(self) != null) return;
    if (authoritative) |*current| {
        if (!syncView(self, current.value)) return;
    } else {
        authoritative = Authority.capture(self) orelse return;
    }
    const allocator = live_allocator orelse self.allocator;
    live_allocator = allocator;
    live_views.append(allocator, .{ .view = self }) catch {
        if (live_views.items.len == 0) {
            if (authoritative) |*current| current.deinit();
            authoritative = null;
            live_allocator = null;
        }
    };
}

pub fn unregisterView(self: *BrowserView) void {
    for (live_views.items, 0..) |entry, i| {
        if (entry.view != self) continue;
        _ = live_views.orderedRemove(i);
        if (live_views.items.len == 0) {
            live_views.deinit(live_allocator orelse self.allocator);
            live_views = .empty;
            live_allocator = null;
            if (authoritative) |*current| current.deinit();
            authoritative = null;
        }
        return;
    }
}

/// Publish a bookmark mutation through the full places snapshot.
fn bookmarksChanged(self: *BrowserView) void {
    self.savePlaces();
    if (self.places_on and !self.widgets_dead) self.renderPlaces();
}

/// Heap ctx on each places row (freed with the row).
pub const PlaceCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    /// Host-qualified location spec; empty = section header.
    spec: []u8,
    is_bookmark: bool,

    pub fn free(user: ?*anyopaque) callconv(.c) void {
        const p: *PlaceCtx = @ptrCast(@alignCast(user.?));
        p.allocator.free(p.spec);
        p.allocator.destroy(p);
    }
};

pub fn onPlacesToggled(btn: *c.GtkToggleButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.places_on = c.gtk_toggle_button_get_active(btn) != 0;
    c.gtk_widget_set_visible(self.places_box, @intFromBool(self.places_on));
    if (self.places_on) {
        // The splitter forgets a position set while its start child
        // was hidden; re-assert the saved width as it comes back.
        c.gtk_paned_set_position(@ptrCast(self.content_paned), self.sidebar_px);
        self.renderPlaces();
    }
    // Only a real toggle is a preference: the one applyChromeState
    // performs at startup IS the stored state.
    if (self.chrome_ready) {
        self.sidebar_open = self.places_on;
        self.savePlaces();
    }
}

/// True when the user folded `name` shut. Unknown sections are open,
/// so a places.json written before this existed reads as all-expanded.
pub fn sectionCollapsed(self: *BrowserView, name: []const u8) bool {
    for (self.collapsed.items) |s| {
        if (std.mem.eql(u8, s, name)) return true;
        // The top section used to be called "Places"; a fold saved
        // under the old name keeps working.
        if (std.mem.eql(u8, name, "Local Places") and std.mem.eql(u8, s, "Places")) return true;
    }
    return false;
}

/// "user@box" / "udp:box" as a section title: the bare host name,
/// first letter upcased ("Archdev Places").
pub fn hostSectionTitle(host: []const u8, buf: []u8) []const u8 {
    var name = host;
    if (std.mem.lastIndexOfScalar(u8, name, '@')) |at| name = name[at + 1 ..];
    if (std.mem.startsWith(u8, name, "udp:")) name = name["udp:".len..];
    if (std.mem.startsWith(u8, name, "ssh:")) name = name["ssh:".len..];
    if (name.len == 0) name = host;
    const text = std.fmt.bufPrint(buf, "{s} Places", .{name}) catch return "Remote Places";
    if (text.len > 0) text[0] = std.ascii.toUpper(text[0]);
    return text;
}

/// True when the user hid section `key` from the sidebar entirely
/// (distinct from folding: a hidden section has no header at all).
pub fn sectionHidden(self: *BrowserView, key: []const u8) bool {
    for (self.hidden_sections.items) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

/// Flip section `key` between hidden and shown, persist, re-render.
pub fn toggleSectionHidden(self: *BrowserView, key: []const u8) void {
    for (self.hidden_sections.items, 0..) |k, i| {
        if (!std.mem.eql(u8, k, key)) continue;
        self.allocator.free(k);
        _ = self.hidden_sections.orderedRemove(i);
        self.savePlaces();
        self.renderPlaces();
        return;
    }
    const owned = self.allocator.dupe(u8, key) catch return;
    self.hidden_sections.append(self.allocator, owned) catch {
        self.allocator.free(owned);
        return;
    };
    self.savePlaces();
    self.renderPlaces();
}

/// Every section key that currently exists, in DEFAULT order: the
/// built-ins, then the user widget sections. Arena-allocated widget
/// keys ("widgets:<name>").
fn allSectionKeys(self: *BrowserView, arena: std.mem.Allocator) [][]const u8 {
    const n = places_mod.builtin_sections.len + self.widgets.sections.items.len;
    const keys = arena.alloc([]const u8, n) catch return &.{};
    for (places_mod.builtin_sections, 0..) |def, i| keys[i] = def.key;
    for (self.widgets.sections.items, 0..) |sec, i| {
        keys[places_mod.builtin_sections.len + i] =
            std.fmt.allocPrint(arena, "{s}{s}", .{ places_mod.WIDGET_KEY_PREFIX, sec.name }) catch "";
    }
    return keys;
}

/// Display title for a section key (widget sections show their name).
pub fn sectionTitleForKey(key: []const u8) []const u8 {
    for (places_mod.builtin_sections) |def| {
        if (std.mem.eql(u8, def.key, key)) return def.title;
    }
    if (std.mem.startsWith(u8, key, places_mod.WIDGET_KEY_PREFIX))
        return key[places_mod.WIDGET_KEY_PREFIX.len..];
    return key;
}

/// The section KEY a header row's title belongs to. Built-ins win over
/// a widget section that shadows their title.
fn sectionKeyForTitle(self: *BrowserView, title: []const u8, buf: []u8) ?[]const u8 {
    for (places_mod.builtin_sections) |def| {
        if (std.mem.eql(u8, def.title, title)) return def.key;
    }
    // Host sections ("Archdev Places") all belong to the one
    // "remote" slot.
    if (std.mem.endsWith(u8, title, " Places")) return "remote";
    if (self.widgets.sectionByName(title) != null)
        return std.fmt.bufPrint(buf, "{s}{s}", .{ places_mod.WIDGET_KEY_PREFIX, title }) catch null;
    return null;
}

/// Move section `key` one slot up or down in the persisted order.
/// The stored order is first normalized to the full current key list
/// so a partial saved order moves predictably.
pub fn moveSection(self: *BrowserView, key: []const u8, up: bool) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = allSectionKeys(self, a);
    const saved = a.alloc([]const u8, self.section_order.items.len) catch return;
    for (self.section_order.items, 0..) |s, i| saved[i] = s;
    const ordered = places_mod.orderSections(a, saved, all) catch return;
    const mut = a.dupe([]const u8, ordered) catch return;
    var idx: ?usize = null;
    for (mut, 0..) |k, i| {
        if (std.mem.eql(u8, k, key)) idx = i;
    }
    const i = idx orelse return;
    if (up) {
        if (i == 0) return;
        std.mem.swap([]const u8, &mut[i], &mut[i - 1]);
    } else {
        if (i + 1 >= mut.len) return;
        std.mem.swap([]const u8, &mut[i], &mut[i + 1]);
    }
    for (self.section_order.items) |s| self.allocator.free(s);
    self.section_order.clearRetainingCapacity();
    for (mut) |k| {
        const owned = self.allocator.dupe(u8, k) catch continue;
        self.section_order.append(self.allocator, owned) catch self.allocator.free(owned);
    }
    self.savePlaces();
    self.renderPlaces();
}

/// Fold a section open or shut and persist it. The caller re-renders:
/// the whole list is rebuilt on every change anyway, so collapsing is
/// "leave the member rows out this time" rather than widget surgery.
fn toggleSection(self: *BrowserView, name: []const u8) void {
    for (self.collapsed.items, 0..) |s, i| {
        if (!std.mem.eql(u8, s, name)) continue;
        self.allocator.free(s);
        _ = self.collapsed.orderedRemove(i);
        return;
    }
    const owned = self.allocator.dupe(u8, name) catch return;
    self.collapsed.append(self.allocator, owned) catch self.allocator.free(owned);
}

/// A section header row. It is activatable -- but as a fold control,
/// not as a place: its ctx spec is "section:<text>", which
/// onPlaceActivated routes to the fold before any navigation.
pub fn placeHeader(self: *BrowserView, text: [*:0]const u8) void {
    const name = std.mem.span(text);
    const folded = sectionCollapsed(self, name);
    const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
    c.gtk_widget_add_css_class(hbox, "sketerm-fb-section");
    c.gtk_widget_set_margin_top(hbox, 8);
    c.gtk_widget_set_margin_start(hbox, 4);
    const arrow = c.gtk_image_new_from_icon_name(if (folded) "pan-end-symbolic" else "pan-down-symbolic");
    c.gtk_box_append(@ptrCast(hbox), arrow);
    const lab = c.gtk_label_new(text);
    c.gtk_label_set_xalign(@ptrCast(lab), 0);
    c.gtk_widget_add_css_class(lab, "dim-label");
    c.gtk_widget_set_hexpand(lab, 1);
    c.gtk_box_append(@ptrCast(hbox), lab);

    const ctx = self.allocator.create(PlaceCtx) catch return;
    var spec_buf: [128]u8 = undefined;
    const spec = std.fmt.bufPrint(&spec_buf, "section:{s}", .{name}) catch {
        self.allocator.destroy(ctx);
        return;
    };
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .spec = self.allocator.dupe(u8, spec) catch {
            self.allocator.destroy(ctx);
            return;
        },
        .is_bookmark = false,
    };
    const row = c.gtk_list_box_row_new();
    c.gtk_list_box_row_set_child(@ptrCast(row), hbox);
    c.gtk_widget_set_tooltip_text(@ptrCast(row), if (folded) "Show this section" else "Hide this section");
    c.g_object_set_data_full(@ptrCast(row), "sketerm-place", @ptrCast(ctx), @ptrCast(&PlaceCtx.free));
    c.gtk_list_box_append(self.places_list, row);
}

fn makePlaceCtx(self: *BrowserView, spec: []const u8, is_bookmark: bool) ?*PlaceCtx {
    const ctx = self.allocator.create(PlaceCtx) catch return null;
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .spec = self.allocator.dupe(u8, spec) catch {
            self.allocator.destroy(ctx);
            return null;
        },
        .is_bookmark = is_bookmark,
    };
    return ctx;
}

fn appendPlaceRow(self: *BrowserView, hbox: *c.GtkWidget, ctx: *PlaceCtx) void {
    const row = c.gtk_list_box_row_new();
    c.gtk_list_box_row_set_child(@ptrCast(row), hbox);
    var tip: [4300:0]u8 = undefined;
    if (std.fmt.bufPrintZ(&tip, "{s}", .{ctx.spec})) |t| c.gtk_widget_set_tooltip_text(@ptrCast(row), t.ptr) else |_| {}
    c.g_object_set_data_full(@ptrCast(row), "sketerm-place", @ptrCast(ctx), @ptrCast(&PlaceCtx.free));
    c.gtk_list_box_append(self.places_list, row);
}

/// A recent-location row. The label is not the raw spec: the folder
/// name reads plainly and the path leading to it is dimmed, so a
/// column of recents scans as names rather than as repeated prefixes.
/// Activation still uses the raw spec.
fn recentRow(self: *BrowserView, spec: []const u8) void {
    const loc = paths.parseSpec(spec);
    if (loc.host) |host| {
        const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        c.gtk_widget_set_margin_start(hbox, 10);
        c.gtk_widget_set_margin_end(hbox, 10);
        c.gtk_box_append(@ptrCast(hbox), iconload.newImageIcon(@ptrCast(@alignCast(self.places_list)), "document-open-recent-symbolic", 16));
        var hz: [260:0]u8 = undefined;
        const host_text = std.fmt.bufPrintZ(&hz, "{s}:", .{host}) catch return;
        const host_label = c.gtk_label_new(host_text.ptr);
        c.gtk_widget_add_css_class(host_label, "dim-label");
        c.gtk_box_append(@ptrCast(hbox), host_label);
        var pz: [4096:0]u8 = undefined;
        const n = @min(loc.path.len, pz.len - 1);
        @memcpy(pz[0..n], loc.path[0..n]);
        pz[n] = 0;
        const path_label = c.gtk_label_new(&pz);
        c.gtk_label_set_xalign(@ptrCast(path_label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(path_label), c.PANGO_ELLIPSIZE_START);
        c.gtk_widget_set_hexpand(path_label, 1);
        c.gtk_box_append(@ptrCast(hbox), path_label);
        appendPlaceRow(self, hbox, makePlaceCtx(self, spec, false) orelse return);
        return;
    }
    const split = places_mod.splitRecentLabel(spec);
    var pz: [1024:0]u8 = undefined;
    var nz: [512:0]u8 = undefined;
    const pn = @min(split.parent.len, pz.len - 1);
    @memcpy(pz[0..pn], split.parent[0..pn]);
    pz[pn] = 0;
    const nn = @min(split.name.len, nz.len - 1);
    @memcpy(nz[0..nn], split.name[0..nn]);
    nz[nn] = 0;
    // Paths may contain &, < and >; Pango would reject the markup.
    const esc_parent = c.g_markup_escape_text(&pz, -1) orelse return;
    defer c.g_free(@ptrCast(esc_parent));
    const esc_name = c.g_markup_escape_text(&nz, -1) orelse return;
    defer c.g_free(@ptrCast(esc_name));
    var markup: [3072:0]u8 = undefined;
    const m = std.fmt.bufPrintZ(&markup, "<span alpha=\"55%\">{s}</span>{s}", .{
        std.mem.span(@as([*:0]const u8, @ptrCast(esc_parent))),
        std.mem.span(@as([*:0]const u8, @ptrCast(esc_name))),
    }) catch return;
    placeRowMarkup(self, "document-open-recent-symbolic", m.ptr, spec);
}

/// A places row whose label is Pango markup. The caller escapes.
fn placeRowMarkup(self: *BrowserView, icon: [*:0]const u8, markup: [*:0]const u8, spec: []const u8) void {
    const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    c.gtk_widget_set_margin_start(hbox, 10);
    c.gtk_widget_set_margin_end(hbox, 10);
    c.gtk_box_append(@ptrCast(hbox), iconload.newImageIcon(@ptrCast(@alignCast(self.places_list)), icon, 16));
    const lab = c.gtk_label_new(null);
    c.gtk_label_set_markup(@ptrCast(lab), markup);
    c.gtk_label_set_xalign(@ptrCast(lab), 0);
    c.gtk_label_set_ellipsize(@ptrCast(lab), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_widget_set_hexpand(lab, 1);
    c.gtk_box_append(@ptrCast(hbox), lab);
    appendPlaceRow(self, hbox, makePlaceCtx(self, spec, false) orelse return);
}

pub fn placeRow(self: *BrowserView, icon: [*:0]const u8, label: []const u8, spec: []const u8, is_bookmark: bool) void {
    const img = iconload.newImageIcon(@ptrCast(@alignCast(self.places_list)), icon, 16);
    placeRowWithIcon(self, img, label, spec, is_bookmark);
}

/// A places row whose icon widget the caller already built (custom
/// bookmark icons: image files and emoji are not themed icon names).
fn placeRowWithIcon(self: *BrowserView, icon_widget: *c.GtkWidget, label: []const u8, spec: []const u8, is_bookmark: bool) void {
    const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    c.gtk_widget_set_margin_start(hbox, 10);
    c.gtk_box_append(@ptrCast(hbox), icon_widget);
    var lz: [256:0]u8 = undefined;
    const n = @min(label.len, lz.len - 1);
    @memcpy(lz[0..n], label[0..n]);
    lz[n] = 0;
    const lab = c.gtk_label_new(&lz);
    c.gtk_label_set_xalign(@ptrCast(lab), 0);
    c.gtk_label_set_ellipsize(@ptrCast(lab), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_widget_set_hexpand(lab, 1);
    c.gtk_box_append(@ptrCast(hbox), lab);
    const ctx = makePlaceCtx(self, spec, is_bookmark) orelse return;
    appendPlaceRow(self, hbox, ctx);
}

const DEFAULT_BOOKMARK_ICON = "starred-symbolic";

/// Resolve a bookmark's icon value into a 16px widget: "" = the
/// default star, "/..." = an image file (broken file falls back),
/// a leading non-ASCII codepoint = emoji rendered as a label, and
/// anything else a themed icon name.
fn bookmarkIconWidget(self: *BrowserView, icon: []const u8) *c.GtkWidget {
    const anchor: *c.GtkWidget = @ptrCast(@alignCast(self.places_list));
    if (icon.len == 0) return iconload.newImageIcon(anchor, DEFAULT_BOOKMARK_ICON, 16);
    if (icon[0] == '/') {
        var pz: [4096:0]u8 = undefined;
        if (icon.len < pz.len) {
            @memcpy(pz[0..icon.len], icon);
            pz[icon.len] = 0;
            if (c.gdk_pixbuf_new_from_file_at_size(&pz, 16, 16, null)) |pb| {
                defer c.g_object_unref(@as(?*anyopaque, @ptrCast(pb)));
                if (c.gdk_texture_new_for_pixbuf(pb)) |tex| {
                    defer c.g_object_unref(@as(?*anyopaque, @ptrCast(tex)));
                    const img = c.gtk_image_new_from_paintable(@ptrCast(tex));
                    c.gtk_image_set_pixel_size(@ptrCast(@alignCast(img)), 16);
                    return img;
                }
            }
        }
        return iconload.newImageIcon(anchor, DEFAULT_BOOKMARK_ICON, 16);
    }
    if (icon[0] >= 0x80) {
        // Emoji (or any non-ASCII text): a plain label, no markup.
        var z: [64:0]u8 = undefined;
        const n = @min(icon.len, z.len - 1);
        @memcpy(z[0..n], icon[0..n]);
        z[n] = 0;
        const lab = c.gtk_label_new(&z);
        c.gtk_widget_set_size_request(lab, 16, -1);
        return lab;
    }
    var z: [128:0]u8 = undefined;
    const n = @min(icon.len, z.len - 1);
    @memcpy(z[0..n], icon[0..n]);
    z[n] = 0;
    return iconload.newImageIcon(anchor, &z, 16);
}

pub fn renderPlaces(self: *BrowserView) void {
    while (c.gtk_list_box_get_row_at_index(self.places_list, 0)) |row| {
        c.gtk_list_box_remove(self.places_list, @ptrCast(row));
    }
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = allSectionKeys(self, a);
    const saved = a.alloc([]const u8, self.section_order.items.len) catch return;
    for (self.section_order.items, 0..) |s, i| saved[i] = s;
    const ordered = places_mod.orderSections(a, saved, all) catch all;
    for (ordered) |key| {
        if (sectionHidden(self, key)) continue;
        if (std.mem.eql(u8, key, "local")) {
            renderLocalSection(self);
        } else if (std.mem.eql(u8, key, "remote")) {
            renderRemoteSection(self);
        } else if (std.mem.eql(u8, key, "registers")) {
            renderRegistersSection(self);
        } else if (std.mem.eql(u8, key, "bookmarks")) {
            renderBookmarksSection(self);
        } else if (std.mem.eql(u8, key, "searches")) {
            renderSearchesSection(self);
        } else if (std.mem.eql(u8, key, "recent")) {
            renderRecentSection(self);
        } else if (std.mem.eql(u8, key, "devices")) {
            renderDevicesSection(self);
        } else if (std.mem.startsWith(u8, key, places_mod.WIDGET_KEY_PREFIX)) {
            const name = key[places_mod.WIDGET_KEY_PREFIX.len..];
            if (self.widgets.sectionByName(name)) |sec|
                sidewidgets.renderSection(self, sec);
        }
    }
}

/// Always the LOCAL machine, whatever host the current tab shows:
/// specs are "local:"-qualified so a click can never resolve against
/// the remote tab's host.
fn renderLocalSection(self: *BrowserView) void {
    self.placeHeader("Local Places");
    if (sectionCollapsed(self, "Local Places")) return;
    const home = if (c.getenv("HOME")) |h| std.mem.span(@as([*:0]const u8, @ptrCast(h))) else "/";
    var home_spec_buf: [4200]u8 = undefined;
    if (std.fmt.bufPrint(&home_spec_buf, "local:{s}", .{home})) |hs|
        self.placeRow("user-home-symbolic", "Home", hs, false)
    else |_|
        self.placeRow("user-home-symbolic", "Home", home, false);
    self.placeRow("drive-harddisk-symbolic", "File System", "local:/", false);
    var trash_buf: [4200]u8 = undefined;
    if (trashFilesDir(&trash_buf)) |td| self.placeRow("user-trash-symbolic", "Trash", td, false);
}

/// Browsing another machine adds ITS places under its own name — the
/// two systems are never conflated in one section.
fn renderRemoteSection(self: *BrowserView) void {
    const tab = self.currentTab() orelse return;
    const host = tab.hc.host orelse return;
    var title_buf: [160]u8 = undefined;
    var title_z: [160:0]u8 = undefined;
    const title = hostSectionTitle(host, &title_buf);
    const tn = @min(title.len, title_z.len - 1);
    @memcpy(title_z[0..tn], title[0..tn]);
    title_z[tn] = 0;
    self.placeHeader(&title_z);
    if (sectionCollapsed(self, title_z[0..tn])) return;
    var spec_buf: [4600]u8 = undefined;
    if (tab.hc.home_dir) |hd| {
        if (std.fmt.bufPrint(&spec_buf, "{s}:{s}", .{ host, hd })) |hs|
            self.placeRow("user-home-symbolic", "Home", hs, false)
        else |_| {}
    }
    if (std.fmt.bufPrint(&spec_buf, "{s}:/", .{host})) |rs|
        self.placeRow("drive-harddisk-symbolic", "File System", rs, false)
    else |_| {}
}

fn renderRegistersSection(self: *BrowserView) void {
    const store = self.regStore();
    if (store.count() == 0) return;
    self.placeHeader("Registers");
    var ri: usize = if (sectionCollapsed(self, "Registers")) store.count() else 0;
    while (ri < store.count()) : (ri += 1) {
        const name = store.nameAt(ri);
        var lbl: [160]u8 = undefined;
        const ltxt = std.fmt.bufPrint(&lbl, "{s} ({d})", .{ name, store.sizeOf(name) }) catch name;
        var spec_buf: [80]u8 = undefined;
        const rspec = std.fmt.bufPrint(&spec_buf, "register:{s}", .{name}) catch continue;
        self.placeRow("folder-saved-search-symbolic", ltxt, rspec, false);
    }
}

fn renderBookmarksSection(self: *BrowserView) void {
    if (self.bookmarks.items.len == 0) return;
    self.placeHeader("Bookmarks");
    if (sectionCollapsed(self, "Bookmarks")) return;
    for (self.bookmarks.items, 0..) |b, i| {
        const label = bookmarkLabelAt(self, i) orelse std.fs.path.basename(b);
        const img = bookmarkIconWidget(self, bookmarkIconAt(self, i));
        placeRowWithIcon(self, img, label, b, true);
    }
}

fn renderSearchesSection(self: *BrowserView) void {
    if (self.saved_searches.items.len == 0) return;
    self.placeHeader("Saved Queries");
    if (sectionCollapsed(self, "Saved Queries")) return;
    for (self.saved_searches.items, 0..) |sq, i| {
        // A saved query is durable, not a stored mode: what it is
        // follows from its own text, resolved here so the label
        // and the run can never disagree.
        const q = query_mod.parse(sq.pattern, sq.content);
        // Kind first: the row ellipsizes in the MIDDLE, so what a
        // query is has to sit where the ellipsis cannot eat it.
        var lbl: [300]u8 = undefined;
        const ltxt = std.fmt.bufPrint(&lbl, "[{s}] {s} in {s}", .{
            if (q) |v| v.kindLabel() else "empty",
            sq.pattern,
            sq.spec,
        }) catch sq.pattern;
        // Encode the index as "search:<i>" — rows resolve it
        // at click time so edits do not dangle.
        var spec_buf: [32]u8 = undefined;
        const sspec = std.fmt.bufPrint(&spec_buf, "search:{d}", .{i}) catch continue;
        const icon: [*:0]const u8 = if (q != null and q.?.live())
            "folder-saved-search-symbolic"
        else
            "system-search-symbolic";
        self.placeRow(icon, ltxt, sspec, true);
    }
}

fn renderRecentSection(self: *BrowserView) void {
    if (self.recent.items.len == 0) return;
    self.placeHeader("Recent");
    if (sectionCollapsed(self, "Recent")) return;
    for (self.recent.items) |r| recentRow(self, r);
}

/// Devices: real block-device and network mounts, from /proc/mounts.
fn renderDevicesSection(self: *BrowserView) void {
    const devices_folded = sectionCollapsed(self, "Devices");
    const f = c.fopen("/proc/mounts", "rb") orelse return;
    var buf: [32 * 1024]u8 = undefined;
    const nread = c.fread(&buf, 1, buf.len, f);
    _ = c.fclose(f);
    var shown: usize = 0;
    var first_dev = true;
    var it = std.mem.tokenizeScalar(u8, buf[0..nread], '\n');
    while (it.next()) |line| {
        if (shown >= 12) break;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const src = fields.next() orelse continue;
        const mp = fields.next() orelse continue;
        const fstype = fields.next() orelse continue;
        const interesting = std.mem.startsWith(u8, src, "/dev/") or
            std.mem.startsWith(u8, fstype, "nfs") or
            std.mem.eql(u8, fstype, "fuse.sshfs");
        if (!interesting) continue;
        if (first_dev) {
            self.placeHeader("Devices");
            first_dev = false;
            if (devices_folded) break;
        }
        // /proc/mounts octal-escapes spaces; show raw (rare).
        // "local:"-qualified: /proc/mounts is THIS machine's table,
        // and a bare path would resolve against a remote tab's host.
        var mp_spec_buf: [1200]u8 = undefined;
        const mp_spec = std.fmt.bufPrint(&mp_spec_buf, "local:{s}", .{mp}) catch mp;
        self.placeRow("drive-harddisk-symbolic", mp, mp_spec, false);
        shown += 1;
    }
}

// ── row context menu ─────────────────────────────────────────────

/// Heap ctx for one open places menu; owned by its popover.
const PlacesMenuCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    /// The row's spec, copied: renderPlaces may destroy the row (and
    /// its PlaceCtx) while this menu is still up.
    spec: []u8,
    popover: *c.GtkWidget,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.free(ctx.spec);
        ctx.allocator.destroy(ctx);
    }
};

/// True when `spec` is one of the recent-location rows.
fn isRecentSpec(self: *BrowserView, spec: []const u8) bool {
    for (self.recent.items) |r| {
        if (std.mem.eql(u8, r, spec)) return true;
    }
    return false;
}

pub fn onPlacesRightClick(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    var spec: []const u8 = "";
    var is_bookmark = false;
    if (c.gtk_list_box_get_row_at_y(self.places_list, @intFromFloat(y))) |row| {
        if (c.g_object_get_data(@ptrCast(row), "sketerm-place")) |data| {
            const pctx: *PlaceCtx = @ptrCast(@alignCast(data));
            spec = pctx.spec;
            is_bookmark = pctx.is_bookmark;
        }
    }
    if (std.mem.startsWith(u8, spec, "section:")) {
        showSectionMenu(self, spec["section:".len..], x, y);
        return;
    }
    if (std.mem.startsWith(u8, spec, "widget:")) {
        showWidgetRowMenu(self, spec, x, y);
        return;
    }
    if (spec.len == 0) {
        // Empty sidebar space: the sidebar's own configuration menu.
        showSidebarConfigMenu(self, x, y);
        return;
    }

    const ctx = self.allocator.create(PlacesMenuCtx) catch return;
    const spec_owned = self.allocator.dupe(u8, spec) catch {
        self.allocator.destroy(ctx);
        return;
    };
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .spec = spec_owned,
        .popover = undefined,
    };
    const root = classicmenu.Root.create(self.allocator) orelse {
        self.allocator.free(ctx.spec);
        self.allocator.destroy(ctx);
        return;
    };
    const m = root.top();
    const is_search = std.mem.startsWith(u8, ctx.spec, "search:");
    const is_register = std.mem.startsWith(u8, ctx.spec, "register:");
    if (is_search) {
        m.item("Run Query", &onPlacesMenuOpen, @ptrCast(ctx));
        m.item("Remove Saved Query", &onPlacesMenuRemove, @ptrCast(ctx));
    } else if (is_register) {
        m.item("Open Register", &onPlacesMenuOpen, @ptrCast(ctx));
    } else {
        m.item("Open in New Tab", &onPlacesMenuOpenTab, @ptrCast(ctx));
        m.item("Open Here", &onPlacesMenuOpen, @ptrCast(ctx));
        m.item("Copy Location", &onPlacesMenuCopy, @ptrCast(ctx));
        const extra = m.section();
        if (is_bookmark) {
            extra.item("Rename Bookmark…", &onBookmarkRenameItem, @ptrCast(ctx));
            extra.item("Change Icon…", &onBookmarkIconItem, @ptrCast(ctx));
            extra.item("Move Up", &onBookmarkMoveUp, @ptrCast(ctx));
            extra.item("Move Down", &onBookmarkMoveDown, @ptrCast(ctx));
            extra.item("Remove Bookmark", &onPlacesMenuRemove, @ptrCast(ctx));
        } else if (isRecentSpec(self, ctx.spec))
            extra.item("Remove from Recent", &onPlacesMenuRemove, @ptrCast(ctx))
        else
            extra.item("Add Bookmark", &onPlacesMenuBookmark, @ptrCast(ctx));
    }
    appendSidebarConfigItems(self, root, m.section());
    const popover = root.popupVia(@ptrCast(@alignCast(self.places_list)), self.root_box, x, y);
    ctx.popover = popover;
    c.g_object_set_data_full(@ptrCast(popover), "sketerm-placesmenu", @ptrCast(ctx), @ptrCast(&PlacesMenuCtx.free));
}

// ── sidebar configuration menu (sections, widgets, bookmarks) ────

/// Per-item ctx for section-level menu rows; owned by the menu Root.
const SectionCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    key: []u8,

    fn make(self: *BrowserView, root: *classicmenu.Root, key: []const u8) ?*SectionCtx {
        const ctx = self.allocator.create(SectionCtx) catch return null;
        ctx.* = .{
            .allocator = self.allocator,
            .view = self,
            .key = self.allocator.dupe(u8, key) catch {
                self.allocator.destroy(ctx);
                return null;
            },
        };
        root.own(&SectionCtx.free, @ptrCast(ctx));
        return ctx;
    }

    fn free(user: ?*anyopaque) callconv(.c) void {
        const ctx: *SectionCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.free(ctx.key);
        ctx.allocator.destroy(ctx);
    }
};

/// The "which sections are visible" checks + section/widget/bookmark
/// housekeeping, appended to whatever menu is opening.
fn appendSidebarConfigItems(self: *BrowserView, root: *classicmenu.Root, m: classicmenu.Menu) void {
    const sub = m.submenu("Sidebar Sections");
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = allSectionKeys(self, a);
    const saved = a.alloc([]const u8, self.section_order.items.len) catch return;
    for (self.section_order.items, 0..) |s, i| saved[i] = s;
    const ordered = places_mod.orderSections(a, saved, all) catch all;
    for (ordered) |key| {
        if (key.len == 0) continue;
        const ctx = SectionCtx.make(self, root, key) orelse continue;
        var tz: [160:0]u8 = undefined;
        const title = sectionTitleForKey(key);
        const tn = @min(title.len, tz.len - 1);
        @memcpy(tz[0..tn], title[0..tn]);
        tz[tn] = 0;
        sub.check(&tz, !sectionHidden(self, key), &onSectionToggleHidden, @ptrCast(ctx));
    }
    const tail = m.section();
    if (SectionCtx.make(self, root, "")) |ctx| {
        tail.item("New Widget Section…", &onNewWidgetSection, @ptrCast(ctx));
        tail.itemIcon("Bookmark Current Folder", .{ .name = "starred-symbolic" }, &onBookmarkHere, @ptrCast(ctx));
    }
}

/// Right-click on a section HEADER: reorder + per-section verbs, plus
/// the shared config items.
fn showSectionMenu(self: *BrowserView, title: []const u8, x: f64, y: f64) void {
    var kbuf: [180]u8 = undefined;
    const key = sectionKeyForTitle(self, title, &kbuf);
    const root = classicmenu.Root.create(self.allocator) orelse return;
    const m = root.top();
    if (key) |k| {
        if (SectionCtx.make(self, root, k)) |ctx| {
            m.item("Move Section Up", &onSectionMoveUp, @ptrCast(ctx));
            m.item("Move Section Down", &onSectionMoveDown, @ptrCast(ctx));
            if (std.mem.startsWith(u8, k, places_mod.WIDGET_KEY_PREFIX)) {
                const wsec = m.section();
                wsec.item("Add Widget…", &onSectionAddWidget, @ptrCast(ctx));
                wsec.item("Remove Section", &onSectionRemove, @ptrCast(ctx));
            }
        }
    }
    appendSidebarConfigItems(self, root, m.section());
    _ = root.popupVia(@ptrCast(@alignCast(self.places_list)), self.root_box, x, y);
}

/// Right-click on empty sidebar space.
fn showSidebarConfigMenu(self: *BrowserView, x: f64, y: f64) void {
    const root = classicmenu.Root.create(self.allocator) orelse return;
    appendSidebarConfigItems(self, root, root.top());
    _ = root.popupVia(@ptrCast(@alignCast(self.places_list)), self.root_box, x, y);
}

fn onSectionToggleHidden(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *SectionCtx = @ptrCast(@alignCast(user.?));
    var kbuf: [180]u8 = undefined;
    if (ctx.key.len > kbuf.len) return;
    @memcpy(kbuf[0..ctx.key.len], ctx.key);
    toggleSectionHidden(ctx.view, kbuf[0..ctx.key.len]);
}

fn onSectionMoveUp(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *SectionCtx = @ptrCast(@alignCast(user.?));
    var kbuf: [180]u8 = undefined;
    if (ctx.key.len > kbuf.len) return;
    @memcpy(kbuf[0..ctx.key.len], ctx.key);
    moveSection(ctx.view, kbuf[0..ctx.key.len], true);
}

fn onSectionMoveDown(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *SectionCtx = @ptrCast(@alignCast(user.?));
    var kbuf: [180]u8 = undefined;
    if (ctx.key.len > kbuf.len) return;
    @memcpy(kbuf[0..ctx.key.len], ctx.key);
    moveSection(ctx.view, kbuf[0..ctx.key.len], false);
}

fn widgetSectionIndex(self: *BrowserView, key: []const u8) ?usize {
    if (!std.mem.startsWith(u8, key, places_mod.WIDGET_KEY_PREFIX)) return null;
    const name = key[places_mod.WIDGET_KEY_PREFIX.len..];
    for (self.widgets.sections.items, 0..) |sec, i| {
        if (std.mem.eql(u8, sec.name, name)) return i;
    }
    return null;
}

fn onSectionAddWidget(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *SectionCtx = @ptrCast(@alignCast(user.?));
    const si = widgetSectionIndex(ctx.view, ctx.key) orelse return;
    sidewidgets.openWidgetForm(ctx.view, si, null);
}

fn onSectionRemove(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *SectionCtx = @ptrCast(@alignCast(user.?));
    const si = widgetSectionIndex(ctx.view, ctx.key) orelse return;
    sidewidgets.removeSection(ctx.view, si);
}

fn onNewWidgetSection(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *SectionCtx = @ptrCast(@alignCast(user.?));
    openNamePrompt(ctx.view, .new_section, null, "New Widget Section", "section name", "", null);
}

fn onBookmarkHere(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *SectionCtx = @ptrCast(@alignCast(user.?));
    bookmarkCurrent(ctx.view);
}

// ── widget row menu ──────────────────────────────────────────────

/// Parse "widget:<si>:<wi>".
fn parseWidgetSpec(spec: []const u8) ?struct { si: usize, wi: usize } {
    const rest = spec["widget:".len..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const si = std.fmt.parseInt(usize, rest[0..colon], 10) catch return null;
    const wi = std.fmt.parseInt(usize, rest[colon + 1 ..], 10) catch return null;
    return .{ .si = si, .wi = wi };
}

fn showWidgetRowMenu(self: *BrowserView, spec: []const u8, x: f64, y: f64) void {
    const ids = parseWidgetSpec(spec) orelse return;
    const root = classicmenu.Root.create(self.allocator) orelse return;
    const m = root.top();
    var sbuf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&sbuf, "{d}:{d}", .{ ids.si, ids.wi }) catch return;
    if (SectionCtx.make(self, root, key)) |ctx| {
        m.item("Edit Widget…", &onWidgetEdit, @ptrCast(ctx));
        m.item("Move Up", &onWidgetMoveUp, @ptrCast(ctx));
        m.item("Move Down", &onWidgetMoveDown, @ptrCast(ctx));
        m.item("Remove Widget", &onWidgetRemove, @ptrCast(ctx));
    }
    appendSidebarConfigItems(self, root, m.section());
    _ = root.popupVia(@ptrCast(@alignCast(self.places_list)), self.root_box, x, y);
}

fn widgetCtxIds(ctx: *SectionCtx) ?struct { si: usize, wi: usize } {
    const colon = std.mem.indexOfScalar(u8, ctx.key, ':') orelse return null;
    const si = std.fmt.parseInt(usize, ctx.key[0..colon], 10) catch return null;
    const wi = std.fmt.parseInt(usize, ctx.key[colon + 1 ..], 10) catch return null;
    return .{ .si = si, .wi = wi };
}

fn onWidgetEdit(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *SectionCtx = @ptrCast(@alignCast(user.?));
    const ids = widgetCtxIds(ctx) orelse return;
    sidewidgets.openWidgetForm(ctx.view, ids.si, ids.wi);
}

fn onWidgetRemove(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *SectionCtx = @ptrCast(@alignCast(user.?));
    const ids = widgetCtxIds(ctx) orelse return;
    sidewidgets.removeWidget(ctx.view, ids.si, ids.wi);
}

fn onWidgetMoveUp(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *SectionCtx = @ptrCast(@alignCast(user.?));
    const ids = widgetCtxIds(ctx) orelse return;
    sidewidgets.moveWidget(ctx.view, ids.si, ids.wi, true);
}

fn onWidgetMoveDown(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *SectionCtx = @ptrCast(@alignCast(user.?));
    const ids = widgetCtxIds(ctx) orelse return;
    sidewidgets.moveWidget(ctx.view, ids.si, ids.wi, false);
}

// ── bookmark row verbs ───────────────────────────────────────────

fn onBookmarkRenameItem(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const i = bookmarkIndexOf(self, ctx.spec) orelse return;
    const current = bookmarkLabelAt(self, i) orelse std.fs.path.basename(self.bookmarks.items[i]);
    openNamePrompt(self, .rename_bookmark, ctx.spec, "Rename Bookmark", "bookmark label", current, null);
}

fn onBookmarkIconItem(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const i = bookmarkIndexOf(self, ctx.spec) orelse return;
    openNamePrompt(
        self,
        .set_bookmark_icon,
        ctx.spec,
        "Bookmark Icon",
        "icon name, emoji, or image path",
        bookmarkIconAt(self, i),
        "Icon name (e.g. folder-music-symbolic), an emoji, or an absolute image path. Empty resets to the default.",
    );
}

fn onBookmarkMoveUp(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
    const i = bookmarkIndexOf(ctx.view, ctx.spec) orelse return;
    moveBookmark(ctx.view, i, true);
}

fn onBookmarkMoveDown(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
    const i = bookmarkIndexOf(ctx.view, ctx.spec) orelse return;
    moveBookmark(ctx.view, i, false);
}

// ── one-line name prompt (new section, bookmark label) ──────────

const NamePromptCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    purpose: enum { new_section, rename_bookmark, set_bookmark_icon },
    /// Owned bookmark spec; null for prompts without a bookmark target.
    target: ?[]u8,
    window: *c.GtkWidget,
    entry: *c.GtkWidget,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const ctx: *NamePromptCtx = @ptrCast(@alignCast(user.?));
        if (ctx.target) |target| ctx.allocator.free(target);
        ctx.allocator.destroy(ctx);
    }
};

fn openNamePrompt(
    self: *BrowserView,
    purpose: @FieldType(NamePromptCtx, "purpose"),
    target: ?[]const u8,
    title: [*:0]const u8,
    placeholder: [*:0]const u8,
    initial: []const u8,
    hint: ?[*:0]const u8,
) void {
    const win = c.gtk_window_new();
    c.gtk_window_set_title(@ptrCast(win), title);
    c.gtk_window_set_modal(@ptrCast(win), 1);
    c.gtk_window_set_default_size(@ptrCast(win), 360, -1);
    if (c.gtk_widget_get_root(self.root_box)) |root|
        c.gtk_window_set_transient_for(@ptrCast(win), @ptrCast(@alignCast(root)));
    const vbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 10);
    c.gtk_widget_set_margin_start(vbox, 14);
    c.gtk_widget_set_margin_end(vbox, 14);
    c.gtk_widget_set_margin_top(vbox, 14);
    c.gtk_widget_set_margin_bottom(vbox, 14);
    const entry = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(entry), placeholder);
    if (initial.len > 0) {
        var z: [512:0]u8 = undefined;
        const n = @min(initial.len, z.len - 1);
        @memcpy(z[0..n], initial[0..n]);
        z[n] = 0;
        c.gtk_editable_set_text(@ptrCast(entry), &z);
        c.gtk_editable_select_region(@ptrCast(entry), 0, -1);
    }
    c.gtk_box_append(@ptrCast(vbox), entry);
    if (hint) |h| {
        const hl = c.gtk_label_new(h);
        c.gtk_label_set_xalign(@ptrCast(hl), 0);
        c.gtk_label_set_wrap(@ptrCast(hl), 1);
        c.gtk_widget_add_css_class(hl, "dim-label");
        c.gtk_widget_add_css_class(hl, "caption");
        c.gtk_box_append(@ptrCast(vbox), hl);
    }
    const btnbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_halign(btnbox, c.GTK_ALIGN_END);
    const cancel = c.gtk_button_new_with_label("Cancel");
    const ok = c.gtk_button_new_with_label("OK");
    c.gtk_widget_add_css_class(ok, "suggested-action");
    c.gtk_box_append(@ptrCast(btnbox), cancel);
    c.gtk_box_append(@ptrCast(btnbox), ok);
    c.gtk_box_append(@ptrCast(vbox), btnbox);
    const ctx = self.allocator.create(NamePromptCtx) catch {
        c.gtk_window_destroy(@ptrCast(win));
        return;
    };
    const target_owned = if (target) |value| self.allocator.dupe(u8, value) catch {
        self.allocator.destroy(ctx);
        c.gtk_window_destroy(@ptrCast(win));
        return;
    } else null;
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .purpose = purpose,
        .target = target_owned,
        .window = win,
        .entry = entry,
    };
    c.g_object_set_data_full(@ptrCast(win), "sketerm-nameprompt", @ptrCast(ctx), @ptrCast(&NamePromptCtx.free));
    _ = c.g_signal_connect_data(cancel, "clicked", @ptrCast(&onNamePromptCancel), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(ok, "clicked", @ptrCast(&onNamePromptOk), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onNamePromptActivate), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_window_set_child(@ptrCast(win), vbox);
    c.gtk_window_present(@ptrCast(win));
    _ = c.gtk_widget_grab_focus(entry);
}

fn onNamePromptCancel(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *NamePromptCtx = @ptrCast(@alignCast(user.?));
    c.gtk_window_destroy(@ptrCast(ctx.window));
}

fn onNamePromptActivate(_: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    onNamePromptOk(undefined, user);
}

fn onNamePromptOk(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *NamePromptCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const text = std.mem.span(c.gtk_editable_get_text(@ptrCast(ctx.entry)));
    var nbuf: [512]u8 = undefined;
    const n = @min(text.len, nbuf.len);
    @memcpy(nbuf[0..n], text[0..n]);
    const name = nbuf[0..n];
    const purpose = ctx.purpose;
    switch (purpose) {
        .new_section => sidewidgets.addSection(self, name),
        .rename_bookmark => if (ctx.target) |target| {
            if (bookmarkIndexOf(self, target)) |i| setBookmarkLabel(self, i, name);
        },
        .set_bookmark_icon => if (ctx.target) |target| {
            if (bookmarkIndexOf(self, target)) |i| setBookmarkIcon(self, i, name);
        },
    }
    c.gtk_window_destroy(@ptrCast(ctx.window));
}

/// Activate the row exactly as a click would (navigate here, run the
/// query, open the register).
fn onPlacesMenuOpen(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    var buf: [4600]u8 = undefined;
    if (ctx.spec.len >= buf.len) return;
    @memcpy(buf[0..ctx.spec.len], ctx.spec);
    const spec = buf[0..ctx.spec.len];
    if (std.mem.startsWith(u8, spec, "search:")) {
        const idx = std.fmt.parseInt(usize, spec[7..], 10) catch return;
        self.runSavedSearch(idx);
        return;
    }
    if (std.mem.startsWith(u8, spec, "register:")) {
        _ = self.registerTab(spec["register:".len..]);
        return;
    }
    const tab = self.currentTab() orelse {
        _ = self.newTabSpec(spec);
        return;
    };
    self.navigateSpec(tab, spec);
}

fn onPlacesMenuOpenTab(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    var buf: [4600]u8 = undefined;
    if (ctx.spec.len >= buf.len) return;
    @memcpy(buf[0..ctx.spec.len], ctx.spec);
    _ = self.newTabSpec(buf[0..ctx.spec.len]);
}

fn onPlacesMenuCopy(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    var z: [4600:0]u8 = undefined;
    const n = @min(ctx.spec.len, z.len - 1);
    @memcpy(z[0..n], ctx.spec[0..n]);
    z[n] = 0;
    const clip = c.gtk_widget_get_clipboard(@ptrCast(@alignCast(ctx.view.places_list)));
    c.gdk_clipboard_set_text(clip, &z);
    ctx.view.setStatus("location copied");
}

fn onPlacesMenuBookmark(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    var buf: [4600]u8 = undefined;
    if (ctx.spec.len >= buf.len) return;
    @memcpy(buf[0..ctx.spec.len], ctx.spec);
    self.addBookmark(buf[0..ctx.spec.len]);
}

/// Remove the row from whichever durable list owns it (bookmark,
/// saved query, recent location).
fn onPlacesMenuRemove(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    var bookmark_changed = false;
    if (std.mem.startsWith(u8, ctx.spec, "search:")) {
        const idx = std.fmt.parseInt(usize, ctx.spec[7..], 10) catch return;
        if (idx < self.saved_searches.items.len) {
            self.saved_searches.items[idx].deinitOwned(self.allocator);
            _ = self.saved_searches.orderedRemove(idx);
        }
    } else {
        while (bookmarkIndexOf(self, ctx.spec)) |i| {
            removeBookmarkAt(self, i);
            bookmark_changed = true;
        }
        var i: usize = 0;
        while (i < self.recent.items.len) {
            if (std.mem.eql(u8, self.recent.items[i], ctx.spec)) {
                self.allocator.free(self.recent.items[i]);
                _ = self.recent.orderedRemove(i);
            } else i += 1;
        }
    }
    if (bookmark_changed) {
        bookmarksChanged(self);
    } else {
        self.savePlaces();
        self.renderPlaces();
    }
}

pub fn onPlaceActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const data = c.g_object_get_data(@ptrCast(row), "sketerm-place") orelse return;
    const ctx: *PlaceCtx = @ptrCast(@alignCast(data));
    if (ctx.spec.len == 0) return;
    if (std.mem.startsWith(u8, ctx.spec, "section:")) {
        // renderPlaces destroys every row -- and this ctx with it --
        // so the section name is copied out before anything runs.
        var nbuf: [128]u8 = undefined;
        const name = ctx.spec["section:".len..];
        if (name.len > nbuf.len) return;
        @memcpy(nbuf[0..name.len], name);
        toggleSection(self, nbuf[0..name.len]);
        self.savePlaces();
        self.renderPlaces();
        return;
    }
    if (std.mem.startsWith(u8, ctx.spec, "search:")) {
        const idx = std.fmt.parseInt(usize, ctx.spec[7..], 10) catch return;
        self.runSavedSearch(idx);
        return;
    }
    if (std.mem.startsWith(u8, ctx.spec, "register:")) {
        // registerTab re-points the tab, which frees the name it was
        // showing -- and that could be this very slice.
        var nbuf: [80]u8 = undefined;
        const name = ctx.spec["register:".len..];
        if (name.len > nbuf.len) return;
        @memcpy(nbuf[0..name.len], name);
        _ = self.registerTab(nbuf[0..name.len]);
        return;
    }
    const tab = self.currentTab() orelse {
        _ = self.newTabSpec(ctx.spec);
        return;
    };
    var buf: [4300]u8 = undefined;
    if (ctx.spec.len >= buf.len) return;
    @memcpy(buf[0..ctx.spec.len], ctx.spec);
    self.navigateSpec(tab, buf[0..ctx.spec.len]);
}

/// Open a saved query: navigate its root, refill the search bar, and
/// fire. A name query comes back LIVE -- reopening one is a
/// subscription, not a re-run, which is the whole point of saving it.
pub fn runSavedSearch(self: *BrowserView, idx: usize) void {
    if (idx >= self.saved_searches.items.len) return;
    const sq = self.saved_searches.items[idx];
    const tab = self.currentTab() orelse (self.newTabSpec(sq.spec) orelse return);
    // Both strings live in the saved list, which navigateSpec's own
    // recent-list bookkeeping can reallocate underneath us.
    var buf: [4300]u8 = undefined;
    var pbuf: [512]u8 = undefined;
    if (sq.spec.len >= buf.len or sq.pattern.len >= pbuf.len) return;
    @memcpy(buf[0..sq.spec.len], sq.spec);
    @memcpy(pbuf[0..sq.pattern.len], sq.pattern);
    const spec = buf[0..sq.spec.len];
    const text = pbuf[0..sq.pattern.len];
    const content = sq.content;
    self.navigateSpec(tab, spec);
    var pz: [512:0]u8 = undefined;
    const pat = std.fmt.bufPrintZ(&pz, "{s}", .{text}) catch return;
    c.gtk_editable_set_text(@ptrCast(self.search_entry), pat.ptr);
    c.gtk_check_button_set_active(@ptrCast(self.search_content), @intFromBool(content));
    c.gtk_widget_set_visible(self.search_bar, 1);
    const q = query_mod.parse(text, content) orelse return;
    self.runQuery(tab, text, q);
}

pub fn onSaveSearchClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const ls = self.last_search orelse {
        self.setStatus("run a query first, then save it");
        return;
    };
    for (self.saved_searches.items) |sq| {
        if (std.mem.eql(u8, sq.spec, ls.spec) and std.mem.eql(u8, sq.pattern, ls.pattern) and sq.content == ls.content) {
            self.setStatus("query already saved");
            return;
        }
    }
    const spec = self.allocator.dupe(u8, ls.spec) catch return;
    const pat = self.allocator.dupe(u8, ls.pattern) catch {
        self.allocator.free(spec);
        return;
    };
    self.saved_searches.append(self.allocator, .{ .spec = spec, .pattern = pat, .content = ls.content }) catch {
        self.allocator.free(spec);
        self.allocator.free(pat);
        return;
    };
    self.savePlaces();
    if (self.places_on) self.renderPlaces();
    self.setStatusFmt("saved query: {s}", .{ls.pattern});
}

pub fn savePlaces(self: *BrowserView) void {
    // attach() can migrate a legacy collection before registering the
    // new face. If another face already owns current process state,
    // that not-yet-live disk snapshot must not replace it.
    const source_index = registeredIndex(self);
    if (live_views.items.len > 0 and source_index == null) return;
    if (source_index) |i| {
        if (!live_views.items[i].synced) {
            if (authoritative) |*current| {
                live_views.items[i].synced = syncView(self, current.value);
            }
            return;
        }
    }

    const next = if (authoritative) |*current| blk: {
        var sources: MergeSources = .{};
        // Other views go first so the explicit saver wins only when
        // both changed the same field; unrelated pending changes merge.
        for (live_views.items) |entry| {
            if (entry.view == self or !entry.synced) continue;
            sources.consider(entry.view, current.value);
        }
        sources.consider(self, current.value);
        break :blk Authority.captureMerged(self.allocator, current.value, sources) orelse return;
    } else Authority.capture(self) orelse return;
    places_mod.save(self.allocator, next.value);
    for (live_views.items) |*entry| {
        const view = entry.view;
        entry.synced = syncView(view, next.value);
        if (entry.synced and view != self and !view.widgets_dead and view.places_on) view.renderPlaces();
    }
    if (authoritative) |*current| current.deinit();
    authoritative = next;
}

/// The custom label for bookmark `i`, or null when it should derive
/// from the spec. The labels list is kept parallel to `bookmarks`;
/// a short list (older places.json) reads as no-label.
pub fn bookmarkLabelAt(self: *BrowserView, i: usize) ?[]const u8 {
    if (i >= self.bookmark_labels.items.len) return null;
    const l = self.bookmark_labels.items[i];
    return if (l.len == 0) null else l;
}

/// The custom icon value for bookmark `i`; "" (also for a short list,
/// an older places.json) = the default icon.
pub fn bookmarkIconAt(self: *BrowserView, i: usize) []const u8 {
    if (i >= self.bookmark_icons.items.len) return "";
    return self.bookmark_icons.items[i];
}

fn bookmarkIndexIn(bookmarks: anytype, spec: []const u8) ?usize {
    for (bookmarks, 0..) |b, i| {
        if (std.mem.eql(u8, b, spec)) return i;
    }
    return null;
}

fn bookmarkIndexOf(self: *BrowserView, spec: []const u8) ?usize {
    return bookmarkIndexIn(self.bookmarks.items, spec);
}

/// Pad an owned-string parallel list with "" up to index `i`.
fn padParallel(self: *BrowserView, list: *std.ArrayList([]u8), i: usize) bool {
    while (list.items.len <= i) {
        const empty = self.allocator.dupe(u8, "") catch return false;
        list.append(self.allocator, empty) catch {
            self.allocator.free(empty);
            return false;
        };
    }
    return true;
}

/// Remove bookmark `i` together with its label and icon slots.
fn removeBookmarkAt(self: *BrowserView, i: usize) void {
    if (i >= self.bookmarks.items.len) return;
    self.allocator.free(self.bookmarks.items[i]);
    _ = self.bookmarks.orderedRemove(i);
    if (i < self.bookmark_labels.items.len) {
        self.allocator.free(self.bookmark_labels.items[i]);
        _ = self.bookmark_labels.orderedRemove(i);
    }
    if (i < self.bookmark_icons.items.len) {
        self.allocator.free(self.bookmark_icons.items[i]);
        _ = self.bookmark_icons.orderedRemove(i);
    }
}

/// Move bookmark `i` (with its label and icon) one slot up or down.
pub fn moveBookmark(self: *BrowserView, i: usize, up: bool) void {
    const items = self.bookmarks.items;
    const j = if (up) (if (i == 0) return else i - 1) else (if (i + 1 >= items.len) return else i + 1);
    std.mem.swap([]u8, &items[i], &items[j]);
    // Keep the parallel lists long enough to swap in step.
    if (!padParallel(self, &self.bookmark_labels, @max(i, j))) return;
    std.mem.swap([]u8, &self.bookmark_labels.items[i], &self.bookmark_labels.items[j]);
    if (!padParallel(self, &self.bookmark_icons, @max(i, j))) return;
    std.mem.swap([]u8, &self.bookmark_icons.items[i], &self.bookmark_icons.items[j]);
    bookmarksChanged(self);
}

/// Set (or with "" clear) the custom label of bookmark `i`.
pub fn setBookmarkLabel(self: *BrowserView, i: usize, label: []const u8) void {
    if (i >= self.bookmarks.items.len) return;
    if (!padParallel(self, &self.bookmark_labels, i)) return;
    const owned = self.allocator.dupe(u8, label) catch return;
    self.allocator.free(self.bookmark_labels.items[i]);
    self.bookmark_labels.items[i] = owned;
    bookmarksChanged(self);
}

/// Set (or with "" reset) the custom icon of bookmark `i`.
pub fn setBookmarkIcon(self: *BrowserView, i: usize, icon: []const u8) void {
    if (i >= self.bookmarks.items.len) return;
    if (!padParallel(self, &self.bookmark_icons, i)) return;
    const owned = self.allocator.dupe(u8, icon) catch return;
    self.allocator.free(self.bookmark_icons.items[i]);
    self.bookmark_icons.items[i] = owned;
    bookmarksChanged(self);
}

pub fn addBookmark(self: *BrowserView, spec: []const u8) void {
    for (self.bookmarks.items) |b| {
        if (std.mem.eql(u8, b, spec)) return;
    }
    const owned = self.allocator.dupe(u8, spec) catch return;
    self.bookmarks.append(self.allocator, owned) catch {
        self.allocator.free(owned);
        return;
    };
    const empty = self.allocator.dupe(u8, "") catch null;
    if (empty) |e| self.bookmark_labels.append(self.allocator, e) catch self.allocator.free(e);
    const empty_icon = self.allocator.dupe(u8, "") catch null;
    if (empty_icon) |e| self.bookmark_icons.append(self.allocator, e) catch self.allocator.free(e);
    bookmarksChanged(self);
    self.setStatusFmt("bookmarked: {s}", .{spec});
}

/// Bookmark the CURRENT tab's directory (menu + Ctrl+D).
pub fn bookmarkCurrent(self: *BrowserView) void {
    const tab = self.currentTab() orelse return;
    var buf: [4600]u8 = undefined;
    const spec = if (tab.hc.host) |host|
        std.fmt.bufPrint(&buf, "{s}:{s}", .{ host, tab.root.path }) catch return
    else
        std.fmt.bufPrint(&buf, "local:{s}", .{tab.root.path}) catch return;
    addBookmark(self, spec);
}

pub fn recordRecentSpec(self: *BrowserView, spec: []const u8) void {
    places_mod.recordRecent(self.allocator, &self.recent, spec, places_mod.RECENT_CAP);
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    const now_ms = @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
    places_mod.recordVisit(self.allocator, &self.frecency, spec, now_ms, places_mod.FRECENCY_CAP);
    self.savePlaces();
    if (self.places_on) self.renderPlaces();
}

test "hostSectionTitle titleizes the bare host name" {
    const t = std.testing;
    var buf: [160]u8 = undefined;
    try t.expectEqualStrings("Archdev Places", hostSectionTitle("archdev", &buf));
    try t.expectEqualStrings("Box Places", hostSectionTitle("skerit@box", &buf));
    try t.expectEqualStrings("Box Places", hostSectionTitle("udp:box", &buf));
    try t.expectEqualStrings("Aeor Places", hostSectionTitle("user@aeor", &buf));
}

test "bookmark dialog target resolves by spec after reorder" {
    const bookmarks = [_][]const u8{ "local:/two", "local:/one" };
    try std.testing.expectEqual(@as(?usize, 1), bookmarkIndexIn(&bookmarks, "local:/one"));
}

fn deinitTestPersistedView(view: *BrowserView) void {
    const allocator = view.allocator;
    freeStrings(allocator, &view.bookmarks);
    freeStrings(allocator, &view.bookmark_labels);
    freeStrings(allocator, &view.bookmark_icons);
    freeStrings(allocator, &view.recent);
    for (view.frecency.items) |entry| allocator.free(entry.spec);
    view.frecency.deinit(allocator);
    freeStrings(allocator, &view.collapsed);
    freeStrings(allocator, &view.hidden_sections);
    freeStrings(allocator, &view.section_order);
    view.widgets.deinit(allocator);
    for (view.saved_searches.items) |search| search.deinitOwned(allocator);
    view.saved_searches.deinit(allocator);
}

test "full places synchronization replaces unrelated stale fields together" {
    const t = std.testing;
    const widgets = [_]places_mod.Widget{.{ .kind = "text", .text = "authoritative widget" }};
    const sections = [_]places_mod.WidgetSection{.{ .name = "Status", .widgets = &widgets }};
    const searches = [_]places_mod.SavedSearch{.{ .spec = "local:/src", .pattern = "*.zig" }};
    const places = places_mod.Places{
        .bookmarks = &.{"local:/project"},
        .bookmark_labels = &.{"Project"},
        .bookmark_icons = &.{"folder-symbolic"},
        .recent = &.{"local:/current"},
        .searches = &searches,
        .hidden_sections = &.{"devices"},
        .widget_sections = &sections,
        .sidebar_px = 260,
        .side_info = true,
    };
    var view = BrowserView{ .allocator = t.allocator, .pane = undefined };
    const stale = try t.allocator.dupe(u8, "local:/stale");
    try view.recent.append(t.allocator, stale);
    defer deinitTestPersistedView(&view);
    try t.expect(syncView(&view, places));
    try t.expectEqualStrings("local:/project", view.bookmarks.items[0]);
    try t.expectEqualStrings("local:/current", view.recent.items[0]);
    try t.expectEqualStrings("*.zig", view.saved_searches.items[0].pattern);
    try t.expectEqualStrings("authoritative widget", view.widgets.sections.items[0].widgets.items[0].text);
    try t.expectEqualStrings("devices", view.hidden_sections.items[0]);
    try t.expectEqual(@as(i32, 260), view.sidebar_px);
    try t.expect(view.side_info);
}

test "places merge keeps unsaved changes from different live views" {
    const t = std.testing;
    const base = places_mod.Places{
        .bookmarks = &.{"local:/old-bookmark"},
        .bookmark_labels = &.{"Old"},
        .bookmark_icons = &.{""},
        .recent = &.{"local:/old-recent"},
    };
    var bookmark_view = BrowserView{ .allocator = t.allocator, .pane = undefined };
    defer deinitTestPersistedView(&bookmark_view);
    var recent_view = BrowserView{ .allocator = t.allocator, .pane = undefined };
    defer deinitTestPersistedView(&recent_view);
    try t.expect(syncView(&bookmark_view, base));
    try t.expect(syncView(&recent_view, base));

    t.allocator.free(bookmark_view.bookmarks.items[0]);
    bookmark_view.bookmarks.items[0] = try t.allocator.dupe(u8, "local:/new-bookmark");
    t.allocator.free(recent_view.recent.items[0]);
    recent_view.recent.items[0] = try t.allocator.dupe(u8, "local:/new-recent");

    var sources: MergeSources = .{};
    sources.consider(&recent_view, base);
    sources.consider(&bookmark_view, base);
    var merged = Authority.captureMerged(t.allocator, base, sources) orelse return error.OutOfMemory;
    defer merged.deinit();
    try t.expectEqualStrings("local:/new-bookmark", merged.value.bookmarks[0]);
    try t.expectEqualStrings("local:/new-recent", merged.value.recent[0]);
}
