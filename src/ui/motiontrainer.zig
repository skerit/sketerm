//! The motion trainer: the ONLY way a motion pack is recorded
//! (`sketerm motion record`, palette "Record Motion Pack"). A native GTK
//! window, so it records the DEVICE: device timestamps from
//! `gdk_event_get_time`, coalesced samples from `gdk_event_get_history`,
//! the device class from the event's device.
//!
//! Four sections (`recorder.Section`): reaches (click the targets),
//! typing (only key timing per key class is kept, the prompted text is
//! discarded), scrolling (wheel bursts while reading a story) and idle
//! drift, each with its own goal. Ctrl+S (or Save) validates and installs
//! the pack into `$XDG_DATA_HOME/sketerm/motion-packs/`; a pack can be
//! saved at any point and continued later.
//!
//! Work is never lost to one failure: a refused Save writes nothing and
//! keeps the recording here, an autosaved draft survives a crash, and
//! closing with unsaved items asks first.
//!
//! All recording logic is `src/motion/recorder.zig`; this file only
//! feeds it events. One heap context, owned by the window's qdata; every
//! dialog callback holds a window ref and resolves the context through
//! the qdata (the `editorwin.zig` close-confirm shape).

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const recorder = @import("../motion/recorder.zig");
const pack_mod = @import("../motion/pack.zig");
const store = @import("../motion/store.zig");
const reading = @import("../motion/reading.zig");
const confirm = @import("confirm.zig");
const atomicwrite = @import("../util/atomicwrite.zig");

const Section = recorder.Section;

const QDATA = "sketerm-motion-trainer";
const IDLE_SECONDS = 8;
/// New items between two autosaved drafts (also written on a page switch).
const DRAFT_EVERY = 20;
const RECORDER = "sketerm " ++ @import("../version.zig").string;

const WORDS = [_][]const u8{
    "river",   "pocket",  "window",  "gentle", "orange", "silver",  "market", "planet",  "summer", "candle",
    "garden",  "bridge",  "forest",  "letter", "copper", "winter",  "travel", "harbor",  "mirror", "pepper",
    "quickly", "measure", "between", "number", "simple", "public",  "office", "machine", "yellow", "jacket",
    "zebra",   "volume",  "kettle",  "lizard", "sphinx", "quartz",  "jovial", "wizard",  "fjord",  "blanket",
};

/// A stack page: its name, switcher title and the explanation on top.
const Page = struct { name: [*:0]const u8, title: []const u8, about: [*:0]const u8 };

fn page(s: Section) Page {
    return switch (s) {
        .reaches => .{
            .name = "reach",
            .title = "Reaches",
            .about = std.fmt.comptimePrint(
                "Click each magenta target the way you normally would. This records how your hand brings the pointer onto something and clicks; replayed clicks (web_act with motion \"replay\") are drawn from it, so this section is needed for them. " ++
                    "One reach in each of the {d} target cells completes it, it is usable from {d} reaches, and you can save at any point and continue later. A miss is fine: that reach starts again from where you clicked.",
                .{ recorder.CELLS, recorder.USABLE_REACHES },
            ),
        },
        .typing => .{
            .name = "typing",
            .title = "Typing",
            .about = "Type the words shown and press Enter. Only how long each key is held and the time between keys is kept, by where the key sits on the keyboard; the text itself is discarded. Needed for replayed typing (web_act set_value).",
        },
        .scrolling => .{
            .name = "scroll",
            .title = "Scrolling",
            .about = "Read the story below at your own pace, scrolling with the wheel or touchpad the way you always do. Only the scroll deltas and their timing are kept, never what you read. Needed for replayed scrolling (web_scroll).",
        },
        .idle => .{
            .name = "idle",
            .title = "Idle drift",
            .about = std.fmt.comptimePrint("Press Start, then leave your hand resting on the pointer for {d} seconds without trying to move it. This records the small drift of a resting hand. Needed only for idle drift (web_open idle_drift).", .{IDLE_SECONDS}),
        },
    };
}

pub const Options = struct {
    /// Installed pack name for Save; empty = `my-<device>`.
    name: []const u8 = "",
    /// Also write the pack to this file on Save.
    out: ?[]const u8 = null,
};

/// What an open question is about; one question at a time.
const Ask = enum { restore, continue_pack, cannot_continue, replace, close, blocked };

const Status = enum { info, err, ok };

const Trainer = struct {
    allocator: std.mem.Allocator,
    window: *c.GtkWidget,
    session: recorder.Session,
    prng: std.Random.DefaultPrng,
    name_entry: *c.GtkWidget,
    out: ?[]u8,
    mode_line: *c.GtkWidget,
    device_line: *c.GtkWidget,
    lines: std.EnumArray(Section, *c.GtkWidget),
    pages: std.EnumArray(Section, ?*c.GtkStackPage) = .initFill(null),
    /// Sections whose switcher title says "(done)".
    done: std.EnumSet(Section) = .initEmpty(),
    meter: *c.GtkWidget,
    meter_label: *c.GtkWidget,
    status: *c.GtkWidget,
    stack: *c.GtkWidget,
    area: *c.GtkWidget,
    prompt: *c.GtkWidget,
    entry: *c.GtkWidget,
    idle_label: *c.GtkWidget,
    idle_timer: c.guint = 0,
    target: ?recorder.Target = null,
    ptr: [2]f64 = .{ 0, 0 },
    have_ptr: bool = false,
    last_t: f64 = 0,
    missed: bool = false,
    /// The status shows why a reach was not kept; the next kept one clears it.
    reach_note: bool = false,
    /// A press from another device class was ignored: so is its release.
    foreign_press: bool = false,
    device_switch: bool = false,
    /// Some event carried a device timestamp.
    timed_seen: bool = false,
    /// Untimed events seen before any timed one.
    untimed: u8 = 0,
    /// The session cannot take this display's input (clock mismatch with
    /// the pack it continues); nothing is recorded until resolved.
    blocked: bool = false,

    /// The installed pack this session continues: saving to it adds.
    continues: NameBuf = .{},
    /// A name whose installed pack the user agreed to replace.
    replace_ok: NameBuf = .{},
    /// The last name a restore/continue question was considered for.
    offered: NameBuf = .{},
    /// Where the autosaved draft lives, and how many unsaved items it holds.
    draft_name: NameBuf = .{},
    draft_unsaved: usize = 0,
    asking: ?Ask = null,
    ask_name: NameBuf = .{},
    close_after_save: bool = false,
    force_close: bool = false,
    destroyed: bool = false,
};

/// A pack name held by value (`pack.validName` caps it at 64).
const NameBuf = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn get(self: *const NameBuf) ?[]const u8 {
        return if (self.len > 0) self.buf[0..self.len] else null;
    }

    fn is(self: *const NameBuf, name: []const u8) bool {
        return self.len > 0 and std.mem.eql(u8, self.buf[0..self.len], name);
    }

    fn set(self: *NameBuf, name: []const u8) void {
        self.len = @min(name.len, self.buf.len);
        @memcpy(self.buf[0..self.len], name[0..self.len]);
    }

    fn clear(self: *NameBuf) void {
        self.len = 0;
    }
};

/// Untimed events before the first timed one after which the display is
/// taken to stamp nothing at all.
const UNTIMED_LIMIT: u8 = 8;

/// An event's time in ms on the session's ONE clock, or null for an
/// event that carries no device sample. GTK synthesizes motion with
/// time 0 on every compositor (a hover refresh after a redraw, the
/// crossing that follows an enter), so a 0 while the display stamps its
/// real events is skipped, never a reason to change clocks. Only a
/// display that stamps NOTHING (`UNTIMED_LIMIT` untimed events before any
/// timed one) moves the session to arrival time, for good: one session's
/// samples must never mix two clocks, so a session continuing a
/// device-clock pack is blocked instead.
fn eventMs(self: *Trainer, device_ms: u32) ?f64 {
    if (self.blocked) return null;
    if (self.session.clock == .arrival) return arrivalMs();
    if (device_ms != 0) {
        self.timed_seen = true;
        return @floatFromInt(device_ms);
    }
    if (self.timed_seen) return null;
    self.untimed += 1;
    if (self.untimed < UNTIMED_LIMIT) return null;
    self.session.useArrivalClock() catch {
        block(self);
        return null;
    };
    return arrivalMs();
}

/// `eventMs` for a press, release, key or scroll, which the session must
/// see even when untimed: it then takes the last sample's time. Null only
/// while blocked.
fn discreteMs(self: *Trainer, device_ms: u32) ?f64 {
    if (self.blocked) return null;
    return eventMs(self, device_ms) orelse self.last_t;
}

fn arrivalMs() f64 {
    return @as(f64, @floatFromInt(c.g_get_monotonic_time())) / 1000.0;
}

/// Open the trainer window (on `app` when given, transient for `parent`).
pub fn open(allocator: std.mem.Allocator, app: ?*c.GtkApplication, parent: ?*c.GtkWindow, opts: Options) void {
    const self = allocator.create(Trainer) catch return;
    var seed: u64 = undefined;
    if (c.getentropy(&seed, @sizeOf(u64)) != 0) seed = @intCast(c.g_get_monotonic_time());
    const window = c.adw_window_new() orelse {
        allocator.destroy(self);
        return;
    };
    self.* = .{
        .allocator = allocator,
        .window = window,
        .session = recorder.Session.init(allocator),
        .prng = std.Random.DefaultPrng.init(seed),
        .name_entry = c.gtk_entry_new(),
        .out = if (opts.out) |o| allocator.dupe(u8, o) catch null else null,
        .mode_line = c.gtk_label_new(""),
        .device_line = c.gtk_label_new(""),
        .lines = undefined,
        .meter = c.gtk_level_bar_new_for_interval(0, 1),
        .meter_label = c.gtk_label_new(""),
        .status = c.gtk_label_new("Pick a section above. Save (Ctrl+S) whenever you like: a pack can be saved before it is complete and continued later."),
        .stack = c.gtk_stack_new(),
        .area = c.gtk_drawing_area_new(),
        .prompt = c.gtk_label_new(""),
        .entry = c.gtk_entry_new(),
        .idle_label = c.gtk_label_new(""),
    };
    for (std.enums.values(Section)) |s| {
        const l = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(l), 0);
        c.gtk_label_set_wrap(@ptrCast(l), 1);
        self.lines.set(s, l);
    }
    self.session.recorder = RECORDER;
    self.session.created = isoNow(self.session.arena.allocator());
    c.g_object_set_data_full(@ptrCast(window), QDATA, @ptrCast(self), @ptrCast(&freeTrainer));
    _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(window, "close-request", @ptrCast(&onCloseRequest), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

    c.gtk_window_set_title(@ptrCast(window), "Record Motion Pack");
    c.gtk_window_set_default_size(@ptrCast(window), 1100, 820);
    if (parent) |p| c.gtk_window_set_transient_for(@ptrCast(window), p);
    if (app) |a| c.gtk_window_set_application(@ptrCast(window), a);

    const toolbar = c.adw_toolbar_view_new().?;
    const header = c.adw_header_bar_new().?;
    const switcher = c.gtk_stack_switcher_new();
    c.gtk_stack_switcher_set_stack(@ptrCast(switcher), @ptrCast(self.stack));
    c.adw_header_bar_set_title_widget(@ptrCast(header), switcher);
    const save_btn = c.gtk_button_new_with_label("Save and install");
    c.gtk_widget_add_css_class(save_btn, "suggested-action");
    c.gtk_widget_set_tooltip_text(save_btn, "Ctrl+S");
    _ = c.g_signal_connect_data(save_btn, "clicked", @ptrCast(&onSaveClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.adw_header_bar_pack_end(@ptrCast(header), save_btn);
    c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar), header);

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
    c.gtk_widget_set_margin_start(root, 14);
    c.gtk_widget_set_margin_end(root, 14);
    c.gtk_widget_set_margin_top(root, 8);
    c.gtk_widget_set_margin_bottom(root, 10);

    // The pack: its name and what saving will do.
    const pack_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_box_append(@ptrCast(pack_row), c.gtk_label_new("Pack name:"));
    if (opts.name.len > 0) {
        var nb: [80]u8 = undefined;
        const nz = std.fmt.bufPrintZ(&nb, "{s}", .{opts.name[0..@min(opts.name.len, 64)]}) catch "";
        c.gtk_editable_set_text(@ptrCast(self.name_entry), nz.ptr);
    }
    c.gtk_entry_set_placeholder_text(@ptrCast(self.name_entry), "my-mouse");
    c.gtk_widget_set_tooltip_text(self.name_entry, "Empty: my-<device>. Press Enter to continue an installed pack of this name.");
    _ = c.g_signal_connect_data(self.name_entry, "activate", @ptrCast(&onNameActivate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(self.name_entry, "changed", @ptrCast(&onNameChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(pack_row), self.name_entry);
    c.gtk_label_set_xalign(@ptrCast(self.mode_line), 0);
    c.gtk_label_set_wrap(@ptrCast(self.mode_line), 1);
    c.gtk_widget_set_hexpand(self.mode_line, 1);
    c.gtk_box_append(@ptrCast(pack_row), self.mode_line);
    c.gtk_box_append(@ptrCast(root), pack_row);

    c.gtk_label_set_xalign(@ptrCast(self.device_line), 0);
    c.gtk_label_set_wrap(@ptrCast(self.device_line), 1);
    c.gtk_box_append(@ptrCast(root), self.device_line);
    for (self.lines.values) |l| c.gtk_box_append(@ptrCast(root), l);
    c.gtk_label_set_wrap(@ptrCast(self.status), 1);
    c.gtk_label_set_xalign(@ptrCast(self.status), 0);
    c.gtk_widget_set_margin_top(self.status, 4);
    c.gtk_box_append(@ptrCast(root), self.status);

    // Reaches.
    const reach = pageBox(.reaches);
    const meter_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_hexpand(self.meter, 1);
    c.gtk_box_append(@ptrCast(meter_row), self.meter);
    c.gtk_box_append(@ptrCast(meter_row), self.meter_label);
    c.gtk_box_append(@ptrCast(reach), meter_row);
    c.gtk_widget_set_hexpand(self.area, 1);
    c.gtk_widget_set_vexpand(self.area, 1);
    c.gtk_drawing_area_set_draw_func(@ptrCast(self.area), @ptrCast(&drawArea), @ptrCast(self), null);
    addMotion(self.area, self, &onReachMotion);
    const click = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(click), 1);
    _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&onPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(click, "released", @ptrCast(&onReleased), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(self.area, @ptrCast(click));
    c.gtk_box_append(@ptrCast(reach), self.area);
    addPage(self, .reaches, reach);

    // Typing.
    const typing = pageBox(.typing);
    const typing_body = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 10);
    c.gtk_widget_set_valign(typing_body, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_vexpand(typing_body, 1);
    c.gtk_widget_add_css_class(self.prompt, "title-2");
    c.gtk_box_append(@ptrCast(typing_body), self.prompt);
    c.gtk_box_append(@ptrCast(typing_body), self.entry);
    c.gtk_box_append(@ptrCast(typing), typing_body);
    const keys = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKeyPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(keys, "key-released", @ptrCast(&onKeyReleased), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(self.entry, @ptrCast(keys));
    _ = c.g_signal_connect_data(self.entry, "activate", @ptrCast(&onPromptDone), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    newPrompt(self);
    addPage(self, .typing, typing);

    // Scrolling.
    const scrolling = pageBox(.scrolling);
    const scroller = buildReader(self);
    const wheel = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    c.gtk_event_controller_set_propagation_phase(@ptrCast(wheel), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(wheel, "scroll", @ptrCast(&onScroll), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(scroller, @ptrCast(wheel));
    c.gtk_box_append(@ptrCast(scrolling), scroller);
    addPage(self, .scrolling, scrolling);

    // Idle drift.
    const idle = pageBox(.idle);
    c.gtk_label_set_wrap(@ptrCast(self.idle_label), 1);
    c.gtk_box_append(@ptrCast(idle), self.idle_label);
    const idle_btn = c.gtk_button_new_with_label("Start (" ++ std.fmt.comptimePrint("{d}", .{IDLE_SECONDS}) ++ " s)");
    c.gtk_widget_set_halign(idle_btn, c.GTK_ALIGN_CENTER);
    _ = c.g_signal_connect_data(idle_btn, "clicked", @ptrCast(&onIdleStart), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(idle), idle_btn);
    const idle_space = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_vexpand(idle_space, 1);
    c.gtk_box_append(@ptrCast(idle), idle_space);
    addMotion(idle, self, &onPlainMotion);
    addPage(self, .idle, idle);

    c.gtk_widget_set_vexpand(self.stack, 1);
    c.gtk_box_append(@ptrCast(root), self.stack);
    _ = c.g_signal_connect_data(self.stack, "notify::visible-child", @ptrCast(&onPageSwitch), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

    const shortcuts = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(shortcuts), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(shortcuts, "key-pressed", @ptrCast(&onWindowKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(window, @ptrCast(shortcuts));

    c.adw_toolbar_view_set_content(@ptrCast(toolbar), root);
    c.adw_window_set_content(@ptrCast(window), toolbar);
    refresh(self);
    c.gtk_window_present(@ptrCast(window));
    if (opts.name.len > 0) offer(self, opts.name);
}

/// A stack page: a vertical box headed by the section's explanation.
fn pageBox(s: Section) *c.GtkWidget {
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8);
    c.gtk_widget_set_margin_top(box, 6);
    const about = c.gtk_label_new(page(s).about);
    c.gtk_label_set_wrap(@ptrCast(about), 1);
    c.gtk_label_set_xalign(@ptrCast(about), 0);
    c.gtk_widget_add_css_class(about, "dim-label");
    c.gtk_box_append(@ptrCast(box), about);
    return box;
}

fn addPage(self: *Trainer, s: Section, child: *c.GtkWidget) void {
    var tb: [48]u8 = undefined;
    const title = std.fmt.bufPrintZ(&tb, "{s}", .{page(s).title}) catch "";
    self.pages.set(s, c.gtk_stack_add_titled(@ptrCast(self.stack), child, page(s).name, title.ptr));
}

/// The scrolling page's reading: one story, picked at random, at a
/// comfortable measure and size.
fn buildReader(self: *Trainer) *c.GtkWidget {
    const scroller = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_vexpand(scroller, 1);
    const view = c.gtk_text_view_new();
    c.gtk_text_view_set_editable(@ptrCast(view), 0);
    c.gtk_text_view_set_cursor_visible(@ptrCast(view), 0);
    c.gtk_text_view_set_wrap_mode(@ptrCast(view), c.GTK_WRAP_WORD_CHAR);
    c.gtk_text_view_set_left_margin(@ptrCast(view), 24);
    c.gtk_text_view_set_right_margin(@ptrCast(view), 24);
    c.gtk_text_view_set_top_margin(@ptrCast(view), 24);
    c.gtk_text_view_set_bottom_margin(@ptrCast(view), 64);
    const clamp = c.adw_clamp_new();
    c.adw_clamp_set_maximum_size(@ptrCast(clamp), 760);
    c.adw_clamp_set_child(@ptrCast(clamp), view);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), clamp);

    const buffer = c.gtk_text_view_get_buffer(@ptrCast(view)) orelse return scroller;
    const nul: [*c]const u8 = null;
    _ = c.gtk_text_buffer_create_tag(buffer, "title", "weight", @as(c_int, c.PANGO_WEIGHT_BOLD), "scale", @as(f64, 1.9), "pixels-below-lines", @as(c_int, 6), nul);
    _ = c.gtk_text_buffer_create_tag(buffer, "byline", "style", @as(c_int, c.PANGO_STYLE_ITALIC), "scale", @as(f64, 1.25), "pixels-below-lines", @as(c_int, 24), nul);
    _ = c.gtk_text_buffer_create_tag(buffer, "para", "scale", @as(f64, 1.25), "pixels-below-lines", @as(c_int, 14), nul);
    const story = reading.get(self.prng.random().uintLessThan(usize, reading.count())) orelse return scroller;
    var iter: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_end_iter(buffer, &iter);
    insertLine(buffer, &iter, story.title, "title");
    var by: [128]u8 = undefined;
    insertLine(buffer, &iter, std.fmt.bufPrint(&by, "by {s}", .{story.author}) catch story.author, "byline");
    var it = story.paragraphs();
    while (it.next()) |p| insertLine(buffer, &iter, p, "para");
    return scroller;
}

fn insertLine(buffer: *c.GtkTextBuffer, iter: *c.GtkTextIter, text: []const u8, tag: [*:0]const u8) void {
    const nul: [*c]const u8 = null;
    c.gtk_text_buffer_insert_with_tags_by_name(buffer, iter, text.ptr, @intCast(text.len), tag, nul);
    c.gtk_text_buffer_insert(buffer, iter, "\n", 1);
}

fn freeTrainer(user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Trainer, user);
    self.session.deinit();
    if (self.out) |o| self.allocator.free(o);
    self.allocator.destroy(self);
}

fn onDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Trainer, user);
    self.destroyed = true;
    if (self.idle_timer != 0) _ = c.g_source_remove(self.idle_timer);
    self.idle_timer = 0;
}

/// The trainer behind `window`, or null once it is being torn down.
fn trainerOf(window: *c.GtkWidget) ?*Trainer {
    const raw = c.g_object_get_data(@ptrCast(window), QDATA) orelse return null;
    const self: *Trainer = @ptrCast(@alignCast(raw));
    return if (self.destroyed) null else self;
}

fn isoNow(a: std.mem.Allocator) []const u8 {
    const now = c.g_date_time_new_now_utc() orelse return "";
    defer c.g_date_time_unref(now);
    const s = c.g_date_time_format_iso8601(now);
    if (s == null) return "";
    defer c.g_free(s);
    return a.dupe(u8, std.mem.span(s)) catch "";
}

fn addMotion(widget: *c.GtkWidget, self: *Trainer, comptime cb: anytype) void {
    const motion = c.gtk_event_controller_motion_new();
    _ = c.g_signal_connect_data(motion, "motion", @ptrCast(cb), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(widget, @ptrCast(motion));
}

/// Feed one motion event and its coalesced history (device times)
/// into the session; `x`/`y` are widget coordinates.
fn feedMotion(self: *Trainer, ctl: ?*c.GtkEventController, x: f64, y: f64) void {
    const ev = c.gtk_event_controller_get_current_event(ctl) orelse return;
    if (self.blocked or !noteDevice(self, ev)) return;
    // History coordinates are surface-relative: shift them by the
    // event's own surface position against its widget position.
    var sx: f64 = 0;
    var sy: f64 = 0;
    const has_pos = c.gdk_event_get_position(ev, &sx, &sy) != 0;
    var n: c.guint = 0;
    const hist = c.gdk_event_get_history(ev, &n);
    const device_clock = c.gdk_event_get_time(ev) != 0 and self.session.clock == .device;
    if (hist != null and has_pos and device_clock) {
        defer c.g_free(hist);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const h = hist[i];
            const hx = h.axes[c.GDK_AXIS_X] - sx + x;
            const hy = h.axes[c.GDK_AXIS_Y] - sy + y;
            self.session.motion(@floatFromInt(h.time), hx, hy) catch {};
        }
    }
    if (hist != null and !(has_pos and device_clock)) c.g_free(hist);
    self.ptr = .{ x, y };
    self.have_ptr = true;
    const t = eventMs(self, c.gdk_event_get_time(ev)) orelse return;
    self.session.motion(t, x, y) catch {};
    self.last_t = t;
}

/// Note the pointer device class of `ev`. False when it is not the
/// class this session records: that event must be ignored.
fn noteDevice(self: *Trainer, ev: *c.GdkEvent) bool {
    const dev = c.gdk_event_get_device(ev) orelse return true;
    const cls: pack_mod.Device = switch (c.gdk_device_get_source(dev)) {
        c.GDK_SOURCE_MOUSE => .mouse,
        c.GDK_SOURCE_TOUCHPAD => .touchpad,
        c.GDK_SOURCE_PEN => .pen,
        else => return true,
    };
    const first = self.session.device == .unknown;
    self.session.useDevice(cls, @floatFromInt(@max(c.gtk_widget_get_scale_factor(self.window), 1))) catch {
        if (!self.device_switch) {
            self.device_switch = true;
            setStatus(self, .err, "A {s} moved, but this pack records a {s}: a pack holds ONE pointing device. Input from the {s} is ignored; keep using the {s}, or record a separate pack for the {s}.", .{
                @tagName(cls), @tagName(self.session.device), @tagName(cls), @tagName(self.session.device), @tagName(cls),
            });
        }
        return false;
    };
    if (first) {
        var nb: [80]u8 = undefined;
        const def = std.fmt.bufPrintZ(&nb, "my-{s}", .{@tagName(cls)}) catch return true;
        c.gtk_entry_set_placeholder_text(@ptrCast(self.name_entry), def.ptr);
        if (std.mem.span(c.gtk_editable_get_text(@ptrCast(self.name_entry))).len == 0) offer(self, def);
    }
    return true;
}

fn onPlainMotion(ctl: ?*c.GtkEventController, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    feedMotion(cast.userData(Trainer, user), ctl, x, y);
}

fn onReachMotion(ctl: ?*c.GtkEventController, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Trainer, user);
    feedMotion(self, ctl, x, y);
    if (self.target == null) spawnTarget(self);
    refresh(self);
}

fn spawnTarget(self: *Trainer) void {
    const w: f64 = @floatFromInt(c.gtk_widget_get_width(self.area));
    const h: f64 = @floatFromInt(c.gtk_widget_get_height(self.area));
    if (w < 50 or h < 50 or !self.have_ptr or self.blocked) return;
    const tg = self.session.coverage.next(self.ptr, w, h, self.prng.random()) orelse return;
    self.target = tg;
    self.session.beginReach(self.last_t, self.ptr, tg) catch {};
    c.gtk_widget_queue_draw(self.area);
}

/// Take the target down (page switch): its reach is not finished.
fn dropTarget(self: *Trainer) void {
    self.session.cancelReach();
    self.target = null;
    self.missed = false;
    c.gtk_widget_queue_draw(self.area);
}

fn onPressed(gesture: ?*c.GtkGestureClick, n: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    _ = n;
    const self = cast.userData(Trainer, user);
    if (c.gtk_event_controller_get_current_event(@ptrCast(gesture))) |ev| {
        self.foreign_press = !noteDevice(self, ev);
        if (self.foreign_press) return;
    }
    const t = discreteMs(self, c.gtk_event_controller_get_current_event_time(@ptrCast(gesture))) orelse return;
    if (self.target == null) return;
    self.missed = !self.session.press(t, x, y);
}

fn onReleased(gesture: ?*c.GtkGestureClick, n: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    _ = n;
    const self = cast.userData(Trainer, user);
    if (self.foreign_press) {
        self.foreign_press = false;
        return;
    }
    const t = discreteMs(self, c.gtk_event_controller_get_current_event_time(@ptrCast(gesture))) orelse return;
    self.ptr = .{ x, y };
    self.last_t = t;
    const tg = self.target orelse return;
    if (self.missed) {
        // A miss restarts the reach from here; the detour is not motion
        // anyone should replay.
        self.missed = false;
        self.session.beginReach(t, self.ptr, tg) catch {};
        refresh(self);
        return;
    }
    const outcome = self.session.release(t) catch return;
    switch (outcome) {
        .none => return,
        .kept => if (self.reach_note) {
            self.reach_note = false;
            setStatus(self, .info, "Reach kept. Click each target as you naturally would.", .{});
        },
        // The press was inside this target, so restarting it from here
        // would be a reach of no length: a new target is shown instead.
        .refused => |why| {
            self.reach_note = true;
            setStatus(self, .err, "That reach was not kept ({s}). Nothing else is affected; click the next target.", .{why});
        },
        .full => setStatus(self, .err, "This pack holds the most reaches a pack can ({d}); further reaches are not recorded.", .{pack_mod.MAX_REACHES}),
    }
    self.target = null;
    spawnTarget(self);
    refresh(self);
    maybeDraft(self, false);
}

/// The target color is pure magenta so a test rig can find it in a
/// screenshot without any other channel.
fn drawArea(_: *c.GtkDrawingArea, cr: *c.cairo_t, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Trainer, user);
    c.cairo_set_source_rgb(cr, 0.13, 0.13, 0.15);
    c.cairo_rectangle(cr, 0, 0, @floatFromInt(width), @floatFromInt(height));
    c.cairo_fill(cr);
    if (self.target) |tg| {
        c.cairo_set_source_rgb(cr, 1, 0, 1);
        c.cairo_rectangle(cr, tg.x, tg.y, tg.w, tg.h);
        c.cairo_fill(cr);
    } else {
        c.cairo_set_source_rgb(cr, 0.8, 0.8, 0.8);
        c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
        c.cairo_set_font_size(cr, 16);
        c.cairo_move_to(cr, 20, 30);
        c.cairo_show_text(cr, "Move the pointer here to start; click each target that appears.");
    }
}

fn newPrompt(self: *Trainer) void {
    const rng = self.prng.random();
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const n = 2 + rng.uintLessThan(usize, 4);
    for (0..n) |i| {
        if (i > 0) w.writeByte(' ') catch break;
        const word = WORDS[rng.uintLessThan(usize, WORDS.len)];
        if (i == 0 and rng.boolean()) {
            w.writeByte(std.ascii.toUpper(word[0])) catch break;
            w.writeAll(word[1..]) catch break;
        } else w.writeAll(word) catch break;
    }
    w.writeByte(0) catch {};
    c.gtk_label_set_text(@ptrCast(self.prompt), @ptrCast(w.buffered().ptr));
}

fn isModifier(keyval: c.guint) bool {
    return keyval >= 0xffe1 and keyval <= 0xffee;
}

fn onKeyPressed(ctl: ?*c.GtkEventControllerKey, keyval: c.guint, keycode: c.guint, _: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Trainer, user);
    if (isModifier(keyval) or keyval == 0xff0d) return 0;
    const t = discreteMs(self, c.gtk_event_controller_get_current_event_time(@ptrCast(ctl))) orelse return 0;
    const cp = c.gdk_keyval_to_unicode(keyval);
    const cls: pack_mod.KeyClass = if (cp == 0 or cp > 0x10ffff) .other else pack_mod.KeyClass.of(@intCast(cp));
    self.session.keyDown(t, keycode, cls) catch {};
    return 0;
}

fn onKeyReleased(ctl: ?*c.GtkEventControllerKey, keyval: c.guint, keycode: c.guint, _: c.GdkModifierType, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Trainer, user);
    if (isModifier(keyval)) return;
    const t = discreteMs(self, c.gtk_event_controller_get_current_event_time(@ptrCast(ctl))) orelse return;
    self.session.keyUp(t, keycode) catch {};
    refresh(self);
    maybeDraft(self, false);
}

fn onPromptDone(entry: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Trainer, user);
    // The typed text is discarded here; only its timing was kept.
    c.gtk_editable_set_text(@ptrCast(entry), "");
    self.session.typingBreak();
    newPrompt(self);
}

fn onScroll(ctl: ?*c.GtkEventControllerScroll, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Trainer, user);
    if (c.gtk_event_controller_get_current_event(@ptrCast(ctl))) |ev| if (!noteDevice(self, ev)) return 0;
    const t = discreteMs(self, c.gtk_event_controller_get_current_event_time(@ptrCast(ctl))) orelse return 0;
    const smooth = c.gtk_event_controller_scroll_get_unit(ctl) != c.GDK_SCROLL_UNIT_WHEEL;
    self.session.wheel(t, dx, dy, smooth) catch {};
    refresh(self);
    maybeDraft(self, false);
    return 0;
}

fn onIdleStart(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Trainer, user);
    if (self.idle_timer != 0 or self.blocked) return;
    self.session.beginIdle();
    c.gtk_label_set_text(@ptrCast(self.idle_label), "Recording: keep your hand resting on the pointer...");
    self.idle_timer = c.g_timeout_add_seconds(IDLE_SECONDS, @ptrCast(&onIdleDone), @ptrCast(self));
}

fn onIdleDone(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Trainer, user);
    self.idle_timer = 0;
    const before = self.session.idle.items.len;
    self.session.endIdle() catch {};
    c.gtk_label_set_text(@ptrCast(self.idle_label), if (self.session.idle.items.len > before)
        "Recorded. Press Start again for another segment."
    else
        "Nothing was recorded: the pointer needs to be over this page while you rest your hand on it. Press Start to try again.");
    refresh(self);
    maybeDraft(self, false);
    return 0;
}

fn onPageSwitch(_: *c.GObject, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Trainer, user);
    // A stack losing its pages to window teardown notifies too.
    if (self.destroyed or c.gtk_widget_get_mapped(self.window) == 0) return;
    dropTarget(self);
    self.session.closeBurst() catch {};
    refresh(self);
    maybeDraft(self, true);
}

fn onWindowKey(_: ?*c.GtkEventControllerKey, keyval: c.guint, _: c.guint, state: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
    if (state & c.GDK_CONTROL_MASK != 0 and (keyval == 's' or keyval == 'S')) {
        save(cast.userData(Trainer, user));
        return 1;
    }
    return 0;
}

fn onSaveClicked(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    save(cast.userData(Trainer, user));
}

fn onNameActivate(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Trainer, user);
    var nb: [80]u8 = undefined;
    offer(self, currentName(self, &nb));
}

fn onNameChanged(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Trainer, user);
    if (!self.destroyed) refresh(self);
}

/// The pack name Save uses: the entry, else `my-<device>`.
fn currentName(self: *Trainer, buf: *[80]u8) []const u8 {
    const typed = std.mem.span(c.gtk_editable_get_text(@ptrCast(self.name_entry)));
    if (typed.len > 0) return typed;
    return std.fmt.bufPrint(buf, "my-{s}", .{@tagName(self.session.device)}) catch "my-pack";
}

/// Show `fmt` in the status line, styled by `kind`; errors and results
/// also go to stderr, since `sketerm motion record` is a terminal command.
fn setStatus(self: *Trainer, kind: Status, comptime fmt: []const u8, args: anytype) void {
    var buf: [900]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, fmt, args) catch blk: {
        buf[buf.len - 1] = 0;
        break :blk buf[0 .. buf.len - 1 :0];
    };
    c.gtk_label_set_text(@ptrCast(self.status), text.ptr);
    c.gtk_widget_remove_css_class(self.status, "error");
    c.gtk_widget_remove_css_class(self.status, "success");
    switch (kind) {
        .info => {},
        .err => c.gtk_widget_add_css_class(self.status, "error"),
        .ok => c.gtk_widget_add_css_class(self.status, "success"),
    }
    if (kind != .info) std.debug.print("motion trainer: {s}\n", .{text});
}

fn setLabel(label: *c.GtkWidget, text: [:0]const u8) void {
    if (std.mem.eql(u8, std.mem.span(c.gtk_label_get_text(@ptrCast(label))), text)) return;
    c.gtk_label_set_text(@ptrCast(label), text.ptr);
}

/// "3 reaches, 0 key timings, ..." for `n`.
fn countsText(buf: []u8, n: recorder.Counts) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    for (std.enums.values(Section), 0..) |s, i| {
        if (i > 0) w.writeAll(", ") catch break;
        w.print("{d} {s}", .{ n.get(s), s.noun() }) catch break;
    }
    return w.buffered();
}

fn refresh(self: *Trainer) void {
    const s = &self.session;
    var buf: [600]u8 = undefined;

    var nb: [80]u8 = undefined;
    const name = currentName(self, &nb);
    const unsaved = s.unsaved();
    var cb: [200]u8 = undefined;
    const mode = if (self.continues.get()) |base| (if (std.mem.eql(u8, base, name))
        std.fmt.bufPrintZ(&buf, "Saving updates the installed '{s}'; this session added {s}.", .{ name, countsText(&cb, s.added()) })
    else
        std.fmt.bufPrintZ(&buf, "Continuing '{s}', saving as '{s}'.", .{ base, name })) else std.fmt.bufPrintZ(&buf, "New pack '{s}'.", .{name});
    if (mode) |m| {
        var full: [700]u8 = undefined;
        const line = if (unsaved > 0)
            std.fmt.bufPrintZ(&full, "{s} {d} recorded item{s} not saved yet.", .{ m, unsaved, if (unsaved == 1) " is" else "s are" }) catch m
        else
            m;
        setLabel(self.mode_line, line);
    } else |_| {}

    const rate = s.rateHz();
    const dev = if (s.device == .unknown)
        std.fmt.bufPrintZ(&buf, "Device: not seen yet; move the pointer over this window.", .{})
    else if (rate <= 1)
        std.fmt.bufPrintZ(&buf, "Device: {s}, sample rate not measured yet (move it a little).", .{@tagName(s.device)})
    else
        std.fmt.bufPrintZ(&buf, "Device: {s}, about {d:.0} samples per second. {s}", .{
            @tagName(s.device), rate, switch (s.clock) {
                .device => "Times come from the device itself.",
                .arrival => "WARNING: this display sends no input timestamps, so times are taken when events arrive; your timing is recorded blurred.",
            },
        });
    if (dev) |d| setLabel(self.device_line, d) else |_| {}

    for (std.enums.values(Section)) |sec| {
        const have = s.progress(sec);
        const goal = sec.goal();
        const n = s.counts().get(sec);
        const limit: []const u8 = if (s.capped.contains(sec)) " The pack limit is reached: more are not recorded." else "";
        const line = switch (sec) {
            .reaches => if (have >= goal)
                std.fmt.bufPrintZ(&buf, "Reaches: complete, {d} of {d} target cells ({d} reaches). More add variety but are optional.{s}", .{ have, goal, n, limit })
            else
                std.fmt.bufPrintZ(&buf, "Reaches: {d} of {d} target cells ({d} reaches), {s}.{s}", .{
                    have, goal, n, if (n >= recorder.USABLE_REACHES) "usable now" else std.fmt.comptimePrint("usable from {d}", .{recorder.USABLE_REACHES}), limit,
                }),
            .typing, .scrolling, .idle => std.fmt.bufPrintZ(&buf, "{s}: {d} of {d} {s}{s}.{s}", .{ page(sec).title, @min(have, goal), goal, sec.noun(), if (have >= goal) ", complete" else "", limit }),
        };
        if (line) |l| setLabel(self.lines.get(sec), l) else |_| {}
        markDone(self, sec, have >= goal);
    }

    const want: f64 = @floatFromInt(Section.reaches.goal());
    const have: f64 = @floatFromInt(@min(s.progress(.reaches), Section.reaches.goal()));
    c.gtk_level_bar_set_value(@ptrCast(self.meter), have / want);
    if (std.fmt.bufPrintZ(&buf, "{d:.0}% of target cells", .{have / want * 100})) |ml| setLabel(self.meter_label, ml) else |_| {}
}

/// Put "(done)" on a section's switcher title once its goal is reached.
fn markDone(self: *Trainer, s: Section, done: bool) void {
    if (self.done.contains(s) == done) return;
    self.done.setPresent(s, done);
    var tb: [48]u8 = undefined;
    const title = std.fmt.bufPrintZ(&tb, "{s}{s}", .{ page(s).title, if (done) " (done)" else "" }) catch return;
    if (self.pages.get(s)) |p| c.gtk_stack_page_set_title(p, title.ptr);
}

/// Autosave the session as a draft every `DRAFT_EVERY` new items, or now
/// when `force` and anything changed since the last one.
fn maybeDraft(self: *Trainer, force: bool) void {
    const unsaved = self.session.unsaved();
    if (unsaved == 0 or unsaved == self.draft_unsaved) return;
    if (!force and unsaved < self.draft_unsaved + DRAFT_EVERY) return;
    var nb: [80]u8 = undefined;
    const name = currentName(self, &nb);
    if (!pack_mod.validName(name)) return;
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    // Nothing storable yet (or no rate): there is nothing a draft could hold.
    self.session.write(&out.writer) catch return;
    var diag: pack_mod.Diag = .{};
    store.saveDraft(self.allocator, out.written(), name, &diag) catch |err| {
        std.debug.print("motion trainer: draft not saved ({s})\n", .{if (diag.len > 0) diag.msg() else @errorName(err)});
        return;
    };
    if (self.draft_name.get()) |old| if (!std.mem.eql(u8, old, name)) store.removeDraft(old);
    self.draft_name.set(name);
    self.draft_unsaved = unsaved;
}

fn dropDrafts(self: *Trainer, name: []const u8) void {
    store.removeDraft(name);
    if (self.draft_name.get()) |old| store.removeDraft(old);
    self.draft_name.clear();
    self.draft_unsaved = 0;
}

// ---- questions --------------------------------------------------------

/// Ask one question; a second one while another is open is dropped (the
/// status line still carries anything that must be said).
fn ask(self: *Trainer, kind: Ask, name: []const u8, heading: [*:0]const u8, body: [*:0]const u8, responses: []const confirm.Response) void {
    if (self.asking != null) return;
    self.asking = kind;
    self.ask_name.set(name);
    // The ref keeps the window (and the qdata resolving back to `self`)
    // alive until the one-shot callback runs.
    _ = c.g_object_ref(@ptrCast(self.window));
    if (confirm.present(self.window, .{ .heading = heading, .body = body, .responses = responses }, .{
        .allocator = self.allocator,
        .cb = &onAnswer,
        .ctx = @ptrCast(self.window),
    }) == null) {
        c.g_object_unref(@ptrCast(self.window));
        self.asking = null;
    }
}

fn onAnswer(user: ?*anyopaque, resp: []const u8) void {
    const window: *c.GtkWidget = @ptrCast(@alignCast(user.?));
    defer c.g_object_unref(@ptrCast(window));
    const self = trainerOf(window) orelse return;
    const kind = self.asking orelse return;
    self.asking = null;
    var nb: [64]u8 = undefined;
    const name_src = self.ask_name.get() orelse "";
    @memcpy(nb[0..name_src.len], name_src);
    const name = nb[0..name_src.len];
    const is = struct {
        fn f(r: []const u8, want: []const u8) bool {
            return std.mem.eql(u8, r, want);
        }
    }.f;
    switch (kind) {
        .restore => if (is(resp, "restore")) {
            if (loadInto(self, name, .draft, false)) {
                // A draft is the whole session it came from, so saving it
                // replaces the installed pack rather than adding to it.
                self.replace_ok.set(name);
                self.draft_name.set(name);
                self.draft_unsaved = self.session.unsaved();
                var cb: [200]u8 = undefined;
                setStatus(self, .ok, "Restored the unsaved recording for '{s}': {s}. Saving replaces the installed '{s}' with it (it already holds what it continued).", .{ name, countsText(&cb, self.session.counts()), name });
            }
        } else if (is(resp, "discard")) {
            store.removeDraft(name);
            offerInstalled(self, name);
        },
        .continue_pack => if (is(resp, "continue")) {
            if (loadInto(self, name, .installed, true)) {
                self.continues.set(name);
                var cb: [200]u8 = undefined;
                setStatus(self, .ok, "Continuing '{s}' ({s}). New recordings are added to it when you save.", .{ name, countsText(&cb, self.session.base) });
            }
        } else {
            setStatus(self, .info, "Recording a new pack. Saving it as '{s}' asks before replacing the installed one.", .{name});
        },
        .cannot_continue => {},
        .replace => if (is(resp, "replace")) {
            self.replace_ok.set(name);
            doSave(self, name);
        } else if (is(resp, "add")) {
            if (loadInto(self, name, .installed, true)) {
                self.continues.set(name);
                doSave(self, name);
            } else self.close_after_save = false;
        } else {
            self.close_after_save = false;
            setStatus(self, .info, "Not saved. The recording is still here.", .{});
        },
        .close => if (is(resp, "save")) {
            self.close_after_save = true;
            save(self);
        } else if (is(resp, "discard")) {
            dropDrafts(self, name);
            closeNow(self);
        },
        .blocked => if (is(resp, "new")) {
            restartFresh(self);
            setStatus(self, .info, "Started a new pack; this display's timing is recorded on arrival.", .{});
        } else closeNow(self),
    }
    refresh(self);
}

fn closeNow(self: *Trainer) void {
    self.force_close = true;
    c.gtk_window_destroy(@ptrCast(self.window));
}

/// Offer what an installed pack or a draft named `name` allows: restore
/// the draft, else continue the pack. Once per name, one question at a
/// time, and never for the draft this window itself keeps.
fn offer(self: *Trainer, name: []const u8) void {
    if (self.asking != null or !pack_mod.validName(name) or self.offered.is(name) or self.continues.is(name)) return;
    self.offered.set(name);
    if (!self.draft_name.is(name) and self.session.unsaved() == 0) {
        var diag: pack_mod.Diag = .{};
        if (store.loadDraft(self.allocator, name, &diag)) |loaded| {
            defer self.allocator.free(loaded.bytes);
            var cb: [200]u8 = undefined;
            var body: [600]u8 = undefined;
            const text = std.fmt.bufPrintZ(&body, "A recording for '{s}' was not saved when its window closed: {s}. Restore it to keep recording and save it, or discard it.", .{ name, countsText(&cb, summaryCounts(loaded.summary)) }) catch "An unsaved recording was found.";
            ask(self, .restore, name, "Restore the unsaved recording?", text.ptr, &.{
                .{ .id = "discard", .label = "Discard it", .appearance = .destructive },
                .{ .id = "restore", .label = "Restore", .appearance = .suggested, .is_default = true, .is_close = true },
            });
            return;
        } else |_| {}
    }
    offerInstalled(self, name);
}

fn offerInstalled(self: *Trainer, name: []const u8) void {
    var diag: pack_mod.Diag = .{};
    const loaded = store.load(self.allocator, name, &diag) catch |err| {
        if (err != error.Invalid and err != error.ReadFailed) return;
        var body: [600]u8 = undefined;
        const text = std.fmt.bufPrintZ(&body, "The installed '{s}' cannot be read: {s}. This window records a new pack; saving it as '{s}' asks before replacing the broken one.", .{ name, if (diag.len > 0) diag.msg() else @errorName(err), name }) catch "The installed pack cannot be read.";
        ask(self, .cannot_continue, name, "This pack cannot be continued", text.ptr, &.{
            .{ .id = "new", .label = "Start a new pack", .appearance = .suggested, .is_default = true, .is_close = true },
        });
        return;
    };
    defer self.allocator.free(loaded.bytes);
    var cb: [200]u8 = undefined;
    var body: [600]u8 = undefined;
    const text = std.fmt.bufPrintZ(&body, "'{s}' is installed: {s}. Continue it to add this session's recording to it, or start a new pack (saving that asks before replacing '{s}').", .{ name, countsText(&cb, summaryCounts(loaded.summary)), name }) catch "This pack is installed.";
    var hb: [120]u8 = undefined;
    const heading = std.fmt.bufPrintZ(&hb, "Continue '{s}'?", .{name}) catch "Continue this pack?";
    ask(self, .continue_pack, name, heading.ptr, text.ptr, &.{
        .{ .id = "new", .label = "Start a new pack" },
        .{ .id = "continue", .label = "Continue", .appearance = .suggested, .is_default = true },
    });
}

fn summaryCounts(s: pack_mod.Pack.Summary) recorder.Counts {
    var n: recorder.Counts = .initFill(0);
    n.set(.reaches, s.reaches);
    n.set(.typing, s.keys);
    n.set(.scrolling, s.scroll);
    n.set(.idle, s.idle);
    return n;
}

const Source = enum { installed, draft };

/// Load the installed pack or the draft `name` into the session.
/// @return false (status says why) when it could not be loaded.
fn loadInto(self: *Trainer, name: []const u8, from: Source, as_base: bool) bool {
    var diag: pack_mod.Diag = .{};
    const loaded = (switch (from) {
        .installed => store.load(self.allocator, name, &diag),
        .draft => store.loadDraft(self.allocator, name, &diag),
    }) catch |err| {
        setStatus(self, .err, "Could not load '{s}': {s}. This window keeps recording a new pack.", .{ name, if (diag.len > 0) diag.msg() else @errorName(err) });
        return false;
    };
    defer self.allocator.free(loaded.bytes);
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const p = pack_mod.parse(arena.allocator(), loaded.bytes, &diag) catch {
        setStatus(self, .err, "Could not load '{s}': {s}.", .{ name, diag.msg() });
        return false;
    };
    self.session.load(p, as_base) catch |err| {
        switch (err) {
            error.DeviceMismatch => setStatus(self, .err, "Cannot add to '{s}': it was recorded with a {s}, and this window records a {s}. A pack holds ONE pointing device; save under another name instead.", .{ name, @tagName(p.header.device), @tagName(self.session.device) }),
            error.ClockMismatch => setStatus(self, .err, "Cannot add to '{s}': its times come from {s}, this window's from {s}, and one pack never mixes the two. Save under another name instead.", .{ name, clockWords(p.header.clock), clockWords(self.session.clock) }),
            error.OutOfMemory => setStatus(self, .err, "Could not load '{s}': out of memory.", .{name}),
        }
        return false;
    };
    // The loaded coverage changes which target is least filled.
    dropTarget(self);
    return true;
}

fn clockWords(clock: pack_mod.Clock) []const u8 {
    return switch (clock) {
        .device => "the device",
        .arrival => "event arrival (no device timestamps)",
    };
}

/// The display stamps no input times but the session continues a pack
/// recorded with them: nothing more can be recorded into it.
fn block(self: *Trainer) void {
    self.blocked = true;
    dropTarget(self);
    const name = self.continues.get() orelse "this pack";
    setStatus(self, .err, "Recording stopped: this display sends no input timestamps, and '{s}' was recorded with them.", .{name});
    var body: [600]u8 = undefined;
    const text = std.fmt.bufPrintZ(&body, "This display sends no input timestamps, and '{s}' was recorded with them; one pack never mixes the two clocks, so nothing more can be added to it here. Start a new pack (timed on arrival), or close this window.", .{name}) catch "This display sends no input timestamps.";
    ask(self, .blocked, name, "Cannot continue this pack here", text.ptr, &.{
        .{ .id = "close", .label = "Close window", .is_close = true },
        .{ .id = "new", .label = "Start a new pack", .appearance = .suggested, .is_default = true },
    });
}

/// Drop everything recorded and loaded, and record a new pack.
fn restartFresh(self: *Trainer) void {
    dropTarget(self);
    self.session.deinit();
    self.session = recorder.Session.init(self.allocator);
    self.session.recorder = RECORDER;
    self.session.created = isoNow(self.session.arena.allocator());
    self.continues.clear();
    self.blocked = false;
    self.timed_seen = false;
    self.untimed = 0;
    self.device_switch = false;
    self.draft_unsaved = 0;
}

// ---- saving -----------------------------------------------------------

fn onCloseRequest(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Trainer, user);
    if (self.force_close) return 0;
    const unsaved = self.session.unsaved();
    if (unsaved == 0) return 0;
    if (self.asking != null) return 1;
    var nb: [80]u8 = undefined;
    const name = currentName(self, &nb);
    var body: [400]u8 = undefined;
    const text = std.fmt.bufPrintZ(&body, "{d} recorded item{s} not saved yet. Save installs the pack as '{s}'; Discard throws the recording away, autosaved draft included.", .{ unsaved, if (unsaved == 1) " is" else "s are", name }) catch "The recording is not saved yet.";
    ask(self, .close, name, "Save the recording?", text.ptr, &.{
        .{ .id = "cancel", .label = "Cancel", .is_close = true },
        .{ .id = "discard", .label = "Discard", .appearance = .destructive },
        .{ .id = "save", .label = "Save", .appearance = .suggested, .is_default = true },
    });
    return 1;
}

fn save(self: *Trainer) void {
    if (self.asking != null) return;
    var nb: [80]u8 = undefined;
    const name = currentName(self, &nb);
    if (!pack_mod.validName(name)) {
        self.close_after_save = false;
        setStatus(self, .err, "Not saved: a pack name is 1-64 characters of a-z, 0-9, '_' or '-'.", .{});
        return;
    }
    self.session.closeBurst() catch {};
    if (!self.continues.is(name) and !self.replace_ok.is(name)) {
        var diag: pack_mod.Diag = .{};
        if (store.load(self.allocator, name, &diag)) |loaded| {
            defer self.allocator.free(loaded.bytes);
            var cb: [200]u8 = undefined;
            var body: [600]u8 = undefined;
            const text = std.fmt.bufPrintZ(&body, "'{s}' is already installed ({s}). Add this recording to it, or replace it with this recording alone?", .{ name, countsText(&cb, summaryCounts(loaded.summary)) }) catch "This pack is already installed.";
            var hb: [120]u8 = undefined;
            const heading = std.fmt.bufPrintZ(&hb, "'{s}' exists", .{name}) catch "The pack exists";
            ask(self, .replace, name, heading.ptr, text.ptr, &.{
                .{ .id = "cancel", .label = "Cancel", .is_close = true },
                .{ .id = "replace", .label = "Replace", .appearance = .destructive },
                .{ .id = "add", .label = "Add to it", .appearance = .suggested, .is_default = true },
            });
            return;
        } else |err| if (err != error.NotInstalled) {
            // A broken installed file is replaced only on purpose.
            var body: [600]u8 = undefined;
            const text = std.fmt.bufPrintZ(&body, "The installed '{s}' cannot be read ({s}). Replace it with this recording?", .{ name, if (diag.len > 0) diag.msg() else @errorName(err) }) catch "The installed pack cannot be read.";
            ask(self, .replace, name, "Replace the broken pack?", text.ptr, &.{
                .{ .id = "cancel", .label = "Cancel", .is_close = true },
                .{ .id = "replace", .label = "Replace", .appearance = .destructive, .is_default = true },
            });
            return;
        }
    }
    doSave(self, name);
}

fn doSave(self: *Trainer, name: []const u8) void {
    const then_close = self.close_after_save;
    self.close_after_save = false;
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    self.session.write(&out.writer) catch |err| {
        switch (err) {
            error.NoRate => setStatus(self, .err, "Nothing saved yet: move the pointer a little so its sample rate can be measured.", .{}),
            error.Empty => setStatus(self, .err, "Nothing saved yet: record some reaches, typing or scrolling first.", .{}),
            else => setStatus(self, .err, "Not saved: the pack could not be built ({s}). Nothing was written, and the recording is still here.", .{@errorName(err)}),
        }
        return;
    };
    var diag: pack_mod.Diag = .{};
    const summary = store.installBytes(self.allocator, out.written(), name, &diag) catch |err| {
        const why: []const u8 = switch (err) {
            error.Invalid => diag.msg(),
            error.WriteFailed => "the pack file could not be written",
            error.NoDataDir => "neither XDG_DATA_HOME nor HOME names a data directory",
            else => @errorName(err),
        };
        var ib: [300]u8 = undefined;
        var idiag: pack_mod.Diag = .{};
        const installed: []const u8 = if (store.load(self.allocator, name, &idiag)) |old| blk: {
            defer self.allocator.free(old.bytes);
            var cb: [200]u8 = undefined;
            break :blk std.fmt.bufPrint(&ib, "the installed '{s}' is unchanged ({s})", .{ name, countsText(&cb, summaryCounts(old.summary)) }) catch "the installed pack is unchanged";
        } else |_| std.fmt.bufPrint(&ib, "nothing is installed as '{s}'", .{name}) catch "nothing is installed under that name";
        setStatus(self, .err, "Not saved: {s}. Nothing was written: {s}, and the whole recording is still in this window; keep recording and save again.", .{ why, installed });
        return;
    };
    self.session.markSaved();
    self.continues.set(name);
    dropDrafts(self, name);
    var tb: [200]u8 = undefined;
    var ab: [200]u8 = undefined;
    const totals = countsText(&tb, summaryCounts(summary));
    const added = countsText(&ab, self.session.added());
    if (self.out) |path| atomicwrite.writeFileExact(path, out.written(), 0o600) catch {
        setStatus(self, .err, "Installed as '{s}' ({s}), but the --out file {s} could not be written.", .{ name, totals, path });
        if (then_close) closeNow(self);
        return;
    };
    setStatus(self, .ok, "Saved and installed as '{s}': {s}. This session added {s}. Use it with: sketerm mcp --web-motion-pack {s}", .{ name, totals, added, name });
    std.debug.print("motion trainer: saved '{s}' (rate {d:.0} Hz, device {s}, {s} clock)\n", .{ name, summary.rate_hz, @tagName(summary.device), @tagName(self.session.clock) });
    refresh(self);
    if (then_close) closeNow(self);
}

/// `sketerm motion record`: the trainer as its own short-lived app.
pub fn runStandalone(allocator: std.mem.Allocator, opts: Options) u8 {
    g_standalone = .{ .allocator = allocator, .opts = opts };
    const env_id = c.getenv("SKETERM_APP_ID");
    const app_id: [*:0]const u8 = if (env_id != null) env_id else "dev.sker.sketerm.motion";
    const app = c.adw_application_new(app_id, c.G_APPLICATION_NON_UNIQUE);
    defer c.g_object_unref(app);
    _ = c.g_signal_connect_data(app, "activate", @ptrCast(&onStandaloneActivate), null, null, c.G_CONNECT_DEFAULT);
    const status = c.g_application_run(@ptrCast(app), 0, null);
    return @intCast(status & 0xff);
}

var g_standalone: struct { allocator: std.mem.Allocator, opts: Options } = undefined;

fn onStandaloneActivate(app: ?*c.GApplication, _: ?*anyopaque) callconv(.c) void {
    open(g_standalone.allocator, @ptrCast(app), null, g_standalone.opts);
}
