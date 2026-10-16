//! Per-tab visual effects.
//!
//! A background tab can carry several composable effects, each a condition
//! paired with a way to draw itself. `tabbar.zig` owns the widget tree and
//! just iterates `registry` from its `snapshot`/tick: every enabled effect
//! is evaluated for the page, and the active ones draw back-to-front.
//!
//! Effect *state* (activity timestamps, the inter-arrival EMA) lives as
//! GObject qdata on the `AdwTabPage`, because the tab widgets are destroyed
//! and rebuilt on every structure change while the page persists.
//!
//! Split of concerns: `eval` is portable logic (timestamps + arithmetic,
//! the only GTK touch is reading qdata off the page); `draw` is the
//! GTK-bound half. Keep new conditions in `eval` and new looks in
//! `draw` so a future non-GTK frontend can reuse the conditions.

const std = @import("std");
const c = @import("../c.zig").c;
const Config = @import("../config.zig").Config;

/// One effect's verdict for a tab this frame.
pub const Activation = struct {
    /// 0 = inactive (skip). Otherwise the effect's strength, for fades.
    intensity: f64 = 0,
    /// True while the look is still changing (fading, pulsing) so the tab
    /// bar keeps its 33ms tick alive. False lets the tick stop.
    animating: bool = false,
};

/// Per-tab toggles for the effects, stored on the page (see `tabSettings`)
/// and persisted in the layout JSON. These are the user-facing controls; the
/// global config only carries the shared threshold and the detection master.
pub const TabSettings = struct {
    /// Show the rainbow activity glow on this tab. On by default.
    show_activity: bool = true,
    /// Warn (red wash + flashing icon) once this tab goes silent. Off by
    /// default.
    warn_inactive: bool = false,
};

/// A composable tab effect. `enabled` reads the per-tab toggle; `draw` is
/// only called when `eval` returned a non-trivial intensity.
pub const Effect = struct {
    name: []const u8,
    enabled: *const fn (s: TabSettings) bool,
    eval: *const fn (page: *c.AdwTabPage, cfg: *const Config, s: TabSettings) Activation,
    draw: *const fn (renderer: *Renderer, page: *c.AdwTabPage, widget: *c.GtkWidget, snapshot: ?*c.GtkSnapshot, act: Activation) void,
};

/// Drawn back-to-front: aurora wash first, warning on top.
pub const registry = [_]Effect{ aurora_effect, inactive_warning_effect };

// ── per-tab settings (packed into one qdata slot on the page) ────────

const SETTINGS_KEY = "sketerm-tab-fx";
const FX_SHOW: usize = 1 << 0;
const FX_WARN: usize = 1 << 1;
/// Marks the slot as explicitly stored so an all-false setting is still a
/// non-NULL qdata pointer, distinct from "never set" (which uses defaults).
const FX_STORED: usize = 1 << 2;

/// The tab's effect toggles, or the defaults if none were stored. Travels
/// with the page across cross-window tab drags (qdata moves with the page).
pub fn tabSettings(page: *c.AdwTabPage) TabSettings {
    const d = c.g_object_get_data(@ptrCast(@alignCast(page)), SETTINGS_KEY) orelse return .{};
    const bits = @intFromPtr(d);
    return .{ .show_activity = bits & FX_SHOW != 0, .warn_inactive = bits & FX_WARN != 0 };
}

pub fn setTabSettings(page: *c.AdwTabPage, s: TabSettings) void {
    var bits: usize = FX_STORED;
    if (s.show_activity) bits |= FX_SHOW;
    if (s.warn_inactive) bits |= FX_WARN;
    c.g_object_set_data(@ptrCast(@alignCast(page)), SETTINGS_KEY, @ptrFromInt(bits));
}

// ── shared activity state (qdata on the page) ────────────────────────

const ACTIVITY_KEY = "sketerm-tab-activity-us";
/// EMA of the inter-arrival gap between activity events, per page.
const GAP_KEY = "sketerm-tab-gap-us";
/// Monotonic-us timestamp of the last time the user ACKNOWLEDGED this tab by
/// dwelling on it (selected it and stayed past the ack delay). The inactivity
/// warning is edge-triggered: it fires only for activity that arrived AFTER
/// the last acknowledgement, so once you've looked at the tab it stays quiet
/// until genuinely new output goes silent again. See `warnActivation`.
const ACK_KEY = "sketerm-tab-ack-us";

/// Read a monotonic-us timestamp stored as a qdata pointer, or null/0.
fn tsOf(page: *c.AdwTabPage, key: [*:0]const u8) ?i64 {
    const d = c.g_object_get_data(@ptrCast(@alignCast(page)), key) orelse return null;
    return @bitCast(@as(u64, @intFromPtr(d)));
}

/// Acknowledge this tab at "now" — called when the user dwells on it (selects
/// it and stays past the ack delay). Clears any inactive-warning and silences
/// future ones until genuinely new activity arrives. NOT called on merely
/// leaving a tab — only on actually looking at it.
pub fn markAck(page: *c.AdwTabPage) void {
    const now = c.g_get_monotonic_time();
    c.g_object_set_data(@ptrCast(@alignCast(page)), ACK_KEY, @ptrFromInt(@as(usize, @intCast(now))));
}

/// A gap larger than this means activity restarted; the average resets to
/// it rather than blending, so a long pause never inflates the window.
const SUSTAIN_RESET_GAP_US: i64 = 6_000_000;
/// Gaps below this are intra-refresh noise (a full-screen TUI repaint emits
/// several events milliseconds apart) and are ignored — only the quiet
/// between refreshes reveals the true period.
const MIN_MEANINGFUL_GAP_US: i64 = 500_000;

/// Stamp a tab's page with an activity event, maintaining the
/// inter-arrival-gap EMA used to sustain the glow for steady streams.
pub fn recordActivity(page: *c.AdwTabPage) void {
    const obj: [*c]c.GObject = @ptrCast(@alignCast(page));
    const now = c.g_get_monotonic_time();
    if (c.g_object_get_data(obj, ACTIVITY_KEY)) |prev| {
        const prev_ts: i64 = @bitCast(@as(u64, @intFromPtr(prev)));
        const gap = now - prev_ts;
        // Only inter-refresh gaps reveal the period; ignore the burst of
        // tiny gaps a TUI repaint produces (those would drag the average
        // down to a few ms and defeat the sustain entirely).
        if (gap >= MIN_MEANINGFUL_GAP_US) {
            const gap_u: u64 = @intCast(gap);
            const old = c.g_object_get_data(obj, GAP_KEY);
            // Blend at 0.5 so it tracks the real cadence in a couple of
            // refreshes; a long pause resets it so an idle tab doesn't
            // inherit a stale rhythm.
            const ema: u64 = if (old != null and gap < SUSTAIN_RESET_GAP_US)
                (@as(u64, @intFromPtr(old)) + gap_u) / 2
            else
                gap_u;
            c.g_object_set_data(obj, GAP_KEY, @ptrFromInt(@as(usize, @intCast(ema))));
        }
    }
    c.g_object_set_data(obj, ACTIVITY_KEY, @ptrFromInt(@as(usize, @intCast(now))));
}

/// Microseconds since this page last produced visible output, or null if it
/// never has (no activity stamp = "never started", not "idle").
fn idleSince(page: *c.AdwTabPage) ?i64 {
    const ts = tsOf(page, ACTIVITY_KEY) orelse return null;
    const elapsed = c.g_get_monotonic_time() - ts;
    return if (elapsed < 0) 0 else elapsed;
}

// ── effect: aurora activity glow ─────────────────────────────────────

/// Activity glow fade time once a tab goes quiet (after any sustain
/// window): full → gone over this many microseconds.
const GLOW_DECAY_US: f64 = 2_600_000;
/// Aurora glow: soft full-spectrum colour blobs that blend and drift
/// right-to-left, breathing in and out of place so the colour flows
/// organically instead of a hard rainbow sliding by.
const AURORA_BLOBS: usize = 6;
/// Period of the slow right-to-left drift, microseconds.
const AURORA_DRIFT_US: f64 = 5_000_000;
/// Period of each blob's in-place wobble, microseconds.
const AURORA_WOBBLE_US: f64 = 2_600_000;
/// Blob spread (fraction of tab width) and wobble amplitude.
const AURORA_SIGMA: f64 = 0.17;
const AURORA_WOBBLE: f64 = 0.06;
/// Blending colours in RGB greys them out; push the blend back toward full
/// saturation by this factor (1 = none) so the aurora stays vivid.
const AURORA_SAT: f64 = 1.55;
/// A source whose refresh period is under this (e.g. htop every ~1.5s) is
/// treated as "ongoing": the glow is held steady so it keeps sweeping
/// smoothly instead of fading and snapping back on each refresh.
const SUSTAIN_THRESHOLD_US: f64 = 4_500_000;
/// Hold the glow for this multiple of the refresh period (generous margin
/// so jitter / a slightly-late refresh never causes a visible dip).
const SUSTAIN_FACTOR: f64 = 2.2;
/// Cap on the sustain window so even near-threshold sources fade eventually.
const SUSTAIN_MAX_US: f64 = 9_000_000;

fn auroraEnabled(s: TabSettings) bool {
    return s.show_activity;
}

fn auroraEval(page: *c.AdwTabPage, _: *const Config, _: TabSettings) Activation {
    const elapsed = idleSince(page) orelse return .{};
    // EMA gap (0 if unrecorded) feeds the adaptive sustain.
    var ema: i64 = 0;
    const obj: [*c]c.GObject = @ptrCast(@alignCast(page));
    if (c.g_object_get_data(obj, GAP_KEY)) |g| ema = @bitCast(@as(u64, @intFromPtr(g)));
    const intensity = auroraIntensity(elapsed, ema);
    return .{ .intensity = intensity, .animating = intensity > 0.01 };
}

/// Glow strength from microseconds since the last event and the measured
/// inter-refresh EMA. Pure: no clock, no GTK — the testable core.
fn auroraIntensity(elapsed_us: i64, ema_us: i64) f64 {
    const elapsed: f64 = @floatFromInt(elapsed_us);
    if (elapsed <= 0) return 1.0;

    // Adaptive sustain: while a source keeps updating faster than the
    // threshold, hold the glow at full so it sweeps continuously instead
    // of fading and snapping on every update (e.g. htop's 2s refresh).
    var hold: f64 = 0;
    if (ema_us > 0) {
        const ema: f64 = @floatFromInt(ema_us);
        if (ema < SUSTAIN_THRESHOLD_US) hold = @min(ema * SUSTAIN_FACTOR, SUSTAIN_MAX_US);
    }
    if (elapsed <= hold) return 1.0;

    const fade = elapsed - hold;
    if (fade >= GLOW_DECAY_US) return 0;
    return 1.0 - fade / GLOW_DECAY_US;
}

/// Shared by every tab in one strip. The old Cairo path rasterized and
/// uploaded two gradients into a full-size image for EACH tab EVERY frame.
/// The colour field is identical across tabs: only geometry and opacity
/// differ. Upload 65x5 + 65x1 texels once per frame and let GSK interpolate
/// the same 64 horizontal colour stops and piecewise-linear vertical mask.
pub const Renderer = struct {
    frame_time: i64 = -1,
    wash: ?*c.GdkTexture = null,
    border: ?*c.GdkTexture = null,

    pub fn deinit(self: *Renderer) void {
        if (self.wash) |texture| c.g_object_unref(texture);
        if (self.border) |texture| c.g_object_unref(texture);
        self.* = .{};
    }

    fn prepare(self: *Renderer, frame_time: i64) bool {
        if (self.frame_time == frame_time and self.wash != null and self.border != null) return true;
        const colors = auroraColors(@floatFromInt(frame_time));
        // Rows at y=0, .25, .5, .75, 1 reproduce the original mask's
        // stops (alpha .04 at 0, .16 at .75, .38 at 1) exactly.
        const alphas = [_]f64{ 0.04, 0.08, 0.12, 0.16, 0.38 };
        var wash: [AURORA_SAMPLES * 5 * 4]u8 = undefined;
        var border: [AURORA_SAMPLES * 4]u8 = undefined;
        for (colors, 0..) |rgb, x| {
            writePixel(border[x * 4 ..][0..4], rgb, 1);
            for (alphas, 0..) |alpha, y|
                writePixel(wash[(y * AURORA_SAMPLES + x) * 4 ..][0..4], rgb, alpha);
        }
        const next_wash = textureFromPixels(&wash, 5) orelse return false;
        const next_border = textureFromPixels(&border, 1) orelse {
            c.g_object_unref(next_wash);
            return false;
        };
        self.deinit();
        self.* = .{ .frame_time = frame_time, .wash = next_wash, .border = next_border };
        return true;
    }
};

fn writePixel(pixel: *[4]u8, rgb: [3]f64, alpha: f64) void {
    for (rgb, 0..) |channel, i| pixel[i] = @intFromFloat(@round(channel * alpha * 255));
    pixel[3] = @intFromFloat(@round(alpha * 255));
}

fn textureFromPixels(pixels: []const u8, height: c_int) ?*c.GdkTexture {
    const bytes = c.g_bytes_new(pixels.ptr, pixels.len) orelse return null;
    defer c.g_bytes_unref(bytes);
    return c.gdk_memory_texture_new(AURORA_SAMPLES, height, c.GDK_MEMORY_R8G8B8A8_PREMULTIPLIED, bytes, AURORA_SAMPLES * 4);
}

/// Align the first/last texel centres with the gradient endpoints. Clipping
/// the half-texel overhang preserves the old geometry at every scale/size.
fn appendAurora(snapshot: ?*c.GtkSnapshot, texture: *c.GdkTexture, w: f32, y: f32, h: f32, rows: usize, opacity: f64) void {
    var clip: c.graphene_rect_t = undefined;
    _ = c.graphene_rect_init(&clip, 0, y, w, h);
    const dx = w / (2 * (AURORA_SAMPLES - 1));
    const dy = if (rows > 1) h / (2 * @as(f32, @floatFromInt(rows - 1))) else 0;
    var bounds: c.graphene_rect_t = undefined;
    _ = c.graphene_rect_init(&bounds, -dx, y - dy, w + 2 * dx, h + 2 * dy);
    c.gtk_snapshot_push_clip(snapshot, &clip);
    // A plain texture node scales directly in the destination pass. An
    // explicit TextureScale node first resamples into an offscreen image
    // at logical resolution whenever the monitor scale is not 1, adding
    // TWO render passes per tab on fractional/HiDPI displays.
    c.gtk_snapshot_push_opacity(snapshot, opacity);
    c.gtk_snapshot_append_texture(snapshot, texture, &bounds);
    c.gtk_snapshot_pop(snapshot);
    c.gtk_snapshot_pop(snapshot);
}

/// The same flowing wash and bottom border, without per-tab raster uploads.
fn auroraDraw(renderer: *Renderer, _: *c.AdwTabPage, widget: *c.GtkWidget, snapshot: ?*c.GtkSnapshot, act: Activation) void {
    const w: f32 = @floatFromInt(c.gtk_widget_get_width(widget));
    const h: f32 = @floatFromInt(c.gtk_widget_get_height(widget));
    if (w <= 0 or h <= 0) return;
    const clock = c.gtk_widget_get_frame_clock(widget) orelse return;
    if (!renderer.prepare(c.gdk_frame_clock_get_frame_time(clock))) return;
    appendAurora(snapshot, renderer.wash.?, w, 0, h, 5, act.intensity);
    appendAurora(snapshot, renderer.border.?, w, h - 3, 3, 1, act.intensity);
}

const aurora_effect = Effect{
    .name = "aurora",
    .enabled = auroraEnabled,
    .eval = auroraEval,
    .draw = auroraDraw,
};

/// Same 64-stop rainbow as the Cairo renderer. Independent of tab width
/// and intensity, so every glowing tab shares this frame's colour field.
const AURORA_SAMPLES = 65;
fn auroraColors(t_us: f64) [AURORA_SAMPLES][3]f64 {
    var colors: [AURORA_SAMPLES][3]f64 = undefined;
    const tau = 2.0 * std.math.pi;
    const nb: f64 = @floatFromInt(AURORA_BLOBS);
    const drift = t_us / AURORA_DRIFT_US;

    var cx: [AURORA_BLOBS]f64 = undefined;
    var col: [AURORA_BLOBS][3]f64 = undefined;
    for (0..AURORA_BLOBS) |i| {
        const fi: f64 = @floatFromInt(i);
        const base = fi / nb;
        const wob = AURORA_WOBBLE * @sin(tau * (t_us / AURORA_WOBBLE_US + base));
        cx[i] = base - drift + wob; // toroidal distance handles the wrap
        col[i] = hsv2rgb(base, 1.0, 1.0);
    }

    const inv2s2 = 1.0 / (2.0 * AURORA_SIGMA * AURORA_SIGMA);
    for (&colors, 0..) |*color, k| {
        const pos = @as(f64, @floatFromInt(k)) / (AURORA_SAMPLES - 1);
        var r: f64 = 0;
        var g: f64 = 0;
        var b: f64 = 0;
        var sw: f64 = 0;
        for (0..AURORA_BLOBS) |i| {
            var d = pos - cx[i];
            d -= @round(d); // nearest copy on the [0,1) torus
            const wt = @exp(-d * d * inv2s2);
            r += wt * col[i][0];
            g += wt * col[i][1];
            b += wt * col[i][2];
            sw += wt;
        }
        if (sw > 0) {
            r /= sw;
            g /= sw;
            b /= sw;
        }
        // Re-saturate: push each channel away from the grey of the blend.
        const grey = (r + g + b) / 3.0;
        r = std.math.clamp(grey + (r - grey) * AURORA_SAT, 0.0, 1.0);
        g = std.math.clamp(grey + (g - grey) * AURORA_SAT, 0.0, 1.0);
        b = std.math.clamp(grey + (b - grey) * AURORA_SAT, 0.0, 1.0);
        color.* = .{ r, g, b };
    }
    return colors;
}

fn hsv2rgb(hv: f64, s: f64, v: f64) [3]f64 {
    const i = @floor(hv * 6.0);
    const f = hv * 6.0 - i;
    const p = v * (1.0 - s);
    const q = v * (1.0 - f * s);
    const tt = v * (1.0 - (1.0 - f) * s);
    return switch (@as(i32, @intFromFloat(@mod(i, 6.0)))) {
        0 => .{ v, tt, p },
        1 => .{ q, v, p },
        2 => .{ p, v, tt },
        3 => .{ p, q, v },
        4 => .{ tt, p, v },
        else => .{ v, p, q },
    };
}

// ── effect: inactive warning ─────────────────────────────────────────

/// Once past the silence threshold, the red wash and icon ramp in over this
/// long so the warning appears as a fade-in rather than a snap.
const WARN_RAMP_US: f64 = 1_500_000;
/// Pulse period of the flashing warning (microseconds).
const WARN_PULSE_US: f64 = 1_100_000;
/// Warning icon edge length (px), centred horizontally over the wash.
const WARN_ICON_PX: c_int = 16;
/// Resolved once per display; symbolic, recoloured at draw time.
var warn_paintable: ?*c.GdkPaintable = null;

fn warnEnabled(s: TabSettings) bool {
    return s.warn_inactive;
}

fn warnEval(page: *c.AdwTabPage, cfg: *const Config, _: TabSettings) Activation {
    const activity_ts = tsOf(page, ACTIVITY_KEY) orelse 0;
    const ack_ts = tsOf(page, ACK_KEY) orelse 0;
    const threshold: i64 = @as(i64, cfg.inactive_warn_secs) * 1_000_000;
    return warnActivation(activity_ts, ack_ts, c.g_get_monotonic_time(), threshold);
}

/// Warning strength for a tab whose activity has gone silent. Edge-triggered:
/// the warning fires only for output that arrived AFTER the last
/// acknowledgement, and only once that output has then been quiet for the
/// threshold. So: activity → silence → warn; dwell on the tab to ack → clear;
/// and it won't warn again until genuinely NEW activity goes silent. A tab
/// that never produced output, or whose latest output predates your last look
/// at it, never warns. Pure: testable core.
fn warnActivation(activity_ts: i64, ack_ts: i64, now: i64, threshold_us: i64) Activation {
    // No output at all, or everything since the last acknowledgement has been
    // seen → nothing unacknowledged to warn about.
    if (activity_ts <= 0 or activity_ts <= ack_ts) return .{};
    const idle = now - activity_ts;
    if (idle < threshold_us) return .{}; // still recent / not silent long enough
    const over: f64 = @floatFromInt(idle - threshold_us);
    const intensity = std.math.clamp(over / WARN_RAMP_US, 0.0, 1.0);
    // Always animating while warned: the icon and wash keep pulsing.
    return .{ .intensity = intensity, .animating = true };
}

/// Absolute monotonic-us time at which this page will start warning
/// (last unacknowledged output + threshold), or null if nothing unacknowledged
/// is pending (no output, or all output predates the last ack). The tab bar
/// schedules the single silence wake-up at the SOONEST such deadline across
/// all warn-enabled tabs.
pub fn warnDeadline(page: *c.AdwTabPage, threshold_us: i64) ?i64 {
    const activity_ts = tsOf(page, ACTIVITY_KEY) orelse 0;
    const ack_ts = tsOf(page, ACK_KEY) orelse 0;
    if (activity_ts <= 0 or activity_ts <= ack_ts) return null;
    return activity_ts + threshold_us;
}

fn warnDraw(_: *Renderer, _: *c.AdwTabPage, widget: *c.GtkWidget, snapshot: ?*c.GtkSnapshot, act: Activation) void {
    const w: f64 = @floatFromInt(c.gtk_widget_get_width(@ptrCast(widget)));
    const h: f64 = @floatFromInt(c.gtk_widget_get_height(@ptrCast(widget)));

    // Pulse 0.55..1.0 so even at the trough the warning stays readable.
    const t_us: f64 = @floatFromInt(c.g_get_monotonic_time());
    const phase = @sin(2.0 * std.math.pi * t_us / WARN_PULSE_US) * 0.5 + 0.5;
    const pulse = 0.55 + 0.45 * phase;
    const strength = act.intensity * pulse;

    // Red wash: faint at the top, denser toward the bottom border.
    var rect: c.graphene_rect_t = undefined;
    _ = c.graphene_rect_init(&rect, 0, 0, @floatCast(w), @floatCast(h));
    const stops = [_]c.GskColorStop{
        .{ .offset = 0, .color = .{ .red = 0.85, .green = 0.12, .blue = 0.12, .alpha = @floatCast(0.05 * strength) } },
        .{ .offset = 0.75, .color = .{ .red = 0.85, .green = 0.12, .blue = 0.12, .alpha = @floatCast(0.22 * strength) } },
        .{ .offset = 1, .color = .{ .red = 0.90, .green = 0.10, .blue = 0.10, .alpha = @floatCast(0.55 * strength) } },
    };
    var start: c.graphene_point_t = undefined;
    var end: c.graphene_point_t = undefined;
    _ = c.graphene_point_init(&start, 0, 0);
    _ = c.graphene_point_init(&end, 0, @floatCast(h));
    c.gtk_snapshot_append_linear_gradient(snapshot, &rect, &start, &end, &stops, stops.len);
    _ = c.graphene_rect_init(&rect, 0, @floatCast(h - 3), @floatCast(w), 3);
    const border: c.GdkRGBA = .{ .red = 0.92, .green = 0.10, .blue = 0.10, .alpha = @floatCast(@min(1.0, 0.85 * strength)) };
    c.gtk_snapshot_append_color(snapshot, &border, &rect);

    drawWarnIcon(widget, snapshot, h, strength);
}

/// Snapshot the cached `dialog-warning-symbolic` paintable, recoloured amber
/// and faded by the pulse, centred near the top of the tab.
fn drawWarnIcon(widget: *c.GtkWidget, snapshot: ?*c.GtkSnapshot, h: f64, strength: f64) void {
    const paintable = warnIcon(widget) orelse return;
    const sz: f64 = @floatFromInt(WARN_ICON_PX);
    const x = 6.0; // hug the leading edge, clear of the centred title
    const y = (h - sz) / 2.0;

    c.gtk_snapshot_save(snapshot);
    var pt: c.graphene_point_t = undefined;
    _ = c.graphene_point_init(&pt, @floatCast(x), @floatCast(y));
    c.gtk_snapshot_translate(snapshot, &pt);
    c.gtk_snapshot_push_opacity(snapshot, @floatCast(strength));

    // Symbolic recolour to amber; fall back to a plain snapshot if the
    // paintable isn't symbolic.
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(paintable)), c.gtk_symbolic_paintable_get_type()) != 0) {
        var color: c.GdkRGBA = .{ .red = 0.98, .green = 0.74, .blue = 0.18, .alpha = 1.0 };
        c.gtk_symbolic_paintable_snapshot_symbolic(@ptrCast(@alignCast(paintable)), snapshot, sz, sz, &color, 1);
    } else {
        c.gdk_paintable_snapshot(paintable, @ptrCast(snapshot), sz, sz);
    }

    c.gtk_snapshot_pop(snapshot); // opacity
    c.gtk_snapshot_restore(snapshot);
}

/// Resolve and cache the warning icon paintable for the widget's display.
fn warnIcon(widget: *c.GtkWidget) ?*c.GdkPaintable {
    if (warn_paintable) |p| return p;
    const display = c.gtk_widget_get_display(widget) orelse return null;
    const theme = c.gtk_icon_theme_get_for_display(display) orelse return null;
    const scale = c.gtk_widget_get_scale_factor(widget);
    const icon = c.gtk_icon_theme_lookup_icon(
        theme,
        "dialog-warning-symbolic",
        null,
        WARN_ICON_PX,
        if (scale > 0) scale else 1,
        c.GTK_TEXT_DIR_NONE,
        c.GTK_ICON_LOOKUP_FORCE_SYMBOLIC,
    ) orelse return null;
    // GtkIconPaintable IS a GdkPaintable; keep the ref for the process life.
    warn_paintable = @ptrCast(@alignCast(icon));
    return warn_paintable;
}

const inactive_warning_effect = Effect{
    .name = "inactive-warning",
    .enabled = warnEnabled,
    .eval = warnEval,
    .draw = warnDraw,
};

test "aurora intensity: full at the stamp, fades to zero past decay" {
    // No EMA: full while elapsed <= 0, linear fade, zero past the decay.
    try std.testing.expectEqual(@as(f64, 1.0), auroraIntensity(0, 0));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), auroraIntensity(@intFromFloat(GLOW_DECAY_US / 2.0), 0), 1e-9);
    try std.testing.expectEqual(@as(f64, 0.0), auroraIntensity(@intFromFloat(GLOW_DECAY_US), 0));
}

test "aurora sustain: a steady source holds full past the bare decay" {
    // A 1.5s-refresh source (htop) is held full for SUSTAIN_FACTOR× its
    // period, well past where the no-sustain curve would have faded out.
    const ema: i64 = 1_500_000;
    const at_decay: i64 = @intFromFloat(GLOW_DECAY_US);
    try std.testing.expectEqual(@as(f64, 0.0), auroraIntensity(at_decay, 0));
    try std.testing.expectEqual(@as(f64, 1.0), auroraIntensity(at_decay, ema));
}

test "inactive warning: silent below the threshold, ramps in above it" {
    const threshold: i64 = 60_000_000;
    const now: i64 = 1_000_000_000;
    // idle = now - activity_ts; ack_ts = 0 (never acknowledged → activity is
    // unacknowledged, so the gate is open and only the idle time matters).
    const at = struct {
        fn f(idle: i64, n: i64, th: i64) Activation {
            return warnActivation(n - idle, 0, n, th);
        }
    }.f;
    try std.testing.expectEqual(Activation{}, at(threshold - 1, now, threshold));
    try std.testing.expectEqual(@as(f64, 0.0), at(threshold, now, threshold).intensity);
    try std.testing.expect(at(threshold, now, threshold).animating);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), at(threshold + @as(i64, @intFromFloat(WARN_RAMP_US / 2.0)), now, threshold).intensity, 1e-9);
    try std.testing.expectEqual(@as(f64, 1.0), at(threshold + @as(i64, @intFromFloat(WARN_RAMP_US * 4.0)), now, threshold).intensity);
}

test "inactive warning: edge-triggered on activity, cleared by acknowledgement" {
    const threshold: i64 = 60_000_000;
    const now: i64 = 1_000_000_000;

    // Unacknowledged output that's been quiet past the threshold → warns.
    try std.testing.expectEqual(@as(f64, 1.0), warnActivation(now - threshold * 2, 0, now, threshold).intensity);

    // Acknowledged AFTER that output (ack newer than activity) → cleared, and
    // stays cleared no matter how much time passes (no NEW activity).
    try std.testing.expectEqual(Activation{}, warnActivation(now - threshold * 5, now - threshold, now, threshold));

    // New output arrived AFTER the acknowledgement and then went silent long
    // enough → warns again (a fresh activity→silence cycle).
    try std.testing.expectEqual(@as(f64, 1.0), warnActivation(now - threshold * 2, now - threshold * 3, now, threshold).intensity);

    // Never produced output → nothing to warn about, even if "seen" long ago.
    try std.testing.expectEqual(Activation{}, warnActivation(0, now - threshold * 9, now, threshold));
    try std.testing.expectEqual(Activation{}, warnActivation(0, 0, now, threshold));
}

test "aurora shares tiny textures per frame and preserves its gradient" {
    const t = std.testing;
    var renderer: Renderer = .{};
    defer renderer.deinit();
    try t.expect(renderer.prepare(1_000_000));
    const wash = renderer.wash.?;
    try t.expectEqual(@as(c_int, 65), c.gdk_texture_get_width(wash));
    try t.expectEqual(@as(c_int, 5), c.gdk_texture_get_height(wash));
    try t.expectEqual(@as(c_int, 1), c.gdk_texture_get_height(renderer.border.?));
    try t.expect(renderer.prepare(1_000_000));
    try t.expectEqual(wash, renderer.wash.?); // all tabs share one upload

    // gdk_texture_download returns native premultiplied ARGB32. Verify
    // the old wash's three alpha stops and its fully opaque footer.
    var pixels: [65 * 5]u32 = undefined;
    c.gdk_texture_download(wash, @ptrCast(&pixels), 65 * 4);
    try t.expectEqual(@as(u32, 10), pixels[0] >> 24);
    try t.expectEqual(@as(u32, 41), pixels[65 * 3] >> 24);
    try t.expectEqual(@as(u32, 97), pixels[65 * 4] >> 24);
    var border: [65]u32 = undefined;
    c.gdk_texture_download(renderer.border.?, @ptrCast(&border), 65 * 4);
    for (border) |pixel| try t.expectEqual(@as(u32, 255), pixel >> 24);

    try t.expect(renderer.prepare(2_000_000));
    var next: [65 * 5]u32 = undefined;
    c.gdk_texture_download(renderer.wash.?, @ptrCast(&next), 65 * 4);
    try t.expect(!std.mem.eql(u32, &pixels, &next)); // genuinely animated
}
