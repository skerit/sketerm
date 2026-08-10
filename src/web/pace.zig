//! Adaptive frame pacing for a browser view: how often the client asks
//! the engine for a frame, and when it stops asking.
//!
//! Pure state machine — no GTK, no CEF, no clock of its own (every entry
//! point takes `now_us`), so both test roots can exercise it. The GTK
//! half lives in `src/ui/webface.zig`, which owns the two timers this
//! machine decides between:
//!
//!   idle   — a slow GLib timeout (`idle_interval_us`) asks for a frame
//!            a few times a second, so a change is still noticed. NO
//!            frame-clock tick is installed in this state; see the
//!            `tick_id` docblock in `src/ui/terminal_surface.zig` for
//!            why an idle tick is a crash and not a mere waste.
//!   active — a frame-clock tick paces requests at the display's real
//!            refresh (120/165Hz), clamped by the configured cap.
//!
//! Input promotes to `active` immediately, so the first paint after a
//! keystroke or a click has no added latency. A paint arriving while
//! idle promotes too — that is a page that started animating on its own.
//! `dry_frames` consecutive requests that produced no paint demote back.

const std = @import("std");

pub const State = enum { idle, active };

/// Requests per second while idle. Slow enough to cost nothing, fast
/// enough that a page which starts moving on its own is noticed within
/// a fifth of a second — and, deliberately, faster than the helper's
/// own watchdog, so in normal operation the GUI is always the pacer.
pub const idle_fps: u16 = 5;

/// Assumed display rate before a frame clock has reported one.
pub const default_display_fps: u16 = 60;

/// Clamp on the configured cap: below 5 the page would feel broken,
/// above 1000 nothing real exists.
pub const min_cap_fps: u16 = 5;
pub const max_cap_fps: u16 = 1000;

pub const Pacer = struct {
    state: State = .idle,
    /// Configured ceiling; 0 = follow the display.
    cap_fps: u16 = 0,
    /// What the frame clock last reported for the CURRENT output. A
    /// window dragged from the 60Hz panel to the 165Hz one changes this
    /// without any config change.
    display_fps: u16 = default_display_fps,
    /// Consecutive requests since the last paint. Reset by `notePaint`.
    dry: u32 = 0,
    /// Monotonic microseconds of the last request sent.
    last_req_us: i64 = 0,

    /// Frames per second this view may request right now.
    pub fn effectiveFps(self: *const Pacer) u16 {
        const display = if (self.display_fps == 0) default_display_fps else self.display_fps;
        if (self.cap_fps == 0) return display;
        return @min(self.cap_fps, display);
    }

    /// Minimum spacing between two requests in the active state.
    ///
    /// Scaled by 15/16 rather than exactly 1/fps: the tick fires ON the
    /// refresh boundary, and a hair of jitter would otherwise push every
    /// other tick past the interval and halve the achieved rate.
    pub fn minIntervalUs(self: *const Pacer) i64 {
        const fps: i64 = @intCast(@max(self.effectiveFps(), 1));
        return @divTrunc(1_000_000 * 15, fps * 16);
    }

    pub fn idleIntervalUs() i64 {
        return @divTrunc(1_000_000, @as(i64, idle_fps));
    }

    /// How many dry requests end the active state — about a quarter of
    /// a second at whatever rate this view runs at, and never fewer than
    /// 8 so a capped-to-5fps view still gets a fair look.
    pub fn dryLimit(self: *const Pacer) u32 {
        return @max(8, @as(u32, self.effectiveFps()) / 4);
    }

    /// Any input, navigation or geometry change: go active NOW. True
    /// when the caller must install the frame-clock tick.
    pub fn promote(self: *Pacer) bool {
        self.dry = 0;
        if (self.state == .active) return false;
        self.state = .active;
        return true;
    }

    /// A paint landed. True when this promoted an idle view — a page
    /// that started moving without being touched.
    pub fn notePaint(self: *Pacer) bool {
        return self.promote();
    }

    /// Whether the active state may send a request at `now_us`.
    pub fn dueAt(self: *const Pacer, now_us: i64) bool {
        if (self.state != .active) return false;
        return now_us - self.last_req_us >= self.minIntervalUs();
    }

    /// Record a request the caller just sent.
    pub fn noteRequest(self: *Pacer, now_us: i64) void {
        self.last_req_us = now_us;
        self.dry +|= 1;
    }

    /// Whether the active state has gone quiet long enough to stop the
    /// tick. Only meaningful in `active`.
    pub fn demoteDue(self: *const Pacer) bool {
        return self.state == .active and self.dry >= self.dryLimit();
    }

    pub fn demote(self: *Pacer) void {
        self.state = .idle;
        self.dry = 0;
    }

    /// Leaving the screen (background tab, teardown) is not idleness —
    /// it stops the pacing entirely, and the next `promote` starts over.
    pub fn stop(self: *Pacer) void {
        self.state = .idle;
        self.dry = 0;
        self.last_req_us = 0;
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "cap 0 follows the display, a cap clamps it, and neither can raise it" {
    var p = Pacer{ .display_fps = 165 };
    try std.testing.expectEqual(@as(u16, 165), p.effectiveFps());
    p.cap_fps = 30;
    try std.testing.expectEqual(@as(u16, 30), p.effectiveFps());
    // A cap above the display never asks for more than the display.
    p.cap_fps = 240;
    try std.testing.expectEqual(@as(u16, 165), p.effectiveFps());
}

test "the active interval lets a 165Hz tick through on every frame" {
    var p = Pacer{ .display_fps = 165 };
    _ = p.promote();
    const frame_us: i64 = @divTrunc(1_000_000, 165);
    var now: i64 = 1_000_000;
    var sent: u32 = 0;
    var i: usize = 0;
    while (i < 165) : (i += 1) {
        if (p.dueAt(now)) {
            p.noteRequest(now);
            sent += 1;
        }
        now += frame_us;
    }
    // Every tick is due: the interval is deliberately shorter than the
    // frame period so jitter cannot halve the rate.
    try std.testing.expectEqual(@as(u32, 165), sent);
}

test "a 30fps cap on a 165Hz tick sends about 30 requests per second" {
    var p = Pacer{ .display_fps = 165, .cap_fps = 30 };
    _ = p.promote();
    const frame_us: i64 = @divTrunc(1_000_000, 165);
    var now: i64 = 1_000_000;
    var sent: u32 = 0;
    var i: usize = 0;
    while (i < 165) : (i += 1) {
        if (p.dueAt(now)) {
            p.noteRequest(now);
            sent += 1;
        }
        now += frame_us;
    }
    // Requests can only happen on a tick boundary, and 165 is not a
    // multiple of 30 — so a 30fps cap on a 165Hz clock lands on every
    // 6th tick, i.e. ~27.5/s. A cap is a ceiling; under-delivering by a
    // tick is correct, exceeding it would not be.
    try std.testing.expect(sent >= 26 and sent <= 30);
}

test "dry requests demote, a paint keeps the view active" {
    var p = Pacer{ .display_fps = 120 };
    try std.testing.expect(p.promote());
    try std.testing.expect(!p.promote()); // idempotent while active

    var now: i64 = 0;
    const frame_us: i64 = @divTrunc(1_000_000, 120);
    // A painting page never demotes, however long it runs.
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        if (p.dueAt(now)) {
            p.noteRequest(now);
            _ = p.notePaint();
        }
        try std.testing.expect(!p.demoteDue());
        now += frame_us;
    }

    // A page that stops painting demotes after dryLimit requests, i.e.
    // about a quarter of a second.
    const limit = p.dryLimit();
    try std.testing.expectEqual(@as(u32, 30), limit);
    i = 0;
    while (i < limit) : (i += 1) {
        try std.testing.expect(!p.demoteDue());
        while (!p.dueAt(now)) now += frame_us;
        p.noteRequest(now);
    }
    try std.testing.expect(p.demoteDue());
    p.demote();
    try std.testing.expectEqual(State.idle, p.state);
    // ... and an idle view never asks through the tick path again.
    try std.testing.expect(!p.dueAt(now + 1_000_000));
}

test "a paint on an idle view promotes it" {
    var p = Pacer{};
    p.demote();
    try std.testing.expect(p.notePaint());
    try std.testing.expectEqual(State.active, p.state);
}

test "stop clears the pacing state entirely" {
    var p = Pacer{ .display_fps = 165 };
    _ = p.promote();
    p.noteRequest(500);
    p.stop();
    try std.testing.expectEqual(State.idle, p.state);
    try std.testing.expectEqual(@as(i64, 0), p.last_req_us);
    try std.testing.expectEqual(@as(u32, 0), p.dry);
}
