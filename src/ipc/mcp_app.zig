//! MCP forwarded-app tools — appTool dispatch, the app_actions step
//! engine (runActionSteps), and appToolTail — split out of mcp.zig.
//! Shared server state stays in mcp.zig and is referenced through it.

const std = @import("std");
const c = @import("../c.zig").c;
const atomicwrite = @import("../util/atomicwrite.zig");
const appdrive = @import("appdrive.zig");
const mcp = @import("mcp.zig");
const imageResultTagged = mcp.imageResultTagged;
const appStopText = mcp.appStopText;
const imagesResult = mcp.imagesResult;
const LogLineJ = mcp.LogLineJ;
const wallNowMs = mcp.wallNowMs;
const withActionStatus = mcp.withActionStatus;
const ActionStatus = mcp.ActionStatus;
const LogReplyJ = mcp.LogReplyJ;
const imagesResultTagged = mcp.imagesResultTagged;
const logStashTail = mcp.logStashTail;
const findWordRun = mcp.findWordRun;
const needsLiveApp = mcp.needsLiveApp;
const CATCHUP_MS = mcp.CATCHUP_MS;
const OcrOut = mcp.OcrOut;
const ocrWindow = mcp.ocrWindow;
const appIdOf = mcp.appIdOf;
const clickTuned = mcp.clickTuned;
const exitSuffix = mcp.exitSuffix;
const Journal = mcp.Journal;
const findInWindow = mcp.findInWindow;
const inputResult = mcp.inputResult;
const FoundMatch = mcp.FoundMatch;
const appFromArgs = mcp.appFromArgs;
const journalStepJson = mcp.journalStepJson;
const PostInputWait = mcp.PostInputWait;
const png_util = mcp.png_util;
const resolveNeedle = mcp.resolveNeedle;
const Watchdog = mcp.Watchdog;
const actionsCapture = mcp.actionsCapture;
const mcpassets = mcp.mcpassets;
const a11yNodeSummary = mcp.a11yNodeSummary;
const imageResult = mcp.imageResult;
const regionFrom = mcp.regionFrom;
const Tuning = mcp.Tuning;
const a11yFindMatch = mcp.a11yFindMatch;
const screenshotCaption = mcp.screenshotCaption;
const a11yFetch = mcp.a11yFetch;
const appSummary = mcp.appSummary;
const firstToplevelId = mcp.firstToplevelId;
const argBool = mcp.argBool;
const monoMs = mcp.monoMs;
const numArray = mcp.numArray;
const applyDebugWrap = mcp.applyDebugWrap;
const argStr = mcp.argStr;
const reportActionStop = mcp.reportActionStop;
const chromiumFamily = mcp.chromiumFamily;
const journalStep = mcp.journalStep;
const probeAppStop = mcp.probeAppStop;
const buildLaunchArgv = mcp.buildLaunchArgv;
const marks_mod = mcp.marks_mod;
const toolResult = mcp.toolResult;
const AppStop = mcp.AppStop;
const appErr = mcp.appErr;
const argFloat = mcp.argFloat;
const argInt = mcp.argInt;

/// The caller named this path, so an existing file keeps its own mode.
fn saveRecording(path: []const u8, bytes: []const u8) atomicwrite.Error!void {
    try atomicwrite.writeFile(path, bytes, 0o600);
}

pub fn appTool(arena: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    if (!mcp.app_state.ready)
        return appErr(arena, "app tools unavailable (server not fully started)");

    if (eql(u8, name, "launch_app")) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        const built = switch (try buildLaunchArgv(arena, &argv, args)) {
            .ok => |b| b,
            .err => |msg| return appErr(arena, msg),
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
                browser_note = "\n(auto-added --ozone-platform=wayland: Chromium-family app in a Wayland-only session)";
            }
        }
        const debug_note = switch (try applyDebugWrap(arena, &argv, args)) {
            .note => |n| n,
            .err => |e| return appErr(arena, e),
        };
        const audio_mode = argStr(args, "audio") orelse "forward";
        if (!eql(u8, audio_mode, "forward") and !eql(u8, audio_mode, "none"))
            return appErr(arena, "'audio' must be \"forward\" or \"none\"");
        const audio_path = argStr(args, "audio_path");
        if (audio_path) |ap| {
            if (eql(u8, audio_mode, "none"))
                return appErr(arena, "'audio_path' needs the sink: drop audio:\"none\"");
            if (ap.len == 0 or ap[0] != '/')
                return appErr(arena, "'audio_path' must be an absolute path (it lands on the daemon's host)");
        }
        const cols: u16 = @intCast(std.math.clamp(argInt(args, "cols") orelse 80, 10, 500));
        const rows: u16 = @intCast(std.math.clamp(argInt(args, "rows") orelse 24, 4, 300));
        const wait_ms: i64 = argInt(args, "wait_ms") orelse 10_000;
        var out_w: u32 = 0;
        var out_h: u32 = 0;
        if (argStr(args, "size")) |sz| {
            const dims = @import("../mux/display.zig").parseSize(sz) orelse
                return appErr(arena, "'size' must be \"WxH\" pixels (1..16384 per side, at most 64 megapixels), e.g. \"3840x2160\"");
            out_w = dims[0];
            out_h = dims[1];
        }
        var env_list: std.ArrayList([]const u8) = .empty;
        defer env_list.deinit(arena);
        var user_set_ozone_hint = false;
        if (args == .object) {
            if (args.object.get("env")) |e| {
                if (e != .object) return appErr(arena, "'env' must be an object of KEY: \"value\" strings");
                var it = e.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* != .string)
                        return appErr(arena, "'env' values must be strings");
                    if (std.mem.eql(u8, entry.key_ptr.*, "ELECTRON_OZONE_PLATFORM_HINT")) user_set_ozone_hint = true;
                    try env_list.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.string }));
                }
            }
        }
        // Electron apps honor this hint and ignore it otherwise; the
        // session has no X server, so wayland is the right default.
        if (!user_set_ozone_hint)
            try env_list.append(arena, "ELECTRON_OZONE_PLATFORM_HINT=wayland");
        const app = appdrive.App.launch(mcp.app_state.allocator, argv.items, .{
            .cols = cols,
            .rows = rows,
            .host = argStr(args, "host"),
            .kb_layout = argStr(args, "layout"),
            .local_sock = mcp.app_state.mux_sock,
            .gpu = argBool(args, "gpu"),
            .no_audio = eql(u8, audio_mode, "none"),
            .audio_capture = audio_path,
            .cwd = argStr(args, "cwd"),
            .env = env_list.items,
            .output_width = out_w,
            .output_height = out_h,
        }) catch |err|
            return appErr(arena, switch (err) {
                appdrive.Error.SpawnFailed => blk: {
                    const why = appdrive.lastLaunchErr();
                    break :blk if (why.len > 0)
                        try std.fmt.allocPrint(arena, "spawn failed — {s}", .{why})
                    else
                        "spawn failed (mux daemon unreachable or spawn refused)";
                },
                appdrive.Error.BadLayout => "unknown keyboard layout (available: us, gb, fr, be, de)",
                else => "launch failed",
            });
        const id = mcp.app_state.next_id;
        mcp.app_state.next_id += 1;
        mcp.app_state.apps.put(mcp.app_state.allocator, id, app) catch {
            app.deinit();
            return error.OutOfMemory;
        };
        const wait_for = argStr(args, "wait_for") orelse "window";
        if (eql(u8, wait_for, "exit")) {
            const deadline = monoMs() + wait_ms;
            while (!app.exited and monoMs() < deadline) _ = app.pumpOnce(50);
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
        var summary = try appSummary(arena, app);
        if (out_w != 0 and (app.output_width != out_w or app.output_height != out_h)) {
            summary = if (app.output_width == 0)
                try std.fmt.allocPrint(arena, "{s}\nWARNING: the daemon did not confirm the requested {d}x{d} output (older daemon — 'size' was likely ignored, the screen stays 1920x1080)", .{ summary, out_w, out_h })
            else
                try std.fmt.allocPrint(arena, "{s}\nWARNING: requested {d}x{d} output but the daemon applied {d}x{d}", .{ summary, out_w, out_h, app.output_width, app.output_height });
        }
        if (browser_note.len > 0) summary = try std.fmt.allocPrint(arena, "{s}{s}", .{ summary, browser_note });
        if (debug_note.len > 0) summary = try std.fmt.allocPrint(arena, "{s}{s}", .{ summary, debug_note });
        if (audio_path) |ap| {
            const stem = if (std.mem.endsWith(u8, ap, ".wav")) ap[0 .. ap.len - 4] else ap;
            summary = try std.fmt.allocPrint(arena, "{s}\naudio capture: {s}.wav on the daemon host (later streams: {s}-N.wav; finalized when the stream or app closes)", .{ summary, stem, stem });
        }
        // Launch-and-look is THE common case: when a window rendered,
        // fold the first screenshot into the launch reply.
        if (shot_win != 0 and !app.exited) {
            var shot_frames: u64 = 0;
            for (app.windows.items) |win| {
                if (win.id == shot_win) shot_frames = win.frames;
            }
            if (!settled)
                summary = try std.fmt.allocPrint(arena, "{s}\n(inline screenshot: window was STILL REPAINTING after the {d}ms settle wait — it may be mid-paint or the app animates continuously; screenshot_app with stable_ms/min_frame gets settled pixels)", .{ summary, stable_ms })
            else if (shot_frames <= 1)
                summary = try std.fmt.allocPrint(arena, "{s}\n(inline screenshot is the window's FIRST committed frame and may precede the app's real paint — screenshot_app with stable_ms gets settled content)", .{summary});
            if (app.screenshotPng(shot_win, 1568, null, 1)) |shot| {
                defer mcp.app_state.allocator.free(shot.png);
                const caption = try screenshotCaption(arena, app, shot_win, shot, summary);
                if (imageResult(arena, caption, shot.png)) |r| return r;
            } else |_| {}
        }
        return toolResult(arena, summary, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "list_installed_apps")) {
        const listing = appdrive.listInstalledApps(mcp.app_state.allocator, argStr(args, "host"), mcp.app_state.mux_sock) catch |err|
            return appErr(arena, switch (err) {
                appdrive.Error.SpawnFailed => "cannot reach the daemon (is sketerm-mux running / host reachable?)",
                else => "app discovery failed",
            });
        defer mcp.app_state.allocator.free(listing);
        return toolResult(arena, listing, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "list_apps")) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("[");
        var first = true;
        for (mcp.app_state.apps.values()) |app| {
            app.drain();
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll(try appSummary(arena, app));
        }
        try w.writeAll("]");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }

    if (eql(u8, name, "app_templates")) {
        if (argStr(args, "delete")) |del| {
            mcpassets.delete(mcp.app_state.allocator, .template, del) catch |err| return appErr(arena, switch (err) {
                mcpassets.Error.NotFound => "no such template",
                mcpassets.Error.BadName => "invalid template name",
                else => "delete failed",
            });
            return toolResult(arena, "template deleted", false) orelse error.OutOfMemory;
        }
        const names = mcpassets.list(mcp.app_state.allocator, .template) catch
            return appErr(arena, "listing templates failed");
        defer {
            for (names) |nm| mcp.app_state.allocator.free(nm);
            mcp.app_state.allocator.free(names);
        }
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("[");
        for (names, 0..) |nm, i| {
            if (i > 0) try w.writeAll(",");
            var dims: []const u8 = "";
            if (mcpassets.load(arena, .template, nm)) |bytes| {
                if (png_util.decodeRgba(arena, bytes)) |dec| {
                    arena.free(dec.rgba);
                    dims = try std.fmt.allocPrint(arena, ",\"w\":{d},\"h\":{d}", .{ dec.w, dec.h });
                } else |_| {}
            } else |_| {}
            try w.print("{{\"name\":{f}{s}}}", .{ std.json.fmt(nm, .{}), dims });
        }
        try w.writeAll("]");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_template_save")) {
        const tname = argStr(args, "name") orelse return appErr(arena, "app_template_save requires 'name'");
        if (!mcpassets.validName(tname))
            return appErr(arena, "invalid template name (letters, digits, . _ - only, max 64)");
        var png_bytes: []const u8 = undefined;
        var dw: u32 = 0;
        var dh: u32 = 0;
        if (argStr(args, "image_b64")) |b64| {
            const decoder = std.base64.standard.Decoder;
            const max = decoder.calcSizeForSlice(b64) catch return appErr(arena, "image_b64 is not valid base64");
            const raw = try arena.alloc(u8, max);
            decoder.decode(raw, b64) catch return appErr(arena, "image_b64 is not valid base64");
            const dec = png_util.decodeRgba(arena, raw) catch
                return appErr(arena, "image_b64 does not decode as an image");
            arena.free(dec.rgba);
            dw = dec.w;
            dh = dec.h;
            png_bytes = raw;
        } else {
            const capp = appFromArgs(args) orelse
                return appErr(arena, "pass 'app' (capture from its window) or 'image_b64' (inline PNG)");
            capp.drain();
            const region = regionFrom(args) orelse
                return appErr(arena, "capturing needs 'region' {x,y,w,h} — crop JUST the distinctive UI element (a whole window makes a useless template)");
            const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(capp);
            if (wid == 0) return appErr(arena, "no rendered window yet (try app_wait first)");
            const shot = capp.snapshotRgba(wid, region) catch
                return appErr(arena, "no rendered pixels in that window (yet?)");
            defer mcp.app_state.allocator.free(shot.px);
            dw = shot.w;
            dh = shot.h;
            png_bytes = png_util.encodeRgba(arena, shot.px, shot.w, shot.h) catch return error.OutOfMemory;
        }
        mcpassets.save(mcp.app_state.allocator, .template, tname, png_bytes) catch |err| return appErr(arena, switch (err) {
            mcpassets.Error.TooBig => "template too large (8 MB cap)",
            else => "saving the template failed (state dir not writable?)",
        });
        const msg = try std.fmt.allocPrint(arena, "template \"{s}\" saved ({d}x{d}) — match it with app_find_image / app_wait_image or the wait_image / click_image action steps", .{ tname, dw, dh });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_macros")) {
        if (argStr(args, "delete")) |del| {
            mcpassets.delete(mcp.app_state.allocator, .macro, del) catch |err| return appErr(arena, switch (err) {
                mcpassets.Error.NotFound => "no such macro",
                mcpassets.Error.BadName => "invalid macro name",
                else => "delete failed",
            });
            return toolResult(arena, "macro deleted", false) orelse error.OutOfMemory;
        }
        if (argStr(args, "show")) |nm| {
            const bytes = mcpassets.load(arena, .macro, nm) catch |err| return appErr(arena, switch (err) {
                mcpassets.Error.NotFound => "no such macro",
                mcpassets.Error.BadName => "invalid macro name",
                mcpassets.Error.OutOfMemory => return error.OutOfMemory,
                else => "macro load failed",
            });
            return toolResult(arena, bytes, false) orelse error.OutOfMemory;
        }
        if (argBool(args, "journal")) {
            const capp = appFromArgs(args) orelse
                return appErr(arena, "the journal view needs 'app' (recorded steps are per app)");
            const entries = Journal.entriesOf(appIdOf(capp));
            var aw: std.Io.Writer.Allocating = .init(arena);
            const w = &aw.writer;
            try w.print("{d} recorded input step(s), oldest first (save the tail with app_macro_save last_steps:N):\n", .{entries.len});
            for (entries, 0..) |e, i| {
                try w.print("{d}. {s}\n", .{ i + 1, e.step });
            }
            return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
        }
        const names = mcpassets.list(mcp.app_state.allocator, .macro) catch
            return appErr(arena, "listing macros failed");
        defer {
            for (names) |nm| mcp.app_state.allocator.free(nm);
            mcp.app_state.allocator.free(names);
        }
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("[");
        for (names, 0..) |nm, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{f}", .{std.json.fmt(nm, .{})});
        }
        try w.writeAll("]");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_macro_save")) {
        const mname = argStr(args, "name") orelse return appErr(arena, "app_macro_save requires 'name'");
        if (!mcpassets.validName(mname))
            return appErr(arena, "invalid macro name (letters, digits, . _ - only, max 64)");
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("{\"actions\":[");
        var count: usize = 0;
        var from_journal = false;
        if (args == .object and args.object.get("actions") != null) {
            const av = args.object.get("actions").?;
            if (av != .array or av.array.items.len == 0)
                return appErr(arena, "'actions' must be a non-empty array of step objects");
            if (av.array.items.len > 200) return appErr(arena, "too many steps (max 200)");
            for (av.array.items, 0..) |st, i| {
                if (st != .object) return appErr(arena, "each action step must be an object");
                if (i > 0) try w.writeAll(",");
                std.json.Stringify.value(st, .{}, w) catch return error.OutOfMemory;
            }
            count = av.array.items.len;
        } else {
            from_journal = true;
            const capp = appFromArgs(args) orelse
                return appErr(arena, "recording from the journal needs 'app' (or pass explicit 'actions')");
            const entries = Journal.entriesOf(appIdOf(capp));
            if (entries.len == 0)
                return appErr(arena, "no recorded input steps for this app yet — drive it (app_click / app_key / app_actions / ...), then save");
            var take: usize = entries.len;
            if (argInt(args, "last_steps")) |ls| {
                if (ls <= 0) return appErr(arena, "'last_steps' must be positive");
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
        mcpassets.save(mcp.app_state.allocator, .macro, mname, aw.written()) catch |err| return appErr(arena, switch (err) {
            mcpassets.Error.TooBig => "macro too large",
            else => "saving the macro failed (state dir not writable?)",
        });
        const msg = try std.fmt.allocPrint(arena, "macro \"{s}\" saved ({d} step(s){s}) — replay with app_macro_run, inspect with app_macros show", .{
            mname, count, if (from_journal) ", wait gaps preserved" else "",
        });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }

    const app = switch (mcp.appSelect(arena, args)) {
        .app => |a| a,
        .err => |e| return appErr(arena, e),
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
    // Observation tools (output/log/windows/screenshot/state/actions/
    // wait/record_stop) handle exit themselves; close_app stays
    // idempotent.
    if ((app.exited or app.presentationGone()) and needsLiveApp(name)) {
        _ = probeAppStop(app, 1_000);
        const summary = try appSummary(arena, app);
        const msg = try std.fmt.allocPrint(arena, "the app has exited or disconnected - {s} needs a running app\n{s}", .{ name, summary });
        return toolResult(arena, msg, true) orelse error.OutOfMemory;
    }

    if (eql(u8, name, "app_windows")) {
        const summary = try appSummary(arena, app);
        return toolResult(arena, summary, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_output")) {
        const text = app.output(argBool(args, "scrollback")) catch
            return appErr(arena, "no terminal mirror for this app (output unavailable)");
        defer mcp.app_state.allocator.free(text);
        var msg: []const u8 = try arena.dupe(u8, text);
        if (std.mem.trim(u8, text, " \n\t\r").len == 0) {
            // A blank grid mirror does not mean "no output" — the log
            // ring (app_log) is the source of truth for line output.
            // Only the post-exit stash is served here; a live app's
            // log_buf may hold a stale earlier log_get reply.
            if (if (app.exited) logStashTail(arena, app, 25) else null) |tail_text| {
                msg = try std.fmt.allocPrint(arena, "(terminal grid mirror is blank — serving the last lines from the log ring instead; app_log is the source of truth for line output)\n{s}", .{tail_text});
            } else {
                msg = if (argBool(args, "scrollback"))
                    "(the app has written nothing to its stdout/stderr PTY — GUI apps often print little; stderr redirected elsewhere by the app itself is not visible here. app_log is the indexed view of the same PTY)"
                else
                    "(no output on the visible terminal grid — pass scrollback:true for scrolled-off history, or use app_log for indexed lines)";
            }
        }
        if (app.exited) {
            msg = try std.fmt.allocPrint(arena, "[app exited, status {d}{s}]\n{s}", .{
                app.exit_status,
                try exitSuffix(arena, app.exit_status),
                msg,
            });
        }
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_wait_log")) return waitLog(arena, app, args);
    if (eql(u8, name, "app_log")) {
        const line_id: u64 = @intCast(@max(argInt(args, "id") orelse 0, 0));
        const from_id: u64 = @intCast(@max(argInt(args, "from_id") orelse 0, 0));
        const filter: ?mcp.pattern.Matcher = switch (mcp.logFilterFrom(arena, args)) {
            .none => null,
            .m => |m| m,
            .err => |e| return appErr(arena, e),
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
                    defer mcp.app_state.allocator.free(grid);
                    const msg = try std.fmt.allocPrint(
                        arena,
                        "[log path timed out even over a fresh daemon connection (app alive: {}, windows: {d}, frames committed: {d}) — serving the PTY grid mirror instead; NO line ids, wrapped at the grid width]\n{s}",
                        .{ !app.exited, app.windows.items.len, frames, grid },
                    );
                    return toolResult(arena, msg, false) orelse error.OutOfMemory;
                } else |_| {}
                const msg = try std.fmt.allocPrint(
                    arena,
                    "the daemon's log reply did not arrive within 5s, a fresh side connection also failed, and no grid mirror is available (app alive: {}, windows: {d}, frames committed: {d})",
                    .{ !app.exited, app.windows.items.len, frames },
                );
                return appErr(arena, msg);
            },
            else => return appErr(arena, if (app.exited)
                "the app exited and its log stash is empty — no output was captured before exit (a known app id, distinct from 'unknown app')"
            else
                "log unavailable: the connection to the app's daemon was lost"),
        };
        const reply = fetch.json;
        defer mcp.app_state.allocator.free(reply);
        if (fetch.stale and line_id != 0)
            return appErr(arena, "the daemon's log reply did not arrive within 5s; only a stale cached snapshot is available, which cannot answer a single-line fetch honestly — retry in a moment");
        const parsed = std.json.parseFromSlice(LogReplyJ, arena, reply, .{
            .ignore_unknown_fields = true,
        }) catch return appErr(arena, "malformed log reply");
        const r = parsed.value;
        const now_wall: i64 = wallNowMs();

        if (line_id != 0) {
            // One line in full — the post-exit stash may return the whole
            // final log, so filter by id here.
            var found: ?LogLineJ = null;
            for (r.lines) |l| {
                if (l.id == line_id) found = l;
            }
            const l = found orelse
                return appErr(arena, "line not available (dropped from the ring, never emitted, or beyond the post-exit stash)");
            const age_s = @as(f64, @floatFromInt(now_wall - l.t)) / 1000.0;
            if (l.marker) {
                if (app.markerImage(line_id)) |img| {
                    const note = if (img.shared_from != 0)
                        try std.fmt.allocPrint(arena, " — window at that instant below (frame unchanged since marker {d}; screenshot shared)", .{img.shared_from})
                    else
                        " — window at that instant below";
                    const cap = try std.fmt.allocPrint(arena, "marker line {d} ({d:.1}s ago): '{s}'{s}", .{
                        l.id, age_s, l.text, note,
                    });
                    if (imageResult(arena, cap, img.png)) |res| return res;
                }
                const cap = try std.fmt.allocPrint(
                    arena,
                    "marker line {d} ({d:.1}s ago): '{s}' (no screenshot was stashed: no rendered window at the time, or the marker aged out)",
                    .{ l.id, age_s, l.text },
                );
                return toolResult(arena, cap, false) orelse error.OutOfMemory;
            }
            const msg = try std.fmt.allocPrint(arena, "line {d} ({d:.1}s ago{s}):\n{s}", .{
                l.id,                                                          age_s,
                if (l.truncated) ", was longer than the 4KB line cap" else "", l.text,
            });
            return toolResult(arena, msg, false) orelse error.OutOfMemory;
        }

        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        if (fetch.stale)
            try w.writeAll("[STALE: the daemon's fresh log reply was still queued behind streamed frame data after 5s — serving the last cached snapshot instead; retry app_log for current lines]\n");
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
        if (filter != null and lines.len == 0) {
            try w.print(
                "0 of {d} scanned line(s) match \"{s}\" (ids {d}..{d}). NOTHING is shown — this is not a tail: the pattern simply has not appeared yet. Wait for it with app_wait_log.",
                .{
                    r.lines.len,
                    argStr(args, "pattern") orelse argStr(args, "grep") orelse "",
                    if (r.lines.len > 0) r.lines[0].id else 0,
                    if (r.lines.len > 0) r.lines[r.lines.len - 1].id else 0,
                },
            );
        } else if (lines.len == 0) {
            try w.writeAll("(log empty — the app has not printed any complete line yet)");
        } else {
            if (filter != null) {
                try w.print("{d} of {d} scanned line(s) match \"{s}\"", .{
                    matched, r.lines.len, argStr(args, "pattern") orelse argStr(args, "grep") orelse "",
                });
                if (matched > lines.len) try w.print(" (newest {d} shown)", .{lines.len});
                try w.writeAll("; ");
            }
            try w.print("log lines {d}..{d} (newest id {d})", .{
                lines[0].id, lines[lines.len - 1].id, r.next_id - 1,
            });
            if (r.dropped > 0) try w.print(", {d} oldest dropped by the ring cap", .{r.dropped});
            if (r.markers_dropped > 0) try w.print(", {d} markers rate-limited", .{r.markers_dropped});
            try w.writeAll(" — [+] = shortened, fetch in full with {\"id\":N}\n");
            for (lines) |l| {
                const age_s = @as(f64, @floatFromInt(now_wall - l.t)) / 1000.0;
                if (l.marker) {
                    const has_shot = app.markerImage(l.id) != null;
                    try w.print("{d} [-{d:.1}s] [marker '{s}'{s}]\n", .{
                        l.id, age_s, l.text,
                        if (has_shot) " — screenshot stashed, view it via {\"id\":this line's id}" else "",
                    });
                } else {
                    try w.print("{d} [-{d:.1}s] {s}{s}\n", .{
                        l.id,                                     age_s, l.text,
                        if (l.cut or l.truncated) " [+]" else "",
                    });
                }
            }
        }
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "screenshot_app") or eql(u8, name, "get_app_state")) {
        var win_id: u32 = 0;
        if (argInt(args, "window")) |v| {
            win_id = @intCast(v);
        } else {
            win_id = firstToplevelId(app);
        }
        if (win_id == 0) {
            // "No window" and "the app died" are different answers —
            // report the exit (status, signal, output) when it applies.
            if (app.exited) {
                const summary = try appSummary(arena, app);
                const msg = try std.fmt.allocPrint(arena, "the app has exited — no window to screenshot\n{s}", .{summary});
                return toolResult(arena, msg, true) orelse error.OutOfMemory;
            }
            return appErr(arena, "no rendered window yet (try app_wait first)");
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
                return appErr(arena, try std.fmt.allocPrint(
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
                region = mcp.regionOf(rv) orelse return appErr(
                    arena,
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
                return appErr(arena, if (diff_region != null)
                    "the region's content did not change before the timeout"
                else
                    "window content did not change before the timeout");
        }
        var settle_note: []const u8 = "";
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
            if (!settled)
                settle_note = "\n[note: frames were still arriving at timeout_ms — captured anyway]";
        }
        if (argBool(args, "stats_only")) {
            // Cheap change probe: no PNG, just "did it change and how
            // much" vs whatever the caller last saw. With a region the
            // diff_pct is computed inside that rect only.
            const st = app.diffStats(win_id, region) catch
                return appErr(arena, "no such window / no pixels yet");
            const msg = try std.fmt.allocPrint(
                arena,
                "{{\"changed\":{},\"diff_pct\":{d:.2},\"resized\":{},\"w\":{d},\"h\":{d},\"frames\":{d}{s}}}{s}",
                .{ st.changed, st.diff_pct, st.resized, st.w, st.h, st.frames, if (region != null) ",\"diff_scope\":\"region\"" else "", settle_note },
            );
            return toolResult(arena, msg, false) orelse error.OutOfMemory;
        }
        const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse 1568, 0, 8192));
        const zoom: u32 = @intCast(std.math.clamp(argInt(args, "zoom") orelse 1, 1, 32));

        if (argInt(args, "burst")) |bn| if (bn > 1) {
            // Burst: up to N shots over a window of time, each gated on
            // a minimum pixel change vs the PREVIOUS shot — one call
            // instead of a screenshot-poll loop across a transition.
            const count: usize = @intCast(@min(bn, 8));
            const burst_ms: i64 = argInt(args, "burst_ms") orelse 5_000;
            const min_pct: f64 = argFloat(args, "min_change_pct") orelse 1.0;
            var pngs: std.ArrayList([]const u8) = .empty;
            defer {
                for (pngs.items) |p| mcp.app_state.allocator.free(p);
                pngs.deinit(arena);
            }
            var offsets: std.ArrayList(i64) = .empty;
            defer offsets.deinit(arena);
            const t0 = monoMs();
            var first: ?appdrive.App.Shot = null;
            while (monoMs() - t0 < burst_ms and pngs.items.len < count) {
                if (pngs.items.len > 0) {
                    _ = app.pumpOnce(25);
                    if (app.peekDiffPct(win_id, region) < min_pct) {
                        if (app.exited) break;
                        continue;
                    }
                }
                const shot = app.screenshotPng(win_id, max_px, region, zoom) catch break;
                pngs.append(arena, shot.png) catch {
                    mcp.app_state.allocator.free(shot.png);
                    break;
                };
                offsets.append(arena, monoMs() - t0) catch break;
                if (first == null) first = shot;
                if (app.exited) break;
            }
            const fshot = first orelse
                return appErr(arena, "no such window / no pixels yet (a region must lie inside the window)");
            var ob: std.ArrayList(u8) = .empty;
            defer ob.deinit(arena);
            for (offsets.items, 0..) |o, i| {
                var nb: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&nb, "{s}{d}ms", .{ if (i > 0) ", " else "", o }) catch break;
                try ob.appendSlice(arena, s);
            }
            const extra: []const u8 = if (eql(u8, name, "get_app_state")) try appSummary(arena, app) else "";
            const base_caption = try screenshotCaption(arena, app, win_id, fshot, extra);
            const caption = try std.fmt.allocPrint(arena, "{s}\nburst: {d} frame(s) captured at [{s}] (each >= {d:.1}% changed from the previous){s}", .{
                base_caption, pngs.items.len, ob.items, min_pct, settle_note,
            });
            return imagesResult(arena, caption, pngs.items) orelse error.OutOfMemory;
        };

        const shot = app.screenshotPng(win_id, max_px, region, zoom) catch
            return appErr(arena, "no such window / no pixels yet (a region must lie inside the window)");
        defer mcp.app_state.allocator.free(shot.png);
        const extra: []const u8 = if (eql(u8, name, "get_app_state")) try appSummary(arena, app) else "";
        const base_caption = try screenshotCaption(arena, app, win_id, shot, extra);
        const caption = if (settle_note.len > 0)
            try std.fmt.allocPrint(arena, "{s}{s}", .{ base_caption, settle_note })
        else
            base_caption;
        return imageResult(arena, caption, shot.png) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_drag")) {
        const win_id: u32 = @intCast(argInt(args, "window") orelse
            return appErr(arena, "app_drag requires 'window'"));
        const x1 = argInt(args, "x1") orelse return appErr(arena, "app_drag requires x1,y1,x2,y2");
        const y1 = argInt(args, "y1") orelse return appErr(arena, "app_drag requires x1,y1,x2,y2");
        const x2 = argInt(args, "x2") orelse return appErr(arena, "app_drag requires x1,y1,x2,y2");
        const y2 = argInt(args, "y2") orelse return appErr(arena, "app_drag requires x1,y1,x2,y2");
        const button: u32 = @intCast(argInt(args, "button") orelse 1);
        var piw = PostInputWait.begin(args, app, win_id, argBool(args, "screenshot"));
        app.drag(
            win_id,
            @floatFromInt(x1),
            @floatFromInt(y1),
            @floatFromInt(x2),
            @floatFromInt(y2),
            button,
        ) catch return appErr(arena, "drag failed (bad window?)");
        journalStep(app, "{{\"drag\":[{d},{d},{d},{d}],\"button\":{d},\"window\":{d}}}", .{ x1, y1, x2, y2, button, win_id });
        const desc = try std.fmt.allocPrint(arena, "dragged ({d},{d}) -> ({d},{d}) button {d}", .{ x1, y1, x2, y2, button });
        return inputResult(arena, app, args, win_id, &piw, desc);
    }
    if (eql(u8, name, "app_clipboard_get")) {
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 3_000;
        const bytes = app.getClipboard(timeout_ms) catch |err| return appErr(arena, switch (err) {
            appdrive.Error.NoClipboard => "the app has not announced a clipboard selection (copy something in it first)",
            appdrive.Error.Timeout => "app did not deliver clipboard data in time",
            else => "clipboard fetch failed",
        });
        defer mcp.app_state.allocator.free(bytes);
        const copy = try arena.dupe(u8, bytes);
        return toolResult(arena, copy, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_clipboard_set")) {
        const text = argStr(args, "text") orelse
            return appErr(arena, "app_clipboard_set requires 'text'");
        app.setClipboard(text) catch return appErr(arena, "clipboard set failed");
        if (argBool(args, "paste")) {
            const win: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
            app.pressKey(win, "ctrl+v") catch return appErr(arena, "paste keystroke failed (no window?)");
            _ = app.waitIdle(200, 2_000);
        }
        return toolResult(arena, "ok (the app sees this as the host clipboard)", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_click")) {
        const button: u32 = @intCast(argInt(args, "button") orelse 1);
        const win_id: u32 = @intCast(argInt(args, "window") orelse
            return appErr(arena, "app_click requires 'window' and x/y. To target a widget by name/role use app_perform_action (coordinate-free)."));
        const x = argInt(args, "x") orelse return appErr(arena, "app_click requires 'x'");
        const y = argInt(args, "y") orelse return appErr(arena, "app_click requires 'y'");
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
                    const detail = try appStopText(arena, stop, "the click");
                    const summary = try appSummary(arena, app);
                    const msg = try std.fmt.allocPrint(arena, "clicked ({d},{d}) button {d} - {s}\n{s}", .{ x, y, button, detail, summary });
                    return toolResult(arena, msg, false) orelse error.OutOfMemory;
                }
                return appErr(arena, "click failed (bad window?)");
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
            if (piw.quietBeforeMs() >= mcp.APP_QUIET_HANG_MS) break;
        }
        journalStep(app, "{{\"click\":[{d},{d}],\"button\":{d},\"window\":{d},\"hold_ms\":{d},\"count\":{d}}}", .{ x, y, button, win_id, hold_ms, count });
        if (stopped != null) {
            // Don't attempt the screenshot — it fails as "no pixels
            // yet?" and masks the crash the click just triggered.
            const summary = try appSummary(arena, app);
            const msg = try std.fmt.allocPrint(arena, "clicked ({d},{d}) button {d}{s}\n{s}", .{ x, y, button, note, summary });
            return toolResult(arena, msg, false) orelse error.OutOfMemory;
        }
        // Built once, after the retries: the log delta consumes the
        // lines it reports, so computing it per attempt would hand the
        // caller only whatever the LAST press happened to print.
        note = try std.fmt.allocPrint(arena, "{s} [window {d} frame {d} at input, {d} now — pass min_frame:{d} to screenshot_app for a provably post-click capture]{s}{s}", .{
            note,
            win_id,
            frame_at_input orelse 0,
            app.frameCount(win_id),
            frame_at_input orelse 0,
            mcp.logDeltaNote(arena, app, args),
            mcp.macroNudge(arena, app),
        });
        if (attempts > 1) {
            note = try std.fmt.allocPrint(arena, " — auto-retried: {d} attempts, earlier clicks produced no qualifying repaint{s}", .{ attempts, note });
        }
        const qual: []const u8 = if (count > 1)
            try std.fmt.allocPrint(arena, " x{d} ({s}, held {d}ms each)", .{ count, if (count == 2) "double-click" else "triple-click", hold_ms })
        else if (hold_ms > 0)
            try std.fmt.allocPrint(arena, " (held {d}ms)", .{hold_ms})
        else
            "";
        if (want_shot) {
            // Post-click frame, optionally with the click point drawn
            // in — one call shows where the click landed AND what the
            // UI did with it. The frame is captured only after the
            // window commits something NEWER than the click (bounded),
            // and the caption says explicitly when it never did.
            const annot = [_]marks_mod.Mark{.{ .x = @floatFromInt(x), .y = @floatFromInt(y) }};
            const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse 1568, 0, 8192));
            const shot = app.screenshotPngMarked(win_id, max_px, null, 1, if (want_mark) &annot else &.{}) catch
                if (probeAppStop(app, 1_000)) |stop| {
                    const detail = try appStopText(arena, stop, "the post-click capture");
                    const summary = try appSummary(arena, app);
                    const msg = try std.fmt.allocPrint(arena, "clicked ({d},{d}) button {d} - {s}\n{s}", .{ x, y, button, detail, summary });
                    return toolResult(arena, msg, false) orelse error.OutOfMemory;
                } else return toolResult(arena, "clicked, but the post-click screenshot failed (no pixels yet?)", false) orelse error.OutOfMemory;
            defer mcp.app_state.allocator.free(shot.png);
            const extra = try std.fmt.allocPrint(arena, "clicked ({d},{d}) button {d}{s}{s}{s}", .{
                x, y, button, qual, note,
                if (want_mark)
                    " — the red crosshair marks the click point on the post-click frame. Coordinates are delivered to the app verbatim; a pointer-LOCKED app tracks its own cursor from relative deltas, so its internal cursor can differ (calibrate with app_mouse_move dx/dy)."
                else
                    "",
            });
            const caption = try screenshotCaption(arena, app, win_id, shot, extra);
            return imageResultTagged(arena, caption, shot.png, "click") orelse error.OutOfMemory;
        }
        if (note.len > 0 or qual.len > 0) {
            const msg = try std.fmt.allocPrint(arena, "clicked ({d},{d}) button {d}{s}{s}", .{ x, y, button, qual, note });
            return toolResult(arena, msg, false) orelse error.OutOfMemory;
        }
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_actions")) {
        const actions_v = (if (args == .object) args.object.get("actions") else null) orelse
            return appErr(arena, "app_actions requires 'actions' (an array of step objects)");
        if (actions_v != .array) return appErr(arena, "'actions' must be an array of step objects");
        const steps = actions_v.array.items;
        if (steps.len == 0) return appErr(arena, "'actions' is empty");
        if (steps.len > 32) return appErr(arena, "too many steps (max 32)");
        const win_arg: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
        return runActionSteps(arena, app, steps, win_arg, true, "");
    }
    return appToolTail(arena, name, args, app);
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
fn waitLog(arena: std.mem.Allocator, app: *appdrive.App, args: std.json.Value) ![]const u8 {
    const m = switch (mcp.logFilterFrom(arena, args)) {
        .none => return appErr(arena, "app_wait_log requires 'pattern' (the log-line pattern to wait for)"),
        .m => |mm| mm,
        .err => |e| return appErr(arena, e),
    };
    const pat = argStr(args, "pattern") orelse argStr(args, "grep") orelse "";
    const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, mcp.WAIT_CAP_MS);
    // Default scans the WHOLE ring first, so an event that already
    // happened resolves immediately; from_id skips history when the
    // caller specifically needs a NEW occurrence.
    var from: u64 = @intCast(@max(argInt(args, "from_id") orelse 0, 0));
    const t0 = monoMs();
    const deadline = t0 + timeout_ms;
    var scanned: usize = 0;
    var newest: u64 = 0;
    while (true) {
        if (mcp.logFetchLines(arena, app, from, 500, 300, 5_000) catch null) |got| {
            for (got.reply.lines) |l| {
                if (l.id < from) continue;
                scanned += 1;
                newest = l.id;
                if (!m.matches(l.text)) continue;
                const elapsed = monoMs() - t0;
                const wid = firstToplevelId(app);
                const frame = app.frameCount(wid);
                const head = try std.fmt.allocPrint(
                    arena,
                    "matched \"{s}\" after {d}ms — log line {d}{s}:\n{s}\n(window {d} is at frame {d}; screenshot_app min_frame:{d} guarantees pixels committed after this line)",
                    .{ pat, elapsed, l.id, if (l.marker) " [marker]" else "", l.text, wid, frame, frame },
                );
                if (argBool(args, "screenshot") and wid != 0) {
                    if (app.screenshotPng(wid, 1568, null, 1)) |shot| {
                        defer mcp.app_state.allocator.free(shot.png);
                        const caption = try screenshotCaption(arena, app, wid, shot, head);
                        if (imageResult(arena, caption, shot.png)) |res| return res;
                    } else |_| {}
                }
                return toolResult(arena, head, false) orelse error.OutOfMemory;
            }
            // Follow forward: the next fetch starts past everything
            // seen, so a long-running wait costs one small round trip
            // per poll instead of re-scanning the ring.
            if (got.reply.next_id > 0) from = got.reply.next_id;
        }
        if (app.exited or app.presentationGone()) {
            _ = probeAppStop(app, 500);
            const summary = try appSummary(arena, app);
            const msg = try std.fmt.allocPrint(
                arena,
                "the app exited before any log line matched \"{s}\" ({d} line(s) scanned in {d}ms)\n{s}",
                .{ pat, scanned, monoMs() - t0, summary },
            );
            return toolResult(arena, msg, true) orelse error.OutOfMemory;
        }
        if (Watchdog.fired.load(.acquire))
            return appErr(arena, "app_wait_log aborted by the MCP hard timeout");
        if (monoMs() >= deadline) break;
        // Pumped sleep: keeps frames/exit flowing while we wait.
        _ = app.pumpOnce(200);
    }
    const msg = try std.fmt.allocPrint(
        arena,
        "no log line matched \"{s}\" within {d}ms ({d} line(s) scanned, newest id {d}). The app is still running — re-run with from_id:{d} to continue from here.",
        .{ pat, timeout_ms, scanned, newest, newest },
    );
    return toolResult(arena, msg, true) orelse error.OutOfMemory;
}

/// Execute an ordered batch of action steps against `app` — the
/// app_actions vocabulary, shared with macro replay (app_macro_run).
/// `record` journals each successful step for app_macro_save; `intro`
/// is written ahead of the per-step report.
pub fn runActionSteps(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    steps: []const std.json.Value,
    win_arg: ?u32,
    record: bool,
    intro: []const u8,
) ![]const u8 {
    const MAX_SHOTS = 8;

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    var pngs: std.ArrayList([]const u8) = .empty;
    defer {
        for (pngs.items) |p| mcp.app_state.allocator.free(p);
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
    if (intro.len > 0) try w.writeAll(intro);
    for (steps, 0..) |st, idx| {
        const n = idx + 1;
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
            const ms: i64 = std.math.clamp(if (wv == .integer) wv.integer else 0, 0, 30_000);
            _ = app.waitIdle(std.math.maxInt(i32), ms); // pure pumped sleep
            try w.print("step {d}: waited {d}ms\n", .{ n, ms });
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
                try w.print("step {d}: ERROR — wait_idle did not settle before timeout (required); remaining steps skipped\n", .{n});
                stopped = true;
                break;
            }
            try w.print("step {d}: wait_idle — {s}\n", .{ n, if (settled) "settled" else "TIMED OUT (still rendering)" });
        } else if (st.object.get("wait_change")) |wv| {
            var timeout_ms: i64 = 10_000;
            var min_pct: f64 = 0;
            if (wv == .integer) {
                timeout_ms = wv.integer;
            } else if (wv == .object) {
                if (argInt(wv, "timeout_ms")) |t| timeout_ms = t;
                if (argFloat(wv, "min_change_pct")) |p| min_pct = p;
            }
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
                try w.print("step {d}: ERROR — wait_change saw no change before timeout (required); remaining steps skipped\n", .{n});
                stopped = true;
                break;
            }
            try w.print("step {d}: wait_change — {s}\n", .{ n, if (changed) "content changed" else "TIMED OUT (no change)" });
        } else if (st.object.get("screenshot")) |sv| {
            const wid = win_step orelse firstToplevelId(app);
            if (wid == 0) {
                try w.print("step {d}: ERROR — no rendered window to screenshot\n", .{n});
                stopped = true;
                break;
            }
            if (pngs.items.len >= MAX_SHOTS) {
                try w.print("step {d}: screenshot SKIPPED (max {d} per call)\n", .{ n, MAX_SHOTS });
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
            const timeout_ms: i64 = if (is_wait) (argInt(wv, "timeout_ms") orelse 10_000) else 0;
            // click_image clicks by definition; wait_image opts in.
            const do_click = if (is_wait) argBool(wv, "click") else true;
            const btn: u32 = @intCast(argInt(wv, "button") orelse 1);
            const region = regionFrom(wv);
            const wid = win_step orelse firstToplevelId(app);
            const deadline = monoMs() + timeout_ms;
            var found: ?FoundMatch = null;
            while (true) {
                switch (try findInWindow(arena, app, wid, region, needle, min_score, 1)) {
                    .matches => |ms| if (ms.len > 0) {
                        found = ms[0];
                    },
                    .err => {}, // window not rendered yet — keep waiting
                }
                if (found != null or app.exited or app.presentationGone() or monoMs() >= deadline) break;
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
                try w.print("step {d}: ERROR — template \"{s}\" not found{s}\n", .{ n, needle.name, if (is_wait) " before timeout" else "" });
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
            const timeout_ms: i64 = argInt(wv, "timeout_ms") orelse 15_000;
            const do_click = argBool(wv, "click");
            const region = regionFrom(wv);
            const scale: u32 = @intCast(std.math.clamp(argInt(wv, "scale") orelse 0, 0, 8));
            const psm: i32 = @intCast(argInt(wv, "psm") orelse 6);
            const lang = argStr(wv, "lang") orelse "eng";
            const wid = win_step orelse firstToplevelId(app);
            const deadline = monoMs() + timeout_ms;
            var seen: ?OcrOut = null;
            var fatal: ?[]const u8 = null;
            while (true) {
                switch (try ocrWindow(arena, app, wid, region, scale, psm, lang)) {
                    .out => |o| {
                        if (std.ascii.indexOfIgnoreCase(o.text, query) != null) seen = o;
                    },
                    .err => |e| {
                        // "not rendered yet" is transient; a missing
                        // OCR engine never resolves — stop now.
                        if (!std.mem.startsWith(u8, e, "no rendered")) fatal = e;
                    },
                }
                if (seen != null or fatal != null or app.exited or app.presentationGone() or monoMs() >= deadline) break;
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
                try w.print("step {d}: ERROR — text \"{s}\" not visible before timeout\n", .{ n, query });
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
        // Journal the step VERBATIM once it succeeded (pure
        // screenshot steps `continue`d above and are not steps a
        // macro needs to repeat).
        if (record) {
            var jw: std.Io.Writer.Allocating = .init(arena);
            std.json.Stringify.value(st, .{}, &jw.writer) catch {};
            Journal.record(appIdOf(app), jw.written());
        }
    }
    // `mark` without any screenshot still yields an image: capture
    // the final state with the leftover marks drawn in.
    if (!stopped and pending_marks.items.len > 0 and pngs.items.len < MAX_SHOTS) {
        const wid = win_arg orelse firstToplevelId(app);
        if (wid != 0)
            _ = try actionsCapture(arena, app, w, &pngs, &shot_tags, &pending_marks, wid, 1568, "end of batch");
    }
    if (!stopped) try w.print("all {d} steps completed\n", .{steps.len});
    if (app_stop != null or app.exited or app.presentationGone()) try w.writeAll(try appSummary(arena, app));
    const base = if (pngs.items.len > 0)
        imagesResultTagged(arena, aw.written(), pngs.items, shot_tags.items) orelse return error.OutOfMemory
    else
        toolResult(arena, aw.written(), false) orelse return error.OutOfMemory;
    const status: ActionStatus = if (app_stop) |stop|
        .{ .app_exited = .{ .step = stop_step, .stop = stop } }
    else if (stopped)
        .failed
    else
        .completed;
    return withActionStatus(arena, base, status) orelse error.OutOfMemory;
}

/// Continuation of appTool (split around the step engine so
/// runActionSteps can live between the two halves).
pub fn appToolTail(arena: std.mem.Allocator, name: []const u8, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const eql = std.mem.eql;
    if (eql(u8, name, "app_mouse_move")) {
        const win: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
        const has_abs = argFloat(args, "x") != null and argFloat(args, "y") != null;
        const has_rel = argFloat(args, "dx") != null or argFloat(args, "dy") != null;
        if (has_abs and has_rel)
            return appErr(arena, "pass x/y (absolute) OR dx/dy (relative), not both");
        var pos: appdrive.App.PtrPos = undefined;
        if (has_abs) {
            pos = app.moveMouse(win, argFloat(args, "x").?, argFloat(args, "y").?) catch
                return appErr(arena, "move failed (bad window?)");
        } else if (has_rel) {
            pos = app.moveMouseRel(win, argFloat(args, "dx") orelse 0, argFloat(args, "dy") orelse 0) catch
                return appErr(arena, "move failed (bad window?)");
        } else {
            pos = app.pointerPos() orelse
                return toolResult(arena, "no pointer position tracked yet (nothing moved/clicked in this app)", false) orelse error.OutOfMemory;
        }
        if (has_abs or has_rel) _ = app.waitIdle(100, 1_000);
        if (has_abs) {
            journalStep(app, "{{\"move\":[{d:.0},{d:.0}]}}", .{ pos.x, pos.y });
        } else if (has_rel) {
            journalStep(app, "{{\"move_rel\":[{d:.0},{d:.0}]}}", .{ argFloat(args, "dx") orelse 0, argFloat(args, "dy") orelse 0 });
        }
        const msg = try std.fmt.allocPrint(arena, "{{\"window\":{d},\"x\":{d:.0},\"y\":{d:.0}}}", .{ pos.win, pos.x, pos.y });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_perform_action")) {
        const elem_id = argStr(args, "element") orelse
            return appErr(arena, "app_perform_action requires 'element' (an id from app_a11y_tree)");
        const index: i64 = argInt(args, "index") orelse 0;
        const payload = try std.fmt.allocPrint(arena, "{{\"op\":\"action\",\"id\":{f},\"index\":{d}}}", .{
            std.json.fmt(elem_id, .{}),
            index,
        });
        const reply = app.a11yOp(payload, argInt(args, "timeout_ms") orelse 5_000) catch
            return appErr(arena, "a11y action failed (daemon unreachable?)");
        defer mcp.app_state.allocator.free(reply);
        if (std.mem.indexOf(u8, reply, "\"ok\"") == null)
            return appErr(arena, try arena.dupe(u8, reply));
        _ = app.waitIdle(200, 2_000);
        return toolResult(arena, "action performed", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_set_value")) {
        const elem_id = argStr(args, "element") orelse
            return appErr(arena, "app_set_value requires 'element' (an id from app_a11y_tree)");
        var payload: []const u8 = undefined;
        if (argStr(args, "text")) |text| {
            payload = try std.fmt.allocPrint(arena, "{{\"op\":\"set_text\",\"id\":{f},\"text\":{f}}}", .{
                std.json.fmt(elem_id, .{}),
                std.json.fmt(text, .{}),
            });
        } else if (args == .object and args.object.get("value") != null) {
            const v = args.object.get("value").?;
            const num: f64 = switch (v) {
                .integer => |iv| @floatFromInt(iv),
                .float => |fl| fl,
                else => return appErr(arena, "'value' must be a number"),
            };
            payload = try std.fmt.allocPrint(arena, "{{\"op\":\"set_value\",\"id\":{f},\"value\":{d}}}", .{
                std.json.fmt(elem_id, .{}),
                num,
            });
        } else return appErr(arena, "app_set_value requires 'text' (text fields) or 'value' (sliders/spinners)");
        const reply = app.a11yOp(payload, argInt(args, "timeout_ms") orelse 5_000) catch
            return appErr(arena, "a11y set failed (daemon unreachable?)");
        defer mcp.app_state.allocator.free(reply);
        if (std.mem.indexOf(u8, reply, "\"ok\"") == null)
            return appErr(arena, try arena.dupe(u8, reply));
        _ = app.waitIdle(200, 2_000);
        return toolResult(arena, "value set", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_wait_for_element")) {
        const role: ?i64 = argInt(args, "role");
        const name_sub = argStr(args, "name");
        if (role == null and name_sub == null)
            return appErr(arena, "app_wait_for_element requires 'role' and/or 'name'");
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 10_000, 0, mcp.WAIT_CAP_MS);
        const deadline = monoMs() + timeout_ms;
        while (true) {
            switch (a11yFetch(arena, app, 5_000)) {
                .tree => |t| if (a11yFindMatch(t, role, name_sub)) |node| {
                    const summary = try a11yNodeSummary(arena, node);
                    return toolResult(arena, summary, false) orelse error.OutOfMemory;
                },
                .err => {}, // tree not up yet — keep polling
            }
            app.drain();
            if (app.exited) {
                const summary = try appSummary(arena, app);
                const msg = try std.fmt.allocPrint(arena, "the app exited while waiting for an element\n{s}", .{summary});
                return toolResult(arena, msg, true) orelse error.OutOfMemory;
            }
            if (Watchdog.fired.load(.acquire))
                return appErr(arena, "element wait aborted by the MCP hard timeout");
            if (monoMs() >= deadline) {
                // Distinguish "not there yet" from "this app has no
                // accessible tree at all" — the second never resolves,
                // so waiting again is pure waste.
                if (app.a11yTree(2_000)) |raw| {
                    defer mcp.app_state.allocator.free(raw);
                    const copy = try arena.dupe(u8, raw);
                    if (mcp.a11yTreeIsBare(arena, copy))
                        return appErr(arena, "this app publishes NO accessibility tree at all (only the desktop registry is on the bus), so no element will ever appear here — raw SDL/OpenGL/framebuffer apps and games have no toolkit to publish one. Drive it with screenshot_app + app_click, or app_wait_image with a saved template.");
                } else |_| {}
                return appErr(arena, "element did not appear before the timeout");
            }
            var ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 300 * 1000 * 1000 };
            _ = c.nanosleep(&ts, null);
        }
    }
    if (eql(u8, name, "app_type")) {
        const text = argStr(args, "text") orelse return appErr(arena, "app_type requires 'text'");
        const win: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
        const wait_win: u32 = win orelse firstToplevelId(app);
        var piw = PostInputWait.begin(args, app, wait_win, argBool(args, "screenshot"));
        app.typeText(win, text) catch |err| return appErr(arena, switch (err) {
            appdrive.Error.BadKey => "text contains a character outside the us keymap",
            else => "type failed (no window?)",
        });
        journalStepJson(app, arena, "type", text, "");
        const desc = try std.fmt.allocPrint(arena, "typed {d} chars", .{text.len});
        return inputResult(arena, app, args, wait_win, &piw, desc);
    }
    if (eql(u8, name, "app_key")) {
        const keys = argStr(args, "keys") orelse return appErr(arena, "app_key requires 'keys'");
        const win: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
        const wait_win: u32 = win orelse firstToplevelId(app);
        const hold_ms: i64 = std.math.clamp(argInt(args, "hold_ms") orelse 0, 0, 10_000);
        var piw = PostInputWait.begin(args, app, wait_win, argBool(args, "screenshot"));
        var it = std.mem.tokenizeScalar(u8, keys, ' ');
        while (it.next()) |spec| {
            app.pressKeyHold(win, spec, hold_ms) catch |err| return appErr(arena, switch (err) {
                appdrive.Error.BadKey => "unknown key chord",
                else => "key press failed (no window?)",
            });
        }
        const extra: []const u8 = if (hold_ms > 0)
            try std.fmt.allocPrint(arena, ",\"hold_ms\":{d}", .{hold_ms})
        else
            "";
        journalStepJson(app, arena, "key", keys, extra);
        const desc = if (hold_ms > 0)
            try std.fmt.allocPrint(arena, "pressed (each held {d}ms): {s}", .{ hold_ms, keys })
        else
            try std.fmt.allocPrint(arena, "pressed: {s}", .{keys});
        return inputResult(arena, app, args, wait_win, &piw, desc);
    }
    if (eql(u8, name, "app_scroll")) {
        const win_id: u32 = @intCast(argInt(args, "window") orelse
            return appErr(arena, "app_scroll requires 'window'"));
        const x = argInt(args, "x") orelse 10;
        const y = argInt(args, "y") orelse 10;
        const dx = argInt(args, "dx") orelse 0;
        const dy = argInt(args, "dy") orelse 0;
        var piw = PostInputWait.begin(args, app, win_id, argBool(args, "screenshot"));
        app.scroll(win_id, @floatFromInt(x), @floatFromInt(y), @floatFromInt(dx), @floatFromInt(dy)) catch
            return appErr(arena, "scroll failed (bad window?)");
        journalStep(app, "{{\"scroll\":[{d},{d}],\"at\":[{d},{d}],\"window\":{d}}}", .{ dx, dy, x, y, win_id });
        const desc = try std.fmt.allocPrint(arena, "scrolled ({d},{d}) at ({d},{d})", .{ dx, dy, x, y });
        return inputResult(arena, app, args, win_id, &piw, desc);
    }
    if (eql(u8, name, "app_resize")) {
        const win_id: u32 = @intCast(argInt(args, "window") orelse
            return appErr(arena, "app_resize requires 'window'"));
        const w = argInt(args, "w") orelse return appErr(arena, "app_resize requires 'w'");
        const h = argInt(args, "h") orelse return appErr(arena, "app_resize requires 'h'");
        app.resizeWindow(win_id, @intCast(w), @intCast(h)) catch
            return appErr(arena, "resize failed (bad window?)");
        _ = app.waitIdle(300, 3_000);
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_wait")) {
        const quiet_ms: i64 = argInt(args, "quiet_ms") orelse 400;
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 10_000, 0, mcp.WAIT_CAP_MS);
        const was_exited = app.exited;
        const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
        // Every verdict carries the frame delta actually observed. Both
        // failure modes reported from the field were unreadable without
        // it: a still splash screen "settles" instantly (0 frames, no
        // sign that the app is merely showing a static image), and an
        // app busy inside its draw path reads as "settled (no new
        // frames)" identically to a wedged one.
        const frames_before = app.frameCount(wid);
        const t0 = monoMs();
        var outcome: []const u8 = undefined;
        if (argInt(args, "min_frames")) |mf| {
            // Liveness by COMMIT COUNT: the only wait that means
            // anything on an app which never visually quiesces, and the
            // honest opposite of settling on a static frame.
            const want: u64 = @intCast(@max(mf, 1));
            if (wid == 0) return appErr(arena, "no rendered window yet (min_frames needs one)");
            if (app.waitFrameAfter(wid, frames_before + want - 1, timeout_ms)) {
                outcome = try std.fmt.allocPrint(arena, "committed {d} new frame(s) within {d}ms", .{ want, monoMs() - t0 });
            } else {
                // Falling short is USUALLY arithmetic, not a fault: an
                // app at 12fps cannot deliver 1400 frames in 115s no
                // matter how healthy it is. Reporting that as "it is
                // not painting" was a false alarm frequent enough to
                // train callers to ignore the message — which is the
                // worst possible reflex, because the same message is
                // how a real freeze announces itself. Only ZERO frames
                // is a liveness claim now.
                outcome = try shortFramesVerdict(arena, wid, app.frameCount(wid) - frames_before, want, monoMs() - t0, timeout_ms);
            }
        } else if (argFloat(args, "change_pct")) |pct| {
            // Visual quiescence: frames may keep committing (a game
            // always renders) — settle when they stop CHANGING much.
            // A region scopes the percentage to that rect.
            if (wid == 0) return appErr(arena, "no rendered window yet (change_pct needs one)");
            outcome = if (app.waitVisualSettle(wid, quiet_ms, timeout_ms, pct, regionFrom(args)))
                try std.fmt.allocPrint(arena, "settled (frames changed <{d:.1}% of pixels for {d}ms)", .{ pct, quiet_ms })
            else
                // NOT an error: for a game or a video this is the
                // expected steady state, so it must not read as failure.
                try std.fmt.allocPrint(arena, "ALIVE AND ANIMATING, never quiesced: frames kept changing >{d:.1}% of pixels for the whole {d}ms. This is the normal state for a game/video and is not a failure — to synchronise on something real, wait on the app's own log (app_wait_log) or on a frame count (min_frames)", .{ pct, timeout_ms });
        } else {
            outcome = if (app.waitIdle(quiet_ms, timeout_ms))
                try std.fmt.allocPrint(arena, "settled (no new frames for {d}ms). NOTE: no commits is not the same as no work — an app busy inside its draw path, or one showing a static splash, settles here instantly; use min_frames for liveness", .{quiet_ms})
            else
                "ALIVE AND RENDERING, never quiesced: new frames kept arriving for the whole timeout. This is normal for a continuously-animating app, not a failure — pass change_pct (e.g. 2) for VISUAL quiescence, min_frames for liveness, or app_wait_log to synchronise on an actual event";
        }
        const delta = app.frameCount(wid) - frames_before;
        // The settle waits return "settled" on exit — say what really
        // happened, with the signal, instead of a bogus quiet verdict.
        if (app.exited) {
            outcome = if (was_exited)
                "the app has already exited (details below)"
            else
                try std.fmt.allocPrint(arena, "app EXITED during the wait (status {d}{s}) — backtrace/report in app_log", .{ app.exit_status, try exitSuffix(arena, app.exit_status) });
        }
        const summary = try appSummary(arena, app);
        const msg = try std.fmt.allocPrint(arena, "{s}\nobserved: window {d} committed {d} frame(s) during the {d}ms wait (now at frame {d})\n{s}", .{
            outcome, wid, delta, monoMs() - t0, app.frameCount(wid), summary,
        });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_watch")) return appWatch(arena, app, args);
    if (eql(u8, name, "app_hover_map")) return hoverMap(arena, app, args);
    if (eql(u8, name, "app_backtrace")) return appBacktrace(arena, app, args);
    if (eql(u8, name, "app_a11y_tree")) {
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 5_000, 0, mcp.WAIT_CAP_MS);
        const tree = app.a11yTree(timeout_ms) catch |err| return appErr(arena, switch (err) {
            appdrive.Error.Timeout => "timed out reading the accessibility tree",
            else => "accessibility read failed",
        });
        defer mcp.app_state.allocator.free(tree);
        const copy = try arena.dupe(u8, tree);
        // "The app published nothing" and "you asked too early" look
        // identical in the raw JSON — both are a registry root with a
        // couple of desktop services under it. Say which one it is:
        // steering the caller toward the coordinate-free path when that
        // path does not exist for this app costs whole turns.
        if (mcp.a11yTreeIsBare(arena, copy)) {
            const msg = try std.fmt.allocPrint(arena,
                \\NO ACCESSIBLE TREE: this app publishes no widgets on the a11y bus — the tree holds only the desktop registry and background services, with nothing below them. Raw SDL / OpenGL / framebuffer apps and games have no toolkit to publish one, so this will not appear later and waiting longer will not help. app_perform_action and app_set_value cannot drive this app; use screenshot_app + app_click coordinates instead, and app_template_save / app_find_image / app_wait_image to locate elements without hardcoding pixels. (If the app IS a GTK/Qt program, it may still be starting: retry once after app_wait.)
                \\{s}
            , .{copy});
            return toolResult(arena, msg, false) orelse error.OutOfMemory;
        }
        // Prepend the AT-SPI role legend so the assistant can read
        // numeric roles without a lookup.
        const msg = try std.fmt.allocPrint(arena,
            \\AT-SPI tree. Each node has an "id" — pass it to app_perform_action (press/activate/toggle a widget) or app_set_value (write a text field/slider) to drive the app WITHOUT coordinates; that is the reliable path. Roles (common): 8 checkbox, 14 dialog/frame, 18 filler, 25 label, 28 menu, 29 menubar, 30 menuitem, 34 canvas, 35 page-tab, 37 panel, 42 push-button, 43 radiobutton, 44 root/desktop, 46 scrollbar, 60 table, 62 text, 71 toolbar, 74 tree, 75 application, 84 entry. Note: "rect" is unreliable for headless apps (no screen position), so prefer perform_action/set_value over pixel clicks.
            \\{s}
        , .{copy});
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_record_start")) {
        var win_id: u32 = 0;
        if (argInt(args, "window")) |v| {
            win_id = @intCast(v);
        } else {
            win_id = firstToplevelId(app);
        }
        if (win_id == 0) return appErr(arena, "no rendered window yet (try app_wait first)");
        // WebM/VP9 is the default (smaller, higher quality); format:"gif"
        // for the animated GIF.
        const want_gif = if (argStr(args, "format")) |fmt| std.mem.eql(u8, fmt, "gif") else false;
        const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse (if (want_gif) @as(i64, 800) else 1280), 0, 4096));
        const fps: u32 = @intCast(std.math.clamp(argInt(args, "fps") orelse 0, 0, 60));
        app.recordStart(win_id, max_px, !want_gif, fps) catch return appErr(arena, "no such window");
        return toolResult(arena, "recording — frames are captured while other app tools run (click/type/wait); call app_record_stop to finish", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_record_stop")) {
        const result = app.recordStop() catch |err| return appErr(arena, switch (err) {
            appdrive.Error.NotRecording => "no recording in progress (app_record_start first)",
            else => "recording produced no frames",
        });
        defer mcp.app_state.allocator.free(result.data);
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
        const ext = if (result.webm) "webm" else "gif";
        const path = argStr(args, "path") orelse
            try std.fmt.allocPrint(arena, "/tmp/sketerm-rec-{d}-{d}.{s}", .{ c.getpid(), ts.tv_sec, ext });
        saveRecording(path, result.data) catch |err| {
            const msg = try std.fmt.allocPrint(arena, "cannot save the recording: {s}", .{@errorName(err)});
            return appErr(arena, msg);
        };
        const msg = try std.fmt.allocPrint(arena, "saved {d} frames ({d} KiB {s}) to {s}", .{ result.frames, result.data.len / 1024, ext, path });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_read_text")) {
        const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
        if (wid == 0) return appErr(arena, "no rendered window yet (try app_wait first)");
        const region = regionFrom(args);
        const scale: u32 = @intCast(std.math.clamp(argInt(args, "scale") orelse 0, 0, 8));
        const psm: i32 = @intCast(std.math.clamp(argInt(args, "psm") orelse 6, 0, 13));
        const lang = argStr(args, "lang") orelse "eng";
        switch (try ocrWindow(arena, app, wid, region, scale, psm, lang)) {
            .err => |e| return appErr(arena, e),
            .out => |o| {
                var aw: std.Io.Writer.Allocating = .init(arena);
                const w = &aw.writer;
                try w.print("{{\"window\":{d},\"ocr_scale\":{d},\"text\":", .{ wid, o.scale });
                try std.json.Stringify.value(o.text, .{}, w);
                try w.writeAll(",\"words\":[");
                for (o.words, 0..) |wd, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"text\":{f},\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"cx\":{d},\"cy\":{d},\"conf\":{d:.0}}}", .{
                        std.json.fmt(wd.text, .{}), wd.x,            wd.y,    wd.w, wd.h,
                        wd.x + wd.w / 2,            wd.y + wd.h / 2, wd.conf,
                    });
                }
                try w.writeAll("]}");
                return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
            },
        }
    }
    if (eql(u8, name, "app_wait_text")) {
        const query = argStr(args, "text") orelse return appErr(arena, "app_wait_text requires 'text'");
        const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
        if (wid == 0) return appErr(arena, "no rendered window yet (try app_wait first)");
        const region = regionFrom(args);
        const scale: u32 = @intCast(std.math.clamp(argInt(args, "scale") orelse 0, 0, 8));
        const psm: i32 = @intCast(std.math.clamp(argInt(args, "psm") orelse 6, 0, 13));
        const lang = argStr(args, "lang") orelse "eng";
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 15_000, 0, mcp.WAIT_CAP_MS);
        const do_click = argBool(args, "click");
        const deadline = monoMs() + timeout_ms;
        var seen: ?OcrOut = null;
        var last_text: []const u8 = "";
        while (true) {
            switch (try ocrWindow(arena, app, wid, region, scale, psm, lang)) {
                .out => |o| {
                    last_text = o.text;
                    if (std.ascii.indexOfIgnoreCase(o.text, query) != null) seen = o;
                },
                .err => |e| {
                    if (!std.mem.startsWith(u8, e, "no rendered")) return appErr(arena, e);
                },
            }
            if (seen != null or app.exited or monoMs() >= deadline) break;
            _ = app.waitIdle(std.math.maxInt(i32), 300); // pumped sleep between OCR passes
        }
        const o = seen orelse {
            const tail = if (last_text.len > 500) last_text[last_text.len - 500 ..] else last_text;
            const msg = try std.fmt.allocPrint(arena, "text \"{s}\" not visible before timeout; last OCR read:\n{s}", .{ query, tail });
            return toolResult(arena, msg, true) orelse error.OutOfMemory;
        };
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.print("{{\"found\":true,\"window\":{d}", .{wid});
        if (findWordRun(o.words, query)) |box| {
            try w.print(",\"match\":{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"cx\":{d},\"cy\":{d}}}", .{
                box.x, box.y, box.w, box.h, box.x + box.w / 2, box.y + box.h / 2,
            });
            if (do_click) {
                clickTuned(app, wid, @floatFromInt(box.x + box.w / 2), @floatFromInt(box.y + box.h / 2), 1) catch
                    return appErr(arena, "text found but the click failed (bad window?)");
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
                try w.writeAll(",\"clicked\":true");
            }
        } else if (do_click) {
            try w.writeAll(",\"match\":null,\"clicked\":false,\"note\":\"text visible but OCR gave no clickable word box\"");
        } else {
            try w.writeAll(",\"match\":null");
        }
        try w.writeAll("}");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_find_image")) {
        const needle = switch (try resolveNeedle(arena, args)) {
            .needle => |nd| nd,
            .err => |e| return appErr(arena, e),
        };
        const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
        if (wid == 0) return appErr(arena, "no rendered window yet (try app_wait first)");
        const min_score = argFloat(args, "min_score") orelse 0.9;
        const max_matches: usize = @intCast(std.math.clamp(argInt(args, "max_matches") orelse 8, 1, 32));
        switch (try findInWindow(arena, app, wid, regionFrom(args), needle, min_score, max_matches)) {
            .err => |e| return appErr(arena, e),
            .matches => |ms| {
                var aw: std.Io.Writer.Allocating = .init(arena);
                const w = &aw.writer;
                try w.print("{{\"template\":{f},\"template_w\":{d},\"template_h\":{d},\"window\":{d},\"matches\":[", .{
                    std.json.fmt(needle.name, .{}), needle.w, needle.h, wid,
                });
                for (ms, 0..) |m, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"x\":{d},\"y\":{d},\"cx\":{d},\"cy\":{d},\"score\":{d:.3}}}", .{ m.x, m.y, m.cx, m.cy, m.score });
                }
                try w.writeAll("]}");
                return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
            },
        }
    }
    if (eql(u8, name, "app_wait_image")) {
        const needle = switch (try resolveNeedle(arena, args)) {
            .needle => |nd| nd,
            .err => |e| return appErr(arena, e),
        };
        const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
        if (wid == 0) return appErr(arena, "no rendered window yet (try app_wait first)");
        const region = regionFrom(args);
        const min_score = argFloat(args, "min_score") orelse 0.9;
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 10_000, 0, mcp.WAIT_CAP_MS);
        const do_click = argBool(args, "click");
        const btn: u32 = @intCast(argInt(args, "button") orelse 1);
        const deadline = monoMs() + timeout_ms;
        var found: ?FoundMatch = null;
        while (true) {
            switch (try findInWindow(arena, app, wid, region, needle, min_score, 1)) {
                .matches => |ms| if (ms.len > 0) {
                    found = ms[0];
                },
                .err => {}, // window not rendered yet — keep waiting
            }
            if (found != null or app.exited or monoMs() >= deadline) break;
            _ = app.pumpOnce(50);
        }
        const m = found orelse {
            const msg = try std.fmt.allocPrint(arena, "template \"{s}\" did not appear before timeout", .{needle.name});
            return toolResult(arena, msg, true) orelse error.OutOfMemory;
        };
        var clicked = false;
        if (do_click) {
            clickTuned(app, wid, @floatFromInt(m.cx), @floatFromInt(m.cy), btn) catch
                return appErr(arena, "template matched but the click failed (bad window?)");
            _ = app.waitIdle(100, 1_000);
            clicked = true;
            // Journal as a replayable step (named templates only —
            // an inline image has no stable reference to replay).
            if (!std.mem.eql(u8, needle.name, "(inline)"))
                journalStep(app, "{{\"wait_image\":{{\"template\":\"{s}\",\"click\":true,\"min_score\":{d:.2}}}}}", .{ needle.name, min_score });
        }
        const msg = try std.fmt.allocPrint(arena, "{{\"found\":true,\"window\":{d},\"x\":{d},\"y\":{d},\"cx\":{d},\"cy\":{d},\"score\":{d:.3},\"clicked\":{}}}", .{
            wid, m.x, m.y, m.cx, m.cy, m.score, clicked,
        });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_macro_run")) {
        const mname = argStr(args, "name") orelse return appErr(arena, "app_macro_run requires 'name'");
        const bytes = mcpassets.load(arena, .macro, mname) catch |err| return appErr(arena, switch (err) {
            mcpassets.Error.NotFound => try std.fmt.allocPrint(arena, "no saved macro \"{s}\" (list with app_macros)", .{mname}),
            mcpassets.Error.BadName => "invalid macro name",
            mcpassets.Error.OutOfMemory => return error.OutOfMemory,
            else => "macro load failed",
        });
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch
            return appErr(arena, "stored macro is not valid JSON");
        if (parsed != .object) return appErr(arena, "stored macro is malformed (want {\"actions\":[...]})");
        const av = parsed.object.get("actions") orelse return appErr(arena, "stored macro has no 'actions'");
        if (av != .array or av.array.items.len == 0) return appErr(arena, "stored macro has no steps");
        if (av.array.items.len > 200) return appErr(arena, "macro too long (max 200 steps)");
        const win_arg: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
        const intro = try std.fmt.allocPrint(arena, "replaying macro \"{s}\" ({d} steps)\n", .{ mname, av.array.items.len });
        return runActionSteps(arena, app, av.array.items, win_arg, false, intro);
    }
    if (eql(u8, name, "close_app_window")) {
        const win_id: u32 = @intCast(argInt(args, "window") orelse
            return appErr(arena, "close_app_window requires 'window'"));
        app.closeWindow(win_id) catch return appErr(arena, "close failed (bad window?)");
        return toolResult(arena, "close requested (the app decides)", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "close_app")) {
        // Idempotent: closing an already-dead app is a no-op success.
        const id = appIdOf(app);
        const was_exited = app.exited;
        const status = app.exit_status;
        _ = mcp.app_state.apps.swapRemove(id);
        // Wait for the daemon to ACK the kill: it tears the session
        // down by signalling the child's whole process group, so an
        // acknowledged kill means no descendant survived. Firing the
        // frame and closing the socket (the old behaviour) reported
        // "killed" whether or not anything died.
        const outcome = app.killAndWait(5_000);
        app.deinit();
        const msg: []const u8 = switch (outcome) {
            .already_exited => if (was_exited)
                try std.fmt.allocPrint(arena, "app session closed (the app had already exited with status {d})", .{status})
            else
                "app session closed (it was already gone on the daemon)",
            .acknowledged => "app session killed — the daemon signalled the child's whole process group and reaped it; no descendant processes remain",
            .unconfirmed => "app session closed locally, but the daemon did not acknowledge the kill within 5s — the process MAY still be running; check with list_apps or on the daemon host",
        };
        return toolResult(arena, msg, outcome == .unconfirmed) orelse error.OutOfMemory;
    }
    return appErr(arena, "unknown tool");
}

// ── observation tools (app_watch / app_hover_map / app_backtrace) ──

/// app_watch: sample a window continuously and report WHEN it changed.
///
/// A screenshot answers "what is on screen now"; nothing answered "did
/// anything happen in the next N seconds". For an action with unknown
/// latency the two are not the same question, and a capture that lands
/// in a pre-roll — or after a short clip has already ended — reads
/// exactly like a dead control. This turns that guess into a
/// measurement.
fn appWatch(arena: std.mem.Allocator, app: *appdrive.App, args: std.json.Value) ![]const u8 {
    const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
    if (wid == 0) return appErr(arena, "no rendered window yet — nothing to watch");
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
    var res = app.watchChanges(wid, duration_ms, min_pct, region, max_events, thumbs) catch |err|
        return appErr(arena, switch (err) {
            appdrive.Error.NoSuchWindow => "no such window (or it has not painted a frame yet)",
            else => "watch failed",
        });
    defer res.deinit(mcp.app_state.allocator);

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("watched window {d} for {d}ms{s} — it committed {d} frame(s) (frame {d} -> {d})\n", .{
        wid,
        res.elapsed_ms,
        if (region != null) ", change gauged inside the given region" else "",
        res.frames,
        res.frame_first,
        res.frame_last,
    });
    if (res.events.len == 0) {
        if (res.frames == 0) {
            try w.print(
                "NO frames at all: the window did not paint once in {d}ms. For an idle event-driven app that is normal (nothing asked it to redraw); for one that should be animating, or one you just sent input to, it is the signature of a hang — app_backtrace shows where the process is.\n",
                .{res.elapsed_ms},
            );
        } else {
            try w.print(
                "NO change of {d:.1}% or more happened at any point. The window IS painting, so this is a real observation and not a missed sample: the content simply never changed materially. Lower min_change_pct to catch smaller updates.\n",
                .{min_pct},
            );
        }
    } else {
        try w.print("timeline (each entry is measured against the previous one, threshold {d:.1}%):\n", .{min_pct});
        for (res.events, 0..) |e, i| {
            try w.print("  [{d}] t={d}ms  changed {d:.1}% of pixels  (frame {d})\n", .{ i + 1, e.at_ms, e.pct, e.frame });
        }
        if (res.truncated)
            try w.print("(timeline capped at {d} entries — more changes occurred; raise max_events or raise min_change_pct)\n", .{max_events});
        if (res.events.len == 1) {
            try w.print(
                "ONE change, at t={d}ms. A screenshot taken before that moment would have shown nothing happening — that delay is the action's real latency.\n",
                .{res.events[0].at_ms},
            );
        }
    }
    if (res.exited) try w.writeAll("the app EXITED during the watch (details below)\n");
    try w.print("pass min_frame:{d} to screenshot_app for a capture provably newer than the start of this watch\n", .{frame_at_start});
    try w.writeAll(try appSummary(arena, app));

    // Thumbnails: encoded AFTER the watch, from stashed pixels, so PNG
    // encoding never perturbs the sampling it is describing.
    var pngs: std.ArrayList([]const u8) = .empty;
    defer {
        for (pngs.items) |p| mcp.app_state.allocator.free(p);
        pngs.deinit(arena);
    }
    for (res.events) |e| {
        if (e.px.len == 0) continue;
        const shot = app.encodePixelsPng(e.px, e.w, e.h, e.format, e.frame, max_px, region, 1, &.{}) catch continue;
        try pngs.append(arena, shot.png);
    }
    if (pngs.items.len == 0)
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    try w.print("({d} thumbnail(s) below, in timeline order)", .{pngs.items.len});
    return imagesResult(arena, aw.written(), pngs.items) orelse error.OutOfMemory;
}

/// app_hover_map: sweep the pointer over a grid and report which cells
/// made the window repaint.
///
/// For an app with no accessibility tree there is otherwise no way to
/// find what is clickable except guessing coordinates, and a piece of
/// background art that happens to be a door is unguessable. This needs
/// no cooperation from the target: it is the same pixel diff every
/// other verdict here is built on, applied to hover.
fn hoverMap(arena: std.mem.Allocator, app: *appdrive.App, args: std.json.Value) ![]const u8 {
    const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
    if (wid == 0) return appErr(arena, "no rendered window yet");
    const dims = app.windowSize(wid) orelse return appErr(arena, "no such window (or it has not painted yet)");
    const region: appdrive.App.Region = regionFrom(args) orelse .{
        .x = 0,
        .y = 0,
        .w = @intCast(@max(dims.w, 0)),
        .h = @intCast(@max(dims.h, 0)),
    };
    if (region.w == 0 or region.h == 0) return appErr(arena, "empty region");
    const cols: usize = @intCast(std.math.clamp(argInt(args, "cols") orelse 12, 2, 40));
    const rows: usize = @intCast(std.math.clamp(argInt(args, "rows") orelse 9, 2, 40));
    const probes = cols * rows;
    const MAX_PROBES = 600;
    if (probes > MAX_PROBES)
        return appErr(arena, "cols*rows exceeds 600 probes — narrow the region or use a coarser grid, then re-sweep the interesting part");
    const settle_ms: i64 = std.math.clamp(argInt(args, "settle_ms") orelse 120, 20, 2_000);
    const min_pct = argFloat(args, "min_change_pct") orelse 0.05;
    // Every probe can burn its full settle, so the worst case is the
    // budget. Refuse with the arithmetic rather than start a sweep the
    // call watchdog will cut off half-finished.
    const worst_ms = @as(i64, @intCast(probes)) * settle_ms;
    if (worst_ms > mcp.WAIT_CAP_MS) {
        return appErr(arena, try std.fmt.allocPrint(
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
        var ref = app.frameRef(wid, true) orelse return appErr(arena, "no such window");
        defer ref.deinit(mcp.app_state.allocator);
        if (app.waitChangeSince(wid, &ref, settle_ms, min_pct, null)) self_changes += 1;
    }
    if (self_changes >= 2) {
        return appErr(arena, try std.fmt.allocPrint(
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
    const t0 = monoMs();
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
            defer ref.deinit(mcp.app_state.allocator);
            _ = app.moveMouse(wid, px, py) catch continue;
            if (app.waitChangeSince(wid, &ref, settle_ms, min_pct, null)) {
                map[r * cols + col] = app.peekChangeVs(wid, &ref, null);
                hits += 1;
            }
        }
    }
    if (restore) |p| _ = app.moveMouse(p.win, p.x, p.y) catch {};

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("hover map of window {d} over ({d},{d}) {d}x{d}: {d}x{d} grid, {d} probes in {d}ms ({d}ms settle, threshold {d:.2}%)\n", .{
        wid, region.x, region.y, region.w, region.h, cols, rows, probes, monoMs() - t0, settle_ms, min_pct,
    });
    if (stopped) try w.writeAll("the sweep STOPPED EARLY (the app exited or the window vanished) — the map below is partial\n");
    r = 0;
    while (r < rows) : (r += 1) {
        try w.writeAll("  ");
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            try w.writeByte(if (map[r * cols + col] > 0) '#' else '.');
        }
        try w.writeByte('\n');
    }
    if (hits == 0) {
        try w.print(
            "NO cell produced a repaint. This app may simply not draw hover feedback — that is common for framebuffer games, and it does NOT mean nothing there is clickable. Lower min_change_pct, or fall back to app_read_text / app_find_image.\n",
            .{},
        );
    } else {
        try w.print("{d} cell(s) responded to hover, click centres in surface coordinates:\n", .{hits});
        r = 0;
        while (r < rows) : (r += 1) {
            var col: usize = 0;
            while (col < cols) : (col += 1) {
                const pct = map[r * cols + col];
                if (pct <= 0) continue;
                const px = @as(f64, @floatFromInt(region.x)) + (@as(f64, @floatFromInt(col)) + 0.5) * cell_w;
                const py = @as(f64, @floatFromInt(region.y)) + (@as(f64, @floatFromInt(r)) + 0.5) * cell_h;
                try w.print("  ({d},{d})  {d:.2}%\n", .{ @as(i64, @intFromFloat(px)), @as(i64, @intFromFloat(py)), pct });
            }
        }
        try w.writeAll("A cell is one grid step wide, so these are approximate centres — re-sweep a promising area with a region + finer grid to localise it.\n");
    }
    try w.writeAll(try appSummary(arena, app));
    return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
}

/// app_backtrace: what a crash gets for free and a hang never did.
///
/// A crashing app dumps a sanitizer/gdb report into the log ring. A
/// HUNG one produces nothing, and `gdb -p` from the calling session
/// fails: Linux Yama only lets an ancestor trace, and the app's
/// ancestor is the daemon. So the daemon takes the backtrace.
fn appBacktrace(arena: std.mem.Allocator, app: *appdrive.App, args: std.json.Value) ![]const u8 {
    const debugger_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 20_000, 2_000, 100_000);
    // Outlast the daemon-side deadline: the reply to a timed-out
    // debugger is still a reply, and giving up first would throw away
    // the partial dump it carries.
    const raw = app.debugBacktrace(debugger_ms, debugger_ms + 10_000) catch |err|
        return appErr(arena, switch (err) {
            appdrive.Error.Timeout => "the daemon did not answer the debug request in time",
            else => "debug request failed (app gone?)",
        });
    defer mcp.app_state.allocator.free(raw);

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
        return appErr(arena, try std.fmt.allocPrint(arena, "no backtrace: {s}", .{rep.@"error"}));

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    if (rep.timed_out) {
        try w.print("PARTIAL: {s}\n", .{rep.@"error"});
    } else {
        try w.print("{s} attached to pid {d} on the daemon host and reported in {d}ms.\n", .{ rep.tool, rep.pid, rep.took_ms });
    }
    try w.writeAll("The app was STOPPED while this was taken and has been resumed; wall-clock timings across this call are not meaningful.\n");
    if (rep.truncated) try w.writeAll("(output truncated at the daemon's cap — the head is retained)\n");
    try w.writeAll("---\n");
    try w.writeAll(rep.text);
    if (!std.mem.endsWith(u8, rep.text, "\n")) try w.writeByte('\n');
    try w.writeAll("---\n");
    try w.writeAll(try appSummary(arena, app));
    return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
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
