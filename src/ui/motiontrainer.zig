//! The motion trainer: the ONLY way a motion pack is recorded
//! (`sketerm motion record`, palette "Record Motion Pack"). A native GTK
//! window, so it records the DEVICE: device timestamps from
//! `gdk_event_get_time`, coalesced samples from `gdk_event_get_history`,
//! the device class from the event's device.
//!
//! Four sections: reaches (click the targets; a coverage meter says
//! how complete the pack is), typing (only key timing per key class is
//! kept, the prompted text is discarded), scrolling (wheel bursts while
//! reading) and idle drift. Ctrl+S (or Save) validates and installs the
//! pack into `$XDG_DATA_HOME/sketerm/motion-packs/`.
//!
//! All recording logic is `src/motion/recorder.zig`; this file only
//! feeds it events. One heap context, owned by the window's qdata.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const recorder = @import("../motion/recorder.zig");
const pack_mod = @import("../motion/pack.zig");
const store = @import("../motion/store.zig");
const atomicwrite = @import("../util/atomicwrite.zig");

const QDATA = "sketerm-motion-trainer";
const IDLE_SECONDS = 8;

const WORDS = [_][]const u8{
    "river",   "pocket",  "window",  "gentle", "orange", "silver",  "market", "planet",  "summer", "candle",
    "garden",  "bridge",  "forest",  "letter", "copper", "winter",  "travel", "harbor",  "mirror", "pepper",
    "quickly", "measure", "between", "number", "simple", "public",  "office", "machine", "yellow", "jacket",
    "zebra",   "volume",  "kettle",  "lizard", "sphinx", "quartz",  "jovial", "wizard",  "fjord",  "blanket",
};

const SCROLL_TEXT =
    \\Scroll this text the way you normally read: a few lines at a time, a pause, then more.
    \\Sometimes you jump ahead, sometimes you scroll back a little to re-read a sentence.
    \\Only the wheel or touchpad deltas and their timing are kept, never what you read.
    \\
;

pub const Options = struct {
    /// Installed pack name for Save; empty = `my-<device>`.
    name: []const u8 = "",
    /// Also write the pack to this file on Save.
    out: ?[]const u8 = null,
};

const Trainer = struct {
    allocator: std.mem.Allocator,
    window: *c.GtkWidget,
    session: recorder.Session,
    prng: std.Random.DefaultPrng,
    name_entry: *c.GtkWidget,
    out: ?[]u8,
    header: *c.GtkWidget,
    meter: *c.GtkWidget,
    meter_label: *c.GtkWidget,
    status: *c.GtkWidget,
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
    misses: usize = 0,
    device_switch: bool = false,
    /// Some event carried a device timestamp.
    timed_seen: bool = false,
    /// Untimed events seen before any timed one.
    untimed: u8 = 0,
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
/// samples must never mix two clocks.
fn eventMs(self: *Trainer, device_ms: u32) ?f64 {
    if (self.session.clock == .arrival) return arrivalMs();
    if (device_ms != 0) {
        self.timed_seen = true;
        return @floatFromInt(device_ms);
    }
    if (self.timed_seen) return null;
    self.untimed += 1;
    if (self.untimed < UNTIMED_LIMIT) return null;
    self.session.clock = .arrival;
    return arrivalMs();
}

/// `eventMs` for a press, release, key or scroll, which the session must
/// see even when untimed: it then takes the last sample's time.
fn discreteMs(self: *Trainer, device_ms: u32) f64 {
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
    const window = c.gtk_window_new();
    self.* = .{
        .allocator = allocator,
        .window = window,
        .session = recorder.Session.init(allocator),
        .prng = std.Random.DefaultPrng.init(seed),
        .name_entry = c.gtk_entry_new(),
        .out = if (opts.out) |o| allocator.dupe(u8, o) catch null else null,
        .header = c.gtk_label_new(""),
        .meter = c.gtk_level_bar_new_for_interval(0, 1),
        .meter_label = c.gtk_label_new(""),
        .status = c.gtk_label_new("Click each target as you naturally would. Ctrl+S saves the pack."),
        .area = c.gtk_drawing_area_new(),
        .prompt = c.gtk_label_new(""),
        .entry = c.gtk_entry_new(),
        .idle_label = c.gtk_label_new("Rest your hand on the pointer and read this sentence while it records how the pointer drifts."),
    };
    self.session.recorder = "sketerm " ++ @import("../version.zig").string;
    self.session.created = isoNow(self.session.arena.allocator());
    c.g_object_set_data_full(@ptrCast(window), QDATA, @ptrCast(self), @ptrCast(&freeTrainer));
    _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

    c.gtk_window_set_title(@ptrCast(window), "Record Motion Pack");
    c.gtk_window_set_default_size(@ptrCast(window), 1100, 760);
    if (parent) |p| c.gtk_window_set_transient_for(@ptrCast(window), p);
    if (app) |a| c.gtk_window_set_application(@ptrCast(window), a);

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
    c.gtk_widget_set_margin_start(root, 10);
    c.gtk_widget_set_margin_end(root, 10);
    c.gtk_widget_set_margin_top(root, 8);
    c.gtk_widget_set_margin_bottom(root, 8);
    c.gtk_label_set_xalign(@ptrCast(self.header), 0);
    c.gtk_box_append(@ptrCast(root), self.header);
    const meter_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_hexpand(self.meter, 1);
    c.gtk_box_append(@ptrCast(meter_row), self.meter);
    c.gtk_box_append(@ptrCast(meter_row), self.meter_label);
    c.gtk_box_append(@ptrCast(root), meter_row);

    const stack = c.gtk_stack_new();
    const switcher = c.gtk_stack_switcher_new();
    c.gtk_stack_switcher_set_stack(@ptrCast(switcher), @ptrCast(stack));
    c.gtk_box_append(@ptrCast(root), switcher);

    // Reaches.
    c.gtk_widget_set_hexpand(self.area, 1);
    c.gtk_widget_set_vexpand(self.area, 1);
    c.gtk_drawing_area_set_draw_func(@ptrCast(self.area), @ptrCast(&drawArea), @ptrCast(self), null);
    addMotion(self.area, self, &onReachMotion);
    const click = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(click), 1);
    _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&onPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(click, "released", @ptrCast(&onReleased), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(self.area, @ptrCast(click));
    _ = c.gtk_stack_add_titled(@ptrCast(stack), self.area, "reach", "Reaches");

    // Typing.
    const typing = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 10);
    c.gtk_widget_set_valign(typing, c.GTK_ALIGN_CENTER);
    const t_intro = c.gtk_label_new("Type the words below and press Enter. Only how long keys are held and the time between them is kept, by key position; the text itself is discarded.");
    c.gtk_label_set_wrap(@ptrCast(t_intro), 1);
    c.gtk_box_append(@ptrCast(typing), t_intro);
    c.gtk_widget_add_css_class(self.prompt, "title-2");
    c.gtk_box_append(@ptrCast(typing), self.prompt);
    c.gtk_box_append(@ptrCast(typing), self.entry);
    const keys = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKeyPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(keys, "key-released", @ptrCast(&onKeyReleased), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(self.entry, @ptrCast(keys));
    _ = c.g_signal_connect_data(self.entry, "activate", @ptrCast(&onPromptDone), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    newPrompt(self);
    _ = c.gtk_stack_add_titled(@ptrCast(stack), typing, "typing", "Typing");

    // Scrolling.
    const scroller = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scroller, 1);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (0..80) |i| text.print(allocator, "{d}. " ++ SCROLL_TEXT ++ "\n", .{i + 1}) catch break;
    text.append(allocator, 0) catch {};
    const long = c.gtk_label_new(if (text.items.len > 0) @as([*:0]const u8, @ptrCast(text.items.ptr)) else "");
    c.gtk_label_set_wrap(@ptrCast(long), 1);
    c.gtk_label_set_xalign(@ptrCast(long), 0);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), long);
    const wheel = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    c.gtk_event_controller_set_propagation_phase(@ptrCast(wheel), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(wheel, "scroll", @ptrCast(&onScroll), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(scroller, @ptrCast(wheel));
    _ = c.gtk_stack_add_titled(@ptrCast(stack), scroller, "scroll", "Scrolling");

    // Idle drift.
    const idle = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 10);
    c.gtk_widget_set_vexpand(idle, 1);
    c.gtk_label_set_wrap(@ptrCast(self.idle_label), 1);
    c.gtk_box_append(@ptrCast(idle), self.idle_label);
    const idle_btn = c.gtk_button_new_with_label("Start (" ++ std.fmt.comptimePrint("{d}", .{IDLE_SECONDS}) ++ " s)");
    c.gtk_widget_set_halign(idle_btn, c.GTK_ALIGN_CENTER);
    _ = c.g_signal_connect_data(idle_btn, "clicked", @ptrCast(&onIdleStart), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(idle), idle_btn);
    addMotion(idle, self, &onPlainMotion);
    _ = c.gtk_stack_add_titled(@ptrCast(stack), idle, "idle", "Idle drift");

    c.gtk_widget_set_vexpand(stack, 1);
    c.gtk_box_append(@ptrCast(root), stack);

    // Save row.
    const save_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_box_append(@ptrCast(save_row), c.gtk_label_new("Pack name:"));
    if (opts.name.len > 0) {
        var nb: [80]u8 = undefined;
        const nz = std.fmt.bufPrintZ(&nb, "{s}", .{opts.name[0..@min(opts.name.len, 64)]}) catch "";
        c.gtk_editable_set_text(@ptrCast(self.name_entry), nz.ptr);
    }
    c.gtk_entry_set_placeholder_text(@ptrCast(self.name_entry), "my-mouse");
    c.gtk_box_append(@ptrCast(save_row), self.name_entry);
    const save_btn = c.gtk_button_new_with_label("Save and install");
    _ = c.g_signal_connect_data(save_btn, "clicked", @ptrCast(&onSaveClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(save_row), save_btn);
    c.gtk_label_set_wrap(@ptrCast(self.status), 1);
    c.gtk_label_set_xalign(@ptrCast(self.status), 0);
    c.gtk_widget_set_hexpand(self.status, 1);
    c.gtk_box_append(@ptrCast(save_row), self.status);
    c.gtk_box_append(@ptrCast(root), save_row);

    const shortcuts = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(shortcuts), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(shortcuts, "key-pressed", @ptrCast(&onWindowKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(window, @ptrCast(shortcuts));

    c.gtk_window_set_child(@ptrCast(window), root);
    refresh(self);
    c.gtk_window_present(@ptrCast(window));
}

fn freeTrainer(user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Trainer, user);
    self.session.deinit();
    if (self.out) |o| self.allocator.free(o);
    self.allocator.destroy(self);
}

fn onDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Trainer, user);
    if (self.idle_timer != 0) _ = c.g_source_remove(self.idle_timer);
    self.idle_timer = 0;
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
    noteDevice(self, ev);
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

fn noteDevice(self: *Trainer, ev: *c.GdkEvent) void {
    const dev = c.gdk_event_get_device(ev) orelse return;
    const cls: pack_mod.Device = switch (c.gdk_device_get_source(dev)) {
        c.GDK_SOURCE_MOUSE => .mouse,
        c.GDK_SOURCE_TOUCHPAD => .touchpad,
        c.GDK_SOURCE_PEN => .pen,
        else => return,
    };
    if (self.session.device == .unknown) {
        self.session.device = cls;
        self.session.scale = @floatFromInt(@max(c.gtk_widget_get_scale_factor(self.window), 1));
    } else if (self.session.device != cls and !self.device_switch) {
        self.device_switch = true;
        c.gtk_label_set_text(@ptrCast(self.status), "A different pointing device moved: a pack records ONE device. Keep using the first one, or record a second pack for this device.");
    }
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
    if (w < 50 or h < 50 or !self.have_ptr) return;
    const tg = self.session.coverage.next(self.ptr, w, h, self.prng.random()) orelse return;
    self.target = tg;
    self.session.beginReach(self.last_t, self.ptr, tg) catch {};
    c.gtk_widget_queue_draw(self.area);
}

fn onPressed(gesture: ?*c.GtkGestureClick, n: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    _ = n;
    const self = cast.userData(Trainer, user);
    const t = discreteMs(self, c.gtk_event_controller_get_current_event_time(@ptrCast(gesture)));
    if (self.target == null) return;
    self.missed = !self.session.press(t, x, y);
    if (self.missed) self.misses += 1;
}

fn onReleased(gesture: ?*c.GtkGestureClick, n: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    _ = n;
    const self = cast.userData(Trainer, user);
    const t = discreteMs(self, c.gtk_event_controller_get_current_event_time(@ptrCast(gesture)));
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
    _ = self.session.release(t) catch false;
    self.target = null;
    spawnTarget(self);
    refresh(self);
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
    const t = discreteMs(self, c.gtk_event_controller_get_current_event_time(@ptrCast(ctl)));
    const cp = c.gdk_keyval_to_unicode(keyval);
    const cls: pack_mod.KeyClass = if (cp == 0 or cp > 0x10ffff) .other else pack_mod.KeyClass.of(@intCast(cp));
    self.session.keyDown(t, keycode, cls) catch {};
    return 0;
}

fn onKeyReleased(ctl: ?*c.GtkEventControllerKey, keyval: c.guint, keycode: c.guint, _: c.GdkModifierType, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Trainer, user);
    if (isModifier(keyval)) return;
    const t = discreteMs(self, c.gtk_event_controller_get_current_event_time(@ptrCast(ctl)));
    self.session.keyUp(t, keycode) catch {};
    refresh(self);
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
    const t = discreteMs(self, c.gtk_event_controller_get_current_event_time(@ptrCast(ctl)));
    if (c.gtk_event_controller_get_current_event(@ptrCast(ctl))) |ev| noteDevice(self, ev);
    const smooth = c.gtk_event_controller_scroll_get_unit(ctl) != c.GDK_SCROLL_UNIT_WHEEL;
    self.session.wheel(t, dx, dy, smooth) catch {};
    refresh(self);
    return 0;
}

fn onIdleStart(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Trainer, user);
    if (self.idle_timer != 0) return;
    self.session.beginIdle();
    c.gtk_label_set_text(@ptrCast(self.idle_label), "Recording: keep your hand on the pointer and read on...");
    self.idle_timer = c.g_timeout_add_seconds(IDLE_SECONDS, @ptrCast(&onIdleDone), @ptrCast(self));
}

fn onIdleDone(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Trainer, user);
    self.idle_timer = 0;
    self.session.endIdle() catch {};
    c.gtk_label_set_text(@ptrCast(self.idle_label), "Recorded. Start again for another segment.");
    refresh(self);
    return 0;
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

fn refresh(self: *Trainer) void {
    const s = &self.session;
    var buf: [400]u8 = undefined;
    const rate = s.rateHz();
    const head = std.fmt.bufPrintZ(&buf, "Device: {s}   measured rate: {d:.0} Hz{s}   display scale: {d:.0}   reaches {d} (misses {d})   key timings {d}   scroll bursts {d}   idle segments {d}", .{
        @tagName(s.device), rate, if (s.clock == .arrival) " (no device timestamps: arrival time)" else "", s.scale, s.reaches.items.len, self.misses, s.keyCount(), s.bursts.items.len + @intFromBool(s.burst.items.len > 0), s.idle.items.len,
    }) catch return;
    c.gtk_label_set_text(@ptrCast(self.header), head.ptr);
    const want: f64 = @floatFromInt(recorder.CELLS * recorder.PER_CELL);
    const have = want - @as(f64, @floatFromInt(s.coverage.missing()));
    c.gtk_level_bar_set_value(@ptrCast(self.meter), have / want);
    var mb: [128]u8 = undefined;
    const ml = std.fmt.bufPrintZ(&mb, "coverage {d:.0}% ({d}/{d} cells complete)", .{ have / want * 100, s.coverage.filledCells(), recorder.CELLS }) catch return;
    c.gtk_label_set_text(@ptrCast(self.meter_label), ml.ptr);
}

fn save(self: *Trainer) void {
    var name_buf: [80]u8 = undefined;
    const typed = std.mem.span(c.gtk_editable_get_text(@ptrCast(self.name_entry)));
    const name: []const u8 = if (typed.len > 0) typed else std.fmt.bufPrint(&name_buf, "my-{s}", .{@tagName(self.session.device)}) catch "my-pack";
    var msg: [300]u8 = undefined;
    const text: []const u8 = blk: {
        if (!pack_mod.validName(name)) break :blk "Pack name: use 1-64 characters of a-z, 0-9, '_' or '-'.";
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        self.session.write(&out.writer) catch |err| break :blk switch (err) {
            error.NoRate => "Nothing to save yet: move the pointer so its sample rate can be measured.",
            error.Empty => "Nothing to save yet: record some reaches, typing or scrolling first.",
            else => "Could not build the pack.",
        };
        var diag: pack_mod.Diag = .{};
        const summary = store.installBytes(self.allocator, out.written(), name, &diag) catch |err| break :blk std.fmt.bufPrint(&msg, "Not saved: {s}", .{if (diag.len > 0) diag.msg() else @errorName(err)}) catch "Not saved.";
        if (self.out) |path| atomicwrite.writeFileExact(path, out.written(), 0o600) catch break :blk "Installed, but the --out file could not be written.";
        break :blk std.fmt.bufPrint(&msg, "Installed as '{s}': {d} reaches, {d} key timings, {d} scroll bursts. Use it with sketerm mcp --web-motion-pack {s}.", .{ name, summary.reaches, summary.keys, summary.scroll, name }) catch "Installed.";
    };
    var z: [320]u8 = undefined;
    const tz = std.fmt.bufPrintZ(&z, "{s}", .{text[0..@min(text.len, 300)]}) catch return;
    // Also on stderr: `sketerm motion record` is a terminal command.
    std.debug.print("motion trainer: {s} (reaches {d}, rate {d:.0} Hz, device {s})\n", .{ text, self.session.reaches.items.len, self.session.rateHz(), @tagName(self.session.device) });
    c.gtk_label_set_text(@ptrCast(self.status), tz.ptr);
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
