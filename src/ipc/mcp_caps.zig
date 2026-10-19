//! MCP `capabilities`: the one preflight a consumer reads instead of
//! probing behaviour. Every server-side lane, backend and mode is a fact here.

const std = @import("std");
const ocr = @import("../util/ocr.zig");
const mcpfilter = @import("mcpfilter.zig");
const panelstore = @import("panelstore.zig");
const mcp_webgui = @import("mcp_webgui.zig");
const mcp = @import("mcp.zig");
const mcp_app = @import("mcp_app.zig");
const mcp_term = @import("mcp_term.zig");
const mcp_ui = @import("mcp_ui.zig");
const Backend = mcp.Backend;
const Res = mcp.Res;
const Tuning = mcp.Tuning;
const UI_CAPABILITY_PROBE_MS = mcp_ui.UI_CAPABILITY_PROBE_MS;
const UiTransport = mcp_ui.UiTransport;
const pathz = @import("../util/pathz.zig");
const recDir = mcp_term.recDir;
const run = mcp.run;
const uiStoreScope = mcp_ui.uiStoreScope;
const uiWireSession = mcp_ui.uiWireSession;
const webGuiTransport = mcp.webGuiTransport;
const yesNo = mcp.yesNo;

/// `sketerm-webengine` as both backends would find it (the shared
/// findbin lookup: $SKETERM_WEB_BIN, next to our executable, dev
/// tree), then $PATH. What the `web_*` tools ultimately depend on, so
/// `capabilities` reports it.
fn webHelperPath(arena: std.mem.Allocator) ?[]const u8 {
    var buf: [4096:0]u8 = undefined;
    if (@import("../web/findbin.zig").find(&buf)) |p| {
        return arena.dupe(u8, std.mem.span(p)) catch null;
    }
    if (pathz.findExecutable(&buf, "sketerm-webengine")) |p| return arena.dupe(u8, p) catch null;
    return null;
}

/// Web features sorted by verdict, so the text lane names each one once.
pub const Verdicts = struct {
    yes: std.ArrayList([]const u8) = .empty,
    no: std.ArrayList([]const u8) = .empty,
    unknown: std.ArrayList([]const u8) = .empty,

    /// @param v null = not known until the browser engine starts.
    pub fn add(self: *Verdicts, arena: std.mem.Allocator, name: []const u8, v: ?bool) !void {
        const list = if (v) |b| (if (b) &self.yes else &self.no) else &self.unknown;
        try list.append(arena, name);
    }

    pub fn line(self: *const Verdicts, arena: std.mem.Allocator, backend: []const u8) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.print("web: {s} backend", .{backend});
        if (self.yes.items.len > 0) try w.print("; here: {s}", .{try std.mem.join(arena, ", ", self.yes.items)});
        if (self.no.items.len > 0) try w.print("; not here: {s}", .{try std.mem.join(arena, ", ", self.no.items)});
        if (self.unknown.items.len > 0) try w.print("; known once the engine starts: {s}", .{try std.mem.join(arena, ", ", self.unknown.items)});
        return aw.written();
    }
};

/// The preflight: what this server can actually do right now. Facts
/// only in structuredContent — every `*_hint` prose field this used to
/// carry either states something the tool's own description already
/// says, or is a SITUATIONAL note, which is one line of the text lane.
pub fn capabilitiesTool(arena: std.mem.Allocator, backend: Backend) ![]const u8 {
    var res = Res.init(arena);
    // headless_gui is what launch_app actually depends on (the mux
    // daemon), and it is effectively always true. gui_socket was once
    // read as "no GUI here", steering assistants back to Xvfb — the
    // two are independent, which the text lane says in one line.
    const headless_terms = mcp_term.term_state.mux_sock != null;
    try res.fact("mode", mcp.srv_mode);
    try res.fact("result_mode", @tagName(mcp.result_mode));
    try res.fact("headless_gui", mcp_app.app_state.ready);
    try res.fact("gui_socket", mcp.srv_gui_socket);
    try res.fact("gui_socket_source", @tagName(mcp.srv_gui_socket_source));
    try res.fact("headless_terminals", headless_terms);
    try res.fact("transfers_and_forwards", headless_terms);
    try res.textf("sketerm {s} MCP, mode {s}; results: {s}", .{
        @import("../version.zig").string,
        mcp.srv_mode,
        switch (mcp.result_mode) {
            .text => "text only (--structured adds structuredContent and outputSchema)",
            .structured => "structured (structuredContent beside the text, outputSchema in tools/list)",
        },
    });
    try res.textf("headless GUI apps {s}, headless terminals {s} (transfers and forwards with them), direct GUI control socket {s} ({s}independent of both and of relayed panels)", .{
        yesNo(mcp_app.app_state.ready),
        yesNo(headless_terms),
        yesNo(mcp.srv_gui_socket),
        if (mcp.srv_gui_socket) try std.fmt.allocPrint(arena, "{s}; ", .{@tagName(mcp.srv_gui_socket_source)}) else "",
    });
    try res.text(if (std.mem.eql(u8, mcp.srv_mode, "shared"))
        "sessions live on the user's own daemon and outlive this server; nothing times them out"
    else if (std.mem.eql(u8, mcp.srv_mode, "isolated"))
        "PRIVATE mux daemon: its sessions are invisible to the user's `sketerm mux list` / `sketerm app` (and theirs here), and it is torn down with every app and terminal when this server exits; there is no idle timeout, so an app that 'exited on its own' between sessions was killed by that teardown. --durable/--name keep sessions, --shared joins the user's daemon"
    else
        "PRIVATE durable mux daemon: its sessions are invisible to the user's `sketerm mux list` / `sketerm app`, survive this server's restarts and are reattached on reconnect; there is no idle timeout");

    // Panel delivery is independent of gui_socket: an isolated MCP can
    // relay to the GUI attached to its inherited origin session.
    const panel_session = panelstore.resolveSession(.absent);
    var panel_transport = UiTransport.init(arena, backend, panel_session);
    defer panel_transport.deinit();
    // A preflight must stay cheap and must not write anything: probe the
    // relay under a short deadline of its own, and report the store by
    // whether its scope RESOLVES. Whether the state dir is writable is the
    // business of the call that actually writes (ui_save says so exactly).
    const panel_reply = panel_transport.talkFor(.{
        .cmd = "panel-list",
        .session = uiWireSession(panel_session),
    }, UI_CAPABILITY_PROBE_MS);
    const panels_ready = panel_reply.ok;
    const panel_store = uiStoreScope(&panel_transport, UI_CAPABILITY_PROBE_MS);
    const panel_store_ready = panel_store.err.len == 0;
    const panel_store_scope_name: []const u8 = if (panel_store.err.len > 0)
        "unavailable"
    else switch (panel_store.scope) {
        .sessionless => "sessionless",
        .session => "session",
        .origin => "origin",
    };
    const panel_state_name: []const u8 = if (panels_ready)
        "ready"
    else if (panel_transport.failure) |failure|
        switch (failure.kind) {
            .legacy_daemon => "legacy_daemon",
            .unsupported => "unsupported_daemon",
            .no_compatible_gui => "no_compatible_gui",
            .no_such_session => "session_unavailable",
            .origin_unreachable => "origin_unreachable",
            .origin_timeout => "origin_timeout",
            .attach_failed => "session_unavailable",
            .identity_mismatch => "identity_mismatch",
            .malformed_attach => "malformed_attach_metadata",
            .malformed_welcome => "malformed_daemon_welcome",
            .request_too_large => "request_too_large",
            .allocation_failed => "pre_delivery_allocation_failed",
            .send_pre_delivery => "send_pre_delivery",
            .delivery_uncertain => "delivery_uncertain",
            .reply_timeout => "viewer_timeout",
            .disconnected => "viewer_disconnected",
            .malformed_reply => "malformed_reply",
        }
    else if (std.mem.indexOf(u8, panel_reply.err, "no compatible GUI") != null)
        "no_compatible_gui"
    else if (panel_session == null and !mcp.srv_gui_socket)
        "no_session_origin"
    else
        "unavailable";
    try res.fact("panels", panels_ready);
    try res.fact("panels_store", panel_store_ready);
    {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.print("{{\"state\":\"{s}\",\"scope\":\"{s}\"", .{
            if (panel_store_ready) "ready" else "unavailable",
            panel_store_scope_name,
        });
        if (!panel_store_ready) {
            try w.writeAll(",\"error\":");
            try std.json.Stringify.value(panel_store.err, .{}, w);
            try w.writeAll(",\"reason\":\"identity_validation_failed\"");
        }
        try w.writeAll("}");
        try res.raw("panel_store", aw.written());
    }
    {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("{\"selected\":");
        try std.json.Stringify.value(panel_transport.selected(), .{}, w);
        try w.writeAll(",\"source\":");
        try std.json.Stringify.value(panel_transport.source(), .{}, w);
        try w.writeAll(",\"state\":");
        try std.json.Stringify.value(panel_state_name, .{}, w);
        try w.writeAll(",\"session\":");
        try std.json.Stringify.value(panel_session, .{}, w);
        if (!panels_ready) {
            try w.writeAll(",\"error\":");
            try std.json.Stringify.value(panel_reply.err, .{}, w);
        }
        try w.writeAll("}");
        try res.raw("panel_transport", aw.written());
    }
    try res.textf("panels: live {s} ({s}, transport {s}), saved {s} (scope {s})", .{
        if (panels_ready) "ready" else "unavailable",
        panel_state_name,
        panel_transport.selected(),
        if (panel_store_ready) "ready" else "unavailable",
        panel_store_scope_name,
    });
    if (!panels_ready)
        try res.text(if (panel_store_ready)
            "live ui_* calls need an origin session relay (SKETERM_SESSION plus SKETERM_MUX_SOCKET, or the connect-only default daemon) or an explicit direct GUI socket; ui_save, ui_panels and ui_delete still work on saved documents"
        else
            "live ui_* calls need an origin session relay (SKETERM_SESSION plus SKETERM_MUX_SOCKET, or the connect-only default daemon) or an explicit direct GUI socket");
    if (!panel_store_ready)
        try res.textf("saved panels are unavailable: the exact origin identity could not be resolved ({s}); ui_save and ui_delete fail the same way, and an exact origin never downgrades to reusable session storage", .{panel_store.err});

    const ocr_ok = ocr.available();
    try res.fact("ocr", ocr_ok);
    if (!ocr_ok)
        try res.text("app_read_text/app_wait_text need libtesseract — install tesseract + tesseract-data-eng on THIS machine");
    // Rootless X11 for app sessions is a daemon-host fact; the private
    // daemon runs on this host, so PATH here is the answer for it.
    const xwl_ok = pathz.executableOnPath("Xwayland") and pathz.executableOnPath("xwayland-satellite");
    try res.fact("app_xwayland", xwl_ok);
    const webm_ok = @import("../util/videorec.zig").available;
    try res.fact("app_record_webm", webm_ok);
    if (!webm_ok)
        try res.text("app_record_start records GIF only: this binary links no libvpx, so format:\"webm\" is refused and the default format is gif");
    if (!xwl_ok)
        try res.text("launch_app xwayland:true (X11-only apps) needs Xwayland AND xwayland-satellite on THIS machine's PATH; a launch asking for it fails until they are installed");

    const helper = webHelperPath(arena);
    // The web tools drive the user's GUI on a server-wide socket OR on
    // the web_gui grant's own; both are "gui" to a consumer.
    const gui_web = @import("mcp_web.zig").guiDrivesWeb();
    // Which backend will answer, and — for the headless case — whether
    // that is a MEASUREMENT or a prediction. The engine starts lazily
    // at the first web call, so before one exists "headless" vs
    // "session" is not yet decided: reporting the guess as a fact once
    // sent a session down an entire mirroring workaround built on a
    // `web_watch:false` that flipped to true the moment a view opened.
    const engine_started = @import("mcp_web.zig").engineStarted();
    const web_backend: []const u8 = if (helper == null)
        "none"
    else if (gui_web)
        "gui"
    else if (std.mem.eql(u8, mcp.srv_mode, "shared"))
        "none"
    else if (@import("mcp_web.zig").sessionInfo() != null)
        "session"
    else if (!engine_started)
        "not_yet_determined"
    else
        "headless";
    const web_ok = helper != null and !std.mem.eql(u8, web_backend, "none");
    // Every web feature verdict, emitted as ONE line after the section.
    var verdicts: Verdicts = .{};
    if (helper) |wp| try res.fact("web_helper", wp) else try res.raw("web_helper", "null");
    try res.fact("web", web_ok);
    try res.fact("web_backend", web_backend);
    // The web_gui grant: permission, its source, and the socket state
    // it holds NOW (lazy: none until the first web call, and never
    // touched by this preflight).
    try res.fact("web_gui", mcp.srv_web_gui.granted);
    try res.fact("web_gui_source", mcp.srv_web_gui.source.name());
    try res.fact("web_gui_transport", webGuiTransport().name());
    if (mcp.srv_web_gui.granted) {
        const via: []const u8 = switch (mcp.srv_web_gui.source) {
            .config => if (mcp.srv_web_gui.profile.len > 0)
                try std.fmt.allocPrint(arena, "config [mcp.{s}]", .{mcp.srv_web_gui.profile})
            else
                "config [mcp]",
            .env => mcp_webgui.ENV,
            .flag => mcp_webgui.FLAG,
            .none => "none",
        };
        const sock_note: []const u8 = if (mcp_webgui.socketPath()) |p|
            try std.fmt.allocPrint(arena, " ({s})", .{p})
        else if (mcp.srv_gui_socket)
            " (the server-wide GUI socket)"
        else
            "";
        try res.textf("web_gui: granted via {s}: the web_* tools use the user's OWN browser and logins (transport now {s}{s}, found or started at the first web call); with no reachable GUI a web call fails 'unavailable', never falls back to a private browser. Terminal/app/file/panel tools stay on the private daemon", .{ via, webGuiTransport().name(), sock_note });
    } else try res.textf("web_gui: not granted, so the web_* tools use a private browser logged in nowhere; the user grants their own browser with {s}, {s}=1 or web_gui = true in config.conf's [mcp] section", .{ mcp_webgui.FLAG, mcp_webgui.ENV });
    if (@import("mcp_web.zig").sessionInfo()) |ws| try res.fact("web_session", ws);
    const display = @import("mcp_web.zig").displayMode();
    try res.fact("web_display", if (display) |d| @tagName(d) else null);
    if (display == .headless_fallback)
        try res.text("web_display: the browser helper failed to start on its virtual display and runs PLAIN HEADLESS instead (no watch-along pixels or page audio for a viewer; pages see no display server)");
    // Watch-along: the private daemon socket and whether the web session
    // shows pixels. Both are facts a human needs to find the assistant's
    // browser from their own GUI; the text lane says where to look.
    const web_watch = @import("mcp_web.zig").presenterActive();
    // Undetermined until an engine exists: `null`, never `false`. An
    // authoritative-looking wrong value is worse than no value.
    if (web_ok and !gui_web and !engine_started)
        try res.raw("web_watch", "null")
    else
        try res.fact("web_watch", web_watch);
    try res.fact("web_engine_started", engine_started);
    try res.fact("web_untrusted", @import("mcp_web.zig").restrictedCapability(.untrusted_web));
    try res.fact("web_policy_ack", @import("mcp_web.zig").restrictedCapability(.net_policy_ack));
    try res.fact("web_navigation_guard", @import("mcp_web.zig").restrictedCapability(.navigation_guard));
    try res.fact("web_emulation", @import("mcp_web.zig").restrictedCapability(.web_emulation));
    try res.fact("web_untrusted_mode", @import("mcp_web.zig").untrustedMode());
    try res.fact("web_review", .{ .inspection = true, .checkpoints = true, .evidence_export = true, .requires_helper_capability = "review", .gui_console = false });
    try res.fact("web_diagnostics", .{ .direct_capture = true, .broker_capture = "requires engine_open diagnostics capability", .gui_capture = false, .retention = "last attempt per route until next attempt or MCP shutdown" });
    if (web_ok and !gui_web and !engine_started)
        try res.text("the browser engine starts at the first web_* call: whether it runs headless or on a session, and whether the user can watch it, are not decided until then (read capabilities again after one)");
    // The browser-page watch: the GUI joins this server's helper as a
    // second client and shows its pages as web pages (helper
    // capability "observe"). `web_socket` is the socket it joins.
    const web_observe = @import("mcp_web.zig").observeActive();
    try res.fact("web_observe", web_observe);
    const handoff_available: ?bool = if (!gui_web and !engine_started) null else web_observe and @import("mcp_web.zig").sessionInfo() != null;
    try res.fact("web_handoff", .{ .session_naming = !gui_web, .available = handoff_available, .entry_point = "AI badge: Watch / Take control", .backend_is_visibility = false });
    var web_sock_buf: [4096]u8 = undefined;
    if (@import("mcp_web.zig").helperSocket(&web_sock_buf)) |ws| try res.fact("web_socket", ws) else try res.raw("web_socket", "null");
    if (web_observe) try res.text("the user can watch or take control of assistant tabs (orange AI badge / Session Overview), so backend headless does not mean invisible: give web_open a descriptive name and keep a tab open for a manual login");
    if (mcp_app.app_state.mux_sock) |ms| try res.fact("mux_socket", ms) else try res.raw("mux_socket", "null");
    if (@import("mcp_web.zig").sessionInfo()) |ws| {
        if (mcp_app.app_state.mux_sock) |ms| {
            try res.textf("the user can watch this browser: session {s} on {s}{s}", .{
                ws,
                ms,
                if (web_watch) " (pages are presented as windows; a viewer holding the controller lease can drive them)" else " (audio and lifetime only: the helper did not arm its presenter)",
            });
        }
    }
    // Per-tab network routes: which kinds `web_open route:` can honour
    // here. A refused route must be explicable from a preflight, never
    // discovered by trying it.
    {
        const routes = @import("mcp_web.zig").routeCapability(web_ok);
        try res.fact("web_routes", routes.name());
        try res.text(routes.describe());
        const proxy = @import("mcp_web.zig").routeProxyCapability(web_ok);
        try res.fact("web_route_proxy", proxy);
        try res.fact("web_untrusted_routes", @import("mcp_web.zig").untrustedRouteWords());
        if (proxy.available) try res.textf("route {s} sends a tab's every request through your own forward proxy, which resolves every host; untrusted views {s}", .{
            proxy.grammar,
            if (proxy.untrusted) "may take it (their loader then dials that proxy and nothing else)" else "cannot open here",
        });
    }
    // How tabs are addressed when several callers share this browser.
    {
        const rules = @import("mcp_web.zig").tabRules();
        try res.fact("web_tab_rules", rules);
        if (rules.idle_close_secs > 0)
            try res.textf("web tabs: an assistant tab untouched for {d} s closes itself unless someone is watching it", .{rules.idle_close_secs})
        else
            try res.text("web tabs: idle closing is off");
    }
    // The discoverability half of fail-closed: without this, a
    // web_open that refuses a profile reads as a bug rather than as a
    // capability this server does not have.
    {
        const profiles = @import("mcp_web.zig").profileCapability(arena);
        try res.fact("web_profiles", profiles.available);
        // Certificate errors are FACTS on every web result, and a
        // headless view answers them itself (fail closed, fingerprint
        // opt-in). A consumer must not have to hang once to learn that.
        try res.fact("web_cert_facts", true);
        // What a web_* call leaves behind: every tab-scoped reply says
        // whether its identity persists, every written file whether it
        // outlives this instance.
        const persist = try @import("mcp_web.zig").persistenceCapability(arena);
        try res.fact("web_persistence", persist);
        if (persist.default) |d| try res.text(try @import("webpersist.zig").sentence(arena, d));
        // What a navigation produced, on web_open/web_navigate replies.
        try res.fact("web_nav_result", @import("mcp_web.zig").navResultCapability());
        // Reading several urls without driving a tab: its limits are
        // what a caller plans a batch around.
        const fetch = @import("mcp_webfetch.zig").capability();
        try res.fact("web_fetch", fetch);
        if (fetch.available)
            try res.textf("web_fetch: at most {d} tabs per call and {d} across every concurrent call, the rest queue; {d} in flight, {d} queued now", .{ fetch.per_call_tabs, fetch.max_tabs, fetch.in_flight, fetch.queued })
        else
            try res.textf("web_fetch is unavailable here: {s}", .{fetch.reason.?});
        try verdicts.add(arena, "web_fetch", fetch.available);
        // Reading one tab: modes, caps, and what the running helper can
        // do, so an old helper's refusal is explicable in advance.
        const rd = @import("mcp_web.zig").readCapability();
        try res.fact("web_read", rd);
        if (rd.page_read) |p| if (!p) try res.text("web_read: the running helper predates page reading, so selector, include_chrome, links and resources answer unavailable");
        // Downloading through a view: the only path that carries the
        // page's own session, so a consumer must be able to preflight
        // it rather than discover it by trying.
        const dl = @import("mcp_web.zig").downloadCapability();
        try res.fact("web_downloads", dl.supported);
        try verdicts.add(arena, if (dl.supported and !dl.started) "downloads (once the engine starts)" else "downloads", dl.supported);
        // Printing a view: a consumer asks for an @page-sized sheet only
        // when the running helper honours it.
        const pr = @import("mcp_web.zig").printCapability();
        try res.fact("web_print_pdf", pr.supported);
        try res.fact("web_print_pdf_css_page", pr.css_page);
        try verdicts.add(arena, "print_pdf", pr.supported);
        if (pr.supported) if (pr.css_page) |css| if (!css) try res.text("web_print_pdf: this helper predates css_page_size and no_margins");
        // Response-body capture: a fail-closed open option, so a
        // consumer must be able to preflight it rather than trip over
        // the refusal.
        const cp = @import("mcp_web.zig").captureCapability();
        try res.fact("web_capture", cp.supported);
        const stream = @import("mcp_web.zig").streamCapability();
        try res.fact("web_stream", web_ok and stream.supported);
        try verdicts.add(arena, if (gui_web) "stream (headless only)" else "stream", web_ok and stream.supported);
        try res.fact("web_stream_audio", stream.audio);
        try res.fact("web_stream_encoded", stream.encoded);
        try res.fact("web_stream_popups", stream.popups);
        try res.fact("web_software_webgl", @import("mcp_web.zig").webglCapability(.software_webgl));
        try res.fact("web_webgl", if (@import("mcp_web.zig").webglMode()) |m| @tagName(m) else null);
        const scr = @import("mcp_web.zig").screenCapability();
        var scr_buf: [16]u8 = undefined;
        try res.fact("web_screen", if (scr.screen) |s| std.fmt.bufPrint(&scr_buf, "{f}", .{s}) catch null else null);
        try res.fact("web_screen_source", @tagName(scr.source));
        const mo = @import("mcp_web.zig").motionCapability();
        if (mo.setup.summary) |s| {
            try res.fact("web_motion", .{ .pack = mo.setup.pack_name, .device = @tagName(s.device), .rate_hz = s.rate_hz, .reaches = s.reaches, .keys = s.keys, .scroll = s.scroll, .idle = s.idle, .drift = s.drift });
            try res.textf("motion pack '{s}': {s} at {d:.0} Hz, {d} reaches, {d} key timings, {d} scroll bursts, {d} idle drift segments ({d} replayable); web_act/web_scroll motion:\"replay\" replays it, web_open idle_drift:true drifts between actions", .{ mo.setup.pack_name, @tagName(s.device), s.rate_hz, s.reaches, s.keys, s.scroll, s.idle, s.drift });
        } else try res.fact("web_motion", null);
        try res.fact("web_motion_default", @tagName(mo.setup.default));
        try res.fact("web_motion_default_source", @tagName(mo.setup.default_source));
        try res.fact("web_motion_replay", mo.helper);
        try res.fact("web_motion_broken", mo.setup.broken);
        try res.fact("web_motion_idle_drift", mo.setup.idle_drift);
        try res.fact("web_motion_idle_drift_source", @tagName(mo.setup.idle_drift_source));
        try res.fact("web_motion_drift", mo.drift_helper);
        if (mo.setup.idle_drift) try res.text("idle drift is ON by default: every headless web_open that omits idle_drift replays the pack's recorded idle wander between actions, and fails closed when it cannot");
        if (mo.setup.broken) |why| try res.textf("motion replay is BROKEN: {s}{s}", .{ why, if (mo.setup.default == .replay) " (the default is replay, so actions fail until this is fixed)" else "" });
        const frame_rate = @import("mcp_web.zig").frameRateCapability();
        try res.fact("web_max_fps", frame_rate.supported);
        try res.fact("web_default_max_fps", frame_rate.default);
        try verdicts.add(arena, if (gui_web) "capture (headless only)" else if (cp.supported and !cp.started) "capture (once the engine starts)" else "capture", cp.supported);
        // Driving a page by hand (web_input) and watching it (web_frame)
        // are headless tools: with a GUI the pane owns its mouse and its
        // pixels. A remote-control viewer preflights both here.
        try res.fact("web_input", web_ok and !gui_web);
        try res.fact("web_frames", web_ok and !gui_web);
        try verdicts.add(arena, if (gui_web) "input/frames (headless only)" else "input/frames", web_ok and !gui_web);
        try verdicts.add(arena, "untrusted views", @import("mcp_web.zig").restrictedCapability(.untrusted_web));
        try verdicts.add(arena, "policy acks", @import("mcp_web.zig").restrictedCapability(.net_policy_ack));
        try verdicts.add(arena, "navigation guard", @import("mcp_web.zig").restrictedCapability(.navigation_guard));
        try verdicts.add(arena, "emulation", @import("mcp_web.zig").restrictedCapability(.web_emulation));
        try verdicts.add(arena, "software WebGL", @import("mcp_web.zig").webglCapability(.software_webgl));
        try verdicts.add(arena, "max_fps", frame_rate.supported);
        try res.fact("web_accept_cert", !gui_web);
        try res.text(if (gui_web)
            "certificate errors: the user's interstitial decides"
        else
            "certificate errors fail closed in headless views; web_open accept_cert trusts one fingerprint for one view");
        if (profiles.store.len > 0) try res.fact("web_profile_store", profiles.store);
        try res.fact("web_profile_save", @import("mcp_web.zig").profileSaveCapability());
        try verdicts.add(arena, "named profiles", profiles.available);
        if (!profiles.available and profiles.reason.len > 0)
            try res.textf("named browsing profiles are unavailable: {s}", .{profiles.reason});
    }
    // Engine lifecycle, as a FACT: a consumer once had to infer "is the
    // engine broker-owned" from profile side effects. Every capability
    // the server gains is reported here from day one.
    if (web_ok and !gui_web) {
        const eng = @import("mcp_web.zig").engineCapability();
        try res.fact("web_engine_broker", eng.broker_lane);
        try res.fact("web_engine_owner", eng.owner.name());
        if (eng.broker_lane)
            try res.textf("browser engine: broker-owned (the mux daemon keeps sketerm-webengine through client restarts), owner now {s}", .{eng.owner.name()})
        else
            try res.textf("browser engine: client-spawned (exits with its last client), owner now {s}", .{eng.owner.name()});
    }
    if (helper == null)
        try res.text("sketerm-webengine is not installed next to the sketerm binary — the web_* tools have nothing to drive, in any mode (build it with: zig build fetch-cef && zig build web)")
    else if (std.mem.eql(u8, web_backend, "none"))
        try res.text("--shared mode drives the user's GUI, but no GUI control socket was found; start the sketerm GUI (or run without --shared, where the web_* tools work headlessly with no GUI at all)")
    else
        try res.text(try verdicts.line(arena, web_backend));

    try res.fact("ssh", pathz.executableOnPath("ssh"));
    try res.fact("scp", pathz.executableOnPath("scp"));
    {
        var cfg = @import("../config.zig").Config.load(arena);
        defer cfg.deinit();
        try res.fact("ssh_master_max_age_s", cfg.mux_ssh_master_max_age_secs);
    }
    try res.fact("ssh_no_x11", true);
    try res.fact("ssh_connect_timeout_s", @import("../mux/sshroute.zig").CONNECT_TIMEOUT_SECS);
    try res.fact("scp_put_targets", @as(u32, mcp_term.MAX_TARGETS));
    try res.fact("file_sync", headless_terms);
    try res.fact("file_sync_local_rsync", pathz.executableOnPath("rsync"));
    try res.fact("mux_tor", true);
    try res.textf("ssh {s}, scp {s}, local rsync for file_sync {s}; tor:<ssh-alias> transport with forced SOCKS5 remote DNS, no UDP or direct fallback", .{
        yesNo(pathz.executableOnPath("ssh")),
        yesNo(pathz.executableOnPath("scp")),
        yesNo(pathz.executableOnPath("rsync")),
    });
    if (mcp_term.rec_state.enabled) {
        if (recDir()) |d| {
            try res.fact("terminal_recordings", d);
            try res.textf("every headless terminal is auto-recorded as an asciicast v2 .cast file in {s} (replay with asciinema play)", .{d});
        } else try res.raw("terminal_recordings", "null");
    } else try res.raw("terminal_recordings", "null");

    // Effective input-timing defaults, with any env override marked —
    // config-set defaults must never be invisible state.
    {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        var overrides: std.Io.Writer.Allocating = .init(arena);
        try w.writeAll("{");
        for (Tuning.all(), 0..) |item, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\":{{\"value\":{d},\"built_in\":{d},\"overridden\":{}}}", .{ item.name, item.value, item.built_in, item.overridden });
            if (item.overridden) try overrides.writer.print("{s}{s} {d} via {s} (built-in {d})", .{
                if (overrides.written().len > 0) ", " else "", item.name, item.value, item.env, item.built_in,
            });
        }
        try w.writeAll("}");
        try res.raw("input_tuning", aw.written());
        if (overrides.written().len > 0)
            try res.textf("input-timing defaults overridden by env (project .mcp.json): {s}; tools/list states the effective values", .{overrides.written()});
    }

    // Tool exposure. A missing tool must be explicable from inside the
    // session: without this an assistant reads a filtered tools/list as
    // "sketerm cannot do that" and goes looking for workarounds.
    {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("{\"spec\":");
        try std.json.Stringify.value(mcp.policy.spec, .{}, w);
        try w.print(",\"source\":\"{s}\",\"restricted\":{},\"groups_available\":[", .{ mcp.policy_source, !mcp.policy.isUnrestricted() });
        var first = true;
        for (std.enums.values(mcpfilter.Group)) |g| {
            var any = false;
            for (mcpfilter.TOOL_META) |m| {
                if (m.group == g and mcp.policy.allowsMeta(m)) {
                    any = true;
                    break;
                }
            }
            if (!any) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try std.json.Stringify.value(g.name(), .{}, w);
        }
        try w.writeAll("],\"groups_suppressed\":[");
        var sup_buf: [std.enums.values(mcpfilter.Group).len]mcpfilter.Group = undefined;
        const suppressed = mcpfilter.suppressedGroups(mcp.policy, &sup_buf);
        for (suppressed, 0..) |g, i| {
            if (i > 0) try w.writeAll(",");
            try std.json.Stringify.value(g.name(), .{}, w);
        }
        try w.writeAll("]}");
        try res.raw("tool_policy", aw.written());
        if (!mcp.policy.isUnrestricted()) {
            try res.textf("tool policy {s} (from {s}) restricts this connection: withheld tools are absent from tools/list AND refused by tools/call. A withheld tool is an operator decision, not a missing capability; ask the user to restart the server with --tools/--profile or $SKETERM_MCP_TOOLS", .{ mcp.policy.spec, mcp.policy_source });
            if (suppressed.len > 0) {
                var sw: std.Io.Writer.Allocating = .init(arena);
                for (suppressed, 0..) |g, i| {
                    if (i > 0) try sw.writer.writeAll(", ");
                    try sw.writer.writeAll(g.name());
                }
                try res.textf("suppressed groups: {s}", .{sw.written()});
            }
        }
    }

    // App/terminal sessions have no idle timeout; what ends them is
    // this server's own lifetime in isolated mode. Saying so removes a
    // whole class of "the app exited with status 0 for no reason".
    try res.fact("session_lifetime", mcp.srv_mode);

    // Sub-agents (the agent_* tools): available in isolated/durable mode,
    // here or on an SSH host, woken through the waiter command.
    {
        const mcp_agent = @import("mcp_agent.zig");
        const agents_ok = mcp_agent.available();
        const agent_ssh = agents_ok and pathz.executableOnPath("ssh");
        try res.fact("agents", agents_ok);
        try res.fact("agent_ssh", agent_ssh);
        try res.fact("agent_open_args_env", agents_ok);
        try res.fact("agent_open_resume", agents_ok);
        try res.fact("agent_resume_checked", agents_ok);
        try res.fact("agent_open_process_args", agents_ok);
        try res.fact("agent_conversation", agents_ok);
        try res.fact("user_daemon_env_scrubbed", @import("../mux/client.zig").Conn.scrub_user_daemon_env);
        try res.fact("agent_resume_by_id", agents_ok);
        try res.fact("agent_idle_ttl_hours", if (agents_ok) mcp_agent.state.ttl_secs / 3600 else 0);
        try res.fact("tombstones", agents_ok);
        try res.fact("agent_login_shell", agent_ssh);
        const ids: []const []const u8 = if (agents_ok) mcp_agent.adapterIds(arena) catch &.{} else &.{};
        try res.fact("agent_adapters", ids);
        const side_apps: []const []const u8 = if (agents_ok) mcp_agent.sideQuestionApps(arena) catch &.{} else &.{};
        try res.fact("agent_side_question", .{ .available = side_apps.len > 0, .apps = side_apps });
        const tui = if (agents_ok) mcp_agent.tuiApps(arena) catch null else null;
        try res.fact("agent_tui", .{ .available = if (tui) |x| x.apps.len > 0 else false, .apps = if (tui) |x| x.apps else &.{}, .on_by_default = if (tui) |x| x.on_by_default else &.{} });
        const gens: []const mcp_agent.ApiVersions = if (agents_ok) mcp_agent.apiVersions(arena) catch &.{} else &.{};
        try res.fact("agent_api_versions", gens);
        if (agents_ok) {
            if (try mcp_agent.waiterTemplate(arena)) |w| try res.fact("agent_waiter", w) else try res.raw("agent_waiter", "null");
        } else try res.raw("agent_waiter", "null");
        try res.fact("open_agents", mcp_agent.state.entries.items.len);
        const select = @import("../agent/select.zig");
        try res.fact("agent_read_select", .{
            .unit = "job",
            .default_detail = @tagName(select.Detail.selected),
            .final_min_chars = select.FINAL_MIN_CHARS,
            .long_min_chars = select.LONG_MIN_CHARS,
            .cap_chars = select.READ_CAP_CHARS,
        });
        try res.fact("agent_records_once", agents_ok);
        try res.fact("agent_events_shared", agents_ok);
        try res.fact("agent_wait_any", agents_ok);
        try res.fact("agent_wait_all", agents_ok);
        try res.fact("agent_send_many", agents_ok);
        try res.fact("agent_agents_every", agents_ok);
        {
            const vocab_s = @import("../agent/vocab.zig");
            var watched: std.ArrayList([]const u8) = .empty;
            for (std.enums.values(vocab_s.State)) |s| if (s.stallWatched()) try watched.append(arena, @tagName(s));
            try res.fact("agent_stall", .{ .available = agents_ok, .max_min = @import("../agent/stall.zig").MAX_MIN, .states = watched.items, .names_last = agents_ok });
        }
        try res.fact("agent_list_preview", agents_ok);
        try res.fact("agent_waiter_content", agents_ok);
        try res.fact("agent_delivery", .{
            .available = agents_ok,
            .confirm_ms = mcp_agent.DELIVERY_CONFIRM_MS,
            .error_code = @tagName(@import("mcp.zig").ErrCode.not_delivered),
            .screen = "app_evidence",
            .api = "http_accepted",
            .api_unanswered = "message_lookup",
            .api_lookup_ms = @import("../agent/opencode.zig").DELIVERY_LOOKUP_MS,
        });
        try res.fact("agent_send_interrupt", agents_ok);
        try res.fact("agent_send_requeue", agents_ok);
        try res.fact("agent_interrupt_requeue", agents_ok);
        try res.fact("agent_wall_times", agents_ok);
        try res.fact("agent_read_activity", agents_ok);
        try res.fact("agent_close_many", agents_ok);
        try res.fact("agent_list_filters", agents_ok);
        try res.fact("agent_selectors", @import("../agent/selector.zig").FORMS);
        try res.fact("agent_hosts", agents_ok);
        try res.fact("agent_caps", .{ .max_per_host = mcp_agent.state.max_per_host, .min_free_mb = mcp_agent.state.min_free_mb });
        try res.fact("agent_read_final", agents_ok);
        try res.fact("agent_list_compact", agents_ok);
        try res.fact("agent_attention", agents_ok);
        try res.fact("agent_relaunch", agents_ok);
        try res.fact("agent_open_handoff", agents_ok);
        try res.fact("agent_send_queue", agents_ok);
        try res.fact("agent_answer_text", agents_ok);
        try res.fact("agent_permissions", agents_ok);
        try res.fact("agent_templates", agents_ok);
        try res.raw("agent_facts", try std.json.Stringify.valueAlloc(arena, try mcp_agent.factsCapability(arena), .{}));
        {
            const retry = @import("../agent/retry.zig");
            const vocab_r = @import("../agent/vocab.zig");
            var classes: std.ArrayList([]const u8) = .empty;
            for (std.enums.values(vocab_r.ErrorClass)) |cls| if (cls.retriedOnOverload()) try classes.append(arena, @tagName(cls));
            try res.fact("agent_retry_on_overload", .{
                .available = agents_ok,
                .classes = classes.items,
                .default_max = retry.DEFAULT_MAX,
                .max_retries = retry.MAX_RETRIES,
                .default_backoff_s = retry.DEFAULT_BACKOFF_S,
                .backoff_cap_s = retry.BACKOFF_CAP_S,
            });
        }
        try res.fact("agent_gone_on_reconnect", agents_ok);
        try res.fact("agent_push", @tagName(if (agents_ok) mcp_agent.state.push else .none));
        try res.fact("agent_push_follow", agents_ok and mcp_agent.state.waiter.path != null);
        try res.fact("agent_push_followers", if (agents_ok) mcp_agent.followers() else 0);
        {
            const mcp_peer = @import("mcp_peer.zig");
            try res.raw("peers", try mcp_peer.capabilityJson(arena));
            const pc = mcp_peer.capability();
            if (pc.available)
                try res.textf("peers: this session is {s}{s}; their messages {s}{s}", .{ if (pc.address.len > 0) pc.address else "(registering)", if (pc.durable) " (durable)" else "", if (pc.channel_armed) "arrive as channel messages" else "arrive through peer_read unless a follower (the opencode plugin) pushes them", if (!pc.slow_mail) "; the per-user daemon predates quiet sends and to lists" else "" })
            else
                try res.textf("peers: unavailable ({s})", .{pc.reason orelse "unknown"});
        }
        const vocab = @import("../agent/vocab.zig");
        var quiet: std.ArrayList([]const u8) = .empty;
        for (std.enums.values(vocab.ErrorClass)) |cls| if (!cls.wakesByDefault()) try quiet.append(arena, @tagName(cls));
        try res.fact("agent_done", .{
            .settled = true,
            .background_cap_ms = select.BACKGROUND_DONE_CAP_MS,
            .background_cap_quiet = true,
            .quiet_errors = quiet.items,
            .quiet_opt_ins = vocab.names(@import("../agent/events.zig").Quiet),
        });
        if (agents_ok) {
            const side_text: []const u8 = if (side_apps.len > 0) try std.fmt.allocPrint(arena, "; agent_ask side questions: {s}", .{try std.mem.join(arena, ", ", side_apps)}) else "";
            try res.textf("sub-agents: {s} on this machine{s}{s}; agents outlive this server for {d} h unattached (mcp_agent_idle_ttl_hours) and agent_attach resumes them", .{
                try std.mem.join(arena, ", ", ids),
                if (agent_ssh) " or an SSH host" else " (no ssh client here, so not on SSH hosts)",
                side_text,
                mcp_agent.state.ttl_secs / 3600,
            });
            if (mcp_agent.state.push == .channel)
                try res.text("agent events are pushed into this session as channel messages: end your turn after delegating, no watch_command needed")
            else if (mcp_agent.followers() > 0)
                try res.text("agent events are pushed into this session by an agent-wait --server follower (the opencode plugin): end your turn after delegating, no watch_command needed")
            else
                try res.text("agent events are not pushed into this session (Claude Code needs --dangerously-load-development-channels server:sketerm or --channels, opencode the sketerm agents plugin): run a result's watch_command in the background to be woken");
        } else try res.text("sub-agents (agent_*) are unavailable in --shared mode: they run on an isolated or durable instance's private daemon");
    }

    try res.fact("term_exec_shell_default", mcp_term.term_state.mux_sock != null);
    try res.fact("open_terms", mcp_term.term_state.terms.count());
    try res.fact("open_apps", mcp_app.app_state.apps.count());
    try res.fact("open_forwards", mcp_term.forward_state.forwards.count());
    try res.textf("open: {d} terminal(s), {d} app(s), {d} forward(s)", .{
        mcp_term.term_state.terms.count(), mcp_app.app_state.apps.count(), mcp_term.forward_state.forwards.count(),
    });

    // A capability-shaped index of a ~100-tool surface. A large surface
    // invites "there must be a tool for this" searching over "what is
    // the simplest path" — two sessions once burned a dozen calls
    // hunting for a transport that did not exist. These are the
    // answers to the questions that were actually asked.
    try res.text(
        "WHERE TO START (by task, not by tool name): " ++
            "move bytes OUT of a page -> web_download (url -> file, with the page's own session) or web_eval out_file: (a computed result -> file); " ++
            "read a page -> web_read (article text) or web_snapshot (things to act on); act on it -> web_act; " ++
            "run something -> term_run in a live shell, term_exec for an isolated one-shot; " ++
            "files on THIS machine -> file_read / file_write / file_list; files over SSH -> scp_get / scp_put; a directory to many hosts or clones -> file_sync; " ++
            "drive a GUI app -> launch_app then app_click / app_type / screenshot_app; " ++
            "show the user something -> ui_show. Nothing here streams data through the conversation that a file could carry.",
    );
    return res.finish();
}
