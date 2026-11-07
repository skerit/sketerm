//! Per-tab disk-usage analyzer and linked treemap.

const std = @import("std");
const c = @import("../../c.zig").c;
const model_mod = @import("../../filebrowser/diskusage.zig");
const format = @import("../../filebrowser/format.zig");
const toolbtn = @import("../toolbtn.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const HostConn = @import("types.zig").HostConn;
const WireJobEv = @import("types.zig").WireJobEv;
const cast = @import("../../util/cast.zig");
const strz = @import("../../util/strz.zig");

const STATE_QDATA = "sketerm-disk-usage-state";
const ROW_QDATA = "sketerm-disk-usage-row";
const MAX_ROWS: usize = 500;
const MAX_TILES: usize = 32;
const OTHER_ID = std.math.maxInt(usize);
const RENDER_DELAY_MS: c.guint = 160;

const Hit = struct {
    id: usize,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    tab: *BTab,
    tab_alive: bool = true,
    hc: *HostConn,
    root: []u8,
    current: []u8,
    model: model_mod.Model,
    metric: model_mod.Metric = .allocated,
    job: u64 = 0,
    running: bool = true,
    canceling: bool = false,
    failed: bool = false,
    canceled: bool = false,
    interrupted: bool = false,
    retention_failed: bool = false,
    truncated: bool = false,
    progress_size: u64 = 0,
    progress_allocated: u64 = 0,
    progress_items: u64 = 0,
    result_errors: u64 = 0,
    result_skipped: u64 = 0,
    progress_file: [512]u8 = undefined,
    progress_file_len: usize = 0,
    render_source: c.guint = 0,
    page: *c.GtkWidget = undefined,
    listbox: *c.GtkListBox = undefined,
    current_label: *c.GtkLabel = undefined,
    path_label: *c.GtkLabel = undefined,
    summary_label: *c.GtkLabel = undefined,
    progress_label: *c.GtkLabel = undefined,
    spinner: *c.GtkSpinner = undefined,
    up_button: *c.GtkWidget = undefined,
    cancel_button: *c.GtkWidget = undefined,
    rescan_button: *c.GtkWidget = undefined,
    mounts_check: *c.GtkCheckButton = undefined,
    allocated_check: *c.GtkCheckButton = undefined,
    apparent_check: *c.GtkCheckButton = undefined,
    chart: *c.GtkWidget = undefined,
    children: std.ArrayList(usize) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    hovered: ?usize = null,
    scroller: *c.GtkWidget = undefined,
    /// The live result rows by node index (`OTHER_ID` for the remainder),
    /// borrowed from their widgets, which own the contexts. A render
    /// updates these in place; only rows that leave the view are removed.
    rows: std.AutoHashMapUnmanaged(usize, *RowCtx) = .empty,
    /// The selected result, by path: it survives a rescan (indices are
    /// reassigned) and is what going back up re-selects.
    selected_path: ?[]u8 = null,
    trail: model_mod.Trail,
    /// Set while a sync adds, removes or selects rows itself, so GTK's
    /// selection signals are not mistaken for the user's.
    syncing: bool = false,
    /// Verification counters (`browser-usage`): renders, the renders a
    /// generic browser re-render caused, and row widgets made/dropped.
    renders: u64 = 0,
    external_renders: u64 = 0,
    rows_built: u64 = 0,
    rows_dropped: u64 = 0,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(State, user);
        if (self.tab_alive and self.tab.usage == self) self.tab.usage = null;
        if (self.render_source != 0) _ = c.g_source_remove(self.render_source);
        self.children.deinit(self.allocator);
        self.hits.deinit(self.allocator);
        // The row contexts belong to their (already disposed) widgets.
        self.rows.deinit(self.allocator);
        if (self.selected_path) |p| self.allocator.free(p);
        self.trail.deinit();
        self.model.deinit();
        self.allocator.free(self.root);
        self.allocator.free(self.current);
        self.allocator.destroy(self);
    }

    fn scheduleRender(self: *State) void {
        if (self.render_source != 0 or self.tab.view.widgets_dead) return;
        self.render_source = c.g_timeout_add(RENDER_DELAY_MS, @ptrCast(&onRenderTick), @ptrCast(self));
    }

    /// The browser's generic re-render of this tab (listing deltas, git
    /// overlays, tab switches) landing on the analyzer.
    pub fn renderExternal(self: *State) void {
        self.external_renders += 1;
        self.render();
    }

    pub fn render(self: *State) void {
        if (self.tab.view.widgets_dead) return;
        self.renders += 1;
        self.model.directChildren(self.current, self.metric, &self.children) catch return;
        renderHeader(self);
        syncRows(self);
        c.gtk_widget_queue_draw(self.chart);
    }

    fn displayedTotal(self: *const State) u64 {
        if (self.model.get(self.current)) |node| return node.value(self.metric);
        var total: u64 = 0;
        for (self.children.items) |index| total +|= self.model.nodes.items[index].value(self.metric);
        if (std.mem.eql(u8, self.current, self.root)) {
            const progress = switch (self.metric) {
                .allocated => self.progress_allocated,
                .apparent => self.progress_size,
            };
            return @max(progress, total);
        }
        return total;
    }

    fn displayedItems(self: *const State) u64 {
        if (self.model.get(self.current)) |node| return node.items;
        var total: u64 = 1;
        for (self.children.items) |index| total +|= self.model.nodes.items[index].items;
        return if (std.mem.eql(u8, self.current, self.root)) @max(self.progress_items, total) else total;
    }

    /// Show `path`, keeping the keyboard in the list: a descent opens at
    /// the top, a return shows the folder where it was left with the
    /// folder it came from selected.
    fn setCurrent(self: *State, path: []const u8) void {
        const fresh = self.allocator.dupe(u8, path) catch return;
        const vadj = c.gtk_scrolled_window_get_vadjustment(@ptrCast(@alignCast(self.scroller)));
        const scroll = self.trail.move(self.current, if (vadj) |a| c.gtk_adjustment_get_value(a) else 0, fresh);
        if (model_mod.childToward(fresh, self.current)) |came_from| self.setSelectedPath(came_from);
        self.allocator.free(self.current);
        self.current = fresh;
        self.hovered = null;
        self.render();
        if (vadj) |a| {
            // The rows just changed but are not laid out yet, so the
            // adjustment still has the old folder's height: widen it
            // for now and the next allocation keeps the offset.
            const page = c.gtk_adjustment_get_page_size(a);
            const upper = @max(c.gtk_adjustment_get_upper(a), scroll + page);
            c.gtk_adjustment_configure(a, scroll, c.gtk_adjustment_get_lower(a), upper, c.gtk_adjustment_get_step_increment(a), c.gtk_adjustment_get_page_increment(a), page);
        }
    }

    fn goUp(self: *State) bool {
        if (std.mem.eql(u8, self.current, self.root)) return false;
        const parent = std.fs.path.dirname(self.current) orelse return false;
        if (!model_mod.within(self.root, parent)) return false;
        self.setCurrent(parent);
        return true;
    }

    fn setSelectedPath(self: *State, path: ?[]const u8) void {
        if (self.selected_path) |old| {
            if (path != null and std.mem.eql(u8, old, path.?)) return;
            self.allocator.free(old);
            self.selected_path = null;
        }
        if (path) |p| self.selected_path = self.allocator.dupe(u8, p) catch null;
    }

    fn setProgressText(self: *State, text: []const u8) void {
        var buf: [640:0]u8 = undefined;
        c.gtk_label_set_text(self.progress_label, zText(&buf, text));
    }
};

/// One result row's widgets and what they show; owned by the row widget.
const RowCtx = struct {
    allocator: std.mem.Allocator,
    state: *State,
    /// Node index, or `OTHER_ID` for the remainder row.
    id: usize,
    /// Position in the list, read by the list's sort function.
    order: usize,
    seen: bool = false,
    face: ?model_mod.RowFace = null,
    row: *c.GtkWidget,
    icon: *c.GtkWidget,
    name: *c.GtkWidget,
    bar: ?*c.GtkWidget,
    size: *c.GtkWidget,
    percent: *c.GtkWidget,
    items: *c.GtkWidget,
};

const zText = strz.copyZ;

/// A header button. Framed (this bar is a header, not flat chrome),
/// but through the shared helper so an icon name the theme cannot
/// draw still yields a labelled button rather than an empty one.
fn makeButton(anchor: *c.GtkWidget, icon: [*:0]const u8, text: [*:0]const u8, tip: [*:0]const u8, callback: anytype, state: *State) *c.GtkWidget {
    return toolbtn.button(anchor, icon, text, tip, callback, @ptrCast(state));
}

fn createState(tab: *BTab, root: []const u8) ?*State {
    const allocator = tab.view.allocator;
    const self = allocator.create(State) catch return null;
    const root_owned = allocator.dupe(u8, root) catch {
        allocator.destroy(self);
        return null;
    };
    const current = allocator.dupe(u8, root) catch {
        allocator.free(root_owned);
        allocator.destroy(self);
        return null;
    };
    self.* = .{
        .allocator = allocator,
        .tab = tab,
        .hc = tab.hc,
        .root = root_owned,
        .current = current,
        .model = model_mod.Model.init(allocator),
        .trail = model_mod.Trail.init(allocator),
    };

    const page = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
    c.gtk_widget_set_hexpand(page, 1);
    c.gtk_widget_set_vexpand(page, 1);
    self.page = page;
    c.g_object_set_data_full(@ptrCast(page), STATE_QDATA, @ptrCast(self), @ptrCast(&State.free));

    const toolbar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8).?;
    c.gtk_widget_set_margin_start(toolbar, 12);
    c.gtk_widget_set_margin_end(toolbar, 12);
    c.gtk_widget_set_margin_top(toolbar, 10);
    c.gtk_widget_set_margin_bottom(toolbar, 10);
    const files = makeButton(toolbar, "view-list-symbolic", "Files", "Return to the file listing", &onFilesClicked, self);
    c.gtk_box_append(@ptrCast(toolbar), files);
    self.up_button = makeButton(toolbar, "go-up-symbolic", "Up", "Analyze the parent shown in this scan", &onUpClicked, self);
    c.gtk_box_append(@ptrCast(toolbar), self.up_button);

    const titles = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 1).?;
    c.gtk_widget_set_hexpand(titles, 1);
    self.current_label = @ptrCast(@alignCast(c.gtk_label_new("Disk Usage").?));
    c.gtk_label_set_xalign(self.current_label, 0);
    c.gtk_widget_add_css_class(@ptrCast(@alignCast(self.current_label)), "title-3");
    c.gtk_label_set_ellipsize(self.current_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(@ptrCast(titles), @ptrCast(@alignCast(self.current_label)));
    self.path_label = @ptrCast(@alignCast(c.gtk_label_new("").?));
    c.gtk_label_set_xalign(self.path_label, 0);
    c.gtk_label_set_ellipsize(self.path_label, c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_widget_add_css_class(@ptrCast(@alignCast(self.path_label)), "dim-label");
    c.gtk_box_append(@ptrCast(titles), @ptrCast(@alignCast(self.path_label)));
    c.gtk_box_append(@ptrCast(toolbar), titles);

    self.spinner = @ptrCast(@alignCast(c.gtk_spinner_new().?));
    c.gtk_spinner_start(self.spinner);
    c.gtk_box_append(@ptrCast(toolbar), @ptrCast(@alignCast(self.spinner)));
    self.cancel_button = makeButton(toolbar, "process-stop-symbolic", "Cancel", "Cancel this scan", &onCancelClicked, self);
    c.gtk_box_append(@ptrCast(toolbar), self.cancel_button);
    self.rescan_button = makeButton(toolbar, "view-refresh-symbolic", "Rescan", "Scan this folder again", &onRescanClicked, self);
    c.gtk_widget_set_visible(self.rescan_button, 0);
    c.gtk_box_append(@ptrCast(toolbar), self.rescan_button);
    c.gtk_box_append(@ptrCast(page), toolbar);

    const options = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12).?;
    c.gtk_widget_set_margin_start(options, 12);
    c.gtk_widget_set_margin_end(options, 12);
    c.gtk_widget_set_margin_bottom(options, 10);
    const metric_label = c.gtk_label_new("Measure:").?;
    c.gtk_widget_add_css_class(metric_label, "dim-label");
    c.gtk_box_append(@ptrCast(options), metric_label);
    self.allocated_check = @ptrCast(@alignCast(c.gtk_check_button_new_with_label("On disk").?));
    self.apparent_check = @ptrCast(@alignCast(c.gtk_check_button_new_with_label("Apparent size").?));
    c.gtk_check_button_set_group(self.apparent_check, self.allocated_check);
    c.gtk_check_button_set_active(self.allocated_check, 1);
    _ = c.g_signal_connect_data(self.allocated_check, "toggled", @ptrCast(&onMetricToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(self.apparent_check, "toggled", @ptrCast(&onMetricToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(options), @ptrCast(@alignCast(self.allocated_check)));
    c.gtk_box_append(@ptrCast(options), @ptrCast(@alignCast(self.apparent_check)));
    self.mounts_check = @ptrCast(@alignCast(c.gtk_check_button_new_with_label("Include mounted filesystems").?));
    c.gtk_widget_set_tooltip_text(@ptrCast(@alignCast(self.mounts_check)), "Applied on the next rescan; off avoids crossing into other drives and network mounts");
    c.gtk_box_append(@ptrCast(options), @ptrCast(@alignCast(self.mounts_check)));
    c.gtk_box_append(@ptrCast(page), options);

    const body = c.gtk_paned_new(c.GTK_ORIENTATION_HORIZONTAL).?;
    c.gtk_widget_set_hexpand(body, 1);
    c.gtk_widget_set_vexpand(body, 1);
    c.gtk_paned_set_position(@ptrCast(body), 520);
    c.gtk_paned_set_shrink_start_child(@ptrCast(body), 0);
    c.gtk_paned_set_shrink_end_child(@ptrCast(body), 0);

    const left = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8).?;
    c.gtk_widget_set_margin_start(left, 12);
    c.gtk_widget_set_margin_end(left, 8);
    c.gtk_widget_set_margin_bottom(left, 12);
    self.summary_label = @ptrCast(@alignCast(c.gtk_label_new("Scanning...").?));
    c.gtk_label_set_xalign(self.summary_label, 0);
    c.gtk_label_set_wrap(self.summary_label, 1);
    c.gtk_widget_add_css_class(@ptrCast(@alignCast(self.summary_label)), "card");
    c.gtk_widget_set_margin_start(@ptrCast(@alignCast(self.summary_label)), 10);
    c.gtk_widget_set_margin_end(@ptrCast(@alignCast(self.summary_label)), 10);
    c.gtk_widget_set_margin_top(@ptrCast(@alignCast(self.summary_label)), 8);
    c.gtk_widget_set_margin_bottom(@ptrCast(@alignCast(self.summary_label)), 8);
    c.gtk_box_append(@ptrCast(left), @ptrCast(@alignCast(self.summary_label)));

    const columns = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8).?;
    c.gtk_widget_add_css_class(columns, "dim-label");
    const folder_head = c.gtk_label_new("Folder or file").?;
    c.gtk_label_set_xalign(@ptrCast(folder_head), 0);
    c.gtk_widget_set_hexpand(folder_head, 1);
    c.gtk_box_append(@ptrCast(columns), folder_head);
    const size_head = c.gtk_label_new("Size").?;
    c.gtk_widget_set_size_request(size_head, 90, -1);
    c.gtk_label_set_xalign(@ptrCast(size_head), 1);
    c.gtk_box_append(@ptrCast(columns), size_head);
    const percent_head = c.gtk_label_new("Share").?;
    c.gtk_widget_set_size_request(percent_head, 58, -1);
    c.gtk_label_set_xalign(@ptrCast(percent_head), 1);
    c.gtk_box_append(@ptrCast(columns), percent_head);
    const items_head = c.gtk_label_new("Contents").?;
    c.gtk_widget_set_size_request(items_head, 78, -1);
    c.gtk_label_set_xalign(@ptrCast(items_head), 1);
    c.gtk_box_append(@ptrCast(columns), items_head);
    c.gtk_box_append(@ptrCast(left), columns);

    const scroll = c.gtk_scrolled_window_new().?;
    self.scroller = scroll;
    c.gtk_widget_set_hexpand(scroll, 1);
    c.gtk_widget_set_vexpand(scroll, 1);
    self.listbox = @ptrCast(@alignCast(c.gtk_list_box_new().?));
    c.gtk_list_box_set_selection_mode(self.listbox, c.GTK_SELECTION_SINGLE);
    c.gtk_list_box_set_activate_on_single_click(self.listbox, 1);
    c.gtk_widget_add_css_class(@ptrCast(@alignCast(self.listbox)), "boxed-list");
    _ = c.g_signal_connect_data(self.listbox, "row-activated", @ptrCast(&onRowActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(self.listbox, "row-selected", @ptrCast(&onRowSelected), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    // Rows keep their widgets across renders; order is a field, not
    // insertion order, so a reorder never re-creates a row.
    c.gtk_list_box_set_sort_func(self.listbox, @ptrCast(&sortRows), null, null);
    c.gtk_scrolled_window_set_child(@ptrCast(scroll), @ptrCast(@alignCast(self.listbox)));
    // GtkViewport's scroll-to-focus runs at the next allocation, against
    // rows a folder change has only just inserted, and lands the list at
    // the top; the list box keeps its own cursor row in view instead.
    if (c.gtk_scrolled_window_get_child(@ptrCast(scroll))) |vp| c.gtk_viewport_set_scroll_to_focus(@ptrCast(@alignCast(vp)), 0);
    c.gtk_box_append(@ptrCast(left), scroll);
    self.progress_label = @ptrCast(@alignCast(c.gtk_label_new("").?));
    c.gtk_label_set_xalign(self.progress_label, 0);
    c.gtk_label_set_ellipsize(self.progress_label, c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_widget_add_css_class(@ptrCast(@alignCast(self.progress_label)), "dim-label");
    c.gtk_box_append(@ptrCast(left), @ptrCast(@alignCast(self.progress_label)));
    c.gtk_paned_set_start_child(@ptrCast(body), left);

    const chart_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8).?;
    c.gtk_widget_set_margin_start(chart_box, 8);
    c.gtk_widget_set_margin_end(chart_box, 12);
    c.gtk_widget_set_margin_bottom(chart_box, 12);
    const chart_title = c.gtk_label_new("Treemap").?;
    c.gtk_label_set_xalign(@ptrCast(chart_title), 0);
    c.gtk_widget_add_css_class(chart_title, "heading");
    c.gtk_box_append(@ptrCast(chart_box), chart_title);
    self.chart = c.gtk_drawing_area_new().?;
    c.gtk_widget_set_hexpand(self.chart, 1);
    c.gtk_widget_set_vexpand(self.chart, 1);
    c.gtk_widget_set_size_request(self.chart, 280, 240);
    c.gtk_widget_add_css_class(self.chart, "card");
    c.gtk_drawing_area_set_draw_func(@ptrCast(self.chart), @ptrCast(&drawChart), @ptrCast(self), null);
    const click = c.gtk_gesture_click_new().?;
    _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&onChartPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(self.chart, @ptrCast(click));
    const motion = c.gtk_event_controller_motion_new().?;
    _ = c.g_signal_connect_data(motion, "motion", @ptrCast(&onChartMotion), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(motion, "leave", @ptrCast(&onChartLeave), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(self.chart, @ptrCast(motion));
    c.gtk_box_append(@ptrCast(chart_box), self.chart);
    const hint = c.gtk_label_new("Click a folder to drill down. Tile area is proportional to the selected measure.").?;
    c.gtk_label_set_wrap(@ptrCast(hint), 1);
    c.gtk_label_set_xalign(@ptrCast(hint), 0);
    c.gtk_widget_add_css_class(hint, "dim-label");
    c.gtk_box_append(@ptrCast(chart_box), hint);
    c.gtk_paned_set_end_child(@ptrCast(body), chart_box);
    c.gtk_box_append(@ptrCast(page), body);
    return self;
}

pub fn start(tab: *BTab, root: []const u8) void {
    const view = tab.view;
    if (tab.usage != null) forget(tab);
    if (tab.hc.state != .ready) {
        view.setStatusFmt("not connected to {s}", .{tab.hc.label()});
        return;
    }
    const state = createState(tab, root) orelse {
        view.setStatus("cannot open disk usage analyzer: out of memory");
        return;
    };
    tab.usage = state;
    c.gtk_widget_set_visible(tab.listing_box, 0);
    c.gtk_box_append(@ptrCast(tab.page), state.page);
    c.gtk_widget_set_visible(state.page, 1);
    if (view.currentTab() == tab) {
        c.gtk_widget_set_sensitive(view.back_button, 1);
        c.gtk_widget_set_sensitive(view.fwd_button, 0);
    }
    state.render();
    submit(state);
    _ = c.gtk_widget_grab_focus(@ptrCast(@alignCast(state.listbox)));
}

fn submit(self: *State) void {
    self.running = true;
    self.canceling = false;
    self.failed = false;
    self.canceled = false;
    self.interrupted = false;
    self.retention_failed = false;
    self.truncated = false;
    self.result_errors = 0;
    self.result_skipped = 0;
    self.job = 0;
    const pattern: []const u8 = if (c.gtk_check_button_get_active(self.mounts_check) != 0) "all-filesystems" else "";
    self.tab.view.startDaemonJobKind(self.hc, "disk_usage", self.root, "", pattern, "analyze disk usage", .{
        .kind = .disk_usage,
        .tab = self.tab,
    });
}

pub fn forget(tab: *BTab) void {
    const self = tab.usage orelse return;
    tab.usage = null;
    self.tab_alive = false;
    for (tab.view.pending_jobs.items) |pending| {
        if (pending.kind == .disk_usage and pending.tab == tab) pending.tab = null;
    }
    if (self.running and self.job != 0 and self.hc.state == .ready)
        self.tab.view.sendOp(self.hc, .{ .req = self.tab.view.nextReq(), .op = "job_cancel", .job = self.job });
    if (self.render_source != 0) {
        _ = c.g_source_remove(self.render_source);
        self.render_source = 0;
    }
    if (tab.view.widgets_dead) return;
    c.gtk_widget_set_visible(tab.listing_box, 1);
    if (c.gtk_widget_get_parent(self.page)) |parent| c.gtk_box_remove(@ptrCast(parent), self.page);
    if (tab.view.currentTab() == tab) tab.view.syncPathEntry(tab);
}

pub fn started(tab: *BTab, hc: *HostConn, job: u64) bool {
    const self = tab.usage orelse return false;
    if (self.hc != hc or !self.running or self.job != 0) return false;
    self.job = job;
    return true;
}

pub fn startFailed(tab: *BTab, message: []const u8) void {
    const self = tab.usage orelse return;
    self.running = false;
    self.interrupted = false;
    self.failed = true;
    self.setProgressText(if (message.len > 0) message else "The scan could not be started");
    self.render();
}

pub fn hostDied(view: *BrowserView, hc: *HostConn) void {
    for (view.pending_jobs.items) |pending| {
        if (pending.kind == .disk_usage and pending.hc == hc) pending.tab = null;
    }
    for (view.tabs.items) |tab| if (tab.usage) |self| {
        if (self.hc != hc) continue;
        if (!self.running) continue;
        self.running = false;
        self.canceling = false;
        self.canceled = false;
        self.interrupted = true;
        self.failed = true;
        self.job = 0;
        self.setProgressText("Host connection lost; results are incomplete");
        self.render();
    };
}

pub fn rebind(tab: *BTab, hc: *HostConn) void {
    const self = tab.usage orelse return;
    if (self.hc == hc) return;
    self.hc = hc;
    if (!self.interrupted) return;
    self.interrupted = false;
    self.job = 0;
    self.running = false;
    self.canceling = false;
    self.failed = false;
    self.canceled = true;
    self.setProgressText("Host reconnected; rescan to refresh these incomplete results");
    self.render();
}

pub fn consume(view: *BrowserView, hc: *HostConn, event: WireJobEv) bool {
    _ = view;
    const self: *State = for (hc.view.tabs.items) |tab| {
        if (tab.usage) |usage| if (usage.hc == hc and usage.job == event.job and event.job != 0) break usage;
    } else return false;

    if (std.mem.eql(u8, event.ev, "usage")) {
        _ = self.model.upsert(.{
            .path = event.path,
            .kind = event.kind,
            .size = event.size,
            .allocated = event.allocated,
            .items = event.items,
            .errors = event.errors,
            .skipped = event.skipped,
            .mtime_ms = event.mtime_ms,
        }) catch {
            self.running = false;
            self.retention_failed = true;
            self.failed = true;
            self.setProgressText("Not enough memory to retain the scan results");
            if (self.hc.state == .ready)
                self.tab.view.sendOp(self.hc, .{ .req = self.tab.view.nextReq(), .op = "job_cancel", .job = self.job });
            self.render();
            return true;
        };
        if (!self.canceling) self.scheduleRender();
        return true;
    }
    if (std.mem.eql(u8, event.ev, "progress")) {
        self.progress_size = event.done;
        self.progress_allocated = event.total;
        self.progress_items = event.files_done;
        if (event.file.len > 0) {
            self.progress_file_len = @min(event.file.len, self.progress_file.len);
            @memcpy(self.progress_file[0..self.progress_file_len], event.file[0..self.progress_file_len]);
        }
        if (!self.canceling) self.scheduleRender();
        return true;
    }
    if (std.mem.eql(u8, event.ev, "done")) {
        self.running = false;
        self.canceling = false;
        self.canceled = false;
        self.interrupted = false;
        self.truncated = event.truncated;
        self.progress_size = event.size;
        self.progress_allocated = event.allocated;
        self.progress_items = event.items;
        self.result_errors = event.errors;
        self.result_skipped = event.skipped;
        if (event.path.len > 0) _ = self.model.upsert(.{
            .path = event.path,
            .kind = "dir",
            .size = event.size,
            .allocated = event.allocated,
            .items = event.items,
            .errors = event.errors,
            .skipped = event.skipped,
            .mtime_ms = event.mtime_ms,
        }) catch {
            self.retention_failed = true;
            self.failed = true;
            self.truncated = true;
            self.setProgressText("Scan finished, but not enough memory remained to retain all results");
            self.render();
            return true;
        };
        self.render();
        return true;
    }
    if (std.mem.eql(u8, event.ev, "error") or std.mem.eql(u8, event.ev, "canceled")) {
        self.running = false;
        self.interrupted = false;
        self.failed = self.retention_failed or std.mem.eql(u8, event.ev, "error");
        self.canceled = !self.failed;
        self.canceling = false;
        if (self.retention_failed)
            self.setProgressText("Not enough memory to retain the scan results")
        else if (event.message.len > 0)
            self.setProgressText(event.message)
        else if (self.failed)
            self.setProgressText("The scan failed; retained results are incomplete")
        else
            self.setProgressText("Scan canceled; retained results are incomplete");
        self.render();
        return true;
    }
    return false;
}

fn renderHeader(self: *State) void {
    var zbuf: [4096:0]u8 = undefined;
    c.gtk_label_set_text(self.path_label, zText(&zbuf, self.current));
    const base = std.fs.path.basename(self.current);
    c.gtk_label_set_text(self.current_label, zText(&zbuf, if (base.len > 0) base else "/"));
    const total = self.displayedTotal();
    var size_buf: [48:0]u8 = undefined;
    var summary: [320:0]u8 = undefined;
    const node = self.model.get(self.current);
    const items = self.displayedItems() -| 1;
    const errors = if (node) |n| n.errors else if (std.mem.eql(u8, self.current, self.root)) self.result_errors else 0;
    const skipped = if (node) |n| n.skipped else if (std.mem.eql(u8, self.current, self.root)) self.result_skipped else 0;
    const metric_name = if (self.metric == .allocated) "on disk" else "apparent";
    const text = std.fmt.bufPrintSentinel(&summary, "{s} {s} in {d} item(s){s}{s}{s}", .{
        format.fmtSize(&size_buf, total),
        metric_name,
        items,
        if (self.canceling) " - canceling" else if (self.running) " - scanning" else "",
        if (errors > 0) " - unreadable content" else "",
        if (skipped > 0) " - mounted filesystems skipped" else "",
    }, 0) catch "Disk usage";
    c.gtk_label_set_text(self.summary_label, text.ptr);
    if (errors > 0 or skipped > 0 or self.truncated)
        c.gtk_widget_add_css_class(@ptrCast(@alignCast(self.summary_label)), "warning")
    else
        c.gtk_widget_remove_css_class(@ptrCast(@alignCast(self.summary_label)), "warning");
    if (self.failed)
        c.gtk_widget_add_css_class(@ptrCast(@alignCast(self.summary_label)), "error")
    else
        c.gtk_widget_remove_css_class(@ptrCast(@alignCast(self.summary_label)), "error");

    const actively_scanning = self.running and !self.canceling;
    c.gtk_widget_set_visible(@ptrCast(@alignCast(self.spinner)), @intFromBool(actively_scanning));
    if (actively_scanning) c.gtk_spinner_start(self.spinner) else c.gtk_spinner_stop(self.spinner);
    c.gtk_widget_set_visible(self.cancel_button, @intFromBool(actively_scanning));
    c.gtk_widget_set_visible(self.rescan_button, @intFromBool(!self.running or self.canceling));
    c.gtk_widget_set_sensitive(@ptrCast(@alignCast(self.mounts_check)), @intFromBool(!self.running or self.canceling));
    c.gtk_widget_set_sensitive(self.up_button, @intFromBool(!std.mem.eql(u8, self.current, self.root)));

    if (self.canceling) {
        c.gtk_label_set_text(self.progress_label, "Canceling scan...");
    } else if (self.running) {
        var progress: [720:0]u8 = undefined;
        const path = self.progress_file[0..self.progress_file_len];
        const txt = std.fmt.bufPrintSentinel(&progress, "Scanned {d} item(s){s}{s}", .{
            self.progress_items,
            if (path.len > 0) ": " else "",
            path,
        }, 0) catch "Scanning...";
        c.gtk_label_set_text(self.progress_label, txt.ptr);
    } else if (!self.failed and !self.canceled) {
        var complete: [220:0]u8 = undefined;
        const txt = std.fmt.bufPrintSentinel(&complete, "Scan complete: {d} item(s){s}", .{
            self.progress_items -| 1,
            if (self.truncated) "; smaller detail omitted" else "",
        }, 0) catch "Scan complete";
        c.gtk_label_set_text(self.progress_label, txt.ptr);
    }
    if (self.tab.view.currentTab() == self.tab) self.tab.view.setStatus(std.mem.span(c.gtk_label_get_text(self.progress_label)));
}

fn ctxOf(row: *c.GtkWidget) ?*RowCtx {
    const raw = c.g_object_get_data(@ptrCast(row), ROW_QDATA) orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn sortRows(a: *c.GtkListBoxRow, b: *c.GtkListBoxRow, _: ?*anyopaque) callconv(.c) c_int {
    const oa = if (ctxOf(@ptrCast(@alignCast(a)))) |ctx| ctx.order else std.math.maxInt(usize);
    const ob = if (ctxOf(@ptrCast(@alignCast(b)))) |ctx| ctx.order else std.math.maxInt(usize);
    return if (oa < ob) -1 else if (oa > ob) 1 else 0;
}

/// The result row holding keyboard focus, if any.
fn focusedRow(self: *State) ?*c.GtkWidget {
    const lb: *c.GtkWidget = @ptrCast(@alignCast(self.listbox));
    const root = c.gtk_widget_get_root(lb) orelse return null;
    const focused = c.gtk_root_get_focus(root) orelse return null;
    const row = c.gtk_widget_get_ancestor(focused, c.gtk_list_box_row_get_type()) orelse return null;
    return if (c.gtk_widget_get_parent(row) == lb) row else null;
}

/// Bring the list in line with `self.children`: rows still shown keep
/// their widgets (and so their selection, focus and hover) and only
/// rewrite labels whose numbers changed; rows that left are removed and
/// new ones inserted at their sorted place.
fn syncRows(self: *State) void {
    const total = self.displayedTotal();
    const count = @min(self.children.items.len, MAX_ROWS);
    var represented: u64 = 0;
    for (self.children.items[0..count]) |index| represented +|= self.model.nodes.items[index].value(self.metric);
    const remainder = total -| represented;
    const had_focus = focusedRow(self) != null;
    self.syncing = true;
    defer self.syncing = false;

    var it = self.rows.valueIterator();
    while (it.next()) |ctx| ctx.*.seen = false;
    var reorder = false;
    for (self.children.items[0..count], 0..) |index, order| {
        const face = model_mod.nodeFace(self.model.nodes.items[index], self.metric, total);
        reorder = placeRow(self, index, order, face, total) or reorder;
    }
    if (remainder > 0) reorder = placeRow(self, OTHER_ID, count, model_mod.otherFace(remainder, total, self.children.items.len - count), total) or reorder;

    // Rows no longer shown; collected first, the map cannot shrink mid-walk.
    var stale: [64]usize = undefined;
    while (true) {
        var n: usize = 0;
        var walk = self.rows.iterator();
        while (walk.next()) |kv| {
            if (kv.value_ptr.*.seen) continue;
            stale[n] = kv.key_ptr.*;
            n += 1;
            if (n == stale.len) break;
        }
        if (n == 0) break;
        for (stale[0..n]) |id| {
            const ctx = self.rows.fetchRemove(id).?.value;
            c.gtk_list_box_remove(self.listbox, ctx.row);
            self.rows_dropped += 1;
        }
    }
    if (reorder) c.gtk_list_box_invalidate_sort(self.listbox);
    restoreSelection(self);
    // Removing the focused row hands focus to whatever GTK finds next,
    // usually outside the list, and the arrow keys stop working.
    if (had_focus and focusedRow(self) == null) {
        const target: *c.GtkWidget = if (c.gtk_list_box_get_selected_row(self.listbox)) |row|
            @ptrCast(@alignCast(row))
        else if (c.gtk_list_box_get_row_at_index(self.listbox, 0)) |row|
            @ptrCast(@alignCast(row))
        else
            @ptrCast(@alignCast(self.listbox));
        _ = c.gtk_widget_grab_focus(target);
    }
}

/// Show `id` at `order` with `face`, creating its row when it has none.
/// @return whether the list must re-sort.
fn placeRow(self: *State, id: usize, order: usize, face: model_mod.RowFace, total: u64) bool {
    if (self.rows.get(id)) |ctx| {
        ctx.seen = true;
        applyFace(ctx, face, total);
        if (ctx.order == order) return false;
        ctx.order = order;
        return true;
    }
    const ctx = buildRow(self, id, order) orelse return false;
    self.rows.put(self.allocator, id, ctx) catch {
        // Untracked, the row could never be removed again: drop it now.
        c.gtk_list_box_remove(self.listbox, ctx.row);
        return false;
    };
    ctx.seen = true;
    applyFace(ctx, face, total);
    // Inserted at its sorted place, but its neighbours may still carry
    // the previous render's order until the walk reaches them.
    return true;
}

fn fixedLabel(width: c_int, xalign: f32) *c.GtkWidget {
    const label = c.gtk_label_new("").?;
    c.gtk_widget_set_size_request(label, width, -1);
    c.gtk_label_set_xalign(@ptrCast(label), xalign);
    return label;
}

fn buildRow(self: *State, id: usize, order: usize) ?*RowCtx {
    const ctx = self.allocator.create(RowCtx) catch return null;
    const other = id == OTHER_ID;
    const row = c.gtk_list_box_row_new().?;
    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8).?;
    c.gtk_widget_set_margin_start(box, 8);
    c.gtk_widget_set_margin_end(box, 8);
    c.gtk_widget_set_margin_top(box, if (other) 7 else 5);
    c.gtk_widget_set_margin_bottom(box, if (other) 7 else 5);
    const icon = c.gtk_image_new().?;
    c.gtk_box_append(@ptrCast(box), icon);
    const name_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 3).?;
    c.gtk_widget_set_hexpand(name_box, 1);
    const name = c.gtk_label_new("").?;
    c.gtk_label_set_xalign(@ptrCast(name), 0);
    c.gtk_label_set_ellipsize(@ptrCast(name), c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(@ptrCast(name_box), name);
    var bar: ?*c.GtkWidget = null;
    if (other) {
        c.gtk_widget_add_css_class(name, "dim-label");
        c.gtk_image_set_from_icon_name(@ptrCast(icon), "view-more-symbolic");
        // Nothing to open or act on: the remainder is not a target.
        c.gtk_list_box_row_set_activatable(@ptrCast(row), 0);
        c.gtk_list_box_row_set_selectable(@ptrCast(row), 0);
    } else {
        const node = self.model.nodes.items[id];
        var name_z: [1024:0]u8 = undefined;
        c.gtk_label_set_text(@ptrCast(name), zText(&name_z, std.fs.path.basename(node.path)));
        c.gtk_widget_set_tooltip_text(row, zText(&name_z, node.path));
        const b = c.gtk_progress_bar_new().?;
        c.gtk_widget_set_size_request(b, -1, 5);
        c.gtk_box_append(@ptrCast(name_box), b);
        bar = b;
    }
    c.gtk_box_append(@ptrCast(box), name_box);
    const size = fixedLabel(90, 1);
    c.gtk_box_append(@ptrCast(box), size);
    const percent = fixedLabel(58, 1);
    c.gtk_box_append(@ptrCast(box), percent);
    const items = fixedLabel(78, 1);
    c.gtk_box_append(@ptrCast(box), items);
    c.gtk_list_box_row_set_child(@ptrCast(row), box);
    ctx.* = .{
        .allocator = self.allocator,
        .state = self,
        .id = id,
        .order = order,
        .row = row,
        .icon = icon,
        .name = name,
        .bar = bar,
        .size = size,
        .percent = percent,
        .items = items,
    };
    c.g_object_set_data_full(@ptrCast(row), ROW_QDATA, @ptrCast(ctx), @ptrCast(cast.destroyCtx(RowCtx)));
    c.gtk_list_box_append(self.listbox, row);
    self.rows_built += 1;
    return ctx;
}

/// Rewrite a row's widgets, and only when what it prints changed.
fn applyFace(ctx: *RowCtx, face: model_mod.RowFace, total: u64) void {
    if (ctx.face) |old| if (old.eql(face)) return;
    const old = ctx.face;
    ctx.face = face;
    if (!face.other and (old == null or old.?.kind != face.kind)) {
        c.gtk_image_set_from_icon_name(@ptrCast(ctx.icon), switch (face.kind) {
            .dir => "folder-symbolic",
            .mount => "drive-harddisk-symbolic",
            .file => "text-x-generic-symbolic",
        });
        if (face.kind == .mount) c.gtk_widget_add_css_class(ctx.name, "dim-label") else c.gtk_widget_remove_css_class(ctx.name, "dim-label");
    }
    if (face.warning) c.gtk_widget_add_css_class(ctx.name, "warning") else c.gtk_widget_remove_css_class(ctx.name, "warning");
    if (face.other) {
        var label_buf: [96:0]u8 = undefined;
        const text = if (face.omitted > 0)
            std.fmt.bufPrintSentinel(&label_buf, "Other ({d} smaller entries)", .{face.omitted}, 0) catch "Other"
        else
            "Other files and folder metadata";
        c.gtk_label_set_text(@ptrCast(ctx.name), text.ptr);
    }
    if (ctx.bar) |bar| {
        const fraction = if (total > 0) @as(f64, @floatFromInt(face.value)) / @as(f64, @floatFromInt(total)) else 0;
        c.gtk_progress_bar_set_fraction(@ptrCast(bar), std.math.clamp(fraction, 0, 1));
    }
    var size_buf: [48:0]u8 = undefined;
    c.gtk_label_set_text(@ptrCast(ctx.size), format.fmtSize(&size_buf, face.value).ptr);
    var percent_buf: [24:0]u8 = undefined;
    const percent = if (total > 0)
        std.fmt.bufPrintSentinel(&percent_buf, "{d}.{d}%", .{ face.permille / 10, face.permille % 10 }, 0) catch ""
    else
        "";
    c.gtk_label_set_text(@ptrCast(ctx.percent), percent.ptr);
    var items_buf: [40:0]u8 = undefined;
    const items: [*:0]const u8 = if (face.other)
        ""
    else switch (face.kind) {
        .mount => "Not scanned",
        .file => "1",
        .dir => if (std.fmt.bufPrintSentinel(&items_buf, "{d}", .{face.items}, 0)) |t| t.ptr else |_| "",
    };
    c.gtk_label_set_text(@ptrCast(ctx.items), items);
}

/// Select the remembered result when it has a row and nothing else is.
fn restoreSelection(self: *State) void {
    const want = self.selected_path orelse return;
    const id = self.model.indexOf(want) orelse return;
    const ctx = self.rows.get(id) orelse return;
    if (c.gtk_list_box_get_selected_row(self.listbox)) |sel| if (@as(*c.GtkWidget, @ptrCast(@alignCast(sel))) == ctx.row) return;
    c.gtk_list_box_select_row(self.listbox, @ptrCast(@alignCast(ctx.row)));
}

/// Drop every row; their node indices are about to be reassigned.
fn clearRows(self: *State) void {
    self.syncing = true;
    defer self.syncing = false;
    var it = self.rows.valueIterator();
    while (it.next()) |ctx| {
        c.gtk_list_box_remove(self.listbox, ctx.*.row);
        self.rows_dropped += 1;
    }
    self.rows.clearRetainingCapacity();
}

fn onRowSelected(_: *c.GtkListBox, row: ?*c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(State, user);
    if (self.syncing) return;
    // NULL outside a sync is the user deselecting (Ctrl+click).
    const r = row orelse return self.setSelectedPath(null);
    const ctx = ctxOf(@ptrCast(@alignCast(r))) orelse return;
    if (ctx.id == OTHER_ID) return;
    self.setSelectedPath(self.model.nodes.items[ctx.id].path);
}

fn onRenderTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(State, user);
    self.render_source = 0;
    self.render();
    return 0;
}

fn onFilesClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(State, user);
    const tab = self.tab;
    forget(tab);
    tab.view.renderTab(tab);
}

fn onUpClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(State, user);
    _ = self.goUp();
}

fn onCancelClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(State, user);
    if (!self.running or self.job == 0 or self.canceling) return;
    if (!self.tab.view.sendOpOk(self.hc, .{ .req = self.tab.view.nextReq(), .op = "job_cancel", .job = self.job })) return;
    self.canceling = true;
    self.setProgressText("Canceling scan...");
    self.render();
}

fn onRescanClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(State, user);
    if (self.running and !self.canceling) return;
    const root = self.allocator.dupe(u8, self.root) catch null;
    clearRows(self);
    self.model.clear();
    self.trail.truncate(0);
    self.hits.clearRetainingCapacity();
    self.hovered = null;
    self.progress_size = 0;
    self.progress_allocated = 0;
    self.progress_items = 0;
    self.progress_file_len = 0;
    if (root) |path| {
        self.allocator.free(self.current);
        self.current = path;
    }
    submit(self);
    self.render();
}

fn onMetricToggled(button: *c.GtkCheckButton, user: ?*anyopaque) callconv(.c) void {
    if (c.gtk_check_button_get_active(button) == 0) return;
    const self = cast.userData(State, user);
    self.metric = if (button == self.apparent_check) .apparent else .allocated;
    self.render();
}

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, _: ?*anyopaque) callconv(.c) void {
    const ctx = ctxOf(@ptrCast(@alignCast(row))) orelse return;
    if (ctx.id == OTHER_ID) return;
    const node = ctx.state.model.nodes.items[ctx.id];
    if (node.kind == .dir) {
        ctx.state.setCurrent(node.path);
    } else {
        ctx.state.tab.view.setStatusFmt("{s}: {s}", .{ if (node.kind == .mount) "not scanned" else "file", node.path });
    }
}

fn hitAt(self: *State, x: f64, y: f64) ?usize {
    for (self.hits.items) |hit| {
        if (x >= hit.x and y >= hit.y and x < hit.x + hit.w and y < hit.y + hit.h) return hit.id;
    }
    return null;
}

fn onChartPressed(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(State, user);
    const id = hitAt(self, x, y) orelse return;
    if (id == OTHER_ID) return;
    const node = self.model.nodes.items[id];
    if (node.kind == .dir) self.setCurrent(node.path) else self.tab.view.setStatusFmt("file: {s}", .{node.path});
}

fn onChartMotion(_: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(State, user);
    const id = hitAt(self, x, y);
    if (id == self.hovered) return;
    self.hovered = id;
    if (id) |value| {
        if (value == OTHER_ID) {
            c.gtk_widget_set_tooltip_text(self.chart, "Other smaller entries and folder metadata");
        } else {
            const node = self.model.nodes.items[value];
            var size_buf: [48:0]u8 = undefined;
            var tip: [720:0]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&tip, "{s}\n{s}", .{ node.path, format.fmtSize(&size_buf, node.value(self.metric)) }, 0) catch return;
            c.gtk_widget_set_tooltip_text(self.chart, text.ptr);
        }
        c.gtk_widget_set_cursor_from_name(self.chart, "pointer");
    } else {
        c.gtk_widget_set_tooltip_text(self.chart, null);
        c.gtk_widget_set_cursor_from_name(self.chart, "default");
    }
    c.gtk_widget_queue_draw(self.chart);
}

fn onChartLeave(_: *c.GtkEventControllerMotion, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(State, user);
    self.hovered = null;
    c.gtk_widget_set_tooltip_text(self.chart, null);
    c.gtk_widget_set_cursor_from_name(self.chart, "default");
    c.gtk_widget_queue_draw(self.chart);
}

const PALETTE = [_][3]f64{
    .{ 0.89, 0.27, 0.25 },
    .{ 0.96, 0.55, 0.15 },
    .{ 0.91, 0.72, 0.16 },
    .{ 0.22, 0.70, 0.42 },
    .{ 0.20, 0.55, 0.88 },
    .{ 0.48, 0.38, 0.83 },
    .{ 0.76, 0.32, 0.72 },
};

fn drawChart(area: *c.GtkDrawingArea, cr: *c.cairo_t, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(State, user);
    self.hits.clearRetainingCapacity();
    self.model.directChildren(self.current, self.metric, &self.children) catch return;
    const direct_count = @min(self.children.items.len, MAX_TILES - 1);
    var items: [MAX_TILES]model_mod.TreemapItem = undefined;
    var count: usize = 0;
    for (self.children.items[0..direct_count]) |index| {
        const value = self.model.nodes.items[index].value(self.metric);
        if (value == 0) continue;
        items[count] = .{ .id = index, .value = value };
        count += 1;
    }
    const remainder = self.model.unrepresented(self.current, self.metric, self.children.items[0..direct_count]);
    if (remainder > 0 and count < items.len) {
        items[count] = .{ .id = OTHER_ID, .value = remainder };
        count += 1;
    }
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    if (count == 0) {
        var color: c.GdkRGBA = undefined;
        c.gtk_widget_get_color(@ptrCast(area), &color);
        c.cairo_set_source_rgba(cr, color.red, color.green, color.blue, 0.55);
        c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
        c.cairo_set_font_size(cr, 14);
        const message: [*:0]const u8 = if (self.running) "Scanning..." else "No measured contents";
        var extents: c.cairo_text_extents_t = undefined;
        c.cairo_text_extents(cr, message, &extents);
        c.cairo_move_to(cr, (w - extents.width) / 2, h / 2);
        c.cairo_show_text(cr, message);
        return;
    }

    var rects: [MAX_TILES]model_mod.Rect = undefined;
    const laid_out = model_mod.layoutTreemap(items[0..count], .{ .id = 0, .x = 4, .y = 4, .w = @max(0, w - 8), .h = @max(0, h - 8) }, &rects);
    for (rects[0..laid_out]) |rect| {
        const gap: f64 = 2;
        const rx = rect.x + gap;
        const ry = rect.y + gap;
        const rw = @max(0, rect.w - gap * 2);
        const rh = @max(0, rect.h - gap * 2);
        if (rw <= 0 or rh <= 0) continue;
        const palette_index: usize = if (rect.id == OTHER_ID) 0 else @intCast(std.hash.Wyhash.hash(0, self.model.nodes.items[rect.id].path) % PALETTE.len);
        const color = if (rect.id == OTHER_ID) [3]f64{ 0.43, 0.43, 0.47 } else PALETTE[palette_index];
        const highlighted = self.hovered != null and self.hovered.? == rect.id;
        const lift: f64 = if (highlighted) 0.12 else 0;
        c.cairo_set_source_rgb(cr, @min(1, color[0] + lift), @min(1, color[1] + lift), @min(1, color[2] + lift));
        c.cairo_rectangle(cr, rx, ry, rw, rh);
        c.cairo_fill(cr);
        self.hits.append(self.allocator, .{ .id = rect.id, .x = rx, .y = ry, .w = rw, .h = rh }) catch {};
        if (rw < 74 or rh < 34) continue;
        const label = if (rect.id == OTHER_ID) "Other" else std.fs.path.basename(self.model.nodes.items[rect.id].path);
        var label_z: [256:0]u8 = undefined;
        const text = zText(&label_z, label);
        c.cairo_save(cr);
        c.cairo_rectangle(cr, rx + 7, ry + 5, rw - 14, rh - 10);
        c.cairo_clip(cr);
        c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
        c.cairo_set_font_size(cr, 12);
        const luminance = color[0] * 0.299 + color[1] * 0.587 + color[2] * 0.114;
        if (luminance > 0.62) c.cairo_set_source_rgba(cr, 0.05, 0.05, 0.06, 0.92) else c.cairo_set_source_rgba(cr, 1, 1, 1, 0.95);
        c.cairo_move_to(cr, rx + 8, ry + 19);
        c.cairo_show_text(cr, text);
        if (rh >= 52) {
            const value = if (rect.id == OTHER_ID) remainder else self.model.nodes.items[rect.id].value(self.metric);
            var size_buf: [48:0]u8 = undefined;
            c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
            c.cairo_set_font_size(cr, 11);
            c.cairo_move_to(cr, rx + 8, ry + 37);
            c.cairo_show_text(cr, format.fmtSize(&size_buf, value).ptr);
        }
        c.cairo_restore(cr);
    }
}

pub fn goUp(tab: *BTab) bool {
    const self = tab.usage orelse return false;
    return self.goUp();
}

pub fn leave(tab: *BTab) bool {
    if (tab.usage == null) return false;
    forget(tab);
    tab.view.renderTab(tab);
    return true;
}

/// One on-screen analyzer row, for the `browser-usage` verification command.
pub const UsageRow = struct {
    path: []const u8,
    pos: i32,
    x: f64,
    y: f64,
    selected: bool,
};

/// Scan state, scroll, selection, focus and churn counters of a tab's analyzer.
pub const UsageReport = struct {
    running: bool,
    current: []const u8,
    scroll: f64,
    upper: f64,
    page: f64,
    n_rows: u32,
    selected: []const u8,
    focus: []const u8,
    focus_widget: []const u8,
    nodes: usize,
    renders: u64,
    external_renders: u64,
    rows_built: u64,
    rows_dropped: u64,
    rows: []UsageRow,
};

fn rowPath(self: *const State, row: *c.GtkWidget) []const u8 {
    const ctx = ctxOf(row) orelse return "(unknown)";
    if (ctx.id == OTHER_ID) return "(other)";
    return self.model.nodes.items[ctx.id].path;
}

/// The analyzer of `tab` in surface coordinates, null when it has none.
/// @return the report; its strings borrow the analyzer's model and `out`.
pub fn report(tab: *BTab, out: []UsageRow) ?UsageReport {
    const self = tab.usage orelse return null;
    const vadj = c.gtk_scrolled_window_get_vadjustment(@ptrCast(@alignCast(self.scroller)));
    var rep: UsageReport = .{
        .running = self.running,
        .current = self.current,
        .scroll = if (vadj) |a| c.gtk_adjustment_get_value(a) else 0,
        .upper = if (vadj) |a| c.gtk_adjustment_get_upper(a) else 0,
        .page = if (vadj) |a| c.gtk_adjustment_get_page_size(a) else 0,
        .n_rows = 0,
        .selected = "",
        .focus = "",
        .focus_widget = "",
        .nodes = self.model.nodes.items.len,
        .renders = self.renders,
        .external_renders = self.external_renders,
        .rows_built = self.rows_built,
        .rows_dropped = self.rows_dropped,
        .rows = out[0..0],
    };
    if (c.gtk_list_box_get_selected_row(self.listbox)) |row| rep.selected = rowPath(self, @ptrCast(@alignCast(row)));
    const lb: *c.GtkWidget = @ptrCast(@alignCast(self.listbox));
    if (c.gtk_widget_get_root(lb)) |root| if (c.gtk_root_get_focus(root)) |focused| {
        rep.focus_widget = std.mem.span(c.gtk_widget_get_name(focused));
        if (c.gtk_widget_get_ancestor(focused, c.gtk_list_box_row_get_type())) |row| {
            if (c.gtk_widget_get_parent(row) == lb) rep.focus = rowPath(self, row);
        }
    };
    const native = c.gtk_widget_get_native(lb) orelse return rep;
    const nat: *c.GtkWidget = @ptrCast(@alignCast(native));
    var sx: f64 = 0;
    var sy: f64 = 0;
    c.gtk_native_get_surface_transform(native, &sx, &sy);
    var vb: c.graphene_rect_t = undefined;
    const have_viewport = c.gtk_widget_compute_bounds(self.scroller, nat, &vb) != 0;
    var n: usize = 0;
    var child = c.gtk_widget_get_first_child(lb);
    while (child) |row| : (child = c.gtk_widget_get_next_sibling(row)) {
        if (c.gtk_widget_get_visible(row) == 0) continue;
        rep.n_rows += 1;
        if (!have_viewport or n >= out.len or c.gtk_widget_get_mapped(row) == 0) continue;
        var rb: c.graphene_rect_t = undefined;
        if (c.gtk_widget_compute_bounds(row, nat, &rb) == 0) continue;
        const cy = rb.origin.y + rb.size.height / 2;
        if (cy < vb.origin.y or cy > vb.origin.y + vb.size.height) continue;
        out[n] = .{
            .path = rowPath(self, row),
            .pos = c.gtk_list_box_row_get_index(@ptrCast(@alignCast(row))),
            .x = sx + rb.origin.x + @min(rb.size.width / 2, 120),
            .y = sy + cy,
            .selected = c.gtk_list_box_row_is_selected(@ptrCast(@alignCast(row))) != 0,
        };
        n += 1;
    }
    rep.rows = out[0..n];
    return rep;
}
