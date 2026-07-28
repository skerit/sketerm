//! MCP browser automation (CDP) tools — split out of mcp.zig. Shares
//! the server's module state (mcp.browser_state, app registry) through
//! mcp.zig; the dispatcher routes browser_* here.

const std = @import("std");
const c = @import("../c.zig").c;
const appdrive = @import("appdrive.zig");
const cdp = @import("cdp.zig");
const mcp = @import("mcp.zig");
const monoMs = mcp.monoMs;
const BrowserSession = mcp.BrowserSession;
const appSummary = mcp.appSummary;
const appErr = mcp.appErr;
const argBool = mcp.argBool;
const argFloat = mcp.argFloat;
const appFromArgs = mcp.appFromArgs;
const imageResult = mcp.imageResult;
const screenshotCaption = mcp.screenshotCaption;
const toolResult = mcp.toolResult;
const mcpassets = mcp.mcpassets;
const argInt = mcp.argInt;
const findBrowserBinary = mcp.findBrowserBinary;
const appIdOf = mcp.appIdOf;
const argStr = mcp.argStr;

// ── Browser automation (CDP) ─────────────────────────────────────
//
// browser_open launches a Chromium-family binary headlessly under the
// Wayland session with --remote-debugging-port=0, discovers the real
// DevTools port from the app log, and attaches a WebSocket CDP client.
// The browser is a NORMAL app (screenshot_app/app_click/app_key all
// work); the browser_* tools add DOM-level reading, clicking, filling
// and waiting — trusted input goes through CDP Input.dispatch*.

pub fn sleepMsLocal(ms: u32) void {
    var ts: c.struct_timespec = .{ .tv_sec = ms / 1000, .tv_nsec = @as(c_long, ms % 1000) * 1_000_000 };
    _ = c.nanosleep(&ts, null);
}

pub fn mkdirs(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            @memcpy(buf[0..i], path[0..i]);
            buf[i] = 0;
            _ = c.mkdir(buf[0..i :0].ptr, 0o700);
        }
    }
}

/// Poll the app's log ring for Chromium's "DevTools listening" line.
pub fn discoverDevtoolsPort(app: *appdrive.App, timeout_ms: i64) ?u16 {
    const deadline = monoMs() + timeout_ms;
    while (monoMs() < deadline) {
        app.drain();
        if (app.logGet("{\"tail\":300,\"from_id\":0,\"id\":0,\"max_chars\":300}", 3_000)) |reply| {
            defer mcp.app_state.allocator.free(reply.json);
            if (cdp.parseDevtoolsPort(reply.json)) |port| return port;
        } else |_| {}
        if (app.exited) return null;
        _ = app.pumpOnce(250);
    }
    return null;
}

/// A JSON string literal (valid JS literal) for embedding in scripts.
pub fn jsStr(arena: std.mem.Allocator, s: ?[]const u8) ![]const u8 {
    const v = s orelse return "null";
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(v, .{}, &aw.writer);
    return aw.written();
}

pub const BrowserGet = union(enum) { bs: *BrowserSession, err: []const u8 };

pub fn browserEnsure(arena: std.mem.Allocator, app: *appdrive.App) !BrowserGet {
    app.drain();
    if (app.exited) {
        const summary = try appSummary(arena, app);
        return .{ .err = try std.fmt.allocPrint(arena, "the browser has exited\n{s}", .{summary}) };
    }
    const bs = mcp.browser_state.sessions.get(appIdOf(app)) orelse
        return .{ .err = "this app has no CDP session — open pages with browser_open (or drive it with the app_* tools)" };
    if (!bs.client.connected()) {
        bs.client.attach(5_000) catch
            return .{ .err = "cannot reattach the DevTools socket (browser hung or DevTools disabled?) — screenshots and app_* input still work" };
    }
    return .{ .bs = bs };
}

pub const BEvalOut = union(enum) { val: ?[]const u8, err: []const u8 };

/// Evaluate JS with one transparent reconnect (navigation can replace
/// the page target, killing the WebSocket).
pub fn bEval(arena: std.mem.Allocator, bs: *BrowserSession, expr: []const u8, timeout_ms: i64) BEvalOut {
    var attempt: u32 = 0;
    while (true) {
        const r = bs.client.eval(arena, expr, timeout_ms) catch |err| {
            if (attempt == 0 and (err == cdp.Error.Closed or err == cdp.Error.Protocol)) {
                attempt = 1;
                bs.client.attach(5_000) catch
                    return .{ .err = "the DevTools connection dropped and could not be reattached" };
                continue;
            }
            return .{ .err = switch (err) {
                cdp.Error.Timeout => "the page did not answer in time (JS blocked / page hung?)",
                cdp.Error.Closed => "the DevTools connection closed",
                else => "DevTools protocol error",
            } };
        };
        if (r.exception) |ex|
            return .{ .err = std.fmt.allocPrint(arena, "JavaScript exception: {s}", .{ex}) catch "JavaScript exception" };
        return .{ .val = r.value_json };
    }
}

pub const PageInfo = struct { url: []const u8, title: []const u8, ready: []const u8 };

pub fn browserPageInfo(arena: std.mem.Allocator, bs: *BrowserSession, timeout_ms: i64) ?PageInfo {
    const out = bEval(arena, bs, "location.href + '\\u0001' + document.title + '\\u0001' + document.readyState", timeout_ms);
    const vj = (switch (out) {
        .val => |v| v,
        .err => null,
    }) orelse return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch return null;
    if (parsed != .string) return null;
    var it = std.mem.splitScalar(u8, parsed.string, 1);
    const url = it.next() orelse return null;
    const title = it.next() orelse "";
    const ready = it.next() orelse "";
    return .{ .url = url, .title = title, .ready = ready };
}

/// Shared JS helpers injected ahead of every element script. deepQuery
/// pierces OPEN shadow roots (custom-element UIs like pl-input);
/// labelText computes an element's accessible label incl. its shadow
/// host's text. Plain constant (inserted via {s}) so its braces never
/// meet std.fmt.
pub const JS_HELPERS: []const u8 =
    \\let badSelector = false;
    \\const deepQuery = s => { const out = []; const walk = root => { let m = []; try { m = root.querySelectorAll(s); } catch (e) { badSelector = true; return; } out.push(...m); for (const el of root.querySelectorAll('*')) if (el.shadowRoot) walk(el.shadowRoot); }; walk(document); return out; };
    \\const labelText = e => { let t = ''; try { if (e.labels) for (const l of e.labels) t += ' ' + (l.innerText || ''); const al = e.getAttribute('aria-label'); if (al) t += ' ' + al; const alb = e.getAttribute('aria-labelledby'); if (alb) for (const id of alb.split(/\s+/)) { const rn = e.getRootNode(); const lr = (rn.getElementById ? rn.getElementById(id) : null) || document.getElementById(id); if (lr) t += ' ' + (lr.innerText || ''); } const host = e.getRootNode().host; if (host) { t += ' ' + (host.innerText || '').slice(0, 200); const hal = host.getAttribute('aria-label'); if (hal) t += ' ' + hal; } if (!t.trim() && e.shadowRoot) { const sl = e.shadowRoot.querySelector('label'); if (sl) t = sl.innerText || ''; } if (!t.trim() && host) { const rn2 = e.getRootNode(); const sl2 = rn2.querySelector ? rn2.querySelector('label') : null; if (sl2) t = sl2.innerText || ''; } } catch (err) {} return t; };
    \\const vis = e => { const r = e.getBoundingClientRect(); if (r.width <= 0 || r.height <= 0) return false; const s = getComputedStyle(e); return s.visibility !== 'hidden' && s.display !== 'none'; };
    \\const activeDeep = () => { let a = document.activeElement; while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement; return a; };
;

/// The shared element finder: selector and/or visible-text filter over
/// interactive elements (shadow-root piercing); tightest text match
/// first. Custom-element hosts wrapping a native control are included
/// when no selector is given.
pub fn elementFinderJs(arena: std.mem.Allocator, selector: ?[]const u8, text: ?[]const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\const sel = {s}; const txt = {s};
        \\{s}
        \\let els;
        \\if (sel) els = deepQuery(sel);
        \\else {{ els = deepQuery("a,button,input,select,textarea,summary,[role='button'],[role='link'],[role='tab'],[role='menuitem'],[role='option'],[role='checkbox'],[role='radio'],[role='switch'],[role='combobox'],[onclick],label"); for (const h of deepQuery('*')) if (h.tagName.includes('-') && h.shadowRoot && h.shadowRoot.querySelector('input,select,textarea,button')) els.push(h); els = [...new Set(els)]; }}
        \\els = els.filter(vis);
        \\if (txt) {{ const q = txt.toLowerCase(); els = els.filter(e => ((e.innerText || '') + ' ' + (e.value || '') + ' ' + labelText(e) + ' ' + (e.getAttribute('placeholder') || '') + ' ' + (e.getAttribute('title') || '')).toLowerCase().includes(q)); els.sort((a, b) => ((a.innerText || '').length) - ((b.innerText || '').length)); }}
    , .{ try jsStr(arena, selector), try jsStr(arena, text), JS_HELPERS });
}

pub fn browserErrOr(arena: std.mem.Allocator, out: BEvalOut) !?[]const u8 {
    switch (out) {
        .err => |e| return @as(?[]const u8, try appErr(arena, e)),
        .val => return null,
    }
}

pub fn browserTool(arena: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    if (!mcp.app_state.ready)
        return appErr(arena, "browser tools unavailable (server not fully started)");

    if (eql(u8, name, "browser_open")) {
        if (argStr(args, "host") != null)
            return appErr(arena, "browser_open is local-only (the DevTools port lives on the daemon host's loopback); for a remote browser, launch_app it and drive it with app_* tools");
        const bin = argStr(args, "browser_path") orelse (findBrowserBinary(arena) orelse
            return appErr(arena, "no Chromium-family browser found on PATH (install chromium) — pass 'browser_path' to use a specific binary"));
        const url = argStr(args, "url") orelse "about:blank";
        const wait_ms: i64 = argInt(args, "wait_ms") orelse 25_000;
        const width: i64 = std.math.clamp(argInt(args, "width") orelse 1280, 320, 3840);
        const height: i64 = std.math.clamp(argInt(args, "height") orelse 900, 240, 2160);

        // Profile: named = persistent under the state dir (cookies and
        // logins survive); default = throwaway per launch.
        var profile_dir: []const u8 = undefined;
        if (argStr(args, "profile")) |p| {
            if (!mcpassets.validName(p)) return appErr(arena, "invalid profile name (letters, digits, . _ - only)");
            const state_base = if (c.getenv("XDG_STATE_HOME")) |sh|
                try std.fmt.allocPrint(arena, "{s}", .{std.mem.span(@as([*:0]const u8, @ptrCast(sh)))})
            else if (c.getenv("HOME")) |home|
                try std.fmt.allocPrint(arena, "{s}/.local/state", .{std.mem.span(@as([*:0]const u8, @ptrCast(home)))})
            else
                return appErr(arena, "no HOME to place the profile in");
            profile_dir = try std.fmt.allocPrint(arena, "{s}/sketerm/browser-profiles/{s}", .{ state_base, p });
        } else {
            const rt = if (c.getenv("XDG_RUNTIME_DIR")) |r| std.mem.span(@as([*:0]const u8, @ptrCast(r))) else "/tmp";
            profile_dir = try std.fmt.allocPrint(arena, "{s}/sketerm/browser-ephemeral-{d}-{d}", .{ rt, c.getpid(), mcp.app_state.next_id });
        }
        mkdirs(profile_dir);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.appendSlice(arena, &.{
            bin,
            "--ozone-platform=wayland",
            "--remote-debugging-port=0",
            try std.fmt.allocPrint(arena, "--user-data-dir={s}", .{profile_dir}),
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-session-crashed-bubble",
            "--hide-crash-restore-bubble",
            "--force-renderer-accessibility",
            try std.fmt.allocPrint(arena, "--window-size={d},{d}", .{ width, height }),
            url,
        });
        const app = appdrive.App.launch(mcp.app_state.allocator, argv.items, .{
            .cols = 100,
            .rows = 30,
            .local_sock = mcp.app_state.mux_sock,
        }) catch {
            const why = appdrive.lastLaunchErr();
            return appErr(arena, if (why.len > 0)
                try std.fmt.allocPrint(arena, "browser spawn failed — {s}", .{why})
            else
                "browser spawn failed (mux daemon unreachable?)");
        };
        const id = mcp.app_state.next_id;
        mcp.app_state.next_id += 1;
        mcp.app_state.apps.put(mcp.app_state.allocator, id, app) catch {
            app.deinit();
            return error.OutOfMemory;
        };
        const started = monoMs();
        _ = app.waitFirstWindow(wait_ms);
        const port = discoverDevtoolsPort(app, @max(0, wait_ms - (monoMs() - started))) orelse {
            const summary = try appSummary(arena, app);
            return toolResult(arena, try std.fmt.allocPrint(arena, "the browser started but never announced a DevTools port — CDP tools unavailable, app_* tools still work (app {d})\n{s}", .{ id, summary }), true) orelse error.OutOfMemory;
        };
        const bs = mcp.browser_state.allocator.create(BrowserSession) catch return error.OutOfMemory;
        bs.* = .{ .client = cdp.Client.init(mcp.browser_state.allocator, port) };
        mcp.browser_state.sessions.put(mcp.browser_state.allocator, id, bs) catch {
            bs.client.deinit();
            mcp.browser_state.allocator.destroy(bs);
            return error.OutOfMemory;
        };
        // The HTTP endpoint answers slightly before the first page
        // target exists; retry the attach briefly.
        var attach_deadline = monoMs() + 10_000;
        while (true) {
            bs.client.attach(4_000) catch {
                if (monoMs() < attach_deadline) {
                    sleepMsLocal(300);
                    continue;
                }
                const summary = try appSummary(arena, app);
                return toolResult(arena, try std.fmt.allocPrint(arena, "browser is up (app {d}, DevTools port {d}) but no page target became attachable\n{s}", .{ id, port, summary }), true) orelse error.OutOfMemory;
            };
            break;
        }
        // Capture network traffic from the first request on: powers
        // browser_network and browser_wait network_idle.
        bs.client.enableNetwork(5_000) catch {};
        // Best-effort: let the initial page settle.
        attach_deadline = monoMs() + 8_000;
        while (monoMs() < attach_deadline) {
            if (browserPageInfo(arena, bs, 3_000)) |info| {
                if (!eql(u8, info.ready, "loading")) break;
            }
            sleepMsLocal(300);
        }
        _ = app.waitIdle(300, 3_000);
        var summary = try appSummary(arena, app);
        summary = try std.fmt.allocPrint(arena, "browser open: app {d}, DevTools port {d} — read with browser_read/browser_elements, interact with browser_click/browser_fill, verify with browser_info; screenshots via get_app_state\n{s}", .{ id, port, summary });
        var shot_win: u32 = 0;
        for (app.windows.items) |win| {
            if (!win.popup and win.frames > 0) {
                shot_win = win.id;
                break;
            }
        }
        if (shot_win != 0) {
            if (app.screenshotPng(shot_win, 1568, null, 1)) |shot| {
                defer mcp.app_state.allocator.free(shot.png);
                const caption = try screenshotCaption(arena, app, shot_win, shot, summary);
                if (imageResult(arena, caption, shot.png)) |r| return r;
            } else |_| {}
        }
        return toolResult(arena, summary, false) orelse error.OutOfMemory;
    }

    const app = appFromArgs(args) orelse
        return appErr(arena, "unknown app (pass 'app' from browser_open; use list_apps)");
    const bs = switch (try browserEnsure(arena, app)) {
        .bs => |b| b,
        .err => |e| return toolResult(arena, e, true) orelse error.OutOfMemory,
    };

    if (eql(u8, name, "browser_info")) {
        const out = bEval(arena, bs,
            \\({url: location.href, title: document.title, ready: document.readyState, scroll_y: Math.round(scrollY), doc_height: document.documentElement.scrollHeight, viewport: [innerWidth, innerHeight]})
        , argInt(args, "timeout_ms") orelse 8_000);
        if (try browserErrOr(arena, out)) |e| return e;
        return toolResult(arena, out.val orelse "null", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_navigate")) {
        const url_arg = argStr(args, "url") orelse return appErr(arena, "browser_navigate requires 'url' (or \"back\"/\"forward\"/\"reload\")");
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 20_000;
        if (eql(u8, url_arg, "back") or eql(u8, url_arg, "forward")) {
            const js = if (eql(u8, url_arg, "back")) "history.back(); true" else "history.forward(); true";
            const out = bEval(arena, bs, js, 5_000);
            if (try browserErrOr(arena, out)) |e| return e;
        } else if (eql(u8, url_arg, "reload")) {
            _ = bs.client.call(arena, "Page.reload", "{}", 5_000) catch {};
        } else {
            const url = if (std.mem.indexOf(u8, url_arg, "://") != null)
                url_arg
            else
                try std.fmt.allocPrint(arena, "https://{s}", .{url_arg});
            const params = try std.fmt.allocPrint(arena, "{{\"url\":{s}}}", .{try jsStr(arena, url)});
            const resp = bs.client.call(arena, "Page.navigate", params, 10_000) catch |err| return appErr(arena, switch (err) {
                cdp.Error.Timeout => "navigation request timed out",
                else => "navigation failed (DevTools connection lost?)",
            });
            if (std.mem.indexOf(u8, resp, "\"errorText\"") != null)
                return appErr(arena, try std.fmt.allocPrint(arena, "navigation refused: {s}", .{resp}));
        }
        // Wait for the load to settle (target may be replaced —
        // browserPageInfo reattaches transparently via bEval).
        const deadline = monoMs() + timeout_ms;
        var last: ?PageInfo = null;
        while (monoMs() < deadline) {
            sleepMsLocal(300);
            if (browserPageInfo(arena, bs, 3_000)) |info| {
                last = info;
                if (eql(u8, info.ready, "complete")) break;
            }
        }
        const info = last orelse return appErr(arena, "navigation started but the page never became readable before the timeout");
        const msg = try std.fmt.allocPrint(arena, "{{\"url\":{s},\"title\":{s},\"ready\":\"{s}\"}}", .{ try jsStr(arena, info.url), try jsStr(arena, info.title), info.ready });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_eval")) {
        const js = argStr(args, "js") orelse return appErr(arena, "browser_eval requires 'js'");
        const out = bEval(arena, bs, js, argInt(args, "timeout_ms") orelse 10_000);
        if (try browserErrOr(arena, out)) |e| return e;
        const v = out.val orelse "undefined";
        const capped = if (v.len > 100_000) try std.fmt.allocPrint(arena, "{s}\n[truncated: {d} of {d} chars]", .{ v[0..100_000], @as(usize, 100_000), v.len }) else v;
        return toolResult(arena, capped, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_read")) {
        const format = argStr(args, "format") orelse "text";
        const selector = argStr(args, "selector");
        const max_chars: usize = @intCast(std.math.clamp(argInt(args, "max_chars") orelse 20_000, 200, 200_000));
        var js: []const u8 = undefined;
        if (eql(u8, format, "text")) {
            js = try std.fmt.allocPrint(arena,
                \\(() => {{ const sel = {s}; const el = sel ? document.querySelector(sel) : document.body; if (!el) return null; return el.innerText; }})()
            , .{try jsStr(arena, selector)});
        } else if (eql(u8, format, "html")) {
            js = try std.fmt.allocPrint(arena,
                \\(() => {{ const sel = {s}; const el = sel ? document.querySelector(sel) : document.documentElement; if (!el) return null; return el.outerHTML; }})()
            , .{try jsStr(arena, selector)});
        } else if (eql(u8, format, "links")) {
            js = try std.fmt.allocPrint(arena,
                \\(() => {{ const sel = {s}; const root = sel ? document.querySelector(sel) : document; if (!root) return null; return JSON.stringify(Array.from(root.querySelectorAll('a[href]')).slice(0, 300).map(a => ({{text: (a.innerText || '').trim().slice(0, 120), href: a.href}}))); }})()
            , .{try jsStr(arena, selector)});
        } else {
            return appErr(arena, "'format' must be text, html or links");
        }
        const out = bEval(arena, bs, js, argInt(args, "timeout_ms") orelse 10_000);
        if (try browserErrOr(arena, out)) |e| return e;
        const vj = out.val orelse return appErr(arena, "selector matched nothing");
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch
            return toolResult(arena, vj, false) orelse error.OutOfMemory;
        if (parsed == .null) return appErr(arena, "selector matched nothing");
        const content = if (parsed == .string) parsed.string else vj;
        const info = browserPageInfo(arena, bs, 3_000);
        const header = if (info) |i|
            try std.fmt.allocPrint(arena, "page: {s}{s}{s}\n---\n", .{ i.url, if (i.title.len > 0) " — " else "", i.title })
        else
            "";
        const capped = if (content.len > max_chars)
            try std.fmt.allocPrint(arena, "{s}{s}\n[truncated: showing {d} of {d} chars — narrow with 'selector' or raise 'max_chars']", .{ header, content[0..max_chars], max_chars, content.len })
        else
            try std.fmt.allocPrint(arena, "{s}{s}", .{ header, content });
        return toolResult(arena, capped, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_elements")) {
        const finder = try elementFinderJs(arena, argStr(args, "selector"), argStr(args, "text"));
        const js = try std.fmt.allocPrint(arena,
            \\(() => {{ {s}
            \\if (badSelector) return 'bad selector';
            \\const implicit = el => ({{A: 'link', BUTTON: 'button', SELECT: 'combobox', TEXTAREA: 'textbox', LABEL: 'label', SUMMARY: 'button', INPUT: el.type === 'checkbox' ? 'checkbox' : el.type === 'radio' ? 'radio' : el.type === 'range' ? 'slider' : 'textbox'}})[el.tagName];
            \\return JSON.stringify(els.slice(0, 100).map((e, i) => {{
            \\const r = e.getBoundingClientRect();
            \\const inner = e.shadowRoot ? e.shadowRoot.querySelector('input,select,textarea') : null;
            \\const val = e.value !== undefined ? e.value : (inner ? inner.value : undefined);
            \\const secret = e.type === 'password' || (inner && inner.type === 'password');
            \\const chk = e.checked !== undefined ? e.checked : (inner && inner.checked !== undefined ? inner.checked : (e.getAttribute('aria-checked') ? e.getAttribute('aria-checked') === 'true' : undefined));
            \\const oel = e.tagName === 'SELECT' ? e : (inner && inner.tagName === 'SELECT' ? inner : null);
            \\return {{n: i, tag: e.tagName.toLowerCase(),
            \\role: e.getAttribute('role') || implicit(e) || (e.tagName.includes('-') ? 'custom' : undefined),
            \\text: ((e.innerText || e.value || e.getAttribute('aria-label') || e.getAttribute('placeholder') || '').trim()).slice(0, 100),
            \\label: labelText(e).trim().slice(0, 80) || undefined,
            \\x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), w: Math.round(r.width), h: Math.round(r.height),
            \\href: e.href || undefined, type: e.type || (inner ? inner.type : undefined) || undefined,
            \\name: e.name || e.getAttribute('name') || (inner ? inner.name : undefined) || undefined,
            \\value: secret ? (val && String(val).length ? '(secret: ' + String(val).length + ' chars)' : undefined) : (val !== undefined && val !== null && String(val).length ? String(val).slice(0, 60) : undefined),
            \\checked: chk,
            \\disabled: e.disabled || (inner && inner.disabled) || e.getAttribute('aria-disabled') === 'true' || undefined,
            \\expanded: e.getAttribute('aria-expanded') ? e.getAttribute('aria-expanded') === 'true' : undefined,
            \\options: oel ? Array.from(oel.options).slice(0, 20).map(o => o.text.slice(0, 40)) : undefined,
            \\shadow: e.shadowRoot ? true : undefined}}; }})); }})()
        , .{finder});
        const out = bEval(arena, bs, js, argInt(args, "timeout_ms") orelse 10_000);
        if (try browserErrOr(arena, out)) |e| return e;
        const vj = out.val orelse "[]";
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch
            return toolResult(arena, vj, false) orelse error.OutOfMemory;
        if (parsed == .string and eql(u8, parsed.string, "bad selector"))
            return appErr(arena, "invalid CSS selector");
        const listing = if (parsed == .string) parsed.string else vj;
        return toolResult(arena, try std.fmt.allocPrint(arena, "interactive elements (centers are viewport CSS px, valid for browser_click x/y):\n{s}", .{listing}), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_click")) {
        const selector = argStr(args, "selector");
        const text = argStr(args, "text");
        var cx: f64 = 0;
        var cy: f64 = 0;
        var desc: []const u8 = "";
        if (argFloat(args, "x")) |xv| {
            cx = xv;
            cy = argFloat(args, "y") orelse return appErr(arena, "'x' needs 'y'");
            desc = try std.fmt.allocPrint(arena, "viewport point ({d:.0},{d:.0})", .{ cx, cy });
        } else {
            if (selector == null and text == null)
                return appErr(arena, "browser_click needs 'selector' and/or 'text' (or explicit x/y viewport coords)");
            const nth: i64 = argInt(args, "nth") orelse 0;
            const finder = try elementFinderJs(arena, selector, text);
            const js = try std.fmt.allocPrint(arena,
                \\(() => {{ {s}
                \\if (badSelector) return {{bad: true}};
                \\const el = els[{d}]; if (!el) return {{found: els.length}};
                \\el.scrollIntoView({{block: 'center', inline: 'center'}});
                \\const r = el.getBoundingClientRect();
                \\return {{found: els.length, x: r.x + r.width / 2, y: r.y + r.height / 2, tag: el.tagName.toLowerCase(), text: ((el.innerText || el.value || '').trim()).slice(0, 80)}}; }})()
            , .{ finder, nth });
            const out = bEval(arena, bs, js, argInt(args, "timeout_ms") orelse 10_000);
            if (try browserErrOr(arena, out)) |e| return e;
            const vj = out.val orelse return appErr(arena, "element lookup returned nothing");
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch
                return appErr(arena, "element lookup returned malformed data");
            if (parsed != .object) return appErr(arena, "element lookup returned malformed data");
            if (parsed.object.get("bad") != null) return appErr(arena, "invalid CSS selector");
            const found: i64 = if (parsed.object.get("found")) |f| (if (f == .integer) f.integer else 0) else 0;
            const xo = parsed.object.get("x") orelse
                return appErr(arena, try std.fmt.allocPrint(arena, "no matching element (matched {d}, wanted index {d}) — browser_elements lists what IS clickable", .{ found, nth }));
            cx = switch (xo) {
                .float => xo.float,
                .integer => @floatFromInt(xo.integer),
                else => 0,
            };
            const yo = parsed.object.get("y").?;
            cy = switch (yo) {
                .float => yo.float,
                .integer => @floatFromInt(yo.integer),
                else => 0,
            };
            const tag = if (parsed.object.get("tag")) |t| (if (t == .string) t.string else "?") else "?";
            const etext = if (parsed.object.get("text")) |t| (if (t == .string) t.string else "") else "";
            desc = try std.fmt.allocPrint(arena, "<{s}> \"{s}\" of {d} match(es) at ({d:.0},{d:.0})", .{ tag, etext, found, cx, cy });
        }
        const button = switch (argInt(args, "button") orelse 1) {
            2 => "middle",
            3 => "right",
            else => "left",
        };
        const clicks: u32 = @intCast(std.math.clamp(argInt(args, "clicks") orelse 1, 1, 3));
        const pre_url: ?[]const u8 = if (browserPageInfo(arena, bs, 3_000)) |pre| pre.url else null;
        bs.client.clickAt(arena, cx, cy, button, clicks, 8_000) catch |err| return appErr(arena, switch (err) {
            cdp.Error.Timeout => "the click was sent but the page did not acknowledge in time",
            else => "click dispatch failed (DevTools connection lost?)",
        });
        _ = app.waitIdle(200, 2_000);
        var msg = try std.fmt.allocPrint(arena, "clicked {s}", .{desc});
        // Navigation may follow a click: report where we landed, and
        // never let an intermediate state read as the final one —
        // ready != complete is flagged as navigation_pending, and
        // wait_navigation=true blocks (bounded) until the load ends.
        var info = browserPageInfo(arena, bs, 3_000);
        if (argBool(args, "wait_navigation")) {
            const nav_deadline = monoMs() + (argInt(args, "nav_timeout_ms") orelse 15_000);
            while (monoMs() < nav_deadline) {
                if (info) |i| {
                    if (eql(u8, i.ready, "complete")) break;
                }
                sleepMsLocal(300);
                info = browserPageInfo(arena, bs, 3_000);
            }
        }
        if (info) |i| {
            msg = try std.fmt.allocPrint(arena, "{s}\npage: {s}{s}{s} ({s})", .{ msg, i.url, if (i.title.len > 0) " — " else "", i.title, i.ready });
            if (pre_url != null and !eql(u8, pre_url.?, i.url))
                msg = try std.fmt.allocPrint(arena, "{s}\nnavigated: {s} -> {s}", .{ msg, pre_url.?, i.url });
            if (!eql(u8, i.ready, "complete"))
                msg = try std.fmt.allocPrint(arena, "{s}\nnavigation_pending: the document is still loading — this URL/title may be an intermediate state (browser_wait url_path/selector, or browser_click wait_navigation=true)", .{msg});
        } else {
            msg = try std.fmt.allocPrint(arena, "{s}\nnavigation_pending: the page is not answering yet (target being replaced?) — verify with browser_info/browser_wait", .{msg});
        }
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_fill")) {
        const selector = argStr(args, "selector");
        const label = argStr(args, "text_label");
        if (selector == null and label == null)
            return appErr(arena, "browser_fill needs 'selector' (CSS) or 'text_label' (placeholder/label/aria text)");
        const text = argStr(args, "value") orelse return appErr(arena, "browser_fill requires 'value' (the text to enter)");
        const finder = try elementFinderJs(arena, selector orelse "input,textarea,select,[contenteditable]", label);
        const nth: i64 = argInt(args, "nth") orelse 0;
        const js = try std.fmt.allocPrint(arena,
            \\(() => {{ {s}
            \\if (badSelector) return {{bad: true}};
            \\const q = 'input,textarea,select,[contenteditable]';
            \\const resolve = e => {{ if (e.matches(q)) return e; if (e.tagName === 'LABEL' && e.control) return e.control; let m = e.querySelector('input,textarea,select'); if (m) return m; if (e.shadowRoot) {{ m = e.shadowRoot.querySelector('input,textarea,select'); if (m) return m; }} const host = e.getRootNode().host; if (host && host.shadowRoot) {{ m = host.shadowRoot.querySelector('input,textarea,select'); if (m) return m; }} return null; }};
            \\els = els.filter(e => resolve(e));
            \\let el = els[{d}]; if (!el) return {{found: els.length}};
            \\el = resolve(el);
            \\el.scrollIntoView({{block: 'center'}});
            \\el.focus();
            \\if (el.tagName === 'SELECT') return {{tag: 'select'}};
            \\if (el.select) el.select();
            \\else if (el.isContentEditable) {{ const r = document.createRange(); r.selectNodeContents(el); const s = getSelection(); s.removeAllRanges(); s.addRange(r); }}
            \\return {{tag: el.tagName.toLowerCase(), name: el.name || el.id || ''}}; }})()
        , .{ finder, nth });
        const out = bEval(arena, bs, js, argInt(args, "timeout_ms") orelse 10_000);
        if (try browserErrOr(arena, out)) |e| return e;
        const vj = out.val orelse return appErr(arena, "field lookup returned nothing");
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch
            return appErr(arena, "field lookup returned malformed data");
        if (parsed != .object) return appErr(arena, "field lookup returned malformed data");
        if (parsed.object.get("bad") != null) return appErr(arena, "invalid CSS selector");
        const tag = if (parsed.object.get("tag")) |t| (if (t == .string) t.string else null) else null;
        if (tag == null) {
            const found: i64 = if (parsed.object.get("found")) |f| (if (f == .integer) f.integer else 0) else 0;
            return appErr(arena, try std.fmt.allocPrint(arena, "no matching editable field (matched {d}) — browser_elements shows the candidates", .{found}));
        }
        if (eql(u8, tag.?, "select")) {
            // Dropdowns: choose the option whose text or value matches.
            const sel_js = try std.fmt.allocPrint(arena,
                \\(() => {{ let el = document.activeElement; while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement; if (!el || el.tagName !== 'SELECT') return 'lost focus';
                \\const want = {s}.toLowerCase();
                \\const idx = Array.from(el.options).findIndex(o => o.value.toLowerCase() === want || o.text.toLowerCase().includes(want));
                \\if (idx < 0) return 'no option matching';
                \\el.selectedIndex = idx; el.dispatchEvent(new Event('input', {{bubbles: true}})); el.dispatchEvent(new Event('change', {{bubbles: true}}));
                \\return 'selected: ' + el.options[idx].text; }})()
            , .{try jsStr(arena, text)});
            const sout = bEval(arena, bs, sel_js, 8_000);
            if (try browserErrOr(arena, sout)) |e| return e;
            return toolResult(arena, sout.val orelse "null", false) orelse error.OutOfMemory;
        }
        if (text.len == 0) {
            const clear = bEval(arena, bs, "(() => { const el = document.activeElement; if (el.isContentEditable) el.textContent = ''; else el.value = ''; el.dispatchEvent(new Event('input', {bubbles: true})); return true; })()", 5_000);
            if (try browserErrOr(arena, clear)) |e| return e;
        } else {
            bs.client.insertText(arena, text, 8_000) catch |err| return appErr(arena, switch (err) {
                cdp.Error.Timeout => "typing was sent but not acknowledged in time",
                else => "typing failed (DevTools connection lost?)",
            });
        }
        const pre_url: ?[]const u8 = if (browserPageInfo(arena, bs, 3_000)) |pre| try arena.dupe(u8, pre.url) else null;
        if (argBool(args, "enter")) {
            _ = bs.client.call(arena, "Input.dispatchKeyEvent", "{\"type\":\"keyDown\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13,\"text\":\"\\r\"}", 5_000) catch {};
            _ = bs.client.call(arena, "Input.dispatchKeyEvent", "{\"type\":\"keyUp\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13}", 5_000) catch {};
            _ = app.waitIdle(200, 2_000);
        }
        // Read back what the field now holds (secrets excepted). A
        // submit can detach the field or replace the page — report
        // THAT instead of a misleading empty value.
        const verify_js = try std.fmt.allocPrint(arena,
            \\(() => {{ {s}
            \\const a = activeDeep();
            \\if (!a || a === document.body) return {{state: 'unfocused'}};
            \\if (!a.isConnected) return {{state: 'detached'}};
            \\if (a.type === 'password') return {{state: 'ok', secret_len: (a.value || '').length}};
            \\return {{state: 'ok', value: ((a.isContentEditable ? a.textContent : a.value) || '').slice(0, 120)}}; }})()
        , .{JS_HELPERS});
        const verify = bEval(arena, bs, verify_js, 5_000);
        var now_holds: []const u8 = "?";
        var nav_note: []const u8 = "";
        switch (verify) {
            .val => |v| blk: {
                const pv = std.json.parseFromSliceLeaky(std.json.Value, arena, v orelse "null", .{}) catch break :blk;
                if (pv != .object) break :blk;
                const state = if (pv.object.get("state")) |s| (if (s == .string) s.string else "") else "";
                if (eql(u8, state, "ok")) {
                    if (pv.object.get("secret_len")) |sl| {
                        if (sl == .integer) now_holds = try std.fmt.allocPrint(arena, "(password field: {d} chars)", .{sl.integer});
                    } else if (pv.object.get("value")) |val| {
                        if (val == .string) now_holds = val.string;
                    }
                } else if (eql(u8, state, "detached")) {
                    now_holds = "(field_detached_after_submit: the element left the document — the form was likely submitted)";
                } else {
                    now_holds = "(field no longer focused — a submit/navigation probably moved focus)";
                }
            },
            .err => now_holds = "(unreadable: the DevTools target was replaced — navigation_started)",
        }
        if (browserPageInfo(arena, bs, 3_000)) |info| {
            if (pre_url != null and !eql(u8, pre_url.?, info.url)) {
                nav_note = try std.fmt.allocPrint(arena, "\nnavigation_started: {s} -> {s} ({s})", .{ pre_url.?, info.url, info.ready });
            } else if (!eql(u8, info.ready, "complete")) {
                nav_note = try std.fmt.allocPrint(arena, "\nnavigation_pending: document readyState is {s}", .{info.ready});
            }
        }
        const msg = try std.fmt.allocPrint(arena, "filled <{s}>{s}; field now holds: {s}{s}", .{ tag.?, if (argBool(args, "enter")) ", pressed Enter" else "", now_holds, nav_note });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_wait")) {
        const selector = argStr(args, "selector");
        const text = argStr(args, "text");
        const url_contains = argStr(args, "url_contains");
        const url_exact = argStr(args, "url_exact");
        const url_path = argStr(args, "url_path");
        const url_regex = argStr(args, "url_regex");
        const gone = argStr(args, "gone");
        const net_idle = argBool(args, "network_idle");
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 15_000;
        if (selector == null and text == null and url_contains == null and url_exact == null and
            url_path == null and url_regex == null and gone == null and !net_idle)
            return appErr(arena, "browser_wait needs at least one of: selector, text, url_contains, url_exact, url_path, url_regex, gone, network_idle");
        if (net_idle and !bs.client.net_enabled)
            bs.client.enableNetwork(5_000) catch return appErr(arena, "network_idle needs DevTools network capture, which could not be enabled");
        const cond_js = try std.fmt.allocPrint(arena,
            \\(() => {{
            \\const sel = {s}, txt = {s}, urlsub = {s}, urlx = {s}, urlp = {s}, urlre = {s}, gone = {s};
            \\let ok = true; const why = [];
            \\if (sel) {{ let m = null; try {{ m = document.querySelector(sel); }} catch (e) {{ return 'bad selector'; }} const visible = m && m.getBoundingClientRect().width > 0; if (!visible) {{ ok = false; why.push('selector not visible'); }} }}
            \\if (txt && !(document.body.innerText || '').toLowerCase().includes(txt.toLowerCase())) {{ ok = false; why.push('text not visible'); }}
            \\if (urlsub && !location.href.includes(urlsub)) {{ ok = false; why.push('url does not contain it'); }}
            \\if (urlx && location.href !== urlx) {{ ok = false; why.push('url is ' + location.href); }}
            \\if (urlp && location.pathname !== urlp) {{ ok = false; why.push('pathname is ' + location.pathname); }}
            \\if (urlre) {{ let re = null; try {{ re = new RegExp(urlre); }} catch (e) {{ return 'bad regex'; }} if (!re.test(location.href)) {{ ok = false; why.push('url does not match the regex (is ' + location.href + ')'); }} }}
            \\if (gone) {{ let m = null; try {{ m = document.querySelector(gone); }} catch (e) {{ return 'bad selector'; }} if (m && m.getBoundingClientRect().width > 0) {{ ok = false; why.push('element still present'); }} }}
            \\return ok ? 'ok' : why.join('; ');
            \\}})()
        , .{ try jsStr(arena, selector), try jsStr(arena, text), try jsStr(arena, url_contains), try jsStr(arena, url_exact), try jsStr(arena, url_path), try jsStr(arena, url_regex), try jsStr(arena, gone) });
        const deadline = monoMs() + timeout_ms;
        var last_why: []const u8 = "condition never evaluated";
        while (true) {
            var js_ok = false;
            const out = bEval(arena, bs, cond_js, 5_000);
            switch (out) {
                .val => |v| {
                    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, v orelse "null", .{}) catch std.json.Value{ .null = {} };
                    if (parsed == .string) {
                        if (eql(u8, parsed.string, "ok")) {
                            js_ok = true;
                        } else {
                            if (eql(u8, parsed.string, "bad selector")) return appErr(arena, "invalid CSS selector");
                            if (eql(u8, parsed.string, "bad regex")) return appErr(arena, "invalid url_regex (JavaScript RegExp syntax)");
                            last_why = parsed.string;
                        }
                    }
                },
                .err => |e| last_why = e,
            }
            if (js_ok and net_idle) {
                // Quiet window over CDP Network events: no requests in
                // flight and none started/finished for 500ms.
                bs.client.pump(150);
                const inflight = bs.client.netInFlight();
                const quiet = monoMs() - bs.client.net_last_ms;
                if (inflight > 0 or quiet < 500) {
                    js_ok = false;
                    last_why = try std.fmt.allocPrint(arena, "network not idle ({d} request(s) in flight, {d}ms since last activity)", .{ inflight, quiet });
                }
            }
            if (js_ok) {
                var msg: []const u8 = "condition met";
                if (browserPageInfo(arena, bs, 3_000)) |info|
                    msg = try std.fmt.allocPrint(arena, "condition met\npage: {s}{s}{s}", .{ info.url, if (info.title.len > 0) " — " else "", info.title });
                return toolResult(arena, msg, false) orelse error.OutOfMemory;
            }
            if (monoMs() >= deadline) break;
            sleepMsLocal(300);
        }
        var fail_msg = try std.fmt.allocPrint(arena, "timeout: {s}", .{last_why});
        if (browserPageInfo(arena, bs, 3_000)) |info|
            fail_msg = try std.fmt.allocPrint(arena, "{s}\ncurrently on: {s}{s}{s}", .{ fail_msg, info.url, if (info.title.len > 0) " — " else "", info.title });
        return toolResult(arena, fail_msg, true) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_form_state")) {
        const selector = argStr(args, "selector");
        const js = try std.fmt.allocPrint(arena,
            \\(() => {{ {s}
            \\const q = 'input,select,textarea,[contenteditable]';
            \\const roleSel = "[role='checkbox'],[role='radio'],[role='switch'],[role='combobox'],[role='listbox'],[role='textbox'],[role='slider'],[role='spinbutton']";
            \\const sel = {s};
            \\let scope = null;
            \\if (sel) {{ const m = deepQuery(sel); if (badSelector) return 'bad selector'; if (!m.length) return 'no scope match'; scope = m[0]; }}
            \\const within = (e, root) => {{ if (!root) return true; let n = e; while (n) {{ if (n === root) return true; n = n.parentNode || n.host; }} return false; }};
            \\const isHostCtl = h => h.tagName.includes('-') && h.shadowRoot && (h.shadowRoot.querySelector(q) || h.matches(roleSel) || h.shadowRoot.querySelector("[role='option'],[role='switch'],[role='checkbox'],[role='radio']"));
            \\let ctls = deepQuery(q + ',' + roleSel);
            \\const hosts = deepQuery('*').filter(isHostCtl);
            \\const covered = new Set(); hosts.forEach(h => {{ for (const i2 of h.shadowRoot.querySelectorAll(q)) covered.add(i2); }});
            \\ctls = ctls.filter(e => !covered.has(e));
            \\const all = [...new Set([...ctls, ...hosts])].filter(e => within(e, scope)).filter(e => e.type !== 'hidden');
            \\const entry = e => {{
            \\const inner = e.shadowRoot ? e.shadowRoot.querySelector(q) : null;
            \\const t = inner || e;
            \\const type = t.type || e.getAttribute('type') || undefined;
            \\const secret = type === 'password';
            \\let value = e.value !== undefined ? e.value : (inner ? inner.value : undefined);
            \\if (value === undefined && e.isContentEditable) value = e.textContent;
            \\const checked = e.checked !== undefined ? e.checked : (inner && inner.checked !== undefined ? inner.checked : (e.getAttribute('aria-checked') ? e.getAttribute('aria-checked') === 'true' : undefined));
            \\let options; const oel = e.tagName === 'SELECT' ? e : (inner && inner.tagName === 'SELECT' ? inner : null);
            \\if (oel) options = Array.from(oel.options).slice(0, 30).map(o => ({{text: o.text.slice(0, 60), value: o.value.slice(0, 60), selected: o.selected || undefined}}));
            \\else {{ const ropts = Array.from(e.querySelectorAll("[role='option']")).concat(e.shadowRoot ? Array.from(e.shadowRoot.querySelectorAll("[role='option']")) : []); if (ropts.length) options = ropts.slice(0, 30).map(o => ({{text: (o.innerText || '').trim().slice(0, 60), selected: o.getAttribute('aria-selected') === 'true' || undefined}})); }}
            \\const fo = t.form || (e.closest ? e.closest('form') : null);
            \\const r = e.getBoundingClientRect();
            \\return {{tag: e.tagName.toLowerCase(),
            \\role: e.getAttribute('role') || undefined,
            \\name: e.name || e.getAttribute('name') || (inner ? inner.name : undefined) || undefined,
            \\id: e.id || undefined,
            \\label: labelText(e).trim().slice(0, 100) || undefined,
            \\type,
            \\value: secret ? (value && String(value).length ? '(secret: ' + String(value).length + ' chars)' : '(empty)') : (value !== undefined && value !== null ? String(value).slice(0, 120) : undefined),
            \\checked, options,
            \\disabled: e.disabled || (inner && inner.disabled) || e.getAttribute('aria-disabled') === 'true' || undefined,
            \\required: t.required || e.getAttribute('aria-required') === 'true' || undefined,
            \\validation: (t.validationMessage && t.validationMessage.slice(0, 120)) || undefined,
            \\shadow_input: inner ? (inner.name || inner.tagName.toLowerCase()) : undefined,
            \\form: fo ? (fo.id || fo.getAttribute('name') || '(unnamed form)') : undefined,
            \\visible: vis(e) || undefined,
            \\x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2)}}; }};
            \\return JSON.stringify(all.slice(0, 80).map(entry)); }})()
        , .{ JS_HELPERS, try jsStr(arena, selector) });
        const out = bEval(arena, bs, js, argInt(args, "timeout_ms") orelse 10_000);
        if (try browserErrOr(arena, out)) |e| return e;
        const vj = out.val orelse "[]";
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch
            return toolResult(arena, vj, false) orelse error.OutOfMemory;
        if (parsed == .string) {
            if (eql(u8, parsed.string, "bad selector")) return appErr(arena, "invalid CSS selector");
            if (eql(u8, parsed.string, "no scope match")) return appErr(arena, "the scope selector matched nothing");
            return toolResult(arena, try std.fmt.allocPrint(arena, "form state (open shadow roots traversed; password values are counts only; centers valid for browser_click x/y):\n{s}", .{parsed.string}), false) orelse error.OutOfMemory;
        }
        return toolResult(arena, vj, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_choose")) {
        const selector = argStr(args, "selector");
        const text = argStr(args, "text");
        const value = argStr(args, "value") orelse return appErr(arena, "browser_choose requires 'value' (the option's text or value)");
        if (selector == null and text == null)
            return appErr(arena, "browser_choose needs 'selector' (CSS) or 'text' (control label text)");
        const nth: i64 = argInt(args, "nth") orelse 0;
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 8_000;
        const finder = try elementFinderJs(arena, selector, text);
        const js = try std.fmt.allocPrint(arena,
            \\(() => {{ {s}
            \\if (badSelector) return {{bad: true}};
            \\const want = {s}.toLowerCase();
            \\const chooseNative = el2 => {{ let idx = Array.from(el2.options).findIndex(o => o.value.toLowerCase() === want || o.text.trim().toLowerCase() === want); if (idx < 0) idx = Array.from(el2.options).findIndex(o => o.text.toLowerCase().includes(want)); if (idx < 0) return {{mode: 'native', err: 'no option matching', options: Array.from(el2.options).slice(0, 20).map(o => o.text)}}; el2.selectedIndex = idx; el2.dispatchEvent(new Event('input', {{bubbles: true}})); el2.dispatchEvent(new Event('change', {{bubbles: true}})); return {{mode: 'native', picked: el2.options[idx].text}}; }};
            \\const selish = e => e.matches('select') || (e.shadowRoot && e.shadowRoot.querySelector('select')) || e.matches("[role='combobox'],[role='listbox']") || e.getAttribute('aria-haspopup') === 'listbox' || e.tagName.includes('-');
            \\const cands = els.filter(selish);
            \\const el = (cands.length ? cands : els)[{d}];
            \\if (!el) return {{found: els.length}};
            \\if (el.tagName === 'SELECT') return chooseNative(el);
            \\const inner = el.shadowRoot ? el.shadowRoot.querySelector('select') : null;
            \\if (inner) return chooseNative(inner);
            \\el.scrollIntoView({{block: 'center'}});
            \\const trg = el.shadowRoot ? el.shadowRoot.querySelector("[part*='trigger'],[aria-haspopup],button,[role='button'],[role='combobox']") : null;
            \\const r = (trg && vis(trg) ? trg : el).getBoundingClientRect();
            \\return {{mode: 'custom', x: r.x + r.width / 2, y: r.y + r.height / 2, tag: el.tagName.toLowerCase(), now: (el.value !== undefined && el.value !== null ? String(el.value) : (el.innerText || '')).trim().slice(0, 60)}}; }})()
        , .{ finder, try jsStr(arena, value), nth });
        const out = bEval(arena, bs, js, 10_000);
        if (try browserErrOr(arena, out)) |e| return e;
        const vj = out.val orelse return appErr(arena, "control lookup returned nothing");
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch
            return appErr(arena, "control lookup returned malformed data");
        if (parsed != .object) return appErr(arena, "control lookup returned malformed data");
        if (parsed.object.get("bad") != null) return appErr(arena, "invalid CSS selector");
        const mode = if (parsed.object.get("mode")) |m| (if (m == .string) m.string else "") else "";
        if (mode.len == 0) {
            const found: i64 = if (parsed.object.get("found")) |f| (if (f == .integer) f.integer else 0) else 0;
            return appErr(arena, try std.fmt.allocPrint(arena, "no matching control (matched {d}) — browser_form_state lists the form controls", .{found}));
        }
        if (eql(u8, mode, "native")) {
            if (parsed.object.get("err") != null) {
                var opts_note: []const u8 = "";
                if (parsed.object.get("options")) |ov| {
                    var ow: std.Io.Writer.Allocating = .init(arena);
                    try std.json.Stringify.value(ov, .{}, &ow.writer);
                    opts_note = try std.fmt.allocPrint(arena, "; available: {s}", .{ow.written()});
                }
                return appErr(arena, try std.fmt.allocPrint(arena, "no <select> option matching \"{s}\"{s}", .{ value, opts_note }));
            }
            const picked = if (parsed.object.get("picked")) |p| (if (p == .string) p.string else "?") else "?";
            return toolResult(arena, try std.fmt.allocPrint(arena, "chose \"{s}\" (native select)", .{picked}), false) orelse error.OutOfMemory;
        }
        // Custom control: trusted-click it open, wait for options to
        // surface (shadow-piercing), click the matching one.
        const tag = if (parsed.object.get("tag")) |t| (if (t == .string) t.string else "?") else "?";
        const was = if (parsed.object.get("now")) |n| (if (n == .string) n.string else "") else "";
        const cxv = parsed.object.get("x") orelse return appErr(arena, "control lookup returned no coordinates");
        const cx: f64 = switch (cxv) {
            .float => cxv.float,
            .integer => @floatFromInt(cxv.integer),
            else => 0,
        };
        const cyv = parsed.object.get("y").?;
        const cy: f64 = switch (cyv) {
            .float => cyv.float,
            .integer => @floatFromInt(cyv.integer),
            else => 0,
        };
        bs.client.clickAt(arena, cx, cy, "left", 1, 8_000) catch
            return appErr(arena, "could not click the control open (DevTools connection lost?)");
        const opt_js = try std.fmt.allocPrint(arena,
            \\(() => {{ {s}
            \\const want = {s}.toLowerCase();
            \\let opts = deepQuery("[role='option'],option,[part='option']").filter(vis);
            \\if (!opts.length) opts = deepQuery("li").filter(vis);
            \\if (!opts.length) return {{count: 0}};
            \\let hit = opts.find(o => (o.innerText || '').trim().toLowerCase() === want || (o.value || '').toLowerCase() === want);
            \\if (!hit) hit = opts.find(o => (o.innerText || '').toLowerCase().includes(want));
            \\if (!hit) return {{count: opts.length, seen: opts.slice(0, 15).map(o => (o.innerText || '').trim().slice(0, 40))}};
            \\hit.scrollIntoView({{block: 'center'}});
            \\const r = hit.getBoundingClientRect();
            \\return {{x: r.x + r.width / 2, y: r.y + r.height / 2, text: (hit.innerText || '').trim().slice(0, 60)}}; }})()
        , .{ JS_HELPERS, try jsStr(arena, value) });
        const deadline = monoMs() + timeout_ms;
        var seen_note: []const u8 = "no visible options appeared";
        while (true) {
            sleepMsLocal(250);
            const oout = bEval(arena, bs, opt_js, 5_000);
            const ovj = switch (oout) {
                .val => |v| v orelse "null",
                .err => "null",
            };
            const op = std.json.parseFromSliceLeaky(std.json.Value, arena, ovj, .{}) catch std.json.Value{ .null = {} };
            if (op == .object) {
                if (op.object.get("x")) |oxv| {
                    const ox: f64 = switch (oxv) {
                        .float => oxv.float,
                        .integer => @floatFromInt(oxv.integer),
                        else => 0,
                    };
                    const oyv = op.object.get("y").?;
                    const oy: f64 = switch (oyv) {
                        .float => oyv.float,
                        .integer => @floatFromInt(oyv.integer),
                        else => 0,
                    };
                    const otext = if (op.object.get("text")) |t2| (if (t2 == .string) t2.string else "?") else "?";
                    bs.client.clickAt(arena, ox, oy, "left", 1, 8_000) catch
                        return appErr(arena, "found the option but could not click it (DevTools connection lost?)");
                    _ = app.waitIdle(150, 1_500);
                    // Read the control back for confirmation.
                    const rb_js = try std.fmt.allocPrint(arena,
                        \\(() => {{ {s}
                        \\const seln = {s}; const txtn = {s};
                        \\let els2 = seln ? deepQuery(seln) : [];
                        \\if (!els2.length && txtn) {{ els2 = deepQuery('*').filter(e => e.tagName.includes('-') && e.shadowRoot).filter(e => labelText(e).toLowerCase().includes(txtn.toLowerCase())); }}
                        \\const el3 = els2[0]; if (!el3) return null;
                        \\return (el3.value !== undefined && el3.value !== null ? String(el3.value) : (el3.innerText || '')).trim().slice(0, 80); }})()
                    , .{ JS_HELPERS, try jsStr(arena, selector), try jsStr(arena, text) });
                    const rb = bEval(arena, bs, rb_js, 5_000);
                    var now: []const u8 = "";
                    if (rb == .val) {
                        if (rb.val) |v2| {
                            const pv = std.json.parseFromSliceLeaky(std.json.Value, arena, v2, .{}) catch std.json.Value{ .null = {} };
                            if (pv == .string) now = pv.string;
                        }
                    }
                    var msg = try std.fmt.allocPrint(arena, "chose \"{s}\" in <{s}>", .{ otext, tag });
                    if (was.len > 0) msg = try std.fmt.allocPrint(arena, "{s} (was: {s})", .{ msg, was });
                    if (now.len > 0) msg = try std.fmt.allocPrint(arena, "{s}; control now shows: {s}", .{ msg, now });
                    return toolResult(arena, msg, false) orelse error.OutOfMemory;
                }
                if (op.object.get("seen")) |sv| {
                    var ow: std.Io.Writer.Allocating = .init(arena);
                    try std.json.Stringify.value(sv, .{}, &ow.writer);
                    seen_note = try std.fmt.allocPrint(arena, "options visible but none match: {s}", .{ow.written()});
                }
            }
            if (monoMs() >= deadline) break;
        }
        // Close whatever popup the click opened before reporting.
        _ = bs.client.call(arena, "Input.dispatchKeyEvent", "{\"type\":\"keyDown\",\"key\":\"Escape\",\"code\":\"Escape\",\"windowsVirtualKeyCode\":27,\"nativeVirtualKeyCode\":27}", 3_000) catch {};
        _ = bs.client.call(arena, "Input.dispatchKeyEvent", "{\"type\":\"keyUp\",\"key\":\"Escape\",\"code\":\"Escape\",\"windowsVirtualKeyCode\":27,\"nativeVirtualKeyCode\":27}", 3_000) catch {};
        return appErr(arena, try std.fmt.allocPrint(arena, "clicked <{s}> open but could not pick \"{s}\": {s} — inspect with browser_form_state/browser_elements and click the option manually", .{ tag, value, seen_note }));
    }
    if (eql(u8, name, "browser_network")) {
        if (!bs.client.net_enabled) {
            bs.client.enableNetwork(5_000) catch return appErr(arena, "could not enable DevTools network capture");
            return toolResult(arena, "network capture was off and is enabled NOW — requests are recorded from this point on; interact/navigate, then call browser_network again", false) orelse error.OutOfMemory;
        }
        bs.client.pump(200);
        if (argBool(args, "clear")) {
            bs.client.netClear();
            return toolResult(arena, "network log cleared", false) orelse error.OutOfMemory;
        }
        const filter = argStr(args, "filter");
        const limit: usize = @intCast(std.math.clamp(argInt(args, "limit") orelse 30, 1, 200));
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.print("{{\"tracked\":{d},\"in_flight\":{d},\"dropped\":{d},\"requests\":[", .{ bs.client.net.items.len, bs.client.netInFlight(), bs.client.net_dropped });
        // Newest last; walk from the tail collecting up to `limit`.
        var idxs: std.ArrayList(usize) = .empty;
        defer idxs.deinit(arena);
        var i = bs.client.net.items.len;
        while (i > 0 and idxs.items.len < limit) {
            i -= 1;
            const e = bs.client.net.items[i];
            if (filter) |f| {
                if (std.mem.indexOf(u8, e.url, f) == null and
                    std.mem.indexOf(u8, e.first_url, f) == null) continue;
            }
            try idxs.append(arena, i);
        }
        var first = true;
        var j = idxs.items.len;
        while (j > 0) {
            j -= 1;
            const e = bs.client.net.items[idxs.items[j]];
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("{{\"seq\":{d},\"method\":\"{s}\",\"url\":", .{ e.seq, e.method });
            try std.json.Stringify.value(if (e.url.len > 200) e.url[0..200] else e.url, .{}, w);
            if (e.status != 0) try w.print(",\"status\":{d}", .{e.status});
            if (e.resource_type.len > 0) try w.print(",\"type\":\"{s}\"", .{e.resource_type});
            if (e.mime.len > 0) {
                try w.writeAll(",\"mime\":");
                try std.json.Stringify.value(e.mime, .{}, w);
            }
            if (!e.finished) try w.writeAll(",\"in_flight\":true");
            if (e.error_text.len > 0) {
                try w.writeAll(",\"failed\":");
                try std.json.Stringify.value(e.error_text, .{}, w);
            }
            if (e.redirects > 0) try w.print(",\"redirects\":{d}", .{e.redirects});
            if (e.first_url.len > 0) {
                try w.writeAll(",\"redirected_from\":");
                try std.json.Stringify.value(if (e.first_url.len > 200) e.first_url[0..200] else e.first_url, .{}, w);
            }
            if (e.post_keys.len > 0) {
                try w.writeAll(",\"post_keys\":");
                try std.json.Stringify.value(e.post_keys, .{}, w);
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_scroll")) {
        var js: []const u8 = undefined;
        if (argStr(args, "to")) |to| {
            if (eql(u8, to, "top")) {
                js = "window.scrollTo(0, 0)";
            } else if (eql(u8, to, "bottom")) {
                js = "window.scrollTo(0, document.documentElement.scrollHeight)";
            } else {
                return appErr(arena, "'to' must be \"top\" or \"bottom\" (use 'selector' to scroll an element into view)");
            }
        } else if (argStr(args, "selector")) |sel| {
            js = try std.fmt.allocPrint(arena,
                \\(() => {{ let el = null; try {{ el = document.querySelector({s}); }} catch (e) {{ return 'bad selector'; }} if (!el) return 'no match'; el.scrollIntoView({{block: 'center'}}); return true; }})()
            , .{try jsStr(arena, sel)});
        } else if (argInt(args, "y")) |y| {
            js = try std.fmt.allocPrint(arena, "window.scrollTo(0, {d})", .{y});
        } else if (argInt(args, "dy")) |dy| {
            js = try std.fmt.allocPrint(arena, "window.scrollBy(0, {d})", .{dy});
        } else {
            return appErr(arena, "browser_scroll needs one of: to (top/bottom), selector, y (absolute), dy (relative)");
        }
        const out = bEval(arena, bs, js, 8_000);
        if (try browserErrOr(arena, out)) |e| return e;
        if (out.val) |v| {
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, v, .{}) catch std.json.Value{ .null = {} };
            if (parsed == .string) {
                if (eql(u8, parsed.string, "bad selector")) return appErr(arena, "invalid CSS selector");
                if (eql(u8, parsed.string, "no match")) return appErr(arena, "selector matched nothing");
            }
        }
        _ = app.waitIdle(150, 1_500);
        const pos = bEval(arena, bs, "({scroll_y: Math.round(scrollY), doc_height: document.documentElement.scrollHeight, viewport_h: innerHeight})", 5_000);
        return toolResult(arena, switch (pos) {
            .val => |v| v orelse "scrolled",
            .err => "scrolled",
        }, false) orelse error.OutOfMemory;
    }
    return appErr(arena, "unknown tool");
}
