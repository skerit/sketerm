//! MCP forwarded-app tools — appTool dispatch, the app_actions step
//! engine (runActionSteps), and appToolTail — split out of mcp.zig.
//! Shared server state stays in mcp.zig and is referenced through it.

const std = @import("std");
const c = @import("../c.zig").c;
const atomicwrite = @import("../util/atomicwrite.zig");
const appdrive = @import("appdrive.zig");
const ocr = @import("../util/ocr.zig");
const mcp = @import("mcp.zig");
const eql = std.mem.eql;
const mcp_tools = @import("mcp_tools.zig");
const clock = @import("../util/clock.zig");
const template = @import("../util/template.zig");
const pattern = @import("../util/pattern.zig");
const mcp_testkit = @import("mcp_testkit.zig");
const wire = @import("../mux/wire.zig");
const expectToolResultShape = mcp.expectToolResultShape;
const parseTestValue = mcp_testkit.parseTestValue;
const run = mcp.run;
const tailLines = mcp.tailLines;
const Res = mcp.Res;
const errRes = mcp.errRes;
const wallMs = @import("../util/clock.zig").wallMs;
const CATCHUP_MS = mcp.CATCHUP_MS;
const png_util = mcp.png_util;
const Watchdog = mcp.Watchdog;
const mcpassets = mcp.mcpassets;
const Tuning = mcp.Tuning;
const argBool = mcp.argBool;
const nowMs = @import("../util/clock.zig").nowMs;
const argStr = mcp.argStr;
const marks_mod = mcp.marks_mod;
const appErr = mcp.appErr;
const argFloat = mcp.argFloat;
const argInt = mcp.argInt;

/// The caller named this path, so an existing file keeps its own mode.
fn saveRecording(path: []const u8, bytes: []const u8) atomicwrite.Error!void {
    try atomicwrite.writeFile(path, bytes, 0o600);
}

/// An OCR failure, typed: a missing engine is a subsystem that is not
/// there, an unrendered window is a target that is not there yet.
fn ocrErr(arena: std.mem.Allocator, msg: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, msg, "no rendered")) return errRes(arena, .not_found, msg);
    return errRes(arena, .unavailable, msg);
}

/// What one waiting step of an `app_actions` batch may spend, and whether
/// the budget shortened the request.
const StepWait = struct {
    ms: i64,
    /// The wait was cut short, so its timeout is a budget fact and must
    /// never be reported as an observation about the app.
    clipped: bool,
    requested: i64,
};

/// What one waiting step of an `app_actions` batch may still spend: its
/// own request, clamped to the per-wait cap AND to what is left of the
/// batch's SINGLE budget. Per-step clamping alone is not enough: N
/// steps each just under `WAIT_CAP_MS` sail past the 150s central
/// watchdog, which then shuts the connection down instead of letting
/// the call answer. Yields 0ms once the budget is spent.
fn stepBudget(requested: i64, batch_deadline: i64) StepWait {
    const left = batch_deadline - nowMs();
    if (left <= 0) return .{ .ms = 0, .clipped = requested > 0, .requested = requested };
    const ms = std.math.clamp(requested, 0, @min(left, mcp.WAIT_CAP_MS));
    return .{ .ms = ms, .clipped = ms < requested, .requested = requested };
}

/// How long a screenshot_app burst may keep capturing, clamped like every
/// other app-side wait: past `WAIT_CAP_MS` the 150s central watchdog would
/// shut the connection down instead of the call answering.
fn burstMs(requested: ?i64) i64 {
    return std.math.clamp(requested orelse 5_000, 0, mcp.WAIT_CAP_MS);
}

/// The clause a clipped wait appends to its transcript line, so a timeout
/// at a shortened deadline cannot read as an app verdict.
fn clipNote(arena: std.mem.Allocator, b: StepWait) ![]const u8 {
    if (!b.clipped) return "";
    return std.fmt.allocPrint(
        arena,
        " [wait clipped to {d}ms of the {d}ms asked, by the batch budget; not an app verdict]",
        .{ b.ms, b.requested },
    );
}

/// Copy one OCR pass out of a poll's scratch arena into `arena`.
///
/// Only the pass that MATCHED is worth keeping; every other pass dies
/// with the next scratch reset, which is what stops a polling wait from
/// growing by one pass's arena charge per iteration for the whole tool
/// call (`ocrWindow` frees the RGBA capture itself, but its recognized
/// text and word boxes and, for small fonts, the upscaled copy of the
/// capture are the caller's arena).
fn dupeOcrOut(arena: std.mem.Allocator, o: OcrOut) !OcrOut {
    const words = try arena.alloc(ocr.Word, o.words.len);
    for (o.words, words) |src, *dst| {
        dst.* = src;
        dst.text = try arena.dupe(u8, src.text);
    }
    return .{ .text = try arena.dupe(u8, o.text), .words = words, .scale = o.scale };
}

/// The word boxes of an OCR pass, as verbatim JSON (each with the
/// centre a click wants).
fn wordBoxesJson(arena: std.mem.Allocator, o: OcrOut) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("[");
    for (o.words, 0..) |wd, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"text\":{f},\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"cx\":{d},\"cy\":{d},\"conf\":{d:.0}}}", .{
            std.json.fmt(wd.text, .{}), wd.x,            wd.y,    wd.w, wd.h,
            wd.x + wd.w / 2,            wd.y + wd.h / 2, wd.conf,
        });
    }
    try w.writeAll("]");
    return aw.written();
}

/// One a11y node as a text line: the id a caller acts on, its role and
/// name. The full node (every attribute) rides structuredContent.
fn a11yNodeLine(arena: std.mem.Allocator, node: std.json.Value) ![]const u8 {
    if (node != .object) return "(malformed node)";
    const id = if (node.object.get("id")) |v| (if (v == .string) v.string else "") else "";
    const role: i64 = if (node.object.get("role")) |v| (if (v == .integer) v.integer else -1) else -1;
    const nm = if (node.object.get("name")) |v| (if (v == .string) v.string else "") else "";
    return std.fmt.allocPrint(arena, "{s} role {d}{s}{s}", .{
        id, role, if (nm.len > 0) " " else "", nm,
    });
}

/// Indented outline of an a11y subtree — the text-lane rendering of a
/// payload that used to be raw JSON.
fn a11yOutline(arena: std.mem.Allocator, w: *std.Io.Writer, node: std.json.Value, depth: u32) !void {
    if (node != .object) return;
    try w.writeAll("\n");
    var i: u32 = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");
    try w.writeAll(try a11yNodeLine(arena, node));
    if (node.object.get("children")) |kids| {
        if (kids == .array) for (kids.array.items) |k| try a11yOutline(arena, w, k, depth + 1);
    }
}

/// THE reader for a stored macro's `{"actions":[...]}` shape (shared by
/// app_macros show and app_macro_run). Null = not that shape, empty, or
/// past the 200-step replay cap.
fn macroSteps(arena: std.mem.Allocator, bytes: []const u8) ?[]const std.json.Value {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return null;
    if (parsed != .object) return null;
    const av = parsed.object.get("actions") orelse return null;
    if (av != .array) return null;
    if (av.array.items.len == 0 or av.array.items.len > 200) return null;
    return av.array.items;
}

/// The facts every app_click reply carries, in one place: the same set
/// on the landed, crashed and retried paths.
fn clickFacts(
    res: *Res,
    win_id: u32,
    x: i64,
    y: i64,
    button: u32,
    count: u32,
    hold_ms: i64,
    attempts: i64,
    repainted: bool,
) !void {
    try res.fact("window", win_id);
    try res.fact("x", x);
    try res.fact("y", y);
    try res.fact("button", button);
    try res.fact("count", count);
    try res.fact("hold_ms", hold_ms);
    try res.fact("attempts", attempts);
    try res.fact("repainted", repainted);
}

/// An error result that still tells the story: the typed code plus the
/// app's own state (exit status, signal, what it last printed) in the
/// message. `appErr` cannot carry facts, and an app that DIED while a
/// tool waited on it is exactly when those facts matter most.
fn appStateErr(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    code: mcp.ErrCode,
    msg: []const u8,
) ![]const u8 {
    return errRes(arena, code, try std.fmt.allocPrint(arena, "{s}\n{s}", .{ msg, try appSummaryText(arena, app) }));
}

pub const Tool = mcp_tools.GroupTool(.app);

/// What an app-scoped tool needs: interaction needs a RUNNING app, while
/// observation (output, log, windows, screenshots, waits) also answers
/// for one that exited.
const Need = enum { any, live };

/// One app-scoped tool body, run once its app is resolved and caught up.
const AppBody = fn (std.mem.Allocator, Tool, std.json.Value, *appdrive.App) anyerror![]const u8;

pub fn appTool(arena: std.mem.Allocator, tool: Tool, args: std.json.Value) ![]const u8 {
    if (!app_state.ready)
        return errRes(arena, .unavailable, "app tools unavailable (server not fully started)");
    return switch (tool) {
        .launch_app => launchApp(arena, args),
        .list_installed_apps => listInstalledApps(arena, args),
        .list_apps => listApps(arena, args),
        .app_templates => appTemplates(arena, args),
        .app_template_save => appTemplateSave(arena, args),
        .app_macros => appMacros(arena, args),
        .app_macro_save => appMacroSave(arena, args),
        .app_windows => withApp(arena, tool, args, .any, appWindows),
        .app_output => withApp(arena, tool, args, .any, appOutput),
        .app_wait_log => withApp(arena, tool, args, .any, waitLog),
        .app_log => withApp(arena, tool, args, .any, appLog),
        .screenshot_app => withApp(arena, tool, args, .any, screenshotApp),
        .get_app_state => withApp(arena, tool, args, .any, screenshotApp),
        .app_drag => withApp(arena, tool, args, .live, appDrag),
        .app_clipboard_get => withApp(arena, tool, args, .live, appClipboardGet),
        .app_clipboard_set => withApp(arena, tool, args, .live, appClipboardSet),
        .app_click => withApp(arena, tool, args, .live, appClick),
        .app_actions => withApp(arena, tool, args, .any, appActions),
        .app_mouse_move => withApp(arena, tool, args, .live, appMouseMove),
        .app_perform_action => withApp(arena, tool, args, .live, appPerformAction),
        .app_set_value => withApp(arena, tool, args, .live, appSetValue),
        .app_wait_for_element => withApp(arena, tool, args, .live, appWaitForElement),
        .app_type => withApp(arena, tool, args, .live, appType),
        .app_key => withApp(arena, tool, args, .live, appKey),
        .app_scroll => withApp(arena, tool, args, .live, appScroll),
        .app_resize => withApp(arena, tool, args, .live, appResize),
        .app_wait => withApp(arena, tool, args, .any, appWait),
        .app_watch => withApp(arena, tool, args, .live, appWatch),
        .app_hover_map => withApp(arena, tool, args, .live, hoverMap),
        .app_backtrace => withApp(arena, tool, args, .live, appBacktrace),
        .app_a11y_tree => withApp(arena, tool, args, .live, appA11yTree),
        .app_record_start => withApp(arena, tool, args, .live, appRecordStart),
        .app_record_stop => withApp(arena, tool, args, .any, appRecordStop),
        .app_read_text => withApp(arena, tool, args, .live, appReadText),
        .app_wait_text => withApp(arena, tool, args, .live, appWaitText),
        .app_find_image => withApp(arena, tool, args, .live, appFindImage),
        .app_wait_image => withApp(arena, tool, args, .live, appWaitImage),
        .app_macro_run => withApp(arena, tool, args, .live, appMacroRun),
        .close_app_window => withApp(arena, tool, args, .live, closeAppWindow),
        .close_app => withApp(arena, tool, args, .any, closeApp),
    };
}

/// Resolve the addressed app, catch it up to its live frame, then run one
/// app-scoped tool on it.
fn withApp(
    arena: std.mem.Allocator,
    tool: Tool,
    args: std.json.Value,
    comptime need: Need,
    comptime body: AppBody,
) ![]const u8 {
    const app = switch (appSelect(arena, args)) {
        .app => |a| a,
        .err => |e| return errRes(arena, .not_found, e),
    };
    // Catch up to the LIVE frame before any observation or input
    // baseline. The 100ms-boxed drain() only chewed part of a between-
    // calls backlog, so screenshots lagged by whole screens on busy
    // apps (SDL games) — the daemon now pauses streaming to a
    // backlogged MCP client and replays current state once we drain;
    // drainLive waits for that replay (bounded).
    _ = app.drainLive(CATCHUP_MS);

    // "The app exited" is a NORMAL state, handled centrally: every
    // interaction tool answers with the exit summary IMMEDIATELY
    // (short-lived programs and observing crashes are routine).
    // Observation tools handle exit themselves; close_app stays
    // idempotent.
    if (need == .live and (app.exited or app.presentationGone())) {
        _ = probeAppStop(app, 1_000);
        return appStateErr(arena, app, .conflict, try std.fmt.allocPrint(
            arena,
            "the app has exited or disconnected - {s} needs a running app",
            .{@tagName(tool)},
        ));
    }
    return body(arena, tool, args, app);
}

fn launchApp(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(arena);
    const built = switch (try buildLaunchArgv(arena, &argv, args)) {
        .ok => |b| b,
        .err => |msg| return errRes(arena, .invalid_args, msg),
    };
    // Chromium-family binaries default to X11 and die in the
    // Wayland-only session; inject the ozone flag unless the
    // caller chose one (argv form only — a shell string cannot be
    // rewritten safely).
    var browser_note: []const u8 = "";
    const argv_form = built.argv_form;
    if (argv_form and chromiumFamily(argv.items[0])) {
        var has_ozone = false;
        for (argv.items) |a| {
            if (std.mem.startsWith(u8, a, "--ozone-platform")) has_ozone = true;
        }
        if (!has_ozone) {
            try argv.insert(arena, 1, "--ozone-platform=wayland");
            browser_note = "auto-added --ozone-platform=wayland: Chromium-family app in a Wayland-only session";
        }
    }
    const debug_note = switch (try applyDebugWrap(arena, &argv, args)) {
        .note => |n| n,
        .err => |e| return errRes(arena, .invalid_args, e),
    };
    const audio_mode = argStr(args, "audio") orelse "forward";
    if (!eql(u8, audio_mode, "forward") and !eql(u8, audio_mode, "none"))
        return errRes(arena, .invalid_args, "'audio' must be \"forward\" or \"none\"");
    const audio_path = argStr(args, "audio_path");
    if (audio_path) |ap| {
        if (eql(u8, audio_mode, "none"))
            return errRes(arena, .invalid_args, "'audio_path' needs the sink: drop audio:\"none\"");
        if (ap.len == 0 or ap[0] != '/')
            return errRes(arena, .invalid_args, "'audio_path' must be an absolute path (it lands on the daemon's host)");
    }
    const cols: u16 = @intCast(std.math.clamp(argInt(args, "cols") orelse 80, 10, 500));
    const rows: u16 = @intCast(std.math.clamp(argInt(args, "rows") orelse 24, 4, 300));
    const wait_ms: i64 = argInt(args, "wait_ms") orelse 10_000;
    var out_w: u32 = 0;
    var out_h: u32 = 0;
    if (argStr(args, "size")) |sz| {
        const dims = @import("../mux/display.zig").parseSize(sz) orelse
            return errRes(arena, .invalid_args, "'size' must be \"WxH\" pixels (1..16384 per side, at most 64 megapixels), e.g. \"3840x2160\"");
        out_w = dims[0];
        out_h = dims[1];
    }
    var env_list: std.ArrayList([]const u8) = .empty;
    defer env_list.deinit(arena);
    var user_set_ozone_hint = false;
    if (args == .object) {
        if (args.object.get("env")) |e| {
            if (e != .object) return errRes(arena, .invalid_args, "'env' must be an object of KEY: \"value\" strings");
            var it = e.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .string)
                    return errRes(arena, .invalid_args, "'env' values must be strings");
                if (std.mem.eql(u8, entry.key_ptr.*, "ELECTRON_OZONE_PLATFORM_HINT")) user_set_ozone_hint = true;
                try env_list.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.string }));
            }
        }
    }
    // Electron apps honor this hint and ignore it otherwise; the
    // session has no X server, so wayland is the right default.
    if (!user_set_ozone_hint)
        try env_list.append(arena, "ELECTRON_OZONE_PLATFORM_HINT=wayland");
    const app = appdrive.App.launch(app_state.allocator, argv.items, .{
        .cols = cols,
        .rows = rows,
        .host = argStr(args, "host"),
        .kb_layout = argStr(args, "layout"),
        .local_sock = app_state.mux_sock,
        .gpu = argBool(args, "gpu"),
        .no_audio = eql(u8, audio_mode, "none"),
        .audio_capture = audio_path,
        .cwd = argStr(args, "cwd"),
        .env = env_list.items,
        .output_width = out_w,
        .output_height = out_h,
        .xwayland = argBool(args, "xwayland"),
    }) catch |err| switch (err) {
        appdrive.Error.SpawnFailed => {
            const why = appdrive.lastLaunchErr();
            if (std.mem.indexOf(u8, why, "XwaylandUnavailable") != null)
                return errRes(arena, .unavailable, "xwayland:true needs Xwayland AND xwayland-satellite on the daemon host's PATH (capabilities.app_xwayland reports this for the local daemon); install them or drop xwayland — nothing was launched");
            return errRes(arena, .unavailable, if (why.len > 0)
                try std.fmt.allocPrint(arena, "spawn failed — {s}", .{why})
            else
                "spawn failed (mux daemon unreachable or spawn refused)");
        },
        appdrive.Error.BadLayout => return errRes(arena, .invalid_args, "unknown keyboard layout (available: us, gb, fr, be, de)"),
        else => return appErr(arena, "launch failed"),
    };
    // Requested X11 but the daemon answered without a display: an
    // older daemon ignored the field. Refuse rather than hand back
    // a session whose X clients can never surface.
    if (argBool(args, "xwayland") and app.x_display == null) {
        _ = app.killAndWait(5_000);
        app.deinit();
        return errRes(arena, .unavailable, "xwayland:true was requested but the daemon attached no X11 display (an older sketerm-mux that predates rootless X11 for app sessions); upgrade the daemon or drop xwayland");
    }
    const id = app_state.next_id;
    app_state.next_id += 1;
    app_state.apps.put(app_state.allocator, id, app) catch {
        app.deinit();
        return error.OutOfMemory;
    };
    const wait_for = argStr(args, "wait_for") orelse "window";
    if (eql(u8, wait_for, "exit")) {
        const deadline = nowMs() + wait_ms;
        while (!app.exited and nowMs() < deadline) _ = app.pumpOnce(50);
    } else {
        _ = app.waitFirstWindow(wait_ms);
    }
    // Launch-and-look must not return the pre-paint frame: "window
    // exists" is earlier than "window has content" for most apps,
    // and a black frame-1 screenshot reads as a broken app. Let
    // painting quiesce briefly before capturing (0 disables).
    const stable_ms: i64 = std.math.clamp(argInt(args, "stable_ms") orelse 500, 0, 10_000);
    var shot_win: u32 = 0;
    for (app.windows.items) |win| {
        if (!win.popup and win.frames > 0) {
            shot_win = win.id;
            break;
        }
    }
    var settled = true;
    if (shot_win != 0 and stable_ms > 0 and !app.exited)
        settled = app.waitVisualSettle(shot_win, stable_ms, @max(stable_ms * 4, 2000), 0, null);

    var res = Res.init(arena);
    try addAppSummary(&res, arena, app);
    if (out_w != 0 and (app.output_width != out_w or app.output_height != out_h)) {
        try res.fact("requested_output_applied", false);
        if (app.output_width == 0)
            try res.textf("WARNING: the daemon did not confirm the requested {d}x{d} output (older daemon — 'size' was likely ignored, the screen stays 1920x1080)", .{ out_w, out_h })
        else
            try res.textf("WARNING: requested {d}x{d} output but the daemon applied {d}x{d}", .{ out_w, out_h, app.output_width, app.output_height });
    }
    if (browser_note.len > 0) try res.text(browser_note);
    if (debug_note.len > 0) try res.text(std.mem.trimStart(u8, debug_note, "\n"));
    try res.fact("xwayland", app.x_display != null);
    if (app.x_display) |xd| {
        try res.fact("x_display", xd);
        try res.fact("xauthority", app.xauthority orelse "");
        try res.textf("rootless X11: DISPLAY={s} XAUTHORITY={s} (exported to the app; X toplevels surface as app windows)", .{ xd, app.xauthority orelse "" });
    }
    if (audio_path) |ap| {
        const stem = if (std.mem.endsWith(u8, ap, ".wav")) ap[0 .. ap.len - 4] else ap;
        try res.fact("audio_capture", try std.fmt.allocPrint(arena, "{s}.wav", .{stem}));
        try res.textf("audio capture: {s}.wav on the daemon host (later streams: {s}-N.wav; finalized when the stream or app closes)", .{ stem, stem });
    }
    // Launch-and-look is THE common case: when a window rendered,
    // fold the first screenshot into the launch reply.
    if (shot_win != 0 and !app.exited) {
        var shot_frames: u64 = 0;
        for (app.windows.items) |win| {
            if (win.id == shot_win) shot_frames = win.frames;
        }
        if (!settled)
            try res.textf("inline screenshot: window was STILL REPAINTING after the {d}ms settle wait — it may be mid-paint or the app animates continuously; screenshot_app with stable_ms/min_frame gets settled pixels", .{stable_ms})
        else if (shot_frames <= 1)
            try res.text("inline screenshot is the window's FIRST committed frame and may precede the app's real paint — screenshot_app with stable_ms gets settled content");
        if (app.screenshotPng(shot_win, 1568, null, 1)) |shot| {
            defer app_state.allocator.free(shot.png);
            try res.fact("settled", settled);
            try res.fact("window", shot_win);
            try addShotFacts(&res, arena, app, shot_win, shot);
            return res.finishWithImages(&.{shot.png}, null);
        } else |_| {}
    }
    return res.finish();
}

fn listInstalledApps(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const listing = appdrive.listInstalledApps(app_state.allocator, argStr(args, "host"), app_state.mux_sock) catch |err| switch (err) {
        appdrive.Error.SpawnFailed => return errRes(arena, .unavailable, "cannot reach the daemon (is sketerm-mux running / host reachable?)"),
        appdrive.Error.Timeout => return errRes(arena, .timeout, "the daemon did not answer the app-discovery request in time"),
        else => return appErr(arena, "app discovery failed"),
    };
    defer app_state.allocator.free(listing);
    const Listing = struct {
        apps: []const struct { name: []const u8 = "", exec: []const u8 = "", icon: []const u8 = "" } = &.{},
        @"error": []const u8 = "",
    };
    const parsed = std.json.parseFromSliceLeaky(Listing, arena, listing, .{ .ignore_unknown_fields = true }) catch
        return appErr(arena, "malformed app listing from the daemon");
    if (parsed.@"error".len > 0 and parsed.apps.len == 0)
        return errRes(arena, .io_failed, try std.fmt.allocPrint(arena, "app discovery failed on the daemon host: {s}", .{parsed.@"error"}));
    var res = Res.init(arena);
    try res.fact("apps", parsed.apps);
    try res.field("count", parsed.apps.len);
    if (argStr(args, "host")) |h| try res.field("host", h);
    if (parsed.apps.len > 0) {
        try res.text("--- installed apps (name: command) ---");
        for (parsed.apps) |a| try res.textf("{s}: {s}", .{ a.name, a.exec });
    }
    return res.finish();
}

fn listApps(arena: std.mem.Allocator, _: std.json.Value) ![]const u8 {
    var res = Res.init(arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("[");
    var first = true;
    for (app_state.apps.values()) |app| {
        app.drain();
        if (!first) try w.writeAll(",");
        first = false;
        var one = Res.init(arena);
        try appFacts(&one, arena, app, true);
        try w.writeAll(try one.structuredJson());
        try res.text(try appSummaryText(arena, app));
    }
    try w.writeAll("]");
    try res.raw("apps", aw.written());
    try res.fact("count", app_state.apps.count());
    if (app_state.apps.count() == 0)
        try res.text("no app sessions (launch one with launch_app)");
    return res.finish();
}

fn appTemplates(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    if (argStr(args, "delete")) |del| {
        mcpassets.delete(app_state.allocator, .template, del) catch |err| switch (err) {
            mcpassets.Error.NotFound => return errRes(arena, .not_found, "no such template"),
            mcpassets.Error.BadName => return errRes(arena, .invalid_args, "invalid template name"),
            else => return errRes(arena, .io_failed, "delete failed"),
        };
        var res = Res.init(arena);
        try res.field("deleted", del);
        return res.finish();
    }
    const names = mcpassets.list(app_state.allocator, .template) catch
        return errRes(arena, .io_failed, "listing templates failed");
    defer {
        for (names) |nm| app_state.allocator.free(nm);
        app_state.allocator.free(names);
    }
    var res = Res.init(arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("[");
    for (names, 0..) |nm, i| {
        if (i > 0) try w.writeAll(",");
        var dw: u32 = 0;
        var dh: u32 = 0;
        if (mcpassets.load(arena, .template, nm)) |bytes| {
            if (png_util.decodeRgba(arena, bytes)) |dec| {
                arena.free(dec.rgba);
                dw = dec.w;
                dh = dec.h;
            } else |_| {}
        } else |_| {}
        if (dw != 0) {
            try w.print("{{\"name\":{f},\"w\":{d},\"h\":{d}}}", .{ std.json.fmt(nm, .{}), dw, dh });
            try res.textf("{s} ({d}x{d})", .{ nm, dw, dh });
        } else {
            try w.print("{{\"name\":{f}}}", .{std.json.fmt(nm, .{})});
            try res.textf("{s} (size unreadable)", .{nm});
        }
    }
    try w.writeAll("]");
    try res.raw("templates", aw.written());
    try res.fact("count", names.len);
    if (names.len == 0) try res.text("no saved templates (save one with app_template_save)");
    return res.finish();
}

fn appTemplateSave(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const tname = argStr(args, "name") orelse return errRes(arena, .invalid_args, "app_template_save requires 'name'");
    if (!mcpassets.validName(tname))
        return errRes(arena, .invalid_args, "invalid template name (letters, digits, . _ - only, max 64)");
    var png_bytes: []const u8 = undefined;
    var dw: u32 = 0;
    var dh: u32 = 0;
    var source: []const u8 = "inline";
    if (argStr(args, "image_b64")) |b64| {
        const decoder = std.base64.standard.Decoder;
        const max = decoder.calcSizeForSlice(b64) catch return errRes(arena, .invalid_args, "image_b64 is not valid base64");
        const raw = try arena.alloc(u8, max);
        decoder.decode(raw, b64) catch return errRes(arena, .invalid_args, "image_b64 is not valid base64");
        const dec = png_util.decodeRgba(arena, raw) catch
            return errRes(arena, .invalid_args, "image_b64 does not decode as an image");
        arena.free(dec.rgba);
        dw = dec.w;
        dh = dec.h;
        png_bytes = raw;
    } else {
        source = "capture";
        const capp = appFromArgs(args) orelse
            return errRes(arena, .invalid_args, "pass 'app' (capture from its window) or 'image_b64' (inline PNG)");
        capp.drain();
        const region = regionFrom(args) orelse
            return errRes(arena, .invalid_args, "capturing needs 'region' {x,y,w,h} — crop JUST the distinctive UI element (a whole window makes a useless template)");
        const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(capp);
        if (wid == 0) return errRes(arena, .not_found, "no rendered window yet (try app_wait first)");
        const shot = capp.snapshotRgba(wid, region) catch
            return errRes(arena, .not_found, "no rendered pixels in that window (yet?)");
        defer app_state.allocator.free(shot.px);
        dw = shot.w;
        dh = shot.h;
        png_bytes = png_util.encodeRgba(arena, shot.px, shot.w, shot.h) catch return error.OutOfMemory;
    }
    mcpassets.save(app_state.allocator, .template, tname, png_bytes) catch |err| switch (err) {
        mcpassets.Error.TooBig => return errRes(arena, .invalid_args, "template too large (8 MB cap)"),
        else => return errRes(arena, .io_failed, "saving the template failed (state dir not writable?)"),
    };
    var res = Res.init(arena);
    try res.field("name", tname);
    try res.field("w", dw);
    try res.field("h", dh);
    try res.field("source", source);
    try res.fact("bytes", png_bytes.len);
    return res.finish();
}

fn appMacros(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    if (argStr(args, "delete")) |del| {
        mcpassets.delete(app_state.allocator, .macro, del) catch |err| switch (err) {
            mcpassets.Error.NotFound => return errRes(arena, .not_found, "no such macro"),
            mcpassets.Error.BadName => return errRes(arena, .invalid_args, "invalid macro name"),
            else => return errRes(arena, .io_failed, "delete failed"),
        };
        var res = Res.init(arena);
        try res.field("deleted", del);
        return res.finish();
    }
    if (argStr(args, "show")) |nm| {
        const bytes = mcpassets.load(arena, .macro, nm) catch |err| switch (err) {
            mcpassets.Error.NotFound => return errRes(arena, .not_found, "no such macro"),
            mcpassets.Error.BadName => return errRes(arena, .invalid_args, "invalid macro name"),
            mcpassets.Error.OutOfMemory => return error.OutOfMemory,
            else => return errRes(arena, .io_failed, "macro load failed"),
        };
        var res = Res.init(arena);
        try res.field("macro", nm);
        if (macroSteps(arena, bytes)) |sv| {
            try res.field("steps", sv.len);
            // Re-serialized from the parse, never the stored bytes:
            // the macro store is an ordinary shared directory, so a
            // document may be pretty-printed and a raw newline in
            // structuredContent splits the NDJSON response line.
            var aw: std.Io.Writer.Allocating = .init(arena);
            try aw.writer.writeAll("{\"actions\":");
            try std.json.Stringify.value(sv, .{}, &aw.writer);
            try aw.writer.writeAll("}");
            try res.raw("actions", aw.written());
            try res.text("--- steps ---");
            for (sv, 0..) |st, i| {
                var jw: std.Io.Writer.Allocating = .init(arena);
                try std.json.Stringify.value(st, .{}, &jw.writer);
                try res.textf("{d}. {s}", .{ i + 1, jw.written() });
            }
        } else {
            try res.text("the stored macro is not the expected {actions:[...]} shape — inspect it with app_macros show");
        }
        return res.finish();
    }
    if (argBool(args, "journal")) {
        const capp = appFromArgs(args) orelse
            return errRes(arena, .invalid_args, "the journal view needs 'app' (recorded steps are per app)");
        const entries = Journal.entriesOf(appIdOf(capp));
        var res = Res.init(arena);
        try res.fact("app", appIdOf(capp));
        try res.field("recorded_steps", entries.len);
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("[");
        for (entries, 0..) |e, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll(e.step);
        }
        try w.writeAll("]");
        try res.raw("journal", aw.written());
        if (entries.len > 0) {
            try res.text("--- recorded input steps, oldest first (save the tail with app_macro_save last_steps:N) ---");
            for (entries, 0..) |e, i| try res.textf("{d}. {s}", .{ i + 1, e.step });
        }
        return res.finish();
    }
    const names = mcpassets.list(app_state.allocator, .macro) catch
        return errRes(arena, .io_failed, "listing macros failed");
    defer {
        for (names) |nm| app_state.allocator.free(nm);
        app_state.allocator.free(names);
    }
    var res = Res.init(arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("[");
    for (names, 0..) |nm, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{f}", .{std.json.fmt(nm, .{})});
        try res.text(nm);
    }
    try w.writeAll("]");
    try res.raw("macros", aw.written());
    try res.fact("count", names.len);
    if (names.len == 0) try res.text("no saved macros (record one with app_macro_save)");
    return res.finish();
}

fn appMacroSave(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const mname = argStr(args, "name") orelse return errRes(arena, .invalid_args, "app_macro_save requires 'name'");
    if (!mcpassets.validName(mname))
        return errRes(arena, .invalid_args, "invalid macro name (letters, digits, . _ - only, max 64)");
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{\"actions\":[");
    var count: usize = 0;
    var from_journal = false;
    if (args == .object and args.object.get("actions") != null) {
        const av = args.object.get("actions").?;
        if (av != .array or av.array.items.len == 0)
            return errRes(arena, .invalid_args, "'actions' must be a non-empty array of step objects");
        if (av.array.items.len > 200) return errRes(arena, .invalid_args, "too many steps (max 200)");
        for (av.array.items, 0..) |st, i| {
            if (st != .object) return errRes(arena, .invalid_args, "each action step must be an object");
            if (i > 0) try w.writeAll(",");
            std.json.Stringify.value(st, .{}, w) catch return error.OutOfMemory;
        }
        count = av.array.items.len;
    } else {
        from_journal = true;
        const capp = appFromArgs(args) orelse
            return errRes(arena, .invalid_args, "recording from the journal needs 'app' (or pass explicit 'actions')");
        const entries = Journal.entriesOf(appIdOf(capp));
        if (entries.len == 0)
            return errRes(arena, .not_found, "no recorded input steps for this app yet — drive it (app_click / app_key / app_actions / ...), then save");
        var take: usize = entries.len;
        if (argInt(args, "last_steps")) |ls| {
            if (ls <= 0) return errRes(arena, .invalid_args, "'last_steps' must be positive");
            take = @min(take, @as(usize, @intCast(ls)));
        }
        var first = true;
        var prev_t: i64 = 0;
        for (entries[entries.len - take ..], 0..) |e, i| {
            // Preserve think-time between recorded inputs as wait
            // steps (clamped) so the replay paces like the drive.
            if (i > 0 and e.t - prev_t >= 250) {
                if (!first) try w.writeAll(",");
                first = false;
                try w.print("{{\"wait\":{d}}}", .{@min(e.t - prev_t, 10_000)});
            }
            prev_t = e.t;
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll(e.step);
            count += 1;
        }
    }
    try w.writeAll("]}");
    mcpassets.save(app_state.allocator, .macro, mname, aw.written()) catch |err| switch (err) {
        mcpassets.Error.TooBig => return errRes(arena, .invalid_args, "macro too large"),
        else => return errRes(arena, .io_failed, "saving the macro failed (state dir not writable?)"),
    };
    var res = Res.init(arena);
    try res.field("name", mname);
    try res.field("steps", count);
    try res.field("from_journal", from_journal);
    if (from_journal) try res.text("think-time between recorded inputs was preserved as wait steps");
    return res.finish();
}

fn appWindows(arena: std.mem.Allocator, _: Tool, _: std.json.Value, app: *appdrive.App) ![]const u8 {
    var res = Res.init(arena);
    try addAppSummary(&res, arena, app);
    return res.finish();
}

fn appOutput(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const text = app.output(argBool(args, "scrollback")) catch |err| switch (err) {
        appdrive.Error.Desynced => return errRes(arena, .unavailable, "this app's terminal mirror lost sync with the session and could not be rebuilt, so its content is stale; use app_log, which is served daemon-side"),
        else => return errRes(arena, .unavailable, "no terminal mirror for this app (output unavailable)"),
    };
    defer app_state.allocator.free(text);
    var res = Res.init(arena);
    try res.fact("app", appIdOf(app));
    try res.fact("exited", app.exited);
    if (app.exited) {
        try res.fact("exit_status", app.exit_status);
        try res.textf("app exited, status {d}{s}", .{ app.exit_status, try exitSuffix(arena, app.exit_status) });
    }
    var body: []const u8 = try arena.dupe(u8, text);
    var source: []const u8 = "terminal_grid";
    if (std.mem.trim(u8, text, " \n\t\r").len == 0) {
        // A blank grid mirror does not mean "no output" — the log
        // ring (app_log) is the source of truth for line output.
        // Only the post-exit stash is served here; a live app's
        // log_buf may hold a stale earlier log_get reply.
        if (if (app.exited) logStashTail(arena, app, 25) else null) |tail_text| {
            source = "log_ring";
            body = tail_text;
            try res.text("the terminal grid mirror is blank — serving the last lines from the log ring instead; app_log is the source of truth for line output");
        } else {
            source = "empty";
            body = "";
            try res.text(if (argBool(args, "scrollback"))
                "the app has written nothing to its stdout/stderr PTY — GUI apps often print little; stderr redirected elsewhere by the app itself is not visible here. app_log is the indexed view of the same PTY"
            else
                "no output on the visible terminal grid — pass scrollback:true for scrolled-off history, or use app_log for indexed lines");
        }
    }
    try res.fact("source", source);
    try res.fact("output", body);
    if (body.len > 0) try res.textf("--- output ({s}) ---\n{s}", .{ source, body });
    return res.finish();
}

fn appLog(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const line_id: u64 = @intCast(@max(argInt(args, "id") orelse 0, 0));
    const from_id: u64 = @intCast(@max(argInt(args, "from_id") orelse 0, 0));
    const filter: ?mcp.pattern.Matcher = switch (logFilterFrom(arena, args)) {
        .none => null,
        .m => |m| m,
        .err => |e| return errRes(arena, .invalid_args, e),
    };
    // Filtering scans the widest window the ring serves, then
    // reports how many lines were SCANNED vs matched — `tail` caps
    // the matches shown, not the search.
    const tail: i64 = if (filter != null) 500 else std.math.clamp(argInt(args, "tail") orelse 60, 1, 500);
    const show_max: usize = @intCast(std.math.clamp(argInt(args, "tail") orelse 60, 1, 500));
    const req = try std.fmt.allocPrint(
        arena,
        "{{\"tail\":{d},\"from_id\":{d},\"id\":{d},\"max_chars\":300}}",
        .{ tail, from_id, line_id },
    );
    const fetch = app.logGet(req, 5_000) catch |err| switch (err) {
        appdrive.Error.Timeout => {
            // Both the primary connection AND a fresh side
            // connection failed — serve the PTY grid mirror as the
            // last resort (content without line ids beats nothing),
            // with liveness data so "log stuck" and "app wedged"
            // read differently.
            var frames: u64 = 0;
            for (app.windows.items) |w| frames += w.frames;
            if (app.output(false)) |grid| {
                defer app_state.allocator.free(grid);
                var res = Res.init(arena);
                try res.fact("app", appIdOf(app));
                try res.fact("source", "terminal_grid");
                try res.fact("output", grid);
                try res.textf(
                    "the log path timed out even over a fresh daemon connection (app alive: {}, windows: {d}, frames committed: {d}) — serving the PTY grid mirror instead; NO line ids, wrapped at the grid width",
                    .{ !app.exited, app.windows.items.len, frames },
                );
                try res.textf("--- terminal grid ---\n{s}", .{grid});
                return res.finish();
            } else |_| {}
            return errRes(arena, .timeout, try std.fmt.allocPrint(
                arena,
                "the daemon's log reply did not arrive within 5s, a fresh side connection also failed, and no grid mirror is available (app alive: {}, windows: {d}, frames committed: {d})",
                .{ !app.exited, app.windows.items.len, frames },
            ));
        },
        else => return if (app.exited)
            errRes(arena, .not_found, "the app exited and its log stash is empty — no output was captured before exit (a known app id, distinct from 'unknown app')")
        else
            errRes(arena, .unavailable, "log unavailable: the connection to the app's daemon was lost"),
    };
    const reply = fetch.json;
    defer app_state.allocator.free(reply);
    if (fetch.stale and line_id != 0)
        return errRes(arena, .timeout, "the daemon's log reply did not arrive within 5s; only a stale cached snapshot is available, which cannot answer a single-line fetch honestly — retry in a moment");
    const parsed = std.json.parseFromSlice(LogReplyJ, arena, reply, .{
        .ignore_unknown_fields = true,
    }) catch return appErr(arena, "malformed log reply");
    const r = parsed.value;
    const now_wall: i64 = wallMs();

    if (line_id != 0) {
        // One line in full — the post-exit stash may return the whole
        // final log, so filter by id here.
        var found: ?LogLineJ = null;
        for (r.lines) |l| {
            if (l.id == line_id) found = l;
        }
        const l = found orelse
            return errRes(arena, .not_found, "line not available (dropped from the ring, never emitted, or beyond the post-exit stash)");
        const age_s = @as(f64, @floatFromInt(now_wall - l.t)) / 1000.0;
        var res = Res.init(arena);
        try res.fact("app", appIdOf(app));
        try res.fact("line_id", l.id);
        try res.fact("age_ms", now_wall - l.t);
        try res.fact("marker", l.marker);
        try res.fact("truncated", l.truncated);
        try res.fact("text", l.text);
        if (l.marker) {
            if (app.markerImage(line_id)) |img| {
                try res.fact("marker_screenshot", true);
                if (img.shared_from != 0) try res.fact("screenshot_shared_from", img.shared_from);
                try res.textf("marker line {d} ({d:.1}s ago): '{s}' — window at that instant below{s}", .{
                    l.id, age_s, l.text,
                    if (img.shared_from != 0)
                        try std.fmt.allocPrint(arena, " (frame unchanged since marker {d}; screenshot shared)", .{img.shared_from})
                    else
                        "",
                });
                return res.finishWithImages(&.{img.png}, null);
            }
            try res.fact("marker_screenshot", false);
            try res.textf(
                "marker line {d} ({d:.1}s ago): '{s}' (no screenshot was stashed: no rendered window at the time, or the marker aged out)",
                .{ l.id, age_s, l.text },
            );
            return res.finish();
        }
        try res.textf("line {d}, {d:.1}s ago{s}", .{
            l.id,
            age_s,
            if (l.truncated) ", was longer than the 4KB line cap" else "",
        });
        try res.textf("--- line ---\n{s}", .{l.text});
        return res.finish();
    }

    var res = Res.init(arena);
    try res.fact("app", appIdOf(app));
    try res.fact("stale", fetch.stale);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    if (fetch.stale)
        try res.text("STALE: the daemon's fresh log reply was still queued behind streamed frame data after 5s — serving the last cached snapshot instead; retry app_log for current lines");
    // A filter narrows what is PRINTED; the scanned window is
    // reported alongside so "0 matches" can never be mistaken for
    // the plain tail. Silently serving unmatched lines (the old
    // behaviour of an unimplemented `grep`) reads as matched
    // content to anyone diffing the output.
    var shown: std.ArrayList(LogLineJ) = .empty;
    defer shown.deinit(arena);
    var matched: usize = 0;
    if (filter) |m| {
        for (r.lines) |l| {
            if (!m.matches(l.text)) continue;
            matched += 1;
            try shown.append(arena, l);
        }
        if (shown.items.len > show_max)
            try shown.replaceRange(arena, 0, shown.items.len - show_max, &.{});
    } else {
        try shown.appendSlice(arena, r.lines);
    }
    const lines = shown.items;
    const pat = argStr(args, "pattern") orelse argStr(args, "grep") orelse "";
    try res.fact("scanned", r.lines.len);
    try res.fact("shown", lines.len);
    try res.fact("next_id", r.next_id);
    try res.fact("dropped", r.dropped);
    try res.fact("markers_dropped", r.markers_dropped);
    if (filter != null) {
        try res.fact("pattern", pat);
        try res.fact("matched", matched);
    }
    if (filter != null and lines.len == 0) {
        try res.textf(
            "0 of {d} scanned line(s) match \"{s}\" (ids {d}..{d}). NOTHING is shown — this is not a tail: the pattern simply has not appeared yet. Wait for it with app_wait_log.",
            .{
                r.lines.len,
                pat,
                if (r.lines.len > 0) r.lines[0].id else 0,
                if (r.lines.len > 0) r.lines[r.lines.len - 1].id else 0,
            },
        );
    } else if (lines.len == 0) {
        try res.text("log empty — the app has not printed any complete line yet");
    } else {
        if (filter != null) {
            try w.print("{d} of {d} scanned line(s) match \"{s}\"", .{ matched, r.lines.len, pat });
            if (matched > lines.len) try w.print(" (newest {d} shown)", .{lines.len});
            try w.writeAll("; ");
        }
        try w.print("log lines {d}..{d} (newest id {d})", .{
            lines[0].id, lines[lines.len - 1].id, r.next_id - 1,
        });
        if (r.dropped > 0) try w.print(", {d} oldest dropped by the ring cap", .{r.dropped});
        if (r.markers_dropped > 0) try w.print(", {d} markers rate-limited", .{r.markers_dropped});
        try w.writeAll(" — [+] = shortened, fetch one in full by its id");
        try res.text(aw.written());
        aw.clearRetainingCapacity();
        try w.writeAll("--- log ---");
        for (lines) |l| {
            const age_s = @as(f64, @floatFromInt(now_wall - l.t)) / 1000.0;
            if (l.marker) {
                const has_shot = app.markerImage(l.id) != null;
                try w.print("\n{d} [-{d:.1}s] [marker '{s}'{s}]", .{
                    l.id, age_s, l.text,
                    if (has_shot) " — screenshot stashed, fetch it by this line's id" else "",
                });
            } else {
                try w.print("\n{d} [-{d:.1}s] {s}{s}", .{
                    l.id,                                     age_s, l.text,
                    if (l.cut or l.truncated) " [+]" else "",
                });
            }
        }
        try res.text(aw.written());
    }
    try res.fact("lines", lines);
    return res.finish();
}

fn screenshotApp(arena: std.mem.Allocator, tool: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    var win_id: u32 = 0;
    if (argInt(args, "window")) |v| {
        win_id = @intCast(v);
    } else {
        win_id = firstToplevelId(app);
    }
    if (win_id == 0) {
        // "No window" and "the app died" are different answers —
        // report the exit (status, signal, output) when it applies.
        if (app.exited)
            return appStateErr(arena, app, .conflict, "the app has exited — no window to screenshot");
        return errRes(arena, .not_found, "no rendered window yet (try app_wait first)");
    }
    const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 10_000, 0, mcp.WAIT_CAP_MS);
    // min_change_pct also thresholds wait_change/stable_ms so
    // continuously-animating apps (a 60Hz software cursor) can
    // still signal/settle on CONTENT changes. Burst reads its own
    // copy below (different default).
    const wait_min_pct: f64 = argFloat(args, "min_change_pct") orelse 0;
    // Freshness gate. wait_change is relative to the caller's LAST
    // screenshot, which cannot express "newer than the keypress I
    // just sent"; min_frame is anchored to the commit counter every
    // capture reports, so a capture can be PROVEN newer than an
    // input instead of hoped to be.
    if (argInt(args, "min_frame")) |mf| {
        const want: u64 = @intCast(@max(mf, 0));
        if (!app.waitFrameAfter(win_id, want, timeout_ms)) {
            const have = app.frameCount(win_id);
            return errRes(arena, .timeout, try std.fmt.allocPrint(
                arena,
                "window {d} committed no frame past {d} within {d}ms — it is still at frame {d}{s}. Nothing was captured (a stale image is worse than an error here).",
                .{ win_id, want, timeout_ms, have, if (app.exited) "; the app has EXITED" else "" },
            ));
        }
    }
    // Region is parsed BEFORE the waits/stats: it scopes not just
    // the crop but every pixel-change percentage below — "did THIS
    // rectangle change" is assertable without eyeballing the image.
    var region: ?appdrive.App.Region = null;
    if (args == .object) {
        if (args.object.get("region")) |rv| {
            region = regionOf(rv) orelse return errRes(
                arena,
                .invalid_args,
                "'region' must be an OBJECT with integer x, y, w, h — e.g. region:{\"x\":0,\"y\":330,\"w\":145,\"h\":150} (a bare [x,y,w,h] array is accepted too). w and h must be > 0 and x/y non-negative.",
            );
        }
    }
    // Percentages only scope to the rect when a threshold gates
    // them — a bare region stays a plain crop.
    const diff_region: ?appdrive.App.Region = if (wait_min_pct > 0) region else null;
    if (argBool(args, "wait_change")) {
        // Block (bounded) until the window commits a frame newer
        // than its last screenshot — "did my click do anything".
        if (!app.waitWindowChange(win_id, timeout_ms, wait_min_pct, diff_region))
            return errRes(arena, .timeout, if (diff_region != null)
                "the region's content did not change before the timeout"
            else
                "window content did not change before the timeout");
    }
    var res = Res.init(arena);
    if (argInt(args, "stable_ms")) |sm| {
        // Settle-then-capture: wait until the window stops
        // repainting before shooting (composes with wait_change:
        // "changed, then went quiet"). With a threshold this is
        // VISUAL settle: sub-threshold repaints don't reset it.
        const settled = if (sm <= 0)
            true
        else if (wait_min_pct > 0)
            app.waitVisualSettle(win_id, sm, timeout_ms, wait_min_pct, diff_region)
        else
            app.waitWindowSettle(win_id, sm, timeout_ms);
        try res.fact("settled", settled);
        if (!settled)
            try res.text("frames were still arriving at timeout_ms — captured anyway");
    }
    if (argBool(args, "stats_only")) {
        // Cheap change probe: no PNG, just "did it change and how
        // much" vs whatever the caller last saw. With a region the
        // diff_pct is computed inside that rect only.
        const st = app.diffStats(win_id, region) catch
            return errRes(arena, .not_found, "no such window / no pixels yet");
        if (tool == .get_app_state) try addAppSummary(&res, arena, app);
        try res.fact("window", win_id);
        try res.fact("changed", st.changed);
        try res.fact("diff_pct", st.diff_pct);
        try res.fact("resized", st.resized);
        try res.fact("w", st.w);
        try res.fact("h", st.h);
        try res.fact("frames", st.frames);
        try res.fact("diff_scope", if (region != null) "region" else "window");
        try res.textf("window {d}: {s} {d:.2}% of the {s} since your last look ({d}x{d}, frame {d}){s}", .{
            win_id,      if (st.changed) "changed" else "unchanged,",
            st.diff_pct, if (region != null) "region" else "window",
            st.w,        st.h,
            st.frames,   if (st.resized) ", window RESIZED" else "",
        });
        return res.finish();
    }
    const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse 1568, 0, 8192));
    const zoom: u32 = @intCast(std.math.clamp(argInt(args, "zoom") orelse 1, 1, 32));

    if (argInt(args, "burst")) |bn| if (bn > 1) {
        // Burst: up to N shots over a window of time, each gated on
        // a minimum pixel change vs the PREVIOUS shot — one call
        // instead of a screenshot-poll loop across a transition.
        const count: usize = @intCast(@min(bn, 8));
        const burst_ms: i64 = burstMs(argInt(args, "burst_ms"));
        const min_pct: f64 = argFloat(args, "min_change_pct") orelse 1.0;
        var pngs: std.ArrayList([]const u8) = .empty;
        defer {
            for (pngs.items) |p| app_state.allocator.free(p);
            pngs.deinit(arena);
        }
        var offsets: std.ArrayList(i64) = .empty;
        defer offsets.deinit(arena);
        const t0 = nowMs();
        var first: ?appdrive.App.Shot = null;
        while (nowMs() - t0 < burst_ms and pngs.items.len < count) {
            if (pngs.items.len > 0) {
                _ = app.pumpOnce(25);
                if (app.peekDiffPct(win_id, region) < min_pct) {
                    if (app.exited) break;
                    continue;
                }
            }
            const shot = app.screenshotPng(win_id, max_px, region, zoom) catch break;
            pngs.append(arena, shot.png) catch {
                app_state.allocator.free(shot.png);
                break;
            };
            offsets.append(arena, nowMs() - t0) catch break;
            if (first == null) first = shot;
            if (app.exited) break;
        }
        const fshot = first orelse
            return errRes(arena, .not_found, "no such window / no pixels yet (a region must lie inside the window)");
        var ob: std.ArrayList(u8) = .empty;
        defer ob.deinit(arena);
        for (offsets.items, 0..) |o, i| {
            var nb: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "{s}{d}ms", .{ if (i > 0) ", " else "", o }) catch break;
            try ob.appendSlice(arena, s);
        }
        if (tool == .get_app_state) try addAppSummary(&res, arena, app);
        try res.fact("window", win_id);
        try res.fact("burst", pngs.items.len);
        try res.fact("burst_offsets_ms", offsets.items);
        try res.fact("min_change_pct", min_pct);
        try addShotFacts(&res, arena, app, win_id, fshot);
        try res.textf("burst: {d} frame(s) captured at [{s}] (each >= {d:.1}% changed from the previous)", .{
            pngs.items.len, ob.items, min_pct,
        });
        return res.finishWithImages(pngs.items, null);
    };

    const shot = app.screenshotPng(win_id, max_px, region, zoom) catch
        return errRes(arena, .not_found, "no such window / no pixels yet (a region must lie inside the window)");
    defer app_state.allocator.free(shot.png);
    if (tool == .get_app_state) try addAppSummary(&res, arena, app);
    try res.fact("window", win_id);
    try addShotFacts(&res, arena, app, win_id, shot);
    // Durable evidence: `path` writes the SAME capture (same region
    // and zoom) to a file on this host at FULL resolution — the
    // inline image is downscaled to max_px, the file is not. Before
    // this, the only file a screenshot could leave behind was the
    // app's own (a game's F2 key).
    if (argStr(args, "path")) |path| {
        if (path.len == 0 or path[0] != '/')
            return errRes(arena, .invalid_args, "'path' must be an absolute path on the MCP server's host");
        const full = if (max_px == 0)
            shot
        else
            app.screenshotPng(win_id, 0, region, zoom) catch
                return errRes(arena, .not_found, "no such window / no pixels yet (a region must lie inside the window)");
        defer if (max_px != 0) app_state.allocator.free(full.png);
        atomicwrite.writeFile(path, full.png, 0o600) catch |err| return errRes(
            arena,
            .io_failed,
            try std.fmt.allocPrint(arena, "cannot write the screenshot to {s}: {s}", .{ path, @errorName(err) }),
        );
        try res.fact("path", path);
        try res.fact("file_bytes", full.png.len);
        try res.fact("file_w", full.img_w);
        try res.fact("file_h", full.img_h);
        try res.textf("saved {d}x{d} PNG ({d} KiB) to {s}", .{ full.img_w, full.img_h, full.png.len / 1024, path });
    }
    // inline:false skips the image block (a file-only capture costs
    // no image tokens); the facts still describe the frame.
    if (args == .object) if (args.object.get("inline")) |v| if (v == .bool and !v.bool) return res.finish();
    return res.finishWithImages(&.{shot.png}, null);
}

fn appDrag(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const win_id: u32 = @intCast(argInt(args, "window") orelse
        return errRes(arena, .invalid_args, "app_drag requires 'window'"));
    const x1 = argInt(args, "x1") orelse return errRes(arena, .invalid_args, "app_drag requires x1,y1,x2,y2");
    const y1 = argInt(args, "y1") orelse return errRes(arena, .invalid_args, "app_drag requires x1,y1,x2,y2");
    const x2 = argInt(args, "x2") orelse return errRes(arena, .invalid_args, "app_drag requires x1,y1,x2,y2");
    const y2 = argInt(args, "y2") orelse return errRes(arena, .invalid_args, "app_drag requires x1,y1,x2,y2");
    const button: u32 = @intCast(argInt(args, "button") orelse 1);
    var piw = PostInputWait.begin(args, app, win_id, argBool(args, "screenshot"));
    app.drag(
        win_id,
        @floatFromInt(x1),
        @floatFromInt(y1),
        @floatFromInt(x2),
        @floatFromInt(y2),
        button,
    ) catch return errRes(arena, .not_found, "drag failed (bad window?)");
    journalStep(app, "{{\"drag\":[{d},{d},{d},{d}],\"button\":{d},\"window\":{d}}}", .{ x1, y1, x2, y2, button, win_id });
    var res = Res.init(arena);
    try res.fact("x1", x1);
    try res.fact("y1", y1);
    try res.fact("x2", x2);
    try res.fact("y2", y2);
    try res.fact("button", button);
    const desc = try std.fmt.allocPrint(arena, "dragged ({d},{d}) -> ({d},{d}) button {d}", .{ x1, y1, x2, y2, button });
    return inputResult(arena, app, args, win_id, &piw, desc, &res);
}

fn appClipboardGet(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const timeout_ms: i64 = mcp.waitCap(argInt(args, "timeout_ms"), 3_000);
    const bytes = app.getClipboard(timeout_ms) catch |err| switch (err) {
        appdrive.Error.NoClipboard => return errRes(arena, .not_found, "the app has not announced a clipboard selection (copy something in it first)"),
        appdrive.Error.Timeout => return errRes(arena, .timeout, "app did not deliver clipboard data in time"),
        else => return appErr(arena, "clipboard fetch failed"),
    };
    defer app_state.allocator.free(bytes);
    const copy = try arena.dupe(u8, bytes);
    var res = Res.init(arena);
    try res.fact("bytes", copy.len);
    try res.fact("text", copy);
    try res.textf("clipboard: {d} byte(s)", .{copy.len});
    if (copy.len > 0) try res.textf("--- clipboard ---\n{s}", .{copy});
    return res.finish();
}

fn appClipboardSet(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const text = argStr(args, "text") orelse
        return errRes(arena, .invalid_args, "app_clipboard_set requires 'text'");
    app.setClipboard(text) catch return appErr(arena, "clipboard set failed");
    const pasted = argBool(args, "paste");
    if (pasted) {
        const win: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
        app.pressKey(win, "ctrl+v") catch return errRes(arena, .not_found, "paste keystroke failed (no window?)");
        _ = app.waitIdle(200, 2_000);
    }
    var res = Res.init(arena);
    try res.fact("bytes", text.len);
    try res.fact("pasted", pasted);
    try res.textf("clipboard set ({d} byte(s)){s} — the app sees this as the host clipboard", .{
        text.len, if (pasted) ", pasted with ctrl+v" else "",
    });
    return res.finish();
}

fn appClick(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const button: u32 = @intCast(argInt(args, "button") orelse 1);
    const win_id: u32 = @intCast(argInt(args, "window") orelse
        return errRes(arena, .invalid_args, "app_click requires 'window' and x/y. To target a widget by name/role use app_perform_action (coordinate-free)."));
    const x = argInt(args, "x") orelse return errRes(arena, .invalid_args, "app_click requires 'x'");
    const y = argInt(args, "y") orelse return errRes(arena, .invalid_args, "app_click requires 'y'");
    const hold_ms: i64 = std.math.clamp(argInt(args, "hold_ms") orelse Tuning.hold_ms.value, 0, 10_000);
    const count: u32 = @intCast(std.math.clamp(argInt(args, "count") orelse 1, 1, 3));
    const retries: i64 = std.math.clamp(argInt(args, "retry") orelse Tuning.click_retry.value, 0, 5);
    // Crosshair-marked post-click screenshot is the DEFAULT: it
    // answers "did the click land where I aimed, and did it do
    // anything" in one image. mark:false (without screenshot)
    // restores the plain text reply.
    const want_mark = if (args == .object and args.object.get("mark") != null)
        argBool(args, "mark")
    else
        true;
    const want_shot = want_mark or argBool(args, "screenshot");
    var attempts: i64 = 0;
    var note: []const u8 = "";
    var repainted = false;
    var stopped: ?AppStop = null;
    var frame_at_input: ?u64 = null;
    while (true) {
        var piw = PostInputWait.begin(args, app, win_id, want_shot);
        // Hover-armed widgets (tooltips, menus that open on dwell)
        // act on a position they saw on an EARLIER frame. The click
        // itself always delivers enter+motion before the button, so
        // this is only needed when the app needs a frame in between.
        if (argBool(args, "move_first")) {
            _ = app.moveMouse(win_id, @floatFromInt(x), @floatFromInt(y)) catch null;
            _ = app.waitIdle(60, 400);
        }
        app.clickEx(win_id, @floatFromInt(x), @floatFromInt(y), button, hold_ms, count) catch {
            if (probeAppStop(app, 1_000)) |stop| {
                var res = Res.init(arena);
                try clickFacts(&res, win_id, x, y, button, count, hold_ms, 1, false);
                try res.textf("clicked ({d},{d}) button {d} - {s}", .{ x, y, button, try appStopText(arena, stop, "the click") });
                try addAppSummary(&res, arena, app);
                return res.finish();
            }
            return errRes(arena, .not_found, "click failed (bad window?)");
        };
        attempts += 1;
        note = try piw.finish(arena, app, win_id);
        repainted = piw.repainted;
        stopped = piw.stop;
        // The freshness handle is the frame BEFORE the first press:
        // a min_frame taken from a later retry would accept pixels
        // the earlier attempts had already produced.
        if (frame_at_input == null) frame_at_input = piw.frame_at_input;
        // Auto-retry only on a WAITED no-repaint verdict — a click
        // that visibly landed must never get a second press, and
        // without a wait there is no verdict to retry on.
        if (repainted or !piw.wait or attempts > retries or stopped != null) break;
        // Nothing to retry against: the window had already stopped
        // painting before the first press, so more presses only
        // burn the timeout and bury the liveness verdict.
        if (piw.quietBeforeMs() >= APP_QUIET_HANG_MS) break;
    }
    journalStep(app, "{{\"click\":[{d},{d}],\"button\":{d},\"window\":{d},\"hold_ms\":{d},\"count\":{d}}}", .{ x, y, button, win_id, hold_ms, count });
    var res = Res.init(arena);
    try clickFacts(&res, win_id, x, y, button, count, hold_ms, attempts, repainted);
    try res.fact("frame_at_input", frame_at_input orelse 0);
    try res.fact("frame_now", app.frameCount(win_id));
    const qual: []const u8 = if (count > 1)
        try std.fmt.allocPrint(arena, " x{d} ({s}, held {d}ms each)", .{ count, if (count == 2) "double-click" else "triple-click", hold_ms })
    else if (hold_ms > 0)
        try std.fmt.allocPrint(arena, " (held {d}ms)", .{hold_ms})
    else
        "";
    if (stopped != null) {
        // Don't attempt the screenshot — it fails as "no pixels
        // yet?" and masks the crash the click just triggered.
        try res.textf("clicked ({d},{d}) button {d}{s}{s}", .{ x, y, button, qual, note });
        try addAppSummary(&res, arena, app);
        return res.finish();
    }
    try res.textf("clicked ({d},{d}) button {d}{s}{s}", .{ x, y, button, qual, note });
    if (attempts > 1)
        try res.textf("auto-retried: {d} attempts, earlier clicks produced no qualifying repaint", .{attempts});
    try res.textf(
        "window {d} frame {d} at input, {d} now — pass min_frame:{d} to screenshot_app for a provably post-click capture",
        .{ win_id, frame_at_input orelse 0, app.frameCount(win_id), frame_at_input orelse 0 },
    );
    // Built once, after the retries: the log delta consumes the
    // lines it reports, so computing it per attempt would hand the
    // caller only whatever the LAST press happened to print.
    const delta = logDeltaNote(arena, app, args);
    if (delta.len > 0) try res.text(std.mem.trimStart(u8, delta, "\n"));
    const nudge = macroNudge(arena, app);
    if (nudge.len > 0) try res.text(std.mem.trimStart(u8, nudge, "\n"));
    if (want_shot) {
        // Post-click frame, optionally with the click point drawn
        // in — one call shows where the click landed AND what the
        // UI did with it. The frame is captured only after the
        // window commits something NEWER than the click (bounded),
        // and the caption says explicitly when it never did.
        const annot = [_]marks_mod.Mark{.{ .x = @floatFromInt(x), .y = @floatFromInt(y) }};
        const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse 1568, 0, 8192));
        const shot = app.screenshotPngMarked(win_id, max_px, null, 1, if (want_mark) &annot else &.{}) catch {
            if (probeAppStop(app, 1_000)) |stop| {
                try res.textf("{s}", .{try appStopText(arena, stop, "the post-click capture")});
                try addAppSummary(&res, arena, app);
                return res.finish();
            }
            try res.fact("screenshot_failed", true);
            try res.text("the post-click screenshot failed (no pixels yet?)");
            return res.finish();
        };
        defer app_state.allocator.free(shot.png);
        if (want_mark)
            try res.text("the red crosshair marks the click point on the post-click frame. Coordinates are delivered to the app verbatim; a pointer-LOCKED app tracks its own cursor from relative deltas, so its internal cursor can differ (calibrate with app_mouse_move dx/dy).");
        try addShotFacts(&res, arena, app, win_id, shot);
        return res.finishWithImages(&.{shot.png}, &.{"click"});
    }
    return res.finish();
}

fn appActions(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const actions_v = (if (args == .object) args.object.get("actions") else null) orelse
        return errRes(arena, .invalid_args, "app_actions requires 'actions' (an array of step objects)");
    if (actions_v != .array) return errRes(arena, .invalid_args, "'actions' must be an array of step objects");
    const steps = actions_v.array.items;
    if (steps.len == 0) return errRes(arena, .invalid_args, "'actions' is empty");
    if (steps.len > 32) return errRes(arena, .invalid_args, "too many steps (max 32)");
    const win_arg: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
    return runActionSteps(arena, app, steps, win_arg, true, null);
}

fn appMouseMove(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const win: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
    const has_abs = argFloat(args, "x") != null and argFloat(args, "y") != null;
    const has_rel = argFloat(args, "dx") != null or argFloat(args, "dy") != null;
    if (has_abs and has_rel)
        return errRes(arena, .invalid_args, "pass x/y (absolute) OR dx/dy (relative), not both");
    var res = Res.init(arena);
    var pos: appdrive.App.PtrPos = undefined;
    if (has_abs) {
        try res.fact("mode", "absolute");
        pos = app.moveMouse(win, argFloat(args, "x").?, argFloat(args, "y").?) catch
            return errRes(arena, .not_found, "move failed (bad window?)");
    } else if (has_rel) {
        try res.fact("mode", "relative");
        pos = app.moveMouseRel(win, argFloat(args, "dx") orelse 0, argFloat(args, "dy") orelse 0) catch
            return errRes(arena, .not_found, "move failed (bad window?)");
    } else {
        try res.fact("mode", "query");
        pos = app.pointerPos() orelse {
            try res.fact("tracked", false);
            try res.text("no pointer position tracked yet (nothing moved/clicked in this app)");
            return res.finish();
        };
    }
    if (has_abs or has_rel) _ = app.waitIdle(100, 1_000);
    if (has_abs) {
        journalStep(app, "{{\"move\":[{d:.0},{d:.0}]}}", .{ pos.x, pos.y });
    } else if (has_rel) {
        journalStep(app, "{{\"move_rel\":[{d:.0},{d:.0}]}}", .{ argFloat(args, "dx") orelse 0, argFloat(args, "dy") orelse 0 });
    }
    try res.fact("tracked", true);
    try res.fact("window", pos.win);
    try res.fact("x", pos.x);
    try res.fact("y", pos.y);
    try res.textf("pointer at ({d:.0},{d:.0}) in window {d}", .{ pos.x, pos.y, pos.win });
    return res.finish();
}

fn appPerformAction(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const elem_id = argStr(args, "element") orelse
        return errRes(arena, .invalid_args, "app_perform_action requires 'element' (an id from app_a11y_tree)");
    const index: i64 = argInt(args, "index") orelse 0;
    const payload = try std.fmt.allocPrint(arena, "{{\"op\":\"action\",\"id\":{f},\"index\":{d}}}", .{
        std.json.fmt(elem_id, .{}),
        index,
    });
    const reply = app.a11yOp(payload, mcp.waitCap(argInt(args, "timeout_ms"), 5_000)) catch
        return errRes(arena, .unavailable, "a11y action failed (daemon unreachable?)");
    defer app_state.allocator.free(reply);
    if (std.mem.indexOf(u8, reply, "\"ok\"") == null)
        return errRes(arena, .not_found, try std.fmt.allocPrint(arena, "the accessibility layer refused the action: {s}", .{reply}));
    _ = app.waitIdle(200, 2_000);
    var res = Res.init(arena);
    try res.fact("element", elem_id);
    try res.fact("index", index);
    try res.fact("performed", true);
    try res.textf("performed action {d} on {s}", .{ index, elem_id });
    return res.finish();
}

fn appSetValue(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const elem_id = argStr(args, "element") orelse
        return errRes(arena, .invalid_args, "app_set_value requires 'element' (an id from app_a11y_tree)");
    var payload: []const u8 = undefined;
    var kind: []const u8 = "text";
    if (argStr(args, "text")) |text| {
        payload = try std.fmt.allocPrint(arena, "{{\"op\":\"set_text\",\"id\":{f},\"text\":{f}}}", .{
            std.json.fmt(elem_id, .{}),
            std.json.fmt(text, .{}),
        });
    } else if (args == .object and args.object.get("value") != null) {
        kind = "value";
        const v = args.object.get("value").?;
        const num: f64 = switch (v) {
            .integer => |iv| @floatFromInt(iv),
            .float => |fl| fl,
            else => return errRes(arena, .invalid_args, "'value' must be a number"),
        };
        payload = try std.fmt.allocPrint(arena, "{{\"op\":\"set_value\",\"id\":{f},\"value\":{d}}}", .{
            std.json.fmt(elem_id, .{}),
            num,
        });
    } else return errRes(arena, .invalid_args, "app_set_value requires 'text' (text fields) or 'value' (sliders/spinners)");
    const reply = app.a11yOp(payload, mcp.waitCap(argInt(args, "timeout_ms"), 5_000)) catch
        return errRes(arena, .unavailable, "a11y set failed (daemon unreachable?)");
    defer app_state.allocator.free(reply);
    if (std.mem.indexOf(u8, reply, "\"ok\"") == null)
        return errRes(arena, .not_found, try std.fmt.allocPrint(arena, "the accessibility layer refused the write: {s}", .{reply}));
    _ = app.waitIdle(200, 2_000);
    var res = Res.init(arena);
    try res.fact("element", elem_id);
    try res.fact("kind", kind);
    try res.fact("set", true);
    try res.textf("set the {s} of {s}", .{ kind, elem_id });
    return res.finish();
}

fn appWaitForElement(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const role: ?i64 = argInt(args, "role");
    const name_sub = argStr(args, "name");
    if (role == null and name_sub == null)
        return errRes(arena, .invalid_args, "app_wait_for_element requires 'role' and/or 'name'");
    const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 10_000, 0, mcp.WAIT_CAP_MS);
    const deadline = nowMs() + timeout_ms;
    while (true) {
        switch (a11yFetch(arena, app, 5_000)) {
            .tree => |t| if (a11yFindMatch(t, role, name_sub)) |node| {
                var res = Res.init(arena);
                try res.fact("found", true);
                try res.raw("element", try a11yNodeSummary(arena, node));
                try res.text(try a11yNodeLine(arena, node));
                return res.finish();
            },
            .err => {}, // tree not up yet — keep polling
        }
        app.drain();
        if (app.exited)
            return appStateErr(arena, app, .conflict, "the app exited while waiting for an element");
        if (Watchdog.fired.load(.acquire))
            return errRes(arena, .timeout, "element wait aborted by the MCP hard timeout");
        if (nowMs() >= deadline) {
            // Distinguish "not there yet" from "this app has no
            // accessible tree at all" — the second never resolves,
            // so waiting again is pure waste.
            if (app.a11yTree(2_000)) |raw| {
                defer app_state.allocator.free(raw);
                const copy = try arena.dupe(u8, raw);
                if (a11yTreeIsBare(arena, copy))
                    return errRes(arena, .unavailable, "this app publishes NO accessibility tree at all (only the desktop registry is on the bus), so no element will ever appear here — raw SDL/OpenGL/framebuffer apps and games have no toolkit to publish one. Drive it with screenshot_app + app_click, or app_wait_image with a saved template.");
            } else |_| {}
            return errRes(arena, .timeout, "element did not appear before the timeout");
        }
        var ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 300 * 1000 * 1000 };
        _ = c.nanosleep(&ts, null);
    }
}

fn appType(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const text = argStr(args, "text") orelse return errRes(arena, .invalid_args, "app_type requires 'text'");
    const win: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
    const wait_win: u32 = win orelse firstToplevelId(app);
    var piw = PostInputWait.begin(args, app, wait_win, argBool(args, "screenshot"));
    app.typeText(win, text) catch |err| switch (err) {
        appdrive.Error.BadKey => return errRes(arena, .invalid_args, "text contains a character outside the us keymap"),
        else => return errRes(arena, .not_found, "type failed (no window?)"),
    };
    journalStepJson(app, arena, "type", text, "");
    var res = Res.init(arena);
    try res.fact("chars", text.len);
    const desc = try std.fmt.allocPrint(arena, "typed {d} chars", .{text.len});
    return inputResult(arena, app, args, wait_win, &piw, desc, &res);
}

fn appKey(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const keys = argStr(args, "keys") orelse return errRes(arena, .invalid_args, "app_key requires 'keys'");
    const win: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
    const wait_win: u32 = win orelse firstToplevelId(app);
    const hold_ms: i64 = std.math.clamp(argInt(args, "hold_ms") orelse 0, 0, 10_000);
    var piw = PostInputWait.begin(args, app, wait_win, argBool(args, "screenshot"));
    var it = std.mem.tokenizeScalar(u8, keys, ' ');
    while (it.next()) |spec| {
        app.pressKeyHold(win, spec, hold_ms) catch |err| switch (err) {
            appdrive.Error.BadKey => return errRes(arena, .invalid_args, "unknown key chord"),
            else => return errRes(arena, .not_found, "key press failed (no window?)"),
        };
    }
    const extra: []const u8 = if (hold_ms > 0)
        try std.fmt.allocPrint(arena, ",\"hold_ms\":{d}", .{hold_ms})
    else
        "";
    journalStepJson(app, arena, "key", keys, extra);
    var res = Res.init(arena);
    try res.fact("keys", keys);
    try res.fact("hold_ms", hold_ms);
    const desc = if (hold_ms > 0)
        try std.fmt.allocPrint(arena, "pressed (each held {d}ms): {s}", .{ hold_ms, keys })
    else
        try std.fmt.allocPrint(arena, "pressed: {s}", .{keys});
    return inputResult(arena, app, args, wait_win, &piw, desc, &res);
}

fn appScroll(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const win_id: u32 = @intCast(argInt(args, "window") orelse
        return errRes(arena, .invalid_args, "app_scroll requires 'window'"));
    const x = argInt(args, "x") orelse 10;
    const y = argInt(args, "y") orelse 10;
    const dx = argInt(args, "dx") orelse 0;
    const dy = argInt(args, "dy") orelse 0;
    var piw = PostInputWait.begin(args, app, win_id, argBool(args, "screenshot"));
    app.scroll(win_id, @floatFromInt(x), @floatFromInt(y), @floatFromInt(dx), @floatFromInt(dy)) catch
        return errRes(arena, .not_found, "scroll failed (bad window?)");
    journalStep(app, "{{\"scroll\":[{d},{d}],\"at\":[{d},{d}],\"window\":{d}}}", .{ dx, dy, x, y, win_id });
    var res = Res.init(arena);
    try res.fact("dx", dx);
    try res.fact("dy", dy);
    try res.fact("x", x);
    try res.fact("y", y);
    const desc = try std.fmt.allocPrint(arena, "scrolled ({d},{d}) at ({d},{d})", .{ dx, dy, x, y });
    return inputResult(arena, app, args, win_id, &piw, desc, &res);
}

fn appResize(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const win_id: u32 = @intCast(argInt(args, "window") orelse
        return errRes(arena, .invalid_args, "app_resize requires 'window'"));
    const w = argInt(args, "w") orelse return errRes(arena, .invalid_args, "app_resize requires 'w'");
    const h = argInt(args, "h") orelse return errRes(arena, .invalid_args, "app_resize requires 'h'");
    app.resizeWindow(win_id, @intCast(w), @intCast(h)) catch
        return errRes(arena, .not_found, "resize failed (bad window?)");
    _ = app.waitIdle(300, 3_000);
    var res = Res.init(arena);
    try res.fact("window", win_id);
    try res.fact("w", w);
    try res.fact("h", h);
    try res.textf("asked window {d} to resize to {d}x{d} (the app decides)", .{ win_id, w, h });
    return res.finish();
}

fn appWait(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const quiet_ms: i64 = argInt(args, "quiet_ms") orelse 400;
    const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 10_000, 0, mcp.WAIT_CAP_MS);
    const was_exited = app.exited;
    var wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
    const t_start = nowMs();
    // No window yet is not an error, it is the thing to wait for:
    // before this, app_wait errored (with change_pct/min_frames) or
    // returned "settled, 0 frames" at once (idle mode) on a
    // slow-starting app, and nothing but launch_app's own wait_ms
    // could block on the first window.
    var window_appeared = false;
    var window_wait_ms: i64 = 0;
    if (wid == 0 and !app.exited) {
        window_appeared = app.waitFirstWindow(timeout_ms);
        window_wait_ms = nowMs() - t_start;
        wid = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
        if (!app.exited and window_appeared and wid != 0) {
            // fall through: the requested wait runs on it below
        } else {
            var res = Res.init(arena);
            try res.fact("window", 0);
            try res.fact("mode", "first_window");
            try res.fact("settled", false);
            try res.fact("window_appeared", window_appeared);
            try res.fact("frames_before", 0);
            try res.fact("frames_committed", 0);
            try res.fact("frame_now", 0);
            try res.fact("waited_ms", window_wait_ms);
            if (app.exited)
                try res.textf("app EXITED before rendering a window (status {d}{s}) — backtrace/report in app_log", .{ app.exit_status, try exitSuffix(arena, app.exit_status) })
            else if (window_appeared)
                try res.textf("a window rendered, but not the requested window id {d}", .{argInt(args, "window") orelse 0})
            else
                try res.textf("NO WINDOW rendered within {d}ms: the app is running but has not committed a toplevel frame yet (still starting, or it may never open one — check app_log / app_output). Call app_wait again to keep waiting", .{timeout_ms});
            try addAppSummary(&res, arena, app);
            return res.finish();
        }
    }
    const remaining_ms: i64 = @max(timeout_ms - window_wait_ms, 0);
    // Every verdict carries the frame delta actually observed. Both
    // failure modes reported from the field were unreadable without
    // it: a still splash screen "settles" instantly (0 frames, no
    // sign that the app is merely showing a static image), and an
    // app busy inside its draw path reads as "settled (no new
    // frames)" identically to a wedged one.
    const frames_before = app.frameCount(wid);
    const t0 = nowMs();
    var res = Res.init(arena);
    var outcome: []const u8 = undefined;
    var mode: []const u8 = "idle";
    var settled_ok = false;
    if (argInt(args, "min_frames")) |mf| {
        // Liveness by COMMIT COUNT: the only wait that means
        // anything on an app which never visually quiesces, and the
        // honest opposite of settling on a static frame.
        mode = "min_frames";
        const want: u64 = @intCast(@max(mf, 1));
        if (app.waitFrameAfter(wid, frames_before + want - 1, remaining_ms)) {
            settled_ok = true;
            outcome = try std.fmt.allocPrint(arena, "committed {d} new frame(s) within {d}ms", .{ want, nowMs() - t0 });
        } else {
            // Falling short is USUALLY arithmetic, not a fault: an
            // app at 12fps cannot deliver 1400 frames in 115s no
            // matter how healthy it is. Reporting that as "it is
            // not painting" was a false alarm frequent enough to
            // train callers to ignore the message — which is the
            // worst possible reflex, because the same message is
            // how a real freeze announces itself. Only ZERO frames
            // is a liveness claim now.
            outcome = try shortFramesVerdict(arena, wid, app.frameCount(wid) - frames_before, want, nowMs() - t0, remaining_ms);
        }
    } else if (argFloat(args, "change_pct")) |pct| {
        // Visual quiescence: frames may keep committing (a game
        // always renders) — settle when they stop CHANGING much.
        // A region scopes the percentage to that rect.
        mode = "visual_settle";
        settled_ok = app.waitVisualSettle(wid, quiet_ms, remaining_ms, pct, regionFrom(args));
        outcome = if (settled_ok)
            try std.fmt.allocPrint(arena, "settled (frames changed <{d:.1}% of pixels for {d}ms)", .{ pct, quiet_ms })
        else
            // NOT an error: for a game or a video this is the
            // expected steady state, so it must not read as failure.
            try std.fmt.allocPrint(arena, "ALIVE AND ANIMATING, never quiesced: frames kept changing >{d:.1}% of pixels for the whole {d}ms. This is the normal state for a game/video and is not a failure — to synchronise on something real, wait on the app's own log (app_wait_log) or on a frame count (min_frames)", .{ pct, remaining_ms });
    } else {
        settled_ok = app.waitIdle(quiet_ms, remaining_ms);
        outcome = if (settled_ok)
            try std.fmt.allocPrint(arena, "settled (no new frames for {d}ms). NOTE: no commits is not the same as no work — an app busy inside its draw path, or one showing a static splash, settles here instantly; use min_frames for liveness", .{quiet_ms})
        else
            "ALIVE AND RENDERING, never quiesced: new frames kept arriving for the whole timeout. This is normal for a continuously-animating app, not a failure — pass change_pct (e.g. 2) for VISUAL quiescence, min_frames for liveness, or app_wait_log to synchronise on an actual event";
    }
    const delta = app.frameCount(wid) - frames_before;
    // The settle waits return "settled" on exit — say what really
    // happened, with the signal, instead of a bogus quiet verdict.
    if (app.exited) {
        settled_ok = false;
        outcome = if (was_exited)
            "the app has already exited (details below)"
        else
            try std.fmt.allocPrint(arena, "app EXITED during the wait (status {d}{s}) — backtrace/report in app_log", .{ app.exit_status, try exitSuffix(arena, app.exit_status) });
    }
    try res.fact("window", wid);
    try res.fact("mode", mode);
    try res.fact("settled", settled_ok);
    try res.fact("frames_before", frames_before);
    try res.fact("frames_committed", delta);
    try res.fact("frame_now", app.frameCount(wid));
    try res.fact("waited_ms", nowMs() - t_start);
    try res.fact("window_appeared", window_appeared);
    if (window_appeared) try res.textf("window {d} rendered after {d}ms; the {s} wait then ran with the remaining {d}ms", .{ wid, window_wait_ms, mode, remaining_ms });
    try res.text(outcome);
    try res.textf("observed: window {d} committed {d} frame(s) during the {d}ms wait (now at frame {d})", .{
        wid, delta, nowMs() - t0, app.frameCount(wid),
    });
    try addAppSummary(&res, arena, app);
    return res.finish();
}

fn appA11yTree(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 5_000, 0, mcp.WAIT_CAP_MS);
    const tree = app.a11yTree(timeout_ms) catch |err| switch (err) {
        appdrive.Error.Timeout => return errRes(arena, .timeout, "timed out reading the accessibility tree"),
        else => return errRes(arena, .unavailable, "accessibility read failed"),
    };
    defer app_state.allocator.free(tree);
    const copy = try arena.dupe(u8, tree);
    var res = Res.init(arena);
    const bare = a11yTreeIsBare(arena, copy);
    try res.fact("bare", bare);
    try res.raw("tree", copy);
    // "The app published nothing" and "you asked too early" look
    // identical in the raw JSON — both are a registry root with a
    // couple of desktop services under it. Say which one it is:
    // steering the caller toward the coordinate-free path when that
    // path does not exist for this app costs whole turns.
    if (bare) {
        try res.text("NO ACCESSIBLE TREE: this app publishes no widgets on the a11y bus — the tree holds only the desktop registry and background services, with nothing below them. Raw SDL / OpenGL / framebuffer apps and games have no toolkit to publish one, so this will not appear later and waiting longer will not help. app_perform_action and app_set_value cannot drive this app; use screenshot_app + app_click coordinates instead, and app_template_save / app_find_image / app_wait_image to locate elements without hardcoding pixels. (If the app IS a GTK/Qt program, it may still be starting: retry once after app_wait.)");
        return res.finish();
    }
    // An indented outline, not the raw JSON: the ids and roles a
    // caller acts on, one node per line. The full tree stays in
    // structuredContent for anything that wants every attribute.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, copy, .{}) catch
        return appErr(arena, "malformed accessibility reply");
    try res.text("AT-SPI tree. Each node's id drives app_perform_action (press/activate/toggle) or app_set_value (write a text field/slider) WITHOUT coordinates; that is the reliable path. Roles (common): 8 checkbox, 14 dialog/frame, 18 filler, 25 label, 28 menu, 29 menubar, 30 menuitem, 34 canvas, 35 page-tab, 37 panel, 42 push-button, 43 radiobutton, 44 root/desktop, 46 scrollbar, 60 table, 62 text, 71 toolbar, 74 tree, 75 application, 84 entry. rect is unreliable for headless apps (no screen position), so prefer perform_action/set_value over pixel clicks.");
    var ow: std.Io.Writer.Allocating = .init(arena);
    try ow.writer.writeAll("--- tree ---");
    if (parsed == .object) {
        if (parsed.object.get("tree")) |root| try a11yOutline(arena, &ow.writer, root, 0);
    }
    try res.text(ow.written());
    return res.finish();
}

fn appRecordStart(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    var win_id: u32 = 0;
    if (argInt(args, "window")) |v| {
        win_id = @intCast(v);
    } else {
        win_id = firstToplevelId(app);
    }
    if (win_id == 0) return errRes(arena, .not_found, "no rendered window yet (try app_wait first)");
    // WebM/VP9 is the default (smaller, higher quality); format:"gif"
    // for the animated GIF.
    const want_gif = if (argStr(args, "format")) |fmt| std.mem.eql(u8, fmt, "gif") else false;
    const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse (if (want_gif) @as(i64, 800) else 1280), 0, 4096));
    const fps: u32 = @intCast(std.math.clamp(argInt(args, "fps") orelse 0, 0, 60));
    app.recordStart(win_id, max_px, !want_gif, fps) catch return errRes(arena, .not_found, "no such window");
    var res = Res.init(arena);
    try res.fact("window", win_id);
    try res.fact("format", if (want_gif) "gif" else "webm");
    try res.fact("max_px", max_px);
    try res.fact("fps", fps);
    try res.fact("recording", true);
    try res.text("recording — frames are captured while other app tools run (click/type/wait); call app_record_stop to finish");
    return res.finish();
}

fn appRecordStop(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const result = app.recordStop() catch |err| switch (err) {
        appdrive.Error.NotRecording => return errRes(arena, .conflict, "no recording in progress (app_record_start first)"),
        else => return errRes(arena, .conflict, "recording produced no frames"),
    };
    defer app_state.allocator.free(result.data);
    const ext = if (result.webm) "webm" else "gif";
    const path = argStr(args, "path") orelse
        try std.fmt.allocPrint(arena, "/tmp/sketerm-rec-{d}-{d}.{s}", .{ c.getpid(), @divTrunc(wallMs(), 1000), ext });
    saveRecording(path, result.data) catch |err| return errRes(
        arena,
        .io_failed,
        try std.fmt.allocPrint(arena, "cannot save the recording: {s}", .{@errorName(err)}),
    );
    var res = Res.init(arena);
    try res.fact("path", path);
    try res.fact("format", ext);
    try res.fact("frames", result.frames);
    try res.fact("bytes", result.data.len);
    try res.textf("saved {d} frames ({d} KiB {s}) to {s}", .{ result.frames, result.data.len / 1024, ext, path });
    return res.finish();
}

fn appReadText(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
    if (wid == 0) return errRes(arena, .not_found, "no rendered window yet (try app_wait first)");
    const region = regionFrom(args);
    const scale: u32 = @intCast(std.math.clamp(argInt(args, "scale") orelse 0, 0, 8));
    const psm: i32 = @intCast(std.math.clamp(argInt(args, "psm") orelse 6, 0, 13));
    const lang = argStr(args, "lang") orelse "eng";
    switch (try ocrWindow(arena, app, wid, region, scale, psm, lang)) {
        .err => |e| return ocrErr(arena, e),
        .out => |o| {
            var res = Res.init(arena);
            try res.fact("window", wid);
            try res.fact("ocr_scale", o.scale);
            try res.fact("words", o.words.len);
            try res.fact("text", o.text);
            try res.raw("boxes", try wordBoxesJson(arena, o));
            try res.textf("OCR of window {d} at scale {d}: {d} word box(es)", .{ wid, o.scale, o.words.len });
            try res.textf("--- ocr text ---\n{s}", .{o.text});
            return res.finish();
        },
    }
}

fn appWaitText(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const query = argStr(args, "text") orelse return errRes(arena, .invalid_args, "app_wait_text requires 'text'");
    const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
    if (wid == 0) return errRes(arena, .not_found, "no rendered window yet (try app_wait first)");
    const region = regionFrom(args);
    const scale: u32 = @intCast(std.math.clamp(argInt(args, "scale") orelse 0, 0, 8));
    const psm: i32 = @intCast(std.math.clamp(argInt(args, "psm") orelse 6, 0, 13));
    const lang = argStr(args, "lang") orelse "eng";
    const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 15_000, 0, mcp.WAIT_CAP_MS);
    const do_click = argBool(args, "click");
    const deadline = nowMs() + timeout_ms;
    var seen: ?OcrOut = null;
    // One arena per OCR pass, released between polls. Each pass
    // charges its caller for the recognized text and word boxes and,
    // for small fonts, an upscaled copy of the capture (`ocrWindow`
    // frees the capture itself); charged to the call arena a long
    // wait grew linearly with the poll count and freed nothing until
    // the tool returned. The timeout message keeps the last read in a
    // fixed buffer for the same reason.
    var ocr_scratch = std.heap.ArenaAllocator.init(app_state.allocator);
    defer ocr_scratch.deinit();
    var last_tail: [500]u8 = undefined;
    var last_tail_len: usize = 0;
    while (true) {
        _ = ocr_scratch.reset(.free_all);
        switch (try ocrWindow(ocr_scratch.allocator(), app, wid, region, scale, psm, lang)) {
            .out => |o| {
                const tail = if (o.text.len > last_tail.len) o.text[o.text.len - last_tail.len ..] else o.text;
                @memcpy(last_tail[0..tail.len], tail);
                last_tail_len = tail.len;
                if (std.ascii.indexOfIgnoreCase(o.text, query) != null) seen = try dupeOcrOut(arena, o);
            },
            .err => |e| {
                if (!std.mem.startsWith(u8, e, "no rendered")) return ocrErr(arena, e);
            },
        }
        if (seen != null or app.exited or nowMs() >= deadline) break;
        _ = app.waitIdle(std.math.maxInt(i32), 300); // pumped sleep between OCR passes
    }
    const o = seen orelse {
        return errRes(arena, .timeout, try std.fmt.allocPrint(
            arena,
            "text \"{s}\" not visible before timeout; last OCR read:\n--- last ocr read ---\n{s}",
            .{ query, last_tail[0..last_tail_len] },
        ));
    };
    var res = Res.init(arena);
    try res.fact("found", true);
    try res.fact("window", wid);
    try res.fact("text", query);
    if (findWordRun(o.words, query)) |box| {
        try res.raw("match", try std.fmt.allocPrint(
            arena,
            "{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"cx\":{d},\"cy\":{d}}}",
            .{ box.x, box.y, box.w, box.h, box.x + box.w / 2, box.y + box.h / 2 },
        ));
        var clicked = false;
        if (do_click) {
            clickTuned(app, wid, @floatFromInt(box.x + box.w / 2), @floatFromInt(box.y + box.h / 2), 1) catch
                return errRes(arena, .not_found, "text found but the click failed (bad window?)");
            _ = app.waitIdle(100, 1_000);
            // Journal as a replayable wait_text step (the macro
            // form of "wait for this label, then click it").
            {
                var jw: std.Io.Writer.Allocating = .init(arena);
                const jwr = &jw.writer;
                jwr.writeAll("{\"wait_text\":{\"text\":") catch return error.OutOfMemory;
                std.json.Stringify.value(query, .{}, jwr) catch return error.OutOfMemory;
                jwr.writeAll(",\"click\":true}}") catch return error.OutOfMemory;
                Journal.record(appIdOf(app), jw.written());
            }
            clicked = true;
        }
        try res.fact("clicked", clicked);
        try res.textf("\"{s}\" is visible in window {d} at ({d},{d}) {d}x{d}, centre ({d},{d}){s}", .{
            query, wid, box.x, box.y, box.w, box.h, box.x + box.w / 2, box.y + box.h / 2,
            if (clicked) " — clicked it" else "",
        });
    } else {
        try res.fact("clicked", false);
        try res.textf("\"{s}\" is visible in window {d}{s}", .{
            query,                                                               wid,
            if (do_click) ", but OCR gave no clickable word box for it" else "",
        });
    }
    return res.finish();
}

fn appFindImage(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const needle = switch (try resolveNeedle(arena, args)) {
        .needle => |nd| nd,
        .err => |e| return errRes(arena, .invalid_args, e),
    };
    const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
    if (wid == 0) return errRes(arena, .not_found, "no rendered window yet (try app_wait first)");
    const min_score = argFloat(args, "min_score") orelse 0.9;
    const max_matches: usize = @intCast(std.math.clamp(argInt(args, "max_matches") orelse 8, 1, 32));
    switch (try findInWindow(arena, app, wid, regionFrom(args), needle, min_score, max_matches)) {
        .err => |e| return errRes(arena, .not_found, e),
        .matches => |ms| {
            var res = Res.init(arena);
            try res.fact("template", needle.name);
            try res.fact("template_w", needle.w);
            try res.fact("template_h", needle.h);
            try res.fact("window", wid);
            try res.fact("count", ms.len);
            try res.textf("template \"{s}\" ({d}x{d}): {d} match(es) in window {d}", .{
                needle.name, needle.w, needle.h, ms.len, wid,
            });
            var aw: std.Io.Writer.Allocating = .init(arena);
            const w = &aw.writer;
            try w.writeAll("[");
            for (ms, 0..) |m, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"x\":{d},\"y\":{d},\"cx\":{d},\"cy\":{d},\"score\":{d:.3}}}", .{ m.x, m.y, m.cx, m.cy, m.score });
                try res.textf("({d},{d}) centre ({d},{d}) score {d:.3}", .{ m.x, m.y, m.cx, m.cy, m.score });
            }
            try w.writeAll("]");
            try res.raw("matches", aw.written());
            return res.finish();
        },
    }
}

fn appWaitImage(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const needle = switch (try resolveNeedle(arena, args)) {
        .needle => |nd| nd,
        .err => |e| return errRes(arena, .invalid_args, e),
    };
    const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
    if (wid == 0) return errRes(arena, .not_found, "no rendered window yet (try app_wait first)");
    const region = regionFrom(args);
    const min_score = argFloat(args, "min_score") orelse 0.9;
    const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 10_000, 0, mcp.WAIT_CAP_MS);
    const do_click = argBool(args, "click");
    const btn: u32 = @intCast(argInt(args, "button") orelse 1);
    const deadline = nowMs() + timeout_ms;
    var found: ?FoundMatch = null;
    while (true) {
        switch (try findInWindow(arena, app, wid, region, needle, min_score, 1)) {
            .matches => |ms| if (ms.len > 0) {
                found = ms[0];
            },
            .err => {}, // window not rendered yet — keep waiting
        }
        if (found != null or app.exited or nowMs() >= deadline) break;
        _ = app.pumpOnce(50);
    }
    const m = found orelse return errRes(arena, .timeout, try std.fmt.allocPrint(
        arena,
        "template \"{s}\" did not appear before timeout",
        .{needle.name},
    ));
    var clicked = false;
    if (do_click) {
        clickTuned(app, wid, @floatFromInt(m.cx), @floatFromInt(m.cy), btn) catch
            return errRes(arena, .not_found, "template matched but the click failed (bad window?)");
        _ = app.waitIdle(100, 1_000);
        clicked = true;
        // Journal as a replayable step (named templates only —
        // an inline image has no stable reference to replay).
        if (!std.mem.eql(u8, needle.name, "(inline)"))
            journalStep(app, "{{\"wait_image\":{{\"template\":\"{s}\",\"click\":true,\"min_score\":{d:.2}}}}}", .{ needle.name, min_score });
    }
    var res = Res.init(arena);
    try res.fact("found", true);
    try res.fact("template", needle.name);
    try res.fact("window", wid);
    try res.fact("x", m.x);
    try res.fact("y", m.y);
    try res.fact("cx", m.cx);
    try res.fact("cy", m.cy);
    try res.fact("score", m.score);
    try res.fact("clicked", clicked);
    try res.textf("template \"{s}\" matched at ({d},{d}) centre ({d},{d}) score {d:.3} in window {d}{s}", .{
        needle.name, m.x, m.y, m.cx, m.cy, m.score, wid,
        if (clicked) " — clicked its centre" else "",
    });
    return res.finish();
}

fn appMacroRun(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const mname = argStr(args, "name") orelse return errRes(arena, .invalid_args, "app_macro_run requires 'name'");
    const bytes = mcpassets.load(arena, .macro, mname) catch |err| switch (err) {
        mcpassets.Error.NotFound => return errRes(arena, .not_found, try std.fmt.allocPrint(arena, "no saved macro \"{s}\" (list with app_macros)", .{mname})),
        mcpassets.Error.BadName => return errRes(arena, .invalid_args, "invalid macro name"),
        mcpassets.Error.OutOfMemory => return error.OutOfMemory,
        else => return errRes(arena, .io_failed, "macro load failed"),
    };
    const steps = macroSteps(arena, bytes) orelse
        return appErr(arena, "the stored macro is not replayable: it needs an actions array of 1 to 200 step objects");
    const win_arg: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
    return runActionSteps(arena, app, steps, win_arg, false, mname);
}

fn closeAppWindow(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const win_id: u32 = @intCast(argInt(args, "window") orelse
        return errRes(arena, .invalid_args, "close_app_window requires 'window'"));
    app.closeWindow(win_id) catch return errRes(arena, .not_found, "close failed (bad window?)");
    var res = Res.init(arena);
    try res.fact("window", win_id);
    try res.fact("close_requested", true);
    try res.textf("asked window {d} to close (the app decides)", .{win_id});
    return res.finish();
}

fn closeApp(arena: std.mem.Allocator, _: Tool, _: std.json.Value, app: *appdrive.App) ![]const u8 {
    // Idempotent: closing an already-dead app is a no-op success.
    const id = appIdOf(app);
    const was_exited = app.exited;
    const status = app.exit_status;
    _ = app_state.apps.swapRemove(id);
    // Wait for the daemon to ACK the kill: it tears the session
    // down by signalling the child's whole process group, so an
    // acknowledged kill means no descendant survived. Firing the
    // frame and closing the socket (the old behaviour) reported
    // "killed" whether or not anything died.
    const outcome = app.killAndWait(5_000);
    // An unacknowledged kill is NOT left ambiguous: ask the daemon
    // whether the session still exists. "gone" is a late ACK, a
    // stated success; "running" is the real failure; only "unknown"
    // (the daemon could not be asked) keeps the old hedge.
    const process_state: []const u8 = if (outcome != .unconfirmed)
        "gone"
    else if (app.sessionListed(5_000)) |listed|
        (if (listed) "running" else "gone")
    else
        "unknown";
    app.deinit();
    const msg: []const u8 = switch (outcome) {
        .already_exited => if (was_exited)
            try std.fmt.allocPrint(arena, "app session closed (the app had already exited with status {d})", .{status})
        else
            "app session closed (it was already gone on the daemon)",
        .acknowledged => "app session killed — the daemon signalled the child's whole process group and reaped it; no descendant processes remain",
        .unconfirmed => if (eql(u8, process_state, "gone"))
            "app session killed: the daemon's acknowledgement did not arrive within 5s, but a follow-up listing confirms the session is gone"
        else if (eql(u8, process_state, "running"))
            "KILL NOT CONFIRMED: the daemon did not acknowledge within 5s and a follow-up listing still shows the session ALIVE — the process is still running; retry close_app, or kill it on the daemon host"
        else
            "app session closed locally, but the daemon did not acknowledge the kill within 5s and could not be asked whether the session survived — the process MAY still be running; check with list_apps or on the daemon host",
    };
    if (outcome == .unconfirmed and !eql(u8, process_state, "gone")) return errRes(arena, .timeout, msg);
    var res = Res.init(arena);
    try res.fact("app", id);
    try res.fact("outcome", @tagName(outcome));
    try res.fact("process_state", process_state);
    try res.fact("was_exited", was_exited);
    if (was_exited) try res.fact("exit_status", status);
    try res.text(msg);
    return res.finish();
}

/// app_wait_log: block until a log line matches `pattern`, then
/// return it (optionally with a screenshot taken at that moment).
///
/// The events worth synchronising on in a real app — a cinematic
/// ending, an effect firing, a subsystem reporting ready — are
/// announced in its own stdout/stderr long before any pixel settles,
/// and often never quiesce visually at all. Without this the only
/// approximation was abusing app_wait as a timer around repeated
/// app_log polls, which costs turns and still misses short-lived
/// events. For sub-second visual events, prefer the OSC 5522 marker
/// escape (app_log): it stashes the frame at the exact instant.
fn waitLog(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const m = switch (logFilterFrom(arena, args)) {
        .none => return errRes(arena, .invalid_args, "app_wait_log requires 'pattern' (the log-line pattern to wait for)"),
        .m => |mm| mm,
        .err => |e| return errRes(arena, .invalid_args, e),
    };
    const pat = argStr(args, "pattern") orelse argStr(args, "grep") orelse "";
    const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, mcp.WAIT_CAP_MS);
    // Default scans the WHOLE ring first, so an event that already
    // happened resolves immediately; from_id skips history when the
    // caller specifically needs a NEW occurrence.
    var from: u64 = @intCast(@max(argInt(args, "from_id") orelse 0, 0));
    const t0 = nowMs();
    const deadline = t0 + timeout_ms;
    var scanned: usize = 0;
    var newest: u64 = 0;
    while (true) {
        if (logFetchLines(arena, app, from, 500, 300, 5_000) catch null) |got| {
            for (got.reply.lines) |l| {
                if (l.id < from) continue;
                scanned += 1;
                newest = l.id;
                if (!m.matches(l.text)) continue;
                const elapsed = nowMs() - t0;
                const wid = firstToplevelId(app);
                const frame = app.frameCount(wid);
                var res = Res.init(arena);
                try res.fact("app", appIdOf(app));
                try res.fact("matched", true);
                try res.fact("timed_out", false);
                try res.fact("pattern", pat);
                try res.fact("line_id", l.id);
                try res.fact("marker", l.marker);
                try res.fact("text", l.text);
                try res.fact("elapsed_ms", elapsed);
                try res.fact("scanned", scanned);
                try res.fact("window", wid);
                try res.fact("frame_at_match", frame);
                try res.textf(
                    "matched \"{s}\" after {d}ms — log line {d}{s}; window {d} is at frame {d}, so screenshot_app min_frame:{d} guarantees pixels committed after this line",
                    .{ pat, elapsed, l.id, if (l.marker) " [marker]" else "", wid, frame, frame },
                );
                try res.textf("--- line ---\n{s}", .{l.text});
                if (argBool(args, "screenshot") and wid != 0) {
                    if (app.screenshotPng(wid, 1568, null, 1)) |shot| {
                        defer app_state.allocator.free(shot.png);
                        try addShotFacts(&res, arena, app, wid, shot);
                        return res.finishWithImages(&.{shot.png}, null);
                    } else |_| {}
                }
                return res.finish();
            }
            // Follow forward: the next fetch starts past everything
            // seen, so a long-running wait costs one small round trip
            // per poll instead of re-scanning the ring.
            if (got.reply.next_id > 0) from = got.reply.next_id;
        }
        if (app.exited or app.presentationGone()) {
            _ = probeAppStop(app, 500);
            return appStateErr(arena, app, .conflict, try std.fmt.allocPrint(
                arena,
                "the app exited before any log line matched \"{s}\" ({d} line(s) scanned in {d}ms)",
                .{ pat, scanned, nowMs() - t0 },
            ));
        }
        if (Watchdog.fired.load(.acquire))
            return errRes(arena, .timeout, "app_wait_log aborted by the MCP hard timeout");
        if (nowMs() >= deadline) break;
        // Pumped sleep: keeps frames/exit flowing while we wait.
        _ = app.pumpOnce(200);
    }
    return errRes(arena, .timeout, try std.fmt.allocPrint(
        arena,
        "no log line matched \"{s}\" within {d}ms ({d} line(s) scanned, newest id {d}). The app is still running — re-run with from_id:{d} to continue from here.",
        .{ pat, timeout_ms, scanned, newest, newest },
    ));
}

/// One executed step, as the result's `steps` array reports it.
const StepOutcome = struct {
    step: usize,
    ok: bool,
    /// The step's own transcript line, without its "step N: " prefix.
    note: []const u8,
    /// The batch budget shortened this step's wait, so a timeout here is
    /// the budget running out and not the app failing to settle.
    wait_clipped: bool = false,
};

/// Execute an ordered batch of action steps against `app` — the
/// app_actions vocabulary, shared with macro replay (app_macro_run).
/// `record` journals each successful step for app_macro_save; `macro`
/// names the replayed macro (null = a direct app_actions call).
///
/// A step FAILURE is not a tool error: the batch ran, and `status`
/// ("completed" / "failed" / "app_exited") is the machine truth beside
/// the step transcript in the text lane.
pub fn runActionSteps(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    steps: []const std.json.Value,
    win_arg: ?u32,
    record: bool,
    macro: ?[]const u8,
) ![]const u8 {
    const MAX_SHOTS = 8;
    // ONE budget for the whole batch. Every waiting step spends out of
    // it (`stepBudget`) and the loop stops once it is gone, so a batch
    // answers within the same bound a single app tool does instead of
    // being cut off by the central watchdog mid-transcript.
    const batch_deadline = nowMs() + mcp.WAIT_CAP_MS;

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    var outcomes: std.ArrayList(StepOutcome) = .empty;
    defer outcomes.deinit(arena);
    // Where in the transcript the CURRENT step's line begins, so an
    // outcome's note is the exact text that step produced.
    var cur_step: usize = 0;
    var cur_start: usize = 0;
    // Whether the CURRENT step's wait was shortened by the batch budget;
    // reported as a fact so a clipped timeout is never read as a verdict.
    var step_clipped = false;
    var pngs: std.ArrayList([]const u8) = .empty;
    defer {
        for (pngs.items) |p| app_state.allocator.free(p);
        pngs.deinit(arena);
    }
    // Per-image trace-filename tags, parallel to `pngs`.
    var shot_tags: std.ArrayList([]const u8) = .empty;
    defer shot_tags.deinit(arena);
    var stopped = false;
    var app_stop: ?AppStop = null;
    var stop_step: usize = 0;
    // Marks accumulated by `"mark": true` steps; drawn onto (and
    // consumed by) the next screenshot so several clicks can share
    // one annotated image, each labelled with its step number.
    var pending_marks: std.ArrayList(marks_mod.Mark) = .empty;
    defer pending_marks.deinit(arena);
    if (macro) |mname| try w.print("replaying macro \"{s}\" ({d} steps)\n", .{ mname, steps.len });
    for (steps, 0..) |st, idx| {
        const n = idx + 1;
        cur_step = n;
        cur_start = aw.written().len;
        step_clipped = false;
        if (nowMs() >= batch_deadline) {
            try w.print(
                "step {d}: ERROR — the batch spent its whole {d}ms budget; remaining steps skipped (split it, or lower the per-step timeouts)\n",
                .{ n, mcp.WAIT_CAP_MS },
            );
            stopped = true;
            break;
        }
        if (probeAppStop(app, 1_000)) |stop| {
            try reportActionStop(arena, w, n, "the batch", stop);
            app_stop = stop;
            stop_step = n;
            stopped = true;
            break;
        }
        if (st != .object) {
            try w.print("step {d}: ERROR — each step must be an object\n", .{n});
            stopped = true;
            break;
        }
        const win_step: ?u32 = if (argInt(st, "window")) |v| @intCast(v) else win_arg;
        const button: u32 = @intCast(argInt(st, "button") orelse 1);

        if (st.object.get("wait")) |wv| {
            const b = stepBudget(std.math.clamp(if (wv == .integer) wv.integer else 0, 0, 30_000), batch_deadline);
            step_clipped = b.clipped;
            _ = app.waitIdle(std.math.maxInt(i32), b.ms); // pure pumped sleep
            try w.print("step {d}: waited {d}ms{s}\n", .{ n, b.ms, try clipNote(arena, b) });
        } else if (st.object.get("move")) |mv| {
            const xy = numArray(mv, 2) orelse {
                try w.print("step {d}: ERROR — \"move\" wants [x,y]\n", .{n});
                stopped = true;
                break;
            };
            const pos = app.moveMouse(win_step, xy[0], xy[1]) catch {
                try w.print("step {d}: ERROR — move failed (bad window?)\n", .{n});
                stopped = true;
                break;
            };
            const marked = argBool(st, "mark");
            if (marked) pending_marks.append(arena, .{ .x = pos.x, .y = pos.y, .kind = .move, .label = @intCast(n) }) catch {};
            try w.print("step {d}: moved to ({d:.0},{d:.0}) window {d}{s}\n", .{ n, pos.x, pos.y, pos.win, if (marked) " [marked]" else "" });
        } else if (st.object.get("move_rel")) |mv| {
            const dd = numArray(mv, 2) orelse {
                try w.print("step {d}: ERROR — \"move_rel\" wants [dx,dy]\n", .{n});
                stopped = true;
                break;
            };
            const pos = app.moveMouseRel(win_step, dd[0], dd[1]) catch {
                try w.print("step {d}: ERROR — move_rel failed (bad window?)\n", .{n});
                stopped = true;
                break;
            };
            const marked = argBool(st, "mark");
            if (marked) pending_marks.append(arena, .{ .x = pos.x, .y = pos.y, .kind = .move, .label = @intCast(n) }) catch {};
            try w.print("step {d}: moved by ({d:.0},{d:.0}) to ({d:.0},{d:.0}) window {d}{s}\n", .{ n, dd[0], dd[1], pos.x, pos.y, pos.win, if (marked) " [marked]" else "" });
        } else if (st.object.get("click")) |cv| {
            const xy = numArray(cv, 2) orelse {
                try w.print("step {d}: ERROR — \"click\" wants [x,y]\n", .{n});
                stopped = true;
                break;
            };
            const wid = win_step orelse firstToplevelId(app);
            const hold_ms: i64 = std.math.clamp(argInt(st, "hold_ms") orelse Tuning.hold_ms.value, 0, 10_000);
            const cnt: u32 = @intCast(std.math.clamp(argInt(st, "count") orelse 1, 1, 3));
            app.clickEx(wid, xy[0], xy[1], button, hold_ms, cnt) catch {
                if (probeAppStop(app, 1_000)) |stop| {
                    try reportActionStop(arena, w, n, "the click", stop);
                    app_stop = stop;
                    stop_step = n;
                    stopped = true;
                    break;
                }
                try w.print("step {d}: ERROR — click failed (bad window?)\n", .{n});
                stopped = true;
                break;
            };
            _ = app.waitIdle(100, 1_000);
            const marked = argBool(st, "mark");
            if (marked) pending_marks.append(arena, .{ .x = xy[0], .y = xy[1], .kind = .click, .label = @intCast(n) }) catch {};
            if (cnt > 1) {
                try w.print("step {d}: clicked ({d:.0},{d:.0}) x{d} button {d} window {d}{s}\n", .{ n, xy[0], xy[1], cnt, button, wid, if (marked) " [marked]" else "" });
            } else {
                try w.print("step {d}: clicked ({d:.0},{d:.0}) button {d} window {d}{s}\n", .{ n, xy[0], xy[1], button, wid, if (marked) " [marked]" else "" });
            }
        } else if (st.object.get("drag")) |dv| {
            const q = numArray(dv, 4) orelse {
                try w.print("step {d}: ERROR — \"drag\" wants [x1,y1,x2,y2]\n", .{n});
                stopped = true;
                break;
            };
            const wid = win_step orelse firstToplevelId(app);
            app.drag(wid, q[0], q[1], q[2], q[3], button) catch {
                if (probeAppStop(app, 1_000)) |stop| {
                    try reportActionStop(arena, w, n, "the drag", stop);
                    app_stop = stop;
                    stop_step = n;
                    stopped = true;
                    break;
                }
                try w.print("step {d}: ERROR — drag failed (bad window?)\n", .{n});
                stopped = true;
                break;
            };
            _ = app.waitIdle(100, 1_000);
            const marked = argBool(st, "mark");
            if (marked) {
                // Start point unlabelled (hover color), end point
                // carries the step number.
                pending_marks.append(arena, .{ .x = q[0], .y = q[1], .kind = .move }) catch {};
                pending_marks.append(arena, .{ .x = q[2], .y = q[3], .kind = .click, .label = @intCast(n) }) catch {};
            }
            try w.print("step {d}: dragged ({d:.0},{d:.0})→({d:.0},{d:.0}) window {d}{s}\n", .{ n, q[0], q[1], q[2], q[3], wid, if (marked) " [marked]" else "" });
        } else if (st.object.get("key")) |kv| {
            if (kv != .string) {
                try w.print("step {d}: ERROR — \"key\" wants a string of chords\n", .{n});
                stopped = true;
                break;
            }
            const khold: i64 = std.math.clamp(argInt(st, "hold_ms") orelse 0, 0, 10_000);
            var bad = false;
            var it = std.mem.tokenizeScalar(u8, kv.string, ' ');
            while (it.next()) |spec| {
                app.pressKeyHold(win_step, spec, khold) catch {
                    bad = true;
                    break;
                };
            }
            if (bad) {
                if (probeAppStop(app, 1_000)) |stop| {
                    try reportActionStop(arena, w, n, "the key press", stop);
                    app_stop = stop;
                    stop_step = n;
                    stopped = true;
                    break;
                }
                try w.print("step {d}: ERROR — key press failed (unknown chord / no window?)\n", .{n});
                stopped = true;
                break;
            }
            _ = app.waitIdle(100, 1_000);
            try w.print("step {d}: pressed \"{s}\"\n", .{ n, kv.string });
        } else if (st.object.get("type")) |tv| {
            if (tv != .string) {
                try w.print("step {d}: ERROR — \"type\" wants a string\n", .{n});
                stopped = true;
                break;
            }
            app.typeText(win_step, tv.string) catch {
                if (probeAppStop(app, 1_000)) |stop| {
                    try reportActionStop(arena, w, n, "text input", stop);
                    app_stop = stop;
                    stop_step = n;
                    stopped = true;
                    break;
                }
                try w.print("step {d}: ERROR — type failed (no window?)\n", .{n});
                stopped = true;
                break;
            };
            _ = app.waitIdle(100, 1_000);
            try w.print("step {d}: typed {d} chars\n", .{ n, tv.string.len });
        } else if (st.object.get("scroll")) |sv| {
            const dd = numArray(sv, 2) orelse {
                try w.print("step {d}: ERROR — \"scroll\" wants [dx,dy]\n", .{n});
                stopped = true;
                break;
            };
            var sx: f64 = 10;
            var sy: f64 = 10;
            if (st.object.get("at")) |atv| {
                if (numArray(atv, 2)) |at| {
                    sx = at[0];
                    sy = at[1];
                }
            } else if (app.pointerPos()) |p| {
                sx = p.x;
                sy = p.y;
            }
            const wid = win_step orelse firstToplevelId(app);
            app.scroll(wid, sx, sy, dd[0], dd[1]) catch {
                if (probeAppStop(app, 1_000)) |stop| {
                    try reportActionStop(arena, w, n, "scroll input", stop);
                    app_stop = stop;
                    stop_step = n;
                    stopped = true;
                    break;
                }
                try w.print("step {d}: ERROR — scroll failed (bad window?)\n", .{n});
                stopped = true;
                break;
            };
            _ = app.waitIdle(100, 1_000);
            const marked = argBool(st, "mark");
            if (marked) pending_marks.append(arena, .{ .x = sx, .y = sy, .kind = .move, .label = @intCast(n) }) catch {};
            try w.print("step {d}: scrolled ({d:.0},{d:.0}) at ({d:.0},{d:.0}) window {d}{s}\n", .{ n, dd[0], dd[1], sx, sy, wid, if (marked) " [marked]" else "" });
        } else if (st.object.get("wait_idle")) |wv| {
            var quiet_ms: i64 = 400;
            var timeout_ms: i64 = 10_000;
            var change_pct: ?f64 = null;
            if (wv == .object) {
                if (argInt(wv, "quiet_ms")) |q| quiet_ms = q;
                if (argInt(wv, "timeout_ms")) |t| timeout_ms = t;
                change_pct = argFloat(wv, "change_pct");
            }
            const budget = stepBudget(timeout_ms, batch_deadline);
            step_clipped = budget.clipped;
            timeout_ms = budget.ms;
            var settled: bool = undefined;
            if (change_pct) |pct| {
                const wid = win_step orelse firstToplevelId(app);
                settled = if (wid == 0) false else app.waitVisualSettle(wid, quiet_ms, timeout_ms, pct, if (wv == .object) regionFrom(wv) else null);
            } else {
                settled = app.waitIdle(quiet_ms, timeout_ms);
            }
            if (probeAppStop(app, 1_000)) |stop| {
                try reportActionStop(arena, w, n, "wait_idle", stop);
                app_stop = stop;
                stop_step = n;
                stopped = true;
                break;
            }
            if (!settled and (argBool(st, "required") or (wv == .object and argBool(wv, "required")))) {
                try w.print(
                    "step {d}: ERROR — wait_idle did not settle before timeout (required); remaining steps skipped{s}\n",
                    .{ n, try clipNote(arena, budget) },
                );
                stopped = true;
                break;
            }
            try w.print("step {d}: wait_idle — {s}{s}\n", .{
                n,
                if (settled) "settled" else "TIMED OUT (still rendering)",
                try clipNote(arena, budget),
            });
        } else if (st.object.get("wait_change")) |wv| {
            var timeout_ms: i64 = 10_000;
            var min_pct: f64 = 0;
            if (wv == .integer) {
                timeout_ms = wv.integer;
            } else if (wv == .object) {
                if (argInt(wv, "timeout_ms")) |t| timeout_ms = t;
                if (argFloat(wv, "min_change_pct")) |p| min_pct = p;
            }
            const budget = stepBudget(timeout_ms, batch_deadline);
            step_clipped = budget.clipped;
            timeout_ms = budget.ms;
            const wid = win_step orelse firstToplevelId(app);
            const changed = if (wid == 0) false else app.waitWindowChange(wid, timeout_ms, min_pct, if (wv == .object and min_pct > 0) regionFrom(wv) else null);
            if (probeAppStop(app, 1_000)) |stop| {
                try reportActionStop(arena, w, n, "wait_change", stop);
                app_stop = stop;
                stop_step = n;
                stopped = true;
                break;
            }
            if (!changed and (argBool(st, "required") or (wv == .object and argBool(wv, "required")))) {
                try w.print(
                    "step {d}: ERROR — wait_change saw no change before timeout (required); remaining steps skipped{s}\n",
                    .{ n, try clipNote(arena, budget) },
                );
                stopped = true;
                break;
            }
            try w.print("step {d}: wait_change — {s}{s}\n", .{
                n,
                if (changed) "content changed" else "TIMED OUT (no change)",
                try clipNote(arena, budget),
            });
        } else if (st.object.get("screenshot")) |sv| {
            const wid = win_step orelse firstToplevelId(app);
            if (wid == 0) {
                try w.print("step {d}: ERROR — no rendered window to screenshot\n", .{n});
                stopped = true;
                break;
            }
            if (pngs.items.len >= MAX_SHOTS) {
                try w.print("step {d}: screenshot SKIPPED (max {d} per call)\n", .{ n, MAX_SHOTS });
                try outcomes.append(arena, stepOutcome(cur_step, true, aw.written()[cur_start..], step_clipped));
                continue;
            }
            var max_px: u32 = 1568;
            if (sv == .object) {
                if (argInt(sv, "max_px")) |m| max_px = @intCast(std.math.clamp(m, 0, 8192));
            }
            if (argBool(st, "mark") or (sv == .object and argBool(sv, "mark"))) {
                // Mark the current pointer position (hover check).
                if (app.pointerPos()) |p|
                    pending_marks.append(arena, .{ .x = p.x, .y = p.y, .kind = .move, .label = @intCast(n) }) catch {};
            }
            const prefix = try std.fmt.allocPrint(arena, "step {d}", .{n});
            if (!try actionsCapture(arena, app, w, &pngs, &shot_tags, &pending_marks, wid, max_px, prefix)) {
                if (probeAppStop(app, 1_000)) |stop| {
                    try reportActionStop(arena, w, n, "the screenshot", stop);
                    app_stop = stop;
                    stop_step = n;
                } else {
                    try w.print("step {d}: ERROR - screenshot failed (no pixels yet?)\n", .{n});
                }
                stopped = true;
                break;
            }
            try outcomes.append(arena, stepOutcome(cur_step, true, aw.written()[cur_start..], step_clipped));
            continue;
        } else if (st.object.get("wait_image") != null or st.object.get("click_image") != null) {
            const is_wait = st.object.get("wait_image") != null;
            const wv = st.object.get("wait_image") orelse st.object.get("click_image").?;
            if (wv != .object) {
                try w.print("step {d}: ERROR — \"{s}\" wants an object with 'template' or 'image_b64'\n", .{ n, if (is_wait) "wait_image" else "click_image" });
                stopped = true;
                break;
            }
            const needle = switch (try resolveNeedle(arena, wv)) {
                .needle => |nd| nd,
                .err => |e| {
                    try w.print("step {d}: ERROR — {s}\n", .{ n, e });
                    stopped = true;
                    break;
                },
            };
            const min_score = argFloat(wv, "min_score") orelse 0.9;
            const budget: StepWait = if (is_wait)
                stepBudget(argInt(wv, "timeout_ms") orelse 10_000, batch_deadline)
            else
                .{ .ms = 0, .clipped = false, .requested = 0 };
            step_clipped = budget.clipped;
            const timeout_ms: i64 = budget.ms;
            // click_image clicks by definition; wait_image opts in.
            const do_click = if (is_wait) argBool(wv, "click") else true;
            const btn: u32 = @intCast(argInt(wv, "button") orelse 1);
            const region = regionFrom(wv);
            const wid = win_step orelse firstToplevelId(app);
            const deadline = nowMs() + timeout_ms;
            var found: ?FoundMatch = null;
            while (true) {
                switch (try findInWindow(arena, app, wid, region, needle, min_score, 1)) {
                    .matches => |ms| if (ms.len > 0) {
                        found = ms[0];
                    },
                    .err => {}, // window not rendered yet — keep waiting
                }
                if (found != null or app.exited or app.presentationGone() or nowMs() >= deadline) break;
                _ = app.pumpOnce(50);
            }
            if (probeAppStop(app, 1_000)) |stop| {
                try reportActionStop(arena, w, n, if (is_wait) "wait_image" else "click_image", stop);
                app_stop = stop;
                stop_step = n;
                stopped = true;
                break;
            }
            const m = found orelse {
                try w.print("step {d}: ERROR — template \"{s}\" not found{s}{s}\n", .{
                    n,
                    needle.name,
                    if (is_wait) " before timeout" else "",
                    try clipNote(arena, budget),
                });
                stopped = true;
                break;
            };
            if (do_click) {
                clickTuned(app, wid, @floatFromInt(m.cx), @floatFromInt(m.cy), btn) catch {
                    if (probeAppStop(app, 1_000)) |stop| {
                        try reportActionStop(arena, w, n, if (is_wait) "wait_image click" else "click_image", stop);
                        app_stop = stop;
                        stop_step = n;
                        stopped = true;
                        break;
                    }
                    try w.print("step {d}: ERROR — template matched but the click failed (bad window?)\n", .{n});
                    stopped = true;
                    break;
                };
                _ = app.waitIdle(100, 1_000);
                if (argBool(st, "mark"))
                    pending_marks.append(arena, .{ .x = @floatFromInt(m.cx), .y = @floatFromInt(m.cy), .kind = .click, .label = @intCast(n) }) catch {};
            }
            try w.print("step {d}: template \"{s}\" matched at ({d},{d}) score {d:.3}{s}\n", .{ n, needle.name, m.x, m.y, m.score, if (do_click) " — clicked its center" else "" });
        } else if (st.object.get("wait_text")) |wv| {
            if (wv != .object) {
                try w.print("step {d}: ERROR — \"wait_text\" wants an object with 'text'\n", .{n});
                stopped = true;
                break;
            }
            const query = argStr(wv, "text") orelse {
                try w.print("step {d}: ERROR — \"wait_text\" requires 'text'\n", .{n});
                stopped = true;
                break;
            };
            const budget = stepBudget(argInt(wv, "timeout_ms") orelse 15_000, batch_deadline);
            step_clipped = budget.clipped;
            const timeout_ms: i64 = budget.ms;
            const do_click = argBool(wv, "click");
            const region = regionFrom(wv);
            const scale: u32 = @intCast(std.math.clamp(argInt(wv, "scale") orelse 0, 0, 8));
            const psm: i32 = @intCast(argInt(wv, "psm") orelse 6);
            const lang = argStr(wv, "lang") orelse "eng";
            const wid = win_step orelse firstToplevelId(app);
            const deadline = nowMs() + timeout_ms;
            var seen: ?OcrOut = null;
            var fatal: ?[]const u8 = null;
            // One arena per OCR pass, released between polls: a pass
            // charges its caller for the recognized text and word boxes
            // and, for small fonts, an upscaled copy of the capture
            // (`ocrWindow` frees the capture itself). Charged to the call
            // arena those would only be freed when the whole batch ends.
            var ocr_scratch = std.heap.ArenaAllocator.init(app_state.allocator);
            defer ocr_scratch.deinit();
            while (true) {
                _ = ocr_scratch.reset(.free_all);
                switch (try ocrWindow(ocr_scratch.allocator(), app, wid, region, scale, psm, lang)) {
                    .out => |o| {
                        if (std.ascii.indexOfIgnoreCase(o.text, query) != null) seen = try dupeOcrOut(arena, o);
                    },
                    .err => |e| {
                        // "not rendered yet" is transient; a missing
                        // OCR engine never resolves — stop now.
                        if (!std.mem.startsWith(u8, e, "no rendered")) fatal = try arena.dupe(u8, e);
                    },
                }
                if (seen != null or fatal != null or app.exited or app.presentationGone() or nowMs() >= deadline) break;
                _ = app.waitIdle(std.math.maxInt(i32), 300); // pumped sleep between OCR passes
            }
            if (probeAppStop(app, 1_000)) |stop| {
                try reportActionStop(arena, w, n, "wait_text", stop);
                app_stop = stop;
                stop_step = n;
                stopped = true;
                break;
            }
            if (fatal) |e| {
                try w.print("step {d}: ERROR — {s}\n", .{ n, e });
                stopped = true;
                break;
            }
            const o = seen orelse {
                try w.print("step {d}: ERROR — text \"{s}\" not visible before timeout{s}\n", .{ n, query, try clipNote(arena, budget) });
                stopped = true;
                break;
            };
            var note: []const u8 = "";
            if (do_click) {
                const box = findWordRun(o.words, query) orelse {
                    try w.print("step {d}: ERROR — text \"{s}\" is visible but OCR gave no clickable word box for it\n", .{ n, query });
                    stopped = true;
                    break;
                };
                clickTuned(app, wid, @floatFromInt(box.x + box.w / 2), @floatFromInt(box.y + box.h / 2), 1) catch {
                    if (probeAppStop(app, 1_000)) |stop| {
                        try reportActionStop(arena, w, n, "wait_text click", stop);
                        app_stop = stop;
                        stop_step = n;
                        stopped = true;
                        break;
                    }
                    try w.print("step {d}: ERROR — text found but the click failed (bad window?)\n", .{n});
                    stopped = true;
                    break;
                };
                _ = app.waitIdle(100, 1_000);
                if (argBool(st, "mark"))
                    pending_marks.append(arena, .{ .x = @floatFromInt(box.x + box.w / 2), .y = @floatFromInt(box.y + box.h / 2), .kind = .click, .label = @intCast(n) }) catch {};
                note = " — clicked it";
            }
            try w.print("step {d}: text \"{s}\" is visible{s}\n", .{ n, query, note });
        } else {
            try w.print("step {d}: ERROR — unknown step (want move/move_rel/click/drag/key/type/scroll/wait/wait_idle/wait_change/screenshot/wait_image/click_image/wait_text)\n", .{n});
            stopped = true;
            break;
        }
        if (probeAppStop(app, 1_000)) |stop| {
            try reportActionStop(arena, w, n, "the action", stop);
            app_stop = stop;
            stop_step = n;
            stopped = true;
            break;
        }
        // Combined form: {"click":[x,y],"screenshot":true} — capture
        // right after the action, with any pending marks drawn in.
        // (Dedicated screenshot steps `continue`d above.)
        if (argBool(st, "screenshot")) {
            const wid = win_step orelse firstToplevelId(app);
            if (pngs.items.len >= MAX_SHOTS) {
                try w.print("step {d}: screenshot SKIPPED (max {d} per call)\n", .{ n, MAX_SHOTS });
            } else if (wid != 0) {
                const prefix = try std.fmt.allocPrint(arena, "step {d}", .{n});
                if (!try actionsCapture(arena, app, w, &pngs, &shot_tags, &pending_marks, wid, 1568, prefix)) {
                    if (probeAppStop(app, 1_000)) |stop| {
                        try reportActionStop(arena, w, n, "the screenshot", stop);
                        app_stop = stop;
                        stop_step = n;
                    } else {
                        try w.print("step {d}: ERROR - screenshot failed (no pixels yet?)\n", .{n});
                    }
                    stopped = true;
                    break;
                }
            }
        }
        try outcomes.append(arena, stepOutcome(cur_step, true, aw.written()[cur_start..], step_clipped));
        // Journal the step VERBATIM once it succeeded (pure
        // screenshot steps `continue`d above and are not steps a
        // macro needs to repeat).
        if (record) {
            var jw: std.Io.Writer.Allocating = .init(arena);
            std.json.Stringify.value(st, .{}, &jw.writer) catch {};
            Journal.record(appIdOf(app), jw.written());
        }
    }
    // The step that stopped the batch produced the last transcript
    // line; record it as the failing outcome.
    if (stopped and cur_step != 0)
        try outcomes.append(arena, stepOutcome(cur_step, false, aw.written()[cur_start..], step_clipped));
    // `mark` without any screenshot still yields an image: capture
    // the final state with the leftover marks drawn in.
    if (!stopped and pending_marks.items.len > 0 and pngs.items.len < MAX_SHOTS) {
        const wid = win_arg orelse firstToplevelId(app);
        if (wid != 0)
            _ = try actionsCapture(arena, app, w, &pngs, &shot_tags, &pending_marks, wid, 1568, "end of batch");
    }
    if (!stopped) try w.print("all {d} steps completed\n", .{steps.len});

    var res = Res.init(arena);
    if (macro) |mname| try res.fact("macro", mname);
    // The batch RAN: a failed step is a fact, never a tool error.
    const status: []const u8 = if (app_stop != null) "app_exited" else if (stopped) "failed" else "completed";
    try res.fact("status", status);
    try res.textf("{s}: {d} of {d} step(s) ran", .{ status, outcomes.items.len, steps.len });
    try res.fact("steps_total", steps.len);
    try res.fact("steps_run", outcomes.items.len);
    if (stopped) {
        try res.fact("step", if (app_stop != null) stop_step else cur_step);
        try res.fact("remaining_steps_skipped", true);
    }
    if (app_stop) |stop| {
        try res.fact("reason", stop.reasonName());
        if (stop.exit_status) |code| try res.fact("exit_status", code);
        if (stop.signal) |sig| {
            try res.fact("signal", sig);
            try res.fact("signal_name", signalName(sig));
        }
    } else if (stopped and outcomes.items.len > 0) {
        try res.fact("reason", outcomes.items[outcomes.items.len - 1].note);
    }
    try res.fact("steps", outcomes.items);
    if (pngs.items.len > 0) try res.fact("screenshots", pngs.items.len);
    if (app_stop != null or app.exited or app.presentationGone())
        try res.text(try appSummaryText(arena, app));
    try res.textf("--- steps ---\n{s}", .{std.mem.trimEnd(u8, aw.written(), "\n")});
    if (pngs.items.len > 0) return res.finishWithImages(pngs.items, shot_tags.items);
    return res.finish();
}

/// One outcome from a step's transcript slice: the "step N: " prefix
/// and the trailing newline belong to the transcript, not to the fact.
fn stepOutcome(step: usize, ok: bool, line: []const u8, wait_clipped: bool) StepOutcome {
    var note = std.mem.trimEnd(u8, line, "\n");
    if (std.mem.indexOf(u8, note, ": ")) |at| {
        if (std.mem.startsWith(u8, note, "step ")) note = note[at + 2 ..];
    }
    // "ERROR" is what the transcript shouts; `ok` already carries it.
    for ([_][]const u8{ "ERROR — ", "ERROR - " }) |prefix| {
        if (std.mem.startsWith(u8, note, prefix)) note = note[prefix.len..];
    }
    return .{ .step = step, .ok = ok, .note = note, .wait_clipped = wait_clipped };
}

/// Continuation of appTool (split around the step engine so
/// runActionSteps can live between the two halves).

// ── observation tools (app_watch / app_hover_map / app_backtrace) ──

/// app_watch: sample a window continuously and report WHEN it changed.
///
/// A screenshot answers "what is on screen now"; nothing answered "did
/// anything happen in the next N seconds". For an action with unknown
/// latency the two are not the same question, and a capture that lands
/// in a pre-roll — or after a short clip has already ended — reads
/// exactly like a dead control. This turns that guess into a
/// measurement.
fn appWatch(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
    if (wid == 0) return errRes(arena, .not_found, "no rendered window yet — nothing to watch");
    const duration_ms: i64 = std.math.clamp(argInt(args, "duration_ms") orelse 10_000, 200, mcp.WAIT_CAP_MS);
    const min_pct = argFloat(args, "min_change_pct") orelse 2.0;
    const max_events: usize = @intCast(std.math.clamp(argInt(args, "max_events") orelse 16, 1, 64));
    const thumbs: usize = @intCast(std.math.clamp(argInt(args, "thumbnails") orelse 3, 0, 8));
    const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse 640, 64, 2048));
    const region = regionFrom(args);

    // Start from the LIVE frame: a queued backlog would otherwise
    // replay as a burst of "changes" that happened before the watch.
    _ = app.drainLive(CATCHUP_MS);
    const frame_at_start = app.frameCount(wid);
    var watch = app.watchChanges(wid, duration_ms, min_pct, region, max_events, thumbs) catch |err| switch (err) {
        appdrive.Error.NoSuchWindow => return errRes(arena, .not_found, "no such window (or it has not painted a frame yet)"),
        else => return appErr(arena, "watch failed"),
    };
    defer watch.deinit(app_state.allocator);

    var res = Res.init(arena);
    try res.fact("window", wid);
    try res.fact("elapsed_ms", watch.elapsed_ms);
    try res.fact("frames", watch.frames);
    try res.fact("frame_first", watch.frame_first);
    try res.fact("frame_last", watch.frame_last);
    try res.fact("frame_at_start", frame_at_start);
    try res.fact("min_change_pct", min_pct);
    try res.fact("truncated", watch.truncated);
    try res.fact("exited_during_watch", watch.exited);
    var ew: std.Io.Writer.Allocating = .init(arena);
    try ew.writer.writeAll("[");
    for (watch.events, 0..) |e, i| {
        if (i > 0) try ew.writer.writeAll(",");
        try ew.writer.print("{{\"at_ms\":{d},\"pct\":{d:.2},\"frame\":{d}}}", .{ e.at_ms, e.pct, e.frame });
    }
    try ew.writer.writeAll("]");
    try res.raw("events", ew.written());

    try res.textf("watched window {d} for {d}ms{s} — it committed {d} frame(s) (frame {d} -> {d})", .{
        wid,
        watch.elapsed_ms,
        if (region != null) ", change gauged inside the given region" else "",
        watch.frames,
        watch.frame_first,
        watch.frame_last,
    });
    if (watch.events.len == 0) {
        if (watch.frames == 0) {
            try res.textf(
                "NO frames at all: the window did not paint once in {d}ms. For an idle event-driven app that is normal (nothing asked it to redraw); for one that should be animating, or one you just sent input to, it is the signature of a hang — app_backtrace shows where the process is.",
                .{watch.elapsed_ms},
            );
        } else {
            try res.textf(
                "NO change of {d:.1}% or more happened at any point. The window IS painting, so this is a real observation and not a missed sample: the content simply never changed materially. Lower min_change_pct to catch smaller updates.",
                .{min_pct},
            );
        }
    } else {
        if (watch.truncated)
            try res.textf("timeline capped at {d} entries — more changes occurred; raise max_events or raise min_change_pct", .{max_events});
        if (watch.events.len == 1) {
            try res.textf(
                "ONE change, at t={d}ms. A screenshot taken before that moment would have shown nothing happening — that delay is the action's real latency.",
                .{watch.events[0].at_ms},
            );
        }
    }
    if (watch.exited) try res.text("the app EXITED during the watch (details below)");
    try res.textf("pass min_frame:{d} to screenshot_app for a capture provably newer than the start of this watch", .{frame_at_start});
    try addAppSummary(&res, arena, app);

    // Thumbnails: encoded AFTER the watch, from stashed pixels, so PNG
    // encoding never perturbs the sampling it is describing.
    var pngs: std.ArrayList([]const u8) = .empty;
    defer {
        for (pngs.items) |p| app_state.allocator.free(p);
        pngs.deinit(arena);
    }
    for (watch.events) |e| {
        if (e.px.len == 0) continue;
        const shot = app.encodePixelsPng(e.px, e.w, e.h, e.format, e.frame, max_px, region, 1, &.{}) catch continue;
        try pngs.append(arena, shot.png);
    }
    if (watch.events.len > 0) {
        var tw: std.Io.Writer.Allocating = .init(arena);
        try tw.writer.print("--- timeline (each entry measured against the previous, threshold {d:.1}%) ---", .{min_pct});
        for (watch.events, 0..) |e, i| {
            try tw.writer.print("\n[{d}] t={d}ms changed {d:.1}% of pixels (frame {d})", .{ i + 1, e.at_ms, e.pct, e.frame });
        }
        try res.text(tw.written());
    }
    if (pngs.items.len == 0) return res.finish();
    try res.fact("thumbnails", pngs.items.len);
    try res.textf("{d} thumbnail(s) below, in timeline order", .{pngs.items.len});
    return res.finishWithImages(pngs.items, null);
}

/// app_hover_map: sweep the pointer over a grid and report which cells
/// made the window repaint.
///
/// For an app with no accessibility tree there is otherwise no way to
/// find what is clickable except guessing coordinates, and a piece of
/// background art that happens to be a door is unguessable. This needs
/// no cooperation from the target: it is the same pixel diff every
/// other verdict here is built on, applied to hover.
fn hoverMap(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
    if (wid == 0) return errRes(arena, .not_found, "no rendered window yet");
    const dims = app.windowSize(wid) orelse return errRes(arena, .not_found, "no such window (or it has not painted yet)");
    const region: appdrive.App.Region = regionFrom(args) orelse .{
        .x = 0,
        .y = 0,
        .w = @intCast(@max(dims.w, 0)),
        .h = @intCast(@max(dims.h, 0)),
    };
    if (region.w == 0 or region.h == 0) return errRes(arena, .invalid_args, "empty region");
    const cols: usize = @intCast(std.math.clamp(argInt(args, "cols") orelse 12, 2, 40));
    const rows: usize = @intCast(std.math.clamp(argInt(args, "rows") orelse 9, 2, 40));
    const probes = cols * rows;
    const MAX_PROBES = 600;
    if (probes > MAX_PROBES)
        return errRes(arena, .invalid_args, "cols*rows exceeds 600 probes — narrow the region or use a coarser grid, then re-sweep the interesting part");
    const settle_ms: i64 = std.math.clamp(argInt(args, "settle_ms") orelse 120, 20, 2_000);
    const min_pct = argFloat(args, "min_change_pct") orelse 0.05;
    // Every probe can burn its full settle, so the worst case is the
    // budget. Refuse with the arithmetic rather than start a sweep the
    // call watchdog will cut off half-finished.
    const worst_ms = @as(i64, @intCast(probes)) * settle_ms;
    if (worst_ms > mcp.WAIT_CAP_MS) {
        return errRes(arena, .invalid_args, try std.fmt.allocPrint(
            arena,
            "{d} probes at {d}ms each is up to {d}ms, over the {d}ms cap on a single call. Use a coarser grid, a smaller settle_ms, or sweep a region at a time.",
            .{ probes, settle_ms, worst_ms, mcp.WAIT_CAP_MS },
        ));
    }

    // A continuously-animating app repaints regardless of the pointer,
    // which would mark every cell as interactive. Establish that BEFORE
    // sweeping: a map that cannot mean anything must not be produced.
    _ = app.drainLive(CATCHUP_MS);
    var self_changes: usize = 0;
    var control: usize = 0;
    while (control < 3) : (control += 1) {
        var ref = app.frameRef(wid, true) orelse return errRes(arena, .not_found, "no such window");
        defer ref.deinit(app_state.allocator);
        if (app.waitChangeSince(wid, &ref, settle_ms, min_pct, null)) self_changes += 1;
    }
    if (self_changes >= 2) {
        return errRes(arena, .conflict, try std.fmt.allocPrint(
            arena,
            "this window repaints by itself ({d} of 3 control samples changed by {d:.2}% with the pointer held still), so a hover map cannot separate the app's own animation from a hover response. Raise min_change_pct above the animation's amplitude (measure it with app_watch) or scope the sweep to a still region.",
            .{ self_changes, min_pct },
        ));
    }

    const restore = app.pointerPos();
    const cell_w = @as(f64, @floatFromInt(region.w)) / @as(f64, @floatFromInt(cols));
    const cell_h = @as(f64, @floatFromInt(region.h)) / @as(f64, @floatFromInt(rows));
    const map = try arena.alloc(f64, probes);
    @memset(map, 0);
    var hits: usize = 0;
    const t0 = nowMs();
    var stopped = false;
    var r: usize = 0;
    outer: while (r < rows) : (r += 1) {
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            if (app.exited) {
                stopped = true;
                break :outer;
            }
            const px = @as(f64, @floatFromInt(region.x)) + (@as(f64, @floatFromInt(col)) + 0.5) * cell_w;
            const py = @as(f64, @floatFromInt(region.y)) + (@as(f64, @floatFromInt(r)) + 0.5) * cell_h;
            var ref = app.frameRef(wid, true) orelse {
                stopped = true;
                break :outer;
            };
            defer ref.deinit(app_state.allocator);
            _ = app.moveMouse(wid, px, py) catch continue;
            if (app.waitChangeSince(wid, &ref, settle_ms, min_pct, null)) {
                map[r * cols + col] = app.peekChangeVs(wid, &ref, null);
                hits += 1;
            }
        }
    }
    if (restore) |p| _ = app.moveMouse(p.win, p.x, p.y) catch {};

    var res = Res.init(arena);
    try res.fact("window", wid);
    try res.raw("region", try std.fmt.allocPrint(arena, "{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}", .{ region.x, region.y, region.w, region.h }));
    try res.fact("cols", cols);
    try res.fact("rows", rows);
    try res.fact("probes", probes);
    try res.fact("elapsed_ms", nowMs() - t0);
    try res.fact("settle_ms", settle_ms);
    try res.fact("min_change_pct", min_pct);
    try res.fact("stopped_early", stopped);
    try res.fact("hits", hits);
    try res.textf("hover map of window {d} over ({d},{d}) {d}x{d}: {d}x{d} grid, {d} probes in {d}ms ({d}ms settle, threshold {d:.2}%)", .{
        wid, region.x, region.y, region.w, region.h, cols, rows, probes, nowMs() - t0, settle_ms, min_pct,
    });
    if (stopped) try res.text("the sweep STOPPED EARLY (the app exited or the window vanished) — the map below is partial");

    // The responding cells, with the surface coordinates a click wants.
    var cw: std.Io.Writer.Allocating = .init(arena);
    try cw.writer.writeAll("[");
    var first_hit = true;
    r = 0;
    while (r < rows) : (r += 1) {
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            const pct = map[r * cols + col];
            if (pct <= 0) continue;
            const px = @as(f64, @floatFromInt(region.x)) + (@as(f64, @floatFromInt(col)) + 0.5) * cell_w;
            const py = @as(f64, @floatFromInt(region.y)) + (@as(f64, @floatFromInt(r)) + 0.5) * cell_h;
            if (!first_hit) try cw.writer.writeAll(",");
            first_hit = false;
            try cw.writer.print("{{\"x\":{d},\"y\":{d},\"pct\":{d:.2}}}", .{
                @as(i64, @intFromFloat(px)), @as(i64, @intFromFloat(py)), pct,
            });
        }
    }
    try cw.writer.writeAll("]");
    try res.raw("cells", cw.written());

    if (hits == 0) {
        try res.text("NO cell produced a repaint. This app may simply not draw hover feedback — that is common for framebuffer games, and it does NOT mean nothing there is clickable. Lower min_change_pct, or fall back to app_read_text / app_find_image.");
    } else {
        try res.textf("{d} cell(s) responded to hover. A cell is one grid step wide, so the centres below are approximate — re-sweep a promising area with a region + finer grid to localise it.", .{hits});
    }
    try addAppSummary(&res, arena, app);

    var mw: std.Io.Writer.Allocating = .init(arena);
    try mw.writer.writeAll("--- map (# = responded to hover) ---");
    r = 0;
    while (r < rows) : (r += 1) {
        try mw.writer.writeAll("\n");
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            try mw.writer.writeByte(if (map[r * cols + col] > 0) '#' else '.');
        }
    }
    if (hits > 0) {
        try mw.writer.writeAll("\nclick centres in surface coordinates:");
        r = 0;
        while (r < rows) : (r += 1) {
            var col: usize = 0;
            while (col < cols) : (col += 1) {
                const pct = map[r * cols + col];
                if (pct <= 0) continue;
                const px = @as(f64, @floatFromInt(region.x)) + (@as(f64, @floatFromInt(col)) + 0.5) * cell_w;
                const py = @as(f64, @floatFromInt(region.y)) + (@as(f64, @floatFromInt(r)) + 0.5) * cell_h;
                try mw.writer.print("\n({d},{d})  {d:.2}%", .{ @as(i64, @intFromFloat(px)), @as(i64, @intFromFloat(py)), pct });
            }
        }
    }
    try res.text(mw.written());
    return res.finish();
}

/// app_backtrace: what a crash gets for free and a hang never did.
///
/// A crashing app dumps a sanitizer/gdb report into the log ring. A
/// HUNG one produces nothing, and `gdb -p` from the calling session
/// fails: Linux Yama only lets an ancestor trace, and the app's
/// ancestor is the daemon. So the daemon takes the backtrace.
fn appBacktrace(arena: std.mem.Allocator, _: Tool, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const debugger_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 20_000, 2_000, 100_000);
    // Outlast the daemon-side deadline: the reply to a timed-out
    // debugger is still a reply, and giving up first would throw away
    // the partial dump it carries.
    const raw = app.debugBacktrace(debugger_ms, debugger_ms + 10_000) catch |err| switch (err) {
        appdrive.Error.Timeout => return errRes(arena, .timeout, "the daemon did not answer the debug request in time"),
        else => return errRes(arena, .unavailable, "debug request failed (app gone?)"),
    };
    defer app_state.allocator.free(raw);

    const Reply = struct {
        ok: bool = false,
        pid: i32 = 0,
        tool: []const u8 = "",
        text: []const u8 = "",
        truncated: bool = false,
        timed_out: bool = false,
        took_ms: i64 = 0,
        @"error": []const u8 = "",
    };
    var parsed = std.json.parseFromSlice(Reply, arena, raw, .{ .ignore_unknown_fields = true }) catch
        return appErr(arena, "malformed debug reply from the daemon");
    defer parsed.deinit();
    const rep = parsed.value;
    if (rep.@"error".len > 0 and rep.text.len == 0)
        return errRes(arena, .unavailable, try std.fmt.allocPrint(arena, "no backtrace: {s}", .{rep.@"error"}));

    var res = Res.init(arena);
    try res.fact("debugger_pid", rep.pid);
    try res.fact("debugger", rep.tool);
    try res.fact("took_ms", rep.took_ms);
    try res.fact("timed_out", rep.timed_out);
    try res.fact("truncated", rep.truncated);
    try res.fact("backtrace", rep.text);
    if (rep.timed_out) {
        try res.textf("PARTIAL: {s}", .{rep.@"error"});
    } else {
        try res.textf("{s} attached to pid {d} on the daemon host and reported in {d}ms.", .{ rep.tool, rep.pid, rep.took_ms });
    }
    try res.text("The app was STOPPED while this was taken and has been resumed; wall-clock timings across this call are not meaningful.");
    if (rep.truncated) try res.text("output truncated at the daemon's cap — the head is retained");
    try addAppSummary(&res, arena, app);
    try res.textf("--- backtrace ---\n{s}", .{std.mem.trimEnd(u8, rep.text, "\n")});
    return res.finish();
}

/// Verdict for a `min_frames` wait that fell short.
///
/// Falling short is USUALLY arithmetic, not a fault: an app painting at
/// 12fps cannot deliver 1400 frames inside 115s no matter how healthy
/// it is. Reporting that as "it is not painting (frozen…)" was a false
/// alarm frequent enough to train callers into ignoring the message —
/// the worst possible reflex, because the identical sentence is how a
/// REAL freeze announces itself. Only zero frames makes a liveness
/// claim now; anything else states the rate and the arithmetic.
fn shortFramesVerdict(
    arena: std.mem.Allocator,
    wid: u32,
    got: u64,
    want: u64,
    elapsed_ms: i64,
    timeout_ms: i64,
) ![]const u8 {
    if (got == 0) {
        return std.fmt.allocPrint(
            arena,
            "NOT LIVE: window {d} committed NO frames at all in {d}ms — it is not painting. That is frozen, minimised, or rendering into another window IF it was supposed to be drawing; an idle event-driven app legitimately commits nothing until something asks it to redraw. app_backtrace settles which one.",
            .{ wid, timeout_ms },
        );
    }
    const elapsed = @max(elapsed_ms, 1);
    const fps = @as(f64, @floatFromInt(got)) * 1000.0 / @as(f64, @floatFromInt(elapsed));
    const need_ms: i64 = @intFromFloat(@as(f64, @floatFromInt(want)) * 1000.0 / @max(fps, 0.001));
    return std.fmt.allocPrint(
        arena,
        "the app IS painting, at about {d:.1} fps — but {d} frames at that rate needs roughly {d}ms and the timeout was {d}ms, so only {d} arrived. That is arithmetic, not a fault: raise timeout_ms, lower min_frames, or wait on something real (app_wait_log / app_watch).",
        .{ fps, want, need_ms, timeout_ms, got },
    );
}

test "a min_frames shortfall only claims NOT LIVE when nothing painted" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The field case: ~12fps, 1400 frames wanted, 115s timeout. The app
    // was painting perfectly and the old wording called it frozen.
    const slow = try shortFramesVerdict(arena, 1, 1243, 1400, 115_000, 115_000);
    try t.expect(std.mem.indexOf(u8, slow, "IS painting") != null);
    try t.expect(std.mem.indexOf(u8, slow, "NOT LIVE") == null);
    try t.expect(std.mem.indexOf(u8, slow, "frozen") == null);
    try t.expect(std.mem.indexOf(u8, slow, "10.8 fps") != null);

    // A genuine freeze keeps the alarm — and points at the tool that
    // can say where it is stuck.
    const dead = try shortFramesVerdict(arena, 2, 0, 10, 5_000, 5_000);
    try t.expect(std.mem.indexOf(u8, dead, "NOT LIVE") != null);
    try t.expect(std.mem.indexOf(u8, dead, "app_backtrace") != null);
}

test "app recordings use private complete replacement" {
    const t = std.testing;
    var tmpl = "/tmp/sketerm-app-recording-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/capture.webm", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);

    try saveRecording(path, "recording");
    var st: c.struct_stat = undefined;
    try t.expect(c.stat(path_z.ptr, &st) == 0);
    try t.expectEqual(@as(c_uint, 0o600), @as(c_uint, @intCast(st.st_mode & 0o777)));
}

test "stepBudget reports whether the batch budget shortened the wait" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Budget wide open: the request is honoured and nothing is clipped,
    // so a timeout there IS an observation about the app.
    const roomy = stepBudget(5_000, nowMs() + mcp.WAIT_CAP_MS);
    try t.expectEqual(@as(i64, 5_000), roomy.ms);
    try t.expect(!roomy.clipped);
    try t.expectEqualStrings("", try clipNote(arena, roomy));

    // Nearly spent: the wait is cut short and must say so.
    const tight = stepBudget(30_000, nowMs() + 400);
    try t.expect(tight.ms <= 400);
    try t.expect(tight.clipped);
    try t.expectEqual(@as(i64, 30_000), tight.requested);
    const note = try clipNote(arena, tight);
    try t.expect(std.mem.indexOf(u8, note, "clipped") != null);
    try t.expect(std.mem.indexOf(u8, note, "not an app verdict") != null);

    // Spent: zero left, and a request for any wait at all is clipped.
    const spent = stepBudget(1_000, nowMs() - 1);
    try t.expectEqual(@as(i64, 0), spent.ms);
    try t.expect(spent.clipped);
    // Asking for nothing is not a clip.
    try t.expect(!stepBudget(0, nowMs() - 1).clipped);

    // The per-wait cap is a clip too: an over-cap request is shortened.
    const over = stepBudget(mcp.WAIT_CAP_MS + 1, nowMs() + 10 * mcp.WAIT_CAP_MS);
    try t.expectEqual(mcp.WAIT_CAP_MS, over.ms);
    try t.expect(over.clipped);
}

test "a clipped step reports wait_clipped as a fact, not as prose only" {
    const t = std.testing;
    const clipped = stepOutcome(3, false, "step 3: ERROR - wait_idle did not settle before timeout (required)\n", true);
    try t.expect(clipped.wait_clipped);
    try t.expect(!clipped.ok);
    try t.expectEqual(@as(usize, 3), clipped.step);
    const plain = stepOutcome(1, true, "step 1: wait_idle settled\n", false);
    try t.expect(!plain.wait_clipped);
}

test "app_macros show re-serializes the stored macro, never echoes it" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dirbuf = "/tmp/sketerm-macroshow-XXXXXX".*;
    const dir_z = c.mkdtemp(&dirbuf) orelse return error.SkipZigTest;
    const dir = std.mem.span(@as([*:0]u8, @ptrCast(dir_z)));
    var envbuf: [160]u8 = undefined;
    const env = try std.fmt.bufPrintZ(&envbuf, "{s}", .{dir});
    _ = c.setenv("XDG_STATE_HOME", env, 1);
    var zbuf: [4096]u8 = undefined;
    defer {
        _ = c.unsetenv("XDG_STATE_HOME");
        if (std.fmt.bufPrintZ(&zbuf, "{s}/sketerm/macros/pretty.json", .{dir})) |f| {
            _ = c.unlink(f.ptr);
        } else |_| {}
        if (std.fmt.bufPrintZ(&zbuf, "{s}/sketerm/macros", .{dir})) |d| _ = c.rmdir(d.ptr) else |_| {}
        if (std.fmt.bufPrintZ(&zbuf, "{s}/sketerm", .{dir})) |d| _ = c.rmdir(d.ptr) else |_| {}
        _ = c.rmdir(dir_z);
    }

    // The macro store is an ordinary directory shared across instances,
    // so a stored document may be pretty-printed. Echoing its bytes put
    // raw newlines into structuredContent and split the NDJSON line.
    try mcpassets.save(t.allocator, .macro, "pretty", "{\n  \"actions\": [\n    {\"wait\": 100}\n  ]\n}\n");

    app_state.ready = true;
    defer app_state.ready = false;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"show\":\"pretty\"}", .{});
    const result = try appTool(arena, .app_macros, args);
    const parsed = try mcp.expectToolResultShape(arena, "app_macros", result);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqual(@as(i64, 1), sc.get("steps").?.integer);
    const actions = sc.get("actions").?.object.get("actions").?.array;
    try t.expectEqual(@as(usize, 1), actions.items.len);
    try t.expectEqual(@as(i64, 100), actions.items[0].object.get("wait").?.integer);
}

test "burstMs defaults and clamps to the per-wait cap" {
    const t = std.testing;
    try t.expectEqual(@as(i64, 5_000), burstMs(null));
    try t.expectEqual(@as(i64, 250), burstMs(250));
    try t.expectEqual(mcp.WAIT_CAP_MS, burstMs(mcp.WAIT_CAP_MS + 1));
    try t.expectEqual(mcp.WAIT_CAP_MS, burstMs(std.math.maxInt(i64)));
    try t.expectEqual(@as(i64, 0), burstMs(-1));
}

// ── moved from mcp.zig ──────────────────────────────────────────

/// Long-lived registry of launched app sessions (module state: MCP
/// serves one assistant on stdio; tool calls are sequential).
pub const AppState = struct {
    allocator: std.mem.Allocator,
    apps: std.AutoArrayHashMapUnmanaged(u32, *appdrive.App) = .empty,
    next_id: u32 = 1,
    ready: bool = true,
    /// Socket of the private (isolated) daemon local app launches
    /// target; null = the shared per-user daemon.
    mux_sock: ?[]const u8 = null,
    /// Durable instance: on exit, detach from app sessions instead of
    /// killing them (they outlive the MCP process for reconnect).
    keep_apps: bool = false,

    /// Idempotent: run() calls it explicitly before retiring an
    /// ephemeral daemon, and again via defer.
    pub fn deinit(self: *AppState) void {
        if (!self.ready) return;
        for (self.apps.values()) |app| {
            if (self.keep_apps) app.detach() else app.deinit();
        }
        self.apps.deinit(self.allocator);
        self.apps = .empty;
        self.ready = false;
    }
};

pub var app_state: AppState = .{ .allocator = undefined, .ready = false };

/// Reconnect a durable instance to app sessions still running on its
/// private daemon, so `list_apps` etc. see them after an MCP restart.
/// Best-effort: no daemon (or none attachable) just means no apps.
pub fn reattachApps(sock: []const u8) void {
    const a = app_state.allocator;
    const refs = appdrive.listAppSessions(a, sock) catch return;
    defer {
        for (refs) |r| a.free(r.name);
        a.free(refs);
    }
    for (refs) |r| {
        const origin_id = r.originId();
        const app = appdrive.App.attachExisting(
            a,
            r.name,
            null,
            sock,
            if (origin_id.len > 0) origin_id else null,
        ) catch continue;
        app.pid = r.pid;
        const id = app_state.next_id;
        app_state.next_id += 1;
        app_state.apps.put(a, id, app) catch {
            app.detach();
            continue;
        };
        // Let the attach replay build the windows before the first
        // tool call reads them (bounded; frames are already in flight).
        _ = app.waitFirstWindow(1500);
    }
}

pub fn appFromArgs(args: std.json.Value) ?*appdrive.App {
    const id = argInt(args, "app") orelse {
        // Single-app convenience: omit `app` when only one exists.
        if (app_state.apps.count() == 1) return app_state.apps.values()[0];
        // Several sessions, but only one still running: an exited app
        // lingers in the table until close_app and must not make a
        // live drive ambiguous.
        var live: ?*appdrive.App = null;
        var live_n: usize = 0;
        for (app_state.apps.values()) |a| {
            if (a.exited) continue;
            live_n += 1;
            live = a;
        }
        return if (live_n == 1) live else null;
    };
    if (id < 0) return null;
    return app_state.apps.get(@intCast(id));
}

/// "app 7 (alive, 2 windows), app 8 (exited, status 0)" — the roster
/// an app-selection error needs to be actionable.
fn appRoster(arena: std.mem.Allocator) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    var it = app_state.apps.iterator();
    var first = true;
    while (it.next()) |e| {
        if (!first) w.writeAll(", ") catch return aw.written();
        first = false;
        const a = e.value_ptr.*;
        var painted: usize = 0;
        for (a.windows.items) |win| {
            if (win.frames > 0) painted += 1;
        }
        if (a.exited) {
            w.print("app {d} (exited, status {d})", .{ e.key_ptr.*, a.exit_status }) catch return aw.written();
        } else {
            w.print("app {d} (alive, {d} window(s))", .{ e.key_ptr.*, painted }) catch return aw.written();
        }
    }
    return aw.written();
}

pub const AppSelect = union(enum) { app: *appdrive.App, err: []const u8 };

/// Resolve the `app` argument, keeping apart the three failure modes
/// the old single "unknown app" message conflated: no sessions at all,
/// an id that does not exist, and an OMITTED id with several
/// candidates. The last one used to read exactly like a crashed app,
/// which is a costly thing to misdiagnose mid-drive.
pub fn appSelect(arena: std.mem.Allocator, args: std.json.Value) AppSelect {
    if (appFromArgs(args)) |a| return .{ .app = a };
    if (app_state.apps.count() == 0)
        return .{ .err = "no app sessions exist — start one with launch_app (this is NOT a crash: nothing was ever launched in this server)" };
    const roster = appRoster(arena);
    if (argInt(args, "app")) |id| {
        const msg = std.fmt.allocPrint(arena, "no app has id {d} (it was closed, or the id is from another MCP server). Known: {s}", .{ id, roster }) catch return .{ .err = "no app with that id" };
        return .{ .err = msg };
    }
    const msg = std.fmt.allocPrint(arena, "'app' was not specified and several sessions are alive — this is AMBIGUOUS, not a dead app. Pass app:<id>. Known: {s}", .{roster}) catch
        return .{ .err = "'app' is ambiguous — pass app:<id> (list them with list_apps)" };
    return .{ .err = msg };
}

pub fn appIdOf(app: *appdrive.App) u32 {
    var it = app_state.apps.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == app) return e.key_ptr.*;
    }
    return 0;
}

/// Human name for the common fatal signals (exit_status = -signo).
pub fn signalName(signo: i32) []const u8 {
    return switch (signo) {
        1 => "SIGHUP",
        2 => "SIGINT",
        4 => "SIGILL",
        6 => "SIGABRT",
        7 => "SIGBUS",
        8 => "SIGFPE",
        9 => "SIGKILL",
        11 => "SIGSEGV",
        13 => "SIGPIPE",
        15 => "SIGTERM",
        else => "signal",
    };
}

/// Signals whose death means "the app crashed" (as opposed to being
/// told to stop).
fn crashSignal(signo: i32) bool {
    return switch (signo) {
        4, 6, 7, 8, 11 => true, // ILL, ABRT, BUS, FPE, SEGV
        else => false,
    };
}

/// Human-readable death suffix for an exit status; "" for plain codes.
/// Shell-wrapped commands (string `command`) report a child's signal
/// death as exit 128+signo — decode that too, flagged as inferred.
pub fn exitSuffix(arena: std.mem.Allocator, status: i32) ![]const u8 {
    if (status < 0)
        return std.fmt.allocPrint(arena, " = killed by {s} (signal {d})", .{ signalName(-status), -status });
    if (status >= 129 and status <= 128 + 31)
        return std.fmt.allocPrint(arena, " (= 128+{d}: the wrapping shell reports the app was killed by {s})", .{ status - 128, signalName(status - 128) });
    return "";
}

fn signalNumber(name: []const u8) ?i32 {
    const names = [_]struct { name: []const u8, number: i32 }{
        .{ .name = "SIGHUP", .number = 1 },
        .{ .name = "SIGINT", .number = 2 },
        .{ .name = "SIGILL", .number = 4 },
        .{ .name = "SIGABRT", .number = 6 },
        .{ .name = "SIGBUS", .number = 7 },
        .{ .name = "SIGFPE", .number = 8 },
        .{ .name = "SIGKILL", .number = 9 },
        .{ .name = "SIGSEGV", .number = 11 },
        .{ .name = "SIGPIPE", .number = 13 },
        .{ .name = "SIGTERM", .number = 15 },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.number;
    }
    return null;
}

/// Recover an inferior signal from gdb/valgrind output when the wrapper survives it.
fn debuggerSignal(log_json: []const u8) ?i32 {
    const prefixes = [_][]const u8{
        "Program received signal ",
        "Process terminating with default action of signal ",
    };
    for (prefixes) |prefix| {
        const at = std.mem.indexOf(u8, log_json, prefix) orelse continue;
        const rest = log_json[at + prefix.len ..];
        if (prefix[0] == 'P' and std.mem.startsWith(u8, prefix, "Process ")) {
            const open = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
            const close_rel = std.mem.indexOfScalar(u8, rest[open + 1 ..], ')') orelse continue;
            const close = open + 1 + close_rel;
            if (signalNumber(rest[open + 1 .. close])) |sig| return sig;
            continue;
        }
        var end: usize = 0;
        while (end < rest.len and ((rest[end] >= 'A' and rest[end] <= 'Z') or (rest[end] >= '0' and rest[end] <= '9'))) end += 1;
        if (signalNumber(rest[0..end])) |sig| return sig;
    }
    return null;
}

const AppStopReason = enum { process_exit, client_disconnected, last_toplevel_destroyed };

pub const AppStop = struct {
    reason: AppStopReason,
    exit_status: ?i32 = null,
    signal: ?i32 = null,

    pub fn reasonName(self: AppStop) []const u8 {
        return switch (self.reason) {
            .process_exit => "process_exit",
            .client_disconnected => "client_disconnected",
            .last_toplevel_destroyed => "last_toplevel_destroyed",
        };
    }
};

/// Join process exit and GUI disappearance into one interaction-stop verdict.
pub fn probeAppStop(app: *appdrive.App, settle_ms: i64) ?AppStop {
    if (!app.exited and !app.presentationGone()) return null;
    if (!app.exited and settle_ms > 0) _ = app.settleExit(settle_ms);

    // A live debugger wrapper still has an indexed daemon-side log.
    // Fetch it now so the inferior's signal wins over the wrapper's
    // eventual status 0. Failure still leaves an honest disconnect.
    if (!app.exited and app.presentationGone() and debuggerSignal(app.log_buf.items) == null) {
        const fetched = app.logGet("{\"tail\":80,\"from_id\":0,\"id\":0,\"max_chars\":300}", 1_000) catch null;
        if (fetched) |f| app.allocator.free(f.json);
    }
    const inferred_signal = debuggerSignal(app.log_buf.items);
    if (app.exited) {
        const status_signal: ?i32 = if (app.exit_status < 0)
            -app.exit_status
        else if (app.exit_status >= 129 and app.exit_status <= 159)
            app.exit_status - 128
        else
            null;
        return .{
            .reason = .process_exit,
            .exit_status = app.exit_status,
            .signal = inferred_signal orelse status_signal,
        };
    }
    const reason: AppStopReason = switch (app.presentation_gone.?) {
        .client_disconnected => .client_disconnected,
        .last_toplevel_destroyed => .last_toplevel_destroyed,
    };
    return .{ .reason = reason, .signal = inferred_signal };
}

pub fn appStopText(arena: std.mem.Allocator, stop: AppStop, context: []const u8) ![]const u8 {
    if (stop.signal) |sig| {
        return std.fmt.allocPrint(arena, "app EXITED during {s} ({s}, signal {d}) - see app_log for the backtrace", .{ context, signalName(sig), sig });
    }
    if (stop.exit_status) |status| {
        return std.fmt.allocPrint(arena, "app exited during {s} (status {d})", .{ context, status });
    }
    return std.fmt.allocPrint(arena, "app EXITED/disconnected during {s} ({s}; exit status unavailable) - see app_log for details", .{ context, stop.reasonName() });
}

/// The daemon's log_get reply / pre-exit log stash, JSON shape.
pub const LogLineJ = struct {
    id: u64 = 0,
    t: i64 = 0,
    text: []const u8 = "",
    truncated: bool = false,
    cut: bool = false,
    marker: bool = false,
};
pub const LogReplyJ = struct {
    next_id: u64 = 0,
    dropped: u64 = 0,
    markers_dropped: u64 = 0,
    lines: []const LogLineJ = &.{},
};

/// Compile the `pattern` (alias `grep`) argument of a log tool.
/// `.none` = the caller passed neither, so nothing is filtered.
pub const LogFilter = union(enum) {
    none,
    m: pattern.Matcher,
    err: []const u8,
};

pub fn logFilterFrom(arena: std.mem.Allocator, args: std.json.Value) LogFilter {
    const pat = argStr(args, "pattern") orelse argStr(args, "grep") orelse return .none;
    const ci = if (args == .object and args.object.get("ignore_case") != null)
        argBool(args, "ignore_case")
    else
        true;
    const m = pattern.compile(arena, pat, ci) catch |err| return .{ .err = switch (err) {
        pattern.Error.BadPattern => std.fmt.allocPrint(
            arena,
            "cannot compile pattern \"{s}\". The syntax is a documented SUBSET of regex: literal text, . [a-z] [^x] classes, * + ? quantifiers, ^ $ anchors and top-level | alternation. There are no groups, so ( and ) are literal characters.",
            .{pat},
        ) catch "bad pattern",
        else => "out of memory compiling the pattern",
    } };
    return .{ .m = m };
}

/// Fetch a slice of the app's log ring and parse it. `from_id` 0 =
/// the last `tail` lines.
pub fn logFetchLines(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    from_id: u64,
    tail: i64,
    max_chars: i64,
    timeout_ms: i64,
) !struct { reply: LogReplyJ, stale: bool } {
    const req = try std.fmt.allocPrint(
        arena,
        "{{\"tail\":{d},\"from_id\":{d},\"id\":0,\"max_chars\":{d}}}",
        .{ tail, from_id, max_chars },
    );
    const fetch = try app.logGet(req, timeout_ms);
    defer app_state.allocator.free(fetch.json);
    const parsed = std.json.parseFromSliceLeaky(LogReplyJ, arena, fetch.json, .{
        .ignore_unknown_fields = true,
    }) catch return error.Malformed;
    return .{ .reply = parsed, .stale = fetch.stale };
}

/// Per-app high-water mark of log ids already handed to an input
/// tool's `include_log_delta`. The crash-hunting loop is invariably
/// click → look → app_log → diff against last time; this collapses it
/// into the click call.
pub const LogDelta = struct {
    var seen: std.AutoArrayHashMapUnmanaged(u32, u64) = .empty;

    fn get(id: u32) ?u64 {
        return seen.get(id);
    }
    fn set(id: u32, v: u64) void {
        seen.put(app_state.allocator, id, v) catch {};
    }
    pub fn deinitAll() void {
        seen.deinit(app_state.allocator);
        seen = .empty;
    }
};

/// "\nlog +N line(s) since the previous input: …" for an input tool
/// called with include_log_delta:true; "" otherwise. The FIRST call
/// for an app only establishes the baseline (dumping the whole
/// pre-existing log into a click reply would bury the delta it exists
/// to show) — read history with app_log.
pub fn logDeltaNote(arena: std.mem.Allocator, app: *appdrive.App, args: std.json.Value) []const u8 {
    if (!argBool(args, "include_log_delta")) return "";
    const MAX_SHOWN = 40;
    const app_id = appIdOf(app);
    const prev = LogDelta.get(app_id);
    const from: u64 = if (prev) |p| p + 1 else 0;
    const got = logFetchLines(arena, app, from, 500, 300, 3_000) catch
        return "\nlog delta: unavailable (the daemon's log reply did not arrive in time — read it with app_log)";
    const r = got.reply;
    if (r.next_id > 0) LogDelta.set(app_id, r.next_id - 1);
    if (prev == null)
        return std.fmt.allocPrint(
            arena,
            "\nlog delta: baseline set at line {d} — the NEXT input with include_log_delta reports what the app printed in between (use app_log for the history before this point)",
            .{if (r.next_id > 0) r.next_id - 1 else 0},
        ) catch "";
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    var n: usize = 0;
    var shown: usize = 0;
    for (r.lines) |l| {
        if (l.id < from) continue;
        n += 1;
        if (shown >= MAX_SHOWN) continue;
        shown += 1;
        w.print("\n  {d} {s}{s}", .{ l.id, l.text, if (l.cut or l.truncated) " [+]" else "" }) catch break;
    }
    if (n == 0) return "\nlog delta: no new lines since the previous input";
    return std.fmt.allocPrint(arena, "\nlog delta: +{d} line(s) since the previous input{s}:{s}", .{
        n,
        if (n > shown) std.fmt.allocPrint(arena, " (newest {d} shown; read the rest with app_log)", .{shown}) catch "" else "",
        aw.written(),
    }) catch "";
}

/// Last `n` non-marker lines from the app's stashed log ring (the
/// daemon pushes the final log ahead of `.exit`), newline-joined.
/// Null when no stash exists or it holds no output lines — unlike the
/// grid mirror these lines are escape-free and never wrapped.
pub fn logStashTail(arena: std.mem.Allocator, app: *appdrive.App, n: usize) ?[]const u8 {
    if (app.log_buf.items.len == 0) return null;
    const parsed = std.json.parseFromSliceLeaky(LogReplyJ, arena, app.log_buf.items, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    if (parsed.lines.len == 0) return null;
    var kept: usize = 0;
    var start = parsed.lines.len;
    while (start > 0 and kept < n) {
        if (!parsed.lines[start - 1].marker) kept += 1;
        start -= 1;
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    var wrote = false;
    for (parsed.lines[start..]) |l| {
        if (l.marker) continue;
        if (wrote) aw.writer.writeAll("\n") catch return null;
        aw.writer.writeAll(l.text) catch return null;
        wrote = true;
    }
    if (!wrote) return null;
    return aw.written();
}

/// THE app-state vocabulary, in both lanes: `appFacts` writes the
/// machine facts into a `Res`, `appSummaryText` renders the same story
/// as prose. Every app tool that reports on its app calls
/// `addAppSummary` (both) — nothing spells an app fact by hand.
///
/// The two halves are deliberately one function pair: an exit reported
/// in structuredContent but missing from the text (or the reverse) is
/// the failure mode that made the old JSON-in-text summary safe.
pub fn appFacts(res: *Res, arena: std.mem.Allocator, app: *appdrive.App, with_windows: bool) !void {
    try res.fact("app", appIdOf(app));
    try res.fact("session", app.name);
    // The daemon-host pid: a debugger handle (`gdb -p`). For a string
    // command this is the wrapping /bin/sh, not the app itself.
    if (app.pid != 0 and !app.exited) try res.fact("pid", app.pid);
    const inferred_signal = debuggerSignal(app.log_buf.items);
    var crashed = false;
    try res.fact("exited", app.exited);
    if (app.exited) {
        try res.fact("exit_status", app.exit_status);
        // decodeStatus convention: negative = killed by that signal.
        if (app.exit_status < 0) {
            try res.fact("signaled", true);
            try res.fact("signal", -app.exit_status);
            try res.fact("signal_name", signalName(-app.exit_status));
            crashed = crashSignal(-app.exit_status);
        } else if (app.exit_status >= 129 and app.exit_status <= 128 + 31) {
            // A string `command` runs under /bin/sh, which reports a
            // child killed by signal N as exit 128+N.
            try res.fact("likely_signal", app.exit_status - 128);
            try res.fact("likely_signal_name", signalName(app.exit_status - 128));
            try res.fact("exit_status_note", try std.fmt.allocPrint(
                arena,
                "exit {d} = 128+{d}: shell-wrapped commands report signal deaths this way",
                .{ app.exit_status, app.exit_status - 128 },
            ));
            crashed = crashSignal(app.exit_status - 128);
        }
    } else if (app.presentation_gone) |reason| {
        try res.fact("app_gone", true);
        try res.fact("disconnect_reason", @tagName(reason));
    }
    if (inferred_signal) |sig| {
        try res.fact("debugger_caught_signal", true);
        try res.fact("inferior_signal", sig);
        try res.fact("inferior_signal_name", signalName(sig));
        if (crashSignal(sig)) crashed = true;
        // A debug wrapper survives the fault it catches and exits 0, so
        // the raw exit_status above describes GDB/valgrind, not the
        // app. Reading that as a clean exit is the whole trap.
        if (app.exited and app.exit_status >= 0) {
            try res.fact("exit_status_is_wrapper", true);
            try res.fact("exit_status_note", try std.fmt.allocPrint(
                arena,
                "exit_status {d} belongs to the DEBUG WRAPPER, which survived the fault; the app itself died on {s} (signal {d}) — inferior_signal is authoritative here",
                .{ app.exit_status, signalName(sig), sig },
            ));
        }
    }
    if (crashed) try res.fact("crashed", true);
    if (with_windows) {
        try res.raw("windows", try windowsJson(arena, app));
        const primary_id = firstToplevelId(app);
        if (primary_id != 0) try res.fact("primary_window", primary_id);
    }
    // An app that died is otherwise a dead end — inline what it
    // printed so one call shows WHY. The log-ring stash (pushed by
    // the daemon ahead of `.exit`) is preferred: escape-free FULL
    // lines, never wrapped at the grid width, includes scrolled-off
    // output. The rendered-grid tail is only the fallback.
    if (app.exited or app.presentationGone()) {
        if (recentOutput(arena, app)) |out| {
            try res.fact("recent_output", out.text);
            try res.fact("recent_output_source", out.source);
        }
        if (std.mem.indexOf(u8, app.log_buf.items, "Sanitizer") != null or
            std.mem.indexOf(u8, app.log_buf.items, "runtime error:") != null)
            try res.fact("sanitizer_report", true);
    }
}

/// The window array of `appFacts`, as verbatim JSON.
fn windowsJson(arena: std.mem.Allocator, app: *appdrive.App) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("[");
    var first = true;
    const primary_id = firstToplevelId(app);
    for (app.windows.items) |win| {
        if (win.frames == 0) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"window\":{d},\"w\":{d},\"h\":{d},\"scale\":{d},\"frames\":{d}", .{ win.id, win.w, win.h, win.scale, win.frames });
        // The default target for window-less tool calls: the most
        // recently painted non-popup toplevel (see firstToplevelId).
        if (win.id == primary_id) try w.writeAll(",\"primary\":true");
        if (win.popup) try w.writeAll(",\"popup\":true");
        if (win.maximized) try w.writeAll(",\"maximized\":true");
        if (win.fullscreen) try w.writeAll(",\"fullscreen\":true");
        if (win.title) |t| {
            try w.writeAll(",\"title\":");
            try std.json.Stringify.value(t, .{}, w);
        }
        if (win.app_id) |aid| {
            try w.writeAll(",\"app_id\":");
            try std.json.Stringify.value(aid, .{}, w);
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");
    return aw.written();
}

const RecentOutput = struct { text: []const u8, source: []const u8 };

/// What a dead app last printed: the indexed log stash if the daemon
/// pushed one, else the rendered grid tail.
fn recentOutput(arena: std.mem.Allocator, app: *appdrive.App) ?RecentOutput {
    if (logStashTail(arena, app, 15)) |tail_text|
        return .{ .text = tail_text, .source = "app_log" };
    const text = app.output(false) catch return null;
    defer app_state.allocator.free(text);
    const tail = tailLines(text, 25);
    if (tail.len == 0) return null;
    return .{ .text = arena.dupe(u8, tail) catch return null, .source = "terminal_grid" };
}

/// Prose half of `appFacts`: identity, exit/disconnect verdict, the
/// window list, and (for a dead app) what it last printed — the
/// payload behind a `--- recent output ---` divider.
pub fn appSummaryText(arena: std.mem.Allocator, app: *appdrive.App) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("app {d} ({s})", .{ appIdOf(app), app.name });
    if (app.pid != 0 and !app.exited) try w.print(" pid {d}", .{app.pid});
    if (app.exited) {
        try w.print(" EXITED, status {d}{s}", .{ app.exit_status, try exitSuffix(arena, app.exit_status) });
    } else if (app.presentation_gone) |reason| {
        try w.print(" GONE from the compositor ({s})", .{@tagName(reason)});
    }
    if (debuggerSignal(app.log_buf.items)) |sig| {
        try w.print("\nthe debug wrapper caught {s} (signal {d}) — backtrace in app_log", .{ signalName(sig), sig });
        if (app.exited and app.exit_status >= 0)
            try w.writeAll("; the exit status above belongs to the WRAPPER, not the app");
    }
    if (std.mem.indexOf(u8, app.log_buf.items, "Sanitizer") != null or
        std.mem.indexOf(u8, app.log_buf.items, "runtime error:") != null)
        try w.writeAll("\na sanitizer wrote a report to stderr — read it in full with app_log");
    const primary_id = firstToplevelId(app);
    var shown: usize = 0;
    for (app.windows.items) |win| {
        if (win.frames == 0) continue;
        shown += 1;
        try w.print("\nwindow {d}: {d}x{d} scale {d} frame {d}", .{ win.id, win.w, win.h, win.scale, win.frames });
        if (win.id == primary_id) try w.writeAll(" primary");
        if (win.popup) try w.writeAll(" popup");
        if (win.title) |t| try w.print(" title={s}", .{t});
    }
    if (shown == 0) try w.writeAll("\nno rendered window");
    if (app.exited or app.presentationGone()) {
        if (recentOutput(arena, app)) |out|
            try w.print("\n--- recent output ({s}) ---\n{s}", .{ out.source, out.text });
    }
    return aw.written();
}

/// Both lanes of the app state at once — the one call every app tool
/// makes to report on its app.
pub fn addAppSummary(res: *Res, arena: std.mem.Allocator, app: *appdrive.App) !void {
    try appFacts(res, arena, app, true);
    try res.text(try appSummaryText(arena, app));
}

/// Screenshot caption: window identity + how to map image coordinates
/// back to app_click surface coordinates (crop origin + scale). One
/// line; anything else a caller wants to say is its own text line.
pub fn screenshotCaption(arena: std.mem.Allocator, app: *appdrive.App, win_id: u32, shot: appdrive.App.Shot) ![]const u8 {
    const win = app.winById(win_id) orelse return error.OutOfMemory;
    const coord_note = if (shot.scale == 1.0 and shot.ox == 0 and shot.oy == 0)
        try std.fmt.allocPrint(arena, "coordinates for app_click are this image's pixel coordinates", .{})
    else if (shot.ox == 0 and shot.oy == 0)
        try std.fmt.allocPrint(
            arena,
            "image is {d}x{d} for a {d}x{d} surface: MULTIPLY image coordinates by {d:.3} before app_click",
            .{ shot.img_w, shot.img_h, win.w, win.h, shot.scale },
        )
    else
        try std.fmt.allocPrint(
            arena,
            "cropped at ({d},{d}): MULTIPLY image coordinates by {d:.3} then ADD ({d},{d}) before app_click",
            .{ shot.ox, shot.oy, shot.scale, shot.ox, shot.oy },
        );
    return std.fmt.allocPrint(
        arena,
        "window {d}: {d}x{d} (scale {d}) frame {d}{s}{s} — {s}{s}",
        .{
            win.id,
            win.w,
            win.h,
            win.scale,
            // Freshness receipt: the window's commit counter for THESE
            // pixels. Assert against it with screenshot_app min_frame
            // instead of hoping a capture is not stale.
            shot.frame,
            if (win.title != null) " title=" else "",
            win.title orelse "",
            coord_note,
            // Set only when drainLive timed out: the frame stream is
            // still catching up, so pixels may lag the app.
            if (app.behind or app.lagging) " [WARNING: frame stream still catching up — this capture may lag the app; retry with wait_change or stable_ms]" else "",
        },
    );
}

// ── a11y tree helpers (element-targeted tools) ───────────────────

/// Fetch + parse the app's a11y tree into a Value (arena-owned), or
/// an error string to hand the assistant.
const A11yFetch = union(enum) {
    tree: std.json.Value,
    err: []const u8,
};

pub fn a11yFetch(arena: std.mem.Allocator, app: *appdrive.App, timeout_ms: i64) A11yFetch {
    const raw = app.a11yTree(timeout_ms) catch |err| return .{ .err = switch (err) {
        appdrive.Error.Timeout => "timed out reading the accessibility tree",
        else => "accessibility read failed",
    } };
    defer app_state.allocator.free(raw);
    const copy = arena.dupe(u8, raw) catch return .{ .err = "oom" };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, copy, .{}) catch
        return .{ .err = "malformed accessibility reply" };
    if (parsed != .object) return .{ .err = "malformed accessibility reply" };
    if (parsed.object.get("error")) |e| {
        if (e == .string) return .{ .err = e.string };
        return .{ .err = "accessibility error" };
    }
    const tree = parsed.object.get("tree") orelse return .{ .err = "no tree in reply" };
    return .{ .tree = tree };
}

/// Deepest nesting level below `node` (0 = no children).
fn a11yDepth(node: std.json.Value) u32 {
    if (node != .object) return 0;
    const kids = node.object.get("children") orelse return 0;
    if (kids != .array) return 0;
    var best: u32 = 0;
    for (kids.array.items) |k| best = @max(best, a11yDepth(k) + 1);
    return best;
}

/// True when the reply is the AT-SPI registry with only childless
/// application entries under it — nothing on the bus published a
/// single widget. A toolkit app always nests at least a window under
/// its application node, so this stays a conservative test: it never
/// calls a real (if shallow) tree "missing", it only recognises the
/// unmistakably empty case that otherwise reads as "you asked too
/// early".
pub fn a11yTreeIsBare(arena: std.mem.Allocator, reply_json: []const u8) bool {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, reply_json, .{}) catch return false;
    if (parsed != .object) return false;
    const tree = parsed.object.get("tree") orelse return false;
    return a11yDepth(tree) <= 1;
}

/// DFS for the first node matching `role` (when non-null) and/or a
/// case-insensitive `name` substring (when non-null).
pub fn a11yFindMatch(node: std.json.Value, role: ?i64, name_sub: ?[]const u8) ?std.json.Value {
    if (node != .object) return null;
    var ok = true;
    if (role) |r| {
        const nr = node.object.get("role") orelse std.json.Value{ .integer = -1 };
        if (nr != .integer or nr.integer != r) ok = false;
    }
    if (ok) {
        if (name_sub) |sub| {
            const nn = node.object.get("name") orelse std.json.Value{ .string = "" };
            if (nn != .string or std.ascii.indexOfIgnoreCase(nn.string, sub) == null) ok = false;
        } else if (role == null) ok = false; // no criteria = no match
    }
    if (ok) return node;
    if (node.object.get("children")) |kids| {
        if (kids == .array) for (kids.array.items) |k| {
            if (a11yFindMatch(k, role, name_sub)) |hit| return hit;
        };
    }
    return null;
}

/// One-line JSON of a node WITHOUT its children (summary for replies).
pub fn a11yNodeSummary(arena: std.mem.Allocator, node: std.json.Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{");
    var first = true;
    if (node == .object) {
        var it = node.object.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "children")) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try std.json.Stringify.value(e.key_ptr.*, .{}, w);
            try w.writeAll(":");
            try std.json.Stringify.value(e.value_ptr.*, .{}, w);
        }
    }
    try w.writeAll("}");
    return aw.written();
}

/// The PRIMARY content window (0 = none rendered yet): among painted
/// non-popup windows, the most recently committed one — a game keeps
/// painting its render surface while its outer frame window sits
/// static. Commits within 1s of each other tie; larger area wins the
/// tie, so a multi-window app at rest still yields its main window.
pub fn firstToplevelId(app: *appdrive.App) u32 {
    var best: ?*appdrive.Window = null;
    for (app.windows.items) |win| {
        if (win.popup or win.frames == 0) continue;
        const b = best orelse {
            best = win;
            continue;
        };
        const newer = win.last_commit_ms > b.last_commit_ms + 1000;
        const older = win.last_commit_ms + 1000 < b.last_commit_ms;
        const bigger = @as(i64, win.w) * win.h > @as(i64, b.w) * b.h;
        if (newer or (!older and bigger)) best = win;
    }
    return if (best) |b| b.id else 0;
}

/// A plain synthesized click honoring the project's hold default —
/// every click the server invents (template match, OCR match) goes
/// through this so an edge-polling app sees the same human-like
/// press-to-release span as an explicit app_click.
pub fn clickTuned(app: *appdrive.App, win_id: u32, x: f64, y: f64, button: u32) appdrive.Error!void {
    return app.clickEx(win_id, x, y, button, Tuning.hold_ms.value, 1);
}

/// Click-and-settle: captured BEFORE injecting input so the post-input
/// wait can tell "the app repainted in response" from "the frame on
/// screen predates the input" — the old idle-only wait returned
/// instantly-quiet on an app that takes a moment to react, so a
/// post-click screenshot was frequently the PRE-click frame.
/// A window silent for this long at the moment an input is injected was
/// not made silent BY that input. Well past any ordinary idle gap (an
/// unfocused static UI commits nothing), so it only fires when the app
/// really has stopped drawing.
pub const APP_QUIET_HANG_MS: i64 = 3_000;

pub const PostInputWait = struct {
    ref: ?appdrive.App.FrameRef,
    wait: bool,
    timeout_ms: i64,
    settle_ms: i64,
    min_pct: f64,
    t0: i64,
    /// Optional {x,y,w,h} rect: min_change_pct/settle percentages are
    /// gauged inside it only (assert "THIS viewport repainted").
    region: ?appdrive.App.Region = null,
    /// Set by finish(): a qualifying post-input frame arrived. Lets
    /// callers (app_click auto-retry) branch on the verdict without
    /// parsing the caption note.
    repainted: bool = false,
    /// Set by finish(): the process exited or its final GUI vanished.
    stop: ?AppStop = null,
    /// The target window's commit counter at the instant BEFORE the
    /// input was injected. Reported back with every input so a later
    /// screenshot_app {"min_frame": N} is PROVABLY post-input rather
    /// than hoped to be — the fix for captures silently lagging whole
    /// screens behind the drive.
    frame_at_input: u64 = 0,
    /// Monotonic ms of the window's last commit BEFORE the input, and
    /// the moment the input was injected. Together they answer a
    /// question the old single no-repaint message collapsed: was the
    /// window painting when the input arrived? If it had already gone
    /// quiet for seconds, the input did not kill it — the app was
    /// ALREADY not painting, and reading that as "the click missed"
    /// costs the entire diagnosis of a hang.
    last_commit_before: i64 = 0,
    injected_at: i64 = 0,

    /// `want_shot` = a post-input screenshot was requested; wait_change
    /// then defaults ON (pass wait_change:false to capture immediately).
    pub fn begin(args: std.json.Value, app: *appdrive.App, win_id: u32, want_shot: bool) PostInputWait {
        const min_pct: f64 = argFloat(args, "min_change_pct") orelse 0;
        // Default settle (Tuning.settle_ms): the FIRST post-input
        // frame is often a partial mid-repaint — capture only once
        // painting pauses. An explicit settle_ms:0 opts out.
        const settle_ms: i64 = std.math.clamp(argInt(args, "settle_ms") orelse Tuning.settle_ms.value, 0, 30_000);
        const settle_explicit = args == .object and args.object.get("settle_ms") != null;
        const explicit: ?bool = if (args == .object)
            (if (args.object.get("wait_change")) |v| (v == .bool and v.bool) else null)
        else
            null;
        const wait = explicit orelse (want_shot or settle_explicit);
        // Catch the mirror up FIRST: a frame already queued on the
        // socket predates the input and must not satisfy the wait.
        // drainLive (not the 100ms-boxed drain): the baseline must be
        // the LIVE frame, incl. a pending daemon-side resync.
        if (wait) _ = app.drainLive(CATCHUP_MS);
        // Defaulted-on waits stay short (a no-op click costs at most
        // Tuning.timeout_ms); an explicit wait_change/settle gets a
        // real budget.
        const timeout_ms: i64 = std.math.clamp(
            argInt(args, "timeout_ms") orelse @as(i64, if (explicit != null or settle_explicit) Tuning.explicitTimeout() else Tuning.timeout_ms.value),
            100,
            30_000,
        );
        return .{
            .ref = if (wait) app.frameRef(win_id, min_pct > 0) else null,
            .wait = wait,
            .timeout_ms = timeout_ms,
            .settle_ms = settle_ms,
            .min_pct = min_pct,
            .region = regionFrom(args),
            .t0 = clock.nowMs(),
            .frame_at_input = app.frameCount(win_id),
            .last_commit_before = app.lastCommitMs(win_id),
            .injected_at = clock.nowMs(),
        };
    }

    /// How long the window had ALREADY been silent when the input was
    /// injected (-1 = unknown: it has never painted, or no baseline was
    /// taken because no wait was requested).
    pub fn quietBeforeMs(self: *const PostInputWait) i64 {
        if (!self.wait or self.last_commit_before == 0) return -1;
        return self.injected_at - self.last_commit_before;
    }

    /// " [frame N at input, M now]" — the handle a caller passes back
    /// as screenshot_app {"min_frame": N} to demand pixels committed
    /// strictly after this input.
    pub fn frameNote(self: *const PostInputWait, arena: std.mem.Allocator, app: *appdrive.App, win_id: u32) []const u8 {
        const now = app.frameCount(win_id);
        if (now == 0 and self.frame_at_input == 0) return "";
        return std.fmt.allocPrint(
            arena,
            " [window {d} frame {d} at input, {d} now — pass min_frame:{d} to screenshot_app for a provably post-input capture]",
            .{ win_id, self.frame_at_input, now, self.frame_at_input },
        ) catch "";
    }

    /// Run AFTER the input. Returns a caption note ("" = nothing to
    /// report); a dry wait yields an explicit NO-repaint note so a
    /// dead click is structurally distinct from a late frame.
    pub fn finish(self: *PostInputWait, arena: std.mem.Allocator, app: *appdrive.App, win_id: u32) ![]const u8 {
        defer if (self.ref) |*r| r.deinit(app.allocator);
        if (!self.wait or self.ref == null) {
            _ = app.waitIdle(200, 2_000);
            if (probeAppStop(app, 1_000)) |stop| {
                self.stop = stop;
                const detail = try appStopText(arena, stop, "the post-input wait");
                return try std.fmt.allocPrint(arena, " - {s}", .{detail});
            }
            return "";
        }
        if (app.waitChangeSince(win_id, &self.ref.?, self.timeout_ms, self.min_pct, self.region)) {
            self.repainted = true;
            const elapsed = clock.nowMs() - self.t0;
            if (self.settle_ms > 0) {
                const remain = @max(self.timeout_ms - elapsed, 500);
                _ = if (self.min_pct > 0)
                    app.waitVisualSettle(win_id, self.settle_ms, remain, self.min_pct, self.region)
                else
                    app.waitWindowSettle(win_id, self.settle_ms, remain);
            } else {
                // Let a multi-frame transition finish before capture.
                _ = app.waitIdle(150, 1_000);
            }
            if (probeAppStop(app, 1_000)) |stop| {
                self.stop = stop;
                const detail = try appStopText(arena, stop, "the post-input settle");
                return try std.fmt.allocPrint(arena, " - {s}", .{detail});
            }
            return try std.fmt.allocPrint(arena, " — window repainted {d}ms after the input{s}{s}", .{
                elapsed,
                if (self.settle_ms > 0) " and settled" else "",
                if (self.region != null and self.min_pct > 0) " (change gauged inside the given region)" else "",
            });
        }
        // The wait primitives bail promptly on exit but return the same
        // false as a dead click — distinguish here, with the signal.
        // A vanished window usually means teardown raced ahead of the
        // .exit frame: give that frame a bounded moment to land.
        if (app.windowGone(win_id) and !app.presentationGone()) _ = app.settleExit(1_000);
        if (probeAppStop(app, 1_000)) |stop| {
            self.stop = stop;
            const detail = try appStopText(arena, stop, "the post-input wait");
            return try std.fmt.allocPrint(arena, " - {s}", .{detail});
        }
        const scoped: []const u8 = if (self.region != null and self.min_pct > 0) " in the given region" else "";
        // The daemon's commit counter already knew whether this window
        // was painting BEFORE the input, so say which failure this is
        // rather than leading with the input caveat. An app that had
        // gone silent seconds earlier was not killed by this click, and
        // the first evidence of a hang must not read as a dead click.
        const quiet = self.quietBeforeMs();
        if (quiet >= APP_QUIET_HANG_MS) {
            return try std.fmt.allocPrint(
                arena,
                " — APP LIVENESS WARNING, not an input problem: window {d} had ALREADY not painted for {d}ms when the input was injected, and it has not painted since. The input was delivered; the app is not drawing. Take a backtrace (app_backtrace) before assuming the coordinates were wrong",
                .{ win_id, quiet },
            );
        }
        if (quiet >= 0) {
            return try std.fmt.allocPrint(
                arena,
                " — NO repaint{s} within {d}ms after the input, although the window WAS painting {d}ms earlier: the input may have hit a dead area, or the app reacts without redrawing (any frame shown predates the input)",
                .{ scoped, self.timeout_ms, quiet },
            );
        }
        return try std.fmt.allocPrint(
            arena,
            " — NO repaint{s} within {d}ms after the input: it may have hit a dead area, or the app reacts without redrawing (any frame shown predates the input)",
            .{ scoped, self.timeout_ms },
        );
    }
};

/// Facts + one prose line for a captured window frame: what the image
/// shows and how to map its pixels back to app_click coordinates.
/// The caller owns the `window` fact (it already has one on every input
/// path, and a key written twice is a broken JSON object).
pub fn addShotFacts(
    res: *Res,
    arena: std.mem.Allocator,
    app: *appdrive.App,
    win_id: u32,
    shot: appdrive.App.Shot,
) !void {
    try res.fact("frame", shot.frame);
    try res.fact("image_w", shot.img_w);
    try res.fact("image_h", shot.img_h);
    try res.fact("image_scale", shot.scale);
    if (shot.ox != 0 or shot.oy != 0) {
        try res.fact("crop_x", shot.ox);
        try res.fact("crop_y", shot.oy);
    }
    try res.text(try screenshotCaption(arena, app, win_id, shot));
}

/// Shared tail for app_key/app_type/app_drag/app_scroll: finish the
/// post-input wait, then answer with a screenshot (when asked) or a
/// text result carrying the repaint note. `res` already holds the
/// tool's own facts; the common input facts are added here.
pub fn inputResult(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    args: std.json.Value,
    win_id: u32,
    piw: *PostInputWait,
    desc: []const u8,
    res: *Res,
) ![]const u8 {
    const note = try piw.finish(arena, app, win_id);
    try res.fact("window", win_id);
    // Every input hands back the frame counter it acted at — the only
    // way a later capture can be asserted (not assumed) newer.
    try res.fact("frame_at_input", piw.frame_at_input);
    try res.fact("frame_now", app.frameCount(win_id));
    try res.fact("repainted", piw.repainted);
    try res.textf("{s}{s}", .{ desc, note });
    if (piw.stop != null) {
        // Skip the screenshot attempt (it would fail as "no pixels
        // yet?" and mask the crash) — report the exit with full detail.
        try addAppSummary(res, arena, app);
        return res.finish();
    }
    const frame_note = piw.frameNote(arena, app, win_id);
    if (frame_note.len > 0) try res.text(frame_note);
    const delta = logDeltaNote(arena, app, args);
    if (delta.len > 0) try res.text(delta);
    const nudge = macroNudge(arena, app);
    if (nudge.len > 0) try res.text(nudge);
    if (argBool(args, "screenshot") and win_id != 0) {
        const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse 1568, 0, 8192));
        const shot = app.screenshotPng(win_id, max_px, null, 1) catch {
            try res.fact("screenshot_failed", true);
            try res.text("the post-input screenshot failed (no pixels yet?)");
            return res.finish();
        };
        defer app_state.allocator.free(shot.png);
        try addShotFacts(res, arena, app, win_id, shot);
        return res.finishWithImages(&.{shot.png}, null);
    }
    return res.finish();
}

/// Fixed-length array of numbers out of a JSON value ([x,y], …).
pub fn numArray(v: std.json.Value, comptime n: usize) ?[n]f64 {
    if (v != .array or v.array.items.len != n) return null;
    var out: [n]f64 = undefined;
    for (v.array.items, 0..) |item, i| {
        out[i] = switch (item) {
            .integer => |iv| @floatFromInt(iv),
            .float => |fv| fv,
            else => return null,
        };
    }
    return out;
}

/// One app_actions screenshot: draws (and consumes) the pending step
/// marks, stores the PNG, writes the report line. Returns false when
/// the capture failed (the caller decides whether that is fatal).
pub fn actionsCapture(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    w: *std.Io.Writer,
    pngs: *std.ArrayList([]const u8),
    tags: *std.ArrayList([]const u8),
    pending: *std.ArrayList(marks_mod.Mark),
    wid: u32,
    max_px: u32,
    prefix: []const u8,
) !bool {
    const marks_n = pending.items.len;
    // Trace-filename tag: what the marks in this shot depict.
    var tag: []const u8 = "";
    for (pending.items) |m| {
        if (m.kind == .click) {
            tag = "click";
            break;
        }
        tag = "move";
    }
    const shot = app.screenshotPngMarked(wid, max_px, null, 1, pending.items) catch {
        return false;
    };
    pngs.append(arena, shot.png) catch {
        app_state.allocator.free(shot.png);
        return error.OutOfMemory;
    };
    tags.append(arena, tag) catch return error.OutOfMemory;
    pending.clearRetainingCapacity();
    if (shot.scale == 1.0) {
        try w.print("{s}: screenshot #{d} of window {d} ({d}x{d})", .{ prefix, pngs.items.len, wid, shot.img_w, shot.img_h });
    } else {
        try w.print("{s}: screenshot #{d} of window {d} — image {d}x{d}, MULTIPLY its coordinates by {d:.3} for clicks", .{ prefix, pngs.items.len, wid, shot.img_w, shot.img_h, shot.scale });
    }
    if (marks_n > 0) try w.print(" [{d} marker(s) drawn: red crosshair = click, cyan = move/hover, number = step]", .{marks_n});
    try w.writeAll("\n");
    return true;
}

pub fn reportActionStop(arena: std.mem.Allocator, w: *std.Io.Writer, step: usize, context: []const u8, stop: AppStop) !void {
    const detail = try appStopText(arena, stop, context);
    try w.print("step {d}: {s}; remaining steps skipped\n", .{ step, detail });
}

// ── input journal, macros, template matching, OCR ─────────────────

/// Per-app journal of successfully injected input steps (canonical
/// step JSON, the app_actions vocabulary). app_macro_save snapshots
/// its tail into a named replayable macro — "record what I just did".
pub const Journal = struct {
    const Entry = struct { step: []u8, t: i64 };
    const MAX_ENTRIES = 400;
    var map: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(Entry)) = .empty;

    /// Best-effort: OOM just loses the entry.
    pub fn record(app_id: u32, step_json: []const u8) void {
        if (app_id == 0 or step_json.len == 0) return;
        const a = app_state.allocator;
        const gop = map.getOrPut(a, app_id) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const copy = a.dupe(u8, step_json) catch return;
        gop.value_ptr.append(a, .{ .step = copy, .t = clock.nowMs() }) catch {
            a.free(copy);
            return;
        };
        while (gop.value_ptr.items.len > MAX_ENTRIES) {
            const old = gop.value_ptr.orderedRemove(0);
            a.free(old.step);
        }
    }

    pub fn entriesOf(app_id: u32) []Entry {
        const list = map.getPtr(app_id) orelse return &.{};
        return list.items;
    }

    pub fn deinitAll() void {
        const a = app_state.allocator;
        for (map.values()) |*list| {
            for (list.items) |e| a.free(e.step);
            list.deinit(a);
        }
        map.deinit(a);
        map = .empty;
    }
};

/// One-shot pointer at app_macro_save, emitted once an app has
/// accumulated enough journalled input for replay to pay off. The
/// crash-hunting loop is fix → rebuild → RE-DRIVE THE IDENTICAL PATH
/// → compare, and hand-driving makes each repro only APPROXIMATELY
/// identical — which is exactly wrong when the question is "same
/// crash, same registers, before and after". The macro tools existed
/// but were only discoverable by reading the full tool list, so the
/// nudge lands at the moment the repetition becomes visible.
pub const MacroNudge = struct {
    const AT = 12;
    var done: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;

    pub fn deinitAll() void {
        done.deinit(app_state.allocator);
        done = .empty;
    }
};

pub fn macroNudge(arena: std.mem.Allocator, app: *appdrive.App) []const u8 {
    const id = appIdOf(app);
    if (id == 0 or MacroNudge.done.contains(id)) return "";
    const n = Journal.entriesOf(id).len;
    if (n < MacroNudge.AT) return "";
    MacroNudge.done.put(app_state.allocator, id, {}) catch return "";
    return std.fmt.allocPrint(
        arena,
        "\n[{d} input steps recorded for this app: app_macro_save {{\"app\":{d},\"name\":\"...\"}} snapshots them (last_steps:N for just the tail) and app_macro_run replays the identical path after a rebuild — worth it when you are about to drive the same route again]",
        .{ n, id },
    ) catch "";
}

/// Format-and-record one journal step for `app` (bounded; an
/// overlong step is dropped, not truncated into invalid JSON).
pub fn journalStep(app: *appdrive.App, comptime fmt: []const u8, fmt_args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, fmt_args) catch return;
    Journal.record(appIdOf(app), s);
}

/// Journal a step whose payload needs real JSON escaping (type text).
/// `extra_raw` is appended verbatim inside the object ("" = none),
/// e.g. ",\"hold_ms\":500".
pub fn journalStepJson(app: *appdrive.App, arena: std.mem.Allocator, key: []const u8, text: []const u8, extra_raw: []const u8) void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.print("{{\"{s}\":", .{key}) catch return;
    std.json.Stringify.value(text, .{}, w) catch return;
    w.writeAll(extra_raw) catch return;
    w.writeAll("}") catch return;
    Journal.record(appIdOf(app), aw.written());
}

/// Optional {"region":{x,y,w,h}} sub-object of a tool/step arg.
pub fn regionFrom(v: std.json.Value) ?appdrive.App.Region {
    if (v != .object) return null;
    return regionOf(v.object.get("region") orelse return null);
}

/// Parse one region value. The documented shape is {x,y,w,h}; the
/// four-number array [x,y,w,h] is accepted too because it is the
/// shape callers reach for, and rejecting it bought nothing but a
/// parse error that pointed at the wrong thing.
pub fn regionOf(r: std.json.Value) ?appdrive.App.Region {
    var x: i64 = 0;
    var y: i64 = 0;
    var w: i64 = 0;
    var h: i64 = 0;
    switch (r) {
        .object => {
            x = argInt(r, "x") orelse 0;
            y = argInt(r, "y") orelse 0;
            w = argInt(r, "w") orelse return null;
            h = argInt(r, "h") orelse return null;
        },
        .array => {
            const q = numArray(r, 4) orelse return null;
            // @intFromFloat outside the destination's range is illegal
            // behaviour, and this build has no safety checks — so the
            // NaN/huge cases are refused BEFORE the conversion, not by
            // the sign check below.
            const lim: f64 = @floatFromInt(std.math.maxInt(u32));
            for (q[0..4]) |n| if (!(n >= 0 and n <= lim)) return null;
            x = @intFromFloat(q[0]);
            y = @intFromFloat(q[1]);
            w = @intFromFloat(q[2]);
            h = @intFromFloat(q[3]);
        },
        else => return null,
    }
    if (x < 0 or y < 0 or w <= 0 or h <= 0) return null;
    // Out of u32 range is a refusal, never a truncating cast: a
    // silently wrapped rect diffs as a legitimate one and changes the
    // repaint verdict.
    const max: i64 = std.math.maxInt(u32);
    if (x > max or y > max or w > max or h > max) return null;
    return .{ .x = @intCast(x), .y = @intCast(y), .w = @intCast(w), .h = @intCast(h) };
}

const Needle = struct { px: []u8, w: u32, h: u32, name: []const u8 };

/// Resolve a template reference: "template" (a saved name) or
/// "image_b64" (inline PNG). Pixels land in the arena.
pub fn resolveNeedle(arena: std.mem.Allocator, v: std.json.Value) !union(enum) { needle: Needle, err: []const u8 } {
    if (argStr(v, "template")) |name| {
        const bytes = mcpassets.load(arena, .template, name) catch |err| return .{ .err = switch (err) {
            mcpassets.Error.NotFound => try std.fmt.allocPrint(arena, "no saved template \"{s}\" (save one with app_template_save; list with app_templates)", .{name}),
            mcpassets.Error.BadName => "invalid template name (letters, digits, . _ - only, max 64)",
            mcpassets.Error.OutOfMemory => return error.OutOfMemory,
            else => "template load failed",
        } };
        const dec = png_util.decodeRgba(arena, bytes) catch
            return .{ .err = "stored template is not a decodable image" };
        return .{ .needle = .{ .px = dec.rgba, .w = dec.w, .h = dec.h, .name = name } };
    }
    if (argStr(v, "image_b64")) |b64| {
        const decoder = std.base64.standard.Decoder;
        const max = decoder.calcSizeForSlice(b64) catch return .{ .err = "image_b64 is not valid base64" };
        const raw = try arena.alloc(u8, max);
        decoder.decode(raw, b64) catch return .{ .err = "image_b64 is not valid base64" };
        const dec = png_util.decodeRgba(arena, raw) catch
            return .{ .err = "image_b64 does not decode as an image" };
        return .{ .needle = .{ .px = dec.rgba, .w = dec.w, .h = dec.h, .name = "(inline)" } };
    }
    return .{ .err = "pass 'template' (a saved template name) or 'image_b64' (inline PNG)" };
}

/// One template hit in SURFACE coordinates (center included — the
/// click point).
pub const FoundMatch = struct { x: u32, y: u32, cx: u32, cy: u32, score: f64 };

/// Match `needle` against a window's current pixels. `.err` is a
/// human message (no pixels / bad template); an empty `.matches`
/// slice just means "not there right now".
pub fn findInWindow(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    win_id: u32,
    region: ?appdrive.App.Region,
    needle: Needle,
    min_score: f64,
    max_matches: usize,
) !union(enum) { matches: []FoundMatch, err: []const u8 } {
    const shot = app.snapshotRgba(win_id, region) catch
        return .{ .err = "no rendered pixels in that window (yet?)" };
    defer app_state.allocator.free(shot.px);
    const ms = template.find(arena, shot.px, shot.w, shot.h, needle.px, needle.w, needle.h, .{
        .min_score = min_score,
        .max_matches = max_matches,
    }) catch |err| switch (err) {
        template.Error.BadTemplate => return .{ .err = "template is unusable (empty or fully transparent)" },
        template.Error.OutOfMemory => return error.OutOfMemory,
    };
    const out = try arena.alloc(FoundMatch, ms.len);
    for (ms, 0..) |m, i| {
        out[i] = .{
            .x = shot.ox + m.x,
            .y = shot.oy + m.y,
            .cx = shot.ox + m.x + needle.w / 2,
            .cy = shot.oy + m.y + needle.h / 2,
            .score = m.score,
        };
    }
    return .{ .matches = out };
}

pub const OcrOut = struct { text: []u8, words: []ocr.Word, scale: u32 };

/// OCR a window (optionally a region), word boxes mapped back to
/// SURFACE coordinates. scale_req 0 = auto (upscale small captures;
/// game bitmap fonts need it). Results live in the arena.
pub fn ocrWindow(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    win_id: u32,
    region: ?appdrive.App.Region,
    scale_req: u32,
    psm: i32,
    lang: []const u8,
) !union(enum) { out: OcrOut, err: []const u8 } {
    const shot = app.snapshotRgba(win_id, region) catch
        return .{ .err = "no rendered pixels in that window (yet?)" };
    defer app_state.allocator.free(shot.px);
    // Upscaling is a REPAIR for tiny fonts, not a free improvement:
    // measured on an ordinary GTK dialog, nearest-neighbour 2x-3x made
    // Tesseract read NOTHING where the native-scale image read the label
    // correctly. The old auto rule (4096/longest edge, clamped to 3)
    // fired on every window under ~1365px — i.e. nearly all of them —
    // so the default silently hurt the common case to help the rare one.
    // Auto now means "native first, upscale only if that found nothing".
    // An explicit `scale` from the caller is still honoured verbatim.
    const auto = scale_req == 0;
    var scale: u32 = if (auto) 1 else @min(scale_req, 8);
    var px: []const u8 = shot.px;
    var w = shot.w;
    var h = shot.h;
    if (scale > 1) {
        px = png_util.upscaleRgba(arena, shot.px, w, h, scale) catch return error.OutOfMemory;
        w *= scale;
        h *= scale;
    }
    var res = ocr.recognize(arena, px, w, h, .{ .lang = lang, .psm = psm }) catch |err| return .{ .err = switch (err) {
        ocr.Error.Unavailable => "OCR unavailable: libtesseract was not found on this machine. Install tesseract plus a language pack (e.g. tesseract-data-eng) — sketerm loads it at runtime, no rebuild needed.",
        ocr.Error.InitFailed => "tesseract loaded but could not initialize the language — install its traineddata (e.g. tesseract-data-eng) or set TESSDATA_PREFIX",
        ocr.Error.OutOfMemory => return error.OutOfMemory,
        else => "text recognition failed",
    } };
    // Nothing legible at native scale: this is the tiny-font case the
    // upscale exists for, so pay for it now rather than by default.
    if (auto and res.words.len == 0) {
        const up = std.math.clamp(4096 / @max(1, @max(shot.w, shot.h)), 1, 3);
        if (up > 1) {
            if (png_util.upscaleRgba(arena, shot.px, shot.w, shot.h, up)) |big| {
                if (ocr.recognize(arena, big, shot.w * up, shot.h * up, .{ .lang = lang, .psm = psm })) |res2| {
                    if (res2.words.len > 0) {
                        res = res2;
                        scale = up;
                    }
                } else |_| {}
            } else |_| {}
        }
    }
    for (res.words) |*wd| {
        wd.x = shot.ox + wd.x / scale;
        wd.y = shot.oy + wd.y / scale;
        wd.w = @max(1, wd.w / scale);
        wd.h = @max(1, wd.h / scale);
    }
    return .{ .out = .{ .text = res.text, .words = res.words, .scale = scale } };
}

/// Bounding box of a run of consecutive OCR words matching the
/// space-separated query, case-insensitive (each query token must
/// appear in its word). Null = no run (the query may still occur in
/// the plain text with different word splits).
pub fn findWordRun(words: []const ocr.Word, query: []const u8) ?struct { x: u32, y: u32, w: u32, h: u32 } {
    var toks: [8][]const u8 = undefined;
    var ntok: usize = 0;
    var it = std.mem.tokenizeScalar(u8, query, ' ');
    while (it.next()) |t| {
        if (ntok == toks.len) break;
        toks[ntok] = t;
        ntok += 1;
    }
    if (ntok == 0) return null;
    if (words.len < ntok) return null;
    var i: usize = 0;
    outer: while (i + ntok <= words.len) : (i += 1) {
        for (toks[0..ntok], 0..) |tok, j| {
            if (std.ascii.indexOfIgnoreCase(words[i + j].text, tok) == null) continue :outer;
        }
        var x0 = words[i].x;
        var y0 = words[i].y;
        var x1 = words[i].x + words[i].w;
        var y1 = words[i].y + words[i].h;
        for (words[i .. i + ntok]) |wd| {
            x0 = @min(x0, wd.x);
            y0 = @min(y0, wd.y);
            x1 = @max(x1, wd.x + wd.w);
            y1 = @max(y1, wd.y + wd.h);
        }
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
    return null;
}

const LaunchArgv = union(enum) {
    ok: struct {
        /// True when the caller supplied explicit argv pieces (array
        /// command, or string command + args) — safe to rewrite
        /// (ozone-flag injection); a bare shell string is not.
        argv_form: bool,
    },
    err: []const u8,
};

/// Build launch_app's argv into `argv` from `command` (string or argv
/// array) plus the optional `args` array. A string command normally
/// runs via `/bin/sh -c`; WITH extra args it becomes the bare
/// EXECUTABLE instead (argv[0], not shell-parsed) — callers pairing a
/// string with args mean "binary plus its arguments", and the old
/// schema silently dropped `args`, launching apps with argc==1.
pub fn buildLaunchArgv(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), args: std.json.Value) !LaunchArgv {
    var extra: std.ArrayList([]const u8) = .empty;
    defer extra.deinit(arena);
    var cmd_is_array = false;
    if (args == .object) {
        if (args.object.get("args")) |ea| {
            if (ea != .array) return .{ .err = "'args' must be an array of strings" };
            for (ea.array.items) |item| {
                if (item != .string) return .{ .err = "'args' must be an array of strings" };
                try extra.append(arena, item.string);
            }
        }
        if (args.object.get("command")) |cmd| switch (cmd) {
            .string => if (extra.items.len > 0) {
                try argv.append(arena, cmd.string);
            } else {
                try argv.append(arena, "/bin/sh");
                try argv.append(arena, "-c");
                try argv.append(arena, cmd.string);
            },
            .array => {
                cmd_is_array = true;
                for (cmd.array.items) |item| {
                    if (item != .string) return .{ .err = "command array must be strings" };
                    try argv.append(arena, item.string);
                }
            },
            else => {},
        };
    }
    if (argv.items.len == 0) return .{ .err = "launch_app requires 'command' (string or argv array)" };
    try argv.appendSlice(arena, extra.items);
    return .{ .ok = .{ .argv_form = cmd_is_array or extra.items.len > 0 } };
}

const DebugWrap = union(enum) { note: []const u8, err: []const u8 };

/// Prepend launch_app's debug:"gdb"/"valgrind" wrapper onto argv; the
/// wrapper's report goes to the PTY = app_log (works for string
/// commands too: the wrapper follows /bin/sh's exec). `gdb_commands`
/// entries become extra -ex commands run AT THE CRASH POINT, after the
/// automatic bt full + info registers.
pub fn applyDebugWrap(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), args: std.json.Value) !DebugWrap {
    const dm = argStr(args, "debug") orelse {
        if (args == .object and args.object.get("gdb_commands") != null)
            return .{ .err = "'gdb_commands' requires debug:\"gdb\"" };
        return .{ .note = "" };
    };
    var wrapped: std.ArrayList([]const u8) = .empty;
    defer wrapped.deinit(arena);
    var note: []const u8 = undefined;
    if (eql(u8, dm, "gdb")) {
        try wrapped.appendSlice(arena, &.{
            "gdb",                                "-q",                                 "-batch",
            // Batch mode runs these in order and quits after the last
            // one. That makes NUISANCE SIGNALS fatal to the whole
            // exercise: a threaded app that takes a SIGPIPE or one of
            // glibc's real-time thread signals stops gdb there, the
            // reporting commands run against that harmless stop, and
            // gdb exits long before the crash under investigation.
            // Passing them through is what makes a backtrace show up
            // reliably rather than roughly one run in five.
            "-ex",                                "handle SIGPIPE nostop noprint pass", "-ex",
            "handle SIG32 nostop noprint pass",   "-ex",                                "handle SIG33 nostop noprint pass",
            "-ex",                                "handle SIG34 nostop noprint pass",   "-ex",
            "handle SIGCHLD nostop noprint pass", "-ex",                                "set pagination off",
            "-ex",                                "set confirm off",                    "-ex",
            "set print thread-events off",        "-ex",                                "run",
            // The faulting thread is often NOT the one gdb selects, and
            // a worker-thread crash is exactly the case a single
            // `bt full` reports uselessly.
            "-ex",                                "thread apply all bt full",           "-ex",
            "info threads",                       "-ex",                                "info registers",
        });
        var n_extra: usize = 0;
        if (args == .object) if (args.object.get("gdb_commands")) |gc| {
            if (gc != .array) return .{ .err = "'gdb_commands' must be an array of strings" };
            if (gc.array.items.len > 64) return .{ .err = "'gdb_commands': at most 64 commands" };
            for (gc.array.items) |item| {
                if (item != .string or item.string.len == 0 or item.string.len > 1000)
                    return .{ .err = "'gdb_commands' entries must be non-empty strings (max 1000 chars)" };
                try wrapped.appendSlice(arena, &.{ "-ex", item.string });
                n_extra += 1;
            }
        };
        try wrapped.append(arena, "--args");
        note = if (n_extra > 0)
            try std.fmt.allocPrint(arena, "\ndebug wrapper: gdb — the reported pid is gdb, not the app; on a crash ALL threads' backtraces, registers, and your {d} extra gdb command(s) land in app_log. NOTE: exit_status will be GDB's (usually 0) even for a crash — the app's real fate is reported as inferior_signal / crashed, read from the backtrace.", .{n_extra})
        else
            "\ndebug wrapper: gdb — the reported pid is gdb, not the app; on a crash ALL threads' backtraces land in app_log. NOTE: exit_status will be GDB's (usually 0) even for a crash — the app's real fate is reported as inferior_signal / crashed, read from the backtrace.";
    } else if (eql(u8, dm, "valgrind")) {
        if (args == .object and args.object.get("gdb_commands") != null)
            return .{ .err = "'gdb_commands' only applies to debug:\"gdb\"" };
        try wrapped.appendSlice(arena, &.{ "valgrind", "--track-origins=yes" });
        note = "\ndebug wrapper: valgrind — the reported pid is valgrind; its report lands in app_log when the app exits";
    } else {
        return .{ .err = "'debug' must be \"gdb\" or \"valgrind\"" };
    }
    try wrapped.appendSlice(arena, argv.items);
    argv.clearRetainingCapacity();
    try argv.appendSlice(arena, wrapped.items);
    return .{ .note = note };
}

// ── Capabilities preflight ────────────────────────────────────────

/// PATH search; arena-owned absolute path or null.
pub fn findExecutable(arena: std.mem.Allocator, exe: []const u8) ?[]const u8 {
    const path_env = c.getenv("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, std.mem.span(@as([*:0]const u8, @ptrCast(path_env))), ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [4096]u8 = undefined;
        const full_z = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, exe }) catch continue;
        if (c.access(full_z.ptr, c.X_OK) == 0) {
            return arena.dupe(u8, full_z) catch null;
        }
    }
    return null;
}

/// Basename-prefix match for the Chromium family (incl. Electron).
pub fn chromiumFamily(arg0: []const u8) bool {
    const base = std.fs.path.basename(arg0);
    const prefixes = [_][]const u8{ "chromium", "chrome", "google-chrome", "brave", "vivaldi", "microsoft-edge", "opera", "electron" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, base, p)) return true;
    }
    return false;
}

const DelayedExit = struct {
    fd: c_int,
    status: i32,
    delay_us: u32 = 50_000,

    fn send(self: DelayedExit) void {
        _ = c.usleep(self.delay_us);
        var frame: [9]u8 = undefined;
        std.mem.writeInt(u32, frame[0..4], 5, .little);
        frame[4] = @intFromEnum(wire.FrameType.exit);
        std.mem.writeInt(i32, frame[5..9], self.status, .little);
        _ = c.write(self.fd, &frame, frame.len);
    }
};

fn testActionApp(a: std.mem.Allocator, with_window: bool) !struct { app: *appdrive.App, peer: c_int } {
    var fds: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds) != 0) return error.SocketFailed;
    errdefer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }
    const app = try a.create(appdrive.App);
    errdefer a.destroy(app);
    app.* = .{
        .allocator = a,
        .conn = .{ .allocator = a, .fd = fds[0] },
        .name = try a.dupe(u8, "mcp-action-test"),
    };
    app.conn.setNonBlocking();
    if (with_window) {
        const win = try a.create(appdrive.Window);
        errdefer a.destroy(win);
        win.* = .{ .id = 1, .chan = 7, .sid = 11, .w = 1, .h = 1, .frames = 1 };
        try win.pixels.appendSlice(a, &.{ 1, 2, 3, 255 });
        try app.windows.append(a, win);
        app.had_toplevel = true;
    }
    app_state.allocator = a;
    return .{ .app = app, .peer = fds[1] };
}

test "appSelect separates unknown, ambiguous and single-live apps" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const f1 = try testActionApp(t.allocator, true);
    defer _ = c.close(f1.peer);
    defer f1.app.deinit();
    const f2 = try testActionApp(t.allocator, true);
    defer _ = c.close(f2.peer);
    defer f2.app.deinit();
    defer {
        app_state.apps.deinit(t.allocator);
        app_state.apps = .empty;
    }
    const empty = try parseTestValue(arena, "{}");

    // Nothing launched: must not read as a dead app.
    switch (appSelect(arena, empty)) {
        .app => return error.UnexpectedApp,
        .err => |e| try t.expect(std.mem.indexOf(u8, e, "no app sessions exist") != null),
    }

    try app_state.apps.put(t.allocator, 7, f1.app);
    // Single app: `app` stays optional.
    switch (appSelect(arena, empty)) {
        .app => |a| try t.expect(a == f1.app),
        .err => return error.UnexpectedError,
    }

    try app_state.apps.put(t.allocator, 8, f2.app);
    // Two live apps, no id: AMBIGUOUS, and the message must name them
    // — the old wording claimed the app was unknown, which reads
    // exactly like a crash and gets misdiagnosed as one.
    switch (appSelect(arena, empty)) {
        .app => return error.UnexpectedApp,
        .err => |e| {
            try t.expect(std.mem.indexOf(u8, e, "AMBIGUOUS") != null);
            try t.expect(std.mem.indexOf(u8, e, "app 7 (alive") != null);
            try t.expect(std.mem.indexOf(u8, e, "app 8 (alive") != null);
        },
    }

    // A wrong id names the roster instead of a bare failure.
    const bad = try parseTestValue(arena, "{\"app\":99}");
    switch (appSelect(arena, bad)) {
        .app => return error.UnexpectedApp,
        .err => |e| {
            try t.expect(std.mem.indexOf(u8, e, "no app has id 99") != null);
            try t.expect(std.mem.indexOf(u8, e, "app 7") != null);
        },
    }

    // An exited session lingers until close_app; it must not make the
    // one remaining live app ambiguous.
    f2.app.exited = true;
    switch (appSelect(arena, empty)) {
        .app => |a| try t.expect(a == f1.app),
        .err => return error.UnexpectedError,
    }
}

test "frame counters make a capture provably newer than an input" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const f = try testActionApp(t.allocator, true);
    defer _ = c.close(f.peer);
    defer f.app.deinit();

    try t.expectEqual(@as(u64, 1), f.app.frameCount(1));
    try t.expectEqual(@as(u64, 0), f.app.frameCount(999));
    // Already past the bar: returns at once.
    try t.expect(f.app.waitFrameAfter(1, 0, 50));
    // Never reached within the bound (nothing commits on this fixture).
    try t.expect(!f.app.waitFrameAfter(1, 5, 50));

    var piw = PostInputWait.begin(try parseTestValue(arena, "{}"), f.app, 1, false);
    try t.expectEqual(@as(u64, 1), piw.frame_at_input);
    const note = piw.frameNote(arena, f.app, 1);
    try t.expect(std.mem.indexOf(u8, note, "frame 1 at input") != null);
    try t.expect(std.mem.indexOf(u8, note, "min_frame:1") != null);
}

test "a11yTreeIsBare only flags a registry with no widgets under it" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The real reply from an SDL game: registry + a desktop service,
    // nothing below either.
    try t.expect(a11yTreeIsBare(arena,
        \\{"tree":{"id":"org.a11y.atspi.Registry#root","role":14,"name":"main","children":[{"id":":1.2#root","role":75,"name":"xdg-desktop-portal-gtk"}]}}
    ));
    // A toolkit app nests widgets — never call that "no tree".
    try t.expect(!a11yTreeIsBare(arena,
        \\{"tree":{"id":"reg","role":14,"children":[{"id":"app","role":75,"children":[{"id":"win","role":14}]}]}}
    ));
    try t.expect(!a11yTreeIsBare(arena, "not json"));
}

test "regionOf accepts the object shape and the array shorthand" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const obj = (regionOf(try parseTestValue(arena, "{\"x\":0,\"y\":330,\"w\":145,\"h\":150}"))).?;
    try t.expectEqual(@as(u32, 330), obj.y);
    try t.expectEqual(@as(u32, 145), obj.w);
    const arr = (regionOf(try parseTestValue(arena, "[0,330,145,150]"))).?;
    try t.expectEqual(obj.y, arr.y);
    try t.expectEqual(obj.h, arr.h);
    // Degenerate rects are rejected, not silently clamped.
    try t.expect(regionOf(try parseTestValue(arena, "{\"x\":1,\"y\":1,\"w\":0,\"h\":5}")) == null);
    try t.expect(regionOf(try parseTestValue(arena, "\"0,330,145,150\"")) == null);
    // Out of u32 range is rejected too. This build has no safety
    // checks, so a truncating @intCast turned 4294967300 into 4 and the
    // change percentages were then measured over a rect nobody asked
    // for — a wrong repaint verdict rather than a refusal.
    try t.expect(regionOf(try parseTestValue(arena, "{\"x\":4294967300,\"y\":0,\"w\":10,\"h\":10}")) == null);
    try t.expect(regionOf(try parseTestValue(arena, "{\"x\":0,\"y\":0,\"w\":9999999999,\"h\":10}")) == null);
    // An f64 outside i64 range is illegal to @intFromFloat, so the
    // array shorthand has to refuse before it converts.
    try t.expect(regionOf(try parseTestValue(arena, "[1e20,0,10,10]")) == null);
    try t.expect(regionOf(try parseTestValue(arena, "[0,0,1e20,10]")) == null);
}

test "debuggerSignal parses gdb and valgrind crash headlines" {
    const t = std.testing;
    try t.expectEqual(@as(?i32, 11), debuggerSignal("Program received signal SIGSEGV, Segmentation fault."));
    try t.expectEqual(@as(?i32, 6), debuggerSignal("Process terminating with default action of signal 6 (SIGABRT)"));
    try t.expectEqual(@as(?i32, null), debuggerSignal("ordinary app output"));
}

test "app_actions stops structurally when a click crashes the app" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();

    const sender = try std.Thread.spawn(.{}, DelayedExit.send, .{DelayedExit{ .fd = fixture.peer, .status = -11 }});
    defer sender.join();
    const root = try parseTestValue(arena,
        \\{"actions":[{"click":[0,0],"screenshot":true},{"screenshot":true}]}
    );
    const result = try @import("mcp_app.zig").runActionSteps(arena, fixture.app, root.object.get("actions").?.array.items, 1, false, null);
    const parsed = try expectToolResultShape(arena, "app_actions", result);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("app_exited", sc.get("status").?.string);
    try t.expectEqual(@as(i64, 1), sc.get("step").?.integer);
    try t.expectEqual(@as(i64, 11), sc.get("signal").?.integer);
    try t.expectEqualStrings("SIGSEGV", sc.get("signal_name").?.string);
    try t.expect(sc.get("remaining_steps_skipped").?.bool);
    // A step failure is never a tool error, and the transcript still
    // tells the story in prose.
    try t.expect(parsed.object.get("isError") == null);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "app EXITED") != null);
    try t.expect(std.mem.indexOf(u8, text, "SIGSEGV") != null);
    try t.expect(std.mem.indexOf(u8, text, "no pixels yet") == null);
    try t.expect(std.mem.indexOf(u8, text, "all 2 steps completed") == null);
}

test "app_actions reports clean exit status and skips later steps" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();

    const sender = try std.Thread.spawn(.{}, DelayedExit.send, .{DelayedExit{ .fd = fixture.peer, .status = 0 }});
    defer sender.join();
    const root = try parseTestValue(arena,
        \\{"actions":[{"wait_idle":{"quiet_ms":500,"timeout_ms":1000}},{"key":"enter"}]}
    );
    const result = try @import("mcp_app.zig").runActionSteps(arena, fixture.app, root.object.get("actions").?.array.items, 1, false, null);
    const parsed = try expectToolResultShape(arena, "app_actions", result);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("app_exited", sc.get("status").?.string);
    try t.expectEqual(@as(i64, 0), sc.get("exit_status").?.integer);
    try t.expectEqual(@as(i64, 2), sc.get("steps_total").?.integer);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "app exited during wait_idle (status 0)") != null);
    // The second step never ran.
    try t.expect(std.mem.indexOf(u8, text, "pressed") == null);
}

test "app_actions keeps a live frozen app distinct from exit" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();

    const root = try parseTestValue(arena,
        \\{"actions":[{"wait_idle":{"quiet_ms":500,"timeout_ms":100,"required":true}}]}
    );
    const result = try @import("mcp_app.zig").runActionSteps(arena, fixture.app, root.object.get("actions").?.array.items, 1, false, null);
    const parsed = try expectToolResultShape(arena, "app_actions", result);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("failed", sc.get("status").?.string);
    try t.expectEqual(@as(i64, 1), sc.get("step").?.integer);
    // The failing step's own words are the reason — no exit is claimed.
    try t.expect(std.mem.indexOf(u8, sc.get("reason").?.string, "wait_idle did not settle") != null);
    try t.expect(sc.get("exit_status") == null);
    try t.expect(sc.get("signal") == null);
    // One outcome, marked not-ok.
    const steps_out = sc.get("steps").?.array.items;
    try t.expectEqual(@as(usize, 1), steps_out.len);
    try t.expect(!steps_out[0].object.get("ok").?.bool);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "wait_idle did not settle before timeout") != null);
}

test "app_actions treats debugger client loss as inferior exit" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, false);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();
    fixture.app.had_toplevel = true;
    fixture.app.presentation_gone = .client_disconnected;
    try fixture.app.log_buf.appendSlice(t.allocator, "{\"lines\":[{\"text\":\"Program received signal SIGSEGV, Segmentation fault.\"}]}");

    const root = try parseTestValue(arena, "{\"actions\":[{\"wait_idle\":{\"timeout_ms\":100}},{\"screenshot\":true}]}");
    const result = try @import("mcp_app.zig").runActionSteps(arena, fixture.app, root.object.get("actions").?.array.items, null, false, null);
    const parsed = try expectToolResultShape(arena, "app_actions", result);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("app_exited", sc.get("status").?.string);
    try t.expectEqualStrings("client_disconnected", sc.get("reason").?.string);
    try t.expectEqual(@as(i64, 11), sc.get("signal").?.integer);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "SIGSEGV") != null);
    // The batch stopped at step 1, so the screenshot step never ran and
    // never complained about the missing window.
    try t.expect(std.mem.indexOf(u8, text, "no rendered window to screenshot") == null);
}

test "PostInputWait reports a click-triggered process crash" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();
    const args = try parseTestValue(arena, "{\"wait_change\":true,\"timeout_ms\":500,\"settle_ms\":0}");
    var wait = PostInputWait.begin(args, fixture.app, 1, true);
    const sender = try std.Thread.spawn(.{}, DelayedExit.send, .{DelayedExit{ .fd = fixture.peer, .status = -11 }});
    defer sender.join();
    const note = try wait.finish(arena, fixture.app, 1);
    try t.expect(wait.stop != null);
    try t.expectEqual(@as(?i32, 11), wait.stop.?.signal);
    try t.expect(std.mem.indexOf(u8, note, "app EXITED") != null);
    try t.expect(std.mem.indexOf(u8, note, "SIGSEGV") != null);
}

test "a no-repaint verdict names the app when it had already stopped painting" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();
    const args = try parseTestValue(arena, "{\"wait_change\":true,\"timeout_ms\":150,\"settle_ms\":0}");

    // The window was painting a moment before the input: a dry wait is
    // genuinely ambiguous (dead area vs an app that reacts silently),
    // and must still say so.
    fixture.app.windows.items[0].last_commit_ms = clock.nowMs() - 100;
    var live = PostInputWait.begin(args, fixture.app, 1, false);
    const live_note = try live.finish(arena, fixture.app, 1);
    try t.expect(std.mem.indexOf(u8, live_note, "dead area") != null);
    try t.expect(std.mem.indexOf(u8, live_note, "WAS painting") != null);
    try t.expect(std.mem.indexOf(u8, live_note, "LIVENESS") == null);

    // The window had been silent for 10s BEFORE the input. This input
    // cannot have caused that, and the first evidence of a hang must
    // not read as a click that missed.
    fixture.app.windows.items[0].last_commit_ms = clock.nowMs() - 10_000;
    var hung = PostInputWait.begin(args, fixture.app, 1, false);
    try t.expect(hung.quietBeforeMs() >= APP_QUIET_HANG_MS);
    const hung_note = try hung.finish(arena, fixture.app, 1);
    try t.expect(std.mem.indexOf(u8, hung_note, "APP LIVENESS WARNING") != null);
    try t.expect(std.mem.indexOf(u8, hung_note, "app_backtrace") != null);
    try t.expect(std.mem.indexOf(u8, hung_note, "dead area") == null);
}

test "watchChanges reports a still window as measured, not as an empty sample" {
    const t = std.testing;
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();

    var res = try fixture.app.watchChanges(1, 250, 2.0, null, 8, 2);
    defer res.deinit(t.allocator);
    // Nothing commits on this fixture: no events, and — the load-bearing
    // part — a frame total of zero, which is what separates "the app is
    // painting and the content did not change" from "the app is dead".
    try t.expectEqual(@as(usize, 0), res.events.len);
    try t.expectEqual(@as(u64, 0), res.frames);
    try t.expectEqual(@as(u64, 1), res.frame_first);
    try t.expect(!res.truncated);
    try t.expect(res.elapsed_ms >= 200);

    // No such window is an error, never a silent empty timeline.
    try t.expectError(appdrive.Error.NoSuchWindow, fixture.app.watchChanges(99, 50, 2.0, null, 4, 0));
}

test "app_click reports a crash during its held click" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();
    try t.expectEqual(@as(usize, 0), app_state.apps.count());
    app_state.ready = true;
    try app_state.apps.put(t.allocator, 1, fixture.app);
    defer {
        // Driving a real app tool records into the PROCESS-GLOBAL
        // journal (and its nudge/log-delta siblings), which only the
        // server's own shutdown normally clears — so without this the
        // entries outlive the test and are reported against
        // t.allocator. It leaked only on some orderings, because a
        // later test reusing these globals could happen to free them.
        Journal.deinitAll();
        LogDelta.deinitAll();
        MacroNudge.deinitAll();
        _ = app_state.apps.fetchSwapRemove(1);
        app_state.apps.deinit(t.allocator);
        app_state.apps = .empty;
        app_state.ready = false;
    }

    const args = try parseTestValue(arena, "{\"app\":1,\"window\":1,\"x\":0,\"y\":0,\"mark\":false,\"wait_change\":true,\"timeout_ms\":500}");
    const sender = try std.Thread.spawn(.{}, DelayedExit.send, .{DelayedExit{ .fd = fixture.peer, .status = -11 }});
    defer sender.join();
    const result = try @import("mcp_app.zig").appTool(arena, .app_click, args);
    const parsed = try expectToolResultShape(arena, "app_click", result);
    const sc = parsed.object.get("structuredContent").?.object;
    // The click's own facts survive the crash it triggered, and the
    // app's death is reported as app state, not as a click failure.
    try t.expectEqual(@as(i64, 1), sc.get("window").?.integer);
    try t.expect(sc.get("exited").?.bool);
    try t.expectEqual(@as(i64, 11), sc.get("signal").?.integer);
    try t.expect(sc.get("crashed").?.bool);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "app EXITED") != null);
    try t.expect(std.mem.indexOf(u8, text, "SIGSEGV") != null);
    try t.expect(std.mem.indexOf(u8, text, "click failed") == null);
    try t.expect(std.mem.indexOf(u8, text, "no pixels yet") == null);
}

test "app tools speak both lanes: windows, wait, pointer and the roster" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();
    app_state.ready = true;
    try app_state.apps.put(t.allocator, 1, fixture.app);
    defer {
        Journal.deinitAll();
        LogDelta.deinitAll();
        MacroNudge.deinitAll();
        _ = app_state.apps.fetchSwapRemove(1);
        app_state.apps.deinit(t.allocator);
        app_state.apps = .empty;
        app_state.ready = false;
    }
    const app_tools = @import("mcp_app.zig");

    // 1. app_windows: the window list is a fact, the prose names it.
    const windows = try app_tools.appTool(arena, .app_windows, try parseTestValue(arena, "{\"app\":1}"));
    const wparsed = try expectToolResultShape(arena, "app_windows", windows);
    const wsc = wparsed.object.get("structuredContent").?.object;
    try t.expectEqual(@as(i64, 1), wsc.get("app").?.integer);
    try t.expect(!wsc.get("exited").?.bool);
    try t.expectEqual(@as(usize, 1), wsc.get("windows").?.array.items.len);
    try t.expectEqual(@as(i64, 1), wsc.get("windows").?.array.items[0].object.get("window").?.integer);
    try t.expectEqual(@as(i64, 1), wsc.get("primary_window").?.integer);
    const wtext = wparsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, wtext, "window 1: 1x1") != null);

    // 2. app_wait: the verdict is a fact (mode + settled), and the
    //    frame arithmetic that used to hide in prose is machine data.
    const waited = try app_tools.appTool(arena, .app_wait, try parseTestValue(arena, "{\"app\":1,\"quiet_ms\":10,\"timeout_ms\":200}"));
    const waparsed = try expectToolResultShape(arena, "app_wait", waited);
    const wasc = waparsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("idle", wasc.get("mode").?.string);
    try t.expect(wasc.get("settled").?.bool);
    try t.expectEqual(@as(i64, 0), wasc.get("frames_committed").?.integer);
    try t.expectEqual(@as(i64, 1), wasc.get("window").?.integer);

    // 3. app_mouse_move with no coordinates is a QUERY, and says so
    //    rather than pretending it moved anything.
    const ptr = try app_tools.appTool(arena, .app_mouse_move, try parseTestValue(arena, "{\"app\":1}"));
    const pparsed = try expectToolResultShape(arena, "app_mouse_move", ptr);
    const psc = pparsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("query", psc.get("mode").?.string);
    try t.expect(!psc.get("tracked").?.bool);

    // 4. list_apps: one entry per session, plus a count.
    const listed = try app_tools.appTool(arena, .list_apps, try parseTestValue(arena, "{}"));
    const lparsed = try expectToolResultShape(arena, "list_apps", listed);
    const lsc = lparsed.object.get("structuredContent").?.object;
    try t.expectEqual(@as(i64, 1), lsc.get("count").?.integer);
    try t.expectEqual(@as(i64, 1), lsc.get("apps").?.array.items[0].object.get("app").?.integer);

    // 5. An unknown app id is a typed not_found, never a bare failure.
    const missing = try app_tools.appTool(arena, .app_windows, try parseTestValue(arena, "{\"app\":99}"));
    const mparsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, missing, .{});
    try t.expect(mparsed.object.get("isError").?.bool);
    try t.expectEqualStrings("not_found", mparsed.object.get("structuredContent").?.object.get("error").?.object.get("code").?.string);
}

test "app_wait with no window WAITS for one and reports first_window instead of erroring" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, false);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();
    app_state.ready = true;
    try app_state.apps.put(t.allocator, 1, fixture.app);
    defer {
        MacroNudge.deinitAll();
        _ = app_state.apps.fetchSwapRemove(1);
        app_state.apps.deinit(t.allocator);
        app_state.apps = .empty;
        app_state.ready = false;
    }
    const app_tools = @import("mcp_app.zig");
    // Every mode used to answer "no rendered window yet" (an error) or
    // "settled, 0 frames" at once; all three now block on the window.
    for ([_][]const u8{ "{\"app\":1,\"timeout_ms\":150}", "{\"app\":1,\"timeout_ms\":150,\"change_pct\":2}", "{\"app\":1,\"timeout_ms\":150,\"min_frames\":1}" }) |json| {
        const t0 = clock.nowMs();
        const waited = try app_tools.appTool(arena, .app_wait, try parseTestValue(arena, json));
        const parsed = try expectToolResultShape(arena, "app_wait", waited);
        const sc = parsed.object.get("structuredContent").?.object;
        try t.expectEqualStrings("first_window", sc.get("mode").?.string);
        try t.expect(!sc.get("settled").?.bool);
        try t.expect(!sc.get("window_appeared").?.bool);
        try t.expectEqual(@as(i64, 0), sc.get("window").?.integer);
        try t.expect(clock.nowMs() - t0 >= 140);
        const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
        try t.expect(std.mem.indexOf(u8, text, "NO WINDOW rendered within 150ms") != null);
    }
}

test "screenshot_app path writes a full-resolution PNG and inline:false skips the image" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();
    app_state.ready = true;
    try app_state.apps.put(t.allocator, 1, fixture.app);
    defer {
        MacroNudge.deinitAll();
        _ = app_state.apps.fetchSwapRemove(1);
        app_state.apps.deinit(t.allocator);
        app_state.apps = .empty;
        app_state.ready = false;
    }
    const app_tools = @import("mcp_app.zig");
    const path = try std.fmt.allocPrint(arena, "/tmp/sketerm-mcp-shot-test-{d}.png", .{c.getpid()});
    defer _ = c.unlink(path.ptr);
    const pathz_ = try arena.dupeZ(u8, path);
    _ = c.unlink(pathz_.ptr);
    const args = try std.fmt.allocPrint(arena, "{{\"app\":1,\"window\":1,\"path\":\"{s}\",\"inline\":false}}", .{path});
    const result = try app_tools.appTool(arena, .screenshot_app, try parseTestValue(arena, args));
    const parsed = try expectToolResultShape(arena, "screenshot_app", result);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings(path, sc.get("path").?.string);
    try t.expectEqual(@as(i64, 1), sc.get("file_w").?.integer);
    try t.expectEqual(@as(i64, 1), sc.get("file_h").?.integer);
    // No image block inline, and the file holds exactly the reported bytes.
    for (parsed.object.get("content").?.array.items) |blk| try t.expectEqualStrings("text", blk.object.get("type").?.string);
    var st: c.struct_stat = undefined;
    try t.expectEqual(@as(c_int, 0), c.stat(pathz_.ptr, &st));
    try t.expectEqual(sc.get("file_bytes").?.integer, @as(i64, @intCast(st.st_size)));
    // A relative path is refused before anything is captured.
    const bad = try app_tools.appTool(arena, .screenshot_app, try parseTestValue(arena, "{\"app\":1,\"window\":1,\"path\":\"shot.png\"}"));
    const bparsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, bad, .{});
    try t.expect(bparsed.object.get("isError").?.bool);
}

test "get_app_state stats_only still reports the app it describes" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();
    app_state.ready = true;
    try app_state.apps.put(t.allocator, 1, fixture.app);
    defer {
        Journal.deinitAll();
        LogDelta.deinitAll();
        MacroNudge.deinitAll();
        _ = app_state.apps.fetchSwapRemove(1);
        app_state.apps.deinit(t.allocator);
        app_state.apps = .empty;
        app_state.ready = false;
    }

    // stats_only is a documented get_app_state option, and this tool's
    // schema requires `app`: the cheap-probe exit skipped the app
    // summary that the image and burst exits both emit.
    const args = try parseTestValue(arena, "{\"app\":1,\"window\":1,\"stats_only\":true}");
    const result = try @import("mcp_app.zig").appTool(arena, .get_app_state, args);
    const parsed = try expectToolResultShape(arena, "get_app_state", result);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqual(@as(i64, 1), sc.get("app").?.integer);
    try t.expectEqual(@as(i64, 1), sc.get("window").?.integer);
    try t.expect(!sc.get("exited").?.bool);
    try t.expect(sc.get("diff_scope") != null);
}

test "app_actions wait_image reports exit instead of template timeout" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, false);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();

    const png_bytes = try png_util.encodeRgba(arena, &.{ 255, 0, 0, 255 }, 1, 1);
    const enc = std.base64.standard.Encoder;
    const b64 = try arena.alloc(u8, enc.calcSize(png_bytes.len));
    _ = enc.encode(b64, png_bytes);
    const json = try std.fmt.allocPrint(
        arena,
        "{{\"actions\":[{{\"wait_image\":{{\"image_b64\":\"{s}\",\"timeout_ms\":1000}}}},{{\"wait\":1}}]}}",
        .{b64},
    );
    const root = try parseTestValue(arena, json);
    const sender = try std.Thread.spawn(.{}, DelayedExit.send, .{DelayedExit{ .fd = fixture.peer, .status = -11 }});
    defer sender.join();
    const result = try @import("mcp_app.zig").runActionSteps(arena, fixture.app, root.object.get("actions").?.array.items, null, false, null);
    const parsed = try expectToolResultShape(arena, "app_actions", result);
    try t.expectEqualStrings("app_exited", parsed.object.get("structuredContent").?.object.get("status").?.string);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "app EXITED during wait_image") != null);
    try t.expect(std.mem.indexOf(u8, text, "template") == null or std.mem.indexOf(u8, text, "not found") == null);
}

test "chromiumFamily basename matching" {
    const t = std.testing;
    try t.expect(chromiumFamily("chromium"));
    try t.expect(chromiumFamily("/usr/bin/chromium"));
    try t.expect(chromiumFamily("/opt/google/chrome/google-chrome-stable"));
    try t.expect(chromiumFamily("brave-browser"));
    try t.expect(chromiumFamily("electron22"));
    try t.expect(!chromiumFamily("firefox"));
    try t.expect(!chromiumFamily("/usr/bin/gedit"));
}

test "buildLaunchArgv: args array appends; string command + args = bare executable" {
    const t = std.testing;
    const a = t.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parse = struct {
        fn go(al: std.mem.Allocator, json: []const u8) std.json.Value {
            return std.json.parseFromSliceLeaky(std.json.Value, al, json, .{}) catch unreachable;
        }
    }.go;

    // String command alone: shell-wrapped (unchanged behavior).
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        const r = try buildLaunchArgv(arena, &argv, parse(arena, "{\"command\":\"echo hi\"}"));
        try t.expect(r == .ok and !r.ok.argv_form);
        try t.expectEqual(@as(usize, 3), argv.items.len);
        try t.expectEqualStrings("/bin/sh", argv.items[0]);
        try t.expectEqualStrings("echo hi", argv.items[2]);
    }
    // String command + args: BARE executable + argv — the regression
    // (args used to be silently dropped, so the app saw argc==1).
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        const r = try buildLaunchArgv(arena, &argv, parse(arena, "{\"command\":\"/opt/game/bin\",\"args\":[\"/data/dir\",\"-w\",\"-nobink\"]}"));
        try t.expect(r == .ok and r.ok.argv_form);
        try t.expectEqual(@as(usize, 4), argv.items.len);
        try t.expectEqualStrings("/opt/game/bin", argv.items[0]);
        try t.expectEqualStrings("/data/dir", argv.items[1]);
        try t.expectEqualStrings("-nobink", argv.items[3]);
    }
    // Array command + args: appended.
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        const r = try buildLaunchArgv(arena, &argv, parse(arena, "{\"command\":[\"/opt/game/bin\",\"-w\"],\"args\":[\"-nobink\"]}"));
        try t.expect(r == .ok and r.ok.argv_form);
        try t.expectEqual(@as(usize, 3), argv.items.len);
        try t.expectEqualStrings("-nobink", argv.items[2]);
    }
    // Bad shapes are described errors, not silent drops.
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        const r = try buildLaunchArgv(arena, &argv, parse(arena, "{\"command\":\"x\",\"args\":\"-w\"}"));
        try t.expect(r == .err);
    }
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        const r = try buildLaunchArgv(arena, &argv, parse(arena, "{\"args\":[\"-w\"]}"));
        try t.expect(r == .err);
    }
}

test "applyDebugWrap: gdb_commands become crash-point -ex args before --args" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parse = struct {
        fn go(al: std.mem.Allocator, json: []const u8) std.json.Value {
            return std.json.parseFromSliceLeaky(std.json.Value, al, json, .{}) catch unreachable;
        }
    }.go;

    // gdb + gdb_commands: -ex pairs land AFTER info registers, BEFORE --args.
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.appendSlice(arena, &.{ "/opt/app", "-w" });
        const r = try applyDebugWrap(arena, &argv, parse(arena, "{\"debug\":\"gdb\",\"gdb_commands\":[\"frame 3\",\"p *ctx\"]}"));
        try t.expect(r == .note);
        const has = struct {
            fn go(items: []const []const u8, needle: []const u8) bool {
                for (items) |it| {
                    if (std.mem.eql(u8, it, needle)) return true;
                }
                return false;
            }
        }.go;
        try t.expectEqualStrings("gdb", argv.items[0]);
        try t.expectEqualStrings("-batch", argv.items[2]);
        // Nuisance signals are passed through, or batch mode reports
        // the wrong stop and quits before the real fault.
        try t.expect(has(argv.items, "handle SIGPIPE nostop noprint pass"));
        try t.expect(has(argv.items, "handle SIG33 nostop noprint pass"));
        // A worker-thread crash needs every thread's stack.
        try t.expect(has(argv.items, "thread apply all bt full"));
        try t.expect(has(argv.items, "info registers"));
        // run precedes the reporting commands.
        var run_at: usize = 0;
        var bt_at: usize = 0;
        for (argv.items, 0..) |it, i| {
            if (std.mem.eql(u8, it, "run")) run_at = i;
            if (std.mem.eql(u8, it, "thread apply all bt full")) bt_at = i;
        }
        try t.expect(run_at > 0 and bt_at > run_at);
        // User commands run at the crash point, in order, last.
        const tail = argv.items[argv.items.len - 7 ..];
        const want_tail = [_][]const u8{ "-ex", "frame 3", "-ex", "p *ctx", "--args", "/opt/app", "-w" };
        for (want_tail, tail) |w, g| try t.expectEqualStrings(w, g);
        try t.expect(std.mem.indexOf(u8, r.note, "2 extra gdb command(s)") != null);
    }
    // Plain gdb: unchanged shape, --args directly after info registers.
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.append(arena, "/opt/app");
        const r = try applyDebugWrap(arena, &argv, parse(arena, "{\"debug\":\"gdb\"}"));
        try t.expect(r == .note);
        try t.expectEqualStrings("--args", argv.items[argv.items.len - 2]);
    }
    // gdb_commands without/with the wrong wrapper: described errors.
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.append(arena, "x");
        try t.expect((try applyDebugWrap(arena, &argv, parse(arena, "{\"gdb_commands\":[\"bt\"]}"))) == .err);
        try t.expect((try applyDebugWrap(arena, &argv, parse(arena, "{\"debug\":\"valgrind\",\"gdb_commands\":[\"bt\"]}"))) == .err);
        try t.expect((try applyDebugWrap(arena, &argv, parse(arena, "{\"debug\":\"gdb\",\"gdb_commands\":[\"\"]}"))) == .err);
        try t.expect((try applyDebugWrap(arena, &argv, parse(arena, "{\"debug\":\"gdb\",\"gdb_commands\":\"bt\"}"))) == .err);
        try t.expectEqualStrings("x", argv.items[0]); // argv untouched on error
    }
    // No debug param: no-op.
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.append(arena, "x");
        const r = try applyDebugWrap(arena, &argv, parse(arena, "{}"));
        try t.expect(r == .note and r.note.len == 0);
        try t.expectEqual(@as(usize, 1), argv.items.len);
    }
}
