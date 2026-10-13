//! Recorded-motion replay (capability "motion-replay", 0xE8 block), the
//! engine half: per-connection packs assembled from `motion_pack`
//! chunks, and per-view RUNS — precomputed timed input steps (moves,
//! press/release, wheel, key edges) that `motionPump` emits from the
//! helper's own poll loop. Nothing sleeps and no thread exists: the
//! server shortens its poll timeout to the next due step.
//!
//! Every run is ANSWERED on every exit: completion posts the action's
//! result, and `motionCancel` (a superseding replay, navigation, the
//! browser going away, helper shutdown) releases whatever button or key
//! it still holds and posts a failure naming why.
//!
//! Idle DRIFT (capability "motion-drift") is the other per-view state:
//! opted into per view, it replays a recorded idle wander of the pointer
//! BETWEEN actions only. Anything else that touches the view (a run, a
//! pending semantic action, live or direct input, a hidden or browserless
//! view) stops the segment at once and restarts the rest before the
//! next one; drift moves the pointer only and holds nothing, so being
//! superseded needs no release.
//!
//! The planning is `src/motion/replay.zig` (pure); this module only
//! turns plans into CEF input through the same senders the direct path
//! uses.

const std = @import("std");
const cef = @import("cef");
const c = @import("cbindings");
const proto = @import("../protocol.zig");
const clock = @import("../../util/clock.zig");
const pack_mod = @import("../../motion/pack.zig");
const replay = @import("../../motion/replay.zig");
const host_mod = @import("../cefhost.zig");
const Host = host_mod.Host;
const View = host_mod.View;
const Pending = host_mod.Pending;

/// One connection's installed pack and its exclusion windows.
pub const ConnPack = struct {
    conn: u32,
    arena: std.heap.ArenaAllocator,
    pack: ?pack_mod.Pack = null,
    fitts: replay.Fitts = .{ .a = 0, .b = 0 },
    typical_burst: f64 = 1,
    recent_reach: replay.Recent = .{},
    recent_scroll: replay.Recent = .{},
    /// Assembly of the pack being sent (`motion_pack` chunks).
    rx: std.ArrayList(u8) = .empty,
    rx_serial: u32 = 0,
    rx_total: u32 = 0,

    fn deinit(self: *ConnPack, gpa: std.mem.Allocator) void {
        self.rx.deinit(gpa);
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const Step = struct {
    at: f64,
    kind: Kind,
    x: i32 = 0,
    y: i32 = 0,
    dx: i32 = 0,
    dy: i32 = 0,
    keysym: u32 = 0,
    mods: u32 = 0,
    text: [4]u8 = undefined,
    text_len: u8 = 0,

    pub const Kind = enum { move, down, up, wheel, key_down, key_up };
};

/// What finishing (or failing) a run answers.
pub const Done = union(enum) {
    /// A click or hover: a `sem_act_result` with the echo text.
    act: struct { sid: u32, msg: []u8 },
    /// A `motion_scroll`: an `ev_motion_done`.
    scroll: struct { req: u32 },
    /// `set_value` typing: on completion the commit read follows, which
    /// answers the action itself.
    typed: struct { sid: u32, guarded: bool, want: []u8 },
    /// `set_value` on a custom dropdown, its opening click: on
    /// completion the option `want` is looked up, and its pick replays
    /// too (`pick_option`).
    pick_open: struct { sid: u32, guarded: bool, want: []u8, conn: u32 },
    /// The dropdown option's click: on completion the control is read
    /// back, which answers the action with both replays' duration.
    pick_option: struct { sid: u32, guarded: bool, picked: []u8 },

    /// The `sem_act` id a failure is answered on, null for a scroll.
    fn sid(self: Done) ?u32 {
        return switch (self) {
            .act => |a| a.sid,
            .scroll => null,
            .typed => |t| t.sid,
            .pick_open => |p| p.sid,
            .pick_option => |p| p.sid,
        };
    }

    fn free(self: Done, gpa: std.mem.Allocator) void {
        switch (self) {
            .act => |a| gpa.free(a.msg),
            .scroll => {},
            .typed => |t| gpa.free(t.want),
            .pick_open => |p| gpa.free(p.want),
            .pick_option => |p| gpa.free(p.picked),
        }
    }
};

pub const Run = struct {
    steps: []Step,
    next: usize = 0,
    /// When step times count from; slides forward when the loop falls
    /// behind (`pumpView`).
    start_us: i64,
    /// When the run began, for the duration actually taken.
    began_us: i64,
    client_request: u32,
    done: Done,
    /// Input this run pressed and has not released yet.
    held_button: bool = false,
    held_key: u32 = 0,
    held_shift: bool = false,

    fn dueUs(self: *const Run) i64 {
        return self.start_us + @as(i64, @intFromFloat(self.steps[self.next].at * 1000));
    }

    /// Wall time the run took, slides included.
    fn durationMs(self: *const Run, now_us: i64) u32 {
        return @intCast(@max(@divFloor(now_us - self.began_us, 1000), 0));
    }
};

fn slotFor(self: *Host, conn: u32) ?*ConnPack {
    for (self.motion_packs.items) |s| if (s.conn == conn) return s;
    return null;
}

/// The loaded pack of connection `conn`, if any.
pub fn motionPackFor(self: *Host, conn: u32) ?*ConnPack {
    const s = slotFor(self, conn) orelse return null;
    return if (s.pack != null) s else null;
}

/// One `motion_pack` chunk from connection `conn`. The completing chunk
/// validates and installs the pack and answers `ev_motion_pack`; any
/// refusal leaves the connection with NO pack.
pub fn motionPackChunk(self: *Host, conn: u32, req: proto.MotionPack) void {
    const slot = slotFor(self, conn) orelse blk: {
        const s = self.gpa.create(ConnPack) catch return;
        s.* = .{ .conn = conn, .arena = .init(self.gpa) };
        self.motion_packs.append(self.gpa, s) catch {
            s.deinit(self.gpa);
            return;
        };
        break :blk s;
    };
    if (req.total == 0) {
        slot.pack = null;
        _ = slot.arena.reset(.free_all);
        slot.rx.clearRetainingCapacity();
        self.post(proto.EvMotionPack{ .serial = req.serial, .ok = 1, .reaches = 0, .keys = 0, .scroll = 0, .msg = "pack cleared" });
        return;
    }
    if (req.serial != slot.rx_serial or req.offset == 0) {
        slot.rx.clearRetainingCapacity();
        slot.rx_serial = req.serial;
        slot.rx_total = req.total;
    }
    const refuse = struct {
        fn f(h: *Host, s: *ConnPack, serial: u32, why: []const u8) void {
            s.pack = null;
            _ = s.arena.reset(.free_all);
            s.rx.clearRetainingCapacity();
            s.rx_total = 0;
            h.post(proto.EvMotionPack{ .serial = serial, .ok = 0, .reaches = 0, .keys = 0, .scroll = 0, .msg = why });
        }
    }.f;
    if (req.total > proto.MOTION_PACK_MAX or req.total != slot.rx_total) return refuse(self, slot, req.serial, "motion pack size is past the limit or changed mid-transfer");
    if (req.offset != slot.rx.items.len or req.offset + req.chunk.s.len > req.total) return refuse(self, slot, req.serial, "motion pack chunk out of order");
    slot.rx.appendSlice(self.gpa, req.chunk.s) catch return refuse(self, slot, req.serial, "out of memory assembling the motion pack");
    if (slot.rx.items.len < req.total) return;

    slot.pack = null;
    _ = slot.arena.reset(.free_all);
    var diag: pack_mod.Diag = .{};
    const parsed = pack_mod.parse(slot.arena.allocator(), slot.rx.items, &diag) catch |err| {
        var buf: [256]u8 = undefined;
        const why = if (err == error.Invalid)
            (std.fmt.bufPrint(&buf, "motion pack refused: {s}", .{diag.msg()}) catch "motion pack refused")
        else
            "out of memory parsing the motion pack";
        return refuse(self, slot, req.serial, why);
    };
    slot.rx.clearAndFree(self.gpa);
    slot.pack = parsed;
    slot.fitts = replay.Fitts.fit(parsed.reaches);
    slot.typical_burst = replay.typicalBurst(parsed, 1);
    slot.recent_reach = .{};
    slot.recent_scroll = .{};
    const s = parsed.summary();
    self.post(proto.EvMotionPack{
        .serial = req.serial,
        .ok = 1,
        .reaches = @intCast(s.reaches),
        .keys = @intCast(s.keys),
        .scroll = @intCast(s.scroll),
        .msg = "",
    });
}

pub fn motionDropConn(self: *Host, conn: u32) void {
    // Drift replays the connection's pack, which goes with it.
    for (self.views.items) |v| {
        if (v.motion_drift) |d| if (d.conn == conn) motionDriftFree(self, v);
    }
    var i: usize = 0;
    while (i < self.motion_packs.items.len) {
        if (self.motion_packs.items[i].conn == conn) {
            self.motion_packs.swapRemove(i).deinit(self.gpa);
        } else i += 1;
    }
}

pub fn motionDeinit(self: *Host) void {
    for (self.views.items) |v| {
        motionCancel(self, v, "the browser helper shut down during the motion replay");
        motionDriftFree(self, v);
    }
    for (self.motion_packs.items) |s| s.deinit(self.gpa);
    self.motion_packs.deinit(self.gpa);
}

fn seededRng() replay.Rng {
    var seed: u64 = undefined;
    if (c.getentropy(&seed, @sizeOf(u64)) != 0) seed = @bitCast(clock.nowNs());
    return replay.Rng.init(seed);
}

/// Start `steps` on `v`. `began_us`, when set, is when an earlier run of
/// the same action began, so the reported duration covers both.
fn begin(self: *Host, v: *View, steps: []Step, done: Done, began_us: ?i64) void {
    motionCancel(self, v, "superseded by a newer replayed action on this view");
    motionDriftYield(self, v);
    const run = self.gpa.create(Run) catch {
        self.gpa.free(steps);
        finishFailed(self, v, done, self.active_sem_request, 0, "out of memory starting the motion replay");
        return;
    };
    const now = clock.nowUs();
    run.* = .{ .steps = steps, .start_us = now, .began_us = began_us orelse now, .client_request = self.active_sem_request, .done = done };
    v.motion_run = run;
    // A plan's first step is due at once; emit it now rather than a
    // poll turn later.
    pumpView(self, v, now);
}

/// Replay a reach onto `rect` (the element's centre x, y and size w, h,
/// logical px) and, for a click, the press. `msg` is the echo the
/// result carries; it is copied.
pub fn motionStartPointer(self: *Host, v: *View, p: *const Pending, rect: [4]i32, click: bool, msg: []const u8) void {
    const owned = self.gpa.dupe(u8, msg) catch
        return postAct(self, v, p.sid, 0, "out of memory starting the motion replay", 0);
    motionStartReach(self, v, p.motion_conn, rect, click, .{ .act = .{ .sid = p.sid, .msg = owned } }, null);
}

/// Replay a reach (and for a click, the press) onto `rect` from
/// connection `conn`'s pack, answered through `done`, which this owns
/// from here on: a replay that cannot start answers it as failed.
pub fn motionStartReach(self: *Host, v: *View, conn: u32, rect: [4]i32, click: bool, done: Done, began_us: ?i64) void {
    const failed = struct {
        fn f(h: *Host, view: *View, d: Done, why: []const u8) void {
            finishFailed(h, view, d, h.active_sem_request, 0, why);
        }
    }.f;
    const slot = motionPackFor(self, conn) orelse
        return failed(self, v, done, "motion replay was asked for but this connection's motion pack is gone; nothing was clicked");
    const pk = slot.pack.?;
    const vw: f64 = @floatFromInt(@max(v.w, 1));
    const vh: f64 = @floatFromInt(@max(v.h, 1));
    var box = [4]f64{
        @as(f64, @floatFromInt(rect[0])) - @as(f64, @floatFromInt(rect[2])) / 2,
        @as(f64, @floatFromInt(rect[1])) - @as(f64, @floatFromInt(rect[3])) / 2,
        @floatFromInt(rect[2]),
        @floatFromInt(rect[3]),
    };
    // Only the visible part of the element can be reached.
    const x0 = std.math.clamp(box[0], 0, vw - 1);
    const y0 = std.math.clamp(box[1], 0, vh - 1);
    box = .{ x0, y0, @max(@min(box[0] + box[2], vw) - x0, 1), @max(@min(box[1] + box[3], vh) - y0, 1) };
    var prng = seededRng();
    const rng = prng.random();
    const from = v.motion_ptr orelse replay.entryPoint(vw, vh, .{ box[0] + box[2] / 2, box[1] + box[3] / 2 }, rng);
    const plan = replay.planReach(self.gpa, pk, slot.fitts, from, box, &slot.recent_reach, rng) catch |err| {
        const why = if (err == error.NoReaches) "motion replay was asked for but the motion pack holds no reaches; nothing was clicked" else "out of memory planning the motion replay";
        return failed(self, v, done, why);
    };
    defer plan.deinit(self.gpa);
    const n = plan.moves.len + @as(usize, if (click) 2 else 0);
    const steps = self.gpa.alloc(Step, n) catch return failed(self, v, done, "out of memory planning the motion replay");
    for (plan.moves, 0..) |m, i| steps[i] = .{ .at = m.t, .kind = .move, .x = @intFromFloat(@round(m.x)), .y = @intFromFloat(@round(m.y)) };
    const land = plan.moves[plan.moves.len - 1];
    if (click) {
        const lx: i32 = @intFromFloat(@round(land.x));
        const ly: i32 = @intFromFloat(@round(land.y));
        steps[n - 2] = .{ .at = plan.press, .kind = .down, .x = lx, .y = ly };
        steps[n - 1] = .{ .at = plan.release, .kind = .up, .x = lx, .y = ly };
    }
    begin(self, v, steps, done, began_us);
}

/// Type `p.arg` with key timing drawn from the pack. On completion the
/// commit read runs exactly as after a direct `typeKeys`. Returns false
/// (having answered the action) when no replay can start.
pub fn motionStartTyping(self: *Host, v: *View, p: *const Pending) bool {
    const slot = motionPackFor(self, p.motion_conn) orelse {
        postAct(self, v, p.sid, 0, "motion replay was asked for but this connection's motion pack is gone; nothing was typed", 0);
        return false;
    };
    const pk = slot.pack.?;
    var strokes: std.ArrayList(host_mod.Keystroke) = .empty;
    defer strokes.deinit(self.gpa);
    var classes: std.ArrayList(pack_mod.KeyClass) = .empty;
    defer classes.deinit(self.gpa);
    var shifted: std.ArrayList(bool) = .empty;
    defer shifted.deinit(self.gpa);
    var it = std.unicode.Utf8Iterator{ .bytes = p.arg, .i = 0 };
    while (it.nextCodepointSlice()) |slice| {
        const ks = self.keystroke(slice) orelse continue;
        const cp = std.unicode.utf8Decode(slice) catch continue;
        strokes.append(self.gpa, ks) catch return failOom(self, v, p.sid);
        classes.append(self.gpa, pack_mod.KeyClass.of(cp)) catch return failOom(self, v, p.sid);
        shifted.append(self.gpa, ks.shift) catch return failOom(self, v, p.sid);
    }
    const want = self.gpa.dupe(u8, p.arg) catch return failOom(self, v, p.sid);
    if (strokes.items.len == 0) {
        const none = self.gpa.alloc(Step, 0) catch return failOomFree(self, v, p.sid, want);
        begin(self, v, none, .{ .typed = .{ .sid = p.sid, .guarded = p.guarded, .want = want } }, null);
        return true;
    }
    var prng = seededRng();
    const times = replay.planTyping(self.gpa, pk, classes.items, shifted.items, prng.random()) catch |err| {
        self.gpa.free(want);
        postAct(self, v, p.sid, 0, if (err == error.NoKeys) "motion replay was asked for but the motion pack holds no key timings; nothing was typed" else "out of memory planning the typing replay", 0);
        return false;
    };
    defer self.gpa.free(times);
    const owned = typingSteps(self.gpa, strokes.items, times) catch return failOomFree(self, v, p.sid, want);
    begin(self, v, owned, .{ .typed = .{ .sid = p.sid, .guarded = p.guarded, .want = want } }, null);
    return true;
}

/// Key edges for the planned `times`, Shift wrapped around its key.
fn typingSteps(gpa: std.mem.Allocator, strokes: []const host_mod.Keystroke, times: []const replay.KeyTime) ![]Step {
    var steps: std.ArrayList(Step) = .empty;
    errdefer steps.deinit(gpa);
    for (strokes, times) |ks, t| {
        const mods: u32 = if (ks.shift) proto.mod_shift else 0;
        var down: Step = .{ .at = t.down, .kind = .key_down, .keysym = ks.keysym, .mods = mods };
        const own = ks.text[0..ks.text_len];
        @memcpy(down.text[0..own.len], own);
        down.text_len = ks.text_len;
        if (ks.shift) try steps.append(gpa, .{ .at = t.shift_down, .kind = .key_down, .keysym = shift_sym, .mods = proto.mod_shift });
        try steps.append(gpa, down);
        try steps.append(gpa, .{ .at = t.up, .kind = .key_up, .keysym = ks.keysym, .mods = mods });
        if (ks.shift) try steps.append(gpa, .{ .at = t.shift_up, .kind = .key_up, .keysym = shift_sym, .mods = 0 });
    }
    return steps.toOwnedSlice(gpa);
}

const shift_sym: u32 = 0xffe1;

fn failOom(self: *Host, v: *View, sid: u32) bool {
    postAct(self, v, sid, 0, "out of memory planning the typing replay", 0);
    return false;
}

fn failOomFree(self: *Host, v: *View, sid: u32, want: []u8) bool {
    self.gpa.free(want);
    return failOom(self, v, sid);
}

/// A `motion_scroll`: wheel bursts from the pack, at the replayed
/// pointer when there is one.
pub fn motionScroll(self: *Host, conn: u32, req: proto.MotionScroll) void {
    const fail = struct {
        fn f(h: *Host, view: u32, r: u32, why: []const u8) void {
            h.post(proto.EvMotionDone{ .view = view, .req = r, .ok = 0, .duration_ms = 0, .msg = why });
        }
    }.f;
    // Answered even without a view: the client waits on this `req`.
    const v = self.findWake(req.view) orelse return fail(self, req.view, req.req, "no view with that id; nothing was scrolled");
    const slot = motionPackFor(self, conn) orelse return fail(self, v.id, req.req, "motion replay was asked for but no motion pack is loaded on this connection; nothing was scrolled");
    var prng = seededRng();
    const plan = replay.planScroll(self.gpa, slot.pack.?, req.dx, req.dy, slot.typical_burst, &slot.recent_scroll, prng.random()) catch |err| {
        return fail(self, v.id, req.req, if (err == error.NoScroll) "motion replay was asked for but the motion pack holds no scroll bursts; nothing was scrolled" else "out of memory planning the scroll replay");
    };
    defer self.gpa.free(plan);
    const at: [2]i32 = if (v.motion_ptr) |pt| .{ @intFromFloat(@round(pt[0])), @intFromFloat(@round(pt[1])) } else .{ req.x, req.y };
    const steps = self.gpa.alloc(Step, plan.len) catch return fail(self, v.id, req.req, "out of memory planning the scroll replay");
    for (plan, 0..) |w, i| steps[i] = .{ .at = w.t, .kind = .wheel, .x = at[0], .y = at[1], .dx = w.dx, .dy = w.dy };
    const saved = self.active_sem_request;
    self.active_sem_request = 0;
    defer self.active_sem_request = saved;
    begin(self, v, steps, .{ .scroll = .{ .req = req.req } }, null);
}

fn postAct(self: *Host, v: *View, sid: u32, ok: u8, msg: []const u8, duration: u32) void {
    self.post(proto.SemActResult{
        .view = v.id,
        .id = sid,
        .ok = ok,
        .msg = msg,
        .motion = @intFromEnum(proto.MotionResult.replayed),
        .duration_ms = duration,
    });
}

fn emit(self: *Host, v: *View, run: *Run, s: Step) void {
    switch (s.kind) {
        .move, .down, .up => {
            const pt = host_mod.viewPoint(v, s.x, s.y);
            var ev = cef.cef_mouse_event_t{ .x = pt.x, .y = pt.y, .modifiers = if (s.kind == .up) cef.EVENTFLAG_LEFT_MOUSE_BUTTON else 0 };
            switch (s.kind) {
                .move => host_mod.withHostArgs(v, host_mod.sendMove, .{ &ev, @as(c_int, 0) }),
                .down => {
                    host_mod.withHostArgs(v, host_mod.setFocus, .{@as(c_int, 1)});
                    host_mod.withHostArgs(v, host_mod.sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 0), @as(c_int, 1) });
                    run.held_button = true;
                },
                .up => {
                    host_mod.withHostArgs(v, host_mod.sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 1), @as(c_int, 1) });
                    run.held_button = false;
                },
                else => unreachable,
            }
            v.motion_ptr = .{ @floatFromInt(s.x), @floatFromInt(s.y) };
        },
        .wheel => self.scroll(.{ .view = v.id, .x = s.x, .y = s.y, .dx = s.dx, .dy = s.dy, .mods = 0 }),
        .key_down, .key_up => {
            if (s.kind == .key_down and run.held_key == 0 and run.held_shift == false and run.next == 0)
                host_mod.withHostArgs(v, host_mod.setFocus, .{@as(c_int, 1)});
            self.keyTo(v, .{
                .view = v.id,
                .kind = @intFromEnum(if (s.kind == .key_down) proto.KeyKind.down else proto.KeyKind.up),
                .keyval = s.keysym,
                .keycode = 0,
                .mods = s.mods,
                .text = s.text[0..s.text_len],
            });
            const down = s.kind == .key_down;
            if (s.keysym == shift_sym) run.held_shift = down else run.held_key = if (down) s.keysym else 0;
        },
    }
}

/// Emit the next step once it is due: ONE per turn. A loop that fell
/// behind (load, a long engine turn) must not flush the backlog as a
/// burst of same-instant moves, which is exactly the machine pattern
/// replay exists to avoid; the rest of the plan slides by the lag
/// instead, so the page still sees the recorded spacing, only later.
fn pumpView(self: *Host, v: *View, now_us: i64) void {
    const run = v.motion_run orelse return;
    if (run.next < run.steps.len) {
        const due_us = run.dueUs();
        if (due_us > now_us) return;
        emit(self, v, run, run.steps[run.next]);
        run.next += 1;
        run.start_us += now_us - due_us;
        if (run.next < run.steps.len) return;
    }
    v.motion_run = null;
    finishOk(self, v, run);
}

/// Emit the next due step of every run, and of every idle drift.
pub fn motionPump(self: *Host) void {
    const now = clock.nowUs();
    for (self.views.items) |v| {
        if (v.motion_run != null) pumpView(self, v, now);
        if (v.motion_drift != null) pumpDrift(self, v, now);
    }
}

/// Milliseconds until the next due step of any run or drift, or null
/// with none.
pub fn motionWaitMs(self: *Host) ?i64 {
    const now = clock.nowUs();
    var best: ?i64 = null;
    for (self.views.items) |v| {
        const due: i64 = if (v.motion_run) |run| blk: {
            if (run.next >= run.steps.len) return 0;
            break :blk run.dueUs();
        } else if (v.motion_drift) |d| (driftDueUs(v, d) orelse continue) else continue;
        const wait = @max(@divFloor(due - now + 999, 1000), 0);
        best = if (best) |b| @min(b, wait) else wait;
    }
    return best;
}

fn finishOk(self: *Host, v: *View, run: *Run) void {
    defer {
        self.gpa.free(run.steps);
        self.gpa.destroy(run);
    }
    const saved = self.active_sem_request;
    self.active_sem_request = run.client_request;
    defer self.active_sem_request = saved;
    const duration = run.durationMs(clock.nowUs());
    switch (run.done) {
        .act => |a| {
            defer self.gpa.free(a.msg);
            postAct(self, v, a.sid, 1, a.msg, duration);
        },
        .scroll => |s| self.post(proto.EvMotionDone{ .view = v.id, .req = s.req, .ok = 1, .duration_ms = duration, .msg = "" }),
        .typed => |t| {
            defer self.gpa.free(t.want);
            self.semCommitTyped(v, t.sid, t.guarded, t.want, duration);
        },
        // Both take ownership of the owned text.
        .pick_open => |p| self.semPickOption(v, p.sid, p.guarded, p.want, p.conn, run.began_us),
        .pick_option => |p| self.semPickChosen(v, p.sid, p.guarded, p.picked, duration),
    }
}

fn finishFailed(self: *Host, v: *View, done: Done, client_request: u32, duration: u32, why: []const u8) void {
    const saved = self.active_sem_request;
    self.active_sem_request = client_request;
    defer self.active_sem_request = saved;
    defer done.free(self.gpa);
    if (done.sid()) |sid| {
        postAct(self, v, sid, 0, why, duration);
    } else switch (done) {
        .scroll => |s| self.post(proto.EvMotionDone{ .view = v.id, .req = s.req, .ok = 0, .duration_ms = duration, .msg = why }),
        else => unreachable,
    }
}

/// Stop the view's run, if any: release what it holds and answer it
/// with `why`.
pub fn motionCancel(self: *Host, v: *View, why: []const u8) void {
    const run = v.motion_run orelse return;
    v.motion_run = null;
    defer {
        self.gpa.free(run.steps);
        self.gpa.destroy(run);
    }
    if (v.browser != null) {
        if (run.held_button) if (v.motion_ptr) |pt| {
            const vp = host_mod.viewPoint(v, @intFromFloat(pt[0]), @intFromFloat(pt[1]));
            var ev = cef.cef_mouse_event_t{ .x = vp.x, .y = vp.y, .modifiers = cef.EVENTFLAG_LEFT_MOUSE_BUTTON };
            host_mod.withHostArgs(v, host_mod.sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 1), @as(c_int, 1) });
        };
        if (run.held_key != 0) self.keyTo(v, .{ .view = v.id, .kind = @intFromEnum(proto.KeyKind.up), .keyval = run.held_key, .keycode = 0, .mods = 0, .text = "" });
        if (run.held_shift) self.keyTo(v, .{ .view = v.id, .kind = @intFromEnum(proto.KeyKind.up), .keyval = shift_sym, .keycode = 0, .mods = 0, .text = "" });
    }
    const done_ms: u32 = if (run.next > 0) @intFromFloat(@max(@round(run.steps[run.next - 1].at), 0)) else 0;
    finishFailed(self, v, run.done, run.client_request, done_ms, why);
}

// -- idle drift (capability "motion-drift") ---------------------------

/// One view's idle drift: the connection whose pack it replays, when it
/// may move next, and the segment being replayed (empty while resting).
pub const Drift = struct {
    conn: u32,
    /// Seeded once per opt-in, so a busy view's every poll turn costs no
    /// entropy read.
    rng: replay.Rng,
    clock: replay.DriftClock = .{},
    recent: replay.Recent = .{},
    moves: []replay.Move = &.{},
    next: usize = 0,
    /// When the segment's move times count from; slides like a run's.
    start_us: i64 = 0,
    /// The view was busy at the last turn: the rest restarts once it is
    /// not, so it counts from the END of an action, not its start.
    blocked: bool = false,

    fn stopSegment(self: *Drift, gpa: std.mem.Allocator) void {
        gpa.free(self.moves);
        self.moves = &.{};
        self.next = 0;
    }

    /// Stop any segment and rest a full rest from `now_us` on.
    fn yieldAt(self: *Drift, gpa: std.mem.Allocator, now_us: i64) void {
        self.stopSegment(gpa);
        self.clock.yield(nowMsF(now_us), self.rng.random());
    }
};

fn nowMsF(now_us: i64) f64 {
    return @as(f64, @floatFromInt(now_us)) / 1000;
}

/// `motion_drift`: turn idle drift on or off for a view, from connection
/// `conn`'s pack; always answered by `ev_motion_done`.
pub fn motionDriftSet(self: *Host, conn: u32, req: proto.MotionDrift) void {
    const answer = struct {
        fn f(h: *Host, view: u32, r: u32, ok: u8, msg: []const u8) void {
            h.post(proto.EvMotionDone{ .view = view, .req = r, .ok = ok, .duration_ms = 0, .msg = msg });
        }
    }.f;
    const v = self.find(req.view) orelse return answer(self, req.view, req.req, 0, "no view with that id; idle drift was not changed");
    if (req.on == 0) {
        motionDriftFree(self, v);
        return answer(self, v.id, req.req, 1, "idle drift off");
    }
    const slot = motionPackFor(self, conn) orelse
        return answer(self, v.id, req.req, 0, "idle drift was asked for but no motion pack is loaded on this connection; the pointer stays still");
    if (!replay.driftUsable(slot.pack.?))
        return answer(self, v.id, req.req, 0, "idle drift was asked for but the motion pack holds no idle segment in which the pointer moved; the pointer stays still");
    const d = v.motion_drift orelse blk: {
        const fresh = self.gpa.create(Drift) catch return answer(self, v.id, req.req, 0, "out of memory starting idle drift");
        fresh.* = .{ .conn = conn, .rng = seededRng() };
        v.motion_drift = fresh;
        break :blk fresh;
    };
    d.conn = conn;
    d.yieldAt(self.gpa, clock.nowUs());
    answer(self, v.id, req.req, 1, "idle drift on");
}

/// Something other than drift touched the view: stop the segment and
/// rest before the next. A no-op when drift is off.
pub fn motionDriftYield(self: *Host, v: *View) void {
    const d = v.motion_drift orelse return;
    d.yieldAt(self.gpa, clock.nowUs());
}

/// Turn the view's drift off and free it.
pub fn motionDriftFree(self: *Host, v: *View) void {
    const d = v.motion_drift orelse return;
    v.motion_drift = null;
    d.stopSegment(self.gpa);
    self.gpa.destroy(d);
}

/// Drift may not move now: an action runs or is in flight, or nothing
/// is there to move a pointer over.
fn driftBlocked(v: *const View) bool {
    if (v.motion_run != null or v.hidden or v.discarded or v.browser == null) return true;
    for (v.pending.items) |p| if (p.kind.isAction()) return true;
    return false;
}

/// When drift next wants a turn, null when it is blocked or has no
/// pointer to move.
fn driftDueUs(v: *const View, d: *const Drift) ?i64 {
    if (driftBlocked(v) or v.motion_ptr == null) return null;
    // Just unblocked: the rest restarts from now, on this very turn.
    if (d.blocked) return 0;
    if (d.next < d.moves.len) return d.start_us + @as(i64, @intFromFloat(d.moves[d.next].t * 1000));
    return @intFromFloat(d.clock.rest_until * 1000);
}

/// One drift turn: rest, start a segment from where the pointer is, or
/// emit its next due move (ONE per turn, sliding like a run).
fn pumpDrift(self: *Host, v: *View, now_us: i64) void {
    const d = v.motion_drift orelse return;
    if (driftBlocked(v)) {
        if (!d.blocked) d.stopSegment(self.gpa);
        d.blocked = true;
        return;
    }
    if (d.blocked) {
        d.blocked = false;
        return d.yieldAt(self.gpa, now_us);
    }
    const now_ms = nowMsF(now_us);
    if (d.next >= d.moves.len) {
        if (!d.clock.due(now_ms)) return;
        // A pointer that never entered the view has no resting place.
        const from = v.motion_ptr orelse return d.clock.rest(now_ms, d.rng.random());
        // The connection cleared its pack: there is nothing left to replay.
        const slot = motionPackFor(self, d.conn) orelse return motionDriftFree(self, v);
        d.stopSegment(self.gpa);
        const moves = replay.planDrift(self.gpa, slot.pack.?, from, @floatFromInt(@max(v.w, 1)), @floatFromInt(@max(v.h, 1)), &d.recent, d.rng.random()) catch |err| switch (err) {
            // A replacement pack without drift: nothing left to replay.
            error.NoIdle => return motionDriftFree(self, v),
            else => return d.clock.rest(now_ms, d.rng.random()),
        };
        if (moves.len == 0) {
            self.gpa.free(moves);
            return d.clock.rest(now_ms, d.rng.random());
        }
        d.moves = moves;
        d.start_us = now_us;
    }
    const m = d.moves[d.next];
    const due_us = d.start_us + @as(i64, @intFromFloat(m.t * 1000));
    if (due_us > now_us) return;
    const x: i32 = @intFromFloat(m.x);
    const y: i32 = @intFromFloat(m.y);
    const pt = host_mod.viewPoint(v, x, y);
    var ev = cef.cef_mouse_event_t{ .x = pt.x, .y = pt.y, .modifiers = 0 };
    host_mod.withHostArgs(v, host_mod.sendMove, .{ &ev, @as(c_int, 0) });
    v.motion_ptr = .{ m.x, m.y };
    d.next += 1;
    d.start_us += now_us - due_us;
    if (d.next >= d.moves.len) {
        d.stopSegment(self.gpa);
        d.clock.rest(now_ms, d.rng.random());
    }
}
