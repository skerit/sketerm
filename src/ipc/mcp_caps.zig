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
const findExecutable = mcp_app.findExecutable;
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
    return findExecutable(arena, "sketerm-webengine");
}

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
    try res.fact("headless_gui", mcp_app.app_state.ready);
    try res.fact("gui_socket", mcp.srv_gui_socket);
    try res.fact("gui_socket_source", @tagName(mcp.srv_gui_socket_source));
    try res.fact("headless_terminals", headless_terms);
    try res.fact("transfers_and_forwards", headless_terms);
    try res.textf("mode {s}: headless GUI apps {s}, headless terminals {s}, transfers/forwards {s}", .{
        mcp.srv_mode,
        yesNo(mcp_app.app_state.ready),
        yesNo(headless_terms),
        yesNo(headless_terms),
    });
    try res.textf("direct GUI control socket: {s} ({s}) — independent of headless GUI apps and of relayed panels", .{
        yesNo(mcp.srv_gui_socket),
        @tagName(mcp.srv_gui_socket_source),
    });
    if (!std.mem.eql(u8, mcp.srv_mode, "shared"))
        try res.text("this server talks to its own PRIVATE mux daemon: sessions here are invisible to the user's `sketerm mux list` / `sketerm app`, and apps started there are invisible here (run with --shared to join the user's daemon)");

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
        try res.text("live ui_* calls need either an origin session relay (SKETERM_SESSION plus SKETERM_MUX_SOCKET, or the connect-only default daemon fallback) or an explicit direct GUI socket. Store-only ui_save/ui_panels/ui_delete stay available while panels_store is true");
    if (!panel_store_ready)
        try res.text("saved-panel persistence is unavailable because the exact origin identity could not be resolved; ui_save/ui_delete return the same failure and ui_panels reports saved_error. Exact origins never downgrade to reusable session storage");

    const ocr_ok = ocr.available();
    try res.fact("ocr", ocr_ok);
    if (!ocr_ok)
        try res.text("app_read_text/app_wait_text need libtesseract — install tesseract + tesseract-data-eng on THIS machine");
    // Rootless X11 for app sessions is a daemon-host fact; the private
    // daemon runs on this host, so PATH here is the answer for it.
    const pathz = @import("../util/pathz.zig");
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
        try res.textf("web_gui: the web_* tools may use the user's OWN browser and logins (granted via {s}); transport now {s}{s} -- a GUI is found or `sketerm web` started lazily at the first web call, found again if it goes away, and a web call with no reachable GUI fails 'unavailable' rather than opening a private headless view. Terminal/app/file/panel tools stay on the private daemon", .{ via, webGuiTransport().name(), sock_note });
    } else try res.textf("web_gui: not granted -- the web_* tools use a private browser with its own cookie jar (the assistant is logged in nowhere); the user grants their own browser with {s}, {s}=1 or web_gui = true in config.conf's [mcp] section", .{ mcp_webgui.FLAG, mcp_webgui.ENV });
    if (@import("mcp_web.zig").sessionInfo()) |ws| try res.fact("web_session", ws);
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
    try res.fact("web_emulation", @import("mcp_web.zig").restrictedCapability(.web_emulation));
    try res.fact("web_untrusted_mode", @import("mcp_web.zig").untrustedMode());
    try res.fact("web_review", .{ .inspection = true, .checkpoints = true, .evidence_export = true, .requires_helper_capability = "review", .gui_console = false });
    try res.fact("web_diagnostics", .{ .direct_capture = true, .broker_capture = "requires engine_open diagnostics capability", .gui_capture = false, .retention = "last attempt per route until next attempt or MCP shutdown" });
    if (web_ok and !gui_web and !engine_started)
        try res.text("the browser engine has not started yet (it spawns at the first web_* call), so web_backend/web_watch/web_session are not yet determined -- open a view and read them again rather than treating this reply as their final value");
    // The browser-page watch: the GUI joins this server's helper as a
    // second client and shows its pages as web pages (helper
    // capability "observe"). `web_socket` is the socket it joins.
    const web_observe = @import("mcp_web.zig").observeActive();
    try res.fact("web_observe", web_observe);
    const handoff_available: ?bool = if (!gui_web and !engine_started) null else web_observe and @import("mcp_web.zig").sessionInfo() != null;
    try res.fact("web_handoff", .{ .session_naming = !gui_web, .available = handoff_available, .entry_point = "AI badge: Watch / Take control", .backend_is_visibility = false });
    var web_sock_buf: [4096]u8 = undefined;
    if (@import("mcp_web.zig").helperSocket(&web_sock_buf)) |ws| try res.fact("web_socket", ws) else try res.raw("web_socket", "null");
    if (web_observe) try res.text("Assistant-owned browser tabs can be shown and driven by the user: orange AI badge / Session Overview -> Watch or Take control. backend:headless does not mean invisible. Give web_open a descriptive name; keep its tab open for manual login and reuse it with web_navigate.");
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
        // Downloading through a view: the only path that carries the
        // page's own session, so a consumer must be able to preflight
        // it rather than discover it by trying.
        const dl = @import("mcp_web.zig").downloadCapability();
        try res.fact("web_downloads", dl.supported);
        if (dl.supported)
            try res.text(if (dl.started)
                "web_download fetches a url INSIDE a view's browser (its cookies and session) straight to a file; a download a page starts lands in the user's XDG download directory and web_download with no url lists them"
            else
                "web_download is available once the browser engine starts; it fetches a url INSIDE a view's browser (its cookies and session) straight to a file")
        else
            try res.text("this browser helper cannot download through a view (capabilities 'downloads' + 'download-start')");
        // Response-body capture: a fail-closed open option, so a
        // consumer must be able to preflight it rather than trip over
        // the refusal.
        const cp = @import("mcp_web.zig").captureCapability();
        try res.fact("web_capture", cp.supported);
        if (cp.supported)
            try res.text(if (cp.started)
                "web_open capture:{...} records the response bodies a headless view's page receives; web_capture reads them, web_wait for:\"response\" waits for the next one"
            else
                "response-body capture (web_open capture:{...}) is available once the browser engine starts")
        else if (gui_web)
            try res.text("response-body capture is headless only: the web tools drive the user's own tabs here")
        else
            try res.text("this browser helper cannot capture response bodies (capability 'capture'); a captured web_open is refused");
        try res.fact("web_accept_cert", !gui_web);
        try res.text(if (gui_web)
            "certificate errors: the user's interstitial decides; results carry cert facts while a load is held"
        else
            "certificate errors fail closed in headless views and are reported as cert facts; web_open accept_cert trusts one fingerprint for one view");
        if (profiles.store.len > 0) try res.fact("web_profile_store", profiles.store);
        try res.fact("web_profile_save", @import("mcp_web.zig").profileSaveCapability());
        if (profiles.available)
            try res.text("named browsing profiles are available (web_open profile:\"name\"); each keeps its own cookie jar across MCP restarts")
        else if (profiles.reason.len > 0)
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
            try res.textf("browser engine lifecycle: broker-owned (the mux daemon spawns sketerm-webengine and keeps it through client restarts; owner now: {s})", .{eng.owner.name()})
        else
            try res.textf("browser engine lifecycle: client-spawned (exits with its last client; owner now: {s})", .{eng.owner.name()});
    }
    if (helper == null)
        try res.text("sketerm-webengine is not installed next to the sketerm binary — the web_* tools have nothing to drive, in any mode (build it with: zig build fetch-cef && zig build web)")
    else if (std.mem.eql(u8, web_backend, "none"))
        try res.text("--shared mode drives the user's GUI, but no GUI control socket was found; start the sketerm GUI (or run without --shared, where the web_* tools work headlessly with no GUI at all)")
    else
        try res.textf("web: {s} backend", .{web_backend});

    try res.fact("ssh", findExecutable(arena, "ssh") != null);
    try res.fact("scp", findExecutable(arena, "scp") != null);
    {
        var cfg = @import("../config.zig").Config.load(arena);
        defer cfg.deinit();
        try res.fact("ssh_master_max_age_s", cfg.mux_ssh_master_max_age_secs);
    }
    try res.fact("ssh_no_x11", true);
    try res.fact("ssh_connect_timeout_s", @import("../mux/sshroute.zig").CONNECT_TIMEOUT_SECS);
    try res.fact("scp_put_targets", @as(u32, mcp_term.MAX_TARGETS));
    try res.fact("file_sync", headless_terms);
    try res.fact("file_sync_local_rsync", @import("../util/pathz.zig").executableOnPath("rsync"));
    try res.fact("mux_tor", true);
    try res.text("mux Tor transport: supported via tor:<ssh-alias>; forced SOCKS5 remote DNS, with no UDP or direct fallback");
    if (mcp_term.rec_state.enabled) {
        if (recDir()) |d| try res.fact("terminal_recordings", d) else try res.raw("terminal_recordings", "null");
        try res.text("every headless terminal is auto-recorded as an asciicast v2 .cast file there (replay with asciinema play)");
    } else try res.raw("terminal_recordings", "null");

    // Effective input-timing defaults, with any env override marked —
    // config-set defaults must never be invisible state.
    {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("{");
        var any_override = false;
        for (Tuning.all(), 0..) |item, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\":{{\"value\":{d},\"built_in\":{d},\"overridden\":{}}}", .{ item.name, item.value, item.built_in, item.overridden });
            if (item.overridden) any_override = true;
        }
        try w.writeAll("}");
        try res.raw("input_tuning", aw.written());
        if (any_override)
            try res.text("some input-timing defaults were overridden via SKETERM_MCP_* env (project .mcp.json); the tools/list descriptions already state the effective values");
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
            try res.textf("tool mcp.policy {s} (from {s}) restricts this connection; withheld tools are absent from tools/list AND refused by tools/call. A withheld tool is not a missing capability — ask the user to restart the server with --tools/--profile or $SKETERM_MCP_TOOLS", .{ mcp.policy.spec, mcp.policy_source });
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
    if (std.mem.eql(u8, mcp.srv_mode, "shared"))
        try res.text("session lifetime: sessions live on the user's own daemon and outlive this server; nothing here times them out")
    else if (std.mem.eql(u8, mcp.srv_mode, "isolated"))
        try res.text("session lifetime: the private daemon and EVERY app/terminal on it are torn down when this MCP server exits. There is no idle timeout — an app that 'exited on its own' between sessions was killed by that teardown. Use --durable/--name for sessions that survive restarts")
    else
        try res.text("session lifetime: the daemon and its sessions survive this server's restarts and are reattached on reconnect; there is no idle timeout");

    // Sub-agents (the agent_* tools): available in isolated/durable mode,
    // here or on an SSH host, woken through the waiter command.
    {
        const mcp_agent = @import("mcp_agent.zig");
        const agents_ok = mcp_agent.available();
        const agent_ssh = agents_ok and findExecutable(arena, "ssh") != null;
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
            try res.textf("sub-agents: agent_open runs one of {d} adapter(s) on this machine{s}, directly or through a wrapper (binary + args + env); results carry a watch_command that wakes you when it needs attention", .{ ids.len, if (agent_ssh) " or on an SSH host (host)" else " (no ssh client here, so not on SSH hosts)" });
            try res.textf("agent_read and done results return per job its last message, earlier segment finals of {d}+ chars, messages of {d}+ chars and notices, about {d} chars per read (detail all for every message); each record reaches you once", .{ select.FINAL_MIN_CHARS, select.LONG_MIN_CHARS, select.READ_CAP_CHARS });
            try res.text("done means settled (no subagents or background tasks left running; the done after 30 minutes idle with background tasks is quiet unless background:true / --background); results and waiters share one event delivery, and agent_wait agents / agent-wait --any watch several agents (all / --all: once every one settled)");
            try res.textf("a prompt counts as sent only once the app shows it took it (a turn, a user record, a queue preview) within {d} s; otherwise the send fails as not_delivered and is never typed again", .{@divTrunc(mcp_agent.DELIVERY_CONFIRM_MS, 1000)});
            try res.text("agent_send to a busy agent queues the prompt in its app for the next turn (outcome queued) unless interrupt, agents sends to several in one call (agents \"*\": every live agent), and agent_answer takes free text where the prompt allows it");
            try res.text("agent_read final returns just the newest job's last message, agent_list is compact unless detail, and agent_attach relaunch starts a gone agent again under its id");
            try res.text("agent_open takes permissions (name to allow/ask/deny, mapped to each app's own mechanism) and retry_on_overload (continue a turn a provider overload ended, off by default); a lost remote link that comes back to find the session gone ends the agent as exited, relaunchable");
            try res.text("agent_template_save keeps named briefs (placeholders in braces) that agent_send and agent_open take as template + vars");
            if (side_apps.len > 0) try res.textf("agent_ask asks an agent a side question (how far are you?) answered from its current context without a turn, busy or idle, recording nothing: {s}", .{try std.mem.join(arena, ", ", side_apps)});
            try res.text("every per-agent result and agent_list carry facts: what the app reports about its context use, rate limits and cost (agent_facts names them per adapter), the context percent also in agent_list's one-line form");
            if (mcp_agent.state.push == .channel)
                try res.text("agent events are pushed into this session as Claude Code channel messages: end your turn after delegating instead of running watch_command")
            else if (mcp_agent.followers() > 0)
                try res.text("agent events are pushed into this session by an agent-wait --server follower (the opencode plugin): end your turn after delegating instead of running watch_command")
            else
                try res.text("agent events are not pushed into this session: Claude Code needs --dangerously-load-development-channels server:sketerm (or --channels), opencode the sketerm agents plugin; until then use watch_command");
            try res.textf("agents outlive this server on their host's per-user daemon for {d} h unattached (mcp_agent_idle_ttl_hours): agent_open returns an id, and agent_attach {{agent: id}} resumes it after a restart", .{mcp_agent.state.ttl_secs / 3600});
        } else
            try res.text("sub-agents (agent_*) are unavailable in --shared mode: they run on an isolated or durable instance's private daemon");
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
