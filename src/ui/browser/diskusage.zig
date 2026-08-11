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

    fn free(user: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(user.?));
        if (self.tab_alive and self.tab.usage == self) self.tab.usage = null;
        if (self.render_source != 0) _ = c.g_source_remove(self.render_source);
        self.children.deinit(self.allocator);
        self.hits.deinit(self.allocator);
        self.model.deinit();
        self.allocator.free(self.root);
        self.allocator.free(self.current);
        self.allocator.destroy(self);
    }

    fn scheduleRender(self: *State) void {
        if (self.render_source != 0 or self.tab.view.widgets_dead) return;
        self.render_source = c.g_timeout_add(RENDER_DELAY_MS, @ptrCast(&onRenderTick), @ptrCast(self));
    }

    pub fn render(self: *State) void {
        if (self.tab.view.widgets_dead) return;
        self.model.directChildren(self.current, self.metric, &self.children) catch return;
        renderHeader(self);
        renderRows(self);
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

    fn setCurrent(self: *State, path: []const u8) void {
        const fresh = self.allocator.dupe(u8, path) catch return;
        self.allocator.free(self.current);
        self.current = fresh;
        self.hovered = null;
        self.render();
    }

    fn goUp(self: *State) bool {
        if (std.mem.eql(u8, self.current, self.root)) return false;
        const parent = std.fs.path.dirname(self.current) orelse return false;
        if (!withinRoot(self.root, parent)) return false;
        self.setCurrent(parent);
        return true;
    }

    fn setProgressText(self: *State, text: []const u8) void {
        var buf: [640:0]u8 = undefined;
        c.gtk_label_set_text(self.progress_label, zText(&buf, text));
    }
};

const RowCtx = struct {
    allocator: std.mem.Allocator,
    state: *State,
    index: usize,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const self: *RowCtx = @ptrCast(@alignCast(user.?));
        self.allocator.destroy(self);
    }
};

fn withinRoot(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or root.len == 1 or path[root.len] == '/';
}

fn zText(buf: []u8, text: []const u8) [*:0]const u8 {
    const n = @min(buf.len - 1, text.len);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

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
    c.gtk_widget_set_hexpand(scroll, 1);
    c.gtk_widget_set_vexpand(scroll, 1);
    self.listbox = @ptrCast(@alignCast(c.gtk_list_box_new().?));
    c.gtk_list_box_set_selection_mode(self.listbox, c.GTK_SELECTION_SINGLE);
    c.gtk_list_box_set_activate_on_single_click(self.listbox, 1);
    c.gtk_widget_add_css_class(@ptrCast(@alignCast(self.listbox)), "boxed-list");
    _ = c.g_signal_connect_data(self.listbox, "row-activated", @ptrCast(&onRowActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_scrolled_window_set_child(@ptrCast(scroll), @ptrCast(@alignCast(self.listbox)));
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
    const text = std.fmt.bufPrintZ(&summary, "{s} {s} in {d} item(s){s}{s}{s}", .{
        format.fmtSize(&size_buf, total),
        metric_name,
        items,
        if (self.canceling) " - canceling" else if (self.running) " - scanning" else "",
        if (errors > 0) " - unreadable content" else "",
        if (skipped > 0) " - mounted filesystems skipped" else "",
    }) catch "Disk usage";
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
        const txt = std.fmt.bufPrintZ(&progress, "Scanned {d} item(s){s}{s}", .{
            self.progress_items,
            if (path.len > 0) ": " else "",
            path,
        }) catch "Scanning...";
        c.gtk_label_set_text(self.progress_label, txt.ptr);
    } else if (!self.failed and !self.canceled) {
        var complete: [220:0]u8 = undefined;
        const txt = std.fmt.bufPrintZ(&complete, "Scan complete: {d} item(s){s}", .{
            self.progress_items -| 1,
            if (self.truncated) "; smaller detail omitted" else "",
        }) catch "Scan complete";
        c.gtk_label_set_text(self.progress_label, txt.ptr);
    }
    if (self.tab.view.currentTab() == self.tab) self.tab.view.setStatus(std.mem.span(c.gtk_label_get_text(self.progress_label)));
}

fn renderRows(self: *State) void {
    while (c.gtk_widget_get_first_child(@ptrCast(@alignCast(self.listbox)))) |child|
        c.gtk_list_box_remove(self.listbox, @ptrCast(@alignCast(child)));
    const total = self.displayedTotal();
    const count = @min(self.children.items.len, MAX_ROWS);
    for (self.children.items[0..count]) |index| appendNodeRow(self, index, total);
    var represented: u64 = 0;
    for (self.children.items[0..count]) |index| represented +|= self.model.nodes.items[index].value(self.metric);
    const remainder = total -| represented;
    if (remainder > 0) appendOtherRow(self, remainder, total, self.children.items.len - count);
}

fn appendNodeRow(self: *State, index: usize, total: u64) void {
    const node = self.model.nodes.items[index];
    const ctx = self.allocator.create(RowCtx) catch return;
    ctx.* = .{ .allocator = self.allocator, .state = self, .index = index };
    const row = c.gtk_list_box_row_new().?;
    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8).?;
    c.gtk_widget_set_margin_start(box, 8);
    c.gtk_widget_set_margin_end(box, 8);
    c.gtk_widget_set_margin_top(box, 5);
    c.gtk_widget_set_margin_bottom(box, 5);
    const icon_name: [*:0]const u8 = switch (node.kind) {
        .dir => "folder-symbolic",
        .mount => "drive-harddisk-symbolic",
        .file => "text-x-generic-symbolic",
    };
    c.gtk_box_append(@ptrCast(box), c.gtk_image_new_from_icon_name(icon_name));

    const name_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 3).?;
    c.gtk_widget_set_hexpand(name_box, 1);
    const name = c.gtk_label_new("").?;
    var name_z: [1024:0]u8 = undefined;
    c.gtk_label_set_text(@ptrCast(name), zText(&name_z, std.fs.path.basename(node.path)));
    c.gtk_label_set_xalign(@ptrCast(name), 0);
    c.gtk_label_set_ellipsize(@ptrCast(name), c.PANGO_ELLIPSIZE_END);
    if (node.errors > 0) c.gtk_widget_add_css_class(name, "warning");
    if (node.kind == .mount) c.gtk_widget_add_css_class(name, "dim-label");
    c.gtk_box_append(@ptrCast(name_box), name);
    const bar = c.gtk_progress_bar_new().?;
    const value = node.value(self.metric);
    const fraction = if (total > 0) @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(total)) else 0;
    c.gtk_progress_bar_set_fraction(@ptrCast(bar), std.math.clamp(fraction, 0, 1));
    c.gtk_widget_set_size_request(bar, -1, 5);
    c.gtk_box_append(@ptrCast(name_box), bar);
    c.gtk_box_append(@ptrCast(box), name_box);

    var size_buf: [48:0]u8 = undefined;
    const size = c.gtk_label_new(format.fmtSize(&size_buf, value).ptr).?;
    c.gtk_widget_set_size_request(size, 90, -1);
    c.gtk_label_set_xalign(@ptrCast(size), 1);
    c.gtk_box_append(@ptrCast(box), size);
    var percent_buf: [24:0]u8 = undefined;
    const percent_text = if (total > 0) std.fmt.bufPrintZ(&percent_buf, "{d:.1}%", .{fraction * 100}) catch "" else "";
    const percent = c.gtk_label_new(percent_text.ptr).?;
    c.gtk_widget_set_size_request(percent, 58, -1);
    c.gtk_label_set_xalign(@ptrCast(percent), 1);
    c.gtk_box_append(@ptrCast(box), percent);
    var items_buf: [40:0]u8 = undefined;
    var item_text: [*:0]const u8 = "1";
    if (node.kind == .mount) {
        item_text = "Not scanned";
    } else if (node.kind == .dir) {
        if (std.fmt.bufPrintZ(&items_buf, "{d}", .{node.items -| 1})) |text|
            item_text = text.ptr
        else |_|
            item_text = "";
    }
    const items = c.gtk_label_new(item_text).?;
    c.gtk_widget_set_size_request(items, 78, -1);
    c.gtk_label_set_xalign(@ptrCast(items), 1);
    c.gtk_box_append(@ptrCast(box), items);
    c.gtk_list_box_row_set_child(@ptrCast(row), box);
    c.gtk_widget_set_tooltip_text(row, zText(&name_z, node.path));
    c.g_object_set_data_full(@ptrCast(row), ROW_QDATA, @ptrCast(ctx), @ptrCast(&RowCtx.free));
    c.gtk_list_box_append(self.listbox, row);
}

fn appendOtherRow(self: *State, value: u64, total: u64, omitted: usize) void {
    const row = c.gtk_list_box_row_new().?;
    c.gtk_list_box_row_set_activatable(@ptrCast(row), 0);
    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8).?;
    c.gtk_widget_set_margin_start(box, 8);
    c.gtk_widget_set_margin_end(box, 8);
    c.gtk_widget_set_margin_top(box, 7);
    c.gtk_widget_set_margin_bottom(box, 7);
    c.gtk_box_append(@ptrCast(box), c.gtk_image_new_from_icon_name("view-more-symbolic"));
    var label_buf: [96:0]u8 = undefined;
    const label_text = if (omitted > 0)
        std.fmt.bufPrintZ(&label_buf, "Other ({d} smaller entries)", .{omitted}) catch "Other"
    else
        std.fmt.bufPrintZ(&label_buf, "Other files and folder metadata", .{}) catch "Other";
    const label = c.gtk_label_new(label_text.ptr).?;
    c.gtk_label_set_xalign(@ptrCast(label), 0);
    c.gtk_widget_set_hexpand(label, 1);
    c.gtk_widget_add_css_class(label, "dim-label");
    c.gtk_box_append(@ptrCast(box), label);
    var size_buf: [48:0]u8 = undefined;
    const size = c.gtk_label_new(format.fmtSize(&size_buf, value).ptr).?;
    c.gtk_widget_set_size_request(size, 90, -1);
    c.gtk_label_set_xalign(@ptrCast(size), 1);
    c.gtk_box_append(@ptrCast(box), size);
    var percent_buf: [24:0]u8 = undefined;
    const fraction = if (total > 0) @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(total)) else 0;
    const pct = std.fmt.bufPrintZ(&percent_buf, "{d:.1}%", .{fraction * 100}) catch "";
    const percent = c.gtk_label_new(pct.ptr).?;
    c.gtk_widget_set_size_request(percent, 58, -1);
    c.gtk_label_set_xalign(@ptrCast(percent), 1);
    c.gtk_box_append(@ptrCast(box), percent);
    const blank = c.gtk_label_new("").?;
    c.gtk_widget_set_size_request(blank, 78, -1);
    c.gtk_box_append(@ptrCast(box), blank);
    c.gtk_list_box_row_set_child(@ptrCast(row), box);
    c.gtk_list_box_append(self.listbox, row);
}

fn onRenderTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *State = @ptrCast(@alignCast(user.?));
    self.render_source = 0;
    self.render();
    return 0;
}

fn onFilesClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *State = @ptrCast(@alignCast(user.?));
    const tab = self.tab;
    forget(tab);
    tab.view.renderTab(tab);
}

fn onUpClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *State = @ptrCast(@alignCast(user.?));
    _ = self.goUp();
}

fn onCancelClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *State = @ptrCast(@alignCast(user.?));
    if (!self.running or self.job == 0 or self.canceling) return;
    if (!self.tab.view.sendOpOk(self.hc, .{ .req = self.tab.view.nextReq(), .op = "job_cancel", .job = self.job })) return;
    self.canceling = true;
    self.setProgressText("Canceling scan...");
    self.render();
}

fn onRescanClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *State = @ptrCast(@alignCast(user.?));
    if (self.running and !self.canceling) return;
    const root = self.allocator.dupe(u8, self.root) catch null;
    self.model.clear();
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
    const self: *State = @ptrCast(@alignCast(user.?));
    self.metric = if (button == self.apparent_check) .apparent else .allocated;
    self.render();
}

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, _: ?*anyopaque) callconv(.c) void {
    const raw = c.g_object_get_data(@ptrCast(row), ROW_QDATA) orelse return;
    const ctx: *RowCtx = @ptrCast(@alignCast(raw));
    const node = ctx.state.model.nodes.items[ctx.index];
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
    const self: *State = @ptrCast(@alignCast(user.?));
    const id = hitAt(self, x, y) orelse return;
    if (id == OTHER_ID) return;
    const node = self.model.nodes.items[id];
    if (node.kind == .dir) self.setCurrent(node.path) else self.tab.view.setStatusFmt("file: {s}", .{node.path});
}

fn onChartMotion(_: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self: *State = @ptrCast(@alignCast(user.?));
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
            const text = std.fmt.bufPrintZ(&tip, "{s}\n{s}", .{ node.path, format.fmtSize(&size_buf, node.value(self.metric)) }) catch return;
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
    const self: *State = @ptrCast(@alignCast(user.?));
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
    const self: *State = @ptrCast(@alignCast(user.?));
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

test "disk usage root containment rejects sibling prefixes" {
    try std.testing.expect(withinRoot("/srv/data", "/srv/data/a"));
    try std.testing.expect(withinRoot("/", "/var"));
    try std.testing.expect(!withinRoot("/srv/data", "/srv/database"));
}
