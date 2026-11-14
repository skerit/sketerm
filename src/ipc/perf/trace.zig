//! Summary of a Chrome trace (`{"traceEvents":[...]}` or a bare array) for the tab's renderer main thread, streamed.
//!
//! The file is read twice and never held whole: pass one finds the main
//! thread (the renderer `TracingStartedInBrowser` / `FrameCommittedInBrowser`
//! name, its `CrRendererMain` thread) and the window, pass two keeps only
//! that thread's events. Times inside are microseconds; the report is ms.
//! Event names below were read off this engine's own traces (CEF, 2026-11).

const std = @import("std");

/// A rewindable byte source; the summarizer reads it start to end twice.
pub const Source = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, buf: []u8) error{ReadFailed}!usize,
    rewindFn: *const fn (ctx: *anyopaque) error{ReadFailed}!void,
};

pub const SliceSource = struct {
    bytes: []const u8,
    pos: usize = 0,
    /// Bytes handed out per read, to exercise chunk boundaries in tests.
    step: usize = 64 * 1024,

    pub fn source(self: *SliceSource) Source {
        return .{ .ctx = self, .readFn = read, .rewindFn = rewind };
    }

    fn read(ctx: *anyopaque, buf: []u8) error{ReadFailed}!usize {
        const self: *SliceSource = @ptrCast(@alignCast(ctx));
        const n = @min(@min(buf.len, self.step), self.bytes.len - self.pos);
        @memcpy(buf[0..n], self.bytes[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    fn rewind(ctx: *anyopaque) error{ReadFailed}!void {
        const self: *SliceSource = @ptrCast(@alignCast(ctx));
        self.pos = 0;
    }
};

/// A task at least this long is a long task (the web's own threshold).
pub const LONG_TASK_US: f64 = 50_000;
/// One event larger than this is skipped (a selector-stats event of a huge sheet stays far below).
const EVENT_CAP: usize = 16 * 1024 * 1024;
/// Selector text kept per entry.
const SELECTOR_CAP: usize = 300;

/// What a main-thread event's time counts as; THE classification of event names.
pub const Kind = enum {
    task,
    script,
    style,
    layout,
    paint,
    gc,

    const table = [_]struct { name: []const u8, kind: Kind }{
        .{ .name = "RunTask", .kind = .task },
        .{ .name = "FunctionCall", .kind = .script },
        .{ .name = "TimerFire", .kind = .script },
        .{ .name = "EvaluateScript", .kind = .script },
        .{ .name = "RunMicrotasks", .kind = .script },
        .{ .name = "EventDispatch", .kind = .script },
        .{ .name = "FireAnimationFrame", .kind = .script },
        .{ .name = "FireIdleCallback", .kind = .script },
        .{ .name = "v8.compile", .kind = .script },
        .{ .name = "v8.evaluateModule", .kind = .script },
        .{ .name = "UpdateLayoutTree", .kind = .style },
        .{ .name = "Layout", .kind = .layout },
        .{ .name = "Paint", .kind = .paint },
        .{ .name = "PrePaint", .kind = .paint },
        .{ .name = "Layerize", .kind = .paint },
        .{ .name = "UpdateLayer", .kind = .paint },
        .{ .name = "Commit", .kind = .paint },
        .{ .name = "MinorGC", .kind = .gc },
        .{ .name = "MajorGC", .kind = .gc },
        .{ .name = "BlinkGC.AtomicPhase", .kind = .gc },
    };

    pub fn of(name: []const u8) ?Kind {
        for (table) |t| if (std.mem.eql(u8, t.name, name)) return t.kind;
        return null;
    }
};

/// A JS location; line and column are 1-based as the engine writes them in traces.
pub const Frame = struct {
    function: []const u8,
    url: []const u8,
    line: u32,
    column: u32,
};

pub const MainThread = struct {
    task_ms: f64 = 0,
    script_ms: f64 = 0,
    style_ms: f64 = 0,
    style_count: u64 = 0,
    layout_ms: f64 = 0,
    layout_count: u64 = 0,
    paint_ms: f64 = 0,
    gc_ms: f64 = 0,
};

/// What dominated a long task's own time.
pub const Cause = enum { script, style, layout, other };

pub const LongTask = struct {
    start_ms: f64,
    duration_ms: f64,
    cause: Cause,
    /// The heaviest JS entry inside the task, when the cause is script.
    frame: ?Frame,
};

pub const LongTasks = struct {
    count: u64 = 0,
    total_ms: f64 = 0,
    max_ms: f64 = 0,
    top: []LongTask = &.{},
};

/// Style or layout run synchronously inside JS, grouped by the frame that forced it.
pub const Reflow = struct {
    frame: Frame,
    count: u32 = 0,
    total_ms: f64 = 0,
    style_count: u32 = 0,
    layout_count: u32 = 0,
};

pub const Reflows = struct {
    count: u64 = 0,
    total_ms: f64 = 0,
    top: []Reflow = &.{},
};

pub const Selector = struct {
    selector: []const u8,
    /// The engine's style sheet id (`ua-style-sheet`, `style-sheet-<pid>-<n>`), not a url.
    style_sheet: []const u8,
    elapsed_ms: f64,
    match_attempts: u64,
    match_count: u64,
};

pub const Frames = struct {
    /// `DrawFrame`s of the tab's renderer compositor: frames drawn, which a static page does only on damage.
    count: u64,
    fps: f64,
};

pub const Timing = struct {
    name: []const u8,
    kind: enum { mark, measure },
    start_ms: f64,
    duration_ms: f64,
};

/// How the main thread was found.
pub const MainSource = enum {
    /// The renderer `TracingStartedInBrowser` (and any `FrameCommittedInBrowser`) named.
    tracing_started,
    /// No such event: every renderer's `CrRendererMain`.
    renderer_metadata,
    /// No renderer main thread at all; every section is empty.
    none,
};

pub const Summary = struct {
    window_ms: f64 = 0,
    events: u64 = 0,
    /// The file ended inside the event array (a cut or partial file).
    cut: bool = false,
    /// Events that could not be parsed or were over the size cap.
    skipped: u64 = 0,
    main_source: MainSource = .none,
    main_threads: u32 = 0,
    main_thread: MainThread = .{},
    long_tasks: LongTasks = .{},
    forced_reflows: Reflows = .{},
    selector_stats: []Selector = &.{},
    frames: ?Frames = null,
    user_timing: []Timing = &.{},
};

// ---------------------------------------------------------------------
// Event splitting
// ---------------------------------------------------------------------

/// Hands out each complete event object of the trace array, whatever the chunking.
const Splitter = struct {
    src: Source,
    buf: [64 * 1024]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,
    eof: bool = false,
    depth: u32 = 0,
    in_str: bool = false,
    esc: bool = false,
    /// The depth of the events array's elements; 0 until it opened.
    events_depth: u32 = 0,
    events_closed: bool = false,
    capturing: bool = false,
    oversized: bool = false,
    cur: std.ArrayList(u8) = .empty,
    key: [16]u8 = undefined,
    key_len: usize = 0,
    key_over: bool = false,
    last_key_is_events: bool = false,
    pending_events_key: bool = false,

    const Item = union(enum) { event: []const u8, oversized };

    fn next(self: *Splitter, gpa: std.mem.Allocator) !?Item {
        while (true) {
            if (self.pos == self.len) {
                if (self.eof) return null;
                self.len = try self.src.readFn(self.src.ctx, &self.buf);
                self.pos = 0;
                if (self.len == 0) {
                    self.eof = true;
                    return null;
                }
            }
            const ch = self.buf[self.pos];
            self.pos += 1;
            if (self.capturing and !self.oversized) {
                if (self.cur.items.len >= EVENT_CAP) self.oversized = true else try self.cur.append(gpa, ch);
            }
            if (self.in_str) {
                if (self.esc) {
                    self.esc = false;
                } else if (ch == '\\') {
                    self.esc = true;
                } else if (ch == '"') {
                    self.in_str = false;
                    if (self.depth == 1) self.pending_events_key = !self.key_over and std.mem.eql(u8, self.key[0..self.key_len], "traceEvents");
                } else if (self.depth == 1) {
                    if (self.key_len < self.key.len) {
                        self.key[self.key_len] = ch;
                        self.key_len += 1;
                    } else self.key_over = true;
                }
                continue;
            }
            switch (ch) {
                '"' => {
                    self.in_str = true;
                    self.key_len = 0;
                    self.key_over = false;
                },
                ':' => if (self.depth == 1) {
                    self.last_key_is_events = self.pending_events_key;
                },
                '[' => {
                    if (self.events_depth == 0 and (self.depth == 0 or (self.depth == 1 and self.last_key_is_events))) self.events_depth = self.depth + 1;
                    self.depth += 1;
                },
                '{' => {
                    if (self.events_depth != 0 and !self.events_closed and self.depth == self.events_depth and !self.capturing) {
                        self.capturing = true;
                        self.oversized = false;
                        self.cur.clearRetainingCapacity();
                        try self.cur.append(gpa, '{');
                    }
                    self.depth += 1;
                },
                '}', ']' => {
                    if (self.depth > 0) self.depth -= 1;
                    if (ch == ']' and self.events_depth != 0 and self.depth + 1 == self.events_depth) self.events_closed = true;
                    if (ch == '}' and self.capturing and self.depth == self.events_depth) {
                        self.capturing = false;
                        if (self.oversized) return .oversized;
                        return .{ .event = self.cur.items };
                    }
                },
                else => {},
            }
        }
    }

    /// The array never closed: the file was cut (or is not a trace).
    fn cut(self: *const Splitter) bool {
        return !self.events_closed;
    }
};

const Raw = struct {
    name: []const u8 = "",
    cat: []const u8 = "",
    ph: []const u8 = "",
    ts: f64 = 0,
    dur: f64 = 0,
    pid: i64 = 0,
    tid: i64 = 0,
    id: ?std.json.Value = null,
    id2: ?std.json.Value = null,
    args: ?std.json.Value = null,
};

fn get(v: ?std.json.Value, key: []const u8) ?std.json.Value {
    const o = v orelse return null;
    if (o != .object) return null;
    return o.object.get(key);
}

fn str(v: ?std.json.Value) []const u8 {
    const s = v orelse return "";
    return if (s == .string) s.string else "";
}

fn int(v: ?std.json.Value) i64 {
    const n = v orelse return 0;
    return switch (n) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn flag(v: ?std.json.Value) ?bool {
    const b = v orelse return null;
    return if (b == .bool) b.bool else null;
}

fn ms(us: f64) f64 {
    return @round(us / 10) / 100;
}

/// Run `each` over every parsed event; the per-event memory is reused.
fn forEach(gpa: std.mem.Allocator, src: Source, ctx: anytype, comptime each: anytype, sum: *Summary, count: bool) !bool {
    try src.rewindFn(src.ctx);
    var sp: Splitter = .{ .src = src };
    defer sp.cur.deinit(gpa);
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    while (try sp.next(gpa)) |item| {
        if (count) sum.events += 1;
        const bytes = switch (item) {
            .oversized => {
                if (count) sum.skipped += 1;
                continue;
            },
            .event => |b| b,
        };
        _ = scratch.reset(.retain_capacity);
        const raw = std.json.parseFromSliceLeaky(Raw, scratch.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch {
            if (count) sum.skipped += 1;
            continue;
        };
        try each(ctx, raw);
    }
    return sp.cut();
}

// ---------------------------------------------------------------------
// Pass one: the main thread and the window
// ---------------------------------------------------------------------

const Thread = struct { pid: i64, tid: i64 };

const Scan = struct {
    arena: std.mem.Allocator,
    renderer_mains: std.ArrayList(Thread) = .empty,
    main_pids: std.ArrayList(i64) = .empty,
    main_frame: []const u8 = "",
    started: bool = false,
    t0: f64 = std.math.inf(f64),
    t1: f64 = -std.math.inf(f64),
    started_ts: ?f64 = null,

    fn addPid(self: *Scan, pid: i64) !void {
        if (pid == 0) return;
        for (self.main_pids.items) |p| if (p == pid) return;
        try self.main_pids.append(self.arena, pid);
    }

    fn each(self: *Scan, e: Raw) !void {
        if (std.mem.eql(u8, e.ph, "M")) {
            if (std.mem.eql(u8, e.name, "thread_name") and std.mem.eql(u8, str(get(e.args, "name")), "CrRendererMain"))
                try self.renderer_mains.append(self.arena, .{ .pid = e.pid, .tid = e.tid });
            return;
        }
        self.t0 = @min(self.t0, e.ts);
        self.t1 = @max(self.t1, e.ts + e.dur);
        if (std.mem.eql(u8, e.name, "TracingStartedInBrowser")) {
            self.started = true;
            self.started_ts = e.ts;
            const frames = get(get(e.args, "data"), "frames") orelse return;
            if (frames != .array) return;
            for (frames.array.items) |f| {
                // The tab's own document: the outermost main frame (the first one when the flag is absent).
                const outer = flag(get(f, "isOutermostMainFrame")) orelse (self.main_frame.len == 0);
                if (!outer) continue;
                if (self.main_frame.len == 0) self.main_frame = try self.arena.dupe(u8, str(get(f, "frame")));
                try self.addPid(int(get(f, "processId")));
            }
        } else if (std.mem.eql(u8, e.name, "FrameCommittedInBrowser")) {
            // A cross-process navigation moves the tab's document to another renderer.
            const d = get(e.args, "data");
            const outer = flag(get(d, "isOutermostMainFrame")) orelse true;
            if (!outer) return;
            const frame = str(get(d, "frame"));
            if (self.main_frame.len != 0 and frame.len != 0 and !std.mem.eql(u8, frame, self.main_frame)) return;
            try self.addPid(int(get(d, "processId")));
        }
    }
};

// ---------------------------------------------------------------------
// Pass two: the main thread's events
// ---------------------------------------------------------------------

const Ev = struct {
    ts: f64,
    end: f64,
    kind: Kind,
    /// script: the JS entry it runs; style/layout: the top of the stack that forced it.
    frame: ?u32,
    self: f64 = 0,
};

const SelectorAcc = struct { selector: []const u8, sheet: []const u8, elapsed_us: f64 = 0, attempts: u64 = 0, matches: u64 = 0 };
const Open = struct { name: []const u8, id: []const u8, ts: f64 };

const Collect = struct {
    arena: std.mem.Allocator,
    threads: []const Thread,
    pids: []const i64,
    evs: std.ArrayList(Ev) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    selectors: std.StringHashMapUnmanaged(SelectorAcc) = .empty,
    timings: std.ArrayList(Timing) = .empty,
    open: std.ArrayList(Open) = .empty,
    draws: u64 = 0,
    frame_events: bool = false,
    t0: f64,

    fn onMain(self: *const Collect, e: Raw) bool {
        for (self.threads) |t| if (t.pid == e.pid and t.tid == e.tid) return true;
        return false;
    }

    fn inPids(self: *const Collect, pid: i64) bool {
        for (self.pids) |p| if (p == pid) return true;
        return false;
    }

    fn frameOf(self: *Collect, v: ?std.json.Value, fn_key: []const u8) !?u32 {
        const function = str(get(v, fn_key));
        const url = str(get(v, "url"));
        if (function.len == 0 and url.len == 0) return null;
        try self.frames.append(self.arena, .{
            .function = try self.arena.dupe(u8, function),
            .url = try self.arena.dupe(u8, url),
            .line = @intCast(std.math.clamp(int(get(v, "lineNumber")), 0, std.math.maxInt(u32))),
            .column = @intCast(std.math.clamp(int(get(v, "columnNumber")), 0, std.math.maxInt(u32))),
        });
        return @intCast(self.frames.items.len - 1);
    }

    fn each(self: *Collect, e: Raw) !void {
        // Frames are drawn by the renderer's compositor thread, not its main thread.
        if (self.inPids(e.pid) and std.mem.indexOf(u8, e.cat, "devtools.timeline.frame") != null) {
            self.frame_events = true;
            if (std.mem.eql(u8, e.name, "DrawFrame")) self.draws += 1;
        }
        if (!self.onMain(e)) return;
        if (std.mem.eql(u8, e.cat, "blink.user_timing")) return self.timing(e);
        if (!std.mem.eql(u8, e.ph, "X")) return;
        if (std.mem.eql(u8, e.name, "SelectorStats")) return self.selectorStats(e);
        const kind = Kind.of(e.name) orelse return;
        const frame: ?u32 = switch (kind) {
            .script => try self.frameOf(get(e.args, "data"), "functionName"),
            .style, .layout => blk: {
                const st = get(get(e.args, "beginData"), "stackTrace") orelse break :blk null;
                if (st != .array or st.array.items.len == 0) break :blk null;
                break :blk try self.frameOf(st.array.items[0], "functionName");
            },
            else => null,
        };
        try self.evs.append(self.arena, .{ .ts = e.ts, .end = e.ts + @max(e.dur, 0), .kind = kind, .frame = frame });
    }

    fn timing(self: *Collect, e: Raw) !void {
        const id = blk: {
            const v = e.id2 orelse e.id orelse break :blk "";
            break :blk switch (v) {
                .string => |s| s,
                .object => str(v.object.get("local") orelse v.object.get("global")),
                .integer => |i| try std.fmt.allocPrint(self.arena, "{d}", .{i}),
                else => "",
            };
        };
        // `performance.mark` is an instant; the `R` instants in this category are the engine's navigation marks.
        if (std.mem.eql(u8, e.ph, "I") or std.mem.eql(u8, e.ph, "i")) {
            try self.timings.append(self.arena, .{ .name = try self.arena.dupe(u8, e.name), .kind = .mark, .start_ms = ms(e.ts - self.t0), .duration_ms = 0 });
        } else if (std.mem.eql(u8, e.ph, "b")) {
            try self.open.append(self.arena, .{ .name = try self.arena.dupe(u8, e.name), .id = try self.arena.dupe(u8, id), .ts = e.ts });
        } else if (std.mem.eql(u8, e.ph, "e")) {
            for (self.open.items, 0..) |o, i| if (std.mem.eql(u8, o.name, e.name) and std.mem.eql(u8, o.id, id)) {
                try self.timings.append(self.arena, .{ .name = o.name, .kind = .measure, .start_ms = ms(o.ts - self.t0), .duration_ms = ms(e.ts - o.ts) });
                _ = self.open.swapRemove(i);
                return;
            };
        }
    }

    fn selectorStats(self: *Collect, e: Raw) !void {
        const list = get(get(e.args, "selector_stats"), "selector_timings") orelse return;
        if (list != .array) return;
        for (list.array.items) |t| {
            const sel = str(get(t, "selector"));
            if (sel.len == 0) continue;
            const sheet = str(get(t, "style_sheet_id"));
            const key = try std.fmt.allocPrint(self.arena, "{s}\x00{s}", .{ sel, sheet });
            const gop = try self.selectors.getOrPut(self.arena, key);
            if (!gop.found_existing) gop.value_ptr.* = .{
                .selector = key[0..@min(sel.len, SELECTOR_CAP)],
                .sheet = key[sel.len + 1 ..],
            } else self.arena.free(key);
            const elapsed = get(t, "elapsed (us)") orelse null;
            gop.value_ptr.elapsed_us += if (elapsed) |v| switch (v) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => 0,
            } else 0;
            gop.value_ptr.attempts += @intCast(@max(int(get(t, "match_attempts")), 0));
            gop.value_ptr.matches += @intCast(@max(int(get(t, "match_count")), 0));
        }
    }
};

const KIND_N = std.enums.values(Kind).len;
const Root = struct { ev: u32, by_kind: [KIND_N]f64 = @splat(0), best: ?u32 = null, best_dur: f64 = 0 };

fn lessByStart(_: void, a: Ev, b: Ev) bool {
    if (a.ts != b.ts) return a.ts < b.ts;
    return a.end > b.end;
}

/// Summarize the trace `src` holds; `top` bounds every list.
pub fn summarize(arena: std.mem.Allocator, src: Source, top: usize) !Summary {
    var sum: Summary = .{};
    var scan: Scan = .{ .arena = arena };
    sum.cut = try forEach(arena, src, &scan, Scan.each, &sum, true);
    if (sum.events == 0 or scan.t1 < scan.t0) return sum;
    const t0 = scan.started_ts orelse scan.t0;
    sum.window_ms = ms(scan.t1 - t0);

    var threads: std.ArrayList(Thread) = .empty;
    var pids: std.ArrayList(i64) = .empty;
    if (scan.main_pids.items.len != 0) {
        sum.main_source = .tracing_started;
        for (scan.main_pids.items) |pid| {
            var named = false;
            for (scan.renderer_mains.items) |t| if (t.pid == pid) {
                try threads.append(arena, t);
                named = true;
            };
            // Metadata comes last and a cut file may lack it; the renderer's main thread id is its pid.
            if (!named) try threads.append(arena, .{ .pid = pid, .tid = pid });
            try pids.append(arena, pid);
        }
    } else if (scan.renderer_mains.items.len != 0) {
        sum.main_source = .renderer_metadata;
        for (scan.renderer_mains.items) |t| {
            try threads.append(arena, t);
            try pids.append(arena, t.pid);
        }
    } else return sum;
    sum.main_threads = @intCast(threads.items.len);

    var col: Collect = .{ .arena = arena, .threads = threads.items, .pids = pids.items, .t0 = t0 };
    _ = try forEach(arena, src, &col, Collect.each, &sum, false);

    const evs = col.evs.items;
    std.mem.sort(Ev, evs, {}, lessByStart);
    var roots: std.ArrayList(Root) = .empty;
    var reflows: std.ArrayList(Reflow) = .empty;
    // Parallel to the stack: the root record index, and the nearest enclosing script frame (or none).
    const Slot = struct { ev: u32, root: ?u32, in_script: bool, script_frame: ?u32 };
    var stack: std.ArrayList(Slot) = .empty;
    var by_kind: [KIND_N]f64 = @splat(0);

    for (evs, 0..) |*e, i| {
        while (stack.items.len != 0 and evs[stack.items[stack.items.len - 1].ev].end <= e.ts)
            finalize(evs, stack.pop().?, &by_kind, roots.items);
        e.self = e.end - e.ts;
        var slot: Slot = .{ .ev = @intCast(i), .root = null, .in_script = false, .script_frame = null };
        if (stack.items.len != 0) {
            const parent = stack.items[stack.items.len - 1];
            const p = &evs[parent.ev];
            p.self -= @max(@min(e.end, p.end) - e.ts, 0);
            slot.root = parent.root;
            slot.in_script = parent.in_script or p.kind == .script;
            slot.script_frame = if (p.kind == .script and p.frame != null) p.frame else parent.script_frame;
        } else if (e.kind == .task) {
            sum.main_thread.task_ms += e.end - e.ts;
            if (e.end - e.ts >= LONG_TASK_US) {
                try roots.append(arena, .{ .ev = @intCast(i) });
                slot.root = @intCast(roots.items.len - 1);
            }
        }
        if (slot.in_script and (e.kind == .style or e.kind == .layout)) {
            // The engine records the forcing stack; without one, the enclosing JS entry is the best name.
            e.frame = e.frame orelse slot.script_frame;
            const f: Frame = if (e.frame) |fi| col.frames.items[fi] else .{ .function = "(unknown)", .url = "", .line = 0, .column = 0 };
            sum.forced_reflows.count += 1;
            sum.forced_reflows.total_ms += e.end - e.ts;
            const r = for (reflows.items) |*r| {
                if (sameFrame(r.frame, f)) break r;
            } else blk: {
                try reflows.append(arena, .{ .frame = f });
                break :blk &reflows.items[reflows.items.len - 1];
            };
            r.count += 1;
            r.total_ms += e.end - e.ts;
            if (e.kind == .style) r.style_count += 1 else r.layout_count += 1;
        }
        if (e.kind == .style) sum.main_thread.style_count += 1;
        if (e.kind == .layout) sum.main_thread.layout_count += 1;
        try stack.append(arena, slot);
    }
    while (stack.pop()) |s| finalize(evs, s, &by_kind, roots.items);

    const mt = &sum.main_thread;
    mt.task_ms = ms(mt.task_ms);
    mt.script_ms = ms(by_kind[@intFromEnum(Kind.script)]);
    mt.style_ms = ms(by_kind[@intFromEnum(Kind.style)]);
    mt.layout_ms = ms(by_kind[@intFromEnum(Kind.layout)]);
    mt.paint_ms = ms(by_kind[@intFromEnum(Kind.paint)]);
    mt.gc_ms = ms(by_kind[@intFromEnum(Kind.gc)]);

    // Long tasks, longest first.
    var lts: std.ArrayList(LongTask) = .empty;
    for (roots.items) |r| {
        const e = evs[r.ev];
        const d = e.end - e.ts;
        sum.long_tasks.count += 1;
        sum.long_tasks.total_ms += d;
        sum.long_tasks.max_ms = @max(sum.long_tasks.max_ms, d);
        const cause = dominant(r.by_kind);
        try lts.append(arena, .{
            .start_ms = ms(e.ts - t0),
            .duration_ms = ms(d),
            .cause = cause,
            .frame = if (cause == .script) if (r.best) |b| col.frames.items[b] else null else null,
        });
    }
    std.mem.sort(LongTask, lts.items, {}, struct {
        fn f(_: void, a: LongTask, b: LongTask) bool {
            return a.duration_ms > b.duration_ms;
        }
    }.f);
    sum.long_tasks.total_ms = ms(sum.long_tasks.total_ms);
    sum.long_tasks.max_ms = ms(sum.long_tasks.max_ms);
    sum.long_tasks.top = lts.items[0..@min(lts.items.len, top)];

    std.mem.sort(Reflow, reflows.items, {}, struct {
        fn f(_: void, a: Reflow, b: Reflow) bool {
            return a.total_ms > b.total_ms;
        }
    }.f);
    for (reflows.items) |*r| r.total_ms = ms(r.total_ms);
    sum.forced_reflows.total_ms = ms(sum.forced_reflows.total_ms);
    sum.forced_reflows.top = reflows.items[0..@min(reflows.items.len, top)];

    var sels: std.ArrayList(Selector) = .empty;
    var it = col.selectors.valueIterator();
    while (it.next()) |a| try sels.append(arena, .{ .selector = a.selector, .style_sheet = a.sheet, .elapsed_ms = ms(a.elapsed_us), .match_attempts = a.attempts, .match_count = a.matches });
    std.mem.sort(Selector, sels.items, {}, struct {
        fn f(_: void, a: Selector, b: Selector) bool {
            if (a.elapsed_ms != b.elapsed_ms) return a.elapsed_ms > b.elapsed_ms;
            return a.match_attempts > b.match_attempts;
        }
    }.f);
    sum.selector_stats = sels.items[0..@min(sels.items.len, top)];

    if (col.frame_events) sum.frames = .{
        .count = col.draws,
        .fps = if (sum.window_ms > 0) @round(@as(f64, @floatFromInt(col.draws)) * 1000 / sum.window_ms * 10) / 10 else 0,
    };

    std.mem.sort(Timing, col.timings.items, {}, struct {
        fn f(_: void, a: Timing, b: Timing) bool {
            if (a.start_ms != b.start_ms) return a.start_ms < b.start_ms;
            return a.kind == .mark and b.kind == .measure;
        }
    }.f);
    sum.user_timing = col.timings.items[0..@min(col.timings.items.len, top)];
    return sum;
}

fn sameFrame(a: Frame, b: Frame) bool {
    return a.line == b.line and a.column == b.column and std.mem.eql(u8, a.function, b.function) and std.mem.eql(u8, a.url, b.url);
}

/// An event's own time is final once it leaves the stack.
fn finalize(evs: []Ev, s: anytype, by_kind: *[KIND_N]f64, roots: []Root) void {
    const e = evs[s.ev];
    const k = @intFromEnum(e.kind);
    by_kind[k] += @max(e.self, 0);
    const ri = s.root orelse return;
    const r = &roots[ri];
    r.by_kind[k] += @max(e.self, 0);
    if (e.kind == .script and e.frame != null and e.end - e.ts > r.best_dur) {
        r.best = e.frame;
        r.best_dur = e.end - e.ts;
    }
}

fn dominant(by_kind: [KIND_N]f64) Cause {
    const script = by_kind[@intFromEnum(Kind.script)];
    const style = by_kind[@intFromEnum(Kind.style)];
    const layout = by_kind[@intFromEnum(Kind.layout)];
    const other = by_kind[@intFromEnum(Kind.task)] + by_kind[@intFromEnum(Kind.paint)] + by_kind[@intFromEnum(Kind.gc)];
    const best = @max(@max(script, style), @max(layout, other));
    if (best == script and script > 0) return .script;
    if (best == style and style > 0) return .style;
    if (best == layout and layout > 0) return .layout;
    return .other;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

/// A small trace in this engine's shapes: two renderers (only pid 10 is the tab's), a 120ms
/// task running `slow`, a 4ms task where `thrash` forces style + layout twice, a
/// selector-stats event, a mark and a measure, two drawn frames, metadata at the end.
const fixture =
    \\{"traceEvents":[
    \\{"name":"TracingStartedInBrowser","ph":"I","pid":1,"tid":1,"ts":1000,"cat":"disabled-by-default-devtools.timeline","args":{"data":{"frames":[{"frame":"F1","isOutermostMainFrame":true,"processId":10,"url":"http://x/"}]}}},
    \\{"name":"RunTask","ph":"X","pid":10,"tid":10,"ts":2000,"dur":120000,"cat":"disabled-by-default-devtools.timeline","args":{}},
    \\{"name":"TimerFire","ph":"X","pid":10,"tid":10,"ts":2010,"dur":119900,"cat":"devtools.timeline","args":{"data":{"frame":"F1","timerId":2}}},
    \\{"name":"FunctionCall","ph":"X","pid":10,"tid":10,"ts":2020,"dur":119800,"cat":"devtools.timeline","args":{"data":{"functionName":"slow","url":"http://x/a.js","lineNumber":2,"columnNumber":14}}},
    \\{"name":"MinorGC","ph":"X","pid":10,"tid":10,"ts":50000,"dur":800,"cat":"devtools.timeline,v8","args":{}},
    \\{"name":"RunTask","ph":"X","pid":10,"tid":10,"ts":130000,"dur":4000,"cat":"disabled-by-default-devtools.timeline","args":{}},
    \\{"name":"FunctionCall","ph":"X","pid":10,"tid":10,"ts":130010,"dur":3900,"cat":"devtools.timeline","args":{"data":{"functionName":"thrash","url":"http://x/a.js","lineNumber":1,"columnNumber":16}}},
    \\{"name":"UpdateLayoutTree","ph":"X","pid":10,"tid":10,"ts":130100,"dur":300,"cat":"blink,devtools.timeline","args":{"beginData":{"stackTrace":[{"functionName":"thrash","url":"http://x/a.js","lineNumber":1,"columnNumber":118}]},"elementCount":1}},
    \\{"name":"SelectorStats","ph":"X","pid":10,"tid":10,"ts":130110,"dur":5,"cat":"disabled-by-default-blink.debug","args":{"selector_stats":{"selector_timings":[{"elapsed (us)":250,"match_attempts":1000,"match_count":0,"selector":".card:has(> .needle)","style_sheet_id":"style-sheet-10-1"},{"elapsed (us)":3,"match_attempts":2,"match_count":2,"selector":"div","style_sheet_id":"ua-style-sheet"}]}}},
    \\{"name":"Layout","ph":"X","pid":10,"tid":10,"ts":130500,"dur":200,"cat":"devtools.timeline","args":{"beginData":{"stackTrace":[{"functionName":"thrash","url":"http://x/a.js","lineNumber":1,"columnNumber":118}]}}},
    \\{"name":"UpdateLayoutTree","ph":"X","pid":10,"tid":10,"ts":131000,"dur":100,"cat":"blink,devtools.timeline","args":{"beginData":{"stackTrace":[{"functionName":"thrash","url":"http://x/a.js","lineNumber":1,"columnNumber":118}]}}},
    \\{"name":"Layout","ph":"X","pid":10,"tid":10,"ts":131200,"dur":100,"cat":"devtools.timeline","args":{"beginData":{"stackTrace":[{"functionName":"thrash","url":"http://x/a.js","lineNumber":1,"columnNumber":118}]}}},
    \\{"name":"RunTask","ph":"X","pid":10,"tid":10,"ts":140000,"dur":1000,"cat":"disabled-by-default-devtools.timeline","args":{}},
    \\{"name":"UpdateLayoutTree","ph":"X","pid":10,"tid":10,"ts":140100,"dur":500,"cat":"blink,devtools.timeline","args":{"elementCount":3}},
    \\{"name":"Paint","ph":"X","pid":10,"tid":10,"ts":140700,"dur":200,"cat":"devtools.timeline","args":{}},
    \\{"name":"act-start","ph":"I","pid":10,"tid":10,"ts":1500,"cat":"blink.user_timing","args":{"data":{"startTime":1}}},
    \\{"name":"commitNavigationEnd","ph":"R","pid":10,"tid":10,"ts":1600,"cat":"blink.user_timing","args":{}},
    \\{"name":"act","ph":"b","id2":{"local":"0x1"},"pid":10,"tid":10,"ts":1500,"cat":"blink.user_timing","args":{}},
    \\{"name":"act","ph":"e","id2":{"local":"0x1"},"pid":10,"tid":10,"ts":135500,"cat":"blink.user_timing","args":{}},
    \\{"name":"DrawFrame","ph":"I","pid":10,"tid":11,"ts":125000,"cat":"disabled-by-default-devtools.timeline.frame","args":{}},
    \\{"name":"DrawFrame","ph":"I","pid":10,"tid":11,"ts":141000,"cat":"disabled-by-default-devtools.timeline.frame","args":{}},
    \\{"name":"DrawFrame","ph":"I","pid":20,"tid":21,"ts":141000,"cat":"disabled-by-default-devtools.timeline.frame","args":{}},
    \\{"name":"RunTask","ph":"X","pid":20,"tid":20,"ts":3000,"dur":90000,"cat":"disabled-by-default-devtools.timeline","args":{}},
    \\{"name":"FunctionCall","ph":"X","pid":20,"tid":20,"ts":3010,"dur":89000,"cat":"devtools.timeline","args":{"data":{"functionName":"other","url":"http://y/b.js","lineNumber":1,"columnNumber":1}}},
    \\{"name":"thread_name","ph":"M","pid":10,"tid":10,"ts":0,"cat":"__metadata","args":{"name":"CrRendererMain"}},
    \\{"name":"thread_name","ph":"M","pid":20,"tid":20,"ts":0,"cat":"__metadata","args":{"name":"CrRendererMain"}},
    \\{"name":"process_name","ph":"M","pid":10,"tid":0,"ts":0,"cat":"__metadata","args":{"name":"Renderer"}}
    \\]}
;

test "a trace summary keeps to the tab's main thread and fills every section" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: SliceSource = .{ .bytes = fixture, .step = 7 };
    const s = try summarize(arena, src.source(), 10);
    try std.testing.expect(!s.cut);
    try std.testing.expectEqual(MainSource.tracing_started, s.main_source);
    try std.testing.expectEqual(@as(u32, 1), s.main_threads);
    try std.testing.expectEqual(@as(u64, 27), s.events);
    try std.testing.expectEqual(@as(f64, 140), s.window_ms);
    // The other renderer's 90ms task is not here: one long task, `slow`.
    try std.testing.expectEqual(@as(u64, 1), s.long_tasks.count);
    try std.testing.expectEqual(@as(f64, 120), s.long_tasks.max_ms);
    const lt = s.long_tasks.top[0];
    try std.testing.expectEqual(Cause.script, lt.cause);
    try std.testing.expectEqualStrings("slow", lt.frame.?.function);
    try std.testing.expectEqual(@as(f64, 1), lt.start_ms);
    // Self times: GC inside slow is not script; forced style inside thrash is style.
    try std.testing.expectEqual(@as(f64, 125), s.main_thread.task_ms);
    try std.testing.expectEqual(@as(f64, 0.8), s.main_thread.gc_ms);
    try std.testing.expectEqual(@as(f64, 0.9), s.main_thread.style_ms);
    try std.testing.expectEqual(@as(u64, 3), s.main_thread.style_count);
    try std.testing.expectEqual(@as(f64, 0.3), s.main_thread.layout_ms);
    try std.testing.expectEqual(@as(f64, 0.2), s.main_thread.paint_ms);
    try std.testing.expectEqual(@as(f64, 122.3), s.main_thread.script_ms);
    // Forced: the four inside thrash, not the style in the plain task.
    try std.testing.expectEqual(@as(u64, 4), s.forced_reflows.count);
    try std.testing.expectEqual(@as(usize, 1), s.forced_reflows.top.len);
    const r = s.forced_reflows.top[0];
    try std.testing.expectEqualStrings("thrash", r.frame.function);
    try std.testing.expectEqual(@as(u32, 118), r.frame.column);
    try std.testing.expectEqual(@as(u32, 4), r.count);
    try std.testing.expectEqual(@as(u32, 2), r.style_count);
    try std.testing.expectEqual(@as(f64, 0.7), r.total_ms);
    try std.testing.expectEqualStrings(".card:has(> .needle)", s.selector_stats[0].selector);
    try std.testing.expectEqualStrings("style-sheet-10-1", s.selector_stats[0].style_sheet);
    try std.testing.expectEqual(@as(u64, 1000), s.selector_stats[0].match_attempts);
    try std.testing.expectEqual(@as(u64, 2), s.frames.?.count);
    try std.testing.expectEqual(@as(usize, 2), s.user_timing.len);
    try std.testing.expectEqualStrings("act-start", s.user_timing[0].name);
    try std.testing.expectEqual(@as(f64, 134), s.user_timing[1].duration_ms);
}

test "a cut trace is summarized up to the cut and says so" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Cut inside the thrash FunctionCall: no metadata, so the main thread comes from the pid.
    const at = std.mem.indexOf(u8, fixture, "\"thrash\",\"url\"").?;
    var src: SliceSource = .{ .bytes = fixture[0..at] };
    const s = try summarize(arena, src.source(), 10);
    try std.testing.expect(s.cut);
    try std.testing.expectEqual(MainSource.tracing_started, s.main_source);
    try std.testing.expectEqual(@as(u64, 1), s.long_tasks.count);
    try std.testing.expectEqual(@as(u64, 0), s.forced_reflows.count);
    try std.testing.expect(s.frames == null);
}

test "without TracingStartedInBrowser every renderer main thread counts; a bare array parses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bare =
        \\[{"name":"RunTask","ph":"X","pid":7,"tid":7,"ts":0,"dur":60000,"args":{}},
        \\{"name":"Layout","ph":"X","pid":7,"tid":7,"ts":10,"dur":59000,"args":{}},
        \\{"name":"weird","ph":"X","pid":"not a number","tid":7,"ts":0},
        \\{"name":"thread_name","ph":"M","pid":7,"tid":7,"args":{"name":"CrRendererMain"}}]
    ;
    var src: SliceSource = .{ .bytes = bare, .step = 3 };
    const s = try summarize(arena, src.source(), 10);
    try std.testing.expect(!s.cut);
    try std.testing.expectEqual(MainSource.renderer_metadata, s.main_source);
    try std.testing.expectEqual(@as(u64, 1), s.skipped);
    try std.testing.expectEqual(Cause.layout, s.long_tasks.top[0].cause);
    try std.testing.expect(s.long_tasks.top[0].frame == null);
    try std.testing.expectEqual(@as(u64, 0), s.forced_reflows.count);
    // Every section exists even when empty.
    try std.testing.expectEqual(@as(usize, 0), s.selector_stats.len);
    try std.testing.expectEqual(@as(usize, 0), s.user_timing.len);

    var none: SliceSource = .{ .bytes = "{\"traceEvents\":[]}" };
    const e = try summarize(arena, none.source(), 10);
    try std.testing.expectEqual(MainSource.none, e.main_source);
    try std.testing.expect(!e.cut);
}
