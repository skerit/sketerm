//! User sidebar widgets: small labelled things the user pins into the
//! places sidebar — static titles/text, the output of a shell command
//! (optionally re-run on an interval), an image, or a sparkline graph
//! of a command's numeric output.
//!
//! The model (`Store`) is deliberately independent of the sidebar so
//! the same widget definitions can be rendered elsewhere later; only
//! `renderSection` and the editor forms know about the places list.
//! Commands run on the LOCAL machine (the GUI host), never on a
//! remote tab's host.

const std = @import("std");
const c = @import("../../c.zig").c;
const places_mod = @import("../../filebrowser/places.zig");
const strz = @import("../../util/strz.zig");

const BrowserView = @import("view.zig").BrowserView;
const places_ui = @import("places.zig");
const cast = @import("../../util/cast.zig");

pub const Kind = enum {
    title,
    text,
    command,
    image,
    graph,

    pub fn fromString(s: []const u8) Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return .title;
    }

    pub fn name(self: Kind) [:0]const u8 {
        return switch (self) {
            .title => "title",
            .text => "text",
            .command => "command",
            .image => "image",
            .graph => "graph",
        };
    }
};

pub const Widget = struct {
    kind: Kind = .title,
    text: []u8 = &.{},
    command: []u8 = &.{},
    path: []u8 = &.{},
    interval_secs: u32 = 0,

    fn deinit(self: *Widget, a: std.mem.Allocator) void {
        if (self.text.len > 0) a.free(self.text);
        if (self.command.len > 0) a.free(self.command);
        if (self.path.len > 0) a.free(self.path);
    }
};

pub const Section = struct {
    name: []u8,
    widgets: std.ArrayList(Widget) = .empty,

    fn deinit(self: *Section, a: std.mem.Allocator) void {
        a.free(self.name);
        for (self.widgets.items) |*w| w.deinit(a);
        self.widgets.deinit(a);
    }
};

/// Owned widget-section model, loaded from and saved with places.json.
pub const Store = struct {
    sections: std.ArrayList(Section) = .empty,

    pub fn deinit(self: *Store, a: std.mem.Allocator) void {
        for (self.sections.items) |*s| s.deinit(a);
        self.sections.deinit(a);
    }

    pub fn loadFrom(self: *Store, a: std.mem.Allocator, parsed: []const places_mod.WidgetSection) void {
        for (parsed) |ps| {
            if (ps.name.len == 0) continue;
            const sec_name = a.dupe(u8, ps.name) catch continue;
            var sec = Section{ .name = sec_name };
            for (ps.widgets) |pw| {
                const w = Widget{
                    .kind = Kind.fromString(pw.kind),
                    .text = if (pw.text.len > 0) a.dupe(u8, pw.text) catch &.{} else &.{},
                    .command = if (pw.command.len > 0) a.dupe(u8, pw.command) catch &.{} else &.{},
                    .path = if (pw.path.len > 0) a.dupe(u8, pw.path) catch &.{} else &.{},
                    .interval_secs = pw.interval_secs,
                };
                sec.widgets.append(a, w) catch {
                    var wm = w;
                    wm.deinit(a);
                };
            }
            self.sections.append(a, sec) catch sec.deinit(a);
        }
    }

    /// Wire form for places.save; slices borrow from the store, the
    /// nested arrays live in `arena`.
    pub fn toPlaces(self: *const Store, arena: std.mem.Allocator) []const places_mod.WidgetSection {
        const out = arena.alloc(places_mod.WidgetSection, self.sections.items.len) catch return &.{};
        for (self.sections.items, 0..) |sec, i| {
            const ws = arena.alloc(places_mod.Widget, sec.widgets.items.len) catch return &.{};
            for (sec.widgets.items, 0..) |w, j| {
                ws[j] = .{
                    .kind = w.kind.name(),
                    .text = w.text,
                    .command = w.command,
                    .path = w.path,
                    .interval_secs = w.interval_secs,
                };
            }
            out[i] = .{ .name = sec.name, .widgets = ws };
        }
        return out;
    }

    pub fn sectionByName(self: *Store, name: []const u8) ?*Section {
        for (self.sections.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }
};

// ── runtime: command output + graph history + refresh timers ─────

const HISTORY_CAP = 64;
/// Command output shown in the sidebar is a snippet, not a pager.
const OUTPUT_CAP = 2048;

/// Live state for one command/graph widget. Heap-allocated so timer
/// and async-subprocess callbacks have a stable pointer; ownership is
/// handed to the in-flight callback when the runtime resets under it.
pub const Run = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    /// "section-name\x00widget-index" — identity across re-renders.
    key: []u8,
    command: []u8,
    interval_secs: u32,
    graph: bool,
    output: []u8 = &.{},
    history: [HISTORY_CAP]f64 = undefined,
    hist_len: usize = 0,
    fetched: bool = false,
    fetching: bool = false,
    timer: c.guint = 0,
    /// The runtime dropped this entry while a fetch was in flight;
    /// the completion callback frees it.
    orphaned: bool = false,

    fn destroy(self: *Run) void {
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        if (self.output.len > 0) self.allocator.free(self.output);
        self.allocator.free(self.key);
        self.allocator.free(self.command);
        self.allocator.destroy(self);
    }
};

pub fn runKey(a: std.mem.Allocator, section: []const u8, index: usize) ?[]u8 {
    return std.fmt.allocPrint(a, "{s}\x00{d}", .{ section, index }) catch null;
}

/// The Run for a widget, created (and its first fetch kicked) on
/// first sight. Returns null for kinds with no runtime.
fn ensureRun(self: *BrowserView, section: *Section, index: usize, w: *const Widget) ?*Run {
    if (w.kind != .command and w.kind != .graph) return null;
    var kbuf: [300]u8 = undefined;
    const want = std.fmt.bufPrint(&kbuf, "{s}\x00{d}", .{ section.name, index }) catch return null;
    for (self.widget_runs.items) |run| {
        if (std.mem.eql(u8, run.key, want)) {
            // An edited command is a different widget in the same slot.
            if (!std.mem.eql(u8, run.command, w.command) or run.interval_secs != w.interval_secs) {
                dropRun(self, run);
                break;
            }
            return run;
        }
    }
    const a = self.allocator;
    const run = a.create(Run) catch return null;
    const key = a.dupe(u8, want) catch {
        a.destroy(run);
        return null;
    };
    const cmd = a.dupe(u8, w.command) catch {
        a.free(key);
        a.destroy(run);
        return null;
    };
    run.* = .{
        .allocator = a,
        .view = self,
        .key = key,
        .command = cmd,
        .interval_secs = w.interval_secs,
        .graph = w.kind == .graph,
    };
    self.widget_runs.append(a, run) catch {
        run.destroy();
        return null;
    };
    startFetch(run);
    if (run.interval_secs > 0)
        run.timer = c.g_timeout_add_seconds(run.interval_secs, @ptrCast(&onRefreshTick), @ptrCast(run));
    return run;
}

fn dropRun(self: *BrowserView, run: *Run) void {
    for (self.widget_runs.items, 0..) |r, i| {
        if (r != run) continue;
        _ = self.widget_runs.orderedRemove(i);
        break;
    }
    if (run.fetching) {
        if (run.timer != 0) _ = c.g_source_remove(run.timer);
        run.timer = 0;
        run.orphaned = true; // the async callback frees it
    } else {
        run.destroy();
    }
}

/// Kill every runtime entry (view teardown or a widget-model edit —
/// indices moved, so identities are stale wholesale).
pub fn resetRuns(self: *BrowserView) void {
    while (self.widget_runs.items.len > 0) {
        dropRun(self, self.widget_runs.items[self.widget_runs.items.len - 1]);
    }
}

fn onRefreshTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const run = cast.userData(Run, user);
    if (!run.fetching) startFetch(run);
    return 1; // keep the interval armed
}

fn startFetch(run: *Run) void {
    if (run.fetching or run.command.len == 0) return;
    var z: [4096:0]u8 = undefined;
    const n = @min(run.command.len, z.len - 1);
    @memcpy(z[0..n], run.command[0..n]);
    z[n] = 0;
    const sub = c.g_subprocess_new(
        c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_SILENCE,
        null,
        "/bin/sh",
        "-c",
        &z,
        @as(?[*:0]const u8, null),
    ) orelse return;
    run.fetching = true;
    c.g_subprocess_communicate_utf8_async(sub, null, null, @ptrCast(&onFetchDone), @ptrCast(run));
}

fn onFetchDone(source: ?*c.GObject, res: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const run = cast.userData(Run, user);
    const sub: *c.GSubprocess = @ptrCast(@alignCast(source.?));
    defer c.g_object_unref(sub);
    var stdout_c: ?[*:0]u8 = null;
    _ = c.g_subprocess_communicate_utf8_finish(sub, res, @ptrCast(&stdout_c), null, null);
    run.fetching = false;
    if (run.orphaned) {
        if (stdout_c) |s| c.g_free(@ptrCast(s));
        run.destroy();
        return;
    }
    run.fetched = true;
    const a = run.allocator;
    if (stdout_c) |s| {
        defer c.g_free(@ptrCast(s));
        var out = std.mem.trim(u8, std.mem.span(s), " \r\n\t");
        if (out.len > OUTPUT_CAP) out = out[0..OUTPUT_CAP];
        const owned = a.dupe(u8, out) catch return;
        if (run.output.len > 0) a.free(run.output);
        run.output = owned;
        if (run.graph) recordSample(run, out);
    }
    const view = run.view;
    if (!view.widgets_dead and view.places_on) view.renderPlaces();
}

/// Graph widgets plot the FIRST number found on the output's first
/// line ("42", "42.5%", "load: 1.20" all work).
fn recordSample(run: *Run, out: []const u8) void {
    const line = out[0 .. std.mem.indexOfScalar(u8, out, '\n') orelse out.len];
    var start: usize = 0;
    while (start < line.len and !isNumStart(line[start])) start += 1;
    if (start >= line.len) return;
    var end = start;
    while (end < line.len and isNumChar(line[end])) end += 1;
    const v = std.fmt.parseFloat(f64, line[start..end]) catch return;
    if (run.hist_len == HISTORY_CAP) {
        std.mem.copyForwards(f64, run.history[0 .. HISTORY_CAP - 1], run.history[1..]);
        run.hist_len -= 1;
    }
    run.history[run.hist_len] = v;
    run.hist_len += 1;
}

fn isNumStart(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or ch == '-' or ch == '.';
}

fn isNumChar(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or ch == '.' or ch == '-' or ch == 'e' or ch == 'E' or ch == '+';
}

// ── rendering ────────────────────────────────────────────────────

/// Render one widget section into the places list (header + rows).
pub fn renderSection(self: *BrowserView, section: *Section) void {
    var tz: [160:0]u8 = undefined;
    const tn = @min(section.name.len, tz.len - 1);
    @memcpy(tz[0..tn], section.name[0..tn]);
    tz[tn] = 0;
    places_ui.placeHeader(self, &tz);
    if (places_ui.sectionCollapsed(self, tz[0..tn])) return;
    for (section.widgets.items, 0..) |*w, i| {
        appendWidgetRow(self, section, w, i);
    }
}

/// Ctx string a widget row carries so the sidebar right-click can
/// resolve it: "widget:<section-index>:<widget-index>".
fn widgetSpec(self: *BrowserView, section: *Section, index: usize, buf: []u8) ?[]const u8 {
    for (self.widgets.sections.items, 0..) |*s, si| {
        if (s == section)
            return std.fmt.bufPrint(buf, "widget:{d}:{d}", .{ si, index }) catch null;
    }
    return null;
}

fn appendWidgetRow(self: *BrowserView, section: *Section, w: *const Widget, index: usize) void {
    const body: ?*c.GtkWidget = switch (w.kind) {
        .title => buildTitle(w),
        .text => buildText(w),
        .command => buildCommand(self, section, w, index),
        .image => buildImage(w),
        .graph => buildGraph(self, section, w, index),
    };
    const child = body orelse return;
    const row = c.gtk_list_box_row_new();
    c.gtk_list_box_row_set_activatable(@ptrCast(row), 0);
    c.gtk_list_box_row_set_child(@ptrCast(row), child);
    var spec_buf: [64]u8 = undefined;
    const spec = widgetSpec(self, section, index, &spec_buf) orelse "";
    const ctx = self.allocator.create(places_ui.PlaceCtx) catch return;
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .spec = self.allocator.dupe(u8, spec) catch {
            self.allocator.destroy(ctx);
            return;
        },
        .is_bookmark = false,
    };
    c.g_object_set_data_full(@ptrCast(row), "sketerm-place", @ptrCast(ctx), @ptrCast(&places_ui.PlaceCtx.free));
    c.gtk_list_box_append(self.places_list, row);
}

fn buildTitle(w: *const Widget) ?*c.GtkWidget {
    var z: [512:0]u8 = undefined;
    const lab = c.gtk_label_new(strz.copyZ(&z, w.text));
    c.gtk_label_set_xalign(@ptrCast(lab), 0);
    c.gtk_label_set_ellipsize(@ptrCast(lab), c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_add_css_class(lab, "heading");
    c.gtk_widget_set_margin_start(lab, 10);
    c.gtk_widget_set_margin_end(lab, 10);
    c.gtk_widget_set_margin_top(lab, 4);
    return lab;
}

fn buildText(w: *const Widget) ?*c.GtkWidget {
    var z: [512:0]u8 = undefined;
    const lab = c.gtk_label_new(strz.copyZ(&z, w.text));
    c.gtk_label_set_xalign(@ptrCast(lab), 0);
    c.gtk_label_set_wrap(@ptrCast(lab), 1);
    c.gtk_widget_add_css_class(lab, "dim-label");
    c.gtk_widget_set_margin_start(lab, 10);
    c.gtk_widget_set_margin_end(lab, 10);
    return lab;
}

/// Caption (the widget's `text`, when set) above the command output.
fn buildCommand(self: *BrowserView, section: *Section, w: *const Widget, index: usize) ?*c.GtkWidget {
    const run = ensureRun(self, section, index, w);
    const vbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    c.gtk_widget_set_margin_start(vbox, 10);
    c.gtk_widget_set_margin_end(vbox, 10);
    appendCaption(vbox, w.text);
    var z: [OUTPUT_CAP + 8:0]u8 = undefined;
    const out: []const u8 = if (run) |r|
        (if (r.fetched) r.output else "…")
    else
        "…";
    const n = @min(out.len, z.len - 1);
    @memcpy(z[0..n], out[0..n]);
    z[n] = 0;
    const lab = c.gtk_label_new(&z);
    c.gtk_label_set_xalign(@ptrCast(lab), 0);
    c.gtk_label_set_wrap(@ptrCast(lab), 1);
    c.gtk_label_set_selectable(@ptrCast(lab), 0);
    c.gtk_widget_add_css_class(lab, "monospace");
    c.gtk_widget_add_css_class(lab, "caption");
    c.gtk_box_append(@ptrCast(vbox), lab);
    return vbox;
}

fn appendCaption(vbox: *c.GtkWidget, text: []const u8) void {
    if (text.len == 0) return;
    var z: [512:0]u8 = undefined;
    const cap = c.gtk_label_new(strz.copyZ(&z, text));
    c.gtk_label_set_xalign(@ptrCast(cap), 0);
    c.gtk_widget_add_css_class(cap, "dim-label");
    c.gtk_widget_add_css_class(cap, "caption");
    c.gtk_box_append(@ptrCast(vbox), cap);
}

fn buildImage(w: *const Widget) ?*c.GtkWidget {
    if (w.path.len == 0) return null;
    var z: [4096:0]u8 = undefined;
    const n = @min(w.path.len, z.len - 1);
    @memcpy(z[0..n], w.path[0..n]);
    z[n] = 0;
    const pic = c.gtk_picture_new_for_filename(&z);
    c.gtk_picture_set_content_fit(@ptrCast(pic), c.GTK_CONTENT_FIT_CONTAIN);
    c.gtk_picture_set_can_shrink(@ptrCast(pic), 1);
    c.gtk_widget_set_size_request(pic, -1, 24);
    // Bounded: a huge wallpaper must not eat the sidebar.
    var natural: c.GtkRequisition = undefined;
    c.gtk_widget_get_preferred_size(pic, null, &natural);
    if (natural.height > 140) c.gtk_widget_set_size_request(pic, -1, 140);
    c.gtk_widget_set_margin_start(pic, 10);
    c.gtk_widget_set_margin_end(pic, 10);
    c.gtk_widget_set_margin_top(pic, 2);
    return pic;
}

/// Heap samples for one sparkline draw (owned by the drawing area).
const GraphCtx = struct {
    allocator: std.mem.Allocator,
    samples: []f64,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const g = cast.userData(GraphCtx, user);
        g.allocator.free(g.samples);
        g.allocator.destroy(g);
    }
};

fn buildGraph(self: *BrowserView, section: *Section, w: *const Widget, index: usize) ?*c.GtkWidget {
    const run = ensureRun(self, section, index, w);
    const vbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    c.gtk_widget_set_margin_start(vbox, 10);
    c.gtk_widget_set_margin_end(vbox, 10);
    appendCaption(vbox, w.text);
    const area = c.gtk_drawing_area_new();
    c.gtk_drawing_area_set_content_height(@ptrCast(area), 36);
    c.gtk_widget_set_hexpand(area, 1);
    const g = self.allocator.create(GraphCtx) catch return vbox;
    const count = if (run) |r| r.hist_len else 0;
    g.* = .{
        .allocator = self.allocator,
        .samples = self.allocator.dupe(f64, if (run) |r| r.history[0..count] else &.{}) catch {
            self.allocator.destroy(g);
            return vbox;
        },
    };
    c.gtk_drawing_area_set_draw_func(@ptrCast(area), @ptrCast(&drawGraph), @ptrCast(g), @ptrCast(&GraphCtx.free));
    c.gtk_box_append(@ptrCast(vbox), area);
    // The latest value, readable without squinting at the line.
    if (run) |r| {
        if (r.hist_len > 0) {
            var vz: [64:0]u8 = undefined;
            if (std.fmt.bufPrintZ(&vz, "{d:.6}", .{trimFloat(r.history[r.hist_len - 1])})) |txt| {
                const lab = c.gtk_label_new(trimZeros(&vz, txt));
                c.gtk_label_set_xalign(@ptrCast(lab), 0);
                c.gtk_widget_add_css_class(lab, "caption");
                c.gtk_widget_add_css_class(lab, "dim-label");
                c.gtk_box_append(@ptrCast(vbox), lab);
            } else |_| {}
        }
    }
    return vbox;
}

fn trimFloat(v: f64) f64 {
    return v;
}

/// "1.200000" → "1.2", "42.000000" → "42".
fn trimZeros(buf: *[64:0]u8, txt: []u8) [*:0]const u8 {
    var end = txt.len;
    if (std.mem.indexOfScalar(u8, txt, '.') != null) {
        while (end > 0 and buf[end - 1] == '0') end -= 1;
        if (end > 0 and buf[end - 1] == '.') end -= 1;
    }
    buf[end] = 0;
    return buf;
}

fn drawGraph(area: *c.GtkDrawingArea, cr: *c.cairo_t, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) void {
    const g = cast.userData(GraphCtx, user);
    var color: c.GdkRGBA = undefined;
    c.gtk_widget_get_color(@ptrCast(area), &color);
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    // Faint baseline box so an empty graph is still visibly a graph.
    c.cairo_set_source_rgba(cr, color.red, color.green, color.blue, 0.15);
    c.cairo_rectangle(cr, 0.5, 0.5, w - 1, h - 1);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
    if (g.samples.len < 2) return;
    var lo = g.samples[0];
    var hi = g.samples[0];
    for (g.samples) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    const span = if (hi - lo < 1e-9) 1.0 else hi - lo;
    c.cairo_set_source_rgba(cr, color.red, color.green, color.blue, 0.8);
    c.cairo_set_line_width(cr, 1.5);
    for (g.samples, 0..) |v, i| {
        const x = 2 + (w - 4) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(g.samples.len - 1));
        const y = h - 3 - (h - 6) * (v - lo) / span;
        if (i == 0) c.cairo_move_to(cr, x, y) else c.cairo_line_to(cr, x, y);
    }
    c.cairo_stroke(cr);
}

// ── editing (forms + mutations, wired from the sidebar menu) ─────

/// Persist the model and rebuild both the runtime (identities moved)
/// and the sidebar.
fn commitEdit(self: *BrowserView) void {
    resetRuns(self);
    _ = self.savePlaces();
    if (self.places_on) self.renderPlaces();
}

pub fn addSection(self: *BrowserView, name: []const u8) void {
    if (name.len == 0) return;
    if (self.widgets.sectionByName(name) != null) {
        self.setStatus("a widget section with that name exists");
        return;
    }
    const owned = self.allocator.dupe(u8, name) catch return;
    self.widgets.sections.append(self.allocator, .{ .name = owned }) catch {
        self.allocator.free(owned);
        return;
    };
    commitEdit(self);
}

pub fn removeSection(self: *BrowserView, si: usize) void {
    if (si >= self.widgets.sections.items.len) return;
    var sec = self.widgets.sections.orderedRemove(si);
    sec.deinit(self.allocator);
    commitEdit(self);
}

pub fn removeWidget(self: *BrowserView, si: usize, wi: usize) void {
    if (si >= self.widgets.sections.items.len) return;
    const sec = &self.widgets.sections.items[si];
    if (wi >= sec.widgets.items.len) return;
    var w = sec.widgets.orderedRemove(wi);
    w.deinit(self.allocator);
    commitEdit(self);
}

pub fn moveWidget(self: *BrowserView, si: usize, wi: usize, up: bool) void {
    if (si >= self.widgets.sections.items.len) return;
    const sec = &self.widgets.sections.items[si];
    const items = sec.widgets.items;
    if (wi >= items.len) return;
    if (up) {
        if (wi == 0) return;
        std.mem.swap(Widget, &items[wi], &items[wi - 1]);
    } else {
        if (wi + 1 >= items.len) return;
        std.mem.swap(Widget, &items[wi], &items[wi + 1]);
    }
    commitEdit(self);
}

/// The add/edit form. One window, five fields; which fields apply per
/// kind is explained inline rather than dynamically hidden (simpler,
/// and the form stays put while you switch kinds).
const FormCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    section_index: usize,
    /// Editing an existing widget; null = adding.
    widget_index: ?usize,
    window: *c.GtkWidget,
    kind_drop: *c.GtkWidget,
    text_entry: *c.GtkWidget,
    command_entry: *c.GtkWidget,
    path_entry: *c.GtkWidget,
    interval_spin: *c.GtkWidget,
};

const kind_labels = [_:null]?[*:0]const u8{ "Title", "Text", "Command output", "Image", "Graph (command)" };
const kind_values = [_]Kind{ .title, .text, .command, .image, .graph };

pub fn openWidgetForm(self: *BrowserView, si: usize, wi: ?usize) void {
    if (si >= self.widgets.sections.items.len) return;
    const sec = &self.widgets.sections.items[si];
    const editing: ?*Widget = if (wi) |i|
        (if (i < sec.widgets.items.len) &sec.widgets.items[i] else return)
    else
        null;

    const win = c.gtk_window_new();
    c.gtk_window_set_title(@ptrCast(win), if (editing != null) "Edit Widget" else "Add Widget");
    c.gtk_window_set_modal(@ptrCast(win), 1);
    c.gtk_window_set_default_size(@ptrCast(win), 420, -1);
    if (c.gtk_widget_get_root(self.root_box)) |root|
        c.gtk_window_set_transient_for(@ptrCast(win), @ptrCast(@alignCast(root)));

    const grid = c.gtk_grid_new();
    c.gtk_grid_set_row_spacing(@ptrCast(grid), 8);
    c.gtk_grid_set_column_spacing(@ptrCast(grid), 10);
    c.gtk_widget_set_margin_start(grid, 14);
    c.gtk_widget_set_margin_end(grid, 14);
    c.gtk_widget_set_margin_top(grid, 14);
    c.gtk_widget_set_margin_bottom(grid, 14);

    const kind_drop = c.gtk_drop_down_new_from_strings(@ptrCast(@constCast(&kind_labels)));
    const text_entry = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(text_entry), "label / caption");
    const command_entry = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(command_entry), "shell command (runs locally)");
    const path_entry = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(path_entry), "/path/to/image.png");
    const interval_spin = c.gtk_spin_button_new_with_range(0, 86400, 5);
    c.gtk_widget_set_tooltip_text(interval_spin, "Re-run seconds for command/graph output; 0 = once");

    if (editing) |w| {
        for (kind_values, 0..) |k, i| {
            if (k == w.kind) c.gtk_drop_down_set_selected(@ptrCast(kind_drop), @intCast(i));
        }
        setEntryText(text_entry, w.text);
        setEntryText(command_entry, w.command);
        setEntryText(path_entry, w.path);
        c.gtk_spin_button_set_value(@ptrCast(interval_spin), @floatFromInt(w.interval_secs));
    }

    formRow(grid, 0, "Kind", kind_drop);
    formRow(grid, 1, "Text", text_entry);
    formRow(grid, 2, "Command", command_entry);
    formRow(grid, 3, "Image file", path_entry);
    formRow(grid, 4, "Refresh (s)", interval_spin);

    const btnbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_halign(btnbox, c.GTK_ALIGN_END);
    const cancel = c.gtk_button_new_with_label("Cancel");
    const save = c.gtk_button_new_with_label(if (editing != null) "Save" else "Add");
    c.gtk_widget_add_css_class(save, "suggested-action");
    c.gtk_box_append(@ptrCast(btnbox), cancel);
    c.gtk_box_append(@ptrCast(btnbox), save);
    c.gtk_grid_attach(@ptrCast(grid), btnbox, 0, 5, 2, 1);

    const ctx = self.allocator.create(FormCtx) catch {
        c.gtk_window_destroy(@ptrCast(win));
        return;
    };
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .section_index = si,
        .widget_index = wi,
        .window = win,
        .kind_drop = kind_drop,
        .text_entry = text_entry,
        .command_entry = command_entry,
        .path_entry = path_entry,
        .interval_spin = interval_spin,
    };
    c.g_object_set_data_full(@ptrCast(win), "sketerm-widget-form", @ptrCast(ctx), @ptrCast(cast.destroyCtx(FormCtx)));
    _ = c.g_signal_connect_data(cancel, "clicked", @ptrCast(&onFormCancel), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(save, "clicked", @ptrCast(&onFormSave), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);

    c.gtk_window_set_child(@ptrCast(win), grid);
    c.gtk_window_present(@ptrCast(win));
}

fn formRow(grid: *c.GtkWidget, row: c_int, label: [*:0]const u8, field: *c.GtkWidget) void {
    const lab = c.gtk_label_new(label);
    c.gtk_label_set_xalign(@ptrCast(lab), 1);
    c.gtk_widget_add_css_class(lab, "dim-label");
    c.gtk_grid_attach(@ptrCast(grid), lab, 0, row, 1, 1);
    c.gtk_widget_set_hexpand(field, 1);
    c.gtk_grid_attach(@ptrCast(grid), field, 1, row, 1, 1);
}

fn setEntryText(entry: *c.GtkWidget, text: []const u8) void {
    var z: [4096:0]u8 = undefined;
    const n = @min(text.len, z.len - 1);
    @memcpy(z[0..n], text[0..n]);
    z[n] = 0;
    c.gtk_editable_set_text(@ptrCast(entry), &z);
}

fn onFormCancel(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(FormCtx, user);
    c.gtk_window_destroy(@ptrCast(ctx.window));
}

fn onFormSave(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(FormCtx, user);
    const self = ctx.view;
    const a = self.allocator;
    if (ctx.section_index >= self.widgets.sections.items.len) {
        c.gtk_window_destroy(@ptrCast(ctx.window));
        return;
    }
    const sec = &self.widgets.sections.items[ctx.section_index];
    const sel = c.gtk_drop_down_get_selected(@ptrCast(ctx.kind_drop));
    const kind = if (sel < kind_values.len) kind_values[sel] else .title;
    const text = std.mem.span(c.gtk_editable_get_text(@ptrCast(ctx.text_entry)));
    const command = std.mem.span(c.gtk_editable_get_text(@ptrCast(ctx.command_entry)));
    const path = std.mem.span(c.gtk_editable_get_text(@ptrCast(ctx.path_entry)));
    const interval: u32 = @intFromFloat(@max(0, c.gtk_spin_button_get_value(@ptrCast(ctx.interval_spin))));
    var w = Widget{
        .kind = kind,
        .text = if (text.len > 0) a.dupe(u8, text) catch &.{} else &.{},
        .command = if (command.len > 0) a.dupe(u8, command) catch &.{} else &.{},
        .path = if (path.len > 0) a.dupe(u8, path) catch &.{} else &.{},
        .interval_secs = interval,
    };
    if (ctx.widget_index) |wi| {
        if (wi < sec.widgets.items.len) {
            sec.widgets.items[wi].deinit(a);
            sec.widgets.items[wi] = w;
        } else w.deinit(a);
    } else {
        sec.widgets.append(a, w) catch w.deinit(a);
    }
    c.gtk_window_destroy(@ptrCast(ctx.window));
    commitEdit(self);
}
